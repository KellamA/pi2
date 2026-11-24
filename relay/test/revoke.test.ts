// Revocation, leaving and deleting (docs/iphone.md 3.6, 5.3): what the relay keeps of a device or a pairing goes with
// it, and an App Attest key it tied is free again; and a pairing nobody uses is deleted by itself.

import { runDurableObjectAlarm, runInDurableObject } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { base64url, concat, fromBase64url } from "../src/bytes.ts";
import type { Pairing } from "../src/pairing.ts";
import { proofText } from "../src/protocol.ts";
import {
	addPhone,
	connect,
	itemId,
	leaveMessage,
	joinHello,
	macHello,
	newKey,
	openWindow,
	pairingObject,
	phoneHello,
	register,
	sealedItem,
	sendJoin,
	standInVerifier,
} from "./helpers.ts";

beforeEach(() => {
	vi.useFakeTimers({ toFake: ["Date"] });
	vi.setSystemTime(Date.parse("2026-11-20T12:00:00Z"));
});
afterEach(() => {
	vi.useRealTimers();
});

const DAY = 24 * 60 * 60 * 1000;

async function stored(pairing: string): Promise<Map<string, unknown>> {
	return runInDurableObject(pairingObject(pairing), async (_: Pairing, state) => state.storage.list());
}

async function mailboxRows(pairing: string): Promise<number> {
	return runInDurableObject(pairingObject(pairing), async (_: Pairing, state) => {
		const items = state.storage.sql.exec<{ n: number }>("SELECT count(*) AS n FROM items").one().n;
		const states = state.storage.sql.exec<{ n: number }>("SELECT count(*) AS n FROM states").one().n;
		return items + states;
	});
}

describe("removeDevice: revocation", () => {
	it("closes the device's socket, refuses it from then on, and deletes its push token and mailbox", async () => {
		const mac = await register();
		const phone = await addPhone(mac);
		const other = await addPhone(mac);
		const device = await phoneHello(mac.pairing, phone);
		await mac.client.json();
		device.client.send({ token: { apns: "ab".repeat(32), environment: "production" } });
		expect(await device.client.json()).toEqual({ ok: { what: "token" } });
		const devices = (await stored(mac.pairing)).get("devices") as Record<string, { token: unknown }>;
		expect(devices[phone.device].token).toEqual({ apns: "ab".repeat(32), environment: "production" });
		device.client.send({ put: { to: "mac", id: itemId(), item: base64url(sealedItem()) } });
		await device.client.json();
		expect(await mac.client.json()).toEqual({ mail: {} });
		mac.client.send({ put: { to: phone.device, id: itemId(), item: base64url(sealedItem()) } });
		await mac.client.json();
		expect(await device.client.json()).toEqual({ mail: {} });
		mac.client.send({ put: { to: other.device, id: itemId(), item: base64url(sealedItem()) } });
		await mac.client.json();
		expect(await mailboxRows(mac.pairing)).toBe(3);

		mac.client.send({ removeDevice: { device: phone.device } });
		await device.client.refused("removed");
		expect(await mac.client.json()).toEqual({ ok: { what: "removeDevice" } });
		// What was for it and from it is gone; the other phone's item stays.
		expect(await mailboxRows(mac.pairing)).toBe(1);
		expect(Object.keys((await stored(mac.pairing)).get("devices") as object)).toEqual([other.device]);

		const again = await connect(mac.pairing);
		again.send({ hello: { v: 1, role: "device", pairing: mac.pairing, device: phone.device, build: "3" } });
		await again.refused("not-listed");
		mac.client.sendBytes(concat(fromBase64url(phone.device.slice(4), 16)!, new Uint8Array([1])));
		expect(await mac.client.json()).toEqual({ offline: { device: phone.device } });
		// Asked again, it is done: the device is gone.
		mac.client.send({ removeDevice: { device: phone.device } });
		expect(await mac.client.json()).toEqual({ ok: { what: "removeDevice" } });
	});

	it("cuts the device's socket even when untying its App Attest key fails, and passes nothing of it to the Mac", async () => {
		const mac = await register();
		const phone = await addPhone(mac);
		const device = await phoneHello(mac.pairing, phone);
		expect(await mac.client.json()).toEqual({ online: { device: phone.device } });
		let release = () => {};
		const held = new Promise<void>((resolve) => (release = resolve));
		await runInDurableObject(pairingObject(mac.pairing), (instance: Pairing) => {
			instance.keyObject = () => ({
				tie: async () => true,
				retie: async () => true,
				untie: async () => {
					await held;
					throw new Error("the App Attest key's object is not answering");
				},
			});
		});
		mac.client.send({ removeDevice: { device: phone.device } });
		// The phone sends while the relay waits on the key's object: none of it may reach the Mac.
		device.client.sendBytes(new Uint8Array([1, 2, 3]));
		device.client.send({ put: { to: "mac", id: itemId(), item: base64url(sealedItem()) } });
		await device.client.refused("removed");
		release();
		expect(await mac.client.json()).toEqual({ ok: { what: "removeDevice" } });
		expect(await mac.client.settle()).toEqual([]);
		mac.client.send({ removeDevice: { device: phone.device } });
		expect(await mac.client.json()).toEqual({ ok: { what: "removeDevice" } });
	});

	it("refuses a ready socket whose device is gone, as things stand when it sends", async () => {
		const mac = await register();
		const phone = await addPhone(mac);
		const device = await phoneHello(mac.pairing, phone);
		expect(await mac.client.json()).toEqual({ online: { device: phone.device } });
		// As if the record went while the socket was still open (a removal the socket's closing has not reached yet).
		await runInDurableObject(pairingObject(mac.pairing), (instance: Pairing) => {
			delete (instance as unknown as { devices: Record<string, unknown> }).devices[phone.device];
		});
		device.client.sendBytes(new Uint8Array([1]));
		await device.client.refused("removed");
		expect(await mac.client.settle()).toEqual([]);
	});

	it("unties the device's App Attest key, which may then join elsewhere", async () => {
		const mac = await register();
		const phone = await addPhone(mac);
		const elsewhere = await register();
		await standInVerifier(elsewhere.pairing);
		const token = await openWindow(elsewhere);
		const before = await joinHello(elsewhere.pairing);
		before.keyId = phone.relayKeyId;
		sendJoin(elsewhere.pairing, before, token);
		await before.client.refused("attest-key-taken");
		mac.client.send({ removeDevice: { device: phone.device } });
		expect(await mac.client.json()).toEqual({ ok: { what: "removeDevice" } });
		const after = await joinHello(elsewhere.pairing);
		after.keyId = phone.relayKeyId;
		sendJoin(elsewhere.pairing, after, token);
		expect(Object.keys(await after.client.json())).toEqual(["joined"]);
	});
});

describe("leave", () => {
	it("refuses a leave not signed with the device's key, and keeps the device", async () => {
		const mac = await register();
		const phone = await addPhone(mac);
		const device = await phoneHello(mac.pairing, phone);
		const stranger = await newKey();
		device.client.send({ leave: { signature: await stranger.sign("anything"), at: Date.now(), notice: await phone.key.sign("a notice") } });
		await device.client.refused("signature");
		const again = await phoneHello(mac.pairing, phone);
		expect(again.ready.mac).toBe(true);
	});

	it("refuses a leave without its time and notice for the Mac, or with either not of its form, and keeps the device", async () => {
		const mac = await register();
		const phone = await addPhone(mac);
		const forms = [
			(leave: Record<string, unknown>) => ({ signature: leave.signature }),
			(leave: Record<string, unknown>) => ({ signature: leave.signature, at: leave.at }),
			(leave: Record<string, unknown>) => ({ signature: leave.signature, notice: leave.notice }),
			(leave: Record<string, unknown>) => ({ ...leave, at: 0 }),
			(leave: Record<string, unknown>) => ({ ...leave, at: -1 }),
			(leave: Record<string, unknown>) => ({ ...leave, at: 1.5 }),
			(leave: Record<string, unknown>) => ({ ...leave, at: String(leave.at) }),
			// Past the year 2286, which RemoteKit's client would not read in `left`.
			(leave: Record<string, unknown>) => ({ ...leave, at: 10_000_000_000_000 }),
			(leave: Record<string, unknown>) => ({ ...leave, notice: base64url(new Uint8Array(63)) }),
			(leave: Record<string, unknown>) => ({ ...leave, notice: base64url(new Uint8Array(65)) }),
			(leave: Record<string, unknown>) => ({ ...leave, notice: null }),
			(leave: Record<string, unknown>) => ({ ...leave, device: phone.device }),
		];
		// Read before anything is checked: the challenge signed does not matter to a leave not of its form.
		const { leave } = await leaveMessage(mac.pairing, phone, base64url(new Uint8Array(32)));
		for (const form of forms) {
			const device = await phoneHello(mac.pairing, phone);
			expect(await mac.client.json()).toEqual({ online: { device: phone.device } });
			device.client.send({ leave: form(leave) });
			await device.client.refused("malformed");
		}
		expect(Object.keys((await stored(mac.pairing)).get("devices") as object)).toEqual([phone.device]);
	});

	it("removes a device that leaves, signed over its connection's challenge, and tells the connected Mac", async () => {
		const mac = await register();
		const phone = await addPhone(mac);
		const client = await connect(mac.pairing);
		client.send({ hello: { v: 1, role: "device", pairing: mac.pairing, device: phone.device, build: "3" } });
		const { challenge } = await client.json();
		client.send({ proof: { signature: await phone.key.sign(proofText("device", mac.pairing, phone.device, challenge)) } });
		await client.json();
		expect(await mac.client.json()).toEqual({ online: { device: phone.device } });
		// A proof's signature is not a leave's: what is signed names what it is for.
		const proved = await leaveMessage(mac.pairing, phone, challenge);
		client.send({ leave: { ...proved.leave, signature: await phone.key.sign(proofText("device", mac.pairing, phone.device, challenge)) } });
		await client.refused("signature");

		const second = await connect(mac.pairing);
		second.send({ hello: { v: 1, role: "device", pairing: mac.pairing, device: phone.device, build: "3" } });
		const fresh = (await second.json()).challenge;
		second.send({ proof: { signature: await phone.key.sign(proofText("device", mac.pairing, phone.device, fresh)) } });
		await second.json();
		await mac.client.json();
		const { leave } = await leaveMessage(mac.pairing, phone, fresh);
		second.send({ leave });
		await second.refused("left");
		// The time and the notice go to the Mac as the phone gave them: the relay cannot check the notice, the Mac does.
		expect(await mac.client.json()).toEqual({ left: { device: phone.device, at: leave.at, notice: leave.notice } });
		expect((await stored(mac.pairing)).get("devices")).toEqual({});
	});

	it("tells a Mac that was away at its next connection, once", async () => {
		const mac = await register();
		const phone = await addPhone(mac);
		mac.client.close();
		const device = await phoneHello(mac.pairing, phone);
		const client = await connect(mac.pairing);
		void client;
		device.client.close();
		const leaving = await connect(mac.pairing);
		leaving.send({ hello: { v: 1, role: "device", pairing: mac.pairing, device: phone.device, build: "3" } });
		const { challenge } = await leaving.json();
		leaving.send({ proof: { signature: await phone.key.sign(proofText("device", mac.pairing, phone.device, challenge)) } });
		expect(await leaving.json()).toEqual({ ready: { mac: false, mail: 0 } });
		const { leave } = await leaveMessage(mac.pairing, phone, challenge, Date.now() - 1000);
		leaving.send({ leave });
		await leaving.refused("left");
		// Kept with the time and the notice, for the Mac to check when it comes; written once the slot is gone.
		const left = { device: phone.device, at: leave.at, notice: leave.notice };
		await vi.waitFor(async () => expect((await stored(mac.pairing)).get("meta")).toMatchObject({ left: [left] }));

		const first = await macHello(mac);
		expect(first.ready).toMatchObject({ devices: [], left: [left] });
		first.client.close();
		const second = await macHello(mac);
		expect(second.ready).toMatchObject({ left: [] });
		expect((await stored(mac.pairing)).get("meta")).toMatchObject({ left: [] });
	});
});

describe("deleting", () => {
	it("deletes a pairing the Mac asks to: every socket closed, everything kept gone, its keys untied", async () => {
		const mac = await register();
		const phone = await addPhone(mac);
		const device = await phoneHello(mac.pairing, phone);
		await mac.client.json();
		mac.client.send({ put: { to: phone.device, id: itemId(), item: base64url(sealedItem()) } });
		await mac.client.json();
		await device.client.json();
		mac.client.send({ deletePairing: {} });
		expect(await mac.client.json()).toEqual({ ok: { what: "deletePairing" } });
		await mac.client.refused("deleted");
		await device.client.refused("deleted");
		expect([...(await stored(mac.pairing)).keys()]).toEqual([]);
		const hello = await connect(mac.pairing);
		hello.send({ hello: { v: 1, role: "mac", pairing: mac.pairing, build: "120" } });
		await hello.refused("unknown-pairing");

		const elsewhere = await register();
		await standInVerifier(elsewhere.pairing);
		const token = await openWindow(elsewhere);
		const joining = await joinHello(elsewhere.pairing);
		joining.keyId = phone.relayKeyId;
		sendJoin(elsewhere.pairing, joining, token);
		expect(Object.keys(await joining.client.json())).toEqual(["joined"]);
	});

	it("deletes a pairing even when untying its keys fails, and such a tie goes by itself after a week", async () => {
		const mac = await register();
		const phone = await addPhone(mac);
		const device = await phoneHello(mac.pairing, phone);
		await mac.client.json();
		await runInDurableObject(pairingObject(mac.pairing), (instance: Pairing) => {
			instance.keyObject = () => ({
				tie: async () => true,
				retie: async () => true,
				untie: async () => Promise.reject(new Error("not answering")),
			});
		});
		mac.client.send({ deletePairing: {} });
		expect(await mac.client.json()).toEqual({ ok: { what: "deletePairing" } });
		await mac.client.refused("deleted");
		await device.client.refused("deleted");
		expect([...(await stored(mac.pairing)).keys()]).toEqual([]);

		// The relay's key is still tied, so another pairing is refused it, until the tie expires.
		const elsewhere = await register();
		await standInVerifier(elsewhere.pairing);
		const window = await openWindow(elsewhere);
		const before = await joinHello(elsewhere.pairing);
		before.keyId = phone.relayKeyId;
		sendJoin(elsewhere.pairing, before, window);
		await before.client.refused("attest-key-taken");
		vi.setSystemTime(Date.now() + 7 * 24 * 60 * 60 * 1000);
		const again = await register();
		await standInVerifier(again.pairing);
		const token = await openWindow(again);
		const after = await joinHello(again.pairing);
		after.keyId = phone.relayKeyId;
		sendJoin(again.pairing, after, token);
		expect(Object.keys(await after.client.json())).toEqual(["joined"]);
	});

	it("deletes a pending pairing that no device was added to after 15 minutes", async () => {
		const mac = await register();
		mac.client.close();
		vi.setSystemTime(Date.now() + 15 * 60 * 1000 - 1);
		await runDurableObjectAlarm(pairingObject(mac.pairing));
		const before = await macHello(mac);
		expect(before.ready.pending).toBe(true);
		before.client.close();
		vi.setSystemTime(Date.now() + 1);
		await runDurableObjectAlarm(pairingObject(mac.pairing));
		expect((await stored(mac.pairing)).size).toBe(0);
		const after = await connect(mac.pairing);
		after.send({ hello: { v: 1, role: "mac", pairing: mac.pairing, build: "120" } });
		await after.refused("unknown-pairing");
	});

	it("keeps a pairing with a device past 15 minutes, and deletes it after 60 days with no connection", async () => {
		const mac = await register();
		await addPhone(mac);
		mac.client.close();
		vi.setSystemTime(Date.now() + 30 * 60 * 1000);
		await runDurableObjectAlarm(pairingObject(mac.pairing));
		const kept = await macHello(mac);
		expect(kept.ready.pending).toBe(false);
		// Connected for 59 days: still kept, and seen.
		vi.setSystemTime(Date.now() + 59 * DAY);
		await runDurableObjectAlarm(pairingObject(mac.pairing));
		kept.client.close();
		vi.setSystemTime(Date.now() + 60 * DAY - 1);
		await runDurableObjectAlarm(pairingObject(mac.pairing));
		expect((await stored(mac.pairing)).size).toBeGreaterThan(0);
		vi.setSystemTime(Date.now() + 1);
		await runDurableObjectAlarm(pairingObject(mac.pairing));
		expect((await stored(mac.pairing)).size).toBe(0);
	});
});
