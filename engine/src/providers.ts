// Model access: every built-in pi-ai provider, the user's own endpoints, and a scripted demo model.

import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import {
	type AuthInteraction,
	createProvider,
	type CredentialStore,
	getSupportedThinkingLevels,
	type Model,
	type MutableModels,
	type Provider,
} from "@earendil-works/pi-ai";
import { anthropicMessagesApi } from "@earendil-works/pi-ai/api/anthropic-messages.lazy";
import { openAICompletionsApi } from "@earendil-works/pi-ai/api/openai-completions.lazy";
import { openAIResponsesApi } from "@earendil-works/pi-ai/api/openai-responses.lazy";
import { builtinModels } from "@earendil-works/pi-ai/providers/all";
import { fauxAssistantMessage, fauxProvider, fauxText, fauxToolCall } from "@earendil-works/pi-ai/providers/faux";

export const DEMO_PROVIDER = "demo";
export const DEMO_MODEL = "demo-1";

export type EndpointApi = "openai-completions" | "openai-responses" | "anthropic-messages";
export type EndpointModel = { id: string; name?: string; contextWindow?: number; reasoning?: boolean };
export type EndpointConfig = { id: string; name: string; baseUrl: string; api: EndpointApi; models: EndpointModel[] };

export type ProviderInfo = {
	id: string;
	name: string;
	kind: "builtin" | "custom" | "demo";
	keyAuth: boolean;
	oauth: { name: string; subscription: boolean } | null;
	/** How the provider is configured right now, or null when it is not. */
	status: { type: string; source: string | null } | null;
	modelCount: number;
	endpoint: EndpointConfig | null;
};

export type ModelInfo = {
	provider: string;
	providerName: string;
	id: string;
	name: string;
	thinkingLevels: string[];
	contextWindow: number;
	/** Left out of the model pickers by the person's choice in settings. */
	hidden?: boolean;
};

/**
 * Of a provider's model ids, the newest of each family, for the "newest only" shortcut in settings.
 * A family is the id without its version numbers and dates ("claude-opus", "gpt-mini"), so "claude-opus-5-5" replaces
 * "claude-opus-4-8" but not "claude-sonnet-5". It is a guess from naming, which is why the person can adjust the result.
 */
export function newestOnly(ids: readonly string[]): Set<string> {
	const best = new Map<string, { id: string; version: number[] }>();
	for (const id of ids) {
		const family: string[] = [];
		const version: number[] = [];
		// Date stamps ("-20251101", "-2024-05-13", "-04-2026") say which build, not which version.
		for (const token of id.replace(/-(\d{4}-\d{2}-\d{2}|\d{2}-\d{4}|\d{6,})(?=-|$)/g, "").split("-")) {
			if (/^\d+(\.\d+)*$/.test(token)) version.push(...token.split(".").map(Number));
			else if (token !== "latest" && token !== "preview") family.push(token);
		}
		const key = family.join("-");
		const held = best.get(key);
		let newer = held === undefined;
		if (held !== undefined) {
			let order = 0;
			for (let i = 0; i < Math.max(version.length, held.version.length) && order === 0; i++) order = (version[i] ?? 0) - (held.version[i] ?? 0);
			// The same version twice is one model under two ids (a dated one and its alias): keep the shorter.
			newer = order > 0 || (order === 0 && id.length < held.id.length);
		}
		if (newer) best.set(key, { id, version });
	}
	return new Set([...best.values()].map((entry) => entry.id));
}

const ENDPOINT_APIS: readonly EndpointApi[] = ["openai-completions", "openai-responses", "anthropic-messages"];

function textOf(content: unknown): string {
	if (typeof content === "string") return content;
	if (!Array.isArray(content)) return "";
	return content.map((block) => (block?.type === "text" && typeof block.text === "string" ? block.text : "")).join("");
}

/** A scripted stand-in model so the app works before any provider is connected. `/bash` and `/read` make it call tools. */
function demoProvider(): Provider {
	// Tests add a second demo model that cannot see images, to check what such a model is given.
	const textOnly = process.env.PI2_DEMO_TEXT_MODEL === "1" ? [{ id: "demo-text", name: "Demo model (text only)", input: ["text" as const] }] : [];
	const faux = fauxProvider({ provider: DEMO_PROVIDER, models: [{ id: DEMO_MODEL, name: "Demo model (scripted)" }, ...textOnly], tokensPerSecond: 20 });
	const step = (request: { messages: readonly unknown[] }) => {
		// The newest thing to answer. A tool or prompt change can add a system message after it, so skip those.
		const last = (request.messages as readonly { role?: string; content?: unknown; isError?: boolean }[]).findLast(
			(message) => message.role === "user" || message.role === "toolResult",
		);
		if (last?.role === "toolResult") {
			// Says how many pictures it was sent, so it is visible that old screenshots are left out.
			const pictures = (request.messages as readonly { content?: unknown }[]).reduce(
				(count, message) => count + (Array.isArray(message.content) ? message.content.filter((block) => block?.type === "image").length : 0),
				0,
			);
			const seen = pictures === 0 ? "" : ` I can see ${pictures} picture${pictures === 1 ? "" : "s"}.`;
			return fauxAssistantMessage(last.isError ? "The tool reported an error; its output is above." : `Done. The tool returned: ${textOf(last.content).slice(0, 200)}${seen}`);
		}
		const prompt = textOf(last?.content).trim();
		if (prompt.startsWith("/bash ")) {
			return fauxAssistantMessage([fauxText("Running that command."), fauxToolCall("bash", { command: prompt.slice(6) })], { stopReason: "toolUse" });
		}
		if (prompt.startsWith("/ask ")) {
			return fauxAssistantMessage([fauxText("I need to check something with you."), fauxToolCall("ask_user", { question: prompt.slice(5) })], { stopReason: "toolUse" });
		}
		if (prompt.startsWith("/continue ")) {
			// "/continue <sub-chat number>: <task>"
			const [chat, ...task] = prompt.slice(10).split(":");
			return fauxAssistantMessage([fauxText("Carrying on in that sub-chat."), fauxToolCall("delegate", { agent: "", chat: Number(chat), task: task.join(":").trim() })], { stopReason: "toolUse" });
		}
		if (prompt.startsWith("/computer ")) {
			// "/computer {json arguments}"
			return fauxAssistantMessage([fauxText("Using the computer."), fauxToolCall("computer", JSON.parse(prompt.slice(10)))], { stopReason: "toolUse" });
		}
		if (prompt.startsWith("/browser ")) {
			// "/browser {json arguments}"
			return fauxAssistantMessage([fauxText("Using the browser."), fauxToolCall("browser", JSON.parse(prompt.slice(9)))], { stopReason: "toolUse" });
		}
		if (prompt.startsWith("/ref ")) {
			return fauxAssistantMessage([fauxText("Opening that reference file."), fauxToolCall("read_reference", { path: prompt.slice(5).trim() })], { stopReason: "toolUse" });
		}
		if (prompt.startsWith("/delegate ")) {
			const [agent, ...task] = prompt.slice(10).split(":");
			return fauxAssistantMessage([fauxText(`Handing that to ${agent!.trim()}.`), fauxToolCall("delegate", { agent: agent!.trim(), task: task.join(":").trim() })], { stopReason: "toolUse" });
		}
		if (prompt.startsWith("/code ")) {
			return fauxAssistantMessage([fauxText("Running a script."), fauxToolCall("codemode", { code: prompt.slice(6) })], { stopReason: "toolUse" });
		}
		if (prompt.startsWith("/mcp ")) {
			// "/mcp <tool name> <json arguments>"
			const [name, ...rest] = prompt.slice(5).split(" ");
			return fauxAssistantMessage([fauxText("Calling that tool."), fauxToolCall(name!, JSON.parse(rest.join(" ") || "{}"))], { stopReason: "toolUse" });
		}
		if (prompt.startsWith("/read ")) {
			return fauxAssistantMessage([fauxText("Reading that file."), fauxToolCall("read", { path: prompt.slice(6).trim() })], { stopReason: "toolUse" });
		}
		return fauxAssistantMessage(
			`You said: "${prompt}". I am the demo model, a scripted stand-in with no intelligence behind it. ` +
				"Connect a real provider in Settings, then pick its model from the toolbar. " +
				"Until then you can try `/bash <command>`, `/read <path>`, `/ask <question>` or `/delegate <agent>: <task>` " +
				"to see tool calls. One, two, three, four, five. Done.",
		);
	};
	faux.setResponses(Array.from({ length: 100_000 }, () => step));
	return faux.provider;
}

/** Sent as the key to an endpoint that was saved without one. */
const KEYLESS = "no-key";

function endpointProvider(config: EndpointConfig): Provider {
	const api = { "openai-completions": openAICompletionsApi, "openai-responses": openAIResponsesApi, "anthropic-messages": anthropicMessagesApi }[config.api]();
	const models = config.models.map((m) => {
		const contextWindow = m.contextWindow ?? 128_000;
		return {
			id: m.id,
			name: m.name ?? m.id,
			api: config.api,
			provider: config.id,
			baseUrl: config.baseUrl,
			reasoning: m.reasoning ?? false,
			input: ["text"],
			cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
			contextWindow,
			maxTokens: Math.min(16_384, Math.floor(contextWindow / 4)),
			// Local and self-hosted servers rarely know the newer OpenAI request fields.
			...(config.api === "openai-completions" ? { compat: { supportsDeveloperRole: false, supportsReasoningEffort: m.reasoning ?? false } } : {}),
		} as Model<EndpointApi>;
	});
	return createProvider({
		id: config.id,
		name: config.name,
		baseUrl: config.baseUrl,
		// A stored key is used when there is one. A server without one (Ollama, LM Studio, llama.cpp) is still
		// "configured": pi-ai refuses to send a request with no key at all, so it is given a stand-in, which such
		// servers ignore.
		auth: { apiKey: { name: config.name, resolve: async ({ credential }) => ({ auth: { apiKey: credential?.key ? credential.key : KEYLESS } }) } },
		models,
		api,
	});
}

export class Providers {
	readonly models: MutableModels;
	readonly #credentials: CredentialStore;
	readonly #endpointsPath: string;
	#endpoints: EndpointConfig[];
	readonly #builtinIds: Set<string>;
	readonly #deviceId: () => string;

	/** `deviceId` returns this installation's stable UUID; some sign-ins (ChatGPT) identify the app by it. */
	constructor(home: string, credentials: CredentialStore, deviceId: () => string) {
		this.#credentials = credentials;
		this.#deviceId = deviceId;
		this.models = builtinModels({ credentials, identity: { attribution: { name: "pi2", url: "https://github.com/earendil-works/pi" } } });
		this.#builtinIds = new Set(this.models.getProviders().map((p) => p.id));
		this.models.setProvider(demoProvider());
		this.#endpointsPath = join(home, "endpoints.json");
		try {
			this.#endpoints = JSON.parse(readFileSync(this.#endpointsPath, "utf8"));
		} catch {
			this.#endpoints = [];
		}
		for (const endpoint of this.#endpoints) this.models.setProvider(endpointProvider(endpoint));
	}

	async listProviders(): Promise<ProviderInfo[]> {
		const providers = this.models.getProviders();
		return Promise.all(
			providers.map(async (provider): Promise<ProviderInfo> => {
				const endpoint = this.#endpoints.find((e) => e.id === provider.id) ?? null;
				const kind = provider.id === DEMO_PROVIDER ? "demo" : endpoint ? "custom" : "builtin";
				// A broken credential (say, a refresh that failed) reads as not configured; signing in again fixes it.
				const check = await this.models.checkAuth(provider.id).catch(() => undefined);
				return {
					id: provider.id,
					name: provider.name,
					kind,
					keyAuth: kind === "builtin" && provider.auth.apiKey !== undefined,
					oauth: provider.auth.oauth ? { name: provider.auth.oauth.name, subscription: provider.auth.oauth.isSubscription === true } : null,
					status: check ? { type: check.type, source: check.source ?? null } : null,
					modelCount: provider.getModels().length,
					endpoint,
				};
			}),
		);
	}

	/** Providers whose work is currently paid for by a subscription sign-in, so their tokens have no per-use price. */
	async subscriptionProviders(): Promise<Set<string>> {
		const ids = new Set<string>();
		for (const provider of this.models.getProviders()) {
			if (provider.auth.oauth?.isSubscription !== true) continue;
			const check = await this.models.checkAuth(provider.id).catch(() => undefined);
			if (check?.type === "oauth") ids.add(provider.id);
		}
		return ids;
	}

	/** Chat models of every provider that is configured. */
	async listModels(): Promise<ModelInfo[]> {
		const names = new Map(this.models.getProviders().map((p) => [p.id, p.name]));
		const available = await this.models.getAvailable();
		return available.map((model) => ({
			provider: model.provider,
			providerName: names.get(model.provider) ?? model.provider,
			id: model.id,
			name: model.name,
			thinkingLevels: model.reasoning ? getSupportedThinkingLevels(model) : [],
			contextWindow: model.contextWindow,
		}));
	}

	async setKey(providerId: string, key: string): Promise<void> {
		if (this.models.getProvider(providerId) === undefined) throw new Error(`Unknown provider: ${providerId}`);
		if (key.trim() === "") throw new Error("The key is empty");
		await this.#credentials.modify(providerId, async () => ({ type: "api_key", key: key.trim() }));
	}

	async logout(providerId: string): Promise<void> {
		await this.models.logout(providerId);
	}

	/** Subscription or OAuth sign-in. pi-ai drives the flow and stores the credential. */
	async login(providerId: string, interaction: AuthInteraction): Promise<void> {
		const provider = this.models.getProvider(providerId);
		if (provider?.auth.oauth === undefined) throw new Error(`${providerId} has no sign-in flow`);
		await this.models.login(providerId, "oauth", interaction, { getDeviceId: this.#deviceId, agentName: "pi2" });
	}

	// ---- The user's own endpoints

	async saveEndpoint(input: { id?: string; name: string; baseUrl: string; api: string; models: EndpointModel[]; key?: string }): Promise<EndpointConfig> {
		const name = input.name.trim();
		const baseUrl = input.baseUrl.trim().replace(/\/+$/, "");
		if (name === "") throw new Error("Give the endpoint a name");
		if (!/^https?:\/\/\S+$/.test(baseUrl)) throw new Error("The base URL must start with http:// or https://");
		if (!ENDPOINT_APIS.includes(input.api as EndpointApi)) throw new Error(`Unknown API style: ${input.api}`);
		const models = input.models.filter((m) => typeof m.id === "string" && m.id.trim() !== "");
		if (models.length === 0) throw new Error("Add at least one model");
		let id = input.id;
		if (id === undefined) {
			const slug = name.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "") || "endpoint";
			id = `custom-${slug}`;
			for (let n = 2; this.models.getProvider(id) !== undefined; n++) id = `custom-${slug}-${n}`;
		} else if (!this.#endpoints.some((e) => e.id === id)) {
			throw new Error(`Unknown endpoint: ${id}`);
		}
		const config: EndpointConfig = { id, name, baseUrl, api: input.api as EndpointApi, models };
		this.#endpoints = [...this.#endpoints.filter((e) => e.id !== id), config];
		this.#persist();
		this.models.setProvider(endpointProvider(config));
		if (input.key !== undefined && input.key.trim() !== "") await this.setKey(id, input.key);
		return config;
	}

	async removeEndpoint(id: string): Promise<void> {
		if (!this.#endpoints.some((e) => e.id === id)) throw new Error(`Unknown endpoint: ${id}`);
		this.#endpoints = this.#endpoints.filter((e) => e.id !== id);
		this.#persist();
		this.models.deleteProvider(id);
		await this.#credentials.delete(id);
	}

	/** Ask a server which models it serves, the way OpenAI-compatible servers answer `GET /models`. */
	async probeEndpoint(baseUrl: string, key?: string): Promise<string[]> {
		const url = `${baseUrl.trim().replace(/\/+$/, "")}/models`;
		const headers: Record<string, string> = {};
		if (key !== undefined && key.trim() !== "") {
			headers.authorization = `Bearer ${key.trim()}`;
			headers["x-api-key"] = key.trim();
		}
		let response: Response;
		try {
			response = await fetch(url, { headers, signal: AbortSignal.timeout(6_000) });
		} catch (error) {
			throw new Error(`Could not reach ${url}: ${error instanceof Error ? error.message : String(error)}`);
		}
		if (!response.ok) throw new Error(`${url} answered ${response.status} ${response.statusText}`);
		const body = (await response.json().catch(() => undefined)) as { data?: { id?: unknown }[]; models?: { id?: unknown; name?: unknown }[] } | undefined;
		const list = body?.data ?? body?.models ?? [];
		const ids = list.map((m) => (m as { id?: unknown; name?: unknown }).id ?? (m as { name?: unknown }).name).filter((id): id is string => typeof id === "string");
		if (ids.length === 0) throw new Error(`${url} listed no models`);
		return ids;
	}

	#persist(): void {
		writeFileSync(this.#endpointsPath, JSON.stringify(this.#endpoints, null, "\t"));
	}
}
