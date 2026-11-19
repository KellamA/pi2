// Needs you (#462): one list of everything that waits for the person. docs/projects.md, 3.9, is the contract this file
// builds, and its names and shapes are the contract's.
//
// The list has two sources. The Inbox (state.ts) holds what a tool call waits on, approvals and `ask_user` questions,
// in memory as today. `pi2.needs`, here, holds what holds no call: a question or decision an agent put with `needs_you`
// and carried on, a request for more reach, a proposed rule, a start refused for a limit. Those are stored, so they
// survive a restart, and stay until answered or withdrawn.
//
// Every answer, by whichever route (`needs.answer`, and today's `inbox.decide` and `inbox.answer`), goes through one
// function, `claim`, which takes the item off the list in the same step it reads it, so it is taken exactly once.
//
// What other issues fill in, each through `onAnswer(kind, handler)`, and what it does until then:
//
// - `reach` (#465): the request for more reach, allowed or refused. No handler yet, so an answer to one is refused and
//   the item stays; nothing puts one until #465.
// - `rule` (#465, adding through #459's `addRule`): a proposed rule, accepted or not. The same until then.
// - `limit` (#464): a start refused for a limit, started anyway or left. The same until then.
// - `ReachChange.op` is typed `unknown` until #465 gives it its type, `Op` (3.12).
//
// Questions and decisions are this file's own: the answer is given to the conversation that asked as a wake of the kind
// `answer` (wakes.ts).

import type { Context } from "@earendil-works/chord/context";
import { type CommitChange, defineDoc, defineTool, type JsonObject, type ToolExecutionResult, type Tx } from "@earendil-works/pi-durable";
import { arr, bool, obj, opt, str } from "@earendil-works/pi-schema";
import type { Host } from "./extensions.ts";
import type { Engine, Feature } from "./features.ts";
import { allProjects, inProject, type LimitReading, Projects, projectsOn, requirePreview, type Start, type SwitchName } from "./projects.ts";
import { type AgentProfile, type InboxItem, type Meta, runsAs } from "./state.ts";
import { chatIdOf } from "./versions.ts";
import { arrivedIn, arriveIn } from "./wakes.ts";
import { answerGoesTo } from "./orchestrator.ts";

// ---- What is stored (3.9)

export type Choice = { id: string; label: string };

/** A change to what agents may do, as an agent asked for it (7.2). #465 builds it; `op` is its `Op` (3.12) then. */
export type ReachChange = {
	/** What it changes, as the person reads it: "Let Forge run commands without asking (Full access)". */
	summary: string;
	target: { kind: "project" } | { kind: "agent"; id: string } | { kind: "rule"; id: string };
	fields: { name: string; before: unknown; after: unknown }[];
	/** The change of section 3.12 it would be, once allowed. `Op` once #465 has landed. */
	op: unknown;
};

type StoredBase = {
	/** "n" and a number from `next`. Never reused. */
	id: string;
	projectId: string;
	/** The conversation that asked, or (for a limit) the orchestrator's conversation the start was for. */
	conversationId: number;
	/** The tool call that put it there, so that the call run again after a crash finds it rather than putting another. */
	callId: string | null;
	createdAt: number;
};

export type StoredNeed =
	| (StoredBase & { kind: "question"; question: string })
	| (StoredBase & { kind: "decision"; question: string; choices: Choice[]; words: boolean })
	| (StoredBase & { kind: "reach"; change: ReachChange; why: string | null })
	| (StoredBase & { kind: "rule"; text: string; binds: "orchestrator" | "everyone"; why: string | null })
	| (StoredBase & { kind: "limit"; start: Start; limit: LimitReading });

export type NeedsDoc = { items: Record<string, StoredNeed>; next: number };

const emptyNeeds = (): NeedsDoc => ({ items: {}, next: 1 });

/**
 * What is stored of Needs you. Made by the first need put, never at start: with the preview never on, nothing is written.
 * Its token is a plain JSON object's, since what a reach request or a limit card holds is typed `unknown` in places;
 * `needsIn` gives it its type.
 */
export const Needs = defineDoc<JsonObject>({
	kind: "pi2.needs",
	version: 1,
	scope: "session",
	initial: () => emptyNeeds() as unknown as JsonObject,
	checkpointWhen: () => true,
});

/** `pi2.needs` in the commit `tx`, to change. */
export const needsIn = async (tx: Tx): Promise<NeedsDoc> => (await tx.doc(Needs)) as unknown as NeedsDoc;

// ---- What is sent (the `needs` event and `needs.list`)

type WireBase = {
	id: string;
	/** Null: an approval or question of a conversation in no project. */
	projectId: string | null;
	conversationId: number;
	rootConversationId: number;
	title: string;
	rootTitle: string;
	/** The agent the conversation runs as, and its name. */
	agentId: string | null;
	agentName: string | null;
	/** Whether the agent is held until it is answered: true for approvals and ask_user questions only. */
	blocking: boolean;
	createdAt: number;
};

export type ApprovalAnswer = "once" | "always" | "rule" | "deny";

export type NeedItem =
	| (WireBase & {
			kind: "approval";
			tool: string;
			arguments: unknown;
			question: string | null;
			site?: string;
			when?: string;
			rule?: { words: string[]; folder: string; worktrees?: true };
			background?: true;
			/** Set when a switch of 8.1 that is off asked: which. Then `answers` is ["once", "deny"]. */
			projectSwitch?: SwitchName;
			/** The answers it takes. */
			answers: ApprovalAnswer[];
	  })
	| (WireBase & { kind: "question"; question: string })
	| (WireBase & { kind: "decision"; question: string; choices: Choice[]; words: boolean })
	| (WireBase & { kind: "reach"; change: ReachChange; why: string | null })
	| (WireBase & { kind: "rule"; text: string; binds: "orchestrator" | "everyone"; why: string | null })
	| (WireBase & { kind: "limit"; start: Start; limit: LimitReading });

/** One shape for every answer, by kind. */
export type NeedAnswer =
	| { kind: "approval"; decision: ApprovalAnswer }
	| { kind: "question"; text: string }
	| { kind: "decision"; choice: string }
	| { kind: "decision"; text: string }
	| { kind: "reach"; allow: boolean }
	| { kind: "rule"; accept: false }
	| { kind: "rule"; accept: true; text?: string; binds?: "orchestrator" | "everyone" }
	| { kind: "limit"; start: boolean };

export type StoredKind = StoredNeed["kind"];

/** What a kind's handler may ask of `claim`: keep the item waiting (as it changed it), and do something once stored. */
export type AnswerOutcome = { keep?: true; after?: () => Promise<void> };

/**
 * What a kind's answer does (3.9): run inside the commit that takes the item off the list, so the answer and its effect
 * are stored together, once. Throwing refuses the answer and leaves the item waiting, as it was.
 */
export type AnswerHandler<K extends StoredKind> = (tx: Tx, need: Extract<StoredNeed, { kind: K }>, answer: Extract<NeedAnswer, { kind: K }>) => Promise<AnswerOutcome | undefined>;

// ---- Words

/** A second answer to the same item, by whichever route. */
export const GONE = "This is no longer waiting: it was answered or withdrawn.";
/** The longest answer in words. */
export const MAX_ANSWER = 20_000;
/** The longest question `needs_you` puts. */
export const MAX_QUESTION = 2_000;
/** The longest label of a choice, and how many choices a decision has. */
export const MAX_CHOICE = 60;
export const MIN_CHOICES = 2;
export const MAX_CHOICES = 6;

const KINDS: readonly NeedItem["kind"][] = ["approval", "question", "decision", "reach", "rule", "limit"];
const DECISIONS: readonly ApprovalAnswer[] = ["once", "always", "rule", "deny"];
/** How each kind is named in a refusal. */
const NAMED: Record<NeedItem["kind"], string> = {
	approval: "a request for approval",
	question: "a question",
	decision: "a decision",
	reach: "a request for more reach",
	rule: "a proposed rule",
	limit: "a start held back by a limit",
};

// ---- State

/** The engine's host, for the Inbox and the conversations; and the engine. Set as the engine makes the feature. */
let wired: Host | undefined;
let running: Engine | undefined;
/** `pi2.needs` as last stored. */
let current: NeedsDoc = emptyNeeds();
/** Counts reads of the document, so a slow read never replaces a later one's. */
let reads = 0;
/** The last `needs` event sent, so a change that changes nothing in it sends none (4.3). */
let sent = "";
const handlers = new Map<StoredKind, AnswerHandler<never>>();

/**
 * What a kind's answer does, set by the issue that puts that kind (12.1): questions and decisions here, reach requests
 * and proposed rules #465, limit cards #464. One handler a kind; a second replaces the first. Approvals have none: their
 * answer goes to the call that waits.
 */
export function onAnswer<K extends StoredKind>(kind: K, handler: AnswerHandler<K>): void {
	handlers.set(kind, handler as unknown as AnswerHandler<never>);
}

/**
 * Put a need on the list, in the commit `tx` that makes what it is about. A call run again after a crash (same
 * `callId`) gets the one it put. The project must exist and not be deleted.
 */
export async function putNeed(tx: Tx, given: DistributiveOmit<StoredNeed, "id" | "createdAt"> & { createdAt?: number }): Promise<StoredNeed> {
	const doc = await needsIn(tx);
	if (given.callId !== null) {
		const earlier = Object.values(doc.items).find((need) => need.callId === given.callId);
		if (earlier !== undefined) return earlier;
	}
	const project = (await tx.doc(Projects)).projects[given.projectId];
	if (project === undefined || project.deletedAt !== undefined) throw new Error(`Unknown project: ${given.projectId}`);
	const need = { ...given, id: `n${doc.next}`, createdAt: given.createdAt ?? Date.now() } as StoredNeed;
	doc.next += 1;
	doc.items[need.id] = need;
	return need;
}

type DistributiveOmit<T, K extends PropertyKey> = T extends unknown ? Omit<T, K> : never;

/** Take a need off the list without an answer, in the commit `tx`: the item, or undefined if it was not waiting. */
export async function withdrawNeed(tx: Tx, id: string): Promise<StoredNeed | undefined> {
	const doc = await needsIn(tx);
	const need = doc.items[id];
	if (need !== undefined) delete doc.items[id];
	return need;
}

/** The needs stored and waiting, oldest first: a plain copy. */
export function storedNeeds(): StoredNeed[] {
	return Object.values(structuredClone(current.items)).sort(oldestFirst);
}

const oldestFirst = (a: { createdAt: number; id: string }, b: { createdAt: number; id: string }) => a.createdAt - b.createdAt || a.id.localeCompare(b.id, "en", { numeric: true });

// ---- Answers

const isObject = (value: unknown): value is Record<string, unknown> => typeof value === "object" && value !== null && !Array.isArray(value);

/** An answer in words: 1 to 20,000 characters, and not only spaces. */
function words(value: unknown, field: string): string {
	if (typeof value !== "string") throw new Error(`${field} must be text`);
	if (value.trim() === "") throw new Error("The answer is empty");
	if (value.length > MAX_ANSWER) throw new Error(`An answer can be ${MAX_ANSWER.toLocaleString("en")} characters at most; this one is ${value.length.toLocaleString("en")}`);
	return value;
}

/** An answer as a request gives it, checked against the shape of its kind (3.9), whatever it answers. */
export function checkAnswer(given: unknown): NeedAnswer {
	if (!isObject(given)) throw new Error("answer must be an object with a kind");
	const kind = given.kind as NeedItem["kind"];
	if (!KINDS.includes(kind)) throw new Error(`Unknown kind of answer: ${String(given.kind)}`);
	const flag = (field: string) => {
		if (typeof given[field] !== "boolean") throw new Error(`${field} must be true or false`);
		return given[field] as boolean;
	};
	switch (kind) {
		case "approval": {
			if (!DECISIONS.includes(given.decision as ApprovalAnswer)) throw new Error("decision must be once, always, rule or deny");
			return { kind, decision: given.decision as ApprovalAnswer };
		}
		case "question":
			return { kind, text: words(given.text, "text") };
		case "decision": {
			if (given.choice !== undefined && given.text !== undefined) throw new Error("Give either a choice or an answer in words, not both");
			if (given.choice !== undefined) {
				if (typeof given.choice !== "string") throw new Error("choice must be a choice's id");
				return { kind, choice: given.choice };
			}
			if (given.text === undefined) throw new Error("Give a choice, or an answer in words");
			return { kind, text: words(given.text, "text") };
		}
		case "reach":
			return { kind, allow: flag("allow") };
		case "rule": {
			if (!flag("accept")) return { kind, accept: false };
			if (given.text !== undefined) words(given.text, "text");
			if (given.binds !== undefined && given.binds !== "orchestrator" && given.binds !== "everyone") throw new Error("binds must be orchestrator or everyone");
			return {
				kind,
				accept: true,
				...(given.text === undefined ? {} : { text: given.text as string }),
				...(given.binds === undefined ? {} : { binds: given.binds as "orchestrator" | "everyone" }),
			};
		}
		case "limit":
			return { kind, start: flag("start") };
	}
}

/** The answers an approval takes: what the Inbox offers it, or only Allow Once and Deny when a project's switch asked. */
export function answersOf(item: InboxItem): ApprovalAnswer[] {
	if (item.projectSwitch !== undefined) return ["once", "deny"];
	// As the Inbox's card offers "always": never for a schedule, each of which is a decision of its own, and not for a
	// browser action with no site to name.
	const always = item.tool !== "schedule_task" && !(item.tool === "browser" && (item.site ?? "") === "");
	return ["once", ...(item.rule !== undefined ? ["rule" as const] : []), ...(always ? ["always" as const] : []), "deny"];
}

/** What the waiting call is given for `answer`, or why it does not answer `item`. */
function inboxAnswer(item: InboxItem, answer: NeedAnswer): string {
	if (item.kind === "question") {
		if (answer.kind !== "question") throw new Error(`This is ${NAMED.question}, not ${NAMED[answer.kind]}`);
		return answer.text;
	}
	if (answer.kind !== "approval") throw new Error(`This is ${NAMED.approval}, not ${NAMED[answer.kind]}`);
	// "rule" carries no words: the rule is the one the engine offered with the request.
	if (answer.decision === "rule" && item.rule === undefined) throw new Error("That request did not offer an allowed command");
	// A project's switch that is off asks to allow one action at a time (projects.ts, `requireSwitch`).
	if (item.projectSwitch !== undefined && answer.decision !== "once" && answer.decision !== "deny") throw new Error("This can only be allowed once, or denied: the project's settings ask each time");
	// "always" where the card does not offer it (a schedule, a browser action with no site) is taken as today: the tool
	// counts it as once, remembering nothing. `inbox.decide` has always taken it, and today's approvals work as before.
	return answer.decision;
}

/** Why `answer` does not answer the stored `need`; nothing when it does. */
function checkStored(need: StoredNeed, answer: NeedAnswer): void {
	if (answer.kind !== need.kind) throw new Error(`This is ${NAMED[need.kind]}, not ${NAMED[answer.kind]}`);
	if (need.kind === "decision" && answer.kind === "decision") {
		if ("choice" in answer && !need.choices.some((choice) => choice.id === answer.choice)) throw new Error(`There is no choice ${answer.choice} in this decision`);
		if ("text" in answer && !need.words) throw new Error("This decision takes one of its choices, not an answer in words");
	}
}

/**
 * Answer item `id`, of either source, with `answer`: the one way any route takes an answer (3.9). It takes the item off
 * the list in the same step it reads it, so a second answer, by whichever route or app, finds it gone and changes
 * nothing. An answer of the wrong kind, or not among the item's answers or choices, is refused and leaves it waiting.
 *
 * An approval or `ask_user` question answers the call that waits on it, as `inbox.decide` and `inbox.answer` did. A
 * stored need is taken in one commit with what its kind's handler (`onAnswer`) does.
 */
export async function claim(id: string, answer: NeedAnswer): Promise<void> {
	if (wired === undefined || running === undefined) throw new Error("Needs you is not running");
	if (wired.inbox.get(id) !== undefined) {
		if (wired.inbox.take(id, (item) => inboxAnswer(item, answer)) === undefined) throw new Error(GONE);
		return;
	}
	if (current.items[id] === undefined) throw new Error(GONE);
	const engine = running;
	const after = await engine.harness().commit(async (tx) => {
		const doc = await needsIn(tx);
		const need = doc.items[id];
		if (need === undefined) throw new Error(GONE);
		checkStored(need, answer);
		const handler = handlers.get(need.kind) as AnswerHandler<StoredKind> | undefined;
		// Until the issue that puts this kind registers what its answer does (12.1), nothing could act on it: the answer is
		// refused rather than lost, and the item stays.
		if (handler === undefined) throw new Error(`pi² cannot act on an answer to ${NAMED[need.kind]} yet`);
		const taken = JSON.parse(JSON.stringify(need)) as StoredNeed;
		delete doc.items[id];
		const outcome = await handler(tx, taken as never, answer as never);
		if (outcome?.keep === true) doc.items[id] = taken;
		return outcome?.after;
	}, engine.context());
	await reload();
	await after?.();
}

// ---- Questions and decisions: the answer wakes the conversation that asked

/** A question as the person's line names it: "the question “Merge now…”". */
const named = (question: string) => {
	const line = question.replace(/\s+/g, " ").trim();
	return `the question “${line.length > 80 ? `${line.slice(0, 79).trimEnd()}…` : line}”`;
};

/** What the agent is given: "The person answered your question “Merge now or after the release?”: After the release." */
export function answerText(question: string, answer: string): string {
	const said = answer.trim();
	if (said.includes("\n")) return `The person answered your question “${question}”:\n\n${said}`;
	return `The person answered your question “${question}”: ${said}${/[.!?…)”"']$/.test(said) ? "" : "."}`;
}

async function wakeWith(tx: Tx, need: StoredNeed & { question: string }, said: string): Promise<AnswerOutcome> {
	// Asked in an earlier conversation with the orchestrator: the answer goes to its current one (orchestrator.ts, 6.5).
	const { to, earlier } = await answerGoesTo(tx, need.conversationId);
	const text = answerText(need.question, said) + (earlier ? `\n\n(You asked this in your earlier conversation, ${need.conversationId}.)` : "");
	await arriveIn(tx, to, { key: `answer:${need.id}`, kind: "answer", ref: need.id, label: named(need.question), ended: "was answered", text });
	return { after: () => arrivedIn(to) };
}

onAnswer("question", (tx, need, answer) => wakeWith(tx, need, answer.text));
onAnswer("decision", (tx, need, answer) => wakeWith(tx, need, "choice" in answer ? need.choices.find((choice) => choice.id === answer.choice)!.label : answer.text));

// ---- The list, as sent

/** The agent a conversation runs as (state.ts, `runsAs`): its `agentId`, but for a conversation carried over. */
const agentOf = (meta: Meta | undefined, agents: Record<string, AgentProfile>): string | null => runsAs(meta, agents) ?? null;

/** Every item waiting, of every project and of none, oldest first; nothing with the preview off (3.9). */
export function needItems(): NeedItem[] {
	if (!projectsOn() || wired === undefined || running === undefined) return [];
	const conversations = running.library().conversations;
	const agents = running.agents();
	const base = (id: string, conversation: number, projectId: string | null | undefined, blocking: boolean, createdAt: number): WireBase => {
		const meta = conversations[String(conversation)];
		const root = meta?.parent ?? conversation;
		const agentId = agentOf(meta, agents);
		return {
			id,
			projectId: projectId ?? meta?.projectId ?? null,
			conversationId: conversation,
			rootConversationId: root,
			title: meta?.title ?? "",
			rootTitle: conversations[String(root)]?.title ?? "",
			agentId,
			agentName: agentId === null ? null : (agents[agentId]?.name ?? null),
			blocking,
			createdAt,
		};
	};
	const waiting: NeedItem[] = wired.inbox.list().map((item) => {
		// A question from a chat's version is the chat's: the app shows the chat under its own id, as the Inbox does.
		const wire = base(item.id, chatIdOf(conversations, item.conversationId), undefined, true, item.createdAt);
		if (item.kind === "question") return { ...wire, kind: "question", question: item.question ?? "" };
		return {
			...wire,
			kind: "approval",
			tool: item.tool,
			arguments: item.arguments,
			question: item.question,
			...(item.site === undefined ? {} : { site: item.site }),
			...(item.when === undefined ? {} : { when: item.when }),
			...(item.rule === undefined ? {} : { rule: item.rule }),
			...(item.background === undefined ? {} : { background: item.background }),
			...(item.projectSwitch === undefined ? {} : { projectSwitch: item.projectSwitch }),
			answers: answersOf(item),
		};
	});
	const stored: NeedItem[] = storedNeeds().map((need) => {
		const { id, projectId, conversationId, callId: _, createdAt, ...rest } = need;
		return { ...base(id, conversationId, projectId, false, createdAt), ...rest } as NeedItem;
	});
	return [...waiting, ...stored].sort(oldestFirst);
}

const needsEvent = () => ({ event: "needs" as const, items: needItems() });

function announce(): void {
	const event = needsEvent();
	const line = JSON.stringify(event);
	if (line === sent) return;
	sent = line;
	running?.broadcast(event);
}

/** Read the document again, as stored, and tell the apps if what they are sent changed. */
async function reload(): Promise<void> {
	if (running === undefined) return;
	const read = ++reads;
	const stored = (await running.harness().snapshot(Needs, running.context())) as NeedsDoc | undefined;
	if (read !== reads) return;
	current = stored === undefined ? emptyNeeds() : structuredClone(stored);
	announce();
}

/** Withdraw in one commit every stored need `gone` picks; nothing is written when none is. */
async function withdrawWhere(gone: (need: StoredNeed) => boolean, why: string): Promise<void> {
	if (running === undefined || !Object.values(current.items).some(gone)) return;
	const taken = await running.harness().commit(async (tx) => {
		const doc = await needsIn(tx);
		const ids = Object.values(doc.items)
			.filter(gone)
			.map((need) => need.id);
		for (const id of ids) await withdrawNeed(tx, id);
		return ids;
	}, running.context());
	await reload();
	if (taken.length > 0) running.log("withdrew", taken.join(", "), "from Needs you:", why);
}

// ---- The tool (5.5)

const text = (value: string) => [{ type: "text" as const, text: value }];
const refuse = (value: string): ToolExecutionResult => ({ output: text(value), isError: true });

const NEEDS_YOU_DESCRIPTION =
	"Put a question or a decision to the person under Needs you, and carry on working: their answer comes to you later as a message, waking you if you are not answering. Use it for what is theirs to decide; do not use it for what you can find out yourself, and do not wait for the answer.\n" +
	`- ask: put \`question\` (${MAX_QUESTION.toLocaleString("en")} characters at most). With \`choices\` (${MIN_CHOICES} to ${MAX_CHOICES}, ${MAX_CHOICE} characters each) it is a decision with a button for each; \`words: false\` leaves out an answer in words, which is allowed by default. Returns at once with the item's id.\n` +
	"- withdraw: take back one of this conversation's items still waiting, by `id`, when it is no longer needed.\n" +
	"- list: this conversation's items still waiting.";

/** How a stored question or decision is listed to the agent. */
function listed(need: StoredNeed): string {
	if (need.kind === "decision") return `- ${need.id}: “${need.question}”, choices: ${need.choices.map((choice) => choice.label).join(", ")}${need.words ? ", or an answer in words" : ""}`;
	if (need.kind === "question") return `- ${need.id}: “${need.question}”`;
	return `- ${need.id}: ${NAMED[need.kind]}`;
}

function needsYouTool() {
	return defineTool({
		name: "needs_you",
		description: NEEDS_YOU_DESCRIPTION,
		parameters: obj({
			action: str({ description: "ask, withdraw or list" }),
			question: opt(str({ description: "For ask: the question, as the person will read it" })),
			choices: opt(arr(str(), { description: "For ask: 2 to 6 short choices, shown as buttons; leave out for an answer in words" })),
			words: opt(bool({ description: "For ask with choices: whether the person may also answer in words instead. Default true" })),
			id: opt(str({ description: "For withdraw: the item's id, such as n12" })),
		}),
		// A call run again after a crash finds what it put by its call id; withdrawing and listing again change nothing more.
		replay: "safe",
		execute: async (args, api, context): Promise<ToolExecutionResult> => {
			const conversationId = api.conversationId as unknown as number;
			const meta = wired?.conversations()[String(conversationId)];
			const project = inProject(conversationId);
			if (meta?.parent !== undefined) return refuse("A sub-chat cannot put things to the person and carry on: use ask_user, which waits for their answer.");
			if (project === undefined || running === undefined) return refuse("needs_you works only in a conversation of a project, with projects turned on.");
			const engine = running;
			const commit = async <T>(edit: (tx: Tx) => Promise<T>, ctx: Context) => {
				const value = await engine.harness().commit(edit, ctx);
				await reload();
				return value;
			};
			const action = args.action.trim().toLowerCase();
			if (action === "ask") {
				const question = (args.question ?? "").trim();
				if (question === "") return refuse("Give the question to put to the person.");
				if (question.length > MAX_QUESTION) return refuse(`That question is ${question.length.toLocaleString("en")} characters; the most is ${MAX_QUESTION.toLocaleString("en")}. Say it more briefly.`);
				let choices: Choice[] | undefined;
				if (args.choices !== undefined) {
					const labels = args.choices.map((label) => label.replace(/\s+/g, " ").trim());
					if (labels.length < MIN_CHOICES || labels.length > MAX_CHOICES) return refuse(`Give ${MIN_CHOICES} to ${MAX_CHOICES} choices, or none for an answer in words.`);
					if (labels.some((label) => label === "")) return refuse("A choice is empty. Give each choice a few words.");
					const long = labels.find((label) => label.length > MAX_CHOICE);
					if (long !== undefined) return refuse(`The choice “${long}” is ${long.length} characters; the most is ${MAX_CHOICE}. Shorten it.`);
					choices = labels.map((label, index) => ({ id: `c${index + 1}`, label }));
				}
				const base = { projectId: project.id, conversationId, callId: api.callId };
				const need = await commit(
					(tx) => putNeed(tx, choices === undefined ? { ...base, kind: "question", question } : { ...base, kind: "decision", question, choices, words: args.words !== false }),
					context,
				);
				return {
					output: text(`Put to the person as ${need.id}. Carry on with what does not depend on it; their answer will come to you as a message.`),
					details: { need: need.id },
				};
			}
			if (action === "withdraw") {
				const id = (args.id ?? "").trim();
				if (id === "") return refuse("Give the id of the item to withdraw, such as n12.");
				const taken = await commit(async (tx) => {
					const need = (await needsIn(tx)).items[id];
					if (need === undefined || need.conversationId !== conversationId) return undefined;
					return withdrawNeed(tx, id);
				}, context);
				if (taken === undefined) return refuse(`${id} is not waiting from this conversation: it was answered or withdrawn, or was not put here. list shows what is.`);
				return { output: text(`Withdrew ${id}. The person no longer sees it.`), details: { need: id } };
			}
			if (action === "list") {
				const mine = storedNeeds().filter((need) => need.conversationId === conversationId);
				if (mine.length === 0) return { output: text("Nothing from this conversation is waiting for the person.") };
				return { output: text(`Waiting for the person, oldest first:\n${mine.map(listed).join("\n")}`) };
			}
			return refuse(`Unknown action: ${args.action}. Use ask, withdraw or list.`);
		},
	});
}

// ---- The feature

/** Whether an archived or deleted conversation, or one whose root is, has `id`. */
function putAway(conversations: Record<string, Meta>, id: number): boolean {
	const away = (meta: Meta | undefined) => meta === undefined || meta.deleted === true || meta.archivedAt !== undefined;
	const meta = conversations[String(id)];
	return away(meta) || (meta?.parent !== undefined && away(conversations[String(meta.parent)]));
}

export const needs: Feature = (host, engine) => {
	wired = host;
	running = engine;
	return {
		start: async () => {
			await reload();
			engine.harness().observeCommits({
				advance: ({ changes }) => {
					const kinds = new Set(changes.filter((one: CommitChange) => one.type === "document" || one.type === "document.copy").map((one: CommitChange) => (one as { record: { kind: string } }).record.kind));
					// A need put or withdrawn in another feature's commit (#464, #465) is read back.
					if (kinds.has("pi2.needs")) void reload().catch((error) => engine.log("could not read Needs you again:", error instanceof Error ? error.message : error));
					// A project deleted takes its needs with it (3.9).
					if (kinds.has("pi2.projects")) {
						void (async () => {
							const projects = (await engine.harness().snapshot(Projects, engine.context()))?.projects ?? {};
							await withdrawWhere((need) => projects[need.projectId]?.deletedAt !== undefined, "its project was deleted");
						})().catch((error) => engine.log("could not withdraw the needs of a deleted project:", error instanceof Error ? error.message : error));
					}
				},
				end: () => {},
			});
		},
		greeting: () => [needsEvent()],
		tools: [needsYouTool()],
		// Offered in a project agent's own conversations with the preview on, the orchestrator's included, and not in a
		// sub-chat, which is not woken and so could not be told the answer: it keeps ask_user, which holds it (5.5, #507).
		toolNames: (_access, agent, where) => (!where.subChat && agent?.projectId !== undefined && projectsOn() && liveProject(agent.projectId) ? ["needs_you"] : []),
		inboxChanged: announce,
		previewChanged: announce,
		// A conversation archived or deleted takes its needs with it, as an approval is let go when its run stops (3.9).
		putAwayChanged: () => {
			const conversations = engine.library().conversations;
			void withdrawWhere((need) => putAway(conversations, need.conversationId), "its conversation was archived or deleted").catch((error) =>
				engine.log("could not withdraw the needs of a conversation put away:", error instanceof Error ? error.message : error),
			);
		},
		handlers: {
			/** `{ projectId? }`: the `needs` event's items, of one project or all. */
			"needs.list": async (params) => {
				requirePreview();
				if (params.projectId === undefined || params.projectId === null) return { items: needItems() };
				if (typeof params.projectId !== "string") throw new Error("projectId must be a project's id");
				if (!liveProject(params.projectId, true)) throw new Error(`Unknown project: ${params.projectId}`);
				return { items: needItems().filter((item) => item.projectId === params.projectId) };
			},
			/** `{ id, answer }`: answers an item of any kind with a `NeedAnswer`, through `claim`. */
			"needs.answer": async (params) => {
				requirePreview();
				if (typeof params.id !== "string") throw new Error("id must be the id of an item waiting");
				await claim(params.id, checkAnswer(params.answer));
				return {};
			},
		},
	};
};

/** Whether project `id` exists, is not deleted, and (unless `archived` allows it) is not archived. */
function liveProject(id: string, archived = false): boolean {
	const project = allProjects()[id];
	return project !== undefined && project.deletedAt === undefined && (archived || project.archivedAt === undefined);
}
