// What the relay counts by address (docs/iphone.md 6.6): every connection to /v1, and registrations. The address is
// held only as a keyed hash, with a key that changes daily, for the day: each object is named by that hash, counts the
// address's connections in memory, never in storage, and keeps only the times of the day's registrations, which it
// deletes a day after its first.
//
// An address is counted by the group it belongs to: an IPv4 address whole, an IPv6 address by its /64, since a home or
// a phone network is given a whole /64 and can use any address in it, and an IPv4-mapped IPv6 address as the IPv4
// address it is.

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
const MINUTE = 60 * 1000;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;

/** Whether a connection is taken; if not, until when its address is refused, and for which limit. */
export type Admission = { pass: true } | { pass: false; until: number; limit: "connections" | "registrations" };

/**
 * The name of an address's object today: HMAC-SHA256 of the address's group (`addressGroup`), keyed with a key made from
 * the deployment's `ADDRESS_KEY` and the date, so the name changes every day and cannot be worked back to an address
 * without that key.
 */
export async function addressName(addressKey: string, group: string, now: number): Promise<string> {
	const day = new Date(now).toISOString().slice(0, 10);
	const dayKey = await hmac(utf8(addressKey), utf8(`pi2-address\0${day}`));
	return hex(await hmac(dayKey, utf8(group)));
}

/**
 * The group an address is counted in, from `CF-Connecting-IP` as Cloudflare gives it: an IPv4 address as itself
 * (`192.0.2.1`), an IPv6 address as its /64 (`2001:db8:1:2::/64`), an IPv4-mapped IPv6 address as its IPv4 address. Read
 * strictly, by hand: anything else, a missing header among it, is null, and the relay takes nothing from it.
 */
export function addressGroup(text: string | null): string | null {
	if (text === null || text.length > 100) return null;
	const v4 = readIPv4(text);
	if (v4 !== null) return v4.join(".");
	const v6 = readIPv6(text);
	if (v6 === null) return null;
	// ::ffff:0:0/96, an IPv4 address written as IPv6.
	if (v6.slice(0, 5).every((group) => group === 0) && v6[5] === 0xffff) {
		return [v6[6] >> 8, v6[6] & 0xff, v6[7] >> 8, v6[7] & 0xff].join(".");
	}
	return `${v6
		.slice(0, 4)
		.map((group) => group.toString(16))
		.join(":")}::/64`;
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

export class Address extends DurableObject<Env> {
	/**
	 * Connections counted in each clock minute of the last hour, in memory only. An object that sat idle long enough to be
	 * evicted forgets them, which only an address making few connections can bring about.
	 */
	private readonly minutes = new Map<number, number>();

	/**
	 * Counts a connection to /v1 from this address, and a registration if it is one, if they are within the limits. A
	 * connection refused is not counted, so that people who share an address get in as soon as there is room.
	 */
	async admit(registering: boolean): Promise<Admission> {
		const now = Date.now();
		const refused = this.connectionsRefused(now);
		if (refused !== null) return { pass: false, until: refused, limit: "connections" };
		if (registering) {
			const times = ((await this.ctx.storage.get<number[]>("times")) ?? []).filter((time) => now - time < DAY);
			const hour = times.filter((time) => now - time < HOUR);
			if (times.length >= REGISTRATIONS_A_DAY) return { pass: false, until: times[0] + DAY, limit: "registrations" };
			if (hour.length >= REGISTRATIONS_AN_HOUR) return { pass: false, until: hour[0] + HOUR, limit: "registrations" };
			if (times.length === 0) await this.ctx.storage.setAlarm(now + DAY);
			times.push(now);
			await this.ctx.storage.put("times", times);
		}
		const minute = Math.floor(now / MINUTE);
		this.minutes.set(minute, (this.minutes.get(minute) ?? 0) + 1);
		return { pass: true };
	}

	/** Null if a connection may be taken now; else when the next may be. */
	private connectionsRefused(now: number): number | null {
		const minute = Math.floor(now / MINUTE);
		for (const counted of this.minutes.keys()) if (counted <= minute - 60) this.minutes.delete(counted);
		if ((this.minutes.get(minute) ?? 0) >= CONNECTIONS_A_MINUTE) return (minute + 1) * MINUTE;
		let hour = 0;
		for (const count of this.minutes.values()) hour += count;
		if (hour < CONNECTIONS_AN_HOUR) return null;
		// Room comes back as the oldest minutes leave the hour.
		for (const [counted, count] of [...this.minutes].sort(([a], [b]) => a - b)) {
			hour -= count;
			if (hour < CONNECTIONS_AN_HOUR) return (counted + 60) * MINUTE;
		}
		return (minute + 1) * MINUTE;
	}

	async alarm(): Promise<void> {
		await this.ctx.storage.deleteAll();
	}
}
