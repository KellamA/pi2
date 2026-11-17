// Commands left running in the background (src/background.ts): a real engine on a throwaway data folder, driven over
// its socket with the demo model. Starting, reading, listing and stopping; what bounds the output; approvals and command
// rules, in worktrees too; what stops a command (the agent, the person, archiving, deleting, removing its worktree, a
// time limit its call gave, the engine stopping) and what an engine does with one an engine that died left running.

import assert from "node:assert/strict";
import { type ChildProcess, execFileSync, spawn } from "node:child_process";
import { chmodSync, closeSync, existsSync, mkdirSync, mkdtempSync, openSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";
import { backgroundMarker, backgroundMarkerDetails, commandLine, elapsed, MAX_WAIT_SECONDS } from "../src/background.ts";
import { EngineClient, exited, PATIENT_MS, running, stop, until } from "./patience.ts";

// Commits made here use a fixed identity and none of the person's own git settings.
process.env.GIT_CONFIG_GLOBAL = "/dev/null";
process.env.GIT_CONFIG_NOSYSTEM = "1";
Object.assign(process.env, { GIT_AUTHOR_NAME: "Test", GIT_AUTHOR_EMAIL: "test@example.invalid", GIT_COMMITTER_NAME: "Test", GIT_COMMITTER_EMAIL: "test@example.invalid" });

const home = mkdtempSync(join(tmpdir(), "pi2-bg-"));
const scratch = realpathSync(mkdtempSync(join(tmpdir(), "pi2-bg-work-")));
const main = join(import.meta.dirname, "..", "src", "main.ts");
process.env.PI2_DEMO_TOKENS_PER_SECOND ??= "1000";
process.env.PI2_LOGIN_SHELL ??= "off";
// A command that is waited for is stopped after two seconds here, so one in the background visibly outlives the limit.
// A request from the app for a command's output may wait for longer than this test waits for anything, so that an answer
// to one can only have come because there was output, or because the command ended: never because the wait ran out.
const OUTPUT_WAIT_SECONDS = (2 * PATIENT_MS) / 1000;
const env = {
	...process.env,
	PI2_HOME: home,
	PI2_KEYCHAIN_SERVICE: "dev.pi2.credentials.test-background",
	PI2_COMMAND_TIMEOUT_SECONDS: "2",
	PI2_OUTPUT_WAIT_SECONDS: String(OUTPUT_WAIT_SECONDS),
};
/** What the engines write, as the app's engine.log has it. A file, so that a line written just before an engine exits is not lost, as it can be in a pipe. */
const engineLog = join(home, "engine.log");

function step(name: string): void {
	console.log(`ok  ${name}`);
}

// ---- Words, without the engine

assert.equal(elapsed(4_200), "4 seconds");
assert.equal(elapsed(1_000), "1 second");
assert.equal(elapsed(125_000), "2 minutes");
assert.equal(elapsed(2 * 3_600_000 + 5 * 60_000), "2 hours 5 minutes");
assert.equal(elapsed(3 * 3_600_000), "3 hours");
assert.equal(commandLine("npm run dev\n  -- --port 3000"), "npm run dev -- --port 3000");
assert.equal(commandLine("x".repeat(200)).length, 121);
assert.equal(backgroundMarker({ id: "bg-2", command: "npm run dev", how: "exited with code 1" }), "Background command bg-2 exited with code 1: npm run dev");
assert.equal(backgroundMarker(null), "Background command ended", "an entry this engine cannot read still says something");
assert.deepEqual(backgroundMarkerDetails({ id: "bg-2", command: "npm run dev", how: "exited with code 1" }), { background: { id: "bg-2" } });
for (const data of [null, {}, { id: 2 }, { id: "bg-0" }, { id: "x" }, { id: "bg-2 " }]) assert.equal(backgroundMarkerDetails(data), undefined, JSON.stringify(data));
step("durations, commands on one line and the transcript's line read as expected");

// ---- The engine

type Event = Record<string, any>;
class Client extends EngineClient {
	/** Connected to `engine` once it listens, and once it has sent what it sends every app that connects. */
	static async attach(engine: ChildProcess): Promise<Client> {
		const client = await Client.connect(engine, home);
		await client.until("first events", () => client.events.providers && client.events.background);
		return client;
	}
	items(id: number, kind: string): Event[] {
		return this.conversations.get(id)?.items.filter((item: Event) => item.kind === kind) ?? [];
	}
	markers(id: number): string[] {
		return this.items(id, "marker").map((item) => item.text as string);
	}
	inbox(): Event[] {
		return this.events.inbox?.items ?? [];
	}
	/** The commands the engine says are running, as Activity lists them. */
	running(): Event[] {
		return this.events.background?.commands ?? [];
	}
	/** Whether the answer to the call that made result number `count` is in, and the run over. */
	#answered(id: number, count: number): Event | undefined {
		const conv = this.conversations.get(id);
		if (conv === undefined || conv.state.busy) return undefined;
		const results = conv.items.filter((item: Event) => item.kind === "tool");
		if (results.length < count) return undefined;
		const result = results[count - 1];
		const after = conv.items.slice(conv.items.indexOf(result) + 1);
		return after.some((item: Event) => item.kind === "assistant") ? result : undefined;
	}
	/** Sends a message the demo model answers with a tool call, and returns that call's result once the answer is in. */
	async tool(id: number, text: string): Promise<Event> {
		const count = this.items(id, "tool").length + 1;
		await this.call("submit", { id, text });
		return await this.until(`result of ${text}`, () => this.#answered(id, count));
	}
	/** The same, answering the approval with `decision` if there is one. Says what was asked, or null. */
	async attempt(id: number, text: string, decision = "deny"): Promise<{ asked: Event | null; result: Event }> {
		const count = this.items(id, "tool").length + 1;
		await this.call("submit", { id, text });
		const asked = await this.until(`${text}: approval or result`, () => this.inbox().find((item) => item.conversationId === id) ?? (this.items(id, "tool").length >= count ? "none" : undefined));
		if (asked !== "none") await this.call("inbox.decide", { id: (asked as Event).id, decision });
		const result = await this.until(`${text}: settled`, () => this.#answered(id, count));
		return { asked: asked === "none" ? null : (asked as Event), result };
	}
	/** Starts a command in the background; returns the call's result and the command's id. */
	async start(id: number, command: string): Promise<{ result: Event; bg: string }> {
		const result = await this.tool(id, `/background ${command}`);
		assert.equal(typeof result.details?.background?.id, "string", `the call says which command it started: ${JSON.stringify(result)}`);
		return { result, bg: result.details.background.id };
	}
	/**
	 * Starts a command that ends at once, and returns the call that saw it end. The call waits about a second for that; on
	 * a machine busy enough for the command to take longer, it is started again until one does.
	 */
	async startOver(id: number, command: string): Promise<{ result: Event; bg: string }> {
		for (const deadline = Date.now() + PATIENT_MS; ; ) {
			const started = await this.start(id, command);
			if (started.result.details.background.status === "ended") return started;
			assert.ok(Date.now() < deadline, `the call that starts a command that ends at once says so: ${started.result.text}`);
			await this.until("that one over too", () => this.markers(id).some((text) => text.includes(`${started.bg} `)));
		}
	}
	/** What a running command has printed, from the call that started it on, once it includes `needle`. */
	async printed(id: number, started: { result: Event; bg: string }, needle: string): Promise<string> {
		let text = started.result.text as string;
		for (const deadline = Date.now() + PATIENT_MS; !text.includes(needle); ) {
			assert.ok(Date.now() < deadline, `${started.bg} printed ${needle}: ${text}`);
			text += (await this.background(id, { action: "read", id: started.bg, wait: 5 })).text;
		}
		return text;
	}
	/** Calls the `background` tool. */
	background(id: number, args: Record<string, unknown>): Promise<Event> {
		return this.tool(id, `/tool background ${JSON.stringify(args)}`);
	}
	/** What the agent is told about its background commands. */
	async told(id: number): Promise<string> {
		const answers = this.items(id, "assistant").length;
		await this.call("submit", { id, text: "/system" });
		const conv = await this.until("system prompt", () => {
			const c = this.conversations.get(id);
			return c !== undefined && !c.state.busy && this.items(id, "assistant").length > answers ? c : undefined;
		});
		const text = this.items(id, "assistant").at(-1)!.text as string;
		assert.ok(text.startsWith("SYSTEM PROMPT"), text);
		void conv;
		return text;
	}
}

const alive = (pid: number) => {
	try {
		process.kill(pid, 0);
		return true;
	} catch {
		return false;
	}
};
/**
 * How long the commands here that only a stop should end would run: twice as long as any wait, so that a wait for one
 * to be stopped cannot be met by its ending by itself.
 */
const LONG = `sleep ${(2 * PATIENT_MS) / 1000}`;
/** The same for node, whose environment macOS lets another process read. */
const LONG_WAIT = `setTimeout(() => {}, ${2 * PATIENT_MS})`;
/** Every process a command here writes its number down for, so that none outlives the test whatever fails. */
const started: number[] = [];
let files = 0;
/** A command that notes its own process and one it starts, then waits: `[command, file of the first, file of the second]`. */
function lingering(): [string, string, string] {
	const leader = join(scratch, `leader-${++files}.pid`);
	const child = join(scratch, `child-${files}.pid`);
	return [`${LONG} & echo $! > '${child}'; echo $$ > '${leader}'; echo up; wait`, leader, child];
}
/**
 * The same, but what it starts ignores SIGTERM, so a stop ends the command's own process at once and leaves the rest in
 * its group until the SIGKILL that follows: what a busy Mac can make of any stop, made certain (#168).
 */
function stubborn(): [string, string, string] {
	const leader = join(scratch, `leader-${++files}.pid`);
	const child = join(scratch, `child-${files}.pid`);
	return [`trap '' TERM; ${LONG} & echo $! > '${child}'; trap - TERM; echo $$ > '${leader}'; echo up; wait`, leader, child];
}
/**
 * A command none of whose processes heeds SIGTERM: only the SIGKILL that follows ends it, so whatever stops it has to
 * give up on it by a bound of its own.
 */
function deaf(): [string, string, string] {
	const leader = join(scratch, `leader-${++files}.pid`);
	const child = join(scratch, `child-${files}.pid`);
	return [`trap '' TERM; ${LONG} & echo $! > '${child}'; echo $$ > '${leader}'; echo up; wait`, leader, child];
}
/** Waits for an answer that should come, but fails rather than wait past the test's patience. */
async function answered<T>(what: string, pending: Promise<T>): Promise<T> {
	let timer: ReturnType<typeof setTimeout> | undefined;
	const late = new Promise<never>((_, reject) => (timer = setTimeout(() => reject(new Error(`Timed out waiting for: ${what}`)), PATIENT_MS)));
	try {
		return await Promise.race([pending, late]);
	} finally {
		clearTimeout(timer);
	}
}
/** The process a command wrote down in `file`, once it has. */
const pidIn = async (file: string): Promise<number> => {
	await until(`${file} to be written`, () => existsSync(file) && readFileSync(file, "utf8").trim() !== "");
	const pid = Number(readFileSync(file, "utf8").trim());
	assert.ok(pid > 1, `${file}: ${pid}`);
	started.push(pid);
	return pid;
};

const run = (cwd: string, ...args: string[]) => execFileSync("git", args, { cwd, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();
function repo(name: string): string {
	const dir = join(scratch, name);
	mkdirSync(dir, { recursive: true });
	run(dir, "init", "-q", "-b", "main");
	// A stand-in for a server: says it is up, then stays.
	writeFileSync(join(dir, "serve"), `#!/bin/sh\necho "serving in $(pwd -P)"\nexec ${LONG}\n`);
	chmodSync(join(dir, "serve"), 0o755);
	run(dir, "add", ".");
	run(dir, "commit", "-q", "-m", "first");
	return dir;
}

const work = join(scratch, "work");
mkdirSync(work);
const boot = () => {
	const log = openSync(engineLog, "a");
	try {
		return spawn(process.execPath, [main], { env, stdio: ["ignore", "ignore", log] });
	} finally {
		closeSync(log);
	}
};
/** What the engines this test started have logged, line by line. */
const logged = (): string[] => (existsSync(engineLog) ? readFileSync(engineLog, "utf8").split("\n") : []);
/** Waits for engine.log to have a line that ends with `text`, after the line's time and the engine's tag. */
const logs = (text: string) => until(`engine.log to say: ${text}`, () => logged().some((line) => /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ \[pi2-engine\] /.test(line) && line.endsWith(text)));
let passed = false;
let engine: ChildProcess = boot();
try {
	let client = await Client.attach(engine);
	const save = async (agent: Record<string, unknown>): Promise<string> => (await client.call("agents.save", { agent })).id;
	const open = async (agentId: string, cwd?: string): Promise<number> => {
		const { id } = await client.call("conversation.create", { agentId });
		await client.call("conversation.open", { id });
		if (cwd !== undefined) await client.call("conversation.configure", { id, cwd });
		await client.until("conversation open", () => client.conversations.get(id)?.state.agent.cwd !== undefined && (cwd === undefined || client.conversations.get(id)?.state.agent.cwd === cwd));
		return id;
	};
	const worker = await save({ name: "Worker", access: "full", cwd: work });
	assert.deepEqual(client.running(), [], "nothing runs in the background at first");

	// ---- Start, read, list, stop
	const a = await open(worker);
	const gate = join(scratch, "gate");
	const [command, leaderFile, childFile] = lingering();
	const startedAt = Date.now();
	// The command cannot end before `gate` is made, which this test does only further down: a call that waited for it would
	// never come back.
	const first = await client.start(a, `echo early; ${command.replace("echo up; wait", `while [ ! -e '${gate}' ]; do sleep 0.1; done; echo late; wait`)}`);
	assert.equal(first.bg, "bg-1");
	assert.equal(first.result.isError, false);
	assert.equal(first.result.name, "bash", "starting one is a bash call");
	assert.match(first.result.text, /^Started in the background as bg-1\. It keeps running after this call, with no time limit\. (What it has printed so far:\nearly\n|It has printed nothing yet\.)\nUse the background tool with id "bg-1" to read what it prints from here on \(action "read"\) and to stop it \(action "stop"\)\.$/);
	assert.equal(first.result.details.background.status, "running");
	assert.ok(!existsSync(gate), "the call does not wait for the command");
	const leader = await pidIn(leaderFile);
	const child = await pidIn(childFile);
	assert.ok(alive(leader) && alive(child));
	const listed = await client.until("listed for Activity", () => client.running()[0]);
	assert.deepEqual({ ...listed, startedAt: 0 }, { id: "bg-1", conversationId: a, rootConversationId: a, command: listed.command, cwd: work, startedAt: 0 });
	assert.ok(listed.command.startsWith(`echo early; ${LONG} &`), listed.command);
	assert.ok(listed.startedAt >= startedAt && listed.startedAt <= Date.now());
	step("bash with background: true starts a command, returns with what it printed so far, and the command is listed as running");

	// What it printed at once came with the call that started it, unless the machine was too busy for that to be in time:
	// then the first read has it. Either way it is given once.
	let read = await client.background(a, { action: "read", id: "bg-1", wait: first.result.text.includes("early") ? 0 : 30 });
	assert.equal((first.result.text + read.text).split("early\n").length, 2, `what it printed is given once: ${first.result.text} / ${read.text}`);
	read = await client.background(a, { action: "read", id: "bg-1" });
	assert.equal(read.isError, false);
	assert.match(read.text, /^bg-1 \(`echo early; .*`\): running for \d+ seconds?\.\nNothing new since you last read it\.$/, read.text);
	assert.deepEqual({ ...read.details, command: "" }, { action: "read", id: "bg-1", command: "", status: "running" });
	// A read that waits returns when the command prints, not when the wait is over: it waits as long as it may, and the
	// command prints in a moment.
	setTimeout(() => writeFileSync(gate, ""), 700);
	const waited = Date.now();
	read = await client.background(a, { action: "read", id: "1", wait: MAX_WAIT_SECONDS });
	assert.match(read.text, /running for .*\.\nlate\n$/, `only what is new, and the id may be given as a number: ${read.text}`);
	assert.ok(Date.now() - waited < (MAX_WAIT_SECONDS * 1000) / 2, "the wait ends when there is output");
	read = await client.background(a, { action: "read", id: "bg-1", tail: 5 });
	assert.match(read.text, /All it has printed:\nearly\nlate$/, read.text);
	read = await client.background(a, { action: "read", id: "bg-1", tail: 1 });
	assert.match(read.text, /Its last line:\nlate$/, read.text);
	const list = await client.background(a, { action: "list" });
	assert.match(list.text, /^Background commands of this conversation:\n- bg-1: `echo early; .*`: running for .*; no unread output\.$/, list.text);
	assert.deepEqual(list.details, { action: "list", count: 1, running: 1 });
	let told = await client.told(a);
	assert.match(told, /<background_commands>\nCommands you started in the background[^]*\n- bg-1: `echo early; .*`, running since \d\d:\d\d\.\n<\/background_commands>/, told);
	step("the background tool reads what is new, waits for output, gives the last lines again and lists; the agent is told what is running");

	for (const wrong of [{ action: "read", id: "bg-99" }, { action: "stop" }, { action: "peek", id: "bg-1" }, { action: "read", id: "bg-1", tail: 0 }]) {
		const refused = await client.background(a, wrong);
		assert.equal(refused.isError, true, JSON.stringify(wrong));
	}
	const b = await open(worker);
	const others = await client.background(b, { action: "read", id: "bg-1" });
	assert.ok(others.isError && /There is no background command bg-1 in this conversation\. This conversation has no background commands\./.test(others.text), others.text);
	assert.match((await client.background(b, { action: "list" })).text, /^This conversation has no background commands\./);
	assert.ok(!(await client.told(b)).includes("<background_commands>"), "a conversation with none is told nothing");
	const reader = await open(await save({ name: "Reader", access: "read", cwd: work }));
	assert.equal((await client.background(reader, { action: "list" })).isError, true, "a conversation without a shell has no background tool");
	step("an unknown id or action is refused, another conversation's command cannot be reached, and without a shell there is no tool");

	// Two seconds is this engine's limit for a command that is waited for; this one has run for longer.
	await sleep(Math.max(0, 3_500 - (Date.now() - startedAt)));
	assert.ok(alive(leader) && client.running().length === 1, "the default time limit is not for background commands");
	// One that only sleeps is stopped at the limit, as in Claude Code, rather than moved to the background.
	assert.match((await client.tool(a, "/bash sleep 30")).text, /stopped after 2 seconds, the default time limit/, "it still is for a command that is waited for");
	assert.equal(client.running().length, 1, "a command that only sleeps is not moved to the background");
	const stopped = await client.background(a, { action: "stop", id: "bg-1" });
	assert.equal(stopped.isError, false);
	assert.match(stopped.text, /^Stopped bg-1 \(`echo early; .*`\) and everything it started, after \d+ seconds\.$/, stopped.text);
	assert.equal(stopped.details.status, "ended");
	await client.until("stopped, with what it started", () => !alive(leader) && !alive(child));
	await client.until("no longer listed", () => client.running().length === 0);
	assert.match((await client.background(a, { action: "stop", id: "bg-1" })).text, /^bg-1 \(.*\) was already over: it was stopped by the agent after \d+ seconds\.$/);
	assert.match((await client.background(a, { action: "read", id: "bg-1" })).text, /: was stopped by the agent after \d+ seconds\.\nNothing new since you last read it\.$/);
	// A wait is kept under the five minutes the prompt cache lasts (#159); one asked for longer is lowered, and the result says so.
	assert.ok(MAX_WAIT_SECONDS < 300, `the longest wait, ${MAX_WAIT_SECONDS} seconds, is under five minutes`);
	const lowered = await client.background(a, { action: "read", id: "bg-1", wait: 600 });
	assert.match(lowered.text, new RegExp(`\\.\\n\\[The wait was lowered to ${MAX_WAIT_SECONDS} seconds, the most a read waits: a longer pause costs more than reading again\\.\\]\\nNothing new since you last read it\\.$`), lowered.text);
	assert.doesNotMatch((await client.background(a, { action: "read", id: "bg-1", wait: MAX_WAIT_SECONDS })).text, /lowered/, "a wait within the most is not");
	told = await client.told(a);
	assert.match(told, /- bg-1: `echo early; .*` is over: it was stopped by the agent, at \d\d:\d\d\./, told);
	assert.deepEqual(client.markers(a), [], "a stop the agent asked for is in its own row, not a line of its own");
	step("a background command outlives the default time limit; stop ends it and everything it started, and its output can still be read");

	// Something the command started outlives its first process during the stop. The stop was of everything it started all
	// the same, and is worded as any stop the agent asked for.
	{
		const [cmd, leaderPid, childPid] = stubborn();
		const { bg } = await client.start(a, cmd);
		const pids = [await pidIn(leaderPid), await pidIn(childPid)];
		const answer = await client.background(a, { action: "stop", id: bg });
		assert.match(answer.text, new RegExp(`^Stopped ${bg} \\(.*\\) and everything it started, after \\d+ seconds?\\.`), answer.text);
		await client.until("stopped, with what outlived it", () => pids.every((pid) => !alive(pid)));
		const again = new RegExp(`^${bg} \\(.*\\) was already over: it was stopped by the agent after \\d+ seconds?\\.$`);
		assert.match((await client.background(a, { action: "stop", id: bg })).text, again);
		assert.match(await client.told(a), new RegExp(`- ${bg}: .* is over: it was stopped by the agent, at \\d\\d:\\d\\d\\.`));
		assert.deepEqual(client.markers(a), [], "still no line of its own");
		step("a stop the agent asked for is worded the same when something the command started outlives its first process");
	}

	// ---- A command that reaches its time limit in the foreground is moved to the background (#197)
	{
		const gate = join(scratch, "gate-moved");
		const [cmd, leaderPid, childPid] = lingering();
		// It prints, then waits for a gate this test opens only after the call has returned: only the move can return it.
		const line = `echo before; ${cmd.replace("echo up; wait", `while [ ! -e '${gate}' ]; do sleep 0.1; done; echo after; wait`)}`;
		const moved = await client.tool(a, `/bash ${line}`);
		const id = moved.details?.background?.id as string;
		assert.match(id ?? "", /^bg-\d+$/, `the call names the command it moved: ${JSON.stringify(moved)}`);
		assert.equal(moved.isError, false, moved.text);
		assert.ok(moved.text.startsWith("before\n"), `what it printed until the move is the call's output: ${moved.text}`);
		assert.ok(
			moved.text.includes(
				`The command did not complete within 2 seconds, the default time limit for a command, and was moved to the background as ${id} rather than stopped. It keeps running there, with no time limit, until it ends, you or the person stop it, the conversation is archived, or pi² stops. What it printed until now is above. Use the background tool with id "${id}" to read what it prints from here on`,
			),
			moved.text,
		);
		assert.ok(!existsSync(gate), "the call did not wait for the command");
		const pids = [await pidIn(leaderPid), await pidIn(childPid)];
		assert.ok(pids.every(alive), "it is still running");
		const listed = await client.until("listed as running, for Activity and the conversation's strip", () => client.running().find((each) => each.id === id));
		assert.deepEqual([listed.conversationId, listed.command, listed.cwd], [a, line, work]);
		assert.match(await client.told(a), new RegExp(`- ${id}: .*, running since \\d\\d:\\d\\d\\.`), "the agent is told it is running in the background");
		// Its output goes on in the same place: what came with the call counts as read, so a read has only what follows.
		writeFileSync(gate, "");
		const after = await client.printed(a, { result: { text: "" }, bg: id }, "after\n");
		assert.ok(!after.includes("before\n"), `a read starts where the call's output ended: ${after}`);
		const shown = await client.call("background.output", { id });
		assert.ok(shown.output.startsWith("before\n") && shown.output.endsWith("after\n") && shown.running, `the person is shown all of it: ${JSON.stringify(shown)}`);
		// The answer that ran it is over (`tool` waits for it), and it is still running.
		assert.ok(pids.every(alive) && client.running().some((each) => each.id === id), "it outlives its answer");
		const stopped = await client.background(a, { action: "stop", id });
		assert.match(stopped.text, new RegExp(`^Stopped ${id} \\(.*\\) and everything it started, after \\d+ seconds?\\.$`), stopped.text);
		await client.until("stopped, with what it started", () => pids.every((pid) => !alive(pid)));
		await logs(`background command ${id} of conversation ${a} reached its time limit in the foreground and was moved to the background`);
		step("a command that reaches its time limit in the foreground is moved to the background: an id, its output so far and on, listed, told to the agent, outliving its answer, stopped like any other");
	}

	// ---- Ending by itself
	const quick = await client.startOver(a, "echo no-such-port >&2; exit 3");
	assert.equal(quick.result.isError, true, "one that fails at once is an error");
	assert.equal(quick.result.text, `Started in the background as ${quick.bg}, but it is already over: it exited with code 3. What it printed:\nno-such-port\n`);
	const fine = await client.startOver(a, "echo all-done");
	assert.equal(fine.result.isError, false);
	assert.equal(fine.result.text, `Started in the background as ${fine.bg}, but it is already over: it finished. What it printed:\nall-done\n`);
	const later = await client.start(a, "sleep 2; echo done-late; exit 4");
	assert.equal(later.result.details.background.status, "running");
	const marker = await client.until("its end shown in the transcript", () => client.markers(a).find((text) => text.includes(later.bg)));
	assert.equal(marker, `Background command ${later.bg} exited with code 4: sleep 2; echo done-late; exit 4`);
	assert.deepEqual(client.items(a, "marker").find((item) => item.text === marker)?.details, { background: { id: later.bg } }, "the line names its command, for its output window");
	assert.ok(!client.markers(a).some((text) => text.includes(`${quick.bg} `) || text.includes(`${fine.bg} `)), "an end the call that started the command saw is in that call's row, not in a line of its own");
	told = await client.told(a);
	assert.ok(told.includes(`- ${later.bg}: \`sleep 2; echo done-late; exit 4\` is over: it exited with code 4, at `), `the agent is told at its next request: ${told}`);
	assert.match((await client.background(a, { action: "read", id: later.bg })).text, /: exited with code 4 after \d+ seconds\.\ndone-late\n$/);
	const exported = (await client.call("conversation.export", { id: a, format: "markdown" })).text as string;
	assert.ok(exported.includes(`*${marker}*`), "an export has the line too");
	// What a command leaves running when its own process ends is stopped with it.
	const leftFile = join(scratch, "left.pid");
	const leaving = await client.start(a, `${LONG} & echo $! > '${leftFile}'; echo leaving`);
	const leftBehind = await pidIn(leftFile);
	assert.equal(
		await client.until("its end shown", () => client.markers(a).find((text) => text.includes(leaving.bg))),
		// The line shows the command cut to a length, and the temporary folder's path can be long.
		`Background command ${leaving.bg} finished, and what it had left running was stopped with it: ${commandLine(`${LONG} & echo $! > '${leftFile}'; echo leaving`)}`,
	);
	await client.until("what it left running is stopped", () => !alive(leftBehind));
	// engine.log names each command with its conversation, since an id alone does not say whose it was.
	await logs(`background command ${later.bg} of conversation ${a} exited with code 4`);
	await logs(`background command ${leaving.bg} of conversation ${a} finished, and what it had left running was stopped with it`);
	step("a command that ends by itself is shown in the transcript and told to the agent at its next request; what it left running is stopped");

	// ---- Only the end of the output is kept
	const flood = join(scratch, "flood");
	const noisy = await client.start(a, `while [ ! -e '${flood}' ]; do sleep 0.1; done; yes 0123456789 | head -c 600000; echo; echo the-end; sleep 600`);
	assert.match(noisy.result.text, /It has printed nothing yet\./);
	writeFileSync(flood, "");
	// The flood takes a moment to arrive. Looking at the end does not count as reading, so the read that follows starts
	// from the oldest output still kept.
	for (const deadline = Date.now() + PATIENT_MS; !/Its last line:\nthe-end$/.test((await client.background(a, { action: "read", id: noisy.bg, tail: 1 })).text); ) {
		assert.ok(Date.now() < deadline, "the flood arrived");
		await sleep(100);
	}
	// The person reads what is kept, in the app: the last 128 KB, ending with the end. That does not count as the agent
	// reading it, which the agent's read below shows by starting from the oldest output kept.
	const kept = await client.call("background.output", { id: noisy.bg });
	assert.ok(kept.output.length <= 128 * 1024 && kept.output.length > 100_000, `the person is shown at most the last 128 KB: ${kept.output.length}`);
	assert.ok(kept.output.endsWith("\nthe-end\n"), kept.output.slice(-40));
	assert.equal(kept.from, kept.total - kept.output.length);
	assert.equal(kept.dropped, kept.from, "what was let go is counted from the first character printed");
	assert.equal((await client.call("background.output", { id: noisy.bg, from: kept.total - 8 })).output, "the-end\n", "from a later point, only what follows it");
	const firstRead = await client.background(a, { action: "read", id: noisy.bg });
	assert.match(firstRead.text, /\[[\d,]+ characters it printed before this were not kept: only the last 128 KB is\.\]/, firstRead.text.slice(0, 300));
	assert.match(firstRead.text, /\[[\d,]+ characters more: read again for them\.\]$/);
	assert.ok(firstRead.text.length < 31_000, `one read is bounded: ${firstRead.text.length}`);
	const dropped = Number(/\[([\d,]+) characters it printed before/.exec(firstRead.text)![1]!.replaceAll(",", ""));
	const waiting = Number(/\[([\d,]+) characters more/.exec(firstRead.text)![1]!.replaceAll(",", ""));
	assert.ok(dropped >= 600_000 - 2 * 128 * 1024, `most of 600,000 characters were let go: ${dropped}`);
	const noisyStop = await client.background(a, { action: "stop", id: noisy.bg });
	assert.ok(noisyStop.text.length < 31_500 && noisyStop.text.includes("What it printed since you last read it:\n") && /more: read again for them\.\]$/.test(noisyStop.text), noisyStop.text.slice(0, 200));
	assert.match((await client.background(a, { action: "read", id: noisy.bg, tail: 1 })).text, /Its last line:\nthe-end$/, "the end is what is kept");
	step("only the end of a command's output is kept, a read is bounded, and what was lost is said");

	// ---- A time limit the call gave
	const limited = await client.tool(a, '/tool bash {"command":"sleep 600","background":true,"timeout":2}');
	assert.match(limited.text, /with a time limit of 2 seconds\./);
	const limitId = limited.details.background.id as string;
	const timedOut = await client.until("stopped by its own limit", () => client.markers(a).find((text) => text.includes(limitId)));
	assert.equal(timedOut, `Background command ${limitId} was stopped after 2 seconds, the \`timeout\` its call gave: sleep 600`);
	step("a background command has no time limit unless its call gives one, which is kept");

	// ---- The person stops one from Activity
	{
		// What it started outlives its first process during the stop, which is still worded as the person's stop (#168).
		const [cmd, leaderPid, childPid] = stubborn();
		const { bg } = await client.start(a, cmd);
		const pids = [await pidIn(leaderPid), await pidIn(childPid)];
		await client.call("background.stop", { id: bg });
		await client.until("stopped", () => pids.every((pid) => !alive(pid)) && client.running().length === 0);
		assert.equal(await client.until("said in the transcript", () => client.markers(a).find((text) => text.includes(bg))), `Background command ${bg} was stopped by the person: ${commandLine(cmd)}`);
		await assert.rejects(client.call("background.stop", { id: bg }), /no longer running/);
		await assert.rejects(client.call("background.stop", { id: "bg-0" }), /no longer running/);
		assert.match(await client.told(a), new RegExp(`- ${bg}: .* is over: it was stopped by the person, at `), "the agent is told the person stopped it");
		step("the person can stop a background command (Activity's Stop), and the conversation and the agent are told");
	}

	// ---- The person reads a command's output, in Activity or the conversation
	{
		const gate2 = join(scratch, "gate-person");
		// The end-only wait below needs a silent stop. With a shell waiting for sleep, bash can print its child's
		// termination before it ends, legitimately waking the read on new output instead (#224). Replace the shell
		// once it has printed, and run longer than the test's patience so only the stop can end the wait.
		const shownCommand = `echo one; while [ ! -e '${gate2}' ]; do sleep 0.1; done; echo two; exec ${LONG}`;
		const { bg } = await client.start(a, shownCommand);
		let shown = await client.call("background.output", { id: bg, wait: 10 });
		for (const deadline = Date.now() + PATIENT_MS; !shown.output.includes("one\n"); ) {
			assert.ok(Date.now() < deadline, `it printed its first line: ${JSON.stringify(shown)}`);
			shown = await client.call("background.output", { id: bg, wait: 5 });
		}
		assert.deepEqual(
			{ ...shown, startedAt: 0 },
			{ id: bg, conversationId: a, rootConversationId: a, command: shownCommand, cwd: work, startedAt: 0, running: true, stopping: false, ended: null, kept: true, total: 4, from: 0, dropped: 0, output: "one\n" },
		);
		assert.equal((await client.call("background.output", { id: bg.slice(3) })).id, bg, "the id may be given as a number");
		// Asked from where it got to, with a wait, the answer comes when there is more.
		setTimeout(() => writeFileSync(gate2, ""), 700);
		const more = await answered("the wait to end when there is output", client.call("background.output", { id: bg, from: shown.total, wait: OUTPUT_WAIT_SECONDS }));
		assert.deepEqual([more.output, more.from, more.dropped, more.total], ["two\n", 4, 0, 8]);
		const quiet = Date.now();
		const nothing = await client.call("background.output", { id: bg, from: more.total, wait: 0.5 });
		assert.ok(nothing.output === "" && nothing.running && Date.now() - quiet >= 400, "with nothing new, it waits as long as asked and says so");
		// The person reading it changes nothing for the agent: what it has not read is still there for it.
		const agentRead = await client.background(a, { action: "read", id: bg, wait: 10 });
		assert.ok(agentRead.text.endsWith("two\n"), `the agent still gets what the person was shown: ${agentRead.text}`);
		// A wait ends when the command does.
		const waiting = client.call("background.output", { id: bg, from: more.total, wait: OUTPUT_WAIT_SECONDS });
		await client.call("background.stop", { id: bg });
		const over = await answered("the wait to end when the command does", waiting);
		assert.equal(over.running, false, "a wait ends when the command ends");
		assert.equal(over.output, "", "the end, not new output, woke this wait");
		const after = await client.call("background.output", { id: bg });
		assert.equal(after.output, "one\ntwo\n", "an ended command's output can still be read");
		assert.equal(after.running, false);
		assert.equal(after.ended.failed, false, "stopped is not failed");
		assert.match(after.ended.how, /^was stopped by the person after \d+ seconds?$/, after.ended.how);
		await assert.rejects(client.call("background.output", { id: "bg-9999" }), /no longer has this command's output/);
		await assert.rejects(client.call("background.output", {}), /no longer has this command's output/);
		step("the person can read a command's output from any point, waiting for more, without changing what the agent has read");
	}

	// ---- Approvals and command rules
	const project = repo("project");
	{
		const asker = await save({ name: "Asker", access: "ask", cwd: project, worktree: true });
		const inWorktree = async (): Promise<number> => {
			const id = await open(asker);
			await client.until("in a worktree", () => (client.conversations.get(id)?.state.agent.cwd as string | undefined)?.startsWith(join(home, "worktrees")));
			return id;
		};
		type Rule = { folder: string; words: string[] };
		const rulesOf = () => ((client.events.agents?.agents ?? []).find((x: Event) => x.id === asker)?.commandRules ?? []) as Rule[];
		const e = await inWorktree();
		let outcome = await client.attempt(e, "/background ./serve");
		assert.equal(outcome.asked?.tool, "bash", "it asks as a command does");
		assert.equal(outcome.asked?.background, true, "and the approval says it will keep running");
		assert.deepEqual(outcome.asked?.rule, { words: ["./serve"], folder: project, worktrees: true }, "with the rule a command would be offered");
		assert.ok(outcome.result.isError && outcome.result.text.includes("declined"), outcome.result.text);
		assert.equal(client.running().length, 0, "denied, nothing was started");
		const plain = await client.attempt(e, "/bash echo hello");
		assert.equal(plain.asked?.background, undefined, "a command that is waited for does not say so");
		// Allowed once, as a command that is waited for, and still running at its limit: starting it in the background would
		// ask, so it is stopped, not moved there (#197).
		const once = await client.attempt(e, `/bash echo waiting; ${LONG}`, "once");
		assert.ok(once.asked !== null && once.asked.background === undefined, "it asks, as a command that is waited for");
		assert.equal(once.result.isError, true, once.result.text);
		assert.ok(once.result.text.includes("waiting\n"), once.result.text);
		assert.ok(
			once.result.text.includes(
				"The command was stopped after 2 seconds, the default time limit for a command. It was not moved to the background, as starting a command there needs the person's approval in this conversation. If it needs longer, run it again with a larger `timeout` (in seconds, up to 600), or with `background: true`",
			),
			once.result.text,
		);
		assert.equal(once.result.details?.background, undefined);
		assert.equal(client.running().length, 0, "nothing was moved to the background");

		outcome = await client.attempt(e, "/background ./serve", "rule");
		assert.equal(outcome.asked?.background, true);
		assert.match(outcome.result.text, /^Started in the background as bg-\d+\./);
		const firstServer = outcome.result.details.background.id as string;
		await client.until("rule kept", () => rulesOf().length === 1);
		assert.deepEqual(rulesOf().map((rule) => [rule.folder, rule.words]), [[project, ["./serve"]]]);
		const f = await inWorktree();
		outcome = await client.attempt(f, "/background ./serve --port 3001");
		assert.equal(outcome.asked, null, "the rule covers a background command in another worktree of the repository");
		assert.deepEqual(outcome.result.details.allowedBy, ["./serve"], "and its row says which rule let it run");
		const secondServer = outcome.result.details.background.id as string;
		const served = await client.printed(f, { result: outcome.result, bg: secondServer }, "serving in ");
		assert.ok(served.includes(`serving in ${realpathSync(client.conversations.get(f)!.state.agent.cwd)}`), `it runs in the conversation's own worktree: ${served}`);
		outcome = await client.attempt(f, "/background ./serve & sleep 1");
		assert.ok(outcome.asked !== null && outcome.asked.rule === undefined, "a line the rules cannot judge still asks");
		// The rule covers it in the background too, so waited for, it is moved there at its limit without asking.
		const ruled = await client.attempt(f, "/bash ./serve --port 3002");
		assert.equal(ruled.asked, null, "the rule covers it");
		assert.match(ruled.result.text, /and was moved to the background as bg-\d+ rather than stopped\./, ruled.result.text);
		await client.attempt(f, `/tool background {"action":"stop","id":"${ruled.result.details.background.id}"}`);
		// Reading, listing and stopping are not asked about, under Ask first.
		for (const args of [{ action: "list" }, { action: "read", id: secondServer }, { action: "stop", id: secondServer }]) {
			const unasked = await client.attempt(f, `/tool background ${JSON.stringify(args)}`);
			assert.equal(unasked.asked, null, `${args.action} does not ask`);
			assert.equal(unasked.result.isError, false, unasked.result.text);
		}
		assert.equal((await client.attempt(e, `/tool background {"action":"stop","id":"${firstServer}"}`)).asked, null);
		// "Always Allow bash Here" covers a background command, as it covers any command.
		const g = await inWorktree();
		outcome = await client.attempt(g, "/background sleep 600", "always");
		assert.ok(outcome.asked !== null && outcome.asked.background === true);
		const third = outcome.result.details.background.id as string;
		outcome = await client.attempt(g, "/background sleep 601");
		assert.equal(outcome.asked, null, "allowed for the conversation, the next one does not ask");
		// Always Allow covers a background start, so a command waited for is moved there at its limit.
		const always = await client.attempt(g, `/bash echo held; ${LONG}`);
		assert.equal(always.asked, null);
		assert.match(always.result.text, /and was moved to the background as bg-\d+ rather than stopped\./, always.result.text);
		await client.attempt(g, `/tool background {"action":"stop","id":"${always.result.details.background.id}"}`);
		await client.attempt(g, `/tool background {"action":"stop","id":"${third}"}`);
		await client.attempt(g, `/tool background {"action":"stop","id":"${outcome.result.details.background.id}"}`);
		await client.until("all stopped", () => client.running().length === 0);
		step(
			"under Ask first a background command asks as a command does and says it keeps running; a rule, also across worktrees, and Always Allow cover it, and a command they cover is moved to the background at its limit, one allowed once stopped; reading and stopping never ask",
		);
	}

	// ---- Archiving, deleting, and removing a worktree
	{
		const [cmd, leaderPid, childPid] = lingering();
		const c = await open(worker);
		const { bg } = await client.start(c, cmd);
		const pids = [await pidIn(leaderPid), await pidIn(childPid)];
		await client.call("conversation.archive", { id: c });
		await client.until("archiving stopped it", () => pids.every((pid) => !alive(pid)) && client.running().length === 0);
		assert.equal(await client.until("said in the transcript", () => client.markers(c).find((text) => text.includes(bg))), `Background command ${bg} was stopped because the conversation was archived: ${commandLine(cmd)}`);

		const [cmd2, leaderPid2] = lingering();
		const d = await open(worker);
		await client.start(d, cmd2);
		const pid2 = await pidIn(leaderPid2);
		await client.call("conversation.delete", { id: d });
		await client.until("deleting stopped it", () => !alive(pid2) && client.running().length === 0);

		// A sub-chat's command is stopped when the conversation it belongs to is archived.
		const helper = await save({ name: "Helper", access: "full", cwd: work });
		const lead = await save({ name: "Lead", access: "full", cwd: work, delegates: [helper] });
		const p = await open(lead);
		const [cmd3, leaderPid3] = lingering();
		const handed = await client.tool(p, `/delegate Helper: /background ${cmd3}`);
		const sub = handed.details.conversationId as number;
		const pid3 = await pidIn(leaderPid3);
		const ofSub = await client.until("the sub-chat's command listed", () => client.running().find((each) => each.conversationId === sub));
		assert.equal(ofSub.rootConversationId, p, "listed under the conversation the sub-chat belongs to");
		await client.call("conversation.archive", { id: p });
		await client.until("archiving the parent stopped it", () => !alive(pid3) && client.running().length === 0);
		step("archiving or deleting a conversation stops its background commands, and those of its sub-chats");

		const builder = await save({ name: "Builder", access: "full", cwd: project, worktree: true });
		const w = await open(builder);
		const root = await client.until("in a worktree", () => {
			const cwd = client.conversations.get(w)?.state.agent.cwd as string | undefined;
			return cwd?.startsWith(join(home, "worktrees")) ? cwd : undefined;
		});
		const { bg: served } = await client.start(w, "./serve");
		await client.call("worktree.remove", { id: w, force: true });
		assert.equal(existsSync(root), false, "the worktree is gone");
		await client.until("removing its worktree stopped it", () => client.running().length === 0);
		assert.equal(await client.until("said in the transcript", () => client.markers(w).find((text) => text.includes(served))), `Background command ${served} was stopped because its worktree was removed: ./serve`);
		step("removing the worktree a background command runs in stops it first");
	}

	// ---- The engine stops, cleanly: its commands stop with it, and the next engine says so
	const z = await open(worker);
	{
		// One that heeds no SIGTERM, so that the stop has to give up on it by its own bound and end it with SIGKILL.
		const [cmd, leaderPid, childPid] = deaf();
		const { bg } = await client.start(z, cmd);
		const pids = [await pidIn(leaderPid), await pidIn(childPid)];
		// And one whose shell ends at SIGTERM while what it started ignores it (`server & wait`): once the shell is gone,
		// its group can no longer be signalled through it, so what is left in it is found by `ps` and ended there (#199).
		const [cmd2, leaderPid2, childPid2] = stubborn();
		const { bg: bg2 } = await client.start(z, cmd2);
		pids.push(await pidIn(leaderPid2), await pidIn(childPid2));
		// And one moved to the background at its limit (#197), which stops with the rest.
		const [cmd3, leaderPid3, childPid3] = lingering();
		// (Not starting with `sleep`, which would be stopped at its limit instead.)
		assert.match((await client.tool(z, `/bash echo moving; ${cmd3}`)).text, /was moved to the background as bg-\d+ rather than stopped/);
		pids.push(await pidIn(leaderPid3), await pidIn(childPid3));
		await stop(engine);
		// The app gives the engine five seconds before a restore. Measure inside the engine, so time this test spends
		// unscheduled after the engine exits is not charged to it. Delays inside the engine still count: the app's deadline
		// counts them too. CPU time or subtracting late timer ticks would hide a real wait and weaken this check (#144).
		const stopped = [...readFileSync(engineLog, "utf8").matchAll(/stopped cleanly in (\d+) ms/g)].at(-1);
		assert.ok(stopped !== undefined, "the engine says how long its stop took");
		assert.equal(engine.exitCode, 0, "the engine exited cleanly");
		assert.ok(Number(stopped[1]) < 5_000, `the engine's stop fits in the five seconds the app gives it: ${stopped[0]}`);
		assert.ok(pids.every((pid) => !alive(pid)), "stopping the engine stopped the command and what it started");
		engine = boot();
		client = await Client.attach(engine);
		assert.deepEqual(client.running(), []);
		await client.call("conversation.open", { id: z });
		assert.equal(await client.until("said in the transcript", () => client.markers(z).find((text) => text.includes(`${bg} `))), `Background command ${bg} ended when pi²’s engine stopped: ${commandLine(cmd)}`);
		assert.equal(await client.until("said in the transcript", () => client.markers(z).find((text) => text.includes(`${bg2} `))), `Background command ${bg2} ended when pi²’s engine stopped: ${commandLine(cmd2)}`);
		assert.match(await client.told(z), new RegExp(`- ${bg}: .* is over: it ended when pi²’s engine stopped\\.`), "the agent is told at its next request");
		assert.match((await client.background(z, { action: "read", id: bg })).text, /: ended when pi²’s engine stopped\.\nIts output was in the engine that stopped, and was not kept\.$/);
		const lost = await client.call("background.output", { id: bg });
		assert.deepEqual([lost.running, lost.kept, lost.output, lost.ended.how], [false, false, "", "ended when pi²’s engine stopped"], "the person is told its output was not kept");
		const next = await client.start(z, "sleep 600");
		assert.ok(Number(next.bg.slice(3)) > Number(bg.slice(3)), `ids are not used again after a restart: ${next.bg} after ${bg}`);
		await client.background(z, { action: "stop", id: next.bg });
		assert.equal(client.events.recovery?.recovery, null, "a clean stop is not an unexpected one: Activity has no notice");
		step(`a clean stop of the engine stops its background commands, even ones that ignore SIGTERM and what outlives a shell that heeds it, within the app's five seconds (${stopped[0]}); the next engine writes that down and tells the agent`);
	}

	// ---- The engine is killed outright: the command is left running, and the next engine stops it
	{
		const [cmd, leaderPid, childPid] = lingering();
		const { bg } = await client.start(z, cmd);
		const pids = [await pidIn(leaderPid), await pidIn(childPid)];
		// One moved to the background at its limit is on record as any other is (#197).
		const [movedCmd, movedLeader, movedChild] = lingering();
		const movedResult = await client.tool(z, `/bash echo moving; ${movedCmd}`);
		const moved = movedResult.details?.background?.id as string;
		assert.match(movedResult.text, /was moved to the background as bg-\d+ rather than stopped/);
		const movedPids = [await pidIn(movedLeader), await pidIn(movedChild)];
		await stop(engine, "SIGKILL");
		assert.ok([...pids, ...movedPids].every(alive), "an engine killed outright does not stop the command");
		engine = boot();
		client = await Client.attach(engine);
		await client.call("conversation.open", { id: z });
		assert.equal(
			await client.until("said in the transcript", () => client.markers(z).find((text) => text.includes(bg))),
			`Background command ${bg} was left running when pi²’s engine stopped, and was stopped when the engine started again: ${commandLine(cmd)}`,
		);
		await client.until("what was left running is stopped", () => pids.every((pid) => !alive(pid)));
		await logs(`background command ${bg} of conversation ${z} left by the last engine was stopped`);
		await client.until("the moved one too", () => movedPids.every((pid) => !alive(pid)));
		assert.equal(
			await client.until("its line", () => client.markers(z).find((text) => text.includes(`${moved} `))),
			`Background command ${moved} was left running when pi²’s engine stopped, and was stopped when the engine started again: ${commandLine(`echo moving; ${movedCmd}`)}`,
		);
		assert.deepEqual(client.running(), []);
		assert.match((await client.background(z, { action: "list" })).text, new RegExp(`- ${bg}: .*: was left running when pi²’s engine stopped, and was stopped when the engine started again; no unread output\\.`));
		// Activity's notice after the unexpected stop names it, with its conversation and what became of it.
		const notice: Event[] = client.events.recovery?.recovery?.background ?? [];
		assert.deepEqual(
			notice.map(({ title: _title, ...rest }) => rest),
			[
				{ id: bg, conversationId: z, rootConversationId: z, command: cmd, outcome: "stopped", group: pids[0] },
				{ id: moved, conversationId: z, rootConversationId: z, command: `echo moving; ${movedCmd}`, outcome: "stopped", group: movedPids[0] },
			],
		);
		const listed = await client.until("the conversation listed", () => client.events.library?.conversations.find((conversation: Event) => conversation.id === z));
		assert.equal(notice[0]!.title, listed.title, "with its conversation's title");
		step("a background command left running by an engine killed outright is stopped by the next engine, with what it started, and marked; Activity's notice names it");
	}

	// ---- What a command started is known by the run's marker, once the command's own first process is gone
	{
		// A program whose environment macOS lets another process read; `sleep` and the like it does not (docs/worktrees.md).
		const holderFile = join(scratch, "holder.pid");
		const leaderFile = join(scratch, "short-leader.pid");
		const cmd = `'${process.execPath}' -e 'require("fs").writeFileSync(process.argv[1], String(process.pid)); ${LONG_WAIT}' '${holderFile}' & echo $$ > '${leaderFile}'; sleep 6`;
		const { bg } = await client.start(z, cmd);
		const [leader, holder] = [await pidIn(leaderFile), await pidIn(holderFile)];
		await stop(engine, "SIGKILL");
		// With no engine running, the command's own process ends, and what it started is left in a group without a leader.
		await until("the command's own process to end", () => !alive(leader));
		assert.ok(alive(holder), "what it started is still running");
		engine = boot();
		client = await Client.attach(engine);
		await client.call("conversation.open", { id: z });
		assert.equal(
			await client.until("said in the transcript", () => client.markers(z).find((text) => text.includes(`${bg} `))),
			`Background command ${bg} was left running when pi²’s engine stopped, and was stopped when the engine started again: ${commandLine(cmd)}`,
		);
		await client.until("what it had started is stopped", () => !alive(holder));
		step("what a background command started is stopped by the next engine by the run's marker, when the command's own process ended meanwhile");
	}

	// ---- Only part of what it started carries the marker: that part is stopped, the rest left alone, and the line says both
	{
		const markedFile = join(scratch, "marked.pid");
		const unmarkedFile = join(scratch, "unmarked.pid");
		const leaderFile = join(scratch, "partly-leader.pid");
		const holder = (file: string) => `'${process.execPath}' -e 'require("fs").writeFileSync(process.argv[1], String(process.pid)); ${LONG_WAIT}' '${file}'`;
		const cmd = `${holder(markedFile)} & env -u PI2_RUN ${holder(unmarkedFile)} & echo $$ > '${leaderFile}'; sleep 6`;
		const { bg } = await client.start(z, cmd);
		const [leader, marked, unmarked] = [await pidIn(leaderFile), await pidIn(markedFile), await pidIn(unmarkedFile)];
		await stop(engine, "SIGKILL");
		await until("the command's own process to end", () => !alive(leader));
		assert.ok(alive(marked) && alive(unmarked), "what it started is still running");
		engine = boot();
		client = await Client.attach(engine);
		await client.call("conversation.open", { id: z });
		const group = leader;
		assert.equal(
			await client.until("said in the transcript", () => client.markers(z).find((text) => text.includes(`${bg} `))),
			`Background command ${bg} was left running when pi²’s engine stopped. What pi² could tell it had started was stopped when the engine started again; something else in its process group (${group}) may still be running, and was left alone because pi² could not be sure it is the same: ${commandLine(cmd)}`,
		);
		await client.until("the part with the marker is stopped", () => !alive(marked));
		await sleep(500);
		assert.ok(alive(unmarked), "the part without the marker is not touched");
		assert.deepEqual(
			client.events.recovery?.recovery?.background.map((left: Event) => [left.id, left.outcome, left.group]),
			[[bg, "partly", group]],
			"Activity's notice says it was stopped in part",
		);
		process.kill(unmarked, "SIGKILL");
		step("when only part of what a background command started carries the run's marker, that part is stopped, the rest is left alone, and its line says both");
	}
	console.log("PASS");
	passed = true;
} finally {
	// A clean stop of the engine stops whatever it still has running in the background.
	if (running(engine)) {
		engine.kill("SIGTERM");
		await Promise.race([exited(engine), sleep(8_000)]);
		await stop(engine, "SIGKILL");
	}
	// And should a check have failed between killing an engine and starting the next, what that engine left running is
	// stopped here: only a process that is still what this test started, never just a number that was written down.
	for (const pid of started) {
		try {
			const line = execFileSync("/bin/ps", ["-o", "command=", "-p", String(pid)], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
			if (line.includes(scratch) || line === LONG || line === "sleep 6") process.kill(pid, "SIGKILL");
		} catch {
			// Gone, as it should be.
		}
	}
	// What the engines said, should a check have failed.
	if (!passed && existsSync(engineLog)) process.stderr.write(readFileSync(engineLog, "utf8"));
	rmSync(home, { recursive: true, force: true });
	rmSync(scratch, { recursive: true, force: true });
}
process.exit(0);
