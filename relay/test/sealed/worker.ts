// The relay as the sealed-bytes check runs it (docs/iphone.md 10, #683): the protocol test's relay (../protocol, the
// relay's own Worker and objects with App Attest's stand-in), with the recorder in front of it at the Worker's edge,
// and its objects able to read back what they keep. `GET /recording` gives everything the recorder kept and every
// object the recording names, read back, as JSON (scan.ts's `encode`).
//
// Run only by `scripts/relay-protocol-test --sealed`, through scripts/isolated.mjs, on 127.0.0.1, with wrangler.jsonc
// beside this file. Nothing deploys it: the relay's own wrangler.jsonc names src/index.ts, and check-bundle reads that.

import { Address as RelayAddress, addressName } from "../../src/addresses.ts";
import { AttestKey as RelayAttestKey } from "../../src/claims.ts";
import { type Env, readSettings } from "../../src/settings.ts";
import protocolTest, { Pairing as ProtocolPairing } from "../protocol/worker.ts";
import { dump, Recorder } from "./recorder.ts";
import { encode, type Stored } from "./scan.ts";

const recorder = new Recorder();

export class Pairing extends ProtocolPairing {
	async dump(name: string): Promise<Stored> {
		return dump("pairing", name, this.ctx);
	}
}

export class AttestKey extends RelayAttestKey {
	async dump(name: string): Promise<Stored> {
		return dump("attestKey", name, this.ctx);
	}
}

export class Address extends RelayAddress {
	async dump(name: string): Promise<Stored> {
		return dump("address", name, this.ctx);
	}
}

type Dumps = { dump(name: string): Promise<Stored> };

export default {
	async fetch(request: Request, env: Env): Promise<Response> {
		const url = new URL(request.url);
		if (url.pathname === "/recording" && request.method === "GET" && !request.headers.has("Upgrade")) {
			const { pairings, attestKeys } = recorder.named();
			const stored: Stored[] = [];
			for (const name of pairings) stored.push(await (env.PAIRINGS.get(env.PAIRINGS.idFromName(name)) as unknown as Dumps).dump(name));
			for (const name of attestKeys) stored.push(await (env.ATTEST_KEYS.get(env.ATTEST_KEYS.idFromName(name)) as unknown as Dumps).dump(name));
			// Registrations are counted under a keyed hash of the address and the day (README.md): the protocol test's
			// worker gives every connection 127.0.0.1.
			const settings = readSettings(env);
			if (settings !== null) {
				const name = await addressName(settings.addressKey, "127.0.0.1", Date.now());
				stored.push(await (env.ADDRESSES.get(env.ADDRESSES.idFromName(name)) as unknown as Dumps).dump(name));
			}
			return Response.json(encode({ events: recorder.events, stored, pushes: recorder.pushes }));
		}
		return recorder.fetch(request, (forwarded) => protocolTest.fetch(forwarded, env));
	},
} satisfies ExportedHandler<Env>;
