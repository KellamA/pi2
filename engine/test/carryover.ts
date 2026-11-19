// Carrying over (#458, docs/projects.md section 9), with a real engine on a throwaway data folder and Keychain service,
// driven over its socket as an app would drive it, on a library built here to the shape of a real one: hundreds of
// conversations in a repository, its subfolder, a worktree pi² made of it, a second repository, a plain folder and no
// folder; sub-chats; archived and deleted ones; chats; an agent deleted since; two agents sharing a folder; an agent's
// notes, written by it and by the person; variables with values; Allow everything.
//
// The report changes nothing, with the preview off. A plan gone stale is refused, with the new report as the refusal's
// data. A run cut off between two projects' commits (the engine killed there) is finished by the next run, which doubles
// nothing; one stopped between its commits and the copying of the variables' values finishes that copying at the next
// start. The run did what the report said and nothing else; a second run writes nothing. With the preview off, a
// conversation of each kind is told exactly what it was told before the run, byte for byte, and again after its project's
// settings, rules, notes and copies were changed with the preview on; the old lists (the `library`, `agents` and `memory`
// events) are as before the run, field by field, but for the fields the old screens do not read and the project agents.
// Then what still holds with the preview off (a project's `startAgents`), conversations made later, a fork, and one left
// in no project carried at the next start. carryplan.ts checks the plan alone on a larger library.

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
const secretsGate = join(work, "secrets-gate");
const commitGate = join(work, "commit-gate");

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
// are all archived, and one for a conversation made later. The second repository's key sorts first, so a run cut off
// after its first commit has carried it alone.

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
const old = join(work, "zold");
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
	/** What conversation `id` is told: its prompt with every section and its tools (the demo model's `/system full`), and the system messages sent so far. */
	async told(id: number): Promise<{ full: string; history: string }> {
		await this.call("conversation.open", { id });
		const full = await this.answer(id, "/system full");
		assert.ok(full.startsWith("FULL\n"), full.slice(0, 200));
		return { full, history: await this.answer(id, "/system history") };
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

// The first engine holds a run before its second project's commit, so that it can be killed there, as by a crash.
engine = start({ PI2_CARRY_COMMIT_GATE: commitGate });
let client = await Client.connect(engine, home);
try {
	await client.until("agents", () => client.events.agents && client.events.library && client.events.memory && client.events.projects);

	// ---- A library to the shape of a real one, made with the preview never on

	/** Where each conversation the test made should end up: its key, and whether it is carried at all. */
	const made = new Map<number, { key: string; archived: boolean; carried: boolean; subChat: boolean; agentId: string }>();
	const builder = (await client.call("agents.save", { agent: { name: "Builder", access: "ask", cwd: repo, instructions: "Build it." } })).id as string;
	const temp = (await client.call("agents.save", { agent: { name: "Temp", access: "read" } })).id as string;
	await client.call("variables.set", { agentId: "forge", name: "GH_TOKEN", value: "token-458" });
	await client.call("variables.set", { agentId: "atlas", name: "ATLAS_KEY", value: "key-458" });
	await client.call("agents.allowEverything", { id: builder, on: true });
	await client.call("memory.setEnabled", { agentId: "atlas", enabled: true });
	const personNote = (await client.call("memory.add", { agentId: "atlas", text: "The person prefers short answers." })).id as string;
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
	const handsOut = async (folder: string, task: string): Promise<{ id: number; child: number }> => {
		const id = await conversation("atlas", folder);
		await client.call("conversation.open", { id });
		assert.match(await client.answer(id, `/delegate Scout: ${task}`), /You said/);
		const child = await client.until("its sub-chat", () => client.events.library.conversations.find((row: any) => row.parent === id));
		made.set(child.id, { ...made.get(id)!, subChat: true, agentId: "scout" });
		return { id, child: child.id };
	};
	const firstInRepo = (await handsOut(repo, "look around")).id;
	// Atlas keeps a note of its own there: carried to the repository's project alone.
	assert.match(await client.answer(firstInRepo, '/tool remember {"note":"The release branch is cut on Fridays."}'), /Calling that tool|Noted/);
	await client.until("atlas's note", () => client.events.memory.agents.atlas.notes.length === 2);
	const inOther = (await handsOut(other, "and here")).id;
	const goneWithItsSubChat = (await handsOut(other, "deleted soon")).id;
	await client.call("conversation.delete", { id: goneWithItsSubChat });
	for (const [id, entry] of made) if (id === goneWithItsSubChat || (entry.subChat && entry.key === other && id > goneWithItsSubChat)) entry.carried = false;
	const { id: orchestratorInRepo, child: subChatInRepo } = await handsOut(sub, "the latest");
	// A worktree pi² made of the repository: grouped with it, by its record.
	const inWorktree = await conversation(builder, repo);
	const worktree = await client.call("worktree.create", { id: inWorktree });
	assert.ok(!worktree.path.startsWith(repo), worktree.path);
	// An agent with notes and a variable, in a plain folder; an ordinary one there too.
	const withNotes = await conversation("atlas", plain);
	const ordinary = await conversation("scout", plain);
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

	// ---- What a conversation of each kind is told before anything is carried over: prompt and tools, byte for byte

	const kinds: Record<string, number> = {
		"an ordinary conversation": ordinary,
		"one chosen as its project's orchestrator's": orchestratorInRepo,
		"one in a worktree": inWorktree,
		"a sub-chat": subChatInRepo,
		"one of an agent with notes and a variable": withNotes,
		"one of an agent deleted since": orphan,
	};
	const toldBefore: Record<string, { full: string; history: string }> = {};
	for (const [kind, id] of Object.entries(kinds)) toldBefore[kind] = await client.told(id);
	assert.match(toldBefore["one of an agent with notes and a variable"]!.full, /The person prefers short answers/);
	/** What each is told now is what it was told before, byte for byte, and no system message was sent since. */
	const toldAsBefore = async (when: string) => {
		for (const [kind, id] of Object.entries(kinds)) {
			const now = await client.told(id);
			assert.equal(now.full, toldBefore[kind]!.full, `${kind}, ${when}`);
			assert.equal(now.history, toldBefore[kind]!.history, `${kind}, ${when}: nothing sent again`);
		}
	};
	step("what a conversation of each kind is told, recorded before the run");

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
		assert.deepEqual(entry.notices, []);
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
	assert.deepEqual(copyIn(repoEntry, "atlas").variables, ["ATLAS_KEY"]);
	assert.equal(copyIn(repoEntry, builder).allowEverything, true);
	assert.equal(copyIn(repoEntry, builder).folder, null, "Builder's folder is the repository's");
	assert.equal(copyIn(repoEntry, builder).worktreeOff, false);
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

	// ---- The run, cut off between its first two projects' commits, as by a crash

	assert.equal(current.projects[0].key, other);
	writeFileSync(commitGate, "");
	const cut = client.call("projects.setPreview", { on: true, plan: current.plan });
	cut.catch(() => {});
	await client.until("held before the second commit", () => existsSync(`${commitGate}.started`));
	engine.kill("SIGKILL");
	await stop(engine);
	client.close();
	rmSync(commitGate, { force: true });
	// The next engine holds the Keychain step instead, once the file is there.
	engine = start({ PI2_CARRY_SECRETS_GATE: secretsGate });
	client = await Client.connect(engine, home);
	await client.until("after the cut", () => client.events.projects && client.events.agents && client.events.library && client.events.memory);
	assert.equal(client.events.projects.preview, false);
	assert.deepEqual(
		client.projects.map((project: any) => project.folder),
		[other],
		"the first project's commit alone",
	);
	const otherProject = client.projects[0];
	assert.equal(client.events.memory.projects[otherProject.id].notes.length, 1);
	// The person changes the note of Atlas's that went there, before the run is finished.
	await client.call("memory.edit", { agentId: "atlas", id: personNote, text: "The person prefers short answers, in lists." });
	const finish = await client.call("projects.carryOver", { dryRun: true });
	assert.deepEqual(
		finish.projects.map((entry: any) => entry.key),
		current.projects.map((entry: any) => entry.key).filter((key: string) => key !== other),
		"the next plan finishes the run, and leaves the project already made alone",
	);
	step("a run cut off between two projects' commits: the first stays, whole, and the next plan does the rest");

	// ---- The rest of the run, stopped between its commits and the Keychain step, as by a crash

	// The first project's copies have their values by now: this engine copied them as it started.
	await client.until("the first project's values copied", () => client.events.projects.carryOver?.secretsPending?.length === 0);
	writeFileSync(secretsGate, "");
	const pendingNow = finish.projects.flatMap((entry: any) => entry.copies.filter((copy: any) => copy.variables.length > 0)).length;
	assert.ok(pendingNow >= 6, `${pendingNow} copies with values to copy`);
	const running = client.call("projects.setPreview", { on: true, plan: finish.plan });
	running.catch(() => {});
	// The projects event comes once the last commit is stored, listing every copy whose values are still to be copied.
	await client.until("the commits", () => client.events.projects.carryOver?.secretsPending?.length === pendingNow && client.projects.length === current.projects.length);
	await client.until("the Keychain step held", () => existsSync(`${secretsGate}.started`));
	engine.kill("SIGKILL");
	await stop(engine);
	client.close();
	rmSync(secretsGate, { force: true });
	engine = start();
	client = await Client.connect(engine, home);
	await client.until("after the restart", () => client.events.projects && client.events.agents && client.events.library && client.events.memory);
	await client.until("the values copied at start", () => client.events.projects.carryOver?.secretsPending?.length === 0);
	assert.equal(client.events.projects.preview, false, "the run was cut off before it turned the preview on");
	const keychain = new KeychainObjects(KEYCHAIN_SERVICE);
	const copies = client.events.agents.agents.filter((agent: any) => agent.projectId !== undefined);
	for (const [template, values] of [["forge", { GH_TOKEN: "token-458" }], ["atlas", { ATLAS_KEY: "key-458" }]] as const) {
		const ids = copies.filter((agent: any) => agent.template?.id === template).map((agent: any) => agent.id);
		assert.equal(ids.length, current.projects.filter((entry: any) => copyIn(entry, template) !== undefined).length);
		for (const id of ids) {
			assert.deepEqual(await keychain.read(`variables/${id}`), values);
			await client.until("marked set", () => client.agent(id).variables?.[0]?.set === true);
		}
	}
	const { carryOver } = client.events.projects;
	assert.equal(typeof carryOver.ranAt, "number");
	assert.ok(existsSync(join(carryOver.backup, "session.sqlite")), "the backup made before the run");
	assert.equal((await client.call("projects.carryOver", { dryRun: true })).plan, null, "nothing left to do: the record is whole");
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
		// The orchestrator: the copy of the chosen conversation's agent, or the default one, with no conversation until the
		// person opens it: no empty conversation is made for it.
		const orchestrator = client.agent(project.orchestratorId);
		assert.equal(orchestrator.role, "orchestrator");
		if (entry.orchestrator.template === null) {
			assert.equal(orchestrator.template, undefined);
			assert.equal(orchestrator.name, "Orchestrator");
			assert.equal(theirs.length, madeCopies.length + 1);
			assert.equal(project.conversation, null);
		} else {
			assert.equal(orchestrator.template.id, entry.orchestrator.template);
			assert.equal(project.conversation, entry.orchestrator.conversation);
			assert.equal(theirs.length, madeCopies.length);
		}
		// Its notes, for the copy of Atlas alone, each once: the note the person changed meanwhile is as it was where it went
		// before the cut, and as it is now everywhere else.
		const notes = client.events.memory.projects[project.id]?.notes ?? [];
		assert.equal(notes.length, entry.notes, entry.key);
		const atlasCopy = theirs.find((agent: any) => agent.template?.id === "atlas");
		for (const note of notes) {
			assert.equal(note.audience, atlasCopy.id);
			assert.equal(note.carriedFrom.agentId, "atlas");
			assert.equal(note.carriedFrom.agentName, "Atlas");
			assert.equal(note.conversation, null);
		}
		if (atlasCopy !== undefined) {
			const persons = notes.filter((note: any) => note.carriedFrom.id === personNote).map((note: any) => note.text);
			assert.deepEqual(persons, [entry.key === other ? "The person prefers short answers." : "The person prefers short answers, in lists."], entry.key);
		}
	}
	assert.equal(client.projects.length, current.projects.length, "no project but the report's");
	// Every conversation carried is in its key's project; nothing else.
	for (const [id, entry] of made) {
		const row = client.row(id);
		if (!entry.carried) continue;
		const project = projectOf(entry.key);
		assert.equal(row.projectId, project.id, `conversation ${id}`);
	}
	for (const row of [...client.events.library.conversations, ...client.events.library.archived]) {
		if (row.chat) assert.equal(row.projectId, null, "a chat is in no project");
	}
	// The person puts the note back as it was: what the agent is told of its own notes is as before again.
	await client.call("memory.edit", { agentId: "atlas", id: personNote, text: "The person prefers short answers." });
	await client.until("put back", () => client.events.memory.agents.atlas.notes.some((note: any) => note.text === "The person prefers short answers."));
	step("the run did what the report said: its projects, copies, orchestrators, notes and conversations, and nothing else");

	// ---- Preview off: the old lists, and what each kind of conversation is told, exactly as before the run

	const unmarkedLibrary = (library: any) => {
		// The fields the old screens do not read: the project (#456), and whether it is an orchestrator's (#466).
		const unmarked = (row: any) => {
			const { projectId: _, orchestrator: __, ...rest } = row;
			return rest;
		};
		return { conversations: library.conversations.map(unmarked), archived: library.archived.map(unmarked) };
	};
	/** The old lists, as the old screens read them: without the fields they do not read, and without project agents. */
	const oldLists = (events: { library: any; agents: any; memory: any }) => {
		const template = (id: string) => events.agents.agents.some((agent: any) => agent.id === id && agent.projectId === undefined);
		return {
			...unmarkedLibrary(events.library),
			agents: events.agents.agents.filter((agent: any) => agent.projectId === undefined),
			memory: Object.fromEntries(Object.entries(events.memory.agents).filter(([id]) => template(id) || !events.agents.agents.some((agent: any) => agent.id === id))),
			chat: events.memory.chat,
		};
	};
	const oldBefore = oldLists({ library: before.library, agents: before.agents, memory: before.memory });
	assert.deepEqual(oldLists({ library: client.events.library, agents: client.events.agents, memory: client.events.memory }), oldBefore);
	// No conversation was added: no empty one for any orchestrator.
	assert.equal(client.events.library.conversations.length + client.events.library.archived.length, before.library.conversations.length + before.library.archived.length);
	// And the agent each conversation runs as is its own, as before.
	for (const row of client.events.library.conversations) assert.equal(row.runsAs, row.agentId);
	await toldAsBefore("with the preview off after the run");
	step("with the preview off, the old lists are as they were, and each kind of conversation is told what it was before, byte for byte");

	// ---- The preview on: nothing more to do; conversations run as their project's copies

	const on = await client.call("projects.setPreview", { on: true });
	assert.equal(on.preview, true);
	assert.equal(on.carryOver.plan, null);
	// Every top-level conversation is in a project now.
	assert.equal(on.carryOver.already, [...made.values()].filter((one) => one.carried && !one.subChat).length);
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

	// ---- The carried projects changed with the preview on: with it off, nothing of it reaches those conversations

	const inPlain = projectOf(plain);
	const inRepo = projectOf(repo);
	for (const project of [inPlain, inRepo]) {
		await client.call("projects.set", { id: project.id, settings: { wakeOnReports: false, withoutAsking: { startAgents: false }, limits: { planShare: 50, dailySpend: 100 } } });
		await client.call("projects.rename", { id: project.id, name: `${project.name}, renamed` });
		await client.call("projects.rules.add", { projectId: project.id, text: "Write every answer in French.", binds: "everyone" });
		await client.call("memory.add", { projectId: project.id, text: "A note the whole project shares." });
	}
	const plainAtlas = copies.find((agent: any) => agent.projectId === inPlain.id && agent.template?.id === "atlas");
	await client.call("agents.save", { agent: { ...client.agent(plainAtlas.id), instructions: "You are the project's Atlas now." } });
	await client.until("the copy changed", () => client.agent(plainAtlas.id).instructions === "You are the project's Atlas now.");
	await client.call("projects.setPreview", { on: false });
	await client.until("off", () => client.events.projects.preview === false);
	await toldAsBefore("with the preview off, after its project was changed with the preview on");
	step("its project's settings, name, rules and notes, and its copy, changed with the preview on: with it off, each kind is told what it was before");

	// ---- What still holds with the preview off, and a sub-chat made then (9.11)

	// The repository's project's `startAgents`, turned off with the preview on, still asks before its agents start one.
	void client.call("submit", { id: firstInRepo, text: "/delegate Scout: with the preview off" });
	await client.call("conversation.open", { id: firstInRepo });
	const asked = await client.until("the switch asks", () => client.events.inbox?.items?.find((item: any) => item.conversationId === firstInRepo));
	assert.equal(asked.projectSwitch, "startAgents");
	await client.call("inbox.decide", { id: asked.id, decision: "once" });
	const madeOff = await client.until("its sub-chat", () => client.events.library.conversations.find((row: any) => row.parent === firstInRepo && !made.has(row.id)));
	await client.until("answered", () => client.conversations.get(firstInRepo)?.state?.busy === false);
	// It takes its parent's project, and no copy: with the preview on it runs as the template, not the project's Scout.
	assert.equal(madeOff.projectId, inRepo.id);
	assert.equal(madeOff.runsAs, "scout");
	await client.call("projects.setPreview", { on: true });
	await client.until("on", () => client.events.projects.preview === true);
	await client.until("still the template", () => client.row(madeOff.id)?.runsAs === "scout");
	step("with the preview off, a carried project's startAgents still asks; a sub-chat made then is in the project, running as its template");

	// ---- Off and on again, and back

	await client.call("projects.setPreview", { on: false });
	await client.until("off", () => client.events.projects.preview === false);
	const listsOff = oldLists({ library: client.events.library, agents: client.events.agents, memory: client.events.memory });
	assert.deepEqual(listsOff.agents, oldBefore.agents);
	assert.deepEqual(listsOff.memory, oldBefore.memory);
	await client.call("projects.setPreview", { on: true });
	await client.until("on", () => client.events.projects.preview === true);
	step("switched off again, the old agents and notes are as they were before projects; on again, as they were left");

	// ---- Conversations made later (9.9)

	// With a template whose folder has a project: into it, running as its copy there.
	const later = (await client.call("conversation.create", { agentId: "forge" })).id as number;
	const laterRow = await client.until("its row", () => client.row(later)?.projectId !== null && client.row(later));
	assert.equal(laterRow.projectId, projectOf("none").id);
	assert.equal(client.agent(laterRow.runsAs).template.id, "forge");
	const forgeInNone = [...made].find(([, one]) => one.key === "none" && one.agentId === "forge" && one.carried && !one.subChat)![0];
	assert.equal(laterRow.runsAs, client.row(forgeInNone).runsAs, "the copy already there, not another");
	// A template's start in a folder whose project has limits is checked against them, as one of that project's agents' is
	// (8.3): the plan's share, set above, has no reading to go by, which the start says.
	const planner = (await client.call("agents.save", { agent: { name: "Planner", cwd: plain, access: "read" } })).id as string;
	const checked = await client.call("conversation.create", { agentId: planner });
	assert.equal(checked.note, "Plan limits: no reading of this plan's windows yet.");
	assert.equal((await client.until("its row", () => client.row(checked.id)?.projectId === inPlain.id && client.row(checked.id))).projectId, inPlain.id);
	assert.equal((await client.call("conversation.create", { agentId: "forge" })).note, undefined, "no folder: a project with no limits");
	// A folder no project has: a new project, with a copy of its agent and the default orchestrator, with no conversation
	// until the person opens it; then `projects.startFresh` makes it.
	const newcomer = (await client.call("agents.save", { agent: { name: "Newcomer", cwd: fresh, access: "read" } })).id as string;
	const rowsBefore = client.events.library.conversations.length;
	const inFresh = (await client.call("conversation.create", { agentId: newcomer })).id as number;
	const freshProject = await client.until("its project", () => client.projects.find((project: any) => project.folder === fresh));
	assert.equal(freshProject.name, "fresh");
	assert.notEqual((await client.until("its row", () => client.row(inFresh)?.projectId === freshProject.id && client.row(inFresh))).runsAs, newcomer);
	assert.equal(client.agent(freshProject.orchestratorId).name, "Orchestrator");
	assert.equal(freshProject.conversation, null);
	assert.equal(client.events.library.conversations.length, rowsBefore + 1, "the conversation made, and no other");
	const opened = (await client.call("projects.startFresh", { id: freshProject.id })).conversation as number;
	await client.until("its orchestrator's conversation", () => client.projects.find((project: any) => project.id === freshProject.id)?.conversation === opened);
	assert.equal((await client.until("its row", () => client.row(opened))).agentId, freshProject.orchestratorId);
	// The archived project's folder: the project is restored, its orchestrator still with no conversation.
	const returning = (await client.call("agents.save", { agent: { name: "Returning", cwd: old, access: "read" } })).id as string;
	const inOld = (await client.call("conversation.create", { agentId: returning })).id as number;
	const oldProject = projectOf(old);
	const restored = await client.until("restored", () => client.projects.find((project: any) => project.id === oldProject.id && project.archivedAt === undefined));
	assert.equal(restored.conversation, null);
	assert.equal((await client.until("its row", () => client.row(inOld)?.projectId === oldProject.id && client.row(inOld))).projectId, oldProject.id);
	// A chat stays out of every project.
	const chat = (await client.call("conversation.create", { chat: true })).id as number;
	assert.equal((await client.until("the chat", () => client.row(chat))).projectId, null);
	// A fork of a conversation whose project was deleted is in no project, as that conversation is, and so is carried.
	await client.call("conversation.open", { id: inFresh });
	await client.answer(inFresh, "something to fork from");
	await client.call("projects.delete", { id: freshProject.id });
	await client.until("deleted", () => client.projects.find((project: any) => project.id === freshProject.id)?.deletedAt !== undefined);
	const { id: fork } = await client.call("conversation.fork", { id: inFresh, entryId: client.conversations.get(inFresh).items.at(-1).id });
	const forkRow = await client.until("the fork carried", () => client.row(fork)?.projectId !== null && client.row(fork)?.projectId !== undefined && client.row(fork));
	const refound = client.projects.find((project: any) => project.id === forkRow.projectId);
	assert.equal(refound.folder, fresh);
	assert.equal(refound.deletedAt, undefined);
	assert.notEqual(refound.id, freshProject.id);
	assert.equal(client.agent(forkRow.runsAs).template.id, newcomer);
	// None of it is anything a run would do again.
	assert.equal((await client.call("projects.carryOver", { dryRun: true })).plan, null);
	step("conversations made later go into their folder's project, a new one, or an archived one restored; a fork too; chats stay out");

	// ---- A conversation left in no project while the preview is on is carried at the next start

	// Made with the preview off, then the engine stopped as if it had been made with the preview on and the engine had
	// stopped before carrying it over.
	await client.call("projects.setPreview", { on: false });
	const stray = await conversation("scout", plain);
	await client.until("the stray", () => client.row(stray));
	client.close();
	await stop(engine);
	const settingsPath = join(home, "settings.json");
	const settings = JSON.parse(readFileSync(settingsPath, "utf8"));
	writeFileSync(settingsPath, JSON.stringify({ ...settings, projects: { preview: true } }));
	engine = start();
	client = await Client.connect(engine, home);
	await client.until("after the restart", () => client.events.projects && client.events.agents && client.events.library);
	const strayRow = await client.until("carried at start", () => client.row(stray)?.projectId === inPlain.id && client.row(stray));
	assert.equal(client.agent(strayRow.runsAs).template.id, "scout");
	step("a conversation left in no project while the preview is on is carried as the engine starts");

	// ---- An engine stopped and started again keeps it all

	const kept = { projects: client.events.projects, agents: client.events.agents.agents };
	client.close();
	await stop(engine);
	engine = start();
	client = await Client.connect(engine, home);
	await client.until("after the restart", () => client.events.projects && client.events.agents);
	assert.deepEqual(client.events.projects, kept.projects);
	assert.deepEqual(client.events.agents.agents, kept.agents);
	assert.equal(JSON.parse(readFileSync(settingsPath, "utf8")).projects.preview, true);
	step("an engine stopped and started again keeps the projects, the copies and the record");
} finally {
	client.close();
	await stop(engine);
}
