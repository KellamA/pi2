// One work list per project (docs/projects.md, 3.11). Only the backend knows where the items are kept.

import type { Context } from "@earendil-works/chord/context";
import { AgentDoc, configure, type ConversationId, defineDoc, defineTool, GenerationTask, LiveDoc, type ToolExecutionApi, type Tx, UserEntry } from "@earendil-works/pi-durable";
import { arr, int, obj, opt, str } from "@earendil-works/pi-schema";
import { isPutAway } from "./archive.ts";
import { startedWords, titleOf } from "./extensions.ts";
import type { Engine, Feature } from "./features.ts";
import { addNews, allProjects, inProject, type LimitReading, type Project, PROJECT_ARCHIVED, Projects, projectsOn, requirePreview, requireSwitch, type Start, type SwitchName, type Who } from "./projects.ts";
import { admit, limitError, limitRefusal, rememberReading } from "./projectlimits.ts";
import { onLimitAssignment } from "./projectlimitstarts.ts";
import { recordWorkChange } from "./changes.ts";
import { handOffWords, reportRun, stageReportRun } from "./reports.ts";
import { Agents, type Access, type AgentProfile, Library, type Meta, runsAs } from "./state.ts";
import { Wakes, watch } from "./wakes.ts";
import { subChatFolder } from "./worktrees.ts";

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
const heldBy = (item: WorkItem | null, by: Who) => by.kind === "agent" && item?.takenBy?.agentId === by.agentId && item.takenBy.conversationId === by.conversationId;

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
	if (row.holder === "none") item.takenBy = null;
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
			return { by, agentId: target.id, agentName: target.name, kind: "assign", parent, chat: null, work: item.id, title: title ?? titleOf(item.title)!, task, options: {} };
		};
		const launch: Runner = async (tx, current, item) => {
			const result = await launchAssignment(tx, current, startOf(item), target, agent, { confirm, callId: call?.api.callId });
			if ("holder" in result) onStarted?.(result.note);
			return result;
		};
		// On GitHub the claim is no commit of pi²'s: the admission check comes first, then the claim, then the start (github.ts).
		const assign: GithubAssign = {
			agentId: target.id,
			admit: (tx, _current, item) => admit(startOf(item), confirm, { tx, model: agent.model, callId: call?.api.callId }),
			start: async (tx, current, item, admitted) => {
				const result = await launchAssignment(tx, current, startOf(item), target, agent, { admitted });
				if (!("holder" in result)) throw new Error("The start was held back after it was admitted.");
				onStarted?.(result.note);
				return result.holder;
			},
		};
		return backendFor(engine, project, { launch, call, confirmedSwitch, assign }).apply(project, action, id, by, args);
	};

	/** `admitted`: the admission check was made already, before a claim on GitHub, and is not made again. */
	async function launchAssignment(tx: Tx, current: Project, start: Start, target: AgentProfile, agent: Awaited<ReturnType<typeof host.agentChange>>, options: { confirm?: string; callId?: string; card?: LimitReading[]; admitted?: { note?: string } }): Promise<Launched | { limit: LimitReading }> {
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
			const child = await tx.createConversation({ ownership: { kind: "ownerless" } });
			const id = child.id as unknown as number;
			await configure(tx, child.id, agent);
			// A normal submit(tx, ...) needs a committed conversation handle and must precede all table writes.
			// This child is brand new: no inbox, run, or prior request to check. Place its first input and start its
			// conversation-owned generation exactly as an idle submit would, without a gap after the claim.
			const entry = await tx.appendEntry(UserEntry, child.id, { model: [{ role: "user", content: task, timestamp: now }] });
			const submission = await tx.createSubmission({ conversationId: child.id, type: "input", status: "placed", entry: entry.id });
			const taskId = await tx.createTask(GenerationTask, {}, { ownership: { kind: "conversation" }, conversationId: child.id });
			(await tx.doc(LiveDoc, child.id)).run = { taskId, inputs: [submission.id], first: entry.id, turns: 0 };
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
			return {
				child: null,
				after: async () => {
					const item = await hooks.assignHeld(project, held, async (later) => {
						const now = liveProject((await later.doc(Projects)).projects[projectId], projectId, true);
						const result = await launchAssignment(later, now, held, saved, agent, { admitted: { note: admitted.note } });
						if (!("holder" in result)) throw new Error("The start was held back after it was admitted.");
						return result.holder;
					});
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
		const result = await launchAssignment(tx, current, start, target, agent, { card: rememberReading(need.confirmed ?? [], need.limit) });
		if ("limit" in result) return result;
		const assigned = workTransition(item, item.id, "assign", whoPerson, {}, Date.now(), result.holder);
		await recordWork(tx, { projectId, action: "assign", by: whoPerson, before: retained(item), after: assigned });
		list!.items[key] = assigned;
		return { child: result.holder.conversationId, after: () => followAssignment(assigned) };
	});

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
		description: "Keep this project's work list. Use list or show to read it; file, take, release, note, wait, block, resume or finish to keep it up to date. Only the orchestrator can assign, close, reopen, edit or classify work. When the work list is a GitHub repository's issues: pull_request opens a pull request from the branch this conversation's folder is on (with id, it fixes that issue), and review posts what you found on pull request id; only the orchestrator can merge a pull request or send_back one to the conversation that opened it.",
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
					const listed = (value: unknown) => toolText(project.repository === null || github === undefined ? JSON.stringify(value) : `${JSON.stringify(value)}\n\n${github.listingNote(project)}`);
					if (action === "list") return { output: listed(await backendFor(engine, project).list(project, { states: filtered(args.states) ?? openStates })) };
					if (action === "show") return { output: listed(await backendFor(engine, project).show(project, numberId(id))) };
					if (args.class !== undefined && args.class !== "local" && args.class !== "cloud") throw new Error("class must be local or cloud");
					item = await mutate(project, { kind: "agent", agentId, conversationId: number }, actionOf(action), action === "file" ? null : numberId(id), args, { api, context });
				}
				// The change an agent's write was recorded as, for the conversation's line with Undo (docs/projects.md, 3.12).
				const change = (await api.snapshot(WorkCall, api.taskId, context))?.change;
				const recorded: { change?: number } = change === undefined ? {} : { change };
				if (action !== "assign") return { output: toolText(JSON.stringify(item)), ...(change === undefined ? {} : { details: { change } }) };
				const holder = item.takenBy!;
				await followAssignment(item);
				const name = host.agent(holder.agentId)?.name ?? holder.agentId;
				const title = host.meta(conversationId(holder.conversationId))?.title ?? titleOf(args.title) ?? titleOf(item.title)!;
				const note = (await api.snapshot(WorkCall, api.taskId, context))?.note;
				return { output: toolText([startedWords(holder.conversationId, name, title, handOffWords(number)), note].filter(Boolean).join("\n\n")), details: { conversationId: holder.conversationId, agentId: holder.agentId, agentName: name, ...recorded } };
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
			"work.act": async ({ projectId: project, id, action: given, text, title, class: modelClass, agentId, task, as, confirmLimit }) => {
				requirePreview();
				const action = actionOf(given);
				if (action === "file") throw new Error("Use work.create to file work.");
				let note: string | undefined;
				const item = await mutate(getProject(projectId(project), true), whoPerson, action, numberId(id), { text, title, class: modelClass, agentId, task, as, confirmLimit }, undefined, (value) => { note = value; });
				if (action !== "assign") return { item };
				await followAssignment(item);
				return { item, conversation: item.takenBy!.conversationId, ...(note === undefined ? {} : { note }) };
			},
		},
	};
};
