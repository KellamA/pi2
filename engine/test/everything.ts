// Allow everything (#294): an agent switch under which nothing it does waits for approval and computer use may use any
// app. A real engine on a throwaway data folder, driven over its socket with the demo model, with stand-ins for the
// app's screen and browser, a test MCP server and a throwaway git repository.
//
// With the switch off, every kind of approval is asked exactly as before. With it on, none is. And the bounds hold:
// questions are still asked; pi² itself, terminals and System Settings stay refused; a sub-chat follows its own agent's
// switch, never its parent's; a duplicate does not get it; saving cannot set it; a change counts from each
// conversation's next message, never in the middle of a run; the daily budget and the turn limit still stop work.

import assert from "node:assert/strict";
import { type ChildProcess, execFileSync, spawn } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { EngineClient, standInApp, stop } from "./patience.ts";

const home = mkdtempSync(join(tmpdir(), "pi2-all-"));
const repo = realpathSync(mkdtempSync(join(tmpdir(), "pi2-all-repo-")));
const main = join(import.meta.dirname, "..", "src", "main.ts");
const KEYCHAIN_SERVICE = `dev.pi2.credentials.test-everything-${process.pid}`;
process.env.PI2_DEMO_TOKENS_PER_SECOND ??= "100000";
process.env.PI2_LOGIN_SHELL ??= "off";
// This client turns Allow everything on and answers approvals as the app does (#504).
process.env.PI2_APP_BUNDLE = standInApp();
const env = { ...process.env, PI2_HOME: home, PI2_KEYCHAIN_SERVICE: KEYCHAIN_SERVICE, PI2_DEMO_COST: "5" };

let engine: ChildProcess | undefined;
process.on("exit", () => {
	if (engine !== undefined && engine.exitCode === null && engine.signalCode === null) engine.kill("SIGKILL");
	rmSync(home, { recursive: true, force: true });
	rmSync(repo, { recursive: true, force: true });
	try {
		while (true) execFileSync("/usr/bin/security", ["delete-generic-password", "-s", KEYCHAIN_SERVICE], { stdio: "ignore" });
	} catch {
		// None left.
	}
});

function step(name: string): void {
	console.log(`ok  ${name}`);
}

// One read-only tool and one that changes things, which waits for approval under Ask first.
const MCP_SERVER = `
import { createInterface } from "node:readline";
const reply = (id, result) => process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, result }) + "\\n");
createInterface({ input: process.stdin }).on("line", (line) => {
	const message = JSON.parse(line);
	if (message.method === "initialize") reply(message.id, { protocolVersion: message.params.protocolVersion, capabilities: { tools: {} }, serverInfo: { name: "notes", version: "1" } });
	else if (message.method === "tools/list") reply(message.id, { tools: [{ name: "write_note", description: "Save a note", inputSchema: { type: "object", properties: { text: { type: "string" } } } }] });
	else if (message.method === "tools/call") reply(message.id, { content: [{ type: "text", text: "saved: " + message.params.arguments.text }] });
	else if (message.id !== undefined) reply(message.id, {});
});
`;

const NOTES = "com.example.notes";
const MAIL = "com.example.mail";

class Client extends EngineClient {
	computerRequests: any[] = [];
	browserRequests: any[] = [];

	override receive(message: any): void {
		if (message.event === "computer") {
			this.computerRequests.push(message);
			const reply = message.action === "describe" ? { ok: true, text: `${message.of} in ${message.app}` } : { ok: true, text: `did ${message.action}`, summary: `did ${message.action}` };
			void this.call("computer.result", { requestId: message.requestId, ...reply }).catch(() => {});
		} else if (message.event === "browser") {
			this.browserRequests.push(message);
			const reply = message.action === "describe" ? { ok: true, text: "Click “Send” on example.com", host: "example.com" } : { ok: true, text: `page:${message.action}` };
			void this.call("browser.result", { requestId: message.requestId, ...reply }).catch(() => {});
		} else super.receive(message);
	}

	get inbox(): any[] {
		return this.events.inbox?.items ?? [];
	}
	agent(id: string): any {
		return this.events.agents?.agents?.find((x: any) => x.id === id);
	}
	meta(id: number): any {
		return this.events.library?.conversations?.find((x: any) => x.id === id);
	}
	tools(id: number): any[] {
		return (this.conversations.get(id)?.items ?? []).filter((item: any) => item.kind === "tool");
	}
}

execFileSync("git", ["init", "-q", "-b", "main"], { cwd: repo });
writeFileSync(join(repo, "notes.txt"), "first\n");
execFileSync("git", ["add", "."], { cwd: repo });
execFileSync("git", ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-q", "-m", "start"], { cwd: repo });
const serverPath = join(home, "mcp-server.mjs");
writeFileSync(serverPath, MCP_SERVER);

engine = spawn(process.execPath, [main], { env, stdio: ["ignore", "ignore", "inherit"] });
const client = await Client.connect(engine, home);
try {
	await client.until("agents", () => client.events.agents);
	await client.call("computer.register");
	await client.call("browser.register");
	const { id: server } = await client.call("mcp.save", { name: "Notes", transport: "stdio", command: process.execPath, args: [serverPath] });
	const mcp = await client.until("the MCP server", () => client.events.mcp?.servers?.find((x: any) => x.id === server && x.status === "connected"));
	const noteTool = mcp.tools[0].toolName as string;

	const settings = { access: "ask", cwd: repo, computer: { enabled: true, apps: [NOTES] }, browser: { enabled: true }, schedule: { enabled: true }, mcpServers: [server], codeMode: true };
	const save = async (agent: Record<string, unknown>): Promise<string> => {
		const { id } = await client.call("agents.save", { agent });
		await client.until(
			`agent ${String(agent.name)}`,
			() =>
				client.agent(id)?.name === agent.name &&
				JSON.stringify(client.agent(id)?.delegates ?? []) === JSON.stringify(agent.delegates ?? []) &&
				(agent.description === undefined || client.agent(id)?.description === agent.description),
		);
		return id;
	};
	const careful = await save({ name: "Careful", ...settings });
	const bold = await save({ name: "Bold", ...settings, delegates: [careful] });
	await save({ id: careful, name: "Careful", ...settings, delegates: [bold] });
	const allow = async (agent: string, on: boolean) => {
		await client.call("agents.allowEverything", { id: agent, on });
		await client.until(`allow everything ${on ? "on" : "off"}`, () => (client.agent(agent)?.allowEverything === true) === on);
	};
	const conversationOf = async (agentId: string): Promise<number> => {
		const { id } = await client.call("conversation.create", { agentId });
		await client.call("conversation.open", { id });
		return id;
	};

	/**
	 * Sends `text` to conversation `id` and waits until its run is over, answering `answer` to each approval it (or a
	 * sub-chat of it) waits on. Resolves with the approvals that were asked, in order.
	 */
	const run = async (id: number, text: string, answer = "once"): Promise<any[]> => {
		const asked: any[] = [];
		const assistants = () => (client.conversations.get(id)?.items ?? []).filter((item: any) => item.kind === "assistant").length;
		const before = assistants();
		await client.call("submit", { id, text });
		await client.until(`the run of “${text}”`, () => {
			for (const item of client.inbox) {
				if (item.rootConversationId !== id || asked.some((seen) => seen.id === item.id)) continue;
				asked.push(item);
				if (item.kind === "question") void client.call("inbox.answer", { id: item.id, text: "blue" });
				else void client.call("inbox.decide", { id: item.id, decision: answer });
			}
			const conv = client.conversations.get(id);
			return conv !== undefined && !conv.state.busy && assistants() > before && !client.inbox.some((item) => item.rootConversationId === id);
		});
		return asked;
	};
	const last = (id: number) => client.tools(id).at(-1);

	// Every kind of approval there is: a command, a file written, a file changed, a document, a tool of an MCP server,
	// computer use, the browser, a worktree for a sub-chat, and a schedule the agent sets itself.
	let n = 0;
	const kinds = (): [string, string][] => {
		n++;
		return [
			["bash", "/bash echo ran"],
			["write", `/tool write ${JSON.stringify({ path: `file-${n}.txt`, content: "hello" })}`],
			["edit", `/tool edit ${JSON.stringify({ path: `file-${n}.txt`, edits: [{ oldText: "hello", newText: "changed" }] })}`],
			["write_document", `/tool write_document ${JSON.stringify({ path: `doc-${n}.html`, markdown: "# Doc" })}`],
			[noteTool, `/mcp ${noteTool} {"text":"x"}`],
			["computer", `/computer ${JSON.stringify({ action: "click", app: NOTES, element: 1 })}`],
			["browser", `/browser ${JSON.stringify({ action: "click", element: 2 })}`],
			["delegate", `/tool delegate ${JSON.stringify({ agent: "Careful", task: "Say hello.", worktree: `wt-${n}` })}`],
			["schedule_task", `/tool schedule_task ${JSON.stringify({ title: `Later ${n}`, prompt: "Check.", repeat: "once", in_minutes: 600 })}`],
		];
	};

	// ---- Off: nothing changes. Each kind waits for the person, once, as it always has.
	const off = await conversationOf(bold);
	for (const [tool, text] of kinds()) {
		const asked = await run(off, text);
		assert.deepEqual(asked.map((item) => [item.kind, item.tool]), [["approval", tool]], `off: ${tool} is asked about`);
		assert.equal(last(off).isError, false, `off: ${tool} ran once allowed: ${last(off).text}`);
		assert.equal(last(off).details?.allowedByEverything, undefined, `off: ${tool} was allowed by the person`);
	}
	assert.equal(readFileSync(join(repo, "file-1.txt"), "utf8"), "changed");
	// Computer use keeps to the listed apps, and browsers stay look-only; nothing is asked about either.
	assert.match((await run(off, `/computer ${JSON.stringify({ action: "click", app: MAIL, element: 1 })}`), last(off)).text, /may not use/);
	assert.match((await run(off, `/computer ${JSON.stringify({ action: "screenshot", app: "com.apple.Safari" })}`), last(off)).text, /may not use/);
	assert.ok(client.computerRequests.every((r) => r.anyApp === undefined), "the app is never told an agent that is off may use any app");
	// A command that reaches its time limit is stopped, not moved to the background, where starting it would ask.
	const slow = await run(off, "/timeout 1 while true; do sleep 1; done");
	assert.equal(slow.length, 1);
	assert.match(last(off).text, /not moved to the background/);
	assert.equal(client.meta(off).allowEverything, false);
	step("off: every kind of approval is asked, once; only listed apps; a command at its limit is stopped");

	// ---- Saving cannot turn it on; only its own request can, and saving keeps it.
	await client.call("agents.save", { agent: { id: careful, name: "Careful", ...settings, delegates: [bold], allowEverything: true } });
	await client.call("agents.save", { agent: { name: "Sneaky", ...settings, allowEverything: true } });
	const sneaky = await client.until("Sneaky", () => client.events.agents.agents.find((x: any) => x.name === "Sneaky"));
	assert.ok(client.agent(careful).allowEverything === undefined && sneaky.allowEverything === undefined, "agents.save never sets it");
	await assert.rejects(client.call("agents.allowEverything", { id: bold, on: "yes" }), /true or false/);
	await assert.rejects(client.call("agents.allowEverything", { id: "nobody", on: true }), /Unknown agent/);
	await allow(bold, true);
	await save({ id: bold, name: "Bold", ...settings, description: "Saved again", delegates: [careful] });
	assert.equal(client.agent(bold).allowEverything, true, "saving the agent keeps it");
	step("only agents.allowEverything sets it; saving neither sets nor clears it");

	// ---- On: none of them is asked about, and each did what it does.
	assert.equal(client.meta(off).allowEverything, false, "a conversation takes it at its next message, not before");
	const on = await conversationOf(bold);
	for (const [tool, text] of kinds()) {
		const asked = await run(on, text);
		assert.deepEqual(asked, [], `on: ${tool} is not asked about`);
		assert.equal(last(on).isError, false, `on: ${tool} ran: ${last(on).text}`);
		assert.equal(last(on).details?.allowedByEverything, true, `on: ${tool} records why it ran unasked`);
	}
	assert.equal(client.meta(on).allowEverything, true);
	assert.equal(readFileSync(join(repo, `file-${n}.txt`), "utf8"), "changed", "the file was written and changed");
	assert.ok(existsSync(join(repo, `doc-${n}.html`)));
	assert.ok(client.events.schedules.schedules.some((s: any) => s.title === `Later ${n}`), "the schedule was set");
	assert.ok(execFileSync("git", ["branch", "--list", `wt-${n}`], { cwd: repo, encoding: "utf8" }).includes(`wt-${n}`), "the worktree was made");
	assert.ok(client.browserRequests.some((r) => r.action === "click" && r.conversationId === on && r.expect === "Click “Send” on example.com"), "the browser still acts only on what it described");
	// The conversation that was off takes it at its next message.
	assert.deepEqual(await run(off, "/bash echo now"), []);
	assert.equal(client.meta(off).allowEverything, true);
	assert.deepEqual(await run(on, "/bash exit 127"), []);
	assert.equal(last(on).isError, true);
	assert.equal(last(on).details?.allowedByEverything, true, "a command that ran but failed still went unasked");
	await client.call("rules.add", { agentId: bold, folder: repo, command: "echo covered" });
	assert.deepEqual(await run(on, "/bash echo covered"), []);
	assert.deepEqual(last(on).details?.allowedBy, ["echo covered"]);
	assert.equal(last(on).details?.allowedByEverything, undefined, "a rule would have let it run anyway");
	step("on: no kind of approval is asked; calls record the switch only when it took the place of an approval");

	// ---- On: computer use may use any app but those that stay refused, and the app is told so.
	const use = async (args: Record<string, unknown>) => {
		assert.deepEqual(await run(on, `/computer ${JSON.stringify(args)}`), [], `nothing is asked: ${JSON.stringify(args)}`);
		return last(on);
	};
	for (const app of [MAIL, "com.apple.Safari", "com.google.Chrome"]) {
		const done = await use({ action: "click", app, element: 1 });
		assert.ok(!done.isError && client.computerRequests.some((r) => r.action === "click" && r.app === app && r.anyApp === true), `${app}: ${done.text}`);
	}
	assert.equal(client.computerRequests.filter((r) => r.action === "list_apps").length, 0);
	assert.ok(!(await use({ action: "list_apps" })).isError && client.computerRequests.at(-1).anyApp === true && JSON.stringify(client.computerRequests.at(-1).apps) === JSON.stringify([NOTES]));
	assert.equal(last(on).details?.allowedByEverything, undefined, "looking never asks");
	const refused: [string, Record<string, unknown>, RegExp][] = [
		["pi² itself", { action: "screenshot", app: "dev.pi2.app" }, /cannot be used/],
		["a copy of pi²", { action: "click", app: "dev.pi2.app.test", element: 1 }, /only be looked at/],
		["a terminal", { action: "screenshot", app: "com.apple.Terminal" }, /cannot be used/],
		["a password manager", { action: "screenshot", app: "com.1password.1password" }, /cannot be used/],
		["System Settings", { action: "click", app: "com.apple.systempreferences", element: 1 }, /only be looked at/],
	];
	for (const [what, args, reason] of refused) {
		const sent = client.computerRequests.length;
		const result = await use(args);
		assert.ok(result.isError && reason.test(result.text), `${what} stays refused: ${result.text}`);
		assert.ok(client.computerRequests.slice(sent).every((r) => r.action !== "click" && r.action !== "screenshot"), `${what}: nothing reaches the app`);
	}
	step("on: computer use may use any app and control browsers; pi², its copies, terminals, password managers and System Settings stay as they were");

	// ---- On: a question is still a question, and a command at its limit is moved to the background without asking.
	const question = await run(on, "/ask Which colour?");
	assert.deepEqual(question.map((item) => item.kind), ["question"], "ask_user still asks");
	assert.equal(last(on).details?.allowedByEverything, undefined, "a question is not an approval");
	assert.deepEqual(await run(on, "/timeout 1 while true; do sleep 1; done"), []);
	assert.match(last(on).text, /moved to the background/);
	step("on: questions are still asked; a command at its limit is moved to the background, as one that would not ask");

	// ---- Sub-chats follow their own agent's switch, never the parent's.
	const handed = await run(on, "/delegate Careful: /bash echo from-careful");
	assert.deepEqual(handed.map((item) => item.tool), ["bash"], "Bold handing work to Careful does not pass it on");
	const sub = client.events.library.conversations.find((x: any) => x.parent === on && x.allowEverything === false && x.agentId === careful);
	assert.ok(sub !== undefined, "the sub-chat does not have it");
	const carefulConv = await conversationOf(careful);
	assert.deepEqual(await run(carefulConv, "/delegate Bold: /bash echo from-bold"), [], "Careful handing work to Bold: Bold's sub-chat has its own");
	assert.ok(client.events.library.conversations.some((x: any) => x.parent === carefulConv && x.agentId === bold && x.allowEverything === true));
	assert.deepEqual((await run(carefulConv, "/bash echo careful")).map((item) => item.tool), ["bash"], "and the parent still asks");
	step("a sub-chat follows its own agent's switch, never its parent's, either way");

	// ---- A duplicate does not get it.
	const { id: copy } = await client.call("agents.duplicate", { id: bold });
	const copied = await client.until("the copy", () => client.agent(copy));
	assert.equal(copied.allowEverything, undefined, "the copy is off");
	assert.equal(client.agent(bold).allowEverything, true, "the original keeps it");
	assert.deepEqual((await run(await conversationOf(copy), "/bash echo copy")).map((item) => item.tool), ["bash"], "the copy's conversations ask");
	step("duplicating an agent does not carry the switch to the copy");

	// ---- A change counts from each conversation's next message, never in the middle of a run, both ways. The calls of
	// one answer are all judged before the first runs, so the two commands are run by a script, each judged as it is called.
	const gate = join(repo, "gate");
	const started = join(repo, "started");
	const twoCommands = `/code await tools.bash({ command: ${JSON.stringify(`touch ${started}; while [ ! -f ${gate} ]; do sleep 0.1; done; echo first`)} }); await tools.bash({ command: "echo second" });`;
	const midRun = async (id: number, turnTo: boolean) => {
		rmSync(gate, { force: true });
		rmSync(started, { force: true });
		const asked: any[] = [];
		const results = client.tools(id).length;
		await client.call("submit", { id, text: twoCommands });
		const waiting = () => client.inbox.find((item) => item.conversationId === id && !asked.some((seen) => seen.id === item.id));
		// Off at the start (to be turned on): the first command asks; it is allowed, and runs until the gate opens.
		if (turnTo) {
			const first = await client.until("the first command's approval", waiting);
			asked.push(first);
			await client.call("inbox.decide", { id: first.id, decision: "once" });
		}
		await client.until("the first command running", () => existsSync(started));
		await allow(bold, turnTo);
		writeFileSync(gate, "");
		await client.until("both commands ended", () => {
			const item = waiting();
			if (item !== undefined) {
				asked.push(item);
				void client.call("inbox.decide", { id: item.id, decision: "once" });
			}
			const conv = client.conversations.get(id);
			return conv !== undefined && !conv.state.busy && client.tools(id).length === results + 1;
		});
		assert.match(last(id).text, /second/, `both commands ran: ${last(id).text}`);
		return asked.length;
	};
	const flip = await conversationOf(bold);
	await allow(bold, false);
	await run(flip, "/bash echo off at first");
	assert.equal(await midRun(flip, true), 2, "turned on in the middle of a run: the rest of that run still asks");
	assert.equal(client.meta(flip).allowEverything, false);
	await run(flip, "/bash echo on now");
	assert.equal(client.meta(flip).allowEverything, true);
	assert.equal(await midRun(flip, false), 0, "turned off in the middle of a run: the rest of that run does not ask");
	assert.equal(client.meta(flip).allowEverything, true, "until the next message");
	assert.deepEqual((await run(flip, "/bash echo off now")).map((item) => item.tool), ["bash"]);
	assert.equal(client.meta(flip).allowEverything, false);
	step("turning it on or off counts from each conversation's next message, both ways");

	// ---- The daily budget and the turn limit still hold.
	await allow(bold, true);
	await client.call("usage.setBudget", { daily: 0.000001 });
	await client.until("over budget", () => client.events.usage?.overBudget === true);
	await assert.rejects(client.call("submit", { id: on, text: "/bash echo spent" }), /budget/);
	await client.call("usage.setBudget", { daily: null });
	await client.until("budget off", () => client.events.usage?.overBudget === false);
	const limited = await save({ name: "Limited", ...settings, maxTurns: 1 });
	await allow(limited, true);
	const short = await conversationOf(limited);
	await client.call("submit", { id: short, text: "/bash echo one turn" });
	const stopped = await client.until("the turn limit", () => client.conversations.get(short)?.state.failure ?? undefined);
	assert.equal(stopped.reason, "turn_limit");
	assert.deepEqual(client.inbox.filter((item) => item.rootConversationId === short), []);
	step("on: a used-up daily budget refuses new work, and the turn limit stops a run");

	// The mark belongs to the call, not to the current switch. Check the reopened transcript and both exports.
	await allow(bold, false);
	const mark = client.tools(on).find((item) => item.name === "bash").callId;
	client.close();
	await stop(engine);
	engine = spawn(process.execPath, [main], { env, stdio: ["ignore", "ignore", "inherit"] });
	const reopened = await Client.connect(engine, home);
	try {
		await reopened.call("conversation.open", { id: on });
		const kept = await reopened.until("the marked result after restart", () => reopened.tools(on).find((item) => item.callId === mark));
		assert.equal(kept.details?.allowedByEverything, true);
		const json = JSON.parse((await reopened.call("conversation.export", { id: on, format: "json" })).text);
		assert.equal(json.items.find((item: any) => item.kind === "tool" && item.callId === mark).details?.allowedByEverything, true);
		const { text: markdown } = await reopened.call("conversation.export", { id: on, format: "markdown" });
		assert.match(markdown, /\*\*Tool: bash\*\*\n\n\*Allowed by Allow everything\.\*/);
		const { text: noMark } = await reopened.call("conversation.export", { id: carefulConv, format: "markdown" });
		assert.doesNotMatch(noMark, /Allowed by Allow everything\./);
	} finally {
		reopened.close();
	}
	step("the mark stays with the call across a restart and in JSON and Markdown exports");
} finally {
	client.close();
	await stop(engine);
}
