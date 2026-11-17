// The processes of commands pi² starts and leaves to run on their own: a worktree's set-up command (worktrees.ts) and a
// command an agent leaves running in the background (background.ts). See docs/worktrees.md and docs/background.md.
//
// Each such command leads a process group of its own and is started with a random marker in its environment. While it
// runs, the engine notes the group, when its first process started, and the marker. Should the engine die outright, the
// next one goes by that note to stop what was left running, and only what is provably the same: a process number is
// given to other programs once it is free, so a number alone proves nothing. Both kinds of command read `ps` through
// here, so a start time noted by one is read the same way by the other.

import { type ChildProcess, execFile } from "node:child_process";
import { randomBytes } from "node:crypto";

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
/** Whether a stored marker is one `newRunMarker` could have made. Anything else, a short or spaced one say, proves nothing. */
const isRunMarker = (marker: unknown): marker is string => typeof marker === "string" && /^[0-9a-f]{32}$/.test(marker);

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
		execFile("/bin/ps", [...which, "-o", "pid=,pgid=,stat=,lstart="], { timeout: PS_TIMEOUT_MS, maxBuffer: 16 * 1024 * 1024, env: psEnv() }, (error, stdout) => {
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
		execFile("/bin/ps", args, { timeout: PS_TIMEOUT_MS, maxBuffer: 32 * 1024 * 1024, env: psEnv() }, (error, stdout) => {
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
 * Which of `members` carry `RUN_VARIABLE` with the value `marker` in their environment, and are still the processes
 * listed. `ps -E` prints the environment after the arguments with nothing to say where one ends and the other begins, so
 * each process is listed without it too and only what `-E` added counts: naming the marker in an argument is not carrying
 * it. macOS shows the environment only of the person's own processes, and not of the programs that come with macOS itself
 * (`/bin/sh`, `sleep`): those read as carrying nothing, as does a process started with a cleared environment. A value
 * with a space in it could spell the marker as a word of its own, but only by knowing the run's random value.
 */
async function carrying(members: [number, Listed][], marker: string): Promise<[number, Listed][]> {
	const pids = members.map(([pid]) => pid).filter(signallable);
	if (pids.length === 0) return [];
	const [bare, full] = await Promise.all([commandLines(pids, false), commandLines(pids, true)]);
	return members.filter(([pid, was]) => {
		const [a, b] = [bare.get(pid), full.get(pid)];
		if (a === undefined || b === undefined || [a, b].some((each) => each.group !== was.group || each.start !== was.start)) return false;
		if (!b.command.startsWith(`${a.command} `)) return false;
		return b.command.slice(a.command.length + 1).split(" ").includes(`${RUN_VARIABLE}=${marker}`);
	});
}

/**
 * After `graceMs`, SIGKILL whatever of `members` SIGTERM did not end: the whole of `group`, when one is given and its
 * leader is still there, else each one that is still the same process.
 */
export function killLater(members: [number, Listed][], graceMs: number, group?: number): void {
	setTimeout(async () => {
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
	}, graceMs).unref();
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
 * ended, or another group that got the same number later. The number alone cannot tell, so each member is asked for the
 * run's marker (`carrying`), and those that have it are signalled one by one, by pid. A member without it is left alone.
 *
 * "stopped" is answered once SIGTERM is sent to everything found; whatever of it is still there, and still the same
 * process, gets SIGKILL after `graceMs`. "partly" means the members with the marker were stopped so, and others that may
 * be the run's were left alone; "unsure", that something that may be the run's was left alone and nothing was stopped.
 * "gone" means nothing of it is running.
 */
export async function stopLeftOver(left: RunProcess, graceMs = GRACE_MS): Promise<LeftOver> {
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
