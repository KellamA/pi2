// Worktrees and the branch tracker: reading git's state, and the engine making and removing a worktree for a
// conversation, over its socket, on a throwaway data folder and throwaway repositories.

import assert from "node:assert/strict";
import childProcess, { type ChildProcess, execFileSync, spawn, spawnSync, type StdioOptions } from "node:child_process";
import { chmodSync, closeSync, constants, existsSync, lstatSync, mkdirSync, mkdtempSync, openSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { syncBuiltinESMExports } from "node:module";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";
import { forgetRun, type NewRun, newRun, newRunMarker, RUN_VARIABLE, stopLeftOver, sweepRuns, useRunFolder } from "../src/processes.ts";
import { inspect, linesIn, parseShortstat, parseStatus, statusPaths, suggestBranch, unquotePath } from "../src/worktrees.ts";
import { EngineClient, PATIENT_MS, standInApp, stop, until } from "./patience.ts";

// Commits made here and by the engine's shell use a fixed identity and none of the person's own git settings.
process.env.GIT_CONFIG_GLOBAL = "/dev/null";
process.env.GIT_CONFIG_NOSYSTEM = "1";
Object.assign(process.env, { GIT_AUTHOR_NAME: "Test", GIT_AUTHOR_EMAIL: "test@example.invalid", GIT_COMMITTER_NAME: "Test", GIT_COMMITTER_EMAIL: "test@example.invalid" });

const home = mkdtempSync(join(tmpdir(), "pi2-wt-"));
const scratch = realpathSync(mkdtempSync(join(tmpdir(), "pi2-wt-repos-")));
const main = join(import.meta.dirname, "..", "src", "main.ts");
// The demo model types slowly for people; every engine this test starts makes it fast.
process.env.PI2_DEMO_TOKENS_PER_SECOND ??= "1000";
// An engine a test starts keeps the PATH the test gave it, and reads nobody's shell profile (src/shellpath.ts).
process.env.PI2_LOGIN_SHELL ??= "off";
// This client answers approvals as the app does (#504).
process.env.PI2_APP_BUNDLE = standInApp();

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

{
	// The size of the change (#598): lines added and removed beyond where the branch left its base, plus what is not
	// committed, new files included.
	assert.deepEqual(parseShortstat(" 3 files changed, 128 insertions(+), 14 deletions(-)"), { added: 128, removed: 14 });
	assert.deepEqual(parseShortstat(" 1 file changed, 1 deletion(-)"), { added: 0, removed: 1 });
	assert.deepEqual(parseShortstat(""), { added: 0, removed: 0 });
	assert.equal(unquotePath('"caf\\303\\251 \\"x\\".txt"'), 'café "x".txt');
	assert.deepEqual(statusPaths(["# branch.oid 0123", "1 .M N... 100644 100644 100644 a b with space.txt", "2 R. N... 100644 100644 100644 a b R100 new name.txt\told.txt", "u UU N... 1 2 3 4 a b c both.txt", "? fresh/", '? "tab\\there"'].join("\n")), {
		changed: ["with space.txt", "new name.txt", "old.txt", "both.txt"],
		untracked: ["fresh/", "tab\there"],
	});
	assert.equal(linesIn(Buffer.from("a\nb\nc")), 3, "a last line without a newline counts");
	assert.equal(linesIn(Buffer.from("a\0b\n")), 0, "a binary file has no lines");

	const sized = repo("sized");
	writeFileSync(join(sized, ".gitignore"), "*.log\n");
	run(sized, "add", ".gitignore");
	run(sized, "commit", "-q", "-m", "ignore logs");
	let size = (await inspect(sized))!;
	assert.deepEqual([size.added, size.removed], [0, 0], "a clean checkout on its default branch has changed nothing");
	writeFileSync(join(sized, "README.md"), "hello\none\ntwo\n");
	writeFileSync(join(sized, "sub", "notes.txt"), "");
	writeFileSync(join(sized, "new.txt"), "1\n2\n3\n4\n5\n");
	mkdirSync(join(sized, "fresh", "deeper"), { recursive: true });
	writeFileSync(join(sized, "fresh", "deeper", "a.txt"), "x\ny");
	writeFileSync(join(sized, "fresh", "debug.log"), "ignored\n".repeat(50));
	writeFileSync(join(sized, "fresh", "picture.bin"), Buffer.from([1, 0, 2, 10, 3, 10]));
	size = (await inspect(sized))!;
	assert.deepEqual([size.added, size.removed], [2 + 5 + 2, 1], "on the default branch, only what is not committed counts: new files too, but not ignored or binary ones");
	writeFileSync(join(sized, "README.md"), "hello\none\ntwo\nthree\n");
	size = (await inspect(sized))!;
	assert.equal(size.added, 3 + 5 + 2, "a file changed again is measured again, though git status prints the same");
	writeFileSync(join(sized, "fresh", "deeper", "a.txt"), "x\ny\nz\n");
	size = (await inspect(sized))!;
	assert.equal(size.added, 3 + 5 + 3, "so is a new file inside a new folder");
	run(sized, "checkout", "-q", "-b", "topic");
	run(sized, "add", "README.md", "sub/notes.txt");
	run(sized, "commit", "-q", "-m", "topic");
	writeFileSync(join(sized, "README.md"), "hello\none\n");
	size = (await inspect(sized))!;
	assert.equal(size.base, "main");
	assert.deepEqual([size.added, size.removed], [1 + 5 + 3, 1], "on a branch, what is committed beyond its base counts with what is not committed yet");
	run(sized, "checkout", "-q", "--", "README.md");
	rmSync(join(sized, "new.txt"));
	rmSync(join(sized, "fresh"), { recursive: true });
	size = (await inspect(sized))!;
	assert.deepEqual([size.added, size.removed], [3, 1], "committed on the branch alone");
	run(sized, "checkout", "-q", "main");
	run(sized, "merge", "-q", "--ff-only", "topic");
	run(sized, "checkout", "-q", "topic");
	size = (await inspect(sized))!;
	assert.deepEqual([size.added, size.removed], [0, 0], "once merged into its base, a branch has changed nothing more");
	step("the size of a change counts lines committed beyond the base and not yet committed, and is measured again when the checkout changes");
}

// ---- The engine: worktrees for conversations

type Event = Record<string, any>;
class Client extends EngineClient {
	/** Every conversation a branches event listed both among the sidebar's branches and as left behind (#128). */
	both: number[] = [];
	override receive(message: any): void {
		super.receive(message);
		if (message.event === "branches") this.both.push(...(message.leftBehind as Event[]).filter((left) => message.conversations[String(left.id)] !== undefined).map((left) => left.id));
	}
	branch(id: number): any {
		return this.events.branches?.conversations?.[String(id)];
	}
	/** Runs a shell command through the demo model and returns its output. */
	async bash(id: number, command: string): Promise<string> {
		return (await this.tool(id, `/bash ${command}`)).text;
	}
	/** Sends a message the demo model answers with a tool call, and returns that call once the answer is in. */
	async tool(id: number, text: string): Promise<Event> {
		const before = this.conversations.get(id)?.items.filter((i: Event) => i.kind === "tool").length ?? 0;
		await this.call("submit", { id, text });
		const conv = await this.until("tool ran", () => {
			const c = this.conversations.get(id);
			return c !== undefined && !c.state.busy && c.items.filter((i: Event) => i.kind === "tool").length > before && c.items.at(-1).kind === "assistant" ? c : undefined;
		});
		return conv.items.filter((i: Event) => i.kind === "tool").at(-1);
	}
}

const project = repo("project");
// Count each engine git call without bypassing the interrupted-worktree cases below.
const gitCalls = join(scratch, "git-calls.tsv");
const gitBin = join(scratch, "bin");
mkdirSync(gitBin);
const realGit = execFileSync("/bin/sh", ["-c", "command -v git"], { encoding: "utf8" }).trim();
const quoted = (value: string) => `'${value.replaceAll("'", `'\\''`)}'`;
const moveMarker = join(scratch, "moved");
const endMove = join(scratch, "end-move");
writeFileSync(join(gitBin, "git"), `#!/bin/sh
set -eu
printf '%s\\t%s\\n' "$(/bin/pwd)" "$*" >> ${quoted(gitCalls)}
real=${quoted(realGit)}
if [ "\${1-}" = worktree ] && [ "\${2-}" = add ]; then
  case "\${6-}" in
    cut-off-new|cut-off-existing)
      "$real" worktree add --quiet --no-checkout -- "$5" "$6"
      echo partial > "$5/partial"
      printf 'Updating files: 18%% (50/275)\\rUpdating files: 19%% (51/275)\\r' >&2
      if [ "$6" = cut-off-existing ]; then
        echo 'fatal: a test checkout filter refused a file' >&2
        exit 1
      fi
      kill -KILL $$ ;;
  esac
fi
if [ "\${1-}" = worktree ] && [ "\${2-}" = move ]; then
  case "\${4-}" in
    */cut-off-move)
      "$real" "$@"
      printf '%s' "$5" > ${quoted(moveMarker)}
      while [ ! -e ${quoted(endMove)} ]; do sleep 0.1; done
      kill -KILL $$ ;;
  esac
fi
exec "$real" "$@"
`, { mode: 0o700 });

// Stand in for the filesystem deleting only the start of the isolated checkout, without racing a deadline.
const cutRm = join(scratch, "cut-rm.mjs");
writeFileSync(cutRm, `import fs from "node:fs/promises";
import { syncBuiltinESMExports } from "node:module";
import { join } from "node:path";
const rm = fs.rm;
fs.rm = async (path, options) => {
	if (typeof path === "string" && /\\/.removing-[^/]+\\/checkout$/.test(path) && (await fs.readFile(join(path, "ignored-cut-off"), "utf8").catch(() => "")).trim() === "interrupt") {
		await rm(join(path, ".git"));
		await rm(join(path, "README.md"));
		await fs.writeFile(join(path, "ignored-cut-off"), "left behind");
		throw Object.assign(new Error("interrupted removal"), { code: "EIO" });
	}
	return rm(path, options);
};
syncBuiltinESMExports();
`);
/** What the engines this test started have logged, line by line. Their log is passed on to the test's own as it comes. */
const logged: string[] = [];
const startEngine = (): ChildProcess => {
	const child = spawn(process.execPath, ["--import", cutRm, main], { env: { ...process.env, PATH: `${gitBin}:${process.env.PATH}`, PI2_HOME: home, PI2_KEYCHAIN_SERVICE: "dev.pi2.credentials.test-worktrees" }, stdio: ["ignore", "ignore", "pipe"] });
	let rest = "";
	child.stderr!.setEncoding("utf8").on("data", (chunk: string) => {
		process.stderr.write(chunk);
		const lines = (rest + chunk).split("\n");
		rest = lines.pop()!;
		logged.push(...lines);
	});
	return child;
};
/** Whether a process is still there (one that has ended but not yet been collected by its parent counts). */
const alive = (pid: number) => {
	try {
		process.kill(pid, 0);
		return true;
	} catch {
		return false;
	}
};
/** Commands' own `sleep`s that must outlive any wait of this test, so that only being stopped ends them; stopped at the end. */
const LONG_SLEEP = `sleep ${(2 * PATIENT_MS) / 1000}`;
/** The same for node: a program whose environment macOS lets another process read. */
const LONG_WAIT = `setTimeout(() => {}, ${2 * PATIENT_MS})`;
/** And of the other programs that come with macOS. */
const SH_SLEEP = `/bin/sh -c '${LONG_SLEEP}; :'`;
const PERL_SLEEP = `/usr/bin/perl -e 'sleep ${(2 * PATIENT_MS) / 1000}'`;
const sleepers: number[] = [];
const holders: number[] = [];
// A dead engine made a file but never recorded a process. Beside it a different, live engine (this test) owns a run
// whose command closed fd 19. Only the former may go, even though neither file is named in the new engine's records.
useRunFolder(join(home, "runs"));
const activeRun = newRun();
const leakedMarker = newRunMarker();
const leakedFile = join(home, "runs", leakedMarker);
closeSync(openSync(leakedFile, constants.O_RDONLY | constants.O_CREAT | constants.O_EXCL, 0o000));
let engine = startEngine();
try {
	const client = await Client.connect(engine, home);
	await client.until("agents", () => client.events.providers);
	await until("startup removes an unheld run file with no record", () => !existsSync(leakedFile));
	assert.ok(existsSync(join(home, "runs", activeRun.marker)), "another engine's live run with no record here is kept");
	forgetRun(activeRun.marker);
	step("startup sweeps an unrecorded dead run's file, never another engine's live run");

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

	// engine.log: each line starts with its time, and a worktree's lines name the conversation (src/log.ts).
	await until("the worktree's removal logged", () => logged.some((line) => line.endsWith(`[pi2-engine] worktree removed for conversation ${a}`)));
	assert.ok(logged.some((line) => line.endsWith(`[pi2-engine] worktree made for conversation ${a} on ${made.branch}`)), logged.join("\n"));
	assert.ok(logged.length > 0 && logged.every((line) => /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ( |$)/.test(line)), `every line of the log starts with its time:\n${logged.join("\n")}`);
	step("engine.log: every line starts with its time; making and removing a worktree are logged with the conversation's number");

	{
		// A conversation in a worktree hands work to other agents.
		const outside = repo("outside");
		const save = async (agent: Record<string, unknown>): Promise<string> => (await client.call("agents.save", { agent })).id;
		const helper = await save({ name: "Helper", access: "full" });
		const neighbour = await save({ name: "Neighbour", access: "full", cwd: project });
		const outsider = await save({ name: "Outsider", access: "full", cwd: outside });
		const lead = await save({ name: "Lead", access: "full", delegates: [helper, neighbour, outsider] });
		const { id: e } = await client.call("conversation.create", { agentId: lead });
		await client.call("conversation.open", { id: e });
		await client.call("conversation.configure", { id: e, cwd: project });
		const shared = await client.call("worktree.create", { id: e });
		await client.until("lead in its worktree", () => client.conversations.get(e)?.state.agent.cwd === shared.path);
		/** Hands a task to an agent; returns the sub-chat's number and its answer. */
		const handOff = async (agent: string, task: string): Promise<{ sub: number; answer: string }> => {
			const call = await client.tool(e, `/delegate ${agent}: ${task}`);
			assert.equal(typeof call.details?.conversationId, "number", JSON.stringify(call));
			return { sub: call.details.conversationId, answer: call.text };
		};
		const where = "/bash pwd && git branch --show-current";
		const helped = await handOff("Helper", where);
		assert.ok(helped.answer.includes(shared.path) && helped.answer.includes(shared.branch), `an agent with no folder works in the worktree: ${helped.answer}`);
		const neighboured = await handOff("Neighbour", where);
		assert.ok(neighboured.answer.includes(shared.path), `an agent whose folder is in the same repository works in the worktree: ${neighboured.answer}`);
		const outsided = await handOff("Outsider", where);
		assert.ok(outsided.answer.includes(outside) && !outsided.answer.includes(shared.path), `an agent whose folder is in another repository keeps it: ${outsided.answer}`);
		const told = (await handOff("Helper", "/system")).answer;
		assert.ok(told.includes("<worktree>") && told.includes("This sub-chat works in the git worktree") && told.includes(shared.branch), `the sub-chat is told about the worktree: ${told}`);
		assert.ok(told.includes("do not check out another branch here") && !told.includes("you may start a new branch"), `a sub-chat in its parent's worktree keeps to its branch: ${told}`);
		assert.ok(!(await handOff("Outsider", "/system")).answer.includes("<worktree>"), "a sub-chat elsewhere is not");
		step("a sub-chat joins its parent's worktree, and is told so, unless its agent works in another repository");

		const cwdOf = (id: number) => client.conversations.get(id)?.state.agent.cwd;
		for (const id of [helped.sub, neighboured.sub, outsided.sub]) await client.call("conversation.open", { id });
		await client.until("sub-chats open", () => cwdOf(helped.sub) === shared.path && cwdOf(neighboured.sub) === shared.path && cwdOf(outsided.sub) === outside);

		// The sub-chats in the worktree show how its branch stands exactly as their parent does, merged included, which is
		// measured from where the worktree started; only the parent is told the worktree is its own.
		await client.bash(e, "echo from-the-lead > lead.txt && git add lead.txt && git commit -q -m 'from the lead'");
		run(project, "merge", "-q", "--ff-only", shared.branch);
		await client.call("branches.refresh");
		await client.until("all merged", () => [e, helped.sub, neighboured.sub].every((id) => client.branch(id)?.state === "merged"));
		for (const id of [helped.sub, neighboured.sub]) {
			const { managed, ...rest } = client.branch(id);
			const { managed: owns, ...parents } = client.branch(e);
			assert.equal(owns, true, "the parent owns the worktree");
			assert.equal(managed, false, "a sub-chat in it does not");
			assert.deepEqual(rest, parents, "a sub-chat in the worktree shows what its parent shows");
		}
		assert.equal(client.branch(outsided.sub).root, outside, "a sub-chat elsewhere shows its own folder's branch");
		step("a sub-chat in its parent's worktree is tracked with it: the same branch and state, merged too, but not its own");
		await client.call("worktree.remove", { id: e });
		await client.until("sub-chats back with their parent", () => cwdOf(e) === project && cwdOf(helped.sub) === project && cwdOf(neighboured.sub) === project);
		assert.equal(cwdOf(outsided.sub), outside, "a sub-chat elsewhere stays where it is");
		step("removing the worktree takes the sub-chats that worked in it back with their parent");
	}

	{
		// delegate gives a new sub-chat a worktree of its own (#151), and sub_chats removes it once nothing would be lost.
		const save = async (agent: Record<string, unknown>): Promise<string> => (await client.call("agents.save", { agent })).id;
		const setupRan = join(scratch, "worker-setup");
		const worker = await save({ name: "Worker", access: "full", cwd: project, setup: `pwd >> '${setupRan}'` });
		const plainHelper = await save({ name: "Plain", access: "full" });
		const auto = await save({ name: "Auto", access: "full", cwd: project, worktree: true });
		const orchestrator = await save({ name: "Orchestrator", access: "full", delegates: [worker, plainHelper] });
		const careful = await save({ name: "Careful", access: "ask", delegates: [worker, auto] });
		const open = async (agentId: string, cwd: string) => {
			const { id } = await client.call("conversation.create", { agentId });
			await client.call("conversation.open", { id });
			await client.call("conversation.configure", { id, cwd });
			await client.until("conversation in its folder", () => client.conversations.get(id)?.state.agent.cwd === cwd);
			return id as number;
		};
		const delegate = (id: number, args: Record<string, unknown>) => client.tool(id, `/tool delegate ${JSON.stringify(args)}`);
		const subChatsOf = (id: number) => (client.events.library?.conversations ?? []).filter((c: Event) => c.parent === id).map((c: Event) => c.id as number);
		const cwdOf = (id: number) => client.conversations.get(id)?.state.agent.cwd;
		const lead = await open(orchestrator, project);
		const head = run(project, "rev-parse", "HEAD");

		const where = "/bash pwd && git branch --show-current && git rev-parse HEAD";
		const first = await delegate(lead, { agent: "Worker", task: where, worktree: "sub-one" });
		assert.equal(first.isError, false, first.text);
		const one = first.details.conversationId as number;
		await client.call("conversation.open", { id: one });
		const oneRoot = await client.until("the sub-chat in its worktree", () => (cwdOf(one) !== project ? cwdOf(one) : undefined));
		assert.ok(oneRoot.startsWith(join(home, "worktrees")), `made where New Worktree… makes them: ${oneRoot}`);
		await client.until("the sub-chat's worktree tracked, for the sidebar and Branches", () => client.branch(one)?.managed === true);
		assert.equal(client.branch(one).branch, "sub-one");
		assert.ok(first.text.includes(oneRoot) && first.text.includes("sub-one") && first.text.includes(head), `the sub-chat worked there, from the parent's commit: ${first.text}`);
		assert.ok(first.text.includes(`worktree of its own at ${oneRoot} on the branch sub-one`), "the answer says where it works");
		assert.equal(cwdOf(lead), project, "the parent stays where it was");
		assert.equal((client.events.library?.conversations ?? []).find((c: Event) => c.id === one)?.title, "Worker: sub-one", "without a title, it is named after its branch");
		assert.equal(realpathSync(readFileSync(setupRan, "utf8").trim()), realpathSync(oneRoot), "the agent's set-up command ran in it");
		const told = await client.tool(lead, `/continue ${one}: /system`);
		assert.ok(told.text.includes("This conversation works in a git worktree of its own") && told.text.includes("sub-one"), `continued, it is told about its worktree: ${told.text}`);
		assert.ok(told.text.includes("Do not use `git stash`"), `and not to stash, since every worktree shares the stashes: ${told.text}`);
		await client.until("continuing keeps the folder", () => cwdOf(one) === oneRoot);
		step("delegate with worktree: the sub-chat gets a worktree of its own from the parent's commit, runs the set-up, is told, is tracked, and keeps it");

		// Starting from a named ref, as the repository has it now.
		run(project, "tag", "older", "HEAD~1");
		const older = run(project, "rev-parse", "older^{commit}");
		const fromTag = await delegate(lead, { agent: "Worker", task: where, worktree: "sub-two", from: "older" });
		assert.equal(fromTag.isError, false, fromTag.text);
		assert.ok(fromTag.text.includes(older) && fromTag.text.includes("sub-two"), `it starts from the ref: ${fromTag.text}`);
		const two = fromTag.details.conversationId as number;
		assert.equal((await client.until("tracked", () => client.branch(two)?.managed === true && client.branch(two))).base, "older", "merged is measured against the ref it was made from");

		// When it cannot be made, the call fails with the reason and nothing is handed over.
		const before = subChatsOf(lead).length;
		const cases: [Record<string, unknown>, RegExp][] = [
			[{ agent: "Worker", task: "x", worktree: "sub-three", from: "no-such-ref" }, /No worktree could be made for the sub-chat, so nothing was handed over: “no-such-ref” is not a branch, tag or commit in project/],
			[{ agent: "Worker", task: "x", worktree: "sub-one", from: "main" }, /The branch sub-one already exists/],
			[{ agent: "Worker", task: "x", worktree: "not a branch.." }, /cannot be a branch name/],
			[{ agent: "Worker", task: "x", from: "main" }, /pass it with `worktree`/],
			[{ agent: "", task: "x", chat: one, worktree: "sub-four" }, /`worktree` is for a new sub-chat/],
		];
		for (const [args, reason] of cases) {
			const failed = await delegate(lead, args);
			assert.equal(failed.isError, true, JSON.stringify(args));
			assert.match(failed.text, reason);
		}
		const nowhere = await open(orchestrator, scratch);
		const outside = await delegate(nowhere, { agent: "Plain", task: "x", worktree: "sub-five" });
		assert.match(outside.text, /nothing was handed over: The sub-chat's folder is not in a git repository/);
		assert.equal(subChatsOf(lead).length, before, "no sub-chat is left behind by a failed call");
		assert.equal(subChatsOf(nowhere).length, 0);
		step("delegate with worktree: a named ref to start from; a bad ref, a taken branch, a bad name or no repository fail the call with the reason, leaving no sub-chat");

		// Without full access, the person is asked first, unless the agent handed the work gets worktrees anyway.
		const asking = await open(careful, project);
		const inboxFor = (id: number) => (client.events.inbox?.items ?? []).find((i: Event) => i.conversationId === id);
		await client.call("submit", { id: asking, text: `/tool delegate ${JSON.stringify({ agent: "Worker", task: "x", worktree: "asked-first", from: "main" })}` });
		const question = await client.until("asked before the worktree is made", () => inboxFor(asking));
		assert.equal(question.question, "Make a git worktree on the branch asked-first, from main, for a new sub-chat with Worker.");
		assert.equal(subChatsOf(asking).length, 0, "nothing is made while it waits");
		await client.call("inbox.decide", { id: question.id, decision: "deny" });
		await client.until("denied", () => !client.conversations.get(asking).state.busy && client.conversations.get(asking).items.some((i: Event) => i.kind === "tool"));
		assert.equal(subChatsOf(asking).length, 0, "denied, nothing is made");
		assert.ok(!run(project, "branch").includes("asked-first"));
		await client.call("submit", { id: asking, text: `/tool delegate ${JSON.stringify({ agent: "Worker", task: "x", worktree: "asked-first" })}` });
		await client.call("inbox.decide", { id: (await client.until("asked again", () => inboxFor(asking))).id, decision: "once" });
		await client.until("allowed, the sub-chat is made", () => subChatsOf(asking).length === 1 && !client.conversations.get(asking).state.busy);
		const byAuto = await delegate(asking, { agent: "Auto", task: "x", worktree: "auto-sub" });
		assert.equal(byAuto.isError, false, byAuto.text);
		assert.equal(inboxFor(asking), undefined, "not asked for an agent whose conversations get worktrees anyway");
		const autoSub = byAuto.details.conversationId as number;
		assert.equal((await client.until("Auto's sub-chat in its worktree", () => client.branch(autoSub)?.managed === true && client.branch(autoSub))).branch, "auto-sub");
		// With no `worktree`, such an agent's sub-chat still gets one, on the branch pi² names, and nobody is asked (#604).
		const byAutoAlone = await delegate(asking, { agent: "Auto", task: "x", title: "Its own worktree" });
		assert.equal(byAutoAlone.isError, false, byAutoAlone.text);
		assert.equal(inboxFor(asking), undefined);
		const autoAlone = byAutoAlone.details.conversationId as number;
		assert.match((await client.until("its worktree made", () => client.branch(autoAlone)?.managed === true && client.branch(autoAlone))).branch, /^pi2\/its-own-worktree/);
		assert.ok(byAutoAlone.text.includes("working in a worktree of its own at "), byAutoAlone.text);
		step("delegate with worktree: asked first without full access, unless the receiving agent gets worktrees anyway");

		// sub_chats says how each worktree stands, and removes one with nothing to lose when archiving, keeping its branch.
		run(project, "config", "status.showUntrackedFiles", "no");
		writeFileSync(join(project, ".git", "info", "exclude"), "ignored-cut-off\n");
		writeFileSync(join(oneRoot, "ignored-cut-off"), "safe to clean up");
		const dirty = (await delegate(lead, { agent: "Worker", task: "/bash echo unsaved > unsaved.txt", worktree: "sub-dirty" })).details.conversationId as number;
		const listed = await client.tool(lead, `/tool sub_chats {"action":"list"}`);
		assert.ok(listed.text.includes(`worktree of its own at ${oneRoot}, on the branch sub-one (made from main): nothing uncommitted, no commits that are not on main`), listed.text);
		assert.match(listed.text, /on the branch sub-dirty \(made from main\): 1 uncommitted change/);
		const kept = await client.tool(lead, `/tool sub_chats ${JSON.stringify({ action: "archive", chats: [one] })}`);
		assert.match(kept.text, /was left where it is\. Nothing would be lost by removing it: pass remove_worktree: true/);
		assert.ok(existsSync(oneRoot));
		await client.until("listed as left behind", () => client.events.branches?.leftBehind?.some((w: Event) => w.id === one));
		const listedAfter = await client.tool(lead, `/tools ${JSON.stringify([
			{ name: "sub_chats", arguments: { action: "archive", chats: [one, dirty], remove_worktree: true } },
			{ name: "sub_chats", arguments: { action: "list" } },
		])}`);
		const removed = client.conversations.get(lead).items.filter((item: Event) => item.kind === "tool").at(-2);
		assert.match(listedAfter.text, /^2 archived; `archived: true` lists them/m);
		assert.doesNotMatch(listedAfter.text, /on the branch sub-dirty/);
		assert.equal(removed.isError, false, removed.text);
		assert.ok(removed.text.includes(`- ${one}: already archived. Removed its worktree at ${oneRoot}; the branch sub-one is kept.`), removed.text);
		assert.match(removed.text, /worktree was not removed: pi² kept it because it has 1 uncommitted change/);
		assert.equal(existsSync(oneRoot), false, "the worktree's folder is gone");
		assert.ok(run(project, "branch").includes("sub-one"), "its branch is kept");
		const dirtyPath = await client.until("dirty checkout still in Branches", () => client.events.branches?.leftBehind?.find((w: Event) => w.id === dirty)?.status.root);
		assert.equal(readFileSync(join(dirtyPath, "unsaved.txt"), "utf8"), "unsaved\n");
		run(project, "config", "--unset", "status.showUntrackedFiles");
		await client.until("no longer left behind", () => !client.events.branches?.leftBehind?.some((w: Event) => w.id === one) && client.events.branches?.leftBehind?.some((w: Event) => w.id === dirty));
		const line = client.conversations.get(lead).items.filter((i: Event) => i.kind === "marker").at(-1).text;
		assert.ok(line.includes("The agent removed a worktree with nothing uncommitted or unmerged; its branch sub-one is kept."), line);
		step("sub_chats: each worktree's standing listed; archiving leaves it, or removes it on request when nothing would be lost, keeping the branch");

		// A worker given several pieces of work in turn starts a new branch in its own worktree once its first is merged
		// (#206): the tracker, sub_chats and removing the worktree go by the branch it is on now.
		const next = (await delegate(lead, { agent: "Worker", task: "/bash git commit -q --allow-empty -m first", worktree: "sub-first" })).details.conversationId as number;
		await client.call("conversation.open", { id: next });
		const nextRoot = await client.until("the worker in its worktree", () => (cwdOf(next) !== project ? cwdOf(next) : undefined));
		const toldNext = await client.tool(lead, `/continue ${next}: /system worktree`);
		assert.ok(toldNext.text.includes("commit your work to its branch, do not check out a branch another worktree has") && toldNext.text.includes("Once sub-first is merged, you may start a new branch here from main"), `a worktree of its own may go on to a new branch: ${toldNext.text}`);
		run(project, "merge", "-q", "--ff-only", "sub-first");
		await client.until("the first branch merged", () => client.branch(next)?.state === "merged");
		run(nextRoot, "switch", "-q", "-c", "sub-second", "main");
		run(nextRoot, "commit", "-q", "--allow-empty", "-m", "second");
		const moved = await client.until("the tracker on the new branch", () => client.branch(next)?.branch === "sub-second" && client.branch(next));
		assert.equal(moved.managed, true, "still its own worktree");
		assert.equal(moved.state, "ahead");
		assert.equal(moved.unmerged, 1, "measured against what the worktree was made from");
		const listedNext = await client.tool(lead, `/tool sub_chats {"action":"list"}`);
		assert.ok(listedNext.text.includes(`worktree of its own at ${nextRoot}, on the branch sub-second (made from main): nothing uncommitted, 1 commit not on main`), listedNext.text);
		const keptNext = await client.tool(lead, `/tool sub_chats ${JSON.stringify({ action: "archive", chats: [next], remove_worktree: true })}`);
		assert.match(keptNext.text, /worktree was not removed: pi² kept it because its branch has 1 commit that is not on main/);
		assert.ok(existsSync(nextRoot), "the new branch's commit is not lost");
		run(project, "merge", "-q", "--ff-only", "sub-second");
		await client.until("the second branch merged", () => client.branch(next)?.state === "merged" || client.events.branches?.leftBehind?.some((w: Event) => w.id === next && w.status.state === "merged"));
		const gone = await client.call("worktree.remove", { id: next, deleteBranch: true });
		assert.equal(gone.branchDeleted, true, JSON.stringify(gone));
		assert.equal(existsSync(nextRoot), false);
		const branches = run(project, "branch");
		assert.ok(!branches.includes("sub-second") && branches.includes("sub-first"), `Remove Worktree and Branch deletes the branch it is on now, as Branches names it: ${branches}`);
		step("a worktree of its own may go on to a new branch once its first is merged: the tracker, sub_chats and removing it follow the branch it is on now");

		const make = (branch: string, task = "Done") => delegate(lead, { agent: "Plain", task, worktree: branch });
		const archive = (id: number) => client.tool(lead, `/tool sub_chats ${JSON.stringify({ action: "archive", chats: [id], remove_worktree: true })}`);
		const leftBehind = (id: number) => client.events.branches?.leftBehind?.find((entry: Event) => entry.id === id);
		run(project, "branch", "cut-off-existing");
		const addedBefore = run(project, "worktree", "list", "--porcelain");
		assert.match((await make("cut-off-new")).text, /git was stopped by SIGKILL\. Retry/);
		const failedExisting = await make("cut-off-existing");
		assert.match(failedExisting.text, /a test checkout filter refused a file\. Retry/);
		assert.doesNotMatch(failedExisting.text, /Updating files|Preparing worktree|Command failed/);
		assert.doesNotMatch(run(project, "branch"), /cut-off-new/);
		assert.match(run(project, "branch"), /cut-off-existing/);
		assert.equal(run(project, "worktree", "list", "--porcelain"), addedBefore);
		assert.ok(!existsSync(join(dirname(oneRoot), "cut-off-new")) && !existsSync(join(dirname(oneRoot), "cut-off-existing")));
		const parallel = ["parallel-a", "parallel-b", "parallel-c"];
		await client.tool(lead, `/tools ${JSON.stringify(parallel.map((branch) => ({ name: "delegate", arguments: { agent: "Plain", task: "Done", worktree: branch } })))}`);
		const outcomes = client.conversations.get(lead).items.filter((item: Event) => item.kind === "tool").slice(-3);
		assert.equal(new Set(outcomes.map((item: Event) => item.details?.conversationId)).size, 3);
		assert.ok(outcomes.every((item: Event) => !item.isError));
		for (const branch of parallel) assert.ok(run(project, "worktree", "list", "--porcelain").includes(`branch refs/heads/${branch}`));
		step("cut-off and failed checkouts remove just their own leftovers and new branch; three delegates can make worktrees together");

		const move = (await make("cut-off-move")).details.conversationId as number;
		const movingRoot = (await client.until("moving checkout is tracked", () => client.branch(move)?.root)) as string;
		const brokenMove = assert.rejects(client.call("worktree.remove", { id: move }), /git was stopped by SIGKILL/);
		try {
			await until("git moved the checkout", () => existsSync(moveMarker) && readFileSync(moveMarker, "utf8") !== "");
			const during = await client.tool(lead, `/tool sub_chats {"action":"list"}`);
			assert.match(during.text, /on the branch cut-off-move[^\n]*checkout status is unavailable/);
		} finally {
			writeFileSync(endMove, "");
		}
		await brokenMove;
		assert.equal(existsSync(movingRoot), false);
		assert.match((await archive(move)).text, /Removed its worktree/);
		assert.equal(existsSync(readFileSync(moveMarker, "utf8")), false);
		step("an overlapping list does not report the partial checkout, and archive retries after git is killed during removal");

		for (const retryFrom of ["archive", "Branches"]) {
			const name = `partial-${retryFrom.toLowerCase()}`;
			const { conversationId: id } = (await make(name, "/bash echo interrupt > ignored-cut-off")).details;
			const root = (await client.until("checkout tracked", () => client.branch(id)?.root)) as string;
			const failedRemoval = await archive(id);
			assert.match(failedRemoval.text, /Could not finish removing the worktree: EIO/);
			await client.until("interrupted removal is listed under Left Behind", () => leftBehind(id)?.status.state === "unavailable");
			const held = failedRemoval.text.match(/inspect (.+?)\. See Branches/)?.[1];
			assert.ok(held, failedRemoval.text);
			assert.equal(existsSync(join(held, "checkout", ".git")), false);
			assert.equal(readFileSync(join(held, "checkout", "ignored-cut-off"), "utf8"), "left behind");
			// A different folder now at the old path is not cleanup material.
			mkdirSync(root);
			writeFileSync(join(root, "work.txt"), "keep this");
			await assert.rejects(client.call("worktree.remove", { id }), /left it alone/);
			assert.equal(readFileSync(join(root, "work.txt"), "utf8"), "keep this");
			rmSync(root, { recursive: true });
			if (retryFrom === "archive") assert.match((await archive(id)).text, /Removed its worktree/);
			else await client.call("worktree.remove", { id });
			assert.equal(existsSync(held), false);
			assert.doesNotMatch(run(project, "worktree", "list", "--porcelain"), new RegExp(`branch refs/heads/${name}`));
			assert.ok(run(project, "branch").includes(name));
		}
		const unproven = (await make("unproven")).details.conversationId as number;
		const unprovenRoot = (await client.until("unproven checkout tracked", () => client.branch(unproven)?.root)) as string;
		rmSync(join(unprovenRoot, ".git"));
		writeFileSync(join(unprovenRoot, "new-work"), "not safe to delete");
		assert.match((await archive(unproven)).text, /pi² left it alone/);
		await client.until("unproven leftover is listed", () => leftBehind(unproven)?.status.state === "unavailable");
		await assert.rejects(client.call("worktree.remove", { id: unproven }), /pi² left it alone/);
		assert.equal(readFileSync(join(unprovenRoot, "new-work"), "utf8"), "not safe to delete");
		step("archive and Branches finish proven half-removals, but leave replaced and unproven folders alone");
	}

	// An agent whose conversations each get a worktree.
	await assert.rejects(client.call("agents.save", { agent: { name: "Builder", access: "full", cwd: scratch, worktree: true } }), /git repository/);
	const { id: builder } = await client.call("agents.save", { agent: { name: "Builder", access: "full", cwd: project, worktree: true } });
	const { id: c } = await client.call("conversation.create", { agentId: builder });
	const { id: d } = await client.call("conversation.create", { agentId: builder });
	await client.until("both in worktrees", () => client.branch(c)?.managed === true && client.branch(d)?.managed === true);
	assert.notEqual(client.branch(c).root, client.branch(d).root, "each conversation has its own checkout");
	assert.notEqual(client.branch(c).branch, client.branch(d).branch, "and its own branch");
	step("an agent set to use worktrees starts each conversation in a worktree of its own");

	// An agent's set-up command: run once in each new worktree, its end shown in the transcript and told to the agent.
	const tooling = repo("tooling");
	writeFileSync(join(tooling, ".gitignore"), "deps/\n");
	run(tooling, "add", ".gitignore");
	run(tooling, "commit", "-q", "-m", "ignore deps");
	const setups = (id: number) => client.conversations.get(id)?.items.filter((item: Event) => item.kind === "setup") ?? [];
	const ended = (id: number) => setups(id).find((item: Event) => item.details.status !== "running");
	await assert.rejects(client.call("agents.save", { agent: { name: "Setter", setup: ["npm", "ci"] } }), /must be text/);
	// The set-up waits for the test to let it finish, so that the first message is certainly sent while it runs.
	const setterGate = join(scratch, "setter.gate");
	const setterCommand = `while [ ! -e '${setterGate}' ]; do sleep 0.1; done; echo installing; mkdir -p deps; echo once >> deps/runs; echo a-warning >&2`;
	const { id: setter } = await client.call("agents.save", { agent: { name: "Setter", access: "full", cwd: tooling, worktree: true, setup: `  ${setterCommand}  ` } });
	const { id: e } = await client.call("conversation.create", { agentId: setter });
	await client.call("conversation.open", { id: e });
	await client.until("set-up shown as running", () => setups(e)[0]?.details.status === "running");
	assert.equal(ended(e), undefined, "the command takes a while");
	// The first message, sent while the set-up runs, waits for it.
	await client.call("submit", { id: e, text: "/system" });
	await client.until("the message in the transcript", () => client.conversations.get(e)?.items.some((item: Event) => item.kind === "user"));
	assert.equal(ended(e), undefined, "the set-up is still running");
	writeFileSync(setterGate, "");
	const answered = await client.until("answer after the set-up", () => {
		const conv = client.conversations.get(e);
		return conv !== undefined && !conv.state.busy && conv.items.at(-1)?.kind === "assistant" ? conv.items : undefined;
	});
	assert.deepEqual(
		answered.map((item: Event) => (item.kind === "setup" ? `setup:${item.details.status}` : item.kind)),
		["setup:running", "user", "setup:done", "assistant"],
		"the set-up's end comes before the answer",
	);
	const done = ended(e);
	assert.equal(done.details.command, setterCommand, "the command is kept as typed, trimmed");
	assert.equal(done.isError, false);
	assert.match(done.details.output, /installing\n/);
	assert.match(done.details.output, /a-warning/, "errors are shown with the output");
	assert.match(done.text, /^The set-up command finished/);
	assert.match(answered.at(-1).text, /ran the set-up command[^]*`while \[ ! -e '[^']*' \]; do sleep 0\.1; done; echo installing[^]*It finished without errors/, "the agent is told it ran");
	const setterRoot = await client.until("tracked", () => client.branch(e)?.managed === true && client.branch(e).root);
	assert.equal(readFileSync(join(setterRoot, "deps", "runs"), "utf8"), "once\n", "it ran in the worktree's top folder");
	assert.equal(existsSync(join(tooling, "deps")), false, "and not in the main checkout");
	await client.bash(e, "true");
	assert.equal(readFileSync(join(setterRoot, "deps", "runs"), "utf8"), "once\n", "it runs once, not for every message");
	step("a set-up command runs once in a new worktree; the first message waits for it, and its output is in the transcript");

	const { id: breaker } = await client.call("agents.save", { agent: { name: "Breaker", access: "full", cwd: tooling, worktree: true, setup: "echo broken-thing >&2; exit 3" } });
	const { id: f } = await client.call("conversation.create", { agentId: breaker });
	await client.call("conversation.open", { id: f });
	const failed = await client.until("set-up failed", () => ended(f));
	assert.equal(failed.isError, true);
	assert.equal(failed.details.reason, "exited with code 3");
	assert.match(failed.details.output, /broken-thing/);
	assert.equal(failed.text, "Set-up command failed: exited with code 3 · echo broken-thing >&2; exit 3", "it leads with what happened, so a cut line loses the command");
	const exported = (await client.call("conversation.export", { id: f, format: "markdown" })).text as string;
	assert.ok(exported.includes("*Set-up command failed: exited with code 3*\n\n```sh\necho broken-thing >&2; exit 3\n```\n"), exported);
	assert.ok(!exported.includes("Running the set-up command"), "an export shows how it ended, not its start as well");
	assert.match(await client.bash(f, "echo still-works"), /still-works/, "the conversation works after a failed set-up");
	await client.call("submit", { id: f, text: "/system" });
	const told = await client.until("told of the failure", () => {
		const conv = client.conversations.get(f);
		const last = conv?.items.at(-1);
		return !conv?.state.busy && last?.kind === "assistant" && last.text.startsWith("SYSTEM PROMPT") ? last.text : undefined;
	});
	assert.match(told, /It exited with code 3[^]*broken-thing/, "the agent is told it failed, with the end of its output");
	step("a failing set-up is shown as failed and told to the agent, and the conversation still works");

	{
		// What a set-up prints is in the conversation's state while it runs, and only in its entry once it has ended.
		const gate = join(scratch, "streamer.gate");
		const { id: streamer } = await client.call("agents.save", {
			agent: { name: "Streamer", access: "full", cwd: tooling, worktree: true, setup: `echo early-line; while [ ! -e '${gate}' ]; do sleep 0.1; done; echo late-line` },
		});
		const { id: s } = await client.call("conversation.create", { agentId: streamer });
		await client.call("conversation.open", { id: s });
		const live = await client.until("output while it runs", () => {
			const setup = client.conversations.get(s)?.state.setup;
			return typeof setup?.output === "string" && setup.output.includes("early-line") ? setup : undefined;
		});
		assert.equal(ended(s), undefined, "it is still running");
		assert.equal(live.run, setups(s)[0].details.run, "the output is the running entry's");
		assert.equal(setups(s).length, 1, "output arriving writes no entries");
		writeFileSync(gate, "");
		const finished = await client.until("set-up ended", () => ended(s));
		assert.match(finished.details.output, /early-line\nlate-line/);
		await client.until("output gone from the state", () => client.conversations.get(s)?.state.setup === null);
		step("a running set-up's output is in the conversation's state as it arrives, and leaves it once the entry has it");
	}

	// Made from the app for a conversation of an agent with a set-up command, then removed while it runs.
	const pidFile = join(scratch, "setup.pid");
	const { id: manual } = await client.call("agents.save", { agent: { name: "Manual", access: "full", cwd: tooling, setup: `${LONG_SLEEP} & echo $! > '${pidFile}'; wait` } });
	const { id: g } = await client.call("conversation.create", { agentId: manual });
	await client.call("conversation.open", { id: g });
	await sleep(300);
	assert.equal(setups(g).length, 0, "no worktree, no set-up");
	await client.call("worktree.create", { id: g });
	await client.until("set-up running", () => setups(g)[0]?.details.status === "running" && existsSync(pidFile) && readFileSync(pidFile, "utf8").trim() !== "");
	const sleeper = Number(readFileSync(pidFile, "utf8"));
	sleepers.push(sleeper);
	const madeAt = await client.until("tracked", () => client.branch(g)?.managed === true && client.branch(g).root);
	// The command would run for twice the test's patience; a remove that waited for it would never be answered in time.
	await client.call("worktree.remove", { id: g });
	const stopped = await client.until("set-up stopped", () => ended(g));
	assert.equal(stopped.details.reason, "was stopped because the worktree was removed");
	assert.equal(existsSync(madeAt), false, "the worktree is gone");
	await client.until("what the command started was stopped too", () => !alive(sleeper));
	step("a worktree made from the app runs the agent's set-up; removing it mid-run stops the command and everything it started");

	// Its folder deleted by hand: shown as missing, and removing it tidies up.
	rmSync(client.branch(d).root, { recursive: true, force: true });
	await client.call("branches.refresh");
	await client.until("missing", () => client.branch(d)?.state === "missing");
	await client.call("worktree.remove", { id: d });
	await client.until("back in the agent's folder", () => client.branch(d)?.managed === false);
	assert.ok(!run(project, "worktree", "list").includes(`pi2/builder-${d}`), "git forgot the deleted worktree");
	step("a worktree deleted by hand shows as missing; removing it lets git forget it");

	{
		// In ordinary folders, a look can reuse the repository and its default branch for a minute (#377). What the
		// branch is and how it stands is read at every look, and moving folders makes the tracker ask again at once.
		const kept = repo("kept");
		const movedTo = repo("movedTo");
		/** How often git was asked `what` with that folder as its working folder. */
		const asked = (what: RegExp, folder: string) =>
			readFileSync(gitCalls, "utf8")
				.split("\n")
				.filter((line) => {
					const [cwd, args = ""] = line.split("\t");
					return cwd === folder && what.test(args);
				}).length;
		const whichRepo = /--show-toplevel/;
		const itsDefault = /refs\/remotes\/origin\/HEAD/;
		const itsStatus = /^status /;
		const { id: keeper } = await client.call("conversation.create");
		await client.call("conversation.configure", { id: keeper, cwd: kept });
		await client.until("keeper tracked", () => client.branch(keeper)?.branch === "main" && client.branch(keeper));
		assert.ok(asked(whichRepo, kept) > 0 && asked(itsDefault, kept) > 0, "the first look asked git which repository this folder is in, and what that repository's default branch is");
		// A second conversation works in another folder of the same repository, so that repository is looked at twice.
		const { id: sharer } = await client.call("conversation.create");
		await client.call("conversation.configure", { id: sharer, cwd: join(kept, "sub") });
		await client.until("sharer tracked", () => client.branch(sharer)?.branch === "main" && client.branch(sharer));
		let statusWas = asked(itsStatus, kept);
		await client.call("branches.refresh");
		await client.until("looked at again", () => asked(itsStatus, kept) > statusWas);
		const repoWas = asked(whichRepo, kept);
		const defaultWas = asked(itsDefault, kept);
		statusWas = asked(itsStatus, kept);
		await client.call("branches.refresh");
		await client.until("looked at once more", () => asked(itsStatus, kept) > statusWas);
		assert.deepEqual([asked(whichRepo, kept), asked(itsDefault, kept)], [repoWas, defaultWas], "the look again read the branch and how it stands, but did not ask again which repository it is in or what its default branch is");
		// A conversation moving folders drops what was kept, so the folder it left (still tracked by the other
		// conversation) and the one it entered are both read afresh.
		await client.call("conversation.configure", { id: sharer, cwd: movedTo });
		await client.until("sharer moved", () => client.branch(sharer)?.repo === "movedTo" && client.branch(sharer));
		assert.ok(asked(whichRepo, kept) > repoWas, "the next look asked again about the folder the conversation left");
		assert.ok(asked(whichRepo, movedTo) > 0, "and about the folder it moved into");
		// A folder in no repository is not kept: that answer is also what a git that failed or timed out gives, so the
		// next look asks again, and a repository made in such a folder shows within a few seconds.
		const nowhere = join(scratch, "nowhere");
		mkdirSync(nowhere, { recursive: true });
		const { id: wanderer } = await client.call("conversation.create");
		await client.call("conversation.configure", { id: wanderer, cwd: nowhere });
		await client.call("branches.refresh");
		const nowhereWas = asked(whichRepo, nowhere);
		assert.ok(nowhereWas > 0, "the look asked git which repository this folder is in");
		await client.call("branches.refresh");
		assert.ok(asked(whichRepo, nowhere) > nowhereWas, "a folder in no repository is asked about again at every look");
		const ownFolder = realpathSync(client.branch(c).root);
		await client.call("branches.refresh");
		const ownWas = asked(whichRepo, ownFolder);
		await client.call("branches.refresh");
		assert.ok(asked(whichRepo, ownFolder) > ownWas, "a worktree pi² made is asked which repository it is in at every look");
		// The size of the change (#598) is measured with one git process when the checkout changed since the last look,
		// and with none when it did not.
		const itsDiff = /^diff /;
		writeFileSync(join(kept, "README.md"), "hello\nmore\n");
		await client.call("branches.refresh");
		await client.until("measured", () => client.branch(keeper)?.added === 1);
		let diffWas = asked(itsDiff, kept);
		assert.ok(diffWas > 0, "a changed checkout is measured with git diff");
		statusWas = asked(itsStatus, kept);
		await client.call("branches.refresh");
		await client.call("branches.refresh");
		assert.ok(asked(itsStatus, kept) >= statusWas + 2, "it was looked at twice more");
		assert.equal(asked(itsDiff, kept), diffWas, "but not measured again, since nothing in it changed");
		// The same file changed again: git status prints the same, and the file's size and time say it changed.
		writeFileSync(join(kept, "README.md"), "hello\nmore\nand more\n");
		await client.call("branches.refresh");
		await client.until("measured again", () => client.branch(keeper)?.added === 2);
		assert.equal(asked(itsDiff, kept), diffWas + 1, "a look after a change measures it once");
		diffWas = asked(itsDiff, kept);
		await client.call("branches.refresh");
		assert.equal(asked(itsDiff, kept), diffWas, "and the next look, with nothing new, not at all");
		step("the tracker reuses answers for ordinary folders until they move, and asks again at every look about folders in no repository and worktrees pi² made");
	}

	// A set-up still running when the engine stops is stopped with it, and said to be cut off when it starts again.
	rmSync(pidFile, { force: true });
	const { id: h } = await client.call("conversation.create", { agentId: manual });
	await client.call("worktree.create", { id: h });
	await client.until("set-up started", () => existsSync(pidFile) && readFileSync(pidFile, "utf8").trim() !== "");
	const orphan = Number(readFileSync(pidFile, "utf8"));
	sleepers.push(orphan);

	// The worktree's record outlives a restart.
	await stop(engine);
	// Killed as the engine exits; gone once launchd has collected it. Checked before the next engine starts, which would
	// stop it too.
	await until("stopping the engine stopped the set-up", () => !alive(orphan));
	engine = startEngine();
	const again = await Client.connect(engine, home);
	await again.until("worktree remembered", () => again.branch(c)?.managed === true);
	step("after a restart the worktree is still known as the conversation's own");
	await again.call("conversation.open", { id: h });
	const cut = await again.until("cut off", () => again.conversations.get(h)?.items.find((item: Event) => item.kind === "setup" && item.details.status !== "running"));
	assert.equal(cut.details.reason, "was cut off when pi²’s engine stopped");
	assert.equal((await again.until("recovery event", () => again.events.recovery)).recovery, null, "a clean stop is not an unexpected one: Activity has no notice");
	assert.match(await again.bash(h, "echo after-restart"), /after-restart/);
	step("a set-up running when the engine stops is stopped with it, and shown as cut off after a restart");

	// Archived or deleted, its worktree stays on disk and is listed as left behind, where it can be removed.
	const behind = (id: number) => again.events.branches?.leftBehind?.find((w: Event) => w.id === id);
	// A look at the folders under way as the conversation is archived, as the engine's own every few seconds may be: what
	// it says must still be true of one moment, and a refresh asked for after the archive must look again after it.
	const underWay = again.call("branches.refresh");
	await again.call("conversation.archive", { id: c });
	await again.call("branches.refresh");
	await underWay;
	let left = behind(c);
	assert.ok(left, "once a refresh asked for after the archive is answered, the worktree is listed as left behind");
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
	assert.deepEqual(again.both, [], "no event listed a conversation both among the branches and as left behind");
	step("an archived or deleted conversation's worktree is listed as left behind, and can be removed");

	{
		// Command rules (src/rules.ts) follow the worktrees pi² made: a rule made in one holds in all of them and in the main
		// checkout, for the same agent and repository only.
		const script = (dir: string) => {
			writeFileSync(join(dir, "run-tests"), '#!/bin/sh\necho "tests ran in $(pwd -P)"\n');
			chmodSync(join(dir, "run-tests"), 0o755);
			run(dir, "add", "run-tests");
			run(dir, "commit", "-q", "-m", "tests");
		};
		script(project);
		const second = repo("second");
		script(second);
		const byHand = join(scratch, "by-hand");
		run(project, "worktree", "add", "-q", "-b", "by-hand", byHand);
		const inbox = () => (again.events.inbox?.items ?? []) as Event[];
		const tools = (id: number) => again.conversations.get(id)?.items.filter((i: Event) => i.kind === "tool") ?? [];
		const cwdOf = (id: number) => again.conversations.get(id)?.state.agent.cwd as string | undefined;
		const start = async (agentId: string, cwd?: string) => {
			const { id } = await again.call("conversation.create", { agentId });
			await again.call("conversation.open", { id });
			await again.until("conversation in a worktree", () => cwdOf(id)?.startsWith(join(home, "worktrees")));
			if (cwd !== undefined) {
				await again.call("conversation.configure", { id, cwd });
				await again.until("conversation moved", () => cwdOf(id) === cwd);
			}
			return id as number;
		};
		/** Run a command and answer its approval with `decision`, if it asks. Says what it asked, or null, and the result. */
		const attempt = async (id: number, command: string, decision = "deny") => {
			const before = tools(id).length;
			await again.call("submit", { id, text: `/bash ${command}` });
			const asked = await again.until(`${command}: approval or result`, () => inbox().find((i) => i.conversationId === id) ?? (tools(id).length > before ? null : undefined));
			if (asked !== null) await again.call("inbox.decide", { id: asked.id, decision });
			await again.until(`${command}: settled`, () => {
				const conv = again.conversations.get(id);
				return conv !== undefined && !conv.state.busy && tools(id).length > before && conv.items.at(-1).kind === "assistant";
			});
			return { asked: asked as Event | null, result: tools(id).at(-1) as Event };
		};
		const ranIn = (outcome: { result: Event }, id: number) => outcome.result.text.includes(`tests ran in ${realpathSync(cwdOf(id)!)}`);
		type Rule = { folder: string; words: string[] };
		const rulesOf = (id: string) => ((again.events.agents?.agents ?? []).find((x: Event) => x.id === id)?.commandRules ?? []) as Rule[];
		const { id: asker } = await again.call("agents.save", { agent: { name: "Asker", access: "ask", cwd: project, worktree: true } });
		const { id: other } = await again.call("agents.save", { agent: { name: "Other", access: "ask", cwd: project, worktree: true } });

		const e = await start(asker);
		let outcome = await attempt(e, "./run-tests", "rule");
		assert.deepEqual(outcome.asked?.rule, { words: ["./run-tests"], folder: project, worktrees: true }, "the rule offered in a worktree is for the main checkout, and says it covers worktrees");
		assert.ok(ranIn(outcome, e), outcome.result.text);
		await again.until("rule kept", () => rulesOf(asker).length === 1);
		assert.deepEqual(rulesOf(asker).map((r) => [r.folder, r.words]), [[project, ["./run-tests"]]]);
		const f = await start(asker);
		assert.notEqual(cwdOf(f), cwdOf(e));
		outcome = await attempt(f, "./run-tests --again");
		assert.equal(outcome.asked, null, "another worktree conversation of the same agent and repository does not ask");
		assert.ok(ranIn(outcome, f) && outcome.result.details?.allowedBy?.[0] === "./run-tests", JSON.stringify(outcome.result));
		const g = await start(asker, project);
		outcome = await attempt(g, "./run-tests");
		assert.ok(outcome.asked === null && ranIn(outcome, g), "nor does the main checkout");
		outcome = await attempt(g, "git status");
		assert.deepEqual(outcome.asked?.rule, { words: ["git", "status"], folder: project, worktrees: true }, "a rule offered in the main checkout covers worktrees too");
		step("rules: a rule made in one worktree conversation holds in another worktree of the same repository and in the main checkout");

		outcome = await attempt(await start(other), "./run-tests");
		assert.ok(outcome.asked !== null, "another agent asks");
		outcome = await attempt(await start(asker, byHand), "./run-tests");
		assert.deepEqual(outcome.asked?.rule, { words: ["./run-tests"], folder: byHand }, "a worktree pi² did not make asks, and its rule would be for that folder only");
		await again.call("agents.save", { agent: { id: asker, name: "Asker", access: "ask", cwd: second, worktree: true } });
		await again.until("asker moved", () => (again.events.agents?.agents ?? []).find((x: Event) => x.id === asker)?.cwd === second);
		const h = await start(asker);
		outcome = await attempt(h, "./run-tests");
		assert.deepEqual(outcome.asked?.rule, { words: ["./run-tests"], folder: second, worktrees: true }, "a worktree of another repository asks");
		assert.equal(rulesOf(asker).length, 1, "saving the agent kept its rule");
		await again.call("rules.add", { agentId: other, folder: cwdOf(f), command: "./run-tests" });
		await again.until("rule added by hand", () => rulesOf(other).length === 1);
		assert.equal(rulesOf(other)[0]!.folder, project, "a rule added by hand for a worktree's folder is kept for the main checkout's");
		await again.call("worktree.remove", { id: e, force: true });
		outcome = await attempt(f, "./run-tests");
		assert.equal(outcome.asked, null, "the rule outlives the worktree it was made in");
		step("rules: another agent, another repository and a worktree pi² did not make still ask; a rule added by hand in a worktree is kept for the main checkout");
	}

	{
		// An engine killed outright mid set-up leaves the command running; the next engine stops it, and what it started.
		const leaderFile = join(scratch, "left.pid");
		const childFile = join(scratch, "left-child.pid");
		const { id: lingerer } = await again.call("agents.save", { agent: { name: "Lingerer", access: "full", cwd: tooling, setup: `${LONG_SLEEP} & echo $! > '${childFile}'; echo $$ > '${leaderFile}'; wait` } });
		const { id: k } = await again.call("conversation.create", { agentId: lingerer });
		await again.call("worktree.create", { id: k });
		const [leader, started] = await again.until("set-up running", () => {
			const read = (file: string) => (existsSync(file) ? Number(readFileSync(file, "utf8").trim()) : 0);
			return read(leaderFile) > 0 && read(childFile) > 0 ? [read(leaderFile), read(childFile)] : undefined;
		});
		sleepers.push(started);
		// The engine notes the command's process group just after starting it, which the next engine needs to stop it.
		await until("the set-up's process group noted", () => logged.some((line) => line.includes(`set-up for conversation ${k} runs as process group ${leader}`)));
		await stop(engine, "SIGKILL");
		assert.ok(alive(leader) && alive(started), "an engine killed outright does not stop the set-up");
		engine = startEngine();
		const third = await Client.connect(engine, home);
		await third.call("conversation.open", { id: k });
		const cut = await third.until("marked", () => third.conversations.get(k)?.items.find((item: Event) => item.kind === "setup" && item.details.status !== "running"));
		assert.equal(cut.details.reason, "was left running when pi²’s engine stopped, and was stopped when the engine started again");
		await third.until("what was left running is stopped", () => !alive(leader) && !alive(started));
		// Activity's notice after the unexpected stop names it, with its conversation and what became of it.
		const notice: Event[] = (await third.until("recovery event", () => third.events.recovery)).recovery?.setups ?? [];
		const listed = await third.until("the conversation listed", () => third.events.library?.conversations.find((conversation: Event) => conversation.id === k));
		assert.deepEqual(notice, [{ conversationId: k, rootConversationId: k, title: listed.title, command: `${LONG_SLEEP} & echo $! > '${childFile}'; echo $$ > '${leaderFile}'; wait`, outcome: "stopped", group: leader }]);
		step("a set-up left running by an engine killed outright is stopped by the next engine, with what it started, and marked; Activity's notice names it");

		// The same when the command's first process has ended and only something it started in the background is left: the
		// next engine knows it by the run's marker in its environment, or by the run's file it has open. The first process
		// ends once the engine is killed, as it waits for the test to let it; ended while the engine runs, the set-up would
		// soon count as over. One of what is left is node with the file closed, known by its environment alone; the other is
		// `sleep` without the marker, known by the file alone, as macOS does not show the environment of its own programs.
		const strayFile = join(scratch, "stray.pid");
		const strayingSleepFile = join(scratch, "stray-sleep.pid");
		const endedFile = join(scratch, "stray-leader.pid");
		const strayGate = join(scratch, "stray.gate");
		const holder = `'${process.execPath}' -e '${LONG_WAIT}' 19<&-`;
		const { id: strayer } = await third.call("agents.save", {
			agent: {
				name: "Strayer",
				access: "full",
				cwd: tooling,
				setup: `${holder} & echo $! > '${strayFile}'; env -u ${RUN_VARIABLE} ${LONG_SLEEP} & echo $! > '${strayingSleepFile}'; echo $$ > '${endedFile}'; while [ ! -e '${strayGate}' ]; do sleep 0.1; done`,
			},
		});
		const { id: l } = await third.call("conversation.create", { agentId: strayer });
		await third.call("worktree.create", { id: l });
		const [ended, stray, straySleep] = await third.until("set-up running", () => {
			const read = (file: string) => (existsSync(file) ? Number(readFileSync(file, "utf8").trim()) : 0);
			return read(endedFile) > 0 && read(strayFile) > 0 && read(strayingSleepFile) > 0 ? [read(endedFile), read(strayFile), read(strayingSleepFile)] : undefined;
		});
		holders.push(stray);
		sleepers.push(straySleep);
		await until("the set-up's process group noted", () => logged.some((line) => line.includes(`set-up for conversation ${l} runs as process group ${ended}`)));
		await stop(engine, "SIGKILL");
		writeFileSync(strayGate, "");
		await until("the command's first process ended", () => !alive(ended));
		assert.ok(alive(stray) && alive(straySleep), "what the set-up started in the background outlives it and the engine");
		engine = startEngine();
		const fourth = await Client.connect(engine, home);
		await fourth.call("conversation.open", { id: l });
		const strayed = await fourth.until("marked", () => fourth.conversations.get(l)?.items.find((item: Event) => item.kind === "setup" && item.details.status !== "running"));
		assert.equal(strayed.details.reason, "was left running when pi²’s engine stopped, and was stopped when the engine started again");
		await fourth.until("what was left without its leader is stopped", () => !alive(stray));
		await fourth.until("the `sleep` that only had the run's file open too", () => !alive(straySleep));
		assert.deepEqual(
			(await fourth.until("recovery event", () => fourth.events.recovery)).recovery?.setups.map((left: Event) => [left.conversationId, left.outcome, left.group]),
			[[l, "stopped", ended]],
			"the notice names only the set-up this engine found",
		);
		step("what a set-up started in the background, left running after its first process ended and the engine was killed, is stopped by the next engine, by its environment or by the run's file");

		// A number that now belongs to another process, or members of a group whose leader is gone, are left alone.
		const other = spawn("/bin/sleep", ["30"], { detached: true, stdio: "ignore" });
		other.unref();
		assert.equal(await stopLeftOver({ group: other.pid!, start: "Thu Jan 1 00:00:00 1970" }, 100), "gone");
		await sleep(300);
		assert.ok(alive(other.pid!), "a process that got the same number, but started at another time, is not touched");
		process.kill(other.pid!);
		const orphaning = spawn("/bin/bash", ["-c", "sleep 30 & echo $!"], { detached: true, stdio: ["ignore", "pipe", "ignore"] });
		let printed = "";
		let exited = false;
		orphaning.stdout!.on("data", (chunk) => (printed += chunk));
		orphaning.once("exit", () => (exited = true));
		await until("leader gone, member left", () => exited && printed.includes("\n"));
		orphaning.stdout!.destroy();
		const member = Number(printed.trim());
		assert.ok(member > 0 && alive(member), printed);
		assert.equal(await stopLeftOver({ group: orphaning.pid!, start: "anything" }, 100), "unsure");
		await sleep(300);
		assert.ok(alive(member), "a group left without its leader is not touched");
		process.kill(member);
		step("a left-over process number now used by another process, or a group whose leader is gone, is not touched");

		// With a marker recorded, each member of a group left without its leader is known by the marker in its environment,
		// and by nothing else. `orphans` starts a group whose first process ends at once, leaving node processes that print
		// their own pid when they are up (`waiting`), and answers with the group and those pids, in the order printed. A
		// variable given as undefined is one the group starts without.
		const marker = newRunMarker();
		const waiting = (before = "") => `'${process.execPath}' -e '${before}console.log(process.pid); ${LONG_WAIT}'`;
		const orphans = async (script: string, env: Record<string, string | undefined>, count = 1, run?: NewRun) => {
			// With a run, started with its file open, as the engine starts a command (`newRun`).
			const stdio = run === undefined ? ["ignore", "pipe", "ignore"] : (run.stdio as unknown[]).map((each, i) => (i === 2 ? "ignore" : each));
			const first = spawn("/bin/bash", ["-c", script], { detached: true, env: { ...process.env, ...env }, stdio: stdio as StdioOptions });
			let out = "";
			let over = false;
			first.stdout!.on("data", (chunk) => (out += chunk));
			first.once("exit", () => (over = true));
			await until("leader gone, members up", () => over && out.trim().split("\n").length === count && out.endsWith("\n"));
			first.stdout!.destroy();
			const pids = out.trim().split("\n").map(Number);
			holders.push(...pids);
			assert.ok(pids.every((pid) => pid > 0 && alive(pid)) && !alive(first.pid!), out);
			return { group: first.pid!, pids };
		};
		const stopAll = (pids: number[]) => pids.forEach((pid) => process.kill(pid, "SIGKILL"));

		let left = await orphans(`${waiting()} &`, { [RUN_VARIABLE]: marker });
		assert.equal(await stopLeftOver({ group: left.group, start: "anything", marker }, 100), "stopped");
		await until("the member with the marker is stopped", () => !alive(left.pids[0]!));
		// One that takes no notice of SIGTERM is killed after the grace.
		left = await orphans(`${waiting('process.on("SIGTERM", () => {}); ')} &`, { [RUN_VARIABLE]: marker });
		assert.equal(await stopLeftOver({ group: left.group, start: "anything", marker }, 1_000), "stopped");
		await sleep(300);
		assert.ok(alive(left.pids[0]!), "it took no notice of SIGTERM");
		await until("the member that ignored SIGTERM is killed", () => !alive(left.pids[0]!));
		step("a member left without its leader that carries the run's marker is stopped, and killed if it ignores that");

		// Look-alikes: a group of the same number whose member has no marker, another run's, the marker only in its
		// arguments, or the marker in a variable of another name. A record from before there were markers, or one whose
		// marker is not one pi² makes, proves nothing either, whatever the member carries.
		const lookAlikes: [string, { group: number; pids: number[] }, string | undefined][] = [
			["no marker", await orphans(`${waiting()} &`, { [RUN_VARIABLE]: undefined }), marker],
			["another run's marker", await orphans(`${waiting()} &`, { [RUN_VARIABLE]: newRunMarker() }), marker],
			["the marker in its arguments", await orphans(`${waiting()} ${RUN_VARIABLE}=${marker} &`, { [RUN_VARIABLE]: undefined }), marker],
			["the marker in a variable of another name", await orphans(`${waiting()} &`, { [RUN_VARIABLE]: undefined, [`NOT_${RUN_VARIABLE}`]: marker }), marker],
			["a record without a marker", await orphans(`${waiting()} &`, { [RUN_VARIABLE]: marker }), undefined],
			["a marker pi² would not make", await orphans(`${waiting()} &`, { [RUN_VARIABLE]: "short" }), "short"],
		];
		for (const [what, alike, recorded] of lookAlikes) {
			assert.equal(await stopLeftOver({ group: alike.group, start: "anything", ...(recorded === undefined ? {} : { marker: recorded }) }, 100), "unsure", what);
		}
		await sleep(400);
		for (const [what, alike] of lookAlikes) assert.ok(alive(alike.pids[0]!), `a member with ${what} is not touched`);
		stopAll(lookAlikes.flatMap(([, alike]) => alike.pids));
		step("a look-alike group without the run's marker in its environment is not touched");

		// A group with both: the member with the marker is stopped, the one started without it is left, and the answer says
		// that part was stopped and part left.
		left = await orphans(`${waiting()} & sleep 1; env -u ${RUN_VARIABLE} ${waiting()} &`, { [RUN_VARIABLE]: marker }, 2);
		assert.equal(await stopLeftOver({ group: left.group, start: "anything", marker }, 100), "partly");
		await until("the member with the marker is stopped", () => !alive(left.pids[0]!));
		await sleep(400);
		assert.ok(alive(left.pids[1]!), "the member without the marker is not touched");
		stopAll([left.pids[1]!]);
		// A number that went to a new process means the old group ended: with or without a marker recorded, nothing of it is left.
		const reused = spawn(process.execPath, ["-e", "setTimeout(() => {}, 30000)"], { detached: true, stdio: "ignore" });
		reused.unref();
		assert.equal(await stopLeftOver({ group: reused.pid!, start: "Thu Jan 1 00:00:00 1970", marker }, 100), "gone");
		await sleep(300);
		assert.ok(alive(reused.pid!), "a process that got the same number is not touched, marker recorded or not");
		process.kill(reused.pid!, "SIGKILL");
		step("in a group with both, only the member that carries the marker is stopped; a number that went to a new process is still not touched");

		// The run's file, beside the marker: a member left without its leader that has the file its run was started with open
		// is the run's, whatever its environment shows. The programs that come with macOS, whose environment cannot be read,
		// are known by it: `sleep` (one ignoring SIGTERM, as `stubborn()` in test/background.ts does), `/bin/sh` and what it
		// runs, and perl, all without the marker in their environment.
		useRunFolder(join(home, "test-runs"));
		{
			const folder = join(home, "test-runs");
			const live = newRun();
			const file = (marker: string) => join(folder, marker);
			const empty = () => {
				const marker = newRunMarker();
				closeSync(openSync(file(marker), constants.O_RDONLY | constants.O_CREAT | constants.O_EXCL, 0o000));
				return marker;
			};
			const stale = empty();
			const changed = empty();
			chmodSync(file(changed), 0o600);
			const nonempty = newRunMarker();
			writeFileSync(file(nonempty), "not a run file", { mode: 0o000 });
			const link = newRunMarker();
			symlinkSync(file(stale), file(link));
			writeFileSync(join(folder, "not-a-marker"), "", { mode: 0o000 });
			const directory = newRunMarker();
			mkdirSync(file(directory));
			// An unrecorded command left by a dead engine: no engine holds this file now, but a system program does.
			const held = newRunMarker();
			const fd = openSync(file(held), constants.O_RDONLY | constants.O_CREAT | constants.O_EXCL, 0o000);
			const stdio = ["ignore", "ignore", "ignore", ...Array(16).fill("ignore"), fd] as StdioOptions;
			const child = spawn("/bin/sleep", [String(2 * PATIENT_MS / 1000)], { detached: true, stdio });
			closeSync(fd);
			sleepers.push(child.pid!);
			try {
				await sweepRuns();
				assert.equal(existsSync(file(stale)), false, "an empty unheld orphan is removed");
				for (const marker of [live.marker, held, changed, nonempty, link, directory, "not-a-marker"]) {
					// existsSync follows a symlink, whose target was just removed.
					assert.ok(marker === link ? lstatSync(file(marker)).isSymbolicLink() : existsSync(file(marker)), `not removed: ${marker}`);
				}
				assert.ok(alive(child.pid!), "cleanup never signals an unrecorded holder");
				await stop(child, "SIGKILL");
				await sweepRuns();
				assert.equal(existsSync(file(held)), false, "once its last holder ends, the file can go");
			} finally {
				await stop(child, "SIGKILL");
				forgetRun(live.marker);
			}
			step("run-file cleanup keeps live runs, unrecorded holders and look-alike files, and never signals a process");

			const uncertain = empty();
			const original = childProcess.execFile;
			try {
				for (const [code, stdout, stderr] of [[2, "", ""], [1, "", "cannot inspect"], [0, "unreadable fields\n", ""], ["ENOENT", "", ""]] as const) {
					(childProcess as { execFile: unknown }).execFile = (_file: string, _args: string[], _options: unknown, callback: (error: unknown, stdout: string, stderr: string) => void) => {
						callback(code === 0 ? null : { code }, stdout, stderr);
					};
					syncBuiltinESMExports();
					await sweepRuns();
					assert.ok(existsSync(file(uncertain)), "a failed, diagnostic or unreadable lsof answer never removes a file");
				}
			} finally {
				childProcess.execFile = original;
				syncBuiltinESMExports();
			}
			forgetRun(uncertain);
			step("run-file cleanup fails closed when lsof fails or its answer is uncertain");
		}
		const system = (run?: NewRun) => orphans(`trap '' TERM; ${LONG_SLEEP} & echo $!; trap - TERM; ${SH_SLEEP} & echo $!; ${PERL_SLEEP} & echo $!`, { [RUN_VARIABLE]: undefined }, 3, run);
		const groupOf = (group: number) => [...execFileSync("/bin/ps", ["-A", "-o", "pid=,pgid="], { encoding: "utf8" }).matchAll(/^\s*(\d+)\s+(\d+)\s*$/gm)].filter((m) => Number(m[2]) === group).map((m) => Number(m[1]));
		const given = newRun();
		const runFile = join(home, "test-runs", given.marker);
		left = await system(given);
		assert.throws(() => openSync(runFile, "r"), /EACCES/, "nothing can open a run's file once it is made, the person's own processes included");
		assert.equal(await stopLeftOver({ group: left.group, start: "anything", marker: given.marker }, 1_000), "stopped");
		await sleep(300);
		assert.ok(alive(left.pids[0]!), "the `sleep` that ignores SIGTERM is still there until the grace is over");
		await until("every member with the run's file, `sleep`, `sh` and perl, is stopped", () => groupOf(left.group).length === 0);
		assert.equal(existsSync(runFile), false, "a run's file goes once its record has been dealt with");
		step("macOS's own programs left without their leader (`sleep`, `/bin/sh`, perl) are stopped when they have the run's file open, and one that ignores SIGTERM is killed");

		// What only looks like the run's is never signalled: a member with another run's file open; with the run's file open
		// once it has been replaced by another of the same name, or had its permissions changed; or once it is gone. And a
		// process with the run's file open in another group is not of the group on record.
		const replaced = newRun();
		const changed = newRun();
		const gone = newRun();
		const unheld = newRun();
		const fileLookAlikes: [string, { group: number; pids: number[] }, string][] = [
			["another run's file", await system(newRun()), unheld.marker],
			["a file replaced by another of the same name", await system(replaced), replaced.marker],
			["a file whose permissions were changed", await system(changed), changed.marker],
			["a file that is gone", await system(gone), gone.marker],
		];
		const replacedFile = join(home, "test-runs", replaced.marker);
		rmSync(replacedFile);
		closeSync(openSync(replacedFile, constants.O_RDONLY | constants.O_CREAT | constants.O_EXCL, 0o000));
		chmodSync(join(home, "test-runs", changed.marker), 0o600);
		rmSync(join(home, "test-runs", gone.marker));
		// A `sleep` of its own group that has the run's file open, beside a group of the number on record that has nothing.
		const elsewhere = newRun();
		const apart = spawn("/bin/sleep", [String((2 * PATIENT_MS) / 1000)], { detached: true, stdio: elsewhere.stdio });
		apart.unref();
		sleepers.push(apart.pid!);
		fileLookAlikes.push(["nothing, beside a process of another group with the run's file", await system(), elsewhere.marker]);
		for (const [what, alike, recorded] of fileLookAlikes) {
			assert.equal(await stopLeftOver({ group: alike.group, start: "anything", marker: recorded }, 100), "unsure", what);
		}
		await sleep(400);
		for (const [what, alike] of fileLookAlikes) assert.ok(alike.pids.every(alive), `a member with ${what} is not touched`);
		assert.ok(alive(apart.pid!), "a process with the run's file open in another group is not touched");
		for (const pid of [...fileLookAlikes.flatMap(([, alike]) => groupOf(alike.group)), apart.pid!]) process.kill(pid, "SIGKILL");
		step("a member with another run's file, or one replaced, changed or gone, and a process of another group with the run's file, are not touched");

		// A record no set-up could have left (1 would signal every process the person owns, 0 the engine's own group) is
		// refused before anything is looked at or signalled, and so is the engine's own pid or group.
		const ownGroup = Number(execFileSync("/bin/ps", ["-o", "pgid=", "-p", String(process.pid)], { encoding: "utf8" }).trim());
		assert.ok(ownGroup > 1, `the test's own group: ${ownGroup}`);
		const ownStart = execFileSync("/bin/ps", ["-o", "lstart=", "-p", String(process.pid)], { encoding: "utf8", env: { ...process.env, LC_ALL: "C", TZ: "UTC" } }).trim().replace(/\s+/g, " ");
		const signalled: unknown[] = [];
		const kill = process.kill;
		process.kill = ((pid: number, signal?: string | number) => {
			signalled.push([pid, signal]);
			return true;
		}) as typeof process.kill;
		try {
			for (const group of [0, 1, -1, -other.pid!, 2.5, Number.NaN, process.pid, ownGroup]) {
				assert.equal(await stopLeftOver({ group, start: ownStart }, 10), "unsure", `group ${group}`);
			}
			assert.equal(await stopLeftOver({ group: other.pid!, start: "" }, 10), "unsure", "an empty start time");
			assert.equal(await stopLeftOver({ group: "7" as unknown as number, start: ownStart }, 10), "unsure", "a number stored as text");
			await sleep(100);
		} finally {
			process.kill = kill;
		}
		assert.deepEqual(signalled, [], "nothing was signalled");
		step("a left-over record of 0, 1, a negative or fractional number, or the engine's own pid or group, is refused and signals nothing");
	}
	console.log("PASS");
} finally {
	await stop(engine);
	// Should a check have failed before they were stopped, the long sleeps of set-ups: only one still running that command.
	for (const pid of [...sleepers, ...holders]) {
		const line = spawnSync("/bin/ps", ["-o", "command=", "-p", String(pid)], { encoding: "utf8" }).stdout.trim();
		if (line === LONG_SLEEP || line.endsWith(LONG_WAIT) || [SH_SLEEP, PERL_SLEEP].some((each) => line === each.replaceAll("'", ""))) process.kill(pid, "SIGKILL");
	}
	rmSync(home, { recursive: true, force: true });
	rmSync(scratch, { recursive: true, force: true });
}
process.exit(0);
