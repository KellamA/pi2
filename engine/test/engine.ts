// End-to-end checks of the engine over its socket, on a throwaway data folder and a throwaway Keychain service.

import assert from "node:assert/strict";
import { type ChildProcess, execFileSync, spawn } from "node:child_process";
import { existsSync, mkdtempSync, readdirSync, readFileSync, realpathSync, rmSync, statSync } from "node:fs";
import { createServer } from "node:http";
import { connect, type Socket } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";

const home = mkdtempSync(join(tmpdir(), "pi2-test-"));
const workdir = realpathSync(mkdtempSync(join(tmpdir(), "pi2-work-")));
const socketPath = join(home, "engine.sock");
const main = join(import.meta.dirname, "..", "src", "main.ts");
const KEYCHAIN_SERVICE = "dev.pi2.credentials.test";

type Item = { id: number; kind: string; text: string; callId?: string; name?: string; isError?: boolean; stop?: string; details?: any; toolCalls?: { callId: string; name: string }[] };
type InboxItem = { id: string; kind: string; conversationId: number; rootConversationId: number; tool: string; question: string | null; agentName: string | null; callId: string };
type State = { busy: boolean; partial: { text: string } | null; failure: { reason: string } | null; queued: { id: number; text: string }[]; agent: { model: { provider: string; modelId: string } | null; access: string; cwd: string | null; agentId: string | null; parent: number | null }; tools: { name: string; status: string }[] };
type Conv = { items: Item[]; state: State };

function startEngine(): ChildProcess {
	return spawn(process.execPath, [main], { env: { ...process.env, PI2_HOME: home, PI2_KEYCHAIN_SERVICE: KEYCHAIN_SERVICE }, stdio: ["ignore", "ignore", "inherit"] });
}

class Client {
	socket!: Socket;
	conversations = new Map<number, Conv>();
	library: { id: number; title: string; busy: boolean }[] = [];
	agents: { id: string; name: string; access: string; delegates: string[] }[] = [];
	inbox: InboxItem[] = [];
	activity: { conversationId: number; rootConversationId: number; status: string }[] = [];
	schedules: { id: string; title: string; enabled: boolean; nextRunAt: number | null; lastConversationId: number | null; pending: unknown }[] = [];
	recovery: { at: number; conversations: { id: number }[] } | null | undefined;
	providers: { id: string; kind: string; status: unknown; oauth: { subscription: boolean } | null }[] = [];
	models: { provider: string; id: string }[] = [];
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
		else if (message.event === "providers") {
			this.providers = message.providers;
			this.models = message.models;
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
	assert.ok(!client.library.some((x) => x.id === childId), "subagent conversations stay out of the sidebar");
	await client.call("conversation.open", { id: childId });
	const child = await client.until("child transcript", () => client.conversations.get(childId));
	assert.equal(child.state.agent.agentId, "scout");
	assert.equal(child.state.agent.parent, m);
	assert.equal(child.items[0]!.text, "say hi to the team");
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

	await client.call("conversation.archive", { id: d });
	await client.until("archived", () => !client.library.some((x) => x.id === d));
	step("archive a conversation");
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
