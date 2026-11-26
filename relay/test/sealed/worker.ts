// The relay as the sealed-bytes check runs it (docs/iphone.md 10, #683): the protocol test's relay (../protocol, the
// relay's own Worker and objects with App Attest's stand-in), with the recorder in front of it at the Worker's edge,
// and its objects able to read back what they keep. `GET /recording` gives everything the recorder kept and every
// object the recording names, read back, as JSON (scan.ts's `encode`).
//
// Its pairings push through the stand-in for Apple's service (../apns.ts) in place of Apple's (#689): nothing is sent
// anywhere, and every request the relay makes of Apple is given with the recording, as `pushes`, its address, headers
// (`authorization` among them) and body exactly as posted, for scan.ts to check.
//
// It also shows that what the relay would write to the console reaches the output the check reads: each `/recording`
// writes two canaries made afresh, one with `console.log` and one with `console.debug`, and gives them with the
// recording, so that check.mjs fails if either is missing from the local runtime's output. `?log=<text>` writes that
// text with `console.log` too: the planted session's way of planting a marker in the relay's console. This is the test's
// Worker, never the relay's: sealed.test.ts holds relay/src to writing nothing.
//
// Run only by `scripts/relay-protocol-test --sealed`, through scripts/isolated.mjs, on 127.0.0.1, with wrangler.jsonc
// beside this file. Nothing deploys it: the relay's own wrangler.jsonc names src/index.ts, and check-bundle reads that.

import { addressGroup, addressName, Address as RelayAddress } from "../../src/addresses.ts";
import { HOSTS } from "../../src/apns.ts";
import { utf8 } from "../../src/bytes.ts";
import { AttestKey as RelayAttestKey } from "../../src/claims.ts";
import { type Env, readSettings } from "../../src/settings.ts";
import { ApnsStandIn } from "../apns.ts";
import protocolTest, { Pairing as ProtocolPairing } from "../protocol/worker.ts";
import { dump, Recorder } from "./recorder.ts";
import { encode, type Push, type Stored } from "./scan.ts";

const recorder = new Recorder();
/** Apple's service, stood in: one for every pairing of the run, whose `pushes` go with the recording. */
const apple = new ApnsStandIn();

/** A push as the stand-in took it, as the recording gives it: the address, every header, the body. */
function recorded(push: ApnsStandIn["pushes"][number]): Push {
	return {
		url: `${HOSTS[push.environment]}/3/device/${push.token}`,
		headers: [["authorization", `bearer ${push.providerToken.text}`], ...Object.entries(push.headers)],
		body: utf8(push.payload),
	};
}

export class Pairing extends ProtocolPairing {
	override apns = apple.client;

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
			// Connections and registrations are counted under a keyed hash of the address's group and the day
			// (README.md): every connection here comes from 127.0.0.1.
			const settings = readSettings(env);
			if (settings !== null) {
				const name = await addressName(settings.addressKey, addressGroup("127.0.0.1")!, Date.now());
				stored.push(await (env.ADDRESSES.get(env.ADDRESSES.idFromName(name)) as unknown as Dumps).dump(name));
			}
			const canaries = { log: `pi2-canary-log-${crypto.randomUUID()}`, debug: `pi2-canary-debug-${crypto.randomUUID()}` };
			console.log(canaries.log);
			console.debug(canaries.debug);
			const planted = url.searchParams.get("log");
			if (planted !== null) console.log(planted);
			return Response.json(encode({ events: recorder.events, stored, pushes: [...recorder.pushes, ...apple.pushes.map(recorded)], canaries }));
		}
		return recorder.fetch(request, (forwarded) => protocolTest.fetch(forwarded, env));
	},
} satisfies ExportedHandler<Env>;
