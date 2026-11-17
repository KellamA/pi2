// The engine takes its PATH from the person's login shell, so the commands an agent runs find the programs the person
// installed (issue #36). Nothing here reads a real profile: stand-in shells are small scripts in throwaway folders.
// The last part starts a real engine with the bare PATH macOS gives an app and has it run a program that is only on
// the stand-in shell's PATH.
//
// Only the check that a hung shell is given up on depends on a time limit, and it keeps a short one. Everywhere else
// the limit is not what is being checked, so the shells, and the engine started at the end, are given a long one: on a
// busy Mac a script can take more than the usual 5 seconds just to start (issue #84).

import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";
import { adoptLoginPath, askShell, folders, loginShell, readPath, usualFolders } from "../src/shellpath.ts";
import { socketPathFor } from "../src/socket.ts";
import { EngineClient, PATIENT_MS, stop } from "./patience.ts";

const scratch = realpathSync(mkdtempSync(join(tmpdir(), "pi2-shellpath-")));
const BARE = "/usr/bin:/bin:/usr/sbin:/sbin";
function step(name: string): void {
	console.log(`ok  ${name}`);
}
/** An executable script at `folder/name`. */
function script(folder: string, name: string, body: string): string {
	mkdirSync(folder, { recursive: true });
	const path = join(folder, name);
	writeFileSync(path, `#!/bin/sh\n${body}\n`);
	chmodSync(path, 0o755);
	return path;
}
const quiet = () => {};
/**
 * The limit wherever the limit is not what is checked, and how long the test waits for something that will happen
 * unless what it tests is broken: only a hang reaches it (patience.ts).
 */
const PATIENT_SECONDS = PATIENT_MS / 1000;
/** Whether a process is gone (a process that has ended but not been collected by its parent still counts as there). */
function gone(pid: number): boolean {
	try {
		process.kill(pid, 0);
		return false;
	} catch {
		return true;
	}
}

try {
	// ---- Reading a PATH

	assert.deepEqual(folders("/a:/b:/a", "/c:/b"), ["/a", "/b", "/c"], "each folder once, in order");
	assert.deepEqual(folders(":/a:.:bin:../x:/b:", undefined), ["/a", "/b"], "the current folder and other relative entries are left out");
	assert.equal(readPath("Welcome back\n\n/opt/tools/bin:/usr/bin\n"), "/opt/tools/bin:/usr/bin", "the last line, after whatever a profile printed");
	assert.equal(readPath(""), undefined);
	assert.equal(readPath("/usr/bin\nzsh: command not found: printenv\n"), undefined, "a last line that is not a PATH is no answer");
	assert.equal(loginShell({ SHELL: "/bin/zsh" }), "/bin/zsh");
	assert.equal(loginShell({ SHELL: "/bin/zsh", PI2_LOGIN_SHELL: "/tmp/other/bash" }), "/tmp/other/bash");
	assert.equal(loginShell({ SHELL: "/bin/zsh", PI2_LOGIN_SHELL: "off" }), undefined);
	step("a PATH is read from a shell's output, and only full paths are kept");

	// ---- Asking a shell

	const tools = join(scratch, "tools");
	script(tools, "pi2-only-here", "echo found-by-path");
	// Prints a line of its own first, as a profile might, and has entries no command should be looked up in.
	const shell = script(join(scratch, "good"), "zsh", `echo "Welcome back"\n[ "$1" = "-ilc" ] || exit 9\nPATH="${tools}:/usr/bin:/bin:.::relative/bin"\nexport PATH\neval "$2"`);
	const patient = PATIENT_SECONDS * 1000;
	assert.deepEqual(await askShell(shell, { PATH: BARE }, patient), { path: `${tools}:/usr/bin:/bin` });

	// Starts a child that would run as long as the test's patience, writes down its number (all at once, by renaming
	// the file), and waits for it. Its limit is what is checked here, so it is short. On a busy Mac the stand-in may be
	// given up on before it has even started its child, which leaves nothing to check the stopping of; then it is asked
	// again with twice the time, until it has.
	const pidFile = join(scratch, "hung.pid");
	const hung = script(join(scratch, "hung"), "bash", `sleep ${PATIENT_SECONDS} &\necho $! > "${pidFile}.new"\nmv "${pidFile}.new" "${pidFile}"\nwait`);
	let left: number | undefined;
	for (let limit = 2_000; left === undefined; limit *= 2) {
		assert.ok(limit <= 128_000, "the hung stand-in started its child before it was given up on, given two minutes");
		rmSync(pidFile, { force: true });
		const started = Date.now();
		const late = await askShell(hung, { PATH: BARE }, limit);
		assert.ok("reason" in late && /did not answer/.test(late.reason), "a shell that hangs is given up on");
		assert.ok(Date.now() - started < limit + 120_000, "without waiting for the child, which would run for ten minutes");
		if (existsSync(pidFile)) left = Number(readFileSync(pidFile, "utf8"));
	}
	assert.ok(Number.isInteger(left) && left > 1, "the stand-in wrote down its child's number");
	// Once killed, the child is collected by launchd, since its parent went with it; that takes a moment.
	for (const deadline = Date.now() + 120_000; !gone(left) && Date.now() < deadline; ) await sleep(50);
	assert.ok(gone(left), "what the hung shell started is stopped with it");

	const failed = await askShell(script(join(scratch, "failing"), "fish", "exit 3"), { PATH: BARE }, patient);
	assert.ok("reason" in failed && /code 3/.test(failed.reason));
	const silent = await askShell(script(join(scratch, "silent"), "zsh", "exit 0"), { PATH: BARE }, patient);
	assert.ok("reason" in silent && /printed no PATH/.test(silent.reason));
	const missing = await askShell(join(scratch, "nowhere", "zsh"), { PATH: BARE }, patient);
	assert.ok("reason" in missing && /could not be started/.test(missing.reason));
	const unknown = await askShell("/bin/tcsh", { PATH: BARE });
	assert.ok("reason" in unknown && /not a shell pi² knows/.test(unknown.reason));
	step("a shell is asked for its PATH; one that hangs, fails or says nothing gives a reason instead");

	// ---- Taking it as the engine's own

	const patientSeconds = String(PATIENT_SECONDS);
	let env: NodeJS.ProcessEnv = { PATH: BARE, PI2_LOGIN_SHELL: shell, PI2_LOGIN_SHELL_TIMEOUT_SECONDS: patientSeconds };
	await adoptLoginPath(quiet, env);
	assert.equal(env.PATH, `${tools}:${BARE}`, "the shell's folders first, then any the engine had that it did not name");

	env = { PATH: BARE, PI2_LOGIN_SHELL: "off", SHELL: shell };
	await adoptLoginPath(quiet, env);
	assert.equal(env.PATH, BARE, "switched off, the PATH is left exactly as it was");

	const usualThenBare = [...usualFolders(), ...BARE.split(":")].filter((folder, index, all) => all.indexOf(folder) === index).join(":");
	env = { PATH: BARE, PI2_LOGIN_SHELL: join(scratch, "failing", "fish"), PI2_LOGIN_SHELL_TIMEOUT_SECONDS: patientSeconds };
	const lines: string[] = [];
	await adoptLoginPath((...parts) => void lines.push(parts.join(" ")), env);
	assert.equal(env.PATH, usualThenBare, "without an answer, the usual places are added in front");
	assert.ok(lines.length === 1 && /not taken from the login shell \(fish stopped with code 3\)/.test(lines[0]!), "and the log says why");

	// How long start-up waits for the shell can be set, as the engine started below needs. A hung shell misses the wait
	// whenever it is asked, so this does not depend on how busy the Mac is. It is then still listened to (latepath.ts
	// checks what comes of that), so it is stopped here.
	env = { PATH: BARE, PI2_LOGIN_SHELL: hung, PI2_LOGIN_SHELL_TIMEOUT_SECONDS: "1" };
	lines.length = 0;
	const listening = await adoptLoginPath((...parts) => void lines.push(parts.join(" ")), env);
	listening?.stop();
	await listening?.done;
	assert.equal(env.PATH, usualThenBare);
	assert.ok(lines.length === 1 && /\(bash did not answer within 1 second/.test(lines[0]!), `the wait is the one given: ${lines[0]}`);
	step("the engine's PATH becomes the shell's, or gains the usual places when the shell gives none");

	// ---- A real engine, started the way the app starts it

	const home = join(scratch, "home");
	const work = join(scratch, "work");
	mkdirSync(home);
	mkdirSync(work);
	const main = join(import.meta.dirname, "..", "src", "main.ts");
	const engine = spawn(process.execPath, [main], {
		env: {
			...process.env,
			PATH: BARE,
			PI2_LOGIN_SHELL: shell,
			PI2_LOGIN_SHELL_TIMEOUT_SECONDS: patientSeconds,
			PI2_HOME: home,
			PI2_KEYCHAIN_SERVICE: "dev.pi2.credentials.test-shellpath",
			PI2_DEMO_TOKENS_PER_SECOND: "1000",
		},
		stdio: ["ignore", "ignore", "inherit"],
	});
	try {
		// The engine listens once it has the shell's answer, which on a busy Mac can take a while.
		const client = await EngineClient.connect(engine, home);
		type Item = { kind: string; text?: string; isError?: boolean };
		/** Runs a shell command through the demo model and returns its result. */
		const bash = async (id: number, command: string): Promise<Item> => {
			const results = (): Item[] => client.conversations.get(id)?.items.filter((item: Item) => item.kind === "tool") ?? [];
			const before = results().length;
			await client.call("submit", { id, text: `/bash ${command}` });
			return await client.until(`the result of ${command}`, () => {
				const conv = client.conversations.get(id);
				return conv !== undefined && !conv.state.busy && results().length > before && conv.items.at(-1)?.kind === "assistant" ? results().at(-1) : undefined;
			});
		};

		const { id } = await client.call("conversation.create");
		await client.call("conversation.open", { id });
		await client.call("conversation.configure", { id, access: "full", cwd: work });
		const found = await bash(id, "pi2-only-here");
		assert.equal(found.isError, false, `the program is found: ${found.text}`);
		assert.equal(found.text?.trim(), "found-by-path");
		const path = await bash(id, "/usr/bin/printenv PATH");
		assert.equal(path.text?.trim(), `${tools}:${BARE}`, "the command's PATH is the shell's, then the engine's own");
		client.close();
		step("a command run by an engine that started with the bare PATH finds a program on the login shell's PATH");
	} finally {
		await stop(engine);
		// In a temporary folder with a long path, the socket is reached through a link in /tmp (src/socket.ts).
		const reached = socketPathFor(home);
		if (reached !== join(home, "engine.sock")) rmSync(join(reached, ".."), { force: true });
	}
} finally {
	rmSync(scratch, { recursive: true, force: true });
}

console.log("shellpath: ok (the engine's commands get the login shell's PATH)");
