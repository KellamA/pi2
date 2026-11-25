// The settings that widen an agent's reach are the person's alone (#513). Since #504 a connection that is not the app's
// cannot answer what waits for the person; the requests that change settings were still taken from any connection, so a
// command an agent runs could widen its own reach through the socket without answering anything. Here a stand-in app
// bundle's `pi2-peer` takes for the app only the processes this test names, finding the one at the other end of the
// connection it is given with lsof, as engine/test/answers.ts does: what is checked is the engine, which requests it
// holds back, what it says, and that the app's own connection keeps making every one of them. The same test checks that
// every handler the engine has is named by one of the three lists in src/answers.ts, so a request added later without
// being classed is caught here. macOS only, for lsof's way of naming sockets.

import assert from "node:assert/strict";
import { type ChildProcess, execFileSync, spawn } from "node:child_process";
import { mkdtempSync, openSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { checkRequestClasses, ONLY_IN_THE_APP, SETTINGS_ONLY_IN_THE_APP } from "../src/answers.ts";
import { socketPathFor } from "../src/socket.ts";
import { EngineClient, standInApp, stop } from "./patience.ts";

process.env.PI2_LOGIN_SHELL ??= "off";
const home = mkdtempSync(join(tmpdir(), "pi2-reach-"));
const work = realpathSync(mkdtempSync(join(tmpdir(), "pi2-reach-work-")));
const main = join(import.meta.dirname, "..", "src", "main.ts");
const KEYCHAIN_SERVICE = `dev.pi2.credentials.test-reach-${process.pid}`;

// The processes the stand-in takes for the app, one process id a line; the test names only itself, so a connection from
// any other process (a command an agent runs, a script) is not the app's.
const apps = join(work, "apps");
const name = (pids: number[]) => writeFileSync(apps, pids.map((pid) => `${pid}\n`).join(""));
name([process.pid]);
// Descriptor 3 is the connection. lsof gives its own address ("d…"); a process holding the other end has a socket
// whose peer ("n->…") is that address.
const bundle = standInApp(`#!/bin/sh
own=$(/usr/sbin/lsof -a -p $$ -d 3 -U -F d 2>/dev/null | sed -n 's/^d//p' | head -n 1)
for pid in $(cat '${apps}'); do
	if [ -n "$own" ] && /usr/sbin/lsof -a -p "$pid" -U -F n 2>/dev/null | grep -qx "n->$own"; then
		echo '{"app":true,"why":"process '"$pid"' is a stand-in app"}'
		exit 0
	fi
done
echo '{"app":false,"why":"the process at the other end is not one this test named"}'
`);
// Keep start-up diagnostics so a failure before the socket opens can name the bad classification.
const engineLog = join(work, "engine.log");
const env = { ...process.env, PI2_HOME: home, PI2_KEYCHAIN_SERVICE: KEYCHAIN_SERVICE, PI2_APP_BUNDLE: bundle };

// A client in a process of its own: requests as JSON lines on its input, replies (not events) on its output. Given a
// method and its parameters instead, it sends that one request, prints the reply and ends, as a command an agent would.
const elsewhere = join(work, "elsewhere.mjs");
writeFileSync(
	elsewhere,
	`import { connect } from "node:net";
import { createInterface } from "node:readline";
const [path, method, params] = process.argv.slice(2);
const socket = connect(path);
createInterface({ input: socket }).on("line", (line) => {
	const message = JSON.parse(line);
	if (message.event !== undefined || message.id === undefined) return;
	console.log(JSON.stringify(message));
	if (method !== undefined) socket.end();
});
if (method !== undefined) socket.once("connect", () => socket.write(JSON.stringify({ id: 1, method, params: JSON.parse(params) }) + "\\n"));
else createInterface({ input: process.stdin }).on("line", (line) => socket.write(line + "\\n")).on("close", () => socket.end());
`,
);

let engine: ChildProcess | undefined;
const others: ChildProcess[] = [];
process.on("exit", () => {
	for (const child of [engine, ...others]) if (child !== undefined && child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
	rmSync(home, { recursive: true, force: true });
	rmSync(work, { recursive: true, force: true });
	try {
		while (true) execFileSync("/usr/bin/security", ["delete-generic-password", "-s", KEYCHAIN_SERVICE], { stdio: "ignore" });
	} catch {
		// None left.
	}
});

function step(text: string): void {
	console.log(`ok  ${text}`);
}

/** A connection from another process than this test's: a command, or a script driving the socket. */
class Elsewhere {
	readonly child: ChildProcess;
	#next = 1;
	#waiting = new Map<number, (reply: { result?: any; error?: string }) => void>();

	constructor() {
		this.child = spawn(process.execPath, [elsewhere, socketPathFor(home)], { stdio: ["pipe", "pipe", "inherit"] });
		others.push(this.child);
		createInterface({ input: this.child.stdout! }).on("line", (line) => {
			const reply = JSON.parse(line);
			this.#waiting.get(reply.id)?.(reply);
			this.#waiting.delete(reply.id);
		});
	}

	/** The reply, error or result, as it came. */
	call(method: string, params: Record<string, unknown> = {}): Promise<{ result?: any; error?: string }> {
		const id = this.#next++;
		const reply = new Promise<{ result?: any; error?: string }>((resolve) => this.#waiting.set(id, resolve));
		this.child.stdin!.write(`${JSON.stringify({ id, method, params })}\n`);
		return reply;
	}

	close(): void {
		this.child.stdin!.end();
	}
}

class Client extends EngineClient {
	get agents(): any[] {
		return this.events.agents?.agents ?? [];
	}

	/** A conversation's tool access, as the conversation event tells the app (stateOf in main.ts). */
	accessOf(id: number): string | undefined {
		return this.conversations.get(id)?.state?.agent?.access;
	}
}

const logFile = openSync(engineLog, "a");
const classes = [new Set(["answer"]), new Set(["setting"]), new Set(["open"])];
assert.doesNotThrow(() => checkRequestClasses(["answer", "setting", "open"], classes));
assert.throws(() => checkRequestClasses(["new.feature"], classes), /new\.feature belongs to 0 request classes/);
assert.throws(() => checkRequestClasses(["open"], [...classes, new Set(["open"])]), /open belongs to 2 request classes/);
step("registration fails if a handler has zero or two request classes");
const start = (environment: NodeJS.ProcessEnv = env) => spawn(process.execPath, [main], { env: environment, stdio: ["ignore", "ignore", logFile] });
engine = start();
const app = await Client.connect(engine, home).catch((error) => {
	throw new Error(`${error.message}\n${readFileSync(engineLog, "utf8")}`);
});
try {
	await app.until("agents", () => app.agents.length > 0);
	const { id: asked } = await app.call("conversation.create", { agentId: "forge" });
	await app.call("conversation.open", { id: asked });
	await app.call("conversation.configure", { id: asked, access: "ask", cwd: work });

	// ---- A connection that is not the app's cannot change what widens reach
	const other = new Elsewhere();
	assert.deepEqual(await other.call("connection.mayAnswer"), { id: 1, result: { mayAnswer: false, why: "the process at the other end is not one this test named" } });
	const forge = () => app.agents.find((agent: any) => agent.id === "forge");
	// Each of these is taken today; each must be refused, with the error an agent reads, and change nothing.
	for (const [method, params, changed] of [
		["agents.save", { agent: { id: "forge", name: "Forge", access: "full" } }, "the agent's access"],
		["conversation.configure", { id: asked, access: "full" }, "the conversation's access"],
		["rules.add", { agentId: "forge", folder: work, command: "npm test" }, "an allowed command"],
		["variables.set", { agentId: "forge", name: "TOKEN", value: "secret-reach" }, "a variable"],
		["mcp.save", { name: "Reach", transport: "http", url: "http://127.0.0.1:1/" }, "an MCP server"],
		["schedules.save", { schedule: { title: "Reach", agentId: "forge", prompt: "Run everything", repeat: { kind: "daily", hour: 9, minute: 0 } } }, "a schedule"],
	] as const) {
		const reply = await other.call(method, params as Record<string, unknown>);
		assert.equal(reply.error, SETTINGS_ONLY_IN_THE_APP, `${method}, which changes ${changed}: ${JSON.stringify(reply)}`);
	}
	assert.notEqual(forge()?.access, "full", "the agent's access was not widened");
	assert.deepEqual(forge()?.commandRules ?? [], [], "no allowed command was added");
	assert.deepEqual(forge()?.variables ?? [], [], "no variable was added");
	assert.notEqual(app.accessOf(asked), "full", "the conversation's access was not widened");
	assert.deepEqual(app.events.mcp?.servers ?? [], [], "no MCP server was added");
	assert.deepEqual(app.events.schedules?.schedules ?? [], [], "no schedule was added");
	// Refused before the request is looked at, so it says nothing about whether the agent or folder exists.
	assert.equal((await other.call("rules.add", { agentId: "no-such-agent" })).error, SETTINGS_ONLY_IN_THE_APP, "it is refused before the request is looked at");
	for (const method of ["conversation.carryOn", "conversation.fork", "work.create", "work.act", "auth.cancel", "backup.create", "endpoints.probe", "mcp.reconnect", "recovery.dismiss", "limits.dismiss", "local.download.pause", "local.download.resume", "local.download.cancel"]) {
		assert.equal((await other.call(method)).error, SETTINGS_ONLY_IN_THE_APP, method);
	}
	// Presenting's (#963): the app's host role and the person's network switch, refused before the stub that answers them.
	for (const method of ["present.register", "present.drawn", "presented.network"]) assert.equal((await other.call(method, { allow: false })).error, SETTINGS_ONLY_IN_THE_APP, method);
	for (const method of ["presented.list", "presented.picture", "presented.file"]) assert.equal((await other.call(method)).error, "Presenting is not available yet.", `${method} is open to any`);
	for (const method of ["test-copy.answerer", "test-copy.fill", "test-copy.fillProject", "not-a-request"]) {
		assert.equal((await other.call(method)).error, `Unknown method: ${method}`);
	}
	const demo = { provider: "demo", modelId: "demo-1" };
	assert.equal((await other.call("chat.continueWithAgent", { id: asked, cwd: work })).error, SETTINGS_ONLY_IN_THE_APP);
	assert.equal((await other.call("chat.continueWithAgent", { id: asked, confirmLimit: "a-reading" })).error, ONLY_IN_THE_APP);
	assert.equal((await other.call("conversation.retry", { id: asked, model: demo })).error, SETTINGS_ONLY_IN_THE_APP);
	assert.match((await other.call("conversation.retry", { id: asked })).error ?? "", /for chats only/);
	// The default model for agents (#617): every agent with none of its own starts on it, so it is the person's alone.
	assert.equal((await other.call("settings.setAgentDefault", { model: demo })).error, SETTINGS_ONLY_IN_THE_APP);
	assert.equal(JSON.parse(readFileSync(join(home, "settings.json"), "utf8")).agentDefault, undefined, "no default for agents was chosen");

	// Selectors for a new conversation are still open; they belong only to that conversation, not the app's defaults.
	const readSettings = () => JSON.parse(readFileSync(join(home, "settings.json"), "utf8"));
	const before = readSettings();
	const plain = await other.call("conversation.create", { agentId: "scout", model: demo });
	assert.equal(typeof plain.result?.id, "number");
	const chat = await other.call("conversation.create", { chat: true, model: demo });
	assert.equal(typeof chat.result?.id, "number");
	assert.deepEqual(readSettings().lastChatModel, before.lastChatModel);
	await app.call("conversation.create", { chat: true, model: demo });
	assert.deepEqual(readSettings().lastChatModel, demo);
	assert.equal(typeof (await other.call("submit", { id: chat.result.id, text: "Hello from the test" })).result?.submissionId, "number");
	// Reading and messaging still work from any connection.
	assert.equal(typeof (await other.call("search", { query: "nothing at all" })).result?.results, "object", "everything else works as before");
	step("a connection that is not the app's cannot widen an agent's reach, and everything else works");

	// ---- The app's connection makes every one of those changes
	const saved = await app.call("agents.save", { agent: { id: "forge", name: "Forge", access: "full" } });
	assert.equal(saved.id, "forge");
	await app.until("the agent's access changed", () => forge()?.access === "full");
	await app.call("conversation.configure", { id: asked, access: "full" });
	await app.until("the conversation's access changed", () => app.accessOf(asked) === "full");
	await app.call("rules.add", { agentId: "forge", folder: work, command: "npm test" });
	await app.until("an allowed command was added", () => (forge()?.commandRules ?? []).some((rule: any) => (rule.words ?? []).join(" ") === "npm test"));
	await app.call("variables.set", { agentId: "forge", name: "TOKEN", value: "secret-reach" });
	await app.until("a variable was added", () => (forge()?.variables ?? []).some((variable: any) => variable.name === "TOKEN"));
	const server = await app.call("mcp.save", { name: "Reach", transport: "http", url: "http://127.0.0.1:1/" });
	await app.until("an MCP server was added", () => (app.events.mcp?.servers ?? []).some((listed: any) => listed.id === server.id));
	assert.deepEqual((await app.call("settings.setAgentDefault", { model: demo })).model, demo);
	const schedule = await app.call("schedules.save", { schedule: { title: "Reach", agentId: "forge", prompt: "Run everything", repeat: { kind: "daily", hour: 9, minute: 0 } } });
	await app.until("a schedule was added", () => (app.events.schedules?.schedules ?? []).some((listed: any) => listed.id === schedule.id));
	other.close();
	step("the app's connection makes every one of those changes");

	step("the engine listened after checking all of its registered request classes");
} finally {
	app.close();
	await stop(engine);
}
