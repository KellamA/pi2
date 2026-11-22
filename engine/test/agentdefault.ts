// The default model for agents (#617, Settings › General): the model, and the thinking level, an agent with no model of
// its own starts each conversation on. A real engine on a throwaway data folder, driven over its socket with the demo
// model, as the app would drive it.
//
// Before a choice, the default is the model last picked in a conversation, as it always was. Once chosen, every way an
// agent is made starts on it: by hand, a duplicate, a project's default orchestrator, a project's New Agent and the
// orchestrator's `project_agents` `make`; an agent with a model of its own keeps it, and a conversation already started
// keeps the model it has. A choice switched off or whose provider is gone falls back, and the event says so and to what.
// That another program cannot make the choice is checked with the other settings in reachsettings.ts.

import assert from "node:assert/strict";
import { type ChildProcess, execFileSync, spawn } from "node:child_process";
import { mkdtempSync, readFileSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { EngineClient, leaveOut, standInApp, stop } from "./patience.ts";

const home = mkdtempSync(join(tmpdir(), "pi2-agentdefault-"));
const work = realpathSync(mkdtempSync(join(tmpdir(), "pi2-agentdefault-work-")));
const main = join(import.meta.dirname, "..", "src", "main.ts");
const KEYCHAIN_SERVICE = `dev.pi2.credentials.test-agentdefault-${process.pid}`;
process.env.PI2_DEMO_TOKENS_PER_SECOND ??= "100000";
process.env.PI2_LOGIN_SHELL ??= "off";
// A second demo model to choose; this client stands for the app, whose requests these are (#513).
const env = { ...process.env, PI2_HOME: home, PI2_KEYCHAIN_SERVICE: KEYCHAIN_SERVICE, PI2_DEMO_TEXT_MODEL: "1", PI2_APP_BUNDLE: standInApp() };

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

type Ref = { provider: string; modelId: string };
const demo: Ref = { provider: "demo", modelId: "demo-1" };
const text: Ref = { provider: "demo", modelId: "demo-text" };

class Client extends EngineClient {
	get agentDefault(): any {
		return this.events.agentDefault;
	}
	agent(id: string): any {
		return this.events.agents?.agents?.find((agent: any) => agent.id === id);
	}
	agentNamed(name: string, projectId?: string): any {
		return this.events.agents?.agents?.find((agent: any) => agent.name === name && agent.projectId === projectId);
	}
	/** What a conversation runs on, once the engine has sent its state. */
	async runsOn(id: number): Promise<{ model: Ref | null; thinkingLevel: string | null }> {
		await this.call("conversation.open", { id });
		const state = await this.until(`conversation ${id}`, () => this.conversations.get(id)?.state);
		return { model: state.agent.model, thinkingLevel: state.agent.thinkingLevel };
	}
	/** A new conversation of `agentId`, and what it runs on. */
	async startWith(agentId: string): Promise<{ id: number; model: Ref | null; thinkingLevel: string | null }> {
		const { id } = await this.call("conversation.create", { agentId });
		return { id, ...(await this.runsOn(id)) };
	}
	items(id: number, kind: string): any[] {
		return this.conversations.get(id)?.items.filter((item: any) => item.kind === kind) ?? [];
	}
	/** Sends a message the demo model answers with a tool call, and returns that call's result once the answer is in. */
	async tool(id: number, message: string): Promise<any> {
		const count = this.items(id, "tool").length + 1;
		await this.call("submit", { id, text: message });
		return await this.until(`result of ${message}`, () => {
			const conv = this.conversations.get(id);
			const results = this.items(id, "tool");
			if (conv === undefined || conv.state.busy || results.length < count) return undefined;
			const after = conv.items.slice(conv.items.indexOf(results[count - 1]) + 1);
			return after.some((item: any) => item.kind === "assistant") ? results[count - 1] : undefined;
		});
	}
}

const sameRef = (a: Ref | null | undefined, b: Ref | null | undefined) => a?.provider === b?.provider && a?.modelId === b?.modelId;
const start = () => spawn(process.execPath, [main], { env, stdio: ["ignore", "ignore", "inherit"] });
engine = start();
const client = await Client.connect(engine, home);
try {
	await client.until("the greeting", () => client.events.providers && client.events.agents && client.events.agentDefault);

	// ---- Before a choice: the model last picked in a conversation, else the demo model, as it always was

	assert.deepEqual({ ...client.agentDefault, event: undefined }, { event: undefined, model: null, thinkingLevel: null, using: demo, fellBack: false });
	assert.deepEqual(client.events.providers.defaultModel, demo);
	const picked = await client.startWith("forge");
	assert.deepEqual(picked.model, demo);
	await client.call("conversation.configure", { id: picked.id, model: text });
	await client.until("the default follows the model picked", () => sameRef(client.agentDefault.using, text) && sameRef(client.events.providers.defaultModel, text));
	assert.deepEqual((await client.startWith("forge")).model, text);
	await client.call("conversation.configure", { id: picked.id, model: demo });
	await client.until("and back", () => sameRef(client.agentDefault.using, demo));
	step("with no choice, an agent with no model starts on the model last picked in a conversation, as before");

	// ---- The choice, checked

	await assert.rejects(client.call("settings.setAgentDefault", {}), /model must be/);
	await assert.rejects(client.call("settings.setAgentDefault", { model: { provider: "demo" } }), /model must be/);
	await assert.rejects(client.call("settings.setAgentDefault", { model: { provider: "demo", modelId: "nope" } }), /Unknown model: demo\/nope/);
	await assert.rejects(client.call("settings.setAgentDefault", { model: text, thinkingLevel: "high" }), /has no thinking level high/);
	const chose = await client.call("settings.setAgentDefault", { model: text });
	assert.deepEqual(chose, { model: text, thinkingLevel: null, using: text, fellBack: false });
	await client.until("the event", () => sameRef(client.agentDefault.model, text) && sameRef(client.events.providers.defaultModel, text));
	assert.deepEqual(JSON.parse(readFileSync(join(home, "settings.json"), "utf8")).agentDefault, { model: text, thinkingLevel: null });
	step("settings.setAgentDefault refuses what is not a model, an unknown model and a thinking level the model has not; it keeps the choice and says so");

	// ---- Every way an agent is made starts on it

	// By hand: New Agent sends no model.
	const { id: byHand } = await client.call("agents.save", { agent: { name: "Helper" } });
	assert.equal(client.agent(byHand)?.model ?? (await client.until("Helper", () => client.agent(byHand))).model, null);
	assert.deepEqual((await client.startWith(byHand)).model, text);
	// A duplicate keeps the original's: none, so the default; and an agent with a model of its own keeps it.
	const { id: copy } = await client.call("agents.duplicate", { id: byHand });
	assert.equal((await client.until("the copy", () => client.agent(copy))).model, null);
	assert.deepEqual((await client.startWith(copy)).model, text);
	const { id: own } = await client.call("agents.save", { agent: { name: "Pinned", model: demo } });
	const { id: ownCopy } = await client.call("agents.duplicate", { id: own });
	await client.until("Pinned's copy", () => client.agent(ownCopy));
	assert.deepEqual((await client.startWith(own)).model, demo);
	assert.deepEqual((await client.startWith(ownCopy)).model, demo);
	// A conversation already started keeps the model it has.
	assert.deepEqual((await client.runsOn(picked.id)).model, demo);
	step("an agent made by hand, and its duplicate, start on the default; one with a model of its own, and its duplicate, keep it; a conversation already started keeps its model");

	// A project: its default orchestrator, its New Agent, and the orchestrator's `make`.
	await leaveOut(client);
	const project = await client.call("projects.create", { folder: work });
	const O = project.conversation as number;
	assert.deepEqual((await client.runsOn(O)).model, text);
	const { id: added } = await client.call("projects.addAgent", { projectId: project.id, agent: { name: "Builder" } });
	assert.equal((await client.until("Builder", () => client.agent(added))).model, null);
	assert.deepEqual((await client.startWith(added)).model, text);
	const made = await client.tool(O, `/tool project_agents ${JSON.stringify({ action: "make", settings: { name: "Reviewer" } })}`);
	assert.equal(made.isError, false, made.text);
	assert.match(made.text, /^Made the agent Reviewer \(the default model, /);
	const reviewer = await client.until("Reviewer", () => client.agentNamed("Reviewer", project.id));
	assert.equal(reviewer.model, null);
	assert.deepEqual((await client.startWith(reviewer.id)).model, text);
	step("a project's default orchestrator, its New Agent and project_agents make start on the default");

	// ---- The thinking level chosen with it

	const { id: box } = await client.call("endpoints.save", { name: "Thinking Box", baseUrl: "http://127.0.0.1:9/v1", api: "openai-completions", models: [{ id: "thinker", reasoning: true }] });
	const thinker: Ref = { provider: box, modelId: "thinker" };
	const listed = await client.until("the thinker listed", () => client.events.providers.models.find((model: any) => model.provider === box && model.id === "thinker"));
	const level = (listed.thinkingLevels as string[]).find((one) => one !== "off");
	assert.ok(level !== undefined, `a reasoning model has thinking levels: ${JSON.stringify(listed.thinkingLevels)}`);
	assert.deepEqual(await client.call("settings.setAgentDefault", { model: thinker, thinkingLevel: level }), { model: thinker, thinkingLevel: level, using: thinker, fellBack: false });
	assert.deepEqual(await client.startWith(byHand).then(({ model, thinkingLevel }) => ({ model, thinkingLevel })), { model: thinker, thinkingLevel: level });
	// An agent's own thinking level wins over the default's.
	await client.call("agents.save", { agent: { id: copy, name: client.agent(copy).name, thinkingLevel: "off" } });
	await client.until("the copy thinks Off", () => client.agent(copy).thinkingLevel === "off");
	assert.deepEqual((await client.startWith(copy)).thinkingLevel, "off");
	step("the thinking level chosen with the default is what an agent with none of its own starts at; its own wins");

	// ---- Falling back

	// Its provider gone: the model last picked, at that model's own thinking level, and the event says so.
	await client.call("endpoints.remove", { id: box });
	await client.until("fell back", () => client.agentDefault.fellBack === true);
	assert.deepEqual({ ...client.agentDefault, event: undefined }, { event: undefined, model: thinker, thinkingLevel: level, using: demo, fellBack: true });
	assert.deepEqual(await client.startWith(byHand).then(({ model, thinkingLevel }) => ({ model, thinkingLevel })), { model: demo, thinkingLevel: null });
	// Switched off in the provider's models: the same.
	await client.call("settings.setAgentDefault", { model: text });
	await client.until("back on the text model", () => client.agentDefault.fellBack === false && sameRef(client.agentDefault.using, text));
	await client.call("providers.setHiddenModels", { id: "demo", hidden: ["demo-text"] });
	await client.until("fell back again", () => client.agentDefault.fellBack === true && sameRef(client.agentDefault.using, demo));
	assert.deepEqual(client.events.providers.defaultModel, demo);
	assert.deepEqual((await client.startWith(byHand)).model, demo);
	// Switched on again, it is the default again.
	await client.call("providers.setHiddenModels", { id: "demo", hidden: [] });
	await client.until("not falling back", () => client.agentDefault.fellBack === false && sameRef(client.agentDefault.using, text));
	assert.deepEqual((await client.startWith(byHand)).model, text);
	step("a default switched off, or whose provider is gone, falls back to the model last picked, and says so; switched on again, it is used again");

	// ---- A choice in a conversation no longer changes it; clearing it goes back to the model picked last

	const later = await client.startWith("forge");
	await client.call("conversation.configure", { id: later.id, model: demo });
	await client.until("the conversation is on the demo model", () => sameRef(client.conversations.get(later.id)?.state.agent.model, demo));
	assert.deepEqual((await client.startWith(byHand)).model, text);
	assert.deepEqual(await client.call("settings.setAgentDefault", { model: null }), { model: null, thinkingLevel: null, using: demo, fellBack: false });
	assert.deepEqual((await client.startWith(byHand)).model, demo);
	step("with a choice, picking a model in a conversation changes only that conversation; clearing the choice goes back to the model picked last");
} finally {
	client.close();
	await stop(engine);
}
