// Keeping this Mac awake while agents work (#561): what the decision is made from, and what a real engine does.
//
// The decision is checked without an engine first: a conversation waiting for the person does not keep the Mac awake,
// battery does only when asked, a failed power read counts as AC. Then a real engine runs against the demo model with a
// stand-in for caffeinate (PI2_AWAKE_PROGRAM), which records its pid for the checks and ends when the engine's process
// does, as `caffeinate -w` does: no check here keeps the real Mac awake, and none reads its power (PI2_AWAKE_POWER,
// which names the source, or a file holding it so that a check can plug the Mac in and unplug it). The grace after the
// last run is made short with PI2_AWAKE_GRACE_MS, and every wait is for the thing itself — the stand-in's process
// appearing and being gone, the run ending, the event saying so — never for a time. The one exception is the second
// the engine waits before starting a holder over again, which is a time of its own: a check that kills the holder
// waits it out rather than racing it.

import assert from "node:assert/strict";
import { spawn, type ChildProcess } from "node:child_process";
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";
import { test } from "node:test";
import { awakeSettings, keepingAwake, readPower, type AwakeState } from "../src/keepawake.ts";
import { exited, stop, until, standInApp, EngineClient } from "./patience.ts";

const main = join(import.meta.dirname, "..", "src", "main.ts");
process.env.PI2_LOGIN_SHELL ??= "off";
// This client changes the setting, which only the app may (#513): a stand-in bundle takes every connection for the app's.
process.env.PI2_APP_BUNDLE = standInApp();
const KEYCHAIN_SERVICE = `dev.pi2.credentials.test-awake-${process.pid}`;

// The stand-in for caffeinate: it records its pid, and ends when the engine's process does ($3, the pid the engine
// passes beside `-w`), whether that process was killed outright or stopped cleanly. The engine stops it directly too,
// and SIGTERM ends it at once; the sleep an interrupt leaves behind ends by itself within a second. Each stands in a
// file of its own, so a check can see that two never ran at once.
const folder = mkdtempSync(join(tmpdir(), "pi2-awake-"));
process.on("exit", () => rmSync(folder, { recursive: true, force: true }));
const holders = join(folder, "holders");
mkdirSync(holders);
const standIn = join(folder, "holder.sh");
writeFileSync(standIn, `#!/bin/sh\necho $$ > "${holders}/$$"\nwhile kill -0 "$3" 2>/dev/null; do sleep 1; done\n`, { mode: 0o755 });
/** The power source a check plugs in and unplugs, for the engines whose PI2_AWAKE_POWER names it. */
const powerFile = join(folder, "power");

/** The stand-ins running now: the assertion is held exactly while one does, and never by two at once. */
function live(): number[] {
	const pids: number[] = [];
	for (const name of readdirSync(holders)) {
		const pid = Number(name);
		try {
			process.kill(pid, 0);
			pids.push(pid);
		} catch {
			// Gone: an ended process is no holder, whether or not its file is still there.
		}
	}
	return pids;
}

/** The pid of the stand-in running now: the one holder, if there is one. */
function holder(): number | undefined {
	return live()[0];
}

/** A stand-in for `runOffThread`, so no check reads the Mac's real power source. */
const said = (stdout: string) => async () => ({ stdout });

test("the decision holds the Mac awake only for work that carries on by itself", () => {
	const awake = (over: Partial<AwakeState>) =>
		keepingAwake({ keep: true, battery: false, power: "ac", working: new Set([1, 2]), waiting: new Set(), ...over });
	assert.deepEqual(awake({}), { hold: true, conversations: 2 });
	// A conversation waiting for the person is not work: nothing of pi²'s carries on while it waits.
	assert.deepEqual(awake({ waiting: new Set([2]) }), { hold: true, conversations: 1 });
	assert.deepEqual(awake({ waiting: new Set([1, 2]) }), { hold: false, conversations: 0 });
	// The setting off, or battery with "Also on battery" off, holds nothing.
	assert.deepEqual(awake({ keep: false }), { hold: false, conversations: 2 });
	assert.deepEqual(awake({ power: "battery" }), { hold: false, conversations: 2 });
	assert.deepEqual(awake({ battery: true, power: "battery" }), { hold: true, conversations: 2 });
});

test("the switch as stored, and the power source as pmset words it", async () => {
	// Absent from settings.json means on, and not on battery.
	assert.deepEqual(awakeSettings(undefined), { keep: true, battery: false });
	assert.deepEqual(awakeSettings({}), { keep: true, battery: false });
	assert.deepEqual(awakeSettings({ keep: false }), { keep: false, battery: false });
	assert.deepEqual(awakeSettings({ battery: true }), { keep: true, battery: true });
	// An override (a test's) is taken as it is; AC power is `pmset -g ps`'s words, and a failed read counts as AC.
	assert.equal(await readPower({ PI2_AWAKE_POWER: "battery" }, said("")), "battery");
	assert.equal(await readPower({}, said("Now drawing from 'AC Power'")), "ac");
	assert.equal(await readPower({}, said("Now drawing from 'Battery Power'")), "battery");
	assert.equal(await readPower({}, async () => {
		throw new Error("pmset failed");
	}), "ac");
	// A file can hold the same words instead, for a check that changes the power source while the engine runs.
	const source = join(folder, "power-read");
	writeFileSync(source, "Now drawing from 'Battery Power'");
	assert.equal(await readPower({ PI2_AWAKE_POWER: source }, said("")), "battery");
	writeFileSync(source, "Now drawing from 'AC Power'");
	assert.equal(await readPower({ PI2_AWAKE_POWER: source }, said("")), "ac");
	assert.equal(await readPower({ PI2_AWAKE_POWER: join(folder, "absent") }, said("")), "ac");
});

// ---- A real engine

/** One engine on its own data folder, with the stand-in for the holder. What it printed is kept in `log`. */
let log = "";
function startEngine(home: string, extra: Record<string, string> = {}): ChildProcess {
	log = "";
	const child = spawn(process.execPath, [main], {
		// The demo model types at one token a second, so a run works for as long as a check needs it to.
		env: { ...process.env, PI2_HOME: home, PI2_KEYCHAIN_SERVICE: KEYCHAIN_SERVICE, PI2_DEMO_TOKENS_PER_SECOND: "1", PI2_AWAKE_PROGRAM: standIn, PI2_AWAKE_GRACE_MS: "10000", PI2_AWAKE_POWER: "ac", ...extra },
		stdio: ["ignore", "ignore", "pipe"],
	});
	child.stderr!.setEncoding("utf8").on("data", (chunk: string) => (log += chunk));
	return child;
}

/** A conversation on the demo model, opened as the app opens one. */
async function conversationOn(client: EngineClient): Promise<number> {
	const { id } = await client.call("conversation.create", { model: { provider: "demo", modelId: "demo-1" } });
	await client.call("conversation.open", { id });
	return id;
}

/** Whether the engine shows the conversation's run as working, which is when the Mac should be kept awake. */
function working(client: EngineClient, id: number): true | undefined {
	return client.events.activity?.runs?.some((run: { conversationId: number; status: string }) => run.conversationId === id && run.status === "working") ? true : undefined;
}

test("held while a run works, let go a short while after the last one ends, and not held with the setting off", async (t) => {
	const home = mkdtempSync(join(tmpdir(), "pi2-awake-home-"));
	t.after(() => rmSync(home, { recursive: true, force: true }));
	let engine: ChildProcess | undefined;
	try {
		engine = startEngine(home);
		const client = await EngineClient.connect(engine, home);
		const id = await conversationOn(client);

		// Held as soon as a run works, and the event the app reads says so.
		await client.call("submit", { id, text: "awake one" });
		const first = await client.until("the assertion held", () => holder());
		await client.until("the awake event says so", () => (client.events.awake?.holding === true ? true : undefined));
		assert.match(log, /keeping this Mac awake: 1 conversation working/);

		// The run ends, and within the grace another starts: the same holder, not let go and begun again.
		await client.call("abort", { id });
		await client.until("the run ended", () => (client.conversations.get(id)?.state?.busy === false ? true : undefined));
		await client.call("submit", { id, text: "awake two" });
		assert.equal(await client.until("still the same holder, no gap", () => (holder() === first ? first : undefined)), first);
		await client.call("abort", { id });
		await client.until("the run ended", () => (client.conversations.get(id)?.state?.busy === false ? true : undefined));

		// Nothing works: let go (the grace here is ten seconds, a minute as the engine runs for the person).
		await client.until("the assertion let go", () => (holder() === undefined ? true : undefined));
		assert.match(log, /letting this Mac sleep again: no conversation is working any more/);
		await client.until("the awake event says so", () => (client.events.awake?.holding === false ? true : undefined));

		// Turning the setting off ends it at once, with a run still working.
		await client.call("submit", { id, text: "awake three" });
		await client.until("held again", () => holder());
		await client.call("settings.setAwake", { keep: false });
		await client.until("let go, the setting off", () => (holder() === undefined ? true : undefined));

		// And back on, mid-run: held again, and a clean stop ends it at once.
		await client.call("settings.setAwake", { keep: true });
		await client.until("held again, the setting back on", () => holder());
		await stop(engine);
		engine = undefined;
		await until("let go when the engine stopped", () => (holder() === undefined ? true : undefined));
		assert.match(log, /letting this Mac sleep again: the engine is stopping/);
		client.close();
	} finally {
		if (engine !== undefined) await stop(engine).catch(() => {});
	}
});

test("on battery, held only with “Also on battery” on; and let go however the engine ends", async (t) => {
	const home = mkdtempSync(join(tmpdir(), "pi2-awake-home-"));
	t.after(() => rmSync(home, { recursive: true, force: true }));
	const engine = startEngine(home, { PI2_AWAKE_POWER: "battery", PI2_AWAKE_GRACE_MS: "500" });
	try {
		const client = await EngineClient.connect(engine, home);
		const id = await conversationOn(client);
		await client.call("settings.setAwake", { keep: true, battery: true });
		assert.deepEqual(JSON.parse(readFileSync(join(home, "settings.json"), "utf8")).awake, { keep: true, battery: true });

		// On battery, held with the switch on, and the log says battery is allowed.
		await client.call("submit", { id, text: "awake battery" });
		await client.until("held on battery, as asked", () => (holder() !== undefined ? true : undefined));
		assert.match(log, /keeping this Mac awake: 1 conversation working \(battery allowed\)/);

		// Not asked: let go at once, with the run still working, and held again once it is asked for.
		await client.call("settings.setAwake", { battery: false });
		await client.until("let go, battery not allowed", () => (holder() === undefined ? true : undefined));
		await client.call("settings.setAwake", { battery: true });
		await client.until("held again, battery asked for", () => (holder() !== undefined ? true : undefined));

		// However the engine ends, the holder ends with it: a kill outright is the case only watching the pid covers.
		engine.kill("SIGKILL");
		await exited(engine);
		await until("let go when the engine was killed outright", () => (holder() === undefined ? true : undefined));
	} finally {
		if (engine.exitCode === null) await stop(engine).catch(() => {});
	}
});

test("nothing is held while a conversation waits for the person, and a holder that dies is held again", async (t) => {
	const home = mkdtempSync(join(tmpdir(), "pi2-awake-home-"));
	t.after(() => rmSync(home, { recursive: true, force: true }));
	let engine: ChildProcess | undefined;
	try {
		engine = startEngine(home, { PI2_AWAKE_GRACE_MS: "500", PI2_AWAKE_POLL_MS: "60000" });
		const client = await EngineClient.connect(engine, home);
		const id = await conversationOn(client);

		// The run works for a few seconds before it asks, so the Mac is kept awake while it does.
		await client.call("submit", { id, text: "/ask Shall I carry on?" });
		const first = await client.until("the assertion held while the run works", () => holder(), 60_000);

		// The holder dies by itself, as one killed would: the engine notices rather than believing it for ever, and holds
		// the Mac awake again while the run still works — one holder, never two.
		await sleep(1_200); // the second the engine waits before starting one that ended at once over again
		process.kill(first, "SIGTERM");
		await client.until("the holder started again", () => {
			const pid = holder();
			return pid !== undefined && pid !== first ? pid : undefined;
		}, 60_000);
		assert.match(log, /the program that keeps this Mac awake ended \(SIGTERM\); holding it again/);
		assert.equal(live().length, 1, "no two holders at once");

		// It asks the person: nothing of pi²'s carries on, so the Mac is let go and the Inbox has the question.
		const item = await client.until("the question in the Inbox", () => client.events.inbox?.items?.[0], 120_000);
		await client.until("let go, everything waits for the person", () => (holder() === undefined ? true : undefined));
		assert.match(log, /letting this Mac sleep again: no conversation is working any more/);

		// The person answers: the work carries on, and so does the assertion.
		await client.call("inbox.answer", { id: item.id, text: "Carry on, please" });
		await client.until("held again once the person answered", () => holder(), 60_000);
	} finally {
		if (engine !== undefined) await stop(engine).catch(() => {});
	}
});

test("the power source is watched while work goes on, and read again when it next matters", async (t) => {
	const home = mkdtempSync(join(tmpdir(), "pi2-awake-home-"));
	t.after(() => rmSync(home, { recursive: true, force: true }));
	let engine: ChildProcess | undefined;
	try {
		writeFileSync(powerFile, "Now drawing from 'Battery Power'");
		engine = startEngine(home, { PI2_AWAKE_POWER: powerFile, PI2_AWAKE_POLL_MS: "300", PI2_AWAKE_GRACE_MS: "300" });
		const client = await EngineClient.connect(engine, home);
		const id = await conversationOn(client);

		// On battery with “Also on battery” off: nothing held, however long the run works.
		await client.call("submit", { id, text: "awake unplugged" });
		await client.until("the run working", () => working(client, id), 60_000);

		// Plugged in while the run works: the power source is looked at again, without a click in Settings.
		writeFileSync(powerFile, "Now drawing from 'AC Power'");
		await client.until("held once the Mac was plugged in", () => holder(), 30_000);

		// Nothing works any more, and it is let go: the power source goes from mattering to not.
		await client.call("abort", { id });
		await client.until("the run ended", () => (client.conversations.get(id)?.state?.busy === false ? true : undefined));
		await client.until("let go, no conversation is working", () => (holder() === undefined ? true : undefined));

		// Unplugged while nothing works: the next run reads the source again rather than trusting the old reading, so the
		// Mac is not held on battery for half a minute before the poll finds out.
		writeFileSync(powerFile, "Now drawing from 'Battery Power'");
		const seen = log.length;
		await client.call("submit", { id, text: "awake unplugged again" });
		await client.until("the run working again", () => working(client, id), 60_000);
		await sleep(1_500); // nothing is held, so there is nothing to wait for; a stale reading held it at once
		assert.equal(holder(), undefined, "on battery, with “Also on battery” off, nothing should be held");
		assert.doesNotMatch(log.slice(seen), /keeping this Mac awake/);
	} finally {
		if (engine !== undefined) await stop(engine).catch(() => {});
	}
});
