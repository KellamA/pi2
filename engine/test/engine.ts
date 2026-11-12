// End-to-end checks of the engine over its socket, on a throwaway data folder and a throwaway Keychain service.

import assert from "node:assert/strict";
import { type ChildProcess, execFileSync, spawn } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, rmSync, statSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { connect, type Socket } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";
import { newestOnly } from "../src/providers.ts";

const home = mkdtempSync(join(tmpdir(), "pi2-test-"));
const workdir = realpathSync(mkdtempSync(join(tmpdir(), "pi2-work-")));
const socketPath = join(home, "engine.sock");
const main = join(import.meta.dirname, "..", "src", "main.ts");
const KEYCHAIN_SERVICE = "dev.pi2.credentials.test";

type Item = { id: number; kind: string; text: string; callId?: string; name?: string; isError?: boolean; stop?: string; details?: any; toolCalls?: { callId: string; name: string }[] };
type InboxItem = { id: string; kind: string; conversationId: number; rootConversationId: number; tool: string; question: string | null; agentName: string | null; callId: string };
type State = { usage: { cost: number; tokens: number }; context: { used: number; window: number | null }; busy: boolean; partial: { text: string } | null; failure: { reason: string } | null; queued: { id: number; text: string }[]; agent: { model: { provider: string; modelId: string } | null; access: string; cwd: string | null; agentId: string | null; parent: number | null }; tools: { name: string; status: string }[] };
type Conv = { items: Item[]; state: State };

function startEngine(): ChildProcess {
	return spawn(process.execPath, [main], { env: { ...process.env, PI2_HOME: home, PI2_KEYCHAIN_SERVICE: KEYCHAIN_SERVICE, PI2_DEMO_COST: "5", PI2_DEMO_TEXT_MODEL: "1" }, stdio: ["ignore", "ignore", "inherit"] });
}

class Client {
	socket!: Socket;
	conversations = new Map<number, Conv>();
	library: { id: number; title: string; busy: boolean; parent: number | null }[] = [];
	agents: { id: string; name: string; access: string; delegates: string[] }[] = [];
	inbox: InboxItem[] = [];
	activity: { conversationId: number; rootConversationId: number; status: string }[] = [];
	schedules: { id: string; title: string; enabled: boolean; nextRunAt: number | null; lastConversationId: number | null; pending: unknown }[] = [];
	recovery: { at: number; conversations: { id: number }[] } | null | undefined;
	usage: any;
	mcp: { id: string; status: string; error: string | null; tools: { name: string; toolName: string; readOnly: boolean }[] }[] = [];
	providers: { id: string; kind: string; status: unknown; oauth: { subscription: boolean } | null }[] = [];
	models: { provider: string; id: string }[] = [];
	/** As the app does for computer use: what the engine asked this client to do on screen, and how it answers. */
	computerRequests: any[] = [];
	computerReply: ((request: any) => Record<string, unknown> | undefined) | undefined;
	#nextId = 1;
	#replies = new Map<number, { resolve: (v: any) => void; reject: (e: Error) => void }>();
	#wake: (() => void) | undefined;

	static async attach(): Promise<Client> {
		const client = new Client();
		// A killed engine leaves its socket file behind, so retry until the new one is listening.
		for (let attempt = 0; ; attempt++) {
			try {
				if (!existsSync(socketPath)) throw new Error("no socket yet");
				client.socket = connect(socketPath);
				await new Promise<void>((resolve, reject) => client.socket.once("connect", resolve).once("error", reject));
				break;
			} catch (error) {
				if (attempt >= 200) throw error;
				await sleep(50);
			}
		}
		let buffer = "";
		client.socket.setEncoding("utf8").on("data", (chunk: string) => {
			buffer += chunk;
			const lines = buffer.split("\n");
			buffer = lines.pop()!;
			for (const line of lines) client.receive(JSON.parse(line));
			client.#wake?.();
		});
		client.socket.on("error", () => {});
		return client;
	}

	receive(message: any): void {
		if (message.event === "library") this.library = message.conversations;
		else if (message.event === "agents") this.agents = message.agents;
		else if (message.event === "inbox") this.inbox = message.items;
		else if (message.event === "activity") this.activity = message.runs;
		else if (message.event === "schedules") this.schedules = message.schedules;
		else if (message.event === "recovery") this.recovery = message.recovery;
		else if (message.event === "usage") this.usage = message;
		else if (message.event === "mcp") this.mcp = message.servers;
		else if (message.event === "providers") {
			this.providers = message.providers;
			this.models = message.models;
		} else if (message.event === "computer") {
			this.computerRequests.push(message);
			const reply = this.computerReply?.(message);
			if (reply !== undefined) void this.call("computer.result", { requestId: message.requestId, ...reply }).catch(() => {});
		} else if (message.event === "conversation") {
			const conv: Conv = this.conversations.get(message.id) ?? { items: [], state: message.state };
			if (message.reset) conv.items = [];
			conv.items.push(...message.items);
			conv.state = message.state;
			this.conversations.set(message.id, conv);
		} else if (message.id !== undefined && message.id !== null) {
			const reply = this.#replies.get(message.id);
			this.#replies.delete(message.id);
			if (message.error !== undefined) reply?.reject(new Error(message.error));
			else reply?.resolve(message.result);
		}
	}

	call(method: string, params: Record<string, unknown> = {}): Promise<any> {
		const id = this.#nextId++;
		this.socket.write(`${JSON.stringify({ id, method, params })}\n`);
		return new Promise((resolve, reject) => this.#replies.set(id, { resolve, reject }));
	}

	async until<T>(what: string, check: () => T | undefined | false, timeoutMs = 60_000): Promise<T> {
		const deadline = Date.now() + timeoutMs;
		for (;;) {
			const value = check();
			if (value !== undefined && value !== false) return value;
			if (Date.now() > deadline) throw new Error(`Timed out waiting for: ${what}`);
			await Promise.race([new Promise<void>((resolve) => (this.#wake = resolve)), sleep(250)]);
		}
	}

	idle(id: number): Promise<Conv> {
		return this.until(`conversation ${id} idle`, () => {
			const conv = this.conversations.get(id);
			return conv !== undefined && !conv.state.busy && conv.items.some((i) => i.kind === "assistant") ? conv : undefined;
		});
	}
}

// A minimal MCP server over stdio: one read-only tool and one that claims to change things.
const MCP_TEST_SERVER = `
import { createInterface } from "node:readline";
const reply = (id, result) => process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, result }) + "\\n");
createInterface({ input: process.stdin }).on("line", (line) => {
	const message = JSON.parse(line);
	if (message.method === "initialize") reply(message.id, { protocolVersion: message.params.protocolVersion, capabilities: { tools: {} }, serverInfo: { name: "echo", version: "1" } });
	else if (message.method === "tools/list") reply(message.id, { tools: [
		{ name: "echo", description: "Echo text back", inputSchema: { type: "object", properties: { text: { type: "string" } }, required: ["text"] }, annotations: { readOnlyHint: true } },
		{ name: "write_note", description: "Pretend to save a note", inputSchema: { type: "object", properties: { text: { type: "string" } } } },
	] });
	else if (message.method === "tools/call") reply(message.id, { content: [{ type: "text", text: (message.params.name === "echo" ? "echo: " : "saved: ") + message.params.arguments.text }] });
	else if (message.id !== undefined) reply(message.id, {});
});
`;

function step(name: string): void {
	console.log(`ok  ${name}`);
}

// A minimal OpenAI-compatible server: lists one model and streams a fixed answer.
let seenAuthorization: string | undefined;
const mock = createServer((request, response) => {
	if (request.method === "GET" && request.url === "/v1/models") {
		response.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({ object: "list", data: [{ id: "mock-1", object: "model" }] }));
		return;
	}
	if (request.method === "POST" && request.url === "/v1/chat/completions") {
		seenAuthorization = request.headers.authorization;
		request.resume().on("end", () => {
			response.writeHead(200, { "content-type": "text/event-stream" });
			const chunk = (delta: object, finish: string | null) =>
				response.write(`data: ${JSON.stringify({ id: "c1", object: "chat.completion.chunk", created: 1, model: "mock-1", choices: [{ index: 0, delta, finish_reason: finish }] })}\n\n`);
			chunk({ role: "assistant", content: "Hello " }, null);
			chunk({ content: "from the " }, null);
			chunk({ content: "mock endpoint." }, null);
			chunk({}, "stop");
			response.end("data: [DONE]\n\n");
		});
		return;
	}
	response.writeHead(404).end();
});
await new Promise<void>((resolve) => mock.listen(0, "127.0.0.1", resolve));
const mockUrl = `http://127.0.0.1:${(mock.address() as { port: number }).port}/v1`;

function cleanKeychain(): void {
	for (const account of ["groq", "custom-mock-box"]) {
		try {
			execFileSync("/usr/bin/security", ["delete-generic-password", "-s", KEYCHAIN_SERVICE, "-a", account], { stdio: "ignore" });
		} catch {}
	}
}
cleanKeychain(); // anything an earlier failed run left behind

let backupPath = "";
let restoredId = -1;
let engine = startEngine();
try {
	let client = await Client.attach();
	await client.until("providers", () => client.providers.length > 0);

	// ---- Conversations and the demo model
	const { id: a } = await client.call("conversation.create");
	await client.call("conversation.open", { id: a });
	await client.call("submit", { id: a, text: "hello there", requestId: "r1" });
	let conv = await client.idle(a);
	assert.deepEqual(conv.items.map((i) => i.kind), ["user", "assistant"]);
	assert.ok(conv.items[1]!.text.endsWith("Done."));
	assert.equal(client.library.find((c) => c.id === a)?.title, "hello there");
	step("create, submit, streamed answer, automatic title");

	// ---- Tool access: off by default
	await client.call("submit", { id: a, text: "/bash echo should-not-run" });
	conv = await client.until("blocked tool result", () => {
		const c = client.conversations.get(a)!;
		return !c.state.busy && c.items.some((i) => i.kind === "tool") ? c : undefined;
	});
	const blocked = conv.items.find((i) => i.kind === "tool")!;
	assert.equal(blocked.isError, true);
	assert.ok(!blocked.text.includes("should-not-run\n"), "the command did not run");
	step("tools are off by default: the call is refused");

	// ---- Tool access: full, in a chosen folder
	const { id: b } = await client.call("conversation.create");
	await client.call("conversation.open", { id: b });
	await client.call("conversation.configure", { id: b, access: "full", cwd: workdir });
	await client.until("access applied", () => client.conversations.get(b)?.state.agent.access === "full");
	await client.call("submit", { id: b, text: "/bash pwd && echo tool-ran" });
	conv = await client.until("tool result", () => {
		const c = client.conversations.get(b)!;
		return !c.state.busy && c.items.filter((i) => i.kind === "assistant").length === 2 ? c : undefined;
	});
	const result = conv.items.find((i) => i.kind === "tool")!;
	assert.equal(result.isError, false);
	assert.ok(result.text.includes(workdir) && result.text.includes("tool-ran"), `bash ran in the folder: ${result.text}`);
	assert.equal(conv.items.find((i) => i.kind === "assistant")!.toolCalls![0]!.callId, result.callId);
	await assert.rejects(client.call("conversation.configure", { id: b, cwd: "/definitely/not/here" }), /Not a folder/);
	step("full access: bash runs in the conversation's folder, result linked to its call");

	// ---- Queue while busy, withdraw, stop
	await client.call("submit", { id: b, text: "first" });
	await client.until("busy", () => client.conversations.get(b)!.state.busy);
	await client.call("submit", { id: b, text: "queued follow-up", mode: "queue" });
	const queued = await client.until("queued item", () => client.conversations.get(b)!.state.queued[0]);
	assert.equal(queued.text, "queued follow-up");
	await client.call("withdraw", { submissionId: queued.id });
	await client.until("queue emptied", () => client.conversations.get(b)!.state.queued.length === 0);
	await client.call("abort", { id: b });
	await client.until("stopped", () => !client.conversations.get(b)!.state.busy);
	assert.ok(!client.conversations.get(b)!.items.some((i) => i.text === "queued follow-up"));
	step("queue a follow-up while busy, withdraw it, stop the run");

	// ---- Crash mid-answer, resume from storage
	const { id: c } = await client.call("conversation.create");
	await client.call("conversation.open", { id: c });
	await client.call("submit", { id: c, text: "survive this", requestId: "crash-1" });
	await client.until("partial answer", () => (client.conversations.get(c)?.state.partial?.text.length ?? 0) > 40);
	await sleep(1200); // let the deferred partial reach storage
	engine.kill("SIGKILL");
	await new Promise((resolve) => engine.once("exit", resolve));
	engine = startEngine();
	client = await Client.attach();
	await client.call("conversation.open", { id: c });
	conv = await client.until("recovered answer", () => {
		const v = client.conversations.get(c);
		return v !== undefined && !v.state.busy && v.items.some((i) => i.kind === "assistant" && i.stop === "stop") ? v : undefined;
	});
	assert.equal(conv.items.filter((i) => i.kind === "user").length, 1);
	assert.equal(conv.items.filter((i) => i.kind === "assistant" && i.stop === "stop").length, 1);
	assert.equal(client.library.length, 3, "the library survived the crash");
	step(`kill -9 mid-answer: resumed, ${conv.items.filter((i) => i.kind === "assistant" && i.stop !== "stop").length} interrupted attempt kept`);

	// ---- Agents
	await client.until("agents", () => client.agents.length > 0);
	assert.deepEqual(client.agents.map((x) => x.id), ["atlas", "forge", "scout"]);
	const { id: f } = await client.call("conversation.create", { agentId: "forge" });
	await client.call("conversation.open", { id: f });
	await client.call("conversation.configure", { id: f, cwd: workdir });
	let forge = await client.until("forge conversation", () => client.conversations.get(f));
	assert.equal(forge.state.agent.agentId, "forge");
	assert.equal(forge.state.agent.access, "ask");
	step("three starter agents; a conversation starts with its agent's setup");

	// ---- Approvals
	const toolResults = (id: number) => client.conversations.get(id)!.items.filter((i) => i.kind === "tool");
	const settled = (id: number, results: number) =>
		client.until(`${results} tool result(s) and idle`, () => {
			const v = client.conversations.get(id)!;
			return !v.state.busy && toolResults(id).length === results ? v : undefined;
		});
	await client.call("submit", { id: f, text: "/bash echo approved-ran" });
	let ask = await client.until("approval request", () => client.inbox.find((i) => i.conversationId === f));
	assert.equal(ask.kind, "approval");
	assert.equal(ask.tool, "bash");
	await sleep(500);
	assert.equal(toolResults(f).length, 0, "nothing runs before the decision");
	assert.equal(client.activity.find((run) => run.conversationId === f)?.status, "waiting", "the activity feed shows it waiting on the person");
	await client.call("inbox.decide", { id: ask.id, decision: "once" });
	await settled(f, 1);
	assert.ok(toolResults(f)[0]!.text.includes("approved-ran"));
	assert.equal(client.inbox.length, 0);
	step("a gated command waits for approval, then runs");

	await client.call("submit", { id: f, text: "/bash echo must-not-run" });
	ask = await client.until("second approval request", () => client.inbox.find((i) => i.conversationId === f));
	await client.call("inbox.decide", { id: ask.id, decision: "deny" });
	await settled(f, 2);
	assert.equal(toolResults(f)[1]!.isError, true);
	assert.ok(!toolResults(f)[1]!.text.includes("must-not-run\n") && /declined/.test(toolResults(f)[1]!.text));
	step("denying blocks the command and tells the model");

	// ---- An approval survives a crash
	await client.call("submit", { id: f, text: "/bash echo after-crash" });
	await client.until("approval before crash", () => client.inbox.find((i) => i.conversationId === f));
	engine.kill("SIGKILL");
	await new Promise((resolve) => engine.once("exit", resolve));
	engine = startEngine();
	client = await Client.attach();
	await client.call("conversation.open", { id: f });
	ask = await client.until("approval asked again after restart", () => client.inbox.find((i) => i.conversationId === f));
	await client.call("inbox.decide", { id: ask.id, decision: "always" });
	await settled(f, 3);
	assert.ok(toolResults(f)[2]!.text.includes("after-crash"));
	step("kill -9 while waiting: the approval is asked again, then the command runs once");

	await client.call("submit", { id: f, text: "/bash echo no-prompt" });
	await settled(f, 4);
	assert.ok(toolResults(f)[3]!.text.includes("no-prompt"));
	step("\"always allow\" skips the prompt for that tool in that conversation");

	// ---- Asking the person
	await client.call("submit", { id: f, text: "/ask Which colour?" });
	const question = await client.until("question", () => client.inbox.find((i) => i.kind === "question"));
	assert.equal(question.question, "Which colour?");
	await assert.rejects(client.call("inbox.answer", { id: question.id, text: "  " }), /empty/);
	await client.call("inbox.answer", { id: question.id, text: "blue" });
	await settled(f, 5);
	assert.equal(toolResults(f)[4]!.text, "blue");
	step("an agent asks a question and gets the answer");

	// ---- Delegation
	const { id: m } = await client.call("conversation.create", { agentId: "atlas" });
	await client.call("conversation.open", { id: m });
	await client.call("submit", { id: m, text: "/delegate Scout: say hi to the team" });
	await client.until("delegation finished", () => {
		const v = client.conversations.get(m);
		return v !== undefined && !v.state.busy && v.items.some((i) => i.kind === "tool") ? v : undefined;
	});
	const handoff = toolResults(m)[0]!;
	assert.equal(handoff.isError, false, handoff.text);
	assert.ok(handoff.text.includes('You said: "say hi to the team"'), "the subagent's answer comes back");
	const childId = handoff.details?.conversationId as number;
	assert.equal(typeof childId, "number", "the call's details name the subagent's conversation");
	assert.equal(client.library.find((x) => x.id === childId)?.parent, m, "the sub-chat is listed under the conversation that started it");
	assert.ok(handoff.text.includes(`chat: ${childId}`), "the agent is told how to continue the sub-chat");
	await client.call("conversation.open", { id: childId });
	const child = await client.until("child transcript", () => client.conversations.get(childId));
	assert.equal(child.state.agent.agentId, "scout");
	assert.equal(child.state.agent.parent, m);
	assert.equal(child.items[0]!.text, "say hi to the team");
	// Continue the same sub-chat instead of opening a new one.
	const subChats = () => client.library.filter((x) => x.parent === m).length;
	assert.equal(subChats(), 1);
	await client.call("submit", { id: m, text: `/continue ${childId}: and now say bye` });
	await client.until("continued", () => {
		const v = client.conversations.get(m)!;
		return !v.state.busy && toolResults(m).length === 2;
	});
	assert.equal(toolResults(m)[1]!.isError, false, toolResults(m)[1]!.text);
	assert.ok(toolResults(m)[1]!.text.includes('You said: "and now say bye"'));
	assert.equal(subChats(), 1, "no second sub-chat was opened");
	await client.until("sub-chat has both exchanges", () => client.conversations.get(childId)!.items.filter((i) => i.kind === "user").length === 2);
	await client.call("submit", { id: m, text: "/continue 999999: nothing there" });
	await client.until("bad continue refused", () => !client.conversations.get(m)!.state.busy && toolResults(m).length === 3);
	assert.equal(toolResults(m)[2]!.isError, true);
	await client.call("submit", { id: m, text: "/delegate Scout: a second piece of work" });
	await client.until("second sub-chat", () => subChats() === 2 && !client.conversations.get(m)!.state.busy);
	step("sub-chats: listed under their parent, continued by number, and a new one for new work");

	await client.call("submit", { id: f, text: "/delegate Scout: not allowed" });
	await settled(f, 6);
	assert.equal(toolResults(f)[5]!.isError, true, "Forge has no agents to delegate to");
	step("delegation: the subagent runs as its own agent and its answer returns; agents without delegates cannot");

	// ---- Editing agents
	await assert.rejects(client.call("agents.save", { agent: { name: "Atlas" } }), /already an agent/);
	const { id: custom } = await client.call("agents.save", { agent: { name: "Quill", description: "Writer", access: "read", delegates: ["scout"] } });
	await client.until("new agent", () => client.agents.some((x) => x.id === custom));
	await client.call("agents.save", { agent: { id: custom, name: "Quill", access: "none" } });
	await client.until("edited agent", () => client.agents.find((x) => x.id === custom)?.access === "none");
	await client.call("agents.delete", { id: "scout" });
	await client.until("agent deleted", () => !client.agents.some((x) => x.id === "scout"));
	assert.deepEqual(client.agents.find((x) => x.id === "atlas")!.delegates, ["forge"], "deleted agents leave other agents' lists");
	step("create, edit and delete agents");

	// ---- Reference files: read on demand, whatever the tool access, and nothing outside them
	const refs = join(home, "refs");
	mkdirSync(join(refs, "guides"), { recursive: true });
	writeFileSync(join(refs, "brief.md"), "The launch is on the 14th.\n");
	writeFileSync(join(refs, "guides", "style.md"), Array.from({ length: 30 }, (_, i) => `rule ${i + 1}`).join("\n"));
	writeFileSync(join(home, "secret.txt"), "not for agents");
	await assert.rejects(client.call("agents.save", { agent: { id: custom, name: "Quill", files: [{ path: join(refs, "nope.md") }] } }), /Not found/);
	await client.call("agents.save", { agent: { id: custom, name: "Quill", files: [{ path: join(refs, "brief.md"), note: "Launch facts" }, { path: join(refs, "guides") }] } });
	await client.until("files saved", () => (client.agents.find((x) => x.id === custom) as any)?.files?.length === 2);
	const { id: q } = await client.call("conversation.create", { agentId: custom });
	await client.call("conversation.open", { id: q });
	assert.equal(client.conversations.get(q)!.state.agent.access, "none");
	const openRef = async (path: string, results: number) => {
		await client.call("submit", { id: q, text: `/ref ${path}` });
		await settled(q, results);
		return toolResults(q)[results - 1]! as any;
	};
	assert.match((await openRef(join(refs, "brief.md"), 1)).text, /launch is on the 14th/);
	assert.match((await openRef(join(refs, "guides"), 2)).text, /style\.md/);
	assert.match((await openRef("style.md", 3)).text, /rule 30/);
	const refused = await openRef(join(home, "secret.txt"), 4);
	assert.ok(refused.isError && !refused.text.includes("not for agents"), "a file that was not listed cannot be read");
	assert.equal((await openRef(join(refs, "guides", "..", "..", "secret.txt"), 5)).isError, true, "nor one reached by climbing out of a folder");
	writeFileSync(join(refs, "brief.md"), "The launch moved to the 21st.\n");
	assert.match((await openRef("brief.md", 6)).text, /moved to the 21st/, "an edited file is read fresh");
	step("reference files: read and listed on demand with tools off, re-read after an edit, nothing outside them");

	// ---- Computer use: the engine decides and asks; a fake app stands in for the screen
	const NOTES = "com.example.notes";
	const MAIL = "com.example.mail";
	const PNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==";
	await assert.rejects(client.call("agents.save", { agent: { id: custom, name: "Quill", computer: { enabled: true, apps: ["com.apple.Terminal"] } } }), /cannot be given/);
	await client.call("agents.save", { agent: { id: custom, name: "Quill", computer: { enabled: true, apps: [NOTES, "com.apple.Safari"] } } });
	await client.until("computer use saved", () => (client.agents.find((x) => x.id === custom) as any)?.computer?.enabled === true);
	assert.equal((client.agents.find((x) => x.id === custom) as any).computer.ask, true, "asking first is the default");
	const { id: k } = await client.call("conversation.create", { agentId: custom });
	await client.call("conversation.open", { id: k });
	let computerCalls = 0;
	const use = async (args: Record<string, unknown>, wait = true) => {
		await client.call("submit", { id: k, text: `/computer ${JSON.stringify(args)}` });
		computerCalls++;
		if (!wait) return undefined as any;
		await settled(k, computerCalls);
		return toolResults(k)[computerCalls - 1]! as any;
	};
	const sentToApp = (action: string, app?: string) => client.computerRequests.filter((r) => r.action === action && (app === undefined || r.app === app));
	const lastAnswer = () => client.conversations.get(k)!.items.findLast((i) => i.kind === "assistant")!.text;

	const noApp = await use({ action: "list_apps" });
	assert.ok(noApp.isError && /not open/.test(noApp.text), "with no app connected there is no screen to use");

	client.computerReply = (request) => {
		if (request.action === "describe") return { ok: true, text: `Click the “New Note” button in ${request.app === MAIL ? "Mail" : "Notes"}` };
		if (request.action === "screenshot") return { ok: true, text: "Notes, window “All Notes”\n[1] button “New Note”", summary: "Looked at Notes", ...(request.image ? { image: { data: PNG, mimeType: "image/png" } } : {}) };
		if (request.action === "click") return { ok: true, text: "Clicked “New Note”.", summary: "Clicked “New Note”" };
		return { ok: true, text: "ok" };
	};
	await client.call("computer.register");

	const shot = await use({ action: "screenshot", app: NOTES });
	assert.ok(!shot.isError && shot.text.includes("[1] button") && !shot.text.includes("[image]"));
	assert.equal(shot.images, 1, "the transcript says there is a picture without carrying it");
	assert.equal(shot.details?.summary, "Looked at Notes");
	assert.equal(client.inbox.length, 0, "looking is never asked about");
	const sent = sentToApp("screenshot").at(-1);
	assert.ok(sent.image === true && sent.conversationId === k && sent.agentName === "Quill");
	assert.deepEqual(await client.call("conversation.image", { id: k, entryId: shot.id, index: 0 }), { data: PNG, mimeType: "image/png" });
	assert.match(lastAnswer(), /I can see 1 picture\./, "the screenshot reaches the model as an image");

	await use({ action: "click", app: NOTES, element: 1 }, false);
	const approval = await client.until("approval for the click", () => client.inbox.find((i) => i.tool === "computer"));
	assert.equal(approval.question, "Click the “New Note” button in Notes", "the approval says what will be clicked, in words");
	assert.equal(sentToApp("click").length, 0, "nothing is clicked while the question is open");
	await client.call("inbox.decide", { id: approval.id, decision: "always" });
	await settled(k, computerCalls);
	assert.equal(toolResults(k).at(-1)!.isError, false);
	assert.equal(sentToApp("click", NOTES).length, 1);
	await use({ action: "click", app: NOTES, element: 1 });
	assert.ok(client.inbox.length === 0 && sentToApp("click", NOTES).length === 2, "“always” covers that app for the rest of the conversation");

	const viewOnly = await use({ action: "click", app: "com.apple.Safari", x: 10, y: 10 });
	assert.ok(viewOnly.isError && /only be looked at/.test(viewOnly.text));
	const notAllowed = await use({ action: "screenshot", app: MAIL });
	assert.ok(notAllowed.isError && /may not use/.test(notAllowed.text));
	const incomplete = await use({ action: "click", app: NOTES });
	assert.ok(incomplete.isError && /needs `element`/.test(incomplete.text));
	assert.equal(client.inbox.length, 0, "a call that cannot run is refused without bothering the person");

	// Another app is asked about separately, and a refusal is final.
	await client.call("agents.save", { agent: { id: custom, name: "Quill", computer: { enabled: true, apps: [NOTES, MAIL, "com.apple.Safari"] } } });
	await client.until("mail added", () => (client.agents.find((x) => x.id === custom) as any)?.computer?.apps.includes(MAIL));
	await use({ action: "click", app: MAIL, element: 1 }, false);
	const second = await client.until("approval for the other app", () => client.inbox.find((i) => i.tool === "computer"));
	assert.match(second.question!, /in Mail$/);
	await client.call("inbox.decide", { id: second.id, decision: "deny" });
	await settled(k, computerCalls);
	assert.ok(toolResults(k).at(-1)!.isError && sentToApp("click", MAIL).length === 0, "a denied action never reaches the app");

	// Only the newest screenshots are sent to the model; the transcript keeps them all.
	for (let i = 0; i < 3; i++) await use({ action: "screenshot", app: NOTES });
	assert.match(lastAnswer(), /I can see 2 pictures\./);
	assert.equal(toolResults(k).filter((r: any) => r.images === 1).length, 4);

	// A model that cannot see images is given the list of controls and no picture is taken.
	await client.call("conversation.configure", { id: k, model: { provider: "demo", modelId: "demo-text" } });
	await client.until("text-only model", () => client.conversations.get(k)!.state.agent.model?.modelId === "demo-text");
	const blind = await use({ action: "screenshot", app: NOTES });
	assert.ok(sentToApp("screenshot").at(-1).image === false && blind.images === 0 && blind.text.includes("[1] button"));
	await client.call("conversation.configure", { id: k, model: { provider: "demo", modelId: "demo-1" } });
	await client.until("back to the demo model", () => client.conversations.get(k)!.state.agent.model?.modelId === "demo-1");

	// The app going away in the middle of an action ends the call instead of leaving it hanging.
	const app = await Client.attach();
	await app.call("computer.register");
	await use({ action: "click", app: NOTES, element: 1 }, false);
	await app.until("the second app is asked", () => app.computerRequests.some((r) => r.action === "click"));
	app.socket.destroy();
	await settled(k, computerCalls);
	assert.ok(toolResults(k).at(-1)!.isError && /closed before/.test(toolResults(k).at(-1)!.text));
	assert.equal((await use({ action: "list_apps" })).text, "ok", "the app that was there before takes over again");
	assert.deepEqual(sentToApp("list_apps").at(-1).apps, [NOTES, MAIL, "com.apple.Safari"], "the app is told which apps to list");
	await client.call("agents.save", { agent: { id: custom, name: "Quill", computer: { enabled: false, apps: [NOTES] } } });
	await client.until("computer use off", () => (client.agents.find((x) => x.id === custom) as any)?.computer?.enabled === false);
	assert.match((await use({ action: "list_apps" })).text, /turned off/);
	step("computer use: asks before acting and says what, app by app; refuses what is not allowed; trims old screenshots; survives the app closing");

	// ---- Schedules
	const { nextRun } = await import("../src/schedules.ts");
	const monday9 = new Date(2026, 10, 9, 9, 0).getTime(); // a Monday, 09:00 local
	assert.equal(nextRun({ kind: "daily", hour: 7, minute: 30 }, monday9), new Date(2026, 10, 10, 7, 30).getTime());
	assert.equal(nextRun({ kind: "daily", hour: 18, minute: 0 }, monday9), new Date(2026, 10, 9, 18, 0).getTime());
	assert.equal(nextRun({ kind: "weekly", weekday: 1, hour: 9, minute: 0 }, monday9), new Date(2026, 10, 16, 9, 0).getTime());
	assert.equal(nextRun({ kind: "once", at: monday9 - 1 }, monday9), null);
	await assert.rejects(client.call("schedules.save", { schedule: { title: "Late", agentId: "atlas", prompt: "x", repeat: { kind: "once", at: Date.now() - 1000 } } }), /already passed/);

	const countTitled = (title: string) => client.library.filter((x) => x.title === title).length;
	await client.call("schedules.save", { schedule: { title: "Soon", agentId: "atlas", prompt: "scheduled hello", repeat: { kind: "once", at: Date.now() + 1200 } } });
	await client.until("scheduled conversation", () => countTitled("Soon") === 1);
	const soonId = client.library.find((x) => x.title === "Soon")!.id;
	await client.call("conversation.open", { id: soonId });
	conv = await client.idle(soonId);
	assert.equal(conv.items[0]!.text, "scheduled hello");
	const soon = await client.until("schedule finished", () => client.schedules.find((x) => x.title === "Soon" && x.pending === null && !x.enabled));
	assert.equal(soon.nextRunAt, null);
	assert.equal(soon.lastConversationId, soonId);
	step("a one-off schedule starts a conversation with its agent at its time, then turns itself off");

	const { id: hourly } = await client.call("schedules.save", { schedule: { title: "Hourly", agentId: "atlas", prompt: "tick", repeat: { kind: "interval", minutes: 60 } } });
	const before = (await client.until("hourly saved", () => client.schedules.find((x) => x.id === hourly))).nextRunAt!;
	assert.ok(before > Date.now() + 59 * 60_000);
	await client.call("schedules.runNow", { id: hourly });
	await client.until("manual run", () => countTitled("Hourly") === 1);
	assert.equal(client.schedules.find((x) => x.id === hourly)!.nextRunAt, before, "running it by hand leaves the timetable alone");
	await client.call("schedules.delete", { id: hourly });
	await client.until("schedule deleted", () => !client.schedules.some((x) => x.id === hourly));
	step("a repeating schedule: next time computed, run now, delete");

	// ---- A schedule that comes due while the engine is down, and the recovery report
	await client.call("schedules.save", { schedule: { title: "Missed", agentId: "atlas", prompt: "catch up", repeat: { kind: "once", at: Date.now() + 2000 } } });
	await client.until("missed saved", () => client.schedules.some((x) => x.title === "Missed"));
	engine.kill("SIGKILL");
	await new Promise((resolve) => engine.once("exit", resolve));
	await sleep(2600);
	engine = startEngine();
	client = await Client.attach();
	await client.until("caught up", () => countTitled("Missed") === 1 && client.schedules.find((x) => x.title === "Missed")?.pending === null);
	await sleep(1500);
	assert.equal(countTitled("Missed"), 1, "a missed run happens once");
	assert.ok(client.recovery, "the engine reports that it restarted after an unclean stop");
	await client.call("recovery.dismiss");
	await client.until("report dismissed", () => client.recovery === null);
	step("a run that came due while the engine was down happens once on restart; the restart is reported");

	// ---- Usage, context size and the daily budget
	await client.call("conversation.open", { id: a });
	conv = await client.until("conversation a", () => client.conversations.get(a));
	assert.ok(conv.state.usage.tokens > 0 && conv.state.usage.cost > 0, "a conversation counts its own tokens and cost");
	assert.ok(conv.state.context.used > 0 && conv.state.context.window !== null, "and how full its context is");
	const usage = await client.until("usage summary", () => (client.usage?.total.tokens > 0 ? client.usage : undefined));
	assert.ok(Math.abs(usage.today.cost - usage.total.cost) < 1e-9 && usage.today.tokens === usage.total.tokens, "everything spent so far was spent today");
	assert.ok(usage.models.some((m: any) => m.key === "demo/demo-1"));
	assert.ok(usage.agents.some((x: any) => x.agentId === "atlas") && usage.conversations.length > 0);
	await client.call("usage.setBudget", { daily: 0.000001 });
	await client.until("over budget", () => client.usage.overBudget === true);
	await assert.rejects(client.call("submit", { id: a, text: "too expensive" }), /budget/);
	await client.call("usage.setBudget", { daily: null });
	await client.until("budget off", () => client.usage.overBudget === false);
	step("usage by model, agent and conversation; a used-up daily budget refuses new work until it is raised");

	// ---- Fork, reset, compact, search
	const firstAnswer = conv.items.find((i) => i.kind === "assistant")!;
	const { id: forkId } = await client.call("conversation.fork", { id: a, entryId: firstAnswer.id });
	await client.call("conversation.open", { id: forkId });
	const fork = await client.until("fork", () => (client.conversations.get(forkId)?.items.length === 2 ? client.conversations.get(forkId) : undefined));
	assert.deepEqual(fork.items.map((i) => i.text), conv.items.slice(0, 2).map((i) => i.text));
	assert.ok(client.library.find((x) => x.id === forkId)!.title.endsWith("(fork)"));
	const originalLength = conv.items.length;
	await client.call("submit", { id: forkId, text: "only in the fork" });
	await client.until("fork answered", () => {
		const v = client.conversations.get(forkId)!;
		return !v.state.busy && v.items.length === 4;
	});
	assert.equal(client.conversations.get(a)!.items.length, originalLength, "the original is untouched");
	const found = (await client.call("search", { query: "ONLY IN THE fork" })).results;
	assert.ok(found.some((r: any) => r.conversationId === forkId && r.role === "user" && r.snippet.includes("only in the fork")));
	assert.deepEqual((await client.call("search", { query: "zzz-not-there" })).results, []);
	await client.call("conversation.reset", { id: forkId, note: "We were testing forks." });
	await client.until("reset marker", () => client.conversations.get(forkId)!.items.some((i) => i.kind === "marker" && i.text === "Context reset"));
	await client.call("conversation.compact", { id: a });
	step("fork from a message, search across conversations, reset the context, ask for a compaction");

	// ---- Code mode
	const { id: scripter } = await client.call("agents.save", { agent: { name: "Scripter", access: "full", codeMode: true, cwd: workdir } });
	await client.until("scripter", () => client.agents.some((x) => x.id === scripter));
	const { id: sc } = await client.call("conversation.create", { agentId: scripter });
	await client.call("conversation.open", { id: sc });
	await client.call("submit", { id: sc, text: "/code const r = await tools.bash({ command: 'echo from-a-script' }); console.log('script saw: ' + r.output.trim());" });
	await client.until("script finished", () => {
		const v = client.conversations.get(sc);
		return v !== undefined && !v.state.busy && v.items.some((i) => i.kind === "tool") ? v : undefined;
	});
	const scriptResult = client.conversations.get(sc)!.items.find((i) => i.kind === "tool")!;
	assert.ok(scriptResult.text.includes("script saw: from-a-script"), `the script called a tool and printed its output: ${scriptResult.text}`);
	step("code mode: a script calls the conversation's tools");

	// ---- MCP servers
	const serverPath = join(home, "mcp-test-server.mjs");
	writeFileSync(serverPath, MCP_TEST_SERVER);
	const { id: server } = await client.call("mcp.save", { name: "Echo", transport: "stdio", command: process.execPath, args: [serverPath] });
	const connected = await client.until("mcp connected", () => client.mcp.find((x) => x.id === server && x.status !== "connecting"));
	assert.equal(connected.status, "connected", connected.error ?? "");
	assert.deepEqual(connected.tools.map((t) => [t.name, t.readOnly]), [["echo", true], ["write_note", false]]);
	const echoTool = connected.tools[0]!.toolName;
	const { id: caller } = await client.call("agents.save", { agent: { name: "Caller", access: "ask", mcpServers: [server] } });
	await client.until("caller", () => client.agents.some((x) => x.id === caller));
	const { id: mc } = await client.call("conversation.create", { agentId: caller });
	await client.call("conversation.open", { id: mc });
	await client.call("submit", { id: mc, text: `/mcp ${echoTool} {"text":"hello mcp"}` });
	await client.until("mcp result", () => {
		const v = client.conversations.get(mc);
		return v !== undefined && !v.state.busy && v.items.some((i) => i.kind === "tool") ? v : undefined;
	});
	assert.equal(client.conversations.get(mc)!.items.find((i) => i.kind === "tool")!.text, "echo: hello mcp");
	await client.call("submit", { id: mc, text: `/mcp ${connected.tools[1]!.toolName} {"text":"x"}` });
	const mcpAsk = await client.until("mcp approval", () => client.inbox.find((i) => i.conversationId === mc));
	assert.equal(mcpAsk.kind, "approval");
	await client.call("inbox.decide", { id: mcpAsk.id, decision: "once" });
	await client.until("mcp write result", () => {
		const v = client.conversations.get(mc)!;
		return !v.state.busy && v.items.filter((i) => i.kind === "tool").length === 2;
	});
	await assert.rejects(client.call("mcp.save", { name: "Bad", transport: "stdio", command: "" }), /command/);
	const { id: broken } = await client.call("mcp.save", { name: "Broken", transport: "stdio", command: "/definitely/not/a/program" });
	const failed = await client.until("broken server reported", () => client.mcp.find((x) => x.id === broken && x.status === "error"));
	assert.ok(failed.error);
	await client.call("mcp.delete", { id: broken });
	await client.call("mcp.delete", { id: server });
	await client.until("servers removed", () => client.mcp.length === 0);
	step("MCP: connect a server, call its tools, ask before tools that change things, report a server that will not start");

	// ---- Providers: built-ins, an API key in the Keychain, removing it
	const anthropic = client.providers.find((p) => p.id === "anthropic")!;
	assert.equal(anthropic.oauth?.subscription, true);
	assert.ok(client.providers.find((p) => p.id === "openai")?.oauth?.subscription);
	assert.equal(client.providers.find((p) => p.id === "groq")!.status, null);
	await client.call("providers.setKey", { id: "groq", key: "gsk_test_not_a_real_key" });
	await client.until("groq configured", () => client.providers.find((p) => p.id === "groq")!.status !== null);
	assert.ok(client.models.some((m) => m.provider === "groq"), "its models are offered once configured");
	const stored = execFileSync("/usr/bin/security", ["find-generic-password", "-s", KEYCHAIN_SERVICE, "-a", "groq", "-w"], { encoding: "utf8" });
	assert.equal(JSON.parse(stored).key, "gsk_test_not_a_real_key");
	const leaked = readdirSync(home).filter((name) => {
		const path = join(home, name);
		return statSync(path).isFile() && readFileSync(path).includes("gsk_test");
	});
	assert.deepEqual(leaked, [], "no secret on disk");
	step("API key stored in the Keychain, not on disk; provider becomes available");

	// ---- Choosing which of a provider's models show
	const groq = () => client.models.filter((m: any) => m.provider === "groq");
	const groqIds = groq().map((m: any) => m.id as string);
	assert.ok(groqIds.length > 1 && groq().every((m: any) => m.hidden === false));
	await client.call("providers.setHiddenModels", { id: "groq", hidden: groqIds.slice(1) });
	await client.until("all but one hidden", () => groq().filter((m: any) => !m.hidden).length === 1 && groq().length === groqIds.length);
	await assert.rejects(client.call("providers.setHiddenModels", { id: "groq", hidden: groqIds }), /at least one/);
	await client.call("providers.setHiddenModels", { id: "groq", newest: true });
	// Which of groq's models that hides depends on their names; the rule itself is checked below.
	await client.until("newest only", () => groq().filter((m: any) => !m.hidden).length > 1);
	await client.call("providers.setHiddenModels", { id: "groq", hidden: [] });
	await client.until("all showing", () => groq().every((m: any) => !m.hidden));
	assert.deepEqual([...newestOnly(["claude-opus-4-8", "claude-opus-5", "claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-4-5", "claude-haiku-4-5-20251001", "gpt-4o", "gpt-4o-2024-05-13"])].sort(), ["claude-haiku-4-5", "claude-opus-5-5", "claude-sonnet-5-5", "gpt-4o"]);
	step("models can be hidden per provider, never all of them; newest-only keeps one per family");

	await client.call("providers.logout", { id: "groq" });
	await client.until("groq removed", () => client.providers.find((p) => p.id === "groq")!.status === null);
	step("removing the key makes the provider unavailable again");

	// ---- A custom endpoint, with a key, end to end
	assert.deepEqual((await client.call("endpoints.probe", { baseUrl: mockUrl })).models, ["mock-1"]);
	await assert.rejects(client.call("endpoints.probe", { baseUrl: "http://127.0.0.1:9/v1" }), /Could not reach/);
	const { id: endpointId } = await client.call("endpoints.save", { name: "Mock Box", baseUrl: mockUrl, api: "openai-completions", models: [{ id: "mock-1" }], key: "mock-secret" });
	assert.equal(endpointId, "custom-mock-box");
	await client.until("endpoint model offered", () => client.models.some((m) => m.provider === endpointId && m.id === "mock-1"));
	const { id: d } = await client.call("conversation.create", { model: { provider: endpointId, modelId: "mock-1" } });
	await client.call("conversation.open", { id: d });
	await client.call("submit", { id: d, text: "hi endpoint" });
	conv = await client.idle(d);
	assert.equal(conv.state.failure, null);
	assert.equal(conv.items.find((i) => i.kind === "assistant")!.text, "Hello from the mock endpoint.");
	assert.equal(seenAuthorization, "Bearer mock-secret");
	step("custom OpenAI-compatible endpoint: probe, save, stream a chat, key sent from the Keychain");

	await client.call("conversation.configure", { id: d, model: { provider: "demo", modelId: "demo-1" } });
	await client.until("model switched", () => client.conversations.get(d)!.state.agent.model?.provider === "demo");
	await client.call("endpoints.remove", { id: endpointId });
	await client.until("endpoint gone", () => !client.providers.some((p) => p.id === endpointId));
	step("switch a conversation's model; remove the endpoint");

	// ---- Export and backup (taken before the archive below, so a restore brings that conversation back)
	const markdown = (await client.call("conversation.export", { id: b, format: "markdown" })).text as string;
	assert.ok(markdown.includes("## You") && markdown.includes("/bash pwd && echo tool-ran") && markdown.includes("**Tool: bash**") && markdown.includes("tool-ran"));
	const exported = JSON.parse((await client.call("conversation.export", { id: b, format: "json" })).text);
	assert.ok(exported.items.length >= 4 && exported.items[0].kind === "user");
	backupPath = (await client.call("backup.create", { directory: workdir })).path;
	assert.ok(existsSync(join(backupPath, "session.sqlite")) && existsSync(join(backupPath, "manifest.json")));
	await assert.rejects(client.call("backup.create", { directory: "/definitely/not/here" }), /Not a folder/);
	restoredId = d;
	step("export a conversation as Markdown and JSON; write a backup while running");

	await client.call("conversation.archive", { id: d });
	await client.until("archived", () => !client.library.some((x) => x.id === d));
	step("archive a conversation");

	// ---- Restore: stop the engine, put the backup back, start again
	const restoreArgs = [main, "--restore", backupPath];
	const restoreEnv = { ...process.env, PI2_HOME: home, PI2_KEYCHAIN_SERVICE: KEYCHAIN_SERVICE };
	assert.throws(() => execFileSync(process.execPath, restoreArgs, { env: restoreEnv, stdio: "pipe" }), "restoring is refused while the engine runs");
	engine.kill("SIGTERM");
	await new Promise((resolve) => engine.once("exit", resolve));
	assert.throws(() => execFileSync(process.execPath, [main, "--restore", workdir], { env: restoreEnv, stdio: "pipe" }), "a folder that is not a backup is refused");
	const restored = JSON.parse(execFileSync(process.execPath, restoreArgs, { env: restoreEnv, encoding: "utf8" }));
	assert.ok(existsSync(join(restored.previousDataMovedTo, "session.sqlite")), "the data that was replaced is kept aside");
	engine = startEngine();
	const afterRestore = await Client.attach();
	await afterRestore.until("restored library", () => afterRestore.library.some((x) => x.id === restoredId));
	step("restore a backup: the conversation archived after it is back, and the replaced data is kept");
	console.log("PASS");
} finally {
	engine.kill("SIGTERM");
	mock.close();
	await sleep(400);
	cleanKeychain();
	rmSync(home, { recursive: true, force: true });
	rmSync(workdir, { recursive: true, force: true });
}
process.exit(0);
