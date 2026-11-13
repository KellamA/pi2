// pi2-engine: hosts one pi durable Harness on SQLite and serves it to the app over a Unix socket.
// Wire format: one JSON object per line. Requests are { id, method, params } and are answered { id, result } or
// { id, error }; the methods are the keys of `handlers` below. The engine also pushes { event, ... } messages:
// "library", "providers", "conversation" (for opened conversations) and "auth" (during a sign-in).

import { randomUUID } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { connect, createServer, type Socket } from "node:net";
import { homedir } from "node:os";
import { join } from "node:path";
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
	type SubmissionId,
	UsageDoc,
} from "@earendil-works/pi-durable";
import { CodemodeSandbox } from "@earendil-works/pi-codemode";
import { createCodemodeExtension } from "@earendil-works/pi-durable/codemode";
import { NodeExecutionEnv } from "@earendil-works/pi-durable/env/node";
import { openNodeSqliteStorage } from "@earendil-works/pi-durable/storage/sqlite/node";
import { CodingTools } from "@earendil-works/pi-durable/tools";
import { type AttachmentNote, describeAttachments, readUserEntryData, USER_ENTRY_KIND, userContent, userEntryData, validateAttachments } from "./attachments.ts";
import { createBackup, restoreBackup } from "./backup.ts";
import { BrowserHost, validateBrowser } from "./browser.ts";
import { KeychainCredentialStore } from "./credentials.ts";
import { type Host, pi2Extension } from "./extensions.ts";
import { type Engine, FEATURES } from "./features.ts";
import { McpServers } from "./mcp.ts";
import { ComputerHost, validateComputer } from "./computer.ts";
import { validateReferenceFiles } from "./reference.ts";
import { DEMO_MODEL, DEMO_PROVIDER, newestOnly, Providers } from "./providers.ts";
import { nextRun, type Schedule, Schedules, validateRepeat } from "./schedules.ts";
import { type Access, ACCESS_LEVELS, type AgentProfile, Agents, Inbox, Library, type Meta, type ModelRef, starterAgents } from "./state.ts";

const context = BACKGROUND_CONTEXT;
const home = process.env.PI2_HOME ?? join(homedir(), "Library", "Application Support", "pi2");
const socketPath = join(home, "engine.sock");
mkdirSync(home, { recursive: true });

function log(...parts: unknown[]): void {
	console.error("[pi2-engine]", ...parts);
}

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
writeFileSync(join(home, "engine.pid"), String(process.pid));

// A marker that is only removed by a clean stop: finding it at start means the last engine was killed or crashed.
const runningMarker = join(home, "engine.running");
const stoppedUncleanly = existsSync(runningMarker);
writeFileSync(runningMarker, String(Date.now()));

// ---- Models, tools, harness

const credentials = new KeychainCredentialStore(home);
const providers = new Providers(home, credentials, () => deviceId());
const mcp = new McpServers(home, credentials);
const inbox = new Inbox();
const computer = new ComputerHost();
const browser = new BrowserHost();
let library: { conversations: Record<string, Meta> } = { conversations: {} };
let agents: Record<string, AgentProfile> = {};

const host: Host = {
	inbox,
	computer,
	browser,
	scratchFolder: () => workspace,
	changesThings: (name) => mcp.changesThings(name),
	meta: (id) => library.conversations[String(id)],
	agent: (id) => (id === undefined ? undefined : agents[id]),
	allowAlways: (id, tool) =>
		editMeta(id, (meta) => {
			if (!meta.autoApprove?.includes(tool)) meta.autoApprove = [...(meta.autoApprove ?? []), tool];
		}),
	agentChange: (agent, options) => agentChange(agent, options),
	continueChat: async (id, content, requestId, callerContext) => {
		const conv = await harness.conversation(id as unknown as ConversationId, context);
		if (conv === undefined) return { reason: "the sub-chat no longer exists" };
		await syncTools(conv).catch(() => {});
		const submission = await conv.submit({ type: "input", content, requestId }, context);
		await editMeta(conv.id, (meta) => void (meta.updatedAt = Date.now()));
		// The sub-chat was created by an earlier call, so this call does not own it: stop it by hand if the caller stops.
		const stop = () => void conv.abort(context).catch(() => {});
		callerContext.abortSignal?.addEventListener("abort", stop, { once: true });
		try {
			const settled = await submission.wait(callerContext);
			if (settled.status !== "done" || settled.type !== "input") return { reason: "reason" in settled && settled.reason !== undefined ? String(settled.reason) : "no answer" };
			const entry = await conv.commit((tx) => tx.entry(AssistantEntry, settled.answer), context);
			return { answer: textOf((entry?.model?.[0] as { content?: unknown } | undefined)?.content) };
		} finally {
			callerContext.abortSignal?.removeEventListener("abort", stop);
		}
	},
	answerText: async (id, entryId) => {
		const conv = await harness.conversation(id, context);
		const entry = await conv?.commit((tx) => tx.entry(AssistantEntry, entryId as EntryId), context);
		return textOf((entry?.model?.[0] as { content?: unknown } | undefined)?.content);
	},
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
};
host.features = FEATURES.map((feature) => feature(host, engine));
const pi2 = pi2Extension(host);
const registry = createRegistry();
const codemode = createCodemodeExtension({ sandbox: new CodemodeSandbox({ memoryLimitBytes: 256 * 1024 * 1024 }) });
let mcpTools = mcp.extension();
registry.install(CodingTools);
registry.install(pi2);
registry.install(codemode);
registry.install(mcpTools);
const tool = (name: string) => [...CodingTools.tools!, ...pi2.tools!, ...codemode.tools!, ...mcpTools.tools!].find((t) => t.name === name);

/**
 * The tools a conversation is given: file and shell tools by access level, asking the person, delegation, and what
 * its agent adds (scripts, MCP servers). A tool whose server is not connected right now is left out.
 */
function toolsFor(access: Access, delegate: boolean, agent: AgentProfile | undefined) {
	const files = access === "none" ? [] : access === "read" ? ["read"] : ["read", "write", "edit", "bash"];
	const extras = [...(agent?.codeMode ? ["codemode"] : []), ...mcp.toolNames(agent?.mcpServers ?? [])];
	// Reference files can be read whatever the access level: the person chose them for this agent.
	const reference = (agent?.files?.length ?? 0) > 0 ? ["read_reference"] : [];
	const screen = agent?.computer?.enabled === true ? ["computer"] : [];
	const web = agent?.browser?.enabled === true ? ["browser"] : [];
	const added = host.features.flatMap((feature) => feature.toolNames?.(access, agent) ?? []);
	return [...files, ...reference, ...screen, ...web, ...added, "ask_user", ...(delegate ? ["delegate"] : []), ...extras].map(tool).filter((t) => t !== undefined);
}

/** How a conversation that starts from `agent` is configured. */
async function agentChange(agent: AgentProfile, options: { delegate: boolean }): Promise<AgentChange> {
	const model = agent.model !== null && providers.models.getModel(agent.model.provider, agent.model.modelId) !== undefined ? agent.model : await defaultModel();
	return {
		model,
		thinkingLevel: (agent.thinkingLevel as never) ?? null,
		instructions: agent.instructions.trim() === "" ? null : agent.instructions,
		tools: toolsFor(agent.access, options.delegate && agent.delegates.some((id) => agents[id] !== undefined), agent),
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
		models: providers.models,
		registry,
		// A conversation without a chosen folder works in the app's own scratch folder, never the home folder.
		env: ({ cwd }) => new NodeExecutionEnv({ cwd: cwd ?? workspace }),
		identity: { attribution: { name: "pi2", url: "https://github.com/earendil-works/pi" } },
		onReport: (report) => log("report", report.kind, report.error instanceof Error ? report.error.message : ""),
	},
	context,
);

const settingsPath = join(home, "settings.json");
const settings: { defaultModel?: ModelRef; lastAgent?: string; dailyBudget?: number | null; onboarded?: boolean; deviceId?: string; hiddenModels?: Record<string, string[]> } = (() => {
	try {
		return JSON.parse(readFileSync(settingsPath, "utf8"));
	} catch {
		return {};
	}
})();
const saveSettings = () => writeFileSync(settingsPath, JSON.stringify(settings, null, "\t"));

/** A random ID for this installation, made the first time a sign-in asks for one and the same ever after. */
function deviceId(): string {
	if (settings.deviceId === undefined) {
		settings.deviceId = randomUUID();
		saveSettings();
	}
	return settings.deviceId;
}

async function conversation(id: unknown): Promise<Conversation> {
	const found = typeof id === "number" ? await harness.conversation(id as ConversationId, context) : undefined;
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
	const own = agents[meta?.agentId ?? ""];
	// A conversation whose agent was deleted keeps the setup it has.
	if (meta === undefined || own === undefined) return;
	const delegate = meta.parent === undefined && own.delegates.some((other) => agents[other] !== undefined);
	const wanted = toolsFor(meta.access, delegate, own);
	const names = wanted.map((t) => t!.name);
	const current = (await harness.snapshot(AgentDoc, conv.id, context))?.tools;
	if (Array.isArray(current) && current.length === names.length && current.every((name, index) => name === names[index])) return;
	await conv.configure({ tools: wanted }, context);
	for (const client of clients) client.subscriptions.get(id)?.push();
}

async function editMeta(id: ConversationId, change: (meta: Meta) => void): Promise<void> {
	await harness.commit(async (tx) => {
		const meta = (await tx.doc(Library)).conversations[String(id)];
		if (meta !== undefined) change(meta);
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
	| { id: number; kind: "marker"; text: string };

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
	if (entry.kind === "pi.compaction") return { id, kind: "marker", text: "Earlier messages were summarized" };
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
		return { used: (usage.input ?? 0) + (usage.cacheRead ?? 0) + (usage.cacheWrite ?? 0) + (usage.output ?? 0), window: window ?? null };
	}
	return { used: 0, window: window ?? null };
}

function stateOf(view: ConversationView, meta: Meta | undefined) {
	const live = (view.docs["pi.live"] ?? {}) as LiveDocShape;
	const agent = (view.docs["pi.agent"] ?? {}) as { model?: ModelRef; thinkingLevel?: string; cwd?: string };
	const inbox = (view.docs["pi.inbox"] ?? {}) as { items?: { id: number; mode: string; content?: unknown; entry?: { kind?: unknown; data?: unknown } }[] };
	const partial = live.generation?.message;
	return {
		busy: live.run !== undefined,
		turns: live.run?.turns ?? 0,
		partial: partial === undefined ? null : assistantParts(partial),
		retry: live.generation?.retry ?? null,
		tools: (live.tools ?? []).map((slot) => ({ callId: slot.callId, name: slot.name, status: slot.status, output: slot.output ?? "", details: slot.details ?? null })),
		failure: live.runFailure === undefined ? null : { reason: live.runFailure.reason, detail: live.runFailure.detail ?? null },
		usage: usageTotals(view.docs["pi.usage"] as UsageDocShape | undefined),
		context: contextOf(view, agent.model),
		compacting: (live.compactions ?? []).length > 0,
		compactionError: live.compactionFailure?.error ?? null,
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
		// What features add (see features.ts).
		...Object.assign({}, ...host.features.map((feature) => feature.state?.(view, meta) ?? {})),
	};
}

// ---- Clients

type Subscription = { push: () => void; stop: () => Promise<unknown> };
type Client = { socket: Socket; subscriptions: Map<number, Subscription> };
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
	for (const client of clients) send(client, message);
}

library = (await harness.snapshot(Library, context)) ?? { conversations: {} };
for (const feature of host.features) await feature.start?.();
let busyConversations = new Set<number>();
/** Every conversation with live work, sub-chats included. */
let working = new Set<number>();

function libraryEvent() {
	const conversations = Object.entries(library.conversations)
		// Sub-chats are listed too, pointing at their parent, unless either of them was deleted.
		.filter(([, meta]) => meta.archived !== true && (meta.parent === undefined || library.conversations[String(meta.parent)]?.archived !== true))
		.map(([id, meta]) => ({
			id: Number(id),
			title: meta.title,
			createdAt: meta.createdAt,
			updatedAt: meta.updatedAt,
			// A conversation shows as working while it or any of its sub-chats is; a sub-chat only for itself.
			busy: meta.parent === undefined ? busyConversations.has(Number(id)) : working.has(Number(id)),
			agentId: meta.agentId ?? null,
			parent: meta.parent ?? null,
		}))
		.sort((a, b) => b.updatedAt - a.updatedAt);
	return { event: "library", conversations };
}

function agentsEvent() {
	return { event: "agents", agents: Object.values(agents).sort((a, b) => a.createdAt - b.createdAt) };
}

/** Everything waiting on the person, with enough context to answer from anywhere in the app. */
function inboxEvent() {
	const items = inbox.list().map((item) => {
		const meta = library.conversations[String(item.conversationId)];
		const root = meta?.parent ?? item.conversationId;
		return {
			...item,
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
	broadcast(activityEvent());
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
}

/** The model a new conversation starts with: the last one picked if it is still usable, else the demo model. */
async function defaultModel(): Promise<ModelRef> {
	const wanted = settings.defaultModel;
	if (wanted !== undefined) {
		const usable = (await providers.models.getAvailable(wanted.provider).catch(() => [])).some((m) => m.id === wanted.modelId);
		if (usable) return wanted;
	}
	return { provider: DEMO_PROVIDER, modelId: DEMO_MODEL };
}

async function subscribe(client: Client, conv: Conversation): Promise<void> {
	const id = conv.id as unknown as number;
	if (client.subscriptions.has(id)) return;
	const watch = await conv.watch(context, { min: 300, max: 600 });
	let view = watch.value;
	let lastSent: unknown;
	const push = () => {
		// Entries never change once committed, so the app is only sent the ones it does not have yet.
		const index = lastSent === undefined ? -1 : view.entries.findIndex((entry) => entry.id === lastSent);
		const reset = lastSent === undefined || index === -1;
		const fresh = reset ? view.entries : view.entries.slice(index + 1);
		if (view.entries.length > 0) lastSent = view.entries.at(-1)!.id;
		const items = fresh.map(toItem).filter((item) => item !== undefined);
		send(client, { event: "conversation", id, reset, items, state: stateOf(view, library.conversations[String(id)]) });
	};
	client.subscriptions.set(id, { push, stop: () => watch.stop() });
	push();
	watch.start(async (call) => {
		if (call.kind !== "value") return;
		view = call.value;
		push();
	});
}

// ---- Requests

type Params = Record<string, unknown>;
const text = (params: Params, key: string): string => {
	const value = params[key];
	if (typeof value !== "string") throw new Error(`Missing ${key}`);
	return value;
};

const handlers: Record<string, (params: Params, client: Client) => Promise<unknown>> = {
	"conversation.create": async (params) => {
		const agent = agents[String(params.agentId ?? settings.lastAgent ?? "")] ?? Object.values(agents).sort((x, y) => x.createdAt - y.createdAt)[0];
		if (agent === undefined) throw new Error("There is no agent to start a conversation with");
		const change = await agentChange(agent, { delegate: true });
		const now = Date.now();
		const created = await harness.createConversation(
			{
				ownership: { kind: "ownerless" },
				agent: params.model !== undefined ? { ...change, model: params.model as ModelRef } : change,
				init: async (tx, id) => {
					(await tx.doc(Library)).conversations[String(id)] = { title: "", createdAt: now, updatedAt: now, access: agent.access, agentId: agent.id };
				},
			},
			context,
		);
		settings.lastAgent = agent.id;
		saveSettings();
		return { id: created.id };
	},
	"conversation.open": async (params, client) => {
		await subscribe(client, await conversation(params.id));
		return {};
	},
	"conversation.close": async (params, client) => {
		const subscription = client.subscriptions.get(params.id as number);
		client.subscriptions.delete(params.id as number);
		await subscription?.stop();
		return {};
	},
	"conversation.rename": async (params) => {
		const conv = await conversation(params.id);
		const title = text(params, "title").trim().slice(0, 120);
		await editMeta(conv.id, (meta) => void (meta.title = title));
		return {};
	},
	"conversation.fork": async (params) => {
		const conv = await conversation(params.id);
		const source = library.conversations[String(conv.id)];
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
					};
				},
			},
			context,
		);
		return { id: fork.id };
	},
	"conversation.compact": async (params) => {
		const instructions = typeof params.instructions === "string" && params.instructions.trim() !== "" ? params.instructions.trim() : undefined;
		await (await conversation(params.id)).compact(instructions, context);
		return {};
	},
	"conversation.reset": async (params) => {
		const note = typeof params.note === "string" && params.note.trim() !== "" ? params.note.trim() : undefined;
		await (await conversation(params.id)).reset(note, context);
		return {};
	},
	search: async (params) => {
		const query = text(params, "query").trim().toLowerCase();
		if (query.length < 2) return { results: [] };
		const results: { conversationId: number; title: string; entryId: number; role: string; snippet: string }[] = [];
		const ids = Object.entries(library.conversations)
			.filter(([, meta]) => meta.archived !== true && meta.parent === undefined)
			.sort(([, x], [, y]) => y.updatedAt - x.updatedAt)
			.map(([id]) => Number(id));
		for (const id of ids) {
			const conv = await harness.conversation(id as unknown as ConversationId, context);
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
					results.push({ conversationId: id, title: library.conversations[String(id)]?.title ?? "", entryId: entry.id as unknown as number, role: message.role, snippet });
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
		if (available.every((model) => hidden.includes(model))) throw new Error("Keep at least one model showing");
		settings.hiddenModels = { ...settings.hiddenModels, [id]: hidden as string[] };
		if (hidden.length === 0) delete settings.hiddenModels[id];
		saveSettings();
		// Answer first: asking every provider about its sign-in takes a moment, and the sheet is waiting.
		void announceProviders().catch((error) => log("announcing providers failed:", error));
		return { hidden };
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
		const meta = library.conversations[String(conv.id)];
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
		if (params.format === "json") return { text: JSON.stringify({ title: meta?.title ?? "", agent: agents[meta?.agentId ?? ""]?.name ?? null, exportedAt: new Date().toISOString(), items }, null, 2) };
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
			else if (item.kind === "assistant") {
				lines.push(`## ${agentName}${item.stop === "aborted" || item.stop === "error" ? " (interrupted)" : ""}`, "");
				if (item.text !== "") lines.push(item.text, "");
				for (const call of item.toolCalls) {
					const result = results.get(call.callId);
					lines.push(`**Tool: ${call.name}**`, "", `${fence}json`, JSON.stringify(call.arguments, null, 2), fence, "");
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
		const conv = await conversation(params.id);
		await conv.abort(context);
		await editMeta(conv.id, (meta) => void (meta.archived = true));
		return {};
	},
	"conversation.configure": async (params, client) => {
		const conv = await conversation(params.id);
		const id = conv.id as unknown as number;
		if (params.model !== undefined) {
			const model = params.model as ModelRef;
			if (providers.models.getModel(model.provider, model.modelId) === undefined) throw new Error(`Unknown model: ${model.provider}/${model.modelId}`);
			await conv.configure({ model: { provider: model.provider, modelId: model.modelId } }, context);
			settings.defaultModel = { provider: model.provider, modelId: model.modelId };
			saveSettings();
		}
		if (params.thinkingLevel !== undefined) await conv.configure({ thinkingLevel: params.thinkingLevel as never }, context);
		if (params.cwd !== undefined) {
			const cwd = params.cwd === null ? null : text(params, "cwd");
			if (cwd !== null && !(existsSync(cwd) && statSync(cwd).isDirectory())) throw new Error(`Not a folder: ${cwd}`);
			await conv.configure({ cwd }, context);
		}
		if (params.access !== undefined) {
			const access = params.access as Access;
			if (!ACCESS_LEVELS.includes(access)) throw new Error(`Unknown access level: ${String(access)}`);
			const meta = library.conversations[String(id)];
			const own = agents[meta?.agentId ?? ""];
			const delegate = meta?.parent === undefined && (own?.delegates ?? []).some((other) => agents[other] !== undefined);
			await conv.configure({ tools: toolsFor(access, delegate, own) }, context);
			await editMeta(conv.id, (meta) => void (meta.access = access));
			for (const other of clients) other.subscriptions.get(id)?.push();
		}
		void client;
		return {};
	},
	submit: async (params) => {
		const conv = await conversation(params.id);
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
		await editMeta(conv.id, (meta) => {
			meta.updatedAt = Date.now();
			// A message that is only attachments is titled after the first of them.
			if (meta.title === "") meta.title = (content.trim().split("\n")[0] || attachments[0]?.name || "").slice(0, 60);
		});
		return { submissionId: submission.id };
	},
	abort: async (params) => {
		await (await conversation(params.id)).abort(context);
		return {};
	},
	continue: async (params) => {
		await (await conversation(params.id)).submit({ type: "continue" }, context);
		return {};
	},
	withdraw: async (params) => {
		const submission = await harness.submission(params.submissionId as SubmissionId, context);
		await submission?.abort(context);
		return {};
	},

	"agents.save": async (params) => {
		const input = params.agent as Partial<AgentProfile> | undefined;
		const name = typeof input?.name === "string" ? input.name.trim() : "";
		if (input === undefined || name === "") throw new Error("Give the agent a name");
		if (input.access !== undefined && !ACCESS_LEVELS.includes(input.access)) throw new Error(`Unknown access level: ${String(input.access)}`);
		if (typeof input.cwd === "string" && !(existsSync(input.cwd) && statSync(input.cwd).isDirectory())) throw new Error(`Not a folder: ${input.cwd}`);
		if (input.maxTurns !== undefined && input.maxTurns !== null && !(Number.isInteger(input.maxTurns) && input.maxTurns >= 1)) throw new Error("The turn limit must be a whole number, 1 or more");
		const taken = Object.values(agents).some((other) => other.id !== input.id && other.name.toLowerCase() === name.toLowerCase());
		if (taken) throw new Error(`There is already an agent called ${name}`);
		let id = input.id;
		if (id !== undefined && agents[id] === undefined) throw new Error(`Unknown agent: ${id}`);
		if (id === undefined) {
			const slug = name.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "") || "agent";
			id = slug;
			for (let n = 2; agents[id] !== undefined; n++) id = `${slug}-${n}`;
		}
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
			delegates: (input.delegates ?? previous?.delegates ?? []).filter((other) => other !== id),
			maxTurns: input.maxTurns === undefined ? (previous?.maxTurns ?? null) : input.maxTurns,
			codeMode: input.codeMode ?? previous?.codeMode ?? false,
			mcpServers: input.mcpServers ?? previous?.mcpServers ?? [],
			files: input.files === undefined ? (previous?.files ?? []) : validateReferenceFiles(input.files),
			computer: input.computer === undefined ? (previous?.computer ?? { enabled: false, apps: [], ask: true }) : validateComputer(input.computer),
			browser: input.browser === undefined ? (previous?.browser ?? { enabled: false, ask: true }) : validateBrowser(input.browser),
			createdAt: previous?.createdAt ?? Date.now(),
		};
		await harness.commit(async (tx) => void ((await tx.doc(Agents)).agents[id] = agent), context);
		// The agent's conversations pick up what it may now do at their next message; see syncTools.
		return { id };
	},
	"agents.delete": async (params) => {
		const id = text(params, "id");
		if (agents[id] === undefined) throw new Error(`Unknown agent: ${id}`);
		if (Object.keys(agents).length === 1) throw new Error("Keep at least one agent");
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
		if (!["once", "always", "deny"].includes(decision)) throw new Error(`Unknown decision: ${decision}`);
		if (!inbox.answer(text(params, "id"), decision)) throw new Error("That request is no longer waiting");
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
// Requests that features answer.
for (const feature of host.features) {
	for (const [method, handler] of Object.entries(feature.handlers ?? {})) handlers[method] = (params) => handler(params);
}

// ---- Live indexes: the library document and which conversations have work running

// The document must exist before it can be watched; this creates it on a first launch.
await harness.commit(async (tx) => void (await tx.doc(Library)), context);
const libraryWatch = await harness.watchDoc(Library, context);
if (libraryWatch === undefined) throw new Error("The library document could not be opened");
libraryWatch.start(async (call) => {
	if (call.kind !== "value") return;
	library = call.value;
	broadcast(libraryEvent());
	broadcast(inboxEvent()); // titles shown in the inbox come from here
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
const graphWatch = await harness.watchTaskGraph(context);
type Graph = { tasks: Record<string, { conversationId?: unknown }> };
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

/** What is running right now, one row per conversation with live work; subagents point at their parent. */
function activityEvent() {
	const waiting = new Set(inbox.list().map((item) => item.conversationId));
	const runs = [...working]
		.map((id) => {
			const meta = library.conversations[String(id)];
			return {
				conversationId: id,
				parent: meta?.parent ?? null,
				rootConversationId: rootOf(id),
				title: meta?.title ?? "",
				agentId: meta?.agentId ?? null,
				status: waiting.has(id) ? "waiting" : "working",
				since: since.get(id) ?? Date.now(),
			};
		})
		.sort((x, y) => x.since - y.since);
	return { event: "activity", runs };
}

// ---- Recovery: what an engine that starts after a crash found and picked up

type Recovery = { at: number; conversations: { id: number; title: string }[] };
let recovery: Recovery | null = stoppedUncleanly
	? { at: Date.now(), conversations: [...new Set([...working].map(rootOf))].map((id) => ({ id, title: library.conversations[String(id)]?.title ?? "" })) }
	: null;
const recoveryEvent = () => ({ event: "recovery", recovery });

graphWatch.start(async (call) => {
	if (call.kind !== "value") return;
	const before = working;
	working = conversationsWithWork(call.value as never);
	refreshBusy();
	const changed = before.size !== working.size || [...working].some((id) => !before.has(id));
	if (changed) broadcast(libraryEvent());
	broadcast(activityEvent());
	scheduleUsageRefresh();
});

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
let usageSummary: Record<string, unknown> = { event: "usage", models: [], agents: [], conversations: [], total: { cost: 0, tokens: 0 }, today: { cost: 0, tokens: 0 }, days: [], budget: { daily: null }, overBudget: false };
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
	const byConversation: { id: number; title: string; cost: number; tokens: number }[] = [];
	for (const [id, meta] of Object.entries(library.conversations)) {
		const usage = usageTotals((await harness.snapshot(UsageDoc, Number(id) as unknown as ConversationId, context)) as UsageDocShape | undefined);
		if (usage.tokens === 0) continue;
		const agent = byAgent.get(meta.agentId ?? "") ?? { cost: 0, tokens: 0 };
		agent.cost += usage.cost;
		agent.tokens += usage.tokens;
		byAgent.set(meta.agentId ?? "", agent);
		// A subagent's spend is shown under the conversation that started it.
		const root = meta.parent ?? Number(id);
		const row = byConversation.find((r) => r.id === root);
		if (row !== undefined) {
			row.cost += usage.cost;
			row.tokens += usage.tokens;
		} else if (library.conversations[String(root)]?.archived !== true) {
			byConversation.push({ id: root, title: library.conversations[String(root)]?.title ?? "", ...usage });
		}
	}
	usageSummary = {
		event: "usage",
		models: Object.entries(session.models ?? {})
			.map(([key, usage]) => ({ key, input: usage.input ?? 0, output: usage.output ?? 0, tokens: usage.totalTokens ?? 0, cost: costOf(key, usage), subscription: onSubscription(key) }))
			.sort((x, y) => y.tokens - x.tokens),
		agents: [...byAgent].map(([agentId, usage]) => ({ agentId, ...usage })).sort((x, y) => y.tokens - x.tokens),
		conversations: byConversation.sort((x, y) => y.cost - x.cost || y.tokens - x.tokens).slice(0, 8),
		total,
		today,
		days: Object.entries(spend.days).sort(([x], [y]) => x.localeCompare(y)).slice(-14).map(([day, usage]) => ({ day, ...usage })),
		budget: { daily: settings.dailyBudget ?? null },
		overBudget: overBudget(),
	};
	broadcast(usageSummary);
}
let usageTimer: ReturnType<typeof setTimeout> | undefined;
/** Usage changes when work ends; recount shortly after, once, however many tasks finished together. */
const scheduleUsageRefresh = () => {
	clearTimeout(usageTimer);
	usageTimer = setTimeout(() => void refreshUsage().catch((error) => log("usage refresh failed:", error)), 400);
};
await refreshUsage();

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
		const change = await agentChange(agent, { delegate: true });
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
	const client: Client = { socket, subscriptions: new Map() };
	clients.add(client);
	send(client, libraryEvent());
	send(client, agentsEvent());
	send(client, inboxEvent());
	send(client, activityEvent());
	send(client, schedulesEvent());
	send(client, recoveryEvent());
	send(client, usageSummary);
	send(client, mcpEvent());
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
	};
	socket.on("close", drop);
	socket.on("error", drop);
});
server.listen(socketPath, () => {
	log(`listening on ${socketPath}`);
	harness.resume(); // continue any run the last process left unfinished
	void tickSchedules(); // and start whatever came due while the engine was not running
	void mcp.start(); // connect to MCP servers without holding up the app
});

// A clean stop closes the Harness. SIGKILL is the crash case and needs no handler: reopening recovers.
let stopping = false;
async function stop(): Promise<void> {
	if (stopping) return;
	stopping = true;
	server.close();
	for (const client of clients) client.socket.destroy();
	clearTimeout(scheduleTimer);
	clearTimeout(usageTimer);
	await mcp.stop();
	await harness.close(context);
	rmSync(socketPath, { force: true });
	rmSync(runningMarker, { force: true });
	process.exit(0);
}
process.on("SIGINT", () => void stop());
process.on("SIGTERM", () => void stop());
