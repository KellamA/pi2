// Work from an attached GitHub repository (#468), driven through a real engine with a throwaway home, the scripted demo
// model, and a stand-in gh (gh-stand-in.mjs) that keeps its repositories in a file and never reaches the network.
import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { BACKGROUND_CONTEXT as context } from "@earendil-works/chord/context";
import { createModels } from "@earendil-works/pi-ai";
import { createRegistry, Harness } from "@earendil-works/pi-durable";
import { openNodeSqliteStorage } from "@earendil-works/pi-durable/storage/sqlite/node";
import { Projects } from "../src/projects.ts";
import { makeScratch } from "../src/scratch.ts";
import { EngineClient, standInApp, stop, until } from "./patience.ts";

const home = mkdtempSync(join(tmpdir(), "pi2-github-"));
const ghFolder = mkdtempSync(join(tmpdir(), "pi2-github-gh-"));
const folder = realpathSync(mkdtempSync(join(tmpdir(), "pi2-github-repo-")));
const service = `dev.pi2.credentials.test-github-${process.pid}`;
const state = join(ghFolder, "state.json");
const shim = join(ghFolder, "gh");
// Each says its process id first, which `exec` keeps, so that the test can wait for the last of them to end (#707).
writeFileSync(shim, `#!/bin/sh\necho $$ >> '${state}.started'\nGH_STAND_IN_STATE='${state}' exec '${process.execPath}' '${join(import.meta.dirname, "gh-stand-in.mjs")}' "$@"\n`, { mode: 0o755 });
const empty = () => ({ defaultBranch: "main", issues: [], pulls: [], labels: [], next: 1 });
writeFileSync(state, JSON.stringify({ repos: { "example/widgets": empty(), "example/other": empty() } }));

const gitIn = (...args: string[]) => execFileSync("git", ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", ...args], { cwd: folder, stdio: "pipe" }).toString().trim();
gitIn("init", "-q", "-b", "main");
gitIn("commit", "-q", "--allow-empty", "-m", "first");
gitIn("remote", "add", "origin", "https://github.com/example/widgets.git");
gitIn("remote", "add", "fork", "git@github.com:someone/widgets.git");
gitIn("checkout", "-q", "-b", "feature");
gitIn("config", "branch.feature.remote", "origin");
gitIn("config", "branch.feature.merge", "refs/heads/feature");

const env = {
	...process.env,
	PI2_HOME: home,
	PI2_KEYCHAIN_SERVICE: service,
	PI2_LOGIN_SHELL: "off",
	PI2_DEMO_TOKENS_PER_SECOND: "100000",
	PI2_DEMO_COST: "10000",
	PI2_APP_BUNDLE: standInApp(),
	PI2_GH: shim,
};
const start = () => spawn(process.execPath, [join(import.meta.dirname, "../src/main.ts")], { env, stdio: ["ignore", "ignore", "inherit"] });
let engine = start();
const blockedPids: number[] = [];
process.on("exit", () => {
	if (engine.exitCode === null && engine.signalCode === null) engine.kill("SIGKILL");
	for (const pid of blockedPids) {
		try {
			process.kill(pid, "SIGKILL");
		} catch {
			// Gone already.
		}
	}
	for (const path of [home, ghFolder, folder]) rmSync(path, { recursive: true, force: true });
	try {
		while (true) execFileSync("/usr/bin/security", ["delete-generic-password", "-s", service], { stdio: "ignore" });
	} catch {
		// None left.
	}
});

// ---- The stand-in's repositories, read and changed as it changes them (under its lock)

type Repo = { issues: any[]; pulls: any[]; labels: { name: string }[] };
const repos = (): Record<string, Repo> => JSON.parse(readFileSync(state, "utf8")).repos;
const widgets = () => repos()["example/widgets"]!;
function changeStandIn(edit: (whole: any) => void): void {
	const lock = `${state}.lock`;
	for (;;) {
		try {
			mkdirSync(lock);
			break;
		} catch {
			if (existsSync(lock) && Date.now() - statSync(lock).mtimeMs > 10_000) rmSync(lock, { recursive: true, force: true });
		}
	}
	try {
		const whole = JSON.parse(readFileSync(state, "utf8"));
		edit(whole);
		// Whole, as the stand-in writes it: one running now reads it without the lock.
		writeFileSync(`${state}.test`, JSON.stringify(whole, null, "\t"));
		renameSync(`${state}.test`, state);
	} finally {
		rmSync(lock, { recursive: true, force: true });
	}
}
const calls = (): { args: string[] }[] => readFileSync(`${state}.log`, "utf8").trim().split("\n").map((line) => JSON.parse(line));

class Client extends EngineClient {
	order: string[] = [];
	/** The projects a `github` event has said a read is under way for (#599). */
	readingSeen = new Set<string>();
	/** Each project's `readAt`s, in the order the events said them: when each read that landed began (#903). */
	readAts = new Map<string, number[]>();
	override receive(message: any): void {
		if (typeof message.event === "string") this.order.push(message.event);
		if (message.event === "github") {
			for (const [id, one] of Object.entries<any>(message.projects ?? {})) {
				if (one.reading === true) this.readingSeen.add(id);
				const seen = this.readAts.get(id) ?? [];
				if (typeof one.readAt === "number" && seen.at(-1) !== one.readAt) this.readAts.set(id, [...seen, one.readAt]);
			}
		}
		super.receive(message);
	}
	results(id: number, name: string) {
		return this.conversations.get(id)?.items.filter((item: any) => item.kind === "tool" && item.name === name) ?? [];
	}
	/** Has the demo model call `name` with `args` in conversation `id`, and gives its result. */
	async use(id: number, name: string, args: Record<string, unknown>) {
		const before = this.results(id, name).length;
		await this.call("submit", { id, text: `/tool ${name} ${JSON.stringify(args)}` });
		return this.until(`${name} ${String(args.action)} in ${id}`, () => !this.conversations.get(id)?.state.busy && this.results(id, name).length > before && this.results(id, name).at(-1));
	}
	work(id: number, action: string, args: Record<string, unknown> = {}) {
		return this.use(id, "work", { action, ...args });
	}
	github(projectId: string) {
		return this.events.github?.projects?.[projectId];
	}
}

const step = (text: string) => console.log(`ok  ${text}`);
/** What an action answered (#636): a line saying what was done, never the item whole. */
const said = (tool: { isError: boolean; text: string }) => {
	assert.equal(tool.isError, false, tool.text);
	assert.ok(!tool.text.includes("{"), `no JSON: ${tool.text}`);
	return tool.text as string;
};
/** The number of the item a `file` answer names. */
const filedId = (tool: { isError: boolean; text: string }) => Number(/^Filed #(\d+) /.exec(said(tool))![1]);
const refusal = (tool: { isError: boolean; text: string }, why: RegExp) => {
	assert.equal(tool.isError, true, tool.text);
	assert.match(tool.text, why);
};

let client = await Client.connect(engine, home);
/** Stop the engine, look at or change its database, and start it again. */
const offline = async (edit: (harness: Harness) => Promise<void>) => {
	client.close();
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

try {
	// ---- A new data folder
	assert.deepEqual(await client.until("greetings", () => client.events.github), { event: "github", projects: {} });
	assert.ok(client.order.indexOf("work") < client.order.indexOf("github"), "github comes after work (4.4)");
	step("the empty github event, after work");

	// ---- Attaching
	const { id: projectId, conversation: parent }: { id: string; conversation: number } = await client.call("projects.create", { folder, name: "Widgets" });
	const { id: local, conversation: localParent }: { id: string; conversation: number } = await client.call("projects.create", { folder: null, name: "Local" });
	const demo = { provider: "demo", modelId: "demo-1" };
	const { id: workerId } = await client.call("projects.addAgent", { projectId, agent: { name: "Worker", access: "full", model: demo } });
	const { id: reviewerId } = await client.call("projects.addAgent", { projectId, agent: { name: "Reviewer", access: "ask", model: demo } });
	const { id: localWorkerId } = await client.call("projects.addAgent", { projectId: local, agent: { name: "Helper", access: "full", model: demo } });
	const { id: worker } = await client.call("conversation.create", { agentId: workerId });
	const { id: reviewer } = await client.call("conversation.create", { agentId: reviewerId });
	const { id: localWorker } = await client.call("conversation.create", { agentId: localWorkerId });
	for (const id of [parent, worker, reviewer, localParent, localWorker]) await client.call("conversation.open", { id });

	await assert.rejects(client.call("github.attach", { projectId: local }), /This project has no folder/);
	await assert.rejects(client.call("github.attach", { projectId, repository: "example/missing" }), /gh cannot reach example\/missing: GraphQL: Could not resolve to a Repository/);
	await assert.rejects(client.call("github.attach", { projectId, repository: "not a name" }), /owner\/name/);
	const { id: leftOver } = await client.call("work.create", { projectId, title: "Left in the list kept by pi²" });
	await assert.rejects(client.call("github.attach", { projectId }), /Close or move this project's open work first: #1 “Left in the list kept by pi²”/);
	await client.call("work.act", { projectId, id: leftOver, action: "close", as: "dropped" });

	// For an agent, attaching is a reach request (7.1), which the person allows.
	const asked = await client.use(parent, "project_settings", { action: "change", changes: { repository: "example/widgets" }, why: "The work is tracked there." });
	assert.equal(asked.isError, false, asked.text);
	assert.match(asked.text, /put to the person as n\d+/);
	const need = await client.until("the reach request", () => client.events.needs?.items?.find((item: any) => item.kind === "reach" && item.projectId === projectId));
	assert.match(need.change.summary, /repository example\/widgets \(now none\)/);
	await client.call("needs.answer", { id: need.id, answer: { kind: "reach", allow: true } });
	await client.until("the repository attached", () => client.events.projects.projects.find((row: any) => row.id === projectId)?.repository?.name === "widgets");
	const listed = await client.until("the first listing", () => client.github(projectId)?.state === "ok" && client.github(projectId));
	assert.deepEqual([listed.repository, listed.issues, listed.pulls, listed.unknown, listed.error], [{ owner: "example", name: "widgets" }, [], [], [], null]);
	assert.equal(typeof listed.readAt, "number");
	await client.call("projects.watch", { projectId, tabs: ["work"] });
	await assert.rejects(client.call("projects.watch", { projectId, tabs: ["board"] }), /tabs must be/);
	await client.call("projects.watch", { projectId: null, tabs: [] });
	step("attaching: refused without a folder, for a repository gh cannot see and over open work; an agent's request allowed by the person");

	// ---- An agent files an issue, two take it at once, and the holder opens a pull request
	// A worker's class is left for the orchestrator (#604), and the tool says so in a line after the item.
	const filedAnswer = await client.work(worker, "file", { title: "Make widgets blue", text: "They are grey.", class: "cloud" });
	// A line saying what was filed, with its new page (#636).
	assert.equal(said(filedAnswer), "Filed #1 “Make widgets blue”, not classified.\nIts page: https://github.com/example/widgets/issues/1\nFiled without a class: only the orchestrator classifies work, and it will.");
	const filed = await client.until("the filed issue listed", () => client.github(projectId)?.issues?.find((one: any) => one.id === 1));
	assert.deepEqual([filed.state, filed.class, filed.filedBy, filed.text], ["open", null, { kind: "agent", agentId: workerId, conversationId: worker }, "They are grey."]);
	const issue = widgets().issues[0];
	assert.match(issue.body, /^\*From Worker, an agent of the pi² project “Widgets”\.\*\n\nThey are grey\.\n\n<!-- pi2:[0-9a-f]{16} -->$/);
	// An agent's issue carries the `agent` label, as scripts/issue's do (#604).
	assert.deepEqual(issue.labels.map((label: any) => label.name).sort(), ["agent", "backlog"]);
	assert.deepEqual(widgets().labels.map((label) => label.name).sort(), ["agent", "backlog", "blocked", "cloud model", "in progress", "local model", "waiting"]);
	assert.equal(said(await client.work(parent, "classify", { id: 1, class: "cloud" })), "Classified #1 “Make widgets blue”: cloud model.", "the orchestrator classifies it");
	const { items, readAt } = await client.call("work.list", { projectId });
	assert.deepEqual(items.map((item: any) => item.id), [1]);
	assert.equal(typeof readAt, "number");
	const listing = await client.work(reviewer, "list");
	assert.match(listing.text, /\(GitHub's listing of example\/widgets, read /);
	assert.match(listing.text, /^1 item: 1 open\.$/m, "a line an item, a count, and no text (#595)");

	// Two take it at once, in the order that once failed on CI by luck (#928): the Worker's take is held between its claim
	// and its read-back until the Reviewer has claimed too, and the Reviewer's between its read-back and its letting go
	// until the Worker has answered. The Worker reads back both claims standing, and holds it: the earlier claim stands.
	const hold = (name: string) => client.until(`the stand-in held the ${name}`, () => (existsSync(`${state}.blocked.${name}`) ? Number(readFileSync(`${state}.blocked.${name}`, "utf8")) : undefined));
	const letGo = (name: string) => writeFileSync(`${state}.release.${name}`, "");
	changeStandIn((whole) => void (whole.block = [{ name: "worker", match: "Taken by Worker", when: "after" }, { name: "reviewer", match: "Released: Reviewer", when: "before" }]));
	const workerTake = client.work(worker, "take", { id: 1 });
	blockedPids.push(await hold("worker"));
	const reviewerTake = client.work(reviewer, "take", { id: 1 });
	// A check failing before it is awaited is what the run reports, not this wait ending with the connection.
	reviewerTake.catch(() => {});
	blockedPids.push(await hold("reviewer"));
	letGo("worker");
	assert.equal(said(await workerTake), "Took #1 “Make widgets blue”: in progress, held by you.");
	// The listing says so too while the Reviewer's claim still stands, before it lets go.
	const whileBoth = await client.until("the issue listed in progress", () => client.github(projectId)?.issues?.find((one: any) => one.id === 1 && one.state === "in_progress"));
	assert.deepEqual(whileBoth.takenBy, { agentId: workerId, conversationId: worker }, "the earlier claim holds while the later one has not let go yet");
	assert.equal(widgets().issues[0].comments.filter((comment: any) => comment.body.includes("Released")).length, 0, "the Reviewer has not let go yet");
	letGo("reviewer");
	const refused = await reviewerTake;
	assert.equal(refused.isError, true, refused.text);
	assert.equal(refused.text, `#1 is taken by Worker, in sub-chat ${worker}`);
	changeStandIn((whole) => delete whole.block);
	for (const name of ["worker", "reviewer"]) for (const end of ["blocked", "release"]) rmSync(`${state}.${end}.${name}`);
	await client.until("the holder listed", () => client.github(projectId)?.issues?.find((one: any) => one.id === 1 && one.takenBy?.agentId === workerId && one.takenBy.conversationId === worker));
	// Both claimed and the later one let go: one claim stands.
	const comments = widgets().issues[0].comments.map((comment: any) => comment.body.split("\n\n")[1]);
	assert.deepEqual(comments.map((text: string) => text.split(",")[0].split(":")[0]), ["Taken by Worker", "Taken by Reviewer", "Released"], comments.join(" / "));
	assert.deepEqual(widgets().issues[0].labels.map((label: any) => label.name).sort(), ["agent", "cloud model", "in progress"]);
	// A take that won, but reads the issue back after it changed hands, is refused, naming the holder (#928): the Worker's
	// take is held after its labels while the orchestrator lets it go and the Reviewer takes it.
	said(await client.work(parent, "release", { id: 1 }));
	changeStandIn((whole) => void (whole.block = [{ name: "late", match: "--add-label", when: "after" }]));
	const lateTake = client.work(worker, "take", { id: 1 });
	lateTake.catch(() => {});
	blockedPids.push(await hold("late"));
	changeStandIn((whole) => delete whole.block);
	said(await client.work(parent, "release", { id: 1 }));
	assert.equal(said(await client.work(reviewer, "take", { id: 1 })), "Took #1 “Make widgets blue”: in progress, held by you.");
	letGo("late");
	const late = await lateTake;
	assert.equal(late.isError, true, late.text);
	assert.equal(late.text, `#1 is taken by Reviewer, in sub-chat ${reviewer}`);
	for (const end of ["blocked", "release"]) rmSync(`${state}.${end}.late`);
	said(await client.work(reviewer, "release", { id: 1 }));
	assert.equal(said(await client.work(worker, "take", { id: 1 })), "Took #1 “Make widgets blue”: in progress, held by you.");
	// Taking what it holds already is no error (#604).
	const commentsBefore = widgets().issues[0].comments.length;
	const again = await client.work(worker, "take", { id: 1 });
	assert.equal(again.isError, false, again.text);
	assert.match(again.text, /^#1 is yours already: carry on\.\n#1 in progress · cloud model · Worker, sub-chat \d+ · changed .+ · Make widgets blue$/);
	assert.equal(widgets().issues[0].comments.length, commentsBefore, "nothing posted");
	// `show` answers in plain lines: its line, its text, and its notes (#595).
	const shown = (await client.work(reviewer, "show", { id: 1 })).text;
	assert.match(shown, /^#1 in progress · cloud model · (Worker|Reviewer), sub-chat \d+ · changed .+ · Make widgets blue$/m);
	assert.match(shown, /\n\nThey are grey\./);
	assert.ok(!shown.includes("Notes ("), "no notes yet");
	step("an agent files an issue (labels made as scripts/issue makes them), two take it at once and the earlier holds it, said so before the later lets go; a take read back after it changed hands is refused");

	const opened = await client.work(worker, "pull_request", { id: 1, title: "Blue widgets" });
	assert.equal(opened.isError, false, opened.text);
	assert.match(opened.text, /^Opened pull request #2 from feature into main: https:\/\/github\.com\/example\/widgets\/pull\/2$/);
	assert.equal(typeof opened.details?.change, "number", "a change with no Undo");
	const pr = widgets().pulls[0];
	assert.deepEqual([pr.headRefName, pr.isCrossRepository, pr.baseRefName], ["feature", false, "main"]);
	assert.match(pr.body, /Fixes #1\n\n<!-- pi2:/);
	gitIn("config", "branch.feature.remote", "fork");
	const fromFork = await client.work(worker, "pull_request", { title: "From the fork", base: "main" });
	assert.match(fromFork.text, /^Opened pull request #3 from someone:feature into main/);
	assert.deepEqual([widgets().pulls[1].headRepositoryOwner.login, widgets().pulls[1].isCrossRepository], ["someone", true]);
	gitIn("config", "branch.feature.remote", "origin");
	gitIn("checkout", "-q", "-b", "loose");
	refusal(await client.work(worker, "pull_request", { title: "Not pushed" }), /^Push the branch first: it has no upstream\.$/);
	gitIn("checkout", "-q", "feature");
	const pulls = await client.until("the pull requests listed", () => client.github(projectId)?.pulls?.length === 2 && client.github(projectId).pulls);
	const two = pulls.find((one: any) => one.number === 2);
	assert.deepEqual([two.head, two.base, two.state, two.work, two.openedBy, two.checks, two.mergeable], ["feature", "main", "open", 1, { conversationId: worker }, "none", "yes"]);
	assert.equal(pulls.find((one: any) => one.number === 3).head, "someone:feature");
	step("the holder opens a pull request that fixes it, one from a fork's branch, and none from a branch with no upstream");

	// ---- The failing checks of the roll-up are named and counted (#573)
	changeStandIn((whole) => {
		// One of each shape GitHub answers, a check run and a commit status, beside one that passed.
		whole.repos["example/widgets"].pulls[0].statusCheckRollup = [
			{ name: "build", status: "COMPLETED", conclusion: "SUCCESS", detailsUrl: "https://ci.example.invalid/build" },
			{ name: "test", status: "COMPLETED", conclusion: "FAILURE", detailsUrl: "https://ci.example.invalid/test" },
			{ context: "lint", state: "FAILURE", targetUrl: "https://ci.example.invalid/lint" },
		];
	});
	// The listing is read at most once a minute, so the orchestrator's classify of #1 as what it already is changes
	// nothing there and makes the read that brings the roll-up in.
	said(await client.work(parent, "classify", { id: 1, class: "cloud" }));
	const named = await client.until("the failing checks named", () => {
		const failing = client.github(projectId)?.pulls?.find((one: any) => one.number === 2)?.failingChecks;
		return Array.isArray(failing) && failing.length === 2 ? failing : undefined;
	});
	assert.deepEqual(named, [
		{ name: "test", url: "https://ci.example.invalid/test" },
		{ name: "lint", url: "https://ci.example.invalid/lint" },
	]);
	assert.deepEqual((client.github(projectId)?.pulls ?? []).map((one: any) => [one.number, one.checks, one.failingChecks]), [[3, "none", []], [2, "failing", named]]);
	assert.match((await client.work(reviewer, "list")).text, /^#2 pull request open · checks failing · no review · Blue widgets$/m, "a pull request's checks, in a word (#595)");
	changeStandIn((whole) => void (whole.repos["example/widgets"].pulls[0].statusCheckRollup = []));
	said(await client.work(parent, "classify", { id: 1, class: "cloud" }));
	const calmed = await client.until("none failing", () => {
		const pull = client.github(projectId)?.pulls?.find((one: any) => one.number === 2);
		return pull?.checks === "none" && pull.failingChecks?.length === 0 ? pull : undefined;
	});
	assert.deepEqual([calmed.checks, calmed.failingChecks], ["none", []]);
	step("the checks that failed are named and counted, and none failing is an empty list");

	// ---- A second agent's finding, Send back, and merging under the switch
	const found = await client.work(reviewer, "review", { id: 2, verdict: "changes", text: "Use a darker blue." });
	assert.equal(found.isError, false, found.text);
	const finding = await client.until("the finding", () => client.github(projectId)?.pulls?.find((one: any) => one.number === 2)?.findings?.[0]);
	assert.deepEqual([finding.agentName, finding.verdict, finding.text], ["Reviewer", "changes", "Use a darker blue."]);
	assert.match(widgets().pulls[0].comments[0].body, /^\*From Reviewer, an agent of the pi² project “Widgets”\.\*\n\n\*\*Changes requested\.\*\* Use a darker blue\./);
	assert.match((await client.work(reviewer, "list")).text, /^#2 pull request open · no checks · changes requested · Blue widgets$/m, "and its review, in a word");
	refusal(await client.work(worker, "send_back", { id: 2, text: "Not mine to send" }), /Only the orchestrator can send a pull request back/);
	refusal(await client.work(worker, "merge", { id: 2 }), /Only the orchestrator can merge a pull request/);

	const sent = await client.work(parent, "send_back", { id: 2, text: "Darker, please." });
	assert.match(sent.text, new RegExp(`Conversation ${worker}, which opened it, was given it`));
	const line = await client.until("the input sent back", () => client.conversations.get(worker)?.items.find((item: any) => item.kind === "marker" && item.text.includes("sent back")));
	assert.equal(line.text, "Orchestrator sent back pull request #2: Darker, please.");
	await client.until("the worker answered it", () => !client.conversations.get(worker)?.state.busy && client.conversations.get(worker)?.items.at(-1)?.kind === "assistant");
	assert.ok(!client.conversations.get(worker)!.items.some((item: any) => item.kind === "user" && /Darker/.test(item.text)), "not a message the person typed");

	const decide = async (decision: string) => {
		const approval = await client.until("the merge switch asks", () => client.events.inbox?.items?.find((item: any) => item.projectSwitch === "merge"));
		await client.call("inbox.decide", { id: approval.id, decision });
	};
	const pending = client.work(parent, "merge", { id: 2 });
	await decide("deny");
	refusal(await pending, /The person declined this action/);
	assert.equal(widgets().pulls[0].state, "OPEN", "refused when the switch says ask");
	await client.call("projects.set", { id: projectId, settings: { withoutAsking: { merge: true } } });
	const merged = await client.work(parent, "merge", { id: 2 });
	assert.equal(merged.text, "Merged pull request #2 “Blue widgets”.");
	assert.equal(widgets().pulls[0].state, "MERGED");
	const closed = await client.until("the issue it fixed closed", () => client.github(projectId)?.issues?.find((one: any) => one.id === 1 && one.state === "done"));
	assert.equal(closed.takenBy, null);
	// The holder still posts its summary on the issue the merge closed, and the status label comes off (#604).
	assert.deepEqual(closed.heldAtClose, { agentId: workerId, conversationId: worker });
	refusal(await client.work(reviewer, "finish", { id: 1, text: "Not mine" }), /^Only the holder can finish #1\./);
	assert.equal(said(await client.work(worker, "finish", { id: 1, text: "Blue now; tested by hand." })), "Finished #1 “Make widgets blue”: done, with your summary.");
	const summed = await client.until("the summary listed", () => client.github(projectId)?.issues?.find((one: any) => one.id === 1 && one.result === "Blue now; tested by hand."));
	assert.deepEqual([summed.state, summed.heldAtClose], ["done", undefined]);
	const one = widgets().issues[0];
	assert.deepEqual([one.state, one.stateReason], ["CLOSED", "COMPLETED"]);
	assert.deepEqual(one.labels.map((label: any) => label.name).sort(), ["agent", "cloud model"]);
	assert.match(one.comments.at(-1).body, /^\*From Worker, an agent of the pi² project “Widgets”\.\*\n\n\*\*Done\.\*\* Blue now; tested by hand\./);
	assert.equal(calls().filter(({ args }) => args[0] === "issue" && args[1] === "close" && args[2] === "1").length, 0, "not closed again");
	refusal(await client.work(worker, "finish", { id: 1, text: "Twice" }), /^#1 is done\. Reopen it first\.$/);
	changeStandIn((whole) => void (whole.repos["example/widgets"].pulls[1].mergeable = "CONFLICTING"));
	await assert.rejects(client.call("github.merge", { projectId, number: 3 }), /Pull request #3 cannot be merged: it conflicts with main/);
	await client.call("github.sendBack", { projectId, number: 3, reason: "Rebase it first." });
	assert.match(widgets().pulls[1].comments.at(-1).body, /^\*\*Sent back\.\*\* Rebase it first\./);
	assert.match((await client.call("github.diff", { projectId, number: 3 })).diff, /^diff --git/);
	step("a reviewing agent's finding is attached; Send back reaches the conversation that opened it; merging asks while the switch is off, is refused, then merges");

	// ---- A long diff comes back whole through github.diff, and one over the engine's 2 MB comes back cut (#977)
	const hunk = (i: number) => `diff --git a/file${i}.txt b/file${i}.txt\n--- a/file${i}.txt\n+++ b/file${i}.txt\n@@ -1 +1 @@\n-old line ${i}\n+new line ${i}\n`;
	const longDiff = Array.from({ length: 3_000 }, (_, i) => hunk(i)).join("") + "last line of the long diff\n";
	assert.ok(Buffer.byteLength(longDiff) > 300_000 && Buffer.byteLength(longDiff) < 400_000);
	changeStandIn((whole) => void (whole.repos["example/widgets"].diff = longDiff));
	const long = (await client.call("github.diff", { projectId, number: 3 })).diff;
	assert.equal(long.length, longDiff.length, "the diff came back whole");
	assert.ok(long.endsWith("last line of the long diff\n"), "to its last line");
	const bigDiff = Array.from({ length: 36_000 }, (_, i) => hunk(i)).join("");
	assert.ok(Buffer.byteLength(bigDiff) > 2 * 1024 * 1024);
	changeStandIn((whole) => void (whole.repos["example/widgets"].diff = bigDiff));
	const cut = (await client.call("github.diff", { projectId, number: 3 })).diff;
	assert.ok(cut.startsWith(bigDiff.slice(0, 2 * 1024 * 1024)), "cut at the engine's limit");
	assert.match(cut, /\n\[pi² cut the diff here: it is longer than 2 MB\. gh pr diff 3 --repo example\/widgets shows all of it\.\]$/);
	changeStandIn((whole) => delete whole.repos["example/widgets"].diff);
	step("a diff of a few hundred KB comes back whole through github.diff, and one over 2 MB comes back cut with the engine's line");

	// ---- Every command names the repository
	for (const { args } of calls()) {
		if (args[0] === "repo" && args[1] === "view") assert.match(args[2]!, /^example\/(widgets|missing)$/, args.join(" "));
		else assert.equal(args[args.indexOf("--repo") + 1], "example/widgets", args.join(" "));
	}
	step("every gh command names the repository with --repo (gh repo view, as its argument)");

	// ---- What the orchestrator did itself is not news to it, for both kinds of list
	said(await client.work(worker, "file", { title: "Second" }));
	said(await client.work(worker, "take", { id: 4 }));
	said(await client.work(parent, "note", { id: 4, text: "The orchestrator's note" }));
	said(await client.work(worker, "note", { id: 4, text: "The worker's note" }));
	const { id: localItem } = await client.call("work.create", { projectId: local, title: "Local work" });
	said(await client.work(localParent, "note", { id: localItem, text: "The orchestrator's note" }));
	said(await client.work(localWorker, "note", { id: localItem, text: "The helper's note" }));
	await offline(async (harness) => {
		const news = (await harness.snapshot(Projects, context))!.news;
		const notes = (id: string) => (news[id] ?? []).filter((item) => item.kind === "work" && item.text.endsWith("(note)."));
		assert.equal(notes(projectId).length, 1, "on GitHub, only the worker's note");
		assert.equal(notes(local).length, 1, "kept by pi², only the helper's note");
	});
	for (const id of [parent, worker, reviewer]) await client.call("conversation.open", { id });
	step("an action by the orchestrator adds no news for the orchestrator, on GitHub and in the list kept by pi²");

	// ---- The admission check comes before a GitHub assignment claims an item
	said(await client.work(worker, "file", { title: "Held back" }));
	await client.until("spending counted", () => client.events.usage?.projects?.find((row: any) => row.id === projectId && row.today.cost > 0));
	await client.call("projects.set", { id: projectId, settings: { limits: { planShare: null, dailySpend: 0.01 } } });
	refusal(await client.work(parent, "assign", { id: 5, agent: "Worker" }), /^Not started: the project has spent \$/);
	assert.deepEqual(widgets().issues.find((one) => one.number === 5).comments, [], "nothing claimed");
	// Nor a worktree made and removed again: admission comes first (#604). The first one made makes the folder.
	assert.ok(!existsSync(join(home, "worktrees")), "no worktree made for a start held back");
	// Once nothing is spending: a card whose reading spending has passed since stays, with the new reading (#464).
	const card = await client.until("the limit card", () => client.events.needs?.items?.find((item: any) => item.kind === "limit" && item.projectId === projectId));
	await client.until("nothing spending", () => [parent, worker, reviewer].every((id) => !client.conversations.get(id)?.state.busy) || undefined);
	const cardNow = () => client.events.needs?.items?.find((item: any) => item.id === card.id);
	for (let tries = 0; ; tries++) {
		assert.ok(tries < 5, "the card is taken once nothing spends");
		const reading = cardNow().limit.id;
		await client.call("needs.answer", { id: card.id, answer: { kind: "limit", start: true } });
		if ((await client.until("the card taken, or kept with a new reading", () => (cardNow() === undefined ? "taken" : cardNow().limit.id !== reading ? "again" : undefined))) === "taken") break;
	}
	const assigned = await client.until("claimed and started", () => client.github(projectId)?.issues?.find((one: any) => one.id === 5 && one.state === "in_progress" && one.takenBy?.conversationId !== parent));
	assert.equal(assigned.takenBy.agentId, workerId);
	assert.equal(client.events.library.conversations.find((row: any) => row.id === assigned.takenBy.conversationId)?.parent, parent);
	assert.match(widgets().issues.find((one) => one.number === 5).comments[0].body, /Taken by Worker, assigned by the person\./);
	await client.until("the start allowed has its worktree", () => existsSync(join(home, "worktrees")) || undefined);
	await client.call("projects.set", { id: projectId, settings: { limits: { dailySpend: null } } });
	step("an assignment past a limit is refused before it claims anything; Start Anyway claims it on GitHub and starts the sub-chat");

	// ---- The state block of a fresh conversation reads GitHub's work
	const { conversation: fresh } = await client.call("projects.startFresh", { id: projectId });
	await client.call("conversation.open", { id: fresh });
	await client.call("submit", { id: fresh, text: "Where do we stand?" });
	const block = await client.until("the state block", () => client.conversations.get(fresh)?.items.find((item: any) => item.kind === "marker" && item.text === "pi² told the orchestrator how the project stands"));
	assert.match(block.details.wake.text, /Work: 0 open, 2 in progress, 0 waiting, 0 blocked\. In progress: #4 Worker; #5 Worker\./);
	await client.until("the fresh conversation is idle", () => !client.conversations.get(fresh)?.state.busy);
	step("the state block of a fresh conversation counts the repository's work (wireWorkState)");

	// ---- A read asks its questions together, and only for what changed since the last (#599)
	const logged = calls().length;
	const readBefore = client.github(projectId).readAt;
	// Each command takes a third of a second, as the real gh takes more; #5 is renamed where no question for changes sees it.
	changeStandIn((whole) => {
		whole.delay = "300-300";
		const five = whole.repos["example/widgets"].issues.find((one: any) => one.number === 5);
		Object.assign(five, { title: "Renamed quietly", updatedAt: new Date(Date.now() - 3 * 60 * 60_000).toISOString() });
	});
	client.readingSeen.clear();
	await client.call("work.act", { projectId, id: 4, action: "note", text: "Read behind" });
	// The read that saw the note: a read already under way when it was posted may land first (#903).
	const landed = await client.until("the read landed", () => {
		const now = client.github(projectId);
		return now?.reading === false && now.readAt !== readBefore && now.issues.find((one: any) => one.id === 4)?.notes.at(-1)?.text === "Read behind" && now;
	});
	const read = calls().slice(logged).filter((one) => ["issue list", "pr list"].includes(one.args.slice(0, 2).join(" ")));
	// Its four questions: asked once it began, and before any read after it, which begins only once it has landed.
	const lastRead = read.filter((one: any) => one.at >= landed.readAt).sort((x: any, y: any) => x.at - y.at).slice(0, 4);
	const flag = (one: { args: string[] }, name: string) => (one.args.includes(`--${name}`) ? one.args[one.args.indexOf(`--${name}`) + 1] : undefined);
	assert.deepEqual(lastRead.map((one) => `${one.args[0]} ${flag(one, "state")} ${flag(one, "json") === "number" ? "numbers" : (flag(one, "search") ?? "").replace(/[\dT:+-]+$/, "")}`).sort(), [
		"issue all updated:>=",
		"issue open numbers",
		"pr closed updated:>=",
		"pr open ",
	]);
	// Since ten minutes before the read before it began, as that read was recorded to begin, to the second GitHub's
	// search takes: never a window on the test's clock, which a loaded Mac can overrun (#903).
	const changesSince = Date.parse(flag(lastRead.find((one) => flag(one, "state") === "all")!, "search")!.replace("updated:>=", ""));
	const readAts = client.readAts.get(projectId)!;
	const lastBegan = readAts[readAts.indexOf(landed.readAt) - 1]!;
	assert.ok(lastBegan >= readBefore, "the read before it is the last one before the note, or one after");
	assert.equal(changesSince, Math.floor((lastBegan - 10 * 60_000) / 1000) * 1000, "changes since ten minutes before the last read began");
	const times = lastRead as unknown as { at: number; ended: number }[];
	assert.ok(Math.max(...times.map((one) => one.at)) < Math.min(...times.map((one) => one.ended)), "the four questions of one read ran at the same time");
	assert.equal(landed.issues.find((one: any) => one.id === 5).title, "Held back", "an issue GitHub does not count as changed is not read again");
	assert.equal(landed.issues.find((one: any) => one.id === 4).notes.at(-1).text, "Read behind");
	assert.ok(client.readingSeen.has(projectId), "the event said a read was under way");
	changeStandIn((whole) => {
		delete whole.delay;
		whole.repos["example/widgets"].issues.find((one: any) => one.number === 5).updatedAt = new Date().toISOString();
	});
	await client.call("work.act", { projectId, id: 4, action: "note", text: "And again" });
	await client.until("the rename read", () => client.github(projectId)?.issues?.find((one: any) => one.id === 5 && one.title === "Renamed quietly"));
	step("a read asks its four questions at once, says it is reading meanwhile, and reads again only what GitHub says changed");

	// ---- GitHub unreachable, and its rate limit
	const before = client.github(projectId).issues;
	changeStandIn((whole) => void (whole.fail = { kind: "unreachable" }));
	refusal(await client.work(worker, "note", { id: 4, text: "While offline" }), /^GitHub cannot be reached: error connecting to api\.github\.com/);
	const down = await client.until("unreachable", () => client.github(projectId)?.state === "unreachable" && client.github(projectId));
	assert.match(down.error, /error connecting to api\.github\.com/);
	assert.deepEqual([down.issues, down.unknown], [before, []]);
	const cached = await client.work(worker, "list");
	assert.deepEqual([...cached.text.matchAll(/^#(\d+) (?!pull request)/gm)].map((match) => Number(match[1])), [5, 4]);
	assert.match(cached.text, /It is not newer: GitHub cannot be reached/);
	changeStandIn((whole) => void (whole.fail = { kind: "rate_limited" }));
	assert.match((await client.work(worker, "show", { id: 4 })).text, /^#4 /, "the cached item, while GitHub refuses");
	assert.match((await client.until("rate limited", () => client.github(projectId)?.state === "rate_limited" && client.github(projectId))).error, /rate limit/);
	changeStandIn((whole) => delete whole.fail);
	said(await client.work(worker, "note", { id: 4, text: "Back again" }));
	await client.until("read again", () => client.github(projectId)?.state === "ok");
	step("with GitHub unreachable or its rate limit reached, the listing stays as it was, saying why, and a write fails without being unknown");

	// ---- The engine killed between an intent and its write, and between the write and its record
	const crash = async (title: string, when: "before" | "after") => {
		changeStandIn((whole) => void (whole.block = { match: title, when }));
		void client.call("submit", { id: worker, text: `/tool work ${JSON.stringify({ action: "file", title })}` });
		await client.until(`the stand-in held ${when} its write`, () => existsSync(`${state}.blocked`) || undefined);
		const pid = Number(readFileSync(`${state}.blocked`, "utf8"));
		blockedPids.push(pid);
		client.close();
		await stop(engine, "SIGKILL");
		process.kill(pid, "SIGKILL");
		rmSync(`${state}.blocked`);
		changeStandIn((whole) => delete whole.block);
		engine = start();
		client = await Client.connect(engine, home);
		await client.call("conversation.open", { id: worker });
		return client.until(`the call run again for “${title}”`, () => !client.conversations.get(worker)?.state.busy && client.results(worker, "work").find((item: any) => item.text.includes(title)));
	};
	const lost = await crash("Lost before the write", "before");
	refusal(lost, /^pi² could not tell whether GitHub took this \(filing “Lost before the write”\)\. Look at the repository before trying again\.$/);
	const unknown = await client.until("the unknown write", () => client.github(projectId)?.unknown?.[0]);
	assert.equal(unknown.summary, "filing “Lost before the write”");
	assert.equal(widgets().issues.filter((one) => one.title === "Lost before the write").length, 0);
	// A script or a test copy asks for what only the event carried before (#573).
	assert.deepEqual((await client.call("github.unknown", { projectId })).unknown, [unknown]);
	await client.call("github.settle", { projectId, intent: unknown.intent, happened: false });
	await client.until("settled", () => client.github(projectId)?.unknown?.length === 0);
	assert.deepEqual((await client.call("github.unknown", { projectId })).unknown, []);
	said(await client.work(worker, "file", { title: "Lost before the write" }));
	assert.equal(widgets().issues.filter((one) => one.title === "Lost before the write").length, 1, "filed once, by hand, after it was settled");

	const kept = await crash("Made before the crash", "after");
	assert.match(said(kept), /^Filed #\d+ “Made before the crash”, not classified\.\nIts page: https:\/\/github\.com\/example\/widgets\/issues\/\d+$/);
	assert.equal(widgets().issues.filter((one) => one.title === "Made before the crash").length, 1, "found by its marker, not made again");
	assert.deepEqual(client.github(projectId)?.unknown ?? (await client.until("listing", () => client.github(projectId))).unknown, []);
	const durable = await client.until("pull requests after restarts", () => client.github(projectId)?.pulls?.find((one: any) => one.number === 2));
	assert.deepEqual(durable.openedBy, { conversationId: worker }, "openedBy kept durably");
	step("killed between an intent and its write: unknown, reported, settled by the person; between the write and its record: found, not made twice");

	// ---- An issue taken with scripts/issue, resuming, closing, and paths from this Mac (#604)
	let scripted = 0;
	changeStandIn((whole) => {
		const repo = whole.repos["example/widgets"];
		const number = repo.next;
		repo.next += 1;
		scripted = number;
		const at = new Date().toISOString();
		const url = `https://github.com/example/widgets/issues/${number}`;
		const comments = [{ id: "IC_1", author: { login: "stand-in" }, body: "Picked up by an agent session on branch `fix-it`.", createdAt: at, url: `${url}#issuecomment-1` }];
		repo.issues.push({ number, title: "Taken with the script", body: "_Opened by an agent session on branch `fix-it`._", state: "OPEN", stateReason: null, labels: [{ name: "agent" }, { name: "in progress" }], url, createdAt: at, updatedAt: at, closedAt: null, comments, author: { login: "stand-in" } });
	});
	const outside = /was taken outside the work tool \(with scripts\/issue, or on GitHub by hand\), so the tool knows no holder for it\./;
	for (const action of ["take", "wait", "finish"]) {
		const refused = await client.work(worker, action, { id: scripted, text: "Mine?" });
		refusal(refused, outside);
		assert.match(refused.text, /ask the orchestrator to release it, which hands it over to the work tool\.$/);
	}
	// The orchestrator's conversation is the fresh one now.
	await client.call("conversation.open", { id: fresh });
	const byOrchestrator = await client.work(fresh, "assign", { id: scripted, agent: "Worker" });
	refusal(byOrchestrator, outside);
	assert.match(byOrchestrator.text, /Release it first: that hands it over to the work tool\.$/);
	said(await client.work(fresh, "release", { id: scripted }));
	const released = widgets().issues.find((one) => one.number === scripted);
	assert.match(released.comments.at(-1).body, /\n\nReleased: it was taken outside the work tool, and is open again\./);
	assert.deepEqual(released.labels.map((label: any) => label.name).sort(), ["agent", "backlog"]);
	said(await client.work(worker, "take", { id: scripted }));

	// resume posts one line, which is no note.
	said(await client.work(worker, "wait", { id: scripted, text: "On the person" }));
	assert.equal(said(await client.work(worker, "resume", { id: scripted })), `Resumed #${scripted} “Taken with the script”: in progress, held by you.`);
	const resumed = await client.until("resumed in the listing", () => client.github(projectId)?.issues?.find((one: any) => one.id === scripted && one.state === "in_progress" && one.notes.some((note: any) => note.text === "On the person")));
	assert.match(widgets().issues.find((one) => one.number === scripted).comments.at(-1).body, new RegExp(`\\n\\nResumed by Worker, in conversation ${worker}\\.\\n\\n<!-- pi2:`));
	assert.deepEqual(resumed.notes.map((note: any) => note.text).filter((text: string) => !text.startsWith("Picked up")), ["On the person"], "the line is no note");

	// A path in this Mac's home folder is posted as ~, in a note, a title and a text.
	const homeFolder = process.env.HOME!;
	said(await client.work(worker, "note", { id: scripted, text: `The log is at ${homeFolder}/Library/Logs/widgets.log.` }));
	assert.match(widgets().issues.find((one) => one.number === scripted).comments.at(-1).body, /The log is at ~\/Library\/Logs\/widgets\.log\./);
	const pathy = { id: filedId(await client.work(worker, "file", { title: `Clean ${homeFolder}/tmp`, text: `Files in ${homeFolder}/tmp pile up.` })) };
	const pathIssue = widgets().issues.find((one) => one.number === pathy.id);
	assert.equal(pathIssue.title, "Clean ~/tmp");
	assert.match(pathIssue.body, /\n\nFiles in ~\/tmp pile up\.\n\n/);
	assert.ok(!JSON.stringify(widgets()).includes(homeFolder), "no home folder anywhere in the repository");

	// finish and close take the status label off.
	assert.equal(said(await client.work(worker, "finish", { id: scripted, text: "Done with it." })), `Finished #${scripted} “Taken with the script”: done, with your summary.`);
	assert.deepEqual(widgets().issues.find((one) => one.number === scripted).labels.map((label: any) => label.name), ["agent"]);
	said(await client.work(worker, "take", { id: pathy.id }));
	said(await client.work(worker, "block", { id: pathy.id, text: "On something else" }));
	assert.match(said(await client.work(fresh, "close", { id: pathy.id, as: "dropped" })), new RegExp(`^Closed #${pathy.id} “.+” as dropped\\.$`));
	const dropped = widgets().issues.find((one) => one.number === pathy.id);
	assert.deepEqual([dropped.state, dropped.stateReason, dropped.labels.map((label: any) => label.name)], ["CLOSED", "NOT_PLANNED", ["agent"]]);
	step("an issue taken with scripts/issue is refused saying so until the orchestrator releases it; resume posts a line; the home folder is posted as ~; finish and close take the status label off");

	// ---- A pull request's body from a file, and a path given as the text refused rather than posted (#662)
	const scratch = makeScratch(home, worker);
	writeFileSync(join(scratch, "pr-body.md"), `What changed, in ${homeFolder}/widgets.\n\nTested by hand.`);
	const pullsBefore = widgets().pulls.length;
	refusal(await client.work(worker, "pull_request", { id: pathy.id, title: "From a file", text: "$PI2_SCRATCH/pr-body.md" }), /^text is only the path of a file: give the path as text_file, which reads the file, or put the words themselves in text\.$/);
	refusal(await client.work(worker, "pull_request", { id: pathy.id, title: "From a file", text: join(scratch, "pr-body.md") }), /^text is only the path of a file: give the path as text_file/);
	refusal(await client.work(worker, "pull_request", { title: "Both", text: "A body", text_file: "$PI2_SCRATCH/pr-body.md" }), /^Give text or text_file, not both\.$/);
	refusal(await client.work(worker, "pull_request", { title: "Outside", text_file: state }), /^text_file: ".*state\.json" is outside this conversation's folder \(.*\)\. text_file reads a file inside it, or in its scratch folder under \$PI2_SCRATCH\.$/);
	assert.equal(widgets().pulls.length, pullsBefore, "no pull request opened by a refusal");
	const fromFile = await client.work(worker, "pull_request", { id: pathy.id, title: "From a file", text_file: "$PI2_SCRATCH/pr-body.md" });
	const fromFileNumber = Number(/^Opened pull request #(\d+) from feature into main: /.exec(said(fromFile))![1]);
	const bodyFromFile = widgets().pulls.find((one) => one.number === fromFileNumber).body;
	assert.match(bodyFromFile, new RegExp(`^\\*From Worker, an agent of the pi² project “Widgets”\\.\\*\\n\\nWhat changed, in ~/widgets\\.\\n\\nTested by hand\\.\\n\\nFixes #${pathy.id}\\n\\n<!-- pi2:[0-9a-f]{16} -->$`));
	// A file in the conversation's folder, by a path relative to it.
	writeFileSync(join(folder, "finding.md"), "Looks right.");
	await client.call("conversation.open", { id: reviewer });
	const reviewed = await client.work(reviewer, "review", { id: fromFileNumber, verdict: "approve", text_file: "finding.md" });
	rmSync(join(folder, "finding.md"));
	assert.match(said(reviewed), /^Posted your finding \(approved\) on pull request #\d+/);
	assert.match(widgets().pulls.find((one) => one.number === fromFileNumber).comments.at(-1).body, /\n\n\*\*Approved\.\*\* Looks right\.\n\n<!-- pi2:/);
	step("a pull request's body and a finding from a file, with the agent's line and the home folder as ~; refused: a path as the text, both given, a file outside the two folders");

	// ---- An open pull request's text replaced, keeping what opening added: its agent's line, Fixes and marker (#823)
	const fromFilePull = () => widgets().pulls.find((one) => one.number === fromFileNumber);
	const openingMarker = /<!-- pi2:[0-9a-f]{16} -->$/.exec(fromFilePull().body)![0];
	const prEdits = () => calls().filter(({ args }) => args[0] === "pr" && args[1] === "edit").length;
	const pullUrl = `https://github.com/example/widgets/pull/${fromFileNumber}`;
	writeFileSync(join(scratch, "pr-update.md"), `What changed, in ${homeFolder}/widgets.\n\nTested by hand, and the suite passed while CI ran.\n`);
	const updated = await client.work(worker, "update_pull_request", { id: fromFileNumber, title: "From a file, tested", text_file: "$PI2_SCRATCH/pr-update.md" });
	assert.equal(said(updated), `Updated the title and text of pull request #${fromFileNumber} “From a file, tested”, keeping the line naming its agent, Fixes #${pathy.id} and pi²'s marker: ${pullUrl}`);
	assert.equal(typeof updated.details?.change, "number", "a change with no Undo");
	assert.equal(fromFilePull().title, "From a file, tested");
	assert.equal(fromFilePull().body, `*From Worker, an agent of the pi² project “Widgets”.*\n\nWhat changed, in ~/widgets.\n\nTested by hand, and the suite passed while CI ran.\n\nFixes #${pathy.id}\n\n${openingMarker}`);
	const listedUpdate = await client.until("the update listed", () => client.github(projectId)?.pulls?.find((one: any) => one.number === fromFileNumber && one.title === "From a file, tested"));
	assert.deepEqual([listedUpdate.work, listedUpdate.openedBy], [pathy.id, { conversationId: worker }], "it still fixes its issue, and is still the worker's");
	// The orchestrator may update it too: the line still names the agent that opened it, and a text that closes the issue in
	// its own words is not given a second Fixes line.
	const rewritten = await client.work(fresh, "update_pull_request", { id: fromFileNumber, text: `Rewritten by the orchestrator. Closes #${pathy.id}.` });
	assert.equal(said(rewritten), `Updated the text of pull request #${fromFileNumber} “From a file, tested”, keeping the line naming its agent, Fixes #${pathy.id} and pi²'s marker: ${pullUrl}`);
	assert.equal(fromFilePull().body, `*From Worker, an agent of the pi² project “Widgets”.*\n\nRewritten by the orchestrator. Closes #${pathy.id}.\n\n${openingMarker}`);
	// The title alone leaves the text as it is; the same again changes nothing.
	const textBefore = fromFilePull().body;
	assert.equal(said(await client.work(worker, "update_pull_request", { id: fromFileNumber, title: "From a file" })), `Updated the title of pull request #${fromFileNumber} “From a file”: ${pullUrl}`);
	assert.deepEqual([fromFilePull().title, fromFilePull().body], ["From a file", textBefore]);
	const editsMade = prEdits();
	assert.equal(editsMade, 3, "one gh pr edit for each change");
	assert.equal(said(await client.work(worker, "update_pull_request", { id: fromFileNumber, title: "From a file" })), `Pull request #${fromFileNumber} “From a file” already says that: nothing changed.`);

	// Refused, with nothing edited: another agent's conversation, a merged and a closed one, one with no marker, one whose
	// marker this project has no record of (the orchestrator's too), no text or title, no number, and a list kept by pi².
	let byHand = 0;
	let foreign = 0;
	changeStandIn((whole) => {
		const repo = whole.repos["example/widgets"];
		repo.pulls.find((one: any) => one.number === 3).state = "CLOSED";
		const at = new Date().toISOString();
		for (const [name, body] of [["by-hand", "Made on GitHub by hand."], ["foreign", "From another pi².\n\n<!-- pi2:0123456789abcdef -->"]] as const) {
			const number = repo.next;
			repo.next = number + 1;
			if (name === "by-hand") byHand = number;
			else foreign = number;
			repo.pulls.push({
				number, title: name, url: `https://github.com/example/widgets/pull/${number}`, headRefName: name, headRepositoryOwner: { login: "example" }, isCrossRepository: false,
				baseRefName: "main", author: { login: "stand-in" }, state: "OPEN", isDraft: false, statusCheckRollup: [], mergeable: "MERGEABLE", body, comments: [],
				createdAt: at, updatedAt: at, closedAt: null, mergedAt: null,
			});
		}
	});
	const bodies = () => JSON.stringify(widgets().pulls.map((one) => [one.number, one.title, one.body]));
	const bodiesBefore = bodies();
	refusal(await client.work(reviewer, "update_pull_request", { id: fromFileNumber, text: "Mine now" }), new RegExp(`^Only conversation ${worker}, which opened pull request #${fromFileNumber}, or the orchestrator can update it\\. Tell the orchestrator in your report\\.$`));
	refusal(await client.work(worker, "update_pull_request", { id: 2, text: "Too late" }), /^Pull request #2 is merged, so its text stays as it is\.$/);
	refusal(await client.work(worker, "update_pull_request", { id: 3, text: "Too late" }), /^Pull request #3 is closed, so its text stays as it is\.$/);
	refusal(await client.work(worker, "update_pull_request", { id: byHand, text: "Not the tool's" }), new RegExp(`^Pull request #${byHand} was not opened with the work tool: its text has no pi² marker, so there is nothing of the tool's to keep\\. Edit it on GitHub, or with gh pr edit\\.$`));
	refusal(await client.work(fresh, "update_pull_request", { id: foreign, text: "Not this project's" }), new RegExp(`^Pull request #${foreign} was not opened by this project's work tool: pi² has no record of it, so update_pull_request leaves it alone\\.`));
	refusal(await client.work(worker, "update_pull_request", { id: fromFileNumber }), /^Give the pull request's new text, in text or text_file, or a new title\.$/);
	refusal(await client.work(worker, "update_pull_request", { text: "Which one?" }), /^id must be the pull request's number$/);
	await client.call("conversation.open", { id: localWorker });
	refusal(await client.work(localWorker, "update_pull_request", { id: 1, text: "None here" }), /^This project's work is kept by pi², which has no pull requests\.$/);
	assert.equal(prEdits(), editsMade, "no gh pr edit for a refusal");
	assert.equal(bodies(), bodiesBefore, "every pull request as it was");
	// Open again, as the lists of merged and closed pull requests below count it.
	changeStandIn((whole) => void (whole.repos["example/widgets"].pulls.find((one: any) => one.number === 3).state = "OPEN"));
	step("update_pull_request replaces an open pull request's text and title, keeping its agent's line, Fixes and marker, for its own conversation and the orchestrator; refused: another's, merged, closed, no marker, no record, nothing given, no number, no pull requests");

	// ---- A text that names an issue with a closing word in passing says so, and a "Part of #N" line takes the Fixes off (#1044)
	// Each pull request from a branch of its own: the stand-in refuses a second open one from the same branch.
	const onBranch = (name: string) => {
		gitIn("checkout", "-q", "-b", name);
		gitIn("config", `branch.${name}.remote`, "origin");
		gitIn("config", `branch.${name}.merge`, `refs/heads/${name}`);
	};
	onBranch("passing");
	const inPassing = await client.work(worker, "pull_request", { title: "In passing", text: `Do not close #${pathy.id}: more remains.` });
	const inPassingNumber = Number(/^Opened pull request #(\d+) from passing into main: /.exec(said(inPassing))![1]);
	assert.match(said(inPassing), new RegExp(`GitHub will close #${pathy.id} when this merges, because the text says "close #${pathy.id}"\\. If that is not meant, reword it and use update_pull_request\\.`));
	const parted = await client.work(worker, "update_pull_request", { id: inPassingNumber, text: `Part of #${pathy.id}.\n\nWhat changed. The rest of #${pathy.id} is done elsewhere.` });
	assert.match(said(parted), new RegExp(`keeping the line naming its agent, no longer fixing #${pathy.id} and pi²'s marker`));
	const partedPull = widgets().pulls.find((one: any) => one.number === inPassingNumber);
	assert.equal(partedPull.body.includes(`Fixes #${pathy.id}`), false, "the Part of line takes the Fixes off");
	assert.match(partedPull.body, new RegExp(`\\n\\nPart of #${pathy.id}\\.\\n\\nWhat changed\\. The rest of #${pathy.id} is done elsewhere\\.\\n\\n<!-- pi2:[0-9a-f]{16} -->$`));
	// Without a Part of line, the Fixes for the issue the pull request was opened with is put back as before.
	onBranch("passing-two");
	const withId = await client.work(worker, "pull_request", { id: pathy.id, title: "With an id", text: "What changed." });
	const withIdNumber = Number(/^Opened pull request #(\d+) from passing-two into main: /.exec(said(withId))![1]);
	const withIdPull = () => widgets().pulls.find((one: any) => one.number === withIdNumber);
	const withIdMarker = /<!-- pi2:[0-9a-f]{16} -->$/.exec(withIdPull().body)![0];
	const keptFixes = await client.work(worker, "update_pull_request", { id: withIdNumber, text: "What changed, and more of it." });
	assert.match(said(keptFixes), new RegExp(`keeping the line naming its agent, Fixes #${pathy.id} and pi²'s marker`));
	assert.equal(withIdPull().body, `*From Worker, an agent of the pi² project “Widgets”.*\n\nWhat changed, and more of it.\n\nFixes #${pathy.id}\n\n${withIdMarker}`);
	gitIn("checkout", "-q", "feature");
	step("a pull request whose text closes an issue in passing says so; a Part of line takes the Fixes off and says so; without it Fixes is kept");

	// ---- A first read reads everything, and what is closed comes brief until it is opened (#599)
	const secondFolder = realpathSync(mkdtempSync(join(tmpdir(), "pi2-github-anew-")));
	const { id: anew } = await client.call("projects.create", { folder: secondFolder, name: "Widgets anew" });
	await client.call("github.attach", { projectId: anew, repository: "example/widgets" });
	const whole = await client.until("the first read", () => client.github(anew)?.state === "ok" && client.github(anew));
	const brief = whole.issues.find((one: any) => one.id === 1);
	assert.deepEqual([brief.state, brief.partial, brief.text, brief.notes], ["done", true, "", []]);
	assert.equal(whole.issues.find((one: any) => one.id === 4).partial, undefined, "an open issue comes whole");
	const briefPull = whole.pulls.find((one: any) => one.number === 2);
	assert.deepEqual([briefPull.state, briefPull.partial, briefPull.findings], ["merged", true, []]);
	const shownIssue = (await client.call("github.show", { projectId: anew, number: 1 })).item;
	assert.deepEqual([shownIssue.partial, shownIssue.text], [undefined, "They are grey."]);
	const shownPull = (await client.call("github.show", { projectId: anew, number: 2, pull: true })).pull;
	assert.deepEqual([shownPull.partial, shownPull.head, shownPull.work], [undefined, "feature", 1]);
	await client.until("both whole in the listing", () => {
		const now = client.github(anew);
		return now.issues.find((one: any) => one.id === 1)?.text === "They are grey." && now.pulls.find((one: any) => one.number === 2)?.partial === undefined;
	});
	await assert.rejects(client.call("github.show", { projectId: anew, number: 99 }), /#99/);
	await client.call("projects.archive", { id: anew });
	rmSync(secondFolder, { recursive: true, force: true });
	step("a first read reads everything, what is closed comes brief, and github.show reads one whole into the listing");

	// ---- The tool's list leaves merged and closed pull requests out unless asked for, then gives them a page at a time (#790)
	const added: number[] = [];
	changeStandIn((whole) => {
		const repo = whole.repos["example/widgets"];
		const at = new Date().toISOString();
		for (let i = 0; i < 35; i++) {
			const number = repo.next;
			repo.next = number + 1;
			added.push(number);
			repo.pulls.push({
				number, title: `Ended ${i}`, url: `https://github.com/example/widgets/pull/${number}`, headRefName: `ended-${i}`, headRepositoryOwner: { login: "example" }, isCrossRepository: false,
				baseRefName: "main", author: { login: "stand-in" }, state: i === 0 ? "CLOSED" : "MERGED", isDraft: false, statusCheckRollup: [], mergeable: "UNKNOWN", body: "", comments: [],
				createdAt: at, updatedAt: at, closedAt: at, mergedAt: i === 0 ? null : at,
			});
		}
	});
	await client.call("work.act", { projectId, id: 1, action: "note", text: "Read the ended pull requests" });
	const listedPulls: any[] = await client.until("the ended pull requests listed", () => {
		const pulls = client.github(projectId)?.pulls ?? [];
		return added.every((number) => pulls.some((one: any) => one.number === number)) && pulls;
	});
	const openPulls = listedPulls.filter((one) => one.state === "open").map((one) => one.number).sort((a, b) => b - a);
	const endedPulls = listedPulls.filter((one) => one.state !== "open").map((one) => one.number).sort((a, b) => b - a);
	assert.ok(openPulls.length > 0 && endedPulls.length > 35, `${openPulls.length} open, ${endedPulls.length} ended`);
	const pullRows = (text: string) => [...text.matchAll(/^#(\d+) pull request (open|merged|closed)\b/gm)].map((match) => ({ number: Number(match[1]), state: match[2] }));
	const itemRows = (text: string) => [...text.matchAll(/^#(\d+) (?!pull request)/gm)].length;

	const board = said(await client.work(reviewer, "list"));
	assert.deepEqual(pullRows(board).map((row) => row.number), openPulls, "the open pull requests only, by default");
	assert.ok(pullRows(board).every((row) => row.state === "open"));
	assert.match(board, new RegExp(`^\\d+ items?: .* ${listedPulls.length} pull requests, ${openPulls.length} of them open\\.$`, "m"), "the count of them all, as before");
	assert.match(board, new RegExp(`^${endedPulls.length} merged or closed in the last seven days are left out: list with states \\["merged", "closed"\\] for them\\.$`, "m"));
	assert.equal(board.split("\n").length, itemRows(board) + openPulls.length + 3, "a line an item, a line an open pull request, the count, what is left out and when it was read");

	const first = said(await client.work(reviewer, "list", { states: ["merged", "closed"] }));
	assert.deepEqual(pullRows(first).map((row) => row.number), endedPulls.slice(0, 30), "the newest thirty, newest first");
	assert.equal(itemRows(first), 0, "no items: none is merged or closed");
	const more = new RegExp(`^${endedPulls.length - 30} more pull requests merged or closed: list again with the same states and cursor "${endedPulls[29]}"\\.$`, "m");
	assert.match(first, more);
	assert.doesNotMatch(first, /left out/);
	const rest = said(await client.work(reviewer, "list", { states: ["merged", "closed"], cursor: String(endedPulls[29]) }));
	assert.deepEqual(pullRows(rest).map((row) => row.number), endedPulls.slice(30), "the rest from the cursor");
	assert.doesNotMatch(rest, / more pull requests /);
	assert.match(rest, new RegExp(`^0 items\\. ${listedPulls.length} pull requests, ${openPulls.length} of them open\\.$`, "m"));
	const mergedOnly = said(await client.work(reviewer, "list", { states: ["open", "merged"] }));
	const mergedRows = pullRows(mergedOnly);
	assert.deepEqual(mergedRows.filter((row) => row.state === "open").map((row) => row.number), openPulls, "open with the open ones");
	assert.ok(mergedRows.some((row) => row.state === "merged") && !mergedRows.some((row) => row.state === "closed"), "merged without the closed one");
	assert.ok(itemRows(mergedOnly) > 0, "and the open items");
	assert.match(mergedOnly, /^1 merged or closed in the last seven days is left out: /m);
	refusal(await client.work(reviewer, "list", { cursor: "5" }), /^cursor goes on through merged and closed pull requests/);
	refusal(await client.work(reviewer, "list", { states: ["merged"], cursor: "#5" }), /^cursor must be the one a list gave/);
	refusal(await client.work(reviewer, "list", { states: ["shipped"] }), /^states must be a list of work states \(.*\), or of pull requests' states, merged and closed$/);
	await client.call("conversation.open", { id: localParent });
	refusal(await client.work(localParent, "list", { states: ["merged"] }), /^merged and closed are states of pull requests, and this project's work is kept by pi², which has none\.$/);
	step("the tool's list gives the open pull requests and the count of all; merged and closed ones when asked, thirty at a time, newest first, with a cursor");

	// ---- Detaching
	await client.call("github.detach", { projectId });
	await client.until("detached", () => client.github(projectId) === undefined);
	assert.deepEqual((await client.call("work.list", { projectId })).items.map((item: any) => item.id), [leftOver], "the list kept by pi² as it was left");
	await client.call("github.attach", { projectId, repository: "Example/Widgets" });
	await client.until("attached again", () => client.github(projectId)?.state === "ok");
	assert.equal(client.github(projectId).repository.name, "widgets");
	step("detaching goes back to the list kept by pi², and attaching again reads it again");
} finally {
	client.close();
	await stop(engine);
	// A `gh` the engine started a moment before it stopped outlives it, as the real one would, and writes its line to
	// the stand-in's log as it ends: into the folder the exit removes, which failed once in CI with "directory not empty"
	// (#707). So the test ends once every one has; those it held were killed as it went.
	// None at all if the test failed before the first: then the failure is what it ends with.
	const started = () => (existsSync(`${state}.started`) ? readFileSync(`${state}.started`, "utf8").trim().split("\n").map(Number).filter((pid) => pid > 0) : []);
	const runs = (pid: number) => {
		try {
			process.kill(pid, 0);
			return true;
		} catch {
			return false;
		}
	};
	await until("every gh the engines started to have ended", () => started().every((pid) => !runs(pid)));
}
