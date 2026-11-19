// One conversation with a project's orchestrator, what it is told of the project, and Start fresh (#466;
// docs/projects.md 6.1 and 6.3 to 6.6).
//
// First the catch-up's room and the state block's words alone. Then a real engine on a throwaway data folder, driven
// over its socket with the demo model: a conversation in no project, told the same prompt and given the same context,
// byte for byte, before the preview, with it on and after everything below; a project whose orchestrator's first
// context begins with the state block; a turn with no news that adds nothing; ten finished reports given once in one
// catch-up, whose cost in tokens is printed; the person writing to a sub-chat, told at the orchestrator's next turn
// without waking it; a summary that ends with the state block and clears no news; Start fresh refused while the
// orchestrator answers, has a message queued or waits on the person, then made, with what was pending moved and the old
// conversation readable and taking no messages; the fresh conversation's first context (the rules, the notes and the
// state, and nothing of the old one); `sub_chats` and `delegate` reaching the earlier conversation's sub-chats; an answer
// to a question asked in the earlier one; a new orchestrator; `lastWords`, `lastLine`, `library`'s `orchestrator` and
// the conversation state's `project`; and the preview off, with which nothing is added and news waits.

import assert from "node:assert/strict";
import { type ChildProcess, execFileSync, spawn } from "node:child_process";
import { closeSync, existsSync, mkdirSync, mkdtempSync, openSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { CATCH_UP_ROOM, catchUp, NEWS_KEPT, type StateSnapshot, stateText } from "../src/orchestrator.ts";
import type { News } from "../src/projects.ts";
import { EngineClient, exited, running, standInApp, stop } from "./patience.ts";

function step(name: string): void {
	console.log(`ok  ${name}`);
}

// ---- The catch-up's room, and the state block's words, alone

{
	const piece = (n: number, text = `Change ${n}.`, keep = false): News => ({ id: `w${n}`, at: n, kind: keep ? "message" : "change", text, ref: String(n), ...(keep ? { keep: true as const } : {}) });
	const ten = Array.from({ length: 10 }, (_, n) => piece(n + 1));
	const all = catchUp(ten);
	assert.deepEqual(
		all.given.map((news) => news.id),
		ten.map((news) => news.id),
	);
	assert.equal(all.text, ["[pi² — what changed in the project since your last turn]", ...ten.map((news) => `- ${news.text}`)].join("\n"));
	assert.equal(all.cleared.size, 10);
	// More than the room: every piece with keep goes in, then the newest of the rest; what does not fit waits.
	const long = Array.from({ length: 60 }, (_, n) => piece(n + 1, `Change ${n + 1}: ${"x".repeat(100)}`));
	const kept = piece(61, `The person wrote to Forge in sub-chat 3: “${"y".repeat(300)}”`, true);
	const crowded = [kept, ...long];
	const some = catchUp(crowded);
	assert.ok(some.text.length <= CATCH_UP_ROOM, `${some.text.length}`);
	assert.ok(some.given.includes(kept), "a message the person wrote is never left out");
	assert.ok(some.given.length < crowded.length);
	assert.ok(some.given.some((news) => news.id === "w60") && !some.given.some((news) => news.id === "w1"), "the newest go in first");
	assert.match(some.text, new RegExp(`\\n…and ${crowded.length - some.given.length} more, given at your next turn; reports and work list them now\\.$`));
	assert.equal(some.cleared.size, some.given.length, "what was not given stays");
	// Past NEWS_KEPT pieces without keep, the oldest go and are counted.
	const many = [...Array.from({ length: NEWS_KEPT + 40 }, (_, n) => piece(n + 1)), piece(9_999, "Kept.", true)];
	const counted = catchUp(many);
	assert.match(counted.text, /\n\(and 40 older changes not listed\)/);
	assert.ok(!counted.given.some((news) => Number(news.id.slice(1)) <= 40));
	assert.ok(["w1", "w40"].every((id) => counted.cleared.has(id)), "those dropped leave the news too");
	assert.ok(counted.given.some((news) => news.id === "w9999"));
	step("a catch-up holds every message the person wrote, then the newest of the rest within 4,000 characters; past 200 the oldest go, counted");

	const at = new Date(2026, 10, 19, 14, 20).getTime();
	const none: StateSnapshot = { at, working: [], needs: [], reports: [], work: { counts: {}, held: [] }, messages: [] };
	assert.equal(stateText(none), ["[pi² — the project as it stands, 19 November 14:20]", "Working now: none.", "Under Needs you: none.", "Reports not read: none.", "Work: none."].join("\n"));
	const busy: StateSnapshot = {
		at,
		working: [
			{ chat: 14, agent: "Forge", title: "Fix login", since: new Date(2026, 10, 19, 13, 40).getTime(), limitUntil: null },
			{ chat: 16, agent: "Scout", title: "Docs", since: at, limitUntil: new Date(2026, 10, 19, 15, 30).getTime() },
		],
		needs: [{ id: "n12", kind: "decision", line: "n12 decision “Merge now or after the release?”", conversation: 1 }],
		reports: [{ chat: 15, agent: "Scout", title: "Tests", outcome: "failed", at: new Date(2026, 10, 19, 14, 10).getTime() }],
		work: { counts: { open: 12, in_progress: 3 }, held: [{ id: 28, title: "", state: "in_progress", agent: "Forge" }] },
		messages: ["The person wrote to Forge in sub-chat 14: “Use the new endpoint instead.”"],
	};
	assert.equal(
		stateText(busy),
		[
			"[pi² — the project as it stands, 19 November 14:20]",
			"Working now: sub-chat 14 “Fix login” (Forge, since 13:40); sub-chat 16 “Docs” (Scout, waiting for its provider's limit until 15:30).",
			"Under Needs you: n12 decision “Merge now or after the release?”.",
			"Reports not read: sub-chat 15 “Tests” (Scout) failed at 14:10.",
			"Work: 12 open, 3 in progress. In progress: #28 Forge.",
			"The person wrote to Forge in sub-chat 14: “Use the new endpoint instead.”",
		].join("\n"),
	);
	const crowd = { ...none, working: Array.from({ length: 33 }, (_, n) => ({ chat: n + 1, agent: "W", title: "T", since: at, limitUntil: null })) };
	assert.match(stateText(crowd), /; and 3 more; sub_chats lists them\.\n/);
	step("the state block says none for each empty part, and lists whole up to 30 entries");
}

// ---- A real engine

const home = mkdtempSync(join(tmpdir(), "pi2-orch-"));
const scratch = realpathSync(mkdtempSync(join(tmpdir(), "pi2-orch-work-")));
const main = join(import.meta.dirname, "..", "src", "main.ts");
const KEYCHAIN_SERVICE = `dev.pi2.credentials.test-orchestrator-${process.pid}`;
// A summary gate that is never closed: the demo model answers `/compaction-history` briefly, and summarises at once.
const env = { ...process.env, PI2_HOME: home, PI2_KEYCHAIN_SERVICE: KEYCHAIN_SERVICE, PI2_DEMO_TOKENS_PER_SECOND: "100000", PI2_LOGIN_SHELL: "off", PI2_DEMO_COMPACTION_GATE: join(home, "summary"), PI2_APP_BUNDLE: standInApp() };
const engineLog = join(home, "engine.log");
const work = join(scratch, "work");
const folder = join(scratch, "project");
mkdirSync(work);
mkdirSync(folder);
const all = join(scratch, "all-gates");
let gates = 0;
const gate = () => {
	const path = join(scratch, `gate-${++gates}`);
	return { open: () => writeFileSync(path, ""), wait: `until [ -e '${path}' ] || [ -e '${all}' ]; do sleep 0.05; done` };
};

type Event = Record<string, any>;
class Client extends EngineClient {
	items(id: number, kind?: string): Event[] {
		return (this.conversations.get(id)?.items ?? []).filter((item: Event) => kind === undefined || item.kind === kind);
	}
	markers(id: number, prefix: string): Event[] {
		return this.items(id, "marker").filter((item) => typeof item.text === "string" && item.text.startsWith(prefix));
	}
	state(id: number): Event | undefined {
		return this.conversations.get(id)?.state;
	}
	row(id: number): Event | undefined {
		return this.events.library?.conversations.find((row: Event) => row.id === id);
	}
	project(id: string): Event | undefined {
		return this.events.projects?.projects.find((row: Event) => row.id === id);
	}
	async open(id: number): Promise<void> {
		await this.call("conversation.open", { id });
		await this.until(`conversation ${id} open`, () => this.state(id));
	}
	/** Sends a message and waits for its own answer; gives its text. */
	async answer(id: number, text: string): Promise<string> {
		const previous = this.items(id).at(-1)?.id ?? 0;
		const { submissionId } = await this.call("submit", { id, text });
		await this.until(`answer to ${text.slice(0, 40)} in ${id}`, () => this.state(id)?.busy === false && this.items(id).some((item) => item.kind === "assistant" && item.id > previous));
		const { submission } = await this.call("submission.get", { id, submissionId });
		assert.equal(submission.status, "done", JSON.stringify(submission));
		return this.items(id).find((item) => item.id === submission.answer)!.text;
	}
	/** What the model was sent as the person's side of the conversation, one message at a time (the demo model's `/context`). */
	async context(id: number): Promise<string[]> {
		const said = await this.answer(id, "/context");
		assert.ok(said.startsWith("CONTEXT\n"), said);
		return said.slice(8).split("\n");
	}
	async prompt(id: number): Promise<string> {
		const full = await this.answer(id, "/system full");
		assert.ok(full.startsWith("FULL\n"));
		return full;
	}
	/** Sends a message the demo model answers with `count` tool calls, and returns their results once the answer is in. */
	async tools(id: number, text: string, count = 1): Promise<Event[]> {
		const before = this.items(id, "tool").length;
		await this.call("submit", { id, text });
		return await this.until(`results of ${text.slice(0, 60)}`, () => {
			const results = this.items(id, "tool");
			if (this.state(id)?.busy !== false || results.length < before + count) return undefined;
			const after = this.items(id).slice(this.items(id).indexOf(results[before + count - 1]!) + 1);
			return after.some((item) => item.kind === "assistant") ? results.slice(before, before + count) : undefined;
		});
	}
}

const boot = () => {
	const log = openSync(engineLog, "a");
	try {
		return spawn(process.execPath, [main], { env, stdio: ["ignore", "ignore", log] });
	} finally {
		closeSync(log);
	}
};
const handOff = (task: string, title: string) => ({ name: "delegate", arguments: { agent: "Worker", task, title, wait: false } });
const STATE = "pi² told the orchestrator how the project stands";
const CAUGHT_UP = "pi² told the orchestrator what changed";
const TOLD = "The orchestrator will be told";

let passed = false;
const engine: ChildProcess = boot();
let client: Client | undefined;
try {
	const c = (client = await Client.connect(engine, home));
	await c.until("first events", () => c.events.agents && c.events.projects && c.events.library);

	// ---- A conversation in no project, as it is before the preview was ever on

	const worker = (await c.call("agents.save", { agent: { name: "Worker", description: "Does the work", access: "full", cwd: work } })).id as string;
	const lead = (await c.call("agents.save", { agent: { name: "Lead", description: "Hands out work", access: "full", cwd: work, delegates: [worker] } })).id as string;
	const plain = (await c.call("conversation.create", { agentId: lead })).id as number;
	await c.open(plain);
	await c.answer(plain, "A first message, in no project.");
	const plainPrompt = await c.prompt(plain);
	const plainContext = await c.context(plain);
	assert.equal(c.row(plain)!.orchestrator, null);
	assert.equal("project" in c.state(plain)!, false, "the state of a conversation in no project has nothing new");
	/** What the plain conversation is told now is what it was told before anything here: prompt, tools and context. */
	const unchanged = async (when: string) => {
		assert.equal(await c.prompt(plain), plainPrompt, `the prompt ${when}`);
		const now = await c.context(plain);
		assert.deepEqual(now.slice(0, plainContext.length), plainContext, `the context ${when}`);
		assert.equal(c.markers(plain, "pi² told").length + c.markers(plain, TOLD).length, 0, `nothing told ${when}`);
		assert.equal("project" in c.state(plain)!, false);
	};

	// ---- A project: the orchestrator's first context begins with the state block

	await c.call("projects.setPreview", { on: true });
	await unchanged("with the preview on");
	const made = await c.call("projects.create", { folder });
	const projectId = made.id as string;
	const oc = made.conversation as number;
	await c.until("the project", () => c.project(projectId));
	const copy = (await c.call("projects.addAgent", { projectId, template: worker })).id as string;
	await c.until("the project's Worker", () => c.events.agents.agents.find((agent: Event) => agent.id === copy));
	const rule = "Run the engine's tests before every commit.";
	await c.call("projects.rules.add", { projectId, text: rule, binds: "everyone" });
	const note = "The release is on Friday.";
	await c.call("memory.add", { projectId, text: note });
	await c.open(oc);
	await c.until("its library row", () => c.row(oc)?.orchestrator === "current");
	assert.deepEqual(c.state(oc)!.project, { id: projectId, orchestrator: "current" });

	const first = await c.context(oc);
	assert.equal(c.markers(oc, STATE).length, 1);
	const block = c.markers(oc, STATE)[0]!.details.wake.text as string;
	assert.match(block, /^\[pi² — the project as it stands, \d+ \w+ \d\d:\d\d\]\nWorking now: none\.\nUnder Needs you: none\.\nReports not read: none\.\nWork: none\.$/);
	assert.deepEqual(first, [...block.split("\n"), "/context"], "the state block, then the message");
	const sections = await c.answer(oc, "/system project project_rules memory");
	assert.match(sections, /<<project>>\n<project>\nYou are the orchestrator of the pi² project “project”, in .+\. The person talks to you here; this is the project's one conversation with you\./);
	assert.match(sections, /You may, without asking: start agents, file work, close work, make and change agents, add rules\. You ask first to: merge, release, go past a limit\. “Release” is the person's policy/);
	assert.match(sections, /Limits: no new agent starts while a plan window it would run on is 90% used or more\. Past a limit/);
	assert.match(sections, /A report from an agent does not wake you; it waits until you read it with reports\. Choose otherwise for particular hand-offs with reports\./);
	assert.match(sections, /Put a decision that is the person's to them with needs_you/);
	assert.match(sections, /\nIts work list is kept by pi²\. Keep it with the work tool, not with scripts or gh of your own\.\n/);
	// #465's tools are offered to it, and so named; before they landed, nothing was said of them.
	assert.match(sections, /\nChange the project with project_agents, project_settings and project_rules; each change shows here with Undo for the person\. A change that lets agents do more is never made by a tool: it is put to the person, who allows or refuses it\.\n/);
	assert.ok(sections.includes(rule) && sections.includes(note));
	step("a new project's orchestrator: its first context is the state block and its message; the project section, the rules and the notes are in its prompt");

	// ---- A turn with no news adds nothing

	const quiet = await c.context(oc);
	assert.equal(c.markers(oc, CAUGHT_UP).length, 0);
	assert.equal(c.markers(oc, STATE).length, 1);
	assert.equal(quiet.filter((line) => line.startsWith("[pi²")).length, 1, "only the first state block");
	step("a turn with no news adds nothing to the context");

	// ---- Ten finished reports: one catch-up, given once

	const ten = await c.tools(oc, `/tools ${JSON.stringify(Array.from({ length: 10 }, (_, n) => handOff(`/bash echo done-${n + 1}`, `Part ${n + 1}`)))}`, 10);
	for (const result of ten) assert.equal(result.isError, false, result.text);
	// The results come in the order the calls ended; the sub-chats are known by their titles.
	const titled = (title: string) => c.events.library.conversations.find((row: Event) => row.parent === oc && row.title === title).id as number;
	const parts = ten.map((_, n) => titled(`Part ${n + 1}`));
	await c.until("ten reports ended", () => parts.every((chat) => (c.events.reports?.projects?.[projectId] ?? []).some((report: Event) => report.conversationId === chat && report.ended !== null)));
	assert.equal(c.markers(oc, "pi² woke").length, 0, "not woken");
	const answers = c.items(oc, "assistant").length;
	const caught = await c.context(oc);
	assert.equal(c.markers(oc, CAUGHT_UP).length, 1);
	const catchUpRow = c.markers(oc, CAUGHT_UP)[0]!;
	assert.equal(catchUpRow.text, `${CAUGHT_UP} (10)`);
	const told = catchUpRow.details.wake.text as string;
	const lines = told.split("\n");
	assert.equal(lines[0], "[pi² — what changed in the project since your last turn]");
	assert.equal(lines.length, 11);
	for (const [n, chat] of parts.entries()) assert.ok(lines.some((line) => new RegExp(`^- Sub-chat ${chat} “Part ${n + 1}” \\(Worker\\) answered at \\d\\d:\\d\\d; not read yet\\.$`).test(line)), told);
	assert.deepEqual(caught.slice(-12), [...lines, "/context"], "the catch-up just before the message");
	const tokens = Math.ceil(told.length / 4);
	console.log(`    a catch-up of ten finished reports: ${told.length} characters, about ${tokens} tokens, given once`);
	assert.ok(tokens < 400, `${tokens}`);
	const again = await c.context(oc);
	assert.equal(c.markers(oc, CAUGHT_UP).length, 1, "news is given once");
	assert.equal(again.filter((line) => line === lines[0]).length, 1, "and is in the context once");
	assert.equal(c.items(oc, "assistant").length, answers + 2);
	step("ten finished reports come in one catch-up in front of the next message, once, and not again");

	// ---- The person writes to a sub-chat: told at the orchestrator's next turn, without waking it

	const part = parts[0]!;
	await c.open(part);
	const before = c.items(oc).length;
	await c.answer(part, "Use the new endpoint instead.");
	assert.equal(c.markers(part, TOLD).length, 1, "the line in the sub-chat");
	assert.equal(c.items(oc).length, before, "the orchestrator is not woken");
	const withMessage = await c.context(oc);
	const message = `- The person wrote to Worker in sub-chat ${part}: “Use the new endpoint instead.”`;
	assert.ok(withMessage.includes(message), withMessage.join("\n"));
	assert.equal(c.markers(oc, CAUGHT_UP).at(-1)!.text, `${CAUGHT_UP} (1)`);
	step("a message the person sends to another agent is told to the orchestrator at its next turn, without waking it");

	// ---- A summary ends with the state block, and clears no news

	await c.answer(oc, `/compaction-history ${"An old turn to summarize. ".repeat(4_000)}`);
	await c.answer(oc, "A recent turn.");
	await c.answer(part, "Keep the old endpoint for the tests.");
	await c.call("conversation.compact", { id: oc });
	const tooLittle = "There is too little here to summarise yet.";
	await c.until("a summary", () => c.items(oc).some((item) => item.details?.compaction?.trigger === "person" || item.text === tooLittle) && c.state(oc)?.compacting === false);
	assert.ok(!c.items(oc).some((item) => item.text === tooLittle), "summarised");
	const summarised = await c.context(oc);
	const summary = summarised.findIndex((line) => line.startsWith("[pi² — the project as it stands"));
	assert.ok(summary >= 0, summarised.join("\n"));
	assert.ok(summarised.slice(0, summary).some((line) => line.includes("The demo model's summary")), "at the end of the summary");
	assert.ok(summarised.includes("The person wrote to Worker in sub-chat " + part + ": “Keep the old endpoint for the tests.”"), "the message kept, in the state block");
	assert.ok(summarised.includes(`- The person wrote to Worker in sub-chat ${part}: “Keep the old endpoint for the tests.”`), "and still in the next catch-up");
	const kept = await c.answer(oc, "/system project project_rules memory");
	assert.ok(kept.includes(rule) && kept.includes(note) && kept.includes("You are the orchestrator of the pi² project"), "the rules, the notes and the project section after it");
	step("a summary of the orchestrator's conversation ends with the state block and clears no news");

	// ---- Start fresh is refused while the orchestrator answers, has a message queued, or waits on the person

	const refused = (message: string) => assert.rejects(c.call("projects.startFresh", { id: projectId }), { message });
	await c.call("submit", { id: oc, text: "/ask Which endpoint?" });
	await c.until("its question", () => c.events.inbox?.items?.some((item: Event) => item.conversationId === oc));
	await refused("Answer what the orchestrator is waiting for first.");
	await c.call("abort", { id: oc });
	await c.until("idle", () => c.state(oc)?.busy === false && !c.events.inbox?.items?.some((item: Event) => item.conversationId === oc));
	await c.call("submit", { id: oc, text: "/slow Take your time." });
	await c.until("answering", () => c.state(oc)?.busy === true);
	await refused("The orchestrator is answering. Let it finish, or stop it, first.");
	await c.call("submit", { id: oc, text: "Queued for later.", mode: "followUp" });
	await refused("Send or take back your queued message first.");
	await c.call("abort", { id: oc });
	await c.until("idle again", () => c.state(oc)?.busy === false);
	await assert.rejects(c.call("projects.startFresh", { id: "p-missing" }), { message: "Unknown project: p-missing" });
	step("Start fresh is refused while the orchestrator answers, has a message queued, or waits on an answer");

	// ---- What is pending when Start fresh comes

	const g = gate();
	const [gated] = await c.tools(oc, `/tools ${JSON.stringify([handOff(`/timeout 600 ${g.wait}; echo gated`, "Gated")])}`);
	const gatedChat = gated!.details.conversationId as number;
	await c.until("its watch", () => c.events.wakes?.items?.some((item: Event) => item.conversationId === oc && item.ref === String(gatedChat)));
	await c.until("its last line in Activity", () => c.events.activity?.runs?.find((run: Event) => run.conversationId === gatedChat)?.lastLine === "Running that command.");
	const asked = await c.tools(oc, `/tool needs_you ${JSON.stringify({ action: "ask", question: "Ship it on Friday?", choices: ["Yes", "No"] })}`);
	const need = /Put to the person as (n\d+)\./.exec(asked[0]!.text)![1]!;
	await c.answer(part, "Before the fresh start.");
	await c.call("work.create", { projectId, title: "Write the release notes" });
	const words = c.project(projectId)!.lastWords;
	assert.equal(typeof words?.text, "string");
	assert.equal(typeof words?.at, "number");

	const { conversation: nc } = await c.call("projects.startFresh", { id: projectId });
	assert.notEqual(nc, oc);
	await c.until("the fresh conversation in the project", () => c.project(projectId)?.conversation === nc);
	assert.deepEqual(c.project(projectId)!.earlier, [oc]);
	await c.until("the library says so", () => c.row(oc)?.orchestrator === "earlier" && c.row(nc)?.orchestrator === "current");
	assert.equal(c.row(nc)!.freshFrom, oc);
	await c.until("the old state says so", () => c.state(oc)?.project?.orchestrator === "earlier");
	assert.ok(c.events.wakes.items.some((item: Event) => item.conversationId === nc && item.ref === String(gatedChat)), "the sub-chat's watch moved");
	assert.ok(!c.events.wakes.items.some((item: Event) => item.conversationId === oc), "nothing left to wake the old one");
	await assert.rejects(c.call("submit", { id: oc, text: "Still there?" }), { message: "This is an earlier conversation with the orchestrator. Write in the current one." });
	await assert.rejects(c.call("continue", { id: oc }), { message: "This is an earlier conversation with the orchestrator. Write in the current one." });
	assert.ok(c.items(oc).length > 0, "the old conversation stays readable");
	assert.equal(c.row(oc)!.archivedAt, undefined);

	await c.open(nc);
	assert.deepEqual(c.state(nc)!.project, { id: projectId, orchestrator: "current" });
	const fresh = await c.context(nc);
	const freshBlock = c.markers(nc, STATE)[0]!.details.wake.text as string;
	assert.deepEqual(fresh, [...freshBlock.split("\n"), "/context"], "nothing of the old conversation: the state block and the message");
	assert.match(freshBlock, new RegExp(`Working now: sub-chat ${gatedChat} “Gated” \\(Worker, since \\d\\d:\\d\\d\\)\\.`));
	assert.match(freshBlock, new RegExp(`Under Needs you: ${need} decision “Ship it on Friday\\?”\\.`));
	assert.match(freshBlock, /\nWork: 1 open, 0 in progress, 0 waiting, 0 blocked\.\n/);
	assert.match(freshBlock, new RegExp(`\\nReports not read: (sub-chat \\d+ “Part \\d+” \\(Worker\\) answered at \\d\\d:\\d\\d; ){9}sub-chat \\d+ “Part \\d+” \\(Worker\\) answered at \\d\\d:\\d\\d\\.\\n`), "told of, not read");
	assert.match(freshBlock, new RegExp(`\\nThe person wrote to Worker in sub-chat ${part}: “Before the fresh start\\.”$`), "a message not yet given is in it");
	const freshSections = await c.answer(nc, "/system project project_rules memory");
	assert.ok(freshSections.includes(rule) && freshSections.includes(note) && freshSections.includes("You are the orchestrator of the pi² project"));
	assert.equal(c.markers(nc, CAUGHT_UP).length, 0, "the state block stood for the news");
	step("Start fresh: a new conversation whose first context is the state block, with the rules and notes in its prompt, and nothing of the old one; the old one readable, taking no messages");

	// ---- The earlier conversation's sub-chats, and an answer to what it asked

	const listing = await c.tools(nc, '/tool sub_chats {"action":"list"}');
	assert.match(listing[0]!.text, new RegExp(`- ${gatedChat} \\(from your earlier conversation ${oc}\\): Worker, “Gated”`));
	assert.match(listing[0]!.text, new RegExp(`- ${part} \\(from your earlier conversation ${oc}\\): Worker, “Part 1”.*Its last report has not been read yet\\.`));
	g.open();
	await c.until("the gated run ended", () => (c.events.reports?.projects?.[projectId] ?? []).some((report: Event) => report.conversationId === gatedChat && report.ended !== null));
	const later = await c.context(nc);
	assert.ok(later.some((line) => new RegExp(`^- Sub-chat ${gatedChat} “Gated” \\(Worker\\) answered at`).test(line)), later.join("\n"));
	const continued = await c.tools(nc, `/continue ${part}: /bash echo again`);
	assert.equal(continued[0]!.isError, false, continued[0]!.text);
	assert.doesNotMatch(continued[0]!.text, /There is no sub-chat/);
	await c.call("needs.answer", { id: need, answer: { kind: "decision", choice: "c1" } });
	await c.until("the answer wakes the fresh conversation", () => c.markers(nc, "pi² woke the agent").length === 1 && c.state(nc)?.busy === false);
	assert.equal(c.markers(oc, "pi² woke the agent").length, 0);
	step("sub_chats lists the earlier conversation's sub-chats and delegate continues one; their reports, and an answer to what it asked, come to the fresh one");

	// ---- Another agent as the orchestrator

	const planner = (await c.call("projects.addAgent", { projectId, agent: { name: "Planner", access: "ask" } })).id as string;
	await assert.rejects(c.call("projects.setOrchestrator", { id: projectId, agentId: lead }), { message: "Lead is not an agent of this project" });
	const orchestratorId = c.project(projectId)!.orchestratorId as string;
	await assert.rejects(c.call("projects.setOrchestrator", { id: projectId, agentId: orchestratorId }), /is the project's orchestrator already/);
	const { conversation: pc } = await c.call("projects.setOrchestrator", { id: projectId, agentId: planner });
	await c.until("Planner orchestrates", () => c.project(projectId)?.orchestratorId === planner && c.project(projectId)?.conversation === pc);
	assert.deepEqual(c.project(projectId)!.earlier, [oc, nc]);
	await c.until("the roles", () => c.events.agents.agents.find((agent: Event) => agent.id === planner)?.role === "orchestrator");
	assert.equal(c.events.agents.agents.find((agent: Event) => agent.id === orchestratorId).role, undefined);
	await c.until("its row", () => c.row(pc)?.agentId === planner && c.row(pc)?.freshFrom === nc);
	await c.open(pc);
	const planned = await c.context(pc);
	assert.equal(planned.at(-1), "/context");
	assert.ok(planned[0]!.startsWith("[pi² — the project as it stands"));
	step("setOrchestrator: another agent of the project orchestrates, with a fresh conversation, the roles changed in the same commit");

	// ---- The preview off: nothing added, news kept

	await c.answer(part, "A note for the orchestrator, while it is on.");
	await c.call("projects.setPreview", { on: false });
	const marks = c.items(pc, "marker").length;
	const off = await c.context(pc);
	assert.equal(c.items(pc, "marker").length, marks, "no catch-up with the preview off");
	assert.ok(!off.some((line) => line.includes("A note for the orchestrator")));
	assert.equal((await c.answer(oc, "An earlier conversation takes messages with the preview off.")).length > 0, true);
	await c.answer(part, "Written with the preview off.");
	assert.equal(c.markers(part, TOLD).length, 4, "nothing is told with the preview off");
	await unchanged("with the preview off again");
	await c.call("projects.setPreview", { on: true });
	const on = await c.context(pc);
	assert.ok(on.some((line) => line.includes("A note for the orchestrator, while it is on.")), "the news kept is given once the preview is on again");
	assert.ok(!on.some((line) => line.includes("Written with the preview off.")));
	await unchanged("after all of it");
	step("with the preview off nothing is added and nothing told; news kept comes once it is on again; a conversation in no project is told the same, byte for byte");

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
