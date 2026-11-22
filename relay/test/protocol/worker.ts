// The relay as the protocol test runs it (docs/iphone.md 10, #678): the relay's own Worker and objects, unchanged but
// for one thing, App Attest's verifier, which a test on a computer cannot pass with a real attestation (it is made only
// by a phone, and Apple's sample is checked only at its own date). In its place, a stand-in that takes exactly the
// client data hash the relay worked out followed by the key id, and nothing else: so the test still shows that the
// Swift client sends the join's client data hash the relay expects (`PairingSecrets.joinClientDataHash`), byte for byte.
//
// Run only by scripts/relay-protocol-test, through scripts/isolated.mjs, on 127.0.0.1, with wrangler.jsonc beside this
// file. Nothing deploys it: the relay's own wrangler.jsonc names src/index.ts, and check-bundle reads that. It also
// answers /redirect with a redirect to /v1, for the check that the client follows none.

import type { AppAttestExpected, AppAttestResult } from "../../src/attest.ts";
import { concat, same } from "../../src/bytes.ts";
import worker, { Address, AttestKey, Pairing as RelayPairing } from "../../src/index.ts";
import type { Env } from "../../src/settings.ts";

async function standIn(attestation: Uint8Array, expected: AppAttestExpected): Promise<AppAttestResult> {
	if (!same(attestation, concat(expected.clientDataHash, expected.keyId))) throw new Error("not the stand-in's attestation");
	// As an attestation from before iOS 27, with neither of Apple's extensions; the test's settings take `none`.
	return { publicKey: new Uint8Array(65), environment: expected.environments[0], receipt: new Uint8Array(0), validationCategory: null, bundleVersion: null };
}

export class Pairing extends RelayPairing {
	override verify = standIn;
}

export { Address, AttestKey };

export default {
	async fetch(request: Request, env: Env): Promise<Response> {
		// A redirect to the relay itself, which the client must not follow (#678's security read): followed, the
		// connection would succeed; refused, it ends with the 302.
		if (new URL(request.url).pathname === "/redirect") return new Response(null, { status: 302, headers: { Location: "/v1" } });
		// Cloudflare sets the connecting address, which registrations are counted by; the local runtime may not.
		if (request.headers.has("CF-Connecting-IP")) return worker.fetch(request, env);
		const headers = new Headers(request.headers);
		headers.set("CF-Connecting-IP", "127.0.0.1");
		return worker.fetch(new Request(request, { headers }), env);
	},
} satisfies ExportedHandler<Env>;
