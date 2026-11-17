// Waiting for a provider's limit. A model request that a provider refuses for its rate limit (HTTP 429, "rate limit",
// a subscription's usage limit) or because it is overloaded (529, "overloaded") does not end the run: the run waits,
// for as long as the provider says when it says, otherwise with a backoff and jitter, and asks again by itself. See
// "When a limit is reached" in docs/limits.md.
//
// - The wait is pi-durable's own: its retry of a failed request is a stored sleep in the run's checkpoint, which a
//   restart resumes and Stop ends. A patch (engine/scripts/patch-dependencies.ts) lets this file decide how long that
//   sleep is for a refusal of this kind, and keeps the attempts spent on such waits from using up its three retries for
//   other errors.
// - What the provider said is read from the refusal itself. pi-ai turns a failed response into an error message and
//   drops its status and headers, so every model request is given a `fetch` that notes the status, headers and body of
//   a refusal (only in memory, never logged), and the note is matched to the message the request ends with.
// - A wait is noted per conversation in a session document (`pi2.limitWaits`): when it began, until when it waits now,
//   how many refusals. That is what the conversation page and Activity show, and what engine.log's lines about a wait
//   starting and ending come from, and it survives a restart with the sleep.

import type { AssistantMessage } from "@earendil-works/pi-ai";
import { AgentDoc, type ConversationId, defineDoc, GenerationTask, hook, LiveDoc } from "@earendil-works/pi-durable";
import type { Engine, Feature } from "./features.ts";
import { CARRY_ON, plainProviderError } from "./providererror.ts";

// ---- Reading a refusal

/** What a refused response said, noted by the fetch each model request is given. */
export type Refusal = { status: number; headers: Record<string, string>; body?: string };

/** A refusal worth waiting for: which kind, and the time the provider named for asking again, if it named one. */
export type Limit = { kind: "rate_limit" | "overloaded"; until?: number };

/**
 * Refusals that waiting does not cure: money or a plan's allowance used up for good (a monthly cap, no credit left, a
 * plan that does not include the model), a workspace cap only its admin can raise, a single request larger than the
 * limit itself. These end the run at once, as pi-ai already treats most of them.
 */
const TERMINAL =
	/insufficient_quota|billing|quota exceeded|out of budget|available balance|credit balance|Monthly usage limit reached|GoUsageLimitError|FreeUsageLimitError|usage_not_included|workplace_individual_usage_limit|request too large/i;
const RATE_LIMITED = /rate.?limit|too many requests|usage.?limit|(?<![a-z0-9])429(?![a-z0-9])/i;
const OVERLOADED = /overloaded|(?<![a-z0-9])529(?![a-z0-9])/i;

/** Whether an error is a refusal to wait for, and what the provider said about when to ask again. */
export function limitOf(text: string, refusal: Refusal | undefined, now: number): Limit | undefined {
	if (TERMINAL.test(text) || (refusal?.body !== undefined && TERMINAL.test(refusal.body))) return undefined;
	const status = refusal?.status;
	const kind = status === 429 ? "rate_limit" : status === 529 ? "overloaded" : OVERLOADED.test(text) ? "overloaded" : RATE_LIMITED.test(text) ? "rate_limit" : undefined;
	if (kind === undefined) return undefined;
	const until = namedTime(text, refusal, now);
	return until === undefined ? { kind } : { kind, until };
}

/**
 * The time a refusal names for asking again, or undefined. Of several, the latest: a provider whose five-hour window is
 * used up and that also says "retry after 30 seconds" would only refuse again in 30 seconds.
 */
export function namedTime(text: string, refusal: Refusal | undefined, now: number): number | undefined {
	const headers = refusal?.headers ?? {};
	const times: number[] = [];
	const ms = number(headers["retry-after-ms"]);
	if (ms !== undefined && ms >= 0) times.push(now + ms);
	const after = headers["retry-after"]?.trim();
	if (after !== undefined && after !== "") {
		const seconds = number(after);
		if (seconds !== undefined) {
			if (seconds >= 0) times.push(now + seconds * 1000);
		} else {
			const date = Date.parse(after);
			if (Number.isFinite(date)) times.push(date);
		}
	}
	// Claude subscriptions: the window that refused, and when it resets (Unix seconds), as on every answer (limits.ts).
	if (headers["anthropic-ratelimit-unified-status"]?.trim() === "rejected") {
		const reset = number(headers["anthropic-ratelimit-unified-reset"]);
		if (reset !== undefined && reset > 0) times.push(reset * 1000);
	}
	// ChatGPT subscriptions (Codex): the error body says when the usage limit resets.
	const error = errorOf(refusal?.body);
	const resetsAt = number(error?.resets_at);
	if (resetsAt !== undefined && resetsAt > 0) times.push(resetsAt * 1000);
	const resetsIn = number(error?.resets_in_seconds);
	if (resetsIn !== undefined && resetsIn >= 0) times.push(now + resetsIn * 1000);
	// pi-ai's own wording of that, when nothing else was read: "Try again in ~42 min."
	if (times.length === 0) {
		const minutes = /try again in ~?(\d+) ?min/i.exec(text)?.[1];
		if (minutes !== undefined) times.push(now + Number(minutes) * 60_000);
	}
	return times.length === 0 ? undefined : Math.max(now, ...times);
}

function number(value: unknown): number | undefined {
	if (typeof value === "number") return Number.isFinite(value) ? value : undefined;
	if (typeof value !== "string" || value.trim() === "") return undefined;
	const parsed = Number(value);
	return Number.isFinite(parsed) ? parsed : undefined;
}

function errorOf(body: string | undefined): Record<string, unknown> | undefined {
	if (body === undefined) return undefined;
	try {
		const parsed = JSON.parse(body) as { error?: unknown };
		return parsed?.error !== null && typeof parsed?.error === "object" ? (parsed.error as Record<string, unknown>) : undefined;
	} catch {
		return undefined;
	}
}

// ---- Noting refusals as requests are made

/** The refusal each failed request ended with, by the message pi-ai made of it. Only ever in memory. */
const refusals = new WeakMap<object, Refusal>();
/** The most of a refusal's body that is kept: enough for any error object, never a whole page. */
const BODY_LIMIT = 16 * 1024;

type Fetch = typeof globalThis.fetch;
type Stream = { result(): Promise<AssistantMessage> };
type StreamCall = (model: unknown, context: unknown, options?: { fetch?: Fetch }) => Stream;

/**
 * The models, unchanged except that each request is made with a `fetch` that notes a refusal, and the message the request
 * ends with is matched to it. Providers that do not use `fetch` (a WebSocket, say) are left as they are: their refusals
 * are judged by the error's text alone.
 */
export function noticingRefusals<T extends object>(models: T): T {
	return new Proxy(models, {
		get(target, key) {
			const value = Reflect.get(target, key, target);
			if ((key === "stream" || key === "streamSimple") && typeof value === "function") {
				const original = value as StreamCall;
				return (model: unknown, context: unknown, options?: { fetch?: Fetch }) => {
					let refusal: Refusal | undefined;
					const own = options?.fetch ?? globalThis.fetch;
					const fetch: Fetch = async (input, init) => {
						const response = await own(input, init);
						if (!response.ok) refusal = await noted(response);
						else refusal = undefined;
						return response;
					};
					const stream = original.call(target, model, context, { ...options, fetch });
					const result = stream.result.bind(stream);
					stream.result = () =>
						result().then((message) => {
							if (message?.stopReason === "error" && refusal !== undefined) refusals.set(message, refusal);
							return message;
						});
					return stream;
				};
			}
			return typeof value === "function" ? value.bind(target) : value;
		},
	});
}

async function noted(response: Response): Promise<Refusal> {
	const headers: Record<string, string> = {};
	response.headers.forEach((value, name) => {
		headers[name.toLowerCase()] = value;
	});
	// The body only of the refusals read here, and read from a copy, so the provider's own handling still reads it whole.
	let body: string | undefined;
	if (response.status === 429 || response.status === 529) {
		try {
			body = (await response.clone().text()).slice(0, BODY_LIMIT);
		} catch {}
	}
	return body === undefined ? { status: response.status, headers } : { status: response.status, headers, body };
}

/** The refusal noted for a message, for tests. */
export function refusalOf(message: object): Refusal | undefined {
	return refusals.get(message);
}

// ---- How long to wait

/** A wait for a limit, as the session document keeps it and the app is sent it. */
export type Wait = {
	kind: Limit["kind"];
	/** When the first refusal of this wait came. */
	since: number;
	/** When the run asks again. */
	until: number;
	/** Whether the provider named that time (otherwise it is a backoff). */
	told: boolean;
	/** Refusals so far in this wait. */
	refusals: number;
	/** The attempt of the run's request that was refused last; pi-durable numbers them from 1 in each generation. */
	attempt: number;
	provider: string;
	providerName: string;
};

export type WaitSettings = {
	/** The first wait when the provider names no time. Each refusal after it doubles it, up to `BACKOFF_STEPS` times. */
	backoffMs: number;
	/** The longest a run waits by itself when no time is named, from the first refusal. */
	maxWaitMs: number;
	/** The furthest time a provider may name that a run still waits for. */
	maxNamedMs: number;
};

const HOUR = 3_600_000;
/** The backoff grows to 40 times the first wait (10 minutes, by default) and stays there. */
const BACKOFF_CAP = 40;
export const DEFAULTS: WaitSettings = { backoffMs: 15_000, maxWaitMs: 6 * HOUR, maxNamedMs: 8 * 24 * HOUR };

/** What the engine's settings answer pi-durable (see the patch): how long to wait, and the attempts spent waiting. */
export type Decision = { waitMs?: number | false; spent: number };

type Callbacks = {
	now(): number;
	random(): number;
	providerName(id: string): string;
	/** A wait began, changed or ended: save it, and tell the apps. */
	changed(id: number, wait: Wait | undefined): void;
	log(line: string): void;
};

/** The waits of every conversation, and the decisions about them. Pure apart from its callbacks, so a test can drive it. */
export class Waits {
	readonly #waits = new Map<number, Wait>();
	readonly #settings: WaitSettings;
	readonly #callbacks: Callbacks;

	constructor(settings: WaitSettings, callbacks: Callbacks, saved: Record<string, Wait> = {}) {
		this.#settings = settings;
		this.#callbacks = callbacks;
		for (const [id, wait] of Object.entries(saved)) this.#waits.set(Number(id), wait);
	}

	get(id: number): Wait | undefined {
		return this.#waits.get(id);
	}

	all(): ReadonlyMap<number, Wait> {
		return this.#waits;
	}

	/**
	 * pi-durable asks this about a failed request (`message`), or with no message about a request the engine stopped
	 * during, before it decides on a retry itself.
	 */
	decide(message: AssistantMessage | undefined, attempt: number, id: number): Decision {
		const known = this.#waits.get(id);
		// A wait noted for an attempt at or after this one belongs to an earlier request of the run, which then answered.
		const current = known !== undefined && known.attempt < attempt ? known : undefined;
		if (known !== undefined && current === undefined) this.#end(id, undefined);
		const spent = current?.refusals ?? 0;
		if (message === undefined) return { spent };
		const now = this.#callbacks.now();
		const limit = limitOf(message.errorMessage ?? "", refusals.get(message), now);
		if (limit === undefined) {
			if (current !== undefined) this.#end(id, `${current.providerName} answered with another error`);
			return { spent };
		}
		const since = current?.since ?? now;
		const count = spent + 1;
		const providerName = this.#callbacks.providerName(message.provider);
		const what = limit.kind === "overloaded" ? `${providerName} being overloaded` : `${providerName}'s rate limit`;
		let waitMs: number;
		if (limit.until !== undefined) {
			const wait = Math.max(0, limit.until - now);
			if (wait > this.#settings.maxNamedMs) {
				const end = new Date(limit.until).toISOString();
				return this.#giveUp(message, id, current, `${providerName} named ${end} for asking again, later than pi² waits by itself (${duration(this.#settings.maxNamedMs)})`, spent);
			}
			// Spread a little, so that runs refused together do not all ask again in the same second.
			const spread = Math.min(30_000, Math.max(Math.min(1000, this.#settings.backoffMs), wait * 0.1));
			waitMs = wait + this.#callbacks.random() * spread;
		} else {
			const waited = now - since;
			if (waited >= this.#settings.maxWaitMs) {
				return this.#giveUp(message, id, current, `pi² waited ${duration(waited)} for ${what}, the longest it waits by itself when the provider names no time`, spent);
			}
			const step = this.#settings.backoffMs * Math.min(BACKOFF_CAP, 2 ** (count - 1));
			// Half the step and a random part of the other half: runs refused together spread out, and each still waits.
			waitMs = Math.min(step / 2 + (this.#callbacks.random() * step) / 2, this.#settings.maxWaitMs - waited);
		}
		const wait: Wait = { kind: limit.kind, since, until: now + waitMs, told: limit.until !== undefined, refusals: count, attempt, provider: message.provider, providerName };
		this.#waits.set(id, wait);
		this.#callbacks.changed(id, wait);
		if (current === undefined) {
			const when = new Date(wait.until).toISOString().replace(/\.\d+Z$/, "Z");
			const how = wait.told ? `until ${when}, the time it named` : `no time named, asking again at ${when} and backing off for up to ${duration(this.#settings.maxWaitMs)}`;
			this.#callbacks.log(`conversation ${id} is waiting for ${what}: ${how}`);
		}
		return { waitMs, spent: count };
	}

	/**
	 * A run found sleeping for a limit with no wait noted, as when the engine was killed between pi-durable storing the
	 * sleep and this file storing the wait: noted again from the sleep, with what can no longer be known (when it began,
	 * whether the provider named the time) taken as from now and not.
	 */
	adopt(id: number, sleep: { at: number; error: string }, provider: string): void {
		if (this.#waits.has(id)) return;
		const now = this.#callbacks.now();
		const limit = limitOf(sleep.error, undefined, now);
		if (limit === undefined) return;
		const wait: Wait = { kind: limit.kind, since: now, until: sleep.at, told: false, refusals: 1, attempt: 0, provider, providerName: provider === "" ? "The provider" : this.#callbacks.providerName(provider) };
		this.#waits.set(id, wait);
		this.#callbacks.changed(id, wait);
		this.#callbacks.log(`conversation ${id} is waiting for a limit, as before the engine stopped: until ${new Date(sleep.at).toISOString().replace(/\.\d+Z$/, "Z")}`);
	}

	/** A response that is not an error came for the conversation: a wait it had is over. */
	answered(id: number): void {
		const wait = this.#waits.get(id);
		if (wait === undefined) return;
		const waited = duration(this.#callbacks.now() - wait.since);
		this.#end(id, `carries on: ${wait.providerName} answered after ${waited} of waiting (${wait.refusals} refusal${wait.refusals === 1 ? "" : "s"})`, true);
	}

	/** The conversations working now: a wait of one that is not has ended with its run (stopped, most likely). */
	working(ids: ReadonlySet<number>): void {
		for (const [id, wait] of [...this.#waits]) {
			if (!ids.has(id)) this.#end(id, `stopped waiting for ${wait.kind === "overloaded" ? `${wait.providerName} being overloaded` : `${wait.providerName}'s rate limit`}: the run ended (stopped) after ${duration(this.#callbacks.now() - wait.since)}`, true);
		}
	}

	#giveUp(message: AssistantMessage, id: number, current: Wait | undefined, why: string, spent: number): Decision {
		// The run ends on this message: its error says why it was not waited for, and how to carry on.
		message.errorMessage = `${message.errorMessage ?? "The request was refused"}\n\n${why}. ${CARRY_ON}`;
		this.#callbacks.log(`conversation ${id} ${current === undefined ? "did not wait" : "gave up waiting"}: ${why}; the run ends`);
		if (current !== undefined) this.#end(id, undefined);
		return { waitMs: false, spent };
	}

	#end(id: number, line: string | undefined, plain = false): void {
		if (!this.#waits.delete(id)) return;
		this.#callbacks.changed(id, undefined);
		if (line !== undefined) this.#callbacks.log(plain ? `conversation ${id} ${line}` : `conversation ${id} stopped waiting: ${line}`);
	}
}

/** "42 s", "14 min", "2 h 5 min", "3 days". */
export function duration(ms: number): string {
	const seconds = Math.max(0, Math.round(ms / 1000));
	if (seconds < 60) return `${seconds} s`;
	const minutes = Math.round(seconds / 60);
	if (minutes < 60) return `${minutes} min`;
	const hours = Math.floor(minutes / 60);
	if (hours < 48) return minutes % 60 === 0 ? `${hours} h` : `${hours} h ${minutes % 60} min`;
	return `${Math.round(hours / 24)} days`;
}

// ---- The feature

const LimitWaits = defineDoc<{ waits: Record<string, Wait>; saved?: number }>({
	kind: "pi2.limitWaits",
	version: 1,
	scope: "session",
	initial: () => ({ waits: {} }),
	checkpointWhen: () => true,
});

/** A setting from the environment, for tests: a number of milliseconds, or the default. */
function setting(name: string, fallback: number): number {
	const value = Number(process.env[name]);
	return process.env[name] !== undefined && Number.isFinite(value) && value >= 0 ? value : fallback;
}

/** What the app is sent about a wait: in the conversation's state while the run sleeps, and in its Activity row. */
function shown(wait: Wait) {
	return { kind: wait.kind, since: wait.since, until: wait.until, told: wait.told, refusals: wait.refusals, provider: wait.providerName };
}

export const limitWait: Feature = (_host, engine: Engine) => {
	const settings: WaitSettings = {
		backoffMs: setting("PI2_LIMIT_BACKOFF_MS", DEFAULTS.backoffMs),
		maxWaitMs: setting("PI2_LIMIT_WAIT_MAX_MS", DEFAULTS.maxWaitMs),
		maxNamedMs: DEFAULTS.maxNamedMs,
	};
	/** Saves so far; a save stores the waits only if no later one has been stored before it. */
	let saves = 0;
	/**
	 * Store the waits as they are now. The commit is started at once, not after the one before it, so that it is on its way
	 * before pi-durable's commit of the run's sleep, which follows the decision this is called from.
	 */
	const save = (): Promise<unknown> => {
		const waits = Object.fromEntries([...waitsOf().all()].map(([id, wait]) => [String(id), wait]));
		const number = ++saves;
		return engine
			.harness()
			.commit(async (tx) => {
				const doc = await tx.doc(LimitWaits);
				if ((doc.saved ?? 0) > number) return;
				doc.waits = waits;
				doc.saved = number;
			}, engine.context())
			.catch((error) => engine.log("limit waits: could not be saved:", error instanceof Error ? error.message : String(error)));
	};
	const callbacks: Callbacks = {
		now: Date.now,
		random: Math.random,
		providerName: (id) => engine.providers().models.getProvider(id)?.name ?? id,
		changed: (id) => {
			// Shown once stored, so that what Activity shows has been kept (a test waits for it before it kills the engine).
			void save().then(() => {
				engine.stateChanged(id);
				engine.activityChanged();
			});
		},
		log: (line) => engine.log(line),
	};
	/** Whether the runs the last engine left have been looked at for a sleep with no wait noted. */
	let looked = false;
	/** The conversations that had work running when last told. */
	let previous: ReadonlySet<number> = new Set();
	/** The provider of the model a conversation is on now: the one its last request went to. */
	const providerOf = async (id: number): Promise<string> => {
		const agent = (await engine.harness().snapshot(AgentDoc, id as unknown as ConversationId, engine.context())) as { model?: { provider?: string } } | undefined;
		return agent?.model?.provider ?? "";
	};
	/** A run that has just ended: if it ended on an error from the model's provider, engine.log says so, and what it was. */
	const logProviderError = async (id: number): Promise<void> => {
		try {
			const failure = (await engine.harness().snapshot(LiveDoc, id as unknown as ConversationId, engine.context()))?.runFailure;
			if (failure?.reason !== "model_error") return;
			const provider = await providerOf(id);
			const name = provider === "" ? "the provider" : callbacks.providerName(provider);
			engine.log(`conversation ${id}'s run ended on an error from ${name}: ${plainProviderError(String(failure.detail ?? ""))}`);
		} catch {}
	};
	let waits: Waits | undefined;
	const waitsOf = () => (waits ??= new Waits(settings, callbacks));
	return {
		start: async () => {
			const doc = await engine.harness().snapshot(LimitWaits, engine.context());
			const saved: Record<string, Wait> = JSON.parse(JSON.stringify(doc?.waits ?? {}));
			saves = doc?.saved ?? 0;
			// Anything decided before this (nothing, as the features start in order) is newer than what was saved.
			for (const [id, wait] of waits?.all() ?? []) saved[String(id)] = wait;
			waits = new Waits(settings, callbacks, saved);
		},
		retry: (message, attempt, id) => waitsOf().decide(message, attempt, id),
		hooks: [
			hook(GenerationTask, {
				afterResponse: (message, api) => {
					// An answer, not an error or a request stopped part way.
					const stop = (message as { stopReason?: string }).stopReason;
					if (stop === "stop" || stop === "length" || stop === "toolUse") waitsOf().answered(api.conversationId as unknown as number);
				},
			}),
		],
		runsChanged: (working) => {
			waitsOf().working(working);
			for (const id of previous) if (!working.has(id)) void logProviderError(id);
			previous = new Set(working);
			if (looked) return;
			looked = true;
			for (const id of working) {
				if (waitsOf().get(id) !== undefined) continue;
				const conversation = id as unknown as ConversationId;
				void (async () => {
					const sleep = (await engine.harness().snapshot(LiveDoc, conversation, engine.context()))?.generation?.retry;
					if (sleep === undefined) return;
					waitsOf().adopt(id, sleep, await providerOf(id));
				})().catch(() => {});
			}
		},
		state: (view) => {
			const wait = waitsOf().get(view.conversation.id as unknown as number);
			// Only while the run sleeps: once it asks again, the request in flight shows as any other. The time is the
			// sleep's own, which pi-durable took a moment after this file decided on it.
			const sleep = (view.docs["pi.live"] as { generation?: { retry?: { at?: unknown } } } | undefined)?.generation?.retry;
			if (wait === undefined || sleep === undefined) return { limitWait: null };
			return { limitWait: { ...shown(wait), until: typeof sleep.at === "number" ? sleep.at : wait.until } };
		},
		activity: (id) => {
			const wait = waitsOf().get(id);
			return { limit: wait === undefined ? null : shown(wait) };
		},
	};
};
