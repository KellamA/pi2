// Registering is limited per address: 5 an hour, 20 a day (docs/iphone.md 6.6). The address is held only as a keyed
// hash, with a key that changes daily, for the day: each object is named by that hash and keeps only the times of the
// day's registrations, and deletes itself a day after its first.

import { DurableObject } from "cloudflare:workers";
import { hex, utf8 } from "./bytes.ts";
import { hmac } from "./crypto.ts";
import type { Env } from "./settings.ts";

export const REGISTRATIONS_AN_HOUR = 5;
export const REGISTRATIONS_A_DAY = 20;
const HOUR = 60 * 60 * 1000;
const DAY = 24 * HOUR;

/**
 * The name of an address's object today: HMAC-SHA256 of the address, keyed with a key made from the deployment's
 * `ADDRESS_KEY` and the date, so the name changes every day and cannot be worked back to an address without that key.
 */
export async function addressName(addressKey: string, address: string, now: number): Promise<string> {
	const day = new Date(now).toISOString().slice(0, 10);
	const dayKey = await hmac(utf8(addressKey), utf8(`pi2-address\0${day}`));
	return hex(await hmac(dayKey, utf8(address)));
}

export class Address extends DurableObject<Env> {
	/** Counts a registration from this address, if it is within the limits. */
	async register(): Promise<boolean> {
		const now = Date.now();
		const times = ((await this.ctx.storage.get<number[]>("times")) ?? []).filter((time) => now - time < DAY);
		if (times.length >= REGISTRATIONS_A_DAY || times.filter((time) => now - time < HOUR).length >= REGISTRATIONS_AN_HOUR) return false;
		if (times.length === 0) await this.ctx.storage.setAlarm(now + DAY);
		times.push(now);
		await this.ctx.storage.put("times", times);
		return true;
	}

	async alarm(): Promise<void> {
		await this.ctx.storage.deleteAll();
	}
}
