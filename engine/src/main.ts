// pi2-engine: hosts one pi durable Harness on SQLite and serves it to the app over a Unix socket.
// Wire format: one JSON object per line. Requests are { id, method, params } and are answered { id, result } or
// { id, error }; the methods are the keys of `handlers` below. The engine also pushes { event, ... } messages:
// "library", "providers", "conversation" (for opened conversations) and "auth" (during a sign-in).

import { randomBytes, randomUUID, timingSafeEqual } from "node:crypto";
import { existsSync, lstatSync, mkdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { connect, createServer } from "node:net";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import {
	type AgentChange,
	AgentDoc,
	AssistantEntry,
	type Conversation,
	type ConversationId,
	type Cursor,
	createRegistry,
	type EntryId,
	type EntryRecord,
	Harness,
	LiveDoc,
	type SubmissionId,
	type Tx,
	UsageDoc,
} from "@earendil-works/pi-durable";
import { CodemodeSandbox } from "@earendil-works/pi-codemode";
import { NodeExecutionEnv } from "@earendil-works/pi-durable/env/node";
import { openNodeSqliteStorage } from "@earendil-works/pi-durable/storage/sqlite/node";
import { createNodePhotonImages } from "@earendil-works/pi-durable/images/node";
import { createCodingTools } from "@earendil-works/pi-durable/tools";
import { USER_ENTRY_KIND, userContent, userEntryData, validateAttachments } from "./attachments.ts";
import { createBackup, restoreBackup } from "./backup.ts";
import { appBundle, AppCheck, checkRequestClasses, personOnly } from "./answers.ts";
import { backgroundForSubChat, hasRunningCommands } from "./background.ts";
import { bashForSubChat } from "./commands.ts";
import { BrowserHost } from "./browser.ts";
import { BUILT_IN_TOOLS, chatToolNames, toolsLeftOut } from "./builtins.ts";
import { type ChatSettings, changeChatSettings, chatSettings, isChat } from "./chat.ts";
import { chatHandover, handoverAttachments } from "./handover.ts";
import { codemodeExtension } from "./codemode.ts";
import { automaticCompactionReady, compactionCheckpoint, earlyCompaction, RETENTION_INSTRUCTIONS, SUMMARY_TOKENS, summaryThinking, validateCompactionTokens } from "./compaction.ts";
import { holdingPlaces } from "./sections.ts";
import { credentialStore } from "./credentials.ts";
import { type Host, pi2Extension } from "./extensions.ts";
import { type Engine, FEATURES } from "./features.ts";
import { carriedProjectFor } from "./carryover.ts";
import { duration, noticingRefusals } from "./limitwait.ts";
import { retryLocalEngine } from "./localrun.ts";
import { NETWORK_RESUMED_ENTRY, type NetworkWait, retryNetwork, transportFailureOf } from "./networkwait.ts";
import { promptCacheLifetimes } from "./cache.ts";
import { retryThinking } from "./thinkingretry.ts";
import { subChatUsage } from "./subchatusage.ts";
import { messageSent } from "./heed.ts";
import { preparedTool } from "./stringargs.ts";
import { textOf } from "./transcript.ts";
import { broadcast, type Client, clients, coalesced, send } from "./clients.ts";
import { dirtyUsage, overBudget, refreshUsage, repriceUsage, scheduleUsageRefresh, Spend, type UsageDocShape, usageById, usageRowsChanged, usageSummary, usageTimer, usageTotals, wireUsage } from "./usage.ts";
import { checkPersonStart, type Params, startConfirmation, text } from "./requests.ts";
import { providerRequests, wireProviderRequests } from "./providerrequests.ts";
import { addCommandRule, agentRequests, saveAgent, wireAgentRequests } from "./agentrequests.ts";
import { conversationRequests, wireConversationEvents } from "./conversationevents.ts";
import { armSchedules, scheduleRequests, schedulesEvent, scheduleTimer, setSchedules, tickSchedules, wireSchedules } from "./scheduleruns.ts";
import { agents, busyConversations, chatOf, conversationsWithWork, isSubChat, library, refreshBusy, rootOf, setAgents, setLibrary, setVersions, setWorking, since, versions, working } from "./indexes.ts";
import { McpServers } from "./mcp.ts";
import { claim } from "./needs.ts";
import { ComputerHost, hasApps } from "./computer.ts";
import { plainProviderError } from "./providererror.ts";
import { DEMO_MODEL, DEMO_PROVIDER, defaultThinking, LOCAL_PROVIDER, Providers } from "./providers.ts";
import { Schedules } from "./schedules.ts";
import { socketPathFor } from "./socket.ts";
import { timeLines } from "./log.ts";
import { LagMonitor } from "./lag.ts";
import { adoptLoginPath } from "./shellpath.ts";
import { runningCommands } from "./running.ts";
import { sweepRuns, useRunFolder } from "./processes.ts";
import { dueForArchive, isArchived, isDeleted, isPutAway, migrateDeleted, validateAutoArchive } from "./archive.ts";
import { versionRequests, Versions } from "./versions.ts";
import { type Access, ACCESS_LEVELS, type AgentProfile, agentOf, Agents, Inbox, Library, type Meta, type ModelRef, projectFrom, runsAs, starterAgents, takeAgentSwitch } from "./state.ts";
import { allProjects, inProject, type Project, PROJECT_ARCHIVED, PROJECT_DELETED, projectDeleted, projectOf, refuseInArchivedProject, refuseStartWith } from "./projects.ts";
import { orchestratorConversation, orchestratorRole, placeInput, refuseEarlier, tellOrchestrator } from "./orchestrator.ts";
import { wireProjectSpend } from "./projectlimits.ts";
import { conversationSpend, dayKey, noSpend } from "./projectspend.ts";
import { refusal } from "./requesterror.ts";
import { delegateTargets } from "./projectagents.ts";
import { syncWorkForInput } from "./work.ts";
import { engineBuild, ignoredLine, ignoredTestSwitches, testSwitch } from "./testswitches.ts";

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
const build = engineBuild;

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
// Once, at start: a release engine names the test-only switches it was given and ignores (testswitches.ts).
const ignoredSwitches = ignoredTestSwitches();
if (ignoredSwitches.length > 0) log(ignoredLine(ignoredSwitches));
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
/**
 * The default model for agents as `defaultModel` last worked it out, for what is decided inside a commit, where the
 * providers are not asked (`followedModel`). Worked out again whenever the providers or the settings change, and as
 * each app connects.
 */
let defaultNow: ModelRef = { provider: DEMO_PROVIDER, modelId: DEMO_MODEL };
let markReady = () => {};

const host: Host = {
	ready: new Promise<void>((resolve) => (markReady = resolve)),
	inbox,
	computer,
	browser,
	scratchFolder: () => workspace,
	changesThings: (name) => mcp.changesThings(name),
	agent: (id) => (id === undefined ? undefined : agents[id]),
	// A chat's version is the chat, as for `meta`.
	agentOf: (id) => agentOf(library.conversations[String(chatOf(id))], agents),
	delegatesOf: (id) => delegateTargets(agentOf(library.conversations[String(chatOf(id))], agents), agents, chatOf(id)),
	allowAlways: (id, tool) =>
		editMeta(id, (meta) => {
			if (!meta.autoApprove?.includes(tool)) meta.autoApprove = [...(meta.autoApprove ?? []), tool];
		}),
	addRule: (agentId, folder, words) =>
		addCommandRule(agentId, folder, words).then(
			() => {},
			(error) => log("could not save the allowed command:", error instanceof Error ? error.message : error),
		),
	agentChange: (agent, options) => agentChange(agent, options),
	sendToChat: async (id, content, requestId, prepare) => {
		const conv = await harness.conversation(id as unknown as ConversationId, context);
		if (conv === undefined) return undefined;
		await takeSwitch(conv.id);
		await syncTools(conv).catch(() => {});
		if (prepare !== undefined) return harness.commit(async (tx) => {
			// A completed admission is a replay, not a new start to check against today's limit.
			const earlier = await tx.submissionByRequest(conv.id, requestId);
			if (earlier !== undefined) return earlier.id as number;
			const meta = (await tx.doc(Library)).conversations[String(id)];
			if (meta === undefined) return undefined;
			const { model } = await tx.doc(AgentDoc, conv.id);
			if (!await prepare(tx, meta, model)) return undefined;
			const submission = await conv.submit(tx, { type: "input", content, requestId });
			meta.updatedAt = Date.now();
			meta.subChatTask = Math.max(meta.subChatTask ?? 0, submission as number);
			return submission as number;
		}, context);
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
	pictureModel: () => settings.pictureModel ?? null,
	setPictureModel: (model) => {
		settings.pictureModel = model;
		saveSettings();
	},
	lookModel: () => settings.lookModel ?? null,
	setLookModel: (model) => {
		settings.lookModel = model;
		saveSettings();
	},
	providers: () => providers,
	waitingOnThePerson: () => new Set(inbox.list().map((item) => item.conversationId)),
	setting: (key) => settings[key],
	saveSetting: (key, value) => {
		(settings as Record<string, unknown>)[key] = value;
		saveSettings();
	},
	saveAgent: (input, options) => saveAgent(input, options),
	busy: (id) => working.has(id),
	// A chat on screen shows its current version (versions.ts).
	shown: () => new Set([...clients].flatMap((client) => [...client.shown].map((id) => versions.chats[String(id)]?.current ?? id))),
	apps: () => clients.size,
	stateChanged: (id) => {
		for (const client of clients) (client.subscriptions.get(id) ?? client.subscriptions.get(chatOf(id)))?.push();
	},
	activityChanged: () => announceActivity(),
	libraryChanged: () => broadcast(libraryEvent()),
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
 * `conversation` is the conversation's id, undefined for one not made yet: in a project, whom it may hand work to
 * depends on which conversation it is (projectagents.ts, `delegateTargets`).
 */
function toolsFor(access: Access, agent: AgentProfile | undefined, subChat: boolean, where: { conversationId?: number; projectId?: string | null; model?: ModelRef | null } = {}) {
	const files = access === "none" ? [] : access === "read" ? ["read"] : ["read", "write", "edit", "bash"];
	const extras = [...(agent?.codeMode ? ["codemode"] : []), ...mcp.toolNames(agent?.mcpServers ?? [])];
	// Reference files can be read whatever the access level: the person chose them for this agent.
	const reference = (agent?.files?.length ?? 0) > 0 ? ["read_reference"] : [];
	// Computer use with no app allowed could only refuse; the tool comes with the first app the person allows (#177), or
	// with test copies of pi² allowed, or with Allow everything, under which any app may be used (#294).
	const screen = hasApps(agent?.computer, agent?.allowEverything === true) ? ["computer"] : [];
	const web = agent?.browser?.enabled === true ? ["browser"] : [];
	const added = host.features.flatMap((feature) => feature.toolNames?.(access, agent, { subChat, ...where }) ?? []);
	const delegate = !subChat && delegateTargets(agent, agents, where.conversationId).length > 0;
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
async function agentChange(agent: AgentProfile, options: { subChat: boolean; projectId?: string | null; model?: ModelRef }): Promise<AgentChange> {
	// The model the conversation starts with: the person's choice where `conversation.create` was given one, else the
	// agent's own, else the default for agents as it is now (#617): an agent with no model of its own follows it.
	const own = agent.model !== null && providers.models.getModel(agent.model.provider, agent.model.modelId) !== undefined;
	const model = options.model ?? (own ? agent.model! : await defaultModel());
	const onDefault = options.model === undefined && !own;
	return {
		model,
		thinkingLevel: (agent.thinkingLevel as never) ?? ((onDefault ? defaultModelThinking(model) : defaultThinking(model)) as never),
		instructions: agent.instructions.trim() === "" ? null : agent.instructions,
		tools: toolsFor(agent.access, agent, options.subChat, { projectId: options.projectId, model }),
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
			// An argument sent as a JSON string where its tool's schema says an array or an object is read as the value it
			// encodes (#572, src/stringargs.ts), for every tool alike: this is the one place every resolved tool passes
			// through, before pi durable checks the call's arguments, and it changes no declaration the model is sent.
			const readStrings = (tool: (typeof agent.tools)[number]) => preparedTool(id, tool);
			const withStringsRead = { ...agent, tools: agent.tools.map(readStrings), callable: agent.callable.map(readStrings) };
			// A sub-chat is one from its first request. Read committed metadata even during crash recovery, before the
			// library watch has caught up; choosing by anything transient would resend tool definitions mid-conversation.
			if (!isSubChat((await read.snapshot(Library, context))?.conversations[String(id)])) return withStringsRead;
			const forSubChat = (tool: (typeof agent.tools)[number]) =>
				tool.name === "bash" ? bashForSubChat(tool) : tool.name === "background" ? backgroundForSubChat(tool) : tool;
			return { ...withStringsRead, tools: withStringsRead.tools.map(forSubChat), callable: withStringsRead.callable.map(forSubChat) };
		},
		// Local engine stops, network outages and provider limits use pi-durable's stored retry sleep (see patch-dependencies.ts).
		// The features are read at every use, so they are made by then.
		settings: {
			compaction: {
				early: (id: ConversationId, window: number, policy: import("@earendil-works/pi-durable").CompactionPolicy) => {
					const meta = library.conversations[String(id)];
					if (meta === undefined || isChat(meta)) return undefined;
					return earlyCompaction(agentOf(meta, agents)?.compactionTokens ?? settings.defaultCompactionTokens, window, policy);
				},
				instructions: RETENTION_INSTRUCTIONS,
				checkpoint: compactionCheckpoint,
				summaryTokens: SUMMARY_TOKENS,
				summaryThinking: (model: Parameters<typeof summaryThinking>[0]) => summaryThinking(model, providers.reportedThinking(model)),
				automaticReady: automaticCompactionReady,
			} as import("@earendil-works/pi-durable").CompactionSettings,
			// As an input is placed, a project's orchestrator is told what changed first (orchestrator.ts; a patch to pi
			// durable, scripts/patch-inputs.ts). It does nothing anywhere else. An input that starts a run of a project's
			// conversation takes its agent's model and thinking level first (`followAgent`).
			placeInput: async (tx, id, now) => {
				await followAgent(tx, id as unknown as number);
				await placeInput(tx, id as unknown as number, now);
			},
			retry: {
				host: (message: Parameters<typeof retryLocalEngine>[0], attempt: number, id: unknown, localRetries = 0, network?: NetworkWait, now = Date.now()) => {
					const local = retryLocalEngine(message, localRetries, home);
					const feature = host.features.find((candidate) => candidate.retry !== undefined);
					const limit = feature?.retry?.(message, attempt, id as number);
					if (local !== undefined) return local;
					const spent = (limit?.spent ?? 0) + (network?.count ?? 0);
					// A stream the provider closed is waited out as a network that is away is (#550), and the conversation is
					// told which of the two it was; a provider that asked for less begins at the longer waits.
					const failure = message?.provider === LOCAL_PROVIDER ? undefined : transportFailureOf(message);
					if (failure !== undefined) return { ...retryNetwork(network, now, undefined, failure), spent };
					return { ...limit, spent };
				},
				recovered: (wait: NetworkWait, now: number) => ({ kind: NETWORK_RESUMED_ENTRY, data: { text: `${wait.closed === true ? "The provider answered again." : "The network is back."} Carried on after waiting ${duration(now - wait.since)}.` } }),
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
	/** The model last picked in an agent conversation's toolbar: the default for agents while none is chosen in Settings. */
	defaultModel?: ModelRef;
	/**
	 * The default model for agents the person chose in Settings › General (#617), with the thinking level it runs at
	 * (null for the model's own default). Absent: the model last picked in a conversation, as before.
	 */
	agentDefault?: { model: ModelRef; thinkingLevel: string | null };
	dailyBudget?: number | null;
	onboarded?: boolean;
	deviceId?: string;
	hiddenModels?: Record<string, string[]>;
	autoArchiveDays?: number | null;
	defaultCompactionTokens?: number | null;
	/** Chat mode's settings (chat.ts); read through `chatSettings`, which gives the defaults for what is missing. */
	chat?: ChatSettings;
	pictureModel?: ModelRef | null;
	/** The model that looks at pictures for one that cannot see them (#540, picturelook.ts); null until the person picks. */
	lookModel?: ModelRef | null;
	/** The model last chosen in a chat, apart from `defaultModel`, the agent view's. */
	lastChatModel?: ModelRef;
	/**
	 * The projects preview switch of the versions before #483 took it out. Read by nothing now; written `true` once by
	 * the update's carrying over (carryover.ts), so the last version with the switch shows projects if someone goes back.
	 */
	projects?: { preview: boolean };
	/** Keeping this Mac awake while agents work (keepawake.ts); read through `awakeSettings`. Absent means on, and not on battery. */
	awake?: { keep: boolean; battery: boolean };
} = (() => {
	try {
		return JSON.parse(readFileSync(settingsPath, "utf8"));
	} catch {
		return {};
	}
})();
const saveSettings = () => writeFileSync(settingsPath, JSON.stringify(settings, null, "\t"));
const compactionSettingsEvent = () => ({ event: "compactionSettings", defaultCompactionTokens: settings.defaultCompactionTokens ?? null });
// What the files moved out of this one use of it (#753), handed over as soon as it all exists.
wireUsage({ harness, context, settings, providers, host, log, stopping: () => stopping });
wireSchedules({ harness, context, log, host, takeSwitch, syncTools, agentChange });
wireProviderRequests({ providers, settings, saveSettings, announceProviders, log });
wireAgentRequests({ harness, context, log, host });
wireConversationEvents({ providers, host, context, log, conversation, followedModel, chatWeb });

/** A random ID for this installation, made the first time a sign-in asks for one and the same ever after. */
function deviceId(): string {
	if (settings.deviceId === undefined) {
		settings.deviceId = randomUUID();
		saveSettings();
	}
	return settings.deviceId;
}

setVersions((await harness.snapshot(Versions, context)) ?? { chats: {} });

/** A conversation the app names by its id. A chat with several versions is the version it shows. */
async function conversation(id: unknown): Promise<Conversation> {
	const shown = typeof id === "number" ? (versions.chats[String(id)]?.current ?? id) : undefined;
	const found = shown === undefined ? undefined : await harness.conversation(shown as unknown as ConversationId, context);
	if (found === undefined) throw new Error(`Unknown conversation: ${String(id)}`);
	return found;
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
	const own = agentOf(meta, agents);
	if (meta === undefined) return;
	// An agent that was deleted or removed keeps its setup, except work, which follows the project.
	if (own === undefined && !isChat(meta)) {
		if (meta.projectId !== undefined) await harness.commit((tx) => syncWorkForInput(tx, conv.id, meta), context);
		return;
	}
	const agent = await harness.snapshot(AgentDoc, conv.id, context);
	const current = agent?.tools;
	const wanted = keepingOrder(current, isChat(meta) ? chatTools(chatWeb(id)) : toolsFor(meta.access, own, isSubChat(meta), { conversationId: id, model: agent?.model }));
	const names = wanted.map((t) => t!.name);
	if (Array.isArray(current) && current.length === names.length && current.every((name, index) => name === names[index])) return;
	await conv.configure({ tools: wanted }, context);
	for (const client of clients) client.subscriptions.get(chatOf(id))?.push();
}

/**
 * The model and thinking level a conversation of a project takes from the agent it runs as (state.ts, `runsAs`) at its
 * next message (docs/projects.md, 3.4): the agent's own model while its provider offers it, else the default model for
 * agents as it is now, and the agent's thinking level, else that model's own, as a conversation is made with
 * (`agentChange`). Undefined for a conversation that keeps the model it has: a chat, one in no project (a deleted
 * project's), one of an archived project, an archived or deleted one, an earlier conversation with a project's
 * orchestrator, one whose agent was deleted or removed, and one given a model of its own through the socket (`ownModel`).
 */
function followedModel(id: number, meta: Meta | undefined): { model: ModelRef; thinkingLevel: string | null } | undefined {
	if (meta === undefined || meta.ownModel === true || isChat(meta) || meta.version === true || isPutAway(meta)) return undefined;
	if (meta.parent !== undefined && isPutAway(library.conversations[String(meta.parent)])) return undefined;
	const project = inProject(id);
	if (project === undefined || project.earlier.includes(id)) return undefined;
	const agent = agentOf(meta, agents);
	if (agent === undefined) return undefined;
	const own = agent.model !== null && providers.models.getModel(agent.model.provider, agent.model.modelId) !== undefined;
	const model = own ? agent.model! : defaultNow;
	return { model, thinkingLevel: agent.thinkingLevel ?? (own ? defaultThinking(model) : defaultModelThinking(model)) };
}

/**
 * In commit `tx`, conversation `id` takes its agent's model and thinking level (`followedModel`) when it is not working:
 * a run under way finishes on the model it has, so a model chosen with the limit banner's Carry on with… holds until
 * the run ends. Called as an input is placed (the `placeInput` setting), which is every message, wake and queued input
 * that starts a run, and as the person's message or Continue is taken (`takeModel`). Returns whether it changed.
 */
async function followAgent(tx: Tx, id: number): Promise<boolean> {
	const wanted = followedModel(id, (await tx.doc(Library)).conversations[String(id)]);
	if (wanted === undefined) return false;
	const conversationId = id as unknown as ConversationId;
	if ((await tx.doc(LiveDoc, conversationId)).run !== undefined) return false;
	const agent = await tx.doc(AgentDoc, conversationId);
	if (sameModel(agent.model, wanted.model) && (agent.thinkingLevel ?? null) === wanted.thinkingLevel) return false;
	agent.model = { ...wanted.model };
	if (wanted.thinkingLevel === null) delete agent.thinkingLevel;
	else agent.thinkingLevel = wanted.thinkingLevel as never;
	return true;
}

/**
 * Before a message is taken: conversation `id` takes its agent's model and thinking level (`followAgent`), so that its
 * tools (`syncTools`, which offer `look` to a model that cannot see) and the checks on the message go by that model.
 */
async function takeModel(id: ConversationId): Promise<void> {
	if (followedModel(id as unknown as number, library.conversations[String(id)]) === undefined) return;
	if (!(await harness.commit((tx) => followAgent(tx, id as unknown as number), context))) return;
	for (const feature of host.features) feature.modelChanged?.(id as unknown as number);
}

/**
 * What `followedModel` says may have changed for some conversations (an agent saved, the default model for agents
 * changed): the apps showing one of them are sent its state again, which says the model its next message runs on.
 */
function followersChanged(): void {
	for (const client of clients) {
		for (const [id, subscription] of client.subscriptions) if (followedModel(id, library.conversations[String(id)]) !== undefined) subscription.push();
	}
}

/**
 * A message is about to be sent to conversation `id`: it takes its agent's model and thinking level (`takeModel`) and
 * its own agent's Allow everything switch as it is now (state.ts, `takeAgentSwitch`). Every way a message reaches a
 * conversation calls this first: the person's (`submit`, `continue`), a schedule's (`deliver`) and an agent's
 * continuing a sub-chat (`sendToChat`); `delegate` sets a new sub-chat's from its own agent as it makes it.
 */
async function takeSwitch(id: ConversationId): Promise<void> {
	await takeModel(id);
	const known = library.conversations[String(id)];
	if (known !== undefined && (known.allowEverything === true) === (agentOf(known, agents)?.allowEverything === true)) return;
	await harness.commit(async (tx) => {
		const meta = (await tx.doc(Library)).conversations[String(id)];
		if (meta !== undefined) takeAgentSwitch(meta, agentOf(meta, agents));
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

// ---- Clients

/** Whether a connection is the app's, which alone may answer or make changes for the person (answers.ts, #504, #513). */
const appCheck = new AppCheck(appBundle(engineMain, build, process.env), log);

/** Whether `client` may act for the person — answer what waits, or change what the person set — and why. */
async function mayAnswer(client: Client): Promise<{ allowed: boolean; why: string }> {
	if (client.testCopy === true) return { allowed: true, why: "this connection gave the test copy's key" };
	const verdict = await appCheck.verdict(client.socket);
	return { allowed: verdict.app, why: verdict.why };
}
/** Clients that registered as the computer host; the host object is kept per client so the right one is dropped. */
const computerClients = new Set<Client>();
const computerHostOf = new WeakMap<Client, { send: (message: unknown) => void }>();
/** The same for the browser: the app holds the web views, and offers to work them for agents. */
const browserClients = new Set<Client>();
const browserHostOf = new WeakMap<Client, { send: (message: unknown) => void }>();

const announceActivity = coalesced(() => activityEvent());

setLibrary((await harness.snapshot(Library, context)) ?? { conversations: {} });
// Conversations deleted before there was an archive are marked the new way, once.
if (Object.values(library.conversations).some((meta) => meta.archived !== undefined)) {
	await harness.commit(async (tx) => void migrateDeleted((await tx.doc(Library)).conversations), context);
	setLibrary((await harness.snapshot(Library, context)) ?? { conversations: {} });
}

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
			// The project it belongs to (projects.ts), archived or not.
			projectId: meta.projectId ?? null,
			// The agent it runs as now (state.ts, `runsAs`): its `agentId`, but for a conversation carried over.
			runsAs: runsAs(meta, agents) ?? null,
			// A project's current or earlier conversation with its orchestrator (orchestrator.ts), or null.
			orchestrator: orchestratorRole(Number(id)),
			// The conversation with the orchestrator this one was started fresh from.
			freshFrom: meta.freshFrom ?? null,
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
			projectId: meta.projectId ?? null,
		}))
		.sort((a, b) => b.archivedAt - a.archivedAt);
	return { event: "library", conversations, archived, autoArchiveDays: settings.autoArchiveDays ?? null };
}

/**
 * What the conversations carried over run as now, as one string. It changes without the library changing when a
 * project's copy of an agent is removed or put back: the apps are then sent the library, and
 * Activity, again. Only a conversation with a `projectAgentId` can run as anything but its `agentId` (state.ts, `runsAs`).
 */
const runsAsNow = () =>
	Object.entries(library.conversations)
		.filter(([, meta]) => meta.projectAgentId !== undefined)
		.map(([id, meta]) => `${id}:${runsAs(meta, agents) ?? ""}`)
		.join(",");
let runsAsSent = runsAsNow();
function runsAsChanged(): void {
	const now = runsAsNow();
	if (now === runsAsSent) return;
	runsAsSent = now;
	broadcast(libraryEvent());
	announceActivity();
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
			agentName: agentOf(meta, agents)?.name ?? null,
			rootConversationId: root,
			rootTitle: library.conversations[String(root)]?.title ?? "",
		};
	});
	return { event: "inbox", items };
}
/** Send the Inbox again, and tell the features that show it (Needs you, needs.ts). */
function announceInbox() {
	broadcast(inboxEvent());
	for (const feature of host.features) feature.inboxChanged?.();
}
inbox.onChange = () => {
	announceInbox();
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
	// A provider signed out, or a model switched off, can make the default for agents fall back, or come back.
	broadcast(await agentDefaultEvent());
	// Signing in or out changes which usage has a price.
	repriceUsage();
	scheduleUsageRefresh();
	for (const feature of host.features) feature.providersChanged?.();
}

/**
 * The model an agent with none of its own starts a conversation on: the one chosen in Settings › General (#617) while
 * its provider offers it and it is not switched off; else the one last picked in a conversation, if still usable; else
 * the demo model.
 */
async function defaultModel(): Promise<ModelRef> {
	const chosen = settings.agentDefault?.model;
	const model =
		chosen !== undefined && !hiddenModel(chosen) && (await usable(chosen))
			? chosen
			: settings.defaultModel !== undefined && (await usable(settings.defaultModel))
				? settings.defaultModel
				: { provider: DEMO_PROVIDER, modelId: DEMO_MODEL };
	if (!sameModel(model, defaultNow)) {
		defaultNow = model;
		followersChanged();
	}
	return model;
}

const hiddenModel = (model: ModelRef) => settings.hiddenModels?.[model.provider]?.includes(model.modelId) === true;
const sameModel = (a: ModelRef | null | undefined, b: ModelRef | null | undefined) => a?.provider === b?.provider && a?.modelId === b?.modelId;

/** The thinking level of a conversation on the default model: the one chosen with it in Settings, else the model's own. */
function defaultModelThinking(model: ModelRef): string | null {
	const chosen = settings.agentDefault;
	return chosen !== undefined && chosen.thinkingLevel !== null && sameModel(chosen.model, model) ? chosen.thinkingLevel : defaultThinking(model);
}

/**
 * Settings › General's default model for agents (#617): what was chosen (null for the model used last), and the model a
 * conversation of an agent with none of its own starts on now, which differs from the choice when it fell back.
 */
async function agentDefaultEvent() {
	const chosen = settings.agentDefault ?? null;
	const using = await defaultModel();
	return { event: "agentDefault", model: chosen?.model ?? null, thinkingLevel: chosen?.thinkingLevel ?? null, using, fellBack: chosen !== null && !sameModel(chosen.model, using) };
}

/** A choice in a conversation's model menu counts for future conversations, too. */
function rememberModel(model: ModelRef, chat: boolean): void {
	if (chat) settings.lastChatModel = model;
	else settings.defaultModel = model;
	saveSettings();
	// While no default for agents is chosen in Settings, this is it: the app shows it for each agent with no model of its own.
	if (!chat) void announceDefault().catch((error) => log("announcing the default model failed:", error instanceof Error ? error.message : error));
}

/** The default model for agents, as the providers event and Settings › General show it. */
async function announceDefault(): Promise<void> {
	broadcast(await providersEvent());
	broadcast(await agentDefaultEvent());
	// The thinking level chosen with the default model can change without the model changing.
	followersChanged();
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

/** Start a chat with pi²'s built-in assistant (chat.ts), on `model` if given, else on the model a new chat starts with. */
async function createChat(given: unknown, client: Client): Promise<{ id: ConversationId }> {
	let model: ModelRef;
	if (given === undefined || given === null) model = await chatModel();
	else {
		const ref = given as Partial<ModelRef>;
		if (typeof ref.provider !== "string" || typeof ref.modelId !== "string") throw new Error("model must be { provider, modelId }");
		if (providers.models.getModel(ref.provider, ref.modelId) === undefined) throw new Error(`Unknown model: ${ref.provider}/${ref.modelId}`);
		model = { provider: ref.provider, modelId: ref.modelId };
		// A script may choose this chat's model, but may not change which model the person's next chat starts with.
		if ((await mayAnswer(client)).allowed) rememberModel(model, true);
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
 * Continue with an Agent (#289, handover.ts): chat `chatId` as it stands, with its pictures and files, and what the
 * person typed, handed to an agent as a message from the person, in project `projectId` (#654): to its orchestrator, unless
 * `agentId` names another of its agents, in the orchestrator's present conversation (the project's one conversation with
 * it, made if it has none yet); to another agent, in a new conversation of that agent in the project. The chat is left as
 * it was; it links to the conversation, and a new conversation links back to it. The agent's access, approvals and
 * Allow everything apply from that message, as in any conversation of its own.
 */
async function continueChat(params: Params): Promise<{ id: ConversationId; note?: string }> {
	const shown = await conversation(params.id);
	const chatId = chatOf(shown.id);
	const meta = library.conversations[String(chatId)];
	if (!isChat(meta)) throw new Error("Only a chat can be continued with an agent");
	if (isDeleted(meta)) throw new Error("That chat was deleted");
	if (params.text !== undefined && typeof params.text !== "string") throw new Error("text must be text");
	const typed = typeof params.text === "string" ? params.text.trim() : "";
	const project = projectToContinueIn(params);
	const agent = agents[String(params.agentId ?? project.orchestratorId)];
	if (agent === undefined || agent.removedAt !== undefined) throw new Error("Choose one of the project's agents to continue with");
	if (agent.projectId !== project.id) throw new Error(`${agent.name} is not an agent of ${project.name}`);
	// A project's agents work in its folder (3.3).
	if (params.cwd !== undefined && params.cwd !== null) throw new Error("A project's agents work in its folder: leave cwd out");
	const cwd = agent.cwd;
	const confirm = startConfirmation(params);
	refuseStartWith(agent);
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

	if (agent.id === project.orchestratorId) return { id: await handOverToOrchestrator(project.id, agent, chatId, meta!.title, entries, typed) };
	const change = { ...(await agentChange(agent, { subChat: false })), cwd };
	const model = change.model == null ? undefined : providers.models.getModel(change.model.provider, change.model.modelId);
	const handover = chatHandover(entries, { title: meta!.title, agent: agent.name, typed: typed !== "", seesPictures: model === undefined || model.input.includes("image") });
	const attachments = handoverAttachments(handover);
	let note: string | undefined;
	const now = Date.now();
	const created = await harness.createConversation(
		{
			ownership: { kind: "ownerless" },
			agent: change,
			init: async (tx, id) => {
				note = await checkPersonStart(tx, agent, change.model, confirm, { from: chatId, version: shown.id, through: entries.at(-1)?.id ?? null, cwd }, typed);
				const conversations = (await tx.doc(Library)).conversations;
				conversations[String(id)] = { title: meta!.title || "From a chat", createdAt: now, updatedAt: now, access: agent.access, agentId: agent.id, continuedFrom: chatId, ...projectFrom(agent) };
				const chat = conversations[String(chatId)];
				if (chat !== undefined) chat.continuedIn = [...(chat.continuedIn ?? []), id as unknown as number];
			},
		},
		context,
	);
	for (const feature of host.features) await feature.made?.(created.id as unknown as number);
	for (const feature of host.features) await feature.created?.(created.id as unknown as number, agent);
	const conv = (await harness.conversation(created.id, context))!;
	// Its own agent's Allow everything, and its own tools, as for any first message of a conversation of that agent.
	await takeSwitch(conv.id);
	await syncTools(conv).catch((error) => log("could not update the tools of conversation", created.id, error instanceof Error ? error.message : ""));
	await conv.submit({ type: "input", content: userContent(typed, attachments), entry: { kind: USER_ENTRY_KIND, data: userEntryData(typed, attachments) }, whenBusy: "followUp" }, context);
	for (const feature of host.features) feature.messageSent?.(created.id as unknown as number);
	return { id: created.id, ...(note === undefined ? {} : { note }) };
}

/**
 * The project a chat is continued in (#654): `projectId`, or the project of `agentId` when that names one of a project's
 * agents; a template is refused, since a project's agents are what a chat goes to.
 */
function projectToContinueIn(params: Params): Project {
	const id = params.projectId ?? agents[String(params.agentId ?? "")]?.projectId;
	if (id === undefined || id === null) throw new Error("Choose a project to continue in");
	if (typeof id !== "string") throw new Error("projectId must be a project's id");
	const project = allProjects()[id];
	if (project === undefined || project.deletedAt !== undefined) throw new Error(`Unknown project: ${id}`);
	if (project.archivedAt !== undefined) throw new Error(PROJECT_ARCHIVED);
	return project;
}

/**
 * Continue with an Agent to a project's orchestrator (#654): the handover goes into its present conversation as a message
 * from the person, taken as the hub's message field takes one (steering a turn under way), with the catch-up in front of
 * it as for any input there (6.4). A project has one conversation with its orchestrator, so no second one is made; one is
 * made only when the project has none yet, as the hub makes it. The chat links to it; it does not link back, since it
 * was not begun from the chat.
 */
async function handOverToOrchestrator(projectId: string, agent: AgentProfile, chatId: number, title: string, entries: EntryRecord[], typed: string): Promise<ConversationId> {
	const id = await orchestratorConversation(projectId);
	const conv = await conversation(id);
	refuseIfPutAway(id);
	const ref = (await harness.snapshot(AgentDoc, conv.id, context))?.model;
	const model = ref == null ? undefined : providers.models.getModel(ref.provider, ref.modelId);
	const handover = chatHandover(entries, { title, agent: agent.name, typed: typed !== "", seesPictures: model === undefined || model.input.includes("image") });
	const attachments = handoverAttachments(handover);
	await takeSwitch(conv.id);
	await syncTools(conv).catch((error) => log("could not update the tools of conversation", id, error instanceof Error ? error.message : ""));
	await harness.commit(async (tx) => {
		await conv.submit(tx, { type: "input", content: userContent(typed, attachments), entry: { kind: USER_ENTRY_KIND, data: userEntryData(typed, attachments) }, whenBusy: "steer" });
		const conversations = (await tx.doc(Library)).conversations;
		const chat = conversations[String(chatId)];
		if (chat !== undefined && !(chat.continuedIn ?? []).includes(id)) chat.continuedIn = [...(chat.continuedIn ?? []), id];
		const orchestrator = conversations[String(id)];
		if (orchestrator !== undefined) {
			orchestrator.updatedAt = Date.now();
			// Titled as a message the person sends is, if nothing has titled it yet.
			if (orchestrator.title === "") orchestrator.title = (typed.split("\n")[0] || attachments[0]?.name || "").slice(0, 60);
		}
	}, context);
	try {
		for (const feature of host.features) feature.messageSent?.(id);
		// As a message sent to steer: calls that only wait end, so that it reaches the orchestrator now (heed.ts).
		messageSent(id);
	} catch (error) {
		log("after a chat was handed to the orchestrator's conversation", id, "in project", projectId, error instanceof Error ? error.message : error);
	}
	return conv.id;
}

// ---- Requests

const handlers: Record<string, (params: Params, client: Client) => Promise<unknown>> = {
	"engine.info": async () => ({ build, main: engineMain, pid: process.pid }),
	/** Whether this connection may act for the person (#504): the app asks once it has connected. */
	"connection.mayAnswer": async (_params, client) => {
		const { allowed, why } = await mayAnswer(client);
		return { mayAnswer: allowed, why };
	},
	/** How late the engine's thread ran since the last time this was asked (lag.ts): for the load script. */
	"engine.lag": async () => lag.take(),
	"conversation.create": async (params, client) => {
		if (params.chat !== undefined && typeof params.chat !== "boolean") throw new Error("chat must be true or false");
		if (params.chat === true && params.agentId !== undefined) throw new Error("A chat has no agent: leave agentId out");
		const confirm = startConfirmation(params);
		if (params.chat === true) return createChat(params.model, client);
		// The app always names the agent; a script that names none gets the oldest.
		const agent = agents[String(params.agentId ?? "")] ?? Object.values(agents).sort((x, y) => x.createdAt - y.createdAt)[0];
		if (agent === undefined) throw new Error("There is no agent to start a conversation with");
		// An agent removed through a tool is offered to nobody (docs/projects.md, 3.3).
		if (agent.removedAt !== undefined) throw new Error(`Unknown agent: ${agent.id}`);
		if (agent.projectId !== undefined) refuseStartWith(agent);
		const change = await agentChange(agent, { subChat: false, ...(params.model !== undefined ? { model: params.model as ModelRef } : {}) });
		const carriedInto = await carriedProjectFor(agent, change.cwd ?? null);
		const now = Date.now();
		let note: string | undefined;
		const created = await harness.createConversation(
			{
				ownership: { kind: "ownerless" },
				agent: change,
				init: async (tx, id) => {
					if (agent.projectId !== undefined || carriedInto !== undefined) note = await checkPersonStart(tx, agent, change.model, confirm, {}, "", carriedInto);
					// A model given here is the conversation's own: it keeps it rather than following its agent's (`ownModel`).
					const own = params.model === undefined ? {} : { ownModel: true as const };
					(await tx.doc(Library)).conversations[String(id)] = { title: "", createdAt: now, updatedAt: now, access: agent.access, agentId: agent.id, ...projectFrom(agent), ...own };
				},
			},
			context,
		);
		for (const feature of host.features) await feature.made?.(created.id as unknown as number);
		for (const feature of host.features) await feature.created?.(created.id as unknown as number, agent);
		return { id: created.id, ...(note === undefined ? {} : { note }) };
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
	...conversationRequests,
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
		const sourceId = chatOf(conv.id);
		refuseIfPutAway(sourceId);
		refuseInArchivedProject(sourceId);
		const source = library.conversations[String(sourceId)];
		if (projectOf(sourceId)?.deletedAt !== undefined) throw new Error(PROJECT_DELETED);
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
						// A fork of a project's conversation is in the project too, with the same agent, and runs as the same one. One of a
						// deleted project's is in none, as that conversation is (3.6), and is carried over as one made is (9.9).
						...(projectDeleted(source?.projectId) ? {} : projectFrom(source)),
						...(source?.projectAgentId !== undefined && !projectDeleted(source.projectId) ? { projectAgentId: source.projectAgentId } : {}),
						// A fork of a chat is a chat, with the assistant's tools, which the fork keeps, and its web switch.
						...(isChat(source) ? { chat: true as const } : {}),
						...(isChat(source) && source?.web === false ? { web: false as const } : {}),
					};
				},
			},
			context,
		);
		// A fork of a conversation in no project goes into its folder's project (9.9), as one made is.
		for (const feature of host.features) await feature.made?.(fork.id as unknown as number);
		return { id: fork.id };
	},
	"conversation.compact": async (params) => {
		const instructions = typeof params.instructions === "string" && params.instructions.trim() !== "" ? params.instructions.trim() : undefined;
		const conv = await conversation(params.id);
		refuseIfPutAway(params.id as number);
		await conv.compact(instructions, context);
		return {};
	},
	"conversation.dismissCompactionError": async (params) => {
		const conv = await conversation(params.id);
		await harness.commit(async (tx) => {
			const live = await tx.doc(LiveDoc, conv.id);
			// A dismissal from an older view must not hide a newer failure.
			if (live.compactionFailure !== undefined && live.compactionFailure.taskId === params.errorId) delete live.compactionFailure;
		}, context);
		return {};
	},
	"conversation.reset": async (params) => {
		const note = typeof params.note === "string" && params.note.trim() !== "" ? params.note.trim() : undefined;
		const conv = await conversation(params.id);
		refuseIfPutAway(params.id as number);
		await conv.reset(note, context);
		return {};
	},
	"usage.setBudget": async (params) => {
		const daily = params.daily;
		if (daily !== null && !(typeof daily === "number" && Number.isFinite(daily) && daily > 0)) throw new Error("The budget must be an amount above zero, or off");
		settings.dailyBudget = daily as number | null;
		saveSettings();
		await refreshUsage();
		return {};
	},
	...providerRequests,
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
	/**
	 * The default model for agents (#617): `{ model: { provider, modelId } | null, thinkingLevel?: string | null }`. Null
	 * goes back to the model last picked in a conversation. Every agent with no model of its own starts its next
	 * conversation on it; conversations already started keep theirs. Answers as the `agentDefault` event says.
	 */
	"settings.setAgentDefault": async (params) => {
		if (!("model" in params)) throw new Error("model must be { provider, modelId }, or null for the model used last");
		if (params.model === null) delete settings.agentDefault;
		else {
			const { provider, modelId } = (params.model ?? {}) as Partial<ModelRef>;
			if (typeof provider !== "string" || typeof modelId !== "string") throw new Error("model must be { provider, modelId }, or null for the model used last");
			if (providers.models.getModel(provider, modelId) === undefined) throw new Error(`Unknown model: ${provider}/${modelId}`);
			const level = params.thinkingLevel ?? null;
			if (level !== null) {
				const levels = (await providers.listModels()).find((model) => model.provider === provider && model.id === modelId)?.thinkingLevels ?? [];
				if (typeof level !== "string" || !levels.includes(level)) throw new Error(`${provider}/${modelId} has no thinking level ${String(level)}`);
			}
			settings.agentDefault = { model: { provider, modelId }, thinkingLevel: level as string | null };
		}
		saveSettings();
		await announceDefault();
		const { event: _, ...answer } = await agentDefaultEvent();
		return answer;
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
	"chat.continueWithAgent": continueChat,
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
		// A model or a thinking level chosen for one conversation is its own from then on: in a project it no longer takes
		// its agent's at each message (`ownModel`). The app chooses them for the agent there, never with this.
		const chosen = params.model as ModelRef | undefined;
		if (chosen !== undefined && providers.models.getModel(chosen.provider, chosen.modelId) === undefined) throw new Error(`Unknown model: ${chosen.provider}/${chosen.modelId}`);
		if (!chat && (chosen !== undefined || params.thinkingLevel !== undefined) && library.conversations[String(id)]?.ownModel !== true) {
			await editMeta(conv.id, (meta) => void (meta.ownModel = true));
		}
		if (params.model !== undefined) {
			const model = params.model as ModelRef;
			// A model on this Mac comes with its own thinking level when the conversation has none (defaultThinking).
			const thinking = params.thinkingLevel === undefined && ((await harness.snapshot(AgentDoc, conv.id, context))?.thinkingLevel ?? null) === null ? defaultThinking(model) : null;
			await conv.configure({ model: { provider: model.provider, modelId: model.modelId }, ...(thinking === null ? {} : { thinkingLevel: thinking }) }, context);
			rememberModel({ provider: model.provider, modelId: model.modelId }, chat);
			for (const feature of host.features) feature.modelChanged?.(id);
			// What the conversation is offered can follow its model: `look`, for one that cannot see pictures (picturelook.ts).
			await syncTools(conv).catch((error) => log("could not update the tools of conversation", params.id, error instanceof Error ? error.message : ""));
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
			const own = agentOf(meta, agents);
			const agent = await harness.snapshot(AgentDoc, conv.id, context);
			await conv.configure({ tools: keepingOrder(agent?.tools, toolsFor(access, own, isSubChat(meta), { conversationId: id, model: agent?.model })) }, context);
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
		// In a project the choice holds for this run alone (`followAgent`), so it is not remembered as the model last picked,
		// which an agent with no model of its own would then run on.
		if (followedModel(id, library.conversations[String(id)]) === undefined) rememberModel(model, isChat(library.conversations[String(id)]));
		for (const switchedId of switched) for (const feature of host.features) feature.modelChanged?.(chatOf(switchedId));
		return { switched };
	},
	submit: async (params) => {
		const conv = await conversation(params.id);
		refuseIfPutAway(params.id as number);
		refuseInArchivedProject(params.id as number);
		refuseEarlier(params.id as number);
		const attachments = validateAttachments(params.attachments);
		// Attachments can be the whole message.
		const content = attachments.length > 0 && params.text === undefined ? "" : text(params, "text");
		if (content.trim() === "" && attachments.length === 0) throw new Error("The message is empty");
		// The agent's settings may have changed since this conversation was set up: its model among them, which the check on
		// pictures goes by.
		await takeSwitch(conv.id);
		if (attachments.some((attachment) => attachment.kind === "image")) {
			// Refused here, while the person can still change the model or the message. Sent anyway, the pictures would
			// be swapped for a note that they were left out, and the model would answer without having seen them.
			const ref = (await harness.snapshot(AgentDoc, conv.id, context))?.model;
			const model = ref === undefined ? undefined : providers.models.getModel(ref.provider, ref.modelId);
			if (model !== undefined && !model.input.includes("image")) throw new Error(`${model.name} cannot see pictures. Choose a model that can, or remove them.`);
		}
		if (overBudget()) throw new Error(`Today's budget of $${settings.dailyBudget!.toFixed(2)} is used up. Raise it in Usage to carry on.`);
		await syncTools(conv).catch((error) => log("could not update the tools of conversation", params.id, error instanceof Error ? error.message : ""));
		const draft = {
			type: "input" as const,
			// With attachments the model is sent content blocks, and the entry records what the transcript shows.
			...(attachments.length === 0 ? { content } : { content: userContent(content, attachments), entry: { kind: USER_ENTRY_KIND, data: userEntryData(content, attachments) } }),
			whenBusy: params.mode === "steer" ? ("steer" as const) : ("followUp" as const),
			...(typeof params.requestId === "string" ? { requestId: params.requestId } : {}),
		};
		// In a project, a message to an agent other than the orchestrator is told to the orchestrator at its next turn, in
		// the commit that takes it (orchestrator.ts). Anywhere else the message is taken as it always was.
		const tell = tellOrchestrator(params.id as number);
		const submission =
			tell === undefined
				? await conv.submit(draft, context)
				: {
						id: await harness.commit(async (tx) => {
							// The same request sent again is the same message, told once.
							const again = draft.requestId === undefined ? undefined : await tx.submissionByRequest(conv.id, draft.requestId);
							const id = await conv.submit(tx, draft);
							if (again === undefined) await tell(tx, content, attachments.length);
							return id;
						}, context),
					};
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
		refuseInArchivedProject(params.id as number);
		refuseEarlier(params.id as number);
		await takeSwitch(conv.id);
		if (library.conversations[String(conv.id)]?.projectId === undefined) await conv.submit({ type: "continue" }, context);
		else await harness.commit(async (tx) => {
			await syncWorkForInput(tx, conv.id, (await tx.doc(Library)).conversations[String(conv.id)]);
			await conv.submit(tx, { type: "continue" });
		}, context);
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

	...agentRequests,
	...scheduleRequests,
	"recovery.dismiss": async () => {
		recovery = null;
		broadcast(recoveryEvent());
		return {};
	},
	// Answered through `claim` (needs.ts), as every answer to what waits for the person is, by whichever route.
	"inbox.decide": async (params) => {
		const decision = text(params, "decision");
		if (!["once", "always", "rule", "deny"].includes(decision)) throw new Error(`Unknown decision: ${decision}`);
		await claim(text(params, "id"), { kind: "approval", decision: decision as "once" | "always" | "rule" | "deny" });
		return {};
	},
	"inbox.answer": async (params) => {
		const answer = text(params, "text");
		if (answer.trim() === "") throw new Error("The answer is empty");
		await claim(text(params, "id"), { kind: "question", text: answer });
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
	for (const [method, handler] of Object.entries(feature.handlers ?? {})) handlers[method] = (params, client) => handler(params, client);
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
	const before = library.conversations;
	setLibrary(call.value);
	if (usageRowsChanged(before, library.conversations)) scheduleUsageRefresh();
	runsAsSent = runsAsNow();
	broadcast(libraryEvent());
	announceInbox(); // titles shown in the inbox come from here
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
setVersions(versionsWatch.value);
versionsWatch.start(async (call) => {
	if (call.kind !== "value") return;
	setVersions(call.value);
	for (const client of clients) for (const subscription of client.subscriptions.values()) void subscription.follow().then(() => subscription.push());
});

// Agents: created with three starters on a first launch, then whatever the person makes of them.
await harness.commit(async (tx) => {
	const doc = await tx.doc(Agents);
	if (Object.keys(doc.agents).length === 0) for (const agent of starterAgents(Date.now())) doc.agents[agent.id] = agent;
}, context);
const agentsWatch = await harness.watchDoc(Agents, context);
if (agentsWatch === undefined) throw new Error("The agents document could not be opened");
setAgents(agentsWatch.value.agents);
agentsWatch.start(async (call) => {
	if (call.kind !== "value") return;
	setAgents(call.value.agents);
	broadcast(agentsEvent());
	announceInbox();
	runsAsChanged();
	// An agent's model or thinking level is its conversations' from their next message.
	followersChanged();
});
// What a conversation of an agent with no model of its own runs on, before anything is decided in a commit.
await defaultModel().catch((error) => log("could not work out the default model for agents:", error instanceof Error ? error.message : error));
// Features start once the conversations and agents are loaded, before any schedule is armed: what one writes into a
// transcript as it starts (a background command the last engine left, a set-up cut short) sets the last engine's
// work going again at once, before `resume()`.
for (const feature of host.features) await feature.start?.();
// Recovery has dealt with recorded runs. Unrecorded files can go only once nothing holds them.
void sweepRuns().catch((error) => log("run files could not be tidied:", error));
const graphWatch = await harness.watchTaskGraph(context);
setWorking(conversationsWithWork(graphWatch.value as never));
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
				projectId: meta?.projectId ?? null,
				// The agent it runs as now (state.ts, `runsAs`).
				runsAs: runsAs(meta, agents) ?? null,
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
	setWorking(conversationsWithWork(call.value as never));
	refreshBusy();
	for (const feature of host.features) feature.runsChanged?.(working);
	const changed = before.size !== working.size || [...working].some((id) => !before.has(id));
	if (changed) broadcast(libraryEvent());
	announceActivity();
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

wireProjectSpend(async (tx, projectId) => {
	const ledger = await tx.doc(Spend);
	const { conversations } = await tx.doc(Library);
	const day = dayKey();
	let cost = 0;
	for (const [key, meta] of Object.entries(conversations)) {
		if (meta.projectId !== projectId) continue;
		const id = Number(key) as unknown as ConversationId;
		const dirty = dirtyUsage.get(id);
		const total = dirtyUsage.has(id) && dirty !== "read" ? usageTotals(dirty) : usageById.get(id)?.totals ?? noSpend();
		cost += conversationSpend(ledger.conversations?.[key], total, day, ledger.conversations === undefined && ledger.lastTokens !== 0).today.cost;
	}
	return cost;
});

// Usage is written with a model response (including compaction) or a tool result that reports usage. The task graph
// also changes for work that spent nothing, and a request can end while its conversation still has work.
harness.observeCommits({
	advance({ changes }) {
		for (const change of changes) {
			if (change.type !== "document" && change.type !== "document.copy") continue;
			if (change.record.kind !== UsageDoc.definition.kind || change.conversationId === undefined) continue;
			const doc = change.type === "document.copy" ? "read" : change.kind === "retire" ? undefined : change.value as UsageDocShape;
			dirtyUsage.set(change.conversationId, doc);
			scheduleUsageRefresh();
		}
	},
	end() {},
});
// Seed once from the durable list, not the visible library: even usage with no pi² metadata belongs in the total.
await harness.commit(async (tx) => {
	let cursor: Cursor | undefined;
	do {
		const page = await tx.scanConversations({}, 256, cursor);
		for (const { id } of page.items) if (!dirtyUsage.has(id)) dirtyUsage.set(id, "read");
		cursor = page.next;
	} while (cursor !== undefined);
}, context);
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
setSchedules(schedulesWatch.value.schedules);

schedulesWatch.start(async (call) => {
	if (call.kind !== "value") return;
	setSchedules(call.value.schedules);
	broadcast(schedulesEvent());
	armSchedules();
});

// Only test-copy starts an engine with this switch and the matching copy paths. The fixture implementation is
// outside src, so an installed engine has neither the handler nor the module, even with the switch in its environment;
// and a release engine never reads the switch (testswitches.ts).
const testSuffix = testSwitch("PI2_TEST_COPY");
const checkout = dirname(dirname(dirname(engineMain)));
const fixtureSource = new URL("../scripts/test-copy-fixture.ts", import.meta.url);
if (testSuffix !== undefined && testSuffix !== "dev" && /^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$/.test(testSuffix)
	&& home === join(homedir(), "Library", "Application Support", `pi2-${testSuffix}`) && lstatSync(home).isDirectory()
	&& process.env.PI2_KEYCHAIN_SERVICE === `dev.pi2.credentials.${testSuffix}`
	&& existsSync(join(checkout, "app", "build", "test-copies", testSuffix, `pi² ${testSuffix}.app`, "Contents", "MacOS", "pi2"))
	&& existsSync(fixtureSource)) {
	const { fixtureSize, seedTranscript } = await import("../scripts/test-copy-fixture.ts");
	// The key with which scripts/test-copy answers for the person in this copy (`answer`, `call`; #504), since it is not
	// the app. A new one at each start, in the copy's own folder in the checkout, which test-copy made and removes at
	// stop: never in the data folder, where the copy's agents work. Only the person's own files hold it.
	const copyFolder = join(checkout, "app", "build", "test-copies", testSuffix);
	const answerKey = randomBytes(32).toString("hex");
	try {
		if (!lstatSync(copyFolder).isDirectory()) throw new Error(`${copyFolder} is not a folder`);
		const pending = join(copyFolder, `.answer-key-${process.pid}`);
		rmSync(pending, { force: true });
		writeFileSync(pending, `${answerKey}\n`, { mode: 0o600, flag: "wx" });
		renameSync(pending, join(copyFolder, "answer-key"));
		handlers["test-copy.answerer"] = async (params, client) => {
			const given = Buffer.from(typeof params.key === "string" ? params.key : "");
			const expected = Buffer.from(answerKey);
			if (given.length !== expected.length || !timingSafeEqual(given, expected)) throw new Error("That is not this test copy's key");
			client.testCopy = true;
			return {};
		};
	} catch (error) {
		log("test-copy cannot answer for the person in this copy:", error instanceof Error ? error.message : error);
	}
	const { fillProject } = await import("../scripts/test-copy-project.ts");
	const { Reports } = await import("./reports.ts");
	let fillingProject = false;
	handlers["test-copy.fillProject"] = async (params, client) => {
		if (fillingProject) throw new Error("A demo project is already being filled in this copy");
		const name = typeof params.name === "string" ? params.name.trim() : undefined;
		if ("name" in params && typeof params.name !== "string") throw new Error("A demo project's name is a string");
		if (name !== undefined && (name.length === 0 || name.length > 60)) throw new Error("A demo project's name is 1 to 60 characters, trimmed");
		const count = "count" in params ? params.count : 1;
		if (typeof count !== "number" || !Number.isInteger(count) || count < 1 || count > 8) throw new Error("A count of demo projects is a whole number from 1 to 8");
		fillingProject = true;
		try {
			// The fixture is itself app-only. These calls and all of their arguments come from the fixture, not the socket.
			const call = async (method: string, callParams: Record<string, unknown>) => {
				const handler = handlers[method];
				if (handler === undefined) throw new Error(`Unknown method: ${method}`);
				return handler(callParams, client);
			};
			const ready = async ({ projectId, working, waiting, finished }: { projectId: string; working: number[]; waiting: number; finished: number }) => {
				const runs = activityEvent().runs;
				const active = working.every((id) => runs.some((run) => run.conversationId === id && run.status === "working" && run.commands.length > 0));
				if (!active || !runs.some((run) => run.conversationId === waiting && run.status === "waiting")) return false;
				const reports = await harness.snapshot(Reports, context);
				return reports?.projects[projectId]?.some((report) => report.conversationId === finished && report.ended?.outcome === "answered" && report.delivered === null) ?? false;
			};
			// `--project <count>` fills that many, one after another, so a copy can hold several for the Dashboard (#481).
			const filled: unknown[] = [];
			for (let made = 0; made < count; made++) filled.push(await fillProject(home, call, ready, name));
			return count === 1 ? filled[0] : filled;
		} finally {
			fillingProject = false;
		}
	};
	handlers["test-copy.fill"] = async (params) => {
		const entries = fixtureSize(params.entries);
		const agent = Object.values(agents).sort((a, b) => a.createdAt - b.createdAt)[0];
		if (agent === undefined) throw new Error("There is no agent to start a conversation with");
		const change = await agentChange(agent, { subChat: false });
		const now = Date.now();
		const created = await harness.createConversation({
			ownership: { kind: "ownerless" },
			agent: { ...change, model: { provider: DEMO_PROVIDER, modelId: DEMO_MODEL }, thinkingLevel: null },
			init: async (tx, id) => {
				(await tx.doc(Library)).conversations[String(id)] = { title: `Test history (${entries} entries)`, renamed: true, createdAt: now, updatedAt: now, access: agent.access, agentId: agent.id };
				await seedTranscript(tx, id, entries, now);
			},
		}, context);
		return { id: created.id, entries };
	};
}

// ---- Socket server

// Check only once the features and any test-copy methods have registered, and fail before opening the socket.
checkRequestClasses(Object.keys(handlers));
Object.freeze(handlers);

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
	void agentDefaultEvent().then((event) => send(client, event));
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
			if (request === null || typeof request !== "object" || Array.isArray(request) || typeof request.method !== "string") {
				send(client, { id: request?.id ?? null, error: "A request must have a method name" });
				continue;
			}
			const method = request.method;
			if (!Object.hasOwn(handlers, method)) {
				send(client, { id: request.id, error: `Unknown method: ${method}` });
				continue;
			}
			const handler = handlers[method]!;
			const params = request.params ?? {};
			if (typeof params !== "object" || Array.isArray(params)) {
				send(client, { id: request.id, error: "Request parameters must be an object" });
				continue;
			}
			const handle = () =>
				handler(params, client).then(
					(result) => send(client, { id: request.id, result }),
					// A refusal may carry data beside its message (requesterror.ts): a changed plan's new report, a limit's reading.
					(error: unknown) => send(client, { id: request.id, ...refusal(error) }),
				);
			// A request that is the person's alone — an answer to what waits, or a change to what they set — is taken only
			// from the app (#504, #513).
			const reason = personOnly(method, params);
			if (reason === undefined) handle();
			else {
				const refuse = () => send(client, { id: request.id, error: reason });
				void mayAnswer(client).then(({ allowed }) => (allowed ? handle() : refuse()), refuse);
			}
		}
	});
	const drop = () => {
		if (!clients.delete(client)) return;
		if (computerClients.delete(client)) computer.unregister(computerHostOf.get(client));
		if (browserClients.delete(client)) browser.unregister(browserHostOf.get(client));
		for (const subscription of client.subscriptions.values()) void subscription.stop();
		// An app that quits closes its panes: what they showed is no longer shown (docs/local-models-running.md).
		if (client.shown.size > 0) for (const feature of host.features) feature.shownChanged?.();
		for (const feature of host.features) feature.disconnected?.(client);
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
