// A pairing's limits (docs/iphone.md 6.6, 5.3), counted for each end apart: only authenticated traffic counts; past a
// limit the end's own socket is closed with `busy` and when it may come back; past the day's, it is held off for an
// hour; and no end's traffic ever holds off another, the Mac least of all.

import { runDurableObjectAlarm, runInDurableObject } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { base64url, concat, fromBase64url, random } from "../src/bytes.ts";
import { JOINED_LIMITS, LIMITS, type Limits, PENDING_LIMITS } from "../src/limits.ts";
import type { Pairing } from "../src/pairing.ts";
import { proofText } from "../src/protocol.ts";
import {
	addPhone,
	type Client,
	connect,
	countStorageWrites,
	joinHello,
	macHello,
	type Mac,
	newAttestKeyId,
	newDeviceId,
	newKey,
	openWindow,
	pairingObject,
	type Phone,
	phoneHello,
	register,
	sendJoin,
	standInVerifier,
} from "./helpers.ts";

const NOON = Date.parse("2026-11-20T12:00:00Z");
const MINUTE = 60 * 1000;
const HOUR = 60 * MINUTE;

beforeEach(() => {
	vi.useFakeTimers({ toFake: ["Date"] });
	vi.setSystemTime(NOON);
});
afterEach(() => {
	vi.useRealTimers();
});

async function setLimits(pairing: string, limits: Partial<Limits>, joined: Partial<Limits> = {}): Promise<void> {
	await runInDurableObject(pairingObject(pairing), (instance: Pairing) => {
		instance.limits = { ...LIMITS, ...limits };
		instance.joinedLimits = { ...JOINED_LIMITS, ...joined };
	});
}

/** Counts the pairing's writes from here on: each save of its record and of its day's counts. */
async function countWrites(pairing: string): Promise<{ count: number }> {
	const writes = { count: 0 };
	await runInDurableObject(pairingObject(pairing), (instance: Pairing) => {
		const object = instance as unknown as Record<"save" | "saveDays", () => Promise<void>>;
		for (const name of ["save", "saveDays"] as const) {
			const real = object[name].bind(instance);
			object[name] = async () => {
				writes.count += 1;
				await real();
			};
		}
	});
	return writes;
}

/** The clock at the start of the next second. */
function nextSecond(): void {
	vi.setSystemTime(Math.ceil((Date.now() + 1) / 1000) * 1000);
}

/** A Mac with phones listed and connected, the clock at the start of a second. */
async function pairWithPhones(count = 1): Promise<{ mac: Mac; listed: Phone[]; phones: Client[] }> {
	const mac = await register();
	const listed: Phone[] = [];
	for (let index = 0; index < count; index++) listed.push(await addPhone(mac));
	const phones: Client[] = [];
	for (const phone of listed) {
		phones.push((await phoneHello(mac.pairing, phone)).client);
		expect(await mac.client.json()).toEqual({ online: { device: phone.device } });
	}
	nextSecond();
	return { mac, listed, phones };
}

/** Expects the socket to be held off: `busy` with when it may come back, then closed. */
async function heldOff(client: Client, until: number): Promise<void> {
	for (;;) {
		const message = await client.next();
		if (typeof message === "string" && message.startsWith('{"busy"')) {
			expect(JSON.parse(message)).toEqual({ busy: { until } });
			break;
		}
		if (typeof message === "object" && "closed" in message) throw new Error("closed without busy");
	}
	expect(await client.next()).toMatchObject({ reason: "busy" });
}

function prefixed(device: string, bytes: number[]): Uint8Array {
	return concat(fromBase64url(device.slice(4), 16)!, new Uint8Array(bytes));
}

describe("limits", () => {
	it("closes a phone's socket with busy past its messages a second, passing on nothing after, and takes it back the next second", async () => {
		const { mac, listed, phones } = await pairWithPhones();
		await setLimits(mac.pairing, { messagesPerSecond: 3 });
		for (let index = 0; index < 4; index++) phones[0].sendBytes(new Uint8Array([index]));
		await heldOff(phones[0], Date.now() + 1000);
		for (let index = 0; index < 3; index++) expect((await mac.client.bytes()).at(-1)).toBe(index);
		expect(await mac.client.json()).toEqual({ held: { device: listed[0].device, until: Date.now() + 1000 } });
		expect(await mac.client.json()).toEqual({ offline: { device: listed[0].device } });
		expect(await mac.client.settle()).toEqual([]);
		nextSecond();
		const again = await phoneHello(mac.pairing, listed[0]);
		again.client.sendBytes(new Uint8Array([4]));
		expect(await mac.client.json()).toEqual({ online: { device: listed[0].device } });
		expect((await mac.client.bytes()).at(-1)).toBe(4);
	});

	it("counts each end apart: a flooding phone holds off neither the Mac nor another phone", async () => {
		const { mac, listed, phones } = await pairWithPhones(2);
		await setLimits(mac.pairing, { messagesPerSecond: 2 });
		for (let index = 0; index < 5; index++) phones[0].sendBytes(new Uint8Array([index]));
		await heldOff(phones[0], Date.now() + 1000);
		// In the same second, the other phone and the Mac each still have their own two.
		phones[1].sendBytes(new Uint8Array([20]));
		phones[1].sendBytes(new Uint8Array([21]));
		mac.client.sendBytes(prefixed(listed[1].device, [30]));
		mac.client.sendBytes(prefixed(listed[1].device, [31]));
		expect([...(await phones[1].bytes())]).toEqual([30]);
		expect([...(await phones[1].bytes())]).toEqual([31]);
		const received = [];
		for (;;) {
			const message = await mac.client.next();
			if (message instanceof Uint8Array) received.push(message.at(-1));
			if (received.includes(21)) break;
		}
		expect(received.slice(-2)).toEqual([20, 21]);
	});

	it("holds a phone off for an hour past its day's limit; the Mac still connects and removes it, and the other phone carries on", async () => {
		const { mac, listed, phones } = await pairWithPhones(2);
		await setLimits(mac.pairing, { messagesPerDay: 3 });
		for (let index = 0; index < 4; index++) {
			nextSecond();
			phones[0].sendBytes(new Uint8Array([index]));
		}
		await heldOff(phones[0], Date.now() + HOUR);
		const refused = await connect(mac.pairing);
		refused.send({ hello: { v: 1, role: "device", pairing: mac.pairing, device: listed[0].device, build: "3" } });
		await heldOff(refused, Date.now() + HOUR);

		// The Mac connects again, and removes the phone; the other phone is untouched.
		mac.client.close();
		const again = await macHello(mac);
		expect(again.ready.devices).toHaveLength(2);
		again.client.send({ removeDevice: { device: listed[0].device } });
		expect(await again.client.json()).toEqual({ ok: { what: "removeDevice" } });
		nextSecond();
		phones[1].sendBytes(new Uint8Array([9]));
		const received = await again.client.bytes();
		expect(received.at(-1)).toBe(9);
	});

	it("takes the phone back an hour later", async () => {
		const { mac, listed, phones } = await pairWithPhones();
		await setLimits(mac.pairing, { messagesPerDay: 2 });
		for (let index = 0; index < 3; index++) {
			nextSecond();
			phones[0].sendBytes(new Uint8Array([index]));
		}
		await heldOff(phones[0], Date.now() + HOUR);
		vi.setSystemTime(Date.now() + HOUR);
		// Still past the day's limit: a message holds it off again, for another hour.
		const back = await phoneHello(mac.pairing, listed[0]);
		back.client.sendBytes(new Uint8Array([3]));
		await heldOff(back.client, Date.now() + HOUR);
		// The next day, it starts again.
		vi.setSystemTime(Date.parse("2026-11-21T02:00:00Z"));
		const tomorrow = await phoneHello(mac.pairing, listed[0]);
		tomorrow.client.sendBytes(new Uint8Array([4]));
		// The Mac got the two messages within the limit, then nothing until the next day's.
		const received = [];
		while (received.at(-1) !== 4) {
			const message = await mac.client.next();
			if (message instanceof Uint8Array) received.push(message.at(-1));
		}
		expect(received).toEqual([0, 1, 4]);
	});

	it("never counts a Mac's removeDevice, closeJoin or deletePairing that takes something away, even past its limits", async () => {
		const { mac, listed } = await pairWithPhones(2);
		await openWindow(mac);
		await setLimits(mac.pairing, { messagesPerDay: 8 });
		// Whatever the Mac has spent today pairing its phones, it soon runs out.
		for (let index = 0; ; index++) {
			expect(index).toBeLessThan(8);
			nextSecond();
			mac.client.send({ take: {} });
			const answer = await mac.client.json();
			if ("busy" in answer) {
				expect(answer).toEqual({ busy: { until: Date.now() + HOUR } });
				break;
			}
			expect(answer).toEqual({ taken: { count: 0 } });
		}
		expect(await mac.client.next()).toMatchObject({ reason: "busy" });
		// Past its day's limit, the Mac is held off for its counted messages; its hello is still taken, and what takes
		// something away still passes: the window, a device, the pairing.
		const again = await macHello(mac);
		again.client.send({ closeJoin: {} });
		expect(await again.client.json()).toEqual({ ok: { what: "closeJoin" } });
		again.client.send({ removeDevice: { device: listed[0].device } });
		expect(await again.client.json()).toEqual({ ok: { what: "removeDevice" } });
		again.client.send({ deletePairing: {} });
		expect(await again.client.json()).toEqual({ ok: { what: "deletePairing" } });
	});

	it("counts a closeJoin with no window open, or a removeDevice of a device already gone, and writes nothing for them", async () => {
		const { mac, listed } = await pairWithPhones();
		await setLimits(mac.pairing, { messagesPerSecond: 3 });
		const writes = await countWrites(mac.pairing);
		for (let index = 0; index < 500; index++) mac.client.send({ closeJoin: {} });
		for (let index = 0; index < 3; index++) expect(await mac.client.json()).toEqual({ ok: { what: "closeJoin" } });
		await heldOff(mac.client, Date.now() + 1000);
		expect(writes.count).toBe(0);

		nextSecond();
		const again = await macHello(mac);
		again.client.send({ removeDevice: { device: listed[0].device } });
		expect(await again.client.json()).toEqual({ ok: { what: "removeDevice" } });
		const before = writes.count;
		for (let index = 0; index < 500; index++) again.client.send({ removeDevice: { device: listed[0].device } });
		for (let index = 0; index < 3; index++) expect(await again.client.json()).toEqual({ ok: { what: "removeDevice" } });
		await heldOff(again.client, Date.now() + 1000);
		expect(writes.count).toBe(before);
	});

	it("gives a phone that has only joined a window a smaller allowance of its own", async () => {
		const mac = await register();
		const other = await addPhone(mac);
		const listed = (await phoneHello(mac.pairing, other)).client;
		await mac.client.json();
		await standInVerifier(mac.pairing);
		const token = await openWindow(mac);
		const joining = await joinHello(mac.pairing);
		sendJoin(mac.pairing, joining, token);
		const { joined } = await joining.client.json();
		await mac.client.json();
		nextSecond();
		await setLimits(mac.pairing, { messagesPerSecond: 50 }, { messagesPerSecond: 2 });
		for (let index = 0; index < 3; index++) joining.client.sendBytes(new Uint8Array([index]));
		await heldOff(joining.client, Date.now() + 1000);
		expect(await mac.client.bytes()).toHaveLength(17);
		expect(await mac.client.bytes()).toHaveLength(17);
		expect(await mac.client.json()).toEqual({ held: { device: joined.device, until: Date.now() + 1000 } });
		expect(await mac.client.json()).toEqual({ offline: { device: joined.device } });
		// The listed phone is untouched.
		listed.sendBytes(new Uint8Array([7]));
		expect((await mac.client.bytes()).at(-1)).toBe(7);
	});

	it("counts a text message in bytes, not characters", async () => {
		const { mac, phones } = await pairWithPhones();
		await setLimits(mac.pairing, { bytesPerSecond: 1000 });
		// 400 characters, 1,200 bytes: past the limit, so held off, though it is not even a message of the protocol.
		phones[0].sendText("€".repeat(400));
		await heldOff(phones[0], Date.now() + 1000);
	});

	it("does not count what a stranger sends: one who knows the pairing's id cannot spend its limits", async () => {
		const { mac, listed, phones } = await pairWithPhones(2);
		await setLimits(mac.pairing, { messagesPerSecond: 2, bytesPerSecond: 70 * 1024 });
		const impostor = await newKey();
		for (let index = 0; index < 20; index++) {
			const stranger = await connect(mac.pairing);
			if (index % 4 === 0) {
				stranger.sendBytes(new Uint8Array(60 * 1024));
				await stranger.refused("malformed");
			} else if (index % 4 === 1) {
				stranger.send({ hello: { v: 1, role: "device", pairing: mac.pairing, device: `dev_${base64url(random(16))}`, build: "3" } });
				await stranger.refused("not-listed");
			} else {
				stranger.send({ hello: { v: 1, role: "device", pairing: mac.pairing, device: listed[1].device, build: "3" } });
				const { challenge } = await stranger.json();
				stranger.send({ proof: { signature: await impostor.sign(proofText("device", mac.pairing, listed[1].device, challenge)) } });
				await stranger.refused("signature");
			}
		}
		// The pairing's own two messages this second still pass.
		phones[0].sendBytes(new Uint8Array([1]));
		phones[0].sendBytes(new Uint8Array([2]));
		expect((await mac.client.bytes()).at(-1)).toBe(1);
		expect((await mac.client.bytes()).at(-1)).toBe(2);
	});
});

describe("what a pairing costs in writes", () => {
	it("holds off a pending pairing's Mac opening and closing windows after a small allowance, and its writes with it", async () => {
		const mac = await register();
		// The allowance alone, without the minute's windows.
		await runInDurableObject(pairingObject(mac.pairing), (instance: Pairing) => {
			instance.windowsAMinute = Number.POSITIVE_INFINITY;
		});
		const writes = await countStorageWrites(mac.pairing);
		let client = mac.client;
		let taken = 0;
		let heldFor = 0;
		for (let second = 0; second < 400 && heldFor === 0; second++) {
			nextSecond();
			if (second > 0) client = (await macHello(mac)).client;
			for (let index = 0; index < 40; index++) client.send(index % 2 === 0 ? { openJoin: { tokenHash: base64url(random(32)), expires: Date.now() + 60_000 } } : { closeJoin: {} });
			for (;;) {
				const message = await client.next();
				if (typeof message === "string" && message.startsWith('{"ok"')) taken += 1;
				else if (typeof message === "string" && message.startsWith('{"busy"')) {
					const { until } = JSON.parse(message).busy;
					// Ten a second, then busy for the rest of the second; past the day's 200, for an hour.
					if (until - Date.now() >= HOUR) heldFor = until - Date.now();
					else expect(until).toBe(Date.now() + 1000);
				} else if (typeof message === "object" && "closed" in message) break;
			}
		}
		expect(heldFor).toBe(HOUR);
		// The day's count holds the refused ones too, so fewer than 200 were taken.
		expect(taken).toBeGreaterThan(PENDING_LIMITS.messagesPerDay / 2);
		expect(taken).toBeLessThanOrEqual(PENDING_LIMITS.messagesPerDay);
		// Each window opened or closed is at most two writes (the record, and the alarm when it moves earlier), and the
		// hold and the day's counts a few more.
		expect(writes.count).toBeLessThanOrEqual(2 * taken + 10);
		// Past the hour's hold, the pairing has long been deleted: no phone was ever added.
		vi.setSystemTime(Date.now() + HOUR);
		const after = await connect(mac.pairing);
		after.send({ hello: { v: 1, role: "mac", pairing: mac.pairing, build: "120" } });
		await runDurableObjectAlarm(pairingObject(mac.pairing));
		expect(Object.keys(await after.json())).toEqual(["refused"]);
	});

	it("leaves the ordinary first pairing room inside a pending pairing's allowance, retries and all", async () => {
		const mac = await register();
		await standInVerifier(mac.pairing);
		// Three windows opened and closed again (a person who took their time), in one second.
		nextSecond();
		for (let index = 0; index < 3; index++) {
			await openWindow(mac);
			mac.client.send({ closeJoin: {} });
			expect(await mac.client.json()).toEqual({ ok: { what: "closeJoin" } });
		}
		// The next second: a window, a join, and the Mac's side of the pairing exchange on the phone's slot.
		nextSecond();
		const token = await openWindow(mac);
		const joining = await joinHello(mac.pairing);
		sendJoin(mac.pairing, joining, token);
		const { joined } = await joining.client.json();
		await mac.client.json();
		for (let index = 0; index < 6; index++) mac.client.sendBytes(prefixed(joined.device, [index]));
		for (let index = 0; index < 6; index++) expect([...(await joining.client.bytes())]).toEqual([index]);
		nextSecond();
		const device = newDeviceId();
		mac.client.send({ addDevice: { device, deviceKey: joining.key.publicKey, attestKeyId: newAttestKeyId() } });
		expect(await mac.client.json()).toEqual({ ok: { what: "addDevice" } });
		// Paired: the Mac has the whole table now.
		mac.client.send({ closeJoin: {} });
		expect(await mac.client.json()).toEqual({ ok: { what: "closeJoin" } });
		for (let index = 0; index < 50; index++) mac.client.sendBytes(prefixed(device, [index]));
		for (let index = 0; index < 50; index++) expect([...(await joining.client.bytes())]).toEqual([index]);
	});

	it("takes ten join windows a minute, a pairing and its retries with room, and holds the Mac off at the eleventh, writing nothing for it", async () => {
		const mac = await register();
		await addPhone(mac);
		// The window the phone was paired in a minute old.
		const start = NOON + MINUTE;
		for (let index = 0; index < 10; index++) {
			vi.setSystemTime(start + index * 1000);
			await openWindow(mac);
		}
		vi.setSystemTime(start + 10_000);
		const writes = await countStorageWrites(mac.pairing);
		mac.client.send({ openJoin: { tokenHash: base64url(random(32)), expires: Date.now() + 60_000 } });
		await heldOff(mac.client, start + MINUTE);
		expect(writes.count).toBe(0);
		// Its hello is still taken, and a window is still refused until the oldest of the ten is a minute old.
		const again = await macHello(mac);
		again.client.send({ openJoin: { tokenHash: base64url(random(32)), expires: Date.now() + 60_000 } });
		await heldOff(again.client, start + MINUTE);
		vi.setSystemTime(start + MINUTE);
		const later = await macHello(mac);
		await openWindow(mac, later.client);
	});

	it("lets a paired Mac that spends its whole allowance on opening and closing windows write a few dozen times, not hundreds a second", async () => {
		const mac = await register();
		await addPhone(mac);
		const start = NOON + MINUTE;
		vi.setSystemTime(start);
		const writes = await countStorageWrites(mac.pairing);
		let client = mac.client;
		let opened = 0;
		for (let second = 0; second < 5; second++) {
			vi.setSystemTime(start + second * 1000);
			if (second > 0) client = (await macHello(mac)).client;
			for (let index = 0; index < LIMITS.messagesPerSecond; index++) {
				client.send(index % 2 === 0 ? { openJoin: { tokenHash: base64url(random(32)), expires: Date.now() + 60_000 } } : { closeJoin: {} });
			}
			for (;;) {
				const message = await client.next();
				if (message === '{"ok":{"what":"openJoin"}}') opened += 1;
				if (typeof message === "object" && "closed" in message) break;
			}
		}
		expect(opened).toBe(10);
		// Each window opened and closed is a few writes (the record when it opens and closes, the alarm when it moves
		// earlier), and the reconnects and the day's counts a few more; without the minute's limit, 250 windows.
		expect(writes.count).toBeLessThanOrEqual(40);
	});

	it("writes at most a handful of times for 50 reconnects of a phone in a minute", async () => {
		// A time after the runtime's own, so that its alarms wait for the test's clock rather than fire at once.
		vi.setSystemTime(Date.parse("2027-06-01T12:00:00Z"));
		const mac = await register();
		const phone = await addPhone(mac);
		const writes = await countStorageWrites(mac.pairing);
		for (let index = 0; index < 50; index++) {
			vi.setSystemTime(Date.now() + 1200);
			const again = await phoneHello(mac.pairing, phone);
			expect(await mac.client.json()).toEqual({ online: { device: phone.device } });
			again.client.close();
			expect(await mac.client.json()).toEqual({ offline: { device: phone.device } });
		}
		// The time it was last seen, once a minute, and the ten seconds' alarm, set again at most every ten seconds.
		expect(writes.count).toBeLessThanOrEqual(8);
	});
});
