// Computer use asks before an action that changes something, in every conversation of an agent: a plain one, and a
// project's sub-chat made by `work` `assign`, worktree and all (#1069). The app's side of computer use is stood in for
// by this test's own connection, as engine.ts does.

import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { mkdirSync, mkdtempSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { EngineClient, standInApp, stop } from "./patience.ts";

process.env.PI2_LOGIN_SHELL ??= "off";
process.env.PI2_DEMO_TOKENS_PER_SECOND ??= "100000";
// This client answers for the app, so that it may be asked approvals and told to do the computer's work (#504).
process.env.PI2_APP_BUNDLE = standInApp();

const home = mkdtempSync(join(tmpdir(), "pi2-computerask-"));
const repos = realpathSync(mkdtempSync(join(tmpdir(), "pi2-computerask-repos-")));
const service = `dev.pi2.credentials.test-computerask-${process.pid}`;
const start = () => spawn(process.execPath, [join(import.meta.dirname, "../src/main.ts")], { env: { ...process.env, PI2_HOME: home, PI2_KEYCHAIN_SERVICE: service }, stdio: ["ignore", "ignore", "inherit"] });
const engine = start();
process.on("exit", () => {
	if (engine.exitCode === null && engine.signalCode === null) engine.kill("SIGKILL");
	rmSync(home, { recursive: true, force: true });
	rmSync(repos, { recursive: true, force: true });
	try {
		while (true) execFileSync("/usr/bin/security", ["delete-generic-password", "-s", service], { stdio: "ignore" });
	} catch {
		/* None left. */
	}
});

/** A throwaway test copy of pi²: an app an agent with test copies on may act in. */
const COPY = "dev.pi2.app.test-1";

type Item = { kind: string; name?: string; isError?: boolean; text?: string; details?: any };
type Approval = { id: string; kind: string; conversationId: number; tool: string; question: string | null };
class Client extends EngineClient {
	inbox: Approval[] = [];
	agents: any[] = [];
	library: { id: number; title: string; parent?: number | null; agentId?: string }[] = [];
	/** As the app does for computer use: what the engine asked this client to do on screen, and how it answers. */
	computerRequests: any[] = [];
	computerReply: ((request: any) => Record<string, unknown> | undefined) | undefined;
	/** The same for the browser, whose pages this client stands in for. */
	browserRequests: any[] = [];
	browserReply: ((request: any) => Record<string, unknown> | undefined) | undefined;

	override receive(message: any): void {
		if (message.event === "inbox") this.inbox = message.items;
		else if (message.event === "agents") this.agents = message.agents;
		else if (message.event === "library") this.library = message.conversations;
		else if (message.event === "computer") {
			this.computerRequests.push(message);
			const reply = this.computerReply?.(message);
			if (reply !== undefined) void this.call("computer.result", { requestId: message.requestId, ...reply }).catch(() => {});
		} else if (message.event === "browser") {
			this.browserRequests.push(message);
			const reply = this.browserReply?.(message);
			if (reply !== undefined) void this.call("browser.result", { requestId: message.requestId, ...reply }).catch(() => {});
		} else super.receive(message);
	}

	items(id: number): Item[] {
		return (this.conversations.get(id)?.items ?? []) as Item[];
	}

	tools(id: number): Item[] {
		return this.items(id).filter((item) => item.kind === "tool");
	}

	/** Send a message and wait for its run to end, giving the last tool call it made. */
	async run(id: number, text: string): Promise<Item> {
		const before = this.tools(id).length;
		await this.call("submit", { id, text });
		await this.until(`the run in ${id}`, () => {
			const conv = this.conversations.get(id);
			return conv !== undefined && !conv.state.busy && this.tools(id).length > before ? conv : undefined;
		});
		return this.tools(id).at(-1)!;
	}

	/** An approval waiting for the person, in conversation `id`. */
	waits(id: number): Approval | undefined {
		return this.inbox.find((item) => item.kind === "approval" && item.conversationId === id);
	}

	acted(action: string, app = COPY): any[] {
		return this.computerRequests.filter((request) => request.action === action && request.app === app);
	}
}

let client: Client | undefined;
const step = (text: string) => console.log(`ok  ${text}`);

try {
	client = await Client.connect(engine, home);
	client.computerReply = (request) => {
		if (request.action === "describe") return { ok: true, text: "Click the “Now” button in pi² test-1" };
		if (request.action === "click") return { ok: true, text: "Clicked the “Now” button at that point.", summary: "Clicked “Now”" };
		if (request.action === "open_app") return { ok: true, text: "pi² test-1 was already open.", summary: "Opened pi² test-1" };
		return { ok: true, text: "ok" };
	};
	await client.call("computer.register");

	// ---- The project and its agent: computer use on, test copies allowed, asking before each action, Allow everything off
	const repo = join(repos, "widgets");
	mkdirSync(repo);
	const git = (...args: string[]) => execFileSync("git", ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", ...args], { cwd: repo, stdio: "pipe" }).toString().trim();
	git("init", "-q", "-b", "main");
	git("commit", "-q", "--allow-empty", "-m", "first");
	const { id: projectId, conversation: parent }: { id: string; conversation: number } = await client.call("projects.create", { folder: repo, name: "Screen" });
	const { id: hand } = await client.call("projects.addAgent", {
		projectId,
		agent: {
			name: "Hand",
			access: "full",
			model: { provider: "demo", modelId: "demo-1" },
			// Its own setting gives each conversation a worktree, so `work` `assign` gives its sub-chat one without asking (#604).
			worktree: true,
			computer: { enabled: true, apps: [], ask: true, testCopies: true },
		},
	});
	await client.call("conversation.open", { id: parent });
	await client.until("the orchestrator's conversation", () => client!.conversations.get(parent)?.state);
	const stored = (): any => {
		const agent = client!.agents.find((one) => one.id === hand);
		assert.ok(agent !== undefined, "the agent is stored");
		return agent;
	};
	assert.deepEqual(stored().computer, { enabled: true, apps: [], ask: true, testCopies: true }, "the agent asks before each action, and no app is listed");
	assert.notEqual(stored().allowEverything, true, "Allow everything is off");

	// ---- A plain conversation of the agent: an action that changes something waits for the person
	const { id: plain } = await client.call("conversation.create", { agentId: hand });
	await client.call("conversation.open", { id: plain });
	await client.until("the plain conversation", () => client!.conversations.get(plain)?.state);
	const denied = client.run(plain, `/computer ${JSON.stringify({ action: "click", app: COPY, element: 3 })}`);
	const plainApproval = (await client.until("an approval for the click", () => client!.waits(plain)))!;
	assert.match(plainApproval.question ?? "", /Click the “Now” button/, "the approval says what will be clicked, in words");
	assert.equal(client.acted("click").length, 0, "nothing is clicked before the person answers");
	await client.call("inbox.decide", { id: plainApproval.id, decision: "deny" });
	assert.equal((await denied).isError, true, "a denied action is refused");
	assert.equal(client.acted("click").length, 0, "and never reaches the app");
	step("a plain conversation of the agent asks before an action that changes something, and Deny blocks it");

	// ---- The same agent's sub-chat, made by `work` `assign` with a worktree of its own
	const { id: item } = await client.call("work.create", { projectId, title: "Check the screen", text: "The window is open." });
	const assigning = client.run(parent, `/tool work ${JSON.stringify({ action: "assign", id: item, agent: "Hand", task: `/computer ${JSON.stringify({ action: "open_app", app: COPY })}` })}`);
	const subApproval = (await client.until("an approval in the sub-chat", () => client!.inbox.find((entry) => entry.kind === "approval" && entry.tool === "computer" && entry.conversationId !== plain && entry.conversationId !== parent)))!;
	assert.equal(client.acted("open_app").length, 0, "the sub-chat's app is not opened before the person answers");
	await client.call("inbox.decide", { id: subApproval.id, decision: "once" });
	const assigned = await assigning;
	assert.equal(assigned.isError, false, assigned.text ?? "");
	const child = assigned.details?.conversationId as number;
	assert.equal(subApproval.conversationId, child, "the approval was the sub-chat's own");
	assert.equal(client.acted("open_app").length, 1, "once answered, the app is opened");
	assert.equal(client.library.find((conv) => conv.id === child)?.parent, parent, "the sub-chat is the parent's");
	await client.call("conversation.open", { id: child });
	await client.until("the sub-chat", () => client!.conversations.get(child)?.state);
	step("a sub-chat made by work assign, with a worktree, asks before it opens an app, and the app is opened once allowed");

	// ---- The same sub-chat, a click at a point and a click by number
	const point = client.run(child, `/computer ${JSON.stringify({ action: "click", app: COPY, x: 10, y: 20 })}`);
	const pointApproval = (await client.until("an approval for the click at a point", () => client!.waits(child)))!;
	assert.equal(client.acted("click").length, 0, "nothing is clicked before the person answers");
	await client.call("inbox.decide", { id: pointApproval.id, decision: "deny" });
	assert.equal((await point).isError, true, "a denied click at a point is refused");
	assert.equal(client.acted("click").length, 0, "and never reaches the app");
	const byNumber = client.run(child, `/computer ${JSON.stringify({ action: "click", app: COPY, element: 3 })}`);
	const numberApproval = (await client.until("an approval for the click by number", () => client!.waits(child)))!;
	assert.match(numberApproval.question ?? "", /Click the “Now” button/, "the sub-chat's approval says what will be clicked");
	await client.call("inbox.decide", { id: numberApproval.id, decision: "once" });
	assert.equal((await byNumber).isError, false, "an allowed click runs");
	assert.equal(client.acted("click").length, 1, "and reaches the app");
	step("in the sub-chat, a click at a point and a click by number each wait for the person, and Deny blocks the one denied");

	// ---- Another agent of the project, under Ask first: a command and a browser action in its sub-chat ask too
	const { id: writer } = await client.call("projects.addAgent", {
		projectId,
		agent: { name: "Writer", access: "ask", model: { provider: "demo", modelId: "demo-1" }, browser: { enabled: true, ask: true } },
	});
	const { id: other } = await client.call("work.create", { projectId, title: "Check the page", text: "Read it first." });
	const commanded = client.run(parent, `/tool work ${JSON.stringify({ action: "assign", id: other, agent: "Writer", task: "/bash echo hello" })}`);
	const commandApproval = (await client.until("an approval for a command", () => client!.inbox.find((entry) => entry.kind === "approval" && entry.tool === "bash")))!;
	await client.call("inbox.decide", { id: commandApproval.id, decision: "deny" });
	const commandDone = await commanded;
	assert.equal(commandDone.isError, false, commandDone.text ?? "");
	const written = commandDone.details?.conversationId as number;
	assert.equal(commandApproval.conversationId, written, "the approval was the writer's sub-chat's");
	assert.equal(client.library.find((conv) => conv.id === written)?.parent, parent, "a sub-chat of the parent's");
	assert.equal(client.agents.find((one) => one.id === writer)?.access, "ask", "the writer is under Ask first");
	await client.call("conversation.open", { id: written });
	await client.until("the writer's sub-chat", () => client!.conversations.get(written)?.state);
	assert.equal(client.tools(written).at(-1)?.isError, true, "a denied command is refused");
	client.browserReply = (request) => (request.action === "describe" ? { ok: true, text: "Click “Submit” on example.com", host: "example.com" } : { ok: true, text: "Clicked “Submit”.", summary: "Clicked “Submit”" });
	await client.call("browser.register");
	const browsing = client.run(written, `/browser ${JSON.stringify({ action: "click", element: 4 })}`);
	const browserApproval = (await client.until("an approval for the page", () => client!.inbox.find((entry) => entry.kind === "approval" && entry.tool === "browser")))!;
	assert.equal(client.browserRequests.filter((request) => request.action === "click").length, 0, "nothing is clicked in the page before the person answers");
	await client.call("inbox.decide", { id: browserApproval.id, decision: "deny" });
	assert.equal((await browsing).isError, true, "a denied page action is refused");
	assert.equal(client.browserRequests.filter((request) => request.action === "click").length, 0, "and never reaches the page");
	step("under Ask first, a command and a browser action in a sub-chat each wait for the person, and Deny blocks them");

	// ---- The agent removed and restored through the project's tools, and then changed by them: it still asks
	const agents = (args: Record<string, unknown>) => client!.run(parent, `/tool project_agents ${JSON.stringify(args)}`);
	// Its ask switch turned off first, which the person allows: that is what the report's agent had had done before.
	const widened = await agents({ action: "change", agent: "Hand", settings: { computer: { ask: false } }, why: "To check the switch" });
	assert.match(widened.text ?? "", /put to the person as n\d+/, "turning ask off is put to the person");
	await client.call("needs.answer", { id: widened.details?.need, answer: { kind: "reach", allow: true } });
	await client.until("the switch off", () => stored().computer?.ask === false);
	await agents({ action: "remove", agent: "Hand" });
	await client.until("the agent removed", () => stored().removedAt !== undefined);
	await agents({ action: "restore", agent: "Hand" });
	await client.until("the agent restored", () => stored().removedAt === undefined);
	const narrowed = await agents({ action: "change", agent: "Hand", settings: { computer: { ask: true } } });
	assert.equal(narrowed.isError, false, narrowed.text ?? "");
	await client.until("the switch on", () => stored().computer?.ask === true);
	// A conversation that existed all along, not only one made after: its next call asks.
	const after = client.run(plain, `/computer ${JSON.stringify({ action: "click", app: COPY, element: 4 })}`);
	const afterApproval = (await client.until("an approval after the change", () => client!.waits(plain)))!;
	assert.equal(client.acted("click").length, 1, "nothing is clicked while that approval waits");
	await client.call("inbox.decide", { id: afterApproval.id, decision: "once" });
	assert.equal((await after).isError, false, "the allowed click runs");
	assert.equal(client.acted("click").length, 2, "and reaches the app");
	step("an agent removed, restored and changed by the project's tools asks again at the next call in a conversation that already existed");

	// ---- The one route that answers with nothing shown: Allow everything, which `Inbox.ask` turns into "once" at once.
	// By design (#294), and worth seeing: it is what a call let through unnoticed looks like from the engine's side.
	await client.call("agents.allowEverything", { id: hand, on: true });
	await client.until("Allow everything on", () => stored().allowEverything === true);
	// A message puts the switch on the conversation (`takeAgentSwitch`); the call it makes is then not asked about.
	const allowed = await client.run(plain, `/computer ${JSON.stringify({ action: "click", app: COPY, element: 5 })}`);
	assert.equal(allowed.isError, false, allowed.text ?? "");
	assert.equal(client.inbox.length, 0, "with Allow everything on for the conversation, nothing waits for the person");
	assert.equal(client.acted("click").length, 3, "the click reached the app with no card shown");
	assert.equal(allowed.details?.allowedByEverything, true, "the call's card says why it was not asked about");
	await client.call("agents.allowEverything", { id: hand, on: false });
	await client.until("Allow everything off", () => stored().allowEverything !== true);
	step("with Allow everything on for the conversation, a click is not asked about at all; that is the only route that lets one through with nothing shown");
} finally {
	client?.close();
	await stop(engine);
}
