// A section of the system prompt, or a tool, that comes or goes in the middle of a conversation is sent on its own, and
// the rest of the prompt is not sent again (#186; src/sections.ts, `keepingOrder` in src/main.ts). A real engine on a
// throwaway data folder, driven over its socket with the demo model, whose `/system history` answers with what each
// system message of the conversation set, removed, added and took away.
//
// pi durable sends again every section, or every tool, when what changed would leave them in another order than the
// agent's. The agent's instructions come last, so before #186 any section that arrived after the first message, such as
// background_commands at the first background command, had the whole prompt sent again.
//
// The built-in tools an agent's settings leave out (#221) are taken away, and come back, in the same way.

import assert from "node:assert/strict";
import { type ChildProcess, execFileSync, spawn } from "node:child_process";
import { mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { EngineClient, stop } from "./patience.ts";

const home = mkdtempSync(join(tmpdir(), "pi2-sec-"));
const scratch = realpathSync(mkdtempSync(join(tmpdir(), "pi2-sec-work-")));
const main = join(import.meta.dirname, "..", "src", "main.ts");
const KEYCHAIN_SERVICE = `dev.pi2.credentials.test-sections-${process.pid}`;
process.env.PI2_DEMO_TOKENS_PER_SECOND ??= "100000";
process.env.PI2_LOGIN_SHELL ??= "off";
const env = { ...process.env, PI2_HOME: home, PI2_KEYCHAIN_SERVICE: KEYCHAIN_SERVICE };

let engine: ChildProcess | undefined;
process.on("exit", () => {
	if (engine !== undefined && engine.exitCode === null && engine.signalCode === null) engine.kill("SIGKILL");
	rmSync(home, { recursive: true, force: true });
	rmSync(scratch, { recursive: true, force: true });
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
}

engine = spawn(process.execPath, [main], { env, stdio: ["ignore", "ignore", "inherit"] });
const client = await Client.connect(engine, home);
try {
	await client.until("providers", () => client.events.providers);
	const agentOf = async (agent: Record<string, unknown>): Promise<string> => {
		const { id } = await client.call("agents.save", { agent });
		const off = JSON.stringify(agent.toolsOff ?? []);
		await client.until(`agent ${agent.name}`, () => client.events.agents?.agents?.some((x: any) => x.id === id && x.name === agent.name && JSON.stringify(x.toolsOff ?? []) === off));
		return id;
	};
	const helper = await agentOf({ name: "Helper", description: "Helps." });
	const profile = { name: "Arrivals", access: "full", cwd: scratch, instructions: "Answer in one line." };
	const agent = await agentOf(profile);
	const { id } = await client.call("conversation.create", { agentId: agent });
	await client.call("conversation.open", { id });

	/** The system messages of the conversation so far, one line each, as the demo model was sent them. */
	const history = async () => (await client.answer(id, "/system history")).split("\n").slice(1);
	await client.answer(id, "Hello");
	let seen = await history();
	assert.equal(seen.length, 1, `the first request sends the prompt once:\n${seen.join("\n")}`);
	assert.match(seen[0]!, /(^| )instructions=/, "the agent's instructions are shown, last");
	assert.match(seen[0]!, / \+tool:bash/, "and the tools");
	console.log(`# the first system message: ${seen[0]}`);

	/**
	 * Since the last look, only `keys` (sections) and `tools` changed: no other section or tool was removed or sent
	 * again. Something must have changed, unless `changes` is false.
	 */
	const onlyChanged = async (what: string, keys: string[], tools: string[], changes = true) => {
		const now = await history();
		const added = now.slice(seen.length);
		seen = now;
		if (changes) assert.ok(added.length > 0, `${what}: the prompt changed`);
		for (const line of added) {
			for (const part of line.split(" ").filter((part) => part !== "")) {
				const name = part.replace(/^[-+]?(tool:)?/, "").replace(/=\d+$/, "");
				const allowed = part.includes("tool:") ? tools : keys;
				assert.ok(allowed.includes(name), `${what}: only ${[...keys, ...tools].join(", ")} change, but a system message has ${part}:\n${added.join("\n")}`);
			}
		}
		console.log(`# ${what}: ${added.join(" | ")}`);
		step(what);
	};

	await client.answer(id, "/background echo from-the-background");
	await onlyChanged("a first background command sends background_commands alone", ["background_commands"], []);

	writeFileSync(join(scratch, "AGENTS.md"), "Keep it short.\n");
	await client.answer(id, "Again");
	await onlyChanged("a project instructions file that appears sends project_instructions alone", ["project_instructions"], []);

	await agentOf({ ...profile, id: agent, codeMode: true });
	await client.answer(id, "Again");
	await onlyChanged("code mode switched on sends codemode and its tool alone", ["codemode"], ["codemode"]);

	await agentOf({ ...profile, id: agent, codeMode: true, schedule: { enabled: true } });
	await client.answer(id, "Again");
	await onlyChanged("scheduling switched on sends its section and tools alone", ["scheduling", "codemode"], ["schedule_task", "list_schedules", "cancel_schedule"]);

	await agentOf({ ...profile, id: agent, codeMode: true, schedule: { enabled: true }, computer: { enabled: true, apps: ["com.apple.Notes"] } });
	await client.answer(id, "Again");
	await onlyChanged("computer use switched on sends its section and tool alone", ["computer_use", "codemode"], ["computer"]);

	await agentOf({ ...profile, id: agent, codeMode: true, schedule: { enabled: true }, computer: { enabled: true, apps: ["com.apple.Notes"] }, browser: { enabled: true } });
	await client.answer(id, "Again");
	await onlyChanged("the browser switched on sends its sections and tools alone", ["browser", "look_web", "codemode"], ["browser", "web_fetch", "web_search"]);

	const everything = { ...profile, id: agent, codeMode: true, schedule: { enabled: true }, computer: { enabled: true, apps: ["com.apple.Notes"] }, browser: { enabled: true }, delegates: [helper] };
	await agentOf(everything);
	await client.answer(id, "Again");
	await onlyChanged("another agent to hand work to sends the agents section and its tools alone", ["agents", "codemode"], ["delegate", "sub_chats"]);

	await client.call("memory.setEnabled", { agentId: agent, enabled: true });
	await client.answer(id, "Again");
	await onlyChanged("memory switched on sends its section and tools alone", ["memory", "codemode"], ["remember", "forget"]);

	// Going, and coming back: a section with nothing to say keeps its place, so its return is sent on its own too.
	await agentOf({ ...everything, codeMode: false });
	await client.answer(id, "Again");
	await onlyChanged("code mode switched off removes only codemode and its tool", ["codemode"], ["codemode"]);
	await agentOf(everything);
	await client.answer(id, "Again");
	await onlyChanged("code mode switched on again sends codemode and its tool alone", ["codemode"], ["codemode"]);

	// Built-in tools left out in the agent's settings, one at a time (#221), and all of them back: each change is sent alone.
	const leavingOut: [string, string[], string[]][] = [
		["files", [], ["list_files", "find_files", "search_files"]],
		["documents", ["documents"], ["write_document"]],
		["ask", [], ["ask_user"]],
		["plan", ["task_list"], ["update_plan"]],
		["web", ["look_web"], ["web_fetch", "web_search"]],
	];
	const off: string[] = [];
	for (const [key, sections, tools] of leavingOut) {
		off.push(key);
		await agentOf({ ...everything, toolsOff: off });
		await client.answer(id, "Again");
		await onlyChanged(`${key} left out takes away only ${[...sections, ...tools].join(", ")}`, [...sections, "codemode"], tools);
	}
	await agentOf({ ...everything, toolsOff: [] });
	await client.answer(id, "Again");
	await onlyChanged(
		"every built-in tool back sends only those tools and their sections",
		[...leavingOut.flatMap(([, sections]) => sections), "codemode"],
		leavingOut.flatMap(([, , tools]) => tools),
	);

	await client.answer(id, "Nothing changed");
	await onlyChanged("a message that changes nothing sends nothing", [], [], false);

	// Nothing above was sent as a whole prompt again: every section the conversation has was sent once at the start, and
	// then only when it changed. The empty sections that hold a place are not sent to the model at all.
	const sizes = (await client.answer(id, "/system sizes")).split("\n").slice(1);
	assert.ok(sizes.every((line) => line.startsWith("(base)") || !/ 0$/.test(line)), `no empty section reaches the model:\n${sizes.join("\n")}`);
	console.log(`# at the end:\n#   ${sizes.join("\n#   ")}`);

	// A chat's web switch (#287), turned off and on in the middle of the chat: the web's section and tools go and come
	// back, and the chat's own section says so, each on its own.
	const { id: chat } = await client.call("conversation.create", { chat: true });
	await client.call("conversation.open", { id: chat });
	const chatHistory = async () => (await client.answer(chat, "/system history")).split("\n").slice(1);
	await client.answer(chat, "Hello");
	let chatSeen = await chatHistory();
	assert.equal(chatSeen.length, 1, `a chat's first request sends the prompt once:\n${chatSeen.join("\n")}`);
	assert.match(chatSeen[0]!, / \+tool:web_fetch/);
	const chatChanged = async (what: string, keys: string[], tools: string[]) => {
		const now = await chatHistory();
		const added = now.slice(chatSeen.length);
		chatSeen = now;
		assert.ok(added.length > 0, `${what}: the prompt changed`);
		for (const part of added.flatMap((line) => line.split(" ")).filter((part) => part !== "")) {
			const name = part.replace(/^[-+]?(tool:)?/, "").replace(/=\d+$/, "");
			assert.ok((part.includes("tool:") ? tools : keys).includes(name), `${what}: only ${[...keys, ...tools].join(", ")} change, but a system message has ${part}:\n${added.join("\n")}`);
		}
		console.log(`# ${what}: ${added.join(" | ")}`);
		step(what);
	};
	await client.call("conversation.configure", { id: chat, web: false });
	await client.answer(chat, "Again");
	await chatChanged("a chat's web switched off takes away only the web and changes the chat section", ["look_web", "chat"], ["web_fetch", "web_search"]);
	await client.call("conversation.configure", { id: chat, web: true });
	await client.answer(chat, "Again");
	await chatChanged("a chat's web switched on again sends only the web and the chat section", ["look_web", "chat"], ["web_fetch", "web_search"]);
} finally {
	client.close();
	await stop(engine);
}
