// Schedules in projects (#656, docs/projects.md 3.13), with a real engine on a throwaway data folder and Keychain
// service, driven over its socket as an app would drive it. Schedules on templates made before the preview are given
// their project's copy by carrying over, beside their own agent, where that project and copy exist: one in a repository,
// one with no folder; one whose folder has no project stays on its template until its first run, carried as it is made,
// makes them. A run lands in the project as the copy; a schedule of a project's orchestrator runs as a conversation of
// its own; an edit keeps the copy until another agent is chosen; one carried to an archived project runs as its template
// and restores it; an agent's own schedule, carried, is still its own to list and cancel; one made since is carried at
// the next start; and with the preview off every schedule runs as its own agent, as before projects.

import assert from "node:assert/strict";
import { type ChildProcess, execFileSync, spawn } from "node:child_process";
import { closeSync, mkdirSync, mkdtempSync, openSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Grouping, scheduleCopies } from "../src/carryover.ts";
import { EngineClient, previewOn, standInApp, stop } from "./patience.ts";

process.env.GIT_CONFIG_GLOBAL = "/dev/null";
process.env.GIT_CONFIG_NOSYSTEM = "1";
Object.assign(process.env, { GIT_AUTHOR_NAME: "Test", GIT_AUTHOR_EMAIL: "test@example.invalid", GIT_COMMITTER_NAME: "Test", GIT_COMMITTER_EMAIL: "test@example.invalid" });
process.env.PI2_DEMO_TOKENS_PER_SECOND ??= "100000";
process.env.PI2_LOGIN_SHELL ??= "off";
// Schedules are the person's settings, taken only from the app's connection (#504): a stand-in takes this test's.
process.env.PI2_APP_BUNDLE = standInApp();

const home = mkdtempSync(join(tmpdir(), "pi2-psched-"));
const work = realpathSync(mkdtempSync(join(tmpdir(), "pi2-psched-work-")));
const main = join(import.meta.dirname, "..", "src", "main.ts");
const KEYCHAIN_SERVICE = `dev.pi2.credentials.test-projectschedules-${process.pid}`;

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

const git = (cwd: string, ...args: string[]) => execFileSync("git", args, { cwd, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();
const repo = join(work, "repo");
mkdirSync(repo, { recursive: true });
git(repo, "init", "-q", "-b", "main");
writeFileSync(join(repo, "README.md"), "hello\n");
git(repo, "add", ".");
git(repo, "commit", "-q", "-m", "first");
// A plain folder with no conversation in it, so no project, until a schedule's run makes one.
const lonelyFolder = join(work, "lonely");
mkdirSync(lonelyFolder);

// ---- The rule alone (3.13), without an engine: which copy a schedule on a template is given

{
	const at = 1_000;
	const agent = (id: string, extra: Record<string, unknown> = {}) => ({ id, name: id, cwd: null, createdAt: at, delegates: [], ...extra }) as any;
	const schedule = (id: string, agentId: string, extra: Record<string, unknown> = {}) =>
		({ id, title: id, agentId, prompt: "p", repeat: { kind: "daily", hour: 1, minute: 0 }, enabled: true, nextRunAt: null, lastRunAt: null, lastConversationId: null, pending: null, createdAt: at, ...extra }) as any;
	const agents = {
		forge: agent("forge", { cwd: repo }),
		loose: agent("loose"),
		gone: agent("gone", { cwd: repo }),
		lonely: agent("lonely", { cwd: lonelyFolder }),
		"forge-copy": agent("forge-copy", { cwd: repo, projectId: "p1", template: { id: "forge", copiedAt: at, templateUpdatedAt: at } }),
		"forge-later": agent("forge-later", { cwd: repo, projectId: "p1", createdAt: at + 1, template: { id: "forge", copiedAt: at, templateUpdatedAt: at } }),
		"loose-copy": agent("loose-copy", { projectId: "p2", template: { id: "loose", copiedAt: at, templateUpdatedAt: at } }),
		"gone-copy": agent("gone-copy", { cwd: repo, projectId: "p1", removedAt: at, template: { id: "gone", copiedAt: at, templateUpdatedAt: at } }),
	};
	const project = (id: string, folder: string | null, extra: Record<string, unknown> = {}) => ({ id, name: id, folder, createdAt: at, updatedAt: at, ...extra }) as any;
	const doc = {
		projects: { p1: project("p1", repo), p2: project("p2", null, { carriedAt: at }) },
		carry: { ranAt: at, backup: null, folders: { none: "p2" }, copies: { "p1 forge": "forge-copy" }, notes: {}, secrets: [] },
		news: {},
		nextNews: 1,
	} as any;
	const schedules = {
		a: schedule("a", "forge"),
		b: schedule("b", "loose"),
		c: schedule("c", "lonely"),
		d: schedule("d", "gone"),
		e: schedule("e", "forge", { holdReason: "held" }),
		f: schedule("f", "forge", { projectAgentId: "forge-later" }),
		g: schedule("g", "forge-copy"),
	};
	const grouping = new Grouping([], work);
	assert.deepEqual(scheduleCopies(schedules, agents, doc, grouping), [{ schedule: "a", copy: "forge-copy" }, { schedule: "b", copy: "loose-copy" }]);
	// Without the record, the oldest copy made from the template is adopted; a record of a copy deleted since gives none.
	assert.deepEqual(scheduleCopies({ a: schedules.a }, agents, { ...doc, carry: { ...doc.carry, copies: {} } }, grouping), [{ schedule: "a", copy: "forge-copy" }]);
	assert.deepEqual(scheduleCopies({ a: schedules.a }, agents, { ...doc, carry: { ...doc.carry, copies: { "p1 forge": "deleted-copy" } } }, grouping), []);
	// A deleted project is never the one; a project the person made with no folder is never taken for `none` (9.4).
	assert.deepEqual(scheduleCopies({ a: schedules.a }, agents, { ...doc, projects: { ...doc.projects, p1: { ...doc.projects.p1, deletedAt: at } } }, grouping), []);
	assert.deepEqual(scheduleCopies({ b: schedules.b }, agents, { ...doc, projects: { p2: project("p2", null) }, carry: { ...doc.carry, folders: {} } }, grouping), []);
	step("the rule alone: a template's copy in the project of its folder, recorded or adopted, never made; held, carried and removed left alone");
}

// ---- A real engine

class Client extends EngineClient {
	row(id: number): any {
		return this.events.library?.conversations?.find((row: any) => row.id === id) ?? this.events.library?.archived?.find((row: any) => row.id === id);
	}
	project(id: string): any {
		return this.events.projects?.projects?.find((project: any) => project.id === id);
	}
	schedule(id: string): any {
		return this.events.schedules?.schedules?.find((row: any) => row.id === id);
	}
	agents(): any[] {
		return this.events.agents?.agents ?? [];
	}
	/** The copy of `template` in `project`. */
	copyOf(template: string, project: string): any {
		return this.agents().find((agent) => agent.projectId === project && agent.template?.id === template);
	}
	/** The demo model's last answer to `/system …` in conversation `id`, once it is whole. */
	system(id: number): string | undefined {
		const text = this.conversations.get(id)?.items?.filter((item: any) => item.kind === "assistant").at(-1)?.text as string | undefined;
		return text?.startsWith("SYSTEM PROMPT") && text.includes("TOOLS: ") && this.row(id)?.busy === false ? text : undefined;
	}
	/** Run a schedule now, and wait for its run to have been answered: the conversation idle, with an answer. */
	async runNow(id: string): Promise<number> {
		const { conversationId } = await this.call("schedules.runNow", { id });
		assert.equal(typeof conversationId, "number");
		await this.until(`the run of ${id} answered`, () => this.row(conversationId) !== undefined && this.row(conversationId).busy === false && this.schedule(id)?.pending === null);
		return conversationId;
	}
}

const env = () => ({ ...process.env, PI2_HOME: home, PI2_KEYCHAIN_SERVICE: KEYCHAIN_SERVICE });
const start = () => {
	const log = openSync(join(home, "engine.log"), "a");
	try {
		return spawn(process.execPath, [main], { env: env(), stdio: ["ignore", "ignore", log] });
	} finally {
		closeSync(log);
	}
};
const daily = { kind: "daily", hour: 3, minute: 0 };

engine = start();
let client = await Client.connect(engine, home);
try {
	await client.until("the engine's greetings", () => client.events.agents && client.events.library && client.events.schedules);

	// ---- Before the preview: templates, their conversations and schedules

	const forge = (await client.call("agents.save", { agent: { name: "Builder", cwd: repo, schedule: { enabled: true } } })).id as string;
	const loose = (await client.call("agents.save", { agent: { name: "Loose" } })).id as string;
	const lonely = (await client.call("agents.save", { agent: { name: "Lonely", cwd: lonelyFolder } })).id as string;
	const inRepo = (await client.call("conversation.create", { agentId: forge })).id as number;
	await client.call("conversation.create", { agentId: loose });
	const nightly = (await client.call("schedules.save", { schedule: { title: "Nightly build", agentId: forge, prompt: "Build it.", repeat: daily } })).id as string;
	const tidy = (await client.call("schedules.save", { schedule: { title: "Tidy up", agentId: loose, prompt: "Tidy up.", repeat: daily } })).id as string;
	const alone = (await client.call("schedules.save", { schedule: { title: "Look around", agentId: lonely, prompt: "Look around.", repeat: daily } })).id as string;
	// One the agent set itself, approved by the person, in its conversation.
	await client.call("conversation.open", { id: inRepo });
	await client.call("submit", { id: inRepo, text: `/tool schedule_task ${JSON.stringify({ title: "Its own", prompt: "Check the build.", repeat: "daily", time: "06:00" })}` });
	const ask = await client.until("schedule_task asks", () => client.events.inbox?.items?.find((item: any) => item.conversationId === inRepo && item.tool === "schedule_task"));
	await client.call("inbox.decide", { id: ask.id, decision: "once" });
	const own = await client.until("its own schedule", () => client.events.schedules.schedules.find((row: any) => row.createdBy?.agentId === forge));
	await client.until("the conversation idle", () => client.row(inRepo)?.busy === false);
	const before = await client.runNow(nightly);
	assert.equal(client.row(before).agentId, forge);
	assert.equal(client.row(before).projectId ?? null, null);
	step("before the preview: schedules on templates, one set by the agent itself, run as before");

	// ---- The preview on: carrying over gives each its copy, where there is one

	await previewOn(client);
	const project = client.row(inRepo).projectId as string;
	assert.equal(typeof project, "string");
	const forgeCopy = client.copyOf(forge, project).id as string;
	const noFolder = client.events.projects.projects.find((row: any) => row.folder === null).id as string;
	const looseCopy = client.copyOf(loose, noFolder).id as string;
	await client.until("the schedules carried", () => client.schedule(nightly).projectAgentId === forgeCopy && client.schedule(tidy).projectAgentId === looseCopy);
	assert.equal(client.schedule(own.id).projectAgentId, forgeCopy);
	assert.equal(client.schedule(nightly).agentId, forge, "the schedule keeps its own agent, which the old way reads");
	assert.equal(client.schedule(alone).projectAgentId, undefined, "a folder with no project: it stays on its template");
	step("the preview on: a schedule in a repository and one with no folder given their project's copy; one with no project left");

	// A run lands in the project, as the copy.
	const carriedRun = await client.runNow(nightly);
	assert.equal(client.row(carriedRun).agentId, forgeCopy);
	assert.equal(client.row(carriedRun).projectId, project);
	assert.equal(client.row(carriedRun).runsAs, forgeCopy);
	assert.notEqual(client.project(project).conversation, carriedRun);
	// The one with no project: its run is carried as it is made, making the project and the copy; the schedule follows.
	const lonelyRun = await client.runNow(alone);
	const lonelyProject = await client.until("the run carried", () => client.row(lonelyRun).projectId);
	const lonelyCopy = await client.until("its copy", () => client.copyOf(lonely, lonelyProject)?.id);
	await client.until("the schedule carried after its run", () => client.schedule(alone).projectAgentId === lonelyCopy);
	const lonelySecond = await client.runNow(alone);
	assert.equal(client.row(lonelySecond).agentId, lonelyCopy);
	assert.equal(client.row(lonelySecond).projectId, lonelyProject);
	step("a carried schedule's run is a conversation of its project, as the copy; one with no project is carried after its first run");

	// A schedule of a project's agent: the orchestrator's run is a conversation of its own, not its current one.
	const orchestrator = client.project(project).orchestratorId as string;
	// Its prompt asks the demo model what it was told and offered on the run's first turn.
	const report = (await client.call("schedules.save", { schedule: { title: "Morning report", agentId: orchestrator, prompt: "/system project", repeat: daily } })).id as string;
	const orchestratorRun = await client.runNow(report);
	assert.equal(client.row(orchestratorRun).agentId, orchestrator);
	assert.equal(client.row(orchestratorRun).projectId, project);
	assert.notEqual(client.project(project).conversation, orchestratorRun);
	assert.ok(!client.project(project).earlier?.includes(orchestratorRun));
	await client.call("conversation.open", { id: orchestratorRun });
	const told = await client.until("the run's answer", () => client.system(orchestratorRun));
	const tools = told.slice(told.lastIndexOf("TOOLS: ") + 7).split(", ");
	for (const only of ["project_agents", "project_settings", "project_rules", "reports"]) assert.ok(!tools.includes(only), `the run is not offered ${only}: ${tools.join(", ")}`);
	assert.ok(tools.includes("work"), "it keeps the project's work list, as any conversation of the project");
	assert.match(told, /<<project>>\n<project>\nYou are Orchestrator, an agent of the pi² project “[^”]+”, in .+\. Orchestrator is its orchestrator\./);
	assert.ok(!told.includes("this is the project's one conversation with you"));
	// Its current conversation keeps every one of them.
	const current = (await client.call("projects.startFresh", { id: project })).conversation as number;
	await client.call("conversation.open", { id: current });
	await client.call("submit", { id: current, text: "/system project" });
	const orchestrated = await client.until("the orchestrator's answer", () => client.system(current));
	const ownTools = orchestrated.slice(orchestrated.lastIndexOf("TOOLS: ") + 7).split(", ");
	for (const only of ["project_agents", "project_settings", "project_rules", "reports"]) assert.ok(ownTools.includes(only), `the orchestrator's conversation is offered ${only}`);
	await client.until("idle", () => client.row(current)?.busy === false);
	step("a schedule of the orchestrator runs as a conversation of the project of its own, offered none of the tools of its current one");

	// Edits: the copy stays while the agent does; another agent chosen drops it.
	await client.call("schedules.save", { schedule: { id: nightly, title: "Nightly build, renamed", agentId: forge, prompt: "Build it.", repeat: daily } });
	await client.until("renamed", () => client.schedule(nightly).title === "Nightly build, renamed");
	assert.equal(client.schedule(nightly).projectAgentId, forgeCopy);
	await client.call("schedules.save", { schedule: { id: tidy, title: "Tidy up", agentId: orchestrator, prompt: "Tidy up.", repeat: daily } });
	await client.until("moved", () => client.schedule(tidy).agentId === orchestrator);
	assert.equal(client.schedule(tidy).projectAgentId, undefined);
	step("an edit keeps the copy while the agent stays, and drops it for another agent");

	// The agent's own schedule, carried, is still its own in a conversation that runs as the copy.
	const results = () => client.conversations.get(inRepo).items.filter((item: any) => item.kind === "tool");
	const count = results().length;
	await client.call("submit", { id: inRepo, text: "/tool list_schedules {}" });
	await client.until("listed", () => client.row(inRepo).busy === false && results().length === count + 1);
	assert.match(results().at(-1).text, new RegExp(`${own.id}: “Its own”.*set by you`));
	assert.match(results().at(-1).text, /Nightly build, renamed.*set by the person/);
	step("an agent's own schedule, carried, is listed as its own by the copy");

	// Archived: the copy's project archived, the carried schedule runs as its template, which restores the project.
	await client.call("projects.archive", { id: lonelyProject });
	await client.until("archived", () => client.project(lonelyProject)?.archivedAt !== undefined);
	const restoring = await client.runNow(alone);
	assert.equal(client.row(restoring).agentId, lonely);
	assert.equal(client.row(restoring).projectId, lonelyProject);
	assert.equal(client.row(restoring).runsAs, lonelyCopy);
	await client.until("the project restored", () => client.project(lonelyProject)?.archivedAt === undefined);
	// A schedule of a project's own agent waits while its project is archived.
	await client.call("projects.archive", { id: project });
	await client.until("archived", () => client.project(project)?.archivedAt !== undefined);
	await assert.rejects(client.call("schedules.runNow", { id: report }), /archived/);
	await client.call("projects.unarchive", { id: project });
	await client.until("restored", () => client.project(project)?.archivedAt === undefined);
	step("archived: a carried schedule's run restores its project; a project's own schedule waits");

	// One made since on a template is carried at the next start.
	const later = (await client.call("schedules.save", { schedule: { title: "Later", agentId: forge, prompt: "Later.", repeat: daily } })).id as string;
	await client.until("made", () => client.schedule(later) !== undefined);
	assert.equal(client.schedule(later).projectAgentId, undefined);
	client.socket.destroy();
	await stop(engine);
	engine = start();
	client = await Client.connect(engine, home);
	await client.until("the engine's greetings", () => client.events.schedules && client.events.library && client.events.projects);
	await client.until("carried at the start", () => client.schedule(later)?.projectAgentId === forgeCopy);
	step("a schedule made since on a template is carried at the next start");

	// ---- The preview off: every schedule runs as its own agent, as before

	await client.call("projects.setPreview", { on: false });
	const off = await client.runNow(nightly);
	assert.equal(client.row(off).agentId, forge);
	assert.equal(client.row(off).projectId ?? null, null);
	assert.equal(client.schedule(nightly).projectAgentId, forgeCopy, "nothing is undone");
	const offLonely = await client.runNow(alone);
	assert.equal(client.row(offLonely).agentId, lonely);
	assert.equal(client.row(offLonely).projectId ?? null, null);
	step("the preview off: carried schedules run as their own agent, in no project, as before");
} finally {
	client.socket.destroy();
	await stop(engine);
}
