// How long a stretch of the engine's own work took, told apart from how busy the Mac was meanwhile (issue #144).
//
// A clean stop has to be over within the five seconds the app gives the engine before a restore. Its time on the clock
// is what it waited for (its own timers, what it started, storage), what it did itself, and every moment the Mac kept it
// from running, which on a busy Mac can be most of it. A tick every TICK_MS tells the last part apart: a tick runs late
// only when the engine was working or was not let run, so the stretch less the ticks' lateness is the time it spent
// waiting. Its own work is counted as the processor time it used, which a busy Mac does not stretch the way it stretches
// the clock. The two together are what the stop would take on a quiet Mac.

const TICK_MS = 20;

export type Measured = {
	/** The stretch on the clock. */
	total: number;
	/** The part of it the engine spent waiting for something, with nothing to run. */
	waiting: number;
	/** The processor time the engine used meanwhile, on all its threads. */
	processor: number;
};

/** Starts measuring; the function returned ends it, in milliseconds. */
export function stopwatch(): () => Measured {
	const began = performance.now();
	const cpu = process.cpuUsage();
	let late = 0;
	let due = began + TICK_MS;
	const overdue = (now: number) => {
		late += Math.max(0, now - due);
		due = now + TICK_MS;
	};
	const tick = setInterval(() => overdue(performance.now()), TICK_MS);
	tick.unref();
	return () => {
		clearInterval(tick);
		const now = performance.now();
		// The stretch since the last tick, should it have run past when the next was due.
		if (now > due) overdue(now);
		const used = process.cpuUsage(cpu);
		const total = now - began;
		return { total: Math.round(total), waiting: Math.round(Math.max(0, total - late)), processor: Math.round((used.user + used.system) / 1000) };
	};
}
