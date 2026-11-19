// The record of changes (#465): docs/projects.md, 3.12, with the reach requests of 7.2 and the requests `changes.*`.
//
// Every change an agent makes to its project through a tool, and every change the person allowed from a reach request,
// is recorded here as a typed operation (`Op`), with its own inverse or none, in the same commit as the change itself.
// The conversation shows each as a line (`projectChanges` in its state), with Undo where it has an inverse; the person
// undoes one with `changes.undo`, the orchestrator with `project_settings` `undo` (projecttools.ts).
//
// Each operation is applied by the same function that applies the person's own request for it: `engine.saveAgent` for
// an agent's settings (agents.save's checks), `applyProjectChange` for a project's (projects.set's), the rule helpers of
// projectrules.ts (projects.rules.*), the note helpers of projectnotes.ts. So an operation cannot do what the person's
// request could not. An Undo checks first that the target is still what the operation left it, and is itself a change.
//
// What other issues fill in, and what it does until then:
//
// - `work.local` and `work.github` (#467, #468) and `wake.choice` (#463) register what they do with `defineOp`. Until
//   then nothing records one, and an Undo or a request of one is refused.
// - `orchestrator.set` is made by #466's `projects.setOrchestrator`, which makes the roles and the fresh conversation in a
//   commit of its own: allowing it is checked in the commit that takes the answer, and made once that is stored.

import { defineDoc, type JsonObject, type Tx } from "@earendil-works/pi-durable";
import type { Host } from "./extensions.ts";
import type { Engine, Feature } from "./features.ts";
import { Memory } from "./knowledge.ts";
import { type AnswerOutcome, needsIn, onAnswer, putNeed, type ReachChange, type StoredNeed } from "./needs.ts";
import { answerGoesTo } from "./orchestrator.ts";
import { removeAgentIn } from "./projectagents.ts";
import { type ProjectNote, putBackProjectNote, removeProjectNote } from "./projectnotes.ts";
import { addRule, editRule, moveRule, type ProjectRule, putBackRule, removeRule, rulesIn } from "./projectrules.ts";
import { addNews, allProjects, applyProjectChange, inProject, PROJECT_ARCHIVED, Projects, projectsOn, requirePreview, type Who } from "./projects.ts";
import { projectTools, TOOL_NAMES } from "./projecttools.ts";
import { agentFieldWidens, agentValues, copy, type Field, projectFieldWidens, projectValues, same } from "./reach.ts";
import { type ReportWake, setWakeChoicesIn, wakeChoicesIn } from "./reports.ts";
import type { CommandRule } from "./rules.ts";
import { Work, type WorkAction, type WorkItem, type WorkOperation } from "./work.ts";
import { type AgentProfile, Agents, Library, runsAs } from "./state.ts";
import { arrivedIn, arriveIn, reloadWakes } from "./wakes.ts";

export type { Field } from "./reach.ts";

// ---- What is stored (3.12)

/** Each kind of operation: what it touches, all of it. None holds a secret: variables' values never appear here. */
export type Op =
	| { kind: "agent.make"; agent: AgentProfile }
	| { kind: "agent.change"; id: string; fields: Field[] }
	| { kind: "agent.remove"; id: string }
	| { kind: "agent.restore"; id: string }
	| { kind: "project.change"; fields: Field[] }
	| { kind: "rule.add"; rule: ProjectRule; at?: number }
	| { kind: "rule.remove"; rule: ProjectRule; at: number }
	| { kind: "rule.edit"; id: string; before: { text: string; binds: string }; after: { text: string; binds: string } }
	| { kind: "rule.move"; id: string; from: number; to: number }
	| { kind: "note.add"; note: ProjectNote }
	| { kind: "note.remove"; note: ProjectNote }
	// before or after empty ({}): the item was not there (filed, or the Undo of filing).
	| { kind: "work.local"; id: number; action: WorkAction; before: Partial<WorkItem>; after: Partial<WorkItem> }
	| { kind: "work.github"; intent: string; action: WorkAction | "pull_request" | "review" | "merge" | "send_back"; summary: string }
	// after: one choice for every run, or one each (an Undo's); batches: the batch each run was in, and is put in.
	| { kind: "wake.choice"; submissions: number[]; before: (string | null)[]; after: string | (string | null)[]; batches?: { before: (string | null)[]; after: (string | null)[] } }
	| { kind: "orchestrator.set"; from: string; to: string };

/** Who made a change: an agent through a tool, the person by allowing what an agent asked for, or the person's Undo. */
export type ChangeBy =
	| { kind: "agent"; agentId: string; conversationId: number; callId: string }
	| { kind: "allowed"; need: string; agentId: string; conversationId: number }
	| { kind: "person" };

export type Change = {
	/** 1, 2, 3… across all projects. */
	id: number;
	at: number;
	by: ChangeBy;
	op: Op;
	/** One line, as the conversation shows it: "Made the agent Reviewer (the default model, Ask first)". */
	summary: string;
	/** Null: it has no Undo (5.9 says which, and why). */
	inverse: Op | null;
	undone?: { at: number; by: Who; change: number };
};

export type ChangesDoc = { projects: Record<string, Change[]>; next: number };

/** How many changes each project keeps, and how many a conversation's state shows. */
export const KEEP = 500;
export const SHOWN = 100;

const emptyChanges = (): ChangesDoc => ({ projects: {}, next: 1 });

/** The record. Made by the first change recorded: with the preview never on, nothing is written. A plain JSON object's token, as `pi2.needs`'s. */
export const Changes = defineDoc<JsonObject>({
	kind: "pi2.changes",
	version: 1,
	scope: "session",
	initial: () => emptyChanges() as unknown as JsonObject,
	checkpointWhen: () => true,
});

/** `pi2.changes` in the commit `tx`, to change. */
export const changesIn = async (tx: Tx): Promise<ChangesDoc> => (await tx.doc(Changes)) as unknown as ChangesDoc;

// ---- Words

/** An Undo whose target was changed again since (3.12). */
export const CHANGED_SINCE = "This was changed again since, so it was not undone. Change it by hand.";
/** A reach request allowed after what it changes has changed (7.2). */
export const ASKED_CHANGED = "This has changed since it was asked, so nothing was changed.";
/** Why a change with no inverse has no Undo, as the conversation's line says it. */
export function noUndoWhy(op: Op): string {
	if (op.kind === "work.github") return "on GitHub; it cannot be undone here";
	if (op.kind === "orchestrator.set") return "it started a fresh conversation; going back is another change of orchestrator";
	return "it cannot be undone";
}

// ---- Operations: how each is checked, applied and undone

/** What each kind of operation does, by the same function as the person's own request for it. */
export type OpRules<O extends Op = Op> = {
	/** Why it cannot be applied now (its target is not what it expects), or undefined. The project is checked already. */
	check(tx: Tx, projectId: string, op: O): Promise<string | undefined>;
	apply(tx: Tx, projectId: string, op: O): Promise<void>;
	/** What undoes it, or null. */
	inverse(op: O): Op | null;
	/** Whether an agent's applying it widens reach (7.1): an agent's Undo of a change can then only be asked for. */
	widens(op: O): boolean;
};

const ops = new Map<Op["kind"], OpRules<never>>();

/** Register what an operation does: #467 and #468 for work's, #463 for `wake.choice`. One a kind. */
export function defineOp<K extends Op["kind"]>(kind: K, rules: OpRules<Extract<Op, { kind: K }>>): void {
	ops.set(kind, rules as unknown as OpRules<never>);
}

const rulesOf = (op: Op): OpRules<Op> | undefined => ops.get(op.kind) as OpRules<Op> | undefined;

/** The inverse of `op`, or null when it has none. */
export function inverseOf(op: Op): Op | null {
	return rulesOf(op)?.inverse(op) ?? null;
}

/** Whether an agent applying `op` widens reach. An operation pi² does not know counts as widening. */
export function opWidens(op: Op): boolean {
	return rulesOf(op)?.widens(op) ?? true;
}

/**
 * Why `op` cannot be applied to project `projectId` now, in a sentence for the person: the project is gone or archived,
 * or the target is not what the operation expects. Undefined when it can.
 */
export async function checkOp(tx: Tx, projectId: string, op: Op): Promise<string | undefined> {
	const project = (await tx.doc(Projects)).projects[projectId];
	if (project === undefined || project.deletedAt !== undefined) return `Unknown project: ${projectId}`;
	if (project.archivedAt !== undefined) return PROJECT_ARCHIVED;
	const rules = rulesOf(op);
	if (rules === undefined) return "pi² cannot make this change yet.";
	return rules.check(tx, projectId, op);
}

/** Apply `op` to project `projectId` in the commit `tx`, through the validator of the person's own request. */
export async function applyOp(tx: Tx, projectId: string, op: Op): Promise<void> {
	const rules = rulesOf(op);
	if (rules === undefined) throw new Error("pi² cannot make this change yet.");
	await rules.apply(tx, projectId, op);
}

/** The engine, for `saveAgent`; the host, for the features and the conversations. Set as the engine makes the feature. */
let running: Engine | undefined;
let hosted: Host | undefined;

const PROFILE_FIELDS = new Set(["name", "description", "color", "instructions", "model", "thinkingLevel", "maxTurns", "compactionTokens", "codeMode", "access", "toolsOff", "toolsOn", "computer", "browser", "mcpServers", "files", "schedule", "worktree", "setup", "delegates"]);

/** An agent's memory switch, as stored in the commit `tx` (knowledge.ts keeps it outside the profile). */
export async function memoryOf(tx: Tx, agentId: string): Promise<boolean> {
	return (await tx.doc(Memory)).agents[agentId]?.enabled === true;
}

/**
 * Change agent `id`'s settings to each field's `after`, in the commit `tx`: the profile through `engine.saveAgent`, with
 * agents.save's checks; the allowed commands, Allow everything and the memory switch, which agents.save never takes, in
 * their documents. `marks` as `saveAgent` takes them.
 */
export async function applyAgentFields(tx: Tx, id: string, fields: Field[], marks?: Pick<AgentProfile, "template">): Promise<void> {
	if (running === undefined) throw new Error("The record of changes is not running");
	const stored = (await tx.doc(Agents)).agents[id];
	if (stored?.projectId === undefined || stored.removedAt !== undefined) throw new Error(`Unknown agent: ${id}`);
	const profile: Record<string, unknown> = {};
	for (const field of fields) {
		if (PROFILE_FIELDS.has(field.name)) profile[field.name] = copy(field.after);
		else if (field.name !== "commandRules" && field.name !== "allowEverything" && field.name !== "memory") throw new Error(`pi² cannot change ${field.name} for an agent`);
	}
	if (Object.keys(profile).length > 0 || marks !== undefined) {
		await running.saveAgent({ ...(profile as Partial<AgentProfile>), id, name: (profile.name as string | undefined) ?? stored.name }, { tx, ...(marks === undefined ? {} : { marks }) });
	}
	const agent = (await tx.doc(Agents)).agents[id]!;
	for (const field of fields) {
		if (field.name === "commandRules") agent.commandRules = copy(field.after) as CommandRule[];
		else if (field.name === "allowEverything") {
			if (field.after === true) agent.allowEverything = true;
			else delete agent.allowEverything;
		} else if (field.name === "memory") {
			const memory = await tx.doc(Memory);
			memory.agents[id] ??= { enabled: false, notes: [], next: 1 };
			memory.agents[id]!.enabled = field.after === true;
		}
	}
}

/** Whether each field of agent `id` still holds its `before`: why not, or undefined. */
async function agentHolds(tx: Tx, projectId: string, id: string, fields: Field[]): Promise<string | undefined> {
	const agent = (await tx.doc(Agents)).agents[id];
	if (agent === undefined || agent.projectId !== projectId || agent.removedAt !== undefined) return CHANGED_SINCE;
	const values = agentValues(agent, await memoryOf(tx, id)) as Record<string, unknown>;
	return fields.every((field) => same(values[field.name], field.before)) ? undefined : CHANGED_SINCE;
}

const swap = (fields: Field[]): Field[] => fields.map((field) => ({ name: field.name, before: copy(field.after), after: copy(field.before) }));

defineOp("agent.make", {
	// An agent is made only through `project_agents` `make`, at the baseline; nothing applies this again.
	check: async () => "An agent is made only by making it.",
	apply: async () => {
		throw new Error("An agent is made only by making it.");
	},
	inverse: (op) => ({ kind: "agent.remove", id: op.agent.id }),
	widens: () => true,
});
defineOp("agent.change", {
	check: (tx, projectId, op) => agentHolds(tx, projectId, op.id, op.fields),
	apply: (tx, _projectId, op) => applyAgentFields(tx, op.id, op.fields),
	inverse: (op) => ({ kind: "agent.change", id: op.id, fields: swap(op.fields) }),
	widens: (op) => op.fields.some((field) => agentFieldWidens(field.name, field.before, field.after)),
});
defineOp("agent.remove", {
	check: async (tx, projectId, op) => {
		const agent = (await tx.doc(Agents)).agents[op.id];
		return agent?.projectId === projectId && agent.removedAt === undefined ? undefined : CHANGED_SINCE;
	},
	apply: (tx, _projectId, op) => removeAgentIn(tx, op.id),
	inverse: (op) => ({ kind: "agent.restore", id: op.id }),
	widens: () => false,
});
defineOp("agent.restore", {
	check: async (tx, projectId, op) => {
		const agent = (await tx.doc(Agents)).agents[op.id];
		return agent?.projectId === projectId && agent.removedAt !== undefined ? undefined : CHANGED_SINCE;
	},
	apply: async (tx, _projectId, op) => {
		// As `agents.restore` does: it comes back with everything it had.
		const agent = (await tx.doc(Agents)).agents[op.id];
		if (agent !== undefined) delete agent.removedAt;
	},
	inverse: (op) => ({ kind: "agent.remove", id: op.id }),
	// Restoring puts back only what the agent had (7.1).
	widens: () => false,
});

/** The project's settings as `applyProjectChange` takes them, from fields named as `projectValues` names them. */
function projectChangeOf(fields: Field[]): { name?: string; folder?: string | null; settings?: Record<string, Record<string, unknown>> } {
	const given: { name?: string; folder?: string | null; settings?: Record<string, Record<string, unknown>> } = {};
	for (const field of fields) {
		if (field.name === "name") given.name = field.after as string;
		else if (field.name === "folder") given.folder = field.after as string | null;
		else if (field.name.startsWith("withoutAsking.") || field.name.startsWith("limits.")) {
			const [part, key] = field.name.split(".") as [string, string];
			given.settings ??= {};
			given.settings[part] ??= {};
			given.settings[part]![key] = field.after;
		} else throw new Error(`pi² cannot change the project's ${field.name} yet`);
	}
	return given;
}

defineOp("project.change", {
	check: async (tx, projectId, op) => {
		const project = (await tx.doc(Projects)).projects[projectId]!;
		const values = projectValues(project);
		return op.fields.every((field) => same(values[field.name], field.before)) ? undefined : CHANGED_SINCE;
	},
	apply: async (tx, projectId, op) => void (await applyProjectChange(tx, projectId, projectChangeOf(op.fields))),
	inverse: (op) => ({ kind: "project.change", fields: swap(op.fields) }),
	widens: (op) => op.fields.some((field) => projectFieldWidens(field.name, field.before, field.after)),
});

/** Rule `id` as stored in the commit `tx`, and its place. */
async function ruleNow(tx: Tx, projectId: string, id: string): Promise<{ rule: ProjectRule; at: number } | undefined> {
	const rules = await rulesIn(tx, projectId);
	const at = rules.findIndex((rule) => rule.id === id);
	return at === -1 ? undefined : { rule: rules[at]!, at };
}

defineOp("rule.add", {
	check: async (tx, projectId, op) => ((await ruleNow(tx, projectId, op.rule.id)) === undefined ? undefined : CHANGED_SINCE),
	apply: (tx, projectId, op) => putBackRule(tx, projectId, op.rule, op.at),
	inverse: (op) => ({ kind: "rule.remove", rule: copy(op.rule), at: op.at ?? 0 }),
	// Adding a rule never widens.
	widens: () => false,
});
defineOp("rule.remove", {
	check: async (tx, projectId, op) => {
		const now = await ruleNow(tx, projectId, op.rule.id);
		return now !== undefined && now.rule.text === op.rule.text && now.rule.binds === op.rule.binds ? undefined : CHANGED_SINCE;
	},
	apply: async (tx, projectId, op) => void (await removeRule(tx, projectId, op.rule.id)),
	inverse: (op) => ({ kind: "rule.add", rule: copy(op.rule), at: op.at }),
	widens: () => true,
});
defineOp("rule.edit", {
	check: async (tx, projectId, op) => {
		const now = await ruleNow(tx, projectId, op.id);
		return now !== undefined && now.rule.text === op.before.text && now.rule.binds === op.before.binds ? undefined : CHANGED_SINCE;
	},
	apply: async (tx, projectId, op) => void (await editRule(tx, projectId, op.id, { text: op.after.text, binds: op.after.binds })),
	inverse: (op) => ({ kind: "rule.edit", id: op.id, before: { ...op.after }, after: { ...op.before } }),
	// The engine cannot tell whether new words ask less; binding fewer does (5.4).
	widens: (op) => op.before.text !== op.after.text || (op.before.binds === "everyone" && op.after.binds === "orchestrator"),
});
defineOp("rule.move", {
	check: async (tx, projectId, op) => ((await ruleNow(tx, projectId, op.id))?.at === op.from ? undefined : CHANGED_SINCE),
	apply: async (tx, projectId, op) => void (await moveRule(tx, projectId, op.id, op.to)),
	inverse: (op) => ({ kind: "rule.move", id: op.id, from: op.to, to: op.from }),
	widens: () => false,
});

/** Note `id` of project `projectId`, as stored in the commit `tx`. */
const noteNow = async (tx: Tx, projectId: string, id: string) => (await tx.doc(Memory)).projects?.[projectId]?.notes.find((note) => note.id === id);

defineOp("note.add", {
	check: async (tx, projectId, op) => ((await noteNow(tx, projectId, op.note.id)) === undefined ? undefined : CHANGED_SINCE),
	apply: async (tx, projectId, op) => putBackProjectNote(await tx.doc(Memory), projectId, op.note),
	inverse: (op) => ({ kind: "note.remove", note: copy(op.note) }),
	widens: () => false,
});
defineOp("note.remove", {
	check: async (tx, projectId, op) => {
		const note = await noteNow(tx, projectId, op.note.id);
		return note !== undefined && note.text === op.note.text && note.audience === op.note.audience ? undefined : CHANGED_SINCE;
	},
	apply: async (tx, projectId, op) => void removeProjectNote((await tx.doc(Memory)).projects?.[projectId], op.note.id),
	inverse: (op) => ({ kind: "note.add", note: copy(op.note) }),
	widens: () => false,
});

// Work kept by pi² (#467): put back as it was. For `assign`, the sub-chat started is not stopped (5.9).
defineOp("work.local", {
	check: async (tx, projectId, op) => {
		const item = (await tx.doc(Work)).projects[projectId]?.items[String(op.id)];
		if (Object.keys(op.before).length === 0) return item === undefined ? undefined : CHANGED_SINCE;
		return item !== undefined && same(item, op.before) ? undefined : CHANGED_SINCE;
	},
	apply: async (tx, projectId, op) => {
		const doc = await tx.doc(Work);
		doc.projects[projectId] ??= { items: {}, next: 1 };
		const list = doc.projects[projectId]!;
		if (Object.keys(op.after).length === 0) delete list.items[String(op.id)];
		else list.items[String(op.id)] = copy(op.after) as WorkItem;
	},
	inverse: (op) => ({ kind: "work.local", id: op.id, action: op.action, before: copy(op.after), after: copy(op.before) }),
	// Work never widens reach, whatever the agent (7.1).
	widens: () => false,
});

const WORK_DONE: Record<WorkAction, string> = {
	file: "Filed",
	take: "Took",
	assign: "Assigned",
	release: "Released",
	wait: "Marked as waiting",
	block: "Marked as blocked",
	resume: "Resumed",
	finish: "Finished",
	close: "Closed",
	reopen: "Reopened",
	note: "Added a note to",
	edit: "Edited",
	classify: "Classified",
};

/**
 * Record an agent's write to the work list kept by pi² (work.ts, `recordWork`), in its commit: its change's id. The
 * person's own writes are not recorded: the record is of what agents did (3.12).
 */
export async function recordWorkChange(tx: Tx, operation: WorkOperation): Promise<number | undefined> {
	if (operation.by.kind !== "agent") return undefined;
	const after = copy(operation.after);
	const op: Op = { kind: "work.local", id: after.id, action: operation.action, before: operation.before === null ? {} : copy(operation.before), after };
	const title = after.title.replace(/\s+/g, " ");
	const summary = `${WORK_DONE[operation.action]} work #${after.id} “${title.length > 60 ? `${title.slice(0, 59).trimEnd()}…` : title}”`;
	const by: ChangeBy = { kind: "agent", agentId: operation.by.agentId, conversationId: operation.by.conversationId, callId: operation.callId ?? "" };
	return (await record(tx, operation.projectId, { by, op, inverse: inverseOf(op), summary })).id;
}

// Waking chosen for runs going now (#463): put the choice back. A run that has ended since has nothing to put back.
const wakeAfter = (op: Extract<Op, { kind: "wake.choice" }>) => op.submissions.map((_, index) => (typeof op.after === "string" ? op.after : (op.after[index] ?? null)));
defineOp("wake.choice", {
	check: async (tx, _projectId, op) => {
		const now = await wakeChoicesIn(tx, op.submissions);
		const after = wakeAfter(op);
		const holds = now.every((one, index) => one !== undefined && one.wake === op.before[index] && (op.batches === undefined || one.batch === op.batches.before[index]));
		return holds && after.length === op.submissions.length ? undefined : CHANGED_SINCE;
	},
	apply: async (tx, _projectId, op) => {
		const after = wakeAfter(op);
		const batches = op.batches?.after;
		const now = await wakeChoicesIn(tx, op.submissions);
		await setWakeChoicesIn(tx, op.submissions.map((submissionId, index) => ({ submissionId, wake: after[index] as ReportWake | null, batch: batches === undefined ? (now[index]?.batch ?? null) : (batches[index] ?? null) })));
	},
	inverse: (op) => ({
		kind: "wake.choice",
		submissions: [...op.submissions],
		before: wakeAfter(op),
		after: [...op.before],
		...(op.batches === undefined ? {} : { batches: { before: [...op.batches.after], after: [...op.batches.before] } }),
	}),
	// The waking of the orchestrator's own hand-offs never widens: the limits bound it (7.1).
	widens: () => false,
});

/**
 * The person's `projects.setOrchestrator` (orchestrator.ts, #466): the roles and the fresh conversation in one commit of
 * its own (6.5), so not inside another's. Undefined while no feature answers it.
 */
const setOrchestrator = (): ((params: Record<string, unknown>) => Promise<unknown>) | undefined =>
	hosted?.features.find((feature) => feature.handlers?.["projects.setOrchestrator"] !== undefined)?.handlers?.["projects.setOrchestrator"];

/** Whether pi² can make another agent the orchestrator. */
export const canSetOrchestrator = () => setOrchestrator() !== undefined;

defineOp("orchestrator.set", {
	check: async (tx, projectId, op) => {
		if (!canSetOrchestrator()) return "pi² cannot make another agent the orchestrator yet.";
		const project = (await tx.doc(Projects)).projects[projectId]!;
		const agent = (await tx.doc(Agents)).agents[op.to];
		return project.orchestratorId === op.from && agent?.projectId === projectId && agent.removedAt === undefined ? undefined : ASKED_CHANGED;
	},
	// Made by `projects.setOrchestrator` in a commit of its own, once the answer is stored (`answerReach`).
	apply: async () => {
		throw new Error("Making another agent the orchestrator starts a fresh conversation, in a commit of its own.");
	},
	inverse: () => null,
	widens: () => true,
});

/**
 * Once a commit that applied operations is stored: what keeps a copy of a document read only after its own commits reads
 * it again. Waking (wakes.ts) is the one; the others follow every commit by themselves.
 */
export async function afterChanges(): Promise<void> {
	await reloadWakes();
}

// ---- Recording, and Undo

/**
 * Record a change of project `projectId` in the commit `tx` that makes it, and answer it with its id. A change the
 * orchestrator did not make itself, in its own conversation, is news for it (6.4), but for one the person allowed: the
 * conversation that asked is told that itself.
 */
export async function record(tx: Tx, projectId: string, given: { by: ChangeBy; op: Op; inverse: Op | null; summary: string }): Promise<Change> {
	const doc = await changesIn(tx);
	const change: Change = { id: doc.next, at: Date.now(), by: copy(given.by), op: copy(given.op), summary: given.summary, inverse: given.inverse === null ? null : copy(given.inverse) };
	doc.next += 1;
	doc.projects[projectId] ??= [];
	// Read back through the draft, so that a list just made is tracked too.
	const list = doc.projects[projectId]!;
	list.push(change);
	if (list.length > KEEP) list.splice(0, list.length - KEEP);
	const project = (await tx.doc(Projects)).projects[projectId];
	const own = given.by.kind === "agent" && project?.conversation === given.by.conversationId;
	if (project !== undefined && !own && given.by.kind !== "allowed") await addNews(tx, projectId, { kind: "change", text: given.by.kind === "person" ? `${given.summary} (by the person)` : given.summary, ref: `change:${change.id}` });
	return copy(change);
}

/** Change `id` as stored in the commit `tx`, with its project: to change. */
export async function changeIn(tx: Tx, id: number): Promise<{ projectId: string; change: Change } | undefined> {
	const doc = await changesIn(tx);
	for (const [projectId, list] of Object.entries(doc.projects)) {
		const change = list.find((one) => one.id === id);
		if (change !== undefined) return { projectId, change };
	}
	return undefined;
}

/** Why change `id` cannot be undone at all, whatever is checked next; undefined when it can be tried. */
export function undoRefusal(found: { change: Change } | undefined, id: number): string | undefined {
	if (found === undefined) return `Unknown change: ${id}`;
	if (found.change.undone !== undefined) return "This was already undone.";
	if (found.change.inverse === null) return `This cannot be undone: ${noUndoWhy(found.change.op)}.`;
	return undefined;
}

/**
 * Undo change `id` in the commit `tx`: check that it can be, that its target is still what it left it, apply its
 * inverse, record that as a change of its own, and mark it undone. Answers the change the Undo made. Throws, changing
 * nothing, when any check fails.
 */
export async function undoIn(tx: Tx, id: number, by: ChangeBy, who: Who): Promise<Change> {
	const found = await changeIn(tx, id);
	const refused = undoRefusal(found, id);
	if (refused !== undefined) throw new Error(refused);
	const { projectId, change } = found!;
	const inverse = change.inverse!;
	const why = await checkOp(tx, projectId, inverse);
	if (why !== undefined) throw new Error(why);
	await applyOp(tx, projectId, inverse);
	const undo = await record(tx, projectId, { by, op: inverse, inverse: inverseOf(inverse), summary: `Undid: ${change.summary}` });
	const stored = (await changeIn(tx, id))!.change;
	stored.undone = { at: Date.now(), by: who, change: undo.id };
	return undo;
}

// ---- Reach requests (7.2)

/** A reach request's change, with its operation typed. */
export type Reach = Omit<ReachChange, "op"> & { op: Op };

/** What a reach request for `op` changes, as `ReachChange` says it: its target and fields. */
export function reachOf(op: Op, summary: string, undoes?: number): Reach {
	const base = { summary, op: copy(op), ...(undoes === undefined ? {} : { undoes }) };
	switch (op.kind) {
		case "agent.change":
			return { ...base, target: { kind: "agent", id: op.id }, fields: copy(op.fields) };
		case "agent.remove":
		case "agent.restore":
			return { ...base, target: { kind: "agent", id: op.id }, fields: [{ name: "removed", before: op.kind === "agent.remove" ? false : true, after: op.kind === "agent.remove" }] };
		case "project.change":
			return { ...base, target: { kind: "project" }, fields: copy(op.fields) };
		case "rule.remove":
			return { ...base, target: { kind: "rule", id: op.rule.id }, fields: [{ name: "rule", before: { text: op.rule.text, binds: op.rule.binds }, after: null }] };
		case "rule.edit":
			return { ...base, target: { kind: "rule", id: op.id }, fields: [{ name: "rule", before: { ...op.before }, after: { ...op.after } }] };
		case "orchestrator.set":
			return { ...base, target: { kind: "project" }, fields: [{ name: "orchestrator", before: op.from, after: op.to }] };
		default:
			return { ...base, target: { kind: "project" }, fields: [] };
	}
}

/**
 * Put a reach request under Needs you in the commit `tx`, for conversation `conversationId` of project `projectId`, or
 * answer the one waiting already for the same change (7.2), with `already`. The same call run again gets the one it put.
 */
export async function askReach(tx: Tx, given: { projectId: string; conversationId: number; callId: string; change: Reach; why: string | null }): Promise<{ need: StoredNeed; already: boolean }> {
	const doc = await needsIn(tx);
	const waiting = Object.values(doc.items).find(
		(need) => need.kind === "reach" && need.projectId === given.projectId && need.callId !== given.callId && same(need.change.target, given.change.target) && same(need.change.op, given.change.op),
	);
	if (waiting !== undefined) return { need: waiting, already: true };
	const need = await putNeed(tx, { kind: "reach", projectId: given.projectId, conversationId: given.conversationId, callId: given.callId, change: given.change, why: given.why });
	return { need, already: false };
}

/** What the agent is told of a change asked for (7.2, step 3). */
export function askedText(summary: string, need: StoredNeed, already: boolean): string {
	if (already) return `${summary}: this is already waiting for the person as ${need.id}. You will be told their answer. Do not ask again meanwhile.`;
	return `${summary}: this widens what agents may do, so it was put to the person as ${need.id}, who will allow or refuse it. You will be told their answer. Do not ask again meanwhile.`;
}

/** The request's summary in a line that names it, for the wake's marker: the request “Change Forge: access…”. */
const named = (what: string, summary: string) => {
	const line = summary.replace(/\s+/g, " ").trim();
	return `${what} “${line.length > 80 ? `${line.slice(0, 79).trimEnd()}…` : line}”`;
};

/**
 * Tell the conversation that asked, in the commit that takes the answer; it is woken once that is stored. Asked in an
 * earlier conversation with the orchestrator, the answer goes to its current one (orchestrator.ts, 6.5), as a question's.
 */
async function tell(tx: Tx, need: StoredNeed, label: string, ended: string, text: string): Promise<AnswerOutcome> {
	const { to, earlier } = await answerGoesTo(tx, need.conversationId);
	const said = earlier ? `${text}\n\n(You asked this in your earlier conversation, ${need.conversationId}.)` : text;
	await arriveIn(tx, to, { key: `answer:${need.id}`, kind: "answer", ref: need.id, label, ended, text: said });
	return { after: () => arrivedIn(to) };
}

/** The agent conversation `conversationId` runs as, by id, as stored in the commit `tx`. */
async function agentIdOf(tx: Tx, conversationId: number): Promise<string> {
	const meta = (await tx.doc(Library)).conversations[String(conversationId)];
	return runsAs(meta, (await tx.doc(Agents)).agents) ?? "";
}

/**
 * Allowing a reach request (7.2): checked again first, in the commit that takes the answer: the project neither archived
 * nor deleted, the asking conversation still in it, the target still there and each field still at its `before`. If
 * any fails, nothing is changed, the item is gone, and the person is told so. Otherwise the change is made through the
 * same validator as the person's own request, recorded, and the conversation that asked is told.
 */
async function answerReach(tx: Tx, need: Extract<StoredNeed, { kind: "reach" }>, allow: boolean): Promise<AnswerOutcome> {
	const change = need.change as Reach;
	const label = named("the request", change.summary);
	if (!allow) return tell(tx, need, label, "was refused", `The person refused: ${change.summary}. Do not ask for it again unless they bring it up.`);
	const meta = (await tx.doc(Library)).conversations[String(need.conversationId)];
	const inProjectStill = meta !== undefined && meta.deleted !== true && meta.projectId === need.projectId;
	const why = inProjectStill ? await checkOp(tx, need.projectId, change.op) : ASKED_CHANGED;
	if (why !== undefined) {
		const told = await tell(tx, need, label, "could not be made", `The person allowed “${change.summary}”, but it had changed since you asked, so nothing was changed.`);
		return {
			after: async () => {
				await told.after?.();
				throw new Error(ASKED_CHANGED);
			},
		};
	}
	const agentId = await agentIdOf(tx, need.conversationId);
	if (change.op.kind === "orchestrator.set") return allowOrchestrator(tx, need, change.op, agentId);
	await applyOp(tx, need.projectId, change.op);
	const made = await record(tx, need.projectId, { by: { kind: "allowed", need: need.id, agentId, conversationId: need.conversationId }, op: change.op, inverse: inverseOf(change.op), summary: change.summary });
	if (change.undoes !== undefined) {
		const undone = await changeIn(tx, change.undoes);
		if (undone !== undefined && undone.change.undone === undefined) undone.change.undone = { at: Date.now(), by: { kind: "person" }, change: made.id };
	}
	const told = await tell(tx, need, label, "was allowed", `The person allowed: ${change.summary}. (change ${made.id})`);
	return {
		after: async () => {
			await afterChanges();
			await told.after?.();
		},
	};
}

/** Why the orchestrator's conversation cannot be put away for a fresh one now (6.5), or undefined: as Start fresh checks. */
export const ORCHESTRATOR_BUSY = "The orchestrator is answering or waiting for you. Let it finish, or stop it, first.";

/**
 * Allowing another agent to be made the orchestrator (5.3, 6.5). Start fresh makes the roles and the fresh conversation
 * in a commit of its own, so this commit, which takes the answer, only checks: the request stays while the orchestrator
 * is busy. Once it is stored, `projects.setOrchestrator` makes the change, and then it is recorded, with no Undo, and the
 * fresh conversation is told. Should that fail, as when the orchestrator started answering meanwhile, nothing is changed
 * and the person is told why; the request is gone, and they can make the change themselves.
 */
async function allowOrchestrator(tx: Tx, need: Extract<StoredNeed, { kind: "reach" }>, op: Extract<Op, { kind: "orchestrator.set" }>, agentId: string): Promise<AnswerOutcome> {
	const summary = (need.change as Reach).summary;
	const current = (await tx.doc(Projects)).projects[need.projectId]?.conversation ?? null;
	if (current !== null && (hosted?.working(current) === true || hosted?.inbox.list().some((item) => item.conversationId === current))) throw new Error(ORCHESTRATOR_BUSY);
	return {
		after: async () => {
			const engine = running!;
			const made = (await setOrchestrator()!({ id: need.projectId, agentId: op.to })) as { conversation: number };
			const fresh = made.conversation;
			await engine.harness().commit(async (later) => {
				const change = await record(later, need.projectId, { by: { kind: "allowed", need: need.id, agentId, conversationId: need.conversationId }, op, inverse: null, summary });
				await arriveIn(later, fresh, { key: `answer:${need.id}`, kind: "answer", ref: need.id, label: named("the request", summary), ended: "was allowed", text: `The person allowed: ${summary}. This is the fresh conversation. (change ${change.id})` });
			}, engine.context());
			await arrivedIn(fresh);
		},
	};
}

/** Accepting a proposed rule (5.4): added through `addRule` as the person accepted it, and recorded, with Undo. */
async function answerRule(tx: Tx, need: Extract<StoredNeed, { kind: "rule" }>, answer: { accept: boolean; text?: string; binds?: "orchestrator" | "everyone" }): Promise<AnswerOutcome> {
	const label = named("the proposed rule", need.text);
	if (!answer.accept) return tell(tx, need, label, "was not accepted", `The person did not accept your proposed rule “${need.text}”. Do not propose it again unless they bring it up.`);
	const agentId = await agentIdOf(tx, need.conversationId);
	const rule = await addRule(tx, need.projectId, { text: answer.text ?? need.text, binds: answer.binds ?? need.binds, addedBy: { kind: "proposal", agentId, conversationId: need.conversationId, need: need.id } });
	const at = (await rulesIn(tx, need.projectId)).length - 1;
	const made = await record(tx, need.projectId, {
		by: { kind: "allowed", need: need.id, agentId, conversationId: need.conversationId },
		op: { kind: "rule.add", rule, at },
		inverse: { kind: "rule.remove", rule, at },
		summary: `Added rule ${rule.id}: “${rule.text}”`,
	});
	const edited = rule.text !== need.text || rule.binds !== need.binds;
	const as = edited ? ` with changes: “${rule.text}”, binding ${rule.binds === "everyone" ? "every agent" : "the orchestrator"}` : "";
	return tell(tx, need, label, "was accepted", `The person accepted your proposed rule as ${rule.id}${as}. (change ${made.id})`);
}

// ---- What the conversation is sent (projectChanges)

/** One line of the conversation's record (3.12), as its state carries it. */
export type ChangeLine = { id: number; summary: string; undone: boolean; canUndo: boolean; noUndo: string | null };

/** The record as last stored, and which projects are neither archived nor deleted, read with it. */
let current: ChangesDoc = emptyChanges();
let live = new Set<string>();

/** The changes made in conversation `id`, the last 100, oldest first. */
export function linesOf(id: number): ChangeLine[] {
	const lines: ChangeLine[] = [];
	for (const [projectId, list] of Object.entries(current.projects)) {
		const open = live.has(projectId);
		for (const change of list) {
			if (change.by.kind === "person" || change.by.conversationId !== id) continue;
			lines.push({ id: change.id, summary: change.summary, undone: change.undone !== undefined, canUndo: open && change.inverse !== null && change.undone === undefined, noUndo: change.inverse === null ? noUndoWhy(change.op) : null });
		}
	}
	return lines.sort((a, b) => a.id - b.id).slice(-SHOWN);
}

/** Every change of project `projectId` as stored, oldest first: a plain copy. */
export function changesOf(projectId: string): Change[] {
	return copy(current.projects[projectId] ?? []);
}

// ---- The feature

export const changes: Feature = (host, engine) => {
	running = engine;
	hosted = host;
	onAnswer("reach", (tx, need, answer) => answerReach(tx, need, answer.allow));
	onAnswer("rule", (tx, need, answer) => answerRule(tx, need, answer));
	/** What each conversation's state last carried, so only a conversation whose lines changed is sent again. */
	const sent = new Map<number, string>();
	let reads = 0;
	const reload = async () => {
		const read = ++reads;
		const stored = (await engine.harness().snapshot(Changes, engine.context())) as ChangesDoc | undefined;
		const projects = (await engine.harness().snapshot(Projects, engine.context()))?.projects ?? {};
		if (read !== reads) return;
		current = stored === undefined ? emptyChanges() : copy(stored);
		live = new Set(Object.values(projects).filter((project) => project.deletedAt === undefined && project.archivedAt === undefined).map((project) => project.id));
		const conversations = new Set<number>([...sent.keys()]);
		for (const list of Object.values(current.projects)) for (const change of list) if (change.by.kind !== "person") conversations.add(change.by.conversationId);
		for (const id of conversations) {
			const line = JSON.stringify(linesOf(id));
			if (sent.get(id) === line) continue;
			sent.set(id, line);
			engine.stateChanged(id);
		}
	};
	return {
		start: async () => {
			await reload();
			engine.harness().observeCommits({
				advance: ({ changes: commits }) => {
					// A change recorded, or a project archived or restored, which decides whether its changes can be undone.
					const touched = commits.some((one) => (one.type === "document" || one.type === "document.copy") && (one.record.kind === "pi2.changes" || one.record.kind === "pi2.projects"));
					if (touched) void reload().catch((error) => engine.log("could not read the record of changes again:", error instanceof Error ? error.message : error));
				},
				end: () => {},
			});
		},
		tools: projectTools(host, engine),
		// To the project's current conversation with its orchestrator, with the preview on, in a project neither archived nor
		// deleted (5.1). A conversation not made yet is known by its agent: the orchestrator, outside a sub-chat. Each tool
		// checks the conversation itself too.
		toolNames: (_access, agent, where) => {
			if (where.subChat || !projectsOn()) return [];
			if (where.conversationId !== undefined) return inProject(where.conversationId)?.conversation === where.conversationId ? [...TOOL_NAMES] : [];
			if (agent?.role !== "orchestrator" || agent.projectId === undefined) return [];
			const project = allProjects()[agent.projectId];
			return project !== undefined && project.deletedAt === undefined && project.archivedAt === undefined ? [...TOOL_NAMES] : [];
		},
		// The lines of the changes made in a conversation of a project (3.12); nothing for any other conversation.
		state: (view, meta) => (meta?.projectId === undefined ? {} : { projectChanges: linesOf(view.conversation.id as unknown as number) }),
		handlers: {
			/** `{ projectId, before?, limit? }`: the project's changes, newest first, 50 by default. */
			"changes.list": async (params) => {
				requirePreview();
				if (typeof params.projectId !== "string") throw new Error("projectId must be a project's id");
				const project = allProjects()[params.projectId];
				if (project === undefined || project.deletedAt !== undefined) throw new Error(`Unknown project: ${params.projectId}`);
				if (params.before !== undefined && !(Number.isInteger(params.before) && (params.before as number) > 0)) throw new Error("before must be a change's id");
				if (params.limit !== undefined && !(Number.isInteger(params.limit) && (params.limit as number) >= 1 && (params.limit as number) <= KEEP)) throw new Error(`limit must be a whole number from 1 to ${KEEP}`);
				const before = (params.before as number | undefined) ?? Number.POSITIVE_INFINITY;
				const limit = (params.limit as number | undefined) ?? 50;
				return { changes: changesOf(params.projectId).filter((change) => change.id < before).reverse().slice(0, limit) };
			},
			/** `{ id }`: the person's Undo of a change (3.12). Never checked against reach: the person's own. */
			"changes.undo": async (params) => {
				requirePreview();
				if (!Number.isInteger(params.id)) throw new Error("id must be a change's id");
				await engine.harness().commit((tx) => undoIn(tx, params.id as number, { kind: "person" }, { kind: "person" }), engine.context());
				await afterChanges();
				await reload();
				return {};
			},
		},
	};
};
