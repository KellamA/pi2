// A pairing's limits (docs/iphone.md 6.6), counted for each end of it separately: the Mac, each listed phone, and each
// phone that has only joined a window. Only authenticated traffic counts: a message counts once the socket that sent it
// has proved itself, so a stranger who learned a pairing's id cannot spend its limits. And one end's traffic never
// counts against another, so no end can get another's socket closed, the Mac's least of all.
//
// Past a limit, the end's own socket is closed with `busy` and the time it may come back. A message is never dropped
// from the middle of a channel, which would break the channel for good (Noise's nonces are implicit); a closed socket
// reconnects and resumes (5.8). Past the day's limit, the end is refused for an hour at a time.

export type Limits = {
	messagesPerSecond: number;
	bytesPerSecond: number;
	messagesPerDay: number;
	bytesPerDay: number;
};

/** 6.6's table, for each end: 100 messages and 2 MB a second; 300,000 messages and 500 MB a day. */
export const LIMITS: Limits = {
	messagesPerSecond: 100,
	bytesPerSecond: 2 * 1024 * 1024,
	messagesPerDay: 300_000,
	bytesPerDay: 500 * 1024 * 1024,
};

/**
 * A phone that has only joined a window carries the pairing exchange and nothing else (3.3: two handshake messages, a
 * few lines, an attestation of some kilobytes), so it is given much less.
 */
export const JOINED_LIMITS: Limits = {
	messagesPerSecond: 20,
	bytesPerSecond: 256 * 1024,
	messagesPerDay: 2_000,
	bytesPerDay: 16 * 1024 * 1024,
};

/**
 * A pending pairing's Mac, before its first phone is added (6.6): anyone with a key of their own can register one, so
 * it is given little, enough for the first pairing with room (a window opened and closed a few times, a join, the
 * pairing exchange, `addDevice`), and every message counts. Its pairing is deleted after 15 minutes if no phone is
 * added, and past this day's allowance its Mac is held off for an hour, so a registration costs a few hundred writes
 * at most.
 */
export const PENDING_LIMITS: Limits = {
	messagesPerSecond: 10,
	bytesPerSecond: 64 * 1024,
	messagesPerDay: 200,
	bytesPerDay: 2 * 1024 * 1024,
};

export type Day = { day: string; messages: number; bytes: number };

/** Whether a message may pass; if not, until when its sender is held off, and whether for the day's limit. */
export type Verdict = { pass: true } | { pass: false; until: number; day: boolean };

const HOUR = 60 * 60 * 1000;

/** The counters of each end: a second's in memory, a day's kept in storage (as often as `due` says). */
export class Counters {
	private readonly seconds = new Map<string, { second: number; messages: number; bytes: number }>();
	private unsaved = 0;

	constructor(public days: Record<string, Day>) {}

	/** Counts one authenticated message of `size` bytes from `sender` at `now`, and says whether it may pass. */
	count(sender: string, size: number, now: number, limits: Limits): Verdict {
		const second = Math.floor(now / 1000);
		let counts = this.seconds.get(sender);
		if (counts === undefined || counts.second !== second) {
			counts = { second, messages: 0, bytes: 0 };
			this.seconds.set(sender, counts);
		}
		const today = dayOf(now);
		let day = this.days[sender];
		if (day === undefined || day.day !== today) day = this.days[sender] = { day: today, messages: 0, bytes: 0 };
		counts.messages += 1;
		counts.bytes += size;
		day.messages += 1;
		day.bytes += size;
		this.unsaved += 1;

		if (day.messages > limits.messagesPerDay || day.bytes > limits.bytesPerDay) return { pass: false, until: now + HOUR, day: true };
		if (counts.messages > limits.messagesPerSecond || counts.bytes > limits.bytesPerSecond) {
			return { pass: false, until: (second + 1) * 1000, day: false };
		}
		return { pass: true };
	}

	/** Forgets an end that is gone: a removed device, a slot let go. */
	forget(sender: string): void {
		this.seconds.delete(sender);
		delete this.days[sender];
	}

	/** Forgets the days that are over; says whether there were any. */
	forgetBefore(now: number): boolean {
		const today = dayOf(now);
		let forgot = false;
		for (const [sender, day] of Object.entries(this.days)) {
			if (day.day === today) continue;
			delete this.days[sender];
			forgot = true;
		}
		return forgot;
	}

	/** Whether any count has not been saved. */
	get dirty(): boolean {
		return this.unsaved > 0;
	}

	/** Whether the day's counts should be saved: every hundred messages, so traffic is not a write each. */
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
