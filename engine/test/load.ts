// What the load script (scripts/load.mts, #344) needs of the engine: the demo model's "/work", which writes and runs a
// command again and again as a working agent does, and `engine.lag`, how late the engine's thread ran. A real engine
// on a throwaway data folder, driven over its socket.

import assert from "node:assert/strict";
import { type ChildProcess, execFileSync, spawn } from "node:child_process";
import { mkdtempSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { EngineClient, stop } from "./patience.ts";

const home = mkdtempSync(join(tmpdir(), "pi2-load-"));
const scratch = realpathSync(mkdtempSync(join(tmpdir(), "pi2-load-work-")));
const main = join(import.meta.dirname, "..", "src", "main.ts");
const KEYCHAIN_SERVICE = `dev.pi2.credentials.test-load-${process.pid}`;
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

engine = spawn(process.execPath, [main], { env, stdio: ["ignore", "ignore", "inherit"] });
const client = await EngineClient.connect(engine, home);
try {
	const { id } = await client.call("conversation.create", { model: { provider: "demo", modelId: "demo-1" } });
	await client.call("conversation.configure", { id, access: "full", cwd: scratch });
	await client.call("conversation.open", { id });

	// "/work <steps> <tokens a second> <command>": a paragraph and the command, `steps` times, then a last answer. Its
	// pace is its own, whatever the demo model's usual one, so the test takes no longer than the commands.
	await client.call("submit", { id, text: "/work 3 100000 echo step done" });
	const items = await client.until("the work to end", () => {
		const conv = client.conversations.get(id);
		const last = conv?.items.at(-1);
		return conv !== undefined && !conv.state.busy && last?.kind === "assistant" && last.toolCalls.length === 0 ? (conv.items as any[]) : undefined;
	});
	const tools = items.filter((item) => item.kind === "tool");
	assert.equal(tools.length, 3, "the command ran three times");
	for (const tool of tools) assert.match(tool.text, /step done/);
	const said = items.filter((item) => item.kind === "assistant").map((item) => item.text as string);
	assert.match(said[0]!, /^Step 1 of 3\./, "each step writes a paragraph before its command");
	assert.match(said[2]!, /^Step 3 of 3\./);
	assert.equal(said.at(-1), "Done: I ran it 3 times.");
	step("/work runs its command the number of times asked, writing between them");

	// A message after it is answered as any other: /work is read from the latest message only.
	await client.call("submit", { id, text: "Hello" });
	await client.until("the answer to Hello", () => {
		const conv = client.conversations.get(id);
		const last = conv?.items.at(-1);
		return conv !== undefined && !conv.state.busy && last?.kind === "assistant" && /^You said: "Hello"/.test(last.text);
	});
	step("a later message is not taken for more work");

	const lag = await client.call("engine.lag");
	for (const key of ["over", "p50", "p99", "max", "busy"]) assert.equal(typeof lag[key], "number", `engine.lag gives ${key}`);
	assert.ok(lag.p50 <= lag.p99 && lag.p99 <= lag.max, "the median is at most the 99th percentile, which is at most the worst");
	assert.ok(lag.busy >= 0 && lag.busy <= 1, "busy is a share");
	assert.ok(Array.isArray(lag.stalls));
	step("engine.lag says how late the engine's thread ran since it was last asked");
} finally {
	client.close();
	await stop(engine);
}
