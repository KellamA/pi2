// The mailbox (docs/iphone.md 5.3, 4.3): sealed items kept for an end that is away, each until its reader says it has
// kept it (`took`, #806) or until it expires (a day, an hour for an item marked `presence`, a `"face"` request), within
// the contract's bounds.

import { runDurableObjectAlarm, runInDurableObject } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { base64url } from "../src/bytes.ts";
import { LIMITS } from "../src/limits.ts";
import type { Pairing } from "../src/pairing.ts";
import { addPhone, type Client, itemId, macHello, pairingObject, phoneHello, register, sealedItem } from "./helpers.ts";

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

/** What an end's day holds of bytes, as the pairing's counters have it now. */
async function dayBytes(pairing: string, end: string): Promise<number> {
	return runInDurableObject(pairingObject(pairing), (instance: Pairing) => {
		return (instance as unknown as { counters: { days: Record<string, { bytes: number }> } }).counters.days[end]?.bytes ?? 0;
	});
}

/** Takes, as an honest reader does, and acknowledges everything the take brought; gives how many there were. */
async function takeAndAcknowledge(client: Client): Promise<number> {
	client.send({ take: {} });
	const ids: string[] = [];
	for (;;) {
		const answer = await client.json();
		if ("mail" in answer) continue;
		expect(answer).not.toHaveProperty("busy");
		if ("taken" in answer) break;
		ids.push(answer.item?.id ?? answer.state.id);
	}
	if (ids.length > 0) {
		client.send({ took: { ids } });
		for (;;) {
			const answer = await client.json();
			if ("mail" in answer) continue;
			expect(answer).toEqual({ ok: { what: "took" } });
			break;
		}
	}
	return ids.length;
}

/** Sends a take, and gives what it handed over, up to and with its `taken`. */
async function take(client: Client): Promise<any[]> {
	client.send({ take: {} });
	const answers = [];
	for (;;) {
		const answer = await client.json();
		answers.push(answer);
		if ("taken" in answer || "busy" in answer) return answers;
	}
}

describe("the mailbox", () => {
	it("keeps a phone's items for the Mac, oldest first, handing them over at each take until the Mac says it kept them", async () => {
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

		// Not acknowledged: the same again, and still counted as waiting.
		expect(await take(client)).toEqual([
			{ item: { from: phone.device, id: first, item: base64url(sealedItem(100, 1)), presence: false } },
			{ item: { from: phone.device, id: second, item: base64url(sealedItem(120, 2)), presence: true } },
			{ taken: { count: 2 } },
		]);
		client.close();
		const again = await macHello(mac);
		expect(again.ready.mail).toBe(2);

		// Only what it names is deleted; naming it again, after a drop, does nothing more.
		tick();
		again.client.send({ took: { ids: [first] } });
		expect(await again.client.json()).toEqual({ ok: { what: "took" } });
		expect(await take(again.client)).toEqual([
			{ item: { from: phone.device, id: second, item: base64url(sealedItem(120, 2)), presence: true } },
			{ taken: { count: 1 } },
		]);
		tick();
		again.client.send({ took: { ids: [first, second] } });
		expect(await again.client.json()).toEqual({ ok: { what: "took" } });
		expect(await take(again.client)).toEqual([{ taken: { count: 0 } }]);
		again.client.send({ took: { ids: [first, second] } });
		expect(await again.client.json()).toEqual({ ok: { what: "took" } });
	});

	it("deletes only the reader's own items and state, whatever ids it names", async () => {
		const mac = await register();
		const phone = await addPhone(mac);
		const other = await addPhone(mac);
		const [forPhone, forOther, fromPhone, state] = [itemId(), itemId(), itemId(), itemId()];
		tick();
		mac.client.send({ put: { to: phone.device, id: forPhone, item: base64url(sealedItem()) } });
		await mac.client.json();
		tick();
		mac.client.send({ put: { to: other.device, id: forOther, item: base64url(sealedItem()) } });
		await mac.client.json();
		mac.client.send({ state: { device: phone.device, id: state, item: base64url(sealedItem()) } });
		await mac.client.json();
		const device = await phoneHello(mac.pairing, phone);
		expect(await mac.client.json()).toEqual({ online: { device: phone.device } });
		tick();
		device.client.send({ put: { to: "mac", id: fromPhone, item: base64url(sealedItem()) } });
		expect(await device.client.json()).toEqual({ ok: { what: "put" } });
		expect(await mac.client.json()).toEqual({ mail: {} });

		// The other phone names everything; the Mac names the phone's items and state: none of it is theirs.
		const second = await phoneHello(mac.pairing, other);
		expect(await mac.client.json()).toEqual({ online: { device: other.device } });
		tick();
		second.client.send({ took: { ids: [forPhone, fromPhone, state] } });
		expect(await second.client.json()).toEqual({ ok: { what: "took" } });
		tick();
		mac.client.send({ took: { ids: [forPhone, forOther, state] } });
		expect(await mac.client.json()).toEqual({ ok: { what: "took" } });
		expect((await take(device.client)).map((answer) => answer.item?.id ?? answer.state?.id ?? answer.taken.count)).toEqual([forPhone, state, 2]);
		expect((await take(second.client)).map((answer) => answer.item?.id ?? answer.taken.count)).toEqual([forOther, 1]);
		expect((await take(mac.client)).map((answer) => answer.item?.id ?? answer.taken.count)).toEqual([fromPhone, 1]);

		// A state the Mac replaced after it was taken has another id, and stays.
		const newer = itemId();
		mac.client.send({ state: { device: phone.device, id: newer, item: base64url(sealedItem(100, 3)) } });
		expect(await mac.client.json()).toEqual({ ok: { what: "state" } });
		expect(await device.client.json()).toEqual({ mail: {} });
		tick();
		device.client.send({ took: { ids: [forPhone, state] } });
		expect(await device.client.json()).toEqual({ ok: { what: "took" } });
		expect(await take(device.client)).toEqual([{ state: { id: newer, item: base64url(sealedItem(100, 3)) } }, { taken: { count: 1 } }]);
	});

	it("refuses a took that is not one, and closes the socket", async () => {
		const mac = await register();
		const phone = await addPhone(mac);
		for (const took of [{ ids: [] }, { ids: [itemId(), "x"] }, { through: itemId() }]) {
			const device = await phoneHello(mac.pairing, phone);
			tick();
			device.client.send({ took });
			await device.client.refused("malformed");
		}
	});

	it("hands a phone's full mailbox over in one take, and takes the took that names all of it", async () => {
		const mac = await register();
		const phone = await addPhone(mac);
		const ids = [];
		for (let index = 0; index < 100; index++) {
			tick();
			ids.push(itemId());
			mac.client.send({ put: { to: phone.device, id: ids[index], item: base64url(sealedItem(16 * 1024)) } });
			expect(await mac.client.json()).toEqual({ ok: { what: "put" } });
		}
		const state = itemId();
		mac.client.send({ state: { device: phone.device, id: state, item: base64url(sealedItem(16 * 1024)) } });
		expect(await mac.client.json()).toEqual({ ok: { what: "state" } });
		const device = await phoneHello(mac.pairing, phone);
		// Some 2.2 MB, past the second's 2 MB: counted against the day alone, so the take and the took after it pass.
		const taken = await take(device.client);
		expect(taken.at(-1)).toEqual({ taken: { count: 101 } });
		expect(JSON.stringify(taken).length).toBeGreaterThan(LIMITS.bytesPerSecond);
		device.client.send({ took: { ids: [...ids, state] } });
		expect(await device.client.json()).toEqual({ ok: { what: "took" } });
		expect(await take(device.client)).toEqual([{ taken: { count: 0 } }]);
	});

	it("charges a reader for what a take hands over again, never the first time, so that one that never acknowledges is held off", async () => {
		const mac = await register();
		const phone = await addPhone(mac);
		const device = await phoneHello(mac.pairing, phone);
		await mac.client.json();
		for (let index = 0; index < 10; index++) {
			tick();
			device.client.send({ put: { to: "mac", id: itemId(), item: base64url(sealedItem(16 * 1024)) } });
			expect(await device.client.json()).toEqual({ ok: { what: "put" } });
			expect(await mac.client.json()).toEqual({ mail: {} });
		}
		// A day of 1 MB: the first take is the writer's, free to the Mac; each after it hands the same 220 KB over again,
		// charged to the Mac, so the sixth fills its day and the next message is held off.
		await runInDurableObject(pairingObject(mac.pairing), (instance: Pairing) => {
			instance.limits = { ...LIMITS, bytesPerDay: 1024 * 1024 };
		});
		const before = await dayBytes(mac.pairing, "mac");
		let takes = 0;
		for (;;) {
			vi.setSystemTime(Date.now() + 1000);
			const answers = await take(mac.client);
			if ("busy" in answers[0]) {
				expect(answers).toEqual([{ busy: { until: Date.now() + HOUR } }]);
				break;
			}
			expect(answers.at(-1)).toEqual({ taken: { count: 10 } });
			if (takes === 0) expect(await dayBytes(mac.pairing, "mac")).toBe(before + JSON.stringify({ take: {} }).length);
			takes += 1;
		}
		expect(takes).toBe(6);
		expect(await mac.client.next()).toMatchObject({ reason: "busy" });
	});

	it("never spends the Mac's day on what phones write to it, when it takes and acknowledges", async () => {
		const mac = await register();
		const phones = [await addPhone(mac), await addPhone(mac)];
		const devices = [];
		for (const phone of phones) {
			devices.push(await phoneHello(mac.pairing, phone));
			expect(await mac.client.json()).toEqual({ online: { device: phone.device } });
		}
		// A day of 2 MB for every end: two phones write 1.3 MB each to the Mac, which, charged for it, would be past its day
		// at the ninth round.
		await runInDurableObject(pairingObject(mac.pairing), (instance: Pairing) => {
			instance.limits = { ...LIMITS, bytesPerDay: 2 * 1024 * 1024 };
		});
		for (let round = 0; round < 15; round++) {
			vi.setSystemTime(Date.now() + 1000);
			for (const device of devices) {
				for (let index = 0; index < 4; index++) {
					tick();
					device.client.send({ put: { to: "mac", id: itemId(), item: base64url(sealedItem(16 * 1024)) } });
					expect(await device.client.json()).toEqual({ ok: { what: "put" } });
				}
			}
			tick();
			expect(await takeAndAcknowledge(mac.client)).toBe(8);
		}
		expect(await dayBytes(mac.pairing, "mac")).toBeLessThan(16 * 1024);
		for (const phone of phones) expect(await dayBytes(mac.pairing, phone.device)).toBeGreaterThan(1024 * 1024);
	});

	it("never spends a phone's day on what the Mac writes to it, when it takes and acknowledges", async () => {
		const mac = await register();
		const phone = await addPhone(mac);
		const device = await phoneHello(mac.pairing, phone);
		expect(await mac.client.json()).toEqual({ online: { device: phone.device } });
		for (let round = 0; round < 10; round++) {
			vi.setSystemTime(Date.now() + 1000);
			for (let index = 0; index < 4; index++) {
				tick();
				mac.client.send({ put: { to: phone.device, id: itemId(), item: base64url(sealedItem(16 * 1024)) } });
				expect(await mac.client.json()).toEqual({ ok: { what: "put" } });
			}
			mac.client.send({ state: { device: phone.device, id: itemId(), item: base64url(sealedItem(16 * 1024)) } });
			expect(await mac.client.json()).toEqual({ ok: { what: "state" } });
			tick();
			expect(await takeAndAcknowledge(device.client)).toBe(5);
		}
		expect(await dayBytes(mac.pairing, phone.device)).toBeLessThan(16 * 1024);
		expect(await dayBytes(mac.pairing, "mac")).toBeGreaterThan(800 * 1024);
	});

	it("charges a state handed over again, and not a new one in its place", async () => {
		const mac = await register();
		const phone = await addPhone(mac);
		const device = await phoneHello(mac.pairing, phone);
		expect(await mac.client.json()).toEqual({ online: { device: phone.device } });
		mac.client.send({ state: { device: phone.device, id: itemId(), item: base64url(sealedItem(16 * 1024)) } });
		expect(await mac.client.json()).toEqual({ ok: { what: "state" } });
		expect(await device.client.json()).toEqual({ mail: {} });
		const start = await dayBytes(mac.pairing, phone.device);
		const take1 = JSON.stringify({ take: {} }).length;
		tick();
		const first = await take(device.client);
		expect(await dayBytes(mac.pairing, phone.device)).toBe(start + take1);
		tick();
		expect(await take(device.client)).toEqual(first);
		expect(await dayBytes(mac.pairing, phone.device)).toBe(start + 2 * take1 + JSON.stringify(first[0]).length);
		// A new state in its place has not been handed over: free again.
		mac.client.send({ state: { device: phone.device, id: itemId(), item: base64url(sealedItem(16 * 1024)) } });
		expect(await mac.client.json()).toEqual({ ok: { what: "state" } });
		expect(await device.client.json()).toEqual({ mail: {} });
		tick();
		await take(device.client);
		expect(await dayBytes(mac.pairing, phone.device)).toBe(start + 3 * take1 + JSON.stringify(first[0]).length);
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
		// Handed over and never acknowledged, they expire all the same.
		const taking = await macHello(mac);
		expect((await take(taking.client)).at(-1)).toEqual({ taken: { count: 2 } });
		taking.client.close();

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
