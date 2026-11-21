// Needs you (#462, docs/projects.md 3.9), without an engine: `claim`, `putNeed`, `withdrawNeed`, `onAnswer` and the list
// as sent, against a stand-in engine and host with a real Inbox and a stand-in harness whose commits run one at a time,
// as pi durable's do, and change nothing when they throw. needs.ts (the test) drives the same through a real engine.
//
// What later issues fill in is checked as it is until they land: an answer to a reach request, a proposed rule or a
// limit card is refused and leaves the item waiting until #465 or #464 registers what it does with `onAnswer`.

import assert from "node:assert/strict";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import type { Tx } from "@earendil-works/pi-durable";
import type { Host } from "../src/extensions.ts";
import { type Engine, FEATURES } from "../src/features.ts";
import { answerText, checkAnswer, claim, GONE, type NeedItem, needItems, needs, onAnswer, putNeed, type StoredNeed, storedNeeds, withdrawNeed } from "../src/needs.ts";
import { defaultProjectSettings, type Project, projects, type Start } from "../src/projects.ts";
import { Inbox, type InboxItem, type Meta } from "../src/state.ts";
import { until } from "./patience.ts";

function step(name: string): void {
	console.log(`ok  ${name}`);
}

// Its place in FEATURES: after projects, so its greeting comes after the projects' (4.4).
assert.ok(FEATURES.indexOf(projects) < FEATURES.indexOf(needs));
step("the needs feature comes after projects in FEATURES");

// ---- A stand-in harness: documents by kind; one commit at a time; a commit that throws changes nothing

const docs = new Map<string, any>();
const observers: { advance: (observation: any) => void }[] = [];
let commits = 0;
let chain: Promise<unknown> = Promise.resolve();
const harness = {
	snapshot: async (token: any) => (docs.has(token.definition.kind) ? structuredClone(docs.get(token.definition.kind)) : undefined),
	commit: <T>(edit: (tx: Tx) => Promise<T>): Promise<T> => {
		const run = chain.then(async () => {
			const working = new Map<string, any>();
			const tx = {
				doc: async (token: any) => {
					const kind = token.definition.kind as string;
					if (!working.has(kind)) working.set(kind, structuredClone(docs.get(kind) ?? token.definition.initial()));
					return working.get(kind);
				},
			} as unknown as Tx;
			const value = await edit(tx);
			for (const [kind, doc] of working) docs.set(kind, doc);
			commits += 1;
			for (const observer of observers) observer.advance({ changes: [...working.keys()].map((kind) => ({ type: "document", record: { kind } })) });
			return value;
		});
		chain = run.catch(() => {});
		return run;
	},
	observeCommits: (observer: { advance: (observation: any) => void }) => {
		observers.push(observer);
		return { detach() {} };
	},
};

const project = (id: string, extra: Partial<Project> = {}): Project => ({
	id,
	name: id,
	folder: null,
	repository: null,
	orchestratorId: `orchestrator-${id}`,
	conversation: 1,
	earlier: [],
	settings: defaultProjectSettings("new"),
	createdAt: 1,
	updatedAt: 1,
	...extra,
});
docs.set("pi2.projects", {
	projects: { p1: project("p1"), p2: project("p2", { conversation: 2 }), gone: project("gone", { deletedAt: 3 }) },
	carry: { ranAt: null, backup: null, folders: {}, copies: {}, notes: {}, secrets: [] },
	news: {},
	nextNews: 1,
});
const meta = (title: string, extra: Partial<Meta> = {}): Meta => ({ title, createdAt: 1, updatedAt: 1, access: "ask", agentId: "orchestrator-p1", ...extra });
const conversations: Record<string, Meta> = {
	1: meta("Plan", { projectId: "p1" }),
	2: meta("Other", { projectId: "p2", agentId: "orchestrator-p2" }),
	3: meta("Sub", { projectId: "p1", parent: 1 }),
	4: meta("Loose", { agentId: "forge" }),
};
const agents = { "orchestrator-p1": { id: "orchestrator-p1", name: "Orchestrator" }, "orchestrator-p2": { id: "orchestrator-p2", name: "Planner" }, forge: { id: "forge", name: "Forge" } };

const saved: Record<string, unknown> = { projects: { preview: true } };
const broadcasts: any[] = [];
const engine = {
	harness: () => harness,
	context: () => BACKGROUND_CONTEXT,
	setting: (key: string) => saved[key],
	saveSetting: (key: string, value: unknown) => void (saved[key] = value),
	broadcast: (message: unknown) => void broadcasts.push(message),
	log: () => {},
	agents: () => agents,
	library: () => ({ conversations }),
} as unknown as Engine;
// Allow everything is on for every conversation: it answers ordinary approvals, and nothing else.
const inbox = new Inbox(async () => true);
const features: any[] = [];
const host = { inbox, conversations: () => conversations, working: () => false, features } as unknown as Host;
const projectsFeature = projects(host, engine);
const needsFeature = needs(host, engine);
features.push(projectsFeature, needsFeature);
inbox.onChange = () => needsFeature.inboxChanged?.();
await projectsFeature.start!();
await needsFeature.start!();
const handlers = { ...projectsFeature.handlers!, ...needsFeature.handlers! };
const lastNeeds = () => broadcasts.filter((message) => message.event === "needs").at(-1)?.items as NeedItem[];

// ---- Nothing waiting

assert.deepEqual(needsFeature.greeting!(), [{ event: "needs", items: [] }]);
assert.equal(docs.has("pi2.needs"), false, "nothing is written at start");
step("with nothing waiting, the empty needs event, and nothing written");

// ---- The Inbox in the list: approvals and ask_user questions, as they wait

const api = { memo: async () => undefined } as never;
const asked = (item: Partial<InboxItem> & { id: string }) =>
	inbox.ask({ kind: "approval", conversationId: 1, callId: `call-${item.id}`, tool: "bash", arguments: { command: "make" }, question: null, createdAt: Number(item.id), ...item }, api, BACKGROUND_CONTEXT);
// Allow everything answers an approval without showing it, as before; a question and a switch's approval it does not.
assert.equal(await asked({ id: "1" }), "once");
const question = asked({ id: "10", kind: "question", tool: "ask_user", question: "Which branch?", conversationId: 4 });
const approval = asked({ id: "11", projectSwitch: "merge", tool: "work", question: "Merge #3." });
await until("both shown", () => inbox.list().length === 2);
const shown = needItems();
assert.deepEqual(shown, [
	{
		id: "10",
		projectId: null,
		conversationId: 4,
		rootConversationId: 4,
		title: "Loose",
		rootTitle: "Loose",
		agentId: "forge",
		agentName: "Forge",
		blocking: true,
		createdAt: 10,
		kind: "question",
		question: "Which branch?",
	},
	{
		id: "11",
		projectId: "p1",
		conversationId: 1,
		rootConversationId: 1,
		title: "Plan",
		rootTitle: "Plan",
		agentId: "orchestrator-p1",
		agentName: "Orchestrator",
		blocking: true,
		createdAt: 11,
		kind: "approval",
		tool: "work",
		arguments: { command: "make" },
		question: "Merge #3.",
		projectSwitch: "merge",
		answers: ["once", "deny"],
	},
]);
assert.deepEqual(lastNeeds(), shown, "the needs event is sent as the Inbox changes");
step("approvals and ask_user questions are in the list, blocking, with projectSwitch and the answers they take");

// ---- claim for the Inbox: the old routes' checks, one answer only

await assert.rejects(claim("11", { kind: "approval", decision: "always" }), { message: "This can only be allowed once, or denied: the project's settings ask each time" });
await assert.rejects(claim("11", { kind: "approval", decision: "rule" }), { message: "That request did not offer an allowed command" });
await assert.rejects(claim("11", { kind: "question", text: "yes" }), { message: "This is a request for approval, not a question" });
await assert.rejects(claim("10", { kind: "approval", decision: "once" }), { message: "This is a question, not a request for approval" });
assert.equal(inbox.list().length, 2, "a refused answer leaves the item waiting");
// Two answers at once, by two routes: the first is taken, the second finds it gone and changes nothing.
const both = await Promise.allSettled([claim("11", { kind: "approval", decision: "deny" }), claim("11", { kind: "approval", decision: "once" })]);
assert.equal(both[0].status, "fulfilled");
assert.equal(both[1].status, "rejected");
assert.equal((both[1] as PromiseRejectedResult).reason.message, GONE);
assert.equal(await approval, "deny");
await claim("10", { kind: "question", text: "main" });
assert.equal(await question, "main");
await assert.rejects(claim("10", { kind: "question", text: "again" }), { message: GONE });
await until("the list empty again", () => inbox.list().length === 0 && lastNeeds().length === 0);
step("claim answers the Inbox's calls once, with the old routes' checks, and refuses the wrong kind");

// What each approval offers, as the Inbox's card does. Allow everything would answer these at once, so an Inbox with it
// off stands in.
const plain = new Inbox(async () => false);
(host as { inbox: Inbox }).inbox = plain;
const offered = async (item: Partial<InboxItem> & { id: string }) => {
	const waiting = plain.ask({ kind: "approval", conversationId: 4, callId: `c${item.id}`, tool: "bash", arguments: {}, question: null, createdAt: Number(item.id), ...item }, api, BACKGROUND_CONTEXT);
	await until(`approval ${item.id}`, () => plain.get(item.id));
	return { answers: (needItems().find((one) => one.id === item.id) as Extract<NeedItem, { kind: "approval" }>).answers, waiting };
};
const shell = await offered({ id: "20", rule: { words: ["make"], folder: "/tmp" } });
assert.deepEqual(shell.answers, ["once", "rule", "always", "deny"]);
const schedule = await offered({ id: "21", tool: "schedule_task" });
assert.deepEqual(schedule.answers, ["once", "deny"]);
const page = await offered({ id: "22", tool: "browser" });
assert.deepEqual(page.answers, ["once", "deny"]);
const site = await offered({ id: "23", tool: "browser", site: "example.com" });
assert.deepEqual(site.answers, ["once", "always", "deny"]);
await claim("20", { kind: "approval", decision: "rule" });
assert.equal(await shell.waiting, "rule");
// "always" where the card does not offer it is passed on as before: the tool takes it as once (selfschedule.ts, extensions.ts).
for (const id of ["21", "22", "23"]) await claim(id, { kind: "approval", decision: "always" });
assert.deepEqual(await Promise.all([schedule.waiting, page.waiting, site.waiting]), ["always", "always", "always"]);
(host as { inbox: Inbox }).inbox = inbox;
step("an approval takes Always Allow where the Inbox offers it, and an allowed command where one was offered");

// ---- Stored needs: put, listed, answered, withdrawn

let need!: StoredNeed;
await harness.commit(async (tx) => {
	need = await putNeed(tx, { kind: "decision", projectId: "p1", conversationId: 1, callId: "call-a", question: "Merge now or after the release?", choices: [{ id: "c1", label: "Now" }, { id: "c2", label: "After the release" }], words: false, createdAt: 30 });
});
assert.equal(need.id, "n1");
// The call run again after a crash finds the one it put.
const again = await harness.commit((tx) => putNeed(tx, { kind: "question", projectId: "p1", conversationId: 1, callId: "call-a", question: "Something else?" }));
assert.equal(again.id, "n1");
await assert.rejects(harness.commit((tx) => putNeed(tx, { kind: "question", projectId: "gone", conversationId: 1, callId: null, question: "?" })), { message: "Unknown project: gone" });
await assert.rejects(harness.commit((tx) => putNeed(tx, { kind: "question", projectId: "p9", conversationId: 1, callId: null, question: "?" })), { message: "Unknown project: p9" });
const start: Start = { by: { kind: "agent", agentId: "orchestrator-p1", conversationId: 1 }, agentId: "b", agentName: "B", kind: "new", parent: 1, chat: null, work: null, title: null, task: "Do it", options: {} };
const put = (given: any): Promise<StoredNeed> => harness.commit((tx) => putNeed(tx, given));
const q = await put({ kind: "question", projectId: "p2", conversationId: 2, callId: "call-b", question: "Which colour?", createdAt: 31 });
const reach = await put({ kind: "reach", projectId: "p1", conversationId: 1, callId: null, change: { summary: "Let Forge run commands without asking (Full access)", target: { kind: "agent", id: "forge" }, fields: [{ name: "access", before: "ask", after: "full" }], op: {} }, why: "To run the tests", createdAt: 32 });
const rule = await put({ kind: "rule", projectId: "p1", conversationId: 1, callId: null, text: "Run the tests first.", binds: "everyone", why: null, createdAt: 33 });
const limit = await put({ kind: "limit", projectId: "p1", conversationId: 1, callId: null, start, limit: { id: "r1", limit: "dailySpend", reason: "Over", provider: null, window: null, used: 21, max: 20, resetsAt: null }, createdAt: 34 });
await until("the stored needs read back", () => storedNeeds().length === 5);
assert.deepEqual(
	storedNeeds().map((one) => [one.id, one.kind]),
	[["n1", "decision"], ["n2", "question"], ["n3", "reach"], ["n4", "rule"], ["n5", "limit"]],
);
const items = needItems();
assert.deepEqual(items[0], {
	id: "n1",
	projectId: "p1",
	conversationId: 1,
	rootConversationId: 1,
	title: "Plan",
	rootTitle: "Plan",
	agentId: "orchestrator-p1",
	agentName: "Orchestrator",
	blocking: false,
	createdAt: 30,
	kind: "decision",
	question: "Merge now or after the release?",
	choices: [{ id: "c1", label: "Now" }, { id: "c2", label: "After the release" }],
	words: false,
});
assert.equal(items[1]!.projectId, "p2");
assert.equal(items[1]!.agentName, "Planner");
assert.deepEqual(items.map((one) => one.kind), ["decision", "question", "reach", "rule", "limit"]);
assert.ok(items.every((one) => !("callId" in one)), "the call id is the engine's own");
assert.deepEqual(lastNeeds(), items);
step("putNeed stores each kind, once per call; the list sends each as its own union, not blocking, oldest first");

// Answers checked against the item, which stays when one is refused.
await assert.rejects(claim("n1", { kind: "question", text: "Now" }), { message: "This is a decision, not a question" });
await assert.rejects(claim("n1", { kind: "decision", choice: "c9" }), { message: "There is no choice c9 in this decision" });
await assert.rejects(claim("n1", { kind: "decision", text: "Whenever" }), { message: "This decision takes one of its choices, not an answer in words" });
// Until #465 and #464 say what their answers do, nothing can act on them: refused, and left waiting.
await assert.rejects(claim(reach.id, { kind: "reach", allow: true }), { message: "pi² cannot act on an answer to a request for more reach yet" });
await assert.rejects(claim(rule.id, { kind: "rule", accept: true }), { message: "pi² cannot act on an answer to a proposed rule yet" });
await assert.rejects(claim(limit.id, { kind: "limit", start: true }), { message: "pi² cannot act on an answer to a start held back by a limit yet" });
assert.equal(storedNeeds().length, 5);
step("an answer of the wrong kind or choice is refused; reach, rule and limit answers wait for #465 and #464");

// A question or decision answered: a wake of the kind `answer`, stored in the same commit, for the conversation that asked.
await claim("n1", { kind: "decision", choice: "c2" });
assert.equal(storedNeeds().some((one) => one.id === "n1"), false);
const arrived = docs.get("pi2.wakes").arrived["1"];
assert.deepEqual(
	arrived.map(({ at: _, ...item }: any) => item),
	[{ key: "answer:n1", kind: "answer", ref: "n1", label: "the question “Merge now or after the release?”", ended: "was answered", text: "The person answered your question “Merge now or after the release?”: After the release." }],
);
await assert.rejects(claim("n1", { kind: "decision", choice: "c1" }), { message: GONE });
await claim(q.id, { kind: "question", text: "Blue, like the sea\nor the sky" });
assert.equal(docs.get("pi2.wakes").arrived["2"][0].text, "The person answered your question “Which colour?”:\n\nBlue, like the sea\nor the sky");
assert.equal(answerText("Go?", "Yes!"), "The person answered your question “Go?”: Yes!");
step("a question or decision answered wakes the conversation that asked, with the answer, once");

// What a kind's handler is given, and may do: keep the item (changed), or take it, with something once stored.
const calls: string[] = [];
let keepIt = true;
onAnswer("limit", async (_tx, card, answer) => {
	calls.push(`${card.id}:${answer.start}`);
	if (keepIt) {
		card.limit.used = 22;
		return { keep: true };
	}
	return { after: async () => void calls.push("after") };
});
await claim(limit.id, { kind: "limit", start: true });
assert.equal(storedNeeds().find((one) => one.id === limit.id)?.kind, "limit");
assert.equal((storedNeeds().find((one) => one.id === limit.id) as Extract<StoredNeed, { kind: "limit" }>).limit.used, 22, "kept as the handler changed it");
keepIt = false;
const twice = await Promise.allSettled([claim(limit.id, { kind: "limit", start: false }), claim(limit.id, { kind: "limit", start: true })]);
assert.deepEqual(twice.map((one) => one.status), ["fulfilled", "rejected"]);
assert.deepEqual(calls, ["n5:true", "n5:false", "after"], "the handler ran once for the two answers");
onAnswer("rule", async () => {
	throw new Error("That rule is already there");
});
const before = commits;
await assert.rejects(claim(rule.id, { kind: "rule", accept: true, text: "Run the tests first, always." }), { message: "That rule is already there" });
assert.ok(storedNeeds().some((one) => one.id === rule.id), "a handler that throws leaves the item waiting");
assert.equal(commits, before, "and nothing was stored");
step("onAnswer: a handler runs once inside the commit that takes the item, may keep it, and refuses by throwing");

// Withdrawn: by withdrawNeed, by its conversation archived or deleted, by its project deleted.
const taken = await harness.commit((tx) => withdrawNeed(tx, reach.id));
assert.equal(taken?.id, reach.id);
assert.equal(await harness.commit((tx) => withdrawNeed(tx, reach.id)), undefined);
await until("withdrawn", () => !storedNeeds().some((one) => one.id === reach.id));
await assert.rejects(claim(reach.id, { kind: "reach", allow: false }), { message: GONE });
const sub = await put({ kind: "question", projectId: "p1", conversationId: 3, callId: null, question: "From a sub-chat's root?" });
conversations["1"] = { ...conversations["1"]!, archivedAt: 50 };
needsFeature.putAwayChanged!();
await until("the archived conversation's needs withdrawn", () => !storedNeeds().some((one) => one.id === rule.id || one.id === sub.id));
delete conversations["1"]!.archivedAt;
const other = await put({ kind: "question", projectId: "p2", conversationId: 2, callId: null, question: "Still there?" });
await harness.commit(async (tx) => {
	((await tx.doc({ definition: { kind: "pi2.projects" } } as never)) as any).projects.p2.deletedAt = 60;
});
await until("the deleted project's needs withdrawn", () => !storedNeeds().some((one) => one.id === other.id));
assert.deepEqual(storedNeeds(), []);
step("withdrawn by withdrawNeed, with its conversation archived or deleted, and with its project deleted");

// ---- The answer's shape, as a request gives it

assert.deepEqual(checkAnswer({ kind: "decision", choice: "c1" }), { kind: "decision", choice: "c1" });
assert.deepEqual(checkAnswer({ kind: "rule", accept: true, binds: "orchestrator" }), { kind: "rule", accept: true, binds: "orchestrator" });
for (const [given, message] of [
	[null, "answer must be an object with a kind"],
	[{ kind: "maybe" }, "Unknown kind of answer: maybe"],
	[{ kind: "approval", decision: "sometimes" }, "decision must be once, always, rule or deny"],
	[{ kind: "question", text: "   " }, "The answer is empty"],
	[{ kind: "question", text: "x".repeat(20_001) }, "An answer can be 20,000 characters at most; this one is 20,001"],
	[{ kind: "decision", choice: "c1", text: "and words" }, "Give either a choice or an answer in words, not both"],
	[{ kind: "decision" }, "Give a choice, or an answer in words"],
	[{ kind: "reach", allow: "yes" }, "allow must be true or false"],
	[{ kind: "rule", accept: true, binds: "someone" }, "binds must be orchestrator or everyone"],
	[{ kind: "limit" }, "start must be true or false"],
] as const) {
	assert.throws(() => checkAnswer(given), { message });
}
step("an answer's shape is checked by its kind");

// ---- Who is offered needs_you (5.1)

const offeredTo = (agent: object, subChat: boolean, access: "none" | "ask" = "ask") => needsFeature.toolNames!(access, agent as never, { subChat });
assert.deepEqual(offeredTo({ projectId: "p1" }, false), ["needs_you"]);
assert.deepEqual(offeredTo({ projectId: "p1" }, false, "none"), ["needs_you"], "whatever its access");
assert.deepEqual(offeredTo({ projectId: "p1" }, true), ["needs_you"], "in a sub-chat too, which keeps ask_user as well (#507)");
assert.deepEqual(offeredTo({}, true), [], "not in a sub-chat of an agent of no project");
assert.deepEqual(offeredTo({}, false), [], "not to an agent of no project");
assert.deepEqual(offeredTo({ projectId: "p2" }, false), [], "not in a deleted project");
step("needs_you is offered to a project agent's conversations and their sub-chats, not outside a project");

// ---- With the preview off: nothing in the list, and the new requests refused

await put({ kind: "question", projectId: "p1", conversationId: 1, callId: null, question: "Kept while off?" });
await handlers["projects.setPreview"]!({ on: false });
assert.deepEqual(lastNeeds(), [], "turning the preview off sends the empty list");
assert.deepEqual(needsFeature.greeting!(), [{ event: "needs", items: [] }]);
assert.deepEqual(offeredTo({ projectId: "p1" }, false), [], "needs_you is not offered with the preview off");
await assert.rejects(handlers["needs.list"]!({}), { message: "Projects are a preview. Turn them on in Settings › General first." });
await assert.rejects(handlers["needs.answer"]!({ id: "n8", answer: { kind: "question", text: "x" } }), { message: "Projects are a preview. Turn them on in Settings › General first." });
assert.equal(storedNeeds().length, 1, "and the need is kept");
await handlers["projects.setPreview"]!({ on: true });
assert.equal(lastNeeds().length, 1, "turning it on again sends it");
assert.equal(((await handlers["needs.list"]!({ projectId: "p1" })) as { items: NeedItem[] }).items.length, 1);
await assert.rejects(handlers["needs.list"]!({ projectId: "p9" }), { message: "Unknown project: p9" });
step("with the preview off the list is empty and the new requests refused; what is stored stays");
