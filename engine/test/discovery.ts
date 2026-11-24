// Explicit subscription discovery adapters and their shared lifecycle. All traffic goes to localhost stand-ins.
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { type Api, createModels, type CreateModelsOptions, createProvider, InMemoryCredentialStore, type Model } from "@earendil-works/pi-ai";
import { openAIResponsesApi } from "@earendil-works/pi-ai/api/openai-responses.lazy";
import { listerFor } from "../src/modellists.ts";
import { Providers } from "../src/providers.ts";
import { providersEvent, wireDefaultModel } from "../src/defaultmodel.ts";
import { providerRequests, refreshDiscoveredProviders, wireProviderRequests } from "../src/providerrequests.ts";

const home = mkdtempSync(join(tmpdir(), "pi2-discovery-"));
process.on("exit", () => rmSync(home, { recursive: true, force: true }));
function gate() {
	let resolve!: () => void;
	const promise = new Promise<void>((done, reject) => {
		const timeout = setTimeout(() => reject(new Error("Discovery fixture did not reach its gate")), 600_000).unref();
		resolve = () => { clearTimeout(timeout); done(); };
	});
	return { promise, resolve };
}
const credentials = new InMemoryCredentialStore();
let loginAccess = "claude-account-a";
let rotatedAccess = "claude-account-a-rotated";
let rotates = 0;
const status = new Map<string, number>();
let goBody: unknown;
let refuseSecondPage = false;
const gates = new Map<string, { arrived: ReturnType<typeof gate>; released: ReturnType<typeof gate> }>();
const asked: { path: string; headers: import("node:http").IncomingHttpHeaders }[] = [];
const go = (id: string, protocol: string) => ({ id, type: "chat", name: `Listed ${id}`, api: { [protocol]: { base_url: "https://attacker.invalid/steal-key" } },
	limit: { context: 999_000, output: 16_000 }, modalities: { input: ["text", "image/png"] }, capabilities: { reasoning: { supported: true, effort: ["low", "high", "xhigh"] } } });
const goModels: unknown[] = [go("claude-next", "messages"), go("gpt-next", "responses"), go("kimi-next", "chat-completions"), go("gemini-next", "generate-content"),
	{ ...go("no-thought", "chat-completions"), capabilities: { reasoning: { supported: false } } },
	{ ...go("embedding-1", "chat-completions"), type: "embedding" }, { ...go("decision-1", "responses"), type: "decision" },
	{ id: "no-metadata" }, { ...go("unknown-protocol", "unrecognized") },
	{ ...go("ambiguous", "responses"), api: { responses: {}, messages: {} } }];
const server = createServer(async (request, response) => {
	const path = request.url!;
	const id = path.startsWith("/anthropic/") ? "anthropic" : "opencode-go";
	asked.push({ path, headers: request.headers });
	const held = gates.get(id);
	if (held) { held.arrived.resolve(); await held.released.promise; }
	const code = status.get(id) ?? 200;
	if (code === 302) { response.writeHead(302, { location: "https://attacker.invalid/list" }).end(); return; }
	if (code !== 200) { response.writeHead(code).end("refused"); return; }
	const json = (body: unknown) => response.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify(body));
	if (path === "/anthropic/v1/models?limit=1000") return void json({ data: [{ id: "claude-new", display_name: "New Claude", max_input_tokens: 800_000, max_tokens: 48_000,
		capabilities: { image_input: { supported: true }, thinking: { supported: true }, effort: { low: { supported: true }, high: { supported: true } } } },
		{ id: "retired", lifecycle: "retired" }], has_more: true, last_id: "page-1" });
	if (path === "/anthropic/v1/models?limit=1000&after_id=page-1") {
		if (refuseSecondPage) { response.writeHead(403).end("second page refused"); return; }
		return void json({ data: [{ id: "claude-newer" }], has_more: false });
	}
	if (path === "/inference/go/v1/models") return void json(goBody ?? { data: goModels });
	response.writeHead(404).end();
});
await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
const origin = `http://127.0.0.1:${(server.address() as { port: number }).port}`;
function model(id: string, api: string, baseUrl: string): Model<Api> {
	return { id, api, baseUrl, name: id, provider: "", reasoning: true, input: ["text"], contextWindow: 200_000, maxTokens: 8000,
		cost: { input: 1, output: 1, cacheRead: 0, cacheWrite: 0 } } as Model<Api>;
}
function builtins(options?: CreateModelsOptions) {
	const models = createModels(options);
	const oauth = { name: "Claude", isSubscription: true, login: async () => ({ type: "oauth", access: loginAccess, refresh: "r", expires: Date.now() + 3_600_000 }),
		refresh: async () => { rotates++; return { type: "oauth", access: rotatedAccess, refresh: "r2", expires: Date.now() + 3_600_000 }; },
		toAuth: async (c: { access: string }) => ({ apiKey: c.access }) };
	const keyAuth = { name: "Key", resolve: async ({ credential }: { credential?: { key?: string } }) => credential?.key ? { auth: { apiKey: credential.key } } : undefined };
	const add = (id: string, auth: object, list: Model<Api>[]) => models.setProvider(createProvider({ id, name: id, auth: auth as never,
		models: list.map((m) => ({ ...m, provider: id })), api: openAIResponsesApi() }));
	add("anthropic", { oauth, apiKey: keyAuth }, [model("claude-old", "anthropic-messages", `${origin}/anthropic`)]);
	add("opencode-go", { apiKey: keyAuth }, [model("claude-old", "anthropic-messages", `${origin}/inference/go/anthropic`),
		model("gpt-old", "openai-responses", `${origin}/inference/go/openai/v1`), model("kimi-old", "openai-completions", `${origin}/inference/go/openai/v1`),
		model("gemini-old", "google-generative-ai", `${origin}/inference/go/google/v1beta`)]);
	add("unsupported", { apiKey: keyAuth }, [model("old", "openai-completions", `${origin}/unsupported`)]);
	return models;
}
const open = () => new Providers(home, credentials, () => "test", { builtins });
let providers = open();
const storeClaude = async (access: string, expires = Date.now() + 3_600_000) => credentials.modify("anthropic", async () => ({ type: "oauth", access, refresh: "r", expires }));
await storeClaude(loginAccess);
await providers.setKey("opencode-go", "go-key-a");
await providers.setKey("unsupported", "unsupported-key");
const now = Date.now();

// A slow Claude listing does not block Go, and callers share a provider's in-flight request.
const held = { arrived: gate(), released: gate() };
gates.set("anthropic", held);
const claude = providers.refreshDiscoveredModels("anthropic", now);
assert.equal(providers.refreshDiscoveredModels("anthropic", now), claude);
await held.arrived.promise;
assert.equal(await providers.refreshDiscoveredModels("opencode-go", now), true);
assert.equal(providers.models.getModel("anthropic", "claude-new"), undefined);
held.released.resolve();
await claude;
gates.delete("anthropic");
assert.deepEqual(asked.filter((a) => a.path.startsWith("/anthropic")).map((a) => a.path), ["/anthropic/v1/models?limit=1000", "/anthropic/v1/models?limit=1000&after_id=page-1"]);
const claudeRequest = asked.find((a) => a.path.startsWith("/anthropic"))!;
assert.equal(claudeRequest.headers.authorization, "Bearer claude-account-a");
assert.equal(claudeRequest.headers["anthropic-beta"], "oauth-2025-04-20");
assert.equal(claudeRequest.headers["anthropic-version"], "2023-06-01");
assert.equal(asked.find((a) => a.path.startsWith("/inference"))!.headers.authorization, "Bearer go-key-a");
const claudeModel = (await providers.listModels()).find((m) => m.provider === "anthropic" && m.id === "claude-new")!;
assert.deepEqual([claudeModel.contextWindow, claudeModel.vision, claudeModel.thinkingLevels], [800_000, true, ["off", "low", "high"]]);
assert.equal(providers.models.getModel("anthropic", "retired"), undefined);
for (const [id, api, route] of [["claude-next", "anthropic-messages", "/anthropic"], ["gpt-next", "openai-responses", "/openai/v1"], ["kimi-next", "openai-completions", "/openai/v1"], ["gemini-next", "google-generative-ai", "/google/v1beta"]]) {
	const found = providers.models.getModel("opencode-go", id!)!;
	assert.equal(found.api, api);
	assert.equal(found.baseUrl, `${origin}/inference/go${route}`);
	assert.equal(found.contextWindow, 999_000);
	assert.equal(found.maxTokens, 16_000);
	assert.deepEqual(found.input, ["text", "image"]);
}
assert.equal(providers.models.getModel("opencode-go", "no-thought")!.reasoning, false);
assert.equal(providers.hasUnknownPrice("opencode-go", "kimi-next"), true, "discovered pricing is unknown, not free");
assert.equal(providers.hasUnknownPrice("opencode-go", "kimi-old"), false, "catalog pricing is retained");
for (const id of ["embedding-1", "decision-1", "no-metadata", "unknown-protocol", "ambiguous"]) assert.equal(providers.models.getModel("opencode-go", id), undefined);
const requests = asked.length;
assert.equal(await providers.refreshDiscoveredModels("anthropic", now + 1), false);
assert.equal(await providers.refreshDiscoveredModels("opencode-go", now + 1), false);
assert.equal(await providers.refreshDiscoveredModels("unsupported", now), false);
assert.equal(asked.length, requests);
console.log("ok independent/coalesced/throttled adapters, canonical Go URL, explicit metadata and trusted routes");

const settings = { hiddenModels: { anthropic: ["claude-new"], "opencode-go": ["gpt-next"] } };
wireDefaultModel({ settings, providers, saveSettings: () => {}, host: { features: [] } as never, log: () => {}, followersChanged: () => {} });
for (const m of (await providersEvent()).models.filter((m) => m.id === "claude-new" || m.id === "gpt-next")) assert.equal(m.hidden, true);
await providers.addModel({ ...providers.draftModel("opencode-go", "gpt-next"), provider: "opencode-go", name: "Manual name" });
assert.equal(await providers.refreshDiscoveredModels("opencode-go", now + 6 * 60 * 60_000), true);
assert.equal(providers.models.getModel("opencode-go", "gpt-next")!.name, "Manual name");
providers.removeModel("opencode-go", "gpt-next");

// Same-scope offline restart, refusal/backoff, and opaque-token rotation on a failing network request.
providers = open();
await providers.listModels();
assert.ok(providers.models.getModel("anthropic", "claude-new"));
status.set("anthropic", 403);
assert.equal(await providers.refreshDiscoveredModels("anthropic", now), false);
assert.ok(providers.models.getModel("anthropic", "claude-new"));
const refused = asked.length;
await providers.refreshDiscoveredModels("anthropic", now + 1);
assert.equal(asked.length, refused);
await storeClaude(loginAccess, 0);
assert.equal(await providers.refreshDiscoveredModels("anthropic", now + 15 * 60_000), true, "changed announces removal after rotation");
assert.equal(rotates, 1);
assert.equal(providers.models.getModel("anthropic", "claude-new"), undefined);
providers = open();
await providers.listModels();
assert.equal(providers.models.getModel("anthropic", "claude-new"), undefined);
status.delete("anthropic");
assert.equal(await providers.refreshDiscoveredModels("anthropic"), true);
assert.ok(providers.models.getModel("anthropic", "claude-new"));
console.log("ok hidden/manual choices, refused Claude listing, offline reuse, rotation failure and recovery");

// Credential switches plus failed cache clearing cannot reintroduce old models, even on restart.
for (const id of ["anthropic", "opencode-go"]) {
	const path = join(home, `${id}-discovered-models.json`);
	const bytes = readFileSync(path, "utf8");
	assert.doesNotMatch(bytes, /claude-account-a|go-key-a/);
	renameSync(path, `${path}.saved`);
	mkdirSync(path);
	if (id === "anthropic") { loginAccess = "claude-account-b"; await providers.login(id, { notify: () => {}, prompt: async () => "" }); }
	else await providers.setKey(id, "go-key-b");
	rmSync(path, { recursive: true });
	renameSync(`${path}.saved`, path);
	status.set(id, 401);
	providers = open();
	await providers.listModels();
	const target = id === "anthropic" ? "claude-new" : "kimi-next";
	assert.equal(providers.models.getModel(id, target), undefined);
	await providers.refreshDiscoveredModels(id);
	assert.equal(providers.models.getModel(id, target), undefined);
	status.delete(id);
}
console.log("ok provider-scoped cache rejects previous credentials after failed clearing and restart");

// Redirects and explicit cancellation never follow another host or publish partial discoveries.
status.set("opencode-go", 302);
providers = open();
await providers.refreshDiscoveredModels("opencode-go");
assert.equal(providers.models.getModel("opencode-go", "kimi-next"), undefined);
status.delete("opencode-go");
const cancelGate = { arrived: gate(), released: gate() };
gates.set("opencode-go", cancelGate);
const lister = listerFor("opencode-go", "Go", providers.models.getModels("opencode-go"), "api_key", "https://attacker.invalid");
assert.ok(!("cannot" in lister));
assert.equal(lister.url, `${origin}/inference/go/v1/models`);
const abort = new AbortController();
const cancelled = lister.list({ apiKey: "stand-in" }, abort.signal);
const rejects = assert.rejects(cancelled, /Could not reach/);
await cancelGate.arrived.promise;
abort.abort();
await rejects;
cancelGate.released.resolve();
gates.delete("opencode-go");

// Exercise the same operation main uses for startup and timer refreshes and both credential-change requests.
providers = open();
let announce = gate();
let expectProvider = "anthropic";
let expectId = "claude-new";
wireProviderRequests({ providers, settings: {}, saveSettings: () => {}, log: () => {}, announceProviders: async () => {
	if ((await providers.listModels()).some((m) => m.provider === expectProvider && m.id === expectId)) announce.resolve();
} });
await refreshDiscoveredProviders();
await announce.promise;
const startupRequests = asked.length;
await refreshDiscoveredProviders();
assert.equal(asked.length, startupRequests, "timer path respects each provider's throttle");
for (const id of ["anthropic", "opencode-go"]) {
	await providers.logout(id);
	announce = gate();
	expectProvider = id;
	expectId = id === "anthropic" ? "claude-new" : "kimi-next";
	const held = { arrived: gate(), released: gate() };
	gates.set(id, held);
	if (id === "anthropic") await providerRequests["providers.login"]!({ id }, { socket: { destroyed: true } } as never);
	else await providerRequests["providers.setKey"]!({ id, key: "go-key-c" }, {} as never);
	await held.arrived.promise;
	assert.equal(providers.models.getModel(id, expectId), undefined);
	held.released.resolve();
	await announce.promise;
	gates.delete(id);
	assert.ok(providers.models.getModel(id, expectId));
	const staleGate = { arrived: gate(), released: gate() };
	gates.set(id, staleGate);
	const stale = providers.refreshDiscoveredModels(id, Date.now() + 7 * 60 * 60_000);
	await staleGate.arrived.promise;
	await providers.logout(id);
	staleGate.released.resolve();
	await stale;
	gates.delete(id);
	assert.equal(providers.models.getModel(id, expectId), undefined);
}
console.log("ok startup/timer and sign-in/key-change announcements, nonblocking requests, gated logout races");

// Wrong credential types, missing credentials, and legacy unbound caches never trigger discovery.
await providers.setKey("anthropic", "not-a-subscription");
await credentials.modify("opencode-go", async () => ({ type: "oauth", access: "wrong-type", refresh: "r", expires: Date.now() + 10000 }));
providers = open();
const beforeWrong = asked.length;
await refreshDiscoveredProviders(); // still wired to previous instance, whose credentials are the same
await providers.refreshDiscoveredModels("anthropic");
await providers.refreshDiscoveredModels("opencode-go");
assert.equal(asked.length, beforeWrong);
writeFileSync(join(home, "anthropic-discovered-models.json"), "[null]");
assert.doesNotThrow(() => open().models.getModels("anthropic"));
// Malformed lists and partially refused pagination cannot publish incomplete new discoveries.
await storeClaude("fresh-claude");
refuseSecondPage = true;
providers = open();
await providers.refreshDiscoveredModels("anthropic");
assert.equal(providers.models.getModel("anthropic", "claude-new"), undefined);
refuseSecondPage = false;
await providers.setKey("opencode-go", "fresh-go");
goBody = { data: "not-a-list" };
await providers.refreshDiscoveredModels("opencode-go");
assert.equal(providers.models.getModel("opencode-go", "kimi-next"), undefined);
goBody = undefined;

// A changed credential bypasses the old success throttle, but failures cannot resurrect its cache.
providers = open();
await providers.refreshDiscoveredModels("opencode-go", now);
assert.ok(providers.models.getModel("opencode-go", "kimi-next"));
await credentials.modify("opencode-go", async () => ({ type: "api_key", key: "another-go-account" }));
status.set("opencode-go", 503);
await providers.refreshDiscoveredModels("opencode-go", now + 1);
assert.equal(providers.models.getModel("opencode-go", "kimi-next"), undefined);
status.delete("opencode-go");

// Switch credentials while a request is definitely underway, even without the lifecycle invalidation hook.
for (const id of ["anthropic", "opencode-go"]) {
	providers = open();
	const held = { arrived: gate(), released: gate() };
	gates.set(id, held);
	const pending = providers.refreshDiscoveredModels(id);
	await held.arrived.promise;
	if (id === "anthropic") await storeClaude("changed-mid-request");
	else await credentials.modify(id, async () => ({ type: "api_key", key: "changed-mid-request" }));
	held.released.resolve();
	await pending;
	gates.delete(id);
	assert.equal(providers.models.getModel(id, id === "anthropic" ? "claude-new" : "kimi-next"), undefined);
}
console.log("ok malformed/partial lists, credential-change throttle reset and in-flight scope changes fail closed");
server.close();
console.log("PASS");
