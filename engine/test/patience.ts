// What the tests that start a real engine share: waiting for it to listen, talking to it over its socket, and waiting
// for what it should do. Not a test itself; the tests import it.
//
// None of it may depend on how fast the Mac is. With several test runs going at once an engine can take well over ten
// seconds to start listening, and anything it does can take many times longer than on a quiet machine (issues #84,
// #114). So a wait here is for the thing itself, never for a time, and its limit, PATIENT_MS, is only a guard against a
// hang. A wait the test can tell has failed ends at once instead: when the engine has exited, or the connection to it
// has closed, nothing more is coming.

import type { ChildProcess } from "node:child_process";
import { connect, type Socket } from "node:net";
import { setTimeout as sleep } from "node:timers/promises";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { scratchRoot } from "../src/scratch.ts";
import { socketPathFor } from "../src/socket.ts";
import { installedState, STALE_MESSAGE } from "../scripts/installed.ts";

// A test file run alone stops here too, at once and with the same line, rather than failing somewhere in the engine it
// starts (#521). `npm test` checks this first; this is what a file run by hand meets.
if (installedState(join(import.meta.dirname, "..")) !== "current") {
	console.error(STALE_MESSAGE);
	process.exit(1);
}

/** The data folders of the engines a test talked to, whose scratch folders (outside the data folder) go when it ends. */
const homes = new Set<string>();
// On exit, so they go whether the test passed or failed; a test's data folder is its own, and so are these.
process.on("exit", () => {
	for (const home of homes) rmSync(scratchRoot(home), { recursive: true, force: true });
});

/**
 * A stand-in app bundle, for `PI2_APP_BUNDLE`: what a development engine asks whether a connection is the app's, which
 * alone may answer approvals and questions (#504). `script` is its `Contents/MacOS/pi2-peer`, which is given the
 * connection as descriptor 3 and prints one line of JSON; by default it takes every connection for the app's, for the
 * tests that answer from their own connection as the app does. engine/test/answers.ts checks the refusals. Removed
 * when the test ends.
 */
export function standInApp(script = `#!/bin/sh\necho '{"app":true,"why":"a stand-in takes every connection for the app'"'"'s"}'\n`): string {
	const bundle = mkdtempSync(join(tmpdir(), "pi2-stand-in-app-"));
	process.on("exit", () => rmSync(bundle, { recursive: true, force: true }));
	mkdirSync(join(bundle, "Contents", "MacOS"), { recursive: true });
	writeFileSync(join(bundle, "Contents", "MacOS", "pi2-peer"), script, { mode: 0o755 });
	return bundle;
}

/** How long a wait for something that will happen, unless what is tested is broken, may take: only a hang reaches it. */
export const PATIENT_MS = 10 * 60_000;

/**
 * A stand-in for the program that keeps the Mac awake (#561), which the engine starts as `caffeinate -i -w <its pid>`:
 * it ends when the engine's process does ($3), as `caffeinate -w` does, and asserts nothing, so no run of the suite keeps
 * the real Mac awake or leaves a holder behind. `engine/test/keepawake.ts` names one of its own, which also says which
 * pid held it; a test that wants another names PI2_AWAKE_PROGRAM itself, as that one does. Removed when the test ends.
 */
export function awakeStandIn(): string {
	const folder = mkdtempSync(join(tmpdir(), "pi2-awake-stand-in-"));
	process.on("exit", () => rmSync(folder, { recursive: true, force: true }));
	const file = join(folder, "holder.sh");
	writeFileSync(file, `#!/bin/sh\nwhile kill -0 "$3" 2>/dev/null; do sleep 1; done\n`, { mode: 0o755 });
	return file;
}

// Every engine a test starts inherits these, so no run of the suite keeps the person's Mac awake and no check depends on
// how it happens to be powered.
process.env.PI2_AWAKE_PROGRAM ??= awakeStandIn();
process.env.PI2_AWAKE_POWER ??= "ac";

/** Whether the process is still running (it has not exited, nor been ended by a signal). */
export function running(child: ChildProcess): boolean {
	return child.exitCode === null && child.signalCode === null;
}

/** Resolves once the process has exited, at once if it already has. */
export function exited(child: ChildProcess): Promise<void> {
	if (!running(child)) return Promise.resolve();
	return new Promise((resolve) => child.once("exit", () => resolve()));
}

/** Stops the process with `signal` unless it has already ended, and resolves once it has. */
export async function stop(child: ChildProcess, signal: NodeJS.Signals = "SIGTERM"): Promise<void> {
	if (!running(child)) return;
	const ended = exited(child);
	child.kill(signal);
	await ended;
}

/** How a process that is no longer running ended, for a message. */
function ending(child: ChildProcess): string {
	return child.signalCode !== null ? `was ended by ${child.signalCode}` : `exited with code ${child.exitCode}`;
}

/**
 * Waits until `check` gives a value (anything but undefined or false: null is an answer too) and returns it. It looks again whenever
 * `wake` says something arrived, and every 50 ms in any case, for checks on files and processes. `over` names a reason
 * the value can no longer come, which ends the wait at once.
 */
export async function until<T>(
	what: string,
	check: () => T | undefined | false,
	options: { patience?: number; over?: () => string | undefined; wake?: (resolve: () => void) => () => void } = {},
): Promise<T> {
	const deadline = Date.now() + (options.patience ?? PATIENT_MS);
	for (;;) {
		const value = check();
		if (value !== undefined && value !== false) return value;
		const reason = options.over?.();
		if (reason !== undefined) throw new Error(`Waiting for ${what}, but ${reason}`);
		if (Date.now() > deadline) throw new Error(`Timed out waiting for: ${what}`);
		await new Promise<void>((resolve) => {
			const forget = options.wake?.(() => {
				clearTimeout(timer);
				resolve();
			});
			const timer = setTimeout(() => {
				forget?.();
				resolve();
			}, 50);
		});
	}
}

/**
 * Connects to the engine `engine` started on data folder `home`, as soon as it listens. Until then there may be no socket
 * file, or the one a killed engine left behind, which refuses connections; either way it tries again shortly. It stops
 * at once if the engine exits first.
 */
export async function listening(engine: ChildProcess, home: string, patience = PATIENT_MS): Promise<Socket> {
	homes.add(home);
	const path = socketPathFor(home);
	const ended = exited(engine);
	for (const deadline = Date.now() + patience; ; ) {
		if (!running(engine)) throw new Error(`The engine ${ending(engine)} before it listened`);
		const socket = connect(path);
		try {
			await new Promise<void>((resolve, reject) => socket.once("connect", resolve).once("error", reject));
			return socket;
		} catch (error) {
			socket.destroy();
			if (Date.now() > deadline) throw new Error(`The engine did not listen within ${patience / 60_000} minutes: ${(error as Error).message}`);
			await Promise.race([sleep(50), ended]);
		}
	}
}

/**
 * Delete the projects carrying over made (docs/projects.md, 9.9), so that the conversations made before are in no project
 * for what they are told and offered: a conversation that is not a chat is otherwise always in a project, and a deleted
 * project's carried ones are in none (`inProject`). For the tests that check what a conversation in no project is told,
 * byte for byte. Answers the projects it deleted.
 */
export async function leaveOut(client: EngineClient): Promise<string[]> {
	const { projects } = await client.call("projects.list");
	const carried = projects.filter((project: any) => project.carriedAt !== undefined && project.deletedAt === undefined).map((project: any) => project.id as string);
	for (const id of carried) await client.call("projects.delete", { id });
	return carried;
}

/**
 * A project for a test about something other than projects, with a copy of each of `templates` in it (#718): since
 * carrying over runs as conversations are made (docs/projects.md, 9.9), a conversation made with a template runs as
 * its project's copy, so a test that changes its agent's settings and expects the conversation to follow makes it
 * with the copy, and changes the copy. Made on `folder` (null: none), the folder its agents work in. They are copied
 * in the order given, and a copy's `delegates` name only the copies made before it, so give an agent after those it
 * hands work to (Scout and Forge before Atlas). Answers the project's id and the copies' ids, by their templates' ids.
 *
 * The project is left with no conversation with its orchestrator, as one carrying over made for a folder is until the
 * person opens it (docs/projects.md, 9.6): the person's messages to its agents then tell no orchestrator, and their
 * transcripts have no line saying so (6.4), as a conversation's had before projects.
 */
export async function aProject<T extends string>(client: EngineClient, folder: string | null, templates: T[]): Promise<{ id: string; agents: Record<T, string> }> {
	const { id, conversation } = await client.call("projects.create", { folder });
	await client.call("conversation.delete", { id: conversation });
	// The project lets it go in a commit of its own, after the deletion's (`putAwayChanged`). Asked, since a test's
	// client may keep no `projects` event.
	for (const deadline = Date.now() + PATIENT_MS; ; ) {
		const { projects } = await client.call("projects.list");
		if ((projects as any[]).some((project) => project.id === id && project.conversation === null)) break;
		if (Date.now() > deadline) throw new Error("Timed out waiting for: the project with no conversation with its orchestrator");
		await new Promise((resolve) => setTimeout(resolve, 50));
	}
	const agents = {} as Record<T, string>;
	for (const template of templates) agents[template] = (await client.call("projects.addAgent", { projectId: id, template })).id;
	return { id, agents };
}

/**
 * One connection to an engine, as the app has: requests with their answers, and the events it sends, which a test's own
 * client keeps by overriding `receive`. By default each kind of event is kept by name in `events`, and a conversation's
 * items and state in `conversations`.
 */
export class EngineClient {
	readonly socket: Socket;
	events: Record<string, any> = {};
	conversations = new Map<number, any>();
	#next = 1;
	#replies = new Map<number, { resolve: (value: any) => void; reject: (error: Error) => void; answer: Promise<any> }>();
	#wakers = new Set<() => void>();
	#closed = false;

	constructor(socket: Socket) {
		this.socket = socket;
		let buffer = "";
		socket.setEncoding("utf8").on("data", (chunk: string) => {
			buffer += chunk;
			const lines = buffer.split("\n");
			buffer = lines.pop()!;
			for (const line of lines) {
				const message = JSON.parse(line);
				if (typeof message.event !== "string" && message.id !== undefined && message.id !== null) {
					const reply = this.#replies.get(message.id);
					this.#replies.delete(message.id);
					// A refusal may carry data beside its message (docs/projects.md, 4.1), kept on the error as `data`.
					if (message.error !== undefined) reply?.reject(Object.assign(new Error(message.error), message.data === undefined ? {} : { data: message.data }));
					else reply?.resolve(message.result);
				} else this.receive(message);
			}
			this.#wake();
		});
		// The socket errors when the engine is killed, which some checks do on purpose; it closes either way.
		socket.on("error", () => {});
		socket.on("close", () => {
			this.#closed = true;
			// No answer is coming to a request still waiting for one. Nobody need be waiting on it: a request sent
			// without waiting for its answer, as the engine was killed, is not a failure of its own.
			for (const reply of this.#replies.values()) {
				reply.answer.catch(() => {});
				reply.reject(new Error("The connection to the engine closed before it answered"));
			}
			this.#replies.clear();
			this.#wake();
		});
	}

	/** A client of this kind, connected to `engine` on data folder `home` as soon as it listens. */
	static async connect<C extends EngineClient>(this: new (socket: Socket) => C, engine: ChildProcess, home: string): Promise<C> {
		return new this(await listening(engine, home));
	}

	/** Whether the connection has closed, as it does when the engine exits. */
	get closed(): boolean {
		return this.#closed;
	}

	/** An event from the engine. */
	receive(message: any): void {
		if (message.event === "conversation") {
			const conv = this.conversations.get(message.id) ?? { items: [] };
			if (message.reset) conv.items = [];
			conv.items.push(...message.items);
			conv.state = message.state;
			this.conversations.set(message.id, conv);
		} else if (typeof message.event === "string") this.events[message.event] = message;
	}

	call(method: string, params: Record<string, unknown> = {}): Promise<any> {
		if (this.#closed) return Promise.reject(new Error(`${method}: the connection to the engine is closed`));
		const id = this.#next++;
		let reply!: { resolve: (value: any) => void; reject: (error: Error) => void };
		const answer = new Promise<any>((resolve, reject) => (reply = { resolve, reject }));
		this.#replies.set(id, { ...reply, answer });
		this.socket.write(`${JSON.stringify({ id, method, params })}\n`);
		return answer;
	}

	/**
	 * Waits until `check` gives a value, looking again as each message arrives. Ends at once if the connection closes
	 * before then, since nothing more will arrive on it.
	 */
	until<T>(what: string, check: () => T | undefined | false, patience = PATIENT_MS): Promise<T> {
		return until(what, check, {
			patience,
			over: () => (this.#closed ? "the connection to the engine closed" : undefined),
			wake: (resolve) => {
				this.#wakers.add(resolve);
				return () => this.#wakers.delete(resolve);
			},
		});
	}

	close(): void {
		this.socket.destroy();
	}

	#wake(): void {
		const wakers = [...this.#wakers];
		this.#wakers.clear();
		for (const wake of wakers) wake();
	}
}
