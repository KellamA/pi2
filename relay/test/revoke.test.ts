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
		mac.client.send({ removeDevice: { device: phone.device } });
		expect(await mac.client.json()).toEqual({ refused: { what: "removeDevice", why: "unknown-device" } });
	});

	it("unties the device's App Attest key, which may then join elsewhere", async () => {
		const mac = await register();
		const phone = await addPhone(mac);
		const elsewhere = await register();
		await standInVerifier(elsewhere.pairing);
		const token = await openWindow(elsewhere);
		const before = await joinHello(elsewhere.pairing);
		before.keyId = phone.attestKeyId;
		sendJoin(elsewhere.pairing, before, token);
		await before.client.refused("attest-key-taken");
		mac.client.send({ removeDevice: { device: phone.device } });
		expect(await mac.client.json()).toEqual({ ok: { what: "removeDevice" } });
		const after = await joinHello(elsewhere.pairing);
		after.keyId = phone.attestKeyId;
		sendJoin(elsewhere.pairing, after, token);
		expect(Object.keys(await after.client.json())).toEqual(["joined"]);
	});
});

describe("leave", () => {
	it("refuses a leave not signed with the device's key, and keeps the device", async () => {
		const mac = await register();
		const phone = await addPhone(mac);
		const device = await phoneHello(mac.pairing, phone);
		device.client.send({ leave: { signature: await (await newKey()).sign("anything") } });
		await device.client.refused("signature");
		const again = await phoneHello(mac.pairing, phone);
		expect(again.ready.mac).toBe(true);
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
		client.send({ leave: { signature: await phone.key.sign(proofText("device", mac.pairing, phone.device, challenge)) } });
		await client.refused("signature");

		const second = await connect(mac.pairing);
		second.send({ hello: { v: 1, role: "device", pairing: mac.pairing, device: phone.device, build: "3" } });
		const fresh = (await second.json()).challenge;
		second.send({ proof: { signature: await phone.key.sign(proofText("device", mac.pairing, phone.device, fresh)) } });
		await second.json();
		await mac.client.json();
		second.send({ leave: { signature: await phone.key.sign(proofText("leave", mac.pairing, phone.device, fresh)) } });
		await second.refused("left");
		expect(await mac.client.json()).toEqual({ left: { device: phone.device } });
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
		leaving.send({ leave: { signature: await phone.key.sign(proofText("leave", mac.pairing, phone.device, challenge)) } });
		await leaving.refused("left");

		const first = await macHello(mac);
		expect(first.ready).toMatchObject({ devices: [], left: [phone.device] });
		first.client.close();
		const second = await macHello(mac);
		expect(second.ready).toMatchObject({ left: [] });
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
		joining.keyId = phone.attestKeyId;
		sendJoin(elsewhere.pairing, joining, token);
		expect(Object.keys(await joining.client.json())).toEqual(["joined"]);
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
