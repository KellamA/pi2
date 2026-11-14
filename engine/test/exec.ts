// Commands run by the engine keep all their output when the engine is busy as they exit (issue #13). pi-durable's
// execution environment closes a finished command's pipes after a short wait for more output; a busy event loop used to
// let that wait run out before the output already in the pipe was read, so the command succeeded with no output.
// scripts/patch-dependencies.ts fixes it until pi-durable does; this fails if the fix is missing.
//
// Each command exits at once and leaves a child that holds the pipe open. The event loop is then kept busy, as it is in
// an engine that is starting up: while it is, the child is told to write, and the loop stays busy until the child says
// it has written and for at least 150 ms, longer than the library's 100 ms wait for more output. So when the loop
// turns, the wait has run out and the output is certainly in the pipe, however slow the machine is (issue #60).
//
// It also checks that a command's standard input is closed (issue #45): `cat` and `read` with nothing to read return at
// once, instead of waiting for input that never comes. And that the `bash` agents get says it has a time limit.

import assert from "node:assert/strict";
import childProcess from "node:child_process";
import { existsSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { syncBuiltinESMExports } from "node:module";
import { tmpdir } from "node:os";
import { join } from "node:path";

// The environment imports spawn from node:child_process; this wraps it before the environment is loaded. The library
// handles "exit" (and starts its wait for more output) first, then whatever is in busyAfterExit runs.
let busyAfterExit: (() => void) | undefined;
const realSpawn = childProcess.spawn;
(childProcess as { spawn: unknown }).spawn = (...args: Parameters<typeof realSpawn>) => {
	const child = realSpawn(...args);
	const emit = child.emit.bind(child);
	child.emit = ((event: string, ...rest: unknown[]) => {
		const result = emit(event, ...rest);
		if (event === "exit") busyAfterExit?.();
		return result;
	}) as typeof child.emit;
	return child;
};
syncBuiltinESMExports();
const { NodeExecutionEnv } = await import("@earendil-works/pi-durable/env/node");

const folder = mkdtempSync(join(tmpdir(), "pi2-exec-"));
const env = new NodeExecutionEnv({ cwd: folder });
const run = async (command: string) => {
	let output = "";
	const started = Date.now();
	const result = await env.exec(command, { onOutput: (text: string) => void (output += text) }, {} as never);
	assert.ok(result.ok, `${command} ran`);
	return { output, ms: Date.now() - started };
};

try {
	const pause = new Int32Array(new SharedArrayBuffer(4)); // Atomics.wait on it sleeps without letting the loop turn
	for (let i = 0; i < 5; i++) {
		// The child writes only once told to, so not before the exit, and the engine cannot have read it yet. It then
		// says it has written (write returned, so the text is in the pipe) and keeps the pipe open.
		const go = join(folder, `go-${i}`);
		const written = join(folder, `written-${i}`);
		let childWrote = false;
		busyAfterExit = () => {
			const until = Date.now() + 150;
			const giveUp = Date.now() + 30_000;
			writeFileSync(go, "");
			while (!(childWrote = existsSync(written)) && Date.now() < giveUp) Atomics.wait(pause, 0, 0, 1);
			while (Date.now() < until) {}
		};
		const { output } = await run(`(while [ ! -e go-${i} ]; do sleep 0.01; done; echo late; : > written-${i}; sleep 1) & echo early`);
		busyAfterExit = undefined;
		assert.ok(childWrote, "the background child wrote while the engine was busy");
		assert.equal(output, "early\nlate\n", "output already in the pipe when the engine gets to it is kept");
	}
	assert.equal((await run("echo plain")).output, "plain\n");
	// What the wait is for: a background process holding the pipe open does not keep the command from finishing.
	const held = await run("sleep 5 & echo held");
	assert.equal(held.output, "held\n");
	assert.ok(held.ms < 2_000, `a command whose background child holds its output open still finishes (${held.ms} ms)`);

	// Standard input is /dev/null: nothing to read, and the end of it straight away.
	const reading = await run('cat; read -r answer; echo "read: $? [$answer]"; [ -t 0 ] || echo not-a-terminal');
	assert.equal(reading.output, "read: 1 []\nnot-a-terminal\n", "cat and read get no input");
	assert.ok(reading.ms < 2_000, `a command that reads its input returns at once (${reading.ms} ms)`);

	// What the model reads about bash: there is a default limit, and a larger timeout can be passed.
	const { commands, DEFAULT_COMMAND_TIMEOUT_SECONDS } = await import("../src/commands.ts");
	const { createBashTool } = await import("@earendil-works/pi-durable/tools");
	const wrap = commands(undefined as never, undefined as never).wraps![0]!;
	const bash = (wrap as { wrap(tool: unknown): { description: string; parameters: unknown } }).wrap(createBashTool());
	assert.equal(DEFAULT_COMMAND_TIMEOUT_SECONDS, 1800, "the default is 30 minutes");
	assert.match(bash.description, /stopped after 30 minutes unless you pass `timeout`; for a command you know takes longer, pass a larger one/);
	assert.match(bash.description, /Standard input is closed/);
	assert.doesNotMatch(bash.description, /Optionally provide a timeout/);
	assert.match(JSON.stringify(bash.parameters), /Timeout in seconds\. Default 1800 \(30 minutes\); pass a larger one/);
} finally {
	rmSync(folder, { recursive: true, force: true });
}

console.log("exec: ok (output kept when the engine is busy as a command exits; standard input closed; bash tells of its time limit)");
process.exit(0); // the background sleep above still holds a pipe
