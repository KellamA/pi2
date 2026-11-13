// An agent's reference files: files and folders on this Mac that every conversation of the agent may read.
//
// They are listed in the prompt and read on demand, so they cost tokens only when used, and they are read from disk
// each time, so an edit shows up in the next read. Reading is all that is offered, whatever the conversation's tool
// access, and only inside what the person listed.

import { spawnSync } from "node:child_process";
import { existsSync, readdirSync, readFileSync, realpathSync, statSync } from "node:fs";
import { basename, extname, isAbsolute, join, sep } from "node:path";

export type ReferenceFile = {
	/** Absolute path of a file or a folder. */
	path: string;
	/** What it is for, in the person's words; shown to the model so it knows when to open it. */
	note: string;
};

const MAX_FILES = 50;
const MAX_LINES = 2000;
const MAX_BYTES = 200_000;
const MAX_ENTRIES = 300;
/** Documents that are not plain text but have text in them, which is what the agent is given. */
const DOCUMENTS = new Set([".docx", ".doc", ".rtf", ".odt"]);

/** Check and tidy what the app sends when an agent is saved. */
export function validateReferenceFiles(input: unknown): ReferenceFile[] {
	if (!Array.isArray(input)) throw new Error("files must be a list");
	if (input.length > MAX_FILES) throw new Error(`An agent can have at most ${MAX_FILES} reference files; add a folder instead`);
	const seen = new Set<string>();
	const files: ReferenceFile[] = [];
	for (const item of input as { path?: unknown; note?: unknown }[]) {
		const path = typeof item?.path === "string" ? item.path.trim() : "";
		if (path === "" || !isAbsolute(path)) throw new Error("Each reference file needs a full path");
		if (!existsSync(path)) throw new Error(`Not found: ${path}`);
		if (seen.has(path)) continue;
		seen.add(path);
		files.push({ path, note: typeof item.note === "string" ? item.note.trim().slice(0, 300) : "" });
	}
	return files;
}

const size = (bytes: number) => (bytes < 1024 ? `${bytes} bytes` : bytes < 1024 * 1024 ? `${Math.round(bytes / 1024)} KB` : `${(bytes / 1024 / 1024).toFixed(1)} MB`);

function stat(path: string) {
	try {
		return statSync(path);
	} catch {
		return undefined;
	}
}

/** The prompt section that tells the model what it has. */
export function describeReferenceFiles(files: readonly ReferenceFile[]): string | undefined {
	if (files.length === 0) return undefined;
	const lines = files.map((file) => {
		const info = stat(file.path);
		const kind = info === undefined ? "missing right now" : info.isDirectory() ? "folder" : size(info.size);
		return `- ${file.path} (${kind})${file.note === "" ? "" : `: ${file.note}`}`;
	});
	return [
		"The person has given you these reference files. Open one with the read_reference tool when it bears on the task; do not guess at what they say. A folder can be listed by passing its path, and its files read by their full path.",
		...lines,
	].join("\n");
}

/** Where `path` really is, if it is one of the listed files or inside one of the listed folders. */
export function locateReference(files: readonly ReferenceFile[], path: string): string | undefined {
	const wanted = path.trim();
	const candidates = isAbsolute(wanted)
		? [wanted]
		: [
				// A bare name, or a path relative to one of the folders.
				...files.filter((file) => basename(file.path) === wanted).map((file) => file.path),
				...files.filter((file) => stat(file.path)?.isDirectory()).map((file) => join(file.path, wanted)),
			];
	for (const candidate of candidates) {
		let real: string;
		try {
			real = realpathSync(candidate);
		} catch {
			continue;
		}
		for (const file of files) {
			let root: string;
			try {
				root = realpathSync(file.path);
			} catch {
				continue;
			}
			// Compared after resolving links, so a link inside a folder cannot lead out of it.
			if (real === root || (statSync(root).isDirectory() && real.startsWith(root.endsWith(sep) ? root : root + sep))) return real;
		}
	}
	return undefined;
}

export type ReferenceResult = { text: string; isError?: boolean };

/** Read a listed file (a window of its lines) or list a listed folder. */
export function readReference(files: readonly ReferenceFile[], path: string, offset?: number, limit?: number): ReferenceResult {
	if (files.length === 0) return { text: "This agent has no reference files.", isError: true };
	const real = locateReference(files, path);
	if (real === undefined) {
		return { text: `"${path}" is not one of your reference files or inside one of your reference folders. You have:\n${files.map((file) => `- ${file.path}`).join("\n")}`, isError: true };
	}
	const info = statSync(real);
	if (info.isDirectory()) {
		const entries = readdirSync(real, { withFileTypes: true })
			.filter((entry) => !entry.name.startsWith("."))
			.sort((a, b) => a.name.localeCompare(b.name));
		const shown = entries.slice(0, MAX_ENTRIES).map((entry) => {
			const full = join(real, entry.name);
			return entry.isDirectory() ? `${full}/` : `${full} (${size(stat(full)?.size ?? 0)})`;
		});
		const more = entries.length > MAX_ENTRIES ? `\n… and ${entries.length - MAX_ENTRIES} more` : "";
		return { text: entries.length === 0 ? `${real} is empty.` : shown.join("\n") + more };
	}
	let content: string;
	const kind = extname(real).toLowerCase();
	if (DOCUMENTS.has(kind)) {
		// Word, RTF and OpenDocument files are read as their text. textutil ships with macOS.
		const converted = spawnSync("/usr/bin/textutil", ["-convert", "txt", "-stdout", real], { encoding: "utf8", maxBuffer: 32 * 1024 * 1024, timeout: 20_000 });
		if (converted.status !== 0 || typeof converted.stdout !== "string") return { text: `${real} could not be read as a document. It may be damaged or password-protected.`, isError: true };
		content = converted.stdout;
	} else if (kind === ".pdf") {
		return { text: `${real} is a PDF, which cannot be read here yet. Ask the person to attach it to the conversation instead.`, isError: true };
	} else {
		const bytes = readFileSync(real);
		if (bytes.subarray(0, 8000).includes(0)) return { text: `${real} is not a text file (${size(info.size)}), so it cannot be read here.`, isError: true };
		content = bytes.toString("utf8");
	}
	const lines = content.split("\n");
	const start = Math.max(1, Math.floor(offset ?? 1));
	const count = Math.min(MAX_LINES, Math.max(1, Math.floor(limit ?? MAX_LINES)));
	if (start > lines.length) return { text: `${real} has ${lines.length} lines; there is nothing at line ${start}.`, isError: true };
	let end = Math.min(lines.length, start + count - 1);
	let body = lines.slice(start - 1, end).join("\n");
	// Long lines can make a short window huge; cut on a line boundary where possible.
	while (Buffer.byteLength(body) > MAX_BYTES && end > start) {
		end = start + Math.max(1, Math.floor((end - start + 1) / 2)) - 1;
		body = lines.slice(start - 1, end).join("\n");
	}
	if (Buffer.byteLength(body) > MAX_BYTES) body = Buffer.from(body).subarray(0, MAX_BYTES).toString("utf8");
	const whole = start === 1 && end === lines.length;
	return { text: whole ? body : `${body}\n\n(Lines ${start}–${end} of ${lines.length}. Pass offset: ${end + 1} for more.)` };
}
