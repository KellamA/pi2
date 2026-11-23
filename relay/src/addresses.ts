// What the relay counts by address (docs/iphone.md 6.6): every connection to /v1, and registrations. The address is
// held only as a keyed hash, with a key that changes daily, for the day: each object is named by that hash, and keeps
// only the counts of the address's connections in the last hour (in a few writes a minute at most, never one for each)
// and the times of the day's registrations, each removed once it has aged out.
//
// An address is counted by the group it belongs to: an IPv4 address whole, an IPv6 address by its /64, since a home or
// a phone network is given a whole /64 and can use any address in it, and an IPv4-mapped or 6to4 IPv6 address as the
// IPv4 address it carries. An IPv6 address is counted again, more loosely, by its block, the /48 it is in: a home or a
// site given a /56 or a /48 has 256 or 65,536 /64s, each with a count of its own, and the block's count keeps that
// from multiplying its limits by as much (README.md, "What it decides").

import { DurableObject } from "cloudflare:workers";
import { hex, utf8 } from "./bytes.ts";
import { hmac } from "./crypto.ts";
import type { Env } from "./settings.ts";

export const REGISTRATIONS_AN_HOUR = 5;
export const REGISTRATIONS_A_DAY = 20;
/**
 * Connections to /v1 from one address (README.md, "What it decides"): a fence against one address opening thousands,
 * not a budget. A household's Mac and phones all coming back after its network dropped make a few dozen in a minute,
 * each end's backoff then bringing it back about once a minute at most.
 */
export const CONNECTIONS_A_MINUTE = 120;
export const CONNECTIONS_AN_HOUR = 1_200;
/**
 * The same for an IPv6 address's block, its /48, all its /64s together: four times a /64's registrations and ten times
 * its connections. A /64 alone can never reach them, so a household meets its own /64's limits first, and no one
 * customer of a network that hands out /64s from a shared /48 (a phone network, an ISP giving each home a /60) can use
 * them up for the rest. Registrations come from Macs, not phones, and cost a pending pairing's storage, so their factor
 * is the smaller; connections cost little, and many phones of a carrier may share a /48, so theirs is loose.
 */
export const BLOCK_REGISTRATIONS_AN_HOUR = 4 * REGISTRATIONS_AN_HOUR;
export const BLOCK_REGISTRATIONS_A_DAY = 4 * REGISTRATIONS_A_DAY;
export const BLOCK_CONNECTIONS_A_MINUTE = 10 * CONNECTIONS_A_MINUTE;
export const BLOCK_CONNECTIONS_AN_HOUR = 10 * CONNECTIONS_AN_HOUR;
const MINUTE = 60 * 1000;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;

type Limits = { registrationsAnHour: number; registrationsADay: number; connectionsAMinute: number; connectionsAnHour: number };
const GROUP: Limits = {
	registrationsAnHour: REGISTRATIONS_AN_HOUR,
	registrationsADay: REGISTRATIONS_A_DAY,
	connectionsAMinute: CONNECTIONS_A_MINUTE,
	connectionsAnHour: CONNECTIONS_AN_HOUR,
};
const BLOCK: Limits = {
	registrationsAnHour: BLOCK_REGISTRATIONS_AN_HOUR,
	registrationsADay: BLOCK_REGISTRATIONS_A_DAY,
	connectionsAMinute: BLOCK_CONNECTIONS_A_MINUTE,
	connectionsAnHour: BLOCK_CONNECTIONS_AN_HOUR,
};

/**
 * Whether a connection is taken; if not, until when it is refused, for which limit, and by which count: the address's
 * own group's, or its block's.
 */
export type Admission = { pass: true } | { pass: false; until: number; limit: "connections" | "registrations"; by: "group" | "block" };

/** What an address is counted by: its group (`addressGroup`), and for an IPv6 address its block, else null. */
export type Counted = { group: string; block: string | null };

/**
 * The names of the objects of an address's group and block today: HMAC-SHA256 of each (`addressCounted`), keyed with a
 * key made from the deployment's `ADDRESS_KEY` and the date, so the names change every day and cannot be worked back to
 * an address without that key. A group and a block never hash the same text: a block is written with `::/48`, a /64
 * with `::/64`, an IPv4 address with neither.
 */
export async function addressNames(addressKey: string, counted: Counted, now: number): Promise<{ group: string; block: string | null }> {
	const day = new Date(now).toISOString().slice(0, 10);
	const dayKey = await hmac(utf8(addressKey), utf8(`pi2-address\0${day}`));
	const name = async (text: string) => hex(await hmac(dayKey, utf8(text)));
	return { group: await name(counted.group), block: counted.block === null ? null : await name(counted.block) };
}

/** The name of the object of one group or block today, as `addressNames` makes it. */
export async function addressName(addressKey: string, group: string, now: number): Promise<string> {
	return (await addressNames(addressKey, { group, block: null }, now)).group;
}

/** The group an address is counted in (`addressCounted`), or null. */
export function addressGroup(text: string | null): string | null {
	return addressCounted(text)?.group ?? null;
}

/**
 * What an address is counted by, from `CF-Connecting-IP` as Cloudflare gives it. Its group: an IPv4 address as itself
 * (`192.0.2.1`), an IPv6 address as its /64 (`2001:db8:1:2::/64`), an IPv4-mapped IPv6 address (`::ffff:192.0.2.1`) and a
 * 6to4 one (`2002:c000:201::/48`, a whole /48 for one IPv4 address) as the IPv4 address they carry. Its block: for an
 * IPv6 address counted as IPv6, its /48 (`2001:db8:1::/48`); else none, since an IPv4 address is one place already.
 * Read strictly, by hand: anything else, a missing header among it, is null, and the relay takes nothing from it.
 */
export function addressCounted(text: string | null): Counted | null {
	if (text === null || text.length > 100) return null;
	const v4 = readIPv4(text);
	if (v4 !== null) return { group: v4.join("."), block: null };
	const v6 = readIPv6(text);
	if (v6 === null) return null;
	// ::ffff:0:0/96, an IPv4 address written as IPv6.
	if (v6.slice(0, 5).every((group) => group === 0) && v6[5] === 0xffff) return { group: quad(v6[6], v6[7]), block: null };
	// 2002::/16, 6to4 (RFC 3056): the /48 after it is the one IPv4 address's, which the next 32 bits give.
	if (v6[0] === 0x2002) return { group: quad(v6[1], v6[2]), block: null };
	const prefix = (length: number) =>
		v6
			.slice(0, length)
			.map((group) => group.toString(16))
			.join(":");
	return { group: `${prefix(4)}::/64`, block: `${prefix(3)}::/48` };
}

/** An IPv4 address from two 16-bit groups. */
function quad(high: number, low: number): string {
	return [high >> 8, high & 0xff, low >> 8, low & 0xff].join(".");
}

/** A dotted quad of four decimal numbers up to 255, with no leading zero (which some readers take for octal). */
function readIPv4(text: string): number[] | null {
	const parts = text.split(".");
	if (parts.length !== 4) return null;
	const out: number[] = [];
	for (const part of parts) {
		if (!/^(0|[1-9][0-9]{0,2})$/.test(part)) return null;
		const value = Number(part);
		if (value > 255) return null;
		out.push(value);
	}
	return out;
}

/**
 * The eight 16-bit groups of an IPv6 address in any spelling RFC 4291 allows: groups of one to four hex digits in either
 * case, one `::` for a run of zero groups, the last 32 bits as a dotted quad. A zone id (`%en0`), which names an
 * interface on the sender's own host and nothing the relay could count by, is taken off.
 */
function readIPv6(text: string): number[] | null {
	const percent = text.indexOf("%");
	const address = percent === -1 ? text : text.slice(0, percent);
	if (percent !== -1 && !/^[A-Za-z0-9._~-]{1,64}$/.test(text.slice(percent + 1))) return null;
	const halves = address.split("::");
	if (halves.length > 2) return null;
	const head = readGroups(halves[0], halves.length === 1);
	const tail = halves.length === 2 ? readGroups(halves[1], true) : [];
	if (head === null || tail === null) return null;
	if (halves.length === 1) return head.length === 8 ? head : null;
	// `::` stands for one zero group at least.
	if (head.length + tail.length > 7) return null;
	return [...head, ...new Array<number>(8 - head.length - tail.length).fill(0), ...tail];
}

/** Groups separated by single colons, the last of which may be a dotted quad if `last` (it ends the address). */
function readGroups(text: string, last: boolean): number[] | null {
	if (text === "") return [];
	const parts = text.split(":");
	const out: number[] = [];
	for (const [index, part] of parts.entries()) {
		if (last && index === parts.length - 1 && part.includes(".")) {
			const v4 = readIPv4(part);
			if (v4 === null) return null;
			out.push((v4[0] << 8) | v4[1], (v4[2] << 8) | v4[3]);
		} else {
			if (!/^[0-9A-Fa-f]{1,4}$/.test(part)) return null;
			out.push(Number.parseInt(part, 16));
		}
	}
	return out;
}

/**
 * The stored mark of a minute's connections: the count itself while small, then the next power of two, at most the
 * minute's limit.
 */
function markFor(count: number, limit: number): number {
	return Math.min(limit, count <= 2 ? count : 2 ** Math.ceil(Math.log2(count)));
}

/**
 * One object for each group (an IPv4 address, an IPv6 /64) and each block (an IPv6 /48) that connects today, named by
 * `addressNames`. A group's object counts against `GROUP`'s limits and, for an IPv6 address, asks its block's object,
 * which counts against `BLOCK`'s; a block's object asks no other.
 */
export class Address extends DurableObject<Env> {
	/**
	 * Connections counted in each clock minute of the last hour, by the minute's number. They are kept in storage too,
	 * since an object with nothing to do leaves memory after some seconds, which an address could otherwise bring about
	 * to start afresh. What is stored is a mark at or above the count, written before a connection passes it: the count
	 * itself for a minute's first two, then 4, 8, 16 and each power of two up to the limit. So a minute's connections cost
	 * at most eight writes however many they are (twelve for a block's), an object that left memory comes back counting at
	 * most twice what was made, and nothing is ever counted below what passed.
	 */
	private minutes = new Map<number, number>();
	private marks = new Map<number, number>();
	/** The times of the day's registrations, oldest first, as stored. */
	private times: number[] = [];
	private loading: Promise<void> | null = null;

	private load(): Promise<void> {
		this.loading ??= (async () => {
			const stored = await this.ctx.storage.get<unknown>(["minutes", "times"]);
			for (const [minute, mark] of Object.entries((stored.get("minutes") as Record<string, number> | undefined) ?? {})) {
				this.minutes.set(Number(minute), mark);
				this.marks.set(Number(minute), mark);
			}
			this.times = (stored.get("times") as number[] | undefined) ?? [];
		})();
		return this.loading;
	}

	/**
	 * Counts a connection to /v1 from this group, and a registration if it is one, if they are within the limits; and
	 * then, for an IPv6 address, in its block's object, named `block`, which must take it too. A connection refused by
	 * either is counted by neither and writes nothing, so that people who share an address or a block get in as soon as
	 * there is room, and the block counts only what its /64s let through.
	 */
	async admit(registering: boolean, block: string | null = null): Promise<Admission> {
		const ask = block === null ? undefined : () => this.env.ADDRESSES.get(this.env.ADDRESSES.idFromName(block)).admitBlock(registering);
		return this.count(registering, GROUP, "group", ask);
	}

	/** Counts a connection, and a registration if it is one, against a block's limits: asked by its /64s' objects only. */
	async admitBlock(registering: boolean): Promise<Admission> {
		return this.count(registering, BLOCK, "block");
	}

	private async count(registering: boolean, limits: Limits, by: "group" | "block", ask?: () => Promise<Admission>): Promise<Admission> {
		await this.load();
		const now = Date.now();
		const refused = this.connectionsRefused(now, limits);
		if (refused !== null) return { pass: false, until: refused, limit: "connections", by };
		this.times = this.times.filter((time) => now - time < DAY);
		if (registering) {
			const hour = this.times.filter((time) => now - time < HOUR);
			if (this.times.length >= limits.registrationsADay) return { pass: false, until: this.times[0] + DAY, limit: "registrations", by };
			if (hour.length >= limits.registrationsAnHour) return { pass: false, until: hour[0] + HOUR, limit: "registrations", by };
		}
		const minute = Math.floor(now / MINUTE);
		// Counted at once, so that the connections that come while the block is asked see this one; given back if the
		// block refuses it, or does not answer.
		this.minutes.set(minute, (this.minutes.get(minute) ?? 0) + 1);
		if (registering) this.times.push(now);
		if (ask !== undefined) {
			let answer: Admission;
			try {
				const result = await ask();
				answer = result.pass ? { pass: true } : { pass: false, until: result.until, limit: result.limit, by: result.by };
				// What the runtime keeps for an answer over RPC is let go when it is disposed, rather than left to the garbage
				// collector (which the runtime warns of).
				(result as Partial<Disposable>)[Symbol.dispose]?.();
			} catch (error) {
				this.giveBack(minute, registering, now);
				throw error;
			}
			if (!answer.pass) {
				this.giveBack(minute, registering, now);
				return answer;
			}
		}
		const writes: Record<string, unknown> = {};
		if (registering) writes.times = [...this.times];
		// The minute's count with any still waiting on the block: a mark at or above what passed.
		const count = this.minutes.get(minute) ?? 0;
		if (count > (this.marks.get(minute) ?? 0)) {
			this.marks.set(minute, markFor(count, limits.connectionsAMinute));
			for (const marked of this.marks.keys()) if (!this.minutes.has(marked)) this.marks.delete(marked);
			writes.minutes = Object.fromEntries(this.marks);
		}
		if (Object.keys(writes).length === 0) return { pass: true };
		// Written before the connection is let through, and the alarm that removes it all once it has aged out set with it
		// (moved only earlier, so a busy address does not set it again each time).
		const due = this.agedOut(now);
		const alarm = await this.ctx.storage.getAlarm();
		const moved = alarm === null || alarm > due;
		if (moved) writes.cleanupAt = due;
		// The alarm first, so that nothing is ever stored with no alarm to remove it.
		if (moved) await this.ctx.storage.setAlarm(due);
		await this.ctx.storage.put(writes);
		return { pass: true };
	}

	/** Takes back a connection counted while its block was asked, which the block refused. */
	private giveBack(minute: number, registering: boolean, now: number): void {
		const count = (this.minutes.get(minute) ?? 1) - 1;
		if (count > 0) this.minutes.set(minute, count);
		else this.minutes.delete(minute);
		if (registering) {
			const index = this.times.lastIndexOf(now);
			if (index !== -1) this.times.splice(index, 1);
		}
	}

	/** When the oldest of what is kept has aged out: the newest minute an hour on, or the first registration a day on. */
	private agedOut(now: number): number {
		const due: number[] = [];
		if (this.minutes.size > 0) due.push((Math.max(...this.minutes.keys()) + 61) * MINUTE);
		if (this.times.length > 0) due.push(this.times[0] + DAY);
		return due.length > 0 ? Math.min(...due) : now + HOUR;
	}

	/** Forgets the minutes older than the hour. */
	private prune(now: number): void {
		const minute = Math.floor(now / MINUTE);
		for (const counted of this.minutes.keys()) if (counted <= minute - 60) this.minutes.delete(counted);
	}

	/** Null if a connection may be taken now; else when the next may be. */
	private connectionsRefused(now: number, limits: Limits): number | null {
		this.prune(now);
		const minute = Math.floor(now / MINUTE);
		if ((this.minutes.get(minute) ?? 0) >= limits.connectionsAMinute) return (minute + 1) * MINUTE;
		let hour = 0;
		for (const count of this.minutes.values()) hour += count;
		if (hour < limits.connectionsAnHour) return null;
		// Room comes back as the oldest minutes leave the hour.
		for (const [counted, count] of [...this.minutes].sort(([a], [b]) => a - b)) {
			hour -= count;
			if (hour < limits.connectionsAnHour) return (counted + 60) * MINUTE;
		}
		return (minute + 1) * MINUTE;
	}

	/**
	 * Removes what has aged out: the minutes older than the hour, the registrations older than the day; everything once
	 * nothing is left, and then the object keeps nothing. Otherwise it comes again when the rest will have aged out. An
	 * object of an earlier day, whose name no address hashes to any more, is emptied so too.
	 */
	async alarm(): Promise<void> {
		await this.load();
		const now = Date.now();
		// The platform never runs an alarm before its time; one that runs early all the same (a test's clock, set apart from
		// the runtime's) sets itself again for that time, so that what is stored always has an alarm to remove it.
		const cleanupAt = await this.ctx.storage.get<number>("cleanupAt");
		if (cleanupAt !== undefined && now < cleanupAt) return this.ctx.storage.setAlarm(cleanupAt);
		this.prune(now);
		for (const marked of this.marks.keys()) if (!this.minutes.has(marked)) this.marks.delete(marked);
		this.times = this.times.filter((time) => now - time < DAY);
		if (this.marks.size === 0 && this.times.length === 0) {
			await this.ctx.storage.deleteAll();
			return;
		}
		const due = this.agedOut(now);
		// The alarm first, as above.
		await this.ctx.storage.setAlarm(due);
		await this.ctx.storage.put({ minutes: Object.fromEntries(this.marks), times: this.times, cleanupAt: due });
	}
}
