// The relay as the protocol test runs it (docs/iphone.md 10, #678): the relay's own Worker and objects, unchanged but
// for one thing, App Attest's verifier, which a test on a computer cannot pass with a real attestation (it is made only
// by a phone, and Apple's sample is checked only at its own date). In its place, a stand-in that takes exactly the
// client data hash the relay worked out followed by the key id, and nothing else: so the test still shows that the
// Swift client sends the join's client data hash the relay expects (`PairingSecrets.joinClientDataHash`), byte for byte.
//
// Run only by scripts/relay-protocol-test, through scripts/isolated.mjs, on 127.0.0.1, with wrangler.jsonc beside this
// file. Nothing deploys it: the relay's own wrangler.jsonc names src/index.ts, and check-bundle reads that. It also
// answers /redirect with a redirect to /v1, for the check that the client follows none.
//
// With `PUSH_STAND_IN` set to `on` (`scripts/relay-protocol-test --remote` sets it, #935), its pairings push through the
// stand-in for Apple's service (../apns.ts) in place of the push key, which this relay has none of: nothing is sent
// anywhere. Then `GET /pushes` gives what the stand-in took, in order (its environment, token, headers and payload,
// exactly as posted), and `POST /pushes/hold` holds Apple's answer to the next push until `POST /pushes/release`, or
// until the relay gives it up (10 seconds), so that pi2-remote-helper-check can revoke a device while its push waits.
// Without it, as `pi2-relay-check --relay` runs, a push is answered `unavailable`, as by a relay with no push key, and
// those paths are the relay's own.

import { apnsFor } from "../../src/apns.ts";
import type { AppAttestExpected, AppAttestResult } from "../../src/attest.ts";
import { concat, same } from "../../src/bytes.ts";
import worker, { Address, AttestKey, Pairing as RelayPairing } from "../../src/index.ts";
import type { Env } from "../../src/settings.ts";
import { ApnsStandIn } from "../apns.ts";

/** The test's own switch, given on the command line, never one of the relay's settings. */
type TestEnv = Env & { PUSH_STAND_IN?: string };

const apple = new ApnsStandIn();
/** Whether a push's answer is held (`/pushes/hold`), and released. A flag read in the held answer's own request. */
let held = { released: true };

function standingIn(env: Env): boolean {
	return (env as TestEnv).PUSH_STAND_IN === "on";
}

async function standIn(attestation: Uint8Array, expected: AppAttestExpected): Promise<AppAttestResult> {
	if (!same(attestation, concat(expected.clientDataHash, expected.keyId))) throw new Error("not the stand-in's attestation");
	// As an attestation from before iOS 27, with neither of Apple's extensions; the test's settings take `none`.
	return { publicKey: new Uint8Array(65), environment: expected.environments[0], receipt: new Uint8Array(0), validationCategory: null, bundleVersion: null };
}

export class Pairing extends RelayPairing {
	override verify = standIn;
	override apns = (topic: string) => (standingIn(this.env) ? apple.client(topic) : apnsFor(this.env, topic));
}

/** The stand-in's routes, with `PUSH_STAND_IN` on; null for any other request. */
function pushes(request: Request, env: Env): Response | null {
	if (!standingIn(env) || request.headers.has("Upgrade")) return null;
	const path = new URL(request.url).pathname;
	if (path === "/pushes" && request.method === "GET") {
		return Response.json(apple.pushes.map(({ environment, token, headers, payload }) => ({ environment, token, headers, payload })));
	}
	if (path === "/pushes/hold" && request.method === "POST") {
		const hold = { released: false };
		held = hold;
		// Polled in the push's own request: a promise is not resolved from another request's context.
		apple.answers.push(async (_push, signal) => {
			while (!hold.released && signal?.aborted !== true) await new Promise((wake) => setTimeout(wake, 20));
			return { status: 200 };
		});
		return new Response(null, { status: 204 });
	}
	if (path === "/pushes/release" && request.method === "POST") {
		held.released = true;
		return new Response(null, { status: 204 });
	}
	return null;
}

export { Address, AttestKey };

export default {
	async fetch(request: Request, env: Env): Promise<Response> {
		const standIn = pushes(request, env);
		if (standIn !== null) return standIn;
		// A redirect to the relay itself, which the client must not follow (#678's security read): followed, the
		// connection would succeed; refused, it ends with the 302.
		if (new URL(request.url).pathname === "/redirect") return new Response(null, { status: 302, headers: { Location: "/v1" } });
		// The client's fixed headers in place of URLSession's own, which would name the system and its locale (#678): a
		// connection without them is answered 400, so every check that connects shows them. A connection with an Origin
		// (a web page's, which the protocol test makes on purpose) goes on to the relay's own 403.
		const upgrade = request.headers.get("Upgrade")?.toLowerCase() === "websocket";
		if (upgrade && !request.headers.has("Origin") && (request.headers.get("User-Agent") !== "pi2-relay-client" || request.headers.get("Accept-Language") !== "*")) {
			return new Response(null, { status: 400 });
		}
		// Cloudflare sets the connecting address, which registrations are counted by; the local runtime may not.
		if (request.headers.has("CF-Connecting-IP")) return worker.fetch(request, env);
		const headers = new Headers(request.headers);
		headers.set("CF-Connecting-IP", "127.0.0.1");
		return worker.fetch(new Request(request, { headers }), env);
	},
} satisfies ExportedHandler<Env>;
