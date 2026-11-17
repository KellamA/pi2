// The environment the engine gives what it starts on an agent's behalf (issue #195): shell commands, background
// commands, a worktree's set-up command, git, and MCP servers run as programs.
//
// That is the engine's own environment, read at the moment something is started (so the login shell's PATH counts once
// it is taken), without the variables that configure pi² itself. The engine is started with PI2_HOME naming its data
// folder, and PI2_KEYCHAIN_SERVICE when it is not the usual one; passed on, a command that starts pi² or an engine
// without setting them itself (a release build of a test copy, `node engine/src/main.ts`) would get this copy's data
// folder and sign-ins. The other PI2_ variables the engine or the app reads are settings for the copy that set them
// (the demo model's speed and price, the login shell to ask, time limits, the addresses usage is asked of, an address
// the look tools may fetch, what a development build's window opens on, where its engine is), and a nested copy should
// not take them unasked either. So every name that starts with PI2_ is left out, and each part of the engine that wants
// one passes it itself.
//
// The exception is PI2_RUN, the marker of a command's run (processes.ts). An engine started by such a command has it in
// its own environment, and what that engine starts must carry it on, or the engine that started the command could not
// find those processes after a crash. A shell, background or set-up command gets a marker of its own in place of it.

import { RUN_VARIABLE } from "./processes.ts";

/** The PI2_ variables passed on to what the engine starts. */
const PASSED_ON = new Set([RUN_VARIABLE]);

/** Whether a variable of the engine's environment is passed on to what it starts for an agent. */
export const passedOn = (name: string): boolean => !name.startsWith("PI2_") || PASSED_ON.has(name);

/** The environment for a program the engine starts for an agent: its own, without pi²'s settings, and with `extra`. */
export function commandEnvironment(extra: Record<string, string> = {}, from: NodeJS.ProcessEnv = process.env): Record<string, string> {
	const env: Record<string, string> = {};
	for (const [name, value] of Object.entries(from)) if (value !== undefined && passedOn(name)) env[name] = value;
	return Object.assign(env, extra);
}
