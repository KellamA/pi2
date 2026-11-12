// pi2-engine: hosts one pi durable Harness on SQLite and serves it to the app over a Unix socket.
// Wire format: one JSON object per line. Requests are { id, method, params } and are answered { id, result } or
// { id, error }; the methods are the keys of `handlers` below. The engine also pushes { event, ... } messages:
// "library", "providers", "conversation" (for opened conversations) and "auth" (during a sign-in).

import { existsSync, mkdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { connect, createServer, type Socket } from "node:net";
import { homedir } from "node:os";
import { join } from "node:path";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import type { AuthEvent, AuthPrompt } from "@earendil-works/pi-ai";
import {
	type Conversation,
	type ConversationId,
	type ConversationView,
	createRegistry,
	defineDoc,
	type EntryRecord,
	Harness,
	type SubmissionId,
} from "@earendil-works/pi-durable";
import { NodeExecutionEnv } from "@earendil-works/pi-durable/env/node";
import { openNodeSqliteStorage } from "@earendil-works/pi-durable/storage/sqlite/node";
import { CodingTools } from "@earendil-works/pi-durable/tools";
import { KeychainCredentialStore } from "./credentials.ts";
import { DEMO_MODEL, DEMO_PROVIDER, Providers } from "./providers.ts";

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
if (alreadyRunning) {
	log("another engine is already running on", socketPath);
	process.exit(3);
}
writeFileSync(join(home, "engine.pid"), String(process.pid));

// ---- Models, tools, harness

type ModelRef = { provider: string; modelId: string };
type Access = "none" | "read" | "full";
type Meta = { title: string; createdAt: number; updatedAt: number; archived?: boolean; access: Access };

const providers = new Providers(home, new KeychainCredentialStore(home));
const registry = createRegistry();
registry.install(CodingTools);
const readTool = CodingTools.tools!.find((tool) => tool.name === "read")!;
/** What `configure({ tools })` takes for an access level: nothing, read only, or everything installed. */
const toolsFor = (access: Access) => (access === "none" ? [] : access === "read" ? [readTool] : null);

/** The app's own index of conversations: titles, order, and tool access. Committed like everything else. */
const Library = defineDoc<{ conversations: Record<string, Meta> }>({
	kind: "pi2.library",
	version: 1,
	scope: "session",
	initial: () => ({ conversations: {} }),
	checkpointWhen: () => true,
});

const storage = await openNodeSqliteStorage(join(home, "session.sqlite"));
const harness = await Harness.open(
	storage,
	{
		models: providers.models,
		registry,
		env: ({ cwd }) => new NodeExecutionEnv({ cwd: cwd ?? homedir() }),
		identity: { attribution: { name: "pi2", url: "https://github.com/earendil-works/pi" } },
		onReport: (report) => log("report", report.kind, report.error instanceof Error ? report.error.message : ""),
	},
	context,
);

const settingsPath = join(home, "settings.json");
const settings: { defaultModel?: ModelRef } = (() => {
	try {
		return JSON.parse(readFileSync(settingsPath, "utf8"));
	} catch {
		return {};
	}
})();
const saveSettings = () => writeFileSync(settingsPath, JSON.stringify(settings, null, "\t"));

async function conversation(id: unknown): Promise<Conversation> {
	const found = typeof id === "number" ? await harness.conversation(id as ConversationId, context) : undefined;
	if (found === undefined) throw new Error(`Unknown conversation: ${String(id)}`);
	return found;
}

async function editMeta(id: ConversationId, change: (meta: Meta) => void): Promise<void> {
	await harness.commit(async (tx) => {
		const meta = (await tx.doc(Library)).conversations[String(id)];
		if (meta !== undefined) change(meta);
	}, context);
}

// ---- What the app is sent

function textOf(content: unknown): string {
	if (typeof content === "string") return content;
	if (!Array.isArray(content)) return "";
	return content.map((block) => (block?.type === "text" && typeof block.text === "string" ? block.text : block?.type === "image" ? "[image]" : "")).join("");
}

type ToolCall = { callId: string; name: string; arguments: unknown };
type Item =
	| { id: number; kind: "user"; text: string }
	| { id: number; kind: "assistant"; text: string; thinking: string; toolCalls: ToolCall[]; stop: string; error: string | null; model: string | null }
	| { id: number; kind: "tool"; callId: string; name: string; text: string; isError: boolean }
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

function toItem(entry: EntryRecord): Item | undefined {
	const id = entry.id as unknown as number;
	if (entry.kind === "pi.reset") return { id, kind: "marker", text: "Context reset" };
	if (entry.kind === "pi.compaction") return { id, kind: "marker", text: "Earlier messages were summarized" };
	const message = entry.model?.[0] as (AssistantLike & { role?: string; toolCallId?: string; toolName?: string; isError?: boolean }) | undefined;
	if (message === undefined) return undefined;
	switch (message.role) {
		case "user":
			return { id, kind: "user", text: textOf(message.content) };
		case "assistant":
			return { id, kind: "assistant", ...assistantParts(message), stop: message.stopReason ?? "stop", error: message.errorMessage ?? null, model: message.model ?? null };
		case "toolResult":
			return { id, kind: "tool", callId: String(message.toolCallId), name: String(message.toolName), text: textOf(message.content), isError: message.isError === true };
		default:
			return undefined;
	}
}

type LiveDocShape = {
	run?: { turns?: number };
	generation?: { message?: AssistantLike; retry?: { at: number; error: string } };
	tools?: { callId: string; name: string; status: string; output?: string }[];
	runFailure?: { reason: string; detail?: string };
};

function stateOf(view: ConversationView, meta: Meta | undefined) {
	const live = (view.docs["pi.live"] ?? {}) as LiveDocShape;
	const agent = (view.docs["pi.agent"] ?? {}) as { model?: ModelRef; thinkingLevel?: string; cwd?: string };
	const inbox = (view.docs["pi.inbox"] ?? {}) as { items?: { id: number; mode: string; content?: unknown }[] };
	const partial = live.generation?.message;
	return {
		busy: live.run !== undefined,
		turns: live.run?.turns ?? 0,
		partial: partial === undefined ? null : assistantParts(partial),
		retry: live.generation?.retry ?? null,
		tools: (live.tools ?? []).map((slot) => ({ callId: slot.callId, name: slot.name, status: slot.status, output: slot.output ?? "" })),
		failure: live.runFailure === undefined ? null : { reason: live.runFailure.reason, detail: live.runFailure.detail ?? null },
		queued: (inbox.items ?? []).filter((item) => item.mode !== "write").map((item) => ({ id: item.id, mode: item.mode, text: textOf(item.content) })),
		agent: { model: agent.model ?? null, thinkingLevel: agent.thinkingLevel ?? null, cwd: agent.cwd ?? null, access: meta?.access ?? "none" },
	};
}

// ---- Clients

type Subscription = { push: () => void; stop: () => Promise<unknown> };
type Client = { socket: Socket; subscriptions: Map<number, Subscription> };
const clients = new Set<Client>();
const pendingPrompts = new Map<string, (answer: string) => void>();
const logins = new Map<string, AbortController>();
let nextLocalId = 1;

function send(client: Client, message: unknown): void {
	if (!client.socket.destroyed) client.socket.write(`${JSON.stringify(message)}\n`);
}
function broadcast(message: unknown): void {
	for (const client of clients) send(client, message);
}

let library = (await harness.snapshot(Library, context)) ?? { conversations: {} };
let busyConversations = new Set<number>();

function libraryEvent() {
	const conversations = Object.entries(library.conversations)
		.filter(([, meta]) => meta.archived !== true)
		.map(([id, meta]) => ({ id: Number(id), title: meta.title, updatedAt: meta.updatedAt, busy: busyConversations.has(Number(id)) }))
		.sort((a, b) => b.updatedAt - a.updatedAt);
	return { event: "library", conversations };
}

async function providersEvent() {
	const [list, models] = await Promise.all([providers.listProviders(), providers.listModels()]);
	return { event: "providers", providers: list, models, defaultModel: await defaultModel() };
}
async function announceProviders(): Promise<void> {
	broadcast(await providersEvent());
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
		const model = (params.model as ModelRef | undefined) ?? (await defaultModel());
		const now = Date.now();
		const created = await harness.createConversation(
			{
				ownership: { kind: "ownerless" },
				agent: { model, tools: [] },
				init: async (tx, id) => {
					(await tx.doc(Library)).conversations[String(id)] = { title: "", createdAt: now, updatedAt: now, access: "none" };
				},
			},
			context,
		);
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
			if (!["none", "read", "full"].includes(access)) throw new Error(`Unknown access level: ${String(access)}`);
			await conv.configure({ tools: toolsFor(access) }, context);
			await editMeta(conv.id, (meta) => void (meta.access = access));
			for (const other of clients) other.subscriptions.get(id)?.push();
		}
		void client;
		return {};
	},
	submit: async (params) => {
		const conv = await conversation(params.id);
		const content = text(params, "text");
		if (content.trim() === "") throw new Error("The message is empty");
		const submission = await conv.submit(
			{
				type: "input",
				content,
				whenBusy: params.mode === "steer" ? "steer" : "followUp",
				...(typeof params.requestId === "string" ? { requestId: params.requestId } : {}),
			},
			context,
		);
		await editMeta(conv.id, (meta) => {
			meta.updatedAt = Date.now();
			if (meta.title === "") meta.title = content.trim().split("\n")[0]!.slice(0, 60);
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

// ---- Live indexes: the library document and which conversations have work running

// The document must exist before it can be watched; this creates it on a first launch.
await harness.commit(async (tx) => void (await tx.doc(Library)), context);
const libraryWatch = await harness.watchDoc(Library, context);
if (libraryWatch === undefined) throw new Error("The library document could not be opened");
libraryWatch.start(async (call) => {
	if (call.kind !== "value") return;
	library = call.value;
	broadcast(libraryEvent());
});
const graphWatch = await harness.watchTaskGraph(context);
const busyFrom = (graph: { tasks: Record<string, { conversationId?: unknown }> }) =>
	new Set(Object.values(graph.tasks).map((task) => task.conversationId as number));
busyConversations = busyFrom(graphWatch.value as never);
graphWatch.start(async (call) => {
	if (call.kind !== "value") return;
	const next = busyFrom(call.value as never);
	const changed = next.size !== busyConversations.size || [...next].some((id) => !busyConversations.has(id));
	busyConversations = next;
	if (changed) broadcast(libraryEvent());
});

// ---- Socket server

rmSync(socketPath, { force: true }); // a socket file a killed engine left behind
const server = createServer((socket) => {
	const client: Client = { socket, subscriptions: new Map() };
	clients.add(client);
	send(client, libraryEvent());
	void providersEvent().then((event) => send(client, event));
	let buffer = "";
	socket.setEncoding("utf8");
	socket.on("data", (chunk: string) => {
		buffer += chunk;
		for (let newline = buffer.indexOf("\n"); newline !== -1; newline = buffer.indexOf("\n")) {
			const line = buffer.slice(0, newline);
			buffer = buffer.slice(newline + 1);
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
		for (const subscription of client.subscriptions.values()) void subscription.stop();
	};
	socket.on("close", drop);
	socket.on("error", drop);
});
server.listen(socketPath, () => {
	log(`listening on ${socketPath}`);
	harness.resume(); // continue any run the last process left unfinished
});

// A clean stop closes the Harness. SIGKILL is the crash case and needs no handler: reopening recovers.
let stopping = false;
async function stop(): Promise<void> {
	if (stopping) return;
	stopping = true;
	server.close();
	for (const client of clients) client.socket.destroy();
	await harness.close(context);
	rmSync(socketPath, { force: true });
	process.exit(0);
}
process.on("SIGINT", () => void stop());
process.on("SIGTERM", () => void stop());
