// Commands run by the engine keep all their output when the engine is busy as they exit (issue #13). pi-durable's
// execution environment closes a finished command's pipes after a short wait for more output; a busy event loop used to
// let that wait run out before the output already in the pipe was read, so the command succeeded with no output.
// scripts/patch-dependencies.ts fixes it until pi-durable does; this fails if the fix is missing.
//
// Each command exits at once and leaves a child that writes 50 ms later, and the event loop is then kept busy for
// 150 ms after the exit, as it is in an engine that is starting up.

import assert from "node:assert/strict";
import childProcess from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { syncBuiltinESMExports } from "node:module";
import { tmpdir } from "node:os";
import { join } from "node:path";

// The environment imports spawn from node:child_process; this wraps it before the environment is loaded.
let busyAfterExit = 0;
const realSpawn = childProcess.spawn;
(childProcess as { spawn: unknown }).spawn = (...args: Parameters<typeof realSpawn>) => {
	const child = realSpawn(...args);
	const emit = child.emit.bind(child);
	child.emit = ((event: string, ...rest: unknown[]) => {
		const result = emit(event, ...rest);
		if (event === "exit" && busyAfterExit > 0) {
			const until = Date.now() + busyAfterExit;
			while (Date.now() < until) {}
		}
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
	busyAfterExit = 150;
	for (let i = 0; i < 5; i++) {
		const { output } = await run("(sleep 0.05; echo late) & echo early");
		assert.equal(output, "early\nlate\n", "output still in the pipe when the engine gets to it is kept");
	}
	busyAfterExit = 0;
	assert.equal((await run("echo plain")).output, "plain\n");
	// What the wait is for: a background process holding the pipe open does not keep the command from finishing.
	const held = await run("sleep 5 & echo held");
	assert.equal(held.output, "held\n");
	assert.ok(held.ms < 2_000, `a command whose background child holds its output open still finishes (${held.ms} ms)`);
} finally {
	rmSync(folder, { recursive: true, force: true });
}

console.log("exec: ok (output kept when the engine is busy as a command exits)");
process.exit(0); // the background sleep above still holds a pipe
