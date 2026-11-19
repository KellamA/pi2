// Agents of a project, and templates (#457, docs/projects.md 3.3, 3.4 and the agent requests of 4.2). A real engine on a
// throwaway data folder, driven over its socket with the demo model, as an app would drive it.
//
// First what must not change: with the preview never on, the new requests are refused, saving an agent writes nothing
// new, a conversation in no project runs as its own agent (`runsAs` in the library and Activity), and an agent that
// hands out work is told the same prompt and tool declarations, byte for byte, before the preview was ever on, with it
// on beside projects with copies of the same agents, and with it off again. Then copying templates into a project,
// making an agent there, what `agents.save`, `agents.duplicate` and `agents.delete` do for a project agent, Update from
// template, `delegate` naming only the project's agents and asking first while `startAgents` is off, and an engine
// stopped and started again. runsas.ts checks `runsAs` itself, and removing an agent, without an engine.

import assert from "node:assert/strict";
import { type ChildProcess, execFileSync, spawn } from "node:child_process";
import { mkdirSync, mkdtempSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { EngineClient, standInApp, stop } from "./patience.ts";
import { AGENT_IN_FOLDER, TEMPLATE_DELETED } from "../src/projectagents.ts";
import { PREVIEW_OFF, PROJECT_ARCHIVED } from "../src/projects.ts";

const home = mkdtempSync(join(tmpdir(), "pi2-pagents-"));
const work = realpathSync(mkdtempSync(join(tmpdir(), "pi2-pagents-work-")));
const main = join(import.meta.dirname, "..", "src", "main.ts");
const KEYCHAIN_SERVICE = `dev.pi2.credentials.test-project-agents-${process.pid}`;
process.env.PI2_DEMO_TOKENS_PER_SECOND ??= "100000";
process.env.PI2_LOGIN_SHELL ??= "off";
const env = { ...process.env, PI2_HOME: home, PI2_KEYCHAIN_SERVICE: KEYCHAIN_SERVICE, PI2_APP_BUNDLE: standInApp() };

let engine: ChildProcess | undefined;
process.on("exit", () => {
	if (engine !== undefined && engine.exitCode === null && engine.signalCode === null) engine.kill("SIGKILL");
	rmSync(home, { recursive: true, force: true });
	rmSync(work, { recursive: true, force: true });
	try {
		while (true) execFileSync("/usr/bin/security", ["delete-generic-password", "-s", KEYCHAIN_SERVICE], { stdio: "ignore" });
	} catch {
		// None left.
	}
});

function step(name: string): void {
	console.log(`ok  ${name}`);
}

const alpha = join(work, "alpha");
const beta = join(work, "beta");
for (const folder of [alpha, beta]) mkdirSync(folder, { recursive: true });

class Client extends EngineClient {
	/** What the demo model answers to `text`, once its run is over. */
	async answer(id: number, text: string): Promise<string> {
		const assistant = () => (this.conversations.get(id)?.items ?? []).filter((item: any) => item.kind === "assistant");
		const before = assistant().length;
		await this.call("submit", { id, text });
		await this.until(`answer to ${text}`, () => {
			const conv = this.conversations.get(id);
			return conv !== undefined && !conv.state.busy && assistant().length > before;
		});
		return assistant().at(-1).text as string;
	}
	/** The result of the last call of `tool` in conversation `id`. */
	result(id: number, tool: string): any {
		return (this.conversations.get(id)?.items ?? []).filter((item: any) => item.kind === "tool" && item.name === tool).at(-1);
	}
	/** The whole prompt and every tool declaration the model was sent, as text, and what each system message changed. */
	async told(id: number): Promise<{ full: string; history: string }> {
		const full = await this.answer(id, "/system full");
		assert.ok(full.startsWith("FULL\n"), full.slice(0, 200));
		return { full, history: await this.answer(id, "/system history") };
	}
	agent(id: string): any {
		return this.events.agents?.agents?.find((agent: any) => agent.id === id);
	}
	agents(projectId: string): any[] {
		return (this.events.agents?.agents ?? []).filter((agent: any) => agent.projectId === projectId);
	}
	listed(id: number): any {
		return this.events.library?.conversations?.find((conversation: any) => conversation.id === id);
	}
	project(id: string): any {
		return this.events.projects?.projects?.find((project: any) => project.id === id);
	}
}

const refused = async (promise: Promise<unknown>, message: string | RegExp) => {
	await assert.rejects(promise, (error: Error) => (typeof message === "string" ? error.message === message : message.test(error.message)), String(message));
};

const start = () => spawn(process.execPath, [main], { env, stdio: ["ignore", "ignore", "inherit"] });
engine = start();
let client = await Client.connect(engine, home);
try {
	await client.until("agents", () => client.events.agents && client.events.library && client.events.projects);

	// ---- With the preview never turned on

	for (const [method, params] of [
		["projects.addAgent", { projectId: "p-x", template: "scout" }],
		["agents.restore", { id: "scout" }],
		["agents.updateFromTemplate", { id: "scout", apply: false }],
	] as const) {
		await refused(client.call(method, params), PREVIEW_OFF);
	}
	// Saving an agent writes nothing new: no `updatedAt`.
	await client.call("agents.save", { agent: { ...client.agent("forge"), description: "Saved before the preview." } });
	await client.until("forge saved", () => client.agent("forge").description === "Saved before the preview.");
	assert.equal(client.agent("forge").updatedAt, undefined);
	step("with the preview never on: the agent requests are refused, and agents.save writes no updatedAt");

	// A conversation in no project runs as its own agent, in the library and in Activity.
	const plain = (await client.call("conversation.create", { agentId: "forge" })).id as number;
	await client.call("conversation.open", { id: plain });
	assert.equal((await client.until("its row", () => client.listed(plain))).runsAs, "forge");
	void client.call("submit", { id: plain, text: "/bash echo waiting" });
	const approval = await client.until("an approval", () => client.events.inbox?.items?.find((item: any) => item.conversationId === plain));
	assert.equal(approval.agentName, "Forge");
	const run = await client.until("its run in Activity", () => client.events.activity?.runs?.find((row: any) => row.conversationId === plain));
	assert.equal(run.runsAs, "forge");
	assert.equal(run.agentId, "forge");
	await client.call("inbox.decide", { id: approval.id, decision: "deny" });
	await client.until("idle", () => client.conversations.get(plain)?.state?.busy === false);
	step("a conversation in no project runs as its agentId: runsAs in library and activity");

	// An agent that hands out work (Atlas, to Scout and Forge): what it is told, before the preview was ever on.
	const atlas = (await client.call("conversation.create", { agentId: "atlas" })).id as number;
	await client.call("conversation.open", { id: atlas });
	assert.match(await client.answer(atlas, "/delegate Scout: before the preview"), /^Done\. The tool returned: You said: "before the preview"/);
	const before = await client.told(atlas);
	assert.ok(before.full.includes('"delegate"'), "Atlas is offered delegate");
	assert.ok(before.full.includes("- Scout: ") && before.full.includes("- Forge: "), "and told of Scout and Forge");

	// ---- The preview on: a project, and copies of templates in it

	await client.call("projects.setPreview", { on: true });
	await client.until("preview on", () => client.events.projects.preview === true);
	const made = await client.call("projects.create", { folder: alpha });
	const project = await client.until("the project", () => client.project(made.id));
	await client.until("its orchestrator", () => client.agent(project.orchestratorId));

	// Scout's memory on, so that its copy takes the switch.
	await client.call("memory.setEnabled", { agentId: "scout", enabled: true });
	const scout = (await client.call("projects.addAgent", { projectId: made.id, template: "scout" })).id as string;
	const scoutCopy = await client.until("the copy of Scout", () => client.agent(scout));
	const scoutTemplate = client.agent("scout");
	assert.equal(scoutCopy.name, "Scout");
	assert.equal(scoutCopy.projectId, made.id);
	assert.equal(scoutCopy.cwd, alpha);
	assert.equal(scoutCopy.access, scoutTemplate.access);
	assert.equal(scoutCopy.instructions, scoutTemplate.instructions);
	assert.equal(scoutCopy.description, scoutTemplate.description);
	assert.equal(scoutCopy.role, undefined);
	assert.equal(scoutCopy.madeBy, undefined);
	assert.equal(scoutCopy.template.id, "scout");
	assert.equal(scoutCopy.template.templateUpdatedAt, scoutTemplate.updatedAt ?? scoutTemplate.createdAt);
	assert.equal(typeof scoutCopy.updatedAt, "number");
	assert.notEqual(scout, "scout");
	await client.until("the copy's memory on", () => client.events.memory?.agents?.[scout]?.enabled === true);
	// Atlas names Scout and Forge: its copy names the project's copy of Scout, and leaves Forge out, having none.
	const atlasCopyId = (await client.call("projects.addAgent", { projectId: made.id, template: "atlas" })).id as string;
	const atlasCopy = await client.until("the copy of Atlas", () => client.agent(atlasCopyId));
	assert.deepEqual(atlasCopy.delegates, [scout]);
	// A second copy of the same template is named apart.
	const scout2 = (await client.call("projects.addAgent", { projectId: made.id, template: "scout" })).id as string;
	assert.equal((await client.until("Scout 2", () => client.agent(scout2))).name, "Scout 2");
	step("projects.addAgent copies a template into the project: its settings, the project's folder, mapped delegates, memory");

	// An agent made from settings, with the same checks as agents.save.
	const reviewer = (await client.call("projects.addAgent", { projectId: made.id, agent: { name: "Reviewer", access: "ask", instructions: "Review." } })).id as string;
	const reviewerRow = await client.until("Reviewer", () => client.agent(reviewer));
	assert.equal(reviewerRow.projectId, made.id);
	assert.equal(reviewerRow.cwd, alpha);
	assert.equal(reviewerRow.template, undefined);
	assert.equal(reviewerRow.access, "ask");
	await refused(client.call("projects.addAgent", { projectId: made.id, agent: { name: "Elsewhere", cwd: beta } }), AGENT_IN_FOLDER);
	await refused(client.call("projects.addAgent", { projectId: made.id, agent: { name: "reviewer" } }), "There is already an agent called reviewer");
	await refused(client.call("projects.addAgent", { projectId: made.id, agent: { name: "" } }), "Give the agent a name");
	await refused(client.call("projects.addAgent", { projectId: made.id, agent: { name: "Bad", access: "root" } }), "Unknown access level: root");
	await refused(client.call("projects.addAgent", { projectId: made.id, template: "scout", agent: { name: "Both" } }), /not both/);
	await refused(client.call("projects.addAgent", { projectId: made.id }), /agent must be/);
	await refused(client.call("projects.addAgent", { projectId: made.id, template: "nobody" }), "Unknown agent: nobody");
	await refused(client.call("projects.addAgent", { projectId: made.id, template: scout }), `Unknown agent: ${scout}`);
	await refused(client.call("projects.addAgent", { projectId: "p-none", template: "scout" }), "Unknown project: p-none");
	// The same name as a template, or as another project's agent, is free in a project.
	const other = await client.call("projects.create", { folder: beta });
	const otherReviewer = (await client.call("projects.addAgent", { projectId: other.id, agent: { name: "Reviewer" } })).id as string;
	assert.equal((await client.until("the other Reviewer", () => client.agent(otherReviewer))).cwd, beta);
	step("projects.addAgent makes an agent from settings, in the project's folder, and refuses what agents.save refuses");

	// agents.save: as today for a project agent, keeping its marks, in its project's folder only; it stamps updatedAt now.
	await refused(client.call("agents.save", { agent: { ...reviewerRow, cwd: beta } }), AGENT_IN_FOLDER);
	await client.call("agents.save", { agent: { ...reviewerRow, cwd: alpha, description: "Reads diffs.", projectId: undefined, template: { id: "forge", copiedAt: 1, templateUpdatedAt: 1 } } });
	const reviewerSaved = await client.until("Reviewer saved", () => client.agent(reviewer).description === "Reads diffs." && client.agent(reviewer));
	assert.equal(reviewerSaved.projectId, made.id);
	assert.equal(reviewerSaved.template, undefined);
	assert.ok(reviewerSaved.updatedAt >= reviewerRow.updatedAt);
	await refused(client.call("agents.save", { agent: { ...reviewerSaved, name: "SCOUT" } }), "There is already an agent called SCOUT");
	// Saved unchanged, so that what Atlas is told of it stays the same (below).
	await client.call("agents.save", { agent: client.agent("forge") });
	assert.equal(typeof (await client.until("forge stamped", () => client.agent("forge").updatedAt !== undefined && client.agent("forge"))).updatedAt, "number");
	step("agents.save keeps a project agent's marks and folder, refuses another folder, and stamps updatedAt once there are projects");

	// agents.duplicate: a project agent's copy is in the same project, never the orchestrator.
	const duplicate = (await client.call("agents.duplicate", { id: reviewer })).id as string;
	const duplicateRow = await client.until("the duplicate", () => client.agent(duplicate));
	assert.equal(duplicateRow.name, "Reviewer copy");
	assert.equal(duplicateRow.projectId, made.id);
	assert.equal(duplicateRow.cwd, alpha);
	const orchestratorCopy = (await client.call("agents.duplicate", { id: project.orchestratorId })).id as string;
	const orchestratorCopyRow = await client.until("the orchestrator's duplicate", () => client.agent(orchestratorCopy));
	assert.equal(orchestratorCopyRow.projectId, made.id);
	assert.equal(orchestratorCopyRow.role, undefined);
	assert.equal(orchestratorCopyRow.name, "Orchestrator copy");
	// A template's duplicate is a template, as today.
	const scoutDuplicate = (await client.call("agents.duplicate", { id: "scout" })).id as string;
	assert.equal((await client.until("Scout's duplicate", () => client.agent(scoutDuplicate))).projectId, undefined);
	step("agents.duplicate keeps a project agent's copy in its project, never as orchestrator");

	// agents.delete: refuses the orchestrator; removes a project agent from the others' delegates.
	await refused(client.call("agents.delete", { id: project.orchestratorId }), "Orchestrator is the project's orchestrator. Make another agent the orchestrator first.");
	await client.call("agents.delete", { id: orchestratorCopy });
	await client.call("agents.delete", { id: duplicate });
	await client.call("agents.delete", { id: scoutDuplicate });
	await client.until("deleted", () => client.agent(duplicate) === undefined && client.agent(orchestratorCopy) === undefined && client.agent(scoutDuplicate) === undefined);
	step("agents.delete refuses the orchestrator, and deletes any other agent of a project");

	// ---- Update from template

	assert.deepEqual(await client.call("agents.updateFromTemplate", { id: scout, apply: false }), { changes: [], applied: false });
	await client.call("agents.save", { agent: { ...client.agent("scout"), instructions: "Read more carefully.", access: "ask", browser: { enabled: true } } });
	await client.call("memory.setEnabled", { agentId: "scout", enabled: false });
	await client.until("Scout changed", () => client.agent("scout").access === "ask" && client.events.memory?.agents?.scout?.enabled === false);
	const looked = await client.call("agents.updateFromTemplate", { id: scout });
	assert.equal(looked.applied, false);
	assert.deepEqual(
		looked.changes,
		[
			{ setting: "instructions", now: scoutCopy.instructions, template: "Read more carefully." },
			{ setting: "access", now: "read", template: "ask" },
			{ setting: "browser", now: { enabled: false, ask: true }, template: { enabled: true, ask: true } },
			{ setting: "memory", now: true, template: false },
		],
	);
	// Looking changed nothing.
	assert.equal(client.agent(scout).access, "read");
	assert.equal(client.events.memory.agents[scout].enabled, true);
	await refused(client.call("agents.updateFromTemplate", { id: scout, apply: "yes" }), "apply must be true or false");
	// Its name, folder and delegates are the project's own, and stay.
	await client.call("agents.save", { agent: { ...client.agent(scout), name: "Researcher" } });
	await client.until("renamed", () => client.agent(scout).name === "Researcher");
	const applied = await client.call("agents.updateFromTemplate", { id: scout, apply: true });
	assert.equal(applied.applied, true);
	assert.equal(applied.changes.length, 4);
	const updated = await client.until("the copy updated", () => client.agent(scout).access === "ask" && client.events.memory.agents[scout].enabled === false && client.agent(scout));
	assert.equal(updated.instructions, "Read more carefully.");
	assert.equal(updated.browser.enabled, true);
	assert.equal(updated.name, "Researcher");
	assert.equal(updated.cwd, alpha);
	assert.equal(updated.projectId, made.id);
	assert.ok(updated.template.copiedAt >= scoutCopy.template.copiedAt);
	assert.equal(updated.template.templateUpdatedAt, client.agent("scout").updatedAt);
	assert.deepEqual(await client.call("agents.updateFromTemplate", { id: scout, apply: false }), { changes: [], applied: false });
	await refused(client.call("agents.updateFromTemplate", { id: reviewer, apply: false }), "Reviewer was not made from a template");
	await refused(client.call("agents.updateFromTemplate", { id: "scout", apply: false }), "Unknown agent: scout");
	// A template deleted since: the copy stays as it is.
	await client.call("agents.save", { agent: { name: "Passing", instructions: "Gone soon." } });
	const passing = (await client.call("projects.addAgent", { projectId: made.id, template: "passing" })).id as string;
	await client.call("agents.delete", { id: "passing" });
	await client.until("the template gone", () => client.agent("passing") === undefined);
	await refused(client.call("agents.updateFromTemplate", { id: passing, apply: false }), TEMPLATE_DELETED);
	assert.equal(client.agent(passing).instructions, "Gone soon.");
	step("agents.updateFromTemplate says what would change, then changes it, leaving the project's own settings");

	// ---- delegate in a project

	// The orchestrator's conversation hands work to every other agent of the project, and to none outside it.
	await client.call("conversation.open", { id: made.conversation });
	assert.match(await client.answer(made.conversation, "/delegate Researcher: from the orchestrator"), /^Done\. The tool returned: You said: "from the orchestrator"/);
	const fromOrchestrator = await client.until("the sub-chat", () => client.events.library.conversations.find((row: any) => row.parent === made.conversation));
	assert.equal(fromOrchestrator.agentId, scout);
	assert.equal(fromOrchestrator.runsAs, scout);
	assert.equal(fromOrchestrator.projectId, made.id);
	await client.answer(made.conversation, "/delegate Forge: outside the project");
	assert.match(client.result(made.conversation, "delegate").text, /^Unknown agent "Forge"\. Available: Researcher, Atlas, Scout 2, Reviewer, Passing\.$/);
	// An agent's own conversation hands work to those its delegates name, in the project: Atlas's copy to the copy of Scout.
	const own = (await client.call("conversation.create", { agentId: atlasCopyId })).id as number;
	await client.call("conversation.open", { id: own });
	await client.answer(own, "/delegate Scout 2: not named");
	assert.match(client.result(own, "delegate").text, /^Unknown agent "Scout 2"\. Available: Researcher\.$/);
	assert.match(await client.answer(own, "/delegate Researcher: from Atlas's copy"), /You said: "from Atlas's copy"/);
	// The template Atlas, outside any project, still hands work to the templates it names.
	assert.match(await client.answer(atlas, "/delegate Scout: with the preview on"), /You said: "with the preview on"/);
	const fromTemplate = client.events.library.conversations.filter((row: any) => row.parent === atlas).map((row: any) => row.agentId);
	assert.deepEqual([...new Set(fromTemplate)], ["scout"]);
	step("delegate names only the project's agents: all of them from the orchestrator's conversation, its delegates from another");

	// With startAgents off, a start asks the person first, as an approval that offers Allow Once and Deny only.
	await client.call("projects.set", { id: made.id, settings: { withoutAsking: { startAgents: false } } });
	const asked = async (conversation: number, text: string) => {
		void client.call("submit", { id: conversation, text });
		return client.until("the switch's approval", () => client.events.inbox?.items?.find((item: any) => item.conversationId === conversation && item.projectSwitch === "startAgents"));
	};
	let item = await asked(own, "/delegate Researcher: may I");
	assert.equal(item.question, "Start a new sub-chat with Researcher.");
	await refused(client.call("inbox.decide", { id: item.id, decision: "always" }), /only be allowed once, or denied/);
	const subChats = () => client.events.library.conversations.filter((row: any) => row.parent === own).length;
	const count = subChats();
	await client.call("inbox.decide", { id: item.id, decision: "deny" });
	await client.until("denied", () => client.conversations.get(own)?.state?.busy === false && client.result(own, "delegate")?.text?.includes("declined"));
	assert.equal(subChats(), count);
	item = await asked(own, "/delegate Researcher: please");
	await client.call("inbox.decide", { id: item.id, decision: "once" });
	await client.until("allowed", () => client.conversations.get(own)?.state?.busy === false && client.result(own, "delegate")?.text?.includes('You said: "please"'));
	assert.equal(subChats(), count + 1);
	// Continuing a sub-chat is a start too.
	const continued = client.events.library.conversations.find((row: any) => row.parent === own).id as number;
	item = await asked(own, `/continue ${continued}: again`);
	assert.match(item.question, new RegExp(`^Continue sub-chat ${continued}, “.*”, with Researcher\\.$`));
	await client.call("inbox.decide", { id: item.id, decision: "once" });
	await client.until("continued", () => client.conversations.get(own)?.state?.busy === false && client.result(own, "delegate")?.text?.includes('You said: "again"'));
	// The switch holds with the preview off: switching off removes no protection (section 2).
	await client.call("projects.setPreview", { on: false });
	item = await asked(own, "/delegate Researcher: with the preview off");
	await client.call("inbox.decide", { id: item.id, decision: "once" });
	await client.until("allowed off", () => client.conversations.get(own)?.state?.busy === false && client.result(own, "delegate")?.text?.includes("with the preview off"));
	// A template outside any project is never asked.
	assert.match(await client.answer(atlas, "/delegate Forge: no question"), /You said: "no question"/);
	await client.call("projects.setPreview", { on: true });
	await client.call("projects.set", { id: made.id, settings: { withoutAsking: { startAgents: true } } });
	step("with startAgents off, delegate asks before each start, new or continued, with the preview on or off");

	// ---- An archived project

	await client.call("projects.archive", { id: made.id });
	await client.until("archived", () => client.project(made.id).archivedAt !== undefined);
	await refused(client.call("projects.addAgent", { projectId: made.id, template: "forge" }), PROJECT_ARCHIVED);
	assert.equal((await client.call("agents.updateFromTemplate", { id: scout, apply: false })).applied, false);
	await refused(client.call("agents.updateFromTemplate", { id: scout, apply: true }), PROJECT_ARCHIVED);
	await refused(client.call("agents.restore", { id: scout }), PROJECT_ARCHIVED);
	await client.call("projects.unarchive", { id: made.id });
	await client.until("restored", () => client.project(made.id).archivedAt === undefined);
	assert.deepEqual(await client.call("agents.restore", { id: scout }), {}, "an agent not removed: nothing to do");
	await refused(client.call("agents.restore", { id: "forge" }), "Unknown agent: forge");
	step("an archived project refuses new agents and changes, and Update from template only looks");

	// ---- What a conversation in no project is told, byte for byte

	const during = await client.told(atlas);
	assert.equal(during.full, before.full);
	await client.call("projects.setPreview", { on: false });
	const after = await client.told(atlas);
	assert.equal(after.full, before.full);
	assert.equal(after.history, before.history);
	assert.equal(client.listed(atlas).runsAs, "atlas");
	step("an agent that hands out work, in no project, is told the same prompt and tools, never on, on and off again");

	// ---- An engine stopped and started again

	const kept = client.events.agents.agents.filter((agent: any) => agent.projectId !== undefined);
	client.close();
	await stop(engine);
	engine = start();
	client = await Client.connect(engine, home);
	await client.until("agents after the restart", () => client.events.agents && client.events.library && client.events.memory);
	assert.deepEqual(client.events.agents.agents.filter((agent: any) => agent.projectId !== undefined), kept);
	assert.equal(client.events.memory.agents[scout].enabled, false);
	assert.equal(client.listed(fromOrchestrator.id).runsAs, scout);
	step("an engine stopped and started again keeps the project agents, their marks and their memory");
} finally {
	client.close();
	await stop(engine);
}
