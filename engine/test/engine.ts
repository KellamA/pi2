// End-to-end checks of the engine over its socket, on a throwaway data folder and a throwaway Keychain service.

import assert from "node:assert/strict";
import { type ChildProcess, execFileSync, spawn } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, rmSync, statSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { connect, type Socket } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";
import { crc32, deflateSync } from "node:zlib";
import { newestOnly } from "../src/providers.ts";

const home = mkdtempSync(join(tmpdir(), "pi2-test-"));
const workdir = realpathSync(mkdtempSync(join(tmpdir(), "pi2-work-")));
/** Folders a check makes in the temporary folder, removed at the end with the data folder whether the checks passed or not. */
const scratchFolders: string[] = [];
function removedAtEnd(folder: string): string {
	scratchFolders.push(folder);
	return folder;
}
const socketPath = join(home, "engine.sock");
const main = join(import.meta.dirname, "..", "src", "main.ts");
// The demo model types slowly for people; every engine this test starts makes it fast.
process.env.PI2_DEMO_TOKENS_PER_SECOND ??= "1000";
// An engine a test starts keeps the PATH the test gave it, and reads nobody's shell profile (src/shellpath.ts).
process.env.PI2_LOGIN_SHELL ??= "off";
// Overridable so two copies of the suite can run at once without sharing Keychain items.
const KEYCHAIN_SERVICE = process.env.PI2_TEST_KEYCHAIN_SERVICE ?? "dev.pi2.credentials.test";

type Item = { id: number; kind: string; text: string; callId?: string; name?: string; isError?: boolean; stop?: string; details?: any; toolCalls?: { callId: string; name: string }[] };
type InboxItem = { id: string; kind: string; conversationId: number; rootConversationId: number; tool: string; question: string | null; agentName: string | null; callId: string };
type State = { usage: { cost: number; tokens: number }; context: { used: number; window: number | null }; busy: boolean; partial: { text: string } | null; failure: { reason: string } | null; queued: { id: number; text: string }[]; agent: { model: { provider: string; modelId: string } | null; access: string; cwd: string | null; agentId: string | null; parent: number | null }; tools: { name: string; status: string }[] };
type Conv = { items: Item[]; state: State };

function startEngine(): ChildProcess {
	return spawn(process.execPath, [main], { env: { ...process.env, PI2_HOME: home, PI2_KEYCHAIN_SERVICE: KEYCHAIN_SERVICE, PI2_DEMO_COST: "5", PI2_DEMO_TEXT_MODEL: "1", PI2_COMMAND_TIMEOUT_SECONDS: "3" }, stdio: ["ignore", "ignore", "inherit"] });
}

class Client {
	socket!: Socket;
	conversations = new Map<number, Conv>();
	library: { id: number; title: string; busy: boolean; parent: number | null }[] = [];
	archived: { id: number; title: string; archivedAt: number; subChats: number }[] = [];
	autoArchiveDays: number | null = null;
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
	/** The latest event of each kind not handled above. */
	events: Record<string, any> = {};
	computerRequests: any[] = [];
	computerReply: ((request: any) => Record<string, unknown> | undefined) | undefined;
	/** The same for the browser: what the engine asked this client to do in a web page, and how it answers. */
	browserRequests: any[] = [];
	browserReply: ((request: any) => Record<string, unknown> | undefined) | undefined;
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
		if (message.event === "library") {
			this.library = message.conversations;
			this.archived = message.archived;
			this.autoArchiveDays = message.autoArchiveDays;
		}
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
		} else if (message.event === "browser") {
			this.browserRequests.push(message);
			const reply = this.browserReply?.(message);
			if (reply !== undefined) void this.call("browser.result", { requestId: message.requestId, ...reply }).catch(() => {});
		} else if (message.event === "conversation") {
			const conv: Conv = this.conversations.get(message.id) ?? { items: [], state: message.state };
			if (message.reset) conv.items = [];
			conv.items.push(...message.items);
			conv.state = message.state;
			this.conversations.set(message.id, conv);
		} else if (typeof message.event === "string") {
			// Any other event: kept by name, for features that send their own.
			this.events[message.event] = message;
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
	await client.call("submit", { id: b, text: "/slow first" });
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
	await client.call("submit", { id: c, text: "/slow survive this", requestId: "crash-1" });
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
	const beforeCrash = await client.until("approval before crash", () => client.inbox.find((i) => i.conversationId === f));
	engine.kill("SIGKILL");
	await new Promise((resolve) => engine.once("exit", resolve));
	engine = startEngine();
	client = await Client.attach();
	await client.call("conversation.open", { id: f });
	ask = await client.until("approval asked again after restart", () => client.inbox.find((i) => i.conversationId === f));
	await client.call("inbox.decide", { id: ask.id, decision: "always" });
	// This failed now and then in CI with the third result not being the command's (issue #13), and did not fail locally.
	// So wait for the approved call's own result rather than for a count, and show the transcript when anything is off.
	const transcript = () =>
		JSON.stringify(
			client.conversations.get(f)!.items.map(({ id, kind, callId, isError, stop, text }) => ({ id, kind, callId, isError, stop, text: text.slice(0, 200) })),
			null,
			1,
		);
	await client
		.until("the approved call's result, and idle", () => !client.conversations.get(f)!.state.busy && toolResults(f).some((r) => r.callId === ask.callId))
		.catch((error: Error) => assert.fail(`${error.message}; the transcript:\n${transcript()}`));
	const ran = toolResults(f).filter((r) => r.callId === ask.callId);
	assert.equal(ask.callId, beforeCrash.callId, `the same call is asked about again; the transcript:\n${transcript()}`);
	assert.equal(ran.length, 1, `the call has one result; the transcript:\n${transcript()}`);
	assert.ok(!ran[0]!.isError && ran[0]!.text.includes("after-crash"), `the command ran; the transcript:\n${transcript()}`);
	assert.equal(toolResults(f).length, 3, `no other tool result was added; the transcript:\n${transcript()}`);
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

	// ---- Attachments: pictures and files sent with a message
	{
		const TINY_PNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==";
		const picture = { kind: "image", name: "shot.png", mimeType: "image/png", data: TINY_PNG };
		const notes = { kind: "text", name: "notes.md", text: "# Notes\nThe launch code is 7421.\n" };
		const answerOf = (id: number) => client.conversations.get(id)!.items.findLast((i) => i.kind === "assistant")!.text;
		const titleOf = (id: number) => client.library.find((x) => x.id === id)?.title;

		// A picture and a text file reach the model; the transcript shows what was typed and names what came with it.
		const { id: att } = await client.call("conversation.create", { agentId: "atlas" });
		await client.call("conversation.open", { id: att });
		await client.call("submit", { id: att, text: "what is in these?", attachments: [notes, picture] });
		const sentWith = (await client.idle(att)).items[0] as any;
		assert.equal(sentWith.kind, "user");
		assert.equal(sentWith.text, "what is in these?", "the message's text is what was typed, without the file's contents");
		assert.deepEqual(sentWith.attachments, [
			{ name: "notes.md", kind: "text", size: Buffer.byteLength(notes.text) },
			{ name: "shot.png", kind: "image", size: Buffer.from(TINY_PNG, "base64").length },
		]);
		assert.equal(sentWith.images, 1);
		assert.match(answerOf(att), /^You said: "what is in these\?"\. With it came 1 picture and 1 attached file\./, "both reached the model, apart from the typed text");
		assert.deepEqual(await client.call("conversation.image", { id: att, entryId: sentWith.id, index: 0 }), { data: TINY_PNG, mimeType: "image/png" });
		await assert.rejects(client.call("conversation.image", { id: att, entryId: sentWith.id, index: 1 }), /no such picture/);
		assert.equal(titleOf(att), "what is in these?");
		assert.ok((await client.call("search", { query: "launch code is 7421" })).results.some((r: any) => r.conversationId === att), "an attached text can be searched for");
		const attachedLine = `*Attached: notes.md (text, ${Buffer.byteLength(notes.text)} bytes); shot.png (picture, ${Buffer.from(TINY_PNG, "base64").length} bytes)*`;
		assert.ok(((await client.call("conversation.export", { id: att, format: "markdown" })).text as string).includes(`## You\n\nwhat is in these?\n\n${attachedLine}`), "an export names the attachments");
		assert.equal(JSON.parse((await client.call("conversation.export", { id: att, format: "json" })).text).items[0].attachments.length, 2);

		// Attachments can be the whole message; the conversation is then named after the first of them.
		const { id: only } = await client.call("conversation.create", { agentId: "atlas" });
		await client.call("conversation.open", { id: only });
		await client.call("submit", { id: only, text: " \n", attachments: [{ ...picture, name: "Screenshot 2026-11-12.png" }, picture] });
		const alone = (await client.idle(only)).items[0] as any;
		assert.ok(alone.text === "" && alone.images === 2 && alone.attachments.length === 2);
		assert.match(answerOf(only), /^You said: ""\. With it came 2 pictures\./);
		assert.deepEqual(await client.call("conversation.image", { id: only, entryId: alone.id, index: 1 }), { data: TINY_PNG, mimeType: "image/png" });
		assert.equal(titleOf(only), "Screenshot 2026-11-12.png");

		// Sent while the agent is busy, they wait in the queue with the message and can be withdrawn.
		await client.call("submit", { id: only, text: "/slow keep going" });
		await client.until("busy with the second message", () => client.conversations.get(only)!.state.busy);
		const plain = client.conversations.get(only)!.items.find((i) => i.kind === "user" && i.text === "/slow keep going") as any;
		assert.deepEqual([plain.attachments, plain.images], [[], 0], "a message without attachments says so");
		await client.call("submit", { id: only, attachments: [notes], mode: "queue" });
		const waiting = (await client.until("queued attachments", () => client.conversations.get(only)!.state.queued[0])) as any;
		assert.ok(waiting.text === "" && waiting.attachments.length === 1 && waiting.attachments[0].name === "notes.md");
		await client.call("withdraw", { submissionId: waiting.id });
		await client.until("queue emptied again", () => client.conversations.get(only)!.state.queued.length === 0);
		await client.call("abort", { id: only });
		await client.until("stopped again", () => !client.conversations.get(only)!.state.busy);

		// The limits, each refused with what is wrong and what to do; nothing of a refused message is kept.
		const refusedWith = (attachments: unknown, text: string | null = "x") => client.call("submit", { id: att, ...(text === null ? {} : { text }), attachments });
		const sizeBefore = client.conversations.get(att)!.items.length;
		await assert.rejects(refusedWith(Array.from({ length: 11 }, () => picture)), /at most 10 attachments; this one has 11/);
		const tooBig = Buffer.concat([Buffer.from(TINY_PNG, "base64"), Buffer.alloc(5 * 1024 * 1024)]).toString("base64");
		await assert.rejects(refusedWith([{ ...picture, data: tooBig }]), /“shot\.png” is just over 5 MB; a picture can be at most 5 MB\. Scale it down/);
		const wayTooBig = Buffer.concat([Buffer.from(TINY_PNG, "base64"), Buffer.alloc(7 * 1024 * 1024)]).toString("base64");
		await assert.rejects(refusedWith([{ ...picture, data: wayTooBig }]), /“shot\.png” is 7\.0 MB; a picture can be at most 5 MB/);
		await assert.rejects(refusedWith([{ ...notes, text: "x".repeat(400_001) }]), /“notes\.md” has 400,001 characters; one attached text can have at most 400,000/);
		await assert.rejects(refusedWith(Array.from({ length: 4 }, () => ({ ...notes, text: "x".repeat(400_000) }))), /add up to 1,600,000 characters; a message can carry at most 1,500,000/);
		await assert.rejects(refusedWith([{ ...picture, mimeType: "image/tiff" }]), /image\/tiff, which cannot be sent as a picture\. Use PNG, JPEG, GIF or WebP/);
		await assert.rejects(refusedWith([{ ...picture, mimeType: "constructor" }]), /constructor, which cannot be sent as a picture/);
		await assert.rejects(refusedWith([{ ...picture, mimeType: "image/jpeg" }]), /is not a JPEG picture/);
		await assert.rejects(refusedWith([{ ...picture, data: "not base64!" }]), /did not arrive whole/);
		await assert.rejects(refusedWith([{ ...notes, text: " \n" }]), /has no text in it/);
		await assert.rejects(refusedWith([{ kind: "video", name: "clip.mov" }]), /Unknown kind of attachment/);
		await assert.rejects(refusedWith([], "  "), /The message is empty/);
		await assert.rejects(refusedWith([], null), /Missing text/);
		await sleep(300);
		assert.equal(client.conversations.get(att)!.items.length, sizeBefore, "a refused message leaves nothing behind");

		// A model that cannot see pictures is not sent any: the message is refused while it can still be changed.
		assert.deepEqual(["demo-1", "demo-text"].map((id) => (client.models.find((m) => m.provider === "demo" && m.id === id) as any)?.vision), [true, false]);
		const { id: textOnly } = await client.call("conversation.create", { agentId: "atlas", model: { provider: "demo", modelId: "demo-text" } });
		await client.call("conversation.open", { id: textOnly });
		await assert.rejects(client.call("submit", { id: textOnly, text: "look at this", attachments: [notes, picture] }), /^Error: Demo model \(text only\) cannot see pictures\. Choose a model that can, or remove them\.$/);
		assert.equal(titleOf(textOnly), "", "the refused message did not name the conversation");
		await client.call("submit", { id: textOnly, text: "read this", attachments: [notes] });
		await client.idle(textOnly);
		assert.match(answerOf(textOnly), /With it came 1 attached file\./, "an attached text is fine for it");

		// A model on the person's own endpoint sees pictures once it is marked as able to. A stand-in server records
		// what it is sent.
		let lastBody = "";
		const eyes = createServer((request, response) => {
			let body = "";
			request.setEncoding("utf8").on("data", (chunk: string) => (body += chunk)).on("end", () => {
				lastBody = body;
				response.writeHead(200, { "content-type": "text/event-stream" });
				const choice = (delta: object, finish: string | null) => ({ id: "c1", object: "chat.completion.chunk", created: 1, model: "sees", choices: [{ index: 0, delta, finish_reason: finish }] });
				response.write(`data: ${JSON.stringify(choice({ role: "assistant", content: "I see it." }, null))}\n\n`);
				response.write(`data: ${JSON.stringify(choice({}, "stop"))}\n\n`);
				response.end("data: [DONE]\n\n");
			});
		});
		await new Promise<void>((resolve) => eyes.listen(0, "127.0.0.1", resolve));
		try {
			const eyesUrl = `http://127.0.0.1:${(eyes.address() as { port: number }).port}/v1`;
			const { id: visionBox } = await client.call("endpoints.save", { name: "Vision Box", baseUrl: eyesUrl, api: "openai-completions", models: [{ id: "sees", vision: true }, { id: "reads" }] });
			await client.until("vision endpoint offered", () => client.models.some((m) => m.provider === visionBox));
			assert.deepEqual(["sees", "reads"].map((id) => (client.models.find((m) => m.provider === visionBox && m.id === id) as any)?.vision), [true, false]);
			const { id: reads } = await client.call("conversation.create", { agentId: "atlas", model: { provider: visionBox, modelId: "reads" } });
			await assert.rejects(client.call("submit", { id: reads, text: "look", attachments: [picture] }), /reads cannot see pictures/);
			const { id: sees } = await client.call("conversation.create", { agentId: "atlas", model: { provider: visionBox, modelId: "sees" } });
			await client.call("conversation.open", { id: sees });
			await client.call("submit", { id: sees, text: "look", attachments: [notes, picture] });
			assert.equal((await client.idle(sees)).state.failure, null);
			assert.equal(answerOf(sees), "I see it.");
			const sentToServer = JSON.parse(lastBody).messages.findLast((message: any) => message.role === "user").content as any[];
			assert.ok(Array.isArray(sentToServer), "the message goes out as parts");
			assert.ok(sentToServer.some((part) => part.type === "image_url" && String(part.image_url?.url).endsWith(TINY_PNG)), "the picture is sent to the endpoint");
			assert.ok(sentToServer.some((part) => part.type === "text" && String(part.text).startsWith("Attached file: notes.md\n\n# Notes")), "and the attached text, under a line naming it");
			await client.call("endpoints.remove", { id: visionBox });
			await client.until("vision endpoint gone", () => !client.providers.some((p) => p.id === visionBox));
		} finally {
			eyes.close();
		}
		step("attachments: pictures and files reach the model and show in the transcript; limits and text-only models refuse plainly; an endpoint model marked as seeing pictures gets them");
	}

	// ---- Pictures read with `read`: one larger than the model takes is shrunk to fit, one within it is left as it is
	{
		/** A PNG of one colour, written here so no picture is kept in the repository. */
		const png = (width: number, height: number) => {
			const chunk = (type: string, data: Buffer) => {
				const body = Buffer.concat([Buffer.from(type, "latin1"), data]);
				const length = Buffer.alloc(4);
				length.writeUInt32BE(data.length);
				const crc = Buffer.alloc(4);
				crc.writeUInt32BE(crc32(body));
				return Buffer.concat([length, body, crc]);
			};
			const header = Buffer.alloc(13);
			header.writeUInt32BE(width, 0);
			header.writeUInt32BE(height, 4);
			header.set([8, 2, 0, 0, 0], 8); // 8-bit RGB
			const row = Buffer.alloc(1 + width * 3, 0x60);
			row[0] = 0; // no filter
			const pixels = deflateSync(Buffer.concat(Array.from({ length: height }, () => row)));
			return Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), chunk("IHDR", header), chunk("IDAT", pixels), chunk("IEND", Buffer.alloc(0))]);
		};
		const sizeOf = (picture: Buffer) => ({ width: picture.readUInt32BE(16), height: picture.readUInt32BE(20) });
		const wide = png(3000, 1200);
		const small = png(40, 30);
		writeFileSync(join(workdir, "wide.png"), wide);
		writeFileSync(join(workdir, "small.png"), small);
		const { id: pics } = await client.call("conversation.create", { agentId: "forge" });
		await client.call("conversation.open", { id: pics });
		await client.call("conversation.configure", { id: pics, cwd: workdir });
		const readPicture = async (name: string, results: number) => {
			await client.call("submit", { id: pics, text: `/read ${name}` });
			await settled(pics, results);
			const result = toolResults(pics)[results - 1]! as any;
			assert.ok(!result.isError && result.images === 1, `${name} is read as a picture: ${result.text}`);
			return { result, image: await client.call("conversation.image", { id: pics, entryId: result.id, index: 0 }) };
		};

		const shrunk = await readPicture("wide.png", 1);
		assert.equal(shrunk.image.mimeType, "image/png");
		const to = sizeOf(Buffer.from(shrunk.image.data, "base64"));
		assert.deepEqual(to, { width: 2000, height: 800 }, "shrunk to the model's 2000 px, keeping its shape");
		assert.ok(shrunk.image.data.length <= 4.5 * 1024 * 1024);
		assert.match(shrunk.result.text, /Resized from 3000x1200 to 2000x800\. Multiply coordinates by 1\.50/, "the model is told it was resized");

		const same = await readPicture("small.png", 2);
		assert.deepEqual(same.image, { data: small.toString("base64"), mimeType: "image/png" }, "a picture within the limits comes back as it is");
		assert.doesNotMatch(same.result.text, /Resized|Converted/);
		step("read: a picture wider than the model takes is shrunk to fit and the model is told; a small one is unchanged");
	}

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

	// An ability switched on in the agent's settings reaches a conversation that already exists, at its next message.
	const { id: late } = await client.call("conversation.create", { agentId: custom });
	await client.call("conversation.open", { id: late });
	await client.call("submit", { id: late, text: "hello" });
	await client.idle(late);
	await client.call("agents.save", { agent: { id: custom, name: "Quill", delegates: ["forge"] } });
	await client.until("hand-off switched on", () => client.agents.find((x) => x.id === custom)?.delegates.includes("forge"));
	await client.call("submit", { id: late, text: "/delegate Forge: say hello" });
	await settled(late, 1);
	assert.equal(toolResults(late)[0]!.isError, false, "the conversation was given the hand-off tool");
	assert.ok(client.library.some((c) => c.parent === late), "and the sub-chat was opened");
	// And one switched off is taken away again.
	await client.call("agents.save", { agent: { id: custom, name: "Quill", delegates: [] } });
	await client.until("hand-off switched off", () => client.agents.find((x) => x.id === custom)?.delegates.length === 0);
	await client.call("submit", { id: late, text: "/delegate Forge: say hello again" });
	await settled(late, 2);
	assert.equal(toolResults(late)[1]!.isError, true, "without the setting the hand-off is refused");
	step("changing what an agent may do reaches its existing conversations");

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
	writeFileSync(join(refs, "guides", "resume.rtf"), "{\\rtf1\\ansi Ten years of shipping software.\\par Led a team of six.}");
	assert.match((await openRef("resume.rtf", 7)).text, /Ten years of shipping software\.\s+Led a team of six\./, "a Word-style document is read as its text");
	step("reference files: read and listed on demand with tools off, re-read after an edit, nothing outside them");

	// ---- Computer use: the engine decides and asks; a fake app stands in for the screen
	const NOTES = "com.example.notes";
	const MAIL = "com.example.mail";
	const PNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==";
	// macOS finds an app by its bundle id without regard to case, and so do the lists.
	for (const terminal of ["com.apple.Terminal", "com.apple.terminal", "COM.APPLE.TERMINAL"]) {
		await assert.rejects(client.call("agents.save", { agent: { id: custom, name: "Quill", computer: { enabled: true, apps: [terminal] } } }), /cannot be given/, `${terminal} is refused`);
	}
	const policy = await import("../src/computer.ts");
	assert.ok(["com.apple.terminal", "Com.Apple.Terminal", "DEV.PI2.APP", "com.1PASSWORD.1password.helper"].every(policy.isNever), "never means never, in any case");
	assert.ok(["com.apple.safari", "COM.GOOGLE.CHROME", "Dev.Pi2.App.Test"].every(policy.isViewOnly), "look-only means look-only, in any case");
	assert.ok(!policy.isNever("dev.pi2.apples") && !policy.isViewOnly("com.apple.safariX"), "only a whole bundle id, or one under it, matches");
	assert.deepEqual(policy.validateComputer({ apps: [NOTES, "COM.EXAMPLE.NOTES", MAIL, "com.example.Mail"] }).apps, [NOTES, MAIL], "two spellings of one app are kept once");
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
	const viewOnlyCase = await use({ action: "click", app: "COM.APPLE.SAFARI", x: 10, y: 10 });
	assert.ok(viewOnlyCase.isError && /only be looked at/.test(viewOnlyCase.text), "a look-only app spelled another way is still look-only");
	const neverCase = await use({ action: "screenshot", app: "com.apple.terminal" });
	assert.ok(neverCase.isError && client.computerRequests.every((r) => r.app?.toLowerCase() !== "com.apple.terminal"), "a never app spelled another way does not reach the app");
	await use({ action: "click", app: "COM.Example.Notes", element: 1 });
	assert.ok(client.inbox.length === 0 && sentToApp("click", NOTES).length === 3, "another spelling of a given app is that app: same approval, sent as it was given");
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

	// pi² itself is never usable; a copy of it under another bundle id is look-only, so an agent can check a change to the app.
	const PI2 = "dev.pi2.app";
	const COPY = "dev.pi2.app.test";
	for (const spelling of [PI2, "Dev.Pi2.App", "DEV.PI2.APP"]) {
		await assert.rejects(client.call("agents.save", { agent: { id: custom, name: "Quill", computer: { enabled: true, apps: [NOTES, spelling] } } }), /cannot be given.*pi² itself/, `${spelling} is refused`);
	}
	await client.call("agents.save", { agent: { id: custom, name: "Quill", computer: { enabled: true, apps: [NOTES, COPY] } } });
	await client.until("the copy of pi² added", () => (client.agents.find((x) => x.id === custom) as any)?.computer?.apps.includes(COPY));
	const itself = await use({ action: "screenshot", app: PI2 });
	assert.ok(itself.isError && sentToApp("screenshot", PI2).length === 0, "pi² itself cannot even be looked at");
	const itselfCase = await use({ action: "screenshot", app: "DEV.PI2.APP" });
	assert.ok(itselfCase.isError && client.computerRequests.every((r) => r.app?.toLowerCase() !== PI2), "nor can pi² itself spelled another way");
	await use({ action: "open_app", app: COPY }, false);
	const opening = await client.until("approval to open the copy", () => client.inbox.find((i) => i.tool === "computer"));
	await client.call("inbox.decide", { id: opening.id, decision: "once" });
	await settled(k, computerCalls);
	assert.ok(!toolResults(k).at(-1)!.isError && sentToApp("open_app", COPY).length === 1, "a copy of pi² can be opened");
	const copyShot = await use({ action: "screenshot", app: COPY });
	assert.ok(!copyShot.isError && sentToApp("screenshot", COPY).length === 1, "a copy of pi² can be looked at");
	for (const acting of [{ action: "click", element: 1 }, { action: "click", x: 10, y: 10 }, { action: "type", text: "hi" }, { action: "key", text: "return" }, { action: "menu", path: "File > New" }, { action: "scroll", dy: 1 }]) {
		const refused = await use({ ...acting, app: COPY });
		assert.ok(refused.isError && /only be looked at/.test(refused.text), `a copy of pi² refuses ${JSON.stringify(acting)}`);
	}
	assert.equal(client.inbox.length, 0, "acting on a copy of pi² is refused without asking");
	assert.ok(["click", "type", "key", "menu", "scroll"].every((action) => sentToApp(action, COPY).length === 0), "nothing that acts reaches a copy of pi²");
	// A copy given under another spelling is still a copy: looked at, never acted on.
	const COPY_CASE = "Dev.PI2.App.Test";
	await client.call("agents.save", { agent: { id: custom, name: "Quill", computer: { enabled: true, apps: [NOTES, COPY_CASE] } } });
	await client.until("the copy of pi² added under another spelling", () => (client.agents.find((x) => x.id === custom) as any)?.computer?.apps.includes(COPY_CASE));
	assert.ok(!(await use({ action: "screenshot", app: COPY_CASE })).isError && sentToApp("screenshot", COPY_CASE).length === 1, "a copy of pi² spelled another way can be looked at");
	const copyCase = await use({ action: "click", app: "dev.pi2.app.TEST", element: 1 });
	assert.ok(copyCase.isError && /only be looked at/.test(copyCase.text) && client.inbox.length === 0, "a copy of pi² spelled another way refuses a click");
	assert.ok(client.computerRequests.every((r) => r.action !== "click" || r.app?.toLowerCase() !== COPY), "no click reaches a copy of pi² in any spelling");
	await client.call("agents.save", { agent: { id: custom, name: "Quill", computer: { enabled: false, apps: [NOTES] } } });
	await client.until("computer use off", () => (client.agents.find((x) => x.id === custom) as any)?.computer?.enabled === false);
	assert.equal((await use({ action: "list_apps" })).isError, true, "switched off, the tool is taken away from the conversation");
	step("computer use: asks before acting and says what, app by app; refuses what is not allowed; trims old screenshots; survives the app closing; a copy of pi² is look-only");

	// ---- The browser: the engine decides what may be opened and asks before acting; a fake app stands in for the pages
	const { checkAddress } = await import("../src/browser.ts");
	const notOpened = [
		"file:///etc/passwd", "javascript:alert(1)", "data:text/html,<p>hi", "about:blank", "ftp://example.com/x", "https://user:pw@example.com/",
		"http://localhost:3000/", "localhost:3000", "http://app.localhost/", "http://127.0.0.1/", "http://127.1/", "http://2130706433/", "http://0x7f.0.0.1/",
		"http://10.1.2.3/", "http://172.16.0.1/", "http://172.31.255.255/", "http://192.168.1.1/admin", "http://169.254.169.254/latest/meta-data/", "http://0.0.0.0:8000/",
		"http://100.64.0.1/", "http://[::1]:8080/", "http://[fd12:3456::1]/", "http://[fe80::1]/", "http://[::ffff:192.168.0.1]/", "http://printer.local/", "http://router/",
	];
	for (const address of notOpened) assert.ok("refused" in checkAddress(address), `${address} must not be opened`);
	for (const address of ["https://example.com/jobs?q=1", "http://172.32.0.1/", "http://11.0.0.1/", "https://[2606:4700::1111]/", "https://local.example.com/"]) {
		assert.ok("url" in checkAddress(address), `${address} is a public address`);
	}
	assert.deepEqual(checkAddress("example.com:8080/a b"), { url: "https://example.com:8080/a%20b", host: "example.com" }, "an address without its scheme means https");

	assert.equal((client.agents.find((x) => x.id === custom) as any).browser?.enabled, false, "the browser is off unless it is switched on");
	const { id: w } = await client.call("conversation.create", { agentId: custom });
	await client.call("conversation.open", { id: w });
	let browserCalls = 0;
	const browse = async (args: Record<string, unknown>, wait = true) => {
		await client.call("submit", { id: w, text: `/browser ${JSON.stringify(args)}` });
		browserCalls++;
		if (!wait) return undefined as any;
		await settled(w, browserCalls);
		return toolResults(w)[browserCalls - 1]! as any;
	};
	const toPage = (action: string, of?: string) => client.browserRequests.filter((r) => r.action === action && (of === undefined || r.of === of));
	const browserAsk = () => client.inbox.find((i) => i.tool === "browser") as (InboxItem & { site?: string }) | undefined;
	assert.equal((await browse({ action: "open", url: "https://example.com/" })).isError, true, "off by default: the conversation has no browser tool");

	await client.call("agents.save", { agent: { id: custom, name: "Quill", browser: { enabled: true } } });
	await client.until("browser switched on", () => (client.agents.find((x) => x.id === custom) as any)?.browser?.enabled === true);
	assert.equal((client.agents.find((x) => x.id === custom) as any).browser.ask, true, "asking first is the default");
	const noBrowser = await browse({ action: "open", url: "https://example.com/" });
	assert.ok(noBrowser.isError && /not open/.test(noBrowser.text), "with no app connected there is no browser to use");

	// The stand-in page: element 1 is a plain link, 3 a password field, 9 does not exist, everything else a button or a field.
	let site = "jobs.example.com";
	client.browserReply = (request) => {
		if (request.action === "describe") {
			if (request.element === 9) return { ok: false, text: "There is no element 9 on the page." };
			if (request.of === "click" && request.element === 1) return { ok: true, text: `Follow the link “Careers” to https://${site}/careers`, host: site, navigates: true };
			if (request.of === "click") return { ok: true, text: `Click “Submit application” on ${site}`, host: site };
			if (request.of === "type" && request.element === 3) return { ok: false, text: "That is a password field. pi² does not type passwords." };
			if (request.of === "type") return { ok: true, text: `Type “${request.text}” into the “Email” field on ${site}`, host: site };
			return { ok: true, text: `Upload ${request.path} to “Résumé” on ${site}`, host: site };
		}
		if (request.action === "screenshot") return { ok: true, text: "pic", summary: `Took a picture of ${site}`, image: { data: PNG, mimeType: "image/png" } };
		return { ok: true, text: `page:${request.action}`, summary: `${request.action} on ${site}` };
	};
	await client.call("browser.register");

	for (const url of ["file:///etc/passwd", "http://192.168.1.1/admin"]) {
		const refusedAddress = await browse({ action: "open", url });
		assert.ok(refusedAddress.isError && /http and https|off limits/.test(refusedAddress.text), `${url} is refused: ${refusedAddress.text}`);
	}
	assert.equal(toPage("open").length, 0, "a refused address never reaches the app");

	const opened = await browse({ action: "open", url: "example.com/jobs" });
	assert.ok(!opened.isError && opened.text === "page:open" && opened.details?.summary === "open on jobs.example.com");
	const openRequest = toPage("open").at(-1);
	assert.ok(openRequest.url === "https://example.com/jobs" && openRequest.conversationId === w && openRequest.agentName === "Quill");
	await browse({ action: "search", query: "swift jobs & more" });
	assert.equal(toPage("search").at(-1).url, "https://html.duckduckgo.com/html/?q=swift%20jobs%20%26%20more", "a search is the results page of a search engine");
	await browse({ action: "read", offset: 8000 });
	assert.equal(toPage("read").at(-1).offset, 8000);
	assert.ok(client.inbox.length === 0 && toPage("describe").length === 0, "opening, searching and reading are not asked about");

	// A plain link is followed without asking; the app is told what it described, and does only that.
	assert.equal((await browse({ action: "click", element: 1 })).isError, false);
	assert.equal(client.inbox.length, 0, "following a plain link is not asked about");
	assert.equal(toPage("click").at(-1).expect, "Follow the link “Careers” to https://jobs.example.com/careers");

	// A button waits, with the app's words for it, and "always" covers that site.
	await browse({ action: "click", element: 2 }, false);
	const press = await client.until("approval for the button", browserAsk);
	assert.equal(press.question, "Click “Submit application” on jobs.example.com", "the approval says what will be clicked, and where");
	assert.equal(press.site, "jobs.example.com");
	assert.equal(toPage("click").length, 1, "nothing is clicked while the question is open");
	await client.call("inbox.decide", { id: press.id, decision: "always" });
	await settled(w, browserCalls);
	assert.ok(!toolResults(w).at(-1)!.isError && toPage("click").length === 2 && toPage("click").at(-1).expect === press.question);
	await browse({ action: "type", element: 4, text: "quill@example.com", submit: true });
	assert.ok(client.inbox.length === 0 && toPage("type").length === 1 && toPage("type").at(-1).submit === true, "“always” covers that site for the rest of the conversation");

	// Another site is asked about separately, and a refusal is final.
	site = "other.example.org";
	await browse({ action: "click", element: 2 }, false);
	const elsewhere = await client.until("approval on the other site", browserAsk);
	assert.match(elsewhere.question!, /on other\.example\.org$/);
	await client.call("inbox.decide", { id: elsewhere.id, decision: "deny" });
	await settled(w, browserCalls);
	assert.ok(toolResults(w).at(-1)!.isError && /declined/.test(toolResults(w).at(-1)!.text) && toPage("click").length === 2, "a denied action never reaches the app");

	// What the app says cannot be done is not asked about and not attempted.
	const secret = await browse({ action: "type", element: 3, text: "hunter2" });
	assert.ok(secret.isError && /password field/.test(secret.text) && toPage("type").length === 1, "a password field is never typed into");
	const missing = await browse({ action: "click", element: 9 });
	assert.ok(missing.isError && /no element 9/.test(missing.text) && toPage("click").length === 2);
	assert.equal((await browse({ action: "select", element: 5 })).isError, true, "a call with something missing is refused");
	assert.equal(client.inbox.length, 0, "a call that cannot run is refused without bothering the person");

	// Uploads: only a reference file, or a file in the conversation's folder once the conversation may read files there.
	writeFileSync(join(workdir, "cv.txt"), "Quill's CV");
	const outside = await browse({ action: "upload", element: 6, path: join(home, "secret.txt") });
	assert.ok(outside.isError && /cannot be uploaded/.test(outside.text), outside.text);
	assert.equal((await browse({ action: "upload", element: 6, path: join(workdir, "cv.txt") })).isError, true, "with tools off the conversation's folder is not open to it either");
	assert.ok(client.inbox.length === 0 && toPage("describe", "upload").length === 0 && toPage("upload").length === 0, "a file it may not use is refused before anyone is asked");
	await browse({ action: "upload", element: 6, path: join(refs, "brief.md") }, false);
	const handIn = await client.until("approval for the upload", browserAsk);
	assert.ok(handIn.question!.includes(realpathSync(join(refs, "brief.md"))), "the approval names the file");
	await client.call("inbox.decide", { id: handIn.id, decision: "once" });
	await settled(w, browserCalls);
	assert.equal(toPage("upload").at(-1).path, realpathSync(join(refs, "brief.md")), "a reference file may be uploaded");
	await client.call("conversation.configure", { id: w, access: "read", cwd: workdir });
	await client.until("read access", () => client.conversations.get(w)!.state.agent.access === "read");
	await browse({ action: "upload", element: 6, path: "cv.txt" }, false);
	await client.call("inbox.decide", { id: (await client.until("approval for the second upload", browserAsk)).id, decision: "once" });
	await settled(w, browserCalls);
	assert.equal(toPage("upload").at(-1).path, join(workdir, "cv.txt"), "and so may a file in the folder the conversation reads");
	assert.equal((await browse({ action: "upload", element: 6, path: "../../etc/hosts" })).isError, true, "but nothing reached by climbing out of it");

	// Screenshots reach the model as pictures, and only the newest are sent.
	const lastSaid = () => client.conversations.get(w)!.items.findLast((i) => i.kind === "assistant")!.text;
	const picture = await browse({ action: "screenshot" });
	assert.ok(picture.images === 1 && picture.details?.summary === "Took a picture of other.example.org");
	assert.match(lastSaid(), /I can see 1 picture\./);
	for (let i = 0; i < 2; i++) await browse({ action: "screenshot" });
	assert.match(lastSaid(), /I can see 2 pictures\./, "old pictures of pages are left out of what the model is sent");
	await client.call("conversation.configure", { id: w, model: { provider: "demo", modelId: "demo-text" } });
	await client.until("text-only model", () => client.conversations.get(w)!.state.agent.model?.modelId === "demo-text");
	const asText = await browse({ action: "screenshot" });
	assert.ok(toPage("screenshot").length === 3 && toPage("read").length === 2 && asText.images === 0 && /cannot see pictures/.test(asText.text), "a model that cannot see is given the page as text");
	await client.call("conversation.configure", { id: w, model: { provider: "demo", modelId: "demo-1" } });
	await client.until("back to the demo model", () => client.conversations.get(w)!.state.agent.model?.modelId === "demo-1");

	// The app going away in the middle of an action ends the call instead of leaving it hanging.
	const pages = await Client.attach();
	await pages.call("browser.register");
	await browse({ action: "open", url: "https://example.com/slow" }, false);
	await pages.until("the second app is asked", () => pages.browserRequests.some((r) => r.action === "open"));
	pages.socket.destroy();
	await settled(w, browserCalls);
	assert.ok(toolResults(w).at(-1)!.isError && /closed before/.test(toolResults(w).at(-1)!.text));
	assert.equal((await browse({ action: "back" })).text, "page:back", "the app that was there before takes over again");

	// With asking switched off nothing waits, and the app is not asked to describe anything.
	await client.call("agents.save", { agent: { id: custom, name: "Quill", browser: { enabled: true, ask: false } } });
	await client.until("asking off", () => (client.agents.find((x) => x.id === custom) as any)?.browser?.ask === false);
	const described = toPage("describe").length;
	assert.equal((await browse({ action: "click", element: 2 })).isError, false);
	assert.ok(client.inbox.length === 0 && toPage("describe").length === described && toPage("click").at(-1).expect === undefined);
	await client.call("agents.save", { agent: { id: custom, name: "Quill", browser: { enabled: false } } });
	await client.until("browser off", () => (client.agents.find((x) => x.id === custom) as any)?.browser?.enabled === false);
	assert.equal((await browse({ action: "read" })).isError, true, "switched off, the tool is taken away from the conversation");
	step("browser: public http(s) pages only; looks and follows links without asking; asks before buttons, typing and uploads, site by site; uploads only what it may read; survives the app closing");

	// ---- Features in files of their own (engine/src/features.ts). Each adds its test step inside its own braces
	// below, and nowhere else in this file.
	{
		// plan (engine/src/plan.ts)
		const planOf = (id: number) => (client.conversations.get(id)?.state as any)?.plan as { items: { content: string; status: string }[] } | null | undefined;
		const results = (id: number) => client.conversations.get(id)!.items.filter((i) => i.kind === "tool");
		const update = async (id: number, items: unknown) => {
			const before = results(id).length;
			await client.call("submit", { id, text: `/tool update_plan ${JSON.stringify({ items })}` });
			await client.until("update_plan answered", () => {
				const v = client.conversations.get(id)!;
				return !v.state.busy && results(id).length === before + 1;
			});
			return results(id).at(-1)!;
		};
		const item = (content: string, status: string) => ({ content, status });

		const { id: p } = await client.call("conversation.create");
		await client.call("conversation.open", { id: p });
		await client.until("plan conversation", () => client.conversations.get(p));
		assert.equal(planOf(p) ?? null, null, "no list at first");

		let answer = await update(p, [item("Read the code", "completed"), item("Write the change", "in_progress"), item("Run the tests", "pending")]);
		assert.equal(answer.isError, false, answer.text);
		assert.equal(answer.text, "1 of 3 done");
		await client.until("list arrives in the state", () => planOf(p)?.items.length === 3);
		assert.deepEqual(planOf(p)!.items.map((x) => x.status), ["completed", "in_progress", "pending"]);

		answer = await update(p, [item("Read the code", "completed"), item("Write the change", "completed"), item("Run the tests", "in_progress"), item("Tidy up", "pending")]);
		assert.equal(answer.text, "2 of 4 done");
		await client.until("list replaced", () => planOf(p)?.items.length === 4);
		assert.equal(planOf(p)!.items[2]!.content, "Run the tests");

		const refusals: [string, unknown, RegExp][] = [
			["no items", [], /empty/],
			["two in progress", [item("A", "in_progress"), item("B", "in_progress")], /2 items are in_progress/],
			["too many", Array.from({ length: 21 }, (_, n) => item(`Step ${n}`, "pending")), /most allowed is 20/],
			["bad status", [item("A", "done")], /status "done"/],
			["empty text", [item("  ", "pending")], /no text/],
			["too long", [item("x".repeat(200), "pending")], /200 characters/],
		];
		for (const [what, items, message] of refusals) {
			answer = await update(p, items);
			assert.ok(answer.isError && message.test(answer.text), `${what}: ${answer.text}`);
			assert.ok(answer.text.includes("unchanged"));
		}
		assert.deepEqual(planOf(p)!.items.map((x) => x.content), ["Read the code", "Write the change", "Run the tests", "Tidy up"], "refused lists leave the old one in place");

		// A sub-chat has a list of its own.
		const { id: parentChat } = await client.call("conversation.create", { agentId: "atlas" });
		await client.call("conversation.open", { id: parentChat });
		await client.call("submit", { id: parentChat, text: "/delegate Forge: say hi" });
		await client.until("plan delegation finished", () => {
			const v = client.conversations.get(parentChat);
			return v !== undefined && !v.state.busy && v.items.some((i) => i.kind === "tool") ? v : undefined;
		});
		const subChat = results(parentChat)[0]!.details?.conversationId as number;
		assert.equal(typeof subChat, "number", JSON.stringify(results(parentChat)[0]));
		await client.call("conversation.open", { id: subChat });
		await client.until("sub-chat transcript", () => client.conversations.get(subChat));
		answer = await update(parentChat, [item("Parent step", "in_progress")]);
		assert.equal(answer.isError, false, answer.text);
		assert.equal((await update(subChat, [item("Sub-chat step", "pending"), item("Another", "pending")])).isError, false, "the sub-chat is offered the tool too");
		await client.until("both lists", () => planOf(subChat)?.items.length === 2 && planOf(parentChat)?.items.length === 1);
		assert.equal(planOf(parentChat)!.items[0]!.content, "Parent step");
		assert.equal(planOf(p)!.items.length, 4, "other conversations keep their lists");

		// A fork carries the list along, and then has its own.
		const forkedAt = client.conversations.get(p)!.items.filter((i) => i.kind === "assistant").at(-1)!;
		const { id: forked } = await client.call("conversation.fork", { id: p, entryId: forkedAt.id });
		await client.call("conversation.open", { id: forked });
		await client.until("forked list", () => planOf(forked)?.items.length === 4);
		answer = await update(forked, [item("Only in the fork", "pending")]);
		assert.equal(answer.isError, false, answer.text);
		await client.until("fork replaced its list", () => planOf(forked)?.items.length === 1);
		assert.equal(planOf(p)!.items.length, 4, "the original keeps its list");

		// The list survives the engine being killed and started again.
		await sleep(1200);
		engine.kill("SIGKILL");
		await new Promise((resolve) => engine.once("exit", resolve));
		engine = startEngine();
		client = await Client.attach();
		for (const id of [p, subChat]) await client.call("conversation.open", { id });
		await client.until("lists after restart", () => planOf(p)?.items.length === 4 && planOf(subChat)?.items.length === 2);
		assert.equal(planOf(p)!.items[3]!.content, "Tidy up");
		assert.equal(planOf(subChat)!.items[0]!.content, "Sub-chat step");
		step("plan: update_plan stores, replaces and refuses lists; per conversation, sub-chats included; survives kill -9");
	}

	{
		// knowledge (engine/src/knowledge.ts)
		const { symlinkSync, unlinkSync } = await import("node:fs");
		const assistants = (id: number) => client.conversations.get(id)!.items.filter((i) => i.kind === "assistant" && i.stop === "stop").length;
		/** Send a message and wait for the answer to it. */
		const say = async (id: number, text: string): Promise<string> => {
			const before = assistants(id);
			await client.call("submit", { id, text });
			await client.until(`answer to ${text.slice(0, 30)}`, () => !client.conversations.get(id)!.state.busy && assistants(id) > before);
			return client.conversations.get(id)!.items.findLast((i) => i.kind === "assistant")!.text;
		};
		const open = async (agentId: string, cwd?: string) => {
			const { id } = await client.call("conversation.create", { agentId });
			await client.call("conversation.open", { id });
			if (cwd !== undefined) {
				await client.call("conversation.configure", { id, cwd });
				await client.until("folder applied", () => client.conversations.get(id)?.state.agent.cwd === cwd);
			}
			return id as number;
		};
		const info = (id: number) => (client.conversations.get(id)!.state as any).projectInstructions;
		const infoFiles = (id: number) => (client.conversations.get(id)!.state as any).projectInstructionFiles;
		const { id: pilot } = await client.call("agents.save", { agent: { name: "Pilot", access: "none" } });
		await client.until("pilot saved", () => client.agents.some((x) => x.id === pilot));

		// -- Project instructions
		const project = removedAtEnd(realpathSync(mkdtempSync(join(tmpdir(), "pi2-project-"))));
		writeFileSync(join(project, "AGENTS.md"), "Always indent with tabs.\n");
		writeFileSync(join(project, "CLAUDE.md"), "Claude-only notes.\n");
		const p1 = await open(pilot, project);
		let said = await say(p1, "/system");
		assert.ok(/From AGENTS\.md in this folder\. These are the project's instructions/.test(said) && said.includes("Always indent with tabs."), "AGENTS.md reaches the model");
		assert.ok(!said.includes("Claude-only"), "AGENTS.md is preferred to CLAUDE.md");
		assert.equal(info(p1), "AGENTS.md", "the app is told which file is in effect, by name as before");
		assert.deepEqual(infoFiles(p1), [{ folder: project, file: "AGENTS.md" }], "and in the list of files");
		writeFileSync(join(project, "AGENTS.md"), "Always indent with spaces.\n");
		said = await say(p1, "/system");
		assert.ok(said.includes("indent with spaces") && !said.includes("indent with tabs"), "an edit counts from the next message");
		unlinkSync(join(project, "AGENTS.md"));
		said = await say(p1, "/system");
		assert.ok(said.includes("From CLAUDE.md in this folder") && said.includes("Claude-only notes."), "CLAUDE.md is used when there is no AGENTS.md");
		unlinkSync(join(project, "CLAUDE.md"));
		said = await say(p1, "/system");
		assert.ok(!said.includes("project's instructions"), "no file, no section");
		writeFileSync(join(project, "AGENTS.md"), "x".repeat(30_000));
		const { describeProjectInstructions } = await import("../src/knowledge.ts"); // streaming 24,000 characters from the demo model would take minutes
		const cut = describeProjectInstructions(project)!;
		assert.ok(cut.includes("is longer than 24,000 characters") && cut.includes("x".repeat(24_000)) && !cut.includes("x".repeat(24_001)), "a long file is cut, with a note");
		step("project instructions: AGENTS.md, else CLAUDE.md, read fresh at every message, cut when long");

		const outside = removedAtEnd(realpathSync(mkdtempSync(join(tmpdir(), "pi2-outside-"))));
		writeFileSync(join(outside, "secret.md"), "OUTSIDE-SECRET");
		const linked = removedAtEnd(realpathSync(mkdtempSync(join(tmpdir(), "pi2-linked-"))));
		symlinkSync(join(outside, "secret.md"), join(linked, "AGENTS.md"));
		const p2 = await open(pilot, linked);
		said = await say(p2, "/system");
		assert.ok(!said.includes("OUTSIDE-SECRET") && !said.includes("project's instructions"), "a link out of the folder is not followed");
		assert.equal(info(p2), null);
		assert.deepEqual(infoFiles(p2), []);
		const p3 = await open(pilot);
		assert.ok(!(await say(p3, "/system")).includes("project's instructions"), "no chosen folder, no instructions");
		step("project instructions: a link out of the folder is not followed; no folder, none");

		// A repository: every folder from its top down to the conversation's is looked in, and none above the top.
		const { readProjectInstructions } = await import("../src/knowledge.ts");
		const above = removedAtEnd(realpathSync(mkdtempSync(join(tmpdir(), "pi2-above-"))));
		writeFileSync(join(above, "AGENTS.md"), "ABOVE-THE-REPOSITORY");
		const repo = join(above, "repo");
		const sub = join(repo, "engine");
		mkdirSync(join(repo, ".git"), { recursive: true });
		mkdirSync(join(sub, "src"), { recursive: true });
		writeFileSync(join(repo, "AGENTS.md"), "Rules from the top.\n");
		const p4 = await open(pilot, join(sub, "src"));
		said = await say(p4, "/system");
		assert.ok(said.includes(`From AGENTS.md in ${repo}, a folder above this one in its git repository.`) && said.includes("Rules from the top."), "a subfolder of a repository gets the top's file");
		assert.ok(!said.includes("ABOVE-THE-REPOSITORY"), "nothing above the repository's top is read");
		assert.equal(info(p4), "AGENTS.md", "the old field names the nearest file, here one above");
		assert.deepEqual(infoFiles(p4), [{ folder: repo, file: "AGENTS.md" }]);
		writeFileSync(join(sub, "CLAUDE.md"), "Rules for the engine.\n");
		const p5 = await open(pilot, sub);
		said = await say(p5, "/system");
		const top = said.indexOf(`From AGENTS.md in ${repo}, a folder above this one`);
		const near = said.indexOf("From CLAUDE.md in this folder:");
		assert.ok(said.includes("from 2 files") && top >= 0 && near > top && said.indexOf("Rules from the top.") < said.indexOf("Rules for the engine."), "both files are given, the top's first");
		assert.equal(info(p5), "CLAUDE.md", "the old field names the nearest file");
		assert.deepEqual(infoFiles(p5), [{ folder: repo, file: "AGENTS.md" }, { folder: sub, file: "CLAUDE.md" }], "the list has both, the top's first");
		assert.deepEqual(readProjectInstructions(join(sub, "src")).map((x) => x.file), ["AGENTS.md", "CLAUDE.md"], "a folder without a file of its own still gets those above it");
		assert.deepEqual(readProjectInstructions(above).map((x) => [x.folder, x.text]), [[above, "ABOVE-THE-REPOSITORY"]], "a folder outside any repository reads only itself");
		assert.deepEqual(readProjectInstructions(join(above, "repo-less")), [], "a missing folder has none");

		// The cap is shared: a short file is given whole, the long ones split the rest equally, each cut with a note.
		writeFileSync(join(repo, "AGENTS.md"), "t".repeat(30_000));
		writeFileSync(join(sub, "CLAUDE.md"), "s".repeat(4_000));
		assert.deepEqual(readProjectInstructions(sub).map((x) => [x.text.length, x.cut]), [[20_000, true], [4_000, false]], "a short file is given whole and the long one has the rest");
		writeFileSync(join(sub, "CLAUDE.md"), "s".repeat(30_000));
		assert.deepEqual(readProjectInstructions(sub).map((x) => [x.text.length, x.cut]), [[12_000, true], [12_000, true]], "two long files share the cap equally");
		const shared = describeProjectInstructions(sub)!;
		assert.ok(shared.includes(`to keep the project's instructions to 24,000 characters in all; the rest is not shown. Read ${join(repo, "AGENTS.md")} for the rest.`), "the cut top file says where the rest is");
		assert.ok(shared.includes("Read CLAUDE.md in this folder for the rest."), "and so does the cut nearer one");

		// A link out of a folder is still not followed, in a folder above too: the link falls through to that folder's CLAUDE.md.
		writeFileSync(join(sub, "CLAUDE.md"), "Rules for the engine.\n");
		unlinkSync(join(repo, "AGENTS.md"));
		symlinkSync(join(outside, "secret.md"), join(repo, "AGENTS.md"));
		writeFileSync(join(repo, "CLAUDE.md"), "Claude rules from the top.\n");
		symlinkSync(join(repo, "CLAUDE.md"), join(sub, "AGENTS.md")); // inside the repository, but out of the subfolder
		assert.deepEqual(readProjectInstructions(sub).map((x) => [x.folder, x.file, x.text]), [[repo, "CLAUDE.md", "Claude rules from the top."], [sub, "CLAUDE.md", "Rules for the engine."]], "a link out of each folder is not followed");

		// A worktree, where .git is a file, is a repository's top: the checkout it sits in is not looked in.
		const worktree = join(repo, "worktrees", "feature");
		mkdirSync(join(worktree, "engine"), { recursive: true });
		writeFileSync(join(worktree, ".git"), "gitdir: ../../.git/worktrees/feature\n");
		writeFileSync(join(worktree, "AGENTS.md"), "Worktree rules.\n");
		assert.deepEqual(readProjectInstructions(join(worktree, "engine")).map((x) => [x.folder, x.text]), [[worktree, "Worktree rules."]], "a worktree is treated as a repository's top");
		step("project instructions: from a repository's top down to the conversation's folder, top first, the cap shared; a worktree is a top");

		// -- Memory
		said = await say(p3, "/system");
		assert.ok(!said.includes("your own notes") && !/TOOLS:.*(remember|forget)/.test(said), "memory is off by default: no section, no tools");
		await say(p3, '/tool remember {"note":"should not be kept"}');
		assert.ok(toolResults(p3).at(-1)!.isError && !/Noted/.test(toolResults(p3).at(-1)!.text), "and the tool is not offered");
		assert.equal(client.events.memory?.agents?.[pilot], undefined, "nothing is stored");
		await assert.rejects(client.call("memory.setEnabled", { agentId: "nobody", enabled: true }), /Unknown agent/);
		await client.call("memory.setEnabled", { agentId: pilot, enabled: true });
		await client.until("memory on", () => client.events.memory?.agents?.[pilot]?.enabled === true);
		const noted = () => client.events.memory.agents[pilot].notes as { id: string; text: string; createdAt: number; conversation: number | null }[];
		await say(p3, '/tool remember {"note":"  Prefers\\nmetric units  "}');
		assert.match(toolResults(p3).at(-1)!.text, /Noted \(m1\)/);
		await client.until("note broadcast", () => noted().length === 1);
		assert.deepEqual([noted()[0]!.text, noted()[0]!.conversation], ["Prefers metric units", p3], "the note is tidied, and says where it came from");
		await say(p3, '/tool remember {"note":"prefers metric units"}');
		assert.ok(/already have/.test(toolResults(p3).at(-1)!.text) && noted().length === 1, "the same note is not added twice");

		engine.kill("SIGKILL");
		await new Promise((resolve) => engine.once("exit", resolve));
		engine = startEngine();
		client = await Client.attach();
		await client.until("memory sent on connecting", () => client.events.memory?.agents?.[pilot]?.notes?.length === 1);
		const q1 = await open(pilot);
		said = await say(q1, "/system");
		assert.ok(said.includes("your own notes") && said.includes("m1: Prefers metric units"), "after a restart, a new conversation of the agent is given the note");
		assert.ok(/not instructions from the person/.test(said) && /TOOLS:.*remember.*|TOOLS:.*forget/.test(said), "and told what the notes are, with the tools to change them");
		const other = await open("scout");
		assert.ok(!(await say(other, "/system")).includes("metric units"), "another agent does not get it");
		step("memory: off by default, remember stores and broadcasts, survives a restart, belongs to one agent");

		await say(q1, '/tool forget {"id":"m1"}');
		assert.match(toolResults(q1).at(-1)!.text, /Forgot m1/);
		await client.until("note gone", () => noted().length === 0);
		await say(q1, '/tool forget {"id":"m1"}');
		assert.ok(toolResults(q1).at(-1)!.isError && /no note m1/.test(toolResults(q1).at(-1)!.text));
		assert.ok(!(await say(q1, "/system")).includes("Prefers metric"), "a forgotten note is no longer given");
		step("memory: forget removes a note");

		await say(q1, `/tool remember ${JSON.stringify({ note: "y".repeat(401) })}`);
		assert.ok(toolResults(q1).at(-1)!.isError && /401 characters; the most is 400/.test(toolResults(q1).at(-1)!.text), "a long note is refused with its length");
		for (let i = 0; i < 60; i++) await client.call("memory.add", { agentId: pilot, text: `note number ${i}` });
		assert.equal(noted().length, 60);
		await say(q1, '/tool remember {"note":"one too many"}');
		assert.ok(toolResults(q1).at(-1)!.isError && /60 notes.*Forget one/.test(toolResults(q1).at(-1)!.text), "the sixty-first is refused, saying what to do");
		await assert.rejects(client.call("memory.add", { agentId: pilot, text: "one too many" }), /60 notes/);
		step("memory: the length and count caps refuse with a message");

		const first = noted()[0]!;
		await client.call("memory.edit", { agentId: pilot, id: first.id, text: "edited by hand" });
		await client.until("edit broadcast", () => noted()[0]!.text === "edited by hand");
		await assert.rejects(client.call("memory.edit", { agentId: pilot, id: first.id, text: "z".repeat(401) }), /400 characters/);
		await assert.rejects(client.call("memory.edit", { agentId: pilot, id: "m999", text: "x" }), /gone/);
		await client.call("memory.delete", { agentId: pilot, id: first.id });
		await client.until("delete broadcast", () => noted().length === 59 && noted().every((n) => n.id !== first.id));
		assert.ok(noted().every((n) => n.conversation === null), "notes written by hand belong to no conversation");
		await client.call("memory.setEnabled", { agentId: pilot, enabled: false });
		await client.until("memory off", () => client.events.memory.agents[pilot].enabled === false);
		assert.equal(noted().length, 59, "turning memory off keeps the notes");
		said = await say(q1, "/system");
		assert.ok(!said.includes("your own notes"), "but they are no longer given");
		await say(q1, '/tool remember {"note":"after off"}');
		assert.ok(toolResults(q1).at(-1)!.isError && !/Noted/.test(toolResults(q1).at(-1)!.text), "and the tools are taken away at the next message");
		for (const n of noted()) await client.call("memory.delete", { agentId: pilot, id: n.id });
		step("memory: the app can turn it on and off and add, edit and delete notes");
	}

	{
		// look (engine/src/look.ts)
		const { symlinkSync } = await import("node:fs");
		const tree = removedAtEnd(realpathSync(mkdtempSync(join(tmpdir(), "pi2-look-"))));
		const outside = removedAtEnd(realpathSync(mkdtempSync(join(tmpdir(), "pi2-look-outside-"))));
		writeFileSync(join(outside, "secret.txt"), "needle outside\n");
		mkdirSync(join(tree, "src", "deep"), { recursive: true });
		mkdirSync(join(tree, "node_modules", "pkg"), { recursive: true });
		mkdirSync(join(tree, "many"));
		mkdirSync(join(tree, "hits"));
		writeFileSync(join(tree, "src", "app.ts"), "export const a = 1;\n// needle one\n");
		writeFileSync(join(tree, "src", "deep", "test_b.py"), "print('Needle two')\n");
		writeFileSync(join(tree, "node_modules", "pkg", "x.ts"), "needle hidden\n");
		writeFileSync(join(tree, "image.bin"), Buffer.from([0, 1, 2, 110, 101, 101, 100, 108, 101]));
		writeFileSync(join(tree, "README.md"), "hello\n");
		for (let i = 0; i < 320; i++) writeFileSync(join(tree, "many", `f${String(i).padStart(3, "0")}.txt`), "");
		for (let i = 0; i < 12; i++) writeFileSync(join(tree, "hits", `h${i}.txt`), Array.from({ length: 12 }, (_, n) => `line ${n} cap-me`).join("\n"));
		symlinkSync(outside, join(tree, "link-out"));
		symlinkSync(join(outside, "secret.txt"), join(tree, "link-file.txt"));

		const { id: lk } = await client.call("conversation.create");
		await client.call("conversation.open", { id: lk });
		let lookCalls = 0;
		const looked = async (id: number, name: string, args: Record<string, unknown>) => {
			lookCalls++;
			await client.call("submit", { id, text: `/tool ${name} ${JSON.stringify(args)}` });
			await settled(id, id === lk ? lookCalls : toolResults(id).length + 1);
			return toolResults(id).at(-1)! as any;
		};
		for (const name of ["list_files", "find_files", "search_files"]) {
			assert.equal((await looked(lk, name, { pattern: "x", query: "x" })).isError, true, `${name} is not offered with tools off`);
		}
		await client.call("conversation.configure", { id: lk, access: "read", cwd: tree });
		await client.until("look folder", () => client.conversations.get(lk)!.state.agent.cwd === tree);

		const listed = await looked(lk, "list_files", {});
		assert.equal(listed.isError, false, listed.text);
		assert.ok(listed.text.indexOf("many/") < listed.text.indexOf("README.md") && listed.text.includes("README.md  6 B") && listed.text.includes("src/"), listed.text);
		assert.ok(!listed.text.includes("node_modules/") && listed.text.includes("Left out by default: node_modules"), "heavy places are left out and the listing says so");
		assert.ok(listed.text.includes("link-out  (link, not followed)"));
		const many = await looked(lk, "list_files", { path: "many" });
		assert.match(many.text, /^many\/ : 320 entries\nf000\.txt/);
		assert.match(many.text, /… and 20 more not shown/, "the listing is capped and says so");
		assert.equal((await looked(lk, "list_files", { path: "src/deep/.." })).isError, false);
		assert.equal((await looked(lk, "list_files", { path: "src/app.ts" })).isError, true, "a file is not a folder");

		const found = await looked(lk, "find_files", { pattern: "**/*.{ts,py}" });
		assert.equal(found.isError, false, found.text);
		assert.ok(found.text.startsWith("2 files match") && found.text.includes("src/app.ts") && found.text.includes("src/deep/test_b.py") && !found.text.includes("x.ts"), found.text);
		assert.ok(!found.text.includes("secret"), "a link out of the folder is not followed");
		assert.match((await looked(lk, "find_files", { pattern: "*.txt", path: "many" })).text, /… and 120 more not shown/, "find is capped and says so");
		assert.match((await looked(lk, "find_files", { pattern: "test_*.py", path: "src" })).text, /^1 file matches/);

		const searched = await looked(lk, "search_files", { query: "needle", ignoreCase: true });
		assert.equal(searched.isError, false, searched.text);
		assert.ok(searched.text.startsWith("2 matches in 2 files") && searched.text.includes("src/app.ts\n  2: // needle one") && searched.text.includes("src/deep/test_b.py\n  1: print('Needle two')"), searched.text);
		assert.ok(!/hidden|outside|image\.bin/.test(searched.text.replace(/\(Not searched.*\)/, "")), "heavy places, linked files and binary files are not searched");
		assert.match(searched.text, /\(Not searched: 1 binary files\)/);
		assert.match((await looked(lk, "search_files", { query: "needle", glob: "**/*.ts" })).text, /^1 match in 1 file/);
		assert.match((await looked(lk, "search_files", { query: "ne+dle \\w+", regex: true, ignoreCase: true })).text, /^2 matches/);
		assert.equal((await looked(lk, "search_files", { query: "(", regex: true })).isError, true);
		assert.match((await looked(lk, "search_files", { query: "zzz-nothing" })).text, /^No matches in/);
		const hits = await looked(lk, "search_files", { query: "cap-me", path: "hits" });
		assert.match(hits.text, /… 2 more in this file/, "per file cap");
		assert.match(hits.text, /Stopped at 100 matches/, "total cap");
		assert.equal(hits.text.split("\n").filter((l: string) => /^  \d+: /.test(l)).length, 100);

		for (const path of ["..", "../../..", outside, join(outside, "secret.txt"), "link-out", "link-out/secret.txt", "link-file.txt"]) {
			for (const [name, args] of [["list_files", { path }], ["find_files", { pattern: "*", path }], ["search_files", { query: "needle", path }]] as const) {
				const refused = await looked(lk, name, args);
				assert.ok(refused.isError && /outside this conversation's folder/.test(refused.text) && !refused.text.includes("needle outside"), `${name} ${path}: ${refused.text}`);
			}
		}
		assert.equal(client.inbox.length, 0, "looking is never asked about");

		// The web: offered only with the agent's browser switched on, and only public pages.
		const webTools = ["web_fetch", "web_search"];
		await client.call("agents.save", { agent: { id: custom, name: "Quill", access: "read", browser: { enabled: false } } });
		await client.until("web off", () => (client.agents.find((x) => x.id === custom) as any)?.browser?.enabled === false);
		const { id: lw } = await client.call("conversation.create", { agentId: custom });
		await client.call("conversation.open", { id: lw });
		for (const name of webTools) assert.equal((await looked(lw, name, { url: "https://example.com/", query: "x" })).isError, true, `${name} is not offered without the browser switch`);
		assert.equal((await looked(lw, "list_files", {})).isError, false, "the agent's access reaches the file tools");
		await client.call("agents.save", { agent: { id: custom, name: "Quill", browser: { enabled: true } } });
		await client.until("web on", () => (client.agents.find((x) => x.id === custom) as any)?.browser?.enabled === true);
		const refusedAddresses: [string, RegExp][] = [
			["http://127.0.0.1:8080/", /off limits/],
			["http://localhost/", /off limits/],
			["http://169.254.169.254/latest/meta-data/", /off limits/],
			["http://192.168.1.1/admin", /off limits/],
			["http://[::1]/", /off limits/],
			["file:///etc/passwd", /http and https/],
			["ftp://example.com/x", /http and https/],
			["javascript:alert(1)", /http and https|not a web address/],
		];
		for (const [url, why] of refusedAddresses) {
			const refused = await looked(lw, "web_fetch", { url });
			assert.ok(refused.isError && why.test(refused.text), `${url}: ${refused.text}`);
		}
		assert.equal((await looked(lw, "web_search", { query: "" })).isError, true);
		assert.equal(client.inbox.length, 0, "reading the web is never asked about");
		await client.call("agents.save", { agent: { id: custom, name: "Quill", browser: { enabled: false } } });
		await client.until("web off again", () => (client.agents.find((x) => x.id === custom) as any)?.browser?.enabled === false);
		step("look: file tools only with tool access, inside the folder, never through a link, capped; web tools only with the browser switch, public addresses only");
	}

	{
		// documents (engine/src/documents.ts)
		const folder = removedAtEnd(realpathSync(mkdtempSync(join(tmpdir(), "pi2-docs-"))));
		const elsewhere = removedAtEnd(realpathSync(mkdtempSync(join(tmpdir(), "pi2-docs-outside-"))));
		const { id: dc } = await client.call("conversation.create");
		await client.call("conversation.open", { id: dc });
		let docCalls = 0;
		const document = async (args: Record<string, unknown>) => {
			docCalls++;
			await client.call("submit", { id: dc, text: `/tool write_document ${JSON.stringify(args)}` });
			await settled(dc, docCalls);
			return toolResults(dc).at(-1)! as any;
		};
		const SENTENCE = "The quarterly numbers are in and they are good.";
		const markdown = `# Quarterly report\n\n${SENTENCE}\n\n| Item | Count |\n|---|---|\n| Apples | 3 |\n`;
		const asText = (name: string) => execFileSync("/usr/bin/textutil", ["-convert", "txt", "-stdout", join(folder, name)], { encoding: "utf8" });

		// Without write access the tool is not there, and nothing is written.
		for (const access of ["none", "read"]) {
			await client.call("conversation.configure", { id: dc, access, cwd: folder });
			await client.until(`documents ${access}`, () => client.conversations.get(dc)!.state.agent.cwd === folder && client.conversations.get(dc)!.state.agent.access === access);
			const refused = await document({ path: "no.docx", markdown });
			assert.equal(refused.isError, true, `write_document is not offered with ${access} access`);
			assert.ok(!existsSync(join(folder, "no.docx")));
		}

		// Under "ask" it waits for the person, as write does.
		await client.call("conversation.configure", { id: dc, access: "ask", cwd: folder });
		await client.until("documents ask", () => client.conversations.get(dc)!.state.agent.access === "ask");
		await client.call("submit", { id: dc, text: `/tool write_document ${JSON.stringify({ path: "report.docx", markdown })}` });
		docCalls++;
		let ask = await client.until("approval to write a document", () => client.inbox.find((i) => i.conversationId === dc));
		assert.equal(ask.kind, "approval");
		assert.equal(ask.tool, "write_document");
		assert.equal((ask as any).arguments.path, "report.docx");
		await sleep(500);
		assert.equal(toolResults(dc).length, docCalls - 1, "nothing runs before the decision");
		assert.ok(!existsSync(join(folder, "report.docx")));
		await client.call("inbox.decide", { id: ask.id, decision: "deny" });
		await settled(dc, docCalls);
		assert.ok(toolResults(dc).at(-1)!.isError && /declined/.test(toolResults(dc).at(-1)!.text));
		assert.ok(!existsSync(join(folder, "report.docx")), "a denied document is not written");

		await client.call("submit", { id: dc, text: `/tool write_document ${JSON.stringify({ path: "report.docx", markdown })}` });
		docCalls++;
		ask = await client.until("second approval to write a document", () => client.inbox.find((i) => i.conversationId === dc));
		await client.call("inbox.decide", { id: ask.id, decision: "once" });
		await settled(dc, docCalls);
		const made = toolResults(dc).at(-1)! as any;
		assert.equal(made.isError, false, made.text);
		assert.match(made.text, /^Wrote report\.docx \(Word document\)/);
		assert.equal(readFileSync(join(folder, "report.docx")).subarray(0, 2).toString(), "PK", "a real Word file, not Markdown");
		const plain = asText("report.docx");
		assert.ok(plain.includes("Quarterly report") && plain.includes(SENTENCE) && plain.includes("Apples"), plain);
		assert.ok(!plain.includes("#") && !plain.includes("|---"), "the Markdown marks are gone");
		assert.equal(client.inbox.length, 0);

		// "Always allow" covers the tool for this conversation, as it does for write.
		await client.call("submit", { id: dc, text: `/tool write_document ${JSON.stringify({ path: "second.html", markdown: "# Second" })}` });
		docCalls++;
		ask = await client.until("approval before always", () => client.inbox.find((i) => i.conversationId === dc));
		await client.call("inbox.decide", { id: ask.id, decision: "always" });
		await settled(dc, docCalls);
		assert.ok(existsSync(join(folder, "second.html")));
		assert.equal((await document({ path: "third.rtf", markdown: "# Third" })).isError, false, "no second question after always");
		assert.equal(client.inbox.length, 0);
		assert.equal(readFileSync(join(folder, "third.rtf")).subarray(0, 5).toString(), "{\\rtf");

		// Refusals, with full access so that nothing waits.
		await client.call("conversation.configure", { id: dc, access: "full" });
		await client.until("documents full", () => client.conversations.get(dc)!.state.agent.access === "full");
		const refusedBy = async (args: Record<string, unknown>, pattern: RegExp) => {
			const result = await document(args);
			assert.equal(result.isError, true, `${JSON.stringify(args).slice(0, 60)} should be refused`);
			assert.match(result.text, pattern);
		};
		await refusedBy({ path: "../outside.docx", markdown }, /outside this conversation's folder/);
		await refusedBy({ path: join(elsewhere, "outside.docx"), markdown }, /outside this conversation's folder/);
		await refusedBy({ path: "notes.txt", markdown }, /\.docx \(Word\), \.rtf, \.odt \(OpenDocument\) and \.html/);
		await refusedBy({ path: "report.pdf", markdown }, /PDF is not offered.*\.docx/);
		await refusedBy({ path: "report.docx", markdown: "# Different" }, /already exists.*overwrite: true/);
		assert.ok(asText("report.docx").includes(SENTENCE), "the existing file was left alone");
		assert.deepEqual(readdirSync(elsewhere), [], "nothing was written outside the folder");
		const replaced = await document({ path: "report.docx", markdown: "# Different\n\nReplaced text.", overwrite: true });
		assert.equal(replaced.isError, false, replaced.text);
		assert.ok(asText("report.docx").includes("Replaced text.") && !asText("report.docx").includes(SENTENCE));
		assert.deepEqual(readdirSync(folder).sort(), ["report.docx", "second.html", "third.rtf"]);
		assert.equal(client.inbox.length, 0);

		rmSync(folder, { recursive: true, force: true });
		rmSync(elsewhere, { recursive: true, force: true });
		step("documents: write_document only with write access; under ask it waits for approval (deny writes nothing, always covers the conversation); a .docx is a real Word file; refuses other folders, other formats, PDF and overwriting");
	}

	{
		// command rules (engine/src/rules.ts)
		const { chmodSync } = await import("node:fs");
		const project = removedAtEnd(realpathSync(mkdtempSync(join(tmpdir(), "pi2-rules-"))));
		const elsewhere = removedAtEnd(realpathSync(mkdtempSync(join(tmpdir(), "pi2-rules-other-"))));
		for (const dir of [project, elsewhere]) {
			writeFileSync(join(dir, "run-tests"), '#!/bin/sh\necho "tests ran: $*"\n');
			chmodSync(join(dir, "run-tests"), 0o755);
		}
		type Rule = { folder: string; words: string[] };
		const rulesOf = (id: string) => ((client.agents.find((x) => x.id === id) as any)?.commandRules ?? []) as Rule[];
		const { id: smith } = await client.call("agents.save", { agent: { name: "Smith", access: "ask", cwd: project } });
		const { id: tester } = await client.call("agents.save", { agent: { name: "Tester", access: "ask", cwd: project } });
		await client.until("agents for rules", () => client.agents.some((x) => x.id === smith) && client.agents.some((x) => x.id === tester));
		const open = async (agentId: string, cwd: string | null = project) => {
			const { id } = await client.call("conversation.create", { agentId });
			await client.call("conversation.open", { id });
			if (cwd !== project && cwd !== null) await client.call("conversation.configure", { id, cwd });
			await client.until("conversation for rules", () => client.conversations.get(id)?.state.agent.cwd === cwd);
			return id as number;
		};
		/** Run a command and answer its approval with `decision`, if it asks. Says what it asked, or null. */
		const run = async (id: number, command: string, decision = "deny") => {
			const before = toolResults(id).length;
			await client.call("submit", { id, text: `/bash ${command}` });
			const asked = await client.until(`${command}: approval or result`, () => client.inbox.find((i) => i.conversationId === id) ?? (toolResults(id).length > before ? null : undefined));
			if (asked !== null) await client.call("inbox.decide", { id: asked.id, decision });
			await settled(id, before + 1);
			return { asked: asked as (InboxItem & { rule?: Rule }) | null, result: toolResults(id).at(-1)! };
		};

		// An approval for a command offers a rule, and choosing it runs the command and keeps the rule.
		const first = await open(smith);
		await client.call("submit", { id: first, text: "/bash ./run-tests --fast" });
		const offer = (await client.until("approval with a rule", () => client.inbox.find((i) => i.conversationId === first))) as InboxItem & { rule?: Rule };
		assert.deepEqual(offer.rule, { words: ["./run-tests"], folder: project }, "the engine proposes the command word, not its arguments");
		await assert.rejects(client.call("inbox.decide", { id: offer.id, decision: "sometimes" }), /Unknown decision/);
		await client.call("inbox.decide", { id: offer.id, decision: "rule" });
		await settled(first, 1);
		assert.match(toolResults(first)[0]!.text, /tests ran: --fast/);
		assert.equal(toolResults(first)[0]!.details?.allowedBy, undefined, "the person allowed that one, not a rule");
		await client.until("rule kept", () => rulesOf(smith).length === 1);
		assert.deepEqual(rulesOf(smith).map((r) => [r.folder, r.words]), [[project, ["./run-tests"]]]);
		assert.equal(rulesOf(tester).length, 0);

		// Kept across a restart, and good for a new conversation of that agent in that folder, other arguments included.
		await sleep(400);
		engine.kill("SIGKILL");
		await new Promise((resolve) => engine.once("exit", resolve));
		engine = startEngine();
		client = await Client.attach();
		await client.until("rules after restart", () => rulesOf(smith).length === 1);
		const second = await open(smith);
		let outcome = await run(second, "./run-tests --other 'a b' 2>&1 | tail -5");
		assert.equal(outcome.asked, null, "covered by the rule: nothing asked");
		assert.match(outcome.result.text, /tests ran: --other a b/);
		assert.deepEqual(outcome.result.details?.allowedBy, ["./run-tests"], "the result says which rule let it run");
		step("rules: an approval offers a rule for the command; choosing it runs the command and keeps the rule, across a restart; a new conversation of the agent in that folder runs it without asking, marked as allowed by the rule");

		// Anything more, another folder or another agent still asks, and offers no rule it could not keep.
		for (const command of ["./run-tests && touch pwned", "./run-tests; touch pwned", "./run-tests $(touch pwned)", "./run-tests > pwned", "cd . && ./run-tests", "FOO=1 ./run-tests"]) {
			outcome = await run(second, command);
			assert.ok(outcome.asked !== null, `${command} asks`);
			assert.equal(outcome.asked!.rule, undefined, `${command} offers no rule`);
			assert.equal(outcome.result.isError, true);
		}
		assert.ok(!existsSync(join(project, "pwned")), "nothing smuggled in ran");
		const results = toolResults(second).length;
		await client.call("submit", { id: second, text: "/bash ./run-tests || touch pwned" });
		const compound = await client.until("compound approval", () => client.inbox.find((i) => i.conversationId === second));
		await assert.rejects(client.call("inbox.decide", { id: compound.id, decision: "rule" }), /No rule can be made/, "the page cannot ask for a rule the engine did not offer");
		await client.call("inbox.decide", { id: compound.id, decision: "deny" });
		await settled(second, results + 1);
		const otherFolder = await open(smith, elsewhere);
		outcome = await run(otherFolder, "./run-tests");
		assert.deepEqual(outcome.asked?.rule, { words: ["./run-tests"], folder: elsewhere }, "another folder asks, and offers a rule for that folder");
		const otherAgent = await open(tester);
		assert.ok((await run(otherAgent, "./run-tests")).asked !== null, "another agent asks");
		step("rules: a compound command, a command that writes or changes folder, another folder and another agent all still ask");

		// A sub-chat and a scheduled run of the agent are covered too.
		const { id: lead } = await client.call("agents.save", { agent: { name: "Lead", access: "none", delegates: [smith] } });
		await client.until("lead saved", () => client.agents.some((x) => x.id === lead));
		const leading = await open(lead, null);
		await client.call("submit", { id: leading, text: "/delegate Smith: /bash ./run-tests --sub" });
		await settled(leading, 1);
		const sub = toolResults(leading)[0]!.details?.conversationId as number;
		assert.equal(typeof sub, "number", JSON.stringify(toolResults(leading)[0]));
		await client.call("conversation.open", { id: sub });
		const subResult = await client.until("sub-chat result", () => client.conversations.get(sub)?.items.find((i) => i.kind === "tool"));
		assert.ok(/tests ran: --sub/.test(subResult.text) && subResult.details?.allowedBy?.[0] === "./run-tests", JSON.stringify(subResult));
		const { id: scheduled } = await client.call("schedules.save", { schedule: { title: "Rule run", agentId: smith, prompt: "/bash ./run-tests --scheduled", repeat: { kind: "once", at: Date.now() + 1000 } } });
		const ruleRun = (await client.until("scheduled run", () => client.library.find((x) => x.title === "Rule run"))).id;
		await client.call("conversation.open", { id: ruleRun });
		const scheduledResult = await client.until("scheduled result", () => client.conversations.get(ruleRun)?.items.find((i) => i.kind === "tool"));
		assert.ok(/tests ran: --scheduled/.test(scheduledResult.text) && scheduledResult.details?.allowedBy?.[0] === "./run-tests", JSON.stringify(scheduledResult));
		await client.call("schedules.delete", { id: scheduled });
		assert.equal(client.inbox.length, 0, "neither asked");
		step("rules: sub-chats and scheduled runs of the agent in that folder are covered too");

		// By hand: the same checks, and a rule that would allow anything is refused, saying why.
		const add = (command: string, agentId = smith, folder = project) => client.call("rules.add", { agentId, folder, command });
		await assert.rejects(add("bash"), /bash alone would let the agent run anything/);
		await assert.rejects(add("python3 -c"), /code it writes on the spot/);
		await assert.rejects(add("rm -rf"), /always asks/);
		await assert.rejects(add("sudo npm test"), /always asks/);
		await assert.rejects(add("npm test; rm x"), /not a plain word/);
		await assert.rejects(add(""), /first words/);
		await assert.rejects(add("npm test", smith, join(project, "nope")), /Not a folder/);
		await assert.rejects(add("npm test", smith, "relative/folder"), /Not a folder/);
		await assert.rejects(add("npm test", "nobody"), /Unknown agent/);
		await add("  ./run-tests  ", tester);
		await client.until("rule added by hand", () => rulesOf(tester).length === 1);
		assert.deepEqual(rulesOf(tester)[0]!.words, ["./run-tests"]);
		await add("./run-tests", tester);
		assert.equal(rulesOf(tester).length, 1, "the same rule is not kept twice");
		outcome = await run(otherAgent, "./run-tests --by-hand");
		assert.ok(outcome.asked === null && outcome.result.details?.allowedBy?.[0] === "./run-tests", "a rule added by hand works like one chosen in an approval");
		// Saving the agent leaves its rules alone, whatever is sent.
		await client.call("agents.save", { agent: { id: smith, name: "Smith", description: "Edited", commandRules: [] } });
		await client.until("smith edited", () => (client.agents.find((x) => x.id === smith) as any)?.description === "Edited");
		assert.equal(rulesOf(smith).length, 1, "saving the agent does not touch its rules");
		step("rules: added by hand with the same checks; bash alone, inline code, rm, sudo and anything not plain are refused with a reason; saving the agent keeps them");

		// Removing a rule makes the command ask again; deleting the agent removes its rules.
		await client.call("rules.remove", { agentId: smith, folder: project, words: ["./run-tests"] });
		await client.until("rule removed", () => rulesOf(smith).length === 0);
		await assert.rejects(client.call("rules.remove", { agentId: smith, folder: project, words: ["./run-tests"] }), /already gone/);
		outcome = await run(second, "./run-tests");
		assert.ok(outcome.asked !== null && outcome.asked.rule !== undefined, "asks again, offering the rule again");
		await client.call("agents.delete", { id: tester });
		await client.until("tester deleted", () => !client.agents.some((x) => x.id === tester));
		await client.call("agents.save", { agent: { name: "Tester", access: "ask" } });
		await client.until("tester again", () => client.agents.some((x) => x.id === tester));
		assert.equal(rulesOf(tester).length, 0, "a new agent of the same name starts with no rules");
		for (const id of [lead, tester, smith]) await client.call("agents.delete", { id });
		rmSync(project, { recursive: true, force: true });
		rmSync(elsewhere, { recursive: true, force: true });
		step("rules: removing a rule makes the command ask again; deleting the agent deletes its rules");
	}

	{
		// limits (engine/src/limits.ts)
		const L = await import("../src/limits.ts");
		const { KeychainCredentialStore } = await import("../src/credentials.ts");
		const fiveReset = Date.now() + 2 * 3_600_000;
		const weekReset = Date.now() + 80 * 3_600_000;
		const unix = (ms: number) => Math.floor(ms / 1000);
		const rows = (reading: { windows: { id: string; label: string; usedPercent: number }[] } | undefined) => reading?.windows.map((w) => [w.id, w.label, w.usedPercent]);

		// Anthropic's headers on answers to subscription requests, as captured in public write-ups: fractions, Unix seconds.
		let reading = L.anthropicFromHeaders({
			"anthropic-ratelimit-unified-5h-utilization": "0.26",
			"anthropic-ratelimit-unified-5h-reset": String(unix(fiveReset)),
			"anthropic-ratelimit-unified-7d-utilization": "0.19",
			"anthropic-ratelimit-unified-7d-reset": String(unix(weekReset)),
			"anthropic-ratelimit-unified-representative-claim": "five_hour",
			"anthropic-ratelimit-unified-status": "allowed",
		});
		assert.deepEqual(rows(reading), [["five_hour", "5-hour window", 26], ["seven_day", "This week", 19]]);
		assert.equal(reading?.windows[0]!.resetsAt, unix(fiveReset) * 1000);
		assert.equal(L.anthropicFromHeaders({ "anthropic-ratelimit-requests-remaining": "40" }), undefined, "an API key's per-minute headers are not a subscription's windows");
		assert.equal(L.anthropicFromHeaders({ "anthropic-ratelimit-unified-5h-utilization": "47" }), undefined, "a value that is not a fraction is not guessed at");
		assert.equal(L.anthropicFromHeaders({ "Anthropic-Ratelimit-Unified-7d-Utilization": "1.0" })?.windows[0]!.usedPercent, 100, "any case of header name; a full window reads 100");

		// Anthropic's usage address: percentages and ISO times; a narrower window only when it is running.
		reading = L.anthropicFromUsage({
			five_hour: { utilization: 47.0, resets_at: new Date(fiveReset).toISOString() },
			seven_day: { utilization: 97.055, resets_at: new Date(weekReset).toISOString() },
			seven_day_opus: { utilization: 12, resets_at: new Date(weekReset).toISOString() },
			seven_day_sonnet: null,
			seven_day_oauth_apps: { utilization: 0, resets_at: null },
			extra_usage: { is_enabled: false, monthly_limit: null, used_credits: null, utilization: null },
			something_new: [1, 2],
		});
		assert.deepEqual(rows(reading), [["five_hour", "5-hour window", 47], ["seven_day", "This week", 97.1], ["seven_day_opus", "This week (Opus)", 12]]);
		assert.deepEqual(L.anthropicFromUsage({ five_hour: null, seven_day: null }), { plan: null, windows: [] }, "both windows null is an answer with nothing to show");
		for (const broken of [null, "<html>", 42, [], {}, { five_hour: "full", seven_day: 3 }, { five_hour: { utilization: "lots" } }, { five_hour: { utilization: -5 }, seven_day: { utilization: 9000 } }]) {
			assert.equal(L.anthropicFromUsage(broken), undefined, `unreadable: ${JSON.stringify(broken)}`);
		}

		// Codex's usage address, shaped as in the open-source Codex client's own tests.
		const codexAnswer = {
			account_id: "account-123",
			user_id: "user-123",
			plan_type: "plus",
			rate_limit: {
				allowed: true,
				limit_reached: false,
				primary_window: { used_percent: 42, limit_window_seconds: 18000, reset_after_seconds: 7200, reset_at: unix(fiveReset) },
				secondary_window: { used_percent: 5, limit_window_seconds: 604800, reset_after_seconds: 288000, reset_at: unix(weekReset) },
			},
			additional_rate_limits: [{ limit_name: "GPT-5.3-Codex-Spark", metered_feature: "codex_other", rate_limit: { allowed: true, limit_reached: false, primary_window: { used_percent: 88, limit_window_seconds: 18000, reset_after_seconds: 600, reset_at: unix(fiveReset) } } }],
			credits: null,
			spend_control: { reached: false },
		};
		reading = L.codexFromUsage(codexAnswer);
		assert.equal(reading?.plan, "Plus");
		assert.deepEqual(rows(reading), [["codex.primary", "5-hour window", 42], ["codex.secondary", "This week", 5], ["codex_other.primary", "5-hour window (GPT-5.3-Codex-Spark)", 88]]);
		assert.equal(reading?.windows[1]!.resetsAt, unix(weekReset) * 1000);
		assert.deepEqual(L.codexFromUsage({ plan_type: "free", rate_limit: null }), { plan: "Free", windows: [] });
		assert.equal(L.codexFromUsage({ rate_limit: { primary_window: { used_percent: 1, limit_window_seconds: 18000, reset_after_seconds: 600 } } }, 1_000_000)?.windows[0]!.resetsAt, 1_600_000, "without reset_at, the reset is counted from reset_after_seconds");
		for (const broken of [null, {}, { plan_type: "pro" }, { rate_limit: "full" }, { rate_limit: { primary_window: { used_percent: "x" } } }, { rate_limit: { primary_window: { used_percent: -3 } } }]) {
			assert.equal(L.codexFromUsage(broken), undefined, `unreadable: ${JSON.stringify(broken)}`);
		}

		// Codex's headers (over HTTP) and its rate-limit event (over a WebSocket), as the Codex client parses them.
		reading = L.codexFromHeaders({
			"x-codex-primary-used-percent": "12.5",
			"x-codex-primary-window-minutes": "300",
			"x-codex-primary-reset-at": String(unix(fiveReset)),
			"x-codex-secondary-used-percent": "3",
			"x-codex-secondary-window-minutes": "10080",
			"x-codex-bengalfox-primary-used-percent": "80",
			"x-codex-bengalfox-primary-window-minutes": "300",
			"x-codex-bengalfox-limit-name": "gpt-5.2-codex-sonic",
			"x-codex-other-primary-used-percent": "0",
		});
		assert.deepEqual(rows(reading), [["codex.primary", "5-hour window", 12.5], ["codex.secondary", "This week", 3], ["codex_bengalfox.primary", "5-hour window (gpt-5.2-codex-sonic)", 80]]);
		assert.equal(L.codexFromHeaders({ "x-codex-primary-used-percent": "NaN" }), undefined);
		reading = L.codexFromEvent({ type: "codex.rate_limits", plan_type: "pro", rate_limits: { allowed: true, limit_reached: false, primary: { used_percent: 42, window_minutes: 300, reset_at: unix(fiveReset) }, secondary: null }, credits: { has_credits: true, unlimited: false, balance: "123" } });
		assert.deepEqual([reading?.plan, reading?.windows.map((w) => [w.id, w.usedPercent, w.resetsAt])], ["Pro", [["codex.primary", 42, unix(fiveReset) * 1000]]]);
		assert.equal(L.codexFromEvent({ type: "response.output_text.delta", delta: "hi" }), undefined);
		assert.equal(L.codexAccount(`h.${Buffer.from(JSON.stringify({ "https://api.openai.com/auth": { chatgpt_account_id: "acct-9" } })).toString("base64url")}.s`), "acct-9");
		assert.equal(L.codexAccount("not-a-token"), undefined);

		// Copilot's quota headers, in the form VS Code's Copilot Chat reads them.
		reading = L.copilotFromHeaders({
			"x-quota-snapshot-chat": "ent=-1&ov=0.0&ovPerm=false&rem=100.0&rst=2026-12-01T00%3A00%3A00Z&totRem=-1",
			"x-quota-snapshot-premium_interactions": `ent=300&ov=0.0&ovPerm=false&rem=62.5&rst=${encodeURIComponent(new Date(weekReset).toISOString())}`,
			"x-quota-snapshot-completions": "ent=-1&rem=100",
		});
		assert.deepEqual(rows(reading), [["premium", "Premium requests", 37.5]]);
		assert.deepEqual(L.copilotFromHeaders({ "x-quota-snapshot-premium_interactions": "ent=-1&rem=100" }), { plan: null, windows: [], note: "No limit on this plan." });
		assert.equal(L.copilotFromHeaders({ "x-quota-snapshot-premium_interactions": "garbage" }), undefined);

		// Kimi's usage address, the least certain shape: counts as strings, a rolling window and a weekly allowance.
		reading = L.kimiFromUsage({
			user: { membership: { level: "LEVEL_INTERMEDIATE" } },
			usage: { limit: "100", used: "37", remaining: "63", resetTime: new Date(weekReset).toISOString() },
			limits: [{ window: { duration: 300, timeUnit: "TIME_UNIT_MINUTE" }, detail: { limit: "100", remaining: "80", resetTime: new Date(fiveReset).toISOString() } }],
		});
		assert.deepEqual([reading?.plan, rows(reading)], ["Intermediate", [["five_hour", "5-hour window", 20], ["seven_day", "This week", 37]]]);
		assert.equal(L.kimiFromUsage({ usage: { limit: 0, used: 5 } }), undefined);

		// The wrapper on a subscription provider: the observer hears every answer, the caller's own callbacks still
		// run, `this` is the provider's own, and an observer that throws does not fail the request.
		const heard: string[] = [];
		const callerHeard: string[] = [];
		const fake: any = {
			id: "fake",
			stream: (_model: unknown, _context: unknown, options: any) => {
				void options.onResponse({ status: 200, headers: { "x-test": "1" } }, {});
				void options.onProviderStreamEvent?.({ type: "codex.rate_limits" }, {});
				return "streamed";
			},
			streamSimple(this: unknown, _model: unknown, _context: unknown, options: any) {
				void options.onResponse({ status: 200, headers: { "x-test": "2" } }, {});
				return this === fake ? "simple" : "lost this";
			},
		};
		const wrapped: any = L.observed(fake, { onResponse: (headers) => heard.push(`headers ${headers["x-test"]}`), onEvent: (event: any) => heard.push(`event ${event.type}`) });
		assert.equal(wrapped.stream({}, {}, { onResponse: () => callerHeard.push("caller") }), "streamed");
		assert.equal(wrapped.streamSimple({}, {}, undefined), "simple");
		assert.equal(wrapped.id, "fake");
		await sleep(10);
		assert.deepEqual(heard, ["headers 1", "event codex.rate_limits", "headers 2"]);
		assert.deepEqual(callerHeard, ["caller"]);
		const throwing: any = L.observed(fake, { onResponse: () => { throw new Error("observer failed"); } });
		assert.equal(throwing.stream({}, {}, {}), "streamed");
		await sleep(10);

		// End to end: a second engine on its own data folder and Keychain service, with two subscription sign-ins
		// stored there as pi-ai stores them, not due for renewal (so no real sign-in server is called), and a local
		// stand-in for each usage address.
		const limitsHome = removedAtEnd(mkdtempSync(join(tmpdir(), "pi2-limits-")));
		const store = new KeychainCredentialStore(limitsHome, `${KEYCHAIN_SERVICE}.limits`);
		const claudeToken = "sk-ant-oat01-limits-test-not-a-real-token";
		const codexToken = `e30.${Buffer.from(JSON.stringify({ "https://api.openai.com/auth": { chatgpt_account_id: "acct-limits-test" } })).toString("base64url")}.not-signed`;
		const notDue = Date.now() + 30 * 86_400_000;
		let anthropicMode: "ok" | "garbage" | "busy" = "ok";
		let codexMode: "ok" | "silent" = "ok";
		const hits = { anthropic: 0, codex: 0 };
		const seen: Record<string, Record<string, unknown>> = {};
		const json = { "content-type": "application/json" };
		const standIn = createServer((request, response) => {
			if (request.url === "/api/oauth/usage") {
				hits.anthropic++;
				seen.anthropic = request.headers;
				if (anthropicMode === "busy") return void response.writeHead(429, { ...json, "retry-after": "1" }).end(JSON.stringify({ type: "error", error: { type: "rate_limit_error" } }));
				if (anthropicMode === "garbage") return void response.writeHead(200, { "content-type": "text/html" }).end("<html>Down for maintenance</html>");
				return void response
					.writeHead(200, json)
					.end(JSON.stringify({ five_hour: { utilization: 47, resets_at: new Date(fiveReset).toISOString() }, seven_day: { utilization: 12.5, resets_at: new Date(weekReset).toISOString() }, seven_day_opus: null }));
			}
			if (request.url === "/backend-api/wham/usage") {
				hits.codex++;
				seen.codex = request.headers;
				if (codexMode === "silent") return; // never answers
				return void response.writeHead(200, json).end(JSON.stringify(codexAnswer));
			}
			response.writeHead(404).end();
		});
		await new Promise<void>((resolve) => standIn.listen(0, "127.0.0.1", resolve));
		const standInUrl = `http://127.0.0.1:${(standIn.address() as { port: number }).port}`;
		// Copilot reports only in the headers of its answers. Its sign-in names the address to send requests to, and
		// pi-ai always uses https for it: a stand-in over TLS, with a certificate made here that only the second engine
		// trusts.
		const { createServer: createTlsServer } = await import("node:https");
		const { GITHUB_COPILOT_MODELS } = await import("@earendil-works/pi-ai/providers/github-copilot.models");
		const copilotModel = Object.values(GITHUB_COPILOT_MODELS).find((model: any) => model.api === "openai-completions")!.id;
		execFileSync("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", join(limitsHome, "key.pem"), "-out", join(limitsHome, "cert.pem"), "-days", "1", "-subj", "/CN=127.0.0.1", "-addext", "subjectAltName=IP:127.0.0.1"], { stdio: "ignore" });
		let copilotAuthorization: string | undefined;
		const copilotStandIn = createTlsServer({ key: readFileSync(join(limitsHome, "key.pem")), cert: readFileSync(join(limitsHome, "cert.pem")) }, (request, response) => {
			if (request.method !== "POST" || !request.url?.endsWith("/chat/completions")) return void response.writeHead(404).end();
			copilotAuthorization = request.headers.authorization;
			request.resume().on("end", () => {
				response.writeHead(200, {
					"content-type": "text/event-stream",
					"x-quota-snapshot-premium_interactions": `ent=300&ov=0.0&ovPerm=false&rem=62.5&rst=${encodeURIComponent(new Date(weekReset).toISOString())}`,
					"x-quota-snapshot-chat": "ent=-1&ov=0.0&ovPerm=false&rem=100.0&totRem=-1",
				});
				const chunk = (delta: object, finish: string | null) =>
					response.write(`data: ${JSON.stringify({ id: "c1", object: "chat.completion.chunk", created: 1, model: copilotModel, choices: [{ index: 0, delta, finish_reason: finish }] })}\n\n`);
				chunk({ role: "assistant", content: "Hello from the Copilot stand-in." }, null);
				chunk({}, "stop");
				response.end("data: [DONE]\n\n");
			});
		});
		await new Promise<void>((resolve) => copilotStandIn.listen(0, "127.0.0.1", resolve));
		const copilotToken = `tid=limits-test;exp=9999999999;proxy-ep=127.0.0.1:${(copilotStandIn.address() as { port: number }).port};`;
		let log = "";
		const startLimitsEngine = () => {
			const child = spawn(process.execPath, [main], {
				env: {
					...process.env,
					PI2_HOME: limitsHome,
					PI2_KEYCHAIN_SERVICE: `${KEYCHAIN_SERVICE}.limits`,
					PI2_LIMITS_ANTHROPIC_URL: `${standInUrl}/api/oauth/usage`,
					PI2_LIMITS_CODEX_URL: `${standInUrl}/backend-api/wham/usage`,
					PI2_LIMITS_KIMI_URL: `${standInUrl}/coding/v1/usages`,
					PI2_LIMITS_MIN_INTERVAL_MS: "1500",
					NODE_EXTRA_CA_CERTS: join(limitsHome, "cert.pem"),
				},
				stdio: ["ignore", "ignore", "pipe"],
			});
			child.stderr!.setEncoding("utf8").on("data", (chunk: string) => (log += chunk));
			return child;
		};
		const attachLimits = async () => {
			const watcher = new Client();
			const path = join(limitsHome, "engine.sock");
			for (let attempt = 0; ; attempt++) {
				try {
					if (!existsSync(path)) throw new Error("no socket yet");
					watcher.socket = connect(path);
					await new Promise<void>((resolve, reject) => watcher.socket.once("connect", resolve).once("error", reject));
					break;
				} catch (error) {
					if (attempt >= 300) throw error;
					await sleep(50);
				}
			}
			let buffer = "";
			watcher.socket.setEncoding("utf8").on("data", (chunk: string) => {
				buffer += chunk;
				const lines = buffer.split("\n");
				buffer = lines.pop()!;
				for (const line of lines) watcher.receive(JSON.parse(line));
			});
			watcher.socket.on("error", () => {});
			return watcher;
		};
		let limitsEngine: ChildProcess | undefined;
		try {
			await store.modify("anthropic", async () => ({ type: "oauth", access: claudeToken, refresh: "limits-test-refresh-a", expires: notDue }));
			await store.modify("openai-codex", async () => ({ type: "oauth", access: codexToken, refresh: "limits-test-refresh-c", expires: notDue, accountId: "acct-limits-test" }));
			await store.modify("github-copilot", async () => ({ type: "oauth", access: copilotToken, refresh: "limits-test-refresh-g", expires: notDue, availableModelIds: [copilotModel] }));
			limitsEngine = startLimitsEngine();
			let watcher = await attachLimits();
			const limitsOf = (id: string): any => watcher.events.limits?.providers?.find((p: any) => p.id === id);
			await watcher.until("limits sent on connecting", () => watcher.events.limits !== undefined);
			// Both signed-in subscriptions are asked at start.
			await watcher.until("both read", () => limitsOf("anthropic")?.windows.length > 0 && limitsOf("openai-codex")?.windows.length > 0, 20_000);
			const claude = limitsOf("anthropic");
			assert.deepEqual(rows(claude), [["five_hour", "5-hour window", 47], ["seven_day", "This week", 12.5]]);
			assert.deepEqual([claude.name, claude.plan, claude.reports, claude.source, claude.error], ["Anthropic", null, "usage", "usage", null]);
			assert.equal(claude.windows[0].resetsAt, Date.parse(new Date(fiveReset).toISOString()));
			const codex = limitsOf("openai-codex");
			assert.deepEqual([codex.name, codex.plan, codex.windows.length], ["OpenAI Codex", "Plus", 3]);
			assert.deepEqual(watcher.events.limits.providers.map((p: any) => p.id).sort(), ["anthropic", "github-copilot", "openai-codex"], "only the signed-in subscriptions");
			assert.equal(seen.anthropic!.authorization, `Bearer ${claudeToken}`);
			assert.equal(seen.anthropic!["anthropic-beta"], "oauth-2025-04-20");
			assert.equal(seen.codex!.authorization, `Bearer ${codexToken}`);
			assert.equal(seen.codex!["chatgpt-account-id"], "acct-limits-test");

			// Copilot has nothing to show until a request on it has been answered; then its premium requests show,
			// read from that answer's headers on the way through, and the answer itself is unchanged.
			assert.deepEqual([limitsOf("github-copilot").reports, limitsOf("github-copilot").windows], ["responses", []]);
			const { id: onCopilot } = await watcher.call("conversation.create");
			await watcher.call("conversation.configure", { id: onCopilot, model: { provider: "github-copilot", modelId: copilotModel } });
			await watcher.call("conversation.open", { id: onCopilot });
			await watcher.call("submit", { id: onCopilot, text: "hello" });
			const copilotAnswer = await watcher.idle(onCopilot);
			assert.ok(copilotAnswer.items.some((i) => i.kind === "assistant" && i.text.includes("Hello from the Copilot stand-in.")), JSON.stringify(copilotAnswer.items));
			assert.equal(copilotAuthorization, `Bearer ${copilotToken}`);
			await watcher.until("copilot read from its answer", () => limitsOf("github-copilot")?.windows.length > 0);
			assert.deepEqual(rows(limitsOf("github-copilot")), [["premium", "Premium requests", 37.5]]);
			assert.equal(limitsOf("github-copilot").source, "responses");

			// Asked twice in a row: within the minimum interval the second sends nothing. The interval is waited out first,
			// so the first always sends, whatever the steps above took on this machine.
			await sleep(1600);
			const beforeHits = { ...hits };
			await watcher.call("limits.refresh");
			const firstHits = { ...hits };
			assert.deepEqual(firstHits, { anthropic: beforeHits.anthropic + 1, codex: beforeHits.codex + 1 }, "the first asks each once");
			let answer = await watcher.call("limits.refresh");
			assert.deepEqual(hits, firstHits, "no second request within the interval");
			assert.equal(answer.providers.length, 3);
			await assert.rejects(watcher.call("limits.refresh", { id: "xai" }), /not signed in/);

			// An answer that cannot be read: said plainly, with when, and the last good figures kept.
			await sleep(1600);
			anthropicMode = "garbage";
			answer = await watcher.call("limits.refresh", { id: "anthropic" });
			let now = answer.providers.find((p: any) => p.id === "anthropic");
			assert.equal(now.error, "Could not read the limits");
			assert.ok(now.errorAt >= now.fetchedAt);
			assert.equal(now.windows[0].usedPercent, 47, "the last good reading stays");

			// Too many requests: said plainly, and the address is left alone for minutes, whatever it said.
			await sleep(1600);
			anthropicMode = "busy";
			answer = await watcher.call("limits.refresh", { id: "anthropic" });
			assert.match(answer.providers.find((p: any) => p.id === "anthropic").error, /check less often/);
			const busyHits = hits.anthropic;
			await sleep(1600);
			await watcher.call("limits.refresh", { id: "anthropic" });
			assert.equal(hits.anthropic, busyHits, "not asked again soon after a 429");

			// An address that never answers is given up on after a few seconds.
			codexMode = "silent";
			const asked = Date.now();
			answer = await watcher.call("limits.refresh", { id: "openai-codex" });
			now = answer.providers.find((p: any) => p.id === "openai-codex");
			assert.match(now.error, /did not answer within 6 seconds/);
			assert.ok(Date.now() - asked < 12_000);
			assert.equal(now.windows.length, 3);

			// Signing out takes a subscription off the list.
			await watcher.call("providers.logout", { id: "openai-codex" });
			await watcher.until("signed out", () => watcher.events.limits.providers.length === 2 && limitsOf("openai-codex") === undefined);

			// After a restart the last good reading is there at once, and a recent one is not asked for again.
			await watcher.until("readings saved", () => existsSync(join(limitsHome, "limits.json")) && !readFileSync(join(limitsHome, "limits.json"), "utf8").includes("openai-codex"));
			limitsEngine.kill("SIGTERM");
			await new Promise((resolve) => limitsEngine!.once("exit", resolve));
			anthropicMode = "ok";
			const beforeRestart = hits.anthropic;
			limitsEngine = startLimitsEngine();
			watcher = await attachLimits();
			await watcher.until("readings kept across a restart", () => limitsOf("anthropic")?.windows[0]?.usedPercent === 47 && limitsOf("github-copilot")?.windows[0]?.usedPercent === 37.5, 20_000);
			assert.equal(hits.anthropic, beforeRestart);

			// No token on disk or in the log.
			for (const secret of [claudeToken, codexToken, "tid=limits-test", "limits-test-refresh"]) {
				assert.ok(!log.includes(secret), "no token in the engine's log");
				const leaked = readdirSync(limitsHome).filter((name) => statSync(join(limitsHome, name)).isFile() && readFileSync(join(limitsHome, name)).includes(secret));
				assert.deepEqual(leaked, [], "no token on disk");
			}
			step("limits: each subscription's windows from its usage address or from its answers' headers on a real request; at most once a minute, longer after a 429; unreadable or silent answers said plainly with the last good figures kept; sign-out, restart, no token on disk or in the log");
		} finally {
			limitsEngine?.kill("SIGTERM");
			standIn.closeAllConnections();
			standIn.close();
			copilotStandIn.closeAllConnections();
			copilotStandIn.close();
			await sleep(400);
			for (const id of ["anthropic", "openai-codex", "github-copilot"]) await store.delete(id).catch(() => {});
			rmSync(limitsHome, { recursive: true, force: true });
		}
	}

	{
		// selfschedule (engine/src/selfschedule.ts)
		const { checkWords, describeScheduling, MAX_AGENT_SCHEDULES, readLocalTime, resolveTiming } = await import("../src/selfschedule.ts");
		const monday = new Date(2026, 10, 9, 8, 30).getTime(); // a Monday morning, local time
		const section = describeScheduling(monday);
		assert.ok(section.includes("Today is Monday 9 November 2026 (2026-11-09)") && section.includes(Intl.DateTimeFormat().resolvedOptions().timeZone), "the prompt gives the date and the time zone");
		assert.ok(!section.includes("08:30"), "but not the clock, which would change the prompt at every message");
		assert.equal(readLocalTime("2026-11-10 07:05"), new Date(2026, 10, 10, 7, 5).getTime());
		assert.equal(readLocalTime("2026-11-31 07:05"), undefined, "a day that does not exist is refused");
		assert.equal(readLocalTime("2026-11-10T07:05Z"), undefined, "so is a time zone: times are the Mac's");
		assert.deepEqual(resolveTiming({ repeat: "Weekly", weekday: "fri", time: "9:00" }, monday), { kind: "weekly", weekday: 5, hour: 9, minute: 0 });
		assert.deepEqual(resolveTiming({ repeat: "once", in_minutes: 120 }, monday), { kind: "once", at: monday + 120 * 60_000 });
		assert.match(resolveTiming({ repeat: "once", at: "2026-11-09 08:00" }, monday) as string, /already passed: it is now 2026-11-09 08:30/);
		assert.match(resolveTiming({ repeat: "once", at: "2026-11-09 09:00", in_minutes: 5 }, monday) as string, /not both/);
		assert.match(resolveTiming({ repeat: "daily", time: "7am" }, monday) as string, /HH:MM on the 24-hour clock/);
		assert.match(checkWords("Long", "p".repeat(2001)) as string, /2001 characters; the most is 2000/);
		assert.deepEqual(checkWords("  Morning\n brief ", " Do it. "), { title: "Morning brief", prompt: "Do it." });

		const results = (id: number) => client.conversations.get(id)!.items.filter((i) => i.kind === "tool");
		const asked = (id: number) => client.inbox.find((i) => i.conversationId === id && i.tool === "schedule_task");
		/** Have the agent call a tool; when `decide` is given, wait for the approval and answer it. Resolves with the result. */
		const use = async (id: number, name: string, args: unknown, decide?: (ask: InboxItem) => string) => {
			const before = results(id).length;
			await client.call("submit", { id, text: `/tool ${name} ${JSON.stringify(args)}` });
			if (decide !== undefined) {
				const ask = await client.until(`${name} asks first`, () => asked(id));
				await client.call("inbox.decide", { id: ask.id, decision: decide(ask) });
			}
			await client.until(`${name} answered`, () => !client.conversations.get(id)!.state.busy && results(id).length === before + 1);
			return results(id).at(-1)!;
		};
		const schedulesOf = (agentId: string) => (client.schedules as any[]).filter((s) => s.agentId === agentId);
		const stamp = (ms: number) => {
			const d = new Date(ms);
			const two = (n: number) => String(n).padStart(2, "0");
			return `${d.getFullYear()}-${two(d.getMonth() + 1)}-${two(d.getDate())} ${two(d.getHours())}:${two(d.getMinutes())}:${two(d.getSeconds())}`;
		};
		const brief = { title: "Morning news brief", prompt: "Sum up the news.", repeat: "daily", time: "07:00" };

		// Off by default: no tools.
		const { id: herald } = await client.call("agents.save", { agent: { name: "Herald", access: "none" } });
		await client.until("herald saved", () => client.agents.some((x) => x.id === herald));
		assert.deepEqual((client.agents.find((x) => x.id === herald) as any).schedule, { enabled: false });
		const { id: h } = await client.call("conversation.create", { agentId: herald });
		await client.call("conversation.open", { id: h });
		let answer = await use(h, "schedule_task", brief);
		assert.ok(answer.isError && /not available/.test(answer.text), `switched off, the tool is not offered: ${answer.text}`);
		assert.equal(asked(h), undefined);
		assert.equal(schedulesOf(herald).length, 0);
		step("selfschedule: off by default, no tools; times are read as the Mac's local time and refused plainly");

		// On: every new schedule asks first. Deny makes nothing; allow makes it, marked with who set it.
		await client.call("agents.save", { agent: { id: herald, name: "Herald", schedule: { enabled: true } } });
		await client.until("scheduling on", () => (client.agents.find((x) => x.id === herald) as any)?.schedule?.enabled === true);
		answer = await use(h, "schedule_task", brief, (ask) => {
			assert.equal(ask.kind, "approval");
			assert.match(ask.question!, /^Herald wants to schedule “Morning news brief”: every day at 07:00, first run \w+day \d+ \w+( \d{4})? at 07:00 — Sum up the news\.$/);
			assert.match((ask as any).when, /^Every day at 07:00, first run /);
			assert.equal(schedulesOf(herald).length, 0, "nothing is made before the decision");
			return "deny";
		});
		assert.ok(answer.isError && /declined/.test(answer.text), answer.text);
		assert.equal(schedulesOf(herald).length, 0, "deny makes nothing");
		answer = await use(h, "schedule_task", brief, () => "once");
		assert.ok(!answer.isError && /^Scheduled “Morning news brief” \(s\w+\): every day at 07:00\. The first run is at \d{4}-\d\d-\d\d 07:00 /.test(answer.text), answer.text);
		const made = await client.until("schedule made", () => schedulesOf(herald)[0]);
		assert.deepEqual(made.createdBy, { agentId: herald, conversationId: h });
		assert.deepEqual([made.title, made.prompt, made.enabled, made.repeat], ["Morning news brief", "Sum up the news.", true, { kind: "daily", hour: 7, minute: 0 }]);
		assert.ok(new Date(made.nextRunAt).getHours() === 7 && made.nextRunAt > Date.now() && made.nextRunAt <= Date.now() + 86_400_000);
		assert.deepEqual(answer.details, { id: made.id, title: "Morning news brief", when: "every day at 07:00" });
		// "Always" is not offered for this tool; an app that sends it gets once, and the next schedule is asked about again.
		answer = await use(h, "schedule_task", { title: "Hourly check", prompt: "Check the build.", repeat: "interval", minutes: 60 }, () => "always");
		assert.equal(answer.isError, false, answer.text);
		answer = await use(h, "schedule_task", { title: "Lunch", prompt: "Lunch time.", repeat: "once", in_minutes: 90 }, () => "deny");
		assert.ok(answer.isError && /declined/.test(answer.text), "after an “always”, the next schedule still asks");
		// Killed while the question waits: asked again, about the same schedule at the same time, and made once.
		await client.call("submit", { id: h, text: `/tool schedule_task ${JSON.stringify({ title: "Wrap-up", prompt: "Sum up the day.", repeat: "once", in_minutes: 600 })}` });
		const beforeCrash = await client.until("approval before the crash", () => asked(h));
		engine.kill("SIGKILL");
		await new Promise((resolve) => engine.once("exit", resolve));
		engine = startEngine();
		client = await Client.attach();
		await client.call("conversation.open", { id: h });
		const afterCrash = await client.until("asked again after the restart", () => asked(h));
		assert.equal(afterCrash.question, beforeCrash.question, "the same schedule, at the same time");
		await client.call("inbox.decide", { id: afterCrash.id, decision: "once" });
		await client.until("made after the restart", () => !client.conversations.get(h)!.state.busy && schedulesOf(herald).some((s) => s.title === "Wrap-up"));
		await sleep(400);
		assert.equal(schedulesOf(herald).filter((s) => s.title === "Wrap-up").length, 1, "and only once");
		step("selfschedule: each new schedule asks first, allow once or deny, never always; deny makes nothing; allow makes it with createdBy; asked again after kill -9");

		// List: this agent's schedules, saying who set each. Cancel: only its own.
		const { id: weekly } = await client.call("schedules.save", { schedule: { title: "Weekly report", agentId: herald, prompt: "Report on the week.", repeat: { kind: "weekly", weekday: 1, hour: 9, minute: 0 } } });
		const { id: atlasOnly } = await client.call("schedules.save", { schedule: { title: "Atlas only", agentId: "atlas", prompt: "x", repeat: { kind: "daily", hour: 6, minute: 0 } } });
		await client.until("the person's schedules", () => client.schedules.some((s) => s.id === weekly) && client.schedules.some((s) => s.id === atlasOnly));
		answer = await use(h, "list_schedules", {});
		assert.equal(answer.isError, false, answer.text);
		assert.match(answer.text, /^It is now \w+day \d+ \w+ at \d\d:\d\d \(\d{4}-\d\d-\d\d \d\d:\d\d, /);
		assert.match(answer.text, new RegExp(`- ${made.id}: “Morning news brief”, every day at 07:00; next run \\d{4}-\\d\\d-\\d\\d 07:00 \\(\\w+day\\); set by you\\.`));
		assert.match(answer.text, /“Weekly report”, every Monday at 09:00; next run [^;]+; set by the person, so you cannot cancel it\./);
		assert.ok(!answer.text.includes("Atlas only"), "another agent's schedules are not listed");
		assert.match(answer.text, /You set 3 of the 20 schedules you may have/);
		answer = await use(h, "cancel_schedule", { id: weekly });
		assert.ok(answer.isError && /set by the person, not by you/.test(answer.text), answer.text);
		answer = await use(h, "cancel_schedule", { id: atlasOnly });
		assert.ok(answer.isError && /no schedule \S+ of yours/.test(answer.text), `nor another agent's: ${answer.text}`);
		assert.ok(client.schedules.some((s) => s.id === weekly) && client.schedules.some((s) => s.id === atlasOnly), "both stay");
		answer = await use(h, "cancel_schedule", { id: made.id });
		assert.ok(!answer.isError && answer.text.startsWith("Cancelled “Morning news brief”"), answer.text);
		await client.until("cancelled", () => !client.schedules.some((s) => s.id === made.id));
		assert.equal(asked(h), undefined, "listing and cancelling ask nothing");
		await client.call("schedules.delete", { id: atlasOnly });
		step("selfschedule: list shows this agent's schedules and who set them; cancel removes only its own");

		// Limits, refused before anything is asked.
		for (const [what, args, message] of [
			["too often", { title: "Spam", prompt: "x", repeat: "interval", minutes: 5 }, /at most every 15 minutes, so 5 is too often/],
			["a long title", { title: "t".repeat(81), prompt: "x", repeat: "daily", time: "08:00" }, /81 characters; keep it to 80/],
			["a time gone by", { title: "Late", prompt: "x", repeat: "once", at: "2020-01-01 09:00" }, /already passed/],
		] as const) {
			answer = await use(h, "schedule_task", args);
			assert.ok(answer.isError && message.test(answer.text), `${what}: ${answer.text}`);
		}
		// The cap, through a script: each of its calls asks too, and the one over the cap is refused without asking.
		const { id: ledger } = await client.call("agents.save", { agent: { name: "Ledger", access: "none", codeMode: true, schedule: { enabled: true } } });
		await client.until("ledger saved", () => client.agents.some((x) => x.id === ledger));
		const { id: l } = await client.call("conversation.create", { agentId: ledger });
		await client.call("conversation.open", { id: l });
		const script = "for (let i = 1; i <= 21; i++) { try { await tools.schedule_task({ title: 'Check ' + i, prompt: 'Check ' + i, repeat: 'interval', minutes: 60 }); } catch (e) { console.log(i + ': ' + e.message); } }";
		await client.call("submit", { id: l, text: `/code ${script}` });
		for (let n = 1; n <= MAX_AGENT_SCHEDULES; n++) {
			const ask = await client.until(`the script's call ${n} asks`, () => asked(l));
			await client.call("inbox.decide", { id: ask.id, decision: "once" });
			await client.until(`call ${n} answered`, () => asked(l)?.id !== ask.id);
		}
		await client.until("script finished", () => !client.conversations.get(l)!.state.busy && results(l).length === 1);
		assert.equal(schedulesOf(ledger).length, MAX_AGENT_SCHEDULES);
		assert.ok(schedulesOf(ledger).every((s) => s.createdBy?.agentId === ledger));
		assert.match(results(l)[0]!.text, /21: You already have 20 schedules that you set, the most there can be/);
		assert.equal(asked(l), undefined);
		for (const s of schedulesOf(ledger)) await client.call("schedules.delete", { id: s.id });
		step("selfschedule: too often, too long, already passed and over the cap are refused without asking; a script's calls ask too");

		// It fires: a new conversation with the agent and the prompt. That run's own schedule_task waits for the person.
		const inner = { title: "Again", prompt: "x", repeat: "once", in_minutes: 30 };
		answer = await use(h, "schedule_task", { title: "Fire soon", prompt: `/tool schedule_task ${JSON.stringify(inner)}`, repeat: "once", at: stamp(Date.now() + 10_000) }, () => "once");
		assert.equal(answer.isError, false, answer.text);
		const fired = await client.until("the schedule fires", () => client.library.find((c) => c.title === "Fire soon"), 30_000);
		await client.call("conversation.open", { id: fired.id });
		const nested = await client.until("the scheduled run asks before scheduling", () => asked(fired.id));
		assert.match(nested.question!, /^Herald wants to schedule “Again”: once, on /);
		assert.equal(client.conversations.get(fired.id)!.state.agent.agentId, herald);
		await sleep(400);
		assert.ok(!schedulesOf(herald).some((s) => s.title === "Again"), "nothing is made while no one has answered");
		await client.call("inbox.decide", { id: nested.id, decision: "deny" });
		await client.until("scheduled run finished", () => !client.conversations.get(fired.id)!.state.busy && results(fired.id).length === 1);
		const ran = schedulesOf(herald).find((s) => s.title === "Fire soon");
		assert.deepEqual([ran.lastConversationId, ran.enabled, ran.nextRunAt], [fired.id, false, null], "a one-off turns itself off after its run");
		step("selfschedule: an agent's schedule fires and starts a conversation; that run's own schedule_task waits in the Inbox");

		// The person's edits keep who set it, and the app cannot claim an agent did. Switching off takes the tools away.
		const hourly = schedulesOf(herald).find((s) => s.title === "Hourly check");
		await client.call("schedules.save", { schedule: { id: hourly.id, title: "Hourly build check", agentId: herald, prompt: hourly.prompt, repeat: hourly.repeat, enabled: true } });
		await client.until("edited", () => schedulesOf(herald).find((s) => s.id === hourly.id)?.title === "Hourly build check");
		assert.deepEqual(schedulesOf(herald).find((s) => s.id === hourly.id).createdBy, { agentId: herald, conversationId: h });
		const { id: claimed } = await client.call("schedules.save", { schedule: { title: "Claimed", agentId: herald, prompt: "x", repeat: { kind: "daily", hour: 5, minute: 0 }, createdBy: { agentId: herald, conversationId: h } } });
		await client.until("claimed saved", () => client.schedules.some((s) => s.id === claimed));
		assert.equal(schedulesOf(herald).find((s) => s.id === claimed).createdBy, undefined);
		await client.call("agents.save", { agent: { id: herald, name: "Herald", schedule: { enabled: false } } });
		await client.until("scheduling off", () => (client.agents.find((x) => x.id === herald) as any)?.schedule?.enabled === false);
		answer = await use(h, "list_schedules", {});
		assert.ok(answer.isError && /not available/.test(answer.text), "the tools are taken away at the next message");
		assert.ok(schedulesOf(herald).some((s) => s.id === hourly.id), "the schedules already approved stay until the person deletes them");
		for (const s of schedulesOf(herald)) await client.call("schedules.delete", { id: s.id });
		step("selfschedule: the person's edits keep who set it, and only the engine can mark it; switching off takes the tools away");
	}
	{
		// commands (engine/src/commands.ts): this engine's default limit is 3 seconds (PI2_COMMAND_TIMEOUT_SECONDS)
		const open = async () => {
			const { id } = await client.call("conversation.create");
			await client.call("conversation.open", { id });
			await client.call("conversation.configure", { id, access: "full", cwd: workdir });
			await client.until("full access", () => client.conversations.get(id)?.state.agent.access === "full");
			return id as number;
		};
		const [stopped, longer, input] = [await open(), await open(), await open()];
		const started = Date.now();
		// At once, so the two waits overlap.
		await client.call("submit", { id: stopped, text: "/bash echo begun; sleep 60; echo never-printed" });
		await client.call("submit", { id: longer, text: "/timeout 30 sleep 5; echo finished-late" });
		await client.call("submit", { id: input, text: '/bash cat; read -r answer; echo "got [$answer]"' });
		const [cut, honoured, reader] = await Promise.all([stopped, longer, input].map((id) => settled(id, 1).then(() => toolResults(id)[0]!)));
		assert.equal(cut.isError, true, cut.text);
		assert.ok(cut.text.includes("begun") && !cut.text.includes("never-printed"), `what it wrote before it was stopped is kept: ${cut.text}`);
		assert.match(cut.text, /stopped after 3 seconds, the default time limit for a command\. If it needs longer, run it again with a larger `timeout`/);
		assert.equal(honoured.isError, false, honoured.text);
		assert.ok(honoured.text.includes("finished-late"), `a larger timeout is honoured: ${honoured.text}`);
		assert.equal(reader.isError, false, reader.text);
		assert.ok(reader.text.includes("got []"), `a command reading its input gets none: ${reader.text}`);
		assert.ok(Date.now() - started < 30_000, "the stopped command did not run its full minute");
		step("commands: one without a timeout is stopped at the default and says how to get longer; a larger timeout is honoured; standard input is closed");
	}

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
	// Every one of them may be hidden: unticking all and then picking a few is how a long list is cut down.
	await client.call("providers.setHiddenModels", { id: "groq", hidden: groqIds });
	await client.until("all hidden", () => groq().every((m: any) => m.hidden) && groq().length === groqIds.length);
	await client.call("providers.setHiddenModels", { id: "groq", newest: true });
	// Which of groq's models that hides depends on their names; the rule itself is checked below.
	await client.until("newest only", () => groq().filter((m: any) => !m.hidden).length > 1);
	await client.call("providers.setHiddenModels", { id: "groq", hidden: [] });
	await client.until("all showing", () => groq().every((m: any) => !m.hidden));
	assert.deepEqual([...newestOnly(["claude-opus-4-8", "claude-opus-5", "claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-4-5", "claude-haiku-4-5-20251001", "gpt-4o", "gpt-4o-2024-05-13"])].sort(), ["claude-haiku-4-5", "claude-opus-5-5", "claude-sonnet-5-5", "gpt-4o"]);
	step("models can be hidden per provider, all of them too; newest-only keeps one per family");

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

	// A local server has no key at all; it must still be usable.
	const { id: keyless } = await client.call("endpoints.save", { name: "No Key Box", baseUrl: mockUrl, api: "openai-completions", models: [{ id: "mock-1" }] });
	await client.until("keyless endpoint offered", () => client.models.some((m) => m.provider === keyless));
	const { id: d2 } = await client.call("conversation.create", { model: { provider: keyless, modelId: "mock-1" } });
	await client.call("conversation.open", { id: d2 });
	await client.call("submit", { id: d2, text: "hi, no key" });
	conv = await client.idle(d2);
	assert.equal(conv.state.failure, null, "an endpoint saved without a key answers");
	assert.equal(conv.items.find((i) => i.kind === "assistant")!.text, "Hello from the mock endpoint.");
	await client.call("conversation.configure", { id: d2, model: { provider: "demo", modelId: "demo-1" } });
	await client.until("model switched back", () => client.conversations.get(d2)!.state.agent.model?.provider === "demo");
	await client.call("endpoints.remove", { id: keyless });
	step("an endpoint with no key (Ollama, LM Studio) works");

	await client.call("conversation.configure", { id: d, model: { provider: "demo", modelId: "demo-1" } });
	await client.until("model switched", () => client.conversations.get(d)!.state.agent.model?.provider === "demo");
	await client.call("endpoints.remove", { id: endpointId });
	await client.until("endpoint gone", () => !client.providers.some((p) => p.id === endpointId));
	step("switch a conversation's model; remove the endpoint");

	// ---- The Archive
	{
		const { migrateDeleted, dueForArchive, validateAutoArchive } = await import("../src/archive.ts");
		// Deleting used to set `archived`. Those stay deleted: they must not turn up in the Archive.
		const before: any = { "1": { title: "gone", archived: true }, "2": { title: "kept" }, "3": { title: "stale flag", archived: false } };
		assert.equal(migrateDeleted(before), true);
		assert.deepEqual(before, { "1": { title: "gone", deleted: true }, "2": { title: "kept" }, "3": { title: "stale flag" } });
		assert.equal(migrateDeleted(before as never), false);

		// What goes unused long enough is due; what is recent, working, waiting, or already put away is not.
		const DAY = 86_400_000;
		const now = 100 * DAY;
		const shelf: any = {
			"1": { updatedAt: now - 40 * DAY },
			"2": { updatedAt: now - 5 * DAY },
			"3": { updatedAt: now - 40 * DAY, archivedAt: 1 },
			"4": { updatedAt: now - 40 * DAY, deleted: true },
			"5": { updatedAt: now - 40 * DAY },
			"6": { updatedAt: now - 2 * DAY, parent: 5 },
			"7": { updatedAt: now - 40 * DAY },
			"8": { updatedAt: now - 40 * DAY },
			"9": { updatedAt: now - 40 * DAY, parent: 8 },
		};
		const active = (id: number) => id === 7 || id === 9;
		assert.deepEqual(dueForArchive(shelf, now, 30, active), [1], "a recent sub-chat or one at work keeps its conversation");
		assert.deepEqual(dueForArchive(shelf, now, null, active), []);
		assert.deepEqual(dueForArchive(shelf, now, 1, () => false), [1, 2, 5, 7, 8]);
		assert.equal(validateAutoArchive(null), null);
		assert.equal(validateAutoArchive(30), 30);
		for (const bad of [0, -1, 1.5, "30", 99_999]) assert.throws(() => validateAutoArchive(bad), /whole number of days/);

		// Archived: out of the list, in the Archive, found by search, and closed to new messages.
		const { id: z } = await client.call("conversation.create");
		await client.call("conversation.open", { id: z });
		await client.call("submit", { id: z, text: "remember the word quokka-archive" });
		await client.idle(z);
		await client.call("conversation.archive", { id: z });
		const shelved = await client.until("in the archive", () => (client.library.some((x) => x.id === z) ? undefined : client.archived.find((x) => x.id === z)));
		assert.ok(shelved.archivedAt > 0);
		assert.equal(shelved.subChats, 0);
		await assert.rejects(client.call("submit", { id: z, text: "more" }), /archived/);
		for (const method of ["continue", "conversation.compact", "conversation.reset"]) await assert.rejects(client.call(method, { id: z }), /archived/, method);
		const hit = (await client.call("search", { query: "quokka-archive" })).results.find((r: any) => r.conversationId === z);
		assert.equal(hit?.archived, true, "an archived conversation is still found, and says it is archived");

		// Restored: back in the list and open to messages again.
		await client.call("conversation.unarchive", { id: z });
		await client.until("restored", () => client.library.some((x) => x.id === z) && !client.archived.some((x) => x.id === z));
		await client.call("submit", { id: z, text: "back again" });
		await client.idle(z);

		// Archiving stops what the conversation was waiting for.
		const { id: w } = await client.call("conversation.create");
		await client.call("conversation.configure", { id: w, access: "ask" });
		await client.call("conversation.open", { id: w });
		await client.call("submit", { id: w, text: "/bash echo never-runs" });
		await client.until("an approval waiting", () => client.inbox.find((i) => i.conversationId === w));
		await client.call("conversation.archive", { id: w });
		await client.until("nothing waiting once archived", () => !client.inbox.some((i) => i.conversationId === w) && client.archived.some((x) => x.id === w));

		// A sub-chat goes with the conversation it belongs to, and comes back with it.
		assert.ok(client.library.some((x) => x.id === m) && client.library.some((x) => x.id === childId));
		await assert.rejects(client.call("conversation.archive", { id: childId }), /together with/);
		await client.call("conversation.archive", { id: m });
		const parent = await client.until("parent and sub-chat out of the list", () => (client.library.some((x) => x.id === m || x.id === childId) ? undefined : client.archived.find((x) => x.id === m)));
		assert.ok(parent.subChats >= 1);
		assert.ok(!client.archived.some((x) => x.id === childId), "the Archive lists conversations, not their sub-chats");
		await assert.rejects(client.call("submit", { id: childId, text: "hello" }), /archived/);
		await client.call("conversation.unarchive", { id: m });
		await client.until("parent and sub-chat back", () => client.library.some((x) => x.id === m) && client.library.some((x) => x.id === childId));

		// Deleted: in neither place, not found, and not to be brought back.
		await client.call("conversation.delete", { id: w });
		await client.until("deleted", () => !client.archived.some((x) => x.id === w) && !client.library.some((x) => x.id === w));
		await assert.rejects(client.call("conversation.unarchive", { id: w }), /deleted/);
		await assert.rejects(client.call("conversation.archive", { id: w }), /deleted/);
		await assert.rejects(client.call("submit", { id: w, text: "again" }), /deleted/);
		assert.ok(!(await client.call("search", { query: "never-runs" })).results.some((r: any) => r.conversationId === w));

		// Archiving on its own: the setting is checked, announced, and leaves alone what was used today.
		await assert.rejects(client.call("settings.setAutoArchive", { days: 0 }), /whole number of days/);
		await client.call("settings.setAutoArchive", { days: 30 });
		await client.until("the setting is announced", () => client.autoArchiveDays === 30);
		assert.ok(client.library.some((x) => x.id === z));
		await client.call("settings.setAutoArchive", { days: null });
		await client.until("the setting is off", () => client.autoArchiveDays === null);
		step("archive: out of the list and into the Archive, still searched, closed to messages, restored; sub-chats go with their conversation; delete is separate and final; unused conversations are archived after the days chosen");
	}

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
	for (const folder of scratchFolders) rmSync(folder, { recursive: true, force: true });
}
process.exit(0);
