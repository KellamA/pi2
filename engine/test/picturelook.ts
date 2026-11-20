// Looking at pictures with a model that can see them (#540, src/picturelook.ts). A real engine on a throwaway data
// folder, driven over its socket with the demo models: `demo-text` (PI2_DEMO_TEXT_MODEL) cannot see pictures and
// `demo-1` can, and no real provider is ever called — the look request goes to the scripted demo stand-in, whose
// answer says how many pictures it was sent.
//
// Checked: the setting (None by default, only models that take pictures, kept across restart); `look` offered only to
// a conversation whose own model cannot see pictures, and to no one while the setting is None, the prompt and tools
// otherwise byte for byte as before; a question about a picture answered by the other model, its spend counted under
// that model in Usage; a picture read by a model that cannot see replaced with one line that says so and names `look`,
// the bytes never reaching that model, while a model that can see still gets the picture; a file `read` could not
// open, or that is no picture, refused.

import assert from "node:assert/strict";
import { type ChildProcess, execFileSync, spawn } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { createServer, type IncomingMessage } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { getBuiltinModels } from "@earendil-works/pi-ai/providers/all";
import { EngineClient, standInApp, stop } from "./patience.ts";

process.env.PI2_DEMO_TOKENS_PER_SECOND ??= "100000";
process.env.PI2_LOGIN_SHELL ??= "off";
// The choice of a model that looks at pictures changes settings.json, so it is the person's alone (#513): this stand-in
// app bundle takes the test's own connection for the app's, as pictures.ts's does for its model choice.
process.env.PI2_APP_BUNDLE ??= standInApp();
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

// A one-pixel PNG, small enough to need no shrinking.
const RED = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC";

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
	async toolsOf(id: number): Promise<string[]> {
		const answer = await this.answer(id, "/system none");
		return answer.slice(answer.lastIndexOf("\nTOOLS: ") + 8).split(", ").filter((name) => name !== "");
	}
	tool(id: number): any {
		return (this.conversations.get(id)?.items ?? []).filter((item: any) => item.kind === "tool").at(-1);
	}
}

function newHome(name: string): string {
	const home = mkdtempSync(join(tmpdir(), `pi2-look-${name}-`));
	folders.push(home);
	return home;
}

async function start(name: string, home = newHome(name)): Promise<{ client: Client; engine: ChildProcess }> {
	const service = `dev.pi2.credentials.test-look-${name}-${process.pid}`;
	services.push(service);
	const engine = spawn(process.execPath, [main], {
		env: { ...process.env, PI2_HOME: home, PI2_KEYCHAIN_SERVICE: service, PI2_DEMO_TEXT_MODEL: "1" },
		stdio: ["ignore", "ignore", "inherit"],
	});
	engines.push(engine);
	const client = await Client.connect(engine, home);
	await client.until("providers", () => client.events.providers);
	await client.until("agents", () => client.events.agents);
	return { client, engine };
}

const home = newHome("one");
const folder = join(home, "folder");
mkdirSync(folder);
writeFileSync(join(folder, "pic.png"), Buffer.from(RED, "base64"));
writeFileSync(join(folder, "notes.txt"), "just text\n");
const { client, engine } = await start("one", home);
let beforeRestart: any;
try {
	// ---- The setting: None by default, only models that take pictures
	const told = await client.until("the look models", () => client.events.look);
	assert.equal(told.model, null, "none by default");
	assert.deepEqual(
		told.models.map(({ provider, id, name }: any) => ({ provider, id, name })),
		[{ provider: "demo", id: "demo-1", name: "Demo model (scripted)" }],
		"the connected providers' models that take pictures, and no model that cannot see them",
	);
	assert.equal(told.models[0].price, null, "the demo model has no price in the catalog");
	await assert.rejects(client.call("look.setModel", { model: { provider: "demo", modelId: "demo-text" } }), /cannot look at pictures/);
	await assert.rejects(client.call("look.setModel", { model: { provider: "demo", modelId: "no-such-model" } }), /cannot look at pictures/);

	// Two conversations of one agent: one on the model that cannot see pictures, one on the model that can.
	const { id: agentId } = await client.call("agents.save", { agent: { name: "Looker", access: "read", model: { provider: "demo", modelId: "demo-text" }, cwd: folder } });
	await client.until("agent Looker", () => client.events.agents?.agents?.some((x: any) => x.id === agentId));
	const open = async (params: Record<string, unknown>): Promise<number> => {
		const { id } = await client.call("conversation.create", params);
		await client.call("conversation.open", { id });
		return id as number;
	};
	const blind = await open({ agentId });
	const seeing = await open({ agentId, model: { provider: "demo", modelId: "demo-1" } });
	const chat = await open({ chat: true, model: { provider: "demo", modelId: "demo-text" } });
	const plain = (await client.call("agents.save", { agent: { name: "Plain", access: "none", model: { provider: "demo", modelId: "demo-text" }, cwd: folder } })).id as string;
	const none = await open({ agentId: plain });

	// While the setting is None, no conversation is offered look, whatever its model or access.
	assert.ok(!(await client.toolsOf(blind)).includes("look"), "a text-only model is offered nothing while the setting is None");
	assert.ok(!(await client.toolsOf(seeing)).includes("look"));
	assert.ok(!(await client.toolsOf(chat)).includes("look"), "a chat has no files to look at");
	assert.ok(!(await client.toolsOf(none)).includes("look"), "an agent with Tools off cannot read files, so it cannot look at any");
	step("None offers nothing: not to a text-only model, a seeing one, a chat, an agent without file access");

	// What a model that cannot see is given today, without look to name: one line, and the bytes kept out of its request.
	const readAnswer = await client.answer(blind, "/read pic.png");
	const readNone = client.tool(blind);
	assert.equal(readNone.isError, false, readNone.text);
	assert.equal(readNone.images ?? 0, 0, "no picture is kept in the result for a model that cannot see");
	assert.match(readNone.text, /You cannot see pictures: pic\.png is one\./);
	assert.ok(!readNone.text.includes("Ask about it with look."), "nothing names a tool that is not offered");
	assert.ok(!readNone.text.includes("placeholder"), "the note about a placeholder is gone with the picture");
	assert.match(readAnswer, /Done\. The tool returned: You cannot see pictures: pic\.png is one\./);
	assert.ok(!/I can see \d+ picture/.test(readAnswer), "no bytes reach the model that cannot see");
	step("read on a picture tells a model that cannot see so, in one line, and sends it no bytes");

	// A model that can see still gets the picture, byte for byte as before.
	assert.match(await client.answer(seeing, "/read pic.png"), /I can see 1 picture\./);
	assert.equal(client.tool(seeing).images, 1, "the picture is kept for a model that can see");

	// A picture already in the conversation is not sent once its model is changed to one that cannot see.
	const changed = await open({ agentId, model: { provider: "demo", modelId: "demo-1" } });
	assert.match(await client.answer(changed, "/read pic.png"), /I can see 1 picture\./);
	await client.call("conversation.configure", { id: changed, model: { provider: "demo", modelId: "demo-text" } });
	assert.doesNotMatch(
		await client.answer(changed, "/read notes.txt"),
		/I can see \d+ picture/,
		"a picture read before the model was changed is not sent to it",
	);
	assert.ok(
		(client.conversations.get(changed).items as any[]).some((item) => item.kind === "tool" && item.images === 1),
		"the person is still shown the picture that was read, though the model was sent a line instead",
	);
	step("a picture already in a conversation is not sent after its model is changed to one that cannot see");
	const seeingBefore = await client.answer(seeing, "/system full");
	const blindBefore = await client.answer(blind, "/system full");
	assert.equal(blindBefore, seeingBefore, "the prompt is the same whatever the model, while the setting is None");
	step("a model that can see still gets the picture, and the prompt does not follow the model");

	// ---- The choice: only then is look offered, and only where its own model cannot see.
	await client.call("look.setModel", { model: { provider: "demo", modelId: "demo-1" } });
	await client.until("the choice", () => client.events.look?.model?.modelId === "demo-1" && client.events.look);
	assert.ok((await client.toolsOf(blind)).includes("look"), "look is offered to the conversation that cannot see");
	assert.ok(!(await client.toolsOf(seeing)).includes("look"), "and to no conversation that can");
	assert.ok(!(await client.toolsOf(chat)).includes("look"));
	assert.ok(!(await client.toolsOf(none)).includes("look"));
	assert.equal(await client.answer(seeing, "/system full"), seeingBefore, "the prompt and tools of a seeing model are unchanged, byte for byte");
	const history = (await client.answer(blind, "/system history")).split("\n");
	assert.ok(history.some((line) => /^look=/.test(line) || line.endsWith("+tool:look")), `look came as a tool alone: ${history.at(-1)}`);
	step("with a model chosen, look is offered to the conversation that cannot see, and nothing else changes");

	// Where a picture would have been given, the line now names the tool.
	const afterRead = await client.answer(blind, "/read pic.png");
	const readOffered = client.tool(blind);
	assert.match(readOffered.text, /You cannot see pictures: pic\.png is one\. Ask about it with look\./);
	assert.ok(!/I can see \d+ picture/.test(afterRead), "still no bytes reach the model that cannot see");
	step("the line names look where a picture would have been given");

	// A picture among text files in one read: the line names its own file, and the text files are still read.
	const mixed = await client.answer(blind, '/tool read {"files":[{"path":"pic.png"},{"path":"notes.txt"}]}');
	const mixedResult = client.tool(blind);
	assert.equal(mixedResult.isError, false, mixedResult.text);
	assert.equal(mixedResult.images ?? 0, 0, "no picture is kept in a call of several files");
	assert.match(mixedResult.text, /==> pic\.png <==\nYou cannot see pictures: pic\.png is one\. Ask about it with look\./, mixedResult.text);
	assert.match(mixedResult.text, /just text/, "the text file beside it is still read");
	assert.ok(!/I can see \d+ picture/.test(mixed), "no bytes reach the model that cannot see");
	step("a picture among text files in one read gets the line that names it, and no bytes");

	// ---- A question about a picture, answered by the other model.
	const spendBefore = client.conversations.get(blind).state.usage;
	await client.answer(blind, '/tool look {"path":"pic.png","question":"What colour is the square?"}');
	const looked = client.tool(blind);
	assert.equal(looked.isError, false, looked.text);
	assert.deepEqual(looked.details, { model: "demo/demo-1", modelName: "Demo model (scripted)", pictures: 1 });
	assert.match(
		looked.text,
		/Demo model \(scripted\) looked at the picture and answered:\s+You said: "Question: What colour is the square\?[^"]*"\. With it came 1 picture\./,
		looked.text,
	);
	const spendAfter = await client.until("the look call counted", () => (client.conversations.get(blind).state.usage.tokens > spendBefore.tokens ? client.conversations.get(blind).state.usage : undefined));
	assert.ok(spendAfter.tokens > spendBefore.tokens, "the spend counts for the conversation");
	const summary = await client.until("the Usage row", () => {
		const rows = client.events.usage?.models?.filter((row: any) => row.lookName !== undefined) ?? [];
		return rows.length === 1 && rows[0].tokens > 0 ? client.events.usage : undefined;
	});
	const row = summary.models.find((candidate: any) => candidate.lookName !== undefined);
	assert.equal(row.key, "demo/demo-1");
	assert.ok(row.tokens > 0, `the look call's own tokens are in the row: ${row.tokens}`);
	assert.equal(row.cost, 0);
	assert.equal(row.unpriced, true, "a model with no price in the catalog counts tokens only");
	assert.match(row.lookName, /Demo model \(scripted\) · looking at pictures/);
	assert.equal(summary.total.tokens, summary.models.reduce((sum: number, one: any) => sum + one.tokens, 0), "nothing is counted twice");
	step("a question about a picture is answered by the other model, and its spend is shown under that model");

	// A model that fails is said plainly, and files read could not open, or that are no picture, are refused.
	await client.answer(blind, '/tool look {"path":"nope.png","question":"Anything?"}');
	const missing = client.tool(blind);
	assert.equal(missing.isError, true);
	assert.match(missing.text, /^No picture could be read\.\nnope\.png: /, missing.text);
	await client.answer(blind, '/tool look {"path":"notes.txt","question":"Anything?"}');
	assert.equal(client.tool(blind).isError, true);
	assert.match(client.tool(blind).text, /notes\.txt: it is not a picture/);
	await client.answer(blind, '/tool look {"path":"pic.png","question":""}');
	assert.equal(client.tool(blind).isError, true, "an empty question is refused");
	assert.match(client.tool(blind).text, /look needs `question`/);
	step("a file that cannot be read, a file that is not a picture, and an empty question are all refused");

	// Clearing the choice takes the tool away again, and the prompt with it.
	await client.call("look.setModel", { model: null });
	await client.until("the cleared choice", () => client.events.look?.model === null && client.events.look);
	assert.ok(!(await client.toolsOf(blind)).includes("look"), "no model named, no look offered");
	step("None takes the tool away again");
	await client.call("look.setModel", { model: { provider: "demo", modelId: "demo-1" } });
	await client.until("the choice again", () => client.events.look?.model?.modelId === "demo-1" && client.events.look);
	beforeRestart = (await client.until("the event before the restart", () => client.events.look)).model;
} finally {
	client.close();
	await stop(engine);
}
assert.deepEqual(beforeRestart, { provider: "demo", modelId: "demo-1" }, "the choice was kept in settings.json");

// ---- The choice is kept across a restart.
{
	const reopened = await start("one", home);
	try {
		const told = await reopened.client.until("the kept choice", () => reopened.client.events.look);
		assert.deepEqual(told.model, { provider: "demo", modelId: "demo-1" });
		assert.deepEqual(
			told.models.map(({ provider, id }: any) => ({ provider, id })),
			[{ provider: "demo", id: "demo-1" }],
		);
		step("the choice and the list of models that take pictures survive a restart");
	} finally {
		reopened.client.close();
		await stop(reopened.engine);
	}
}

// ---- A provider's error is the tool's error, in plain words, and the conversation carries on.
{
	const home = newHome("refused");
	const folder = join(home, "folder");
	mkdirSync(folder);
	writeFileSync(join(folder, "pic.png"), Buffer.from(RED, "base64"));
	// A stand-in OpenAI on 127.0.0.1, at its limit, naming a key and a request id that must not reach the model.
	const standIn = createServer((request: IncomingMessage, response) => {
		request.resume();
		request.on("end", () =>
			response.writeHead(429, { "content-type": "application/json", "x-should-retry": "false" }).end(
				JSON.stringify({ error: { message: "Rate limit reached for this project. request id req_0123456789abcdef; key sk-not-a-real-key-0123456789", type: "rate_limit_error" } }),
			),
		);
	});
	await new Promise<void>((resolve) => standIn.listen(0, "127.0.0.1", resolve));
	try {
		// A model added by hand to OpenAI, on the stand-in's address: only a test can put one there (as addedmodels.ts does).
		const base = `http://127.0.0.1:${(standIn.address() as { port: number }).port}/v1`;
		const template = getBuiltinModels("openai").find((model) => model.api === "openai-responses")!;
		const stored = { ...template, id: "gpt-look-refused", name: "GPT Look Refused", baseUrl: base, input: ["text", "image"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } };
		writeFileSync(
			join(home, "added-models.json"),
			JSON.stringify({ openai: [{ id: "gpt-look-refused", name: "GPT Look Refused", basedOn: "a-model-the-library-dropped", contextWindow: 100_000, maxTokens: 4096, vision: true, thinkingLevels: [], addedAt: 1, model: stored }] }),
		);
		const refused = await start("refused", home);
		try {
			await refused.client.call("providers.setKey", { id: "openai", key: "sk-test-not-real" });
			await refused.client.until("the added model offered", () => refused.client.events.look?.models?.some((model: any) => model.id === "gpt-look-refused") === true);
			await refused.client.call("look.setModel", { model: { provider: "openai", modelId: "gpt-look-refused" } });
			await refused.client.until("the choice", () => refused.client.events.look?.model?.modelId === "gpt-look-refused");
			const { id: agentId } = await refused.client.call("agents.save", { agent: { name: "Blind", access: "read", model: { provider: "demo", modelId: "demo-text" }, cwd: folder } });
			await refused.client.until("agent Blind", () => refused.client.events.agents?.agents?.some((x: any) => x.id === agentId));
			const { id } = await refused.client.call("conversation.create", { agentId });
			await refused.client.call("conversation.open", { id });
			const answer = await refused.client.answer(id, '/tool look {"path":"pic.png","question":"What is in it?"}');
			const result = refused.client.tool(id);
			assert.equal(result.isError, true, result.text);
			assert.match(result.text, /^GPT Look Refused could not look at the picture: OpenAI API error \(429\) rate_limit_error: Rate limit reached for this project\./, result.text);
			assert.ok(!result.text.includes("sk-") && !result.text.includes("req_0123456789abcdef"), `no key or request id reaches the model: ${result.text}`);
			assert.match(answer, /The tool reported an error; its output is above\./, "the conversation carries on after the provider's error");
			step("a provider's limit is the tool's error in plain words, and the conversation carries on");
		} finally {
			refused.client.close();
			await stop(refused.engine);
		}
	} finally {
		standIn.close();
	}
}
