// The check that the relay sees only sealed bytes (docs/iphone.md 10 and 13, decision 8; #683): what the recorder kept
// (recorder.ts) and what the relay stored are searched for every marker the session sent, in every form the test
// knows, and for every secret of the session's ends; every binary message must be one of the session's own Noise
// messages and every item one of its sealed items; and every control message, header and stored field must be one
// 5.3 says the relay may see, by an allow-list kept here. A field the relay starts to carry or keep is refused until
// this list names it, in a pull request the owner reviews (relay/ is an owner's path).
//
// Pure TypeScript with no import of the runtime's, so that both workerd (sealed.test.ts) and Node (check.mjs, after
// the live session) run it. It decides nothing about the relay's code; it reads only what the recorder handed it.

/** One thing the recorder saw at the relay's edge, in order. `socket` numbers the connections. */
export type Event =
	| { socket: number; kind: "open"; method: string; url: string; headers: [string, string][]; status: number }
	| { socket: number; kind: "text"; from: "end" | "relay"; text: string }
	| { socket: number; kind: "bytes"; from: "end" | "relay"; bytes: Uint8Array }
	| { socket: number; kind: "close"; from: "end" | "relay"; code: number; reason: string };

/** What one object keeps, read back from its storage: its key-value pairs, its own tables, its sockets' attachments. */
export type Stored = {
	object: "pairing" | "attestKey" | "address";
	name: string;
	/** The object's id in hex, which names its file in the relay's local state. */
	id: string;
	kv: Record<string, unknown>;
	tables: Record<string, Record<string, unknown>[]>;
	sockets: unknown[];
};

/**
 * A push the relay asked Apple's service to send, as the local stand-in for APNs (test/apns.ts) took it, which the
 * recording relay hands over with the recording (worker.ts), to be checked as everything else is (#689): its address,
 * every header (`authorization` among them) and its body exactly.
 */
export type Push = { url: string; headers: [string, string][]; body: Uint8Array };

export type Recording = {
	events: Event[];
	stored: Stored[];
	pushes: Push[];
	/** What the recording relay wrote to the console as it gave the recording (worker.ts), for check.mjs to find. */
	canaries?: { log: string; debug: string };
};

/** A file of the relay's local state, as Wrangler's `--persist-to` left it, read whole. */
export type File = { path: string; bytes: Uint8Array };

/** A text the session sent where the relay must not read it, and where it put it (`place`). */
export type Marker = { place: string; text: string };

/** What the session's own ends say of it (check.mjs reads it from the Swift program's file). */
export type Session = {
	/** Every marker it sent, by place. */
	markers: Marker[];
	/**
	 * Bytes that must never be seen at all: the ends' private keys, the public keys the relay is never given (the Mac's
	 * identity, record and channel keys, the phone's presence, record and channel keys), the pairing's secret, the
	 * channels' bindings, the attestation inside `pair`.
	 */
	secrets: Uint8Array[];
	/** The only keys the relay may be given, by field: the Mac's relay key (`relayKey`), the phone's device key (`deviceKey`). */
	keys: { relayKey: string[]; deviceKey: string[] };
	/** The devices' ids the session used, slots and engine's ids: the only ones a Mac's binary message may name. */
	devices: string[];
	/** SHA-256, in hex, of every Noise message either end sent: handshakes and transport messages. */
	noise: string[];
	/** SHA-256, in hex, of every sealed item either end put or the Mac left as a state. */
	items: string[];
	/** SHA-256 of the items the session left in the mailbox, which the relay must still hold when it is read. */
	kept: string[];
};

export type Finding = { rule: string; where: string; detail: string };

// MARK: Forms

const encoder = new TextEncoder();

/** The forms a marker is looked for in: each a name and the bytes it would leave. */
export function forms(text: string): { form: string; bytes: Uint8Array }[] {
	const utf8 = encoder.encode(text);
	const found: { form: string; bytes: Uint8Array }[] = [{ form: "UTF-8", bytes: utf8 }];
	found.push({ form: "UTF-16LE", bytes: utf16(text, true) }, { form: "UTF-16BE", bytes: utf16(text, false) });
	found.push(...byteForms(utf8));
	const escaped = JSON.stringify(text).slice(1, -1);
	if (escaped !== text) found.push({ form: "JSON", bytes: encoder.encode(escaped) });
	for (const upper of [false, true]) {
		const ascii = asciiEscaped(escaped, upper);
		if (ascii !== escaped) found.push({ form: `JSON \\u${upper ? " (upper)" : ""}`, bytes: encoder.encode(ascii) });
	}
	// Latin-1, one byte a character, which V8 uses for a string that fits it, in what it serialises.
	if ([...text].some((character) => character > "\x7f") && [...text].every((character) => character <= "\xff")) {
		found.push({ form: "Latin-1", bytes: Uint8Array.from(text, (character) => character.charCodeAt(0)) });
	}
	const percent = encodeURIComponent(text);
	if (percent !== text) found.push({ form: "percent", bytes: encoder.encode(percent) });
	return unique(found);
}

/** The forms bytes are looked for in: as they are, hex either case, base64 and base64url at each of three alignments. */
export function byteForms(bytes: Uint8Array): { form: string; bytes: Uint8Array }[] {
	const found = [
		{ form: "bytes", bytes },
		{ form: "hex", bytes: encoder.encode(toHex(bytes)) },
		{ form: "HEX", bytes: encoder.encode(toHex(bytes).toUpperCase()) },
	];
	for (let shift = 0; shift < 3; shift++) {
		const middle = base64Middle(bytes, shift);
		if (middle.length < 8) continue;
		found.push({ form: `base64 +${shift}`, bytes: encoder.encode(middle) });
		const url = middle.replaceAll("+", "-").replaceAll("/", "_");
		if (url !== middle) found.push({ form: `base64url +${shift}`, bytes: encoder.encode(url) });
	}
	return found;
}

/**
 * The characters of base64 that depend only on `bytes`, wherever they start: `shift` bytes after a three-byte boundary
 * of whatever was encoded with them. A character carries six bits; it is kept only if all of them come from `bytes`.
 */
export function base64Middle(bytes: Uint8Array, shift: number): string {
	const padded = new Uint8Array(shift + bytes.length);
	padded.set(bytes, shift);
	const encoded = btoa(latin1(padded));
	let text = "";
	for (let index = 0; index < encoded.length; index++) {
		const first = Math.floor((6 * index) / 8);
		const last = Math.floor((6 * index + 5) / 8);
		if (first >= shift && last < shift + bytes.length) text += encoded[index];
	}
	return text;
}

function utf16(text: string, little: boolean): Uint8Array {
	const bytes = new Uint8Array(text.length * 2);
	for (let index = 0; index < text.length; index++) {
		const unit = text.charCodeAt(index);
		bytes[2 * index + (little ? 0 : 1)] = unit & 0xff;
		bytes[2 * index + (little ? 1 : 0)] = unit >> 8;
	}
	return bytes;
}

function asciiEscaped(text: string, upper: boolean): string {
	return text.replace(/[^\x00-\x7f]/g, (character) => {
		const code = character.charCodeAt(0).toString(16).padStart(4, "0");
		return `\\u${upper ? code.toUpperCase() : code}`;
	});
}

function unique(list: { form: string; bytes: Uint8Array }[]): { form: string; bytes: Uint8Array }[] {
	const seen = new Set<string>();
	return list.filter(({ bytes }) => {
		const key = latin1(bytes);
		if (seen.has(key)) return false;
		seen.add(key);
		return true;
	});
}

// MARK: Bytes

export function latin1(bytes: Uint8Array): string {
	let text = "";
	for (let start = 0; start < bytes.length; start += 8192) text += String.fromCharCode(...bytes.subarray(start, start + 8192));
	return text;
}

export function toHex(bytes: Uint8Array): string {
	return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

export function fromHex(text: string): Uint8Array {
	if (!/^(?:[0-9a-f]{2})*$/.test(text)) throw new Error("not hex");
	return Uint8Array.from(text.match(/../g) ?? [], (pair) => parseInt(pair, 16));
}

export function toBase64(bytes: Uint8Array): string {
	return btoa(latin1(bytes));
}

export function fromBase64(text: string): Uint8Array {
	return Uint8Array.from(atob(text), (character) => character.charCodeAt(0));
}

/** Base64url without padding, read strictly: only its one way of writing given bytes. Null if it is not that. */
export function fromBase64url(text: string): Uint8Array | null {
	if (!/^[A-Za-z0-9_-]*$/.test(text) || text.length % 4 === 1) return null;
	let bytes: Uint8Array;
	try {
		bytes = fromBase64(text.replaceAll("-", "+").replaceAll("_", "/") + "=".repeat((4 - (text.length % 4)) % 4));
	} catch {
		return null;
	}
	return toBase64(bytes).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "") === text ? bytes : null;
}

export async function sha256(bytes: Uint8Array): Promise<string> {
	return toHex(new Uint8Array(await crypto.subtle.digest("SHA-256", new Uint8Array(bytes))));
}

/** A value made JSON, with every byte array as `{"$bytes":<base64>}`, for the recording to leave the runtime. */
export function encode(value: unknown): unknown {
	if (value instanceof Uint8Array) return { $bytes: toBase64(value) };
	if (value instanceof ArrayBuffer) return { $bytes: toBase64(new Uint8Array(value)) };
	if (Array.isArray(value)) return value.map(encode);
	if (typeof value === "object" && value !== null) return Object.fromEntries(Object.entries(value).map(([key, inner]) => [key, encode(inner)]));
	return value;
}

/** `encode` undone. */
export function decode(value: unknown): unknown {
	if (Array.isArray(value)) return value.map(decode);
	if (typeof value === "object" && value !== null) {
		const entries = Object.entries(value);
		if (entries.length === 1 && entries[0][0] === "$bytes" && typeof entries[0][1] === "string") return fromBase64(entries[0][1]);
		return Object.fromEntries(entries.map(([key, inner]) => [key, decode(inner)]));
	}
	return value;
}

// MARK: Looking for markers

/** A place to look, with what it holds. */
export type Haystack = { where: string; bytes: Uint8Array };

/** Every marker and secret, in every form, found in any haystack. */
export function findAll(markers: Marker[], secrets: Uint8Array[], haystacks: Haystack[]): Finding[] {
	const needles: { name: string; form: string; text: string }[] = [];
	for (const marker of markers) {
		if (encoder.encode(marker.text).length < 12) throw new Error(`the marker for ${marker.place} is shorter than 12 bytes, too short to look for`);
		for (const { form, bytes } of forms(marker.text)) needles.push({ name: `the ${marker.place} marker`, form, text: latin1(bytes) });
	}
	secrets.forEach((secret, index) => {
		if (secret.length < 16) throw new Error(`secret ${index} is shorter than 16 bytes`);
		for (const { form, bytes } of byteForms(secret)) needles.push({ name: `secret ${index}`, form, text: latin1(bytes) });
	});
	const findings: Finding[] = [];
	for (const haystack of haystacks) {
		const text = latin1(haystack.bytes);
		for (const needle of needles) {
			if (text.includes(needle.text)) findings.push({ rule: "readable", where: haystack.where, detail: `${needle.name}, as ${needle.form}` });
		}
	}
	return findings;
}

/** What the recorder saw, as places to look: each message alone, and each socket's bytes each way run together. */
export function recordingHaystacks(recording: Recording): Haystack[] {
	const haystacks: Haystack[] = [];
	const streams = new Map<string, Uint8Array[]>();
	recording.events.forEach((event, index) => {
		const where = `socket ${event.socket}, event ${index}`;
		switch (event.kind) {
			case "open":
				haystacks.push({ where: `${where}: the request`, bytes: encoder.encode(`${event.method} ${event.url}\n${event.headers.map(([name, value]) => `${name}: ${value}`).join("\n")}`) });
				break;
			case "text":
				haystacks.push({ where: `${where}: a text from the ${event.from}`, bytes: encoder.encode(event.text) });
				break;
			case "bytes": {
				haystacks.push({ where: `${where}: bytes from the ${event.from}`, bytes: event.bytes });
				const key = `socket ${event.socket}: every binary message from the ${event.from}, run together`;
				streams.set(key, [...(streams.get(key) ?? []), event.bytes]);
				break;
			}
			case "close":
				haystacks.push({ where: `${where}: the ${event.from}'s closing`, bytes: encoder.encode(`${event.code} ${event.reason}`) });
				break;
		}
	});
	for (const [where, parts] of streams) {
		const length = parts.reduce((sum, part) => sum + part.length, 0);
		const joined = new Uint8Array(length);
		let offset = 0;
		for (const part of parts) {
			joined.set(part, offset);
			offset += part.length;
		}
		haystacks.push({ where, bytes: joined });
	}
	recording.pushes.forEach((push, index) => {
		haystacks.push({ where: `push ${index}`, bytes: encoder.encode(`${push.url}\n${push.headers.map(([name, value]) => `${name}: ${value}`).join("\n")}\n`) });
		haystacks.push({ where: `push ${index}: its payload`, bytes: push.body });
	});
	return haystacks;
}

/** What the objects keep, as places to look: each object's whole dump, and each byte array in it as it is. */
export function storedHaystacks(stored: Stored[]): Haystack[] {
	const haystacks: Haystack[] = [];
	for (const object of stored) {
		const name = `the ${object.object} object ${object.name}`;
		haystacks.push({ where: `${name}, read back`, bytes: encoder.encode(JSON.stringify(encode(object))) });
		walk(object, (bytes, path) => haystacks.push({ where: `${name}: ${path}`, bytes }));
	}
	return haystacks;
}

function walk(value: unknown, visit: (bytes: Uint8Array, path: string) => void, path = ""): void {
	if (value instanceof Uint8Array) return visit(value, path);
	if (Array.isArray(value)) return value.forEach((inner, index) => walk(inner, visit, `${path}[${index}]`));
	if (typeof value === "object" && value !== null) {
		for (const [key, inner] of Object.entries(value)) walk(inner, visit, path === "" ? key : `${path}.${key}`);
	}
}

// MARK: What the relay may see

/** A check of one value: true if it is what the field may hold. */
type Kind = (value: unknown) => boolean;

const isBytes = (count?: number, min = 1, max = Infinity) => (value: unknown) => {
	if (typeof value !== "string") return false;
	const bytes = fromBase64url(value);
	return bytes !== null && (count === undefined ? bytes.length >= min && bytes.length <= max : bytes.length === count);
};
const pairing: Kind = isBytes(16);
const device: Kind = (value) => typeof value === "string" && value.startsWith("dev_") && isBytes(16)(value.slice(4));
const itemId: Kind = isBytes(16);
const bytes32: Kind = isBytes(32);
const signature: Kind = isBytes(64);
/** A P-256 public key, SPKI DER: 91 bytes. */
const key: Kind = (value) => isBytes(91)(value) && fromBase64url(value as string)![0] === 0x30;
/** A sealed item: HPKE's encapsulated key (an uncompressed point) first, 81 bytes to 16 KB. */
const sealed: Kind = (value) => isBytes(undefined, 81, 16 * 1024)(value) && fromBase64url(value as string)![0] === 0x04;
/**
 * App Attest's attestation object, as the phone sends it at `join` (3.3, 6.6). Here always the protocol test's stand-in
 * (relay/test/protocol/worker.ts): the join's 32-byte client data hash, then the 32-byte key id, and nothing else.
 */
const attestation: Kind = isBytes(64);
/** An App Attest key's id: 32 bytes in standard base64, as `DCAppAttestService` gives it. */
const attestKeyId: Kind = (value) => typeof value === "string" && /^[A-Za-z0-9+/]{43}=$/.test(value);
const time: Kind = (value) => Number.isSafeInteger(value) && (value as number) > 0;
const count: Kind = (value) => Number.isSafeInteger(value) && (value as number) >= 0;
const bool: Kind = (value) => typeof value === "boolean";
const isTrue: Kind = (value) => value === true;
const one: Kind = (value) => value === 1;
const build: Kind = (value) => typeof value === "string" && /^(?:0|[1-9][0-9]{0,8})(?:\.(?:0|[1-9][0-9]{0,8})){0,2}$/.test(value);
const role: Kind = (value) => value === "mac" || value === "device";
const empty: Kind = (value) => typeof value === "object" && value !== null && !Array.isArray(value) && Object.keys(value).length === 0;
const apns: Kind = (value) => typeof value === "string" && /^(?:[0-9a-f]{2}){32,100}$/.test(value);
const environment: Kind = (value) => value === "development" || value === "production";
const reader: Kind = (value) => value === "mac" || device(value);
const list = (each: Kind): Kind => (value) => Array.isArray(value) && value.every(each);
const shape = (fields: Fields): Kind => (value) => fieldsFault(value, fields) === null;
/** The time a phone says it left (3.6): at most the year 2286, as RemoteKit's client reads a time. */
const leftAt: Kind = (value) => time(value) && (value as number) <= 9_999_999_999_999;
/**
 * A device that left, as the Mac is told and the relay keeps it: the time, and the device key's signature over the leave
 * text for the Mac, which names the Mac's identity key and so tells the relay nothing it can check (#813).
 */
const leftDevice: Kind = (value) => shape({ device, at: leftAt, notice: signature })(value);

/** The fixed words of a refusal (relay/README.md, "Refusals"): never what a client sent. */
const WHY = [
	"malformed", "unavailable", "unknown-pairing", "not-listed", "signature", "update-required", "another-mac", "limits", "too-many",
	"timeout", "window-closed", "token", "attestation", "category", "bundle-version", "attest-key-taken", "full", "exists",
	"unknown-device", "device-key", "not-joined", "mailbox-full", "busy", "removed", "left", "deleted", "replaced", "window-ended",
];
const why: Kind = (value) => typeof value === "string" && WHY.includes(value);
/** Why the relay refused a push (relay/README.md, "Pushes", "Live Activities"): its own words, never the Mac's or Apple's text. */
const PUSH_WHY = ["no-token", "token-dead", "push-limit", "push-later", "unavailable", "unknown-device", "clock"];
const pushWhy: Kind = (value) => typeof value === "string" && PUSH_WHY.includes(value);
const REQUESTS = ["openJoin", "closeJoin", "addDevice", "removeDevice", "deletePairing", "state", "put", "take", "token", "leave", "push", "activityToken", "dropActivity"];
const what: Kind = (value) => typeof value === "string" && REQUESTS.includes(value);
/** What an `ok` names: a request, or `took` (#806), which is answered `ok` and never refused with a `what` (one malformed closes the socket). */
const okWhat: Kind = (value) => what(value) || value === "took";
/** `took`'s ids (#806): 1 to 200 items' ids (`MAX_TOOK` in src/protocol.ts), none twice, as the relay reads them. */
const tookIds: Kind = (value) =>
	Array.isArray(value) && value.length >= 1 && value.length <= 200 && value.every(itemId) && new Set(value).size === value.length;

// Pushes (#689; relay/README.md, "Pushes", "Live Activities").
/** The sizes a sealed push has (`SEALED_SIZES` in src/apns.ts): a sealed item's first byte, padded to one of three. */
export const SEALED_PUSH_SIZES = [696, 1464, 3000];
const sealedPush: Kind = (value) => {
	const bytes = typeof value === "string" ? fromBase64url(value) : null;
	return bytes !== null && SEALED_PUSH_SIZES.includes(bytes.length) && bytes[0] === 0x04;
};
/** A Live Activity's count, as the relay takes it. */
const activityCount: Kind = (value) => Number.isSafeInteger(value) && (value as number) >= 0 && (value as number) <= 99_999;
/**
 * When a Live Activity's numbers were counted: a time in milliseconds the relay takes, a day behind its clock at most and
 * five minutes ahead (src/apns.ts, `isNear`), with the check's clock for the relay's and a minute for the check's run.
 */
const countedAt: Kind = (value) => time(value) && (value as number) >= Date.now() - 24 * 3_600_000 - 60_000 && (value as number) <= Date.now() + 5 * 60_000;
/**
 * The four numbers, exactly: the one push the relay reads, by design (docs/iphone.md 7). Nothing beside them, and none
 * of them anything but a count or the time they were counted.
 */
const activityState: Kind = (value) => fieldsFault(value, { working: activityCount, needs: activityCount, finished: activityCount, at: countedAt }) === null;
const activityEvent: Kind = (value) => value === "update" || value === "end";
/** The Mac's `push`: sealed, or a Live Activity's numbers; a background push never with a collapse id. */
const PUSH_FORMS: Fields[] = [
	{ device, kind: (value) => value === "alert", sealed: sealedPush, "collapse?": bytes32 },
	{ device, kind: (value) => value === "background", sealed: sealedPush },
	{ device, kind: (value) => value === "activity", activity: itemId, event: activityEvent, state: activityState },
];

/** A message's fields: each with its kind, `?` after a name for one that may be left out. */
type Fields = Record<string, Kind>;

/**
 * Every text message an end may send the relay, by name, and each form its body may have (iphone.md 5.3; the exact
 * forms are relay/README.md's "The protocol"). Each field is what 5.3 says the relay learns: ids, keys, signatures,
 * sealed items, sizes, times, builds and fixed words. Nothing here holds text a person wrote or reads.
 */
export const FROM_AN_END: Record<string, Fields[]> = {
	register: [{ v: one, build, relayKey: key, "ext?": empty }],
	hello: [{ v: one, role, pairing, "device?": device, build, "ext?": empty }],
	proof: [{ signature }],
	join: [{ pairing, deviceKey: key, attestation, keyId: attestKeyId, token: bytes32 }],
	openJoin: [{ tokenHash: bytes32, expires: time }],
	closeJoin: [{}],
	addDevice: [{ device, deviceKey: key, attestKeyId }],
	removeDevice: [{ device }],
	deletePairing: [{}],
	state: [{ device, id: itemId, item: sealed }],
	put: [{ to: reader, id: itemId, item: sealed, "presence?": isTrue }],
	take: [{}],
	took: [{ ids: tookIds }],
	token: [{ apns, environment }],
	leave: [{ signature, at: leftAt, notice: signature }],
	ping: [{}],
	push: PUSH_FORMS,
	activityToken: [{ activity: itemId, apns, environment }],
	dropActivity: [{ activity: itemId }],
};

/** Every text message the relay may send an end, by name, and each form its body may have. */
export const FROM_THE_RELAY: Record<string, Fields[]> = {
	registered: [{ pairing }],
	ready: [
		{ devices: list(shape({ device, online: bool })), left: list(leftDevice), pending: bool, mail: count },
		{ mac: bool, mail: count },
	],
	joined: [{ device }, { device, deviceKey: key, keyId: attestKeyId }],
	ok: [{ what: okWhat }],
	refused: [{ why }, { what, why }, { what: (value) => value === "push", why: pushWhy }],
	item: [{ from: reader, id: itemId, item: sealed, presence: bool }],
	state: [{ id: itemId, item: sealed }],
	taken: [{ count }],
	online: [{ device }],
	offline: [{ device }],
	left: [{ device, at: leftAt, notice: signature }],
	anotherMac: [{}],
	held: [{ device, until: time }],
	mac: [{ online: bool }],
	mail: [{}],
	busy: [{ until: time }],
	pong: [{}],
};

/** Why `value` is not an object with exactly these fields, each of its kind; null if it is. */
function fieldsFault(value: unknown, fields: Fields): string | null {
	if (typeof value !== "object" || value === null || Array.isArray(value)) return "not an object";
	const names = Object.keys(value);
	for (const name of names) {
		const kind = fields[name] ?? fields[`${name}?`];
		if (kind === undefined) return `a field the allow-list does not have: ${JSON.stringify(name)}`;
		if (!kind((value as Record<string, unknown>)[name])) return `${name} is not what the allow-list takes there`;
	}
	for (const name of Object.keys(fields)) {
		if (!name.endsWith("?") && !names.includes(name)) return `${name} is missing`;
	}
	return null;
}

/** Why a text message is not one the allow-list takes; null if it is. `challenge` is the one with a string body. */
export function messageFault(text: string, from: "end" | "relay"): string | null {
	let value: unknown;
	try {
		value = JSON.parse(text);
	} catch {
		return "not JSON";
	}
	if (typeof value !== "object" || value === null || Array.isArray(value)) return "not an object";
	const names = Object.keys(value);
	if (names.length !== 1) return "not one member";
	const name = names[0];
	const body = (value as Record<string, unknown>)[name];
	if (from === "relay" && name === "challenge") return bytes32(body) ? null : "a challenge that is not 32 bytes";
	const forms = (from === "end" ? FROM_AN_END : FROM_THE_RELAY)[name];
	if (forms === undefined) return `a message the allow-list does not have: ${JSON.stringify(name)}`;
	const faults = forms.map((fields) => fieldsFault(body, fields));
	return faults.includes(null) ? null : `${name}: ${faults.join("; or ")}`;
}

/**
 * What RemoteKit's relay client says of itself on every connection (`RelaySession` in RemoteKit/Relay, #678's security
 * read, S2, which folded in #819): a `User-Agent` with no program's or system's version, and an `Accept-Language` that
 * names no locale (URLSession sends one whatever is set, so the client pins it). Pinned here to exactly those, so that
 * the check fails if the system's own come back: the program's name, CFNetwork's and Darwin's versions, the person's
 * languages.
 */
export const USER_AGENT = "pi2-relay-client";
export const ACCEPT_LANGUAGE = "*";

/**
 * The headers a connection may carry to the relay, each with what it may hold: the WebSocket's own, the pairing's,
 * the two URLSession adds whatever the client asks (the same for everyone), the client's fixed `User-Agent` and
 * `Accept-Language`, and the address the local runtime puts on a request before the Worker sees it. Anything else
 * fails until it is named here. Each value is searched for markers too.
 */
export const HEADERS: Record<string, Kind> = {
	// The WebSocket's handshake (RFC 6455) and HTTP's own.
	host: (value) => typeof value === "string" && /^(?:127\.0\.0\.1|localhost|\[::1\])(?::\d{1,5})?$/.test(value),
	upgrade: (value) => value === "websocket",
	connection: (value) => value === "Upgrade",
	"sec-websocket-key": (value) => typeof value === "string" && /^[A-Za-z0-9+/]{22}==$/.test(value),
	"sec-websocket-version": (value) => value === "13",
	"sec-websocket-extensions": (value) => value === "permessage-deflate",
	// The pairing, which takes the connection to its object (5.3).
	"pi2-pairing": pairing,
	// URLSession's own, the same for everyone.
	accept: (value) => value === "*/*",
	"accept-encoding": (value) => value === "br, gzip",
	// The relay client's own, fixed (above).
	"user-agent": (value) => value === USER_AGENT,
	"accept-language": (value) => value === ACCEPT_LANGUAGE,
	// The connecting address, which the local runtime sets as Cloudflare does (5.3: the relay knows it, and keeps none).
	"cf-connecting-ip": (value) => typeof value === "string" && (isIPv4(value) || isIPv6(value)),
};

function isIPv4(text: string): boolean {
	const parts = text.split(".");
	return parts.length === 4 && parts.every((part) => /^(?:0|[1-9][0-9]{0,2})$/.test(part) && Number(part) <= 255);
}

function isIPv6(text: string): boolean {
	if (!/^[0-9a-f:]{2,39}$/.test(text) || (text.match(/::/g) ?? []).length > 1) return false;
	const groups = text.split(":");
	return groups.length <= 8 && groups.every((group) => group.length <= 4);
}

/** The headers a client's connection must carry once taken (101): RemoteKit's client's fixed ones. */
const REQUIRED = ["user-agent", "accept-language"];

/** Why a connection's request is not one the allow-list takes; null if it is. */
export function requestFault(event: Extract<Event, { kind: "open" }>): string | null {
	const url = new URL(event.url);
	if (url.pathname !== "/v1" || url.search !== "") return "an address that carries more than /v1";
	if (event.status === 101) {
		const names = event.headers.map(([name]) => name.toLowerCase());
		for (const name of REQUIRED) if (!names.includes(name)) return `a connection taken without the relay client's ${name}`;
	}
	for (const [name, value] of event.headers) {
		const kind = HEADERS[name.toLowerCase()];
		if (kind === undefined) return `a header the allow-list does not have: ${name}`;
		if (!kind(value)) {
			const fixed = { "user-agent": "USER_AGENT", "accept-language": "ACCEPT_LANGUAGE" }[name.toLowerCase()];
			return fixed !== undefined
				? `a ${name} that is not the relay client's fixed one (${fixed} in scan.ts): ${JSON.stringify(value)}`
				: `a ${name} header that is not what the allow-list takes: ${JSON.stringify(value)}`;
		}
	}
	return null;
}

/** What a pairing's object may keep (5.3, "What it keeps"), by key: its record, its devices, its day's counters. */
const META: Fields = {
	pairing,
	relayKey: key,
	pendingUntil: (value) => value === null || time(value),
	lastSeen: time,
	blocked: (value) => typeof value === "object" && value !== null && Object.entries(value).every(([end, until]) => (end === "mac" || device(end)) && time(until)),
	window: (value) => value === null || shape({ id: isBytes(16), tokenHash: bytes32, expires: time, tries: count, joins: count })(value),
	left: list(leftDevice),
	/** When the join windows of the last minute were opened, for their limit. */
	"opened?": list(time),
};
const DEVICE: Fields = {
	key,
	listed: bool,
	attestKeyIds: list(attestKeyId),
	macKeyId: (value) => value === null || attestKeyId(value),
	token: (value) => value === null || shape({ apns, environment })(value),
	/** The tokens of the Live Activities the phone started, by the activity's id, five at most, each for twelve hours (#700). */
	"activities?": (value) =>
		typeof value === "object" && value !== null && Object.keys(value).length <= 5 &&
		Object.entries(value).every(([id, token]) => itemId(id) && shape({ apns, environment, until: time })(token)),
};
/** The pushes counted this hour (src/apns.ts, `PushHour`): for the pairing and for each device, a count of each kind. */
const PUSH_COUNTS: Fields = { "alert?": count, "background?": count, "activity?": count };
const pushHour: Kind = (value) =>
	shape({
		hour: count,
		counts: (counts) =>
			typeof counts === "object" && counts !== null && Object.entries(counts).every(([end, kinds]) => (end === "pairing" || device(end)) && shape(PUSH_COUNTS)(kinds)),
	})(value);
const DAY: Fields = { day: (value) => typeof value === "string" && /^\d{4}-\d{2}-\d{2}$/.test(value), messages: count, bytes: count };

/** Each object's keys and tables, and what each may hold. */
const STORED: Record<Stored["object"], { kv: Record<string, Kind>; tables: Record<string, Fields> }> = {
	pairing: {
		kv: {
			meta: shape(META),
			devices: (value) => typeof value === "object" && value !== null && Object.entries(value).every(([id, slot]) => device(id) && shape(DEVICE)(slot)),
			days: (value) => typeof value === "object" && value !== null && Object.entries(value).every(([end, day]) => (end === "mac" || device(end)) && shape(DAY)(day)),
			pushes: pushHour,
		},
		tables: {
			// `handed`: whether a take handed it over before, so that only what is handed over again is charged (#806).
			items: { reader, writer: reader, id: itemId, item: storedSealed, presence: (value) => value === 0 || value === 1, expires: time, handed: (value) => value === 0 || value === 1 },
			states: { device, id: itemId, item: storedSealed, expires: time, handed: (value) => value === 0 || value === 1 },
		},
	},
	attestKey: { kv: { tie: shape({ pairing, device, until: time }) }, tables: {} },
	// Connections counted in each minute of the last hour, by the minute's number; registrations' times; when it all goes.
	address: {
		kv: {
			minutes: (value) => typeof value === "object" && value !== null && Object.entries(value).every(([minute, mark]) => /^\d{1,12}$/.test(minute) && count(mark)),
			times: list(time),
			cleanupAt: time,
		},
		tables: {},
	},
};
function storedSealed(value: unknown): boolean {
	return value instanceof Uint8Array && value.length >= 81 && value.length <= 16 * 1024 && value[0] === 0x04;
}
/** What a socket's attachment holds while it is connected (pairing.ts's `Attachment`). */
const ATTACHMENT: Fields = {
	at: time,
	kind: (value) => typeof value === "string" && ["hello", "register", "mac?", "device?", "join?", "register?", "mac", "device", "joined"].includes(value),
	pairing,
	"challenge?": bytes32,
	"device?": device,
	"relayKey?": key,
	"seen?": time,
};

/** Every field an object keeps that the allow-list does not take. */
export function storedFaults(stored: Stored[]): Finding[] {
	const findings: Finding[] = [];
	for (const object of stored) {
		const where = `the ${object.object} object ${object.name}`;
		const allowed = STORED[object.object];
		for (const [name, value] of Object.entries(object.kv)) {
			const kind = allowed.kv[name];
			if (kind === undefined) findings.push({ rule: "stored", where, detail: `a key the allow-list does not have: ${JSON.stringify(name)}` });
			else if (!kind(value)) findings.push({ rule: "stored", where, detail: `${name} holds what the allow-list does not take there` });
		}
		for (const [table, rows] of Object.entries(object.tables)) {
			const fields = allowed.tables[table];
			if (fields === undefined) {
				findings.push({ rule: "stored", where, detail: `a table the allow-list does not have: ${JSON.stringify(table)}` });
				continue;
			}
			rows.forEach((row, index) => {
				const fault = fieldsFault(row, fields);
				if (fault !== null) findings.push({ rule: "stored", where: `${where}, ${table} row ${index}`, detail: fault });
			});
		}
		object.sockets.forEach((attachment, index) => {
			if (attachment === null) return;
			const fault = fieldsFault(attachment, ATTACHMENT);
			if (fault !== null) findings.push({ rule: "stored", where: `${where}, socket ${index}'s attachment`, detail: fault });
		});
	}
	return findings;
}

// MARK: The whole check

/**
 * Checks a recording and the relay's files against the session that made them. Gives every finding; none means the
 * relay saw and kept only sealed bytes and what 5.3 lists. `files` is null where there are none to read (in workerd,
 * whose storage the test reads back through the objects only).
 *
 * It also fails if the recording could not have seen the session: every Noise message the ends sent must have passed
 * through it, every sealed item been put through it, and every item the session left in the mailbox be in what the
 * objects keep and in the files. So a recorder or a reading of the files that stopped working cannot pass by seeing
 * nothing.
 */
export async function check(recording: Recording, files: File[] | null, session: Session): Promise<Finding[]> {
	const findings: Finding[] = [];

	// What the ends sent where the relay must not read it, in every place it saw or kept.
	const haystacks = [
		...recordingHaystacks(recording),
		...storedHaystacks(recording.stored),
		...(files ?? []).map((file) => ({ where: `the relay's file ${file.path}`, bytes: file.bytes })),
	];
	findings.push(...findAll(session.markers, session.secrets, haystacks));

	// What each socket is: the Mac's binary messages carry a device's 16-byte id in front, a phone's carry nothing.
	const roles = new Map<number, "mac" | "device">();
	for (const event of recording.events) {
		if (event.kind !== "text" || event.from !== "end" || roles.has(event.socket)) continue;
		const value = safeParse(event.text) as { hello?: { role?: unknown }; register?: unknown } | null;
		if (value?.register !== undefined) roles.set(event.socket, "mac");
		else if (value?.hello?.role === "mac" || value?.hello?.role === "device") roles.set(event.socket, value.hello.role);
	}

	const noise = new Set(session.noise);
	const items = new Set(session.items);
	const passed = { noise: new Map<string, Set<string>>(), items: new Set<string>() };
	for (const [index, event] of recording.events.entries()) {
		const where = `socket ${event.socket}, event ${index}`;
		if (event.kind === "open") {
			const fault = requestFault(event);
			if (fault !== null) findings.push({ rule: "request", where, detail: fault });
		} else if (event.kind === "text") {
			const fault = messageFault(event.text, event.from);
			if (fault !== null) {
				findings.push({ rule: "control", where: `${where}, from the ${event.from}`, detail: fault });
				continue;
			}
			const keyFault = keysFault(event.text, session.keys);
			if (keyFault !== null) findings.push({ rule: "key", where: `${where}, from the ${event.from}`, detail: keyFault });
			for (const item of sealedItems(event.text)) {
				const hash = await sha256(item);
				if (!items.has(hash)) findings.push({ rule: "not-sealed", where: `${where}, from the ${event.from}`, detail: "an item that is not one of the session's sealed items" });
				if (event.from === "end") passed.items.add(hash);
			}
		} else if (event.kind === "bytes") {
			const role = roles.get(event.socket);
			if (role === undefined) {
				findings.push({ rule: "not-noise", where, detail: "bytes on a socket that never said what it is" });
				continue;
			}
			if (role === "mac") {
				const named = `dev_${toBase64(event.bytes.subarray(0, 16)).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "")}`;
				if (!session.devices.includes(named)) findings.push({ rule: "not-noise", where: `${where}, from the ${event.from}`, detail: "a Mac's binary message for a device that is not the session's" });
			}
			const body = role === "mac" ? event.bytes.subarray(16) : event.bytes;
			const hash = await sha256(body);
			if (!noise.has(hash)) {
				findings.push({ rule: "not-noise", where: `${where}, from the ${event.from}`, detail: "a binary message that is not one of the session's Noise messages" });
				continue;
			}
			const seen = passed.noise.get(hash) ?? new Set();
			seen.add(event.from);
			passed.noise.set(hash, seen);
		}
	}
	findings.push(...storedFaults(recording.stored));
	findings.push(...(await pushFaults(recording, items, roles)));

	// The recorder saw the whole session, and the relay's storage and files were read.
	const unseen = session.noise.filter((hash) => passed.noise.get(hash)?.size !== 2).length;
	if (unseen > 0) findings.push({ rule: "unseen", where: "the recording", detail: `${unseen} of the session's ${session.noise.length} Noise messages did not pass through it both ways` });
	const unput = session.items.filter((hash) => !passed.items.has(hash)).length;
	if (unput > 0) findings.push({ rule: "unseen", where: "the recording", detail: `${unput} of the session's ${session.items.length} sealed items were not put through it` });
	// Everything the mailbox keeps is one of the session's sealed items.
	const storedItems = new Set<string>();
	for (const object of recording.stored) {
		for (const [table, rows] of Object.entries(object.tables)) {
			for (const [index, row] of rows.entries()) {
				if (!(row.item instanceof Uint8Array)) continue;
				const hash = await sha256(row.item);
				storedItems.add(hash);
				if (!items.has(hash) && !session.kept.includes(hash)) {
					findings.push({ rule: "not-sealed", where: `the ${object.object} object ${object.name}, ${table} row ${index}`, detail: "an item that is not one of the session's sealed items" });
				} else if (!session.kept.includes(hash)) {
					// A take deletes nothing (#806): the session acknowledges what it took, and only what it left may still be kept.
					// Scanned above all the same, wherever it is.
					findings.push({ rule: "acknowledged", where: `the ${object.object} object ${object.name}, ${table} row ${index}`, detail: "an item the session took and acknowledged, or did not leave, still kept" });
				}
			}
		}
	}
	for (const hash of session.kept) {
		if (!storedItems.has(hash)) findings.push({ rule: "unseen", where: "the objects' storage", detail: `an item the session left in the mailbox (${hash.slice(0, 12)}…) is not in it` });
	}
	if (files === null) return findings;
	if (session.kept.length > 0 && files.length === 0) findings.push({ rule: "unseen", where: "the relay's files", detail: "none were read" });
	// Every object the relay keeps a file for was read back, and so held to the allow-list.
	const read = new Set(recording.stored.map((object) => object.id));
	for (const file of files) {
		const id = /(?:^|\/)do\/[^/]+\/([0-9a-f]{64})\.sqlite$/.exec(file.path)?.[1];
		if (id !== undefined && !read.has(id)) findings.push({ rule: "unread", where: `the relay's file ${file.path}`, detail: "an object the read-back did not read" });
	}
	const fileText = files.map((file) => latin1(file.bytes)).join("\n");
	const keptBytes = await keptItemBytes(recording, new Set(session.kept));
	if (keptBytes.length !== session.kept.length) findings.push({ rule: "unseen", where: "the recording", detail: "an item the session left in the mailbox was not put through it" });
	for (const bytes of keptBytes) {
		if (!fileText.includes(latin1(bytes))) findings.push({ rule: "unseen", where: "the relay's files", detail: "an item the session left in the mailbox is not in them" });
	}
	return findings;
}

// MARK: Pushes to Apple

/** Apple's two hosts (src/apns.ts, `HOSTS`). */
const APPLE: Record<string, string> = { "https://api.sandbox.push.apple.com": "development", "https://api.push.apple.com": "production" };
const LIVE_ACTIVITY_TOPIC = ".push-type.liveactivity";
/** The provider token: an ES256 JWT, three base64url parts, which carries the key's id, the team and a time. */
const bearer: Kind = (value) => typeof value === "string" && /^bearer [A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/.test(value);
/** An app's bundle id, as `apns-topic` names it. */
const bundleId = (value: string) => /^[a-z0-9-]+(?:\.[a-z0-9-]+)+$/.test(value);
/** The headers of each kind of request to Apple, and what each may hold (relay/README.md, "Pushes", "Live Activities"). */
const APPLE_HEADERS: Record<"alert" | "background" | "activity", Fields> = {
	alert: {
		authorization: bearer,
		"apns-topic": (value) => typeof value === "string" && bundleId(value) && !value.endsWith(LIVE_ACTIVITY_TOPIC),
		"apns-push-type": (value) => value === "alert",
		"apns-priority": (value) => value === "10",
		"apns-expiration": (value) => typeof value === "string" && /^[1-9][0-9]{9}$/.test(value),
		"apns-collapse-id?": bytes32,
	},
	background: {
		authorization: bearer,
		"apns-topic": (value) => typeof value === "string" && bundleId(value) && !value.endsWith(LIVE_ACTIVITY_TOPIC),
		"apns-push-type": (value) => value === "background",
		"apns-priority": (value) => value === "5",
		"apns-expiration": (value) => typeof value === "string" && /^[1-9][0-9]{9}$/.test(value),
	},
	activity: {
		authorization: bearer,
		"apns-topic": (value) => typeof value === "string" && value.endsWith(LIVE_ACTIVITY_TOPIC) && bundleId(value.slice(0, -LIVE_ACTIVITY_TOPIC.length)),
		"apns-push-type": (value) => value === "liveactivity",
		"apns-priority": (value) => value === "5",
		"apns-expiration": (value) => typeof value === "string" && /^[1-9][0-9]{9}$/.test(value),
	},
};

/**
 * Every request the relay made of Apple's service, held to what the Mac asked for (#689): each push the relay answered
 * `ok` is one request, in order, and nothing else is; its address is a token the session's own phone gave on its own
 * socket (`token` for an alert or a background push, `activityToken` for a Live Activity), never one the Mac sent; its
 * headers exactly its kind's; an alert's or a background push's body exactly the fixed payload round the very sealed
 * bytes the Mac sent, which must be one of the session's sealed items, an alert's collapse id exactly the Mac's; and a
 * Live Activity's body exactly `activityPayload`'s form round the same four numbers the Mac sent, and nothing else.
 */
export async function pushFaults(recording: Recording, items: Set<string>, roles: Map<number, "mac" | "device">): Promise<Finding[]> {
	const findings: Finding[] = [];
	const waiting = new Map<number, Record<string, unknown>[]>();
	const sent: Record<string, unknown>[] = [];
	const tokens = { push: new Set<string>(), activity: new Set<string>() };
	for (const event of recording.events) {
		if (event.kind !== "text") continue;
		const value = safeParse(event.text) as Record<string, Record<string, unknown>> | null;
		if (value === null || typeof value !== "object") continue;
		const role = roles.get(event.socket);
		if (event.from === "end" && role === "device" && value.token !== undefined) tokens.push.add(`${value.token.environment} ${value.token.apns}`);
		if (event.from === "end" && role === "device" && value.activityToken !== undefined) tokens.activity.add(`${value.activityToken.environment} ${value.activityToken.apns}`);
		if (role !== "mac") continue;
		if (event.from === "end" && value.push !== undefined) waiting.set(event.socket, [...(waiting.get(event.socket) ?? []), value.push]);
		const answered = event.from === "relay" ? (value.ok ?? value.refused) : undefined;
		if (answered?.what === "push") {
			const asked = waiting.get(event.socket)?.shift();
			if (asked === undefined) findings.push({ rule: "push", where: `socket ${event.socket}`, detail: "an answer to a push the Mac did not ask for" });
			else if (value.ok !== undefined) sent.push(asked);
		}
	}
	if (sent.length !== recording.pushes.length) {
		findings.push({ rule: "unseen", where: "the pushes to Apple", detail: `the relay said ${sent.length} pushes were sent, and Apple's stand-in took ${recording.pushes.length}` });
	}
	for (const [index, push] of recording.pushes.entries()) {
		const where = `push ${index}`;
		const asked = sent[index];
		if (asked === undefined) continue;
		const fault = (detail: string) => findings.push({ rule: "push", where, detail });
		const kind = asked.kind as "alert" | "background" | "activity";
		const address = /^(https:\/\/[a-z.]+)\/3\/device\/([0-9a-f]+)$/.exec(push.url);
		const environment = address === null ? undefined : APPLE[address[1]];
		if (address === null || environment === undefined) fault("an address that is not Apple's push service and a device token");
		else if (!(kind === "activity" ? tokens.activity : tokens.push).has(`${environment} ${address[2]}`)) {
			fault(`a token the session's phone did not give for this kind on its own socket, in this environment`);
		}
		const headers: Record<string, string> = {};
		for (const [name, value] of push.headers) headers[name.toLowerCase()] = value;
		const headerFault = fieldsFault(headers, APPLE_HEADERS[kind] ?? {});
		if (headerFault !== null) fault(`its headers: ${headerFault}`);
		const body = new TextDecoder().decode(push.body);
		if (kind === "alert" || kind === "background") {
			const sealed = asked.sealed as string;
			const expected =
				kind === "alert"
					? JSON.stringify({ aps: { alert: { title: "pi²", body: "Something needs you" }, "mutable-content": 1 }, sealed })
					: JSON.stringify({ aps: { "content-available": 1 }, sealed });
			if (body !== expected) fault("a body that is not the fixed payload round the sealed bytes the Mac sent");
			if (kind === "alert" && headers["apns-collapse-id"] !== asked.collapse) fault("a collapse id that is not the one the Mac sent");
			const bytes = fromBase64url(sealed);
			if (bytes === null || !items.has(await sha256(bytes))) findings.push({ rule: "not-sealed", where, detail: "sealed bytes that are not one of the session's sealed items" });
		} else {
			const parsed = safeParse(body) as { aps?: { timestamp?: unknown; event?: unknown } } | null;
			const timestamp = parsed?.aps?.timestamp;
			const aps: Record<string, unknown> = { timestamp, event: asked.event, "content-state": asked.state };
			if (asked.event === "end" && typeof timestamp === "number") aps["dismissal-date"] = timestamp + 900;
			if (!Number.isSafeInteger(timestamp) || (timestamp as number) <= 0 || body !== JSON.stringify({ aps })) {
				fault("a body that is not a Live Activity's payload round the four numbers the Mac sent, and nothing else");
			}
		}
	}
	return findings;
}

/** Why a message names a key that is not the session's own for its field (`relayKey`, `deviceKey`); null if none. */
function keysFault(text: string, keys: Session["keys"]): string | null {
	const value = safeParse(text) as Record<string, Record<string, unknown>> | null;
	const body = value === null ? undefined : Object.values(value)[0];
	if (typeof body !== "object" || body === null) return null;
	for (const field of ["relayKey", "deviceKey"] as const) {
		if (field in body && !keys[field].includes(body[field] as string)) return `a ${field} that is not the session's own`;
	}
	return null;
}

/** The bytes of every sealed item a text message carries (`put`, `state`, `item`, and a sealed `push`). */
function sealedItems(text: string): Uint8Array[] {
	const value = safeParse(text) as Record<string, Record<string, unknown>> | null;
	if (value === null) return [];
	const body = Object.values(value)[0];
	if (typeof body !== "object" || body === null) return [];
	const field = typeof body.item === "string" ? body.item : "push" in value && typeof body.sealed === "string" ? body.sealed : null;
	const bytes = field === null ? null : fromBase64url(field);
	return bytes === null ? [] : [bytes];
}

async function keptItemBytes(recording: Recording, kept: Set<string>): Promise<Uint8Array[]> {
	const found = new Map<string, Uint8Array>();
	for (const event of recording.events) {
		if (event.kind !== "text" || event.from !== "end") continue;
		for (const item of sealedItems(event.text)) {
			const hash = await sha256(item);
			if (kept.has(hash)) found.set(hash, item);
		}
	}
	return [...found.values()];
}

function safeParse(text: string): unknown {
	try {
		return JSON.parse(text);
	} catch {
		return null;
	}
}
