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
import { rmSync } from "node:fs";
import { scratchRoot } from "../src/scratch.ts";
import { socketPathFor } from "../src/socket.ts";

/** The data folders of the engines a test talked to, whose scratch folders (outside the data folder) go when it ends. */
const homes = new Set<string>();
// On exit, so they go whether the test passed or failed; a test's data folder is its own, and so are these.
process.on("exit", () => {
	for (const home of homes) rmSync(scratchRoot(home), { recursive: true, force: true });
});

/** How long a wait for something that will happen, unless what is tested is broken, may take: only a hang reaches it. */
export const PATIENT_MS = 10 * 60_000;

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
					if (message.error !== undefined) reply?.reject(new Error(message.error));
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
