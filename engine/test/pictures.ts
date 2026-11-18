// Making pictures (#286, src/pictures.ts). Two real engines on throwaway data folders, driven over their sockets with the
// demo model; no real provider is ever called.
//
// The first has no picture model: `make_picture` is offered to no one, an agent that turned it on and a chat are told
// why in the `pictures` section, an agent that did not is told nothing, and the app is told there is no model and which
// providers have them. The second has a picture model on a stand-in server on 127.0.0.1 that speaks OpenRouter's picture
// API (PI2_DEMO_PICTURES): an agent that turned the tool on and a chat are offered it, it makes a picture that is kept in
// the conversation, changes the newest picture when asked, counts what it cost, says when the model fails, and never
// asks for approval.

import assert from "node:assert/strict";
import { type ChildProcess, execFileSync, spawn } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
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

async function start(name: string, extra: Record<string, string>): Promise<{ client: Client; engine: ChildProcess }> {
	const home = mkdtempSync(join(tmpdir(), `pi2-pic-${name}-`));
	folders.push(home);
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
	const { client, engine } = await start("none", {});
	try {
		const told = await client.until("pictures", () => client.events.pictures);
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

// ---- A picture model on a stand-in server
{
	const { client, engine } = await start("some", { PI2_DEMO_PICTURES: standInUrl, PI2_DEMO_COST: "0" });
	try {
		const told = await client.until("the picture model", () => (client.events.pictures?.models?.length > 0 ? client.events.pictures : undefined));
		assert.deepEqual(told.models, [{ provider: "demo", id: "demo-pictures", name: "Demo pictures (stand-in)" }]);

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
		step("make_picture makes a picture with the model, keeps it in the conversation, counts its cost, asks nothing");

		// Changing it: the newest picture in the conversation goes with the description.
		await client.answer(painter, '/tool make_picture {"description":"Make it blue","change":true}');
		const changed = client.tools(painter).at(-1);
		assert.equal(changed.isError, false, changed.text);
		assert.match(changed.text, /^Changed the picture with/);
		assert.deepEqual(asked.at(-1)!.content, [
			{ type: "text", text: "Make it blue" },
			{ type: "image_url", image_url: { url: `data:image/png;base64,${RED}` } },
		]);
		assert.deepEqual(await client.call("conversation.image", { id: painter, entryId: changed.id, index: 0 }), { data: BLUE, mimeType: "image/png" });
		step("with change, the newest picture in the conversation is sent to be changed");

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
		step("nothing to change, and a model that fails, are said plainly; a chat makes pictures without asking");
	} finally {
		client.close();
		await stop(engine);
	}
}
standIn.close();
