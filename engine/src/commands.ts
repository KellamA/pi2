// An agent's shell command: how long it may run (issue #45), and where the rest of a long output is kept (issue #161).
//
// pi durable's `bash` takes an optional `timeout` and has no default, so a command that never finishes, or waits for
// input that never comes, would hold the run until the person stopped it. This wraps `bash` wherever it is offered: a
// call without `timeout` gets the default limit, and the model is told about the limit in the tool's description and
// when it stops a command. Standard input is already closed: pi durable starts every command with it on /dev/null
// (engine/test/exec.ts checks), so a command that asks a question gets no answer and fails at once.
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

/** The limit for a command whose call names none: 30 minutes. Tests shorten it with PI2_COMMAND_TIMEOUT_SECONDS. */
export const DEFAULT_COMMAND_TIMEOUT_SECONDS = (() => {
	const seconds = Number(process.env.PI2_COMMAND_TIMEOUT_SECONDS);
	return Number.isFinite(seconds) && seconds > 0 ? seconds : 30 * 60;
})();

/** "30 minutes", "90 seconds", "1 second". */
export function duration(seconds: number): string {
	const [count, unit] = seconds >= 60 && seconds % 60 === 0 ? [seconds / 60, "minute"] : [seconds, "second"];
	return `${count} ${unit}${count === 1 ? "" : "s"}`;
}

const LIMIT = duration(DEFAULT_COMMAND_TIMEOUT_SECONDS);

/** The longest `timeout` Node's timers take, as pi durable's `bash` checks it. */
const MAX_TIMEOUT_SECONDS = 2_147_483_647 / 1000;

export const DESCRIPTION =
	"Execute a bash command in the current working directory. Returns combined stdout and stderr. " +
	"A long output is shortened to its last 2000 lines or 50KB, whichever is less, and then the whole of it is kept in a file whose path the result gives: " +
	`read the rest there with \`read\` (\`offset\`, \`limit\`) or search it with \`grep\`. The file is kept for ${KEEP_DAYS} days. ` +
	"So do not cut a command's output short yourself with `head`, `tail` or `grep`: what you cut is not kept, and getting it back means running the command again. " +
	`A command is stopped after ${LIMIT} unless you pass \`timeout\`; for a command you know takes longer, pass a larger one. ` +
	"Standard input is closed, so a command that asks a question fails instead of waiting for an answer: give answers as options or through a pipe. " +
	BACKGROUND_DESCRIPTION;

const PARAMETERS = obj(
	{
		command: str({ description: "Bash command to execute" }),
		timeout: opt(num({ description: `Timeout in seconds. Default ${DEFAULT_COMMAND_TIMEOUT_SECONDS} (${LIMIT}); pass a larger one for a command known to take longer. A background command has none unless one is passed.` })),
		background: opt(bool({ description: BACKGROUND_PARAMETER })),
	},
	{ open: true },
);

/** What the model reads when the limit stopped a command, under whatever output it had written. */
export function stoppedMessage(timeout: number | undefined): string {
	const why = timeout === undefined ? `${LIMIT}, the default time limit for a command` : `${duration(timeout)}, the \`timeout\` this call gave`;
	return `The command was stopped after ${why}. If it needs longer, run it again with a larger \`timeout\` (in seconds).`;
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
async function run(store: OutputStore | undefined, args: { command: string; timeout: number; given: number | undefined }, api: ToolExecutionApi, context: Context): Promise<ToolExecutionResult> {
	if (!Number.isFinite(args.timeout) || args.timeout <= 0) throw new Error("Invalid timeout: must be a finite number of seconds");
	if (args.timeout > MAX_TIMEOUT_SECONDS) throw new Error(`Invalid timeout: maximum is ${MAX_TIMEOUT_SECONDS} seconds`);
	const env = api.env;
	if (env === undefined) throw new Error("No execution environment is configured");
	const conversationId = api.conversationId as unknown as number;
	const recorder = store?.record(conversationId, api.callId);
	const result = await env.exec(
		args.command,
		{
			cwd: env.cwd,
			env: {},
			inheritEnv: true,
			timeout: args.timeout,
			// No `window`: every chunk is wanted for the file, not only the tail the result keeps.
			onOutput: (text, _context, info) => {
				api.output(text, info.skipped);
				recorder?.add(text);
			},
		},
		context,
	);
	const retained = api.retainedOutput();
	const kept = recorder?.end(retained.truncated);
	if (kept?.kept) store?.prune(conversationId);
	const message = kept === undefined ? undefined : keptMessage(kept, retained.text);
	if (message !== undefined) api.diagnostic({ severity: "info", code: "full_output", message });
	if (!result.ok) {
		if (result.error.code === "aborted" && context.abortSignal?.aborted) throw result.error;
		if (result.error.code === "timeout") throw new Error(stoppedMessage(args.given));
		if (result.error.code === "aborted") throw new Error("Command aborted");
		throw result.error;
	}
	const exitCode = result.value.exitCode;
	// What a script calling `bash` gets, as pi durable's `bash` gives it.
	const structuredOutput = { output: retained.text, truncated: retained.truncated, ...(kept?.kept ? { fullOutputPath: kept.path } : {}), exitCode };
	if (exitCode === 0) return { structuredOutput };
	return { structuredOutput, isError: true, diagnostics: [{ severity: "error", code: "exit_code", message: `Command exited with code ${exitCode}` }] };
}

const shell = (store: OutputStore | undefined) =>
	wrapTool(createBashTool(), (bash) => ({
		...bash,
		description: DESCRIPTION,
		parameters: PARAMETERS,
		execute: async (args, api, context) => {
			// Left running rather than waited for, so the default limit is not for it.
			// (The library's own type for the arguments does not know the parameter this wrap adds.)
			if ((args as { background?: unknown }).background === true) return await startInBackground(args, api, context);
			return await run(store, { command: args.command, timeout: args.timeout ?? DEFAULT_COMMAND_TIMEOUT_SECONDS, given: args.timeout }, api, context);
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
