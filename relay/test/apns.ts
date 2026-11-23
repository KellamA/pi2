
// A stand-in for Apple's push service (docs/iphone.md 10; README.md, "Pushes"), for the relay's tests and for a local
// relay's Worker: it takes what the relay would post to Apple, checks it as Apple would (the provider token's ES256
// signature, its `kid`, `iss` and `iat`; the host, the path and the headers), keeps a record of each push, and answers as
// the test says, 200 unless told otherwise. It signs with a throwaway key it makes itself: no key of anyone's is here,
// and nothing reaches Apple.
//
// It is in `test/`, never in `src/`: the Worker as deployed bundles only `src/` (and the engine's verifier), which
// `npm run check-bundle` checks, so it cannot be in what is shipped. It imports nothing of the tests' runtime, so that a
// local relay's Worker can take it as it is. A test puts it in a pairing's object (`standInApns` in push.test.ts); a
// local relay's Worker (P10's `test/protocol/worker.ts`, P15's recorder) with `override apns = standIn.client`, and
// reads `pushes` for the payloads that `xcrun simctl push` and the sealed-bytes check need.

import { Apns, type Environment, HOSTS, type Post } from "../src/apns.ts";
import { base64, fromBase64url, utf8 } from "../src/bytes.ts";

/** One push as Apple would have received it. */
export type RecordedPush = {
	/** The relay's clock when it posted. */
	at: number;
	environment: Environment;
	/** The device token, from the path. */
	token: string;
	/** Every header but `authorization`, whose token is in `providerToken`. */
	headers: Record<string, string>;
	/** The provider token, its header and claims, and whether its signature verified with the stand-in's key. */
	providerToken: { text: string; header: unknown; claims: unknown; verified: boolean };
	/** The body, exactly as posted. */
	payload: string;
};

/** How Apple answers a push: a status and, unless it is 200, a reason. */
export type Answer = { status: number; reason?: string };

export class ApnsStandIn {
	/** Every push posted, in order. */
	readonly pushes: RecordedPush[] = [];
	/**
	 * How the next posts are answered, in order, each an answer or a function that gives one (and is given the request's
	 * signal, which aborts it as `fetch` would be); then 200.
	 */
	readonly answers: (Answer | ((push: RecordedPush, signal: AbortSignal | null) => Promise<Answer>))[] = [];
	/** How long the relay's client waits for an answer; set before its first push. */
	timeout: number | undefined = undefined;
	/** A post fails as a network would, without an answer, while this is set. */
	unreachable = false;
	readonly keyId = "STANDIN123";
	readonly teamId = "TEAMSTAND1";
	/** Made on first use, not when the stand-in is: a Worker may make no random values in its global scope. */
	private keyPair: Promise<CryptoKeyPair> | null = null;
	private made: Apns | null = null;

	/** What the relay posts with in place of `fetch`. */
	readonly post: Post = async (url, init) => {
		if (this.unreachable) throw new TypeError("Network connection lost.");
		const match = /^(https:\/\/[a-z.]+)\/3\/device\/([0-9a-f]+)$/.exec(url);
		const environment = (Object.keys(HOSTS) as Environment[]).find((name) => HOSTS[name] === match?.[1]);
		if (match === null || environment === undefined || init.method !== "POST") return answer({ status: 404, reason: "BadPath" });
		const headers: Record<string, string> = {};
		new Headers(init.headers).forEach((value, name) => (headers[name] = value));
		const bearer = headers.authorization ?? "";
		delete headers.authorization;
		const push: RecordedPush = {
			at: Date.now(),
			environment,
			token: match[2],
			headers,
			providerToken: await this.read(bearer.replace(/^bearer /, "")),
			payload: typeof init.body === "string" ? init.body : "",
		};
		this.pushes.push(push);
		if (!push.providerToken.verified) return answer({ status: 403, reason: "InvalidProviderToken" });
		const next = this.answers.shift();
		return answer(next === undefined ? { status: 200 } : typeof next === "function" ? await next(push, init.signal ?? null) : next);
	};

	/** The relay's client, signing with the stand-in's key and posting to it: what a pairing's `apns` gives. */
	readonly client = (topic: string): Apns => {
		this.made ??= new Apns({ keyId: this.keyId, teamId: this.teamId, signingKey: async () => (await this.keys()).privateKey }, topic, this.post, this.timeout);
		return this.made;
	};

	/** The stand-in's key as a `.p8` file holds it, for the tests of reading the deployment's secrets. */
	static async pem(): Promise<{ pem: string; publicKey: CryptoKey }> {
		const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair;
		const der = new Uint8Array((await crypto.subtle.exportKey("pkcs8", pair.privateKey)) as ArrayBuffer);
		const lines = base64(der).match(/.{1,64}/g)!.join("\n");
		return { pem: `-----BEGIN PRIVATE KEY-----\n${lines}\n-----END PRIVATE KEY-----\n`, publicKey: pair.publicKey };
	}

	private keys(): Promise<CryptoKeyPair> {
		return (this.keyPair ??= crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, false, ["sign", "verify"]) as Promise<CryptoKeyPair>);
	}

	private async read(text: string): Promise<RecordedPush["providerToken"]> {
		const parts = text.split(".");
		const json = (part: string | undefined) => {
			const bytes = part === undefined ? null : fromBase64url(part);
			try {
				return bytes === null ? null : JSON.parse(new TextDecoder().decode(bytes));
			} catch {
				return null;
			}
		};
		const header = json(parts[0]);
		const claims = json(parts[1]);
		const signature = parts.length === 3 ? fromBase64url(parts[2], 64) : null;
		let verified = false;
		if (signature !== null && header?.alg === "ES256" && header?.kid === this.keyId && claims?.iss === this.teamId) {
			const age = Date.now() / 1000 - claims.iat;
			verified =
				Object.keys(header).length === 2 &&
				Object.keys(claims).length === 2 &&
				Number.isInteger(claims.iat) &&
				age >= 0 &&
				age < 60 * 60 &&
				(await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, (await this.keys()).publicKey, new Uint8Array(signature), utf8(`${parts[0]}.${parts[1]}`)));
		}
		return { text, header, claims, verified };
	}
}

function answer({ status, reason }: Answer): Response {
	return new Response(status === 200 ? null : JSON.stringify({ reason }), { status, headers: status === 200 ? {} : { "content-type": "application/json" } });
}
