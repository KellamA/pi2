// A section of the system prompt that changes mid-conversation, for a model that does not take a later system message
// (src/promptchanges.ts, #629): pi² sends the change where it happened, as a user message marked as its own, and the
// start of the prompt stays as it was. First the transform alone; then the requests an `openai-completions` and an
// `anthropic-messages` endpoint are sent, on a stand-in server on 127.0.0.1, with everything before each change compared
// byte for byte with what the request before it sent, and the same requests sent without pi²'s transform, which change
// the prompt's start; then a real engine whose model, on the stand-in, starts a background command and later asks again
// once it has ended, the change pi durable itself makes.

import assert from "node:assert/strict";
import { type ChildProcess, spawn } from "node:child_process";
import { closeSync, mkdtempSync, openSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { createServer, type ServerResponse } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createModels, InMemoryCredentialStore, type Message } from "@earendil-works/pi-ai";
import { anthropicMessagesApi } from "@earendil-works/pi-ai/api/anthropic-messages.lazy";
import { openAICompletionsApi } from "@earendil-works/pi-ai/api/openai-completions.lazy";
import { normalizeContext } from "@earendil-works/pi-ai/utils/transcript";
import { foldsPromptChanges, PROMPT_CHANGE_NOTE, promptChangesInPlace } from "../src/promptchanges.ts";
import { Providers } from "../src/providers.ts";
import { EngineClient, standInApp, stop } from "./patience.ts";

// The engine takes an agent's settings only from its app's connection (#513): this test's connection stands for it.
process.env.PI2_APP_BUNDLE = standInApp();
process.env.PI2_LOGIN_SHELL ??= "off";

function step(name: string): void {
	console.log(`ok  ${name}`);
}

const usage = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };
const tool = { name: "bash", description: "Run a command", parameters: { type: "object", properties: { command: { type: "string" } } } } as never;
const base = { role: "system", content: "", sections: { task_list: "<task_list>\nKeep a list.\n</task_list>", background_commands: "" }, toolsAdded: [tool], timestamp: 1 } as Message;
const user = (text: string, timestamp = 2): Message => ({ role: "user", content: text, timestamp });
const change = (sections: Record<string, string | null>, timestamp = 5): Message => ({ role: "system", content: "", sections, timestamp }) as Message;
const running = "<background_commands>\n- bg-1: `npm test`, running since 10:00.\n</background_commands>";

// ---- The transform alone

{
	const call = (api: string, provider: string) =>
		({ role: "assistant", content: [{ type: "toolCall", id: "call_1", name: "bash", arguments: { command: "npm test" } }], api, provider, model: "m", usage, stopReason: "toolUse", timestamp: 3 }) as Message;
	const result = { role: "toolResult", toolCallId: "call_1", toolName: "bash", content: [{ type: "text", text: "Started as bg-1" }], isError: false, timestamp: 4 } as Message;
	const before = [base, user("Start the tests"), call("openai-completions", "p"), result];
	const messages = structuredClone([...before, change({ background_commands: running })]);
	const freeze = (value: unknown): void => {
		if (value === null || typeof value !== "object") return;
		for (const each of Object.values(value)) freeze(each);
		Object.freeze(value);
	};
	// pi durable gives its messages frozen.
	freeze(messages);
	const placed = promptChangesInPlace(messages);
	assert.deepEqual(placed.slice(0, 4), before, "everything before the change is as it was, and nothing was changed in place");
	assert.equal(placed[0], messages[0], "the first system message is the very same");
	assert.deepEqual(placed.slice(4), [user(`${PROMPT_CHANGE_NOTE}\n\nUpdated system prompt section "background_commands":\n\n${running}`, 5)], "after tool results, a user message of its own");
	assert.match(PROMPT_CHANGE_NOTE, /^\[pi², not the person: .*needs no answer\.\]$/);

	const asked = promptChangesInPlace([base, user("Is it done?"), change({ background_commands: "" })]);
	assert.deepEqual(asked, [base, user(`Is it done?\n\n${PROMPT_CHANGE_NOTE}\n\nSystem prompt section "background_commands" is now empty: what it said before no longer holds.`)], "after the person's message, joined to it: no two user messages in a row");
	const picture = { role: "user", content: [{ type: "text", text: "Look" }, { type: "image", data: "AAAA", mimeType: "image/png" }], timestamp: 2 } as Message;
	assert.deepEqual(promptChangesInPlace([base, picture, change({ browser: null })]).at(-1), { ...picture, content: [...(picture.content as never[]), { type: "text", text: `${PROMPT_CHANGE_NOTE}\n\nRemoved system prompt section "browser".` }] });

	// The remove-all and re-add-all pair pi durable sends when sections would otherwise change order: one note, each section's last word.
	const pair = promptChangesInPlace([base, user("Go"), change({ task_list: null, background_commands: null }), change({ task_list: "<task_list>\nKeep a list.\n</task_list>", background_commands: running, browser: "<browser>\nOn\n</browser>" })]);
	assert.equal(pair.length, 2);
	assert.equal(
		(pair[1] as { content: string }).content,
		`Go\n\n${PROMPT_CHANGE_NOTE}\n\nUpdated system prompt section "task_list":\n\n<task_list>\nKeep a list.\n</task_list>\n\nUpdated system prompt section "background_commands":\n\n${running}\n\nUpdated system prompt section "browser":\n\n<browser>\nOn\n</browser>`,
	);

	// Tools that change stay with pi-ai, on a system message with nothing else, which it folds into the tools at the top.
	const other = { name: "read", description: "Read", parameters: { type: "object", properties: {} } } as never;
	const tools = promptChangesInPlace([base, user("Go"), { role: "system", content: "", sections: { background_commands: running }, toolsAdded: [other], toolsRemoved: [{ name: "bash" }], timestamp: 5 } as Message]);
	assert.deepEqual(tools, [base, user(`Go\n\n${PROMPT_CHANGE_NOTE}\n\nUpdated system prompt section "background_commands":\n\n${running}`), { role: "system", content: "", toolsAdded: [other], toolsRemoved: [{ name: "bash" }], timestamp: 5 }]);
	assert.deepEqual(promptChangesInPlace([base, user("Go"), { role: "system", content: "", toolsAdded: [other], timestamp: 5 } as Message]), [base, user("Go"), { role: "system", content: "", toolsAdded: [other], timestamp: 5 }], "a change of tools alone gives no note");
	assert.deepEqual(promptChangesInPlace([base, user("Go")]), [base, user("Go")], "nothing changed, nothing sent");
	assert.deepEqual(promptChangesInPlace([user("Go")]), [user("Go")]);

	// Two changes, each in its own request: the second leaves the first where it was.
	const two = [...before, change({ background_commands: running }), { ...(call("openai-completions", "p") as object), content: [{ type: "text", text: "Started." }], stopReason: "stop" } as Message, user("Is it done?", 6), change({ background_commands: "" }, 7)];
	assert.deepEqual(promptChangesInPlace(two).slice(0, 5), promptChangesInPlace(two.slice(0, 5)));

	assert.equal(foldsPromptChanges({ api: "openai-completions" }), true, "an endpoint of one's own, DeepSeek or GLM");
	assert.equal(foldsPromptChanges({ api: "openai-completions", compat: { supportsMidConvoSystemMessages: false } }), true);
	assert.equal(foldsPromptChanges({ api: "anthropic-messages", compat: {} }), true);
	assert.equal(foldsPromptChanges({ api: "openai-completions", compat: { supportsMidConvoSystemMessages: true } }), false, "a model on this Mac, Anthropic's, Codex: untouched");
	assert.equal(foldsPromptChanges({ api: "anthropic-messages", compat: { supportsMidConvoSystemMessages: true } }), false);
	assert.equal(foldsPromptChanges({ api: "google-generative-ai", compat: { supportsMidConvoSystemMessages: true } }), true, "Google's API folds them whatever the model says");
	assert.equal(foldsPromptChanges({ api: "bedrock-converse-stream" }), true);
	assert.equal(foldsPromptChanges({ api: "faux" }), false, "an API pi² does not know (the demo model's) is left alone");
}
step("a changed section is placed where it changed, after the person's message or tool results, and the rest is left as it was");

// ---- The requests two endpoints are sent

type Body = Record<string, unknown> & { messages: Record<string, unknown>[] };
const bodies: { path: string; body: Body }[] = [];
/** What the engine's model (`worker`) answers next, given the last message it was sent. */
let worker: (last: Record<string, unknown>) => Record<string, unknown> = () => ({ content: "ok" });
const sse = (response: ServerResponse, events: unknown[]) => {
	response.writeHead(200, { "content-type": "text/event-stream" });
	response.end(events.map((event) => `${typeof event === "object" && event !== null && "type" in event ? `event: ${(event as { type: string }).type}\n` : ""}data: ${JSON.stringify(event)}\n\n`).join(""));
};
const server = createServer((request, response) => {
	let text = "";
	request.setEncoding("utf8").on("data", (chunk: string) => (text += chunk)).on("end", () => {
		const body = JSON.parse(text) as Body;
		bodies.push({ path: request.url ?? "", body });
		if (request.url?.split("?")[0]?.endsWith("/messages")) {
			const answer = { input_tokens: 10, cache_creation_input_tokens: 0, cache_read_input_tokens: 0, output_tokens: 1 };
			sse(response, [
				{ type: "message_start", message: { id: "msg_1", type: "message", role: "assistant", content: [], model: "m", stop_reason: null, stop_sequence: null, usage: answer } },
				{ type: "content_block_start", index: 0, content_block: { type: "text", text: "" } },
				{ type: "content_block_delta", index: 0, delta: { type: "text_delta", text: "ok" } },
				{ type: "content_block_stop", index: 0 },
				{ type: "message_delta", delta: { stop_reason: "end_turn", stop_sequence: null }, usage: { output_tokens: 1 } },
				{ type: "message_stop" },
			]);
			return;
		}
		const delta = body.model === "worker" ? worker(body.messages.at(-1)!) : { content: "ok" };
		const chunk = (part: Record<string, unknown>, finish: string | null = null) => ({ id: "c", object: "chat.completion.chunk", created: 0, model: body.model, choices: [{ index: 0, delta: part, finish_reason: finish }] });
		response.writeHead(200, { "content-type": "text/event-stream" });
		response.end(`data: ${JSON.stringify(chunk({ role: "assistant", ...delta }))}\n\ndata: ${JSON.stringify(chunk({}, "tool_calls" in delta ? "tool_calls" : "stop"))}\n\ndata: [DONE]\n\n`);
	});
});
await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
const url = `http://127.0.0.1:${(server.address() as { port: number }).port}`;

/**
 * A request as a prompt cache reads it: pi-ai marks the last message of each Anthropic request for the cache, writing a
 * message's text as a block to mark it, and a mark or a lone block is read as the same text. Everything else stays.
 */
const asRead = (value: unknown): unknown =>
	JSON.parse(JSON.stringify(value), (key, entry) => (key === "cache_control" ? undefined : key === "content" && typeof entry === "string" ? [{ type: "text", text: entry }] : entry));
const same = (a: unknown, b: unknown, what: string) => assert.equal(JSON.stringify(asRead(a)), JSON.stringify(asRead(b)), what);

const data = mkdtempSync(join(tmpdir(), "pi2-promptchanges-"));
try {
	const models = (api: string, id: string) => ({ id, name: api, baseUrl: api === "anthropic-messages" ? url : `${url}/v1`, api, models: [{ id: "m" }] });
	writeFileSync(join(data, "endpoints.json"), JSON.stringify([models("openai-completions", "custom-openai"), models("anthropic-messages", "custom-anthropic")]));
	const providers = new Providers(data, new InMemoryCredentialStore(), () => "device", { builtins: (options) => createModels(options) });
	for (const [api, provider, raw] of [
		["openai-completions", "custom-openai", openAICompletionsApi()],
		["anthropic-messages", "custom-anthropic", anthropicMessagesApi()],
	] as const) {
		const model = providers.models.getModel(provider, "m")!;
		assert.equal(model.api, api);
		assert.equal(foldsPromptChanges(model), true, `${api}: an endpoint of one's own does not say it takes a later system message`);
		const call = { role: "assistant", content: [{ type: "toolCall", id: "call_1", name: "bash", arguments: { command: "npm test" } }], api, provider, model: "m", usage, stopReason: "toolUse", timestamp: 3 } as Message;
		const result = { role: "toolResult", toolCallId: "call_1", toolName: "bash", content: [{ type: "text", text: "Started in the background as bg-1." }], isError: false, timestamp: 4 } as Message;
		const answered = { role: "assistant", content: [{ type: "text", text: "Started." }], api, provider, model: "m", usage, stopReason: "stop", timestamp: 6 } as Message;
		// As pi durable makes them: the prompt at the first request, then each change just before the request it is for.
		const first = [base, user("Start the tests in the background")];
		const second = [...first, call, result, change({ background_commands: running })];
		const third = [...second, answered, user("Is it done?", 7), change({ background_commands: "" }, 8)];
		const send = async (messages: Message[], through: "pi²" | "pi-ai") => {
			const stream = through === "pi²" ? providers.models.stream(model, { messages }, {}) : raw.stream(model as never, normalizeContext({ messages }), { apiKey: "k" });
			const answer = await stream.result();
			assert.equal(answer.stopReason, "stop", answer.errorMessage ?? "");
			return bodies.at(-1)!.body;
		};
		const sent = [];
		for (const messages of [first, second, third]) sent.push(await send(messages, "pi²"));
		const prompt = api === "anthropic-messages" ? ["system", "tools"] : ["tools"];
		for (const [n, [earlier, later]] of [[0, [sent[0]!, sent[1]!]], [1, [sent[1]!, sent[2]!]]] as const) {
			for (const key of prompt) same(later[key], earlier[key], `${api}: request ${n + 2} sends the same ${key} as request ${n + 1}`);
			same(later.messages.slice(0, earlier.messages.length), earlier.messages, `${api}: request ${n + 2} starts with everything request ${n + 1} sent`);
		}
		const lead = api === "anthropic-messages" ? 0 : 1;
		assert.deepEqual(
			sent[1]!.messages.slice(lead + 3).map((message) => [message.role, JSON.stringify(message.content).includes(PROMPT_CHANGE_NOTE)]),
			[["user", true]],
			`${api}: the change after the tool's result is a user message of its own`,
		);
		const last = JSON.stringify(sent[2]!.messages.at(-1)!.content);
		assert.ok(last.includes("Is it done?") && last.includes(PROMPT_CHANGE_NOTE) && last.includes("is now empty"), `${api}: going back to empty joins the person's message: ${last}`);
		assert.equal(sent[2]!.messages.at(-2)!.role, "assistant", `${api}: no two user messages in a row`);

		// The same requests as pi-ai sends them without pi²'s transform: folded into the first system message, the change
		// makes every request start differently, so a prompt cache keeps nothing.
		const folded = [];
		for (const messages of [first, second, third]) folded.push(await send(messages, "pi-ai"));
		const start = (body: Body) => JSON.stringify(api === "anthropic-messages" ? body.system : body.messages[0]);
		assert.notEqual(start(folded[1]!), start(folded[0]!), `${api}: without the transform, the second request's prompt starts differently`);
		assert.notEqual(start(folded[2]!), start(folded[1]!), `${api}: and the third's again`);
		same(folded[0]!, sent[0]!, `${api}: a request with no change is sent as before`);
		step(`${api}: everything before a change is sent byte for byte as before, the change as a user message after it; folded, the prompt's start changed each time`);
	}

	// A model that says it takes a later system message is sent it as before (a model on this Mac: localrun.ts).
	const flagged = { ...providers.models.getModel("custom-openai", "m")!, compat: { supportsMidConvoSystemMessages: true } };
	await providers.models.stream(flagged as never, { messages: [base, user("Go"), change({ background_commands: running })] }, {}).result();
	assert.deepEqual(bodies.at(-1)!.body.messages.map((message) => message.role), ["system", "user", "system"]);
	step("a model that takes a later system message is sent it where it is, as before");
} finally {
	rmSync(data, { recursive: true, force: true });
}

// ---- A real engine: the change pi durable makes as a background command starts and ends

const home = mkdtempSync(join(tmpdir(), "pi2-promptchanges-engine-"));
const work = realpathSync(mkdtempSync(join(tmpdir(), "pi2-promptchanges-work-")));
const gate = join(work, "gate");
const engineLog = join(home, "engine.log");
let engine: ChildProcess | undefined;
let passed = false;
try {
	const log = openSync(engineLog, "a");
	try {
		engine = spawn(process.execPath, [join(import.meta.dirname, "..", "src", "main.ts")], {
			env: { ...process.env, PI2_HOME: home, PI2_KEYCHAIN_SERVICE: `dev.pi2.credentials.test-promptchanges-${process.pid}` },
			stdio: ["ignore", "ignore", log],
		});
	} finally {
		closeSync(log);
	}
	const client = await EngineClient.connect(engine, home);
	const { id: provider } = await client.call("endpoints.save", { name: "Stand-in", baseUrl: `${url}/v1`, api: "openai-completions", models: [{ id: "worker" }] });
	await client.until("the endpoint offered", () => client.events.providers?.models?.some((m: { provider: string }) => m.provider === provider));
	const { id: agentId } = await client.call("agents.save", { agent: { name: "Worker", access: "full", cwd: work, model: { provider, modelId: "worker" } } });
	const { id } = await client.call("conversation.create", { agentId });
	await client.call("conversation.open", { id });
	worker = (last) =>
		last.role === "user" && last.content === "Start it"
			? { tool_calls: [{ index: 0, id: "call_1", type: "function", function: { name: "bash", arguments: JSON.stringify({ command: `while [ ! -e '${gate}' ]; do sleep 0.1; done`, background: true }) } }] }
			: { content: "Noted." };
	const mine = () => bodies.filter((each) => each.body.model === "worker").map((each) => each.body);
	const idle = (count: number) => client.until(`request ${count} answered`, () => mine().length >= count && client.conversations.get(id)?.state.busy === false && client.conversations.get(id)?.items.some((item: { kind: string }) => item.kind === "assistant"));
	await client.call("submit", { id, text: "Start it" });
	await idle(2);
	assert.equal(mine().length, 2, "the tool call, then its result answered");
	writeFileSync(gate, "");
	await client.until("the command over", () => client.events.background !== undefined && client.events.background.commands.length === 0);
	await client.call("submit", { id, text: "Is it done?" });
	await idle(3);
	const sent = mine();
	assert.equal(sent.length, 3, JSON.stringify(sent.map((body) => body.messages.at(-1))));
	for (const [n, [earlier, later]] of [[1, [sent[0]!, sent[1]!]], [2, [sent[1]!, sent[2]!]]] as const) {
		same(later.tools, earlier.tools, `request ${n + 1} sends the same tools`);
		same(later.messages.slice(0, earlier.messages.length), earlier.messages, `request ${n + 1} starts with everything request ${n} sent`);
	}
	const started = JSON.stringify(sent[1]!.messages.at(-1));
	assert.equal(sent[1]!.messages.at(-2)!.role, "tool");
	assert.ok(started.includes(PROMPT_CHANGE_NOTE) && started.includes("background_commands") && started.includes("bg-1"), `the command started: ${started}`);
	assert.ok(!JSON.stringify(sent[1]!.messages[0]).includes("bg-1"), "and not in the first system message");
	const ended = JSON.stringify(sent[2]!.messages.at(-1));
	assert.ok(ended.includes("Is it done?") && ended.includes(PROMPT_CHANGE_NOTE) && ended.includes("background_commands"), `the command ended: ${ended}`);
	assert.ok(sent.every((body) => body.messages.filter((message) => message.role === "system").length === 1), "one system message, at the start, in each");
	step("a real engine: a background command's start and end reach an endpoint where they happened, and each request starts with all of the one before");
	passed = true;
} finally {
	if (engine !== undefined) await stop(engine);
	server.close();
	if (!passed) {
		try {
			process.stderr.write(readFileSync(engineLog, "utf8"));
		} catch {}
	}
	rmSync(home, { recursive: true, force: true });
	rmSync(work, { recursive: true, force: true });
}
