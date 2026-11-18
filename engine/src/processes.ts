// The processes of commands pi² starts and leaves to run on their own: a worktree's set-up command (worktrees.ts) and a
// command an agent leaves running in the background (background.ts). See docs/worktrees.md and docs/background.md.
//
// Each such command leads a process group of its own and is started with a random marker in its environment, and with
// a file of its run open, which nothing else can open (`newRun`). While it runs, the engine notes the group, when its
// first process started, and the marker. Should the engine die outright, the next one goes by that note to stop what was
// left running, and only what is provably the same: a process number is given to other programs once it is free, so a
// number alone proves nothing. Both kinds of command read `ps` through here, so a start time noted by one is read the
// same way by the other.

import { type ChildProcess, execFile } from "node:child_process";
import { randomBytes } from "node:crypto";
import { subscribe } from "node:diagnostics_channel";
import { type BigIntStats, closeSync, constants, mkdirSync, openSync, rmSync } from "node:fs";
import { lstat, readdir, unlink } from "node:fs/promises";
import { execFileOffThread } from "./offthread.ts";
import { join } from "node:path";

/**
 * A command's process group: its id, which is the pid of the process that leads it, and when that process started, as
 * `ps -o lstart=` gives it. The start time tells the group apart from an unrelated one that later got the same number.
 * `marker` is the value of `RUN_VARIABLE` in the environment the command was started with, which whatever it starts
 * inherits: it tells a member of the group apart once the leader is no longer there to. A record without one is from
 * before there were markers, and only its leader can prove it.
 */
export type RunProcess = { group: number; start: string; marker?: string };

/** The environment variable that names one run of a command pi² started, for `stopLeftOver` to know its processes by. */
export const RUN_VARIABLE = "PI2_RUN";
/** A marker for a new run: 128 random bits, which nothing else has by chance. */
export const newRunMarker = (): string => randomBytes(16).toString("hex");
/** The processes being looked out for, by the marker they are to be started with. */
const lookedFor = new Map<string, (child: ChildProcess) => void>();
let looking = false;

/**
 * Look out for the process this engine is about to start with `marker` as `RUN_VARIABLE` in its environment, for a
 * command started by code that does not hand back its process: a foreground command, which pi durable's `exec` starts
 * (commands.ts). Node announces each process it starts on the `child_process.spawn` tracing channel, with the options it
 * was started with, before it runs; the marker tells this one apart from any other, whatever its command. `child()` is
 * undefined until it is seen, and stays so should Node not announce it; `done()` stops looking.
 */
export function lookOutFor(marker: string): { child(): ChildProcess | undefined; done(): void } {
	if (!looking) {
		looking = true;
		subscribe("tracing:child_process.spawn:start", (message) => {
			if (lookedFor.size === 0) return;
			const { process: child, options } = message as { process?: ChildProcess; options?: { env?: Record<string, string | undefined> } };
			const given = options?.env?.[RUN_VARIABLE];
			if (child !== undefined && typeof given === "string") lookedFor.get(given)?.(child);
		});
	}
	let found: ChildProcess | undefined;
	lookedFor.set(marker, (child) => {
		found = child;
		lookedFor.delete(marker);
	});
	return { child: () => found, done: () => void lookedFor.delete(marker) };
}

/** Whether a stored marker is one `newRunMarker` could have made. Anything else, a short or spaced one say, proves nothing. */
const isRunMarker = (marker: unknown): marker is string => typeof marker === "string" && /^[0-9a-f]{32}$/.test(marker);

/**
 * Where runs' files are kept (`newRun`): `runs` in the data folder, which the engine names at its start. Until it does,
 * no command is given a file, and none is looked for: a marker in the environment is then the only proof.
 */
let runFolder: string | undefined;
export const useRunFolder = (folder: string): void => void (runFolder = folder);
/** The descriptor a command is given its run's file as. High, so that it is out of the way of a script's own (3 to 9). */
const RUN_FD = 19;
const runFile = (folder: string, marker: string) => join(folder, marker);

/** A run about to be started: its marker, and the `stdio` to start it with, which hands it its file. */
export type NewRun = { marker: string; stdio: ("ignore" | "pipe" | number)[] };
/** Held until `forgetRun`, even if the command closes its copy: another engine must not sweep a live run's file. */
const liveFiles = new Map<string, number>();

/**
 * A new run of a command: a marker for its environment (`RUN_VARIABLE`), and an empty file of the run's own, named by
 * the marker, that the command is started with open as descriptor `RUN_FD` (`stdio`), which whatever it starts inherits.
 * The file is made with no permissions at all, so that no process, the person's own included, can open it once it is
 * made: a process that has it open got it from the command. macOS lets `lsof` list the files of the person's own
 * processes, the programs that come with macOS too, whose environment it does not show. So the file proves a process the
 * run's where the environment cannot (`holding`). The engine keeps its own copy until `forgetRun`, including when the
 * command could not be started. This keeps a live run's file safe from cleanup even if the command closes its copy.
 * Without a folder for it, or should it not be made, there is no file, and the command is started as before.
 */
export function newRun(): NewRun {
	const marker = newRunMarker();
	let fd: number | undefined;
	if (runFolder !== undefined) {
		try {
			mkdirSync(runFolder, { recursive: true, mode: 0o700 });
			// Node opens it close-on-exec, so no other process this engine starts gets it.
			const path = runFile(runFolder, marker);
			fd = openSync(path, constants.O_RDONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o000);
			liveFiles.set(path, fd);
		} catch {
			fd = undefined;
		}
	}
	const stdio: NewRun["stdio"] = ["ignore", "pipe", "pipe", ...(fd === undefined ? [] : [...Array<"ignore">(RUN_FD - 3).fill("ignore"), fd])];
	return { marker, stdio };
}

/** Remove the file of a run that is over, or that the engine after the one that started it has dealt with. */
export function forgetRun(marker: string | undefined): void {
	if (runFolder === undefined || !isRunMarker(marker)) return;
	const path = runFile(runFolder, marker);
	const fd = liveFiles.get(path);
	if (fd !== undefined) {
		liveFiles.delete(path);
		closeSync(fd);
	}
	try {
		rmSync(path, { force: true });
	} catch {
		// A later engine's sweep can remove it once nothing holds it.
	}
}

/**
 * Remove files left before a dead engine noted a run's process. No process is signalled. A complete, successful lsof
 * answer must show no holder, anywhere, including another engine and groups whose process was never recorded. Since
 * newRun creates and opens the file atomically and keeps it open until forgetRun, even an about-to-start run is safe.
 * Only unchanged empty private run files count; doubt, a failed listing or any diagnostic leaves the file alone.
 */
export async function sweepRuns(): Promise<void> {
	const folder = runFolder;
	if (folder === undefined) return;
	const names = await readdir(folder).catch(() => []);
	const candidates: { path: string; before: BigIntStats }[] = [];
	for (const marker of names) {
		if (!isRunMarker(marker)) continue;
		const path = runFile(folder, marker);
		if (liveFiles.has(path)) continue;
		const before = await lstat(path, { bigint: true }).catch(() => undefined);
		if (before === undefined || !before.isFile() || before.size !== 0n || (before.mode & 0o7777n) !== 0n || before.uid !== BigInt(process.getuid?.() ?? -1)) continue;
		candidates.push({ path, before });
	}
	if (candidates.length === 0) return;
	// One scan for the folder, not one per file: listing every process's files can be slow on a busy Mac. This runs
	// outside startup's wait, with a longer deadline than a targeted ps/lsof query. Too many paths fails closed too.
	const listed = await new Promise<string | undefined>((resolve) => {
		// On the engine's thread, unlike the others here: it runs once, after start-up, and the tests stand in for it there.
		execFile("/usr/sbin/lsof", ["-n", "-P", "-F", "pDi", "--", ...candidates.map(({ path }) => path)], { timeout: 120_000, maxBuffer: 16 * 1024 * 1024, env: psEnv() }, (error, stdout, stderr) => {
			// Exit 1 is the normal answer when none of the files is held. Diagnostics or any other failure are doubt.
			resolve(stderr !== "" || (error !== null && (error as { code?: unknown }).code !== 1) ? undefined : stdout);
		});
	});
	if (listed === undefined) return;
	const held = new Set<string>();
	let inFile = false;
	let device: bigint | undefined;
	let inode: bigint | undefined;
	const complete = () => {
		if (!inFile) return true;
		if (device === undefined || inode === undefined) return false;
		held.add(`${device}:${inode}`);
		return true;
	};
	for (const line of listed.split("\n")) {
		if (/^p\d+$/.test(line) || /^f.+$/.test(line)) {
			if (!complete()) return;
			inFile = line.startsWith("f");
			[device, inode] = [undefined, undefined];
		} else if (inFile && /^D0x[0-9a-f]+$/i.test(line)) device = BigInt(line.slice(1));
		else if (inFile && /^i\d+$/.test(line)) inode = BigInt(line.slice(1));
		else if (line !== "") return; // An answer whose fields we cannot read is not proof of absence.
	}
	if (!complete() || (listed !== "" && held.size === 0)) return;
	for (const { path, before } of candidates) {
		if (held.has(`${before.dev}:${before.ino}`) || liveFiles.has(path)) continue;
		const after = await lstat(path, { bigint: true }).catch(() => undefined);
		if (after === undefined || after.dev !== before.dev || after.ino !== before.ino || after.mode !== before.mode || after.uid !== before.uid || after.size !== before.size || after.ctimeNs !== before.ctimeNs) continue;
		await unlink(path).catch(() => {});
	}
}

/**
 * Which of `pids` have the file of the run `marker` open: the one `newRun` made, still there, still with no permissions,
 * and still the same file (the same device and inode). An inode number names one file on a device at a time, and one
 * still there is not given to another, so a process with that open has the run's file, which it can only have been
 * handed by the run. `lsof` reads that for the person's own processes, macOS's own programs among them. Anything it does
 * not answer in full, or a file that is gone or was changed, proves nothing.
 */
async function holding(pids: number[], marker: string): Promise<Set<number>> {
	const found = new Set<number>();
	if (runFolder === undefined || pids.length === 0) return found;
	const file = await lstat(runFile(runFolder, marker), { bigint: true }).catch(() => undefined);
	if (file === undefined || !file.isFile() || (file.mode & 0o7777n) !== 0n || file.uid !== BigInt(process.getuid?.() ?? -1)) return found;
	const listed = await new Promise<string | undefined>((resolve) => {
		execFileOffThread("/usr/sbin/lsof", ["-w", "-n", "-P", "-p", pids.join(","), "-F", "pDi"], { timeout: PS_TIMEOUT_MS, maxBuffer: 16 * 1024 * 1024, env: psEnv() }, (error, stdout) => {
			// lsof exits 1 when one of the processes asked about is not there: what it listed of the others still stands.
			resolve(error && (error as { code?: unknown }).code !== 1 ? undefined : String(stdout));
		});
	});
	if (listed === undefined) return found;
	// One field a line: `p` starts a process, `f` one of its files, then `D` its device (in hex) and `i` its inode.
	let pid = 0;
	let device: bigint | undefined;
	let inode: bigint | undefined;
	const done = () => {
		if (device === file.dev && inode === file.ino && pids.includes(pid)) found.add(pid);
		[device, inode] = [undefined, undefined];
	};
	for (const line of listed.split("\n")) {
		const [field, value] = [line[0], line.slice(1)];
		if (field === "p" || field === "f") done();
		if (field === "p") pid = /^\d+$/.test(value) ? Number(value) : 0;
		else if (field === "D" && /^0x[0-9a-f]+$/i.test(value)) device = BigInt(value);
		else if (field === "i" && /^\d+$/.test(value)) inode = BigInt(value);
	}
	done();
	return found;
}

/** After SIGTERM, how long what is left over gets before SIGKILL. */
const GRACE_MS = 3_000;
const PS_TIMEOUT_MS = 10_000;
/** UTC and the C locale, so the same process reads the same whoever asks and whenever. */
const psEnv = () => ({ ...process.env, LC_ALL: "C", TZ: "UTC" });

/** A process as `ps` lists it: its process group and when it started. */
export type Listed = { group: number; start: string };

/**
 * Processes as `ps` lists them, by pid: their process group and start time. Only `pid` when given, else all of them.
 * Processes that have ended and wait only to be reaped are left out: they run nothing.
 */
export function processes(pid?: number): Promise<Map<number, Listed>> {
	return new Promise((resolve, reject) => {
		const which = pid === undefined ? ["-A"] : ["-p", String(pid)];
		execFileOffThread("/bin/ps", [...which, "-o", "pid=,pgid=,stat=,lstart="], { timeout: PS_TIMEOUT_MS, maxBuffer: 16 * 1024 * 1024, env: psEnv() }, (error, stdout) => {
			const found = new Map<number, Listed>();
			for (const line of String(stdout).split("\n")) {
				const match = /^\s*(\d+)\s+(\d+)\s+(\S+)\s+(\S.*?)\s*$/.exec(line);
				if (match && !match[3]!.startsWith("Z")) found.set(Number(match[1]), { group: Number(match[2]), start: match[4]!.replace(/\s+/g, " ") });
			}
			// ps exits 1 when the one process asked about is not there: that is an answer, not a failure.
			if (error && !(pid !== undefined && (error as { code?: unknown }).code === 1)) reject(error);
			else resolve(found);
		});
	});
}

/** A process or group number that may be signalled: a whole number above 1 that is not this engine's own. */
export const signallable = (n: unknown): n is number => typeof n === "number" && Number.isSafeInteger(n) && n > 1 && n !== process.pid;

/**
 * What to note of a command just started with `marker`, so that the next engine can find it: its group and that group's
 * start. Read only while `child` is known not to have been reaped: until then its pid cannot belong to anything else.
 * Undefined when it has ended already, or was not the leader of a group of its own.
 */
export async function noteProcess(child: ChildProcess, marker: string): Promise<RunProcess | undefined> {
	const group = child.pid;
	if (!signallable(group)) return undefined;
	const own = (await processes(group)).get(group);
	if (own === undefined || own.group !== group || child.exitCode !== null || child.signalCode !== null) return undefined;
	return { group, start: own.start, marker };
}

/**
 * `pids` as `ps` lists them, each with its command line, and with its environment after that when `environment` is set.
 * A newline or tab in either is printed as `\012` or `\011`, so a process is always one line; the whole of it is asked
 * for (`-ww`), however long.
 */
function commandLines(pids: number[], environment: boolean): Promise<Map<number, Listed & { command: string }>> {
	return new Promise((resolve, reject) => {
		const args = [...(environment ? ["-E"] : []), "-ww", "-p", pids.join(","), "-o", "pid=,pgid=,stat=,lstart=,command="];
		execFileOffThread("/bin/ps", args, { timeout: PS_TIMEOUT_MS, maxBuffer: 32 * 1024 * 1024, env: psEnv() }, (error, stdout) => {
			const found = new Map<number, Listed & { command: string }>();
			for (const line of String(stdout).split("\n")) {
				// The start time is five words ("Mon Nov 16 20:57:27 2026"); the command is everything after it.
				const match = /^\s*(\d+)\s+(\d+)\s+(\S+)\s+(\S+\s+\S+\s+\S+\s+\S+\s+\S+)\s+(.*)$/.exec(line);
				if (match && !match[3]!.startsWith("Z")) found.set(Number(match[1]), { group: Number(match[2]), start: match[4]!.replace(/\s+/g, " "), command: match[5]! });
			}
			// ps exits 1 when none of them is there any more: that is an answer, not a failure.
			if (error && (error as { code?: unknown }).code !== 1) reject(error);
			else resolve(found);
		});
	});
}

/**
 * Which of `members` are provably of the run `marker`, and are still the processes listed: those that have the run's
 * file open (`holding`), and those that carry `RUN_VARIABLE` with the value `marker` in their environment. Either one is
 * proof; neither replaces the other. A process can close the file (as Python's `subprocess` does for what it starts), and
 * macOS shows no environment for its own programs (`/bin/sh`, `sleep`) or another person's, or for a process started with
 * a cleared one.
 *
 * `ps -E` prints the environment after the arguments with nothing to say where one ends and the other begins, so each
 * process is listed without it too and only what `-E` added counts: naming the marker in an argument is not carrying it.
 * A value with a space in it could spell the marker as a word of its own, but only by knowing the run's random value.
 * The files are read first, so that the listing that tells whether each is still the same process comes after.
 */
async function carrying(members: [number, Listed][], marker: string): Promise<[number, Listed][]> {
	const pids = members.map(([pid]) => pid).filter(signallable);
	if (pids.length === 0) return [];
	const holders = await holding(pids, marker).catch(() => new Set<number>());
	const [bare, full] = await Promise.all([commandLines(pids, false), commandLines(pids, true)]);
	return members.filter(([pid, was]) => {
		const [a, b] = [bare.get(pid), full.get(pid)];
		if (!signallable(pid) || a === undefined || b === undefined || [a, b].some((each) => each.group !== was.group || each.start !== was.start)) return false;
		if (holders.has(pid)) return true;
		if (!b.command.startsWith(`${a.command} `)) return false;
		return b.command.slice(a.command.length + 1).split(" ").includes(`${RUN_VARIABLE}=${marker}`);
	});
}

/**
 * SIGKILL whatever of `members` is still there: the whole of `group`, when one is given and its leader is still there,
 * else each one that is still the same process (the same group, started at the same time) as when it was listed.
 */
export async function killRemaining(members: [number, Listed][], group?: number): Promise<void> {
	if (members.length === 0) return;
	const now = await processes().catch(() => new Map<number, Listed>());
	const same = ([pid, was]: [number, Listed]) => signallable(pid) && now.get(pid)?.group === was.group && now.get(pid)?.start === was.start;
	const leader = members.find(([pid]) => pid === group);
	const targets = group !== undefined && leader !== undefined && same(leader) ? [-group] : members.filter(same).map(([pid]) => pid);
	for (const target of targets) {
		try {
			process.kill(target, "SIGKILL");
		} catch {
			// Gone meanwhile.
		}
	}
}

/** After `graceMs`, SIGKILL whatever of `members` SIGTERM did not end, as `killRemaining` does. */
export function killLater(members: [number, Listed][], graceMs: number, group?: number): void {
	setTimeout(() => void killRemaining(members, group), graceMs).unref();
}

/**
 * What became of a command an engine that died left behind: all of it stopped, some of it stopped and the rest left
 * alone, nothing of it running, or something that may be its left alone.
 */
export type LeftOver = "stopped" | "partly" | "gone" | "unsure";
/** What the engine's log says of each, after "left by the last engine". */
export const leftOverLog: Record<LeftOver, string> = { stopped: "was stopped", partly: "was stopped in part; the rest may still be running", gone: "is not running", unsure: "may still be running" };

/**
 * Stop what is left of a command's process group after the engine that started it died, but only what is provably the
 * same run.
 *
 * While its leader is alive, still leads the group, and started when the record says, the whole group is the run's: a
 * group's id is not given to a new process while the group lasts. Then the group is signalled as one.
 *
 * Without that leader, a group of this number may be what the command started in the background before its first process
 * ended, or another group that got the same number later. The number alone cannot tell, so each member is asked for
 * proof that it is the run's, the run's file open or its marker in the environment (`carrying`), and those that have it
 * are signalled one by one, by pid. A member without either is left alone.
 *
 * The record is dealt with once: the run's file is removed afterwards (`forgetRun`).
 *
 * "stopped" is answered once SIGTERM is sent to everything found; whatever of it is still there, and still the same
 * process, gets SIGKILL after `graceMs`. "partly" means the members with the marker were stopped so, and others that may
 * be the run's were left alone; "unsure", that something that may be the run's was left alone and nothing was stopped.
 * "gone" means nothing of it is running.
 */
export async function stopLeftOver(left: RunProcess, graceMs = GRACE_MS): Promise<LeftOver> {
	try {
		return await stopRun(left, graceMs);
	} finally {
		forgetRun(left.marker);
	}
}

async function stopRun(left: RunProcess, graceMs: number): Promise<LeftOver> {
	// The record comes from a stored document, and a group number of 1 would signal every process the person owns, and 0
	// this engine's own group. Anything a command could never have been recorded with is refused before looking.
	if (!signallable(left.group) || typeof left.start !== "string" || left.start === "") return "unsure";
	const all = await processes();
	// Nor the group this engine is in, or one whose number it cannot read.
	const ownGroup = all.get(process.pid)?.group;
	if (ownGroup === undefined || ownGroup === left.group) return "unsure";
	const members = [...all].filter(([, each]) => each.group === left.group);
	const leader = all.get(left.group);
	if (leader !== undefined && leader.group === left.group && leader.start === left.start) {
		try {
			process.kill(-left.group, "SIGTERM");
		} catch {
			return "gone";
		}
		killLater(members, graceMs, left.group);
		return "stopped";
	}
	const marked = isRunMarker(left.marker) ? await carrying(members, left.marker) : [];
	for (const [pid] of marked) {
		try {
			process.kill(pid, "SIGTERM");
		} catch {
			// Gone meanwhile.
		}
	}
	if (marked.length > 0) killLater(marked, graceMs);
	// A number that now belongs to a process that started at another time was free in between, so the recorded group had
	// ended by then: whoever is in a group of that number now, without the marker, is not of it. Otherwise the members
	// without the marker may be the run's (one whose environment cannot be read, say) or may not: they cannot be told.
	const reused = leader !== undefined && leader.start !== left.start;
	if (!reused && marked.length < members.length) return marked.length > 0 ? "partly" : "unsure";
	return marked.length > 0 ? "stopped" : "gone";
}
