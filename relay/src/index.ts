// The relay's Worker (docs/iphone.md 5.3, #676): it takes WebSocket connections at /v1 and hands each to its
// pairing's object, which holds it with the WebSocket Hibernation API. It reads nothing a connection carries.
//
// The address carries no id, since a platform's request logs keep URLs (5.3). A connection names its pairing in the
// `Pi2-Pairing` header, only so that it reaches the right object; the pairing's object takes nothing on its word, and
// its first message, `hello`, names the pairing again. A connection without the header is a Mac that registers a new
// pairing: the Worker counts it against its address's limit and gives it a new id.
//
// Logs are off (wrangler.jsonc), and nothing here or in the objects writes to the console.

import { Address, addressName } from "./addresses.ts";
import { base64url, random } from "./bytes.ts";
import { AttestKey } from "./claims.ts";
import { Pairing } from "./pairing.ts";
import { isPairingId, PAIRING_HEADER, ROUTE_HEADER } from "./protocol.ts";
import { type Env, readSettings } from "./settings.ts";

export { Address, AttestKey, Pairing };

export default {
	async fetch(request: Request, env: Env): Promise<Response> {
		const url = new URL(request.url);
		if (url.pathname !== "/v1" || url.search !== "" || request.method !== "GET") return new Response(null, { status: 404 });
		if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") return new Response(null, { status: 426 });
		const settings = readSettings(env);
		if (settings === null) return new Response(null, { status: 503 });

		const named = request.headers.get(PAIRING_HEADER);
		if (named !== null) {
			if (!isPairingId(named)) return new Response(null, { status: 400 });
			return env.PAIRINGS.get(env.PAIRINGS.idFromName(named)).fetch(forward("hello", named));
		}

		// A registration. Cloudflare sets the connecting address; without one, nothing can be counted, so nothing is taken.
		const address = request.headers.get("CF-Connecting-IP");
		if (address === null || address === "") return new Response(null, { status: 400 });
		const limit = env.ADDRESSES.get(env.ADDRESSES.idFromName(await addressName(settings.addressKey, address, Date.now())));
		if (!(await limit.register())) return new Response(null, { status: 429 });
		const pairing = base64url(random(16));
		return env.PAIRINGS.get(env.PAIRINGS.idFromName(pairing)).fetch(forward("register", pairing));
	},
} satisfies ExportedHandler<Env>;

/** A request for the object made afresh, carrying nothing of the client's but that it asks for a WebSocket. */
function forward(route: "hello" | "register", pairing: string): Request {
	return new Request("https://pairing.invalid/v1", { headers: { Upgrade: "websocket", [ROUTE_HEADER]: route, [PAIRING_HEADER]: pairing } });
}
