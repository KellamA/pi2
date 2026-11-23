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
	kv: Record<string, unknown>;
	tables: Record<string, Record<string, unknown>[]>;
	sockets: unknown[];
};

/**
 * A push the relay asked Apple's service to send, as the local stand-in for APNs recorded it. The relay at this head
 * sends none (pushes are P20's, #689); the stand-in P20 adds hands each request to the recorder, and it is checked here
 * as everything else is.
 */
export type Push = { url: string; headers: [string, string][]; body: Uint8Array };

export type Recording = { events: Event[]; stored: Stored[]; pushes: Push[] };

/** A file of the relay's local state, as Wrangler's `--persist-to` left it, read whole. */
export type File = { path: string; bytes: Uint8Array };

/** A text the session sent where the relay must not read it, and where it put it (`place`). */
export type Marker = { place: string; text: string };

/** What the session's own ends say of it (check.mjs reads it from the Swift program's file). */
export type Session = {
	/** Every marker it sent, by place. */
	markers: Marker[];
	/** Bytes that must never be seen at all: the ends' private keys, the pairing's secret, the channels' bindings. */
	secrets: Uint8Array[];
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
/** App Attest's attestation object, as the phone sends it at `join`: Apple's, which the relay checks (3.3, 6.6). */
const attestation: Kind = isBytes(undefined, 1, 32 * 1024);
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

/** The fixed words of a refusal (relay/README.md, "Refusals"): never what a client sent. */
const WHY = [
	"malformed", "unavailable", "unknown-pairing", "not-listed", "signature", "update-required", "another-mac", "limits", "too-many",
	"timeout", "window-closed", "token", "attestation", "category", "bundle-version", "attest-key-taken", "full", "exists",
	"unknown-device", "device-key", "not-joined", "mailbox-full", "busy", "removed", "left", "deleted", "replaced", "window-ended",
];
const why: Kind = (value) => typeof value === "string" && WHY.includes(value);
const REQUESTS = ["openJoin", "closeJoin", "addDevice", "removeDevice", "deletePairing", "state", "put", "take", "token", "leave"];
const what: Kind = (value) => typeof value === "string" && REQUESTS.includes(value);

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
	token: [{ apns, environment }],
	leave: [{ signature }],
	ping: [{}],
};

/** Every text message the relay may send an end, by name, and each form its body may have. */
export const FROM_THE_RELAY: Record<string, Fields[]> = {
	registered: [{ pairing }],
	ready: [
		{ devices: list(shape({ device, online: bool })), left: list(device), pending: bool, mail: count },
		{ mac: bool, mail: count },
	],
	joined: [{ device }, { device, deviceKey: key, keyId: attestKeyId }],
	ok: [{ what }],
	refused: [{ why }, { what, why }],
	item: [{ from: reader, id: itemId, item: sealed, presence: bool }],
	state: [{ id: itemId, item: sealed }],
	taken: [{ count }],
	online: [{ device }],
	offline: [{ device }],
	left: [{ device }],
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
 * The `User-Agent` RemoteKit's relay client sends on every connection: a fixed text that says nothing of the person,
 * the device or its system (#678's security read, S2, which folded in #819). Pinned here to the client's own value, so
 * that the check fails if the system's (the program's name, CFNetwork's and Darwin's versions) comes back. Null until
 * the client that sends it is merged into this branch; until then every connection fails the check.
 */
export const USER_AGENT: string | null = null;

/**
 * The headers a connection may carry to the relay, each with what it may hold: the WebSocket's own, the pairing's,
 * the two URLSession adds whatever the client asks (the same for everyone), the client's fixed `User-Agent`, and the
 * address the local runtime puts on a request before the Worker sees it. Anything else fails until it is named here:
 * `Accept-Language` among them, which would tell the relay the person's languages. Each value is searched for markers
 * too.
 */
export const HEADERS: Record<string, Kind> = {
	// The WebSocket's handshake (RFC 6455) and HTTP's own.
	host: (value) => typeof value === "string" && /^(?:127\.0\.0\.1|localhost|\[::1\])(?::\d{1,5})?$/.test(value),
	upgrade: (value) => value === "websocket",
	connection: (value) => value === "Upgrade",
	"sec-websocket-key": (value) => typeof value === "string" && /^[A-Za-z0-9+/]{22}==$/.test(value),
	"sec-websocket-version": (value) => value === "13",
	"sec-websocket-extensions": (value) => typeof value === "string" && /^permessage-deflate(?:; ?[a-z_]+(?:=\d+)?)*$/.test(value),
	// The pairing, which takes the connection to its object (5.3).
	"pi2-pairing": pairing,
	// URLSession's own, the same for everyone.
	accept: (value) => value === "*/*",
	"accept-encoding": (value) => typeof value === "string" && /^[a-z]+(?:, [a-z]+)*$/.test(value),
	// The relay client's own, fixed (USER_AGENT above).
	"user-agent": (value) => USER_AGENT !== null && value === USER_AGENT,
	// The connecting address, which the local runtime sets as Cloudflare does (5.3: the relay knows it, and keeps none).
	"cf-connecting-ip": (value) => typeof value === "string" && /^[0-9a-f.:]+$/.test(value),
};

/** Why a connection's request is not one the allow-list takes; null if it is. */
export function requestFault(event: Extract<Event, { kind: "open" }>): string | null {
	const url = new URL(event.url);
	if (url.pathname !== "/v1" || url.search !== "") return "an address that carries more than /v1";
	for (const [name, value] of event.headers) {
		const kind = HEADERS[name.toLowerCase()];
		if (kind === undefined) return `a header the allow-list does not have: ${name}`;
		if (!kind(value)) {
			return name.toLowerCase() === "user-agent"
				? "a User-Agent that is not the relay client's fixed one (USER_AGENT in scan.ts)"
				: `a ${name} header that is not what the allow-list takes`;
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
	left: list(device),
};
const DEVICE: Fields = {
	key,
	listed: bool,
	attestKeyIds: list(attestKeyId),
	macKeyId: (value) => value === null || attestKeyId(value),
	token: (value) => value === null || shape({ apns, environment })(value),
};
const DAY: Fields = { day: (value) => typeof value === "string" && /^\d{4}-\d{2}-\d{2}$/.test(value), messages: count, bytes: count };

/** Each object's keys and tables, and what each may hold. */
const STORED: Record<Stored["object"], { kv: Record<string, Kind>; tables: Record<string, Fields> }> = {
	pairing: {
		kv: {
			meta: shape(META),
			devices: (value) => typeof value === "object" && value !== null && Object.entries(value).every(([id, slot]) => device(id) && shape(DEVICE)(slot)),
			days: (value) => typeof value === "object" && value !== null && Object.entries(value).every(([end, day]) => (end === "mac" || device(end)) && shape(DAY)(day)),
		},
		tables: {
			items: { reader, writer: reader, id: itemId, item: storedSealed, presence: (value) => value === 0 || value === 1, expires: time },
			states: { device, id: itemId, item: storedSealed, expires: time },
		},
	},
	attestKey: { kv: { tie: shape({ pairing, device, until: time }) }, tables: {} },
	address: { kv: { times: list(time) }, tables: {} },
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

	// The recorder saw the whole session, and the relay's storage and files were read.
	const unseen = session.noise.filter((hash) => passed.noise.get(hash)?.size !== 2).length;
	if (unseen > 0) findings.push({ rule: "unseen", where: "the recording", detail: `${unseen} of the session's ${session.noise.length} Noise messages did not pass through it both ways` });
	const unput = session.items.filter((hash) => !passed.items.has(hash)).length;
	if (unput > 0) findings.push({ rule: "unseen", where: "the recording", detail: `${unput} of the session's ${session.items.length} sealed items were not put through it` });
	const storedItems = new Set<string>();
	for (const object of recording.stored) {
		for (const rows of Object.values(object.tables)) {
			for (const row of rows) if (row.item instanceof Uint8Array) storedItems.add(await sha256(row.item));
		}
	}
	for (const hash of session.kept) {
		if (!storedItems.has(hash)) findings.push({ rule: "unseen", where: "the objects' storage", detail: `an item the session left in the mailbox (${hash.slice(0, 12)}…) is not in it` });
	}
	if (files === null) return findings;
	if (session.kept.length > 0 && files.length === 0) findings.push({ rule: "unseen", where: "the relay's files", detail: "none were read" });
	const fileText = files.map((file) => latin1(file.bytes)).join("\n");
	const keptBytes = await keptItemBytes(recording, new Set(session.kept));
	if (keptBytes.length !== session.kept.length) findings.push({ rule: "unseen", where: "the recording", detail: "an item the session left in the mailbox was not put through it" });
	for (const bytes of keptBytes) {
		if (!fileText.includes(latin1(bytes))) findings.push({ rule: "unseen", where: "the relay's files", detail: "an item the session left in the mailbox is not in them" });
	}
	return findings;
}

/** The bytes of every sealed item a text message carries (`put`, `state`, `item`). */
function sealedItems(text: string): Uint8Array[] {
	const value = safeParse(text) as Record<string, Record<string, unknown>> | null;
	if (value === null) return [];
	const body = Object.values(value)[0];
	if (typeof body !== "object" || body === null || typeof body.item !== "string") return [];
	const bytes = fromBase64url(body.item);
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
