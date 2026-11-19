// Projects (#450): the project itself, its requests, and the preview switch that turns projects on (#456).
//
// docs/projects.md is the contract this file builds, and its names and shapes are the contract's. A project is a
// document of its own (`pi2.projects`), with its orchestrator an ordinary agent in `pi2.agents` marked with the
// project's id, and its conversations ordinary conversations in `pi2.library` marked the same way. Nothing that exists
// is rewritten: with the preview off, every request that exists today works as today, and only the requests new in the
// epic are refused (section 2).
//
// Several later issues are built on this file side by side. What each fills in later has a place here, marked with the
// issue that fills it, and does what the contract's 12.1 says until then:
//
// - `onPreviewOn(plan)`: carrying over when the preview is turned on (#458). Until then it carries nothing over.
// - `carryOverState()`: the `projects` event's `carryOver` (#458). Null until then.
// - `lastWords(projectId)`: the orchestrator's last words, for the Dashboard: orchestrator.ts (#466) supplies them
//   through `wireLastWords`, and marks a new project's conversation for its state block through `wireFresh`.
// - `news`: stored by `addNews` (#463, #464, #465 and #467 add to it), delivered by orchestrator.ts (#466).
// - `requireSwitch` is whole: a switch that is off asks the person, whatever the agent's access (#457, #465, #467 and
//   #468 call it from their tools).
// - Each project feature after this one (#459, #462, #463, #467, #468) adds itself in its place in `FEATURES`.

import { randomUUID } from "node:crypto";
import { existsSync, realpathSync, statSync } from "node:fs";
import { basename } from "node:path";
import type { Context } from "@earendil-works/chord/context";
import { type CommitChange, defineDoc, type HookApi, type Tx } from "@earendil-works/pi-durable";
import type { Host } from "./extensions.ts";
import type { Feature } from "./features.ts";
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
	/** The orchestrator's conversation now. `projects.create` makes it, empty, with the project. Null only when it was deleted. */
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

/** What carrying over has done (#458). Empty until it lands. */
export type CarryRecord = {
	ranAt: number | null;
	backup: string | null;
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
 * The projects, the carrying-over record and the news. Made by the first commit that writes it, never at start: with the
 * preview never turned on, nothing new is written (section 2).
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
	secretsPending: { copy: string; name: string; project: string; variables: string[]; error: string | null }[];
};

/** What carrying over would do, or did (9.8). Built by #458; until then, always the empty report. */
export type CarryOverReport = {
	plan: string | null;
	projects: {
		key: string;
		name: string;
		existing: string | null;
		adopted: boolean;
		archived: boolean;
		orchestrator: { conversation: number | null; title: string | null; template: string | null } | null;
		copies: { template: string; name: string; existing: string | null; allowEverything: boolean; variables: string[]; folder: string | null }[];
		conversations: number;
		archivedConversations: number;
		subChats: number;
		notes: number;
	}[];
	leftOut: { chats: number; deleted: number; notesLeft: number };
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

/** The refusal of every request new in the epic while the preview is off (section 2). */
export const PREVIEW_OFF = "Projects are a preview. Turn them on in Settings › General first.";
/** A request that would change an archived project, or start something in it (4.1, 3.6). */
export const PROJECT_ARCHIVED = "This project is archived. Restore it first.";
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

/** Whether the preview is on: `projects.preview` in settings.json, absent meaning off. */
let preview = false;
/** The `pi2.projects` document as last stored. Read again after every commit that changes it, by anyone. */
let current: ProjectsDoc = emptyProjects();
/** The engine's host, for the conversations and the Inbox. Set as the engine makes the feature. */
let wired: Host | undefined;

/** Whether the preview is on. Every piece of the epic asks this, and nothing else, whether projects are on. */
export function projectsOn(): boolean {
	return preview;
}

/** The projects as last stored, deleted ones included. A plain copy: change them only through a commit. */
export function allProjects(): Record<string, Project> {
	return structuredClone(current.projects);
}

/**
 * The project conversation `conversation` belongs to, whatever the preview and whether the project is archived or
 * deleted: for what holds with the preview off too, a project's limits and its `startAgents` switch (section 2).
 */
export function projectOf(conversation: number): Project | undefined {
	const projectId = wired?.conversations()[String(conversation)]?.projectId;
	return projectId === undefined ? undefined : current.projects[projectId];
}

/**
 * The project conversation `conversation` is in, for what it is told and offered: only with the preview on, and only a
 * project neither archived nor deleted. Undefined for every other conversation, which is then told exactly what it is
 * told today.
 */
export function inProject(conversation: number): Project | undefined {
	const project = projectOf(conversation);
	if (!preview || project === undefined || project.archivedAt !== undefined || project.deletedAt !== undefined) return undefined;
	return project;
}

/** Refuses a request new in the epic while the preview is off, with the one message section 2 gives. */
export function requirePreview(): void {
	if (!preview) throw new Error(PREVIEW_OFF);
}

/**
 * Refuses a message to a conversation of an archived project, with the preview on (3.6). With it off, every conversation
 * works as today.
 */
export function refuseInArchivedProject(conversation: number): void {
	const project = projectOf(conversation);
	if (preview && project !== undefined && project.deletedAt === undefined && project.archivedAt !== undefined) throw new Error(PROJECT_ARCHIVED);
}

/** Refuses a new conversation with `agent` when it is an agent of an archived project, with the preview on (3.6). */
export function refuseStartWith(agent: AgentProfile): void {
	const project = agent.projectId === undefined ? undefined : current.projects[agent.projectId];
	if (preview && project !== undefined && project.deletedAt === undefined && project.archivedAt !== undefined) throw new Error(PROJECT_ARCHIVED);
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
 * question. Anywhere else, or with the switch on, it asks nothing. It holds with the preview off too: `startAgents`
 * still holds for a project's conversations then (section 2), and the other switches govern tools not offered then.
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

// ---- The places later issues fill in

/**
 * Carrying over, when the preview is turned on (9.8). #458 fills this in: work the plan out again, refuse when it is not
 * `plan` ("What would be carried over has changed since you looked. Look at it again."), run it, and answer its report.
 * Until then nothing is carried over, and the report is empty.
 */
export async function onPreviewOn(_plan: string | null): Promise<CarryOverReport> {
	return emptyReport();
}

/** The report of a run with nothing to do (9.8). */
export function emptyReport(): CarryOverReport {
	return { plan: null, projects: [], leftOut: { chats: 0, deleted: 0, notesLeft: 0 }, already: 0, ranAt: current.carry.ranAt, backup: current.carry.backup, secretsPending: [] };
}

/** The `projects` event's `carryOver`: null while nothing was ever carried over. #458 fills it in. */
export function carryOverState(): CarryOverState | null {
	return null;
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

let reloadNow = async (): Promise<void> => {};

/** Read the document again now, after a commit made elsewhere (Start fresh, orchestrator.ts), and tell the apps. */
export function reloadProjects(): Promise<void> {
	return reloadNow();
}

// ---- Checking what a request gives

const isFolder = (path: string) => existsSync(path) && statSync(path).isDirectory();

/** A project's folder, stored by its real path, or null for none. */
function checkFolder(value: unknown): string | null {
	if (value === null) return null;
	if (typeof value !== "string" || value.trim() === "") throw new Error("folder must be a folder's path, or null");
	if (!isFolder(value)) throw new Error(`Not a folder: ${value}`);
	return realpathSync(value);
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
		preview,
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
			const stored = engine.setting("projects") as { preview?: unknown } | undefined;
			preview = stored?.preview === true;
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
		// Sent whether the preview is on or not, so that turning it on shows everything at once (4.4).
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
			/** `{}`: exactly the `projects` event's content, for a script that does not read events. Allowed with the preview off. */
			"projects.list": async () => {
				const { event: _, ...content } = projectsEvent();
				return content;
			},
			/**
			 * `{ on, plan? }`: the preview on or off, counting for each conversation from its next message. On, carrying over
			 * runs first (#458, through `onPreviewOn`), and turns nothing on if it refuses. Allowed with the preview off.
			 */
			"projects.setPreview": async (params) => {
				if (typeof params.on !== "boolean") throw new Error("on must be true or false");
				if (params.plan !== undefined && params.plan !== null && typeof params.plan !== "string") throw new Error("plan must be the plan of the report you were shown");
				const on = params.on;
				const carryOver = on ? await onPreviewOn((params.plan as string | null | undefined) ?? null) : null;
				preview = on;
				engine.saveSetting("projects", { preview: on });
				engine.log(`projects preview ${on ? "on" : "off"}`);
				announce();
				// What other features send that depends on it, such as Needs you's list (#462), is sent again.
				for (const feature of host.features) feature.previewChanged?.(on);
				return { preview, carryOver };
			},
			/**
			 * `{ folder, name?, template? }`: a project from a folder (or null) in one step, with its orchestrator and an empty
			 * conversation with it, in one commit. The orchestrator is a copy of `template`, else of the default orchestrator.
			 */
			"projects.create": async (params) => {
				requirePreview();
				if (!("folder" in params)) throw new Error("folder must be a folder's path, or null");
				const folder = checkFolder(params.folder);
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
				requirePreview();
				const id = projectId(params);
				const name = checkName(params.name);
				await change((doc) => {
					const project = live(doc, id);
					if (project.archivedAt !== undefined) throw new Error(PROJECT_ARCHIVED);
					if (named(doc, name, id) !== undefined) throw new Error(`There is already a project called ${name}`);
					project.name = name;
					project.updatedAt = Date.now();
				});
				return {};
			},
			/**
			 * `{ id, folder?, settings? }`: the folder, where new conversations of its agents start (those working stay where
			 * they are), and any part of the settings, each checked; what is not given is kept.
			 */
			"projects.set": async (params) => {
				requirePreview();
				const id = projectId(params);
				const folder = params.folder === undefined ? undefined : checkFolder(params.folder);
				const settings = await change(async (doc, tx) => {
					const project = live(doc, id);
					if (project.archivedAt !== undefined) throw new Error(PROJECT_ARCHIVED);
					if (folder !== undefined && folder !== project.folder) {
						const same = folder === null ? undefined : ofFolder(doc, folder, id);
						if (same !== undefined) throw new Error(`There is already a project for this folder: ${same.name}${same.archivedAt !== undefined ? "; restore it instead" : ""}`);
						if (folder === null && project.repository !== null) throw new Error("A project with a repository attached needs a folder. Detach the repository first.");
						project.folder = folder;
						// Every agent of the project works in its folder (3.3): the engine sets it, never `agents.save`.
						for (const agent of Object.values((await tx.doc(Agents)).agents)) if (agent.projectId === id) agent.cwd = folder;
					}
					if (params.settings !== undefined) project.settings = changeProjectSettings(project.settings, params.settings);
					project.updatedAt = Date.now();
					return JSON.parse(JSON.stringify(project.settings)) as ProjectSettings;
				});
				return { settings };
			},
			/** `{ id }`: out of the sidebar, with the preview on; no conversation's own state changes (3.6). */
			"projects.archive": async (params) => {
				requirePreview();
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
				requirePreview();
				const id = projectId(params);
				await lifecycle(id, (project, now) => {
					if (project.archivedAt === undefined) return;
					delete project.archivedAt;
					project.updatedAt = now;
				});
				return {};
			},
			/** `{ id }`: shown only in the Archive, with the preview on; its folder and name are free again (3.6). */
			"projects.delete": async (params) => {
				requirePreview();
				const id = projectId(params);
				live(current, id);
				if (busy(id)) throw new Error(STOP_FIRST);
				await lifecycle(id, (project, now) => {
					project.deletedAt = now;
					project.updatedAt = now;
				});
				return {};
			},
		},
	};
};
