// Worktrees and the branch tracker: reading git's state, and the engine making and removing a worktree for a
// conversation, over its socket, on a throwaway data folder and throwaway repositories.

import assert from "node:assert/strict";
import { type ChildProcess, execFileSync, spawn } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { connect, type Socket } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";
import { inspect, parseStatus, stopLeftOver, suggestBranch } from "../src/worktrees.ts";

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
		assert.ok(!(await handOff("Outsider", "/system")).answer.includes("<worktree>"), "a sub-chat elsewhere is not");
		step("a sub-chat joins its parent's worktree, and is told so, unless its agent works in another repository");

		const cwdOf = (id: number) => client.conversations.get(id)?.state.agent.cwd;
		for (const id of [helped.sub, neighboured.sub, outsided.sub]) await client.call("conversation.open", { id });
		await client.until("sub-chats open", () => cwdOf(helped.sub) === shared.path && cwdOf(neighboured.sub) === shared.path && cwdOf(outsided.sub) === outside);
		await client.call("worktree.remove", { id: e });
		await client.until("sub-chats back with their parent", () => cwdOf(e) === project && cwdOf(helped.sub) === project && cwdOf(neighboured.sub) === project);
		assert.equal(cwdOf(outsided.sub), outside, "a sub-chat elsewhere stays where it is");
		step("removing the worktree takes the sub-chats that worked in it back with their parent");
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
	const { id: setter } = await client.call("agents.save", {
		agent: { name: "Setter", access: "full", cwd: tooling, worktree: true, setup: "  sleep 2; echo installing; mkdir -p deps; echo once >> deps/runs; echo a-warning >&2  " },
	});
	const { id: e } = await client.call("conversation.create", { agentId: setter });
	await client.call("conversation.open", { id: e });
	await client.until("set-up shown as running", () => setups(e)[0]?.details.status === "running");
	assert.equal(ended(e), undefined, "the command takes a while");
	// The first message, sent while the set-up runs, waits for it.
	await client.call("submit", { id: e, text: "/system" });
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
	assert.equal(done.details.command, "sleep 2; echo installing; mkdir -p deps; echo once >> deps/runs; echo a-warning >&2", "the command is kept as typed, trimmed");
	assert.equal(done.isError, false);
	assert.match(done.details.output, /installing\n/);
	assert.match(done.details.output, /a-warning/, "errors are shown with the output");
	assert.match(done.text, /^The set-up command finished/);
	assert.match(answered.at(-1).text, /ran the set-up command[^]*`sleep 2; echo installing[^]*It finished without errors/, "the agent is told it ran");
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
	assert.match(failed.text, /^The set-up command exited with code 3/);
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
	const { id: manual } = await client.call("agents.save", { agent: { name: "Manual", access: "full", cwd: tooling, setup: `sleep 30 & echo $! > '${pidFile}'; wait` } });
	const { id: g } = await client.call("conversation.create", { agentId: manual });
	await client.call("conversation.open", { id: g });
	await sleep(300);
	assert.equal(setups(g).length, 0, "no worktree, no set-up");
	await client.call("worktree.create", { id: g });
	await client.until("set-up running", () => setups(g)[0]?.details.status === "running" && existsSync(pidFile) && readFileSync(pidFile, "utf8").trim() !== "");
	const sleeper = Number(readFileSync(pidFile, "utf8"));
	const madeAt = await client.until("tracked", () => client.branch(g)?.managed === true && client.branch(g).root);
	const removing = Date.now();
	await client.call("worktree.remove", { id: g });
	assert.ok(Date.now() - removing < 10_000, "removing does not wait for the command to finish");
	const stopped = await client.until("set-up stopped", () => ended(g));
	assert.equal(stopped.details.reason, "was stopped because the worktree was removed");
	assert.equal(existsSync(madeAt), false, "the worktree is gone");
	const gone = () => {
		try {
			process.kill(sleeper, 0);
			return false;
		} catch {
			return true;
		}
	};
	await client.until("what the command started was stopped too", gone, 5_000);
	step("a worktree made from the app runs the agent's set-up; removing it mid-run stops the command and everything it started");

	// Its folder deleted by hand: shown as missing, and removing it tidies up.
	rmSync(client.branch(d).root, { recursive: true, force: true });
	await client.call("branches.refresh");
	await client.until("missing", () => client.branch(d)?.state === "missing");
	await client.call("worktree.remove", { id: d });
	await client.until("back in the agent's folder", () => client.branch(d)?.managed === false);
	assert.ok(!run(project, "worktree", "list").includes(`pi2/builder-${d}`), "git forgot the deleted worktree");
	step("a worktree deleted by hand shows as missing; removing it lets git forget it");

	// A set-up still running when the engine stops is stopped with it, and said to be cut off when it starts again.
	rmSync(pidFile, { force: true });
	const { id: h } = await client.call("conversation.create", { agentId: manual });
	await client.call("worktree.create", { id: h });
	await client.until("set-up started", () => existsSync(pidFile) && readFileSync(pidFile, "utf8").trim() !== "");
	const orphan = Number(readFileSync(pidFile, "utf8"));

	// The worktree's record outlives a restart.
	engine.kill("SIGTERM");
	await new Promise((resolve) => engine.once("exit", resolve));
	engine = spawn(process.execPath, [main], { env: { ...process.env, PI2_HOME: home, PI2_KEYCHAIN_SERVICE: "dev.pi2.credentials.test-worktrees" }, stdio: ["ignore", "ignore", "inherit"] });
	const again = await Client.attach();
	await again.until("worktree remembered", () => again.branch(c)?.managed === true);
	step("after a restart the worktree is still known as the conversation's own");
	assert.throws(() => process.kill(orphan, 0), "stopping the engine stopped the set-up");
	await again.call("conversation.open", { id: h });
	const cut = await again.until("cut off", () => again.conversations.get(h)?.items.find((item: Event) => item.kind === "setup" && item.details.status !== "running"));
	assert.equal(cut.details.reason, "was cut off when pi²’s engine stopped");
	assert.match(await again.bash(h, "echo after-restart"), /after-restart/);
	step("a set-up running when the engine stops is stopped with it, and shown as cut off after a restart");

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
		const alive = (pid: number) => {
			try {
				process.kill(pid, 0);
				return true;
			} catch {
				return false;
			}
		};
		const leaderFile = join(scratch, "left.pid");
		const childFile = join(scratch, "left-child.pid");
		const { id: lingerer } = await again.call("agents.save", { agent: { name: "Lingerer", access: "full", cwd: tooling, setup: `sleep 120 & echo $! > '${childFile}'; echo $$ > '${leaderFile}'; wait` } });
		const { id: k } = await again.call("conversation.create", { agentId: lingerer });
		await again.call("worktree.create", { id: k });
		const [leader, started] = await again.until("set-up running", () => {
			const read = (file: string) => (existsSync(file) ? Number(readFileSync(file, "utf8").trim()) : 0);
			return read(leaderFile) > 0 && read(childFile) > 0 ? [read(leaderFile), read(childFile)] : undefined;
		});
		// The engine notes the command's process group just after starting it.
		await sleep(1_000);
		engine.kill("SIGKILL");
		await new Promise((resolve) => engine.once("exit", resolve));
		assert.ok(alive(leader) && alive(started), "an engine killed outright does not stop the set-up");
		engine = spawn(process.execPath, [main], { env: { ...process.env, PI2_HOME: home, PI2_KEYCHAIN_SERVICE: "dev.pi2.credentials.test-worktrees" }, stdio: ["ignore", "ignore", "inherit"] });
		const third = await Client.attach();
		await third.call("conversation.open", { id: k });
		const cut = await third.until("marked", () => third.conversations.get(k)?.items.find((item: Event) => item.kind === "setup" && item.details.status !== "running"));
		assert.equal(cut.details.reason, "was left running when pi²’s engine stopped, and was stopped when the engine started again");
		await third.until("what was left running is stopped", () => !alive(leader) && !alive(started), 10_000);
		step("a set-up left running by an engine killed outright is stopped by the next engine, with what it started, and marked");

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
		await third.until("leader gone, member left", () => exited && printed.includes("\n"));
		orphaning.stdout!.destroy();
		const member = Number(printed.trim());
		assert.ok(member > 0 && alive(member), printed);
		assert.equal(await stopLeftOver({ group: orphaning.pid!, start: "anything" }, 100), "unsure");
		await sleep(300);
		assert.ok(alive(member), "a group left without its leader is not touched");
		process.kill(member);
		step("a left-over process number now used by another process, or a group whose leader is gone, is not touched");
	}
	console.log("PASS");
} finally {
	engine.kill("SIGTERM");
	await sleep(300);
	rmSync(home, { recursive: true, force: true });
	rmSync(scratch, { recursive: true, force: true });
}
process.exit(0);
