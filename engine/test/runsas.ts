// `runsAs` and what goes through it (#457, docs/projects.md 3.3 and 3.4), without an engine: which agent a conversation
// runs as, with the preview on and off, for a copy removed or deleted, and an agent of its own removed; whom a
// conversation may hand work to, in a project and outside one; what Update from template compares; the folder of a
// project agent; and removing an agent through a tool. The projects feature and the project agents feature are given a
// stand-in engine and host. projectagents.ts drives the same through a real engine.

import assert from "node:assert/strict";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import type { Host } from "../src/extensions.ts";
import { type Engine, FEATURES } from "../src/features.ts";
import { AGENT_IN_FOLDER, delegateTargets, projectAgentFolder, projectAgents, removeAgent, stampsAgents, templateChanges } from "../src/projectagents.ts";
import { defaultProjectSettings, PROJECT_ARCHIVED, type Project, type ProjectsDoc, projects, projectsOn } from "../src/projects.ts";
import { type AgentProfile, agentOf, type Meta, runsAs } from "../src/state.ts";

function step(name: string): void {
	console.log(`ok  ${name}`);
}

assert.ok(FEATURES.includes(projectAgents));
assert.ok(FEATURES.indexOf(projectAgents) < FEATURES.indexOf(projects), "before the projects' greetings, having none of its own");
step("the project agents feature is in FEATURES");

const project = (id: string, extra: Partial<Project> = {}): Project => ({
	id,
	name: id,
	folder: `/work/${id}`,
	repository: null,
	orchestratorId: `o-${id}`,
	conversation: null,
	earlier: [],
	settings: defaultProjectSettings("new"),
	createdAt: 1,
	updatedAt: 1,
	...extra,
});
const stored: ProjectsDoc = {
	projects: { p1: project("p1", { conversation: 1 }), p2: project("p2", { archivedAt: 2 }), p3: project("p3", { conversation: 8, deletedAt: 3 }) },
	carry: { ranAt: null, backup: null, folders: {}, copies: {}, notes: {}, secrets: [] },
	news: {},
	nextNews: 1,
};
let createdAt = 0;
const agent = (id: string, extra: Partial<AgentProfile> = {}): AgentProfile => ({
	id,
	name: id,
	description: "",
	color: "violet",
	model: null,
	thinkingLevel: null,
	instructions: "",
	access: "read",
	cwd: null,
	delegates: [],
	maxTurns: null,
	createdAt: ++createdAt,
	...extra,
});
const agents: Record<string, AgentProfile> = {
	scout: agent("scout"),
	forge: agent("forge"),
	"o-p1": agent("o-p1", { name: "Orchestrator", projectId: "p1", role: "orchestrator", delegates: ["scout"] }),
	"scout-1": agent("scout-1", { name: "Scout", projectId: "p1", template: { id: "scout", copiedAt: 1, templateUpdatedAt: 1 } }),
	"forge-1": agent("forge-1", { name: "Forge", projectId: "p1", removedAt: 5 }),
	"atlas-1": agent("atlas-1", { name: "Atlas", projectId: "p1", delegates: ["scout", "scout-1", "forge-1", "x-2"] }),
	atlas: agent("atlas", { delegates: ["scout", "scout-1", "forge-1", "gone"] }),
	"x-2": agent("x-2", { projectId: "p2" }),
	// The copies of a project carrying over made, deleted since (#458).
	"scout-3": agent("scout-3", { name: "Scout", projectId: "p3", template: { id: "scout", copiedAt: 1, templateUpdatedAt: 1 } }),
	"atlas-3": agent("atlas-3", { name: "Atlas", projectId: "p3", role: "orchestrator", delegates: ["scout-3"], template: { id: "atlas", copiedAt: 1, templateUpdatedAt: 1 } }),
};
const meta = (agentId: string | undefined, extra: Partial<Meta> = {}): Meta => ({ title: "", createdAt: 1, updatedAt: 1, access: "read", ...(agentId === undefined ? {} : { agentId }), ...extra });
const conversations: Record<string, Meta> = {
	1: meta("o-p1", { projectId: "p1" }),
	2: meta("atlas-1", { projectId: "p1" }),
	3: meta("atlas"),
	4: meta("scout", { projectId: "p1", projectAgentId: "scout-1" }),
	5: meta("scout-1", { projectId: "p1", parent: 1 }),
	6: meta("x-2", { projectId: "p2" }),
	7: meta("scout", { projectId: "p3", projectAgentId: "scout-3" }),
	8: meta("atlas", { projectId: "p3", projectAgentId: "atlas-3" }),
};
const working = new Set<number>();

const saved: Record<string, unknown> = { projects: { preview: false } };
const engine = {
	harness: () => ({
		snapshot: async () => structuredClone(stored),
		observeCommits: () => ({ detach() {} }),
		commit: async (edit: (tx: unknown) => Promise<unknown>) => edit({ doc: async () => ({ agents }) }),
	}),
	context: () => BACKGROUND_CONTEXT,
	setting: (key: string) => saved[key],
	saveSetting: (key: string, value: unknown) => void (saved[key] = value),
	broadcast: () => {},
	log: () => {},
	agents: () => agents,
} as unknown as Engine;
const host = { inbox: { ask: async () => "deny" }, conversations: () => conversations, working: (id: number) => working.has(id), features: [] } as unknown as Host;
const feature = projects(host, engine);
await feature.start!();
projectAgents(host, engine);
const setPreview = (on: boolean) => feature.handlers!["projects.setPreview"]!({ on });

// ---- runsAs and agentOf

assert.equal(projectsOn(), false);
assert.equal(runsAs(conversations[3], agents), "atlas");
assert.equal(runsAs(conversations[4], agents), "scout", "with the preview off, a conversation carried over runs as its agentId");
assert.equal(runsAs(undefined, agents), undefined);
assert.equal(runsAs(meta(undefined, { chat: true }), agents), undefined, "a chat has no agent");
await setPreview(true);
assert.equal(runsAs(conversations[4], agents), "scout-1", "with it on, as the project's copy");
assert.equal(agentOf(conversations[4], agents)?.id, "scout-1");
assert.equal(runsAs(conversations[3], agents), "atlas", "a conversation not carried over runs as its agentId, preview or not");
assert.equal(runsAs(conversations[1], agents), "o-p1");
assert.equal(runsAs(meta("scout", { projectAgentId: "forge-1" }), agents), "scout", "a copy removed through a tool: its agentId");
assert.equal(runsAs(meta("scout", { projectAgentId: "deleted" }), agents), "scout", "a copy deleted: its agentId");
assert.equal(agentOf(meta("deleted", { projectAgentId: "deleted-too" }), agents), undefined, "both deleted: none, so it keeps the setup it has");
assert.equal(runsAs(meta("forge-1"), agents), "forge-1");
assert.equal(agentOf(meta("forge-1"), agents), undefined, "its own agent removed: none, as for a deleted agent");
assert.equal(agentOf(meta("deleted"), agents), undefined);
// A conversation whose project was deleted is in no project (3.6): it runs as its agentId, its copy still there.
assert.equal(runsAs(conversations[7], agents), "scout", "its project deleted: its agentId");
assert.equal(runsAs(conversations[8], agents), "atlas", "the deleted project's orchestrator's conversation too");
await setPreview(false);
assert.equal(agentOf(conversations[4], agents)?.id, "scout");
step("runsAs: the project's copy for a conversation carried over, while the preview is on and the copy and its project are there; else agentId");

// ---- Whom a conversation may hand work to

const ids = (list: AgentProfile[]) => list.map((each) => each.id);
// With the preview off, as before projects: the agents its delegates name that exist, in order (not removed).
assert.deepEqual(ids(delegateTargets(agents.atlas, agents, 3)), ["scout", "scout-1"]);
assert.deepEqual(ids(delegateTargets(agents["o-p1"], agents, 1)), ["scout"], "the orchestrator too, by its delegates");
assert.deepEqual(ids(delegateTargets(agents["atlas-1"], agents, 2)), ["scout", "scout-1", "x-2"]);
assert.deepEqual(ids(delegateTargets(undefined, agents, 3)), []);
await setPreview(true);
// The orchestrator's current conversation: every other agent of the project, not removed, whatever its delegates say.
assert.deepEqual(ids(delegateTargets(agents["o-p1"], agents, 1)), ["scout-1", "atlas-1"]);
// Another conversation of the project, a sub-chat of the orchestrator's among them: its delegates, in the project.
assert.deepEqual(ids(delegateTargets(agents["atlas-1"], agents, 2)), ["scout-1"]);
assert.deepEqual(ids(delegateTargets(agents["o-p1"], agents, 5)), [], "the orchestrator agent in another conversation: its delegates, none in the project");
// Outside any project: templates only.
assert.deepEqual(ids(delegateTargets(agents.atlas, agents, 3)), ["scout"]);
// A conversation not made yet is in its agent's project.
assert.deepEqual(ids(delegateTargets(agents["atlas-1"], agents)), ["scout-1"]);
assert.deepEqual(ids(delegateTargets(agents.atlas, agents)), ["scout"]);
// An archived project's conversation keeps to its project's agents.
assert.deepEqual(ids(delegateTargets(agents["atlas-1"], agents, 6)), ["x-2"]);
// A deleted project's conversation is in no project: its own agent's templates, as before projects (#458).
assert.deepEqual(ids(delegateTargets(agentOf(conversations[8], agents), agents, 8)), ["scout"]);
// And an agent of a deleted project, for a conversation not made yet, hands work to no project's agents.
assert.deepEqual(ids(delegateTargets(agents["atlas-3"], agents)), []);
step("delegateTargets: as before with the preview off; with it on, the project's agents, or templates outside any project, a deleted one's included");

// ---- What Update from template compares

const starter = agent("starter", { access: "ask", instructions: "Be careful." });
const copied: AgentProfile = {
	...starter,
	id: "starter-1",
	name: "Renamed",
	cwd: "/work/p1",
	delegates: ["scout-1"],
	commandRules: [{ folder: "/x", words: ["ls"], createdAt: 1 }],
	worktree: false,
	setup: "",
	codeMode: false,
	mcpServers: [],
	files: [],
	computer: { testCopies: false, ask: true, apps: [], enabled: false },
	browser: { enabled: false, ask: true },
	schedule: { enabled: false },
	toolsOff: [],
	toolsOn: [],
	compactionTokens: null,
	projectId: "p1",
};
assert.deepEqual(templateChanges(copied, starter), [], "defaults, key order, name, folder, delegates and allowed commands are no change");
assert.deepEqual(templateChanges({ ...copied, access: "read", toolsOff: ["web"] }, starter, { copy: true, template: true }), [
	{ setting: "access", now: "read", template: "ask" },
	{ setting: "toolsOff", now: ["web"], template: [] },
]);
assert.deepEqual(templateChanges(copied, starter, { copy: false, template: true }), [{ setting: "memory", now: false, template: true }]);
step("templateChanges compares the settings a copy takes from its template, as saved, and the memory switch");

// ---- A project agent's folder, and stamping updatedAt

assert.equal(projectAgentFolder("p1", undefined), "/work/p1");
assert.equal(projectAgentFolder("p1", "/work/p1"), "/work/p1");
assert.throws(() => projectAgentFolder("p1", "/elsewhere"), { message: AGENT_IN_FOLDER });
assert.throws(() => projectAgentFolder("p1", null), { message: AGENT_IN_FOLDER });
assert.equal(stampsAgents(), true);
await setPreview(false);
assert.equal(stampsAgents(), true, "once there are projects, whatever the preview");
step("a project agent works in its project's folder; agents.save stamps updatedAt once there are projects");

// ---- Removing an agent through a tool (#465 calls it)

await assert.rejects(removeAgent("o-p1"), { message: "Orchestrator is the project's orchestrator. Make another agent the orchestrator first." });
await assert.rejects(removeAgent("scout"), { message: "Unknown agent: scout" }, "a template is not removed");
await assert.rejects(removeAgent("forge-1"), { message: "Unknown agent: forge-1" }, "already removed");
await assert.rejects(removeAgent("x-2"), { message: PROJECT_ARCHIVED });
working.add(5);
await assert.rejects(removeAgent("scout-1"), { message: "Scout is working on sub-chat 5. Wait for it, or ask the person to stop it." });
working.clear();
await removeAgent("scout-1");
assert.equal(typeof agents["scout-1"]!.removedAt, "number");
await setPreview(true);
assert.equal(runsAs(conversations[4], agents), "scout", "its conversations carried over run as their agentId again");
assert.deepEqual(ids(delegateTargets(agents["o-p1"], agents, 1)), ["atlas-1"], "and it is offered to nobody");
step("removeAgent sets removedAt, refusing the orchestrator, a template, an archived project's agent and one working");
