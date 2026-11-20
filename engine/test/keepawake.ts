// Keeping this Mac awake while agents work (#561): what the decision is made from, and what a real engine does.
//
// The decision is checked without an engine first: a conversation waiting for the person does not keep the Mac awake,
// battery does only when asked, a failed power read counts as AC. Then a real engine runs against the demo model with a
// stand-in for caffeinate (PI2_AWAKE_PROGRAM), which records its pid for the checks and ends when the engine's process
// does, as `caffeinate -w` does: no check here keeps the real Mac awake, and none reads its power (PI2_AWAKE_POWER). The
// grace after the last run is made short with PI2_AWAKE_GRACE_MS, and every wait is for the thing itself — the
// stand-in's process appearing and being gone, the run ending, the event saying so — never for a time.

import assert from "node:assert/strict";
import { spawn, type ChildProcess } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
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
// and SIGTERM ends it at once; the sleep an interrupt leaves behind ends by itself within a second.
const folder = mkdtempSync(join(tmpdir(), "pi2-awake-"));
process.on("exit", () => rmSync(folder, { recursive: true, force: true }));
const marker = join(folder, "holder.pid");
const standIn = join(folder, "holder.sh");
writeFileSync(standIn, `#!/bin/sh\necho $$ > "${marker}"\nwhile kill -0 "$3" 2>/dev/null; do sleep 1; done\n`, { mode: 0o755 });

/** The pid of the stand-in running now, and whether it lives: the assertion is held exactly while one does. */
function holder(): number | undefined {
	if (!existsSync(marker)) return undefined;
	const pid = Number(readFileSync(marker, "utf8"));
	try {
		process.kill(pid, 0);
	} catch {
		return undefined;
	}
	return pid;
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
});

// ---- A real engine

/** One engine on its own data folder, with the stand-in for the holder. What it printed is kept in `log`. */
let log = "";
function startEngine(home: string, extra: Record<string, string> = {}): ChildProcess {
	log = "";
	const child = spawn(process.execPath, [main], {
		// The demo model types at one token a second, so a run works for as long as a check needs it to.
		env: { ...process.env, PI2_HOME: home, PI2_KEYCHAIN_SERVICE: KEYCHAIN_SERVICE, PI2_DEMO_TOKENS_PER_SECOND: "1", PI2_AWAKE_PROGRAM: standIn, PI2_AWAKE_GRACE_MS: "10000", ...extra },
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
