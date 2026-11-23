// App Attest's verifier in the relay (docs/iphone.md 12.1, P37 and P8): that it is the engine's very file, not a copy;
// that it runs in the Workers runtime; and the fixtures of #672 (engine/test/appattest.json), Apple's own sample
// attestation and altered ones, run through the relay's `join` with the real verifier.

import { runInDurableObject } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as engine from "../../engine/src/appattest.ts";
import fixtures from "../../engine/test/appattest.json";
import engineSource from "../../engine/src/appattest.ts?raw";
import * as relay from "../src/attest.ts";
import { base64url, fromBase64, hex, utf8 } from "../src/bytes.ts";
import { sha256 } from "../src/crypto.ts";
import type { Pairing } from "../src/pairing.ts";
import { type Joining, joinHello, openWindow, pairingObject, register, type Mac } from "./helpers.ts";

const sample = fixtures.samples[0];
const attestation = Uint8Array.from(atob(sample.attestation), (character) => character.charCodeAt(0));
const [validFrom, validUntil] = sample.leafValid.map(Date.parse);
/** A time the sample's leaf certificate is valid at, as the engine's own test checks it. */
const sampleTime = (validFrom + validUntil) / 2;

afterEach(() => {
	vi.useRealTimers();
});

describe("the verifier the relay runs", () => {
	it("is the engine's own file, imported by its path, not a copy", async () => {
		// One module: the relay's import and the engine's file give the very same functions and classes.
		expect(relay.verifyAttestation).toBe(engine.verifyAttestation);
		expect(relay.AppAttestError).toBe(engine.AppAttestError);
		// And that file is the one the engine's tests check: its root and fingerprint are the fixtures'.
		expect(engine.APPLE_APP_ATTEST_ROOT_SHA256).toBe(fixtures.root.derSha256);
		expect(engineSource).toContain("export async function verifyAttestation(");
	});

	it("runs in the Workers runtime: Apple's sample passes, at a time its leaf is valid", async () => {
		const result = await engine.verifyAttestation(attestation, {
			teamId: sample.teamId,
			bundleId: sample.bundleId,
			keyId: fromBase64(sample.keyId, 32)!,
			clientDataHash: utf8(sample.clientDataHash),
			environments: ["production"],
			now: sampleTime,
		});
		expect(result.environment).toBe(sample.environment);
		expect(result.validationCategory).toBe(sample.expected.validationCategory);
		expect(result.bundleVersion).toBe(sample.expected.bundleVersion);
		expect(hex(await sha256(new Uint8Array(attestation)))).toBe(sample.attestationSha256);
	});
});

describe("Apple's sample through the relay's join", () => {
	beforeEach(() => {
		vi.useFakeTimers({ toFake: ["Date"] });
		vi.setSystemTime(sampleTime);
	});

	/**
	 * Apple made its sample for client data of its own, the text `example_server_challenge` as it is, so the relay's
	 * object is given that in place of the hash of its challenge and the phone's key, which Apple could not know; and the
	 * real verifier is watched, so a refusal says which of its checks refused. Nothing else of `join` is changed.
	 */
	async function asApple(pairing: string, clientData = true): Promise<{ reasons: string[] }> {
		const watched = { reasons: [] as string[] };
		await runInDurableObject(pairingObject(pairing), (instance: Pairing) => {
			if (clientData) instance.clientDataHash = async () => utf8(sample.clientDataHash);
			instance.verify = async (bytes, expected) => {
				try {
					return await engine.verifyAttestation(bytes, expected);
				} catch (error) {
					watched.reasons.push((error as engine.AppAttestError).reason);
					throw error;
				}
			};
		});
		return watched;
	}

	async function join(mac: Mac, bytes: Uint8Array, keyId = sample.keyId): Promise<Joining> {
		const token = await openWindow(mac);
		const joining = await joinHello(mac.pairing);
		joining.client.send({
			join: { pairing: mac.pairing, deviceKey: joining.key.publicKey, attestation: base64url(bytes), keyId, token: base64url(token) },
		});
		return joining;
	}

	it("joins: the sample is a genuine attestation for its key, app and client data, and its key is then tied", async () => {
		const mac = await register();
		const watched = await asApple(mac.pairing);
		const joining = await join(mac, attestation);
		const answer = await joining.client.json();
		expect(Object.keys(answer)).toEqual(["joined"]);
		expect(watched.reasons).toEqual([]);
		expect(await mac.client.json()).toEqual({ joined: { device: answer.joined.device, deviceKey: joining.key.publicKey, keyId: sample.keyId } });

		// Its key is now tied to that pairing's phone: another pairing refuses it, though the verifier takes it.
		const second = await register();
		const again = await asApple(second.pairing);
		const twice = await join(second, attestation);
		await twice.client.refused("attest-key-taken");
		expect(again.reasons).toEqual([]);
	});

	it("is refused for the client data the relay works out itself, which Apple's sample was not made for", async () => {
		const mac = await register();
		const watched = await asApple(mac.pairing, false);
		const joining = await join(mac, attestation);
		await joining.client.refused("attestation");
		expect(watched.reasons).toEqual(["nonce"]);
	});

	it("is refused at the relay's own time now, long after its leaf expired", async () => {
		vi.useRealTimers();
		const mac = await register();
		const watched = await asApple(mac.pairing);
		const joining = await join(mac, attestation);
		await joining.client.refused("attestation");
		expect(watched.reasons).toEqual(["expired"]);
	});

	it("is refused for another key than the one it attests", async () => {
		const mac = await register();
		const watched = await asApple(mac.pairing);
		const joining = await join(mac, attestation, "A".repeat(43) + "=");
		await joining.client.refused("attestation");
		expect(watched.reasons).toEqual(["key-id"]);
	});

	it("is refused cut short, with a byte after it, or with a byte of its leaf certificate changed", async () => {
		// The engine's own test alters each part in turn; here, that the relay's join refuses what the verifier refuses.
		const altered: [string, Uint8Array][] = [];
		const truncated = attestation.slice(0, attestation.length - 1);
		altered.push(["cut short", truncated]);
		const longer = new Uint8Array(attestation.length + 1);
		longer.set(attestation);
		altered.push(["with a byte after it", longer]);
		const flipped = attestation.slice();
		flipped[200] ^= 0x01;
		altered.push(["a byte of the leaf certificate changed", flipped]);
		for (const [, bytes] of altered) {
			const mac = await register();
			const watched = await asApple(mac.pairing);
			const joining = await join(mac, bytes);
			await joining.client.refused("attestation");
			expect(watched.reasons).toHaveLength(1);
		}
	});
});
