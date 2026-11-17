// `run_code` (#286, src/runcode.ts): a short program runs in the sandbox and gives back what it printed, and cannot
// reach files, the network, the process or any tool; a program that never ends is stopped at its time limit and its
// worker thread exits; one that allocates too much fails inside the sandbox. No engine: the sandbox the tool uses,
// driven directly. That the tool is offered only to an agent that turns it on is in offered.ts.

import assert from "node:assert/strict";
import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { codeSandbox, MAX_OUTPUT_CHARS, runProgram } from "../src/runcode.ts";

const folder = mkdtempSync(join(tmpdir(), "pi2-runcode-"));
let exits: Promise<void>[] = [];
const sandbox = codeSandbox({ onWorkerStarted: (exited) => void exits.push(exited) });
// A server the program would have to reach to touch the network: it must never be asked anything.
let asked = 0;
const server = createServer((_request, response) => {
	asked++;
	response.end("reached");
});
await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
const port = (server.address() as { port: number }).port;

function step(name: string): void {
	console.log(`ok  ${name}`);
}
const textOf = (blocks: { type: string; text?: string }[]) => blocks.map((block) => block.text ?? "").join("\n");

try {
	// It prints, and returns.
	const sums = await runProgram(sandbox, "console.log(6 * 7); console.log('two', 'words'); text('a text item'); return { days: (Date.UTC(2026, 11, 25) - Date.UTC(2026, 0, 1)) / 864e5 };");
	assert.equal(sums.isError, false);
	assert.equal(textOf(sums.blocks), '42\ntwo words\na text item\nReturned: {"days":358}');
	assert.equal(textOf((await runProgram(sandbox, "return 'plain text'")).blocks), "Returned: plain text");
	assert.match(textOf((await runProgram(sandbox, "")).blocks), /printed nothing and returned nothing/);
	step("prints and returns, top-level await and all");

	// A program that throws says where, after what it printed.
	const thrown = await runProgram(sandbox, "console.log('before'); const x = null; x.y;");
	assert.equal(thrown.isError, true);
	assert.match(textOf(thrown.blocks), /^before\nTypeError: /);
	assert.equal((await runProgram(sandbox, "this is not javascript")).isError, true);
	step("an error says what went wrong");

	// Nothing to reach anything with: no Node, no network, no timers, no tools, no modules.
	const reach = await runProgram(
		sandbox,
		"return ['require', 'process', 'fetch', 'XMLHttpRequest', 'WebSocket', 'setTimeout', 'setInterval', 'Deno', 'Bun', 'std', 'os', 'module'].map((name) => `${name}:${typeof globalThis[name]}`).join(' ') + ` tools:${Object.keys(tools).length} ALL_TOOLS:${ALL_TOOLS.length}`",
	);
	assert.equal(
		textOf(reach.blocks),
		"Returned: require:undefined process:undefined fetch:undefined XMLHttpRequest:undefined WebSocket:undefined setTimeout:undefined setInterval:undefined Deno:undefined Bun:undefined std:undefined os:undefined module:undefined tools:0 ALL_TOOLS:0",
	);
	const imported = await runProgram(sandbox, `const fs = await import('node:fs'); fs.writeFileSync(${JSON.stringify(join(folder, "written"))}, 'x');`);
	assert.equal(imported.isError, true, textOf(imported.blocks));
	const std = await runProgram(sandbox, `const os = await import('qjs:os'); return os;`);
	assert.equal(std.isError, true, textOf(std.blocks));
	const network = await runProgram(sandbox, `return await fetch('http://127.0.0.1:${port}/')`);
	assert.equal(network.isError, true, textOf(network.blocks));
	const called = await runProgram(sandbox, "return await tools.bash({ command: 'touch x' })");
	assert.equal(called.isError, true, textOf(called.blocks));
	assert.ok(!existsSync(join(folder, "written")), "no file was written");
	assert.equal(asked, 0, "the network was never reached");
	step("no require, process, fetch, timers, modules or tools: no file written, no request made");

	// A program that never ends is stopped at its limit, and so is its worker thread; so is one that only awaits.
	for (const code of ["while (true) {}", "for (;;) await null;"]) {
		exits = [];
		const endless = await runProgram(sandbox, code, 1);
		assert.equal(endless.isError, true);
		assert.match(textOf(endless.blocks), /stopped after 1 seconds, its time limit/);
		assert.equal(exits.length, 1);
		await exits[0];
	}
	step("a program that never ends is stopped at its limit, and its worker thread exits");

	// Stopped from outside, as when the person stops the answer.
	exits = [];
	const stopping = new AbortController();
	const stopped = runProgram(sandbox, "while (true) {}", 120, stopping.signal);
	await new Promise((resolve) => setImmediate(resolve));
	stopping.abort();
	const ended = await stopped;
	assert.equal(ended.isError, true);
	assert.match(textOf(ended.blocks), /The program was stopped\./);
	await exits[0];
	step("a program is stopped when its call is");

	// Too much memory fails inside the sandbox, which keeps working.
	const greedy = await runProgram(sandbox, "const parts = []; for (;;) parts.push(new Array(1e6).fill(1));", 60);
	assert.equal(greedy.isError, true);
	assert.match(textOf(greedy.blocks), /out of memory/i);
	assert.equal(textOf((await runProgram(sandbox, "return 1 + 1")).blocks), "Returned: 2");
	step("too much memory fails in the program, and the next one runs");

	// A long output keeps its start and its end.
	const long = await runProgram(sandbox, "console.log('start' + 'x'.repeat(100000) + 'end')");
	const shown = textOf(long.blocks);
	assert.ok(shown.length < MAX_OUTPUT_CHARS + 100 && shown.startsWith("startx") && shown.endsWith("xend") && shown.includes("characters left out"));
	step("a long output is shortened in the middle");
} finally {
	await sandbox.close();
	server.close();
	rmSync(folder, { recursive: true, force: true });
}
