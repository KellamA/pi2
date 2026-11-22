// The mailbox (docs/iphone.md 5.3, 4.3): sealed items kept for an end that is away, each until taken or until it
// expires (a day, an hour for an item marked `presence`, a `"face"` request), within the contract's bounds.

import { runDurableObjectAlarm } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { base64url } from "../src/bytes.ts";
import { addPhone, itemId, macHello, pairingObject, phoneHello, register, sealedItem } from "./helpers.ts";

beforeEach(() => {
	vi.useFakeTimers({ toFake: ["Date"] });
	vi.setSystemTime(Date.parse("2026-11-20T12:00:00Z"));
});
afterEach(() => {
	vi.useRealTimers();
});

const HOUR = 60 * 60 * 1000;

/** Moves the clock on before each message, so that a test's many messages stay within 100 a second (6.6). */
function tick(): void {
	vi.setSystemTime(Date.now() + 20);
}

describe("the mailbox", () => {
	it("keeps a phone's items for the Mac until it takes them, oldest first, and then has none", async () => {
		const mac = await register();
		const phone = await addPhone(mac);
		const device = await phoneHello(mac.pairing, phone);
		await mac.client.json();
		mac.client.close();
		expect(await device.client.json()).toEqual({ mac: { online: false } });
		const [first, second] = [itemId(), itemId()];
		tick();
		device.client.send({ put: { to: "mac", id: first, item: base64url(sealedItem(100, 1)) } });
		expect(await device.client.json()).toEqual({ ok: { what: "put" } });
		tick();
		device.client.send({ put: { to: "mac", id: second, item: base64url(sealedItem(120, 2)), presence: true } });
		expect(await device.client.json()).toEqual({ ok: { what: "put" } });

		const { client, ready } = await macHello(mac);
		expect(ready.mail).toBe(2);
		client.send({ take: {} });
		expect(await client.json()).toEqual({ item: { from: phone.device, id: first, item: base64url(sealedItem(100, 1)), presence: false } });
		expect(await client.json()).toEqual({ item: { from: phone.device, id: second, item: base64url(sealedItem(120, 2)), presence: true } });
		expect(await client.json()).toEqual({ taken: { count: 2 } });
		client.send({ take: {} });
		expect(await client.json()).toEqual({ taken: { count: 0 } });
	});

	it("keeps the Mac's items and latest state for a phone, and tells a connected reader that mail came", async () => {
		const mac = await register();
		const phone = await addPhone(mac);
		const item = itemId();
		tick();
		mac.client.send({ put: { to: phone.device, id: item, item: base64url(sealedItem()) } });
		expect(await mac.client.json()).toEqual({ ok: { what: "put" } });
		mac.client.send({ state: { device: phone.device, id: itemId(), item: base64url(sealedItem(100, 1)) } });
		expect(await mac.client.json()).toEqual({ ok: { what: "state" } });
		const latest = itemId();
		mac.client.send({ state: { device: phone.device, id: latest, item: base64url(sealedItem(100, 2)) } });
		expect(await mac.client.json()).toEqual({ ok: { what: "state" } });

		const device = await phoneHello(mac.pairing, phone);
		expect(device.ready.mail).toBe(1);
		device.client.send({ take: {} });
		expect(await device.client.json()).toEqual({ item: { from: "mac", id: item, item: base64url(sealedItem()), presence: false } });
		expect(await device.client.json()).toEqual({ state: { id: latest, item: base64url(sealedItem(100, 2)) } });
		expect(await device.client.json()).toEqual({ taken: { count: 2 } });

		tick();
		mac.client.send({ put: { to: phone.device, id: itemId(), item: base64url(sealedItem()) } });
		expect(await device.client.json()).toEqual({ mail: {} });
	});

	it("deletes an item marked presence (a \"face\" request) after an hour, and any other after a day", async () => {
		const mac = await register();
		const phone = await addPhone(mac);
		const device = await phoneHello(mac.pairing, phone);
		await mac.client.json();
		mac.client.close();
		expect(await device.client.json()).toEqual({ mac: { online: false } });
		const [hour, day] = [itemId(), itemId()];
		tick();
		device.client.send({ put: { to: "mac", id: hour, item: base64url(sealedItem()), presence: true } });
		await device.client.json();
		tick();
		device.client.send({ put: { to: "mac", id: day, item: base64url(sealedItem()) } });
		await device.client.json();

		vi.setSystemTime(Date.now() + HOUR);
		await runDurableObjectAlarm(pairingObject(mac.pairing));
		const later = await macHello(mac);
		expect(later.ready.mail).toBe(1);
		later.client.close();

		vi.setSystemTime(Date.now() + 23 * HOUR - 1);
		const before = await macHello(mac);
		expect(before.ready.mail).toBe(1);
		before.client.close();
		vi.setSystemTime(Date.now() + 1);
		await runDurableObjectAlarm(pairingObject(mac.pairing));
		const after = await macHello(mac);
		expect(after.ready.mail).toBe(0);
	});

	it("refuses an item id already waiting for the same reader", async () => {
		const mac = await register();
		const phone = await addPhone(mac);
		const id = itemId();
		tick();
		mac.client.send({ put: { to: phone.device, id, item: base64url(sealedItem()) } });
		await mac.client.json();
		tick();
		mac.client.send({ put: { to: phone.device, id, item: base64url(sealedItem()) } });
		expect(await mac.client.json()).toEqual({ refused: { what: "put", why: "exists" } });
	});

	it("refuses an item for a device not listed, and a phone's item for anyone but the Mac", async () => {
		const mac = await register();
		const phone = await addPhone(mac);
		const other = await addPhone(mac);
		tick();
		mac.client.send({ put: { to: "dev_AAAAAAAAAAAAAAAAAAAAAA", id: itemId(), item: base64url(sealedItem()) } });
		expect(await mac.client.json()).toEqual({ refused: { what: "put", why: "unknown-device" } });
		const device = await phoneHello(mac.pairing, phone);
		tick();
		device.client.send({ put: { to: other.device, id: itemId(), item: base64url(sealedItem()) } });
		await device.client.refused("malformed");
	});

	it("takes only what looks like a sealed item: 81 bytes to 16 KB, starting as an uncompressed point", async () => {
		const mac = await register();
		const phone = await addPhone(mac);
		for (const item of [sealedItem(80), sealedItem(16 * 1024 + 1), sealedItem(100).fill(5)]) {
			tick();
			mac.client.send({ put: { to: phone.device, id: itemId(), item: base64url(item) } });
			await mac.client.refused("malformed");
			mac.client = (await macHello(mac)).client;
		}
		tick();
		mac.client.send({ put: { to: phone.device, id: itemId(), item: base64url(sealedItem(16 * 1024)) } });
		expect(await mac.client.json()).toEqual({ ok: { what: "put" } });
	});

	it("holds at most 50 items and 256 KB from one phone for the Mac", async () => {
		const mac = await register();
		const phone = await addPhone(mac);
		const other = await addPhone(mac);
		const device = await phoneHello(mac.pairing, phone);
		for (let index = 0; index < 50; index++) {
			tick();
			device.client.send({ put: { to: "mac", id: itemId(), item: base64url(sealedItem(100)) } });
			expect(await device.client.json()).toEqual({ ok: { what: "put" } });
		}
		tick();
		device.client.send({ put: { to: "mac", id: itemId(), item: base64url(sealedItem(100)) } });
		expect(await device.client.json()).toEqual({ refused: { what: "put", why: "mailbox-full" } });

		const second = await phoneHello(mac.pairing, other);
		for (let index = 0; index < 16; index++) {
			tick();
			second.client.send({ put: { to: "mac", id: itemId(), item: base64url(sealedItem(16 * 1024)) } });
			expect(await second.client.json()).toEqual({ ok: { what: "put" } });
		}
		tick();
		second.client.send({ put: { to: "mac", id: itemId(), item: base64url(sealedItem(100)) } });
		expect(await second.client.json()).toEqual({ refused: { what: "put", why: "mailbox-full" } });
	});

	it("holds at most 200 items and 1 MB for the Mac in all", async () => {
		const mac = await register();
		const phones = [];
		const listed = [];
		for (let index = 0; index < 5; index++) listed.push(await addPhone(mac));
		for (const phone of listed) phones.push(await phoneHello(mac.pairing, phone));
		// Four phones' 50 small items each make 200.
		for (const phone of phones.slice(0, 4)) {
			for (let index = 0; index < 50; index++) {
				tick();
				phone.client.send({ put: { to: "mac", id: itemId(), item: base64url(sealedItem(100)) } });
				expect(await phone.client.json()).toEqual({ ok: { what: "put" } });
			}
		}
		phones[4].client.send({ put: { to: "mac", id: itemId(), item: base64url(sealedItem(100)) } });
		expect(await phones[4].client.json()).toEqual({ refused: { what: "put", why: "mailbox-full" } });
	});

	it("holds at most 1 MB for the Mac in all", async () => {
		const mac = await register();
		const phones = [];
		const listed = [];
		for (let index = 0; index < 5; index++) listed.push(await addPhone(mac));
		for (const phone of listed) phones.push(await phoneHello(mac.pairing, phone));
		// Each phone may leave 256 KB: four fill the megabyte, less what is not a whole item.
		for (const phone of phones.slice(0, 4)) {
			for (let index = 0; index < 16; index++) {
				tick();
				phone.client.send({ put: { to: "mac", id: itemId(), item: base64url(sealedItem(16 * 1024)) } });
				expect(await phone.client.json()).toEqual({ ok: { what: "put" } });
			}
		}
		phones[4].client.send({ put: { to: "mac", id: itemId(), item: base64url(sealedItem(100)) } });
		expect(await phones[4].client.json()).toEqual({ refused: { what: "put", why: "mailbox-full" } });
	});

	it("holds at most 100 items for a phone", async () => {
		const mac = await register();
		const phone = await addPhone(mac);
		for (let index = 0; index < 100; index++) {
			tick();
			mac.client.send({ put: { to: phone.device, id: itemId(), item: base64url(sealedItem(100)) } });
			expect(await mac.client.json()).toEqual({ ok: { what: "put" } });
		}
		tick();
		mac.client.send({ put: { to: phone.device, id: itemId(), item: base64url(sealedItem(100)) } });
		expect(await mac.client.json()).toEqual({ refused: { what: "put", why: "mailbox-full" } });
	});
});
