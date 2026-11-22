// A pairing's limits (docs/iphone.md 6.6). Only authenticated traffic is counted: a message counts once the socket that
// sent it has proved itself as the pairing's Mac or one of its phones, so a stranger who learned a pairing's id cannot
// spend its limits and get its sockets closed. Past a limit, the relay answers "busy" and passes nothing on; past twice
// a limit, the pairing's sockets are closed for an hour.

export type Limits = {
	messagesPerSecond: number;
	bytesPerSecond: number;
	messagesPerDay: number;
	bytesPerDay: number;
};

/** 6.6's table: 100 messages and 2 MB a second; 300,000 messages and 500 MB a day. */
export const LIMITS: Limits = {
	messagesPerSecond: 100,
	bytesPerSecond: 2 * 1024 * 1024,
	messagesPerDay: 300_000,
	bytesPerDay: 500 * 1024 * 1024,
};

export type Day = { day: string; messages: number; bytes: number };

export type Verdict = { pass: true } | { pass: false; until: number; block: boolean };

/** The counters: a second's in memory, a day's kept in storage (as often as `due` says). */
export class Counters {
	private second = -1;
	private messages = 0;
	private bytes = 0;
	private unsaved = 0;

	constructor(public day: Day) {}

	/** Counts one authenticated message of `size` bytes at `now`, and says whether it may pass. */
	count(size: number, now: number, limits: Limits): Verdict {
		const second = Math.floor(now / 1000);
		if (second !== this.second) {
			this.second = second;
			this.messages = 0;
			this.bytes = 0;
		}
		const today = dayOf(now);
		if (today !== this.day.day) this.day = { day: today, messages: 0, bytes: 0 };
		this.messages += 1;
		this.bytes += size;
		this.day.messages += 1;
		this.day.bytes += size;
		this.unsaved += 1;

		const overDay = this.day.messages > limits.messagesPerDay || this.day.bytes > limits.bytesPerDay;
		const overSecond = this.messages > limits.messagesPerSecond || this.bytes > limits.bytesPerSecond;
		if (!overDay && !overSecond) return { pass: true };
		const block =
			this.day.messages > 2 * limits.messagesPerDay ||
			this.day.bytes > 2 * limits.bytesPerDay ||
			this.messages > 2 * limits.messagesPerSecond ||
			this.bytes > 2 * limits.bytesPerSecond;
		const until = overDay ? Date.parse(`${today}T00:00:00Z`) + 24 * 60 * 60 * 1000 : (second + 1) * 1000;
		return { pass: false, until, block };
	}

	/** Whether the day's counts should be saved: every hundred messages, so a pairing's traffic is not a write each. */
	get due(): boolean {
		return this.unsaved >= 100;
	}

	saved(): void {
		this.unsaved = 0;
	}
}

export function dayOf(now: number): string {
	return new Date(now).toISOString().slice(0, 10);
}
