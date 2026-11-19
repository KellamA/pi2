// Worktrees and the branch tracker. See docs/worktrees.md.
//
// A conversation whose folder is in a git repository can move into a worktree of its own: a second checkout of the
// same repository on a new branch, so several agents can change one project at once without stepping on each other.
// pi² keeps those worktrees in its data folder and remembers which conversation each belongs to.
//
// Separately, the tracker looks at the folder of every conversation in the sidebar every few seconds and tells the
// app which branch it is on, whether that is a worktree, and how the branch stands: clean, changed, ahead, merged,
// in conflict. Nothing here runs a git command that changes anything, except creating and removing a worktree when
// the person asks for it.
//
// An agent can have a set-up command (`npm ci`, say) that runs once in each new worktree of its conversations, so what
// git ignores is put back before the agent needs it. Its start and end are written into the transcript, and the
// conversation's next request waits for it, so the agent is told how it went before it answers.

import { type ChildProcess, spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, lstatSync, mkdirSync, mkdtempSync, realpathSync, statSync } from "node:fs";
import { rm, rmdir } from "node:fs/promises";
import { basename, dirname, join, relative, sep } from "node:path";
import { awaitWithContext, type Context } from "@earendil-works/chord/context";
import type { ConversationId, DocumentReader } from "@earendil-works/pi-durable";
import { AgentDoc, defineDoc, section } from "@earendil-works/pi-durable";
import { commandEnvironment } from "./environment.ts";
import type { Feature } from "./features.ts";
import { runOffThread } from "./offthread.ts";
import type { MadeWorktree } from "./rules.ts";
import { forAgent } from "./priority.ts";
import { scratchVariable } from "./scratch.ts";
import { agentVariables } from "./variables.ts";
import type { AgentProfile } from "./state.ts";
import { stopCommandsIn } from "./background.ts";
import { forgetRun, type LeftOver, leftOverLog, newRun, noteProcess, RUN_VARIABLE, type RunProcess, signallable, stopLeftOver } from "./processes.ts";

/** A worktree pi² made for a conversation. */
export type Worktree = {
	/** The worktree's own folder. */
	path: string;
	branch: string;
	/** The repository's main checkout. */
	repo: string;
	/** The folder the conversation worked in before, which it goes back to when the worktree is removed. */
	origin: string;
	/** The branch the worktree was made from, if it was made from one; what "merged" is measured against. */
	base: string | null;
	/** The commit it started at. */
	baseCommit: string;
	createdAt: number;
	/** Written only after the removal checks, before Git moves the checkout out of use. */
	checkoutId?: string;
	removal?: { holding: string; holdingId: string; checkoutId: string; gitDir: string; gitDirId: string; branch: string; base?: string; deleting?: boolean };
	/** How the agent's set-up command went in it, when there was one. */
	setup?: Setup;
};

/** A set-up command's run in a new worktree. Written to the transcript as a `SETUP_ENTRY` when it starts and ends. */
export type Setup = {
	/** Which run this is, so that the transcript's start and end entries pair up. */
	run: string;
	command: string;
	status: "running" | "done" | "failed";
	/** For a failure, what happened, worded to follow "the set-up command": "exited with code 1". */
	reason?: string;
	seconds?: number;
	/** The end of what it printed, standard output and errors together. */
	output?: string;
	/** While it runs: its process group, so that an engine started after one that died can find what was left running. */
	process?: RunProcess;
};

/** A set-up command's transcript entry: display only, so the model never sees it (a prompt section tells it instead). */
export const SETUP_ENTRY = "pi2.setup";
/** Long enough for an install and a first build; a command still going after this is stopped. */
const SETUP_TIMEOUT_MS = 15 * 60_000;
/** How much of its output the transcript keeps: the end, where the errors are. */
const SETUP_KEEP_CHARS = 32 * 1024;
/** How much of a failed set-up's output the agent is shown. */
const SETUP_TOLD_CHARS = 2_000;
/** After SIGTERM, how long a set-up gets before SIGKILL; after it exits, how long the rest of its output may take. */
const SETUP_GRACE_MS = 3_000;
/** How often the apps are sent a running set-up's output, at most. */
const SETUP_PUSH_MS = 250;

/** What the app is sent for a set-up entry: one line for anything that shows only text, and the rest as details. */
export function setupItem(id: number, data: unknown) {
	const setup = (data !== null && typeof data === "object" ? data : {}) as Partial<Setup>;
	const command = typeof setup.command === "string" ? setup.command : "";
	const status = setup.status === "done" || setup.status === "failed" ? setup.status : "running";
	const reason = typeof setup.reason === "string" ? setup.reason : "failed";
	// A failed one leads with what happened, so that where the line is cut short it is the command that goes.
	const text = status === "running" ? `Running the set-up command: ${command}` : status === "done" ? `The set-up command finished: ${command}` : `${setupLead(status, reason)} · ${command}`;
	const details = {
		run: String(setup.run ?? ""),
		command,
		status,
		reason: status === "failed" ? reason : null,
		seconds: typeof setup.seconds === "number" ? setup.seconds : null,
		output: typeof setup.output === "string" ? setup.output : "",
	};
	return { id, kind: "setup" as const, text, isError: status === "failed", details };
}

/** What happened to a set-up, without its command: "Set-up command failed: exited with code 1". */
function setupLead(status: string, reason: string | null): string {
	if (status === "running") return "Running the set-up command";
	if (status === "done") return "The set-up command finished";
	const why = (reason ?? "").replace(/\s+/g, " ").trim();
	return why === "" || why === "failed" ? "Set-up command failed" : `Set-up command failed: ${why}`;
}

/** A set-up entry in a Markdown export: what happened, then the command in a block of its own, exactly as it was. */
export function setupMarkdown(details: ReturnType<typeof setupItem>["details"]): string {
	const lead = `*${setupLead(details.status, details.reason)}*`;
	if (details.command.trim() === "") return lead;
	const fence = "`".repeat(Math.max(3, ...[...details.command.matchAll(/`+/g)].map((run) => run[0].length + 1)));
	return `${lead}\n\n${fence}sh\n${details.command}\n${fence}`;
}

/** The end of `text`, at most `chars` of it, marked when something was left out. */
const tail = (text: string, chars: number) => (text.length <= chars ? text : `[earlier output left out]\n${text.slice(-chars)}`);

/** Signal a set-up command and everything it started: it leads a process group of its own. */
function signalGroup(child: ChildProcess, signal: NodeJS.Signals): void {
	if (child.pid === undefined) return;
	try {
		process.kill(-child.pid, signal);
	} catch {
		// Already gone.
	}
}

const Worktrees = defineDoc<{ conversations: Record<string, Worktree> }>({
	kind: "pi2.worktrees",
	version: 1,
	scope: "session",
	initial: () => ({ conversations: {} }),
	checkpointWhen: () => true,
});

/** How a branch stands, most pressing first. The app picks the icon's colour from this. */
export type BranchState = "missing" | "unavailable" | "conflict" | "changes" | "detached" | "merged" | "ahead" | "behind" | "clean";

/** What the app is told about one conversation's folder. */
export type BranchInfo = {
	/** The repository's name: its main checkout's folder name. */
	repo: string;
	/** The top of the checkout the conversation works in. */
	root: string;
	/** Null when HEAD is detached. */
	branch: string | null;
	/** Short commit id of HEAD; null in a repository with no commits yet. */
	head: string | null;
	/** Whether the folder is a linked worktree rather than the repository's main checkout. */
	worktree: boolean;
	/** Whether pi² made that worktree for this conversation (and so can remove it). */
	managed: boolean;
	upstream: string | null;
	/** Commits not pushed to the upstream, and commits on the upstream not here. Zero without an upstream. */
	ahead: number;
	behind: number;
	/** What "merged" and `unmerged` are measured against: the branch a worktree was made from, else the default branch. */
	base: string | null;
	/** Commits on this branch that are not on `base`; null when this is the base branch or there is none. */
	unmerged: number | null;
	/** Files changed, added or not yet tracked. */
	changes: number;
	/** Files with unresolved conflicts. */
	conflicts: number;
	/** A merge, rebase, cherry-pick or revert that has stopped half way. */
	operation: string | null;
	state: BranchState;
};

/**
 * A worktree pi² made for a conversation that is no longer in the sidebar: archived or deleted, or a sub-chat of one
 * that is. It stays on disk until the person removes it, so the Branches page lists it.
 */
export type LeftBehind = {
	id: number;
	title: string;
	/** "archived" can be restored, so its worktree may still be wanted; "deleted" will not come back. */
	reason: "archived" | "deleted";
	status: BranchInfo;
};

const POLL_MS = 5_000;
/** How long a conversation's folder is remembered before it is read again; changes made through the app count at once. */
const FOLDER_TTL_MS = 30_000;
/** A worktree pi² made is asked about afresh at every look, since removing it depends on the answer. */
const GIT_TTL_MS = 60_000;
const GIT_TIMEOUT_MS = 10_000;
// Mutations can touch thousands of files. Keep a hang guard, not the tracker's short polling deadline.
const WORKTREE_TIMEOUT_MS = 15 * 60_000;

export class GitError extends Error {}

/** Runs git without touching the index lock (so it never gets in an agent's way) and without ever asking for input. */
// Off the engine's thread (offthread.ts): the tracker runs git for every folder every few seconds.
export async function git(args: string[], cwd: string, timeout = GIT_TIMEOUT_MS): Promise<string> {
	const { error, stdout, stderr } = await runOffThread("git", args, {
		cwd,
		timeout,
		maxBuffer: 8 * 1024 * 1024,
		env: commandEnvironment({ GIT_OPTIONAL_LOCKS: "0", GIT_TERMINAL_PROMPT: "0", LC_ALL: "C" }),
	});
	if (error === null) return stdout;
	const lines = stderr.split(/[\r\n]+/).map((line) => line.trim()).filter((line) => line !== "" && !/^(?:[^:]+: +\d+%|Preparing worktree|HEAD is now at)/.test(line));
	const message = error.code === "ERR_CHILD_PROCESS_STDIO_MAXBUFFER" ? "git printed more output than pi² can keep"
		: error.killed ? `git was stopped after reaching its ${timeout / 1000}-second limit`
		: error.signal !== null ? `git was stopped by ${error.signal}`
		: lines.find((line) => /^(fatal|error): /.test(line)) ?? lines.at(-1) ?? `git ${typeof error.code === "number" ? `exited with code ${error.code}` : `failed${error.code === null ? "" : ` (${error.code})`}`}`;
	throw Object.assign(new GitError(tailReason(message.replace(/^(fatal|error): /, ""))), { code: error.code });
}

const tailReason = (message: string) => message.length <= 240 ? message : `${message.slice(0, 239)}…`;
const worktreeGit = (args: string[], cwd: string) => git(["worktree", ...args], cwd, WORKTREE_TIMEOUT_MS);

const tryGit = (args: string[], cwd: string) => git(args, cwd).then((out) => out.trim(), () => undefined);

type Repo = { root: string; gitDir: string; commonDir: string; main: string; worktree: boolean };
type RemoveOptions = { force: boolean; deleteBranch: boolean; onlyIfMerged?: boolean };
type RemovalResult = { branchDeleted: boolean; note: string | null; branch: string | null };

/** The repository a folder is in, or undefined when it is in none (or git is missing). */
export async function repoOf(folder: string): Promise<Repo | undefined> {
	if (!isFolder(folder)) return undefined;
	const out = await tryGit(["rev-parse", "--path-format=absolute", "--show-toplevel", "--git-dir", "--git-common-dir"], folder);
	const [root, gitDir, commonDir] = out?.split("\n") ?? [];
	if (root === undefined || gitDir === undefined || commonDir === undefined || root === "") return undefined;
	// A bare repository has no main checkout; its worktrees are named after the repository folder itself.
	const main = basename(commonDir) === ".git" ? dirname(commonDir) : commonDir;
	return { root, gitDir, commonDir, main, worktree: realish(gitDir) !== realish(commonDir) };
}

function isFolder(path: string): boolean {
	try {
		return statSync(path).isDirectory();
	} catch {
		return false;
	}
}

function realish(path: string): string {
	try {
		return realpathSync(path);
	} catch {
		return path;
	}
}

/** Whether `folder` is `root` or inside it. */
const within = (folder: string, root: string) => (realish(folder) + sep).startsWith(realish(root) + sep);

/** Do not mistake a symlink, replacement folder or unreadable path for the directory on record. */
function directoryId(path: string): string | null {
	try {
		const stat = lstatSync(path, { bigint: true });
		if (stat.isDirectory()) return `${stat.dev}:${stat.ino}:${stat.birthtimeNs}`;
		throw new Error("The recorded worktree path is not a directory. Check it by hand; pi² left it alone");
	} catch (error) {
		if ((error as NodeJS.ErrnoException).code === "ENOENT") return null;
		throw error;
	}
}

async function registrations(root: string) {
	const out = await worktreeGit(["list", "--porcelain", "-z"], root);
	return out.split("\0\0").flatMap((record) => {
		const [path, ...fields] = record.split("\0");
		return path?.startsWith("worktree ") ? [{ path: path.slice(9), fields }] : [];
	});
}

/** Only forget the exact missing checkout, never prune unrelated worktrees or let Git match a path suffix. */
type Registration = Awaited<ReturnType<typeof registrations>>[number];
const canonicalPath = (path: string) => join(realish(dirname(path)), basename(path));

async function forgetCheckout(root: string, path: string, entries?: Registration[]): Promise<void> {
	const entry = (entries ?? await registrations(root)).find((entry) => canonicalPath(entry.path) === canonicalPath(path));
	if (entry === undefined) return;
	if (directoryId(path) !== null || directoryId(entry.path) !== null) throw new Error("A folder is now at the old worktree path. Check it by hand; pi² left it alone");
	await worktreeGit(["remove", "--", entry.path], root);
}

/**
 * The folder a new sub-chat starts in. It joins the folder its parent works in now (a worktree, say), unless the other
 * agent has a folder of its own in another repository, or in none, which it keeps.
 */
export async function subChatFolder(parent: string | null, own: string | null): Promise<string | null> {
	if (own === null || parent === null) return parent ?? own;
	const [a, b] = await Promise.all([repoOf(parent), repoOf(own)]);
	return a !== undefined && b !== undefined && realish(a.commonDir) === realish(b.commonDir) ? parent : own;
}

/** The repository's default branch: what origin/HEAD points at, else a local main or master. */
async function defaultBranch(root: string): Promise<string | null> {
	const remote = await tryGit(["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"], root);
	if (remote) return remote;
	for (const name of ["main", "master"]) {
		if ((await tryGit(["rev-parse", "--verify", "--quiet", `refs/heads/${name}`], root)) !== undefined) return name;
	}
	return null;
}

/**
 * Which repository a folder is in, and what a repository's default branch is, kept between looks: neither changes
 * often, and the tracker looks at every folder in the sidebar every few seconds.
 */
let repos = new Map<string, { at: number; value: Repo | undefined }>();
let defaults = new Map<string, { at: number; value: string | null }>();

/** What `ask` answers for `key`, kept for `GIT_TTL_MS`, so a look does not start the git process that answers it again and again. */
async function kept<T>(where: Map<string, { at: number; value: T }>, key: string, ask: () => Promise<T>): Promise<T> {
	const was = where.get(key);
	if (was !== undefined && Date.now() - was.at < GIT_TTL_MS) return was.value;
	const value = await ask();
	const at = Date.now();
	where.set(key, { at, value });
	// An answer older than the limit is never read again, so this drops it here rather than letting the maps grow.
	for (const [other, entry] of where) if (at - entry.at >= GIT_TTL_MS) where.delete(other);
	return value;
}

/** A conversation moved folders or a removal began or ended. Replace the maps so an in-flight answer cannot refill them. */
function forgetKept(): void {
	repos = new Map();
	defaults = new Map();
}

/** Reads `git status --porcelain=v2 --branch`. */
export function parseStatus(out: string) {
	let oid: string | null = null;
	let head: string | null = null;
	let upstream: string | null = null;
	let ahead = 0;
	let behind = 0;
	let changes = 0;
	let conflicts = 0;
	for (const line of out.split("\n")) {
		if (line.startsWith("# branch.oid ")) {
			const value = line.slice("# branch.oid ".length);
			oid = value === "(initial)" ? null : value;
		} else if (line.startsWith("# branch.head ")) {
			const value = line.slice("# branch.head ".length);
			head = value === "(detached)" ? null : value;
		} else if (line.startsWith("# branch.upstream ")) upstream = line.slice("# branch.upstream ".length);
		else if (line.startsWith("# branch.ab ")) {
			const match = /\+(\d+) -(\d+)/.exec(line);
			if (match) {
				ahead = Number(match[1]);
				behind = Number(match[2]);
			}
		} else if (line.startsWith("u ")) conflicts++;
		else if (line.startsWith("1 ") || line.startsWith("2 ") || line.startsWith("? ")) changes++;
	}
	return { oid, head, upstream, ahead, behind, changes, conflicts };
}

/** Which of the states applies, most pressing first. */
export function stateOf(info: Omit<BranchInfo, "state">, options: { merged: boolean }): BranchState {
	if (info.conflicts > 0 || info.operation !== null) return "conflict";
	if (info.changes > 0) return "changes";
	if (info.branch === null) return "detached";
	if (options.merged) return "merged";
	if (info.ahead > 0 || (info.upstream === null && (info.unmerged ?? 0) > 0)) return "ahead";
	if (info.behind > 0) return "behind";
	return "clean";
}

const removingPaths = new Set<string>();
let removalGeneration = 0;
const statusArgs = ["status", "--porcelain=v2", "--branch", "--untracked-files=normal", "--ignore-submodules=none"];

function operationIn(gitDir: string): string | null {
	for (const [name, operation] of Object.entries({ MERGE_HEAD: "merge", "rebase-merge": "rebase", "rebase-apply": "rebase", CHERRY_PICK_HEAD: "cherry-pick", REVERT_HEAD: "revert" })) {
		if (existsSync(join(gitDir, name))) return operation;
	}
	return null;
}

function unreadableWorktree(own: Worktree, state: "missing" | "unavailable"): BranchInfo {
	return {
		repo: basename(own.repo),
		root: own.path,
		branch: own.branch,
		head: null,
		worktree: true,
		managed: true,
		upstream: null,
		ahead: 0,
		behind: 0,
		base: own.base,
		unmerged: null,
		changes: 0,
		conflicts: 0,
		operation: null,
		state,
	};
}

/** How the folder's branch stands, or undefined when the folder is not in a git repository. */
export async function inspect(folder: string, own?: Worktree): Promise<BranchInfo | undefined> {
	const generation = removalGeneration;
	if ([...removingPaths].some((path) => own?.path === path || within(folder, path))) return own === undefined ? undefined : unreadableWorktree(own, "unavailable");
	const info = await inspectCheckout(folder, own);
	// A status scan begun just before a removal may have seen only part of the checkout.
	return generation === removalGeneration ? info : own === undefined ? undefined : unreadableWorktree(own, "unavailable");
}

async function inspectCheckout(folder: string, own?: Worktree, checkingRemoval = false): Promise<BranchInfo | undefined> {
	if (own !== undefined && !isFolder(own.path)) return unreadableWorktree(own, own.removal === undefined && !existsSync(own.path) ? "missing" : "unavailable");
	const repo = own === undefined && !checkingRemoval ? await kept(repos, folder, () => repoOf(folder)) : await repoOf(own?.path ?? folder);
	if (repo === undefined || (own !== undefined && (!repo.worktree || realish(own.path) !== realish(repo.root)))) return own === undefined ? undefined : unreadableWorktree(own, "unavailable");
	const out = await git(statusArgs, repo.root, checkingRemoval ? WORKTREE_TIMEOUT_MS : GIT_TIMEOUT_MS).catch((error: Error) => {
		if (checkingRemoval) throw new Error(`git could not read the worktree's status: ${error.message}. Check git status and retry`);
		return undefined;
	});
	if (out === undefined) return own === undefined ? undefined : unreadableWorktree(own, "unavailable");
	const status = parseStatus(out);
	const operation = operationIn(repo.gitDir);
	const managed = own !== undefined && realish(own.path) === realish(repo.root);
	// Measured against the branch the worktree was made from, else the default branch, unless this is that branch.
	let base = managed && own.base !== null ? own.base : await (checkingRemoval ? defaultBranch(repo.root) : kept(defaults, repo.root, () => defaultBranch(repo.root)));
	if (base !== null && status.head !== null && (base === status.head || base === `origin/${status.head}`)) base = null;
	let unmerged: number | null = null;
	let merged = false;
	if (base !== null && status.oid !== null) {
		const counted = await tryGit(["rev-list", "--count", `${base}..${status.oid}`], repo.root);
		unmerged = counted === undefined ? null : Number(counted);
		// Only a worktree pi² made can be called merged with confidence: it has moved on from where it started and
		// everything on it is now on the base. Any other branch with nothing of its own may simply be new.
		if (managed && unmerged === 0 && status.oid !== own.baseCommit) merged = true;
	}
	const info = {
		repo: basename(repo.main),
		root: repo.root,
		branch: status.head,
		head: status.oid?.slice(0, 7) ?? null,
		worktree: repo.worktree,
		managed,
		upstream: status.upstream,
		ahead: status.ahead,
		behind: status.behind,
		base,
		unmerged,
		changes: status.changes,
		conflicts: status.conflicts,
		operation,
	};
	return { ...info, state: stateOf(info, { merged }) };
}

/** Whether an agent can remove this checkout and keep the branch, without leaving unmerged work behind. */
export function whyKeepWorktree(info: BranchInfo | undefined): string | undefined {
	if (info?.state === "missing") return undefined;
	if (info === undefined || info.state === "unavailable") return "pi² could not read how its branch stands";
	if (info.operation !== null) return `a ${info.operation} is stopped half way in it`;
	const changes = info.changes + info.conflicts;
	if (changes > 0) return `it has ${changes} uncommitted change${changes === 1 ? "" : "s"}`;
	if (info.branch === null || info.unmerged === null || info.base === null) return "pi² cannot tell whether its branch is merged";
	if (info.unmerged > 0) return `its branch has ${info.unmerged} commit${info.unmerged === 1 ? " that is" : "s that are"} not on ${info.base}; fetch first if it merged elsewhere`;
	return undefined;
}

/** A branch name made from a conversation's title: "pi2/fix-the-login-page". */
export function suggestBranch(title: string, fallback: string): string {
	const slug = title
		.toLowerCase()
		.normalize("NFKD")
		.replace(/[^a-z0-9]+/g, "-")
		.replace(/^-+|-+$/g, "")
		.slice(0, 40)
		.replace(/-+$/, "");
	return `pi2/${slug === "" ? fallback : slug}`;
}

/** A folder name for a branch: its slashes and anything odd turned into dashes. */
const folderName = (branch: string) => branch.replace(/[^A-Za-z0-9._-]+/g, "-").replace(/^[-.]+/, "") || "worktree";

export const worktrees: Feature = (_host, engine) => {
	let mine: Record<string, Worktree> = {};
	/** Each listed conversation's folder, with when it was read. */
	const folders = new Map<number, { cwd: string | null; at: number }>();
	let last: Record<string, BranchInfo> = {};
	let leftBehind: LeftBehind[] = [];
	let lastJSON = "";
	/** The look at the folders under way, if any, and the one asked for to follow it. */
	let looking: Promise<void> | undefined;
	let lookAgain: Promise<void> | undefined;
	let gitMissing = false;
	/** Conversations whose worktree is being made or removed right now. */
	const changing = new Set<number>();
	const repoChanges = new Map<string, Promise<unknown>>();
	async function inRepo<T>(commonDir: string, change: () => Promise<T>): Promise<T> {
		const key = realish(commonDir);
		const next = (repoChanges.get(key) ?? Promise.resolve()).catch(() => {}).then(change);
		repoChanges.set(key, next);
		try {
			return await next;
		} finally {
			if (repoChanges.get(key) === next) repoChanges.delete(key);
		}
	}
	/**
	 * Set-up commands running now, by conversation. `settled` resolves once their end is recorded and written; `output` is
	 * what they have printed so far, which the conversation's state carries while they run.
	 */
	const setups = new Map<number, { run: string; child: ChildProcess; output(): string; stop(reason: string): void; settled: Promise<void> }>();
	/**
	 * The set-ups the last engine had running, and what became of each, for the notice after it stopped unexpectedly: with
	 * the conversation in the sidebar each belongs to.
	 */
	const cutOff: { conversationId: number; rootConversationId: number; title: string; command: string; outcome: LeftOver; group: number | null }[] = [];

	const event = () => ({ event: "branches", conversations: last, leftBehind });

	async function save(edit: (doc: Record<string, Worktree>) => void): Promise<void> {
		await engine.harness().commit(async (tx) => edit((await tx.doc(Worktrees)).conversations), engine.context());
		mine = JSON.parse(JSON.stringify((await engine.harness().snapshot(Worktrees, engine.context()))?.conversations ?? {}));
	}

	async function folderOf(id: number): Promise<string | null> {
		const known = folders.get(id);
		if (known !== undefined && Date.now() - known.at < FOLDER_TTL_MS) return known.cwd;
		const doc = await engine.harness().snapshot(AgentDoc, id as unknown as ConversationId, engine.context());
		const cwd = (doc as { cwd?: string | null } | undefined)?.cwd ?? null;
		folders.set(id, { cwd, at: Date.now() });
		return cwd;
	}

	/** Why a conversation is out of the sidebar, or undefined when the sidebar lists it. */
	function away(id: string | number): LeftBehind["reason"] | undefined {
		const all = engine.library().conversations;
		const own = (key: string | number | undefined): LeftBehind["reason"] | undefined => {
			if (key === undefined) return undefined;
			const meta = all[String(key)];
			// Gone from the library altogether counts as deleted.
			if (meta === undefined || meta.deleted === true) return "deleted";
			return meta.archivedAt !== undefined || meta.archived !== undefined ? "archived" : undefined;
		};
		const reasons = [own(id), own(all[String(id)]?.parent)];
		return reasons.includes("deleted") ? "deleted" : reasons.includes("archived") ? "archived" : undefined;
	}

	/** The conversations the sidebar lists: not archived or deleted, nor a sub-chat of one that is. */
	function listed(): number[] {
		return Object.keys(engine.library().conversations)
			.filter((id) => away(id) === undefined)
			.map(Number);
	}

	/**
	 * Look at the folders again and tell the apps if anything changed. Asked while a look is under way, it looks once more
	 * after that one, which may have read the library before whatever change the caller wants seen; however many ask
	 * meanwhile, once.
	 */
	function refresh(): Promise<void> {
		if (gitMissing) return Promise.resolve();
		if (looking === undefined) {
			looking = look().finally(() => (looking = undefined));
			return looking;
		}
		lookAgain ??= looking.then(() => {
			lookAgain = undefined;
			return refresh();
		});
		return lookAgain;
	}

	async function look(): Promise<void> {
		try {
			// Which conversations are listed and which are put away, at one moment: the library can change while git is
			// asked below, and the event must not say a conversation is both in the sidebar and left behind (#128).
			const ids = listed();
			const putAway = Object.entries(mine).flatMap(([key, own]) => {
				const reason = away(key);
				return reason === undefined ? [] : [{ key, own, reason }];
			});
			for (const id of folders.keys()) if (!ids.includes(id)) folders.delete(id);
			const byFolder = new Map<string, Promise<BranchInfo | undefined>>();
			const next: Record<string, BranchInfo> = {};
			const worktreeFolders = Object.entries(mine).map(([key, own]) => ({ key, folder: realish(own.path) + sep }));
			for (const id of ids) {
				const cwd = await folderOf(id);
				if (cwd === null) continue;
				// A conversation working in a worktree pi² made for another one, as a sub-chat does in its parent's, is looked
				// at as that worktree: one look for the folder however many work in it, and the same state the owner shows
				// (merged is measured against where the worktree started). Only the owner is told the worktree is its own.
				const inside = mine[String(id)] === undefined ? realish(cwd) + sep : "";
				const ownerKey = mine[String(id)] !== undefined ? String(id) : worktreeFolders.find(({ folder }) => inside.startsWith(folder))?.key;
				const own = ownerKey === undefined ? undefined : mine[ownerKey];
				const key = ownerKey === undefined ? cwd : `${cwd}\u0000${ownerKey}`;
				if (!byFolder.has(key)) byFolder.set(key, inspect(cwd, own));
				const info = await byFolder.get(key)!;
				if (info !== undefined) next[String(id)] = ownerKey === String(id) || !info.managed ? info : { ...info, managed: false };
			}
			// Worktrees of conversations put away: still on disk until the person removes them.
			const behind: LeftBehind[] = [];
			for (const { key, own, reason } of putAway) {
				const status = await inspect(own.path, own);
				if (status !== undefined) behind.push({ id: Number(key), title: engine.library().conversations[key]?.title ?? "", reason, status });
			}
			behind.sort((a, b) => (mine[String(b.id)]?.createdAt ?? 0) - (mine[String(a.id)]?.createdAt ?? 0));
			const json = JSON.stringify([next, behind]);
			last = next;
			leftBehind = behind;
			if (json !== lastJSON) {
				lastJSON = json;
				engine.broadcast(event());
			}
		} catch (error) {
			if ((error as { code?: unknown }).code === "ENOENT") gitMissing = true;
			engine.log("branches:", error instanceof Error ? error.message : error);
		}
	}

	async function setFolder(id: number, cwd: string): Promise<void> {
		const conv = await engine.harness().conversation(id as unknown as ConversationId, engine.context());
		if (conv === undefined) throw new Error(`Unknown conversation: ${id}`);
		await conv.configure({ cwd }, engine.context());
		forgetKept();
		folders.set(id, { cwd, at: Date.now() });
	}

	/** Write a set-up command's start or end into the conversation's transcript, where the person sees it. */
	async function noteSetup(id: number, setup: Setup): Promise<void> {
		try {
			const conv = await engine.harness().conversation(id as unknown as ConversationId, engine.context());
			await conv?.submit({ type: "write", entry: { kind: SETUP_ENTRY, data: JSON.parse(JSON.stringify(setup)) } }, engine.context());
		} catch (error) {
			engine.log("could not note the set-up of conversation", id, error instanceof Error ? error.message : error);
		}
	}

	/** Keep how the set-up went with the worktree, unless the worktree went, or made another, meanwhile. */
	async function recordSetup(id: number, setup: Setup): Promise<void> {
		await save((doc) => {
			const own = doc[String(id)];
			if (own !== undefined && (own.setup === undefined || own.setup.run === setup.run)) own.setup = { ...setup, ...(setup.output === undefined ? {} : { output: tail(setup.output, SETUP_TOLD_CHARS) }) };
		});
	}

	/**
	 * Run the agent's set-up command in a worktree just made for conversation `id`, without waiting for it. It runs as
	 * the person typed it, through bash, with the engine's environment less pi²'s own settings (environment.ts), with the
	 * agent's own variables (variables.ts) and the conversation's scratch folder (scratch.ts), in a process group of its
	 * own so that stopping it stops whatever it started too. It is given what tells this run apart, which what it starts
	 * inherits, so that the next engine can know them if this one dies (`stopLeftOver`): a marker in its environment, and
	 * its run's file, open (`newRun`).
	 */
	async function startSetup(id: number, root: string, command: string): Promise<void> {
		const run = `${id}-${Date.now()}`;
		const started = Date.now();
		// The variables the person gave the conversation's agent (variables.ts). Without them the command is not run.
		let variables: Record<string, string>;
		try {
			variables = await agentVariables(id);
		} catch (error) {
			const setup: Setup = { run, command, status: "failed", reason: `could not start: ${error instanceof Error ? error.message : String(error)}`, seconds: 0, output: "" };
			engine.log("set-up for conversation", id, "could not start: the agent's variables could not be read");
			await recordSetup(id, setup);
			await noteSetup(id, setup);
			return;
		}
		await recordSetup(id, { run, command, status: "running" });
		await noteSetup(id, { run, command, status: "running" });
		let output = "";
		let stopped: string | undefined;
		let failedToStart: string | undefined;
		const given = newRun();
		const marker = given.marker;
		let child: ChildProcess;
		try {
			child = spawn(...forAgent("/bin/bash", ["-c", command]), { cwd: root, env: commandEnvironment({ ...variables, ...scratchVariable(id), [RUN_VARIABLE]: marker }), detached: true, stdio: given.stdio });
		} catch (error) {
			forgetRun(marker);
			throw error;
		}
		// Its output goes to the apps with the conversation's state as it arrives, a few times a second at most. Not as
		// transcript entries, which are kept for good: the one written when it ends holds the output's end.
		let pushing: ReturnType<typeof setTimeout> | undefined;
		const keep = (chunk: Buffer) => {
			output += chunk.toString("utf8");
			if (output.length > 2 * SETUP_KEEP_CHARS) output = output.slice(-SETUP_KEEP_CHARS);
			pushing ??= setTimeout(() => {
				pushing = undefined;
				engine.stateChanged(id);
			}, SETUP_PUSH_MS);
		};
		child.stdout?.on("data", keep);
		child.stderr?.on("data", keep);
		const stop = (reason: string) => {
			if (stopped !== undefined || child.exitCode !== null || child.signalCode !== null) return;
			stopped = reason;
			signalGroup(child, "SIGTERM");
			setTimeout(() => signalGroup(child, "SIGKILL"), SETUP_GRACE_MS).unref();
		};
		const timer = setTimeout(() => stop(`did not finish within ${SETUP_TIMEOUT_MS / 60_000} minutes and was stopped`), SETUP_TIMEOUT_MS);
		timer.unref();
		const ended = new Promise<{ code: number | null; signal: NodeJS.Signals | null }>((resolve) => {
			child.once("error", (error) => {
				failedToStart = error.message;
				resolve({ code: null, signal: null });
			});
			child.once("close", (code, signal) => resolve({ code, signal }));
			// Something it started in the background may hold its output open long after it exits; do not wait on that.
			child.once("exit", (code, signal) => setTimeout(() => resolve({ code, signal }), SETUP_GRACE_MS).unref());
		});
		// Its process group, that group's start and the run's marker, so that if this engine dies, the next one can stop what
		// it left running.
		void noteProcess(child, marker)
			.then(async (noted) => {
				if (noted === undefined) return;
				let kept = false;
				await save((doc) => {
					const setup = doc[String(id)]?.setup;
					if (setup?.run === run && setup.status === "running") {
						setup.process = noted;
						kept = true;
					}
				});
				// Written down: from here on, an engine that comes after this one can stop what the set-up left running.
				if (kept) engine.log("set-up for conversation", id, "runs as process group", noted.group);
			})
			.catch((error) => engine.log("could not note the set-up's process for conversation", id, error instanceof Error ? error.message : error));
		const settled = ended.then(async ({ code, signal }) => {
			clearTimeout(timer);
			clearTimeout(pushing);
			child.stdout?.destroy();
			child.stderr?.destroy();
			const reason =
				failedToStart !== undefined ? `could not start: ${failedToStart}` : stopped !== undefined ? stopped : code !== 0 ? (code === null ? `was ended by ${signal ?? "a signal"}` : `exited with code ${code}`) : undefined;
			const setup: Setup = { run, command, status: reason === undefined ? "done" : "failed", ...(reason === undefined ? {} : { reason }), seconds: Math.round((Date.now() - started) / 1000), output: tail(output, SETUP_KEEP_CHARS) };
			engine.log("set-up for conversation", id, reason === undefined ? "finished" : reason);
			await recordSetup(id, setup).catch((error) => engine.log("could not record the set-up of conversation", id, error instanceof Error ? error.message : error));
			// No longer on record as running, so no engine will look for its file.
			forgetRun(marker);
			await noteSetup(id, setup);
			if (setups.get(id)?.child === child) {
				setups.delete(id);
				// The entry has its output now; the state no longer carries it.
				engine.stateChanged(id);
			}
		});
		setups.set(id, { run, child, output: () => output, stop, settled });
	}

	/**
	 * Make a worktree for conversation `id` from the repository its folder is in, and move the conversation into it. A new
	 * branch starts from the commit the folder is on, or from `from` (a branch, tag or commit as the repository has it now).
	 */
	async function create(id: number, requested?: string, from?: string): Promise<{ path: string; branch: string }> {
		if (mine[String(id)] !== undefined) throw new Error("This conversation already has a worktree of its own");
		if (changing.has(id)) throw new Error("A worktree is already being made for this conversation");
		changing.add(id);
		try {
			folders.delete(id);
			const cwd = await folderOf(id);
			if (cwd === null) throw new Error("Choose a folder in a git repository for this conversation first");
			const repo = await repoOf(cwd);
			if (repo === undefined) throw new Error("This conversation's folder is not in a git repository");
			return await inRepo(repo.commonDir, () => createInRepo(id, cwd, repo, requested, from));
		} finally {
			changing.delete(id);
			void refresh();
		}
	}

	async function createInRepo(id: number, cwd: string, repo: Repo, requested?: string, from?: string) {
		const named = from?.trim();
		if (named !== undefined && (named === "" || named.startsWith("-"))) throw new Error(`“${from}” is not a branch, tag or commit`);
		const start = await tryGit(["rev-parse", "--verify", "--quiet", `${named ?? "HEAD"}^{commit}`], repo.root);
		if (named !== undefined && (start === undefined || start === "")) throw new Error(`“${named}” is not a branch, tag or commit in ${basename(repo.main)}`);
		if (start === undefined || start === "") throw new Error("The repository has no commits yet, so there is nothing to make a worktree from");
		const meta = engine.library().conversations[String(id)];
		let branch = requested?.trim() || suggestBranch(meta?.title ?? "", `${meta?.agentId ?? "conversation"}-${id}`);
		const checked = await git(["check-ref-format", "--branch", branch], repo.root).catch(() => undefined);
		if (checked === undefined) throw new Error(`“${branch}” cannot be a branch name`);
		branch = checked.trim();
		const exists = (name: string) => git(["show-ref", "--verify", "--quiet", `refs/heads/${name}`], repo.root).then(() => true, (error) => {
			if (error.code === 1) return false;
			throw error;
		});
		// A name the person chose that already exists is checked out as it is; a suggested one gets a number instead.
		const useExisting = requested !== undefined && requested.trim() !== "" && (await exists(branch));
		if (useExisting && named !== undefined) throw new Error(`The branch ${branch} already exists. Choose another name, or leave out where it starts from to check it out as it is`);
		if (!useExisting) for (let n = 2, stem = branch; await exists(branch); n++) branch = `${stem}-${n}`;
		const current = await tryGit(["symbolic-ref", "--quiet", "--short", "HEAD"], repo.root);
		const parent = join(engine.home, "worktrees", `${basename(repo.main)}-${createHash("sha256").update(realish(repo.commonDir)).digest("hex").slice(0, 6)}`);
		mkdirSync(parent, { recursive: true });
		const registered = new Set((await registrations(repo.root)).map((entry) => canonicalPath(entry.path)));
		const stem = join(parent, folderName(branch));
		const canonicalParent = realpathSync(parent);
		let path = stem;
		for (let n = 2; ; path = `${stem}-${n++}`) {
			if (registered.has(join(canonicalParent, basename(path)))) continue;
			try {
				mkdirSync(path, { mode: 0o700 });
				break;
			} catch (error) {
				if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
			}
		}
		const reserved = directoryId(path);
		const ref = `refs/heads/${branch}`;
		let madeBranch = false;
		try {
			// Know whether we created the branch, rather than inferring it from a failed `add -b`.
			if (!useExisting) {
				await git(["branch", "--no-track", "--", branch, start], repo.root, WORKTREE_TIMEOUT_MS);
				madeBranch = true;
			}
			await worktreeGit(["add", "--quiet", "--", path, branch], repo.root);
		} catch (error) {
			try {
				const id = directoryId(path);
				const entries = await registrations(repo.root);
				const entry = entries.find((entry) => canonicalPath(entry.path) === join(canonicalParent, basename(path)));
				if ((id !== null && id !== reserved) || (entry?.fields.some((field) => field.startsWith("locked") && field !== "locked initializing"))) throw new Error("the checkout changed");
				if (madeBranch && (await git(["rev-parse", "--verify", ref], repo.root)).trim() !== start) throw new Error("the new branch moved");
				if (id !== null) await rm(path, { recursive: true, force: true });
				if (entry?.fields.includes("locked initializing")) await worktreeGit(["unlock", "--", path], repo.root);
				await forgetCheckout(repo.root, path, entries);
				// The expected old value protects commits if the branch moved while we cleaned up.
				if (madeBranch) {
					if ((await registrations(repo.root)).some((entry) => entry.fields.includes(`branch ${ref}`))) throw new Error("the new branch is checked out elsewhere");
					await git(["update-ref", "-d", ref, start], repo.root, WORKTREE_TIMEOUT_MS);
				}
			} catch (cleanup) {
				engine.log("could not finish cleaning up worktree creation:", cleanup instanceof Error ? cleanup.message : cleanup);
				throw new Error(`git could not make the worktree: ${(error as Error).message}. Check ${path} and branch ${branch} before retrying`);
			}
			throw new Error(`git could not make the worktree: ${(error as Error).message}. Retry, or choose another branch name`);
		}
		const baseCommit = (await tryGit(["rev-parse", "HEAD"], path)) ?? start;
		// The same subfolder of the new checkout, when the conversation worked in one.
		const inside = relative(realish(repo.root), realish(cwd));
		const target = inside !== "" && !inside.startsWith("..") && isFolder(join(path, inside)) ? join(path, inside) : path;
		await save((doc) => {
			// "Merged" is measured against where it started: the ref it was made from, else the branch the folder was on.
			doc[String(id)] = { path, branch, repo: repo.main, origin: cwd, base: useExisting ? (current ?? null) : (named ?? current ?? null), baseCommit, createdAt: Date.now(), checkoutId: reserved! };
		});
		await setFolder(id, target);
		engine.log("worktree made for conversation", id, "on", branch);
		// The agent's set-up command, written for the agent's own repository, so run only in a worktree of that one.
		const agent = engine.agents()[meta?.agentId ?? ""];
		const command = agent?.setup?.trim() ?? "";
		const theirs = command === "" || agent?.cwd == null ? undefined : await repoOf(agent.cwd);
		if (theirs !== undefined && realish(theirs.commonDir) === realish(repo.commonDir)) {
			await startSetup(id, path, command).catch((error) => engine.log("could not start the set-up of conversation", id, error instanceof Error ? error.message : error));
		}
		return { path: target, branch };
	}

	/** Remove conversation `id`'s worktree and move it back to the folder it worked in before. */
	async function remove(id: number, options: RemoveOptions): Promise<RemovalResult> {
		const own = mine[String(id)];
		if (own === undefined) throw new Error("This conversation has no worktree of its own");
		if (changing.has(id)) throw new Error("The worktree is already being changed. Retry after it finishes");
		changing.add(id);
		removingPaths.add(own.path);
		removalGeneration++;
		forgetKept();
		try {
			const common = isFolder(own.repo) ? await git(["rev-parse", "--path-format=absolute", "--git-common-dir"], own.repo).then((out) => out.trim()) : undefined;
			return await inRepo(common ?? own.repo, () => removeInRepo(id, options, common));
		} finally {
			changing.delete(id);
			removingPaths.delete(own.path);
			removalGeneration++;
			forgetKept();
			void refresh();
		}
	}

	async function removeInRepo(id: number, options: RemoveOptions, common: string | undefined) {
		const own = mine[String(id)]!;
		if (engine.busy(id)) throw new Error("The agent is working in this worktree. Stop it first");
		// A set-up still running would go on writing into the folder being removed, and so would a command the agent
		// left running in the background there.
		const stopSetup = async () => {
			const setup = setups.get(id);
			setup?.stop("was stopped because the worktree was removed");
			await Promise.all([setup?.settled, stopCommandsIn(own.path, "was stopped because its worktree was removed")]);
		};
		// Sub-chats working in the worktree go back with the conversation, so continuing one does not run in a folder that is gone.
		const joined: number[] = [];
		for (const [key, meta] of Object.entries(engine.library().conversations)) {
			if (meta.parent !== id || mine[key] !== undefined) continue;
			folders.delete(Number(key));
			const cwd = await folderOf(Number(key));
			if (cwd !== null && within(cwd, own.path)) {
				if (engine.busy(Number(key))) throw new Error("A sub-chat is working in this worktree. Stop it first");
				joined.push(Number(key));
			}
		}
		await stopSetup();
		const repoRoot = common === undefined ? undefined : own.repo;
		const checkoutId = directoryId(own.path);
		if (!within(dirname(own.path), join(engine.home, "worktrees"))) throw new Error("The recorded path is outside pi²'s worktree folder. Check it by hand; pi² left it alone");
		let branch: string | null = own.removal?.branch ?? own.branch;
		if (checkoutId === null && own.removal !== undefined) {
			await finishRemoval(id, own, own.removal, common, options.onlyIfMerged === true);
		} else if (checkoutId !== null) {
			const repo = await repoOf(own.path);
			if ((own.checkoutId !== undefined && own.checkoutId !== checkoutId) || common === undefined || repo === undefined || !repo.worktree || realish(repo.root) !== realish(own.path) || realish(repo.commonDir) !== realish(common) || !lstatSync(join(own.path, ".git"), { throwIfNoEntry: false })?.isFile()) {
				throw new Error("pi² cannot verify this folder is still its checkout or that removal had passed its checks. Check it by hand; pi² left it alone");
			}
			if (own.removal !== undefined) {
				// The move never took place. Do not let the old check authorize a new removal.
				const holding = directoryId(own.removal.holding);
				if (checkoutId !== own.removal.checkoutId || own.removal.deleting || (holding !== null && holding !== own.removal.holdingId) || directoryId(join(own.removal.holding, "checkout")) !== null) {
					throw new Error("The worktree path changed during removal. Check it by hand; pi² left it alone");
				}
				if (holding !== null) await rmdir(own.removal.holding);
				await save((doc) => void delete doc[String(id)]!.removal);
			}
			const info = await inspectCheckout(own.path, own, true);
			if (info === undefined || info.state === "unavailable") throw new Error("git could not read the worktree's status. Check git status and retry");
			branch = info.branch;
			if (options.onlyIfMerged) {
				const why = whyKeepWorktree(info);
				if (why !== undefined) throw new Error(`pi² kept it because ${why}. Check it before retrying`);
			}
			if (options.force) {
				// Explicit discard is not a proof that nothing would be lost; never recover it by recursive deletion.
				await worktreeGit(["remove", "--force", "--", own.path], own.repo).catch((error: Error) => {
					throw new Error(`git could not remove the worktree: ${error.message}. Check it in Branches before retrying`);
				});
			} else {
				const changes = info.changes + info.conflicts;
				if (changes > 0) throw new Error(`The worktree has ${changes} uncommitted change${changes === 1 ? "" : "s"}. Commit them, or remove it anyway to lose them`);
				if (info.operation !== null || branch === null) throw new Error("Finish the git operation or put the detached commit on a branch, then retry");
				const gitDir = realpathSync(repo.gitDir);
				const gitDirId = directoryId(gitDir);
				if (gitDirId === null || dirname(gitDir) !== join(realish(common), "worktrees")) throw new Error("pi² cannot verify the worktree registration. Check it by hand");
				const entry = (await registrations(own.repo)).find((entry) => realish(entry.path) === realish(own.path));
				if (entry === undefined || !entry.fields.includes(`branch refs/heads/${branch}`)) throw new Error("The worktree registration changed. Check it by hand, then retry");
				if (entry.fields.some((field) => field === "locked" || field.startsWith("locked "))) throw new Error("Git has locked this worktree. Unlock it before retrying");
				const holding = mkdtempSync(join(realpathSync(dirname(own.path)), ".removing-"));
				const record = { holding, holdingId: directoryId(holding)!, checkoutId, gitDir, gitDirId, branch, ...(info.base !== null && info.unmerged === 0 ? { base: info.base } : {}) };
				await save((doc) => { doc[String(id)]!.removal = record; });
				try {
					// Git checks locks, submodules and the linked checkout before moving it. Agents only know the old
					// path, so they cannot use a partly deleted checkout if the slow deletion is interrupted.
					await worktreeGit(["move", "--", own.path, join(holding, "checkout")], own.repo);
				} catch (error) {
					throw new Error(`git could not move the worktree for removal: ${(error as Error).message}. Check it in Branches or retry removal`);
				}
				await finishRemoval(id, own, record, common, options.onlyIfMerged === true);
			}
		} else if (repoRoot !== undefined) {
			// Its folder was deleted by hand. Forget just this checkout, not other missing checkouts.
			await forgetCheckout(repoRoot, own.path);
		}
		let branchDeleted = false;
		let note: string | null = null;
		if (options.deleteBranch && repoRoot !== undefined && branch !== null) {
			const deleted = await git(["branch", options.force ? "-D" : "-d", branch], repoRoot).then(
				() => true,
				() => false,
			);
			branchDeleted = deleted;
			if (!deleted) note = `The branch ${branch} was kept: it has commits that are not merged yet.`;
		}
		const back = isFolder(own.origin) ? own.origin : repoRoot;
		await save((doc) => void delete doc[String(id)]);
		if (back !== undefined) for (const each of [id, ...joined]) await setFolder(each, back);
		engine.log("worktree removed for conversation", id);
		return { branchDeleted, note, branch };
	}

	async function finishRemoval(id: number, own: Worktree, record: NonNullable<Worktree["removal"]>, common: string | undefined, onlyIfMerged: boolean): Promise<void> {
		const { holding, holdingId, checkoutId, gitDir, gitDirId } = record;
		const checkout = join(holding, "checkout");
		try {
			if (common === undefined || dirname(gitDir) !== join(realish(common), "worktrees") || dirname(holding) !== realpathSync(dirname(own.path)) || !basename(holding).startsWith(".removing-") || directoryId(own.path) !== null) {
				throw new Error("pi² cannot verify the recorded removal");
			}
			const parent = directoryId(holding);
			const files = directoryId(checkout);
			const admin = directoryId(gitDir);
			if ((parent !== null && parent !== holdingId) || (files !== null && files !== checkoutId) || (admin !== null && admin !== gitDirId)) throw new Error("A folder in the recorded removal was replaced");
			const entries = (await registrations(own.repo)).filter((entry) => {
				const path = canonicalPath(entry.path);
				return path === canonicalPath(own.path) || path === checkout;
			});
			if (entries.length > 1 || (entries.length === 1 && (admin === null || !entries[0]!.fields.includes(`branch refs/heads/${record.branch}`))) || existsSync(join(gitDir, "locked"))) {
				throw new Error("The worktree registration changed or is locked");
			}
			if (onlyIfMerged && record.base === undefined) throw new Error("The recorded removal did not confirm the branch was merged. Use Branches to finish it and keep the branch");
			if (files !== null && !record.deleting) {
				if (admin === null || entries.length !== 1) throw new Error("The checkout can no longer be verified");
				// Check once more once the old path is out of use. Explicit paths work even if Git moved the
				// checkout but was cut off before updating one of its links.
				const gitAt = ["--git-dir", gitDir, "--work-tree", checkout];
				const status = parseStatus(await git([...gitAt, ...statusArgs], checkout, WORKTREE_TIMEOUT_MS));
				if (status.oid === null || status.head !== record.branch || status.changes + status.conflicts > 0 || operationIn(gitDir) !== null) {
					throw new Error("The isolated checkout changed. Its files were kept");
				}
				if (onlyIfMerged && (record.base === undefined || (await git([...gitAt, "rev-list", "--count", `${record.base}..${status.oid}`], checkout)).trim() !== "0")) {
					throw new Error("The branch is not confirmed merged. Fetch first if it merged elsewhere, or keep its branch using Branches");
				}
				await save((doc) => { doc[String(id)]!.removal!.deleting = true; });
			}
			// The slow part has no deadline. The recorded, isolated directory can be retried even if there
			// is no .git file left, without touching anything at the original path.
			if (files !== null) await rm(checkout, { force: true, recursive: true, maxRetries: 3 });
			if (entries[0] !== undefined) await forgetCheckout(own.repo, entries[0].path, entries);
			if (directoryId(gitDir) === gitDirId && !existsSync(join(gitDir, "gitdir"))) {
				// Git may have been cut off while deleting this exact registration, after unlinking its backlink.
				await rm(gitDir, { force: true, recursive: true, maxRetries: 3 });
			}
			if (directoryId(gitDir) !== null) throw new Error("Some of the Git registration is still present");
			if (parent !== null) await rmdir(holding);
		} catch (error) {
			const reason = error instanceof GitError ? error.message : (error as NodeJS.ErrnoException).code ?? (error as Error).message;
			throw new Error(`Could not finish removing the worktree: ${reason}. Retry removal in Branches or inspect ${holding}`);
		}
	}

	const guide = (own: Worktree, cwd: string | null, shared: boolean) =>
		[
			`${shared ? "This sub-chat works in the git worktree of the conversation that handed it this task" : "This conversation works in a git worktree of its own"}: ${cwd ?? own.path}, on the branch ${own.branch}${own.base ? `, made from ${own.base}` : ""}.`,
			// A conversation with a worktree of its own may go on to a new branch once its first is merged, so that an agent
			// given several pieces of work in turn can make a pull request of each (#206): the tracker, sub_chats and
			// removing the worktree all go by the branch it is on now. A sub-chat sharing its parent's worktree may not.
			shared
				? `Other agents may be working in other worktrees of the same repository at the same time, so keep to this folder: commit your work to ${own.branch}, do not check out another branch here, and do not change the main checkout at ${own.repo}.`
				: `Other agents may be working in other worktrees of the same repository at the same time, so keep to this folder: commit your work to its branch, do not check out a branch another worktree has, and do not change the main checkout at ${own.repo}. Once ${own.branch} is merged, you may start a new branch here from ${own.base ?? "the default branch"} for your next piece of work.`,
			// One agent's `git stash pop` applied another's stash: the list is the repository's, not the worktree's (#242).
			"Do not use `git stash`: every worktree of the repository shares its stashes.",
			"Files git ignores (installed packages, build output, local settings) are not copied into a new worktree; set them up here if the work needs them.",
			...setupNote(own.setup),
		].join(" ");

	/** What the agent is told about the set-up command that ran in its worktree. */
	function setupNote(setup: Setup | undefined): string[] {
		if (setup === undefined || setup.status === "running") return [];
		const ran = `When pi² made this worktree it ran the set-up command the person gave this agent, in the worktree's top folder: \`${setup.command}\`.`;
		if (setup.status === "done") return [`${ran} It finished without errors.`];
		const output = (setup.output ?? "").trim();
		const fence = "`".repeat(Math.max(3, ...[...output.matchAll(/`+/g)].map((run) => run[0].length + 1)));
		return [
			`${ran} It ${setup.reason ?? "failed"}, so what it sets up may be missing or incomplete; the person can see this in the conversation too.`,
			...(output === "" ? [] : [`The end of its output:\n${fence}\n${output}\n${fence}`]),
		];
	}

	let timer: ReturnType<typeof setInterval> | undefined;
	made = { create, remove };

	return {
		sections: [
			section("worktree", async (input, context) => {
				// A sub-chat is told about the worktree of the conversation that handed it work, when it works there too.
				const parent = engine.library().conversations[String(input.conversationId)]?.parent;
				const shared = mine[String(input.conversationId)] === undefined && parent !== undefined;
				const owner = shared && parent !== undefined ? parent : Number(input.conversationId);
				const before = mine[String(owner)];
				if (before === undefined) return undefined;
				const cwd = ((await input.read.snapshot(AgentDoc, input.conversationId, context)) as { cwd?: string | null } | undefined)?.cwd ?? null;
				// Only while the conversation is still in the worktree.
				if (cwd === null || !within(cwd, before.path)) return undefined;
				// A message sent while the set-up command runs waits for it, so the agent starts in a worktree that is ready
				// and is told how the set-up went; a sub-chat working there waits too. Stopping the run stops the wait, not
				// the set-up.
				const setup = setups.get(owner);
				if (setup !== undefined) await awaitWithContext(setup.settled, context);
				// Read again: the record changes when the set-up ends, and is gone if the worktree was removed meanwhile.
				const own = mine[String(owner)];
				if (own === undefined) return undefined;
				return guide(own, cwd, shared);
			}),
		],
		start: async () => {
			mine = JSON.parse(JSON.stringify((await engine.harness().snapshot(Worktrees, engine.context()))?.conversations ?? {}));
			// A set-up that was running when the last engine stopped will not finish: say so where it was started. An engine
			// that died outright (SIGKILL, a crash) did not stop it, so it may still be running: stop what is provably part of
			// it, and leave anything else alone and say so.
			for (const [key, own] of Object.entries(mine)) {
				if (own.setup?.status !== "running") continue;
				const { process: left, ...was } = own.setup;
				const found: LeftOver = left === undefined ? "gone" : await stopLeftOver(left).catch(() => "unsure" as const);
				if (left !== undefined) engine.log("set-up left by the last engine for conversation", key, leftOverLog[found]);
				const reason =
					found === "stopped"
						? "was left running when pi²’s engine stopped, and was stopped when the engine started again"
						: found === "partly"
							? `was left running when pi²’s engine stopped. What pi² could tell it had started was stopped when the engine started again; something else in its process group (${left?.group}) may still be running, and was left alone because pi² could not be sure it belongs to this set-up`
							: found === "unsure"
								? `was cut off when pi²’s engine stopped. Something it started may still be running (process group ${left?.group}), and was left alone because pi² could not be sure it belongs to this set-up`
								: "was cut off when pi²’s engine stopped";
				const library = engine.library().conversations;
				const root = library[key]?.parent ?? Number(key);
				cutOff.push({
					conversationId: Number(key),
					rootConversationId: root,
					title: library[String(root)]?.title ?? "",
					command: was.command,
					outcome: found,
					group: signallable(left?.group) ? left.group : null,
				});
				const setup: Setup = { ...was, status: "failed", reason };
				await recordSetup(Number(key), setup);
				await noteSetup(Number(key), setup);
			}
			// Stopping the engine stops the set-ups it started, which would otherwise carry on alone.
			process.once("exit", () => {
				for (const setup of setups.values()) signalGroup(setup.child, "SIGKILL");
			});
			timer = setInterval(() => {
				// Nobody to tell: wait for an app to connect. A look still under way is enough: the next tick comes soon.
				if (engine.apps() > 0 && looking === undefined) void refresh();
			}, POLL_MS);
			timer.unref?.();
			void refresh();
		},
		recovery: () => ({ setups: cutOff }),
		greeting: () => [event()],
		// A set-up command running in the conversation's worktree, with the end of what it has printed so far.
		state: (view) => {
			const running = setups.get(view.conversation.id as unknown as number);
			return { setup: running === undefined ? null : { run: running.run, output: tail(running.output(), SETUP_KEEP_CHARS) } };
		},
		folderChanged: (id) => {
			forgetKept();
			folders.delete(id);
			void refresh();
		},
		created: async (id, agent: AgentProfile) => {
			if (agent.worktree !== true || agent.cwd === null) return;
			try {
				await create(id);
			} catch (error) {
				// The conversation still works, in the agent's own folder; the tracker shows where.
				engine.log("could not make a worktree for conversation", id, error instanceof Error ? error.message : error);
			}
		},
		handlers: {
			"worktree.create": async (params) => {
				if (typeof params.id !== "number") throw new Error(`Unknown conversation: ${String(params.id)}`);
				if (params.branch !== undefined && typeof params.branch !== "string") throw new Error("branch must be text");
				return await create(params.id, params.branch as string | undefined);
			},
			"worktree.remove": async (params) => {
				if (typeof params.id !== "number") throw new Error(`Unknown conversation: ${String(params.id)}`);
				return await remove(params.id, { force: params.force === true, deleteBranch: params.deleteBranch === true });
			},
			/** What the app suggests when it asks for a branch name. */
			"worktree.suggest": async (params) => {
				if (typeof params.id !== "number") throw new Error(`Unknown conversation: ${String(params.id)}`);
				const meta = engine.library().conversations[String(params.id)];
				return { branch: suggestBranch(meta?.title ?? "", `${meta?.agentId ?? "conversation"}-${params.id}`) };
			},
			"branches.refresh": async () => {
				folders.clear();
				await refresh();
				return {};
			},
		},
	};
};

/**
 * Every worktree pi² made and still has a record of (its conversation's, whether listed, archived or deleted): its folder
 * and its repository's main checkout. Command rules follow these (rules.ts, `ruleFolder`).
 */
export async function madeWorktrees(read: DocumentReader, context: Context): Promise<MadeWorktree[]> {
	const doc = await read.snapshot(Worktrees, context);
	return Object.values(doc?.conversations ?? {}).map(({ path, repo }) => ({ path, repo }));
}

/** The worktrees feature's own ways to make and remove a worktree, for the rest of the engine; set once it is made. */
let made: { create(id: number, branch?: string, from?: string): Promise<{ path: string; branch: string }>; remove(id: number, options: RemoveOptions): Promise<RemovalResult> } | undefined;

/**
 * Make a worktree for conversation `id` and move it there, exactly as New Worktree… does: the same folder, record, set-up
 * command and tracking. Throws with the reason when it cannot.
 */
export function makeWorktree(id: number, branch: string | undefined, from: string | undefined): Promise<{ path: string; branch: string }> {
	if (made === undefined) throw new Error("Worktrees are not available");
	return made.create(id, branch, from);
}

/** Remove conversation `id`'s worktree with the rules Remove Worktree… has: refused with uncommitted changes unless forced. */
export function removeWorktree(id: number, options: RemoveOptions): Promise<RemovalResult> {
	if (made === undefined) throw new Error("Worktrees are not available");
	return made.remove(id, options);
}

/** The worktree pi² made for conversation `id`, if it has one of its own. */
export async function worktreeOf(read: DocumentReader, id: number, context: Context): Promise<Worktree | undefined> {
	const doc = await read.snapshot(Worktrees, context);
	return doc?.conversations[String(id)];
}

/** Whether `folder` is in a git repository, for checking an agent's settings. */
export async function inRepository(folder: string): Promise<boolean> {
	return (await repoOf(folder)) !== undefined;
}

