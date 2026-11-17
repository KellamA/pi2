// An engine told to stop while it is still starting stops cleanly (issue #100): it does not leave the marker that makes
// the next start report a crash, and it does not leave the login shell it was asking for its PATH running.
//
// The engine is held in start-up by a stand-in login shell that never answers, with start-up's wait for it made far
// longer than the test (PI2_LOGIN_SHELL_TIMEOUT_SECONDS). The signal is sent once the stand-in has said it is running,
// so it always comes while the engine is starting, however busy the Mac is: nothing here is timed.

import assert from "node:assert/strict";
import { type ChildProcess, spawn, spawnSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { connect } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";
import { socketPathFor } from "../src/socket.ts";

const scratch = realpathSync(mkdtempSync(join(tmpdir(), "pi2-earlystop-")));
const home = join(scratch, "home");
const main = join(import.meta.dirname, "..", "src", "main.ts");
const shellPidFile = join(scratch, "shell.pid");
const sleepPidFile = join(scratch, "sleep.pid");
const engines: ChildProcess[] = [];

function step(name: string): void {
	console.log(`ok  ${name}`);
}
async function until(what: string, met: () => boolean, ms = 120_000): Promise<void> {
	for (const deadline = Date.now() + ms; !met(); ) {
		if (Date.now() > deadline) throw new Error(`Timed out waiting for ${what}`);
		await sleep(25);
	}
}
const pidIn = (file: string): number | undefined => {
	const text = existsSync(file) ? readFileSync(file, "utf8").trim() : "";
	return text === "" ? undefined : Number(text);
};
/** Whether `pid` is still this test's own process: running (not a zombie waiting to be reaped) a command with `part`. */
const stillRunning = (pid: number, part: string): boolean => {
	const [stat = "", ...rest] = spawnSync("/bin/ps", ["-o", "stat=,command=", "-p", String(pid)], { encoding: "utf8" }).stdout.trim().split(/\s+/);
	return stat !== "" && !stat.startsWith("Z") && rest.join(" ").includes(part);
};

function startEngine(env: NodeJS.ProcessEnv) {
	const engine = spawn(process.execPath, [main], {
		env: { ...process.env, PI2_HOME: home, PI2_KEYCHAIN_SERVICE: "dev.pi2.credentials.test-earlystop", PI2_DEMO_TOKENS_PER_SECOND: "1000", ...env },
		stdio: ["ignore", "ignore", "pipe"],
	});
	engines.push(engine);
	const log: string[] = [];
	let rest = "";
	engine.stderr!.setEncoding("utf8").on("data", (chunk: string) => {
		const all = (rest + chunk).split("\n");
		rest = all.pop()!;
		log.push(...all);
	});
	const exited = new Promise<{ code: number | null; signal: NodeJS.Signals | null }>((resolve) => engine.once("exit", (code, signal) => resolve({ code, signal })));
	return { engine, log, exited, logged: (pattern: RegExp) => log.some((line) => pattern.test(line)) };
}

try {
	// A login shell that never answers: it says which process it is, starts a program of its own, and waits for it.
	// Its name must be one the engine knows how to ask.
	const shellFolder = join(scratch, "shell");
	mkdirSync(shellFolder);
	const shell = join(shellFolder, "zsh");
	writeFileSync(shell, `#!/bin/sh\n[ "$1" = "-ilc" ] || exit 0\necho $$ > "${shellPidFile}"\nsleep 300 &\necho $! > "${sleepPidFile}"\nwait\n`);
	chmodSync(shell, 0o755);

	// ---- Stopped while waiting for the login shell

	const first = startEngine({ PI2_LOGIN_SHELL: shell, PI2_LOGIN_SHELL_TIMEOUT_SECONDS: "3600" });
	await until("the engine to ask its stand-in shell", () => pidIn(shellPidFile) !== undefined && pidIn(sleepPidFile) !== undefined);
	const shellPid = pidIn(shellPidFile)!;
	const sleepPid = pidIn(sleepPidFile)!;
	assert.ok(stillRunning(shellPid, shell) && stillRunning(sleepPid, "sleep 300"), "the stand-in is running");
	assert.ok(existsSync(join(home, "engine.running")), "the engine has begun: its marker is there");
	assert.ok(!first.logged(/listening on /), "and it is still starting, waiting for the shell");
	first.engine.kill("SIGTERM");
	first.engine.kill("SIGTERM"); // a second signal while stopping changes nothing
	const { code, signal } = await first.exited;
	assert.deepEqual({ code, signal }, { code: 0, signal: null }, `the engine stops on its own, not killed by the signal:\n${first.log.join("\n")}`);
	assert.ok(!existsSync(join(home, "engine.running")), "it counts as stopped cleanly");
	assert.ok(!first.logged(/listening on /), "it never listened");
	assert.ok(first.logged(/told to stop \(SIGTERM\) while starting/), first.log.join("\n"));
	assert.ok(first.logged(/PATH not taken from the login shell: the engine is stopping/), first.log.join("\n"));
	await until("the stand-in shell and what it started to be stopped", () => !stillRunning(shellPid, shell) && !stillRunning(sleepPid, "sleep 300"), 10_000);
	step("an engine told to stop while waiting for its login shell stops cleanly, and stops the shell");

	// ---- The next start

	const second = startEngine({ PI2_LOGIN_SHELL: "off" });
	await until("the next engine to listen", () => second.logged(/listening on /));
	const socket = connect(socketPathFor(home));
	let buffer = "";
	const recovery = await new Promise<unknown>((resolve, reject) => {
		socket.once("error", reject);
		socket.setEncoding("utf8").on("data", (chunk: string) => {
			buffer += chunk;
			const lines = buffer.split("\n");
			buffer = lines.pop()!;
			for (const line of lines) {
				const message = JSON.parse(line);
				if (message.event === "recovery") resolve(message.recovery);
			}
		});
	});
	socket.destroy();
	assert.equal(recovery, null, "the next start does not report a crash");
	second.engine.kill("SIGTERM");
	assert.deepEqual(await second.exited, { code: 0, signal: null });
	assert.ok(!existsSync(join(home, "engine.running")));
	step("the next start does not take it for a crash");
} finally {
	for (const engine of engines) {
		if (engine.exitCode === null && engine.signalCode === null) {
			const exited = new Promise((resolve) => engine.once("exit", resolve));
			engine.kill("SIGKILL");
			await exited;
		}
	}
	// In a temporary folder with a long path, an engine's socket is reached through a link in /tmp (src/socket.ts).
	const reached = socketPathFor(home);
	if (reached !== join(home, "engine.sock")) rmSync(join(reached, ".."), { force: true });
	// Had a check failed, the stand-in could be left: stop it, if it is still this test's own.
	for (const [file, command] of [
		[shellPidFile, join(scratch, "shell", "zsh")],
		[sleepPidFile, "sleep 300"],
	] as const) {
		const pid = pidIn(file);
		if (pid !== undefined && pid > 1 && stillRunning(pid, command)) process.kill(pid, "SIGKILL");
	}
	rmSync(scratch, { recursive: true, force: true });
}

console.log("earlystop: ok (an engine told to stop while starting stops cleanly)");
