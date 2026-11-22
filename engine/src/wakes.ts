// Waking an agent that is not answering when something it left running ends (issues #158 and #104). See docs/wakes.md.
//
// Two things can wake an agent: a sub-chat it handed work to with `delegate` and `wait: false`, once the sub-chat
// answers or stops, and a command it started in the background with `bash`, `background: true` and `wake: true`, once
// the command ends. Each is a watch, kept in a session document from the moment it starts, so that what ends while
// the engine is down, or as it stops, still wakes the agent once when it starts again. A third, the person's answer to
// what the agent put under Needs you (needs.ts, #462), is not watched: it arrives in the commit that takes the answer.
//
// What has ended waits in the same document until its conversation is idle. Then all of it is handed to the agent as
// one message, oldest first, which starts an answer like any message: under the conversation's turn limit, and its
// tool calls asked about under Ask first as always. Nothing is handed over while the conversation is answering (it
// goes when the answer ends), while today's budget is used up, after the person stopped the agent (until they send a
// message), or once the conversation has been woken `WAKES_PER_HOUR` times in the last hour. An archived or deleted
// conversation is never woken: what it was waiting for is let go, and an archived one gets a line saying so.
//
// A sub-chat is never woken, with one exception (#507): the person's answer to what a worker in a project put under
// Needs you. While the worker's run is going, the answer steers that run, given as its next input within the same bounds;
// once the run has ended, it goes instead to the conversation that handed the worker the work (`relay`), and the worker
// is not started again.

import { awaitWithContext, type Context } from "@earendil-works/chord/context";
import { ConversationBusy, type ConversationId, ConversationIdle, defineDoc, type SettledSubmissionRecord, type SubmissionId, type Tx } from "@earendil-works/pi-durable";
import { type Host, subChatResult } from "./extensions.ts";
import type { Engine, Feature } from "./features.ts";
import { answerGoesTo } from "./orchestrator.ts";
import { addNews, Projects, projectOf } from "./projects.ts";
import { latestReport, type ReportWake, reportOf, reportWatched, settle, unreadReports, wakeFor } from "./reports.ts";
import { Library, type Meta } from "./state.ts";
import { subChatActivity } from "./subchats.ts";
import { testSwitch } from "./testswitches.ts";
import { syncWorkForInput } from "./work.ts";

/** The message that wakes an agent: the model reads its content, and the transcript shows a line. */
export const WAKE_ENTRY = "pi2.wake";
/** A line for the person only: why the agent was not woken, or will not be for a while. */
export const WAKE_NOTE = "pi2.wake-note";

/**
 * The most times a conversation is woken in an hour. An agent that hands out work to many sub-chats is woken once for
 * each that answers on its own (those that answer together come in one wake), and the busiest such round seen so far
 * had eighteen; thirty leaves room for that and the builds it waits on. A command that ends and is started again in a
 * loop, or work handed back and forth, stops there: what arrives meanwhile is kept until the hour allows another wake,
 * or the person sends a message. The daily budget bounds what the wakes cost either way.
 */
export const WAKES_PER_HOUR = (() => {
	// A test sets another, to reach it in a few wakes; a release engine ignores it (testswitches.ts).
	const given = Number(testSwitch("PI2_WAKES_PER_HOUR"));
	return Number.isInteger(given) && given > 0 ? given : 30;
})();
const HOUR = 3_600_000;
/** How often a wake held for the budget looks again, for a budget that is raised or a new day. */
const BUDGET_RECHECK_MS = 60_000;
/** How long a watch's key is remembered once it arrived, so a call run again after a crash cannot watch it twice. */
const SEEN_MS = 7 * 86_400_000;

export type WakeKind = "subchat" | "background" | "answer";

/** Something a conversation's agent will be woken for when it ends. */
export type Watch = {
	key: string;
	/** The conversation to wake. */
	conversationId: number;
	kind: WakeKind;
	/** The sub-chat's number, or the background command's id. */
	ref: string;
	/** How the person and the agent are told of it: "sub-chat 12 “Fix login”", "background command bg-3 (`npm test`)". */
	label: string;
	startedAt: number;
	/** For a sub-chat: the submission it answers, and the agent's name. */
	submissionId?: number;
	agent?: string;
	/**
	 * Read only for a run of a sub-chat of a project's orchestrator, which has a report (reports.ts, #463): when its
	 * report wakes the orchestrator. Absent: as the project's `wakeOnReports` says when it ends.
	 */
	wake?: ReportWake;
	/** The batch it belongs to (`reports` `wake`, several chats): `all` and `failure` count over the batch's runs. */
	batch?: string;
};

/**
 * Something that ended, waiting to be handed to its conversation's agent. `report`: the run whose report it carries
 * (reports.ts), given only if `settle` says so in the commit that wakes the agent.
 */
export type Arrived = { key: string; kind: WakeKind; ref: string; label: string; ended: string; text: string; at: number; failure?: SubChatFailure; report?: number; relay?: Relay };
/**
 * An answer to what a worker (a sub-chat) put under Needs you (#507): what goes to the conversation that handed it the
 * work in its place, if the worker's run has ended before it is given; and the line of news for the project's
 * orchestrator when it is given to the worker itself (docs/projects.md, 6.4).
 */
export type Relay = { label: string; text: string; news: { projectId: string; text: string } };
/** Keep the older run's reason separate from its advice, which can be out of date at handover. */
type SubChatFailure = { submissionId: number; withoutAdvice: string; usage: string };
/** Why a conversation is not woken for now: the person stopped it, the hourly cap, or the budget. */
type Hold = { why: "stopped" | "cap" | "budget"; since: number };
export type WakesDoc = {
	watching: Record<string, Watch>;
	/** By conversation, oldest first. */
	arrived: Record<string, Arrived[]>;
	/** By conversation, when it was woken in the last hour. */
	woken: Record<string, number[]>;
	held: Record<string, Hold>;
	/** Keys that have arrived, with when. */
	seen: Record<string, number>;
	/**
	 * Answers given to a worker's run as it worked (#507), by the submission that steers it, until the run takes it in: a
	 * run that ends first (stopped, failed) never places it, and what it carried goes to the worker's parent instead.
	 */
	steered?: Record<string, { conversationId: number; items: Arrived[] }>;
};
type Doc = WakesDoc;
const empty = (): Doc => ({ watching: {}, arrived: {}, woken: {}, held: {}, seen: {} });

export const Wakes = defineDoc<Doc>({
	kind: "pi2.wakes",
	version: 1,
	scope: "session",
	initial: empty,
	checkpointWhen: () => true,
});

let engine: Engine | undefined;
let host: Host | undefined;
/** The document as last committed, for reading outside a commit. */
let mirror: Doc = empty();
/** Set once the engine has loaded what it needs to decide (its usage, for the budget): nothing is delivered before. */
let ready = false;
/** Sub-chat watches whose submission this engine is waiting on. */
const following = new Set<string>();
/** Steers this engine is waiting on to be placed or let go (`steered`). In memory: `start` picks them up again. */
const steering = new Set<string>();
/** Waiting for what arrives in a conversation: `sub_chats` with `wait`. */
const listeners = new Map<number, Set<() => void>>();
const delivering = new Set<number>();
const again = new Set<number>();
const timers = new Map<number, ReturnType<typeof setTimeout>>();

const copy = <T>(value: T): T => JSON.parse(JSON.stringify(value));

async function change<T>(edit: (doc: Doc) => T): Promise<T> {
	return commitWakes((_tx, doc) => edit(doc));
}

/** Change the document in a commit that may change others too (reports.ts), and read it back. */
export async function commitWakes<T>(edit: (tx: Tx, doc: Doc) => T | Promise<T>): Promise<T> {
	if (engine === undefined) throw new Error("Waking is not available here");
	const harness = engine.harness();
	const result = await harness.commit(async (tx) => edit(tx, await tx.doc(Wakes)), engine.context());
	mirror = copy((await harness.snapshot(Wakes, engine.context())) ?? empty());
	announce();
	return result;
}

/** Read the document back after a commit made elsewhere (a tool's) that changed it. */
export async function reloadWakes(): Promise<void> {
	if (engine === undefined) return;
	mirror = copy((await engine.harness().snapshot(Wakes, engine.context())) ?? empty());
	announce();
}

/** The sub-chats' runs watched now, of every conversation. */
export const watchedRuns = (): Watch[] => Object.values(mirror.watching).filter((each) => each.kind === "subchat");

/** The conversation at the top of the sidebar that `id` belongs to. */
const rootOf = (id: number) => engine?.library().conversations[String(id)]?.parent ?? id;

/** Why a conversation is out of the sidebar, itself or through the one it is a sub-chat of. */
function putAway(id: number): "archived" | "deleted" | undefined {
	const all = engine?.library().conversations ?? {};
	const own = (key: number) => {
		const meta = all[String(key)];
		if (meta === undefined || meta.deleted === true) return "deleted" as const;
		return meta.archivedAt !== undefined ? ("archived" as const) : undefined;
	};
	const reasons = [own(id), own(rootOf(id))];
	return reasons.includes("deleted") ? "deleted" : reasons.includes("archived") ? "archived" : undefined;
}

/** What the apps are sent: everything a conversation will be woken for, running or arrived, and why it is held. */
function event() {
	const items = [
		...Object.values(mirror.watching).map((watch) => ({ ...shown(watch), state: "running" })),
		...Object.entries(mirror.arrived).flatMap(([id, list]) => list.map((item) => ({ ...shown({ ...item, conversationId: Number(id), startedAt: item.at }), state: "arrived" }))),
	];
	const held = Object.entries(mirror.held).map(([id, hold]) => ({ conversationId: Number(id), why: hold.why, since: hold.since, until: hold.why === "cap" ? capEnds(Number(id)) : null }));
	return { event: "wakes", items, held, perHour: WAKES_PER_HOUR };
}
const shown = (item: { key: string; conversationId: number; kind: WakeKind; ref: string; label: string; startedAt: number; wake?: ReportWake; batch?: string }) => ({
	key: item.key,
	conversationId: item.conversationId,
	rootConversationId: rootOf(item.conversationId),
	kind: item.kind,
	ref: item.ref,
	label: item.label,
	startedAt: item.startedAt,
	// The projects epic (#463): the project of the conversation woken, and the watch's own choice and batch, as stored.
	projectId: projectOf(item.conversationId)?.id ?? null,
	wake: item.wake ?? null,
	batch: item.batch ?? null,
});
const announce = () => engine?.broadcast(event());

/** When the oldest wake of the last hour drops out of it, letting another one through. */
function capEnds(id: number): number | null {
	const recent = (mirror.woken[String(id)] ?? []).filter((at) => at > Date.now() - HOUR);
	return recent.length < WAKES_PER_HOUR ? null : recent[recent.length - WAKES_PER_HOUR]! + HOUR;
}

/** Write a line for the person into a conversation. Never throws. */
async function note(id: number, data: Record<string, unknown>): Promise<void> {
	if (engine === undefined) return;
	try {
		const conv = await engine.harness().conversation(id as unknown as ConversationId, engine.context());
		await conv?.submit({ type: "write", entry: { kind: WAKE_NOTE, data: data as never } }, engine.context());
	} catch (error) {
		engine.log("could not write a note about waking conversation", id, error instanceof Error ? error.message : error);
	}
}

// ---- Watching

/**
 * Wake `watch.conversationId`'s agent when this ends. Undefined once watched; otherwise why it cannot be: only a
 * conversation of its own is woken, since a sub-chat's answers go to the agent that handed it the work, not to anyone
 * reading its own transcript.
 */
export async function watch(given: Watch): Promise<string | undefined> {
	if (engine === undefined) return "Waking is not available here.";
	if (engine.library().conversations[String(given.conversationId)]?.parent !== undefined) {
		return "A sub-chat is not woken: its answers go to the agent that handed it the work.";
	}
	await change((doc) => {
		if (doc.seen[given.key] !== undefined || doc.watching[given.key] !== undefined) return;
		doc.watching[given.key] = given;
	});
	if (given.kind === "subchat") follow(given);
	return undefined;
}

/** Stop watching something, so that its end wakes nobody: the agent stopped it, or was told of its end another way. */
export async function unwatch(key: string): Promise<void> {
	if (mirror.watching[key] === undefined) return;
	await change((doc) => {
		delete doc.watching[key];
		doc.seen[key] = Date.now();
	});
}

/** Whether something is watched: whether its end will wake an agent. */
export const watched = (key: string): boolean => mirror.watching[key] !== undefined;

/**
 * Something watched has ended: keep it for its agent, and wake the agent if it is not answering. `ended` is a few words
 * for the person's line ("answered", "exited with code 1"); `text` is what the agent is given, or the failure reason
 * with advice when `failure` allows that advice to be replaced at delivery.
 */
export async function arrive(key: string, ended: string, text: string, failure?: SubChatFailure): Promise<void> {
	const id = await change((doc) => {
		const watch = doc.watching[key];
		if (watch === undefined) return undefined;
		delete doc.watching[key];
		doc.seen[key] = Date.now();
		const item: Arrived = { key, kind: watch.kind, ref: watch.ref, label: watch.label, ended, text, at: Date.now(), ...(failure === undefined ? {} : { failure }) };
		doc.arrived[String(watch.conversationId)] = [...(doc.arrived[String(watch.conversationId)] ?? []), item];
		return watch.conversationId;
	});
	if (id === undefined) return;
	for (const listener of [...(listeners.get(id) ?? [])]) listener();
	void deliver(id);
}

/**
 * Something that wakes `conversationId`'s agent without having been watched: the person's answer to a question or
 * decision it put under Needs you (needs.ts, the wake kind `answer`). It is added inside `tx`, the commit that takes the
 * answer, so the answer and its wake are stored together, once; call `arrivedIn` when that commit is made. A key already
 * seen adds nothing.
 */
export async function arriveIn(tx: Tx, conversationId: number, item: { key: string; kind: WakeKind; ref: string; label: string; ended: string; text: string; relay?: Relay }): Promise<void> {
	const doc = await tx.doc(Wakes);
	if (doc.seen[item.key] !== undefined) return;
	doc.seen[item.key] = Date.now();
	doc.arrived[String(conversationId)] = [...(doc.arrived[String(conversationId)] ?? []), { ...item, at: Date.now() }];
}

/** What `arriveIn` added has been committed: read it, and wake the agent if it is not answering. */
export async function arrivedIn(conversationId: number): Promise<void> {
	if (engine === undefined) return;
	mirror = copy((await engine.harness().snapshot(Wakes, engine.context())) ?? empty());
	announce();
	void deliver(conversationId);
}

/** Wait for a sub-chat's submission to settle, then pass on its result. In memory: `start` picks the watches up again. */
function follow(watch: Watch): void {
	const submissionId = watch.submissionId;
	// A run with a report is followed by reports.ts, which decides what its end wakes (`settle`), and is told of the watch.
	if (reportOf(submissionId) !== undefined) return reportWatched(submissionId);
	if (engine === undefined || host === undefined || submissionId === undefined || following.has(watch.key)) return;
	following.add(watch.key);
	const { harness, context } = { harness: engine.harness(), context: engine.context() };
	const child = Number(watch.ref);
	void (async () => {
		try {
			const submission = await harness.submission(submissionId as unknown as SubmissionId, context);
			let settled: SettledSubmissionRecord | undefined;
			if (submission !== undefined) settled = await submission.wait(context);
			const result = await subChatResult(host!, harness, child, watch.agent ?? "The agent", settled, context);
			if (result.failed) {
				await arrive(watch.key, "stopped without answering", result.text, { submissionId, withoutAdvice: result.withoutAdvice, usage: result.usage });
			} else {
				await arrive(watch.key, "answered", `${capital(watch.label)} answered:\n\n${result.text}`);
			}
		} catch (error) {
			engine?.log("could not follow", watch.label, "for conversation", watch.conversationId, error instanceof Error ? error.message : error);
		} finally {
			following.delete(watch.key);
		}
	})();
}

const capital = (text: string) => text.charAt(0).toUpperCase() + text.slice(1);

/**
 * A report (reports.ts) as something that arrived: worded as `follow` words a watched sub-chat's end, so that a wake, a
 * wait and a read give it alike.
 */
export function reportArrival(report: { submissionId: number; conversationId: number; title: string }, result: Awaited<ReturnType<typeof subChatResult>>, at: number): Arrived {
	const label = `sub-chat ${report.conversationId} “${report.title}”`;
	const base = { key: `report:${report.submissionId}`, kind: "subchat" as const, ref: String(report.conversationId), label, at, report: report.submissionId };
	if (result.failed) return { ...base, ended: "stopped without answering", text: result.text, failure: { submissionId: report.submissionId, withoutAdvice: result.withoutAdvice, usage: result.usage } };
	return { ...base, ended: "answered", text: `${capital(label)} answered:\n\n${result.text}` };
}

/**
 * Whether the run of worker `id` has ended, so that an answer for it goes to the conversation that handed it the work
 * (#507): as the report of its latest run says (reports.ts), for a sub-chat that has one; else, or as well, by its being
 * idle, stopped by the person, or put away.
 */
function workerDone(id: number): boolean {
	if (engine === undefined) return true;
	if (putAway(id) !== undefined || mirror.held[String(id)]?.why === "stopped") return true;
	const report = latestReport(id);
	return (report !== undefined && report.ended !== null) || !engine.busy(id);
}

/**
 * Give what arrived for worker `id` and was not given to it to the conversation that handed it the work instead, with
 * the words for that (`relay`): for the orchestrator's sub-chat, its current conversation (orchestrator.ts). Woken at
 * once, within the bounds as any wake; a conversation put away lets it go, as any wake for it.
 */
async function relay(id: number): Promise<void> {
	if (engine === undefined) return;
	const parent = engine.library().conversations[String(id)]?.parent;
	const to = await commitWakes(async (tx, doc) => {
		const list = doc.arrived[String(id)] ?? [];
		if (list.length === 0) return undefined;
		delete doc.arrived[String(id)];
		delete doc.held[String(id)];
		const moving = list.filter((item) => item.relay !== undefined);
		if (parent === undefined || moving.length === 0) return undefined;
		const { to } = await answerGoesTo(tx, parent);
		const given = moving.map(({ relay, ...item }) => ({ ...item, label: relay!.label, text: relay!.text }));
		doc.arrived[String(to)] = [...(doc.arrived[String(to)] ?? []), ...given];
		return to;
	});
	if (to === undefined) return;
	engine.log("sub-chat", id, "had ended, so the person's answer goes to conversation", to);
	for (const listener of [...(listeners.get(to) ?? [])]) listener();
	void deliver(to);
}

/** Something that arrived for `conversationId` (a report, reports.ts): a `sub_chats` wait there looks again. */
export function heard(conversationId: number): void {
	for (const listener of [...(listeners.get(conversationId) ?? [])]) listener();
}

/** Hand what arrived for `conversationId` to its agent, if it can be now. */
export function wakeUp(conversationId: number): void {
	void deliver(conversationId);
}

export function resultText(item: Arrived, conversations: Record<string, Meta>): string {
	const failure = item.failure;
	if (failure === undefined) return item.text;
	const meta = conversations[item.ref];
	const head = `${capital(item.label)} stopped without an answer:\n\n`;
	if ((meta?.subChatTask ?? 0) <= failure.submissionId) return head + item.text + failure.usage;
	const activity = host === undefined ? undefined : subChatActivity(host, [Number(item.ref)]);
	const state = meta?.deleted === true ? "has since been deleted" : meta?.archivedAt !== undefined ? "is now archived" : activity === undefined ? "is now idle" : `is ${activity}`;
	return `${head}${failure.withoutAdvice} It has been continued since and ${state}.${failure.usage}`;
}

// ---- Waiting for a sub-chat instead of being woken

/**
 * For `sub_chats` with `wait`: the results of this conversation's sub-chats that arrived and were not yet handed over,
 * or, when there are none, the next one to arrive. They are taken: the agent is not woken for them as well. "none"
 * when nothing is left to wait for. `chats` narrows it to those sub-chats.
 */
export async function nextSubChats(conversationId: number, chats: number[] | undefined, context: Context): Promise<{ text: string }[] | "none"> {
	const wanted = (item: { kind: WakeKind; ref: string }) => item.kind === "subchat" && (chats === undefined || chats.length === 0 || chats.includes(Number(item.ref)));
	for (;;) {
		// The reports of runs that ended and woke nobody (reports.ts) are taken too; none outside a project.
		const unread = await unreadReports(conversationId, chats);
		const taken = await commitWakes(async (tx, doc) => {
			const list = doc.arrived[String(conversationId)] ?? [];
			const mine = list.filter(wanted);
			const loose = unread.filter((item) => !list.some((each) => each.report === item.report));
			if (mine.length === 0 && loose.length === 0) return [];
			const given: Arrived[] = [];
			// A report is given only if `settle` says so, and taken from wherever it waits.
			for (const item of [...mine, ...loose]) if (item.report === undefined || (await settle(tx, item.report, { by: "wait", conversationId })).give) given.push(item);
			const rest = (doc.arrived[String(conversationId)] ?? []).filter((item) => !wanted(item));
			if (rest.length === 0) delete doc.arrived[String(conversationId)];
			else doc.arrived[String(conversationId)] = rest;
			if (loose.length > 0) given.sort((a, b) => a.at - b.at);
			return given.map((item) => ({ text: resultText(item, host?.conversations() ?? {}) }));
		});
		if (taken.length > 0) return taken;
		if (!Object.values(mirror.watching).some((each) => each.conversationId === conversationId && wanted(each))) return "none";
		let listener: (() => void) | undefined;
		try {
			await awaitWithContext(
				new Promise<void>((resolve) => {
					listener = resolve;
					const set = listeners.get(conversationId) ?? new Set();
					set.add(resolve);
					listeners.set(conversationId, set);
				}),
				context,
			);
		} finally {
			if (listener !== undefined) listeners.get(conversationId)?.delete(listener);
		}
	}
}

/** The sub-chats a conversation is waiting on without waiting in a call: for `sub_chats`' list. */
export function watchedSubChats(conversationId: number): number[] {
	return Object.values(mirror.watching)
		// A run whose report will not wake the agent (reports.ts) is not one whose answer comes as a message.
		.filter((each) => each.conversationId === conversationId && each.kind === "subchat" && wakeFor(each) !== "never")
		.map((each) => Number(each.ref));
}

// ---- Waking

function deliver(id: number): Promise<void> {
	if (delivering.has(id)) {
		again.add(id);
		return Promise.resolve();
	}
	delivering.add(id);
	return deliverNow(id)
		.catch((error) => engine?.log("could not wake conversation", id, error instanceof Error ? error.message : error))
		.finally(() => {
			delivering.delete(id);
			if (again.delete(id)) void deliver(id);
		});
}

/** Look again at `at`, for a hold that ends then. */
function lookAgainAt(id: number, at: number): void {
	clearTimeout(timers.get(id));
	const timer = setTimeout(() => {
		timers.delete(id);
		void deliver(id);
	}, Math.max(0, Math.min(at - Date.now(), 2_000_000_000)));
	timer.unref();
	timers.set(id, timer);
}

async function hold(id: number, why: Hold["why"], data: Record<string, unknown>): Promise<void> {
	if (mirror.held[String(id)]?.why === why) return;
	await change((doc) => void (doc.held[String(id)] = { why, since: Date.now() }));
	await note(id, { held: why, ...data });
}

async function deliverNow(id: number): Promise<void> {
	if (!ready || engine === undefined) return;
	const waiting = mirror.arrived[String(id)] ?? [];
	if (waiting.length === 0) return;
	// A worker is given an answer only while its run goes, steering it; once the run has ended, its parent is (#507).
	const worker = engine.library().conversations[String(id)]?.parent !== undefined;
	if (worker && workerDone(id)) return relay(id);
	const gone = putAway(id);
	if (gone !== undefined) return letGo(id, gone);
	// Delivered when the answer ends: the end of a run is a change to what is running, which looks again.
	if (!worker && engine.busy(id)) return;
	const held = mirror.held[String(id)];
	if (held?.why === "stopped") return;
	const over = engine.overBudget();
	if (over !== undefined) {
		await hold(id, "budget", { budget: over });
		lookAgainAt(id, Date.now() + BUDGET_RECHECK_MS);
		return;
	}
	const recent = (mirror.woken[String(id)] ?? []).filter((at) => at > Date.now() - HOUR);
	if (recent.length >= WAKES_PER_HOUR) {
		const until = capEnds(id)!;
		await hold(id, "cap", { until, perHour: WAKES_PER_HOUR });
		lookAgainAt(id, until);
		return;
	}
	const harness = engine.harness();
	const context = engine.context();
	const conv = await harness.conversation(id as unknown as ConversationId, context);
	if (conv === undefined) return;
	const last = recent.length + 1 === WAKES_PER_HOUR;
	let woke = false;
	if (worker) {
		try {
			woke = await steer(id, conv, context);
		} catch (error) {
			// The run ended between looking and steering: the answer goes to the parent after all.
			if (error instanceof ConversationIdle || error instanceof ConversationBusy) return relay(id);
			throw error;
		}
		mirror = copy((await harness.snapshot(Wakes, context)) ?? empty());
		announce();
		for (const key of Object.keys(mirror.steered ?? {})) followSteer(key);
		if (woke) engine.log("gave sub-chat", id, "while it worked:", waiting.map((item) => item.label).join(", "));
		return;
	}
	try {
		await harness.commit(async (tx) => {
			const doc = await tx.doc(Wakes);
			const arrived = copy(doc.arrived[String(id)] ?? []);
			// A report goes only if `settle` gives it in this commit (reports.ts): one a wait or a read took, or one past a
			// project's limit, is left out, and stays as it is for `reports`.
			const items: Arrived[] = [];
			for (const item of arrived) if (item.report === undefined || (await settle(tx, item.report, { by: "wake", conversationId: id })).give) items.push(item);
			if (items.length < arrived.length) {
				const rest = (doc.arrived[String(id)] ?? []).filter((item) => item.report === undefined || items.some((each) => each.report === item.report));
				if (rest.length === 0) delete doc.arrived[String(id)];
				else doc.arrived[String(id)] = rest;
			}
			if (items.length === 0) return;
			const head = items.length === 1 ? "[pi² woke you: this ended while you were not answering.]" : `[pi² woke you: these ${items.length} ended while you were not answering, oldest first.]`;
			const limit = last
				? `\n\n[pi² has now woken you ${WAKES_PER_HOUR} times in the last hour, the most it does. Until an hour has passed since the first of them, or the person sends a message, what ends is kept for you rather than waking you.]`
				: "";
			const { conversations } = await tx.doc(Library);
			const content = `${head}\n\n${items.map((item) => resultText(item, conversations)).join("\n\n---\n\n")}${limit}`;
			const data = { items: items.map((item) => ({ kind: item.kind, ref: item.ref, label: item.label, ended: item.ended })) };
			await syncWorkForInput(tx, conv.id, conversations[String(id)]);
			// Refused, writing nothing, if a run started meanwhile: what arrived then goes at that run's end, with the rest.
			await conv.submit(tx, { type: "input", content, entry: { kind: WAKE_ENTRY, data }, whenBusy: "reject", requestId: `wake:${id}:${items[0]!.key}` });
			delete doc.arrived[String(id)];
			doc.woken[String(id)] = [...(doc.woken[String(id)] ?? []).filter((at) => at > Date.now() - HOUR), Date.now()];
			delete doc.held[String(id)];
			for (const [key, at] of Object.entries(doc.seen)) if (at < Date.now() - SEEN_MS) delete doc.seen[key];
			const meta = conversations[String(id)];
			if (meta !== undefined) meta.updatedAt = Date.now();
			woke = true;
		}, context);
	} catch (error) {
		if (error instanceof ConversationBusy) return;
		throw error;
	}
	mirror = copy((await harness.snapshot(Wakes, context)) ?? empty());
	announce();
	if (woke) engine.log("woke conversation", id, "for", waiting.map((item) => item.label).join(", "));
}

/**
 * Give what arrived for worker `id` to its run going now, as the next input it reads (a steer), with the line of news
 * for the orchestrator, in one commit. Throws `ConversationIdle` when no run is going, having written nothing.
 */
async function steer(id: number, conv: { id: ConversationId; submit(tx: Tx, draft: never): Promise<unknown> }, context: Context): Promise<boolean> {
	return engine!.harness().commit(async (tx) => {
		const doc = await tx.doc(Wakes);
		const items = copy(doc.arrived[String(id)] ?? []);
		if (items.length === 0) return false;
		const content = items.map((item) => item.text).join("\n\n---\n\n");
		const data = { items: items.map((item) => ({ kind: item.kind, ref: item.ref, label: item.label, ended: item.ended })), steered: true };
		const { conversations } = await tx.doc(Library);
		const submission = await conv.submit(tx, { type: "input", content, entry: { kind: WAKE_ENTRY, data }, whenBusy: "steer", whenIdle: "reject", requestId: `steer:${id}:${items[0]!.key}` } as never);
		await syncWorkForInput(tx, conv.id, conversations[String(id)]);
		doc.steered = { ...(doc.steered ?? {}), [String(submission)]: { conversationId: id, items } };
		delete doc.arrived[String(id)];
		doc.woken[String(id)] = [...(doc.woken[String(id)] ?? []).filter((at) => at > Date.now() - HOUR), Date.now()];
		delete doc.held[String(id)];
		const projects = await tx.doc(Projects);
		for (const item of items) {
			if (item.relay !== undefined && projects.projects[item.relay.news.projectId] !== undefined) await addNews(tx, item.relay.news.projectId, { kind: "need", text: item.relay.news.text, ref: item.ref });
		}
		return true;
	}, context);
}

/**
 * Wait for steer `key` (a submission) to be taken in by the worker's run, or let go with it (#507): one the run never
 * placed, because it was stopped or failed first, gives what it carried back to the worker's list, which then goes to
 * its parent, its run having ended.
 */
function followSteer(key: string): void {
	if (engine === undefined || steering.has(key)) return;
	steering.add(key);
	const running = engine;
	void (async () => {
		try {
			const submission = await running.harness().submission(Number(key) as unknown as SubmissionId, running.context());
			const settled = submission === undefined ? undefined : await submission.wait(running.context());
			const lost = settled === undefined || (settled.status === "unanswered" && (settled as { entry?: unknown }).entry === undefined);
			const back = await change((doc) => {
				const kept = doc.steered?.[key];
				if (kept === undefined) return undefined;
				delete doc.steered![key];
				if (!lost) return undefined;
				doc.arrived[String(kept.conversationId)] = [...kept.items, ...(doc.arrived[String(kept.conversationId)] ?? [])];
				return kept.conversationId;
			});
			if (back !== undefined) void deliver(back);
		} catch (error) {
			running.log("could not follow the answer given to sub-chat as it worked:", error instanceof Error ? error.message : error);
		} finally {
			steering.delete(key);
		}
	})();
}

/** A conversation put away is never woken: what it waited for, and what arrived for it, is let go. */
async function letGo(id: number, why: "archived" | "deleted"): Promise<void> {
	const dropped = await change((doc) => {
		const watches = Object.values(doc.watching).filter((each) => each.conversationId === id);
		for (const each of watches) {
			delete doc.watching[each.key];
			doc.seen[each.key] = Date.now();
		}
		const arrived = doc.arrived[String(id)] ?? [];
		delete doc.arrived[String(id)];
		delete doc.held[String(id)];
		return [...arrived.map((item) => ({ label: item.label, ended: item.ended })), ...watches.map((each) => ({ label: each.label, ended: null }))];
	});
	if (dropped.length === 0) return;
	engine?.log("conversation", id, "was", why, "so it will not be woken for", dropped.map((item) => item.label).join(", "));
	if (why === "archived") await note(id, { dropped: why, items: dropped });
}

/** The person stopped a conversation's agent, or turned waking off for one thing: `cancel` names what. */
async function cancel(id: number, key: string | undefined): Promise<void> {
	const dropped = await change((doc) => {
		const watches = Object.values(doc.watching).filter((each) => each.conversationId === id && (key === undefined || each.key === key));
		for (const each of watches) {
			delete doc.watching[each.key];
			doc.seen[each.key] = Date.now();
		}
		const arrived = doc.arrived[String(id)] ?? [];
		const taken = arrived.filter((item) => key === undefined || item.key === key);
		const rest = arrived.filter((item) => !taken.includes(item));
		if (rest.length === 0) delete doc.arrived[String(id)];
		else doc.arrived[String(id)] = rest;
		return [...taken.map((item) => item.label), ...watches.map((each) => each.label)];
	});
	if (dropped.length > 0) await note(id, { cancelled: dropped });
}

/** What the transcript shows for a `WAKE_ENTRY`: "pi² woke the agent: sub-chat 12 “Fix login” answered". */
export function wakeMarker(data: unknown): string {
	const items = (data !== null && typeof data === "object" && Array.isArray((data as { items?: unknown }).items) ? (data as { items: unknown[] }).items : []).filter(
		(item): item is { label: string; ended: string } => item !== null && typeof item === "object" && typeof (item as { label?: unknown }).label === "string",
	);
	// An answer given to a worker as it worked (#507) did not wake it.
	const steered = (data as { steered?: unknown } | null)?.steered === true;
	if (items.length === 0) return steered ? "pi² told the agent as it worked" : "pi² woke the agent";
	return `${steered ? "pi² told the agent as it worked" : "pi² woke the agent"}: ${items.map((item) => `${item.label} ${typeof item.ended === "string" ? item.ended : "ended"}`).join("; ")}`;
}

/** What a background command's id is, for the line's Output button, when the wake was for one command alone. */
export function wakeMarkerDetails(data: unknown): { background: { id: string } } | undefined {
	const items = data !== null && typeof data === "object" ? (data as { items?: unknown }).items : undefined;
	if (!Array.isArray(items) || items.length !== 1) return undefined;
	const item = items[0] as { kind?: unknown; ref?: unknown };
	return item?.kind === "background" && typeof item.ref === "string" && /^bg-[1-9][0-9]{0,8}$/.test(item.ref) ? { background: { id: item.ref } } : undefined;
}

const clock = (at: number) => {
	const d = new Date(at);
	return `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
};

/** What the transcript shows for a `WAKE_NOTE`. */
export function wakeNoteMarker(data: unknown): string {
	const entry = (data !== null && typeof data === "object" ? data : {}) as Record<string, unknown>;
	const labels = (value: unknown) =>
		Array.isArray(value) ? value.map((item) => (typeof item === "string" ? item : typeof item?.label === "string" ? item.label : "")).filter((label) => label !== "") : [];
	switch (entry.held) {
		case "stopped":
			return "You stopped the agent, so pi² will not wake it until you send a message. What ends meanwhile is kept for it.";
		case "budget":
			return `pi² did not wake the agent: ${typeof entry.budget === "string" ? entry.budget.replace(/\.$/, "") : "today's budget is used up"}. It is woken once there is budget again.`;
		case "cap":
			return `pi² has woken the agent ${typeof entry.perHour === "number" ? entry.perHour : WAKES_PER_HOUR} times in the last hour, the most it does. What ends now is kept for it, and given to it ${typeof entry.until === "number" ? `at ${clock(entry.until)}` : "within the hour"}, or after your next message.`;
	}
	if (entry.dropped !== undefined) {
		const named = labels(entry.items);
		return `The conversation was ${entry.dropped === "deleted" ? "deleted" : "archived"}, so pi² will not wake the agent${named.length === 0 ? "" : ` for ${named.join(", ")}`}.`;
	}
	if (entry.cancelled !== undefined) {
		const named = labels(entry.cancelled);
		return `You turned off waking the agent${named.length === 0 ? "" : ` for ${named.join(", ")}`}.`;
	}
	return "pi² changed when it wakes the agent";
}

export const wakes: Feature = (given, running) => {
	host = given;
	engine = running;
	return {
		start: async () => {
			await running.harness().commit(async (tx) => void (await tx.doc(Wakes)), running.context());
			mirror = copy((await running.harness().snapshot(Wakes, running.context())) ?? empty());
			// Once the engine has its usage and is about to listen: sub-chats followed again, and anything that arrived
			// while it was down (or as it stopped) handed over.
			void given.ready.then(() => {
				ready = true;
				for (const each of Object.values(mirror.watching)) if (each.kind === "subchat") follow(each);
				for (const key of Object.keys(mirror.steered ?? {})) followSteer(key);
				for (const id of Object.keys(mirror.arrived)) void deliver(Number(id));
			});
		},
		greeting: () => [event()],
		runsChanged: (working) => {
			for (const id of Object.keys(mirror.arrived)) if (!working.has(Number(id))) void deliver(Number(id));
		},
		usageChanged: () => {
			for (const [id, held] of Object.entries(mirror.held)) if (held.why === "budget") void deliver(Number(id));
		},
		messageSent: (id) => {
			// The person is there: the hold for their Stop, and the hourly count, start again. What arrived goes once the
			// answer to their message ends.
			if (mirror.held[String(id)] === undefined && (mirror.woken[String(id)] ?? []).length === 0) return;
			void change((doc) => {
				delete doc.held[String(id)];
				delete doc.woken[String(id)];
			});
		},
		stopped: (id) => {
			const waits = Object.values(mirror.watching).some((each) => each.conversationId === id) || (mirror.arrived[String(id)] ?? []).length > 0;
			// A worker stopped has ended its run: what waits for it goes to its parent instead (#507).
			if (waits && running.library().conversations[String(id)]?.parent !== undefined) void relay(id);
			else if (waits) void hold(id, "stopped", {});
		},
		putAwayChanged: () => {
			const ids = new Set([...Object.values(mirror.watching).map((each) => each.conversationId), ...Object.keys(mirror.arrived).map(Number)]);
			for (const id of ids) {
				const gone = putAway(id);
				if (gone === undefined) continue;
				// A worker put away has ended its run: what waits for it goes to its parent, which may be put away too (#507).
				if (running.library().conversations[String(id)]?.parent !== undefined) {
					void deliver(id);
					continue;
				}
				// Its sub-chats that work without being waited for stop with it, as its background commands do.
				const children = Object.values(mirror.watching).filter((each) => each.conversationId === id && each.kind === "subchat");
				void letGo(id, gone).then(async () => {
					for (const each of children) {
						const conv = await running.harness().conversation(Number(each.ref) as unknown as ConversationId, running.context());
						await conv?.abort(running.context()).catch(() => {});
					}
				});
			}
		},
		handlers: {
			/** The person turns waking off: for one thing (`key`), or everything the conversation waits on. */
			"wakes.cancel": async (params) => {
				if (typeof params.conversationId !== "number") throw new Error("Missing conversationId");
				await cancel(params.conversationId, typeof params.key === "string" ? params.key : undefined);
				return {};
			},
			/** The person lets the agent be woken again after their Stop, without sending a message. */
			"wakes.resume": async (params) => {
				if (typeof params.conversationId !== "number") throw new Error("Missing conversationId");
				const id = params.conversationId;
				if (mirror.held[String(id)]?.why === "stopped") await change((doc) => void delete doc.held[String(id)]);
				void deliver(id);
				return {};
			},
		},
	};
};
