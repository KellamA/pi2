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

import { type ChildProcess, execFile, spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, realpathSync, statSync } from "node:fs";
import { basename, dirname, join, relative, sep } from "node:path";
import { awaitWithContext } from "@earendil-works/chord/context";
import type { ConversationId } from "@earendil-works/pi-durable";
import { AgentDoc, defineDoc, section } from "@earendil-works/pi-durable";
import type { Feature } from "./features.ts";
import type { AgentProfile } from "./state.ts";

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

/** What the app is sent for a set-up entry: one line for anything that shows only text, and the rest as details. */
export function setupItem(id: number, data: unknown) {
	const setup = (data !== null && typeof data === "object" ? data : {}) as Partial<Setup>;
	const command = typeof setup.command === "string" ? setup.command : "";
	const status = setup.status === "done" || setup.status === "failed" ? setup.status : "running";
	const reason = typeof setup.reason === "string" ? setup.reason : "failed";
	const text = status === "running" ? `Running the set-up command: ${command}` : status === "done" ? `The set-up command finished: ${command}` : `The set-up command ${reason}: ${command}`;
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
export type BranchState = "missing" | "conflict" | "changes" | "detached" | "merged" | "ahead" | "behind" | "clean";

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
const GIT_TIMEOUT_MS = 10_000;

export class GitError extends Error {}

/** Runs git without touching the index lock (so it never gets in an agent's way) and without ever asking for input. */
export function git(args: string[], cwd: string): Promise<string> {
	return new Promise((resolve, reject) => {
		execFile(
			"git",
			args,
			{
				cwd,
				timeout: GIT_TIMEOUT_MS,
				maxBuffer: 8 * 1024 * 1024,
				env: { ...process.env, GIT_OPTIONAL_LOCKS: "0", GIT_TERMINAL_PROMPT: "0", LC_ALL: "C" },
			},
			(error, stdout, stderr) => {
				if (error) {
					const message = String(stderr).trim().split("\n").filter((line) => line.trim() !== "").pop() ?? error.message;
					reject(Object.assign(new GitError(message.replace(/^(fatal|error): /, "")), { code: (error as { code?: unknown }).code }));
				} else resolve(String(stdout));
			},
		);
	});
}

const tryGit = (args: string[], cwd: string) => git(args, cwd).then((out) => out.trim(), () => undefined);

type Repo = { root: string; gitDir: string; commonDir: string; main: string; worktree: boolean };

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

/** The repository's default branch: what origin/HEAD points at, else a local main or master. */
async function defaultBranch(root: string): Promise<string | null> {
	const remote = await tryGit(["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"], root);
	if (remote) return remote;
	for (const name of ["main", "master"]) {
		if ((await tryGit(["rev-parse", "--verify", "--quiet", `refs/heads/${name}`], root)) !== undefined) return name;
	}
	return null;
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

/** How the folder's branch stands, or undefined when the folder is not in a git repository. */
export async function inspect(folder: string, own?: Worktree): Promise<BranchInfo | undefined> {
	if (own !== undefined && !isFolder(own.path)) {
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
			state: "missing",
		};
	}
	const repo = await repoOf(folder);
	if (repo === undefined) return undefined;
	const out = await tryGit(["status", "--porcelain=v2", "--branch", "--untracked-files=normal", "--ignore-submodules=dirty"], repo.root);
	if (out === undefined) return undefined;
	const status = parseStatus(out);
	const operation = ["MERGE_HEAD", "rebase-merge", "rebase-apply", "CHERRY_PICK_HEAD", "REVERT_HEAD"]
		.map((name) => (existsSync(join(repo.gitDir, name)) ? name : undefined))
		.find((name) => name !== undefined);
	const managed = own !== undefined && realish(own.path) === realish(repo.root);
	// Measured against the branch the worktree was made from, else the default branch, unless this is that branch.
	let base = managed && own.base !== null ? own.base : await defaultBranch(repo.root);
	if (base !== null && status.head !== null && (base === status.head || base === `origin/${status.head}`)) base = null;
	let unmerged: number | null = null;
	let merged = false;
	if (base !== null && status.oid !== null) {
		const counted = await tryGit(["rev-list", "--count", `${base}..HEAD`], repo.root);
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
		operation: operation === undefined ? null : ({ MERGE_HEAD: "merge", "rebase-merge": "rebase", "rebase-apply": "rebase", CHERRY_PICK_HEAD: "cherry-pick", REVERT_HEAD: "revert" } as Record<string, string>)[operation]!,
	};
	return { ...info, state: stateOf(info, { merged }) };
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
	let ticking = false;
	let gitMissing = false;
	/** Conversations whose worktree is being made or removed right now. */
	const changing = new Set<number>();
	/** Set-up commands running now, by conversation. `settled` resolves once their end is recorded and written. */
	const setups = new Map<number, { child: ChildProcess; stop(reason: string): void; settled: Promise<void> }>();

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

	async function refresh(): Promise<void> {
		if (ticking || gitMissing) return;
		ticking = true;
		try {
			const ids = listed();
			for (const id of folders.keys()) if (!ids.includes(id)) folders.delete(id);
			const byFolder = new Map<string, Promise<BranchInfo | undefined>>();
			const next: Record<string, BranchInfo> = {};
			for (const id of ids) {
				const cwd = await folderOf(id);
				if (cwd === null) continue;
				const own = mine[String(id)];
				// Two conversations in the same folder share one look at it, unless one of them owns the worktree.
				const key = own === undefined ? cwd : `${cwd}\u0000${id}`;
				if (!byFolder.has(key)) byFolder.set(key, inspect(cwd, own));
				const info = await byFolder.get(key)!;
				if (info !== undefined) next[String(id)] = info;
			}
			// Worktrees of conversations put away: still on disk until the person removes them.
			const behind: LeftBehind[] = [];
			for (const [key, own] of Object.entries(mine)) {
				const reason = away(key);
				if (reason === undefined) continue;
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
		} finally {
			ticking = false;
		}
	}

	async function setFolder(id: number, cwd: string): Promise<void> {
		const conv = await engine.harness().conversation(id as unknown as ConversationId, engine.context());
		if (conv === undefined) throw new Error(`Unknown conversation: ${id}`);
		await conv.configure({ cwd }, engine.context());
		folders.set(id, { cwd, at: Date.now() });
	}

	/** Write a set-up command's start or end into the conversation's transcript, where the person sees it. */
	async function noteSetup(id: number, setup: Setup): Promise<void> {
		try {
			const conv = await engine.harness().conversation(id as unknown as ConversationId, engine.context());
			await conv?.submit({ type: "write", entry: { kind: SETUP_ENTRY, data: JSON.parse(JSON.stringify(setup)) } }, engine.context());
		} catch (error) {
			engine.log("could not note the set-up of", id, error instanceof Error ? error.message : error);
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
	 * the person typed it, through bash, with the engine's environment, in a process group of its own so that stopping
	 * it stops whatever it started too.
	 */
	async function startSetup(id: number, root: string, command: string): Promise<void> {
		const run = `${id}-${Date.now()}`;
		const started = Date.now();
		await recordSetup(id, { run, command, status: "running" });
		await noteSetup(id, { run, command, status: "running" });
		let output = "";
		let stopped: string | undefined;
		let failedToStart: string | undefined;
		const child = spawn("/bin/bash", ["-c", command], { cwd: root, env: process.env, detached: true, stdio: ["ignore", "pipe", "pipe"] });
		const keep = (chunk: Buffer) => {
			output += chunk.toString("utf8");
			if (output.length > 2 * SETUP_KEEP_CHARS) output = output.slice(-SETUP_KEEP_CHARS);
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
		const settled = ended.then(async ({ code, signal }) => {
			clearTimeout(timer);
			child.stdout?.destroy();
			child.stderr?.destroy();
			const reason =
				failedToStart !== undefined ? `could not start: ${failedToStart}` : stopped !== undefined ? stopped : code !== 0 ? (code === null ? `was ended by ${signal ?? "a signal"}` : `exited with code ${code}`) : undefined;
			const setup: Setup = { run, command, status: reason === undefined ? "done" : "failed", ...(reason === undefined ? {} : { reason }), seconds: Math.round((Date.now() - started) / 1000), output: tail(output, SETUP_KEEP_CHARS) };
			engine.log("set-up for", id, reason === undefined ? "finished" : reason);
			await recordSetup(id, setup).catch((error) => engine.log("could not record the set-up of", id, error instanceof Error ? error.message : error));
			await noteSetup(id, setup);
			if (setups.get(id)?.child === child) setups.delete(id);
		});
		setups.set(id, { child, stop, settled });
	}

	/** Make a worktree for conversation `id` from the repository its folder is in, and move the conversation into it. */
	async function create(id: number, requested?: string): Promise<{ path: string; branch: string }> {
		if (mine[String(id)] !== undefined) throw new Error("This conversation already has a worktree of its own");
		if (changing.has(id)) throw new Error("A worktree is already being made for this conversation");
		folders.delete(id);
		const cwd = await folderOf(id);
		if (cwd === null) throw new Error("Choose a folder in a git repository for this conversation first");
		const repo = await repoOf(cwd);
		if (repo === undefined) throw new Error("This conversation's folder is not in a git repository");
		const start = await tryGit(["rev-parse", "--verify", "--quiet", "HEAD^{commit}"], repo.root);
		if (start === undefined || start === "") throw new Error("The repository has no commits yet, so there is nothing to make a worktree from");
		changing.add(id);
		try {
			const meta = engine.library().conversations[String(id)];
			let branch = requested?.trim() || suggestBranch(meta?.title ?? "", `${meta?.agentId ?? "conversation"}-${id}`);
			const checked = await git(["check-ref-format", "--branch", branch], repo.root).catch(() => undefined);
			if (checked === undefined) throw new Error(`“${branch}” cannot be a branch name`);
			branch = checked.trim();
			const exists = async (name: string) => (await tryGit(["rev-parse", "--verify", "--quiet", `refs/heads/${name}`], repo.root)) !== undefined;
			// A name the person chose that already exists is checked out as it is; a suggested one gets a number instead.
			const useExisting = requested !== undefined && requested.trim() !== "" && (await exists(branch));
			if (!useExisting) for (let n = 2, stem = branch; await exists(branch); n++) branch = `${stem}-${n}`;
			const current = await tryGit(["symbolic-ref", "--quiet", "--short", "HEAD"], repo.root);
			const parent = join(engine.home, "worktrees", `${basename(repo.main)}-${createHash("sha256").update(realish(repo.commonDir)).digest("hex").slice(0, 6)}`);
			mkdirSync(parent, { recursive: true });
			let path = join(parent, folderName(branch));
			for (let n = 2; existsSync(path); n++) path = join(parent, `${folderName(branch)}-${n}`);
			await git(useExisting ? ["worktree", "add", path, branch] : ["worktree", "add", "-b", branch, path, start], repo.root).catch((error: Error) => {
				throw new Error(`git could not make the worktree: ${error.message}`);
			});
			const baseCommit = (await tryGit(["rev-parse", "HEAD"], path)) ?? start;
			// The same subfolder of the new checkout, when the conversation worked in one.
			const inside = relative(realish(repo.root), realish(cwd));
			const target = inside !== "" && !inside.startsWith("..") && isFolder(join(path, inside)) ? join(path, inside) : path;
			await save((doc) => {
				doc[String(id)] = { path, branch, repo: repo.main, origin: cwd, base: current ?? null, baseCommit, createdAt: Date.now() };
			});
			await setFolder(id, target);
			engine.log("worktree made for", id, "on", branch);
			// The agent's set-up command, written for the agent's own repository, so run only in a worktree of that one.
			const agent = engine.agents()[meta?.agentId ?? ""];
			const command = agent?.setup?.trim() ?? "";
			const theirs = command === "" || agent?.cwd == null ? undefined : await repoOf(agent.cwd);
			if (theirs !== undefined && realish(theirs.commonDir) === realish(repo.commonDir)) {
				await startSetup(id, path, command).catch((error) => engine.log("could not start the set-up of", id, error instanceof Error ? error.message : error));
			}
			return { path: target, branch };
		} finally {
			changing.delete(id);
			void refresh();
		}
	}

	/** Remove conversation `id`'s worktree and move it back to the folder it worked in before. */
	async function remove(id: number, options: { force: boolean; deleteBranch: boolean }): Promise<{ branchDeleted: boolean; note: string | null }> {
		const own = mine[String(id)];
		if (own === undefined) throw new Error("This conversation has no worktree of its own");
		if (engine.busy(id)) throw new Error("The agent is working in this worktree. Stop it first");
		if (changing.has(id)) throw new Error("The worktree is already being changed");
		changing.add(id);
		try {
			// A set-up still running would go on writing into the folder being removed.
			const stopSetup = async () => {
				const setup = setups.get(id);
				setup?.stop("was stopped because the worktree was removed");
				await setup?.settled;
			};
			const repoRoot = isFolder(own.repo) ? own.repo : undefined;
			if (isFolder(own.path)) {
				if (!options.force) {
					const status = parseStatus((await tryGit(["status", "--porcelain=v2", "--branch"], own.path)) ?? "");
					if (status.changes > 0 || status.conflicts > 0) {
						throw new Error(`The worktree has ${status.changes + status.conflicts} uncommitted change${status.changes + status.conflicts === 1 ? "" : "s"}. Commit them, or remove it anyway to lose them`);
					}
				}
				await stopSetup();
				await git(["worktree", "remove", ...(options.force ? ["--force"] : []), own.path], repoRoot ?? own.path).catch((error: Error) => {
					throw new Error(`git could not remove the worktree: ${error.message}`);
				});
			} else {
				await stopSetup();
				// Its folder was deleted by hand: let git forget it too.
				if (repoRoot !== undefined) await tryGit(["worktree", "prune"], repoRoot);
			}
			let branchDeleted = false;
			let note: string | null = null;
			if (options.deleteBranch && repoRoot !== undefined) {
				const deleted = await git(["branch", options.force ? "-D" : "-d", own.branch], repoRoot).then(
					() => true,
					() => false,
				);
				branchDeleted = deleted;
				if (!deleted) note = `The branch ${own.branch} was kept: it has commits that are not merged yet.`;
			}
			const back = isFolder(own.origin) ? own.origin : repoRoot;
			await save((doc) => void delete doc[String(id)]);
			if (back !== undefined) await setFolder(id, back);
			engine.log("worktree removed for", id);
			return { branchDeleted, note };
		} finally {
			changing.delete(id);
			void refresh();
		}
	}

	const guide = (own: Worktree, cwd: string | null) =>
		[
			`This conversation works in a git worktree of its own: ${cwd ?? own.path}, on the branch ${own.branch}${own.base ? `, made from ${own.base}` : ""}.`,
			`Other agents may be working in other worktrees of the same repository at the same time, so keep to this folder: commit your work to ${own.branch}, do not check out another branch here, and do not change the main checkout at ${own.repo}.`,
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

	return {
		sections: [
			section("worktree", async (input, context) => {
				// A message sent while the set-up command runs waits for it, so the agent starts in a worktree that is ready
				// and is told how the set-up went. Stopping the run stops the wait, not the set-up.
				const setup = setups.get(Number(input.conversationId));
				if (setup !== undefined) await awaitWithContext(setup.settled, context);
				const own = mine[String(input.conversationId)];
				if (own === undefined) return undefined;
				const cwd = ((await input.read.snapshot(AgentDoc, input.conversationId, context)) as { cwd?: string | null } | undefined)?.cwd ?? null;
				// Only while the conversation is still in the worktree.
				if (cwd === null || !(realish(cwd) + sep).startsWith(realish(own.path) + sep)) return undefined;
				return guide(own, cwd);
			}),
		],
		start: async () => {
			mine = JSON.parse(JSON.stringify((await engine.harness().snapshot(Worktrees, engine.context()))?.conversations ?? {}));
			// A set-up that was running when the last engine stopped will not finish: say so where it was started.
			for (const [key, own] of Object.entries(mine)) {
				if (own.setup?.status !== "running") continue;
				const setup: Setup = { ...own.setup, status: "failed", reason: "was cut off when pi²’s engine stopped" };
				await recordSetup(Number(key), setup);
				await noteSetup(Number(key), setup);
			}
			// Stopping the engine stops the set-ups it started, which would otherwise carry on alone.
			process.once("exit", () => {
				for (const setup of setups.values()) signalGroup(setup.child, "SIGKILL");
			});
			timer = setInterval(() => {
				// Nobody to tell: wait for an app to connect.
				if (engine.apps() > 0) void refresh();
			}, POLL_MS);
			timer.unref?.();
			void refresh();
		},
		greeting: () => [event()],
		folderChanged: (id) => {
			folders.delete(id);
			void refresh();
		},
		created: async (id, agent: AgentProfile) => {
			if (agent.worktree !== true || agent.cwd === null) return;
			try {
				await create(id);
			} catch (error) {
				// The conversation still works, in the agent's own folder; the tracker shows where.
				engine.log("could not make a worktree for", id, error instanceof Error ? error.message : error);
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

/** Whether `folder` is in a git repository, for checking an agent's settings. */
export async function inRepository(folder: string): Promise<boolean> {
	return (await repoOf(folder)) !== undefined;
}

