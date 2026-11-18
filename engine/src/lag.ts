// How late the engine's one thread runs: how long a timer due now waits before it fires, and how much of the time the
// thread is busy. Everything the app asks, opening a conversation or sending a message, waits at least as long, so
// this is what the load script (scripts/load.mts) asks for with `engine.lag`. A wait of a second or more is also
// written to engine.log, so a slow engine on a real Mac leaves a trace (#344).
//
// Measured with a timer of its own rather than `monitorEventLoopDelay`, whose histogram did not show a thread held for
// 300 ms at all when tried: a late tick here is exactly the wait a request would have had.

import { type EventLoopUtilization, performance } from "node:perf_hooks";

/** A wait this long is written to engine.log. */
const STALL_MS = 1000;
/** How often it looks. */
const TICK_MS = 50;
/** The most ticks kept between two `take`s: about an hour and a half of them. */
const KEEP = 100_000;

export type Lag = {
	/** Milliseconds since the last `take`, or since the engine started. */
	over: number;
	/** How late a timer fired, in milliseconds: the median, the 99th percentile and the worst. */
	p50: number;
	p99: number;
	max: number;
	/** The share of that time the thread was busy, 0 to 1. */
	busy: number;
	/** The waits of a second or more, in milliseconds, oldest first (at most 20). */
	stalls: number[];
};

export class LagMonitor {
	#since = performance.now();
	#used: EventLoopUtilization = performance.eventLoopUtilization();
	#late: number[] = [];
	#stalls: number[] = [];
	readonly #timer: ReturnType<typeof setInterval>;

	constructor(log: (line: string) => void) {
		let due = performance.now() + TICK_MS;
		this.#timer = setInterval(() => {
			const now = performance.now();
			const late = Math.max(0, now - due);
			due = now + TICK_MS;
			if (this.#late.length < KEEP) this.#late.push(late);
			if (late < STALL_MS) return;
			this.#stalls.push(Math.round(late));
			if (this.#stalls.length > 20) this.#stalls.shift();
			log(`the engine's thread was held for ${(late / 1000).toFixed(1)} s without a break: anything asked of it meanwhile waited that long`);
		}, TICK_MS);
		this.#timer.unref();
	}

	/** What happened since the last time it was asked, and starts counting again. */
	take(): Lag {
		const now = performance.now();
		const used = performance.eventLoopUtilization(this.#used);
		const sorted = this.#late.sort((x, y) => x - y);
		const at = (share: number) => Math.round(sorted[Math.min(sorted.length - 1, Math.floor(share * sorted.length))] ?? 0);
		const lag: Lag = {
			over: Math.round(now - this.#since),
			p50: at(0.5),
			p99: at(0.99),
			max: Math.round(sorted.at(-1) ?? 0),
			busy: Math.round(used.utilization * 1000) / 1000,
			stalls: this.#stalls,
		};
		this.#since = now;
		this.#used = performance.eventLoopUtilization();
		this.#late = [];
		this.#stalls = [];
		return lag;
	}

	stop(): void {
		clearInterval(this.#timer);
	}
}
