// An app that stops reading must not stop the engine (#927). Checking the app's connection hands its descriptor to
// the app bundle's `pi2-peer` in `spawn`'s stdio, and on macOS libuv then clears O_NONBLOCK on it in the engine's own
// process, on the open file description the engine's end of the socket is: the engine's next write to an app that does
// not read held its one thread until the app read again, and with it every conversation, agent and phone. A real engine
// with a stand-in bundle whose `pi2-peer` takes every connection for the app's: the app's connection is checked, then
// the app reads nothing for ten seconds while the engine has far more to send it than the socket's buffers hold, and
// another connection is answered throughout. macOS only, for lsof's way of naming sockets and for libuv's posix_spawn.

import assert from "node:assert/strict";
import { type ChildProcess, execFileSync, spawn } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { EngineClient, standInApp, stop } from "./patience.ts";

process.env.PI2_APP_BUNDLE = standInApp();
process.env.PI2_LOGIN_SHELL ??= "off";
const home = mkdtempSync(join(tmpdir(), "pi2-appstall-"));
const main = join(import.meta.dirname, "..", "src", "main.ts");
const KEYCHAIN_SERVICE = `dev.pi2.credentials.test-appstall-${process.pid}`;
const env = { ...process.env, PI2_HOME: home, PI2_KEYCHAIN_SERVICE: KEYCHAIN_SERVICE };

/** How long the app reads nothing, at least: as long as a busy window, or an app paused in a debugger, might. */
const STALL_MS = 10_000;
/** What the engine is made to have for the app meanwhile: macOS gives a Unix socket 8 KiB each way unless asked for more. */
const OWED_BYTES = 4 * 1024 * 1024;
/** A request of the other connection's not answered in this long is a held engine, on any Mac. */
const HELD_MS = 60_000;

let engine: ChildProcess | undefined;
process.on("exit", () => {
	if (engine !== undefined && engine.exitCode === null && engine.signalCode === null) engine.kill("SIGKILL");
	rmSync(home, { recursive: true, force: true });
	try {
		while (true) execFileSync("/usr/bin/security", ["delete-generic-password", "-s", KEYCHAIN_SERVICE], { stdio: "ignore" });
	} catch {
		// None left.
	}
});

function step(text: string): void {
	console.log(`ok  ${text}`);
}

const sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

/** lsof's fields for each Unix socket `pid` holds (or only descriptor `fd`), one record a descriptor. */
function unixSockets(pid: number, fd?: number): Record<string, string>[] {
	const output = execFileSync("/usr/sbin/lsof", ["-a", "-p", String(pid), ...(fd === undefined ? [] : ["-d", String(fd)]), "-U", "+fg", "-F", "fdnG"], { encoding: "utf8" });
	const records: Record<string, string>[] = [];
	for (const line of output.split("\n")) {
		if (line.startsWith("f")) records.push({ f: line.slice(1) });
		else if (line.length > 0 && records.length > 0) records.at(-1)![line[0]!] = line.slice(1);
	}
	return records;
}

engine = spawn(process.execPath, [main], { env, stdio: ["ignore", "ignore", "inherit"] });
try {
	const app = await EngineClient.connect(engine, home);
	const other = await EngineClient.connect(engine, home);
	let read = 0;
	app.socket.on("data", (chunk: string) => (read += Buffer.byteLength(chunk)));

	assert.equal((await app.call("connection.mayAnswer")).mayAnswer, true);
	step("the app's connection is checked: the stand-in's pi2-peer is handed it, and takes it for the app's");

	// The engine's end of the app's connection: lsof names it, by its address, as the other end of this process's.
	const peer = unixSockets(process.pid, (app.socket as unknown as { _handle: { fd: number } })._handle.fd)[0]?.n;
	assert.ok(peer?.startsWith("->"), "lsof names the other end of the app's connection");
	const engineEnd = unixSockets(engine.pid!).find((socket) => socket.d === peer.slice(2));
	assert.ok(engineEnd?.G !== undefined, "lsof names the engine's end of the app's connection, with its flags");
	assert.ok((Number.parseInt(engineEnd.G.split(";")[0]!, 16) & 0x4) !== 0, `the engine's end of the app's connection is left blocking after its check (descriptor ${engineEnd.f}, flags ${engineEnd.G})`);
	step("after the check, the engine's end of the app's connection is still non-blocking");

	const { id } = await app.call("conversation.create", { model: { provider: "demo", modelId: "demo-1" } });
	const reply = JSON.stringify({ id: 1, result: await app.call("engine.info") }).length + 1;
	const count = Math.ceil(OWED_BYTES / reply);
	const done = "Renamed after every request the app sent while it read nothing";

	// The app stops reading, and asks for more than its socket's buffers hold, then renames a conversation: the
	// engine tells every connection of that, so the other connection sees when the engine has handled it all.
	app.socket.pause();
	const stopped = Date.now();
	const before = read;
	const answers = Array.from({ length: count }, () => app.call("engine.info"));
	const renamed = app.call("conversation.rename", { id, title: done });

	let answered = 0;
	let handled = false;
	try {
		while (!handled || Date.now() - stopped < STALL_MS) {
			const asked = Date.now();
			let held: ReturnType<typeof setTimeout> | undefined;
			const answer = await Promise.race([other.call("engine.info"), new Promise<undefined>((resolve) => (held = setTimeout(() => resolve(undefined), HELD_MS)))]);
			clearTimeout(held);
			assert.ok(
				answer !== undefined,
				`the other connection asked ${((asked - stopped) / 1000).toFixed(1)} s after the app stopped reading, and was not answered in ${HELD_MS / 1000} s (${answered} answered before)`,
			);
			answered++;
			handled ||= (other.events.library?.conversations ?? []).some((conversation: { title: string }) => conversation.title === done);
			await sleep(100);
		}
		assert.equal(read, before, "the app read nothing meanwhile");
	} finally {
		// A held engine goes on once its app reads again, and can then be stopped.
		app.socket.resume();
	}
	step(`an app that reads nothing for ${STALL_MS / 1000} s while the engine has ${count} answers for it does not hold the engine: another connection was answered ${answered} times meanwhile`);

	await Promise.all([...answers, renamed]);
	assert.ok(read - before >= OWED_BYTES, `the app was sent all it asked for once it read again (${read - before} bytes)`);
	step(`once the app reads again it is sent everything it was owed, ${((read - before) / 1024 / 1024).toFixed(1)} MiB, far more than its socket's buffers hold`);
} finally {
	await stop(engine);
}
