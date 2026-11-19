// Project memory (#461), through a real engine and the demo model, with its own data and Keychain service.
import assert from "node:assert/strict";
import { type ChildProcess, spawn } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { BACKGROUND_CONTEXT as context } from "@earendil-works/chord/context";
import { createModels } from "@earendil-works/pi-ai";
import { createRegistry, Harness } from "@earendil-works/pi-durable";
import { openNodeSqliteStorage } from "@earendil-works/pi-durable/storage/sqlite/node";
import { MAX_NOTES, Memory } from "../src/knowledge.ts";
import { projectNotebook, type ProjectNote } from "../src/projectnotes.ts";
import { PREVIEW_OFF, PROJECT_ARCHIVED, Projects } from "../src/projects.ts";
import { Agents } from "../src/state.ts";
import { EngineClient, previewOn, previewOnLeavingOut, standInApp, stop } from "./patience.ts";

const home = mkdtempSync(join(tmpdir(), "pi2-notes-"));
const env = { ...process.env, PI2_HOME: home, PI2_KEYCHAIN_SERVICE: `dev.pi2.credentials.test-projectnotes-${process.pid}`, PI2_LOGIN_SHELL: "off", PI2_DEMO_TOKENS_PER_SECOND: "100000", PI2_APP_BUNDLE: standInApp() };
const start = () => spawn(process.execPath, [join(import.meta.dirname, "../src/main.ts")], { env, stdio: ["ignore", "ignore", "inherit"] });
let engine: ChildProcess | undefined;
process.on("exit", () => {
	if (engine !== undefined && engine.exitCode === null && engine.signalCode === null) engine.kill("SIGKILL");
	// The test uses only the demo model and makes no Keychain items.
	rmSync(home, { recursive: true, force: true });
});

class Client extends EngineClient {
	notes(projectId: string): ProjectNote[] {
		return this.events.memory?.projects?.[projectId]?.notes ?? [];
	}
	async answer(id: number, text: string): Promise<string> {
		const assistants = () => (this.conversations.get(id)?.items ?? []).filter((item: any) => item.kind === "assistant");
		const before = assistants().length;
		await this.call("submit", { id, text });
		await this.until(`answer to ${text}`, () => this.conversations.get(id)?.state?.busy === false && assistants().length > before);
		return assistants().at(-1).text;
	}
	async prompt(id: number) {
		const answer = await this.answer(id, "/system full");
		assert.ok(answer.startsWith("FULL\n"), answer.slice(0, 200));
		return JSON.parse(answer.slice(5)) as { sections: [string, string][]; tools: { name: string }[] };
	}
	async memory(id: number) {
		return (await this.prompt(id)).sections.find(([key]) => key === "memory")?.[1] ?? "";
	}
	async tool(id: number, name: string, args: Record<string, unknown>) {
		await this.answer(id, `/tool ${name} ${JSON.stringify(args)}`);
		const tool = this.conversations.get(id).items.filter((item: any) => item.kind === "tool").at(-1);
		assert.equal(tool?.name, name);
		return tool;
	}
	async create(params: Record<string, unknown>) {
		const { id } = await this.call("conversation.create", params);
		await this.call("conversation.open", { id });
		return id as number;
	}
}

let client: Client | undefined;
let other: Client | undefined;
try {
	engine = start();
	client = await Client.connect(engine, home);
	await client.until("memory greeting", () => client!.events.memory);
	assert.deepEqual(client.events.memory.projects, {});
	const methods = ["memory.add", "memory.edit", "memory.delete"];
	for (const method of methods) await assert.rejects(client.call(method, { projectId: "p-missing" }), { message: PREVIEW_OFF });
	const legacy = await client.call("memory.add", { agentId: "forge", text: "Only Forge remembers this." });
	assert.equal(legacy.id, "m1");
	await client.call("memory.setEnabled", { agentId: "forge", enabled: true });
	await client.call("memory.add", { chat: true, text: "Only chat remembers this." });
	await previewOnLeavingOut(client);
	for (const method of methods) {
		await assert.rejects(client.call(method, { projectId: "constructor" }), { message: "Unknown project: constructor" });
		await assert.rejects(client.call(method, { projectId: true }), /projectId must be/);
		await assert.rejects(client.call(method, { projectId: "p-missing", chat: true }), /in place of/);
	}
	const { id: projectId, conversation: first } = await client.call("projects.create", { folder: null, name: "Notes", template: "forge" });
	const { id: otherId } = await client.call("projects.create", { folder: null, name: "Other notes" });
	const { id: overflow } = await client.call("projects.create", { folder: null, name: "Carried notes fixture" });
	const { orchestratorId: author } = (await client.call("projects.list")).projects.find((p: any) => p.id === projectId);
	await client.call("conversation.open", { id: first });
	assert.deepEqual(client.events.memory.projects, {}, "turning on and copying a template never carries its notes over before #458");
	assert.doesNotMatch(await client.memory(first), /Only Forge/);

	other = await Client.connect(engine, home);
	await other.until("the second greeting", () => other!.events.memory);
	const { id: privateId } = await client.call("memory.add", { projectId, text: " First line \n\nSecond   line " });
	assert.equal(privateId, "n1");
	const [byPerson] = await other.until("the other app's note event", () => other!.notes(projectId).length > 0 && other!.notes(projectId));
	assert.deepEqual(byPerson, { id: "n1", text: "First line\nSecond line", createdAt: byPerson!.createdAt, conversation: null, agentId: null, audience: null });
	await assert.rejects(client.call("memory.edit", { projectId, id: privateId, audience: "forge" }), { message: "Unknown agent: forge" });
	await assert.rejects(client.call("memory.edit", { projectId, id: privateId, audience: 1 }), /audience must be/);
	await assert.rejects(client.call("memory.edit", { projectId, id: privateId, text: "x".repeat(401) }), /400 characters at most/);
	await assert.rejects(client.call("memory.add", { projectId, text: " " }), /Write the note first/);
	await client.call("memory.edit", { projectId, id: privateId, audience: author });
	assert.match(await client.memory(first), /n1 \(for you alone\): First line\n  Second line/);

	const saved = await client.tool(first, "remember", { note: "Shared   from\nthe first conversation." });
	assert.ok(!saved.isError, JSON.stringify(saved));
	assert.match(saved.text, /Noted \(n2\)/);
	// The record of changes (#465) gives the note its change, and the conversation a line for it, with Undo.
	assert.equal(typeof saved.details?.change, "number", JSON.stringify(saved.details));
	const app = client;
	const line = await app.until("the note's line", () => app.conversations.get(first)?.state.projectChanges?.find((one: any) => one.id === saved.details.change));
	assert.deepEqual(line, { id: saved.details.change, summary: "Remembered project note n2", undone: false, canUndo: true, noUndo: null });
	assert.deepEqual(client.notes(projectId)[1], { id: "n2", text: "Shared from the first conversation.", createdAt: client.notes(projectId)[1]!.createdAt, conversation: first, agentId: author, audience: null });
	assert.match((await client.tool(first, "remember", { note: "SHARED from the first conversation." })).text, /already have that note \(n2\)/);
	assert.equal((await client.call("memory.add", { projectId: otherId, text: "Only the other project reads this." })).id, "n1");
	assert.doesNotMatch(await client.memory(first), /Only the other/);
	// With the preview on, a template's conversation goes into a project as it is made (#458, docs/projects.md 9.9); with
	// it off, it reads its agent's own notes, as before projects. Turned on again with the plan that carries it over.
	await client.call("projects.setPreview", { on: false });
	const template = await client.create({ agentId: "forge" });
	assert.match(await client.memory(template), /Only Forge/);
	assert.doesNotMatch(await client.memory(template), /Shared from/);
	await previewOn(client);
	const chat = await client.create({ chat: true });
	assert.match(await client.memory(chat), /Only chat/);
	const lookedUp = await client.tool(chat, "agent_notes", {});
	assert.match(lookedUp.text, /Only Forge/);
	assert.doesNotMatch(lookedUp.text, /Shared from|First line/);
	console.log("ok  types, limits, events, note metadata, and legacy isolation; until #458 no carry; a change id and line since #465");

	other.close();
	other = undefined;
	client.close();
	await stop(engine);
	// #457's tools to make another agent and change the orchestrator need not have landed. Add another member and a
	// carried-notes fixture (#458) offline, in the same isolated database the socket tests use.
	const storage = await openNodeSqliteStorage(join(home, "session.sqlite"));
	const harness = await Harness.open(storage, { registry: createRegistry(), models: createModels() }, context);
	const reviewer = "note-reviewer";
	try {
		await harness.commit(async (tx) => {
			const { agents } = await tx.doc(Agents);
			agents[reviewer] = { ...JSON.parse(JSON.stringify(agents[author])), id: reviewer, name: "Note reviewer", role: "agent", delegates: [] };
			agents[author]!.delegates = [reviewer];
			const memory = await tx.doc(Memory);
			memory.agents[reviewer] = { enabled: true, notes: [], next: 1 };
			const book = projectNotebook(memory, overflow);
			for (let i = 1; i <= MAX_NOTES + 1; i++) {
				book.notes.push({ id: `n${book.next++}`, text: `Carried note ${i}`, createdAt: i, conversation: null, agentId: "forge", audience: null, carriedFrom: { agentId: "forge", agentName: "Forge", id: `m${i}` } });
			}
		}, context);
	} finally {
		await harness.close(context);
	}
	engine = start();
	const c = client = await Client.connect(engine, home);
	await c.until("the restarted greeting", () => c.events.memory);
	assert.equal(c.notes(projectId).length, 2);
	assert.equal(c.notes(overflow).length, MAX_NOTES + 1);
	assert.equal(c.notes(overflow).at(-1)?.carriedFrom?.id, `m${MAX_NOTES + 1}`);
	await assert.rejects(c.call("memory.add", { projectId: overflow, text: "At 61" }), /already 60/);
	await c.call("memory.delete", { projectId: overflow, id: "n1" });
	await assert.rejects(c.call("memory.add", { projectId: overflow, text: "At 60" }), /already 60/);
	await c.call("memory.delete", { projectId: overflow, id: "n2" });
	assert.equal((await c.call("memory.add", { projectId: overflow, text: "At 59" })).id, `n${MAX_NOTES + 2}`);

	await c.call("conversation.open", { id: first });
	const later = await c.create({ agentId: reviewer });
	const prompt = await c.memory(later);
	assert.match(prompt, /n2: Shared from the first conversation/);
	assert.doesNotMatch(prompt, /n1|First line|Only Forge|Only the other/);
	const hidden = await c.tool(later, "forget", { id: privateId });
	assert.match(hidden.text, /^There is no note n1\. Your notes: n2\./);
	assert.ok(hidden.isError);
	assert.equal(c.notes(projectId).length, 2);
	const emptyChild = await c.answer(first, '/delegate Note reviewer: /tool remember {"note":"Written in a sub-chat."}');
	assert.ok(emptyChild.length > 0);
	const child = await c.until("the sub-chat's note", () => c.notes(projectId).find((n) => n.text === "Written in a sub-chat."));
	assert.equal(child.agentId, reviewer);
	assert.notEqual(child.conversation, first);
	assert.notEqual(child.conversation, later);
	assert.match(await c.memory(later), /Written in a sub-chat/);
	await c.call("memory.setEnabled", { agentId: reviewer, enabled: false });
	const off = await c.prompt(later);
	assert.ok(!off.sections.some(([name]) => name === "memory"));
	assert.ok(!off.tools.some(({ name }) => name === "remember" || name === "forget"));
	await c.call("memory.setEnabled", { agentId: reviewer, enabled: true });
	await c.call("memory.edit", { projectId, id: privateId, audience: null, text: "Now shared." });
	assert.match(await c.memory(later), /n1: Now shared/);
	const deleted = await c.tool(later, "forget", { id: privateId });
	assert.match(deleted.text, /^Forgot n1\./);
	assert.equal(typeof deleted.details?.change, "number");
	assert.doesNotMatch(await c.memory(first), /Now shared/);
	console.log("ok  restart, carried-note limits, cross-agent sharing, audience and switch, and sub-chats");

	// bash makes this round ordered. Switch the preview while bash waits, before remember has run.
	const round = c.answer(first, `/tools ${JSON.stringify([
		{ name: "bash", arguments: { command: "echo should-not-run" } },
		{ name: "remember", arguments: { note: "This turn stays in the project." } },
	])}`);
	const waiting = await c.until("the ordered round's approval", () => c.events.inbox?.items?.find((item: any) => item.conversationId === first && item.tool === "bash"));
	await c.call("projects.setPreview", { on: false });
	await c.call("inbox.decide", { id: waiting.id, decision: "deny" });
	await round;
	assert.ok(c.notes(projectId).some((n) => n.text === "This turn stays in the project."));
	assert.match(await c.memory(first), /your own notes from earlier conversations/);
	assert.match(await c.memory(later), /your own notes from earlier conversations/);
	assert.doesNotMatch(await c.memory(later), /Written in a sub-chat/);
	assert.match((await c.tool(later, "remember", { note: "Legacy after turning off." })).text, /Noted \(m1\)/);
	for (const method of methods) await assert.rejects(c.call(method, { projectId }), { message: PREVIEW_OFF });
	assert.ok(c.notes(projectId).some((n) => n.text === "Written in a sub-chat."), "switching off does not hide the field from apps");
	await c.call("projects.setPreview", { on: true });
	assert.doesNotMatch(await c.memory(later), /Legacy after turning off/);
	await c.call("projects.archive", { id: projectId });
	for (const method of methods) await assert.rejects(c.call(method, { projectId }), { message: PROJECT_ARCHIVED });
	await c.call("projects.delete", { id: projectId });
	for (const method of methods) await assert.rejects(c.call(method, { projectId }), { message: `Unknown project: ${projectId}` });
	assert.doesNotMatch(await c.memory(later), /Written in a sub-chat/);
	console.log("ok  preview off keeps legacy memory; archived and deleted projects cannot be edited");
} finally {
	other?.close();
	client?.close();
	if (engine !== undefined) await stop(engine);
}
