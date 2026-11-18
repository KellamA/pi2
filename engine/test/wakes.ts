// Waking an agent that is not answering (src/wakes.ts, issues #158 and #104): a real engine on a throwaway data folder,
// driven over its socket with the demo model. A sub-chat handed work with `delegate` and `wait: false`, and a command
// started with `bash`, `background: true` and `wake: true`, wake the agent when they end; several that end while it is
// answering come together when the answer ends; `sub_chats` with `wait` takes the next one instead. Then each bound: the
// turn limit, Ask first, the daily budget, the hourly cap, the person's Stop and "Don't wake", an archived or deleted
// conversation, and an engine that stops and starts again.

import assert from "node:assert/strict";
import { type ChildProcess, spawn } from "node:child_process";
import { closeSync, existsSync, mkdirSync, mkdtempSync, openSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { wakeMarker, wakeMarkerDetails, wakeNoteMarker } from "../src/wakes.ts";
import { EngineClient, exited, running, stop } from "./patience.ts";

const home = mkdtempSync(join(tmpdir(), "pi2-wake-"));
const scratch = realpathSync(mkdtempSync(join(tmpdir(), "pi2-wake-work-")));
const main = join(import.meta.dirname, "..", "src", "main.ts");
process.env.PI2_DEMO_TOKENS_PER_SECOND ??= "1000";
process.env.PI2_LOGIN_SHELL ??= "off";
/** The hourly cap, made small enough to reach. */
const CAP = 3;
const env = { ...process.env, PI2_HOME: home, PI2_KEYCHAIN_SERVICE: "dev.pi2.credentials.test-wakes", PI2_WAKES_PER_HOUR: String(CAP), PI2_DEMO_COST: "5" };
const engineLog = join(home, "engine.log");

function step(name: string): void {
	console.log(`ok  ${name}`);
}

// ---- Words, without the engine

assert.equal(wakeMarker({ items: [{ kind: "subchat", ref: "12", label: "sub-chat 12 “Fix login”", ended: "answered" }] }), "pi² woke the agent: sub-chat 12 “Fix login” answered");
assert.equal(wakeMarker(null), "pi² woke the agent");
assert.deepEqual(wakeMarkerDetails({ items: [{ kind: "background", ref: "bg-3", label: "background command bg-3", ended: "finished" }] }), { background: { id: "bg-3" } });
assert.equal(wakeMarkerDetails({ items: [{ kind: "subchat", ref: "12", label: "x", ended: "answered" }] }), undefined);
assert.match(wakeNoteMarker({ held: "stopped" }), /^You stopped the agent/);
assert.match(wakeNoteMarker({ held: "cap", perHour: 30, until: Date.now() }), /30 times in the last hour/);
assert.match(wakeNoteMarker({ dropped: "archived", items: [{ label: "sub-chat 4", ended: null }] }), /archived, so pi² will not wake the agent for sub-chat 4/);
step("the transcript's lines read as expected");

// ---- The engine

type Event = Record<string, any>;
class Client extends EngineClient {
	static async attach(engine: ChildProcess): Promise<Client> {
		const client = await Client.connect(engine, home);
		await client.until("first events", () => client.events.providers && client.events.wakes);
		return client;
	}
	items(id: number, kind: string): Event[] {
		return this.conversations.get(id)?.items.filter((item: Event) => item.kind === kind) ?? [];
	}
	markers(id: number): string[] {
		return this.items(id, "marker").map((item) => item.text as string);
	}
	wakes(id: number): string[] {
		return this.markers(id).filter((text) => text.startsWith("pi² woke the agent"));
	}
	/** What the engine says a conversation will be woken for. */
	watched(id: number): Event[] {
		return (this.events.wakes?.items ?? []).filter((item: Event) => item.conversationId === id);
	}
	idle(id: number): boolean {
		const conv = this.conversations.get(id);
		return conv !== undefined && !conv.state.busy;
	}
	/** Sends a message the demo model answers with a tool call, and returns that call's result once the answer is in. */
	async tool(id: number, text: string): Promise<Event> {
		const count = this.items(id, "tool").length + 1;
		await this.call("submit", { id, text });
		return await this.until(`result of ${text}`, () => {
			const conv = this.conversations.get(id);
			const results = this.items(id, "tool");
			if (conv === undefined || conv.state.busy || results.length < count) return undefined;
			const after = conv.items.slice(conv.items.indexOf(results[count - 1]) + 1);
			return after.some((item: Event) => item.kind === "assistant") ? results[count - 1] : undefined;
		});
	}
	/** Waits for the agent to have been woken `count` times in all, and for that answer to be over. */
	async woken(id: number, count: number): Promise<string> {
		await this.until(`wake ${count} of conversation ${id}`, () => this.wakes(id).length >= count && this.idle(id));
		assert.equal(this.wakes(id).length, count, `woken exactly ${count} times: ${JSON.stringify(this.wakes(id))}`);
		return this.wakes(id)[count - 1]!;
	}
}

/** Every command here waits for a file of its own, or for the one that lets them all go when the test ends. */
const all = join(scratch, "all-gates");
let gates = 0;
const gate = (): { path: string; open: () => void; wait: string } => {
	const path = join(scratch, `gate-${++gates}`);
	return { path, open: () => writeFileSync(path, ""), wait: `until [ -e '${path}' ] || [ -e '${all}' ]; do sleep 0.05; done` };
};
const work = join(scratch, "work");
mkdirSync(work);

const boot = () => {
	const log = openSync(engineLog, "a");
	try {
		return spawn(process.execPath, [main], { env, stdio: ["ignore", "ignore", log] });
	} finally {
		closeSync(log);
	}
};
let passed = false;
let engine: ChildProcess = boot();
try {
	let client = await Client.attach(engine);
	const save = async (agent: Record<string, unknown>): Promise<string> => (await client.call("agents.save", { agent })).id;
	const open = async (agentId: string): Promise<number> => {
		const { id } = await client.call("conversation.create", { agentId });
		await client.call("conversation.open", { id });
		await client.until("conversation open", () => client.conversations.get(id)?.state !== undefined);
		return id;
	};
	const worker = await save({ name: "Worker", description: "Does the work", access: "full", cwd: work });
	const lead = await save({ name: "Lead", description: "Hands out work", access: "full", cwd: work, delegates: [worker] });
	/** Hands `task` to a new sub-chat without waiting; returns the sub-chat's number. */
	const handOff = async (id: number, task: string, title: string): Promise<number> => {
		const result = await client.tool(id, `/tool delegate ${JSON.stringify({ agent: "Worker", task, title, wait: false })}`);
		assert.equal(result.isError, false, result.text);
		assert.match(result.text, /is working on it\. Its answer will come to you as a message/);
		return result.details.conversationId as number;
	};
	/** A sub-chat task: a command that waits for `g`, then says `word`. */
	const task = (g: { wait: string }, word: string) => `/timeout 600 ${g.wait}; echo ${word}`;
	/** Starts a command in the background that wakes the agent when it ends; returns its id. */
	const startWaking = async (id: number, command: string): Promise<string> => {
		const result = await client.tool(id, `/tool bash ${JSON.stringify({ command, background: true, wake: true })}`);
		assert.equal(result.isError, false, result.text);
		return result.details.background.id as string;
	};

	// ---- delegate with wait: false
	{
		const a = await open(lead);
		const g = gate();
		const sub = await handOff(a, task(g, "first-done"), "One");
		assert.ok(client.idle(a), "the call returned while the sub-chat works, and the agent's answer is over");
		await client.until("the engine says the agent will be woken for it", () => client.watched(a).some((item) => item.kind === "subchat" && item.ref === String(sub) && item.state === "running"));
		assert.equal(client.events.library.conversations.find((x: Event) => x.id === sub)?.parent, a, "the sub-chat is listed under its conversation");
		g.open();
		const line = await client.woken(a, 1);
		assert.equal(line, `pi² woke the agent: sub-chat ${sub} “One” answered`);
		const answer = client.items(a, "assistant").at(-1)!.text as string;
		assert.match(answer, /\[pi² woke you: this ended while you were not answering\.\]/, "the woken answer answers the sub-chat's result");
		assert.match(answer, /first-done/, "with the sub-chat's answer in it");
		assert.match(answer, new RegExp(`chat: ${sub}`), "and how to carry it on");
		assert.deepEqual(client.watched(a), [], "nothing left to wake it for");
		step("delegate with wait: false returns at once; the sub-chat's answer wakes the agent, with what delegate would have answered");

		// Two that end while the agent is answering come together, oldest first, when the answer ends.
		const g2 = gate();
		const g3 = gate();
		const busy = gate();
		const two = await handOff(a, task(g2, "second-done"), "Two");
		const three = await handOff(a, task(g3, "third-done"), "Three");
		await client.call("submit", { id: a, text: `/timeout 600 ${busy.wait}` });
		await client.until("the agent answering", () => client.conversations.get(a)!.state.busy);
		g2.open();
		await client.until("the second arrived", () => client.watched(a).some((item) => item.ref === String(two) && item.state === "arrived"));
		g3.open();
		await client.until("the third arrived", () => client.watched(a).some((item) => item.ref === String(three) && item.state === "arrived"));
		assert.equal(client.wakes(a).length, 1, "not woken while answering");
		busy.open();
		const both = await client.woken(a, 2);
		assert.equal(both, `pi² woke the agent: sub-chat ${two} “Two” answered; sub-chat ${three} “Three” answered`);
		const together = client.items(a, "assistant").at(-1)!.text as string;
		assert.match(together, /these 2 ended while you were not answering, oldest first/);
		assert.ok(together.indexOf("second-done") < together.indexOf("third-done"), "oldest first");
		step("what ends while the agent answers comes when the answer ends, together and oldest first");

		// sub_chats wait takes the next one to finish, whichever it is, without a wake.
		const g4 = gate();
		const g5 = gate();
		const four = await handOff(a, task(g4, "fourth-done"), "Four");
		const five = await handOff(a, task(g5, "fifth-done"), "Five");
		const listed = await client.tool(a, `/tool sub_chats ${JSON.stringify({ action: "list" })}`);
		assert.match(listed.text, new RegExp(`- ${four}: Worker, “Four”\\. Working, and its answer will come to you as a message`));
		const waiting = client.tool(a, `/tool sub_chats ${JSON.stringify({ action: "wait" })}`);
		await client.until("the agent waiting", () => client.conversations.get(a)!.state.busy);
		g5.open();
		const next = await waiting;
		assert.match(next.text, new RegExp(`^Sub-chat ${five} “Five” answered:`), next.text);
		assert.match(next.text, /fifth-done/);
		assert.doesNotMatch(next.text, /fourth-done/);
		const later = client.tool(a, `/tool sub_chats ${JSON.stringify({ action: "wait", chats: [four] })}`);
		g4.open();
		assert.match((await later).text, /fourth-done/);
		assert.match((await client.tool(a, `/tool sub_chats ${JSON.stringify({ action: "wait" })}`)).text, /nothing to wait for/);
		assert.equal(client.wakes(a).length, 2, "what wait took did not wake the agent as well");
		step("sub_chats with wait gets the next sub-chat to finish, whichever it is, and the agent is not woken for it");
	}

	// ---- A command in the background with wake: true
	{
		const b = await open(lead);
		const g = gate();
		const bg = await startWaking(b, `${g.wait}; echo '/bash echo woken-by-${"bg"}'`);
		assert.ok(client.watched(b).some((item) => item.kind === "background" && item.ref === bg));
		g.open();
		const line = await client.woken(b, 1);
		assert.match(line, new RegExp(`^pi² woke the agent: background command ${bg} \\(\`until .*\`\\) finished$`));
		assert.deepEqual(client.items(b, "marker").find((item) => item.text === line)?.details, { background: { id: bg } }, "the line opens the command's output");
		const results = client.items(b, "tool");
		assert.equal(results.at(-1)!.name, "bash");
		assert.match(results.at(-1)!.text, /woken-by-bg/, "the woken agent acted on what the command printed");
		// One the agent stops, or whose end the call that started it reported, does not wake it.
		const stopped = await startWaking(b, "sleep 600");
		await client.tool(b, `/tool background ${JSON.stringify({ action: "stop", id: stopped })}`);
		const quick = await client.tool(b, `/tool bash ${JSON.stringify({ command: "true", background: true, wake: true })}`);
		await client.until("nothing watched", () => client.watched(b).length === 0);
		assert.equal(client.wakes(b).length, 1, `neither the one it stopped nor ${quick.details.background.id} woke it`);
		// A sub-chat is not woken: its answers go to the agent that handed it the work.
		const sub = await client.tool(b, `/tool delegate ${JSON.stringify({ agent: "Worker", task: `/tool bash ${JSON.stringify({ command: "true", background: true, wake: true })}` })}`);
		assert.match(sub.text, /The tool reported an error/);
		step("a background command started with wake: true wakes the agent when it ends, with how and the end of its output; not when it was stopped by the agent or seen to end, nor in a sub-chat");
	}

	// ---- The turn limit
	{
		const limited = await save({ name: "Limited", description: "One turn", access: "full", cwd: work, maxTurns: 1 });
		const c = await open(limited);
		const g = gate();
		// One turn: the call that starts the command is as far as the first answer gets.
		await client.call("submit", { id: c, text: `/tool bash ${JSON.stringify({ command: `${g.wait}; echo '/bash echo past-the-limit'`, background: true, wake: true })}` });
		await client.until("started, and stopped at the limit", () => client.items(c, "tool").length === 1 && client.idle(c) && client.conversations.get(c)!.state.failure?.reason === "turn_limit");
		g.open();
		await client.woken(c, 1);
		await client.until("the woken run's command", () => client.items(c, "tool").some((item) => /past-the-limit/.test(item.text)) && client.idle(c));
		assert.equal(client.conversations.get(c)!.state.failure?.reason, "turn_limit", "the woken run stopped at its turn limit");
		assert.equal(client.conversations.get(c)!.items.at(-1)!.kind, "tool", "with no answer after its one turn");
		step("a wake counts against the turn limit like any answer");
	}

	// ---- Ask first
	{
		const asker = await save({ name: "Asker", description: "Asks first", access: "ask", cwd: work });
		const d = await open(asker);
		const g = gate();
		const count = client.items(d, "tool").length + 1;
		await client.call("submit", { id: d, text: `/tool bash ${JSON.stringify({ command: `${g.wait}; echo '/bash echo needs-approval'`, background: true, wake: true })}` });
		const start = await client.until("asked to start it", () => (client.events.inbox?.items ?? []).find((item: Event) => item.conversationId === d));
		await client.call("inbox.decide", { id: start.id, decision: "once" });
		await client.until("started", () => client.items(d, "tool").length >= count && client.idle(d));
		g.open();
		const asked = await client.until("the woken answer's command asked about", () => (client.events.inbox?.items ?? []).find((item: Event) => item.conversationId === d && item.arguments?.command === "echo needs-approval"));
		assert.equal(asked.kind, "approval");
		await client.call("inbox.decide", { id: asked.id, decision: "deny" });
		await client.until("declined", () => client.idle(d) && client.items(d, "tool").some((item) => /declined/.test(item.text)));
		step("under Ask first, what the woken answer does is asked about as always");
	}

	// ---- The daily budget
	{
		const e = await open(lead);
		const g = gate();
		await startWaking(e, `${g.wait}; echo budget-done`);
		await client.call("usage.setBudget", { daily: 0.000001 });
		await client.until("over budget", () => client.events.usage?.overBudget === true);
		g.open();
		await client.until("told why it was not woken", () => client.markers(e).some((text) => /^pi² did not wake the agent: Today's budget of \$0\.00 is used up\. It is woken once there is budget again\.$/.test(text)));
		assert.equal(client.wakes(e).length, 0, "not woken while the budget is used up");
		assert.ok(client.watched(e).some((item) => item.state === "arrived"), "what ended is kept");
		await client.call("usage.setBudget", { daily: null });
		assert.match(await client.woken(e, 1), /finished$/);
		step("a wake waits while today's budget is used up, and comes once there is budget again");
	}

	// ---- The hourly cap: a command whose end has the woken agent start it again, in a loop
	{
		const counter = join(scratch, "loop-count");
		const loop = join(scratch, "loop.sh");
		const again = JSON.stringify({ command: `sh ${loop}`, background: true, wake: true });
		// Each round waits for a file of its own, which the test makes once the round is under way.
		writeFileSync(loop, `n=$(( $(cat '${counter}' 2>/dev/null || echo 0) + 1 )); echo $n > '${counter}'\nuntil [ -e '${scratch}/go-'$n ] || [ -e '${all}' ]; do sleep 0.05; done\necho '/tool bash ${again}'\n`);
		const round = async (n: number) => {
			await client.until(`round ${n} under way`, () => existsSync(counter) && readFileSync(counter, "utf8").trim() === String(n) && client.watched(f).some((item) => item.state === "running"));
			writeFileSync(join(scratch, `go-${n}`), "");
		};
		const f = await open(lead);
		await startWaking(f, `sh ${loop}`);
		for (let n = 1; n <= CAP; n++) {
			await round(n);
			await client.woken(f, n);
		}
		const told = (await client.call("search", { query: `pi² has now woken you ${CAP} times in the last hour` })).results;
		assert.ok(told.some((result: Event) => result.conversationId === f), "the agent is told when it reaches the cap");
		await round(CAP + 1);
		await client.until("the person told", () => client.markers(f).some((text) => text.startsWith(`pi² has woken the agent ${CAP} times in the last hour, the most it does.`) && text.endsWith("or after your next message.")));
		assert.ok(client.watched(f).some((item) => item.state === "arrived"), "what ended is kept");
		assert.equal(client.wakes(f).length, CAP, "not woken past the cap");
		// The person's message starts the count again: what was kept comes when the answer to it ends.
		await client.call("submit", { id: f, text: "carry on" });
		await client.woken(f, CAP + 1);
		step(`a conversation is woken at most ${CAP} times an hour here, however its agent keeps starting what wakes it; the agent and the person are told, and the person's message lets the rest through`);
	}

	// ---- The person's Stop, and Don't wake
	{
		const h = await open(lead);
		const g = gate();
		const sub = await handOff(h, task(g, "after-stop"), "Stopped");
		await client.call("abort", { id: h });
		await client.until("told waking is paused", () => client.markers(h).some((text) => text.startsWith("You stopped the agent, so pi² will not wake it until you send a message.")));
		g.open();
		await client.until("the answer kept", () => client.watched(h).some((item) => item.ref === String(sub) && item.state === "arrived"));
		assert.equal(client.wakes(h).length, 0, "not woken after the person's Stop");
		await client.call("submit", { id: h, text: "go on" });
		assert.match(await client.woken(h, 1), /“Stopped” answered$/);
		const g2 = gate();
		const bg = await startWaking(h, `${g2.wait}; echo not-wanted`);
		const [item] = client.watched(h);
		await client.call("wakes.cancel", { conversationId: h, key: item!.key });
		await client.until("told", () => client.markers(h).some((text) => text.startsWith(`You turned off waking the agent for background command ${bg}`)));
		g2.open();
		await client.until("the command over", () => client.markers(h).some((text) => text.startsWith(`Background command ${bg} finished`)));
		assert.equal(client.wakes(h).length, 1, "Don't wake: not woken for it");
		step("after the person's Stop nothing wakes the agent until they send a message; Don't wake turns one off");
	}

	// ---- Archived and deleted
	{
		const i = await open(lead);
		const g = gate();
		const sub = await handOff(i, task(g, "never-heard"), "Archived");
		const bg = await startWaking(i, g.wait);
		await client.call("conversation.archive", { id: i });
		await client.until("told why it will not be woken", () =>
			client.markers(i).some((text) => text.startsWith("The conversation was archived, so pi² will not wake the agent for") && text.includes(`sub-chat ${sub}`) && text.includes(bg)),
		);
		await client.until("its sub-chat stopped with it", () => (client.events.activity?.runs ?? []).every((run: Event) => run.conversationId !== sub));
		assert.deepEqual(client.watched(i), []);
		const j = await open(lead);
		const g2 = gate();
		await handOff(j, task(g2, "never-heard"), "Deleted");
		await client.call("conversation.delete", { id: j });
		await client.until("nothing left to wake it for", () => client.watched(j).length === 0);
		g.open();
		g2.open();
		assert.equal(client.wakes(i).length + client.wakes(j).length, 0, "an archived or deleted conversation is never woken");
		step("an archived or deleted conversation is never woken: what it waited for is stopped and let go, and an archived one says so");
	}

	// ---- An engine that stops and starts again
	{
		const k = await open(lead);
		const g = gate();
		const sub = await handOff(k, task(g, "after-restart"), "Restarted");
		const bg = await startWaking(k, "sleep 600");
		engine.kill("SIGTERM");
		await exited(engine);
		g.open();
		engine = boot();
		client = await Client.attach(engine);
		await client.call("conversation.open", { id: k });
		// The command's end is handed over as the engine starts, the sub-chat's once it has answered: in one wake or two.
		const bgLine = new RegExp(`background command ${bg} \\(\`sleep 600\`\\) ended when pi²’s engine stopped`);
		const subLine = `sub-chat ${sub} “Restarted” answered`;
		await client.until("both handed over", () => client.wakes(k).some((text) => bgLine.test(text)) && client.wakes(k).some((text) => text.includes(subLine)) && client.idle(k));
		const told = client.wakes(k).join("\n");
		assert.equal(told.split(subLine).length, 2, `the sub-chat once: ${told}`);
		assert.equal(told.split(`background command ${bg} `).length, 2, `the command once: ${told}`);
		const woken = client.wakes(k).length;
		engine.kill("SIGTERM");
		await exited(engine);
		engine = boot();
		client = await Client.attach(engine);
		await client.call("conversation.open", { id: k });
		await client.until("transcript", () => client.items(k, "assistant").length > 0);
		assert.equal(client.wakes(k).length, woken, "and only once");
		step("a wake survives the engine stopping: a command that ended with it wakes the agent once, and a sub-chat is followed again");
	}

	console.log("PASS");
	passed = true;
} finally {
	writeFileSync(all, "");
	if (running(engine)) {
		engine.kill("SIGTERM");
		await Promise.race([exited(engine), new Promise((resolve) => setTimeout(resolve, 8_000))]);
		await stop(engine, "SIGKILL");
	}
	if (!passed && existsSync(engineLog)) process.stderr.write(readFileSync(engineLog, "utf8"));
	rmSync(home, { recursive: true, force: true });
	rmSync(scratch, { recursive: true, force: true });
}
process.exit(0);
