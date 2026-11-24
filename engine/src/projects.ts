// Projects (#450): the project itself and its requests (#456). Since #483 took the preview switch out, projects are the
// only way: carrying over runs by itself when the engine starts (carryover.ts).
//
// docs/projects.md is the contract this file builds, and its names and shapes are the contract's. A project is a
// document of its own (`pi2.projects`), with its orchestrator an ordinary agent in `pi2.agents` marked with the
// project's id, and its conversations ordinary conversations in `pi2.library` marked the same way. Nothing that exists
// is rewritten: carrying over only adds fields, so the last version with the switch can still read every document.
//
// The features that build on this file keep state of their own, made with each engine, and each imports this file. So
// what the `projects` event needs of them is handed in as each feature is made, through a `wire…` function, and the
// imports go one way (docs/projects.md, 12.1):
//
// - `carryOverState()`: what carrying over has done, from carryover.ts through `wireCarryOver`;
// - `ruleTokens(projectId)`: what the rules cost, from projectrules.ts through `wireRuleTokens`;
// - `lastWords(projectId)`: the orchestrator's last words, for the Dashboard, from orchestrator.ts through
//   `wireLastWords`, which also marks a new project's conversation for its state block through `wireFresh`.
//
// And `offeredFolder(folder)`, the second check of a folder a paired phone gives `projects.create` (the first is its
// device row in answers.ts), from folders.ts through `wireOfferedFolder`: without it, a phone's project has no folder.
//
// Without them (a stand-in engine in a test), `carryOver` is null, `ruleTokens` zeros and `lastWords` null. `news` is
// stored by `addNews`, from the commits of the features that tell of something, and delivered by orchestrator.ts.
// `requireSwitch` asks the person when a switch that is off governs a tool, whatever the agent's access.

import { randomUUID } from "node:crypto";
import { existsSync, realpathSync, statSync } from "node:fs";
import { basename } from "node:path";
import type { Context } from "@earendil-works/chord/context";
import { type CommitChange, defineDoc, type HookApi, type Tx } from "@earendil-works/pi-durable";
import type { Client } from "./clients.ts";
import type { Host } from "./extensions.ts";
import type { Feature } from "./features.ts";
import { Schedules } from "./schedules.ts";
import { type AgentProfile, Agents, Library } from "./state.ts";

// ---- Documents (contract, 3.2 and section 8)

/** The switches of 8.1: what the orchestrator may do without asking. */
export type SwitchName = "startAgents" | "fileWork" | "closeWork" | "makeAgents" | "addRules" | "merge" | "release" | "passLimits";
export const SWITCH_NAMES: readonly SwitchName[] = ["startAgents", "fileWork", "closeWork", "makeAgents", "addRules", "merge", "release", "passLimits"];

export type ProjectSettings = {
	/** The person's switch alone (8.2). */
	wakeOnReports: boolean;
	withoutAsking: Record<SwitchName, boolean>;
	limits: {
		/** Percent, 1 to 100: no start while a window of the plan the started agent would run on is this much used. Null: none. */
		planShare: number | null;
		/** Dollars: no start once the project's spending today reaches this. Null: none. */
		dailySpend: number | null;
	};
};

export type Project = {
	/** "p-" and a UUID. Never reused. */
	id: string;
	/** 1 to 80 characters, trimmed. Unique, ignoring case, among projects not deleted. */
	name: string;
	/** The real path of the project's folder, or null for a project with no folder. At most one project not deleted has a given folder. */
	folder: string | null;
	/** The GitHub repository attached, whose issues and pull requests are the work list (#468); null: the list is kept by pi². */
	repository: { owner: string; name: string } | null;
	/** The project agent that is its orchestrator: in `pi2.agents`, with this `projectId` and `role: "orchestrator"`. */
	orchestratorId: string;
	/**
	 * The orchestrator's conversation now. `projects.create` makes it, empty, with the project. Null when it was deleted, and
	 * in a project carrying over made with the default orchestrator until the person first opens or writes to it (the app
	 * makes it then with `projects.startFresh`, orchestrator.ts).
	 */
	conversation: number | null;
	/** Earlier conversations with the orchestrator, oldest first (Start fresh, #466). */
	earlier: number[];
	settings: ProjectSettings;
	createdAt: number;
	updatedAt: number;
	/** Archived by the person: out of the sidebar; nothing new starts in it (3.6). */
	archivedAt?: number;
	/** Deleted by the person: shown nowhere but the Archive (3.6). */
	deletedAt?: number;
	/** Made by carrying over, at this time (#458). */
	carriedAt?: number;
};

/** What carrying over has done (#458): empty on a data folder it has never changed. */
export type CarryRecord = {
	ranAt: number | null;
	backup: string | null;
	/**
	 * The copy of the data the update that took the switch out made at its first start, before changing anything (#715),
	 * whatever `backup` holds. `path` null: there was nothing to copy (no conversation, no project), and nothing was made.
	 * Absent until then, and in every document an older version wrote.
	 */
	removalBackup?: { path: string | null; at: number };
	folders: Record<string, string>;
	copies: Record<string, string>;
	notes: Record<string, { projectId: string; noteId: string } | "left">;
	secrets: { copyId: string; templateId: string; names: string[]; tries: number; lastError: string | null }[];
};

/** One thing the orchestrator has not been told yet (6.4). */
export type News = {
	/** "w" and a number from `nextNews`: each piece of news is told once, by its id. */
	id: string;
	at: number;
	kind: "report" | "message" | "change" | "work" | "limit" | "need";
	/** One line, as the catch-up shows it. */
	text: string;
	/** What it is about (a conversation, a need, a change, a work item), for the board to link to. Not unique. */
	ref: string;
	/** A message the person wrote to another agent: never dropped for room (6.4). */
	keep?: true;
};

export type ProjectsDoc = {
	projects: Record<string, Project>;
	carry: CarryRecord;
	/** By project id: what the orchestrator has not been told yet. Oldest first. */
	news: Record<string, News[]>;
	/** The next id of a piece of news, across all projects. */
	nextNews: number;
};

const emptyProjects = (): ProjectsDoc => ({
	projects: {},
	carry: { ranAt: null, backup: null, folders: {}, copies: {}, notes: {}, secrets: [] },
	news: {},
	nextNews: 1,
});

/**
 * The projects, the carrying-over record and the news. Made by the first commit that writes it: on a data folder an
 * older version left, the record of the update's copy of the data, at the first start (carryover.ts).
 */
export const Projects = defineDoc<ProjectsDoc>({
	kind: "pi2.projects",
	version: 1,
	scope: "session",
	initial: emptyProjects,
	checkpointWhen: () => true,
});

// ---- What the apps are sent (4.3)

export type ProjectRow = Project & {
	folderMissing: boolean;
	/** About how many tokens the rules add to each request: an orchestrator's, and every other agent's (6.2). */
	ruleTokens: { orchestrator: number; agents: number };
	/** The last line of the orchestrator's last finished answer, at most 200 characters, and when (orchestrator.ts). */
	lastWords: { text: string; at: number } | null;
};

export type CarryOverState = {
	ranAt: number | null;
	backup: string | null;
	/** The copy of the data the update made before carrying over (#715): the path as it is on disk. Null: none was made. */
	removalBackup: { path: string; at: number } | null;
	/** Why the update's copy of the data, or its carrying over, failed at this start; it is tried again at the next. */
	removalFailed: string | null;
	secretsPending: { copy: string; name: string; project: string; variables: string[]; error: string | null }[];
};

/** What carrying over would do, or did (9.8, carryover.ts). Without carryover.ts, always the empty report. */
export type CarryOverReport = {
	plan: string | null;
	projects: {
		key: string;
		name: string;
		existing: string | null;
		/** Found by its folder for a key the record does not send to it yet: recorded now (9.4). Not again once recorded. */
		adopted: boolean;
		archived: boolean;
		orchestrator: { conversation: number | null; title: string | null; template: string | null } | null;
		copies: { template: string; name: string; existing: string | null; allowEverything: boolean; variables: string[]; worktreeOff: boolean; folder: string | null }[];
		conversations: number;
		archivedConversations: number;
		subChats: number;
		/** Sub-chats in the project already that ran as the template, given the project's copy now (#715). */
		subChatsPutRight: number;
		notes: number;
		/** Lines the person should read: a repository gone, a bare repository's worktrees each a project (9.2). */
		notices: string[];
	}[];
	leftOut: { chats: number; deleted: number; deletedProject: number; notesLeft: number };
	already: number;
	ranAt: number | null;
	backup: string | null;
	secretsPending: CarryOverState["secretsPending"];
};

// ---- Starts and limits (8.3)

/** Who asked for something: the person (through the app), or an agent in one of its conversations (7.3). */
export type Who = { kind: "person" } | { kind: "agent"; agentId: string; conversationId: number };

/** Everything needed to make one start, as it was asked for: kept whole on a limit card, so allowing it makes exactly this. */
export type Start = {
	by: Who;
	agentId: string;
	agentName: string;
	kind: "new" | "continue" | "assign" | "conversation";
	/** The parent conversation for a sub-chat; the sub-chat continued; the work item assigned. */
	parent: number | null;
	chat: number | null;
	work: number | null;
	title: string | null;
	task: string;
	/** What `delegate` was given beyond the task, as given: worktree, from, wait. */
	options: Record<string, unknown>;
};

/** What was over, when it was read. Its `id` names this limit and reading, for a one-shot confirmation. */
export type LimitReading = { id: string; limit: "planShare" | "dailySpend"; reason: string; provider: string | null; window: string | null; used: number; max: number; resetsAt: number | null };

// ---- Words the person and agents read

/** A request that would change an archived project, or start something in it (4.1, 3.6). */
export const PROJECT_ARCHIVED = "This project is archived. Restore it first.";
export const PROJECT_DELETED = "This agent’s project was deleted. Choose another agent.";
/** Archiving or deleting a project while something of it works or waits (3.6). */
const STOP_FIRST = "Stop the project's agents first.";
/** What a tool is told when the person denies what a switch that is off asked about. */
const SWITCH_DECLINED = "The person declined this action. Do not retry it; ask what they would like instead.";
/** The most characters a project's name may have. */
export const MAX_PROJECT_NAME = 80;

/** The orchestrator's instructions, in full (3.3). */
export const ORCHESTRATOR_INSTRUCTIONS =
	"You are the orchestrator of this project. The person talks to you. Plan the work with them, hand each piece to one of the project's agents with `delegate` or `work` (`assign`), review what comes back, and report plainly what was done and what was not. Keep the project's work list up to date. When a decision is the person's, put it to them with `needs_you` and carry on with what does not depend on it. If the project has no agent suited to a piece of work, make one with `project_agents`.";

/**
 * The default orchestrator (3.3): a template that is not stored, like chat mode's assistant in chat.ts. A project made
 * without naming a template gets a copy of it, an ordinary project agent from then on. Every setting not named is a new
 * agent's default, as `agents.save` gives it; `memory` is the memory switch, kept outside the profile (knowledge.ts).
 */
export const DEFAULT_ORCHESTRATOR: Readonly<Omit<AgentProfile, "id" | "cwd" | "createdAt">> & { memory: true } = {
	name: "Orchestrator",
	description: "",
	color: "violet",
	model: null,
	thinkingLevel: null,
	instructions: ORCHESTRATOR_INSTRUCTIONS,
	access: "ask",
	worktree: false,
	setup: "",
	delegates: [],
	maxTurns: null,
	codeMode: false,
	mcpServers: [],
	files: [],
	computer: { enabled: false, apps: [], ask: true, testCopies: false },
	browser: { enabled: false, ask: true },
	schedule: { enabled: false },
	toolsOff: [],
	// "Summarise its own conversation" (builtins.ts), off for a new agent.
	toolsOn: ["compact"],
	compactionTokens: 100_000,
	commandRules: [],
	memory: true,
};

/** A new project's settings, or a carried-over one's (8.1 to 8.3). */
export function defaultProjectSettings(made: "new" | "carried"): ProjectSettings {
	return {
		wakeOnReports: made === "carried",
		withoutAsking: { startAgents: true, fileWork: true, closeWork: true, makeAgents: true, addRules: true, merge: false, release: false, passLimits: false },
		limits: { planShare: made === "new" ? 90 : null, dailySpend: null },
	};
}

// ---- What every piece of the epic asks

/** The `pi2.projects` document as last stored. Read again after every commit that changes it, by anyone. */
let current: ProjectsDoc = emptyProjects();
/** The engine's host, for the conversations and the Inbox. Set as the engine makes the feature. */
let wired: Host | undefined;

/** The projects as last stored, deleted ones included. A plain copy: change them only through a commit. */
export function allProjects(): Record<string, Project> {
	return structuredClone(current.projects);
}

/**
 * The project conversation `conversation` belongs to, whether the project is archived or not. If the project was deleted, only a conversation whose own agent belongs to it
 * still belongs to it. A carried conversation falls back to its template and is in no project (3.6).
 */
export function projectOf(conversation: number): Project | undefined {
	const meta = wired?.conversations()[String(conversation)];
	const project = meta?.projectId === undefined ? undefined : current.projects[meta.projectId];
	if (project?.deletedAt !== undefined && wired?.agent(meta?.agentId)?.projectId !== project.id) return undefined;
	return project;
}

/**
 * Whether project `projectId` was deleted, as last stored (3.6). False for undefined, and
 * for a project not stored (a stand-in engine's).
 */
export function projectDeleted(projectId: string | undefined): boolean {
	return projectId !== undefined && current.projects[projectId]?.deletedAt !== undefined;
}

/**
 * The project conversation `conversation` is in, for what it is told and offered: only a project neither archived nor
 * deleted. Undefined for every other conversation (a chat, a deleted project's carried one), which is then told exactly
 * what a conversation in no project is told.
 */
export function inProject(conversation: number): Project | undefined {
	const project = projectOf(conversation);
	if (project === undefined || project.archivedAt !== undefined || project.deletedAt !== undefined) return undefined;
	return project;
}

/** Refuses a message to a conversation of an archived project (3.6). */
export function refuseInArchivedProject(conversation: number): void {
	const project = projectOf(conversation);
	if (project !== undefined && project.deletedAt === undefined && project.archivedAt !== undefined) throw new Error(PROJECT_ARCHIVED);
}

/** No starts with agents of deleted projects, or archived projects (3.6). */
export function startWithRefusal(agent: AgentProfile, projects = current.projects): string | undefined {
	const project = agent.projectId === undefined ? undefined : projects[agent.projectId];
	if (project?.deletedAt !== undefined) return PROJECT_DELETED;
	if (project?.archivedAt !== undefined) return PROJECT_ARCHIVED;
	return undefined;
}

export function refuseStartWith(agent: AgentProfile, projects = current.projects): void {
	const reason = startWithRefusal(agent, projects);
	if (reason !== undefined) throw new Error(reason);
}

/** A tool call that a switch governs, as `requireSwitch` asks about it: the same fields as any approval. */
export type SwitchAsk = {
	conversationId: number;
	/** The Inbox item's id: the tool task's, `String(api.taskId)`, as every approval's. */
	id: string;
	callId: string;
	tool: string;
	arguments: unknown;
	api: Pick<HookApi, "memo">;
	context: Context;
};

/**
 * The one helper every tool a switch governs calls (8.1), before it does what the switch is about. In a conversation of
 * a project whose switch `name` is off, it asks the person through the Inbox, as an approval that offers only Allow
 * Once and Deny and that Allow everything does not answer (`projectSwitch`, decision 17), and says `what` as the
 * question. Anywhere else, or with the switch on, it asks nothing. It holds in an archived project too, whose
 * conversations cannot start anything anyway.
 */
export async function requireSwitch(conversation: SwitchAsk, name: SwitchName, what: string): Promise<{ ok: true } | { ok: false; reason: string }> {
	const project = projectOf(conversation.conversationId);
	if (project === undefined || project.settings.withoutAsking[name]) return { ok: true };
	if (wired === undefined) throw new Error("The projects feature is not running");
	const answer = await wired.inbox.ask(
		{
			id: conversation.id,
			kind: "approval",
			conversationId: conversation.conversationId,
			callId: conversation.callId,
			tool: conversation.tool,
			arguments: conversation.arguments,
			question: what,
			projectSwitch: name,
			createdAt: Date.now(),
		},
		conversation.api,
		conversation.context,
	);
	// Only Allow Once and Deny are offered; anything but Allow Once counts as no.
	return answer === "once" ? { ok: true } : { ok: false, reason: SWITCH_DECLINED };
}

export { admit } from "./projectlimits.ts";

/**
 * Store one piece of news for project `projectId`'s orchestrator, in the commit `tx` that makes what it tells of (6.4).
 * orchestrator.ts (#466) delivers it in the catch-up. The project must exist; one deleted takes news too, which nobody
 * is told.
 */
export async function addNews(tx: Tx, projectId: string, news: { kind: News["kind"]; text: string; ref: string; keep?: true; at?: number }): Promise<News> {
	const doc = await tx.doc(Projects);
	if (doc.projects[projectId] === undefined) throw new Error(`Unknown project: ${projectId}`);
	const item: News = { id: `w${doc.nextNews}`, at: news.at ?? Date.now(), kind: news.kind, text: news.text, ref: news.ref, ...(news.keep === true ? { keep: true as const } : {}) };
	doc.nextNews += 1;
	doc.news[projectId] = [...(doc.news[projectId] ?? []), item];
	return item;
}

// ---- What other features wire in

/** What carryover.ts gives this file: the event's `carryOver`. */
export type CarryOverParts = {
	state(): CarryOverState | null;
};
let carrying: CarryOverParts | undefined;

/** carryover.ts wires carrying over in as its feature is made; answers what tells the apps the `projects` event again. */
export function wireCarryOver(parts: CarryOverParts): () => void {
	carrying = parts;
	return () => announceProjects();
}

/** What carrying over has done, as last stored: a plain copy (carryover.ts). */
export function carryRecord(): CarryRecord {
	return structuredClone(current.carry);
}

/** The `projects` event's `carryOver`: null while nothing was ever carried over (carryover.ts). */
export function carryOverState(): CarryOverState | null {
	return carrying?.state() ?? null;
}

let countRuleTokens = (_projectId: string): ProjectRow["ruleTokens"] => ({ orchestrator: 0, agents: 0 });
let announceProjects = () => {};

/** About how many tokens a project's rules add to each request (6.2). */
export function ruleTokens(projectId: string): ProjectRow["ruleTokens"] {
	return countRuleTokens(projectId);
}

/** The rules feature supplies the estimate and tells us when to check it again, without writing `pi2.projects`. */
export function wireRuleTokens(count: typeof countRuleTokens): () => void {
	countRuleTokens = count;
	return announceProjects;
}

let findLastWords = (_projectId: string): ProjectRow["lastWords"] => null;

/** The last line of the project's orchestrator's last finished answer (4.3), as orchestrator.ts (#466) keeps it. */
export function lastWords(projectId: string): { text: string; at: number } | null {
	return findLastWords(projectId);
}

/** orchestrator.ts supplies the last words, and is given what sends the `projects` event again when they change. */
export function wireLastWords(find: typeof findLastWords): () => void {
	findLastWords = find;
	return () => announceProjects();
}

let markFresh = async (_tx: Tx, _conversation: number): Promise<void> => {};

/**
 * orchestrator.ts (#466) marks a new conversation with the orchestrator, in the commit that makes it, so that its first
 * input begins with the state block (6.4). `projects.create` calls it for the project's first conversation.
 */
export function wireFresh(mark: typeof markFresh): void {
	markFresh = mark;
}

/**
 * The folder a paired phone may make a project from (docs/iphone.md 4.2, #698), checked again as it is made: one
 * `projects.folders` offers at that moment, by its exact text (folders.ts). The device row in answers.ts has already
 * refused any other. Until folders.ts wires it, none.
 */
let offeredFolder = async (value: unknown): Promise<string | null> => {
	if (value === null) return null;
	throw new Error("A new project's folder is chosen on the Mac.");
};

export function wireOfferedFolder(check: typeof offeredFolder): void {
	offeredFolder = check;
}

let reloadNow = async (): Promise<void> => {};

/** Read the document again now, after a commit made elsewhere (Start fresh, orchestrator.ts), and tell the apps. */
export function reloadProjects(): Promise<void> {
	return reloadNow();
}

// ---- Checking what a request gives

const isFolder = (path: string) => existsSync(path) && statSync(path).isDirectory();

/** A project's folder, stored by its real path, or null for none. */
export function checkFolder(value: unknown): string | null {
	if (value === null) return null;
	if (typeof value !== "string" || value.trim() === "") throw new Error("folder must be a folder's path, or null");
	if (!isFolder(value)) throw new Error(`Not a folder: ${value}`);
	// macOS's own real path, with the case the disk has, as carrying over keys folders (9.2).
	return realpathSync.native(value);
}

/** A project's name, as given: trimmed, one line, 1 to 80 characters. */
function checkName(value: unknown): string {
	if (typeof value !== "string" || value.trim() === "") throw new Error("Give the project a name");
	const name = value.trim();
	// biome-ignore lint/suspicious/noControlCharactersInRegex: control characters are what is refused
	if (/[\u0000-\u001f\u007f\u2028\u2029]/.test(name)) throw new Error("A project's name must be a single line");
	if (name.length > MAX_PROJECT_NAME) throw new Error(`A project's name can be ${MAX_PROJECT_NAME} characters at most; this one is ${name.length}`);
	return name;
}

const projectId = (params: Record<string, unknown>): string => {
	if (typeof params.id !== "string") throw new Error("id must be a project's id");
	return params.id;
};

/** A project that exists and was not deleted, in the document being changed. */
function live(doc: ProjectsDoc, id: string): Project {
	const project = doc.projects[id];
	if (project === undefined || project.deletedAt !== undefined) throw new Error(`Unknown project: ${id}`);
	return project;
}

/** The project not deleted, other than `except`, that has `name` already, ignoring case. */
function named(doc: ProjectsDoc, name: string, except?: string): Project | undefined {
	return Object.values(doc.projects).find((project) => project.id !== except && project.deletedAt === undefined && project.name.toLowerCase() === name.toLowerCase());
}

/** The project not deleted, other than `except`, whose folder `folder` is. */
function ofFolder(doc: ProjectsDoc, folder: string, except?: string): Project | undefined {
	return Object.values(doc.projects).find((project) => project.id !== except && project.deletedAt === undefined && project.folder === folder);
}

/** The settings with what `given` changes, each part checked; the parts not given are kept. */
export function changeProjectSettings(settings: ProjectSettings, given: unknown): ProjectSettings {
	const isObject = (value: unknown): value is Record<string, unknown> => typeof value === "object" && value !== null && !Array.isArray(value);
	if (!isObject(given)) throw new Error("settings must be an object");
	const next: ProjectSettings = JSON.parse(JSON.stringify(settings));
	for (const [key, value] of Object.entries(given)) {
		if (key === "wakeOnReports") {
			if (typeof value !== "boolean") throw new Error("wakeOnReports must be true or false");
			next.wakeOnReports = value;
		} else if (key === "withoutAsking") {
			if (!isObject(value)) throw new Error("withoutAsking must be an object of switches");
			for (const [name, on] of Object.entries(value)) {
				if (!SWITCH_NAMES.includes(name as SwitchName)) throw new Error(`Unknown switch: ${name}`);
				if (typeof on !== "boolean") throw new Error(`${name} must be true or false`);
				next.withoutAsking[name as SwitchName] = on;
			}
		} else if (key === "limits") {
			if (!isObject(value)) throw new Error("limits must be an object");
			for (const [name, limit] of Object.entries(value)) {
				if (name === "planShare") {
					if (limit !== null && !(Number.isInteger(limit) && (limit as number) >= 1 && (limit as number) <= 100)) throw new Error("planShare must be a whole number from 1 to 100, or null");
					next.limits.planShare = limit as number | null;
				} else if (name === "dailySpend") {
					if (limit !== null && !(typeof limit === "number" && Number.isFinite(limit) && limit > 0)) throw new Error("dailySpend must be an amount above zero, or null");
					next.limits.dailySpend = limit as number | null;
				} else throw new Error(`Unknown limit: ${name}`);
			}
		} else throw new Error(`Unknown setting: ${key}`);
	}
	return next;
}

/**
 * Rename project `id`, change its folder or any part of its settings, in the commit `tx`, each checked: what
 * `projects.rename` and `projects.set` do, and the operation `project.change` an agent's change applies (changes.ts),
 * so neither can do what the other could not. `folder` is checked already (`checkFolder`). Answers the settings now.
 */
export async function applyProjectChange(tx: Tx, id: string, given: { name?: string; folder?: string | null; settings?: unknown }): Promise<ProjectSettings> {
	const doc = await tx.doc(Projects);
	const project = live(doc, id);
	if (project.archivedAt !== undefined) throw new Error(PROJECT_ARCHIVED);
	if (given.name !== undefined) {
		const name = checkName(given.name);
		if (named(doc, name, id) !== undefined) throw new Error(`There is already a project called ${name}`);
		project.name = name;
	}
	if (given.folder !== undefined && given.folder !== project.folder) {
		const folder = given.folder;
		const same = folder === null ? undefined : ofFolder(doc, folder, id);
		if (same !== undefined) throw new Error(`There is already a project for this folder: ${same.name}${same.archivedAt !== undefined ? "; restore it instead" : ""}`);
		if (folder === null && project.repository !== null) throw new Error("A project with a repository attached needs a folder. Detach the repository first.");
		project.folder = folder;
		// Every agent of the project works in its folder (3.3): the engine sets it, never `agents.save`.
		for (const agent of Object.values((await tx.doc(Agents)).agents)) if (agent.projectId === id) agent.cwd = folder;
	}
	if (given.settings !== undefined) project.settings = changeProjectSettings(project.settings, given.settings);
	project.updatedAt = Date.now();
	return JSON.parse(JSON.stringify(project.settings)) as ProjectSettings;
}

/** An agent's id as made for a project: its name's slug and a UUID, never reused, whatever is deleted later. */
const agentIdFor = (name: string) => `${name.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "") || "agent"}-${randomUUID()}`;

// ---- The feature

export const projects: Feature = (host, engine) => {
	wired = host;
	/** The last `projects` event broadcast, so that a change that changes nothing in it sends none (4.3). */
	let sent = "";
	/** Counts reads of the document, so a slow read never replaces a later one's. */
	let reads = 0;

	const projectsEvent = () => ({
		event: "projects" as const,
		projects: Object.values(current.projects)
			.sort((a, b) => a.createdAt - b.createdAt)
			.map(
				(project): ProjectRow => ({
					...structuredClone(project),
					folderMissing: project.folder !== null && !isFolder(project.folder),
					ruleTokens: ruleTokens(project.id),
					lastWords: lastWords(project.id),
				}),
			),
		carryOver: carryOverState(),
	});
	const announce = () => {
		const event = projectsEvent();
		const line = JSON.stringify(event);
		if (line === sent) return;
		sent = line;
		engine.broadcast(event);
	};
	announceProjects = announce;
	/** Read the document again, as stored, and tell the apps if what they are sent changed. */
	const reload = async () => {
		const read = ++reads;
		const stored = await engine.harness().snapshot(Projects, engine.context());
		if (read !== reads) return;
		current = stored === undefined ? emptyProjects() : JSON.parse(JSON.stringify(stored));
		announce();
	};
	reloadNow = reload;
	/** Change the document in one commit, and have the change read back before the request answers. */
	const change = async <T>(edit: (doc: ProjectsDoc, tx: Tx) => Promise<T> | T): Promise<T> => {
		const value = await engine.harness().commit(async (tx) => edit(await tx.doc(Projects), tx), engine.context());
		await reload();
		return value;
	};
	/** Whether a conversation of project `id`, a sub-chat included, is working or waiting on the person. */
	const busy = (id: string) => {
		const waiting = new Set(host.inbox.list().map((item) => item.conversationId));
		return Object.entries(host.conversations()).some(([conversation, meta]) => meta.projectId === id && meta.deleted !== true && (host.working(Number(conversation)) || waiting.has(Number(conversation))));
	};
	const lifecycle = (id: string, edit: (project: Project, now: number) => void) =>
		change((doc) => {
			const project = live(doc, id);
			edit(project, Date.now());
		});
	/** The template a project's orchestrator is copied from: an agent of no project, not removed. */
	const templateOf = (value: unknown): AgentProfile => {
		const template = typeof value === "string" ? engine.agents()[value] : undefined;
		if (template === undefined || template.projectId !== undefined || template.removedAt !== undefined) throw new Error(`Unknown agent: ${String(value)}`);
		return template;
	};

	return {
		start: async () => {
			await reload();
			// A commit by anyone that changes the document (news added in another feature's commit, say) is read back.
			engine.harness().observeCommits({
				advance: ({ changes }) => {
					const touched = changes.some((one: CommitChange) => (one.type === "document" || one.type === "document.copy") && one.record.kind === "pi2.projects");
					if (touched) void reload().catch((error) => engine.log("could not read the projects again:", error instanceof Error ? error.message : error));
				},
				end: () => {},
			});
		},
		greeting: () => [projectsEvent()],
		// The person deleted a conversation (3.6): if it was a project's orchestrator's current one, the project has none now,
		// and an earlier one leaves `earlier`. Archiving one changes nothing in the project.
		putAwayChanged: () => {
			const conversations = host.conversations();
			const gone = (id: number) => conversations[String(id)]?.deleted === true;
			const stale = (project: Project) => (project.conversation !== null && gone(project.conversation)) || project.earlier.some(gone);
			if (!Object.values(current.projects).some(stale)) return;
			void change((doc) => {
				for (const project of Object.values(doc.projects)) {
					if (!stale(project)) continue;
					if (project.conversation !== null && gone(project.conversation)) project.conversation = null;
					project.earlier = project.earlier.filter((id) => !gone(id));
					project.updatedAt = Date.now();
				}
			}).catch((error) => engine.log("could not note a deleted conversation in its project:", error instanceof Error ? error.message : error));
		},
		handlers: {
			/** `{}`: exactly the `projects` event's content, for a script that does not read events. */
			"projects.list": async () => {
				const { event: _, ...content } = projectsEvent();
				return content;
			},
			/**
			 * `{ folder, name?, template? }`: a project from a folder (or null) in one step, with its orchestrator and an empty
			 * conversation with it, in one commit. The orchestrator is a copy of `template`, else of the default orchestrator.
			 */
			"projects.create": async (params, connection) => {
				if (!("folder" in params)) throw new Error("folder must be a folder's path, or null");
				// From a paired phone, only a folder the Mac offers it (folders.ts); the app chooses any in its own panel.
				const folder = (connection as Client | undefined)?.device !== undefined ? await offeredFolder(params.folder) : checkFolder(params.folder);
				const given = params.name === undefined || params.name === null ? undefined : checkName(params.name);
				const template = params.template === undefined || params.template === null ? undefined : templateOf(params.template);
				const now = Date.now();
				const id = `p-${randomUUID()}`;
				let agent: AgentProfile;
				if (template === undefined) {
					const { memory: _, ...settings } = DEFAULT_ORCHESTRATOR;
					agent = { ...structuredClone(settings), id: agentIdFor(settings.name), cwd: folder, createdAt: now };
				} else {
					// As `agents.duplicate` copies an agent (3.3), but into the project: its folder, no `delegates` (the project has no
					// copies to map them to yet), every allowed command, and neither Allow everything nor the variables' values. The
					// variables' names and the memory switch are copied below, by the features that keep them.
					agent = structuredClone(template);
					delete agent.allowEverything;
					delete agent.variables;
					delete agent.madeBy;
					delete agent.removedAt;
					agent.id = agentIdFor(template.name);
					agent.cwd = folder;
					agent.delegates = [];
					agent.createdAt = now;
					agent.template = { id: template.id, copiedAt: now, templateUpdatedAt: template.updatedAt ?? template.createdAt };
				}
				agent.projectId = id;
				agent.role = "orchestrator";
				agent.updatedAt = now;
				const configured = await host.agentChange(agent, { subChat: false });
				const created = await engine.harness().createConversation(
					{
						ownership: { kind: "ownerless" },
						agent: configured,
						init: async (tx, conversation) => {
							const doc = await tx.doc(Projects);
							if (folder !== null) {
								const same = ofFolder(doc, folder);
								if (same !== undefined) throw new Error(`There is already a project for this folder: ${same.name}${same.archivedAt !== undefined ? "; restore it instead" : ""}`);
							}
							let name = given ?? "";
							if (given !== undefined) {
								if (named(doc, given) !== undefined) throw new Error(`There is already a project called ${given}`);
							} else {
								const base = folder === null ? "No folder" : basename(folder).trim() || folder;
								for (let n = 1; name === "" || named(doc, name) !== undefined; n++) {
									const suffix = n === 1 ? "" : ` ${n}`;
									name = `${base.slice(0, MAX_PROJECT_NAME - suffix.length).trim()}${suffix}`;
								}
							}
							(await tx.doc(Agents)).agents[agent.id] = agent;
							doc.projects[id] = {
								id,
								name,
								folder,
								repository: null,
								orchestratorId: agent.id,
								conversation: conversation as unknown as number,
								earlier: [],
								settings: defaultProjectSettings("new"),
								createdAt: now,
								updatedAt: now,
							};
							// It begins with the state block (6.4).
							await markFresh(tx, conversation as unknown as number);
							(await tx.doc(Library)).conversations[String(conversation)] = { title: "", createdAt: now, updatedAt: now, access: agent.access, agentId: agent.id, projectId: id };
						},
					},
					engine.context(),
				);
				await reload();
				const conversation = created.id as unknown as number;
				// What features keep for an agent outside its profile, as for a duplicate, or as the default orchestrator has it;
				// then what they do for a conversation the person starts with it. The project is made by now, whatever fails here.
				for (const feature of host.features) {
					try {
						if (template !== undefined) await feature.agentDuplicated?.(template.id, agent.id);
						else await feature.agentMade?.(agent.id, { memory: DEFAULT_ORCHESTRATOR.memory });
						await feature.created?.(conversation, agent);
					} catch (error) {
						engine.log("project", id, "was made, but a feature could not set up its orchestrator:", error instanceof Error ? error.message : error);
					}
				}
				return { id, conversation };
			},
			/** `{ id, name }`: refuses an empty name, one over 80 characters, or one taken. */
			"projects.rename": async (params) => {
				const id = projectId(params);
				const name = checkName(params.name);
				await change((_doc, tx) => applyProjectChange(tx, id, { name }));
				return {};
			},
			/**
			 * `{ id, folder?, settings? }`: the folder, where new conversations of its agents start (those working stay where
			 * they are), and any part of the settings, each checked; what is not given is kept.
			 */
			"projects.set": async (params) => {
				const id = projectId(params);
				const folder = params.folder === undefined ? undefined : checkFolder(params.folder);
				const settings = await change((_doc, tx) => applyProjectChange(tx, id, { ...(folder === undefined ? {} : { folder }), ...(params.settings === undefined ? {} : { settings: params.settings }) }));
				return { settings };
			},
			/** `{ id }`: out of the sidebar; no conversation's own state changes (3.6). */
			"projects.archive": async (params) => {
				const id = projectId(params);
				live(current, id);
				if (busy(id)) throw new Error(STOP_FIRST);
				await lifecycle(id, (project, now) => {
					if (project.archivedAt !== undefined) return;
					project.archivedAt = now;
					project.updatedAt = now;
				});
				return {};
			},
			"projects.unarchive": async (params) => {
				const id = projectId(params);
				await lifecycle(id, (project, now) => {
					if (project.archivedAt === undefined) return;
					delete project.archivedAt;
					project.updatedAt = now;
				});
				return {};
			},
			/** `{ id }`: shown only in the Archive; its folder and name are free again (3.6). */
			"projects.delete": async (params) => {
				const id = projectId(params);
				live(current, id);
				if (busy(id)) throw new Error(STOP_FIRST);
				const held = await change(async (doc, tx) => {
					const project = live(doc, id);
					project.deletedAt = project.updatedAt = Date.now();
					const { agents } = await tx.doc(Agents);
					const { schedules } = await tx.doc(Schedules);
					const held: string[] = [];
					for (const schedule of Object.values(schedules)) {
						if (agents[schedule.agentId]?.projectId !== id) continue;
						schedule.holdReason = PROJECT_DELETED;
						held.push(schedule.id);
					}
					return held;
				});
				for (const schedule of held) engine.log("schedule", schedule, "held:", PROJECT_DELETED);
				// Carried conversations now run as their templates, without any change to the Library document.
				engine.libraryChanged();
				engine.activityChanged();
				return {};
			},
		},
	};
};
