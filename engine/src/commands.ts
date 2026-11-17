// An agent's shell command: how long it may run (issue #45), and where the rest of a long output is kept (issue #161).
//
// pi durable's `bash` takes an optional `timeout` and has no default, so a command that never finishes, or waits for
// input that never comes, would hold the run until the person stopped it. This wraps `bash` wherever it is offered: a
// call without `timeout` gets the default limit, and the model is told about the limit in the tool's description and
// when it stops a command. Standard input is already closed: pi durable starts every command with it on /dev/null
// (engine/test/exec.ts checks), so a command that asks a question gets no answer and fails at once.
//
// The limits are Claude Code's (issue #160): 2 minutes unless the call passes `timeout`, and no more than 10 minutes
// whatever it passes. A command that needs longer runs in the background, where the agent and the person can see it is
// still going. The default was 30 minutes, and a command waiting on a system prompt nobody had seen (by the timing, a
// privacy prompt) held its conversation for 29 of them with nothing to show for it.
//
// At the limit, as in Claude Code, a command is moved to the background rather than stopped (issue #197), so the time it
// ran is not lost: it becomes a background command like one started with `background: true` (background.ts `adopt`).
// Only where starting it in the background would not have asked the person (extensions.ts `commandAsks`), so moving it
// never lets something run on that was approved only to be waited for; otherwise, and for a command that only sleeps,
// it is stopped as before. pi durable's `exec` still starts it and passes on its output; the wrap gives it a run marker,
// by which its process is known as it starts (processes.ts `lookOutFor`), keeps the limit itself, and stops it when the
// run is stopped only until it is moved.
//
// The result shows the end of a long output only. The wrap runs the command itself, as pi durable's `bash` does but
// without its spill file in the system's temporary folder (never removed), and keeps the whole output in a file of its
// own instead (output.ts), which the result names whenever it had to shorten the output.
//
// The same wrap gives `bash` its other way of running a command: with `background: true` it is started and left
// running, with no time limit of its own (background.ts).

import { type Context, withAbortSignal, withoutAbortSignal } from "@earendil-works/chord/context";
import { type ToolExecutionApi, type ToolExecutionResult, wrapTool } from "@earendil-works/pi-durable";
import { createBashTool } from "@earendil-works/pi-durable/tools";
import { bool, num, obj, opt, str } from "@earendil-works/pi-schema";
import { constants } from "node:os";
import { join } from "node:path";
import { isDeleted } from "./archive.ts";
import { adopt, BACKGROUND_DESCRIPTION, BACKGROUND_PARAMETER, KEEP_CHARS, startInBackground, WAKE_PARAMETER } from "./background.ts";
import { commandEnvironment } from "./environment.ts";
import { commandAsks } from "./extensions.ts";
import type { Engine, Feature } from "./features.ts";
import { countLines, KEEP_DAYS, type Kept, MAX_FILE_BYTES, OutputStore, type Recorder } from "./output.ts";
import { lookOutFor, newRunMarker, RUN_VARIABLE } from "./processes.ts";
import { runningCommands } from "./running.ts";
import { scratchVariable } from "./scratch.ts";
import { agentVariables } from "./variables.ts";

/** How long a command in the foreground may run, in seconds: `fallback` when its call names no `timeout`, and `most` whatever it names. */
export type Limits = { fallback: number; most: number };

/** The limit for a command whose call names none: 2 minutes, as Claude Code's. Tests shorten it with PI2_COMMAND_TIMEOUT_SECONDS. */
export const DEFAULT_COMMAND_TIMEOUT_SECONDS = (() => {
	const seconds = Number(process.env.PI2_COMMAND_TIMEOUT_SECONDS);
	return Number.isFinite(seconds) && seconds > 0 ? seconds : 2 * 60;
})();

/** The most a call's `timeout` may give a command in the foreground: 10 minutes, as Claude Code's, or the default if that is longer. */
export const MAX_COMMAND_TIMEOUT_SECONDS = Math.max(10 * 60, DEFAULT_COMMAND_TIMEOUT_SECONDS);

const LIMITS: Limits = { fallback: DEFAULT_COMMAND_TIMEOUT_SECONDS, most: MAX_COMMAND_TIMEOUT_SECONDS };

/** "2 minutes", "90 seconds", "1 second". */
export function duration(seconds: number): string {
	const [count, unit] = seconds >= 60 && seconds % 60 === 0 ? [seconds / 60, "minute"] : [seconds, "second"];
	return `${count} ${unit}${count === 1 ? "" : "s"}`;
}

/** A time the clock measured: "45 seconds", "3 minutes 12 seconds", "2 minutes". */
export function elapsed(ms: number): string {
	const seconds = Math.round(ms / 1000);
	if (seconds < 60) return duration(seconds);
	const rest = seconds % 60;
	return rest === 0 ? duration(seconds) : `${duration(seconds - rest)} ${duration(rest)}`;
}

/** The longest `timeout` Node's timers take, as pi durable's `bash` checks it. */
const MAX_TIMEOUT_SECONDS = 2_147_483_647 / 1000;

/**
 * What the model is told the tool does. Short, since it is read again on every turn; it says what the shell is not for,
 * because agents read files through it (`cat`, `sed -n`) far more often than with `read`, began most commands with a
 * `cd` to the folder they were already in, and cut a third of their outputs with `head` or `tail` (#162). Finding and
 * searching files is pointed to from `find_files` and `search_files` themselves, which an agent may not be offered (#221).
 */
export function describe(limits: Limits): string {
	return (
		"Run a bash command; returns its stdout and stderr together. " +
		"Every command starts in the conversation's folder, so there is no need to `cd` to it (a `cd` does not carry over to the next command). " +
		"Not for reading files (`read` takes several at once) or changing them (`edit`, `write`). " +
		`A long output is shortened to its last 2000 lines or 50KB, and the whole of it is kept for ${KEEP_DAYS} days in a file the result names, to read with \`read\` or search with \`grep\`: ` +
		"so do not cut an output short with `head`, `tail` or `grep`, which loses the rest. " +
		`A command has ${duration(limits.fallback)} unless you pass \`timeout\` in seconds, up to ${duration(limits.most)}. ` +
		"One not finished by then is moved to the background, and the result gives its id for the background tool; it is stopped instead where that would need the person's approval, or when it starts with `sleep`. " +
		`For one you know may take longer (a full test suite, a build), use \`background: true\` from the start, which has no time limit. ` +
		"Standard input is closed, so a command that asks a question fails instead of waiting for an answer: give answers as options or through a pipe. " +
		BACKGROUND_DESCRIPTION
	);
}

function parameters(limits: Limits) {
	return obj(
		{
			command: str({ description: "Bash command to execute" }),
			timeout: opt(
				num({
					description: `Timeout in seconds. Default ${limits.fallback} (${duration(limits.fallback)}), at most ${limits.most} (${duration(limits.most)}); pass a larger one for a command known to take longer. A background command has no time limit unless one is passed, and then it may be longer than ${duration(limits.most)}.`,
				}),
			),
			background: opt(bool({ description: BACKGROUND_PARAMETER })),
			wake: opt(bool({ description: WAKE_PARAMETER })),
		},
		{ open: true },
	);
}

/** How long a command ran and how it printed, for what the result says about the time it took. */
export type Timing = { ms: number; printed: boolean; quietAtEndMs: number; longestQuietMs: number };

/** A minute without output is worth telling the agent about: it may be waiting on something. */
const QUIET_MS = 60_000;

/**
 * What the model reads when the limit stopped a command, under whatever output it had written: which limit, whether it
 * had gone quiet, and what to do instead. `given` is the call's own `timeout`, if it gave one.
 */
export function stoppedMessage(limits: Limits, given: number | undefined, timing?: Timing, notMoved?: string): string {
	const why = limitOf(limits, given);
	const quiet =
		timing === undefined || timing.ms < QUIET_MS
			? ""
			: !timing.printed
				? " It printed nothing in that time."
				: timing.quietAtEndMs >= QUIET_MS
					? ` It had printed nothing for the last ${elapsed(timing.quietAtEndMs)}.`
					: "";
	const waiting = quiet === "" ? "" : " A command that goes quiet for that long may be waiting on something, such as a permission prompt on the person's screen or a slow network folder; run again, it may wait again.";
	const instead =
		(given ?? limits.fallback) >= limits.most
			? "If it needs longer, run it again with `background: true`, which has no time limit, and read its output with the background tool."
			: `If it needs longer, run it again with a larger \`timeout\` (in seconds, up to ${limits.most}), or with \`background: true\`, which has no time limit, and read its output with the background tool.`;
	return `The command was stopped after ${why}.${quiet}${waiting}${notMoved === undefined ? "" : ` ${notMoved}`} ${instead}`;
}

/** Which limit a command reached: "2 minutes, the default time limit for a command". `given` is the call's own `timeout`. */
function limitOf(limits: Limits, given: number | undefined): string {
	if (given === undefined) return `${duration(limits.fallback)}, the default time limit for a command`;
	if (given > limits.most) return `${duration(limits.most)}, the longest a command may run unless it is in the background (this call asked for ${duration(given)})`;
	return `${duration(given)}, the \`timeout\` this call gave`;
}

/**
 * What the model reads when a command reached its limit and was moved to the background instead of being stopped, under
 * what it had printed by then (issue #197). Claude Code says "Command did not complete within its 120s timeout and was
 * moved to the background", with the task's id; this says the same, and how to go on with it.
 */
export function movedMessage(limits: Limits, given: number | undefined, id: string, printed: boolean): string {
	return (
		`The command did not complete within ${limitOf(limits, given)}, and was moved to the background as ${id} rather than stopped. ` +
		"It keeps running there, with no time limit, until it ends, you or the person stop it, the conversation is archived, or pi² stops. " +
		`${printed ? "What it printed until now is above." : "It has printed nothing so far."} ` +
		`Use the background tool with id "${id}" to read what it prints from here on (action "read", with \`wait\` to wait for more) and to stop it (action "stop").`
	);
}

/** The result of a command moved to the background at its limit: what it printed until then, and what became of it. */
async function moved(
	store: OutputStore | undefined,
	limits: Limits,
	given: number | undefined,
	adopted: { id: string; recorded: Promise<void>; answer: (sawTheEnd: boolean) => void },
	api: ToolExecutionApi,
	conversationId: number,
	recorder: Recorder | undefined,
): Promise<ToolExecutionResult> {
	try {
		// As the call that starts a background command does, this one answers once the command's process is on record.
		await adopted.recorded;
		const retained = api.retainedOutput();
		// The file has what it printed in the foreground; what it prints from here on is the background tool's to read.
		const kept = recorder?.end(retained.truncated);
		if (kept?.kept) store?.prune(conversationId);
		const message = kept === undefined ? undefined : keptMessage(kept, retained.text);
		if (message !== undefined) api.diagnostic({ severity: "info", code: "full_output", message });
		api.diagnostic({ severity: "info", code: "moved_to_background", message: movedMessage(limits, given, adopted.id, retained.text !== "") });
		return {
			details: { background: { id: adopted.id, status: "running" } },
			// What a script calling `bash` gets, as for a command started in the background.
			structuredOutput: { output: retained.text, truncated: retained.truncated, ...(kept?.kept ? { fullOutputPath: kept.path } : {}), exitCode: 0, background: adopted.id },
		};
	} finally {
		adopted.answer(false);
	}
}

/** What the result of a command that ended by itself says about a long run: how long, and how long it went quiet. */
export function tookMessage(timing: Timing): string | undefined {
	if (timing.ms < QUIET_MS) return undefined;
	const quiet = !timing.printed ? ", printing nothing until it ended" : timing.longestQuietMs >= QUIET_MS ? `, and went ${elapsed(timing.longestQuietMs)} without printing anything` : "";
	return `The command took ${elapsed(timing.ms)}${quiet}.`;
}

/**
 * What the result of a command that ran to its end says about its exit code (#182). A command line's exit code is the
 * last command's, and a non-zero one is often no failure at all: a `grep` that found nothing, `gh pr checks` with checks
 * still pending, an `a && b` that stopped where it was meant to. So it is told to the model as a fact, and the result is
 * not an error, unless the code says the command could not be started (126, not executable; 127, not found) or was
 * ended by a signal (128 and the signal's number, as the shell and pi durable report it). `details.exitCode` lets the
 * conversation show the code on the row. A command stopped at its time limit, or aborted, has no exit code: it throws.
 */
export function exitResult(exitCode: number): { isError?: true; details?: { exitCode: number; signal?: string }; diagnostics?: { severity: "info" | "error"; code: string; message: string }[] } {
	if (exitCode === 0) return {};
	const signal = exitCode > 128 ? Object.entries(constants.signals).find(([, number]) => number === exitCode - 128)?.[0] : undefined;
	const failed =
		signal !== undefined
			? `The command was ended by ${signal} (exit code ${exitCode}).`
			: exitCode === 127
				? "Exit code 127: a command it ran was not found."
				: exitCode === 126
					? "Exit code 126: a command it ran could not be run (it is not executable, or not allowed)."
					: undefined;
	const details = { exitCode, ...(signal === undefined ? {} : { signal }) };
	if (failed !== undefined) return { isError: true, details, diagnostics: [{ severity: "error", code: "exit_code", message: failed }] };
	return { details, diagnostics: [{ severity: "info", code: "exit_code", message: `Exit code ${exitCode}` }] };
}

const count = (n: number) => n.toLocaleString("en-US");
const size = (bytes: number) => (bytes < 1024 * 1024 ? `${Math.max(1, Math.round(bytes / 1024))} KB` : `${(bytes / (1024 * 1024)).toFixed(1)} MB`);

/** What the result says about an output it had to shorten: how much is shown, and where the rest is. */
export function keptMessage(kept: Kept, shown: string): string | undefined {
	if (!("lines" in kept)) return undefined;
	const shownLines = countLines(shown);
	const part =
		shownLines < kept.lines
			? `The output is ${count(kept.lines)} lines long; only the last ${count(shownLines)} are shown.`
			: `The output is ${size(kept.bytes)}; only the last ${size(Buffer.byteLength(shown))} of it are shown.`;
	if (!kept.kept) return `${part} The rest could not be kept (${kept.failed}).`;
	const where = kept.capped ? `Its first ${size(MAX_FILE_BYTES)} are in \`${kept.path}\` (the rest was not kept)` : `All of it is in \`${kept.path}\``;
	return `${part} ${where}, for ${KEEP_DAYS} days: read it with \`read\` (\`offset\`, \`limit\`) or search it with \`grep\`, rather than running the command again.`;
}

/**
 * What `bash` needs to move a command that reached its time limit to the background rather than stop it: whether
 * starting it there would ask the person (extensions.ts). Without it, as in a test of the wrap alone, it is stopped.
 */
export type HandOver = { asks(api: ToolExecutionApi, command: string, context: Context): Promise<boolean> };

/** A command that only waits, which Claude Code stops at its limit rather than move: nothing is gained by keeping it. */
const onlyWaits = (command: string) => /^\s*sleep(\s|$)/.test(command);

/** pi durable's `bash`, run without its spill file: the output goes to `store` as well as to the result. */
async function run(store: OutputStore | undefined, limits: Limits, args: { command: string; timeout?: number }, api: ToolExecutionApi, context: Context, handOver?: HandOver): Promise<ToolExecutionResult> {
	const given = args.timeout;
	if (given !== undefined && (!Number.isFinite(given) || given <= 0)) throw new Error("Invalid timeout: must be a finite number of seconds");
	// A longer one is lowered to the most, as Claude Code does: a call asking for more is often only being generous.
	const timeout = Math.min(given ?? limits.fallback, limits.most, MAX_TIMEOUT_SECONDS);
	const env = api.env;
	if (env === undefined) throw new Error("No execution environment is configured");
	const conversationId = api.conversationId as unknown as number;
	// The variables the person gave the conversation's agent (variables.ts); read before anything starts, since reading
	// them can fail, and then the command is not run.
	const variables = await agentVariables(conversationId);
	const recorder = store?.record(conversationId, api.callId);
	const started = Date.now();
	let lastPrinted: number | undefined;
	let longestQuietMs = 0;
	// A marker of this run in the command's environment, as a background command has (background.ts): it tells this
	// command's process apart as it is started, and is what the next engine knows what it started by, should the command
	// move to the background and this engine die.
	const marker = newRunMarker();
	const watched = handOver === undefined ? undefined : lookOutFor(marker);
	// The end of what it has printed, and how much in all: where its output starts from should it move to the background.
	let tail = "";
	let total = 0;
	/** Where its output goes once it is in the background. */
	let movedTo: ((chunk: string) => void) | undefined;
	// What stops it: the run being stopped, until it moves to the background and no longer belongs to the run, and the
	// time limit, which this wrap keeps rather than `exec`, so that at the limit it can be moved instead.
	const own = new AbortController();
	const forward = () => own.abort();
	if (context.abortSignal?.aborted) own.abort();
	else context.abortSignal?.addEventListener("abort", forward, { once: true });
	// For the person: how long it has run, and how long since it printed (running.ts). Ended in the `finally` below.
	const clock = runningCommands.begin(conversationId, api.callId, args.command, started);
	const execution = env.exec(
		args.command,
		{
			cwd: env.cwd,
			// The engine's environment less pi²'s own settings, such as its data folder (issue #195), with the agent's own
			// variables (issue #96) and the conversation's scratch folder (issue #180).
			env: commandEnvironment({ ...variables, ...scratchVariable(conversationId), [RUN_VARIABLE]: marker }),
			inheritEnv: false,
			// No `window`: every chunk is wanted for the file, not only the tail the result keeps.
			onOutput: (text, _context, info) => {
				if (movedTo !== undefined) return movedTo(text);
				const now = Date.now();
				longestQuietMs = Math.max(longestQuietMs, now - (lastPrinted ?? started));
				lastPrinted = now;
				api.output(text, info.skipped);
				recorder?.add(text);
				clock.printed();
				if (watched === undefined) return;
				tail += text;
				total += text.length;
				if (tail.length > 2 * KEEP_CHARS) tail = tail.slice(-KEEP_CHARS);
			},
		},
		withAbortSignal(own.signal, withoutAbortSignal(context)),
	);
	let timer: ReturnType<typeof setTimeout> | undefined;
	const limit = new Promise<"limit">((resolve) => (timer = setTimeout(() => resolve("limit"), timeout * 1000)));
	let timedOut = false;
	let notMoved: string | undefined;
	let result: Awaited<typeof execution>;
	try {
		const first = await Promise.race([execution, limit]);
		if (first !== "limit") result = first;
		else {
			const child = watched?.child();
			if (child !== undefined && (child.exitCode !== null || child.signalCode !== null)) {
				// It ended just as the limit came: its result is on its way.
				result = await execution;
			} else {
				const asks = handOver === undefined || child === undefined || onlyWaits(args.command) ? undefined : await handOver.asks(api, args.command, context).catch(() => true);
				if (asks === true) notMoved = "It was not moved to the background, as starting a command there needs the person's approval in this conversation.";
				const adopted =
					asks !== false || child === undefined
						? undefined
						: await adopt({
								child,
								marker,
								command: args.command,
								cwd: env.cwd,
								conversationId,
								startedAt: started,
								printed: () => ({ output: tail, total }),
								route: (keep) => {
									movedTo = keep;
									context.abortSignal?.removeEventListener("abort", forward);
								},
								wanted: () => !own.signal.aborted,
							});
				if (adopted !== undefined) return await moved(store, limits, given, adopted, api, conversationId, recorder);
				if (child !== undefined && (child.exitCode !== null || child.signalCode !== null)) result = await execution;
				else {
					timedOut = true;
					own.abort();
					result = await execution;
				}
			}
		}
	} finally {
		clearTimeout(timer);
		watched?.done();
		if (movedTo === undefined) context.abortSignal?.removeEventListener("abort", forward);
		// Ended, stopped, or moved to the background, where it has a row of its own: no longer running here.
		clock.end();
	}
	const ended = Date.now();
	const quietAtEndMs = ended - (lastPrinted ?? started);
	const timing: Timing = { ms: ended - started, printed: lastPrinted !== undefined, quietAtEndMs, longestQuietMs: Math.max(longestQuietMs, quietAtEndMs) };
	const retained = api.retainedOutput();
	const kept = recorder?.end(retained.truncated);
	if (kept?.kept) store?.prune(conversationId);
	const message = kept === undefined ? undefined : keptMessage(kept, retained.text);
	if (message !== undefined) api.diagnostic({ severity: "info", code: "full_output", message });
	if (!result.ok) {
		if (result.error.code === "aborted" && context.abortSignal?.aborted) throw result.error;
		if (timedOut || result.error.code === "timeout") throw new Error(stoppedMessage(limits, given, timing, notMoved));
		if (result.error.code === "aborted") throw new Error("Command aborted");
		throw result.error;
	}
	const took = tookMessage(timing);
	if (took !== undefined) api.diagnostic({ severity: "info", code: "took", message: took });
	const exitCode = result.value.exitCode;
	// What a script calling `bash` gets, as pi durable's `bash` gives it.
	const structuredOutput = { output: retained.text, truncated: retained.truncated, ...(kept?.kept ? { fullOutputPath: kept.path } : {}), exitCode };
	return { structuredOutput, ...exitResult(exitCode) };
}

/**
 * The wrap of `bash` with these limits, keeping long outputs in `store`, and moving a command that reaches its limit to
 * the background when `handOver` says it may. Tests make one with limits of their own.
 */
export const shell = (store: OutputStore | undefined, limits: Limits = LIMITS, handOver?: HandOver) =>
	wrapTool(createBashTool(), (bash) => ({
		...bash,
		description: describe(limits),
		parameters: parameters(limits),
		execute: async (args, api, context) => {
			// Left running rather than waited for, so the limits are not for it.
			// (The library's own type for the arguments does not know the parameter this wrap adds.)
			if ((args as { background?: unknown }).background === true) return await startInBackground(args, api, context);
			return await run(store, limits, args, api, context, handOver);
		},
	}));

export const commands: Feature = (host, engine: Engine | undefined) => {
	// Without an engine (a test of the description), nothing is kept, and a command is never moved to the background.
	const store = engine === undefined ? undefined : new OutputStore(join(engine.home, "output"));
	const handOver: HandOver | undefined =
		engine === undefined || host === undefined ? undefined : { asks: (api, command, context) => commandAsks(host, api.conversationId, command, api, context) };
	const sweep = () => {
		try {
			store?.sweep((id) => isDeleted(engine?.library().conversations[String(id)]));
		} catch (error) {
			engine?.log("kept command output could not be tidied:", error instanceof Error ? error.message : error);
		}
	};
	let daily: NodeJS.Timeout | undefined;
	return {
		wraps: [shell(store, LIMITS, handOver)],
		start: async () => {
			sweep();
			daily = setInterval(sweep, 86_400_000);
			daily.unref();
		},
		putAwayChanged: sweep,
		stopping: async () => clearInterval(daily),
	};
};
