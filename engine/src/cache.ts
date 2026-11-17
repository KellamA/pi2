// How long a provider keeps a conversation's prompt cache. A provider keeps it five minutes by default; a request after a
// longer pause reads nothing from it and writes the whole conversation into it again (#159). A conversation that hands
// out work waits for its sub-chats for far longer than that, so from its first `delegate` on its requests ask for the
// long cache (pi-ai's `cacheRetention: "long"`: an hour on Anthropic's API and on Bedrock, what OpenAI's API calls
// extended retention). Every other request is sent as before. See "The prompt cache" in docs/limits.md.
//
// - Which conversation a request is for: pi-durable sends each conversation's requests with a provider session id of its
//   own (`pi.provider`), which a hook before each request notes. The models given to the harness are wrapped so that a
//   request whose conversation has a sub-chat asks for the long cache, unless its caller chose a lifetime itself (a
//   compaction asks for none).
// - A refusal must not break a conversation: a request asking for the long cache that the provider refuses because of it
//   (an error, before any answer, naming the cache) is sent again at once with the short one, and that provider is not
//   asked for the long one again until the engine restarts. engine.log says so once.
// - engine.log has a line for a request that comes after more than five minutes without one in its conversation, saying
//   what it read from the cache, so the effect can be seen from the log. `usage` keeps `cacheRead` and `cacheWrite` too.

import type { AssistantMessage, AssistantMessageEvent } from "@earendil-works/pi-ai";
import { AssistantMessageEventStream } from "@earendil-works/pi-ai/utils/event-stream";
import { GenerationTask, hook, ProviderDoc } from "@earendil-works/pi-durable";
import type { Feature } from "./features.ts";
import { duration } from "./limitwait.ts";
import { plainProviderError } from "./providererror.ts";

/** A pause longer than this, between two requests of a conversation, is longer than the short cache lasts. */
const PAUSE_MS = ((value) => (Number.isFinite(value) && value >= 0 ? value : 5 * 60_000))(Number(process.env.PI2_CACHE_PAUSE_MS ?? 5 * 60_000));
/** The most of a refusal's body that is read, to see whether it names the cache. */
const BODY_LIMIT = 16 * 1024;
/** Words a refusal of the long cache has in it: Anthropic's `cache_control.ttl`, OpenAI's `prompt_cache_retention`, Bedrock's `cachePoint`. */
const CACHE_WORDS = /\bttl\b|cach|retention/i;

type Retention = "long" | "short";
type Policy = {
	/** Whether a conversation has handed out work: whether any conversation is its sub-chat. */
	handsOutWork(conversation: number): boolean;
	providerName(id: string): string;
	log(line: string): void;
};

/** Set when the feature is made; until then (and in a process without it) every request is sent as it comes. */
let policy: Policy | undefined;
/** Provider session id → conversation, and back, as the hook before each request found them. Only ever in memory. */
const conversationOf = new Map<string, number>();
const sessionOf = new Map<number, string>();
/** Providers that refused a request for the long cache: not asked for it again until the engine restarts. */
const refused = new Set<string>();
/** Conversations whose asking for the long cache engine.log has noted, once each. */
const announced = new Set<number>();
/** The last answered request of each provider session: when it ended, what it read, and the lifetime it asked for. */
const last = new Map<string, { at: number; read: number; retention: Retention }>();

/**
 * Whether a request that asked for the long cache was refused because of it: it ended on an error (not a stop), with no
 * status or a client error other than a bad key or a limit, and the error or the refusal's body names the cache.
 */
export function refusedForCache(message: AssistantMessage, status: number | undefined, body: string): boolean {
	if (message.stopReason !== "error") return false;
	if (status !== undefined && (status < 400 || status >= 500 || status === 401 || status === 429)) return false;
	return CACHE_WORDS.test(`${message.errorMessage ?? ""}\n${body}`);
}

type Fetch = typeof globalThis.fetch;
type Model = { id: string; api: string; provider: string };
type Options = { cacheRetention?: string; sessionId?: string; fetch?: Fetch; signal?: AbortSignal };
type Stream = AsyncIterable<AssistantMessageEvent> & { result(): Promise<AssistantMessage> };
type StreamCall = (model: Model, context: unknown, options?: Options) => Stream;

/**
 * The models, unchanged except that a request of a conversation that hands out work asks for the long cache, and is sent
 * again with the short one if the provider refuses it for that.
 */
export function promptCacheLifetimes<T extends object>(models: T): T {
	return new Proxy(models, {
		get(target, key) {
			const value = Reflect.get(target, key, target);
			if ((key === "stream" || key === "streamSimple") && typeof value === "function") {
				const original = (value as StreamCall).bind(target);
				return (model: Model, context: unknown, options?: Options) => request(original, model, context, options);
			}
			return typeof value === "function" ? value.bind(target) : value;
		},
	});
}

function request(original: StreamCall, model: Model, context: unknown, options: Options | undefined): Stream {
	const session = options?.sessionId;
	const conversation = session === undefined ? undefined : conversationOf.get(session);
	// A request that is not a conversation's own (a compaction asks for no cache) is left as its caller made it.
	if (session === undefined || conversation === undefined || options?.cacheRetention !== undefined || policy === undefined) return original(model, context, options);
	const started = Date.now();
	if (refused.has(model.provider) || !policy.handsOutWork(conversation)) {
		const stream = original(model, context, options);
		void stream.result().then((message) => observe(session, conversation, "short", started, message), () => {});
		return stream;
	}
	if (!announced.has(conversation)) {
		announced.add(conversation);
		policy.log(`conversation ${conversation} hands out work: its requests ask ${policy.providerName(model.provider)} for the long prompt cache from now on`);
	}
	const out = new AssistantMessageEventStream();
	void relay(out, original, model, context, options!, conversation, session, started);
	return out as unknown as Stream;
}

/** Sends a request with the long cache into `out`, or, if the provider refuses it for that, again with the short one. */
async function relay(out: AssistantMessageEventStream, original: StreamCall, model: Model, context: unknown, options: Options, conversation: number, session: string, started: number): Promise<void> {
	let retention: Retention = "long";
	let finished = false;
	const send = (event: AssistantMessageEvent) => {
		if (event.type === "done" || event.type === "error") finished = true;
		out.push(event);
	};
	try {
		let status: number | undefined;
		let body = "";
		const own = options.fetch ?? globalThis.fetch;
		const fetch: Fetch = async (input, init) => {
			const response = await own(input, init);
			status = response.status;
			body = "";
			// Read from a copy, so the provider's own handling still reads it whole.
			if (response.status >= 400 && response.status < 500) {
				try {
					body = (await response.clone().text()).slice(0, BODY_LIMIT);
				} catch {}
			}
			return response;
		};
		const first = original(model, context, { ...options, fetch, cacheRetention: "long" });
		// Held until the answer has begun: a refusal comes before any of it, and the person sees nothing of the attempt.
		const held: AssistantMessageEvent[] = [];
		let passing = false;
		let refusal: AssistantMessage | undefined;
		for await (const event of first) {
			if (passing) {
				send(event);
				continue;
			}
			if (event.type === "error" && !options.signal?.aborted && refusedForCache(event.error, status, body)) {
				refusal = event.error;
				break;
			}
			held.push(event);
			if (event.type === "done" || event.type === "error" || event.partial.content.length > 0) {
				passing = true;
				for (const each of held.splice(0)) send(each);
			}
		}
		if (refusal === undefined) {
			for (const each of held) send(each);
			if (!finished) out.end(await first.result());
		} else {
			retention = "short";
			const second = original(model, context, { ...options, cacheRetention: "short" });
			for await (const event of second) send(event);
			const message = await second.result();
			if (!finished) out.end(message);
			// Refused again in the same way, the long cache was not what the provider refused: it may be asked again.
			const again = message.stopReason === "error" && CACHE_WORDS.test(message.errorMessage ?? "");
			if (!again && !refused.has(model.provider)) {
				refused.add(model.provider);
				const name = policy!.providerName(model.provider);
				policy!.log(
					`${name} refused a request that asked for the long prompt cache (${plainProviderError(refusal.errorMessage ?? "") || "no message"}); it was sent again with the short cache, and ${name} is not asked for the long one again until the engine restarts`,
				);
			}
		}
	} catch (error) {
		// pi-ai reports a failure as an error event; anything else still ends the request as an error, never leaves it hanging.
		if (!finished) {
			const message: AssistantMessage = {
				role: "assistant",
				content: [],
				api: model.api,
				provider: model.provider,
				model: model.id,
				usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
				stopReason: "error",
				errorMessage: error instanceof Error ? error.message : String(error),
				timestamp: Date.now(),
			} as AssistantMessage;
			send({ type: "error", reason: "error", error: message } as AssistantMessageEvent);
		}
	}
	void out.result().then((message) => observe(session, conversation, retention, started, message), () => {});
}

const count = (n: number) => n.toLocaleString("en-US");

/** One line in engine.log for a request after a pause longer than the short cache lasts: what it read from the cache. */
function observe(session: string, conversation: number, retention: Retention, started: number, message: AssistantMessage): void {
	// A request that was refused or stopped did not touch the cache.
	if (message.stopReason === "error" || message.stopReason === "aborted") return;
	const usage = message.usage;
	const before = last.get(session);
	last.set(session, { at: Date.now(), read: usage?.cacheRead ?? 0, retention });
	if (before === undefined || usage === undefined || policy === undefined) return;
	const pause = started - before.at;
	if (pause <= PAUSE_MS) return;
	const asked = `the request before asked for the ${before.retention} cache`;
	if (usage.cacheRead > 0) {
		policy.log(`conversation ${conversation} read ${count(usage.cacheRead)} tokens from the prompt cache after ${duration(pause)} without a request; ${asked}`);
	} else if (usage.cacheWrite > 0 || before.read > 0) {
		// A provider that reports no writes (OpenAI's) shows a miss as input sent again; one that caches nothing shows neither.
		const again = usage.cacheWrite > 0 ? `wrote ${count(usage.cacheWrite)} tokens to it again` : `sent ${count(usage.input)} tokens of input again`;
		policy.log(`conversation ${conversation} read nothing from the prompt cache after ${duration(pause)} without a request, and ${again}; ${asked}`);
	}
}

export const promptCache: Feature = (_host, engine) => {
	policy = {
		handsOutWork: (id) => Object.values(engine.library().conversations).some((meta) => meta.parent === id),
		providerName: (id) => engine.providers().models.getProvider(id)?.name ?? id,
		log: (line) => engine.log(line),
	};
	return {
		hooks: [
			hook(GenerationTask, {
				beforeRequest: async (_request, api, context) => {
					const id = api.conversationId as unknown as number;
					if (sessionOf.has(id)) return undefined;
					// A conversation's first request may come before it has a session id: the next one finds it.
					const session = (await api.snapshot(ProviderDoc, api.conversationId, context))?.sessionId;
					if (session !== undefined) {
						sessionOf.set(id, session);
						conversationOf.set(session, id);
					}
					return undefined;
				},
			}),
		],
	};
};
