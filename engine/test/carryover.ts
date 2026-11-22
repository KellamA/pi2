// The update that took the projects switch out (#715, #483; docs/projects.md section 9): carrying over, run by the
// engine itself as it starts, on a data folder as the last version with the switch left it. A real engine on a
// throwaway data folder and Keychain service, driven over its socket as an app would drive it.
//
// The folder is made by this engine with nothing carried (`PI2_CARRY_NEVER`, the last version with the switch never
// on), to the shape of a real library: hundreds of conversations in a repository, its subfolder, a worktree pi² made of
// it, a second repository, a plain folder and no folder; sub-chats; archived and deleted ones; chats; an agent deleted
// since; two agents sharing a folder; an agent's notes, written by it and by the person; variables with values; Allow
// everything. Its report changes nothing. A copy of the data that cannot be made carries nothing, and says so in the log
// and the `projects` event. Then the update: the copy made first and recorded (`carry.removalBackup`), the plan run as
// its report said, cut off between two projects' commits (the engine killed there) and finished by the next start,
// which makes no second copy; stopped between its commits and the copying of the variables' values, which the next
// start finishes; `settings.json`'s switch written for the versions before; what the last version reads (the library,
// the agents and the notes) as it was, but for the fields it does not read and the project agents. A second start writes
// nothing. Then conversations made later, a fork, a deleted project's, and one left in no project carried at the next
// start. Then the owner's case, a folder where the switch was turned on and off again and carrying over ran long ago: a
// fresh copy is made, settings.json's switch written, and nothing changes but a stray and a sub-chat made with the switch
// off, which is given its project's copy. A copy that fails once its folder is made, and one an engine is killed in the
// middle of (`PI2_BACKUP_GATE`), leave nothing behind. Last, a release engine (a `BUILD` file) ignores `PI2_CARRY_NEVER`.
// carryplan.ts checks the plan alone on a larger library.
//
// `PI2_CARRY_KEEP=<folder>` copies the data folder there at the end, for a look at it with an older engine.

import assert from "node:assert/strict";
import { type ChildProcess, execFileSync, spawn } from "node:child_process";
import { closeSync, cpSync, existsSync, mkdirSync, mkdtempSync, openSync, readdirSync, readFileSync, realpathSync, rmdirSync, rmSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { BACKGROUND_CONTEXT as context } from "@earendil-works/chord/context";
import { createModels } from "@earendil-works/pi-ai";
import { createRegistry, Harness } from "@earendil-works/pi-durable";
import { openNodeSqliteStorage } from "@earendil-works/pi-durable/storage/sqlite/node";
import { CARRIES_ITSELF } from "../src/carryover.ts";
import { KeychainObjects } from "../src/credentials.ts";
import { PROJECT_DELETED, Projects } from "../src/projects.ts";
import { Library } from "../src/state.ts";
import { EngineClient, standInApp, stop, until } from "./patience.ts";

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
const settingsPath = join(home, "settings.json");
const backups = join(home, "backups");

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
	/** How many of each event about a stored document came: a report that writes nothing sends none of them. */
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
	/** Every conversation's place: its project and the agent it runs as. */
	places(): string[] {
		return [...(this.events.library?.conversations ?? []), ...(this.events.library?.archived ?? [])].map((row: any) => `${row.id} ${row.projectId} ${row.runsAs}`).sort();
	}
}

const env = (extra: Record<string, string> = {}) => ({ ...process.env, PI2_HOME: home, PI2_KEYCHAIN_SERVICE: KEYCHAIN_SERVICE, ...extra });
const logPath = join(home, "engine.log");
const start = (extra: Record<string, string> = {}) => {
	// Match the app's logging: a bare engine writes to stderr, not to a file of its own.
	const log = openSync(logPath, "a");
	try {
		return spawn(process.execPath, [main], { env: env(extra), stdio: ["ignore", "ignore", log] });
	} finally {
		closeSync(log);
	}
};
const refusal = async (promise: Promise<unknown>): Promise<any> => {
	try {
		await promise;
	} catch (error) {
		return error;
	}
	assert.fail("not refused");
};
const settingsFile = () => (existsSync(settingsPath) ? JSON.parse(readFileSync(settingsPath, "utf8")) : {});
const backupsMade = () => (existsSync(backups) && statSync(backups).isDirectory() ? readdirSync(backups).sort() : []);
const ready = (c: Client) => c.until("the greetings", () => c.events.projects && c.events.agents && c.events.library && c.events.memory);
/** With the engine stopped: read or change its documents, as an older version stored them. */
const offline = async <T>(edit: (harness: Harness) => Promise<T>): Promise<T> => {
	const storage = await openNodeSqliteStorage(join(home, "session.sqlite"));
	const harness = await Harness.open(storage, { registry: createRegistry(), models: createModels() }, context);
	try {
		return await edit(harness);
	} finally {
		await harness.close(context);
	}
};

// The first engine is the last version with the switch never turned on: it carries nothing.
engine = start({ PI2_CARRY_NEVER: "1" });
let client = await Client.connect(engine, home);
try {
	await ready(client);

	// ---- A library to the shape of a real one, made with the switch never on

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
	// An agent with notes and a variable, in a plain folder; an ordinary one there too, and one made last.
	await conversation("atlas", plain);
	const ordinary = await conversation("scout", plain);
	const late = await conversation("forge", plain);
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
	assert.deepEqual(client.projects, [], "nothing carried as it was made");
	assert.equal(client.row(ordinary).projectId, null);
	step(`a library of ${made.size} conversations, with sub-chats, archived and deleted ones, chats, a worktree and an agent deleted since`);

	// ---- The report, before the update: it changes nothing

	const before = {
		library: structuredClone(client.events.library),
		agents: structuredClone(client.events.agents),
		memory: structuredClone(client.events.memory),
		projects: structuredClone(client.events.projects),
	};
	assert.deepEqual(before.projects, { event: "projects", preview: true, projects: [], carryOver: null });
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
		assert.equal(entry.subChatsPutRight, 0);
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
	assert.deepEqual(report.leftOut, { chats: 2, deleted, deletedProject: 0, notesLeft: 1 });
	assert.equal(report.already, 0);
	assert.deepEqual([report.ranAt, report.backup, report.secretsPending], [null, null, []]);
	// Nothing written: no event about anything stored, and the same report again.
	assert.deepEqual(await client.call("projects.carryOver", { dryRun: true }), report);
	await client.call("projects.list");
	assert.deepEqual(client.counts, counted);
	assert.deepEqual(client.events.projects, before.projects);
	assert.deepEqual(backupsMade(), []);
	assert.equal(settingsFile().projects, undefined);
	// Only the dry run is taken: the run is the engine's own.
	assert.equal((await refusal(client.call("projects.carryOver", { plan: report.plan }))).message, CARRIES_ITSELF);
	step("the report, before the update: each project, its copies and orchestrator, what is left out; nothing written");

	// ---- A copy of the data that cannot be made: nothing is carried, and the engine says so; the next start tries again

	client.close();
	await stop(engine);
	writeFileSync(backups, "a file where the folder of copies goes\n");
	engine = start();
	client = await Client.connect(engine, home);
	await ready(client);
	const failedWhy = await client.until("the failure told", () => client.events.projects.carryOver?.removalFailed);
	assert.match(failedWhy, /^The copy of your data could not be made, so nothing was moved into projects: .+\. pi² tries again when it next starts\.$/);
	assert.equal(client.events.projects.carryOver.removalBackup, null);
	assert.deepEqual(client.projects, []);
	assert.equal(client.row(ordinary).projectId, null);
	assert.equal(settingsFile().projects, undefined, "the switch is not written");
	assert.ok(readFileSync(logPath, "utf8").includes("carrying over at the update: The copy of your data could not be made"));
	assert.equal((await client.call("projects.carryOver", { dryRun: true })).plan, report.plan, "the plan as it was");
	client.close();
	await stop(engine);
	rmSync(backups);
	step("a copy of the data that cannot be made: nothing is carried, and the log and the projects event say why");

	// ---- A copy that fails part way, once its folder is made: nothing is left in backups/, nothing is carried, even a
	// conversation made meanwhile

	// A settings file the copy cannot take (a folder where `added-models.json` goes, which the engine reads as none).
	const unreadable = join(home, "added-models.json");
	mkdirSync(unreadable);
	engine = start();
	client = await Client.connect(engine, home);
	await ready(client);
	const failedInside = await client.until("the failure told", () => client.events.projects.carryOver?.removalFailed);
	assert.match(failedInside, /^The copy of your data could not be made/);
	assert.deepEqual(readdirSync(backups), [], "no copy and no unfinished one left");
	const during = (await client.call("conversation.create", { agentId: "scout" })).id as number;
	assert.equal((await client.until("its row", () => client.row(during))).projectId, null, "made while no copy is recorded: not carried");
	await client.call("conversation.delete", { id: during });
	assert.deepEqual(client.projects, []);
	assert.equal(settingsFile().projects, undefined);
	client.close();
	await stop(engine);
	rmdirSync(unreadable);
	step("a copy that fails once its folder is made leaves nothing in backups/, carries nothing, and says why; a conversation made meanwhile is not carried");

	// ---- An engine killed while it makes the copy leaves it unfinished; the next start removes it, and only it

	const backupGate = join(work, "backup-gate");
	writeFileSync(backupGate, "");
	engine = start({ PI2_BACKUP_GATE: backupGate });
	await until("held in the copy", () => existsSync(`${backupGate}.started`), { over: () => (engine!.exitCode !== null ? "the engine stopped" : undefined) });
	engine.kill("SIGKILL");
	await stop(engine);
	rmSync(backupGate, { force: true });
	const unfinished = readdirSync(backups);
	assert.equal(unfinished.length, 1);
	assert.match(unfinished[0]!, /^pi2-backup-\d{8}-\d{6}\.partial$/);
	assert.equal(await offline(async (harness) => (await harness.snapshot(Projects, context))?.carry.removalBackup), undefined, "not recorded");
	// A folder of the person's own there, without the mark, is never removed.
	const theirs = join(backups, "pi2-backup-kept-by-hand");
	mkdirSync(theirs);
	step("an engine killed while it makes the copy leaves it marked unfinished, and records nothing");

	// ---- The update, cut off between its first two projects' commits, as by a crash

	assert.equal(report.projects[0].key, other);
	writeFileSync(commitGate, "");
	engine = start({ PI2_CARRY_COMMIT_GATE: commitGate });
	await until("held before the second commit", () => existsSync(`${commitGate}.started`), { over: () => (engine!.exitCode !== null ? "the engine stopped" : undefined) });
	engine.kill("SIGKILL");
	await stop(engine);
	rmSync(commitGate, { force: true });
	const cut = await offline(async (harness) => (await harness.snapshot(Projects, context))!);
	assert.deepEqual(Object.values(cut.projects).map((project) => project.folder), [other], "the first project's commit alone");
	assert.ok(readFileSync(logPath, "utf8").includes("carrying over at the update: removed 1 unfinished copy of the data"));
	assert.ok(existsSync(theirs), "a folder without the mark stays");
	rmdirSync(theirs);
	assert.deepEqual(backupsMade().length, 1, "the copy made first, and the unfinished one gone");
	const removal = cut.carry.removalBackup!;
	assert.equal(removal.path, join(home, "backups", backupsMade()[0]!));
	assert.equal(typeof removal.at, "number");
	assert.ok(existsSync(join(removal.path, "session.sqlite")));
	assert.ok(existsSync(join(removal.path, "settings.json")));
	assert.equal(JSON.parse(readFileSync(join(removal.path, "settings.json"), "utf8")).projects, undefined, "a copy from before anything changed");
	assert.equal(cut.carry.backup, removal.path, "the run's own record of its backup is the same copy");
	assert.equal(settingsFile().projects, undefined, "the switch is written once the run is whole");
	step("the update, cut off between two projects' commits: the copy made first and recorded, the first project whole");

	// ---- The next start finishes it, with no second copy, and is stopped before the Keychain step, as by a crash

	writeFileSync(secretsGate, "");
	engine = start({ PI2_CARRY_SECRETS_GATE: secretsGate });
	client = await Client.connect(engine, home);
	await ready(client);
	const pendingNow = report.projects.flatMap((entry: any) => entry.copies.filter((copy: any) => copy.variables.length > 0)).length;
	assert.ok(pendingNow >= 6, `${pendingNow} copies with values to copy`);
	await client.until("the commits", () => client.events.projects.carryOver?.secretsPending?.length === pendingNow && client.projects.length === report.projects.length);
	await client.until("the Keychain step held", () => existsSync(`${secretsGate}.started`));
	await client.until("the switch written", () => settingsFile().projects?.preview === true);
	assert.deepEqual(client.events.projects.carryOver.removalBackup, removal, "the copy recorded at the first start");
	assert.equal(client.events.projects.carryOver.removalFailed, null);
	assert.equal(backupsMade().length, 1, "and no second copy");
	engine.kill("SIGKILL");
	await stop(engine);
	client.close();
	rmSync(secretsGate, { force: true });
	engine = start();
	client = await Client.connect(engine, home);
	await ready(client);
	await client.until("the values copied at start", () => client.events.projects.carryOver?.secretsPending?.length === 0);
	const keychain = new KeychainObjects(KEYCHAIN_SERVICE);
	const copies = client.events.agents.agents.filter((agent: any) => agent.projectId !== undefined);
	for (const [template, values] of [["forge", { GH_TOKEN: "token-458" }], ["atlas", { ATLAS_KEY: "key-458" }]] as const) {
		const ids = copies.filter((agent: any) => agent.template?.id === template).map((agent: any) => agent.id);
		assert.equal(ids.length, report.projects.filter((entry: any) => copyIn(entry, template) !== undefined).length);
		for (const id of ids) {
			assert.deepEqual(await keychain.read(`variables/${id}`), values);
			await client.until("marked set", () => client.agent(id).variables?.[0]?.set === true);
		}
	}
	const { carryOver } = client.events.projects;
	assert.equal(typeof carryOver.ranAt, "number");
	assert.equal(carryOver.backup, removal.path);
	assert.deepEqual(carryOver.removalBackup, removal);
	assert.equal(carryOver.removalFailed, null);
	assert.equal(client.events.projects.preview, true);
	assert.equal((await client.call("projects.carryOver", { dryRun: true })).plan, null, "nothing left to do: the record is whole");
	assert.equal(backupsMade().length, 1);
	step("the next start finishes the run with no second copy and writes the switch; one cut off before the Keychain step, the start after copies the values");

	// ---- The run did what the report said, and nothing else

	const projectOf = (key: string) => client.projects.find((project: any) => (project.folder ?? "none") === key || (key === "none" && project.folder === null));
	for (const entry of report.projects) {
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
		// Its notes, for the copy of Atlas alone, each once.
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
			assert.deepEqual(persons, ["The person prefers short answers."], entry.key);
		}
	}
	assert.equal(client.projects.length, report.projects.length, "no project but the report's");
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
	step("the run did what the report said: its projects, copies, orchestrators, notes and conversations, and nothing else");

	// ---- What the last version with the switch reads, as it was

	const unmarkedLibrary = (library: any) => {
		// The fields the old screens do not read: the project (#456), whether it is an orchestrator's (#466), what it runs as.
		const unmarked = (row: any) => {
			const { projectId: _, orchestrator: __, runsAs: ___, ...rest } = row;
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
	assert.deepEqual(oldLists({ library: client.events.library, agents: client.events.agents, memory: client.events.memory }), oldLists({ library: before.library, agents: before.agents, memory: before.memory }));
	// No conversation was added: no empty one for any orchestrator.
	assert.equal(client.events.library.conversations.length + client.events.library.archived.length, before.library.conversations.length + before.library.archived.length);
	// Every carried conversation keeps its template as its agent, beside the copy it runs as.
	for (const [id, entry] of made) if (entry.carried) assert.equal(client.row(id).agentId, entry.agentId, `conversation ${id}`);
	step("what the last version with the switch reads is as it was: the library, the agents and their notes, each conversation's agentId");

	// ---- Every conversation in a project, running as its project's copy

	const after = await client.call("projects.carryOver", { dryRun: true });
	assert.equal(after.already, [...made.values()].filter((one) => one.carried && !one.subChat).length);
	assert.equal(client.agent(client.row(late).runsAs).template.id, "forge");
	assert.equal(client.row(orphan).runsAs, temp, "an agent deleted since: it runs as it does today");
	assert.equal(client.row(inWorktree).projectId, projectOf(repo).id, "a worktree pi² made is with its repository");
	step("every top-level conversation is in a project; each runs as its project's copy of its agent");

	// ---- A second start writes nothing

	const kept = { projects: structuredClone(client.events.projects), agents: structuredClone(client.events.agents.agents), places: client.places() };
	const settingsBefore = readFileSync(settingsPath, "utf8");
	const settingsTime = statSync(settingsPath).mtimeMs;
	const logBefore = readFileSync(logPath, "utf8").length;
	client.close();
	await stop(engine);
	engine = start();
	client = await Client.connect(engine, home);
	await ready(client);
	// A dry run waits for the update's own run at the start: both go one at a time.
	assert.equal((await client.call("projects.carryOver", { dryRun: true })).plan, null);
	assert.deepEqual(client.events.projects, kept.projects);
	assert.deepEqual(client.events.agents.agents, kept.agents);
	assert.deepEqual(client.places(), kept.places);
	assert.equal(readFileSync(settingsPath, "utf8"), settingsBefore);
	assert.equal(statSync(settingsPath).mtimeMs, settingsTime, "settings.json not written again");
	assert.equal(backupsMade().length, 1, "no second copy");
	assert.doesNotMatch(readFileSync(logPath, "utf8").slice(logBefore), /carrying over at the update|carried over at the update/);
	assert.deepEqual(await client.call("projects.retrySecrets"), { secrets: [] });
	step("a second start writes nothing: no copy, no commit, settings.json as it was");

	// ---- Conversations made later (9.9)

	const inPlain = projectOf(plain);
	await client.call("projects.set", { id: inPlain.id, settings: { limits: { planShare: 50, dailySpend: 100 } } });
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
	const newcomer = (await client.call("agents.save", { agent: { name: "Newcomer", cwd: fresh, access: "read", delegates: ["scout"] } })).id as string;
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
	// A carried parent starts a child with the project's Scout. After deletion the parent can still delegate to
	// templates, but cannot continue the old child, whose own agent belongs to the deleted project.
	const freshCopy = client.row(inFresh).runsAs;
	await client.call("projects.set", { id: freshProject.id, settings: { withoutAsking: { startAgents: true } } });
	await client.call("conversation.open", { id: inFresh });
	await client.answer(inFresh, "/delegate Scout: work in this project");
	const child = await client.until("the project agent's sub-chat", () => client.events.library.conversations.find((row: any) => row.parent === inFresh));
	assert.equal(client.agent(child.agentId).projectId, freshProject.id);
	const toolResults = () => client.conversations.get(inFresh).items.filter((item: any) => item.kind === "tool");
	const beforeContinue = toolResults().length;
	const { id: schedule } = await client.call("schedules.save", { schedule: { agentId: freshCopy, title: "Deleted project's schedule", prompt: "Do not run this", repeat: { kind: "interval", minutes: 60 } } });
	const scheduleRow = () => client.events.schedules?.schedules.find((row: any) => row.id === schedule);
	assert.equal((await client.until("the schedule is active", () => scheduleRow())).holdReason, undefined);
	// A carried conversation falls back to its template; the project's own conversations keep their agent.
	await client.answer(inFresh, "something to fork from");
	const beforeDelete = await client.call("projects.carryOver", { dryRun: true });
	await client.call("projects.delete", { id: freshProject.id });
	await client.until("deleted", () => client.projects.find((project: any) => project.id === freshProject.id)?.deletedAt !== undefined);
	assert.equal((await client.until("the schedule is held", () => scheduleRow()?.holdReason && scheduleRow())).lastRunAt, null);
	assert.equal(scheduleRow().holdReason, PROJECT_DELETED);
	assert.equal((await refusal(client.call("schedules.runNow", { id: schedule }))).message, PROJECT_DELETED);
	assert.equal((await refusal(client.call("conversation.create", { agentId: freshCopy }))).message, PROJECT_DELETED);
	assert.ok(readFileSync(logPath, "utf8").includes(`schedule ${schedule} held: ${PROJECT_DELETED}`));
	await client.until("the carried conversation falls back", () => client.row(inFresh).runsAs === newcomer);
	assert.equal(client.row(opened).runsAs, freshProject.orchestratorId);
	await client.answer(inFresh, `/continue ${child.id}: do not run this either`);
	assert.equal(toolResults().length, beforeContinue + 1);
	const blocked = toolResults().at(-1);
	assert.equal(blocked.isError, true);
	assert.match(blocked.text, /project was deleted/);
	const deletedReport = await client.call("projects.carryOver", { dryRun: true });
	assert.equal(deletedReport.already, beforeDelete.already - 2);
	assert.deepEqual(deletedReport.leftOut, { ...beforeDelete.leftOut, deletedProject: 2 });
	assert.equal(deletedReport.plan, null, "the deletion is not undone by a run");
	step("a deleted project's own starts and sub-chat continuations are refused, its schedule is held and reported, and its top-level conversations are counted apart");
	// A fork of the template-backed conversation starts outside the deleted project and so is carried.
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

	// ---- A conversation left in no project is carried at the next start

	// Made by an engine that carries nothing, as if the engine had stopped before carrying it over.
	client.close();
	await stop(engine);
	engine = start({ PI2_CARRY_NEVER: "1" });
	client = await Client.connect(engine, home);
	await ready(client);
	const stray = await conversation("scout", plain);
	assert.equal((await client.until("the stray", () => client.row(stray))).projectId, null);
	client.close();
	await stop(engine);
	engine = start();
	client = await Client.connect(engine, home);
	await ready(client);
	const strayRow = await client.until("carried at start", () => client.row(stray)?.projectId === inPlain.id && client.row(stray));
	assert.equal(client.agent(strayRow.runsAs).template.id, "scout");
	assert.equal((await client.until("the schedule is still held after restart", () => scheduleRow()?.holdReason && scheduleRow())).holdReason, PROJECT_DELETED);
	assert.equal(backupsMade().length, 1, "no second copy for it");
	step("a conversation left in no project is carried as the engine starts");

	// ---- The owner's case: a folder where the switch was on, and carrying over ran long ago

	// As the last version with the switch left it: no copy of the update's recorded; a sub-chat made with the switch off in
	// a conversation carried over, in its parent's project and running as its template (9.11 of that version); and a
	// conversation made since in no project.
	const repoProject = projectOf(repo);
	const scoutCopy = copies.find((agent: any) => agent.projectId === repoProject.id && agent.template?.id === "scout").id as string;
	assert.equal(client.row(subChatInRepo).runsAs, scoutCopy);
	const ownersBefore = { projects: structuredClone(client.events.projects), agents: structuredClone(client.events.agents.agents), places: client.places() };
	client.close();
	await stop(engine);
	engine = start({ PI2_CARRY_NEVER: "1" });
	client = await Client.connect(engine, home);
	await ready(client);
	const madeSince = await conversation("forge", repo);
	client.close();
	await stop(engine);
	await offline(async (harness) => {
		await harness.commit(async (tx) => {
			const doc = await tx.doc(Projects);
			delete doc.carry.removalBackup;
			const meta = (await tx.doc(Library)).conversations[String(subChatInRepo)]!;
			assert.equal(meta.projectId, repoProject.id);
			delete meta.projectAgentId;
		}, context);
	});
	// Switched on once, then off again: settings.json says so.
	writeFileSync(settingsPath, JSON.stringify({ ...settingsFile(), projects: { preview: false } }, null, "\t"));
	const owners = { backups: backupsMade() };
	assert.equal(owners.backups.length, 1);
	engine = start();
	client = await Client.connect(engine, home);
	await ready(client);
	const ownersRemoval = await client.until("a fresh copy recorded", () => client.events.projects.carryOver?.removalBackup);
	assert.equal((await client.call("projects.carryOver", { dryRun: true })).plan, null, "the update's run done");
	const twoCopies = backupsMade();
	assert.equal(twoCopies.length, 2, "a fresh copy, though an older one is recorded");
	assert.equal(ownersRemoval.path, join(backups, twoCopies.find((name) => !owners.backups.includes(name))!));
	assert.ok(existsSync(join(ownersRemoval.path, "session.sqlite")));
	assert.equal(client.events.projects.carryOver.backup, removal.path, "the older copy stays recorded as the first run's");
	assert.equal(client.events.projects.carryOver.removalFailed, null);
	await client.until("the sub-chat put right", () => client.row(subChatInRepo)?.runsAs === scoutCopy);
	assert.equal(client.row(subChatInRepo).agentId, "scout", "its template kept beside the copy");
	await client.until("the one made since carried", () => client.row(madeSince)?.projectId === repoProject.id);
	await client.until("settings.json written", () => settingsFile().projects?.preview === true);
	// Nothing else changed: every other conversation where it was, running as it did, the agents and the projects as they
	// were, and the record but for the run's time and the copy.
	assert.deepEqual(client.places().filter((line) => !line.startsWith(`${madeSince} `)), ownersBefore.places);
	assert.deepEqual(client.events.agents.agents, ownersBefore.agents);
	assert.deepEqual(client.events.projects.projects, ownersBefore.projects.projects);
	const unrecorded = (state: any) => ({ ...state, ranAt: 0, removalBackup: null });
	assert.deepEqual(unrecorded(client.events.projects.carryOver), unrecorded(ownersBefore.projects.carryOver));
	step("the owner's case, switched on once and off again: a fresh copy made and recorded beside the older one, settings.json's switch written; nothing changes but a conversation made since and a sub-chat made with the switch off, given its project's copy");

	// ---- An engine stopped and started again keeps it all

	const keptAgain = { projects: client.events.projects, agents: client.events.agents.agents };
	client.close();
	await stop(engine);
	engine = start();
	client = await Client.connect(engine, home);
	await ready(client);
	assert.equal((await client.call("projects.carryOver", { dryRun: true })).plan, null);
	assert.deepEqual(client.events.projects, keptAgain.projects);
	assert.deepEqual(client.events.agents.agents, keptAgain.agents);
	assert.equal(settingsFile().projects.preview, true);
	assert.equal(backupsMade().length, 2);
	step("an engine stopped and started again keeps the projects, the copies and the record");

	// ---- A release engine ignores PI2_CARRY_NEVER, and says so

	client.close();
	await stop(engine);
	// A release engine is one with a `BUILD` file next to its `src`: this engine's sources, copied with one.
	const release = join(work, "release", "engine");
	cpSync(join(import.meta.dirname, "..", "src"), join(release, "src"), { recursive: true });
	cpSync(join(import.meta.dirname, "..", "package.json"), join(release, "package.json"));
	symlinkSync(join(import.meta.dirname, "..", "node_modules"), join(release, "node_modules"));
	writeFileSync(join(release, "BUILD"), "test-release\n");
	const releaseHome = join(work, "release-home");
	mkdirSync(releaseHome);
	const releaseLog = openSync(join(releaseHome, "engine.log"), "a");
	engine = spawn(process.execPath, [join(release, "src", "main.ts")], { env: { ...env(), PI2_HOME: releaseHome, PI2_CARRY_NEVER: "1" }, stdio: ["ignore", "ignore", releaseLog] });
	closeSync(releaseLog);
	client = await Client.connect(engine, releaseHome);
	await ready(client);
	const carried = (await client.call("conversation.create", { agentId: "forge" })).id as number;
	assert.equal(typeof (await client.until("carried", () => client.row(carried)?.projectId !== null && client.row(carried))).projectId, "string", "a conversation made is carried as ever");
	assert.equal(JSON.parse(readFileSync(join(releaseHome, "settings.json"), "utf8")).projects.preview, true, "the update ran");
	assert.ok(readFileSync(join(releaseHome, "engine.log"), "utf8").includes("PI2_CARRY_NEVER is set and ignored: a release engine always carries over"));
	assert.ok(readFileSync(logPath, "utf8").includes("PI2_CARRY_NEVER is set: this development engine carries nothing into projects"), "and a development one says it is in force");
	step("a release engine (a BUILD file beside its src) ignores PI2_CARRY_NEVER and says so; a development one says it is in force");
} finally {
	client.close();
	await stop(engine);
	if (process.env.PI2_CARRY_KEEP !== undefined) cpSync(home, process.env.PI2_CARRY_KEEP, { recursive: true });
}
