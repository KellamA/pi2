// Reports, and when one wakes the orchestrator (#463; docs/projects.md 3.10, 5.6 and 8.2).
//
// A report is how one run of a sub-chat of a project's orchestrator ended: its answer, or that it failed or was stopped.
// Each run `delegate` starts from the orchestrator's conversation has one, by its submission, in `pi2.reports`, from
// the moment it starts. `settle` is the one function that decides what becomes of a report, and nothing else sets
// `delivered`: when its run ends, when a wait (`delegate` waiting for it, `sub_chats` with `wait`) or `reports` `read`
// asks for it, and when a wake that carries it is submitted (wakes.ts). So a report is given to the orchestrator once,
// whichever of those comes first.
//
// When a run ends and no wait asks for it, its watch's `wake` decides (wakes.ts keeps the watch), or else the project's
// `wakeOnReports`, the person's switch (8.2): `each` wakes as today, `never` wakes nobody, `all` wakes once when its
// batch's last run has ended, `failure` only at the batch's first run that failed or was stopped. A report that woke
// nobody stays undelivered, with a line of news for the catch-up (#466), and its text comes with `reports` `read`.
//
// Outside a project, with the preview off, and in an archived or deleted project, nothing here changes anything: a run
// there has no report, or its report wakes as wakes.md says.
//
// What later issues fill in:
// - The catch-up delivering the news a report adds (#466). Until then the orchestrator reads reports with `reports`.
// - `reports` `wake` is a change with a line and Undo (5.6, 5.9) in #465's record of changes (changes.ts), which
//   applies its Undo through `setWakeChoicesIn`.
// - `work` `assign` (#467) starts runs with a report too, through `reportRun` with `work`.

import { randomUUID } from "node:crypto";
import type { Context } from "@earendil-works/chord/context";
import { type CommitChange, defineDoc, defineTool, type SettledSubmissionRecord, type SubmissionId, type ToolExecutionApi, type ToolExecutionResult, type Tx } from "@earendil-works/pi-durable";
import { arr, int, obj, opt, str } from "@earendil-works/pi-schema";
import { type Host, subChatResult } from "./extensions.ts";
import { reportPastLimit } from "./projectlimits.ts";
import type { Engine, Feature } from "./features.ts";
import { waitForChat } from "./heed.ts";
import { allProjects, inProject, type Project, PROJECT_ARCHIVED, Projects, projectsOn, requirePreview } from "./projects.ts";
import { type Arrived, commitWakes, heard, reloadWakes, reportArrival, resultText, wakeUp, type Watch, watchedRuns, Wakes } from "./wakes.ts";
import { type ChangeBy, inverseOf, type Op, record } from "./changes.ts";

// ---- The document (3.10)

export type ReportWake = "each" | "all" | "failure" | "never";
export const REPORT_WAKES: readonly ReportWake[] = ["each", "all", "failure", "never"];

/** How one run of a sub-chat of an orchestrator's conversation ended. Kept seven days after it was delivered. */
export type Report = {
	/** The run: the sub-chat's submission that `delegate` (or `work assign`) made. Unique. */
	submissionId: number;
	conversationId: number;
	agentId: string;
	title: string;
	/** The batch it was put in with `reports` (`wake`), if any. */
	batch: string | null;
	/** The work item the sub-chat was handed with `work assign`, if any. */
	work: number | null;
	/** Null while the run goes on. */
	ended: { at: number; outcome: "answered" | "failed" | "stopped" } | null;
	/**
	 * Null until it is delivered: given to the orchestrator once, by exactly one of these, in the commit that gives it.
	 * `wake`: a wake carried it. `wait`: `delegate` waiting for it, or `sub_chats` with `wait`, returned it. `read`:
	 * `reports` with `read` returned it.
	 */
	delivered: { by: "wake" | "wait" | "read"; at: number; conversationId: number } | null;
};

export type ReportsDoc = { projects: Record<string, Report[]> };

const empty = (): ReportsDoc => ({ projects: {} });

/** The reports, by project. Made by the first report, never at start: with no project, nothing new is written. */
export const Reports = defineDoc<ReportsDoc>({
	kind: "pi2.reports",
	version: 1,
	scope: "session",
	initial: empty,
	checkpointWhen: () => true,
});

/** What a `reports` read gave, kept with its call, so that the call run again after a crash gives the same (5.1). */
const Given = defineDoc<{ text: string | null }>({
	kind: "pi2.reportsGiven",
	version: 1,
	scope: "task",
	initial: () => ({ text: null }),
	checkpointWhen: () => true,
});

/** How long a delivered report is kept, and sent in the `reports` event. */
const KEEP_MS = 7 * 86_400_000;

let engine: Engine | undefined;
let host: Host | undefined;
/** The document as last stored. */
let mirror: ReportsDoc = empty();
/** Set once the engine is ready to follow runs. */
let ready = false;
/** Runs a `delegate` call is waiting for now: the wait takes their reports (3.10, step 2). In memory: the call, run again, waits again. */
const waited = new Set<number>();
/** Runs whose end this engine is waiting for. */
const following = new Set<number>();

const copy = <T>(value: T): T => JSON.parse(JSON.stringify(value));

// ---- Which runs have a report

/**
 * The project whose orchestrator's conversation `conversation` is, now or earlier, with the preview on and the project
 * neither archived nor deleted. Only a run started from such a conversation has a report.
 */
export function orchestratorOf(conversation: number): Project | undefined {
	const project = inProject(conversation);
	return project !== undefined && (project.conversation === conversation || project.earlier.includes(conversation)) ? project : undefined;
}

function locate(doc: ReportsDoc, submissionId: number): { projectId: string; report: Report } | undefined {
	for (const [projectId, list] of Object.entries(doc.projects)) {
		const report = list.find((each) => each.submissionId === submissionId);
		if (report !== undefined) return { projectId, report };
	}
	return undefined;
}

/** The report of run `submissionId`, as last stored, if it has one. */
export function reportOf(submissionId: number | undefined): Report | undefined {
	return submissionId === undefined ? undefined : locate(mirror, submissionId)?.report;
}

/**
 * When a watched run's report wakes the orchestrator, as it stands now: its watch's `wake`, or the project's switch
 * (on: `each`; off: `never`). Undefined for a run with no report, which wakes as wakes.md says; `each` for one whose
 * project is out of the preview now (switched off, archived or deleted), which does too.
 */
export function wakeFor(watch: Pick<Watch, "conversationId" | "submissionId" | "wake">): ReportWake | undefined {
	if (reportOf(watch.submissionId) === undefined) return undefined;
	const project = inProject(watch.conversationId);
	if (project === undefined) return "each";
	return watch.wake ?? (project.settings.wakeOnReports ? "each" : "never");
}

// ---- The one function that decides

export type Ask =
	/** The run ended (with `outcome`), or something about it changed after it ended (a watch made for it late). */
	| { by: "end"; outcome?: NonNullable<Report["ended"]>["outcome"] }
	/** A wait asks for it: `again` for `delegate` waiting for its own run, which gives it again when run again after a crash. */
	| { by: "wait"; conversationId: number; again?: boolean }
	| { by: "read"; conversationId: number }
	/** A wake being submitted carries it. */
	| { by: "wake"; conversationId: number };

export type Settled = {
	/** For a wait, a read or a wake: whether the report is given now. */
	give: boolean;
	/** At a run's end: the conversation to wake, and the reports the wake carries, oldest first. */
	to?: number;
	wake: number[];
};

const clock = (at: number) => {
	const d = new Date(at);
	return `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
};
const outcomeWords = (outcome: NonNullable<Report["ended"]>["outcome"]) => (outcome === "answered" ? "answered" : outcome === "failed" ? "failed" : "was stopped");
const agentName = (report: Report) => host?.agent(report.agentId)?.name ?? "an agent that was deleted";

/** The line of news for a report not delivered when its run ended (6.4). */
const newsLine = (report: Report) => `Sub-chat ${report.conversationId} “${report.title}” (${agentName(report)}) ${outcomeWords(report.ended!.outcome)} at ${clock(report.ended!.at)}; not read yet.`;
const isNewsOf = (report: Report) => (news: { kind: string; ref: string; at: number }) => news.kind === "report" && news.ref === String(report.conversationId) && news.at === report.ended?.at;

/**
 * Decide what becomes of the report of run `submissionId`, inside the commit `tx` that does it (3.10). Nothing else sets
 * `delivered`. In order: one already delivered is given to no one again; a wait that asks for it takes it; a read takes
 * it; at its run's end, with no wait asking, its watch's choice (or the project's switch) decides whom it wakes, and what
 * wakes nobody stays undelivered, with a line of news. A run with no report is given as today.
 */
export async function settle(tx: Tx, submissionId: number, ask: Ask): Promise<Settled> {
	const doc = await tx.doc(Reports);
	const found = locate(doc as ReportsDoc, submissionId);
	if (found === undefined) return { give: true, wake: [] };
	const { projectId, report } = found;
	const wakes = await tx.doc(Wakes);
	const now = Date.now();

	const deliver = async (by: "wake" | "wait" | "read", conversationId: number) => {
		report.delivered = { by, at: now, conversationId };
		// It is not waiting in a wake any more, and is no longer news.
		for (const [key, list] of Object.entries(wakes.arrived)) {
			const rest = list.filter((item) => item.report !== submissionId);
			if (rest.length === list.length) continue;
			if (rest.length === 0) delete wakes.arrived[key];
			else wakes.arrived[key] = rest;
		}
		const projects = await tx.doc(Projects);
		const news = projects.news[projectId];
		if (news !== undefined && news.some(isNewsOf(report))) projects.news[projectId] = news.filter((each) => !isNewsOf(report)(each));
	};

	if (ask.by === "wait") {
		if (report.delivered !== null) return { give: ask.again === true && report.delivered.by === "wait", wake: [] };
		await deliver("wait", ask.conversationId);
		return { give: true, wake: [] };
	}
	if (ask.by === "read") {
		if (report.delivered !== null || report.ended === null || waited.has(submissionId)) return { give: false, wake: [] };
		await deliver("read", ask.conversationId);
		return { give: true, wake: [] };
	}
	if (ask.by === "wake") {
		if (report.delivered !== null || (await reportPastLimit(tx, projectId, ask.conversationId))) return { give: false, wake: [] };
		await deliver("wake", ask.conversationId);
		return { give: true, wake: [] };
	}

	// The run ended.
	if (report.ended === null) {
		if (ask.outcome === undefined) return { give: false, wake: [] };
		report.ended = { at: now, outcome: ask.outcome };
	}
	const watch = Object.values(wakes.watching).find((each) => each.kind === "subchat" && each.submissionId === submissionId);
	if (watch !== undefined && (report.delivered !== null || !waited.has(submissionId))) {
		// Its end is seen to here: nothing else wakes anyone for it.
		delete wakes.watching[watch.key];
		wakes.seen[watch.key] = now;
	}
	if (report.delivered !== null || waited.has(submissionId)) return { give: false, wake: [] };
	const list = doc.projects[projectId] as Report[];
	let give: Report[] = [];
	if (watch !== undefined && !(await reportPastLimit(tx, projectId, watch.conversationId))) {
		const project = inProject(watch.conversationId);
		const mode: ReportWake = project === undefined ? "each" : (watch.wake ?? (project.settings.wakeOnReports ? "each" : "never"));
		const batch = report.batch === null ? [report] : list.filter((each) => each.batch === report.batch);
		if (mode === "each") give = [report];
		else if (mode === "all") give = batch.every((each) => each.ended !== null) ? batch.filter((each) => each.delivered === null) : [];
		else if (mode === "failure" && report.ended.outcome !== "answered") {
			// The first of the batch that failed or was stopped wakes it, with those that ended before; the later ones do not.
			const first = !batch.some((each) => each !== report && each.ended !== null && each.ended.outcome !== "answered");
			give = first ? batch.filter((each) => each.ended !== null && each.delivered === null) : [];
		}
	}
	// Each report not delivered when its run ended is news, once (6.4); delivering it takes the news away.
	const projects = await tx.doc(Projects);
	if (projects.projects[projectId] !== undefined && !(projects.news[projectId] ?? []).some(isNewsOf(report))) {
		projects.news[projectId] = [...(projects.news[projectId] ?? []), { id: `w${projects.nextNews}`, at: report.ended.at, kind: "report", text: newsLine(report), ref: String(report.conversationId) }];
		projects.nextNews += 1;
	}
	give.sort((a, b) => a.ended!.at - b.ended!.at || a.submissionId - b.submissionId);
	return { give: false, ...(give.length > 0 && watch !== undefined ? { to: watch.conversationId } : {}), wake: give.map((each) => each.submissionId) };
}

// ---- Starting, following and ending runs

/** Read the document again, as stored, and tell the apps if what they are sent changed. */
let reads = 0;
let sent = "";
async function reload(): Promise<void> {
	if (engine === undefined) return;
	const read = ++reads;
	const stored = await engine.harness().snapshot(Reports, engine.context());
	if (read !== reads) return;
	mirror = stored === undefined ? empty() : copy(stored as ReportsDoc);
	announce();
}

/** The `reports` event (4.3): undelivered reports, and those of the last seven days. */
function event() {
	const since = Date.now() - KEEP_MS;
	const projects: Record<string, Report[]> = {};
	for (const [projectId, list] of Object.entries(mirror.projects)) {
		const kept = list.filter((each) => each.delivered === null || each.delivered.at > since);
		if (kept.length > 0) projects[projectId] = copy(kept);
	}
	return { event: "reports" as const, projects };
}
function announce(): void {
	const next = event();
	const line = JSON.stringify(next);
	if (line === sent) return;
	sent = line;
	engine?.broadcast(next);
}

export type Run = { submissionId: number; conversationId: number; agentId: string; title: string; work?: number };

/** Assignment can store the report with its first input, so even a crash before the reply cannot lose it. */
export async function stageReportRun(tx: Tx, projectId: string, run: Run): Promise<void> {
	const doc = await tx.doc(Reports);
	if (locate(doc as ReportsDoc, run.submissionId) !== undefined) return;
	const since = Date.now() - KEEP_MS;
	const list = (doc.projects[projectId] ?? []).filter((each) => each.delivered === null || each.delivered.at > since);
	list.push({ submissionId: run.submissionId, conversationId: run.conversationId, agentId: run.agentId, title: run.title, batch: null, work: run.work ?? null, ended: null, delivered: null });
	doc.projects[projectId] = list;
}

/**
 * Run `run`, started from conversation `parent`, has a report if `parent` is a project's orchestrator's conversation:
 * keep it, and follow the run. Once only for a run, so a call run again after a crash may call it again. Before its
 * watch is made (wakes.ts), so that the watch is known to be the report's.
 */
export async function reportRun(parent: number, run: Run): Promise<void> {
	const project = orchestratorOf(parent);
	if (project === undefined || engine === undefined) return;
	if (reportOf(run.submissionId) === undefined) {
		await engine.harness().commit((tx) => stageReportRun(tx, project.id, run), engine.context());
		await reload();
	}
	const report = reportOf(run.submissionId);
	if (report !== undefined) follow(report);
}

/**
 * `delegate` waiting for its run `run`, started from `parent`: `waitForChat` (heed.ts), and the run's report, if it has
 * one, taken by the wait (3.10, step 2). `taken` is false only when the report was already given another way.
 */
export async function waitForRun(api: ToolExecutionApi, parent: number, run: Run, context: Context): Promise<{ settled: SettledSubmissionRecord; taken: boolean } | { messaged: true }> {
	await reportRun(parent, run);
	if (reportOf(run.submissionId) === undefined) {
		const outcome = await waitForChat(api, run.conversationId, run.submissionId as unknown as SubmissionId, context);
		return "messaged" in outcome ? outcome : { ...outcome, taken: true };
	}
	waited.add(run.submissionId);
	try {
		const outcome = await waitForChat(api, run.conversationId, run.submissionId as unknown as SubmissionId, context);
		if ("messaged" in outcome) return outcome;
		const taken = await api.commit(async (tx) => (await settle(tx, run.submissionId, { by: "wait", conversationId: parent, again: true })).give, context);
		return { ...outcome, taken };
	} finally {
		waited.delete(run.submissionId);
		await afterCommit();
	}
}

/**
 * What `delegate` says of a run it hands over without waiting, in place of "Its answer will come to you as a message…",
 * when that is not so (5.6): in an orchestrator's conversation whose project's reports do not wake it. Undefined: as today.
 */
export function handOffWords(parent: number): string | undefined {
	const project = orchestratorOf(parent);
	if (project === undefined || project.settings.wakeOnReports) return undefined;
	return "Its report waits for you unread; you are not woken for it (the project's setting). To be woken, use reports with action wake.";
}

/** After a commit made elsewhere (a tool's) that `settle` took part in: both mirrors read again. */
async function afterCommit(): Promise<void> {
	await reloadWakes();
	await reload();
}

const outcomeOf = (settled: SettledSubmissionRecord | undefined): NonNullable<Report["ended"]>["outcome"] => {
	if (settled !== undefined && settled.status === "done" && settled.type === "input") return "answered";
	return settled !== undefined && "reason" in settled && settled.reason === "aborted" ? "stopped" : "failed";
};

/** What a wake, a wait or a read gives of a report: what `delegate` would have answered, as a wake words it. */
async function arrival(report: Report, given?: SettledSubmissionRecord): Promise<Arrived> {
	const running = engine!;
	let settled = given;
	if (settled === undefined) {
		const submission = await running.harness().submission(report.submissionId as unknown as SubmissionId, running.context());
		settled = submission === undefined ? undefined : await submission.wait(running.context());
	}
	const result = await subChatResult(host!, running.harness(), report.conversationId, host!.agent(report.agentId)?.name ?? "The agent", settled, running.context());
	return reportArrival(report, result, report.ended?.at ?? Date.now());
}

/** The text a wait or a read gives of each report. */
const textOf = (item: Arrived) => resultText(item, host?.conversations() ?? {});

function follow(report: Report): void {
	if (!ready || engine === undefined || report.ended !== null || following.has(report.submissionId)) return;
	const running = engine;
	following.add(report.submissionId);
	void (async () => {
		try {
			const submission = await running.harness().submission(report.submissionId as unknown as SubmissionId, running.context());
			const settled = submission === undefined ? undefined : await submission.wait(running.context());
			await ended(report.submissionId, settled);
		} catch (error) {
			running.log("could not follow the report of sub-chat", report.conversationId, error instanceof Error ? error.message : error);
		} finally {
			following.delete(report.submissionId);
		}
	})();
}

/**
 * Run `submissionId` ended (`settled`), or, with no `settled`, something about it changed since it ended (a watch made
 * for it late): `settle` decides, and the wake it asks for is put where wakes.ts hands it over.
 */
async function ended(submissionId: number, settled?: SettledSubmissionRecord | "again"): Promise<void> {
	const report = reportOf(submissionId);
	if (report === undefined || engine === undefined) return;
	const outcome = settled === "again" ? undefined : outcomeOf(settled);
	// The texts a wake may carry, made first: this run's and those of its batch that ended and were not given yet.
	const texts = new Map<number, Arrived>();
	const ending = { ...report, ended: report.ended ?? { at: Date.now(), outcome: outcome ?? "failed" } };
	texts.set(submissionId, await arrival(ending, settled === "again" ? undefined : settled));
	const list = Object.values(mirror.projects).find((each) => each.some((one) => one.submissionId === submissionId)) ?? [];
	for (const other of list) {
		if (other.submissionId !== submissionId && report.batch !== null && other.batch === report.batch && other.ended !== null && other.delivered === null) texts.set(other.submissionId, await arrival(other));
	}
	const decided = await commitWakes(async (tx, wakes) => {
		const result: Settled & { missing?: number[] } = await settle(tx, submissionId, settled === "again" ? { by: "end" } : { by: "end", outcome });
		if (result.to === undefined) return result;
		const items = result.wake.map((id) => texts.get(id)).filter((item): item is Arrived => item !== undefined);
		// The run's own text carries the time it ended, as stored.
		const stored = locate((await tx.doc(Reports)) as ReportsDoc, submissionId)?.report;
		for (const item of items) if (item.report === submissionId && stored?.ended) item.at = stored.ended.at;
		if (items.length > 0) wakes.arrived[String(result.to)] = [...(wakes.arrived[String(result.to)] ?? []), ...items];
		return { ...result, missing: result.wake.filter((id) => !texts.has(id)) };
	});
	await reload();
	// A run of the batch that ended as this one was decided: its text is made now, and joins the wake if it was not given meanwhile.
	const missing = decided.missing ?? [];
	if (decided.to !== undefined && missing.length > 0) {
		const late: Arrived[] = [];
		for (const id of missing) {
			const other = reportOf(id);
			if (other !== undefined) late.push(await arrival(other));
		}
		await commitWakes(async (tx, wakes) => {
			const doc = (await tx.doc(Reports)) as ReportsDoc;
			const still = late.filter((item) => locate(doc, item.report!)?.report.delivered === null);
			if (still.length > 0) wakes.arrived[String(decided.to)] = [...(wakes.arrived[String(decided.to)] ?? []), ...still];
		});
	}
	const parent = host?.conversations()[String(report.conversationId)]?.parent;
	if (parent !== undefined) heard(parent);
	if (decided.to !== undefined) wakeUp(decided.to);
}

/** A watch was made for a run that has a report (wakes.ts): if the run has ended already, decide again now, with the watch. */
export function reportWatched(submissionId: number | undefined): void {
	const report = reportOf(submissionId);
	if (report === undefined || report.ended === null || report.delivered !== null) return;
	void ended(report.submissionId, "again").catch((error) => engine?.log("could not settle the report of sub-chat", report.conversationId, error instanceof Error ? error.message : error));
}

/**
 * For `sub_chats` with `wait` in conversation `conversationId` (wakes.ts): the reports of its sub-chats (or of `chats`)
 * whose runs ended and that were not given yet, with the texts a wait gives. The wait takes them through `settle`.
 */
export async function unreadReports(conversationId: number, chats: number[] | undefined): Promise<Arrived[]> {
	const conversations = host?.conversations() ?? {};
	const found: Arrived[] = [];
	for (const list of Object.values(mirror.projects)) {
		for (const report of list) {
			if (report.ended === null || report.delivered !== null || waited.has(report.submissionId)) continue;
			if (conversations[String(report.conversationId)]?.parent !== conversationId) continue;
			if (chats !== undefined && chats.length > 0 && !chats.includes(report.conversationId)) continue;
			found.push(await arrival(report));
		}
	}
	return found;
}

// ---- Choosing when runs going now wake the orchestrator (5.6, and the person's `reports.wake`)

const NUMBERS = ["no", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"];
const listed = (ids: number[]) => (ids.length <= 1 ? ids.map(String).join("") : `${ids.slice(0, -1).join(", ")} and ${ids.at(-1)}`);
const chatsWord = (ids: number[]) => `${ids.length === 1 ? "Sub-chat" : "Sub-chats"} ${listed(ids)}`;

/**
 * Set when the reports of the runs going now of `chats`, sub-chats of project `projectId`'s orchestrator, wake it.
 * Several with `all` or `failure` become one batch. Answers what was set, in words, and whether nothing could be.
 */
async function chooseWake(projectId: string, chats: number[], when: ReportWake, by?: Extract<ChangeBy, { kind: "agent" }>): Promise<{ text: string; isError?: true; change?: number }> {
	const going = (chat: number) =>
		(mirror.projects[projectId] ?? []).filter((each) => each.conversationId === chat && each.ended === null).sort((a, b) => b.submissionId - a.submissionId)[0];
	const watches = watchedRuns();
	const chosen: { chat: number; report: Report; watch: Watch }[] = [];
	const notGoing: number[] = [];
	const waitedFor: number[] = [];
	for (const chat of [...new Set(chats)]) {
		const report = going(chat);
		const watch = report === undefined ? undefined : watches.find((each) => each.submissionId === report.submissionId);
		if (report === undefined) notGoing.push(chat);
		else if (watch === undefined) waitedFor.push(chat);
		else chosen.push({ chat, report, watch });
	}
	const notes = [
		...(notGoing.length === 0 ? [] : [`${chatsWord(notGoing)} ${notGoing.length === 1 ? "has" : "have"} no run going now: reports with action list shows what is waiting to be read.`]),
		...(waitedFor.length === 0
			? []
			: [`${chatsWord(waitedFor)} ${waitedFor.length === 1 ? "is" : "are"} not watched: delegate is waiting for ${waitedFor.length === 1 ? "it" : "them"}, or the person turned waking off for ${waitedFor.length === 1 ? "it" : "them"}.`]),
	];
	if (chosen.length === 0) return { text: notes.join(" ") || "Name the sub-chats in `chats`.", isError: true };
	const batch = chosen.length > 1 && (when === "all" || when === "failure") ? `b-${randomUUID()}` : null;
	const submissions = chosen.map(({ report }) => report.submissionId);
	const change = await commitWakes(async (tx) => {
		const before = await wakeChoicesIn(tx, submissions);
		await setWakeChoicesIn(tx, submissions.map((submissionId) => ({ submissionId, wake: when, batch })));
		// An agent's choice is a change, with a line and its Undo, which puts the choice back (5.9). One that changes
		// nothing, as the same call run again after a crash, is none.
		if (by === undefined || before.every((one) => one?.wake === when && one.batch === batch)) return undefined;
		const op: Op = { kind: "wake.choice", submissions, before: before.map((one) => one?.wake ?? null), after: when, batches: { before: before.map((one) => one?.batch ?? null), after: submissions.map(() => batch) } };
		return (await record(tx, projectId, { by, op, inverse: inverseOf(op), summary: `Chose waking for ${chatsWord(chosen.map((each) => each.chat)).toLowerCase()}: ${when}` })).id;
	});
	await reload();
	const ids = chosen.map((each) => each.chat);
	const one = ids.length === 1;
	const count = ids.length <= 10 ? NUMBERS[ids.length] : String(ids.length);
	const said = (() => {
		switch (when) {
			case "each":
				return one ? `You will be woken when sub-chat ${ids[0]} ends.` : `You will be woken for each of sub-chats ${listed(ids)} as it ends.`;
			case "never":
				return `You will not be woken for ${one ? "sub-chat" : "sub-chats"} ${listed(ids)}: ${one ? "its report waits" : "their reports wait"} for you unread, for reports with action read.`;
			case "all":
				return one ? `You will be woken when sub-chat ${ids[0]} has ended.` : `${chatsWord(ids)} are one batch: you will be woken once, when all ${count} have ended.`;
			case "failure":
				return one
					? `You will be woken for sub-chat ${ids[0]} only if it fails or is stopped; if it answers, its report waits for you unread.`
					: `${chatsWord(ids)} are one batch: you will be woken only if one fails or is stopped, once, with the reports of those that ended before it; the others wait for you unread.`;
		}
	})();
	return { text: [said, ...notes].join(" "), ...(change === undefined ? {} : { change }) };
}

/**
 * The waking chosen for runs `submissions` as stored in the commit `tx`: each one's watch's `wake` and `batch`, or
 * undefined for a run no longer watched. For `reports` `wake` and the operation `wake.choice` (changes.ts).
 */
export async function wakeChoicesIn(tx: Tx, submissions: number[]): Promise<({ wake: ReportWake | null; batch: string | null } | undefined)[]> {
	const watching = Object.values((await tx.doc(Wakes)).watching);
	return submissions.map((id) => {
		const watch = watching.find((each) => each.kind === "subchat" && each.submissionId === id);
		return watch === undefined ? undefined : { wake: watch.wake ?? null, batch: watch.batch ?? null };
	});
}

/** Set the waking of runs, in the commit `tx`: what `reports` `wake` does, and the operation `wake.choice` (changes.ts). */
export async function setWakeChoicesIn(tx: Tx, choices: { submissionId: number; wake: ReportWake | null; batch: string | null }[]): Promise<void> {
	const wakes = await tx.doc(Wakes);
	const doc = (await tx.doc(Reports)) as ReportsDoc;
	for (const choice of choices) {
		const stored = Object.values(wakes.watching).find((each) => each.kind === "subchat" && each.submissionId === choice.submissionId);
		if (stored !== undefined) {
			if (choice.wake === null) delete stored.wake;
			else stored.wake = choice.wake;
			if (choice.batch === null) delete stored.batch;
			else stored.batch = choice.batch;
		}
		const kept = locate(doc, choice.submissionId)?.report;
		if (kept !== undefined) kept.batch = choice.batch;
	}
}

// ---- The orchestrator's tool (5.6)

export const REPORTS_DESCRIPTION =
	"See the reports of the sub-chats you hand work to, and choose when they wake you. A report is how one run of a sub-chat ended: its answer, or that it failed or was stopped. Each is given to you once: by waking you, by a wait (delegate waiting for it, sub_chats with wait), or by reading it here. Actions:\n" +
	"- list: the reports you have not read yet, then the sub-chats working now, with how each one's report will reach you.\n" +
	"- read: the reports not read yet, or those of the sub-chats in `chats`, each as delegate would have given it.\n" +
	"- wake: choose when the reports of the sub-chats in `chats`, working now, wake you, with `when`: each (as each ends), all (once, when all of them have ended), failure (only if one fails or is stopped, with the reports of those that ended before it), or never (they wait for you unread). " +
	"Several chats with all or failure become one batch. Whether reports wake you otherwise is the person's setting for the project; this chooses only for the runs you name.";

const text = (value: string) => [{ type: "text" as const, text: value }];

function reportsTool() {
	return defineTool({
		name: "reports",
		description: REPORTS_DESCRIPTION,
		parameters: obj({
			action: str({ description: "list, read or wake" }),
			chats: opt(arr(int(), { description: "For read: the sub-chats whose reports to read, by default all. For wake: the sub-chats working now to choose for" })),
			when: opt(str({ description: "For wake: each, all, failure or never" })),
		}),
		// Listing changes nothing, a choice made twice is the same choice, and a read run again gives what it gave (`Given`).
		replay: "safe",
		execute: async (args, api, context): Promise<ToolExecutionResult> => {
			const caller = api.conversationId as unknown as number;
			const project = orchestratorOf(caller);
			if (project === undefined || project.conversation !== caller) {
				return { output: text("reports is for the project's orchestrator, in its current conversation."), isError: true };
			}
			const action = args.action.trim().toLowerCase();
			const mine = () => copy(mirror.projects[project.id] ?? []);
			const describe = (report: Report) => `sub-chat ${report.conversationId} “${report.title}” (${agentName(report)})`;

			if (action === "list") {
				const unread = mine()
					.filter((each) => each.ended !== null && each.delivered === null)
					.sort((a, b) => a.ended!.at - b.ended!.at);
				const runs = mine().filter((each) => each.ended === null);
				const watches = watchedRuns();
				const lines: string[] = [];
				if (unread.length > 0) {
					lines.push(`Reports not read yet (${unread.length}):`);
					for (const report of unread) lines.push(`- ${capital(describe(report))} ${outcomeWords(report.ended!.outcome)} at ${clock(report.ended!.at)}.`);
					lines.push("reports with action read gives them.");
				} else lines.push("No report is waiting to be read.");
				if (runs.length > 0) {
					lines.push("", `Working now (${runs.length}):`);
					for (const report of runs) {
						const watch = watches.find((each) => each.submissionId === report.submissionId);
						const mode = watch === undefined ? undefined : wakeFor(watch);
						const others = report.batch === null ? [] : runs.filter((each) => each.batch === report.batch && each !== report).map((each) => each.conversationId);
						const batch = others.length === 0 ? "" : ` (one batch with ${others.length === 1 ? "sub-chat" : "sub-chats"} ${listed(others)})`;
						const how =
							watch === undefined
								? waited.has(report.submissionId)
									? "delegate is waiting for it"
									: "it will not wake you: its report will wait for you unread"
								: mode === "each"
									? "you will be woken when it ends"
									: mode === "all"
										? `you will be woken once all of its batch have ended${batch}`
										: mode === "failure"
											? `you will be woken only if it fails or is stopped${batch}`
											: "it will not wake you: its report will wait for you unread";
						lines.push(`- ${capital(describe(report))}: ${how}.`);
					}
				}
				if (await api.commit((tx) => reportPastLimit(tx, project.id, caller), context)) lines.push("", "The project is past one of its limits, so no report wakes you now: they wait for you unread.");
				return { output: text(lines.join("\n")), details: { action, unread: unread.length, working: runs.length } };
			}

			if (action === "read") {
				const before = await api.snapshot(Given, api.taskId, context);
				if (typeof before?.text === "string") return { output: text(before.text), details: { action } };
				const wanted = args.chats ?? [];
				const candidates = mine()
					.filter((each) => each.ended !== null && each.delivered === null && !waited.has(each.submissionId) && (wanted.length === 0 || wanted.includes(each.conversationId)))
					.sort((a, b) => a.ended!.at - b.ended!.at || a.submissionId - b.submissionId);
				const items = await Promise.all(candidates.map((report) => arrival(report)));
				const given = await api.commit(async (tx) => {
					const out: string[] = [];
					for (const item of items) if ((await settle(tx, item.report!, { by: "read", conversationId: caller })).give) out.push(textOf(item));
					const none = wanted.length === 0 ? "No report is waiting to be read." : `No report of ${wanted.length === 1 ? "sub-chat" : "sub-chats"} ${listed(wanted)} is waiting to be read.`;
					const said = out.length === 0 ? none : out.join("\n\n---\n\n");
					(await tx.doc(Given, api.taskId)).text = said;
					return { said, count: out.length };
				}, context);
				await afterCommit();
				return { output: text(given.said), details: { action, count: given.count } };
			}

			if (action === "wake") {
				const when = (args.when ?? "").trim().toLowerCase() as ReportWake;
				if (!REPORT_WAKES.includes(when)) return { output: text("wake needs `when`: each, all, failure or never."), isError: true };
				if ((args.chats ?? []).length === 0) return { output: text("wake needs `chats`: the sub-chats working now to choose for, from list."), isError: true };
				const agentId = host?.agentOf(api.conversationId)?.id ?? "";
				const chosen = await chooseWake(project.id, args.chats!, when, { kind: "agent", agentId, conversationId: caller, callId: api.callId });
				const ended = chosen.change === undefined ? chosen.text : `${chosen.text} The person can undo it. (change ${chosen.change})`;
				return { output: text(ended), details: { action, when, ...(chosen.change === undefined ? {} : { change: chosen.change }) }, ...(chosen.isError ? { isError: true } : {}) };
			}
			return { output: text(`Unknown action "${args.action}". Use list, read or wake.`), isError: true };
		},
	});
}

const capital = (value: string) => value.charAt(0).toUpperCase() + value.slice(1);

// ---- The feature

export const reports: Feature = (given, running) => {
	host = given;
	engine = running;
	return {
		tools: [reportsTool()],
		// The orchestrator's alone (5.1), with the preview on and its project neither archived nor deleted. `toolNames` is
		// not told the conversation, so another conversation of the orchestrator agent is offered it too, and refused.
		toolNames: (_access, agent, where) => {
			if (where.subChat || agent?.role !== "orchestrator" || agent.projectId === undefined || !inProjectOn(agent.projectId)) return [];
			return ["reports"];
		},
		start: async () => {
			await reload();
			// A commit by anyone that changes the document (a wake that carried a report, in wakes.ts) is read back.
			running.harness().observeCommits({
				advance: ({ changes }) => {
					const touched = changes.some((one: CommitChange) => (one.type === "document" || one.type === "document.copy") && one.record.kind === "pi2.reports");
					if (touched) void reload().catch((error) => running.log("could not read the reports again:", error instanceof Error ? error.message : error));
				},
				end: () => {},
			});
			void given.ready.then(() => {
				ready = true;
				for (const list of Object.values(mirror.projects)) for (const report of list) follow(report);
				// A watch made for a run that had already ended, by an engine that stopped before deciding again.
				for (const watch of watchedRuns()) reportWatched(watch.submissionId);
			});
		},
		greeting: () => [event()],
		handlers: {
			/** `{ projectId, chats, when }`: the person's choice of waking for sub-chats' runs going now (4.2). */
			"reports.wake": async (params) => {
				requirePreview();
				const projectId = params.projectId;
				if (typeof projectId !== "string") throw new Error("projectId must be a project's id");
				const project = allProjects()[projectId];
				if (project === undefined || project.deletedAt !== undefined) throw new Error(`Unknown project: ${projectId}`);
				if (project.archivedAt !== undefined) throw new Error(PROJECT_ARCHIVED);
				if (!Array.isArray(params.chats) || params.chats.length === 0 || !params.chats.every((chat) => Number.isInteger(chat))) throw new Error("chats must be a list of sub-chats' numbers");
				if (typeof params.when !== "string" || !REPORT_WAKES.includes(params.when as ReportWake)) throw new Error("when must be each, all, failure or never");
				const chosen = await chooseWake(projectId, params.chats as number[], params.when as ReportWake);
				if (chosen.isError) throw new Error(chosen.text);
				return {};
			},
		},
	};
};

/** Whether project `projectId` is in the preview now: on, and neither archived nor deleted. */
function inProjectOn(projectId: string): boolean {
	const project = allProjects()[projectId];
	return projectsOn() && project !== undefined && project.archivedAt === undefined && project.deletedAt === undefined;
}
