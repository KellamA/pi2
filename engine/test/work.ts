// The built-in work list, driven through a real engine with a throwaway home and the scripted demo model.
import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { BACKGROUND_CONTEXT as context } from "@earendil-works/chord/context";
import { createModels } from "@earendil-works/pi-ai";
import { createRegistry, Harness } from "@earendil-works/pi-durable";
import { openNodeSqliteStorage } from "@earendil-works/pi-durable/storage/sqlite/node";
import { DEFAULT_ORCHESTRATOR, PREVIEW_OFF, PROJECT_ARCHIVED, Projects } from "../src/projects.ts";
import { Agents } from "../src/state.ts";
import { recordWork, Work, type WorkItem } from "../src/work.ts";
import { EngineClient, previewOnLeavingOut, standInApp, stop } from "./patience.ts";

const home = mkdtempSync(join(tmpdir(), "pi2-work-"));
const service = `dev.pi2.credentials.test-work-${process.pid}`;
// A stand-in gh (gh-stand-in.mjs) that knows no repository: the project with one attached is never read from GitHub.
const ghFolder = mkdtempSync(join(tmpdir(), "pi2-work-gh-"));
writeFileSync(join(ghFolder, "state.json"), JSON.stringify({ repos: {} }));
writeFileSync(join(ghFolder, "gh"), `#!/bin/sh\nGH_STAND_IN_STATE='${join(ghFolder, "state.json")}' exec '${process.execPath}' '${join(import.meta.dirname, "gh-stand-in.mjs")}' "$@"\n`, { mode: 0o755 });
// A folder of its own for the git repositories assignments are given worktrees of (#596).
const repos = realpathSync(mkdtempSync(join(tmpdir(), "pi2-work-repos-")));
const env = { ...process.env, PI2_HOME: home, PI2_KEYCHAIN_SERVICE: service, PI2_LOGIN_SHELL: "off", PI2_DEMO_TOKENS_PER_SECOND: "100000", PI2_APP_BUNDLE: standInApp(), PI2_GH: join(ghFolder, "gh") };
const start = () => spawn(process.execPath, [join(import.meta.dirname, "../src/main.ts")], { env, stdio: ["ignore", "ignore", "inherit"] });
let engine = start();
process.on("exit", () => {
	if (engine.exitCode === null && engine.signalCode === null) engine.kill("SIGKILL");
	rmSync(home, { recursive: true, force: true });
	rmSync(ghFolder, { recursive: true, force: true });
	rmSync(repos, { recursive: true, force: true });
	try {
		while (true) execFileSync("/usr/bin/security", ["delete-generic-password", "-s", service], { stdio: "ignore" });
	} catch { /* None left. */ }
});

class Client extends EngineClient {
	order: string[] = [];
	override receive(message: any): void {
		if (typeof message.event === "string") this.order.push(message.event);
		super.receive(message);
	}
	async tool(id: number, action: string, args: Record<string, unknown> = {}) {
		const results = () => this.conversations.get(id)?.items.filter((item: any) => item.kind === "tool" && item.name === "work") ?? [];
		const before = results().length;
		await this.call("submit", { id, text: `/tool work ${JSON.stringify({ action, ...args })}` });
		return this.until(`work ${action} in ${id}`, () => !this.conversations.get(id)?.state.busy && results().length > before && results().at(-1));
	}
	async offered(id: number) {
		const answers = () => this.conversations.get(id)?.items.filter((item: any) => item.kind === "assistant") ?? [];
		const before = answers().length;
		await this.call("submit", { id, text: "/system full" });
		const answer = await this.until(`tools in ${id}`, () => !this.conversations.get(id)?.state.busy && answers().length > before && answers().at(-1).text);
		return JSON.parse(answer.slice(5)).tools.some((tool: { name: string }) => tool.name === "work");
	}
}

let client: Client | undefined;
let peer: Client | undefined;
const offline = async (edit: (harness: Harness) => Promise<void>) => {
	client?.close();
	peer?.close();
	await stop(engine);
	const storage = await openNodeSqliteStorage(join(home, "session.sqlite"));
	const harness = await Harness.open(storage, { registry: createRegistry(), models: createModels() }, context);
	try {
		await edit(harness);
	} finally {
		await harness.close(context);
	}
	engine = start();
	client = await Client.connect(engine, home);
};
const step = (text: string) => console.log(`ok  ${text}`);
const value = (tool: { isError: boolean; text: string }) => {
	assert.equal(tool.isError, false, tool.text);
	return JSON.parse(tool.text);
};
const refusal = (tool: { isError: boolean; text: string }, why: RegExp) => {
	assert.equal(tool.isError, true, tool.text);
	assert.match(tool.text, why);
};

try {
	client = await Client.connect(engine, home);
	assert.deepEqual(await client.until("greetings", () => client!.events.work), { event: "work", projects: {} });
	assert.ok(client.order.indexOf("projects") < client.order.indexOf("work"));
	for (const method of ["work.list", "work.create", "work.act"]) await assert.rejects(client.call(method), { message: PREVIEW_OFF });
	// A conversation in no project: with the preview on, one whose project was deleted, since carrying over puts every
	// other in one (#458; `previewOnLeavingOut`).
	const { id: plain } = await client.call("conversation.create", { agentId: "forge" });
	await previewOnLeavingOut(client);
	const { id: projectId, conversation: parent }: { id: string; conversation: number } = await client.call("projects.create", { folder: null, name: "Local" });
	const { id: other } = await client.call("projects.create", { folder: null, name: "Other" });
	const { id: github } = await client.call("projects.create", { folder: null, name: "GitHub" });
	await offline(async (harness) => {
		assert.equal(await harness.snapshot(Work, context), undefined, "no work document before the first file");
		// Keep stable worker IDs in this test. #468 will attach a repo; seed it only in this test's own database.
		await harness.commit(async (tx) => {
			const { memory: _, ...settings } = DEFAULT_ORCHESTRATOR;
			(await tx.doc(Agents)).agents.worker = { ...settings, id: "worker", name: "Worker", projectId, cwd: null, createdAt: 1, access: "full", instructions: "", model: { provider: "demo", modelId: "demo-1" } };
			(await tx.doc(Projects)).projects[github]!.repository = { owner: "example", name: "unread" };
		}, context);
	});
	const socket = client;
	const call = (name: string, params: Record<string, unknown> = {}) => socket.call(`work.${name}`, { projectId, ...params });
	const create = async (title: string, args: Record<string, unknown> = {}): Promise<number> => (await call("create", { title, ...args })).id;
	const act = async (id: number, action: string, args: Record<string, unknown> = {}) => call("act", { id, action, ...args });
	const list = async (args?: Record<string, unknown>): Promise<WorkItem[]> => (await call("list", args)).items;
	const show = async (id: number) => (await list()).find((item) => item.id === id)!;
	const { id: worker } = await socket.call("conversation.create", { agentId: "worker" });
	await Promise.all([parent, worker, plain].map((id) => socket.call("conversation.open", { id })));
	assert.equal(await socket.offered(parent), true);
	assert.equal(await socket.offered(worker), true);
	assert.equal(await socket.offered(plain), false);
	// The child's first turn must follow its parent, rather than gaining work from the target profile.
	// #457 also filters project workers out of ordinary delegation.
	await socket.call("agents.save", { agent: { id: "forge", name: "Forge", delegates: ["worker"] } });
	await socket.call("submit", { id: plain, text: "/delegate Worker: /system full" });
	const handoff = await socket.until("out-of-project delegation", () => !socket.conversations.get(plain)?.state.busy && socket.conversations.get(plain)?.items.find((item: any) => item.kind === "tool" && item.name === "delegate"));
	if (!handoff.isError) {
		await socket.call("conversation.open", { id: handoff.details.conversationId });
		const initial = await socket.until("first answer in the child", () => socket.conversations.get(handoff.details.conversationId)?.items.find((item: any) => item.kind === "assistant")?.text);
		assert.equal(JSON.parse(initial.slice(5)).tools.some((tool: { name: string }) => tool.name === "work"), false);
	}
	assert.deepEqual(await call("list"), { items: [], readAt: null });
	// The project with a repository attached is GitHub's (#468): never the list kept by pi² instead.
	await assert.rejects(call("list", { projectId: github }), /GitHub refused it: .*Could not resolve to a Repository/);
	await assert.rejects(call("create", { projectId: github, title: "No fallback" }), /Could not resolve to a Repository/);
	await assert.rejects(call("list", { projectId: "__proto__" }), /Unknown project/);
	await assert.rejects(create(" "), /1 to 200/);
	await assert.rejects(create("a".repeat(201)), /1 to 200/);
	await assert.rejects(create("Too much", { text: "a".repeat(20_001) }), /20,000/);
	await assert.rejects(call("list", { states: ["all"] }), /states must/);
	refusal(await socket.tool(parent, "pull_request"), /kept by pi², which has no pull requests/);
	step("preview, greeting order, project-only tools, validation, and no GitHub fallback");

	const id = await create("  Race  ", { text: "Work description", class: "local" });
	assert.equal(id, 1);
	assert.equal((await call("create", { projectId: other, title: "Independent" })).id, 1);
	const first = await show(id);
	assert.deepEqual(first, { id, title: "Race", text: "Work description", state: "open", class: "local", takenBy: null, notes: [], result: null, filedBy: { kind: "person" }, createdAt: first.createdAt, updatedAt: first.createdAt, closedAt: null });
	peer = await Client.connect(engine, home);
	await peer.until("saved work in the greeting", () => peer?.events.work?.projects[projectId]?.length === 1);
	const [a, b] = await Promise.all([socket.tool(parent, "take", { id }), socket.tool(worker, "take", { id })]);
	assert.notEqual(a.isError, b.isError, "exactly one gets the item");
	const { takenBy: holder } = value(a.isError ? b : a);
	const winner = a.isError ? worker : parent;
	const loser = a.isError ? parent : worker;
	assert.equal(holder.conversationId, winner);
	assert.equal((a.isError ? a : b).text, `#${id} is taken by ${winner === parent ? "Orchestrator" : "Worker"}, in sub-chat ${winner}`);
	await peer.until("the other app sees the winner", () => peer?.events.work?.projects[projectId]?.[0]?.takenBy?.conversationId === winner);
	refusal(await socket.tool(loser, "wait", { id }), /Only the holder/);
	assert.equal(value(await socket.tool(winner, "wait", { id, text: "Waiting for a response" })).state, "waiting");
	// Taking what it holds is no error, and says how to go on (#604).
	const mine = await socket.tool(winner, "take", { id });
	assert.equal(mine.isError, false, mine.text);
	assert.match(mine.text, new RegExp(`^#${id} is yours already, and waiting: use resume to go on\\.\\n\\n\\{`));
	assert.equal(value(await socket.tool(winner, "block", { id, text: "Blocked on the response" })).state, "blocked");
	assert.equal((await act(id, "resume")).item.state, "in_progress");
	assert.deepEqual((await show(id)).takenBy, holder);
	assert.equal(value(await socket.tool(loser, "note", { id, text: "I can leave a note too" })).notes.length, 3);
	await assert.rejects(act(id, "finish", { text: "not the person" }), /person cannot use finish/);
	const done = value(await socket.tool(winner, "finish", { id, text: "Checked the result" }));
	assert.deepEqual([done.state, done.takenBy, done.result], ["done", null, "Checked the result"]);
	assert.equal(typeof done.closedAt, "number");
	refusal(await socket.tool(loser, "take", { id }), /#1 is done\. Reopen it first\./);
	// `list` and `show` answer in plain lines, never the item whole (#595).
	const empty = await socket.tool(worker, "list");
	assert.equal(empty.isError, false, empty.text);
	assert.equal(empty.text, "0 items.");
	const closed = await socket.tool(worker, "list", { states: ["done"] });
	assert.match(closed.text, new RegExp(`^#${id} done · local model · nobody · changed .+ · Race$`, "m"));
	assert.match(closed.text, /^1 item: 1 done\.$/m);
	const shown = await socket.tool(worker, "show", { id });
	assert.match(shown.text, new RegExp(`^#${id} done .* · Race$`, "m"));
	assert.match(shown.text, /Work description/, "the item's own text");
	assert.match(shown.text, /Done: Checked the result/);
	const reopened = (await act(id, "reopen")).item;
	assert.deepEqual([reopened.state, reopened.result, reopened.closedAt], ["open", null, null]);
	assert.equal(value(await socket.tool(worker, "take", { id })).state, "in_progress");
	assert.equal(value(await socket.tool(parent, "release", { id })).takenBy, null);
	assert.equal((await act(id, "edit", { title: "Edited", text: "New description" })).item.text, "New description");
	assert.equal((await act(id, "classify", { class: "cloud" })).item.class, "cloud");
	assert.equal((await act(id, "note", { text: "Person's note" })).item.notes.at(-1).by.kind, "person");
	assert.equal((await act(id, "close", { as: "dropped" })).item.state, "dropped");
	step("concurrent tools claim once, report the holder, and persist state, notes, classification and result");

	// Only the orchestrator classifies: another agent's item is filed unclassed, and told so in a line (#604).
	const unclassed = await socket.tool(worker, "file", { title: "With a class", class: "local" });
	assert.equal(unclassed.isError, false, unclassed.text);
	const [unclassedItem, unclassedLine] = unclassed.text.split("\n\n");
	assert.equal(JSON.parse(unclassedItem).class, null);
	assert.equal(unclassedLine, "Filed without a class: only the orchestrator classifies work, and it will.");
	const classed = await socket.tool(parent, "file", { title: "Classed by the orchestrator", class: "cloud" });
	assert.equal(value(classed).class, "cloud", "the orchestrator's class is kept");
	for (const item of [JSON.parse(unclassedItem).id, value(classed).id]) await act(item, "close", { as: "dropped" });

	const projectSettings = (withoutAsking: Record<string, boolean>) => socket.call("projects.set", { id: projectId, settings: { withoutAsking } });
	await socket.call("conversation.configure", { id: worker, access: "none" });
	assert.match((await socket.tool(worker, "show", { id })).text, new RegExp(`^#${id} `), "an agent with no access may still read it");
	refusal(await socket.tool(worker, "note", { id, text: "No tools" }), /access does not let it change/);
	await socket.call("conversation.configure", { id: worker, access: "read" });
	assert.equal((await socket.tool(worker, "list")).text, "0 items.");
	refusal(await socket.tool(worker, "file", { title: "Read only" }), /access does not let it change/);
	await socket.call("conversation.configure", { id: worker, access: "ask" });
	const open = await create("Assign this", { text: "Read the assignment's body" });
	refusal(await socket.tool(worker, "assign", { id: open, agent: "Worker" }), /Only the orchestrator assigns work/);
	refusal(await socket.tool(worker, "reopen", { id }), /Only the orchestrator/);
	await projectSettings({ fileWork: false, closeWork: false, startAgents: false });
	const decide = async (which: string, decision: string) => {
		const approval = await socket.until(`project switch ${which}`, () => socket.events.inbox?.items?.find((item: any) => item.projectSwitch === which));
		await socket.call("inbox.decide", { id: approval.id, decision });
	};
	const pendingFile = socket.tool(worker, "file", { title: "Filed with approval" });
	await decide("fileWork", "once");
	const filed = value(await pendingFile);
	assert.equal(filed.filedBy.agentId, "worker");
	const pendingClose = socket.tool(parent, "close", { id: filed.id, as: "done" });
	await decide("closeWork", "deny");
	refusal(await pendingClose, /person declined/);
	assert.equal((await show(filed.id)).state, "open");
	step("access levels, current orchestrator role, and project switch approvals");

	const count = () => socket.events.library?.conversations?.filter((row: any) => row.parent === parent).length ?? 0;
	const children = count();
	const before = await show(open);
	const pending = socket.tool(parent, "assign", { id: open, agent: "Worker", title: "Assigned child", task: "Extra directions" });
	await decide("startAgents", "deny");
	refusal(await pending, /person declined/);
	assert.deepEqual(await show(open), before);
	assert.equal(count(), children);
	await assert.rejects(act(open, "assign", { agentId: "forge" }), /Unknown agent: forge/);
	assert.deepEqual(await show(open), before);

	// A different tool wins while the assignment waits on the person's approval: no child or second news is created.
	const waiting = socket.tool(parent, "assign", { id: open, agent: "Worker" });
	await socket.until("assignment is asking", () => socket.events.inbox?.items?.some((item: any) => item.projectSwitch === "startAgents"));
	assert.equal(value(await socket.tool(worker, "take", { id: open })).state, "in_progress");
	await decide("startAgents", "once");
	refusal(await waiting, /is taken by Worker/);
	assert.equal(count(), children);
	await act(open, "release");
	const assign = socket.tool(parent, "assign", { id: open, agent: "Worker", title: "Assigned child", task: "Extra directions" });
	await decide("startAgents", "once");
	const handed = await assign;
	assert.equal(handed.isError, false, handed.text);
	assert.match(handed.text, /“Assigned child”, with Worker, is working on it/);
	const child = handed.details.conversationId;
	assert.deepEqual((await show(open)).takenBy, { agentId: "worker", conversationId: child });
	await socket.call("conversation.open", { id: child });
	await socket.until("child gets assignment and answers", () => socket.conversations.get(child)?.items.some((item: any) => item.kind === "assistant" && /Read the assignment's body[\s\S]*Extra directions/.test(item.text)) && !socket.conversations.get(child)?.state.busy);
	assert.match(handed.text, /Its report waits for you unread/);
	const report = await socket.until("assignment report remains unread with waking off", () => socket.events.reports?.projects[projectId]?.find((row: any) => row.conversationId === child && row.ended?.outcome === "answered"));
	assert.equal(report.work, open);
	assert.equal(report.delivered, null);
	refusal(await socket.tool(child, "assign", { id: filed.id, agent: "Worker" }), /Only the orchestrator assigns work/);
	// The assigned sub-chat that takes its own work is told it is its already (#604).
	const ownTake = await socket.tool(child, "take", { id: open });
	assert.equal(ownTake.isError, false, ownTake.text);
	assert.match(ownTake.text, new RegExp(`^#${open} is yours already: carry on\\.`));
	assert.equal(value(await socket.tool(child, "note", { id: open, text: "From its own sub-chat" })).notes.length, 1);
	const finish = socket.tool(child, "finish", { id: open, text: "Assigned work complete" });
	await decide("closeWork", "once");
	assert.equal(value(await finish).result, "Assigned work complete");
	await socket.call("projects.set", { id: projectId, settings: { wakeOnReports: true } });
	const byPerson = await act(filed.id, "assign", { agentId: "worker" });
	assert.equal(byPerson.item.takenBy.conversationId, byPerson.conversation);
	await socket.until("the second assignment wakes the orchestrator with waking on", () => socket.conversations.get(parent)?.items.some((item: any) => item.kind === "marker" && item.details?.wake?.text?.includes(`Sub-chat ${byPerson.conversation} “Filed with approval” answered:`)) && !socket.conversations.get(parent)?.state.busy);
	step("assign refuses without a claim or child, races a take, and starts a durable sub-chat for agent and person");

	// ---- A list of six long items answers in a few hundred characters an item, and `show` gives one item's words (#595)
	const long = "The whole of this piece of work, said at length. ".repeat(120);
	for (let n = 0; n < 6; n++) await create(`Backlog ${n + 1}`, { text: `${long}${n}` });
	const many = await socket.tool(worker, "list");
	assert.equal(many.isError, false, many.text);
	const lines = many.text.split("\n").filter((line: string) => /· Backlog \d+$/.test(line));
	assert.equal(lines.length, 6, many.text);
	for (const line of lines) assert.ok(line.length < 300, `a few hundred characters an item: ${line.length}\n${line}`);
	assert.ok(!many.text.includes("said at length"), "none of the text");
	assert.match(many.text, /^7 items: 6 open, 1 in progress\.$/m);
	const one = lines.find((line: string) => line.endsWith("Backlog 3"))!;
	const backlogId = Number(/#(\d+)/.exec(one)![1]);
	const showed = await socket.tool(worker, "show", { id: backlogId });
	assert.match(showed.text, /said at length/, "show gives the text");
	assert.match(showed.text, /more characters of the text; the project's Work tab shows it/, "and says where the rest is");
	assert.ok(showed.text.length < 4_500, `a cut text: ${showed.text.length}`);
	// A long item's notes come newest first, and the answer says how many more there are.
	for (let n = 0; n < 14; n++) await act(backlogId, "note", { text: `Note ${n + 1}. ${"said at length ".repeat(20)}` });
	const noted = await socket.tool(worker, "show", { id: backlogId });
	assert.match(noted.text, /^Notes \(14\), newest first:$/m);
	assert.match(noted.text, /Note 14\./, "the newest note first");
	assert.ok(!noted.text.includes("Note 1\."), "not the oldest ones");
	assert.match(noted.text, /\[2 more notes; the project's Work tab shows it\]/, "and how many more there are");
	// One note longer than a note's cut is cut itself, and says so.
	const longNote = await create("A long note", {});
	await act(longNote, "note", { text: "x".repeat(2_000) });
	assert.match((await socket.tool(worker, "show", { id: longNote })).text, /\[\+\d+ characters\]/, "a long note is cut and says so");
	step("a list of six long items stays a few hundred characters a line, and show gives one item's text and cut notes");

	// ---- An assignment in a project whose folder is a git repository gives its sub-chat a worktree (#596)
	const repo = join(repos, "widgets");
	mkdirSync(repo);
	const gitIn = (...args: string[]) =>
		execFileSync("git", ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", ...args], { cwd: repo, stdio: "pipe" }).toString().trim();
	gitIn("init", "-q", "-b", "main");
	gitIn("commit", "-q", "--allow-empty", "-m", "first");
	const demo = { provider: "demo", modelId: "demo-1" };
	const { id: repoProject, conversation: repoParent }: { id: string; conversation: number } = await socket.call("projects.create", { folder: repo, name: "Repository" });
	const { id: handId } = await socket.call("projects.addAgent", { projectId: repoProject, agent: { name: "Hand", access: "full", model: demo } });
	// An agent whose own setting gives every conversation a worktree: it gets its one, never a second.
	const { id: ownId } = await socket.call("projects.addAgent", { projectId: repoProject, agent: { name: "Own", access: "full", model: demo, worktree: true } });
	await socket.call("conversation.open", { id: repoParent });
	await socket.call("conversation.configure", { id: repoParent, access: "full" });
	const repoCall = (name: string, params: Record<string, unknown> = {}) => socket.call(`work.${name}`, { projectId: repoProject, ...params });
	const repoItem = async (title: string, text = "") => (await repoCall("create", { title, text })).id;
	/** The worktree an assignment's answer says its sub-chat works in, checked as the checkout git made. */
	const worktreeIn = (said: string) => {
		const found = /working in a worktree of its own at (.+), on the branch (\S+)\./.exec(said) ?? /worktree of its own at (.+), on the branch (\S+)\./.exec(said);
		assert.ok(found, said);
		return { path: found![1]!, branch: found![2]! };
	};

	// With no `worktree`: a branch named for the work, and the answer says so.
	const login = await repoItem("Tidy the login form");
	const said = await socket.tool(repoParent, "assign", { id: login, agent: "Hand" });
	assert.equal(said.isError, false, said.text);
	const made = worktreeIn(said.text);
	assert.equal(made.branch, `work-${login}-tidy-the-login-form`);
	assert.ok(existsSync(made.path), made.path);
	assert.equal(gitIn("-C", made.path, "rev-parse", "--abbrev-ref", "HEAD"), made.branch);
	assert.match(said.text, /, with Hand, is working on it/);

	// `worktree` names its branch, as `delegate`'s does.
	const second = await repoItem("Fix the logout button");
	const chosen = await socket.tool(repoParent, "assign", { id: second, agent: "Hand", worktree: "logout-fix" });
	assert.equal(chosen.isError, false, chosen.text);
	assert.equal(worktreeIn(chosen.text).branch, "logout-fix");
	assert.equal(gitIn("-C", worktreeIn(chosen.text).path, "rev-parse", "--abbrev-ref", "HEAD"), "logout-fix");

	// `worktree: false` asks for the project's folder itself.
	const third = await repoItem("Read the docs");
	const here = await socket.tool(repoParent, "assign", { id: third, agent: "Hand", worktree: false });
	assert.equal(here.isError, false, here.text);
	assert.ok(!/worktree of its own/.test(here.text), here.text);
	const thirdChild = here.details.conversationId;
	await socket.until("the third sub-chat in the project's own folder", () => {
		const status = socket.events.branches?.conversations?.[String(thirdChild)];
		return status !== undefined && status.branch === "main" && status.worktree === false && status;
	});

	// An agent whose own setting is on gets its one worktree, on the branch pi² suggests, and not a second one.
	const fourth = await repoItem("Change the footer");
	const theirs = await socket.tool(repoParent, "assign", { id: fourth, agent: "Own" });
	assert.equal(theirs.isError, false, theirs.text);
	assert.match(worktreeIn(theirs.text).branch, /^pi2\//, theirs.text);

	// A worktree that cannot be made refuses the assignment, with the reason, and nothing is claimed.
	const fifth = await repoItem("Try the same branch twice");
	const twice = await socket.tool(repoParent, "assign", { id: fifth, agent: "Hand", worktree: "logout-fix" });
	assert.equal(twice.isError, true, twice.text);
	assert.match(twice.text, /^No worktree could be made for the sub-chat, so nothing was handed over: /);
	const left = (await repoCall("list")).items.find((item: any) => item.id === fifth);
	assert.deepEqual([left.state, left.takenBy], ["open", null]);

	// A folder that is not a git repository gets no worktree and no error.
	const plainFolder = join(repos, "plain");
	mkdirSync(plainFolder);
	const { id: plainProject, conversation: plainParent }: { id: string; conversation: number } = await socket.call("projects.create", { folder: plainFolder, name: "Plain" });
	const { id: plainWorker } = await socket.call("projects.addAgent", { projectId: plainProject, agent: { name: "Plain hand", access: "full", model: demo } });
	await socket.call("conversation.open", { id: plainParent });
	const plainItem = (await socket.call("work.create", { projectId: plainProject, title: "No repository here" })).id;
	const noRepo = await socket.tool(plainParent, "assign", { id: plainItem, agent: "Plain hand" });
	assert.equal(noRepo.isError, false, noRepo.text);
	assert.ok(!/worktree of its own/.test(noRepo.text), noRepo.text);
	assert.equal((await socket.call("work.list", { projectId: plainProject })).items[0].takenBy.agentId, plainWorker);
	step("assign gives its sub-chat a worktree named for the work, as asked, or none, and refuses when it cannot be made");

	// The orchestrator is told of the person's assignment at its next turn (#466), in a catch-up in front of the wake; its
	// own assignment is not news to it (#468).
	const told = (socket.conversations.get(parent)?.items ?? [])
		.filter((item: any) => item.kind === "marker" && typeof item.text === "string" && item.text.startsWith("pi² told the orchestrator what changed"))
		.flatMap((item: any) => String(item.details?.wake?.text ?? "").split("\n"))
		.filter((line: string) => /\(assign\)\.$/.test(line));
	assert.equal(told.length, 1, "the person's assignment told to the orchestrator, and not its own");
	const beforeRestart = await list();
	await socket.call("projects.setPreview", { on: false });
	assert.equal(await socket.offered(worker), false);
	await assert.rejects(call("list"), { message: PREVIEW_OFF });
	assert.deepEqual(socket.events.work.projects[projectId], beforeRestart);
	await offline(async (harness) => {
		const stored = await harness.snapshot(Projects, context);
		const news = stored?.news[projectId] ?? [];
		assert.equal(news.filter((item) => item.kind === "work" && /\(assign\)/.test(item.text)).length, 0, "and the news told is cleared");
		const item = beforeRestart[0]!;
		// #465 owns record(op): for now the unconnected operation does not even ask for another document.
		await recordWork(new Proxy({}, { get: () => { throw new Error("recordWork used the transaction before #465"); } }) as never, { projectId, by: { kind: "person" }, action: "file", before: null, after: item });
	});
	await client.until("work after restart with preview off", () => client?.events.work);
	assert.deepEqual(client.events.work.projects[projectId], beforeRestart);
	await client.call("projects.setPreview", { on: true });
	assert.deepEqual((await client.call("work.list", { projectId })).items, beforeRestart);
	await client.call("projects.archive", { id: projectId });
	assert.deepEqual((await client.call("work.list", { projectId })).items, beforeRestart);
	await assert.rejects(client.call("work.create", { projectId, title: "Archived" }), { message: PROJECT_ARCHIVED });
	await client.call("projects.delete", { id: projectId });
	await assert.rejects(client.call("work.list", { projectId }), /Unknown project/);
	step("work and news survive restart, preview off retains the event, and archived/deleted projects cannot change work");
} finally {
	peer?.close();
	client?.close();
	await stop(engine);
}
