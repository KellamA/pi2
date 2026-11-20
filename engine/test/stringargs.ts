// A tool argument sent as a JSON string where its tool's schema says an array or an object (src/stringargs.ts, issue
// #572): the string is read as the value it encodes before the arguments are checked, in one place for every tool.
// Here the reading alone, with the library's own `edit` and a stand-in for the check the harness makes; then a real
// engine with the demo model, whose `/tools` message takes the arguments as they are written: an `edit` whose `edits`
// arrive as a string edits the file and the model is told to send the value itself, an `update_plan` whose `items`
// arrive as a string is set the same way (nothing of its own repairs them), a string that is not JSON and one that
// parses to an object where an array is wanted are refused as before, a string argument that happens to hold JSON is
// untouched, and nothing the model is sent about the tool changes.

import assert from "node:assert/strict";
import { type ChildProcess, spawn } from "node:child_process";
import { closeSync, mkdtempSync, openSync, readFileSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { validateToolArguments } from "@earendil-works/pi-ai/utils/validation";
import { createEditTool } from "@earendil-works/pi-durable/tools";
import { EngineClient, standInApp, stop } from "./patience.ts";
import { preparedTool, readStringified } from "../src/stringargs.ts";
// The engine takes changes to what the person set only from its app's connection (#513): this test's connection stands
// for the app's, as the tests that answer for the person already do (#504).
process.env.PI2_APP_BUNDLE = standInApp();

function step(name: string): void {
	console.log(`ok  ${name}`);
}

// ---- The reading alone

const edit = createEditTool();
const one = JSON.stringify([{ oldText: "a", newText: "b" }]);
assert.deepEqual(readStringified(edit.parameters, { path: "a.txt", edits: one }), {
	value: { path: "a.txt", edits: [{ oldText: "a", newText: "b" }] },
	names: ["edits"],
});
// Only a string that parses to the kind asked: one that does not parse, and one that parses to the other kind, are
// left for the check, which refuses them as today.
assert.equal(readStringified(edit.parameters, { path: "a.txt", edits: "not json" }), undefined);
assert.equal(readStringified(edit.parameters, { path: "a.txt", edits: JSON.stringify({ oldText: "a", newText: "b" }) }), undefined, "an object where an array is wanted");
// A string where a string is wanted is never touched, whatever it holds, and neither is a value that is not a string.
assert.equal(readStringified(edit.parameters, { path: one, edits: [{ oldText: "a", newText: "b" }] }), undefined);
for (const args of [null, undefined, "text", 7, [one], {}]) assert.equal(readStringified(edit.parameters, args), undefined, JSON.stringify(args));
// An object where an object is wanted is read too; a schema more loosely said, a union that allows a string, is not.
assert.deepEqual(
	readStringified({ type: "object", properties: { thing: { type: "object" }, loose: { anyOf: [{ type: "string" }, { type: "object" }] } } }, { thing: JSON.stringify({ a: 1 }), loose: JSON.stringify({ b: 2 }) }),
	{ value: { thing: { a: 1 }, loose: JSON.stringify({ b: 2 }) }, names: ["thing"] },
);
step("the reading: a string at an array or object position read as the JSON it encodes, only that and only of the kind asked");

// ---- The tool with the reading added

const prepared = preparedTool(1, edit);
// The declarations the model is sent are the tool's own, unchanged byte for byte.
assert.equal(prepared.name, edit.name);
assert.equal(prepared.description, edit.description);
assert.ok(prepared.parameters === edit.parameters, "the very same schema object");
// The reading runs before the tool's own repair, which then sees what it expects: `edit`'s turns a single edit and a
// top-level oldText/newText into the same list as before.
const args = prepared.prepareArguments?.({ path: "a.txt", edits: one, oldText: "c", newText: "d" }) as { edits: unknown[] };
assert.deepEqual(args.edits, [{ oldText: "a", newText: "b" }, { oldText: "c", newText: "d" }]);
assert.deepEqual(validateToolArguments(prepared as never, { type: "toolCall", id: "c1", name: "edit", arguments: args as never }).edits, [
	{ oldText: "a", newText: "b" },
	{ oldText: "c", newText: "d" },
]);
// A string the reading leaves alone reaches the check unchanged, refused with its usual words.
const left = prepared.prepareArguments?.({ path: "a.txt", edits: "not json" }) as unknown;
assert.throws(() => validateToolArguments(prepared as never, { type: "toolCall", id: "c2", name: "edit", arguments: left as never }), /edits\.0: expected object, got string/);
step("the tool: the reading before its own repair, then the check as before; the declarations unchanged");

// ---- A real engine, with the demo model

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

const home = mkdtempSync(join(tmpdir(), "pi2-stringargs-"));
const work = realpathSync(mkdtempSync(join(tmpdir(), "pi2-stringargs-work-")));
const main = join(import.meta.dirname, "..", "src", "main.ts");
const engineLog = join(home, "engine.log");
const log = openSync(engineLog, "a");
const engine: ChildProcess = spawn(process.execPath, [main], {
	env: { ...process.env, PI2_HOME: home, PI2_KEYCHAIN_SERVICE: "dev.pi2.credentials.test-stringargs", PI2_DEMO_TOKENS_PER_SECOND: "1000", PI2_LOGIN_SHELL: "off" },
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

	// The file to edit, written plainly first.
	await client.send(conv, `/tool write ${JSON.stringify({ path: "note.txt", content: "alpha\nbeta\n" })}`);
	assert.equal(readFileSync(join(work, "note.txt"), "utf8"), "alpha\nbeta\n");

	// `edits` as a JSON string: the file is edited, the result begins with one line telling the model to send the value
	// itself, and the row records it for the person.
	const edited = await client.send(conv, `/tools ${JSON.stringify([{ name: "edit", arguments: { path: "note.txt", edits: JSON.stringify([{ oldText: "beta", newText: "gamma" }]) } }])}`);
	assert.equal(edited.isError, false, edited.text);
	assert.match(edited.text, /^`edits` was sent as a JSON string and read as the value it encodes\. Send the value itself next time, not a string of it\.\n/);
	assert.deepEqual(edited.details.stringArguments, ["edits"]);
	assert.equal(readFileSync(join(work, "note.txt"), "utf8"), "alpha\ngamma\n");
	// The engine's log says so too, with the model, so it can be counted, by model.
	assert.match(readFileSync(engineLog, "utf8"), /edit's edits arrived as a JSON string and was read as the value it encodes \(conversation \d+, model demo\//);
	step("edit with edits as a JSON string: the file edited, one line to the model, the row and the log saying so");

	// `items` as a JSON string, a tool with no repair of its own: the plan is set the same way, with the same notice.
	const planned = await client.send(conv, `/tool update_plan ${JSON.stringify({ items: JSON.stringify([{ content: "Send the value itself, not a string of it", status: "completed" }]) })}`);
	assert.equal(planned.isError, false, planned.text);
	assert.match(planned.text, /^`items` was sent as a JSON string and read as the value it encodes\. Send the value itself next time, not a string of it\.\n/);
	assert.deepEqual(planned.details.stringArguments, ["items"]);
	assert.deepEqual((client.state(conv)!.plan as { items: { content: string; status: string }[] }).items, [
		{ content: "Send the value itself, not a string of it", status: "completed" },
	]);
	step("update_plan with items as a JSON string: the plan set, the same notice");

	// A string that is not JSON, and one that parses to an object where an array is wanted: refused as before.
	const notJson = await client.send(conv, `/tools ${JSON.stringify([{ name: "edit", arguments: { path: "note.txt", edits: "not json" } }])}`);
	assert.equal(notJson.isError, true, notJson.text);
	assert.match(notJson.text, /Validation failed for tool "edit"/);
	assert.match(notJson.text, /edits\.0: expected object, got string/);
	assert.equal(notJson.details?.stringArguments, undefined, "nothing was read");
	assert.equal(readFileSync(join(work, "note.txt"), "utf8"), "alpha\ngamma\n", "the file is untouched");
	const objectNotArray = await client.send(conv, `/tool update_plan ${JSON.stringify({ items: JSON.stringify({ content: "one item", status: "pending" }) })}`);
	assert.equal(objectNotArray.isError, true, objectNotArray.text);
	assert.match(objectNotArray.text, /Validation failed for tool "update_plan"/);
	assert.match(objectNotArray.text, /items\.0: expected object, got string/);
	assert.equal(objectNotArray.details?.stringArguments, undefined, "nothing was read");
	assert.deepEqual((client.state(conv)!.plan as { items: { content: string; status: string }[] }).items, [
		{ content: "Send the value itself, not a string of it", status: "completed" },
	], "the plan is unchanged");
	step("a string that is not JSON, and one that parses to an object where an array is wanted: refused as before");

	// A string argument that happens to hold JSON is untouched, and the model is told nothing.
	const echoed = await client.send(conv, `/tool bash ${JSON.stringify({ command: "echo '{\"a\":1}'" })}`);
	assert.equal(echoed.isError, false, echoed.text);
	assert.match(echoed.text, /\{"a":1\}/);
	assert.equal(echoed.details?.stringArguments, undefined, "a string where a string is wanted is never touched");
	assert.doesNotMatch(echoed.text, /was sent as a JSON string/);
	step("a command that is itself JSON text: untouched, and the model is told nothing");

	console.log("PASS");
	passed = true;
} finally {
	await stop(engine);
	if (!passed) process.stderr.write(readFileSync(engineLog, "utf8"));
	rmSync(home, { recursive: true, force: true });
	rmSync(work, { recursive: true, force: true });
}
process.exit(passed ? 0 : 1);
