// How much of each signed-in subscription's allowance is used: the windows a provider counts in (five hours, a week,
// a month), how full each is, and when it resets. Shown at the top of Usage. See docs/limits.md.
//
// Two ways in, per provider:
// - From the answers pi² already gets. Anthropic, OpenAI Codex and GitHub Copilot put the figures in the headers (or,
//   for Codex over a WebSocket, in an event) of every answer to a subscription request. The subscription providers
//   are wrapped so that pi-ai's `onResponse` and `onProviderStreamEvent` callbacks reach this file; nothing else about
//   a request changes, and a failure here never reaches it.
// - By asking. Anthropic, OpenAI Codex and Kimi answer a usage address for the signed-in account. It is asked when the
//   app asks, when a subscription is signed in, at start when the last reading is old, and after a run whose answers
//   did not carry the figures; never more than about once a minute per provider, and less often when one says so.
//
// None of these is a documented, stable interface. Everything is parsed defensively: an answer that cannot be read
// becomes "Could not read the limits", never a crash and never a made-up number. Tokens come from pi-ai's own auth
// resolution, which renews and stores them, and never reach a log, an error message or the app.
//
// The app is sent `{ event: "limits", providers: ProviderLimits[] }` when it connects and whenever something changes;
// `limits.refresh` (optionally `{ id }`) asks again and answers with the same event. The last good reading of each
// provider is kept in `limits.json` in the data folder (percentages and times only), so it survives a restart.

import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { ModelAuth, Provider, ProviderResponse } from "@earendil-works/pi-ai";
import type { Engine, Feature } from "./features.ts";

// ---- What the app is sent

export type LimitWindow = {
	/** Stable within a provider ("five_hour", "codex.secondary"), the same whichever way it was read. */
	id: string;
	/** "5-hour window", "This week", "This week (Opus)". */
	label: string;
	/** How much of the window is used, 0–100. */
	usedPercent: number;
	/** When the window resets, in milliseconds since 1970, or null when the provider did not say. */
	resetsAt: number | null;
};

/** What one answer says. `note` is for what a window cannot show, such as an allowance without a limit. */
export type Reading = { plan: string | null; windows: LimitWindow[]; note?: string };

export type ProviderLimits = {
	id: string;
	name: string;
	plan: string | null;
	note: string | null;
	/**
	 * How pi² learns this provider's limits: "usage", it can ask at any time (and also reads the answers to requests);
	 * "responses", only the answers to requests carry them; "none", the provider does not report them.
	 */
	reports: "usage" | "responses" | "none";
	windows: LimitWindow[];
	/** When the windows were read, or null before the first reading. */
	fetchedAt: number | null;
	/** Where they came from: the provider's usage address, or the answers to requests. */
	source: "usage" | "responses" | null;
	/** Why the last attempt failed, plainly, and when. The windows shown are then the last good reading. */
	error: string | null;
	errorAt: number | null;
	refreshing: boolean;
};

export const UNREADABLE = "Could not read the limits";

// ---- Reading values

type Json = Record<string, unknown>;

function object(value: unknown): Json | undefined {
	return typeof value === "object" && value !== null && !Array.isArray(value) ? (value as Json) : undefined;
}

/** A short, non-empty string. */
function text(value: unknown): string | undefined {
	if (typeof value !== "string") return undefined;
	const trimmed = value.trim();
	return trimmed === "" || trimmed.length > 80 ? undefined : trimmed;
}

/** A finite number, from a number or a numeric string (some providers send numbers as strings). */
function number(value: unknown): number | undefined {
	if (typeof value === "number") return Number.isFinite(value) ? value : undefined;
	if (typeof value !== "string") return undefined;
	const trimmed = value.trim();
	if (trimmed === "" || trimmed.length > 32) return undefined;
	const parsed = Number(trimmed);
	return Number.isFinite(parsed) ? parsed : undefined;
}

/** A percentage reported as 0–100. A little over 100 (an overrun) shows as 100; anything stranger is not guessed at. */
function percent(value: unknown): number | undefined {
	const n = number(value);
	if (n === undefined || n < 0 || n > 200) return undefined;
	return Math.round(Math.min(100, n) * 10) / 10;
}

/** A fraction reported as 0–1, as a percentage. A value well above 1 is not a fraction, so it is not guessed at. */
function fraction(value: unknown): number | undefined {
	const n = number(value);
	return n === undefined || n < 0 || n > 2 ? undefined : percent(n * 100);
}

/** A moment in milliseconds since 1970, from seconds, milliseconds or an ISO 8601 string; undefined if it is none of those. */
function instant(value: unknown): number | undefined {
	let ms: number | undefined;
	const n = number(value);
	if (n !== undefined) ms = n > 1e11 ? n : n * 1000;
	else if (typeof value === "string" && value.length <= 64) {
		const parsed = Date.parse(value);
		ms = Number.isNaN(parsed) ? undefined : parsed;
	}
	// Before 2020, or more than about a year away, it is not a reset time.
	if (ms === undefined || ms < Date.UTC(2020, 0, 1) || ms > Date.now() + 400 * 86_400_000) return undefined;
	return Math.round(ms);
}

/** "codex-bengalfox" and "codex_bengalfox" are one limit. */
function limitId(name: string): string {
	return name.trim().toLowerCase().replace(/[^a-z0-9]+/g, "_").replace(/^_|_$/g, "");
}

function words(name: string): string {
	const spaced = name.replace(/[_-]+/g, " ").trim();
	return spaced.charAt(0).toUpperCase() + spaced.slice(1);
}

/** A plan as the provider names it ("plus", "LEVEL_BASIC"), for people ("Plus", "Basic"). */
export function planName(value: unknown): string | null {
	const raw = text(value)?.replace(/^LEVEL_/i, "");
	if (raw === undefined || raw === "" || /^(unknown|guest|unspecified)$/i.test(raw)) return null;
	const known: Record<string, string> = { prolite: "Pro Lite", promax: "Pro Max", free_workspace: "Free (workspace)", k12: "K-12" };
	return (
		known[raw.toLowerCase()] ??
		raw
			.toLowerCase()
			.split(/[_\s-]+/)
			.filter((word) => word !== "")
			.map((word) => word.charAt(0).toUpperCase() + word.slice(1))
			.join(" ")
	);
}

function near(minutes: number, target: number): boolean {
	return Math.abs(minutes - target) <= target * 0.05;
}

/** "5-hour window", "This week" and so on, from a window's length. */
export function windowLabel(minutes: number | undefined): string | undefined {
	if (minutes === undefined || !(minutes > 0)) return undefined;
	if (near(minutes, 300)) return "5-hour window";
	if (near(minutes, 10_080)) return "This week";
	if (near(minutes, 1_440)) return "24-hour window";
	if (near(minutes, 43_200) || near(minutes, 44_640)) return "This month";
	if (minutes < 120) return `${Math.round(minutes)}-minute window`;
	if (minutes < 2_880) return `${Math.round(minutes / 60)}-hour window`;
	return `${Math.round(minutes / 1_440)}-day window`;
}

/** The same id for a 5-hour or a weekly window whichever provider field it came from. */
function idForMinutes(minutes: number): string {
	if (near(minutes, 300)) return "five_hour";
	if (near(minutes, 10_080)) return "seven_day";
	return `${Math.round(minutes)}m`;
}

/** Header lookup by lower-case name, whatever case the record uses. */
function headerReader(headers: Record<string, string>): { get(name: string): string | undefined; names: string[] } {
	const lower = new Map<string, string>();
	for (const [name, value] of Object.entries(headers ?? {})) if (typeof value === "string") lower.set(name.toLowerCase(), value);
	return { get: (name) => lower.get(name), names: [...lower.keys()] };
}

// ---- Anthropic (Claude Pro/Max sign-in)

/**
 * The `anthropic-ratelimit-unified-*` headers on answers to subscription requests: utilisation as a fraction 0–1 and
 * the reset as Unix seconds, for the 5-hour (`5h`) and 7-day (`7d`) windows. Undocumented; read by Claude Code itself.
 */
export function anthropicFromHeaders(headers: Record<string, string>): Reading | undefined {
	const { get } = headerReader(headers);
	const windows: LimitWindow[] = [];
	for (const [key, id, label] of [
		["5h", "five_hour", "5-hour window"],
		["7d", "seven_day", "This week"],
	] as const) {
		const usedPercent = fraction(get(`anthropic-ratelimit-unified-${key}-utilization`));
		if (usedPercent === undefined) continue;
		windows.push({ id, label, usedPercent, resetsAt: instant(get(`anthropic-ratelimit-unified-${key}-reset`)) ?? null });
	}
	return windows.length === 0 ? undefined : { plan: null, windows };
}

const ANTHROPIC_SCOPES: Record<string, string> = { opus: "Opus", sonnet: "Sonnet", haiku: "Haiku", cowork: "Cowork", oauth_apps: "other apps" };

/**
 * The answer of `GET /api/oauth/usage`: `five_hour` and `seven_day` objects with `utilization` (0–100) and `resets_at`
 * (ISO 8601), and sometimes narrower ones such as `seven_day_opus`. Undocumented; it backs Claude Code's /usage.
 */
export function anthropicFromUsage(body: unknown): Reading | undefined {
	const data = object(body);
	if (data === undefined) return undefined;
	const windows: LimitWindow[] = [];
	const add = (key: string, label: string, always: boolean) => {
		const entry = object(data[key]);
		const usedPercent = percent(entry?.utilization);
		if (entry === undefined || usedPercent === undefined) return;
		const resetsAt = instant(entry.resets_at) ?? null;
		// A narrower window that is empty and not running is one this plan does not have: leave it out.
		if (!always && usedPercent === 0 && resetsAt === null) return;
		windows.push({ id: key, label, usedPercent, resetsAt });
	};
	add("five_hour", "5-hour window", true);
	add("seven_day", "This week", true);
	for (const key of Object.keys(data).slice(0, 50)) {
		const match = /^(five_hour|seven_day)_([a-z0-9_]{1,40})$/.exec(key);
		if (match === null) continue;
		const scope = ANTHROPIC_SCOPES[match[2]!] ?? words(match[2]!);
		add(key, `${match[1] === "five_hour" ? "5-hour window" : "This week"} (${scope})`, false);
	}
	// Both main windows there but null: an answer, with nothing to show. Anything else without a window is unreadable.
	if (windows.length === 0) return data.five_hour === null && data.seven_day === null ? { plan: null, windows: [] } : undefined;
	return { plan: null, windows };
}

// ---- OpenAI Codex (ChatGPT sign-in)

function codexWindow(raw: unknown, limit: string, position: "primary" | "secondary", name: string | undefined, now: number): LimitWindow | undefined {
	const window = object(raw);
	const usedPercent = percent(window?.used_percent);
	if (window === undefined || usedPercent === undefined) return undefined;
	const seconds = number(window.limit_window_seconds);
	const minutes = number(window.window_minutes) ?? (seconds === undefined ? undefined : seconds / 60);
	const after = number(window.reset_after_seconds);
	const resetsAt = instant(window.reset_at) ?? (after !== undefined && after >= 0 && after < 400 * 86_400 ? now + after * 1000 : null);
	const label = windowLabel(minutes) ?? (position === "primary" ? "Short window" : "Long window");
	return { id: `${limit}.${position}`, label: name === undefined ? label : `${label} (${name})`, usedPercent, resetsAt };
}

/**
 * The answer of `GET {chatgpt}/backend-api/wham/usage`, as the open-source Codex client reads it: `plan_type`,
 * `rate_limit.primary_window` / `secondary_window` (`used_percent`, `limit_window_seconds`, `reset_at` in Unix seconds)
 * and `additional_rate_limits[]` for limits of particular models.
 */
export function codexFromUsage(body: unknown, now = Date.now()): Reading | undefined {
	const data = object(body);
	if (data === undefined) return undefined;
	const windows: LimitWindow[] = [];
	const push = (window: LimitWindow | undefined) => window !== undefined && !windows.some((w) => w.id === window.id) && windows.push(window);
	const main = object(data.rate_limit);
	for (const position of ["primary", "secondary"] as const) push(codexWindow(main?.[`${position}_window`], "codex", position, undefined, now));
	const extras = Array.isArray(data.additional_rate_limits) ? data.additional_rate_limits.slice(0, 20) : [];
	for (const raw of extras) {
		const extra = object(raw);
		const named = text(extra?.metered_feature) ?? text(extra?.limit_name);
		if (extra === undefined || named === undefined || limitId(named) === "codex") continue;
		const limit = object(extra.rate_limit);
		for (const position of ["primary", "secondary"] as const) push(codexWindow(limit?.[`${position}_window`], limitId(named), position, text(extra.limit_name) ?? named, now));
	}
	// No windows is an answer only when it says so: `rate_limit` null, or both of its windows null. A window that is
	// there but cannot be read, or no `rate_limit` at all, is not the answer described above.
	const none = main === undefined ? data.rate_limit === null : main.primary_window == null && main.secondary_window == null;
	if (windows.length === 0 && !none) return undefined;
	return { plan: planName(data.plan_type), windows };
}

/**
 * The `x-codex-*` headers on answers over HTTP, as the Codex client reads them: `x-<limit>-primary-used-percent`,
 * `-window-minutes` and `-reset-at` (Unix seconds), the same for `secondary`, where `<limit>` is `codex` or another
 * metered limit, whose name for people is in `x-<limit>-limit-name`.
 */
export function codexFromHeaders(headers: Record<string, string>): Reading | undefined {
	const { get, names } = headerReader(headers);
	const families = new Set<string>();
	for (const name of names) {
		const match = /^x-([a-z0-9-]{1,60})-primary-used-percent$/.exec(name);
		if (match !== null) families.add(match[1]!);
	}
	const windows: LimitWindow[] = [];
	for (const family of [...families].slice(0, 10)) {
		const id = limitId(family);
		const name = id === "codex" ? undefined : (text(get(`x-${family}-limit-name`)) ?? family);
		for (const position of ["primary", "secondary"] as const) {
			const usedPercent = percent(get(`x-${family}-${position}-used-percent`));
			if (usedPercent === undefined) continue;
			const minutes = number(get(`x-${family}-${position}-window-minutes`));
			const resetsAt = instant(get(`x-${family}-${position}-reset-at`)) ?? null;
			// As the Codex client does: a window of all zeroes is no window.
			if (usedPercent === 0 && !(minutes !== undefined && minutes > 0) && resetsAt === null) continue;
			const label = windowLabel(minutes) ?? (position === "primary" ? "Short window" : "Long window");
			windows.push({ id: `${id}.${position}`, label: name === undefined ? label : `${label} (${name})`, usedPercent, resetsAt });
		}
	}
	return windows.length === 0 ? undefined : { plan: null, windows };
}

/** The `codex.rate_limits` event Codex sends over a WebSocket: `plan_type` and `rate_limits.primary` / `secondary`. */
export function codexFromEvent(event: unknown, now = Date.now()): Reading | undefined {
	const data = object(event);
	if (data?.type !== "codex.rate_limits") return undefined;
	const limits = object(data.rate_limits);
	const named = text(data.metered_limit_name) ?? text(data.limit_name) ?? "codex";
	const id = limitId(named);
	const windows: LimitWindow[] = [];
	for (const position of ["primary", "secondary"] as const) {
		const window = codexWindow(limits?.[position], id, position, id === "codex" ? undefined : named, now);
		if (window !== undefined) windows.push(window);
	}
	const plan = planName(data.plan_type);
	return windows.length === 0 && plan === null ? undefined : { plan, windows };
}

/** The ChatGPT account a Codex token is for, from its own claims, as pi-ai and the Codex client read it. */
export function codexAccount(token: string): string | undefined {
	try {
		const payload = token.split(".")[1];
		if (payload === undefined || payload.length > 20_000) return undefined;
		const claims = object(JSON.parse(Buffer.from(payload, "base64url").toString("utf8")));
		return text(object(claims?.["https://api.openai.com/auth"])?.chatgpt_account_id);
	} catch {
		return undefined;
	}
}

// ---- GitHub Copilot

/**
 * The `x-quota-snapshot-<quota>` headers on Copilot's answers, as VS Code's Copilot Chat reads them: URL-encoded
 * `ent` (the allowance, -1 for none), `rem` (percent remaining) and `rst` (the reset, ISO 8601). Premium requests are
 * what a subscription meters; chat is metered on the free plan; completions are not used by pi².
 */
export function copilotFromHeaders(headers: Record<string, string>): Reading | undefined {
	const { get, names } = headerReader(headers);
	const quotas = names
		.filter((name) => name.startsWith("x-quota-snapshot-"))
		.map((name) => name.slice("x-quota-snapshot-".length))
		.filter((quota) => quota !== "completions")
		// VS Code prefers premium_models to premium_interactions; both are the same allowance.
		.sort((a, b) => rank(a) - rank(b))
		.slice(0, 10);
	const windows: LimitWindow[] = [];
	const seen = new Set<string>();
	let unlimited = false;
	for (const quota of quotas) {
		const id = quota === "premium_models" || quota === "premium_interactions" ? "premium" : limitId(quota);
		if (id === "" || seen.has(id)) continue;
		let params: URLSearchParams;
		try {
			params = new URLSearchParams(get(`x-quota-snapshot-${quota}`) ?? "");
		} catch {
			continue;
		}
		if (number(params.get("ent")) === -1) {
			seen.add(id);
			unlimited = true;
			continue;
		}
		const remaining = number(params.get("rem"));
		if (remaining === undefined || remaining > 100 || remaining < -100) continue;
		const usedPercent = percent(Math.max(0, 100 - remaining));
		if (usedPercent === undefined) continue;
		seen.add(id);
		const label = id === "premium" ? "Premium requests" : id === "chat" ? "Chat messages" : words(quota);
		windows.push({ id, label, usedPercent, resetsAt: instant(params.get("rst")) ?? null });
	}
	if (windows.length === 0 && !unlimited) return undefined;
	return { plan: null, windows, ...(windows.length === 0 ? { note: "No limit on this plan." } : {}) };
}

function rank(quota: string): number {
	return ["premium_models", "premium_interactions", "chat"].indexOf(quota) + 1 || 10;
}

// ---- Kimi Code (subscription sign-in)

/**
 * The answer of `GET https://api.kimi.com/coding/v1/usages`, as open-source monitors read it: `usage` (the weekly
 * allowance as `limit`/`used`/`remaining`/`resetTime`), `limits[]` (rolling windows: `window.duration` +
 * `window.timeUnit`, and the same counts in `detail`), and in newer answers `usages.limit_5h` / `limit_7d` with a
 * `used_ratio`. The least certain of the shapes here: counts may come as strings.
 */
export function kimiFromUsage(body: unknown): Reading | undefined {
	const data = object(body);
	if (data === undefined) return undefined;
	const windows: LimitWindow[] = [];
	const push = (window: LimitWindow) => !windows.some((w) => w.id === window.id) && windows.push(window);
	const counted = (raw: unknown, id: string, label: string) => {
		const detail = object(raw);
		const limit = number(detail?.limit);
		if (detail === undefined || limit === undefined || limit <= 0) return;
		const remaining = number(detail.remaining);
		const used = number(detail.used) ?? (remaining === undefined ? undefined : limit - remaining);
		const usedPercent = used === undefined ? undefined : percent(Math.max(0, (used / limit) * 100));
		if (usedPercent !== undefined) push({ id, label, usedPercent, resetsAt: instant(detail.resetTime ?? detail.reset_time ?? detail.resetAt) ?? null });
	};
	const units: Record<string, number> = { TIME_UNIT_MINUTE: 1, TIME_UNIT_HOUR: 60, TIME_UNIT_DAY: 1_440, TIME_UNIT_WEEK: 10_080 };
	for (const raw of Array.isArray(data.limits) ? data.limits.slice(0, 10) : []) {
		const item = object(raw);
		const window = object(item?.window);
		const duration = number(window?.duration);
		const unit = typeof window?.timeUnit === "string" ? units[window.timeUnit] : undefined;
		const minutes = duration === undefined || unit === undefined ? undefined : duration * unit;
		const label = windowLabel(minutes);
		if (minutes !== undefined && label !== undefined) counted(item?.detail, idForMinutes(minutes), label);
	}
	const ratios = object(data.usages);
	for (const [key, id, label] of [
		["limit_5h", "five_hour", "5-hour window"],
		["limit_7d", "seven_day", "This week"],
	] as const) {
		const entry = object(ratios?.[key]);
		const usedPercent = fraction(entry?.used_ratio ?? entry?.usedRatio);
		if (usedPercent !== undefined) push({ id, label, usedPercent, resetsAt: instant(entry?.reset_time ?? entry?.resetTime) ?? null });
	}
	counted(data.usage, "seven_day", "This week");
	if (windows.length === 0) return undefined;
	return { plan: planName(object(object(data.user)?.membership)?.level), windows };
}

// ---- Which provider reports how

type UsageAddress = {
	/** Who answers, for messages: "Anthropic did not answer". */
	name: string;
	url(): string;
	headers(auth: ModelAuth): Record<string, string>;
	parse(body: unknown): Reading | undefined;
};

type Source = {
	headers?: (headers: Record<string, string>) => Reading | undefined;
	event?: (event: unknown) => Reading | undefined;
	usage?: UsageAddress;
};

class LimitsError extends Error {
	/** How long to leave the provider alone after this, beyond the usual minute. */
	readonly backoffMs: number;
	constructor(message: string, backoffMs = 0) {
		super(message);
		this.backoffMs = backoffMs;
	}
}

function bearer(auth: ModelAuth): string {
	const header = Object.entries(auth.headers ?? {}).find(([name]) => name.toLowerCase() === "authorization")?.[1];
	const token = auth.apiKey ?? (typeof header === "string" ? header.replace(/^Bearer\s+/i, "") : undefined);
	if (token === undefined || token === "") throw new LimitsError("The sign-in gave no token. Signing in again in Settings › Providers should fix it.");
	return token;
}

/** Keyed by pi-ai provider id. A signed-in subscription not listed here does not report its limits. */
export const SOURCES: Record<string, Source> = {
	anthropic: {
		headers: anthropicFromHeaders,
		usage: {
			name: "Anthropic",
			url: () => process.env.PI2_LIMITS_ANTHROPIC_URL ?? "https://api.anthropic.com/api/oauth/usage",
			headers: (auth) => ({ authorization: `Bearer ${bearer(auth)}`, "anthropic-beta": "oauth-2025-04-20" }),
			parse: anthropicFromUsage,
		},
	},
	"openai-codex": {
		headers: codexFromHeaders,
		event: codexFromEvent,
		usage: {
			name: "OpenAI",
			url: () => process.env.PI2_LIMITS_CODEX_URL ?? "https://chatgpt.com/backend-api/wham/usage",
			headers: (auth) => {
				const token = bearer(auth);
				const account = codexAccount(token);
				if (account === undefined) throw new LimitsError("The sign-in does not name a ChatGPT account. Signing in again in Settings › Providers may fix it.");
				return { authorization: `Bearer ${token}`, "chatgpt-account-id": account };
			},
			parse: (body) => codexFromUsage(body),
		},
	},
	"github-copilot": { headers: copilotFromHeaders },
	"kimi-coding": {
		usage: {
			name: "Kimi",
			url: () => process.env.PI2_LIMITS_KIMI_URL ?? "https://api.kimi.com/coding/v1/usages",
			headers: (auth) => ({ authorization: `Bearer ${bearer(auth)}` }),
			parse: kimiFromUsage,
		},
	},
};

// ---- Watching the answers

type Observers = { onResponse?(headers: Record<string, string>): void; onEvent?(event: unknown): void };
type StreamOptions = {
	onResponse?: (response: ProviderResponse, model: never) => void | Promise<void>;
	onProviderStreamEvent?: (event: unknown, model: never) => void | Promise<void>;
};

/**
 * The provider, unchanged except that its requests also report their response headers and stream events to
 * `observers`, after any callbacks the caller set (which still run). A throwing observer is ignored: pi-ai would
 * otherwise treat a failure in a stream-event callback as a failed request.
 */
export function observed(provider: Provider, observers: Observers): Provider {
	const wrap = (options: StreamOptions | undefined): StreamOptions => {
		const own = options ?? {};
		return {
			...own,
			...(observers.onResponse === undefined
				? {}
				: {
						onResponse: async (response, model) => {
							try {
								observers.onResponse!(response?.headers ?? {});
							} catch {}
							await own.onResponse?.(response, model);
						},
					}),
			...(observers.onEvent === undefined
				? {}
				: {
						onProviderStreamEvent: async (event, model) => {
							try {
								observers.onEvent!(event);
							} catch {}
							await own.onProviderStreamEvent?.(event, model);
						},
					}),
		};
	};
	type Stream = (model: unknown, context: unknown, options?: StreamOptions) => unknown;
	return new Proxy(provider, {
		get(target, key) {
			if (key === "stream" || key === "streamSimple") {
				const original = target[key] as unknown as Stream;
				return (model: unknown, context: unknown, options?: StreamOptions) => original.call(target, model, context, wrap(options));
			}
			const value = Reflect.get(target, key, target);
			return typeof value === "function" ? value.bind(target) : value;
		},
	});
}

// ---- The tracker

/** The least time between two requests to one provider's usage address. Shorter only in tests. */
const MIN_INTERVAL_MS = ((value) => (Number.isFinite(value) && value >= 0 ? value : 60_000))(Number(process.env.PI2_LIMITS_MIN_INTERVAL_MS ?? 60_000));
/** How long a usage address has to answer. */
const FETCH_TIMEOUT_MS = 6_000;
/** Renewing a token is pi-ai's work and has its own limit; this only stops waiting for it. */
const AUTH_TIMEOUT_MS = 20_000;
/** After the last answer of a run, wait this long before asking, so one run is asked about once. */
const AFTER_RUN_MS = 15_000;
/** A reading from the answers this recent makes asking the usage address unnecessary. */
const FRESH_MS = 2 * 60_000;
/** At start, a reading older than this is checked again. */
const STALE_MS = 10 * 60_000;
/** After "too many requests": at least this long, at most an hour, whatever the provider says. */
const BACKOFF_MS = 5 * 60_000;

type Stored = Reading & { fetchedAt: number; source: "usage" | "responses" };

type State = {
	reading?: Stored;
	error?: { message: string; at: number };
	lastAttempt: number;
	backoffUntil: number;
	inFlight?: Promise<void>;
	afterRun?: ReturnType<typeof setTimeout>;
};

/** A stored reading, or undefined if the file holds something else. */
function storedReading(raw: unknown): Stored | undefined {
	const data = object(raw);
	const fetchedAt = number(data?.fetchedAt);
	if (data === undefined || fetchedAt === undefined || (data.source !== "usage" && data.source !== "responses") || !Array.isArray(data.windows)) return undefined;
	const windows: LimitWindow[] = [];
	for (const item of data.windows.slice(0, 30)) {
		const window = object(item);
		const id = text(window?.id);
		const label = text(window?.label);
		const usedPercent = percent(window?.usedPercent);
		if (id === undefined || label === undefined || usedPercent === undefined) return undefined;
		windows.push({ id, label, usedPercent, resetsAt: number(window?.resetsAt) ?? null });
	}
	const note = text(data.note);
	return { plan: text(data.plan) ?? null, windows, ...(note === undefined ? {} : { note }), fetchedAt, source: data.source };
}

function retryAfterMs(value: string | null): number {
	const seconds = number(value);
	const ms = seconds !== undefined ? seconds * 1000 : value !== null && !Number.isNaN(Date.parse(value)) ? Date.parse(value) - Date.now() : 0;
	return Math.min(60 * 60_000, Math.max(BACKOFF_MS, ms));
}

/** Asks one usage address. Throws a LimitsError with a message fit for the person; never one that holds a token. */
async function askUsage(engine: Engine, id: string, address: UsageAddress): Promise<Reading> {
	let auth: ModelAuth;
	try {
		const result = await engine.providers().models.getAuth(id, { signal: AbortSignal.timeout(AUTH_TIMEOUT_MS) });
		if (result === undefined || result.source !== "OAuth") throw new LimitsError("Not signed in with a subscription.");
		auth = result.auth;
	} catch (error) {
		if (error instanceof LimitsError) throw error;
		throw new LimitsError("The sign-in could not be renewed. Signing in again in Settings › Providers should fix it.");
	}
	const url = address.url();
	let response: Response;
	let body: string;
	try {
		response = await fetch(url, {
			headers: { accept: "application/json", "user-agent": "pi2", ...address.headers(auth) },
			// The token is for this address only: never follow it somewhere else.
			redirect: "error",
			signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
		});
		if (!response.ok) {
			// What a refusal says is not needed (and could quote the request): let the connection go.
			void response.body?.cancel().catch(() => {});
			if (response.status === 429) throw new LimitsError(`${address.name} asked pi² to check less often. It will try again later.`, retryAfterMs(response.headers.get("retry-after")));
			if (response.status === 401 || response.status === 403) {
				throw new LimitsError(`${address.name} refused to say (${response.status}). If this keeps happening, signing in again in Settings › Providers may help.`);
			}
			throw new LimitsError(`${address.name} answered ${response.status}.`);
		}
		body = await response.text();
	} catch (error) {
		if (error instanceof LimitsError) throw error;
		// The message of a failed fetch can quote a header, so it is not passed on.
		const timedOut = error instanceof Error && (error.name === "TimeoutError" || error.name === "AbortError");
		throw new LimitsError(timedOut ? `${address.name} did not answer within ${FETCH_TIMEOUT_MS / 1000} seconds.` : `Could not reach ${new URL(url).host}.`);
	}
	if (body.length > 1_000_000) throw new LimitsError(UNREADABLE);
	let parsed: unknown;
	try {
		parsed = JSON.parse(body);
	} catch {
		throw new LimitsError(UNREADABLE);
	}
	const reading = address.parse(parsed);
	if (reading === undefined) throw new LimitsError(UNREADABLE);
	return reading;
}

class LimitsTracker {
	readonly #engine: Engine;
	readonly #path: string;
	readonly #states = new Map<string, State>();
	/** Signed-in subscriptions, in the providers' order. */
	#signedIn: string[] = [];
	#broadcastTimer: ReturnType<typeof setTimeout> | undefined;
	#saveTimer: ReturnType<typeof setTimeout> | undefined;

	constructor(engine: Engine) {
		this.#engine = engine;
		this.#path = join(engine.home, "limits.json");
		this.#load();
		const models = engine.providers().models;
		for (const provider of models.getProviders()) {
			const source = SOURCES[provider.id];
			if (provider.auth.oauth?.isSubscription !== true || (source?.headers === undefined && source?.event === undefined)) continue;
			const id = provider.id;
			models.setProvider(
				observed(provider, {
					onResponse: source.headers === undefined ? undefined : (headers) => this.#answered(id, source.headers!(headers)),
					onEvent:
						source.event === undefined
							? undefined
							: (event) => {
									const type = object(event)?.type;
									// Stream events come by the hundred; only these two say anything here.
									if (type === "codex.rate_limits" || type === "response.completed") this.#answered(id, source.event!(event));
								},
				}),
			);
		}
		void this.#start().catch((error) => engine.log("limits: first look failed:", error instanceof Error ? error.name : "error"));
	}

	event(): { event: "limits"; providers: ProviderLimits[] } {
		return { event: "limits", providers: this.#signedIn.map((id) => this.#view(id)) };
	}

	/** `limits.refresh`: ask every signed-in subscription, or the one named, subject to the usual limits on asking. */
	async refresh(params: Record<string, unknown>): Promise<unknown> {
		const id = typeof params.id === "string" ? params.id : undefined;
		await this.#updateSignedIn();
		if (id !== undefined && !this.#signedIn.includes(id)) throw new Error("That subscription is not signed in.");
		await Promise.all((id === undefined ? this.#signedIn : [id]).map((each) => this.#ask(each)));
		this.#broadcastNow();
		return this.event();
	}

	/** Someone signed in or out: drop what belonged to a subscription that is gone, ask about one that is new. */
	async providersChanged(): Promise<void> {
		const before = new Set(this.#signedIn);
		await this.#updateSignedIn();
		for (const id of this.#signedIn) if (!before.has(id)) void this.#ask(id);
		this.#broadcastSoon();
	}

	async #start(): Promise<void> {
		await this.#updateSignedIn();
		for (const id of this.#signedIn) {
			const reading = this.#states.get(id)?.reading;
			if (reading === undefined || Date.now() - reading.fetchedAt > STALE_MS) void this.#ask(id);
		}
		this.#broadcastSoon();
	}

	#state(id: string): State {
		let state = this.#states.get(id);
		if (state === undefined) {
			state = { lastAttempt: 0, backoffUntil: 0 };
			this.#states.set(id, state);
		}
		return state;
	}

	async #updateSignedIn(): Promise<void> {
		const providers = this.#engine.providers();
		const ids = await providers.subscriptionProviders().catch(() => undefined);
		// The Keychain could not be read: keep what was known rather than forget every reading.
		if (ids === undefined) return;
		this.#signedIn = providers.models
			.getProviders()
			.map((provider) => provider.id)
			.filter((id) => ids.has(id));
		let dropped = false;
		for (const [id, state] of this.#states) {
			if (ids.has(id)) continue;
			clearTimeout(state.afterRun);
			this.#states.delete(id);
			dropped = true;
		}
		if (dropped) this.#saveSoon();
	}

	/** What an answer to a request said, if anything. A run on a subscription also leads to asking, once it is over. */
	#answered(id: string, reading: Reading | undefined): void {
		// Only for a subscription sign-in: the same provider used with a key has no plan windows to show.
		if (!this.#signedIn.includes(id)) return;
		if (reading !== undefined) this.#record(id, reading, "responses");
		if (SOURCES[id]?.usage === undefined) return;
		const state = this.#state(id);
		clearTimeout(state.afterRun);
		state.afterRun = setTimeout(() => {
			state.afterRun = undefined;
			const reading = this.#states.get(id)?.reading;
			// The answers carried the figures: nothing to ask.
			if (reading?.source === "responses" && Date.now() - reading.fetchedAt < FRESH_MS) return;
			void this.#ask(id);
		}, AFTER_RUN_MS);
		state.afterRun.unref();
	}

	/**
	 * A reading from the usage address replaces the last one. One from an answer updates the windows it names and
	 * keeps the others: a Codex answer can carry one limit at a time.
	 */
	#record(id: string, reading: Reading, source: "usage" | "responses"): void {
		const state = this.#state(id);
		const previous = state.reading;
		let windows = reading.windows;
		if (source === "responses" && previous !== undefined) {
			const fresh = new Map(reading.windows.map((window) => [window.id, window]));
			windows = [...previous.windows.map((window) => fresh.get(window.id) ?? window), ...reading.windows.filter((window) => !previous.windows.some((old) => old.id === window.id))];
		}
		const note = reading.note ?? (source === "responses" && windows.length === 0 ? previous?.note : undefined);
		state.reading = { plan: reading.plan ?? previous?.plan ?? null, windows, ...(note === undefined ? {} : { note }), fetchedAt: Date.now(), source };
		state.error = undefined;
		this.#broadcastSoon();
		this.#saveSoon();
	}

	/** Asks the provider's usage address, unless it was asked within the minute, asked to be left alone, or is being asked. */
	#ask(id: string): Promise<void> {
		const address = SOURCES[id]?.usage;
		if (address === undefined) return Promise.resolve();
		const state = this.#state(id);
		if (state.inFlight !== undefined) return state.inFlight;
		const now = Date.now();
		if (now - state.lastAttempt < MIN_INTERVAL_MS || now < state.backoffUntil) return Promise.resolve();
		state.lastAttempt = now;
		state.inFlight = (async () => {
			try {
				this.#broadcastSoon();
				const reading = await askUsage(this.#engine, id, address);
				if (this.#states.get(id) === state) this.#record(id, reading, "usage");
			} catch (error) {
				const message = error instanceof LimitsError ? error.message : UNREADABLE;
				if (error instanceof LimitsError) state.backoffUntil = Date.now() + error.backoffMs;
				state.error = { message, at: Date.now() };
				// Only the plain message, or the kind of an unexpected error: never what it quotes.
				this.#engine.log("limits:", id, error instanceof LimitsError ? message : `unexpected ${error instanceof Error ? error.name : typeof error}`);
			} finally {
				state.inFlight = undefined;
				this.#broadcastSoon();
			}
		})();
		return state.inFlight;
	}

	#view(id: string): ProviderLimits {
		const source = SOURCES[id];
		const state = this.#states.get(id);
		const reading = state?.reading;
		return {
			id,
			name: this.#engine.providers().models.getProvider(id)?.name ?? id,
			plan: reading?.plan ?? null,
			note: reading?.note ?? null,
			reports: source?.usage !== undefined ? "usage" : source?.headers !== undefined || source?.event !== undefined ? "responses" : "none",
			windows: reading?.windows ?? [],
			fetchedAt: reading?.fetchedAt ?? null,
			source: reading?.source ?? null,
			error: state?.error?.message ?? null,
			errorAt: state?.error?.at ?? null,
			refreshing: state?.inFlight !== undefined,
		};
	}

	#broadcastSoon(): void {
		if (this.#broadcastTimer !== undefined) return;
		this.#broadcastTimer = setTimeout(() => this.#broadcastNow(), 150);
		this.#broadcastTimer.unref();
	}

	#broadcastNow(): void {
		clearTimeout(this.#broadcastTimer);
		this.#broadcastTimer = undefined;
		try {
			this.#engine.broadcast(this.event());
		} catch {
			// While the engine is still starting there is no one to send to yet (and no list of them); an app that
			// connects later is sent the current state anyway.
		}
	}

	#load(): void {
		try {
			const readings = object(object(JSON.parse(readFileSync(this.#path, "utf8")))?.readings) ?? {};
			for (const [id, raw] of Object.entries(readings)) {
				const reading = storedReading(raw);
				if (reading !== undefined) this.#state(id).reading = reading;
			}
		} catch {
			// No file yet, or one that cannot be read: start empty.
		}
	}

	#saveSoon(): void {
		if (this.#saveTimer !== undefined) return;
		this.#saveTimer = setTimeout(() => {
			this.#saveTimer = undefined;
			const readings = Object.fromEntries([...this.#states].filter(([, state]) => state.reading !== undefined).map(([id, state]) => [id, state.reading]));
			try {
				writeFileSync(this.#path, JSON.stringify({ version: 1, readings }, null, "\t"));
			} catch (error) {
				this.#engine.log("limits: could not save the last readings:", error instanceof Error ? error.message : String(error));
			}
		}, 1_000);
		this.#saveTimer.unref();
	}
}

export const limits: Feature = (_host, engine) => {
	const tracker = new LimitsTracker(engine);
	return {
		handlers: { "limits.refresh": (params) => tracker.refresh(params) },
		welcome: () => [tracker.event()],
		providersChanged: () => void tracker.providersChanged().catch((error) => engine.log("limits: after a sign-in change:", error instanceof Error ? error.name : "error")),
	};
};
