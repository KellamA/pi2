// What the relay counts by address (docs/iphone.md 6.6): the group an address is counted in (an IPv6 address by its
// /64) and its block (an IPv6 address's /48), registrations, and every connection to /v1, counted in a few writes a
// minute that last when the object leaves memory, refused with 429 and `Retry-After`, and refused by the Worker itself
// while its address or its block is held.

import { env, runDurableObjectAlarm, runInDurableObject } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
	type Address,
	type Admission,
	addressCounted,
	addressGroup,
	addressName,
	addressNames,
	BLOCK_CONNECTIONS_A_MINUTE,
	BLOCK_CONNECTIONS_AN_HOUR,
	BLOCK_REGISTRATIONS_A_DAY,
	BLOCK_REGISTRATIONS_AN_HOUR,
	CONNECTIONS_A_MINUTE,
	CONNECTIONS_AN_HOUR,
	REGISTRATIONS_A_DAY,
	REGISTRATIONS_AN_HOUR,
} from "../src/addresses.ts";
import type { Pairing } from "../src/pairing.ts";
import { connect, pairingObject, register, worker } from "./helpers.ts";

// A time after the runtime's own, so that the objects' alarms wait for the test's clock rather than run at once.
const NOON = Date.parse("2027-06-01T12:00:00Z");
const MINUTE = 60 * 1000;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;

beforeEach(() => {
	vi.useFakeTimers({ toFake: ["Date"] });
	vi.setSystemTime(NOON);
});
afterEach(() => {
	vi.useRealTimers();
});

let prefixes = 0;
/** A /64 of its own for each test, and an address in it. */
function newPrefix(): (host: number) => string {
	prefixes += 1;
	const prefix = `2001:db8:${prefixes.toString(16)}:${(prefixes * 7).toString(16)}`;
	return (host) => `${prefix}:${(host >> 16).toString(16)}:${(host & 0xffff).toString(16)}:1:${(host % 9).toString(16)}`;
}

let blocks = 0;
/** A /48 of its own for each test (apart from `newPrefix`'s), and an address in any /64 of it. */
function newBlock(): (subnet: number, host?: number) => string {
	blocks += 1;
	const prefix = `2001:db8:${(0x8000 + blocks).toString(16)}`;
	return (subnet, host = 1) => `${prefix}:${subnet.toString(16)}::${host.toString(16)}`;
}

let quads = 0;
function newQuad(): string {
	quads += 1;
	return `203.0.${(quads >> 8) & 255}.${quads & 255}`;
}

/** The two 16-bit groups of an IPv4 address, in hex, inverted for Teredo. */
function groupsOf(quad: string, inverted = false): string {
	const [a, b, c, d] = quad.split(".").map(Number);
	const flip = (group: number) => (inverted ? ~group & 0xffff : group).toString(16);
	return `${flip((a << 8) | b)}:${flip((c << 8) | d)}`;
}

/** The 6to4 address of an IPv4 address (RFC 3056), in a /64 of its /48. */
function sixToFourOf(quad: string, subnet = 1): string {
	return `2002:${groupsOf(quad)}:${subnet.toString(16)}::1`;
}

/** A Teredo address of an IPv4 address (RFC 4380), through RFC 4380's example server, with a port. */
function teredoOf(quad: string, port = 0x63bf): string {
	return `2001:0:4136:e378:8000:${port.toString(16)}:${groupsOf(quad, true)}`;
}

/** The Address object an address is counted in, today. */
async function addressObject(address: string): Promise<DurableObjectStub<Address>> {
	const name = await addressName(env.ADDRESS_KEY!, addressGroup(address)!, Date.now());
	return env.ADDRESSES.get(env.ADDRESSES.idFromName(name));
}

/** The Address object an IPv6 address's block is counted in, today. */
async function blockObject(address: string): Promise<DurableObjectStub<Address>> {
	const name = await addressName(env.ADDRESS_KEY!, addressCounted(address)!.block!, Date.now());
	return env.ADDRESSES.get(env.ADDRESSES.idFromName(name));
}

/** A connection from `address` as the Worker counts it: its group's object, which asks its block's. */
async function admitFrom(address: string, registering = false): Promise<Admission> {
	const names = await addressNames(env.ADDRESS_KEY!, addressCounted(address)!, Date.now());
	return env.ADDRESSES.get(env.ADDRESSES.idFromName(names.group)).admit(registering, names.block);
}

/** What the object stores. */
async function storedIn(object: DurableObjectStub<Address>): Promise<Record<string, unknown>> {
	return runInDurableObject(object, async (_: Address, state) => Object.fromEntries(await state.storage.list()));
}

/** Counts the writes the address's object makes from here on, at its storage, and how often it is asked. */
async function watchAddress(address: string): Promise<Watched> {
	return watch(await addressObject(address));
}

/** The same for an IPv6 address's block's object. */
async function watchBlock(address: string): Promise<Watched> {
	return watch(await blockObject(address));
}

async function watch(object: DurableObjectStub<Address>): Promise<Watched> {
	const watched: Watched = { writes: 0, asked: 0, fail: false };
	await runInDurableObject(object, (instance: Address, state) => {
		const storage = state.storage as unknown as Record<string, (...args: unknown[]) => unknown>;
		for (const name of ["put", "delete", "deleteAll", "setAlarm", "deleteAlarm"]) {
			const real = storage[name].bind(storage);
			storage[name] = (...args: unknown[]) => {
				watched.writes += 1;
				if (watched.failWrites === true) return Promise.reject(new Error("storage"));
				return real(...args);
			};
		}
		// RPC calls only what the class has, not a property of the instance: so the class's method counts, for this one.
		const prototype = Object.getPrototypeOf(instance) as Watchable;
		if (prototype[WATCHED] !== true) {
			for (const method of ["admit", "admitBlock"] as const) {
				const real = prototype[method];
				prototype[method] = async function (this: object, ...args: unknown[]) {
					const counts = askedOf.get(this);
					if (counts !== undefined) counts.asked += 1;
					if (counts?.fail === true) throw new Error("overloaded");
					if (counts?.gate !== undefined) await counts.gate;
					return real.apply(this, args);
				};
			}
			prototype[WATCHED] = true;
		}
		askedOf.set(instance, watched);
	});
	return watched;
}

const WATCHED = Symbol("watched");
type Watchable = {
	admit: (this: object, ...args: unknown[]) => Promise<unknown>;
	admitBlock: (this: object, ...args: unknown[]) => Promise<unknown>;
	[WATCHED]?: true;
};
/** What `watchAddress` counts; `fail` makes the object's every answer an error, as an overloaded object's. */
type Watched = {
	writes: number;
	asked: number;
	fail: boolean;
	/** Every write to the object's storage refused, as a write the platform could not make. */
	failWrites?: boolean;
	/** While set, each call waits for it before the object answers. */
	gate?: Promise<void>;
};
const askedOf = new WeakMap<object, Watched>();

/**
 * The address's object as it is after leaving memory: a new instance over the same storage, as the runtime makes when
 * the next call comes. Gives what it answers to `count` connections.
 */
async function afresh(address: string, count: number): Promise<Admission[]> {
	return runInDurableObject(await addressObject(address), async (instance: Address, state) => {
		const fresh = new (instance.constructor as new (state: DurableObjectState, env: Cloudflare.Env) => Address)(state, env);
		const answers: Admission[] = [];
		for (let index = 0; index < count; index++) answers.push(await fresh.admit(false));
		return answers;
	});
}

/**
 * The object as it is after leaving memory, in place: what its constructor sets made anew, so that its next call loads
 * from storage, as the runtime's new instance would.
 */
async function evict(object: DurableObjectStub<Address>): Promise<void> {
	await runInDurableObject(object, (instance: Address) => {
		Object.assign(instance, { minutes: new Map(), marks: new Map(), bases: new Map(), times: [], waiting: [], loading: null });
	});
}

/** The stored mark of the object's minute at NOON. */
async function markOf(object: DurableObjectStub<Address>): Promise<number> {
	const minutes = (await storedIn(object)).minutes as Record<string, number> | undefined;
	return minutes?.[String(Math.floor(NOON / MINUTE))] ?? 0;
}

/** One connection to the pairing from `address`, as the Worker answers it; a socket it opens is closed again. */
async function knock(pairing: string | null, address: string | null): Promise<Response> {
	const headers: Record<string, string> = { Upgrade: "websocket" };
	if (pairing !== null) headers["Pi2-Pairing"] = pairing;
	if (address !== null) headers["CF-Connecting-IP"] = address;
	const response = await worker.fetch("https://relay.test/v1", { headers });
	if (response.webSocket) {
		response.webSocket.accept();
		response.webSocket.close(1000);
	}
	return response;
}

describe("the group an address is counted in", () => {
	it("takes an IPv4 address whole, written only as a dotted quad", () => {
		expect(addressGroup("192.0.2.1")).toBe("192.0.2.1");
		expect(addressGroup("0.0.0.0")).toBe("0.0.0.0");
		expect(addressGroup("255.255.255.255")).toBe("255.255.255.255");
		// Cloudflare's Pseudo IPv4 (class E) is an IPv4 address like another.
		expect(addressGroup("240.16.0.1")).toBe("240.16.0.1");
		for (const text of ["256.0.0.1", "01.2.3.4", "1.2.3.04", "1.2.3", "1.2.3.4.5", "1..2.3", " 1.2.3.4", "1.2.3.4 ", "1.2.3.4\n", "+1.2.3.4", "1.2.3.-4", "0x1.2.3.4", "1.2.3.4%en0", "1e2.2.3.4", "１.2.3.4"]) {
			expect(addressGroup(text), text).toBeNull();
		}
	});

	it("takes an IPv6 address by its /64, in every spelling: compressed, full, upper case, a dotted tail, a zone id", () => {
		const same = [
			"2001:db8:1:2::1",
			"2001:db8:1:2::",
			"2001:0db8:0001:0002:0000:0000:0000:0001",
			"2001:DB8:1:2:FFFF:FFFF:FFFF:FFFF",
			"2001:Db8:1:2:a:B:c:D",
			"2001:db8:1:2:0:0:192.0.2.1",
			"2001:db8:1:2::192.0.2.1",
			"2001:db8:1:2:1:2:3::",
			"2001:db8:1:2:0::1",
			"2001:db8:0001:2:0000::0:1",
			"2001:db8:1:2::1%en0",
			"2001:db8:1:2::1%25",
			"2001:db8:1:2::1%eth0.1_x~y-z",
		];
		for (const text of same) expect(addressGroup(text), text).toBe("2001:db8:1:2::/64");
		// The /64 itself is compressed only where it is: zero groups stay, so no two /64s read alike.
		expect(addressGroup("2001:db8::1")).toBe("2001:db8:0:0::/64");
		expect(addressGroup("2001:db8:0:1::1")).toBe("2001:db8:0:1::/64");
		expect(addressGroup("2001:db8:1:3::1")).toBe("2001:db8:1:3::/64");
		expect(addressGroup("fe80::1%en0")).toBe("fe80:0:0:0::/64");
		expect(addressGroup("::1")).toBe("0:0:0:0::/64");
		expect(addressGroup("::")).toBe("0:0:0:0::/64");
		expect(addressGroup("1:2:3:4:5:6:7:8")).toBe("1:2:3:4::/64");
		expect(addressGroup("::2:3:4:5:6:7:8")).toBe("0:2:3:4::/64");
	});

	it("takes an IPv4-mapped IPv6 address as the IPv4 address it is, in either spelling", () => {
		for (const text of ["::ffff:192.0.2.1", "::FFFF:192.0.2.1", "::ffff:c000:201", "::ffff:C000:0201", "0:0:0:0:0:ffff:192.0.2.1", "0000:0000:0000:0000:0000:ffff:c000:0201", "::ffff:192.0.2.1%en0"]) {
			expect(addressGroup(text), text).toBe("192.0.2.1");
		}
		// Only ::ffff:0:0/96 is mapped: an IPv4-compatible or translated address is IPv6, by its /64.
		expect(addressGroup("::192.0.2.1")).toBe("0:0:0:0::/64");
		expect(addressGroup("::ffff:0:192.0.2.1")).toBe("0:0:0:0::/64");
		expect(addressGroup("64:ff9b::192.0.2.1")).toBe("64:ff9b:0:0::/64");
	});

	it("takes every 6to4 address as one group, and every Teredo address as another, with no block, never as the IPv4 address it carries", () => {
		// 6to4 (2002::/16), whichever IPv4 address its next 32 bits carry, and whichever /64 of that address's /48.
		for (const text of ["2002:c000:201::1", "2002:C000:0201:0:0:0:0:1", "2002:c000:201:ffff:1:2:3:4", "2002:c000:201:5::", "2002:c000:201::192.0.2.9", "2002:cb00:7101::1", "2002::", "2002::1", "2002:ffff:ffff:ffff:ffff:ffff:ffff:ffff", "2002:c000:201::1%en0"]) {
			expect(addressCounted(text), text).toEqual({ group: "2002::/16", block: null });
		}
		// Teredo (2001::/32), whichever server, flags, port and client address it names (RFC 4380's example carries
		// 192.0.2.45, its last 32 bits inverted).
		for (const text of ["2001:0:4136:e378:8000:63bf:3fff:fdd2", "2001:0000:0a0b:0c0d:0:0:3fff:FDD2", "2001::ffff:1:3fff:fdd2", "2001:0:4136:e378:8000:63bf:63.255.253.210", "2001:0:1:2::", "2001::", "2001:0:ffff:ffff:ffff:ffff:ffff:ffff"]) {
			expect(addressCounted(text), text).toEqual({ group: "2001::/32", block: null });
		}
		// 2001:1::/32 and the rest of 2001::/16, and 2003::/16, are ordinary IPv6.
		expect(addressCounted("2001:1:4136:e378::3fff:fdd2")).toEqual({ group: "2001:1:4136:e378::/64", block: "2001:1:4136::/48" });
		expect(addressCounted("2001:db8:1:2::1")).toEqual({ group: "2001:db8:1:2::/64", block: "2001:db8:1::/48" });
		expect(addressCounted("2003:c000:201::1")).toEqual({ group: "2003:c000:201:0::/64", block: "2003:c000:201::/48" });
	});

	it("counts an IPv6 address in its /48 too, in every spelling; an IPv4 or mapped address in no block", () => {
		for (const text of ["2001:db8:1:2::1", "2001:0db8:0001:ffff:0000:0000:0000:0001", "2001:DB8:1:0:a:B:c:D", "2001:db8:1::", "2001:db8:1:2::192.0.2.1%en0"]) {
			expect(addressCounted(text)?.block, text).toBe("2001:db8:1::/48");
		}
		expect(addressCounted("2001:db8::1")).toEqual({ group: "2001:db8:0:0::/64", block: "2001:db8:0::/48" });
		expect(addressCounted("2001:db8:2:2::1")?.block).toBe("2001:db8:2::/48");
		for (const text of ["192.0.2.1", "::ffff:192.0.2.1"]) expect(addressCounted(text), text).toEqual({ group: "192.0.2.1", block: null });
		for (const text of [null, "", "2001:db8::1::2", "2001:db8::1/48"]) expect(addressCounted(text), String(text)).toBeNull();
	});

	it("names a block's object apart from every group's, by the same day's key", async () => {
		const names = await addressNames(env.ADDRESS_KEY!, addressCounted("2001:db8:1:2::1")!, NOON);
		expect(names.block).not.toBe(names.group);
		expect(names.group).toBe(await addressName(env.ADDRESS_KEY!, "2001:db8:1:2::/64", NOON));
		expect(names.block).toBe(await addressName(env.ADDRESS_KEY!, "2001:db8:1::/48", NOON));
		expect(names.block).toMatch(/^[0-9a-f]{64}$/);
		// The next day, both change.
		const tomorrow = await addressNames(env.ADDRESS_KEY!, addressCounted("2001:db8:1:2::1")!, NOON + DAY);
		expect(tomorrow.group).not.toBe(names.group);
		expect(tomorrow.block).not.toBe(names.block);
		expect((await addressNames(env.ADDRESS_KEY!, addressCounted("192.0.2.1")!, NOON)).block).toBeNull();
	});

	it("takes nothing else: a missing header, a malformed address, an address with more around it", () => {
		const refused = [
			null,
			"",
			" ",
			"2001:db8::1::2",
			"2001:db8:::1",
			":2001:db8::1",
			"2001:db8::1:",
			":::",
			"1:2:3:4:5:6:7:8:9",
			"1:2:3:4:5:6:7",
			"1:2:3:4:5:6:7::8",
			"1:2:3:4::5:6:7:8",
			"12345::1",
			"g::1",
			"2001:db8::-1",
			"2001:db8::+1",
			"2001:db8:: 1",
			" 2001:db8::1",
			"2001:db8::1 ",
			"::ffff:192.0.2.256",
			"::ffff:192.0.2",
			"::ffff:192.0.02.1",
			"1.2.3.4::",
			"::1.2.3.4:5",
			"1:2:3:4:5:6:7:1.2.3.4",
			"fe80::1%",
			"fe80::1%en 0",
			"fe80::1%en0%en1",
			"fe80::1%en/0",
			"[2001:db8::1]",
			"2001:db8::1/64",
			"2001:db8::1, 192.0.2.1",
			"localhost",
			`2001:db8::1%${"x".repeat(100)}`,
		];
		for (const text of refused) expect(addressGroup(text), String(text)).toBeNull();
	});
});

describe("registrations by address", () => {
	it("counts registrations from one /64 together, whatever address in it each comes from, and another /64 apart", async () => {
		const host = newPrefix();
		for (let index = 0; index < 5; index++) await register(host(index));
		const sixth = await knock(null, host(1000));
		expect(sixth.status).toBe(429);
		expect(sixth.headers.get("Retry-After")).toBe(String(HOUR / 1000));
		// The next /64 is another place.
		await register(newPrefix()(0));
		// An hour on, the first of the five has left the hour.
		vi.setSystemTime(NOON + HOUR);
		await register(host(2000));
	});

	it("counts an IPv4-mapped address with its IPv4 address", async () => {
		const quad = newQuad();
		for (let index = 0; index < 3; index++) await register(quad);
		await register(`::ffff:${quad}`);
		await register(`::FFFF:${quad}`);
		expect((await knock(null, quad)).status).toBe(429);
		expect((await knock(null, `::ffff:${quad}`)).status).toBe(429);
	});

	it("says when a registration may come again past the day's twenty", async () => {
		const quad = newQuad();
		for (let hour = 0; hour < 4; hour++) {
			vi.setSystemTime(NOON + hour * HOUR);
			for (let index = 0; index < 5; index++) await register(quad);
		}
		vi.setSystemTime(NOON + 4 * HOUR);
		const refused = await knock(null, quad);
		expect(refused.status).toBe(429);
		// The first of the day's twenty is a day old at noon tomorrow (though the day's object is another by then).
		expect(refused.headers.get("Retry-After")).toBe(String(20 * HOUR / 1000));
	});

	it("refuses a connection with no address, or one that does not read as one, before any object is woken", async () => {
		const mac = await register();
		const sockets = async () => runInDurableObject(pairingObject(mac.pairing), (_: Pairing, state) => state.getWebSockets().length);
		const before = await sockets();
		for (const address of [null, "", "unknown", "2001:db8::1::2", "198.51.100.1, 203.0.113.1", "01.2.3.4"]) {
			expect((await knock(null, address)).status, String(address)).toBe(400);
			expect((await knock(mac.pairing, address)).status, String(address)).toBe(400);
		}
		expect(await sockets()).toBe(before);
	});
});

describe("connections by address", () => {
	it(`takes ${CONNECTIONS_A_MINUTE} connections a minute from one /64 in eight writes; refuses the next with 429 until the next minute, writing nothing`, async () => {
		const mac = await register();
		const host = newPrefix();
		const watched = await watchAddress(host(0));
		// Half a minute in, so that the refusal's time is the minute's end, thirty seconds on.
		vi.setSystemTime(NOON + 30 * 1000);
		for (let index = 0; index < CONNECTIONS_A_MINUTE; index++) expect((await knock(mac.pairing, host(index))).status).toBe(101);
		const refused = await knock(mac.pairing, host(5000));
		expect(refused.status).toBe(429);
		expect(refused.headers.get("Retry-After")).toBe("30");
		// A registration from the same place is a connection too.
		expect((await knock(null, host(5001))).status).toBe(429);
		// The minute's marks (1, 2, 4, 8, 16, 32, 64, 120) and the alarm that removes them; nothing for the refused.
		expect(watched.writes).toBe(9);
		// Another address is not held back by this one.
		expect((await knock(mac.pairing, newPrefix()(0))).status).toBe(101);
		expect((await knock(mac.pairing, newQuad())).status).toBe(101);
		// The next minute, the address is taken again: refused connections were not counted.
		vi.setSystemTime(NOON + MINUTE);
		for (let index = 0; index < CONNECTIONS_A_MINUTE; index++) expect((await knock(mac.pairing, host(index))).status).toBe(101);
		expect((await knock(mac.pairing, host(0))).status).toBe(429);
		expect(watched.writes).toBe(17);
	});

	it("refuses a held address in the Worker itself, without asking its object, until the object's time", async () => {
		const mac = await register();
		const quad = newQuad();
		for (let index = 0; index < CONNECTIONS_A_MINUTE; index++) expect((await knock(mac.pairing, quad)).status).toBe(101);
		expect((await knock(mac.pairing, quad)).status).toBe(429);
		const watched = await watchAddress(quad);
		for (let index = 0; index < 50; index++) {
			const refused = await knock(mac.pairing, quad);
			expect(refused.status).toBe(429);
			expect(refused.headers.get("Retry-After")).toBe("60");
		}
		expect(watched.asked).toBe(0);
		vi.setSystemTime(NOON + MINUTE);
		expect((await knock(mac.pairing, quad)).status).toBe(101);
		expect(watched.asked).toBe(1);
	});

	it(`takes ${CONNECTIONS_AN_HOUR} in an hour, then as many as the oldest minutes give back as they leave it`, async () => {
		const quad = newQuad();
		const object = await addressObject(quad);
		const watched = await watchAddress(quad);
		// Ten minutes at the minute's limit.
		for (let minute = 0; minute < CONNECTIONS_AN_HOUR / CONNECTIONS_A_MINUTE; minute++) {
			vi.setSystemTime(NOON + minute * MINUTE);
			for (let index = 0; index < CONNECTIONS_A_MINUTE; index++) expect(await object.admit(false)).toEqual({ pass: true });
		}
		vi.setSystemTime(NOON + 30 * MINUTE);
		expect(await object.admit(false)).toEqual({ pass: false, until: NOON + HOUR, limit: "connections", by: "group" });
		// An hour after the first minute, its 120 are free again, and only those.
		vi.setSystemTime(NOON + HOUR);
		for (let index = 0; index < CONNECTIONS_A_MINUTE; index++) expect(await object.admit(false)).toEqual({ pass: true });
		expect(await object.admit(false)).toEqual({ pass: false, until: NOON + HOUR + MINUTE, limit: "connections", by: "group" });
		vi.setSystemTime(NOON + HOUR + MINUTE);
		expect(await object.admit(false)).toEqual({ pass: true });
		// Eight writes for each full minute, one for the last minute's one, and the alarm.
		expect(watched.writes).toBe(11 * 8 + 1 + 1);
	});

	it("keeps the counts when its object leaves memory, never fewer than were taken and at most twice", async () => {
		const quad = newQuad();
		const object = await addressObject(quad);
		for (let index = 0; index < 33; index++) expect(await object.admit(false)).toEqual({ pass: true });
		// 33 taken, and 64 stored: a new instance over the same storage takes 56 more this minute, not 120.
		const answers = await afresh(quad, 57);
		expect(answers.slice(0, 56).every((answer) => answer.pass)).toBe(true);
		expect(answers[56]).toEqual({ pass: false, until: NOON + MINUTE, limit: "connections", by: "group" });

		// An hour's worth: a new instance half an hour on is still refused until the first minute leaves the hour.
		const other = newQuad();
		const counted = await addressObject(other);
		for (let minute = 0; minute < CONNECTIONS_AN_HOUR / CONNECTIONS_A_MINUTE; minute++) {
			vi.setSystemTime(NOON + 2 * HOUR + minute * MINUTE);
			for (let index = 0; index < CONNECTIONS_A_MINUTE; index++) expect(await counted.admit(false)).toEqual({ pass: true });
		}
		vi.setSystemTime(NOON + 2 * HOUR + 30 * MINUTE);
		expect(await afresh(other, 1)).toEqual([{ pass: false, until: NOON + 3 * HOUR, limit: "connections", by: "group" }]);
	});

	it("stores at most twice what passed however often its object leaves memory: an IPv4 address, and a /64 with its block", async () => {
		for (const address of [newQuad(), newPrefix()(0)]) {
			const objects = [await addressObject(address)];
			if (addressCounted(address)!.block !== null) objects.push(await blockObject(address));
			let passed = 0;
			let refused: Admission | null = null;
			// Seventeen connections each time it comes back: just past a power of two, where a mark built on the last mark
			// would double what was stored each time.
			while (refused === null) {
				for (const object of objects) await evict(object);
				for (let index = 0; index < 17 && refused === null; index++) {
					const answer = await admitFrom(address);
					if (answer.pass) passed += 1;
					else refused = answer;
				}
				for (const object of objects) expect(await markOf(object), address).toBeLessThanOrEqual(2 * passed);
			}
			expect(refused).toEqual({ pass: false, until: NOON + MINUTE, limit: "connections", by: "group" });
			expect(passed, address).toBeGreaterThanOrEqual(CONNECTIONS_A_MINUTE / 2);
		}
	});

	it("removes the counts once they have aged out, the registrations' times a day after, and then everything", async () => {
		const quad = newQuad();
		const object = await addressObject(quad);
		await register(quad);
		for (let index = 0; index < 5; index++) await object.admit(false);
		const stored = async () => runInDurableObject(object, async (_: Address, state) => Object.fromEntries(await state.storage.list()));
		expect(Object.keys(await stored()).sort()).toEqual(["cleanupAt", "minutes", "times"]);
		// Run before its time, the alarm removes nothing and sets itself again for that time.
		vi.setSystemTime(NOON + 30 * MINUTE);
		expect(await runDurableObjectAlarm(object)).toBe(true);
		expect(await runInDurableObject(object, (_: Address, state) => state.storage.getAlarm())).toBe(NOON + 61 * MINUTE);
		expect(Object.keys(await stored()).sort()).toEqual(["cleanupAt", "minutes", "times"]);
		// The hour over, the minutes go; the registration's time stays for its day.
		vi.setSystemTime(NOON + 2 * HOUR);
		expect(await runDurableObjectAlarm(object)).toBe(true);
		expect(await stored()).toEqual({ minutes: {}, times: [NOON], cleanupAt: NOON + DAY });
		vi.setSystemTime(NOON + DAY);
		expect(await runDurableObjectAlarm(object)).toBe(true);
		expect(await stored()).toEqual({});
	});

	it("answers 503 when the address's object does not answer, and takes nothing", async () => {
		const mac = await register();
		const quad = newQuad();
		const watched = await watchAddress(quad);
		watched.fail = true;
		const sockets = async () => runInDurableObject(pairingObject(mac.pairing), (_: Pairing, state) => state.getWebSockets().length);
		const before = await sockets();
		for (const pairing of [mac.pairing, null]) {
			const response = await knock(pairing, quad);
			expect(response.status).toBe(503);
			expect(response.headers.get("Retry-After")).toBe("60");
		}
		expect(watched.asked).toBe(2);
		expect(await sockets()).toBe(before);
	});

	it("counts a registration once against both of its limits, with one write of its times", async () => {
		const quad = newQuad();
		const watched = await watchAddress(quad);
		await register(quad);
		// The alarm that deletes the times after a day, and the times.
		expect(watched.writes).toBe(2);
		await register(quad);
		expect(watched.writes).toBe(3);
		expect(watched.asked).toBe(2);
	});

	it("leaves a household's worst minute far inside the limit: a Mac and five phones all reconnecting through a dropping network", async () => {
		// Each end's backoff (RemoteKit's RelayBackoff: 1 s doubling to a minute, with jitter) brings it back at most
		// about seven times in the first minute; six ends, with every try reaching the relay.
		const mac = await register();
		const host = newPrefix();
		for (let attempt = 0; attempt < 7; attempt++) {
			for (let end = 0; end < 6; end++) expect((await knock(mac.pairing, host(end))).status).toBe(101);
		}
		// And the Mac's own next connection is still taken.
		(await connect(mac.pairing, host(0))).close();
	});
});

describe("an IPv6 address's block", () => {
	it(`counts a /48's registrations together, ${BLOCK_REGISTRATIONS_AN_HOUR} an hour, a /64 always meeting its own ${REGISTRATIONS_AN_HOUR} first; one refused by the block writes nothing`, async () => {
		const block = newBlock();
		// One /64 alone is refused by its own count, never the block's.
		for (let index = 0; index < REGISTRATIONS_AN_HOUR; index++) await register(block(0, index + 1));
		expect((await knock(null, block(0, 99))).status).toBe(429);
		expect(await admitFrom(block(0, 100), true)).toEqual({ pass: false, until: NOON + HOUR, limit: "registrations", by: "group" });
		// Three more /64s of the block fill it.
		for (let subnet = 1; subnet < BLOCK_REGISTRATIONS_AN_HOUR / REGISTRATIONS_AN_HOUR; subnet++) {
			for (let index = 0; index < REGISTRATIONS_AN_HOUR; index++) await register(block(subnet, index + 1));
		}
		const next = block(0x100);
		const watched = await watchAddress(next);
		const refused = await knock(null, next);
		expect(refused.status).toBe(429);
		expect(refused.headers.get("Retry-After")).toBe(String(HOUR / 1000));
		// Refused by the block each time, more often than its own /64 would take: what its /64 counted while the block was
		// asked was given back, and nothing was written.
		for (let index = 0; index <= REGISTRATIONS_AN_HOUR; index++) {
			expect(await admitFrom(next, true)).toEqual({ pass: false, until: NOON + HOUR, limit: "registrations", by: "block" });
		}
		expect(watched.writes).toBe(0);
		expect(await storedIn(await addressObject(next))).toEqual({});
		// Connections that do not register are not held back, and another /48 is another place.
		expect(await admitFrom(next)).toEqual({ pass: true });
		await register(newBlock()(0));
		// An hour on, the block has room again.
		vi.setSystemTime(NOON + HOUR);
		await register(next);
	});

	it(`says when a registration may come again past the block's ${BLOCK_REGISTRATIONS_A_DAY} a day`, async () => {
		const block = newBlock();
		const perHour = BLOCK_REGISTRATIONS_AN_HOUR / REGISTRATIONS_AN_HOUR;
		for (let hour = 0; hour < BLOCK_REGISTRATIONS_A_DAY / BLOCK_REGISTRATIONS_AN_HOUR; hour++) {
			vi.setSystemTime(NOON + hour * HOUR);
			for (let subnet = 0; subnet < perHour; subnet++) {
				for (let index = 0; index < REGISTRATIONS_AN_HOUR; index++) expect(await admitFrom(block(hour * perHour + subnet), true)).toEqual({ pass: true });
			}
		}
		vi.setSystemTime(NOON + 4 * HOUR);
		const refused = await knock(null, block(0xfff));
		expect(refused.status).toBe(429);
		expect(refused.headers.get("Retry-After")).toBe(String((20 * HOUR) / 1000));
	});

	it(`takes ${BLOCK_CONNECTIONS_A_MINUTE} connections a minute from a /48's /64s in twelve writes of its own, a /64 meeting its own ${CONNECTIONS_A_MINUTE} first; refuses the next, counting it nowhere`, async () => {
		const mac = await register();
		const block = newBlock();
		const blockWatched = await watchBlock(block(0));
		vi.setSystemTime(NOON + 30 * 1000);
		for (let index = 0; index < CONNECTIONS_A_MINUTE; index++) expect(await admitFrom(block(0, index + 1))).toEqual({ pass: true });
		expect(await admitFrom(block(0, 999))).toEqual({ pass: false, until: NOON + MINUTE, limit: "connections", by: "group" });
		// Eight more /64s at their limit, one at 100 and one at 20: the block's 1,200.
		for (let subnet = 1; subnet < 9; subnet++) {
			for (let index = 0; index < CONNECTIONS_A_MINUTE; index++) expect(await admitFrom(block(subnet))).toEqual({ pass: true });
		}
		for (let index = 0; index < 100; index++) expect(await admitFrom(block(9))).toEqual({ pass: true });
		for (let index = 0; index < 20; index++) expect(await admitFrom(block(10))).toEqual({ pass: true });
		expect(BLOCK_CONNECTIONS_A_MINUTE).toBe(1_200);
		// The block's marks (1, 2, 4, … 1,024, 1,200) and its alarm.
		expect(blockWatched.writes).toBe(13);
		// The /64 at 100 is refused by the block, again and again past its own 120: each was given back.
		const partly = await watchAddress(block(9));
		for (let index = 0; index < 30; index++) {
			expect(await admitFrom(block(9))).toEqual({ pass: false, until: NOON + MINUTE, limit: "connections", by: "block" });
		}
		expect(partly.writes).toBe(0);
		// A /64 of the block not seen before: refused, and nothing stored for it.
		const fresh = block(11);
		const watched = await watchAddress(fresh);
		expect(await admitFrom(fresh)).toEqual({ pass: false, until: NOON + MINUTE, limit: "connections", by: "block" });
		expect(watched.writes).toBe(0);
		expect(await storedIn(await addressObject(fresh))).toEqual({});
		expect(blockWatched.writes).toBe(13);

		// Through the Worker: 429 until the minute's end, then the block held in the Worker itself, for every /64 of it.
		const refused = await knock(mac.pairing, block(12));
		expect(refused.status).toBe(429);
		expect(refused.headers.get("Retry-After")).toBe("30");
		const asked = blockWatched.asked;
		for (let subnet = 13; subnet < 33; subnet++) expect((await knock(mac.pairing, block(subnet))).status).toBe(429);
		expect(blockWatched.asked).toBe(asked);
		// Another /48, and IPv4, are not held back.
		expect((await knock(mac.pairing, newBlock()(0))).status).toBe(101);
		expect((await knock(mac.pairing, newQuad())).status).toBe(101);
		// The next minute, the block takes connections again.
		vi.setSystemTime(NOON + MINUTE);
		expect((await knock(mac.pairing, block(13))).status).toBe(101);
		expect(blockWatched.asked).toBe(asked + 1);

		// Its alarm removes it all once the hour is over, as a /64's does.
		vi.setSystemTime(NOON + 2 * HOUR);
		const object = await blockObject(block(0));
		expect(await runDurableObjectAlarm(object)).toBe(true);
		expect(await storedIn(object)).toEqual({});
	});

	it(`takes half its ${BLOCK_CONNECTIONS_A_MINUTE} a minute at least from its /64s however often its objects leave memory, storing at most twice what passed`, async () => {
		const block = newBlock();
		const object = await blockObject(block(0));
		let passed = 0;
		let refused: Admission | null = null;
		for (let segment = 0; refused === null; segment++) {
			// Twenty /64s in turn, each and the block brought back from storage before its seventeen.
			const address = block(segment % 20);
			await evict(object);
			await evict(await addressObject(address));
			for (let index = 0; index < 17; index++) {
				const answer = await admitFrom(address);
				if (answer.pass) passed += 1;
				else {
					// A /64 at its own limit gives way to the next; the block's refusal ends it.
					if (answer.by === "block") refused = answer;
					break;
				}
			}
			expect(await markOf(object)).toBeLessThanOrEqual(2 * passed);
		}
		expect(refused).toEqual({ pass: false, until: NOON + MINUTE, limit: "connections", by: "block" });
		expect(passed).toBeGreaterThanOrEqual(BLOCK_CONNECTIONS_A_MINUTE / 2);
	});

	it(`keeps a block's ${BLOCK_CONNECTIONS_AN_HOUR} an hour when its object leaves memory`, async () => {
		const block = newBlock();
		const object = await blockObject(block(0));
		// What a block's object that took 1,200 in each of ten minutes has stored.
		const first = Math.floor(NOON / MINUTE);
		const minutes = Object.fromEntries(Array.from({ length: 10 }, (_, index) => [first + index, BLOCK_CONNECTIONS_A_MINUTE]));
		await runInDurableObject(object, async (_: Address, state) => {
			await state.storage.setAlarm(NOON + 70 * MINUTE);
			await state.storage.put({ minutes, cleanupAt: NOON + 70 * MINUTE });
		});
		vi.setSystemTime(NOON + 30 * MINUTE);
		const answer = await runInDurableObject(object, async (instance: Address, state) => {
			const fresh = new (instance.constructor as new (state: DurableObjectState, env: Cloudflare.Env) => Address)(state, env);
			return fresh.admitBlock(false);
		});
		expect(answer).toEqual({ pass: false, until: NOON + HOUR, limit: "connections", by: "block" });
	});

	it("answers 503 when the block's object does not answer, and its /64 counts nothing", async () => {
		const mac = await register();
		const block = newBlock();
		const blockWatched = await watchBlock(block(0));
		blockWatched.fail = true;
		const watched = await watchAddress(block(0));
		for (const pairing of [mac.pairing, null]) {
			const response = await knock(pairing, block(0));
			expect(response.status).toBe(503);
			expect(response.headers.get("Retry-After")).toBe("60");
		}
		expect(blockWatched.asked).toBe(2);
		expect(watched.writes).toBe(0);
		// Given back: the /64 still has its five registrations, and its whole minute.
		blockWatched.fail = false;
		for (let index = 0; index < REGISTRATIONS_AN_HOUR; index++) await register(block(0));
		for (let index = REGISTRATIONS_AN_HOUR; index < CONNECTIONS_A_MINUTE; index++) expect(await admitFrom(block(0))).toEqual({ pass: true });
		expect(await admitFrom(block(0))).toEqual({ pass: false, until: NOON + MINUTE, limit: "connections", by: "group" });
	});

	it("stores no registration of a /64 still waiting on its block: one the block then refuses is never stored", async () => {
		const block = newBlock();
		await fillBlockRegistrations(block, BLOCK_REGISTRATIONS_AN_HOUR - 1);
		const address = block(0);
		const blockWatched = await watchBlock(address);
		let open!: () => void;
		blockWatched.gate = new Promise((resolve) => {
			open = resolve;
		});
		// A first registration from the /64 waits at the block...
		const first = admitFrom(address, true);
		await vi.waitFor(() => expect(blockWatched.asked).toBe(1));
		blockWatched.gate = undefined;
		// ...while a second, a second later, takes the block's last room this hour, and is stored: alone.
		vi.setSystemTime(NOON + 1000);
		expect(await admitFrom(address, true)).toEqual({ pass: true });
		const object = await addressObject(address);
		expect((await storedIn(object)).times).toEqual([NOON + 1000]);
		open();
		expect(await first).toEqual({ pass: false, until: NOON + HOUR, limit: "registrations", by: "block" });
		expect((await storedIn(object)).times).toEqual([NOON + 1000]);
	});

	it("takes back what the block took when its /64's own write fails, so that the block counts only what passed", async () => {
		const block = newBlock();
		await fillBlockRegistrations(block, BLOCK_REGISTRATIONS_AN_HOUR - 1);
		const failing = block(0);
		const watched = await watchAddress(failing);
		watched.failWrites = true;
		await expect(admitFrom(failing, true)).rejects.toThrow();
		await expect(admitFrom(failing)).rejects.toThrow();
		// Through the Worker, 503, as for an object that does not answer.
		const response = await knock(null, failing);
		expect(response.status).toBe(503);
		expect(response.headers.get("Retry-After")).toBe("60");
		// The block took each and was told to give it back: it stores the nineteen registrations that passed, and counts
		// nineteen connections this minute; the /64 counts none.
		const blockStub = await blockObject(failing);
		expect(((await storedIn(blockStub)).times as number[]).length).toBe(BLOCK_REGISTRATIONS_AN_HOUR - 1);
		const minute = Math.floor(NOON / MINUTE);
		const counted = async (object: DurableObjectStub<Address>) =>
			runInDurableObject(object, (instance: Address) => (instance as unknown as { minutes: Map<number, number> }).minutes.get(minute) ?? 0);
		expect(await counted(blockStub)).toBe(BLOCK_REGISTRATIONS_AN_HOUR - 1);
		expect(await counted(await addressObject(failing))).toBe(0);
		// So the block's twentieth is still there to take, and only it.
		watched.failWrites = false;
		expect(await admitFrom(block(5), true)).toEqual({ pass: true });
		expect(await admitFrom(failing, true)).toEqual({ pass: false, until: NOON + HOUR, limit: "registrations", by: "block" });
		expect(await counted(blockStub)).toBe(BLOCK_REGISTRATIONS_AN_HOUR);
	});

	it("writes the next connection's own mark after a failed write, never letting it pass on a mark that was not stored: an IPv4 address and a /64", async () => {
		for (const address of [newQuad(), newBlock()(0)]) {
			const watched = await watchAddress(address);
			watched.failWrites = true;
			await expect(admitFrom(address), address).rejects.toThrow();
			watched.failWrites = false;
			expect(await admitFrom(address), address).toEqual({ pass: true });
			expect(await markOf(await addressObject(address)), address).toBeGreaterThanOrEqual(1);
		}
	});
});

/** Registrations from a block's /64s 1, 2, 3 and 4, five from each, `count` in all, at the present time. */
async function fillBlockRegistrations(block: (subnet: number, host?: number) => string, count: number): Promise<void> {
	for (let index = 0; index < count; index++) {
		const subnet = 1 + Math.floor(index / REGISTRATIONS_AN_HOUR);
		expect(await admitFrom(block(subnet, 1 + (index % REGISTRATIONS_AN_HOUR)), true)).toEqual({ pass: true });
	}
}

describe("the tunnelling ranges, 6to4 and Teredo", () => {
	it("counts registrations from every 6to4 address together, every Teredo address together, and neither against the IPv4 address it carries", async () => {
		// A day of its own, since each range is one object for everyone, named by the day.
		const day = NOON + 10 * DAY;
		vi.setSystemTime(day);
		const carried = Array.from({ length: REGISTRATIONS_AN_HOUR + 1 }, () => newQuad());
		// Five, each carrying another IPv4 address, from another /64 of its /48: the range's five this hour.
		for (let index = 0; index < REGISTRATIONS_AN_HOUR; index++) await register(sixToFourOf(carried[index], index));
		const refused = await knock(null, sixToFourOf(carried[REGISTRATIONS_AN_HOUR]));
		expect(refused.status).toBe(429);
		expect(refused.headers.get("Retry-After")).toBe(String(HOUR / 1000));
		// Teredo is one count of its own, whichever client address and port each names.
		for (let index = 0; index < REGISTRATIONS_AN_HOUR; index++) await register(teredoOf(carried[index], 0x1000 + index));
		expect((await knock(null, teredoOf(carried[REGISTRATIONS_AN_HOUR]))).status).toBe(429);
		// The IPv4 addresses they carry were counted for none of it: each still has its own five.
		for (let index = 0; index < REGISTRATIONS_AN_HOUR; index++) await register(carried[0]);
		expect((await knock(null, carried[0])).status).toBe(429);
		await register(carried[REGISTRATIONS_AN_HOUR]);
		// The day's limit is the range's too, all its addresses together.
		for (let hour = 1; hour < REGISTRATIONS_A_DAY / REGISTRATIONS_AN_HOUR; hour++) {
			vi.setSystemTime(day + hour * HOUR);
			for (let index = 0; index < REGISTRATIONS_AN_HOUR; index++) await register(sixToFourOf(newQuad()));
		}
		vi.setSystemTime(day + 4 * HOUR);
		const held = await knock(null, sixToFourOf(newQuad()));
		expect(held.status).toBe(429);
		expect(held.headers.get("Retry-After")).toBe(String((20 * HOUR) / 1000));
	});

	it(`takes one address's ${CONNECTIONS_A_MINUTE} connections a minute from a whole range, then holds it in the Worker; connections as a chosen IPv4 address's 6to4 or Teredo address take nothing of its own`, async () => {
		const day = NOON + 11 * DAY;
		vi.setSystemTime(day);
		const mac = await register();
		const target = newQuad();
		for (let index = 0; index < CONNECTIONS_A_MINUTE; index++) expect((await knock(mac.pairing, sixToFourOf(target, index))).status).toBe(101);
		const range = await watchAddress(sixToFourOf(newQuad()));
		for (const address of [sixToFourOf(target), sixToFourOf(newQuad()), "2002::1"]) {
			const refused = await knock(mac.pairing, address);
			expect(refused.status, address).toBe(429);
			expect(refused.headers.get("Retry-After")).toBe("60");
		}
		expect(range.asked).toBe(1);
		// The IPv4 address they carried has its whole minute, and Teredo is another count.
		for (let index = 0; index < CONNECTIONS_A_MINUTE; index++) expect((await knock(mac.pairing, target)).status).toBe(101);
		expect((await knock(mac.pairing, target)).status).toBe(429);
		for (let index = 0; index < CONNECTIONS_A_MINUTE; index++) expect((await knock(mac.pairing, teredoOf(target, index))).status).toBe(101);
		expect((await knock(mac.pairing, teredoOf(newQuad()))).status).toBe(429);
		// The next minute, the range is taken again.
		vi.setSystemTime(day + MINUTE);
		expect((await knock(mac.pairing, sixToFourOf(newQuad()))).status).toBe(101);
	});
});
