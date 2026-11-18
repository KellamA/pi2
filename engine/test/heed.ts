// A message from the person while an agent waits (src/heed.ts, issue #295): a real engine on a throwaway data folder,
// driven over its socket with the demo model. A message sent to steer ends a wait on a sub-chat at once, and the sub-chat
// carries on and can be waited for again, or gives its answer later by itself, once; one sent during a command in the
// foreground comes after the command; both in one answer; a background read and a question to the person give way too;
// what the person is shown a message waits for; and Stop stops a sub-chat that was let go.
//
// Nothing here is timed. Each command the agents run waits for a file the test makes (a gate), and says it has started by
// making one of its own, so the test knows where every call stands however busy the Mac is.

import assert from "node:assert/strict";
import { type ChildProcess, spawn } from "node:child_process";
import { closeSync, existsSync, mkdtempSync, openSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { EngineClient, stop, until } from "./patience.ts";

const home = mkdtempSync(join(tmpdir(), "pi2-heed-"));
const scratch = realpathSync(mkdtempSync(join(tmpdir(), "pi2-heed-work-")));
const main = join(import.meta.dirname, "..", "src", "main.ts");
const engineLog = join(home, "engine.log");

function step(name: string): void {
	console.log(`ok  ${name}`);
}

type Event = Record<string, any>;
class Client extends EngineClient {
	items(id: number, kind?: string): Event[] {
		return (this.conversations.get(id)?.items ?? []).filter((item: Event) => kind === undefined || item.kind === kind);
	}
	state(id: number): Event | undefined {
		return this.conversations.get(id)?.state;
	}
	idle(id: number): boolean {
		return this.state(id)?.busy === false;
	}
	subChats(parent: number): Event[] {
		return (this.events.library?.conversations ?? []).filter((meta: Event) => meta.parent === parent);
	}
	/** The newest sub-chat of `parent`: the library lists them in no particular order. */
	newestSubChat(parent: number): number {
		return Math.max(...this.subChats(parent).map((meta) => meta.id as number));
	}
	/** Whether a conversation (a sub-chat too) is working, as the library says. */
	working(id: number): boolean {
		return (this.events.library?.conversations ?? []).some((meta: Event) => meta.id === id && meta.busy === true);
	}
	/** The newest answer's text, once the conversation is idle with at least `count` answers. */
	async answer(id: number, count: number): Promise<string> {
		return await this.until(`answer ${count} of conversation ${id}`, () => (this.idle(id) && this.items(id, "assistant").length >= count ? (this.items(id, "assistant").at(-1)!.text as string) : undefined));
	}
	/** Sends a message the demo model answers with a tool call, and returns that call's result once the answer is in. */
	async tool(id: number, text: string): Promise<Event> {
		const count = this.items(id, "tool").length + 1;
		const answers = this.items(id, "assistant").length;
		await this.call("submit", { id, text });
		return await this.until(`result of ${text}`, () => (this.idle(id) && this.items(id, "tool").length >= count && this.items(id, "assistant").length >= answers + 2 ? this.items(id, "tool")[count - 1] : undefined));
	}
}

let gates = 0;
/** A command that says it has started, then waits for the test to open its gate: `[command, open, started]`. */
function gated(says: string): [string, () => void, () => boolean] {
	const n = ++gates;
	const gate = join(scratch, `gate-${n}`);
	const started = join(scratch, `started-${n}`);
	// Asked for with a time limit far beyond the test's patience, so only the gate ends it.
	const command = `/timeout 600 touch '${started}'; while [ ! -e '${gate}' ]; do sleep 0.1; done; echo ${says}`;
	return [command, () => writeFileSync(gate, ""), () => existsSync(started)];
}

const log = openSync(engineLog, "a");
const engine: ChildProcess = spawn(process.execPath, [main], {
	env: { ...process.env, PI2_HOME: home, PI2_KEYCHAIN_SERVICE: "dev.pi2.credentials.test-heed", PI2_DEMO_TOKENS_PER_SECOND: "1000", PI2_LOGIN_SHELL: "off" },
	stdio: ["ignore", log, log],
});
closeSync(log);
let passed = false;
try {
	const client = await Client.connect(engine, home);
	await client.until("first events", () => client.events.agents && client.events.library);
	const { id: worker } = await client.call("agents.save", { agent: { name: "Worker", access: "full", cwd: scratch } });
	const { id: leadAgent } = await client.call("agents.save", { agent: { name: "Lead", access: "full", cwd: scratch, delegates: [worker] } });
	await client.until("the agents", () => client.events.agents.agents.some((agent: Event) => agent.id === leadAgent && agent.delegates.includes(worker)));
	const { id: lead } = await client.call("conversation.create", { agentId: leadAgent });
	await client.call("conversation.open", { id: lead });
	await client.until("the conversation", () => client.state(lead));
	const steer = (text: string) => client.call("submit", { id: lead, text, mode: "steer" });
	const userTexts = () => client.items(lead).filter((item) => item.kind === "user").map((item) => item.text as string);

	// ---- A message during a wait on a sub-chat arrives at once; the sub-chat carries on and is waited for again

	const [first, openFirst, firstStarted] = gated("released-one");
	await client.call("submit", { id: lead, text: `/delegate Worker: ${first}` });
	await until("the sub-chat's command to start", firstStarted);
	const chat = client.newestSubChat(lead);
	const waits = await client.until("what a message would wait for", () => {
		const said = client.state(lead)?.messageWaits;
		return said?.ends?.length > 0 ? said : undefined;
	});
	assert.deepEqual(waits, { holds: [], ends: [`the wait for Worker's sub-chat ${chat}`] }, "a message now would end the wait, and wait for nothing");
	await steer("hello while you wait");
	const letGo = await client.until("the message answered", () => (client.idle(lead) && client.items(lead, "assistant").at(-1)?.text?.includes("hello while you wait") ? client.items(lead, "tool")[0] : undefined));
	assert.equal(letGo.details?.waitEnded, true, JSON.stringify(letGo));
	assert.equal(letGo.isError, false);
	assert.match(letGo.text, new RegExp(`stopped waiting for sub-chat ${chat} .*nothing was stopped.*chat: ${chat} and no task`, "s"));
	assert.ok(client.working(chat), "the sub-chat is still working");
	assert.ok(!existsSync(join(scratch, "gate-1")), "and its command is still waiting for its gate");
	step("a message during a wait on a sub-chat reaches the agent at once, and the sub-chat carries on");

	// Waited for again: its answer comes back to the call, and is not added to the conversation as well.
	const answers = client.items(lead, "assistant").length;
	await client.call("submit", { id: lead, text: `/tool delegate ${JSON.stringify({ agent: "", chat })}` });
	await client.until("the wait again", () => client.state(lead)?.messageWaits?.ends?.length > 0);
	openFirst();
	const again = (await client.until("the answer waited for again", () => (client.idle(lead) && client.items(lead, "assistant").length >= answers + 2 ? client.items(lead, "tool")[1] : undefined))) as Event;
	assert.equal(again.isError, false, again.text);
	assert.match(again.text, /released-one/);
	assert.deepEqual(client.items(lead, "marker"), [], "nothing was added to the conversation besides");
	const owesNothing = await client.tool(lead, `/tool delegate ${JSON.stringify({ agent: "", chat })}`);
	assert.equal(owesNothing.isError, true);
	assert.match(owesNothing.text, /owes you no answer/);
	assert.match((await client.tool(lead, `/tool delegate ${JSON.stringify({ agent: "Worker" })}`)).text, /`task` says what to hand over/);
	step("a sub-chat let go is waited for again with chat and no task, and its answer is given once");

	// ---- Not waited for again: its answer is added to the conversation when it comes, once

	const [second, openSecond, secondStarted] = gated("released-two");
	await client.call("submit", { id: lead, text: `/delegate Worker: ${second}` });
	await until("the second sub-chat's command to start", secondStarted);
	const secondChat = client.newestSubChat(lead);
	await client.until("its wait", () => client.state(lead)?.messageWaits?.ends?.length > 0);
	await steer("never mind it");
	await client.until("the message answered", () => client.idle(lead) && client.items(lead, "assistant").at(-1)?.text?.includes("never mind it"));
	openSecond();
	const marker = await client.until("the late answer added", () => client.items(lead, "marker").find((item) => item.text.includes(`Sub-chat ${secondChat}`)));
	assert.match(marker.text, /answered after the agent stopped waiting for it/);
	await client.until("the sub-chat idle", () => !client.working(secondChat));
	const owed = await client.tool(lead, `/tool delegate ${JSON.stringify({ agent: "", chat: secondChat })}`);
	assert.match(owed.text, /owes you no answer/, "the answer was given once, by being added");
	assert.equal(client.items(lead, "marker").filter((item) => item.text.includes(`Sub-chat ${secondChat}`)).length, 1);
	step("a sub-chat's answer that nobody waits for is added to the conversation when it comes, once");

	// ---- A message during a command in the foreground arrives after the command

	const [command, openCommand, commandStarted] = gated("command-done");
	await client.call("submit", { id: lead, text: command });
	await until("the command to start", commandStarted);
	const holds = await client.until("what a message would wait for", () => client.state(lead)?.messageWaits?.holds?.[0]);
	assert.match(holds, /^the command `touch /);
	await steer("after the command");
	const queued = await client.until("the message queued", () => client.state(lead)?.queued?.[0]);
	assert.equal(queued.mode, "steer");
	assert.ok(!userTexts().includes("after the command"), "the message waits while the command runs");
	assert.ok(client.state(lead)!.busy);
	openCommand();
	await client.until("the message answered", () => client.idle(lead) && client.items(lead, "assistant").at(-1)?.text?.includes("after the command"));
	const items = client.items(lead);
	const result = items.findIndex((item) => item.kind === "tool" && item.text.includes("command-done"));
	const message = items.findIndex((item) => item.kind === "user" && item.text === "after the command");
	assert.ok(result >= 0 && message > result, "the message is placed after the command's result");
	step("a message during a command in the foreground reaches the agent once the command has ended");

	// ---- Both in one answer: the command holds the message; the wait after it does not

	const [third, openThird, thirdStarted] = gated("released-three");
	const [held, openHeld, heldStarted] = gated("held-done");
	const calls = [
		{ name: "bash", arguments: { command: held.replace(/^\/timeout 600 /, ""), timeout: 600 } },
		{ name: "delegate", arguments: { agent: "Worker", task: third } },
	];
	const toolsBefore = client.items(lead, "tool").length;
	await client.call("submit", { id: lead, text: `/tools ${JSON.stringify(calls)}` });
	await until("the command to start", heldStarted);
	await steer("after both");
	await client.until("the message queued", () => client.state(lead)?.queued?.length === 1);
	openHeld();
	await client.until("the message answered", () => client.idle(lead) && client.items(lead, "assistant").at(-1)?.text?.includes("after both"));
	const [ran, handed] = client.items(lead, "tool").slice(toolsBefore);
	assert.match(ran!.text, /held-done/);
	assert.equal(handed!.details?.waitEnded, true, "the sub-chat started after the command was handed its task and not waited for");
	await until("the third sub-chat's command to start", thirdStarted);
	const thirdChat = handed!.details.conversationId as number;
	assert.ok(client.working(thirdChat));
	openThird();
	await client.until("its late answer added", () => client.items(lead, "marker").some((item) => item.text.includes(`Sub-chat ${thirdChat}`)));
	step("with a command and a sub-chat in one answer, the message waits for the command only");

	// ---- A background read with wait, and a question to the person, give way too

	const [bg, openBg] = gated("bg-done");
	const startedBg = await client.tool(lead, `/background ${bg.replace(/^\/timeout 600 /, "")}`);
	const bgId = startedBg.details.background.id as string;
	const reads = client.items(lead, "tool").length;
	await client.call("submit", { id: lead, text: `/tool background ${JSON.stringify({ action: "read", id: bgId, wait: 200 })}` });
	await client.until("the read's wait", () => client.state(lead)?.messageWaits?.ends?.[0] === `the wait for ${bgId}`);
	await steer("stop reading");
	await client.until("the message answered", () => client.idle(lead) && client.items(lead, "assistant").at(-1)?.text?.includes("stop reading"));
	const read = client.items(lead, "tool")[reads]!;
	assert.equal(read.details?.waitEnded, true);
	assert.match(read.text, new RegExp(`stopped waiting.*${bgId} is still running`, "s"));
	openBg();

	const asked = client.items(lead, "tool").length;
	await client.call("submit", { id: lead, text: "/ask Which colour?" });
	await client.until("the question", () => (client.events.inbox?.items ?? []).some((item: Event) => item.conversationId === lead));
	await steer("I will tell you later");
	await client.until("the message answered", () => client.idle(lead) && client.items(lead, "assistant").at(-1)?.text?.includes("I will tell you later"));
	assert.match(client.items(lead, "tool")[asked]!.text, /sent you a message instead of answering/);
	assert.ok(!(client.events.inbox?.items ?? []).some((item: Event) => item.conversationId === lead), "the question is taken away");
	step("a background read with wait, and a question to the person, stop waiting for a message");

	// ---- Stop stops a sub-chat that was let go, and its end is added as owed

	const [fourth, , fourthStarted] = gated("never");
	await client.call("submit", { id: lead, text: `/delegate Worker: ${fourth}` });
	await until("the fourth sub-chat's command to start", fourthStarted);
	const fourthChat = client.newestSubChat(lead);
	await client.until("its wait", () => client.state(lead)?.messageWaits?.ends?.length > 0);
	await steer("go on without it");
	await client.until("the message answered", () => client.idle(lead) && client.items(lead, "assistant").at(-1)?.text?.includes("go on without it"));
	assert.ok(client.working(fourthChat));
	await client.call("abort", { id: lead });
	const stopped = await client.until("the stopped sub-chat's end added", () => client.items(lead, "marker").find((item) => item.text.includes(`Sub-chat ${fourthChat}`)));
	assert.match(stopped.text, /ended without an answer/);
	await client.until("the sub-chat stopped", () => !client.working(fourthChat));
	step("Stop stops the sub-chats a message let go on, and the agent is told they did not finish");

	console.log("PASS");
	passed = true;
} finally {
	await stop(engine);
	// Every gate opened, so no command here outlives the test whatever failed.
	for (let n = 1; n <= gates; n++) writeFileSync(join(scratch, `gate-${n}`), "");
	if (!passed && existsSync(engineLog)) process.stderr.write(readFileSync(engineLog, "utf8"));
	rmSync(home, { recursive: true, force: true });
	rmSync(scratch, { recursive: true, force: true });
}
process.exit(passed ? 0 : 1);
