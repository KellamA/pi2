// Worktrees and the branch tracker: reading git's state, and the engine making and removing a worktree for a
// conversation, over its socket, on a throwaway data folder and throwaway repositories.

import assert from "node:assert/strict";
import { type ChildProcess, execFileSync, spawn } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { connect, type Socket } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";
import { inspect, parseStatus, suggestBranch } from "../src/worktrees.ts";

// Commits made here and by the engine's shell use a fixed identity and none of the person's own git settings.
process.env.GIT_CONFIG_GLOBAL = "/dev/null";
process.env.GIT_CONFIG_NOSYSTEM = "1";
Object.assign(process.env, { GIT_AUTHOR_NAME: "Test", GIT_AUTHOR_EMAIL: "test@example.invalid", GIT_COMMITTER_NAME: "Test", GIT_COMMITTER_EMAIL: "test@example.invalid" });

const home = mkdtempSync(join(tmpdir(), "pi2-wt-"));
const scratch = realpathSync(mkdtempSync(join(tmpdir(), "pi2-wt-repos-")));
const socketPath = join(home, "engine.sock");
const main = join(import.meta.dirname, "..", "src", "main.ts");
// The demo model types slowly for people; every engine this test starts makes it fast.
process.env.PI2_DEMO_TOKENS_PER_SECOND ??= "1000";
// An engine a test starts keeps the PATH the test gave it, and reads nobody's shell profile (src/shellpath.ts).
process.env.PI2_LOGIN_SHELL ??= "off";

const run = (cwd: string, ...args: string[]) => execFileSync("git", args, { cwd, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();
function repo(name: string): string {
	const dir = join(scratch, name);
	mkdirSync(join(dir, "sub"), { recursive: true });
	run(dir, "init", "-q", "-b", "main");
	writeFileSync(join(dir, "README.md"), "hello\n");
	writeFileSync(join(dir, "sub", "notes.txt"), "notes\n");
	run(dir, "add", ".");
	run(dir, "commit", "-q", "-m", "first");
	return dir;
}
function step(name: string): void {
	console.log(`ok  ${name}`);
}

// ---- Reading git's state, without the engine

const sample = ["# branch.oid 0123456789abcdef", "# branch.head feature", "# branch.upstream origin/feature", "# branch.ab +2 -1", "1 .M N... 100644 100644 100644 a b file.txt", "? new.txt", "u UU N... 1 2 3 4 a b c conflict.txt"].join("\n");
assert.deepEqual(parseStatus(sample), { oid: "0123456789abcdef", head: "feature", upstream: "origin/feature", ahead: 2, behind: 1, changes: 2, conflicts: 1 });
assert.equal(parseStatus("# branch.oid (initial)\n# branch.head (detached)").head, null);
assert.equal(suggestBranch("Fix the login page!", "x"), "pi2/fix-the-login-page");
assert.equal(suggestBranch("", "forge-3"), "pi2/forge-3");
step("git status and branch names are read as expected");

const plain = repo("plain");
assert.equal(await inspect(scratch), undefined, "a folder outside any repository has no branch");
let info = (await inspect(join(plain, "sub")))!;
assert.equal(info.branch, "main");
assert.equal(info.root, plain);
assert.equal(info.worktree, false);
assert.equal(info.state, "clean");
writeFileSync(join(plain, "README.md"), "changed\n");
info = (await inspect(plain))!;
assert.equal(info.state, "changes");
assert.equal(info.changes, 1);
run(plain, "commit", "-q", "-am", "second");
run(plain, "checkout", "-q", "-b", "topic");
writeFileSync(join(plain, "README.md"), "topic\n");
run(plain, "commit", "-q", "-am", "topic");
info = (await inspect(plain))!;
assert.equal(info.base, "main");
assert.equal(info.unmerged, 1);
assert.equal(info.state, "ahead", "a branch with commits not on the default branch, and no upstream, is ahead");
run(plain, "checkout", "-q", "main");
writeFileSync(join(plain, "README.md"), "main\n");
run(plain, "commit", "-q", "-am", "main");
assert.throws(() => run(plain, "merge", "-q", "topic"));
info = (await inspect(plain))!;
assert.equal(info.state, "conflict");
assert.equal(info.operation, "merge");
assert.equal(info.conflicts, 1);
run(plain, "merge", "--abort");
run(plain, "checkout", "-q", "--detach");
assert.equal((await inspect(plain))!.state, "detached");
step("a folder's branch reads as clean, changed, ahead, in conflict or detached");

// ---- The engine: worktrees for conversations

type Event = Record<string, any>;
class Client {
	socket!: Socket;
	events: Record<string, Event> = {};
	conversations = new Map<number, Event>();
	#next = 1;
	#replies = new Map<number, { resolve: (v: any) => void; reject: (e: Error) => void }>();
	static async attach(): Promise<Client> {
		const client = new Client();
		for (let attempt = 0; ; attempt++) {
			try {
				if (!existsSync(socketPath)) throw new Error("no socket yet");
				client.socket = connect(socketPath);
				await new Promise<void>((resolve, reject) => client.socket.once("connect", resolve).once("error", reject));
				break;
			} catch (error) {
				if (attempt >= 200) throw error;
				await sleep(50);
			}
		}
		let buffer = "";
		client.socket.setEncoding("utf8").on("data", (chunk: string) => {
			buffer += chunk;
			const lines = buffer.split("\n");
			buffer = lines.pop()!;
			for (const line of lines) {
				const message = JSON.parse(line);
				if (message.event === "conversation") {
					const conv = client.conversations.get(message.id) ?? { items: [] };
					if (message.reset) conv.items = [];
					conv.items.push(...message.items);
					conv.state = message.state;
					client.conversations.set(message.id, conv);
				} else if (typeof message.event === "string") client.events[message.event] = message;
				else if (message.id !== undefined && message.id !== null) {
					const reply = client.#replies.get(message.id);
					client.#replies.delete(message.id);
					if (message.error !== undefined) reply?.reject(new Error(message.error));
					else reply?.resolve(message.result);
				}
			}
		});
		return client;
	}
	call(method: string, params: Record<string, unknown> = {}): Promise<any> {
		const id = this.#next++;
		this.socket.write(`${JSON.stringify({ id, method, params })}\n`);
		return new Promise((resolve, reject) => this.#replies.set(id, { resolve, reject }));
	}
	async until<T>(what: string, check: () => T | undefined | false, timeoutMs = 30_000): Promise<T> {
		const deadline = Date.now() + timeoutMs;
		for (;;) {
			const value = check();
			if (value !== undefined && value !== false) return value;
			if (Date.now() > deadline) throw new Error(`Timed out waiting for: ${what}`);
			await sleep(100);
		}
	}
	branch(id: number): any {
		return this.events.branches?.conversations?.[String(id)];
	}
	/** Runs a shell command through the demo model and returns its output. */
	async bash(id: number, command: string): Promise<string> {
		const before = this.conversations.get(id)?.items.filter((i: Event) => i.kind === "tool").length ?? 0;
		await this.call("submit", { id, text: `/bash ${command}` });
		const conv = await this.until("command ran", () => {
			const c = this.conversations.get(id);
			return c !== undefined && !c.state.busy && c.items.filter((i: Event) => i.kind === "tool").length > before && c.items.at(-1).kind === "assistant" ? c : undefined;
		});
		return conv.items.filter((i: Event) => i.kind === "tool").at(-1).text;
	}
}

const project = repo("project");
let engine: ChildProcess = spawn(process.execPath, [main], { env: { ...process.env, PI2_HOME: home, PI2_KEYCHAIN_SERVICE: "dev.pi2.credentials.test-worktrees" }, stdio: ["ignore", "ignore", "inherit"] });
try {
	const client = await Client.attach();
	await client.until("agents", () => client.events.providers);

	const { id: a } = await client.call("conversation.create");
	await client.call("conversation.open", { id: a });
	await client.call("conversation.configure", { id: a, access: "full", cwd: join(project, "sub") });
	let seen = await client.until("branch of the main checkout", () => client.branch(a));
	assert.equal(seen.branch, "main");
	assert.equal(seen.worktree, false);
	assert.equal(seen.state, "clean");
	step("a conversation's folder is tracked: branch main, not a worktree, clean");

	await assert.rejects(client.call("worktree.create", { id: a, branch: "not a branch.." }), /cannot be a branch name/);
	const made = await client.call("worktree.create", { id: a });
	assert.match(made.branch, /^pi2\/[a-z]+-\d+$/);
	assert.ok(made.path.startsWith(join(home, "worktrees")), `the worktree lives in the data folder: ${made.path}`);
	assert.ok(made.path.endsWith("/sub"), "the conversation keeps working in the same subfolder");
	await client.until("conversation moved", () => client.conversations.get(a)?.state.agent.cwd === made.path);
	seen = await client.until("branch of the worktree", () => client.branch(a)?.worktree === true && client.branch(a));
	assert.equal(seen.branch, made.branch);
	assert.equal(seen.managed, true);
	assert.equal(seen.state, "clean");
	await assert.rejects(client.call("worktree.create", { id: a }), /already has a worktree/);
	step("make a worktree: a new branch, in the data folder, and the conversation moves into it");

	const output = await client.bash(a, "git branch --show-current && echo made-here > new.txt && pwd");
	assert.ok(output.includes(made.branch) && output.includes(made.path), `the agent works on the worktree's branch: ${output}`);
	assert.equal(existsSync(join(project, "sub", "new.txt")), false, "the main checkout is untouched");
	await client.until("changes seen", () => client.branch(a)?.state === "changes");
	await assert.rejects(client.call("worktree.remove", { id: a }), /uncommitted change/);
	await client.bash(a, "git add . && git commit -q -m 'from the agent'");
	seen = await client.until("ahead", () => client.branch(a)?.state === "ahead" && client.branch(a));
	assert.equal(seen.unmerged, 1);
	assert.equal(seen.base, "main");
	step("the agent's changes show as changes, then as a commit ahead of main; removing with changes is refused");

	// A second conversation works in the main checkout at the same time, on its own branch.
	const { id: b } = await client.call("conversation.create");
	await client.call("conversation.configure", { id: b, cwd: project });
	await client.until("second conversation tracked", () => client.branch(b)?.branch === "main");
	run(project, "merge", "-q", "--ff-only", made.branch);
	seen = await client.until("merged", () => client.branch(a)?.state === "merged" && client.branch(a));
	assert.equal(client.branch(b).worktree, false);
	step("merging the worktree's branch into main shows it as merged");

	const removed = await client.call("worktree.remove", { id: a, deleteBranch: true });
	assert.equal(removed.branchDeleted, true);
	assert.equal(existsSync(made.path), false, "the worktree's folder is gone");
	await client.until("back in the main checkout", () => client.conversations.get(a)?.state.agent.cwd === join(project, "sub"));
	await client.until("tracked there again", () => client.branch(a)?.worktree === false);
	assert.ok(!run(project, "branch").includes(made.branch), "the merged branch was deleted");
	assert.equal(readFileSync(join(project, "sub", "new.txt"), "utf8"), "made-here\n", "the work arrived through the merge");
	step("remove the worktree: its folder and merged branch go, and the conversation returns to where it was");

	// An agent whose conversations each get a worktree.
	await assert.rejects(client.call("agents.save", { agent: { name: "Builder", access: "full", cwd: scratch, worktree: true } }), /git repository/);
	const { id: builder } = await client.call("agents.save", { agent: { name: "Builder", access: "full", cwd: project, worktree: true } });
	const { id: c } = await client.call("conversation.create", { agentId: builder });
	const { id: d } = await client.call("conversation.create", { agentId: builder });
	await client.until("both in worktrees", () => client.branch(c)?.managed === true && client.branch(d)?.managed === true);
	assert.notEqual(client.branch(c).root, client.branch(d).root, "each conversation has its own checkout");
	assert.notEqual(client.branch(c).branch, client.branch(d).branch, "and its own branch");
	step("an agent set to use worktrees starts each conversation in a worktree of its own");

	// Its folder deleted by hand: shown as missing, and removing it tidies up.
	rmSync(client.branch(d).root, { recursive: true, force: true });
	await client.call("branches.refresh");
	await client.until("missing", () => client.branch(d)?.state === "missing");
	await client.call("worktree.remove", { id: d });
	await client.until("back in the agent's folder", () => client.branch(d)?.managed === false);
	assert.ok(!run(project, "worktree", "list").includes(`pi2/builder-${d}`), "git forgot the deleted worktree");
	step("a worktree deleted by hand shows as missing; removing it lets git forget it");

	// The worktree's record outlives a restart.
	engine.kill("SIGTERM");
	await new Promise((resolve) => engine.once("exit", resolve));
	engine = spawn(process.execPath, [main], { env: { ...process.env, PI2_HOME: home, PI2_KEYCHAIN_SERVICE: "dev.pi2.credentials.test-worktrees" }, stdio: ["ignore", "ignore", "inherit"] });
	const again = await Client.attach();
	await again.until("worktree remembered", () => again.branch(c)?.managed === true);
	step("after a restart the worktree is still known as the conversation's own");

	// Archived or deleted, its worktree stays on disk and is listed as left behind, where it can be removed.
	const behind = (id: number) => again.events.branches?.leftBehind?.find((w: Event) => w.id === id);
	await again.call("conversation.archive", { id: c });
	await again.call("branches.refresh");
	let left = await again.until("archived worktree left behind", () => behind(c));
	assert.equal(left.reason, "archived");
	assert.equal(left.status.managed, true);
	assert.equal(left.status.state, "clean");
	assert.equal(again.branch(c), undefined, "an archived conversation is not among the sidebar's branches");
	await again.call("conversation.unarchive", { id: c });
	await again.call("branches.refresh");
	await again.until("restored with its worktree", () => again.branch(c)?.managed === true && behind(c) === undefined);
	await again.call("conversation.delete", { id: c });
	await again.call("branches.refresh");
	left = await again.until("deleted worktree left behind", () => behind(c)?.reason === "deleted" && behind(c));
	assert.ok(existsSync(left.status.root), "deleting the conversation leaves its worktree on disk");
	await again.call("worktree.remove", { id: c });
	await again.until("no longer left behind", () => behind(c) === undefined);
	assert.equal(existsSync(left.status.root), false, "removing it deletes the worktree's folder");
	assert.ok(run(project, "branch").includes(left.status.branch), "and keeps its branch");
	step("an archived or deleted conversation's worktree is listed as left behind, and can be removed");
	console.log("PASS");
} finally {
	engine.kill("SIGTERM");
	await sleep(300);
	rmSync(home, { recursive: true, force: true });
	rmSync(scratch, { recursive: true, force: true });
}
process.exit(0);
