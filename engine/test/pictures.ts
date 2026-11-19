// Making pictures (#286, #339, src/pictures.ts). Real engines on throwaway data folders, driven over their sockets with the
// demo model; no real provider is ever called.
//
// The first has no picture model: `make_picture` is offered to no one, an agent that turned it on and a chat are told
// why in the `pictures` section, an agent that did not is told nothing, and the app is told there is no model and which
// providers have them. Then there are priced and unpriced picture models on a stand-in server on 127.0.0.1. Check the
// person's choice, fallbacks, pictures in the conversation, and what Usage and the budget count, including after restart.

import assert from "node:assert/strict";
import { type ChildProcess, execFileSync, spawn } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { EngineClient, stop } from "./patience.ts";

process.env.PI2_DEMO_TOKENS_PER_SECOND ??= "100000";
process.env.PI2_LOGIN_SHELL ??= "off";
const main = join(import.meta.dirname, "..", "src", "main.ts");
const folders: string[] = [];
const services: string[] = [];
const engines: ChildProcess[] = [];
process.on("exit", () => {
	for (const engine of engines) if (engine.exitCode === null && engine.signalCode === null) engine.kill("SIGKILL");
	for (const folder of folders) rmSync(folder, { recursive: true, force: true });
	for (const service of services) {
		try {
			while (true) execFileSync("/usr/bin/security", ["delete-generic-password", "-s", service], { stdio: "ignore" });
		} catch {
			// None left.
		}
	}
});

function step(name: string): void {
	console.log(`ok  ${name}`);
}

// A one-pixel PNG for each colour the stand-in is asked for, so a picture can be told from another.
const RED = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC";
const BLUE = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNgYPgPAAEDAQAIicLsAAAAAElFTkSuQmCC";

/** What the stand-in was asked: the model, and the content of the one message (text and pictures). */
const asked: { model: string; content: { type: string; text?: string; image_url?: { url: string } }[] }[] = [];
let failNext = false;
const standIn = createServer((request, response) => {
	let body = "";
	request.on("data", (chunk) => (body += chunk));
	request.on("end", () => {
		const sent = JSON.parse(body);
		asked.push({ model: sent.model, content: sent.messages[0].content });
		response.setHeader("content-type", "application/json");
		if (failNext) {
			failNext = false;
			response.statusCode = 400;
			response.end(JSON.stringify({ error: { message: "The stand-in refuses this one", code: 400 } }));
			return;
		}
		const text = sent.messages[0].content.find((part: { type: string }) => part.type === "text")?.text ?? "";
		const picture = /blue/i.test(text) ? BLUE : RED;
		response.end(
			JSON.stringify({
				id: "gen-1",
				choices: [{ index: 0, finish_reason: "stop", message: { role: "assistant", content: "Here it is.", images: [{ type: "image_url", image_url: { url: `data:image/png;base64,${picture}` } }] } }],
				usage: { prompt_tokens: 1000, completion_tokens: 2000, total_tokens: 3000 },
			}),
		);
	});
});
await new Promise<void>((resolve) => standIn.listen(0, "127.0.0.1", resolve));
const standInUrl = `http://127.0.0.1:${(standIn.address() as { port: number }).port}/v1`;

class Client extends EngineClient {
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
	async offered(id: number): Promise<{ tools: string[]; sections: string[] }> {
		const sizes = (await this.answer(id, "/system sizes")).split("\n").slice(1);
		const answer = await this.answer(id, "/system none");
		return { tools: answer.slice(answer.lastIndexOf("\nTOOLS: ") + 8).split(", "), sections: sizes.map((line) => line.slice(0, line.lastIndexOf(" "))).filter((key) => !key.startsWith("(")) };
	}
	tools(id: number): any[] {
		return (this.conversations.get(id)?.items ?? []).filter((item: any) => item.kind === "tool");
	}
	async conversationOf(agent: Record<string, unknown> | { chat: true }): Promise<number> {
		let params: Record<string, unknown> = { chat: true };
		if (!("chat" in agent)) {
			const { id: agentId } = await this.call("agents.save", { agent });
			await this.until(`agent ${String(agent.name)}`, () => this.events.agents?.agents?.some((x: any) => x.id === agentId));
			params = { agentId };
		}
		const { id } = await this.call("conversation.create", params);
		await this.call("conversation.open", { id });
		return id;
	}
}

function newHome(name: string): string {
	const home = mkdtempSync(join(tmpdir(), `pi2-pic-${name}-`));
	folders.push(home);
	return home;
}

async function start(name: string, extra: Record<string, string>, home = newHome(name)): Promise<{ client: Client; engine: ChildProcess }> {
	const service = `dev.pi2.credentials.test-pictures-${name}-${process.pid}`;
	services.push(service);
	const engine = spawn(process.execPath, [main], { env: { ...process.env, PI2_HOME: home, PI2_KEYCHAIN_SERVICE: service, ...extra }, stdio: ["ignore", "ignore", "inherit"] });
	engines.push(engine);
	const client = await Client.connect(engine, home);
	await client.until("providers", () => client.events.providers);
	await client.until("agents", () => client.events.agents);
	return { client, engine };
}

// ---- No picture model
{
	const { client, engine } = await start("none", { PI2_DEMO_PICTURES: "" });
	try {
		const told = await client.until("pictures", () => client.events.pictures);
		assert.equal(told.model, null, "automatic by default");
		assert.deepEqual(told.models, [], "no picture model");
		assert.ok(told.makers.includes("OpenRouter"), `the providers that have them: ${told.makers}`);
		const entry = client.events.agents.builtInTools.find((tool: any) => tool.key === "pictures");
		assert.equal(entry.offByDefault, true);
		assert.equal(entry.needs, "pictures");

		const plain = await client.conversationOf({ name: "Plain", access: "none" });
		const plainSeen = await client.offered(plain);
		assert.ok(!plainSeen.tools.includes("make_picture") && !plainSeen.sections.includes("pictures"), "an agent that did not turn it on is told nothing");
		const wanting = await client.conversationOf({ name: "Painter", access: "none", toolsOn: ["pictures"] });
		const wantingSeen = await client.offered(wanting);
		assert.ok(!wantingSeen.tools.includes("make_picture"), wantingSeen.tools.join(" "));
		const section = await client.answer(wanting, "/system pictures");
		assert.match(section, /You cannot make pictures here: none of the person's providers has a model that makes them \(OpenRouter has them; the person can add a key in Settings › Providers\)/);
		const chat = await client.conversationOf({ chat: true });
		const chatSeen = await client.offered(chat);
		assert.ok(!chatSeen.tools.includes("make_picture") && chatSeen.sections.includes("pictures"), `${chatSeen.tools.join(" ")} / ${chatSeen.sections.join(" ")}`);
		step("no picture model: offered to no one; an agent that wants it and a chat are told why, others nothing; the app is told");
	} finally {
		client.close();
		await stop(engine);
	}
}

// ---- Picture models on a stand-in server
{
	const home = newHome("some");
	const env = { PI2_DEMO_PICTURES: standInUrl, PI2_DEMO_COST: "0" };
	const missing = { provider: "demo", modelId: "demo-pictures-removed" };
	const unpriced = { provider: "demo", modelId: "demo-pictures-unpriced" };
	writeFileSync(join(home, "settings.json"), JSON.stringify({ pictureModel: missing }));
	const { client, engine } = await start("some", env, home);
	let beforeRestart: any;
	try {
		const told = await client.until("the picture models", () => client.events.pictures);
		assert.deepEqual(told.model, missing, "retain the choice when its model is not offered");
		assert.deepEqual(told.models.map(({ provider, id, canEdit, price }: any) => ({ provider, id, canEdit, price })), [
			{ provider: "demo", id: "demo-pictures", canEdit: true, price: { input: 1, output: 2 } },
			{ provider: "demo", id: "demo-pictures-unpriced", canEdit: false, price: null },
		]);
		await assert.rejects(client.call("pictures.setModel", { model: { provider: "demo", modelId: "demo-1" } }), /no longer available/);

		const plain = await client.conversationOf({ name: "Plain", access: "none" });
		assert.ok(!(await client.offered(plain)).tools.includes("make_picture"), "still off for an agent that did not turn it on");
		const painter = await client.conversationOf({ name: "Painter", access: "none", toolsOn: ["pictures"] });
		const seen = await client.offered(painter);
		assert.ok(seen.tools.includes("make_picture") && !seen.sections.includes("pictures"), `${seen.tools.join(" ")} / ${seen.sections.join(" ")}`);
		const chat = await client.conversationOf({ chat: true });
		const chatSeen = await client.offered(chat);
		assert.ok(chatSeen.tools.includes("make_picture") && !chatSeen.sections.includes("pictures"), chatSeen.tools.join(" "));
		step("a picture model: offered to an agent that turned it on and to a chat, with no section");

		// A picture, kept in the conversation, and what it cost counted.
		const before = client.conversations.get(painter).state.usage;
		await client.answer(painter, '/tool make_picture {"description":"A red square"}');
		const made = client.tools(painter).at(-1);
		assert.equal(made.name, "make_picture");
		assert.equal(made.isError, false, made.text);
		assert.match(made.text, /^Made a picture with Demo pictures \(stand-in\)\. The person sees it in the conversation/);
		assert.match(made.text, /Demo pictures \(stand-in\) said: Here it is\./);
		assert.equal(made.images, 1, "the picture is kept with the result");
		assert.deepEqual(made.details, { model: "demo/demo-pictures", modelName: "Demo pictures (stand-in)", pictures: 1, changed: false });
		assert.equal(asked.length, 1);
		assert.equal(asked[0]!.model, "demo-pictures");
		assert.deepEqual(asked[0]!.content, [{ type: "text", text: "A red square" }]);
		const picture = await client.call("conversation.image", { id: painter, entryId: made.id, index: 0 });
		assert.deepEqual(picture, { data: RED, mimeType: "image/png" });
		// 1,000 tokens in at $1 a million and 2,000 out at $2: half a cent.
		const after = await client.until("the picture's cost", () => (client.conversations.get(painter).state.usage.cost > before.cost ? client.conversations.get(painter).state.usage : undefined));
		assert.ok(Math.abs(after.cost - before.cost - 0.005) < 1e-9, `cost ${after.cost - before.cost}`);
		assert.ok(after.tokens - before.tokens >= 3000);
		assert.deepEqual(client.events.inbox?.items ?? [], [], "nothing asked");
		step("make_picture falls back to the automatic model, keeps the picture, counts its cost, asks nothing");

		assert.deepEqual(await client.call("pictures.setModel", { model: unpriced }), { model: unpriced });
		assert.deepEqual((await client.until("picture model choice", () => client.events.pictures?.model?.modelId === unpriced.modelId && client.events.pictures)).model, unpriced);
		await client.answer(painter, '/tool make_picture {"description":"A red square with the chosen model"}');
		assert.equal(asked.at(-1)!.model, unpriced.modelId, "explicit choice overrides the priced default");
		await client.call("usage.setBudget", { daily: 0.009 });
		assert.equal(client.events.usage.overBudget, false, "unknown spend does not count towards the budget");

		// The chosen model cannot edit. The automatic edit model gets the newest picture and the description.
		await client.answer(painter, '/tool make_picture {"description":"Make it blue","change":true}');
		const changed = client.tools(painter).at(-1);
		assert.equal(changed.isError, false, changed.text);
		assert.match(changed.text, /^Changed the picture with/);
		assert.equal(asked.at(-1)!.model, "demo-pictures");
		assert.deepEqual(asked.at(-1)!.content, [
			{ type: "text", text: "Make it blue" },
			{ type: "image_url", image_url: { url: `data:image/png;base64,${RED}` } },
		]);
		assert.deepEqual(await client.call("conversation.image", { id: painter, entryId: changed.id, index: 0 }), { data: BLUE, mimeType: "image/png" });
		await client.call("usage.setBudget", { daily: 0.009 });
		assert.equal(client.events.usage.overBudget, true, "the two priced calls reach the budget");
		await assert.rejects(client.call("submit", { id: chat, text: "Budget check" }), /budget/);
		// Leave room for the chat's picture without forcing a usage refresh after it.
		await client.call("usage.setBudget", { daily: 0.016 });
		assert.deepEqual(await client.call("pictures.setModel", { model: null }), { model: null });
		step("the chosen model overrides automatic; automatic still chooses a model for editing; the budget counts known spend");

		// Nothing to change in a conversation without a picture; the model's own failure said plainly.
		const count = asked.length;
		await client.answer(chat, '/tool make_picture {"description":"Make it blue","change":true}');
		assert.equal(client.tools(chat).at(-1).isError, true);
		assert.match(client.tools(chat).at(-1).text, /no picture in this conversation to change/);
		assert.equal(asked.length, count, "nothing was asked of the model");
		failNext = true;
		await client.answer(chat, '/tool make_picture {"description":"A cat"}');
		const failed = client.tools(chat).at(-1);
		assert.equal(failed.isError, true);
		assert.match(failed.text, /Demo pictures \(stand-in\) could not make the picture: .*The stand-in refuses this one/);
		await client.answer(chat, '/tool make_picture {"description":"A cat"}');
		assert.equal(client.tools(chat).at(-1).isError, false, "a chat makes pictures too");
		assert.deepEqual(client.events.inbox?.items ?? [], [], "nothing asked");
		assert.equal(asked.at(-1)!.model, "demo-pictures", "clearing the choice restores automatic selection");
		step("nothing to change, and a model that fails, are said plainly; a chat makes pictures without asking");

		const expectedRows = [
			{ key: "demo/demo-pictures", input: 3000, output: 6000, tokens: 9000, cost: 0.015, unpriced: false },
			{ key: "demo/demo-pictures-unpriced", input: 1000, output: 2000, tokens: 3000, cost: 0, unpriced: true },
		];
		const { summary, rows } = await client.until("Usage with all priced and unpriced picture calls", () => {
			const summary = client.events.usage;
			if (summary === undefined) return undefined;
			const rows = summary.models.filter((row: any) => row.pictureName !== undefined);
			// Earlier events can already have both rows. Wait for the last call too, then check the exact counts.
			if (expectedRows.every((expected) => rows.some((row: any) => row.key === expected.key && row.tokens >= expected.tokens))) return { summary, rows };
		});
		assert.deepEqual(rows.map(({ key, input, output, tokens, cost, unpriced }: any) => ({ key, input, output, tokens, cost, unpriced })), expectedRows);
		assert.equal(summary.total.cost, 0.015);
		assert.deepEqual(summary.today, summary.total);
		assert.equal(summary.total.tokens, summary.models.reduce((sum: number, row: any) => sum + row.tokens, 0));
		assert.equal(summary.agents.find((row: any) => row.cost > 0)?.cost, 0.01);
		assert.equal(summary.chats.cost, 0.005);
		assert.equal(summary.conversations.find((row: any) => row.id === painter)?.cost, 0.01);
		assert.equal(summary.conversations.find((row: any) => row.id === chat)?.cost, 0.005);
		assert.equal(summary.budget.daily, 0.016);
		assert.equal(summary.overBudget, false, "rows did not count the spend again");
		await client.call("pictures.setModel", { model: unpriced });
		beforeRestart = summary;
	} finally {
		client.close();
		await stop(engine);
	}

	const reopened = await start("some", env, home);
	try {
		assert.deepEqual((await reopened.client.until("saved picture model", () => reopened.client.events.pictures)).model, unpriced);
		const summary = await reopened.client.until("saved Usage", () => reopened.client.events.usage);
		assert.deepEqual(summary.models, beforeRestart.models);
		assert.deepEqual(summary.total, beforeRestart.total);
		assert.deepEqual(summary.today, beforeRestart.today);
		assert.equal(summary.overBudget, false);
		step("only known spend is counted; model rows, the daily budget and the choice survive restart");
	} finally {
		reopened.client.close();
		await stop(reopened.engine);
	}
}
standIn.close();
