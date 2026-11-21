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
	override receive(message: any): void {
		if (typeof message.event === "string") this.order.push(message.event);
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
const value = (tool: { isError: boolean; text: string }) => {
	assert.equal(tool.isError, false, tool.text);
	return JSON.parse(tool.text.split("\n\n(GitHub's listing")[0]!);
};
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
	for (const method of ["github.attach", "github.detach", "github.refresh", "github.merge", "github.sendBack", "github.diff", "github.unknown", "github.settle", "projects.watch"]) {
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
	const filed = value(await client.work(worker, "file", { title: "Make widgets blue", text: "They are grey.", class: "cloud" }));
	assert.deepEqual([filed.id, filed.state, filed.class, filed.filedBy, filed.text, filed.url], [1, "open", "cloud", { kind: "agent", agentId: workerId, conversationId: worker }, "They are grey.", "https://github.com/example/widgets/issues/1"]);
	const issue = widgets().issues[0];
	assert.match(issue.body, /^\*From Worker, an agent of the pi² project “Widgets”\.\*\n\nThey are grey\.\n\n<!-- pi2:[0-9a-f]{16} -->$/);
	assert.deepEqual(issue.labels.map((label: any) => label.name).sort(), ["backlog", "cloud model"]);
	assert.deepEqual(widgets().labels.map((label) => label.name).sort(), ["backlog", "blocked", "cloud model", "in progress", "local model", "waiting"]);
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
	assert.deepEqual(value(a.isError ? b : a).takenBy, { agentId: winnerAgent, conversationId: winner });
	// Both claimed and the later one let go, or the later one read the issue after the first was in progress and claimed
	// nothing: either way, one claim stands.
	const comments = widgets().issues[0].comments.map((comment: any) => comment.body.split("\n\n")[1]);
	const claims = comments.filter((text: string) => text.startsWith("Taken by")).length;
	assert.equal(claims - comments.filter((text: string) => text.startsWith("Released")).length, 1, comments.join(" / "));
	console.log(`    (${claims === 2 ? "both claimed; the later one let go" : "the later one found it taken before claiming"})`);
	assert.deepEqual(widgets().issues[0].labels.map((label: any) => label.name).sort(), ["cloud model", "in progress"]);
	if (winner !== worker) {
		await client.work(winner, "release", { id: 1 });
		value(await client.work(worker, "take", { id: 1 }));
	}
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
	value(await client.work(parent, "classify", { id: 1, class: "cloud" }));
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
	value(await client.work(parent, "classify", { id: 1, class: "cloud" }));
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
	value(await client.work(worker, "file", { title: "Second" }));
	value(await client.work(worker, "take", { id: 4 }));
	value(await client.work(parent, "note", { id: 4, text: "The orchestrator's note" }));
	value(await client.work(worker, "note", { id: 4, text: "The worker's note" }));
	const { id: localItem } = await client.call("work.create", { projectId: local, title: "Local work" });
	value(await client.work(localParent, "note", { id: localItem, text: "The orchestrator's note" }));
	value(await client.work(localWorker, "note", { id: localItem, text: "The helper's note" }));
	await offline(async (harness) => {
		const news = (await harness.snapshot(Projects, context))!.news;
		const notes = (id: string) => (news[id] ?? []).filter((item) => item.kind === "work" && item.text.endsWith("(note)."));
		assert.equal(notes(projectId).length, 1, "on GitHub, only the worker's note");
		assert.equal(notes(local).length, 1, "kept by pi², only the helper's note");
	});
	for (const id of [parent, worker, reviewer]) await client.call("conversation.open", { id });
	step("an action by the orchestrator adds no news for the orchestrator, on GitHub and in the list kept by pi²");

	// ---- The admission check comes before a GitHub assignment claims an item
	value(await client.work(worker, "file", { title: "Held back" }));
	await client.until("spending counted", () => client.events.usage?.projects?.find((row: any) => row.id === projectId && row.today.cost > 0));
	await client.call("projects.set", { id: projectId, settings: { limits: { planShare: null, dailySpend: 0.01 } } });
	refusal(await client.work(parent, "assign", { id: 5, agent: "Worker" }), /^Not started: the project has spent \$/);
	assert.deepEqual(widgets().issues.find((one) => one.number === 5).comments, [], "nothing claimed");
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
	value(await client.work(worker, "note", { id: 4, text: "Back again" }));
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
	value(await client.work(worker, "file", { title: "Lost before the write" }));
	assert.equal(widgets().issues.filter((one) => one.title === "Lost before the write").length, 1, "filed once, by hand, after it was settled");

	const kept = await crash("Made before the crash", "after");
	assert.equal(value(kept).title, "Made before the crash");
	assert.equal(widgets().issues.filter((one) => one.title === "Made before the crash").length, 1, "found by its marker, not made again");
	assert.deepEqual(client.github(projectId)?.unknown ?? (await client.until("listing", () => client.github(projectId))).unknown, []);
	const durable = await client.until("pull requests after restarts", () => client.github(projectId)?.pulls?.find((one: any) => one.number === 2));
	assert.deepEqual(durable.openedBy, { conversationId: worker }, "openedBy kept durably");
	step("killed between an intent and its write: unknown, reported, settled by the person; between the write and its record: found, not made twice");

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
