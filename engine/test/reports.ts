// Reports, and when one wakes the orchestrator (#463; docs/projects.md 3.10, 5.6 and 8.2): a real engine on a throwaway
// data folder, driven over its socket with the demo model, as an app would drive it.
//
// With the preview never on, the empty `reports` event and `reports.wake` refused. Then a project whose orchestrator
// hands work out: with the project's default, ten sub-chats ending wake nobody and the orchestrator makes no request;
// their reports are listed and read, each once. `delegate` waiting takes its own run's report. Then each choice of
// `reports` `wake`: each, a batch woken once when all of it has ended, a batch woken only at its first failure (with a
// failure among answers), never; `sub_chats` with `wait` taking a report that woke nobody; the person's `reports.wake`;
// the project's switch on, which wakes as today; an engine stopped and started again in the middle of a batch; and the
// preview off again, with which waking is exactly as wakes.md says.

import assert from "node:assert/strict";
import { type ChildProcess, execFileSync, spawn } from "node:child_process";
import { closeSync, existsSync, mkdirSync, mkdtempSync, openSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import type { Host } from "../src/extensions.ts";
import type { Engine } from "../src/features.ts";
import { defaultProjectSettings, PREVIEW_OFF, type Project, type ProjectsDoc, projects } from "../src/projects.ts";
import { pastLimit, type Report, type ReportsDoc, type ReportWake, reports, settle } from "../src/reports.ts";
import { Inbox, type Meta } from "../src/state.ts";
import type { Watch, WakesDoc } from "../src/wakes.ts";
import { EngineClient, exited, running, stop } from "./patience.ts";

const home = mkdtempSync(join(tmpdir(), "pi2-rep-"));
const scratch = realpathSync(mkdtempSync(join(tmpdir(), "pi2-rep-work-")));
const main = join(import.meta.dirname, "..", "src", "main.ts");
const KEYCHAIN_SERVICE = `dev.pi2.credentials.test-reports-${process.pid}`;
process.env.PI2_DEMO_TOKENS_PER_SECOND ??= "100000";
process.env.PI2_LOGIN_SHELL ??= "off";
const env = { ...process.env, PI2_HOME: home, PI2_KEYCHAIN_SERVICE: KEYCHAIN_SERVICE };
const engineLog = join(home, "engine.log");

function step(name: string): void {
	console.log(`ok  ${name}`);
}

// ---- What a later issue fills in, as it is until then

assert.equal(pastLimit("p-any"), false);
step("until #464, no project is past a limit for its reports");

// ---- settle, alone: a stand-in engine and host, as projectseams.ts has them, and a stand-in commit
{
	const project: Project = {
		id: "p1",
		name: "p1",
		folder: null,
		repository: null,
		orchestratorId: "o",
		conversation: 1,
		earlier: [],
		settings: defaultProjectSettings("new"),
		createdAt: 1,
		updatedAt: 1,
	};
	const stored: ProjectsDoc = { projects: { p1: project }, carry: { ranAt: null, backup: null, folders: {}, copies: {}, notes: {}, secrets: [] }, news: {}, nextNews: 1 };
	const meta = (parent?: number): Meta => ({ title: "", createdAt: 1, updatedAt: 1, access: "ask", agentId: "a", projectId: "p1", ...(parent === undefined ? {} : { parent }) });
	const conversations: Record<string, Meta> = { 1: meta(), 11: meta(1), 12: meta(1), 13: meta(1), 14: meta(1) };
	const standIn = {
		harness: () => ({ snapshot: async () => structuredClone(stored), observeCommits: () => ({ detach() {} }) }),
		context: () => BACKGROUND_CONTEXT,
		setting: () => ({ preview: true }),
		saveSetting: () => {},
		broadcast: () => {},
		log: () => {},
		agents: () => ({}),
	} as unknown as Engine;
	const host = { inbox: new Inbox(async () => false), conversations: () => conversations, working: () => false, features: [], agent: () => ({ name: "Worker" }) } as unknown as Host;
	await projects(host, standIn).start!();
	reports(host, standIn);
	const report = (submissionId: number, conversationId: number, batch: string | null = null): Report => ({ submissionId, conversationId, agentId: "w", title: `T${conversationId}`, batch, work: null, ended: null, delivered: null });
	const watch = (submissionId: number, chat: number, wake?: ReportWake, batch?: string): Watch => ({
		key: `delegate:${submissionId}`,
		conversationId: 1,
		kind: "subchat",
		ref: String(chat),
		label: `sub-chat ${chat}`,
		startedAt: 1,
		submissionId,
		...(wake === undefined ? {} : { wake }),
		...(batch === undefined ? {} : { batch }),
	});
	const docs: { reports: ReportsDoc; wakes: WakesDoc; projects: ProjectsDoc } = {
		reports: { projects: { p1: [report(101, 11), report(102, 12, "b"), report(103, 13, "b"), report(104, 14, "b")] } },
		wakes: { watching: {}, arrived: {}, woken: {}, held: {}, seen: {} },
		projects: structuredClone(stored),
	};
	for (const each of [watch(101, 11), watch(102, 12, "all", "b"), watch(103, 13, "all", "b"), watch(104, 14, "all", "b")]) docs.wakes.watching[each.key] = each;
	const tx = { doc: async (token: { definition: { kind: string } }) => ({ "pi2.reports": docs.reports, "pi2.wakes": docs.wakes, "pi2.projects": docs.projects })[token.definition.kind] } as never;
	const news = () => docs.projects.news.p1 ?? [];

	// The project's default (off): an end wakes nobody, and is news once.
	assert.deepEqual(await settle(tx, 101, { by: "end", outcome: "answered" }), { give: false, wake: [] });
	assert.equal(docs.reports.projects.p1![0]!.ended?.outcome, "answered");
	assert.equal(docs.wakes.watching["delegate:101"], undefined, "its watch is let go");
	assert.equal(news().length, 1);
	assert.match(news()[0]!.text, /^Sub-chat 11 “T11” \(Worker\) answered at \d\d:\d\d; not read yet\.$/);
	assert.deepEqual(await settle(tx, 101, { by: "end" }), { give: false, wake: [] });
	assert.equal(news().length, 1, "decided again, it is news once");
	// A read takes it, and its news goes; nothing gives it again.
	assert.deepEqual(await settle(tx, 101, { by: "read", conversationId: 1 }), { give: true, wake: [] });
	assert.equal(docs.reports.projects.p1![0]!.delivered?.by, "read");
	assert.equal(news().length, 0);
	for (const ask of [{ by: "read", conversationId: 1 }, { by: "wait", conversationId: 1 }, { by: "wake", conversationId: 1 }, { by: "wait", conversationId: 1, again: true }] as const) {
		assert.equal((await settle(tx, 101, ask)).give, false, ask.by);
	}
	// A batch of three with all: nothing until the last has ended, then every one not given, oldest first.
	assert.deepEqual(await settle(tx, 103, { by: "end", outcome: "failed" }), { give: false, wake: [] });
	assert.equal((await settle(tx, 102, { by: "read", conversationId: 1 })).give, false, "a run going is not read");
	assert.deepEqual(await settle(tx, 102, { by: "end", outcome: "answered" }), { give: false, wake: [] });
	assert.equal((await settle(tx, 102, { by: "read", conversationId: 1 })).give, true, "read meanwhile");
	assert.deepEqual(await settle(tx, 104, { by: "end", outcome: "stopped" }), { give: false, to: 1, wake: [103, 104] });
	assert.equal(news().length, 2, "each end not delivered then is news");
	// The wake carries them: each is given once, and its news goes.
	assert.equal((await settle(tx, 103, { by: "wake", conversationId: 1 })).give, true);
	assert.equal((await settle(tx, 103, { by: "wake", conversationId: 1 })).give, false);
	assert.equal((await settle(tx, 104, { by: "wait", conversationId: 1 })).give, true, "a wait that comes first takes it");
	assert.equal((await settle(tx, 104, { by: "wake", conversationId: 1 })).give, false, "and the wake then does not");
	assert.equal(news().length, 0);
	// A run with no report is given as today.
	assert.deepEqual(await settle(tx, 999, { by: "wake", conversationId: 1 }), { give: true, wake: [] });

	// failure: answers wake nobody; the first failure wakes with those before it; later runs nobody.
	docs.reports.projects.p1!.push(report(201, 11, "f"), report(202, 12, "f"), report(203, 13, "f"), report(204, 14));
	for (const each of [watch(201, 11, "failure", "f"), watch(202, 12, "failure", "f"), watch(203, 13, "failure", "f"), watch(204, 14, "each")]) docs.wakes.watching[each.key] = each;
	assert.deepEqual(await settle(tx, 201, { by: "end", outcome: "answered" }), { give: false, wake: [] });
	assert.deepEqual(await settle(tx, 202, { by: "end", outcome: "failed" }), { give: false, to: 1, wake: [201, 202] });
	assert.deepEqual(await settle(tx, 203, { by: "end", outcome: "stopped" }), { give: false, wake: [] });
	// each, chosen for one run, overrides the project's switch.
	assert.deepEqual(await settle(tx, 204, { by: "end", outcome: "answered" }), { give: false, to: 1, wake: [204] });
	// The project's switch on: a run with no choice of its own wakes, as today.
	docs.reports.projects.p1!.push(report(301, 11));
	docs.wakes.watching["delegate:301"] = watch(301, 11);
	await projects(host, { ...standIn, harness: () => ({ snapshot: async () => ({ ...structuredClone(stored), projects: { p1: { ...project, settings: { ...project.settings, wakeOnReports: true } } } }), observeCommits: () => ({ detach() {} }) }) } as unknown as Engine).start!();
	assert.deepEqual(await settle(tx, 301, { by: "end", outcome: "answered" }), { give: false, to: 1, wake: [301] });
	step("settle: each end, read, wait and wake decided in one place; each report given once; news added and taken away");
}

type Event = Record<string, any>;
class Client extends EngineClient {
	/** The events' names, in the order they came. */
	order: string[] = [];
	override receive(message: any): void {
		if (typeof message.event === "string") this.order.push(message.event);
		super.receive(message);
	}
	static async attach(engine: ChildProcess): Promise<Client> {
		const client = await Client.connect(engine, home);
		await client.until("first events", () => client.events.providers && client.events.wakes && client.events.reports && client.events.agents);
		return client;
	}
	items(id: number, kind: string): Event[] {
		return this.conversations.get(id)?.items.filter((item: Event) => item.kind === kind) ?? [];
	}
	wakes(id: number): string[] {
		return this.items(id, "marker")
			.map((item) => item.text as string)
			.filter((text) => text.startsWith("pi² woke the agent"));
	}
	watched(id: number): Event[] {
		return (this.events.wakes?.items ?? []).filter((item: Event) => item.conversationId === id);
	}
	idle(id: number): boolean {
		const conv = this.conversations.get(id);
		return conv !== undefined && !conv.state.busy;
	}
	/** Every report of project `projectId`, as the `reports` event has it. */
	reports(projectId: string): Event[] {
		return this.events.reports?.projects?.[projectId] ?? [];
	}
	reportOf(projectId: string, chat: number): Event | undefined {
		return this.reports(projectId)
			.filter((report) => report.conversationId === chat)
			.at(-1);
	}
	/** Whether the run of sub-chat `chat` has ended, as the `reports` event says. */
	ended(projectId: string, chat: number): boolean {
		return (this.reportOf(projectId, chat)?.ended ?? null) !== null;
	}
	/** Sends a message the demo model answers with `count` tool calls, and returns their results once the answer is in. */
	async tools(id: number, text: string, count = 1): Promise<Event[]> {
		const before = this.items(id, "tool").length;
		await this.call("submit", { id, text });
		return await this.until(`results of ${text.slice(0, 80)}`, () => {
			const conv = this.conversations.get(id);
			const results = this.items(id, "tool");
			if (conv === undefined || conv.state.busy || results.length < before + count) return undefined;
			const after = conv.items.slice(conv.items.indexOf(results[before + count - 1]) + 1);
			return after.some((item: Event) => item.kind === "assistant") ? results.slice(before, before + count) : undefined;
		});
	}
	async tool(id: number, text: string): Promise<Event> {
		return (await this.tools(id, text))[0]!;
	}
	/** Waits for the agent to have been woken `count` times in all, and for that answer to be over. */
	async woken(id: number, count: number): Promise<string> {
		await this.until(`wake ${count} of conversation ${id}`, () => this.wakes(id).length >= count && this.idle(id));
		assert.equal(this.wakes(id).length, count, `woken exactly ${count} times: ${JSON.stringify(this.wakes(id))}`);
		return this.wakes(id)[count - 1]!;
	}
}

/** Every command here waits for a file of its own, or for the one that lets them all go when the test ends. */
const all = join(scratch, "all-gates");
let gates = 0;
const gate = (): { path: string; open: () => void; wait: string } => {
	const path = join(scratch, `gate-${++gates}`);
	return { path, open: () => writeFileSync(path, ""), wait: `until [ -e '${path}' ] || [ -e '${all}' ]; do sleep 0.05; done` };
};
const work = join(scratch, "work");
const folder = join(scratch, "project");
mkdirSync(work);
mkdirSync(folder);
/** A sub-chat's task: a command that waits for `g`, then says `word`. */
const task = (g: { wait: string }, word: string) => `/timeout 600 ${g.wait}; echo ${word}`;
const handOffCall = (text: string, title: string, wait = false) => ({ name: "delegate", arguments: { agent: "Worker", task: text, title, ...(wait ? {} : { wait: false }) } });

const boot = () => {
	const log = openSync(engineLog, "a");
	try {
		return spawn(process.execPath, [main], { env, stdio: ["ignore", "ignore", log] });
	} finally {
		closeSync(log);
	}
};
let passed = false;
let engine: ChildProcess = boot();
let client: Client | undefined;
try {
	client = await Client.attach(engine);
	const c = () => client!;

	// ---- With the preview never on

	assert.deepEqual(c().events.reports, { event: "reports", projects: {} });
	assert.ok(c().order.indexOf("reports") > c().order.indexOf("projects"), c().order.join(" "));
	await assert.rejects(c().call("reports.wake", { projectId: "p-x", chats: [1], when: "each" }), { message: PREVIEW_OFF });
	step("with the preview never on: the empty reports event after the projects event, and reports.wake refused");

	// ---- A project whose orchestrator hands work out

	const worker = (await c().call("agents.save", { agent: { name: "Worker", description: "Does the work", access: "full", cwd: work } })).id as string;
	const lead = (await c().call("agents.save", { agent: { name: "Lead", description: "Hands out work", access: "full", cwd: work, delegates: [worker] } })).id as string;
	await c().call("projects.setPreview", { on: true });
	const made = await c().call("projects.create", { folder });
	const projectId = made.id as string;
	const oc = made.conversation as number;
	const orchestratorId = (await c().until("the project", () => c().events.projects.projects.find((row: Event) => row.id === projectId))).orchestratorId;
	const orchestrator = await c().until("the orchestrator", () => c().events.agents.agents.find((agent: Event) => agent.id === orchestratorId));
	// Until #457 names the project's agents for it, the orchestrator is given one to hand work to.
	await c().call("agents.save", { agent: { ...orchestrator, delegates: [worker] } });
	await c().until("its delegates", () => c().events.agents.agents.find((agent: Event) => agent.id === orchestratorId)?.delegates?.includes(worker));
	await c().call("conversation.open", { id: oc });
	await c().until("open", () => c().conversations.get(oc)?.state !== undefined);
	assert.equal(c().events.projects.projects.find((row: Event) => row.id === projectId).settings.wakeOnReports, false, "off for a new project");
	const empty = await c().tool(oc, '/tool reports {"action":"list"}');
	assert.equal(empty.isError, false, empty.text);
	assert.match(empty.text, /^No report is waiting to be read\.$/);
	// Nowhere else: a conversation in no project is not offered it.
	const plain = (await c().call("conversation.create", { agentId: lead })).id as number;
	await c().call("conversation.open", { id: plain });
	const unknown = await c().tool(plain, '/tool reports {"action":"list"}');
	assert.equal(unknown.isError, true);
	assert.doesNotMatch(unknown.text, /report is waiting/);
	step("the orchestrator is offered reports, and a conversation in no project is not");

	// ---- With the project's default: ten sub-chats ending wake nobody

	const ten = gate();
	const started = await c().tools(oc, `/tools ${JSON.stringify(Array.from({ length: 10 }, (_, n) => handOffCall(task(ten, `done-${n + 1}`), `Part ${n + 1}`)))}`, 10);
	for (const result of started) {
		assert.equal(result.isError, false, result.text);
		assert.match(result.text, /is working on it\. Its report waits for you unread; you are not woken for it \(the project's setting\)\. To be woken, use reports with action wake\./);
	}
	// The results come in the order the calls ended; the sub-chats are known by their titles.
	const titled = (title: string) => c().events.library.conversations.find((row: Event) => row.parent === oc && row.title === title).id as number;
	const parts = started.map((_, n) => titled(`Part ${n + 1}`));
	await c().until("ten reports, running", () => parts.every((chat) => c().reportOf(projectId, chat)?.ended === null));
	for (const chat of parts) {
		const report = c().reportOf(projectId, chat)!;
		assert.equal(report.batch, null);
		assert.equal(report.work, null);
		assert.equal(report.delivered, null);
		assert.equal(report.agentId, worker);
	}
	const watching = c().watched(oc);
	assert.equal(watching.length, 10);
	assert.ok(watching.every((item) => item.projectId === projectId && item.wake === null && item.batch === null), JSON.stringify(watching[0]));
	const listedSubChats = await c().tool(oc, '/tool sub_chats {"action":"list"}');
	assert.doesNotMatch(listedSubChats.text, /its answer will come to you as a message/, "sub_chats does not say the answer comes as a message");
	const answers = c().items(oc, "assistant").length;
	ten.open();
	await c().until("ten reports ended", () => parts.every((chat) => c().reportOf(projectId, chat)?.ended?.outcome === "answered"));
	await c().until("nothing left to wake it for", () => c().watched(oc).length === 0);
	assert.equal(c().wakes(oc).length, 0, "not woken");
	assert.equal(c().items(oc, "assistant").length, answers, "and no request made by the orchestrator");
	assert.ok(parts.every((chat) => c().reportOf(projectId, chat)!.delivered === null), "undelivered");
	step("with the project's default, ten sub-chats ending wake nobody: their reports wait unread and the orchestrator makes no request");

	const listed = await c().tool(oc, '/tool reports {"action":"list"}');
	assert.match(listed.text, /^Reports not read yet \(10\):\n(- Sub-chat \d+ “Part \d+” \(Worker\) answered at \d\d:\d\d\.\n){10}reports with action read gives them\.$/);
	const two = await c().tool(oc, `/tool reports ${JSON.stringify({ action: "read", chats: parts.slice(0, 2) })}`);
	assert.equal(two.isError, false, two.text);
	const given: string[] = two.text.split("\n\n---\n\n");
	assert.equal(given.length, 2);
	// Oldest first, by when each run ended, which is in no fixed order here.
	const first = given.find((each) => each.includes("“Part 1”"))!;
	assert.match(first, new RegExp(`^Sub-chat ${parts[0]} “Part 1” answered:[\\s\\S]*done-1[\\s\\S]*call delegate again with chat: ${parts[0]}\\.\\)[\\s\\S]*Used: `));
	assert.ok(given.some((each) => /done-2/.test(each)));
	await c().until("two delivered by read", () => parts.slice(0, 2).every((chat) => c().reportOf(projectId, chat)?.delivered?.by === "read"));
	assert.equal(c().reportOf(projectId, parts[0]!)!.delivered.conversationId, oc);
	const rest = await c().tool(oc, '/tool reports {"action":"read"}');
	assert.equal(rest.text.split("\n\n---\n\n").length, 8);
	assert.doesNotMatch(rest.text, /done-1\b|done-2\b/, "a report read is not given again");
	for (let n = 3; n <= 10; n++) assert.match(rest.text, new RegExp(`done-${n}\\b`));
	assert.match((await c().tool(oc, '/tool reports {"action":"read"}')).text, /^No report is waiting to be read\.$/);
	await c().until("every one delivered", () => parts.every((chat) => c().reportOf(projectId, chat)?.delivered?.by === "read"));
	step("reports list names the reports not read; read gives each once, as delegate would have, and the event says so");

	// ---- delegate waiting takes its own run's report

	const waitedFor = await c().tool(oc, `/tool delegate ${JSON.stringify({ agent: "Worker", task: "/bash echo waited-answer", title: "Waited" })}`);
	assert.match(waitedFor.text, /waited-answer/);
	const waitedChat = waitedFor.details.conversationId as number;
	await c().until("delivered by the wait", () => c().reportOf(projectId, waitedChat)?.delivered?.by === "wait");
	assert.equal(c().reportOf(projectId, waitedChat)!.ended.outcome, "answered");
	assert.match((await c().tool(oc, '/tool reports {"action":"read"}')).text, /^No report is waiting to be read\.$/);
	step("delegate waiting for its run takes its report, which is then given to no one else");

	// ---- each

	const g1 = gate();
	const [one] = await c().tools(oc, `/tools ${JSON.stringify([handOffCall(task(g1, "each-answer"), "Each")])}`);
	const eachChat = one!.details.conversationId as number;
	const chosen = await c().tool(oc, `/tool reports ${JSON.stringify({ action: "wake", chats: [eachChat], when: "each" })}`);
	assert.equal(chosen.text, `You will be woken when sub-chat ${eachChat} ends.`);
	assert.equal(c().watched(oc)[0]!.wake, "each");
	g1.open();
	assert.equal(await c().woken(oc, 1), `pi² woke the agent: sub-chat ${eachChat} “Each” answered`);
	assert.match(c().items(oc, "assistant").at(-1)!.text, /each-answer/);
	await c().until("delivered by the wake", () => c().reportOf(projectId, eachChat)?.delivered?.by === "wake");
	step("reports wake each: the run's report wakes the orchestrator, as a wake does today");

	// ---- all: one batch, woken once when all of it has ended

	const batchGates = [gate(), gate(), gate()];
	const batch = await c().tools(oc, `/tools ${JSON.stringify(batchGates.map((g, n) => handOffCall(task(g, `all-${n + 1}`), `All ${n + 1}`)))}`, 3);
	const allChats = batch.map((_, n) => titled(`All ${n + 1}`));
	const setAll = await c().tool(oc, `/tool reports ${JSON.stringify({ action: "wake", chats: allChats, when: "all" })}`);
	assert.equal(setAll.text, `Sub-chats ${allChats[0]}, ${allChats[1]} and ${allChats[2]} are one batch: you will be woken once, when all three have ended.`);
	const batchId = c().reportOf(projectId, allChats[0]!)!.batch as string;
	assert.match(batchId, /^b-/);
	assert.ok(allChats.every((chat) => c().reportOf(projectId, chat)!.batch === batchId));
	assert.ok(c().watched(oc).every((item) => item.wake === "all" && item.batch === batchId));
	const batchList = await c().tool(oc, '/tool reports {"action":"list"}');
	assert.match(batchList.text, /you will be woken once all of its batch have ended \(one batch with sub-chats/);
	// One after the other, so that the wake's order, oldest first, is known.
	batchGates[0]!.open();
	await c().until("the first of the batch ended", () => c().ended(projectId, allChats[0]!));
	batchGates[1]!.open();
	await c().until("two of the batch ended", () => allChats.slice(0, 2).every((chat) => c().ended(projectId, chat)));
	assert.equal(c().wakes(oc).length, 1, "not woken before the batch has ended");
	batchGates[2]!.open();
	const batchWake = await c().woken(oc, 2);
	assert.equal(batchWake, `pi² woke the agent: ${allChats.map((chat, n) => `sub-chat ${chat} “All ${n + 1}” answered`).join("; ")}`);
	assert.match(c().items(oc, "assistant").at(-1)!.text, /these 3 ended while you were not answering, oldest first/);
	await c().until("the batch delivered by the wake", () => allChats.every((chat) => c().reportOf(projectId, chat)?.delivered?.by === "wake"));
	step("reports wake all: a batch of three wakes the orchestrator once, when all three have ended, with every report");

	// ---- failure: a batch with one failure among answers

	const failGates = [gate(), gate(), gate()];
	const failing = await c().tools(oc, `/tools ${JSON.stringify(failGates.map((g, n) => handOffCall(task(g, `fail-${n + 1}`), `Fail ${n + 1}`)))}`, 3);
	const failChats = failing.map((_, n) => titled(`Fail ${n + 1}`));
	const setFailure = await c().tool(oc, `/tool reports ${JSON.stringify({ action: "wake", chats: failChats, when: "failure" })}`);
	assert.match(setFailure.text, /are one batch: you will be woken only if one fails or is stopped, once/);
	failGates[0]!.open();
	await c().until("the first answered", () => c().reportOf(projectId, failChats[0]!)?.ended?.outcome === "answered");
	assert.equal(c().wakes(oc).length, 2, "an answer wakes nobody");
	await c().call("conversation.open", { id: failChats[1] });
	await c().until("the second working", () => c().conversations.get(failChats[1]!)?.state?.busy);
	await c().call("abort", { id: failChats[1] });
	const failWake = await c().woken(oc, 3);
	assert.equal(failWake, `pi² woke the agent: sub-chat ${failChats[0]} “Fail 1” answered; sub-chat ${failChats[1]} “Fail 2” stopped without answering`);
	assert.equal(c().reportOf(projectId, failChats[1]!)!.ended.outcome, "stopped");
	await c().call("conversation.open", { id: failChats[2] });
	await c().until("the third working", () => c().conversations.get(failChats[2]!)?.state?.busy);
	await c().call("abort", { id: failChats[2] });
	await c().until("the third ended", () => c().reportOf(projectId, failChats[2]!)?.ended?.outcome === "stopped");
	await c().until("nothing watched", () => c().watched(oc).length === 0);
	assert.equal(c().wakes(oc).length, 3, "the batch's later runs wake nobody");
	assert.equal(c().reportOf(projectId, failChats[2]!)!.delivered, null);
	const late = await c().tool(oc, '/tool reports {"action":"read"}');
	assert.match(late.text, new RegExp(`^Sub-chat ${failChats[2]} “Fail 3” stopped without an answer:`));
	step("reports wake failure: an answer wakes nobody, the first run stopped wakes with those before it, the later ones wake nobody");

	// ---- sub_chats wait takes a report that woke nobody

	const g2 = gate();
	const [quiet] = await c().tools(oc, `/tools ${JSON.stringify([handOffCall(task(g2, "quiet-answer"), "Quiet")])}`);
	const quietChat = quiet!.details.conversationId as number;
	g2.open();
	await c().until("ended, unread", () => c().ended(projectId, quietChat));
	const taken = await c().tool(oc, `/tool sub_chats ${JSON.stringify({ action: "wait", chats: [quietChat] })}`);
	assert.match(taken.text, /quiet-answer/);
	await c().until("delivered by the wait", () => c().reportOf(projectId, quietChat)?.delivered?.by === "wait");
	step("sub_chats with wait takes a report that woke nobody, once");

	// ---- The person's choice: reports.wake

	const g3 = gate();
	const [personal] = await c().tools(oc, `/tools ${JSON.stringify([handOffCall(task(g3, "person-chose"), "Person")])}`);
	const personalChat = personal!.details.conversationId as number;
	await assert.rejects(c().call("reports.wake", { projectId: "p-nothing", chats: [personalChat], when: "each" }), { message: "Unknown project: p-nothing" });
	await assert.rejects(c().call("reports.wake", { projectId, chats: [personalChat], when: "sometimes" }), { message: "when must be each, all, failure or never" });
	await assert.rejects(c().call("reports.wake", { projectId, chats: [], when: "each" }), { message: "chats must be a list of sub-chats' numbers" });
	await assert.rejects(c().call("reports.wake", { projectId, chats: [eachChat], when: "each" }), /has no run going now/);
	assert.deepEqual(await c().call("reports.wake", { projectId, chats: [personalChat], when: "each" }), {});
	g3.open();
	assert.equal(await c().woken(oc, 4), `pi² woke the agent: sub-chat ${personalChat} “Person” answered`);
	step("the person's reports.wake chooses for a run going now, and refuses what is not one");

	// ---- The project's switch on: as today

	await c().call("projects.set", { id: projectId, settings: { wakeOnReports: true } });
	const g4 = gate();
	const [today] = await c().tools(oc, `/tools ${JSON.stringify([handOffCall(task(g4, "switch-on"), "Switch")])}`);
	assert.match(today!.text, /is working on it\. Its answer will come to you as a message when it is done, waking you if you are not answering then;/);
	g4.open();
	assert.equal(await c().woken(oc, 5), `pi² woke the agent: sub-chat ${today!.details.conversationId} “Switch” answered`);
	step("with the project's switch on, a report wakes the orchestrator as today");

	// ---- An engine stopped and started again in the middle of a batch

	await c().call("projects.set", { id: projectId, settings: { wakeOnReports: false } });
	const restartGates = [gate(), gate()];
	const restarting = await c().tools(oc, `/tools ${JSON.stringify(restartGates.map((g, n) => handOffCall(task(g, `restart-${n + 1}`), `Restart ${n + 1}`)))}`, 2);
	const restartChats = restarting.map((_, n) => titled(`Restart ${n + 1}`));
	await c().tool(oc, `/tool reports ${JSON.stringify({ action: "wake", chats: restartChats, when: "all" })}`);
	restartGates[0]!.open();
	await c().until("the first ended", () => c().ended(projectId, restartChats[0]!));
	const before = c().events.reports.projects[projectId].length;
	c().close();
	engine.kill("SIGTERM");
	await exited(engine);
	restartGates[1]!.open();
	engine = boot();
	client = await Client.attach(engine);
	await c().call("conversation.open", { id: oc });
	const restartWake = await c().woken(oc, 6);
	assert.equal(restartWake, `pi² woke the agent: ${restartChats.map((chat, n) => `sub-chat ${chat} “Restart ${n + 1}” answered`).join("; ")}`);
	await c().until("both delivered by the wake", () => restartChats.every((chat) => c().reportOf(projectId, chat)?.delivered?.by === "wake"));
	assert.equal(c().reports(projectId).length, before, "every report kept");
	assert.ok(
		c()
			.reports(projectId)
			.every((report) => report.ended !== null && report.delivered !== null),
		"none lost: each delivered once",
	);
	step("an engine stopped in the middle of a batch: the batch wakes once after the restart, and no report is lost");

	// ---- The preview off: waking exactly as wakes.md says

	await c().call("projects.setPreview", { on: false });
	const g5 = gate();
	const [off] = await c().tools(oc, `/tools ${JSON.stringify([handOffCall(task(g5, "preview-off"), "Off")])}`);
	assert.match(off!.text, /Its answer will come to you as a message/);
	assert.equal(c().reportOf(projectId, off!.details.conversationId), undefined, "no report");
	g5.open();
	assert.equal(await c().woken(oc, 7), `pi² woke the agent: sub-chat ${off!.details.conversationId} “Off” answered`);
	await assert.rejects(c().call("reports.wake", { projectId, chats: [1], when: "each" }), { message: PREVIEW_OFF });
	assert.equal(c().events.reports.projects[projectId].length, before, "the reports kept as they are");
	step("with the preview off, a run of the orchestrator has no report and wakes it as today; reports.wake is refused");

	console.log("PASS");
	passed = true;
} finally {
	writeFileSync(all, "");
	client?.close();
	if (running(engine)) {
		engine.kill("SIGTERM");
		await Promise.race([exited(engine), new Promise((resolve) => setTimeout(resolve, 8_000))]);
		await stop(engine, "SIGKILL");
	}
	if (!passed && existsSync(engineLog)) process.stderr.write(readFileSync(engineLog, "utf8"));
	rmSync(home, { recursive: true, force: true });
	rmSync(scratch, { recursive: true, force: true });
	try {
		while (true) execFileSync("/usr/bin/security", ["delete-generic-password", "-s", KEYCHAIN_SERVICE], { stdio: "ignore" });
	} catch {
		// None left.
	}
}
process.exit(0);
