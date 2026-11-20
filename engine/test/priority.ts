// Agents' commands run at a lower priority than pi² itself (#344, src/priority.ts): a shell command and a background
// command start under `nice`, as does what they start, and the person's switch turns it off for the commands after.
// A real engine on a throwaway data folder, driven over its socket with the demo model.

import assert from "node:assert/strict";
import { type ChildProcess, execFileSync, spawn } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { EngineClient, standInApp, stop } from "./patience.ts";
// The engine takes changes to what the person set only from its app's connection (#513): this test's connection stands
// for the app's, as the tests that answer for the person already do (#504).
process.env.PI2_APP_BUNDLE = standInApp();

const home = mkdtempSync(join(tmpdir(), "pi2-prio-"));
const scratch = realpathSync(mkdtempSync(join(tmpdir(), "pi2-prio-work-")));
const main = join(import.meta.dirname, "..", "src", "main.ts");
const KEYCHAIN_SERVICE = `dev.pi2.credentials.test-priority-${process.pid}`;
process.env.PI2_DEMO_TOKENS_PER_SECOND ??= "100000";
process.env.PI2_LOGIN_SHELL ??= "off";
const env = { ...process.env, PI2_HOME: home, PI2_KEYCHAIN_SERVICE: KEYCHAIN_SERVICE };

let engine: ChildProcess | undefined;
process.on("exit", () => {
	if (engine !== undefined && engine.exitCode === null && engine.signalCode === null) engine.kill("SIGKILL");
	rmSync(home, { recursive: true, force: true });
	rmSync(scratch, { recursive: true, force: true });
	if (process.platform !== "darwin") return;
	try {
		while (true) execFileSync("/usr/bin/security", ["delete-generic-password", "-s", KEYCHAIN_SERVICE], { stdio: "ignore" });
	} catch {
		// None left.
	}
});

function step(name: string): void {
	console.log(`ok  ${name}`);
}

/** The niceness of the test itself, which the engine has too: what a command gets is counted from it. */
const own = Number(execFileSync("/bin/ps", ["-o", "nice=", "-p", String(process.pid)], { encoding: "utf8" }).trim());

class Client extends EngineClient {
	/** What the command the demo model was asked to run printed, once its run is over. */
	async ran(id: number, text: string): Promise<string> {
		const tools = () => (this.conversations.get(id)?.items ?? []).filter((item: any) => item.kind === "tool");
		const before = tools().length;
		await this.call("submit", { id, text });
		await this.until(`the run of ${text}`, () => {
			const conv = this.conversations.get(id);
			return conv !== undefined && !conv.state.busy && tools().length > before;
		});
		return tools().at(-1).text as string;
	}
}

engine = spawn(process.execPath, [main], { env, stdio: ["ignore", "ignore", "inherit"] });
const client = await Client.connect(engine, home);
try {
	await client.until("the priority setting", () => client.events.priority);
	assert.equal(client.events.priority.lower, true, "on unless the person turned it off");
	const { id } = await client.call("conversation.create", { model: { provider: "demo", modelId: "demo-1" } });
	await client.call("conversation.configure", { id, access: "full", cwd: scratch });
	await client.call("conversation.open", { id });

	// The command, and a process it starts, are each `niceness` steps lower than the engine.
	const lowered = Math.min(own + 10, process.platform === "darwin" ? 20 : 19);
	const shell = await client.ran(id, "/bash ps -o nice= -p $$; sh -c 'ps -o nice= -p $$'");
	assert.deepEqual(shell.trim().split(/\s+/).map(Number), [lowered, lowered], `a shell command and what it starts run lower:\n${shell}`);
	assert.match(await client.ran(id, "/bash echo $0 && pwd"), new RegExp(`^/bin/bash\\n${scratch}`), "the same shell, in the same folder");
	step("a shell command and what it starts run at a lower priority, in the same shell and folder");

	const file = join(scratch, "background-nice");
	await client.ran(id, `/background ps -o nice= -p $$ > ${file}`);
	await client.until("the background command to write", () => existsSync(file) && readFileSync(file, "utf8").trim() !== "");
	assert.equal(Number(readFileSync(file, "utf8").trim()), lowered, "a background command too");
	step("a background command runs at a lower priority");

	await client.call("priority.set", { lower: false });
	await client.until("the setting off", () => client.events.priority?.lower === false);
	const plain = await client.ran(id, "/bash ps -o nice= -p $$");
	assert.equal(Number(plain.trim()), own, "with the switch off, a command runs at the engine's own priority");
	await assert.rejects(client.call("priority.set", { lower: "no" }), /true or false/);
	step("turned off, the next command runs at pi²'s own priority");

	// The switch is kept.
	client.close();
	await stop(engine);
	engine = spawn(process.execPath, [main], { env, stdio: ["ignore", "ignore", "inherit"] });
	const again = await Client.connect(engine, home);
	await again.until("the priority setting", () => again.events.priority);
	assert.equal(again.events.priority.lower, false, "off after a restart too");
	await again.call("priority.set", { lower: true });
	again.close();
	step("the switch outlasts a restart");
} finally {
	client.close();
	await stop(engine);
}
