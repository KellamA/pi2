// The relay's protocol (docs/iphone.md 5.3; README.md, "The protocol"): what each text message is, read strictly. A
// text message is one JSON object with one member, named for the message, whose value is an object; and it must be
// written exactly as JavaScript's `JSON.stringify` writes what it holds: compact, no key twice, no escape that need not
// be one. So there is one way to write each message, and nothing about it is left to guess.
//
// Nothing a client sends is ever written back to it or anywhere else: a message that is not one of these is refused
// with a fixed word (`Why`), never with what was in it.

import { fromBase64, fromBase64url } from "./bytes.ts";
import { publicKeyBytes } from "./crypto.ts";

/** The headers the Worker gives a pairing's object, made afresh: the object sees nothing else of the client's request. */
export const ROUTE_HEADER = "Pi2-Route";
export const PAIRING_HEADER = "Pi2-Pairing";

/**
 * What an end signs to prove itself (`proof`) or to leave (`leave`): the UTF-8 bytes of `pi2-relay-v1`, then, each after
 * a zero byte, what is signed (`mac`, `device`, `register` or `leave`), the pairing's id, the device's id, and the
 * challenge the relay gave this connection, as base64url. A field that does not apply (the pairing at `register`, the
 * device for a Mac) is empty. Signed with the relay key (a Mac) or the device key (a phone), as ECDSA P-256 over
 * SHA-256, 64 bytes, r then s, in base64url, as every signature of RemoteKit's.
 */
export function proofText(what: "mac" | "device" | "register" | "leave", pairing: string, device: string, challenge: string): string {
	return ["pi2-relay-v1", what, pairing, device, challenge].join("\0");
}

/** The longest text message taken: a `join` with its attestation (at most 32 KB of bytes, as base64url) is the longest. */
export const MAX_TEXT = 48 * 1024;
/** The longest binary message taken: a Noise message (at most 65,535 bytes) and a device's id (6.6: "70 KB"). */
export const MAX_BINARY = 70 * 1024;
/** A sealed item: at most 16 KB, and at least HPKE's encapsulated key (65 bytes, an uncompressed point) and a tag. */
export const MAX_ITEM = 16 * 1024;
const MIN_ITEM = 65 + 16;
/** App Attest makes some 6 KB; the verifier takes no more than this. */
const MAX_ATTESTATION = 32 * 1024;

/** The fixed words a refusal carries, in `{"refused":{"why":…}}` and as a closing socket's reason. */
export type Why =
	| "malformed" // not a message of the protocol, or not one this end may send now
	| "unavailable" // the relay is missing a setting, or something it needs failed
	| "unknown-pairing"
	| "not-listed" // a device whose slot is not listed
	| "signature" // the challenge was not signed with the key on record
	| "update-required" // a build below the minimum for its role
	| "another-mac" // a Mac socket is already connected
	| "limits" // the pairing went past twice a limit, and is closed for an hour
	| "too-many" // too many registrations from one address, or connections waiting to prove themselves
	| "timeout" // nothing proved within ten seconds
	| "window-closed" // no join window open, or it was closed by three refused joins
	| "token" // a join token that is not the window's
	| "attestation" // an App Attest attestation the verifier refused
	| "category" // Apple's validation category, or its absence, is not one this deployment takes
	| "bundle-version" // Apple's bundle version is below the minimum build
	| "attest-key-taken" // the attested key is already tied to another pairing or device
	| "full" // five devices are listed, or three phones joined this window
	| "exists" // a device or an item with that id is already there
	| "unknown-device"
	| "device-key" // addDevice names another device key than the slot joined with
	| "mailbox-full"
	| "removed" // the device's slot was removed by the Mac
	| "left" // the device left
	| "deleted" // the Mac deleted the pairing
	| "replaced" // a newer connection of the same end took its place
	| "window-ended"; // a joined phone's window closed before the Mac added it

/** A build, as the end's `CFBundleVersion` or the Mac's build number: up to three numbers with dots between. */
export type Build = number[];

export function readBuild(text: unknown): Build | null {
	if (typeof text !== "string" || !/^(?:0|[1-9][0-9]{0,8})(?:\.(?:0|[1-9][0-9]{0,8})){0,2}$/.test(text)) return null;
	return text.split(".").map(Number);
}

/** Below zero if `a` is an earlier build than `b`; missing parts count as zero, so 12 and 12.0 are the same build. */
export function compareBuilds(a: Build, b: Build): number {
	for (let index = 0; index < Math.max(a.length, b.length); index++) {
		const difference = (a[index] ?? 0) - (b[index] ?? 0);
		if (difference !== 0) return difference;
	}
	return 0;
}

export type Hello = { type: "hello"; role: "mac" | "device"; pairing: string; device: string | null; build: Build };
export type Register = { type: "register"; build: Build; relayKey: string };
export type Proof = { type: "proof"; signature: string };
export type Join = {
	type: "join";
	pairing: string;
	deviceKey: string;
	attestation: Uint8Array<ArrayBuffer>;
	keyId: string;
	keyIdBytes: Uint8Array<ArrayBuffer>;
	token: Uint8Array<ArrayBuffer>;
};
export type OpenJoin = { type: "openJoin"; tokenHash: Uint8Array<ArrayBuffer>; expires: number };
export type AddDevice = { type: "addDevice"; device: string; deviceKey: string; attestKeyId: string };
export type RemoveDevice = { type: "removeDevice"; device: string };
export type State = { type: "state"; device: string; id: string; item: Uint8Array<ArrayBuffer> };
export type Put = { type: "put"; to: string; id: string; item: Uint8Array<ArrayBuffer>; presence: boolean };
export type Token = { type: "token"; apns: string; environment: "development" | "production" };
export type Leave = { type: "leave"; signature: string };
export type Bare = { type: "closeJoin" | "deletePairing" | "take" };

export type Message = Hello | Register | Proof | Join | OpenJoin | AddDevice | RemoveDevice | State | Put | Token | Leave | Bare;

type Body = Record<string, unknown>;

/** The message a text holds, or null if it is not exactly one of the protocol's. */
export function readMessage(text: string): Message | null {
	if (text.length > MAX_TEXT || new TextEncoder().encode(text).length > MAX_TEXT) return null;
	let value: unknown;
	try {
		value = JSON.parse(text);
	} catch {
		return null;
	}
	// One way of writing each message: the text JavaScript writes for what it holds. This refuses white space, a key
	// given twice, escapes that need not be, numbers written another way, and a lone surrogate.
	if (JSON.stringify(value) !== text || !isObject(value)) return null;
	const names = Object.keys(value);
	if (names.length !== 1) return null;
	const name = names[0];
	const body = value[name];
	if (!isObject(body)) return null;
	switch (name) {
		case "hello":
			return hello(body);
		case "register":
			return register(body);
		case "proof":
			return exactly(body, ["signature"]) && isSignature(body.signature) ? { type: "proof", signature: body.signature } : null;
		case "join":
			return join(body);
		case "openJoin":
			return openJoin(body);
		case "closeJoin":
		case "deletePairing":
		case "take":
			return exactly(body, []) ? { type: name } : null;
		case "addDevice":
			return exactly(body, ["device", "deviceKey", "attestKeyId"]) &&
				isDeviceId(body.device) &&
				isKeyText(body.deviceKey) &&
				isKeyId(body.attestKeyId)
				? { type: "addDevice", device: body.device, deviceKey: body.deviceKey, attestKeyId: body.attestKeyId }
				: null;
		case "removeDevice":
			return exactly(body, ["device"]) && isDeviceId(body.device) ? { type: "removeDevice", device: body.device } : null;
		case "state": {
			if (!exactly(body, ["device", "id", "item"]) || !isDeviceId(body.device) || !isItemId(body.id)) return null;
			const item = readItem(body.item);
			return item === null ? null : { type: "state", device: body.device, id: body.id, item };
		}
		case "put":
			return put(body);
		case "token":
			return exactly(body, ["apns", "environment"]) &&
				typeof body.apns === "string" &&
				/^(?:[0-9a-f]{2}){32,100}$/.test(body.apns) &&
				(body.environment === "development" || body.environment === "production")
				? { type: "token", apns: body.apns, environment: body.environment }
				: null;
		case "leave":
			return exactly(body, ["signature"]) && isSignature(body.signature) ? { type: "leave", signature: body.signature } : null;
		default:
			return null;
	}
}

function hello(body: Body): Hello | null {
	const keys = ["v", "role", "pairing", "build"];
	if (body.role === "device" && "device" in body) keys.push("device");
	if ("ext" in body) keys.push("ext");
	if (!exactly(body, keys) || body.v !== 1 || !isPairingId(body.pairing)) return null;
	// `ext` is empty today and ignored where it holds what the relay does not know (5.3, decision 23).
	if ("ext" in body && !isObject(body.ext)) return null;
	const build = readBuild(body.build);
	if (build === null || (body.role !== "mac" && body.role !== "device")) return null;
	let device: string | null = null;
	if ("device" in body) {
		if (!isDeviceId(body.device)) return null;
		device = body.device;
	}
	return { type: "hello", role: body.role, pairing: body.pairing, device, build };
}

function register(body: Body): Register | null {
	const keys = ["v", "build", "relayKey"];
	if ("ext" in body) keys.push("ext");
	if (!exactly(body, keys) || body.v !== 1 || !isKeyText(body.relayKey)) return null;
	if ("ext" in body && !isObject(body.ext)) return null;
	const build = readBuild(body.build);
	return build === null ? null : { type: "register", build, relayKey: body.relayKey };
}

function join(body: Body): Join | null {
	if (!exactly(body, ["pairing", "deviceKey", "attestation", "keyId", "token"])) return null;
	if (!isPairingId(body.pairing) || !isKeyText(body.deviceKey) || !isKeyId(body.keyId)) return null;
	if (typeof body.attestation !== "string" || typeof body.token !== "string") return null;
	if (body.attestation.length > Math.ceil((MAX_ATTESTATION * 4) / 3)) return null;
	const attestation = fromBase64url(body.attestation);
	const token = fromBase64url(body.token, 32);
	const keyIdBytes = fromBase64(body.keyId, 32);
	if (attestation === null || attestation.length === 0 || token === null || keyIdBytes === null) return null;
	return {
		type: "join",
		pairing: body.pairing,
		deviceKey: body.deviceKey,
		attestation: new Uint8Array(attestation),
		keyId: body.keyId,
		keyIdBytes: new Uint8Array(keyIdBytes),
		token: new Uint8Array(token),
	};
}

function openJoin(body: Body): OpenJoin | null {
	if (!exactly(body, ["tokenHash", "expires"]) || typeof body.tokenHash !== "string") return null;
	const tokenHash = fromBase64url(body.tokenHash, 32);
	if (tokenHash === null || !Number.isSafeInteger(body.expires) || (body.expires as number) <= 0) return null;
	return { type: "openJoin", tokenHash: new Uint8Array(tokenHash), expires: body.expires as number };
}

function put(body: Body): Put | null {
	const keys = ["to", "id", "item"];
	if ("presence" in body) keys.push("presence");
	if (!exactly(body, keys) || !isItemId(body.id)) return null;
	if (body.to !== "mac" && !isDeviceId(body.to)) return null;
	if ("presence" in body && body.presence !== true) return null;
	const item = readItem(body.item);
	if (item === null) return null;
	return { type: "put", to: body.to as string, id: body.id, item, presence: body.presence === true };
}

function readItem(text: unknown): Uint8Array<ArrayBuffer> | null {
	if (typeof text !== "string" || text.length > Math.ceil((MAX_ITEM * 4) / 3)) return null;
	const item = fromBase64url(text);
	// HPKE's encapsulated key comes first, an uncompressed P-256 point (docs/remotekit.md, "Sealed items").
	if (item === null || item.length < MIN_ITEM || item.length > MAX_ITEM || item[0] !== 0x04) return null;
	return new Uint8Array(item);
}

function isObject(value: unknown): value is Body {
	return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** Whether `body` has exactly these members. */
function exactly(body: Body, keys: string[]): boolean {
	const names = Object.keys(body);
	return names.length === keys.length && names.every((name) => keys.includes(name));
}

/** A pairing's id: 16 bytes, base64url. */
export function isPairingId(value: unknown): value is string {
	return typeof value === "string" && fromBase64url(value, 16) !== null;
}

/** A device's id: "dev_" and 16 bytes, base64url; also its slot (docs/iphone.md 3.2). */
export function isDeviceId(value: unknown): value is string {
	return typeof value === "string" && value.startsWith("dev_") && fromBase64url(value.slice(4), 16) !== null;
}

/** A device's id as the 16 bytes in front of a binary message (5.3). */
export function deviceIdBytes(device: string): Uint8Array {
	return fromBase64url(device.slice(4), 16)!;
}

function isItemId(value: unknown): value is string {
	return typeof value === "string" && fromBase64url(value, 16) !== null;
}

function isKeyText(value: unknown): value is string {
	return typeof value === "string" && publicKeyBytes(value) !== null;
}

/** An App Attest key's id as `DCAppAttestService` gives it: 32 bytes in standard base64. */
function isKeyId(value: unknown): value is string {
	return typeof value === "string" && fromBase64(value, 32) !== null;
}

function isSignature(value: unknown): value is string {
	return typeof value === "string" && fromBase64url(value, 64) !== null;
}
