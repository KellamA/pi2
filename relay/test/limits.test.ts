// A pairing's limits (docs/iphone.md 6.6, 5.3): only authenticated traffic counts; past a limit the relay answers
// "busy" and passes nothing on; past twice a limit the pairing's sockets are closed for an hour.

import { runDurableObjectAlarm, runInDurableObject } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { base64url, random } from "../src/bytes.ts";
import { LIMITS, type Limits } from "../src/limits.ts";
import type { Pairing } from "../src/pairing.ts";
import { proofText } from "../src/protocol.ts";
import { addPhone, connect, macHello, type Mac, newKey, pairingObject, phoneHello, register } from "./helpers.ts";

const NOON = Date.parse("2026-11-20T12:00:00Z");

beforeEach(() => {
	vi.useFakeTimers({ toFake: ["Date"] });
	vi.setSystemTime(NOON);
});
afterEach(() => {
	vi.useRealTimers();
});

async function setLimits(pairing: string, limits: Partial<Limits>): Promise<void> {
	await runInDurableObject(pairingObject(pairing), (instance: Pairing) => {
		instance.limits = { ...LIMITS, ...limits };
	});
}

/** A Mac with one phone connected, the clock at the start of a second. */
async function pairWithPhone(): Promise<{ mac: Mac; phone: Awaited<ReturnType<typeof phoneHello>> }> {
	const mac = await register();
	const listed = await addPhone(mac);
	const phone = await phoneHello(mac.pairing, listed);
	expect(await mac.client.json()).toEqual({ online: { device: listed.device } });
	vi.setSystemTime(Math.ceil((Date.now() + 1) / 1000) * 1000);
	return { mac, phone };
}

describe("limits", () => {
	it("answers busy past the messages a second, passes nothing on, and lets the next second through", async () => {
		const { mac, phone } = await pairWithPhone();
		await setLimits(mac.pairing, { messagesPerSecond: 3 });
		for (let index = 0; index < 3; index++) phone.client.sendBytes(new Uint8Array([index]));
		phone.client.sendBytes(new Uint8Array([3]));
		expect(await phone.client.json()).toEqual({ busy: { until: Date.now() - (Date.now() % 1000) + 1000 } });
		for (let index = 0; index < 3; index++) expect((await mac.client.bytes()).at(-1)).toBe(index);
		vi.setSystemTime(Date.now() + 1000);
		phone.client.sendBytes(new Uint8Array([4]));
		expect((await mac.client.bytes()).at(-1)).toBe(4);
	});

	it("counts the Mac's and the phones' messages together, the pairing's alone", async () => {
		const { mac, phone } = await pairWithPhone();
		const other = await pairWithPhone();
		await setLimits(mac.pairing, { messagesPerSecond: 2 });
		await setLimits(other.mac.pairing, { messagesPerSecond: 2 });
		phone.client.sendBytes(new Uint8Array([1]));
		mac.client.send({ take: {} });
		mac.client.send({ take: {} });
		expect(await mac.client.bytes()).toHaveLength(17);
		expect(await mac.client.json()).toEqual({ taken: { count: 0 } });
		expect(await mac.client.json()).toMatchObject({ busy: {} });
		// Another pairing's limits are its own.
		other.phone.client.sendBytes(new Uint8Array([1]));
		expect(await other.mac.client.bytes()).toHaveLength(17);
	});

	it("answers busy past the bytes a second", async () => {
		const { mac, phone } = await pairWithPhone();
		await setLimits(mac.pairing, { bytesPerSecond: 1000 });
		phone.client.sendBytes(new Uint8Array(600));
		phone.client.sendBytes(new Uint8Array(600));
		expect(await mac.client.bytes()).toHaveLength(616);
		expect(await phone.client.json()).toMatchObject({ busy: {} });
	});

	it("answers busy past the day's messages until the next day", async () => {
		const { mac, phone } = await pairWithPhone();
		// Seven today: pairing the phone took three of the Mac's (openJoin, addDevice, closeJoin).
		await setLimits(mac.pairing, { messagesPerDay: 7 });
		for (let index = 0; index < 4; index++) {
			vi.setSystemTime(Date.now() + 1000);
			phone.client.sendBytes(new Uint8Array([index]));
			expect((await mac.client.bytes()).at(-1)).toBe(index);
		}
		vi.setSystemTime(Date.now() + 1000);
		phone.client.sendBytes(new Uint8Array([4]));
		expect(await phone.client.json()).toEqual({ busy: { until: Date.parse("2026-11-21T00:00:00Z") } });
		vi.setSystemTime(Date.parse("2026-11-21T00:00:00Z"));
		phone.client.sendBytes(new Uint8Array([5]));
		expect((await mac.client.bytes()).at(-1)).toBe(5);
	});

	it("closes every socket of a pairing past twice a limit, refuses it for an hour, and then takes it again", async () => {
		const { mac, phone } = await pairWithPhone();
		await setLimits(mac.pairing, { messagesPerSecond: 2 });
		for (let index = 0; index < 5; index++) phone.client.sendBytes(new Uint8Array([index]));
		const until = Date.now() + 60 * 60 * 1000;
		const seen = [];
		for (;;) {
			const message = await phone.client.next();
			seen.push(message);
			if (typeof message === "object" && "closed" in message) break;
		}
		expect(seen.at(-2)).toBe(JSON.stringify({ refused: { why: "limits", until } }));
		expect(seen.at(-1)).toMatchObject({ reason: "limits" });
		// The Mac is closed too, and told why.
		for (;;) {
			const message = await mac.client.next();
			if (typeof message === "string" && message.startsWith('{"refused"')) {
				expect(JSON.parse(message)).toEqual({ refused: { why: "limits", until } });
				break;
			}
		}
		const refused = await connect(mac.pairing);
		refused.send({ hello: { v: 1, role: "mac", pairing: mac.pairing, build: "120" } });
		expect(await refused.json()).toEqual({ refused: { why: "limits", until } });

		vi.setSystemTime(until);
		await runDurableObjectAlarm(pairingObject(mac.pairing));
		const { ready } = await macHello(mac);
		expect(ready.devices).toHaveLength(1);
	});

	it("does not count what a stranger sends: one who knows the pairing's id cannot spend its limits", async () => {
		const { mac, phone } = await pairWithPhone();
		const absent = await addPhone(mac);
		vi.setSystemTime(Math.ceil((Date.now() + 1) / 1000) * 1000);
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
				stranger.send({ hello: { v: 1, role: "device", pairing: mac.pairing, device: absent.device, build: "3" } });
				const { challenge } = await stranger.json();
				stranger.send({ proof: { signature: await impostor.sign(proofText("device", mac.pairing, absent.device, challenge)) } });
				await stranger.refused("signature");
			}
		}
		// The pairing's own two messages this second still pass.
		phone.client.sendBytes(new Uint8Array([1]));
		phone.client.sendBytes(new Uint8Array([2]));
		expect((await mac.client.bytes()).at(-1)).toBe(1);
		expect((await mac.client.bytes()).at(-1)).toBe(2);
	});
});

