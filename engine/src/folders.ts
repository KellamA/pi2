// What a paired phone may see of the Mac's disk (docs/iphone.md 4.2 and 5.7, #698): the folders the Mac offers for a
// new project (`projects.folders`), and one text file a conversation links to (`files.preview`). A phone cannot browse
// the Mac's disk, and nothing here lets it: it is offered only folders the person already used with pi², and shown only
// a file an agent's answer pointed to, under that conversation's own folder. Both are open to the app too, and answer
// it the same.
//
// The folders offered (`offeredFolders`), at most MAX_FOLDERS, each by its real path (links followed), once:
// - the folder of every project not deleted, archived ones included, marked with the project's name (`project`), since
//   a folder has one project at most and `projects.create` refuses a second;
// - the folder of every agent not removed (templates and projects' agents), as the person set it;
// - the folder of each of the RECENT_CONVERSATIONS newest conversations the person started (not a sub-chat, not a
//   chat, not deleted), as it works now: set when it was made, or changed in its settings.
// A deleted project lends none of these, through itself, its agents or its conversations. Never a folder's contents,
// never a parent of one, never a folder that is not there now, never the data folder or anything in it (pi²'s own
// worktrees among them) or the scratch folders, nor a folder that holds either (the home folder, `~/Library`, `/`),
// and never one whose path holds something shaped like a key, which the masks of 5.7 would change (the phone could not
// send it back). Folders no project has come first, the one used last first; then those of projects, the same way.
// Every string of the answer is masked again on its way to a phone (remote.ts, `forDevice`), as everything sent to one
// is. Each offering is also told to answers.ts (`offerFolders`), whose device row for `projects.create` takes a folder
// from a phone only by the exact text of one offered (4.2): the decision is the device lists', and `offeredFolder`
// below checks it again, against what is offered at that moment, before the project is made.
//
// `files.preview` takes a file only when all of these hold, and says which did not: the conversation has a folder; one
// of its agent's answers links to the file (a Markdown link or picture, or a `file:` address in angle brackets, outside
// code, as the conversation's page draws a file link: markdown.js, `fileTarget`); by its text, and then once links are
// followed, the file is under the folder; it is not inside a `.git`, nor in pi²'s data folder or a scratch folder (but
// the worktree pi² made for this very conversation, or for the one a sub-chat works for, is its folder: not any other
// in the data folder, #902); it is a regular file; git does not ignore it, and, in a folder that is no git repository,
// no name on its path begins with a dot (`.env`, `.ssh/…`), the conversation's folder's own path included (a
// conversation working in `~/.ssh` is shown none of it, #902); it has no other name (a hard link could make a file
// from anywhere on the volume look as if it were in the folder); it is at
// most 256 KB; and it is UTF-8 text with no NUL. No refusal's words hold a path. The check and the read are of the same file: it is opened with no link followed anywhere
// on its path (O_NOFOLLOW_ANY on macOS; on Linux the opened descriptor's own path is read back), without waiting on a
// pipe, and the opened file must be the one checked (device and inode), so a file swapped for a link, or for another
// file, between the check and the read is refused.
//
// Bounds on the work a phone, or anything on the socket, can ask for again and again (#902). What either reads is kept
// a while, and never shown again once the rules would refuse it now (`keepFolders`, for the engine itself):
// - Each conversation's folder, read from its AgentDoc once and then kept up to date from the documents' commits: a
//   commit that changes the AgentDoc gives the new one, a retirement or a copy forgets it, and a read a commit
//   overtook is not kept.
// - The last answer of `projects.folders`, for OFFERED_MS, while what it was made of is the same: the folders used
//   (projects', agents' and the recent conversations', each with when) and the projects' names and repositories, all
//   in memory. A project deleted or renamed, an agent removed, a conversation deleted, moved or used, and the key
//   differs. Before it is given again, each folder used that it offers is checked to have the real path it had, and
//   each folder it offers to be a folder still (a system call each): one gone, moved behind a link, or a link pointed
//   elsewhere makes it read everything again. What can be stale is only a repository's name read from `.git/config`,
//   for OFFERED_MS.
// - The files each conversation links to, by its folder and its newest entry: entries never change once committed, so
//   while the newest is the same, so is what the transcript links to. A new entry, or another folder, reads the
//   transcript again. Only which files are linked is kept: every other check (git's ignore rules among them) runs at
//   each request, so a file that became ignored, or moved out, is refused at once.
// And a device may ask for at most PREVIEWS_PER_MINUTE files a minute: each runs git, and each is logged.

import { constants, lstatSync, readFileSync, readlinkSync, realpathSync, statSync } from "node:fs";
import { open } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, dirname } from "node:path";
import { AgentDoc, type ConversationId } from "@earendil-works/pi-durable";
import type { Client } from "./clients.ts";
import { commandEnvironment } from "./environment.ts";
import type { Engine, Feature } from "./features.ts";
import { offerFolders } from "./answers.ts";
import { maskKeys } from "./devices.ts";
import { parseRemote } from "./github.ts";
import { runOffThread } from "./offthread.ts";
import { allProjects, wireOfferedFolder } from "./projects.ts";
import { scratchRoot } from "./scratch.ts";
import { toItem } from "./transcript.ts";
import { allWorktrees } from "./worktrees.ts";

/** The most folders offered at once. */
export const MAX_FOLDERS = 50;
/** How many of the newest conversations the person started lend their folders. */
export const RECENT_CONVERSATIONS = 200;
/** The largest file shown on a phone, in bytes (5.7). */
export const MAX_PREVIEW = 256 * 1024;
/** How long an answer of `projects.folders` is given again while nothing it was made of changed (#902). */
export const OFFERED_MS = 5_000;
/** How many conversations' linked files are kept (#902). */
export const LINKED_KEPT = 32;
/** How many files a device may be shown in a minute (#902): a person tapping links, never a script reading a folder. */
export const PREVIEWS_PER_MINUTE = 30;

// What a phone is told, and why.
export const NOT_OFFERED = "That folder is not one your Mac offers for a new project. Choose one it offers, or make the project on the Mac.";
export const NO_FOLDER = "This conversation has no folder, so none of its files is shown on the phone.";
export const NOT_A_PATH = "That is not the path of a file on the Mac.";
export const NOT_LINKED = "The conversation does not link to that file. Only a file its agent's answers link to is shown on the phone.";
export const FOLDER_GONE = "The conversation's folder is not on the Mac any more.";
export const MISSING = "There is no file there. It may have been moved or deleted.";
export const OUTSIDE = "That file is outside the conversation's folder once its links are followed, so it is not shown on the phone.";
export const IN_GIT = "That file is inside git's own folder (.git), which is not shown on the phone.";
export const NOT_A_FILE = "That is not a file pi² shows: a folder, a link, a pipe or a device is not shown on the phone.";
export const IN_PI2 = "That file is in pi²'s own data or a scratch folder, which is not shown on the phone.";
export const DOT_OUTSIDE_GIT =
	"That file, or a folder it is in, has a name that begins with a dot, as secrets' often do (.env, .ssh), and its folder is no git repository, so it is not shown on the phone.";
export const HARD_LINK = "That file has another name on the Mac (a hard link), so pi² cannot tell it lies only in the conversation's folder. It is not shown on the phone.";
export const IGNORED = "git ignores that file, so it is not shown on the phone: an ignored file often holds secrets, as an .env file does.";
export const GIT_UNKNOWN = "pi² could not tell whether git ignores that file, so it is not shown on the phone.";
export const NOT_TEXT = "That file is not text: only UTF-8 text is shown on the phone.";
export const CHANGED = "That file changed while pi² read it. Try again.";
export const TOO_MANY_PREVIEWS = `This phone asked for more than ${PREVIEWS_PER_MINUTE} files in a minute. Wait a minute, then try again.`;
export const tooLarge = (size: number) => `That file is too large to show on the phone: ${Math.ceil(size / 1024)} KB, of at most ${MAX_PREVIEW / 1024} KB.`;

export type OfferedFolder = { path: string; name: string; where?: string; project?: string; repository?: string };

/** macOS's open(2) flag that refuses a symbolic link anywhere on the path, not only at its end (sys/fcntl.h). */
const O_NOFOLLOW_ANY = 0x20000000;

let wired: Engine | undefined;

/** What is kept for one engine between requests (#902; see the top of this file). */
type Kept = {
	now: () => number;
	/** Each conversation's folder by its AgentDoc (null for none), kept up to date from the documents' commits. */
	cwds: Map<number, string | null>;
	/** The reads of a conversation's AgentDoc under way: a commit to it marks them overtaken, and they are not kept. */
	reading: Map<number, Set<{ overtaken: boolean }>>;
	/** The last answer, what it was made of, and the folders used that it offers, each by the real path it had then. */
	offered?: { key: string; at: number; folders: OfferedFolder[]; sources: [string, string][] };
	/** By conversation, the files its transcript links to, as of its newest entry, read with its folder then. */
	linked: Map<number, { folder: string; newest: unknown; paths: Set<string> }>;
};
const kept = new WeakMap<Engine, Kept>();
const AGENT_DOC = AgentDoc.definition.kind;

/** A conversation's folder as its AgentDoc gives it: null for none. */
const cwdIn = (doc: unknown): string | null => {
	const cwd = (doc as { cwd?: unknown } | undefined)?.cwd;
	return typeof cwd === "string" ? cwd : null;
};

/**
 * Keep what `projects.folders` and `files.preview` read for `engine`, from now until its documents' session ends (see
 * the top of this file). The feature calls it as the engine starts; a test, with a stand-in engine and clock.
 */
export function keepFolders(engine: Engine, now: () => number = Date.now): void {
	if (kept.has(engine)) return;
	const state: Kept = { now, cwds: new Map(), reading: new Map(), linked: new Map() };
	kept.set(engine, state);
	engine.harness().observeCommits({
		advance: ({ changes }) => {
			for (const change of changes) {
				if ((change.type !== "document" && change.type !== "document.copy") || change.record.kind !== AGENT_DOC || change.conversationId === undefined) continue;
				const id = Number(change.conversationId);
				for (const read of state.reading.get(id) ?? []) read.overtaken = true;
				// The value is the whole document as committed; a copy carries none, and is read again when asked for.
				if (change.type === "document" && change.kind === "change" && state.cwds.has(id)) state.cwds.set(id, cwdIn(change.value));
				else state.cwds.delete(id);
			}
		},
		// Nothing more is seen of the documents, so nothing kept could be trusted.
		end: () => void kept.delete(engine),
	});
}

/** Conversation `id`'s folder: kept, or read from its AgentDoc and kept unless a commit overtook the read. */
async function folderOf(engine: Engine, id: number, keeping: Kept | undefined): Promise<string | null | undefined> {
	if (keeping?.cwds.has(id)) return keeping.cwds.get(id);
	const read = { overtaken: false };
	const reads = keeping?.reading.get(id) ?? new Set();
	reads.add(read);
	keeping?.reading.set(id, reads);
	try {
		const cwd = cwdIn(await engine.harness().snapshot(AgentDoc, id as unknown as ConversationId, engine.context()));
		if (keeping !== undefined && !read.overtaken) keeping.cwds.set(id, cwd);
		return cwd;
	} catch {
		// A conversation that cannot be read lends no folder.
		return undefined;
	} finally {
		reads.delete(read);
		if (reads.size === 0) keeping?.reading.delete(id);
	}
}

/**
 * Whether what an answer offered is still as it was: each folder used that it offers has the real path it had then (a
 * folder moved behind a link, or a link pointed elsewhere, has not), and each folder it offers is still a folder.
 */
function stillThere(last: NonNullable<Kept["offered"]>): boolean {
	try {
		return last.sources.every(([path, found]) => real(path) === found) && last.folders.every((folder) => statSync(folder.path).isDirectory());
	} catch {
		return false;
	}
}

const real = (path: string): string | null => {
	try {
		return realpathSync.native(path);
	} catch {
		return null;
	}
};
const within = (path: string, folder: string) => path === folder || path.startsWith(folder.endsWith("/") ? folder : `${folder}/`);

/** A path with the home folder written `~`, as the person knows it. */
function shown(path: string, home = homedir()): string {
	if (home.length <= 1) return path;
	if (path === home) return "~";
	return path.startsWith(`${home}/`) ? `~${path.slice(home.length)}` : path;
}

/** `owner/name` of the GitHub repository a folder is a checkout of, from its own `.git/config`; undefined otherwise. */
function repositoryOf(folder: string): string | undefined {
	try {
		const config = `${folder}/.git/config`;
		const info = lstatSync(config);
		if (!info.isFile() || info.size > 64 * 1024) return undefined;
		let origin = false;
		for (const line of readFileSync(config, "utf8").split("\n")) {
			const section = /^\s*\[([^\]]*)\]/.exec(line);
			if (section !== null) origin = /^remote\s+"origin"$/.test(section[1]!.trim());
			const url = origin ? /^\s*url\s*=\s*(.+?)\s*$/.exec(line) : null;
			if (url !== null) {
				const found = parseRemote(url[1]!);
				return found === undefined ? undefined : `${found.owner}/${found.name}`;
			}
		}
	} catch {
		// No repository, or one this cannot read: it is offered without.
	}
	return undefined;
}

/** The folders the Mac offers a phone for a new project now, in the order to show them (see the top of this file). */
export async function offeredFolders(engine: Engine | undefined = wired): Promise<OfferedFolder[]> {
	if (engine === undefined) return [];
	const used = new Map<string, number>();
	const use = (path: string | null | undefined, at: number) => {
		if (typeof path !== "string" || !path.startsWith("/")) return;
		used.set(path, Math.max(used.get(path) ?? 0, at));
	};
	const all = Object.values(allProjects());
	const deleted = new Set(all.filter((project) => project.deletedAt !== undefined).map((project) => project.id));
	const projects = all.filter((project) => project.deletedAt === undefined);
	for (const project of projects) use(project.folder, project.updatedAt);
	for (const agent of Object.values(engine.agents())) {
		if (agent.removedAt === undefined && !(agent.projectId !== undefined && deleted.has(agent.projectId))) use(agent.cwd, agent.updatedAt ?? agent.createdAt);
	}
	const started = Object.entries(engine.library().conversations)
		.filter(([, meta]) => meta.deleted !== true && meta.parent === undefined && meta.chat !== true && !(meta.projectId !== undefined && deleted.has(meta.projectId)))
		.sort(([, a], [, b]) => b.updatedAt - a.updatedAt)
		.slice(0, RECENT_CONVERSATIONS);
	const keeping = kept.get(engine);
	for (const [id, meta] of started) use(await folderOf(engine, Number(id), keeping), meta.updatedAt);
	// Folders of conversations no longer among the newest are forgotten now and then: read again should they come back.
	if (keeping !== undefined && keeping.cwds.size > 2 * RECENT_CONVERSATIONS) {
		const recent = new Set(started.map(([id]) => Number(id)));
		for (const id of keeping.cwds.keys()) if (!recent.has(id)) keeping.cwds.delete(id);
	}
	// The last answer again, while it was made of the same, each folder used that it offers still has the real path it had,
	// and each folder it offers is still a folder.
	const key = JSON.stringify([
		[...used],
		projects.filter((project) => project.folder !== null).map((project) => [project.folder, project.name, project.repository?.owner ?? null, project.repository?.name ?? null]),
	]);
	const last = keeping?.offered;
	if (keeping !== undefined && last !== undefined && last.key === key && keeping.now() - last.at < OFFERED_MS && stillThere(last)) {
		offerFolders(last.folders.map((folder) => folder.path));
		return last.folders.map((folder) => ({ ...folder }));
	}
	const own = [real(engine.home) ?? engine.home, real(scratchRoot(engine.home)) ?? scratchRoot(engine.home)];
	const byReal = new Map<string, number>();
	const resolved = new Map<string, string>();
	for (const [path, at] of used) {
		const found = real(path);
		// Never in pi²'s own folders, nor holding one (the home folder, `~/Library`, `/`).
		if (found === null || own.some((folder) => within(found, folder) || within(folder, found)) || maskKeys(found) !== found) continue;
		try {
			if (!statSync(found).isDirectory()) continue;
		} catch {
			continue;
		}
		byReal.set(found, Math.max(byReal.get(found) ?? 0, at));
		resolved.set(path, found);
	}
	// A project's folder by its real path too, should it have become a link since it was set.
	const projectOf = new Map(projects.filter((project) => project.folder !== null).map((project) => [real(project.folder!) ?? project.folder!, project]));
	const ordered = [...byReal].sort(([pathA, a], [pathB, b]) => Number(projectOf.has(pathA)) - Number(projectOf.has(pathB)) || b - a);
	const offered = ordered.slice(0, MAX_FOLDERS).map(([path]) => {
		const project = projectOf.get(path);
		const repository = project?.repository != null ? `${project.repository.owner}/${project.repository.name}` : repositoryOf(path);
		return {
			path,
			name: basename(path) || path,
			where: shown(dirname(path)),
			...(project === undefined ? {} : { project: project.name }),
			...(repository === undefined ? {} : { repository }),
		};
	});
	offerFolders(offered.map((folder) => folder.path));
	if (keeping !== undefined) {
		const paths = new Set(offered.map((folder) => folder.path));
		const sources = [...resolved].filter(([, found]) => paths.has(found));
		keeping.offered = { key, at: keeping.now(), folders: offered.map((folder) => ({ ...folder })), sources };
	}
	return offered;
}

/**
 * `projects.create`'s folder from a phone, checked again as the project is made: one `projects.folders` offers at this
 * moment, by its exact text, as the phone was given it. Nothing the phone names is looked up on the disk unless it is
 * already one of those; then it is checked to be still that folder, with no link on its way.
 */
export async function offeredFolder(value: unknown): Promise<string | null> {
	if (value === null) return null;
	if (typeof value !== "string" || value.trim() === "") throw new Error("folder must be a folder's path, or null");
	if (!(await offeredFolders()).some((folder) => folder.path === value)) throw new Error(NOT_OFFERED);
	try {
		if (real(value) !== value || !statSync(value).isDirectory()) throw new Error(NOT_OFFERED);
	} catch {
		throw new Error(NOT_OFFERED);
	}
	return value;
}

// ---- files.preview

/**
 * The absolute path a link's target names, by its text alone, as the Mac's file links take it (FileLink.path in
 * app/Sources/FileLinkKit): an absolute path, `~` or `~/…`, a `file:` address with no host but `localhost`, or a path
 * relative to the conversation's folder; with `.` and `..` worked out. Null when it names no file on the Mac.
 */
export function linkPath(target: string, folder: string, home = homedir()): string | null {
	const text = target.trim();
	// biome-ignore lint/suspicious/noControlCharactersInRegex: control characters are what is refused
	if (text === "" || text.length > 4096 || /[\u0000-\u001f\u007f]/.test(text)) return null;
	let path: string;
	if (/^file:/i.test(text)) {
		const address = /^file:\/\/(?:localhost)?(\/[^?#]*)/i.exec(text);
		if (address === null) return null;
		try {
			path = decodeURIComponent(address[1]!);
		} catch {
			return null;
		}
		// biome-ignore lint/suspicious/noControlCharactersInRegex: control characters are what is refused
		if (path.startsWith("//") || /[\u0000-\u001f\u007f]/.test(path)) return null;
	} else if (/^[a-z][a-z0-9+.-]*:/i.test(text) || text.startsWith("//")) return null;
	else if (text === "~") path = home;
	else if (text.startsWith("~/")) path = home + text.slice(1);
	else if (text.startsWith("/")) path = text;
	else if (/^[#?~]/.test(text)) return null;
	else path = `${folder.endsWith("/") ? folder : `${folder}/`}${text}`;
	const names: string[] = [];
	for (const name of path.split("/")) {
		if (name === "" || name === ".") continue;
		if (name === "..") names.pop();
		else names.push(name);
	}
	return `/${names.join("/")}`;
}

/**
 * The targets of the links in `markdown` that the conversation's page could draw as file links: inline links and
 * pictures, and autolinks to `file:` addresses, outside fenced code and code spans. A target given in angle brackets
 * is taken without them.
 */
export function linkTargets(markdown: string): string[] {
	const prose: string[] = [];
	let fence: string | null = null;
	for (const line of markdown.split("\n")) {
		const marker = /^ {0,3}(`{3,}|~{3,})/.exec(line)?.[1];
		if (fence === null && marker !== undefined) fence = marker;
		else if (fence !== null && marker !== undefined && marker[0] === fence[0] && marker.length >= fence.length && line.trim() === marker) fence = null;
		else if (fence === null) prose.push(line);
	}
	const text = prose.join("\n").replace(/(`+)[\s\S]*?\1/g, " ");
	const targets: string[] = [];
	// The bare target is never empty: an empty one let `\s*` either side of it share a run of white space, and the search
	// took time growing with the square of its length (minutes for a megabyte, on the engine's thread).
	for (const found of text.matchAll(/\]\(\s*(?:<([^<>\n]*)>|([^\s()<>]+(?:\([^\s()<>]*\)[^\s()<>]*)*|(?:\([^\s()<>]*\)[^\s()<>]*)+))(?:\s+(?:"[^"\n]*"|'[^'\n]*'|\([^()\n]*\)))?\s*\)/g)) {
		targets.push(found[1] ?? found[2]!);
	}
	for (const found of text.matchAll(/<(file:[^<>\s]+)>/gi)) targets.push(found[1]!);
	return targets;
}

const ANOTHER_REPOSITORY = new Set(["GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_NAMESPACE", "GIT_PREFIX", "GIT_CEILING_DIRECTORIES", "GIT_DISCOVERY_ACROSS_FILESYSTEM"]);

/** What git says of `path`, relative to `folder` (a real path): ignored, kept, no repository there, or it cannot tell. */
async function gitIgnores(folder: string, path: string): Promise<"ignored" | "kept" | "no repository" | "unknown"> {
	// --no-index: a file that matches an ignore rule counts as ignored even if git tracks it. core.fsmonitor off: asking
	// runs nothing the repository's own configuration names.
	const { error, stderr } = await runOffThread("git", ["-c", "core.fsmonitor=false", "check-ignore", "--no-index", "-q", "--", path], {
		cwd: folder,
		timeout: 20_000,
		// None of the variables that would make git ask another repository than the folder's. A name git reads as a
		// pathspec's magic (":(glob)…") makes it fail, and the file is refused as one git could not tell of.
		env: Object.fromEntries(
			Object.entries(commandEnvironment({ GIT_OPTIONAL_LOCKS: "0", GIT_TERMINAL_PROMPT: "0", LC_ALL: "C" })).filter(([name]) => !ANOTHER_REPOSITORY.has(name)),
		),
	});
	if (error === null) return "ignored";
	if (error.code === 1) return "kept";
	if (error.code === 128 && /not a git repository/i.test(stderr)) return "no repository";
	return "unknown";
}

type Conversation = NonNullable<Awaited<ReturnType<ReturnType<Engine["harness"]>["conversation"]>>>;

/**
 * The files conversation `id`'s agent's answers link to, each by the path its target names read against `folder`. Kept
 * by the folder and the conversation's newest entry: entries never change once committed, so the same newest entry
 * means the same transcript; a new one, or another folder, reads it all again.
 */
async function linkedFiles(engine: Engine, id: number, conv: Conversation, folder: string): Promise<ReadonlySet<string>> {
	const keeping = kept.get(engine);
	let newest: unknown;
	if (keeping !== undefined) {
		newest = (await conv.entries({ order: "descending" }, 1, undefined, engine.context())).items[0]?.id;
		const known = keeping.linked.get(id);
		if (known !== undefined && newest !== undefined && known.newest === newest && known.folder === folder) return known.paths;
	}
	const paths = new Set<string>();
	let cursor: unknown;
	for (;;) {
		const batch = await conv.entries({ order: "ascending" }, 500, cursor as never, engine.context());
		for (const entry of batch.items) {
			const item = toItem(entry);
			if (item?.kind !== "assistant") continue;
			for (const target of linkTargets(item.text)) {
				const path = linkPath(target, folder);
				if (path !== null) paths.add(path);
			}
		}
		cursor = (batch as { next?: unknown }).next;
		if (cursor === undefined || batch.items.length === 0) break;
	}
	if (keeping !== undefined && newest !== undefined) {
		// The conversation asked last goes to the end; past LINKED_KEPT, the one asked longest ago is forgotten.
		keeping.linked.delete(id);
		keeping.linked.set(id, { folder, newest, paths });
		if (keeping.linked.size > LINKED_KEPT) keeping.linked.delete(keeping.linked.keys().next().value!);
	}
	return paths;
}

/**
 * Whether `folder` (a real path) is in the worktree pi² made for conversation `id`, or, for a sub-chat, for the
 * conversation it works for, whose folder it joins: by pi²'s record of each, never by where the folder is (#902).
 */
async function inOwnWorktree(engine: Engine, id: number, folder: string, data: string): Promise<boolean> {
	const conversations = engine.library().conversations;
	const made = await allWorktrees(engine.harness(), engine.context());
	let at: number | undefined = id;
	for (let hops = 0; at !== undefined && hops < 16; hops++) {
		const worktree = made[String(at)];
		const path = typeof worktree?.path === "string" ? real(worktree.path) : null;
		if (path !== null && path.startsWith(`${data}/worktrees/`) && within(folder, path)) return true;
		at = conversations[String(at)]?.parent;
	}
	return false;
}

/**
 * `files.preview { id, path }`: the text of a file conversation `id` links to, and its size in bytes; see the top of
 * this file. `between` runs after the checks and before the read: the test swaps the file there.
 */
export async function previewFile(params: Record<string, unknown>, engine: Engine | undefined = wired, between?: () => Promise<void>): Promise<{ text: string; size: number }> {
	if (engine === undefined) throw new Error(NO_FOLDER);
	const id = params.id;
	const meta = typeof id === "number" ? engine.library().conversations[String(id)] : undefined;
	if (meta === undefined || meta.deleted === true) throw new Error(`Unknown conversation: ${String(id)}`);
	if (typeof params.path !== "string") throw new Error(NOT_A_PATH);
	const doc = await engine.harness().snapshot(AgentDoc, id as unknown as ConversationId, engine.context());
	const folder = (doc as { cwd?: string | null } | undefined)?.cwd ?? null;
	if (folder === null || !folder.startsWith("/")) throw new Error(NO_FOLDER);
	const asked = linkPath(params.path, folder);
	if (asked === null) throw new Error(NOT_A_PATH);

	// Linked from one of its agent's answers, by the same reading of a target.
	const conv = await engine.harness().conversation(id as unknown as ConversationId, engine.context());
	if (conv === undefined) throw new Error(`Unknown conversation: ${String(id)}`);
	if (!(await linkedFiles(engine, id as number, conv, folder)).has(asked)) throw new Error(NOT_LINKED);

	// Under the folder: by its text first, so that a link out tells nothing of what is there; then once links are
	// followed. Then what it is: pi²'s own and git's own are refused before anything is said of the file itself.
	const realFolder = real(folder);
	if (realFolder === null) throw new Error(FOLDER_GONE);
	const folderText = linkPath(folder, "/") ?? folder;
	if (asked === folderText || asked === realFolder || !(within(asked, folderText) || within(asked, realFolder))) throw new Error(OUTSIDE);
	const file = real(asked);
	if (file === null) throw new Error(MISSING);
	if (file === realFolder || !within(file, realFolder)) throw new Error(OUTSIDE);
	const relative = realFolder === "/" ? file.slice(1) : file.slice(realFolder.length + 1);
	if (relative.split("/").includes(".git")) throw new Error(IN_GIT);
	// pi²'s data folder (its settings, endpoints and MCP servers' command lines, 5.7) and the scratch folders, but for the
	// conversation's own worktree there, which is its folder: never another conversation's, nor a folder holding several.
	const data = real(engine.home) ?? engine.home;
	const pi2Own = [data, real(scratchRoot(engine.home)) ?? scratchRoot(engine.home)];
	if (pi2Own.some((own) => within(file, own)) && !(await inOwnWorktree(engine, id as number, realFolder, data))) throw new Error(IN_PI2);
	const checked = lstatSync(file, { bigint: true });
	if (!checked.isFile()) throw new Error(NOT_A_FILE);
	// git before the size and the other name, so that nothing is said of a file git ignores.
	const git = await gitIgnores(realFolder, relative);
	if (git === "ignored") throw new Error(IGNORED);
	if (git === "unknown") throw new Error(GIT_UNKNOWN);
	// The conversation's folder's own names too, by its text and once links are followed: one working in `~/.ssh`, or
	// through a link to it, is shown nothing there.
	const dotted = (path: string) => path.split("/").some((name) => name.startsWith("."));
	if (git === "no repository" && (dotted(relative) || dotted(realFolder) || dotted(folderText))) throw new Error(DOT_OUTSIDE_GIT);
	if (checked.nlink > 1n) throw new Error(HARD_LINK);
	if (checked.size > BigInt(MAX_PREVIEW)) throw new Error(tooLarge(Number(checked.size)));

	// The read, of the file checked and nothing else: no link followed anywhere on its path, no wait on a pipe.
	await between?.();
	const darwin = process.platform === "darwin";
	if (!darwin && process.platform !== "linux") throw new Error("Files are shown on a phone only from a Mac.");
	// macOS refuses O_NOFOLLOW beside O_NOFOLLOW_ANY (EINVAL), which covers it.
	const flags = constants.O_RDONLY | constants.O_NONBLOCK | (darwin ? O_NOFOLLOW_ANY : constants.O_NOFOLLOW);
	let handle: Awaited<ReturnType<typeof open>>;
	try {
		handle = await open(file, flags);
	} catch {
		throw new Error(CHANGED);
	}
	try {
		if (!darwin && readlinkSync(`/proc/self/fd/${handle.fd}`) !== file) throw new Error(CHANGED);
		const opened = await handle.stat({ bigint: true });
		if (!opened.isFile() || opened.dev !== checked.dev || opened.ino !== checked.ino) throw new Error(CHANGED);
		if (opened.nlink > 1n) throw new Error(HARD_LINK);
		const buffer = Buffer.alloc(MAX_PREVIEW + 1);
		let size = 0;
		for (;;) {
			const { bytesRead } = await handle.read(buffer, size, buffer.length - size, size);
			if (bytesRead === 0) break;
			size += bytesRead;
			if (size > MAX_PREVIEW) throw new Error(tooLarge(Number(opened.size)));
		}
		const bytes = buffer.subarray(0, size);
		if (bytes.includes(0)) throw new Error(NOT_TEXT);
		let text: string;
		try {
			text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
		} catch {
			throw new Error(NOT_TEXT);
		}
		return { text, size };
	} finally {
		await handle.close();
	}
}

/** When each device was last shown files, the last minute's, by device, in `performance.now()`'s milliseconds. */
const previewsBy = new Map<string, number[]>();

/**
 * Counts one `files.preview` from `device`, or refuses it, in words the phone shows, when it asked for
 * PREVIEWS_PER_MINUTE in the last minute. Counted before any of the work, whether it is then shown or refused; one
 * refused here is not counted, so a phone that keeps asking is shown files again a minute after its last one shown.
 * On a monotonic clock (#997), so that a change of the Mac's clock neither holds a phone back nor gives it a new count.
 */
export function previewCounted(device: string, now = performance.now()): void {
	const recent = (previewsBy.get(device) ?? []).filter((at) => now - at < 60_000);
	if (recent.length >= PREVIEWS_PER_MINUTE) {
		previewsBy.set(device, recent);
		throw new Error(TOO_MANY_PREVIEWS);
	}
	recent.push(now);
	previewsBy.set(device, recent);
}

export const folders: Feature = (_host, engine) => {
	wired = engine;
	wireOfferedFolder(offeredFolder);
	return {
		start: async () => keepFolders(engine),
		handlers: {
			/** `{}`: `{ folders: [{ path, name, where?, project?, repository? }] }`, the folders offered for a new project. */
			"projects.folders": async () => ({ folders: await offeredFolders(engine) }),
			/** `{ id, path }`: `{ text, size }` of a text file the conversation links to, under its folder; a device's counted. */
			"files.preview": async (params, connection) => {
				const device = (connection as Client | undefined)?.device?.id;
				if (device !== undefined) previewCounted(device);
				return previewFile(params, engine);
			},
		},
	};
};
