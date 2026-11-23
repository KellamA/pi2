// The join's client data hash (docs/iphone.md 3.3 step 2) is worked out twice: here, by the relay, to check a join's
// attestation, and in RemoteKit (`PairingSecrets.joinClientDataHash`, #678), by the phone, to have App Attest attest
// over it. This one value, which `pi2-relay-check` holds RemoteKit to as well, keeps the two the same: SHA-256 of the
// relay's 32-byte challenge followed by the device key's 91-byte SPKI DER.

import { describe, expect, it } from "vitest";
import { fromBase64url } from "../src/bytes.ts";
import { publicKeyBytes } from "../src/crypto.ts";
import { joinClientDataHash } from "../src/join.ts";

/** The challenge: the bytes 0 to 31. */
const CHALLENGE = new Uint8Array(Array.from({ length: 32 }, (_, index) => index));
/** The public half of the P-256 key whose private scalar is 32 bytes of 0x07, as SPKI DER in base64url. */
const DEVICE_KEY = "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEHhhTL9R1TALzBB2cdc6zO4P_2BrHzk_ogsyxyYvFiW6kbDEcTi_0DdlqNlPm5FRF0y3-SG7O11x6kMahiIHAow";
const HASH = "c3e46a7e9b3066c24a4353e2f51e841768431939a3bd82533722f63a2af57c1e";

function hex(bytes: Uint8Array): string {
	return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

describe("the join's client data hash", () => {
	it("is the value RemoteKit's check holds it to", async () => {
		const key = publicKeyBytes(DEVICE_KEY);
		expect(key).not.toBeNull();
		expect(key!.length).toBe(91);
		expect(hex(await joinClientDataHash(CHALLENGE, key!))).toBe(HASH);
	});

	it("changes with the challenge and with the key", async () => {
		const key = fromBase64url(DEVICE_KEY, 91)!;
		const otherChallenge = CHALLENGE.slice();
		otherChallenge[31] ^= 1;
		expect(hex(await joinClientDataHash(otherChallenge, key))).not.toBe(HASH);
		const otherKey = key.slice();
		otherKey[90] ^= 1;
		expect(hex(await joinClientDataHash(CHALLENGE, otherKey))).not.toBe(HASH);
	});
});
