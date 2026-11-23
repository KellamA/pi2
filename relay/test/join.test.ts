// A phone's join (docs/iphone.md 3.3 step 2, 6.6) with a stand-in for App Attest's verifier (docs/iphone.md 10):
// the window, the token and its three tries, what the attestation is checked against, Apple's category and bundle
// version, an App Attest key tied to one pairing and device, and the slot the Mac then adds or lets go.

import { env, runDurableObjectAlarm, runInDurableObject } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { AppAttestError } from "../src/attest.ts";
import { base64url, concat, fromBase64, fromBase64url, random } from "../src/bytes.ts";
import { sha256 } from "../src/crypto.ts";
import { judge } from "../src/join.ts";
import type { Pairing } from "../src/pairing.ts";
import { readSettings, type Settings } from "../src/settings.ts";
import {
	addPhone,
	attested,
	connect,
	type Joining,
	joinHello,
	macHello,
	newAttestKeyId,
	newDeviceId,
	newKey,
	openWindow,
	pairingObject,
	phoneHello,
	register,
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

async function joined(joining: Joining): Promise<string> {
	const answer = await joining.client.json();
	expect(Object.keys(answer)).toEqual(["joined"]);
	return answer.joined.device;
}

describe("join", () => {
	it("gives a phone with the window's token and a genuine attestation a slot, and connects it to the Mac", async () => {
		const mac = await register();
		const asked = await standInVerifier(mac.pairing);
		const token = await openWindow(mac);
		const joining = await joinHello(mac.pairing);
		sendJoin(mac.pairing, joining, token);
		const device = await joined(joining);
		expect(device).toMatch(/^dev_[A-Za-z0-9_-]{22}$/);
		expect(await mac.client.json()).toEqual({ joined: { device, deviceKey: joining.key.publicKey, keyId: joining.keyId } });

		// What the verifier was asked: the deployment's team, bundle and environments, the key named, and the client data
		// hash of this connection's challenge and this device key; and no time, so it checks at its own.
		const expected = asked.asked[0];
		expect(expected).toMatchObject({ teamId: "1234567890", bundleId: "com.example.myapp", environments: ["production"] });
		expect(expected.now).toBeUndefined();
		expect([...expected.keyId]).toEqual([...fromBase64(joining.keyId, 32)!]);
		const hash = await sha256(concat(fromBase64url(joining.challenge, 32)!, joining.key.der));
		expect([...expected.clientDataHash]).toEqual([...hash]);

		// The channel's bytes pass both ways, as for any device.
		joining.client.sendBytes(new Uint8Array([9, 9, 9]));
		const received = await mac.client.bytes();
		expect(base64url(received.subarray(0, 16))).toBe(device.slice(4));
		expect([...received.subarray(16)]).toEqual([9, 9, 9]);
		mac.client.sendBytes(concat(fromBase64url(device.slice(4), 16)!, new Uint8Array([5])));
		expect([...(await joining.client.bytes())]).toEqual([5]);
	});

	it("refuses a phone when no window is open, or once it has expired", async () => {
		const mac = await register();
		const early = await joiningHello(mac.pairing);
		await early.refused("window-closed");
		await openWindow(mac, mac.client, Date.now() + 60 * 1000);
		vi.setSystemTime(Date.now() + 60 * 1000);
		const late = await joiningHello(mac.pairing);
		await late.refused("window-closed");
	});

	it("keeps a window no longer than five minutes", async () => {
		const mac = await register();
		await standInVerifier(mac.pairing);
		await openWindow(mac, mac.client, Date.now() + 60 * 60 * 1000);
		vi.setSystemTime(Date.now() + 5 * 60 * 1000);
		const joining = await joiningHello(mac.pairing);
		await joining.refused("window-closed");
	});

	it("counts a wrong token, a refused attestation and a key already tied against three tries, and the third closes the window", async () => {
		const mac = await register();
		let genuine = false;
		await standInVerifier(mac.pairing, () => {
			if (!genuine) throw new AppAttestError("nonce", "The attestation was made for other client data.");
			return attested();
		});
		const token = await openWindow(mac);

		const wrongToken = await joinHello(mac.pairing);
		sendJoin(mac.pairing, wrongToken, random(32));
		await wrongToken.client.refused("token");

		const badAttestation = await joinHello(mac.pairing);
		sendJoin(mac.pairing, badAttestation, token);
		await badAttestation.client.refused("attestation");

		genuine = true;
		const third = await joinHello(mac.pairing);
		sendJoin(mac.pairing, third, random(32));
		await third.client.refused("token");

		// Closed: even a right token and a genuine attestation are refused now.
		const after = await joiningHello(mac.pairing);
		await after.refused("window-closed");
	});

	it("refuses an attestation from a category the deployment does not take, or a build below the minimum", async () => {
		const mac = await register();
		let answer = attested(3);
		await standInVerifier(mac.pairing, () => answer);
		const token = await openWindow(mac);
		const development = await joinHello(mac.pairing);
		sendJoin(mac.pairing, development, token);
		await development.client.refused("category");
		answer = attested(2, "0.9");
		const old = await joinHello(mac.pairing);
		sendJoin(mac.pairing, old, token);
		await old.client.refused("bundle-version");
	});

	it("judges Apple's category and bundle version as the deployment's settings say", () => {
		const settings = readSettings(env)!;
		const only: Settings = { ...settings, categories: { values: [2, 4], none: false } };
		expect(judge(only, 2, "1")).toBeNull();
		expect(judge(only, 4, "12.1")).toBeNull();
		expect(judge(only, 3, "1")).toBe("category");
		expect(judge(only, 1, "1")).toBe("category");
		// Before iOS 27 neither is given: taken only where the deployment lists `none`.
		expect(judge(only, null, null)).toBe("category");
		expect(judge({ ...only, categories: { values: [2], none: true } }, null, null)).toBeNull();
		// One without the other is not what Apple makes.
		expect(judge({ ...only, categories: { values: [2], none: true } }, 2, null)).toBe("category");
		expect(judge({ ...only, categories: { values: [2], none: true } }, null, "1")).toBe("category");
		// The bundle version must be a build at or above the minimum for a phone.
		const minimum: Settings = { ...only, minimum: { ...only.minimum, device: [12] } };
		expect(judge(minimum, 2, "12")).toBeNull();
		expect(judge(minimum, 2, "12.0.1")).toBeNull();
		expect(judge(minimum, 2, "11.9")).toBe("bundle-version");
		expect(judge(minimum, 2, "1.0 (12)")).toBe("bundle-version");
	});

	it("refuses an App Attest key already tied to another pairing", async () => {
		const first = await register();
		const second = await register();
		await standInVerifier(first.pairing);
		await standInVerifier(second.pairing);
		const token = await openWindow(first);
		const joining = await joinHello(first.pairing);
		sendJoin(first.pairing, joining, token);
		await joined(joining);

		const tokenAgain = await openWindow(second);
		const again = await joinHello(second.pairing);
		again.keyId = joining.keyId;
		sendJoin(second.pairing, again, tokenAgain);
		await again.client.refused("attest-key-taken");
	});

	it("refuses an App Attest key already tied to another device of the same pairing", async () => {
		const mac = await register();
		await standInVerifier(mac.pairing);
		const token = await openWindow(mac);
		const joining = await joinHello(mac.pairing);
		sendJoin(mac.pairing, joining, token);
		await joined(joining);
		const again = await joinHello(mac.pairing);
		again.keyId = joining.keyId;
		sendJoin(mac.pairing, again, token);
		await again.client.refused("attest-key-taken");
	});

	it("takes three phones in one window, so the engine can see a second claim, and no more", async () => {
		const mac = await register();
		await standInVerifier(mac.pairing);
		const token = await openWindow(mac);
		for (let index = 0; index < 3; index++) {
			const joining = await joinHello(mac.pairing);
			sendJoin(mac.pairing, joining, token);
			await joined(joining);
		}
		const fourth = await joiningHello(mac.pairing);
		await fourth.refused("full");
	});

	it("lets go of a joined phone's slot when the window closes without the Mac adding it, and unties its key", async () => {
		const mac = await register();
		await standInVerifier(mac.pairing);
		const token = await openWindow(mac);
		const joining = await joinHello(mac.pairing);
		sendJoin(mac.pairing, joining, token);
		const device = await joined(joining);
		expect(await mac.client.json()).toMatchObject({ joined: { device } });
		mac.client.send({ closeJoin: {} });
		expect(await mac.client.json()).toEqual({ ok: { what: "closeJoin" } });
		await joining.client.refused("window-ended");
		const kept = await runInDurableObject(pairingObject(mac.pairing), async (_: Pairing, state) => state.storage.get<object>("devices"));
		expect(kept).toEqual({});

		// The key is free for another join.
		const tokenAgain = await openWindow(mac);
		const again = await joinHello(mac.pairing);
		again.keyId = joining.keyId;
		sendJoin(mac.pairing, again, tokenAgain);
		await joined(again);
	});

	it("lets go of a joined phone's slot when the window expires", async () => {
		const mac = await register();
		await standInVerifier(mac.pairing);
		const token = await openWindow(mac);
		const joining = await joinHello(mac.pairing);
		sendJoin(mac.pairing, joining, token);
		await joined(joining);
		vi.setSystemTime(Date.now() + 5 * 60 * 1000);
		await runDurableObjectAlarm(pairingObject(mac.pairing));
		await joining.client.refused("window-ended");
	});

	it("makes a joined phone a listed device when the Mac adds it with the same device key", async () => {
		const mac = await register();
		await standInVerifier(mac.pairing);
		const token = await openWindow(mac);
		const joining = await joinHello(mac.pairing);
		sendJoin(mac.pairing, joining, token);
		const device = await joined(joining);
		await mac.client.json();

		mac.client.send({ addDevice: { device, deviceKey: (await newKey()).publicKey, attestKeyId: joining.keyId } });
		expect(await mac.client.json()).toEqual({ refused: { what: "addDevice", why: "device-key" } });
		mac.client.send({ addDevice: { device, deviceKey: joining.key.publicKey, attestKeyId: joining.keyId } });
		expect(await mac.client.json()).toEqual({ ok: { what: "addDevice" } });
		mac.client.send({ closeJoin: {} });
		expect(await mac.client.json()).toEqual({ ok: { what: "closeJoin" } });

		// Its socket stays, now a device's: it may use the mailbox.
		expect(await joining.client.settle()).toEqual([]);
		mac.client.close();
		const { ready } = await macHello(mac);
		expect(ready).toEqual({ devices: [{ device, online: true }], left: [], pending: false, mail: 0 });
	});

	it("pairs as the contract has it: two App Attest keys, and the Mac adding the phone under the engine's id", async () => {
		const mac = await register();
		await standInVerifier(mac.pairing);
		const token = await openWindow(mac);
		// The phone joins with the App Attest key it made for the relay.
		const joining = await joinHello(mac.pairing);
		sendJoin(mac.pairing, joining, token);
		const slot = await joined(joining);
		expect(await mac.client.json()).toMatchObject({ joined: { device: slot } });
		// The engine paired it with a second key, which the Mac checked, and gave it an id of its own.
		const device = newDeviceId();
		const macKey = newAttestKeyId();
		expect(macKey).not.toBe(joining.keyId);
		mac.client.send({ addDevice: { device, deviceKey: joining.key.publicKey, attestKeyId: macKey } });
		expect(await mac.client.json()).toEqual({ ok: { what: "addDevice" } });

		// The phone's socket carries on, under the engine's id: the pairing exchange is not cut.
		joining.client.sendBytes(new Uint8Array([7]));
		expect([...(await mac.client.bytes())]).toEqual([...fromBase64url(device.slice(4), 16)!, 7]);
		mac.client.sendBytes(concat(fromBase64url(device.slice(4), 16)!, new Uint8Array([8])));
		expect([...(await joining.client.bytes())]).toEqual([8]);
		mac.client.sendBytes(concat(fromBase64url(slot.slice(4), 16)!, new Uint8Array([9])));
		expect(await mac.client.json()).toEqual({ offline: { device: slot } });
		mac.client.send({ closeJoin: {} });
		expect(await mac.client.json()).toEqual({ ok: { what: "closeJoin" } });
		expect(await joining.client.settle()).toEqual([]);

		// The relay keeps the device under the engine's id, with the relay's key tied and the Mac's recorded.
		const devices = await runInDurableObject(pairingObject(mac.pairing), async (_: Pairing, state) =>
			state.storage.get<Record<string, { attestKeyIds: string[]; macKeyId: string }>>("devices"),
		);
		expect(Object.keys(devices!)).toEqual([device]);
		expect(devices![device]).toMatchObject({ attestKeyIds: [joining.keyId], macKeyId: macKey });
		await phoneHello(mac.pairing, { device, key: joining.key, attestKeyId: macKey, relayKeyId: joining.keyId });
		await joining.client.refused("replaced");

		// The relay's key is tied to the device: another pairing is refused it. The Mac's key, which the relay never
		// checked, is not tied.
		const other = await register();
		await standInVerifier(other.pairing);
		const otherToken = await openWindow(other);
		const relayKey = await joinHello(other.pairing);
		relayKey.keyId = joining.keyId;
		sendJoin(other.pairing, relayKey, otherToken);
		await relayKey.client.refused("attest-key-taken");
		const theMacs = await joinHello(other.pairing);
		theMacs.keyId = macKey;
		sendJoin(other.pairing, theMacs, otherToken);
		expect(Object.keys(await theMacs.client.json())).toEqual(["joined"]);
	});

	it("adds the live slot when the same phone joined twice, and lets go of the other", async () => {
		const mac = await register();
		await standInVerifier(mac.pairing);
		const token = await openWindow(mac);
		// The phone joins, its socket drops, and it joins again: the same device key, a new App Attest key.
		const first = await joinHello(mac.pairing);
		sendJoin(mac.pairing, first, token);
		const dead = await joined(first);
		await mac.client.json();
		first.client.close();
		expect(await mac.client.json()).toEqual({ offline: { device: dead } });
		const second = await joinHello(mac.pairing);
		second.key = first.key;
		sendJoin(mac.pairing, second, token);
		const live = await joined(second);
		await mac.client.json();
		const device = newDeviceId();
		mac.client.send({ addDevice: { device, deviceKey: first.key.publicKey, attestKeyId: newAttestKeyId() } });
		expect(await mac.client.json()).toEqual({ ok: { what: "addDevice" } });
		mac.client.send({ closeJoin: {} });
		expect(await mac.client.json()).toEqual({ ok: { what: "closeJoin" } });

		// The live socket carries on under the engine's id.
		mac.client.sendBytes(concat(fromBase64url(device.slice(4), 16)!, new Uint8Array([5])));
		expect([...(await second.client.bytes())]).toEqual([5]);
		second.client.sendBytes(new Uint8Array([6]));
		expect([...(await mac.client.bytes())]).toEqual([...fromBase64url(device.slice(4), 16)!, 6]);
		const devices = await runInDurableObject(pairingObject(mac.pairing), async (_: Pairing, state) =>
			state.storage.get<Record<string, { attestKeyIds: string[] }>>("devices"),
		);
		expect(devices).toEqual({ [device]: expect.objectContaining({ attestKeyIds: [second.keyId] }) });
		expect([dead, live]).not.toContain(device);

		// The dead slot's relay key is untied with it.
		const other = await register();
		await standInVerifier(other.pairing);
		const otherToken = await openWindow(other);
		const reuse = await joinHello(other.pairing);
		reuse.keyId = first.keyId;
		sendJoin(other.pairing, reuse, otherToken);
		expect(Object.keys(await reuse.client.json())).toEqual(["joined"]);
	});

	it("prefers a slot with a live socket to a later one whose socket dropped", async () => {
		const mac = await register();
		await standInVerifier(mac.pairing);
		const token = await openWindow(mac);
		const first = await joinHello(mac.pairing);
		sendJoin(mac.pairing, first, token);
		await joined(first);
		await mac.client.json();
		const second = await joinHello(mac.pairing);
		second.key = first.key;
		sendJoin(mac.pairing, second, token);
		const later = await joined(second);
		await mac.client.json();
		second.client.close();
		expect(await mac.client.json()).toEqual({ offline: { device: later } });
		const device = newDeviceId();
		mac.client.send({ addDevice: { device, deviceKey: first.key.publicKey, attestKeyId: newAttestKeyId() } });
		expect(await mac.client.json()).toEqual({ ok: { what: "addDevice" } });
		first.client.sendBytes(new Uint8Array([1]));
		expect([...(await mac.client.bytes())]).toEqual([...fromBase64url(device.slice(4), 16)!, 1]);
	});

	it("refuses to add a phone that did not join this pairing: a Mac cannot list devices of its own making", async () => {
		const mac = await register();
		const made = await newKey();
		mac.client.send({ addDevice: { device: `dev_${base64url(random(16))}`, deviceKey: made.publicKey, attestKeyId: "A".repeat(43) + "=" } });
		expect(await mac.client.json()).toEqual({ refused: { what: "addDevice", why: "not-joined" } });
		// Nor one that joined another pairing.
		const other = await register();
		const theirs = await addPhone(other);
		mac.client.send({ addDevice: { device: theirs.device, deviceKey: theirs.key.publicKey, attestKeyId: theirs.attestKeyId } });
		expect(await mac.client.json()).toEqual({ refused: { what: "addDevice", why: "not-joined" } });
		mac.client.send({ addDevice: { device: `dev_${base64url(random(16))}`, deviceKey: theirs.key.publicKey, attestKeyId: theirs.attestKeyId } });
		expect(await mac.client.json()).toEqual({ refused: { what: "addDevice", why: "not-joined" } });
		// The pairing stays pending.
		mac.client.close();
		expect((await macHello(mac)).ready.pending).toBe(true);
	});

	it("lists five devices at most, and refuses an id already listed", async () => {
		const mac = await register();
		const phones = [];
		for (let index = 0; index < 5; index++) phones.push(await addPhone(mac));
		mac.client.send({ addDevice: { device: phones[0].device, deviceKey: phones[0].key.publicKey, attestKeyId: phones[0].attestKeyId } });
		expect(await mac.client.json()).toEqual({ refused: { what: "addDevice", why: "exists" } });
		const token = await openWindow(mac);
		const sixth = await joinHello(mac.pairing);
		sendJoin(mac.pairing, sixth, token);
		const device = await joined(sixth);
		await mac.client.json();
		mac.client.send({ addDevice: { device, deviceKey: sixth.key.publicKey, attestKeyId: sixth.keyId } });
		expect(await mac.client.json()).toEqual({ refused: { what: "addDevice", why: "full" } });
	});

	it("refuses a proof on a joining socket, which must join", async () => {
		const mac = await register();
		await standInVerifier(mac.pairing);
		await openWindow(mac);
		const joining = await joinHello(mac.pairing);
		joining.client.send({ proof: { signature: await joining.key.sign("anything") } });
		await joining.client.refused("malformed");
	});
});

/** A phone with no slot says hello, to be refused before any challenge. */
async function joiningHello(pairing: string) {
	const client = await connect(pairing);
	client.send({ hello: { v: 1, role: "device", pairing, build: "3" } });
	return client;
}
