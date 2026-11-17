// Commands an agent leaves running in the background (issue #50). See docs/background.md.
//
// `bash` with `background: true` starts a command and returns at once; the `background` tool lists a conversation's
// commands, reads what they have printed since the last read, and stops them. Starting one is a `bash` call like any
// other, so Ask first, "Always Allow bash Here" and command rules judge it exactly as they judge a command that is
// waited for (extensions.ts); reading and stopping only touch what the conversation itself started, and never ask.
//
// Each command leads a process group of its own, as a worktree's set-up command does, so stopping it stops whatever it
// started. Its output comes to the engine through pipes, and only the end of it is kept, in memory. A session document
// records each running command's group, when its first process started, and the marker it was started with, so that an
// engine started after one that died can stop what was left running, and only what is provably the same (`stopLeftOver`
// in processes.ts).
//
// A command the agent waits for that reaches its time limit can become one too (`adopt`, issue #197): commands.ts moves
// it here, where starting it would not have asked the person, and from then on it is followed exactly as one started here.
//
// Nothing here limits how many there are or how long they run. A command runs until it ends, the agent or the person
// stops it, its conversation is archived or deleted, the worktree it runs in is removed, or the engine stops.

import { type ChildProcess, spawn } from "node:child_process";
import { realpathSync, statSync } from "node:fs";
import { sep } from "node:path";
import { awaitWithContext, type Context } from "@earendil-works/chord/context";
import { type ConversationId, defineDoc, defineTool, section, type ToolExecutionApi, type ToolExecutionResult } from "@earendil-works/pi-durable";
import { int, num, obj, opt, str } from "@earendil-works/pi-schema";
import { commandEnvironment } from "./environment.ts";
import type { Engine, Feature } from "./features.ts";
import { killLater, killRemaining, type Listed, type LeftOver, leftOverLog, newRunMarker, noteProcess, processes, RUN_VARIABLE, type RunProcess, signallable, stopLeftOver } from "./processes.ts";

/** How much of a command's output is kept: its end. The buffer is cut back to this once it holds twice as much. */
export const KEEP_CHARS = 128 * 1024;
/**
 * The most one read, or the answer to starting or stopping a command, carries: in characters, in lines and in bytes,
 * whichever comes first. All three stay inside what the harness lets a tool's result hold (2,000 lines, 50 KB), so the
 * notes around the output, such as how much more is waiting, are never what gets cut.
 */
export const READ_CHARS = 30_000;
export const READ_LINES = 1_500;
const READ_BYTES = 40_000;
/** After SIGTERM, how long a command gets before SIGKILL; after it exits, how long the rest of its output may take. */
const GRACE_MS = 3_000;
/** How long the call that starts a command waits to see whether it fails at once, such as a program that is not there. */
const SETTLE_MS = 1_000;
/** On a clean stop of the engine, how long commands get between SIGTERM and SIGKILL. The app waits five seconds for the engine. */
const SHUTDOWN_GRACE_MS = 1_500;
/** The longest a read waits for new output. Stopping the run ends the wait sooner. */
export const MAX_WAIT_SECONDS = 600;
/**
 * The longest a request from the app for a command's output waits for more. The app asks again when it returns.
 * `PI2_OUTPUT_WAIT_SECONDS` sets another, for a test that must tell a wait ended by output from one that ran out.
 */
export const APP_WAIT_SECONDS = (() => {
	const given = Number(process.env.PI2_OUTPUT_WAIT_SECONDS);
	return Number.isFinite(given) && given > 0 ? given : 30;
})();
/** How many ended commands are remembered, across all conversations, for their output to be read. */
const ENDED_KEPT = 50;
/** How many of a conversation's ended commands its agent is reminded of. */
const ENDED_TOLD = 5;
const MAX_TIMEOUT_SECONDS = 2_147_483;

/** A line the transcript shows the person when a background command ends other than by the agent stopping it. */
export const BACKGROUND_ENTRY = "pi2.background";

/** A running command as the session document records it, for the engine that starts after this one. */
type Left = { id: string; conversationId: number; command: string; cwd: string; startedAt: number; process?: RunProcess };

const Background = defineDoc<{ next: number; running: Record<string, Left> }>({
	kind: "pi2.background",
	version: 1,
	scope: "session",
	initial: () => ({ next: 1, running: {} }),
	checkpointWhen: () => true,
});

type Command = {
	id: string;
	conversationId: number;
	command: string;
	cwd: string;
	startedAt: number;
	/** Absent for a command an earlier engine started: all that is known of it is its record. */
	child?: ChildProcess;
	/** The end of what it has printed, standard output and errors together as they arrived. */
	output: string;
	/** How many characters it has printed in all, and how many of them the agent has been given. */
	total: number;
	read: number;
	/** Why it is being stopped, worded to follow the command: "was stopped by the agent". */
	stopping?: string;
	/** Set once it is over and its output is complete. */
	ended?: { at: number; how: string; failed: boolean };
	/** Resolves when `ended` is set. */
	settled: Promise<void>;
	/** Reads waiting for output or the end. */
	waiters: Set<() => void>;
};

/**
 * What became of the commands the last engine left running, for the notice after it stopped unexpectedly: one each, with
 * the conversation in the sidebar it belongs to.
 */
type LeftBehind = { id: string; conversationId: number; rootConversationId: number; title: string; command: string; outcome: LeftOver | "unknown"; group: number | null };
const leftBehind: LeftBehind[] = [];

/** A command as engine.log names it: with its conversation, since a command's id alone does not say whose it was. */
const logName = (id: string, conversationId: number) => `background command ${id} of conversation ${conversationId}`;

/** Every command this engine knows of, running and recently ended, by id. */
const commands = new Map<string, Command>();
let engine: Engine | undefined;
/** Set by a clean stop of the engine: what ends from then on keeps its record, for the next engine to write down. */
let shuttingDown = false;

const text = (value: string) => [{ type: "text" as const, text: value }];
const fail = (message: string) => ({ output: text(message), isError: true });
const isRunning = (command: Command) => command.ended === undefined;
const reaped = (child: ChildProcess) => child.exitCode !== null || child.signalCode !== null;

/** "bg-3" for "bg-3", "BG-3" or "3". */
const idOf = (given: string) => {
	const id = given.trim().toLowerCase();
	return /^\d+$/.test(id) ? `bg-${id}` : id;
};

/** The command on one line, for a list or a marker. */
export function commandLine(command: string, most = 120): string {
	const line = command.replace(/\s+/g, " ").trim();
	return line.length > most ? `${line.slice(0, most)}…` : line;
}

/** "42 seconds", "3 minutes", "2 hours 5 minutes". */
export function elapsed(ms: number): string {
	const seconds = Math.max(0, Math.round(ms / 1000));
	const plural = (count: number, unit: string) => `${count} ${unit}${count === 1 ? "" : "s"}`;
	if (seconds < 90) return plural(seconds, "second");
	const minutes = Math.round(seconds / 60);
	if (minutes < 90) return plural(minutes, "minute");
	return minutes % 60 === 0 ? plural(minutes / 60, "hour") : `${plural(Math.floor(minutes / 60), "hour")} ${plural(minutes % 60, "minute")}`;
}

const clock = (at: number) => {
	const d = new Date(at);
	return `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
};

/** What the transcript shows for a `BACKGROUND_ENTRY`: "Background command bg-2 exited with code 1: npm run dev". */
export function backgroundMarker(data: unknown): string {
	const entry = (data !== null && typeof data === "object" ? data : {}) as { id?: unknown; command?: unknown; how?: unknown };
	const id = typeof entry.id === "string" ? ` ${entry.id}` : "";
	const how = typeof entry.how === "string" && entry.how.trim() !== "" ? entry.how : "ended";
	const command = typeof entry.command === "string" ? commandLine(entry.command) : "";
	return `Background command${id} ${how}${command === "" ? "" : `: ${command}`}`;
}

/**
 * What the app is given with that line besides its words: the command's id, for a way to the window with its output.
 * Nothing for an entry with no id this engine could have given.
 */
export function backgroundMarkerDetails(data: unknown): { background: { id: string } } | undefined {
	const id = data !== null && typeof data === "object" ? (data as { id?: unknown }).id : undefined;
	return typeof id === "string" && /^bg-[1-9][0-9]{0,8}$/.test(id) ? { background: { id } } : undefined;
}

// ---- Process groups

function realish(path: string): string {
	try {
		return realpathSync(path);
	} catch {
		return path;
	}
}

/**
 * Signal a command and everything it started. Only while its first process has not been reaped: until then its number,
 * which is also the group's, cannot belong to anything else.
 */
function signalGroup(child: ChildProcess, signal: NodeJS.Signals): void {
	if (!signallable(child.pid) || reaped(child)) return;
	try {
		process.kill(-child.pid, signal);
	} catch {
		// Already gone.
	}
}

/**
 * Stop what a command left running in its process group after its first process ended (`server & disown`, say), so that
 * "ended" means nothing of it is still running unseen. A group's number is not given to a new process while the group
 * has members, so members found under it are the command's own: they get SIGTERM, and those still there after `graceMs`,
 * and provably the same, SIGKILL. Answers whether there were any.
 */
async function stopMembers(group: number, graceMs: number): Promise<boolean> {
	if (!signallable(group)) return false;
	const before = await processes().catch(() => undefined);
	if (before === undefined) return false;
	// Never the group this engine is in, or any group when it cannot read its own.
	const own = before.get(process.pid)?.group;
	if (own === undefined || own === group) return false;
	const members = [...before].filter(([pid, each]) => each.group === group && signallable(pid));
	if (members.length === 0) return false;
	try {
		process.kill(-group, "SIGTERM");
	} catch {
		return true;
	}
	killLater(members, graceMs);
	return true;
}

// ---- Keeping track

/** What the apps are sent: the commands running now, oldest first. Activity lists them, each with a way to stop it. */
function event() {
	const library = engine?.library().conversations ?? {};
	const running = [...commands.values()].filter(isRunning).sort((a, b) => a.startedAt - b.startedAt);
	return {
		event: "background",
		commands: running.map((command) => ({
			id: command.id,
			conversationId: command.conversationId,
			// The conversation in the sidebar: a sub-chat's commands are reached through the one it belongs to.
			rootConversationId: library[String(command.conversationId)]?.parent ?? command.conversationId,
			command: command.command,
			cwd: command.cwd,
			startedAt: command.startedAt,
		})),
	};
}

const announce = () => engine?.broadcast(event());

async function save(edit: (doc: { next: number; running: Record<string, Left> }) => void): Promise<void> {
	if (engine === undefined) return;
	await engine.harness().commit(async (tx) => edit(await tx.doc(Background)), engine.context());
}

/** Write a command's end into its conversation's transcript, where the person sees it. The model does not: its section tells it. */
async function note(command: Command, how: string): Promise<void> {
	if (engine === undefined) return;
	try {
		const conv = await engine.harness().conversation(command.conversationId as unknown as ConversationId, engine.context());
		const data = { id: command.id, command: command.command, how, seconds: Math.round(((command.ended?.at ?? Date.now()) - command.startedAt) / 1000) };
		await conv?.submit({ type: "write", entry: { kind: BACKGROUND_ENTRY, data } }, engine.context());
	} catch (error) {
		engine.log("could not note the end of", logName(command.id, command.conversationId), error instanceof Error ? error.message : error);
	}
}

/** Forget the oldest ended commands, and their output, beyond the number kept. */
function prune(): void {
	const ended = [...commands.values()].filter((command) => !isRunning(command)).sort((a, b) => a.ended!.at - b.ended!.at);
	for (const command of ended.slice(0, Math.max(0, ended.length - ENDED_KEPT))) commands.delete(command.id);
}

const wake = (command: Command) => {
	for (const waiter of [...command.waiters]) waiter();
};

/**
 * Ask a running command to stop: SIGTERM to its group now, SIGKILL after `graceMs` if its first process is still there.
 * `how` is what its end is then put down to. Resolves once it has ended and its output is complete.
 */
function stop(command: Command, how: string, graceMs = GRACE_MS): Promise<void> {
	if (!isRunning(command) || command.child === undefined) return command.settled;
	if (command.stopping === undefined) {
		command.stopping = how;
		const child = command.child;
		signalGroup(child, "SIGTERM");
		setTimeout(() => signalGroup(child, "SIGKILL"), graceMs).unref();
	}
	return command.settled;
}

function isFolder(path: string): boolean {
	try {
		return statSync(path).isDirectory();
	} catch {
		return false;
	}
}

/** Whether `folder` is `root` or inside it. */
const within = (folder: string, root: string) => (realish(folder) + sep).startsWith(realish(root) + sep);

/** Stop the background commands running in `folder` or below it, and wait for them: a worktree about to be removed. */
export async function stopCommandsIn(folder: string, how: string): Promise<void> {
	await Promise.all([...commands.values()].filter((command) => isRunning(command) && within(command.cwd, folder)).map((command) => stop(command, how)));
}

/** Whether a conversation has a background command running: one that does is not archived for being left unused. */
export function hasRunningCommands(conversationId: number): boolean {
	return [...commands.values()].some((command) => command.conversationId === conversationId && isRunning(command));
}

/** The background commands a conversation has running, oldest first: what the agent is told before they are stopped. */
export function runningCommandsOf(conversationId: number): { id: string; command: string }[] {
	return [...commands.values()]
		.filter((command) => command.conversationId === conversationId && isRunning(command))
		.sort((a, b) => a.startedAt - b.startedAt)
		.map((command) => ({ id: command.id, command: commandLine(command.command) }));
}

/** Stop the background commands a conversation has running, and wait for them: a sub-chat about to be archived. */
export async function stopCommandsOf(conversationId: number, how: string): Promise<void> {
	await Promise.all([...commands.values()].filter((command) => command.conversationId === conversationId && isRunning(command)).map((command) => stop(command, how)));
}

/** Why a conversation is out of the sidebar, itself or through the conversation it is a sub-chat of. */
function putAway(conversationId: number): "archived" | "deleted" | undefined {
	const all = engine?.library().conversations ?? {};
	const own = (key: number | undefined): "archived" | "deleted" | undefined => {
		if (key === undefined) return undefined;
		const meta = all[String(key)];
		if (meta === undefined || meta.deleted === true) return "deleted";
		return meta.archivedAt !== undefined || meta.archived !== undefined ? "archived" : undefined;
	};
	const reasons = [own(conversationId), own(all[String(conversationId)]?.parent)];
	return reasons.includes("deleted") ? "deleted" : reasons.includes("archived") ? "archived" : undefined;
}

// ---- Starting one

/** The part of `bash`'s description that tells the model about the mode. */
export const BACKGROUND_DESCRIPTION =
	"With `background: true` the command is started and left running while you carry on: use it for a server, a watching build, a test copy of an app, or anything else that takes long or does not end by itself. " +
	"The call returns after a moment with the command's id and what it has printed by then; the background tool reads its later output, lists what is running and stops it. " +
	"A background command has no time limit unless you pass `timeout`. It keeps running after you finish answering, until it ends, you or the person stop it, the conversation is archived, or pi² stops. " +
	"Run the long-lived program itself, without `&` or `nohup`: what the command leaves running when its own process ends is stopped with it.";

export const BACKGROUND_PARAMETER = "Start the command and leave it running in the background, instead of waiting for it. Read its output later with the background tool.";

/**
 * Start `args.command` in the background for the calling conversation: what `bash` does when it is called with
 * `background: true` (commands.ts). The approval hook has already run by now, as for any `bash` call.
 */
export async function startInBackground(args: { command: string; timeout?: number }, api: ToolExecutionApi, _context: Context): Promise<ToolExecutionResult> {
	if (engine === undefined || api.env === undefined) throw new Error("Background commands are not available here");
	const host = engine;
	if (args.timeout !== undefined && !(Number.isFinite(args.timeout) && args.timeout > 0 && args.timeout <= MAX_TIMEOUT_SECONDS)) {
		throw new Error(`Invalid timeout: a number of seconds above zero, at most ${MAX_TIMEOUT_SECONDS}`);
	}
	if (args.command.trim() === "") return fail("There is no command to start.");
	const conversationId = api.conversationId as unknown as number;
	const cwd = api.env.cwd;
	if (!isFolder(cwd)) return fail(`The conversation's folder is not there, so the command was not started: ${cwd}`);
	const startedAt = Date.now();
	// The record comes first, so a command is never running without one.
	let id = "";
	await save((doc) => {
		id = `bg-${doc.next}`;
		doc.next += 1;
		doc.running[id] = { id, conversationId, command: args.command, cwd, startedAt };
	});
	const forget = () => save((doc) => void delete doc.running[id]).catch((error) => host.log("could not forget", logName(id, conversationId), error instanceof Error ? error.message : error));

	// As a command that is waited for is run: through bash, in the conversation's folder, with the engine's environment
	// less pi²'s own settings (environment.ts), and no input. In a process group of its own, so that stopping it stops whatever it started too. One variable is
	// added to that environment: a marker of this run, which what it starts inherits, so that the next engine can know
	// them if this one dies, even once the command's own first process has ended (`stopLeftOver`).
	const marker = newRunMarker();
	let child: ChildProcess;
	try {
		child = spawn("/bin/bash", ["-c", args.command], { cwd, env: commandEnvironment({ [RUN_VARIABLE]: marker }), detached: true, stdio: ["ignore", "pipe", "pipe"] });
	} catch (error) {
		await forget();
		return fail(`The command could not be started: ${error instanceof Error ? error.message : String(error)}`);
	}
	const command: Command = { id, conversationId, command: args.command, cwd, startedAt, child, output: "", total: 0, read: 0, settled: Promise.resolve(), waiters: new Set() };
	commands.set(id, command);
	const followed = follow(host, command, child, marker, args.timeout, forget);
	child.stdout?.setEncoding("utf8").on("data", followed.keep);
	child.stderr?.setEncoding("utf8").on("data", followed.keep);
	announce();

	let sawTheEnd = false;
	try {
		// A moment to see whether it fails at once: a program that is not there, a port already taken.
		await Promise.race([command.settled, new Promise<void>((resolve) => setTimeout(resolve, SETTLE_MS).unref())]);
		await followed.recorded;
		sawTheEnd = command.ended !== undefined;
		return started(command, args.timeout, followed.neverStarted());
	} finally {
		followed.answer(sawTheEnd);
	}
}

/**
 * Make a foreground command that reached its time limit a background command, as if it had been started as one: what
 * `bash` does at the limit when starting the command in the background would not have asked the person (commands.ts).
 * `child` is its process, which leads a group of its own and was started with `marker` in its environment; its output
 * keeps coming through the caller, which `route` points at the command's from then on. `printed` is what it has printed
 * so far: the end of it, and how many characters in all. The agent is given that in the call's result, so it counts as
 * read. Undefined, and nothing changed, when the command can no longer be moved: it has ended, `wanted` says no (the
 * call was stopped), its conversation was put away, or the engine is stopping.
 */
export async function adopt(given: {
	child: ChildProcess;
	marker: string;
	command: string;
	cwd: string;
	conversationId: number;
	startedAt: number;
	printed: () => { output: string; total: number };
	route: (keep: (chunk: string) => void) => void;
	wanted: () => boolean;
}): Promise<{ id: string; recorded: Promise<void>; answer: (sawTheEnd: boolean) => void } | undefined> {
	if (engine === undefined) return undefined;
	const host = engine;
	const { child, conversationId } = given;
	const movable = () => !shuttingDown && signallable(child.pid) && !reaped(child) && putAway(conversationId) === undefined && given.wanted();
	if (!movable()) return undefined;
	let id = "";
	await save((doc) => {
		id = `bg-${doc.next}`;
		doc.next += 1;
		doc.running[id] = { id, conversationId, command: given.command, cwd: given.cwd, startedAt: given.startedAt };
	});
	const forget = () => save((doc) => void delete doc.running[id]).catch((error) => host.log("could not forget", logName(id, conversationId), error instanceof Error ? error.message : error));
	if (!movable()) {
		await forget();
		return undefined;
	}
	// From here to `route` nothing waits, so no output can come in between and be lost or counted twice.
	const { output, total } = given.printed();
	const command: Command = { id, conversationId, command: given.command, cwd: given.cwd, startedAt: given.startedAt, child, output: output.slice(-KEEP_CHARS), total, read: total, settled: Promise.resolve(), waiters: new Set() };
	commands.set(id, command);
	const followed = follow(host, command, child, given.marker, undefined, forget);
	given.route(followed.keep);
	host.log(logName(id, conversationId), "reached its time limit in the foreground and was moved to the background");
	announce();
	return { id, recorded: followed.recorded, answer: followed.answer };
}

/**
 * Follow a background command's process from its start, or from its move to the background, to its end: what ends it,
 * its record for the next engine, and what is said of its end. `keep` takes its output as it comes; `answer` is told
 * whether the call that started it said, in its own result, that it was already over.
 */
function follow(host: Engine, command: Command, child: ChildProcess, marker: string, timeout: number | undefined, forget: () => Promise<void>) {
	const { id, conversationId } = command;
	let finish: () => void = () => {};
	command.settled = new Promise<void>((resolve) => (finish = resolve));
	const keep = (chunk: string) => {
		command.output += chunk;
		command.total += chunk.length;
		if (command.output.length > 2 * KEEP_CHARS) command.output = command.output.slice(-KEEP_CHARS);
		wake(command);
	};
	const closed = new Promise<void>((resolve) => child.once("close", () => resolve()));
	const timer =
		timeout === undefined ? undefined : setTimeout(() => void stop(command, `was stopped after ${elapsed(timeout * 1000)}, the \`timeout\` its call gave`), timeout * 1000);
	timer?.unref();

	let over = false;
	/** Set when bash itself could not be started: then there never was a command, and nothing is said of one. */
	let neverStarted: string | undefined;
	/** Whether the call that started the command said, in its own result, that it was already over. */
	let answer: (sawTheEnd: boolean) => void = () => {};
	const answered = new Promise<boolean>((resolve) => (answer = resolve));
	/**
	 * `left` answers whether the command, ending other than by a stop pi² carried out, left something running in its group, once that has been looked
	 * into and stopped. For a stop pi² carried out it is always false: that stop was of everything the command started.
	 */
	const end = async (how: string, failed: boolean, at: number, left: Promise<boolean>) => {
		if (over) return;
		over = true;
		clearTimeout(timer);
		child.stdout?.destroy();
		child.stderr?.destroy();
		const ended = { at, how, failed };
		command.ended = ended;
		finish();
		wake(command);
		prune();
		announce();
		const leftSomething = await left.catch(() => false);
		if (leftSomething) ended.how = `${how}, and what it had left running was stopped with it`;
		host.log(logName(id, conversationId), ended.how);
		// Stopped with the engine, its record stays: the next engine writes its end down, and tells the agent.
		if (shuttingDown) return;
		await forget();
		// The transcript already shows a stop the agent asked for, in that call's row, and an end the call that started
		// the command saw, in that one's. Any other end gets a line of its own, and so does what was stopped with it.
		if (command.stopping === STOPPED_BY_AGENT || neverStarted !== undefined) return;
		if (leftSomething || !(await answered)) await note(command, ended.how);
	};
	child.once("error", (error) => {
		neverStarted = error.message;
		void end(`could not start: ${error.message}`, true, Date.now(), Promise.resolve(false));
	});
	child.once("exit", (code, signal) => {
		const at = Date.now();
		// Its number is free for another process from here on, so nothing more is signalled by it: what it left in its
		// group is looked up and stopped by what `ps` says is there.
		const swept = signallable(child.pid) ? stopMembers(child.pid, GRACE_MS) : Promise.resolve(false);
		// A stop pi² carried out (the agent's, the person's, a time limit, archiving) was sent to the whole group at once and
		// was always meant to take everything the command started. Whether some of it outlived the first process by a moment
		// depends only on how busy the Mac is, so it is not told: the same stop is worded the same way every time (#168).
		const left = command.stopping === undefined ? swept : swept.then(() => false);
		const how = command.stopping ?? (code === 0 ? "finished" : code === null ? `was ended by ${signal ?? "a signal"}` : `exited with code ${code}`);
		const failed = command.stopping === undefined && code !== 0;
		// It is over once the rest of its output is in: when its pipes close, or after a moment, should something it left
		// behind still hold them. That does not wait for the look at its group, which only adds to what is said of its end.
		void Promise.race([closed, new Promise<void>((resolve) => setTimeout(resolve, GRACE_MS).unref())]).then(() => end(how, failed, at, left));
	});

	// Its process group, that group's start and the run's marker, for the engine that comes after this one, should this one
	// die. Read only while the child is known not to have been reaped: until then its pid cannot belong to anything else.
	const recorded = noteProcess(child, marker)
		.then(async (noted) => {
			if (noted === undefined) return;
			await save((doc) => {
				const record = doc.running[id];
				if (record !== undefined && !over) record.process = noted;
			});
		})
		.catch((error) => host.log("could not note the process of", logName(id, conversationId), error instanceof Error ? error.message : error));
	return { keep, recorded, answer, neverStarted: () => neverStarted };
}

/** What the call that started a command answers: its id, how it stands after a moment, and what it has printed. */
function started(command: Command, timeout: number | undefined, neverStarted: string | undefined): ToolExecutionResult {
	const id = command.id;
	if (neverStarted !== undefined) {
		commands.delete(id);
		return fail(`The command could not be started: ${neverStarted}`);
	}
	const shown = unread(command);
	const lost = shown.dropped === 0 ? "" : `[${count(shown.dropped)} before this were not kept: only the last ${KEEP_CHARS / 1024} KB is.]\n`;
	const more = shown.waiting === 0 ? "" : `\n[${count(shown.waiting)} more: read them with the background tool.]`;
	const said = shown.text === "" ? "It has printed nothing yet." : `What it has printed so far:\n${lost}${shown.text}${more}`;
	const details = { background: { id, status: isRunning(command) ? "running" : "ended" } };
	if (command.ended !== undefined) {
		const lead = `Started in the background as ${id}, but it is already over: it ${command.ended.how}.`;
		const printed = shown.text === "" ? "It printed nothing." : `What it printed:\n${lost}${shown.text}${more}`;
		return { output: text(`${lead} ${printed}`), details, ...(command.ended.failed ? { isError: true } : { structuredOutput: { output: shown.text, truncated: false, exitCode: 0, background: id } }) };
	}
	return {
		output: text(
			`Started in the background as ${id}. It keeps running after this call, with ${timeout === undefined ? "no time limit" : `a time limit of ${elapsed(timeout * 1000)}`}. ${said}\n` +
				`Use the background tool with id "${id}" to read what it prints from here on (action "read") and to stop it (action "stop").`,
		),
		details,
		structuredOutput: { output: shown.text, truncated: false, exitCode: 0, background: id },
	};
}

const STOPPED_BY_AGENT = "was stopped by the agent";

/** The start of `text` that one answer can carry. */
function fit(text: string): string {
	let part = text.slice(0, READ_CHARS);
	let at = -1;
	for (let line = 0; line < READ_LINES; line++) {
		at = part.indexOf("\n", at + 1);
		if (at === -1) break;
	}
	if (at !== -1) part = part.slice(0, at + 1);
	while (Buffer.byteLength(part) > READ_BYTES) part = part.slice(0, Math.floor((part.length * READ_BYTES) / Buffer.byteLength(part)) - 1);
	return part;
}

/** The end of `text` that one answer can carry. */
function fitEnd(text: string): string {
	let part = text.slice(-READ_CHARS);
	while (Buffer.byteLength(part) > READ_BYTES) part = part.slice(-(Math.floor((part.length * READ_BYTES) / Buffer.byteLength(part)) - 1));
	return part;
}

/**
 * The output the agent has not been given yet, oldest first, as much of it as one answer can carry, marked as given. `dropped`
 * counts what was printed and lost before it could be read; `waiting` what is still unread after this.
 */
function unread(command: Command): { text: string; dropped: number; waiting: number } {
	// Where the kept output begins, counted from the first character the command printed.
	const first = command.total - command.output.length;
	const dropped = Math.max(0, first - command.read);
	const from = Math.max(command.read, first);
	const part = fit(command.output.slice(from - first));
	command.read = from + part.length;
	return { text: part, dropped, waiting: command.total - command.read };
}

/** How a command stands, in a few words: "running for 3 minutes", "exited with code 1 after 4 seconds". */
function standing(command: Command, now = Date.now()): string {
	if (command.ended === undefined) return `running for ${elapsed(now - command.startedAt)}`;
	return command.child === undefined ? command.ended.how : `${command.ended.how} after ${elapsed(command.ended.at - command.startedAt)}`;
}

const count = (n: number) => `${n.toLocaleString("en-US")} character${n === 1 ? "" : "s"}`;

/**
 * A command and the output of it that is kept, from character `from` on (counted from the first character it printed),
 * for the person to read in the app. At most the last `KEEP_CHARS`: the buffer holds up to twice that before it is cut.
 * It leaves what counts as read for the agent as it was: the person looking does not pass anything over for the agent.
 */
function forThePerson(command: Command, from: number) {
	const first = command.total - command.output.length;
	const asked = Math.min(from, command.total);
	let begin = Math.max(asked, first, command.total - KEEP_CHARS);
	// Never half a character: the kept output can begin in the middle of one written as two UTF-16 units, and the app's
	// JSON reader refuses the lone half.
	const unit = command.output.charCodeAt(begin - first);
	if (unit >= 0xdc00 && unit <= 0xdfff) begin += 1;
	const library = engine?.library().conversations ?? {};
	return {
		id: command.id,
		conversationId: command.conversationId,
		rootConversationId: library[String(command.conversationId)]?.parent ?? command.conversationId,
		command: command.command,
		cwd: command.cwd,
		startedAt: command.startedAt,
		running: isRunning(command),
		stopping: isRunning(command) && command.stopping !== undefined,
		// How it ended, worded to follow "It": "exited with code 1 after 4 seconds".
		ended: command.ended === undefined ? null : { at: command.ended.at, how: standing(command), failed: command.ended.failed },
		// False for a command an engine that stopped had started: its output went with that engine.
		kept: command.child !== undefined,
		total: command.total,
		from: begin,
		// Printed after `from` but let go before it could be shown.
		dropped: Math.max(0, begin - asked),
		output: command.output.slice(begin - first),
	};
}

/** What the agent is told of its conversation's background commands at each request: what is running, and what ended. */
function describeCommands(conversationId: number): string | undefined {
	const own = [...commands.values()].filter((command) => command.conversationId === conversationId).sort((a, b) => a.startedAt - b.startedAt);
	const running = own.filter(isRunning);
	const ended = own.filter((command) => !isRunning(command)).slice(-ENDED_TOLD);
	if (running.length === 0 && ended.length === 0) return undefined;
	// No running times and no counts of output: the section is sent again whenever its words change.
	return [
		"Commands you started in the background in this conversation, with bash and `background: true`. They are not stopped when you finish answering. The background tool reads their output (action read), lists them (list) and stops them (stop).",
		...running.map((command) => `- ${command.id}: \`${commandLine(command.command)}\`, running since ${clock(command.startedAt)}.`),
		...ended.map((command) => `- ${command.id}: \`${commandLine(command.command)}\` is over: it ${command.ended!.how}${command.child === undefined ? "" : `, at ${clock(command.ended!.at)}`}.`),
	].join("\n");
}

export const background: Feature = (_host, running) => {
	engine = running;

	const find = (given: string | undefined, conversationId: number): Command | string => {
		const own = [...commands.values()].filter((command) => command.conversationId === conversationId);
		const known = own.length === 0 ? "This conversation has no background commands." : `This conversation's background commands: ${own.map((command) => command.id).join(", ")}.`;
		if (given === undefined || given.trim() === "") return `Give the command's \`id\`, such as "bg-1". ${known}`;
		const command = commands.get(idOf(given));
		if (command === undefined || command.conversationId !== conversationId) {
			return `There is no background command ${idOf(given)} in this conversation. ${known} A command that ended long ago, or before pi² was last restarted, is no longer kept.`;
		}
		return command;
	};

	const tool = defineTool({
		name: "background",
		description:
			"Work with the commands you started in the background in this conversation, with bash and `background: true`. Actions:\n" +
			"- list: each one's id, its command, whether it is running or how it ended, and how much of its output you have not read.\n" +
			`- read: what \`id\` has printed since you last read it, standard output and errors together, and whether it is still running. With \`wait\`, when there is nothing new it waits up to that many seconds (${MAX_WAIT_SECONDS} at most) for more output or for the command to end. With \`tail\`, it gives the last \`tail\` lines instead, read or not, and what counts as read stays as it was.\n` +
			"- stop: stop `id` and everything it started, and give what it printed since you last read it.\n" +
			`Only the last ${KEEP_CHARS / 1024} KB a command printed is kept, and one read gives at most ${READ_CHARS.toLocaleString("en-US")} characters or ${READ_LINES.toLocaleString("en-US")} lines: read again for the rest.`,
		parameters: obj({
			action: str({ description: "list, read or stop" }),
			id: opt(str({ description: 'For read and stop: the command\'s id, such as "bg-1"' })),
			wait: opt(num({ description: `For read: seconds to wait for new output when there is none, up to ${MAX_WAIT_SECONDS}` })),
			tail: opt(int({ description: "For read: give the last this many lines, read or not, instead of what is new" })),
		}),
		// Listing and reading change nothing that outlasts the engine, and stopping what is stopped changes nothing.
		replay: "safe",
		execute: async (args, api, context) => {
			const conversationId = api.conversationId as unknown as number;
			const action = args.action.trim().toLowerCase();
			if (action === "list") {
				const own = [...commands.values()].filter((command) => command.conversationId === conversationId).sort((a, b) => a.startedAt - b.startedAt);
				if (own.length === 0) return { output: text("This conversation has no background commands. Start one with bash and `background: true`."), details: { action, count: 0, running: 0 } };
				const lines = own.map((command) => {
					const waiting = command.total - Math.max(command.read, command.total - command.output.length);
					return `- ${command.id}: \`${commandLine(command.command)}\`: ${standing(command)}; ${waiting === 0 ? "no unread output" : `${count(waiting)} of output unread`}.`;
				});
				return { output: text(["Background commands of this conversation:", ...lines].join("\n")), details: { action, count: own.length, running: own.filter(isRunning).length } };
			}
			if (action !== "read" && action !== "stop") return fail(`Unknown action "${args.action}". Use list, read or stop.`);
			const command = find(args.id, conversationId);
			if (typeof command === "string") return fail(command);
			const details = () => ({ action, id: command.id, command: command.command, status: isRunning(command) ? "running" : "ended" });

			if (action === "stop") {
				const was = isRunning(command);
				if (was) await awaitWithContext(stop(command, STOPPED_BY_AGENT), context);
				const rest = unread(command);
				const lead = was
					? `Stopped ${command.id} (\`${commandLine(command.command)}\`) and everything it started, after ${elapsed((command.ended?.at ?? Date.now()) - command.startedAt)}.`
					: `${command.id} (\`${commandLine(command.command)}\`) was already over: it ${standing(command)}.`;
				return { output: text(`${lead}${rest.text === "" ? "" : `\nWhat it printed since you last read it:\n${rest.text}`}${rest.waiting > 0 ? `\n[${count(rest.waiting)} more: read again for them.]` : ""}`), details: details() };
			}

			if (args.wait !== undefined && !(Number.isFinite(args.wait) && args.wait >= 0)) return fail("`wait` must be a number of seconds, 0 or more.");
			if (args.tail !== undefined && !(Number.isInteger(args.tail) && args.tail >= 1)) return fail("`tail` must be a whole number of lines, 1 or more.");
			const head = () => `${command.id} (\`${commandLine(command.command)}\`): ${standing(command)}.`;
			if (args.tail !== undefined) {
				const lines = command.output.replace(/\n$/, "").split("\n");
				// A second look: what counts as read stays as it was, so nothing new is passed over by looking at the end.
				const last = fitEnd(lines.slice(-Math.min(args.tail, READ_LINES)).join("\n"));
				const all = lines.length <= args.tail && command.total === command.output.length && last.length === lines.join("\n").length;
				const which = all ? "All it has printed" : `Its last ${args.tail === 1 ? "line" : `${args.tail} lines`}`;
				return { output: text(command.output === "" ? `${head()} It has printed nothing${command.child === undefined ? " that was kept" : ""}.` : `${head()} ${which}:\n${last}`), details: details() };
			}
			const nothingNew = () => command.total - Math.max(command.read, command.total - command.output.length) === 0;
			if (nothingNew() && isRunning(command) && (args.wait ?? 0) > 0) {
				// Until it prints, ends, the time is up, or the run is stopped.
				let waiter: (() => void) | undefined;
				let timer: ReturnType<typeof setTimeout> | undefined;
				try {
					await awaitWithContext(
						new Promise<void>((resolve) => {
							waiter = resolve;
							command.waiters.add(resolve);
							timer = setTimeout(resolve, Math.min(args.wait!, MAX_WAIT_SECONDS) * 1000);
						}),
						context,
					);
				} finally {
					clearTimeout(timer);
					if (waiter !== undefined) command.waiters.delete(waiter);
				}
			}
			const part = unread(command);
			const lines = [head()];
			if (command.child === undefined) lines.push("Its output was in the engine that stopped, and was not kept.");
			else {
				if (part.dropped > 0) lines.push(`[${count(part.dropped)} it printed before this were not kept: only the last ${KEEP_CHARS / 1024} KB is.]`);
				if (part.text === "") lines.push(command.total === 0 ? "It has printed nothing." : "Nothing new since you last read it.");
				else lines.push(part.text);
				if (part.waiting > 0) lines.push(`[${count(part.waiting)} more: read again for them.]`);
			}
			return { output: text(lines.join("\n")), details: details() };
		},
	});

	return {
		tools: [tool],
		// Wherever there is a shell: starting one is a `bash` call.
		toolNames: (access) => (access === "ask" || access === "full" ? ["background"] : []),
		sections: [
			section("background_commands", (input) => {
				if (!input.agent.tools.some((offered) => offered.name === "background")) return undefined;
				return describeCommands(input.conversationId as unknown as number);
			}),
		],
		start: async () => {
			// Commands the last engine had running. A clean stop stopped them; an engine that died outright (SIGKILL, a
			// crash) did not, so they may still be running: stop each, if it is provably the same one, and otherwise leave it
			// alone and say so. Either way their output went with that engine.
			const doc = await running.harness().snapshot(Background, running.context());
			const left: Left[] = JSON.parse(JSON.stringify(Object.values(doc?.running ?? {})));
			for (const record of left) {
				// Without its process on record, the engine stopped in the instant between starting it and noting it down.
				const found: LeftOver | "unknown" = record.process === undefined ? "unknown" : await stopLeftOver(record.process).catch(() => "unsure" as const);
				running.log(logName(record.id, record.conversationId), "left by the last engine", found === "unknown" ? leftOverLog.unsure : leftOverLog[found]);
				const how =
					found === "stopped"
						? "was left running when pi²’s engine stopped, and was stopped when the engine started again"
						: found === "partly"
							? `was left running when pi²’s engine stopped. What pi² could tell it had started was stopped when the engine started again; something else in its process group (${record.process?.group}) may still be running, and was left alone because pi² could not be sure it is the same`
							: found === "unsure"
								? `was cut off when pi²’s engine stopped. Something it started may still be running (process group ${record.process?.group}), and was left alone because pi² could not be sure it is the same`
								: found === "unknown"
									? "was cut off when pi²’s engine stopped, just as it was being started. It may still be running: pi² had not yet noted its process, and so left it alone"
									: "ended when pi²’s engine stopped";
				const library = running.library().conversations;
				const root = library[String(record.conversationId)]?.parent ?? record.conversationId;
				leftBehind.push({
					id: record.id,
					conversationId: record.conversationId,
					rootConversationId: root,
					title: library[String(root)]?.title ?? "",
					command: record.command,
					outcome: found,
					group: signallable(record.process?.group) ? record.process.group : null,
				});
				const { process: _process, ...known } = record;
				const command: Command = { ...known, output: "", total: 0, read: 0, ended: { at: Date.now(), how, failed: true }, settled: Promise.resolve(), waiters: new Set() };
				commands.set(record.id, command);
				await note(command, how);
			}
			if (left.length > 0) await save((stored) => void (stored.running = {}));
			prune();
			// Should the engine exit without its clean stop (an error it did not catch), nothing is left running unseen.
			process.once("exit", () => {
				for (const command of commands.values()) if (isRunning(command) && command.child !== undefined) signalGroup(command.child, "SIGKILL");
			});
		},
		// A clean stop of the engine stops them: SIGTERM, a moment, then SIGKILL. Their records stay, and the next engine
		// writes their end into their conversations.
		stopping: async () => {
			shuttingDown = true;
			const live = [...commands.values()].filter(isRunning);
			if (live.length === 0) return;
			const pause = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms).unref());
			const ended = Promise.all(live.map((command) => stop(command, "was stopped when pi²’s engine stopped", SHUTDOWN_GRACE_MS)));
			// Everything in their groups, listed while the grace runs. A command's own first process can end at SIGTERM and
			// be reaped at once while what it started ignores it (`server & wait`); its group can then no longer be signalled
			// through it, and the SIGKILL that `stopMembers` arranges for later would come after the engine is gone (#199).
			// So whatever of this list is still there, and still the same process, is ended here, before the engine exits. A
			// group's number is not given to another while it has members, so a member listed under it is the command's own.
			const groups = new Set(live.map((command) => command.child?.pid).filter(signallable));
			const listing = processes()
				.then((listed): [number, Listed][] => {
					const own = listed.get(process.pid)?.group;
					return own === undefined ? [] : [...listed].filter(([pid, each]) => signallable(pid) && each.group !== own && groups.has(each.group));
				})
				.catch((): [number, Listed][] => []);
			await Promise.race([ended, pause(SHUTDOWN_GRACE_MS)]);
			for (const command of live) if (command.child !== undefined) signalGroup(command.child, "SIGKILL");
			// Only groups whose first process is gone: the others were just ended whole through it.
			const leaderless = new Set(live.filter((command) => command.child !== undefined && reaped(command.child)).map((command) => command.child!.pid));
			await killRemaining((await listing).filter(([, each]) => leaderless.has(each.group)));
			// A moment for their ends to come in, so engine.log has them.
			await Promise.race([ended, pause(500)]);
		},
		recovery: () => ({ background: leftBehind }),
		greeting: () => [event()],
		// Archiving or deleting a conversation stops what it left running, and what its sub-chats did.
		putAwayChanged: () => {
			for (const command of commands.values()) {
				const reason = putAway(command.conversationId);
				if (reason === undefined) continue;
				if (isRunning(command)) void stop(command, `was stopped because the conversation was ${reason}`);
			}
		},
		handlers: {
			/**
			 * The person reads a command's output, from Activity or the conversation: what is kept from `from` on. With `wait`
			 * (seconds), a request that finds nothing new waits for more output or the end, up to `APP_WAIT_SECONDS`, so the
			 * app sees output as it arrives without asking over and over.
			 */
			"background.output": async (params) => {
				const command = typeof params.id === "string" ? commands.get(idOf(params.id)) : undefined;
				if (command === undefined) {
					throw new Error(`pi² no longer has this command's output. While its engine runs, it keeps the output of the commands running and of the last ${ENDED_KEPT} that ended.`);
				}
				const from = typeof params.from === "number" && Number.isFinite(params.from) && params.from > 0 ? Math.floor(params.from) : 0;
				const wait = typeof params.wait === "number" && Number.isFinite(params.wait) && params.wait > 0 ? Math.min(params.wait, APP_WAIT_SECONDS) : 0;
				if (wait > 0 && isRunning(command) && command.total <= from) {
					let waiter: (() => void) | undefined;
					let timer: ReturnType<typeof setTimeout> | undefined;
					try {
						await new Promise<void>((resolve) => {
							waiter = resolve;
							command.waiters.add(resolve);
							timer = setTimeout(resolve, wait * 1000);
							timer.unref();
						});
					} finally {
						clearTimeout(timer);
						if (waiter !== undefined) command.waiters.delete(waiter);
					}
				}
				return forThePerson(command, from);
			},
			/** The person stops one from Activity. */
			"background.stop": async (params) => {
				const command = typeof params.id === "string" ? commands.get(params.id) : undefined;
				if (command === undefined || !isRunning(command)) throw new Error("That command is no longer running");
				await stop(command, "was stopped by the person");
				return {};
			},
		},
	};
};
