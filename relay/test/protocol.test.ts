// The protocol's first steps (docs/iphone.md 5.3, 3.4, 6.6): the Worker's door, hello and register with their
// challenges and builds, a second Mac refused, the ten seconds to prove oneself, and what is read strictly.

import { runDurableObjectAlarm, runInDurableObject } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { base64url, random } from "../src/bytes.ts";
import type { Pairing } from "../src/pairing.ts";
import { readMessage, proofText } from "../src/protocol.ts";
import { addPhone, connect, macHello, newAddress, newKey, pairingObject, phoneHello, register, worker } from "./helpers.ts";

beforeEach(() => {
	vi.useFakeTimers({ toFake: ["Date"] });
	vi.setSystemTime(Date.parse("2026-11-20T12:00:00Z"));
});
afterEach(() => {
	vi.useRealTimers();
});

describe("the Worker", () => {
	it("takes only a WebSocket at /v1, with nothing in its address", async () => {
		expect((await worker.fetch("https://relay.test/")).status).toBe(404);
		expect((await worker.fetch("https://relay.test/v1?pairing=x", { headers: { Upgrade: "websocket" } })).status).toBe(404);
		// The runtime itself refuses a POST that asks for a WebSocket; either way, nothing is opened.
		expect((await worker.fetch("https://relay.test/v1", { method: "POST", headers: { Upgrade: "websocket" } })).status).not.toBe(101);
		expect((await worker.fetch("https://relay.test/v1")).status).toBe(426);
		const response = await worker.fetch("https://relay.test/v1", { headers: { Upgrade: "websocket", "Pi2-Pairing": "not an id" } });
		expect(response.status).toBe(400);
		expect(await response.text()).toBe("");
	});

	it("refuses any request a web page could make: one carrying an Origin", async () => {
		const address = newAddress();
		for (let index = 0; index < 6; index++) {
			const response = await worker.fetch("https://relay.test/v1", {
				headers: { Upgrade: "websocket", "CF-Connecting-IP": address, Origin: "https://example.com" },
			});
			expect(response.status).toBe(403);
		}
		// Nothing was counted against the address: its five registrations an hour are all still there.
		for (let index = 0; index < 5; index++) await register(address);
		const mac = await register();
		const named = await worker.fetch("https://relay.test/v1", { headers: { Upgrade: "websocket", "Pi2-Pairing": mac.pairing, Origin: "null" } });
		expect(named.status).toBe(403);
	});

	it("refuses a registration with no address to count it against", async () => {
		expect((await worker.fetch("https://relay.test/v1", { headers: { Upgrade: "websocket" } })).status).toBe(400);
	});

	it("limits registrations to five an hour and twenty a day from one address", async () => {
		const address = newAddress();
		for (let index = 0; index < 5; index++) await register(address);
		const sixth = await worker.fetch("https://relay.test/v1", { headers: { Upgrade: "websocket", "CF-Connecting-IP": address } });
		expect(sixth.status).toBe(429);
		// Another address is not held back by this one.
		await register(newAddress());
		for (let hour = 1; hour < 4; hour++) {
			vi.setSystemTime(Date.parse("2026-11-20T12:00:00Z") + hour * 60 * 60 * 1000 + 1);
			for (let index = 0; index < 5; index++) await register(address);
		}
		vi.setSystemTime(Date.parse("2026-11-20T16:00:00Z") + 1);
		expect((await worker.fetch("https://relay.test/v1", { headers: { Upgrade: "websocket", "CF-Connecting-IP": address } })).status).toBe(429);
		// The next day, the address's object has another name, and its count starts again.
		vi.setSystemTime(Date.parse("2026-11-21T00:00:01Z"));
		await register(address);
	});
});

describe("register and hello", () => {
	it("registers a pairing for a Mac that signs the challenge with its relay key, then knows it at hello", async () => {
		const mac = await register();
		expect(mac.pairing).toMatch(/^[A-Za-z0-9_-]{22}$/);
		mac.client.close();
		const { ready } = await macHello(mac);
		expect(ready).toEqual({ devices: [], left: [], pending: true, mail: 0 });
	});

	it("gives each registration a pairing of its own", async () => {
		const a = await register();
		const b = await register();
		expect(a.pairing).not.toBe(b.pairing);
	});

	it("refuses a register whose challenge is signed with another key", async () => {
		const key = await newKey();
		const other = await newKey();
		const client = await connect();
		client.send({ register: { v: 1, build: "120", relayKey: key.publicKey } });
		const { challenge } = await client.json();
		expect(challenge).toMatch(/^[A-Za-z0-9_-]{43}$/);
		client.send({ proof: { signature: await other.sign(proofText("register", "", "", challenge)) } });
		await client.refused("signature");
	});

	it("refuses a Mac's hello signed with another key, or over another challenge", async () => {
		const mac = await register();
		mac.client.close();
		const client = await connect(mac.pairing);
		client.send({ hello: { v: 1, role: "mac", pairing: mac.pairing, build: "120" } });
		await client.json();
		client.send({ proof: { signature: await mac.key.sign(proofText("mac", mac.pairing, "", base64url(random(32)))) } });
		await client.refused("signature");
	});

	it("gives a fresh challenge each time, and none to a phone whose slot is not listed", async () => {
		const mac = await register();
		const challenges = new Set<string>();
		const client = await connect(mac.pairing);
		client.send({ hello: { v: 1, role: "device", pairing: mac.pairing, device: `dev_${base64url(random(16))}`, build: "3" } });
		await client.refused("not-listed");
		mac.client.close();
		for (let index = 0; index < 3; index++) {
			const client = await connect(mac.pairing);
			client.send({ hello: { v: 1, role: "mac", pairing: mac.pairing, build: "120" } });
			challenges.add((await client.json()).challenge);
			client.close();
		}
		expect(challenges.size).toBe(3);
	});

	it("refuses a hello for a pairing that does not exist, or that names another pairing than it reached", async () => {
		const stranger = base64url(random(16));
		const client = await connect(stranger);
		client.send({ hello: { v: 1, role: "mac", pairing: stranger, build: "120" } });
		await client.refused("unknown-pairing");

		const mac = await register();
		const other = await register();
		const crossed = await connect(mac.pairing);
		crossed.send({ hello: { v: 1, role: "mac", pairing: other.pairing, build: "120" } });
		await crossed.refused("unknown-pairing");
	});

	it("refuses builds below the minimum for each role: update required", async () => {
		const key = await newKey();
		const client = await connect();
		client.send({ register: { v: 1, build: "99.9", relayKey: key.publicKey } });
		await client.refused("update-required");

		const mac = await register();
		const phone = await addPhone(mac);
		const old = await connect(mac.pairing);
		old.send({ hello: { v: 1, role: "mac", pairing: mac.pairing, build: "99" } });
		await old.refused("update-required");
		const oldPhone = await connect(mac.pairing);
		oldPhone.send({ hello: { v: 1, role: "device", pairing: mac.pairing, device: phone.device, build: "0.9" } });
		await oldPhone.refused("update-required");
	});

	it("takes ext and ignores what it holds", async () => {
		const mac = await register();
		mac.client.close();
		const client = await connect(mac.pairing);
		client.send({ hello: { v: 1, role: "mac", pairing: mac.pairing, build: "120", ext: { receipt: "anything" } } });
		expect(Object.keys(await client.json())).toEqual(["challenge"]);
	});
});

describe("a second Mac", () => {
	it("is refused while the Mac's socket is connected, and the connected one is told", async () => {
		const mac = await register();
		const second = await connect(mac.pairing);
		second.send({ hello: { v: 1, role: "mac", pairing: mac.pairing, build: "120" } });
		const { challenge } = await second.json();
		second.send({ proof: { signature: await mac.key.sign(proofText("mac", mac.pairing, "", challenge)) } });
		await second.refused("another-mac");
		expect(await mac.client.json()).toEqual({ anotherMac: {} });
		// The connected Mac is untouched.
		expect(await mac.client.settle()).toEqual([]);
	});

	it("that cannot prove itself is refused without troubling the connected Mac", async () => {
		const mac = await register();
		const impostor = await newKey();
		const second = await connect(mac.pairing);
		second.send({ hello: { v: 1, role: "mac", pairing: mac.pairing, build: "120" } });
		const { challenge } = await second.json();
		second.send({ proof: { signature: await impostor.sign(proofText("mac", mac.pairing, "", challenge)) } });
		await second.refused("signature");
		expect(await mac.client.settle()).toEqual([]);
	});

	it("is refused if it proves itself while another Mac does", async () => {
		const mac = await register();
		mac.client.close();
		const [a, b] = [await connect(mac.pairing), await connect(mac.pairing)];
		a.send({ hello: { v: 1, role: "mac", pairing: mac.pairing, build: "120" } });
		b.send({ hello: { v: 1, role: "mac", pairing: mac.pairing, build: "120" } });
		const [ca, cb] = [(await a.json()).challenge, (await b.json()).challenge];
		a.send({ proof: { signature: await mac.key.sign(proofText("mac", mac.pairing, "", ca)) } });
		expect(Object.keys(await a.json())).toEqual(["ready"]);
		b.send({ proof: { signature: await mac.key.sign(proofText("mac", mac.pairing, "", cb)) } });
		await b.refused("another-mac");
		expect(await a.json()).toEqual({ anotherMac: {} });
	});

	it("takes the place of a Mac socket not heard from in 90 seconds, which is closed", async () => {
		const mac = await register();
		vi.setSystemTime(Date.now() + 91 * 1000);
		const { client, ready } = await macHello(mac);
		expect(ready.pending).toBe(true);
		await mac.client.refused("replaced");
		expect(await client.settle()).toEqual([]);
	});
});

describe("proving within ten seconds", () => {
	it("closes a socket that has not proved itself, and only that one", async () => {
		const mac = await register();
		const idle = await connect(mac.pairing);
		const challenged = await connect(mac.pairing);
		challenged.send({ hello: { v: 1, role: "mac", pairing: mac.pairing, build: "120" } });
		await challenged.json();
		vi.setSystemTime(Date.now() + 10 * 1000);
		await runDurableObjectAlarm(pairingObject(mac.pairing));
		await idle.refused("timeout");
		await challenged.refused("timeout");
		expect(await mac.client.settle()).toEqual([]);
	});

	it("closes the oldest waiting socket when sixteen wait", async () => {
		const mac = await register();
		const first = await connect(mac.pairing);
		const rest = [];
		for (let index = 0; index < 15; index++) {
			vi.setSystemTime(Date.now() + 1);
			rest.push(await connect(mac.pairing));
		}
		await connect(mac.pairing);
		await first.refused("too-many");
		// The others still wait for their hello.
		rest[0].send({ hello: { v: 1, role: "mac", pairing: mac.pairing, build: "120" } });
		expect(Object.keys(await rest[0].json())).toEqual(["challenge"]);
	});

	it("keeps nothing for a pairing nobody registered", async () => {
		const stranger = base64url(random(16));
		const client = await connect(stranger);
		vi.setSystemTime(Date.now() + 10 * 1000);
		await runDurableObjectAlarm(pairingObject(stranger));
		await client.refused("timeout");
		await runDurableObjectAlarm(pairingObject(stranger));
		const kept = await runInDurableObject(pairingObject(stranger), async (_instance: Pairing, state) => (await state.storage.list()).size);
		expect(kept).toBe(0);
	});
});

describe("what is refused as malformed", () => {
	it("closes a socket whose first message is not its hello", async () => {
		const mac = await register();
		for (const message of [
			"not json",
			'{"hello":{"v":1,"role":"mac","pairing":"x","build":"120"}} ',
			'{ "hello": {} }',
			JSON.stringify({ hello: { v: 2, role: "mac", pairing: mac.pairing, build: "120" } }),
			JSON.stringify({ hello: { v: 1, role: "mac", pairing: mac.pairing, build: "120", device: "dev_AAAAAAAAAAAAAAAAAAAAAA" } }),
			JSON.stringify({ hello: { v: 1, role: "mac", pairing: mac.pairing, build: "120", extra: 1 } }),
			JSON.stringify({ register: { v: 1, build: "120", relayKey: "x" } }),
			JSON.stringify({ proof: { signature: base64url(random(64)) } }),
		]) {
			const client = await connect(mac.pairing);
			client.sendText(message);
			await client.refused("malformed");
		}
		const binary = await connect(mac.pairing);
		binary.sendBytes(new Uint8Array([1, 2, 3]));
		await binary.refused("malformed");
	});

	it("never says back what it was sent", async () => {
		const mac = await register();
		const client = await connect(mac.pairing);
		client.sendText(JSON.stringify({ hello: { v: 1, role: "mac", pairing: mac.pairing, build: "MARKER-<script>" } }));
		const refusal = await client.next();
		const closed = await client.next();
		expect(JSON.stringify([refusal, closed])).not.toContain("MARKER");
	});

	it("reads each message exactly: one way of writing it, no key twice, nothing after it", () => {
		const pairing = base64url(random(16));
		const hello = { hello: { v: 1, role: "mac", pairing, build: "120" } };
		expect(readMessage(JSON.stringify(hello))).toMatchObject({ type: "hello", role: "mac", pairing, build: [120] });
		expect(readMessage(JSON.stringify(hello) + "\n")).toBeNull();
		expect(readMessage(JSON.stringify(hello).replace('"v":1', '"v":1,"v":1'))).toBeNull();
		expect(readMessage(JSON.stringify(hello).replace('"v":1', '"v":1.0'))).toBeNull();
		expect(readMessage(JSON.stringify(hello).replace('"mac"', '"\\u006dac"'))).toBeNull();
		expect(readMessage(JSON.stringify({ ...hello, take: {} }))).toBeNull();
		expect(readMessage(JSON.stringify({ hello: { ...hello.hello, build: "01" } }))).toBeNull();
		expect(readMessage(JSON.stringify({ hello: { ...hello.hello, build: "1.2.3.4" } }))).toBeNull();
		expect(readMessage(JSON.stringify({ hello: { ...hello.hello, pairing: pairing + "A" } }))).toBeNull();
		expect(readMessage(JSON.stringify({ take: {} }))).toEqual({ type: "take" });
		expect(readMessage(JSON.stringify({ take: [] }))).toBeNull();
		expect(readMessage("x".repeat(48 * 1024 + 1))).toBeNull();
		// Sizes are in bytes: 17,000 characters of three bytes each are past the 48 KB, though fewer characters.
		const wide = JSON.stringify({ hello: { ...hello.hello, ext: { note: "€".repeat(17_000) } } });
		expect(wide.length).toBeLessThan(48 * 1024);
		expect(readMessage(wide)).toBeNull();
		expect(readMessage(JSON.stringify({ hello: { ...hello.hello, ext: { note: "€".repeat(100) } } }))).not.toBeNull();
		// A base64url text with bits left over is not the one way of writing its bytes.
		const signature = base64url(random(64));
		const last = signature.at(-1)!;
		const odd = signature.slice(0, -1) + (last === "A" ? "B" : last === "Q" ? "R" : "B");
		expect(readMessage(JSON.stringify({ proof: { signature } }))).toEqual({ type: "proof", signature });
		expect(readMessage(JSON.stringify({ proof: { signature: odd } }))).toBeNull();
	});
});

describe("a phone's hello", () => {
	it("is taken for a listed device that signs with its device key", async () => {
		const mac = await register();
		const phone = await addPhone(mac);
		const { ready } = await phoneHello(mac.pairing, phone);
		expect(ready).toEqual({ mac: true, mail: 0 });
		expect(await mac.client.json()).toEqual({ online: { device: phone.device } });
	});

	it("is refused when signed with another key", async () => {
		const mac = await register();
		const phone = await addPhone(mac);
		const other = await newKey();
		const client = await connect(mac.pairing);
		client.send({ hello: { v: 1, role: "device", pairing: mac.pairing, device: phone.device, build: "3" } });
		const { challenge } = await client.json();
		client.send({ proof: { signature: await other.sign(proofText("device", mac.pairing, phone.device, challenge)) } });
		await client.refused("signature");
	});

	it("is refused when signed for another device of the same pairing", async () => {
		const mac = await register();
		const phone = await addPhone(mac);
		const other = await addPhone(mac);
		const client = await connect(mac.pairing);
		client.send({ hello: { v: 1, role: "device", pairing: mac.pairing, device: phone.device, build: "3" } });
		const { challenge } = await client.json();
		client.send({ proof: { signature: await other.key.sign(proofText("device", mac.pairing, phone.device, challenge)) } });
		await client.refused("signature");
	});

	it("replaces the same device's older socket", async () => {
		const mac = await register();
		const phone = await addPhone(mac);
		const first = await phoneHello(mac.pairing, phone);
		const second = await phoneHello(mac.pairing, phone);
		await first.client.refused("replaced");
		expect(second.ready.mac).toBe(true);
	});
});
