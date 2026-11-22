// Running a model on this Mac (#291, part of #173): the engine that serves it is started when a conversation that uses
// the model is opened or set working, shared by every conversation that uses it, and stopped a minute after the last one
// stops using it. See docs/local-models-running.md.
//
// A conversation uses a model on this Mac while its model is that one and it is open in one of the app's panes (the app
// says which with `conversations.shown`), or while it has work running: a run, a sub-chat's or a scheduled one. It stops
// counting when its pane closes or shows another conversation, when it is archived or deleted, or when its model is
// changed. An app that quits closes its panes; work an agent is doing still counts.
//
// The server is started the way the engine starts everything it leaves to run on its own (processes.ts): in a process
// group of its own, with the run's marker in its environment, its group and start noted in a session document. A clean
// stop of the engine stops it; one left by an engine that died is stopped by the next, if it is provably the same. What
// is particular to the real engine (its command line, how it says it is ready) is in localengine.ts.
//
// A request for the model (providers.ts) waits here until the server is ready, so a message sent while it loads is
// answered once it has loaded, and one sent after it was stopped starts it again.

import { type ChildProcess, spawn } from "node:child_process";
import { randomBytes } from "node:crypto";
import { closeSync, mkdirSync, openSync, readSync, rmSync, statSync } from "node:fs";
import { createServer } from "node:net";
import { homedir } from "node:os";
import { join } from "node:path";
import type { AssistantMessage } from "@earendil-works/pi-ai";
import { AgentDoc, type ConversationId, defineDoc } from "@earendil-works/pi-durable";
import { isPutAway } from "./archive.ts";
import { commandEnvironment } from "./environment.ts";
import type { Engine, Feature } from "./features.ts";
import { execFileOffThread } from "./offthread.ts";
import { type EngineRecipe, fileName, type LocalModel, type LocalSetup, localSetupReader, STRATA } from "./localengine.ts";
import { refusalOf } from "./limitwait.ts";
import { localChanged } from "./localmodels.ts";
import { forgetRun, killLater, killRemaining, type Listed, leftOverLog, newRun, noteProcess, processes, RUN_VARIABLE, type RunProcess, signallable, stopLeftOver } from "./processes.ts";
import { LOCAL_PROVIDER, type LocalLease } from "./providers.ts";

/** How long a model nobody uses stays loaded: switching between two conversations does not unload and load it again. */
const GRACE_MS = (() => {
	const given = Number(process.env.PI2_LOCAL_GRACE_SECONDS);
	return Number.isFinite(given) && given >= 0 ? given * 1000 : 60_000;
})();
/** How long loading may take before pi² gives up on it. A large model read from disk for the first time takes minutes. */
const LOAD_LIMIT_MS = 20 * 60_000;
/** After SIGTERM, how long the server gets to end before SIGKILL; at a clean stop of the engine, less, as for commands. */
const STOP_GRACE_MS = 5_000;
const SHUTDOWN_GRACE_MS = 1_500;
/** How often a loading server is asked whether it is ready, and its log read for progress. */
const POLL_MS = 250;
/** How often the memory of a running server is looked at again. */
const MEMORY_MS = 10_000;

export const LOCAL_RETRY_ENTRY = "pi2.localRetry";
const LOCAL_RETRY_NOTICE = "The model on this Mac stopped and was started again. Carrying on.";
const RETRY_DELAYS = [2_000, 10_000, 30_000];
// Only tests shorten or hold the durable sleep; its normal backoff does not depend on the model's settings.
const retryDelay = (ms: number): number => {
	const testDelay = Number(process.env.PI2_LOCAL_RUN_RETRY_MS);
	return Number.isFinite(testDelay) && testDelay >= 0 ? testDelay : ms;
};
const ENGINE_STOPPED = /\bthe engine stopped unexpectedly \(exit code -?\d+\); the next request restarts it\b/i;
const CONNECTION_DROPPED = /^(?:connection (?:error|refused|lost)|fetch failed|terminated|stream ended without finish_reason|socket hang up|other side closed|ECONN(?:RESET|REFUSED))\b/i;

/** Strata's server may still be running after its engine stops; asking it again starts the engine. */
export function retryLocalEngine(message: AssistantMessage | undefined, count: number, home: string) {
	if (message?.provider !== LOCAL_PROVIDER || message.stopReason !== "error") return undefined;
	const error = message.errorMessage ?? "";
	if (!ENGINE_STOPPED.test(error) && (refusalOf(message) !== undefined || !CONNECTION_DROPPED.test(error))) return undefined;
	const delay = RETRY_DELAYS[count];
	if (delay !== undefined) {
		return { waitMs: retryDelay(delay), spent: 0, localRetries: count + 1, notice: { kind: LOCAL_RETRY_ENTRY, data: { text: LOCAL_RETRY_NOTICE } } };
	}
	const log = join(home, "local", "logs", `${fileName(message.model)}.log`);
	message.errorMessage = `${error}\n\nWhat Strata printed is in its log, ${tilde(log)}.`;
	return { waitMs: false as const, spent: 0 };
}

/** A server as the session document records it, for the engine that starts after this one should this one die. */
type Left = { model: string; startedAt: number; process?: RunProcess };
const LocalRuns = defineDoc<{ running: Record<string, Left> }>({
	kind: "pi2.local",
	version: 1,
	scope: "session",
	initial: () => ({ running: {} }),
	checkpointWhen: () => true,
});

type Status = "starting" | "ready" | "stopping";

type Server = {
	model: LocalModel;
	status: Status;
	startedAt: number;
	readyAt?: number;
	/** How far loading has got, 0 to 1, when the engine says. */
	progress?: number;
	/** What the engine last said it is doing while it loads ("mapping the experts"), when it says. */
	stage?: string;
	port: number;
	key: string;
	log: string;
	child?: ChildProcess;
	/** The run's marker, whose file goes once it is over (processes.ts). */
	marker?: string;
	/** Settles once it is ready to be asked, or fails with why it cannot be. */
	ready: Promise<void>;
	/** Fails `ready`, while it has not settled. */
	refuse: (error: Error) => void;
	/** Resolves once its process has exited (at once if it never started). */
	gone: Promise<void>;
	/** Why it is being stopped, worded to follow its name: "was stopped by hand". */
	stopping?: string;
	/** Ends the requests on it when it is stopped by hand or by pi²: with a crash they end on their own. */
	abort: AbortController;
	/** The conversations using it, at the last look. */
	users: Set<number>;
	/** Requests waiting for it or being answered by it. */
	requests: number;
	/** When it stops for want of anyone using it, while that is counting down. */
	stopsAt?: number;
	timer?: ReturnType<typeof setTimeout>;
	/** Bytes its processes hold in memory, at the last look: its own and those it started, in whatever group. */
	memory?: number;
	/**
	 * What it started, at any depth and in any process group, at the last look: Strata's server starts the engine in a
	 * group of its own (#290), which a signal to the server's group does not reach. Whatever of it is still the same
	 * process once the server has gone is ended with it.
	 */
	family: [number, Listed][];
	/** Its process is on record, for the next engine should this one die. */
	recorded?: boolean;
	/** The look at its family taken as its stop began. */
	listed?: Promise<void>;
};

/** How a model's last server ended, for the conversation and Settings to say. */
type Ended = { at: number; how: string; failed: boolean; lines: string[]; log: string };

/** The servers running, by model id. One that is stopping stays until it has exited, unless another has taken its place. */
const servers = new Map<string, Server>();
/** Every server whose process may still be running, the ones that gave their place to another included. */
const live = new Set<Server>();
const ended = new Map<string, Ended>();
/**
 * Models not to start again on their own: one stopped by hand, or that failed or crashed, until a conversation starts
 * using it that was not before, or a message is sent to it.
 */
const heldBack = new Set<string>();
/** The conversations using each model at the last look. */
let lastUsers = new Map<string, Set<number>>();
/** Conversations with work running, as the engine last said. */
let working: ReadonlySet<number> = new Set();
/** Conversations whose state says something about a model on this Mac: sent again when that changes. */
const watching = new Set<number>();
let shuttingDown = false;
let engine: Engine | undefined;
const recipe: EngineRecipe = STRATA;
let readSetup: () => LocalSetup = () => ({ engine: null, models: [] });

const tilde = (path: string) => (path.startsWith(`${homedir()}/`) ? `~${path.slice(homedir().length)}` : path);


/** A port on 127.0.0.1 that nothing listens on right now. */
function freePort(): Promise<number> {
	return new Promise((resolve, reject) => {
		const probe = createServer();
		probe.once("error", reject);
		probe.listen(0, "127.0.0.1", () => {
			const address = probe.address();
			probe.close(() => (typeof address === "object" && address !== null ? resolve(address.port) : reject(new Error("no port"))));
		});
	});
}

/** The last lines of a log, at most `count`, from its last 8 KB. */
function lastLines(path: string, count = 6): string[] {
	try {
		const size = statSync(path).size;
		const length = Math.min(size, 8192);
		const buffer = Buffer.alloc(length);
		const fd = openSync(path, "r");
		try {
			readSync(fd, buffer, 0, length, size - length);
		} finally {
			closeSync(fd);
		}
		return buffer.toString("utf8").split(/\r?\n|\r/).map((line) => line.trimEnd()).filter((line) => line.trim() !== "").slice(-count);
	} catch {
		return [];
	}
}

/** A process as `ps` lists it here: its parent, group, resident memory in KB and start, as `processes()` reads it. */
type Row = { ppid: number; group: number; rss: number; start: string };

/** Every process, by pid, from one reading of `ps`. Those that have ended and wait only to be reaped are left out. */
function table(): Promise<Map<number, Row>> {
	return new Promise((resolve, reject) => {
		execFileOffThread("/bin/ps", ["-A", "-o", "pid=,ppid=,pgid=,rss=,stat=,lstart="], { timeout: 10_000, maxBuffer: 32 * 1024 * 1024, env: { ...process.env, LC_ALL: "C", TZ: "UTC" } }, (error, stdout) => {
			if (error) return reject(error);
			const rows = new Map<number, Row>();
			for (const line of String(stdout).split("\n")) {
				const match = /^\s*(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\S+)\s+(\S.*?)\s*$/.exec(line);
				if (match && !match[5]!.startsWith("Z")) rows.set(Number(match[1]), { ppid: Number(match[2]), group: Number(match[3]), rss: Number(match[4]), start: match[6]!.replace(/\s+/g, " ") });
			}
			resolve(rows);
		});
	});
}

/**
 * The processes `root` started, and those they started, whatever their group, from one listing: a process's parent is
 * the one that started it, or launchd's once that has ended, so what an ended process started is no longer found here.
 */
function descendants(rows: Map<number, Row>, root: number): [number, Listed][] {
	const children = new Map<number, number[]>();
	for (const [pid, row] of rows) {
		if (!children.has(row.ppid)) children.set(row.ppid, []);
		children.get(row.ppid)!.push(pid);
	}
	const found: [number, Listed][] = [];
	const queue = [...(children.get(root) ?? [])];
	while (queue.length > 0) {
		const pid = queue.shift()!;
		const row = rows.get(pid)!;
		if (!signallable(pid) || found.some(([seen]) => seen === pid)) continue;
		found.push([pid, { group: row.group, start: row.start }]);
		queue.push(...(children.get(pid) ?? []));
	}
	return found;
}

/** Look again at a server's family and memory, while its first process is known not to have been reaped. */
async function look(server: Server): Promise<void> {
	const pid = server.child?.pid;
	if (pid === undefined || server.child?.exitCode !== null || server.child?.signalCode !== null) return;
	const rows = await table().catch(() => undefined);
	if (rows === undefined || !live.has(server) || server.child.exitCode !== null || server.child.signalCode !== null) return;
	const family = descendants(rows, pid);
	// Only the members still listed: one that ended since the last look is not ended again by its number.
	server.family = [...new Map([...server.family.filter(([member]) => rows.has(member)), ...family]).entries()];
	const memory = [pid, ...family.map(([member]) => member)].reduce((sum, member) => sum + (rows.get(member)?.rss ?? 0), 0) * 1024;
	if (memory !== server.memory && server.status === "ready") {
		server.memory = memory;
		announce();
	}
}

// ---- What the app is told

/** A server as Activity, the menu bar and `local.status` show it. */
function describe(server: Server) {
	return {
		id: server.model.id,
		name: server.model.name,
		status: server.status,
		startedAt: server.startedAt,
		readyAt: server.readyAt ?? null,
		progress: server.progress ?? null,
		stage: server.stage ?? null,
		memory: server.memory ?? null,
		pid: server.child?.pid ?? null,
		users: [...server.users].sort((a, b) => a - b),
		stopsAt: server.stopsAt ?? null,
		log: server.log,
		recorded: server.recorded === true,
	};
}

/** The running half of `local.status`: the servers running, and how each model's last one ended. */
export function runningStatus() {
	return {
		running: [...servers.values()].map(describe),
		ended: Object.fromEntries([...ended].map(([id, end]) => [id, end])),
	};
}

/** What a conversation using `modelId` is told of it. */
function forConversation(modelId: string) {
	const server = servers.get(modelId);
	const model = server?.model ?? readSetup().models.find((each) => each.id === modelId);
	const name = model?.name ?? modelId;
	if (server !== undefined) {
		return { model: modelId, name, status: server.status, since: server.status === "ready" ? (server.readyAt ?? server.startedAt) : server.startedAt, progress: server.progress ?? null, stage: server.stage ?? null, error: null, lines: [], log: server.log };
	}
	const end = ended.get(modelId);
	if (end?.failed === true) return { model: modelId, name, status: "failed", since: end.at, progress: null, stage: null, error: end.how, lines: end.lines, log: end.log };
	return { model: modelId, name, status: "stopped", since: end?.at ?? null, progress: null, stage: null, error: null, lines: [], log: end?.log ?? null };
}

let announced: ReturnType<typeof setTimeout> | undefined;
/** Tell the apps: the `local.running` event, and the state of every conversation that shows a model on this Mac. */
function announce(): void {
	if (engine === undefined) return;
	clearTimeout(announced);
	announced = undefined;
	engine.broadcast({ event: "local.running", ...runningStatus() });
	// And `local`, the whole of `local.status`, which has this half too (localmodels.ts).
	localChanged();
	for (const id of watching) engine.stateChanged(id);
}
/** The same, at most twice a second: for progress, which an engine may print many times a second. */
function announceSoon(): void {
	announced ??= setTimeout(announce, 500);
}

// ---- Keeping the record

let saving: Promise<void> = Promise.resolve();
function save(edit: (doc: { running: Record<string, Left> }) => void): Promise<void> {
	const host = engine;
	if (host === undefined || shuttingDown) return saving;
	saving = saving
		.then(() => host.harness().commit(async (tx) => edit(await tx.doc(LocalRuns)), host.context()))
		.catch((error) => host.log("could not keep the record of a model on this Mac:", error instanceof Error ? error.message : error));
	return saving;
}

// ---- Starting and stopping

const notInstalled = () => `The engine that runs models on this Mac is not installed. Get it in Settings › Providers, or choose another model.`;
const notSetUp = (id: string) => `${id} is not set up on this Mac. Set it up in Settings › Providers, or choose another model.`;

/**
 * Start the server for `modelId`, or give the one already starting or running. One that is stopping is let finish, and
 * a new one starts once it has gone. Throws at once when the model or the engine is not set up.
 */
function start(modelId: string): Server {
	const current = servers.get(modelId);
	if (current !== undefined && current.status !== "stopping") return current;
	const setup = readSetup();
	const model = setup.models.find((each) => each.id === modelId);
	if (model === undefined) throw new Error(notSetUp(modelId));
	if (setup.engine === null) throw new Error(notInstalled());
	const missing = recipe.missing?.(setup.engine, model);
	if (missing !== undefined) throw new Error(missing);
	const host = engine!;
	const folder = join(host.home, "local", "logs");
	let markReady = () => {};
	let markFailed: (error: Error) => void = () => {};
	let markGone = () => {};
	const server: Server = {
		refuse: (error) => markFailed(error),
		model,
		status: "starting",
		startedAt: Date.now(),
		port: 0,
		key: randomBytes(24).toString("hex"),
		log: join(folder, `${fileName(model.id)}.log`),
		ready: new Promise<void>((resolve, reject) => ((markReady = resolve), (markFailed = reject))),
		gone: new Promise<void>((resolve) => (markGone = resolve)),
		abort: new AbortController(),
		users: lastUsers.get(modelId) ?? new Set(),
		requests: 0,
		family: [],
	};
	server.ready.catch(() => {});
	servers.set(modelId, server);
	live.add(server);
	ended.delete(modelId);
	heldBack.delete(modelId);
	host.log(`starting ${model.id} on this Mac with ${recipe.name}`);
	announce();

	/** It could not be made ready: say why, stop what there is of it, and let what waits for it know. */
	const fail = (how: string) => {
		if (server.status !== "starting") return;
		const lines = lastLines(server.log);
		const message = `${model.name} could not be started on this Mac: ${how}. What ${recipe.name} printed is in its log, ${tilde(server.log)}.`;
		ended.set(modelId, { at: Date.now(), how, failed: true, lines, log: server.log });
		heldBack.add(modelId);
		host.log(`${model.id} could not be started: ${how}`);
		markFailed(new Error(message));
		void stop(server, how);
	};
	/** Its process has ended, or never started: it is gone. */
	const finish = () => {
		clearTimeout(server.timer);
		live.delete(server);
		if (servers.get(modelId) === server) servers.delete(modelId);
		void save((doc) => void delete doc.running[modelId]).then(() => forgetRun(server.marker));
		markGone();
		announce();
		evaluateSoon();
	};

	void (async () => {
		const previous = current;
		if (previous !== undefined) await previous.gone;
		if (server.stopping !== undefined) return finish();
		mkdirSync(folder, { recursive: true });
		server.port = await freePort();
		const { program, args, env, unset } = recipe.command(setup.engine!, model, server.port, host.home);
		// The run's marker in its environment, and its file open as the engine's other runs have it, which tell what it
		// starts apart after a crash (processes.ts); what it prints goes to its log.
		const run = newRun();
		const marker = run.marker;
		server.marker = marker;
		// A new file, not the old one emptied: a server of this model still ending (one the last engine left, being
		// stopped) keeps writing to the old one, and its last lines must not land in this run's log.
		rmSync(server.log, { force: true });
		const output = openSync(server.log, "w");
		let child: ChildProcess;
		try {
			child = spawn(program, args, {
				env: Object.fromEntries(
					Object.entries(commandEnvironment({ ...env, [RUN_VARIABLE]: marker, ...(recipe.keyVariable === null ? {} : { [recipe.keyVariable]: server.key }) })).filter(([name]) => !unset?.includes(name)),
				),
				detached: true,
				stdio: ["ignore", output, output, ...(run.stdio as unknown[]).slice(3)] as never,
			});
		} finally {
			closeSync(output);
		}
		server.child = child;
		// A program that cannot be run at all (not there, not executable) has an error and no exit.
		child.once("error", (error) => {
			if (child.pid !== undefined) return;
			fail(`${recipe.name} could not be run (${error.message})`);
			finish();
		});
		child.once("exit", (code, signal) => {
			const how = code !== null ? `exited with code ${code}` : `was ended by ${signal ?? "a signal"}`;
			// What it left in its group goes with it, and what it started in groups of their own, once it has had the
			// moment it takes to end them itself.
			if (signallable(child.pid)) void sweep(child.pid);
			if (server.family.length > 0) killLater(server.family, STOP_GRACE_MS);
			if (server.status === "starting") fail(`${recipe.name} ${how} before the model was loaded`);
			else if (server.stopping === undefined) {
				// It was ready and nobody stopped it: it crashed. The requests on it end on their own; the next one starts it again.
				ended.set(modelId, { at: Date.now(), how: `${recipe.name} stopped unexpectedly: it ${how}`, failed: true, lines: lastLines(server.log), log: server.log });
				heldBack.add(modelId);
				host.log(`${model.id} stopped unexpectedly: ${recipe.name} ${how}`);
			} else {
				if (ended.get(modelId)?.failed !== true) ended.set(modelId, { at: Date.now(), how: server.stopping, failed: false, lines: [], log: server.log });
				host.log(`${model.id} ${server.stopping}`);
			}
			finish();
		});
		void save((doc) => void (doc.running[modelId] = { model: modelId, startedAt: server.startedAt }));
		void noteProcess(child, marker)
			.then(async (noted) => {
				if (noted === undefined) return;
				await save((doc) => {
					const record = doc.running[modelId];
					if (record !== undefined && live.has(server)) record.process = noted;
				});
				server.recorded = true;
				announce();
			})
			.catch((error) => host.log(`could not note the process of ${model.id}:`, error instanceof Error ? error.message : error));

		// Ready once the engine answers that it is; how far it has got, from what it prints meanwhile.
		const base = `http://127.0.0.1:${server.port}`;
		let read = 0;
		let partial = "";
		while (server.status === "starting") {
			try {
				const size = statSync(server.log).size;
				if (size > read) {
					const buffer = Buffer.alloc(Math.min(size - read, 1024 * 1024));
					const fd = openSync(server.log, "r");
					try {
						read += readSync(fd, buffer, 0, buffer.length, read);
					} finally {
						closeSync(fd);
					}
					const lines = (partial + buffer.toString("utf8")).split(/\r?\n|\r/);
					partial = lines.pop() ?? "";
					for (const line of lines) {
						const progress = recipe.progress(line);
						if (progress !== undefined && progress !== server.progress) {
							server.progress = progress;
							announceSoon();
						}
						const stage = recipe.stage?.(line);
						if (stage !== undefined && stage !== server.stage) {
							server.stage = stage;
							announceSoon();
						}
					}
					void look(server);
				}
			} catch {
				// No log yet.
			}
			const answered = await fetch(`${base}${recipe.readyPath}`, { headers: { authorization: `Bearer ${server.key}` }, signal: AbortSignal.timeout(10_000) }).then(
				(response) => (void response.body?.cancel().catch(() => {}), response.ok),
				() => false,
			);
			if (server.status !== "starting") break;
			if (answered) {
				server.status = "ready";
				server.readyAt = Date.now();
				server.progress = 1;
				server.stage = undefined;
				host.log(`${model.id} is ready on this Mac, after ${Math.round((server.readyAt - server.startedAt) / 1000)} s`);
				markReady();
				announce();
				void watch(server);
				break;
			}
			if (Date.now() - server.startedAt > LOAD_LIMIT_MS) {
				fail(`it had not finished loading after ${LOAD_LIMIT_MS / 60_000} minutes, so pi² stopped it`);
				break;
			}
			await new Promise((resolve) => setTimeout(resolve, POLL_MS));
		}
	})().catch((error) => {
		fail(`pi² could not start ${recipe.name}: ${error instanceof Error ? error.message : String(error)}`);
		if (server.child === undefined) finish();
	});
	return server;
}

/** SIGTERM what is left in a group whose first process has ended, and SIGKILL what of it is still there after a moment. */
async function sweep(group: number): Promise<void> {
	const listed = await processes().catch(() => undefined);
	const own = listed?.get(process.pid)?.group;
	if (listed === undefined || own === undefined || own === group) return;
	const members = [...listed].filter(([pid, each]) => each.group === group && signallable(pid));
	if (members.length === 0) return;
	for (const [pid] of members) {
		try {
			process.kill(pid, "SIGTERM");
		} catch {
			// Gone meanwhile.
		}
	}
	killLater(members, STOP_GRACE_MS);
}

/** Signal a server's whole group, while its first process is not reaped (until then the group's number is its own). */
function signal(server: Server, which: NodeJS.Signals): void {
	const child = server.child;
	if (child === undefined || !signallable(child.pid) || child.exitCode !== null || child.signalCode !== null) return;
	try {
		process.kill(-child.pid, which);
	} catch {
		// Gone already.
	}
}

/** Stop a server, saying why ("was stopped by hand"). Resolves once its process has exited. */
function stop(server: Server, why: string, graceMs = STOP_GRACE_MS): Promise<void> {
	if (server.stopping === undefined) {
		server.stopping = why;
		const wasStarting = server.status === "starting";
		server.status = "stopping";
		clearTimeout(server.timer);
		server.timer = undefined;
		server.stopsAt = undefined;
		// Requests being answered are cut off. Those still waiting for it to load are told why it did not, below.
		if (!wasStarting) server.abort.abort(new Error(`${server.model.name} ${why}. A message to it starts it again.`));
		if (wasStarting) {
			if (!ended.has(server.model.id)) ended.set(server.model.id, { at: Date.now(), how: why, failed: false, lines: [], log: server.log });
			server.refuse(new Error(`${server.model.name} ${why} before it had loaded. A message to it starts it again.`));
		}
		// Its family as it is now, before the signal: what it started in groups of its own, which the signal does not reach.
		server.listed = look(server);
		signal(server, "SIGTERM");
		const later = setTimeout(() => {
			signal(server, "SIGKILL");
			void killRemaining(server.family);
		}, graceMs);
		later.unref();
		void server.gone.then(() => clearTimeout(later));
		announce();
	}
	return server.gone;
}

/** Look at a ready server's family and memory now and then, while it runs. */
async function watch(server: Server): Promise<void> {
	while (live.has(server) && server.status === "ready") {
		await look(server);
		await new Promise((resolve) => setTimeout(resolve, MEMORY_MS).unref());
	}
}

// ---- Who uses it

let evaluating: Promise<void> | undefined;
let again = false;
/** Look again at which conversations use which model, soon, and once however many changes come together. */
function evaluateSoon(): void {
	if (engine === undefined || shuttingDown) return;
	if (evaluating !== undefined) {
		again = true;
		return;
	}
	evaluating = (async () => {
		do {
			again = false;
			await evaluate().catch((error) => engine?.log("could not tell which conversations use a model on this Mac:", error instanceof Error ? error.message : error));
		} while (again && !shuttingDown);
	})().finally(() => (evaluating = undefined));
}

/** The model on this Mac a conversation uses now, if its model is one. */
async function modelOf(id: number): Promise<string | undefined> {
	const host = engine!;
	const model = (await host.harness().snapshot(AgentDoc, id as unknown as ConversationId, host.context()))?.model as { provider?: string; modelId?: string } | undefined;
	return model?.provider === LOCAL_PROVIDER && typeof model.modelId === "string" ? model.modelId : undefined;
}

/**
 * Which conversations use each model, and what follows: a model someone has started using is started, unless it was
 * stopped by hand or failed and nobody new has come to it since; one nobody uses stops after the grace period.
 */
async function evaluate(): Promise<void> {
	const host = engine!;
	const library = host.library().conversations;
	const candidates = new Set([...host.shown(), ...working]);
	const using = new Map<string, Set<number>>();
	for (const id of candidates) {
		const meta = library[String(id)];
		if (meta === undefined || isPutAway(meta) || (meta.parent !== undefined && isPutAway(library[String(meta.parent)]))) continue;
		const model = await modelOf(id).catch(() => undefined);
		if (model === undefined) continue;
		if (!using.has(model)) using.set(model, new Set());
		using.get(model)!.add(id);
	}
	if (shuttingDown) return;
	const setup = readSetup();
	let changed = false;
	for (const [model, ids] of using) {
		const before = lastUsers.get(model);
		// Someone new: a model held back after a stop by hand or a failure is started for them.
		if ([...ids].some((id) => !before?.has(id))) heldBack.delete(model);
		const server = servers.get(model);
		if ((server === undefined || server.status === "stopping") && !heldBack.has(model) && setup.engine !== null && setup.models.some((each) => each.id === model)) {
			try {
				start(model);
				changed = true;
			} catch {
				// Not set up after all: a request for it says so.
			}
		}
	}
	for (const server of servers.values()) {
		const id = server.model.id;
		const users = using.get(id) ?? new Set<number>();
		if (users.size !== server.users.size || [...users].some((user) => !server.users.has(user))) changed = true;
		server.users = users;
		if (server.status === "stopping") continue;
		// A model taken out of the list by the downloads piece is not kept running.
		if (!setup.models.some((each) => each.id === id)) {
			void stop(server, "was stopped because it is no longer set up");
			continue;
		}
		if (users.size > 0 || server.requests > 0) {
			if (server.stopsAt !== undefined) changed = true;
			clearTimeout(server.timer);
			server.timer = undefined;
			server.stopsAt = undefined;
		} else if (server.stopsAt === undefined) {
			// Nobody since this look: it stops when the grace period is over, if nobody has come by then.
			server.stopsAt = Date.now() + GRACE_MS;
			server.timer = setTimeout(() => {
				server.timer = undefined;
				evaluateSoon();
			}, GRACE_MS);
			server.timer.unref();
			changed = true;
		} else if (server.timer === undefined && server.stopsAt <= Date.now()) {
			void stop(server, "was stopped because no conversation was using it");
		}
	}
	lastUsers = using;
	if (changed) announce();
}

// ---- Requests for the model (providers.ts)

/**
 * Wait until `modelId` is ready to be asked, starting it if it is not running, and hold it while the request runs: what
 * a request through the `local` provider does first. A message sent to a model stopped by hand starts it again.
 */
async function lease(modelId: string, signal?: AbortSignal): Promise<LocalLease> {
	heldBack.delete(modelId);
	const server = start(modelId);
	server.requests++;
	clearTimeout(server.timer);
	server.timer = undefined;
	if (server.stopsAt !== undefined) {
		server.stopsAt = undefined;
		announce();
	}
	let released = false;
	const release = () => {
		if (released) return;
		released = true;
		server.requests--;
		evaluateSoon();
	};
	try {
		await new Promise<void>((resolve, reject) => {
			if (signal?.aborted) return reject(signal.reason);
			const aborted = () => reject(signal?.reason ?? new Error("The request was stopped"));
			signal?.addEventListener("abort", aborted, { once: true });
			server.abort.signal.addEventListener("abort", () => reject(server.abort.signal.reason), { once: true });
			server.ready.then(resolve, reject).finally(() => signal?.removeEventListener("abort", aborted));
		});
	} catch (error) {
		release();
		throw error;
	}
	return {
		baseUrl: `http://127.0.0.1:${server.port}${recipe.apiPath}`,
		key: server.key,
		signal: signal === undefined ? server.abort.signal : AbortSignal.any([signal, server.abort.signal]),
		done: release,
	};
}

export const localRun: Feature = (_host, running) => {
	engine = running;
	readSetup = localSetupReader(running.home);
	running.providers().connectLocal({ lease, setup: () => readSetup() });
	return {
		start: async () => {
			// Servers the last engine left: a clean stop stopped them, one that died did not.
			const doc = await running.harness().snapshot(LocalRuns, running.context());
			const left: Left[] = JSON.parse(JSON.stringify(Object.values(doc?.running ?? {})));
			for (const record of left) {
				// What its first process started in groups of its own, from the moment that process is proved the same: the
				// signal to its group does not reach them. Strata's server ends them itself when asked to, in a few seconds;
				// whatever of them is still there, and still the same, after that is ended.
				const rows = record.process === undefined ? undefined : await table().catch(() => undefined);
				const leader = record.process === undefined ? undefined : rows?.get(record.process.group);
				const family = rows !== undefined && leader !== undefined && leader.group === record.process!.group && leader.start === record.process!.start ? descendants(rows, record.process!.group) : [];
				const found = record.process === undefined ? "unsure" : await stopLeftOver(record.process).catch(() => "unsure" as const);
				if (family.length > 0) killLater(family, STOP_GRACE_MS);
				running.log(`${record.model} on this Mac, left by the last engine,`, record.process === undefined ? "may still be running: its process had not been noted" : leftOverLog[found]);
			}
			if (left.length > 0) await save((stored) => void (stored.running = {}));
			// Should the engine exit without its clean stop, nothing is left loaded unseen.
			process.once("exit", () => {
				for (const server of live) signal(server, "SIGKILL");
			});
		},
		stopping: async () => {
			shuttingDown = true;
			const all = [...live];
			if (all.length === 0) return;
			const groups = new Set(all.map((server) => server.child?.pid).filter(signallable));
			// Listed while they are asked to end: a server's first process can end at SIGTERM while what it started does not,
			// and its group can then no longer be signalled through it.
			const listing = processes()
				.then((listed): [number, Listed][] => {
					const own = listed.get(process.pid)?.group;
					return own === undefined ? [] : [...listed].filter(([pid, each]) => signallable(pid) && each.group !== own && groups.has(each.group));
				})
				.catch((): [number, Listed][] => []);
			const ends = Promise.all(all.map((server) => stop(server, "was stopped when pi²’s engine stopped", SHUTDOWN_GRACE_MS)));
			await Promise.race([ends, new Promise((resolve) => setTimeout(resolve, SHUTDOWN_GRACE_MS).unref())]);
			for (const server of all) signal(server, "SIGKILL");
			// And what each started in groups of their own: Strata's engine, which its server would have ended had it had time.
			await Promise.all(all.map((server) => server.listed));
			await killRemaining(all.flatMap((server) => server.family));
			const leaderless = new Set(all.filter((server) => server.child !== undefined && (server.child.exitCode !== null || server.child.signalCode !== null)).map((server) => server.child!.pid));
			await killRemaining((await listing).filter(([, each]) => leaderless.has(each.group)));
			// Nothing of them is left for the next engine to look for: their records go, so it does not report them.
			await saving;
			await running
				.harness()
				.commit(async (tx) => void ((await tx.doc(LocalRuns)).running = {}), running.context())
				.then(() => {
					for (const server of all) forgetRun(server.marker);
				})
				.catch((error) => running.log("could not clear the record of the models on this Mac:", error instanceof Error ? error.message : error));
		},
		runsChanged: (now) => {
			working = new Set(now);
			evaluateSoon();
		},
		shownChanged: () => evaluateSoon(),
		modelChanged: () => evaluateSoon(),
		putAwayChanged: () => evaluateSoon(),
		greeting: () => [{ event: "local.running", ...runningStatus() }],
		localStatus: () => runningStatus(),
		state: (view) => {
			const id = view.conversation.id as unknown as number;
			const model = (view.docs["pi.agent"] as { model?: { provider?: string; modelId?: string } } | undefined)?.model;
			if (model?.provider !== LOCAL_PROVIDER || typeof model.modelId !== "string") {
				watching.delete(id);
				return { local: null };
			}
			watching.add(id);
			return { local: forConversation(model.modelId) };
		},
		handlers: {
			/** Start a model now, as Settings' Try it does: answers once it is ready, or with why it could not start. */
			"local.start": async (params) => {
				const id = typeof params.id === "string" ? params.id : "";
				const server = start(id);
				evaluateSoon();
				await server.ready;
				return describe(server);
			},
			/** The person's Stop, in Activity or the menu bar. Conversations using it start it again with their next message. */
			"local.stop": async (params) => {
				const id = typeof params.id === "string" ? params.id : "";
				const server = servers.get(id);
				if (server === undefined || server.status === "stopping") throw new Error("That model is not running");
				heldBack.add(id);
				await stop(server, "was stopped by hand");
				return {};
			},
		},
	};
};
