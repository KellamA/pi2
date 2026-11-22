// A worker's question that does not hold it (#507; docs/projects.md 3.9, 5.5 and 6.4): a real engine on a throwaway
// data folder, driven over its socket with the demo model, as an app would drive it.
//
// A project whose orchestrator hands work to Worker, a project agent with full access. A worker is offered needs_you
// and ask_user, and told which to use when; a sub-chat of a conversation in no project is offered nothing new. A worker
// asks and carries on, and the answer reaches it while its run goes, steering it, with a line of news for the
// orchestrator. A worker asks and ends, and the answer goes to the orchestrator, with whose question it was and how to
// continue the sub-chat, and the worker is not started again. Two workers' questions answered in the other order each
// reach the worker that asked. A question withdrawn, and one whose sub-chat is archived, leave nothing waiting.

import assert from "node:assert/strict";
import { type ChildProcess, execFileSync, spawn } from "node:child_process";
import { closeSync, existsSync, mkdirSync, mkdtempSync, openSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { GONE } from "../src/needs.ts";
import { EngineClient, exited, leaveOut, running, standInApp, stop } from "./patience.ts";
// The engine takes answers for the person only from its app's connection (#504): this test's connection stands for it.
process.env.PI2_APP_BUNDLE = standInApp();

const home = mkdtempSync(join(tmpdir(), "pi2-wq-"));
const scratch = realpathSync(mkdtempSync(join(tmpdir(), "pi2-wq-work-")));
const main = join(import.meta.dirname, "..", "src", "main.ts");
const KEYCHAIN_SERVICE = `dev.pi2.credentials.test-workerquestions-${process.pid}`;
process.env.PI2_DEMO_TOKENS_PER_SECOND ??= "100000";
process.env.PI2_LOGIN_SHELL ??= "off";
const env = { ...process.env, PI2_HOME: home, PI2_KEYCHAIN_SERVICE: KEYCHAIN_SERVICE };
const engineLog = join(home, "engine.log");

function step(name: string): void {
	console.log(`ok  ${name}`);
}

type Event = Record<string, any>;
class Client extends EngineClient {
	items(id: number, kind: string): Event[] {
		return this.conversations.get(id)?.items.filter((item: Event) => item.kind === kind) ?? [];
	}
	markers(id: number, prefix: string): Event[] {
		return this.items(id, "marker").filter((item) => (item.text as string).startsWith(prefix));
	}
	idle(id: number): boolean {
		const conv = this.conversations.get(id);
		return conv !== undefined && !conv.state.busy;
	}
	get needs(): Event[] {
		return this.events.needs?.items ?? [];
	}
	needFrom(chat: number): Event | undefined {
		return this.needs.find((item) => item.conversationId === chat);
	}
	/** Whether an answer waits in pi2.wakes to be given to conversation `id`. */
	waitingFor(id: number): boolean {
		return (this.events.wakes?.items ?? []).some((item: Event) => item.conversationId === id && item.state === "arrived");
	}
	reportOf(projectId: string, chat: number): Event | undefined {
		return (this.events.reports?.projects?.[projectId] ?? []).filter((report: Event) => report.conversationId === chat).at(-1);
	}
	/** Sends a message the demo model answers with `count` tool calls, and returns their results once the answer is in. */
	async tools(id: number, text: string, count = 1): Promise<Event[]> {
		const before = this.items(id, "tool").length;
		await this.call("submit", { id, text });
		return await this.until(`results of ${text.slice(0, 80)}`, () => {
			const conv = this.conversations.get(id);
			const results = this.items(id, "tool");
			if (conv === undefined || conv.state.busy || results.length < before + count) return undefined;
			const after = conv.items.slice(conv.items.indexOf(results[before + count - 1]) + 1);
			return after.some((item: Event) => item.kind === "assistant") ? results.slice(before, before + count) : undefined;
		});
	}
	async tool(id: number, text: string): Promise<Event> {
		return (await this.tools(id, text))[0]!;
	}
}

/** Every command here waits for a file of its own, or for the one that lets them all go when the test ends. */
const all = join(scratch, "all-gates");
let gates = 0;
const gate = (): { open: () => void; wait: string } => {
	const path = join(scratch, `gate-${++gates}`);
	return { open: () => writeFileSync(path, ""), wait: `until [ -e '${path}' ] || [ -e '${all}' ]; do sleep 0.05; done` };
};
const folder = join(scratch, "project");
const work = join(scratch, "work");
mkdirSync(folder);
mkdirSync(work);

/** A worker's task: put `question` under Needs you and, with a gate, carry on with a command that waits for it. */
const asks = (question: string, g?: { wait: string }, choices?: string[]) =>
	`/tools ${JSON.stringify([
		{ name: "needs_you", arguments: { action: "ask", question, ...(choices === undefined ? {} : { choices }) } },
		...(g === undefined ? [] : [{ name: "bash", arguments: { command: `${g.wait}; echo built`, timeout: 600 } }]),
	])}`;
const handOff = (task: string, title: string) => ({ name: "delegate", arguments: { agent: "Worker", task, title, wait: false } });

const boot = () => {
	const log = openSync(engineLog, "a");
	try {
		return spawn(process.execPath, [main], { env, stdio: ["ignore", "ignore", log] });
	} finally {
		closeSync(log);
	}
};
let passed = false;
const engine: ChildProcess = boot();
let client: Client | undefined;
try {
	client = await Client.connect(engine, home);
	const c = client;
	await c.until("first events", () => c.events.providers && c.events.wakes && c.events.reports && c.events.agents && c.events.needs);

	const worker = (await c.call("agents.save", { agent: { name: "Worker", description: "Does the work", access: "full", cwd: work } })).id as string;
	const lead = (await c.call("agents.save", { agent: { name: "Lead", description: "Hands out work", access: "full", cwd: work, delegates: [worker] } })).id as string;

	// ---- A sub-chat of a conversation in no project is offered nothing new

	// In no project: the project carrying over makes for it is deleted (#458, `leaveOut`).
	const plain = (await c.call("conversation.create", { agentId: lead })).id as number;
	await leaveOut(c);
	await c.call("conversation.open", { id: plain });
	const outside = await c.tool(plain, `/tool delegate ${JSON.stringify({ agent: "Worker", task: "/system none" })}`);
	assert.match(outside.text, /TOOLS: /);
	assert.doesNotMatch(outside.text, /needs_you/, "not offered needs_you outside a project");

	const made = await c.call("projects.create", { folder });
	const projectId = made.id as string;
	const oc = made.conversation as number;
	const copy = (await c.call("projects.addAgent", { projectId, template: worker })).id as string;
	await c.until("the project's Worker", () => c.events.agents.agents.find((agent: Event) => agent.id === copy));
	await c.call("conversation.open", { id: oc });
	await c.until("open", () => c.conversations.get(oc)?.state !== undefined);

	const still = await c.tool(plain, `/tool delegate ${JSON.stringify({ agent: "Worker", task: "/system none" })}`);
	assert.doesNotMatch(still.text, /needs_you/, "nor beside a project made since");
	assert.match(still.text, /ask_user/);
	step("a sub-chat of a conversation in no project is offered nothing new, before a project is made or after");

	// ---- A worker is offered both ways to ask, and told which to use when

	const told = await c.tool(oc, `/tool delegate ${JSON.stringify({ agent: "Worker", task: "/system project", title: "Prompt" })}`);
	assert.match(told.text, /TOOLS: [^\n]*\bneeds_you\b/);
	assert.match(told.text, /TOOLS: [^\n]*\bask_user\b/);
	assert.match(
		told.text,
		/When something is the person's to decide and your work can go on without it, put it to them with needs_you and carry on: their answer comes to you as you work, or, once you have finished, to the agent that handed you this work\. Use ask_user only when your next step needs the answer and there is nothing else to do meanwhile\./,
	);
	const described = await c.tool(oc, `/tool delegate ${JSON.stringify({ agent: "Worker", task: "/system tools needs_you", title: "Tools" })}`);
	assert.match(described.text, /When your next step needs the answer and you have nothing else to do meanwhile, use ask_user instead, which waits for it\./);
	step("a worker in a project is offered needs_you and ask_user, and the section and the tool say which to use when");

	// ---- A worker asks and carries on: the answer reaches it while its run goes

	const g1 = gate();
	const [started] = await c.tools(oc, `/tools ${JSON.stringify([handOff(asks("Blue or green?", g1), "Colours")])}`);
	const colours = started!.details.conversationId as number;
	const asked = await c.until("the worker's question", () => c.needFrom(colours));
	assert.equal(asked.kind, "question");
	assert.equal(asked.question, "Blue or green?");
	assert.equal(asked.rootConversationId, oc);
	assert.equal(asked.title, "Colours");
	assert.equal(asked.agentName, "Worker");
	assert.equal(asked.agentId, copy);
	assert.equal(asked.blocking, false, "it does not hold the worker");
	assert.equal(asked.work, undefined, "a run handed out with delegate has no piece of work");
	await c.until("the worker still working", () => c.reportOf(projectId, colours)?.ended === null);
	await c.call("conversation.open", { id: colours });
	await c.until("the worker's transcript", () => c.items(colours, "tool").some((item) => item.name === "needs_you"));
	assert.match(c.items(colours, "tool").find((item) => item.name === "needs_you")!.text, /^Put to the person as n\d+\. Carry on/);
	await c.call("needs.answer", { id: asked.id, answer: { kind: "question", text: "Green" } });
	await c.until("given to the worker's run", () => !c.waitingFor(colours) && c.needFrom(colours) === undefined);
	assert.equal(c.reportOf(projectId, colours)!.ended, null, "while its run still goes");
	g1.open();
	await c.until("the run ended", () => c.reportOf(projectId, colours)?.ended?.outcome === "answered");
	const steered = await c.until("the line in the worker's transcript", () => c.markers(colours, "pi² told the agent as it worked")[0]);
	assert.equal(steered.text, "pi² told the agent as it worked: the question “Blue or green?” was answered");
	assert.equal(steered.details.wake.text, "The person answered your question “Blue or green?”: Green.");
	assert.equal(c.markers(oc, "pi² woke").length, 0, "the orchestrator is not woken for it");
	const read = await c.tool(oc, `/tool reports ${JSON.stringify({ action: "read", chats: [colours] })}`);
	assert.match(read.text, /You said: "The person answered your question “Blue or green\?”: Green\."/, "the run read the answer and answered it");
	const items = c.conversations.get(colours).items as Event[];
	const built = items.findIndex((item) => item.kind === "tool" && item.name === "bash" && /built/.test(item.text));
	assert.ok(built >= 0 && items.indexOf(steered) > built, "given after the step it was taking, in the same run");
	const caught = c.markers(oc, "pi² told the orchestrator what changed").at(-1)!;
	assert.match(caught.details.wake.text, new RegExp(`- The person answered Worker's question in sub-chat ${colours}: “Green”`), "and the orchestrator is told in its catch-up");
	step("a worker asks and carries on; the answer is given to its run as it works, and the orchestrator is told at its next turn");

	// ---- A worker asks and ends: the answer goes to the orchestrator, and the worker stays ended

	const [shipping] = await c.tools(oc, `/tools ${JSON.stringify([handOff(asks("Ship on Friday?", undefined, ["Yes", "No"]), "Shipping")])}`);
	const ship = shipping!.details.conversationId as number;
	const decision = await c.until("the worker's decision", () => c.needFrom(ship));
	assert.equal(decision.kind, "decision");
	await c.until("its run ended", () => c.reportOf(projectId, ship)?.ended?.outcome === "answered");
	await c.call("conversation.open", { id: ship });
	await c.until("its transcript", () => c.idle(ship) && c.items(ship, "assistant").length > 0);
	const answersBefore = c.items(ship, "assistant").length;
	const runBefore = c.reportOf(projectId, ship)!.submissionId;
	const wakesBefore = c.markers(oc, "pi² woke").length;
	await c.call("needs.answer", { id: decision.id, answer: { kind: "decision", choice: "c2" } });
	await c.until("the orchestrator woken with it", () => c.markers(oc, "pi² woke").length === wakesBefore + 1 && c.idle(oc));
	const relayed = c.markers(oc, "pi² woke").at(-1)!;
	assert.equal(relayed.text, `pi² woke the agent: Worker's question “Ship on Friday?” in sub-chat ${ship} was answered`);
	assert.equal(
		relayed.details.wake.text,
		"[pi² woke you: this ended while you were not answering.]\n\n" +
			`The person answered the question Worker asked in sub-chat ${ship} “Shipping”: “Ship on Friday?”\n\n` +
			"Their answer: No.\n\n" +
			`Worker's run had ended, so it has not been told. To carry on with the answer, continue the sub-chat: delegate with chat: ${ship}.`,
	);
	assert.deepEqual(relayed.details.answers, [{ need: decision.id, ended: "was answered", label: `Worker's question “Ship on Friday?” in sub-chat ${ship}` }]);
	assert.ok(c.idle(ship), "the worker is not started again");
	assert.equal(c.items(ship, "assistant").length, answersBefore);
	assert.equal(c.markers(ship, "pi² ").length, 0, "and is given nothing");
	assert.equal(c.reportOf(projectId, ship)!.submissionId, runBefore, "no new run");
	step("a worker asks and ends; the answer wakes the orchestrator with whose question it was and how to continue, and the worker stays ended");

	// ---- Two workers' questions answered in the other order: each reaches the worker that asked

	const ga = gate();
	const gb = gate();
	const pair = await c.tools(oc, `/tools ${JSON.stringify([handOff(asks("Which port?", ga), "Port"), handOff(asks("Which name?", gb), "Name")])}`, 2);
	const port = c.events.library.conversations.find((row: Event) => row.parent === oc && row.title === "Port").id as number;
	const name = c.events.library.conversations.find((row: Event) => row.parent === oc && row.title === "Name").id as number;
	assert.equal(pair.length, 2);
	const [askedPort, askedName] = await c.until("both questions", () => {
		const both = [c.needFrom(port), c.needFrom(name)];
		return both.every((one) => one !== undefined) ? both : undefined;
	});
	await c.call("needs.answer", { id: askedName!.id, answer: { kind: "question", text: "Lantern" } });
	await c.call("needs.answer", { id: askedPort!.id, answer: { kind: "question", text: "8080" } });
	await c.until("both given", () => !c.waitingFor(port) && !c.waitingFor(name) && c.needs.length === 0);
	ga.open();
	gb.open();
	await c.until("both ended", () => c.reportOf(projectId, port)?.ended !== null && c.reportOf(projectId, name)?.ended !== null);
	const both = await c.tool(oc, `/tool reports ${JSON.stringify({ action: "read", chats: [port, name] })}`);
	const [portReport, nameReport] = [port, name].map((chat) => both.text.split("\n\n---\n\n").find((each: string) => each.startsWith(`Sub-chat ${chat} `))!);
	assert.match(portReport!, /“Which port\?”: 8080\./);
	assert.doesNotMatch(portReport!, /Lantern/);
	assert.match(nameReport!, /“Which name\?”: Lantern\./);
	assert.doesNotMatch(nameReport!, /8080/);
	step("two workers' questions answered in the other order: each answer reaches the worker that asked it");

	// ---- Given to a run that is stopped before it took the answer in: it goes to the orchestrator instead

	const gs = gate();
	const [stopping] = await c.tools(oc, `/tools ${JSON.stringify([handOff(asks("Tabs or spaces?", gs), "Style")])}`);
	const style = stopping!.details.conversationId as number;
	const styleQuestion = await c.until("its question", () => c.needFrom(style));
	const beforeStop = c.markers(oc, "pi² woke").length;
	await c.call("needs.answer", { id: styleQuestion.id, answer: { kind: "question", text: "Tabs" } });
	await c.until("given to its run", () => !c.waitingFor(style));
	await c.call("abort", { id: style });
	await c.until("the orchestrator woken with it instead", () => c.markers(oc, "pi² woke").some((row, index) => index >= beforeStop && /Worker's question “Tabs or spaces\?”/.test(row.text)));
	const instead = c.markers(oc, "pi² woke").find((row) => /Worker's question “Tabs or spaces\?”/.test(row.text))!;
	assert.match(instead.details.wake.text, new RegExp(`The person answered the question Worker asked in sub-chat ${style} “Style”: “Tabs or spaces\\?”\n\nTheir answer: Tabs\.`));
	await c.call("conversation.open", { id: style });
	await c.until("the worker's transcript", () => c.idle(style) && c.items(style, "tool").length > 0);
	assert.equal(c.markers(style, "pi² told the agent").length, 0, "the worker never took it in");
	await c.until("the orchestrator idle", () => c.idle(oc));
	step("an answer given to a run that is stopped before it took it in goes to the orchestrator instead");

	// ---- A run handed a piece of work: the card names it, and so does the answer that goes to the orchestrator

	const filed = await c.tool(oc, `/tool work ${JSON.stringify({ action: "file", title: "Fix login", text: "The login times out." })}`);
	assert.equal(filed.isError, false, filed.text);
	const item = Number(/^Filed #(\d+) “Fix login”/.exec(filed.text)![1]);
	const assigned = await c.tool(oc, `/tool work ${JSON.stringify({ action: "assign", id: item, agent: "Worker", title: "Login", task: asks("Keep the old endpoint?") })}`);
	assert.equal(assigned.isError, false, assigned.text);
	const login = c.events.library.conversations.find((row: Event) => row.parent === oc && row.title === "Login").id as number;
	const onWork = await c.until("the assigned worker's question", () => c.needFrom(login));
	assert.equal(onWork.work, item, "the card can name the piece of work");
	await c.until("its run ended", () => typeof c.reportOf(projectId, login)?.ended?.at === "number");
	assert.equal(c.reportOf(projectId, login)!.work, item);
	const woke = c.markers(oc, "pi² woke").length;
	await c.call("needs.answer", { id: onWork.id, answer: { kind: "question", text: "No, the new one.\nIt is faster." } });
	await c.until("the orchestrator woken", () => c.markers(oc, "pi² woke").length === woke + 1 && c.idle(oc));
	assert.match(
		c.markers(oc, "pi² woke").at(-1)!.details.wake.text,
		new RegExp(`The person answered the question Worker asked in sub-chat ${login} “Login” \\(on #${item}\\): “Keep the old endpoint\\?”\n\nTheir answer:\n\nNo, the new one\.\nIt is faster\.\n\nWorker's run had ended`),
	);
	step("a run handed a piece of work: its question carries the work's number, and the answer that goes to the orchestrator names it");

	// ---- Withdrawn, and the sub-chat archived before the answer: nothing waits, nobody is told

	const [withdrawing] = await c.tools(oc, `/tools ${JSON.stringify([handOff(asks("Keep the old flag?"), "Flags")])}`);
	const flags = withdrawing!.details.conversationId as number;
	const flag = await c.until("its question", () => c.needFrom(flags));
	await c.until("its run ended", () => c.reportOf(projectId, flags)?.ended !== null && c.reportOf(projectId, flags)?.ended !== undefined);
	const listed = await c.tool(oc, `/tool delegate ${JSON.stringify({ agent: "Worker", chat: flags, task: '/tool needs_you {"action":"list"}' })}`);
	assert.match(listed.text, new RegExp(`- ${flag.id}: “Keep the old flag\\?”`));
	const withdrawn = await c.tool(oc, `/tool delegate ${JSON.stringify({ agent: "Worker", chat: flags, task: `/tool needs_you {"action":"withdraw","id":"${flag.id}"}` })}`);
	assert.match(withdrawn.text, new RegExp(`Withdrew ${flag.id}\\. The person no longer sees it\\.`));
	await c.until("gone from the list", () => c.needFrom(flags) === undefined);
	await assert.rejects(c.call("needs.answer", { id: flag.id, answer: { kind: "question", text: "Yes" } }), { message: GONE });

	const [archiving] = await c.tools(oc, `/tools ${JSON.stringify([handOff(asks("Rename the table?"), "Tables")])}`);
	const tables = archiving!.details.conversationId as number;
	const table = await c.until("its question", () => c.needFrom(tables));
	await c.until("its run ended", () => typeof c.reportOf(projectId, tables)?.ended?.at === "number");
	const quiet = c.markers(oc, "pi² woke").length;
	const put = await c.tool(oc, `/tool sub_chats ${JSON.stringify({ action: "archive", chats: [tables] })}`);
	assert.equal(put.isError, false, put.text);
	await c.until("withdrawn with its sub-chat", () => c.needFrom(tables) === undefined);
	await assert.rejects(c.call("needs.answer", { id: table.id, answer: { kind: "question", text: "Yes" } }), { message: GONE });
	assert.equal(c.markers(oc, "pi² woke").length, quiet, "nobody is woken");
	assert.ok(!c.waitingFor(oc) && !c.waitingFor(tables), "and nothing waits to be given");
	step("a question withdrawn, and one whose sub-chat is archived before the answer, leave nothing waiting and wake nobody");

	console.log("PASS");
	passed = true;
} finally {
	writeFileSync(all, "");
	client?.close();
	if (running(engine)) {
		engine.kill("SIGTERM");
		await Promise.race([exited(engine), new Promise((resolve) => setTimeout(resolve, 8_000))]);
		await stop(engine, "SIGKILL");
	}
	if (!passed && existsSync(engineLog)) process.stderr.write(readFileSync(engineLog, "utf8"));
	rmSync(home, { recursive: true, force: true });
	rmSync(scratch, { recursive: true, force: true });
	try {
		while (true) execFileSync("/usr/bin/security", ["delete-generic-password", "-s", KEYCHAIN_SERVICE], { stdio: "ignore" });
	} catch {
		// None left.
	}
}
process.exit(0);
