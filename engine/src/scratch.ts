// A scratch folder for each conversation (issue #180): somewhere to keep temporary files between commands, outside the
// conversation's folder, which may be a project's.
//
// Each conversation's is `/tmp/pi2-<uid>/scratch-<hash>/<conversation>`, where the hash is the first 8 hex digits of the
// SHA-256 of the data folder's path (resolved, in Unicode NFC, as socket.ts hashes it), so that copies of pi² on other
// data folders (a development build, a test's engine) never share one. A sub-chat is a conversation of its own and has
// its own. Why there:
//
// - Short and without spaces. The data folder is in "Application Support", and a command that puts a socket in a
//   temporary folder (the engine's own tests do) has 103 bytes for its whole path. This one is about 32.
// - Private. `/tmp/pi2-<uid>` is the folder socket.ts already keeps its short links in, made with mode 0700 and checked
//   to be a folder this user owns that nobody else can open, as it is here, so no other user's process can plant files
//   in it or point it somewhere else. `/tmp` itself cannot be used as it is: anyone may make a name there first.
// - Not in backups: Time Machine leaves out `/private/tmp`, and pi²'s own backup copies only the data folder.
// - Cleared by macOS too: it removes files in `/tmp` that nobody has used for three days, so what an archived or
//   forgotten conversation leaves does not stay for long. A folder macOS took away is made again when next needed.
//
// The folder is made when first needed, before a command of the conversation starts, and every command, background
// command and set-up command gets its path in PI2_SCRATCH. It is removed when its conversation is deleted, or the
// conversation it is a sub-chat of. An archived conversation keeps it: it can be restored and continued where it
// stopped, and macOS clears an unused one in a few days anyway. As the kept outputs of output.ts are, the folders are
// looked at as the engine starts, whenever conversations are archived or deleted, and once a day.

import { section } from "@earendil-works/pi-durable";
import { createHash } from "node:crypto";
import { lstatSync, mkdirSync, readdirSync, rmSync } from "node:fs";
import { join, resolve } from "node:path";
import type { Engine, Feature } from "./features.ts";
import type { Meta } from "./state.ts";

/** The variable that names a conversation's scratch folder in its commands' environment. */
export const SCRATCH_VARIABLE = "PI2_SCRATCH";

const uid = () => process.getuid?.() ?? 0;

/** The folder this user's short paths live in: socket.ts's links and the scratch folders. */
export const privateRoot = (): string => `/tmp/pi2-${uid()}`;

/** The folder the scratch folders of the engine on data folder `home` are in. */
export function scratchRoot(home: string, root = privateRoot()): string {
	const folder = resolve(home).normalize("NFC");
	return join(root, `scratch-${createHash("sha256").update(folder).digest("hex").slice(0, 8)}`);
}

/** The scratch folder of conversation `id` of the engine on `home`, whether it has been made or not. */
export const scratchFolder = (home: string, id: number, root?: string): string => join(scratchRoot(home, root), String(id));

/** Make conversation `id`'s scratch folder if it is not there, and give its path. Throws if it cannot be made safely. */
export function makeScratch(home: string, id: number, root = privateRoot()): string {
	mkdirSync(root, { recursive: true, mode: 0o700 });
	const own = lstatSync(root);
	// Another user may have made it first, as anyone can make a name in /tmp: then nothing is put in it.
	if (!own.isDirectory() || own.uid !== uid() || (own.mode & 0o077) !== 0) throw new Error(`${root} must be a folder of this user's that nobody else can open.`);
	const folder = scratchFolder(home, id, root);
	mkdirSync(folder, { recursive: true, mode: 0o700 });
	return folder;
}

/** Why a conversation's scratch folder is no longer wanted: it, or the conversation it is a sub-chat of, is deleted or unknown. */
export function scratchGone(conversations: Record<string, Meta>, id: number): boolean {
	const gone = (key: number) => {
		const meta = conversations[String(key)];
		return meta === undefined || meta.deleted === true;
	};
	const parent = conversations[String(id)]?.parent;
	return gone(id) || (parent !== undefined && gone(parent));
}

/** Remove the scratch folders under `folder` whose conversations `gone` says are gone. Only folders named by a number are touched. */
export function sweepScratch(folder: string, gone: (id: number) => boolean): void {
	let names: string[];
	try {
		names = readdirSync(folder);
	} catch {
		return;
	}
	for (const name of names) if (/^\d+$/.test(name) && gone(Number(name))) rmSync(join(folder, name), { recursive: true, force: true });
}

let running: Engine | undefined;

/**
 * What a command of conversation `id` adds to its environment: PI2_SCRATCH, its scratch folder, made if need be.
 * Nothing when it cannot be made (the engine's log says why), and nothing outside a running engine.
 */
export function scratchVariable(id: number): Record<string, string> {
	if (running === undefined) return {};
	try {
		return { [SCRATCH_VARIABLE]: makeScratch(running.home, id) };
	} catch (error) {
		running.log(`scratch folder for conversation ${id} could not be made:`, error instanceof Error ? error.message : error);
		return {};
	}
}

/** The line of the system prompt that names the folder. */
export const describeScratch = (folder: string): string =>
	`Your scratch folder is ${folder}, also in ${SCRATCH_VARIABLE} for every command: keep temporary files there rather than in /tmp or the working folder. It is this conversation's alone, kept between commands, and removed when the conversation is deleted.`;

export const scratch: Feature = (_host, engine: Engine | undefined) => {
	// Without an engine (a test of what the tools say), there is no folder to name.
	if (engine === undefined) return {};
	running = engine;
	const sweep = () => {
		try {
			const conversations = engine.library().conversations;
			sweepScratch(scratchRoot(engine.home), (id) => scratchGone(conversations, id));
		} catch (error) {
			engine.log("scratch folders could not be tidied:", error instanceof Error ? error.message : error);
		}
	};
	let daily: NodeJS.Timeout | undefined;
	return {
		// Present whenever commands can be run, so it does not come and go during a conversation (#186).
		sections: [section("scratch", (input) => (input.agent.tools.some((tool) => tool.name === "bash") ? describeScratch(scratchFolder(engine.home, input.conversationId as unknown as number)) : undefined))],
		start: async () => {
			sweep();
			daily = setInterval(sweep, 86_400_000);
			daily.unref();
		},
		putAwayChanged: sweep,
		stopping: async () => clearInterval(daily),
	};
};
