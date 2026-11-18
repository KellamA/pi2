// Working things out with code: `run_code` runs a short JavaScript program and returns what it printed (#286).
//
// It is a built-in tool off by default (builtins.ts, key `code`): the chat assistant is given it, and an agent whose
// settings turn it on. The program runs in the same sandbox code mode's scripts run in (pi-codemode's QuickJS, in a
// worker thread), but with no tools to call: QuickJS has no `require`, `import`, `fetch`, timers or `process`, and its
// WASI shim offers a clock, randomness and a discarded standard output, nothing else, so a program has no way to the
// files, the network or anything else on the Mac. That is why it never asks for approval, and why it is not one of the
// tools that run in order (order.ts): it changes nothing. A program that never ends is stopped at its time limit, and
// its worker thread with it.
//
// See docs/code.md.

import type { Context } from "@earendil-works/chord/context";
import { type CodemodeOutputItem, type CodemodeResult, CodemodeSandbox, type CodemodeSandboxOptions } from "@earendil-works/pi-codemode";
import { defineTool } from "@earendil-works/pi-durable";
import { int, obj, opt, str } from "@earendil-works/pi-schema";
import type { Feature } from "./features.ts";

/** Seconds a program may run unless the call says otherwise, and the most it may ask for. */
export const DEFAULT_SECONDS = 30;
export const MAX_SECONDS = 120;
/** What a program may allocate; beyond it, an allocation fails in the program as `InternalError: out of memory`. */
const MEMORY_BYTES = 64 * 1024 * 1024;
/** The most of a program's output the model is given: its start and its end, with how much was left out between. */
export const MAX_OUTPUT_CHARS = 30_000;

export type Block = { type: "text"; text: string } | { type: "image"; data: string; mimeType: string };

/** `value` as the program's `return` gave it: strings as they are, anything else as JSON. */
function valueText(value: unknown): string {
	if (typeof value === "string") return value;
	try {
		return JSON.stringify(value) ?? String(value);
	} catch {
		return String(value);
	}
}

/** Text no longer than `MAX_OUTPUT_CHARS`, keeping its start and end. */
export function shorten(text: string): string {
	if (text.length <= MAX_OUTPUT_CHARS) return text;
	const half = Math.floor(MAX_OUTPUT_CHARS / 2);
	const left = text.length - 2 * half;
	return `${text.slice(0, half)}\n[… ${left.toLocaleString("en-US")} characters left out …]\n${text.slice(-half)}`;
}

/** What the model is given for a finished program: what it printed, in order, then what it returned or why it failed. */
export function resultBlocks(result: CodemodeResult, seconds: number): { blocks: Block[]; isError: boolean } {
	const lines: string[] = [];
	const images: Block[] = [];
	for (const item of result.output as CodemodeOutputItem[]) {
		if (item.type === "text") lines.push(item.text);
		else images.push({ type: "image", data: item.data, mimeType: item.mimeType });
	}
	let ending: string | undefined;
	if (result.ok) {
		if (result.value !== undefined) ending = `Returned: ${valueText(result.value)}`;
	} else if (result.error.kind === "script") {
		ending = result.error.stack ?? `${result.error.name ?? "Error"}: ${result.error.message}`;
	} else if (result.error.kind === "timeout") {
		ending = `The program was stopped after ${seconds} seconds, its time limit. Make it do less, or pass a larger timeout (${MAX_SECONDS} at most).`;
	} else if (result.error.kind === "aborted") {
		ending = "The program was stopped.";
	} else {
		ending = `The sandbox failed: ${result.error.message}`;
	}
	const printed = lines.join("\n");
	const text = [printed === "" && ending === undefined ? "The program printed nothing and returned nothing." : printed, ending].filter((part) => part !== undefined && part !== "").join("\n");
	return { blocks: [{ type: "text", text: shorten(text) }, ...images], isError: !result.ok };
}

const DESCRIPTION =
	"Run a short JavaScript program and get back what it printed: for arithmetic, dates, counting, converting or checking data, " +
	"anything better worked out than guessed. `code` is the body of an async function: `console.log()` prints, `return` gives a value, " +
	"top-level `await` works. It runs in a sandbox with no access to files, the network or any other tool: there is no `require`, " +
	`\`import\`, \`fetch\`, \`process\` or timers. It is stopped after \`timeout\` seconds (${DEFAULT_SECONDS} unless given, ${MAX_SECONDS} at most) ` +
	"and can use 64 MB of memory. Nothing is kept between calls.";

/** The sandbox programs run in: no tools, no globals beyond the language's own and the output helpers. */
export function codeSandbox(extra: Pick<CodemodeSandboxOptions, "onWorkerStarted"> = {}): CodemodeSandbox {
	return new CodemodeSandbox({ ...extra, tools: [], globals: [], memoryLimitBytes: MEMORY_BYTES, timeoutMs: DEFAULT_SECONDS * 1000 });
}

/** Run `code` for at most `timeout` seconds (the default when absent), and what the model is given for it. */
export async function runProgram(sandbox: CodemodeSandbox, code: string, timeout?: number, signal?: AbortSignal): Promise<{ blocks: Block[]; isError: boolean; ok: boolean }> {
	const seconds = Math.min(MAX_SECONDS, Math.max(1, Math.round(timeout ?? DEFAULT_SECONDS)));
	const result = await sandbox.execute(code, { timeoutMs: seconds * 1000, ...(signal === undefined ? {} : { signal }) });
	return { ...resultBlocks(result, seconds), ok: result.ok };
}

export const runCode: Feature = () => {
	// One sandbox for every call: each run gets a VM, in a worker thread, of its own. Closed when the engine stops.
	const sandbox = codeSandbox();
	const tool = defineTool({
		name: "run_code",
		description: DESCRIPTION,
		parameters: obj({
			code: str({ description: "The program: the body of an async function" }),
			timeout: opt(int({ description: `Seconds it may run, ${MAX_SECONDS} at most` })),
		}),
		// It changes nothing, so running it again after a restart is harmless.
		replay: "safe",
		execute: async (args, _api, context: Context) => {
			const { blocks, isError, ok } = await runProgram(sandbox, args.code, args.timeout, context.abortSignal);
			return { output: blocks, details: { ok }, ...(isError ? { isError: true } : {}) };
		},
	});
	return {
		tools: [tool],
		// Wherever it is wanted: it needs no access, since it reaches nothing. Off unless the agent turns it on (builtins.ts).
		toolNames: () => ["run_code"],
		stopping: () => sandbox.close(),
	};
};
