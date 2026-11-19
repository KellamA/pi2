// The places in projects.ts that later issues of the projects epic fill in (docs/projects.md, 12.1), each doing what
// the contract says it does until then, and the helpers every piece of the epic asks: `projectsOn`, `inProject`,
// `requireSwitch`, `admit` and `addNews`. The feature is given a stand-in engine and host, with a real Inbox, so no
// engine is started. projects.ts (the test) drives the same feature through a real engine.

import assert from "node:assert/strict";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import type { Host } from "../src/extensions.ts";
import { type Engine, FEATURES } from "../src/features.ts";
import { addRule, projectRules, type ProjectRulesDoc, projectRulesPrompt } from "../src/projectrules.ts";
import {
	addNews,
	admit,
	carryOverState,
	defaultProjectSettings,
	emptyReport,
	inProject,
	lastWords,
	onPreviewOn,
	PREVIEW_OFF,
	type Project,
	type ProjectsDoc,
	projectOf,
	projects,
	projectsOn,
	Projects,
	requireSwitch,
	ruleTokens,
	type Start,
} from "../src/projects.ts";
import { Inbox, type Meta } from "../src/state.ts";
import { work } from "../src/work.ts";
import { until } from "./patience.ts";

function step(name: string): void {
	console.log(`ok  ${name}`);
}

// Its place in FEATURES: last of today's features, with the places after it for the others (4.4), which each later
// issue fills with its own feature: only the epic's features come after it.
const epic = ["projects", "projectRules", "needs", "reports", "work", "github"];
assert.ok(FEATURES.includes(projects));
assert.deepEqual(
	FEATURES.slice(FEATURES.indexOf(projects)).map((feature) => feature.name).filter((name) => !epic.includes(name)),
	[],
);
step("the projects feature is last of today's features in FEATURES, where the others' places follow it");

// The rules' greeting follows projects (4.4), independently of their section's place (6.1).
assert.equal(FEATURES[FEATURES.indexOf(projects) + 1], projectRules);
assert.ok(FEATURES.indexOf(projectRulesPrompt) < FEATURES.indexOf(projects));
step("the rules feature follows projects in the greetings; its prompt has a separate place");
assert.ok(FEATURES.indexOf(work) > FEATURES.indexOf(projectRules));
step("the work greeting follows the project and rule greetings");

const project = (id: string, extra: Partial<Project> = {}): Project => ({
	id,
	name: id,
	folder: null,
	repository: null,
	orchestratorId: `orchestrator-${id}`,
	conversation: null,
	earlier: [],
	settings: defaultProjectSettings("new"),
	createdAt: 1,
	updatedAt: 1,
	...extra,
});
const settings = defaultProjectSettings("new");
settings.withoutAsking.startAgents = false;
const stored: ProjectsDoc = {
	projects: {
		p1: project("p1", { settings }),
		p2: project("p2", { archivedAt: 2 }),
		p3: project("p3", { deletedAt: 3 }),
	},
	carry: { ranAt: null, backup: null, folders: {}, copies: {}, notes: {}, secrets: [] },
	news: {},
	nextNews: 1,
};
const meta = (projectId?: string, parent?: number): Meta => ({ title: "", createdAt: 1, updatedAt: 1, access: "ask", agentId: "a", ...(projectId === undefined ? {} : { projectId }), ...(parent === undefined ? {} : { parent }) });
const conversations: Record<string, Meta> = { 1: meta("p1"), 2: meta("p2"), 3: meta("p3"), 4: meta(), 5: meta("p1", 1) };

const saved: Record<string, unknown> = { projects: { preview: true } };
const broadcasts: any[] = [];
const engine = {
	harness: () => ({ snapshot: async () => structuredClone(stored), observeCommits: () => ({ detach() {} }) }),
	context: () => BACKGROUND_CONTEXT,
	setting: (key: string) => saved[key],
	saveSetting: (key: string, value: unknown) => void (saved[key] = value),
	broadcast: (message: unknown) => void broadcasts.push(message),
	log: () => {},
	agents: () => ({}),
} as unknown as Engine;
// Allow everything is on for every conversation: it answers ordinary approvals, never one a switch asks.
const inbox = new Inbox(async () => true);
const host = { inbox, conversations: () => conversations, working: () => false, features: [] } as unknown as Host;
const feature = projects(host, engine);
await feature.start!();
const handlers = feature.handlers!;

// ---- projectsOn and inProject

assert.equal(projectsOn(), true);
assert.equal(inProject(1)?.id, "p1");
assert.equal(inProject(5)?.id, "p1", "a sub-chat is in its project");
assert.equal(inProject(2), undefined, "archived");
assert.equal(inProject(3), undefined, "deleted");
assert.equal(inProject(4), undefined, "in no project");
assert.equal(inProject(99), undefined, "unknown");
assert.equal(projectOf(2)?.id, "p2");
assert.equal(projectOf(3)?.id, "p3");
step("projectsOn, inProject and projectOf with the preview on");

assert.deepEqual(await handlers["projects.setPreview"]!({ on: false }), { preview: false, carryOver: null });
assert.equal(projectsOn(), false);
assert.deepEqual(saved.projects, { preview: false });
assert.equal(broadcasts.at(-1).event, "projects");
assert.equal(broadcasts.at(-1).preview, false);
assert.equal(inProject(1), undefined, "with the preview off, no conversation is in a project for what it is told");
assert.equal(projectOf(1)?.id, "p1", "but it still belongs to it");
for (const method of ["projects.create", "projects.rename", "projects.set", "projects.archive", "projects.unarchive", "projects.delete"]) {
	await assert.rejects(handlers[method]!({ id: "p1", folder: null, name: "x" }), { message: PREVIEW_OFF });
}
const listed = (await handlers["projects.list"]!({})) as any;
assert.equal(listed.preview, false);
assert.deepEqual(
	listed.projects.map((row: any) => [row.id, row.folderMissing, row.ruleTokens, row.lastWords]),
	["p1", "p2", "p3"].map((id) => [id, false, { orchestrator: 0, agents: 0 }, null]),
);
step("with the preview off: projectsOn false, inProject nothing, new requests refused, list allowed");

// ---- What later issues fill in, as it is until they land

assert.deepEqual(await handlers["projects.setPreview"]!({ on: true, plan: null }), { preview: true, carryOver: emptyReport() });
assert.deepEqual(await onPreviewOn("any plan"), { plan: null, projects: [], leftOut: { chats: 0, deleted: 0, notesLeft: 0 }, already: 0, ranAt: null, backup: null, secretsPending: [] });
assert.equal(carryOverState(), null);
assert.deepEqual(ruleTokens("p1"), { orchestrator: 0, agents: 0 });
assert.equal(lastWords("p1"), null);
step("until #458 onPreviewOn carries nothing over and carryOver is null; ruleTokens zeros without rules; lastWords null until #466");

const start: Start = { by: { kind: "agent", agentId: "a", conversationId: 1 }, agentId: "b", agentName: "B", kind: "new", parent: 1, chat: null, work: null, title: null, task: "Do it", options: {} };
assert.deepEqual(admit(start), { ok: true });
assert.deepEqual(admit({ ...start, by: { kind: "person" }, kind: "conversation", parent: null }, "a-reading"), { ok: true });
step("until #464 admit admits every start");

// ---- requireSwitch

const api = { memo: async () => undefined } as never;
const ask = (conversationId: number, id: string, name: Parameters<typeof requireSwitch>[1]) =>
	requireSwitch({ conversationId, id, callId: `call-${id}`, tool: "delegate", arguments: { agent: "B" }, api, context: BACKGROUND_CONTEXT }, name, `Start B on “${id}”.`);
assert.deepEqual(await ask(4, "t1", "startAgents"), { ok: true }, "in no project, nothing is asked");
assert.deepEqual(await ask(1, "t2", "fileWork"), { ok: true }, "a switch that is on asks nothing");
assert.equal(inbox.list().length, 0);
const answered = async (conversationId: number, id: string, answer: string) => {
	const result = ask(conversationId, id, "startAgents");
	const item = await until(`the question ${id}`, () => inbox.get(id));
	assert.equal(item.kind, "approval");
	assert.equal(item.projectSwitch, "startAgents");
	assert.equal(item.question, `Start B on “${id}”.`);
	assert.equal(item.conversationId, conversationId);
	inbox.answer(id, answer);
	return result;
};
assert.deepEqual(await answered(1, "t3", "once"), { ok: true }, "asked although Allow everything is on, and allowed once");
const denied = await answered(5, "t4", "deny");
assert.equal(denied.ok, false);
assert.match((denied as { reason: string }).reason, /declined/);
// It holds with the preview off: switching off removes no protection (section 2).
await handlers["projects.setPreview"]!({ on: false });
assert.deepEqual(await answered(1, "t5", "once"), { ok: true });
// An ordinary approval in the same conversation is still answered by Allow everything, as before.
assert.equal(await inbox.ask({ id: "t7", kind: "approval", conversationId: 1, callId: "c7", tool: "bash", arguments: {}, question: null, createdAt: 1 }, api, BACKGROUND_CONTEXT), "once");
step("requireSwitch asks only for a switch that is off, in a project, whatever Allow everything and the preview say");

// ---- addNews

const doc: ProjectsDoc = structuredClone(stored);
const tx = { doc: async () => doc } as never;
const first = await addNews(tx, "p1", { kind: "report", text: "Scout finished.", ref: "12", at: 5 });
assert.deepEqual(first, { id: "w1", at: 5, kind: "report", text: "Scout finished.", ref: "12" });
const second = await addNews(tx, "p1", { kind: "message", text: "The person wrote to Forge.", ref: "13", keep: true });
assert.equal(second.id, "w2");
assert.equal(second.keep, true);
await addNews(tx, "p3", { kind: "change", text: "Deleted, still stored.", ref: "c1" });
assert.deepEqual(doc.news.p1!.map((news) => news.id), ["w1", "w2"]);
assert.deepEqual(doc.news.p3!.map((news) => news.id), ["w3"]);
assert.equal(doc.nextNews, 4);
await assert.rejects(addNews(tx, "p9", { kind: "work", text: "x", ref: "1" }), { message: "Unknown project: p9" });
assert.equal(doc.nextNews, 4);
step("addNews stores news by project, oldest first, each with an id of its own; #466 delivers it");

// #465 will supply attribution and call addRule in its own commit. There is no proposal handler yet.
const rulesDoc: ProjectRulesDoc = { projects: {} };
const rulesTx = { doc: async (token: unknown) => token === Projects ? doc : rulesDoc } as never;
const addedBy = { kind: "proposal", agentId: "a", conversationId: 1, need: "n1" } as const;
const add = (id: string) => addRule(rulesTx, id, { text: " Keep this. ", binds: "everyone", addedBy });
await assert.rejects(add("p1"), { message: PREVIEW_OFF });
assert.deepEqual(rulesDoc, { projects: {} });
await handlers["projects.setPreview"]!({ on: true });
const rule = await add("p1");
assert.deepEqual(rule, { id: "r1", text: "Keep this.", binds: "everyone", addedBy, createdAt: rule.createdAt, updatedAt: rule.createdAt });
assert.deepEqual(rulesDoc.projects.p1, { rules: [rule], next: 2 });
assert.equal(projectRules(host, engine).handlers?.["projects.rules.propose"], undefined);
step("addRule appends in the caller's transaction and retains attribution; #465 owns proposal handling");
