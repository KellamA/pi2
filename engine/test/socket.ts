// The engine's socket path, and a data folder whose path is too long for a Unix socket (issue #15): the socket is then
// reached through a short link, and the engine still starts and answers there.

import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { chmodSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readlinkSync, realpathSync, rmSync, symlinkSync } from "node:fs";
import { connect, createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";
import { MAX_SOCKET_PATH, socketPathFor } from "../src/socket.ts";

function step(name: string): void {
	console.log(`ok  ${name}`);
}

const scratch = realpathSync(mkdtempSync(join(tmpdir(), "pi2-socket-")));
// The test's own folder of links, short enough to hold a socket path (the temporary folder's own path is long).
const linkScratch = mkdtempSync("/tmp/pi2-socket-");
const links = join(linkScratch, "links");
const short = join(scratch, "short");
const long = join(scratch, "a".repeat(60), "b".repeat(60));
mkdirSync(long, { recursive: true });

try {
	assert.equal(socketPathFor(short, links), join(short, "engine.sock"));
	assert.equal(existsSync(links), false, "a short data folder needs no link");
	step("a short data folder's socket is engine.sock in it");

	const path = socketPathFor(long, links);
	assert.ok(Buffer.byteLength(path) <= MAX_SOCKET_PATH, path);
	assert.match(path, /\/[0-9a-f]{16}\/engine\.sock$/);
	const link = join(path, "..");
	assert.equal(readlinkSync(link), long);
	assert.equal(lstatSync(links).mode & 0o777, 0o700);
	assert.equal(socketPathFor(long, links), path, "asking again gives the same path");
	assert.equal(socketPathFor(`${long}/`, links), path, "a trailing slash names the same folder");
	assert.equal(socketPathFor(join(long, "..", "b".repeat(60)), links), path);
	const accented = join(long, "caf\u00e9");
	assert.equal(socketPathFor(accented.normalize("NFD"), links), socketPathFor(accented, links), "decomposed accents name the same folder");
	assert.equal(readlinkSync(join(socketPathFor(accented, links), "..")), accented, "the link holds the composed path");
	step("a long data folder's socket is reached through a short link to it");

	rmSync(link);
	symlinkSync(scratch, link);
	assert.equal(socketPathFor(long, links), path);
	assert.equal(readlinkSync(link), long, "a link pointing elsewhere is replaced");
	rmSync(link);
	assert.equal(socketPathFor(long, links), path);
	assert.equal(readlinkSync(link), long, "a link that went away is made again");
	step("a wrong or missing link is put right");

	chmodSync(links, 0o755);
	assert.throws(() => socketPathFor(long, links), /nobody else can open/);
	chmodSync(links, 0o700);
	const elsewhere = join(linkScratch, "elsewhere");
	mkdirSync(elsewhere, { mode: 0o700 });
	const pointed = join(linkScratch, "pointed");
	symlinkSync(elsewhere, pointed);
	assert.throws(() => socketPathFor(long, pointed), /nobody else can open/, "the folder of links may not itself be a link");
	step("links are only made in a folder of this user's alone");

	const server = createServer((socket) => socket.end("hello\n"));
	await new Promise<void>((resolve, reject) => server.once("error", reject).listen(path, resolve));
	assert.ok(lstatSync(join(long, "engine.sock")).isSocket(), "the socket file is in the data folder");
	const reply = await new Promise<string>((resolve, reject) => {
		const client = connect(path);
		let text = "";
		client.setEncoding("utf8").on("data", (chunk) => (text += chunk)).once("end", () => resolve(text)).once("error", reject);
	});
	assert.equal(reply, "hello\n");
	await new Promise((resolve) => server.close(resolve));
	step("a server listens and a client connects through the link");

	// The engine itself, with the default folder of links in /tmp.
	const home = join(long, "home");
	const enginePath = socketPathFor(home);
	const main = join(import.meta.dirname, "..", "src", "main.ts");
	const keychain = process.env.PI2_TEST_KEYCHAIN_SERVICE ?? "dev.pi2.credentials.test";
	const engine = spawn(process.execPath, [main], { env: { ...process.env, PI2_HOME: home, PI2_KEYCHAIN_SERVICE: keychain }, stdio: ["ignore", "ignore", "inherit"] });
	try {
		let greeting = "";
		for (let attempt = 0; attempt < 100 && greeting === ""; attempt++) {
			await sleep(100);
			greeting = await new Promise<string>((resolve) => {
				const client = connect(enginePath);
				client.setEncoding("utf8");
				client.once("data", (chunk: string) => (client.destroy(), resolve(chunk.split("\n")[0]!)));
				client.once("error", () => resolve(""));
			});
		}
		assert.ok(greeting.startsWith("{"), "the engine answers on the short path");
		assert.ok(lstatSync(join(home, "engine.sock")).isSocket());
		step("the engine starts on a long data folder and answers through the link");
	} finally {
		if (engine.exitCode === null && engine.signalCode === null) {
			const exited = new Promise((resolve) => engine.once("exit", resolve));
			engine.kill("SIGTERM");
			await exited;
		}
		rmSync(join(enginePath, ".."), { force: true });
	}
} finally {
	rmSync(scratch, { recursive: true, force: true });
	rmSync(linkScratch, { recursive: true, force: true });
}
