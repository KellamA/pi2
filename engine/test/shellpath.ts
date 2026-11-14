// The engine takes its PATH from the person's login shell, so the commands an agent runs find the programs the person
// installed (issue #36). Nothing here reads a real profile: stand-in shells are small scripts in throwaway folders.
// The last part starts a real engine with the bare PATH macOS gives an app and has it run a program that is only on
// the stand-in shell's PATH.

import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { connect, type Socket } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";
import { adoptLoginPath, askShell, folders, loginShell, readPath, usualFolders } from "../src/shellpath.ts";
import { socketPathFor } from "../src/socket.ts";

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
	assert.deepEqual(await askShell(shell, { PATH: BARE }), { path: `${tools}:/usr/bin:/bin` });

	const pidFile = join(scratch, "hung.pid");
	const hung = script(join(scratch, "hung"), "bash", `sleep 30 &\necho $! > "${pidFile}"\nwait`);
	// Long enough for the stand-in to have started its child even while the other tests keep the Mac busy.
	const started = Date.now();
	const late = await askShell(hung, { PATH: BARE }, 2_000);
	assert.ok("reason" in late && /did not answer/.test(late.reason), "a shell that hangs is given up on");
	assert.ok(Date.now() - started < 10_000, "well before the shell would have finished by itself");
	const left = Number(readFileSync(pidFile, "utf8"));
	const gone = () => {
		try {
			process.kill(left, 0);
			return false;
		} catch {
			return true;
		}
	};
	for (let attempt = 0; attempt < 100 && !gone(); attempt++) await sleep(50);
	assert.ok(gone(), "what the hung shell started is stopped with it");

	const failed = await askShell(script(join(scratch, "failing"), "fish", "exit 3"), { PATH: BARE });
	assert.ok("reason" in failed && /code 3/.test(failed.reason));
	const silent = await askShell(script(join(scratch, "silent"), "zsh", "exit 0"), { PATH: BARE });
	assert.ok("reason" in silent && /printed no PATH/.test(silent.reason));
	const missing = await askShell(join(scratch, "nowhere", "zsh"), { PATH: BARE });
	assert.ok("reason" in missing && /could not be started/.test(missing.reason));
	const unknown = await askShell("/bin/tcsh", { PATH: BARE });
	assert.ok("reason" in unknown && /not a shell pi² knows/.test(unknown.reason));
	step("a shell is asked for its PATH; one that hangs, fails or says nothing gives a reason instead");

	// ---- Taking it as the engine's own

	let env: NodeJS.ProcessEnv = { PATH: BARE, PI2_LOGIN_SHELL: shell };
	await adoptLoginPath(quiet, env);
	assert.equal(env.PATH, `${tools}:${BARE}`, "the shell's folders first, then any the engine had that it did not name");

	env = { PATH: BARE, PI2_LOGIN_SHELL: "off", SHELL: shell };
	await adoptLoginPath(quiet, env);
	assert.equal(env.PATH, BARE, "switched off, the PATH is left exactly as it was");

	env = { PATH: BARE, PI2_LOGIN_SHELL: hung.replace("/hung/bash", "/failing/fish") };
	const lines: string[] = [];
	await adoptLoginPath((...parts) => void lines.push(parts.join(" ")), env);
	assert.equal(env.PATH, [...usualFolders(), ...BARE.split(":")].filter((folder, index, all) => all.indexOf(folder) === index).join(":"), "without an answer, the usual places are added in front");
	assert.ok(lines.length === 1 && /not taken from the login shell \(fish stopped with code 3\)/.test(lines[0]!), "and the log says why");
	step("the engine's PATH becomes the shell's, or gains the usual places when the shell gives none");

	// ---- A real engine, started the way the app starts it

	const home = join(scratch, "home");
	const work = join(scratch, "work");
	mkdirSync(home);
	mkdirSync(work);
	const main = join(import.meta.dirname, "..", "src", "main.ts");
	const engine = spawn(process.execPath, [main], {
		env: { ...process.env, PATH: BARE, PI2_LOGIN_SHELL: shell, PI2_HOME: home, PI2_KEYCHAIN_SERVICE: "dev.pi2.credentials.test-shellpath", PI2_DEMO_TOKENS_PER_SECOND: "1000" },
		stdio: ["ignore", "ignore", "inherit"],
	});
	try {
		const socketPath = socketPathFor(home);
		let socket!: Socket;
		for (let attempt = 0; ; attempt++) {
			try {
				if (!existsSync(join(home, "engine.sock"))) throw new Error("no socket yet");
				socket = connect(socketPath);
				await new Promise<void>((resolve, reject) => socket.once("connect", resolve).once("error", reject));
				break;
			} catch (error) {
				if (attempt >= 200) throw error;
				await sleep(50);
			}
		}
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

		const { id } = await call("conversation.create");
		await call("conversation.open", { id });
		await call("conversation.configure", { id, access: "full", cwd: work });
		const found = await bash(id, "pi2-only-here");
		assert.equal(found.isError, false, `the program is found: ${found.text}`);
		assert.equal(found.text?.trim(), "found-by-path");
		const path = await bash(id, "/usr/bin/printenv PATH");
		assert.equal(path.text?.trim(), `${tools}:${BARE}`, "the command's PATH is the shell's, then the engine's own");
		socket.destroy();
		step("a command run by an engine that started with the bare PATH finds a program on the login shell's PATH");
	} finally {
		if (engine.exitCode === null && engine.signalCode === null) {
			const exited = new Promise((resolve) => engine.once("exit", resolve));
			engine.kill("SIGTERM");
			await exited;
		}
		// In a temporary folder with a long path, the socket is reached through a link in /tmp (src/socket.ts).
		const reached = socketPathFor(home);
		if (reached !== join(home, "engine.sock")) rmSync(join(reached, ".."), { force: true });
	}
} finally {
	rmSync(scratch, { recursive: true, force: true });
}

console.log("shellpath: ok (the engine's commands get the login shell's PATH)");
