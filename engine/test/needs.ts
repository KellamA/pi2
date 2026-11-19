// Needs you (#462, docs/projects.md 3.9 and 5.5) through a real engine on a throwaway data folder, with the demo model,
// driven over its socket as an app would drive it.
//
// With the preview never on: the empty `needs` event after the projects', the new requests refused, and an approval
// answered exactly as before, through `inbox.decide`, once. With it on: `needs_you` offered to a project's conversation
// and to no other; a decision and a question put while the agent carries on, listed, withdrawn and answered; the answer
// waking the agent once, however many apps send it; an approval and an `ask_user` question in the same list, answered
// by either route, once; a need surviving a restart; and needs withdrawn with their conversation or project.

import assert from "node:assert/strict";
import { type ChildProcess, execFileSync, spawn } from "node:child_process";
import { mkdtempSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { GONE } from "../src/needs.ts";
import { PREVIEW_OFF } from "../src/projects.ts";
import { EngineClient, standInApp, stop } from "./patience.ts";

const home = mkdtempSync(join(tmpdir(), "pi2-needs-"));
const work = realpathSync(mkdtempSync(join(tmpdir(), "pi2-needs-work-")));
const main = join(import.meta.dirname, "..", "src", "main.ts");
const KEYCHAIN_SERVICE = `dev.pi2.credentials.test-needs-${process.pid}`;
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

type Event = Record<string, any>;
class Client extends EngineClient {
	/** The events' names, in the order they came. */
	order: string[] = [];
	override receive(message: any): void {
		if (typeof message.event === "string") this.order.push(message.event);
		super.receive(message);
	}
	items(id: number, kind: string): Event[] {
		return this.conversations.get(id)?.items.filter((item: Event) => item.kind === kind) ?? [];
	}
	idle(id: number): boolean {
		const conv = this.conversations.get(id);
		return conv !== undefined && !conv.state.busy;
	}
	/** What the demo model answers to `text`, once its run is over. */
	async answer(id: number, text: string): Promise<string> {
		const before = this.items(id, "assistant").length;
		await this.call("submit", { id, text });
		await this.until(`answer to ${text}`, () => this.idle(id) && this.items(id, "assistant").length > before);
		return this.items(id, "assistant").at(-1)!.text as string;
	}
	/** Sends a message the demo model answers with a tool call, and returns that call's result once the answer is in. */
	async tool(id: number, text: string): Promise<Event> {
		const count = this.items(id, "tool").length + 1;
		await this.call("submit", { id, text });
		return await this.until(`result of ${text}`, () => {
			const conv = this.conversations.get(id);
			const results = this.items(id, "tool");
			if (conv === undefined || conv.state.busy || results.length < count) return undefined;
			const after = conv.items.slice(conv.items.indexOf(results[count - 1]) + 1);
			return after.some((item: Event) => item.kind === "assistant") ? results[count - 1] : undefined;
		});
	}
	/** `needs_you` called by the demo model in conversation `id`. */
	needsYou(id: number, args: Record<string, unknown>): Promise<Event> {
		return this.tool(id, `/tool needs_you ${JSON.stringify(args)}`);
	}
	/** The tools a conversation is offered, by name. */
	async offered(id: number): Promise<string[]> {
		const said = await this.answer(id, "/system none");
		return said.slice(said.indexOf("TOOLS: ") + 7).split(", ");
	}
	get needs(): Event[] {
		return this.events.needs?.items ?? [];
	}
	need(id: string): Event | undefined {
		return this.needs.find((item) => item.id === id);
	}
	wakes(id: number): Event[] {
		return this.items(id, "marker").filter((item) => (item.text as string).startsWith("pi² woke the agent"));
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
	await client.until("providers", () => client.events.providers && client.events.agents && client.events.needs);

	// ---- With the preview never turned on

	assert.deepEqual(client.events.needs, { event: "needs", items: [] });
	assert.ok(client.order.indexOf("needs") > client.order.indexOf("projects"), client.order.join(" "));
	await refused(client.call("needs.list"), PREVIEW_OFF);
	await refused(client.call("needs.answer", { id: "n1", answer: { kind: "question", text: "x" } }), PREVIEW_OFF);
	// An approval, as today: in the Inbox, answered through inbox.decide, once; nothing in Needs you.
	const plain = (await client.call("conversation.create", { agentId: "forge" })).id as number;
	await client.call("conversation.open", { id: plain });
	const ran = client.tool(plain, "/bash echo as-before");
	const before = await client.until("an approval", () => client.events.inbox?.items?.find((item: Event) => item.conversationId === plain));
	assert.equal(before.kind, "approval");
	assert.deepEqual(client.needs, []);
	await client.call("inbox.decide", { id: before.id, decision: "once" });
	await refused(client.call("inbox.decide", { id: before.id, decision: "deny" }), GONE);
	assert.match((await ran).text, /as-before/);
	assert.deepEqual(client.needs, []);
	assert.equal((await client.offered(plain)).includes("needs_you"), false);
	step("with the preview never on: the empty needs event after the projects', new requests refused, approvals as before");

	// ---- The preview on, and a project

	await client.call("projects.setPreview", { on: true });
	const project = await client.call("projects.create", { folder: work });
	const orchestrator = project.conversation as number;
	await client.call("conversation.open", { id: orchestrator });
	assert.ok((await client.offered(orchestrator)).includes("needs_you"), "offered in the orchestrator's conversation");
	assert.equal((await client.offered(plain)).includes("needs_you"), false, "and not in a conversation in no project");
	step("needs_you is offered to a project's conversation, and to no conversation in no project");

	// A decision put, and the agent carries on: the call returns at once, and the agent answers the next message.
	const decision = await client.needsYou(orchestrator, { action: "ask", question: "Merge #503 now or after the release?", choices: ["Now", "After the release"] });
	assert.equal(decision.isError, false, decision.text);
	assert.equal(decision.text, "Put to the person as n1. Carry on with what does not depend on it; their answer will come to you as a message.");
	const n1 = await client.until("n1 under Needs you", () => client.need("n1"));
	assert.deepEqual(
		{ ...n1, createdAt: 0 },
		{
			id: "n1",
			kind: "decision",
			projectId: project.id,
			conversationId: orchestrator,
			rootConversationId: orchestrator,
			title: client.events.library.conversations.find((row: Event) => row.id === orchestrator).title,
			rootTitle: client.events.library.conversations.find((row: Event) => row.id === orchestrator).title,
			agentId: client.events.projects.projects[0].orchestratorId,
			agentName: "Orchestrator",
			blocking: false,
			createdAt: 0,
			question: "Merge #503 now or after the release?",
			choices: [
				{ id: "c1", label: "Now" },
				{ id: "c2", label: "After the release" },
			],
			words: true,
		},
	);
	assert.ok(client.idle(orchestrator), "not held");
	assert.match(await client.answer(orchestrator, "carrying on"), /carrying on/);
	assert.ok(client.need("n1"), "still waiting");
	step("needs_you ask puts a decision under Needs you and the agent carries on");

	// A question, listed, withdrawn; refusals.
	const question = await client.needsYou(orchestrator, { action: "ask", question: "Which colour?" });
	assert.match(question.text, /^Put to the person as n2\./);
	await client.until("n2", () => client.need("n2")?.kind === "question");
	const list = await client.needsYou(orchestrator, { action: "list" });
	assert.equal(list.text, "Waiting for the person, oldest first:\n- n1: “Merge #503 now or after the release?”, choices: Now, After the release, or an answer in words\n- n2: “Which colour?”");
	assert.equal((await client.needsYou(orchestrator, { action: "withdraw", id: "n2" })).text, "Withdrew n2. The person no longer sees it.");
	await client.until("n2 gone", () => client.need("n2") === undefined);
	const again = await client.needsYou(orchestrator, { action: "withdraw", id: "n2" });
	assert.equal(again.isError, true);
	await refused(client.call("needs.answer", { id: "n2", answer: { kind: "question", text: "Red" } }), GONE);
	assert.equal((await client.needsYou(orchestrator, { action: "ask", question: "Pick", choices: ["Only one"] })).isError, true);
	assert.equal((await client.needsYou(orchestrator, { action: "ask", question: "x".repeat(2001) })).isError, true);
	assert.equal((await client.needsYou(orchestrator, { action: "shout" })).isError, true);
	step("needs_you list and withdraw; a withdrawn item cannot be answered; what it refuses");

	// An approval and an ask_user question are in the same list, blocking, and answered once by either route.
	const asked = client.tool(orchestrator, "/bash echo in-the-project");
	const approval = await client.until("the approval under Needs you", () => client.needs.find((item) => item.kind === "approval"));
	assert.equal(approval.projectId, project.id);
	assert.equal(approval.blocking, true);
	assert.equal(approval.tool, "bash");
	assert.ok(approval.answers.includes("once") && approval.answers.includes("deny"), approval.answers);
	assert.equal(client.events.inbox.items.find((item: Event) => item.id === approval.id)?.kind, "approval", "and still in the Inbox for the old screens");
	await refused(client.call("needs.answer", { id: approval.id, answer: { kind: "question", text: "yes" } }), "This is a request for approval, not a question");
	await client.call("needs.answer", { id: approval.id, answer: { kind: "approval", decision: "once" } });
	await refused(client.call("inbox.decide", { id: approval.id, decision: "deny" }), GONE);
	assert.match((await asked).text, /in-the-project/);
	const askUser = client.tool(orchestrator, "/ask Which branch?");
	const held = await client.until("the ask_user question", () => client.needs.find((item) => item.kind === "question" && item.blocking));
	assert.equal(held.question, "Which branch?");
	await client.call("inbox.answer", { id: held.id, text: "main" });
	await refused(client.call("needs.answer", { id: held.id, answer: { kind: "question", text: "dev" } }), GONE);
	assert.equal((await askUser).text, "main");
	await client.until("only n1 left", () => client.needs.length === 1);
	step("an approval and an ask_user question are listed too, blocking, and taken once by either route");

	// Two apps answer the same decision at once: one is taken, the other finds it gone; the agent is woken once.
	second = await Client.connect(engine, home);
	await second.until("the second app's list", () => second!.need("n1"));
	await refused(client.call("needs.answer", { id: "n1", answer: { kind: "decision", choice: "c3" } }), "There is no choice c3 in this decision");
	const answers = await Promise.allSettled([
		client.call("needs.answer", { id: "n1", answer: { kind: "decision", choice: "c2" } }),
		second.call("needs.answer", { id: "n1", answer: { kind: "decision", text: "Now, please" } }),
	]);
	assert.deepEqual(answers.map((one) => one.status).sort(), ["fulfilled", "rejected"]);
	assert.equal((answers.find((one) => one.status === "rejected") as PromiseRejectedResult).reason.message, GONE);
	const won = answers[0]!.status === "fulfilled" ? "After the release." : "Now, please.";
	await client.until("woken", () => client.wakes(orchestrator).length === 1 && client.idle(orchestrator));
	const wake = client.wakes(orchestrator)[0]!;
	assert.equal(wake.text, "pi² woke the agent: the question “Merge #503 now or after the release?” was answered");
	assert.equal(wake.details.wake.text, `[pi² woke you: this ended while you were not answering.]\n\nThe person answered your question “Merge #503 now or after the release?”: ${won}`);
	await second.until("gone from the second app too", () => second!.need("n1") === undefined);
	assert.equal(client.wakes(orchestrator).length, 1);
	step("two apps answer at once: one answer is taken, and wakes the agent once with it");

	// ---- A need survives a restart, and its answer still wakes the agent

	await client.needsYou(orchestrator, { action: "ask", question: "Ship it?", choices: ["Yes", "No"], words: false });
	await client.until("n3", () => client.need("n3"));
	await refused(client.call("needs.answer", { id: "n3", answer: { kind: "decision", text: "Maybe" } }), "This decision takes one of its choices, not an answer in words");
	second.close();
	second = undefined;
	client.close();
	await stop(engine);
	engine = start();
	client = await Client.connect(engine, home);
	const kept = await client.until("n3 after the restart", () => client.need("n3"));
	assert.equal(kept.words, false);
	assert.equal(kept.question, "Ship it?");
	await client.call("conversation.open", { id: orchestrator });
	await client.until("the conversation", () => client.conversations.get(orchestrator)?.items.length > 0);
	await client.call("needs.answer", { id: "n3", answer: { kind: "decision", choice: "c1" } });
	await client.until("woken after the restart", () => client.wakes(orchestrator).length === 2 && client.idle(orchestrator));
	assert.match(client.wakes(orchestrator)[1]!.details.wake.text, /answered your question “Ship it\?”: Yes\.$/);
	step("a need survives a restart, and its answer wakes the agent");

	// ---- needs.list, and the preview off and on

	await client.needsYou(orchestrator, { action: "ask", question: "Still there?" });
	await client.until("n4", () => client.need("n4"));
	assert.deepEqual((await client.call("needs.list", { projectId: project.id })).items, client.needs);
	assert.deepEqual((await client.call("needs.list")).items, client.needs);
	await refused(client.call("needs.list", { projectId: "p-nothing" }), "Unknown project: p-nothing");
	await client.call("projects.setPreview", { on: false });
	await client.until("the empty list with the preview off", () => client.needs.length === 0);
	assert.equal((await client.offered(orchestrator)).includes("needs_you"), false, "not offered with the preview off");
	await client.call("projects.setPreview", { on: true });
	await client.until("back with the preview on", () => client.need("n4"));
	step("needs.list of one project or all; the list is empty with the preview off, and comes back with it on");

	// ---- Withdrawn with its conversation, and with its project

	const other = (await client.call("conversation.create", { agentId: client.events.projects.projects[0].orchestratorId })).id as number;
	await client.call("conversation.open", { id: other });
	await client.needsYou(other, { action: "ask", question: "From the other conversation?" });
	await client.until("n5", () => client.need("n5"));
	await client.call("conversation.archive", { id: other });
	await client.until("n5 withdrawn with its conversation", () => client.need("n5") === undefined);
	assert.ok(client.need("n4"), "the others stay");
	await client.call("projects.delete", { id: project.id });
	await client.until("n4 withdrawn with its project", () => client.needs.length === 0);
	step("a need is withdrawn when its conversation is archived, or its project deleted");
} finally {
	second?.close();
	client.close();
	await stop(engine);
}
