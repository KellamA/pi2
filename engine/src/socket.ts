// Where the engine's socket is reached.
//
// The socket is `engine.sock` in the data folder. macOS limits a Unix socket's path to 103 bytes, so for a data folder
// with a long path (only possible with PI2_HOME) the socket is reached through a short link to the folder instead:
// `/tmp/pi2-<uid>/<first 16 hex digits of the SHA-256 of the folder's path>`, the path resolved and in Unicode NFC.
// The socket file itself stays in the data folder. The app works out the same path in EngineSocket.swift; keep the
// two in step.

import { createHash } from "node:crypto";
import { lstatSync, mkdirSync, readlinkSync, rmSync, symlinkSync } from "node:fs";
import { join, resolve } from "node:path";

/** The longest socket path macOS accepts: `sun_path` holds 104 bytes, including the closing zero. */
export const MAX_SOCKET_PATH = 103;

/** The path to connect to or listen on for the engine whose data folder is `home`. Makes the short link if needed. */
export function socketPathFor(home: string, linkRoot = `/tmp/pi2-${process.getuid?.() ?? 0}`): string {
	// Composed (NFC), as the app has it: it hashes the exact bytes, and the app's URLs give decomposed accents.
	const folder = resolve(home).normalize("NFC");
	const direct = join(folder, "engine.sock");
	if (Buffer.byteLength(direct) <= MAX_SOCKET_PATH) return direct;
	const link = join(linkRoot, createHash("sha256").update(folder).digest("hex").slice(0, 16));
	const short = join(link, "engine.sock");
	if (Buffer.byteLength(short) > MAX_SOCKET_PATH) throw new Error(`The socket path is too long, even through ${link}.`);
	// The links live in a folder only this user can write to, so nobody else can point one at their own engine.
	mkdirSync(linkRoot, { recursive: true, mode: 0o700 });
	const root = lstatSync(linkRoot);
	if (!root.isDirectory() || root.uid !== process.getuid?.() || (root.mode & 0o077) !== 0) {
		throw new Error(`${linkRoot} must be a folder of this user's that nobody else can open.`);
	}
	if (linkTarget(link) !== folder) {
		// The app and the engine may both make it at once; whichever is second finds the right link already there.
		rmSync(link, { force: true });
		try {
			symlinkSync(folder, link);
		} catch (error) {
			if ((error as NodeJS.ErrnoException).code !== "EEXIST" || linkTarget(link) !== folder) throw error;
		}
	}
	return short;
}

function linkTarget(link: string): string | null {
	try {
		return readlinkSync(link);
	} catch {
		return null;
	}
}
