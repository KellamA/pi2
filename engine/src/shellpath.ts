// The PATH the engine gives the programs it starts: the person's own, as their login shell has it.
//
// The engine is started by the app or by the login item, so it begins with the PATH macOS gives every program:
// /usr/bin:/bin:/usr/sbin:/sbin. What the person installed themselves (Homebrew, a version manager, ~/.local/bin) is
// not on it, and an agent's `npm test` or `gh` would be "command not found". Writing `PATH=… npm test` is no way round
// it: a command that sets a variable always asks (rules.ts). So the engine asks the login shell for its PATH once, as
// it starts, and takes that as its own. Commands, MCP servers and git all inherit it from there.

import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { homedir, userInfo } from "node:os";
import { basename, join } from "node:path";

/** How long a login shell gets to answer. One that reads a slow profile is worth waiting for; one that hangs is not. */
export const ASK_MS = 5_000;
/** Shells that take `-ilc` and hand what they start PATH as one string of folders separated by colons. */
const KNOWN_SHELLS: ReadonlySet<string> = new Set(["zsh", "bash", "fish"]);
/** Only the end of the output matters; a profile may print a great deal before it. */
const KEEP_CHARS = 64 * 1024;

/**
 * The folders of a PATH, in order, each once. Only full paths are kept: an empty entry or `.` means "the folder the
 * command runs in", which would let a file in a project stand in for a program.
 */
export function folders(...paths: (string | undefined)[]): string[] {
	const seen = new Set<string>();
	for (const path of paths) for (const folder of (path ?? "").split(":")) if (folder.startsWith("/")) seen.add(folder);
	return [...seen];
}

/** Where people's own programs usually are, for when the shell cannot be asked. Only the folders that exist. */
export function usualFolders(home = homedir()): string[] {
	return ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", join(home, ".local", "bin")].filter((folder) => existsSync(folder));
}

/** The PATH in what a shell printed: its last line, since a profile may print lines of its own first. */
export function readPath(output: string): string | undefined {
	const last = output.split("\n").map((line) => line.trim()).filter((line) => line !== "").pop();
	if (last === undefined || !last.startsWith("/")) return undefined;
	const found = folders(last);
	return found.length === 0 ? undefined : found.join(":");
}

/** The shell to ask: the person's own, or the one a test names. Undefined when none is to be asked. */
export function loginShell(env: NodeJS.ProcessEnv = process.env): string | undefined {
	if (env.PI2_LOGIN_SHELL !== undefined) return env.PI2_LOGIN_SHELL === "off" || env.PI2_LOGIN_SHELL === "" ? undefined : env.PI2_LOGIN_SHELL;
	if (env.SHELL !== undefined && env.SHELL !== "") return env.SHELL;
	try {
		// Started by launchd, the engine may have no SHELL; the account still says which it is.
		return userInfo().shell ?? undefined;
	} catch {
		return undefined;
	}
}

/**
 * Ask `shell` for its PATH the way a new terminal window would have it: as a login shell (`-l`) and an interactive one
 * (`-i`), because version managers are often set up in the file only interactive shells read. Never rejects: answers
 * with the PATH, or with why there is none.
 */
export function askShell(shell: string, env: NodeJS.ProcessEnv = process.env, timeoutMs = ASK_MS): Promise<{ path: string } | { reason: string }> {
	if (!KNOWN_SHELLS.has(basename(shell))) return Promise.resolve({ reason: `${basename(shell)} is not a shell pi² knows how to ask` });
	return new Promise((resolve) => {
		let output = "";
		let settled = false;
		const settle = (answer: { path: string } | { reason: string }) => {
			if (settled) return;
			settled = true;
			clearTimeout(timer);
			resolve(answer);
		};
		// printenv, not echo: it prints what a program started by the shell is given, the same in every shell. In a
		// group of its own so that whatever the profile started can be stopped with it.
		const child = spawn(shell, ["-ilc", "exec /usr/bin/printenv PATH"], { env, stdio: ["ignore", "pipe", "ignore"], detached: true });
		const timer = setTimeout(() => {
			try {
				process.kill(-child.pid!, "SIGKILL");
			} catch {
				child.kill("SIGKILL");
			}
			settle({ reason: `${basename(shell)} did not answer within ${Math.round(timeoutMs / 1000)} seconds` });
		}, timeoutMs);
		child.stdout!.setEncoding("utf8").on("data", (chunk: string) => {
			output = (output + chunk).slice(-KEEP_CHARS);
		});
		child.once("error", (error) => settle({ reason: `${basename(shell)} could not be started (${error.message})` }));
		child.once("close", (code) => {
			const path = readPath(output);
			settle(path !== undefined ? { path } : { reason: code === 0 ? `${basename(shell)} printed no PATH` : `${basename(shell)} stopped with code ${code ?? "none"}` });
		});
	});
}

/**
 * Make the login shell's PATH this process's own, keeping any folder the engine already had after it. If the shell
 * cannot be asked, the usual places are added instead. Never throws; says in the log what it did, without the folders.
 */
export async function adoptLoginPath(log: (...parts: unknown[]) => void, env: NodeJS.ProcessEnv = process.env): Promise<void> {
	// Tests switch this off, so an engine they start runs with the PATH they gave it and reads nobody's profile.
	if (env.PI2_LOGIN_SHELL === "off") return;
	const shell = loginShell(env);
	const asked = shell === undefined ? { reason: "the account names no shell" } : await askShell(shell, env);
	if ("path" in asked) {
		env.PATH = folders(asked.path, env.PATH).join(":");
		log(`PATH taken from ${basename(shell!)}: ${folders(asked.path).length} folders`);
		return;
	}
	const usual = usualFolders();
	env.PATH = folders(usual.join(":"), env.PATH).join(":");
	log(`PATH not taken from the login shell (${asked.reason}); added ${usual.length === 0 ? "nothing" : usual.join(", ")}`);
}
