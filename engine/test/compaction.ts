// A real engine with the demo model. The summary and independent work each wait for a gate the test opens.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { closeSync, existsSync, mkdtempSync, openSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createFauxCore } from "@earendil-works/pi-ai/providers/faux";
import { automaticCompactionReady, SUMMARY_TOKENS, summaryThinking } from "../src/compaction.ts";
import { EngineClient, standInApp, stop } from "./patience.ts";

// This test is about conversations in no project, made with the agents of no project: its engines carry nothing into
// projects (`PI2_CARRY_NEVER`, carryover.ts), as the last version with the switch never on did (#715).
process.env.PI2_CARRY_NEVER = "1";
// The engine takes changes to what the person set only from its app's connection (#513): this test's connection stands
// for the app's, as the tests that answer for the person already do (#504).
process.env.PI2_APP_BUNDLE = standInApp();

const home = mkdtempSync(join(tmpdir(), "pi2-compact-"));
const work = realpathSync(mkdtempSync(join(tmpdir(), "pi2-compact-work-")));
const gate = join(work, "summary");
const log = join(home, "engine.log");
const fd = openSync(log, "a");
const engine = spawn(process.execPath, [join(import.meta.dirname, "../src/main.ts")], {
	env: { ...process.env, PI2_HOME: home, PI2_KEYCHAIN_SERVICE: `dev.pi2.credentials.test-compact-${process.pid}`, PI2_LOGIN_SHELL: "off", PI2_DEMO_TOKENS_PER_SECOND: "1000", PI2_DEMO_COMPACTION_GATE: gate },
	stdio: ["ignore", fd, fd],
});
closeSync(fd);

const tool = (name: string, args: object) => `/tool ${name} ${JSON.stringify(args)}`;
const filler = (size: number) => `/compaction-history ${"keep context long enough for a cut ".repeat(size)}`;
const file = (name: string) => join(work, name);
const command = (name: string) => `touch '${file(`${name}.started`)}'; while [ ! -e '${file(name)}' ]; do sleep 0.1; done; printf '%s\\n' '${name} finished'`;
const release = (name: string) => writeFileSync(file(name), "");
const armSummary = (mode = "succeed", second?: string) => {
	rmSync(`${gate}.started`, { force: true });
	rmSync(`${gate}.retry.started`, { force: true });
	if (second !== undefined) writeFileSync(`${gate}.retry`, second);
	writeFileSync(gate, mode);
};
const releaseSummary = (retry = false) => rmSync(retry ? `${gate}.retry` : gate);
const summaryRequest = (retry = false): { prompt: string; maxTokens: number; reasoning?: string } =>
	JSON.parse(readFileSync(`${retry ? `${gate}.retry` : gate}.started`, "utf8"));

let passed = false;
try {
	const { models: [reasoning] } = createFauxCore({ models: [{ id: "reasoning", reasoning: true }], provider: "stand-in" });
	assert.equal(summaryThinking(reasoning), "off");
	assert.equal(summaryThinking(reasoning, { off: null, minimal: null }), "low");
	const failed = { head: 1, tokens: 201, at: 10_000 };
	const afterTenMinutes = failed.at + 600_000;
	assert.equal(automaticCompactionReady(failed, { head: 1, tokens: 222 }, afterTenMinutes - 1), false);
	assert.equal(automaticCompactionReady(failed, { head: 1, tokens: 221 }, afterTenMinutes), false);
	assert.equal(automaticCompactionReady(failed, { head: 1, tokens: 222 }, afterTenMinutes), true);
	assert.equal(automaticCompactionReady(failed, { head: 2, tokens: 201 }, failed.at), true, "a fresh context is not the failed one");

	const client = await EngineClient.connect(engine, home);
	await client.until("initial settings and agents", () => client.events.compactionSettings && client.events.agents);
	const items = (id: number): any[] => client.conversations.get(id)?.items ?? [];
	const state = (id: number) => client.conversations.get(id)?.state;
	const markers = (id: number) => items(id).filter((item) => item.details?.compaction);
	const submit = (id: number, text: string, mode?: string) => client.call("submit", { id, text, mode });
	const answer = async (id: number, text: string) => {
		// An idle event alone could be from the previous run. Wait for a new answer too.
		const previous = items(id).filter((item) => item.kind === "assistant").at(-1)?.id ?? 0;
		const { submissionId } = await submit(id, text);
		await client.until(`submission ${submissionId} to finish`, () => state(id)?.busy === false && state(id)?.compacting === false && items(id).some((item) => item.kind === "assistant" && item.id > previous));
		const { submission } = await client.call("submission.get", { id, submissionId });
		assert.equal(submission.status, "done", JSON.stringify(submission));
		return items(id).find((item) => item.id === submission.answer);
	};
	const open = async (agentId: string) => {
		const { id } = await client.call("conversation.create", { agentId, model: { provider: "demo", modelId: "demo-1" } });
		await client.call("conversation.open", { id });
		await client.until(`conversation ${id}`, () => state(id));
		return id as number;
	};
	const saveAgent = async (agent: Record<string, unknown>) => {
		const { id } = await client.call("agents.save", { agent });
		await client.until(`saved agent ${id}`, () => client.events.agents.agents.some((it: any) => it.id === id && Object.entries(agent).every(([key, value]) => JSON.stringify(it[key]) === JSON.stringify(value))));
		return id as string;
	};
	const worker = await saveAgent({ name: "Compaction Worker", access: "full", cwd: work });
	const lead = await saveAgent({ name: "Compaction Lead", access: "full", cwd: work, delegates: [worker], thinkingLevel: "high" });
	const id = await open(lead);
	assert.deepEqual(await client.call("settings.getCompaction"), { defaultCompactionTokens: null });
	assert.equal(client.events.agents.builtInTools.find((entry: any) => entry.key === "compact").offByDefault, true);
	for (const defaultCompactionTokens of [0, 1.5]) {
		await assert.rejects(client.call("settings.setCompaction", { defaultCompactionTokens }), /whole number/);
	}
	for (const compactionTokens of [-1, 1.5]) {
		await assert.rejects(client.call("agents.save", { agent: { id: lead, name: "Compaction Lead", compactionTokens } }), /whole number/);
	}
	const refused = await answer(id, tool("compact", { note: "not yet offered" }));
	assert.match(refused.text, /tool reported an error/);
	await answer(id, "Please keep the open request named UNFINISHED-418.");
	await answer(id, filler(2_800));
	assert.equal(markers(id).length, 0, "neither setting is on by default");
	assert.ok(state(id).lastRequestInputTokens > 20_000, "the last measured request counts input tokens");
	console.log("ok  settings and tool are off by default; the last request size is reported");

	const short = await open(lead);
	await answer(short, "One short turn.");
	const shortBefore = items(short).slice();
	const notice = "There is too little here to summarise yet.";
	await client.call("conversation.compact", { id: short });
	await client.until("short conversation's notice", () => items(short).at(-1)?.text === notice && state(short)?.compacting === false);
	const shortItems = items(short);
	assert.deepEqual(shortItems.slice(0, -1), shortBefore);
	assert.deepEqual(shortItems.at(-1), { id: shortItems.at(-1).id, kind: "marker", text: notice });
	assert.equal((await answer(short, "/context")).text, "CONTEXT\nOne short turn.\n(answer)\n/context");
	console.log("ok  manual compaction on a short conversation adds one line, not model context");

	// Set the all-agents default, but override it for one agent with an at-window value, then Off.
	await client.call("settings.setCompaction", { defaultCompactionTokens: 2_000 });
	await client.until("the default setting event", () => client.events.compactionSettings.defaultCompactionTokens === 2_000);
	await saveAgent({ id: lead, name: "Compaction Lead", compactionTokens: 128_000 });
	await answer(id, "The window-sized override does not cause an early summary.");
	assert.equal(markers(id).length, 0);
	await saveAgent({ id: lead, name: "Compaction Lead", compactionTokens: 0 });
	await answer(id, "Off also keeps earlier messages despite the lower default.");
	assert.equal(markers(id).length, 0, "Off overrides the all-agents default");
	const inheriting = await open(worker);
	await answer(inheriting, "Some earlier work in a conversation which follows the default.");
	await answer(inheriting, filler(500));
	assert.equal(markers(inheriting)[0].details.compaction.trigger, "size");
	await client.call("settings.setCompaction", { defaultCompactionTokens: null });
	await saveAgent({ id: worker, name: "Compaction Worker", compactionTokens: 2_000 });
	const individual = await open(worker);
	await answer(individual, "Earlier work for the per-agent threshold.");
	armSummary("length", "length");
	await submit(individual, filler(500));
	await client.until("size summary reaches the model", () => existsSync(`${gate}.started`));
	const steer = await submit(individual, "STEER AFTER SIZE FAILURE", "steer");
	releaseSummary();
	await client.until("the shorter size summary reaches the model", () => existsSync(`${gate}.retry.started`));
	releaseSummary(true);
	await client.until("the steer answered despite the failed early summary", () => state(individual)?.busy === false && items(individual).at(-1)?.text?.includes("STEER AFTER SIZE FAILURE"));
	assert.equal((await client.call("submission.get", { id: individual, submissionId: steer.submissionId })).submission.status, "done");
	assert.equal(markers(individual).length, 0);
	assert.match(state(individual).compactionError, /summary is incomplete.*\n.*note on what matters.*start a new conversation/);
	const errorId = state(individual).compactionErrorId;
	await client.call("conversation.dismissCompactionError", { id: individual, errorId: errorId - 1 });
	await client.call("conversation.dismissCompactionError", { id: individual, errorId });
	await client.until("the warning is dismissed", () => state(individual)?.compactionError === null);
	armSummary();
	await submit(individual, "NEXT TURN IN COOLDOWN");
	await client.until("answer or unexpected repeat summary", () => existsSync(`${gate}.started`) || (state(individual)?.busy === false && items(individual).at(-1)?.kind === "assistant" && items(individual).at(-1)?.text?.includes("NEXT TURN IN COOLDOWN")));
	assert.equal(existsSync(`${gate}.started`), false, "dismissing the banner does not let automatic attempts through");
	assert.equal(markers(individual).length, 0);
	// A separate long history makes a normal-tail manual cut eligible even while the early threshold is cooling down.
	releaseSummary();
	await answer(individual, filler(2_800));
	armSummary();
	await client.call("conversation.compact", { id: individual });
	await client.until("manual summary bypasses cooldown", () => existsSync(`${gate}.started`));
	releaseSummary();
	await client.until("a manual marker", () => markers(individual)[0]?.details.compaction.trigger === "person");
	await saveAgent({ id: worker, name: "Compaction Worker", compactionTokens: null });
	console.log("ok  an early summary fails twice; a steer survives; cooldown survives dismissal and manual compaction bypasses it");

	const overflowing = await open(lead);
	await answer(overflowing, "Earlier context before the provider reports overflow.");
	await answer(overflowing, filler(2_800));
	armSummary("fail");
	await submit(overflowing, "/compaction-overflow");
	await client.until("summary after provider overflow", () => existsSync(`${gate}.started`));
	releaseSummary();
	await client.until("first overflow run fails", () => state(overflowing)?.busy === false && state(overflowing)?.compactionError?.includes("refused"));
	const overflowWarning = state(overflowing).compactionErrorId;
	armSummary();
	const nextOverflow = await submit(overflowing, "/compaction-overflow");
	await client.until("second overflow ends or reaches the summary again", () => existsSync(`${gate}.started`) ||
		(state(overflowing)?.busy === false && items(overflowing).at(-1)?.kind === "assistant" && items(overflowing).filter((item) => item.kind === "user" && item.text === "/compaction-overflow").length === 2));
	assert.equal(existsSync(`${gate}.started`), false, "provider overflow cannot bypass the cooldown");
	assert.equal(state(overflowing).compactionErrorId, overflowWarning);
	assert.notEqual((await client.call("submission.get", { id: overflowing, submissionId: nextOverflow.submissionId })).submission.status, "done");
	releaseSummary();
	console.log("ok  a provider-reported overflow cannot bypass the automatic cooldown");

	const beforeLength = items(id).slice();
	armSummary("length", "length");
	await client.call("conversation.compact", { id, instructions: "Keep UNFINISHED-418." });
	await client.until("length-limited summary reaches the model", () => existsSync(`${gate}.started`));
	const first = summaryRequest();
	assert.equal(first.maxTokens, SUMMARY_TOKENS);
	assert.equal(first.reasoning, undefined, "the high-thinking conversation gets a summary with thinking off");
	releaseSummary();
	await client.until("shorter retry after length stop", () => existsSync(`${gate}.retry.started`));
	const second = summaryRequest(true);
	assert.equal(second.maxTokens, first.maxTokens);
	assert.equal(second.reasoning, first.reasoning);
	assert.ok(second.prompt.startsWith(first.prompt));
	assert.match(second.prompt, /at most 12000 tokens.*open requests, decisions, standing instructions, blockers, and what is running/);
	assert.doesNotMatch(second.prompt, /An unfinished summary/);
	releaseSummary(true);
	await client.until("length failure", () => state(id)?.compacting === false && state(id)?.compactionError?.includes("summary is incomplete"));
	assert.deepEqual(items(id), beforeLength);
	assert.equal(markers(id).length, 0);
	assert.match((await answer(id, "/compaction-context")).text, /UNFINISHED-418/, "double length failure keeps the old context");
	console.log("ok  two length stops leave no summary; the retry has the same source and a shorter target");

	// Exercise the idle (menu) boundary with a failure. No new history beyond the input and answer; no hidden head change.
	const before = items(id).slice();
	armSummary("fail");
	await client.call("conversation.compact", { id, instructions: "don't lose the open request" });
	await client.until("menu summary reaches the model", () => existsSync(`${gate}.started`));
	const queued = await submit(id, "MESSAGE AFTER FAILED MENU SUMMARY");
	assert.equal((await client.call("submission.get", { id, submissionId: queued.submissionId })).submission.status, "queued");
	assert.deepEqual(items(id), before);
	releaseSummary();
	await client.until("the queued message answered after the menu summary failed", () => state(id)?.busy === false && items(id).at(-1)?.text?.includes("MESSAGE AFTER FAILED MENU SUMMARY"));
	assert.deepEqual(items(id).slice(0, before.length), before);
	assert.equal(markers(id).length, 0);
	assert.match(state(id).compactionError, /refused/);
	assert.match((await answer(id, "/compaction-context")).text, /UNFINISHED-418/, "no hidden change to model context on failure");
	armSummary("length", "succeed");
	await client.call("conversation.compact", { id });
	await client.until("first request of successful menu summary", () => existsSync(`${gate}.started`));
	releaseSummary();
	await client.until("successful shorter request reaches the model", () => existsSync(`${gate}.retry.started`));
	assert.equal(markers(id).length, 0, "nothing is placed after the first stop for length");
	releaseSummary(true);
	await client.until("successful menu summary", () => markers(id)[0]?.details.compaction.trigger === "person" && state(id)?.compactionError === null);
	assert.equal(markers(id).length, 1);
	console.log("ok  failure releases queued input; a length retry succeeds and clears the warning");

	// At the agent boundary, keep durable work that the demo summarizer deliberately ignores.
	await saveAgent({ id: lead, name: "Compaction Lead", toolsOn: ["compact"] });
	await answer(id, tool("update_plan", { items: [{ content: "Preserve this in-progress plan", status: "in_progress" }] }));
	await answer(id, tool("delegate", { agent: worker, title: "Still running", task: `/timeout 600 ${command("subchat")}`, wait: false }));
	await answer(id, tool("bash", { command: command("unwatched"), background: true }));
	await answer(id, tool("bash", { command: command("watched"), background: true, wake: true }));
	await client.until("all commands at their gates", () => ["subchat", "watched", "unwatched"].every((name) => existsSync(file(`${name}.started`))));
	armSummary();
	await submit(id, tool("compact", { note: "Verbatim rule: keep KNOWN-418." }));
	await client.until("agent summary reaches the model", () => existsSync(`${gate}.started`));
	assert.ok(items(id).some((item) => item.name === "compact" && !item.isError), "compaction is after the tool result");
	assert.match(summaryRequest().prompt, /Keep every unfinished request.*Preserve what the person asked/s);
	assert.match(summaryRequest().prompt, /Verbatim rule: keep KNOWN-418/);
	const during = await submit(id, "PERSON DURING SUMMARY", "steer");
	release("watched");
	await client.until("the wake durably arrived while summarizing", () => client.events.wakes?.items.some((each: any) => each.state === "arrived" && each.kind === "background"));
	assert.equal((await client.call("submission.get", { id, submissionId: during.submissionId })).submission.status, "queued");
	assert.equal(markers(id).length, 1);
	assert.equal(items(id).filter((item) => item.details?.wake).length, 0);
	releaseSummary();
	await client.until("the wake and its answer after the tool-requested summary", () => state(id)?.busy === false && items(id).at(-1)?.text?.includes("watched finished"));
	const marker = markers(id)[1];
	assert.deepEqual(marker.details.compaction, { trigger: "agent", note: "Verbatim rule: keep KNOWN-418." });
	const placed = items(id).find((item) => item.kind === "user" && item.text === "PERSON DURING SUMMARY");
	const woke = items(id).filter((item) => item.details?.wake);
	assert.equal(woke.length, 1);
	assert.ok(marker.id < placed.id && placed.id < woke[0].id);
	assert.equal((await client.call("submission.get", { id, submissionId: during.submissionId })).submission.status, "done");
	const context = (await answer(id, "/compaction-context")).text;
	assert.match(context, /Current state recorded by pi²/);
	assert.match(context, /Open sub-chat \d+ "Still running".*working.*Task:.*subchat/s);
	assert.match(context, /Background command bg-\d+ is running: .*unwatched.*will not wake you/);
	assert.match(context, /The answer from sub-chat .* is watched for a wake/);
	assert.match(context, /Wake awaiting delivery: background command bg-\d+/);
	assert.match(context, /\[in_progress\] Preserve this in-progress plan/);
	assert.match(context, /Verbatim rule: keep KNOWN-418/);
	await answer(id, tool("compact", { note: "A later note." }));
	assert.match((await answer(id, "/compaction-context")).text, /Notes from the agent on what must be kept \(verbatim\):\nVerbatim rule: keep KNOWN-418\.\nA later note\./);
	release("unwatched");
	release("subchat");
	console.log("ok  tool boundary, retained live state and notes, and person input then wake delivered once after compaction");
	passed = true;
} finally {
	await stop(engine);
	if (!passed) console.error(readFileSync(log, "utf8"));
	rmSync(work, { recursive: true, force: true });
	rmSync(home, { recursive: true, force: true });
}
