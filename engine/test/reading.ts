// `read` of several files, or several ranges of one file, in one call (issue #176): engine/src/reading.ts wraps pi
// durable's `read`. This runs the wrap around the library's own tool, on files in a folder of its own, with a stand-in
// for what a tool call is given (its folder, its model): the old single-file form gives exactly what the library gives,
// and the several-file form returns each file under its own line, says why one could not be read without losing the
// others, and keeps to the call's limits.

import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { NodeExecutionEnv } from "@earendil-works/pi-durable/env/node";
import { createReadTool } from "@earendil-works/pi-durable/tools";
import { CALL_MAX_BYTES, headerOf, MAX_FILES, MAX_IMAGES, prepareArguments, READ_DESCRIPTION, reading } from "../src/reading.ts";

const folder = mkdtempSync(join(tmpdir(), "pi2-reading-"));
process.on("exit", () => rmSync(folder, { recursive: true, force: true }));

const step = (what: string) => console.log(`ok  ${what}`);
const TINY_PNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==";

const numbered = (count: number, width = 0) => Array.from({ length: count }, (_, i) => `line ${i + 1}`.padEnd(width, ".")).join("\n") + "\n";
writeFileSync(join(folder, "a.txt"), "alpha\nbeta\n");
writeFileSync(join(folder, "b.txt"), "no newline at the end");
writeFileSync(join(folder, "long.txt"), numbered(3000));
writeFileSync(join(folder, "shot.png"), Buffer.from(TINY_PNG, "base64"));
// Three files of 40KB each: two fit in a call, the third does not.
for (const name of ["big1.txt", "big2.txt", "big3.txt"]) writeFileSync(join(folder, name), numbered(1000, 40));

const library = createReadTool();
const read = reading.wrap(library as never) as unknown as typeof library;
const api = {
	env: new NodeExecutionEnv({ cwd: folder }),
	agent: async () => ({ model: undefined }),
	models: { getModel: () => undefined },
} as never;
const context = {} as never;
/** What the wrapped tool gives for `args`, after the repairs pi durable applies before a call. */
const call = (args: Record<string, unknown>) => read.execute((read.prepareArguments?.(args) ?? args) as never, api, context);
const texts = (result: { output?: readonly { type: string; text?: string }[] }) => (result.output ?? []).map((block) => (block.type === "text" ? block.text : "[image]")).join("");

try {
	// The description and parameters the model is given.
	assert.equal(read.description, READ_DESCRIPTION);
	const parameters = read.parameters as { properties: Record<string, unknown>; required?: string[] };
	assert.deepEqual(Object.keys(parameters.properties), ["path", "offset", "limit", "files"]);
	assert.ok(!(parameters.required ?? []).includes("path"), "path is optional now that files can stand in for it");

	// The old form: exactly what the library gives, for a whole file, a range, a long file and a missing one.
	for (const args of [{ path: "a.txt" }, { path: "long.txt", offset: 10, limit: 5 }, { path: "long.txt" }, { path: "shot.png" }]) {
		assert.deepEqual(await call(args), await library.execute(args as never, api, context), JSON.stringify(args));
	}
	await assert.rejects(call({ path: "missing.txt" }), /ENOENT|not found|no such file/i, "a missing file is an error, as before");
	await assert.rejects(library.execute({ path: "missing.txt" } as never, api, context));
	await assert.rejects(call({}), /Give `path`, or `files`/);
	await assert.rejects(call({ files: [] }), /`files` is empty/);
	step("one file with path: the library's own result, a missing file and an empty call refused");

	// Several files.
	let result = await call({ files: [{ path: "a.txt" }, { path: "b.txt" }] });
	assert.equal(result.isError, undefined);
	assert.equal(texts(result), "==> a.txt <==\nalpha\nbeta\n\n==> b.txt <==\nno newline at the end\n");
	assert.deepEqual(result.structuredOutput, [
		{ path: "a.txt", text: "alpha\nbeta\n" },
		{ path: "b.txt", text: "no newline at the end" },
	]);
	assert.deepEqual(result.details, { files: [{ path: "a.txt" }, { path: "b.txt" }] });
	// `path` with `files` counts as the first of them; a list of paths and a list sent as a string are taken too.
	assert.equal(texts(await call({ path: "a.txt", files: [{ path: "b.txt" }] })), texts(result));
	assert.equal(texts(await call({ files: ["a.txt", "b.txt"] })), texts(result));
	assert.equal(texts(await call({ files: JSON.stringify([{ path: "a.txt" }, "b.txt"]) })), texts(result));
	assert.deepEqual(prepareArguments({ path: "a.txt" }), { path: "a.txt" }, "the old form is left as it is");
	step("several files: each under its own line, in the order asked, also when sent as a list of paths or a string");

	// Several ranges of one file, each with what the library says about the rest.
	result = await call({ files: [{ path: "long.txt", limit: 2 }, { path: "long.txt", offset: 2999 }] });
	assert.equal(
		texts(result),
		"==> long.txt (lines 1-2) <==\nline 1\nline 2\n[2999 more lines in file. Use offset=3 to continue.]\n\n==> long.txt (from line 2999) <==\nline 2999\nline 3000\n",
	);
	assert.deepEqual(result.details, { files: [{ path: "long.txt", limit: 2 }, { path: "long.txt", offset: 2999 }] });
	assert.equal(headerOf({ path: "x", offset: 10, limit: 50 }), "==> x (lines 10-59) <==");
	// A whole long file keeps the library's limit for one file.
	result = await call({ files: [{ path: "long.txt" }] });
	assert.match(texts(result), /\nline 2000\n\[Showing lines 1-2000 of 3001\. Use offset=2001 to continue\.\]\n$/);
	step("several ranges of one file, each with its own range and the library's note about the rest");

	// A missing file says why in its place; the others are still read. Only when none can be read is it an error.
	result = await call({ files: [{ path: "a.txt" }, { path: "missing.txt" }, { path: "long.txt", offset: 5000 }, { path: "b.txt" }] });
	assert.equal(result.isError, undefined, "one file missing does not fail the call");
	const parts = texts(result).split(/\n(?===> )/);
	assert.equal(parts[0], "==> a.txt <==\nalpha\nbeta\n");
	assert.match(parts[1]!, /^==> missing\.txt <==\n\[.*(ENOENT|not found|no such file).*\]\n?$/i);
	assert.match(parts[2]!, /^==> long\.txt \(from line 5000\) <==\n\[Offset 5000 is beyond end of file \(3001 lines total\)\]\n?$/);
	assert.equal(parts[3], "==> b.txt <==\nno newline at the end\n");
	const reads = result.structuredOutput as { path: string; text?: string; error?: string }[];
	assert.ok(reads[1]!.error !== undefined && reads[1]!.text === undefined && reads[2]!.error !== undefined);
	assert.deepEqual((result.details as { files: unknown[] }).files[1], { path: "missing.txt", failed: true });
	result = await call({ files: [{ path: "missing.txt" }, { path: "gone.txt" }] });
	assert.equal(result.isError, true, "nothing could be read");
	step("a file that cannot be read says why, and the others are still returned; the call fails only when none could be read");

	// The call's limit: the file that crosses it is cut at a line, and says where to go on; the files after it are not read.
	result = await call({ files: [{ path: "big1.txt" }, { path: "big2.txt" }, { path: "big3.txt" }, { path: "a.txt" }] });
	const big = result.structuredOutput as { path: string; text?: string; note?: string; error?: string }[];
	const shownBytes = big.reduce((sum, file) => sum + Buffer.byteLength(file.text ?? ""), 0);
	assert.ok(shownBytes <= CALL_MAX_BYTES && shownBytes > CALL_MAX_BYTES - 64, `the call shows up to its limit (${shownBytes} bytes)`);
	assert.equal(big[0]!.note, undefined);
	const lastShown = big[2]!.text!.trimEnd().split("\n").at(-1)!;
	assert.ok(big[2]!.text!.endsWith(".\n"), "cut at the end of a line");
	const next = Number(/Use offset=(\d+) to continue/.exec(big[2]!.note!)![1]);
	assert.match(big[2]!.note!, /This call's 100KB of text ran out here, after line \d+\./);
	assert.equal(lastShown, `line ${next - 1}`.padEnd(40, "."));
	const continued = await call({ path: "big3.txt", offset: next, limit: 1 });
	assert.equal(continued.structuredOutput, `line ${next}`.padEnd(40, "."), "the offset it gives carries on where it stopped");
	assert.match(big[3]!.error!, /Not read: this call has already shown 100KB\. Read it in another call\./);
	assert.equal(result.isError, undefined);
	// No more than MAX_FILES files in one call.
	result = await call({ files: Array.from({ length: MAX_FILES + 1 }, () => "a.txt") });
	const many = result.structuredOutput as { error?: string }[];
	assert.equal(many.filter((file) => file.error === undefined).length, MAX_FILES);
	assert.match(many.at(-1)!.error!, new RegExp(`at most ${MAX_FILES} files`));
	step("the call shows at most 100KB of text: the file that crosses it says which offset continues it, and later files are not read");

	// Pictures: each under its line, at most MAX_IMAGES in a call.
	result = await call({ files: [{ path: "a.txt" }, { path: "shot.png" }] });
	const blocks = result.output ?? [];
	assert.deepEqual(blocks.map((block) => block.type), ["text", "text", "text", "image", "text"]);
	assert.deepEqual(blocks[3], { type: "image", data: TINY_PNG, mimeType: "image/png" });
	assert.deepEqual(blocks[4], { type: "text", text: "[Read image file [image/png].]\n" }, "with what the library says about it");
	assert.deepEqual((result.details as { files: unknown[] }).files[1], { path: "shot.png", image: true });
	const picture = (result.structuredOutput as { image?: unknown }[])[1]!;
	assert.deepEqual(picture.image, { type: "image", data: TINY_PNG, mimeType: "image/png" });
	result = await call({ files: Array.from({ length: MAX_IMAGES + 1 }, () => "shot.png") });
	assert.equal((result.output ?? []).filter((block) => block.type === "image").length, MAX_IMAGES);
	assert.match((result.structuredOutput as { error?: string }[]).at(-1)!.error!, new RegExp(`at most ${MAX_IMAGES} images`));
	step("pictures come back under their own line, at most five in a call");
} finally {
	rmSync(folder, { recursive: true, force: true });
}
