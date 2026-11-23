// The relay's Worker (docs/iphone.md 5.3, #676): it takes WebSocket connections at /v1 and hands each to its
// pairing's object, which holds it with the WebSocket Hibernation API. It reads nothing a connection carries.
//
// The address carries no id, since a platform's request logs keep URLs (5.3). A connection names its pairing in the
// `Pi2-Pairing` header, only so that it reaches the right object; the pairing's object takes nothing on its word, and
// its first message, `hello`, names the pairing again. A connection without the header is a Mac that registers a new
// pairing: the Worker gives it a new id. Every connection is counted against its address first (addresses.ts), and an
// IPv6 address's against its block's too, a registration against the registrations' limits as well, before any
// pairing's object is woken.
//
// Logs are off (wrangler.jsonc), and nothing here or in the objects writes to the console.

import { Address, type Admission, addressCounted, addressNames } from "./addresses.ts";
import { base64url, random } from "./bytes.ts";
import { AttestKey } from "./claims.ts";
import { Pairing } from "./pairing.ts";
import { isPairingId, PAIRING_HEADER, ROUTE_HEADER } from "./protocol.ts";
import { type Env, readSettings } from "./settings.ts";

export { Address, AttestKey, Pairing };

export default {
	async fetch(request: Request, env: Env): Promise<Response> {
		// Only pi² Remote and the phone talk to the relay, and neither is a web page. A browser always says which page a
		// WebSocket comes from, so a page that tried to make its visitors register pairings, or knock on one, is refused
		// here, before anything is counted or any object woken.
		if (request.headers.has("Origin")) return new Response(null, { status: 403 });
		const url = new URL(request.url);
		if (url.pathname !== "/v1" || url.search !== "" || request.method !== "GET") return new Response(null, { status: 404 });
		if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") return new Response(null, { status: 426 });
		const settings = readSettings(env);
		if (settings === null) return new Response(null, { status: 503 });

		const named = request.headers.get(PAIRING_HEADER);
		if (named !== null && !isPairingId(named)) return new Response(null, { status: 400 });

		// Cloudflare sets the connecting address on every request that reaches the Worker, and overwrites a client's own;
		// one without an address that reads as one is no client's, and nothing can be counted for it, so nothing is taken.
		const counted = addressCounted(request.headers.get("CF-Connecting-IP"));
		if (counted === null) return new Response(null, { status: 400 });
		const now = Date.now();
		const names = await addressNames(settings.addressKey, counted, now);
		for (const name of [names.group, names.block]) {
			const until = name === null ? undefined : held.get(name);
			if (until !== undefined && until > now) return tooMany(until, now);
		}
		let admission: Admission;
		try {
			// The group's object asks the block's itself, so that each counts only what both take.
			admission = await env.ADDRESSES.get(env.ADDRESSES.idFromName(names.group)).admit(named === null, names.block);
		} catch {
			// The address's object, or its block's, did not answer, most likely overloaded by that same address or block:
			// refused, rather than taken uncounted, which is what such a flood would be after.
			return new Response(null, { status: 503, headers: { "Retry-After": "60" } });
		}
		if (!admission.pass) {
			const name = admission.by === "block" ? names.block : names.group;
			if (admission.limit === "connections" && name !== null) hold(name, admission.until);
			return tooMany(admission.until, now);
		}

		if (named !== null) return env.PAIRINGS.get(env.PAIRINGS.idFromName(named)).fetch(forward("hello", named));
		const pairing = base64url(random(16));
		return env.PAIRINGS.get(env.PAIRINGS.idFromName(pairing)).fetch(forward("register", pairing));
	},
} satisfies ExportedHandler<Env>;

/** A request for the object made afresh, carrying nothing of the client's but that it asks for a WebSocket. */
function forward(route: "hello" | "register", pairing: string): Request {
	return new Request("https://pairing.invalid/v1", { headers: { Upgrade: "websocket", [ROUTE_HEADER]: route, [PAIRING_HEADER]: pairing } });
}

/**
 * Addresses and blocks past their connections' limit, by their object's name, and until when, as this isolate last heard
 * from the objects: a flood from one address, or from the /64s of one block, is refused here, without a call to an
 * object each time. Only ever a refusal, and only until the object's own time, so it is never more lenient than the
 * object. Bounded, the oldest forgotten first.
 */
const held = new Map<string, number>();
const MAX_HELD = 1024;

function hold(name: string, until: number): void {
	held.delete(name);
	if (held.size >= MAX_HELD) {
		const now = Date.now();
		for (const [other, time] of held) if (time <= now) held.delete(other);
		if (held.size >= MAX_HELD) held.delete(held.keys().next().value!);
	}
	held.set(name, until);
}

/** 429 with the seconds until the address may come back (pi² Remote waits a minute at least either way). */
function tooMany(until: number, now: number): Response {
	return new Response(null, { status: 429, headers: { "Retry-After": String(Math.max(1, Math.ceil((until - now) / 1000))) } });
}
