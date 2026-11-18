// How the plan's windows reach an agent that hands out work, and the person (#232; docs/limits.md, "Telling an agent
// that hands out work, and the person"): the line in delegate's result when the sub-chat's subscription is nearly used
// up, the windows in sub_chats' list, and the Inbox notice when a window passes 90% while runs on it are going.
//
// First the wording, on a clock of its own; then a real engine on a throwaway data folder and a throwaway Keychain
// service, with two stand-in subscriptions signed in there as pi-ai stores them (not due for renewal, so no real
// sign-in server is called): Claude, whose usage address is a stand-in on 127.0.0.1, and GitHub Copilot, whose sign-in
// names the address its requests go to, here a stand-in over TLS with a certificate only this engine trusts. Copilot's
// answers carry its premium requests in their headers, which the test sets, and the stand-in can hold an answer back
// so that a run is still going when the figures arrive. No real provider is called.
//
// Each check waits for what the engine does, with one exception: a notice's window resets half a minute after the answer
// that names it, which the engine has to have read and looked at within that time. That time is then sat through.

import assert from "node:assert/strict";
import { type ChildProcess, execFileSync, spawn } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import { createServer as createTlsServer } from "node:https";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";
import { GITHUB_COPILOT_MODELS } from "@earendil-works/pi-ai/providers/github-copilot.models";
import { KeychainCredentialStore } from "../src/credentials.ts";
import { limitsReport, nearlyUsedUp, type ProviderLimits, refusedWindow, resetWords, windowWords } from "../src/limits.ts";
import { EngineClient, PATIENT_MS, stop } from "./patience.ts";

function step(name: string): void {
	console.log(`ok  ${name}`);
}

// ---- In words

{
	const now = new Date(2026, 10, 17, 12, 0).getTime(); // Tuesday 17 November 2026, noon, local time
	const five = new Date(2026, 10, 17, 15, 30).getTime();
	const week = new Date(2026, 10, 20, 9, 0).getTime();
	assert.equal(resetWords(five, now), "at 15:30 (in 3 h 30 min)");
	assert.equal(resetWords(week, now), "on Friday 20 November at 09:00 (in 3 days)");
	const claude: ProviderLimits = {
		id: "anthropic",
		name: "Anthropic",
		plan: "Max",
		note: null,
		reports: "usage",
		windows: [
			{ id: "five_hour", label: "5-hour window", usedPercent: 84, resetsAt: five },
			{ id: "seven_day", label: "This week", usedPercent: 40, resetsAt: week },
		],
		fetchedAt: now - 3 * 60_000,
		source: "usage",
		error: null,
		errorAt: null,
		refreshing: false,
	};
	assert.equal(
		nearlyUsedUp(claude, now),
		"Plan limits: the Anthropic subscription (Max), which this sub-chat runs on, has 5-hour window 84% used, resets at 15:30 (in 3 h 30 min). A run the provider refuses for its limit waits for the reset and carries on by itself.",
	);
	const both = { ...claude, windows: [{ ...claude.windows[0]!, usedPercent: 100 }, { ...claude.windows[1]!, usedPercent: 91.5 }] };
	assert.match(nearlyUsedUp(both, now)!, /has 5-hour window used up, resets at 15:30 \(in 3 h 30 min\); this week 91\.5% used, resets on Friday 20 November at 09:00 \(in 3 days\)\./);
	assert.equal(nearlyUsedUp({ ...claude, windows: [{ ...claude.windows[0]!, usedPercent: 79.9 }] }, now), undefined, "below 80%, nothing");
	assert.equal(nearlyUsedUp({ ...claude, windows: [{ ...claude.windows[0]!, resetsAt: now - 1 }] }, now), undefined, "a window that has reset since it was read is not counted");
	assert.equal(nearlyUsedUp(undefined, now), undefined, "a model not on a subscription, nothing");
	assert.equal(windowWords({ id: "premium", label: "Premium requests", usedPercent: 92, resetsAt: null }, now), "premium requests 92% used, reset time not reported");
	assert.equal(windowWords({ id: "five_hour", label: "5-hour window", usedPercent: 97, resetsAt: now - 600_000 }, now), "5-hour window reset 10 min ago (it read 97% before that; not read again since)");

	const codex: ProviderLimits = { ...claude, id: "openai-codex", name: "OpenAI Codex", plan: "Plus", windows: [], fetchedAt: null, source: null, error: "OpenAI did not answer within 6 seconds.", errorAt: now };
	const openai: ProviderLimits = { ...claude, id: "openai", name: "OpenAI", plan: null, reports: "none", windows: [], fetchedAt: null, source: null };
	const report = limitsReport([claude, codex, openai], new Map([["anthropic", ["this conversation", "Forge", "Scout"]], ["openai-codex", ["Scout"]]]), now);
	assert.deepEqual(report, [
		"Plan limits, as last read. A run the provider refuses for its limit waits for the reset and carries on by itself.",
		"- Anthropic subscription (Max), which this conversation, Forge and Scout run on: 5-hour window 84% used, resets at 15:30 (in 3 h 30 min); this week 40% used, resets on Friday 20 November at 09:00 (in 3 days). Read 3 min ago.",
		"- OpenAI Codex subscription (Plus), which Scout runs on: not read yet. The last check failed: OpenAI did not answer within 6 seconds.",
		"- OpenAI subscription, which none of your agents runs on: it does not report its limits.",
	]);
	assert.deepEqual(limitsReport([], new Map(), now), ["Plan limits: no subscription is signed in, so there are no plan windows to watch."]);
	step("the windows in words: delegate's line at 80% or more, naming the subscription, and the whole report for sub_chats");

	// Which window a refusal was for (#343): the one whose reset is the time named, give or take the jitter; else the
	// one most used at 90% or more; else none.
	const windows = [
		{ id: "five_hour", label: "5-hour window", usedPercent: 100, resetsAt: five },
		{ id: "seven_day", label: "This week", usedPercent: 95, resetsAt: week },
	];
	assert.equal(refusedWindow(windows, week + 25_000, true, now)?.id, "seven_day", "the week, whose reset was named, though the 5-hour is fuller");
	assert.equal(refusedWindow(windows, five + 3000, true, now)?.id, "five_hour");
	assert.equal(refusedWindow(windows, now + 30_000, false, now)?.id, "five_hour", "no time named: the fullest");
	assert.equal(refusedWindow([{ ...windows[1]!, usedPercent: 60 }], now + 30_000, false, now), undefined, "none past 90%, none");
	assert.equal(refusedWindow([], now + 30_000, true, now), undefined);
	step("a refusal is matched to the window whose reset it named, or the fullest past 90%");
}

// ---- A real engine with two stand-in subscriptions

const home = mkdtempSync(join(tmpdir(), "pi2-planwindows-"));
const KEYCHAIN_SERVICE = `dev.pi2.credentials.test-planwindows-${process.pid}`;
const store = new KeychainCredentialStore(home, KEYCHAIN_SERVICE);
process.on("exit", () => {
	rmSync(home, { recursive: true, force: true });
	for (const account of ["anthropic", "github-copilot"]) {
		try {
			execFileSync("/usr/bin/security", ["delete-generic-password", "-s", KEYCHAIN_SERVICE, "-a", account], { stdio: "ignore" });
		} catch {}
	}
});

const fiveReset = Date.now() + 2 * 3_600_000;
const monthReset = Date.now() + 9 * 86_400_000;
const json = { "content-type": "application/json" };
const usage = createServer((request, response) => {
	if (request.url !== "/api/oauth/usage") return void response.writeHead(404).end();
	response.writeHead(200, json).end(JSON.stringify({ five_hour: { utilization: 93, resets_at: new Date(fiveReset).toISOString() }, seven_day: { utilization: 41, resets_at: new Date(monthReset).toISOString() } }));
});
await new Promise<void>((resolve) => usage.listen(0, "127.0.0.1", resolve));

const copilotModel = Object.values(GITHUB_COPILOT_MODELS).find((model: any) => model.api === "openai-completions")!.id;
execFileSync("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", join(home, "key.pem"), "-out", join(home, "cert.pem"), "-days", "1", "-subj", "/CN=127.0.0.1", "-addext", "subjectAltName=IP:127.0.0.1"], { stdio: "ignore" });
/**
 * What Copilot's next answers say of its premium requests: the share used, and when they reset, or in how long from the
 * moment the stand-in answers.
 */
let premium: { used: number; resets: number; resetsIn?: number } = { used: 85, resets: monthReset };
/** Set while answers are held back after their headers: the run is going, and the figures are in. */
let held: { release: () => void; promise: Promise<void> } | undefined;
let answered = 0;
const copilot = createTlsServer({ key: readFileSync(join(home, "key.pem")), cert: readFileSync(join(home, "cert.pem")) }, (request, response) => {
	if (request.method !== "POST" || !request.url?.endsWith("/chat/completions")) return void response.writeHead(404).end();
	request.resume().on("end", async () => {
		response.writeHead(200, {
			"content-type": "text/event-stream",
			"x-quota-snapshot-premium_interactions": `ent=300&ov=0.0&ovPerm=false&rem=${100 - premium.used}&rst=${encodeURIComponent(new Date(premium.resetsIn === undefined ? premium.resets : Date.now() + premium.resetsIn).toISOString())}`,
		});
		response.flushHeaders();
		await held?.promise;
		const chunk = (delta: object, finish: string | null) =>
			response.write(`data: ${JSON.stringify({ id: "c1", object: "chat.completion.chunk", created: 1, model: copilotModel, choices: [{ index: 0, delta, finish_reason: finish }] })}\n\n`);
		chunk({ role: "assistant", content: `Copilot stand-in answer ${++answered}.` }, null);
		chunk({}, "stop");
		response.end("data: [DONE]\n\n");
	});
});
await new Promise<void>((resolve) => copilot.listen(0, "127.0.0.1", resolve));
const hold = () => {
	let release!: () => void;
	const promise = new Promise<void>((resolve) => (release = resolve));
	held = { release, promise };
};
const letGo = () => {
	held?.release();
	held = undefined;
};

let log = "";
function startEngine(): ChildProcess {
	const child = spawn(process.execPath, [join(import.meta.dirname, "..", "src", "main.ts")], {
		env: {
			...process.env,
			PI2_HOME: home,
			PI2_KEYCHAIN_SERVICE: KEYCHAIN_SERVICE,
			PI2_LOGIN_SHELL: "off",
			PI2_LIMITS_ANTHROPIC_URL: `http://127.0.0.1:${(usage.address() as { port: number }).port}/api/oauth/usage`,
			PI2_LIMITS_MIN_INTERVAL_MS: "500",
			NODE_EXTRA_CA_CERTS: join(home, "cert.pem"),
		},
		stdio: ["ignore", "ignore", "pipe"],
	});
	child.stderr!.setEncoding("utf8").on("data", (chunk: string) => (log += chunk));
	return child;
}

type Item = { kind: string; text: string; isError?: boolean; details?: any };
type Notice = { id: string; at: number; provider: string; name: string; plan: string | null; window: string; label: string; usedPercent: number; resetsAt: number | null; stage?: string; nearlyAt?: number; runs: { conversationId: number; rootConversationId: number; title: string; agentName: string | null; subChat: boolean }[] };
class Client extends EngineClient {
	get notices(): Notice[] {
		return this.events.limits?.notices ?? [];
	}
	limitsOf(id: string): any {
		return this.events.limits?.providers?.find((p: any) => p.id === id);
	}
	tools(id: number): Item[] {
		return (this.conversations.get(id)?.items ?? []).filter((i: Item) => i.kind === "tool");
	}
	/** Sends `text` to `id` and resolves with the result of the tool call it leads to, once the conversation is idle. */
	async tool(id: number, text: string): Promise<Item> {
		const before = this.tools(id).length;
		await this.call("submit", { id, text });
		return this.until(`a tool result for ${text}`, () => !this.conversations.get(id)!.state.busy && this.tools(id)[before]);
	}
}

const notDue = Date.now() + 30 * 86_400_000;
await store.modify("anthropic", async () => ({ type: "oauth", access: "sk-ant-oat01-planwindows-test-not-a-real-token", refresh: "planwindows-test-refresh-a", expires: notDue }));
await store.modify("github-copilot", async () => ({
	type: "oauth",
	access: `tid=planwindows-test;exp=9999999999;proxy-ep=127.0.0.1:${(copilot.address() as { port: number }).port};`,
	refresh: "planwindows-test-refresh-g",
	expires: notDue,
	availableModelIds: [copilotModel],
}));

let engine = startEngine();
try {
	let client = await Client.connect(engine, home);
	// Read at start; and asked again until it has been, in case that first look did not get an answer in time on a busy
	// Mac (the usage address is given six seconds, and renewing a sign-in twenty).
	// A refresh waits for an ask under way, and sends the event before it answers.
	for (const deadline = Date.now() + PATIENT_MS; !(client.limitsOf("anthropic")?.windows.length > 0); ) {
		assert.ok(Date.now() < deadline, `Claude's windows never read: ${JSON.stringify(client.limitsOf("anthropic"))}\n${log}`);
		await client.call("limits.refresh").catch(() => {});
		if (!(client.limitsOf("anthropic")?.windows.length > 0)) await sleep(600);
	}
	assert.equal(client.limitsOf("anthropic").windows[0].usedPercent, 93);
	assert.deepEqual(client.notices, [], "a window past 90% with nothing running on it is no notice");

	// Scout runs on the Copilot subscription; Atlas, which hands it work, on the demo model; Forge on the default (demo).
	await client.call("agents.save", { agent: { id: "scout", name: "Scout", model: { provider: "github-copilot", modelId: copilotModel } } });
	const { id: lead } = await client.call("conversation.create", { agentId: "atlas", model: { provider: "demo", modelId: "demo-1" } });
	await client.call("conversation.open", { id: lead });

	// Below 80% the result says nothing of the windows; at 85% it ends with a line naming the subscription.
	premium = { used: 50, resets: monthReset };
	let handed = await client.tool(lead, "/delegate Scout: hello");
	assert.equal(handed.isError, false, handed.text);
	assert.ok(handed.text.startsWith("Copilot stand-in answer 1."), handed.text);
	assert.doesNotMatch(handed.text, /Plan limits/);
	const sub = handed.details.conversationId as number;
	premium = { used: 85, resets: monthReset };
	handed = await client.tool(lead, `/continue ${sub}: again`);
	assert.match(handed.text, /\n\nPlan limits: the GitHub Copilot subscription, which this sub-chat runs on, has premium requests 85% used, resets on \w+day \d+ \w+( \d{4})? at \d\d:\d\d \(in 9 days\)\. A run the provider refuses for its limit waits for the reset and carries on by itself\.$/);
	assert.deepEqual(client.notices, [], "85% is no notice");
	step("delegate: no line below 80%; at 85% one naming the subscription, the window, the share used and the reset");

	// sub_chats' list ends with every subscription's windows and who runs on each.
	const listed = await client.tool(lead, '/tool sub_chats {"action":"list"}');
	assert.ok(listed.text.includes("\n\nPlan limits, as last read. A run the provider refuses for its limit waits for the reset and carries on by itself.\n"), listed.text);
	assert.match(listed.text, /\n- Anthropic subscription, which none of your agents runs on: 5-hour window 93% used, resets (at|on) .*; this week 41% used, resets on .*\. Read .* ago\.\n/);
	assert.match(listed.text, /\n- GitHub Copilot subscription, which Scout runs on: premium requests 85% used, resets on .* \(in 9 days\)\. Read .* ago, from the answer to a request\.$/);
	step("sub_chats' list says how each subscription's windows stand and which agents run on it");

	// Past 90% while a run on it is going: one notice, naming that run, and a line in engine.log. Claude's 93% has no
	// run on it, so no notice of its own.
	premium = { used: 91, resets: monthReset };
	hold();
	await client.call("submit", { id: lead, text: `/continue ${sub}: once more` });
	const notice = await client.until("a notice", () => client.notices[0]);
	assert.equal(client.notices.length, 1);
	const { id: _id, at: _at, nearlyAt, ...shown } = notice;
	assert.equal(nearlyAt, notice.at, "the first stage of its story");
	assert.deepEqual(shown, {
		provider: "github-copilot",
		name: "GitHub Copilot",
		plan: null,
		window: "premium",
		label: "Premium requests",
		usedPercent: 91,
		resetsAt: Date.parse(new Date(monthReset).toISOString()),
		stage: "nearly",
		runs: [{ conversationId: sub, rootConversationId: lead, title: "Scout: hello", agentName: "Scout", subChat: true }],
	});
	assert.match(log, new RegExp(`limits: GitHub Copilot, premium requests 91% used \\(resets .*Z\\), with 1 conversation working on it: ${sub}; a notice is in the Inbox`));
	letGo();
	await client.until("the lead idle", () => !client.conversations.get(lead)!.state.busy && client.tools(lead).length === 4);
	assert.match(client.tools(lead)[3]!.text, /premium requests 91% used/);
	step("a window past 90% with a run on it going leaves one notice, naming the run, and a line in engine.log; one with no run on it does not");

	// Once per window per reset: more runs past 90% add nothing, and dismissing it does not bring it back.
	premium = { used: 96, resets: monthReset };
	await client.tool(lead, `/continue ${sub}: and again`);
	assert.equal(client.notices.length, 1, "not noticed twice");
	await client.call("limits.dismiss", { id: notice.id });
	await client.until("dismissed", () => client.notices.length === 0);
	await client.tool(lead, `/continue ${sub}: still more`);
	assert.equal(client.notices.length, 0, "a dismissed notice does not come back before the reset");

	// A reading well below means the window reset: past 90% again, it is noticed again. This time its reset is half a
	// minute after the answer that says so, and the notice leaves the Inbox once that has passed.
	premium = { used: 10, resets: monthReset };
	await client.tool(lead, `/continue ${sub}: a new month`);
	premium = { used: 92, resets: 0, resetsIn: 30_000 };
	hold();
	await client.call("submit", { id: lead, text: `/continue ${sub}: nearly out` });
	await client.until("noticed again after the reset", () => client.notices.length === 1 && client.notices[0]!.usedPercent === 92);
	letGo();
	await client.until("gone once its window reset", () => client.notices.length === 0);
	step("once per window per reset: not repeated, dismissed for good, noticed again after a reset, and gone when its window resets");

	// A notice is kept over a restart, and goes when its subscription is signed out.
	premium = { used: 10, resets: monthReset };
	await client.until("the lead idle again", () => !client.conversations.get(lead)!.state.busy);
	await client.tool(lead, `/continue ${sub}: reset`);
	premium = { used: 95, resets: monthReset };
	hold();
	await client.call("submit", { id: lead, text: `/continue ${sub}: last` });
	const kept = await client.until("a third notice", () => client.notices[0]);
	letGo();
	await client.until("the lead idle at last", () => !client.conversations.get(lead)!.state.busy);
	await stop(engine);
	engine = startEngine();
	client = await Client.connect(engine, home);
	await client.until("the notice after a restart", () => client.notices[0]?.id === kept.id);
	await client.call("providers.logout", { id: "github-copilot" });
	await client.until("gone with the sign-out", () => client.notices.length === 0 && client.limitsOf("github-copilot") === undefined);
	assert.ok(!log.includes("planwindows-test"), "no token in the engine's log");
	step("a notice is kept over a restart and goes when its subscription is signed out");
	console.log("PASS");
} catch (error) {
	// What the engine said, for a failure that is not plain from the check alone.
	process.stderr.write(log);
	throw error;
} finally {
	letGo();
	await stop(engine);
	usage.closeAllConnections();
	usage.close();
	copilot.closeAllConnections();
	copilot.close();
	for (const id of ["anthropic", "github-copilot"]) await store.delete(id).catch(() => {});
}
process.exit(0);
