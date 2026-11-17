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
// once, instead of waiting for input that never comes. And that the `bash` agents get says it has a time limit, and
// that it can leave a command running in the background.

import assert from "node:assert/strict";
import childProcess from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, utimesSync, writeFileSync } from "node:fs";
import { syncBuiltinESMExports } from "node:module";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { PATIENT_MS } from "./patience.ts";

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

/** `promise`, unless it has not settled in ten minutes, which only a command that hangs takes (patience.ts). */
const hangs = <T>(what: string, promise: Promise<T>): Promise<T> =>
	Promise.race([promise, new Promise<never>((_, reject) => setTimeout(() => reject(new Error(`Timed out: ${what}`)), PATIENT_MS).unref())]);

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
			const giveUp = Date.now() + PATIENT_MS;
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
	// What the wait is for: a background process holding the pipe open does not keep the command from finishing. This
	// one holds it until the test lets it go, after the command has finished, so finishing at all shows it: nothing here
	// depends on how fast the machine is.
	const held = await hangs("a command whose background child holds its output open still finishes", run("(while [ ! -e held-gate ] && [ -d . ]; do sleep 0.05; done) & echo held"));
	assert.equal(held.output, "held\n");
	assert.ok(!existsSync(join(folder, "held-gate")), `the child was still holding its output open (${held.ms} ms)`);
	writeFileSync(join(folder, "held-gate"), "");

	// Standard input is /dev/null: nothing to read, and the end of it straight away. A command waiting for input that
	// never comes would never return.
	const reading = await hangs("a command that reads its input returns at once", run('cat; read -r answer; echo "read: $? [$answer]"; [ -t 0 ] || echo not-a-terminal'));
	assert.equal(reading.output, "read: 1 []\nnot-a-terminal\n", "cat and read get no input");

	// What the model reads about bash: there is a default limit, and a larger timeout can be passed, up to a most.
	const { commands, DEFAULT_COMMAND_TIMEOUT_SECONDS, MAX_COMMAND_TIMEOUT_SECONDS, movedMessage, shell, stoppedMessage, tookMessage } = await import("../src/commands.ts");
	const { createBashTool } = await import("@earendil-works/pi-durable/tools");
	const { BACKGROUND_CONTEXT } = await import("@earendil-works/chord/context");
	const wrap = commands(undefined as never, undefined as never).wraps![0]!;
	const bash = (wrap as { wrap(tool: unknown): { description: string; parameters: unknown } }).wrap(createBashTool());
	assert.equal(DEFAULT_COMMAND_TIMEOUT_SECONDS, 120, "the default is 2 minutes, as Claude Code's (issue #160)");
	assert.equal(MAX_COMMAND_TIMEOUT_SECONDS, 600, "a call may ask for 10 minutes at most, as in Claude Code");
	assert.match(
		bash.description,
		/A command has 2 minutes unless you pass `timeout` in seconds, up to 10 minutes\. One not finished by then is moved to the background, and the result gives its id for the background tool; it is stopped instead where that would need the person's approval, or when it starts with `sleep`\. For one you know may take longer \(a full test suite, a build\), use `background: true` from the start, which has no time limit\./,
	);
	assert.match(bash.description, /Standard input is closed/);
	assert.doesNotMatch(bash.description, /Optionally provide a timeout/);
	// That a long output is kept whole, so it need not cut it short itself (issue #161).
	assert.match(bash.description, /A long output is shortened to its last 2000 lines or 50KB, and the whole of it is kept for 7 days in a file the result names/);
	assert.match(bash.description, /do not cut an output short with `head`, `tail` or `grep`/);
	// What it is not for, and that it starts in the folder (issue #162).
	assert.match(bash.description, /Every command starts in the conversation's folder, so there is no need to `cd` to it/);
	assert.match(bash.description, /Not for reading files \(`read` takes several at once\), finding or searching them \(`find_files`, `search_files`\), or changing them \(`edit`, `write`\)/);
	assert.doesNotMatch(bash.description, /saved to a temp file/);
	assert.match(JSON.stringify(bash.parameters), /Timeout in seconds\. Default 120 \(2 minutes\), at most 600 \(10 minutes\); pass a larger one/);
	// And about leaving one running: how to, that the limit is not for it, and where its output is read.
	assert.match(bash.description, /With `background: true` the command is started and left running/);
	assert.match(bash.description, /A background command has no time limit unless you pass `timeout`/);
	assert.match(bash.description, /the background tool reads its later output/);
	assert.match(JSON.stringify(bash.parameters), /"background":\{[^}]*"type":"boolean"/);

	// A call that asks for more than the most gets the most, and is told what to do instead (issue #160). The command
	// itself would run for ten minutes, longer than any wait here, so only the limit can end it.
	type Run = { execute(args: unknown, api: unknown, context: unknown): Promise<unknown> };
	const limited = (shell(undefined, { fallback: 1, most: 2 }) as unknown as { wrap(tool: unknown): Run }).wrap(createBashTool());
	const runLimited = async (args: Record<string, unknown>) => {
		let printed = "";
		const api = { env, conversationId: 1, callId: "limited", output: (text: string) => void (printed += text), retainedOutput: () => ({ text: printed, truncated: false }), diagnostic: () => {} };
		try {
			// A wrap made without an engine moves nothing to the background: the limit stops the command.
			return { result: await hangs("a command the limit stops", limited.execute(args, api, BACKGROUND_CONTEXT)), printed };
		} catch (error) {
			return { error: (error as Error).message, printed };
		}
	};
	const lowered = await runLimited({ command: "echo started; sleep 600", timeout: 3600 });
	assert.equal(lowered.printed, "started\n", "what it printed is kept");
	assert.equal(
		lowered.error,
		"The command was stopped after 2 seconds, the longest a command may run unless it is in the background (this call asked for 60 minutes). If it needs longer, run it again with `background: true`, which has no time limit, and read its output with the background tool.",
	);
	const quiet = await runLimited({ command: "sleep 600" });
	assert.equal(
		quiet.error,
		"The command was stopped after 1 second, the default time limit for a command. If it needs longer, run it again with a larger `timeout` (in seconds, up to 2), or with `background: true`, which has no time limit, and read its output with the background tool.",
		"a second of quiet is not worth remarking on",
	);
	assert.equal((await runLimited({ command: "echo fine", timeout: 2 })).printed, "fine\n");

	// A non-zero exit is told as a fact, not as an error, unless the command could not be started or a signal ended it
	// (issue #182). Limits longer than any wait here, so only the command ends each run.
	const roomy = (shell(undefined, { fallback: 600, most: 600 }) as unknown as { wrap(tool: unknown): Run }).wrap(createBashTool());
	const ended = async (command: string) => {
		let printed = "";
		const api = { env, conversationId: 1, callId: "exit", output: (text: string) => void (printed += text), retainedOutput: () => ({ text: printed, truncated: false }), diagnostic: () => {} };
		return (await hangs(command, roomy.execute({ command }, api, {}))) as { isError?: boolean; details?: unknown; diagnostics?: unknown; structuredOutput: { exitCode: number } };
	};
	const clean = await ended("true");
	assert.deepEqual([clean.isError, clean.details, clean.diagnostics, clean.structuredOutput.exitCode], [undefined, undefined, undefined, 0], "exit 0 says nothing of it");
	for (const [command, code] of [["grep -q nothing-here /dev/null", 1], ["echo pending; exit 8", 8], ["false && echo never", 1], ["exit 255", 255]] as const) {
		const result = await ended(command);
		assert.equal(result.isError, undefined, `${command}: not an error`);
		assert.deepEqual(result.details, { exitCode: code }, command);
		assert.deepEqual(result.diagnostics, [{ severity: "info", code: "exit_code", message: `Exit code ${code}` }], command);
		assert.equal(result.structuredOutput.exitCode, code, `${command}: a script still gets the code`);
	}
	for (const [command, code, message, signal] of [
		["no-such-command-182", 127, "Exit code 127: a command it ran was not found.", undefined],
		["/dev/null", 126, "Exit code 126: a command it ran could not be run (it is not executable, or not allowed).", undefined],
		["kill -KILL $$", 137, "The command was ended by SIGKILL (exit code 137).", "SIGKILL"],
		["sh -c 'kill -TERM $$'", 143, "The command was ended by SIGTERM (exit code 143).", "SIGTERM"],
	] as const) {
		const result = await ended(command);
		assert.equal(result.isError, true, `${command}: an error`);
		assert.deepEqual(result.details, { exitCode: code, ...(signal === undefined ? {} : { signal }) }, command);
		assert.deepEqual(result.diagnostics, [{ severity: "error", code: "exit_code", message }], command);
		assert.equal(result.structuredOutput.exitCode, code, command);
	}
	// The messages about time, at the real limits: one stopped by the default, one whose own timeout ran out, and how
	// long one that ended by itself took when that was a minute or more.
	const real = { fallback: 120, most: 600 };
	const minute = 60_000;
	assert.equal(
		stoppedMessage(real, undefined, { ms: 2 * minute, printed: true, quietAtEndMs: 1000, longestQuietMs: 1000 }),
		"The command was stopped after 2 minutes, the default time limit for a command. If it needs longer, run it again with a larger `timeout` (in seconds, up to 600), or with `background: true`, which has no time limit, and read its output with the background tool.",
	);
	assert.match(stoppedMessage(real, 300, { ms: 5 * minute, printed: true, quietAtEndMs: 4 * minute, longestQuietMs: 4 * minute }), /^The command was stopped after 5 minutes, the `timeout` this call gave\. It had printed nothing for the last 4 minutes\./);
	assert.match(
		stoppedMessage(real, undefined, { ms: 2 * minute, printed: false, quietAtEndMs: 2 * minute, longestQuietMs: 2 * minute }),
		/^The command was stopped after 2 minutes, the default time limit for a command\. It printed nothing in that time\. A command that goes quiet for that long may be waiting on something, such as a permission prompt on the person's screen/,
	);
	assert.match(stoppedMessage(real, 600), /after 10 minutes, the `timeout` this call gave\. If it needs longer, run it again with `background: true`/);
	// A command moved to the background at its limit (#197) is told which limit, its id, and how to go on with it.
	assert.equal(
		movedMessage(real, 3600, "bg-3", false),
		'The command did not complete within 10 minutes, the longest a command may run unless it is in the background (this call asked for 60 minutes), and was moved to the background as bg-3 rather than stopped. It keeps running there, with no time limit, until it ends, you or the person stop it, the conversation is archived, or pi² stops. It has printed nothing so far. Use the background tool with id "bg-3" to read what it prints from here on (action "read", with `wait` to wait for more) and to stop it (action "stop").',
	);
	assert.equal(tookMessage({ ms: 59_000, printed: false, quietAtEndMs: 59_000, longestQuietMs: 59_000 }), undefined, "a command under a minute says nothing of its time");
	assert.equal(tookMessage({ ms: 1722_000, printed: true, quietAtEndMs: 0, longestQuietMs: 1721_000 }), "The command took 28 minutes 42 seconds, and went 28 minutes 41 seconds without printing anything.");
	assert.equal(tookMessage({ ms: 90_000, printed: false, quietAtEndMs: 90_000, longestQuietMs: 90_000 }), "The command took 1 minute 30 seconds, printing nothing until it ended.");
	assert.equal(tookMessage({ ms: 3 * minute, printed: true, quietAtEndMs: 0, longestQuietMs: 5000 }), "The command took 3 minutes.");

	// Where a long output is kept, and for how long (engine/src/output.ts).
	const { OutputStore, Recorder, KEEP_PER_CONVERSATION, KEEP_DAYS } = await import("../src/output.ts");
	const { keptMessage } = await import("../src/commands.ts");
	const store = new OutputStore(join(folder, "output"));
	const long = Array.from({ length: 3000 }, (_, i) => `line ${i + 1}\n`);
	const recorder = store.record(7, "toolu_01/../x");
	for (const line of long) recorder.add(line);
	const kept = recorder.end(true);
	assert.ok(kept.kept && kept.lines === 3000 && !kept.capped, JSON.stringify(kept));
	assert.equal(kept.path, join(folder, "output", "7", "toolu_01____x.log"), "the call's id cannot lead out of the conversation's folder");
	assert.equal(readFileSync(kept.path, "utf8"), long.join(""));
	assert.match(keptMessage(kept, long.slice(-2000).join(""))!, /^The output is 3,000 lines long; only the last 2,000 are shown\. All of it is in `[^`]+`, for 7 days/);
	// Not shortened: no file, even one started as the output neared the window.
	const fits = store.record(7, "fits");
	for (const line of long.slice(0, 2000)) fits.add(line);
	assert.deepEqual(fits.end(false), { kept: false });
	assert.ok(!existsSync(join(folder, "output", "7", "fits.log")));
	// A file holds the beginning of a very long output only, and says so.
	const capped = new Recorder(join(folder, "output", "7", "capped.log"), 100);
	for (const line of long) capped.add(line);
	const cut = capped.end(true);
	assert.ok(cut.kept && cut.capped && cut.lines === 3000, JSON.stringify(cut));
	assert.equal(readFileSync(cut.path, "utf8"), long.join("").slice(0, 100));
	assert.match(keptMessage(cut, "line 3000\n")!, /Its first 64\.0 MB are in `[^`]+` \(the rest was not kept\)/);
	// Kept: the newest KEEP_PER_CONVERSATION, none older than KEEP_DAYS; a deleted conversation's folder goes.
	const many = join(folder, "output", "8");
	mkdirSync(many, { recursive: true });
	const now = Date.now();
	for (let i = 0; i < KEEP_PER_CONVERSATION + 5; i++) {
		writeFileSync(join(many, `${i}.log`), "x");
		utimesSync(join(many, `${i}.log`), new Date(now - i * 60_000), new Date(now - i * 60_000));
	}
	writeFileSync(join(many, "old.log"), "x");
	utimesSync(join(many, "old.log"), new Date(now - (KEEP_DAYS + 1) * 86_400_000), new Date(now - (KEEP_DAYS + 1) * 86_400_000));
	const untouched = join(folder, "output", "not-a-conversation");
	mkdirSync(untouched);
	store.sweep((id) => id === 7, now);
	assert.ok(!existsSync(join(folder, "output", "7")), "a deleted conversation's files are removed");
	assert.deepEqual(readdirSync(many).sort(), Array.from({ length: KEEP_PER_CONVERSATION }, (_, i) => `${i}.log`).sort(), "the newest are kept, the oldest and the week-old one removed");
	assert.ok(existsSync(untouched), "only folders named for a conversation are touched");
} finally {
	rmSync(folder, { recursive: true, force: true });
}

console.log("exec: ok (output kept when the engine is busy as a command exits; standard input closed; bash tells of its time limits, lowers a timeout above the most and says what to do instead, tells a non-zero exit as a fact unless the command could not start or a signal ended it, tells of running in the background, and of where a long output is kept; kept outputs are bounded)");
process.exit(0); // the background sleep above still holds a pipe
