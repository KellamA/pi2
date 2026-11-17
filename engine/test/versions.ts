// A chat's versions (#285): Try Again, with the same model or another, Edit, the step between versions, and the sources
// an answer read. A real engine on a throwaway data folder, driven over its socket with the scripted demo model.
//
// Until chats exist (#283), a development engine (one without a BUILD file, as here) offers versions on any conversation
// of its own, so this uses an ordinary one.

import assert from "node:assert/strict";
import { type ChildProcess, spawn } from "node:child_process";
import { mkdtempSync, realpathSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { EngineClient, stop } from "./patience.ts";

type Item = { id: number; kind: string; text?: string; model?: string | null; stop?: string; details?: any; toolCalls?: { callId: string; name: string }[] };
type Point = { after: number | null; index: number; count: number };
type State = { busy: boolean; chat: boolean; versions: Point[] | null; agent: { model: { provider: string; modelId: string } | null } };
type Conv = { items: Item[]; state: State; resets: number };

const scratch = realpathSync(mkdtempSync(join(tmpdir(), "pi2-versions-")));
const home = join(scratch, "home");
const main = join(import.meta.dirname, "..", "src", "main.ts");
const engines: ChildProcess[] = [];

process.on("exit", () => {
	for (const engine of engines) engine.kill("SIGKILL");
	rmSync(scratch, { recursive: true, force: true });
});

function startEngine(env: NodeJS.ProcessEnv = {}): ChildProcess {
	const engine = spawn(process.execPath, [main], {
		env: { ...process.env, PI2_HOME: home, PI2_KEYCHAIN_SERVICE: `dev.pi2.credentials.test-versions-${process.pid}`, PI2_DEMO_TOKENS_PER_SECOND: "1000", PI2_DEMO_TEXT_MODEL: "1", PI2_DEMO_COST: "5", ...env },
		stdio: ["ignore", "ignore", "inherit"],
	});
	engines.push(engine);
	return engine;
}

class Client extends EngineClient {
	override conversations = new Map<number, Conv>();
	library: { id: number; title: string; busy: boolean; parent: number | null }[] = [];
	archived: { id: number }[] = [];
	usage: any;

	override receive(message: any): void {
		if (message.event === "library") {
			this.library = message.conversations;
			this.archived = message.archived;
		} else if (message.event === "usage") this.usage = message;
		else if (message.event === "conversation") {
			const conv: Conv = this.conversations.get(message.id) ?? { items: [], state: message.state, resets: 0 };
			if (message.reset) {
				conv.items = [];
				conv.resets += 1;
			}
			conv.items.push(...message.items);
			conv.state = message.state;
			this.conversations.set(message.id, conv);
		} else super.receive(message);
	}

	/** The conversation once it is idle and its newest answer says `words`. */
	answered(id: number, words: string): Promise<Conv> {
		return this.until(`an answer saying ${words}`, () => {
			const conv = this.conversations.get(id);
			const last = conv?.items.findLast((item) => item.kind === "assistant");
			return conv !== undefined && !conv.state.busy && last?.text?.includes(words) === true ? conv : undefined;
		});
	}
}

const said = (conv: Conv) => conv.items.filter((item) => item.kind === "user").map((item) => item.text);
const answers = (conv: Conv) => conv.items.filter((item) => item.kind === "assistant");
const step = (name: string) => console.log(`ok  ${name}`);

// A page for web_fetch to read, served on this Mac to the one address the engine is told it may fetch from here.
const server = createServer((request, response) => {
	if (request.url === "/guide") {
		response.writeHead(200, { "content-type": "text/html" });
		response.end("<html><head><title>The Guide</title></head><body><p>Mostly harmless.</p></body></html>");
	} else {
		response.writeHead(404);
		response.end();
	}
});
await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
const address = `127.0.0.1:${(server.address() as { port: number }).port}`;

try {
	let engine = startEngine({ PI2_TEST_ALLOW_ADDRESS: address });
	let client = await Client.connect(engine, home);

	// An agent that may read the web, for the sources.
	await client.call("agents.save", { agent: { name: "Reader", access: "none", browser: { enabled: true, ask: false } } });
	const { id: chat } = await client.call("conversation.create", { agentId: "reader" });
	await client.call("conversation.open", { id: chat });
	await client.call("submit", { id: chat, text: "first" });
	await client.answered(chat, 'You said: "first"');
	await client.call("submit", { id: chat, text: "second" });
	let conv = await client.answered(chat, 'You said: "second"');
	const first = conv.items.find((item) => item.kind === "user" && item.text === "first")!;
	const second = conv.items.find((item) => item.kind === "user" && item.text === "second")!;
	const originalAnswer = answers(conv).at(-1)!;
	assert.deepEqual(conv.state.versions, [], "one version: no points to step between");
	assert.equal(conv.state.chat, false, "an ordinary conversation, offered versions by a development engine");

	// ---- Try Again: a new version of the answer, and the earlier one kept

	const resets = conv.resets;
	const tried = await client.call("conversation.retry", { id: chat, entryId: originalAnswer.id });
	assert.equal(tried.id, chat);
	assert.notEqual(tried.version, chat, "a version of its own");
	conv = await client.until("the new version shown, answered", () => {
		const now = client.conversations.get(chat)!;
		return now.resets > resets && !now.state.busy && answers(now).length === 2 && answers(now).at(-1)!.id !== originalAnswer.id ? now : undefined;
	});
	assert.deepEqual(said(conv), ["first", "second"], "the same messages, answered again");
	assert.deepEqual(conv.state.versions, [{ after: second.id, index: 1, count: 2 }], "two versions of the answer to the second message, the new one shown");
	assert.ok(!client.library.some((row) => row.id === tried.version), "a version is never listed on its own");
	assert.ok(client.library.some((row) => row.id === chat));
	step("Try Again answers the message again as a new version, under the chat's id");

	// With another model.
	await client.call("conversation.retry", { id: chat, entryId: second.id, model: { provider: "demo", modelId: "demo-text" } });
	conv = await client.until("a third version, by the other model", () => {
		const now = client.conversations.get(chat)!;
		return !now.state.busy && now.state.versions?.[0]?.count === 3 && answers(now).at(-1)?.model === "demo-text" ? now : undefined;
	});
	assert.deepEqual(conv.state.versions, [{ after: second.id, index: 2, count: 3 }]);
	assert.equal(conv.state.agent.model?.modelId, "demo-text", "the chat carries on with the model chosen");
	await assert.rejects(client.call("conversation.retry", { id: chat, entryId: second.id, model: { provider: "demo", modelId: "nonesuch" } }), /Unknown model/);
	step("Try Again with another model");

	// ---- Stepping between versions: the conversation below follows

	await client.call("conversation.version", { id: chat, after: second.id, index: 0 });
	conv = await client.until("the first answer shown again", () => {
		const now = client.conversations.get(chat)!;
		return now.state.versions?.[0]?.index === 0 ? now : undefined;
	});
	assert.equal(answers(conv).at(-1)!.id, originalAnswer.id, "the earlier answer, as it was");
	assert.equal(conv.state.agent.model?.modelId, "demo-1", "with the model it had");
	// What the model sees follows the version shown.
	await client.call("submit", { id: chat, text: "/context" });
	conv = await client.answered(chat, "CONTEXT");
	assert.equal(answers(conv).at(-1)!.text, "CONTEXT\nfirst\n(answer)\nsecond\n(answer)\n/context");
	await assert.rejects(client.call("conversation.version", { id: chat, after: second.id, index: 3 }), /no such version/);
	step("stepping between versions shows each as it was, and carries on from it");

	// ---- Edit: the person's message, sent again in place of the old one

	await client.call("conversation.edit", { id: chat, entryId: second.id, text: "second, edited" });
	conv = await client.answered(chat, 'You said: "second, edited"');
	assert.deepEqual(said(conv), ["first", "second, edited"], "the edited message, and nothing that followed the old one");
	assert.equal(conv.state.versions?.length, 1, "the versions of the answer to the old message are not on this path");
	const editPoint = conv.state.versions![0]!;
	assert.deepEqual({ index: editPoint.index, count: editPoint.count }, { index: 1, count: 2 });
	assert.ok(editPoint.after! > first.id && editPoint.after! < second.id, "the versions part after the first exchange");
	await client.call("submit", { id: chat, text: "/context" });
	conv = await client.answered(chat, "CONTEXT");
	assert.equal(answers(conv).at(-1)!.text, "CONTEXT\nfirst\n(answer)\nsecond, edited\n(answer)\n/context", "the model sees the edited message, and none of the earlier version");
	await assert.rejects(client.call("conversation.edit", { id: chat, entryId: answers(conv)[0]!.id, text: "x" }), /Only your own messages/);
	await assert.rejects(client.call("conversation.edit", { id: chat, entryId: second.id, text: "x" }), /not in the version shown/, "the old message is in another version");
	step("Edit sends the message again in its place, keeping the earlier version");

	// Back to the earlier version: the one under it shown last, with its own versions of the answer.
	await client.call("conversation.version", { id: chat, after: editPoint.after, index: 0 });
	conv = await client.until("the earlier version shown again", () => {
		const now = client.conversations.get(chat)!;
		return said(now).includes("second") ? now : undefined;
	});
	assert.deepEqual(said(conv), ["first", "second", "/context"], "as it was left, with the message sent there");
	assert.deepEqual(conv.state.versions, [
		{ after: editPoint.after, index: 0, count: 2 },
		{ after: second.id, index: 0, count: 3 },
	]);
	step("going back to an earlier version shows the one under it seen last");

	// ---- Editing the first message starts afresh

	await client.call("conversation.edit", { id: chat, entryId: first.id, text: "first, edited" });
	conv = await client.answered(chat, 'You said: "first, edited"');
	assert.deepEqual(said(conv), ["first, edited"]);
	assert.deepEqual(conv.state.versions, [{ after: null, index: 1, count: 2 }]);
	await client.call("conversation.version", { id: chat, after: null, index: 0 });
	conv = await client.until("the chat as it began", () => (said(client.conversations.get(chat)!)[0] === "first" ? client.conversations.get(chat) : undefined));
	assert.equal(conv.state.versions?.[0]?.count, 2);
	step("editing the first message starts a version afresh");

	// ---- While an answer is being written

	await client.call("submit", { id: chat, text: "/slow a long answer to stop" });
	// Some of it written, so that stopping it leaves an answer to keep.
	await client.until("the answer under way", () => ((client.conversations.get(chat)!.state as { partial?: { text?: string } | null }).partial?.text ?? "") !== "" || undefined);
	await assert.rejects(client.call("conversation.version", { id: chat, after: null, index: 1 }), /Wait until the answer is finished/);
	const slow = said(client.conversations.get(chat)!).length;
	const slowMessage = client.conversations.get(chat)!.items.findLast((item) => item.kind === "user")!;
	await client.call("conversation.retry", { id: chat, entryId: slowMessage.id });
	conv = await client.answered(chat, 'You said: "a long answer to stop"');
	assert.equal(said(conv).length, slow, "answered again");
	const slowPoint = conv.state.versions!.find((point) => point.after === slowMessage.id)!;
	assert.deepEqual(slowPoint, { after: slowMessage.id, index: 1, count: 2 });
	await client.call("conversation.version", { id: chat, after: slowMessage.id, index: 0 });
	conv = await client.until("the stopped answer shown", () => (client.conversations.get(chat)!.state.versions?.find((point) => point.after === slowMessage.id)?.index === 0 ? client.conversations.get(chat) : undefined));
	assert.equal(answers(conv).at(-1)!.stop, "aborted", "the answer Try Again stopped is kept as it stopped");
	step("Try Again stops an answer being written, and keeps it; stepping waits for the answer");

	// ---- Sources: the pages an answer read

	await client.call("submit", { id: chat, text: `/tool web_fetch {"url": "http://${address}/guide"}` });
	conv = await client.answered(chat, "Done. The tool returned");
	const fetched = conv.items.findLast((item) => item.kind === "tool")!;
	assert.deepEqual(fetched.details, { source: { url: `http://${address}/guide`, title: "The Guide" } });
	step("a page read names itself as a source");

	// ---- What versions take with them: usage counts for each, under the chat

	await client.until("usage counted", () => client.usage?.conversations?.some((row: { id: number; tokens: number }) => row.id === chat && row.tokens > 0) || undefined);
	assert.ok(!client.usage.conversations.some((row: { id: number }) => row.id !== chat), "every version's usage is the chat's");
	const search = await client.call("search", { query: "a long answer to stop" });
	assert.ok(search.results.every((result: { conversationId: number }) => result.conversationId === chat));
	step("usage and search count a chat's versions as the chat");

	// ---- After a restart, the version shown is still the one shown

	const before = client.conversations.get(chat)!;
	const shownBefore = { said: said(before), versions: before.state.versions };
	client.close();
	await stop(engine);
	engine = startEngine({ PI2_TEST_ALLOW_ADDRESS: address });
	client = await Client.connect(engine, home);
	await client.call("conversation.open", { id: chat });
	conv = await client.until("the chat again", () => client.conversations.get(chat));
	assert.deepEqual({ said: said(conv), versions: conv.state.versions }, shownBefore);
	step("the version shown outlasts a restart");

	// ---- Archiving takes the versions with the chat; they are never in the Archive on their own

	await client.call("conversation.archive", { id: chat });
	await client.until("archived", () => client.archived.some((row) => row.id === chat) || undefined);
	assert.equal(client.archived.length, 1);
	await assert.rejects(client.call("conversation.retry", { id: chat, entryId: second.id }), /archived/);
	step("archiving the chat archives its versions with it");

	client.close();
	await stop(engine);
} finally {
	server.close();
	for (const engine of engines) await stop(engine);
}
