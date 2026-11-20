// `edit` replaces exact text only (issue #575). Twice in one night the tool answered "Successfully replaced" for an
// oldText that was not in the file byte for byte — a curly quotation mark for a straight one — and wrote the agent's
// slightly wrong newText over a line the change never meant to alter, breaking a build. The loose matching that let it
// happen (pi durable's `normalizeForFuzzyMatch`) normalises Unicode quotes, dashes and spaces, trailing whitespace and
// NFKC lookalikes, then writes the touched lines back from that normalised form, so the file's own characters were lost
// as well. A patch to the installed package (engine/scripts/patch-edit.ts) refuses instead, in the library's own
// matching before anything is written: an oldText that matches byte for byte is replaced as before, and one that
// matches only after the normalisation is refused with the file's own exact text for the place it nearly matched, so
// the agent can send it again exactly. Line endings (CRLF) keep today's tolerance, and what is written keeps the
// file's own. Here a real engine with the demo model, whose `/tools` message makes the calls as a real model makes
// them: the near miss of the issue refused with the file's own text and the file untouched; an exact match as before;
// several edits in one call where one is a near miss change nothing at all; a file with CRLF line endings keeps them;
// every other kind of near miss — a curly single quote, a dash, a narrow space, an NFKC lookalike, trailing
// whitespace — refused the same way; and one too large to show naming the lines to read instead.

import assert from "node:assert/strict";
import { type ChildProcess, spawn } from "node:child_process";
import { closeSync, mkdtempSync, openSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { EngineClient, standInApp, stop } from "./patience.ts";

// The engine takes changes to what the person set only from its app's connection (#513): this test's connection stands
// for the app's, as the tests that answer for the person already do (#504).
process.env.PI2_APP_BUNDLE = standInApp();

function step(name: string): void {
	console.log(`ok  ${name}`);
}

type Event = Record<string, any>;
class Client extends EngineClient {
	items(id: number, kind?: string): Event[] {
		return (this.conversations.get(id)?.items ?? []).filter((item: Event) => kind === undefined || item.kind === kind);
	}
	state(id: number): Event | undefined {
		return this.conversations.get(id)?.state;
	}
	idle(id: number): boolean {
		return this.state(id)?.busy === false;
	}
	/** Sends a message the demo model answers with tool calls, and returns the next call's result once the answer is in. */
	async send(id: number, text: string): Promise<Event> {
		const count = this.items(id, "tool").length + 1;
		const answers = this.items(id, "assistant").length;
		await this.call("submit", { id, text });
		return await this.until(`result of ${text}`, () =>
			this.idle(id) && this.items(id, "tool").length >= count && this.items(id, "assistant").length >= answers + 2 ? this.items(id, "tool")[count - 1] : undefined);
	}
}

const home = mkdtempSync(join(tmpdir(), "pi2-editexact-"));
const work = realpathSync(mkdtempSync(join(tmpdir(), "pi2-editexact-work-")));
const main = join(import.meta.dirname, "..", "src", "main.ts");
const engineLog = join(home, "engine.log");
const log = openSync(engineLog, "a");
const engine: ChildProcess = spawn(process.execPath, [main], {
	env: { ...process.env, PI2_HOME: home, PI2_KEYCHAIN_SERVICE: "dev.pi2.credentials.test-editexact", PI2_DEMO_TOKENS_PER_SECOND: "1000", PI2_LOGIN_SHELL: "off" },
	stdio: ["ignore", log, log],
});
closeSync(log);
let passed = false;
try {
	const client = await Client.connect(engine, home);
	await client.until("first events", () => client.events.agents && client.events.library);
	const { id: worker } = await client.call("agents.save", { agent: { name: "Worker", access: "full", cwd: work } });
	const { id: conv } = await client.call("conversation.create", { agentId: worker });
	await client.call("conversation.open", { id: conv });
	await client.until("the conversation", () => client.state(conv));

	// What a near miss is refused with: the file's own text for the place it nearly matched, with the line numbers and
	// what to do. One line, so a long oldText cannot put a whole file in the refusal; the agent is told to read it.
	const refusedBy = (item: Event, path: string, lines: string): void => {
		assert.equal(item.isError, true, `the call should have failed, and answered: ${item.text}`);
		assert.match(item.text, new RegExp(`${path} exactly`));
		assert.match(item.text, /quotation marks, dashes, spaces, trailing whitespace or lookalike characters/);
		assert.match(item.text, /Nothing was changed\./);
		assert.match(item.text, new RegExp(`The file's own text on ${lines}:`));
		assert.match(item.text, /Send the oldText again copied from the file exactly\./);
	};

	// ---- The near miss of the issue: one curly quotation mark for a straight one

	// The file as the agent read it, with curly quotes as the issue's Swift file had.
	const note = join(work, "note.txt");
	writeFileSync(note, "alpha\nthe answer was “no”\nbeta\n");
	// The agent's call: straight quotes in oldText where the file has curly ones, and the same slip carried into
	// newText, as the issue's edit did.
	const slip = await client.send(conv, `/tools ${JSON.stringify([{ name: "edit", arguments: { path: "note.txt", edits: [{ oldText: 'the answer was "no"', newText: 'the answer was "no", sadly' }] } }])}`);
	refusedBy(slip, "note.txt", "line 2");
	assert.match(slip.text, /the answer was “no”/);
	assert.equal(readFileSync(note, "utf8"), "alpha\nthe answer was “no”\nbeta\n", "the file is untouched");
	step("a near miss in one quotation mark: refused with the file's own text, the file untouched");

	// Sent again exactly as the file has it, the edit applies as before, and the file's own curly quotes stay.
	const exact = await client.send(conv, `/tools ${JSON.stringify([{ name: "edit", arguments: { path: "note.txt", edits: [{ oldText: "the answer was “no”", newText: "the answer was “yes”" }] } }])}`);
	assert.equal(exact.isError, false, exact.text);
	assert.match(exact.text, /^Successfully replaced 1 block\(s\) in note\.txt\./);
	assert.equal(readFileSync(note, "utf8"), "alpha\nthe answer was “yes”\nbeta\n");
	step("an exact match: replaced as before, the file's own quotes kept");

	// ---- Several edits in one call, one a near miss: nothing changes at all

	writeFileSync(note, "alpha\nthe answer was “no”\nbeta\n");
	const both = await client.send(conv, `/tools ${JSON.stringify([
		{ name: "edit", arguments: { path: "note.txt", edits: [
			{ oldText: "alpha", newText: "ALPHA" },
			{ oldText: 'the answer was "no"', newText: 'the answer was "no", sadly' },
		] } },
	])}`);
	refusedBy(both, "note.txt", "line 2");
	assert.equal(readFileSync(note, "utf8"), "alpha\nthe answer was “no”\nbeta\n", "neither edit was applied");
	step("several edits in one call, one a near miss: nothing changes at all");

	// ---- A file with CRLF line endings keeps them, matched with plain LF as today

	const win = join(work, "win.txt");
	writeFileSync(win, "one\r\ntwo\r\nthree\r\n");
	const crlf = await client.send(conv, `/tools ${JSON.stringify([{ name: "edit", arguments: { path: "win.txt", edits: [{ oldText: "two\nthree", newText: "two\nTHREE" }] } }])}`);
	assert.equal(crlf.isError, false, crlf.text);
	assert.equal(readFileSync(win, "utf8"), "one\r\ntwo\r\nTHREE\r\n");
	step("a CRLF file: matched with plain LF as today, and keeps its CRLF");

	// ---- Every other kind of near miss, each refused with the file's own text

	// [what the file has, what the agent sends instead]: a curly single quote, an en-dash, a narrow no-break space, an
	// NFKC lookalike (a circled digit for the digit it normalises to), and trailing whitespace at a line's end.
	const near: [string, string][] = [
		["it\u2019s here", "it's here"],
		["pages 1\u20133", "pages 1-3"],
		["a\u202fb\u202fc", "a b c"],
		["count \u2461 two", "count 2 two"],
		["two   \nthree", "two\nthree"],
	];
	for (const [has, sends] of near) {
		writeFileSync(note, `alpha\n${has}\nbeta\n`);
		const tried = await client.send(conv, `/tools ${JSON.stringify([{ name: "edit", arguments: { path: "note.txt", edits: [{ oldText: sends, newText: `X${sends}X` }] } }])}`);
		assert.equal(tried.isError, true, `a near miss (${JSON.stringify(sends)}) should have been refused, and answered: ${tried.text}`);
		assert.match(tried.text, /note\.txt exactly/);
		assert.match(tried.text, /Nothing was changed\./);
		assert.equal(readFileSync(note, "utf8"), `alpha\n${has}\nbeta\n`, `the file keeps its own text after a near miss (${JSON.stringify(sends)})`);
	}
	step("every other kind of near miss: refused, the file keeping its own text");

	// A near miss larger than the refusal shows: it says where to read the rest, and changes nothing.
	const lines = Array.from({ length: 60 }, (_, i) => `line ${i + 1}`);
	writeFileSync(note, `${lines.join("\n")}\n`);
	const huge = await client.send(conv, `/tools ${JSON.stringify([{ name: "edit", arguments: { path: "note.txt", edits: [{ oldText: `${lines.join("\n").replace("line 30", "line 30 ")}\n`, newText: "replaced\n" }] } }])}`);
	assert.equal(huge.isError, true, huge.text);
	assert.match(huge.text, /note\.txt exactly/);
	assert.match(huge.text, /Nothing was changed\./);
	assert.match(huge.text, /on lines 1-60/);
	assert.match(huge.text, /Read note\.txt from line 41 for the rest of it/);
	assert.equal(readFileSync(note, "utf8"), `${lines.join("\n")}\n`, "the file is untouched");
	step("a near miss too large to show: the line range named, where to read it, the file untouched");

	console.log("PASS");
	passed = true;
} finally {
	await stop(engine);
	if (!passed) process.stderr.write(readFileSync(engineLog, "utf8"));
	rmSync(home, { recursive: true, force: true });
	rmSync(work, { recursive: true, force: true });
}
process.exit(passed ? 0 : 1);
