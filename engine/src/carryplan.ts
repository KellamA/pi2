// Carrying over's plan (#458): docs/projects.md, sections 9.2 to 9.8, and 3.13 for schedules. What carrying over would
// do, worked out from the documents alone; carryover.ts runs it, at the update, for a conversation made later and for a
// restore (3.6), and gives the schedules their copies.
//
// It is worked out as one plan, `planCarryOver(snapshot)`, a function of the documents alone (and of the folders on disk,
// for grouping by repository), with every choice made by a rule and every tie broken by one. The report a dry run shows
// is that plan, with its fingerprint; a real run works the plan out again and goes ahead only if the fingerprint is the
// same.

import { createHash } from "node:crypto";
import { existsSync, readFileSync, realpathSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join, resolve, sep } from "node:path";
import type { MemoryDoc } from "./knowledge.ts";
import { type CarryOverReport, type CarryOverState, MAX_PROJECT_NAME, type Project, type ProjectsDoc } from "./projects.ts";
import type { Schedule } from "./schedules.ts";
import type { AgentProfile, Meta } from "./state.ts";

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
	/**
	 * Sub-chats in the project already, made with the switch off in a conversation carried over, which took its
	 * `projectId` but no `projectAgentId` (#715): each given the copy the project has of its agent.
	 */
	fixes: { id: number; copy: string }[];
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

/**
 * An agent the plan may copy into a project: a template, and, for a restore (3.6, `from` the deleted project), an agent
 * of that project too, since the conversation being restored ran as it and it cannot start work where it is.
 */
const copyable = (agent: AgentProfile | undefined, from: string | undefined): boolean =>
	agent !== undefined && (agent.projectId === undefined || (from !== undefined && agent.projectId === from));

/** A name made unique among `taken` (lower case), with " 2", " 3"…, within the 80 characters of a project's name. */
export function unique(base: string, taken: Set<string>, max = Number.POSITIVE_INFINITY): string {
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
	/** By project: its sub-chats to put right (`fixes`). */
	const fixesOf = new Map<string, { id: number; copy: string }[]>();
	/**
	 * The copy project `projectId` has of template `templateId`, by 9.5's rules: the one recorded, unless the person deleted
	 * it since; else the oldest agent of the project made from it. Undefined: none.
	 */
	const copyIn = (projectId: string, templateId: string): string | undefined => {
		const recorded = doc.carry.copies[`${projectId} ${templateId}`];
		if (recorded !== undefined) return agents[recorded] === undefined ? undefined : recorded;
		return Object.values(agents)
			.filter((agent) => agent.projectId === projectId && agent.template?.id === templateId)
			.sort(byMade)[0]?.id;
	};
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
			// A sub-chat made with the switch off in a conversation carried over (9.11 of the versions with the switch): in
			// the project, running as the template. Given the project's copy, if it has one; none is made for it.
			const template = m.agentId === undefined ? undefined : agents[m.agentId];
			if (only === undefined && m.parent !== undefined && m.deleted !== true && m.projectAgentId === undefined && liveById.has(m.projectId) && template !== undefined && template.projectId === undefined) {
				const copy = copyIn(m.projectId, template.id);
				if (copy !== undefined) fixesOf.set(m.projectId, [...(fixesOf.get(m.projectId) ?? []), { id, copy }]);
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
			fixes: [],
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
				fixes: [],
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
	for (const [projectId, fixes] of fixesOf) entryFor(liveById.get(projectId)!, projectKey.get(projectId)!, false).fixes.push(...fixes);

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
		.filter((entry) => entry.conversations.length > 0 || entry.notes.length > 0 || entry.fixes.length > 0)
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
export function pending(doc: ProjectsDoc["carry"], agents: Record<string, AgentProfile>): CarryOverState["secretsPending"] {
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
			subChatsPutRight: entry.fixes.length,
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

// ---- Schedules (3.13)

/**
 * The schedules on templates that carrying over gives a copy, each with that copy (3.13): the copy of its template in
 * the project of the template's folder, the one recorded for that project and template, or else the oldest agent of the
 * project made from it, neither removed nor deleted. No project or copy is made for a schedule: one with neither stays
 * on its template, and its run is carried as it is made (9.9), which makes them. A held schedule is left alone.
 */
export function scheduleCopies(
	schedules: Record<string, Schedule>,
	agents: Record<string, AgentProfile>,
	doc: ProjectsDoc,
	grouping: Grouping,
): { schedule: string; copy: string }[] {
	const live = Object.values(doc.projects).filter((project) => project.deletedAt === undefined);
	const keys = new Map(live.map((project) => [project.id, project.folder === null ? "none" : grouping.key(project.folder)]));
	const usable = (agent: AgentProfile | undefined) => agent !== undefined && agent.removedAt === undefined;
	const found: { schedule: string; copy: string }[] = [];
	for (const schedule of Object.values(schedules).sort((a, b) => a.createdAt - b.createdAt || (a.id < b.id ? -1 : 1))) {
		const template = agents[schedule.agentId];
		if (schedule.projectAgentId !== undefined || schedule.holdReason !== undefined || template === undefined || template.projectId !== undefined || template.removedAt !== undefined) continue;
		const project = lookUp(grouping.key(template.cwd ?? null), live, keys, doc.carry.folders)?.project;
		if (project === undefined) continue;
		const recorded = doc.carry.copies[`${project.id} ${template.id}`];
		// A copy recorded and since deleted or removed stays that way (9.5, 3): the schedule stays on its template.
		const copy = recorded !== undefined
			? (usable(agents[recorded]) ? agents[recorded] : undefined)
			: Object.values(agents).filter((agent) => agent.projectId === project.id && agent.template?.id === template.id && usable(agent)).sort(byMade)[0];
		if (copy !== undefined) found.push({ schedule: schedule.id, copy: copy.id });
	}
	return found;
}
