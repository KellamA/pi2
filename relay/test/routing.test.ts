// Routing (docs/iphone.md 5.3, "Data"): a phone's binary messages reach its pairing's Mac with its 16-byte id in front,
// the Mac's reach the phone that id names with the id taken off, and nothing reaches another pairing; with the
// notices each end is sent when the other comes and goes.

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { base64url, concat, fromBase64url, random } from "../src/bytes.ts";
import { addPhone, connect, macHello, phoneHello, register } from "./helpers.ts";

beforeEach(() => {
	vi.useFakeTimers({ toFake: ["Date"] });
	vi.setSystemTime(Date.parse("2026-11-20T12:00:00Z"));
});
afterEach(() => {
	vi.useRealTimers();
});

function id(device: string): Uint8Array {
	return fromBase64url(device.slice(4), 16)!;
}

describe("routing", () => {
	it("passes each phone's bytes to the Mac with its id in front, and the Mac's to the phone its id names", async () => {
		const mac = await register();
		const [a, b] = [await addPhone(mac), await addPhone(mac)];
		const phoneA = await phoneHello(mac.pairing, a);
		const phoneB = await phoneHello(mac.pairing, b);
		expect(await mac.client.json()).toEqual({ online: { device: a.device } });
		expect(await mac.client.json()).toEqual({ online: { device: b.device } });

		const noise = random(1000);
		phoneA.client.sendBytes(noise);
		expect([...(await mac.client.bytes())]).toEqual([...concat(id(a.device), noise)]);
		phoneB.client.sendBytes(new Uint8Array([1]));
		expect([...(await mac.client.bytes())]).toEqual([...concat(id(b.device), new Uint8Array([1]))]);

		mac.client.sendBytes(concat(id(b.device), new Uint8Array([2, 3])));
		expect([...(await phoneB.client.bytes())]).toEqual([2, 3]);
		mac.client.sendBytes(concat(id(a.device), noise));
		expect([...(await phoneA.client.bytes())]).toEqual([...noise]);
		// Neither phone got the other's.
		expect(await phoneA.client.settle()).toEqual([]);
		expect(await phoneB.client.settle()).toEqual([]);
	});

	it("passes the largest Noise message with its id, and refuses one larger than 70 KB", async () => {
		const mac = await register();
		const phone = await addPhone(mac);
		const device = await phoneHello(mac.pairing, phone);
		await mac.client.json();
		const largest = random(65535);
		device.client.sendBytes(largest);
		expect((await mac.client.bytes()).length).toBe(65535 + 16);
		device.client.sendBytes(new Uint8Array(70 * 1024 + 1).fill(1));
		await device.client.refused("malformed");
	});

	it("tells the Mac a phone is offline when it sends to one not connected, and a phone the Mac is away", async () => {
		const mac = await register();
		const phone = await addPhone(mac);
		mac.client.sendBytes(concat(id(phone.device), new Uint8Array([1])));
		expect(await mac.client.json()).toEqual({ offline: { device: phone.device } });
		const stranger = `dev_${base64url(random(16))}`;
		mac.client.sendBytes(concat(id(stranger), new Uint8Array([1])));
		expect(await mac.client.json()).toEqual({ offline: { device: stranger } });

		const device = await phoneHello(mac.pairing, phone);
		expect(device.ready.mac).toBe(true);
		mac.client.close();
		expect(await device.client.json()).toEqual({ mac: { online: false } });
		device.client.sendBytes(new Uint8Array([1]));
		expect(await device.client.json()).toEqual({ mac: { online: false } });
		const again = await macHello(mac);
		expect(again.ready.devices).toEqual([{ device: phone.device, online: true }]);
		expect(await device.client.json()).toEqual({ mac: { online: true } });
		device.client.close();
		expect(await again.client.json()).toEqual({ offline: { device: phone.device } });
	});

	it("refuses a Mac's binary message too short to name a device, and a phone's empty one", async () => {
		const mac = await register();
		mac.client.sendBytes(random(16));
		await mac.client.refused("malformed");
		const again = await macHello(mac);
		const phone = await addPhone(mac, again.client);
		const device = await phoneHello(mac.pairing, phone);
		device.client.sendBytes(new Uint8Array(0));
		await device.client.refused("malformed");
	});

	it("keeps pairings apart: a Mac reaches only its own phones, even naming another pairing's", async () => {
		const first = await register();
		const second = await register();
		const theirs = await addPhone(second);
		const device = await phoneHello(second.pairing, theirs);
		await second.client.json();
		first.client.sendBytes(concat(id(theirs.device), new Uint8Array([1])));
		expect(await first.client.json()).toEqual({ offline: { device: theirs.device } });
		expect(await device.client.settle()).toEqual([]);

		// A phone of one pairing cannot say hello to another.
		const crossing = await connect(first.pairing);
		crossing.send({ hello: { v: 1, role: "device", pairing: first.pairing, device: theirs.device, build: "3" } });
		await crossing.refused("not-listed");
	});

	it("refuses what a phone may not send: the Mac's own requests", async () => {
		const mac = await register();
		const phone = await addPhone(mac);
		for (const message of [{ closeJoin: {} }, { deletePairing: {} }, { removeDevice: { device: phone.device } }]) {
			const device = await phoneHello(mac.pairing, phone);
			device.client.send(message);
			await device.client.refused("malformed");
		}
	});

	it("refuses what a Mac may not send: a phone's own requests", async () => {
		const mac = await register();
		mac.client.send({ token: { apns: "ab".repeat(32), environment: "production" } });
		await mac.client.refused("malformed");
	});
});
