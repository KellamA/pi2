// One work list per project (docs/projects.md, 3.11). Only the backend knows where the items are kept.

import type { Context } from "@earendil-works/chord/context";
import { AgentDoc, type AgentChange, configure, type ConversationId, defineDoc, type DocumentReader, defineTool, GenerationTask, LiveDoc, type ToolExecutionApi, type Tx, UserEntry } from "@earendil-works/pi-durable";
import { arr, int, lit, obj, opt, str, union } from "@earendil-works/pi-schema";
import { isPutAway } from "./archive.ts";
import { giveWorktree, startedWords, titleOf } from "./extensions.ts";
import type { Engine, Feature } from "./features.ts";
import { addNews, allProjects, inProject, type LimitReading, type Project, PROJECT_ARCHIVED, Projects, projectsOn, requirePreview, requireSwitch, type Start, type SwitchName, type Who } from "./projects.ts";
import { admit, limitError, limitRefusal, rememberReading } from "./projectlimits.ts";
import { onLimitAssignment } from "./projectlimitstarts.ts";
import { recordWorkChange } from "./changes.ts";
import { handOffWords, reportRun, stageReportRun } from "./reports.ts";
import { Agents, type Access, type AgentProfile, Library, type Meta, runsAs } from "./state.ts";
import { Wakes, watch } from "./wakes.ts";
import { branchSlug, removeWorktree, repoOf, subChatBranch, subChatFolder, worktreeOf } from "./worktrees.ts";

export type WorkState = "open" | "in_progress" | "waiting" | "blocked" | "done" | "dropped";
export type WorkAction = "file" | "take" | "assign" | "release" | "wait" | "block" | "resume" | "finish" | "close" | "reopen" | "note" | "edit" | "classify";
export type WorkItem = {
	id: number;
	title: string;
	text: string;
	state: WorkState;
	class: "local" | "cloud" | null;
	takenBy: { agentId: string; conversationId: number } | null;
	notes: { at: number; by: Who; text: string }[];
	result: string | null;
	filedBy: Who;
	createdAt: number;
	updatedAt: number;
	closedAt: number | null;
	url?: string;
	/**
	 * GitHub only: who held it when it was closed outside pi² (a merged pull request's "Fixes #N"), until that holder
	 * finishes it with its summary (#604). Absent otherwise.
	 */
	heldAtClose?: { agentId: string; conversationId: number };
};
/** What the tool's `list` says of a pull request (#595): the fields of github.ts's own `PullRequest` that it reads. */
export type PullSummary = {
	number: number;
	title: string;
	state: "open" | "merged" | "closed";
	draft: boolean;
	checks: "passing" | "failing" | "pending" | "none";
	findings: { verdict: "approve" | "changes" | "comment"; at: number }[];
	/** Only what its row shows was read, a closed one's (#599): its checks and review are not known here. */
	partial?: true;
};
export type WorkDoc = { projects: Record<string, { items: Record<string, WorkItem>; next: number }> };
export interface WorkBackend {
	list(project: Project, filter: { states?: WorkState[] }): Promise<WorkItem[]>;
	show(project: Project, id: number): Promise<WorkItem>;
	/** Applies one row, checking its source state against what this backend holds now. */
	apply(project: Project, action: WorkAction, id: number | null, by: Who, args: Record<string, unknown>): Promise<WorkItem>;
}

export const Work = defineDoc<WorkDoc>({ kind: "pi2.work", version: 1, scope: "session", initial: () => ({ projects: {} }), checkpointWhen: () => true });

// A tool that did its work but did not return before a crash reads its result again. The receipt lives only as long
// as the tool task does; it is committed with the action, not memoized in a second commit after it.
// `change` is the change an agent's write was recorded as (changes.ts), for the result's `details.change`. `text` is
// a pull request's action's answer (github.ts), which has no work item.
type WorkReceipt = { call: string; item: WorkItem | null; refused?: string; note?: string; change?: number; text?: string };
const WorkCall = defineDoc<WorkReceipt>({ kind: "pi2.workCall", version: 1, scope: "task", initial: () => ({ call: "", item: null }), checkpointWhen: () => true });

/** Keep what a `work` call did with its task, in the commit `tx` that finishes it (github.ts): a call run again gives it. */
export async function workReceipt(tx: Tx, call: Call, done: Omit<WorkReceipt, "call">): Promise<void> {
	const receipt = await tx.doc(WorkCall, call.api.taskId);
	receipt.call = call.api.callId;
	receipt.item = done.item === null ? null : retained(done.item);
	for (const key of ["refused", "note", "change", "text"] as const) {
		if (done[key] === undefined) delete receipt[key];
		else (receipt as Record<string, unknown>)[key] = done[key];
	}
}

/** What a `work` call kept with its task, if this call finished already. */
export async function workReceiptOf(call: Call): Promise<WorkReceipt | undefined> {
	const receipt = await call.api.snapshot(WorkCall, call.api.taskId, call.context);
	return receipt?.call === call.api.callId ? receipt : undefined;
}

export type WorkOperation = { projectId: string; action: WorkAction; by: Who; before: WorkItem | null; after: WorkItem; callId?: string };
/** Record an agent's write in the record of changes (changes.ts), in this transaction: the change's id, or none for the person's. */
export function recordWork(tx: Tx, operation: WorkOperation): Promise<number | undefined> {
	return recordWorkChange(tx, operation);
}

/** A pull request of an attached repository (docs/projects.md, 3.11): github.ts reads and acts on them. */
export type PullAction = "pull_request" | "review" | "merge" | "send_back";

/**
 * What an assignment on GitHub needs of this file (github.ts): the admission check of #464, in a commit of its own before
 * the item is claimed on GitHub, and the start of the sub-chat once it is, without checking again.
 */
export type GithubAssign = {
	/** The agent assigned. */
	agentId: string;
	admit(tx: Tx, project: Project, item: WorkItem): Promise<{ ok: true; note?: string } | { ok: false; limit: LimitReading }>;
	start(tx: Tx, project: Project, item: WorkItem, admitted: { note?: string }): Promise<NonNullable<WorkItem["takenBy"]>>;
};
export type GithubWriting = { call?: Call; confirmedSwitch?: SwitchName; assign?: GithubAssign };

/** What github.ts (#468) supplies for a project with a repository attached. */
export type GithubWork = {
	backend(project: Project, writing: GithubWriting): WorkBackend;
	/** When the listing was read; null when it never was. */
	readAt(project: Project): number | null;
	/** The pull requests the listing holds, for the tool's `list` answer (#595). */
	pulls(project: Project): PullSummary[];
	/** A line for the tool's `list` and `show`: when the listing was read, and why it is not newer. */
	listingNote(project: Project): string;
	/** A pull request's action (5.7): the text the model is given, and the change it was recorded as. */
	pull(project: Project, action: PullAction, by: Who, args: Record<string, unknown>, call: Call): Promise<{ text: string; change?: number }>;
	/** Start Anyway on a limit card for an assignment: claim the item on GitHub, then start (`launch`), once the card's commit is made. */
	assignHeld(project: Project, start: Start, launch: (tx: Tx, item: WorkItem) => Promise<NonNullable<WorkItem["takenBy"]>>): Promise<WorkItem>;
};
let github: GithubWork | undefined;

/** github.ts plugs the GitHub backend in here as the engine makes its feature. */
export function wireGithubWork(given: GithubWork): void {
	github = given;
}

/** The backend of a project with a repository attached; undefined until github.ts is running. Never the pi² list instead. */
export function githubWorkBackend(project: Project, writing: GithubWriting = {}): WorkBackend | undefined {
	return github?.backend(project, writing);
}

const openStates: WorkState[] = ["open", "in_progress", "waiting", "blocked"];
const heldStates: WorkState[] = ["in_progress", "waiting", "blocked"];
const closedStates: WorkState[] = ["done", "dropped"];
const states: WorkState[] = [...openStates, ...closedStates];

type Row = {
	from: readonly WorkState[] | null;
	to: WorkState | "same" | "as";
	holder: "same" | "none" | "caller" | "assigned";
	agent: "any" | "holder" | "orchestrator" | "either";
	person?: true;
	switch?: SwitchName;
};

const table: Record<WorkAction, Row> = {
	file: { from: null, to: "open", holder: "none", agent: "any", person: true, switch: "fileWork" },
	take: { from: ["open"], to: "in_progress", holder: "caller", agent: "any" },
	assign: { from: ["open"], to: "in_progress", holder: "assigned", agent: "orchestrator", person: true, switch: "startAgents" },
	release: { from: heldStates, to: "open", holder: "none", agent: "either", person: true },
	wait: { from: ["in_progress", "blocked"], to: "waiting", holder: "same", agent: "holder" },
	block: { from: ["in_progress", "waiting"], to: "blocked", holder: "same", agent: "holder" },
	resume: { from: ["waiting", "blocked"], to: "in_progress", holder: "same", agent: "either", person: true },
	finish: { from: heldStates, to: "done", holder: "none", agent: "holder", switch: "closeWork" },
	close: { from: openStates, to: "as", holder: "none", agent: "orchestrator", person: true, switch: "closeWork" },
	reopen: { from: closedStates, to: "open", holder: "none", agent: "orchestrator", person: true },
	note: { from: states, to: "same", holder: "same", agent: "any", person: true }, // Explicit in work.act (4.2).
	edit: { from: states, to: "same", holder: "same", agent: "orchestrator", person: true },
	classify: { from: states, to: "same", holder: "same", agent: "orchestrator", person: true },
};

const pullActions: string[] = ["pull_request", "review", "merge", "send_back"] satisfies PullAction[];
const retained = <T>(value: T): T => JSON.parse(JSON.stringify(value));
const conversationId = (id: number): ConversationId => id as unknown as ConversationId;
const numberId = (id: unknown): number => {
	if (typeof id !== "number" || !Number.isSafeInteger(id) || id < 1) throw new Error("id must be a work item's positive whole number");
	return id;
};
const filtered = (value: unknown): WorkState[] | undefined => {
	if (value === undefined) return undefined;
	if (!Array.isArray(value) || value.some((state) => !states.includes(state))) throw new Error(`states must be a list of work states: ${states.join(", ")}`);
	return value;
};
const actionOf = (value: unknown): WorkAction => {
	if (typeof value !== "string" || !Object.hasOwn(table, value)) throw new Error(`Unknown work action: ${String(value)}`);
	return value as WorkAction;
};
const projectId = (value: unknown): string => {
	if (typeof value !== "string") throw new Error("projectId must be a project's id");
	return value;
};
const liveProject = (project: Project | undefined, id: string, write = false): Project => {
	if (project === undefined || project.deletedAt !== undefined) throw new Error(`Unknown project: ${id}`);
	if (write && project.archivedAt !== undefined) throw new Error(PROJECT_ARCHIVED);
	return project;
};

function stringOf(args: Record<string, unknown>, key: string): string | undefined {
	const value = args[key];
	if (value === undefined) return undefined;
	if (typeof value !== "string") throw new Error(`${key} must be text`);
	return value;
}
function workTitle(value: string | undefined): string {
	const title = value?.trim() ?? "";
	if (title.length < 1 || title.length > 200) throw new Error("title must be 1 to 200 characters");
	return title;
}
function workText(value: string | undefined): string | undefined {
	if (value !== undefined && value.length > 20_000) throw new Error("text must be at most 20,000 characters");
	return value;
}
export const unknownItem = (id: number) => new Error(`Unknown work item: #${id}`);
export const canWrite = (access: Access | undefined) => access === "ask" || access === "full";
export const writeRefusal = "This agent's access does not let it change the work list.";
/** Whether `by` is the project's orchestrator, in its current conversation. */
export const orchestrates = (project: Project, by: Who) => by.kind === "agent" && by.conversationId === project.conversation && by.agentId === project.orchestratorId;

/**
 * News for the orchestrator of a change to the work list (6.4), in the commit that makes it: none for what the
 * orchestrator did itself, in its own conversation, which is not news to it (#466).
 */
export async function workNews(tx: Tx, project: Project, by: Who, text: string, ref: string, at = Date.now()): Promise<void> {
	if (orchestrates(project, by)) return;
	await addNews(tx, project.id, { kind: "work", text, ref, at });
}
const sameHolder = (holder: WorkItem["takenBy"] | undefined, by: Who) => by.kind === "agent" && holder?.agentId === by.agentId && holder.conversationId === by.conversationId;
const heldBy = (item: WorkItem | null, by: Who) => sameHolder(item?.takenBy, by);

/** What the tool answers an agent that takes what it holds already (#604): no error, and how to go on. */
export function yoursAlready(item: WorkItem, by: Who): string | undefined {
	if (!heldBy(item, by)) return undefined;
	return item.state === "in_progress" ? `#${item.id} is yours already: carry on.` : `#${item.id} is yours already, and ${item.state}: use resume to go on.`;
}

function actor(project: Project, by: Who, action: WorkAction, access?: Access): void {
	const row = table[action];
	if (by.kind === "person") {
		if (!row.person) throw new Error(`The person cannot use ${action}. Ask the agent holding the work, or use release or close.`);
		return;
	}
	if (access === undefined || !canWrite(access)) throw new Error(writeRefusal);
	if (row.agent === "orchestrator" && !orchestrates(project, by)) {
		throw new Error(action === "assign" ? "Only the orchestrator assigns work. Tell it in your report." : `Only the orchestrator can ${action} work. Tell it in your report.`);
	}
}

/** Shared by both backends. Check the committed item again, even if a switch asked about an earlier read. */
export function checkWorkTransition(project: Project, item: WorkItem, action: WorkAction, by: Who, agentName: (id: string) => string = (id) => id): void {
	const row = table[action];
	const holder = item.takenBy;
	if ((action === "take" || action === "assign") && holder !== null) {
		throw new Error(`#${item.id} is taken by ${agentName(holder.agentId)}, in sub-chat ${holder.conversationId}`);
	}
	// An issue a merged pull request closed under its holder: the holder still finishes it, with its summary (#604).
	if (action === "finish" && item.state === "done" && item.heldAtClose !== undefined) {
		if (by.kind === "agent" && !sameHolder(item.heldAtClose, by)) throw new Error(`Only the holder can finish #${item.id}. Tell the orchestrator in your report.`);
		return;
	}
	// Held, with no holder this tool knows: taken or paused with scripts/issue, or by hand on GitHub (#604). The tool knows
	// a holder only from its own comments, and does not guess one from the script's.
	if (holder === null && heldStates.includes(item.state) && (action === "take" || action === "assign" || (by.kind === "agent" && (row.agent === "holder" || (row.agent === "either" && !orchestrates(project, by)))))) {
		const said = `#${item.id} is ${item.state.replace("_", " ")}, but it was taken outside the work tool (with scripts/issue, or on GitHub by hand), so the tool knows no holder for it.`;
		const next = by.kind === "person" || orchestrates(project, by) ? " Release it first: that hands it over to the work tool." : " Keep it with what took it, or ask the orchestrator to release it, which hands it over to the work tool.";
		throw new Error(`${said}${next}`);
	}
	if (!row.from?.includes(item.state)) {
		const next = closedStates.includes(item.state) ? " Reopen it first." : item.state === "open" ? " Take or assign it first." : " Check the work list and choose an action for that state.";
		throw new Error(`#${item.id} is ${item.state}.${next}`);
	}
	if (by.kind === "agent" && (row.agent === "holder" || (row.agent === "either" && !orchestrates(project, by))) && !heldBy(item, by)) {
		throw new Error(`Only the holder can ${action} #${item.id}. Tell the orchestrator in your report.`);
	}
}

/** Apply a checked row to a copy, shared by both backends. No external effects occur here. */
export function workTransition(before: WorkItem | null, id: number, action: WorkAction, by: Who, args: Record<string, unknown>, at: number, assigned?: NonNullable<WorkItem["takenBy"]>): WorkItem {
	const row = table[action];
	const text = stringOf(args, "text");
	const item: WorkItem = before === null
		? { id, title: workTitle(stringOf(args, "title")), text: workText(text) ?? "", state: "open", class: null, takenBy: null, notes: [], result: null, filedBy: by, createdAt: at, updatedAt: at, closedAt: null }
		: retained(before);
	if (action === "classify" || (action === "file" && args.class !== undefined)) {
		if (args.class !== null && args.class !== "local" && args.class !== "cloud") throw new Error("class must be local, cloud, or null");
		item.class = args.class;
	}
	if (row.to === "as") {
		if (args.as !== "done" && args.as !== "dropped") throw new Error("as must be done or dropped");
		item.state = args.as;
	} else if (row.to !== "same") item.state = row.to;
	if (row.holder === "none") {
		item.takenBy = null;
		delete item.heldAtClose;
	}
	else if (row.holder === "caller" && by.kind === "agent") item.takenBy = { agentId: by.agentId, conversationId: by.conversationId };
	else if (row.holder === "assigned") {
		if (assigned === undefined) throw new Error("The assigned agent's sub-chat was not started.");
		item.takenBy = assigned;
	}
	if (action === "note" && !text?.trim()) throw new Error("text must say what to note");
	if ((action === "note" || action === "wait" || action === "block") && text?.trim()) item.notes.push({ at, by, text });
	if (action === "edit") {
		if (args.title !== undefined) item.title = workTitle(stringOf(args, "title"));
		if (text !== undefined) item.text = workText(text)!;
	}
	if (action === "finish" || action === "close") {
		item.closedAt = at;
		item.result = item.state === "done" ? text ?? null : null;
	} else if (action === "reopen") {
		item.closedAt = null;
		item.result = null;
	}
	if (before !== null && JSON.stringify(item) !== JSON.stringify(before)) item.updatedAt = at;
	return item;
}

type Launched = { holder: NonNullable<WorkItem["takenBy"]>; note?: string };
type Runner = (tx: Tx, project: Project, item: WorkItem) => Promise<Launched | { limit: LimitReading }>;
export type Call = { api: ToolExecutionApi; context: Context };
type Write = { call?: Call; launch?: Runner; confirmedSwitch?: SwitchName; assign?: GithubAssign };

/** The line of news for a change to a work item. */
export const workNewsText = (item: Pick<WorkItem, "id" | "title">, action: string) => `Work #${item.id}: ${item.title.replace(/\s+/g, " ")} (${action}).`;

// ---- How the tool answers `list` and `show` (#595): a line an item, so that a whole backlog's prose is not read again at
// every later turn. `show` gives one item's text and notes; the newest notes come first, and a cut says what is left.

/** How much of an item's text `show` gives before it says the rest is elsewhere. */
const TEXT_SHOWN = 4_000;
/** How many characters of notes `show` gives before it says how many more there are. */
const NOTES_SHOWN = 4_000;
/** How many notes `show` gives at most, however short they are, and how much of one note. */
const NOTES_MOST = 12;
const NOTE_SHOWN = 1_200;

const STATE_WORDS: Record<WorkState, string> = { open: "open", in_progress: "in progress", waiting: "waiting", blocked: "blocked", done: "done", dropped: "dropped" };
const when = (at: number) => `${new Date(at).toISOString().slice(0, 16).replace("T", " ")}Z`;
const oneLine = (text: string) => text.replace(/\s+/g, " ").trim();

/** "Worker, sub-chat 34", or "nobody". */
const holderWords = (item: WorkItem, name: (id: string) => string) =>
	item.takenBy === null ? "nobody" : `${name(item.takenBy.agentId)}, sub-chat ${item.takenBy.conversationId}`;

/** One line for a piece of work: its number, state, class, who has it and in which sub-chat, when it last changed, and its title. */
function itemLine(item: WorkItem, name: (id: string) => string): string {
	const modelClass = item.class === null ? "not classified" : `${item.class} model`;
	return `#${item.id} ${STATE_WORDS[item.state]} · ${modelClass} · ${holderWords(item, name)} · changed ${when(item.updatedAt)} · ${oneLine(item.title)}`;
}

/** One line for a pull request: its number, state and draft, its checks and its review, each in a word, and its title. */
function pullLine(pull: PullSummary): string {
	const checks = pull.checks === "none" ? "no checks" : `checks ${pull.checks}`;
	const newest = [...pull.findings].sort((one, other) => one.at - other.at).at(-1);
	const review = newest === undefined ? "no review" : newest.verdict === "approve" ? "approved" : newest.verdict === "changes" ? "changes requested" : "comments only";
	const state = pull.state === "merged" ? "merged" : pull.state === "closed" ? "closed" : pull.draft ? "open, a draft" : "open";
	if (pull.partial === true) return `#${pull.number} pull request ${state} · ${oneLine(pull.title)}`;
	return `#${pull.number} pull request ${state} · ${checks} · ${review} · ${oneLine(pull.title)}`;
}

/** How many there are, by state, so that a list says how the backlog stands without any of its words. */
function countWords(items: WorkItem[], pulls: PullSummary[]): string {
	const order: WorkState[] = [...openStates, ...closedStates];
	const byState = order
		.filter((state) => items.some((item) => item.state === state))
		.map((state) => `${items.filter((item) => item.state === state).length} ${STATE_WORDS[state]}`);
	const said = `${items.length} ${items.length === 1 ? "item" : "items"}${byState.length === 0 ? "" : `: ${byState.join(", ")}`}.`;
	if (pulls.length === 0) return said;
	const open = pulls.filter((pull) => pull.state === "open").length;
	return `${said} ${pulls.length} ${pulls.length === 1 ? "pull request" : "pull requests"}, ${open} of them open.`;
}

/** The tool's `list` answer: a line an item, a line a pull request, how many there are, and when GitHub was read. */
function listAnswer(project: Project, items: WorkItem[], name: (id: string) => string): string {
	const pulls = project.repository === null || github === undefined ? [] : github.pulls(project);
	const lines = items.map((item) => itemLine(item, name));
	if (pulls.length > 0) lines.push(...pulls.map(pullLine));
	lines.push(countWords(items, pulls));
	if (project.repository !== null && github !== undefined) lines.push(github.listingNote(project));
	return lines.join("\n");
}

/** `text` cut at `most` characters, at a word or a line break where there is one, and how much was left out. */
function cut(text: string, most: number): { shown: string; rest: number } {
	if (text.length <= most) return { shown: text, rest: 0 };
	const window = text.slice(0, most);
	const at = Math.max(window.lastIndexOf("\n"), window.lastIndexOf(" "));
	const shown = at > most * 0.6 ? window.slice(0, at) : window;
	return { shown, rest: text.length - shown.length };
}

/** Where the rest of a cut item is: its page on GitHub, or the tab that shows it. */
const restWords = (item: WorkItem) => (item.url === undefined ? "the project's Work tab shows it" : `the rest is on its page: ${item.url}`);

/** The tool's `show` answer: the item's line, its text, what finishing it said, and its notes. */
function showAnswer(item: WorkItem, name: (id: string) => string): string {
	const lines = [itemLine(item, name)];
	const text = cut(item.text.trim(), TEXT_SHOWN);
	if (text.shown !== "") lines.push("", text.shown);
	if (text.rest > 0) lines.push(`[${text.rest} more characters of the text; ${restWords(item)}]`);
	if (item.result !== null && item.result.trim() !== "") lines.push("", `Done: ${item.result.trim()}`);
	if (item.notes.length > 0) {
		// A long item is read from its newest notes, which say where it stands now; a short one in the order it was written.
		const newestFirst = item.notes.length > NOTES_MOST || item.notes.reduce((all, note) => all + note.text.length, 0) > NOTES_SHOWN;
		const order = newestFirst ? [...item.notes].reverse() : item.notes;
		const shown: typeof item.notes = [];
		let used = 0;
		for (const note of order) {
			if (shown.length >= NOTES_MOST || (shown.length > 0 && used + note.text.length > NOTES_SHOWN)) break;
			shown.push(note);
			used += note.text.length;
		}
		lines.push("", `Notes (${item.notes.length})${newestFirst ? ", newest first" : ""}:`);
		for (const note of shown) {
			const who = note.by.kind === "person" ? "the person" : name(note.by.agentId);
			const said = cut(oneLine(note.text), NOTE_SHOWN);
			lines.push(`${when(note.at)}, ${who}: ${said.shown}${said.rest === 0 ? "" : ` [+${said.rest} characters]`}`);
		}
		const left = item.notes.length - shown.length;
		if (left > 0) lines.push(`[${left} more ${left === 1 ? "note" : "notes"}; ${restWords(item)}]`);
	}
	return lines.join("\n");
}

/**
 * Check, in the commit `tx`, that `by` may make `action` now (both backends): the project live and not archived, with the
 * kind of list expected; for an agent, its conversation current in the project, its access, its role, and the switch it
 * was asked about still the one that holds. Answers the project and the agents as stored.
 */
export async function checkWriterIn(tx: Tx, projectId: string, by: Who, action: WorkAction, confirmedSwitch: SwitchName | undefined, onGithub: boolean): Promise<{ project: Project; agents: Record<string, AgentProfile> }> {
	requirePreview();
	const current = liveProject((await tx.doc(Projects)).projects[projectId], projectId, true);
	if ((current.repository !== null) !== onGithub) throw new Error("The project's work list changed. Look at it again.");
	const meta = by.kind === "agent" ? (await tx.doc(Library)).conversations[String(by.conversationId)] : undefined;
	const agents = (await tx.doc(Agents)).agents;
	if (by.kind === "agent" && (meta?.projectId !== current.id || isPutAway(meta) || runsAs(meta, agents) !== by.agentId || current.earlier.includes(by.conversationId))) {
		throw new Error("Use work from a current conversation in this project.");
	}
	actor(current, by, action, meta?.access);
	const gate = table[action].switch;
	if (by.kind === "agent" && gate !== undefined && !current.settings.withoutAsking[gate] && confirmedSwitch !== gate) {
		throw new Error("The project's permission changed. Ask the person before trying again.");
	}
	if (by.kind === "agent" && (agents[by.agentId] === undefined || agents[by.agentId]?.removedAt !== undefined)) throw new Error(`Unknown agent: ${by.agentId}`);
	return { project: current, agents };
}

function offersWork(project: Project | undefined, id?: number): boolean {
	return project !== undefined && project.archivedAt === undefined && project.deletedAt === undefined && (id === undefined || !project.earlier.includes(id));
}

/** Wakes admit their own input, without main.ts's syncTools. Refresh just work at that same boundary. */
export async function syncWorkForInput(tx: Tx, id: ConversationId, meta: Meta | undefined): Promise<void> {
	if (meta?.projectId === undefined) return;
	const offered = projectsOn() && offersWork((await tx.doc(Projects)).projects[meta.projectId], id as number);
	const stored = await tx.doc(AgentDoc, id);
	if (!Array.isArray(stored.tools) || stored.tools.includes("work") === offered) return;
	stored.tools = offered ? [...stored.tools, "work"] : stored.tools.filter((name) => name !== "work");
}

function backendFor(engine: Engine, project: Project, writing: Write = {}): WorkBackend {
	if (project.repository === null) return localWorkBackend(engine, writing);
	const backend = githubWorkBackend(project, { call: writing.call, confirmedSwitch: writing.confirmedSwitch, assign: writing.assign });
	if (backend === undefined) throw new Error("GitHub work is not available yet.");
	return backend;
}

function localWorkBackend(engine: Engine, { call, launch, confirmedSwitch }: Write): WorkBackend {
	const stored = async () => (await engine.harness().snapshot(Work, engine.context()))?.projects ?? {};
	return {
		list: async (project, { states }) => Object.values((await stored())[project.id]?.items ?? {}).filter((item) => states === undefined || states.includes(item.state)),
		show: async (project, id) => {
			const item = (await stored())[project.id]?.items[String(id)];
			if (item === undefined) throw unknownItem(id);
			return item;
		},
		apply: async (project, action, id, by, args) => {
			const commit = async (tx: Tx) => {
				const receipt = call === undefined ? undefined : await tx.doc(WorkCall, call.api.taskId);
				if (receipt?.call === call?.api.callId && receipt !== undefined) {
					if (receipt.refused !== undefined) return { refused: receipt.refused };
					if (receipt.item !== null) return retained(receipt.item);
				}
				const { project: current, agents } = await checkWriterIn(tx, project.id, by, action, confirmedSwitch, false);
				const doc = await tx.doc(Work);
				if (doc.projects[project.id] === undefined) doc.projects[project.id] = { items: {}, next: 1 };
				const list = doc.projects[project.id]!;
				const key = id ?? list.next;
				const before = id === null ? null : list.items[String(id)] ?? null;
				if (id !== null && before === null) throw unknownItem(id);
				if (before !== null) checkWorkTransition(current, before, action, by, (id) => agents[id]?.name ?? id);
				const at = Date.now();
				const assigned = action === "assign" && before !== null ? await launch?.(tx, current, before) : undefined;
				if (assigned !== undefined && "limit" in assigned) {
					if (by.kind === "person") throw limitError(assigned.limit);
					const refused = limitRefusal(assigned.limit, current.conversation !== null);
					if (receipt !== undefined && call !== undefined) {
						receipt.call = call.api.callId;
						receipt.refused = refused;
					}
					return { refused };
				}
				const item = workTransition(before, key, action, by, args, at, assigned?.holder);
				if (id === null) list.next += 1;
				if (before === null || JSON.stringify(before) !== JSON.stringify(item)) {
					const change = await recordWork(tx, { projectId: project.id, action, by, before: before === null ? null : retained(before), after: item, ...(call === undefined ? {} : { callId: call.api.callId }) });
					if (receipt !== undefined && change !== undefined) receipt.change = change;
					await workNews(tx, current, by, workNewsText(item, action), String(item.id), at);
					list.items[String(key)] = item;
				}
				if (receipt !== undefined && call !== undefined) {
					receipt.call = call.api.callId;
					receipt.item = item;
					if (assigned?.note !== undefined) receipt.note = assigned.note;
				}
				return item;
			};
			const result = await (call === undefined ? engine.harness().commit(commit, engine.context()) : call.api.commit(commit, call.context));
			if ("refused" in result) throw new Error(result.refused);
			return result;
		},
	};
}

/**
 * The sub-chat of an assignment, made empty: `launchAssignment` gives it its task and starts it, inside the commit that
 * claims the work. Made on its own first so that a worktree can be made for it before the work is claimed (#596), as
 * `delegate` makes its sub-chat before handing it anything.
 */
async function newSubChat(tx: Tx, project: Project, target: AgentProfile, agent: AgentChange, title: string, parent: number): Promise<number> {
	const child = await tx.createConversation({ ownership: { kind: "ownerless" } });
	const id = child.id as unknown as number;
	await configure(tx, child.id, agent);
	const now = Date.now();
	(await tx.doc(Library)).conversations[String(id)] = { title, parent, projectId: project.id, createdAt: now, updatedAt: now, access: target.access, agentId: target.id, ...(target.allowEverything ? { allowEverything: true as const } : {}) };
	return id;
}

/** The branch named for a piece of work (#596): `work-12-tidy-the-login`, or `work-12` when its title has no words. */
export function branchForWork(item: Pick<WorkItem, "id" | "title">): string {
	const slug = branchSlug(item.title);
	return slug === "" ? `work-${item.id}` : `work-${item.id}-${slug}`;
}

/** `worktree` and `from` of an assignment, checked as `delegate` checks them (#596). */
function checkWorktreeArgs(args: Record<string, unknown>): void {
	const given = args.worktree;
	if (given !== undefined && given !== false && (typeof given !== "string" || given.trim() === "")) {
		throw new Error('`worktree` needs a branch name, such as "fix-login-timeout", or false for the project\'s folder.');
	}
	if (args.from !== undefined && typeof args.from !== "string") throw new Error("`from` must be a branch, a tag or a commit");
	if (args.from !== undefined && (given === undefined || given === false)) throw new Error("`from` says where a sub-chat's worktree starts; pass it with `worktree`.");
}

/**
 * The worktree an assignment's sub-chat should get (#596), or undefined for none: `worktree: false` asks for the
 * project's folder itself, a branch name is as given, and with neither one named for the work is made when the project's
 * folder is a git repository and the agent's own setting is off. An agent whose setting is on already gets its one
 * worktree, which is not made twice.
 */
async function plannedWorktree(project: Project, item: Pick<WorkItem, "id" | "title">, target: AgentProfile, options: { worktree?: unknown; from?: unknown }, folder: string | null): Promise<{ branch: string; from?: string } | undefined> {
	const from = typeof options.from === "string" && options.from.trim() !== "" ? options.from.trim() : undefined;
	const given = options.worktree;
	if (given === false) return undefined;
	if (typeof given === "string") return { branch: given.trim(), ...(from === undefined ? {} : { from }) };
	// An agent whose own setting gives every conversation a worktree: its one, on the branch pi² names for the sub-chat,
	// when the sub-chat's folder is in a repository, as `delegate` gives it (#604).
	if (target.worktree === true) {
		const branch = await subChatBranch(undefined, target, folder);
		return branch === undefined ? undefined : { branch };
	}
	if (project.folder === null || (await repoOf(project.folder)) === undefined) return undefined;
	return { branch: branchForWork(item), ...(from === undefined ? {} : { from }) };
}

type Reader = DocumentReader & { commit<T>(edit: (tx: Tx) => Promise<T>, context: Context): Promise<T> };

const whoPerson: Who = { kind: "person" };
const toolText = (text: string) => [{ type: "text" as const, text }];
const NO_SUBMIT = "This project has no current orchestrator conversation. Start one before assigning work.";
const watchKey = (id: number) => `work:assign:${id}`;

export const work: Feature = (host, engine) => {
	let current: WorkDoc = { projects: {} };
	let last = "";
	let reads = 0;
	const event = () => ({ event: "work", projects: Object.fromEntries(Object.entries(current.projects).map(([id, list]) => [id, Object.values(list.items)])) });
	const reload = async () => {
		const seq = ++reads;
		const stored = await engine.harness().snapshot(Work, engine.context());
		if (seq !== reads) return;
		current = stored === undefined ? { projects: {} } : retained(stored);
		const next = event();
		const line = JSON.stringify(next);
		if (line === last) return;
		last = line;
		engine.broadcast(next);
	};

	const getProject = (id: string, write = false) => {
		const projects = allProjects();
		return liveProject(Object.hasOwn(projects, id) ? projects[id] : undefined, id, write);
	};
	const getAgent = (project: Project, name: string, allowName: boolean): AgentProfile => {
		const candidates = Object.values(engine.agents()).filter((agent) => agent.projectId === project.id && agent.removedAt === undefined);
		const target = candidates.find((agent) => agent.id === name || (allowName && agent.name.toLowerCase() === name.toLowerCase()));
		if (target === undefined) throw new Error(`Unknown agent: ${name}`);
		return target;
	};

	const mutate = async (project: Project, by: Who, action: WorkAction, id: number | null, args: Record<string, unknown>, call?: Call, onStarted?: (note: string | undefined) => void): Promise<WorkItem> => {
		const access = by.kind === "agent" ? host.meta(conversationId(by.conversationId))?.access : undefined;
		actor(project, by, action, access);
		const backend = backendFor(engine, project);
		const row = table[action];
		const before = id === null || (action !== "assign" && row.switch === undefined) ? null : await backend.show(project, id);
		if (before !== null) checkWorkTransition(project, before, action, by, (id) => host.agent(id)?.name ?? id);
		const target = action === "assign" ? getAgent(project, (stringOf(args, by.kind === "person" ? "agentId" : "agent") ?? "").trim(), by.kind === "agent") : undefined;
		if (action === "file") workTransition(null, 1, action, by, args, 0);
		if (action === "close" || action === "finish") workTransition(before, id!, action, by, args, 0);
		const extra = action === "assign" ? stringOf(args, "task") : undefined;
		const title = action === "assign" ? titleOf(stringOf(args, "title")) : undefined;
		const confirm = action === "assign" ? stringOf(args, "confirmLimit") : undefined;
		if (action === "assign") checkWorktreeArgs(args);
		let confirmedSwitch: SwitchName | undefined;
		if (by.kind === "agent" && call !== undefined && row.switch !== undefined) {
			const what = action === "assign" ? `Start ${target!.name} on work #${id} “${before!.title}”?` : action === "file" ? `File work “${workTitle(stringOf(args, "title"))}”?` : `${action === "finish" ? "Finish" : "Close"} work #${id} “${before!.title}”?`;
			const asks = inProject(by.conversationId)?.settings.withoutAsking[row.switch] === false;
			const answer = await requireSwitch({ conversationId: by.conversationId, id: String(call.api.taskId), callId: call.api.callId, tool: "work", arguments: { action, ...(id === null ? {} : { id }), ...args }, ...call }, row.switch, what);
			if (!answer.ok) throw new Error(answer.reason);
			if (asks) confirmedSwitch = row.switch;
		}
		if (target === undefined) return backendFor(engine, project, { call, confirmedSwitch }).apply(project, action, id, by, args);
		const parent = project.conversation;
		if (parent === null) throw new Error(NO_SUBMIT);
		const context = call?.context ?? engine.context();
		const reader = call?.api ?? engine.harness();
		const parentFolder = (await reader.snapshot(AgentDoc, conversationId(parent), context))?.cwd ?? null;
		const agent = { ...await host.agentChange(target, { subChat: true }), cwd: await subChatFolder(parentFolder, target.cwd) };
		const startOf = (item: WorkItem): Start => {
			const task = [`Work #${item.id}: ${item.title}`, item.text, extra].filter(Boolean).join("\n\n");
			const options = { ...(args.worktree === undefined ? {} : { worktree: args.worktree }), ...(args.from === undefined ? {} : { from: args.from }) };
			return { by, agentId: target.id, agentName: target.name, kind: "assign", parent, chat: null, work: item.id, title: title ?? titleOf(item.title)!, task, options };
		};
		// The sub-chat is made before the work is claimed, so that its worktree can be made before anything is handed over
		// (#596): a worktree that cannot be made then refuses the start with nothing claimed and no run begun.
		const plan = await plannedWorktree(project, before!, target, { worktree: args.worktree, from: args.from }, agent.cwd ?? null);
		const named = title ?? titleOf(before!.title)!;
		const writer = call === undefined ? engine.harness() : call.api;
		// The admission check comes before a worktree is made (#604), so that a start a limit holds back makes no branch to
		// remove again. Admitted here, it is not checked a second time at the claim.
		let admittedEarly: { note?: string } | undefined;
		if (plan !== undefined) {
			const outcome = await writer.commit(async (tx: Tx): Promise<{ note?: string } | { limit: LimitReading } | { refused: string }> => {
				const admitted = await admit(startOf(before!), confirm, { tx, model: agent.model, callId: call?.api.callId });
				if (admitted.ok) return admitted.note === undefined ? {} : { note: admitted.note };
				if (by.kind === "person") return { limit: admitted.limit };
				const refused = limitRefusal(admitted.limit, project.conversation !== null);
				if (call !== undefined) await workReceipt(tx, call, { item: null, refused });
				return { refused };
			}, context);
			if ("limit" in outcome) throw limitError(outcome.limit);
			if ("refused" in outcome) throw new Error(outcome.refused);
			admittedEarly = outcome;
		}
		const child = plan === undefined ? undefined : await writer.commit((tx: Tx) => newSubChat(tx, project, target, agent, named, parent), context);
		if (plan !== undefined && child !== undefined) {
			const reason = await giveWorktree(reader as Reader, child, plan.branch, plan.from, context);
			if (reason !== undefined) {
				await dropSubChat(reader as Reader, child, context);
				throw new Error(`No worktree could be made for the sub-chat, so nothing was handed over: ${reason}`);
			}
		}
		const launch: Runner = async (tx, current, item) => {
			const result = await launchAssignment(tx, current, startOf(item), target, agent, { confirm, callId: call?.api.callId, ...(child === undefined ? {} : { child }), ...(admittedEarly === undefined ? {} : { admitted: admittedEarly }) });
			if ("holder" in result) onStarted?.(result.note);
			return result;
		};
		// On GitHub the claim is no commit of pi²'s: the admission check comes first, then the claim, then the start (github.ts).
		const assign: GithubAssign = {
			agentId: target.id,
			admit: async (tx, _current, item) => (admittedEarly === undefined ? admit(startOf(item), confirm, { tx, model: agent.model, callId: call?.api.callId }) : { ok: true as const, ...admittedEarly }),
			start: async (tx, current, item, admitted) => {
				const result = await launchAssignment(tx, current, startOf(item), target, agent, { admitted, ...(child === undefined ? {} : { child }) });
				if (!("holder" in result)) throw new Error("The start was held back after it was admitted.");
				onStarted?.(result.note);
				return result.holder;
			},
		};
		try {
			return await backendFor(engine, project, { launch, call, confirmedSwitch, assign }).apply(project, action, id, by, args);
		} catch (error) {
			// The claim was refused, or the item was taken meanwhile: the sub-chat made for it is put away again (#596).
			if (child !== undefined) await dropSubChat(reader as Reader, child, context);
			throw error;
		}
	};

	/**
	 * Put away a sub-chat made for an assignment that never started: it has no message in it worth keeping, and neither
	 * has its worktree, so the branch goes too and the item is as it was (#596).
	 */
	async function dropSubChat(reader: Reader, child: number, context: Context): Promise<void> {
		try {
			const meta = (await reader.snapshot(Library, context))?.conversations[String(child)];
			if (meta === undefined || meta.subChatTask !== undefined) return;
			if ((await worktreeOf(reader, child, context)) !== undefined) {
				await removeWorktree(child, { force: true, deleteBranch: true }).catch((error) => engine.log("could not remove the worktree of a sub-chat that did not start:", error instanceof Error ? error.message : error));
			}
			await reader.commit(async (tx) => {
				const stored = (await tx.doc(Library)).conversations[String(child)];
				if (stored !== undefined && stored.subChatTask === undefined) stored.deleted = true;
			}, context);
		} catch (error) {
			engine.log("could not put away a sub-chat of an assignment that did not start:", error instanceof Error ? error.message : error);
		}
	}

	/** `admitted`: the admission check was made already, before a claim on GitHub, and is not made again. */
	async function launchAssignment(tx: Tx, current: Project, start: Start, target: AgentProfile, agent: AgentChange, options: { confirm?: string; callId?: string; card?: LimitReading[]; admitted?: { note?: string }; child?: number }): Promise<Launched | { limit: LimitReading }> {
			const parent = start.parent!;
			const library = (await tx.doc(Library)).conversations;
			const parentMeta = library[String(parent)];
			if (current.conversation !== parent || parentMeta?.projectId !== current.id || parentMeta.parent !== undefined || isPutAway(parentMeta)) throw new Error(NO_SUBMIT);
			const saved = (await tx.doc(Agents)).agents[target.id];
			if (saved?.projectId !== current.id || saved.removedAt !== undefined) throw new Error(`Unknown agent: ${target.id}`);
			if (JSON.stringify(saved) !== JSON.stringify(target)) throw new Error(`${target.name}'s settings changed. Look at the agent and try again.`);
			const admitted = options.admitted === undefined ? await admit(start, options.confirm, { tx, model: agent.model, callId: options.callId, card: options.card }) : { ok: true as const, ...options.admitted };
			if (!admitted.ok) return { limit: admitted.limit };
			const budget = engine.overBudget();
			if (budget !== undefined) throw new Error(`${budget} Raise it in Usage to carry on.`);
			const named = start.title!;
			const task = start.task;
			const now = Date.now();
			// Made already, when a worktree was made for it before the claim (#596).
			const id = options.child ?? (await newSubChat(tx, current, target, agent, named, parent));
			const child = conversationId(id);
			// A normal submit(tx, ...) needs a committed conversation handle and must precede all table writes.
			// This child is brand new: no inbox, run, or prior request to check. Place its first input and start its
			// conversation-owned generation exactly as an idle submit would, without a gap after the claim.
			const entry = await tx.appendEntry(UserEntry, child, { model: [{ role: "user", content: task, timestamp: now }] });
			const submission = await tx.createSubmission({ conversationId: child, type: "input", status: "placed", entry: entry.id });
			const taskId = await tx.createTask(GenerationTask, {}, { ownership: { kind: "conversation" }, conversationId: child });
			(await tx.doc(LiveDoc, child)).run = { taskId, inputs: [submission.id], first: entry.id, turns: 0 };
			library[String(id)] = { title: named, parent, projectId: current.id, createdAt: now, updatedAt: now, access: target.access, agentId: target.id, subChatTask: submission.id as number, ...(saved.allowEverything ? { allowEverything: true as const } : {}) };
			await stageReportRun(tx, current.id, { submissionId: submission.id as number, conversationId: id, agentId: target.id, title: named, work: start.work! });
			(await tx.doc(Wakes)).watching[watchKey(id)] = { key: watchKey(id), conversationId: parent, kind: "subchat", ref: String(id), label: `sub-chat ${id} “${named}”`, startedAt: now, submissionId: submission.id as number, agent: target.name };
			return { holder: { agentId: target.id, conversationId: id }, note: admitted.note };
	}

	onLimitAssignment(async (tx, need) => {
		const { start, projectId } = need;
		const current = liveProject((await tx.doc(Projects)).projects[projectId], projectId, true);
		if (current.repository !== null) {
			// On GitHub: the card's readings are checked in this commit; the claim and the start follow it (github.ts).
			if (github === undefined) throw new Error("GitHub work is not available yet.");
			const target = (await tx.doc(Agents)).agents[start.agentId];
			if (target?.projectId !== projectId || target.removedAt !== undefined) throw new Error(`Unknown agent: ${start.agentId}`);
			const here = (await tx.doc(AgentDoc, conversationId(start.parent!))).cwd ?? null;
			const agent = retained({ ...await host.agentChange(retained(target), { subChat: true }), cwd: await subChatFolder(here, target.cwd) });
			const admitted = await admit(start, undefined, { tx, model: agent.model, card: rememberReading(need.confirmed ?? [], need.limit) });
			if (!admitted.ok) return { limit: admitted.limit };
			// What the commit's documents gave is read again only through copies once it is made.
			const saved = retained(target);
			const held = retained(start);
			const project = retained(current);
			const hooks = github;
			const plan = await plannedWorktree(project, { id: held.work!, title: held.title ?? "" }, saved, held.options, agent.cwd ?? null);
			return {
				child: null,
				after: async () => {
					const item = await hooks.assignHeld(project, held, async (later) => {
						const now = liveProject((await later.doc(Projects)).projects[projectId], projectId, true);
						const result = await launchAssignment(later, now, held, saved, agent, { admitted: { note: admitted.note } });
						if (!("holder" in result)) throw new Error("The start was held back after it was admitted.");
						return result.holder;
					});
					await placeWorktreeLater(projectId, item.takenBy!.conversationId, plan);
					await followAssignment(item);
				},
			};
		}
		const list = (await tx.doc(Work)).projects[projectId];
		const key = String(start.work);
		const item = list?.items[key];
		if (item === undefined) throw unknownItem(start.work!);
		checkWorkTransition(current, item, "assign", whoPerson, (id) => host.agent(id)?.name ?? id);
		const target = (await tx.doc(Agents)).agents[start.agentId];
		if (target?.projectId !== projectId || target.removedAt !== undefined) throw new Error(`Unknown agent: ${start.agentId}`);
		const here = (await tx.doc(AgentDoc, conversationId(start.parent!))).cwd ?? null;
		const agent = { ...await host.agentChange(target, { subChat: true }), cwd: await subChatFolder(here, target.cwd) };
		const plan = await plannedWorktree(current, item, target, start.options, agent.cwd ?? null);
		const result = await launchAssignment(tx, current, start, target, agent, { card: rememberReading(need.confirmed ?? [], need.limit) });
		if ("limit" in result) return result;
		const assigned = workTransition(item, item.id, "assign", whoPerson, {}, Date.now(), result.holder);
		await recordWork(tx, { projectId, action: "assign", by: whoPerson, before: retained(item), after: assigned });
		list!.items[key] = assigned;
		// The sub-chat was made in this commit, so its worktree comes after it (#596).
		return { child: result.holder.conversationId, after: async () => { await placeWorktreeLater(projectId, result.holder.conversationId, plan); await followAssignment(assigned); } };
	});

	/**
	 * A worktree for an assignment the person allowed from a limit card (#596). Its sub-chat is made in the card's commit,
	 * so the worktree comes after it; one that cannot be made leaves the sub-chat in the project's folder, and the
	 * orchestrator is told, since the person's answer has already started it.
	 */
	async function placeWorktreeLater(projectId: string, child: number, plan: { branch: string; from?: string } | undefined): Promise<void> {
		if (plan === undefined) return;
		const reason = await giveWorktree(engine.harness() as Reader, child, plan.branch, plan.from, engine.context());
		if (reason === undefined) return;
		engine.log("could not give sub-chat", child, "its worktree:", reason);
		await engine.harness().commit((tx) => addNews(tx, projectId, { kind: "work", ref: String(child), text: `Sub-chat ${child} was started without its worktree: ${reason}`, at: Date.now() }), engine.context());
	}

	/** The watch was stored with the child. Attach its live waiter; recovery attaches it again if we stopped first. */
	const followAssignment = async (item: WorkItem) => {
		const key = watchKey(item.takenBy!.conversationId);
		try {
			const pending = (await engine.harness().snapshot(Wakes, engine.context()))?.watching[key];
			if (pending?.submissionId !== undefined) {
				const holder = item.takenBy!;
				const title = host.meta(conversationId(holder.conversationId))?.title ?? titleOf(item.title)!;
				// Reload and follow the staged report before attaching its watch, as delegate does.
				await reportRun(pending.conversationId, { submissionId: pending.submissionId, conversationId: holder.conversationId, agentId: holder.agentId, title, work: item.id });
				await watch(pending);
			}
		} catch (error) {
			engine.log("could not follow assigned work:", error);
		}
	};

	const tool = defineTool({
		name: "work",
		description: "Keep this project's work list. Use list or show to read it (list answers a line an item, show one item's text and notes); file, take, release, note, wait, block, resume or finish to keep it up to date. Only the orchestrator can assign, close, reopen, edit or classify work. When the work list is a GitHub repository's issues: pull_request opens a pull request from the branch this conversation's folder is on (with id, it fixes that issue), and review posts what you found on pull request id; only the orchestrator can merge a pull request or send_back one to the conversation that opened it.",
		parameters: obj({
			action: str({ description: "list, show, file, take, assign, release, wait, block, resume, finish, close, reopen, note, edit, classify, pull_request, review, merge, or send_back" }),
			id: opt(int({ description: "Work item number (on GitHub, the issue's); for review, merge and send_back, the pull request's" })),
			text: opt(str({ description: "Note, reason for wait or block, result of finish, the work's text for file or edit, the finding for review, or the reason for send_back" })),
			title: opt(str({ description: "Work title for file or edit; sub-chat title for assign; pull request title for pull_request" })),
			states: opt(arr(str(), { description: "States to list; defaults to open, in_progress, waiting and blocked" })),
			class: opt(str({ description: "local or cloud, for file or classify" })),
			agent: opt(str({ description: "Project agent to assign the work to" })),
			task: opt(str({ description: "What to tell the assigned agent beyond the work's own text" })),
			as: opt(str({ description: "done or dropped, for close" })),
			worktree: opt(
				union([str(), lit(false)], {
					description: "assign: the branch for a git worktree of the sub-chat, as `delegate`'s `worktree`; false to keep it in the project's folder; without it a worktree named for the work is made when the project's folder is a git repository and the agent's own setting is off",
				}),
			),
			from: opt(str({ description: "With `worktree`: what the new branch starts from, as `delegate`'s `from`" })),
			base: opt(str({ description: "pull_request: the branch to merge into; defaults to the repository's default branch" })),
			verdict: opt(str({ description: "review: approve, changes or comment" })),
		}),
		replay: "safe",
		execute: async ({ action, id, ...args }, api, context) => {
			try {
				const number = api.conversationId as unknown as number;
				const meta = host.meta(api.conversationId);
				const project = inProject(number);
				const agentId = runsAs(meta, engine.agents());
				const classGiven = args.class !== undefined;
				const receipt = await api.snapshot(WorkCall, api.taskId, context);
				if (receipt?.call === api.callId && receipt.refused !== undefined) throw new Error(receipt.refused);
				if (receipt?.call === api.callId && receipt.text !== undefined) return { output: toolText(receipt.text), ...(receipt.change === undefined ? {} : { details: { change: receipt.change } }) };
				let item = receipt?.call === api.callId ? receipt.item : null;
				if (item === null) {
					requirePreview();
					if (project === undefined || agentId === undefined || project.earlier.includes(number) || isPutAway(meta)) throw new Error("Use work from a current conversation in this project.");
					if (pullActions.includes(action)) {
						if (project.repository === null) throw new Error("This project's work is kept by pi², which has no pull requests.");
						if (github === undefined) throw new Error("GitHub work is not available yet.");
						const by: Who = { kind: "agent", agentId, conversationId: number };
						if (!canWrite(meta?.access)) throw new Error(writeRefusal);
						if ((action === "merge" || action === "send_back") && !orchestrates(project, by)) throw new Error(`Only the orchestrator can ${action === "merge" ? "merge a pull request" : "send a pull request back"}. Tell it in your report.`);
						const done = await github.pull(project, action as PullAction, by, { id, ...args }, { api, context });
						return { output: toolText(done.text), ...(done.change === undefined ? {} : { details: { change: done.change } }) };
					}
					const names = (id: string) => host.agent(id)?.name ?? id;
					if (action === "list") {
						const items = await backendFor(engine, project).list(project, { states: filtered(args.states) ?? openStates });
						return { output: toolText(listAnswer(project, items, names)) };
					}
					if (action === "show") return { output: toolText(showAnswer(await backendFor(engine, project).show(project, numberId(id)), names)) };
					const by: Who = { kind: "agent", agentId, conversationId: number };
					// Only the orchestrator classifies (docs/issue-classes.md): another agent's item is filed unclassed (#604).
					if (action === "file" && args.class !== undefined && !orchestrates(project, by)) delete args.class;
					if (args.class !== undefined && args.class !== "local" && args.class !== "cloud") throw new Error("class must be local or cloud");
					// An assigned sub-chat that takes its own work is told it is its already, with no error (#604).
					if (action === "take") {
						const now = await backendFor(engine, project).show(project, numberId(id));
						const yours = yoursAlready(now, by);
						if (yours !== undefined) return { output: toolText(`${yours}\n\n${JSON.stringify(now)}`) };
					}
					item = await mutate(project, by, actionOf(action), action === "file" ? null : numberId(id), args, { api, context });
				}
				// The change an agent's write was recorded as, for the conversation's line with Undo (docs/projects.md, 3.12).
				const change = (await api.snapshot(WorkCall, api.taskId, context))?.change;
				const recorded: { change?: number } = change === undefined ? {} : { change };
				if (action !== "assign") {
					const unclassed = action === "file" && classGiven && project !== undefined && agentId !== undefined && !orchestrates(project, { kind: "agent", agentId, conversationId: number });
					const said = unclassed ? "\n\nFiled without a class: only the orchestrator classifies work, and it will." : "";
					return { output: toolText(`${JSON.stringify(item)}${said}`), ...(change === undefined ? {} : { details: { change } }) };
				}
				const holder = item.takenBy!;
				await followAssignment(item);
				const name = host.agent(holder.agentId)?.name ?? holder.agentId;
				const title = host.meta(conversationId(holder.conversationId))?.title ?? titleOf(args.title) ?? titleOf(item.title)!;
				const note = (await api.snapshot(WorkCall, api.taskId, context))?.note;
				const own = await worktreeOf(api, holder.conversationId, context);
				const place = own === undefined ? undefined : `The sub-chat works in a worktree of its own at ${own.path}, on the branch ${own.branch}.`;
				return { output: toolText([startedWords(holder.conversationId, name, title, handOffWords(number)), place, note].filter(Boolean).join("\n\n")), details: { conversationId: holder.conversationId, agentId: holder.agentId, agentName: name, ...recorded } };
			} catch (error) {
				const message = error instanceof Error ? error.message : String(error);
				return { output: toolText(message), isError: true };
			}
		},
	});

	return {
		tools: [tool],
		toolNames: (_access, agent, where) => {
			if (where.conversationId !== undefined) {
				return offersWork(inProject(where.conversationId), where.conversationId) ? ["work"] : [];
			}
			// A new sub-chat uses its parent's project (including no project), never its target's profile.
			const id = where.projectId === undefined ? agent?.projectId : where.projectId;
			if (!projectsOn() || id == null) return [];
			return offersWork(allProjects()[id]) ? ["work"] : [];
		},
		start: async () => {
			await reload();
			engine.harness().observeCommits({
				advance: ({ changes }) => {
					if (changes.some((change) => (change.type === "document" || change.type === "document.copy") && change.record.kind === "pi2.work")) {
						void reload().catch((error) => engine.log("could not read work again:", error));
					}
				},
				end: () => {},
			});
		},
		greeting: () => [event()],
		handlers: {
			"work.list": async (params) => {
				requirePreview();
				const project = getProject(projectId(params.projectId));
				const items = await backendFor(engine, project).list(project, { states: filtered(params.states) });
				return { items, readAt: project.repository === null || github === undefined ? null : github.readAt(project) };
			},
			"work.create": async ({ projectId: id, title, text, class: modelClass }) => {
				requirePreview();
				const item = await mutate(getProject(projectId(id), true), whoPerson, "file", null, { title, text, class: modelClass });
				return { id: item.id };
			},
			"work.act": async ({ projectId: project, id, action: given, text, title, class: modelClass, agentId, task, as, confirmLimit, worktree, from }) => {
				requirePreview();
				const action = actionOf(given);
				if (action === "file") throw new Error("Use work.create to file work.");
				let note: string | undefined;
				// No `worktree` from the app's Give to: the same default an agent's `assign` gets (#596).
				const item = await mutate(getProject(projectId(project), true), whoPerson, action, numberId(id), { text, title, class: modelClass, agentId, task, as, confirmLimit, ...(worktree === undefined ? {} : { worktree }), ...(from === undefined ? {} : { from }) }, undefined, (value) => { note = value; });
				if (action !== "assign") return { item };
				await followAssignment(item);
				return { item, conversation: item.takenBy!.conversationId, ...(note === undefined ? {} : { note }) };
			},
		},
	};
};
