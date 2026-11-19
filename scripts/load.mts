#!/usr/bin/env node
// Reproduces the load of many agents working at once, without a provider, and measures how pi²'s engine answers
// meanwhile (#344). It starts N conversations on the scripted demo model in a throwaway copy, each writing at a model's
// pace and running a command again and again as a working agent does ("/work" in engine/src/providers.ts), and keeps
// asking what the app asks while it waits: to open a conversation, to send a message to one that is idle and to queue
// one behind a run. It reports how long each took before the load and with it, how late the engine's thread ran
// (`engine.lag`, engine/src/lag.ts), and how many events a second the engine sent.
//
//   node scripts/load.mts test-344                  a copy started from this checkout with scripts/test-copy; started
//                                                   here, and stopped at the end, if it is not running
//   node scripts/load.mts --socket <path>           an engine you started yourself, such as under a profiler
//
// Options: --runs 20, --seconds 120 (with the load), --before 15 (seconds measured before it), --pace 60 (tokens a
// second), --command "<shell command each step runs>", --large 200 (steps of a conversation made first, of about three
// entries each with a long output, to open as the largest conversations are opened; 0 for none), --json <file> (the numbers, to compare later), --keep (leave a
// copy this started running). Every conversation it made is archived at the end, which stops what it was doing, and
// its folders are removed.
//
// It never touches the installed pi²: a copy's socket is only ever the one `scripts/test-copy socket` names, after the
// checks `call` makes, and --socket is refused for the usual data folder's.

import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { connect, type Socket } from "node:net";
import { homedir, loadavg, tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const testCopy = join(root, "scripts", "test-copy");

function die(message: string): never {
	console.error(`load: ${message}`);
	process.exit(1);
}

// ---- Arguments

const args = process.argv.slice(2);
const options: Record<string, string> = {};
let suffix: string | undefined;
for (let i = 0; i < args.length; i++) {
	const arg = args[i]!;
	if (arg === "--keep") options.keep = "1";
	else if (arg.startsWith("--")) {
		const value = args[++i];
		if (value === undefined) die(`${arg} needs a value`);
		options[arg.slice(2)] = value;
	} else if (suffix === undefined) suffix = arg;
	else die(`unexpected ${arg}`);
}
const known = ["keep", "socket", "runs", "seconds", "before", "pace", "command", "json", "large"];
for (const key of Object.keys(options)) if (!known.includes(key)) die(`unknown option --${key}`);
if ((suffix === undefined) === (options.socket === undefined)) die("name a copy (node scripts/load.mts test-344) or an engine's socket (--socket <path>), one of them");
const number = (key: string, fallback: number) => {
	const value = options[key] === undefined ? fallback : Number(options[key]);
	if (!Number.isFinite(value) || value < 0) die(`--${key} takes a number`);
	return value;
};
const RUNS = number("runs", 20);
const SECONDS = number("seconds", 120);
const BEFORE = number("before", 15);
const PACE = number("pace", 60);
const LARGE = number("large", 200);
// What a working agent runs between paragraphs: looks at its repository, lists files, and waits on something (a build,
// a test) for a couple of seconds.
const COMMAND = options.command ?? "git status --short && git log --oneline -3 && ls -la && sleep 2";
/** How long one probe may wait before it counts as failed. */
const PROBE_LIMIT_MS = 60_000;

// ---- The engine

let started = false;
let socketPath: string;
if (options.socket !== undefined) {
	socketPath = resolve(options.socket);
	if (socketPath.startsWith(join(homedir(), "Library", "Application Support", "pi2") + "/")) die("refusing the usual data folder's socket: that is the installed pi²");
} else {
	const ask = () => spawnSync(testCopy, ["socket", suffix!], { encoding: "utf8" });
	let found = ask();
	if (found.status !== 0) {
		if (!/no copy named/.test(found.stderr)) die(found.stderr.trim());
		console.log(`Starting the copy ${suffix} (scripts/test-copy start ${suffix})…`);
		const start = spawnSync(testCopy, ["start", suffix!], { stdio: "inherit" });
		if (start.status !== 0) die("the copy did not start");
		started = true;
		found = ask();
		if (found.status !== 0) die(found.stderr.trim());
	}
	socketPath = found.stdout.trim();
}

type Answer = { id?: number; result?: unknown; error?: string };
const waiting = new Map<number, (answer: Answer) => void>();
const events = new Map<string, { count: number; bytes: number }>();
/** Called with each `conversation` event, for the conversation being made large. */
let watching: ((event: { id: number; items: unknown[]; state: { busy: boolean } }, bytes: number) => void) | undefined;
let counting = false;
let nextId = 1;

const socket: Socket = await new Promise((done, fail) => {
	const s = connect(socketPath, () => done(s));
	s.once("error", fail);
}).catch((error: Error) => die(`could not connect to ${socketPath}: ${error.message}`));
socket.on("close", () => {
	for (const answer of waiting.values()) answer({ error: "the connection to the engine closed" });
	waiting.clear();
});
// The start of a line still arriving, in pieces. Only each new piece is looked through for the line's end: joining and
// splitting all of it again for every piece took this script tens of milliseconds for a conversation of 1.5 MB, which
// it then counted as the engine's (#380).
let unfinished: string[] = [];
socket.setEncoding("utf8").on("data", (chunk: string) => {
	const lines: string[] = [];
	let start = 0;
	for (let end = chunk.indexOf("\n"); end !== -1; end = chunk.indexOf("\n", start)) {
		unfinished.push(chunk.slice(start, end));
		lines.push(unfinished.join(""));
		unfinished = [];
		start = end + 1;
	}
	if (start < chunk.length) unfinished.push(chunk.slice(start));
	for (const line of lines) {
		if (line === "") continue;
		const message = JSON.parse(line) as Answer & { event?: string };
		if (message.event !== undefined) {
			if (message.event === "conversation") watching?.(message as never, line.length);
			if (!counting) continue;
			const kind = events.get(message.event) ?? { count: 0, bytes: 0 };
			kind.count++;
			kind.bytes += line.length + 1;
			events.set(message.event, kind);
			continue;
		}
		const answer = waiting.get(message.id!);
		waiting.delete(message.id!);
		answer?.(message);
	}
});

/** Sends a request; resolves with its result and how long the answer took, or rejects with the engine's error. */
function request(method: string, params: object = {}, limit = PROBE_LIMIT_MS): Promise<{ result: any; ms: number }> {
	const id = nextId++;
	const began = performance.now();
	return new Promise((done, fail) => {
		const timer = setTimeout(() => {
			waiting.delete(id);
			fail(new Error(`${method} had no answer in ${limit / 1000} s`));
		}, limit);
		waiting.set(id, (answer) => {
			clearTimeout(timer);
			if (answer.error !== undefined) fail(new Error(`${method}: ${answer.error}`));
			else done({ result: answer.result, ms: performance.now() - began });
		});
		socket.write(`${JSON.stringify({ id, method, params })}\n`);
	});
}

// ---- Measuring

type Phase = "before" | "load";
const samples: Record<Phase, Record<string, number[]>> = { before: {}, load: {} };
const failures: string[] = [];
const record = (phase: Phase, what: string, ms: number) => (samples[phase][what] ??= []).push(ms);
let canLag = true;
const stalls: number[] = [];
let busyShare: Record<Phase, number[]> = { before: [], load: [] };

async function probe(phase: Phase, what: string, method: string, params: object): Promise<any> {
	try {
		const { result, ms } = await request(method, params);
		record(phase, what, ms);
		return result;
	} catch (error) {
		failures.push(`${phase}: ${(error as Error).message}`);
		record(phase, what, PROBE_LIMIT_MS);
		return undefined;
	}
}

/** One round of what the app asks for: a cheap request, opening a conversation, and sending a message. */
async function round(phase: Phase, n: number, idle: number, busy: number[], large: number | undefined): Promise<void> {
	if (canLag) {
		try {
			const { result } = await request("engine.lag");
			record(phase, "engine thread late, worst in a round", result.max);
			busyShare[phase].push(result.busy);
			stalls.push(...result.stalls);
		} catch (error) {
			if (/Unknown method/.test((error as Error).message)) canLag = false;
			else failures.push(`${phase}: ${(error as Error).message}`);
		}
	}
	await probe(phase, "engine.info (does nothing)", "engine.info", {});
	const open = busy.length > 0 ? busy[n % busy.length]! : idle;
	if ((await probe(phase, "conversation.open", "conversation.open", { id: open })) !== undefined) {
		await request("conversation.close", { id: open }).catch(() => {});
	}
	if (large !== undefined && (await probe(phase, `conversation.open, ${largeEntries} entries`, "conversation.open", { id: large })) !== undefined) {
		await request("conversation.close", { id: large }).catch(() => {});
	}
	// As the app opens it since #380: answered once the newest entries are sent, the rest following.
	if (large !== undefined && (await probe(phase, `conversation.open, newest first`, "conversation.open", { id: large, newestFirst: true })) !== undefined) {
		await request("conversation.close", { id: large }).catch(() => {});
	}
	await probe(phase, "submit, to an idle conversation", "submit", { id: idle, text: `A message while ${busy.length} runs work (${n}).` });
	if (busy.length > 0) await probe(phase, "submit, queued behind a run", "submit", { id: busy[(n * 7 + 3) % busy.length]!, text: `Queued while ${busy.length} runs work (${n}).` });
}

const made: number[] = [];
let largeEntries = 0;

/** A conversation of `steps` steps, each a paragraph, a command and its long output; resolves once it has finished. */
async function largeConversation(steps: number): Promise<number> {
	const id = await conversation("large");
	let seen = false;
	const finished = new Promise<void>((done) => {
		onInterrupt = done;
		watching = (event) => {
			if (event.id !== id) return;
			largeEntries += event.items.length;
			if (event.state.busy) seen = true;
			else if (seen) done();
		};
	});
	await request("conversation.open", { id });
	await request("submit", { id, text: `/work ${steps} 5000 seq 1 2000` });
	await finished;
	watching = undefined;
	await request("conversation.close", { id });
	return id;
}
const folders = mkdtempSync(join(process.env.PI2_SCRATCH ?? tmpdir(), "pi2-load-"));

/** A conversation on the demo model, with full access in a small git repository of its own. */
async function conversation(name: string): Promise<number> {
	const folder = join(folders, name);
	const git = (...words: string[]) => spawnSync("git", ["-C", folder, ...words], { stdio: "ignore" });
	spawnSync("mkdir", ["-p", folder]);
	git("init", "-q");
	writeFileSync(join(folder, "README.md"), `# ${name}\n\nA folder the load script made for one conversation.\n`);
	git("add", "README.md");
	git("-c", "user.name=load", "-c", "user.email=load@example.invalid", "commit", "-q", "-m", "Start");
	const { result } = await request("conversation.create", { model: { provider: "demo", modelId: "demo-1" } });
	made.push(result.id);
	await request("conversation.configure", { id: result.id, access: "full", cwd: folder });
	return result.id;
}

const sleep = (ms: number) => new Promise((done) => setTimeout(done, ms));
const quantile = (values: number[], share: number) => {
	const sorted = [...values].sort((x, y) => x - y);
	return sorted[Math.min(sorted.length - 1, Math.floor(share * sorted.length))] ?? NaN;
};
const worst = (values: number[]) => (values.length === 0 ? NaN : Math.max(...values));
const ms = (value: number) => (Number.isNaN(value) ? "-" : value >= 10_000 ? `${(value / 1000).toFixed(0)} s` : value >= 1000 ? `${(value / 1000).toFixed(1)} s` : `${Math.round(value)} ms`);

// Interrupted, it stops measuring, reports and archives what it made; interrupted again, it stops at once.
let interrupted = false;
let onInterrupt = () => {};
const interrupt = () => {
	if (interrupted) process.exit(130);
	interrupted = true;
	console.log("\nStopping early: the numbers so far follow.");
	onInterrupt();
};
process.on("SIGINT", interrupt);
process.on("SIGTERM", interrupt);

const load = { before: loadavg()[0]!, end: 0 };
const timeline: { at: number; load: number; open: number; late: number }[] = [];
const began = Date.now();
try {
	const idle = await conversation("idle");
	let large: number | undefined;
	if (LARGE > 0) {
		console.log(`Making a conversation of ${LARGE} steps to open…`);
		large = await largeConversation(LARGE);
	}
	console.log(`Measuring for ${BEFORE} s before the load…`);
	for (let n = 0, until = Date.now() + BEFORE * 1000; Date.now() < until && !interrupted; n++) {
		await round("before", n, idle, [], large);
		await sleep(1000);
	}

	console.log(`Starting ${RUNS} runs: each writes at ${PACE} tokens a second and runs \`${COMMAND}\` between paragraphs…`);
	const busy: number[] = [];
	for (let i = 0; i < RUNS && !interrupted; i++) {
		const id = await conversation(`run-${i + 1}`);
		// Enough steps to outlast the measurement; archiving stops it.
		await request("submit", { id, text: `/work 10000 ${PACE} ${COMMAND}` });
		busy.push(id);
	}
	counting = true;
	const loadStarted = performance.now();
	console.log(`Measuring for ${SECONDS} s with the load…`);
	for (let n = 0, until = Date.now() + SECONDS * 1000; Date.now() < until && !interrupted; n++) {
		const at = Math.round((Date.now() - began) / 1000);
		const before = samples.load["conversation.open"]?.length ?? 0;
		await round("load", n, idle, busy, large);
		const opened = samples.load["conversation.open"]?.[before] ?? NaN;
		const late = samples.load["engine thread late, worst in a round"]?.at(-1) ?? NaN;
		timeline.push({ at, load: loadavg()[0]!, open: Math.round(opened), late });
		if (n % 10 === 0) console.log(`  ${at} s: load average ${loadavg()[0]!.toFixed(0)}, open ${ms(opened)}, engine thread late by up to ${ms(late)}`);
		await sleep(1000);
	}
	const loadSeconds = (performance.now() - loadStarted) / 1000;
	counting = false;
	load.end = loadavg()[0]!;

	// ---- Report
	const rows = [...new Set([...Object.keys(samples.before), ...Object.keys(samples.load)])];
	const line = (cells: string[], widths: number[]) => cells.map((cell, i) => (i === 0 ? cell.padEnd(widths[i]!) : cell.padStart(widths[i]!))).join("  ");
	const widths = [38, 8, 8, 8, 8, 8, 8];
	console.log(`\nWith ${RUNS} runs on the demo model, ${PACE} tokens a second, for ${loadSeconds.toFixed(0)} s. Load average ${load.before.toFixed(0)} before, ${load.end.toFixed(0)} at the end.\n`);
	console.log(line(["", "before", "", "", `with ${RUNS} runs`, "", ""], widths));
	console.log(line(["", "median", "95%", "worst", "median", "95%", "worst"], widths));
	for (const row of rows) {
		const b = samples.before[row] ?? [];
		const l = samples.load[row] ?? [];
		console.log(line([row, ms(quantile(b, 0.5)), ms(quantile(b, 0.95)), ms(worst(b)), ms(quantile(l, 0.5)), ms(quantile(l, 0.95)), ms(worst(l))], widths));
	}
	const share = (values: number[]) => (values.length === 0 ? "-" : `${Math.round((values.reduce((x, y) => x + y, 0) / values.length) * 100)}%`);
	if (canLag) console.log(`\nThe engine's thread was busy ${share(busyShare.before)} of the time before, ${share(busyShare.load)} with the load. Held for a second or more: ${stalls.length === 0 ? "never" : stalls.map(ms).join(", ")}.`);
	else console.log("\nThis engine does not answer engine.lag (it is older than #344), so how late its thread ran is not known.");
	const kinds = [...events].sort(([, x], [, y]) => y.bytes - x.bytes);
	const total = kinds.reduce((sum, [, kind]) => ({ count: sum.count + kind.count, bytes: sum.bytes + kind.bytes }), { count: 0, bytes: 0 });
	console.log(`\nEvents to one client with the load: ${(total.count / loadSeconds).toFixed(1)} a second, ${(total.bytes / loadSeconds / 1024).toFixed(0)} KB a second.`);
	for (const [kind, { count, bytes }] of kinds) console.log(`  ${kind.padEnd(16)} ${(count / loadSeconds).toFixed(1).padStart(7)} a second  ${(bytes / loadSeconds / 1024).toFixed(1).padStart(8)} KB a second  ${(bytes / count / 1024).toFixed(1).padStart(7)} KB each`);
	if (failures.length > 0) console.log(`\n${failures.length} request(s) failed or had no answer in ${PROBE_LIMIT_MS / 1000} s (counted as ${PROBE_LIMIT_MS / 1000} s):\n  ${failures.slice(0, 10).join("\n  ")}`);
	if (options.json !== undefined) {
		const summary = Object.fromEntries(
			(["before", "load"] as const).map((phase) => [phase, Object.fromEntries(Object.entries(samples[phase]).map(([what, values]) => [what, { median: quantile(values, 0.5), p95: quantile(values, 0.95), worst: worst(values), n: values.length }]))]),
		);
		writeFileSync(options.json, JSON.stringify({ runs: RUNS, pace: PACE, command: COMMAND, seconds: loadSeconds, load, summary, busy: busyShare, stalls, events: Object.fromEntries(events), failures, timeline }, null, "\t"));
		console.log(`\nThe numbers are in ${options.json}.`);
	}
} finally {
	counting = false;
	console.log(`\nArchiving the ${made.length} conversations this made…`);
	for (const id of made) await request("conversation.archive", { id }, 600_000).catch((error) => console.error(`load: could not archive conversation ${id}: ${error.message}`));
	socket.destroy();
	rmSync(folders, { recursive: true, force: true });
	if (started && options.keep === undefined) spawnSync(testCopy, ["stop", suffix!], { stdio: "inherit" });
}
