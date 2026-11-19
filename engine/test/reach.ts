// Reach (#465, docs/projects.md 7.1 and 7.2), without an engine: every setting of an agent and of a project classed as
// widening or not, a setting the tables do not name counting as widening, the baseline of a new agent made by an agent,
// and which operations an agent's Undo can only ask for. engine/test/changes.ts drives the same through a real engine.

import assert from "node:assert/strict";
import { inverseOf, type Op, opWidens } from "../src/changes.ts";
import { AGENT_FIELDS, agentFieldWidens, agentValues, baselineOf, projectFieldWidens, splitNew } from "../src/reach.ts";
import type { AgentProfile } from "../src/state.ts";

function step(name: string): void {
	console.log(`ok  ${name}`);
}

// ---- An agent's settings (7.1)

const widens = (name: string, before: unknown, after: unknown) => agentFieldWidens(name, before, after);
for (const name of ["name", "description", "color", "instructions", "model", "thinkingLevel", "maxTurns", "compactionTokens", "codeMode"]) {
	assert.equal(widens(name, "a", "b"), false, name);
}
assert.equal(widens("access", "ask", "full"), true);
assert.equal(widens("access", "none", "read"), true);
assert.equal(widens("access", "full", "read"), false);
assert.equal(widens("allowEverything", false, true), true);
assert.equal(widens("allowEverything", true, false), false);
assert.equal(widens("toolsOff", ["web"], []), true, "a built-in tool turned back on");
assert.equal(widens("toolsOff", [], ["web"]), false);
assert.equal(widens("toolsOn", [], ["pictures"]), true);
assert.equal(widens("toolsOn", ["pictures"], []), false);
const computer = { enabled: true, apps: ["com.apple.Notes"], ask: true, testCopies: false };
assert.equal(widens("computer", { ...computer, enabled: false }, computer), true, "turned on");
assert.equal(widens("computer", computer, { ...computer, apps: [...computer.apps, "com.apple.Mail"] }), true, "an app added");
assert.equal(widens("computer", computer, { ...computer, testCopies: true }), true, "test copies");
assert.equal(widens("computer", computer, { ...computer, ask: false }), true, "ask turned off");
assert.equal(widens("computer", computer, { ...computer, apps: [] }), false, "an app taken away");
assert.equal(widens("browser", { enabled: false, ask: true }, { enabled: true, ask: true }), true);
assert.equal(widens("browser", { enabled: true, ask: true }, { enabled: true, ask: false }), true);
assert.equal(widens("browser", { enabled: true, ask: false }, { enabled: false, ask: false }), false);
assert.equal(widens("mcpServers", ["a"], ["a", "b"]), true);
assert.equal(widens("mcpServers", ["a", "b"], ["a"]), false);
assert.equal(widens("files", [{ path: "/a", note: "" }], [{ path: "/a", note: "now with a note" }]), false, "a note changed");
assert.equal(widens("files", [], [{ path: "/a", note: "" }]), true);
assert.equal(widens("schedule", { enabled: false }, { enabled: true }), true);
const rule = { folder: "/p", words: ["npm", "test"], createdAt: 1 };
assert.equal(widens("commandRules", [], [rule]), true);
assert.equal(widens("commandRules", [rule], []), false);
assert.equal(widens("commandRules", [rule], [{ ...rule, createdAt: 2 }]), false, "the same command again");
assert.equal(widens("worktree", false, true), true);
assert.equal(widens("setup", "", "npm ci"), true);
assert.equal(widens("setup", "npm ci", "npm install"), true, "changed");
assert.equal(widens("setup", "npm ci", ""), false, "cleared");
assert.equal(widens("delegates", [], ["forge"]), true);
assert.equal(widens("delegates", ["forge"], []), false);
assert.equal(widens("memory", false, true), true);
assert.equal(widens("memory", true, false), false);
assert.equal(widens("someSettingAddedLater", false, false), false, "no change, nothing to class");
assert.equal(widens("someSettingAddedLater", false, true), true, "a setting the table does not name widens on any change");
assert.equal(widens("someSettingAddedLater", true, false), true);
assert.equal(widens("variables", [], []), false);
assert.equal(widens("variables", [], [{ name: "TOKEN", set: true }]), true);
step("every setting of an agent is classed as 7.1 says, and one it does not name widens on any change");

// ---- A project's settings (7.1)

assert.equal(projectFieldWidens("name", "A", "B"), false);
assert.equal(projectFieldWidens("folder", "/a", "/b"), true);
assert.equal(projectFieldWidens("folder", "/a", null), true);
assert.equal(projectFieldWidens("repository", null, { owner: "o", name: "n" }), true);
assert.equal(projectFieldWidens("withoutAsking.merge", false, true), true);
assert.equal(projectFieldWidens("withoutAsking.merge", true, false), false);
assert.equal(projectFieldWidens("limits.planShare", 90, 100), true, "raised");
assert.equal(projectFieldWidens("limits.planShare", 90, null), true, "turned off");
assert.equal(projectFieldWidens("limits.planShare", 90, 50), false, "lowered");
assert.equal(projectFieldWidens("limits.dailySpend", null, 5), false, "one set where there was none");
assert.equal(projectFieldWidens("wakeOnReports", false, true), true, "not offered to a tool, so counted as widening");
assert.equal(projectFieldWidens("somethingLater", 1, 2), true);
step("every setting of a project is classed as 7.1 says, and one it does not name widens");

// ---- The baseline of a new agent made by an agent (7.2)

const template: AgentProfile = {
	id: "t",
	name: "Builder",
	description: "Builds",
	color: "orange",
	model: { provider: "demo", modelId: "demo-1" },
	thinkingLevel: "high",
	instructions: "Build things.",
	access: "full",
	cwd: null,
	worktree: true,
	setup: "npm ci",
	delegates: ["scout"],
	maxTurns: 40,
	codeMode: true,
	mcpServers: ["github"],
	files: [{ path: "/docs", note: "" }],
	computer: { enabled: true, apps: ["com.apple.Notes"], ask: false, testCopies: false },
	browser: { enabled: true, ask: true },
	schedule: { enabled: true },
	toolsOff: ["web"],
	toolsOn: ["pictures", "compact"],
	compactionTokens: 50_000,
	commandRules: [rule],
	allowEverything: true,
	createdAt: 1,
};
const wanted = agentValues(template, true);
const { made, asked } = splitNew(wanted);
assert.deepEqual(made, { ...baselineOf(wanted), toolsOff: ["web"] }, "made at the baseline, but for what narrows");
assert.equal(made.access, "ask");
assert.deepEqual(made.model, template.model, "the model as asked: spending is bounded by the limits");
assert.equal(made.instructions, "Build things.");
assert.equal(made.codeMode, true);
assert.deepEqual(
	asked.map((field) => field.name),
	["access", "allowEverything", "toolsOn", "computer", "browser", "mcpServers", "files", "schedule", "commandRules", "worktree", "setup", "delegates", "memory"],
);
assert.deepEqual(asked.find((field) => field.name === "access"), { name: "access", before: "ask", after: "full" });
const tame = splitNew(agentValues({ ...template, access: "read", worktree: false, setup: "", delegates: [], mcpServers: [], files: [], computer: undefined, browser: undefined, schedule: undefined, toolsOn: [], commandRules: [], allowEverything: undefined }, false));
assert.deepEqual(tame.asked, [], "a new agent that asks for nothing that widens is made as asked");
for (const field of asked) assert.ok((AGENT_FIELDS as readonly string[]).includes(field.name));
step("a new agent is made at the baseline for each setting that would widen, and one request asks for all of them");

// ---- Which operations an agent's Undo can only ask for (3.12)

const projectRule = { id: "r1", text: "Run the tests.", binds: "everyone" as const, addedBy: { kind: "person" as const }, createdAt: 1, updatedAt: 1 };
const note = { id: "n1", text: "A note", createdAt: 1, conversation: null, agentId: null, audience: null };
const cases: [Op, boolean][] = [
	[{ kind: "agent.change", id: "a", fields: [{ name: "access", before: "ask", after: "full" }] }, true],
	[{ kind: "agent.change", id: "a", fields: [{ name: "description", before: "x", after: "y" }] }, false],
	[{ kind: "agent.remove", id: "a" }, false],
	[{ kind: "agent.restore", id: "a" }, false],
	[{ kind: "project.change", fields: [{ name: "withoutAsking.merge", before: false, after: true }] }, true],
	[{ kind: "project.change", fields: [{ name: "name", before: "A", after: "B" }] }, false],
	[{ kind: "rule.add", rule: projectRule, at: 0 }, false],
	[{ kind: "rule.remove", rule: projectRule, at: 0 }, true],
	[{ kind: "rule.edit", id: "r1", before: { text: "a", binds: "orchestrator" }, after: { text: "a", binds: "everyone" } }, false],
	[{ kind: "rule.edit", id: "r1", before: { text: "a", binds: "everyone" }, after: { text: "a", binds: "orchestrator" } }, true],
	[{ kind: "rule.edit", id: "r1", before: { text: "a", binds: "everyone" }, after: { text: "b", binds: "everyone" } }, true],
	[{ kind: "rule.move", id: "r1", from: 0, to: 1 }, false],
	[{ kind: "note.add", note }, false],
	[{ kind: "note.remove", note }, false],
	[{ kind: "work.local", id: 1, action: "close", before: { state: "open" }, after: { state: "done" } }, false],
	[{ kind: "wake.choice", submissions: [4, 5], before: [null, "each"], after: "never" }, false],
	[{ kind: "orchestrator.set", from: "a", to: "b" }, true],
	[{ kind: "work.github", intent: "i", action: "merge", summary: "Merged #1" }, true],
];
for (const [op, wide] of cases) assert.equal(opWidens(op), wide, `${op.kind} ${JSON.stringify(op)}`);
// Undoing the addition of a rule removes it, so an agent's Undo of it is a request; the inverse of each inverse is the op.
const added: Op = { kind: "rule.add", rule: projectRule, at: 2 };
assert.equal(opWidens(inverseOf(added)!), true);
assert.deepEqual(inverseOf(inverseOf(added)!), added);
const chosen: Op = { kind: "wake.choice", submissions: [4, 5], before: [null, "each"], after: "all", batches: { before: [null, null], after: ["b-1", "b-1"] } };
assert.deepEqual(inverseOf(chosen), { kind: "wake.choice", submissions: [4, 5], before: ["all", "all"], after: [null, "each"], batches: { before: ["b-1", "b-1"], after: [null, null] } }, "each run's own choice and batch put back");
const filed: Op = { kind: "work.local", id: 3, action: "file", before: {}, after: { id: 3, title: "A" } };
assert.deepEqual(inverseOf(filed), { kind: "work.local", id: 3, action: "file", before: { id: 3, title: "A" }, after: {} }, "filing is undone by taking the item away");
assert.equal(inverseOf({ kind: "orchestrator.set", from: "a", to: "b" }), null, "no Undo: it starts a fresh conversation");
assert.equal(inverseOf({ kind: "work.github", intent: "i", action: "merge", summary: "Merged #1" }), null, "no Undo: done on GitHub");
step("an agent's Undo that would widen reach is known as such; work and waking never widen; the orchestrator and GitHub's have no Undo");
