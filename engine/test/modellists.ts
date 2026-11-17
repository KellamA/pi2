// Asking a provider which models a key or sign-in can use, and refreshing the catalogs the library refreshes itself
// (#259): src/modellists.ts and src/providers.ts against stand-in providers whose addresses are a stand-in server on
// 127.0.0.1, answering as ChatGPT's Codex service, Anthropic, OpenAI and Google answer. No real provider is called.

import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { type Api, createModels, type CreateModelsOptions, createProvider, InMemoryCredentialStore, type Model } from "@earendil-works/pi-ai";
import { openAIResponsesApi } from "@earendil-works/pi-ai/api/openai-responses.lazy";
import { CODEX_CLIENT_VERSION } from "../src/modellists.ts";
import { Providers } from "../src/providers.ts";

function step(name: string): void {
	console.log(`ok  ${name}`);
}

const home = mkdtempSync(join(tmpdir(), "pi2-lists-"));
process.on("exit", () => rmSync(home, { recursive: true, force: true }));

/** A ChatGPT token as the Codex service reads it: a JWT naming the account. */
const token = ["e30", Buffer.from(JSON.stringify({ "https://api.openai.com/auth": { chatgpt_account_id: "acct-1" } })).toString("base64url"), "sig"].join(".");

type Asked = { path: string; headers: Record<string, string | string[] | undefined> };
const asked: Asked[] = [];
const json = (response: import("node:http").ServerResponse, status: number, body: unknown) => response.writeHead(status, { "content-type": "application/json" }).end(JSON.stringify(body));
const standIn = createServer((request, response) => {
	const path = request.url ?? "";
	asked.push({ path, headers: request.headers });
	if (path === `/backend-api/codex/models?client_version=${CODEX_CLIENT_VERSION}`) {
		return json(response, 200, {
			models: [
				{ slug: "gpt-6.1-sol", display_name: "GPT-6.1 Sol", visibility: "list" },
				{ slug: "gpt-6.2-sol", display_name: "GPT-6.2 Sol", context_window: 600_000, input_modalities: ["text", "image"], supported_reasoning_levels: [{ effort: "low" }, { effort: "medium" }, { effort: "high" }, { effort: "xhigh" }], visibility: "list" },
				{ slug: "codex-internal", display_name: "Internal", visibility: "hide" },
			],
		});
	}
	if (path === "/anthropic/v1/models?limit=1000") {
		return json(response, 200, {
			data: [
				{ type: "model", id: "claude-opus-6", display_name: "Claude Opus 6", max_input_tokens: 1_000_000, max_tokens: 128_000, capabilities: { image_input: { supported: true }, thinking: { supported: true }, effort: { low: { supported: true }, high: { supported: true }, max: { supported: true } } }, lifecycle: "active" },
				{ type: "model", id: "claude-opus-1", display_name: "Claude Opus 1", lifecycle: "retired" },
			],
			has_more: true,
			last_id: "claude-opus-1",
		});
	}
	if (path === "/anthropic/v1/models?limit=1000&after_id=claude-opus-1") return json(response, 200, { data: [{ type: "model", id: "claude-opus-5-5", display_name: "Claude Opus 5.5" }], has_more: false });
	if (path === "/openai/v1/models") return json(response, 200, { object: "list", data: [{ id: "gpt-6.1-sol", object: "model" }, { id: "gpt-6.3", object: "model", context_window: 64_000 }] });
	if (path === "/google/v1beta/models?pageSize=1000") {
		return json(response, 200, {
			models: [
				{ name: "models/gemini-9-pro", displayName: "Gemini 9 Pro", inputTokenLimit: 2_000_000, outputTokenLimit: 65_536, supportedGenerationMethods: ["generateContent"] },
				{ name: "models/embedding-9", supportedGenerationMethods: ["embedContent"] },
			],
		});
	}
	if (path === "/refuse/v1/models") return json(response, 401, { error: { message: "Incorrect API key provided: sk-abcdefghijklmnopqrstuvwxyz123456.", type: "invalid_request_error" } });
	if (path === "/redirect/v1/models") return response.writeHead(302, { location: "http://elsewhere.invalid/v1/models" }).end();
	json(response, 404, { error: { message: `No route ${path}` } });
});
await new Promise<void>((resolve) => standIn.listen(0, "127.0.0.1", resolve));
const origin = `http://127.0.0.1:${(standIn.address() as { port: number }).port}`;

function chat(id: string, api: string, baseUrl: string, extra: Partial<Model<Api>> = {}): Model<Api> {
	return { id, name: id, api, provider: "", baseUrl, reasoning: true, input: ["text", "image"], cost: { input: 1, output: 1, cacheRead: 0, cacheWrite: 0 }, contextWindow: 272_000, maxTokens: 64_000, ...extra } as Model<Api>;
}
const oauth = { name: "Sign-in", isSubscription: true, login: async () => Promise.reject(new Error("not in a test")), refresh: async (c: never) => c, toAuth: async (c: { access: string }) => ({ apiKey: c.access }) };
const keyAuth = (name: string) => ({ name, resolve: async ({ credential }: { credential?: { key?: string } }) => (credential?.key ? { auth: { apiKey: credential.key } } : undefined) });
let fetched = 0;

function standIns(options?: CreateModelsOptions) {
	const models = createModels(options);
	const add = (id: string, name: string, auth: object, list: Model<Api>[], extra: object = {}) =>
		models.setProvider(createProvider({ id, name, auth: auth as never, models: list.map((model) => ({ ...model, provider: id })), api: openAIResponsesApi(), ...extra }));
	add("openai-codex", "OpenAI Codex", { oauth }, [chat("gpt-6.1-sol", "openai-codex-responses", `${origin}/backend-api`)]);
	add("anthropic", "Anthropic", { apiKey: keyAuth("Anthropic API key"), oauth }, [chat("claude-opus-5-5", "anthropic-messages", `${origin}/anthropic`)]);
	add("openai", "OpenAI", { apiKey: keyAuth("OpenAI API key"), oauth }, [chat("gpt-6.1-sol", "openai-responses", `${origin}/openai/v1`)]);
	add("google", "Google", { apiKey: keyAuth("Google API key") }, [chat("gemini-8-pro", "google-generative-ai", `${origin}/google/v1beta`)]);
	add("github-copilot", "GitHub Copilot", { apiKey: keyAuth("Copilot"), oauth }, [chat("gpt-6.1-sol", "openai-completions", `${origin}/copilot`)]);
	add("refuser", "Refuser", { apiKey: keyAuth("Refuser API key") }, [chat("r-1", "openai-completions", `${origin}/refuse/v1`)]);
	add("redirector", "Redirector", { apiKey: keyAuth("Redirector API key") }, [chat("r-1", "openai-completions", `${origin}/redirect/v1`)]);
	add("cloudy", "Cloudy", { apiKey: keyAuth("Cloudy API key") }, [chat("c-1", "openai-completions", "https://api.example.invalid/accounts/{ACCOUNT}/v1")]);
	// A provider whose catalog the library refreshes itself, as pi-ai's Radius is.
	add("dynamic", "Dynamic", { apiKey: keyAuth("Dynamic API key") }, [chat("dyn-1", "pi-messages", `${origin}/dynamic`)], {
		fetchModels: async () => {
			fetched++;
			return [{ ...chat("dyn-2", "pi-messages", `${origin}/dynamic`), provider: "dynamic" }];
		},
	});
	return models;
}

const credentials = new InMemoryCredentialStore();
const open = () => new Providers(home, credentials, () => "device", { builtins: standIns });
let providers = open();

// What settings say of each provider.
await credentials.modify("openai-codex", async () => ({ type: "oauth", access: token, refresh: "r", expires: Date.now() + 3_600_000 }));
await credentials.modify("github-copilot", async () => ({ type: "api_key", key: "copilot-key" }));
await credentials.modify("cloudy", async () => ({ type: "api_key", key: "cloudy-key" }));
await credentials.modify("dynamic", async () => ({ type: "api_key", key: "dyn-key" }));
const info = new Map((await providers.listProviders()).map((p) => [p.id, p.ask]));
assert.deepEqual(info.get("openai-codex"), { can: true, url: origin });
assert.deepEqual(info.get("github-copilot"), { can: false, why: "GitHub Copilot lists its models only to its own apps, so pi² cannot ask it which models you can use." });
assert.deepEqual(info.get("cloudy"), { can: false, why: "pi² does not know how to ask Cloudy which models it serves." });
assert.deepEqual(info.get("dynamic"), { can: true, url: null });
assert.equal(info.get("anthropic"), null, "not signed in and no key: nothing to ask with");
assert.equal(info.get("demo"), null);
step("settings are told which providers can be asked, where, and why not");

// ChatGPT's Codex service, with the sign-in.
asked.length = 0;
let listing = await providers.askProvider("openai-codex");
assert.deepEqual(listing, {
	provider: "openai-codex",
	providerName: "OpenAI Codex",
	asked: origin,
	refreshed: false,
	catalogCount: 1,
	models: [
		{ id: "gpt-6.2-sol", name: "GPT-6.2 Sol", known: false, addedByHand: false },
		{ id: "gpt-6.1-sol", name: "GPT-6.1 Sol", known: true, addedByHand: false },
	],
});
assert.equal(asked.length, 1);
assert.equal(asked[0]!.headers.authorization, `Bearer ${token}`);
assert.equal(asked[0]!.headers["chatgpt-account-id"], "acct-1");
// What it said of the new model comes before what the newest of its family has.
const draft = providers.draftModel("openai-codex", "gpt-6.2-sol");
assert.deepEqual(
	{ name: draft.name, contextWindow: draft.contextWindow, maxTokens: draft.maxTokens, vision: draft.vision, thinkingLevels: draft.thinkingLevels, told: draft.told, basedOn: draft.basedOn },
	{ name: "GPT-6.2 Sol", contextWindow: 600_000, maxTokens: 64_000, vision: true, thinkingLevels: ["off", "low", "medium", "high", "xhigh"], told: ["context size", "name", "pictures", "thinking levels"], basedOn: "gpt-6.1-sol" },
);
step("ChatGPT's Codex service is asked with the sign-in, and what it says of a new model is used to add it");

// Anthropic with a key, two pages; retired models left out.
await credentials.modify("anthropic", async () => ({ type: "api_key", key: "sk-ant-key" }));
asked.length = 0;
listing = await providers.askProvider("anthropic");
assert.deepEqual(listing.models.map((m) => [m.id, m.known]), [["claude-opus-6", false], ["claude-opus-5-5", true]]);
assert.deepEqual(asked.map((a) => [a.path, a.headers["x-api-key"], a.headers["anthropic-version"], a.headers.authorization]), [
	["/anthropic/v1/models?limit=1000", "sk-ant-key", "2023-06-01", undefined],
	["/anthropic/v1/models?limit=1000&after_id=claude-opus-1", "sk-ant-key", "2023-06-01", undefined],
]);
const opus = providers.draftModel("anthropic", "claude-opus-6");
assert.deepEqual([opus.contextWindow, opus.maxTokens, opus.vision, opus.thinkingLevels], [1_000_000, 128_000, true, ["off", "low", "high", "max"]]);
// With a Claude sign-in instead: the token as a bearer, with the beta Anthropic asks of a sign-in.
await credentials.modify("anthropic", async () => ({ type: "oauth", access: "sk-ant-oat-token", refresh: "r", expires: Date.now() + 3_600_000 }));
asked.length = 0;
await providers.askProvider("anthropic");
assert.deepEqual([asked[0]!.headers.authorization, asked[0]!.headers["anthropic-beta"], asked[0]!.headers["x-api-key"]], ["Bearer sk-ant-oat-token", "oauth-2025-04-20", undefined]);
step("Anthropic is asked with a key or a Claude sign-in, page by page");

// OpenAI with a key, and with a ChatGPT sign-in, whose token is for the same API.
await credentials.modify("openai", async () => ({ type: "api_key", key: "sk-openai" }));
asked.length = 0;
listing = await providers.askProvider("openai");
assert.deepEqual(listing.models.map((m) => [m.id, m.known]), [["gpt-6.3", false], ["gpt-6.1-sol", true]]);
assert.equal(providers.draftModel("openai", "gpt-6.3").contextWindow, 64_000);
await credentials.modify("openai", async () => ({ type: "oauth", access: "chatgpt-token", refresh: "r", expires: Date.now() + 3_600_000 }));
await providers.askProvider("openai");
assert.deepEqual(asked.map((a) => [a.path, a.headers.authorization]), [["/openai/v1/models", "Bearer sk-openai"], ["/openai/v1/models", "Bearer chatgpt-token"]]);
step("OpenAI is asked with a key or a ChatGPT sign-in");

// Google, with a key; models that cannot chat left out.
await credentials.modify("google", async () => ({ type: "api_key", key: "g-key" }));
asked.length = 0;
listing = await providers.askProvider("google");
assert.deepEqual(listing.models.map((m) => m.id), ["gemini-9-pro"]);
assert.equal(asked[0]!.headers["x-goog-api-key"], "g-key");
assert.equal(providers.draftModel("google", "gemini-9-pro").contextWindow, 2_000_000);
step("Google is asked with a key");

// Refusals and the rest say plainly what happened, and keys are not repeated.
await credentials.modify("refuser", async () => ({ type: "api_key", key: "sk-refused" }));
await assert.rejects(providers.askProvider("refuser"), (error: Error) => {
	assert.equal(error.message, "Refuser answered 401: invalid_request_error: Incorrect API key provided: [key]. It may not let this key or sign-in list its models: add a model by its id instead.");
	assert.doesNotMatch(error.message, /sk-abcdefghijklmnopqrstuvwxyz123456/);
	return true;
});
await credentials.modify("redirector", async () => ({ type: "api_key", key: "sk-redirect" }));
asked.length = 0;
await assert.rejects(providers.askProvider("redirector"), /Redirector sent pi² on to elsewhere\.invalid, which pi² does not follow: only 127\.0\.0\.1:\d+ is asked\.$/);
assert.deepEqual(asked.map((a) => a.path), ["/redirect/v1/models"], "a redirect elsewhere is not followed");
await assert.rejects(providers.askProvider("github-copilot"), /GitHub Copilot lists its models only to its own apps/);
await assert.rejects(providers.askProvider("anthropic-not-there"), /Unknown provider/);
await credentials.delete("refuser");
await assert.rejects(providers.askProvider("refuser"), /Sign in to Refuser or add its key first/);
step("a refusal, a redirect and a provider that cannot be asked are said plainly, without the key");

// The library's own refresh: at start for providers with a stored credential, kept for the next start, and on asking.
// An added model the refreshed list comes to have gives way to it.
await providers.addModel({ provider: "dynamic", id: "dyn-2", basedOn: "dyn-1", contextWindow: 1000, maxTokens: 100, vision: false, thinkingLevels: [] });
assert.equal(providers.isAddedByHand("dynamic", "dyn-2"), true);
const errors = await providers.refreshCatalogs();
assert.equal(errors.size, 0);
assert.equal(fetched, 1);
assert.deepEqual(providers.models.getModels("dynamic").map((m) => m.id), ["dyn-1", "dyn-2"]);
assert.equal(providers.isAddedByHand("dynamic", "dyn-2"), false, "the refreshed catalog's own entry took its place");
assert.equal(JSON.parse(readFileSync(join(home, "added-models.json"), "utf8")).dynamic, undefined);
assert.ok(JSON.parse(readFileSync(join(home, "model-catalogs.json"), "utf8")).dynamic.models.some((m: { id: string }) => m.id === "dyn-2"));
listing = await providers.askProvider("dynamic");
assert.deepEqual([listing.refreshed, listing.asked, listing.catalogCount, fetched], [true, null, 2, 2]);
// The next start has the list at once, from the store, before asking again.
providers = open();
await credentials.delete("dynamic");
await providers.refreshCatalogs();
assert.equal(fetched, 2, "no credential stored: not asked");
assert.deepEqual(providers.models.getModels("dynamic").map((m) => m.id), ["dyn-1", "dyn-2"]);
step("the catalogs the library refreshes itself are refreshed at start and on asking, and kept for the next start");

standIn.close();
