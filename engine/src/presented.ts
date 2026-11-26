// Presenting (#946, docs/design/presenting.md): an agent shows the person pictures and mockup pages in a card of their
// own, and can ask them to pick one. The design's "The contract" is what this file builds, and its names are the
// contract's. What is here:
//
// - The tool `present`. Every file it is given is read once, by the conversation's reach as `read` resolves a path (its
//   folder, `~`, `$PI2_SCRATCH`), checked against the limits below and copied, by its content, into the data folder:
//   `presented/<conversation>/blobs/<sha256>`, and a page's manifest in `pages/<sha256>.json`. The file is opened once,
//   without following a link at its name, and read from that one descriptor: its size is checked on the descriptor and
//   the bytes read must be exactly that many, with the same size and time after, or it changed while it was copied and
//   is refused. A page is its HTML file's folder and what is below it, walked without following any link (a link is left
//   out, whether it leads out of the folder or not), without hidden files and folders and `node_modules`.
// - `pi2.presented`, a document of the conversation (fork: its current state), the index the cards and the window read:
//   each presentation's versions, items and question. The tool's result carries the version too, for a card with no
//   access to the document.
// - The question: an Inbox item with `choices` and `presentation` (state.ts), sent under Needs you as a decision that
//   blocks, answered by `claim` as every item is (needs.ts); or, with `wait: false` in a project, a stored decision, whose
//   answer wakes the agent. Either way its end is written into the record.
// - Drawing a page: the engine never loads one. It asks the app that registered (`present.register`) with the event
//   `present.draw`, and takes `present.drawn` only from that connection, for a draw it asked for, once, within bounds.
// - The requests the app and the phone read with: `presented.list`, `presented.picture`, `presented.file`,
//   `presented.network`, and the event `conversation.presented` to the connections that have the conversation open.
//
// Who may send each request is answers.ts's (#963); this file checks again what it serves: whole numbers found only in
// that conversation's record, a blob named only by the record and read only under that conversation's folder, a path of
// a page only as its manifest has it, and nothing but PNG, JPEG, GIF and WebP to a phone.

import { awaitWithContext, type Context } from "@earendil-works/chord/context";
import { AgentDoc, type CommitChange, type ConversationId, defineDoc, defineTool, type ToolExecutionApi, type ToolExecutionResult, type Tx } from "@earendil-works/pi-durable";
import { arr, bool, obj, opt, str } from "@earendil-works/pi-schema";
import { createHash, randomBytes } from "node:crypto";
import { closeSync, constants, cpSync, existsSync, fstatSync, lstatSync, mkdirSync, openSync, readdirSync, readSync, realpathSync, renameSync, rmSync, type Stats, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, extname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { pictureType, sizeText } from "./attachments.ts";
import { type Client, clients, send } from "./clients.ts";
import type { Host } from "./extensions.ts";
import type { Engine, Feature } from "./features.ts";
import { unlessMessaged } from "./heed.ts";
import { chatOf, versions } from "./indexes.ts";
import { MAX_CHOICE, MAX_CHOICES, MAX_QUESTION, MIN_CHOICES, onPresentationEnded, type PresentationEnd, type PresentedAnswer, putNeed } from "./needs.ts";
import { inProject } from "./projects.ts";
import { conversationScratch, scratchPath } from "./scratch.ts";
import { testSwitch } from "./testswitches.ts";

// ---- What is stored (the contract's "What is stored")

export type PresentedSnapshot = { state: "drawn"; sha256: string } | { state: "pending" } | { state: "failed"; reason: string };
/**
 * `console` is every line the page's console printed, as the app gives it: its level first ("log: …", "info: …",
 * "warn: …", "debug: …", "error: …"; a script error or an unhandled rejection is "error: …"). `errors` is how many of
 * them are errors: those that begin "error: ". A warning is a line, not an error.
 */
export type PresentedDrawn = { loadMs: number; blank: boolean; console: string[]; errors: number; blocked: string[] };

/** What the app puts before a console line that is an error: `console.error`, a script error, an unhandled rejection. */
const ERROR_LINE = "error: ";
export const isErrorLine = (line: string) => line.startsWith(ERROR_LINE);
export const errorsIn = (lines: readonly string[]) => lines.filter(isErrorLine).length;

/** A page's console in the agent's answer: its errors by themselves, then its other lines; nothing when it printed nothing. */
export function consoleWords(lines: readonly string[]): string | undefined {
	const errors = lines.filter(isErrorLine).map((line) => line.slice(ERROR_LINE.length));
	const others = lines.filter((line) => !isErrorLine(line));
	const quoted = (some: string[]) => some.map((line) => JSON.stringify(line)).join("; ");
	const parts: string[] = [];
	if (errors.length > 0) parts.push(`${plural(errors.length, "console error")}: ${quoted(errors)}`);
	if (others.length > 0) parts.push(errors.length > 0 ? `${plural(others.length, "other console line")}: ${quoted(others)}` : `${plural(others.length, "console line")}, no errors: ${quoted(others)}`);
	return parts.length === 0 ? undefined : parts.join("; ");
}

export type PresentedItem = {
	label: string;
	caption: string | null;
	kind: "picture" | "page";
	/** The path as the agent gave it. */
	name: string;
	mimeType: string;
	/** A picture's blob, or a page's manifest. */
	sha256: string;
	bytes: number;
	files: number;
	width: number | null;
	height: number | null;
	snapshot: PresentedSnapshot | null;
	drawn: PresentedDrawn | null;
};

export type PresentedQuestion = {
	text: string;
	choices: { id: string; label: string }[];
	words: true;
	/** The Inbox item's id (it waits) or the stored need's (`wait: false`). */
	need: string;
	answer: PresentationEnd | null;
};

export type PresentedVersion = {
	version: number;
	callId: string;
	createdAt: number;
	title: string;
	items: PresentedItem[];
	question: PresentedQuestion | null;
	/**
	 * The person's "Allow network for this page", for this version's pages alone: a new version starts with it off, so a page
	 * the agent changes after the person allowed it does not inherit that (#994's read). `changes` is every time it was
	 * turned on or off, the newest 100, so it can be seen afterwards.
	 */
	network: { allowed: boolean; changes: { allow: boolean; at: number }[] };
};

export type PresentationRecord = { id: string; versions: PresentedVersion[] };
export type PresentedDocShape = { next: number; items: Record<string, PresentationRecord> };

/** A conversation's presentations. Its current state goes with a fork, whose folder of files is cloned (`forked`). */
export const PresentedDoc = defineDoc<PresentedDocShape>({
	kind: "pi2.presented",
	version: 1,
	scope: "conversation",
	history: "latest",
	fork: "current",
	initial: () => ({ next: 1, items: {} }),
	checkpointWhen: () => true,
});

/** A page's manifest, as `pages/<sha256>.json` holds it: its entry and every file by its relative, `/`-separated path. */
export type PageManifest = { entry: string; files: Record<string, { sha256: string; bytes: number; type: string }> };

// ---- Limits (the contract's "Where presented files are copied, and their limits")

const MB = 1024 * 1024;
export const LIMITS = {
	items: 6,
	label: 12,
	title: 120,
	caption: 400,
	picture: 20 * MB,
	side: 16_384,
	svg: 2 * MB,
	pageFiles: 500,
	pageBytes: 50 * MB,
	call: 100 * MB,
	conversation: 500 * MB,
	/** Folders a page's walk may open before it is refused as no mockup's: a guard against a page put in a big tree. */
	pageFolders: 2_000,
	/** The longest path an item or a page's file may have, and the longest name in it, in bytes of UTF-8. */
	path: 1_024,
	name: 255,
	/** How many changes of a version's network switch its record keeps: the newest. */
	networkChanges: 100,
	/** What `present.drawn` may carry: the findings' count and length, and the reason a page could not be drawn. */
	console: 50,
	consoleLine: 500,
	blocked: 20,
	blockedAddress: 2_048,
	reason: 500,
	/** Draws asked for and not yet answered, across conversations: the oldest is forgotten past it (its page stays pending). */
	pendingDraws: 200,
} as const;

/** The size the app draws a page at, in points: a card's, and its snapshot is a PNG of twice that. */
export const DRAW_WIDTH = 1280;
export const DRAW_HEIGHT = 800;

/**
 * How long the tool waits for the app to draw its pages, all at once: 20 seconds. `PI2_PRESENT_DRAW_MS` sets another, for
 * a test that must tell a page drawn from one that was not; a release engine ignores it (testswitches.ts).
 */
export const DRAW_WAIT_MS = (() => {
	const given = Number(testSwitch("PI2_PRESENT_DRAW_MS"));
	return Number.isFinite(given) && given > 0 ? given : 20_000;
})();

// ---- Words

const text = (value: string) => [{ type: "text" as const, text: value }];
const refuse = (value: string): ToolExecutionResult => ({ output: text(value), isError: true });
const count = (n: number) => n.toLocaleString("en-US");
const plural = (n: number, one: string, many = `${one}s`) => `${count(n)} ${n === 1 ? one : many}`;
const megabytes = (bytes: number) => `${Math.round(bytes / MB)} MB`;

/** A refusal of the tool, with what to do instead: thrown inside the copying, answered as the call's error. */
class Refusal extends Error {}

/** What the page and the app are told when a presentation, version or item is not in the conversation's record. */
export const NOT_PRESENTED = "This conversation has no such presentation.";
export const NOT_DRAWN = "That page has not been drawn yet: pi² draws it while it is open on this Mac. Try again once it has been drawn.";
export const NO_SVG_TO_A_DEVICE = "An SVG picture is shown on the Mac only: it is not sent to a phone. Look at it in pi² on the Mac.";

// ---- Reading what the agent gave, once and without following a link

const OPEN_FLAGS = constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK;
const UNICODE_SPACES = /[\u00A0\u2000-\u200A\u202F\u205F\u3000]/g;

/** A path as `read` resolves it (pi durable's `resolvePath`, with the same spellings tried): absolute, from `cwd`. */
export function resolveGiven(given: string, cwd: string): string {
	let path = given.replace(UNICODE_SPACES, " ");
	if (path.startsWith("@")) path = path.slice(1);
	if (path === "~") path = homedir();
	else if (path.startsWith("~/")) path = join(homedir(), path.slice(2));
	else if (path.startsWith("file://")) {
		try {
			path = fileURLToPath(path);
		} catch {
			// As read does: a malformed address stays an ordinary path.
		}
	}
	const resolved = isAbsolute(path) ? resolve(path) : resolve(cwd, path);
	// The spellings `read` also tries for a name macOS may store otherwise (pi durable's `resolveReadToolPath`).
	for (const variant of [resolved, resolved.normalize("NFD"), resolved.replace(/'/g, "\u2019"), resolved.normalize("NFD").replace(/'/g, "\u2019")]) {
		if (lstatSync(variant, { throwIfNoEntry: false }) !== undefined) return variant;
	}
	return resolved;
}

/**
 * A file's bytes, read once from one descriptor opened without following a link at its name: refused if it is not a
 * plain file, is larger than `max`, or changed while it was read (its size or time, or the bytes read not its size).
 * `between` runs after the check and before the read: a test changes the file there. `opened` is told what was
 * opened, before anything is read, and throws to refuse it (a page's file that is no longer under its folder).
 */
export function readOnce(path: string, max: number, name: string, tooLarge: (bytes: number) => string, between?: () => void, opened?: (stats: Stats) => void): Buffer {
	let fd: number;
	try {
		fd = openSync(path, OPEN_FLAGS);
	} catch (error) {
		const code = (error as NodeJS.ErrnoException).code;
		if (code === "ELOOP") throw new Refusal(`${name} is a symbolic link, which present does not follow. Present the file it points to.`);
		if (code === "ENOENT" || code === "ENOTDIR") throw new Refusal(`${name} does not exist. Check the path; a relative one is read from the conversation's folder.`);
		if (code === "EACCES" || code === "EPERM") throw new Refusal(`${name} cannot be read: permission was refused.`);
		throw new Refusal(`${name} cannot be read: ${(error as Error).message}`);
	}
	try {
		const before = fstatSync(fd);
		if (before.isDirectory()) throw new Refusal(`${name} is a folder. Present a picture file, or a page's HTML file.`);
		if (!before.isFile()) throw new Refusal(`${name} is not a plain file. Present a picture file, or a page's HTML file.`);
		opened?.(before);
		if (before.size > max) throw new Refusal(tooLarge(before.size));
		between?.();
		const bytes = Buffer.alloc(before.size);
		let read = 0;
		while (read < before.size) {
			const got = readSync(fd, bytes, read, before.size - read, read);
			if (got === 0) break;
			read += got;
		}
		const extra = readSync(fd, Buffer.alloc(1), 0, 1, before.size);
		const after = fstatSync(fd);
		if (read !== before.size || extra !== 0 || !same(before, after)) throw new Refusal(`${name} changed while it was being copied. Present it again once it has been written.`);
		return bytes;
	} finally {
		closeSync(fd);
	}
}

/** A copy of what a commit's draft or a snapshot holds, as plain data. */
const plain = <T>(value: T): T => JSON.parse(JSON.stringify(value)) as T;

const same = (a: Stats, b: Stats) => a.size === b.size && a.mtimeMs === b.mtimeMs && a.ino === b.ino && a.dev === b.dev;

/** A raster picture's pixels, from its header: PNG, GIF, WebP and JPEG. Undefined when the header cannot be read. */
export function pictureSize(bytes: Buffer, mimeType: string): { width: number; height: number } | undefined {
	try {
		if (mimeType === "image/png") return bytes.subarray(12, 16).toString("latin1") === "IHDR" ? { width: bytes.readUInt32BE(16), height: bytes.readUInt32BE(20) } : undefined;
		if (mimeType === "image/gif") return { width: bytes.readUInt16LE(6), height: bytes.readUInt16LE(8) };
		if (mimeType === "image/webp") {
			const chunk = bytes.subarray(12, 16).toString("latin1");
			if (chunk === "VP8 ") return { width: bytes.readUInt16LE(26) & 0x3fff, height: bytes.readUInt16LE(28) & 0x3fff };
			if (chunk === "VP8L") {
				const b = bytes.subarray(21, 25);
				return { width: 1 + (((b[1]! & 0x3f) << 8) | b[0]!), height: 1 + (((b[3]! & 0x0f) << 10) | (b[2]! << 2) | ((b[1]! & 0xc0) >> 6)) };
			}
			if (chunk === "VP8X") return { width: 1 + bytes.readUIntLE(24, 3), height: 1 + bytes.readUIntLE(27, 3) };
			return undefined;
		}
		if (mimeType === "image/jpeg") {
			let at = 2;
			while (at + 9 < bytes.length) {
				if (bytes[at] !== 0xff) return undefined;
				const marker = bytes[at + 1]!;
				if (marker === 0xff) {
					at += 1;
					continue;
				}
				if (marker === 0xd8 || marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) {
					at += 2;
					continue;
				}
				const frame = marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc;
				if (frame) return { width: bytes.readUInt16BE(at + 7), height: bytes.readUInt16BE(at + 5) };
				at += 2 + bytes.readUInt16BE(at + 2);
			}
			return undefined;
		}
	} catch {
		return undefined;
	}
	return undefined;
}

/** Whether a file is an SVG picture: after a byte order mark, an XML declaration, comments and a doctype, an `<svg` element. */
export function isSvg(bytes: Buffer): boolean {
	let head = bytes.subarray(0, 64 * 1024).toString("utf8");
	if (head.startsWith("\uFEFF")) head = head.slice(1);
	for (;;) {
		head = head.trimStart();
		const skip = /^(<\?xml[\s\S]*?\?>|<!--[\s\S]*?-->|<!DOCTYPE[^>]*>)/i.exec(head);
		if (skip === null) break;
		head = head.slice(skip[0].length);
	}
	return /^<svg[\s>/]/i.test(head);
}

/** The size an SVG says it is: its `width` and `height` in pixels, or its `viewBox`. Null when it says neither. */
export function svgSize(bytes: Buffer): { width: number; height: number } | null {
	const tag = /<svg\b[^>]*>/i.exec(bytes.subarray(0, 64 * 1024).toString("utf8"))?.[0];
	if (tag === undefined) return null;
	const attribute = (name: string) => new RegExp(`\\s${name}\\s*=\\s*["']([^"']*)["']`, "i").exec(tag)?.[1]?.trim();
	const pixels = (value: string | undefined) => {
		const match = value === undefined ? null : /^(\d+(?:\.\d+)?)(px)?$/.exec(value);
		return match === null ? undefined : Math.round(Number(match[1]));
	};
	const width = pixels(attribute("width"));
	const height = pixels(attribute("height"));
	if (width !== undefined && height !== undefined) return { width, height };
	const box = attribute("viewBox")?.split(/[\s,]+/).map(Number);
	if (box?.length === 4 && box.every(Number.isFinite) && box[2]! > 0 && box[3]! > 0) return { width: Math.round(box[2]!), height: Math.round(box[3]!) };
	return null;
}

/** What a page's file is served as, by its ending; what has none known is plain bytes. */
const PAGE_TYPES: Record<string, string> = {
	".html": "text/html",
	".htm": "text/html",
	".css": "text/css",
	".js": "text/javascript",
	".mjs": "text/javascript",
	".json": "application/json",
	".map": "application/json",
	".txt": "text/plain",
	".md": "text/plain",
	".csv": "text/csv",
	".xml": "application/xml",
	".svg": "image/svg+xml",
	".png": "image/png",
	".jpg": "image/jpeg",
	".jpeg": "image/jpeg",
	".gif": "image/gif",
	".webp": "image/webp",
	".avif": "image/avif",
	".ico": "image/x-icon",
	".woff": "font/woff",
	".woff2": "font/woff2",
	".ttf": "font/ttf",
	".otf": "font/otf",
	".wasm": "application/wasm",
	".mp4": "video/mp4",
	".webm": "video/webm",
	".mp3": "audio/mpeg",
	".wav": "audio/wav",
};
const pageType = (path: string) => PAGE_TYPES[extname(path).toLowerCase()] ?? "application/octet-stream";

/** Whether a name in a page's folder is left out: hidden (`.git`, `.env`) or `node_modules`. */
const leftOutName = (name: string) => name.startsWith(".") || name === "node_modules";

/** Whether a path is within the bounds every path presenting keeps has: 1,024 bytes, and 255 a name, in UTF-8. */
export const pathFits = (path: string, separator = "/") => Buffer.byteLength(path) <= LIMITS.path && path.split(separator).every((part) => Buffer.byteLength(part) <= LIMITS.name);

/** A manifest path the scheme handler can serve as it is: printable, no `.` or `..` part, within the bounds. */
const servablePath = (path: string) => path.length > 0 && pathFits(path) && !/[\u0000-\u001f\u007f\\]/.test(path) && path.split("/").every((part) => part !== "" && part !== "." && part !== "..");

/** What a page's walk read: every file's bytes by its manifest path, and what it left out, by why. */
type Walked = { files: Map<string, Buffer>; bytes: number; links: number; hidden: number; unservable: number };

/**
 * A page's folder: the HTML file's own folder and everything below it, walked with `lstat` and never through a link,
 * hidden files and folders and `node_modules` left out, each file read once (`readOnce`). Refused over 500 files or 50
 * MB, or over 2,000 folders; refused outright for the home folder, a folder that holds it, and `~/Library`, which hold
 * the person's whole Mac (and folders macOS asks before letting pi² read). All of it on real paths: the folder is the
 * real path of the HTML file's, compared with the home folder's real path, and walked from there; a folder that has
 * become a link (or is no longer its real path) is refused before it is listed, and each file opened must be the file
 * at its path, in a folder whose real path is under the page's. `hooks.listed` runs after each folder is listed: a test
 * swaps a folder there.
 */
export function walkPage(entry: string, name: string, hooks: { listed?: (folder: string) => void } = {}): Walked {
	// Judged on real paths: a link to the home folder, at the page's folder or above it, is the home folder (#994's read).
	let root: string;
	try {
		root = realpathSync(dirname(entry));
	} catch (error) {
		throw new Refusal(`The folder of ${name} cannot be read: ${(error as Error).message}`);
	}
	let home: string;
	try {
		home = realpathSync(homedir());
	} catch {
		home = resolve(homedir());
	}
	const under = (path: string, folder: string) => path === folder || path.startsWith(folder.endsWith(sep) ? folder : folder + sep);
	if (under(home, root) || root === join(home, "Library")) {
		throw new Refusal(`${name} is in ${root}, which holds far more than a mockup. Put the page in a folder of its own, with only what it needs, and present it from there.`);
	}
	const changed = () => new Refusal(`The folder of ${name} changed while it was being copied: a folder in it became a link, or a file moved out of it. Present it again once it is written.`);
	/** The file opened is the one at its path, and that path's folder, really, is under the page's. */
	const stillInside = (path: string) => (stats: Stats) => {
		let real: string;
		let there: Stats | undefined;
		try {
			real = realpathSync(dirname(path));
			there = lstatSync(path, { throwIfNoEntry: false });
		} catch {
			throw changed();
		}
		if (!under(real, root) || there === undefined || there.ino !== stats.ino || there.dev !== stats.dev) throw changed();
	};
	const walked: Walked = { files: new Map(), bytes: 0, links: 0, hidden: 0, unservable: 0 };
	const tooMany = () => new Refusal(`The page's folder, ${root}, holds more than ${count(LIMITS.pageFiles)} files. Keep the folder to the mockup: only the page and what it loads.`);
	const tooLarge = (bytes: number) => new Refusal(`The page's folder, ${root}, holds more than ${megabytes(LIMITS.pageBytes)} (${sizeText(bytes)} at least). Keep the folder to the mockup, with smaller pictures.`);
	const add = (path: string, relativePath: string) => {
		if (!servablePath(relativePath)) {
			walked.unservable += 1;
			return;
		}
		if (walked.files.size >= LIMITS.pageFiles) throw tooMany();
		const bytes = readOnce(path, LIMITS.pageBytes - walked.bytes, `${relativePath} in the page's folder`, (size) => tooLarge(walked.bytes + size).message, undefined, stillInside(path));
		walked.bytes += bytes.length;
		walked.files.set(relativePath, bytes);
	};
	const entryName = basename(entry);
	add(join(root, entryName), entryName);
	const folders = [root];
	let opened = 0;
	while (folders.length > 0) {
		const folder = folders.shift()!;
		if (++opened > LIMITS.pageFolders) throw new Refusal(`The page's folder, ${root}, holds more than ${count(LIMITS.pageFolders)} folders. Keep the folder to the mockup.`);
		// A folder found a folder when its parent was listed may be a link by now: it is not listed then.
		let info: Stats | undefined;
		let real: string | undefined;
		try {
			info = lstatSync(folder, { throwIfNoEntry: false });
			real = realpathSync(folder);
		} catch {}
		if (info === undefined || info.isSymbolicLink() || !info.isDirectory() || real !== folder) throw changed();
		let names: import("node:fs").Dirent[];
		try {
			names = readdirSync(folder, { withFileTypes: true });
		} catch (error) {
			throw new Refusal(`The page's folder ${folder} cannot be read: ${(error as Error).message}`);
		}
		hooks.listed?.(folder);
		names.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
		for (const one of names) {
			const path = join(folder, one.name);
			const relativePath = relative(root, path).split(sep).join("/");
			if (relativePath === entryName) continue;
			if (leftOutName(one.name)) {
				walked.hidden += 1;
				continue;
			}
			// `withFileTypes` reads the entry itself, as `lstat` does: a link is never followed, whatever it points at.
			if (one.isSymbolicLink()) walked.links += 1;
			else if (one.isDirectory()) folders.push(path);
			else if (one.isFile()) add(path, relativePath);
		}
	}
	return walked;
}

// ---- Where the files are kept: presented/<conversation>/ in the data folder

/** `presented` in the data folder. */
export const presentedRoot = (home: string) => join(home, "presented");

/**
 * The folder `part` (`blobs` or `pages`) of conversation `folder`'s files, made if `make`, and checked to be a folder at
 * each step from `presented` down, none of them a link: what is read or written there is under the data folder only.
 */
function partFolder(home: string, folder: number, part: "blobs" | "pages", make: boolean): string {
	if (!Number.isSafeInteger(folder) || folder < 0) throw new Error(NOT_PRESENTED);
	const steps = [presentedRoot(home), join(presentedRoot(home), String(folder)), join(presentedRoot(home), String(folder), part)];
	for (const step of steps) {
		if (make) mkdirSync(step, { recursive: true, mode: 0o700 });
		const found = lstatSync(step, { throwIfNoEntry: false });
		if (found === undefined && !make) throw new Error("The presented files of this conversation are not there.");
		if (found === undefined || found.isSymbolicLink() || !found.isDirectory()) throw new Error(`${step} is not a folder pi² made, so nothing is read or written there.`);
	}
	return steps[2]!;
}

const SHA256 = /^[0-9a-f]{64}$/;
const sha256 = (bytes: Buffer) => createHash("sha256").update(bytes).digest("hex");
const fileName = (part: "blobs" | "pages", sha: string) => (part === "pages" ? `${sha}.json` : sha);

/** Keep `bytes` under conversation `folder`'s `part`, once, by its SHA-256, written whole before it takes its name. */
function keep(home: string, folder: number, part: "blobs" | "pages", bytes: Buffer): string {
	const sha = sha256(bytes);
	const target = join(partFolder(home, folder, part, true), fileName(part, sha));
	const there = lstatSync(target, { throwIfNoEntry: false });
	if (there?.isFile() === true && there.size === bytes.length) return sha;
	const partial = `${target}.${randomBytes(6).toString("hex")}.partial`;
	writeFileSync(partial, bytes, { flag: "wx", mode: 0o600 });
	renameSync(partial, target);
	return sha;
}

/** Whether conversation `folder` already keeps the file of that SHA-256. */
function kept(home: string, folder: number, part: "blobs" | "pages", sha: string): boolean {
	return lstatSync(join(presentedRoot(home), String(folder), part, fileName(part, sha)), { throwIfNoEntry: false })?.isFile() === true;
}

/**
 * A file kept for conversation `folder`, by the SHA-256 its record names: read under `presented/<folder>/<part>/` only,
 * never through a link, and checked against that SHA-256, so a file changed on disk is refused rather than served.
 */
export function readKept(home: string, folder: number, part: "blobs" | "pages", sha: string): Buffer {
	if (!SHA256.test(sha)) throw new Error(NOT_PRESENTED);
	const path = join(partFolder(home, folder, part, false), fileName(part, sha));
	let bytes: Buffer;
	try {
		bytes = readOnce(path, LIMITS.call, "The presented file", () => "The presented file is larger than pi² keeps.");
	} catch (error) {
		throw new Error(error instanceof Refusal ? "The presented file is not there, or cannot be read." : (error as Error).message);
	}
	if (sha256(bytes) !== sha) throw new Error("The presented file has changed on disk since it was kept, so it is not shown.");
	return bytes;
}

/** How many bytes conversation `folder` keeps, of both parts. */
function folderBytes(home: string, folder: number): number {
	let total = 0;
	for (const part of ["blobs", "pages"]) {
		const path = join(presentedRoot(home), String(folder), part);
		let names: string[];
		try {
			names = readdirSync(path);
		} catch {
			continue;
		}
		for (const name of names) {
			const info = lstatSync(join(path, name), { throwIfNoEntry: false });
			if (info?.isFile() === true) total += info.size;
		}
	}
	return total;
}

/** Settings › Storage's line (`engine.info`'s `presented`): the bytes kept, and in how many conversations. */
export function presentedStorage(home: string): { bytes: number; conversations: number } {
	let bytes = 0;
	let conversations = 0;
	let names: string[];
	try {
		names = readdirSync(presentedRoot(home));
	} catch {
		return { bytes: 0, conversations: 0 };
	}
	for (const name of names) {
		if (!/^\d+$/.test(name)) continue;
		const own = folderBytes(home, Number(name));
		if (own === 0) continue;
		bytes += own;
		conversations += 1;
	}
	return { bytes, conversations };
}

// ---- The record

/** A presentation's id: "p" and a whole number, as `next` gives them. */
const PRESENTATION_ID = /^p[1-9][0-9]{0,8}$/;

/** An item of a version of a presentation, found only in that conversation's record, from parameters checked here. */
export function findItem(doc: PresentedDocShape | undefined, presentation: unknown, version: unknown, item: unknown): { record: PresentationRecord; version: PresentedVersion; item: PresentedItem; index: number } {
	if (typeof presentation !== "string" || !PRESENTATION_ID.test(presentation)) throw new Error("presentation must be a presentation's id, such as p2");
	if (typeof version !== "number" || !Number.isSafeInteger(version) || version < 1) throw new Error("version must be a whole number, from 1");
	if (typeof item !== "number" || !Number.isSafeInteger(item) || item < 0) throw new Error("item must be a whole number, from 0");
	const record = doc !== undefined && Object.hasOwn(doc.items, presentation) ? doc.items[presentation] : undefined;
	const found = record?.versions.find((one) => one.version === version);
	const entry = found?.items[item];
	if (record === undefined || found === undefined || entry === undefined) throw new Error(NOT_PRESENTED);
	return { record, version: found, item: entry, index: item };
}

/**
 * What `presented.page` answers of a manifest: its entry and every file's path, size and type, by path. Bounded by a
 * page's own limits: 500 files, each path 1,024 bytes (2,048 once escaped as JSON, a `"` being two) with about 62 bytes
 * of fields, and the entry's name 255: at most about 1.06 MB. A file whose entry is not whole is left out, as is the
 * entry if the manifest does not list it, which the engine never writes.
 */
export function pageListing(manifest: PageManifest): { entry: string; files: { path: string; bytes: number; type: string }[] } {
	const files = Object.entries(manifest.files)
		.filter(([, file]) => typeof file === "object" && file !== null && Number.isSafeInteger(file.bytes) && file.bytes >= 0 && typeof file.type === "string" && typeof file.sha256 === "string")
		.map(([path, file]) => ({ path, bytes: file.bytes, type: file.type }))
		.sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0));
	if (!files.some((file) => file.path === manifest.entry)) throw new Error("The page's list of files cannot be read.");
	return { entry: manifest.entry, files };
}

/** What a picture request answers: the picture's bytes or the page's snapshot, never an SVG to a device. */
export function servedPicture(item: PresentedItem, device: boolean): { part: "blobs"; sha256: string; mimeType: string } {
	if (item.kind === "page") {
		if (item.snapshot?.state !== "drawn") throw new Error(NOT_DRAWN);
		return { part: "blobs", sha256: item.snapshot.sha256, mimeType: "image/png" };
	}
	if (device && item.mimeType === "image/svg+xml") throw new Error(NO_SVG_TO_A_DEVICE);
	return { part: "blobs", sha256: item.sha256, mimeType: item.mimeType };
}

// ---- The answer the agent is given

const DEFAULT_LABELS = "ABCDEF";

function describeDrawn(item: PresentedItem, noApp: boolean): string {
	const parts = [`page, ${plural(item.files, "file")}, ${sizeText(item.bytes)}`];
	const snapshot = item.snapshot;
	if (snapshot?.state === "pending") {
		parts.push(
			noApp
				? "not drawn yet: pi² is not open on this Mac. The person sees it once it is; nothing was checked"
				: `not drawn yet: pi² did not draw it within ${Math.round(DRAW_WAIT_MS / 1000)} seconds. The person sees it once it is drawn; nothing was checked`,
		);
		return parts.join("; ");
	}
	if (snapshot?.state === "failed") {
		parts.push(`could not be drawn: ${snapshot.reason}`);
		return parts.join("; ");
	}
	const drawn = item.drawn;
	if (drawn === null) return parts.join("; ");
	parts.push(`loaded in ${(drawn.loadMs / 1000).toFixed(1)} s`);
	if (item.width !== null && item.height !== null) parts.push(`drawn ${item.width}×${item.height}${item.height > DRAW_HEIGHT ? " (taller than the window: it scrolls)" : ""}`);
	if (drawn.blank) parts.push("**it looks blank**: nothing but its background was drawn, and its body has no text");
	const said = consoleWords(drawn.console);
	if (said !== undefined) parts.push(said);
	if (drawn.blocked.length > 0) parts.push(`blocked, since the network is off: ${drawn.blocked.join(", ")} (put it in the folder instead)`);
	return parts.join("; ");
}

/** The tool's answer: what was shown, item by item, and how to show a new version. */
export function answerFor(record: PresentationRecord, version: PresentedVersion, snapshots: string[], noApp: boolean): string {
	const lines = [`Presented "${version.title}" as ${record.id}, version ${version.version}. The person sees a card in the conversation and can open it in a window.`];
	for (const item of version.items) {
		const size = item.width === null || item.height === null ? "" : `, ${item.width}×${item.height}`;
		const what = item.kind === "page" ? describeDrawn(item, noApp) : `${LABEL_OF[item.mimeType] ?? item.mimeType}${size}, ${sizeText(item.bytes)}`;
		lines.push(`${item.label}  ${item.name}: ${what}`);
	}
	if (snapshots.length > 0) lines.push(`Pictures of the pages as drawn: ${snapshots.join(", ")}. Read ${snapshots.length === 1 ? "it" : "them"}, or look at ${snapshots.length === 1 ? "it" : "them"}, to check.`);
	lines.push(`To show a new version of this, call present again with update: "${record.id}".`);
	return lines.join("\n");
}

const LABEL_OF: Record<string, string> = { "image/png": "PNG", "image/jpeg": "JPEG", "image/gif": "GIF", "image/webp": "WebP", "image/svg+xml": "SVG" };

/** What the agent is told of the person's answer to the question. */
export function answeredWith(question: PresentedQuestion, end: PresentationEnd, labels: string[]): string {
	if ("ended" in end) {
		if (end.ended === "messaged") return "The person sent you a message instead of answering the question; it follows. The question was taken away: present again with update if you still need the answer.";
		if (end.ended === "withdrawn") return "The question was withdrawn before the person answered it.";
		return "The question was stopped before the person answered it.";
	}
	if ("words" in end) return end.words.includes("\n") ? `The person answered:\n\n${end.words.trim()}` : `The person answered: ${end.words.trim()}`;
	// A default choice ("Use B") is said by its item's label: "The person chose B."
	const index = question.choices.findIndex((choice) => choice.label === end.chose);
	const offered = labels[index];
	if (offered !== undefined && end.chose === `Use ${offered}`) return `The person chose ${offered}.`;
	return `The person chose “${end.chose}”.`;
}

// ---- The tool's checks, before anything is copied

type Given = {
	title: string;
	items: { path: string; label?: string; caption?: string }[];
	question?: string;
	choices?: string[];
	wait?: boolean;
	update?: string;
};

type Checked = {
	title: string;
	items: { path: string; label: string; caption: string | null }[];
	question: { text: string; choices: { id: string; label: string }[]; wait: boolean } | null;
	update: string | null;
};

/** The call's arguments checked, or a refusal saying what to do instead. Nothing is read yet. */
export function checkGiven(args: Given, inAProject: boolean): Checked | string {
	const title = (args.title ?? "").replace(/\s+/g, " ").trim();
	if (title === "") return "Give a title: what is shown, in a few words, such as \"Sign-in screen, three layouts\".";
	if (title.length > LIMITS.title) return `The title is ${title.length} characters; keep it to ${LIMITS.title}, a few words.`;
	if (!Array.isArray(args.items) || args.items.length === 0) return "Give at least one item to show: a picture file or a page's HTML file.";
	if (args.items.length > LIMITS.items) return `${args.items.length} items is more than one card shows: give ${LIMITS.items} at most, or present them in two calls.`;
	const items: Checked["items"] = [];
	for (const [index, item] of args.items.entries()) {
		const path = typeof item?.path === "string" ? item.path.trim() : "";
		if (path === "") return `Item ${index + 1} has no path: give a picture file or a page's HTML file.`;
		if (!pathFits(path)) return `The path of item ${index + 1} is ${count(Buffer.byteLength(path))} bytes, or has a name over ${LIMITS.name}: a path can be ${count(LIMITS.path)} bytes at most, and each name in it ${LIMITS.name}. Give a shorter one.`;
		const given = (item.label ?? "").replace(/\s+/g, " ").trim();
		const label = given === "" ? DEFAULT_LABELS[index]! : given;
		if (label.length > LIMITS.label) return `The label “${label}” is ${label.length} characters; keep labels to ${LIMITS.label}, such as “Compact”.`;
		const twin = items.find((other) => other.label.toLowerCase() === label.toLowerCase());
		if (twin !== undefined) return `Two items are labelled “${label}”. Give each its own label, or leave labels out for A, B, C… in order.`;
		const caption = (item.caption ?? "").trim();
		if (caption.length > LIMITS.caption) return `The caption of ${label} is ${caption.length} characters; keep it to a line or two (${LIMITS.caption} characters at most).`;
		items.push({ path, label, caption: caption === "" ? null : caption });
	}
	let question: Checked["question"] = null;
	const asked = (args.question ?? "").trim();
	if (args.choices !== undefined && asked === "") return "choices go with question: give the question they answer, or leave choices out.";
	if (asked !== "") {
		if (asked.length > MAX_QUESTION) return `The question is ${count(asked.length)} characters; the most is ${count(MAX_QUESTION)}. Say it more briefly.`;
		let labels: string[];
		if (args.choices === undefined) labels = items.map((item) => `Use ${item.label}`);
		else {
			labels = args.choices.map((choice) => String(choice).replace(/\s+/g, " ").trim());
			if (labels.length < MIN_CHOICES || labels.length > MAX_CHOICES) return `Give ${MIN_CHOICES} to ${MAX_CHOICES} choices, or leave choices out for one per item (“Use A”, “Use B”…).`;
			if (labels.some((label) => label === "")) return "A choice is empty. Give each choice a few words.";
			const long = labels.find((label) => label.length > MAX_CHOICE);
			if (long !== undefined) return `The choice “${long}” is ${long.length} characters; the most is ${MAX_CHOICE}. Shorten it.`;
			if (new Set(labels.map((label) => label.toLowerCase())).size !== labels.length) return "Two choices are the same. Give each its own words.";
		}
		if (args.wait === false && !inAProject) return "In a conversation outside a project, a question waits for its answer; leave out wait.";
		question = { text: asked, choices: labels.map((label, index) => ({ id: `c${index + 1}`, label })), wait: args.wait !== false };
	}
	const update = (args.update ?? "").trim();
	if (update !== "" && !PRESENTATION_ID.test(update)) return `“${update}” is not the id of a presentation: an id is p and a number, such as p2, as an earlier present said.`;
	return { title, items, question, update: update === "" ? null : update };
}

// ---- Copying, before the record is written

export type Copied = { item: Omit<PresentedItem, "label" | "caption">; keep: { part: "blobs" | "pages"; bytes: Buffer }[] };

/** Read one item's file (or a page's folder) and check it against the limits; nothing is written yet. */
export function copyItem(path: string, given: string): Copied {
	const name = `“${given}”`;
	const ending = extname(path).toLowerCase();
	if (ending === ".html" || ending === ".htm") {
		const walked = walkPage(path, name);
		// No prototype: a file named `__proto__` is a file like any other.
		const files: PageManifest["files"] = Object.create(null);
		const keep: Copied["keep"] = [];
		for (const [relativePath, bytes] of [...walked.files].sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))) {
			files[relativePath] = { sha256: sha256(bytes), bytes: bytes.length, type: pageType(relativePath) };
			keep.push({ part: "blobs", bytes });
		}
		const manifest: PageManifest = { entry: basename(path), files };
		const manifestBytes = Buffer.from(JSON.stringify(manifest));
		keep.push({ part: "pages", bytes: manifestBytes });
		return {
			item: { kind: "page", name: given, mimeType: "text/html", sha256: sha256(manifestBytes), bytes: walked.bytes, files: walked.files.size, width: null, height: null, snapshot: { state: "pending" }, drawn: null },
			keep,
		};
	}
	const bytes = readOnce(path, LIMITS.picture, name, (size) => `${name} is ${sizeText(size)}; a picture can be ${megabytes(LIMITS.picture)} at most. Scale it down, or save it as JPEG, and present that.`);
	const raster = pictureType(bytes.subarray(0, 16));
	let mimeType: string;
	let size: { width: number; height: number } | null;
	if (raster !== undefined) {
		mimeType = raster.mimeType;
		const read = pictureSize(bytes, mimeType);
		if (read === undefined) throw new Refusal(`${name} starts as a ${raster.label} picture but its size cannot be read: it may be damaged. Save it again and present that.`);
		size = read;
	} else if (ending === ".svg" || isSvg(bytes)) {
		if (!isSvg(bytes)) throw new Refusal(`${name} is named .svg but is not an SVG picture. Save it as one, or as PNG, and present that.`);
		if (bytes.length > LIMITS.svg) throw new Refusal(`${name} is an SVG of ${sizeText(bytes.length)}; an SVG can be ${megabytes(LIMITS.svg)} at most. Simplify it, or save it as PNG, and present that.`);
		mimeType = "image/svg+xml";
		size = svgSize(bytes);
	} else {
		throw new Refusal(`${name} is neither a picture present shows (PNG, JPEG, GIF, WebP or SVG) nor a page (an .html or .htm file). Save it as one of those and present that.`);
	}
	if (size !== null && (size.width > LIMITS.side || size.height > LIMITS.side)) {
		throw new Refusal(`${name} is ${size.width}×${size.height} pixels; a picture can be ${count(LIMITS.side)} a side at most. Scale it down and present that.`);
	}
	return {
		item: { kind: "picture", name: given, mimeType, sha256: sha256(bytes), bytes: bytes.length, files: 1, width: size?.width ?? null, height: size?.height ?? null, snapshot: null, drawn: null },
		keep: [{ part: "blobs", bytes }],
	};
}

// ---- Drawing pages: the app that registered draws, and its answer is checked

/** A page to draw: the conversation whose record holds it, and where in that record. */
type PageRef = { conversation: number; presentation: string; version: number; item: number };
const pageKey = (page: PageRef) => `${page.conversation}/${page.presentation}/${page.version}/${page.item}`;

type Draw = { page: PageRef; host: Client; settled: Promise<void>; settle: () => void };

/** What `present.drawn` was given, checked: or a refusal saying which bound it is past. */
export type DrawnAnswer = { ok: true; loadMs: number; blank: boolean; height: number; console: string[]; blocked: string[]; snapshot: Buffer; width: number } | { ok: false; reason: string; console: string[]; blocked: string[] };

const oneLine = (value: string) => value.replace(/[\u0000-\u001f\u007f]+/g, " ").trim();

function strings(value: unknown, field: string, most: number, longest: number): string[] {
	if (value === undefined) return [];
	if (!Array.isArray(value)) throw new Error(`${field} must be a list of text`);
	if (value.length > most) throw new Error(`${field} holds ${value.length} entries; the most is ${most}`);
	return value.map((one) => {
		if (typeof one !== "string") throw new Error(`${field} must be a list of text`);
		if (one.length > longest) throw new Error(`An entry of ${field} is ${one.length} characters; the most is ${longest}`);
		return oneLine(one);
	});
}

/** `present.drawn`'s parameters checked against the contract's bounds: the snapshot's bytes, the findings' count and length. */
export function checkDrawn(params: Record<string, unknown>): DrawnAnswer {
	if (typeof params.ok !== "boolean") throw new Error("ok must be true or false");
	const console = strings(params.console, "console", LIMITS.console, LIMITS.consoleLine);
	const blocked = strings(params.blocked, "blocked", LIMITS.blocked, LIMITS.blockedAddress);
	if (!params.ok) {
		const reason = typeof params.reason === "string" ? oneLine(params.reason) : "";
		if (reason === "" || reason.length > LIMITS.reason) throw new Error(`reason must say why the page could not be drawn, in ${LIMITS.reason} characters at most`);
		return { ok: false, reason, console, blocked };
	}
	const loadMs = params.loadMs;
	if (typeof loadMs !== "number" || !Number.isFinite(loadMs) || loadMs < 0 || loadMs > 3_600_000) throw new Error("loadMs must be the milliseconds the page took to load");
	if (typeof params.blank !== "boolean") throw new Error("blank must be true or false");
	const height = params.height;
	if (typeof height !== "number" || !Number.isSafeInteger(height) || height < 1 || height > 1_000_000) throw new Error("height must be the page's whole height, a whole number of CSS pixels");
	const snapshot = params.snapshot as { mimeType?: unknown; data?: unknown } | undefined;
	if (typeof snapshot !== "object" || snapshot === null || snapshot.mimeType !== "image/png" || typeof snapshot.data !== "string") throw new Error("snapshot must be { mimeType: \"image/png\", data }");
	if (snapshot.data.length > Math.ceil((LIMITS.picture * 4) / 3) + 4) throw new Error(`The snapshot is larger than ${megabytes(LIMITS.picture)}`);
	if (snapshot.data.length % 4 !== 0 || !/^[A-Za-z0-9+/]*={0,2}$/.test(snapshot.data)) throw new Error("The snapshot is not base64");
	const bytes = Buffer.from(snapshot.data, "base64");
	if (bytes.length === 0 || bytes.length > LIMITS.picture) throw new Error(`The snapshot is larger than ${megabytes(LIMITS.picture)}`);
	if (pictureType(bytes.subarray(0, 16))?.mimeType !== "image/png") throw new Error("The snapshot is not a PNG");
	const size = pictureSize(bytes, "image/png");
	if (size === undefined || size.width < 1 || size.height < 1 || size.width > LIMITS.side || size.height > LIMITS.side) throw new Error(`The snapshot's size cannot be read, or is over ${count(LIMITS.side)} pixels a side`);
	return { ok: true, loadMs, blank: params.blank, height, console, blocked, snapshot: bytes, width: DRAW_WIDTH };
}

// ---- The feature

export const presented: Feature = (host: Host, engine: Engine) => {
	const home = engine.home;
	/** Connections that registered to draw, oldest first: the newest draws. */
	const hosts: Client[] = [];
	/** Draws asked for and not yet answered, by request id. */
	const draws = new Map<string, Draw>();
	/** Pages whose snapshot is pending, by `pageKey`: asked of each app that registers. */
	const pendingPages = new Map<string, PageRef>();
	/** What each conversation's presentations were when last sent, by conversation and presentation, to send only what changed. */
	const sent = new Map<number, Map<string, string>>();
	let nextDraw = 1;

	const read = async (conversation: number): Promise<PresentedDocShape | undefined> =>
		(await engine.harness().snapshot(PresentedDoc, conversation as unknown as ConversationId, engine.context())) as PresentedDocShape | undefined;

	/** Note which pages of a conversation's record are still to be drawn. */
	const notePending = (conversation: number, doc: PresentedDocShape | undefined) => {
		for (const key of [...pendingPages.keys()]) if (key.startsWith(`${conversation}/`)) pendingPages.delete(key);
		for (const record of Object.values(doc?.items ?? {})) {
			for (const version of record.versions) {
				version.items.forEach((item, index) => {
					if (item.snapshot?.state === "pending") {
						const page = { conversation, presentation: record.id, version: version.version, item: index };
						pendingPages.set(pageKey(page), page);
					}
				});
			}
		}
	};

	/** `conversation.presented` for each record of `conversation` that changed, to the connections that have it open. */
	const announce = (conversation: number, doc: PresentedDocShape | undefined) => {
		const app = chatOf(conversation);
		// A chat's version that is not the one shown is not what its subscribers see.
		const shown = versions.chats[String(app)]?.current ?? app;
		const before = sent.get(conversation) ?? new Map<string, string>();
		const now = new Map<string, string>();
		const changed: PresentationRecord[] = [];
		for (const record of Object.values(doc?.items ?? {})) {
			const line = JSON.stringify(record);
			now.set(record.id, line);
			if (before.get(record.id) !== line) changed.push(record);
		}
		sent.set(conversation, now);
		if (changed.length === 0 || shown !== conversation) return;
		for (const client of clients) {
			if (!client.subscriptions.has(app)) continue;
			for (const record of changed) send(client, { event: "conversation.presented", id: app, record });
		}
	};

	/** The record changed in a commit: what is pending, and what the open conversations are sent, follow it. */
	const changedIn = async (conversation: number) => {
		const doc = await read(conversation);
		notePending(conversation, doc);
		announce(conversation, doc);
	};

	/** Write a snapshot where the agent can read it: `$PI2_SCRATCH/presented/p2-v3-B.png`. Answers its name for the agent, or nothing. */
	const scratchCopy = (conversation: number, page: PageRef, label: string, bytes: Buffer): string | undefined => {
		const scratch = conversationScratch(conversation);
		if (scratch === undefined) return undefined;
		const folder = join(scratch, "presented");
		const name = `${page.presentation}-v${page.version}-${/^[A-Za-z0-9_-]{1,12}$/.test(label) ? label : `item${page.item + 1}`}.png`;
		try {
			mkdirSync(folder, { recursive: true, mode: 0o700 });
			// The scratch folder is the agent's: a link it put there is never written through. A new file takes the name.
			const found = lstatSync(folder);
			if (found.isSymbolicLink() || !found.isDirectory()) return undefined;
			const partial = join(folder, `.${name}.${randomBytes(6).toString("hex")}`);
			writeFileSync(partial, bytes, { flag: "wx", mode: 0o600 });
			renameSync(partial, join(folder, name));
			return `$PI2_SCRATCH/presented/${name}`;
		} catch (error) {
			engine.log("present: could not write a snapshot to the scratch folder of conversation", conversation, error instanceof Error ? error.message : error);
			return undefined;
		}
	};

	/** Ask the app that registered last to draw `page`, unless that app was asked already. Undefined with no app. */
	const askToDraw = (page: PageRef): Draw | undefined => {
		const drawer = hosts.at(-1);
		if (drawer === undefined) return undefined;
		for (const draw of draws.values()) if (pageKey(draw.page) === pageKey(page) && draw.host === drawer) return draw;
		if (draws.size >= LIMITS.pendingDraws) draws.delete(draws.keys().next().value!);
		const requestId = `present-${nextDraw++}`;
		let settle!: () => void;
		const settled = new Promise<void>((resolve) => (settle = resolve));
		const draw: Draw = { page, host: drawer, settled, settle };
		draws.set(requestId, draw);
		send(drawer, { event: "present.draw", requestId, conversationId: chatOf(page.conversation), presentation: page.presentation, version: page.version, item: page.item, width: DRAW_WIDTH, height: DRAW_HEIGHT });
		return draw;
	};

	/** Store what the app found drawing `page`: the snapshot as a blob, the findings in the item. */
	const storeDrawn = async (page: PageRef, answer: DrawnAnswer) => {
		const folder = chatOf(page.conversation);
		const sha = answer.ok ? keep(home, folder, "blobs", answer.snapshot) : undefined;
		let label: string | undefined;
		await engine.harness().commit(async (tx) => {
			const doc = (await tx.doc(PresentedDoc, page.conversation as unknown as ConversationId)) as PresentedDocShape;
			const record = Object.hasOwn(doc.items, page.presentation) ? doc.items[page.presentation] : undefined;
			const item = record?.versions.find((one) => one.version === page.version)?.items[page.item];
			if (item === undefined || item.kind !== "page" || item.snapshot?.state !== "pending") return;
			label = item.label;
			if (answer.ok) {
				item.snapshot = { state: "drawn", sha256: sha! };
				item.width = answer.width;
				item.height = answer.height;
				item.drawn = { loadMs: Math.round(answer.loadMs), blank: answer.blank, console: answer.console, errors: errorsIn(answer.console), blocked: answer.blocked };
			} else {
				item.snapshot = { state: "failed", reason: answer.reason };
				item.drawn = { loadMs: 0, blank: false, console: answer.console, errors: errorsIn(answer.console), blocked: answer.blocked };
			}
		}, engine.context());
		if (answer.ok && label !== undefined) scratchCopy(page.conversation, page, label, answer.snapshot);
	};

	/** The question about a version ended: its answer in the record, in the commit `tx`. */
	const endIn = async (tx: Tx, conversation: number, presentation: string, version: number, end: PresentationEnd) => {
		const doc = (await tx.doc(PresentedDoc, conversation as unknown as ConversationId)) as PresentedDocShape;
		const record = Object.hasOwn(doc.items, presentation) ? doc.items[presentation] : undefined;
		const question = record?.versions.find((one) => one.version === version)?.question;
		if (question !== undefined && question !== null && question.answer === null) question.answer = end;
	};

	onPresentationEnded(async (tx, need, end) => {
		const ref = need.presentation!;
		await endIn(tx, need.conversationId, ref.presentation, ref.version, end);
	});

	/** The conversations whose files go: deleted, or a sub-chat of one deleted. Unknown ones are kept. */
	const sweep = () => {
		let names: string[];
		try {
			names = readdirSync(presentedRoot(home));
		} catch {
			return;
		}
		const conversations = engine.library().conversations;
		const deleted = (id: number) => conversations[String(id)]?.deleted === true;
		for (const name of names) {
			if (!/^\d+$/.test(name)) continue;
			const id = Number(name);
			const parent = conversations[name]?.parent;
			if (!deleted(id) && !(parent !== undefined && deleted(parent))) continue;
			try {
				rmSync(join(presentedRoot(home), name), { recursive: true, force: true });
				for (const key of [...pendingPages.keys()]) if (key.startsWith(`${id}/`)) pendingPages.delete(key);
				engine.log("present: removed the presented files of deleted conversation", id);
			} catch (error) {
				engine.log("present: could not remove the presented files of conversation", id, error instanceof Error ? error.message : error);
			}
		}
	};

	// ---- The tool

	const presentTool = defineTool({
		name: "present",
		description:
			"Show the person pictures or mockups in a card of their own in the conversation, large, with a label and a caption under each. They can open it in a window, full screen, and step between the items. " +
			"Use it whenever the person asks to see something, and for anything visual you made (a screenshot, a design, a mockup page), instead of naming its path. " +
			"Each item is a picture file (PNG, JPEG, GIF, WebP or SVG) or a page: an HTML file, shown with what lies in its folder and below, drawn with its scripts on and the network off, so put everything it needs in that folder and keep the folder to the mockup. " +
			"Give several items to offer variants side by side, labelled A, B, C or with short labels of your own, each with a caption saying how it differs. " +
			"With `question`, the card asks the person to pick, and the call waits for the answer; with `wait: false`, in a project, it returns at once and the answer comes to you later as a message. " +
			"To show a new version of something you presented before, pass its id as `update`: the person's window then shows the new version and keeps the older ones. " +
			"The files are copied as they are now; a later change to them is not shown until you present again. " +
			"The answer says what was shown: each item's size and, for a page, whether it loaded, its console errors, the addresses it tried to reach, and a picture of it as drawn that you can read or look at.",
		parameters: obj({
			title: str({ description: 'What is shown, in a few words, such as "Sign-in screen, three layouts"' }),
			items: arr(
				obj({
					path: str({ description: "A picture file or an HTML file, relative to the conversation's folder or absolute" }),
					label: opt(str({ description: 'A short label, 12 characters at most, such as "Compact"; A, B, C… in order when left out' })),
					caption: opt(str({ description: "A line or two shown under it: what this one is, or how it differs" })),
				}),
				{ description: "What to show, in this order: 1 to 6 items" },
			),
			question: opt(str({ description: 'A question for the person to answer by picking, such as "Which layout should I build?"' })),
			choices: opt(arr(str(), { description: 'With question: the answers offered as buttons, 2 to 6, 60 characters each; by default "Use A", "Use B"… one per item. The person can always answer in words instead' })),
			wait: opt(bool({ description: "With question, in a project: false returns at once, and the answer comes later as a message. Default true" })),
			update: opt(str({ description: 'The id of something presented before in this conversation, such as "p2", to show this as its new version' })),
		}),
		// Run again after a crash, it finds its own version by its call and copies nothing twice.
		replay: "safe",
		execute: async (args, api, context): Promise<ToolExecutionResult> => {
			const conversation = api.conversationId as unknown as number;
			const folder = chatOf(conversation);
			const project = inProject(conversation);
			const checked = checkGiven(args as Given, project !== undefined);
			if (typeof checked === "string") return refuse(checked);

			let found = await findCall(api, context);
			if (found === undefined) {
				const before = await read(conversation);
				if (checked.update !== null && (before === undefined || !Object.hasOwn(before.items, checked.update))) {
					return refuse(`This conversation has presented nothing as ${checked.update}. Leave update out to present it as something new.`);
				}
				let copied: Copied[];
				try {
					copied = await copyAll(api, context, checked);
				} catch (error) {
					if (error instanceof Refusal) return refuse(error.message);
					throw error;
				}
				found = await api.commit(async (tx) => {
					const doc = (await tx.doc(PresentedDoc, api.conversationId)) as PresentedDocShape;
					const earlier = callIn(doc, api.callId);
					if (earlier !== undefined) return earlier;
					const id = checked.update ?? `p${doc.next}`;
					if (checked.update === null) doc.next += 1;
					if (!Object.hasOwn(doc.items, id)) doc.items[id] = { id, versions: [] };
					// Read back from the document, so that what is changed below is the stored record, not the object put in it.
					const record = doc.items[id]!;
					const number = (record.versions.at(-1)?.version ?? 0) + 1;
					let question: PresentedQuestion | null = null;
					if (checked.question !== null) {
						let need = String(api.taskId);
						if (!checked.question.wait) {
							const put = await putNeed(tx, {
								kind: "decision",
								projectId: project!.id,
								conversationId: conversation,
								callId: api.callId,
								question: checked.question.text,
								choices: checked.question.choices,
								words: true,
								presentation: { conversationId: folder, presentation: id, version: number },
							});
							need = put.id;
						}
						question = { text: checked.question.text, choices: checked.question.choices, words: true, need, answer: null };
					}
					const version: PresentedVersion = {
						version: number,
						callId: api.callId,
						createdAt: Date.now(),
						title: checked.title,
						items: copied.map((one, index) => ({ ...one.item, label: checked.items[index]!.label, caption: checked.items[index]!.caption })),
						question,
						// Every version starts with the network off, whatever the person allowed an earlier one.
						network: { allowed: false, changes: [] },
					};
					record.versions.push(version);
					return { record: plain(record), version: plain(version) };
				}, context);
				// Pages are drawn by the app, all at once, for at most the wait; one not drawn by then is drawn later.
				const pages = found.version.items.flatMap((item, index) => (item.kind === "page" ? [{ conversation, presentation: found!.record.id, version: found!.version.version, item: index }] : []));
				const asked = pages.map(askToDraw).filter((draw): draw is Draw => draw !== undefined);
				if (asked.length > 0) {
					let timer: ReturnType<typeof setTimeout> | undefined;
					const timeout = new Promise<void>((resolve) => (timer = setTimeout(resolve, DRAW_WAIT_MS)));
					try {
						await awaitWithContext(Promise.race([Promise.all(asked.map((draw) => draw.settled)), timeout]), context);
					} finally {
						clearTimeout(timer);
					}
				}
			}

			// What was shown, from the record as it is now: the snapshots drawn since are in it.
			const now = callIn((await read(conversation)) ?? { next: 1, items: {} }, api.callId) ?? found;
			const snapshots = now.version.items.flatMap((item, index) => {
				if (item.kind !== "page" || item.snapshot?.state !== "drawn") return [];
				const page = { conversation, presentation: now.record.id, version: now.version.version, item: index };
				try {
					const written = scratchCopy(conversation, page, item.label, readKept(home, folder, "blobs", item.snapshot.sha256));
					return written === undefined ? [] : [written];
				} catch {
					return [];
				}
			});
			const said = answerFor(now.record, now.version, snapshots, hosts.length === 0);
			const details = { presentation: now.record.id, ...now.version };
			const question = now.version.question;
			if (question === null) return { output: text(said), details };
			const labels = now.version.items.map((item) => item.label);
			if (question.answer !== null) return { output: text(`${said}\n\n${answeredWith(question, question.answer, labels)}`), details };
			if (question.need.startsWith("n")) return { output: text(`${said}\n\nThe question is under Needs you; the answer comes to you as a message.`), details };

			// It waits: an Inbox item, sent under Needs you as a decision that blocks, until the person answers or writes.
			let end: PresentationEnd;
			try {
				const asked = await unlessMessaged(
					api,
					(waiting) =>
						host.inbox.ask(
							{
								id: question.need,
								kind: "question",
								conversationId: conversation,
								callId: api.callId,
								tool: "present",
								arguments: args,
								question: question.text,
								choices: question.choices,
								presentation: { conversationId: folder, presentation: now.record.id, version: now.version.version },
								createdAt: Date.now(),
							},
							api,
							waiting,
						),
					context,
				);
				if ("messaged" in asked) end = { ended: "messaged" };
				else {
					const given = JSON.parse(asked.value) as PresentedAnswer;
					end = "chose" in given ? { chose: given.chose } : { words: given.words };
				}
			} catch (error) {
				// Stopped: the record says so, in a commit of the engine's own, since this call's context is cancelled.
				await engine
					.harness()
					.commit((tx) => endIn(tx, conversation, now.record.id, now.version.version, { ended: "stopped" }), engine.context())
					.catch((failure) => engine.log("present: could not mark a question stopped:", failure instanceof Error ? failure.message : failure));
				throw error;
			}
			await api.commit((tx) => endIn(tx, conversation, now.record.id, now.version.version, end), context);
			return { output: text(`${said}\n\n${answeredWith(question, end, labels)}`), details: { ...details, question: { ...question, answer: end } } };
		},
	});

	/** The version this call made, if a run of it before a crash made one. */
	const callIn = (doc: PresentedDocShape, callId: string): { record: PresentationRecord; version: PresentedVersion } | undefined => {
		for (const record of Object.values(doc.items)) {
			const version = record.versions.find((one) => one.callId === callId);
			if (version !== undefined) return { record: plain(record), version: plain(version) };
		}
		return undefined;
	};
	const findCall = async (api: ToolExecutionApi, context: Context) => {
		const doc = (await api.snapshot(PresentedDoc, api.conversationId, context)) as PresentedDocShape | undefined;
		return doc === undefined ? undefined : callIn(doc, api.callId);
	};

	/** Every item read and checked, then kept: the call's and the conversation's limits before anything is written. */
	const copyAll = async (api: ToolExecutionApi, context: Context, checked: Checked): Promise<Copied[]> => {
		const conversation = api.conversationId as unknown as number;
		const folder = chatOf(conversation);
		const agent = (await api.snapshot(AgentDoc, api.conversationId, context)) as { cwd?: string | null } | undefined;
		const cwd = agent?.cwd ?? host.scratchFolder();
		const copied: Copied[] = [];
		let total = 0;
		for (const item of checked.items) {
			let path: string;
			try {
				path = resolveGiven(scratchPath(item.path, conversationScratch(conversation), cwd), cwd);
			} catch (error) {
				throw new Refusal(error instanceof Error ? error.message : String(error));
			}
			const one = copyItem(path, item.path);
			total += one.item.bytes;
			if (total > LIMITS.call) throw new Refusal(`These items come to more than ${megabytes(LIMITS.call)} in one call. Present fewer at a time, or smaller ones.`);
			copied.push(one);
		}
		// The conversation's own limit counts only files it does not keep already: a version that changes one picture adds one.
		const adding = new Map<string, number>();
		for (const one of copied) {
			for (const file of one.keep) {
				const sha = sha256(file.bytes);
				if (!kept(home, folder, file.part, sha)) adding.set(`${file.part}/${sha}`, file.bytes.length);
			}
		}
		const holds = folderBytes(home, folder);
		const more = [...adding.values()].reduce((sum, bytes) => sum + bytes, 0);
		if (holds + more > LIMITS.conversation) {
			throw new Refusal(`This conversation already holds ${sizeText(holds)} of presented files, and these would take it past ${megabytes(LIMITS.conversation)}. Present smaller files, or fewer, or in a new conversation.`);
		}
		for (const one of copied) for (const file of one.keep) keep(home, folder, file.part, file.bytes);
		return copied;
	};

	// ---- The requests

	const conversationOf = async (params: Record<string, unknown>) => {
		if (typeof params.id !== "number" || !Number.isSafeInteger(params.id)) throw new Error("id must be a conversation's number");
		const conv = await engine.conversation(params.id);
		const id = conv.id as unknown as number;
		return { id, folder: chatOf(id), doc: await read(id) };
	};
	const device = (connection: object | undefined) => (connection as Client | undefined)?.device !== undefined;
	/** A page item's manifest, for `presented.file` and `presented.page`: the Mac's alone, found only in that conversation's record. */
	const manifestOf = async (params: Record<string, unknown>, connection: object | undefined): Promise<{ folder: number; manifest: PageManifest }> => {
		if (device(connection)) throw new Error("A presented page's files are the Mac's.");
		const { folder, doc } = await conversationOf(params);
		const { item } = findItem(doc, params.presentation, params.version, params.item);
		if (item.kind !== "page") throw new Error("That item is a picture, not a page: ask for it with presented.picture.");
		const manifest = JSON.parse(readKept(home, folder, "pages", item.sha256).toString("utf8")) as PageManifest;
		if (typeof manifest !== "object" || manifest === null || typeof manifest.entry !== "string" || typeof manifest.files !== "object" || manifest.files === null || Array.isArray(manifest.files)) {
			throw new Error("The page's list of files cannot be read.");
		}
		return { folder, manifest };
	};

	return {
		tools: [presentTool],
		// It reads files as `read` does, so it is offered wherever tool access is not off; never in a chat (no `chatToolNames`).
		toolNames: (access) => (access === "none" ? [] : ["present"]),
		start: async () => {
			sweep();
			// The pages not drawn yet, asked of the next app that registers: the conversations that keep files.
			let names: string[] = [];
			try {
				names = readdirSync(presentedRoot(home)).filter((name) => /^\d+$/.test(name));
			} catch {}
			for (const name of names) {
				const id = Number(name);
				for (const conversation of [id, ...Object.keys(versions.chats[name]?.lines ?? {}).map(Number).filter((one) => one !== id)]) {
					try {
						const doc = await read(conversation);
						notePending(conversation, doc);
						sent.set(conversation, new Map(Object.values(doc?.items ?? {}).map((record) => [record.id, JSON.stringify(record)])));
					} catch (error) {
						engine.log("present: could not read the presentations of conversation", conversation, error instanceof Error ? error.message : error);
					}
				}
			}
			engine.harness().observeCommits({
				advance: ({ changes }) => {
					const touched = new Set<number>();
					for (const change of changes as CommitChange[]) {
						if (change.type !== "document" && change.type !== "document.copy") continue;
						const record = (change as { record: { kind: string; scope: { kind: string; conversationId?: unknown } } }).record;
						if (record.kind === "pi2.presented" && record.scope.kind === "conversation") touched.add(record.scope.conversationId as number);
					}
					for (const conversation of touched) void changedIn(conversation).catch((error) => engine.log("present: could not read the presentations again:", error instanceof Error ? error.message : error));
				},
				end: () => {},
			});
		},
		putAwayChanged: sweep,
		forked: async (source, fork) => {
			const from = join(presentedRoot(home), String(source));
			const to = join(presentedRoot(home), String(fork));
			if (!existsSync(from) || existsSync(to)) return;
			try {
				// A clone where the disk can: the fork's cards stand alone, and take no space until either changes.
				cpSync(from, to, { recursive: true, mode: constants.COPYFILE_FICLONE, errorOnExist: false, force: false, filter: (path) => !lstatSync(path).isSymbolicLink() });
				notePending(fork, await read(fork));
			} catch (error) {
				engine.log("present: could not copy the presented files of conversation", source, "to its fork", fork, error instanceof Error ? error.message : error);
			}
		},
		disconnected: (connection) => {
			const index = hosts.indexOf(connection as Client);
			if (index >= 0) hosts.splice(index, 1);
			for (const [id, draw] of draws) if (draw.host === connection) draws.delete(id);
		},
		handlers: {
			/** This connection draws pages; the latest to ask draws. Every page still pending is asked of it. */
			"present.register": async (_params, connection) => {
				const client = connection as Client;
				const index = hosts.indexOf(client);
				if (index >= 0) hosts.splice(index, 1);
				hosts.push(client);
				for (const page of pendingPages.values()) askToDraw(page);
				return {};
			},
			/** What the app found drawing a page the engine asked it to: taken from that connection only, once. */
			"present.drawn": async (params, connection) => {
				if (typeof params.requestId !== "string" || params.requestId.length > 64) throw new Error("requestId must be the id of the draw asked for");
				// A draw this engine asked for, of this connection: a request id is never taken from anyone else, nor twice.
				const draw = draws.get(params.requestId);
				if (draw === undefined || draw.host !== connection) return { answered: false };
				const answer = checkDrawn(params);
				draws.delete(params.requestId);
				// The same page asked of another app since: that draw is answered by this one.
				const same = [draw];
				for (const [id, other] of draws) {
					if (pageKey(other.page) !== pageKey(draw.page)) continue;
					draws.delete(id);
					same.push(other);
				}
				try {
					await storeDrawn(draw.page, answer);
				} finally {
					for (const one of same) one.settle();
				}
				return { answered: true };
			},
			/** `{ id }`: every presentation of the conversation, every version, for the window. */
			"presented.list": async (params, connection) => {
				if (device(connection)) throw new Error("Presenting's window is the Mac's.");
				const { doc } = await conversationOf(params);
				const items = Object.values(doc?.items ?? {}).sort((a, b) => Number(a.id.slice(1)) - Number(b.id.slice(1)));
				return { items };
			},
			/** `{ id, presentation, version, item }`: a picture, or a page's snapshot once drawn. */
			"presented.picture": async (params, connection) => {
				const { folder, doc } = await conversationOf(params);
				const { item } = findItem(doc, params.presentation, params.version, params.item);
				const served = servedPicture(item, device(connection));
				const bytes = readKept(home, folder, served.part, served.sha256);
				// What is sent is what its first bytes say: a raster picture is checked again as it was when kept.
				if (served.mimeType !== "image/svg+xml" && pictureType(bytes.subarray(0, 16))?.mimeType !== served.mimeType) throw new Error("The presented file is not the picture it was kept as.");
				return { mimeType: served.mimeType, data: bytes.toString("base64") };
			},
			/** `{ id, presentation, version, item, path }`: one file of a page, by its manifest's path exactly. */
			"presented.file": async (params, connection) => {
				const path = params.path;
				const { folder, manifest } = await manifestOf(params, connection);
				if (typeof path !== "string" || path.length === 0 || !pathFits(path)) throw new Error("path must be a file of the page, as its manifest names it");
				const file = Object.hasOwn(manifest.files, path) ? manifest.files[path] : undefined;
				if (file === undefined || typeof file.sha256 !== "string" || typeof file.type !== "string") throw new Error("The page has no such file.");
				return { mimeType: file.type, data: readKept(home, folder, "blobs", file.sha256).toString("base64") };
			},
			/**
			 * `{ id, presentation, version, item }`: a page's list of files, its manifest, for the page view before it asks
			 * `presented.file`: `{ entry, files: [{ path, bytes, type }] }`, by path. Read and refused as `presented.file` is.
			 */
			"presented.page": async (params, connection) => {
				const { manifest } = await manifestOf(params, connection);
				return pageListing(manifest);
			},
			/**
			 * `{ id, presentation, version, allow }`: the person's Allow network for that version's pages alone, written into
			 * the record with when, and said in the engine's log.
			 */
			"presented.network": async (params) => {
				if (typeof params.allow !== "boolean") throw new Error("allow must be true or false");
				const allow = params.allow;
				const { id, doc } = await conversationOf(params);
				const { record, version } = findItem(doc, params.presentation, params.version, 0);
				await engine.harness().commit(async (tx) => {
					const stored = (await tx.doc(PresentedDoc, id as unknown as ConversationId)) as PresentedDocShape;
					const found = Object.hasOwn(stored.items, record.id) ? stored.items[record.id]?.versions.find((one) => one.version === version.version) : undefined;
					if (found === undefined) return;
					found.network.allowed = allow;
					found.network.changes.push({ allow, at: Date.now() });
					if (found.network.changes.length > LIMITS.networkChanges) found.network.changes.splice(0, found.network.changes.length - LIMITS.networkChanges);
				}, engine.context());
				engine.log(`present: the network was turned ${allow ? "on" : "off"} for ${record.id} version ${version.version} of conversation ${id}`);
				return {};
			},
		},
	};
};
