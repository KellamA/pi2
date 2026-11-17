// Which tools, and which sections of the system prompt, a conversation is offered when they could do nothing in it
// (#177): no `computer` while computer use is on but no app is allowed, and no scheduling in a sub-chat. A real engine
// on a throwaway data folder, driven over its socket with the demo model.
//
// It also prints the size of the prompt and of the tool definitions, for a plain agent and for a sub-chat of an agent
// with computer use and scheduling on and no app allowed, which is what the pull request for #177 measured.

import assert from "node:assert/strict";
import { type ChildProcess, execFileSync, spawn } from "node:child_process";
import { mkdtempSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { EngineClient, stop } from "./patience.ts";

const home = mkdtempSync(join(tmpdir(), "pi2-off-"));
const scratch = realpathSync(mkdtempSync(join(tmpdir(), "pi2-off-work-")));
const main = join(import.meta.dirname, "..", "src", "main.ts");
const KEYCHAIN_SERVICE = `dev.pi2.credentials.test-offered-${process.pid}`;
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
	/** The tools offered, and the sections of the prompt with something in them, by name. */
	async offered(id: number): Promise<{ tools: string[]; sections: string[]; prompt: number; definitions: number }> {
		const sizes = (await this.answer(id, "/system sizes")).split("\n").slice(1);
		const parts = sizes.map((line) => [line.slice(0, line.lastIndexOf(" ")), Number(line.slice(line.lastIndexOf(" ") + 1))] as const);
		const answer = await this.answer(id, "/system none");
		return {
			tools: answer.slice(answer.lastIndexOf("\nTOOLS: ") + 8).split(", "),
			sections: parts.filter(([key]) => !key.startsWith("(")).map(([key]) => key),
			prompt: parts.filter(([key]) => !key.startsWith("(tools")).reduce((sum, [, size]) => sum + size, 0),
			definitions: parts.find(([key]) => key.startsWith("(tools"))![1],
		};
	}
}

engine = spawn(process.execPath, [main], { env, stdio: ["ignore", "ignore", "inherit"] });
const client = await Client.connect(engine, home);
try {
	await client.until("providers", () => client.events.providers);
	const agentOf = async (agent: Record<string, unknown>): Promise<string> => {
		const { id } = await client.call("agents.save", { agent });
		const apps = JSON.stringify((agent.computer as { apps?: string[] } | undefined)?.apps ?? []);
		await client.until(`agent ${agent.name}`, () =>
			client.events.agents?.agents?.some((x: any) => x.id === id && JSON.stringify(x.computer?.apps ?? []) === apps && (x.codeMode ?? false) === (agent.codeMode ?? false)),
		);
		return id;
	};
	const conversationOf = async (agentId: string): Promise<number> => {
		const { id } = await client.call("conversation.create", { agentId });
		await client.call("conversation.open", { id });
		return id;
	};
	const report = (name: string, seen: Awaited<ReturnType<Client["offered"]>>) =>
		console.log(`# ${name}: prompt ${seen.prompt} characters, ${seen.tools.length} tools in ${seen.definitions} characters\n#   sections: ${seen.sections.join(" ")}\n#   tools: ${seen.tools.join(" ")}`);

	const plain = await conversationOf(await agentOf({ name: "Plain", access: "full", cwd: scratch }));
	const worker = { name: "Worker", access: "full", cwd: scratch, computer: { enabled: true, apps: [] }, schedule: { enabled: true } };
	const workerId = await agentOf(worker);
	const lead = await conversationOf(await agentOf({ name: "Lead", access: "full", cwd: scratch, computer: { enabled: true, apps: [] }, schedule: { enabled: true }, delegates: [workerId] }));

	const plainSeen = await client.offered(plain);
	report("a plain agent", plainSeen);
	assert.ok(plainSeen.tools.includes("ask_user") && plainSeen.tools.includes("bash"), plainSeen.tools.join(" "));
	assert.ok(!plainSeen.tools.includes("computer") && !plainSeen.tools.includes("schedule_task"), plainSeen.tools.join(" "));
	step("a plain agent: no computer, no scheduling");

	// A conversation of its own, with computer use on and no app: scheduling yes, the computer no.
	const leadSeen = await client.offered(lead);
	report("an agent with computer use on, no app allowed, and scheduling on", leadSeen);
	assert.ok(!leadSeen.tools.includes("computer") && !leadSeen.sections.includes("computer_use"), `no app allowed, no computer:\n${leadSeen.tools.join(" ")}\n${leadSeen.sections.join(" ")}`);
	for (const name of ["schedule_task", "list_schedules", "cancel_schedule", "delegate"]) assert.ok(leadSeen.tools.includes(name), `${name}: ${leadSeen.tools.join(" ")}`);
	assert.ok(leadSeen.sections.includes("scheduling"));
	step("computer use on with no app allowed: no computer tool or section; scheduling as before");

	// A sub-chat of that agent's: neither the computer nor scheduling, but ask_user.
	const before = new Set((client.events.library?.conversations ?? []).map((x: any) => x.id));
	await client.answer(lead, "/delegate Worker: Hello");
	const sub = await client.until("the sub-chat", () => (client.events.library?.conversations ?? []).find((x: any) => x.parent === lead && !before.has(x.id))?.id as number | undefined);
	await client.call("conversation.open", { id: sub });
	const subSeen = await client.offered(sub);
	report("a sub-chat of an agent with computer use on, no app allowed, and scheduling on", subSeen);
	for (const name of ["computer", "schedule_task", "list_schedules", "cancel_schedule", "delegate"]) assert.ok(!subSeen.tools.includes(name), `${name} is not offered in a sub-chat: ${subSeen.tools.join(" ")}`);
	for (const key of ["computer_use", "scheduling", "agents"]) assert.ok(!subSeen.sections.includes(key), `no ${key} section in a sub-chat: ${subSeen.sections.join(" ")}`);
	assert.ok(subSeen.tools.includes("ask_user") && subSeen.tools.includes("bash") && subSeen.tools.includes("background"), subSeen.tools.join(" "));
	step("a sub-chat: no computer without an app, no scheduling, ask_user kept");

	// The person allows an app: the tool and its section come, in the conversation and its sub-chat, and are sent alone.
	const history = async (id: number) => (await client.answer(id, "/system history")).split("\n").slice(1);
	const was = await history(sub);
	await agentOf({ ...worker, id: workerId, computer: { enabled: true, apps: ["com.apple.Notes"] } });
	const allowed = await client.offered(sub);
	assert.ok(allowed.tools.includes("computer") && allowed.sections.includes("computer_use"), `an app allowed, the computer comes: ${allowed.tools.join(" ")}`);
	assert.ok(!allowed.tools.includes("schedule_task") && !allowed.sections.includes("scheduling"), "still no scheduling in the sub-chat");
	const came = (await history(sub)).slice(was.length);
	assert.deepEqual(came.join(" ").split(" ").filter((part) => part !== "").sort(), ["+tool:computer", `computer_use=${came.join(" ").match(/computer_use=(\d+)/)?.[1]}`].sort(), `only the computer is sent:\n${came.join("\n")}`);
	step("an app allowed: the computer tool and section come, sent alone");

	// And go again when the last app is taken away.
	await agentOf({ ...worker, id: workerId, computer: { enabled: true, apps: [] } });
	const gone = await client.offered(sub);
	assert.ok(!gone.tools.includes("computer") && !gone.sections.includes("computer_use"), `the last app taken away, the computer goes: ${gone.tools.join(" ")}`);
	step("the last app taken away: the computer goes");

	// Code mode lists what a script can call: neither the scheduling tools in a sub-chat nor the computer without an app.
	await agentOf({ ...worker, id: workerId, codeMode: true });
	const results = () => (client.conversations.get(sub)?.items ?? []).filter((item: any) => item.kind === "tool");
	await client.answer(sub, "/code text(ALL_TOOLS.map((tool) => tool.name).join(' '))");
	const listed = results().at(-1).text as string;
	assert.ok(listed.includes("bash") && !listed.includes("schedule_task") && !listed.includes("computer"), `a script in the sub-chat cannot call them either:\n${listed}`);
	step("a script in the sub-chat lists neither");
} finally {
	client.close();
	await stop(engine);
}
