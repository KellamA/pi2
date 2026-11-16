// The PATH the engine gives the programs it starts: the person's own, as their login shell has it.
//
// The engine is started by the app or by the login item, so it begins with the PATH macOS gives every program:
// /usr/bin:/bin:/usr/sbin:/sbin. What the person installed themselves (Homebrew, a version manager, ~/.local/bin) is
// not on it, and an agent's `npm test` or `gh` would be "command not found". Writing `PATH=… npm test` is no way round
// it: a command that sets a variable always asks (rules.ts). So the engine asks the login shell for its PATH once, as
// it starts, and takes that as its own. Commands, MCP servers and git all inherit it from there.
//
// Start-up waits a few seconds for the answer and no longer. The login item starts the engine right after login, when
// the Mac is at its busiest and a shell with a version manager in its profile can take a good while, so a shell that
// misses the wait is not stopped (issue #86): the engine goes on with the usual folders and keeps listening, and takes
// the shell's PATH when it comes. What is started before then has the usual folders; what is started after has the
// person's own PATH.

import { type ChildProcess, spawn } from "node:child_process";
import { existsSync } from "node:fs";
import type { Socket } from "node:net";
import { homedir, userInfo } from "node:os";
import { basename, join } from "node:path";

/**
 * How long start-up waits for the login shell's answer. One that reads a slow profile is worth waiting for, but the
 * app is waiting for the engine meanwhile.
 */
export const ASK_MS = 5_000;
/**
 * How long after it was asked a shell that missed that wait is still listened to. Then it is stopped, with whatever
 * its profile started. Five minutes: on a loaded Mac the engine itself has been seen to take 11 to 18 seconds to
 * start (issue #86), and a shell slowed by the same load answers within a minute or two, so this leaves room well
 * beyond that. One still going then is not slow but waiting for something that will not come (an answer to a
 * question, a program that does not return). Listening that long costs only the idle shell; much longer, and its
 * PATH would turn up under work that had run without it for so long that the change would be more surprise than help.
 */
export const GIVE_UP_MS = 5 * 60_000;
/** How long after a shell has ended its output is still read, in case something it started holds that open. */
const LAST_WORDS_MS = 1_000;
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

/** What a shell said: its PATH, or why there is none. */
export type Answer = { path: string } | { reason: string };

/** A shell that has been asked for its PATH. */
export interface Asked {
	/**
	 * Its answer, if that comes within the wait. Otherwise why there is none; `listening` is then set if the shell is
	 * still going, in which case `late` may yet have its PATH. Never rejects.
	 */
	readonly soon: Promise<Answer & { listening?: true }>;
	/** Its answer in the end, however long it took, or why it never gave one. Never rejects. */
	readonly late: Promise<Answer>;
	/** Stops the shell and whatever it started, if it is still going; `late` then answers with `reason`. */
	stop(reason: string): void;
}

/** "5 seconds", "5 minutes", "1 minute". */
function span(ms: number): string {
	const [count, unit] = ms >= 60_000 && ms % 60_000 === 0 ? [ms / 60_000, "minute"] : [Math.round(ms / 1000), "second"];
	return `${count} ${unit}${count === 1 ? "" : "s"}`;
}

/**
 * Ask `shell` for its PATH the way a new terminal window would have it: as a login shell (`-l`) and an interactive one
 * (`-i`), because version managers are often set up in the file only interactive shells read. Never throws.
 *
 * `soon` answers within `waitMs`. A shell still going then is left to finish, and `late` has its answer when it comes.
 * It is stopped `giveUpMs` after it was asked, or when this process exits, whichever comes first; once the wait is
 * over, neither the shell nor that limit keeps this process running. With `giveUpMs` no longer than `waitMs`, the
 * shell is stopped as soon as the wait runs out.
 */
export function listenToShell(shell: string, env: NodeJS.ProcessEnv = process.env, waitMs = ASK_MS, giveUpMs = GIVE_UP_MS): Asked {
	const name = basename(shell);
	const refused = (reason: string): Asked => {
		const answer = Promise.resolve({ reason });
		return { soon: answer, late: answer, stop: () => {} };
	};
	if (!KNOWN_SHELLS.has(name)) return refused(`${name} is not a shell pi² knows how to ask`);
	let child: ChildProcess;
	try {
		// printenv, not echo: it prints what a program started by the shell is given, the same in every shell. In a
		// group of its own so that whatever the profile started can be stopped with it.
		child = spawn(shell, ["-ilc", "exec /usr/bin/printenv PATH"], { env, stdio: ["ignore", "pipe", "ignore"], detached: true });
	} catch (error) {
		// A path or a variable that no program can be given. One that is only missing is reported below instead.
		return refused(`${name} could not be started (${error instanceof Error ? error.message : String(error)})`);
	}
	let answerSoon!: (answer: Answer & { listening?: true }) => void;
	let answerLate!: (answer: Answer) => void;
	const soon = new Promise<Answer & { listening?: true }>((resolve) => (answerSoon = resolve));
	const late = new Promise<Answer>((resolve) => (answerLate = resolve));
	let output = "";
	let over = false;
	let ended = false;
	let waited = false;
	let lastWords: NodeJS.Timeout | undefined;
	const kill = () => {
		// A shell that has ended is never signalled: once it is gone and its group is empty, its number is free for
		// another program to be given, and this may be minutes later.
		if (ended) return;
		try {
			process.kill(-child.pid!, "SIGKILL");
		} catch {
			child.kill("SIGKILL");
		}
	};
	/** The shell has answered, failed or been stopped: nothing more will come from it. */
	const finish = (answer: Answer) => {
		if (over) return;
		over = true;
		clearTimeout(waitTimer);
		clearTimeout(giveUpTimer);
		clearTimeout(lastWords);
		process.removeListener("exit", kill);
		answerSoon(answer); // does nothing if the wait had already run out
		answerLate(answer);
	};
	const giveUp = (reason: string) => {
		if (over) return;
		kill();
		finish({ reason });
	};
	const conclude = (code: number | null) => {
		const path = readPath(output);
		finish(path !== undefined ? { path } : { reason: code === 0 ? `${name} printed no PATH` : `${name} stopped with code ${code ?? "none"}` });
	};
	// A limit is not acted on the moment its timer comes up. Node handles a timer that is due before it looks at what
	// the programs it started have done, so if this process was busy as the limit passed (the engine is, while it
	// starts), a shell that had answered well within it would be taken for one that had not. So the event loop gets
	// one turn first, in which a shell that has ended is seen to have; that shell's answer is then on its way, and
	// only one still running has run out of time.
	const atLimit = (act: () => void) => () => {
		setImmediate(() => {
			if (!over && !ended) act();
		});
	};
	const waitTimer = setTimeout(
		atLimit(() => {
			const reason = `${name} did not answer within ${span(waitMs)}`;
			if (giveUpMs <= waitMs) return giveUp(reason);
			answerSoon({ reason, listening: true });
			// From here on the shell is only listened to: it must not hold up this process's own end.
			waited = true;
			child.unref();
			(child.stdout as Socket).unref();
			giveUpTimer?.unref();
		}),
		waitMs,
	);
	const giveUpTimer = giveUpMs > waitMs ? setTimeout(atLimit(() => giveUp(`${name} had not answered ${span(giveUpMs)} after it was asked, and was stopped`)), giveUpMs) : undefined;
	// However this process ends, a shell still going is not left behind. (Nothing can be done when it is killed
	// outright; the shell then runs on until it finishes by itself.)
	process.once("exit", kill);
	child.stdout!.setEncoding("utf8").on("data", (chunk: string) => {
		output = (output + chunk).slice(-KEEP_CHARS);
	});
	child.once("error", (error) => finish({ reason: `${name} could not be started (${error.message})` }));
	child.once("exit", (code) => {
		ended = true;
		if (over) return;
		// What it printed is read within a few turns of the event loop, and "close" below then has it all. Unless
		// something its profile started still holds its output open: that would be waited for until a limit, and
		// then stopped under a number that is no longer the shell's. So after a moment (and a turn of the event loop,
		// as for the limits) what is there is the answer, and what the shell left running is left running, as it
		// would be in a terminal.
		lastWords = setTimeout(() => {
			setImmediate(() => {
				if (over) return;
				child.stdout!.destroy();
				conclude(code);
			});
		}, LAST_WORDS_MS);
		if (waited) lastWords.unref();
	});
	child.once("close", conclude);
	return { soon, late, stop: giveUp };
}

/**
 * Ask `shell` for its PATH and wait up to `timeoutMs` for it; a shell that has not answered by then is stopped, with
 * whatever it started. Never rejects: answers with the PATH, or with why there is none.
 */
export function askShell(shell: string, env: NodeJS.ProcessEnv = process.env, timeoutMs = ASK_MS): Promise<Answer> {
	return listenToShell(shell, env, timeoutMs, 0).late;
}

/** A login shell that missed start-up's wait and is still listened to. */
export interface StillListening {
	/** Settles once the shell has answered and its PATH is taken, or it has failed or been stopped. Never rejects. */
	readonly done: Promise<void>;
	/** Stops the shell and whatever it started, and leaves the PATH as it is. For when the engine is stopping. */
	stop(): void;
}

/**
 * Make the login shell's PATH this process's own, keeping any folder the engine already had after it. If the shell
 * cannot be asked, the usual places are added instead.
 *
 * If the shell has only not answered within `waitMs`, the usual places are added for now and it is still listened to,
 * for up to `giveUpMs` from when it was asked: when it answers, the PATH becomes what an answer in time would have
 * made it, so whatever is started from then on gets it. The result is then the shell still being listened to.
 *
 * Never throws; says in the log what it did, without the shell's folders.
 */
export async function adoptLoginPath(log: (...parts: unknown[]) => void, env: NodeJS.ProcessEnv = process.env, waitMs = ASK_MS, giveUpMs = GIVE_UP_MS): Promise<StillListening | undefined> {
	// Tests switch this off, so an engine they start runs with the PATH they gave it and reads nobody's profile.
	if (env.PI2_LOGIN_SHELL === "off") return undefined;
	const shell = loginShell(env);
	const askedAt = Date.now();
	const asked = shell === undefined ? undefined : listenToShell(shell, env, waitMs, giveUpMs);
	const soon: Answer & { listening?: true } = asked === undefined ? { reason: "the account names no shell" } : await asked.soon;
	if ("path" in soon) {
		env.PATH = folders(soon.path, env.PATH).join(":");
		log(`PATH taken from ${basename(shell!)}: ${folders(soon.path).length} folders`);
		return undefined;
	}
	const began = env.PATH;
	const usual = usualFolders();
	env.PATH = folders(usual.join(":"), began).join(":");
	const added = `added ${usual.length === 0 ? "nothing" : usual.join(", ")}`;
	if (asked === undefined || soon.listening !== true) {
		log(`PATH not taken from the login shell (${soon.reason}); ${added}`);
		return undefined;
	}
	log(`PATH not taken from the login shell (${soon.reason}); ${added} for now, and still listening for its answer`);
	let stopping = false;
	const done = asked.late
		.then((late) => {
			if (stopping) return;
			if (!("path" in late)) {
				log(`PATH still not taken from the login shell (${late.reason}); it stays as it is until the engine starts again`);
				return;
			}
			// Exactly what an answer in time would have given: the shell's folders, then the ones the engine began
			// with, in the order it had them. Not built on the PATH of the meantime: the usual places were standing in
			// for the shell's own and were put in front, so carried over they would leave this PATH different from
			// the one a quicker start gives, in folders or in their order, for no reason the person could see.
			// (Nothing else in the engine changes the PATH, so nothing else is lost by starting again from `began`.)
			env.PATH = folders(late.path, began).join(":");
			log(`PATH taken from ${basename(shell!)}, ${span(Date.now() - askedAt)} after it was asked: ${folders(late.path).length} folders. What is started from now on gets it`);
		})
		.catch(() => {}); // only a log that cannot be written leads here, and then there is nowhere to say so
	return {
		done,
		stop: () => {
			stopping = true;
			asked.stop("the engine is stopping");
		},
	};
}
