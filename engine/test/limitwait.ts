// Waiting for a provider's limit (src/limitwait.ts, docs/limits.md): how a refusal is read and how long a run waits for
// it, then a real engine against a stand-in provider on 127.0.0.1 that refuses (HTTP 429 or 529, with and without a
// time to ask again) and then answers. No real provider is called.
//
// No check depends on how fast the Mac is. Waits the provider does not time are made short with PI2_LIMIT_BACKOFF_MS,
// times it names are a few milliseconds, and a wait of an hour is only looked at, stopped and carried over a restart,
// never sat through. Each check waits for what the engine does, never for a time. What the engine logged is waited for
// the same way (`logSays` below): it reaches this test over a pipe, so a line can arrive after the socket event that
// followed it, and reading `log` once then misses it (#588).

import assert from "node:assert/strict";
import { type ChildProcess, execFileSync, spawn } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { AssistantMessage } from "@earendil-works/pi-ai";
import { unfinished } from "../src/extensions.ts";
import { DEFAULTS, duration, type EpisodeChange, limitOf, namedTime, noticingRefusals, type Wait, Waits, wordedTime } from "../src/limitwait.ts";
import { usedUpUntil } from "../src/limits.ts";
import { closedStream, failureOf, isNetworkError, retryNetwork, transportFailureOf } from "../src/networkwait.ts";
import { CARRY_ON, plainProviderError } from "../src/providererror.ts";
import { EngineClient, standInApp, stop, until } from "./patience.ts";

// This test is about conversations in no project, made with the agents of no project: its engines carry nothing into
// projects (`PI2_CARRY_NEVER`, carryover.ts), as the last version with the switch never on did (#715).
process.env.PI2_CARRY_NEVER = "1";
// The engine takes changes to what the person set only from its app's connection (#513): this test's connection stands
// for the app's, as the tests that answer for the person already do (#504).
process.env.PI2_APP_BUNDLE = standInApp();

function step(name: string): void {
	console.log(`ok  ${name}`);
}

// ---- Reading a transport failure, and its backoff

{
	const cause = (code: string) => Object.assign(new Error(`connect ${code}`), { code });
	for (const code of ["ENOTFOUND", "EAI_AGAIN", "ENETUNREACH", "EHOSTUNREACH", "ENETDOWN", "ECONNREFUSED", "ECONNRESET", "ETIMEDOUT", "UND_ERR_CONNECT_TIMEOUT", "UND_ERR_HEADERS_TIMEOUT", "UND_ERR_SOCKET"]) {
		assert.ok(isNetworkError(new Error("Connection error.", { cause: new TypeError("fetch failed", { cause: cause(code) }) })));
	}
	assert.ok(isNetworkError(new TypeError("fetch failed", { cause: new AggregateError([cause("ECONNREFUSED"), cause("ENETUNREACH")]) }), true));
	assert.ok(isNetworkError(new TypeError("fetch failed"), true));
	assert.ok(isNetworkError(new Error("Connection error."), true));
	assert.ok(isNetworkError(new DOMException("timed out", "TimeoutError"), true));
	assert.ok(!isNetworkError(new Error("Connection error.")));
	assert.ok(!isNetworkError(new Error("fetch failed: getaddrinfo ENOTFOUND example.invalid"), true), "not matched by substring");
	assert.ok(!isNetworkError(new TypeError("fetch failed", { cause: cause("CERT_HAS_EXPIRED") }), true));
	assert.ok(!isNetworkError(Object.assign(new Error("Connection error.", { cause: cause("ENOTFOUND") }), { status: 400 }), true));
	assert.ok(!isNetworkError(new DOMException("stopped", "AbortError"), true));
	let wait: ReturnType<typeof retryNetwork>["network"];
	let now = 1000;
	for (const delay of [2000, 5000, 15_000, 30_000, ...Array(9).fill(60_000), 8000]) {
		const retry = retryNetwork(wait, now, 1);
		assert.equal(retry.waitMs, delay);
		wait = retry.network;
		now += delay;
	}
	assert.equal(now - 1000, 600_000);
	assert.deepEqual(retryNetwork(wait, now, 1), { waitMs: false });
	assert.equal(retryNetwork(undefined, now, 1).waitMs, 2000);
	step("transport failures are matched by code and cause, not provider text; retry delays grow and end at ten minutes");
}

// ---- A stream the provider closed (#550)

{
	// Each shape as it arrives from fetch: HTTP/2 ending the stream with a code of its own before anything is answered,
	// and undici's words for a connection that ended in flight, which an SDK wraps and pi-ai flattens into the message
	// the run ends with ("Connection error.: <the deepest cause> (<its code>)").
	const http2 = (code: string) => new TypeError("fetch failed", { cause: Object.assign(new Error(`Stream closed with error code ${code}`), { code: "ERR_HTTP2_STREAM_ERROR" }) });
	assert.equal(closedStream(http2("NGHTTP2_ENHANCE_YOUR_CALM")), "calm");
	assert.equal(closedStream(http2("NGHTTP2_REFUSED_STREAM")), "calm");
	assert.equal(closedStream("Connection error.: Stream closed with error code NGHTTP2_ENHANCE_YOUR_CALM (ERR_HTTP2_STREAM_ERROR)"), "calm");
	assert.equal(closedStream(new TypeError("fetch failed", { cause: Object.assign(new Error("read ECONNRESET"), { code: "ECONNRESET" }) })), "closed");
	assert.equal(closedStream("Connection error.: terminated (UND_ERR_SOCKET)"), "closed");
	assert.equal(closedStream("Connection error.: other side closed (UND_ERR_SOCKET)"), "closed");
	// Not a stream the provider closed: a certificate, a name that does not resolve, Stop, and a response that came.
	assert.equal(closedStream(new TypeError("fetch failed", { cause: Object.assign(new Error("certificate has expired"), { code: "CERT_HAS_EXPIRED" }) })), undefined);
	assert.equal(closedStream("Connection error.: getaddrinfo ENOTFOUND example.invalid"), undefined);
	assert.equal(closedStream(new DOMException("stopped", "AbortError")), undefined);
	assert.equal(closedStream(Object.assign(new Error("Stream closed with error code NGHTTP2_ENHANCE_YOUR_CALM"), { status: 400 })), undefined);
	assert.equal(failureOf(new TypeError("fetch failed", { cause: Object.assign(new Error("connect ECONNREFUSED"), { code: "ECONNREFUSED" }) }), true), "network");
	// A provider that asked for less begins at the longer waits, and goes on from there.
	const calm = retryNetwork(undefined, 1000, 1, "calm");
	assert.equal(calm.waitMs, 15_000);
	assert.deepEqual(calm.network, { since: 1000, count: 1, closed: true, calm: true });
	assert.equal(retryNetwork(calm.network, 16_000, 1).waitMs, 30_000);
	assert.deepEqual(retryNetwork(undefined, 1000, 1, "closed").network, { since: 1000, count: 1, closed: true });
	assert.equal(retryNetwork(undefined, 1000, 1, "closed").waitMs, 2_000);
	assert.deepEqual(retryNetwork(undefined, 1000, 1, "network").network, { since: 1000, count: 1 });
	step("a stream the provider closed is told apart from a network that is away, and one that asks for less waits longer first");
}

{
	// What the run notes down of each: a stream closed before or during an answer is asked again whole, and a request the
	// provider answered is not, whatever words came with it.
	const noted = async (errorMessage: string, options: { content?: unknown; fetch?: typeof fetch } = {}): Promise<ReturnType<typeof transportFailureOf>> => {
		const message = { role: "assistant", content: options.content ?? [], api: "openai-completions", provider: "stand-in", model: "m", usage: {}, stopReason: "error", errorMessage, timestamp: 1 } as unknown as AssistantMessage;
		const models = noticingRefusals({
			stream: (_model: unknown, _context: unknown, streamOptions?: { fetch?: typeof fetch }) => ({
				result: async () => {
					if (options.fetch !== undefined) await streamOptions!.fetch!("http://stand-in/v1/chat/completions", {});
					return message;
				},
			}),
		}) as unknown as { stream: (model: unknown, context: unknown, options?: { fetch?: typeof fetch }) => { result: () => Promise<AssistantMessage> } };
		return transportFailureOf(await models.stream({}, {}, options.fetch === undefined ? {} : { fetch: options.fetch }).result());
	};
	const refused = async () => new Response('{"error":{"message":"Connection error.: terminated (UND_ERR_SOCKET)"}}', { status: 400 });
	assert.equal(await noted("Connection error.: Stream closed with error code NGHTTP2_ENHANCE_YOUR_CALM (ERR_HTTP2_STREAM_ERROR)"), "calm");
	assert.equal(await noted("Connection error.: other side closed (UND_ERR_SOCKET)"), "closed");
	// Part way through an answer counts too: the whole request is asked again, so that part is dropped.
	assert.equal(await noted("Connection error.: terminated (UND_ERR_SOCKET)", { content: [{ type: "text", text: "Half an ans" }] }), "closed");
	// The request's own fault: a 4xx with a message, a content flag, and a limit's refusal.
	assert.equal(await noted("Connection error.: terminated (UND_ERR_SOCKET)", { fetch: refused }), undefined);
	assert.equal(await noted("Provider finish_reason: content_filter"), undefined);
	assert.equal(await noted("429 This request would exceed your account's rate limit."), undefined);
	step("a run notes a stream the provider closed, part way through an answer or not, but never an answer the provider refused");
}

// ---- Reading a refusal

const NOW = Date.UTC(2026, 10, 17, 12, 0, 0);
{
	assert.deepEqual(limitOf("429 This request would exceed your account's rate limit.", { status: 429, headers: {} }, NOW), { kind: "rate_limit" });
	assert.deepEqual(limitOf('{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}', undefined, NOW), { kind: "overloaded" });
	assert.deepEqual(limitOf("Overloaded", { status: 529, headers: {} }, NOW), { kind: "overloaded" });
	assert.deepEqual(limitOf("429 status code (no body)", undefined, NOW), { kind: "rate_limit" });
	assert.deepEqual(limitOf("You have hit your ChatGPT usage limit (plus plan). Try again in ~42 min.", undefined, NOW), { kind: "rate_limit", until: NOW + 42 * 60_000 });
	// Not a wait: a bad key, a refused request, a model that does not exist, money or an allowance used up for good.
	for (const text of [
		"401 invalid x-api-key",
		"400 messages: text content blocks must be non-empty",
		"404 model: claude-nonexistent",
		"429 You exceeded your current quota, please check your plan and billing details. insufficient_quota",
		"400 Your credit balance is too low to access the Anthropic API.",
		"429 Request too large for gpt-4o: Limit 30000, Requested 50000.",
		"Monthly usage limit reached",
	]) {
		assert.equal(limitOf(text, undefined, NOW), undefined, text);
	}
	assert.equal(limitOf("The usage limit has been reached", { status: 429, headers: {}, body: '{"error":{"type":"usage_not_included"}}' }, NOW), undefined, "a plan that does not include the model");
	// A number inside a longer one is not a status.
	assert.equal(limitOf("400 request req_14290 failed", undefined, NOW), undefined);
	step("a refusal for a limit or an overload is told apart from errors waiting does not cure");
}
{
	const headers = (h: Record<string, string>) => ({ status: 429, headers: h });
	assert.equal(namedTime("", headers({ "retry-after": "30" }), NOW), NOW + 30_000);
	assert.equal(namedTime("", headers({ "retry-after-ms": "250" }), NOW), NOW + 250);
	assert.equal(namedTime("", headers({ "retry-after": "Tue, 17 Nov 2026 12:05:00 GMT" }), NOW), NOW + 5 * 60_000);
	assert.equal(namedTime("", headers({}), NOW), undefined);
	assert.equal(namedTime("", headers({ "retry-after": "soon" }), NOW), undefined);
	// A time already past means now.
	assert.equal(namedTime("", headers({ "retry-after": "Tue, 17 Nov 2026 11:00:00 GMT" }), NOW), NOW);
	// A used-up Claude window names its reset; of two times, the later counts.
	const reset = NOW / 1000 + 2 * 3600;
	assert.equal(namedTime("", headers({ "retry-after": "30", "anthropic-ratelimit-unified-status": "rejected", "anthropic-ratelimit-unified-reset": String(reset) }), NOW), reset * 1000);
	assert.equal(namedTime("", headers({ "anthropic-ratelimit-unified-status": "allowed", "anthropic-ratelimit-unified-reset": String(reset) }), NOW), undefined, "a window that did not refuse");
	// ChatGPT's usage limit, in the error body.
	assert.equal(namedTime("", { status: 429, headers: {}, body: JSON.stringify({ error: { type: "usage_limit_reached", resets_at: reset } }) }, NOW), reset * 1000);
	assert.equal(namedTime("", { status: 429, headers: {}, body: JSON.stringify({ error: { resets_in_seconds: 90 } }) }, NOW), NOW + 90_000);
	// A plan's short window whose reset is only said in words, as OpenCode Go says it; a month's allowance is still terminal.
	const GO = "429 GoUsageLimitError: OpenCode Go usage limit reached (5-hour, resets in 2h 17m). To keep going now, turn on Extra Usage or upgrade to Go Plus at https://opencode.ai/console";
	assert.equal(wordedTime(GO, NOW), NOW + (2 * 60 + 17) * 60_000);
	assert.equal(wordedTime("Try again in ~42 min.", NOW), NOW + 42 * 60_000);
	assert.equal(wordedTime("retry in 30s", NOW), NOW + 30_000);
	assert.equal(wordedTime("resets in 1 day 3 hours", NOW), NOW + 27 * 60 * 60_000);
	assert.equal(wordedTime("resets in 2 hours and 5 minutes", NOW), NOW + 125 * 60_000);
	assert.equal(wordedTime("the limit resets soon", NOW), undefined);
	assert.equal(wordedTime("installed in 3 minutes", NOW), undefined);
	assert.equal(namedTime(GO, undefined, NOW), NOW + (2 * 60 + 17) * 60_000);
	assert.deepEqual(limitOf(GO, undefined, NOW), { kind: "rate_limit", until: NOW + (2 * 60 + 17) * 60_000 });
	assert.equal(limitOf(GO.replace("5-hour, resets in 2h 17m", "monthly, resets in 12d 3h"), undefined, NOW), undefined);
	assert.equal(limitOf("429 GoUsageLimitError: OpenCode Go usage limit reached.", undefined, NOW), undefined);
	assert.equal(limitOf("Monthly usage limit reached, resets in 2h", undefined, NOW), undefined);
	step("the time a provider names for asking again: retry-after (seconds, milliseconds, a date), a window's reset, an error body, a wait in words");
}

// ---- How long a run waits

function message(errorMessage: string, provider = "anthropic"): AssistantMessage {
	return { role: "assistant", content: [], api: "anthropic-messages", provider, model: "m", usage: {} as never, stopReason: "error", errorMessage, timestamp: NOW };
}
{
	let now = NOW;
	let random = 0.5;
	const lines: string[] = [];
	const saved = new Map<number, Wait | undefined>();
	const waits = new Waits(DEFAULTS, {
		now: () => now,
		random: () => random,
		providerName: (id) => (id === "anthropic" ? "Anthropic" : id),
		changed: (id, wait) => saved.set(id, wait),
		log: (line) => lines.push(line),
	});
	const refused = "429 rate_limit_error: This request would exceed your account's rate limit.";
	// No time named: half the step and a random part of the other half, the step doubling from 15 s up to 10 minutes.
	const first = waits.decide(message(refused), 1, 7);
	assert.equal(first.waitMs, 15_000 * 0.75);
	assert.equal(first.spent, 1);
	assert.equal(saved.get(7)?.refusals, 1);
	assert.match(lines.at(-1)!, /^conversation 7 is waiting for Anthropic's rate limit: no time named, asking again at .* and backing off for up to 6 h$/);
	random = 0;
	assert.equal(waits.decide(message(refused), 2, 7).waitMs, 15_000);
	random = 1;
	assert.equal(waits.decide(message(refused), 3, 7).waitMs, 60_000);
	for (let attempt = 4; attempt < 12; attempt++) waits.decide(message(refused), attempt, 7);
	assert.equal(waits.decide(message(refused), 12, 7).waitMs, 600_000, "the step stops growing at 10 minutes");
	assert.equal(lines.length, 1, "one line when the wait starts, not one for each refusal");
	// pi-durable asks about a request the engine stopped during: the refusals do not count against its retries.
	assert.deepEqual(waits.decide(undefined, 13, 7), { spent: 12 });
	// The answer ends the wait.
	now += 60 * 60_000;
	waits.answered(7);
	assert.equal(waits.get(7), undefined);
	assert.equal(saved.get(7), undefined);
	assert.match(lines.at(-1)!, /^conversation 7 carries on: Anthropic answered after 1 h of waiting \(12 refusals\)$/);

	// A time named: that long, and a little more, so runs refused together spread out.
	random = 1;
	const hour = waits.decide(message("You have hit your ChatGPT usage limit (plus plan). Try again in ~60 min.", "openai-codex"), 1, 9);
	assert.equal(hour.waitMs, 60 * 60_000 + 30_000, "an hour, and at most 30 seconds more");
	assert.equal(waits.get(9)?.told, true);
	assert.match(lines.at(-1)!, /^conversation 9 is waiting for openai-codex's rate limit: until .*Z, the time it named$/);

	// Another error ends the wait, and leaves the retries to pi-durable, with the refusals not counted.
	const other = waits.decide(message("500 Internal server error"), 2, 9);
	assert.deepEqual(other, { spent: 1 });
	assert.equal(waits.get(9), undefined);
	assert.match(lines.at(-1)!, /^conversation 9 stopped waiting: openai-codex answered with another error$/);

	// A wait of more than 8 days is not believed: the run ends, and its error says why.
	const far = message("You have hit your ChatGPT usage limit (pro plan). Try again in ~20000 min.", "openai-codex");
	assert.deepEqual(waits.decide(far, 1, 10), { waitMs: false, spent: 0 });
	assert.match(far.errorMessage!, /later than pi² waits by itself \(8 days\)\. Continue the conversation to try again\.$/);
	assert.match(lines.at(-1)!, /^conversation 10 did not wait: /);

	// Six hours without a named time, and the run ends.
	now = NOW;
	random = 1;
	let attempt = 1;
	let decision = waits.decide(message(refused), attempt, 11);
	while (decision.waitMs !== false) {
		now += decision.waitMs!;
		decision = waits.decide(message(refused), ++attempt, 11);
	}
	assert.equal(now - NOW, DEFAULTS.maxWaitMs, "the last wait ends at the six hours");
	assert.match(lines.at(-1)!, /^conversation 11 gave up waiting: pi² waited 6 h for Anthropic's rate limit, the longest it waits by itself when the provider names no time; the run ends$/);
	assert.equal(waits.get(11), undefined);

	// A wait noted for a later attempt than the one asked about belongs to an earlier request: it is let go.
	waits.decide(message(refused), 3, 12);
	assert.deepEqual(waits.decide(message(refused), 1, 12).spent, 1);
	// A run that ends while waiting (Stop) lets its wait go.
	waits.working(new Set([5]));
	assert.equal(waits.get(12), undefined);
	assert.match(lines.at(-1)!, /^conversation 12 stopped waiting for Anthropic's rate limit: the run ended \(stopped\) after 0 s$/);
	// A run found sleeping after a restart with no wait noted gets one from its sleep; one that is not a limit does not.
	now = NOW;
	waits.adopt(13, { at: NOW + 60_000, error: refused }, "anthropic");
	assert.deepEqual({ ...waits.get(13), since: undefined }, { kind: "rate_limit", since: undefined, until: NOW + 60_000, told: false, refusals: 1, attempt: 0, provider: "anthropic", providerName: "Anthropic" });
	assert.match(lines.at(-1)!, /^conversation 13 is waiting for a limit, as before the engine stopped: until /);
	waits.adopt(14, { at: NOW + 60_000, error: "500 Internal server error" }, "anthropic");
	assert.equal(waits.get(14), undefined);
	assert.equal(waits.decide(message(refused), 2, 13).spent, 2, "the next refusal carries on the adopted wait");
	assert.equal(duration(3 * 24 * 3_600_000), "3 days");
	step("how long a run waits: the time named, or a backoff with jitter to 10 minutes, for at most 6 hours; other errors are left alone");
}

// ---- A provider's limit reached, and work carrying on: told once each, per provider
{
	let now = NOW;
	const lines: string[] = [];
	const told: EpisodeChange[] = [];
	const saved: Record<string, Wait> = {};
	const callbacks = {
		now: () => now,
		random: () => 0,
		providerName: (id: string) => (id === "anthropic" ? "Anthropic" : id),
		changed: (id: number, wait: Wait | undefined) => {
			if (wait === undefined) delete saved[String(id)];
			else saved[String(id)] = wait;
		},
		log: (line: string) => lines.push(line),
		episode: (change: EpisodeChange) => told.push(change),
	};
	const waits = new Waits(DEFAULTS, callbacks);
	const hour = "You have hit your usage limit. Try again in ~60 min.";
	// A short limit, with no time named, is no news: its wait is seconds.
	waits.decide(message("429 Too Many Requests", "openai-codex"), 1, 30);
	assert.equal(told.length, 0, "a wait of seconds is not a limit reached");
	// An hour named: reached at once, with who waits and until when.
	waits.decide(message(hour), 1, 21);
	assert.equal(told.length, 1);
	assert.equal(told[0]!.phase, "reached");
	assert.deepEqual({ ...told[0]!.episode }, { provider: "anthropic", providerName: "Anthropic", since: NOW, until: NOW + 3_600_000, told: true, waiting: [21], runs: [21] });
	// Another run joins it: told again, so the count stays true; refused again for the same time, not.
	now += 1000;
	waits.decide(message(hour), 1, 22);
	assert.equal(told.length, 2);
	assert.deepEqual(told[1]!.episode.waiting, [21, 22]);
	waits.decide(message(hour), 2, 22);
	assert.equal(told.length, 2, "a refusal that changes nothing told is not told");
	assert.deepEqual(waits.episode("anthropic")?.waiting, [21, 22]);
	assert.equal(waits.episode("openai-codex"), undefined);
	// The provider answers one of them: work carries on, once, for both; the other, still asleep, is no new episode.
	now += 3_600_000;
	waits.answered(21);
	assert.equal(told.length, 3);
	assert.equal(told[2]!.phase, "carried_on");
	assert.deepEqual(told[2]!.episode.runs, [21, 22]);
	waits.answered(22);
	assert.equal(told.length, 3, "the second run carrying on is the same news");
	assert.equal(waits.episode("anthropic"), undefined);
	// Reached again, then every run that waits is stopped: nothing waits any more.
	waits.decide(message(hour), 1, 23);
	assert.equal(told.at(-1)!.phase, "reached");
	waits.working(new Set());
	assert.equal(told.at(-1)!.phase, "ended");
	assert.deepEqual(told.at(-1)!.episode.runs, [23]);
	// A backoff counts once it has grown to five minutes from the first refusal.
	const before = told.length;
	let attempt = 1;
	waits.decide(message("429 Too Many Requests", "openai-codex"), attempt, 31);
	while (told.length === before && attempt < 20) waits.decide(message("429 Too Many Requests", "openai-codex"), ++attempt, 31);
	assert.equal(attempt, 7, "the seventh refusal, whose wait is five minutes");
	assert.equal(told.at(-1)!.phase, "reached");
	assert.equal(told.at(-1)!.episode.told, false);
	assert.ok(told.at(-1)!.episode.until - told.at(-1)!.episode.since >= DEFAULTS.reachedAfterMs);
	waits.working(new Set());
	// After a restart: the episode the saved waits were in is known, not told again, and its end is told.
	waits.decide(message(hour), 1, 24);
	const count = told.length;
	const again = new Waits(DEFAULTS, callbacks, JSON.parse(JSON.stringify(saved)));
	assert.deepEqual(again.episode("anthropic")?.waiting, [24]);
	assert.equal(told.length, count);
	again.answered(24);
	assert.equal(told.at(-1)!.phase, "carried_on");
	step("a provider's limit counts as reached once a run waits five minutes for it, and its end is told once: carried on, or nothing waits");
}

// ---- A window one conversation learned, which the other conversations on the provider wait for (#556)
{
	const lines: string[] = [];
	const shown: Wait[] = [];
	// A hold sleeps with a timer that does not keep a process alive by itself, as the engine's must not; this keeps one.
	const awake = setInterval(() => {}, 250);
	const waits = new Waits({ ...DEFAULTS, rememberAtLeastMs: 50 }, {
		now: Date.now,
		random: () => 0,
		providerName: (id) => (id === "anthropic" ? "Anthropic" : id),
		changed: (_id, wait) => {
			if (wait !== undefined) shown.push(wait);
		},
		log: (line) => lines.push(line),
	});
	/** A refusal that names a reset this far off. */
	const windowed = (seconds: number) => `429 This request would exceed your account's rate limit. It resets in ${seconds} s.`;
	// A time a moment off is the conversation's own business; a longer one is remembered for the provider.
	waits.decide(message(windowed(0)), 1, 40);
	assert.equal(waits.remembered("anthropic"), undefined, "a moment off is not worth the others waiting for");
	waits.decide(message(windowed(1)), 1, 41);
	const until = waits.remembered("anthropic")?.until;
	assert.equal(typeof until, "number");
	assert.ok(lines.some((line) => /^conversation 41 was told Anthropic's limit is used up until .*Z: the other conversations on Anthropic wait for that time rather than ask$/.test(line)), lines.join("\n"));

	// A second conversation waits without asking, shown as a wait for a limit.
	const second = waits.gate(42, "anthropic");
	assert.equal(waits.get(42)?.held, true);
	assert.equal(waits.get(42)?.until, until);
	assert.equal(shown.at(-1)?.held, true, "the app is shown it as a wait");
	assert.match(lines.at(-1)!, /^conversation 42 waits for Anthropic's rate limit until .*Z, the time conversation 41 was told, without asking$/);
	// When the time comes one request goes, and a third conversation waits for its answer.
	await second;
	assert.equal(waits.get(42), undefined, "the hold ends with its request going");
	assert.match(lines.at(-1)!, /^conversation 42 stopped waiting for Anthropic's rate limit: the time it named has come, and its request goes now$/);
	const third = waits.gate(43, "anthropic");
	assert.equal(waits.get(43)?.held, true, "held behind the one let through");
	await new Promise((resolve) => setTimeout(resolve, 20));
	assert.equal(waits.get(43)?.held, true, "and still held until that one is answered");
	// The provider answers the one let through: its window is over for every conversation.
	waits.answered(42, "anthropic");
	await third;
	assert.equal(waits.get(43), undefined);
	assert.equal(waits.remembered("anthropic"), undefined);
	assert.match(lines.at(-1)!, /^conversation 43 stopped waiting for Anthropic's rate limit: nothing is known of its limit any more$/);

	// A request the person asked for by hand goes at once, and its answer ends the window for all.
	waits.decide(message(windowed(2)), 1, 44);
	assert.equal(typeof waits.remembered("anthropic")?.until, "number");
	const behind = waits.gate(45, "anthropic");
	assert.equal(waits.get(45)?.held, true);
	// A message to a conversation nobody stopped does not ask for its request now: it is held as any other.
	waits.ask(47);
	const alsoHeld = waits.gate(47, "anthropic");
	assert.equal(waits.get(47)?.held, true);
	waits.stopped(46);
	waits.ask(46);
	const started = Date.now();
	await waits.gate(46, "anthropic");
	assert.ok(Date.now() - started < 1000, "sent at once, not held");
	assert.equal(waits.get(46), undefined);
	assert.match(lines.at(-1)!, /^conversation 46 asks Anthropic now, as the person asked it to, rather than waiting until /);
	waits.answered(46, "anthropic");
	await behind;
	await alsoHeld;
	assert.equal(waits.remembered("anthropic"), undefined);
	assert.equal(waits.get(45), undefined);
	assert.equal(waits.get(47), undefined);

	// A provider that named no time: nothing is remembered, so a conversation asks as it does now.
	const plain = new Waits({ ...DEFAULTS, rememberAtLeastMs: 50 }, { now: Date.now, random: () => 0, providerName: (id) => id, changed: () => {}, log: () => {} });
	plain.decide(message("429 rate_limit_error: slow down"), 1, 49);
	assert.equal(plain.remembered("anthropic"), undefined);
	await plain.gate(48, "anthropic");
	assert.equal(plain.get(48), undefined, "no wait placed");
	// What a delegating agent is told of it, in the kind of line a subscription gets (#232).
	assert.equal(usedUpUntil(undefined, NOW), undefined);
	assert.match(
		usedUpUntil({ provider: "p", providerName: "OpenCode Go", from: 1, until: NOW + (2 * 60 + 17) * 60_000 }, NOW)!,
		/^Plan limits: OpenCode Go's limit is used up until \d\d:\d\d \(in 2 h 17 min\), as its refusal said\. A run the provider refuses for its limit waits for the reset and carries on by itself\.$/,
	);
	clearInterval(awake);
	step("a window one conversation was told of: the others wait for that time without asking, one request goes at the time, and an answer ends it for all");
}

// ---- What an agent and engine.log are told of a provider's error
{
	assert.equal(
		plainProviderError('429 {"type":"error","error":{"type":"rate_limit_error","message":"This request would exceed your account\'s rate limit. Please try again later."},"request_id":"req_011CVabcdefghijk"}'),
		"429 rate_limit_error: This request would exceed your account's rate limit. Please try again later.",
	);
	assert.equal(plainProviderError('401 {"error":{"message":"Incorrect API key provided: sk-proj-abcdefghijklmnop1234","code":"invalid_api_key"}}'), "401 invalid_api_key: Incorrect API key provided: [key]");
	assert.equal(
		plainProviderError("Rate limit reached for org-AbCdEf123456 in project proj_Zyx987654321 for user someone@example.com, request req_abcdef123456, account 3f2b1c4d-1a2b-4c3d-8e9f-0a1b2c3d4e5f, token Bearer abc.def.ghi"),
		"Rate limit reached for [id] in project [id] for user [email], request [request], account [id], token Bearer [hidden]",
	);
	assert.equal(plainProviderError(`x${"y".repeat(400)}`).length, 300);
	assert.ok(plainProviderError(`x${"y".repeat(400)}`).endsWith("…"));
	// pi²'s own words after the provider's, when it stopped waiting for a limit, are kept whole.
	const gaveUp = `429 ${"Too many requests. ".repeat(30)}\n\npi² waited 6 h for Anthropic's rate limit, the longest it waits by itself when the provider names no time. ${CARRY_ON}`;
	assert.match(plainProviderError(gaveUp), /^429 Too many requests\..*… pi² waited 6 h for Anthropic's rate limit, the longest it waits by itself when the provider names no time\. Continue the conversation to try again\.$/);
	step("a provider's error is shortened, and keys, accounts, request ids and addresses are taken out of it");

	assert.equal(
		unfinished("Scout", 12, "model_error", '401 {"error":{"type":"authentication_error","message":"invalid x-api-key"}}'),
		"Scout did not finish the task: the model's provider answered with an error: “401 authentication_error: invalid x-api-key”. The sub-chat is kept as it stopped: to carry on from there, call delegate again with chat: 12.",
	);
	assert.match(unfinished("Scout", 12, "model_error", "429 Too Many Requests"), /”\. The provider refused it for its limit, so carrying on works once the limit has reset\. The sub-chat is kept/);
	assert.doesNotMatch(unfinished("Scout", 12, "model_error", gaveUp), /once the limit has reset/, "pi² said why itself");
	assert.equal(unfinished("Scout", 12, "aborted", undefined), "Scout did not finish the task: its run was stopped, by the person or with this conversation. The sub-chat is kept as it stopped: to carry on from there, call delegate again with chat: 12.");
	assert.equal(unfinished("Scout", 12, "turn_limit", undefined), "Scout did not finish the task (turn_limit). The sub-chat is kept as it stopped: to carry on from there, call delegate again with chat: 12.");
	step("delegate's result for a sub-chat that ended on an error says why, in the provider's words, and how to carry on");
}

// ---- A real engine, and a stand-in provider that refuses and then answers

const home = mkdtempSync(join(tmpdir(), "pi2-limit-"));
const KEYCHAIN_SERVICE = `dev.pi2.credentials.test-limitwait-${process.pid}`;
process.on("exit", () => {
	rmSync(home, { recursive: true, force: true });
	// The endpoint has no key, so nothing should be there; make sure.
	for (let i = 0; i < 100; i++) {
		try {
			execFileSync("/usr/bin/security", ["delete-generic-password", "-s", KEYCHAIN_SERVICE], { stdio: "ignore" });
		} catch {
			break;
		}
	}
});

type Refuse = { status: number; headers?: Record<string, string>; body: string };
const RATE_LIMITED: Refuse = { status: 429, body: JSON.stringify({ error: { type: "rate_limit_error", message: "This request would exceed your account's rate limit. Please try again later." } }) };
const OVERLOADED: Refuse = { status: 529, body: JSON.stringify({ error: { type: "overloaded_error", message: "Overloaded" } }) };
const BAD_KEY: Refuse = { status: 401, body: JSON.stringify({ error: { type: "authentication_error", message: "invalid x-api-key" } }) };
/** What the stand-in answers each request for a prompt: a refusal, or (past the list) an answer. */
const scripts: Record<string, Refuse[]> = {
	"six refusals": Array(6).fill(RATE_LIMITED),
	"told when": [
		{ ...RATE_LIMITED, headers: { "retry-after-ms": "5" } },
		{ ...RATE_LIMITED, headers: { "retry-after": "0" } },
	],
	overloaded: [OVERLOADED, OVERLOADED, OVERLOADED, OVERLOADED, OVERLOADED],
	// Refused until a message from the person comes with it; at most 50 times, so that without it the run still ends.
	"a message meanwhile": Array(50).fill({ ...RATE_LIMITED, headers: { "retry-after-ms": "300" } }),
	// A window one conversation is told of, which the others on the provider wait for (#556).
	window: [{ ...RATE_LIMITED, headers: { "retry-after-ms": "1500" } }],
	"window later": [{ ...RATE_LIMITED, headers: { "retry-after-ms": "2500" } }],
	"window again": [{ ...RATE_LIMITED, headers: { "retry-after-ms": "2500" } }],
	"window told": [{ ...RATE_LIMITED, headers: { "retry-after-ms": "4000" } }],
	"window carried": [{ ...RATE_LIMITED, headers: { "retry-after-ms": "2500" } }],
	"window never named": [RATE_LIMITED],
	"bad key": Array(100).fill(BAD_KEY),
	"an hour": Array(100).fill({ ...RATE_LIMITED, headers: { "retry-after": "3600" } }),
	"switch this run": [{ ...RATE_LIMITED, headers: { "retry-after": "3600" } }],
	"waiting child one": [{ ...RATE_LIMITED, headers: { "retry-after": "3600" } }],
	"waiting child two": [{ ...RATE_LIMITED, headers: { "retry-after": "3600" } }],
	"billing only": [{ status: 429, body: '{"error":{"type":"insufficient_quota","message":"Your credit balance is too low"}}' }],
	"never answers": Array(1000).fill(RATE_LIMITED),
	"network words in HTTP": [{ status: 400, body: '{"error":{"message":"Connection error.: getaddrinfo ENOTFOUND example.invalid"}}' }],
	"network then limit": [RATE_LIMITED, RATE_LIMITED],
};
const requests: Record<string, number> = {};
/** The person's messages in the last request for each prompt, by its last message. */
const seen: Record<string, string[]> = {};
/** While true, a request for "held" is refused, naming a time a moment off; then it is answered. */
let holding = true;
/** When each prompt's request came, and when its answer was written: for what waits behind another (#556). */
const came: Record<string, number> = {};
const after: Record<string, number> = {};
let networkDown = true;
const wire: Record<string, string> = {};
const standIn = createServer((request, response) => {
	if (request.method === "GET" && request.url === "/v1/models") {
		response.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({ object: "list", data: [{ id: "stand-in", object: "model" }] }));
		return;
	}
	let body = "";
	request.setEncoding("utf8").on("data", (chunk: string) => (body += chunk));
	request.on("end", () => {
		const users = (JSON.parse(body).messages as { role: string; content: unknown }[]).filter((m) => m.role === "user");
		const last = users.at(-1)?.content;
		const prompt = typeof last === "string" ? last : (last as { text?: string }[]).map((part) => part.text ?? "").join("");
		const n = requests[prompt] ?? 0;
		requests[prompt] = n + 1;
		came[prompt] = Date.now();
		seen[prompt] = users.map((m) => (typeof m.content === "string" ? m.content : (m.content as { text?: string }[]).map((part) => part.text ?? "").join("")));
		wire[prompt] = body;
		const parentJob = prompt === "network parent";
		const firstParentRequest = parentJob && n === 0;
		const drops = prompt === "network once" || prompt === "network then limit" ? 1 : prompt === "network repeatedly" ? 8 : 0;
		if (n < drops || prompt === "network steering" || prompt === "network never" || prompt === "network stop" || (networkDown && (prompt === "network child" || (parentJob && !firstParentRequest)))) {
			request.socket.destroy();
			return;
		}
		const refusal = prompt === "held" && holding ? { ...RATE_LIMITED, headers: { "retry-after-ms": "200" } } : scripts[prompt]?.[n];
		if (refusal !== undefined) {
			response.writeHead(refusal.status, { "content-type": "application/json", ...refusal.headers }).end(refusal.body);
			return;
		}
		const reply = () => {
			after[prompt] = Date.now();
			response.writeHead(200, { "content-type": "text/event-stream" });
			const chunk = (delta: object, finish: string | null) =>
				response.write(`data: ${JSON.stringify({ id: "c1", object: "chat.completion.chunk", created: 1, model: "stand-in", choices: [{ index: 0, delta, finish_reason: finish }] })}\n\n`);
			if (firstParentRequest) {
				chunk({ role: "assistant", tool_calls: [{ index: 0, id: "delegate-network", type: "function", function: { name: "delegate", arguments: JSON.stringify({ agent: "Scout", task: "network child", wait: false }) } }] }, null);
				chunk({}, "tool_calls");
			} else {
				if (prompt === "stream closed before answer" && n === 0) {
					// The headers arrive and the stream ends before any of the answer: what an HTTP/2 ENHANCE_YOUR_CALM looks
					// like from here, whose code an HTTP/1.1 connection cannot send (#550).
					response.write(": streamed\n\n", () => request.socket.destroy());
					return;
				}
				chunk({ role: "assistant", content: `Answered after ${n} refusals.` }, null);
				if (prompt === "stream cut off" && n === 0) {
					// Drop the socket only after headers and a piece of the answer have been sent.
					response.write(": streamed\n\n", () => request.socket.destroy());
					return;
				}
				chunk({}, "stop");
			}
			response.end("data: [DONE]\n\n");
		};
		// Two conversations behind one window: the answer is held back a moment, so that the one waiting behind it is seen
		// to wait, rather than send at the same moment (#556).
		if (prompt === "window slow" || prompt === "window third") setTimeout(reply, 150);
		else reply();
	});
});
await new Promise<void>((resolve) => standIn.listen(0, "127.0.0.1", resolve));
const standInUrl = `http://127.0.0.1:${(standIn.address() as { port: number }).port}/v1`;

let log = "";
function startEngine(extra: Record<string, string> = {}): ChildProcess {
	const child = spawn(process.execPath, [join(import.meta.dirname, "..", "src", "main.ts")], {
		env: { ...process.env, PI2_HOME: home, PI2_KEYCHAIN_SERVICE: KEYCHAIN_SERVICE, PI2_LOGIN_SHELL: "off", PI2_LIMIT_BACKOFF_MS: "20", PI2_NETWORK_WAIT_SCALE: "0.02", ...extra },
		stdio: ["ignore", "ignore", "pipe"],
	});
	child.stderr!.setEncoding("utf8").on("data", (chunk: string) => {
		log += chunk;
		process.stderr.write(chunk);
	});
	return child;
}

type Item = { kind: string; text: string; stop?: string; error?: string | null };
/**
 * The check that the engine logged a line, held until it arrives. The engine writes to its standard error and this test
 * reads the pipe, so a line can reach us after the socket event that came after it: reading `log` once then misses it,
 * which is what failed in CI (#588). The limit is patience.ts's guard against a hang, not a longer wait.
 */
async function logSays(what: string, line: RegExp): Promise<void> {
	await until(`the engine's log to say ${what}`, () => (line.test(log) ? true : undefined));
}

type Model = { provider: string; modelId: string };
type Shown = { kind: string; since: number; until: number; told: boolean; refusals: number; provider: string; model: Model | null };
type State = {
	busy: boolean;
	agent: { model: Model };
	failure: { reason: string; detail: string | null } | null;
	retry: { at: number; error: string; network?: boolean; closed?: boolean } | null;
	limitWait: Shown | null;
	messageWaits?: { holds: string[]; ends: string[]; retryAt?: number } | null;
};
class Client extends EngineClient {
	override conversations = new Map<number, { items: Item[]; state: State }>();
	activity: { conversationId: number; parent: number | null; status: string; limit: Shown | null }[] = [];
	models: { provider: string; id: string }[] = [];
	notices: { id: string; name: string; stage?: string; waiting?: number; until?: number; told?: boolean; runs: { conversationId: number; subChat: boolean }[] }[] = [];
	/** Whether `notices` is the engine's yet: it sends them as a client connects, and an empty list before then says nothing. */
	noticesSent = false;
	networkSleeps = new Map<number, Set<number>>();
	/** The sleeps of a run waiting for a stream the provider closed (#550), which are network sleeps too. */
	closedSleeps = new Map<number, Set<number>>();
	override receive(message: any): void {
		if (message.event === "conversation" && message.state.retry?.network === true) {
			const sleeps = this.networkSleeps.get(message.id) ?? new Set<number>();
			sleeps.add(message.state.retry.at);
			this.networkSleeps.set(message.id, sleeps);
			assert.equal(message.state.limitWait, null);
			if (message.state.retry.closed === true) {
				const closed = this.closedSleeps.get(message.id) ?? new Set<number>();
				closed.add(message.state.retry.at);
				this.closedSleeps.set(message.id, closed);
			}
		}
		if (message.event === "activity") this.activity = message.runs;
		else if (message.event === "limits") {
			this.notices = message.notices;
			this.noticesSent = true;
		}
		else if (message.event === "providers") this.models = message.models;
		else super.receive(message);
	}
	/** A new conversation on the stand-in, sent `prompt`. */
	async ask(provider: string, prompt: string, chat = false): Promise<number> {
		const { id } = await this.call("conversation.create", { ...(chat ? { chat } : {}), model: { provider, modelId: "stand-in" } });
		await this.call("conversation.open", { id });
		await this.call("submit", { id, text: prompt });
		return id;
	}
	/** The conversation once its run has ended, answered or not. */
	ended(id: number): Promise<{ items: Item[]; state: State }> {
		return this.until(`conversation ${id} ended`, () => {
			const conv = this.conversations.get(id);
			return conv !== undefined && !conv.state.busy && conv.items.some((i) => i.kind === "user") && (conv.state.failure !== null || conv.items.some((i) => i.kind === "assistant" && i.stop === "stop")) ? conv : undefined;
		});
	}
}

const answer = (conv: { items: Item[] }) => conv.items.filter((i) => i.kind === "assistant" && i.stop === "stop").at(-1)?.text;

let engine = startEngine();
try {
	let client = await Client.connect(engine, home);
	const { id: provider } = await client.call("endpoints.save", { name: "Stand-in", baseUrl: standInUrl, api: "openai-completions", models: [{ id: "stand-in" }] });
	await client.until("stand-in offered", () => client.models.some((m) => m.provider === provider));

	// Six refusals with no time named: more than pi-durable's three retries, and the run still answers.
	const six = await client.ask(provider, "six refusals");
	let conv = await client.ended(six);
	assert.equal(conv.state.failure, null, "the run carried on");
	assert.equal(answer(conv), "Answered after 6 refusals.");
	assert.equal(requests["six refusals"], 7);
	await logSays("the run is waiting for a rate limit with no time named", new RegExp(`conversation ${six} is waiting for Stand-in's rate limit: no time named`));
	await client.until("the wait's end logged", () => new RegExp(`conversation ${six} carries on: Stand-in answered after .* of waiting \\(6 refusals\\)`).test(log));
	step("a run refused six times for a rate limit, with no time named, waits and carries on by itself");

	// The provider says when: retry-after-ms, then retry-after: 0.
	const told = await client.ask(provider, "told when");
	conv = await client.ended(told);
	assert.equal(conv.state.failure, null);
	assert.equal(answer(conv), "Answered after 2 refusals.");
	await logSays("the run waits for the time the provider named", new RegExp(`conversation ${told} is waiting for Stand-in's rate limit: until .*Z, the time it named`));
	step("a run waits for the time the provider names (retry-after-ms, retry-after) and carries on");

	// Overloaded (529), five times.
	const busy = await client.ask(provider, "overloaded");
	conv = await client.ended(busy);
	assert.equal(conv.state.failure, null);
	assert.equal(answer(conv), "Answered after 5 refusals.");
	await logSays("the run is waiting for an overloaded provider", new RegExp(`conversation ${busy} is waiting for Stand-in being overloaded`));
	step("a run that meets an overloaded provider (529) waits and carries on");

	// A message sent to steer while the run waits for a limit (#324): it does not end the wait, and it is placed as the
	// wait ends, so the next request carries it, rather than after an answer to the conversation as it was.
	const steered = await client.ask(provider, "a message meanwhile");
	await client.until("the wait shown", () => client.conversations.get(steered)?.state.limitWait ?? undefined);
	const waits = await client.until("what a message would wait for", () => client.conversations.get(steered)?.state.messageWaits ?? undefined);
	assert.equal(typeof waits.retryAt, "number", "the field can say the message waits for the next request");
	await client.call("submit", { id: steered, text: "Also mention the tests.", mode: "steer" });
	conv = await client.ended(steered);
	assert.equal(conv.state.failure, null);
	assert.equal(answer(conv), "Answered after 0 refusals.", "answered on the first request that carried the message");
	assert.deepEqual(seen["Also mention the tests."], ["a message meanwhile", "Also mention the tests."], "that request had both");
	assert.ok(requests["a message meanwhile"]! < 50, "not after the refusals ran out");
	step("a message sent while a run waits for a limit is kept, and carried by the first request after the wait");

	// A bad key ends the run at once, after one request, as before.
	const bad = await client.ask(provider, "bad key");
	conv = await client.ended(bad);
	assert.equal(conv.state.failure?.reason, "model_error");
	assert.match(conv.state.failure!.detail!, /invalid x-api-key/);
	assert.equal(requests["bad key"], 1, "not retried");
	assert.doesNotMatch(log, new RegExp(`conversation ${bad} is waiting`));
	await client.until("the error logged", () => new RegExp(`conversation ${bad}'s run ended on an error from Stand-in: .*invalid x-api-key`).test(log));
	step("an error that is not a limit (a bad key) still ends the run at once, and engine.log says so");

	// A sub-chat whose run ends on the provider's error: delegate's result says why, and how to carry on.
	await client.call("agents.save", { agent: { id: "scout", name: "Scout", model: { provider, modelId: "stand-in" } } });
	const { id: lead } = await client.call("conversation.create", { agentId: "atlas", model: { provider: "demo", modelId: "demo-1" } });
	await client.call("conversation.open", { id: lead });
	await client.call("submit", { id: lead, text: "/delegate Scout: bad key" });
	const handed = await client.until("delegate's result", () => client.conversations.get(lead)?.items.find((i) => i.kind === "tool"));
	const [failure, usage] = handed.text.split("\n\n");
	const said = /^Scout did not finish the task: the model's provider answered with an error: “(.*invalid x-api-key.*)”\. The sub-chat is kept as it stopped: to carry on from there, call delegate again with chat: (\d+)\.$/.exec(failure!);
	assert.ok(said !== null, handed.text);
	assert.match(usage ?? "", /^Used: 1 request(?: over [^;\n]+)?\.$/, "the failed request has no reported tokens");
	const sub = Number(said[2]);
	await client.until("the sub-chat's error logged", () => new RegExp(`conversation ${sub}'s run ended on an error from Stand-in: .*invalid x-api-key`).test(log));
	// Continued, and refused again: the same.
	await client.until("the lead idle", () => !client.conversations.get(lead)!.state.busy);
	await client.call("submit", { id: lead, text: `/continue ${sub}: bad key` });
	const again = await client.until("the continued delegate's result", () => client.conversations.get(lead)!.items.filter((i) => i.kind === "tool")[1]);
	const [failedAgain, usedAgain] = again.text.split("\n\n");
	assert.equal(failedAgain, failure);
	assert.match(usedAgain ?? "", /^Used: 2 requests(?: over [^;\n]+)?\.$/);
	step("a sub-chat that ends on a provider's error: delegate says why and how to carry on, and engine.log names the sub-chat");

	// An hour named: the wait shows in the conversation and in Activity, with its time.
	const before = Date.now();
	const hour = await client.ask(provider, "an hour");
	const waiting = await client.until("the wait shown", () => client.conversations.get(hour)?.state.limitWait ?? undefined);
	assert.equal(waiting.kind, "rate_limit");
	assert.equal(waiting.told, true);
	assert.equal(waiting.provider, "Stand-in");
	assert.ok(waiting.until >= before + 3600_000 && waiting.until <= Date.now() + 3630_000, "an hour, and at most 30 seconds more");
	assert.equal(client.conversations.get(hour)!.state.busy, true, "the run is still going");
	assert.equal(client.conversations.get(hour)!.state.retry?.at, waiting.until);
	const row = await client.until("Activity shows the wait", () => client.activity.find((run) => run.conversationId === hour && run.limit !== null));
	assert.ok(Math.abs(row.limit!.until - waiting.until) < 1000, "the same time, give or take the moment between deciding and sleeping");
	step("a wait shows in the conversation and in Activity, with the time it waits until");

	// It survives a restart: killed in the middle of the wait, the next engine still waits, until the same time.
	await stop(engine, "SIGKILL");
	engine = startEngine();
	client = await Client.connect(engine, home);
	await client.call("conversation.open", { id: hour });
	const resumed = await client.until("the wait shown after a restart", () => client.conversations.get(hour)?.state.limitWait ?? undefined);
	assert.equal(resumed.until, waiting.until);
	assert.equal(requests["an hour"], 1, "nothing was asked again meanwhile");
	await client.until("Activity shows it after the restart", () => client.activity.find((run) => run.conversationId === hour && run.limit?.until === row.limit!.until));
	step("a wait survives the engine being killed, and goes on until the same time");

	// Stop ends it, as any run.
	await client.call("abort", { id: hour });
	conv = await client.until("stopped", () => {
		const c = client.conversations.get(hour);
		return c !== undefined && !c.state.busy && c.state.failure !== null ? c : undefined;
	});
	assert.equal(conv.state.failure!.reason, "aborted");
	assert.equal(conv.state.limitWait, null);
	await client.until("the stop logged", () => new RegExp(`conversation ${hour} stopped waiting for Stand-in's rate limit: the run ended \\(stopped\\)`).test(log));
	await client.until("Activity no longer shows it", () => !client.activity.some((run) => run.conversationId === hour));
	await client.until("its notice out of the Inbox", () => (client.noticesSent && client.notices.length === 0) || undefined);
	step("Stop ends a run that waits for a limit, and takes its notice out of the Inbox");

	// A provider's limit reached, for a sub-chat handed work without waiting: the Inbox has a notice, sub_chats' list says
	// it waits and until when, and when the provider answers again the notice says work carries on. Five minutes made
	// nothing, so a refusal naming a moment counts.
	await stop(engine);
	// A reset an hour off is not remembered here, so that these runs are refused and wait, as the checks below expect: a
	// window another conversation learned holds its conversations instead (#556).
	engine = startEngine({ PI2_LIMIT_REACHED_MS: "0", PI2_LIMIT_REMEMBER_MS: "7200000" });
	client = await Client.connect(engine, home);
	// The engine was stopped at once after Stop took the notice out, well within the second limits.json waits before it
	// is saved. A clean stop saves it then, so the notice stays out; before #638 the next engine brought back the notice
	// as last saved, still at "reached" for that earlier run, which the checks below then took for the sub-chat's.
	await client.until("the Inbox's notices as the engine starts", () => client.noticesSent || undefined);
	assert.equal(client.notices.length, 0, `a notice taken out just before a clean stop stays out after it: ${JSON.stringify(client.notices)}`);
	await client.until("stand-in offered again", () => client.models.some((m) => m.provider === provider));
	const { id: parent } = await client.call("conversation.create", { agentId: "atlas", model: { provider: "demo", modelId: "demo-1" } });
	await client.call("conversation.open", { id: parent });
	await client.call("submit", { id: parent, text: '/tool delegate {"agent":"Scout","task":"held","wait":false}' });
	const reached = await client.until("the limit reached in the Inbox", () => client.notices.find((notice) => notice.stage === "reached"));
	assert.equal(reached.name, "Stand-in");
	assert.equal(reached.waiting, 1);
	assert.equal(reached.told, true);
	const held = reached.runs[0]!.conversationId;
	assert.equal(reached.runs[0]!.subChat, true);
	await client.until("Activity shows the sub-chat waiting", () => client.activity.find((run) => run.conversationId === held && run.limit !== null));
	await logSays("a limit is reached, and a notice is in the Inbox", /limits: Stand-in's limit is reached: 1 run \(conversation \d+\) waits until .*Z, the time it named; a notice is in the Inbox/);
	await client.until("the parent idle", () => client.conversations.get(parent)?.state.busy === false);
	await client.call("submit", { id: parent, text: '/tool sub_chats {"action":"list"}' });
	const listed = await client.until("sub_chats' list", () => client.conversations.get(parent)!.items.filter((i) => i.kind === "tool")[1]);
	assert.match(listed.text, new RegExp(`- ${held}: Scout, “.*”\\. Waiting for Stand-in's rate limit until \\d\\d:\\d\\d \\(in \\d+ s\\), the time Stand-in named; it carries on by itself then`));
	assert.equal(client.notices.filter((notice) => notice.stage === "reached").length, 1, "one notice, however many refusals");
	// The provider answers again.
	holding = false;
	const carried = await client.until("work carried on, in the Inbox", () => client.notices.find((notice) => notice.stage === "carried_on"));
	assert.equal(carried.id, reached.id, "the same notice, gone on to its next stage");
	assert.deepEqual(carried.runs.map((run) => run.conversationId), [held]);
	await logSays("the limit reset and the run carries on", /limits: Stand-in answered again after .*: its limit has reset, and the 1 run \(conversation \d+\) that waited carries on/);
	await client.call("limits.dismiss", { id: carried.id });
	await client.until("the notice dismissed", () => client.notices.length === 0 || undefined);
	step("a limit reached is one notice in the Inbox that goes on to say work carried on, and sub_chats' list says who waits until when");

	// Choosing another model advances the actual sleeping generation, not a replacement run. The queued steer goes on
	// the new model's first request and the original submission finishes. A billing refusal is not a wait.
	const demo = { provider: "demo", modelId: "demo-1" };
	const original = { provider, modelId: "stand-in" };
	const billing = await client.ask(provider, "billing only");
	assert.equal((await client.ended(billing)).state.limitWait, null);
	await assert.rejects(client.call("conversation.carryOn", { id: billing, since: Date.now(), model: demo }), /no run is still waiting/i);
	assert.equal(requests["billing only"], 1);
	const { id: single } = await client.call("conversation.create", { model: original });
	await client.call("conversation.open", { id: single });
	const { submissionId } = await client.call("submit", { id: single, text: "switch this run" });
	const singleWait = await client.until("the run waiting before choosing", () => client.conversations.get(single)?.state.limitWait ?? undefined);
	assert.deepEqual(singleWait.model, original);
	const select = (model: Model, since = singleWait.since) => client.call("conversation.carryOn", { id: single, since, model });
	await assert.rejects(select(original), /no run is still waiting/i);
	await assert.rejects(select({ provider: "demo", modelId: "missing" }), /model is not available/i);
	await assert.rejects(select(demo, singleWait.since - 1), /no run is still waiting/i);
	assert.equal(requests["switch this run"], 1);
	assert.deepEqual(client.conversations.get(single)!.state.agent.model, original);
	assert.equal(client.conversations.get(single)!.state.busy, true);
	await client.call("submit", { id: single, text: "/context", mode: "steer" });
	assert.deepEqual(await select(demo), { switched: [single] });
	conv = await client.ended(single);
	assert.equal(conv.state.failure, null);
	assert.deepEqual(conv.state.agent.model, demo);
	assert.equal(conv.state.limitWait, null);
	assert.equal(answer(conv), "CONTEXT\nswitch this run\n/context");
	assert.equal(requests["switch this run"], 1);
	assert.equal(requests["/context"], undefined, "queued steer went to the new model");
	assert.equal((await client.call("submission.get", { id: single, submissionId })).submission.status, "done");
	assert.match(conv.items.find((item) => item.kind === "marker" && item.text.startsWith("You changed the model"))!.text, /from stand-in \(Stand-in\) to Demo model \(scripted\) \(demo\) and carried on\./);
	await client.until("leaving the wait clears its notice", () => client.notices.length === 0 || undefined);
	assert.doesNotMatch(log, new RegExp(`conversation ${single} carries on: Stand-in answered`));
	await assert.rejects(select(demo), /no run is still waiting/i);
	step("a person's choice switches the same run and its queued steer to the new model, without claiming the old limit reset");

	// One choice at the parent changes both live, sleeping sub-chats, without interrupting either blocking delegate.
	const unrelated = await client.ask(provider, "an hour");
	await client.until("an unrelated wait", () => client.conversations.get(unrelated)?.state.limitWait ?? undefined);
	const { id: bulk } = await client.call("conversation.create", { agentId: "atlas", model: demo });
	await client.call("conversation.open", { id: bulk });
	const tools = ["waiting child one", "waiting child two", "non-waiting child"].map((task) => ({ name: "delegate", arguments: { agent: "Scout", task } }));
	await client.call("submit", { id: bulk, text: `/tools ${JSON.stringify(tools)}` });
	const children = await client.until("both children at the limit", () => {
		const ids = client.activity.filter((run) => run.parent === bulk && run.limit !== null).map((run) => run.conversationId);
		return ids.length === 2 ? ids : undefined;
	});
	for (const id of children) {
		await client.call("conversation.open", { id });
		await client.until(`sub-chat ${id} sleeping`, () => client.conversations.get(id)?.state.limitWait ?? undefined);
	}
	const bulkResult = await client.call("conversation.carryOn", { id: bulk, subChats: true, model: demo });
	assert.deepEqual(bulkResult.switched.sort(), [...children].sort());
	for (const id of children) {
		const child = await client.ended(id);
		assert.equal(child.state.failure, null);
		assert.deepEqual(child.state.agent.model, demo);
		assert.match(answer(child)!, /You said: "waiting child (one|two)"/);
	}
	const bulkEnd = await client.ended(bulk);
	assert.equal(bulkEnd.state.failure, null);
	assert.deepEqual(bulkEnd.state.agent.model, demo);
	assert.equal(bulkEnd.items.filter((item) => item.kind === "tool").length, 3);
	for (const task of ["waiting child one", "waiting child two"]) {
		assert.equal(requests[task], 1);
		assert.ok(bulkEnd.items.some((item) => item.kind === "tool" && item.text.includes(`You said: "${task}"`)));
	}
	assert.ok(bulkEnd.items.some((item) => item.kind === "tool" && item.text.includes("Answered after 0 refusals.")), "the non-waiting child answered on its original model");
	assert.match(bulkEnd.items.find((item) => item.kind === "marker" && item.text.startsWith("You changed the model"))!.text, /You changed the model for 2 sub-chats to .*#\d+: stand-in \(Stand-in\), #\d+: stand-in \(Stand-in\)/);
	assert.deepEqual(client.conversations.get(unrelated)!.state.agent.model, original);
	assert.notEqual(client.conversations.get(unrelated)!.state.limitWait, null);
	await client.call("abort", { id: unrelated });
	await client.call("conversation.configure", { id: single, model: original });
	await client.until("the toolbar can switch back", () => client.conversations.get(single)!.state.agent.model.provider === provider);
	step("one choice moves the waiting sub-chats, but not their parent, a non-waiting child, or an unrelated wait");

	// The longest wait without a named time, made a millisecond: the run ends, and says why.
	await stop(engine);
	engine = startEngine({ PI2_LIMIT_WAIT_MAX_MS: "1" });
	client = await Client.connect(engine, home);
	await client.until("stand-in offered again", () => client.models.some((m) => m.provider === provider));
	const never = await client.ask(provider, "never answers");
	conv = await client.ended(never);
	assert.equal(conv.state.failure?.reason, "model_error");
	assert.match(conv.state.failure!.detail!, /the longest it waits by itself when the provider names no time\. Continue the conversation to try again\.$/);
	assert.equal(requests["never answers"], 2, "asked once more, then gave up");
	await client.until("giving up logged", () => new RegExp(`conversation ${never} gave up waiting: pi² waited .* for Stand-in's rate limit`).test(log));
	step("a run that has waited as long as it waits by itself ends, and its error says why and how to carry on");
	// A connection closed before even the headers. The next request gets the queued steer, not a failed assistant entry.
	const networkSteer = await client.ask(provider, "network steering");
	await client.until("network sleep began", () => client.networkSleeps.has(networkSteer));
	await client.call("submit", { id: networkSteer, text: "Steer after the outage", mode: "steer" });
	// A connection the stand-in ends is one the provider closed, and the conversation says so (#550); the network being
	// away has a line of its own, which a socket reset no longer uses.
	const carriedOn = (c: { items: Item[] }) => c.items.filter((i) => i.kind === "marker" && /^The (?:network is back|provider answered again)\. Carried on after waiting \d+ s\.$/.test(i.text));
	const answeredAgain = (c: { items: Item[] }) => carriedOn(c).filter((i) => i.text.startsWith("The provider answered again."));
	for (const [prompt, n] of [["network once", 1], ["network repeatedly", 8], ["network then limit", 2]] as const) {
		const id = await client.ask(provider, prompt, prompt === "network once");
		conv = await client.ended(id);
		assert.equal(conv.state.failure, null);
		assert.equal(answer(conv), `Answered after ${n} refusals.`);
		assert.equal(carriedOn(conv).length, 1);
		assert.equal(answeredAgain(conv).length, 1);
		assert.ok(client.closedSleeps.has(id));
		assert.equal(conv.items.filter((i) => i.stop === "error").length, prompt === "network then limit" ? 1 : 0);
		assert.ok(client.networkSleeps.has(id));
		assert.doesNotMatch(wire[prompt]!, /getaddrinfo|No network just now|The provider answered again|Carried on after waiting/);
	}
	assert.deepEqual(seen["Steer after the outage"], ["network steering", "Steer after the outage"]);
	assert.equal(carriedOn(await client.ended(networkSteer)).length, 1);
	step("a connection closed before its answer, a scaled multi-minute one, steering, and a 429 after one all carry on");

	// A connection the provider ends part way through an answer is waited out and asked again whole (#550).
	for (const prompt of ["stream cut off", "stream closed before answer"]) {
		const id = await client.ask(provider, prompt);
		conv = await client.ended(id);
		assert.equal(conv.state.failure, null, "the run carried on");
		assert.equal(answer(conv), "Answered after 1 refusals.");
		assert.equal(requests[prompt], 2, "the whole request was asked again");
		assert.ok(client.closedSleeps.has(id));
		assert.equal(conv.items.filter((i) => i.kind === "assistant" && i.stop === "error").length, 0, "the failed attempt is not kept");
		assert.ok(!conv.items.some((i) => i.text.includes("Answered after 0 refusals.")), "the part of the answer is not kept twice");
		assert.match(answeredAgain(conv)[0]!.text, /^The provider answered again\. Carried on after waiting \d+ s\.$/);
	}
	step("a stream the provider closes before or during its answer is waited out and asked again whole, and the conversation says so");

	const id = await client.ask(provider, "network words in HTTP");
	conv = await client.ended(id);
	assert.ok(!client.networkSleeps.has(id));
	assert.ok(!client.closedSleeps.has(id));
	assert.ok(conv.items.some((i) => i.stop === "error"));
	assert.equal(carriedOn(conv).length, 0);
	step("an HTTP refusal naming connection errors is not waited for, whatever its words");

	const parentTogether = await client.ask(provider, "network parent");
	const child = await client.until("the child running", () => client.activity.find((r) => r.parent === parentTogether)?.conversationId);
	await client.call("conversation.open", { id: child });
	await client.until("parent and child have both waited for the network", () => client.networkSleeps.has(parentTogether) && client.networkSleeps.has(child));
	networkDown = false;
	for (const id of [parentTogether, child]) {
		conv = await client.ended(id);
		assert.equal(conv.state.failure, null);
		assert.equal(carriedOn(conv).length, 1);
	}
	assert.doesNotMatch(wire["network parent"]!, /No network just now|The provider answered again|Carried on after waiting/);
	step("parent and sub-chat can both wait and recover from the same outage");

	await stop(engine);
	engine = startEngine({ PI2_NETWORK_WAIT_SCALE: "0.002" });
	client = await Client.connect(engine, home);
	await client.until("stand-in offered again", () => client.models.some((m) => m.provider === provider));
	const { id: failedParent } = await client.call("conversation.create", { agentId: "atlas", model: demo });
	await client.call("conversation.open", { id: failedParent });
	await client.call("submit", { id: failedParent, text: "/delegate Scout: network never" });
	const failedDelegate = await client.until("delegate reports the original connection failure", () => client.conversations.get(failedParent)?.items.find((i) => i.kind === "tool"));
	assert.match(failedDelegate.text, /Scout did not finish the task: the model's provider answered with an error: “Connection error\..*UND_ERR_SOCKET.*”\. The sub-chat is kept as it stopped: to carry on from there, call delegate again with chat: \d+/s);
	// It waited and asked again before giving up. How many times beyond that is how many requests fit in the scaled
	// ten minutes (1.2 s of the engine's clock), which is the Mac's speed, not the engine's rule; the delays themselves are
	// checked at the top of this file (#638).
	assert.ok(requests["network never"]! >= 2, `asked ${requests["network never"]} times`);
	step("giving up preserves the terminal provider error and delegation result");

	// A deadline longer than test patience makes it impossible to pass because the sleep happened to end.
	await stop(engine);
	engine = startEngine({ PI2_NETWORK_WAIT_SCALE: "1000" });
	client = await Client.connect(engine, home);
	await client.until("stand-in offered again", () => client.models.some((m) => m.provider === provider));
	const networkStop = await client.ask(provider, "network stop");
	const sleep = await client.until("a durable network sleep", () => {
		const retry = client.conversations.get(networkStop)?.state.retry;
		return retry?.network === true ? retry : undefined;
	});
	await stop(engine);
	engine = startEngine({ PI2_NETWORK_WAIT_SCALE: "1000" });
	client = await Client.connect(engine, home);
	await client.call("conversation.open", { id: networkStop });
	await client.until("the same network sleep after restart", () => client.conversations.get(networkStop)?.state.retry?.at === sleep.at && client.networkSleeps.has(networkStop));
	await client.call("abort", { id: networkStop });
	conv = await client.until("Stop ended the sleep", () => {
		const c = client.conversations.get(networkStop);
		return c?.state.busy === false && c.state.retry === null ? c : undefined;
	});
	assert.equal(requests["network stop"], 1);
	assert.equal(carriedOn(conv).length, 0);
	step("a network sleep survives an engine restart and Stop ends it without another request");

	// ---- A window one conversation is told of: the others on the provider wait for it (#556)
	await stop(engine);
	engine = startEngine({ PI2_LIMIT_REMEMBER_MS: "50" });
	client = await Client.connect(engine, home);
	await client.until("stand-in offered again", () => client.models.some((m) => m.provider === provider));
	/** The holds the engine has logged: conversations waiting for a time another was told of. */
	const holds = () => log.split("\n").filter((line) => line.includes(", without asking"));
	assert.equal(holds().length, 0);

	// One conversation is refused and told until when. A second on the same provider does not send a request at all.
	const learner = await client.ask(provider, "window");
	await client.until("what the refusal said is remembered", () => new RegExp(`conversation ${learner} was told Stand-in's limit is used up until .*: the other conversations on Stand-in wait for that time rather than ask`).test(log) || undefined);
	const behind = await client.ask(provider, "window second");
	await client.until("the second waits, shown as a wait for a limit", () => client.conversations.get(behind)?.state.limitWait ?? undefined);
	const shown = client.conversations.get(behind)!.state.limitWait!;
	assert.equal(shown.provider, "Stand-in");
	assert.equal(shown.told, true);
	assert.equal(shown.refusals, 0, "it was refused nothing: it never asked");
	// The line saying the second is held, held until it arrives; and the line the wait found is the one checked, rather
	// than a second reading of the log taken at a moment of its own (#588).
	const heldLine = await client.until("its hold logged", () => holds().find((line) => line.includes(`conversation ${behind} waits`)));
	assert.match(heldLine, new RegExp(`conversation ${behind} waits for Stand-in's rate limit until .*Z, the time conversation ${learner} was told, without asking$`));
	assert.equal(requests["window second"], undefined, "the second sent no request while the first waits");
	// At the time it named, one of them goes; the other follows when it is answered, so each is answered on its first
	// request after the window, never refused.
	for (const id of [learner, behind]) assert.equal((await client.ended(id)).state.failure, null, `conversation ${id} carried on`);
	assert.equal(requests["window"], 2);
	assert.equal(requests["window second"], 1);
	step("a second conversation on a provider whose window another learned waits without asking, and is answered at the time it named");

	// Two conversations behind one window: one is let through at the time, and the other only once that one is answered.
	const keeper = await client.ask(provider, "window later");
	await client.until("the window shown", () => client.conversations.get(keeper)?.state.limitWait ?? undefined);
	await client.call("abort", { id: keeper });
	await client.until("the one that named it stopped, the window still known", () => (client.conversations.get(keeper)?.state.busy === false ? true : undefined));
	const slow = await client.ask(provider, "window slow");
	await client.until("the first held", () => client.conversations.get(slow)?.state.limitWait ?? undefined);
	const thirdChat = await client.ask(provider, "window third");
	await client.until("the second held", () => client.conversations.get(thirdChat)?.state.limitWait ?? undefined);
	assert.equal(requests["window slow"], undefined);
	assert.equal(requests["window third"], undefined);
	for (const id of [slow, thirdChat]) assert.equal((await client.ended(id)).state.failure, null, `conversation ${id} carried on`);
	const [wentFirst, cameAfter] = (came["window slow"] ?? 0) <= (came["window third"] ?? 0) ? ["window slow", "window third"] : ["window third", "window slow"];
	assert.ok(came[cameAfter]! >= after[wentFirst]!, `${cameAfter} was sent only after ${wentFirst} was answered`);
	step("one request is let through at the time the window resets, and the conversations behind it follow when it is answered");

	// A new message after Stop is sent at once, and its answer ends the window for all.
	const againChat = await client.ask(provider, "window again");
	await client.until("the window known again", () => client.conversations.get(againChat)?.state.limitWait ?? undefined);
	const fourth = await client.ask(provider, "window fourth");
	await client.until("held without asking", () => client.conversations.get(fourth)?.state.limitWait ?? undefined);
	assert.equal(requests["window fourth"], undefined);
	await client.call("abort", { id: fourth });
	await client.until("the held one stopped", () => (client.conversations.get(fourth)?.state.busy === false ? true : undefined));
	await client.call("submit", { id: fourth, text: "window by hand" });
	conv = await client.until("the hand-asked request answered", () => {
		const c = client.conversations.get(fourth);
		return c !== undefined && c.state.busy === false && c.state.failure === null && c.items.some((i) => i.kind === "assistant" && i.stop === "stop") ? c : undefined;
	});
	assert.equal(answer(conv), "Answered after 0 refusals.");
	assert.equal(requests["window by hand"], 1, "sent at once");
	await logSays("the person's message asks now rather than waiting", new RegExp(`conversation ${fourth} asks Stand-in now, as the person asked it to, rather than waiting until`));
	// Answered, so nothing is held back any more: a conversation asking now is not made to wait.
	const nextUp = await client.ask(provider, "window after");
	conv = await client.ended(nextUp);
	assert.equal(conv.state.failure, null);
	assert.equal(requests["window after"], 1);
	await client.call("abort", { id: againChat });
	step("a request the person asks for by hand is sent, and its answer ends the window for every conversation");

	// Carry on, chosen while a run is held, sends its request now too, and its answer ends the window for all.
	const learnedWindow = await client.ask(provider, "window carried");
	await client.until("the window known once more", () => client.conversations.get(learnedWindow)?.state.limitWait ?? undefined);
	const heldChat = await client.ask(provider, "window carried on");
	const heldWait = await client.until("held, waiting for the time", () => client.conversations.get(heldChat)?.state.limitWait ?? undefined);
	assert.equal(requests["window carried on"], undefined);
	assert.deepEqual(await client.call("conversation.carryOn", { id: heldChat, since: heldWait.since, model: demo }), { switched: [heldChat] });
	conv = await client.until("answered on the model its request was made for", () => {
		const c = client.conversations.get(heldChat);
		return c !== undefined && c.state.busy === false && c.state.failure === null && c.items.some((i) => i.kind === "assistant" && i.stop === "stop") ? c : undefined;
	});
	assert.equal(answer(conv), "Answered after 0 refusals.");
	assert.equal(requests["window carried on"], 1);
	assert.match(conv.items.find((item) => item.kind === "marker" && item.text.startsWith("You ended the wait"))!.text, /^You ended the wait for Stand-in's limit and sent its request now; the conversation's model is Demo model \(scripted\) \(demo\) from the next request\.$/);
	const afterCarry = await client.ask(provider, "window after carry");
	conv = await client.ended(afterCarry);
	assert.equal(conv.state.failure, null);
	assert.equal(requests["window after carry"], 1, "the answer ended the window for every conversation");
	step("Carry on, chosen while a run is held for a window, sends its request at once, and its answer ends the wait for all");

	// A provider that named no time: nothing is remembered, and the next conversation asks as it does now.
	const backoff = await client.ask(provider, "window never named");
	await client.until("the backoff shown", () => client.conversations.get(backoff)?.state.limitWait ?? undefined);
	const nothing = await client.ask(provider, "window after nothing");
	conv = await client.ended(nothing);
	assert.equal(conv.state.failure, null);
	assert.equal(requests["window after nothing"], 1, "asked at once, as before");
	assert.ok(!log.split("\n").some((line) => line.includes(`conversation ${backoff} was told`)), "nothing is remembered for a provider that named no time");
	assert.ok(!holds().some((line) => line.includes(`conversation ${nothing} waits`)), "no hold was placed for it");
	conv = await client.ended(backoff);
	assert.equal(answer(conv), "Answered after 1 refusals.");
	step("a provider that named no time is not remembered, and the conversations on it ask as they did");

	// What an agent that hands out work is told: the window, in the kind of line a subscription gets (#232).
	const toldWindow = await client.ask(provider, "window told");
	await client.until("the window remembered again", () => new RegExp(`conversation ${toldWindow} was told Stand-in's limit is used up until`).test(log) || undefined);
	const { id: toldLead } = await client.call("conversation.create", { agentId: "atlas", model: demo });
	await client.call("conversation.open", { id: toldLead });
	await client.call("submit", { id: toldLead, text: '/tool sub_chats {"action":"list"}' });
	const listedAgain = await client.until("sub_chats' list", () => client.conversations.get(toldLead)!.items.find((i) => i.kind === "tool"));
	assert.match(listedAgain.text, /- Stand-in, which .*: its limit is used up until \d\d:\d\d \(in \d+ (?:s|min)\), as a refusal said\. A run that asks it before then waits for that time\./);
	await client.until("the lead idle", () => (client.conversations.get(toldLead)?.state.busy === false ? true : undefined));
	step("an agent that hands out work is told which provider's limit is used up, and until when");
	console.log("PASS");
} finally {
	await stop(engine);
	standIn.close();
}
process.exit(0);
