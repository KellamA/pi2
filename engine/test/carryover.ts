// Carrying over (#458, docs/projects.md section 9), with a real engine on a throwaway data folder and Keychain service,
// driven over its socket as an app would drive it, on a library built here to the shape of a real one: hundreds of
// conversations in a repository, its subfolder, a worktree pi² made of it, a second repository, a plain folder and no
// folder; sub-chats; archived and deleted ones; chats; an agent deleted since; two agents sharing a folder; an agent's
// notes, written by it and by the person; a variable with a value; Allow everything.
//
// The report changes nothing, with the preview off. A plan gone stale is refused, with the new report as the refusal's
// data. A run stopped between its commits and the copying of the variables' values (the engine killed there) finishes
// that copying at the next start. The run did what the report said and nothing else; a second run writes nothing; with
// the preview off the old lists (the `library`, `agents` and `memory` events) are exactly as before the run, field by
// field, but for the fields the old screens do not read and the agents they leave out. Then conversations made later.
// carryplan.ts checks the plan alone on a larger library, with sub-chats several deep.

import assert from "node:assert/strict";
import { type ChildProcess, execFileSync, spawn } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { PLAN_CHANGED } from "../src/carryover.ts";
import { KeychainObjects } from "../src/credentials.ts";
import { EngineClient, standInApp, stop } from "./patience.ts";

// Commits made here use a fixed identity and none of the person's own git settings.
process.env.GIT_CONFIG_GLOBAL = "/dev/null";
process.env.GIT_CONFIG_NOSYSTEM = "1";
Object.assign(process.env, { GIT_AUTHOR_NAME: "Test", GIT_AUTHOR_EMAIL: "test@example.invalid", GIT_COMMITTER_NAME: "Test", GIT_COMMITTER_EMAIL: "test@example.invalid" });
process.env.PI2_DEMO_TOKENS_PER_SECOND ??= "100000";
process.env.PI2_LOGIN_SHELL ??= "off";
// Allow everything is turned on only from the app (#504): a stand-in takes this test's connections for it.
process.env.PI2_APP_BUNDLE = standInApp();

const home = mkdtempSync(join(tmpdir(), "pi2-carry-"));
const work = realpathSync(mkdtempSync(join(tmpdir(), "pi2-carry-work-")));
const main = join(import.meta.dirname, "..", "src", "main.ts");
const KEYCHAIN_SERVICE = `dev.pi2.credentials.test-carryover-${process.pid}`;
const gate = join(work, "secrets-gate");

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

// ---- Folders: a real repository (pi² makes a worktree of it), a second one, a plain folder, one whose conversations
// are all archived, and one for a conversation made later.

const git = (cwd: string, ...args: string[]) => execFileSync("git", args, { cwd, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();
const repo = join(work, "repo");
const sub = join(repo, "engine");
mkdirSync(sub, { recursive: true });
git(repo, "init", "-q", "-b", "main");
writeFileSync(join(repo, "README.md"), "hello\n");
writeFileSync(join(sub, "main.ts"), "// engine\n");
git(repo, "add", ".");
git(repo, "commit", "-q", "-m", "first");
const other = join(work, "other");
mkdirSync(join(other, ".git"), { recursive: true });
const plain = join(work, "plain");
const old = join(work, "old");
const fresh = join(work, "fresh");
for (const folder of [plain, old, fresh]) mkdirSync(folder);

class Client extends EngineClient {
	/** How many of each event about a stored document came: a run that writes nothing sends none of them. */
	counts: Record<string, number> = { library: 0, agents: 0, memory: 0, projects: 0 };
	override receive(message: any): void {
		if (typeof message.event === "string" && message.event in this.counts) this.counts[message.event]! += 1;
		super.receive(message);
	}
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
	get projects(): any[] {
		return this.events.projects?.projects ?? [];
	}
	agent(id: string): any {
		return this.events.agents?.agents?.find((agent: any) => agent.id === id);
	}
	row(id: number): any {
		return this.events.library?.conversations?.find((row: any) => row.id === id) ?? this.events.library?.archived?.find((row: any) => row.id === id);
	}
}

const env = (extra: Record<string, string> = {}) => ({ ...process.env, PI2_HOME: home, PI2_KEYCHAIN_SERVICE: KEYCHAIN_SERVICE, ...extra });
const start = (extra: Record<string, string> = {}) => spawn(process.execPath, [main], { env: env(extra), stdio: ["ignore", "ignore", "inherit"] });
const refusal = async (promise: Promise<unknown>): Promise<any> => {
	try {
		await promise;
	} catch (error) {
		return error;
	}
	assert.fail("not refused");
};

// The first engine holds the Keychain step at the gate, so that it can be killed there, as by a crash.
engine = start({ PI2_CARRY_SECRETS_GATE: gate });
let client = await Client.connect(engine, home);
try {
	await client.until("agents", () => client.events.agents && client.events.library && client.events.memory && client.events.projects);

	// ---- A library to the shape of a real one, made with the preview never on

	/** Where each conversation the test made should end up: its key, and whether it is carried at all. */
	const made = new Map<number, { key: string; archived: boolean; carried: boolean; subChat: boolean; agentId: string }>();
	const builder = (await client.call("agents.save", { agent: { name: "Builder", access: "ask", cwd: repo, instructions: "Build it." } })).id as string;
	const temp = (await client.call("agents.save", { agent: { name: "Temp", access: "read" } })).id as string;
	await client.call("variables.set", { agentId: "forge", name: "GH_TOKEN", value: "token-458" });
	await client.call("agents.allowEverything", { id: builder, on: true });
	await client.call("memory.setEnabled", { agentId: "atlas", enabled: true });
	await client.call("memory.add", { agentId: "atlas", text: "The person prefers short answers." });
	await client.call("memory.setEnabled", { agentId: temp, enabled: true });
	await client.call("memory.add", { agentId: temp, text: "A note of an agent deleted since." });
	await client.until("memory", () => client.events.memory.agents[temp]?.notes?.length === 1);

	const conversation = async (agentId: string, folder: string | null): Promise<number> => {
		const id = (await client.call("conversation.create", { agentId })).id as number;
		await client.call("conversation.configure", { id, cwd: folder });
		made.set(id, { key: folder === null ? "none" : folder === sub ? repo : folder, archived: false, carried: true, subChat: false, agentId });
		return id;
	};
	const agentsInTurn = ["atlas", "forge", "scout", builder];
	const foldersInTurn = [repo, sub, other, plain, null];
	for (let n = 0; n < 240; n++) {
		const id = await conversation(agentsInTurn[n % 4]!, foldersInTurn[n % 5]!);
		if (n % 9 === 4) {
			await client.call("conversation.archive", { id });
			made.get(id)!.archived = true;
		} else if (n % 13 === 6) {
			await client.call("conversation.delete", { id });
			made.get(id)!.carried = false;
		}
	}
	// Agents that hand out work, with sub-chats: the most recent in the repository becomes its orchestrator's (9.6).
	const handsOut = async (folder: string, task: string): Promise<number> => {
		const id = await conversation("atlas", folder);
		await client.call("conversation.open", { id });
		assert.match(await client.answer(id, `/delegate Scout: ${task}`), /You said/);
		const child = await client.until("its sub-chat", () => client.events.library.conversations.find((row: any) => row.parent === id));
		made.set(child.id, { ...made.get(id)!, subChat: true, agentId: "scout" });
		return id;
	};
	const firstInRepo = await handsOut(repo, "look around");
	// Atlas keeps a note of its own there: carried to the repository's project alone.
	assert.match(await client.answer(firstInRepo, '/tool remember {"note":"The release branch is cut on Fridays."}'), /Calling that tool|Noted/);
	await client.until("atlas's note", () => client.events.memory.agents.atlas.notes.length === 2);
	const inOther = await handsOut(other, "and here");
	const goneWithItsSubChat = await handsOut(other, "deleted soon");
	await client.call("conversation.delete", { id: goneWithItsSubChat });
	for (const [id, entry] of made) if (id === goneWithItsSubChat || (entry.subChat && entry.key === other && id > goneWithItsSubChat)) entry.carried = false;
	const orchestratorInRepo = await handsOut(sub, "the latest");
	// A worktree pi² made of the repository: grouped with it, by its record.
	const inWorktree = await conversation(builder, repo);
	const worktree = await client.call("worktree.create", { id: inWorktree });
	assert.ok(!worktree.path.startsWith(repo), worktree.path);
	// An agent deleted since: its conversation is carried, and runs as it does today; its note is left.
	const orphan = await conversation(temp, plain);
	await client.call("agents.delete", { id: temp });
	// A folder whose conversations are all archived: its project is made archived.
	for (const id of [await conversation("scout", old), await conversation("scout", old)]) {
		await client.call("conversation.archive", { id });
		made.get(id)!.archived = true;
	}
	// Chats, which carrying over leaves out.
	for (let n = 0; n < 2; n++) await client.call("conversation.create", { chat: true });
	await client.until("the library", () => [...made.keys()].every((id) => made.get(id)!.carried === false || client.row(id) !== undefined));
	const deleted = [...made.values()].filter((entry) => !entry.carried).length;
	step(`a library of ${made.size} conversations, with sub-chats, archived and deleted ones, chats, a worktree and an agent deleted since`);

	// ---- The report, with the preview off: it changes nothing

	const before = {
		library: structuredClone(client.events.library),
		agents: structuredClone(client.events.agents),
		memory: structuredClone(client.events.memory),
		projects: structuredClone(client.events.projects),
	};
	const counted = { ...client.counts };
	const report = await client.call("projects.carryOver", { dryRun: true });
	assert.match(report.plan, /^[0-9a-f]{32}$/);
	assert.deepEqual(
		report.projects.map((entry: any) => entry.key),
		[repo, other, plain, old, "none"].sort(),
	);
	for (const entry of report.projects) {
		const here = [...made.values()].filter((one) => one.carried && one.key === entry.key);
		assert.equal(entry.conversations, here.filter((one) => !one.subChat && !one.archived).length, `${entry.key}: conversations`);
		assert.equal(entry.archivedConversations, here.filter((one) => !one.subChat && one.archived).length, `${entry.key}: archived`);
		assert.equal(entry.subChats, here.filter((one) => one.subChat).length, `${entry.key}: sub-chats`);
		assert.equal(entry.existing, null);
		assert.equal(entry.adopted, false);
	}
	const entryOf = (r: any, key: string) => r.projects.find((entry: any) => entry.key === key);
	const repoEntry = entryOf(report, repo);
	assert.equal(repoEntry.name, "repo");
	assert.deepEqual(repoEntry.orchestrator, { conversation: orchestratorInRepo, title: client.row(orchestratorInRepo).title, template: "atlas" });
	assert.deepEqual(entryOf(report, other).orchestrator, { conversation: inOther, title: client.row(inOther).title, template: "atlas" });
	assert.deepEqual(entryOf(report, plain).orchestrator, { conversation: null, title: null, template: null });
	assert.equal(entryOf(report, old).archived, true);
	assert.equal(entryOf(report, "none").name, "No folder");
	// Two agents sharing the repository, and those Atlas hands work to: a copy of each. Temp, deleted, has none.
	assert.deepEqual(repoEntry.copies.map((copy: any) => copy.template), ["atlas", "forge", "scout", builder]);
	const copyIn = (entry: any, template: string) => entry.copies.find((copy: any) => copy.template === template);
	assert.deepEqual(copyIn(repoEntry, "forge").variables, ["GH_TOKEN"]);
	assert.equal(copyIn(repoEntry, builder).allowEverything, true);
	assert.equal(copyIn(repoEntry, builder).folder, null, "Builder's folder is the repository's");
	assert.equal(copyIn(entryOf(report, other), builder).folder, repo, "elsewhere, its new sub-chats would start in that project's folder");
	assert.equal(copyIn(entryOf(report, plain), temp), undefined);
	// Notes: the person's to every project with a copy of Atlas, Atlas's own to the repository's alone; Temp's left.
	for (const entry of report.projects) assert.equal(entry.notes, entry.key === repo ? 2 : copyIn(entry, "atlas") === undefined ? 0 : 1, entry.key);
	assert.deepEqual(report.leftOut, { chats: 2, deleted, notesLeft: 1 });
	assert.equal(report.already, 0);
	assert.deepEqual([report.ranAt, report.backup, report.secretsPending], [null, null, []]);
	// Nothing written: no event about anything stored, and the same report again.
	assert.deepEqual(await client.call("projects.carryOver", { dryRun: true }), report);
	await client.call("projects.list");
	assert.deepEqual(client.counts, counted);
	assert.deepEqual(client.events.projects, before.projects);
	assert.equal(existsSync(join(home, "backups")), false);
	step("the report, with the preview off: each project, its copies and orchestrator, what is left out; nothing written");

	// ---- Refused: no plan, and a plan gone stale, each with the new report as data

	let refused = await refusal(client.call("projects.setPreview", { on: true }));
	assert.equal(refused.message, PLAN_CHANGED);
	assert.deepEqual(refused.data, report);
	refused = await refusal(client.call("projects.carryOver", { plan: report.plan }));
	assert.equal(refused.message, "Projects are a preview. Turn them on in Settings › General first.");
	const late = await conversation("forge", plain);
	refused = await refusal(client.call("projects.setPreview", { on: true, plan: report.plan }));
	assert.equal(refused.message, PLAN_CHANGED);
	const current = refused.data;
	assert.notEqual(current.plan, report.plan);
	assert.equal(entryOf(current, plain).conversations, entryOf(report, plain).conversations + 1);
	assert.equal(client.events.projects.preview, false);
	assert.deepEqual(client.events.projects, before.projects);
	before.library = structuredClone(client.events.library);
	step("a run with no plan, or a plan gone stale, is refused with the new report, and turns nothing on");

	// ---- The run, stopped between its commits and the Keychain step, as by a crash

	writeFileSync(gate, "");
	const forgeCopies = current.projects.filter((entry: any) => copyIn(entry, "forge") !== undefined).length;
	assert.ok(forgeCopies >= 4, `${forgeCopies} copies of Forge`);
	const running = client.call("projects.setPreview", { on: true, plan: current.plan });
	running.catch(() => {});
	// The projects event comes once the last commit is stored, listing every copy whose values are still to be copied.
	await client.until("the commits", () => client.events.projects.carryOver?.secretsPending?.length === forgeCopies && client.projects.length === current.projects.length);
	await client.until("the Keychain step held", () => existsSync(`${gate}.started`));
	engine.kill("SIGKILL");
	await stop(engine);
	client.close();
	rmSync(gate, { force: true });
	engine = start();
	client = await Client.connect(engine, home);
	await client.until("after the restart", () => client.events.projects && client.events.agents && client.events.library && client.events.memory);
	await client.until("the values copied at start", () => client.events.projects.carryOver?.secretsPending?.length === 0);
	assert.equal(client.events.projects.preview, false, "the run was cut off before it turned the preview on");
	const keychain = new KeychainObjects(KEYCHAIN_SERVICE);
	const copies = client.events.agents.agents.filter((agent: any) => agent.projectId !== undefined);
	const forgeCopyIds = copies.filter((agent: any) => agent.template?.id === "forge").map((agent: any) => agent.id);
	assert.equal(forgeCopyIds.length, forgeCopies);
	for (const id of forgeCopyIds) {
		assert.deepEqual(await keychain.read(`variables/${id}`), { GH_TOKEN: "token-458" });
		await client.until("marked set", () => client.agent(id).variables?.[0]?.set === true);
	}
	const { carryOver } = client.events.projects;
	assert.equal(typeof carryOver.ranAt, "number");
	assert.ok(existsSync(join(carryOver.backup, "session.sqlite")), "the backup made before the run");
	step("a run cut off before the Keychain step: the next engine copies the values at start, and the copies have them");

	// ---- The run did what the report said, and nothing else

	const projectOf = (key: string) => client.projects.find((project: any) => (project.folder ?? "none") === key || (key === "none" && project.folder === null));
	for (const entry of current.projects) {
		const project = projectOf(entry.key);
		assert.ok(project !== undefined, entry.key);
		assert.equal(project.name, entry.name);
		assert.equal(project.carriedAt !== undefined, true);
		assert.equal(project.archivedAt !== undefined, entry.archived, entry.key);
		assert.deepEqual(project.settings.limits, { planShare: null, dailySpend: null }, "a carried project has no limits");
		assert.equal(project.settings.wakeOnReports, true);
		const theirs = copies.filter((agent: any) => agent.projectId === project.id);
		const madeCopies = theirs.filter((agent: any) => agent.template !== undefined);
		assert.deepEqual(madeCopies.map((agent: any) => agent.template.id).sort(), entry.copies.map((copy: any) => copy.template).sort(), entry.key);
		for (const copy of madeCopies) {
			const template = before.agents.agents.find((agent: any) => agent.id === copy.template.id);
			assert.equal(copy.name, template.name);
			assert.equal(copy.instructions, template.instructions);
			assert.equal(copy.access, template.access);
			assert.equal(copy.cwd, project.folder);
			assert.equal(copy.allowEverything, template.allowEverything);
			assert.deepEqual(copy.commandRules, template.commandRules ?? []);
			assert.equal(client.events.memory.agents[copy.id]?.enabled ?? false, before.memory.agents[template.id]?.enabled ?? false);
			// Each copy hands work to the project's copies of the templates its own named.
			assert.deepEqual(
				copy.delegates.map((id: string) => client.agent(id).template.id),
				template.delegates.filter((id: string) => theirs.some((agent: any) => agent.template?.id === id)),
			);
		}
		// The orchestrator: the copy of the chosen conversation's agent, or the default one with an empty conversation.
		const orchestrator = client.agent(project.orchestratorId);
		assert.equal(orchestrator.role, "orchestrator");
		if (entry.orchestrator.template === null) {
			assert.equal(orchestrator.template, undefined);
			assert.equal(orchestrator.name, "Orchestrator");
			assert.equal(theirs.length, madeCopies.length + 1);
			if (entry.archived) assert.equal(project.conversation, null, "none until the project is restored");
			else assert.equal(client.row(project.conversation).agentId, orchestrator.id);
		} else {
			assert.equal(orchestrator.template.id, entry.orchestrator.template);
			assert.equal(project.conversation, entry.orchestrator.conversation);
			assert.equal(theirs.length, madeCopies.length);
		}
		// Its notes, for the copy of Atlas alone.
		const notes = client.events.memory.projects[project.id]?.notes ?? [];
		assert.equal(notes.length, entry.notes);
		const atlasCopy = theirs.find((agent: any) => agent.template?.id === "atlas");
		for (const note of notes) {
			assert.equal(note.audience, atlasCopy.id);
			assert.equal(note.carriedFrom.agentId, "atlas");
			assert.equal(note.carriedFrom.agentName, "Atlas");
			assert.equal(note.conversation, null);
		}
	}
	assert.equal(client.projects.length, current.projects.length, "no project but the report's");
	// Every conversation carried is in its key's project, running as that project's copy of its agent; nothing else.
	for (const [id, entry] of made) {
		const row = client.row(id);
		if (!entry.carried) continue;
		const project = projectOf(entry.key);
		assert.equal(row.projectId, project.id, `conversation ${id}`);
	}
	for (const row of [...client.events.library.conversations, ...client.events.library.archived]) {
		if (row.chat) assert.equal(row.projectId, null, "a chat is in no project");
	}
	step("the run did what the report said: its projects, copies, orchestrators, notes and conversations, and nothing else");

	// ---- Preview off: the old lists exactly as before the run

	/** The old lists, as the old screens read them: without the fields they do not read, and without project agents. */
	// The run made one conversation of its own in each project it gave the default orchestrator (and that is not archived):
	// a conversation made in a project, listed in the old sidebar like any other (9.11). It is the only one added.
	const orchestrators = new Set(
		client.projects.filter((project: any) => client.agent(project.orchestratorId).template === undefined && project.conversation !== null).map((project: any) => project.conversation),
	);
	const beforeIds = new Set([...before.library.conversations, ...before.library.archived].map((row: any) => row.id));
	assert.deepEqual(
		new Set([...client.events.library.conversations, ...client.events.library.archived].map((row: any) => row.id).filter((id: number) => !beforeIds.has(id))),
		orchestrators,
	);
	const oldLists = (events: { library: any; agents: any; memory: any }) => {
		const template = (id: string) => events.agents.agents.some((agent: any) => agent.id === id && agent.projectId === undefined);
		const unmarked = (row: any) => {
			const { projectId: _, ...rest } = row;
			return rest;
		};
		const kept = (row: any) => !orchestrators.has(row.id);
		return {
			conversations: events.library.conversations.filter(kept).map(unmarked),
			archived: events.library.archived.filter(kept).map(unmarked),
			agents: events.agents.agents.filter((agent: any) => agent.projectId === undefined),
			memory: Object.fromEntries(Object.entries(events.memory.agents).filter(([id]) => template(id) || !events.agents.agents.some((agent: any) => agent.id === id))),
			chat: events.memory.chat,
		};
	};
	const withLate = oldLists(before);
	assert.deepEqual(oldLists({ library: client.events.library, agents: client.events.agents, memory: client.events.memory }), withLate);
	// And the agent each conversation runs as is its own, as before.
	for (const row of client.events.library.conversations) assert.equal(row.runsAs, row.agentId);
	step("with the preview off, the library, agents and memory events are as before the run, field by field");

	// ---- The preview on: nothing more to do; conversations run as their project's copies

	const on = await client.call("projects.setPreview", { on: true });
	assert.equal(on.preview, true);
	assert.equal(on.carryOver.plan, null);
	// Every top-level conversation is in a project now: those carried, and the orchestrators' the run made.
	assert.equal(on.carryOver.already, [...made.values()].filter((one) => one.carried && !one.subChat).length + orchestrators.size);
	await client.until("runs as the copies", () => client.row(late).runsAs !== "forge");
	assert.equal(client.agent(client.row(late).runsAs).template.id, "forge");
	assert.equal(client.row(orphan).runsAs, temp, "an agent deleted since: it runs as it does today");
	assert.equal(client.row(inWorktree).projectId, projectOf(repo).id, "a worktree pi² made is with its repository");
	step("turned on with nothing left to do; each conversation runs as its project's copy of its agent");

	// ---- A second run writes nothing

	const quiet = { ...client.counts };
	const ranAt = client.events.projects.carryOver.ranAt;
	const second = await client.call("projects.carryOver", { plan: null });
	assert.equal(second.plan, null);
	assert.deepEqual(second.projects, []);
	assert.equal(second.ranAt, ranAt);
	await client.call("projects.list");
	assert.deepEqual(client.counts, quiet, "no event: nothing was stored");
	assert.deepEqual(await client.call("projects.retrySecrets"), { secrets: [] });
	step("a second run has nothing to do, and writes nothing, ranAt included");

	// ---- Off and on again, and back

	await client.call("projects.setPreview", { on: false });
	await client.until("off", () => client.events.projects.preview === false);
	assert.deepEqual(oldLists({ library: client.events.library, agents: client.events.agents, memory: client.events.memory }), withLate);
	await client.call("projects.setPreview", { on: true });
	await client.until("on", () => client.events.projects.preview === true);
	step("switched off again, the old lists are as they were before projects; on again, as they were left");

	// ---- Conversations made later (9.9)

	// With a template whose folder has a project: into it, running as its copy there.
	const later = (await client.call("conversation.create", { agentId: "forge" })).id as number;
	const laterRow = await client.until("its row", () => client.row(later)?.projectId !== null && client.row(later));
	assert.equal(laterRow.projectId, projectOf("none").id);
	assert.equal(client.agent(laterRow.runsAs).template.id, "forge");
	const forgeInNone = [...made].find(([, one]) => one.key === "none" && one.agentId === "forge" && one.carried && !one.subChat)![0];
	assert.equal(laterRow.runsAs, client.row(forgeInNone).runsAs, "the copy already there, not another");
	// A folder no project has: a new project, with a copy of its agent, the default orchestrator and its conversation.
	const newcomer = (await client.call("agents.save", { agent: { name: "Newcomer", cwd: fresh, access: "read" } })).id as string;
	const inFresh = (await client.call("conversation.create", { agentId: newcomer })).id as number;
	const freshProject = await client.until("its project", () => client.projects.find((project: any) => project.folder === fresh));
	assert.equal(freshProject.name, "fresh");
	assert.equal((await client.until("its row", () => client.row(inFresh)?.projectId === freshProject.id && client.row(inFresh))).runsAs !== newcomer, true);
	assert.equal(client.agent(freshProject.orchestratorId).name, "Orchestrator");
	assert.equal(client.row(freshProject.conversation).agentId, freshProject.orchestratorId);
	// The archived project's folder: the project is restored, and its orchestrator's conversation made.
	const returning = (await client.call("agents.save", { agent: { name: "Returning", cwd: old, access: "read" } })).id as string;
	const inOld = (await client.call("conversation.create", { agentId: returning })).id as number;
	const oldProject = projectOf(old);
	const restored = await client.until("restored", () => client.projects.find((project: any) => project.id === oldProject.id && project.archivedAt === undefined && project.conversation !== null));
	assert.equal(client.row(restored.conversation).agentId, restored.orchestratorId);
	assert.equal((await client.until("its row", () => client.row(inOld)?.projectId === oldProject.id && client.row(inOld))).projectId, oldProject.id);
	// A chat stays out of every project.
	const chat = (await client.call("conversation.create", { chat: true })).id as number;
	assert.equal((await client.until("the chat", () => client.row(chat))).projectId, null);
	// None of it is anything a run would do again.
	assert.equal((await client.call("projects.carryOver", { dryRun: true })).plan, null);
	step("conversations made later go into their folder's project, a new one, or an archived one restored; chats stay out");

	// ---- An engine stopped and started again keeps it all

	const kept = { projects: client.events.projects, agents: client.events.agents.agents };
	client.close();
	await stop(engine);
	engine = start();
	client = await Client.connect(engine, home);
	await client.until("after the restart", () => client.events.projects && client.events.agents);
	assert.deepEqual(client.events.projects, kept.projects);
	assert.deepEqual(client.events.agents.agents, kept.agents);
	assert.equal(JSON.parse(readFileSync(join(home, "settings.json"), "utf8")).projects.preview, true);
	step("an engine stopped and started again keeps the projects, the copies and the record");
} finally {
	client.close();
	await stop(engine);
}
