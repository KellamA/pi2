// A project's conversation runs on the model and thinking of the agent it runs as, read at each message (#726;
// docs/projects.md 3.4): a real engine on a throwaway data folder, driven over its socket with the demo models and a
// stand-in provider on 127.0.0.1, as an app would drive it.
//
// A project agent's model is changed with two of its conversations existing, one idle and one in the middle of a run:
// the idle one says the new model at once and its next message runs on it; the running one finishes on the old one and
// runs on the new one after. The orchestrator's conversation follows its agent the same way. A conversation given a
// model of its own through the socket (`ownModel`), a chat and a conversation in no project keep theirs. A model chosen
// with Carry on with… holds for that run alone, and is not remembered as the default for agents.

import assert from "node:assert/strict";
import { type ChildProcess, execFileSync, spawn } from "node:child_process";
import { mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { EngineClient, leaveOut, standInApp, stop } from "./patience.ts";

const home = mkdtempSync(join(tmpdir(), "pi2-agentmodel-"));
const scratch = realpathSync(mkdtempSync(join(tmpdir(), "pi2-agentmodel-work-")));
const main = join(import.meta.dirname, "..", "src", "main.ts");
const KEYCHAIN_SERVICE = `dev.pi2.credentials.test-agentmodel-${process.pid}`;
process.env.PI2_DEMO_TOKENS_PER_SECOND ??= "100000";
const env = { ...process.env, PI2_HOME: home, PI2_KEYCHAIN_SERVICE: KEYCHAIN_SERVICE, PI2_LOGIN_SHELL: "off", PI2_DEMO_TEXT_MODEL: "1", PI2_APP_BUNDLE: standInApp() };

/** Lets every command still waiting go, so that none outlives the test. */
const all = join(scratch, "all-gates");
let engine: ChildProcess | undefined;
process.on("exit", () => {
	writeFileSync(all, "");
	if (engine !== undefined && engine.exitCode === null && engine.signalCode === null) engine.kill("SIGKILL");
	rmSync(home, { recursive: true, force: true });
	rmSync(scratch, { recursive: true, force: true });
	try {
		while (true) execFileSync("/usr/bin/security", ["delete-generic-password", "-s", KEYCHAIN_SERVICE], { stdio: "ignore" });
	} catch {
		// None left.
	}
});

function step(name: string): void {
	console.log(`ok  ${name}`);
}

type Ref = { provider: string; modelId: string };
const demo: Ref = { provider: "demo", modelId: "demo-1" };
const text: Ref = { provider: "demo", modelId: "demo-text" };

// The stand-in provider: a request whose last message is "carry on here" is refused once, for an hour, which the
// engine waits for; everything else is answered with a line of its own.
const requests: Record<string, number> = {};
const standIn = createServer((request, response) => {
	if (request.method === "GET" && request.url === "/v1/models") {
		response.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({ object: "list", data: [{ id: "stand-in", object: "model" }] }));
		return;
	}
	let body = "";
	request.setEncoding("utf8").on("data", (chunk: string) => (body += chunk));
	request.on("end", () => {
		const users = (JSON.parse(body).messages as { role: string; content: unknown }[]).filter((m) => m.role === "user");
		const last = users.at(-1)?.content;
		const prompt = typeof last === "string" ? last : (last as { text?: string }[]).map((part) => part.text ?? "").join("");
		const n = requests[prompt] ?? 0;
		requests[prompt] = n + 1;
		if (prompt === "carry on here" && n === 0) {
			const refusal = { error: { type: "rate_limit_error", message: "This request would exceed your account's rate limit. Please try again later." } };
			response.writeHead(429, { "content-type": "application/json", "retry-after": "3600" }).end(JSON.stringify(refusal));
			return;
		}
		response.writeHead(200, { "content-type": "text/event-stream" });
		const chunk = (delta: object, finish: string | null) =>
			response.write(`data: ${JSON.stringify({ id: "c1", object: "chat.completion.chunk", created: 1, model: "stand-in", choices: [{ index: 0, delta, finish_reason: finish }] })}\n\n`);
		chunk({ role: "assistant", content: `The stand-in answered ${prompt}.` }, null);
		chunk({}, "stop");
		response.end("data: [DONE]\n\n");
	});
});
await new Promise<void>((resolve) => standIn.listen(0, "127.0.0.1", resolve));
const standInUrl = `http://127.0.0.1:${(standIn.address() as { port: number }).port}/v1`;

type Item = { kind: string; text: string; stop?: string; model?: string | null };
class Client extends EngineClient {
	agent(id: string): any {
		return this.events.agents?.agents?.find((agent: any) => agent.id === id);
	}
	state(id: number): any {
		return this.conversations.get(id)?.state;
	}
	/** What the engine says conversation `id` runs on now, or at its next message. */
	model(id: number): Ref | undefined {
		return this.state(id)?.agent.model;
	}
	answers(id: number): Item[] {
		return (this.conversations.get(id)?.items ?? []).filter((item: Item) => item.kind === "assistant" && item.stop === "stop");
	}
	async open(id: number): Promise<void> {
		await this.call("conversation.open", { id });
		await this.until(`conversation ${id} open`, () => this.state(id));
	}
	/** Sends a message and answers the model that wrote the answer, once the run has ended. */
	async answeredBy(id: number, message: string): Promise<string | null | undefined> {
		const before = this.answers(id).length;
		await this.call("submit", { id, text: message });
		return (await this.until(`the answer to ${message}`, () => (this.answers(id).length > before && this.state(id)?.busy === false ? this.answers(id).at(-1) : undefined))).model;
	}
	/** Saves an agent's model and thinking level, as the hub's menus and the agent's page do (`agents.save`). */
	async setModel(agentId: string, model: Ref, thinkingLevel?: string): Promise<void> {
		await this.call("agents.save", { agent: { id: agentId, name: this.agent(agentId).name, model, ...(thinkingLevel === undefined ? {} : { thinkingLevel }) } });
		await this.until(`${agentId} saved`, () => this.agent(agentId)?.model?.modelId === model.modelId && (thinkingLevel === undefined || this.agent(agentId)?.thinkingLevel === thinkingLevel));
	}
}

const same = (a: Ref | null | undefined, b: Ref) => a?.provider === b.provider && a?.modelId === b.modelId;

engine = spawn(process.execPath, [main], { env, stdio: ["ignore", "ignore", "inherit"] });
const client = await Client.connect(engine, home);
try {
	const c = client;
	await c.until("first events", () => c.events.providers && c.events.agents && c.events.projects);

	// ---- In no project, and chats: their own model, as before

	// A template's conversation in no project: the project carrying over made for it is deleted (`leaveOut`).
	const plain = (await c.call("conversation.create", { agentId: "atlas" })).id as number;
	await leaveOut(c);
	const chat = (await c.call("conversation.create", { chat: true })).id as number;
	await c.open(plain);
	await c.open(chat);
	const plainBefore = c.model(plain)!;
	const chatBefore = c.model(chat)!;
	assert.ok(same(plainBefore, demo) && same(chatBefore, demo), `both start on the demo model: ${JSON.stringify([plainBefore, chatBefore])}`);

	// ---- A project agent with two conversations, one idle and one in the middle of a run

	const project = await c.call("projects.create", { folder: scratch });
	const projectId = project.id as string;
	const orchestrator = project.conversation as number;
	const builder = (await c.call("projects.addAgent", { projectId, agent: { name: "Builder", model: demo, access: "full" } })).id as string;
	await c.until("Builder", () => c.agent(builder));
	const idle = (await c.call("conversation.create", { agentId: builder })).id as number;
	const busy = (await c.call("conversation.create", { agentId: builder })).id as number;
	// One given a model of its own through the socket keeps it (`ownModel`): the app never does this in a project.
	const own = (await c.call("conversation.create", { agentId: builder, model: demo })).id as number;
	for (const id of [idle, busy, own, orchestrator]) await c.open(id);
	assert.equal(await c.answeredBy(idle, "hello"), "demo-1");
	assert.equal(await c.answeredBy(own, "hello"), "demo-1");

	const gate = join(scratch, "gate");
	await c.call("submit", { id: busy, text: `/bash until [ -e '${gate}' ] || [ -e '${all}' ]; do sleep 0.05; done; echo built` });
	await c.until("the command running", () => c.state(busy)?.busy === true && c.state(busy)?.tools.some((tool: any) => tool.name === "bash" && tool.status === "running"));

	await c.setModel(builder, text, "low");
	// What the engine sends for each is what it runs on next: the idle one the agent's new model at once, the running one
	// the model its run has.
	await c.until("the idle one says the agent's new model", () => same(c.model(idle), text) && c.state(idle).agent.thinkingLevel === "low");
	assert.ok(same(c.model(busy), demo), "the running one says the model its run has");
	assert.ok(same(c.model(own), demo), "one with a model of its own keeps it");
	assert.equal(await c.answeredBy(idle, "again"), "demo-text", "the idle one's next message runs on the new model");
	assert.equal(c.state(idle).agent.thinkingLevel, "low");
	assert.ok(same(c.model(busy), demo) && c.state(busy).busy === true, "the running one is still on its old model");
	step("an agent's model changed: its idle conversation says the new one at once and its next message runs on it");

	writeFileSync(gate, "");
	await c.until("the run finished", () => c.state(busy)?.busy === false && c.answers(busy).length > 0);
	assert.equal(c.answers(busy).at(-1)!.model, "demo-1", "the run finished on the model it started on");
	await c.until("then it says the agent's model", () => same(c.model(busy), text));
	assert.equal(await c.answeredBy(busy, "and now"), "demo-text", "and its next message runs on the new one");
	assert.equal(await c.answeredBy(own, "still"), "demo-1", "one with a model of its own keeps it");
	step("a conversation working as its agent's model changed finishes on the old model, and runs on the new one after");

	// The orchestrator's conversation follows its agent: the hub's bar changes the agent alone.
	const orchestratorId = (await c.call("projects.list")).projects.find((row: any) => row.id === projectId).orchestratorId as string;
	assert.equal(await c.answeredBy(orchestrator, "hello"), "demo-1");
	await c.setModel(orchestratorId, text);
	await c.until("the orchestrator's conversation says its agent's model", () => same(c.model(orchestrator), text));
	assert.equal(await c.answeredBy(orchestrator, "again"), "demo-text");
	step("the orchestrator's conversation follows its agent's model");

	// The template the conversation in no project runs as, and chat mode, are not the project's agents.
	await c.setModel("atlas", text);
	assert.ok(same(c.model(plain), plainBefore), "a conversation in no project keeps its own model");
	assert.ok(same(c.model(chat), chatBefore), "a chat keeps its own model");
	assert.equal(await c.answeredBy(plain, "hello"), "demo-1");
	assert.equal(await c.answeredBy(chat, "hello"), "demo-1");
	step("a conversation in no project and a chat keep their own models");

	// ---- Carry on with…: for that run alone

	const { id: provider } = await c.call("endpoints.save", { name: "Stand-in", baseUrl: standInUrl, api: "openai-completions", models: [{ id: "stand-in" }] });
	await c.until("the stand-in offered", () => c.events.providers.models.some((model: any) => model.provider === provider));
	const standInModel: Ref = { provider, modelId: "stand-in" };
	const waiter = (await c.call("projects.addAgent", { projectId, agent: { name: "Waiter", model: standInModel } })).id as string;
	await c.until("Waiter", () => c.agent(waiter));
	const held = (await c.call("conversation.create", { agentId: waiter })).id as number;
	await c.open(held);
	await c.call("submit", { id: held, text: "carry on here" });
	const wait = await c.until("the run waiting for the limit", () => c.state(held)?.limitWait ?? undefined);
	const defaultBefore = c.events.providers.defaultModel as Ref;
	assert.deepEqual(await c.call("conversation.carryOn", { id: held, since: wait.since, model: text }), { switched: [held] });
	await c.until("the run finished", () => c.state(held)?.busy === false && c.answers(held).length > 0);
	assert.equal(c.answers(held).at(-1)!.model, "demo-text", "the run carried on with the model chosen");
	await c.until("then it says its agent's model again", () => same(c.model(held), standInModel));
	// Its next message goes to its agent's model, whose limit the engine has learned is used up for an hour: it waits
	// for it, without asking (#556), which is how a run on that model is told apart here.
	await c.call("submit", { id: held, text: "after carrying on" });
	const next = await c.until("the next run waiting for the agent's model", () => (c.state(held)?.busy === true ? (c.state(held)?.limitWait ?? undefined) : undefined));
	assert.equal(next.provider, "Stand-in");
	assert.ok(same(c.model(held), standInModel), `its next message runs on its agent's model: ${JSON.stringify(c.model(held))}`);
	assert.equal(requests["after carrying on"], undefined);
	await c.call("abort", { id: held });
	await c.until("stopped", () => c.state(held)?.busy === false);
	assert.deepEqual(c.events.providers.defaultModel, defaultBefore, "the choice is not remembered as the default for agents");
	assert.ok(same(c.agent(waiter).model, standInModel), "nor does it change the agent");
	step("a model chosen with Carry on with… holds for that run, and the next message runs on the agent's model");
} finally {
	client.close();
	await stop(engine);
	standIn.close();
}
