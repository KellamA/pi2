// Who may answer for the person (#504): only the app. A real engine on a throwaway data folder, with the scripted demo
// model. What tells the app from anything else is the app bundle's `pi2-peer` (PeerKit, checked on real code
// signatures by app/Sources/pi2-peer-check); here a stand-in bundle's `pi2-peer` takes for the app only the processes
// this test names, finding the one at the other end of the connection it is given with lsof, as
// app/check-release-build.mts does. So what is checked here is the engine: which requests it holds back, from which
// connections, what it says, and that a restart, a second app and an agent's own command are each judged anew.
// macOS only, for lsof's way of naming sockets.

import assert from "node:assert/strict";
import { type ChildProcess, execFileSync, spawn } from "node:child_process";
import { mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { ONLY_IN_THE_APP } from "../src/answers.ts";
import { socketPathFor } from "../src/socket.ts";
import { EngineClient, standInApp, stop } from "./patience.ts";

process.env.PI2_DEMO_TOKENS_PER_SECOND ??= "100000";
process.env.PI2_LOGIN_SHELL ??= "off";
const home = mkdtempSync(join(tmpdir(), "pi2-answers-"));
const work = realpathSync(mkdtempSync(join(tmpdir(), "pi2-answers-work-")));
const main = join(import.meta.dirname, "..", "src", "main.ts");
const KEYCHAIN_SERVICE = `dev.pi2.credentials.test-answers-${process.pid}`;

// The processes the stand-in takes for the app, one process id a line; the test changes it as it goes.
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
const env = { ...process.env, PI2_HOME: home, PI2_KEYCHAIN_SERVICE: KEYCHAIN_SERVICE, PI2_APP_BUNDLE: bundle };

// A client in a process of its own: requests as JSON lines on its input, replies (not events) on its output. Given a
// method and its parameters instead, it sends that one request, prints the reply and ends, as an agent's command would.
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

/** A connection from another process than this test's: a command, or a second app once it is named. */
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

	get pid(): number {
		return this.child.pid!;
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
	get inbox(): any[] {
		return this.events.inbox?.items ?? [];
	}

	tools(id: number): any[] {
		return this.conversations.get(id)?.items.filter((item: any) => item.kind === "tool") ?? [];
	}

	/** Waits for the approval of a command in conversation `id`. */
	approval(id: number): Promise<any> {
		return this.until(`an approval in conversation ${id}`, () => this.inbox.find((item) => item.conversationId === id && item.kind === "approval"));
	}

	/** Waits until conversation `id` is idle with `count` tool results. */
	settled(id: number, count: number): Promise<any[]> {
		return this.until(`${count} tool result(s) in conversation ${id}`, () => {
			const conv = this.conversations.get(id);
			return conv !== undefined && !conv.state.busy && this.tools(id).length === count && this.tools(id);
		});
	}
}

const start = (environment: NodeJS.ProcessEnv = env) => spawn(process.execPath, [main], { env: environment, stdio: ["ignore", "ignore", "inherit"] });
engine = start();
let app = await Client.connect(engine, home);
try {
	await app.until("agents", () => app.events.agents?.agents?.length > 0);
	const { id: asked } = await app.call("conversation.create", { agentId: "forge" });
	await app.call("conversation.open", { id: asked });
	await app.call("conversation.configure", { id: asked, access: "ask", cwd: work });

	// ---- An ordinary connection, from another process
	await app.call("submit", { id: asked, text: "/bash echo first" });
	let approval = await app.approval(asked);
	const other = new Elsewhere();
	assert.deepEqual(await other.call("connection.mayAnswer"), { id: 1, result: { mayAnswer: false, why: "the process at the other end is not one this test named" } });
	for (const [method, params] of [
		["inbox.decide", { id: approval.id, decision: "once" }],
		["inbox.decide", { id: approval.id, decision: "always" }],
		["inbox.decide", { id: approval.id, decision: "deny" }],
		["inbox.answer", { id: approval.id, text: "yes" }],
		["auth.answer", { promptId: "prompt-1", value: "a code" }],
		["agents.allowEverything", { id: "forge", on: true }],
	] as const) {
		const reply = await other.call(method, params);
		assert.equal(reply.error, ONLY_IN_THE_APP, `${method} ${JSON.stringify(params)}: ${JSON.stringify(reply)}`);
	}
	assert.ok(app.inbox.some((item) => item.id === approval.id), "the approval still waits");
	assert.equal(app.tools(asked).length, 0, "and nothing ran");
	assert.notEqual(app.events.agents.agents.find((agent: any) => agent.id === "forge").allowEverything, true, "Allow everything stayed off");
	assert.ok(!(await other.call("agents.allowEverything", { id: "forge", on: false })).error, "turning Allow everything off is not held back");
	const created = await other.call("conversation.create", { agentId: "scout" });
	assert.equal(typeof created.result?.id, "number", "everything else works as before");
	assert.ok((await other.call("inbox.decide", { id: "no-such-request", decision: "sideways" })).error === ONLY_IN_THE_APP, "it is refused before the request is looked at");
	step("a connection from another process cannot answer an approval, a question or a sign-in, nor turn on Allow everything; everything else works");

	// ---- The app can
	assert.deepEqual(await app.call("connection.mayAnswer"), { mayAnswer: true, why: `process ${process.pid} is a stand-in app` });
	await app.call("inbox.decide", { id: approval.id, decision: "once" });
	assert.ok((await app.settled(asked, 1))[0].text.includes("first"));
	await app.call("submit", { id: asked, text: "/ask Which colour?" });
	const question = await app.until("a question", () => app.inbox.find((item) => item.conversationId === asked && item.kind === "question"));
	assert.equal((await other.call("inbox.answer", { id: question.id, text: "red" })).error, ONLY_IN_THE_APP);
	await app.call("inbox.answer", { id: question.id, text: "blue" });
	assert.equal((await app.settled(asked, 2))[1].text, "blue");
	step("the app's connection answers approvals and questions");

	// ---- A need that waits while the agent carries on
	await app.call("projects.setPreview", { on: true });
	const { id: project, conversation: orchestrator } = await app.call("projects.create", { folder: work });
	await app.call("conversation.open", { id: orchestrator });
	await app.call("submit", { id: orchestrator, text: '/tool needs_you {"action":"ask","question":"Which branch?"}' });
	const need = await app.until("a stored question under Needs you", () => app.events.needs?.items.find((item: any) => item.projectId === project && item.kind === "question" && !item.blocking));
	await app.settled(orchestrator, 1);
	const answer = { id: need.id, answer: { kind: "question", text: "main" } };
	assert.equal((await other.call("needs.answer", answer)).error, ONLY_IN_THE_APP);
	assert.ok((await app.call("needs.list", { projectId: project })).items.some((item: any) => item.id === need.id), "the need still waits");
	assert.deepEqual(await app.call("needs.answer", answer), {});
	assert.deepEqual(await app.call("needs.list", { projectId: project }), { items: [] });
	step("only the app's connection can answer a stored need");

	// ---- A command an agent runs
	const { id: runner } = await app.call("conversation.create", { agentId: "atlas" });
	await app.call("conversation.open", { id: runner });
	await app.call("conversation.configure", { id: runner, access: "full", cwd: work });
	await app.call("submit", { id: asked, text: "/bash echo second" });
	approval = await app.approval(asked);
	const params = JSON.stringify({ id: approval.id, decision: "once" });
	await app.call("submit", { id: runner, text: `/bash '${process.execPath}' '${elsewhere}' '${socketPathFor(home)}' inbox.decide '${params}'` });
	const [tried] = await app.settled(runner, 1);
	assert.ok(tried.text.includes(JSON.stringify(ONLY_IN_THE_APP)), `the command was refused, and told why: ${tried.text}`);
	assert.ok(app.inbox.some((item) => item.id === approval.id) && app.tools(asked).length === 2, "the approval still waits, and the command it is for has not run");
	step("a command an agent runs cannot answer another conversation's approval, and is told to ask the person");

	// ---- Two apps
	const second = new Elsewhere();
	name([process.pid, second.pid]);
	assert.equal((await second.call("connection.mayAnswer")).result.mayAnswer, true);
	assert.equal((await other.call("connection.mayAnswer")).result.mayAnswer, false, "a connection already judged stays judged");
	assert.deepEqual(await second.call("inbox.decide", { id: approval.id, decision: "once" }), { id: 2, result: {} });
	assert.ok((await app.settled(asked, 3))[2].text.includes("second"));
	second.close();
	step("a second app answers too; each connection is judged by its own process");

	// ---- A restart of the engine, with the app still open
	await app.call("submit", { id: asked, text: "/bash echo third" });
	const before = await app.approval(asked);
	await stop(engine, "SIGKILL");
	other.close();
	engine = start();
	app = await Client.connect(engine, home);
	await app.call("conversation.open", { id: asked });
	approval = await app.approval(asked);
	assert.equal(approval.callId, before.callId, "the same call is asked about again");
	const after = new Elsewhere();
	assert.equal((await after.call("inbox.decide", { id: approval.id, decision: "once" })).error, ONLY_IN_THE_APP, "an ordinary connection is still refused");
	after.close();
	assert.equal((await app.call("connection.mayAnswer")).mayAnswer, true);
	await app.call("inbox.decide", { id: approval.id, decision: "once" });
	assert.ok((await app.settled(asked, 4))[3].text.includes("third"));
	step("after the engine restarts, the app's new connection answers and others are still refused");

	// ---- An engine that cannot tell: nobody answers
	await app.call("submit", { id: asked, text: "/bash echo fourth" });
	await app.approval(asked);
	app.close();
	await stop(engine);
	const { PI2_APP_BUNDLE: _, ...unknowing } = env;
	engine = start(unknowing);
	app = await Client.connect(engine, home);
	await app.call("conversation.open", { id: asked });
	approval = await app.approval(asked);
	assert.deepEqual(await app.call("connection.mayAnswer"), { mayAnswer: false, why: "this engine does not know which app it belongs to" });
	await assert.rejects(app.call("inbox.decide", { id: approval.id, decision: "deny" }), (error: Error) => error.message === ONLY_IN_THE_APP);
	step("an engine that does not know its app takes no answer from anyone");
} finally {
	app.close();
	await stop(engine);
}
