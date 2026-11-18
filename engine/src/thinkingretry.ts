// A model's catalog can disagree with its provider, especially when it was added by hand (#363).
import { clampThinkingLevel, getSupportedThinkingLevels, type Api, type AssistantMessage, type AssistantMessageEvent, type Model, type SimpleStreamOptions, type ThinkingLevelMap } from "@earendil-works/pi-ai";
import { AssistantMessageEventStream } from "@earendil-works/pi-ai/utils/event-stream";
import { GenerationTask, hook } from "@earendil-works/pi-durable";
import type { Feature } from "./features.ts";
import type { Providers } from "./providers.ts";

export const THINKING_LEVELS = ["off", "minimal", "low", "medium", "high", "xhigh", "max"] as const;
type ThinkingLevel = typeof THINKING_LEVELS[number];
export const THINKING_RETRY_ENTRY = "pi2.thinking-retry";

function level(value: string): ThinkingLevel | undefined {
	const lower = value.toLowerCase();
	return lower === "none" ? "off" : THINKING_LEVELS.find((level) => level === lower);
}

const field = (value: unknown, key: string): unknown => value != null && typeof value === "object" ? (value as Record<string, unknown>)[key] : undefined;
const effortField = /\b(?:reasoning[._ ]?effort|reasoning[._ ]?level|thinking[._ ]?level|output_config\.effort)\b/i;

/** Read only discrete levels explicitly named by a parameter validation error, never a budget or a hint in prose. */
export function reportedThinking(message: string, sent: string, modelId: string): { levels: ThinkingLevel[]; map: ThinkingLevelMap; rejected: ThinkingLevel } | undefined {
	const rejected = level(sent);
	if (rejected === undefined) return undefined;
	// OpenAI/Codex sometimes omit the parameter name. In that form the refused value and the exact model must match.
	const openAI = /Unsupported value: ['"`]([\w-]+)['"`] is not supported with the ['"`]([^'"`]+)['"`] model\./i.exec(message);
	if (!effortField.test(message) && (openAI?.[1]?.toLowerCase() !== sent.toLowerCase() || openAI[2] !== modelId)) return undefined;
	if (!/unsupported|not supported|invalid|must be|input should be/i.test(message)) return undefined;
	// Mistral uses a Python-style list; OpenAI uses a sentence. Anthropic/Bedrock and Gemini/Vertex can wrap the
	// validation text in a JSON error, so the list must end before the surrounding object or array ends.
	const list = /(?:\bsupported (?:values|levels|efforts)(?: are)?\s*:|(?:must be|valid values are)\s+one of\s*:?|input should be)\s*\[?([\w'"`, \t-]+)\s*(?:\]|\.|;|\n|$)/i.exec(message)?.[1];
	if (list === undefined) return undefined;
	const values = list.replace(/['"`]/g, "").trim().split(/\s*(?:,\s*(?:and\s+|or\s+)?|\s+(?:and|or)\s+)\s*/);
	const levels = values.map(level);
	if (levels.some((value) => value === undefined || value === rejected)) return undefined;
	const map: ThinkingLevelMap = {};
	for (const each of THINKING_LEVELS) {
		const index = levels.indexOf(each);
		map[each] = index < 0 ? null : values[index]!.toLowerCase();
	}
	return { levels: THINKING_LEVELS.filter((each) => levels.includes(each)), map, rejected };
}

/** Only the wire field for thinking, never tokens, prompts or error data. */
function sentEffort(payload: unknown): string | undefined {
	const extras = field(payload, "additionalModelRequestFields") ?? payload; // Bedrock
	const generation = field(payload, "generationConfig") ?? field(payload, "config") ?? payload; // Gemini/Vertex
	const value = field(field(extras, "reasoning"), "effort") ?? field(extras, "reasoning_effort") ?? field(extras, "reasoningEffort")
		?? field(field(extras, "output_config"), "effort") ?? field(field(generation, "thinkingConfig"), "thinkingLevel");
	return typeof value === "string" ? value : undefined;
}

function closest(from: ThinkingLevel, levels: ThinkingLevel[]): ThinkingLevel {
	const index = THINKING_LEVELS.indexOf(from);
	const distance = (level: ThinkingLevel) => Math.abs(THINKING_LEVELS.indexOf(level) - index);
	// On a tie, spend less thinking effort, not more.
	return levels.reduce((best, level) => distance(level) < distance(best) ? level : best);
}

const notices = new WeakMap<AssistantMessage, string>();
export const thinkingNotices: Feature = (_host, engine) => ({
	hooks: [hook(GenerationTask, {
		afterResponse: async (message, runtime) => {
			const text = notices.get(message);
			if (text === undefined) return;
			try {
				const conv = await engine.harness().conversation(runtime.conversationId, engine.context());
				await conv?.submit({ type: "write", entry: { kind: THINKING_RETRY_ENTRY, data: { text } } }, engine.context());
			} catch {
				engine.log("could not write a thinking-level notice in conversation", runtime.conversationId);
			}
		},
	})],
});

/** Sit inside limit handling but outside the long-cache retry: each policy can handle its own refusal. */
export function retryThinking(providers: Providers, models: Providers["models"], changed: () => void): Providers["models"] {
	return new Proxy(models, {
		get(target, key) {
			const value = Reflect.get(target, key, target);
			if (key !== "streamSimple") return typeof value === "function" ? value.bind(target) : value;
			return (model: Model<Api>, context: Parameters<typeof target.streamSimple>[1], options?: SimpleStreamOptions) => {
				if (!model.reasoning) return target.streamSimple(model, context, options);
				const learned = providers.reportedThinking(model);
				const effective = learned === undefined ? model : { ...model, thinkingLevelMap: learned };
				if (learned !== undefined) {
					const next = closest(options?.reasoning ?? "off", getSupportedThinkingLevels(effective));
					options = { ...options, reasoning: next === "off" ? undefined : next };
				}
				const out = new AssistantMessageEventStream();
				void (async () => {
					let sent: string | undefined;
					let status: number | undefined;
					const first = target.streamSimple(effective, context, {
						...options,
						fetch: async (input, init) => {
							const response = await (options?.fetch ?? globalThis.fetch)(input, init);
							status = response.status;
							return response;
						},
						onPayload: async (payload, requestModel) => {
							const replacement = await options?.onPayload?.(payload, requestModel);
							sent = sentEffort(replacement ?? payload);
							return replacement;
						},
					});
					let started = false;
					let opening: AssistantMessageEvent | undefined;
					for await (const event of first) {
						if (event.type === "error" && !started && event.error.content.length === 0 && !options?.signal?.aborted && sent !== undefined
							&& (status === undefined || status === 400 || status === 422 || status === 200)) {
							const report = reportedThinking(event.error.errorMessage ?? "", sent, model.id);
							if (report !== undefined) {
								const requested = clampThinkingLevel(effective, options?.reasoning ?? "off");
								const next = closest(report.rejected, report.levels);
								const name = (level: string) => level[0]!.toUpperCase() + level.slice(1);
								const text = `${model.name} refused the ${name(requested)} thinking level. Retried with ${name(next)}.`;
								const retry = target.streamSimple({ ...model, thinkingLevelMap: report.map }, context, { ...options, reasoning: next === "off" ? undefined : next });
								for await (const result of retry) {
									if (result.type === "done") {
										notices.set(result.message, text);
										if (status !== 422 && providers.learnThinking(model, report.levels, report.map)) changed();
									} else if (result.type === "error") notices.set(result.error, text);
									out.push(result);
								}
								out.end(await retry.result());
								return;
							}
						}
						if (event.type !== "error" && event.type !== "done" && event.partial.content.length > 0) started = true;
						// An empty start does not show yet; hold it so a retry is one stream, not two.
						if (event.type === "start" && !started) {
							opening = event;
						} else {
							if (opening !== undefined) out.push(opening);
							opening = undefined;
							out.push(event);
						}
					}
					out.end(await first.result());
				})().catch((error: unknown) => {
					const message: AssistantMessage = {
						role: "assistant", content: [], api: model.api, provider: model.provider, model: model.id,
						usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
						stopReason: "error", errorMessage: error instanceof Error ? error.message : String(error), timestamp: Date.now(),
					};
					out.push({ type: "error", reason: "error", error: message });
				});
				return out;
			};
		},
	});
}
