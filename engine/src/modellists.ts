// Asking a built-in provider which models a key or sign-in can use (#259), and keeping the lists of providers whose
// catalog the library refreshes itself (pi-ai's `models.refresh()`). Requests go only to the provider's own address,
// the one its models are sent to, with the person's own credential, and never follow a redirect elsewhere.

import { readFileSync, writeFileSync } from "node:fs";
import type { Api, Model, ModelsStore, ModelsStoreEntry } from "@earendil-works/pi-ai";
import { plainProviderError } from "./providererror.ts";

/** A model as a provider lists it: its id, and what the provider says about it, when it does. */
export type ListedModel = { id: string; name?: string; contextWindow?: number; maxTokens?: number; vision?: boolean; thinkingLevels?: string[]; api?: string };

/** The credential a listing is asked with, as pi-ai resolves it for the provider's own requests. */
export type ListingAuth = { apiKey?: string; headers?: Record<string, string>; baseUrl?: string };

/** How a provider can be asked: where, and how its answer is read. */
export type Lister = {
	/** The address asked, for the person to see. */
	url: string;
	list: (auth: ListingAuth, signal: AbortSignal) => Promise<ListedModel[]>;
};

/**
 * The Codex release whose model list pi² asks for. ChatGPT's Codex service lists the models a client of that version
 * can use (`client_version`, as the Codex CLI sends it), so an old version could be shown fewer.
 */
export const CODEX_CLIENT_VERSION = "0.169.0";

const THINKING = ["off", "minimal", "low", "medium", "high", "xhigh", "max"];
const ASK_TIMEOUT_MS = 20_000;

/** A GET to `url` that is answered as JSON, or an error saying plainly what the provider answered. */
async function getJson(url: string, headers: Record<string, string>, signal: AbortSignal, who: string): Promise<unknown> {
	let response: Response;
	try {
		response = await fetch(url, { headers: { accept: "application/json", ...headers }, redirect: "manual", signal: AbortSignal.any([signal, AbortSignal.timeout(ASK_TIMEOUT_MS)]) });
	} catch (error) {
		throw new Error(`Could not reach ${who} at ${new URL(url).host}: ${error instanceof Error ? error.message : String(error)}`);
	}
	// The credential goes to the provider's own address only, never where an answer points.
	if (response.status >= 300 && response.status < 400) {
		const location = response.headers.get("location") ?? "";
		let where = "another address";
		try {
			where = new URL(location, url).host;
		} catch {}
		throw new Error(`${who} sent pi² on to ${where}, which pi² does not follow: only ${new URL(url).host} is asked.`);
	}
	if (!response.ok) {
		const said = plainProviderError(await response.text().catch(() => ""), 240);
		const refused = response.status === 401 || response.status === 403 || response.status === 404;
		const hint = refused ? ". It may not let this key or sign-in list its models: add a model by its id instead." : "";
		throw new Error(`${who} answered ${response.status}${said === "" ? "" : `: ${said.replace(/[.\s]+$/, "")}`}${hint}`);
	}
	try {
		return await response.json();
	} catch {
		throw new Error(`${who} did not answer with a list of models`);
	}
}

const positive = (value: unknown) => (typeof value === "number" && Number.isInteger(value) && value > 0 ? value : undefined);
const text = (value: unknown) => (typeof value === "string" && value.trim() !== "" ? value.trim() : undefined);
const levels = (efforts: readonly unknown[], off: boolean) => {
	const known = efforts.filter((effort): effort is string => typeof effort === "string" && THINKING.includes(effort));
	return known.length === 0 ? undefined : THINKING.filter((level) => (level === "off" && off) || known.includes(level));
};

/** ChatGPT's Codex service, with a ChatGPT sign-in: the models the Codex CLI's picker shows. */
function codexLister(baseUrl: string, who: string): Lister {
	const url = `${baseUrl.replace(/\/+$/, "")}/codex/models?client_version=${CODEX_CLIENT_VERSION}`;
	return {
		url,
		list: async (auth, signal) => {
			const token = auth.apiKey ?? "";
			const headers: Record<string, string> = { authorization: `Bearer ${token}`, originator: "pi" };
			// The account the token is for, as every Codex request names it.
			try {
				const account = JSON.parse(Buffer.from(token.split(".")[1] ?? "", "base64url").toString("utf8"))?.["https://api.openai.com/auth"]?.chatgpt_account_id;
				if (typeof account === "string") headers["chatgpt-account-id"] = account;
			} catch {
				// A token that is not a JWT is sent as it is; the service says what it thinks of it.
			}
			const body = (await getJson(url, headers, signal, who)) as { models?: unknown };
			if (!Array.isArray(body?.models)) throw new Error(`${who} did not answer with a list of models`);
			return (body.models as Record<string, unknown>[])
				.filter((model) => typeof model.slug === "string" && (model.visibility === undefined || model.visibility === "list"))
				.map((model) => ({
					id: model.slug as string,
					name: text(model.display_name),
					contextWindow: positive(model.context_window),
					...(Array.isArray(model.input_modalities) ? { vision: model.input_modalities.includes("image") } : {}),
					thinkingLevels: Array.isArray(model.supported_reasoning_levels) ? levels(model.supported_reasoning_levels.map((level) => (level as { effort?: unknown })?.effort), true) : undefined,
				}));
		},
	};
}

/** Go publishes native protocols; returned URLs are deliberately ignored. Routing stays with trusted templates. */
function goLister(models: readonly Model<Api>[], who: string): Lister {
	const origin = new URL(models[0]?.baseUrl ?? "https://opencode.ai").origin;
	if (origin !== "https://opencode.ai" && !/^http:\/\/(127\.0\.0\.1|localhost)(:\d+)?$/.test(origin)) throw new Error("Unrecognized OpenCode Go origin");
	const protocols: Record<string, string> = { messages: "anthropic-messages", responses: "openai-responses", "chat-completions": "openai-completions", "generate-content": "google-generative-ai" };
	const url = `${origin}/inference/go/v1/models`;
	return { url, list: async (auth, signal) => {
		const body = await getJson(url, { authorization: `Bearer ${auth.apiKey ?? ""}` }, signal, who) as { data?: unknown };
		if (!Array.isArray(body?.data)) throw new Error(`${who} did not answer with a list of models`);
		const found: ListedModel[] = [];
		for (const model of body.data) {
			if (model?.type !== "chat" || typeof model.id !== "string") continue;
			const keys = model.api && typeof model.api === "object" ? Object.keys(model.api) : [];
			const api = keys.length === 1 ? protocols[keys[0]!] : undefined;
			// Without a protocol we cannot safely invent a route for a new model on this mixed-API provider.
			if (api === undefined) continue;
			const reasoning = model.capabilities?.reasoning;
			found.push({ id: model.id, name: text(model.name), api,
				contextWindow: positive(model.limit?.context), maxTokens: positive(model.limit?.output),
				...(Array.isArray(model.modalities?.input) ? { vision: model.modalities.input.some((value: unknown) => typeof value === "string" && (value === "image" || value.startsWith("image/"))) } : {}),
				thinkingLevels: reasoning?.supported === false ? [] : Array.isArray(reasoning?.effort) ? levels(reasoning.effort, true) : undefined });
		}
		return found;
	} };
}

/** Anthropic's `GET /v1/models`, with an API key or a Claude sign-in, a page of up to 1000 at a time. */
function anthropicLister(baseUrl: string, who: string, signedIn: boolean): Lister {
	const base = `${baseUrl.replace(/\/+$/, "")}/v1/models`;
	return {
		url: base,
		list: async (auth, signal) => {
			const headers: Record<string, string> = { "anthropic-version": "2023-06-01", ...auth.headers };
			if (signedIn) {
				headers.authorization = `Bearer ${auth.apiKey ?? ""}`;
				headers["anthropic-beta"] = "oauth-2025-04-20";
			} else if (auth.apiKey !== undefined) headers["x-api-key"] = auth.apiKey;
			const found: ListedModel[] = [];
			for (let after: string | undefined, page = 0; page < 20; page++) {
				const body = (await getJson(`${base}?limit=1000${after === undefined ? "" : `&after_id=${encodeURIComponent(after)}`}`, headers, signal, who)) as { data?: unknown; has_more?: unknown; last_id?: unknown };
				if (!Array.isArray(body?.data)) throw new Error(`${who} did not answer with a list of models`);
				for (const model of body.data as Record<string, unknown>[]) {
					if (typeof model.id !== "string" || model.lifecycle === "retired") continue;
					const capabilities = (model.capabilities ?? {}) as { image_input?: { supported?: unknown }; effort?: Record<string, unknown>; thinking?: { supported?: unknown } };
					const efforts = capabilities.effort === undefined ? [] : Object.keys(capabilities.effort).filter((key) => (capabilities.effort![key] as { supported?: unknown })?.supported === true);
					found.push({
						id: model.id,
						name: text(model.display_name),
						contextWindow: positive(model.max_input_tokens),
						maxTokens: positive(model.max_tokens),
						...(typeof capabilities.image_input?.supported === "boolean" ? { vision: capabilities.image_input.supported } : {}),
						thinkingLevels: capabilities.thinking?.supported === true ? levels(efforts, true) : undefined,
					});
				}
				if (body.has_more !== true || typeof body.last_id !== "string") break;
				after = body.last_id;
			}
			return found;
		},
	};
}

/** Google's Gemini API, `GET /models` with an API key, a page at a time. */
function googleLister(baseUrl: string, who: string): Lister {
	const base = `${baseUrl.replace(/\/+$/, "")}/models`;
	return {
		url: base,
		list: async (auth, signal) => {
			const found: ListedModel[] = [];
			for (let token: string | undefined, page = 0; page < 20; page++) {
				const body = (await getJson(`${base}?pageSize=1000${token === undefined ? "" : `&pageToken=${encodeURIComponent(token)}`}`, { "x-goog-api-key": auth.apiKey ?? "", ...auth.headers }, signal, who)) as {
					models?: unknown;
					nextPageToken?: unknown;
				};
				if (!Array.isArray(body?.models)) throw new Error(`${who} did not answer with a list of models`);
				for (const model of body.models as Record<string, unknown>[]) {
					const methods = Array.isArray(model.supportedGenerationMethods) ? model.supportedGenerationMethods : [];
					if (typeof model.name !== "string" || !methods.includes("generateContent")) continue;
					found.push({ id: model.name.replace(/^models\//, ""), name: text(model.displayName), contextWindow: positive(model.inputTokenLimit), maxTokens: positive(model.outputTokenLimit) });
				}
				if (typeof body.nextPageToken !== "string" || body.nextPageToken === "") break;
				token = body.nextPageToken;
			}
			return found;
		},
	};
}

/** Ids of models an OpenAI-style list has beside chat models: speech, pictures, video, embeddings, moderation. */
const NOT_CHAT = /(embed|tts|whisper|transcribe|dall-e|gpt-image|sora|moderation|realtime|audio|speech|rerank|^babbage|^davinci)/i;

/** An OpenAI-style `GET /models` (OpenAI, and the many services that copy its API), with a key or a token. */
function openAILister(url: string, who: string): Lister {
	return {
		url,
		list: async (auth, signal) => {
			const body = (await getJson(url, { authorization: `Bearer ${auth.apiKey ?? ""}`, ...auth.headers }, signal, who)) as { data?: unknown };
			if (!Array.isArray(body?.data)) throw new Error(`${who} did not answer with a list of models`);
			return (body.data as Record<string, unknown>[])
				.filter((model) => typeof model.id === "string" && !NOT_CHAT.test(model.id))
				.map((model) => ({ id: model.id as string, name: text(model.name), contextWindow: positive(model.context_window) ?? positive(model.context_length) }));
		},
	};
}

/** Providers whose list cannot be had with a plain request: their own sign-in protocol, or an account of a cloud's. */
const UNASKABLE: Record<string, string> = {
	"github-copilot": "GitHub Copilot lists its models only to its own apps",
	"amazon-bedrock": "Amazon Bedrock lists models per region and account through AWS's own tools",
	"google-vertex": "Vertex AI lists models per Google Cloud project through Google Cloud's own tools",
	azure: "Azure OpenAI serves the deployments you made in your Azure account",
	typesafe: "Typesafe has no chat models to add",
};

/**
 * How to ask `providerId` which models a credential of `credential`'s kind can use, or why it cannot be asked. Only
 * the address its models are sent to is asked, never another.
 */
export function listerFor(providerId: string, providerName: string, models: readonly Model<Api>[], credential: "oauth" | "api_key", providerBaseUrl: string | undefined): Lister | { cannot: string } {
	const who = providerName;
	const reason = UNASKABLE[providerId];
	if (reason !== undefined) return { cannot: `${reason}, so pi² cannot ask it which models you can use.` };
	const base = (api: string) => models.find((model) => model.api === api && /^https?:\/\/[^{}]+$/.test(model.baseUrl))?.baseUrl;
	if (providerId === "openai-codex") return credential === "oauth" ? codexLister(providerBaseUrl ?? base("openai-codex-responses") ?? "https://chatgpt.com/backend-api", who) : { cannot: `${who} is used with a ChatGPT sign-in.` };
	if (providerId === "opencode-go") return credential === "api_key" ? goLister(models, who) : { cannot: "OpenCode Go uses an API key." };
	if (providerId === "anthropic") return anthropicLister(providerBaseUrl ?? base("anthropic-messages") ?? "https://api.anthropic.com", who, credential === "oauth");
	// Signed in to OpenAI with ChatGPT, the token is for api.openai.com, as a key is.
	if (credential === "oauth" && providerId !== "openai") return { cannot: `pi² does not know how to ask ${who} which models a sign-in can use.` };
	const google = base("google-generative-ai");
	if (google !== undefined && models.every((model) => model.api === "google-generative-ai")) return googleLister(google, who);
	const mistral = base("mistral-conversations");
	if (mistral !== undefined) return openAILister(`${mistral.replace(/\/+$/, "")}/v1/models`, who);
	const openai = base("openai-responses") ?? base("openai-completions");
	if (openai !== undefined) return openAILister(`${openai.replace(/\/+$/, "")}/models`, who);
	return { cannot: `pi² does not know how to ask ${who} which models it serves.` };
}

/**
 * Where pi-ai keeps the catalogs of providers whose list it refreshes itself (`models.refresh()`), so that one fetched
 * once is there at the next start, before it is fetched again. A cache: losing it costs one request.
 */
export class FileModelsStore implements ModelsStore {
	readonly #path: string;
	#entries: Record<string, ModelsStoreEntry>;

	constructor(path: string) {
		this.#path = path;
		try {
			this.#entries = JSON.parse(readFileSync(path, "utf8"));
		} catch {
			this.#entries = {};
		}
	}

	async read(providerId: string): Promise<ModelsStoreEntry | undefined> {
		return this.#entries[providerId];
	}

	async write(providerId: string, entry: ModelsStoreEntry): Promise<void> {
		this.#entries[providerId] = entry;
		writeFileSync(this.#path, JSON.stringify(this.#entries));
	}

	async delete(providerId: string): Promise<void> {
		delete this.#entries[providerId];
		writeFileSync(this.#path, JSON.stringify(this.#entries));
	}
}
