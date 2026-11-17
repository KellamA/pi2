// `read` of several files, or several ranges of one file, in one call (issue #176).
//
// pi durable's `read` takes one file per call, and the shell takes any number, so agents batched their reading through
// `bash` (`cat a b c`, several `sed -n` ranges) and the transcript showed a command where it could show files. This wraps
// the library's `read` wherever it is offered, rather than patching it: a call with `path` (and `offset`, `limit`) is
// handed to the library as it is, and gives exactly what it gave before; a call with `files` reads each entry with the
// library's own `read`, in the order given, and returns them one after another, each under a `==> path <==` line.
//
// - A file that cannot be read says why, in its place, and the others are still returned. The call is an error only
//   when no file could be read, so the row in the conversation is red only when nothing came of it.
// - Each file keeps the library's limit (2000 lines or 50KB) and the call as a whole shows at most 100KB of text: the
//   file that crosses it is cut at a line and says where to go on from, and the files after it are not read, with a
//   line saying so. Without a limit for the whole, twenty files could put a megabyte in the context at once.
// - Pictures come back as the library prepares them, each under its line, at most five in a call: enough for a few
//   screenshots side by side, without one call holding tens of megabytes of them.
// - Programs (code mode scripts) get a list with one entry per file: its text, its picture, or why it was not read.
// - The result's `details` list the files for the conversation page, which shows one row naming them, and opens to a
//   section per file (app/Web/transcript/tools.js).

import type { Context } from "@earendil-works/chord/context";
import { type ToolExecutionApi, type ToolExecutionResult, type ToolRegistration, wrapTool } from "@earendil-works/pi-durable";
import { createReadTool } from "@earendil-works/pi-durable/tools";
import { arr, lit, num, obj, opt, str, union } from "@earendil-works/pi-schema";
import type { Feature } from "./features.ts";

/** The most text one call shows, over all its files. */
export const CALL_MAX_BYTES = 100 * 1024;
/** The most files (or ranges) one call reads; more are listed as not read. */
export const MAX_FILES = 20;
/** The most pictures one call shows. */
export const MAX_IMAGES = 5;
/** pi durable's limits for one file, which its `read` applies (they are not exported). */
const FILE_MAX_LINES = 2000;
const FILE_MAX_KB = 50;

export const READ_DESCRIPTION =
	"Read files: text, or images (jpg, png, gif, webp, bmp), which are sent as attachments. " +
	"One file with `path`, or several, or several ranges of one, with `files` in a single call: use this rather than `cat`, `sed -n` or `head` in the shell. " +
	`A file shows at most ${FILE_MAX_LINES} lines or ${FILE_MAX_KB}KB; \`offset\` (from 1) and \`limit\` choose the lines, and a file cut short says which offset continues it. ` +
	`One call shows at most ${CALL_MAX_BYTES / 1024}KB of text and ${MAX_IMAGES} images in all. A file that cannot be read says why, and the others are still shown.`;

const range = {
	offset: opt(num({ description: "Line number to start reading from (1-indexed)" })),
	limit: opt(num({ description: "Maximum number of lines to read" })),
};

// Its fields mean what the same fields of the call do, so they are not described again.
const entry = obj({ path: str(), offset: opt(num()), limit: opt(num()) }, { open: true });

export const READ_PARAMETERS = obj(
	{
		path: opt(str({ description: "Path to the file to read (relative or absolute)" })),
		...range,
		files: opt(arr(entry, { description: `Several files, or ranges of one, in this order (at most ${MAX_FILES}); instead of \`path\`` })),
	},
	{ open: true },
);

const image = obj({ type: lit("image"), data: str(), mimeType: str() }, { open: true });

/** What programs get: as before for `path`; for `files`, an entry per file in the order asked. */
export const READ_OUTPUT = union([
	str(),
	image,
	arr(obj({ path: str(), text: opt(str()), image: opt(image), note: opt(str()), error: opt(str()) }, { open: true })),
]);

type Entry = { path: string; offset?: number; limit?: number };
type Args = { path?: string; offset?: number; limit?: number; files?: Entry[] };
type Block = { type: "text"; text: string } | { type: "image"; data: string; mimeType: string };

/** What a program gets for one file. */
type Read = { path: string; text?: string; image?: Block & { type: "image" }; note?: string; error?: string };
/** What the conversation page is told about one file. */
type Shown = { path: string; offset?: number; limit?: number; failed?: true; image?: true };

/** "lines 10-59", "from line 10", or nothing. The page reads it back, in `readHeader` (app/Web/transcript/tools.js). */
function rangeOf(entry: Entry): string {
	if (entry.offset === undefined && entry.limit === undefined) return "";
	const from = entry.offset ?? 1;
	return entry.limit === undefined ? `from line ${from}` : `lines ${from}-${from + entry.limit - 1}`;
}

/** The line a file's part of the output starts with. The page finds the parts by these lines. */
export function headerOf(entry: Entry): string {
	const lines = rangeOf(entry);
	return `==> ${entry.path}${lines === "" ? "" : ` (${lines})`} <==`;
}

/** The entries a call asks for: `path` first if it has one, then `files`. Strings in `files` are taken as paths. */
function entriesOf(args: Args): Entry[] {
	const entries: Entry[] = [];
	if (typeof args.path === "string") entries.push({ path: args.path, ...(args.offset === undefined ? {} : { offset: args.offset }), ...(args.limit === undefined ? {} : { limit: args.limit }) });
	for (const file of args.files ?? []) entries.push(file);
	return entries;
}

/** Models often send `files` as a JSON string, or as a list of paths; take both. Pure, as pi durable asks. */
export function prepareArguments(args: unknown): Args {
	if (args === null || typeof args !== "object" || Array.isArray(args)) return args as Args;
	let files = (args as { files?: unknown }).files;
	if (typeof files === "string") {
		try {
			files = JSON.parse(files);
		} catch {
			return args as Args;
		}
	}
	if (!Array.isArray(files)) return { ...(args as object), ...(files === undefined ? {} : { files }) } as Args;
	return { ...(args as object), files: files.map((file) => (typeof file === "string" ? { path: file } : file)) } as Args;
}

const messageOf = (error: unknown) => (error instanceof Error ? error.message : String(error));

/** Cut `text` to at most `bytes` bytes, at the end of a line if one ends there, else at a character. */
function cut(text: string, bytes: number): string {
	const buffer = Buffer.from(text, "utf8");
	if (buffer.length <= bytes) return text;
	let end = buffer.lastIndexOf(0x0a, bytes - 1);
	if (end >= 0) return buffer.subarray(0, end + 1).toString("utf8");
	// One line longer than what is left: as many whole characters as fit.
	end = bytes;
	while (end > 0 && (buffer[end]! & 0xc0) === 0x80) end--;
	return buffer.subarray(0, end).toString("utf8");
}

const linesIn = (text: string) => (text === "" ? 0 : text.split("\n").length - (text.endsWith("\n") ? 1 : 0));

/** The several-file form: each entry read with the library's `read`, in order. */
async function readMany(read: ToolRegistration, entries: Entry[], api: ToolExecutionApi, context: Context): Promise<ToolExecutionResult> {
	const blocks: Block[] = [];
	const reads: Read[] = [];
	const shown: Shown[] = [];
	let bytes = 0;
	let images = 0;
	let failures = 0;
	// Once a file has been cut short for the call's limit, the files after it are not read, even one small enough to fit.
	let full = false;
	for (const [index, entry] of entries.entries()) {
		const own: Block[] = [];
		const done: Read = { path: entry.path };
		const page: Shown = { path: entry.path, ...(entry.offset === undefined ? {} : { offset: entry.offset }), ...(entry.limit === undefined ? {} : { limit: entry.limit }) };
		const notRead = (why: string) => {
			done.error = why;
			page.failed = true;
			failures++;
		};
		if (index >= MAX_FILES) notRead(`Not read: one call reads at most ${MAX_FILES} files. Read it in another call.`);
		else if (full) notRead(`Not read: this call has already shown ${CALL_MAX_BYTES / 1024}KB. Read it in another call.`);
		else {
			try {
				context.abortSignal?.throwIfAborted();
				const result = await read.execute({ path: entry.path, ...(entry.offset === undefined ? {} : { offset: entry.offset }), ...(entry.limit === undefined ? {} : { limit: entry.limit }) }, api, context);
				const diagnostics = result.diagnostics ?? [];
				const picture = (result.output ?? []).find((block) => block.type === "image") as (Block & { type: "image" }) | undefined;
				if (result.isError) notRead(diagnostics.map((d) => d.message).join(" ") || "It could not be read.");
				else if (picture !== undefined) {
					if (images >= MAX_IMAGES) notRead(`Not shown: one call shows at most ${MAX_IMAGES} images. Read it in another call.`);
					else {
						images++;
						own.push(picture);
						done.image = picture;
						page.image = true;
						const note = diagnostics.map((d) => d.message).join(" ");
						if (note !== "") done.note = note;
					}
				} else {
					let text = typeof result.structuredOutput === "string" ? result.structuredOutput : "";
					let note = diagnostics.map((d) => d.message).join(" ");
					const room = CALL_MAX_BYTES - bytes;
					if (Buffer.byteLength(text, "utf8") > room) {
						text = cut(text, room);
						full = true;
						const from = entry.offset ?? 1;
						const next = from + linesIn(text);
						note = `This call's ${CALL_MAX_BYTES / 1024}KB of text ran out here, after line ${next - 1}. Use offset=${next} to continue.`;
					}
					bytes += Buffer.byteLength(text, "utf8");
					done.text = text;
					if (note !== "") done.note = note;
					if (text !== "") own.push({ type: "text", text: text.endsWith("\n") ? text : `${text}\n` });
				}
			} catch (error) {
				if (context.abortSignal?.aborted) throw error;
				notRead(messageOf(error));
			}
		}
		const note = done.error ?? done.note;
		// A blank line between files; the header line is how the page tells them apart.
		blocks.push({ type: "text", text: `${index > 0 ? "\n" : ""}${headerOf(entry)}\n` }, ...own);
		if (note !== undefined) blocks.push({ type: "text", text: `[${note}]\n` });
		reads.push(done);
		shown.push(page);
	}
	return {
		output: blocks,
		structuredOutput: reads,
		details: { files: shown },
		...(failures === entries.length ? { isError: true } : {}),
	};
}

/** The wrap of `read`: the library's tool for one `path`, and several files with `files`. */
export const reading = wrapTool(createReadTool(), (read) => {
	const wrapped: ToolRegistration = {
		...(read as ToolRegistration),
		description: READ_DESCRIPTION,
		parameters: READ_PARAMETERS,
		structuredOutputSchema: READ_OUTPUT,
		prepareArguments,
		// The call's own limit is the one above, so pi durable's for one result (50KB, 2000 lines) must not cut it shorter.
		// Each file's header and note come on top of its text, and a file of empty lines is many lines in few bytes.
		outputLimits: { maxBytes: CALL_MAX_BYTES + MAX_FILES * 4096, maxLines: MAX_FILES * (FILE_MAX_LINES + 4) + 4096, retain: "head" },
		execute: async (given, api, context) => {
			const args = given as Args;
			if (args.files === undefined) {
				if (typeof args.path !== "string") throw new Error("Give `path`, or `files` with the files to read.");
				// Exactly as before: the library's own result.
				return await read.execute(given as never, api as never, context);
			}
			const entries = entriesOf(args);
			if (entries.length === 0) throw new Error("`files` is empty: give at least one file to read.");
			return await readMany(read as ToolRegistration, entries, api, context);
		},
	};
	return wrapped as unknown as typeof read;
});

export const reads: Feature = () => ({ wraps: [reading] });
