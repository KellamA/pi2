// Models added by hand to a built-in provider (#259): what pi² takes from the catalog for a new id, how it is kept,
// given way to the catalog and removed, and what a conversation says when the provider refuses it or it is gone. The
// first part runs src/providers.ts against stand-in providers with catalogs of their own; the second a real engine,
// whose added model is sent to a stand-in server on 127.0.0.1. No real provider is called.

import assert from "node:assert/strict";
import { type ChildProcess, execFileSync, spawn } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createServer, type IncomingMessage } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
	type Api,
	createModels,
	createProvider,
	type CreateModelsOptions,
	getSupportedThinkingLevels,
	InMemoryCredentialStore,
	type Model,
} from "@earendil-works/pi-ai";
import { openAICompletionsApi } from "@earendil-works/pi-ai/api/openai-completions.lazy";
import { openAIResponsesApi } from "@earendil-works/pi-ai/api/openai-responses.lazy";
import { getBuiltinModels } from "@earendil-works/pi-ai/providers/all";
import { nameLike, nearestModel, Providers } from "../src/providers.ts";
import { reportedThinking } from "../src/thinkingretry.ts";
import { EngineClient, stop } from "./patience.ts";

function step(name: string): void {
	console.log(`ok  ${name}`);
}

const temporary: string[] = [];
const KEYCHAIN_SERVICE = `dev.pi2.credentials.test-addedmodels-${process.pid}`;
process.on("exit", () => {
	for (const folder of temporary) rmSync(folder, { recursive: true, force: true });
	for (let i = 0; i < 100; i++) {
		try {
			execFileSync("/usr/bin/security", ["delete-generic-password", "-s", KEYCHAIN_SERVICE], { stdio: "ignore" });
		} catch {
			break;
		}
	}
});

/** A stand-in server on 127.0.0.1: what it was asked, and what it answers, by the model asked for. */
type Asked = { method: string; url: string; authorization: string | undefined; model: string | undefined; effort?: string };
const asked: Asked[] = [];
const REFUSED = new Set(["gpt-6.2-sol", "gpt-test-next"]);
const standIn = createServer((request: IncomingMessage, response) => {
	let body = "";
	request.setEncoding("utf8").on("data", (chunk: string) => (body += chunk));
	request.on("end", () => {
		const { model, reasoning } = body === "" ? {} : JSON.parse(body) as { model?: string; reasoning?: { effort?: string } };
		asked.push({ method: request.method ?? "", url: request.url ?? "", authorization: request.headers.authorization, model, effort: reasoning?.effort });
		if (model === "gpt-test-thinking" && reasoning?.effort !== "low") {
			response.writeHead(400, { "content-type": "application/json" }).end(JSON.stringify({ error: {
				message: `Unsupported value: 'none' is not supported with the '${model}' model. Supported values are: 'low', 'medium', 'high', 'xhigh', and 'max'.`,
				param: "reasoning.effort", code: "unsupported_value", type: "invalid_request_error",
			} }));
			return;
		}
		if (model !== undefined && REFUSED.has(model)) {
			// OpenAI's own answer for a model the key cannot use.
			response.writeHead(404, { "content-type": "application/json" }).end(
				JSON.stringify({ error: { message: `The model \`${model}\` does not exist or you do not have access to it.`, type: "invalid_request_error", param: null, code: "model_not_found" } }),
			);
			return;
		}
		// A Responses API answer, streamed, with token counts.
		response.writeHead(200, { "content-type": "text/event-stream" });
		const send = (event: Record<string, unknown>) => response.write(`event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`);
		const item = { type: "message", id: "msg_1", role: "assistant", status: "in_progress", content: [] as unknown[] };
		send({ type: "response.created", response: { id: "resp_1", object: "response", status: "in_progress", model, output: [] } });
		send({ type: "response.output_item.added", output_index: 0, item });
		send({ type: "response.content_part.added", item_id: "msg_1", output_index: 0, content_index: 0, part: { type: "output_text", text: "", annotations: [] } });
		send({ type: "response.output_text.delta", item_id: "msg_1", output_index: 0, content_index: 0, delta: "Hello from the stand-in." });
		const done = { ...item, status: "completed", content: [{ type: "output_text", text: "Hello from the stand-in.", annotations: [] }] };
		send({ type: "response.output_item.done", output_index: 0, item: done });
		send({
			type: "response.completed",
			response: { id: "resp_1", object: "response", status: "completed", model, output: [done], usage: { input_tokens: 40, output_tokens: 6, total_tokens: 46, input_tokens_details: { cached_tokens: 0 }, output_tokens_details: { reasoning_tokens: 0 } } },
		});
		response.end();
	});
});
await new Promise<void>((resolve) => standIn.listen(0, "127.0.0.1", resolve));
const standInUrl = `http://127.0.0.1:${(standIn.address() as { port: number }).port}/v1`;

// ---- Which validation errors actually tell us the accepted levels

assert.deepEqual(reportedThinking("reasoning_effort 'none' is not supported for this model; supported values: ['low', 'high', 'max']", "none", "glm")?.levels, ["low", "high", "max"]);
assert.deepEqual(reportedThinking("Invalid thinkingLevel. Supported levels: LOW, HIGH.", "MEDIUM", "gemini")?.levels, ["low", "high"]);
assert.deepEqual(reportedThinking("output_config.effort: Input should be 'low', 'medium' or 'high'", "max", "claude")?.levels, ["low", "medium", "high"]);
assert.equal(reportedThinking("output_config.effort 'xhigh' is not supported when thinking is disabled on this model. Use effort 'high' or below, or enable thinking.", "xhigh", "claude"), undefined);
assert.equal(reportedThinking("Thinking budget is not supported for this model.", "low", "gemini"), undefined);
assert.equal(reportedThinking("Unsupported value: 'none' is not supported with the 'other-model' model. Supported values are: 'low'.", "none", "test"), undefined);
assert.equal(reportedThinking("Invalid reasoning_effort. Supported values: low, sometimes.", "max", "test"), undefined);
assert.equal(reportedThinking("Invalid reasoning_effort. Supported values: low, max.", "max", "test"), undefined);
step("only explicit, understood effort validation lists can cause a retry");

// ---- Choosing what a new id is like

{
	const ids = ["gpt-5.6-sol", "gpt-6-sol", "gpt-6.1-sol", "gpt-6.1-terra", "gpt-6-luna", "o3", "claude-opus-5-5", "claude-opus-4-8-20250101"].map((id) => ({ id }));
	assert.deepEqual(nearestModel("gpt-6.2-sol", ids), { model: { id: "gpt-6.1-sol" }, sameFamily: true });
	// No "gpt-nova" yet: the newest "gpt-…", and of two of the same version the shorter id.
	assert.deepEqual(nearestModel("gpt-7-nova", ids), { model: { id: "gpt-6.1-sol" }, sameFamily: false });
	assert.deepEqual(nearestModel("claude-opus-6", ids), { model: { id: "claude-opus-5-5" }, sameFamily: true });
	assert.deepEqual(nearestModel("mystery", ids)?.sameFamily, false);
	assert.equal(nearestModel("x", []), undefined);
	assert.equal(nameLike("gpt-6.2-sol", { id: "gpt-6.1-sol", name: "GPT-6.1 Sol" }), "GPT-6.2 Sol");
	assert.equal(nameLike("claude-opus-5-6", { id: "claude-opus-5-5", name: "Claude Opus 5.5" }), "Claude Opus 5.6");
	assert.equal(nameLike("gpt-7-nova", { id: "gpt-6.1-sol", name: "GPT-6.1 Sol" }), "gpt-7-nova");
	step("a new id is based on the newest model of its family, or the closest, and named like it");
}

// ---- src/providers.ts, with stand-in built-in providers

function chat(id: string, name: string, extra: Partial<Model<Api>> = {}): Model<Api> {
	return {
		id,
		name,
		api: "openai-responses",
		provider: "",
		baseUrl: standInUrl,
		reasoning: true,
		thinkingLevelMap: { off: "none", xhigh: "xhigh" },
		input: ["text", "image"],
		cost: { input: 2, output: 10, cacheRead: 0.2, cacheWrite: 0 },
		contextWindow: 500_000,
		maxTokens: 128_000,
		...extra,
	} as Model<Api>;
}

/** A collection like the library's, of two providers whose catalogs the test chooses. */
function standIns(subscription: Model<Api>[], keyed: Model<Api>[]) {
	return (options?: CreateModelsOptions) => {
		const models = createModels(options);
		models.setProvider(
			createProvider({
				id: "sub",
				name: "Sub Codex",
				auth: {
					oauth: {
						name: "Sub (plan)",
						isSubscription: true,
						login: async () => {
							throw new Error("not in a test");
						},
						refresh: async (credential) => credential,
						toAuth: async (credential) => ({ apiKey: credential.access }),
					},
				},
				models: subscription.map((model) => ({ ...model, provider: "sub" })),
				api: openAIResponsesApi(),
			}),
		);
		models.setProvider(
			createProvider({
				id: "keyed",
				name: "Keyed",
				auth: { apiKey: { name: "Keyed API key", resolve: async ({ credential }) => (credential?.key ? { auth: { apiKey: credential.key } } : undefined) } },
				models: keyed.map((model) => ({ ...model, provider: "keyed" })),
				// The provider's own choice of what a credential may use, which knows nothing of models added by hand.
				filterModels: (list) => list.filter((model) => model.id !== "keyed-hidden"),
				api: { "openai-responses": openAIResponsesApi(), "openai-completions": openAICompletionsApi() },
			}),
		);
		return models;
	};
}

const SUB = [
	chat("gpt-6-sol", "GPT-6 Sol", { contextWindow: 272_000 }),
	chat("gpt-6.1-sol", "GPT-6.1 Sol"),
	chat("gpt-6.1-terra", "GPT-6.1 Terra", { input: ["text"] }),
];
const KEYED = [chat("keyed-1", "Keyed 1"), chat("keyed-hidden", "Keyed Hidden"), chat("oss-2", "OSS 2", { api: "openai-completions", reasoning: false, thinkingLevelMap: undefined })];

{
	const home = mkdtempSync(join(tmpdir(), "pi2-added-"));
	temporary.push(home);
	const credentials = new InMemoryCredentialStore();
	const lines: string[] = [];
	const open = (builtins = standIns(SUB, KEYED)) => new Providers(home, credentials, () => "device", { builtins, log: (...parts) => lines.push(parts.join(" ")) });
	let providers = open();

	const draft = providers.draftModel("sub", " gpt-6.2-sol ");
	const template = providers.models.getModel("sub", "gpt-6.1-sol")!;
	assert.deepEqual(
		{ ...draft, templates: draft.templates.map((t) => t.id) },
		{
			provider: "sub",
			providerName: "Sub Codex",
			id: "gpt-6.2-sol",
			name: "GPT-6.2 Sol",
			basedOn: "gpt-6.1-sol",
			basedOnName: "GPT-6.1 Sol",
			match: "family",
			told: [],
			api: "openai-responses",
			apis: ["openai-responses"],
			contextWindow: 500_000,
			maxTokens: 128_000,
			vision: true,
			thinkingLevels: getSupportedThinkingLevels(template),
			templates: ["gpt-6.1-sol", "gpt-6.1-terra", "gpt-6-sol"],
			editing: false,
		},
	);
	assert.deepEqual(draft.thinkingLevels, ["off", "minimal", "low", "medium", "high", "xhigh"]);
	assert.equal(providers.draftModel("sub", "gpt-6.2-sol", { basedOn: "gpt-6.1-terra" }).vision, false);
	assert.equal(providers.draftModel("sub", "gpt-6.2-sol", { basedOn: "gpt-6.1-terra" }).match, "chosen");
	assert.equal(providers.draftModel("keyed", "oss-3", { api: "openai-completions" }).basedOn, "oss-2");
	assert.deepEqual(providers.draftModel("keyed", "oss-3").apis, ["openai-responses", "openai-completions"]);
	assert.throws(() => providers.draftModel("sub", "gpt-6.1-sol"), /Sub Codex already has gpt-6.1-sol \(GPT-6.1 Sol\)/);
	assert.throws(() => providers.draftModel("sub", "GPT 6.2 Sol"), /no spaces/);
	assert.throws(() => providers.draftModel("sub", ""), /Type the model's id/);
	assert.throws(() => providers.draftModel("demo", "x"), /Unknown provider: demo/);
	step("a draft takes context size, thinking levels, pictures and the API from the newest model of the family");

	const input = { provider: "sub", id: "gpt-6.2-sol", name: "GPT-6.2 Sol", basedOn: "gpt-6.1-sol", contextWindow: 400_000, maxTokens: 100_000, vision: false, thinkingLevels: ["off", "low", "high"] };
	await assert.rejects(providers.addModel(input), /Sign in to Sub Codex or add its key first/);
	await credentials.modify("sub", async () => ({ type: "oauth", access: "sub-token", refresh: "r", expires: Date.now() + 3_600_000 }));
	await assert.rejects(providers.addModel({ ...input, maxTokens: 500_000 }), /cannot be more than the context size/);
	await assert.rejects(providers.addModel({ ...input, contextWindow: 0 }), /whole number/);
	await assert.rejects(providers.addModel({ ...input, thinkingLevels: ["lots"] }), /Thinking levels are some of/);
	const info = await providers.addModel(input);
	assert.deepEqual(info, { provider: "sub", providerName: "Sub Codex", id: "gpt-6.2-sol", name: "GPT-6.2 Sol", thinkingLevels: ["off", "low", "high"], contextWindow: 400_000, vision: false, addedByHand: true });
	const listed = (await providers.listModels()).filter((model) => model.provider === "sub");
	assert.deepEqual(listed.map((model) => [model.id, model.addedByHand === true]), [["gpt-6-sol", false], ["gpt-6.1-sol", false], ["gpt-6.1-terra", false], ["gpt-6.2-sol", true]]);
	const added = providers.models.getModel("sub", "gpt-6.2-sol")!;
	assert.deepEqual(added.cost, { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, "no price is known");
	assert.equal(added.baseUrl, template.baseUrl);
	assert.equal(added.api, "openai-responses");
	assert.equal(providers.isAddedByHand("sub", "gpt-6.2-sol"), true);
	assert.equal(providers.isAddedByHand("sub", "gpt-6.1-sol"), false);
	assert.equal((await providers.listProviders()).find((p) => p.id === "sub")?.modelCount, 4);
	step("an added model is offered with the provider's own, with the settings chosen and no price");

	// It is changed by adding it again, and the draft for it is what it has.
	assert.deepEqual({ ...providers.draftModel("sub", "gpt-6.2-sol"), templates: [] }, {
		provider: "sub",
		providerName: "Sub Codex",
		id: "gpt-6.2-sol",
		name: "GPT-6.2 Sol",
		basedOn: "gpt-6.1-sol",
		basedOnName: "GPT-6.1 Sol",
		match: "chosen",
		api: "openai-responses",
		apis: ["openai-responses"],
		contextWindow: 400_000,
		maxTokens: 100_000,
		vision: false,
		thinkingLevels: ["off", "low", "high"],
		templates: [],
		editing: true,
	});
	await providers.addModel({ ...input, name: "Sol 6.2", vision: true });
	assert.deepEqual((await providers.listModels()).filter((m) => m.id === "gpt-6.2-sol").map((m) => [m.name, m.vision]), [["Sol 6.2", true]]);
	step("an added model can be changed");

	// A provider's own filter of what a credential may use leaves added models alone.
	await credentials.modify("keyed", async () => ({ type: "api_key", key: "sk-keyed" }));
	await providers.addModel({ provider: "keyed", id: "keyed-2", basedOn: "keyed-1", contextWindow: 1000, maxTokens: 500, vision: false, thinkingLevels: [] });
	assert.deepEqual((await providers.listModels()).filter((m) => m.provider === "keyed").map((m) => [m.id, m.thinkingLevels.length]), [["keyed-1", 6], ["oss-2", 0], ["keyed-2", 0]]);
	step("a provider's filter for a credential does not hide a model added by hand");

	// The request goes where the template's went, with the provider's credential; a refusal names the model.
	asked.length = 0;
	await providers.addModel({ provider: "keyed", id: "gpt-test-next", basedOn: "keyed-1", contextWindow: 1000, maxTokens: 500, vision: false, thinkingLevels: [] });
	const refused = await providers.models.completeSimple(providers.models.getModel("keyed", "gpt-test-next")!, { messages: [{ role: "user", content: "hi", timestamp: Date.now() }] });
	assert.equal(refused.stopReason, "error");
	assert.match(refused.errorMessage ?? "", /The model `gpt-test-next` does not exist or you do not have access to it/);
	assert.deepEqual(asked.map((a) => [a.method, a.url, a.authorization, a.model]), [["POST", "/v1/responses", "Bearer sk-keyed", "gpt-test-next"]]);
	step("an added model is asked for on the provider's own address, with its credential, and a refusal names it");

	// Kept across a restart, and built from the catalog's model as it is then.
	providers = open();
	assert.equal(providers.models.getModel("sub", "gpt-6.2-sol")?.name, "Sol 6.2");
	const stored = JSON.parse(readFileSync(join(home, "added-models.json"), "utf8"));
	assert.deepEqual(Object.keys(stored), ["sub", "keyed"]);
	assert.equal(stored.sub[0].basedOn, "gpt-6.1-sol");
	step("added models are kept across a restart");

	// The library no longer has the template: the model as stored is used.
	providers = open(standIns([SUB[0]!], KEYED));
	assert.equal(providers.models.getModel("sub", "gpt-6.2-sol")?.contextWindow, 400_000);
	assert.equal(providers.isAddedByHand("sub", "gpt-6.2-sol"), true);
	step("an added model still works when the library drops the model it was based on");

	// The library comes to know it: its own entry takes the place of the one added by hand, which is forgotten.
	providers = open(standIns([...SUB, chat("gpt-6.2-sol", "GPT-6.2 Sol (catalog)", { contextWindow: 1_000_000 })], KEYED));
	const sol = (await providers.listModels()).filter((m) => m.id === "gpt-6.2-sol");
	assert.deepEqual(sol, [{ provider: "sub", providerName: "Sub Codex", id: "gpt-6.2-sol", name: "GPT-6.2 Sol (catalog)", thinkingLevels: getSupportedThinkingLevels(template), contextWindow: 1_000_000, vision: true }]);
	assert.equal(JSON.parse(readFileSync(join(home, "added-models.json"), "utf8")).sub, undefined);
	assert.ok(lines.some((line) => line.includes("sub/gpt-6.2-sol was added by hand and is now in the provider's own list")));
	step("an added model gives way to the catalog's own entry once the library knows its id");

	// Removed.
	providers.removeModel("keyed", "keyed-2");
	assert.equal(providers.models.getModel("keyed", "keyed-2"), undefined);
	assert.throws(() => providers.removeModel("keyed", "keyed-2"), /keyed-2 was not added by hand to Keyed/);
	assert.throws(() => providers.removeModel("sub", "gpt-6.1-sol"), /was not added by hand/);
	providers = open(standIns(SUB, KEYED));
	assert.deepEqual((await providers.listModels()).filter((m) => m.addedByHand).map((m) => m.id), ["gpt-test-next"]);
	step("an added model can be removed, and stays removed");
}

// ---- A real engine

const home = mkdtempSync(join(tmpdir(), "pi2-added-engine-"));
temporary.push(home);
// A model added by hand to the built-in OpenAI provider, based on a model the library has dropped, so it is used as
// stored: on the stand-in's address. Only the test can put one there; pi² takes the address from the catalog.
const openaiTemplate = getBuiltinModels("openai").find((model) => model.api === "openai-responses")!;
const storedModel = (id: string) => ({ ...openaiTemplate, id, name: id, reasoning: false, thinkingLevelMap: undefined, baseUrl: standInUrl, input: ["text"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } });
const storedEntry = (id: string) => ({ id, name: id, basedOn: "a-model-the-library-dropped", contextWindow: 100_000, maxTokens: 4096, vision: false, thinkingLevels: [], addedAt: 1, model: storedModel(id) });
const thinking = storedEntry("gpt-test-thinking");
writeFileSync(join(home, "added-models.json"), JSON.stringify({ openai: [storedEntry("gpt-test-next"), storedEntry("gpt-test-works"), {
	...thinking, thinkingLevels: ["off", "low", "medium", "high"], model: { ...thinking.model, reasoning: true, thinkingLevelMap: { off: "none" } },
}] }));

// Keys for real providers in the test's own environment are not passed on: nothing here may reach one.
const environment = Object.fromEntries(Object.entries(process.env).filter(([name]) => !/(API_KEY|TOKEN|SECRET)/.test(name)));
let log = "";
function startEngine(): ChildProcess {
	const child = spawn(process.execPath, [join(import.meta.dirname, "..", "src", "main.ts")], {
		env: { ...environment, PI2_HOME: home, PI2_KEYCHAIN_SERVICE: KEYCHAIN_SERVICE, PI2_LOGIN_SHELL: "off", PI2_DEMO_TOKENS_PER_SECOND: "2000" },
		stdio: ["ignore", "ignore", "pipe"],
	});
	child.stderr!.setEncoding("utf8").on("data", (chunk: string) => {
		log += chunk;
		process.stderr.write(chunk);
	});
	return child;
}

type Item = { kind: string; text: string; stop?: string; error?: string | null };
type State = { busy: boolean; failure: { reason: string; detail: string | null } | null };
type Shown = { provider: string; id: string; name: string; thinkingLevels: string[]; addedByHand?: boolean };
class Client extends EngineClient {
	override conversations = new Map<number, { items: Item[]; state: State }>();
	models: Shown[] = [];
	usage: { key: string; tokens: number; cost: number; unpriced?: boolean }[] = [];
	override receive(message: any): void {
		if (message.event === "providers") this.models = message.models;
		else if (message.event === "usage") this.usage = message.models;
		else super.receive(message);
	}
	/** The conversation once its run has ended after `users` messages, answered or not. */
	ended(id: number, users: number): Promise<{ items: Item[]; state: State }> {
		return this.until(`conversation ${id} ended`, () => {
			const conv = this.conversations.get(id);
			if (conv === undefined || conv.state.busy || conv.items.filter((i) => i.kind === "user").length < users) return undefined;
			const answered = conv.items.filter((i) => i.kind === "assistant" && i.stop === "stop").length;
			return conv.state.failure !== null || answered >= users ? conv : undefined;
		});
	}
}

let engine = startEngine();
try {
	let client = await Client.connect(engine, home);
	await client.call("providers.setKey", { id: "openai", key: "sk-test-not-real" });
	await client.until("the added models offered", () => client.models.filter((m) => m.provider === "openai" && m.addedByHand === true).length === 3);
	step("models added by hand are offered once their provider has a key, marked as added by hand");

	// The stand-in answers one of them: its tokens are counted, and Usage says its price is not known.
	asked.length = 0;
	const { id: works } = await client.call("conversation.create", { model: { provider: "openai", modelId: "gpt-test-works" } });
	await client.call("conversation.open", { id: works });
	await client.call("submit", { id: works, text: "hello" });
	let conv = await client.ended(works, 1);
	assert.equal(conv.state.failure, null);
	assert.equal(conv.items.filter((i) => i.kind === "assistant").at(-1)?.text, "Hello from the stand-in.");
	assert.deepEqual(asked.map((a) => [a.url, a.authorization, a.model]), [["/v1/responses", "Bearer sk-test-not-real", "gpt-test-works"]]);
	const row = await client.until("its usage", () => client.usage.find((u) => u.key === "openai/gpt-test-works"));
	assert.deepEqual({ tokens: row.tokens, cost: row.cost, unpriced: row.unpriced }, { tokens: 46, cost: 0, unpriced: true });
	step("an added model answers on the provider's key; Usage counts its tokens and says its price is not known");

	// Off was copied from another model. The refusal is retried in place; the amended catalog and draft agree.
	const levels = ["low", "medium", "high", "xhigh", "max"];
	const { id: retried } = await client.call("conversation.create", { model: { provider: "openai", modelId: thinking.id } });
	await client.call("conversation.open", { id: retried });
	await client.call("submit", { id: retried, text: "Use the stand-in" });
	conv = await client.ended(retried, 1);
	assert.equal(conv.state.failure, null);
	assert.deepEqual(asked.filter((a) => a.model === thinking.id).map((a) => a.effort), ["none", "low"]);
	assert.deepEqual(conv.items.filter((a) => a.kind === "marker").map((a) => a.text), ["gpt-test-thinking refused the Off thinking level. Retried with Low."]);
	assert.equal(conv.items.filter((a) => a.kind === "assistant").length, 1);
	await client.until("corrected model menu", () => client.models.find((m) => m.id === thinking.id)?.thinkingLevels.join() === levels.join());
	assert.deepEqual((await client.call("providers.draftModel", { provider: "openai", id: thinking.id })).thinkingLevels, levels);
	await client.call("submit", { id: retried, text: "Again" });
	conv = await client.ended(retried, 2);
	assert.equal(conv.state.failure, null);
	assert.deepEqual(asked.filter((a) => a.model === thinking.id).map((a) => a.effort), ["none", "low", "low"]);
	assert.equal(conv.items.filter((a) => a.kind === "marker").length, 1);
	step("a refused thinking level is retried once and corrected in the model menu and draft");

	// The provider refuses the other: the conversation says so, in the provider's words, and names the model.
	const { id: refused } = await client.call("conversation.create", { model: { provider: "openai", modelId: "gpt-test-next" } });
	await client.call("conversation.open", { id: refused });
	await client.call("submit", { id: refused, text: "hello" });
	conv = await client.ended(refused, 1);
	assert.equal(conv.state.failure?.reason, "model_error");
	assert.match(conv.state.failure?.detail ?? "", /The model `gpt-test-next` does not exist or you do not have access to it\./);
	assert.match(conv.state.failure?.detail ?? "", /gpt-test-next was added by hand in Settings › Providers: if OpenAI does not offer it to this sign-in or key, or names it otherwise, choose another model or change the id there\.$/);
	step("a provider's refusal of an added model names it and says it was added by hand");

	// Removed while a conversation uses it: the next message ends the run with a message, and the engine carries on.
	await client.call("providers.removeModel", { provider: "openai", id: "gpt-test-next" });
	await client.until("the removed model gone", () => !client.models.some((m) => m.id === "gpt-test-next"));
	await assert.rejects(client.call("conversation.configure", { id: refused, model: { provider: "openai", modelId: "gpt-test-next" } }), /Unknown model: openai\/gpt-test-next/);
	const before = asked.length;
	await client.call("submit", { id: refused, text: "again" });
	conv = await client.ended(refused, 2);
	assert.equal(conv.state.failure?.reason, "no_model");
	assert.equal(
		conv.state.failure?.detail,
		"OpenAI has no model gpt-test-next now. A model added by hand and then removed, or one a provider no longer lists, cannot be used. Choose another model from the toolbar, then press Continue.",
	);
	assert.equal(asked.length, before, "nothing was sent for a model that is gone");
	// The person chooses another model and carries on.
	await client.call("conversation.configure", { id: refused, model: { provider: "demo", modelId: "demo-1" } });
	await client.call("continue", { id: refused });
	conv = await client.until("the conversation answered on the demo model", () => {
		const c = client.conversations.get(refused);
		return c !== undefined && !c.state.busy && c.state.failure === null && c.items.at(-1)?.kind === "assistant" ? c : undefined;
	});
	assert.match(conv.items.at(-1)?.text ?? "", /I am the demo model/);
	step("a conversation whose added model was removed stops with a message naming it, and carries on on another");

	// Added through the engine, kept across a restart.
	const draft = await client.call("providers.draftModel", { provider: "openai", id: "gpt-99-test" });
	assert.equal(draft.editing, false);
	await client.call("providers.addModel", { provider: "openai", id: "gpt-99-test", name: "GPT-99 Test", basedOn: draft.basedOn, contextWindow: draft.contextWindow, maxTokens: draft.maxTokens, vision: draft.vision, thinkingLevels: draft.thinkingLevels });
	await client.until("the new model offered", () => client.models.some((m) => m.id === "gpt-99-test" && m.addedByHand === true));
	client.close();
	await stop(engine);
	engine = startEngine();
	client = await Client.connect(engine, home);
	await client.until("the added models offered after a restart", () => {
		const ids = client.models.filter((m) => m.addedByHand === true).map((m) => m.id).sort();
		return ids.join(" ") === "gpt-99-test gpt-test-thinking gpt-test-works";
	});
	assert.deepEqual(client.models.find((m) => m.id === thinking.id)?.thinkingLevels, levels);
	step("models added in settings and their corrected thinking levels are kept across a restart");
	client.close();
} finally {
	await stop(engine);
	standIn.close();
}
