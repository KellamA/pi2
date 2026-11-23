
// Pushes through Apple's push service (docs/iphone.md 7, decision 11, #689): the relay is the one sender of pi²'s
// notifications, with the deployment's push key. The engine decides what to push, pi² Remote seals it for the device,
// and the Mac asks the relay to `push`; the relay puts the sealed bytes, as the Mac gave them, inside a payload whose
// every other word is fixed here, and posts it to Apple. So nothing the Mac or the relay writes is ever readable text on
// a notification: the phone's notification service extension replaces the title and the body with what it opens and
// verifies inside `sealed`, or with its own placeholder (question 2, answered yes on 2026-11-21).
//
// Apple's provider API, as relied on here (each from Apple's developer documentation, read 2026-11-22):
// - "Establishing a token-based connection to APNs": the provider token is a JWT signed with ES256, its header `alg`
//   and `kid` (the 10-character key id), its claims `iss` (the 10-character team id) and `iat` (seconds since the
//   epoch); "Refresh your token no more than once every 20 minutes and no less than once every 60 minutes. APNs rejects
//   any request whose token contains a timestamp that's more than one hour old"; "APNs report an error if you use a new
//   token more than once every 20 minutes on the same connection"; and "You can use the same token from multiple
//   provider servers".
// - "Sending notification requests to APNs": HTTP/2 to api.sandbox.push.apple.com (development) or api.push.apple.com
//   (production), `POST /3/device/<device token>`; the headers `authorization: bearer <token>`, `apns-topic` (the
//   app's bundle id), `apns-push-type` (`alert`, or `background`, which must have priority 5: "Using priority 10 is an
//   error"), `apns-priority` (10 "immediately"), `apns-expiration` (seconds; until then APNs stores the notification
//   and tries again), `apns-collapse-id` ("must not exceed 64 bytes"); the payload "limited to a maximum size of 4 KB
//   (4096 bytes)"; and "Don't make assumptions about device token size".
// - "Handling notification responses from APNs": 200 is success; 410 "The device token is no longer active for the
//   topic" (`Unregistered`, `ExpiredToken`); 400 `BadDeviceToken` ("... and that the token matches the environment")
//   and `DeviceTokenNotForTopic`; 403 `ExpiredProviderToken` ("a new token should be generated") and the key's other
//   faults; 429 `TooManyRequests` ("to the same device token") and `TooManyProviderTokenUpdates`; 500 and 503. "Don't
//   retry ... BadDeviceToken, DeviceTokenNotForTopic, Forbidden, ExpiredToken, Unregistered, or PayloadTooLarge"; 5XX
//   may be retried "After 15 minutes ... you may employ a back-off technique".
//
// HTTP/2: a Worker's `fetch` chooses the protocol itself and has no switch for it; APNs speaks HTTP/2 alone. Clients
// for Workers that post to APNs with plain `fetch` exist and are used; the one push this code has not yet made, to the
// owner's phone from the development relay (#689's last check), is what shows it for this relay.
//
// The relay retries nothing. A push Apple refuses for a while (429, 5XX, the network) is answered `push-later`, and
// nothing more goes to that token or that environment until the back-off below has passed; whether to ask again is the
// Mac's to decide, which knows whether the need still waits (6.5: "only for what still waits"). The push key is read
// from the deployment's secrets, imported as a key Web Crypto will not export, and the token made with it is kept in
// this isolate's memory for its allowed life: neither is ever logged, stored, sent anywhere but in Apple's
// `authorization` header, or put in an error.

import { base64url, utf8 } from "./bytes.ts";
import type { Env } from "./settings.ts";

/** How the relay posts to Apple: `fetch`, which tests replace with a stand-in for Apple's service (test/apns.ts). */
export type Post = (url: string, init: RequestInit) => Promise<Response>;

export type PushKind = "alert" | "background";
export type Environment = "development" | "production";
/** A device's push token, as the phone gave it in `token`, with the environment its build registered in. */
export type PushToken = { apns: string; environment: Environment };
/** What the Mac asked to push: its kind, the sealed bytes as their base64url text, and an alert's collapse id. */
export type Sending = { kind: PushKind; sealed: string; collapse: string | null };

/**
 * Which of Apple's two services a token is sent to. The contract has the phone say it (`token { apns, environment }`,
 * 5.3): a build signed for development registers with the sandbox, a TestFlight or App Store build with production,
 * and only the phone knows which it is (its `aps-environment` entitlement).
 */
export const HOSTS: Record<Environment, string> = {
	development: "https://api.sandbox.push.apple.com",
	production: "https://api.push.apple.com",
};

/** Apple's limit on a payload (other than VoIP's). */
export const MAX_PAYLOAD = 4096;

/**
 * The words every alert carries, fixed here: the notification service extension always replaces them (7), and they are
 * what a phone shows only if the extension cannot run at all. Nothing of the Mac's is ever beside them.
 */
export const ALERT = { title: "pi²", body: "Something needs you" } as const;

/**
 * The payload of a push, exactly (7): an alert with the fixed words and `mutable-content`, so that the extension runs;
 * or a background push, `content-available` alone, which wakes the app to take a notification away. Either carries one
 * custom key, `sealed`, the Mac's sealed bytes as base64url. No category, thread, sound, badge or anything else that
 * could tell one push from another is outside the seal.
 */
export function payload(kind: PushKind, sealed: string): string {
	if (kind === "alert") return JSON.stringify({ aps: { alert: ALERT, "mutable-content": 1 }, sealed });
	return JSON.stringify({ aps: { "content-available": 1 }, sealed });
}

/**
 * The most sealed bytes a push takes: what fits Apple's 4,096 bytes beside the alert's payload, the larger of the two,
 * once written as base64url. It is 3,000 bytes (4,000 characters, a payload of 4,095 bytes). `push` is read against it
 * (protocol.ts), and `send` checks the payload again before posting.
 */
export const MAX_SEALED = Math.floor(((MAX_PAYLOAD - utf8(payload("alert", "")).length) * 3) / 4);

/** How long Apple keeps a push for a phone that is offline: an hour, then it is dropped (the mailbox keeps the need). */
const EXPIRES_AFTER = 60 * 60;

const MINUTE = 60 * 1000;
const HOUR = 60 * MINUTE;
/** A provider token is used for 50 minutes, under Apple's hour with room for a clock that is off. */
const TOKEN_REUSE_FOR = 50 * MINUTE;
/** And never made again sooner than 20 minutes after the last, even when Apple calls it stale. */
const TOKEN_REMAKE_AFTER = 20 * MINUTE;
/** After a 5XX or a failed connection, nothing goes to that environment for 30 seconds, doubling up to 15 minutes. */
const BACK_OFF_FIRST = 30 * 1000;
const BACK_OFF_MOST = 15 * MINUTE;
/** After `TooManyRequests`, nothing goes to that device token for a minute. */
const TOKEN_BUSY_FOR = MINUTE;
/** After `TooManyProviderTokenUpdates`, nothing goes to that environment for a minute, with the same token after. */
const UPDATES_BUSY_FOR = MINUTE;
/** After Apple refuses the relay's key or topic (403, `TopicDisallowed`), nothing goes to that environment for an hour. */
const KEY_REFUSED_FOR = HOUR;

/** What became of a push: sent, or the word the Mac is answered with (README.md, "Pushes"). */
export type Outcome = "sent" | "token-dead" | "push-later" | "unavailable";

/** The deployment's push key: its id, the team's id, and the key itself, imported on first use. */
export type Credentials = { keyId: string; teamId: string; signingKey: () => Promise<CryptoKey | null> };

/**
 * The push key from the deployment's secrets (`APNS_KEY`, the `.p8` file's text; `APNS_KEY_ID`; `APNS_TEAM_ID`), or
 * null if any is missing or not well formed. A relay with no push key relays as before and answers every `push`
 * `unavailable`: a development relay is deployed before its key exists (docs/relay.md, 4), and a local one has none.
 */
export function readCredentials(env: Env): Credentials | null {
	const keyId = env.APNS_KEY_ID;
	const teamId = env.APNS_TEAM_ID;
	if (typeof keyId !== "string" || !/^[A-Z0-9]{10}$/.test(keyId)) return null;
	if (typeof teamId !== "string" || !/^[A-Z0-9]{10}$/.test(teamId)) return null;
	const der = pkcs8(env.APNS_KEY);
	if (der === null) return null;
	let imported: Promise<CryptoKey | null> | null = null;
	const signingKey = () =>
		(imported ??= crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]).catch(() => null));
	return { keyId, teamId, signingKey };
}

/** The DER of a PKCS#8 private key in PEM, as Apple's `.p8` file holds it, or null; nothing of it is ever said back. */
function pkcs8(text: unknown): Uint8Array<ArrayBuffer> | null {
	if (typeof text !== "string" || text.length > 4096) return null;
	const match = /^\s*-----BEGIN PRIVATE KEY-----([A-Za-z0-9+/=\s]+)-----END PRIVATE KEY-----\s*$/.exec(text);
	if (match === null) return null;
	let binary: string;
	try {
		binary = atob(match[1].replace(/\s+/g, ""));
	} catch {
		return null;
	}
	if (binary.length < 32) return null;
	const der = new Uint8Array(binary.length);
	for (let index = 0; index < binary.length; index++) der[index] = binary.charCodeAt(index);
	return der;
}

/**
 * The provider token, made with the push key and kept for its allowed life: reused for 50 minutes, never remade within
 * 20. Kept in this isolate's memory only, so each isolate the platform runs has its own, which Apple allows ("You can use
 * the same token from multiple provider servers").
 */
class ProviderToken {
	private current: { text: string; at: number } | null = null;
	private making: Promise<string | null> | null = null;

	constructor(private readonly credentials: Credentials) {}

	async get(now: number): Promise<string | null> {
		if (this.current !== null && now - this.current.at < TOKEN_REUSE_FOR) return this.current.text;
		// Two pairings that need a new token at once wait for the same one.
		this.making ??= this.make(now).finally(() => (this.making = null));
		return this.making;
	}

	private async make(now: number): Promise<string | null> {
		const key = await this.credentials.signingKey();
		if (key === null) return null;
		const iat = Math.floor(now / 1000);
		const signed = `${base64url(utf8(JSON.stringify({ alg: "ES256", kid: this.credentials.keyId })))}.${base64url(
			utf8(JSON.stringify({ iss: this.credentials.teamId, iat })),
		)}`;
		let signature: Uint8Array;
		try {
			// Web Crypto writes an ECDSA signature as r then s, 32 bytes each, which is what JWS's ES256 takes (RFC 7518 3.4).
			signature = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, utf8(signed)));
		} catch {
			return null;
		}
		this.current = { text: `${signed}.${base64url(signature)}`, at: iat * 1000 };
		return this.current.text;
	}

	/** Apple called the token stale (`ExpiredProviderToken`): the next push makes another, unless this one is under 20 minutes old. */
	stale(now: number): void {
		if (this.current !== null && now - this.current.at >= TOKEN_REMAKE_AFTER) this.current = null;
	}
}

type Hold = { until: number; why: "push-later" | "unavailable"; backOff: number };

/** The relay's client of Apple's push service, for one push key and topic. */
export class Apns {
	private readonly token: ProviderToken;
	/** For each environment, until when nothing is sent to it, and the last back-off, which doubles. */
	private readonly holds: Record<Environment, Hold> = {
		development: { until: 0, why: "push-later", backOff: 0 },
		production: { until: 0, why: "push-later", backOff: 0 },
	};
	/** Device tokens Apple said were pushed to too often, until when; in memory only. */
	private readonly busyTokens = new Map<string, number>();

	constructor(
		credentials: Credentials,
		/** The phone app's bundle id, which is the topic of its alerts and background pushes. */
		readonly topic: string,
		private readonly post: Post,
	) {
		this.token = new ProviderToken(credentials);
	}

	/** Why a push to this token is not sent now, if it is held back; checked before the push is counted. */
	held(token: PushToken, now: number): "push-later" | "unavailable" | null {
		const hold = this.holds[token.environment];
		if (hold.until > now) return hold.why;
		if ((this.busyTokens.get(token.apns) ?? 0) > now) return "push-later";
		return null;
	}

	/** Posts one push to Apple and says what became of it. Nothing is tried again. */
	async send(token: PushToken, sending: Sending, now: number): Promise<Outcome> {
		const body = payload(sending.kind, sending.sealed);
		if (utf8(body).length > MAX_PAYLOAD) return "unavailable";
		const providerToken = await this.token.get(now);
		if (providerToken === null) return "unavailable";
		const headers: Record<string, string> = {
			authorization: `bearer ${providerToken}`,
			"apns-topic": this.topic,
			"apns-push-type": sending.kind,
			"apns-priority": sending.kind === "alert" ? "10" : "5",
			"apns-expiration": String(Math.floor(now / 1000) + EXPIRES_AFTER),
		};
		if (sending.collapse !== null) headers["apns-collapse-id"] = sending.collapse;
		let response: Response;
		try {
			response = await this.post(`${HOSTS[token.environment]}/3/device/${token.apns}`, { method: "POST", headers, body, redirect: "manual" });
		} catch {
			this.backOff(token.environment, now);
			return "push-later";
		}
		const reason = response.status === 200 ? null : await readReason(response);
		if (response.status === 200) await response.body?.cancel();
		return this.answer(response.status, reason, token, now);
	}

	private answer(status: number, reason: string | null, token: PushToken, now: number): Outcome {
		const environment = token.environment;
		if (status === 200) {
			this.holds[environment].backOff = 0;
			return "sent";
		}
		// The token is no good for this app in this environment: forgotten, and never tried again (Apple: "Don't retry").
		if (status === 410 || (status === 400 && (reason === "BadDeviceToken" || reason === "DeviceTokenNotForTopic"))) return "token-dead";
		if (status === 403 && reason === "ExpiredProviderToken") {
			this.token.stale(now);
			return "push-later";
		}
		if (status === 429) {
			if (reason === "TooManyRequests") {
				this.pruneBusy(now);
				this.busyTokens.set(token.apns, now + TOKEN_BUSY_FOR);
			} else {
				// `TooManyProviderTokenUpdates`, or a 429 Apple does not explain: the token is kept, and the environment rests.
				this.holds[environment] = { ...this.holds[environment], until: now + UPDATES_BUSY_FOR, why: "push-later" };
			}
			return "push-later";
		}
		if (status >= 500) {
			this.backOff(environment, now);
			return "push-later";
		}
		// Apple refused the relay's key, team or topic for this environment: the deployment's fault, and not one that
		// passes by itself. Nothing is sent there for an hour; the owner fixes the secret, and a deploy starts afresh.
		if (status === 403 || reason === "TopicDisallowed") {
			this.holds[environment] = { ...this.holds[environment], until: now + KEY_REFUSED_FOR, why: "unavailable" };
			return "unavailable";
		}
		// Anything else is a request of the relay's own that Apple found wrong; nothing the Mac can mend by asking again.
		return "unavailable";
	}

	private backOff(environment: Environment, now: number): void {
		const hold = this.holds[environment];
		const backOff = hold.backOff === 0 ? BACK_OFF_FIRST : Math.min(hold.backOff * 2, BACK_OFF_MOST);
		this.holds[environment] = { until: now + backOff, why: "push-later", backOff };
	}

	private pruneBusy(now: number): void {
		if (this.busyTokens.size < 1000) return;
		for (const [token, until] of this.busyTokens) if (until <= now) this.busyTokens.delete(token);
	}
}

/** The `reason` of Apple's answer, read from at most a kilobyte of it, or null. */
async function readReason(response: Response): Promise<string | null> {
	try {
		const text = await response.text();
		if (text.length > 1024) return null;
		const reason = (JSON.parse(text) as { reason?: unknown }).reason;
		return typeof reason === "string" && /^[A-Za-z]{1,64}$/.test(reason) ? reason : null;
	} catch {
		return null;
	}
}

/** This isolate's client, made once for the deployment's secrets and kept while they stay the same. */
let shared: { secrets: string[]; apns: Apns } | null = null;

/** The deployment's client of Apple's push service, or null if it has no push key, or one not well formed. */
export function apnsFor(env: Env, topic: string): Apns | null {
	const secrets = [env.APNS_KEY ?? "", env.APNS_KEY_ID ?? "", env.APNS_TEAM_ID ?? "", topic];
	if (shared !== null && shared.secrets.every((value, index) => value === secrets[index])) return shared.apns;
	shared = null;
	const credentials = readCredentials(env);
	if (credentials === null) return null;
	shared = { secrets, apns: new Apns(credentials, topic, (url, init) => fetch(url, init)) };
	return shared.apns;
}

/**
 * 6.6's push limits, for each device an hour: 120 alerts and 60 background pushes. (Its 60 Live Activity updates are
 * P30's, with the Live Activity part of this file.)
 */
export type PushLimits = Record<PushKind, number>;
export const PUSH_LIMITS: PushLimits = { alert: 120, background: 60 };
/**
 * And for the whole pairing, five devices' worth (3.5), counted apart, so that removing a device and adding another
 * does not start its count afresh.
 */
const PAIRING_TIMES = 5;
const PAIRING = "pairing";

/** The pushes counted this hour, by device and for the pairing; what the pairing's object stores as `pushes`. */
export type PushHour = { hour: number; counts: Record<string, Record<PushKind, number>> };

export class PushCounts {
	private state: PushHour;

	constructor(saved: PushHour | undefined) {
		this.state = saved ?? { hour: 0, counts: {} };
	}

	/** Whether one more push of `kind` to `device` fits this hour, for the device and for the pairing. */
	allows(device: string, kind: PushKind, now: number, limits: PushLimits): boolean {
		this.roll(now);
		const counts = this.state.counts;
		return (counts[device]?.[kind] ?? 0) < limits[kind] && (counts[PAIRING]?.[kind] ?? 0) < limits[kind] * PAIRING_TIMES;
	}

	/**
	 * Counts one push sent; gives what to store. Devices no longer listed are dropped from it as it goes, so a removed
	 * device's id stays no longer than the hour, and only the pairing's count remembers it.
	 */
	add(device: string, kind: PushKind, now: number, listed: (device: string) => boolean): PushHour {
		this.roll(now);
		const counts = this.state.counts;
		for (const id of Object.keys(counts)) if (id !== PAIRING && !listed(id)) delete counts[id];
		for (const id of [device, PAIRING]) {
			counts[id] ??= { alert: 0, background: 0 };
			counts[id][kind] += 1;
		}
		return this.state;
	}

	private roll(now: number): void {
		const hour = Math.floor(now / HOUR);
		if (this.state.hour !== hour) this.state = { hour, counts: {} };
	}
}
