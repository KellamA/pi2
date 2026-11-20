// Carrying over (#458): docs/projects.md, section 9. What a person has today is put into projects, with nothing lost,
// nothing deleted and nothing the old way reads changed: it only adds documents, adds fields the old way does not read
// (`projectId`, `projectAgentId`), and copies agents.
//
// It is worked out as one plan, `planCarryOver(snapshot)`, a function of the documents alone (and of the folders on disk,
// for grouping by repository), with every choice made by a rule and every tie broken by one. The report a dry run shows
// is that plan, with its fingerprint; a real run works the plan out again and goes ahead only if the fingerprint is the
// same. A run commits one project at a time, each commit finding what an earlier one did and recording what it did
// itself, so a run cut off part way is finished by the next, and a second run with nothing new has an empty plan and
// writes nothing at all.
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
// - No conversation is made with a project's default orchestrator: `conversation` stays null until the person first
//   opens or writes to the orchestrator, when the app makes it with `projects.startFresh` (orchestrator.ts), which marks
//   it to begin with the state block. A person with thirty folders gets no thirty empty conversations in the old sidebar.
// - Copies are made here, inside each project's commit, not through `engine.saveAgent`, which commits on its own: a run
//   cut off part way must never leave a copy without its project. So the features' `agentDuplicated` hooks are not run;
//   what knowledge.ts's and variables.ts's do (the memory switch, the variables' names) is done here, in the same commit.

import { createHash, randomUUID } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, realpathSync, rmSync, statSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
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
import { Schedules } from "./schedules.ts";
import { type AgentProfile, Agents, Library, type Meta } from "./state.ts";
import { copyAgentValues } from "./variables.ts";
import { madeWorktrees } from "./worktrees.ts";

/** The refusal of a run whose plan is not the one the person was shown (4.2, 9.8). */
export const PLAN_CHANGED = "What would be carried over has changed since you looked. Look at it again.";

// ---- Restoring one conversation of a deleted project (3.6, #531)

/** The refusal of a restore whose plan is not the one the person was shown (3.6). */
export const RESTORE_CHANGED = "What the restore would do has changed since you looked. Look at it again.";
/** A conversation that cannot be restored: it is in no project, or in one that was not deleted (3.6). */
export const NOT_OF_DELETED_PROJECT = "This conversation is not of a deleted project.";
/** The family moves as one (3.6): a sub-chat is restored through the conversation it belongs to. */
export const RESTORE_SUB_CHAT = "A sub-chat is restored with the conversation it belongs to. Restore that one.";
/** Nothing may be working or waiting in the family (3.6), though deleting the project guaranteed none was. */
export const STOP_RESTORE = "This conversation, or one of its sub-chats, is working or waiting on the person. Stop it first.";
export const RESTORE_FOLDER_MISSING = "The folder of this conversation or one of its sub-chats is missing. Put it back before restoring.";

// ---- Grouping by folder (9.2)

/** What a `.git` entry is, without following anything but the entry itself. */
function gitEntry(folder: string): "folder" | "file" | undefined {
	try {
		const stat = statSync(join(folder, ".git"));
		return stat.isDirectory() ? "folder" : stat.isFile() ? "file" : undefined;
	} catch {
		return undefined;
	}
}

/** A folder's grouping key, and a line for the report when the grouping could not be what the person might expect. */
type Keyed = { key: string; notice?: string };

/**
 * Grouping keys for one plan (9.2), without running git, each path's real path and each folder's key worked out once
 * (a plan asks for thousands). Real paths are macOS's own (`realpathSync.native`), with the case the disk has, so one
 * repository stored with two casings is one key.
 */
export class Grouping {
	readonly #real = new Map<string, string>();
	readonly #keys = new Map<string, Keyed>();
	readonly #repository = new Map<string, boolean>();
	readonly #worktrees: readonly { path: string; repo: string }[];
	readonly #home: string;

	constructor(worktrees: readonly { path: string; repo: string }[], home: string = homedir()) {
		this.#worktrees = worktrees;
		this.#home = this.real(home);
	}

	/**
	 * A path's real path. For a path that has gone, the real path of the nearest folder above it that is still there,
	 * with the rest as stored: a gone folder under a symbolic link is still found inside what the link leads to.
	 */
	real(path: string): string {
		const known = this.#real.get(path);
		if (known !== undefined) return known;
		let found: string;
		try {
			found = realpathSync.native(path);
		} catch {
			const up = dirname(path);
			found = up === path ? path : join(this.real(up), basename(path));
		}
		this.#real.set(path, found);
		return found;
	}

	/** Whether `folder` is `root` or inside it, by real paths. */
	#within(folder: string, root: string): boolean {
		return (this.real(folder) + sep).startsWith(this.real(root) + sep);
	}

	/** The grouping key of a conversation working in `cwd`: see `groupingKey`. */
	key(cwd: string | null): string {
		return this.keyed(cwd).key;
	}

	/** The key, with a line for the report about a repository that has gone or is bare. */
	keyed(cwd: string | null): Keyed {
		if (cwd === null) return { key: "none" };
		const known = this.#keys.get(cwd);
		if (known !== undefined) return known;
		const found = this.#find(cwd);
		this.#keys.set(cwd, found);
		return found;
	}

	#find(cwd: string): Keyed {
		for (const made of this.#worktrees) {
			if (!this.#within(cwd, made.path)) continue;
			const key = this.real(made.repo);
			return existsSync(made.repo) ? { key } : { key, notice: `The repository ${key}, which pi² made a worktree of, has gone: this project's folder is missing.` };
		}
		const start = this.real(cwd);
		for (let folder = start; ; ) {
			// A repository at the home folder (dotfiles, say) does not hold every folder under it together.
			if (folder === this.#home && folder !== start) break;
			const entry = gitEntry(folder);
			if (entry === "folder") return { key: folder };
			if (entry === "file") return this.#linked(folder);
			const up = dirname(folder);
			if (up === folder) break;
			folder = up;
		}
		return { key: start };
	}

	/** A folder with a `.git` file: a linked worktree's main checkout, or the folder itself (a submodule, anything else). */
	#linked(folder: string): Keyed {
		let gitdir: string | undefined;
		try {
			const line = /^gitdir:\s*(.+?)\s*$/m.exec(readFileSync(join(folder, ".git"), "utf8"));
			if (line !== null) gitdir = resolve(folder, line[1]!);
		} catch {
			// Unreadable: the folder with the file is the key.
		}
		if (gitdir === undefined) return { key: folder };
		const linked = /^(.*)\/\.git\/worktrees\/[^/]+\/?$/.exec(gitdir);
		if (linked !== null) {
			const key = this.real(linked[1]!);
			return existsSync(join(linked[1]!, ".git")) ? { key } : { key, notice: `The repository ${key}, which ${folder} is a worktree of, has gone: this project's folder is missing.` };
		}
		const bare = /^(.*)\/worktrees\/[^/]+\/?$/.exec(gitdir);
		if (bare !== null && existsSync(join(bare[1]!, "HEAD")) && !existsSync(join(bare[1]!, ".git"))) {
			return { key: folder, notice: `${folder} is a worktree of the bare repository ${this.real(bare[1]!)}: each of its worktrees is a project of its own.` };
		}
		return { key: folder };
	}

	/** Whether `folder` is in a repository, using the same home boundary as the grouping key. */
	inRepository(folder: string): boolean {
		const start = this.real(folder);
		const known = this.#repository.get(start);
		if (known !== undefined) return known;
		let found = false;
		if (existsSync(start)) {
			for (let at = start; ; at = dirname(at)) {
				if (at === this.#home && at !== start) break;
				if (gitEntry(at) !== undefined) {
					found = true;
					break;
				}
				if (dirname(at) === at) break;
			}
		}
		this.#repository.set(start, found);
		return found;
	}
}

/**
 * The grouping key of a conversation working in `cwd` (9.2), without running git: `none` for no folder; for a folder in
 * a worktree pi² made, the main checkout it was made from; otherwise, from the folder upwards, but not past the home
 * folder, the nearest folder with a `.git` entry: a folder `.git` is a main checkout, a linked worktree's file names its
 * main checkout, and any other file (a submodule's) makes its own folder the key. With none found, the folder itself. A
 * folder that has gone is walked up from as stored, so it is keyed by the repository above it that is still there.
 */
export function groupingKey(cwd: string | null, worktrees: readonly { path: string; repo: string }[], home?: string): string {
	return new Grouping(worktrees, home).key(cwd);
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
	/** The home folder, where the walk up to a repository stops (9.2). The person's, unless a test gives another. */
	home?: string;
};

/** A template the plan copies into a project, or the copy it finds there. */
export type PlannedCopy = {
	template: string;
	/** The copy's name: the template's, with " 2", " 3"… when the project has an agent by that name. */
	name: string;
	/** The copy found: recorded by an earlier run, or adopted (`adopt`). Null: one is made. */
	existing: string | null;
	adopt: boolean;
	/**
	 * For a copy made: the template's Allow everything, the names of its variables with values, and its memory switch, as
	 * the report says them. The commit takes these, not what the template has by then (9.5).
	 */
	allowEverything: boolean;
	variables: string[];
	memory: boolean;
	/** The template makes a worktree for each conversation, and the project's folder is no repository: the copy does not. */
	worktreeOff: boolean;
	/** The template's own folder, when it groups elsewhere than the project: a new sub-chat of the copy starts elsewhere. */
	folder: string | null;
};

/** One of an agent's notes, copied into one project for that agent's copy alone (9.7). */
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
};

/** One project of a plan: one found or made for a grouping key, with what the run adds to it. */
export type PlannedProject = {
	key: string;
	name: string;
	/** The project found (9.4); null for a project made. */
	existing: string | null;
	/** Found by its folder for a key the record does not send to it yet (9.4): recorded now. */
	adopted: boolean;
	/** The keys whose `carry.folders` the run points at this project: one, or more when several keys reach it. */
	recordKeys: string[];
	/** A project made: its folder, the key's path, or null for `none`. A project found: its folder. */
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
	/** Lines for the report: a repository gone, a bare repository's worktrees (9.2). */
	notices: string[];
	/** A restore of one conversation of a deleted project (3.6): that project, whose agents the plan may copy as it copies templates. */
	from?: string;
};

export type CarryPlan = {
	projects: PlannedProject[];
	/** Notes of agents deleted, left where they are and recorded `"left"`: "<agentId> <noteId>". */
	left: string[];
	leftOut: { chats: number; deleted: number; deletedProject: number };
	already: number;
};

/** The most recently updated first, then the lowest id: the tie-break of 9.3. */
const byRecent = (a: { updatedAt: number; id: number | string }, b: { updatedAt: number; id: number | string }) =>
	b.updatedAt - a.updatedAt || (typeof a.id === "number" && typeof b.id === "number" ? a.id - b.id : String(a.id) < String(b.id) ? -1 : String(a.id) > String(b.id) ? 1 : 0);
/** Agents, or projects, in the order they were made, then by id. */
const byMade = (a: { createdAt: number; id: string }, b: { createdAt: number; id: string }) => a.createdAt - b.createdAt || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0);

const isTemplate = (agent: AgentProfile | undefined): agent is AgentProfile => agent !== undefined && agent.projectId === undefined;

/**
 * An agent the plan may copy into a project: a template, and, for a restore (3.6, `from` the deleted project), an agent
 * of that project too, since the conversation being restored ran as it and it cannot start work where it is.
 */
const copyable = (agent: AgentProfile | undefined, from: string | undefined): boolean =>
	agent !== undefined && (agent.projectId === undefined || (from !== undefined && agent.projectId === from));

/** A name made unique among `taken` (lower case), with " 2", " 3"…, within the 80 characters of a project's name. */
function unique(base: string, taken: Set<string>, max = Number.POSITIVE_INFINITY): string {
	for (let n = 1; ; n++) {
		const suffix = n === 1 ? "" : ` ${n}`;
		const name = `${base.slice(0, max - suffix.length).trim()}${suffix}`;
		if (!taken.has(name.toLowerCase())) return name;
	}
}

/**
 * The project of a grouping key (9.4), among the projects not deleted, each with its key: one whose folder has the key,
 * else the one recorded for it. Among several with the key, the one recorded is kept; otherwise the one whose folder is
 * the key itself, then the oldest. A project the person made with no folder is never taken for `none`. Undefined: a new
 * project. `byFolder`: found by its folder rather than only by the record.
 */
export function lookUp(key: string, live: readonly Project[], keys: ReadonlyMap<string, string>, folders: Record<string, string>): { project: Project; byFolder: boolean } | undefined {
	const recorded = folders[key] === undefined ? undefined : live.find((project) => project.id === folders[key]);
	const candidates = live.filter((project) => keys.get(project.id) === key && (key !== "none" || project.carriedAt !== undefined));
	if (recorded !== undefined && candidates.includes(recorded)) return { project: recorded, byFolder: true };
	const exact = (project: Project) => (project.folder === key ? 0 : 1);
	const first = [...candidates].sort((a, b) => exact(a) - exact(b) || byMade(a, b))[0];
	if (first !== undefined) return { project: first, byFolder: true };
	return recorded === undefined ? undefined : { project: recorded, byFolder: false };
}

/**
 * What carrying over would do, from the documents alone: every choice made by a rule of section 9, every tie broken by
 * 9.3's, so the same documents give the same plan. With `only`, the plan for that one top-level conversation, made later
 * or left in no project (9.9), with its sub-chats. With `from`, a deleted project's id, the plan is a restore of that one
 * conversation (3.6): its family arrives stripped of its project, and the agents of the deleted project may be copied
 * into the project of the family's folder as templates are.
 */
export function planCarryOver(snapshot: CarrySnapshot, only?: number, options?: { from?: string }): CarryPlan {
	const { conversations, agents, memory } = snapshot;
	const from = options?.from;
	const grouping = new Grouping(snapshot.worktrees, snapshot.home);
	const doc = snapshot.projects;
	const live = Object.values(doc.projects).filter((project) => project.deletedAt === undefined);
	const liveById = new Map(live.map((project) => [project.id, project]));
	const projectKey = new Map(live.map((project) => [project.id, project.folder === null ? "none" : grouping.key(project.folder)]));
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

	const leftOut = { chats: 0, deleted: 0, deletedProject: 0 };
	let already = 0;
	let otherUncarried = false;
	/** Top-level conversations to add, by key; sub-chats to add, by key or by the project their root is in. */
	const byKey = new Map<string, { tops: number[]; subs: number[] }>();
	const byProject = new Map<string, number[]>();
	const keyOf = new Map<number, string>();
	const noticesOf = new Map<string, Set<string>>();
	const keyFor = (id: number): string => {
		const known = keyOf.get(id);
		if (known !== undefined) return known;
		const { key, notice } = grouping.keyed(snapshot.folders[String(id)] ?? null);
		keyOf.set(id, key);
		if (notice !== undefined) noticesOf.set(key, (noticesOf.get(key) ?? new Set()).add(notice));
		return key;
	};
	const bucket = (key: string) => byKey.get(key) ?? byKey.set(key, { tops: [], subs: [] }).get(key)!;
	for (const id of ids) {
		const m = meta(id)!;
		if (m.version === true) continue;
		const root = rootOf(id);
		if (only !== undefined && root !== only) {
			if (m.projectId === undefined && m.deleted !== true && m.chat !== true && root !== undefined && meta(root)?.deleted !== true && meta(root)?.chat !== true) otherUncarried = true;
			continue;
		}
		if (m.chat === true) {
			if (m.deleted !== true && only === undefined) leftOut.chats++;
			continue;
		}
		if (m.projectId !== undefined) {
			if (m.parent === undefined && m.deleted !== true && only === undefined) {
				if (doc.projects[m.projectId]?.deletedAt !== undefined) leftOut.deletedProject++;
				else already++;
			}
			continue;
		}
		const rootMeta = root === undefined ? undefined : meta(root);
		if (m.deleted === true || rootMeta === undefined || rootMeta.deleted === true || rootMeta.chat === true) {
			if (only === undefined && rootMeta?.chat !== true) leftOut.deleted++;
			continue;
		}
		if (m.parent === undefined) bucket(keyFor(id)).tops.push(id);
		else if (rootMeta.projectId !== undefined) {
			// A sub-chat made since in a conversation already in a project: into that project, if it is still there.
			if (liveById.has(rootMeta.projectId)) byProject.set(rootMeta.projectId, [...(byProject.get(rootMeta.projectId) ?? []), id]);
		} else bucket(keyFor(root!)).subs.push(id);
	}

	// 9.4: the project of each key.
	const entries = new Map<string, PlannedProject>();
	const names = new Set(live.map((project) => project.name.toLowerCase()));
	const entryFor = (project: Project, key: string, adopted: boolean): PlannedProject => {
		const found = entries.get(project.id);
		if (found !== undefined) {
			found.adopted ||= adopted;
			if (adopted && !found.recordKeys.includes(key)) found.recordKeys.push(key);
			return found;
		}
		const made: PlannedProject = {
			key,
			name: project.name,
			existing: project.id,
			adopted,
			recordKeys: adopted ? [key] : [],
			folder: project.folder,
			archived: project.archivedAt !== undefined,
			restore: false,
			orchestrator: null,
			copies: [],
			conversations: [],
			notes: [],
			notices: [],
		};
		entries.set(project.id, made);
		return made;
	};
	const add = (entry: PlannedProject, id: number, subChat: boolean) =>
		entry.conversations.push({ id, template: null, archived: meta(id)!.archivedAt !== undefined, subChat });
	for (const key of [...byKey.keys()].sort()) {
		const { tops, subs } = byKey.get(key)!;
		let entry: PlannedProject;
		const found = lookUp(key, live, projectKey, doc.carry.folders);
		if (found !== undefined) {
			// Adopted: found by its folder for a key the record does not send to it yet. One a run made or adopted before is
			// found the same way, and is not adopted again.
			entry = entryFor(found.project, key, found.byFolder && doc.carry.folders[key] !== found.project.id);
		} else {
			const name = unique(key === "none" ? "No folder" : basename(key).trim() || key, names, MAX_PROJECT_NAME);
			names.add(name.toLowerCase());
			entry = {
				key,
				name,
				existing: null,
				adopted: false,
				recordKeys: [key],
				folder: key === "none" ? null : key,
				archived: tops.every((id) => meta(id)!.archivedAt !== undefined),
				restore: false,
				orchestrator: null,
				copies: [],
				conversations: [],
				notes: [],
				notices: [],
			};
			entries.set(`key:${key}`, entry);
		}
		for (const notice of noticesOf.get(key) ?? []) if (!entry.notices.includes(notice)) entry.notices.push(notice);
		// A conversation made later in the folder of an archived project restores it, since the person set it going (3.6);
		// one archived already, carried as it was left, does not.
		if (only !== undefined && entry.existing !== null && entry.archived && tops.some((id) => meta(id)!.archivedAt === undefined)) entry.restore = true;
		for (const id of tops) add(entry, id, false);
		for (const id of subs) add(entry, id, true);
	}
	for (const [projectId, subs] of byProject) {
		const entry = entryFor(liveById.get(projectId)!, projectKey.get(projectId)!, false);
		for (const id of subs) add(entry, id, true);
	}

	// 9.5: the templates each project's conversations ran as, and those they may hand work to, followed through.
	for (const entry of entries.values()) {
		if (from !== undefined) entry.from = from;
		const wanted = new Set<string>();
		const queue = entry.conversations.map(({ id }) => meta(id)!.agentId).filter((id): id is string => id !== undefined && copyable(agents[id], from));
		while (queue.length > 0) {
			const id = queue.shift()!;
			if (wanted.has(id)) continue;
			wanted.add(id);
			for (const other of agents[id]!.delegates ?? []) if (copyable(agents[other], from) && agents[other].removedAt === undefined) queue.push(other);
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
			const made = existing === null;
			entry.copies.push({
				template: template.id,
				name,
				existing,
				adopt,
				allowEverything: made && template.allowEverything === true,
				variables: made ? (template.variables ?? []).filter((variable) => variable.set).map((variable) => variable.name) : [],
				memory: made && memory.agents[template.id]?.enabled === true,
				worktreeOff: made && template.worktree === true && (entry.folder === null || !grouping.inRepository(entry.folder)),
				folder: made && template.cwd !== null && grouping.key(template.cwd) !== entry.key ? template.cwd : null,
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

	// 9.7: each note of an agent's goes to each project with a copy of that agent, for the copy alone, and is recorded for
	// that project as it is copied there; a project that gets a copy later gets the notes then.
	/** Where the notes of `template` may go: the projects of the plan with a copy of it, and those with one recorded. */
	const destinationsOf = (template: string): { project: string; copy: string | null; entry: PlannedProject | undefined }[] => {
		const found = new Map<string, { project: string; copy: string | null; entry: PlannedProject | undefined }>();
		for (const [id, entry] of entries) {
			const copy = entry.copies.find((one) => one.template === template);
			if (copy !== undefined) found.set(id, { project: id, copy: copy.existing, entry });
		}
		for (const [pair, copy] of Object.entries(doc.carry.copies)) {
			const [projectId, from] = pair.split(" ");
			if (from !== template || found.has(projectId!) || !liveById.has(projectId!)) continue;
			// A removed or deleted copy cannot receive a note, but still reserves the notes written in its project.
			found.set(projectId!, { project: projectId!, copy, entry: entries.get(projectId!) });
		}
		return [...found.values()];
	};
	/** The project, or plan entry, a conversation is in after the plan; undefined for none. */
	const homeOf = (conversation: number | null): string | undefined => {
		const written = conversation === null ? undefined : meta(conversation);
		if (written === undefined || written.deleted === true) return undefined;
		if (written.projectId !== undefined) return liveById.has(written.projectId) ? written.projectId : undefined;
		for (const [id, entry] of entries) if (entry.conversations.some((one) => one.id === conversation)) return id;
		return undefined;
	};
	// Other uncarried conversations can give a note a home (or give its home a copy) in a full plan. Use that plan's
	// routing in this case, but leave its other copies and conversations for their own carry.
	const noteKey = (destination: string, agent: string, note: string) => JSON.stringify([destination, agent, note]);
	let fullNotes: Set<string> | undefined;
	const left: string[] = [];
	const templates = only === undefined ? Object.keys(memory.agents) : [...new Set([...entries.values()].flatMap((entry) => entry.copies.map((copy) => copy.template)))];
	for (const agentId of templates.sort()) {
		const notes = memory.agents[agentId]?.notes ?? [];
		if (notes.length === 0) continue;
		const agent = agents[agentId];
		if (agent === undefined) {
			// An agent deleted: its notes are kept, shown nowhere today, and left where they are.
			if (only === undefined) for (const note of notes) if (doc.carry.notes[`${agentId} ${note.id}`] === undefined) left.push(`${agentId} ${note.id}`);
			continue;
		}
		// A project agent's own notes: there are none to carry; its notes are its project's.
		if (agent.projectId !== undefined) continue;
		const destinations = destinationsOf(agentId);
		if (destinations.length === 0) continue;
		if (otherUncarried) fullNotes ??= new Set(planCarryOver(snapshot).projects.flatMap((entry) =>
			entry.notes.map((note) => noteKey(entry.existing ?? `key:${entry.key}`, note.agent, note.note)),
		));
		for (const note of notes) {
			// Where a conversation of that agent's wrote it, when that project has a copy; else (the person wrote it, or its
			// conversation is gone or in no project with a copy) every project with a copy.
			const home = homeOf(note.conversation);
			const there = destinations.filter((one) => one.project === home);
			for (const destination of fullNotes !== undefined || there.length === 0 ? destinations : there) {
				if (fullNotes !== undefined && !fullNotes.has(noteKey(destination.project, agentId, note.id))) continue;
				if (only !== undefined && !destination.entry?.copies.some((copy) => copy.template === agentId)) continue;
				if (destination.copy !== null && (agents[destination.copy] === undefined || agents[destination.copy].removedAt !== undefined)) continue;
				if (destination.entry === undefined || destination.entry.existing !== null) {
					if (doc.carry.notes[`${destination.project} ${agentId} ${note.id}`] !== undefined) continue;
				}
				const entry = destination.entry ?? entryFor(liveById.get(destination.project)!, projectKey.get(destination.project)!, false);
				destination.entry = entry;
				entry.notes.push({ agent: agentId, agentName: agent.name, note: note.id, text: note.text, createdAt: note.createdAt, byAgent: note.conversation !== null, copy: destination.copy });
			}
		}
	}

	const projects = [...entries.values()]
		.filter((entry) => entry.conversations.length > 0 || entry.notes.length > 0)
		.sort((a, b) => (a.key < b.key ? -1 : a.key > b.key ? 1 : (a.existing ?? "") < (b.existing ?? "") ? -1 : 1));
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
				worktreeOff: copy.worktreeOff,
				folder: copy.folder,
			})),
			conversations: entry.conversations.filter((one) => !one.subChat && !one.archived).length,
			archivedConversations: entry.conversations.filter((one) => !one.subChat && one.archived).length,
			subChats: entry.conversations.filter((one) => one.subChat).length,
			notes: entry.notes.length,
			notices: [...entry.notices],
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
 * Tests hold a run at a point, to stop the engine there as a crash would: while the file the variable `name` names
 * exists, the run waits there, having written `<file>.started`. `PI2_CARRY_SECRETS_GATE` holds the Keychain step;
 * `PI2_CARRY_COMMIT_GATE` holds the run before each project's commit but the first; `PI2_RESTORE_COMMIT_GATE` holds
 * a restore after it has checked the plan but before its transaction.
 */
async function gate(name: "PI2_CARRY_SECRETS_GATE" | "PI2_CARRY_COMMIT_GATE" | "PI2_RESTORE_COMMIT_GATE"): Promise<void> {
	const file = process.env[name];
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
	/** The default orchestrator, made whole before the commit. */
	orchestrator: AgentProfile | undefined;
	now: number;
	/** A full run's: `ranAt`, the backup, and the notes left; a conversation made later (9.9) records none of them. */
	run: { backup: string; left: string[] } | undefined;
};

/** Something the plan counted on is no longer so, part way through a run: it stops, and the next run finds what was done. */
export const CHANGED_DURING = "Something changed while carrying over ran, so it stopped part way. Look at it again, and run it again.";

/**
 * One project of the plan, in one commit (9.8, 4): the project, its copies, the conversations' fields, the notes, and the
 * record. Everything it finds done (by an earlier run, or by the person since) it leaves as it is.
 */
export async function applyProject(tx: Tx, entry: PlannedProject, made: Made, grouping: Grouping): Promise<void> {
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
	for (const key of entry.recordKeys) doc.carry.folders[key] = project.id;

	// The copies (9.5, 3.3): found ones as they are; made ones from the template, with what the plan said it takes.
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
		// A restore may copy an agent of the deleted project it comes from (3.6, `entry.from`); anything else with a project is not a template.
		if (template === undefined || (template.projectId !== undefined && template.projectId !== entry.from)) throw new Error(CHANGED_DURING);
		// The report listed what the copy takes beyond a copy made by hand. A template that has gained one of those since
		// stops the run; one that has lost one gives the copy what is left of it.
		const valuesNow = (template.variables ?? []).filter((variable) => variable.set).map((variable) => variable.name);
		const memoryNow = memory.agents[template.id]?.enabled === true;
		const worktreeOff = template.worktree === true && (project.folder === null || !grouping.inRepository(project.folder));
		if ((template.allowEverything === true && !planned.allowEverything) || valuesNow.some((name) => !planned.variables.includes(name)) || (memoryNow && !planned.memory) || (worktreeOff && !planned.worktreeOff)) {
			throw new Error(CHANGED_DURING);
		}
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
		if (planned.allowEverything && template.allowEverything === true) copy.allowEverything = true;
		// No worktree where the project's folder is no repository: there is nothing to make one from (agents.save's check).
		if (worktreeOff) copy.worktree = false;
		agents[copy.id] = copy;
		doc.carry.copies[pair] = copy.id;
		memory.agents[copy.id] = { enabled: planned.memory && memoryNow, notes: [], next: 1 };
		const names = planned.variables.filter((name) => valuesNow.includes(name));
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

	// The orchestrator of a project made (9.6). The default one has no conversation until the person opens it.
	if (entry.existing === null && entry.orchestrator !== null) {
		if (entry.orchestrator.template !== null) {
			const chosen = copyOf[entry.orchestrator.template];
			if (chosen === undefined) throw new Error(CHANGED_DURING);
			agents[chosen]!.role = "orchestrator";
			project.orchestratorId = chosen;
		} else {
			const orchestrator = made.orchestrator!;
			agents[orchestrator.id] = orchestrator;
			memory.agents[orchestrator.id] = { enabled: DEFAULT_ORCHESTRATOR.memory, notes: [], next: 1 };
			project.orchestratorId = orchestrator.id;
		}
	}
	doc.projects[project.id] = project;

	// The conversations: `projectId`, and the copy each runs as; nothing else of theirs changes (9.6).
	const moved = new Set<number>();
	for (const planned of entry.conversations) {
		const meta = conversations[String(planned.id)];
		if (meta === undefined || meta.deleted === true || meta.projectId !== undefined) continue;
		meta.projectId = project.id;
		const copy = planned.template === null ? undefined : copyOf[planned.template];
		if (copy !== undefined) meta.projectAgentId = copy;
		moved.add(planned.id);
	}
	// The conversation chosen as the orchestrator's must be one this commit took: not deleted or taken since.
	if (entry.existing === null && entry.orchestrator?.conversation != null) {
		if (!moved.has(entry.orchestrator.conversation)) throw new Error(CHANGED_DURING);
		// In the document itself: what was put in it is not the object it was given.
		doc.projects[project.id]!.conversation = entry.orchestrator.conversation;
	}

	// The notes, each for its agent's copy alone, recorded for this project in this commit (9.7).
	for (const note of entry.notes) {
		const dealt = `${project.id} ${note.agent} ${note.note}`;
		if (doc.carry.notes[dealt] !== undefined) continue;
		const audience = note.copy ?? copyOf[note.agent];
		if (audience === undefined || agents[audience] === undefined || agents[audience].removedAt !== undefined) continue;
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
		doc.carry.notes[dealt] = { projectId: project.id, noteId: id };
	}

	if (made.run !== undefined) {
		for (const dealt of made.run.left) if (doc.carry.notes[dealt] === undefined) doc.carry.notes[dealt] = "left";
		if (doc.carry.backup === null) doc.carry.backup = made.run.backup;
		doc.carry.ranAt = now;
	}
}

// ---- The feature

/** Set as the feature is made: the project a new conversation in `cwd` would be carried into, for `admit` (8.3). */
let projectForFolder: ((cwd: string | null) => Promise<string | undefined>) | undefined;

/**
 * The project a conversation the person starts with `agent`, working in `cwd`, will be carried into as it is made (9.9),
 * so that its start is checked against that project's limits (8.3): with the preview on, for a template, the project of
 * its folder, if one exists. Undefined otherwise: an agent of a project is checked against its own, and a project made
 * for the folder has no limits.
 */
export async function carriedProjectFor(agent: AgentProfile, cwd: string | null): Promise<string | undefined> {
	if (!projectsOn() || agent.projectId !== undefined || projectForFolder === undefined) return undefined;
	return projectForFolder(cwd);
}

export const carryOver: Feature = (host, engine) => {
	/** One run at a time, a conversation made later (9.9) included, so two never work from the same documents. */
	let queue: Promise<unknown> = Promise.resolve();
	const serially = <T>(work: () => Promise<T>): Promise<T> => {
		const next = queue.then(work, work);
		queue = next.catch(() => {});
		return next;
	};
	let secretsQueue: Promise<unknown> = Promise.resolve();

	const storedProjects = async (): Promise<ProjectsDoc> => {
		const stored = await engine.harness().snapshot(Projects, engine.context());
		return JSON.parse(JSON.stringify(stored ?? { projects: {}, carry: { ranAt: null, backup: null, folders: {}, copies: {}, notes: {}, secrets: [] }, news: {}, nextNews: 1 }));
	};

	/** The documents, as stored now. Other uncarried conversations can determine where a note belongs (9.7). */
	const folderOf = async (id: number, tx?: Tx): Promise<string | null> => {
		const conversation = id as unknown as ConversationId;
		const agent = tx === undefined
			? await engine.harness().snapshot(AgentDoc, conversation, engine.context())
			: await tx.doc(AgentDoc, conversation);
		return agent?.cwd ?? null;
	};
	const snapshot = async (tx?: Tx): Promise<CarrySnapshot> => {
		const harness = engine.harness();
		const context = engine.context();
		const library = tx === undefined ? await harness.snapshot(Library, context) : await tx.doc(Library);
		const conversations = library?.conversations ?? {};
		const folders: Record<string, string | null> = {};
		for (const [id, meta] of Object.entries(conversations)) {
			if (meta.parent !== undefined || meta.chat === true || meta.version === true || meta.deleted === true || meta.projectId !== undefined) continue;
			folders[id] = await folderOf(Number(id), tx);
		}
		const agents = tx === undefined ? await harness.snapshot(Agents, context) : await tx.doc(Agents);
		const memory = tx === undefined ? await harness.snapshot(Memory, context) : await tx.doc(Memory);
		return {
			conversations,
			folders,
			agents: agents?.agents ?? {},
			memory: memory ?? { agents: {} },
			worktrees: await madeWorktrees(harness, context, tx),
			projects: tx === undefined ? await storedProjects() : await tx.doc(Projects),
		};
	};

	/** The plan as the documents give it now, with its report. */
	const look = async (only?: number) => {
		const documents = await snapshot();
		const plan = planCarryOver(documents, only);
		return { plan, documents, report: reportOf(plan, documents.projects.carry, documents.agents) };
	};

	/** What one project's commit is given beyond its plan: the ids made for it, and the default orchestrator. */
	const madeFor = (entry: PlannedProject, now: number): Made => {
		const projectId = entry.existing ?? `p-${randomUUID()}`;
		const copies = Object.fromEntries(entry.copies.filter((copy) => copy.existing === null).map((copy) => [copy.template, agentIdFor(copy.name)]));
		let orchestrator: AgentProfile | undefined;
		if (entry.existing === null && entry.orchestrator?.template === null) {
			const { memory: _, ...settings } = DEFAULT_ORCHESTRATOR;
			const taken = new Set(entry.copies.map((copy) => copy.name.toLowerCase()));
			const name = unique(settings.name, taken);
			orchestrator = { ...structuredClone(settings), name, id: agentIdFor(name), cwd: entry.folder, createdAt: now, projectId, role: "orchestrator", updatedAt: now };
		}
		return { projectId, copies, orchestrator, now, run: undefined };
	};

	/** Each project of `plan` in a commit of its own, in order. */
	const apply = async (plan: CarryPlan, documents: CarrySnapshot, run: Made["run"]) => {
		const grouping = new Grouping(documents.worktrees, documents.home);
		const last = plan.projects.length - 1;
		for (const [index, entry] of plan.projects.entries()) {
			if (index > 0) await gate("PI2_CARRY_COMMIT_GATE");
			const made = { ...madeFor(entry, Date.now()), run: run === undefined ? undefined : { backup: run.backup, left: index === last ? run.left : [] } };
			await engine.harness().commit(async (tx) => applyProject(tx, entry, made, grouping), engine.context());
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
			await gate("PI2_CARRY_SECRETS_GATE");
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
			await apply(plan, documents, { backup, left: plan.left });
			engine.log(`carried over: ${plan.projects.length} project${plan.projects.length === 1 ? "" : "s"}, plan ${report.plan}`);
			await retrySecrets().catch(() => {});
			const stored = (await engine.harness().snapshot(Projects, engine.context()))?.carry ?? carryRecord();
			const agents = (await engine.harness().snapshot(Agents, engine.context()))?.agents ?? {};
			return { ...report, ranAt: stored.ranAt, backup: stored.backup, secretsPending: pending(stored, agents) };
		});

	const checkIdle = (family: ReadonlySet<number>) => {
		if ([...family].some((member) => host.working(member)) || host.inbox.list().some((item) => family.has(item.conversationId))) {
			throw new Error(STOP_RESTORE);
		}
	};

	/** The family and its plan (3.6); in the move's transaction these are read from the documents it will write. */
	const lookRestore = async (id: number, tx?: Tx) => {
		requirePreview();
		const documents = await snapshot(tx);
		const root = documents.conversations[String(id)];
		if (root === undefined || root.deleted === true) throw new Error(`Unknown conversation: ${id}`);
		if (root.parent !== undefined) throw new Error(RESTORE_SUB_CHAT);
		const from = root.projectId;
		if (root.chat === true || root.version === true || from === undefined || documents.projects.projects[from]?.deletedAt === undefined) {
			throw new Error(NOT_OF_DELETED_PROJECT);
		}
		const children = new Map<number, number[]>();
		for (const [key, meta] of Object.entries(documents.conversations)) {
			if (meta.version === true || meta.parent === undefined) continue;
			if (!children.has(meta.parent)) children.set(meta.parent, []);
			children.get(meta.parent)!.push(Number(key));
		}
		const family = new Set<number>([id]);
		for (const member of family) for (const child of children.get(member) ?? []) family.add(child);
		checkIdle(family);
		const scheduleDoc = tx === undefined ? await engine.harness().snapshot(Schedules, engine.context()) : await tx.doc(Schedules);
		if (Object.values(scheduleDoc?.schedules ?? {}).some((schedule) => schedule.pending !== null && family.has(schedule.pending.conversationId))) {
			throw new Error(STOP_RESTORE);
		}
		// A restore is a carry of this family (9.9), stripped of the old project and the root's archived state.
		const conversations: Record<string, Meta> = JSON.parse(JSON.stringify(documents.conversations));
		const folders = { ...documents.folders };
		for (const member of family) {
			const meta = conversations[String(member)]!;
			if (meta.deleted === true || meta.chat === true) continue;
			const cwd = await folderOf(member, tx);
			if (cwd !== null) {
				let directory = false;
				try { directory = statSync(cwd).isDirectory(); } catch { /* Gone or no longer reachable. */ }
				if (!directory) throw new Error(RESTORE_FOLDER_MISSING);
			}
			if (member === id) folders[String(id)] = cwd;
			delete meta.projectId;
			delete meta.projectAgentId;
		}
		delete conversations[String(id)]!.archivedAt;
		const plan = planCarryOver({ ...documents, conversations, folders }, id, { from });
		const entry = plan.projects[0]!;
		const rootTemplate = entry.conversations.find((one) => one.id === id)!.template;
		const rootCopy = entry.copies.find((copy) => copy.template === rootTemplate);
		const removed = rootCopy?.existing != null && documents.agents[rootCopy.existing]?.removedAt !== undefined;
		const rootAgent = removed ? null : rootTemplate;
		const original = root.agentId === undefined ? undefined : documents.agents[root.agentId];
		// A removed or deleted copy stays that way. Tell the person what this means for the root (3.4).
		if (rootAgent === null && original !== undefined) {
			const reason = removed ? "This project’s copy was removed and will not be used." : "No copy will be made for this conversation.";
			entry.notices.push(`${reason} It keeps ${original.name} as its agent.${original.projectId === from ? " That agent still belongs to the deleted project and is not available for new starts." : ""}`);
		} else if (rootAgent === null && root.agentId !== undefined) {
			entry.notices.push("Its original agent was deleted. This conversation keeps the setup it has.");
		}
		const report = { ...reportOf(plan, documents.projects.carry, documents.agents), rootAgent, restoresProject: entry.restore };
		return { report, documents, from, family, entry };
	};

	const restore = (id: number, dryRun: boolean, given: string | null) =>
		serially(async () => {
			const preview = await lookRestore(id);
			if (dryRun) return preview.report;
			if (given !== preview.report.plan) throw new RequestError(RESTORE_CHANGED, preview.report);
			let backup = preview.documents.projects.carry.backup;
			let newBackup: string | undefined;
			if (backup === null) {
				const folder = join(engine.home, "backups");
				mkdirSync(folder, { recursive: true });
				newBackup = backup = await createBackup(engine.home, folder);
				engine.log("restoring: backed up to", backup);
			}
			await gate("PI2_RESTORE_COMMIT_GATE");
			const { report, entry, from, projectId } = await engine.harness().commit(async (tx) => {
				// Other requests do not share the carry queue. Replan inside the write transaction, after the backup.
				const { report, documents, entry, from, family } = await lookRestore(id, tx);
				if (given !== report.plan) throw new RequestError(RESTORE_CHANGED, report);
				const library = await tx.doc(Library);
				for (const { id: member } of entry.conversations) {
					const meta = library.conversations[String(member)]!;
					delete meta.projectId;
					delete meta.projectAgentId;
					if (member === id) delete meta.archivedAt;
				}
				const made = madeFor(entry, Date.now());
				await applyProject(tx, entry, made, new Grouping(documents.worktrees, documents.home));
				const { projects, carry } = await tx.doc(Projects);
				const source = projects[from]!;
				if (source.conversation === id) source.conversation = null;
				if (source.earlier.includes(id)) source.earlier = source.earlier.filter((other) => other !== id);
				if (carry.backup === null) carry.backup = backup;
				requirePreview();
				checkIdle(family);
				return { report, entry, from, projectId: made.projectId };
			}, engine.context()).catch(async (error) => {
				// A refused first restore must not leave an unrecorded backup in the way of retrying it.
				if (newBackup !== undefined) {
					try {
						if ((await storedProjects()).carry.backup !== newBackup) rmSync(newBackup, { force: true, recursive: true });
					} catch (cleanup) {
						engine.log("restoring: could not clean up the unused backup", cleanup);
					}
				}
				throw error;
			});
			engine.log(`restored conversation ${id} of the deleted project ${from} into ${projectId}`);
			if (entry.copies.some((copy) => copy.existing === null && copy.variables.length > 0)) await retrySecrets().catch(() => {});
			const stored = (await engine.harness().snapshot(Projects, engine.context()))?.carry ?? carryRecord();
			const agents = (await engine.harness().snapshot(Agents, engine.context()))?.agents ?? {};
			return { ...report, projectId, backup: stored.backup, secretsPending: pending(stored, agents) };
		});

	/** A top-level conversation not yet in a project, with the preview on: into the project of its folder (9.9). */
	const carryOne = (id: number) =>
		serially(async () => {
			if (!projectsOn()) return;
			const { plan, documents } = await look(id);
			if (plan.projects.length === 0) return;
			await apply(plan, documents, undefined);
			if (plan.projects.some((entry) => entry.copies.some((copy) => copy.existing === null && copy.variables.length > 0))) void retrySecrets().catch(() => {});
		});

	/**
	 * Every top-level conversation that is not a chat, not deleted and in no project, carried one by one, with the preview
	 * on: at engine start, and after a conversation made later could not be carried, so that one left behind (by a crash
	 * between the commit that made it and the one that carries it, or by a failure) is carried still. Until a run is
	 * recorded, the report and backup must come first. A conversation of a deleted project keeps its `projectId` (3.6).
	 */
	const strays = async (): Promise<void> => {
		if (!projectsOn() || carryRecord().ranAt === null) return;
		const conversations = (await engine.harness().snapshot(Library, engine.context()))?.conversations ?? {};
		const left = Object.entries(conversations)
			.filter(([, meta]) => meta.parent === undefined && meta.chat !== true && meta.version !== true && meta.deleted !== true && meta.projectId === undefined)
			.map(([id]) => Number(id))
			.sort((a, b) => a - b);
		for (const id of left) {
			await carryOne(id).catch((error) => engine.log("could not carry conversation", id, "into a project:", error instanceof Error ? error.message : error));
		}
	};

	projectForFolder = async (cwd) => {
		const projects = await storedProjects();
		const grouping = new Grouping(await madeWorktrees(engine.harness(), engine.context()));
		const live = Object.values(projects.projects).filter((project) => project.deletedAt === undefined);
		const keys = new Map(live.map((project) => [project.id, project.folder === null ? "none" : grouping.key(project.folder)]));
		return lookUp(grouping.key(cwd), live, keys, projects.carry.folders)?.project.id;
	};

	wireCarryOver({
		previewOn: (plan) => run(plan),
		state: () => {
			const carry = carryRecord();
			if (carry.ranAt === null && carry.backup === null && carry.secrets.length === 0) return null;
			return { ranAt: carry.ranAt, backup: carry.backup, secretsPending: pending(carry, engine.agents()) };
		},
	});

	return {
		start: async () => {
			// Not waited for: the engine need not wait for the Keychain to start.
			void retrySecrets().catch(() => {});
			// Once every feature has started, the preview's switch read among them.
			void host.ready.then(strays).catch((error) => engine.log("could not carry the conversations in no project:", error instanceof Error ? error.message : error));
		},
		// The plan for that one conversation leaves out a sub-chat, a chat and one in a project already.
		made: async (id) => {
			if (!projectsOn()) return;
			try {
				await carryOne(id);
			} catch (error) {
				engine.log("could not carry conversation", id, "into a project:", error instanceof Error ? error.message : error);
				// Once more, with any other left behind; a failure there is logged, and the next engine start tries again.
				void strays();
			}
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
			/**
			 * `{ id, dryRun?, plan? }` (3.6, #531): the restore of one conversation of a deleted project, only with the
			 * preview on. With `dryRun`, the report of what the restore would do, changing nothing; without, `plan` must be
			 * the dry run's, and the move is one commit with a backup first, taken only from the app (answers.ts).
			 */
			"projects.restoreConversation": async (params) => {
				if (typeof params.id !== "number") throw new Error("id must be a conversation's id");
				if (params.dryRun !== undefined && typeof params.dryRun !== "boolean") throw new Error("dryRun must be true or false");
				if (params.plan !== undefined && params.plan !== null && typeof params.plan !== "string") throw new Error("plan must be the plan of the report you were shown");
				requirePreview();
				return restore(params.id, params.dryRun === true, (params.plan as string | null | undefined) ?? null);
			},
		},
	};
};
