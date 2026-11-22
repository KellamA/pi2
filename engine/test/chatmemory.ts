// Chat mode's instructions and memory (#288, src/chat.ts and src/knowledge.ts). A real engine on a throwaway data folder,
// driven over its socket with the demo model, as the app would drive it.
//
// The chat instructions from Settings reach every chat and no agent. Chat mode keeps notes of its own, across chats, apart
// from every agent's: a chat remembers and forgets only its own, and can read the agents' notes (those with memory on)
// with agent_notes, which changes nothing. It never works the other way: no agent is given chat mode's notes or the tool,
// a chat continued as an agent's conversation (#289) included.
// With memory off, a chat remembers nothing and reads nothing. Prints what the agents' notes would cost in every chat's
// prompt, against the one line and the tool that chat mode uses instead.

import assert from "node:assert/strict";
import { type ChildProcess, execFileSync, spawn } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { CHAT_MEMORY_TOOLS } from "../src/knowledge.ts";
import { EngineClient, leaveOut, standInApp, stop } from "./patience.ts";

// The agents' notes chat mode reads are the templates' own (docs/projects.md, 9.7), which a conversation writes and is
// given only in no project: the agent's conversations here are such ones, their carried project deleted (`leaveOut`), as
// a person still has them (#718).
// The engine takes changes to what the person set only from its app's connection (#513): this test's connection stands
// for the app's, as the tests that answer for the person already do (#504).
process.env.PI2_APP_BUNDLE = standInApp();

const home = mkdtempSync(join(tmpdir(), "pi2-chatmemory-"));
const main = join(import.meta.dirname, "..", "src", "main.ts");
const KEYCHAIN_SERVICE = `dev.pi2.credentials.test-chatmemory-${process.pid}`;
process.env.PI2_DEMO_TOKENS_PER_SECOND ??= "100000";
process.env.PI2_LOGIN_SHELL ??= "off";
const env = { ...process.env, PI2_HOME: home, PI2_KEYCHAIN_SERVICE: KEYCHAIN_SERVICE };

let engine: ChildProcess | undefined;
process.on("exit", () => {
	if (engine !== undefined && engine.exitCode === null && engine.signalCode === null) engine.kill("SIGKILL");
	rmSync(home, { recursive: true, force: true });
	try {
		while (true) execFileSync("/usr/bin/security", ["delete-generic-password", "-s", KEYCHAIN_SERVICE], { stdio: "ignore" });
	} catch {
		// None left.
	}
});

function step(name: string): void {
	console.log(`ok  ${name}`);
}

type Note = { id: string; text: string; createdAt: number; conversation: number | null };

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
	/** The result of the tool call `text` asks the demo model for. */
	async tool(id: number, text: string): Promise<{ name: string; text: string; isError: boolean }> {
		await this.answer(id, text);
		return (this.conversations.get(id)?.items ?? []).filter((item: any) => item.kind === "tool").at(-1);
	}
	/** The tools offered, the sections of the prompt with something in them and their sizes. */
	async offered(id: number): Promise<{ tools: string[]; sizes: Map<string, number> }> {
		const sizes = (await this.answer(id, "/system sizes")).split("\n").slice(1);
		const answer = await this.answer(id, "/system none");
		return {
			tools: answer.slice(answer.lastIndexOf("\nTOOLS: ") + 8).split(", "),
			sizes: new Map(sizes.map((line) => [line.slice(0, line.lastIndexOf(" ")), Number(line.slice(line.lastIndexOf(" ") + 1))])),
		};
	}
	/** The text of section `key` as the model was last sent it, or "(none)". */
	async section(id: number, key: string): Promise<string> {
		const answer = await this.answer(id, `/system ${key}`);
		const text = answer.slice(answer.indexOf(`<<${key}>>\n`) + key.length + 5, answer.lastIndexOf("\nTOOLS: "));
		// As the model is sent it, in tags of its name.
		return text.replace(new RegExp(`^<${key}>\\n([\\s\\S]*)\\n</${key}>$`), "$1");
	}
	async open(params: Record<string, unknown>): Promise<number> {
		const { id } = await this.call("conversation.create", params);
		await this.call("conversation.open", { id });
		await this.until("its state", () => this.conversations.get(id)?.state);
		return id;
	}
	chatNotes(): Note[] {
		return this.events.memory?.chat?.notes ?? [];
	}
	agentNotes(agentId: string): Note[] {
		return this.events.memory?.agents?.[agentId]?.notes ?? [];
	}
}

const start = () => spawn(process.execPath, [main], { env, stdio: ["ignore", "ignore", "inherit"] });
engine = start();
let client = await Client.connect(engine, home);
try {
	await client.until("agents", () => client.events.agents);
	await client.until("chat settings", () => client.events.chat);
	await client.until("memory", () => client.events.memory);
	const agents = client.events.agents.agents as { id: string; name: string }[];
	const [forge, scout] = [agents.find((agent) => agent.id === "forge")!, agents.find((agent) => agent.id === "scout")!];
	assert.ok(forge !== undefined && scout !== undefined, agents.map((agent) => agent.id).join(" "));
	assert.deepEqual(client.events.memory.chat, { notes: [] }, "chat mode has no notes yet");

	// ---- Chat instructions: in every chat, in no agent's conversation.
	const chat = await client.open({ chat: true });
	assert.equal(await client.section(chat, "chat_instructions"), "(none)", "no instructions, no section");
	await client.call("chat.set", { instructions: "Call me Captain. Answer in British English." });
	assert.match(await client.section(chat, "chat_instructions"), /Settings, for every chat[\s\S]*\n\nCall me Captain\. Answer in British English\.$/);
	const agentChat = await client.open({ agentId: "forge" });
	await leaveOut(client);
	assert.equal(await client.section(agentChat, "chat_instructions"), "(none)", "an agent is not given the chat instructions");
	await client.call("chat.set", { instructions: "" });
	assert.equal(await client.section(chat, "chat_instructions"), "(none)", "cleared, they are gone from the next message");
	await client.call("chat.set", { instructions: "Call me Captain." });
	step("the chat instructions reach every chat from its next message, and no agent");

	// ---- Chat mode's own notes: on by default, kept across chats, apart from every agent's.
	let seen = await client.offered(chat);
	for (const name of CHAT_MEMORY_TOOLS) assert.ok(seen.tools.includes(name), `${name} in a chat: ${seen.tools.join(" ")}`);
	let memory = await client.section(chat, "memory");
	assert.match(memory, /your own notes from earlier chats/);
	assert.match(memory, /You have no notes yet/);
	assert.ok(!/agent_notes/.test(memory), "no line about the agents' notes while no agent has any");
	let result = await client.tool(chat, '/tool remember {"note":"The person sails a boat called Petrel."}');
	assert.match(result.text, /Noted \(c1\)/);
	await client.until("the chat's note", () => client.chatNotes().length === 1);
	assert.deepEqual([client.chatNotes()[0]!.text, client.chatNotes()[0]!.conversation], ["The person sails a boat called Petrel.", chat]);
	assert.ok(Object.values(client.events.memory.agents).every((agent: any) => agent.notes.length === 0), `no agent's notes changed: ${JSON.stringify(client.events.memory.agents)}`);
	const nextChat = await client.open({ chat: true });
	assert.match(await client.section(nextChat, "memory"), /- c1: The person sails a boat called Petrel\./, "the next chat has the note");
	step("a chat remembers in chat mode's own notes, and the next chat is given them");

	// ---- The agents' notes: an agent with memory on, and one with it off.
	await client.call("memory.setEnabled", { agentId: forge.id, enabled: true });
	await client.until("forge's memory on", () => client.events.memory.agents[forge.id]?.enabled === true);
	result = await client.tool(agentChat, '/tool remember {"note":"The person works in TypeScript and prefers tabs."}');
	assert.match(result.text, /Noted \(m1\)/);
	await client.call("memory.add", { agentId: forge.id, text: "The project is called Lighthouse." });
	await client.until("forge's notes", () => client.agentNotes(forge.id).length === 2);
	await client.call("memory.add", { agentId: scout.id, text: "Scout's note, with its memory off." });
	await client.until("scout's note", () => client.agentNotes(scout.id).length === 1);
	assert.equal(client.chatNotes().length, 1, "chat mode's notes are untouched by an agent's");

	// The agent: none of chat mode's notes, and no way to read or change them.
	const agentSeen = await client.offered(agentChat);
	assert.ok(!agentSeen.tools.includes("agent_notes"), `an agent has no agent_notes: ${agentSeen.tools.join(" ")}`);
	const agentMemory = await client.section(agentChat, "memory");
	assert.match(agentMemory, /m1: The person works in TypeScript/);
	assert.ok(!/Petrel|c1/.test(agentMemory), "an agent is not given chat mode's notes");
	result = await client.tool(agentChat, '/tool forget {"id":"c1"}');
	assert.ok(result.isError && /no note c1/.test(result.text), result.text);
	result = await client.tool(agentChat, '/tool agent_notes {"agent":"Forge"}');
	assert.ok(result.isError, "an agent cannot call agent_notes");
	assert.equal(client.chatNotes().length, 1, "an agent's forget leaves chat mode's notes alone");
	step("an agent is never given chat mode's notes or the tool, and cannot remove one");

	// The chat: one line naming the agents with notes, and the notes when it asks for them.
	memory = await client.section(chat, "memory");
	assert.match(memory, new RegExp(`agents in pi² keep notes of their own[^\\n]*: ${forge.name}\\. [^\\n]*agent_notes[^\\n]*read-only`));
	assert.ok(!memory.includes(scout.name), "an agent with memory off is not named");
	assert.ok(!/TypeScript|Lighthouse/.test(memory), "the agents' notes are not in a chat's prompt");
	result = await client.tool(chat, "/tool agent_notes {}");
	assert.equal(result.isError, false, result.text);
	assert.match(result.text, new RegExp(`^${forge.name}'s notes:\\n- The person works in TypeScript and prefers tabs\\.\\n- The project is called Lighthouse\\.$`));
	assert.ok(!result.text.includes("Scout's note"), "not an agent's whose memory is off");
	result = await client.tool(chat, `/tool agent_notes ${JSON.stringify({ agent: forge.name.toUpperCase(), search: "lighthouse boat" })}`);
	assert.equal(result.text, `${forge.name}'s notes:\n- The project is called Lighthouse.`, "by name, and only the notes with a word asked for");
	result = await client.tool(chat, '/tool agent_notes {"agent":"Nobody"}');
	assert.ok(result.isError && result.text.includes(`These do: ${forge.name}.`), result.text);
	step("a chat is told which agents keep notes, and reads them with agent_notes");

	// A chat cannot change an agent's notes, whatever it tries, and what it notes stays in its own.
	const forgeBefore = JSON.stringify(client.agentNotes(forge.id));
	result = await client.tool(chat, '/tool forget {"id":"m1"}');
	assert.ok(result.isError && /no note m1/.test(result.text) && /Your notes: c1/.test(result.text), result.text);
	result = await client.tool(chat, '/tool remember {"note":"The person works in TypeScript and prefers tabs."}');
	assert.match(result.text, /Noted \(c2\)/, "a note like an agent's is chat mode's own");
	await client.until("the chat's second note", () => client.chatNotes().length === 2);
	assert.equal(JSON.stringify(client.agentNotes(forge.id)), forgeBefore, "the agent's notes are as they were");
	assert.ok(!(await client.section(agentChat, "memory")).includes("c2"), "and the agent is not given the chat's");
	step("a chat cannot remove or change an agent's note, and nothing it notes reaches an agent");

	// ---- The app's requests for chat mode's notes.
	const { id: added } = await client.call("memory.add", { chat: true, text: "  Lives near\n the sea  " });
	assert.equal(added, "c3");
	await client.until("added by hand", () => client.chatNotes().some((n) => n.id === "c3" && n.text === "Lives near\nthe sea" && n.conversation === null));
	await client.call("memory.edit", { chat: true, id: "c3", text: "Lives by the sea" });
	await client.until("edited", () => client.chatNotes().find((n) => n.id === "c3")?.text === "Lives by the sea");
	await assert.rejects(client.call("memory.edit", { chat: true, id: "m1", text: "x" }), /gone/, "an agent's note is not a chat's to edit");
	await assert.rejects(client.call("memory.add", { chat: true, agentId: forge.id, text: "x" }), /not both/);
	await assert.rejects(client.call("memory.add", { chat: "yes", text: "x" }), /chat must be true/);
	await assert.rejects(client.call("memory.setEnabled", { chat: true, enabled: false }), /chat\.set/);
	await client.call("memory.delete", { chat: true, id: "c2" });
	await client.until("deleted", () => client.chatNotes().length === 2 && !client.chatNotes().some((n) => n.id === "c2"));
	assert.equal(JSON.stringify(client.agentNotes(forge.id)), forgeBefore);
	step("the app adds, edits and deletes chat mode's notes, apart from the agents'");

	// ---- A chat continued as an agent's conversation (#289), in a project (#654), takes none of chat mode's notes with it.
	const { id: secret } = await client.call("memory.add", { chat: true, text: "Zephyrine is the name of the person's cat." });
	await client.until("the note to keep back", () => client.chatNotes().some((n) => n.id === secret));
	// Asked in another chat: the demo model answers /system with the prompt, which would put the note in this chat's answers.
	assert.match(await client.section(nextChat, "memory"), /Zephyrine/, "chats have it in their prompt");
	const { id: projectId } = await client.call("projects.create", { folder: null, name: "Lighthouse" });
	const { id: forgeCopy } = await client.call("projects.addAgent", { projectId, template: forge.id });
	await client.call("memory.add", { projectId, text: "The project is called Lighthouse." });
	const { id: continued } = await client.call("chat.continueWithAgent", { id: chat, projectId, agentId: forgeCopy, text: "Please carry on" });
	await client.call("conversation.open", { id: continued });
	await client.until("the continued conversation's first answer", () => {
		const conv = client.conversations.get(continued);
		return conv !== undefined && !conv.state.busy && conv.items.some((item: any) => item.kind === "assistant");
	});
	const continuedSeen = await client.offered(continued);
	assert.ok(!continuedSeen.tools.includes("agent_notes"), `the agent's conversation has no agent_notes: ${continuedSeen.tools.join(" ")}`);
	const continuedMemory = await client.section(continued, "memory");
	assert.match(continuedMemory, /The project is called Lighthouse/, "the agent has its project's notes");
	assert.ok(!/Zephyrine|Lives by the sea|c1|c3/.test(continuedMemory), "and none of chat mode's");
	assert.ok((await client.call("search", { query: "Please carry on" })).results.some((result: any) => result.conversationId === continued), "the search reaches the handed-over chat");
	assert.ok(!(await client.call("search", { query: "Zephyrine" })).results.some((result: any) => result.conversationId === continued), "no note of chat mode's is in what the agent was given");
	step("a chat continued with an agent gives it none of chat mode's notes");

	// ---- What the agents' notes would cost in every chat's prompt, against what chat mode sends instead.
	for (let i = client.agentNotes(forge.id).length; i < 60; i++) await client.call("memory.add", { agentId: forge.id, text: `Forge's note ${i}: ${"x".repeat(380)}` });
	await client.until("sixty notes", () => client.agentNotes(forge.id).length === 60);
	const full = (await client.offered(agentChat)).sizes.get("memory")!;
	const chatSeen = await client.offered(chat);
	const line = (await client.section(chat, "memory")).split("\n").find((text) => text.startsWith("The person's agents"))!.length;
	const tools = [...chatSeen.sizes].find(([key]) => key.startsWith("(tools:"))!;
	console.log(
		`    sizes: one agent's 60 notes, in its own prompt, ${full} characters; a chat's memory section ${chatSeen.sizes.get("memory")}, of which ${line} ` +
			`name the agents with notes; a chat's tools ${tools[1]} ${tools[0]}`,
	);
	assert.ok(line * 20 < full, "the line is a small part of what the notes would be");
	result = await client.tool(chat, "/tool agent_notes {}");
	assert.equal(result.isError, false);
	assert.equal((result.text.match(/\n- /g) ?? []).length, 60, "one agent's sixty notes are given whole");
	step("one agent's notes in full cost many times the line a chat is given about them");

	// ---- After a restart, the notes are still kept apart.
	await stop(engine, "SIGKILL");
	engine = start();
	client = await Client.connect(engine, home);
	await client.until("memory sent on connecting", () => client.events.memory?.chat?.notes?.length === 3);
	const later = await client.open({ chat: true });
	assert.match(await client.section(later, "memory"), /- c1: The person sails a boat called Petrel\.\n- c3: Lives by the sea/);
	const laterAgent = await client.open({ agentId: "forge" });
	await leaveOut(client);
	assert.ok(!/Petrel|by the sea/.test(await client.section(laterAgent, "memory")));
	step("after a restart, chat mode's notes are still its own");

	// ---- Memory off: nothing remembered, nothing read, its own or the agents'.
	await client.call("chat.set", { memory: false });
	seen = await client.offered(later);
	for (const name of CHAT_MEMORY_TOOLS) assert.ok(!seen.tools.includes(name), `no ${name} with memory off: ${seen.tools.join(" ")}`);
	assert.ok(!seen.sizes.has("memory"), "no memory section");
	const toolsOff = [...seen.sizes].find(([key]) => key.startsWith("(tools:"))!;
	console.log(`    sizes: a chat's tools with memory off ${toolsOff[1]} ${toolsOff[0]}; remember, forget and agent_notes add ${tools[1] - toolsOff[1]}`);
	result = await client.tool(later, '/tool remember {"note":"should not be kept"}');
	assert.ok(result.isError && !/Noted/.test(result.text), result.text);
	result = await client.tool(later, "/tool agent_notes {}");
	assert.ok(result.isError && !/Forge's note/.test(result.text), result.text);
	assert.equal(client.chatNotes().length, 3, "nothing was noted, and the notes are kept");
	assert.match(await client.section(later, "chat_instructions"), /Call me Captain/, "the instructions are not memory: they still count");
	await client.call("chat.set", { memory: true });
	assert.ok((await client.offered(later)).tools.includes("remember"), "on again, the tools come back at the next message");
	step("with memory off, a chat remembers nothing and reads nothing, and its notes are kept");

} finally {
	client.close();
	await stop(engine);
}
