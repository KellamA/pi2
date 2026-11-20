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
//
// The file tools know the folder by name too (#564): a path that begins with $PI2_SCRATCH is read as this
// conversation's scratch folder, and a path that begins with any other $NAME is refused rather than half-understood -
// a shell variable that is not set would otherwise make a file or folder called `$HOME` by accident. `scratchPath`
// below is the one that decides, and every built-in tool that takes a path asks it: `read`, `write` and `edit` through
// the wraps `scratchPaths` gives, which this feature puts on by tool name, and `list_files`, `find_files` and
// `search_files` through `locate` in look.ts, which gains the scratch folder as the one other folder they may look in.

import { AgentDoc, section, type ToolExecutionApi, type ToolRegistration, type Wrap } from "@earendil-works/pi-durable";
import { createHash } from "node:crypto";
import { existsSync, lstatSync, mkdirSync, readdirSync, rmSync } from "node:fs";
import { join, resolve } from "node:path";
import type { Context } from "@earendil-works/chord/context";
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
 * The conversation's scratch folder, made if need be: what `$PI2_SCRATCH` in a path stands for, as PI2_SCRATCH in its
 * commands' environment does. Nothing when there is no running engine or the folder cannot be made (its log says why).
 */
export function conversationScratch(id: unknown): string | undefined {
	if (running === undefined) return undefined;
	try {
		return makeScratch(running.home, Number(id));
	} catch (error) {
		running.log(`scratch folder for conversation ${String(id)} could not be made:`, error instanceof Error ? error.message : error);
		return undefined;
	}
}

/**
 * What a command of conversation `id` adds to its environment: PI2_SCRATCH, its scratch folder, made if need be.
 * Nothing when it cannot be made (the engine's log says why), and nothing outside a running engine.
 */
export function scratchVariable(id: number): Record<string, string> {
	const folder = conversationScratch(id);
	return folder === undefined ? {} : { [SCRATCH_VARIABLE]: folder };
}

/** What a file tool answers for a path that begins with a variable it will not expand (#564). */
export const NO_VARIABLE_PATH = "The file tools do not expand variables: write the full path. Only $PI2_SCRATCH may begin a path.";

/** What it answers when there is no scratch folder to put in `$PI2_SCRATCH`'s place, rather than a guess. */
export const NO_SCRATCH_FOLDER = "$PI2_SCRATCH cannot begin a path in a conversation with no scratch folder: write the full path.";

/** A path that begins with `$NAME` or `${NAME}`, on its own or before a `/`. */
const A_VARIABLE_AT_THE_START = /^\$(?:\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))(?=\/|$)/;

/**
 * The path a file tool uses for the one the agent wrote (#564). `$PI2_SCRATCH` or `${PI2_SCRATCH}`, alone or beginning
 * the path, stands for `scratch`, the conversation's scratch folder; every other path comes back as written. A path
 * that begins with another `$NAME` is refused, because the shell's rules for one would make a file or folder called
 * `$HOME` (`$HOME` not set) or a folder the agent did not mean (set), and neither is what it was reaching for. The one
 * exception is where the agent can only have meant what it wrote: `folder`, the folder a path with no `/` at its start
 * is relative to, really holds something of exactly that name. `scratch` is undefined for a conversation whose scratch
 * folder there is none of, and that is refused too.
 */
export function scratchPath(path: string, scratch: string | undefined, folder: string): string {
	const written = A_VARIABLE_AT_THE_START.exec(path);
	if (written === null) return path;
	const name = written[1] ?? written[2]!;
	const below = path.slice(written[0].length).replace(/^\/+/, "");
	if (name !== SCRATCH_VARIABLE) {
		if (existsSync(join(folder, written[0]))) return path;
		throw new Error(NO_VARIABLE_PATH);
	}
	if (scratch === undefined) throw new Error(NO_SCRATCH_FOLDER);
	return below === "" ? scratch : join(scratch, below);
}

/** Does any path this call gives begin with a `$`, so that the folders a path is relative to matter at all? */
function asksAboutAVariable(args: unknown): boolean {
	if (args === null || typeof args !== "object" || Array.isArray(args)) return false;
	const given = args as { path?: unknown; files?: unknown };
	const aVariable = (path: unknown) => typeof path === "string" && path.startsWith("$");
	return aVariable(given.path) || (Array.isArray(given.files) && given.files.some((entry) => aVariable((entry as { path?: unknown })?.path)));
}

/**
 * The call's arguments, with each path they give read as `scratchPath` reads it. Every file tool names its path `path`, and
 * `read` takes several in `files`, each with its own `path`; anything else in the arguments is left as it was. A path that
 * asks for the scratch folder needs the folder made, which the wrap asks `scratchOf` for just before, so a `write` of
 * `$PI2_SCRATCH/x` need not be preceded by a `mkdir`. A call with no path beginning with `$` is sent to the tool as it
 * came and never asks, so a plain relative path does not make a scratch folder in a conversation that has none.
 */
export function expandPaths(args: unknown, scratch: string | undefined, folder: string): unknown {
	if (args === null || typeof args !== "object" || Array.isArray(args)) return args;
	const given = args as Record<string, unknown> & { files?: unknown };
	const read = (path: unknown) => (typeof path === "string" ? scratchPath(path, scratch, folder) : path);
	const files = Array.isArray(given.files)
		? given.files.map((entry) => (entry === null || typeof entry !== "object" || Array.isArray(entry) ? entry : { ...entry, path: read((entry as { path?: unknown }).path) }))
		: undefined;
	return {
		...given,
		...(typeof given.path === "string" ? { path: read(given.path) } : {}),
		...(files === undefined ? {} : { files }),
	};
}

/**
 * The wraps that read `$PI2_SCRATCH` in a path, one for each of the `names` file tools. Wrapping by name, as order.ts
 * does, so a wrap already put on the tool is kept and this adds to it. The paths are read before the tool runs, so what
 * the tool answers names the real file; `scratchOf` gives the conversation's scratch folder (made if need be) and
 * `fallback` the folder a path with no `/` at its start is relative to, which is what a `$NAME` is looked for in. Nothing
 * else about a call changes. A path that begins with another variable is refused before the file is touched, so no
 * folder of a variable's name is ever made.
 */
export const scratchPaths = (
	where: { scratchOf: (conversationId: unknown) => string | undefined; fallback: () => string },
	names: readonly string[],
): Extract<Wrap<ToolRegistration>, { tool: string }>[] =>
	names.map((name) => ({
		tool: name,
		wrap: (tool: ToolRegistration) => ({
			...tool,
			execute: async (given: unknown, api: ToolExecutionApi, context: Context) => {
				// A path that begins with no `$` is the tool's own business, and needs no look at the conversation's state.
				if (!asksAboutAVariable(given)) return await tool.execute(given as never, api as never, context);
				const doc = (await api.snapshot(AgentDoc, api.conversationId, context)) as { cwd?: string | null } | undefined;
				let askedFor: unknown;
				try {
					askedFor = expandPaths(given, where.scratchOf(api.conversationId), doc?.cwd ?? where.fallback());
				} catch (error) {
					// A path the tools will not take is an answer of its own, not a fault in the call: it fails with one
					// line saying what to write, and the tool is never reached, so nothing of that name is made.
					return { output: [{ type: "text" as const, text: error instanceof Error ? error.message : String(error) }], isError: true };
				}
				return await tool.execute(askedFor as never, api as never, context);
			},
		}),
	}));

/** The line of the system prompt that names the folder. */
export const describeScratch = (folder: string): string =>
	`Your scratch folder is ${folder}, also in ${SCRATCH_VARIABLE} for every command: keep temporary files there rather than in /tmp or the working folder. A path you give a file tool may begin with $${SCRATCH_VARIABLE}, which stands for this folder, and the tool answers with the real path. It is this conversation's alone, kept between commands, and removed when the conversation is deleted.`;

export const scratch: Feature = (host, engine: Engine | undefined) => {
	// Without an engine (a test of what the tools say), there is no folder to name.
	if (engine === undefined) return {};
	running = engine;
	// Wrapping by name: `reads` made `read` into what it is today, and `order` wraps these same tools again later (features.ts).
	const wraps = scratchPaths({ scratchOf: conversationScratch, fallback: () => host.scratchFolder() }, ["read", "write", "edit"]);
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
		wraps,
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
