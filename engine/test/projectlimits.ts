// Project limits (#464), over the socket on a throwaway engine with a scripted model and stand-in Usage readings.
import assert from "node:assert/strict";
import { type ChildProcess, execFileSync, spawn } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { type ProviderLimits } from "../src/limits.ts";
import { GONE } from "../src/needs.ts";
import { localMidnight, uncovered } from "../src/projectlimits.ts";
import { defaultProjectSettings, type LimitReading } from "../src/projects.ts";
import { conversationSpend } from "../src/projectspend.ts";
import { EngineClient, standInApp, stop } from "./patience.ts";

const home = mkdtempSync(join(tmpdir(), "pi2-pl-"));
const main = join(import.meta.dirname, "..", "src", "main.ts");
const feature = pathToFileURL(join(import.meta.dirname, "..", "src", "features.ts")).href;
const reading = join(home, "stand-in.json");
const bundle = standInApp();
const setup = `import { readFileSync } from 'node:fs';
import { FEATURES } from ${JSON.stringify(feature)};
const index = FEATURES.findIndex(f => f.name === 'limits');
if (index === -1) throw Error('No Usage readings feature');
const limits = FEATURES[index];
FEATURES[index] = (...args) => ({ ...limits(...args), planLimits: () => JSON.parse(readFileSync(${JSON.stringify(reading)}, 'utf8')) });`;
const preload = `data:text/javascript,${encodeURIComponent(setup)}`;
const demo = { provider: "demo", modelId: "demo-1" };
const reset = Date.now() + 3_600_000;
function plan(used?: number, resetsAt = reset, weekly?: number): void {
	const view: ProviderLimits = { id: "demo", name: "Stand-in", plan: "Test", reports: "usage", fetchedAt: used === undefined ? null : Date.now(), source: "usage", note: null, error: null, errorAt: null, refreshing: false,
		windows: [...(used === undefined ? [] : [{ id: "5h", label: "5-hour window", usedPercent: used, resetsAt }]), ...(weekly === undefined ? [] : [{ id: "7d", label: "This week", usedPercent: weekly, resetsAt: reset }])],
	};
	writeFileSync(reading, JSON.stringify([view]));
}
plan();
const KEYCHAIN_SERVICE = `dev.pi2.credentials.test-projectlimits-${process.pid}`;
const startEngine = () => spawn(process.execPath, ["--import", preload, main], { env: {
	...process.env, PI2_HOME: home, PI2_KEYCHAIN_SERVICE: KEYCHAIN_SERVICE, PI2_LOGIN_SHELL: "off", PI2_APP_BUNDLE: bundle, PI2_DEMO_TEXT_MODEL: "1", PI2_DEMO_COST: "10000", PI2_DEMO_TOKENS_PER_SECOND: "100000",
}, stdio: ["ignore", "ignore", "inherit"] });

let engine: ChildProcess | undefined;
process.on("exit", () => {
	if (engine !== undefined && engine.exitCode === null && engine.signalCode === null) engine.kill("SIGKILL");
	rmSync(home, { recursive: true, force: true });
});

class Client extends EngineClient {
	children(parent: number): any[] {
		return (this.events.library?.conversations ?? []).filter((row: any) => row.parent === parent);
	}
	cards(): any[] {
		return (this.events.needs?.items ?? []).filter((row: any) => row.kind === "limit");
	}
	items(id: number, kind: string): any[] {
		return (this.conversations.get(id)?.items ?? []).filter((row: any) => row.kind === kind);
	}
	async tool(id: number, tool: string, args: Record<string, unknown>): Promise<any> {
		const before = this.items(id, "assistant").length;
		const count = this.items(id, "tool").length;
		await this.call("submit", { id, text: `/tool ${tool} ${JSON.stringify(args)}` });
		return this.until(`${tool}'s result`, () => {
			const c = this.conversations.get(id);
			if (c === undefined || c.state.busy || this.items(id, "assistant").length <= before) return undefined;
			const result = this.items(id, "tool")[count];
			assert.ok(result, `${tool} produced no tool result: ${JSON.stringify(c.items.slice(-4))}`);
			return result;
		});
	}
	async refused(method: string, params: Record<string, unknown>): Promise<LimitReading> {
		let limit: LimitReading | undefined;
		await assert.rejects(this.call(method, params), (error: Error & { data?: { limit: LimitReading } }) => {
			assert.match(error.message, /^Past the project's limit:/);
			limit = error.data?.limit;
			return true;
		});
		assert.ok(limit?.id);
		return limit;
	}
}

// What a confirmed reading covers for its one start (#953), case by case, without an engine.
{
	const now = Date.now();
	const midnight = localMidnight(now);
	const spend = (used: number, max = 5, resetsAt = midnight): Omit<LimitReading, "id"> => ({ limit: "dailySpend", provider: null, window: null, used, max, resetsAt, reason: "spent" });
	const share = (window: string, used: number, max = 90, resetsAt = reset): Omit<LimitReading, "id"> => ({ limit: "planShare", provider: "demo", window, used, max, resetsAt, reason: "used" });
	const card = (...readings: Omit<LimitReading, "id">[]) => readings.map((reading, index) => ({ ...reading, id: `r${index}` }));
	assert.equal(uncovered([spend(5.5)], card(spend(5.2))), undefined, "more spent the same day, under the same limit");
	assert.equal(uncovered([spend(5.1)], card(spend(5.2))), undefined, "less spent than the card read");
	assert.equal(uncovered([spend(9, 8)], card(spend(5.2))), undefined, "a looser limit since");
	assert.deepEqual(uncovered([spend(5.5, 4)], card(spend(5.2))), spend(5.5, 4), "a tighter limit since");
	assert.deepEqual(uncovered([spend(0.2, 5, localMidnight(midnight + 1))], card(spend(5.2))), spend(0.2, 5, localMidnight(midnight + 1)), "a new day");
	assert.deepEqual(uncovered([share("5h", 95), spend(5.5)], card(spend(5.2))), share("5h", 95), "the plan's share, which the card did not name");
	assert.equal(uncovered([share("5h", 99)], card(share("5h", 92))), undefined, "the same window used more");
	assert.deepEqual(uncovered([share("5h", 99, 85)], card(share("5h", 92))), share("5h", 99, 85), "the plan's share made tighter");
	assert.deepEqual(uncovered([share("5h", 92, 90, reset + 1)], card(share("5h", 92))), share("5h", 92, 90, reset + 1), "the window reset and filled again");
	assert.equal(uncovered([share("5h", 91)], card(share("7d", 97))), undefined, "a lower window of the same plan");
	assert.deepEqual(uncovered([share("5h", 98)], card(share("7d", 97))), share("5h", 98), "a higher window of the same plan");
	assert.deepEqual(uncovered([share("7d", 97), share("5h", 91)], card(share("7d", 97))), share("5h", 91), "one reading covers one breach");
	assert.deepEqual(uncovered([spend(5.5)], []), spend(5.5), "nothing confirmed");
	console.log("ok  a confirmed reading covers its own limit however much more is spent; tighter, another limit or a new day does not");
}

const cid = (reply: { id: number }) => reply.id;
engine = startEngine();
let c = await Client.connect(engine, home);
let second: Client | undefined;
try {
	const repo = join(home, "repo");
	mkdirSync(repo);
	execFileSync("git", ["-C", repo, "init", "-qb", "test-base"]);
	execFileSync("git", ["-C", repo, "-c", "user.name=Stand-in", "-c", "user.email=test@example.invalid", "commit", "--quiet", "--allow-empty", "-m", "base"]);
	const { id: project, conversation: root } = await c.call("projects.create", { folder: repo });
	const row = (await c.call("projects.list")).projects.find((row: any) => row.id === project);
	assert.deepEqual(row.settings.limits, { planShare: 90, dailySpend: null });
	assert.deepEqual(defaultProjectSettings("carried").limits, { planShare: null, dailySpend: null });
	await c.call("conversation.open", { id: root });
	await c.call("conversation.configure", { id: root, model: demo });
	const worker = cid(await c.call("projects.addAgent", { projectId: project, agent: { name: "Worker", model: demo, access: "ask" } }));
	const make = { agentId: worker, model: demo };
	const set = (settings: object) => c.call("projects.set", { id: project, settings });

	assert.match((await c.call("conversation.create", make)).note, /no reading of this plan/);
	plan(99, Date.now() - 1000);
	assert.match((await c.call("conversation.create", make)).note, /no reading of this plan/);
	plan(89);
	const [a, b] = await Promise.all([c.call("conversation.create", make), c.call("conversation.create", make)]);
	assert.notEqual(a.id, b.id);
	assert.equal(a.note, undefined);
	console.log("ok  missing and expired readings do not block, and two concurrent starts below the limit both pass");

	plan(90);
	let refusal = await c.refused("conversation.create", make);
	assert.deepEqual({ ...refusal, reason: null, id: null }, { id: null, limit: "planShare", reason: null, provider: "demo", window: "5h", used: 90, max: 90, resetsAt: reset });
	await c.refused("conversation.create", { agentId: row.orchestratorId, model: demo, confirmLimit: refusal.id });
	// The same window, used more since the reading was confirmed, is still the start the person confirmed (#953).
	plan(93);
	assert.equal(typeof (await c.call("conversation.create", { ...make, confirmLimit: refusal.id })).id, "number");
	plan(91);
	refusal = await c.refused("conversation.create", make);
	second = await Client.connect(engine, home);
	const same = { ...make, confirmLimit: refusal.id };
	const retries = await Promise.allSettled([c.call("conversation.create", same), second.call("conversation.create", same)]);
	assert.equal(retries.filter((result) => result.status === "fulfilled").length, 1);
	assert.match((retries.find((result) => result.status === "rejected") as PromiseRejectedResult).reason.message, /^Past the project's limit:/);
	assert.equal(c.cards().length, 0);
	plan(98, reset, 99);
	const firstWindow = await c.refused("conversation.create", make);
	const secondWindow = await c.refused("conversation.create", { ...make, confirmLimit: firstWindow.id });
	assert.notEqual(firstWindow.window, secondWindow.window);
	assert.equal(typeof (await c.call("conversation.create", { ...make, confirmLimit: secondWindow.id })).id, "number");
	console.log("ok  structured error, exact start, the same window used more, both windows, and a confirmation used only once");

	const task = "Keep this exact task.\nSecond line.";
	const handoff = { agent: "Worker", title: "The held task", task, worktree: "held-464", from: "test-base", wait: true };
	const delegate = (args: Record<string, unknown>) => c.tool(root, "delegate", args);
	plan(89);
	const waiting = delegate(handoff);
	const approval = await c.until("the worktree approval", () => c.events.inbox?.items.find((item: any) => item.tool === "delegate"));
	plan(98, reset, 99);
	await c.call("inbox.decide", { id: approval.id, decision: "once" });
	const blocked = await waiting;
	assert.equal(blocked.isError, true);
	assert.match(blocked.text, /Not started: .*Start|Not started: .*project's limit/);
	assert.equal(c.children(root).length, 0);
	const card = await c.until("the limit card", () => c.cards()[0]);
	assert.deepEqual(card.start, { by: { kind: "agent", agentId: row.orchestratorId, conversationId: root }, agentId: worker, agentName: "Worker", kind: "new", parent: root, chat: null, work: null, title: handoff.title, task, options: { worktree: handoff.worktree, from: handoff.from, wait: true } });

	// The hand-off survives being refused, the engine stopping, and having the reading move again.
	c.close(); second.close(); second = undefined;
	await stop(engine);
	plan(100);
	engine = startEngine();
	c = await Client.connect(engine, home);
	await c.call("conversation.open", { id: root });
	const answer = (client: Client, id: string, start = true) => client.call("needs.answer", { id, answer: { kind: "limit", start } });
	assert.deepEqual((await c.call("needs.list", { projectId: project })).items[0].start, card.start);
	await answer(c, card.id);
	const updated = await c.until("the card with the new reading", () => c.cards().find((row) => row.id === card.id && row.limit.used === 100));
	assert.notEqual(updated.limit.id, card.limit.id);
	assert.equal(c.children(root).length, 0);
	plan(95);
	second = await Client.connect(engine, home);
	const answered = await Promise.allSettled([answer(c, card.id), answer(second, card.id)]);
	assert.equal(answered.filter((result) => result.status === "fulfilled").length, 1);
	assert.equal((answered.find((result) => result.status === "rejected") as PromiseRejectedResult).reason.message, GONE);
	const child = await c.until("only one new child", () => c.children(root)[0]);
	assert.equal(child.title, handoff.title);
	await c.call("conversation.open", { id: child.id });
	await c.until("the allowed hand-off finished", () => !c.conversations.get(child.id)?.state.busy && c.items(child.id, "assistant").length > 0);
	assert.deepEqual(c.items(child.id, "user").map((row) => row.text), [task]);
	assert.equal(c.children(root).length, 1);
	assert.match(execFileSync("git", ["-C", repo, "worktree", "list", "--porcelain"], { encoding: "utf8" }), /branch refs\/heads\/held-464/);
	await assert.rejects(answer(c, card.id), { message: GONE });
	console.log("ok  the whole hand-off is durable; refreshed card, two answers, task and worktree preserved");

	const kept = await delegate({ agent: "Worker", chat: child.id, task: "Continue the same conversation", title: "New title", wait: false });
	assert.equal(kept.isError, true);
	const continued = await c.until("the continue card", () => c.cards().find((row) => row.start.chat === child.id));
	await answer(c, continued.id, false);
	assert.equal(c.items(child.id, "user").length, 1);
	assert.equal(c.children(root).length, 1);
	const again = await delegate({ agent: "Worker", chat: child.id, task: "This exact continuation", title: "Continued title", wait: false });
	assert.match(again.text, /Not started:/);
	await answer(c, (await c.until("second continue card", () => c.cards().find((row) => row.start.chat === child.id))).id);
	await c.until("same child continued once", () => !c.conversations.get(child.id)?.state.busy && c.items(child.id, "user").length === 2);
	assert.deepEqual(c.items(child.id, "user").map((row) => row.text), [task, "This exact continuation"]);
	assert.equal(c.children(root).length, 1);

	const { id: work } = await c.call("work.create", { projectId: project, title: "Original title", text: "Original work text." });
	const assignment = await c.tool(root, "work", { action: "assign", id: work, agent: "Worker", task: "Extra directions." });
	assert.match(assignment.text, /Not started:/);
	const workCard = await c.until("assignment's card", () => c.cards().find((row) => row.start.work === work));
	assert.equal((await c.call("work.list", { projectId: project })).items[0].state, "open");
	await c.call("work.act", { projectId: project, id: work, action: "edit", text: "Edited after the hand-off was asked for." });
	await answer(c, workCard.id);
	const item = (await c.call("work.list", { projectId: project })).items[0];
	assert.equal(item.state, "in_progress");
	const assigned = item.takenBy.conversationId;
	await c.call("conversation.open", { id: assigned });
	await c.until("held assignment submitted", () => c.items(assigned, "user")[0]);
	assert.equal(c.items(assigned, "user")[0].text, "Work #1: Original title\n\nOriginal work text.\n\nExtra directions.");
	const { id: work2 } = await c.call("work.create", { projectId: project, title: "Person assigns" });
	const assign = { projectId: project, id: work2, action: "assign", agentId: worker };
	const assignLimit = await c.refused("work.act", assign);
	assert.equal(typeof (await c.call("work.act", { ...assign, confirmLimit: assignLimit.id })).conversation, "number");
	console.log("ok  a held assignment commits the claim and the original task once; the person can confirm an assignment too");

	await set({ wakeOnReports: true, withoutAsking: { passLimits: true } });
	const passed = await delegate({ agent: "Worker", task: "Finish without waking the parent", wait: false });
	assert.match(passed.text, /Passed a project limit:/);
	const reports = await c.until("ended unread report although report wakes are on", () => c.events.reports?.projects?.[project]?.some((r: any) => r.ended && r.delivered === null && r.title.includes("without waking")));
	assert.ok(reports);
	assert.equal(c.items(root, "marker").filter((row) => row.text.startsWith("pi² woke the agent")).length, 0);
	console.log("ok  Leave It starts nothing; passLimits permits starts but never report wakes");

	// The report is eligible when it ends; hold its recipient busy until it would cross the limit.
	plan(89);
	await delegate({ agent: "Worker", task: "/ask Release the report?", title: "Late limit report", wait: false });
	const inbox = (id: number) => c.until(`question from ${id}`, () => c.events.inbox?.items.find((item: any) => item.kind === "question" && item.conversationId === id));
	const late = await c.until("late report child", () => c.children(root).find((each) => each.title === "Late limit report"));
	const childQuestion = await inbox(late.id);
	await c.call("submit", { id: root, text: "/ask Keep the parent busy?" });
	const rootQuestion = await inbox(root);
	await c.call("inbox.answer", { id: childQuestion.id, text: "Yes" });
	await c.until("eligible report arrived but did not wake the busy parent", () => c.events.wakes?.items?.find((item: any) => item.ref === String(late.id) && item.state === "arrived"));
	plan(95);
	await c.call("inbox.answer", { id: rootQuestion.id, text: "Done" });
	await c.until("the wake was withdrawn, not submitted", () => !c.conversations.get(root)?.state.busy && !c.events.wakes?.items?.some((item: any) => item.ref === String(late.id)));
	assert.equal(c.events.reports.projects[project].find((r: any) => r.conversationId === late.id).delivered, null);
	assert.equal(c.items(root, "marker").filter((row) => row.text.startsWith("pi² woke the agent")).length, 0);
	console.log("ok  a previously eligible report is checked again when its wake would start");

	const usage = await c.until("project's spend", () => c.events.usage?.projects?.find((row: any) => row.id === project && row.today.cost > 0));
	assert.ok(usage.today.tokens > 0);
	await set({ withoutAsking: { passLimits: false }, limits: { planShare: null, dailySpend: 0.01 } });
	assert.equal((await c.refused("conversation.create", make)).limit, "dailySpend");
	const before = c.items(root, "assistant").length;
	await c.call("submit", { id: root, text: "The person's own turn still goes ahead" });
	await c.until("person's turn finished", () => !c.conversations.get(root)?.state.busy && c.items(root, "assistant").length > before);
	const unaffected = await c.call("conversation.create", { agentId: "forge", model: demo });
	assert.equal(unaffected.note, undefined);
	assert.equal(typeof unaffected.id, "number");
	console.log("ok  project daily spending, and ordinary person turns");

	// #953: one press of Start Anyway starts what the card holds, though the project spent more under the same limit since.
	const grew = await delegate({ agent: "Worker", title: "Spend grew", task: "Start after more was spent", wait: false });
	assert.match(grew.text, /Not started:/);
	const spendCard = await c.until("the daily-spend card", () => c.cards().find((row) => row.start.title === "Spend grew"));
	assert.equal(spendCard.limit.limit, "dailySpend");
	const spent = c.items(root, "assistant").length;
	await c.call("submit", { id: root, text: "Spend a little more today" });
	await c.until("that turn finished", () => !c.conversations.get(root)?.state.busy && c.items(root, "assistant").length > spent);
	await c.until("more spent than the card read", () => c.events.usage?.projects?.find((row: any) => row.id === project && row.today.cost > spendCard.limit.used));
	assert.deepEqual(await answer(c, spendCard.id), {});
	await c.until("the held start ran", () => c.children(root).find((each) => each.title === "Spend grew"));
	await c.until("the card taken off the list", () => !c.cards().some((row) => row.id === spendCard.id) || undefined);
	console.log("ok  Start Anyway on a daily-spend card starts it once, though spend grew since the card");

	// What is still a new decision: held again, the card kept with the new reading, and the answer says so.
	const heldAgain = async (title: string, change: () => Promise<unknown>, kind: string) => {
		assert.match((await delegate({ agent: "Worker", title, task: `${title}.`, wait: false })).text, /Not started:/);
		const held = await c.until(`the card for ${title}`, () => c.cards().find((row) => row.start.title === title));
		await change();
		const result = await answer(c, held.id);
		assert.equal(result.held, true);
		assert.equal(result.limit.limit, kind);
		assert.notEqual(result.limit.id, held.limit.id);
		await c.until(`the card for ${title} with its new reading`, () => c.cards().find((row) => row.id === held.id && row.limit.id === result.limit.id));
		assert.equal(c.children(root).some((each) => each.title === title), false);
		return held;
	};
	const tighter = await heldAgain("Tighter limit", () => set({ limits: { planShare: null, dailySpend: 0.005 } }), "dailySpend");
	assert.deepEqual(await answer(c, tighter.id), {});
	await c.until("the start under the tighter limit ran", () => c.children(root).find((each) => each.title === "Tighter limit"));
	const other = await heldAgain("Another limit", async () => { plan(95); await set({ limits: { planShare: 90, dailySpend: 0.005 } }); }, "planShare");
	assert.deepEqual(await answer(c, other.id), {});
	await c.until("the start past both limits ran", () => c.children(root).find((each) => each.title === "Another limit"));
	console.log("ok  a tighter limit, or another limit the card did not name, holds it again with a distinct answer");
} finally {
	c.close(); second?.close();
	await stop(engine);
}

// Same-day reattribution uses what was spent today, not all of the conversation's history.
const yesterday = conversationSpend(undefined, { cost: 5, tokens: 100 }, "day 1");
const today = conversationSpend(yesterday, { cost: 6, tokens: 130 }, "day 2");
assert.deepEqual(today.today, { cost: 1, tokens: 30 });
assert.deepEqual(conversationSpend(today, { cost: 0, tokens: 140 }, "day 2").today, { cost: 0, tokens: 40 });
