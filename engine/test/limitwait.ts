// Waiting for a provider's limit (src/limitwait.ts, docs/limits.md): how a refusal is read and how long a run waits for
// it, then a real engine against a stand-in provider on 127.0.0.1 that refuses (HTTP 429 or 529, with and without a
// time to ask again) and then answers. No real provider is called.
//
// No check depends on how fast the Mac is. Waits the provider does not time are made short with PI2_LIMIT_BACKOFF_MS,
// times it names are a few milliseconds, and a wait of an hour is only looked at, stopped and carried over a restart,
// never sat through. Each check waits for what the engine does, never for a time.

import assert from "node:assert/strict";
import { type ChildProcess, execFileSync, spawn } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { AssistantMessage } from "@earendil-works/pi-ai";
import { DEFAULTS, duration, limitOf, namedTime, type Wait, Waits } from "../src/limitwait.ts";
import { EngineClient, stop } from "./patience.ts";

function step(name: string): void {
	console.log(`ok  ${name}`);
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
	step("the time a provider names for asking again: retry-after (seconds, milliseconds, a date), a window's reset, an error body");
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
	"bad key": Array(100).fill(BAD_KEY),
	"an hour": Array(100).fill({ ...RATE_LIMITED, headers: { "retry-after": "3600" } }),
	"never answers": Array(1000).fill(RATE_LIMITED),
};
const requests: Record<string, number> = {};
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
		const refusal = scripts[prompt]?.[n];
		if (refusal !== undefined) {
			response.writeHead(refusal.status, { "content-type": "application/json", ...refusal.headers }).end(refusal.body);
			return;
		}
		response.writeHead(200, { "content-type": "text/event-stream" });
		const chunk = (delta: object, finish: string | null) =>
			response.write(`data: ${JSON.stringify({ id: "c1", object: "chat.completion.chunk", created: 1, model: "stand-in", choices: [{ index: 0, delta, finish_reason: finish }] })}\n\n`);
		chunk({ role: "assistant", content: `Answered after ${n} refusals.` }, null);
		chunk({}, "stop");
		response.end("data: [DONE]\n\n");
	});
});
await new Promise<void>((resolve) => standIn.listen(0, "127.0.0.1", resolve));
const standInUrl = `http://127.0.0.1:${(standIn.address() as { port: number }).port}/v1`;

let log = "";
function startEngine(extra: Record<string, string> = {}): ChildProcess {
	const child = spawn(process.execPath, [join(import.meta.dirname, "..", "src", "main.ts")], {
		env: { ...process.env, PI2_HOME: home, PI2_KEYCHAIN_SERVICE: KEYCHAIN_SERVICE, PI2_LOGIN_SHELL: "off", PI2_LIMIT_BACKOFF_MS: "20", ...extra },
		stdio: ["ignore", "ignore", "pipe"],
	});
	child.stderr!.setEncoding("utf8").on("data", (chunk: string) => {
		log += chunk;
		process.stderr.write(chunk);
	});
	return child;
}

type Item = { kind: string; text: string; stop?: string; error?: string | null };
type Shown = { kind: string; since: number; until: number; told: boolean; refusals: number; provider: string };
type State = { busy: boolean; failure: { reason: string; detail: string | null } | null; retry: { at: number; error: string } | null; limitWait: Shown | null };
class Client extends EngineClient {
	override conversations = new Map<number, { items: Item[]; state: State }>();
	activity: { conversationId: number; status: string; limit: Shown | null }[] = [];
	models: { provider: string; id: string }[] = [];
	override receive(message: any): void {
		if (message.event === "activity") this.activity = message.runs;
		else if (message.event === "providers") this.models = message.models;
		else super.receive(message);
	}
	/** A new conversation on the stand-in, sent `prompt`. */
	async ask(provider: string, prompt: string): Promise<number> {
		const { id } = await this.call("conversation.create", { model: { provider, modelId: "stand-in" } });
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
	assert.match(log, new RegExp(`conversation ${six} is waiting for Stand-in's rate limit: no time named`));
	await client.until("the wait's end logged", () => new RegExp(`conversation ${six} carries on: Stand-in answered after .* of waiting \\(6 refusals\\)`).test(log));
	step("a run refused six times for a rate limit, with no time named, waits and carries on by itself");

	// The provider says when: retry-after-ms, then retry-after: 0.
	const told = await client.ask(provider, "told when");
	conv = await client.ended(told);
	assert.equal(conv.state.failure, null);
	assert.equal(answer(conv), "Answered after 2 refusals.");
	assert.match(log, new RegExp(`conversation ${told} is waiting for Stand-in's rate limit: until .*Z, the time it named`));
	step("a run waits for the time the provider names (retry-after-ms, retry-after) and carries on");

	// Overloaded (529), five times.
	const busy = await client.ask(provider, "overloaded");
	conv = await client.ended(busy);
	assert.equal(conv.state.failure, null);
	assert.equal(answer(conv), "Answered after 5 refusals.");
	assert.match(log, new RegExp(`conversation ${busy} is waiting for Stand-in being overloaded`));
	step("a run that meets an overloaded provider (529) waits and carries on");

	// A bad key ends the run at once, after one request, as before.
	const bad = await client.ask(provider, "bad key");
	conv = await client.ended(bad);
	assert.equal(conv.state.failure?.reason, "model_error");
	assert.match(conv.state.failure!.detail!, /invalid x-api-key/);
	assert.equal(requests["bad key"], 1, "not retried");
	assert.doesNotMatch(log, new RegExp(`conversation ${bad} is waiting`));
	step("an error that is not a limit (a bad key) still ends the run at once");

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
	step("Stop ends a run that waits for a limit");

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
	assert.match(log, new RegExp(`conversation ${never} gave up waiting: pi² waited .* for Stand-in's rate limit`));
	step("a run that has waited as long as it waits by itself ends, and its error says why and how to carry on");
	console.log("PASS");
} finally {
	await stop(engine);
	standIn.close();
}
process.exit(0);
