// Model access: every built-in pi-ai provider, the user's own endpoints, and a scripted demo model.

import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import {
	type AnyModel,
	type Api,
	type AuthInteraction,
	createProvider,
	type CredentialStore,
	getSupportedThinkingLevels,
	type Model,
	type MutableModels,
	type Provider,
	type ThinkingLevelMap,
} from "@earendil-works/pi-ai";
import { anthropicMessagesApi } from "@earendil-works/pi-ai/api/anthropic-messages.lazy";
import { openAICompletionsApi } from "@earendil-works/pi-ai/api/openai-completions.lazy";
import { openAIResponsesApi } from "@earendil-works/pi-ai/api/openai-responses.lazy";
import { builtinModels } from "@earendil-works/pi-ai/providers/all";
import { createFauxCore, fauxAssistantMessage, fauxText, fauxToolCall } from "@earendil-works/pi-ai/providers/faux";
import { isAttachmentBlock } from "./attachments.ts";

export const DEMO_PROVIDER = "demo";
export const DEMO_MODEL = "demo-1";

export type EndpointApi = "openai-completions" | "openai-responses" | "anthropic-messages";
/** `vision`: the model takes pictures. Off unless the person says so, since a server cannot be asked. */
export type EndpointModel = { id: string; name?: string; contextWindow?: number; reasoning?: boolean; vision?: boolean };
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
	/** Whether the model can be sent pictures. */
	vision: boolean;
	/** Left out of the model pickers by the person's choice in settings. */
	hidden?: boolean;
	/** Added by hand to a built-in provider whose library does not list it (see `AddedModel`). */
	addedByHand?: boolean;
};

/**
 * A model the person added by its id to a built-in provider, for one newer than the library's catalog: kept in
 * `added-models.json`, by provider. What pi² cannot know about it is taken from a model of the provider's catalog
 * (`basedOn`) and may be changed. It has no known price.
 */
export type AddedModel = {
	id: string;
	name: string;
	basedOn: string;
	contextWindow: number;
	maxTokens: number;
	vision: boolean;
	/** As `getSupportedThinkingLevels` gives them; empty for a model that does not think. */
	thinkingLevels: string[];
	addedAt: number;
	/** The model as it was built when added: what it is built from if the library no longer has `basedOn`. */
	model: Model<Api>;
};

/** What pi² would add for an id, before the person changes any of it, or what an added model has now. */
export type ModelDraft = {
	provider: string;
	providerName: string;
	id: string;
	name: string;
	basedOn: string;
	basedOnName: string;
	/** How `basedOn` was chosen: the newest of the id's family, the closest other one, or the person's or an earlier choice. */
	match: "family" | "nearest" | "chosen";
	api: string;
	/** The APIs the provider's catalog models speak, for a provider with more than one. */
	apis: string[];
	contextWindow: number;
	maxTokens: number;
	vision: boolean;
	thinkingLevels: string[];
	/** The catalog models it can be based on, newest first. */
	templates: { id: string; name: string; api: string }[];
	/** The id is already added by hand: saving it changes that model. */
	editing: boolean;
};

/** Every thinking level pi-ai knows, in order. */
const THINKING_LEVELS = ["off", "minimal", "low", "medium", "high", "xhigh", "max"] as const;

/**
 * A model id's family and version: the id without its version numbers and dates ("claude-opus", "gpt-mini"), and those
 * numbers. Date stamps ("-20251101", "-2024-05-13", "-04-2026") say which build, not which version.
 */
function familyOf(id: string): { family: string[]; version: number[] } {
	const family: string[] = [];
	const version: number[] = [];
	for (const token of id.replace(/-(\d{4}-\d{2}-\d{2}|\d{2}-\d{4}|\d{6,})(?=-|$)/g, "").split("-")) {
		if (/^\d+(\.\d+)*$/.test(token)) version.push(...token.split(".").map(Number));
		else if (token !== "latest" && token !== "preview") family.push(token);
	}
	return { family, version };
}

function compareVersions(a: readonly number[], b: readonly number[]): number {
	for (let i = 0; i < Math.max(a.length, b.length); i++) {
		const order = (a[i] ?? 0) - (b[i] ?? 0);
		if (order !== 0) return order;
	}
	return 0;
}

/**
 * Of a provider's model ids, the newest of each family, for the "newest only" shortcut in settings.
 * A family is the id without its version numbers and dates ("claude-opus", "gpt-mini"), so "claude-opus-5-5" replaces
 * "claude-opus-4-8" but not "claude-sonnet-5". It is a guess from naming, which is why the person can adjust the result.
 */
export function newestOnly(ids: readonly string[]): Set<string> {
	const best = new Map<string, { id: string; version: number[] }>();
	for (const id of ids) {
		const { family, version } = familyOf(id);
		const key = family.join("-");
		const held = best.get(key);
		let newer = held === undefined;
		if (held !== undefined) {
			const order = compareVersions(version, held.version);
			// The same version twice is one model under two ids (a dated one and its alias): keep the shorter.
			newer = order > 0 || (order === 0 && id.length < held.id.length);
		}
		if (newer) best.set(key, { id, version });
	}
	return new Set([...best.values()].map((entry) => entry.id));
}

/**
 * The model of `models` a new id is most like: the newest of its own family ("gpt-6.1-sol" for "gpt-6.2-sol"), else
 * the newest of those sharing the most of its family's first words ("gpt-…" for "gpt-7-nova"), else the newest of all.
 * Newest by version, then by a shorter id (an alias rather than a dated build).
 */
export function nearestModel<T extends { id: string }>(id: string, models: readonly T[]): { model: T; sameFamily: boolean } | undefined {
	const wanted = familyOf(id).family;
	let best: { model: T; shared: number; version: number[] } | undefined;
	for (const model of models) {
		const { family, version } = familyOf(model.id);
		const same = family.join("-") === wanted.join("-");
		let shared = 0;
		while (shared < Math.min(family.length, wanted.length) && family[shared] === wanted[shared]) shared++;
		// The whole family alike outranks any number of first words alike.
		const score = same ? Number.MAX_SAFE_INTEGER : shared;
		const order = best === undefined ? 1 : score - best.shared || compareVersions(version, best.version) || best.model.id.length - model.id.length;
		if (order > 0) best = { model, shared: score, version };
	}
	return best === undefined ? undefined : { model: best.model, sameFamily: best.shared === Number.MAX_SAFE_INTEGER };
}

/**
 * A name for a new id from its template's: "GPT-6.1 Sol" for "gpt-6.1-sol" gives "GPT-6.2 Sol" for "gpt-6.2-sol". The
 * id itself when the template's name does not show its version the same way.
 */
export function nameLike(id: string, template: { id: string; name: string }): string {
	const from = familyOf(template.id);
	const to = familyOf(id);
	if (from.family.join("-") !== to.family.join("-") || from.version.length === 0 || to.version.length === 0) return id;
	const version = from.version.join(".");
	if (!template.name.includes(version)) return id;
	return template.name.replace(version, to.version.join("."));
}

/** The thinking-level map that gives `levels` (in pi-ai's sense) on top of a template's map. */
function thinkingMap(template: Model<Api>, levels: readonly string[]): ThinkingLevelMap {
	const map: Record<string, string | null | undefined> = { ...(template.reasoning ? template.thinkingLevelMap : {}) };
	for (const level of THINKING_LEVELS) {
		if (!levels.includes(level)) map[level] = null;
		// The two highest exist only when mapped; the others, mapped to nothing, take the provider's default.
		else if (level === "xhigh" || level === "max") map[level] = typeof map[level] === "string" ? map[level] : level;
		else if (map[level] === null) delete map[level];
	}
	return map as ThinkingLevelMap;
}

/** A model id as typed, or why it cannot be one. Ids may hold "/", ":" and "@" ("anthropic/claude-x", "qwen3:32b"). */
function checkModelId(raw: unknown): string {
	const id = typeof raw === "string" ? raw.trim() : "";
	if (id === "") throw new Error("Type the model's id, as the provider names it, such as gpt-6.2-sol");
	if (/\s/.test(id)) throw new Error("A model id has no spaces. Type the id the provider uses, such as gpt-6.2-sol, rather than its name");
	if (id.length > 200) throw new Error("That model id is too long");
	return id;
}

/** A model added by hand, built from its template with the person's choices. Its price is not known, so it is none. */
function buildAdded(template: Model<Api>, entry: Omit<AddedModel, "addedAt" | "model" | "basedOn">, provider: string): Model<Api> {
	const reasoning = entry.thinkingLevels.some((level) => level !== "off");
	const { thinkingLevelMap: _map, ...rest } = template;
	return {
		...rest,
		id: entry.id,
		name: entry.name,
		provider,
		reasoning,
		...(reasoning ? { thinkingLevelMap: thinkingMap(template, entry.thinkingLevels) } : {}),
		input: entry.vision ? ["text", "image"] : ["text"],
		contextWindow: entry.contextWindow,
		maxTokens: entry.maxTokens,
		cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
	} as Model<Api>;
}

/**
 * A built-in provider with the models added to it by hand after its own. One the catalog has come to know (a library
 * update, or a provider's refreshed list) is left out: the catalog's own entry takes its place. Added models are offered
 * whatever the credential: a provider's own filter only knows its catalog.
 */
function withAddedModels(provider: Provider, added: () => readonly Model<Api>[]): Provider {
	const extra = (): readonly Model<Api>[] => {
		const list = added();
		if (list.length === 0) return list;
		const known = new Set(provider.getModels().map((model) => model.id));
		return list.filter((model) => !known.has(model.id));
	};
	const apart = <M extends AnyModel>(models: readonly M[]) => {
		const mine = new Set<AnyModel>(extra());
		return { theirs: models.filter((model) => !mine.has(model)), mine: models.filter((model) => mine.has(model)) };
	};
	const { getAllModels, filterModels, filterAllModels } = provider;
	return {
		...provider,
		getModels: () => [...provider.getModels(), ...extra()],
		...(getAllModels === undefined ? {} : { getAllModels: () => [...getAllModels(), ...extra()] }),
		...(filterModels === undefined
			? {}
			: {
					filterModels: (models, credential) => {
						const { theirs, mine } = apart(models);
						return [...filterModels(theirs, credential), ...mine];
					},
				}),
		...(filterAllModels === undefined
			? {}
			: {
					filterAllModels: (models, credential) => {
						const { theirs, mine } = apart(models);
						return [...filterAllModels(theirs, credential), ...mine];
					},
				}),
	};
}

const ENDPOINT_APIS: readonly EndpointApi[] = ["openai-completions", "openai-responses", "anthropic-messages"];

function textOf(content: unknown): string {
	if (typeof content === "string") return content;
	if (!Array.isArray(content)) return "";
	return content.map((block) => (block?.type === "text" && typeof block.text === "string" ? block.text : "")).join("");
}

type DemoMessage = { role?: string; content?: unknown; isError?: boolean };
type DemoBlock = { type?: string; text?: unknown };

/** The newest thing for the demo model to answer. A tool or prompt change can add a system message after it, so skip those. */
function demoLast(messages: readonly unknown[]): DemoMessage | undefined {
	return (messages as readonly DemoMessage[]).findLast((message) => message.role === "user" || message.role === "toolResult");
}

const isAttached = (block: DemoBlock) => block?.type === "text" && typeof block.text === "string" && isAttachmentBlock(block.text);

/** What the person typed, apart from what they attached: attached texts are blocks of their own, after it. */
function demoPrompt(last: DemoMessage | undefined): string {
	const blocks: readonly DemoBlock[] = Array.isArray(last?.content) ? last.content : [];
	return (typeof last?.content === "string" ? last.content : textOf(blocks.filter((block) => !isAttached(block)))).trim();
}

/** A scripted stand-in model so the app works before any provider is connected. `/bash` and `/read` make it call tools. */
function demoProvider(): Provider {
	// Tests add a second demo model that cannot see images, to check what such a model is given.
	const textOnly = process.env.PI2_DEMO_TEXT_MODEL === "1" ? [{ id: "demo-text", name: "Demo model (text only)", input: ["text" as const] }] : [];
	const models = [{ id: DEMO_MODEL, name: "Demo model (scripted)" }, ...textOnly];
	// It types at a readable pace. Tests set PI2_DEMO_TOKENS_PER_SECOND to speed it up, since most of their time would
	// otherwise go to waiting on it; a message that starts with "/slow " is still answered at the readable pace, for the
	// tests that need an answer to be on its way (to stop it, queue behind it or kill the engine in the middle of it).
	const READABLE = 20;
	const speed = Number(process.env.PI2_DEMO_TOKENS_PER_SECOND);
	const slow = createFauxCore({ provider: DEMO_PROVIDER, models, tokensPerSecond: READABLE });
	const fast = createFauxCore({ provider: DEMO_PROVIDER, models, tokensPerSecond: Number.isFinite(speed) && speed > 0 ? speed : READABLE });
	const step = (request: { messages: readonly unknown[] }) => {
		const last = demoLast(request.messages);
		if (last?.role === "toolResult") {
			// Says how many pictures it was sent, so it is visible that old screenshots are left out.
			const pictures = (request.messages as readonly { content?: unknown }[]).reduce(
				(count, message) => count + (Array.isArray(message.content) ? message.content.filter((block) => block?.type === "image").length : 0),
				0,
			);
			const seen = pictures === 0 ? "" : ` I can see ${pictures} picture${pictures === 1 ? "" : "s"}.`;
			return fauxAssistantMessage(last.isError ? "The tool reported an error; its output is above." : `Done. The tool returned: ${textOf(last.content).slice(0, 200)}${seen}`);
		}
		const blocks: readonly DemoBlock[] = Array.isArray(last?.content) ? last.content : [];
		const typed = demoPrompt(last);
		const prompt = typed.startsWith("/slow ") ? typed.slice(6).trim() : typed;
		if (prompt.startsWith("/bash ")) {
			return fauxAssistantMessage([fauxText("Running that command."), fauxToolCall("bash", { command: prompt.slice(6) })], { stopReason: "toolUse" });
		}
		if (prompt.startsWith("/timeout ")) {
			// "/timeout <seconds> <command>": bash with a time limit of its own
			const [seconds, ...command] = prompt.slice(9).split(" ");
			return fauxAssistantMessage([fauxText("Running that command."), fauxToolCall("bash", { command: command.join(" "), timeout: Number(seconds) })], { stopReason: "toolUse" });
		}
		if (prompt.startsWith("/background ")) {
			// "/background <command>": bash, started and left running
			return fauxAssistantMessage([fauxText("Starting that in the background."), fauxToolCall("bash", { command: prompt.slice(12), background: true })], { stopReason: "toolUse" });
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
		if (prompt.startsWith("/tools ")) {
			// "/tools [{"name": …, "arguments": {…}}, …]": several tool calls in one answer, as a real model makes them.
			const calls = JSON.parse(prompt.slice(7)) as { name: string; arguments?: Parameters<typeof fauxToolCall>[1] }[];
			return fauxAssistantMessage([fauxText("Calling those tools."), ...calls.map((call) => fauxToolCall(call.name, call.arguments ?? {}))], { stopReason: "toolUse" });
		}
		if (prompt.startsWith("/tool ")) {
			// "/tool <tool name> <json arguments>": call any tool the conversation has, by name.
			const [name, ...rest] = prompt.slice(6).split(" ");
			return fauxAssistantMessage([fauxText("Calling that tool."), fauxToolCall(name!, JSON.parse(rest.join(" ") || "{}"))], { stopReason: "toolUse" });
		}
		if (prompt === "/system" || prompt.startsWith("/system ")) {
			// Answers with the system prompt and the tools the model was offered, so tests can see what reaches it.
			// Later system messages replace sections by name (null removes one) and add or remove tools.
			const sections = new Map<string, string>();
			const offered = new Map<string, { name: string }>();
			let content = "";
			// One line per system message, for "/system history": what each one changed.
			const history: string[] = [];
			for (const message of request.messages as readonly { role?: string; content?: unknown; sections?: Record<string, string | null>; toolsAdded?: { name: string }[]; toolsRemoved?: { name: string }[] }[]) {
				if (message.role !== "system") continue;
				content += textOf(message.content);
				history.push(
					[
						...Object.entries(message.sections ?? {}).map(([key, value]) => (value === null ? `-${key}` : `${key}=${value.length}`)),
						...(message.toolsRemoved ?? []).map((tool) => `-tool:${tool.name}`),
						...(message.toolsAdded ?? []).map((tool) => `+tool:${tool.name}`),
					].join(" "),
				);
				for (const [key, value] of Object.entries(message.sections ?? {})) value === null ? sections.delete(key) : sections.set(key, value);
				for (const added of message.toolsAdded ?? []) offered.set(added.name, added);
				for (const removed of message.toolsRemoved ?? []) offered.delete(removed.name);
			}
			const asked = prompt.slice(8).trim();
			if (asked === "history") {
				// "/system history": each system message in order, with the sections it set (and their length), removed (-) and
				// the tools it took away and added, so a test can see what was sent again (#186).
				return fauxAssistantMessage(`HISTORY\n${history.join("\n")}`);
			}
			// A section with nothing to say is empty, holding its place, and is not sent (sections.ts).
			for (const [key, value] of sections) if (value === "") sections.delete(key);
			if (asked === "sizes") {
				// "/system sizes": the characters of each part of the prompt and of the tool definitions, to measure them.
				const parts = [["(base)", content.length], ...[...sections].map(([key, value]) => [key, value.length]), [`(tools: ${offered.size})`, JSON.stringify([...offered.values()]).length]];
				return fauxAssistantMessage(`SIZES\n${parts.map(([key, size]) => `${key} ${size}`).join("\n")}`);
			}
			if (asked !== "") {
				// "/system <section> ...": those sections as they are, and every tool offered, by name.
				const named = asked.split(/\s+/).map((key) => `<<${key}>>\n${sections.get(key) ?? "(none)"}`);
				return fauxAssistantMessage(`SYSTEM PROMPT\n${named.join("\n")}\nTOOLS: ${[...offered.keys()].join(", ")}`);
			}
			// Only the sections about what the agent knows and where it works, and the tools for memory: the demo model speaks slowly.
			const prompts = [...sections].filter(([key]) => key === "project_instructions" || key === "memory" || key === "worktree" || key === "background_commands").map(([key, value]) => `<${key}>\n${value}\n</${key}>`).join("\n");
			return fauxAssistantMessage(`SYSTEM PROMPT\n${prompts}\nTOOLS: ${[...offered.keys()].filter((name) => name === "remember" || name === "forget").join(", ")}`);
		}
		if (prompt.startsWith("/mcp ")) {
			// "/mcp <tool name> <json arguments>"
			const [name, ...rest] = prompt.slice(5).split(" ");
			return fauxAssistantMessage([fauxText("Calling that tool."), fauxToolCall(name!, JSON.parse(rest.join(" ") || "{}"))], { stopReason: "toolUse" });
		}
		if (prompt.startsWith("/read ")) {
			return fauxAssistantMessage([fauxText("Reading that file."), fauxToolCall("read", { path: prompt.slice(6).trim() })], { stopReason: "toolUse" });
		}
		// Says what came with the message, so it is visible that attachments reach the model.
		const pictures = blocks.filter((block) => block?.type === "image").length;
		const files = blocks.filter(isAttached).length;
		const came = [pictures === 0 ? "" : `${pictures} picture${pictures === 1 ? "" : "s"}`, files === 0 ? "" : `${files} attached file${files === 1 ? "" : "s"}`].filter((part) => part !== "");
		return fauxAssistantMessage(
			`You said: "${prompt}". ${came.length === 0 ? "" : `With it came ${came.join(" and ")}. `}I am the demo model, a scripted stand-in with no intelligence behind it. ` +
				"Connect a real provider in Settings, then pick its model from the toolbar. " +
				"Until then you can try `/bash <command>`, `/read <path>`, `/ask <question>` or `/delegate <agent>: <task>` " +
				"to see tool calls. One, two, three, four, five. Done.",
		);
	};
	slow.setResponses(Array.from({ length: 100_000 }, () => step));
	fast.setResponses(Array.from({ length: 100_000 }, () => step));
	const pace = (context: { messages: readonly unknown[] }, options?: object) =>
		(options as { deferred?: unknown } | undefined)?.deferred === undefined && demoPrompt(demoLast(context.messages)).startsWith("/slow ") ? slow : fast;
	return createProvider({
		id: DEMO_PROVIDER,
		auth: { apiKey: { name: "Demo", resolve: async () => ({ auth: {} }) } },
		models: fast.models,
		api: {
			stream: (model, context, options) => pace(context, options).stream(model, context, options),
			streamSimple: (model, context, options) => pace(context, options).streamSimple(model, context, options),
			// Deferred answers are always made by the fast one, so it holds their handles.
			fetchDeferred: fast.fetchDeferred,
			cancelDeferred: fast.cancelDeferred,
		},
	});
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
			// Pictures (attached, or screenshots from computer use) are only sent to a model the person marked as seeing them.
			input: m.vision === true ? ["text", "image"] : ["text"],
			cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
			contextWindow,
			maxTokens: Math.min(16_384, Math.floor(contextWindow / 4)),
			// Local and self-hosted servers rarely know the newer OpenAI request fields, such as the long prompt cache's.
			...(config.api === "openai-completions" ? { compat: { supportsDeveloperRole: false, supportsReasoningEffort: m.reasoning ?? false, supportsLongCacheRetention: false } } : {}),
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
	/** Each built-in provider as the library made it, without the models added by hand: its catalog. */
	readonly #catalogs = new Map<string, Provider>();
	readonly #addedPath: string;
	#added: Record<string, AddedModel[]>;
	/** The added models as built, by provider: the same objects each time, until they change. */
	#built = new Map<string, Model<Api>[]>();
	readonly #log: (...parts: unknown[]) => void;

	/**
	 * `deviceId` returns this installation's stable UUID; some sign-ins (ChatGPT) identify the app by it. `builtins`
	 * makes the collection of built-in providers, which tests replace with stand-ins.
	 */
	constructor(
		home: string,
		credentials: CredentialStore,
		deviceId: () => string,
		options: { builtins?: typeof builtinModels; log?: (...parts: unknown[]) => void } = {},
	) {
		this.#credentials = credentials;
		this.#deviceId = deviceId;
		this.#log = options.log ?? (() => {});
		this.models = (options.builtins ?? builtinModels)({ credentials, identity: { attribution: { name: "pi2", url: "https://github.com/earendil-works/pi" } } });
		this.#builtinIds = new Set(this.models.getProviders().map((p) => p.id));
		this.#addedPath = join(home, "added-models.json");
		try {
			this.#added = JSON.parse(readFileSync(this.#addedPath, "utf8"));
		} catch {
			this.#added = {};
		}
		for (const provider of this.models.getProviders()) {
			// Every built-in provider is a plain object of functions; one that is not is left as it is, without added models.
			if (typeof provider.getModels !== "function" || Object.getPrototypeOf(provider) !== Object.prototype) continue;
			this.#catalogs.set(provider.id, provider);
			this.models.setProvider(withAddedModels(provider, () => this.#builtModels(provider.id)));
		}
		this.giveWay();
		this.models.setProvider(demoProvider());
		this.#endpointsPath = join(home, "endpoints.json");
		try {
			this.#endpoints = JSON.parse(readFileSync(this.#endpointsPath, "utf8"));
		} catch {
			this.#endpoints = [];
		}
		for (const endpoint of this.#endpoints) this.models.setProvider(endpointProvider(endpoint));
	}

	// ---- Models added by hand to built-in providers

	#builtModels(providerId: string): Model<Api>[] {
		let built = this.#built.get(providerId);
		if (built === undefined) {
			const catalog = this.#catalogs.get(providerId);
			built = (this.#added[providerId] ?? []).map((entry) => {
				// From the catalog's model as it is now, so a library update's fixes reach it; from the stored one if it is gone.
				const template = catalog?.getModels().find((model) => model.id === entry.basedOn) ?? entry.model;
				return buildAdded(template, entry, providerId);
			});
			this.#built.set(providerId, built);
		}
		return built;
	}

	/** Whether `id` is a model added by hand to `providerId` that its catalog does not list, so is in use as added. */
	isAddedByHand(providerId: string, id: string): boolean {
		const catalog = this.#catalogs.get(providerId);
		return (this.#added[providerId] ?? []).some((entry) => entry.id === id) && catalog?.getModels().some((model) => model.id === id) !== true;
	}

	/**
	 * Forgets the models added by hand that their provider's catalog now lists, whose own entry has taken their place.
	 * At start (a library update) and after a provider's list is refreshed. Returns what it forgot.
	 */
	giveWay(): { provider: string; id: string }[] {
		const forgotten: { provider: string; id: string }[] = [];
		for (const [providerId, entries] of Object.entries(this.#added)) {
			const known = new Set(this.#catalogs.get(providerId)?.getModels().map((model) => model.id) ?? []);
			for (const entry of entries) if (known.has(entry.id)) forgotten.push({ provider: providerId, id: entry.id });
		}
		if (forgotten.length > 0) {
			for (const { provider, id } of forgotten) {
				this.#added[provider] = this.#added[provider]!.filter((entry) => entry.id !== id);
				if (this.#added[provider]!.length === 0) delete this.#added[provider];
				this.#built.delete(provider);
				this.#log(`${provider}/${id} was added by hand and is now in the provider's own list, which takes its place`);
			}
			this.#persistAdded();
		}
		return forgotten;
	}

	#catalog(providerId: string): Provider {
		const catalog = this.#catalogs.get(providerId);
		if (catalog === undefined) {
			const endpoint = this.#endpoints.some((e) => e.id === providerId);
			throw new Error(endpoint ? "Models are added to an endpoint of your own in its settings: Edit…" : `Unknown provider: ${providerId}`);
		}
		return catalog;
	}

	/**
	 * What pi² would add for `id` on a built-in provider: settings taken from a model of its catalog, the newest of the same
	 * family unless `basedOn` names another, or the newest that speaks `api`. For an id already added, what it has now.
	 */
	draftModel(providerId: string, rawId: string, choice: { basedOn?: string; api?: string } = {}): ModelDraft {
		const catalog = this.#catalog(providerId);
		const id = checkModelId(rawId);
		const models = catalog.getModels();
		const listed = models.find((model) => model.id === id);
		if (listed !== undefined) throw new Error(`${catalog.name} already has ${id} (${listed.name}). If it is not in the model menus, tick it in Models….`);
		if (models.length === 0) throw new Error(`pi² knows no models of ${catalog.name} to take this one's settings from`);
		const apis = [...new Set(models.map((model) => model.api))];
		const templates = [...models].sort((a, b) => compareVersions(familyOf(b.id).version, familyOf(a.id).version) || a.id.localeCompare(b.id)).map((model) => ({ id: model.id, name: model.name, api: model.api }));
		const existing = this.#added[providerId]?.find((entry) => entry.id === id);
		let template: Model<Api> | undefined;
		let match: ModelDraft["match"] = "chosen";
		if (choice.basedOn !== undefined) {
			template = models.find((model) => model.id === choice.basedOn);
			if (template === undefined) throw new Error(`${catalog.name} has no model ${choice.basedOn} to take settings from`);
		} else if (existing !== undefined && choice.api === undefined) {
			const built = this.#builtModels(providerId).find((model) => model.id === id)!;
			const base = models.find((model) => model.id === existing.basedOn);
			return {
				provider: providerId,
				providerName: catalog.name,
				id,
				name: existing.name,
				basedOn: existing.basedOn,
				basedOnName: base?.name ?? existing.basedOn,
				match,
				api: built.api,
				apis,
				contextWindow: existing.contextWindow,
				maxTokens: existing.maxTokens,
				vision: existing.vision,
				thinkingLevels: existing.thinkingLevels,
				templates,
				editing: true,
			};
		} else {
			const speaking = choice.api === undefined ? models : models.filter((model) => model.api === choice.api);
			if (speaking.length === 0) throw new Error(`None of ${catalog.name}'s models speak ${choice.api}`);
			const nearest = nearestModel(id, speaking)!;
			template = nearest.model;
			match = nearest.sameFamily ? "family" : "nearest";
		}
		return {
			provider: providerId,
			providerName: catalog.name,
			id,
			name: existing?.name ?? nameLike(id, template),
			basedOn: template.id,
			basedOnName: template.name,
			match,
			api: template.api,
			apis,
			contextWindow: template.contextWindow,
			maxTokens: template.maxTokens,
			vision: template.input.includes("image"),
			thinkingLevels: template.reasoning ? getSupportedThinkingLevels(template) : [],
			templates,
			editing: existing !== undefined,
		};
	}

	/**
	 * Adds a model by its id to a built-in provider that is signed in or has a key, or changes one added before. It is
	 * then offered wherever the provider's models are, on the same sign-in.
	 */
	async addModel(input: {
		provider: string;
		id: string;
		name?: string;
		basedOn: string;
		contextWindow: number;
		maxTokens: number;
		vision: boolean;
		thinkingLevels: string[];
	}): Promise<ModelInfo> {
		const catalog = this.#catalog(input.provider);
		const id = checkModelId(input.id);
		if (catalog.getModels().some((model) => model.id === id)) throw new Error(`${catalog.name} already has ${id}`);
		if ((await this.models.checkAuth(input.provider).catch(() => undefined)) === undefined) {
			throw new Error(`Sign in to ${catalog.name} or add its key first: the model is used with that sign-in or key.`);
		}
		const template = catalog.getModels().find((model) => model.id === input.basedOn);
		if (template === undefined) throw new Error(`${catalog.name} has no model ${String(input.basedOn)} to take settings from`);
		const whole = (value: unknown, what: string) => {
			if (typeof value !== "number" || !Number.isInteger(value) || value < 1) throw new Error(`${what} must be a whole number of tokens`);
			return value;
		};
		const contextWindow = whole(input.contextWindow, "The context size");
		const maxTokens = whole(input.maxTokens, "The longest answer");
		if (maxTokens > contextWindow) throw new Error("The longest answer cannot be more than the context size");
		if (!Array.isArray(input.thinkingLevels) || input.thinkingLevels.some((level) => !(THINKING_LEVELS as readonly string[]).includes(level))) {
			throw new Error(`Thinking levels are some of: ${THINKING_LEVELS.join(", ")}`);
		}
		const thinks = input.thinkingLevels.some((level) => level !== "off");
		const choices = {
			id,
			name: input.name?.trim() || id,
			contextWindow,
			maxTokens,
			vision: input.vision === true,
			// In pi-ai's order, and "off" alone is no thinking at all.
			thinkingLevels: thinks ? THINKING_LEVELS.filter((level) => input.thinkingLevels.includes(level)) : [],
		};
		const model = buildAdded(template, choices, input.provider);
		const earlier = this.#added[input.provider]?.find((entry) => entry.id === id);
		const entry: AddedModel = { ...choices, basedOn: template.id, addedAt: earlier?.addedAt ?? Date.now(), model };
		this.#added[input.provider] = [...(this.#added[input.provider] ?? []).filter((e) => e.id !== id), entry];
		this.#built.delete(input.provider);
		this.#persistAdded();
		this.#log(`${earlier === undefined ? "added" : "changed"} ${input.provider}/${id} by hand, based on ${template.id}`);
		return this.#info(this.#builtModels(input.provider).find((m) => m.id === id)!);
	}

	removeModel(providerId: string, id: string): void {
		if (!this.#added[providerId]?.some((entry) => entry.id === id)) throw new Error(`${id} was not added by hand to ${this.models.getProvider(providerId)?.name ?? providerId}`);
		this.#added[providerId] = this.#added[providerId]!.filter((entry) => entry.id !== id);
		if (this.#added[providerId]!.length === 0) delete this.#added[providerId];
		this.#built.delete(providerId);
		this.#persistAdded();
		this.#log(`removed ${providerId}/${id}, which was added by hand`);
	}

	#persistAdded(): void {
		writeFileSync(this.#addedPath, JSON.stringify(this.#added, null, "\t"));
	}

	#info(model: Model<Api>, names?: Map<string, string>): ModelInfo {
		return {
			provider: model.provider,
			providerName: names?.get(model.provider) ?? this.models.getProvider(model.provider)?.name ?? model.provider,
			id: model.id,
			name: model.name,
			thinkingLevels: model.reasoning ? getSupportedThinkingLevels(model) : [],
			contextWindow: model.contextWindow,
			vision: model.input.includes("image"),
			...(this.isAddedByHand(model.provider, model.id) ? { addedByHand: true } : {}),
		};
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
		return available.map((model) => this.#info(model, names));
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
