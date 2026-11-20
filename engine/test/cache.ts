// The prompt cache's lifetime (src/cache.ts, "The prompt cache" in docs/limits.md): a conversation that hands out work
// asks for the long cache from its first `delegate` on, every other one stays on the short cache, a provider that refuses
// the long cache gets the request again with the short one and is not asked for it again until the engine restarts, and
// engine.log says what a request after a long pause read from the cache. A real engine against a stand-in provider on
// 127.0.0.1 that speaks Anthropic's Messages API. No real provider is called.
//
// No check depends on how fast the Mac is: each waits for what the engine does. The pause that counts as long is made
// zero with PI2_CACHE_PAUSE_MS, so every request after the first in a conversation has a line.

import assert from "node:assert/strict";
import { type ChildProcess, execFileSync, spawn } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { createServer, type ServerResponse } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { AssistantMessage } from "@earendil-works/pi-ai";
import { refusedForCache } from "../src/cache.ts";
import { EngineClient, standInApp, stop } from "./patience.ts";
// The engine takes changes to what the person set only from its app's connection (#513): this test's connection stands
// for the app's, as the tests that answer for the person already do (#504).
process.env.PI2_APP_BUNDLE = standInApp();

function step(name: string): void {
	console.log(`ok  ${name}`);
}

// ---- What counts as a refusal of the long cache

{
	const error = (errorMessage: string): AssistantMessage =>
		({ role: "assistant", content: [], api: "anthropic-messages", provider: "p", model: "m", usage: {} as never, stopReason: "error", errorMessage, timestamp: 0 }) as AssistantMessage;
	assert.equal(refusedForCache(error('400 {"type":"error","error":{"type":"invalid_request_error","message":"cache_control.ttl: Extra inputs are not permitted"}}'), 400, ""), true);
	assert.equal(refusedForCache(error("400 Unrecognized request argument supplied: prompt_cache_retention"), 400, ""), true);
	assert.equal(refusedForCache(error("ValidationException: The model does not support the ttl field of cachePoint"), undefined, ""), true);
	assert.equal(refusedForCache(error("400 status code (no body)"), 400, '{"detail":"extended cache retention is not available"}'), true, "named in the body only");
	// Not the cache's fault: a limit, a bad key, a server error, a prompt too long, an answer that was stopped.
	assert.equal(refusedForCache(error("429 rate limit for prompt caching"), 429, ""), false);
	assert.equal(refusedForCache(error("401 invalid x-api-key, cache"), 401, ""), false);
	assert.equal(refusedForCache(error("500 cache server unavailable"), 500, ""), false);
	assert.equal(refusedForCache(error("400 prompt is too long: 210000 tokens > 200000 maximum"), 400, ""), false);
	assert.equal(refusedForCache({ ...error("ttl"), stopReason: "aborted" }, undefined, ""), false);
	step("a refusal of the long cache is told apart from other errors");
}

// ---- A real engine, and a stand-in Anthropic endpoint

const home = mkdtempSync(join(tmpdir(), "pi2-cache-"));
const KEYCHAIN_SERVICE = `dev.pi2.credentials.test-cache-${process.pid}`;
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

type Seen = { prompt: string; afterTool: boolean; long: boolean; answered: boolean };
/** Every request the stand-in was sent, in order. */
const seen: Seen[] = [];
/** Whether the stand-in refuses a request that asks for the one-hour cache, as a gateway that does not know it would. */
let refuseLong = false;

function sse(response: ServerResponse, events: object[]): void {
	response.writeHead(200, { "content-type": "text/event-stream" });
	for (const event of events) response.write(`event: ${(event as { type: string }).type}\ndata: ${JSON.stringify(event)}\n\n`);
	response.end();
}

const standIn = createServer((request, response) => {
	let body = "";
	request.setEncoding("utf8").on("data", (chunk: string) => (body += chunk));
	request.on("end", () => {
		const parsed = JSON.parse(body) as { messages: { role: string; content: string | { type: string; text?: string }[] }[] };
		const blocks = (m: { content: string | { type: string; text?: string }[] }) => (typeof m.content === "string" ? [{ type: "text", text: m.content }] : m.content);
		const users = parsed.messages.filter((m) => m.role === "user");
		const afterTool = blocks(users.at(-1)!).some((b) => b.type === "tool_result");
		// The conversation's own words: the newest user message that is not a tool's result.
		const prompt = blocks(users.findLast((m) => blocks(m).some((b) => b.type === "text")) ?? users[0]!)
			.filter((b) => b.type === "text")
			.map((b) => b.text ?? "")
			.join("")
			.trim();
		const long = body.includes('"ttl":"1h"');
		const entry: Seen = { prompt, afterTool, long, answered: false };
		seen.push(entry);
		if (long && refuseLong) {
			response
				.writeHead(400, { "content-type": "application/json" })
				.end(JSON.stringify({ type: "error", error: { type: "invalid_request_error", message: "cache_control.ttl: Extra inputs are not permitted" } }));
			return;
		}
		entry.answered = true;
		// Every answer reports a cache write and no read, so a pause shows as a miss; "warm" ones report a read.
		const warm = prompt.includes("warm");
		const usage = { input_tokens: 12, cache_creation_input_tokens: warm ? 100 : 3000, cache_read_input_tokens: warm ? 2500 : 0, output_tokens: 1 };
		const start = { type: "message_start", message: { id: "msg_1", type: "message", role: "assistant", content: [], model: "stand-in", stop_reason: null, stop_sequence: null, usage } };
		if (prompt === "hand out" && !afterTool) {
			sse(response, [
				start,
				{ type: "content_block_start", index: 0, content_block: { type: "tool_use", id: "toolu_1", name: "delegate", input: {} } },
				{ type: "content_block_delta", index: 0, delta: { type: "input_json_delta", partial_json: JSON.stringify({ agent: "Scout", task: "say hi" }) } },
				{ type: "content_block_stop", index: 0 },
				{ type: "message_delta", delta: { stop_reason: "tool_use", stop_sequence: null }, usage: { output_tokens: 9 } },
				{ type: "message_stop" },
			]);
			return;
		}
		sse(response, [
			start,
			{ type: "content_block_start", index: 0, content_block: { type: "text", text: "" } },
			{ type: "content_block_delta", index: 0, delta: { type: "text_delta", text: `Answer to ${prompt}${afterTool ? " after a tool" : ""}.` } },
			{ type: "content_block_stop", index: 0 },
			{ type: "message_delta", delta: { stop_reason: "end_turn", stop_sequence: null }, usage: { output_tokens: 5 } },
			{ type: "message_stop" },
		]);
	});
});
await new Promise<void>((resolve) => standIn.listen(0, "127.0.0.1", resolve));
const standInUrl = `http://127.0.0.1:${(standIn.address() as { port: number }).port}`;

let log = "";
function startEngine(): ChildProcess {
	const child = spawn(process.execPath, [join(import.meta.dirname, "..", "src", "main.ts")], {
		env: { ...process.env, PI2_HOME: home, PI2_KEYCHAIN_SERVICE: KEYCHAIN_SERVICE, PI2_LOGIN_SHELL: "off", PI2_CACHE_PAUSE_MS: "0" },
		stdio: ["ignore", "ignore", "pipe"],
	});
	child.stderr!.setEncoding("utf8").on("data", (chunk: string) => {
		log += chunk;
		process.stderr.write(chunk);
	});
	return child;
}

type Item = { kind: string; text: string; stop?: string };
type State = { busy: boolean; failure: { reason: string; detail: string | null } | null };
class Client extends EngineClient {
	override conversations = new Map<number, { items: Item[]; state: State }>();
	models: { provider: string; id: string }[] = [];
	override receive(message: any): void {
		if (message.event === "providers") this.models = message.models;
		else super.receive(message);
	}
	/** Sends `text` and waits for the answer to it: the answers of the conversation, one more than before. */
	async say(id: number, text: string): Promise<string> {
		const before = this.answers(id).length;
		await this.call("submit", { id, text });
		return this.until(`the answer to "${text}"`, () => {
			const conv = this.conversations.get(id)!;
			assert.equal(conv.state.failure, null, `conversation ${id} failed: ${conv.state.failure?.detail}`);
			return !conv.state.busy && this.answers(id).length > before ? this.answers(id).at(-1) : undefined;
		});
	}
	answers(id: number): string[] {
		return (this.conversations.get(id)?.items ?? []).filter((i) => i.kind === "assistant" && i.stop === "stop").map((i) => i.text);
	}
}

const lines = (pattern: RegExp) => log.split("\n").filter((line) => pattern.test(line));
const requestsFor = (prompt: string) => seen.filter((s) => s.prompt === prompt);

let engine = startEngine();
try {
	let client = await Client.connect(engine, home);
	const { id: provider } = await client.call("endpoints.save", { name: "Stand-in", baseUrl: standInUrl, api: "anthropic-messages", models: [{ id: "stand-in" }] });
	await client.until("stand-in offered", () => client.models.some((m) => m.provider === provider));
	await client.call("agents.save", { agent: { id: "scout", name: "Scout", model: { provider, modelId: "stand-in" } } });
	const model = { provider, modelId: "stand-in" };

	// A conversation that has not handed out work, and one that will: both on the short cache at first.
	const { id: plain } = await client.call("conversation.create", { agentId: "scout", model });
	await client.call("conversation.open", { id: plain });
	const { id: lead } = await client.call("conversation.create", { agentId: "atlas", model });
	await client.call("conversation.open", { id: lead });
	assert.equal(await client.say(plain, "first plain"), "Answer to first plain.");
	assert.equal(await client.say(lead, "first lead"), "Answer to first lead.");
	assert.equal(await client.say(lead, "second lead"), "Answer to second lead.");
	assert.deepEqual(
		seen.map((s) => s.long),
		[false, false, false],
	);
	step("a conversation that has not handed out work asks for the short cache");

	// The lead hands out work: the request that calls delegate was already sent, short; the sub-chat's own requests stay
	// short; from the one after it, the lead's requests ask for the long cache.
	assert.equal(await client.say(lead, "hand out"), "Answer to hand out after a tool.");
	const handOut = requestsFor("hand out");
	assert.deepEqual(
		handOut.map((s) => [s.afterTool, s.long]),
		[
			[false, false],
			[true, true],
		],
	);
	assert.deepEqual(
		requestsFor("say hi").map((s) => s.long),
		[false],
		"the sub-chat stays on the short cache",
	);
	assert.equal(await client.say(lead, "after handing out"), "Answer to after handing out.");
	assert.equal(requestsFor("after handing out")[0]?.long, true);
	assert.equal(await client.say(plain, "second plain"), "Answer to second plain.");
	assert.equal(requestsFor("second plain")[0]?.long, false, "the other conversation is unchanged");
	assert.equal(lines(new RegExp(`conversation ${lead} hands out work: its requests ask Stand-in for the long prompt cache from now on`)).length, 1);
	step("from its first delegate on, a conversation asks for the long cache; its sub-chat and other conversations do not");

	// A request after a pause (any pause, in this test) says in engine.log what it read from the cache, once.
	assert.equal(lines(new RegExp(`conversation ${plain} read nothing from the prompt cache after .* without a request, and wrote 3,000 tokens to it again; the request before asked for the short cache`)).length, 1);
	assert.equal(lines(new RegExp(`conversation ${lead} read nothing from the prompt cache after .* the request before asked for the long cache`)).length, 1, "after handing out");
	assert.equal(await client.say(lead, "warm"), "Answer to warm.");
	await client.until("the read logged", () => lines(new RegExp(`conversation ${lead} read 2,500 tokens from the prompt cache after .* without a request; the request before asked for the long cache`)).length === 1);
	const leadLines = lines(new RegExp(`conversation ${lead} read `)).length;
	const leadRequests = seen.filter((s) => s.prompt.includes("lead") || ["hand out", "after handing out", "warm"].includes(s.prompt)).length;
	assert.ok(leadLines < leadRequests, `at most one line a request (${leadLines} lines, ${leadRequests} requests)`);
	step("engine.log says what a request after a pause read from the cache, and which lifetime the one before asked for");

	// The provider now refuses the long cache: the request is sent again with the short one, and the person sees only
	// the answer. Stand-in is not asked for the long one again, and engine.log says so once.
	refuseLong = true;
	assert.equal(await client.say(lead, "refused"), "Answer to refused.");
	assert.deepEqual(
		requestsFor("refused").map((s) => [s.long, s.answered]),
		[
			[true, false],
			[false, true],
		],
	);
	const refusedLine = /Stand-in refused a request that asked for the long prompt cache \(.*cache_control\.ttl: Extra inputs are not permitted.*\); it was sent again with the short cache, and Stand-in is not asked for the long one again until the engine restarts/;
	await client.until("the refusal logged", () => lines(refusedLine).length === 1);
	assert.equal(await client.say(lead, "after the refusal"), "Answer to after the refusal.");
	assert.deepEqual(
		requestsFor("after the refusal").map((s) => s.long),
		[false],
	);
	assert.equal(lines(refusedLine).length, 1, "said once");
	step("a provider that refuses the long cache: the request goes again with the short one, and it is not asked again");

	// A restart forgets the refusal: the next request asks again, is refused, and is sent again.
	await stop(engine);
	engine = startEngine();
	client = await Client.connect(engine, home);
	await client.until("stand-in offered again", () => client.models.some((m) => m.provider === provider));
	await client.call("conversation.open", { id: lead });
	await client.until("the lead's transcript", () => client.conversations.get(lead));
	assert.equal(await client.say(lead, "after a restart"), "Answer to after a restart.");
	assert.deepEqual(
		requestsFor("after a restart").map((s) => [s.long, s.answered]),
		[
			[true, false],
			[false, true],
		],
	);
	await client.until("the refusal logged again", () => lines(refusedLine).length === 2);
	step("after a restart the long cache is asked for again, and a refusal is dealt with as before");
	console.log("PASS");
} finally {
	await stop(engine);
	standIn.close();
}
process.exit(0);
