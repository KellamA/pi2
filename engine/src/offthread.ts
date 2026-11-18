// Short programs the engine runs for itself (git for the branch tracker, `security` for the Keychain, `ps` and `lsof`
// for the processes it started), run from a worker thread of their own instead of the engine's one thread (#344).
//
// Starting a process holds the thread that starts it until the new process is under way. On a quiet Mac that is a
// millisecond or two; with a load of 80 to 140 it was measured at 8 ms in the middle and up to half a second, and the
// engine started dozens a minute: everything the app asked meanwhile, opening a conversation or sending a message,
// waited behind them. Started from a worker, they hold only the worker; the engine's thread was measured to stay within
// 10 ms while the worker started thirty in a row, against 100 ms when it started them itself.
//
// Only programs run to their end and read whole go here. The commands an agent runs stream their output and are
// started where they were.

import { Worker } from "node:worker_threads";

/** Why a program failed, as `execFile` says it: its exit code (or a system error's, such as ENOENT), or the signal that killed it. */
export type RanError = Error & { code: number | string | null; killed: boolean; signal: string | null };
export type Ran = { error: RanError | null; stdout: string; stderr: string };
export type Options = { cwd?: string; env?: NodeJS.ProcessEnv; timeout?: number; maxBuffer?: number; input?: string };

// The worker: runs each program with execFile and posts back how it ended. Plain JavaScript, so it needs nothing loaded.
const WORKER = `
const { parentPort } = require("node:worker_threads");
const { execFile } = require("node:child_process");
parentPort.on("message", ({ id, file, args, options }) => {
	const { input, ...rest } = options;
	let child;
	const reply = (error, stdout, stderr) =>
		parentPort.postMessage({
			id,
			error: error ? { message: error.message, code: error.code ?? null, killed: error.killed === true, signal: error.signal ?? null } : null,
			stdout: String(stdout ?? ""),
			stderr: String(stderr ?? ""),
		});
	try {
		child = execFile(file, args, { ...rest, encoding: "utf8" }, reply);
	} catch (error) {
		reply(error, "", "");
		return;
	}
	// A program that may exit before it reads its input shows that in its exit code, not as a crash here.
	child.stdin?.on("error", () => {});
	child.stdin?.end(input);
});
`;

let worker: Worker | undefined;
let nextId = 1;
const waiting = new Map<number, (ran: Ran) => void>();

function start(): Worker {
	if (worker !== undefined) return worker;
	const started = new Worker(WORKER, { eval: true });
	// It keeps the process running only while a program it runs is awaited, as a child process would.
	started.unref();
	started.on("message", (message: { id: number; error: RanError | null; stdout: string; stderr: string }) => {
		const done = waiting.get(message.id);
		waiting.delete(message.id);
		if (waiting.size === 0) started.unref();
		if (message.error !== null) message.error = Object.assign(new Error(message.error.message), message.error);
		done?.({ error: message.error, stdout: message.stdout, stderr: message.stderr });
	});
	const lost = (why: string) => {
		if (worker === started) worker = undefined;
		for (const [id, done] of waiting) {
			waiting.delete(id);
			done({ error: Object.assign(new Error(why), { code: null, killed: false, signal: null }), stdout: "", stderr: "" });
		}
	};
	started.on("error", (error: Error) => lost(`the engine's worker for programs failed: ${error.message}`));
	started.on("exit", () => lost("the engine's worker for programs stopped"));
	worker = started;
	return started;
}

/**
 * Runs `file` with `args` to its end, off the engine's thread, as `execFile` would: `error` is set when it could not be
 * started, exited with a code other than 0 (`code`), was killed at `timeout` (`killed`), or printed more than
 * `maxBuffer`. `input` is written to its standard input, which is closed after it.
 */
/** `runOffThread` with `execFile`'s callback, for code written for that. */
export function execFileOffThread(file: string, args: readonly string[], options: Options, callback: (error: RanError | null, stdout: string, stderr: string) => void): void {
	void runOffThread(file, args, options).then(({ error, stdout, stderr }) => callback(error, stdout, stderr));
}

export function runOffThread(file: string, args: readonly string[], options: Options = {}): Promise<Ran> {
	const id = nextId++;
	return new Promise((resolve) => {
		const running = start();
		waiting.set(id, resolve);
		running.ref();
		running.postMessage({ id, file, args, options });
	});
}
