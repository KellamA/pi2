// Scheduled runs: "start a conversation with this agent and this prompt at these times".
//
// A schedule is a row in a committed document. The engine keeps one timer for the earliest due time and, on every
// start, runs whatever came due while it was not running (once per schedule, however many times were missed).

import { defineDoc } from "@earendil-works/pi-durable";

export type Repeat =
	| { kind: "once"; at: number }
	| { kind: "interval"; minutes: number }
	| { kind: "daily"; hour: number; minute: number }
	| { kind: "weekly"; weekday: number; hour: number; minute: number };

export type Schedule = {
	id: string;
	title: string;
	agentId: string;
	prompt: string;
	repeat: Repeat;
	enabled: boolean;
	nextRunAt: number | null;
	lastRunAt: number | null;
	lastConversationId: number | null;
	/** A run whose conversation exists but whose prompt may not have been submitted yet; finished on the next start. */
	pending: { conversationId: number; runAt: number } | null;
	createdAt: number;
	/** Set when an agent made it (with the person's approval), from that conversation; absent when the person made it. */
	createdBy?: { agentId: string; conversationId: number };
};

export const Schedules = defineDoc<{ schedules: Record<string, Schedule> }>({
	kind: "pi2.schedules",
	version: 1,
	scope: "session",
	initial: () => ({ schedules: {} }),
	checkpointWhen: () => true,
});

export function validateRepeat(repeat: unknown): Repeat {
	const r = repeat as Partial<Record<string, unknown>> | undefined;
	const int = (value: unknown, min: number, max: number, what: string): number => {
		if (typeof value !== "number" || !Number.isInteger(value) || value < min || value > max) throw new Error(`${what} must be a whole number from ${min} to ${max}`);
		return value;
	};
	switch (r?.kind) {
		case "once":
			if (typeof r.at !== "number" || !Number.isFinite(r.at)) throw new Error("Pick a date and time");
			return { kind: "once", at: r.at };
		case "interval":
			return { kind: "interval", minutes: int(r.minutes, 1, 60 * 24 * 30, "The interval in minutes") };
		case "daily":
			return { kind: "daily", hour: int(r.hour, 0, 23, "The hour"), minute: int(r.minute, 0, 59, "The minute") };
		case "weekly":
			return { kind: "weekly", weekday: int(r.weekday, 0, 6, "The weekday"), hour: int(r.hour, 0, 23, "The hour"), minute: int(r.minute, 0, 59, "The minute") };
		default:
			throw new Error("Unknown kind of schedule");
	}
}

/** The first run time strictly after `after`, in the Mac's local time; null when there is none. */
export function nextRun(repeat: Repeat, after: number): number | null {
	switch (repeat.kind) {
		case "once":
			return repeat.at > after ? repeat.at : null;
		case "interval":
			return after + repeat.minutes * 60_000;
		case "daily":
		case "weekly": {
			const next = new Date(after);
			next.setHours(repeat.hour, repeat.minute, 0, 0);
			// At most eight steps: today, then each of the next seven days.
			for (let i = 0; i < 8; i++) {
				const fits = repeat.kind === "daily" || next.getDay() === repeat.weekday;
				if (fits && next.getTime() > after) return next.getTime();
				next.setDate(next.getDate() + 1);
				next.setHours(repeat.hour, repeat.minute, 0, 0);
			}
			return null;
		}
	}
}
