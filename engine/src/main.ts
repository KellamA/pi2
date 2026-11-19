// pi2-engine: hosts one pi durable Harness on SQLite and serves it to the app over a Unix socket.
// Wire format: one JSON object per line. Requests are { id, method, params } and are answered { id, result } or
// { id, error }; the methods are the keys of `handlers` below. The engine also pushes { event, ... } messages:
// "library", "providers", "conversation" (for opened conversations) and "auth" (during a sign-in).

import { randomUUID } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { connect, createServer, type Socket } from "node:net";
import { homedir } from "node:os";
import { dirname, isAbsolute, join } from "node:path";
import { fileURLToPath } from "node:url";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import type { AuthEvent, AuthPrompt } from "@earendil-works/pi-ai";
import {
	type AgentChange,
	AgentDoc,
	AssistantEntry,
	type Conversation,
	type ConversationId,
	type ConversationView,
	createRegistry,
	defineDoc,
	type EntryId,
	type EntryRecord,
	Harness,
	LiveDoc,
	type SubmissionId,
	UsageDoc,
} from "@earendil-works/pi-durable";
import { CodemodeSandbox } from "@earendil-works/pi-codemode";
import { NodeExecutionEnv } from "@earendil-works/pi-durable/env/node";
import { openNodeSqliteStorage } from "@earendil-works/pi-durable/storage/sqlite/node";
import { createNodePhotonImages } from "@earendil-works/pi-durable/images/node";
import { createCodingTools } from "@earendil-works/pi-durable/tools";
import { type AttachmentNote, describeAttachments, readUserEntryData, USER_ENTRY_KIND, userContent, userEntryData, validateAttachments } from "./attachments.ts";
import { createBackup, restoreBackup } from "./backup.ts";
import { BACKGROUND_ENTRY, backgroundForSubChat, backgroundMarker, backgroundMarkerDetails, hasRunningCommands } from "./background.ts";
import { bashForSubChat } from "./commands.ts";
import { BrowserHost, validateBrowser } from "./browser.ts";
import { BUILT_IN_TOOLS, chatToolNames, toolsLeftOut, validateToolsOff, validateToolsOn } from "./builtins.ts";
import { type ChatSettings, changeChatSettings, chatSettings, isChat } from "./chat.ts";
import { chatHandover, handoverAttachments } from "./handover.ts";
import { codemodeExtension } from "./codemode.ts";
import { compactionCheckpoint, type CompactionMarker, compactionMarker, earlyCompaction, RETENTION_INSTRUCTIONS, validateCompactionTokens } from "./compaction.ts";
import { holdingPlaces } from "./sections.ts";
import { credentialStore } from "./credentials.ts";
import { type Host, pi2Extension } from "./extensions.ts";
import { type Engine, FEATURES } from "./features.ts";
import { inRepository, madeWorktrees, SETUP_ENTRY, setupItem, setupMarkdown } from "./worktrees.ts";
import { CARRY_ON_ENTRY, noticingRefusals } from "./limitwait.ts";
import { promptCacheLifetimes } from "./cache.ts";
import { retryThinking, THINKING_RETRY_ENTRY } from "./thinkingretry.ts";
import { preparePlan } from "./plan.ts";
import { SUBCHATS_ENTRY, subChatsMarker } from "./subchats.ts";
import { subChatUsage } from "./subchatusage.ts";
import { messageSent } from "./heed.ts";
import { WAKE_ENTRY, WAKE_NOTE, wakeMarker, wakeMarkerDetails, wakeNoteMarker } from "./wakes.ts";
import { McpServers } from "./mcp.ts";
import { ComputerHost, hasApps, validateComputer } from "./computer.ts";
import { validateReferenceFiles } from "./reference.ts";
import { plainProviderError } from "./providererror.ts";
import { DEMO_MODEL, DEMO_PROVIDER, defaultThinking, newestOnly, Providers } from "./providers.ts";
import { type CommandRule, ruleFolder, ruleRefusal, sameFolder, wordsOf } from "./rules.ts";
import { nextRun, type Schedule, Schedules, validateRepeat } from "./schedules.ts";
import { socketPathFor } from "./socket.ts";
import { timeLines } from "./log.ts";
import { LagMonitor } from "./lag.ts";
import { validateScheduleSettings } from "./selfschedule.ts";
import { adoptLoginPath } from "./shellpath.ts";
import { runningCommands } from "./running.ts";
import { sweepRuns, useRunFolder } from "./processes.ts";
import { dueForArchive, isArchived, isDeleted, isPutAway, migrateDeleted, validateAutoArchive } from "./archive.ts";
import { type ChatVersions, chatIdOf, points, versionRequests, Versions, versionsAllowed } from "./versions.ts";
import { type Access, ACCESS_LEVELS, type AgentProfile, Agents, Inbox, Library, type Meta, type ModelRef, starterAgents, takeAgentSwitch } from "./state.ts";

// Every line of engine.log starts with the time it was written (log.ts). Not when restoring a backup: what that writes
// goes to the app, which reads its output and shows its error to the person as it is.
if (!process.argv.includes("--restore")) {
	timeLines(process.stdout);
	timeLines(process.stderr);
}

const context = BACKGROUND_CONTEXT;
const home = process.env.PI2_HOME ?? join(homedir(), "Library", "Application Support", "pi2");
mkdirSync(home, { recursive: true });
// The files of the runs of set-up and background commands, which tell what they started apart (processes.ts).
useRunFolder(join(home, "runs"));
/** Which build of the app this engine came with: the `BUILD` file a release build writes next to `src`. A development
 * engine has none. The app compares it with its own after an update and restarts an engine left over from before. */
const engineMain = fileURLToPath(import.meta.url);
const build = (() => {
	try {
		return readFileSync(join(dirname(engineMain), "..", "BUILD"), "utf8").trim() || null;
	} catch {
		return null;
	}
})();

function log(...parts: unknown[]): void {
	console.error("[pi2-engine]", ...parts);
}
/** How late the engine's thread runs (lag.ts). */
const lag = new LagMonitor((line) => log(line));

// Anything that would kill the process is written to the log first. The app restarts the engine, and reopening the
// storage recovers whatever was running.
process.on("uncaughtException", (error) => {
	log("fatal: uncaught exception", error.stack ?? error);
	process.exit(1);
});
process.on("unhandledRejection", (reason) => {
	log("fatal: unhandled rejection", reason instanceof Error ? (reason.stack ?? reason) : reason);
	process.exit(1);
});
const socketPath = (() => {
	try {
		return socketPathFor(home);
	} catch (error) {
		log("fatal: no socket path for", home, error instanceof Error ? error.message : error);
		process.exit(1);
	}
})();

// A stop (the app quitting, launchd, Ctrl-C) is listened for from the very start, not only once the engine is running:
// start-up can take seconds, most of them waiting for the login shell's PATH, and a signal with no handler kills the
// engine outright, leaving the marker that makes the next start report a crash, and the shell running (issue #100).
// Before anything is written there is nothing to undo and the engine just exits. Once it has begun, the shell is
// stopped so start-up does not wait for it, the rest of start-up (local work, a moment) is let finish, and the engine
// then stops the way a running one does instead of listening.
let phase: "probing" | "starting" | "running" = "probing";
let stopWhenStarted = false;
/** Set by stop(), at the end of this file. Declared up here, since stop() can run before start-up has got that far. */
let stopping = false;
const stopLoginShell = new AbortController();
function askToStop(signal: NodeJS.Signals): void {
	if (phase === "running") return void stop();
	if (phase === "probing") {
		if (process.argv.includes("--restore")) console.error("Stopped before restoring the backup.");
		process.exit(process.argv.includes("--restore") ? 1 : 0);
	}
	if (stopWhenStarted) return;
	stopWhenStarted = true;
	log(`told to stop (${signal}) while starting: stopping as soon as start-up is done`);
	stopLoginShell.abort();
}
process.on("SIGINT", askToStop);
process.on("SIGTERM", askToStop);

// One process writes a storage at a time. If an engine already answers on the socket, this one must not start.
const alreadyRunning = await new Promise<boolean>((resolve) => {
	const probe = connect(socketPath);
	probe.once("connect", () => (probe.destroy(), resolve(true))).once("error", () => resolve(false));
});
// `--restore <folder>`: replace the data with a backup, then exit. The app runs this between stopping and starting
// the engine.
const restoreFrom = process.argv.indexOf("--restore");
if (restoreFrom !== -1) {
	if (alreadyRunning) {
		console.error("Stop the engine before restoring a backup.");
		process.exit(2);
	}
	try {
		const aside = restoreBackup(home, process.argv[restoreFrom + 1] ?? "");
		console.log(JSON.stringify({ restored: true, previousDataMovedTo: aside }));
		process.exit(0);
	} catch (error) {
		console.error(error instanceof Error ? error.message : String(error));
		process.exit(1);
	}
}
if (alreadyRunning) {
	log("another engine is already running on", socketPath);
	process.exit(0); // not a failure: launchd must not keep restarting a second copy
}
phase = "starting";
writeFileSync(join(home, "engine.pid"), String(process.pid));
// Asked now, so the answer is there by the time anything is run; see shellpath.ts.
const pathReady = adoptLoginPath(log, process.env, undefined, undefined, stopLoginShell.signal);

// A marker that is only removed by a clean stop: finding it at start means the last engine was killed or crashed.
const runningMarker = join(home, "engine.running");
const stoppedUncleanly = existsSync(runningMarker);
writeFileSync(runningMarker, String(Date.now()));

// ---- Models, tools, harness

const credentials = credentialStore(home);
const providers = new Providers(home, credentials, () => deviceId(), { log });
const mcp = new McpServers(home, credentials);
mcp.log = log;
// Allow everything (#294), read from the stored conversation rather than the copy the watch keeps, which can lag
// behind the message that set it.
const inbox = new Inbox(async (id) => (await harness.snapshot(Library, context))?.conversations[String(id)]?.allowEverything === true);
const computer = new ComputerHost();
const browser = new BrowserHost();
let library: { conversations: Record<string, Meta> } = { conversations: {} };
let agents: Record<string, AgentProfile> = {};
let markReady = () => {};

const host: Host = {
	ready: new Promise<void>((resolve) => (markReady = resolve)),
	inbox,
	computer,
	browser,
	scratchFolder: () => workspace,
	changesThings: (name) => mcp.changesThings(name),
	agent: (id) => (id === undefined ? undefined : agents[id]),
	allowAlways: (id, tool) =>
		editMeta(id, (meta) => {
			if (!meta.autoApprove?.includes(tool)) meta.autoApprove = [...(meta.autoApprove ?? []), tool];
		}),
	addRule: (agentId, folder, words) =>
		addCommandRule(agentId, folder, words).then(
			() => {},
			(error) => log("could not keep the rule:", error instanceof Error ? error.message : error),
		),
	agentChange: (agent, options) => agentChange(agent, options),
	sendToChat: async (id, content, requestId) => {
		const conv = await harness.conversation(id as unknown as ConversationId, context);
		if (conv === undefined) return undefined;
		await takeSwitch(conv.id);
		await syncTools(conv).catch(() => {});
		const submission = await conv.submit({ type: "input", content, requestId }, context);
		await editMeta(conv.id, (meta) => {
			meta.updatedAt = Date.now();
			// The same call may replay after restart; keep the newest handoff.
			meta.subChatTask = Math.max(meta.subChatTask ?? 0, submission.id as number);
		});
		return submission.id as number;
	},
	conversations: () => library.conversations,
	working: (id) => working.has(id),
	// A chat's version is the chat as far as approvals and "always allow" go (versions.ts).
	meta: (id) => library.conversations[String(chatOf(id))],
	answerText: async (id, entryId) => {
		const conv = await harness.conversation(id, context);
		const entry = await conv?.commit((tx) => tx.entry(AssistantEntry, entryId as EntryId), context);
		return textOf((entry?.model?.[0] as { content?: unknown } | undefined)?.content);
	},
	subChatUsage: (id, ctx) => subChatUsage(harness, id, ctx),
	features: [],
};
// Features in files of their own (see features.ts). They are made here, before the harness opens, so what they
// need of the engine is handed over as getters.
const engine: Engine = {
	harness: () => harness,
	context: () => context,
	home,
	broadcast: (message) => broadcast(message),
	log,
	agents: () => agents,
	library: () => library,
	chatSettings: () => chatSettings(settings.chat),
	providers: () => providers,
	busy: (id) => working.has(id),
	// A chat on screen shows its current version (versions.ts).
	shown: () => new Set([...clients].flatMap((client) => [...client.shown].map((id) => versions.chats[String(id)]?.current ?? id))),
	apps: () => clients.size,
	stateChanged: (id) => {
		for (const client of clients) (client.subscriptions.get(id) ?? client.subscriptions.get(chatOf(id)))?.push();
	},
	activityChanged: () => announceActivity(),
	overBudget: () => (overBudget() ? `Today's budget of $${settings.dailyBudget!.toFixed(2)} is used up.` : undefined),
	providersChanged: () => void announceProviders(),
};
host.features = FEATURES.map((feature) => feature(host, engine));
// `read` shrinks a picture larger than the model takes (a Retina screenshot, say) and converts BMP, rather than refusing
// it. Photon is WebAssembly, so it needs no native module or install script, and runs in a worker that exits when idle.
const CodingTools = createCodingTools({ images: await createNodePhotonImages() });
const pi2 = pi2Extension(host);
const registry = createRegistry();
const codemode = codemodeExtension({ sandbox: new CodemodeSandbox({ memoryLimitBytes: 256 * 1024 * 1024 }) });
let mcpTools = mcp.extension();
registry.install(CodingTools);
// Their sections keep their places, so one that comes or goes mid-conversation does not send the others again (sections.ts).
registry.install(holdingPlaces(pi2));
registry.install(holdingPlaces(codemode));
registry.install(mcpTools);
const tool = (name: string) => [...CodingTools.tools!, ...pi2.tools!, ...codemode.tools!, ...mcpTools.tools!].find((t) => t.name === name);

/**
 * The tools a conversation is given: file and shell tools by access level, asking the person, delegation, and what
 * its agent adds (scripts, MCP servers). A tool whose server is not connected right now is left out, and so is a tool
 * that could do nothing: the computer while no app is allowed, and in a sub-chat (`subChat`), handing work on and
 * whatever a feature leaves out there (scheduling). Last, the built-in tools the agent's settings leave out (builtins.ts),
 * where a sub-chat follows its own agent's list, and what a feature withholds for now (pictures with no picture model).
 */
function toolsFor(access: Access, agent: AgentProfile | undefined, subChat: boolean) {
	const files = access === "none" ? [] : access === "read" ? ["read"] : ["read", "write", "edit", "bash"];
	const extras = [...(agent?.codeMode ? ["codemode"] : []), ...mcp.toolNames(agent?.mcpServers ?? [])];
	// Reference files can be read whatever the access level: the person chose them for this agent.
	const reference = (agent?.files?.length ?? 0) > 0 ? ["read_reference"] : [];
	// Computer use with no app allowed could only refuse; the tool comes with the first app the person allows (#177), or
	// with test copies of pi² allowed, or with Allow everything, under which any app may be used (#294).
	const screen = hasApps(agent?.computer, agent?.allowEverything === true) ? ["computer"] : [];
	const web = agent?.browser?.enabled === true ? ["browser"] : [];
	const added = host.features.flatMap((feature) => feature.toolNames?.(access, agent, { subChat }) ?? []);
	const delegate = !subChat && (agent?.delegates ?? []).some((other) => agents[other] !== undefined);
	const leftOut = new Set([...toolsLeftOut(agent), ...withheld()]);
	return [...files, ...reference, ...screen, ...web, ...added, "ask_user", ...(delegate ? ["delegate", "sub_chats"] : []), ...extras]
		.filter((name) => !leftOut.has(name))
		.map(tool)
		.filter((t) => t !== undefined);
}

/** The tools that could do nothing right now, such as making pictures with no picture model: offered to no one. */
function withheld(): string[] {
	return host.features.flatMap((feature) => feature.withheld?.() ?? []);
}

/**
 * The tools of a chat (chat.ts): the assistant's fixed set, with the web while the chat's web switch is on, and what
 * features add for chats (chat mode's memory while that is on, knowledge.ts).
 */
function chatTools(web: boolean) {
	const held = withheld();
	const added = host.features.flatMap((feature) => feature.chatToolNames?.() ?? []);
	return [...chatToolNames(web), ...added]
		.filter((name) => !held.includes(name))
		.map(tool)
		.filter((t) => t !== undefined);
}

/** How a new chat is configured: no folder, no instructions of an agent's, the assistant's tools. */
function chatChange(model: ModelRef, web: boolean): AgentChange {
	return { model, thinkingLevel: defaultThinking(model), instructions: null, tools: chatTools(web), cwd: null, maxTurns: null };
}

/** Whether chat `id` (or the chat it is a version of) may read the web: its own switch, which starts as chat mode's setting. */
const chatWeb = (id: number): boolean => library.conversations[String(chatOf(id))]?.web !== false;

/**
 * `wanted` in the order the conversation already has its tools (`current`, its AgentDoc's), with the new ones after them.
 * pi durable sends a conversation only the tools that changed while their order stays, and every tool again when it
 * would not (#186), so a tool that comes, such as computer use switched on, must come last.
 */
function keepingOrder<T extends { name: string } | undefined>(current: unknown, wanted: T[]): T[] {
	if (!Array.isArray(current)) return wanted;
	const place = new Map(current.map((name, index) => [name, index]));
	const kept = wanted.filter((t) => place.has(t!.name)).sort((a, b) => place.get(a!.name)! - place.get(b!.name)!);
	return [...kept, ...wanted.filter((t) => !place.has(t!.name))];
}

/** How a conversation that starts from `agent` is configured: a sub-chat, or a conversation of its own. */
async function agentChange(agent: AgentProfile, options: { subChat: boolean }): Promise<AgentChange> {
	const model = agent.model !== null && providers.models.getModel(agent.model.provider, agent.model.modelId) !== undefined ? agent.model : await defaultModel();
	return {
		model,
		thinkingLevel: (agent.thinkingLevel as never) ?? defaultThinking(model),
		instructions: agent.instructions.trim() === "" ? null : agent.instructions,
		tools: toolsFor(agent.access, agent, options.subChat),
		cwd: agent.cwd,
		maxTurns: agent.maxTurns,
	};
}

const workspace = join(home, "workspace");
mkdirSync(workspace, { recursive: true });

const storage = await openNodeSqliteStorage(join(home, "session.sqlite"));
const harness = await Harness.open(
	storage,
	{
		// Every request notes how a provider refused it, so a limit can be waited for as long as the provider says. A
		// conversation that hands out work asks for the long prompt cache (src/cache.ts).
		models: noticingRefusals(retryThinking(providers, promptCacheLifetimes(providers.models), engine.providersChanged)),
		registry,
		conversationAgent: async (agent, id, read, context) => {
			// A sub-chat is one from its first request. Read committed metadata even during crash recovery, before the
			// library watch has caught up; choosing by anything transient would resend tool definitions mid-conversation.
			if (!isSubChat((await read.snapshot(Library, context))?.conversations[String(id)])) return agent;
			const forSubChat = (tool: (typeof agent.tools)[number]) =>
				tool.name === "bash" ? bashForSubChat(tool) : tool.name === "background" ? backgroundForSubChat(tool) : tool;
			return { ...agent, tools: agent.tools.map(forSubChat), callable: agent.callable.map(forSubChat) };
		},
		// A refusal for a provider's limit is retried when and as often as src/limitwait.ts decides (a patched pi-durable
		// asks `retry.host`; see engine/scripts/patch-dependencies.ts). Read at every use, so the features are made by then.
		settings: {
			compaction: {
				early: (id: ConversationId, window: number, policy: import("@earendil-works/pi-durable").CompactionPolicy) => {
					const meta = library.conversations[String(id)];
					if (meta === undefined || isChat(meta)) return undefined;
					return earlyCompaction(agents[meta.agentId ?? ""]?.compactionTokens ?? settings.defaultCompactionTokens, window, policy);
				},
				instructions: RETENTION_INSTRUCTIONS,
				checkpoint: compactionCheckpoint,
			} as import("@earendil-works/pi-durable").CompactionSettings,
			retry: {
				host: (message: never, attempt: number, id: unknown) => {
					const feature = host.features.find((candidate) => candidate.retry !== undefined);
					return feature?.retry?.(message, attempt, id as number) ?? { spent: 0 };
				},
			} as never,
		},
		// A conversation without a chosen folder works in the app's own scratch folder, never the home folder.
		env: ({ cwd }) => new NodeExecutionEnv({ cwd: cwd ?? workspace }),
		identity: { attribution: { name: "pi2", url: "https://github.com/earendil-works/pi" } },
		onReport: (report) => log("report", report.kind, report.error instanceof Error ? report.error.message : ""),
	},
	context,
);

const settingsPath = join(home, "settings.json");
const settings: {
	defaultModel?: ModelRef;
	lastAgent?: string;
	dailyBudget?: number | null;
	onboarded?: boolean;
	deviceId?: string;
	hiddenModels?: Record<string, string[]>;
	autoArchiveDays?: number | null;
	defaultCompactionTokens?: number | null;
	/** Chat mode's settings (chat.ts); read through `chatSettings`, which gives the defaults for what is missing. */
	chat?: ChatSettings;
	/** The model last chosen in a chat, apart from `defaultModel`, the agent view's. */
	lastChatModel?: ModelRef;
} = (() => {
	try {
		return JSON.parse(readFileSync(settingsPath, "utf8"));
	} catch {
		return {};
	}
})();
const saveSettings = () => writeFileSync(settingsPath, JSON.stringify(settings, null, "\t"));
const compactionSettingsEvent = () => ({ event: "compactionSettings", defaultCompactionTokens: settings.defaultCompactionTokens ?? null });

/** A random ID for this installation, made the first time a sign-in asks for one and the same ever after. */
function deviceId(): string {
	if (settings.deviceId === undefined) {
		settings.deviceId = randomUUID();
		saveSettings();
	}
	return settings.deviceId;
}

/** Which version of each chat is shown (versions.ts); kept up to date by a watch further down. */
let versions: { chats: Record<string, ChatVersions> } = (await harness.snapshot(Versions, context)) ?? { chats: {} };

/** A conversation the app names by its id. A chat with several versions is the version it shows. */
async function conversation(id: unknown): Promise<Conversation> {
	const shown = typeof id === "number" ? (versions.chats[String(id)]?.current ?? id) : undefined;
	const found = shown === undefined ? undefined : await harness.conversation(shown as unknown as ConversationId, context);
	if (found === undefined) throw new Error(`Unknown conversation: ${String(id)}`);
	return found;
}

/** The chat a version belongs to, or the conversation itself. */
function chatOf(id: number | ConversationId): number {
	return chatIdOf(library.conversations, id as number);
}
/** A sub-chat, handed work by another conversation; not a chat's version. */
function isSubChat(meta: Meta | undefined): boolean {
	return meta?.parent !== undefined && meta.version !== true;
}

/**
 * Bring a conversation's tools in line with what its agent may do now. A conversation's tools are fixed when it is
 * set up, so without this an ability switched on in the agent's settings (handing work on, reference files, computer
 * use, scripts, MCP servers) would only reach conversations started afterwards, and one switched off would linger.
 * The conversation's own tool access is kept. Does nothing when they already match.
 */
async function syncTools(conv: Conversation): Promise<void> {
	const id = conv.id as unknown as number;
	const meta = library.conversations[String(id)];
	const own = agents[meta?.agentId ?? ""];
	// A conversation whose agent was deleted keeps the setup it has. A chat has the assistant's tools.
	if (meta === undefined || (own === undefined && !isChat(meta))) return;
	const current = (await harness.snapshot(AgentDoc, conv.id, context))?.tools;
	const wanted = keepingOrder(current, isChat(meta) ? chatTools(chatWeb(id)) : toolsFor(meta.access, own, isSubChat(meta)));
	const names = wanted.map((t) => t!.name);
	if (Array.isArray(current) && current.length === names.length && current.every((name, index) => name === names[index])) return;
	await conv.configure({ tools: wanted }, context);
	for (const client of clients) client.subscriptions.get(chatOf(id))?.push();
}

/**
 * A message is about to be sent to conversation `id`: it takes its own agent's Allow everything switch as it is now
 * (state.ts, `takeAgentSwitch`). Every way a message reaches a conversation calls this first: the person's (`submit`,
 * `continue`), a schedule's (`deliver`) and an agent's continuing a sub-chat (`sendToChat`); `delegate` sets a new
 * sub-chat's from its own agent as it makes it.
 */
async function takeSwitch(id: ConversationId): Promise<void> {
	const known = library.conversations[String(id)];
	if (known !== undefined && (known.allowEverything === true) === (agents[known.agentId ?? ""]?.allowEverything === true)) return;
	await harness.commit(async (tx) => {
		const meta = (await tx.doc(Library)).conversations[String(id)];
		if (meta !== undefined) takeAgentSwitch(meta, agents[meta.agentId ?? ""]);
	}, context);
}

/** Changes a conversation's record in the library; a chat's version changes the chat's. */
async function editMeta(id: ConversationId, change: (meta: Meta) => void): Promise<void> {
	const key = chatOf(id);
	await harness.commit(async (tx) => {
		const meta = (await tx.doc(Library)).conversations[String(key)];
		if (meta !== undefined) change(meta);
	}, context);
}

// Saving and duplicating share validation and defaults; the app never assembles a copy.
async function saveAgent(input: Partial<AgentProfile> | undefined, copiedRules?: CommandRule[]): Promise<{ id: string }> {
	let name = typeof input?.name === "string" ? input.name.trim() : "";
	if (input === undefined || name === "") throw new Error("Give the agent a name");
	if (input.access !== undefined && !ACCESS_LEVELS.includes(input.access)) throw new Error(`Unknown access level: ${String(input.access)}`);
	if (typeof input.cwd === "string" && !(existsSync(input.cwd) && statSync(input.cwd).isDirectory())) throw new Error(`Not a folder: ${input.cwd}`);
	if (input.worktree !== undefined && typeof input.worktree !== "boolean") throw new Error("worktree must be true or false");
	if (input.setup !== undefined && typeof input.setup !== "string") throw new Error("The set-up command must be text");
	if (typeof input.setup === "string" && input.setup.length > 4_000) throw new Error("The set-up command is too long: keep it under 4,000 characters, or put it in a script");
	if (input.maxTurns !== undefined && input.maxTurns !== null && !(Number.isInteger(input.maxTurns) && input.maxTurns >= 1)) throw new Error("The turn limit must be a whole number, 1 or more");
	const taken = Object.values(agents).some((other) => other.id !== input.id && other.name.toLowerCase() === name.toLowerCase());
	if (taken && copiedRules === undefined) throw new Error(`There is already an agent called ${name}`);
	if (input.id !== undefined && agents[input.id] === undefined) throw new Error(`Unknown agent: ${input.id}`);
	// New identities are allocated in the commit, so two requests cannot pick the same name or id.
	let id = input.id ?? "";
	const previous = agents[id];
	const agent: AgentProfile = {
		id,
		name,
		description: (input.description ?? previous?.description ?? "").trim(),
		color: input.color ?? previous?.color ?? "violet",
		model: input.model === undefined ? (previous?.model ?? null) : input.model,
		thinkingLevel: input.thinkingLevel === undefined ? (previous?.thinkingLevel ?? null) : input.thinkingLevel,
		instructions: input.instructions ?? previous?.instructions ?? "",
		access: input.access ?? previous?.access ?? "none",
		cwd: input.cwd === undefined ? (previous?.cwd ?? null) : input.cwd,
		worktree: input.worktree ?? previous?.worktree ?? false,
		setup: (input.setup ?? previous?.setup ?? "").trim(),
		delegates: (input.delegates ?? previous?.delegates ?? []).filter((other) => other !== id),
		maxTurns: input.maxTurns === undefined ? (previous?.maxTurns ?? null) : input.maxTurns,
		codeMode: input.codeMode ?? previous?.codeMode ?? false,
		mcpServers: input.mcpServers ?? previous?.mcpServers ?? [],
		files: input.files === undefined ? (previous?.files ?? []) : validateReferenceFiles(input.files),
		computer: input.computer === undefined ? (previous?.computer ?? { enabled: false, apps: [], ask: true, testCopies: false }) : validateComputer(input.computer),
		browser: input.browser === undefined ? (previous?.browser ?? { enabled: false, ask: true }) : validateBrowser(input.browser),
		schedule: input.schedule === undefined ? (previous?.schedule ?? { enabled: false }) : validateScheduleSettings(input.schedule),
		toolsOff: input.toolsOff === undefined ? (previous?.toolsOff ?? []) : validateToolsOff(input.toolsOff),
		toolsOn: input.toolsOn === undefined ? (previous?.toolsOn ?? []) : validateToolsOn(input.toolsOn),
		compactionTokens: input.compactionTokens === undefined ? (previous?.compactionTokens ?? null) : validateCompactionTokens(input.compactionTokens),
		createdAt: previous?.createdAt ?? Date.now(),
	};
	if (agent.worktree === true && (agent.cwd === null || !(await inRepository(agent.cwd)))) {
		throw new Error("To give each conversation its own worktree, choose a folder in a git repository for the agent");
	}
	await harness.commit(async (tx) => {
		const doc = await tx.doc(Agents);
		if (input.id === undefined) {
			const base = name;
			const taken = () => Object.values(doc.agents).some((other) => other.name.toLowerCase() === name.toLowerCase());
			if (copiedRules !== undefined) {
				for (let n = 2; taken(); n++) name = `${base} ${n}`;
			} else if (taken()) throw new Error(`There is already an agent called ${name}`);
			const slug = name.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "") || "agent";
			// A deleted copy may still own conversations, schedules and worktrees. Never reuse its identity.
			id = copiedRules === undefined ? slug : `${slug}-${randomUUID()}`;
			for (let n = 2; doc.agents[id] !== undefined; n++) id = `${slug}-${n}`;
			agent.id = id;
			agent.name = name;
			agent.delegates = agent.delegates.filter((other) => other !== id);
		}
		// Save never accepts rules from the app. Duplication alone supplies rules from the stored source.
		const rules: CommandRule[] = JSON.parse(JSON.stringify(copiedRules ?? doc.agents[id]?.commandRules ?? []));
		// Nor variables: they change through their own requests, and a copy gets theirs from variables.ts.
		const variables = doc.agents[id]?.variables;
		// Nor Allow everything, which has its own request; a new agent, a duplicate among them, never has it (#294).
		const everything = doc.agents[id]?.allowEverything === true;
		doc.agents[id] = {
			...agent,
			commandRules: rules,
			...(variables === undefined ? {} : { variables: JSON.parse(JSON.stringify(variables)) }),
			...(everything ? { allowEverything: true as const } : {}),
		};
	}, context);
	// The agent's conversations pick up what it may now do at their next message; see syncTools.
	return { id };
}

// ---- Rules for an agent's shell commands (rules.ts). They live on the agent, so deleting it deletes them.

const sameWords = (a: readonly string[], b: readonly string[]) => a.length === b.length && a.every((word, index) => word === b[index]);

/**
 * Keep a rule, whether it was chosen in an approval or typed in the agent's settings: both pass the same checks, and a
 * folder inside a worktree pi² made is kept as the same folder of the repository's main checkout (rules.ts, `ruleFolder`).
 */
async function addCommandRule(agentId: string, folder: string, words: string[]): Promise<CommandRule> {
	const refused = ruleRefusal(words);
	if (refused !== undefined) throw new Error(refused);
	const rule: CommandRule = { folder: ruleFolder(folder, await madeWorktrees(harness, context)), words: [...words], createdAt: Date.now() };
	await harness.commit(async (tx) => {
		const agent = (await tx.doc(Agents)).agents[agentId];
		if (agent === undefined) throw new Error(`Unknown agent: ${agentId}`);
		const rules: CommandRule[] = JSON.parse(JSON.stringify(agent.commandRules ?? []));
		if (rules.some((other) => sameFolder(other.folder, rule.folder) && sameWords(other.words, rule.words))) return;
		agent.commandRules = [...rules, rule];
	}, context);
	return rule;
}

async function removeCommandRule(agentId: string, folder: string, words: string[]): Promise<void> {
	await harness.commit(async (tx) => {
		const agent = (await tx.doc(Agents)).agents[agentId];
		if (agent === undefined) throw new Error(`Unknown agent: ${agentId}`);
		const rules: CommandRule[] = JSON.parse(JSON.stringify(agent.commandRules ?? []));
		const kept = rules.filter((rule) => !(sameFolder(rule.folder, folder) && sameWords(rule.words, words)));
		if (kept.length === rules.length) throw new Error("That rule is already gone");
		agent.commandRules = kept;
	}, context);
}

// ---- What the app is sent

function textOf(content: unknown, markImages = true): string {
	if (typeof content === "string") return content;
	if (!Array.isArray(content)) return "";
	return content.map((block) => (block?.type === "text" && typeof block.text === "string" ? block.text : block?.type === "image" && markImages ? "[image]" : "")).join("");
}

function imagesOf(content: unknown): { data: string; mimeType: string }[] {
	if (!Array.isArray(content)) return [];
	return content.flatMap((block) => (block?.type === "image" && typeof block.data === "string" && typeof block.mimeType === "string" ? [{ data: block.data, mimeType: block.mimeType }] : []));
}

type ToolCall = { callId: string; name: string; arguments: unknown };
type Item =
	| { id: number; kind: "user"; text: string; attachments: AttachmentNote[]; images: number }
	| { id: number; kind: "assistant"; text: string; thinking: string; toolCalls: ToolCall[]; stop: string; error: string | null; model: string | null }
	| { id: number; kind: "tool"; callId: string; name: string; text: string; isError: boolean; details: unknown; images: number }
	| { id: number; kind: "marker"; text: string; details?: { background?: { id: string }; wake?: { text: string }; compaction?: CompactionMarker } }
	| ReturnType<typeof setupItem>;

type AssistantLike = { content?: unknown; stopReason?: string; errorMessage?: string; model?: string };

function assistantParts(message: AssistantLike): { text: string; thinking: string; toolCalls: ToolCall[] } {
	const blocks = Array.isArray(message.content) ? message.content : [];
	return {
		text: textOf(message.content),
		thinking: blocks.map((b) => (b?.type === "thinking" && typeof b.thinking === "string" ? b.thinking : "")).join(""),
		toolCalls: blocks.filter((b) => b?.type === "toolCall").map((b) => ({ callId: String(b.id), name: String(b.name), arguments: b.arguments ?? {} })),
	};
}

/** A tool result's `details`, wherever this version of pi durable keeps them on the entry. */
function detailsOf(entry: EntryRecord): unknown {
	const data = entry.data as { details?: unknown } | undefined;
	const message = entry.model?.[0] as { details?: unknown } | undefined;
	return data?.details ?? message?.details ?? null;
}

function toItem(entry: EntryRecord): Item | undefined {
	const id = entry.id as unknown as number;
	if (entry.kind === "pi.reset") return { id, kind: "marker", text: "Context reset" };
	if (entry.kind === "pi.compaction") return { id, kind: "marker", ...compactionMarker(entry) };
	if (entry.kind === SETUP_ENTRY) return setupItem(id, entry.data);
	if (entry.kind === THINKING_RETRY_ENTRY || entry.kind === CARRY_ON_ENTRY) return { id, kind: "marker", text: (entry.data as { text: string }).text };
	if (entry.kind === BACKGROUND_ENTRY) {
		// With the command's id, so the line can open the window with its output.
		const details = backgroundMarkerDetails(entry.data);
		return { id, kind: "marker", text: backgroundMarker(entry.data), ...(details === undefined ? {} : { details }) };
	}
	if (entry.kind === SUBCHATS_ENTRY) return { id, kind: "marker", text: subChatsMarker(entry.data) };
	// Show the same model input behind the line, including wakes stored before the row could open (#318).
	if (entry.kind === WAKE_ENTRY) {
		const content = textOf((entry.model?.[0] as { content?: unknown } | undefined)?.content);
		const details = { ...wakeMarkerDetails(entry.data), wake: { text: content } };
		return { id, kind: "marker", text: wakeMarker(entry.data), details };
	}
	if (entry.kind === WAKE_NOTE) return { id, kind: "marker", text: wakeNoteMarker(entry.data) };
	const message = entry.model?.[0] as (AssistantLike & { role?: string; toolCallId?: string; toolName?: string; isError?: boolean }) | undefined;
	if (message === undefined) return undefined;
	switch (message.role) {
		case "user": {
			// A message sent with attachments recorded what the person typed apart from the files' contents. Its pictures
			// are counted, as a tool result's are, and fetched one at a time.
			const own = readUserEntryData(entry);
			return { id, kind: "user", text: own?.text ?? textOf(message.content), attachments: own?.attachments ?? [], images: imagesOf(message.content).length };
		}
		case "assistant":
			return { id, kind: "assistant", ...assistantParts(message), stop: message.stopReason ?? "stop", error: message.errorMessage ?? null, model: message.model ?? null };
		case "toolResult":
			// Pictures are not sent with the transcript: the app is told how many there are and fetches one when it shows it.
			return { id, kind: "tool", callId: String(message.toolCallId), name: String(message.toolName), text: textOf(message.content, false), isError: message.isError === true, details: detailsOf(entry), images: imagesOf(message.content).length };
		default:
			return undefined;
	}
}

type LiveDocShape = {
	run?: { turns?: number };
	generation?: { message?: AssistantLike; retry?: { at: number; error: string } };
	tools?: { callId: string; name: string; status: string; output?: string; details?: unknown }[];
	runFailure?: { reason: string; detail?: string };
	compactions?: unknown[];
	compactionFailure?: { error?: string };
	lastRequestInputTokens?: number;
};

type UsageJson = { input?: number; output?: number; cacheRead?: number; cacheWrite?: number; totalTokens?: number; cost?: { total?: number } };
type UsageDocShape = { models?: Record<string, UsageJson>; tools?: Record<string, UsageJson> };
/**
 * What a usage entry cost. Providers report this themselves; the scripted demo model is free, except that tests give
 * it a price (PI2_DEMO_COST, dollars per million tokens) so that spend and budgets have something to count.
 */
const demoPrice = Number(process.env.PI2_DEMO_COST ?? 0);
/**
 * Providers signed in with a subscription. pi-ai prices every answer at the model's list price, which is not what a
 * subscription costs, so their usage counts tokens only: no dollar figure, and nothing towards the daily budget.
 * This follows how the provider is connected now, so switching a provider between a subscription and a key
 * re-labels its earlier usage too.
 */
let subscriptions = new Set<string>();
const onSubscription = (key: string) => subscriptions.has(key.split("/")[0]!);
/** A model added by hand has no known price: pi-ai counts it at none, and Usage says so rather than showing nothing. */
const unpriced = (key: string) => {
	const slash = key.indexOf("/");
	return !onSubscription(key) && providers.isAddedByHand(key.slice(0, slash), key.slice(slash + 1));
};
const costOf = (key: string, usage: UsageJson) => {
	if (onSubscription(key)) return 0;
	return key === `${DEMO_PROVIDER}/${DEMO_MODEL}` && demoPrice > 0 ? ((usage.totalTokens ?? 0) * demoPrice) / 1_000_000 : (usage.cost?.total ?? 0);
};
const usageTotals = (usage: UsageDocShape | undefined) => {
	let cost = 0;
	let tokens = 0;
	for (const [key, entry] of [...Object.entries(usage?.models ?? {}), ...Object.entries(usage?.tools ?? {})]) {
		cost += costOf(key, entry);
		tokens += entry.totalTokens ?? 0;
	}
	return { cost, tokens };
};

/** How full the model's context is, from the newest answer's own token counts. */
function contextOf(view: ConversationView, model: ModelRef | undefined) {
	const window = model === undefined ? undefined : providers.models.getModel(model.provider, model.modelId)?.contextWindow;
	for (let i = view.entries.length - 1; i >= 0; i--) {
		const entry = view.entries[i]!;
		if (entry.kind === "pi.reset") break;
		const usage = (entry.model?.[0] as { role?: string; usage?: UsageJson } | undefined)?.usage;
		if (usage === undefined) continue;
		const input = (usage.input ?? 0) + (usage.cacheRead ?? 0) + (usage.cacheWrite ?? 0);
		return { used: input + (usage.output ?? 0), window: window ?? null, input };
	}
	return { used: 0, window: window ?? null, input: null };
}

/**
 * What a run's failure says, for the model it was asked of. pi durable names a model it cannot find by its key, and a
 * provider's refusal of a model added by hand does not say that pi² only guessed it was there; both are said plainly.
 */
function failureDetail(failure: { reason: string; detail?: string }, model: ModelRef | undefined): string | null {
	const provider = model === undefined ? undefined : providers.models.getProvider(model.provider);
	if (failure.reason === "no_model" && model !== undefined) {
		const what =
			provider === undefined
				? `${model.modelId}'s provider, ${model.provider}, is no longer connected.`
				: `${provider.name} has no model ${model.modelId} now. A model added by hand and then removed, or one a provider no longer lists, cannot be used.`;
		return `${what} Choose another model from the toolbar, then press Continue.`;
	}
	if (failure.reason === "model_error" && model !== undefined && providers.isAddedByHand(model.provider, model.modelId)) {
		const said = failure.detail ?? "";
		return `${said}${said === "" || /[.!?]$/.test(said) ? "" : "."} ${model.modelId} was added by hand in Settings › Providers: if ${provider?.name ?? model.provider} does not offer it to this sign-in or key, or names it otherwise, choose another model or change the id there.`.trim();
	}
	return failure.detail ?? null;
}

function stateOf(view: ConversationView, meta: Meta | undefined) {
	const live = (view.docs["pi.live"] ?? {}) as LiveDocShape;
	const agent = (view.docs["pi.agent"] ?? {}) as { model?: ModelRef; thinkingLevel?: string; cwd?: string };
	const inbox = (view.docs["pi.inbox"] ?? {}) as { items?: { id: number; mode: string; content?: unknown; entry?: { kind?: unknown; data?: unknown } }[] };
	const partial = live.generation?.message;
	const { input, ...contextSize } = contextOf(view, agent.model);
	const id = view.conversation.id as unknown as number;
	/** A command running in the foreground: when it started and last printed, for the clock on its row (running.ts). */
	const clock = (callId: string) => {
		const running = runningCommands.clock(id, callId);
		return running === undefined ? {} : { startedAt: running.startedAt, lastOutputAt: running.lastOutputAt };
	};
	return {
		busy: live.run !== undefined,
		turns: live.run?.turns ?? 0,
		partial: partial === undefined ? null : assistantParts(partial),
		retry: live.generation?.retry ?? null,
		tools: (live.tools ?? []).map((slot) => ({ callId: slot.callId, name: slot.name, status: slot.status, output: slot.output ?? "", details: slot.details ?? null, ...clock(slot.callId) })),
		failure: live.runFailure === undefined ? null : { reason: live.runFailure.reason, detail: failureDetail(live.runFailure, agent.model) },
		usage: usageTotals(view.docs["pi.usage"] as UsageDocShape | undefined),
		context: contextSize,
		lastRequestInputTokens: live.lastRequestInputTokens ?? input,
		compacting: (live.compactions ?? []).length > 0,
		compactionError: live.compactionFailure?.error ?? null,
		// An archived conversation, or a sub-chat of one, is not in the list the app is sent; its title and standing
		// come with it here, so it can still be shown, read-only.
		title: meta?.title ?? "",
		// A chat of the built-in assistant (chat.ts): the page shows chat mode's own controls only then.
		chat: isChat(meta),
		// A chat's web switch (#287): whether its next message may read the web. Null for any other conversation.
		web: isChat(meta) ? chatWeb(id) : null,
		archived: isArchived(meta) || (meta?.parent !== undefined && isArchived(library.conversations[String(meta.parent)])),
		queued: (inbox.items ?? [])
			.filter((item) => item.mode !== "write")
			.map((item) => {
				const own = readUserEntryData(item.entry);
				return { id: item.id, mode: item.mode, text: own?.text ?? textOf(item.content), attachments: own?.attachments ?? [] };
			}),
		agent: {
			model: agent.model ?? null,
			thinkingLevel: agent.thinkingLevel ?? null,
			cwd: agent.cwd ?? null,
			access: meta?.access ?? "none",
			agentId: meta?.agentId ?? null,
			parent: meta?.parent ?? null,
		},
		// Where the versions of what is shown part, and which is shown; null where they are not offered (versions.ts).
		versions: versionsAllowed(meta) ? points(versions.chats[String(chatOf(id))], chatOf(id), new Set(view.entries.map((entry) => entry.id as unknown as number))) : null,
		// What features add (see features.ts).
		...Object.assign({}, ...host.features.map((feature) => feature.state?.(view, meta) ?? {})),
	};
}

// ---- Clients

/** `follow` watches the version a chat shows now, if that changed (versions.ts). */
type Subscription = { push: () => void; stop: () => Promise<unknown>; follow: () => Promise<void> };
/** `shown`: the conversations this app has on screen, in its panes or as chat mode's chat (`conversations.shown`). */
type Client = { socket: Socket; subscriptions: Map<number, Subscription>; shown: Set<number> };
const clients = new Set<Client>();
/** Clients that registered as the computer host; the host object is kept per client so the right one is dropped. */
const computerClients = new Set<Client>();
const computerHostOf = new WeakMap<Client, { send: (message: unknown) => void }>();
/** The same for the browser: the app holds the web views, and offers to work them for agents. */
const browserClients = new Set<Client>();
const browserHostOf = new WeakMap<Client, { send: (message: unknown) => void }>();
const pendingPrompts = new Map<string, (answer: string) => void>();
const logins = new Map<string, AbortController>();
let nextLocalId = 1;

function send(client: Client, message: unknown): void {
	if (!client.socket.destroyed) client.socket.write(`${JSON.stringify(message)}\n`);
}
function broadcast(message: unknown): void {
	if (clients.size === 0) return;
	// Made into text once, however many apps are connected.
	const line = `${JSON.stringify(message)}\n`;
	for (const client of clients) if (!client.socket.destroyed) client.socket.write(line);
}

/**
 * Sends the event `make` makes to every app at most once every `ms`: at once when none went in the last `ms`, else once
 * at the end of it, made then, so the last state is always sent. Activity lists every run, and was sent again whole for
 * each change to any of them: with 20 runs working, 55 events a second, 360 KB, each of which the app decoded and laid
 * out (#344). The library and the Inbox, sent a few times a second at most, go at once: what is done next often reads
 * them (an approval answered must leave the Inbox before it could be answered again).
 */
function coalesced(make: () => unknown, ms = 250): () => void {
	let last = Number.NEGATIVE_INFINITY;
	let timer: ReturnType<typeof setTimeout> | undefined;
	const now = () => {
		timer = undefined;
		last = performance.now();
		broadcast(make());
	};
	return () => {
		if (timer !== undefined) return;
		const wait = last + ms - performance.now();
		if (wait <= 0) now();
		else timer = setTimeout(now, wait);
	};
}
const announceActivity = coalesced(() => activityEvent());

library = (await harness.snapshot(Library, context)) ?? { conversations: {} };
// Conversations deleted before there was an archive are marked the new way, once.
if (Object.values(library.conversations).some((meta) => meta.archived !== undefined)) {
	await harness.commit(async (tx) => void migrateDeleted((await tx.doc(Library)).conversations), context);
	library = (await harness.snapshot(Library, context)) ?? { conversations: {} };
}
let busyConversations = new Set<number>();
/** Every conversation with live work, sub-chats included. */
let working = new Set<number>();

function libraryEvent() {
	const conversations = Object.entries(library.conversations)
		// Sub-chats are listed too, pointing at their parent, unless either of them was archived or deleted. A chat's
		// versions are not: the chat stands for them.
		.filter(([, meta]) => meta.version !== true && !isPutAway(meta) && (meta.parent === undefined || !isPutAway(library.conversations[String(meta.parent)])))
		.map(([id, meta]) => ({
			id: Number(id),
			title: meta.title,
			createdAt: meta.createdAt,
			updatedAt: meta.updatedAt,
			// A conversation shows as working while it or any of its sub-chats is; a sub-chat only for itself.
			busy: meta.parent === undefined ? busyConversations.has(Number(id)) : working.has(Number(id)),
			agentId: meta.agentId ?? null,
			parent: meta.parent ?? null,
			// Chat mode lists only chats, and the agent view never does (chat.ts).
			chat: isChat(meta),
			pinned: meta.pinned === true,
			// Continue with an Agent (#289): the chat a conversation was continued from, and the conversations a chat was
			// continued in, leaving out any deleted since.
			continuedFrom: meta.continuedFrom ?? null,
			continuedIn: (meta.continuedIn ?? []).filter((other) => library.conversations[String(other)] !== undefined && !isDeleted(library.conversations[String(other)])),
			// Allow everything as this conversation took it at its latest message; the app warns while it or its agent has it.
			allowEverything: meta.allowEverything === true,
		}))
		.sort((a, b) => b.updatedAt - a.updatedAt);
	// The Archive: archived conversations, and sub-chats an agent archived on their own while their conversation stays in
	// the sidebar. A sub-chat of an archived conversation is reached through that conversation.
	const archived = Object.entries(library.conversations)
		.filter(([, meta]) => meta.version !== true && isArchived(meta) && (meta.parent === undefined || !isPutAway(library.conversations[String(meta.parent)])))
		.map(([id, meta]) => ({
			id: Number(id),
			title: meta.title,
			createdAt: meta.createdAt,
			updatedAt: meta.updatedAt,
			archivedAt: meta.archivedAt as number,
			agentId: meta.agentId ?? null,
			subChats: Object.values(library.conversations).filter((child) => child.parent === Number(id) && child.version !== true && !isDeleted(child)).length,
			parent: meta.parent ?? null,
			parentTitle: meta.parent === undefined ? null : (library.conversations[String(meta.parent)]?.title ?? ""),
			chat: isChat(meta),
			pinned: meta.pinned === true,
		}))
		.sort((a, b) => b.archivedAt - a.archivedAt);
	return { event: "library", conversations, archived, autoArchiveDays: settings.autoArchiveDays ?? null };
}

/** Nothing new is started in a conversation that was put away, or in one of its sub-chats. */
function refuseIfPutAway(id: number): void {
	const put = [library.conversations[String(id)], library.conversations[String(rootOf(id))]];
	if (put.some(isDeleted)) throw new Error("This conversation was deleted");
	if (put.some(isArchived)) throw new Error("This conversation is archived. Restore it to carry on.");
}

/** Archive a top-level conversation: stop what it is doing, and move it and its sub-chats out of the sidebar. */
async function archiveConversation(id: number): Promise<void> {
	const conv = await conversation(id);
	const meta = library.conversations[String(id)];
	if (meta?.parent !== undefined) throw new Error("A sub-chat is archived together with the conversation it belongs to");
	if (isDeleted(meta)) throw new Error("That conversation was deleted");
	await conv.abort(context);
	await editMeta(conv.id, (m) => {
		if (m.archivedAt === undefined) m.archivedAt = Date.now();
	});
}

/** Archive what has gone unused for as long as the person chose. Conversations that are working or waiting are left. */
async function sweepArchive(): Promise<void> {
	const waiting = new Set(inbox.list().map((item) => item.conversationId));
	// One with a command still running in the background is in use too: archiving it would stop the command.
	const active = (id: number) => working.has(id) || busyConversations.has(id) || waiting.has(id) || hasRunningCommands(id);
	for (const id of dueForArchive(library.conversations, Date.now(), settings.autoArchiveDays ?? null, active)) {
		await archiveConversation(id).catch((error) => log("could not archive conversation", id, error instanceof Error ? error.message : ""));
	}
}

function agentsEvent() {
	// The list of built-in tools goes with them, so the settings show what the engine offers without a copy of their own.
	return { event: "agents", agents: Object.values(agents).sort((a, b) => a.createdAt - b.createdAt), builtInTools: BUILT_IN_TOOLS };
}

/** Everything waiting on the person, with enough context to answer from anywhere in the app. */
function inboxEvent() {
	const items = inbox.list().map((item) => {
		// A question from a chat's version is the chat's: the app shows the chat under its own id.
		const conversationId = chatOf(item.conversationId);
		const meta = library.conversations[String(conversationId)];
		const root = meta?.parent ?? conversationId;
		return {
			...item,
			conversationId,
			title: meta?.title ?? "",
			agentName: agents[meta?.agentId ?? ""]?.name ?? null,
			rootConversationId: root,
			rootTitle: library.conversations[String(root)]?.title ?? "",
		};
	});
	return { event: "inbox", items };
}
inbox.onChange = () => {
	broadcast(inboxEvent());
	announceActivity();
};

async function providersEvent() {
	const [list, all] = await Promise.all([providers.listProviders(), providers.listModels()]);
	// Hidden models stay in the list, marked: settings shows them, the pickers leave them out, and one already in use keeps working.
	const models = all.map((model) => ({ ...model, hidden: settings.hiddenModels?.[model.provider]?.includes(model.id) === true }));
	return { event: "providers", providers: list, models, defaultModel: await defaultModel(), onboarded: settings.onboarded === true };
}
async function announceProviders(): Promise<void> {
	broadcast(await providersEvent());
	// Signing in or out changes which usage has a price.
	scheduleUsageRefresh();
	for (const feature of host.features) feature.providersChanged?.();
}

/** The model a new conversation starts with: the last one picked if it is still usable, else the demo model. */
async function defaultModel(): Promise<ModelRef> {
	const wanted = settings.defaultModel;
	if (wanted !== undefined && (await usable(wanted))) return wanted;
	return { provider: DEMO_PROVIDER, modelId: DEMO_MODEL };
}

/** A choice in a conversation's model menu counts for future conversations, too. */
function rememberModel(model: ModelRef, chat: boolean): void {
	if (chat) settings.lastChatModel = model;
	else settings.defaultModel = model;
	saveSettings();
}

/** Whether `model`'s provider is connected and offers it now. */
async function usable(model: ModelRef): Promise<boolean> {
	return (await providers.models.getAvailable(model.provider).catch(() => [])).some((m) => m.id === model.modelId);
}

/**
 * The model a new chat starts with: the one used last in a chat, else chat mode's default model, else the agent view's.
 * Choosing a default model in Settings forgets the last one used (`chat.set`), so the choice counts from the next chat.
 */
async function chatModel(): Promise<ModelRef> {
	for (const wanted of [settings.lastChatModel, chatSettings(settings.chat).defaultModel]) {
		if (wanted !== undefined && wanted !== null && (await usable(wanted))) return wanted;
	}
	return defaultModel();
}

const chatEvent = () => ({ event: "chat", ...chatSettings(settings.chat) });

/**
 * Sends the app a conversation as it changes. A chat with several versions is sent as the version it shows, under the
 * chat's id, and starts over with that version's entries when another is shown.
 */
async function subscribe(client: Client, id: number): Promise<void> {
	if (client.subscriptions.has(id)) return;
	let watch: Awaited<ReturnType<Conversation["watch"]>> | undefined;
	let view: ConversationView | undefined;
	let lastSent: unknown;
	const push = () => {
		if (view === undefined) return;
		// Entries never change once committed, so the app is only sent the ones it does not have yet.
		const index = lastSent === undefined ? -1 : view.entries.findIndex((entry) => entry.id === lastSent);
		const reset = lastSent === undefined || index === -1;
		const fresh = reset ? view.entries : view.entries.slice(index + 1);
		if (view.entries.length > 0) lastSent = view.entries.at(-1)!.id;
		const items = fresh.map(toItem).filter((item) => item !== undefined);
		send(client, { event: "conversation", id, reset, items, state: stateOf(view, library.conversations[String(id)]) });
	};
	let following = Promise.resolve();
	const attach = async () => {
		const conv = await conversation(id);
		if (watch !== undefined && view?.conversation.id === conv.id) return;
		const next = await conv.watch(context, { min: 300, max: 600 });
		// A feature's own documents are not part of the view; the task list is loaded here so the first state carries it.
		await preparePlan(conv.id as unknown as number);
		const previous = watch;
		watch = next;
		view = next.value;
		lastSent = undefined;
		push();
		next.start(async (call) => {
			if (call.kind !== "value" || watch !== next) return;
			view = call.value;
			push();
		});
		await previous?.stop();
	};
	// One at a time, so two quick changes of version never leave two watches.
	const follow = () => (following = following.then(attach).catch((error) => log("could not follow conversation", id, error instanceof Error ? error.message : "")));
	client.subscriptions.set(id, { push, stop: async () => watch?.stop(), follow });
	try {
		await attach();
	} catch (error) {
		client.subscriptions.delete(id);
		throw error;
	}
}

/** Start a chat with pi²'s built-in assistant (chat.ts), on `model` if given, else on the model a new chat starts with. */
async function createChat(given: unknown): Promise<{ id: ConversationId }> {
	let model: ModelRef;
	if (given === undefined || given === null) model = await chatModel();
	else {
		const ref = given as Partial<ModelRef>;
		if (typeof ref.provider !== "string" || typeof ref.modelId !== "string") throw new Error("model must be { provider, modelId }");
		if (providers.models.getModel(ref.provider, ref.modelId) === undefined) throw new Error(`Unknown model: ${ref.provider}/${ref.modelId}`);
		model = { provider: ref.provider, modelId: ref.modelId };
		// Chosen for this chat, so the next one starts with it too, as it would after choosing it in the chat.
		settings.lastChatModel = model;
		saveSettings();
	}
	const now = Date.now();
	// The web starts as chat mode's setting says, and is the chat's own from then on.
	const web = chatSettings(settings.chat).web;
	const created = await harness.createConversation(
		{
			ownership: { kind: "ownerless" },
			agent: chatChange(model, web),
			init: async (tx, id) => {
				// No agent, and no tool access of an agent's: its tools are the assistant's own, none of which asks.
				(await tx.doc(Library)).conversations[String(id)] = { title: "", createdAt: now, updatedAt: now, access: "none", chat: true, ...(web ? {} : { web: false as const }) };
			},
		},
		context,
	);
	return { id: created.id };
}

/**
 * Continue with an Agent (#289, handover.ts): a new conversation of `agentId`, in `cwd` or the agent's own folder, whose
 * first message is chat `chatId` as it stands, with its pictures and files, and what the person typed. The chat is left
 * as it was; each is linked to the other on its record. The agent's access, approvals and Allow everything apply from
 * that first message, as in any conversation of its own.
 */
async function continueChat(params: Params): Promise<{ id: ConversationId }> {
	const shown = await conversation(params.id);
	const chatId = chatOf(shown.id);
	const meta = library.conversations[String(chatId)];
	if (!isChat(meta)) throw new Error("Only a chat can be continued with an agent");
	if (isDeleted(meta)) throw new Error("That chat was deleted");
	const agent = agents[String(params.agentId ?? "")];
	if (agent === undefined) throw new Error("Choose one of your agents to continue with");
	if (params.text !== undefined && typeof params.text !== "string") throw new Error("text must be text");
	const typed = typeof params.text === "string" ? params.text.trim() : "";
	let cwd = agent.cwd;
	if (params.cwd !== undefined && params.cwd !== null) {
		cwd = text(params, "cwd");
		if (!(existsSync(cwd) && statSync(cwd).isDirectory())) throw new Error(`Not a folder: ${cwd}`);
	}
	if (busyConversations.has(chatId)) throw new Error("The chat is still answering. Wait for it to finish, or stop it, then continue with an agent.");
	if (overBudget()) throw new Error(`Today's budget of $${settings.dailyBudget!.toFixed(2)} is used up. Raise it in Usage to carry on.`);

	// The chat as it stands: the version shown, with the history it was made from.
	const entries: EntryRecord[] = [];
	let cursor: unknown;
	for (;;) {
		const batch = await shown.entries({ order: "ascending" }, 500, cursor as never, context);
		entries.push(...batch.items);
		cursor = (batch as { next?: unknown }).next;
		if (cursor === undefined || batch.items.length === 0) break;
	}
	if (!entries.some((entry) => (entry.model?.[0] as { role?: string } | undefined)?.role === "user")) throw new Error("This chat has nothing in it yet to continue from");

	const change = { ...(await agentChange(agent, { subChat: false })), cwd };
	const model = change.model == null ? undefined : providers.models.getModel(change.model.provider, change.model.modelId);
	const handover = chatHandover(entries, { title: meta!.title, agent: agent.name, typed: typed !== "", seesPictures: model === undefined || model.input.includes("image") });
	const attachments = handoverAttachments(handover);
	const now = Date.now();
	const created = await harness.createConversation(
		{
			ownership: { kind: "ownerless" },
			agent: change,
			init: async (tx, id) => {
				const conversations = (await tx.doc(Library)).conversations;
				conversations[String(id)] = { title: meta!.title || "From a chat", createdAt: now, updatedAt: now, access: agent.access, agentId: agent.id, continuedFrom: chatId };
				const chat = conversations[String(chatId)];
				if (chat !== undefined) chat.continuedIn = [...(chat.continuedIn ?? []), id as unknown as number];
			},
		},
		context,
	);
	settings.lastAgent = agent.id;
	saveSettings();
	for (const feature of host.features) await feature.created?.(created.id as unknown as number, agent);
	const conv = (await harness.conversation(created.id, context))!;
	// Its own agent's Allow everything, and its own tools, as for any first message of a conversation of that agent.
	await takeSwitch(conv.id);
	await syncTools(conv).catch((error) => log("could not update the tools of conversation", created.id, error instanceof Error ? error.message : ""));
	await conv.submit({ type: "input", content: userContent(typed, attachments), entry: { kind: USER_ENTRY_KIND, data: userEntryData(typed, attachments) }, whenBusy: "followUp" }, context);
	for (const feature of host.features) feature.messageSent?.(created.id as unknown as number);
	return { id: created.id };
}

// ---- Requests

type Params = Record<string, unknown>;
const text = (params: Params, key: string): string => {
	const value = params[key];
	if (typeof value !== "string") throw new Error(`Missing ${key}`);
	return value;
};

const handlers: Record<string, (params: Params, client: Client) => Promise<unknown>> = {
	"engine.info": async () => ({ build, main: engineMain, pid: process.pid }),
	/** How late the engine's thread ran since the last time this was asked (lag.ts): for the load script. */
	"engine.lag": async () => lag.take(),
	"conversation.create": async (params) => {
		if (params.chat !== undefined && typeof params.chat !== "boolean") throw new Error("chat must be true or false");
		if (params.chat === true && params.agentId !== undefined) throw new Error("A chat has no agent: leave agentId out");
		if (params.chat === true) return createChat(params.model);
		const agent = agents[String(params.agentId ?? settings.lastAgent ?? "")] ?? Object.values(agents).sort((x, y) => x.createdAt - y.createdAt)[0];
		if (agent === undefined) throw new Error("There is no agent to start a conversation with");
		const change = await agentChange(agent, { subChat: false });
		const now = Date.now();
		const created = await harness.createConversation(
			{
				ownership: { kind: "ownerless" },
				agent: params.model !== undefined ? { ...change, model: params.model as ModelRef, thinkingLevel: (agent.thinkingLevel as never) ?? defaultThinking(params.model as ModelRef) } : change,
				init: async (tx, id) => {
					(await tx.doc(Library)).conversations[String(id)] = { title: "", createdAt: now, updatedAt: now, access: agent.access, agentId: agent.id };
				},
			},
			context,
		);
		settings.lastAgent = agent.id;
		saveSettings();
		for (const feature of host.features) await feature.created?.(created.id as unknown as number, agent);
		return { id: created.id };
	},
	/** `{ id, pinned }`: pin a conversation to the top of its list, or unpin it. A sub-chat goes with its conversation. */
	"conversation.pin": async (params) => {
		const conv = await conversation(params.id);
		if (typeof params.pinned !== "boolean") throw new Error("pinned must be true or false");
		const meta = library.conversations[String(chatOf(conv.id))];
		if (meta?.parent !== undefined) throw new Error("A sub-chat cannot be pinned on its own; pin the conversation it belongs to");
		if (isDeleted(meta)) throw new Error("That conversation was deleted");
		await editMeta(conv.id, (m) => {
			if (params.pinned === true) m.pinned = true;
			else delete m.pinned;
		});
		return {};
	},
	"conversation.open": async (params, client) => {
		await conversation(params.id);
		await subscribe(client, params.id as number);
		return {};
	},
	"conversation.close": async (params, client) => {
		const subscription = client.subscriptions.get(params.id as number);
		client.subscriptions.delete(params.id as number);
		await subscription?.stop();
		return {};
	},
	/**
	 * The conversations the app shows now: those open in its panes, and chat mode's current chat. Sent whenever that
	 * changes, and as it connects. A model on this Mac counts as used while a conversation using it is shown (localrun.ts).
	 */
	"conversations.shown": async (params, client) => {
		const ids = params.ids;
		if (!Array.isArray(ids) || ids.some((id) => !Number.isSafeInteger(id))) throw new Error("ids must be a list of conversation numbers");
		const shown = new Set(ids as number[]);
		if (shown.size === client.shown.size && [...shown].every((id) => client.shown.has(id))) return {};
		client.shown = shown;
		for (const feature of host.features) feature.shownChanged?.();
		return {};
	},
	"conversation.rename": async (params) => {
		const conv = await conversation(params.id);
		const title = text(params, "title").trim().slice(0, 120);
		await editMeta(conv.id, (meta) => {
			meta.title = title;
			meta.renamed = true;
		});
		return {};
	},
	"conversation.fork": async (params) => {
		const conv = await conversation(params.id);
		const source = library.conversations[String(chatOf(conv.id))];
		const now = Date.now();
		// The fork sees the conversation up to and including that entry, then goes its own way.
		const fork = await conv.fork(
			params.entryId as EntryId,
			{
				ownership: { kind: "ownerless" },
				init: async (tx, id) => {
					(await tx.doc(Library)).conversations[String(id)] = {
						title: `${source?.title || "Conversation"} (fork)`,
						createdAt: now,
						updatedAt: now,
						access: source?.access ?? "none",
						...(source?.agentId !== undefined ? { agentId: source.agentId } : {}),
						// A fork of a chat is a chat, with the assistant's tools, which the fork keeps, and its web switch.
						...(isChat(source) ? { chat: true as const } : {}),
						...(isChat(source) && source?.web === false ? { web: false as const } : {}),
					};
				},
			},
			context,
		);
		return { id: fork.id };
	},
	"conversation.compact": async (params) => {
		const instructions = typeof params.instructions === "string" && params.instructions.trim() !== "" ? params.instructions.trim() : undefined;
		const conv = await conversation(params.id);
		refuseIfPutAway(params.id as number);
		await conv.compact(instructions, context);
		return {};
	},
	"conversation.reset": async (params) => {
		const note = typeof params.note === "string" && params.note.trim() !== "" ? params.note.trim() : undefined;
		const conv = await conversation(params.id);
		refuseIfPutAway(params.id as number);
		await conv.reset(note, context);
		return {};
	},
	search: async (params) => {
		const query = text(params, "query").trim().toLowerCase();
		if (query.length < 2) return { results: [] };
		const results: { conversationId: number; title: string; entryId: number; role: string; snippet: string; archived: boolean; chat: boolean }[] = [];
		// Archived conversations are searched too: finding something again is what they are kept for.
		const ids = Object.entries(library.conversations)
			.filter(([, meta]) => !isDeleted(meta) && meta.parent === undefined)
			.sort(([, x], [, y]) => y.updatedAt - x.updatedAt)
			.map(([id]) => Number(id));
		for (const id of ids) {
			// A chat is searched as it is shown: its version shown.
			const conv = await conversation(id).catch(() => undefined);
			if (conv === undefined) continue;
			let cursor: unknown;
			// Newest first, at most 2,000 entries of each conversation.
			for (let page = 0; page < 10 && results.length < 40; page++) {
				const batch = await conv.entries({ order: "descending" }, 200, cursor as never, context);
				for (const entry of batch.items) {
					const message = entry.model?.[0] as { role?: string; content?: unknown } | undefined;
					if (message?.role !== "user" && message?.role !== "assistant") continue;
					const body = textOf(message.content, false);
					const at = body.toLowerCase().indexOf(query);
					if (at === -1) continue;
					const start = Math.max(0, at - 40);
					const snippet = (start > 0 ? "…" : "") + body.slice(start, at + query.length + 80).replace(/\s+/g, " ") + (at + query.length + 80 < body.length ? "…" : "");
					results.push({ conversationId: id, title: library.conversations[String(id)]?.title ?? "", entryId: entry.id as unknown as number, role: message.role, snippet, archived: isArchived(library.conversations[String(id)]), chat: isChat(library.conversations[String(id)]) });
					if (results.length >= 40) break;
				}
				cursor = (batch as { next?: unknown }).next;
				if (cursor === undefined) break;
			}
			if (results.length >= 40) break;
		}
		return { results };
	},
	"usage.setBudget": async (params) => {
		const daily = params.daily;
		if (daily !== null && !(typeof daily === "number" && Number.isFinite(daily) && daily > 0)) throw new Error("The budget must be an amount above zero, or off");
		settings.dailyBudget = daily as number | null;
		saveSettings();
		await refreshUsage();
		return {};
	},
	"providers.setHiddenModels": async (params) => {
		const id = text(params, "id");
		const available = (await providers.listModels()).filter((model) => model.provider === id).map((model) => model.id);
		if (available.length === 0) throw new Error("That provider has no models to choose from yet");
		const hidden = params.newest === true ? available.filter((model) => !newestOnly(available).has(model)) : params.hidden;
		if (!Array.isArray(hidden) || hidden.some((model) => typeof model !== "string")) throw new Error("hidden must be a list of model ids");
		settings.hiddenModels = { ...settings.hiddenModels, [id]: hidden as string[] };
		if (hidden.length === 0) delete settings.hiddenModels[id];
		saveSettings();
		// Answer first: asking every provider about its sign-in takes a moment, and the sheet is waiting.
		void announceProviders().catch((error) => log("announcing providers failed:", error));
		return { hidden };
	},
	"providers.draftModel": async (params) =>
		providers.draftModel(text(params, "provider"), text(params, "id"), {
			...(typeof params.basedOn === "string" ? { basedOn: params.basedOn } : {}),
			...(typeof params.api === "string" ? { api: params.api } : {}),
		}),
	"providers.addModel": async (params) => {
		const model = await providers.addModel(params as never);
		await announceProviders();
		scheduleUsageRefresh();
		return model;
	},
	"providers.ask": async (params) => {
		const listing = await providers.askProvider(text(params, "id"));
		// A refreshed catalog may hold new models, or ones that were added by hand.
		if (listing.refreshed) await announceProviders();
		return listing;
	},
	"providers.removeModel": async (params) => {
		providers.removeModel(text(params, "provider"), text(params, "id"));
		await announceProviders();
		scheduleUsageRefresh();
		return {};
	},
	/** The app offers to do computer actions for agents; only one app does at a time, the latest to ask. */
	"computer.register": async (_params, client) => {
		// The same connection offering twice is still one host.
		const host = computerHostOf.get(client) ?? { send: (message: unknown) => send(client, message) };
		computerHostOf.set(client, host);
		computer.register(host);
		computerClients.add(client);
		return {};
	},
	"computer.result": async (params) => {
		const image = params.image as { data?: unknown; mimeType?: unknown } | undefined;
		const answered = computer.answer(text(params, "requestId"), {
			ok: params.ok === true,
			text: typeof params.text === "string" ? params.text : "",
			...(typeof params.summary === "string" && params.summary !== "" ? { summary: params.summary } : {}),
			...(image !== undefined && typeof image.data === "string" && typeof image.mimeType === "string" ? { image: { data: image.data, mimeType: image.mimeType } } : {}),
		});
		return { answered };
	},
	/** The app offers its browser to agents; as with the computer, the latest app to ask does the work. */
	"browser.register": async (_params, client) => {
		const host = browserHostOf.get(client) ?? { send: (message: unknown) => send(client, message) };
		browserHostOf.set(client, host);
		browser.register(host);
		browserClients.add(client);
		return {};
	},
	"browser.result": async (params) => {
		const image = params.image as { data?: unknown; mimeType?: unknown } | undefined;
		const answered = browser.answer(text(params, "requestId"), {
			ok: params.ok === true,
			text: typeof params.text === "string" ? params.text : "",
			...(typeof params.summary === "string" && params.summary !== "" ? { summary: params.summary } : {}),
			...(image !== undefined && typeof image.data === "string" && typeof image.mimeType === "string" ? { image: { data: image.data, mimeType: image.mimeType } } : {}),
			...(typeof params.host === "string" ? { host: params.host } : {}),
			...(params.navigates === true ? { navigates: true } : {}),
		});
		return { answered };
	},
	"mcp.save": async (params) => {
		const saved = await mcp.save(params as never);
		return { id: saved.id };
	},
	"mcp.delete": async (params) => {
		await mcp.remove(text(params, "id"));
		return {};
	},
	"mcp.reconnect": async (params) => {
		await mcp.reconnect(text(params, "id"));
		return {};
	},
	/** Set or replace the value of one of a server's own variables (mcp.ts, #273), and start it again with it. */
	"mcp.setVariable": async (params) => {
		await mcp.setVariable(text(params, "id"), params.name, params.value);
		return {};
	},
	"mcp.removeVariable": async (params) => {
		await mcp.removeVariable(text(params, "id"), params.name);
		return {};
	},
	/** One picture of an entry: a screenshot in a tool result, or a picture the person attached to a message. */
	"conversation.image": async (params) => {
		const conv = await conversation(params.id);
		const entryId = params.entryId;
		if (typeof entryId !== "number") throw new Error("entryId must be a number");
		const page = await conv.entries({ minEntryId: entryId as never, maxEntryId: entryId as never }, 1, undefined, context);
		const message = page.items[0]?.model?.[0] as { content?: unknown } | undefined;
		const image = imagesOf(message?.content)[typeof params.index === "number" ? params.index : 0];
		if (image === undefined) throw new Error("That entry has no such picture");
		return image;
	},
	"conversation.export": async (params) => {
		const conv = await conversation(params.id);
		const meta = library.conversations[String(chatOf(conv.id))];
		const items: Item[] = [];
		let cursor: unknown;
		for (;;) {
			const batch = await conv.entries({ order: "ascending" }, 500, cursor as never, context);
			for (const entry of batch.items) {
				const item = toItem(entry);
				if (item !== undefined) items.push(item);
			}
			cursor = (batch as { next?: unknown }).next;
			if (cursor === undefined || batch.items.length === 0) break;
		}
		if (params.format === "json") return { text: JSON.stringify({ title: meta?.title ?? "", agent: agents[meta?.agentId ?? ""]?.name ?? null, chat: isChat(meta), exportedAt: new Date().toISOString(), items }, null, 2) };
		const agentName = agents[meta?.agentId ?? ""]?.name ?? "Assistant";
		const fence = "```";
		const clip = (value: string) => (value.length > 4000 ? `${value.slice(0, 4000)}\n… (${value.length - 4000} more characters)` : value);
		const results = new Map(items.flatMap((item) => (item.kind === "tool" ? [[item.callId, item] as const] : [])));
		const lines: string[] = [`# ${meta?.title || "Conversation"}`, ""];
		for (const item of items) {
			if (item.kind === "user") {
				lines.push("## You", "", item.text, "");
				const attached = describeAttachments(item.attachments, item.images);
				if (attached !== undefined) lines.push(`*${attached}*`, "");
			} else if (item.kind === "marker") lines.push(`*${item.text}*`, "");
			else if (item.kind === "setup") {
				// Its start is left out once its end is there, as the conversation shows it.
				const run = item.details.run;
				const ended = item.details.status === "running" && items.some((other) => other.kind === "setup" && other.details.run === run && other.details.status !== "running");
				if (!ended) lines.push(setupMarkdown(item.details), "");
			}
			else if (item.kind === "assistant") {
				lines.push(`## ${agentName}${item.stop === "aborted" || item.stop === "error" ? " (interrupted)" : ""}`, "");
				if (item.text !== "") lines.push(item.text, "");
				for (const call of item.toolCalls) {
					const result = results.get(call.callId);
					lines.push(`**Tool: ${call.name}**`, "");
					if ((result?.details as { allowedByEverything?: unknown } | null)?.allowedByEverything === true) lines.push("*Allowed by Allow everything.*", "");
					lines.push(`${fence}json`, JSON.stringify(call.arguments, null, 2), fence, "");
					if (result !== undefined) lines.push(result.isError ? "Result (error):" : "Result:", "", fence, clip(result.text), fence, "");
				}
			}
		}
		return { text: lines.join("\n") };
	},
	"settings.finishOnboarding": async () => {
		settings.onboarded = true;
		saveSettings();
		await announceProviders();
		return {};
	},
	"backup.create": async (params) => ({ path: await createBackup(home, text(params, "directory")) }),
	"conversation.archive": async (params) => {
		if (typeof params.id !== "number") throw new Error(`Unknown conversation: ${String(params.id)}`);
		await archiveConversation(params.id);
		return {};
	},
	"conversation.unarchive": async (params) => {
		const conv = await conversation(params.id);
		if (isDeleted(library.conversations[String(params.id)])) throw new Error("That conversation was deleted");
		await editMeta(conv.id, (meta) => void delete meta.archivedAt);
		return {};
	},
	/** Shown nowhere again. Its entries stay in the session file: pi durable cannot erase a conversation. */
	"conversation.delete": async (params) => {
		const conv = await conversation(params.id);
		await conv.abort(context);
		await editMeta(conv.id, (meta) => void (meta.deleted = true));
		return {};
	},
	"settings.getCompaction": async () => ({ defaultCompactionTokens: settings.defaultCompactionTokens ?? null }),
	"settings.setCompaction": async (params) => {
		settings.defaultCompactionTokens = validateCompactionTokens(params.defaultCompactionTokens);
		saveSettings();
		const event = compactionSettingsEvent();
		broadcast(event);
		return { defaultCompactionTokens: event.defaultCompactionTokens };
	},
	"settings.setAutoArchive": async (params) => {
		settings.autoArchiveDays = validateAutoArchive(params.days);
		saveSettings();
		broadcast(libraryEvent());
		// Chosen now, so applied now: the person sees what the setting does without waiting for the next check.
		await sweepArchive();
		return {};
	},
	/** Chat mode's settings (chat.ts): any of `instructions`, `defaultModel`, `web`, `memory`. Answers with all four. */
	"chat.set": async (params) => {
		const after = changeChatSettings(chatSettings(settings.chat), params, (model) => providers.models.getModel(model.provider, model.modelId) !== undefined);
		settings.chat = after;
		// A default chosen now counts from the next chat, over the model used last.
		if (params.defaultModel !== undefined) delete settings.lastChatModel;
		saveSettings();
		broadcast(chatEvent());
		// The web setting is where a new chat's web switch starts; chats already made keep their own (#287). The memory
		// switch changes what every chat is offered, from its next message (syncTools).
		return after;
	},
	/** Continue with an Agent (#289): `{ id, agentId, cwd?, text? }`, answered with the new conversation's `{ id }`. */
	"chat.continueWithAgent": async (params) => continueChat(params),
	"conversation.configure": async (params, client) => {
		const conv = await conversation(params.id);
		const id = chatOf(conv.id);
		const chat = isChat(library.conversations[String(id)]);
		// A chat has no folder and no tool access to choose: its tools are the assistant's (chat.ts).
		if (chat && params.cwd !== undefined) throw new Error("A chat has no folder");
		if (chat && params.access !== undefined) throw new Error("A chat's tools are fixed: it has no tool access to change");
		if (params.web !== undefined) {
			if (!chat) throw new Error("Only a chat has a web switch; an agent's tools are chosen in its settings");
			if (typeof params.web !== "boolean") throw new Error("web must be true or false");
			// Kept on the chat's record and counted from its next message, when its tools are brought in line (syncTools),
			// so an answer being written keeps the tools it started with.
			await editMeta(conv.id, (meta) => {
				if (params.web === false) meta.web = false;
				else delete meta.web;
			});
			for (const other of clients) other.subscriptions.get(id)?.push();
		}
		if (params.model !== undefined) {
			const model = params.model as ModelRef;
			if (providers.models.getModel(model.provider, model.modelId) === undefined) throw new Error(`Unknown model: ${model.provider}/${model.modelId}`);
			// A model on this Mac comes with its own thinking level when the conversation has none (defaultThinking).
			const thinking = params.thinkingLevel === undefined && ((await harness.snapshot(AgentDoc, conv.id, context))?.thinkingLevel ?? null) === null ? defaultThinking(model) : null;
			await conv.configure({ model: { provider: model.provider, modelId: model.modelId }, ...(thinking === null ? {} : { thinkingLevel: thinking }) }, context);
			rememberModel({ provider: model.provider, modelId: model.modelId }, chat);
			for (const feature of host.features) feature.modelChanged?.(id);
		}
		if (params.thinkingLevel !== undefined) await conv.configure({ thinkingLevel: params.thinkingLevel as never }, context);
		if (params.cwd !== undefined) {
			const cwd = params.cwd === null ? null : text(params, "cwd");
			if (cwd !== null && !(existsSync(cwd) && statSync(cwd).isDirectory())) throw new Error(`Not a folder: ${cwd}`);
			await conv.configure({ cwd }, context);
			for (const feature of host.features) feature.folderChanged?.(id);
		}
		if (params.access !== undefined) {
			const access = params.access as Access;
			if (!ACCESS_LEVELS.includes(access)) throw new Error(`Unknown access level: ${String(access)}`);
			const meta = library.conversations[String(id)];
			const own = agents[meta?.agentId ?? ""];
			const current = (await harness.snapshot(AgentDoc, conv.id, context))?.tools;
			await conv.configure({ tools: keepingOrder(current, toolsFor(access, own, isSubChat(meta))) }, context);
			await editMeta(conv.id, (meta) => void (meta.access = access));
			for (const other of clients) other.subscriptions.get(id)?.push();
		}
		void client;
		return {};
	},
	"conversation.carryOn": async (params) => {
		const conv = await conversation(params.id);
		const id = chatOf(conv.id);
		refuseIfPutAway(id);
		const { provider, modelId } = (params.model ?? {}) as Partial<ModelRef>;
		if (typeof provider !== "string" || typeof modelId !== "string") throw new Error("Choose a model to carry on with");
		const model = { provider, modelId };
		if (!(await usable(model))) throw new Error(`Model is not available: ${provider}/${modelId}`);
		const since = params.since;
		const scope = params.subChats === true ? { subChats: true as const } : typeof since === "number" ? { since } : undefined;
		if (scope === undefined) throw new Error("This run is no longer waiting for that limit");
		const carryOn = host.features.find((feature) => feature.carryOn !== undefined)?.carryOn;
		const switched = await carryOn?.(conv.id, model, scope);
		if (!switched?.length) throw new Error("No run is still waiting for a limit that can carry on with that model");
		rememberModel(model, isChat(library.conversations[String(id)]));
		for (const switchedId of switched) for (const feature of host.features) feature.modelChanged?.(chatOf(switchedId));
		return { switched };
	},
	submit: async (params) => {
		const conv = await conversation(params.id);
		refuseIfPutAway(params.id as number);
		const attachments = validateAttachments(params.attachments);
		// Attachments can be the whole message.
		const content = attachments.length > 0 && params.text === undefined ? "" : text(params, "text");
		if (content.trim() === "" && attachments.length === 0) throw new Error("The message is empty");
		if (attachments.some((attachment) => attachment.kind === "image")) {
			// Refused here, while the person can still change the model or the message. Sent anyway, the pictures would
			// be swapped for a note that they were left out, and the model would answer without having seen them.
			const ref = (await harness.snapshot(AgentDoc, conv.id, context))?.model;
			const model = ref === undefined ? undefined : providers.models.getModel(ref.provider, ref.modelId);
			if (model !== undefined && !model.input.includes("image")) throw new Error(`${model.name} cannot see pictures. Choose a model that can, or remove them.`);
		}
		if (overBudget()) throw new Error(`Today's budget of $${settings.dailyBudget!.toFixed(2)} is used up. Raise it in Usage to carry on.`);
		// The agent's settings may have changed since this conversation was set up.
		await takeSwitch(conv.id);
		await syncTools(conv).catch((error) => log("could not update the tools of conversation", params.id, error instanceof Error ? error.message : ""));
		const submission = await conv.submit(
			{
				type: "input",
				// With attachments the model is sent content blocks, and the entry records what the transcript shows.
				...(attachments.length === 0 ? { content } : { content: userContent(content, attachments), entry: { kind: USER_ENTRY_KIND, data: userEntryData(content, attachments) } }),
				whenBusy: params.mode === "steer" ? "steer" : "followUp",
				...(typeof params.requestId === "string" ? { requestId: params.requestId } : {}),
			},
			context,
		);
		// From here the message is kept, and the app is told so at once: nothing after this may make it look refused, or the
		// person, given the text back, would send it again (#344).
		try {
			for (const feature of host.features) feature.messageSent?.(params.id as number);
			// A message to steer ends the waits of calls that only wait, so that it reaches the agent now (heed.ts).
			if (params.mode === "steer") messageSent(conv.id as unknown as number);
		} catch (error) {
			log("after a message to conversation", params.id, "was kept:", error instanceof Error ? error.message : error);
		}
		await editMeta(conv.id, (meta) => {
			meta.updatedAt = Date.now();
			// A message that is only attachments is titled after the first of them.
			if (meta.title === "") meta.title = (content.trim().split("\n")[0] || attachments[0]?.name || "").slice(0, 60);
		}).catch((error) => log("could not note the message to conversation", params.id, error instanceof Error ? error.message : error));
		return { submissionId: submission.id };
	},
	abort: async (params) => {
		await (await conversation(params.id)).abort(context);
		for (const feature of host.features) feature.stopped?.(params.id as number);
		return {};
	},
	continue: async (params) => {
		const conv = await conversation(params.id);
		refuseIfPutAway(params.id as number);
		await takeSwitch(conv.id);
		await conv.submit({ type: "continue" }, context);
		return {};
	},
	/** Read one admitted message's durable outcome, not a previous run's idle state (test-copy send). */
	"submission.get": async (params) => {
		if (!Number.isSafeInteger(params.submissionId)) throw new Error("submissionId must be a number");
		const conv = await conversation(params.id);
		const submission = await harness.submission(params.submissionId as SubmissionId, context);
		if (submission === undefined) throw new Error("No such submission");
		const record = await submission.status(context);
		if (record.conversationId !== conv.id) throw new Error("That submission belongs to another conversation");
		const live = await harness.snapshot(LiveDoc, conv.id, context);
		return { submission: record, busy: live?.run !== undefined };
	},
	withdraw: async (params) => {
		const submission = await harness.submission(params.submissionId as SubmissionId, context);
		await submission?.abort(context);
		return {};
	},

	"agents.save": async (params) => saveAgent(params.agent as Partial<AgentProfile> | undefined),
	/**
	 * Allow everything on or off for an agent (#294). The app asks the person to confirm before it turns it on. Its
	 * conversations take the change at their next message (`takeSwitch`).
	 */
	"agents.allowEverything": async (params) => {
		const id = text(params, "id");
		if (typeof params.on !== "boolean") throw new Error("on must be true or false");
		const on = params.on;
		await harness.commit(async (tx) => {
			const agent = (await tx.doc(Agents)).agents[id];
			if (agent === undefined) throw new Error(`Unknown agent: ${id}`);
			if (on) agent.allowEverything = true;
			else delete agent.allowEverything;
		}, context);
		log("agent", id, on ? "now allows everything" : "no longer allows everything");
		return {};
	},
	"agents.duplicate": async (params) => {
		const sourceId = text(params, "id");
		const source = agents[sourceId];
		if (source === undefined) throw new Error(`Unknown agent: ${sourceId}`);
		const { id } = await saveAgent({ ...structuredClone(source), id: undefined, name: `${source.name} copy` }, structuredClone(source.commandRules ?? []));
		for (const feature of host.features) await feature.agentDuplicated?.(sourceId, id);
		return { id };
	},
	"agents.delete": async (params) => {
		const id = text(params, "id");
		if (agents[id] === undefined) throw new Error(`Unknown agent: ${id}`);
		if (Object.keys(agents).length === 1) throw new Error("Keep at least one agent");
		for (const feature of host.features) await feature.deletingAgent?.(id);
		await harness.commit(async (tx) => {
			const doc = await tx.doc(Agents);
			delete doc.agents[id];
			for (const other of Object.values(doc.agents)) other.delegates = other.delegates.filter((d) => d !== id);
		}, context);
		return {};
	},
	"schedules.save": async (params) => {
		const input = params.schedule as Partial<Schedule> | undefined;
		const title = typeof input?.title === "string" ? input.title.trim() : "";
		const prompt = typeof input?.prompt === "string" ? input.prompt.trim() : "";
		if (input === undefined || title === "") throw new Error("Give the schedule a name");
		if (prompt === "") throw new Error("Write what the agent should do");
		if (typeof input.agentId !== "string" || agents[input.agentId] === undefined) throw new Error("Choose an agent");
		const repeat = validateRepeat(input.repeat);
		const previous = input.id === undefined ? undefined : schedules[input.id];
		if (input.id !== undefined && previous === undefined) throw new Error(`Unknown schedule: ${input.id}`);
		const now = Date.now();
		const enabled = input.enabled ?? previous?.enabled ?? true;
		const next = nextRun(repeat, now);
		if (repeat.kind === "once" && next === null && enabled) throw new Error("That time has already passed");
		const id = input.id ?? `s${now.toString(36)}${Math.floor(Math.random() * 1e6).toString(36)}`;
		const schedule: Schedule = {
			id,
			title,
			agentId: input.agentId,
			prompt,
			repeat,
			enabled: enabled && next !== null,
			nextRunAt: next,
			lastRunAt: previous?.lastRunAt ?? null,
			lastConversationId: previous?.lastConversationId ?? null,
			pending: previous?.pending ?? null,
			createdAt: previous?.createdAt ?? now,
			// Who made it is kept through the person's edits; the app cannot set it.
			...(previous?.createdBy !== undefined ? { createdBy: previous.createdBy } : {}),
		};
		await harness.commit(async (tx) => void ((await tx.doc(Schedules)).schedules[id] = schedule), context);
		return { id };
	},
	"schedules.delete": async (params) => {
		const id = text(params, "id");
		await harness.commit(async (tx) => void delete (await tx.doc(Schedules)).schedules[id], context);
		return {};
	},
	"schedules.runNow": async (params) => {
		const id = text(params, "id");
		if (schedules[id] === undefined) throw new Error(`Unknown schedule: ${id}`);
		await fire(id, true);
		return { conversationId: schedules[id]?.lastConversationId ?? null };
	},
	"recovery.dismiss": async () => {
		recovery = null;
		broadcast(recoveryEvent());
		return {};
	},
	"inbox.decide": async (params) => {
		const decision = text(params, "decision");
		if (!["once", "always", "rule", "deny"].includes(decision)) throw new Error(`Unknown decision: ${decision}`);
		const id = text(params, "id");
		const item = inbox.get(id);
		if (item === undefined) throw new Error("That request is no longer waiting");
		// "rule" carries no words: the rule is the one the engine offered with the request.
		if (decision === "rule" && item.rule === undefined) throw new Error("No rule can be made from that request");
		if (!inbox.answer(id, decision)) throw new Error("That request is no longer waiting");
		return {};
	},
	/** A rule typed in an agent's settings: `command` is its words, such as "npm test". */
	"rules.add": async (params) => {
		const agentId = text(params, "agentId");
		if (agents[agentId] === undefined) throw new Error(`Unknown agent: ${agentId}`);
		const folder = text(params, "folder");
		if (!isAbsolute(folder) || !(existsSync(folder) && statSync(folder).isDirectory())) throw new Error(`Not a folder: ${folder}`);
		return { rule: await addCommandRule(agentId, folder, wordsOf(text(params, "command"))) };
	},
	"rules.remove": async (params) => {
		const words = params.words;
		if (!Array.isArray(words) || words.some((word) => typeof word !== "string")) throw new Error("words must be a list of words");
		await removeCommandRule(text(params, "agentId"), text(params, "folder"), words as string[]);
		return {};
	},
	"inbox.answer": async (params) => {
		const answer = text(params, "text");
		if (answer.trim() === "") throw new Error("The answer is empty");
		if (!inbox.answer(text(params, "id"), answer)) throw new Error("That question is no longer waiting");
		return {};
	},

	"providers.setKey": async (params) => {
		await providers.setKey(text(params, "id"), text(params, "key"));
		await announceProviders();
		return {};
	},
	"providers.logout": async (params) => {
		await providers.logout(text(params, "id"));
		await announceProviders();
		return {};
	},
	"providers.login": async (params, client) => {
		const loginId = `login-${nextLocalId++}`;
		const abort = new AbortController();
		logins.set(loginId, abort);
		send(client, { event: "auth", loginId, kind: "started", providerId: params.id });
		try {
			await providers.login(text(params, "id"), {
				signal: abort.signal,
				notify: (event: AuthEvent) => send(client, { event: "auth", loginId, kind: "notify", notice: event }),
				prompt: (prompt: AuthPrompt) =>
					new Promise<string>((resolve, reject) => {
						const promptId = `prompt-${nextLocalId++}`;
						const { signal, ...shown } = prompt;
						const done = () => pendingPrompts.delete(promptId);
						pendingPrompts.set(promptId, (answer) => (done(), resolve(answer)));
						const cancel = () => (done(), send(client, { event: "auth", loginId, kind: "promptClosed", promptId }), reject(new Error("Cancelled")));
						signal?.addEventListener("abort", cancel, { once: true });
						abort.signal.addEventListener("abort", cancel, { once: true });
						send(client, { event: "auth", loginId, kind: "prompt", promptId, prompt: shown });
					}),
			});
			await announceProviders();
			return {};
		} finally {
			logins.delete(loginId);
			send(client, { event: "auth", loginId, kind: "finished" });
		}
	},
	"auth.answer": async (params) => {
		pendingPrompts.get(text(params, "promptId"))?.(text(params, "value"));
		return {};
	},
	"auth.cancel": async (params) => {
		logins.get(text(params, "loginId"))?.abort();
		return {};
	},

	"endpoints.probe": async (params) => ({ models: await providers.probeEndpoint(text(params, "baseUrl"), params.key as string | undefined) }),
	"endpoints.save": async (params) => {
		const saved = await providers.saveEndpoint(params as never);
		await announceProviders();
		return { id: saved.id };
	},
	"endpoints.remove": async (params) => {
		await providers.removeEndpoint(text(params, "id"));
		await announceProviders();
		return {};
	},
};
// Try Again, Edit, and stepping between a chat's versions (versions.ts).
Object.assign(
	handlers,
	versionRequests({
		harness,
		context,
		library: () => library.conversations,
		versions: () => versions,
		busy: (id) => working.has(id),
		mayStart: (id) => {
			refuseIfPutAway(id);
			if (overBudget()) throw new Error(`Today's budget of $${settings.dailyBudget!.toFixed(2)} is used up. Raise it in Usage to carry on.`);
		},
		modelExists: (model) => providers.models.getModel(model.provider, model.modelId) !== undefined,
		syncTools: (conv) => syncTools(conv).catch((error) => log("could not update the tools of conversation", conv.id, error instanceof Error ? error.message : "")),
		touched: (id) => editMeta(id as unknown as ConversationId, (meta) => void (meta.updatedAt = Date.now())),
	}),
);
// Requests that features answer.
for (const feature of host.features) {
	for (const [method, handler] of Object.entries(feature.handlers ?? {})) handlers[method] = (params) => handler(params);
}

// ---- Live indexes: the library document and which conversations have work running

// The document must exist before it can be watched; this creates it on a first launch.
await harness.commit(async (tx) => void (await tx.doc(Library)), context);
const libraryWatch = await harness.watchDoc(Library, context);
if (libraryWatch === undefined) throw new Error("The library document could not be opened");
/**
 * Which conversations are put away, and which of those are deleted, as one string: when it changes, open conversations
 * are told their new standing. Deleting an archived conversation changes it too, so that what goes with a deleted one
 * (its kept outputs, its scratch folder) goes then.
 */
const putAway = () =>
	Object.entries(library.conversations)
		.filter(([, meta]) => isPutAway(meta))
		.map(([id, meta]) => (isDeleted(meta) ? `${id}d` : id))
		.join(",");
let wasPutAway = putAway();
libraryWatch.start(async (call) => {
	if (call.kind !== "value") return;
	library = call.value;
	broadcast(libraryEvent());
	broadcast(inboxEvent()); // titles shown in the inbox come from here
	const now = putAway();
	if (now !== wasPutAway) {
		wasPutAway = now;
		for (const client of clients) for (const subscription of client.subscriptions.values()) subscription.push();
		for (const feature of host.features) feature.putAwayChanged?.();
	}
});

// Which version each chat shows: an open chat follows it (versions.ts).
await harness.commit(async (tx) => void (await tx.doc(Versions)), context);
const versionsWatch = await harness.watchDoc(Versions, context);
if (versionsWatch === undefined) throw new Error("The versions document could not be opened");
versions = versionsWatch.value;
versionsWatch.start(async (call) => {
	if (call.kind !== "value") return;
	versions = call.value;
	for (const client of clients) for (const subscription of client.subscriptions.values()) void subscription.follow().then(() => subscription.push());
});

// Agents: created with three starters on a first launch, then whatever the person makes of them.
await harness.commit(async (tx) => {
	const doc = await tx.doc(Agents);
	if (Object.keys(doc.agents).length === 0) for (const agent of starterAgents(Date.now())) doc.agents[agent.id] = agent;
}, context);
const agentsWatch = await harness.watchDoc(Agents, context);
if (agentsWatch === undefined) throw new Error("The agents document could not be opened");
agents = agentsWatch.value.agents;
agentsWatch.start(async (call) => {
	if (call.kind !== "value") return;
	agents = call.value.agents;
	broadcast(agentsEvent());
	broadcast(inboxEvent());
});
// Features start once the conversations and agents are loaded, before any schedule is armed: what one writes into a
// transcript as it starts (a background command the last engine left, a set-up cut short) sets the last engine's
// work going again at once, before `resume()`.
for (const feature of host.features) await feature.start?.();
// Recovery has dealt with recorded runs. Unrecorded files can go only once nothing holds them.
void sweepRuns().catch((error) => log("run files could not be tidied:", error));
const graphWatch = await harness.watchTaskGraph(context);
type Graph = { tasks: Record<string, { conversationId?: unknown }> };
/** The conversation `id` belongs to: itself, or the one whose sub-chat it is. */
const rootOf = (id: number): number => library.conversations[String(id)]?.parent ?? id;
const conversationsWithWork = (graph: Graph) => new Set(Object.values(graph.tasks).map((task) => task.conversationId as number));
working = conversationsWithWork(graphWatch.value as never);
/** When each conversation's current work was first seen, for "running for…" in the app. */
const since = new Map<number, number>();
const refreshBusy = () => {
	const now = Date.now();
	for (const id of working) if (!since.has(id)) since.set(id, now);
	for (const id of [...since.keys()]) if (!working.has(id)) since.delete(id);
	busyConversations = new Set([...working].map(rootOf));
};
refreshBusy();
// A wait the last engine noted for a run that has since ended (it stopped between the two) is let go.
for (const feature of host.features) feature.runsChanged?.(working);

/** What is running right now, one row per conversation with live work; subagents point at their parent. */
function activityEvent() {
	const waiting = new Set(inbox.list().map((item) => item.conversationId));
	const runs = [...working]
		.map((id) => {
			// A chat's version shows as the chat, which is what the app can open.
			const shown = chatOf(id);
			const meta = library.conversations[String(shown)];
			return {
				conversationId: shown,
				parent: meta?.parent ?? null,
				rootConversationId: rootOf(id),
				title: meta?.title ?? "",
				agentId: meta?.agentId ?? null,
				// A chat answering is shown as a chat, not as an agent's work.
				chat: isChat(meta),
				status: waiting.has(id) ? "waiting" : "working",
				since: since.get(id) ?? Date.now(),
				// What features add (a wait for a provider's limit, say).
				...Object.assign({}, ...host.features.map((feature) => feature.activity?.(id) ?? {})),
				// Its shell commands running in the foreground, with their clocks (running.ts).
				commands: runningCommands.of(id),
			};
		})
		.sort((x, y) => x.since - y.since);
	return { event: "activity", runs };
}

// ---- Recovery: what an engine that starts after a crash found and picked up

/** The conversations that were working and were picked up, and what features add (background commands, say). */
type Recovery = { at: number; conversations: { id: number; title: string }[]; [feature: string]: unknown };
let recovery: Recovery | null = stoppedUncleanly
	? {
			...Object.assign({}, ...host.features.map((feature) => feature.recovery?.() ?? {})),
			at: Date.now(),
			conversations: [...new Set([...working].map(rootOf))].map((id) => ({ id, title: library.conversations[String(id)]?.title ?? "", chat: isChat(library.conversations[String(id)]) })),
		}
	: null;
const recoveryEvent = () => ({ event: "recovery", recovery });

graphWatch.start(async (call) => {
	if (call.kind !== "value") return;
	const before = working;
	working = conversationsWithWork(call.value as never);
	refreshBusy();
	for (const feature of host.features) feature.runsChanged?.(working);
	const changed = before.size !== working.size || [...working].some((id) => !before.has(id));
	if (changed) broadcast(libraryEvent());
	announceActivity();
	scheduleUsageRefresh();
});
// A command starting or ending changes its row in the conversation, which the live document may already have shown
// without its clock; its output reaches the conversation on its own, and only Activity needs telling of it.
runningCommands.onChange = (id, why) => {
	if (why !== "printed") engine.stateChanged(id);
	announceActivity();
};

// ---- MCP servers: their tools are one extension, replaced whenever a server connects or drops

const mcpEvent = () => ({ event: "mcp", servers: mcp.list() });
mcp.onChange = () => {
	mcpTools = mcp.extension();
	registry.install(mcpTools);
	broadcast(mcpEvent());
};

// ---- Usage: totals from pi durable's own counters, plus a per-day ledger for "today" and budgets

const Spend = defineDoc<{ days: Record<string, { cost: number; tokens: number }>; lastCost: number; lastTokens: number }>({
	kind: "pi2.spend",
	version: 1,
	scope: "session",
	initial: () => ({ days: {}, lastCost: 0, lastTokens: 0 }),
	checkpointWhen: () => true,
});
const dayKey = (at = new Date()) => `${at.getFullYear()}-${String(at.getMonth() + 1).padStart(2, "0")}-${String(at.getDate()).padStart(2, "0")}`;
let usageSummary: Record<string, unknown> = { event: "usage", models: [], agents: [], chats: { cost: 0, tokens: 0 }, conversations: [], total: { cost: 0, tokens: 0 }, today: { cost: 0, tokens: 0 }, days: [], budget: { daily: null }, overBudget: false };
let todayCost = 0;
const overBudget = () => typeof settings.dailyBudget === "number" && todayCost >= settings.dailyBudget;

async function refreshUsage(): Promise<void> {
	subscriptions = await providers.subscriptionProviders();
	const session = (await harness.usage(context)) as UsageDocShape;
	const total = usageTotals(session);
	// Whatever was spent since the last look belongs to today.
	const spend = await harness.commit(async (tx) => {
		const doc = await tx.doc(Spend);
		// The total only falls when usage stops being priced (a provider now on a subscription); take that back off today.
		const delta = { cost: total.cost - doc.lastCost, tokens: Math.max(0, total.tokens - doc.lastTokens) };
		if (delta.cost !== 0 || delta.tokens > 0) {
			// Create the day, then read it back: only the document's own copy records changes.
			doc.days[dayKey()] ??= { cost: 0, tokens: 0 };
			const day = doc.days[dayKey()]!;
			day.cost = Math.max(0, day.cost + delta.cost);
			day.tokens += delta.tokens;
			doc.lastCost = total.cost;
			doc.lastTokens = total.tokens;
		}
		// A plain copy: the document itself is only readable inside this commit.
		return { days: JSON.parse(JSON.stringify(doc.days)) as Record<string, { cost: number; tokens: number }> };
	}, context);
	const today = spend.days[dayKey()] ?? { cost: 0, tokens: 0 };
	todayCost = today.cost;

	const byAgent = new Map<string, { cost: number; tokens: number }>();
	// Chats are the built-in assistant's, not an agent's: counted on their own.
	const chats = { cost: 0, tokens: 0 };
	const byConversation: { id: number; title: string; cost: number; tokens: number; chat: boolean }[] = [];
	for (const [id, meta] of Object.entries(library.conversations)) {
		const usage = usageTotals((await harness.snapshot(UsageDoc, Number(id) as unknown as ConversationId, context)) as UsageDocShape | undefined);
		if (usage.tokens === 0) continue;
		const agent = isChat(meta) ? chats : (byAgent.get(meta.agentId ?? "") ?? { cost: 0, tokens: 0 });
		agent.cost += usage.cost;
		agent.tokens += usage.tokens;
		if (!isChat(meta)) byAgent.set(meta.agentId ?? "", agent);
		// A subagent's spend is shown under the conversation that started it.
		const root = meta.parent ?? Number(id);
		const row = byConversation.find((r) => r.id === root);
		if (row !== undefined) {
			row.cost += usage.cost;
			row.tokens += usage.tokens;
		} else if (!isPutAway(library.conversations[String(root)])) {
			byConversation.push({ id: root, title: library.conversations[String(root)]?.title ?? "", ...usage, chat: isChat(library.conversations[String(root)]) });
		}
	}
	usageSummary = {
		event: "usage",
		models: Object.entries(session.models ?? {})
			.map(([key, usage]) => ({ key, input: usage.input ?? 0, output: usage.output ?? 0, tokens: usage.totalTokens ?? 0, cost: costOf(key, usage), subscription: onSubscription(key), unpriced: unpriced(key) }))
			.sort((x, y) => y.tokens - x.tokens),
		agents: [...byAgent].map(([agentId, usage]) => ({ agentId, ...usage })).sort((x, y) => y.tokens - x.tokens),
		chats,
		conversations: byConversation.sort((x, y) => y.cost - x.cost || y.tokens - x.tokens).slice(0, 8),
		total,
		today,
		days: Object.entries(spend.days).sort(([x], [y]) => x.localeCompare(y)).slice(-14).map(([day, usage]) => ({ day, ...usage })),
		budget: { daily: settings.dailyBudget ?? null },
		overBudget: overBudget(),
	};
	broadcast(usageSummary);
	for (const feature of host.features) feature.usageChanged?.();
}
let usageTimer: ReturnType<typeof setTimeout> | undefined;
/** Usage changes when work ends; recount shortly after, once, however many tasks finished together. */
const scheduleUsageRefresh = () => {
	clearTimeout(usageTimer);
	usageTimer = setTimeout(() => void refreshUsage().catch((error) => log("usage refresh failed:", error)), 400);
};
await refreshUsage();

// Providers whose list the library refreshes itself (pi-ai's models.refresh()) are asked for it, in the background.
void providers
	.refreshCatalogs()
	.then(async (errors) => {
		for (const [id, error] of errors) log(`refreshing ${id}'s list of models failed: ${plainProviderError(error.message)}`);
		await announceProviders();
	})
	.catch((error) => log("refreshing the providers' lists of models failed:", error));

// ---- Schedules

await harness.commit(async (tx) => void (await tx.doc(Schedules)), context);
const schedulesWatch = await harness.watchDoc(Schedules, context);
if (schedulesWatch === undefined) throw new Error("The schedules document could not be opened");
let schedules = schedulesWatch.value.schedules;
const schedulesEvent = () => ({ event: "schedules", schedules: Object.values(schedules).sort((x, y) => x.createdAt - y.createdAt) });
let scheduleTimer: ReturnType<typeof setTimeout> | undefined;
const firing = new Set<string>();

/** Submit the prompt of a run whose conversation exists. The request ID makes doing this twice harmless. */
async function deliver(id: string): Promise<void> {
	const schedule = schedules[id];
	const pending = schedule?.pending;
	if (schedule === undefined || pending == null) return;
	const conv = await harness.conversation(pending.conversationId as unknown as ConversationId, context);
	if (conv !== undefined) await takeSwitch(conv.id);
	await conv?.submit({ type: "input", content: schedule.prompt, requestId: `schedule:${id}:${pending.runAt}` }, context);
	await harness.commit(async (tx) => {
		const current = (await tx.doc(Schedules)).schedules[id];
		if (current?.pending?.runAt === pending.runAt) current.pending = null;
	}, context);
}

/** Start one run of a schedule: a new conversation with its agent, then its prompt. */
async function fire(id: string, manual: boolean): Promise<void> {
	const schedule = schedules[id];
	if (schedule === undefined || firing.has(id)) return;
	firing.add(id);
	try {
		const agent = agents[schedule.agentId] ?? Object.values(agents).sort((x, y) => x.createdAt - y.createdAt)[0];
		if (agent === undefined) return;
		const change = await agentChange(agent, { subChat: false });
		const now = Date.now();
		const due = schedule.nextRunAt;
		await harness.createConversation(
			{
				ownership: { kind: "ownerless" },
				agent: change,
				// The conversation and the schedule's bookkeeping are one commit: a crash leaves both or neither.
				init: async (tx, conversationId) => {
					const current = (await tx.doc(Schedules)).schedules[id];
					if (current === undefined || (!manual && current.nextRunAt !== due)) throw new Error("The schedule changed while it was starting");
					(await tx.doc(Library)).conversations[String(conversationId)] = { title: current.title, createdAt: now, updatedAt: now, access: agent.access, agentId: agent.id };
					current.pending = { conversationId: conversationId as unknown as number, runAt: now };
					current.lastRunAt = now;
					current.lastConversationId = conversationId as unknown as number;
					if (!manual) {
						// Runs missed while the engine was off are not replayed one by one: the next run is in the future.
						current.nextRunAt = nextRun(current.repeat, now);
						if (current.nextRunAt === null) current.enabled = false;
					}
				},
			},
			context,
		);
		schedules = (await harness.snapshot(Schedules, context))?.schedules ?? schedules;
		await deliver(id);
	} catch (error) {
		log("schedule", id, "did not start:", error instanceof Error ? error.message : error);
	} finally {
		firing.delete(id);
	}
}

function armSchedules(): void {
	clearTimeout(scheduleTimer);
	const due = Object.values(schedules).filter((x) => x.enabled && x.nextRunAt !== null);
	if (due.length === 0) return;
	const next = Math.min(...due.map((x) => x.nextRunAt!));
	// setTimeout cannot wait longer than about 24 days; waking early and re-arming is harmless.
	// While the budget is used up a due run stays due; look again in a minute rather than spinning.
	const soonest = overBudget() ? 60_000 : 0;
	scheduleTimer = setTimeout(() => void tickSchedules(), Math.min(Math.max(next - Date.now(), soonest), 2_000_000_000));
}

async function tickSchedules(): Promise<void> {
	const now = Date.now();
	for (const schedule of Object.values(schedules)) {
		if (schedule.pending !== null) await deliver(schedule.id).catch((error) => log("schedule", schedule.id, "delivery failed:", error));
		else if (schedule.enabled && schedule.nextRunAt !== null && schedule.nextRunAt <= now) {
			// Out of budget: the run stays due and starts once there is budget again.
			if (overBudget()) log("schedule", schedule.id, "is waiting: today's budget is used up");
			else await fire(schedule.id, false);
		}
	}
	armSchedules();
}

schedulesWatch.start(async (call) => {
	if (call.kind !== "value") return;
	schedules = call.value.schedules;
	broadcast(schedulesEvent());
	armSchedules();
});

// ---- Socket server

rmSync(socketPath, { force: true }); // a socket file a killed engine left behind
const server = createServer((socket) => {
	const client: Client = { socket, subscriptions: new Map(), shown: new Set() };
	clients.add(client);
	send(client, libraryEvent());
	send(client, agentsEvent());
	send(client, inboxEvent());
	send(client, activityEvent());
	send(client, schedulesEvent());
	send(client, recoveryEvent());
	send(client, usageSummary);
	send(client, mcpEvent());
	send(client, chatEvent());
	send(client, compactionSettingsEvent());
	for (const feature of host.features) for (const event of feature.greeting?.() ?? []) send(client, event);
	void providersEvent().then((event) => send(client, event));
	// A message with pictures is one line of many megabytes, arriving in small chunks. The chunks of an unfinished line
	// are kept apart and joined once, at its end: searching one growing string for the line break would copy all of it
	// again for every chunk, seconds of work during which nothing else is answered.
	const unfinished: string[] = [];
	socket.setEncoding("utf8");
	socket.on("data", (chunk: string) => {
		let start = 0;
		for (let newline = chunk.indexOf("\n"); ; newline = chunk.indexOf("\n", start)) {
			if (newline === -1) {
				if (start < chunk.length) unfinished.push(chunk.slice(start));
				break;
			}
			unfinished.push(chunk.slice(start, newline));
			const line = unfinished.join("");
			unfinished.length = 0;
			start = newline + 1;
			if (line.trim() === "") continue;
			let request: { id?: unknown; method?: unknown; params?: Params };
			try {
				request = JSON.parse(line);
			} catch {
				send(client, { id: null, error: "Invalid JSON" });
				continue;
			}
			const handler = handlers[String(request.method)];
			if (handler === undefined) {
				send(client, { id: request.id, error: `Unknown method: ${String(request.method)}` });
				continue;
			}
			handler(request.params ?? {}, client).then(
				(result) => send(client, { id: request.id, result }),
				(error: unknown) => send(client, { id: request.id, error: error instanceof Error ? error.message : String(error) }),
			);
		}
	});
	const drop = () => {
		if (!clients.delete(client)) return;
		if (computerClients.delete(client)) computer.unregister(computerHostOf.get(client));
		if (browserClients.delete(client)) browser.unregister(browserHostOf.get(client));
		for (const subscription of client.subscriptions.values()) void subscription.stop();
		// An app that quits closes its panes: what they showed is no longer shown (docs/local-models-running.md).
		if (client.shown.size > 0) for (const feature of host.features) feature.shownChanged?.();
	};
	socket.on("close", drop);
	socket.on("error", drop);
});
// Nothing an agent or an MCP server starts may run before the PATH is the person's own, or, if their shell is too slow
// to wait for, has the usual folders. The shell is then still listened to, and its PATH taken when it comes.
const stillListening = await pathReady;
// The last wait of start-up: from here on a stop is the ordinary one. One asked for while starting is done now, in place
// of listening, and before anything is marked ready; stop() ends the process, so nothing below runs.
phase = "running";
if (stopWhenStarted) await stop();
// Tool calls the last engine left, or anything started early, are decided only from here on (see `Host.ready`).
markReady();
server.listen(socketPath, () => {
	log(`listening on ${socketPath}`);
	harness.resume(); // continue any run the last process left unfinished
	void tickSchedules(); // and start whatever came due while the engine was not running
	void mcp.start(); // connect to MCP servers without holding up the app
});
// MCP servers run as programs are started just above, so on a start where the login shell was too slow they get the
// usual folders. When its PATH is taken they are started again with it, without cutting off a call (issue #98). One
// not started yet by then gets it anyway, and if the PATH did not change nothing is started again.
void stillListening?.done.then(() => mcp.followPath());

// Conversations left unused for as long as the person chose are archived: a little after start-up, once what was
// running has had time to show as running, and then a few times a day.
const sweepSoon = setTimeout(() => void sweepArchive(), 2 * 60_000);
const sweepOften = setInterval(() => void sweepArchive(), 6 * 3_600_000);
sweepSoon.unref();
sweepOften.unref();

// A clean stop closes the Harness. SIGKILL is the crash case and needs no handler: reopening recovers. SIGINT and
// SIGTERM come here through askToStop, near the top, and only once start-up is done, so everything below exists; the
// server may never have listened, if the stop came while starting.
async function stop(): Promise<void> {
	if (stopping) return;
	stopping = true;
	// Measure here, not around the signal in another process: that process may not get to run when this one exits.
	// Scheduling delays inside this stop still count, just as they do toward the app's five-second restore deadline.
	const began = performance.now();
	stopLoginShell.abort(); // a shell too slow for start-up and still being listened to
	server.close();
	for (const client of clients) client.socket.destroy();
	clearTimeout(scheduleTimer);
	clearTimeout(usageTimer);
	// What features left running (background commands) goes with the engine.
	await Promise.all(host.features.map((feature) => feature.stopping?.().catch((error) => log("a feature did not stop cleanly:", error instanceof Error ? error.message : error))));
	await mcp.stop();
	await harness.close(context);
	rmSync(socketPath, { force: true });
	rmSync(runningMarker, { force: true });
	log(`stopped cleanly in ${Math.ceil(performance.now() - began)} ms`);
	process.exit(0);
}
