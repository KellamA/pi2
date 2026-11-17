// The whole output of a shell command whose result had to be shortened (issue #161).
//
// A command's result shows only the end of a long output (the tool's window: the last 2000 lines or 50 KB). Agents
// used to guard against that by cutting the output themselves with `head`, `tail` or `grep`, and when the part they
// kept did not answer the question, ran the command again. So the engine keeps the whole output in a file and says
// where in the result; a second look costs a `read`, not a second run.
//
// The files are only text a program printed, kept for the agent to read back. They live in the data folder, never in
// the conversation's folder (a project's), one folder per conversation: `output/<conversation>/<call>.log`, readable
// by this user only. pi durable's own `bash` spills the same output to a file of its own in the system's temporary
// folder and never removes it; commands.ts runs the command without that, so this is the only copy.
//
// They are not kept for ever. A conversation keeps the files of its last KEEP_PER_CONVERSATION shortened commands,
// each for KEEP_DAYS days at most, and a file holds at most the first MAX_FILE_BYTES of the output. A deleted
// conversation's folder is removed. The engine looks at them as it starts, whenever conversations are archived or
// deleted, whenever a conversation keeps a new one, and once a day.

import { closeSync, mkdirSync, openSync, readdirSync, rmSync, statSync, writeSync } from "node:fs";
import { dirname, join } from "node:path";

/** How many shortened outputs a conversation keeps: the newest. */
export const KEEP_PER_CONVERSATION = 50;
/** How long a file is kept after it was last written. */
export const KEEP_DAYS = 7;
/** How much of one output a file holds: its beginning. Enough for any output an agent would read back. */
export const MAX_FILE_BYTES = 64 * 1024 * 1024;

/** The tool's window, as pi durable's harness bounds a result (its DEFAULT_MAX_LINES and DEFAULT_MAX_BYTES). */
const WINDOW_LINES = 2000;
const WINDOW_BYTES = 50 * 1024;

/** What became of a command's output, once it has ended. */
export type Kept =
	/** The output fitted the window: nothing was kept, since the result holds all of it. */
	| { kept: false }
	/** The whole output, or its first MAX_FILE_BYTES when `capped`, is in `path`. */
	| { kept: true; path: string; lines: number; bytes: number; capped: boolean }
	/** It could not be written (a full disk, say). */
	| { kept: false; failed: string; lines: number; bytes: number };

/** Lines in `text` as a person counts them: a last line without a newline still counts. */
export function countLines(text: string): number {
	let newlines = 0;
	for (let i = text.indexOf("\n"); i !== -1; i = text.indexOf("\n", i + 1)) newlines++;
	return newlines + (text === "" || text.endsWith("\n") ? 0 : 1);
}

/** One command's output on its way to a file. The file is only made once the output is longer than the window. */
export class Recorder {
	#path: string;
	#held: string[] = [];
	#fd: number | undefined;
	#written = 0;
	#bytes = 0;
	#newlines = 0;
	#endsWithNewline = true;
	#capped = false;
	#failed: string | undefined;
	#maxBytes: number;

	constructor(path: string, maxBytes = MAX_FILE_BYTES) {
		this.#path = path;
		this.#maxBytes = maxBytes;
	}

	/** Take the next piece of output, as the command printed it. Never throws: a failure to write is kept for `end`. */
	add(text: string): void {
		if (text === "") return;
		this.#bytes += Buffer.byteLength(text);
		for (let i = text.indexOf("\n"); i !== -1; i = text.indexOf("\n", i + 1)) this.#newlines++;
		this.#endsWithNewline = text.endsWith("\n");
		if (this.#failed !== undefined || this.#capped) return;
		if (this.#fd === undefined) {
			this.#held.push(text);
			// Made a little before the window is full, so a file is there whenever the result is shortened.
			if (this.#bytes < WINDOW_BYTES && this.#newlines < WINDOW_LINES) return;
			this.#open();
			const held = this.#held;
			this.#held = [];
			for (const piece of held) this.#write(piece);
		} else this.#write(text);
	}

	/**
	 * The command has ended. `shortened` is whether its result had to leave some of the output out: only then is the
	 * file kept, since otherwise the result already holds all of it.
	 */
	end(shortened: boolean): Kept {
		if (shortened && this.#fd === undefined && this.#failed === undefined) {
			this.#open();
			for (const piece of this.#held) this.#write(piece);
		}
		this.#held = [];
		if (this.#fd !== undefined) closeSync(this.#fd);
		this.#fd = undefined;
		const lines = this.#newlines + (this.#endsWithNewline ? 0 : 1);
		if (!shortened) {
			rmSync(this.#path, { force: true });
			return { kept: false };
		}
		if (this.#failed !== undefined) {
			rmSync(this.#path, { force: true });
			return { kept: false, failed: this.#failed, lines, bytes: this.#bytes };
		}
		return { kept: true, path: this.#path, lines, bytes: this.#bytes, capped: this.#capped };
	}

	#open(): void {
		try {
			// Made here rather than when the command started: a sweep removes a conversation's folder once it is empty.
			mkdirSync(dirname(this.#path), { recursive: true, mode: 0o700 });
			this.#fd = openSync(this.#path, "w", 0o600);
		} catch (error) {
			this.#failed = (error as Error).message;
		}
	}

	#write(text: string): void {
		if (this.#fd === undefined || this.#failed !== undefined || this.#capped) return;
		let bytes = Buffer.from(text);
		if (this.#written + bytes.length > this.#maxBytes) {
			bytes = bytes.subarray(0, this.#maxBytes - this.#written);
			this.#capped = true;
		}
		try {
			for (let at = 0; at < bytes.length; ) at += writeSync(this.#fd, bytes, at);
			this.#written += bytes.length;
		} catch (error) {
			this.#failed = (error as Error).message;
		}
	}
}

/** The folder of kept outputs, `output` in the data folder. */
export class OutputStore {
	readonly root: string;

	constructor(root: string) {
		this.root = root;
	}

	/** A recorder for one call's output. `callId` names the file, so a call run again after a crash writes the same one. */
	record(conversationId: number, callId: string): Recorder {
		const folder = join(this.root, String(conversationId));
		const name = callId.replace(/[^A-Za-z0-9_-]/g, "_").slice(0, 80) || `call-${Date.now()}`;
		return new Recorder(join(folder, `${name}.log`));
	}

	/** Drop a conversation's files beyond the newest KEEP_PER_CONVERSATION, and any older than KEEP_DAYS. */
	prune(conversationId: number, now = Date.now()): void {
		const folder = join(this.root, String(conversationId));
		const files: { path: string; at: number }[] = [];
		for (const name of entries(folder)) {
			const path = join(folder, name);
			try {
				files.push({ path, at: statSync(path).mtimeMs });
			} catch {}
		}
		files.sort((a, b) => b.at - a.at);
		files.forEach((file, index) => {
			if (index >= KEEP_PER_CONVERSATION || now - file.at > KEEP_DAYS * 86_400_000) rmSync(file.path, { force: true });
		});
		if (entries(folder).length === 0) rmSync(folder, { recursive: true, force: true });
	}

	/** Remove the folders of deleted conversations, and prune the rest. `deleted` says whether a conversation is. */
	sweep(deleted: (conversationId: number) => boolean, now = Date.now()): void {
		for (const name of entries(this.root)) {
			const id = Number(name);
			// Only folders this store made are touched: a conversation's number.
			if (!/^\d+$/.test(name)) continue;
			if (deleted(id)) rmSync(join(this.root, name), { recursive: true, force: true });
			else this.prune(id, now);
		}
	}
}

function entries(folder: string): string[] {
	try {
		return readdirSync(folder);
	} catch {
		return [];
	}
}
