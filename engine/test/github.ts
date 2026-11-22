// Work from an attached GitHub repository (#468), driven through a real engine with a throwaway home, the scripted demo
// model, and a stand-in gh (gh-stand-in.mjs) that keeps its repositories in a file and never reaches the network.
import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { BACKGROUND_CONTEXT as context } from "@earendil-works/chord/context";
import { createModels } from "@earendil-works/pi-ai";
import { createRegistry, Harness } from "@earendil-works/pi-durable";
import { openNodeSqliteStorage } from "@earendil-works/pi-durable/storage/sqlite/node";
import { PREVIEW_OFF, Projects } from "../src/projects.ts";
import { makeScratch } from "../src/scratch.ts";
import { EngineClient, previewOn, standInApp, stop } from "./patience.ts";

const home = mkdtempSync(join(tmpdir(), "pi2-github-"));
const ghFolder = mkdtempSync(join(tmpdir(), "pi2-github-gh-"));
const folder = realpathSync(mkdtempSync(join(tmpdir(), "pi2-github-repo-")));
const service = `dev.pi2.credentials.test-github-${process.pid}`;
const state = join(ghFolder, "state.json");
const shim = join(ghFolder, "gh");
writeFileSync(shim, `#!/bin/sh\nGH_STAND_IN_STATE='${state}' exec '${process.execPath}' '${join(import.meta.dirname, "gh-stand-in.mjs")}' "$@"\n`, { mode: 0o755 });
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
		writeFileSync(state, JSON.stringify(whole, null, "\t"));
	} finally {
		rmSync(lock, { recursive: true, force: true });
	}
}
const calls = (): { args: string[] }[] => readFileSync(`${state}.log`, "utf8").trim().split("\n").map((line) => JSON.parse(line));

class Client extends EngineClient {
	order: string[] = [];
	/** The projects a `github` event has said a read is under way for (#599). */
	readingSeen = new Set<string>();
	override receive(message: any): void {
		if (typeof message.event === "string") this.order.push(message.event);
		if (message.event === "github") for (const [id, one] of Object.entries<any>(message.projects ?? {})) if (one.reading === true) this.readingSeen.add(id);
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
	// ---- With the preview off
	assert.deepEqual(await client.until("greetings", () => client.events.github), { event: "github", projects: {} });
	assert.ok(client.order.indexOf("work") < client.order.indexOf("github"), "github comes after work (4.4)");
	for (const method of ["github.attach", "github.detach", "github.refresh", "github.merge", "github.sendBack", "github.diff", "github.unknown", "github.settle", "github.show", "projects.watch"]) {
		await assert.rejects(client.call(method, {}), { message: PREVIEW_OFF });
	}
	step("with the preview off, the empty github event after work, and every github request refused");

	// ---- Attaching
	await previewOn(client);
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

	const [a, b] = await Promise.all([client.work(worker, "take", { id: 1 }), client.work(reviewer, "take", { id: 1 })]);
	assert.notEqual(a.isError, b.isError, `exactly one gets it: ${a.text} / ${b.text}`);
	const winner = a.isError ? reviewer : worker;
	const winnerAgent = a.isError ? reviewerId : workerId;
	const loser = (a.isError ? a : b).text;
	assert.equal(loser, `#1 is taken by ${winner === worker ? "Worker" : "Reviewer"}, in sub-chat ${winner}`);
	assert.equal(said(a.isError ? b : a), "Took #1 “Make widgets blue”: in progress, held by you.");
	await client.until("the holder listed", () => client.github(projectId)?.issues?.find((one: any) => one.id === 1 && one.takenBy?.agentId === winnerAgent && one.takenBy.conversationId === winner));
	// Both claimed and the later one let go, or the later one read the issue after the first was in progress and claimed
	// nothing: either way, one claim stands.
	const comments = widgets().issues[0].comments.map((comment: any) => comment.body.split("\n\n")[1]);
	const claims = comments.filter((text: string) => text.startsWith("Taken by")).length;
	assert.equal(claims - comments.filter((text: string) => text.startsWith("Released")).length, 1, comments.join(" / "));
	console.log(`    (${claims === 2 ? "both claimed; the later one let go" : "the later one found it taken before claiming"})`);
	assert.deepEqual(widgets().issues[0].labels.map((label: any) => label.name).sort(), ["agent", "cloud model", "in progress"]);
	if (winner !== worker) {
		await client.work(winner, "release", { id: 1 });
		said(await client.work(worker, "take", { id: 1 }));
	}
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
	step("an agent files an issue (labels made as scripts/issue makes them), two take it at once and one holds it");

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
	const landed = await client.until("the read landed", () => client.github(projectId)?.reading === false && client.github(projectId).readAt !== readBefore && client.github(projectId));
	const read = calls().slice(logged).filter((one) => ["issue list", "pr list"].includes(one.args.slice(0, 2).join(" ")));
	const lastRead = read.slice(-4);
	const flag = (one: { args: string[] }, name: string) => (one.args.includes(`--${name}`) ? one.args[one.args.indexOf(`--${name}`) + 1] : undefined);
	assert.deepEqual(lastRead.map((one) => `${one.args[0]} ${flag(one, "state")} ${flag(one, "json") === "number" ? "numbers" : (flag(one, "search") ?? "").replace(/[\dT:+-]+$/, "")}`).sort(), [
		"issue all updated:>=",
		"issue open numbers",
		"pr closed updated:>=",
		"pr open ",
	]);
	const changesSince = Date.parse(flag(lastRead.find((one) => flag(one, "state") === "all")!, "search")!.replace("updated:>=", ""));
	assert.ok(changesSince <= readBefore - 10 * 60_000 && changesSince > readBefore - 10 * 60_000 - 2_000, "changes since ten minutes before the last read began");
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

	// ---- Detaching, and the preview off
	await client.call("github.detach", { projectId });
	await client.until("detached", () => client.github(projectId) === undefined);
	assert.deepEqual((await client.call("work.list", { projectId })).items.map((item: any) => item.id), [leftOver], "the list kept by pi² as it was left");
	await client.call("github.attach", { projectId, repository: "Example/Widgets" });
	await client.until("attached again", () => client.github(projectId)?.state === "ok");
	await client.call("projects.setPreview", { on: false });
	await assert.rejects(client.call("github.refresh", { projectId }), { message: PREVIEW_OFF });
	assert.equal(client.github(projectId).repository.name, "widgets", "the event keeps what was made");
	step("detaching goes back to the list kept by pi²; with the preview off the event stays and the requests are refused");
} finally {
	client.close();
	await stop(engine);
}
