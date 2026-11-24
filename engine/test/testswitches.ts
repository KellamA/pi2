// The switches only tests set (#720, src/testswitches.ts): honoured by a development engine, ignored by a release one,
// which says once at start which of them it was given. Two real engines on throwaway data folders and Keychain
// services, given every test switch, with each gate's file in place: this one, run from the checkout, and a release
// engine as a release build lays one out (these sources copied into a stand-in app's `Contents/Resources/engine`, with
// a `BUILD` file beside them, and the app's `pi2-peer` helper a stand-in that takes this test's connection for the
// app's, as standInApp does for a development engine).
//
// Checked: the development engine offers the demo models the switches add (the text-only one, the picture models, a
// demo model that thinks), prices the demo model, holds a backup at its gate until the gate's file goes, and writes no
// line about ignoring anything. The release engine offers the demo model alone and as it ships, counts its spend as
// free, makes a backup at once with the gate's file there, touches no gate, and names in one line, once, every switch
// it was given. And in the sources: every test switch named in src is on the list, and none is read but through it.
//
// The stand-ins and tunings only tests set (#743) are given too, each its usual value or a stand-in nothing here reaches
// (their own tests show a development engine honours them); the release engine names them with the rest. It is told
// not to keep the Mac awake before it answers, since it ignores the stand-in for caffeinate that patience.ts names.

import assert from "node:assert/strict";
import { type ChildProcess, execFileSync, spawn } from "node:child_process";
import { closeSync, cpSync, existsSync, mkdirSync, mkdtempSync, openSync, readdirSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { CATALOG, KEEP_FREE_BYTES } from "../src/localcatalog.ts";
import { ignoredLine, TEST_SWITCHES } from "../src/testswitches.ts";
import { EngineClient, standInApp, stop, until } from "./patience.ts";

const source = join(import.meta.dirname, "..", "src");
const work = realpathSync(mkdtempSync(join(tmpdir(), "pi2-switches-")));
const services: string[] = [];
const engines: ChildProcess[] = [];
process.on("exit", () => {
	for (const engine of engines) if (engine.exitCode === null && engine.signalCode === null) engine.kill("SIGKILL");
	rmSync(work, { recursive: true, force: true });
	for (const service of services) {
		try {
			while (true) execFileSync("/usr/bin/security", ["delete-generic-password", "-s", service], { stdio: "ignore" });
		} catch {
			// None left.
		}
	}
});

function step(name: string): void {
	console.log(`ok  ${name}`);
}

// ---- The sources: every test switch is on the list, and read only through testSwitch

const TEST_ONLY = /^(PI2_[A-Z0-9_]*_GATE|PI2_DEMO_[A-Z0-9_]+|PI2_CARRY_NEVER|PI2_TEST_[A-Z0-9_]+|PI2_LIMITS_[A-Z0-9]+_URL)$/;
for (const file of readdirSync(source).filter((name) => name.endsWith(".ts") && name !== "testswitches.ts")) {
	const text = readFileSync(join(source, file), "utf8");
	for (const [name] of text.matchAll(/\bPI2_[A-Z0-9_]+\b/g)) {
		if (TEST_ONLY.test(name)) assert.ok((TEST_SWITCHES as readonly string[]).includes(name), `${file} names ${name}, a test switch that is not in TEST_SWITCHES (testswitches.ts)`);
	}
	for (const [read, name] of text.matchAll(/\benv(?:\.|\[\s*["'`])(PI2_[A-Z0-9_]+)/g)) {
		assert.ok(!(TEST_SWITCHES as readonly string[]).includes(name!), `${file} reads ${read} itself: a test switch is read with testSwitch (testswitches.ts)`);
	}
}
step("every test switch src names is on the list, and none is read but through testSwitch");

// ---- Every switch, each gate's file in place

const gates = Object.fromEntries(TEST_SWITCHES.filter((name) => name.endsWith("_GATE")).map((name) => [name, join(work, name.toLowerCase())]));
const SWITCHES: Record<string, string> = {
	...gates,
	PI2_CARRY_NEVER: "1",
	PI2_DEMO_COST: "5",
	// Nothing listens here: the picture models are only offered, never asked.
	PI2_DEMO_PICTURES: "http://127.0.0.1:9/v1",
	PI2_DEMO_TEXT_MODEL: "1",
	PI2_DEMO_TOKENS_PER_SECOND: "100000",
	PI2_TEST_COPY: "test-switches",
	// The stand-ins: addresses nothing here asks (no provider is signed in, no page fetched), the stand-in for caffeinate
	// that patience.ts names, and the catalog as it ships.
	PI2_TEST_ALLOW_ADDRESS: "127.0.0.1:9",
	PI2_LIMITS_ANTHROPIC_URL: "http://127.0.0.1:9/usage",
	PI2_LIMITS_CODEX_URL: "http://127.0.0.1:9/usage",
	PI2_LIMITS_KIMI_URL: "http://127.0.0.1:9/usage",
	PI2_AWAKE_PROGRAM: process.env.PI2_AWAKE_PROGRAM!,
	PI2_AWAKE_POWER: "ac",
	PI2_LOCAL_CATALOG: join(work, "catalog.json"),
	// Paired devices: nothing pairs here, so pi² Remote's stand-in is never started nor App Attest's asked; an empty
	// PI2_UNPLACED_HANDLER adds no request, so the engine starts.
	PI2_REMOTE_STAND_IN: join(work, "no-remote.mjs"),
	PI2_APP_ATTEST_STAND_IN: "1",
	PI2_APP_ATTEST_TEAM: "ABCDE12345",
	PI2_UNPLACED_HANDLER: "",
	PI2_DEVICE_SESSION_MS: "86400000",
	PI2_APPROVAL_DEPTH_THROWS: "1",
	// The tunings, at their usual values.
	PI2_AWAKE_GRACE_MS: "60000",
	PI2_AWAKE_POLL_MS: "30000",
	PI2_COMMAND_TIMEOUT_SECONDS: "120",
	PI2_OUTPUT_WAIT_SECONDS: "30",
	PI2_LIMITS_MIN_INTERVAL_MS: "60000",
	PI2_LIMIT_BACKOFF_MS: "15000",
	PI2_LIMIT_WAIT_MAX_MS: "21600000",
	PI2_LIMIT_REMEMBER_MS: "60000",
	PI2_LIMIT_REACHED_MS: "300000",
	PI2_LOCAL_STALL_MS: "60000",
	PI2_LOCAL_RETRY_MS: "2000",
	PI2_LOCAL_RETRIES: "8",
	PI2_LOCAL_KEEP_FREE: String(KEEP_FREE_BYTES),
	PI2_LOCAL_MEMORY_GB: "64",
	PI2_LOCAL_RUN_RETRY_MS: "2000",
	PI2_WAKES_PER_HOUR: "30",
};
writeFileSync(SWITCHES.PI2_LOCAL_CATALOG!, JSON.stringify(CATALOG));
assert.deepEqual(Object.keys(SWITCHES).sort(), [...TEST_SWITCHES].sort(), "this test gives every test switch");
const armGates = () => {
	for (const file of Object.values(gates)) {
		writeFileSync(file, "");
		rmSync(`${file}.started`, { force: true });
	}
};

class Client extends EngineClient {
	/** Sends `text` to a new conversation with the demo model and waits for its answer. */
	async answered(text: string): Promise<void> {
		const { id } = await this.call("conversation.create", { model: { provider: "demo", modelId: "demo-1" } });
		await this.call("conversation.open", { id });
		await this.call("submit", { id, text });
		await this.until(`the answer to ${text}`, () => {
			const conversation = this.conversations.get(id);
			return conversation?.state?.busy === false && conversation.items.some((item: any) => item.kind === "assistant");
		});
	}
	demoModels(): Promise<any[]> {
		return this.until("the demo models", () => this.events.providers?.models.filter((model: any) => model.provider === "demo"));
	}
	pictureModels(): Promise<string[]> {
		return this.until("the picture models", () => this.events.pictures?.models.map((model: any) => model.id as string));
	}
}

async function start(name: string, main: string, extra: Record<string, string> = {}): Promise<{ client: Client; engine: ChildProcess; home: string; log: () => string }> {
	const home = join(work, `${name}-home`);
	mkdirSync(home);
	const service = `dev.pi2.credentials.test-switches-${name}-${process.pid}`;
	services.push(service);
	const logPath = join(home, "engine.log");
	const log = openSync(logPath, "a");
	const engine = spawn(process.execPath, [main], {
		env: { ...process.env, PI2_HOME: home, PI2_KEYCHAIN_SERVICE: service, PI2_LOGIN_SHELL: "off", ...SWITCHES, ...extra },
		stdio: ["ignore", log, log],
	});
	closeSync(log);
	engines.push(engine);
	return { client: await Client.connect(engine, home), engine, home, log: () => readFileSync(logPath, "utf8") };
}

// ---- A development engine honours them

{
	armGates();
	// A backup is the person's to ask for (#504): the stand-in takes this test's connection for the app's.
	const { client, engine, log } = await start("development", join(source, "main.ts"), { PI2_APP_BUNDLE: standInApp() });
	try {
		const demo = await client.demoModels();
		assert.deepEqual(demo.map((model) => model.id), ["demo-1", "demo-text"], "PI2_DEMO_TEXT_MODEL adds the text-only model");
		assert.ok(demo[0].thinkingLevels.length > 0, "PI2_DEMO_COMPACTION_GATE makes the demo model one that thinks");
		assert.deepEqual(await client.pictureModels(), ["demo-pictures", "demo-pictures-unpriced"], "PI2_DEMO_PICTURES adds the picture models");

		const gate = gates.PI2_BACKUP_GATE!;
		const backups = join(work, "development-backups");
		mkdirSync(backups);
		const made = client.call("backup.create", { directory: backups });
		await until("the backup held at PI2_BACKUP_GATE", () => existsSync(`${gate}.started`), { over: () => (client.closed ? "the connection closed" : undefined) });
		assert.ok(readdirSync(backups).every((name) => name.endsWith(".partial")), "the copy waits with its folder still partial");
		rmSync(gate);
		assert.ok(existsSync((await made).path), "and finishes once the gate's file is gone");

		await client.answered("hello");
		const usage = await client.until("the spend counted", () => client.events.usage?.total.tokens > 0 && client.events.usage);
		assert.ok(usage.total.cost > 0, "PI2_DEMO_COST prices the demo model");

		assert.ok(log().includes("PI2_CARRY_NEVER is set: this development engine carries nothing into projects"));
		assert.ok(!log().includes("set and ignored"), "a development engine ignores none of them");
	} finally {
		client.close();
		await stop(engine);
	}
	step("a development engine honours the gates and the demo model's switches, and ignores none");
}

// ---- A release engine ignores them, and says so once

{
	armGates();
	// Laid out as in a release build: the app's own helper beside the engine says whether a connection is the app's.
	const bundle = join(work, "Stand-in.app");
	const engineFolder = join(bundle, "Contents", "Resources", "engine");
	cpSync(source, join(engineFolder, "src"), { recursive: true });
	cpSync(join(source, "..", "package.json"), join(engineFolder, "package.json"));
	symlinkSync(join(source, "..", "node_modules"), join(engineFolder, "node_modules"));
	writeFileSync(join(engineFolder, "BUILD"), "test-release\n");
	cpSync(join(standInApp(), "Contents", "MacOS"), join(bundle, "Contents", "MacOS"), { recursive: true });
	const { client, engine, log } = await start("release", join(engineFolder, "src", "main.ts"));
	try {
		const info = await client.call("engine.info");
		assert.equal(info.build, "test-release", "a release engine");

		const demo = await client.demoModels();
		assert.deepEqual(demo.map((model) => model.id), ["demo-1"], "no text-only demo model");
		assert.deepEqual(demo[0].thinkingLevels, [], "the demo model as it ships, which does not think");
		assert.deepEqual(await client.pictureModels(), [], "no demo picture models");

		const backups = join(work, "release-backups");
		mkdirSync(backups);
		assert.ok(existsSync((await client.call("backup.create", { directory: backups })).path), "a backup made with PI2_BACKUP_GATE's file there");

		// It ignores PI2_AWAKE_PROGRAM: without this, its answer would keep this Mac awake with the real caffeinate.
		await client.call("settings.setAwake", { keep: false });
		await client.answered("hello");
		const usage = await client.until("the spend counted", () => client.events.usage?.total.tokens > 0 && client.events.usage);
		assert.equal(usage.total.cost, 0, "the demo model is free, PI2_DEMO_COST or not");

		for (const file of Object.values(gates)) assert.ok(existsSync(file) && !existsSync(`${file}.started`), `${file}: no gate was reached`);
		const lines = log().split("\n").filter((line) => line.includes("set and ignored:"));
		assert.deepEqual(lines.map((line) => line.slice(line.indexOf("[pi2-engine] ") + 13)), [
			ignoredLine([...TEST_SWITCHES]),
			"PI2_CARRY_NEVER is set and ignored: a release engine always carries over",
		]);
		step(`a release engine ignores every test switch and says so once: ${lines[0]!.slice(lines[0]!.indexOf("[pi2-engine] ") + 13)}`);
	} finally {
		client.close();
		await stop(engine);
	}
}
