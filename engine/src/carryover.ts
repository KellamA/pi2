// Carrying over (#458): docs/projects.md, section 9. What a person has today is put into projects, with nothing lost,
// nothing deleted and nothing the old way reads changed: it only adds documents, adds fields the old way does not read
// (`projectId`, `projectAgentId`), and copies agents.
//
// It is worked out as one plan, `planCarryOver(snapshot)`, a function of the documents alone (and of the folders on disk,
// for grouping by repository), with every choice made by a rule and every tie broken by one. The report a dry run shows
// is that plan, with its fingerprint; a real run works the plan out again and goes ahead only if the fingerprint is the
// same. A run commits one project at a time, each commit finding what an earlier one did, so a run cut off part way is
// finished by the next, and a second run with nothing new has an empty plan and writes nothing at all.
//
// Copying the variables' values into the Keychain is a step after the commits, taken again at every engine start and
// with `projects.retrySecrets` until done (`carry.secrets`).
//
// What is not done here, and why:
//
// - The watches' `wake` (9.1) is #463's field. A project carrying over makes has `wakeOnReports` on, which #463 reads as
//   waking for each report, so a sub-chat handed over without waiting wakes the orchestrator as it did.
// - The backup is made before the first run that changes anything, not before each conversation made later (9.9), which
//   only adds one conversation's fields to what the backup already holds.

import { createHash, randomUUID } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, realpathSync, statSync, writeFileSync } from "node:fs";
import { basename, dirname, join, resolve, sep } from "node:path";
import { AgentDoc, type ConversationId, type Tx } from "@earendil-works/pi-durable";
import { createBackup } from "./backup.ts";
import type { Feature } from "./features.ts";
import { Memory, type MemoryDoc } from "./knowledge.ts";
import { projectNotebook } from "./projectnotes.ts";
import {
	type CarryOverReport,
	type CarryOverState,
	carryRecord,
	DEFAULT_ORCHESTRATOR,
	defaultProjectSettings,
	MAX_PROJECT_NAME,
	type Project,
	Projects,
	type ProjectsDoc,
	projectsOn,
	requirePreview,
	wireCarryOver,
} from "./projects.ts";
import { RequestError } from "./requesterror.ts";
import { type AgentProfile, Agents, Library, type Meta } from "./state.ts";
import { copyAgentValues } from "./variables.ts";
import { madeWorktrees } from "./worktrees.ts";

/** The refusal of a run whose plan is not the one the person was shown (4.2, 9.8). */
export const PLAN_CHANGED = "What would be carried over has changed since you looked. Look at it again.";

// ---- Grouping by folder (9.2)

/** A path's real path, or the path as given when it has gone. */
function real(path: string): string {
	try {
		return realpathSync(path);
	} catch {
		return path;
	}
}

/** Whether `folder` is `root` or inside it, by real paths where they exist. */
const within = (folder: string, root: string) => (real(folder) + sep).startsWith(real(root) + sep);

/** What a `.git` entry is, without following anything but the entry itself. */
function gitEntry(folder: string): "folder" | "file" | undefined {
	try {
		const stat = statSync(join(folder, ".git"));
		return stat.isDirectory() ? "folder" : stat.isFile() ? "file" : undefined;
	} catch {
		return undefined;
	}
}

/**
 * The grouping key of a conversation working in `cwd` (9.2), without running git: `none` for no folder; for a folder in
 * a worktree pi² made, the main checkout it was made from; otherwise, from the folder upwards, the nearest folder with a
 * `.git` entry: a folder `.git` is a main checkout, a linked worktree's file names its main checkout, and any other file
 * (a submodule's) makes its own folder the key. With none found, the folder itself. Each key is a real path, or the
 * path as stored for a folder that has gone.
 */
export function groupingKey(cwd: string | null, worktrees: readonly { path: string; repo: string }[]): string {
	if (cwd === null) return "none";
	for (const made of worktrees) if (within(cwd, made.path)) return real(made.repo);
	for (let folder = real(cwd); ; ) {
		const entry = gitEntry(folder);
		if (entry === "folder") return real(folder);
		if (entry === "file") {
			let gitdir: string | undefined;
			try {
				const line = /^gitdir:\s*(.+?)\s*$/m.exec(readFileSync(join(folder, ".git"), "utf8"));
				if (line !== null) gitdir = resolve(folder, line[1]!);
			} catch {
				// Unreadable: the folder with the file is the key.
			}
			const linked = gitdir === undefined ? null : /^(.*)\/\.git\/worktrees\/[^/]+\/?$/.exec(gitdir);
			return real(linked === null ? folder : linked[1]!);
		}
		const up = dirname(folder);
		if (up === folder) break;
		folder = up;
	}
	return real(cwd);
}

// ---- One plan (9.3 to 9.7)

/** The documents a plan is worked out from. */
export type CarrySnapshot = {
	conversations: Record<string, Meta>;
	/** The folder each top-level conversation not yet in a project works in, as its `pi.agent` document holds it. */
	folders: Record<string, string | null>;
	agents: Record<string, AgentProfile>;
	memory: MemoryDoc;
	worktrees: { path: string; repo: string }[];
	projects: ProjectsDoc;
};

/** A template the plan copies into a project, or the copy it finds there. */
export type PlannedCopy = {
	template: string;
	/** The copy's name: the template's, with " 2", " 3"… when the project has an agent by that name. */
	name: string;
	/** The copy found: recorded by an earlier run, or adopted (`adopt`). Null: one is made. */
	existing: string | null;
	adopt: boolean;
	/** For a copy made: the template's Allow everything, the names of its variables with values, and its memory switch. */
	allowEverything: boolean;
	variables: string[];
	memory: boolean;
	/** The template's own folder, when it groups elsewhere than the project: a new sub-chat of the copy starts elsewhere. */
	folder: string | null;
};

/** One of an agent's notes, copied into a project for that agent's copy alone (9.7). */
export type PlannedNote = {
	agent: string;
	agentName: string;
	note: string;
	text: string;
	createdAt: number;
	/** Written by the person (null), or in a conversation by the agent. */
	byAgent: boolean;
	/** The copy it is given to, when the project has it already; else the copy made of `agent` in this commit. */
	copy: string | null;
	/** Whether this project's commit records the note as dealt with: the last of the projects it goes to. */
	record: boolean;
};

/** One project of a plan: one found or made for a grouping key, with what the run adds to it. */
export type PlannedProject = {
	key: string;
	name: string;
	/** The project found (9.4); null for a project made. */
	existing: string | null;
	/** Found by its folder, not by the record (9.4, 1): a project the record does not have for this key yet. */
	adopted: boolean;
	/** Whether the run records `carry.folders[key]`. */
	recordFolder: boolean;
	/** A project made: its folder, the key's path, or null for `none`. */
	folder: string | null;
	archived: boolean;
	/** A conversation made later goes into an archived project, and so restores it (9.9). */
	restore: boolean;
	/** For a project made: its orchestrator's conversation and its template, or both null for the default orchestrator. */
	orchestrator: { conversation: number | null; template: string | null; title: string | null } | null;
	copies: PlannedCopy[];
	/** The conversations it takes, each with the template whose copy it runs as (null: none, it runs as its agentId). */
	conversations: { id: number; template: string | null; archived: boolean; subChat: boolean }[];
	notes: PlannedNote[];
};

export type CarryPlan = {
	projects: PlannedProject[];
	/** Notes left where they are, recorded `"left"`: "<agentId> <noteId>". */
	left: string[];
	leftOut: { chats: number; deleted: number };
	already: number;
};

/** The most recently updated first, then the lowest id: the tie-break of 9.3. */
const byRecent = (a: { updatedAt: number; id: number | string }, b: { updatedAt: number; id: number | string }) =>
	b.updatedAt - a.updatedAt || (typeof a.id === "number" && typeof b.id === "number" ? a.id - b.id : String(a.id) < String(b.id) ? -1 : String(a.id) > String(b.id) ? 1 : 0);
/** Agents in the order they were made, then by id. */
const byMade = (a: AgentProfile, b: AgentProfile) => a.createdAt - b.createdAt || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0);

const isTemplate = (agent: AgentProfile | undefined): agent is AgentProfile => agent !== undefined && agent.projectId === undefined;

/** A name made unique among `taken` (lower case), with " 2", " 3"…, within the 80 characters of a project's name. */
function unique(base: string, taken: Set<string>, max = Number.POSITIVE_INFINITY): string {
	for (let n = 1; ; n++) {
		const suffix = n === 1 ? "" : ` ${n}`;
		const name = `${base.slice(0, max - suffix.length).trim()}${suffix}`;
		if (!taken.has(name.toLowerCase())) return name;
	}
}

/**
 * What carrying over would do, from the documents alone: every choice made by a rule of section 9, every tie broken by
 * 9.3's, so the same documents give the same plan. With `only`, the plan for that one conversation, made later (9.9).
 */
export function planCarryOver(snapshot: CarrySnapshot, only?: number): CarryPlan {
	const { conversations, agents, memory, worktrees } = snapshot;
	const doc = snapshot.projects;
	const live = Object.values(doc.projects).filter((project) => project.deletedAt === undefined);
	const projectKey = new Map(live.map((project) => [project.id, project.folder === null ? "none" : groupingKey(project.folder, worktrees)]));
	const ids = Object.keys(conversations)
		.map(Number)
		.sort((a, b) => a - b);
	const meta = (id: number) => conversations[String(id)];
	/** The root of a sub-chat, or undefined when a parent on the way is missing. */
	const rootOf = (id: number): number | undefined => {
		const seen = new Set<number>();
		let at = id;
		while (meta(at)?.parent !== undefined) {
			if (seen.has(at)) return undefined;
			seen.add(at);
			at = meta(at)!.parent!;
		}
		return meta(at) === undefined ? undefined : at;
	};
	const subChatsOf = new Map<number, number>();
	for (const id of ids) {
		const parent = meta(id)!.parent;
		if (parent !== undefined && meta(id)!.version !== true && meta(id)!.deleted !== true) subChatsOf.set(parent, (subChatsOf.get(parent) ?? 0) + 1);
	}

	const leftOut = { chats: 0, deleted: 0 };
	let already = 0;
	/** Top-level conversations to add, by key; sub-chats to add, by key or by the project their root is in. */
	const byKey = new Map<string, { tops: number[]; subs: number[] }>();
	const byProject = new Map<string, number[]>();
	const keyOf = new Map<number, string>();
	const bucket = (key: string) => byKey.get(key) ?? byKey.set(key, { tops: [], subs: [] }).get(key)!;
	for (const id of only === undefined ? ids : [only]) {
		const m = meta(id);
		if (m === undefined || m.version === true) continue;
		if (m.chat === true) {
			if (m.deleted !== true && only === undefined) leftOut.chats++;
			continue;
		}
		if (m.projectId !== undefined) {
			if (m.parent === undefined && m.deleted !== true && only === undefined) already++;
			continue;
		}
		const root = rootOf(id);
		const rootMeta = root === undefined ? undefined : meta(root);
		if (m.deleted === true || rootMeta === undefined || rootMeta.deleted === true || rootMeta.chat === true) {
			if (only === undefined && rootMeta?.chat !== true) leftOut.deleted++;
			continue;
		}
		if (only !== undefined && m.parent !== undefined) continue;
		if (m.parent === undefined) {
			const key = groupingKey(snapshot.folders[String(id)] ?? null, worktrees);
			keyOf.set(id, key);
			bucket(key).tops.push(id);
		} else if (rootMeta.projectId !== undefined) {
			// A sub-chat made since in a conversation already in a project: into that project, if it is still there.
			if (projectKey.has(rootMeta.projectId)) byProject.set(rootMeta.projectId, [...(byProject.get(rootMeta.projectId) ?? []), id]);
		} else {
			const key = keyOf.get(root!) ?? groupingKey(snapshot.folders[String(root)] ?? null, worktrees);
			keyOf.set(root!, key);
			bucket(key).subs.push(id);
		}
	}

	// 9.4: the project of each key: one not deleted whose folder has the key, else the one recorded for it, else a new one.
	const entries = new Map<string, PlannedProject>();
	const names = new Set(live.map((project) => project.name.toLowerCase()));
	const entryFor = (project: Project, adopted: boolean, recordFolder: boolean, key: string): PlannedProject => {
		const found = entries.get(project.id);
		if (found !== undefined) {
			found.adopted ||= adopted;
			found.recordFolder ||= recordFolder;
			return found;
		}
		const made: PlannedProject = {
			key,
			name: project.name,
			existing: project.id,
			adopted,
			recordFolder,
			folder: project.folder,
			archived: project.archivedAt !== undefined,
			restore: false,
			orchestrator: null,
			copies: [],
			conversations: [],
			notes: [],
		};
		entries.set(project.id, made);
		return made;
	};
	const add = (entry: PlannedProject, id: number, subChat: boolean) =>
		entry.conversations.push({ id, template: null, archived: meta(id)!.archivedAt !== undefined, subChat });
	for (const key of [...byKey.keys()].sort()) {
		const { tops, subs } = byKey.get(key)!;
		let entry: PlannedProject;
		const byFolder = live
			.filter((project) => projectKey.get(project.id) === key)
			.sort((a, b) => byRecent(a, b))[0];
		const recorded = doc.carry.folders[key] === undefined ? undefined : live.find((project) => project.id === doc.carry.folders[key]);
		// Adopted: found by its folder and recorded now. One a run made or adopted before is found the same way, and is not
		// adopted again.
		const adopted = byFolder !== undefined && doc.carry.folders[key] !== byFolder.id;
		if (byFolder !== undefined) entry = entryFor(byFolder, adopted, adopted, key);
		else if (recorded !== undefined) entry = entryFor(recorded, false, false, key);
		else {
			const name = unique(key === "none" ? "No folder" : basename(key).trim() || key, names, MAX_PROJECT_NAME);
			names.add(name.toLowerCase());
			entry = {
				key,
				name,
				existing: null,
				adopted: false,
				recordFolder: true,
				folder: key === "none" ? null : key,
				archived: tops.every((id) => meta(id)!.archivedAt !== undefined),
				restore: false,
				orchestrator: null,
				copies: [],
				conversations: [],
				notes: [],
			};
			entries.set(`key:${key}`, entry);
		}
		// A conversation made later in the folder of an archived project restores it, since the person set it going (3.6).
		if (only !== undefined && entry.existing !== null && entry.archived) entry.restore = true;
		for (const id of tops) add(entry, id, false);
		for (const id of subs) add(entry, id, true);
	}
	for (const [projectId, subs] of byProject) {
		const project = live.find((one) => one.id === projectId)!;
		const entry = entryFor(project, false, false, projectKey.get(projectId)!);
		for (const id of subs) add(entry, id, true);
	}

	// 9.5: the templates each project's conversations ran as, and those they may hand work to, followed through.
	for (const entry of entries.values()) {
		const wanted = new Set<string>();
		const queue = entry.conversations.map(({ id }) => meta(id)!.agentId).filter((id): id is string => id !== undefined && isTemplate(agents[id]));
		while (queue.length > 0) {
			const id = queue.shift()!;
			if (wanted.has(id)) continue;
			wanted.add(id);
			for (const other of agents[id]!.delegates ?? []) if (isTemplate(agents[other]) && agents[other].removedAt === undefined) queue.push(other);
		}
		const taken = new Set(
			Object.values(agents)
				.filter((agent) => entry.existing !== null && agent.projectId === entry.existing)
				.map((agent) => agent.name.toLowerCase()),
		);
		const none = new Set<string>();
		for (const template of [...wanted].map((id) => agents[id]!).sort(byMade)) {
			const pair = `${entry.existing} ${template.id}`;
			const recorded = entry.existing === null ? undefined : doc.carry.copies[pair];
			let existing: string | null = null;
			let adopt = false;
			if (recorded !== undefined) {
				// The copy recorded, removed or not; one the person deleted since stays deleted, and nothing is made (9.5, 3).
				if (agents[recorded] === undefined) {
					none.add(template.id);
					continue;
				}
				existing = recorded;
			} else if (entry.existing !== null) {
				const made = Object.values(agents)
					.filter((agent) => agent.projectId === entry.existing && agent.template?.id === template.id)
					.sort(byMade)[0];
				if (made !== undefined) {
					existing = made.id;
					adopt = true;
				}
			}
			const name = existing === null ? unique(template.name, taken) : agents[existing]!.name;
			if (existing === null) taken.add(name.toLowerCase());
			entry.copies.push({
				template: template.id,
				name,
				existing,
				adopt,
				allowEverything: existing === null && template.allowEverything === true,
				variables: existing === null ? (template.variables ?? []).filter((variable) => variable.set).map((variable) => variable.name) : [],
				memory: existing === null && memory.agents[template.id]?.enabled === true,
				folder: existing === null && template.cwd !== null && groupingKey(template.cwd, worktrees) !== entry.key ? template.cwd : null,
			});
		}
		const copied = new Set(entry.copies.map((copy) => copy.template));
		for (const conversation of entry.conversations) {
			const agentId = meta(conversation.id)!.agentId;
			conversation.template = agentId !== undefined && copied.has(agentId) && !none.has(agentId) ? agentId : null;
		}

		// 9.6: a project made gets as its orchestrator's conversation the most recent one that hands out work.
		if (entry.existing === null) {
			const chosen = entry.conversations
				.filter((one) => !one.subChat && !one.archived && one.template !== null && (subChatsOf.get(one.id) ?? 0) > 0)
				.map((one) => ({ id: one.id, updatedAt: meta(one.id)!.updatedAt, template: one.template! }))
				.sort(byRecent)[0];
			entry.orchestrator =
				chosen === undefined ? { conversation: null, template: null, title: null } : { conversation: chosen.id, template: chosen.template, title: meta(chosen.id)!.title };
		}
	}

	// 9.7: each note of an agent's not yet dealt with goes to the projects with a copy of that agent, for the copy alone.
	const copiesOf = (template: string): { entry: PlannedProject; copy: string | null }[] => {
		const found: { entry: PlannedProject; copy: string | null }[] = [];
		for (const entry of entries.values()) {
			const copy = entry.copies.find((one) => one.template === template);
			if (copy !== undefined) found.push({ entry, copy: copy.existing });
		}
		for (const [pair, copy] of Object.entries(doc.carry.copies)) {
			const [projectId, from] = pair.split(" ");
			if (from !== template || agents[copy] === undefined || !projectKey.has(projectId!) || entries.has(projectId!)) continue;
			found.push({ entry: entryFor(live.find((project) => project.id === projectId)!, false, false, projectKey.get(projectId!)!), copy });
		}
		return found;
	};
	const left: string[] = [];
	const planned: { note: Omit<PlannedNote, "copy" | "record">; to: { entry: PlannedProject; copy: string | null }[] }[] = [];
	const entryOf = new Map<number, PlannedProject>();
	for (const entry of entries.values()) for (const one of entry.conversations) entryOf.set(one.id, entry);
	/** Whether the conversation a note was written in is, after the plan, in the project `entry` stands for. */
	const writtenIn = (conversation: number | null, entry: PlannedProject): boolean => {
		const written = conversation === null ? undefined : meta(conversation);
		if (written === undefined || written.deleted === true) return false;
		return written.projectId !== undefined ? entry.existing === written.projectId : entryOf.get(conversation!) === entry;
	};
	const inPlan = new Set(only === undefined ? Object.keys(memory.agents) : [...entries.values()].flatMap((entry) => entry.copies.map((copy) => copy.template)));
	for (const agentId of Object.keys(memory.agents).sort()) {
		if (!inPlan.has(agentId)) continue;
		const agent = agents[agentId];
		// A project agent's own notes: there are none to carry; its notes are its project's.
		if (agent !== undefined && agent.projectId !== undefined) continue;
		const destinations = agent === undefined ? [] : copiesOf(agentId);
		const copiedAnywhere = agent !== undefined && Object.values(agents).some((other) => other.projectId !== undefined && other.template?.id === agentId);
		for (const note of memory.agents[agentId]!.notes) {
			const dealt = `${agentId} ${note.id}`;
			if (doc.carry.notes[dealt] !== undefined) continue;
			if (destinations.length === 0) {
				// An agent deleted, or one with no copy anywhere, keeps its notes where they are. One with only copies the person
				// made by hand is left unrecorded, for the run that adopts one of them.
				if (!copiedAnywhere && only === undefined) left.push(dealt);
				continue;
			}
			// Where a conversation of that agent's wrote it; else (the person wrote it, or its conversation is gone or in no
			// project with a copy) every project with a copy.
			const there = destinations.filter(({ entry }) => writtenIn(note.conversation, entry));
			planned.push({
				note: { agent: agentId, agentName: agent!.name, note: note.id, text: note.text, createdAt: note.createdAt, byAgent: note.conversation !== null },
				to: there.length > 0 ? there : destinations,
			});
		}
	}

	// A project found only for notes that all went elsewhere has nothing to do.
	const receiving = new Set(planned.flatMap(({ to }) => to.map(({ entry }) => entry)));
	const projects = [...entries.values()]
		.filter((entry) => entry.conversations.length > 0 || receiving.has(entry))
		.sort((a, b) => (a.key < b.key ? -1 : a.key > b.key ? 1 : (a.existing ?? "") < (b.existing ?? "") ? -1 : 1));
	for (const { note, to } of planned) {
		const last = to.map(({ entry }) => projects.indexOf(entry)).reduce((a, b) => Math.max(a, b));
		for (const { entry, copy } of to) entry.notes.push({ ...note, copy, record: projects.indexOf(entry) === last });
	}
	return { projects, left, leftOut, already };
}

/** The plan's fingerprint (9.3): a hash of everything it would do, or null when it would do nothing. */
export function fingerprint(plan: CarryPlan): string | null {
	if (plan.projects.length === 0 && plan.left.length === 0) return null;
	return createHash("sha256")
		.update(JSON.stringify({ projects: plan.projects, left: plan.left }))
		.digest("hex")
		.slice(0, 32);
}

/** The pending copies of variables' values, as the `projects` event and the report say them (4.3). */
function pending(doc: ProjectsDoc["carry"], agents: Record<string, AgentProfile>): CarryOverState["secretsPending"] {
	return doc.secrets.map((item) => ({ copy: item.copyId, name: agents[item.copyId]?.name ?? item.copyId, project: agents[item.copyId]?.projectId ?? "", variables: [...item.names], error: item.lastError }));
}

/** The report of a plan (9.8), with the record as it stands. */
export function reportOf(plan: CarryPlan, carry: ProjectsDoc["carry"], agents: Record<string, AgentProfile>): CarryOverReport {
	return {
		plan: fingerprint(plan),
		projects: plan.projects.map((entry) => ({
			key: entry.key,
			name: entry.name,
			existing: entry.existing,
			adopted: entry.adopted,
			archived: entry.archived && !entry.restore,
			orchestrator: entry.orchestrator,
			copies: entry.copies.map((copy) => ({
				template: copy.template,
				name: copy.name,
				existing: copy.existing,
				allowEverything: copy.allowEverything,
				variables: copy.variables,
				folder: copy.folder,
			})),
			conversations: entry.conversations.filter((one) => !one.subChat && !one.archived).length,
			archivedConversations: entry.conversations.filter((one) => !one.subChat && one.archived).length,
			subChats: entry.conversations.filter((one) => one.subChat).length,
			notes: entry.notes.length,
		})),
		leftOut: { ...plan.leftOut, notesLeft: plan.left.length },
		already: plan.already,
		ranAt: carry.ranAt,
		backup: carry.backup,
		secretsPending: pending(carry, agents),
	};
}

// ---- The run (9.8)

/**
 * Tests hold the Keychain step here, to stop an engine between a run's commits and the copying of values, as a crash
 * would: while the file `PI2_CARRY_SECRETS_GATE` names exists, the step waits, having written `<file>.started`.
 */
async function gate(): Promise<void> {
	const file = process.env.PI2_CARRY_SECRETS_GATE;
	if (file === undefined || !existsSync(file)) return;
	writeFileSync(`${file}.started`, "");
	while (existsSync(file)) await new Promise((resolve) => setTimeout(resolve, 50));
}

/** An agent's id as made for a project: its name's slug and a UUID, never reused, whatever is deleted later. */
const agentIdFor = (name: string) => `${name.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "") || "agent"}-${randomUUID()}`;

/** What one project's commit is given beyond its plan: the ids made for it, and what the whole run records with it. */
type Made = {
	projectId: string;
	copies: Record<string, string>;
	/** The default orchestrator, made whole before the commit so its conversation can be configured from it. */
	orchestrator: AgentProfile | undefined;
	/** The orchestrator's empty conversation, made in this commit. */
	conversation: number | undefined;
	now: number;
	/** A full run's: `ranAt`, the backup, and the notes left; a conversation made later (9.9) records none of them. */
	run: { backup: string; left: string[] } | undefined;
};

/** Something the plan counted on is no longer so, part way through a run: it stops, and the next run finds what was done. */
const CHANGED_DURING = "Something changed while carrying over ran, so it stopped part way. Look at it again, and run it again.";

/**
 * One project of the plan, in one commit (9.8, 4): the project, its copies, the conversations' fields, the notes, and the
 * record. Everything it finds done (by an earlier run, or by the person since) it leaves as it is.
 */
async function applyProject(tx: Tx, entry: PlannedProject, made: Made): Promise<void> {
	const doc = await tx.doc(Projects);
	const { agents } = await tx.doc(Agents);
	const { conversations } = await tx.doc(Library);
	const memory = await tx.doc(Memory);
	const { now } = made;
	let project: Project;
	if (entry.existing !== null) {
		const found = doc.projects[entry.existing];
		if (found === undefined || found.deletedAt !== undefined) throw new Error(CHANGED_DURING);
		project = found;
		if (entry.restore && project.archivedAt !== undefined) {
			delete project.archivedAt;
			project.updatedAt = now;
		}
	} else {
		// Made meanwhile, by another run or by the person: this plan no longer holds.
		const recorded = doc.carry.folders[entry.key];
		const recordedLive = recorded !== undefined && doc.projects[recorded] !== undefined && doc.projects[recorded].deletedAt === undefined;
		const sameFolder = entry.folder !== null && Object.values(doc.projects).some((other) => other.deletedAt === undefined && other.folder === entry.folder);
		if (recordedLive || sameFolder) throw new Error(CHANGED_DURING);
		const names = new Set(Object.values(doc.projects).filter((other) => other.deletedAt === undefined).map((other) => other.name.toLowerCase()));
		project = {
			id: made.projectId,
			name: unique(entry.name, names, MAX_PROJECT_NAME),
			folder: entry.folder,
			repository: null,
			orchestratorId: "",
			conversation: null,
			earlier: [],
			settings: defaultProjectSettings("carried"),
			createdAt: now,
			updatedAt: now,
			...(entry.archived ? { archivedAt: now } : {}),
			carriedAt: now,
		};
	}
	if (entry.recordFolder) doc.carry.folders[entry.key] = project.id;

	// The copies (9.5, 3.3): found ones as they are; made ones from the template as it is now.
	const copyOf: Record<string, string> = {};
	const madeNow: string[] = [];
	for (const planned of entry.copies) {
		const pair = `${project.id} ${planned.template}`;
		const recorded = doc.carry.copies[pair];
		if (planned.existing !== null || recorded !== undefined) {
			const id = planned.existing ?? recorded!;
			if (agents[id] === undefined) continue;
			if (doc.carry.copies[pair] === undefined) doc.carry.copies[pair] = id;
			copyOf[planned.template] = id;
			continue;
		}
		const template = agents[planned.template];
		if (template === undefined || template.projectId !== undefined) throw new Error(CHANGED_DURING);
		// Documents in a commit are not plain objects: copied through JSON, as every commit here copies them.
		const copy: AgentProfile = JSON.parse(JSON.stringify(template));
		delete copy.allowEverything;
		delete copy.madeBy;
		delete copy.removedAt;
		delete copy.role;
		copy.id = made.copies[planned.template]!;
		copy.name = planned.name;
		copy.cwd = project.folder;
		copy.projectId = project.id;
		copy.template = { id: template.id, copiedAt: now, templateUpdatedAt: template.updatedAt ?? template.createdAt };
		copy.createdAt = now;
		copy.updatedAt = now;
		copy.commandRules = copy.commandRules ?? [];
		// The names alone: a value is in the Keychain only once the step after this commit has copied it.
		if (template.variables !== undefined) copy.variables = template.variables.map((variable) => ({ name: variable.name, set: false }));
		if (template.allowEverything === true) copy.allowEverything = true;
		// A copy in a project with no folder has nowhere to make a worktree from.
		if (copy.worktree === true && project.folder === null) copy.worktree = false;
		agents[copy.id] = copy;
		doc.carry.copies[pair] = copy.id;
		memory.agents[copy.id] = { enabled: memory.agents[template.id]?.enabled === true, notes: [], next: 1 };
		const names = (template.variables ?? []).filter((variable) => variable.set).map((variable) => variable.name);
		if (names.length > 0) doc.carry.secrets.push({ copyId: copy.id, templateId: template.id, names, tries: 0, lastError: null });
		copyOf[planned.template] = copy.id;
		madeNow.push(copy.id);
	}
	// Each copy made hands work to the project's copies of the templates its template named (3.3). Changed in the
	// document itself: what was put in it is not the object it was given.
	for (const id of madeNow) {
		const copy = agents[id]!;
		const named = agents[copy.template!.id]?.delegates ?? [];
		copy.delegates = named.map((other) => copyOf[other]).filter((other): other is string => other !== undefined && other !== id);
	}

	// The orchestrator of a project made (9.6).
	if (entry.existing === null && entry.orchestrator !== null) {
		const chosen = entry.orchestrator.template === null ? undefined : copyOf[entry.orchestrator.template];
		if (entry.orchestrator.template !== null) {
			if (chosen === undefined) throw new Error(CHANGED_DURING);
			agents[chosen]!.role = "orchestrator";
			project.orchestratorId = chosen;
			project.conversation = entry.orchestrator.conversation;
		} else {
			const orchestrator = made.orchestrator!;
			agents[orchestrator.id] = orchestrator;
			memory.agents[orchestrator.id] = { enabled: DEFAULT_ORCHESTRATOR.memory, notes: [], next: 1 };
			project.orchestratorId = orchestrator.id;
			if (made.conversation !== undefined) {
				project.conversation = made.conversation;
				conversations[String(made.conversation)] = { title: "", createdAt: now, updatedAt: now, access: orchestrator.access, agentId: orchestrator.id, projectId: project.id };
			}
		}
	}
	doc.projects[project.id] = project;

	// The conversations: `projectId`, and the copy each runs as; nothing else of theirs changes (9.6).
	for (const planned of entry.conversations) {
		const meta = conversations[String(planned.id)];
		if (meta === undefined || meta.deleted === true || meta.projectId !== undefined) continue;
		meta.projectId = project.id;
		const copy = planned.template === null ? undefined : copyOf[planned.template];
		if (copy !== undefined) meta.projectAgentId = copy;
	}

	// The notes, each for its agent's copy alone, once (9.7).
	for (const note of entry.notes) {
		const dealt = `${note.agent} ${note.note}`;
		if (doc.carry.notes[dealt] !== undefined) continue;
		const audience = note.copy ?? copyOf[note.agent];
		if (audience === undefined || agents[audience] === undefined) continue;
		const book = projectNotebook(memory, project.id);
		const same = book.notes.find((other) => other.audience === audience && other.text.toLowerCase() === note.text.toLowerCase());
		let id = same?.id;
		if (id === undefined) {
			id = `n${book.next++}`;
			book.notes.push({
				id,
				text: note.text,
				createdAt: note.createdAt,
				conversation: null,
				agentId: note.byAgent ? audience : null,
				audience,
				carriedFrom: { agentId: note.agent, agentName: note.agentName, id: note.note },
			});
		}
		if (note.record) doc.carry.notes[dealt] = { projectId: project.id, noteId: id };
	}

	if (made.run !== undefined) {
		for (const dealt of made.run.left) if (doc.carry.notes[dealt] === undefined) doc.carry.notes[dealt] = "left";
		if (doc.carry.backup === null) doc.carry.backup = made.run.backup;
		doc.carry.ranAt = now;
	}
}

// ---- The feature

export const carryOver: Feature = (host, engine) => {
	/** One run at a time, a conversation made later (9.9) included, so two never work from the same documents. */
	let queue: Promise<unknown> = Promise.resolve();
	const serially = <T>(work: () => Promise<T>): Promise<T> => {
		const next = queue.then(work, work);
		queue = next.catch(() => {});
		return next;
	};
	let secretsQueue: Promise<unknown> = Promise.resolve();

	/** The documents, as stored now. With `only`, only that conversation's folder is read. */
	const snapshot = async (only?: number): Promise<CarrySnapshot> => {
		const harness = engine.harness();
		const context = engine.context();
		const conversations = (await harness.snapshot(Library, context))?.conversations ?? {};
		const stored = await harness.snapshot(Projects, context);
		const projects: ProjectsDoc = stored ?? { projects: {}, carry: { ranAt: null, backup: null, folders: {}, copies: {}, notes: {}, secrets: [] }, news: {}, nextNews: 1 };
		const folders: Record<string, string | null> = {};
		for (const [id, meta] of Object.entries(conversations)) {
			if (only !== undefined && Number(id) !== only) continue;
			if (meta.parent !== undefined || meta.chat === true || meta.deleted === true || meta.projectId !== undefined) continue;
			const agent = (await harness.snapshot(AgentDoc, Number(id) as unknown as ConversationId, context)) as { cwd?: string | null } | undefined;
			folders[id] = agent?.cwd ?? null;
		}
		return {
			conversations,
			folders,
			agents: (await harness.snapshot(Agents, context))?.agents ?? {},
			memory: (await harness.snapshot(Memory, context)) ?? { agents: {} },
			worktrees: await madeWorktrees(harness, context),
			projects: JSON.parse(JSON.stringify(projects)),
		};
	};

	/** The plan as the documents give it now, with its report. */
	const look = async (only?: number) => {
		const documents = await snapshot(only);
		const plan = planCarryOver(documents, only);
		return { plan, documents, report: reportOf(plan, documents.projects.carry, documents.agents) };
	};

	/** Each project of `plan` in a commit of its own, in order; the default orchestrator's empty conversation with it. */
	const apply = async (plan: CarryPlan, run: Made["run"]) => {
		const last = plan.projects.length - 1;
		const conversations: { id: number; agent: AgentProfile }[] = [];
		for (const [index, entry] of plan.projects.entries()) {
			const now = Date.now();
			const projectId = entry.existing ?? `p-${randomUUID()}`;
			const copies = Object.fromEntries(entry.copies.filter((copy) => copy.existing === null).map((copy) => [copy.template, agentIdFor(copy.name)]));
			let orchestrator: AgentProfile | undefined;
			if (entry.existing === null && entry.orchestrator?.template === null) {
				const { memory: _, ...settings } = DEFAULT_ORCHESTRATOR;
				const taken = new Set(entry.copies.map((copy) => copy.name.toLowerCase()));
				const name = unique(settings.name, taken);
				orchestrator = { ...structuredClone(settings), name, id: agentIdFor(name), cwd: entry.folder, createdAt: now, projectId, role: "orchestrator", updatedAt: now };
			}
			const made = { projectId, copies, orchestrator, conversation: undefined, now, run: run === undefined ? undefined : { backup: run.backup, left: index === last ? run.left : [] } };
			// A project made archived has no conversation with its orchestrator until it is restored (3.2).
			if (orchestrator !== undefined && !(entry.archived && !entry.restore)) {
				const configured = await host.agentChange(orchestrator, { subChat: false });
				const created = await engine.harness().createConversation(
					{ ownership: { kind: "ownerless" }, agent: configured, init: async (tx, conversation) => applyProject(tx, entry, { ...made, conversation: conversation as unknown as number }) },
					engine.context(),
				);
				conversations.push({ id: created.id as unknown as number, agent: orchestrator });
			} else await engine.harness().commit(async (tx) => applyProject(tx, entry, made), engine.context());
		}
		// Nothing but notes left to record: one commit for them.
		if (plan.projects.length === 0 && run !== undefined && run.left.length > 0) {
			await engine.harness().commit(async (tx) => {
				const doc = await tx.doc(Projects);
				for (const dealt of run.left) if (doc.carry.notes[dealt] === undefined) doc.carry.notes[dealt] = "left";
				if (doc.carry.backup === null) doc.carry.backup = run.backup;
				doc.carry.ranAt = Date.now();
			}, engine.context());
		}
		// What features do for a conversation the person starts with an agent, as for a project made by hand.
		for (const { id, agent } of conversations) {
			for (const feature of host.features) {
				try {
					await feature.created?.(id, agent);
				} catch (error) {
					engine.log("carrying over made conversation", id, "but a feature could not set it up:", error instanceof Error ? error.message : error);
				}
			}
		}
	};

	/**
	 * Copy the variables' values still pending into the Keychain (9.5): each copy done is taken off the list, one that fails
	 * keeps its error and is tried again at the next engine start or `projects.retrySecrets`.
	 */
	const retrySecrets = (): Promise<void> => {
		const next = secretsQueue.then(async () => {
			const stored = await engine.harness().snapshot(Projects, engine.context());
			const items = stored?.carry.secrets ?? [];
			if (items.length === 0) return;
			await gate();
			const agents = (await engine.harness().snapshot(Agents, engine.context()))?.agents ?? {};
			const outcome = new Map<string, string | null>();
			for (const item of items) {
				if (agents[item.copyId] === undefined) {
					outcome.set(item.copyId, null);
					engine.log("carrying over: the copy", item.copyId, "was deleted before its variables' values were copied");
					continue;
				}
				if (agents[item.templateId] === undefined) {
					// Its values went with it (variables.ts, `deletingAgent`): there is nothing left to copy.
					outcome.set(item.copyId, null);
					engine.log("carrying over: the agent", item.templateId, "was deleted before its variables' values were copied to", item.copyId);
					continue;
				}
				try {
					await copyAgentValues(item.templateId, item.copyId, item.names);
					outcome.set(item.copyId, null);
				} catch (error) {
					outcome.set(item.copyId, error instanceof Error ? error.message : String(error));
				}
			}
			await engine.harness().commit(async (tx) => {
				const doc = await tx.doc(Projects);
				doc.carry.secrets = doc.carry.secrets.flatMap((item) => {
					if (!outcome.has(item.copyId)) return [item];
					const error = outcome.get(item.copyId)!;
					return error === null ? [] : [{ ...item, tries: item.tries + 1, lastError: error }];
				});
			}, engine.context());
		});
		secretsQueue = next.catch((error) => engine.log("carrying over could not copy variables' values:", error instanceof Error ? error.message : error));
		return next;
	};

	/** Work the plan out again; refuse unless it is `given`; run it; answer its report (9.8). */
	const run = (given: string | null) =>
		serially(async () => {
			const { plan, report, documents } = await look();
			if (report.plan === null) return report;
			if (given !== report.plan) throw new RequestError(PLAN_CHANGED, report as unknown as Record<string, unknown>);
			let backup = documents.projects.carry.backup;
			if (backup === null) {
				// Before the first run that changes anything: the database and settings as they were (9.8, 3).
				const folder = join(engine.home, "backups");
				mkdirSync(folder, { recursive: true });
				backup = await createBackup(engine.home, folder);
				engine.log("carrying over: backed up to", backup);
			}
			await apply(plan, { backup, left: plan.left });
			engine.log(`carried over: ${plan.projects.length} project${plan.projects.length === 1 ? "" : "s"}, plan ${report.plan}`);
			await retrySecrets().catch(() => {});
			const stored = (await engine.harness().snapshot(Projects, engine.context()))?.carry ?? carryRecord();
			const agents = (await engine.harness().snapshot(Agents, engine.context()))?.agents ?? {};
			return { ...report, ranAt: stored.ranAt, backup: stored.backup, secretsPending: pending(stored, agents) };
		});

	/** A top-level conversation made with the preview on, not yet in a project: into the project of its folder (9.9). */
	const carryMade = (id: number) =>
		serially(async () => {
			const { plan } = await look(id);
			if (plan.projects.length === 0) return;
			await apply(plan, undefined);
			// A project restored by it gets its orchestrator's conversation, as one the person restores does.
			for (const entry of plan.projects) if (entry.restore && entry.existing !== null) await startOrchestrator(entry.existing);
			if (plan.projects.some((entry) => entry.copies.some((copy) => copy.existing === null && copy.variables.length > 0))) void retrySecrets().catch(() => {});
		});

	/** A project carrying over made archived, restored: its orchestrator's empty conversation, if it has none yet (3.2). */
	const restored = (projectId: string) =>
		serially(() => startOrchestrator(projectId)).catch((error) =>
			engine.log("could not start the conversation with a restored project's orchestrator:", error instanceof Error ? error.message : error),
		);
	async function startOrchestrator(projectId: string): Promise<void> {
		const project = (await engine.harness().snapshot(Projects, engine.context()))?.projects[projectId];
		if (project === undefined || project.carriedAt === undefined || project.conversation !== null || project.earlier.length > 0) return;
		const orchestrator = (await engine.harness().snapshot(Agents, engine.context()))?.agents[project.orchestratorId];
		if (orchestrator === undefined) return;
		const now = Date.now();
		const created = await engine.harness().createConversation(
			{
				ownership: { kind: "ownerless" },
				agent: await host.agentChange(orchestrator, { subChat: false }),
				init: async (tx, conversation) => {
					const stored = (await tx.doc(Projects)).projects[projectId];
					if (stored === undefined || stored.conversation !== null) throw new Error("The project has a conversation with its orchestrator already");
					stored.conversation = conversation as unknown as number;
					stored.updatedAt = now;
					(await tx.doc(Library)).conversations[String(conversation)] = { title: "", createdAt: now, updatedAt: now, access: orchestrator.access, agentId: orchestrator.id, projectId };
				},
			},
			engine.context(),
		);
		for (const feature of host.features) await feature.created?.(created.id as unknown as number, orchestrator).catch(() => {});
	}

	wireCarryOver({
		previewOn: (plan) => run(plan),
		state: () => {
			const carry = carryRecord();
			if (carry.ranAt === null && carry.backup === null && carry.secrets.length === 0) return null;
			return { ranAt: carry.ranAt, backup: carry.backup, secretsPending: pending(carry, engine.agents()) };
		},
		restored,
	});

	return {
		// Not waited for: the engine need not wait for the Keychain to start.
		start: async () => void retrySecrets().catch(() => {}),
		// The plan for that one conversation leaves out a sub-chat, a chat and one in a project already.
		made: async (id) => {
			if (!projectsOn()) return;
			await carryMade(id).catch((error) => engine.log("could not carry conversation", id, "into a project:", error instanceof Error ? error.message : error));
		},
		handlers: {
			/**
			 * `{ dryRun?, plan? }`: with `dryRun`, the report of what a run would do, changing nothing, with the preview off too;
			 * without, the preview must be on, and it runs `plan`, as `projects.setPreview` does, to bring in what is new since.
			 */
			"projects.carryOver": async (params) => {
				if (params.dryRun !== undefined && typeof params.dryRun !== "boolean") throw new Error("dryRun must be true or false");
				if (params.plan !== undefined && params.plan !== null && typeof params.plan !== "string") throw new Error("plan must be the plan of the report you were shown");
				if (params.dryRun === true) return (await serially(() => look())).report;
				requirePreview();
				return run((params.plan as string | null | undefined) ?? null);
			},
			/** `{}`: try again to copy the variables' values still pending, and answer what is still pending. */
			"projects.retrySecrets": async () => {
				requirePreview();
				await retrySecrets().catch(() => {});
				const carry = (await engine.harness().snapshot(Projects, engine.context()))?.carry;
				const agents = (await engine.harness().snapshot(Agents, engine.context()))?.agents ?? {};
				return { secrets: carry === undefined ? [] : pending(carry, agents) };
			},
		},
	};
};
