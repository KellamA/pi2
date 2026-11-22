// Restoring one conversation of a deleted project (#531, docs/projects.md 3.6), with a real engine on a throwaway data
// folder and Keychain service, driven over its socket as an app would drive it. A project is made with two conversations,
// one with a sub-chat, and deleted; the dry run answers what a restore would do and changes nothing; the restore moves the
// one conversation and its sub-chat into the project of their folder, under a copy of its agent (Allow everything and the
// variables' values included), and leaves the other where it was. A stale plan is refused with the new report; a sub-chat,
// one not of a deleted project, one working and the preview off are refused; the schedules the deletion held stay held;
// and doing it twice changes nothing.

import assert from "node:assert/strict";
import { type ChildProcess, execFileSync, spawn } from "node:child_process";
import { closeSync, existsSync, mkdirSync, mkdtempSync, openSync, readFileSync, readdirSync, realpathSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { personOnly, SETTINGS_ONLY_IN_THE_APP } from "../src/answers.ts";
import { NOT_OF_DELETED_PROJECT, RESTORE_CHANGED, RESTORE_FOLDER_MISSING, RESTORE_SUB_CHAT, STOP_RESTORE } from "../src/carryover.ts";
import { KeychainObjects } from "../src/credentials.ts";
import { PROJECT_DELETED } from "../src/projects.ts";
import { EngineClient, standInApp, stop } from "./patience.ts";

// Commits made here use a fixed identity and none of the person's own git settings.
process.env.GIT_CONFIG_GLOBAL = "/dev/null";
process.env.GIT_CONFIG_NOSYSTEM = "1";
Object.assign(process.env, { GIT_AUTHOR_NAME: "Test", GIT_AUTHOR_EMAIL: "test@example.invalid", GIT_COMMITTER_NAME: "Test", GIT_COMMITTER_EMAIL: "test@example.invalid" });
process.env.PI2_DEMO_TOKENS_PER_SECOND ??= "100000";
process.env.PI2_LOGIN_SHELL ??= "off";
// Restoring is the person's act, taken only from the app's connection (#504): a stand-in takes this test's connections for it.
process.env.PI2_APP_BUNDLE = standInApp();

const home = mkdtempSync(join(tmpdir(), "pi2-restore-"));
const work = realpathSync(mkdtempSync(join(tmpdir(), "pi2-restore-work-")));
const main = join(import.meta.dirname, "..", "src", "main.ts");
const KEYCHAIN_SERVICE = `dev.pi2.credentials.test-restoreconversation-${process.pid}`;
const commitGate = join(work, "restore-commit");

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

// The folder the deleted project worked in: a real repository, so the grouping key is the folder itself.
const git = (cwd: string, ...args: string[]) => execFileSync("git", args, { cwd, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();
const repo = join(work, "repo");
mkdirSync(repo, { recursive: true });
git(repo, "init", "-q", "-b", "main");
writeFileSync(join(repo, "README.md"), "hello\n");
git(repo, "add", ".");
git(repo, "commit", "-q", "-m", "first");

class Client extends EngineClient {
	agent(id: string): any {
		return this.events.agents?.agents?.find((agent: any) => agent.id === id);
	}
	/** A conversation's row, in the sidebar's list or the Archive's. */
	row(id: number): any {
		return this.events.library?.conversations?.find((row: any) => row.id === id) ?? this.events.library?.archived?.find((row: any) => row.id === id);
	}
	project(id: string): any {
		return this.events.projects?.projects?.find((project: any) => project.id === id);
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
}

const env = (extra: Record<string, string> = {}) => ({ ...process.env, PI2_HOME: home, PI2_KEYCHAIN_SERVICE: KEYCHAIN_SERVICE, PI2_RESTORE_COMMIT_GATE: commitGate, ...extra });
const start = (extra?: Record<string, string>) => {
	const log = openSync(join(home, "engine.log"), "a");
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

// Only the app's connection may restore; the dry run, which changes nothing, stays open to any connection.
assert.equal(personOnly("projects.restoreConversation", { id: 1 }), SETTINGS_ONLY_IN_THE_APP);
assert.equal(personOnly("projects.restoreConversation", { id: 1, dryRun: true }), undefined);
step("the restore is classed with the requests only the app may make");

engine = start();
let client = await Client.connect(engine, home);
try {
	await client.until("the engine's greetings", () => client.events.agents && client.events.library && client.events.projects);

	// ---- A project with two conversations, one with a sub-chat, and a schedule on one of its agents

	const helper = (await client.call("agents.save", { agent: { name: "Helper" } })).id as string;
	const worker = (await client.call("agents.save", { agent: { name: "Worker", cwd: repo, instructions: "Build it.", delegates: [helper] } })).id as string;
	const made = await client.call("projects.create", { folder: repo });
	const project = made.id as string;
	const orchestratorConversation = made.conversation as number;
	const returningTemplate = (await client.call("agents.save", { agent: { name: "Returning", cwd: repo } })).id as string;
	const carried = (await client.call("conversation.create", { agentId: returningTemplate })).id as number;
	await client.until("template-backed conversation carried into the source", () => client.row(carried)?.projectId === project);
	// The helper's copy is made first, so the worker's copy's delegates can be mapped to it (3.3).
	const helperCopy = (await client.call("projects.addAgent", { projectId: project, template: helper })).id as string;
	const repeats = await Promise.all(Array.from({ length: 3 }, async () => (await client.call("conversation.create", { agentId: helperCopy })).id as number));
	const workerCopy = (await client.call("projects.addAgent", { projectId: project, template: worker })).id as string;
	const second = (await client.call("conversation.create", { agentId: workerCopy })).id as number;
	// The hand-off below needs the project's switch on (8.1), or it would wait for the person.
	await client.call("projects.set", { id: project, settings: { withoutAsking: { startAgents: true } } });
	// The copy in the project takes what only the person can give it: Allow everything and a variable with a value.
	await client.call("agents.allowEverything", { id: workerCopy, on: true });
	await client.call("variables.set", { agentId: workerCopy, name: "GH_TOKEN", value: "token-531" });
	const schedule = (await client.call("schedules.save", { schedule: { title: "Nightly build", agentId: workerCopy, prompt: "Build it.", repeat: { kind: "daily", hour: 3, minute: 0 } } })).id as string;
	await client.call("conversation.open", { id: second });
	const tree = await client.call("worktree.create", { id: second });
	writeFileSync(join(tree.path, "uncommitted.txt"), "keep this\n");
	const branch = () => [git(tree.path, "branch", "--show-current"), git(tree.path, "rev-parse", "HEAD"), git(tree.path, "status", "--porcelain"), git(repo, "worktree", "list", "--porcelain")];
	const beforeTree = branch();
	assert.match(await client.answer(second, "/delegate Helper: look around"), /Handing that to Helper|You said/);
	const subChat = (await client.until("its sub-chat", () => client.events.library.conversations.find((row: any) => row.parent === second))).id as number;
	assert.equal(client.row(orchestratorConversation).projectId, project);
	assert.equal(client.row(second).projectId, project);
	assert.equal(client.row(subChat).projectId, project);
	step("a project with two conversations, one with a sub-chat, and a schedule on one of its agents");

	// ---- Deleted: its conversations keep their project, and its schedules are held

	// While the project is still live, its conversation is not of a deleted project, and the refusal says so.
	assert.equal((await refusal(client.call("projects.restoreConversation", { id: orchestratorConversation }))).message, NOT_OF_DELETED_PROJECT);
	await client.call("projects.delete", { id: project });
	await client.until("the project deleted", () => client.project(project)?.deletedAt !== undefined);
	assert.equal(client.row(orchestratorConversation).projectId, project);
	assert.equal(client.row(second).projectId, project);
	assert.equal(client.row(subChat).projectId, project);
	const scheduleAfter = client.events.schedules.schedules.find((row: any) => row.id === schedule);
	assert.equal(scheduleAfter.holdReason, PROJECT_DELETED);
	assert.equal((await refusal(client.call("schedules.save", { schedule: { title: "Again", agentId: workerCopy, prompt: "Once more.", repeat: { kind: "daily", hour: 4, minute: 0 } } }))).message, PROJECT_DELETED);
	step("the project deleted: its conversations keep their project, and its schedules are held and cannot be remade");

	// ---- Refusals: a sub-chat, and one working

	assert.equal((await refusal(client.call("projects.restoreConversation", { id: subChat }))).message, RESTORE_SUB_CHAT);
	// A message could have reached the conversation through the socket, which deletes nothing: the restore refuses.
	await client.call("submit", { id: second, text: "/slow take your time" });
	await client.until("the conversation busy", () => client.row(second).busy === true);
	assert.equal((await refusal(client.call("projects.restoreConversation", { id: second, dryRun: true }))).message, STOP_RESTORE);
	await client.call("abort", { id: second });
	await client.until("the conversation idle", () => client.row(second).busy === false);
	step("a sub-chat and one working are refused");

	// A missing worktree folder still groups under its repository in 9.2, but cannot be restored.
	renameSync(tree.path, `${tree.path}-away`);
	try {
		assert.equal((await refusal(client.call("projects.restoreConversation", { id: second, dryRun: true }))).message, RESTORE_FOLDER_MISSING);
		assert.equal(client.row(second).projectId, project);
		assert.equal(client.row(subChat).projectId, project);
	} finally {
		renameSync(`${tree.path}-away`, tree.path);
	}
	step("a vanished folder is refused without splitting the family");

	// ---- The dry run: what the restore would do, changing nothing

	const before = structuredClone(client.events);
	const report = await client.call("projects.restoreConversation", { id: second, dryRun: true });
	assert.equal(typeof report.plan, "string");
	assert.equal(report.projects.length, 1);
	const planned: any = report.projects[0];
	assert.equal(planned.key, realpathSync(repo));
	assert.equal(planned.name, "repo");
	assert.equal(planned.existing, null);
	assert.equal(planned.adopted, false);
	assert.equal(planned.archived, false);
	assert.equal(planned.conversations, 1);
	assert.equal(planned.subChats, 1);
	assert.equal(planned.orchestrator.conversation, second);
	assert.equal(planned.orchestrator.template, workerCopy);
	assert.equal(report.rootAgent, workerCopy);
	assert.equal(report.restoresProject, false);
	assert.equal(report.projectId, undefined);
	const plannedWorker: any = planned.copies.find((copy: any) => copy.template === workerCopy);
	const plannedHelper: any = planned.copies.find((copy: any) => copy.template !== workerCopy);
	assert.equal(plannedWorker.name, "Worker");
	assert.equal(plannedWorker.allowEverything, true);
	assert.deepEqual(plannedWorker.variables, ["GH_TOKEN"]);
	assert.ok(plannedHelper !== undefined, "the plan copies the sub-chat's agent too, so it can still hand work to it");
	assert.equal(plannedHelper.name, "Helper");
	assert.equal(plannedHelper.allowEverything, false);
	assert.deepEqual(plannedHelper.variables, []);
	assert.deepEqual(client.events.library, before.library);
	assert.deepEqual(client.events.agents, before.agents);
	assert.equal(client.project(project).deletedAt !== undefined, true);
	step("the dry run answers what the restore would do, and changes nothing");

	// ---- A stale plan is refused with the new report; the restore is one commit

	await client.call("variables.set", { agentId: workerCopy, name: "SECOND_KEY", value: "second-531" });
	const stale = await refusal(client.call("projects.restoreConversation", { id: second, plan: report.plan }));
	assert.equal(stale.message, RESTORE_CHANGED);
	const changed = stale.data as any;
	assert.deepEqual(changed.projects[0].copies.find((copy: any) => copy.template === workerCopy).variables, ["GH_TOKEN", "SECOND_KEY"]);
	writeFileSync(commitGate, "");
	const busy = refusal(client.call("projects.restoreConversation", { id: second, plan: changed.plan }));
	await client.until("restore ready to commit", () => existsSync(`${commitGate}.started`));
	await client.call("submit", { id: second, text: "/slow not yet" });
	await client.until("a run started during restore", () => client.row(second)?.busy === true);
	rmSync(commitGate);
	rmSync(`${commitGate}.started`);
	assert.equal((await busy).message, STOP_RESTORE);
	assert.equal(client.row(second).projectId, project);
	assert.equal(client.row(subChat).projectId, project);
	assert.deepEqual(readdirSync(join(home, "backups")), []);
	await client.call("abort", { id: second });
	await client.until("the run stopped", () => client.row(second).busy === false);
	step("work starting after validation refuses the move and discards the unused backup");
	const fresh = await client.call("projects.restoreConversation", { id: second, dryRun: true });
	const restored: any = await client.call("projects.restoreConversation", { id: second, plan: fresh.plan });
	const into: any = client.events.projects.projects.find((row: any) => row.id !== project && row.deletedAt === undefined);
	assert.ok(into !== undefined, "the restore made the project of the folder");
	assert.equal(typeof restored.backup, "string");
	assert.equal(restored.projectId, into.id);
	assert.equal(restored.ranAt, null);
	assert.equal(JSON.parse(readFileSync(join(restored.backup, "manifest.json"), "utf8")).app, "pi2");
	assert.ok(existsSync(join(restored.backup, "session.sqlite")));
	assert.equal(client.events.projects.carryOver?.backup, restored.backup);
	assert.equal(realpathSync(into.folder), realpathSync(repo));
	assert.equal(into.settings.wakeOnReports, true);
	assert.equal(client.row(second).projectId, into.id);
	assert.equal(client.row(subChat).projectId, into.id);
	assert.deepEqual(branch(), beforeTree);
	assert.equal(client.conversations.get(second)?.state.agent.cwd, tree.path);
	assert.equal(readFileSync(join(tree.path, "uncommitted.txt"), "utf8"), "keep this\n");
	assert.equal(client.row(orchestratorConversation).projectId, project);
	const workerIn: any = Object.values(client.events.agents.agents).find((agent: any) => agent.projectId === into.id && agent.template?.id === workerCopy);
	assert.ok(workerIn !== undefined, "a copy of the conversation's agent was made in the project");
	assert.equal(workerIn.allowEverything, true);
	assert.equal(client.row(second).runsAs, workerIn.id);
	assert.equal(into.orchestratorId, workerIn.id);
	assert.equal(into.conversation, second);
	// The variables' values were copied by the retried Keychain step: nothing is pending and the copy's are set.
	await client.until("the variables' values copied", () => {
		const copy = client.agent(workerIn.id);
		return copy?.variables?.length === 2 && copy.variables.every((variable: any) => variable.set === true) && (client.events.projects.carryOver?.secretsPending ?? []).length === 0;
	});
	assert.equal(restored.secretsPending.length, 0);
	assert.deepEqual(await new KeychainObjects(KEYCHAIN_SERVICE).read(`variables/${workerIn.id}`), { GH_TOKEN: "token-531", SECOND_KEY: "second-531" });
	assert.doesNotMatch(JSON.stringify(restored), /token-531|second-531/);
	step("the stale plan refused with the new report; the restore moved the conversation and its sub-chat, under a copy of its agent, in one commit");

	// ---- Doing it twice changes nothing

	const after = structuredClone({ library: client.events.library, projects: client.events.projects, agents: client.events.agents });
	assert.equal((await refusal(client.call("projects.restoreConversation", { id: second }))).message, NOT_OF_DELETED_PROJECT);
	assert.equal((await refusal(client.call("projects.restoreConversation", { id: second, dryRun: true }))).message, NOT_OF_DELETED_PROJECT);
	assert.deepEqual({ library: client.events.library, projects: client.events.projects, agents: client.events.agents }, after);
	step("restoring it again is refused and changes nothing");

	// ---- Reuse the copy for two more conversations, then honor deletion of that same copy on the next restore.

	const helperIn = client.events.agents.agents.find((agent: any) => agent.projectId === into.id && agent.template?.id === helperCopy).id;
	for (const repeat of repeats.slice(0, 2)) {
		const sameCopy = await client.call("projects.restoreConversation", { id: repeat, dryRun: true });
		assert.deepEqual(sameCopy.projects[0].copies.map((copy: any) => copy.existing), [helperIn]);
		await client.call("projects.restoreConversation", { id: repeat, plan: sameCopy.plan });
		assert.equal(client.row(repeat).runsAs, helperIn);
	}
	await client.call("agents.delete", { id: helperIn });
	const withoutCopy = await client.call("projects.restoreConversation", { id: repeats[2], dryRun: true });
	assert.equal(withoutCopy.rootAgent, null);
	assert.deepEqual(withoutCopy.projects[0].copies, []);
	assert.match(withoutCopy.projects[0].notices.join(" "), /No copy will be made.*still belongs to the deleted project/);
	await client.call("projects.restoreConversation", { id: repeats[2], plan: withoutCopy.plan });
	assert.equal(client.row(repeats[2]!).projectId, into.id);
	assert.equal(client.row(repeats[2]!).runsAs, helperCopy);
	assert.equal(client.events.agents.agents.some((agent: any) => agent.projectId === into.id && agent.template?.id === helperCopy), false);
	step("two restores reuse the recorded copy; a later restore discloses that the deleted copy stays deleted");

	const handMade = (await client.call("projects.addAgent", { projectId: into.id, template: returningTemplate })).id as string;
	const adoption = await client.call("projects.restoreConversation", { id: carried, dryRun: true });
	assert.equal(adoption.rootAgent, returningTemplate);
	assert.equal(adoption.projects[0].copies.find((copy: any) => copy.template === returningTemplate).existing, handMade);
	await client.call("projects.restoreConversation", { id: carried, plan: adoption.plan });
	assert.equal(client.row(carried).runsAs, handMade);
	assert.equal(client.agent(handMade).allowEverything, undefined);
	assert.equal(client.events.agents.agents.filter((agent: any) => agent.projectId === into.id && agent.template?.id === returningTemplate).length, 1);
	step("a carried conversation adopts the person's existing copy of its template without changing its reach");

	// ---- The other conversation: into the project that exists for the folder now, restored if archived

	await client.call("projects.archive", { id: into.id });
	await client.call("conversation.archive", { id: orchestratorConversation });
	await client.until("it archived", () => client.row(orchestratorConversation).archivedAt !== undefined);
	const secondReport = await client.call("projects.restoreConversation", { id: orchestratorConversation, dryRun: true });
	const secondPlanned = secondReport.projects[0];
	assert.equal(secondPlanned.existing, into.id);
	assert.equal(secondPlanned.orchestrator, null);
	assert.equal(secondPlanned.copies.length, 1);
	assert.equal(secondReport.restoresProject, true);
	const again = await client.call("projects.restoreConversation", { id: orchestratorConversation, plan: secondReport.plan });
	assert.equal(again.backup, restored.backup);
	const now = client.events.projects.projects.find((row: any) => row.id === into.id);
	assert.equal(client.row(orchestratorConversation).projectId, into.id);
	assert.equal(client.row(orchestratorConversation).archivedAt, undefined);
	assert.equal(now.orchestratorId, workerIn.id);
	assert.equal(now.conversation, second);
	assert.equal(now.archivedAt, undefined);
	assert.equal(client.project(project).conversation, null);
	assert.equal((await refusal(client.call("projects.restoreConversation", { id: orchestratorConversation }))).message, NOT_OF_DELETED_PROJECT);
	step("the other conversation went into the project that exists for the folder, restored if archived, and the orchestrator stands");

	// ---- A destination deleted after the final request starts: no writes from the obsolete plan.

	const later = (await client.call("projects.startFresh", { id: into.id })).conversation as number;
	await client.call("projects.delete", { id: into.id });
	const target = (await client.call("projects.create", { folder: repo })).id as string;
	const toTarget = await client.call("projects.restoreConversation", { id: second, dryRun: true });
	assert.equal(toTarget.projects[0].existing, target);
	writeFileSync(commitGate, "");
	const stopped = refusal(client.call("projects.restoreConversation", { id: second, plan: toTarget.plan }));
	await client.until("restore between plan and commit", () => existsSync(`${commitGate}.started`));
	await client.call("projects.delete", { id: target });
	rmSync(commitGate);
	const revised = await stopped;
	assert.equal(revised.message, RESTORE_CHANGED);
	assert.equal(revised.data.projects[0].existing, null);
	assert.equal(client.row(second).projectId, into.id);
	assert.equal(client.row(subChat).projectId, into.id);
	assert.equal(client.project(into.id).conversation, later);
	assert.ok(client.project(into.id).earlier.includes(second));
	step("deleting the destination between validation and commit refuses the obsolete plan without moving anyone");

	await client.call("projects.restoreConversation", { id: second, plan: revised.data.plan });
	assert.equal(client.project(into.id).earlier.includes(second), false);
	step("the eventual move clears the earlier-conversation reference");

	// A real connection whose stand-in peer verdict is not the app's can preview but not apply, even with the right plan.
	client.close();
	await stop(engine);
	engine = start({ PI2_APP_BUNDLE: standInApp(`#!/bin/sh\necho '{"app":false,"why":"not the app"}'\n`) });
	client = await Client.connect(engine, home);
	const visible = await client.call("projects.restoreConversation", { id: later, dryRun: true });
	assert.equal(typeof visible.plan, "string");
	assert.equal((await refusal(client.call("projects.restoreConversation", { id: later, plan: visible.plan }))).message, SETTINGS_ONLY_IN_THE_APP);
	await client.until("the other conversation stayed put", () => client.row(later)?.projectId === into.id);
	step("an ordinary socket connection can preview but cannot restore");
} finally {
	client.close();
	await stop(engine);
}
