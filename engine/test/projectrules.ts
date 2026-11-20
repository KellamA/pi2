// The project rules contract through a real engine using only the scripted demo model and an isolated data folder.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { ProjectRule } from "../src/projectrules.ts";
import { PREVIEW_OFF, PROJECT_ARCHIVED } from "../src/projects.ts";
import { EngineClient, previewOnLeavingOut, standInApp, stop } from "./patience.ts";
// The engine takes changes to what the person set only from its app's connection (#513): this test's connection stands
// for the app's, as the tests that answer for the person already do (#504).
process.env.PI2_APP_BUNDLE = standInApp();

const home = mkdtempSync(join(tmpdir(), "pi2-rules-"));
const gate = join(home, "summary");
writeFileSync(join(home, "CLAUDE.md"), "Keep this fixture separate from the project rules.\n");
const demo = { provider: "demo", modelId: "demo-1" };
const start = () => spawn(process.execPath, [join(import.meta.dirname, "../src/main.ts")], {
	env: { ...process.env, PI2_HOME: home, PI2_KEYCHAIN_SERVICE: `dev.pi2.credentials.test-projectrules-${process.pid}`, PI2_LOGIN_SHELL: "off", PI2_DEMO_TOKENS_PER_SECOND: "100000", PI2_DEMO_COMPACTION_GATE: gate },
	stdio: ["ignore", "ignore", "inherit"],
});
let engine = start();
let client: Client | undefined;
let other: Client | undefined;

class Client extends EngineClient {
	order: string[] = [];
	override receive(message: any): void {
		if (message.event === "projects" || message.event === "projectRules") this.order.push(message.event);
		super.receive(message);
	}
	rules(project: string): ProjectRule[] {
		return this.events.projectRules?.projects[project] ?? [];
	}
	async open(id: number): Promise<void> {
		await this.call("conversation.open", { id });
	}
	async answer(id: number, text: string): Promise<string> {
		const items = () => this.conversations.get(id)?.items ?? [];
		const previous = items().at(-1)?.id ?? 0;
		const { submissionId } = await this.call("submit", { id, text });
		await this.until(`answer to submission ${submissionId} in ${id}`, () => this.conversations.get(id)?.state.busy === false && items().some((item: any) => item.kind === "assistant" && item.id > previous));
		const { submission } = await this.call("submission.get", { id, submissionId });
		assert.equal(submission.status, "done");
		return items().find((item: any) => item.id === submission.answer).text;
	}
	async prompt(id: number): Promise<{ full: string; sections: Map<string, string> }> {
		const full = await this.answer(id, "/system full");
		assert.ok(full.startsWith("FULL\n"));
		return { full, sections: new Map(JSON.parse(full.slice(5)).sections) };
	}
}

const section = (...lines: string[]) => [
	"<project_rules>",
	"The person's rules for this project. Keep every one at every turn. Their order is only the order they are shown in; none outranks another. If two seem to conflict, or the person asks for something a rule forbids, say so and ask them.",
	...lines,
	"</project_rules>",
].join("\n");
const lead = "For you, the orchestrator:";
const all = "For every agent:";

try {
	const app = client = await Client.connect(engine, home);
	await app.until("rules greeting", () => app.events.projectRules);
	assert.deepEqual(app.order, ["projects", "projectRules"]);
	assert.deepEqual(app.events.projectRules, { event: "projectRules", projects: {} });
	for (const action of ["add", "edit", "move", "remove"]) {
		await assert.rejects(app.call(`projects.rules.${action}`, {}), { message: PREVIEW_OFF });
	}
	const { id: plain } = await app.call("conversation.create", { agentId: "forge", model: demo });
	await app.open(plain);
	const plainBefore = await app.prompt(plain);
	assert.equal(plainBefore.sections.has("project_rules"), false);

	await previewOnLeavingOut(app);
	const { id: projectId, conversation: orchestrator } = await app.call("projects.create", { folder: home });
	const { id: otherProject, conversation: unrelated } = await app.call("projects.create", { folder: null });
	const project = app.events.projects.projects.find((row: any) => row.id === projectId);
	const agent = await app.until("orchestrator profile", () => app.events.agents?.agents.find((one: any) => one.id === project.orchestratorId));
	// The orchestrator's conversation hands work to the project's other agents (#457): a copy of Scout. A sub-chat
	// inherits its parent's projectId, but runs as that copy, so only the everyone rules bind it.
	await app.call("agents.save", { agent: { ...agent, model: demo } });
	await app.call("projects.addAgent", { projectId, template: "scout" });
	await app.open(orchestrator);
	await app.open(unrelated);
	const empty = (await app.prompt(orchestrator)).sections;
	assert.equal(empty.has("project_rules"), false);
	assert.equal(empty.has("project"), true, "the project section (#466) is there, separately from the rules");
	await app.answer(orchestrator, "BEFORE-THE-RULES-SUMMARY");
	await app.answer(orchestrator, "/delegate Scout: say hello");
	const worker = (await app.until("project sub-chat", () => app.events.library?.conversations.find((row: any) => row.parent === orchestrator))).id;
	await app.open(worker);
	assert.equal((await app.prompt(worker)).sections.has("project_rules"), false);

	const action = (name: string, params: Record<string, unknown>) => app.call(`projects.rules.${name}`, { projectId, ...params });
	const add = (text: unknown, binds: unknown) => action("add", { text, binds });
	await assert.rejects(action("add", { projectId: "p-missing", text: "Valid", binds: "everyone" }), { message: "Unknown project: p-missing" });
	await assert.rejects(add("Valid", "scout"), /binds must be/);
	for (const text of [42, "   \r\n ", "x".repeat(1_001)]) await assert.rejects(add(text, "everyone"), /must be/);
	const restricted = "Read the review before you continue.\nKeep the final wording: café — exact.";
	const shared = "Give the check result in the report.";
	const { id: r1 } = await action("add", { text: `  ${restricted.replace("\n", "   \r\n \r\n\t")}  `, binds: "orchestrator", addedBy: { kind: "agent" } });
	assert.equal(r1, "r1");
	const [rule] = app.rules(projectId);
	assert.deepEqual(rule, { id: r1, text: restricted, binds: "orchestrator", addedBy: { kind: "person" }, createdAt: rule!.createdAt, updatedAt: rule!.createdAt });
	assert.equal(typeof rule!.createdAt, "number");
	assert.equal((await app.prompt(worker)).sections.has("project_rules"), false);
	assert.deepEqual(await add(shared, "everyone"), { id: "r2" });
	const both = section(lead, `1. ${restricted}`, all, `2. ${shared}`);
	const onlyShared = section(all, `2. ${shared}`);
	const prompt = (await app.prompt(orchestrator)).sections;
	assert.equal(prompt.get("project_rules"), both);
	const order = [...prompt.keys()];
	assert.ok(order.indexOf("task_list") < order.indexOf("project_rules") && order.indexOf("project_rules") < order.indexOf("project_instructions"));
	assert.equal((await app.prompt(worker)).sections.get("project_rules"), onlyShared);
	assert.equal((await app.prompt(unrelated)).sections.has("project_rules"), false);
	assert.equal((await app.prompt(plain)).full, plainBefore.full);
	const tokens = async () => (await app.call("projects.list")).projects.find((row: any) => row.id === projectId).ruleTokens;
	const count = { orchestrator: Math.ceil(both.length / 4), agents: Math.ceil(onlyShared.length / 4) };
	assert.deepEqual(await tokens(), count);
	assert.deepEqual(app.events.projects.projects.find((row: any) => row.id === projectId).ruleTokens, count);
	console.log("ok  normalized text, board numbers, scopes, estimates, and unchanged prompt and tools outside projects");

	const history = (id: number) => app.answer(id, "/system history");
	assert.match((await history(orchestrator)).split("\n").at(-1)!, /^project_rules=\d+$/);
	const before = await history(orchestrator);
	const events = app.order.length;
	assert.deepEqual(await action("edit", { id: r1, text: ` ${restricted} ` }), {});
	assert.deepEqual(await action("move", { id: r1, to: 0 }), {});
	assert.equal(app.order.length, events, "no events on a no-op");
	const rulesEvents = () => app.order.filter((event) => event === "projectRules").length;
	const sentBeforeRename = rulesEvents();
	await app.call("projects.rename", { id: projectId, name: "Renamed" });
	assert.equal(rulesEvents(), sentBeforeRename);
	const renamed = await history(orchestrator);
	assert.ok(renamed.startsWith(`${before}\n`), "no rules diff from renaming the project or a no-op");
	assert.match(renamed.slice(before.length + 1), /^project=\d+$/, "renaming changes the project section (#466) alone");
	await assert.rejects(action("move", { id: r1, to: 2 }), /to must be/);
	assert.deepEqual(await action("move", { id: r1, to: 1 }), {});
	assert.deepEqual(app.rules(projectId).map((rule) => rule.id), ["r2", r1]);
	const moved = section(all, `1. ${shared}`, lead, `2. ${restricted}`);
	assert.equal((await app.prompt(orchestrator)).sections.get("project_rules"), moved);
	assert.equal((await app.prompt(worker)).sections.get("project_rules"), section(all, `1. ${shared}`));
	assert.deepEqual(await action("edit", { id: "r2", binds: "orchestrator", text: "Give the full check result." }), {});
	assert.equal((await app.prompt(worker)).sections.has("project_rules"), false);
	const edited = section(lead, "1. Give the full check result.", `2. ${restricted}`);
	assert.equal((await app.prompt(orchestrator)).sections.get("project_rules"), edited);
	assert.equal((await tokens()).agents, 0);

	await app.answer(orchestrator, `/compaction-history ${"An old turn to summarize. ".repeat(1_000)}`);
	await app.answer(orchestrator, "A recent turn.");
	await app.call("conversation.compact", { id: orchestrator });
	await app.until("a stored summary", () => app.conversations.get(orchestrator)?.items.some((item: any) => item.details?.compaction?.trigger === "person"));
	assert.equal((await app.prompt(orchestrator)).sections.get("project_rules"), edited);
	const context = await app.answer(orchestrator, "/context");
	assert.ok(context.includes("The demo model's summary"));
	assert.ok(!context.includes("BEFORE-THE-RULES-SUMMARY"), "the old turn was compacted away");
	console.log("ok  stable section, changes in place, and exact rule text after a summary");

	await app.call("projects.archive", { id: projectId });
	for (const name of ["add", "edit", "move", "remove"]) await assert.rejects(action(name, { id: r1, text: shared, binds: "everyone", to: 0 }), { message: PROJECT_ARCHIVED });
	await app.call("projects.unarchive", { id: projectId });
	for (let i = 3; i <= 50; i++) assert.deepEqual(await add("x".repeat(1_000), "everyone"), { id: `r${i}` });
	await assert.rejects(add(shared, "everyone"), { message: "This project has 50 rules, the most it can have. Remove one first." });
	assert.deepEqual(await action("remove", { id: r1 }), {});
	await assert.rejects(action("remove", { id: r1 }), { message: `Unknown rule: ${r1}` });
	assert.deepEqual(await add(shared, "everyone"), { id: "r51" });
	for (const { id } of app.rules(projectId)) if (id !== "r51") await action("remove", { id });
	const kept = app.events.projectRules;
	await app.call("projects.setPreview", { on: false });
	assert.equal((await app.prompt(orchestrator)).sections.has("project_rules"), false);
	assert.equal((await app.prompt(worker)).sections.has("project_rules"), false);
	assert.equal((await app.prompt(plain)).full, plainBefore.full);
	other = await Client.connect(engine, home);
	assert.deepEqual(await other.until("rules greeting with preview off", () => other!.events.projectRules), kept);
	other.close();
	other = undefined;
	app.close();
	await stop(engine);
	engine = start();
	const restarted = client = await Client.connect(engine, home);
	assert.deepEqual(await restarted.until("rules after restart", () => restarted.events.projectRules), kept);
	assert.equal(restarted.events.projects.preview, false);
	await restarted.call("projects.setPreview", { on: true });
	await restarted.open(orchestrator);
	assert.equal((await restarted.prompt(orchestrator)).sections.get("project_rules"), section(all, `1. ${shared}`));
	await restarted.call("projects.delete", { id: projectId });
	await assert.rejects(restarted.call("projects.rules.remove", { projectId, id: "r51" }), { message: `Unknown project: ${projectId}` });
	assert.equal((await restarted.prompt(orchestrator)).sections.has("project_rules"), false);
	assert.equal(restarted.rules(otherProject).length, 0);
	console.log("ok  lifecycle, limit, non-reused ids, and rules kept across preview switches and restart");
} finally {
	other?.close();
	client?.close();
	await stop(engine);
	rmSync(home, { recursive: true, force: true });
}
