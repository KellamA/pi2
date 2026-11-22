// What the relay asks of a phone that joins a pairing (docs/iphone.md 3.3 step 2, 6.6): App Attest's attestation of a
// genuine pi² for iPhone, through the engine's verifier, and what this deployment takes of what Apple says about it.

import type { AppAttestExpected, AppAttestResult } from "./attest.ts";
import { concat } from "./bytes.ts";
import { sha256 } from "./crypto.ts";
import { compareBuilds, readBuild, type Why } from "./protocol.ts";
import type { Settings } from "./settings.ts";

export type Verifier = (attestation: Uint8Array, expected: AppAttestExpected) => Promise<AppAttestResult>;

/**
 * The client data hash a joining phone passes to `attestKey`: SHA-256 of the relay's challenge (32 bytes) followed by
 * the device key's SPKI DER, so that the attested copy of the app vouches for this device key on this connection, as
 * step 4's does for the Mac (6.6: "Binding the attestation to the device key keeps a script from bringing a key of its
 * own").
 */
export async function joinClientDataHash(challenge: Uint8Array, deviceKey: Uint8Array): Promise<Uint8Array<ArrayBuffer>> {
	return sha256(concat(challenge, deviceKey));
}

/**
 * Checks a join's attestation: the verifier's checks (Apple's root, the team and bundle ids, the key id, the client data
 * hash, the environments this deployment takes, the time), then Apple's validation category and bundle version, which
 * the verifier gives without judging them. Answers null if it is taken, or why not.
 */
export async function checkAttestation(
	verify: Verifier,
	settings: Settings,
	attestation: Uint8Array,
	keyId: Uint8Array,
	clientDataHash: Uint8Array,
): Promise<Why | null> {
	let result: AppAttestResult;
	try {
		// Bytes made here, in this runtime: the verifier takes only its own `Uint8Array`s.
		result = await verify(new Uint8Array(attestation), {
			teamId: settings.teamId,
			bundleId: settings.bundleId,
			keyId: new Uint8Array(keyId),
			clientDataHash: new Uint8Array(clientDataHash),
			environments: settings.environments,
			// No `now`: the attestation is checked as it arrives, at the relay's own time (the verifier's header).
		});
	} catch {
		return "attestation";
	}
	return judge(settings, result.validationCategory, result.bundleVersion);
}

/**
 * Apple's two extensions (iOS 27 and later add them together, signed into the authenticator data, so they cannot be
 * taken off): the validation category must be one this deployment lists, and the bundle version must be a build at or
 * above the minimum for a phone. An attestation without them (an earlier iOS) is taken only where the deployment lists
 * `none` among its categories.
 */
export function judge(settings: Settings, category: number | null, bundleVersion: string | null): Why | null {
	if (category === null || bundleVersion === null) {
		return category === null && bundleVersion === null && settings.categories.none ? null : "category";
	}
	if (!settings.categories.values.includes(category)) return "category";
	const build = readBuild(bundleVersion);
	if (build === null || compareBuilds(build, settings.minimum.device) < 0) return "bundle-version";
	return null;
}
