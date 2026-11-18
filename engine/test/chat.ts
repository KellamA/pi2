// Chat mode's engine (#283, src/chat.ts): chats with pi²'s built-in assistant, as a kind of conversation. A real engine on
// a throwaway data folder, driven over its socket with the demo model, as the app would drive it.
//
// A chat is made with `conversation.create` and `chat: true`; its record has `chat: true` and no agent, and the page is
// told so. It is offered only the assistant's tools (reading the web, writing documents), none of which asks, and its
// documents are kept in a folder of its own. It is pinned, renamed, searched, counted, exported, archived and deleted
// as any conversation, and never shows as an agent's. Chat mode's settings have their defaults and a request to change them.

import assert from "node:assert/strict";
import { type ChildProcess, execFileSync, spawn } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { dueForArchive } from "../src/archive.ts";
import { CHAT_TOOLS } from "../src/builtins.ts";
import { CHAT_MEMORY_TOOLS } from "../src/knowledge.ts";
import { EngineClient, stop } from "./patience.ts";

const home = mkdtempSync(join(tmpdir(), "pi2-chat-"));
const outside = realpathSync(mkdtempSync(join(tmpdir(), "pi2-chat-out-")));
const main = join(import.meta.dirname, "..", "src", "main.ts");
const KEYCHAIN_SERVICE = `dev.pi2.credentials.test-chat-${process.pid}`;
process.env.PI2_DEMO_TOKENS_PER_SECOND ??= "100000";
process.env.PI2_LOGIN_SHELL ??= "off";
// A second model to choose, and a price so that usage has something to count.
const env = { ...process.env, PI2_HOME: home, PI2_KEYCHAIN_SERVICE: KEYCHAIN_SERVICE, PI2_DEMO_TEXT_MODEL: "1", PI2_DEMO_COST: "3" };

let engine: ChildProcess | undefined;
process.on("exit", () => {
	if (engine !== undefined && engine.exitCode === null && engine.signalCode === null) engine.kill("SIGKILL");
	rmSync(home, { recursive: true, force: true });
	rmSync(outside, { recursive: true, force: true });
	try {
		while (true) execFileSync("/usr/bin/security", ["delete-generic-password", "-s", KEYCHAIN_SERVICE], { stdio: "ignore" });
	} catch {
		// None left.
	}
});

function step(name: string): void {
	console.log(`ok  ${name}`);
}

class Client extends EngineClient {
	/** What the demo model answers to `text`, once its run is over. */
	async answer(id: number, text: string): Promise<string> {
		const assistant = () => (this.conversations.get(id)?.items ?? []).filter((item: any) => item.kind === "assistant");
		const before = assistant().length;
		await this.call("submit", { id, text });
		await this.until(`answer to ${text}`, () => {
			const conv = this.conversations.get(id);
			return conv !== undefined && !conv.state.busy && assistant().length > before;
		});
		return assistant().at(-1).text as string;
	}
	/** The tools offered, and the sections of the prompt with something in them, by name. */
	async offered(id: number): Promise<{ tools: string[]; sections: string[] }> {
		const sizes = (await this.answer(id, "/system sizes")).split("\n").slice(1);
		const answer = await this.answer(id, "/system none");
		return {
			tools: answer.slice(answer.lastIndexOf("\nTOOLS: ") + 8).split(", "),
			sections: sizes.map((line) => line.slice(0, line.lastIndexOf(" "))).filter((key) => !key.startsWith("(")),
		};
	}
	row(id: number): any {
		return (this.events.library?.conversations ?? []).find((x: any) => x.id === id);
	}
	tools(id: number): any[] {
		return (this.conversations.get(id)?.items ?? []).filter((item: any) => item.kind === "tool");
	}
}

/**
 * The chat's tools as the engine's list has them: those of `CHAT_TOOLS` it knows, the web's only with the web on, and not
 * making pictures, since this engine has no picture model (pictures.ts; tested in pictures.ts).
 */
const expected = (builtIns: any[], web: boolean) => [
	...builtIns.filter((entry) => CHAT_TOOLS.includes(entry.key) && (web || entry.key !== "web") && entry.needs !== "pictures").flatMap((entry) => entry.tools as string[]),
	// Chat mode's memory, on by default (#288; tested in chatmemory.ts).
	...CHAT_MEMORY_TOOLS,
];

engine = spawn(process.execPath, [main], { env, stdio: ["ignore", "ignore", "inherit"] });
const client = await Client.connect(engine, home);
try {
	await client.until("providers", () => client.events.providers);
	await client.until("agents", () => client.events.agents);
	const agentsBefore = client.events.agents.agents.map((agent: any) => agent.id);

	// ---- Settings: there with their defaults before anything is changed.
	await client.until("chat settings", () => client.events.chat);
	assert.deepEqual({ ...client.events.chat, event: undefined }, { event: undefined, instructions: "", defaultModel: null, web: true, memory: true });
	step("chat mode's settings have their defaults");

	// ---- A chat
	const { id: chat } = await client.call("conversation.create", { chat: true });
	await client.call("conversation.open", { id: chat });
	const row = await client.until("the chat in the library", () => client.row(chat));
	assert.equal(row.chat, true);
	assert.equal(row.agentId, null, "a chat has no agent");
	assert.equal(row.pinned, false);
	const state = await client.until("the chat's state", () => client.conversations.get(chat)?.state);
	assert.equal(state.chat, true, "the page is told it is a chat");
	assert.equal(state.agent.agentId, null);
	assert.equal(state.agent.cwd, null, "a chat has no folder");
	assert.deepEqual(state.agent.model, { provider: "demo", modelId: "demo-1" }, "a first chat starts with the agent view's model");
	assert.deepEqual(client.events.agents.agents.map((agent: any) => agent.id), agentsBefore, "the assistant is not one of the agents");
	await assert.rejects(client.call("conversation.create", { chat: true, agentId: agentsBefore[0] }), /A chat has no agent/);
	step("conversation.create with chat: true makes a chat: chat: true, no agent, no folder, and no new agent");

	// The agent view's conversations are not chats.
	const { id: plain } = await client.call("conversation.create", { agentId: "forge" });
	await client.call("conversation.open", { id: plain });
	assert.equal((await client.until("the agent's conversation", () => client.row(plain))).chat, false);
	assert.equal((await client.until("its state", () => client.conversations.get(plain)?.state)).chat, false);
	step("an agent's conversation is not a chat");

	// ---- Its tools: the assistant's own, and only those.
	const builtIns = client.events.agents.builtInTools;
	const seen = await client.offered(chat);
	assert.deepEqual([...seen.tools].sort(), expected(builtIns, true).sort(), `only the assistant's tools: ${seen.tools.join(" ")}`);
	for (const name of ["web_fetch", "web_search", "write_document"]) assert.ok(seen.tools.includes(name), `${name}: ${seen.tools.join(" ")}`);
	for (const name of ["bash", "read", "write", "edit", "ask_user", "update_plan", "delegate", "browser", "computer", "list_files", "schedule_task"]) {
		assert.ok(!seen.tools.includes(name), `no ${name} in a chat: ${seen.tools.join(" ")}`);
	}
	assert.ok(seen.sections.includes("chat") && seen.sections.includes("look_web") && seen.sections.includes("documents"), seen.sections.join(" "));
	for (const key of ["scratch", "agents", "project_instructions", "worktree", "computer_use", "browser"]) assert.ok(!seen.sections.includes(key), `no ${key} section: ${seen.sections.join(" ")}`);
	const section = await client.answer(chat, "/system chat");
	assert.match(section, /chat assistant of pi²/);
	assert.match(section, /no folder/);
	const agentSeen = await client.offered(plain);
	assert.ok(!agentSeen.sections.includes("chat"), "an agent's conversation has no chat section");
	step("a chat is offered the web and documents, and nothing that works the Mac");

	// The title comes from the first message, as an agent's conversation's does.
	await client.until("the chat's title", () => client.row(chat)?.title === "/system sizes");

	// ---- A document: written in the chat's own folder, without asking.
	const own = join(home, "chats", String(chat));
	const results = client.tools(chat).length;
	await client.answer(chat, '/tool write_document {"path":"notes.html","markdown":"# Notes\\n\\nFrom a chat.","title":"Notes"}');
	const written = client.tools(chat).at(-1);
	assert.ok(client.tools(chat).length > results);
	assert.equal(written.isError, false, written.text);
	assert.match(written.text, /Wrote notes\.html/);
	assert.equal(written.details.path, join(realpathSync(own), "notes.html"), "the result names the file in full, for the page to open");
	assert.match(readFileSync(join(own, "notes.html"), "utf8"), /From a chat\./);
	assert.deepEqual(client.events.inbox?.items ?? [], [], "nothing asked");
	await client.answer(chat, `/tool write_document ${JSON.stringify({ path: join(outside, "away.html"), markdown: "# Away" })}`);
	assert.equal(client.tools(chat).at(-1).isError, true);
	assert.ok(!existsSync(join(outside, "away.html")), "a chat cannot write outside its own folder");
	step("write_document in a chat writes in the chat's own folder, asks nothing, and nowhere else");

	// ---- Working things out with code (#286): the chat has it, and it asks nothing.
	assert.ok(seen.tools.includes("run_code"), seen.tools.join(" "));
	await client.answer(chat, '/tool run_code {"code":"return 6 * 7"}');
	const ran = client.tools(chat).at(-1);
	assert.equal(ran.name, "run_code");
	assert.equal(ran.isError, false, ran.text);
	assert.equal(ran.text, "Returned: 42");
	assert.deepEqual(client.events.inbox?.items ?? [], [], "nothing asked");
	step("run_code in a chat runs without asking");

	// ---- What cannot be changed in a chat, and what can.
	await assert.rejects(client.call("conversation.configure", { id: chat, cwd: outside }), /A chat has no folder/);
	await assert.rejects(client.call("conversation.configure", { id: chat, access: "full" }), /tools are fixed/);
	await client.call("conversation.configure", { id: chat, thinkingLevel: "high" });
	await client.until("thinking", () => client.conversations.get(chat)?.state.agent.thinkingLevel === "high");
	await client.call("conversation.configure", { id: chat, model: { provider: "demo", modelId: "demo-text" } });
	await client.until("the chat's model", () => client.conversations.get(chat)?.state.agent.model?.modelId === "demo-text");
	assert.match(await client.answer(chat, "Hello again"), /./, "the chat answers on the model chosen in the middle of it");
	const { id: next } = await client.call("conversation.create", { chat: true });
	await client.call("conversation.open", { id: next });
	assert.equal((await client.until("the next chat's state", () => client.conversations.get(next)?.state)).agent.model.modelId, "demo-text", "a new chat starts with the model used last in a chat");
	const { id: agentNext } = await client.call("conversation.create", { agentId: "forge" });
	await client.call("conversation.open", { id: agentNext });
	assert.equal((await client.until("the agent's next state", () => client.conversations.get(agentNext)?.state)).agent.model.modelId, "demo-1", "the agent view keeps its own last model");
	step("a chat has no folder or access to change; its model and thinking change in the middle, and the next chat starts with that model");

	// ---- Settings: changed and checked.
	await assert.rejects(client.call("chat.set", { web: "no" }), /web must be true or false/);
	await assert.rejects(client.call("chat.set", { defaultModel: { provider: "demo", modelId: "nope" } }), /Unknown model/);
	await assert.rejects(client.call("chat.set", { instructions: "x".repeat(20_001) }), /20,000 characters at most/);
	const changed = await client.call("chat.set", { defaultModel: { provider: "demo", modelId: "demo-1" }, instructions: "  Be brief.  " });
	assert.deepEqual(changed, { instructions: "Be brief.", defaultModel: { provider: "demo", modelId: "demo-1" }, web: true, memory: true });
	await client.until("the chat event", () => client.events.chat?.instructions === "Be brief.");
	const { id: third } = await client.call("conversation.create", { chat: true });
	await client.call("conversation.open", { id: third });
	assert.equal((await client.until("the third chat's state", () => client.conversations.get(third)?.state)).agent.model.modelId, "demo-1", "a default chosen in Settings counts from the next chat");
	const settingsFile = JSON.parse(readFileSync(join(home, "settings.json"), "utf8"));
	assert.equal(settingsFile.chat.instructions, "Be brief.", "kept under chat in the engine's settings");
	step("chat.set changes the settings, refuses what is wrong, and a default model counts from the next chat");

	// The web switch: off, a chat's next message has no web tools; on again, they come back.
	await client.call("chat.set", { web: false });
	const noWeb = await client.offered(chat);
	assert.deepEqual([...noWeb.tools].sort(), expected(builtIns, false).sort(), noWeb.tools.join(" "));
	assert.ok(!noWeb.sections.includes("look_web"));
	await client.call("chat.set", { web: true });
	assert.ok((await client.offered(chat)).tools.includes("web_fetch"));
	step("with the web off, a chat is not offered the web tools, from its next message");

	// ---- Pinned
	await client.call("conversation.pin", { id: chat, pinned: true });
	await client.until("pinned", () => client.row(chat)?.pinned === true);
	await assert.rejects(client.call("conversation.pin", { id: chat }), /pinned must be true or false/);
	await client.call("conversation.pin", { id: chat, pinned: false });
	await client.until("unpinned", () => client.row(chat)?.pinned === false);
	const day = 86_400_000;
	const old = { title: "", createdAt: 0, updatedAt: 0, access: "none" as const, chat: true as const };
	assert.deepEqual(dueForArchive({ "1": old, "2": { ...old, pinned: true } }, 10 * day, 1, () => false), [1], "a pinned chat is not archived for going unused");
	step("conversation.pin pins and unpins; a pinned conversation is not archived automatically");

	// ---- Rename, search, usage, export, activity, fork
	await client.call("conversation.rename", { id: chat, title: "Questions about tides" });
	await client.until("renamed", () => client.row(chat)?.title === "Questions about tides");
	const found = (await client.call("search", { query: "hello again" })).results;
	assert.ok(found.some((result: any) => result.conversationId === chat && result.chat === true), JSON.stringify(found));
	const usage = await client.until("usage counted for chats", () => (client.events.usage?.chats?.tokens > 0 ? client.events.usage : undefined));
	assert.ok(usage.chats.cost > 0, "a chat counts towards spend and the budget");
	assert.ok(!usage.agents.some((agent: any) => agent.agentId === ""), "and is not counted as an agent's");
	assert.ok(usage.conversations.some((conv: any) => conv.id === chat && conv.chat === true));
	const exported = JSON.parse((await client.call("conversation.export", { id: chat, format: "json" })).text);
	assert.equal(exported.chat, true);
	assert.equal(exported.agent, null);
	assert.match((await client.call("conversation.export", { id: chat })).text, /^# Questions about tides\n[\s\S]*## Assistant/);
	await client.call("submit", { id: chat, text: "/slow tell me a long story" });
	const run = await client.until("the chat in Activity", () => client.events.activity?.runs?.find((x: any) => x.conversationId === chat));
	assert.equal(run.chat, true, "Activity shows a chat as a chat");
	assert.equal(run.agentId, null);
	await client.call("abort", { id: chat });
	await client.until("stopped", () => !client.conversations.get(chat)?.state.busy && !client.events.activity?.runs?.some((x: any) => x.conversationId === chat));
	const firstEntry = client.conversations.get(chat).items[0].id;
	const { id: fork } = await client.call("conversation.fork", { id: chat, entryId: firstEntry });
	assert.equal((await client.until("the fork", () => client.row(fork))).chat, true, "a fork of a chat is a chat");
	step("a chat is renamed, searched, counted, exported, shown in Activity and forked as a chat");

	// ---- Archive and delete
	await client.call("conversation.archive", { id: chat });
	const archived = await client.until("archived", () => client.events.library?.archived?.find((x: any) => x.id === chat));
	assert.equal(archived.chat, true);
	assert.ok(!client.row(chat), "out of the list");
	await assert.rejects(client.call("submit", { id: chat, text: "more" }), /archived/);
	await client.call("conversation.unarchive", { id: chat });
	await client.until("restored", () => client.row(chat));
	assert.ok(existsSync(own), "an archived chat keeps its documents");
	await client.call("conversation.delete", { id: chat });
	await client.until("its folder removed", () => !existsSync(own));
	step("a chat is archived and restored with its documents, and deleting it removes them");

	assert.deepEqual(client.events.agents.agents.map((agent: any) => agent.id), agentsBefore, "still no new agent");
	assert.deepEqual(client.events.inbox?.items ?? [], [], "and nothing a chat did asked anything");
} finally {
	client.close();
	await stop(engine);
}
