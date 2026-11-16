// A login shell that is too slow for start-up's wait is still listened to, and its PATH is taken when it answers
// (issue #86). Until then the engine has the usual folders; a shell that never answers is stopped at a far limit, and
// one still going when the engine stops is stopped with it.
//
// Nothing here reads a real profile: the shells are small scripts in a throwaway folder, and the home folder the
// "usual folders" are looked for in is a throwaway one too. A stand-in answers when the test lets it (a file appears),
// not after a sleep, so nothing depends on how busy the Mac is. The last part starts two real engines with the bare
// PATH macOS gives an app, one whose shell answers late and one whose shell never does.

import assert from "node:assert/strict";
import { type ChildProcess, spawn, spawnSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { connect, type Socket } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";
import { pathToFileURL } from "node:url";
import { adoptLoginPath, askShell, folders, GIVE_UP_MS, listenToShell, usualFolders } from "../src/shellpath.ts";
import { socketPathFor } from "../src/socket.ts";

const scratch = realpathSync(mkdtempSync(join(tmpdir(), "pi2-latepath-")));
const BARE = "/usr/bin:/bin:/usr/sbin:/sbin";
/** How long the in-process checks wait before going on without the shell, in place of five seconds. */
const WAIT_MS = 300;
/** The far limit for the check that it stops a shell: long enough for a stand-in to have started on a busy Mac. */
const FAR_MS = 8_000;
function step(name: string): void {
	console.log(`ok  ${name}`);
}

// The usual folders are looked for under the home folder. A throwaway one makes them the same on every Mac, with one
// that is certain to be there. The engines started below get the real one back: they are given no shell to read.
const realHome = process.env.HOME;
process.env.HOME = join(scratch, "person");
const usualOnly = join(scratch, "person", ".local", "bin");
mkdirSync(usualOnly, { recursive: true });

/**
 * An executable stand-in shell at `folder/name`. Run once before it is used, the way no shell would run it, so that
 * whatever the Mac does with a program it has not seen before is done before anything is timed.
 */
function standIn(folder: string, name: string, body: string): string {
	mkdirSync(folder, { recursive: true });
	const path = join(folder, name);
	writeFileSync(path, `#!/bin/sh\n[ "$1" = "-ilc" ] || exit 0\n${body}\n`);
	chmodSync(path, 0o755);
	spawnSync(path, ["first-run"]);
	return path;
}
/** A shell that answers with `path`, but not before the file `gate` is there. */
function gated(folder: string, gate: string, path: string): string {
	return standIn(folder, "zsh", `while [ ! -e "${gate}" ]; do sleep 0.05; done\necho "Welcome back"\nPATH="${path}"\nexport PATH\neval "$2"`);
}
/** A shell that never answers: it starts a program of its own, says in `pidFile` which, and waits for it. */
function hanging(folder: string, pidFile: string): string {
	return standIn(folder, "bash", `sleep 300 &\necho $! > "${pidFile}"\nwait`);
}
const alive = (pid: number): boolean => {
	try {
		process.kill(pid, 0);
		return true;
	} catch {
		return false;
	}
};
async function until(what: string, met: () => boolean, ms = 30_000): Promise<void> {
	for (const deadline = Date.now() + ms; !met(); ) {
		if (Date.now() > deadline) throw new Error(`Timed out waiting for ${what}`);
		await sleep(25);
	}
}
/** The program a hanging shell started, once it has said which. */
async function startedBy(pidFile: string): Promise<number> {
	await until("the stand-in shell to start its program", () => existsSync(pidFile) && readFileSync(pidFile, "utf8").trim() !== "");
	return Number(readFileSync(pidFile, "utf8"));
}
const within = <T>(ms: number, what: string, promise: Promise<T>): Promise<T> => {
	let timer: NodeJS.Timeout;
	return Promise.race([promise, new Promise<never>((_, reject) => (timer = setTimeout(() => reject(new Error(`Timed out waiting for ${what}`)), ms)))]).finally(() => clearTimeout(timer));
};
const pidFiles: string[] = [];
const engines: ChildProcess[] = [];

try {
	const tools = join(scratch, "tools");
	mkdirSync(tools);
	writeFileSync(join(tools, "pi2-only-late"), "#!/bin/sh\necho found-by-late-path\n");
	chmodSync(join(tools, "pi2-only-late"), 0o755);
	assert.ok(usualFolders().includes(usualOnly), "the throwaway home's folder is one of the usual ones");
	const fallback = (began: string) => folders(usualFolders().join(":"), began).join(":");

	// ---- Two real engines, started the way the app starts them

	// Started now, since each waits its five seconds for the shell before it listens; they are looked at further down,
	// after the checks that need no engine.
	const main = join(import.meta.dirname, "..", "src", "main.ts");
	const startEngine = (name: string, shell: string) => {
		const home = join(scratch, name);
		mkdirSync(home);
		const engine = spawn(process.execPath, [main], {
			env: { ...process.env, HOME: realHome, PATH: BARE, PI2_LOGIN_SHELL: shell, PI2_HOME: home, PI2_KEYCHAIN_SERVICE: "dev.pi2.credentials.test-latepath", PI2_DEMO_TOKENS_PER_SECOND: "1000" },
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
		return { home, engine, log, logged: (pattern: RegExp) => log.some((line) => pattern.test(line)) };
	};
	const engineGate = join(scratch, "engine-gate");
	const slow = startEngine("slow", gated(join(scratch, "engine-late"), engineGate, `${tools}:/usr/bin:/bin`));
	const hungPid = join(scratch, "engine-never.pid");
	pidFiles.push(hungPid);
	const hung = startEngine("hung", hanging(join(scratch, "engine-never"), hungPid));

	// ---- An answer after the wait

	let scenario = 0;
	/** Starts with `began`, asks a shell that says `said` only once the wait is over, and reports each stage. */
	const lateAnswer = async (said: string, began: string) => {
		const gate = join(scratch, `gate-${++scenario}`);
		const env: NodeJS.ProcessEnv = { PATH: began, PI2_LOGIN_SHELL: gated(join(scratch, `late-${scenario}`), gate, said) };
		const lines: string[] = [];
		const listening = await adoptLoginPath((...parts) => void lines.push(parts.join(" ")), env, WAIT_MS, 60_000);
		assert.ok(listening !== undefined, "a shell still going when the wait runs out is still listened to");
		const meanwhile = env.PATH;
		const logged = lines.length;
		writeFileSync(gate, "");
		await within(30_000, "the late answer to be taken", listening.done);
		return { meanwhile, logged, final: env.PATH, lines };
	};

	const plain = await lateAnswer(`${tools}:/usr/bin:/bin:.::relative/bin`, BARE);
	assert.equal(plain.meanwhile, fallback(BARE), "until the shell answers, the usual places are in front of what the engine had");
	assert.ok(plain.meanwhile!.startsWith(`${usualOnly}:`) || plain.meanwhile!.includes(`:${usualOnly}:`));
	assert.equal(plain.logged, 1);
	assert.match(plain.lines[0]!, /^PATH not taken from the login shell \(zsh did not answer within \d+ seconds?\); added .* for now, and still listening for its answer$/);
	assert.equal(plain.final, `${tools}:${BARE}`, "then the shell's folders, and after them the ones the engine began with: what an answer in time gives");
	assert.equal(plain.lines.length, 2);
	assert.match(plain.lines[1]!, /^PATH taken from zsh, \d+ seconds? after it was asked: 3 folders\. /);
	assert.ok(!plain.lines[1]!.includes(tools), "the log does not list the shell's folders");

	const named = await lateAnswer(`${tools}:/usr/bin:${usualOnly}:/bin`, BARE);
	assert.equal(named.final, `${tools}:/usr/bin:${usualOnly}:/bin:/usr/sbin:/sbin`, "a usual place the shell names is where the shell has it, once");

	const had = await lateAnswer(`${tools}:/usr/bin:/bin`, `${BARE}:${usualOnly}`);
	assert.equal(had.meanwhile, fallback(`${BARE}:${usualOnly}`));
	assert.equal(had.final, `${tools}:${BARE}:${usualOnly}`, "a usual place the engine began with stays, after the shell's folders");
	step("a shell that answers after the wait has its PATH taken then, the same as an answer in time");

	// ---- An answer that is in, but not yet read, when the wait runs out

	// The shell answers at once and says when it is about to; this process is then kept from looking, as an engine
	// busy starting is, until the wait is well over and the shell has finished (ps shows it as a zombie).
	const quickPid = join(scratch, "quick.pid");
	const quick = standIn(join(scratch, "quick"), "zsh", `echo $$ > "${quickPid}"\nPATH="${tools}:/usr/bin:/bin"\nexport PATH\neval "$2"`);
	const pause = new Int32Array(new SharedArrayBuffer(4)); // Atomics.wait on it sleeps without letting the loop turn
	const unread = listenToShell(quick, { PATH: BARE }, WAIT_MS, 60_000);
	const asked = Date.now();
	for (const giveUp = asked + 30_000; ; Atomics.wait(pause, 0, 0, 10)) {
		const finished = existsSync(quickPid) && readFileSync(quickPid, "utf8").trim() !== "" && /Z/.test(spawnSync("/bin/ps", ["-o", "stat=", "-p", readFileSync(quickPid, "utf8").trim()], { encoding: "utf8" }).stdout);
		if ((finished && Date.now() - asked > WAIT_MS + 200) || Date.now() > giveUp) break;
	}
	assert.deepEqual(await unread.soon, { path: `${tools}:/usr/bin:/bin` }, "an answer that came in time counts as in time, though the wait ran out before it was read");
	assert.deepEqual(await unread.late, { path: `${tools}:/usr/bin:/bin` });
	step("a busy engine does not take a shell that answered in time for a slow one");

	// ---- A shell that never answers

	const neverPid = join(scratch, "never.pid");
	pidFiles.push(neverPid);
	let env: NodeJS.ProcessEnv = { PATH: BARE, PI2_LOGIN_SHELL: hanging(join(scratch, "never"), neverPid) };
	let lines: string[] = [];
	let started = Date.now();
	let listening = await adoptLoginPath((...parts) => void lines.push(parts.join(" ")), env, WAIT_MS, FAR_MS);
	assert.ok(listening !== undefined);
	let settled = false;
	void listening.done.then(() => (settled = true));
	const left = await startedBy(neverPid);
	assert.ok(alive(left) && !settled && lines.length === 1, "start-up goes on after the wait, and the shell is left running");
	await within(30_000, "the far limit", listening.done);
	assert.ok(Date.now() - started >= FAR_MS - 50, "until the far limit");
	await until("what the shell started to be stopped", () => !alive(left), 5_000);
	assert.equal(env.PATH, fallback(BARE), "the PATH stays as it was");
	assert.equal(lines.length, 2);
	assert.match(lines[1]!, /^PATH still not taken from the login shell \(bash had not answered 8 seconds after it was asked, and was stopped\); it stays as it is until the engine starts again$/);
	assert.equal(GIVE_UP_MS, 5 * 60_000, "the engine's own far limit is five minutes");
	step("a shell that never answers is stopped at the far limit, with what it started");

	// ---- A shell that fails late, and one that cannot be started at all

	const failGate = join(scratch, "fail-gate");
	env = { PATH: BARE, PI2_LOGIN_SHELL: standIn(join(scratch, "fails-late"), "fish", `while [ ! -e "${failGate}" ]; do sleep 0.05; done\nexit 3`) };
	lines = [];
	listening = await adoptLoginPath((...parts) => void lines.push(parts.join(" ")), env, WAIT_MS, 60_000);
	assert.ok(listening !== undefined);
	writeFileSync(failGate, "");
	await within(30_000, "the late failure", listening.done);
	assert.equal(env.PATH, fallback(BARE));
	assert.match(lines[1]!, /^PATH still not taken from the login shell \(fish stopped with code 3\)/);

	// A path no program can have. Starting it throws rather than failing later, and that is a reason like any other.
	const impossible = join(scratch, "no\0where", "zsh");
	const refused = await askShell(impossible, { PATH: BARE });
	assert.ok("reason" in refused && /could not be started/.test(refused.reason));
	env = { PATH: BARE, PI2_LOGIN_SHELL: impossible };
	assert.equal(await adoptLoginPath(() => {}, env, WAIT_MS, 60_000), undefined, "nothing is listened to");
	assert.equal(env.PATH, fallback(BARE));
	step("a shell that fails after the wait, or cannot be started, leaves the usual places and a reason");

	// ---- A shell that ends but leaves something holding its output open

	// Its answer is taken a moment after it ends, not waited for until a limit. And nothing is stopped then: the
	// shell's process number is no longer its own, and what a profile leaves running is left running in a terminal too.
	const keptPid = join(scratch, "kept.pid");
	pidFiles.push(keptPid);
	const leaves = standIn(join(scratch, "leaves"), "zsh", `sleep 300 &\necho $! > "${keptPid}"\nPATH="${tools}:/usr/bin:/bin"\nexport PATH\neval "$2"`);
	started = Date.now();
	assert.deepEqual(await askShell(leaves, { PATH: BARE }, 60_000), { path: `${tools}:/usr/bin:/bin` });
	assert.ok(Date.now() - started < 30_000, "well before the limit");
	const kept = await startedBy(keptPid);
	await sleep(200);
	assert.ok(alive(kept), "what the shell left running is not stopped");
	process.kill(kept, "SIGKILL"); // this test's own `sleep`, checked alive just now
	step("a shell that has ended is answered for at once and never signalled, whatever still holds its output");

	// ---- Stopping while the shell is still going

	const stopPid = join(scratch, "stop.pid");
	pidFiles.push(stopPid);
	env = { PATH: BARE, PI2_LOGIN_SHELL: hanging(join(scratch, "stopped"), stopPid) };
	lines = [];
	listening = await adoptLoginPath((...parts) => void lines.push(parts.join(" ")), env, WAIT_MS, 10 * 60_000);
	assert.ok(listening !== undefined);
	const toStop = await startedBy(stopPid);
	assert.ok(alive(toStop));
	started = Date.now();
	listening.stop();
	await within(5_000, "the stop to be done", listening.done);
	await until("what the shell started to be stopped", () => !alive(toStop), 5_000);
	assert.ok(Date.now() - started < 10_000);
	assert.equal(env.PATH, fallback(BARE));
	assert.equal(lines.length, 1, "nothing more is logged for a shell the engine stopped itself");

	// A process with nothing else to do ends by itself while the shell is still going, ten minutes before the far
	// limit, and stops the shell as it goes: neither the shell nor the limit holds it.
	const endPid = join(scratch, "end.pid");
	pidFiles.push(endPid);
	const ending = join(scratch, "ending.mjs");
	writeFileSync(
		ending,
		[
			`import { existsSync } from "node:fs";`,
			`import { setTimeout as sleep } from "node:timers/promises";`,
			`import { adoptLoginPath } from ${JSON.stringify(pathToFileURL(join(import.meta.dirname, "..", "src", "shellpath.ts")).href)};`,
			`const [shell, pidFile] = process.argv.slice(2);`,
			`const listening = await adoptLoginPath(() => {}, { PATH: ${JSON.stringify(BARE)}, PI2_LOGIN_SHELL: shell }, ${WAIT_MS}, 10 * 60_000);`,
			`while (!existsSync(pidFile)) await sleep(20);`,
			`console.log(listening === undefined ? "nothing pending" : "still listening");`,
		].join("\n"),
	);
	const ended = spawn(process.execPath, [ending, hanging(join(scratch, "ended"), endPid), endPid], { stdio: ["ignore", "pipe", "inherit"] });
	let said = "";
	ended.stdout!.setEncoding("utf8").on("data", (chunk: string) => (said += chunk));
	const code = await within(30_000, "a process with a shell still going to end by itself", new Promise<number | null>((resolve) => ended.once("close", resolve))).catch((error) => {
		ended.kill("SIGKILL");
		throw error;
	});
	assert.equal(code, 0);
	assert.equal(said.trim(), "still listening");
	const orphan = await startedBy(endPid);
	await until("what the shell started to be stopped", () => !alive(orphan), 5_000);
	step("a shell still going is stopped when the engine stops, and does not keep the process running");

	// ---- The two engines started above

	// The engine whose shell answers late: commands before the answer have the usual folders, commands after it the
	// shell's PATH.
	await until("the engine to listen", () => slow.logged(/listening on /), 120_000);
	assert.ok(slow.logged(/PATH not taken from the login shell \(zsh did not answer within 5 seconds\); added .* still listening/), slow.log.join("\n"));
	const socket: Socket = connect(socketPathFor(slow.home));
	await new Promise<void>((resolve, reject) => socket.once("connect", resolve).once("error", reject));
	type Item = { kind: string; text?: string; isError?: boolean };
	const items: Item[] = [];
	let busy = false;
	let next = 1;
	const replies = new Map<number, { resolve: (value: any) => void; reject: (error: Error) => void }>();
	let buffer = "";
	socket.setEncoding("utf8").on("data", (chunk: string) => {
		buffer += chunk;
		const received = buffer.split("\n");
		buffer = received.pop()!;
		for (const line of received) {
			const message = JSON.parse(line);
			if (message.event === "conversation") {
				if (message.reset) items.length = 0;
				items.push(...message.items);
				busy = message.state.busy;
			} else if (typeof message.id === "number") {
				const reply = replies.get(message.id);
				replies.delete(message.id);
				if (message.error !== undefined) reply?.reject(new Error(message.error));
				else reply?.resolve(message.result);
			}
		}
	});
	const call = (method: string, params: Record<string, unknown> = {}): Promise<any> => {
		const id = next++;
		socket.write(`${JSON.stringify({ id, method, params })}\n`);
		return new Promise((resolve, reject) => replies.set(id, { resolve, reject }));
	};
	/** Runs a shell command through the demo model and returns its result. */
	const bash = async (id: number, command: string): Promise<Item> => {
		const before = items.filter((item) => item.kind === "tool").length;
		await call("submit", { id, text: `/bash ${command}` });
		for (const deadline = Date.now() + 30_000; ; ) {
			const results = items.filter((item) => item.kind === "tool");
			if (!busy && results.length > before && items.at(-1)?.kind === "assistant") return results.at(-1)!;
			if (Date.now() > deadline) throw new Error(`Timed out waiting for: ${command}`);
			await sleep(50);
		}
	};
	const work = join(scratch, "work");
	mkdirSync(work);
	const { id } = await call("conversation.create");
	await call("conversation.open", { id });
	await call("conversation.configure", { id, access: "full", cwd: work });
	const early = await bash(id, "pi2-only-late");
	assert.match(early.text ?? "", /not found/, "before the shell answers, a program only on its PATH is not found");
	const earlyPath = (await bash(id, "/usr/bin/printenv PATH")).text?.trim() ?? "";
	assert.ok(!earlyPath.split(":").includes(tools) && earlyPath.endsWith(BARE), `a command then has the engine's PATH and the usual places: ${earlyPath}`);
	writeFileSync(engineGate, "");
	await until("the engine to take the late PATH", () => slow.logged(/PATH taken from zsh, \d+ seconds? after it was asked: 3 folders/));
	assert.ok(!slow.log.some((line) => line.includes(tools)), "the engine's log does not list the shell's folders");
	const found = await bash(id, "pi2-only-late");
	assert.equal(found.isError, false, `after it, the program is found: ${found.text}`);
	assert.equal(found.text?.trim(), "found-by-late-path");
	assert.equal((await bash(id, "/usr/bin/printenv PATH")).text?.trim(), `${tools}:${BARE}`, "and a command's PATH is the shell's, then the engine's own");
	socket.destroy();
	step("an engine whose shell answers late runs later commands with the shell's PATH");

	// The engine whose shell never answers: it is listening all the same, and stops cleanly, taking the shell and
	// what the shell started with it.
	await until("the other engine to listen", () => hung.logged(/listening on /), 120_000);
	assert.ok(hung.logged(/PATH not taken from the login shell \(bash did not answer within 5 seconds\)/), hung.log.join("\n"));
	const held = await startedBy(hungPid);
	assert.ok(alive(held), "the shell is still going while the engine runs");
	const exited = new Promise<number | null>((resolve) => hung.engine.once("exit", resolve));
	hung.engine.kill("SIGTERM");
	assert.equal(await within(60_000, "the engine to stop", exited), 0, "the engine stops cleanly with the shell still going");
	await until("what the shell started to be stopped", () => !alive(held), 5_000);
	assert.ok(!existsSync(join(hung.home, "engine.running")), "and counts as stopped cleanly");
	step("an engine whose shell never answers stops cleanly and takes the shell with it");
} finally {
	for (const engine of engines) {
		if (engine.exitCode === null && engine.signalCode === null) {
			const exited = new Promise((resolve) => engine.once("exit", resolve));
			engine.kill("SIGTERM");
			await exited;
		}
	}
	// In a temporary folder with a long path, an engine's socket is reached through a link in /tmp (src/socket.ts).
	for (const name of ["slow", "hung"]) {
		const reached = socketPathFor(join(scratch, name));
		if (reached !== join(scratch, name, "engine.sock")) rmSync(join(reached, ".."), { force: true });
	}
	// Had a check failed part-way, a stand-in's `sleep` could be left: stop any that is still this test's own.
	for (const pidFile of pidFiles) {
		const pid = existsSync(pidFile) ? Number(readFileSync(pidFile, "utf8")) : Number.NaN;
		if (Number.isInteger(pid) && pid > 1 && spawnSync("/bin/ps", ["-o", "command=", "-p", String(pid)], { encoding: "utf8" }).stdout.trim() === "sleep 300") process.kill(pid, "SIGKILL");
	}
	rmSync(scratch, { recursive: true, force: true });
}

console.log("latepath: ok (a slow login shell's PATH is taken when it comes)");
