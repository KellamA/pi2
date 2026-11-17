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
// The result shows the end of a long output only. The wrap runs the command itself, as pi durable's `bash` does but
// without its spill file in the system's temporary folder (never removed), and keeps the whole output in a file of its
// own instead (output.ts), which the result names whenever it had to shorten the output.
//
// The same wrap gives `bash` its other way of running a command: with `background: true` it is started and left
// running, with no time limit of its own (background.ts).

import type { Context } from "@earendil-works/chord/context";
import { type ToolExecutionApi, type ToolExecutionResult, wrapTool } from "@earendil-works/pi-durable";
import { createBashTool } from "@earendil-works/pi-durable/tools";
import { bool, num, obj, opt, str } from "@earendil-works/pi-schema";
import { join } from "node:path";
import { isDeleted } from "./archive.ts";
import { BACKGROUND_DESCRIPTION, BACKGROUND_PARAMETER, startInBackground } from "./background.ts";
import type { Engine, Feature } from "./features.ts";
import { countLines, KEEP_DAYS, type Kept, MAX_FILE_BYTES, OutputStore } from "./output.ts";

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

/** What the model is told the tool does. */
export function describe(limits: Limits): string {
	return (
		"Execute a bash command in the current working directory. Returns combined stdout and stderr. " +
		"A long output is shortened to its last 2000 lines or 50KB, whichever is less, and then the whole of it is kept in a file whose path the result gives: " +
		`read the rest there with \`read\` (\`offset\`, \`limit\`) or search it with \`grep\`. The file is kept for ${KEEP_DAYS} days. ` +
		"So do not cut a command's output short yourself with `head`, `tail` or `grep`: what you cut is not kept, and getting it back means running the command again. " +
		`A command is stopped after ${duration(limits.fallback)} unless you pass \`timeout\` in seconds, which can give it up to ${duration(limits.most)}. ` +
		`For one that may take longer (a full test suite, a build), use \`background: true\`, which has no time limit. ` +
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
export function stoppedMessage(limits: Limits, given: number | undefined, timing?: Timing): string {
	const capped = given !== undefined && given > limits.most;
	const why =
		given === undefined
			? `${duration(limits.fallback)}, the default time limit for a command`
			: capped
				? `${duration(limits.most)}, the longest a command may run unless it is in the background (this call asked for ${duration(given)})`
				: `${duration(given)}, the \`timeout\` this call gave`;
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
	return `The command was stopped after ${why}.${quiet}${waiting} ${instead}`;
}

/** What the result of a command that ended by itself says about a long run: how long, and how long it went quiet. */
export function tookMessage(timing: Timing): string | undefined {
	if (timing.ms < QUIET_MS) return undefined;
	const quiet = !timing.printed ? ", printing nothing until it ended" : timing.longestQuietMs >= QUIET_MS ? `, and went ${elapsed(timing.longestQuietMs)} without printing anything` : "";
	return `The command took ${elapsed(timing.ms)}${quiet}.`;
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

/** pi durable's `bash`, run without its spill file: the output goes to `store` as well as to the result. */
async function run(store: OutputStore | undefined, limits: Limits, args: { command: string; timeout?: number }, api: ToolExecutionApi, context: Context): Promise<ToolExecutionResult> {
	const given = args.timeout;
	if (given !== undefined && (!Number.isFinite(given) || given <= 0)) throw new Error("Invalid timeout: must be a finite number of seconds");
	// A longer one is lowered to the most, as Claude Code does: a call asking for more is often only being generous.
	const timeout = Math.min(given ?? limits.fallback, limits.most, MAX_TIMEOUT_SECONDS);
	const env = api.env;
	if (env === undefined) throw new Error("No execution environment is configured");
	const conversationId = api.conversationId as unknown as number;
	const recorder = store?.record(conversationId, api.callId);
	const started = Date.now();
	let lastPrinted: number | undefined;
	let longestQuietMs = 0;
	const result = await env.exec(
		args.command,
		{
			cwd: env.cwd,
			env: {},
			inheritEnv: true,
			timeout,
			// No `window`: every chunk is wanted for the file, not only the tail the result keeps.
			onOutput: (text, _context, info) => {
				const now = Date.now();
				longestQuietMs = Math.max(longestQuietMs, now - (lastPrinted ?? started));
				lastPrinted = now;
				api.output(text, info.skipped);
				recorder?.add(text);
			},
		},
		context,
	);
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
		if (result.error.code === "timeout") throw new Error(stoppedMessage(limits, given, timing));
		if (result.error.code === "aborted") throw new Error("Command aborted");
		throw result.error;
	}
	const took = tookMessage(timing);
	if (took !== undefined) api.diagnostic({ severity: "info", code: "took", message: took });
	const exitCode = result.value.exitCode;
	// What a script calling `bash` gets, as pi durable's `bash` gives it.
	const structuredOutput = { output: retained.text, truncated: retained.truncated, ...(kept?.kept ? { fullOutputPath: kept.path } : {}), exitCode };
	if (exitCode === 0) return { structuredOutput };
	return { structuredOutput, isError: true, diagnostics: [{ severity: "error", code: "exit_code", message: `Command exited with code ${exitCode}` }] };
}

/** The wrap of `bash` with these limits, keeping long outputs in `store`. Tests make one with limits of their own. */
export const shell = (store: OutputStore | undefined, limits: Limits = LIMITS) =>
	wrapTool(createBashTool(), (bash) => ({
		...bash,
		description: describe(limits),
		parameters: parameters(limits),
		execute: async (args, api, context) => {
			// Left running rather than waited for, so the limits are not for it.
			// (The library's own type for the arguments does not know the parameter this wrap adds.)
			if ((args as { background?: unknown }).background === true) return await startInBackground(args, api, context);
			return await run(store, limits, args, api, context);
		},
	}));

export const commands: Feature = (_host, engine: Engine | undefined) => {
	// Without an engine (a test of the description), nothing is kept.
	const store = engine === undefined ? undefined : new OutputStore(join(engine.home, "output"));
	const sweep = () => {
		try {
			store?.sweep((id) => isDeleted(engine?.library().conversations[String(id)]));
		} catch (error) {
			engine?.log("kept command output could not be tidied:", error instanceof Error ? error.message : error);
		}
	};
	let daily: NodeJS.Timeout | undefined;
	return {
		wraps: [shell(store)],
		start: async () => {
			sweep();
			daily = setInterval(sweep, 86_400_000);
			daily.unref();
		},
		putAwayChanged: sweep,
		stopping: async () => clearInterval(daily),
	};
};
