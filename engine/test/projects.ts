// Projects (#456, docs/projects.md): the project itself and its requests. A real engine on a throwaway data folder,
// driven over its socket with the demo model, as an app would drive it.
//
// First what must not change: a new data folder's app is sent the empty `projects` event, and settings.json says
// `projects: { preview: true }` for the versions before #483 took the switch out; a conversation in no
// project is told exactly the same prompt and tool declarations, byte for byte, before any project and after all of
// them. Then each request, with what it refuses; the operations of 3.6, checking the library and the hub (the
// `projects` event); two apps connected at once; and an engine stopped and started again.

import assert from "node:assert/strict";
import { type ChildProcess, execFileSync, spawn } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { EngineClient, leaveOut, standInApp, stop } from "./patience.ts";
import { ORCHESTRATOR_INSTRUCTIONS, PROJECT_ARCHIVED } from "../src/projects.ts";

const home = mkdtempSync(join(tmpdir(), "pi2-proj-"));
const work = realpathSync(mkdtempSync(join(tmpdir(), "pi2-proj-work-")));
const main = join(import.meta.dirname, "..", "src", "main.ts");
const KEYCHAIN_SERVICE = `dev.pi2.credentials.test-projects-${process.pid}`;
process.env.PI2_DEMO_TOKENS_PER_SECOND ??= "100000";
process.env.PI2_LOGIN_SHELL ??= "off";
// This client answers approvals as the app does (#504).
process.env.PI2_APP_BUNDLE = standInApp();
const env = { ...process.env, PI2_HOME: home, PI2_KEYCHAIN_SERVICE: KEYCHAIN_SERVICE };

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

// Folders of projects: two with the same last part, to see a default name taken.
const alpha = join(work, "alpha");
const otherAlpha = join(work, "other", "alpha");
const beta = join(work, "beta");
const gamma = join(work, "gamma");
const delta = join(work, "delta");
for (const folder of [alpha, otherAlpha, beta, gamma, delta]) mkdirSync(folder, { recursive: true });
const aFile = join(work, "a-file.txt");
writeFileSync(aFile, "not a folder\n");

class Client extends EngineClient {
	/** The events' names, in the order they came. */
	order: string[] = [];
	override receive(message: any): void {
		if (typeof message.event === "string") this.order.push(message.event);
		super.receive(message);
	}
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
	/** The whole prompt and every tool declaration the model was sent, as text, and what each system message changed. */
	async told(id: number): Promise<{ full: string; history: string }> {
		const full = await this.answer(id, "/system full");
		assert.ok(full.startsWith("FULL\n"), full.slice(0, 200));
		// Something to compare: the prompt, its sections and the tools of an agent with full tools.
		const parsed = JSON.parse(full.slice(5));
		assert.ok(parsed.sections.length > 2 && parsed.tools.length > 4, full.slice(0, 400));
		return { full, history: await this.answer(id, "/system history") };
	}
	get projects(): any[] {
		return this.events.projects?.projects ?? [];
	}
	row(id: string): any {
		return this.projects.find((project) => project.id === id);
	}
	agent(id: string): any {
		return this.events.agents?.agents?.find((agent: any) => agent.id === id);
	}
	/** A conversation in the old sidebar: the `library` event's list, not the Archive. */
	listed(id: number): any {
		return this.events.library?.conversations?.find((conversation: any) => conversation.id === id);
	}
	archivedRow(id: number): any {
		return this.events.library?.archived?.find((conversation: any) => conversation.id === id);
	}
}

const refused = async (promise: Promise<unknown>, message: string | RegExp) => {
	await assert.rejects(promise, (error: Error) => (typeof message === "string" ? error.message === message : message.test(error.message)), String(message));
};

const start = () => spawn(process.execPath, [main], { env, stdio: ["ignore", "ignore", "inherit"] });
engine = start();
let client = await Client.connect(engine, home);
let second: Client | undefined;
try {
	await client.until("providers", () => client.events.providers);
	await client.until("agents", () => client.events.agents);

	// ---- A new data folder

	assert.deepEqual(client.events.projects, { event: "projects", projects: [], carryOver: null });
	// After today's events, each feature's greeting in the order of FEATURES, the projects' last (4.4).
	assert.ok(client.order.indexOf("projects") > client.order.indexOf("compactionSettings"), client.order.join(" "));
	assert.ok(client.order.indexOf("projects") > client.order.indexOf("memory"), client.order.join(" "));
	assert.deepEqual(await client.call("projects.list"), { projects: [], carryOver: null });
	// A dry run waits for the update's own run at the start (carryover.ts), which writes the switch for the versions before.
	assert.equal((await client.call("projects.carryOver", { dryRun: true })).plan, null);
	const settingsFile = () => (existsSync(join(home, "settings.json")) ? JSON.parse(readFileSync(join(home, "settings.json"), "utf8")) : {});
	assert.deepEqual(settingsFile().projects, { preview: true });
	assert.equal(existsSync(join(home, "backups")), false, "nothing to copy on a new data folder");
	await refused(client.call("projects.carryOver", {}), "Carrying over runs by itself when the engine starts. Only a dry run is taken: give dryRun: true.");
	step("a new data folder: the empty projects event, last of the greetings, and the switch written in settings.json");

	// A conversation made with a template goes into the project of its folder as it is made, here one with no folder
	// (#458, 9.9); deleting that project leaves it in no project for what it is told, which this test checks below.
	const plain = (await client.call("conversation.create", { agentId: "forge" })).id as number;
	const carriedIds = await leaveOut(client);
	assert.equal(carriedIds.length, 1);
	const carried = await client.until("the carried project deleted", () => client.projects.find((row: any) => row.id === carriedIds[0] && row.deletedAt !== undefined));
	assert.equal(carried.name, "No folder");
	await client.call("conversation.open", { id: plain });
	const before = await client.told(plain);
	assert.equal(before.history.split("\n").length, 2, before.history);
	step("a conversation made is carried into its folder's project; that project deleted, it is in none");

	// projects.create: from a folder, in one step, with its orchestrator and an empty conversation with it.
	const made = await client.call("projects.create", { folder: alpha });
	assert.match(made.id, /^p-[0-9a-f-]{36}$/);
	assert.equal(typeof made.conversation, "number");
	const a = await client.until("the project in the event", () => client.row(made.id));
	assert.equal(a.name, "alpha");
	assert.equal(a.folder, alpha);
	assert.equal(a.repository, null);
	assert.equal(a.conversation, made.conversation);
	assert.deepEqual(a.earlier, []);
	assert.deepEqual(a.settings, {
		wakeOnReports: false,
		withoutAsking: { startAgents: true, fileWork: true, closeWork: true, makeAgents: true, addRules: true, merge: false, release: false, passLimits: false },
		limits: { planShare: 90, dailySpend: null },
	});
	assert.equal(a.folderMissing, false);
	// What later issues fill in, as it is until they land: #459's rules, #466's last words.
	assert.deepEqual(a.ruleTokens, { orchestrator: 0, agents: 0 });
	assert.equal(a.lastWords, null);
	assert.equal(a.archivedAt, undefined);
	assert.equal(a.deletedAt, undefined);
	const orchestrator = await client.until("the orchestrator", () => client.agent(a.orchestratorId));
	assert.equal(orchestrator.projectId, made.id);
	assert.equal(orchestrator.role, "orchestrator");
	assert.equal(orchestrator.name, "Orchestrator");
	assert.equal(orchestrator.color, "violet");
	assert.equal(orchestrator.model, null);
	assert.equal(orchestrator.access, "ask");
	assert.equal(orchestrator.cwd, alpha);
	assert.equal(orchestrator.instructions, ORCHESTRATOR_INSTRUCTIONS);
	assert.deepEqual(orchestrator.toolsOn, ["compact"]);
	assert.equal(orchestrator.compactionTokens, 100_000);
	assert.equal(orchestrator.template, undefined);
	await client.until("its memory on", () => client.events.memory?.agents?.[a.orchestratorId]?.enabled === true);
	const orchestratorRow = await client.until("its conversation", () => client.listed(made.conversation));
	assert.equal(orchestratorRow.projectId, made.id);
	assert.equal(orchestratorRow.agentId, a.orchestratorId);
	assert.equal(client.listed(plain).projectId, carried.id);
	step("projects.create makes the project, its default orchestrator and an empty conversation in one step");

	await refused(client.call("projects.create", { folder: alpha }), "There is already a project for this folder: alpha");
	await refused(client.call("projects.create", { folder: aFile }), `Not a folder: ${aFile}`);
	await refused(client.call("projects.create", {}), "folder must be a folder's path, or null");
	await refused(client.call("projects.create", { folder: beta, name: "ALPHA" }), "There is already a project called ALPHA");
	await refused(client.call("projects.create", { folder: beta, name: "x".repeat(81) }), /80 characters at most/);
	await refused(client.call("projects.create", { folder: beta, template: "nobody" }), "Unknown agent: nobody");
	await refused(client.call("projects.create", { folder: beta, template: a.orchestratorId }), `Unknown agent: ${a.orchestratorId}`);
	const second2 = await client.call("projects.create", { folder: otherAlpha });
	const none = await client.call("projects.create", { folder: null });
	const none2 = await client.call("projects.create", { folder: null, name: "  Loose ends  " });
	const copied = await client.call("projects.create", { folder: beta, template: "forge" });
	// Beside the one carrying over made, deleted.
	await client.until("four more projects", () => client.projects.length === 6);
	assert.equal(client.row(second2.id).name, "alpha 2");
	assert.equal(client.row(none.id).name, "No folder");
	assert.equal(client.row(none.id).folder, null);
	assert.equal(client.row(none2.id).name, "Loose ends");
	// Every project's orchestrator may be called Orchestrator: names are unique within a project, and among templates.
	const noneOrchestrator = await client.until("a second Orchestrator", () => client.agent(client.row(none.id).orchestratorId));
	assert.equal(noneOrchestrator.name, "Orchestrator");
	assert.equal(noneOrchestrator.cwd, null);
	const copy = await client.until("the copy of Forge", () => client.agent(client.row(copied.id).orchestratorId));
	const forge = client.agent("forge");
	assert.equal(copy.name, forge.name);
	assert.equal(copy.instructions, forge.instructions);
	assert.equal(copy.access, forge.access);
	assert.equal(copy.cwd, beta);
	assert.equal(copy.role, "orchestrator");
	assert.equal(copy.projectId, copied.id);
	assert.equal(copy.template.id, "forge");
	assert.deepEqual(copy.delegates, []);
	step("create's default names, a folderless project, a copied template, and what it refuses");

	// A template may still be called Orchestrator, and agents.save keeps what marks a project agent.
	const template = await client.call("agents.save", { agent: { name: "Orchestrator", access: "read" } });
	assert.equal(template.id, "orchestrator");
	await client.call("agents.save", { agent: { ...orchestrator, delegates: ["scout"], projectId: undefined, role: undefined } });
	const saved = await client.until("the orchestrator saved", () => client.agent(a.orchestratorId)?.delegates?.includes("scout") && client.agent(a.orchestratorId));
	assert.equal(saved.projectId, made.id);
	assert.equal(saved.role, "orchestrator");
	await client.call("agents.delete", { id: "orchestrator" });
	await refused(client.call("agents.delete", { id: a.orchestratorId }), "Orchestrator is the project's orchestrator. Make another agent the orchestrator first.");
	step("names are unique among templates and within a project; agents.save keeps the marks; the orchestrator cannot be deleted");

	// A conversation started with a project agent is in its project, and so is a sub-chat of one.
	const other = (await client.call("conversation.create", { agentId: a.orchestratorId })).id as number;
	assert.equal((await client.until("its row", () => client.listed(other))).projectId, made.id);
	await client.call("conversation.open", { id: made.conversation });
	// The orchestrator's conversation hands work to the project's other agents, whatever its delegates say (#457, 3.3).
	await client.call("projects.addAgent", { projectId: made.id, template: "scout" });
	await client.answer(made.conversation, "/delegate Scout: say hello");
	const subChat = await client.until("the sub-chat", () => client.events.library.conversations.find((row: any) => row.parent === made.conversation));
	assert.equal(subChat.projectId, made.id);
	step("conversation.create with a project agent, and a sub-chat, are in the project");

	// projects.rename
	await refused(client.call("projects.rename", { id: made.id, name: "   " }), "Give the project a name");
	await refused(client.call("projects.rename", { id: made.id, name: "y".repeat(81) }), /80 characters at most/);
	await refused(client.call("projects.rename", { id: made.id, name: "no FOLDER" }), "There is already a project called no FOLDER");
	await refused(client.call("projects.rename", { id: "p-nothing", name: "Z" }), "Unknown project: p-nothing");
	assert.deepEqual(await client.call("projects.rename", { id: made.id, name: " The app " }), {});
	await client.until("renamed", () => client.row(made.id).name === "The app");
	assert.deepEqual(await client.call("projects.rename", { id: made.id, name: "the APP" }), {});
	await client.until("renamed again, in another case", () => client.row(made.id).name === "the APP");
	step("projects.rename, and what it refuses");

	// projects.set
	const changed = await client.call("projects.set", { id: made.id, settings: { withoutAsking: { merge: true }, limits: { planShare: 50 } } });
	assert.deepEqual(changed.settings, {
		wakeOnReports: false,
		withoutAsking: { startAgents: true, fileWork: true, closeWork: true, makeAgents: true, addRules: true, merge: true, release: false, passLimits: false },
		limits: { planShare: 50, dailySpend: null },
	});
	assert.deepEqual((await client.call("projects.set", { id: made.id, settings: { wakeOnReports: true, limits: { dailySpend: 2.5 } } })).settings.limits, { planShare: 50, dailySpend: 2.5 });
	for (const [settings, message] of [
		[{ limits: { planShare: 0 } }, "planShare must be a whole number from 1 to 100, or null"],
		[{ limits: { planShare: 50.5 } }, "planShare must be a whole number from 1 to 100, or null"],
		[{ limits: { dailySpend: -1 } }, "dailySpend must be an amount above zero, or null"],
		[{ limits: { other: 1 } }, "Unknown limit: other"],
		[{ withoutAsking: { everything: true } }, "Unknown switch: everything"],
		[{ withoutAsking: { merge: "yes" } }, "merge must be true or false"],
		[{ wakeOnReports: 1 }, "wakeOnReports must be true or false"],
		[{ colour: "red" }, "Unknown setting: colour"],
		["all", "settings must be an object"],
	] as const) {
		await refused(client.call("projects.set", { id: made.id, settings }), message);
	}
	// Nothing refused changed anything.
	assert.deepEqual((await client.call("projects.set", { id: made.id })).settings.limits, { planShare: 50, dailySpend: 2.5 });
	await refused(client.call("projects.set", { id: made.id, folder: beta }), `There is already a project for this folder: ${client.row(copied.id).name}`);
	await client.call("projects.set", { id: made.id, folder: gamma });
	await client.until("the folder moved", () => client.row(made.id).folder === gamma);
	// Its agents' new conversations start there; the conversations already made stay where they are.
	await client.until("its orchestrator's folder", () => client.agent(a.orchestratorId).cwd === gamma);
	assert.equal(client.agent("forge").cwd, forge.cwd);
	await client.call("projects.set", { id: made.id, folder: alpha });
	await client.until("back in alpha", () => client.agent(a.orchestratorId).cwd === alpha);
	step("projects.set changes the settings part by part, each checked, and the folder with its agents'");

	// ---- Archiving and deleting (3.6)

	/** The library and the hub after each: conversations stay where they were, always. */
	const offAndOn = async (label: string, check: () => void) => {
		check();
		step(label);
	};
	const inSidebar = (...ids: number[]) => {
		for (const id of ids) assert.ok(client.listed(id) !== undefined, `conversation ${id} in the library`);
	};

	// Refused while a conversation of the project waits on the person: the orchestrator asks to run a command.
	void client.call("submit", { id: other, text: "/bash echo waiting" });
	await client.call("conversation.open", { id: other });
	const approval = await client.until("an approval", () => client.events.inbox?.items?.find((item: any) => item.conversationId === other));
	const run = await client.until("its run in Activity", () => client.events.activity?.runs?.find((row: any) => row.conversationId === other));
	assert.equal(run.projectId, made.id);
	await refused(client.call("projects.archive", { id: made.id }), "Stop the project's agents first.");
	await refused(client.call("projects.delete", { id: made.id }), "Stop the project's agents first.");
	await client.call("inbox.decide", { id: approval.id, decision: "deny" });
	await client.until("idle again", () => client.conversations.get(other)?.state?.busy === false && !client.events.activity?.runs?.some((row: any) => row.conversationId === other));
	step("archiving and deleting are refused while a conversation of the project works or waits; activity has projectId");

	await client.call("projects.archive", { id: made.id });
	const archivedAt = (await client.until("archived", () => client.row(made.id).archivedAt !== undefined && client.row(made.id))).archivedAt;
	await offAndOn("archive a project", () => {
		inSidebar(made.conversation, other);
		assert.equal(client.row(made.id).archivedAt, archivedAt);
	});
	await refused(client.call("submit", { id: other, text: "hello" }), PROJECT_ARCHIVED);
	await refused(client.call("continue", { id: other }), PROJECT_ARCHIVED);
	await refused(client.call("conversation.create", { agentId: a.orchestratorId }), PROJECT_ARCHIVED);
	await refused(client.call("projects.rename", { id: made.id, name: "Renamed" }), PROJECT_ARCHIVED);
	await refused(client.call("projects.set", { id: made.id, settings: {} }), PROJECT_ARCHIVED);
	await refused(client.call("projects.create", { folder: alpha }), "There is already a project for this folder: the APP; restore it instead");
	step("an archived project refuses messages and starts");

	await client.call("projects.unarchive", { id: made.id });
	await client.until("restored", () => client.row(made.id).archivedAt === undefined);
	await offAndOn("restore a project", () => {
		inSidebar(made.conversation, other);
		assert.equal(client.row(made.id).archivedAt, undefined);
	});
	assert.match(await client.answer(other, "back again"), /^You said: "back again"/);

	// The person archives one conversation of the project: the project is unchanged, and keeps pointing at it.
	await client.call("conversation.archive", { id: made.conversation });
	await client.until("the conversation archived", () => client.archivedRow(made.conversation));
	await offAndOn("archive the orchestrator's conversation", () => {
		assert.equal(client.listed(made.conversation), undefined);
		assert.equal(client.archivedRow(made.conversation).projectId, made.id);
		assert.equal(client.row(made.id).conversation, made.conversation);
		assert.equal(client.row(made.id).archivedAt, undefined);
	});
	await client.call("conversation.unarchive", { id: made.conversation });
	await client.until("the conversation restored", () => client.listed(made.conversation));
	await offAndOn("restore the orchestrator's conversation", () => {
		inSidebar(made.conversation);
		assert.equal(client.row(made.id).conversation, made.conversation);
	});

	// The person deletes the orchestrator's conversation: the project has none until the next message makes one (#466).
	await client.call("conversation.delete", { id: none2.conversation });
	await client.until("its conversation gone from the project", () => client.row(none2.id).conversation === null);
	await offAndOn("delete the orchestrator's conversation", () => {
		assert.equal(client.listed(none2.conversation), undefined);
		assert.equal(client.row(none2.id).conversation, null);
	});

	// Deleting a project: its conversations are where they were, and its folder and name are free.
	await client.call("projects.delete", { id: made.id });
	await client.until("deleted", () => client.row(made.id).deletedAt !== undefined);
	await offAndOn("delete a project", () => {
		inSidebar(made.conversation, other);
		assert.equal(client.listed(other).projectId, made.id);
		assert.notEqual(client.row(made.id).deletedAt, undefined);
	});
	for (const method of ["projects.rename", "projects.set", "projects.archive", "projects.unarchive", "projects.delete"]) {
		await refused(client.call(method, { id: made.id, name: "Again" }), `Unknown project: ${made.id}`);
	}
	// A deleted project's conversations are in no project for what they are told.
	assert.match(await client.answer(other, "after the project went"), /^You said: "after the project went"/);
	const again = await client.call("projects.create", { folder: alpha, name: "the app" });
	await client.until("a new project for the folder", () => client.row(again.id)?.folder === alpha);
	step("a deleted project frees its folder and name, and refuses every request");

	// ---- Two apps at once

	second = await Client.connect(engine, home);
	await second.until("the second app's projects", () => second!.events.projects);
	assert.deepEqual(second.events.projects, client.events.projects);
	await second.call("projects.rename", { id: copied.id, name: "Forge's project" });
	await client.until("the first app told", () => client.row(copied.id).name === "Forge's project");
	await second.until("the second app told", () => second!.events.projects.projects.find((row: any) => row.id === copied.id)?.name === "Forge's project");
	assert.deepEqual(second.events.projects, client.events.projects);
	step("two apps connected at once are both told of every change, whichever made it");

	// ---- What a conversation in no project is told, byte for byte

	const after = await client.told(plain);
	assert.equal(after.full, before.full);
	// Nothing was sent again: one system message, the first.
	assert.equal(after.history, before.history);
	// A conversation made goes into its folder's project as it is made (#458, docs/projects.md 9.9): one with no folder
	// into the one carrying over makes for no folder, never one the person made with none.
	const later = (await client.call("conversation.create", { agentId: "forge" })).id as number;
	const laterRow = await client.until("its row", () => client.listed(later)?.projectId !== null && client.listed(later));
	const laterProject = await client.until("its project", () => client.row(laterRow.projectId));
	assert.equal(laterProject.folder, null);
	assert.notEqual(laterProject.carriedAt, undefined);
	assert.ok(![none.id, none2.id].includes(laterProject.id));
	// It runs as the copy of Forge there. Told something else, the copy would show in what the conversation is told; its
	// project deleted, it is in no project (3.6), and is told nothing of it.
	const laterCopy = client.agent(laterRow.runsAs);
	assert.equal(laterCopy.template.id, "forge");
	await client.call("agents.save", { agent: { ...laterCopy, instructions: "Not what Forge is told." } });
	await client.until("the copy changed", () => client.agent(laterCopy.id).instructions === "Not what Forge is told.");
	await client.call("projects.delete", { id: laterProject.id });
	await client.until("deleted", () => client.row(laterProject.id).deletedAt !== undefined);
	await client.call("conversation.open", { id: later });
	const laterTold = await client.told(later);
	assert.doesNotMatch(laterTold.full, /Not what Forge is told/);
	step("a conversation in no project is told the same prompt and tools, byte for byte, before any project and after all of them");

	// ---- Every project, in the list as in the event

	const listed = await client.call("projects.list");
	assert.equal(listed.projects.length, 8);
	assert.deepEqual({ event: "projects", ...listed }, client.events.projects);
	step("projects.list answers what the event holds");

	// ---- An engine stopped and started again

	const kept = client.events.projects;
	const keptAgents = client.events.agents.agents.filter((agent: any) => agent.projectId !== undefined);
	second.close();
	second = undefined;
	client.close();
	await stop(engine);
	engine = start();
	client = await Client.connect(engine, home);
	await client.until("agents after the restart", () => client.events.agents && client.events.library && client.events.projects);
	assert.deepEqual(client.events.projects, kept);
	assert.deepEqual(client.events.agents.agents.filter((agent: any) => agent.projectId !== undefined), keptAgents);
	assert.equal(client.listed(other).projectId, made.id);
	assert.equal(client.listed(again.conversation).projectId, again.id);
	await client.until("memory after the restart", () => client.events.memory?.agents?.[client.row(again.id).orchestratorId]?.enabled === true);
	assert.deepEqual(settingsFile().projects, { preview: true });
	step("an engine stopped and started again keeps the projects, their agents and conversations");
} finally {
	second?.close();
	client.close();
	await stop(engine);
}
