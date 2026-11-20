// A path that begins with $PI2_SCRATCH, in the file tools (issue #564). src/scratch.ts reads the path before the tool
// runs, so the tool itself is not changed and what it answers names the real file. Here: how one path is read, with and
// without a scratch folder; the arguments of a call, `read`'s `files` among them; and the three library tools run
// through the wrap, on a folder of their own, with a stand-in for what a tool call is given (its conversation, its
// folder). That the same folder is what a command's $PI2_SCRATCH names is answered by test/environment.ts, which runs a
// real engine and its shell.

import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { NodeExecutionEnv } from "@earendil-works/pi-durable/env/node";
import { createEditTool, createReadTool, createWriteTool } from "@earendil-works/pi-durable/tools";
import { NO_SCRATCH_FOLDER, NO_VARIABLE_PATH, expandPaths, scratchPath, scratchPaths } from "../src/scratch.ts";
import { reading } from "../src/reading.ts";

const root = mkdtempSync(join(tmpdir(), "pi2-scratch-paths-"));
process.on("exit", () => rmSync(root, { recursive: true, force: true }));
const project = join(root, "project");
const scratchRoot = join(root, "scratch");
mkdirSync(project);
/** The conversation's scratch folder, made for it as `conversationScratch` makes the real one. */
const scratchFor = (id: unknown): string => {
	const folder = join(scratchRoot, String(id));
	mkdirSync(folder, { recursive: true });
	return folder;
};

const step = (what: string) => console.log(`ok  ${what}`);
const refusedWith = (why: string) => (error: unknown) => error instanceof Error && error.message === why;

// ---- How one path is read

// Anything that does not begin with a variable comes back as it was written.
for (const path of ["notes/x.txt", "notes", "./x", "/tmp/elsewhere/x.txt", "src/$PI2_SCRATCH/x", "./$PI2_SCRATCH/x", "src/$HOME/x"]) {
	assert.equal(scratchPath(path, "SCRATCH", project), path, path);
}
// The two spellings of the name, on their own or beginning the path.
for (const [path, wanted] of [
	["$PI2_SCRATCH", "SCRATCH"],
	["$PI2_SCRATCH/", "SCRATCH"],
	["${PI2_SCRATCH}", "SCRATCH"],
	["${PI2_SCRATCH}/", "SCRATCH"],
	["$PI2_SCRATCH/pictures/one.png", join("SCRATCH", "pictures/one.png")],
	["${PI2_SCRATCH}/x", join("SCRATCH", "x")],
	// The name at the start is read; what follows it is kept, a variable there included.
	["$PI2_SCRATCH/mid/$HOME", join("SCRATCH", "mid/$HOME")],
] as const) {
	assert.equal(scratchPath(path, "SCRATCH", project), wanted, path);
}
// A name that only begins like it, or is not the one, is not the scratch folder.
for (const path of ["$PI2_SCRATCHX", "$PI2_SCRATCHING/x", "$PI2", "$SCRATCH/x", "$PI2SCRATCH/x"]) {
	assert.throws(() => scratchPath(path, "SCRATCH", project), refusedWith(NO_VARIABLE_PATH), path);
}
// Another variable is refused, however it is written …
for (const path of ["$HOME/x", "${HOME}/x", "$PI2_HOME/x", "$PATH", "${TMPDIR}"]) {
	assert.throws(() => scratchPath(path, "SCRATCH", project), refusedWith(NO_VARIABLE_PATH), path);
}
// … unless the folder a relative path is in really holds something of exactly that name, which is what the agent meant.
mkdirSync(join(project, "$odd"));
assert.equal(scratchPath("$odd", "SCRATCH", project), "$odd");
assert.equal(scratchPath("$odd/x.txt", "SCRATCH", project), "$odd/x.txt");
assert.throws(() => scratchPath("$odder/x.txt", "SCRATCH", project), refusedWith(NO_VARIABLE_PATH), "a name close to one that exists");
// And with no scratch folder to put in its place, the path is refused rather than guessed at.
for (const path of ["$PI2_SCRATCH", "$PI2_SCRATCH/x", "${PI2_SCRATCH}/x"]) {
	assert.throws(() => scratchPath(path, undefined, project), refusedWith(NO_SCRATCH_FOLDER), path);
}
step("one path: the scratch folder for $PI2_SCRATCH, the path as written otherwise, another variable refused, a real folder of that name kept");

// ---- The paths of a call

assert.deepEqual(expandPaths({ path: "$PI2_SCRATCH/x", content: "c" }, "SCRATCH", project), { path: join("SCRATCH", "x"), content: "c" });
assert.deepEqual(expandPaths({ path: "$PI2_SCRATCH" }, "SCRATCH", project), { path: "SCRATCH" });
assert.deepEqual(expandPaths({ path: "notes/x", pattern: "*.ts", glob: "src/**" }, "SCRATCH", project), { path: "notes/x", pattern: "*.ts", glob: "src/**" }, "no other argument changes");
assert.deepEqual(expandPaths({ files: [{ path: "$PI2_SCRATCH/a", offset: 2 }, { path: "b" }, "c"] }, "SCRATCH", project), {
	files: [{ path: join("SCRATCH", "a"), offset: 2 }, { path: "b" }, "c"],
});
assert.deepEqual(expandPaths({ files: [{ path: "a" }] }, undefined, project), { files: [{ path: "a" }] }, "no path asked for the scratch folder, so no folder is needed");
assert.throws(() => expandPaths({ path: "$HOME/x" }, "SCRATCH", project), refusedWith(NO_VARIABLE_PATH));
assert.throws(() => expandPaths({ files: [{ path: "$HOME/x" }] }, "SCRATCH", project), refusedWith(NO_VARIABLE_PATH), "a list of files is checked entry by entry");
for (const args of [null, undefined, "text", 7]) assert.equal(expandPaths(args, "SCRATCH", project), args);
step("a call: each path it gives read, its other arguments left as they were");

// ---- The tools, through the wrap

const wrapOf = new Map(scratchPaths({ scratchOf: scratchFor, fallback: () => project }, ["write", "edit", "read"]).map((each) => [each.tool, each.wrap]));
const noneOf = new Map(scratchPaths({ scratchOf: () => undefined, fallback: () => project }, ["write"]).map((each) => [each.tool, each.wrap]));
const library = { write: createWriteTool(), edit: createEditTool(), read: reading.wrap(createReadTool() as never) as never };
const tools = Object.fromEntries(Object.entries(library).map(([name, tool]) => [name, (wrapOf.get(name) ?? ((x: never) => x))(tool as never)])) as typeof library;
const noScratch = noneOf.get("write")!(library.write as never) as typeof library.write;

const api = {
	env: new NodeExecutionEnv({ cwd: project }),
	conversationId: 7,
	snapshot: async () => ({ cwd: project }),
	agent: async () => ({ model: undefined }),
	models: { getModel: () => undefined },
} as never;
const context = {} as never;
/** What the wrapped tool gives for `args`, after the repairs the harness applies before a call. */
const call = (tool: { execute: (...args: never[]) => Promise<any>; prepareArguments?: (args: unknown) => unknown }, args: Record<string, unknown>) =>
	tool.execute(((tool.prepareArguments?.(args) ?? args) as never), api, context);

/** A call refused before the file was touched: an answer of one line the agent can act on, not a fault in the call. */
const refused = async (tool: Parameters<typeof call>[0], args: Record<string, unknown>, why: string, what: string) => {
	const answer = await call(tool, args);
	assert.equal(answer.isError, true, `${what}: ${JSON.stringify(answer)}`);
	assert.ok(answer.output.every((part: { text: string }) => part.text === why), `${what}: ${JSON.stringify(answer)}`);
};

const own = scratchFor(7);
try {
	// Written with the variable's name, in both spellings, into a folder that is not there yet.
	rmSync(scratchRoot, { recursive: true, force: true });
	for (const [path, text] of [["$PI2_SCRATCH/note.txt", "one\n"], ["${PI2_SCRATCH}/note.txt", "two\n"]] as const) {
		const wrote = await call(tools.write, { path, content: text });
		assert.equal(wrote.isError, undefined, `${path}: ${JSON.stringify(wrote)}`);
		assert.equal(readFileSync(join(own, "note.txt"), "utf8"), text, `${path} reaches the conversation's scratch folder, made on the way`);
		// The tool answers with the path it was given, which is now the real one, so the agent can use it again.
		assert.ok(JSON.stringify(wrote).includes(join(own, "note.txt")), `${path}: ${JSON.stringify(wrote)}`);
	}
	const deep = await call(tools.write, { path: "$PI2_SCRATCH/deep/in/sub.txt", content: "below\n" });
	assert.equal(deep.isError, undefined, JSON.stringify(deep));
	assert.equal(readFileSync(join(own, "deep/in/sub.txt"), "utf8"), "below\n", "and folders below it are made as ever");

	// Read and edited by the same name, and the answer says where the file really is.
	const read = await call(tools.read, { files: [{ path: "$PI2_SCRATCH/note.txt" }] });
	assert.ok(JSON.stringify(read).includes("two"), JSON.stringify(read).slice(0, 300));
	assert.ok(JSON.stringify(read).includes(join(own, "note.txt")), "the header names the real path: " + JSON.stringify(read).slice(0, 300));
	const several = await call(tools.read, { files: [{ path: "$PI2_SCRATCH/note.txt" }, { path: "$PI2_SCRATCH/deep/in/sub.txt" }] });
	assert.ok(JSON.stringify(several).includes("below"), JSON.stringify(several).slice(0, 300));
	const edited = await call(tools.edit, { path: "$PI2_SCRATCH/note.txt", edits: [{ oldText: "two", newText: "three" }] });
	assert.equal(edited.isError, undefined, JSON.stringify(edited));
	assert.equal(readFileSync(join(own, "note.txt"), "utf8"), "three\n");

	// A path with no variable in it is the tool's own business, as before.
	const plain = await call(tools.write, { path: "plain.txt", content: "in the working folder\n" });
	assert.equal(plain.isError, undefined, JSON.stringify(plain));
	assert.equal(readFileSync(join(project, "plain.txt"), "utf8"), "in the working folder\n");

	// A variable the tools will not expand is refused, and nothing is made for its name.
	for (const [name, args] of [
		["write", { path: "$HOME/nope.txt", content: "x" }],
		["read", { path: "$HOME/nope.txt" }],
		["read", { files: [{ path: "$HOME/nope.txt" }] }],
		["edit", { path: "$HOME/nope.txt", edits: [{ oldText: "a", newText: "b" }] }],
	] as const) {
		await refused(tools[name], args, NO_VARIABLE_PATH, `${name} ${JSON.stringify(args)}`);
	}
	assert.equal(existsSync(join(project, "$HOME")), false, "no folder named $HOME was made");

	// A folder of exactly that name is still a folder, and the agent's own words reach it.
	const literal = await call(tools.write, { path: "$odd/kept.txt", content: "as written\n" });
	assert.equal(literal.isError, undefined, JSON.stringify(literal));
	assert.equal(readFileSync(join(project, "$odd", "kept.txt"), "utf8"), "as written\n");

	// A conversation with no scratch folder is refused, not guessed at.
	await refused(noScratch, { path: "$PI2_SCRATCH/nope.txt", content: "x" }, NO_SCRATCH_FOLDER, "a conversation with no scratch folder");
	assert.equal(existsSync(join(project, "$PI2_SCRATCH")), false, "and no folder named $PI2_SCRATCH was made in its place");
	step("write, read and edit: $PI2_SCRATCH and ${PI2_SCRATCH} reach the conversation's scratch folder, and say so; another variable is refused and nothing is made");
} catch (error) {
	console.error(error);
	process.exitCode = 1;
}
