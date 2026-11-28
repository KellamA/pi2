// Paired devices in the engine (docs/iphone.md sections 3 and 4, #673): the record of each device, pairing as the
// engine sees it, the checks of every attach, resume and sealed item, the devices' log, and the `devices` event.
//
// The engine is the judge of who is speaking. A paired phone is a second way to be the person, with keys made at
// pairing that the Mac can revoke. pi² Remote (remote.ts) holds the channels and the Mac's keys; everything it passes
// on is checked here again, against the engine's own record: a fault in the helper cannot make the engine take what
// the device's table (answers.ts) refuses, nor an attach without the device's own signatures.
//
// The shapes are RemoteKit's (docs/remotekit.md, #674): bytes in text are base64url without padding, written one way;
// P-256 keys are SPKI DER; signatures are ECDSA P-256 over SHA-256 of the exact `signed` text, 64 raw bytes (r then s);
// `signed` is compact JSON read strictly, every field present in order and none unknown. Every comparison of a secret,
// a binding, a challenge or the digits takes a time that depends on the length alone. Nothing key-shaped, and no value
// of a secret the engine knows (secrets.ts), goes into the devices' log (`maskKeys`), and the pairing's secret `s`
// goes only into the answer to `devices.pairStart`, on the app's own connection, and to pi² Remote, never into an event or a log (3.1).

import { createHash, createHmac, createPublicKey, type KeyObject, randomBytes, timingSafeEqual, verify } from "node:crypto";
import { homedir, hostname } from "node:os";
import type { Context } from "@earendil-works/chord/context";
import { defineDoc, type Harness } from "@earendil-works/pi-durable";
import { type DevicePath, deviceMay, type DeviceSession, devicePlacement, ONLY_ON_THE_MAC } from "./answers.ts";
import { AppAttestError, type AppAttestEnvironment, type AppAttestResult, verifyAttestation } from "./appattest.ts";
import type { Client } from "./clients.ts";
import { RequestError } from "./requesterror.ts";
import { SECRET_HIDDEN, secretSpans } from "./secrets.ts";
import { releaseEngine, testCopySuffix, testSwitch } from "./testswitches.ts";

// ---- The records (3.2, 4.3, 4.4)

export type Device = {
	id: string; // "dev_" and 16 random bytes, base64url; also the device's slot at the relay
	name: string; // as the phone gave it; the person can rename it on the Mac
	model: string;
	system: string;
	deviceKey: string; // public halves, SPKI DER in base64url; "" once revoked
	presenceKey: string | null;
	pendingPresenceKey: string | null; // a new one, until the person accepts it on the Mac
	channelKey: string; // 32 raw Curve25519 bytes in base64url; "" once revoked
	recordKey: string; // SPKI DER in base64url; "" once revoked
	attestKeyId: string; // the App Attest key the Mac checked at pairing, as DCAppAttestService names it (base64); "" for a simulator a test copy paired
	build: string;
	suspendedAt: number | null;
	pairedAt: number;
	lastSeenAt: number | null;
	lastPath: DevicePath | null;
	revokedAt: number | null; // kept 90 days for the log, then removed
	/** Once revoked: the SHA-256 of its device key (base64url), so that the same key cannot pair again while the record is kept. */
	deviceKeyHash?: string;
};

export type RemoteSwitches = { on: boolean; relay: boolean; home: boolean; direct: boolean; preview: boolean };
export type MacKeys = { identity: string; channel: string; record: string; relay: string; secureEnclave: boolean };

export type DevicesState = {
	pairing: string | null; // the pairing's id at the relay
	relay: string; // the relay's address
	macName: string;
	remote: RemoteSwitches;
	macKeys: MacKeys | null; // public halves, as pi² Remote reported them
	devices: Device[];
};

/** The document `pi2.devices`. Everything off until the person turns the preview and remote access on (decision 19). */
export const Devices = defineDoc<DevicesState>({
	kind: "pi2.devices",
	version: 1,
	scope: "session",
	initial: () => ({ pairing: null, relay: "", macName: "", remote: { on: false, relay: true, home: true, direct: false, preview: false }, macKeys: null, devices: [] }),
	checkpointWhen: () => true,
});

/** The nonces of the sealed items taken, by device and nonce, with when: kept 48 hours, through a restart (4.3). */
export const DeviceNonces = defineDoc<{ taken: Record<string, number> }>({
	kind: "pi2.deviceNonces",
	version: 1,
	scope: "session",
	initial: () => ({ taken: {} }),
	checkpointWhen: () => true,
});

export type DeviceLogEntry = {
	at: number;
	device: string;
	path: DevicePath;
	method: string; // or "pair", "attach", "resume", "suspend"
	summary: string; // made by `summarize`
	presence: boolean; // the session or item was opened under a valid presence signature
	outcome: "done" | "refused" | "failed";
	why?: string;
	/** Refusals of the same request for the same reason within a minute of each other, made one entry: how many, and the last's time. */
	count?: number;
	lastAt?: number;
};

/** The document `pi2.deviceLog`: 90 days, at most 10,000 entries, the oldest going first (4.4). */
export const DeviceLog = defineDoc<{ entries: DeviceLogEntry[] }>({
	kind: "pi2.deviceLog",
	version: 1,
	scope: "session",
	initial: () => ({ entries: [] }),
	checkpointWhen: () => true,
});

const DAY = 86_400_000;
const KEPT = 90 * DAY;
const MAX_LOG = 10_000;
const MAX_DEVICES = 5;
const NONCES_KEPT = 2 * DAY;
const WINDOW_MS = 5 * 60_000;
const CHALLENGE_MS = 2 * 60_000;
const AT_WITHIN = 2 * 60_000;
/** How far ahead of the Mac's clock a sealed item's `at` may be (section 11: five minutes of difference). */
const ITEM_AHEAD = 5 * 60_000;
const SUSPEND_AFTER = 5;
const SUSPEND_WITHIN = 10 * 60_000;

/** The lowest build of pi² for iPhone the engine attaches (5.3's minimum, S7). Raised when a phone's build must go. */
export const MINIMUM_PHONE_BUILD = "1";
/** pi² for iPhone's bundle id, which its App Attest key is made for. */
export const IPHONE_BUNDLE_ID = "dev.pi2.ios";
/**
 * pi²'s team id, the App ID prefix App Attest checks. Null until signing is set up (P14, #686): until then a release
 * engine takes no pairing claim at all, and a development engine only with the team its tests name.
 */
export const IPHONE_TEAM_ID: string | null = null;

// ---- Wiring

type Names = { conversation: (id: number) => string | undefined; project: (id: string) => string | undefined };
type DeviceParts = {
	harness: Harness;
	context: Context;
	log: (...parts: unknown[]) => void;
	/** A release engine: production App Attest keys alone, of apps App Store or TestFlight distributed. */
	release: boolean;
	names: Names;
};

/** What remote.ts gives this file: pi² Remote's side of each step. Set once, by `wireRemote`. */
export type RemoteHooks = {
	/** Something that decides whether pi² Remote should run changed. */
	changed: () => void;
	/** Sends pi² Remote a `remote` event. */
	toHelper: (event: Record<string, unknown>) => void;
	/** Waits for a pi² Remote that has said hello, starting one; throws if it cannot. */
	ready: () => Promise<{ addresses: string[] }>;
	/** Closes the device's sessions, telling each first, as `device` events, if it was revoked. */
	closeSessions: (device: string, why: string) => void;
	/** The open sessions, for the Devices page and the menu bar (4.4). */
	sessions: () => { device: string; session: string; path: DevicePath; since: number }[];
	/** pi² Remote's own state, for the Devices page: with what it said of the relay path (`remote.state`'s `relay`). */
	helper: () => { running: boolean; stoppedInLastHour: number; relay?: Record<string, unknown> | null };
	/** Each device session's record changed: its `device` event is sent again. */
	recordChanged: (device: string) => void;
	/** The Mac's addresses as the running pi² Remote said them, or null when none has said hello. */
	addresses: () => string[] | null;
	/**
	 * What pi² Remote says of the relay path once it is about the relay's address now set (#1013), or null if it does not
	 * say it within `within` ms.
	 */
	relayWord: (within: number) => Promise<Record<string, unknown> | null>;
	/** pi² Remote's last word about the address and the pairing now set, kept while it is stopped; or null. */
	lastRelayWord: () => Record<string, unknown> | null;
};

let harness: Harness;
let context: Context;
let log: DeviceParts["log"];
let release: boolean;
let names: Names;
let state: DevicesState = Devices.definition.initial();
/**
 * Why the stored record of devices, their nonces or their log could not be read, or null. Then no device can pair,
 * attach or send anything, pi² Remote is not started, and the Devices page is told why (`devices` event); the rest of
 * the engine starts and works as before. Nothing is written over what could not be read.
 */
let unreadable: string | null = null;
/** Devices being saved by `pairConfirm`: pi² Remote is wanted meanwhile, to tell the phone. */
let saving = 0;
/**
 * Whether the relay last refused a Live Activity push because this Mac's clock seems wrong, and no activity push since
 * has gone unanswered (pushes.ts, #915): the Devices page says so in words. In memory alone, gone with the engine.
 */
let pushClockWrong = false;
export const remoteHooks: RemoteHooks = {
	changed: () => {},
	toHelper: () => {},
	ready: async () => {
		throw new Error("pi² Remote is not part of this engine.");
	},
	closeSessions: () => {},
	sessions: () => [],
	helper: () => ({ running: false, stoppedInLastHour: 0 }),
	recordChanged: () => {},
	addresses: () => null,
	// The tests that play no pi² Remote: a pairing registered here. An engine's own is remote.ts's (`wireRemote`), and
	// without one `ready` refuses before any pairing opens.
	relayWord: async () => ({ registered: "here", address: state.relay }),
	lastRelayWord: () => null,
};

const isObject = (value: unknown): value is Record<string, unknown> => typeof value === "object" && value !== null && !Array.isArray(value);
const isText = (value: unknown) => typeof value === "string";
const textOrNull = (value: unknown) => value === null || typeof value === "string";
const timeOrNull = (value: unknown) => value === null || typeof value === "number";

/** What is wrong with a stored `pi2.devices`, or null for nothing. */
function devicesProblem(value: unknown): string | null {
	if (!isObject(value)) return "it is not a record";
	if (!textOrNull(value.pairing) || !isText(value.relay) || !isText(value.macName)) return "its pairing, relay or name is not one";
	const switches = value.remote;
	if (!isObject(switches) || !["on", "relay", "home", "direct", "preview"].every((key) => typeof switches[key] === "boolean")) return "its switches are not ones";
	const keys = value.macKeys;
	if (keys !== null && (!isObject(keys) || !["identity", "channel", "record", "relay"].every((key) => isText(keys[key])) || typeof keys.secureEnclave !== "boolean")) {
		return "the Mac's keys in it are not ones";
	}
	if (!Array.isArray(value.devices)) return "its devices are not a list";
	for (const device of value.devices) {
		const fine =
			isObject(device) &&
			["id", "name", "model", "system", "deviceKey", "channelKey", "recordKey", "attestKeyId", "build"].every((key) => isText(device[key])) &&
			textOrNull(device.presenceKey) &&
			textOrNull(device.pendingPresenceKey) &&
			timeOrNull(device.suspendedAt) &&
			timeOrNull(device.lastSeenAt) &&
			timeOrNull(device.revokedAt) &&
			typeof device.pairedAt === "number" &&
			[null, "relay", "home", "direct", "mailbox"].includes(device.lastPath as string | null) &&
			(device.deviceKeyHash === undefined || isText(device.deviceKeyHash));
		if (!fine) return "a device in it is not one";
	}
	return null;
}

/** What is wrong with the stored nonces or log, or null. */
function nonceProblem(value: unknown): string | null {
	return isObject(value) && isObject(value.taken) && Object.values(value.taken).every((at) => typeof at === "number") ? null : "the nonces taken are not a record of them";
}
function logProblem(value: unknown): string | null {
	if (!isObject(value) || !Array.isArray(value.entries)) return "the devices' log is not a list";
	const fine = (entry: unknown) => isObject(entry) && typeof entry.at === "number" && isText(entry.device) && isText(entry.method) && isText(entry.summary) && isText(entry.outcome);
	return value.entries.every(fine) ? null : "an entry of the devices' log is not one";
}

/**
 * Reads the record, and removes what has been revoked for 90 days. A record, nonces or log that cannot be read refuses
 * every device, and does not stop the engine (`unreadable`).
 */
export async function wireDevices(parts: DeviceParts): Promise<void> {
	({ harness, context, log, release, names } = parts);
	const now = Date.now();
	const gone = (device: Device) => device.revokedAt !== null && now - device.revokedAt >= KEPT;
	unreadable = null;
	state = Devices.definition.initial();
	let problem: string | null;
	try {
		const stored = await harness.snapshot(Devices, context);
		const nonces = await harness.snapshot(DeviceNonces, context);
		const entries = await harness.snapshot(DeviceLog, context);
		problem =
			(stored === undefined ? null : devicesProblem(stored)) ?? (nonces === undefined ? null : nonceProblem(nonces)) ?? (entries === undefined ? null : logProblem(entries));
		if (problem === null && stored !== undefined) state = stored;
	} catch (error) {
		problem = error instanceof Error ? error.message : String(error);
	}
	if (problem !== null) {
		unreadable = `pi²'s record of paired devices could not be read (${problem}), so no device can pair or connect. The rest of pi² works as before.`;
		log("devices:", unreadable);
		return;
	}
	// Nothing is written at start unless something is due to go: with no device, the documents are never made.
	if (state.devices.some(gone)) {
		await harness.commit(async (tx) => {
			const doc = await tx.doc(Devices);
			doc.devices = doc.devices.filter((device) => !gone(device));
		}, context);
		state = (await harness.snapshot(Devices, context)) ?? state;
	}
}

/** The record as it is now. */
export function devicesState(): Readonly<DevicesState> {
	return state;
}

/** A paired device, not revoked. */
export function pairedDevice(id: unknown): Device | undefined {
	return typeof id === "string" ? state.devices.find((device) => device.id === id && device.revokedAt === null) : undefined;
}

export function activeDevices(): Device[] {
	return state.devices.filter((device) => device.revokedAt === null);
}

/** Whether pi² Remote should run (5.5): the preview and remote access on, and a device paired or a pairing open. */
export function helperWanted(): boolean {
	return unreadable === null && state.remote.preview && state.remote.on && (activeDevices().length > 0 || window !== null || saving > 0 || askingAgain > 0);
}

/** Whether devices may pair and attach at all: the preview (decision 19) and remote access on. */
export function remoteOn(): boolean {
	return unreadable === null && state.remote.preview && state.remote.on;
}

async function change(edit: (doc: DevicesState) => void): Promise<void> {
	if (unreadable !== null) throw new Error(unreadable);
	await harness.commit(async (tx) => edit(await tx.doc(Devices)), context);
	state = (await harness.snapshot(Devices, context)) ?? state;
	announce();
	remoteHooks.changed();
}

/** What pi² Remote reported of itself (`remote.hello`, `remote.state`). */
export async function helperReported(given: { macKeys?: MacKeys; pairing?: string | null }): Promise<void> {
	const keys = given.macKeys;
	// A pairing the person started again from is never taken back: a hello or a state in flight may still name it (#917).
	const pairing = given.pairing != null && forgottenPairings.has(given.pairing) ? null : (given.pairing ?? null);
	if (pairing !== null && state.pairing !== null && pairing !== state.pairing) {
		throw new Error("pi² Remote names another pairing than this Mac's.");
	}
	const sameKeys = keys === undefined || JSON.stringify(keys) === JSON.stringify(state.macKeys);
	if (sameKeys && (pairing === null || pairing === state.pairing)) return;
	await change((doc) => {
		if (keys !== undefined) doc.macKeys = keys;
		if (pairing !== null) doc.pairing = pairing;
	});
}

// ---- Bytes, keys, signatures (docs/remotekit.md, "Everywhere")

/** Base64url without padding, in its one form; `length` in bytes when given. Null for anything else. */
export function fromBase64url(text: unknown, length?: number): Buffer | null {
	if (typeof text !== "string" || text.length > 64 * 1024 || !/^[A-Za-z0-9_-]*$/.test(text)) return null;
	const bytes = Buffer.from(text, "base64url");
	if (bytes.toString("base64url") !== text) return null;
	if (length !== undefined && bytes.length !== length) return null;
	return bytes;
}

/** Standard base64 with padding, in its one form, as DCAppAttestService writes a key id. */
function fromBase64(text: unknown, length: number): Buffer | null {
	if (typeof text !== "string" || text.length > 128 || !/^[A-Za-z0-9+/]*={0,2}$/.test(text)) return null;
	const bytes = Buffer.from(text, "base64");
	return bytes.length === length && bytes.toString("base64") === text ? bytes : null;
}

/** Equal, in a time that depends on the lengths alone. */
export function same(a: Uint8Array, b: Uint8Array): boolean {
	return a.length === b.length && a.length > 0 && timingSafeEqual(a, b);
}

const sameText = (a: string, b: string) => same(Buffer.from(a), Buffer.from(b));

/**
 * The SPKI header of an uncompressed P-256 point, up to and with its 0x04: id-ecPublicKey, prime256v1, a 66-byte bit
 * string. With the point's 64 bytes, 91 bytes in all: CryptoKit's `derRepresentation`, the one form RemoteKit's
 * `PublicKeys.signingKey` takes (#786). A compressed point names the same key in other bytes, so it is refused: each
 * key has one text, which the engine compares.
 */
const P256_SPKI_HEADER = Buffer.from("3059301306072a8648ce3d020106082a8648ce3d030107034200" + "04", "hex");

/** A P-256 public key written as SPKI DER in base64url, in the one encoding a key has: uncompressed, as RemoteKit writes it. */
export function p256Key(text: unknown): KeyObject | null {
	if (typeof text !== "string" || text.length > 200) return null;
	const der = fromBase64url(text);
	if (der === null || der.length !== 91 || !der.subarray(0, P256_SPKI_HEADER.length).equals(P256_SPKI_HEADER)) return null;
	try {
		const key = createPublicKey({ key: der, format: "der", type: "spki" });
		if (key.asymmetricKeyType !== "ec" || key.asymmetricKeyDetails?.namedCurve !== "prime256v1") return null;
		return same(key.export({ format: "der", type: "spki" }), der) ? key : null;
	} catch {
		return null;
	}
}

/** Whether `key` made `signature` (64 raw bytes, base64url) over the exact bytes of `text`. */
export function signedBy(text: string, signature: unknown, key: KeyObject): boolean {
	const bytes = fromBase64url(signature, 64);
	if (bytes === null) return false;
	try {
		return verify("sha256", Buffer.from(text, "utf8"), { key, dsaEncoding: "ieee-p1363" }, bytes);
	} catch {
		return false;
	}
}

/**
 * Reads `text` as a signed statement: compact JSON as RemoteKit and JSON.stringify write it, with exactly `fields`, in
 * that order. Written any other way (white space, a key twice, a number written otherwise, anything after it), it is
 * refused: the text read is the text signed.
 */
export function readSigned(text: unknown, fields: readonly string[]): Record<string, unknown> | null {
	if (typeof text !== "string" || text.length > 16 * 1024) return null;
	let value: unknown;
	try {
		value = JSON.parse(text);
	} catch {
		return null;
	}
	if (typeof value !== "object" || value === null || Array.isArray(value) || JSON.stringify(value) !== text) return null;
	const keys = Object.keys(value);
	return keys.length === fields.length && keys.every((key, index) => key === fields[index]) ? (value as Record<string, unknown>) : null;
}

/** Whether `value` is a plain object with exactly the keys `required`, and perhaps some of `optional`. */
function exactly(value: unknown, required: readonly string[], optional: readonly string[] = []): value is Record<string, unknown> {
	if (typeof value !== "object" || value === null || Array.isArray(value)) return false;
	const keys = Object.keys(value);
	return required.every((key) => keys.includes(key)) && keys.every((key) => required.includes(key) || optional.includes(key));
}

/** A short text a person gave: a name, a model, a system. */
const plainText = (value: unknown, max: number): value is string =>
	typeof value === "string" && value.length > 0 && Buffer.byteLength(value) <= max && !/[\u0000-\u001f\u007f]/.test(value);

/** A build number, as CFBundleVersion has it: numbers and dots. */
const buildText = (value: unknown): value is string => typeof value === "string" && /^[0-9]{1,9}(\.[0-9]{1,9}){0,3}$/.test(value);

/** Whether build `a` is at least `b`, part by part. */
export function buildAtLeast(a: string, b: string): boolean {
	const x = a.split(".").map(Number);
	const y = b.split(".").map(Number);
	for (let i = 0; i < Math.max(x.length, y.length); i++) {
		const [p, q] = [x[i] ?? 0, y[i] ?? 0];
		if (p !== q) return p > q;
	}
	return true;
}

/** The SHA-256 of a public key's text, in base64url: what a revoked device's record keeps of its device key. */
const keyHash = (key: string) => createHash("sha256").update(key, "utf8").digest("base64url");

/** HMAC-SHA256 keyed with `secret` over a label, a zero byte and what it is bound to (RemoteKit's PairingSecrets). */
function pairingMac(secret: Buffer, label: string, bound: Buffer): Buffer {
	return createHmac("sha256", secret).update(Buffer.concat([Buffer.from(label, "utf8"), Buffer.from([0]), bound])).digest();
}

/** The six digits the phone shows (3.3 step 7). */
export function pairingDigits(secret: Buffer, binding: Buffer): string {
	return String(pairingMac(secret, "pi2-digits", binding).readUInt32BE(0) % 1_000_000).padStart(6, "0");
}

/** What the relay is given for a join window: SHA-256 of the join token (3.3 step 2). */
export function joinTokenHash(secret: Buffer, pairing: string): string {
	return createHash("sha256").update(pairingMac(secret, "pi2-join", Buffer.from(pairing, "utf8"))).digest("base64url");
}

// ---- What is never written down: keys (5.7)

// The shapes of secrets that are often pasted or printed: providers' and services' API keys and tokens, and private
// keys in PEM. Masked in every string a device is sent (remote.ts walks each line's decoded value, so a key after a
// line break, a tab or a colour code is a key like any other) and in the devices' log. A key of another shape is not
// caught: the events carry no secret of the person's settings (5.7, engine/test/devices.ts).
//
// Each shape is found by its prefix and a fixed least number of its characters, and its run of characters is then
// followed by hand to its end: no pattern has an open quantifier, so no input, however long, makes the matcher
// backtrack through it (a greedy `{20,}` over megabytes overflowed V8's stack), and the whole run is hidden, never only
// its first part.

type Run = (code: number) => boolean;
const upper: Run = (c) => c >= 65 && c <= 90;
const digit: Run = (c) => c >= 48 && c <= 57;
const ALNUM: Run = (c) => upper(c) || digit(c) || (c >= 97 && c <= 122);
const TOKEN: Run = (c) => ALNUM(c) || c === 95 || c === 45;
/** At the start of a word, or after a colour code: for prefixes some word could end with. */
const WORD_START = String.raw`(?:(?<![A-Za-z0-9_-])|(?<=\u001b\[[0-9;]{0,16}m))`;
/**
 * Where a key's prefix at a text's very end counts (#997): at the text's start, after a character that is no letter,
 * digit or underscore, or after a colour code.
 */
const END_WORD_START = /(?:(?<![A-Za-z0-9_])|(?<=\u001b\[[0-9;]{0,16}m))/y;
/** `keep`: the prefix is shown, and only the run after it hidden (a webhook's address, whose secret is its path). */
const KEY_SHAPES: { start: RegExp; run: Run; least: number; keep?: true }[] = [
	// Prefixes no word has: wherever they stand, after a letter, a colour code or anything else.
	{ start: /sk-ant-/g, run: TOKEN, least: 16 },
	{ start: /gsk_/g, run: ALNUM, least: 20 },
	{ start: /xai-/g, run: ALNUM, least: 20 },
	{ start: /whsec_/g, run: (c) => ALNUM(c) || c === 43 || c === 47 || c === 61, least: 20 },
	{ start: /(?:sk|rk)_test_/g, run: ALNUM, least: 20 },
	{ start: /ya29\./g, run: TOKEN, least: 20 },
	{ start: /https:\/\/hooks\.slack\.com\/services\//g, run: (c) => TOKEN(c) || c === 47, least: 10, keep: true },
	{ start: /sk-(?:proj|svcacct|or-v1)-/g, run: TOKEN, least: 16 },
	{ start: /gh[pousr]_/g, run: ALNUM, least: 30 },
	{ start: /github_pat_/g, run: (c) => ALNUM(c) || c === 95, least: 30 },
	{ start: /glpat-/g, run: TOKEN, least: 20 },
	{ start: /xox[abposr]-/g, run: (c) => ALNUM(c) || c === 45, least: 10 },
	// An AWS access key id: AKIA (long-lived) or ASIA (temporary) and 16 upper-case letters and digits, starting a word.
	{ start: new RegExp(`${WORD_START}(?:AKIA|ASIA)`, "g"), run: (c) => upper(c) || digit(c), least: 16 },
	{ start: /AIza/g, run: TOKEN, least: 35 },
	{ start: /hf_/g, run: ALNUM, least: 30 },
	{ start: /(?:sk|rk|pk)_live_/g, run: ALNUM, least: 20 },
	{ start: /npm_/g, run: ALNUM, least: 36 },
	// `sk-` alone ends words ("desk-"), so it must start one, or follow a colour code.
	{ start: new RegExp(`${WORD_START}sk-`, "g"), run: TOKEN, least: 20 },
];
// Not caught: JSON web tokens (`eyJ…`), of which most a transcript shows are harmless (an id token's claims, a test's
// fixture), and whose prefix is only base64 of `{"`.
const PEM_BEGIN = /-----BEGIN [A-Z ]{0,40}PRIVATE KEY-----/g;
const PEM_END = /-----END [A-Z ]{0,40}PRIVATE KEY-----/y;
export const KEY_HIDDEN = "[key hidden]";

/**
 * `text` with every key-shaped string in it replaced by KEY_HIDDEN, and every value of a secret the engine knows
 * (secrets.ts: agents' and MCP servers' variables, providers' keys and tokens) by SECRET_HIDDEN. Where the two overlap,
 * the run they cover together is replaced once, by the mark of the one that starts first.
 */
export function maskKeys(text: string): string {
	return maskKeysFrom(text, 0);
}

/**
 * `text` from character `from` on, masked as `maskKeys` masks the whole of it: what is hidden is found in the whole text
 * and only then cut, so that a key or a value that begins before `from` is hidden in the part after it too (a
 * background command's output read from an offset a phone chooses, #894). A run hidden across `from` starts the part
 * with its mark.
 */
export function maskKeysFrom(text: string, from: number): string {
	const spans: [number, number, string][] = [];
	for (const { start, run, least, keep } of KEY_SHAPES) {
		start.lastIndex = 0;
		for (let found = start.exec(text); found !== null; found = start.exec(text)) {
			const after = found.index + found[0].length;
			let end = after;
			while (end < text.length && run(text.charCodeAt(end))) end++;
			// A text that ends partway into a key, its prefix and fewer characters than make one (#997): hidden to its end too,
			// so that an answer or an output still coming shows no part of a key before the rest arrives (#965's read: 29 of a
			// `ghp_` key's 36). Only at the text's very end, and only for a prefix that starts a word (`risk_test_` is a word's
			// end, not a key); a text that ends in a prefix alone ("sk-") shows the mark for it.
			END_WORD_START.lastIndex = found.index;
			const cutShort = end === text.length && (keep !== true || end > after) && END_WORD_START.test(text);
			if (end - after >= least || cutShort) spans.push([keep === true ? after : found.index, end, KEY_HIDDEN]);
			start.lastIndex = Math.max(end, found.index + 1);
		}
	}
	// A private key: its header, then only a body that is a key's, lines of base64 of 16 characters or more with white
	// space between, and the end line with it when it follows directly. The first character that cannot be a key's ends
	// it, so a header standing in a command hides nothing of the command around it.
	const base64: Run = (c) => ALNUM(c) || c === 43 || c === 47 || c === 61;
	const space: Run = (c) => c === 32 || c === 9 || c === 10 || c === 13;
	PEM_BEGIN.lastIndex = 0;
	for (let found = PEM_BEGIN.exec(text); found !== null; found = PEM_BEGIN.exec(text)) {
		let end = found.index + found[0].length;
		for (;;) {
			let from = end;
			while (from < text.length && space(text.charCodeAt(from))) from++;
			PEM_END.lastIndex = from;
			if (PEM_END.test(text)) {
				end = PEM_END.lastIndex;
				break;
			}
			let to = from;
			while (to < text.length && base64(text.charCodeAt(to))) to++;
			if (to - from < 16) break;
			end = to;
		}
		spans.push([found.index, end, KEY_HIDDEN]);
		PEM_BEGIN.lastIndex = end;
	}
	for (const [from, to] of secretSpans(text)) spans.push([from, to, SECRET_HIDDEN]);
	if (spans.length === 0) return from === 0 ? text : text.slice(from);
	// By where each starts; a key's shape before a known value at the same place (`sort` keeps the order of equals).
	spans.sort((a, b) => a[0] - b[0]);
	// Runs that overlap made one, marked as the first; runs that only touch keep a mark each.
	const runs: [number, number, string][] = [];
	for (const [start, end, mark] of spans) {
		const last = runs[runs.length - 1];
		if (last !== undefined && start < last[1]) last[1] = Math.max(last[1], end);
		else runs.push([start, end, mark]);
	}
	let out = "";
	let at = from;
	for (const [start, end, mark] of runs) {
		if (end <= from) continue;
		out += (start < from ? "" : text.slice(at, start)) + mark;
		at = end;
	}
	return out + text.slice(at);
}

/** What stands in a device's copy for a value nested deeper than it is walked. */
export const TOO_DEEP = "[too deep to show]";
const MAX_DEPTH = 256;
/**
 * The depth an approval is walked from, wherever it sits: a line a device is sent puts one 2 levels down (the `inbox`
 * and `needs` events) or 3 (`needs.list`'s answer), and the engine's own record of one, which the gate judges
 * (`hidesSomething`), has it at 0. Counting each from here, never from where it sits, cuts the phone's copy exactly
 * where the gate judges it cut. 8 leaves room for a form that nests one deeper; an approval sent deeper than 8 would be
 * cut sooner than the gate judges, so the devices test holds the forms a phone answers from (the `inbox` event,
 * `needs.list`'s answer) to the gate's cut at every depth either side of it, and a development engine says so when it
 * meets one deeper in any line (`deepApproval`), so that a new form cannot quietly reopen that gap (#881).
 */
export const APPROVAL_DEPTH = 8;
/** When a development engine last said it met an approval deeper than APPROVAL_DEPTH: at most once a minute. */
let deepSaid = 0;

/**
 * An approval met `depth` levels down in a line for a device, deeper than APPROVAL_DEPTH, and not inside another
 * approval: a form the gate's judgement does not match. A release engine says nothing (the phone's copy is still
 * masked, and marked if cut); a development engine says it in engine.log, and under test
 * (`PI2_APPROVAL_DEPTH_THROWS`) throws, which drops the line (`forDevice`), so that the test meets it.
 */
function deepApproval(depth: number): void {
	if (releaseEngine) return;
	const said = `an approval was met ${depth} levels down in a line for a device, deeper than APPROVAL_DEPTH (${APPROVAL_DEPTH}): the phone's copy is cut sooner than the gate judges (devices.ts)`;
	if (testSwitch("PI2_APPROVAL_DEPTH_THROWS") === "1") throw new Error(said);
	const now = Date.now();
	if (now - deepSaid < 60_000) return;
	deepSaid = now;
	log?.(`devices: ${said}`);
}
/**
 * Set beside an approval a device is sent when masking hid part of it, or part was too deep: the phone does not show
 * the whole call, and the engine takes no allowing answer to it from a device (`approvalHidden`, answers.ts).
 */
export const PART_HIDDEN = "partHidden";

/**
 * `value`, a decoded JSON value, with every string in it masked, the keys of its objects included, and what is nested
 * deeper than 256 levels replaced by TOO_DEEP, an approval's insides counted from APPROVAL_DEPTH. Masking the strings
 * rather than the JSON text is what makes it hold: in the text a key after a line break follows `\n`, and one after a
 * colour code follows `\u001b[32m`. `masking.hidden` is set when anything was hidden; an approval (an object of kind
 * "approval" with an id) also gets PART_HIDDEN. `inApproval`: walking an approval's insides, where another approval
 * is judged with it, by the gate as here.
 */
export function maskValue(value: unknown, masking: { hidden: boolean } = { hidden: false }, depth = 0, inApproval = false): unknown {
	if (typeof value === "string") {
		const masked = maskKeys(value);
		if (masked !== value) masking.hidden = true;
		return masked;
	}
	if (typeof value !== "object" || value === null) return value;
	if (depth >= MAX_DEPTH) {
		masking.hidden = true;
		return TOO_DEEP;
	}
	if (Array.isArray(value)) return value.map((item) => maskValue(item, masking, depth + 1, inApproval));
	const record = value as Record<string, unknown>;
	const approval = record.kind === "approval" && typeof record.id === "string";
	if (approval && !inApproval && depth > APPROVAL_DEPTH) deepApproval(depth);
	const own = approval ? { hidden: false } : masking;
	// Only ever deeper, so a line is never walked past MAX_DEPTH.
	const at = approval ? Math.max(depth, APPROVAL_DEPTH) : depth;
	// No prototype: a key `__proto__` stays a key.
	const out: Record<string, unknown> = Object.create(null);
	for (const [key, item] of Object.entries(record)) {
		const name = maskKeys(key);
		if (name !== key) own.hidden = true;
		out[name] = maskValue(item, own, at + 1, inApproval || approval);
	}
	if (approval && own.hidden) {
		out[PART_HIDDEN] = true;
		masking.hidden = true;
	}
	return out;
}

/** Whether a device's copy of `value` would hide anything of it: then a device may not allow it (answers.ts). */
export function hidesSomething(value: unknown): boolean {
	const masking = { hidden: false };
	try {
		maskValue(value, masking);
	} catch {
		return true;
	}
	return masking.hidden;
}

// ---- The devices' log (4.4)

type Params = Record<string, unknown>;

/**
 * `PI2_DEVICE_FAULT`, a test switch: the method whose log line, and whose handling from a device's line or a mailbox
 * item, throw before the request's own `try` (remote.ts), so that engine/test/devices.ts can show that neither ends the
 * engine.
 */
export const DEVICE_FAULT = testSwitch("PI2_DEVICE_FAULT");

/**
 * `PI2_DEVICE_FAULT_AFTER`, a test switch: the method whose answer goes out and whose step after it throws (remote.ts),
 * so that engine/test/devices.ts can show that a device gets one answer per request id and the log says the request was
 * answered (#905). A request of that method asked with the id "after-answer" meets it.
 */
export const DEVICE_FAULT_AFTER = testSwitch("PI2_DEVICE_FAULT_AFTER");

/**
 * A line for the log saying what a request did (`summaryLine`), or, should that fail, the method's name alone. It never
 * throws: a device chooses every parameter it reads, and it runs before the request's own `try` (remote.ts), where a
 * throw would end the engine.
 */
export function summarize(given: string, params: Params): string {
	try {
		return summaryLine(given, params);
	} catch {
		return loggedMethod(given);
	}
}

/**
 * A line for the log saying what a request did, by its method and parameters: the conversation or project it names, by
 * name. An issue that lets a device send a new request adds its line here (12.1). Never the text of a message, which
 * may hold anything.
 */
function summaryLine(given: string, params: Params): string {
	const method = loggedMethod(given);
	if (DEVICE_FAULT !== undefined && method === DEVICE_FAULT) throw new Error("PI2_DEVICE_FAULT: the log line");
	const title = typeof params.id === "number" ? names?.conversation(params.id) : undefined;
	const project = typeof params.projectId === "string" ? names?.project(params.projectId) : undefined;
	// A conversation not named yet has an empty title: it is left out, as one not found is.
	const inConversation = title === undefined || title === "" ? "" : ` in “${title}”`;
	const inProject = project === undefined || project === "" ? "" : ` (${project})`;
	const lines: Record<string, () => string> = {
		submit: () => `Sent a message${inConversation}`,
		continue: () => `Continued${inConversation}`,
		abort: () => `Stopped${inConversation}`,
		withdraw: () => `Took back a message${inConversation}`,
		"conversation.create": () => `Started a conversation${params.confirmLimit !== undefined ? " past a limit" : ""}`,
		"conversation.export": () => `Exported${inConversation}`,
		"conversation.rename": () => `Renamed a conversation to “${said(params.title ?? "")}”`,
		"conversation.delete": () => `Deleted${inConversation}`,
		"conversation.configure": () => `Changed the settings of${inConversation || " a conversation"}`,
		"inbox.decide": () => `Answered an approval: ${["once", "always", "rule", "deny"].includes(params.decision as string) ? String(params.decision) : "?"}`,
		"inbox.answer": () => "Answered a question",
		"needs.answer": () => `Answered under Needs you${inProject}`,
		"agents.allowEverything": () => `Turned Allow everything ${params.on === true ? "on" : "off"}`,
		"agents.save": () => "Changed an agent's settings",
		"github.merge": () => `Merged #${said(params.number)}${inProject}`,
		"github.settle": () => `Marked a write ${params.happened === true ? "done" : "not done"}${inProject}`,
		"work.act": () => `${clip(said(params.action ?? "Acted on"), 24)} work #${clip(said(params.id), 12)}${inProject}`,
		"devices.forgetSelf": () => "Unpaired itself",
		"devices.acceptPresenceKey": () => "Its new Face ID key was accepted on the Mac",
		"devices.refusePresenceKey": () => "Its new Face ID key was refused on the Mac",
		presenceKey: () => "Offered a new Face ID key",
		"pushes.set": () => {
			const switches = (["needs", "limits", "answers"] as const).filter((key) => typeof params[key] === "boolean").map((key) => `${key} ${params[key] === true ? "on" : "off"}`);
			// Whatever the device sent: null or a string is read as an object with nothing in it.
			const chosen = typeof params.project === "object" && params.project !== null ? (params.project as Params) : {};
			const name = typeof chosen.id === "string" ? names?.project(chosen.id) : undefined;
			const quieted = params.project === undefined ? [] : [`${chosen.quiet === true ? "quieted" : "unquieted"} ${name === undefined || name === "" ? "a project" : `“${name}”`}`];
			return `Notifications: ${[...switches, ...quieted].join(", ") || "read"}`;
		},
		"pushes.follow": () => `${params.on === true ? "Followed" : "Stopped following"}${inProject || " a project"} in a Live Activity`,
		// #698: the folders offered for a new project, a project made from one, and a file shown on the phone, by its name.
		"projects.folders": () => "Asked for the folders offered for a new project",
		"projects.create": () => `Made a project ${typeof params.folder === "string" ? `from the folder “${clip(params.folder.split("/").filter(Boolean).at(-1) ?? params.folder, 60)}”` : "with no folder"}${params.template != null ? " and a copy of a template" : ""}`,
		"files.preview": () => `Showed the file “${previewedPath(params.path)}”${inConversation}`,
		pair: () => "Paired",
		attach: () => "Attached",
		resume: () => "Resumed",
		suspend: () => "Suspended",
		leave: () => "Unpaired itself on the phone",
	};
	return clip(maskKeys(unhidden(lines[method]?.() ?? `${method}${inConversation}${inProject}`)), MAX_SUMMARY);
}

/**
 * What a text shows as nothing, or as something other than what is there, in the devices' log and in a push (pushes.ts):
 * one set for both (#997), so that neither lets through what the other takes out. Every control character; every
 * format character (`Cf`: a right-to-left override or another bidirectional control, which could make a path a phone
 * sent read as another, U+202E then "txt.md" showing "dm.txt"; zero-width characters, U+00AD, U+061C, U+2060 to U+2064,
 * the tag characters); the line and paragraph separators; every default-ignorable code point (variation selectors,
 * U+034F, the Hangul fillers); and half a character.
 */
const NOT_SHOWN_IN_TEXT = /[\p{Cc}\p{Cf}\p{Cs}\p{Zl}\p{Zp}\p{Default_Ignorable_Code_Point}]/gu;
const CONTROL = /^\p{Cc}$/u;

/**
 * `text` with nothing in it that would show other than as it reads (#902, #997), before the masks, so that nothing
 * invisible can split a key out of their sight: NOT_SHOWN_IN_TEXT taken out, but what breaks a line. On one line
 * (`"spaces"`, the log's), every control character, a line break among them, and a line or paragraph separator is a
 * space. With its lines (`"kept"`, a push's), a line break stays, a line or paragraph separator is one, a tab is a
 * space, and every other control character is taken out; so that two lines never read as one word.
 */
export function unhidden(text: string, lines: "spaces" | "kept" = "spaces"): string {
	return text.replace(NOT_SHOWN_IN_TEXT, (found) => {
		if (found === "\n" || found === "\u2028" || found === "\u2029") return lines === "kept" ? "\n" : " ";
		if (found === "\t") return " ";
		return lines === "spaces" && CONTROL.test(found) ? " " : "";
	});
}

/** A value a device gave, as words: an object or an array as "?", since `String` of one can throw (`{"toString": 1}`). */
const said = (value: unknown) => (typeof value === "object" && value !== null ? "?" : String(value));
/**
 * The file `files.preview` names, for the log (#698): as the link named it, which is its path relative to the
 * conversation's folder for a relative link (`./` and `..` worked out), or its whole path with the home folder as `~`;
 * at most 120 characters, the end kept.
 */
function previewedPath(path: unknown): string {
	if (typeof path !== "string" || path.trim() === "") return "?";
	let text = path.trim().replace(/^file:\/\/(?:localhost)?/i, "");
	const home = homedir();
	if (home.length > 1 && text.startsWith(`${home}/`)) text = `~${text.slice(home.length)}`;
	const names: string[] = [];
	for (const name of text.split("/")) {
		if (name === "" || name === ".") continue;
		if (name === ".." && names.length > 0 && names.at(-1) !== "..") names.pop();
		else names.push(name);
	}
	const shown = `${text.startsWith("/") ? "/" : ""}${names.join("/")}`;
	return shown.length <= 120 ? shown : `…${shown.slice(shown.length - 119)}`;
}

/** At most `max` characters of `text`, with an ellipsis where it was cut. */
const clip = (text: string, max: number) => (text.length <= max ? text : `${text.slice(0, max - 1)}…`);

/** What the log may name, beside the requests the device lists place. */
const LOG_OWN = new Set(["pair", "attach", "resume", "suspend", "presenceKey", "leave", "unknown"]);
/**
 * The entries one device's flood cannot push out: they stay their 90 days. A new Face ID key's offer and the person's
 * answer to it among them: one key waits at a time, so there are never many.
 */
const LOG_KEPT = new Set(["pair", "suspend", "presenceKey", "devices.acceptPresenceKey", "devices.refusePresenceKey"]);
const MAX_METHOD = 64;
const MAX_SUMMARY = 200;
const MAX_WHY = 200;
/**
 * Each device's share of the log, so that one device cannot push out another's entries (5 devices, 10,000 in all). Of
 * it, what was done and what was refused or failed each keep their newest half whatever the other does (#997).
 */
const MAX_PER_DEVICE = MAX_LOG / MAX_DEVICES;
/** Refusals or failures alike (`mergedBy`), from the same device and path, within this of the first, are one entry. */
const COALESCE_MS = 60_000;

/**
 * What makes a refusal or a failure one with another, for the log's merging (#997): the device, the path, the method,
 * the outcome and the summary as stored (cleaned and masked), so that only the same request about the same thing (the
 * same file, the same title, the same conversation) merges and a merged entry never reads as tries of something the
 * phone did not ask for (#1015's security read); and for a refusal the words of its why before the first number in
 * them. A refusal's words are the engine's own sentences, and one that carries a size (#924, #940: "this one has
 * 1.2 MB", "… 20,001 characters") is the same refusal whatever the size; a failure's are its handler's, which can
 * repeat what the phone sent, so the failures of one request about one thing are alike whatever they say. What was done
 * is never merged. Requests about other things are not merged: the split of a device's share bounds them.
 */
function mergedBy(entry: DeviceLogEntry): string | undefined {
	if (entry.outcome === "done") return undefined;
	const kind = entry.outcome === "failed" ? null : (entry.why ?? "").replace(/[0-9][\s\S]*$/, "");
	return JSON.stringify([entry.device, entry.path, entry.method, entry.outcome, entry.summary, kind]);
}

/** How long new entries wait in memory before they are written together. */
const FLUSH_MS = 2_000;
/** Entries made and not yet written: the next write takes them all, at most FLUSH_MS after the first. */
const pendingLog: DeviceLogEntry[] = [];
/**
 * The refusal and failure entries made this last minute, by `mergedBy`, with how many like them came since and are not
 * yet written. While its entry waits in `pendingLog`, a repeat adds to the entry itself.
 */
const refusalsMade = new Map<string, { entry: DeviceLogEntry; more: number; lastAt: number }>();
/**
 * Records whose key has moved on to a new entry while they still held `more`: their counts are owed a write, and the
 * next write takes them (#1063). At most one for a key stands at a time: a record is moved here only when its minute
 * is over, so two of one key are at least `COALESCE_MS` apart, and a write comes at most `FLUSH_MS` after the new
 * entry that moved the first — and empties this as it writes.
 */
const refusalsOwed: { entry: DeviceLogEntry; more: number; lastAt: number }[] = [];
let flushTimer: ReturnType<typeof setTimeout> | undefined;
let flushing: Promise<void> = Promise.resolve();

/**
 * Writes what waits in memory, in one commit, after any write already under way. `alongside`, a change to the record
 * of devices made in the same commit, so that neither is stored without the other (a suspension and its entry).
 */
export function flushDeviceLog(alongside?: (doc: DevicesState) => void): Promise<void> {
	clearTimeout(flushTimer);
	flushTimer = undefined;
	const write = () => writePending(alongside);
	flushing = flushing.then(write, write);
	return flushing;
}

async function writePending(alongside?: (doc: DevicesState) => void): Promise<void> {
	const entries = pendingLog.splice(0);
	const counts = [...refusalsMade.values(), ...refusalsOwed.splice(0)].filter((one) => one.more > 0 && !entries.includes(one.entry)).map((one) => ({ ...one }));
	for (const one of refusalsMade.values()) if (!entries.includes(one.entry)) one.more = 0;
	if (entries.length === 0 && counts.length === 0 && alongside === undefined) return;
	const now = Date.now();
	await harness.commit(async (tx) => {
		if (alongside !== undefined) alongside(await tx.doc(Devices));
		const doc = await tx.doc(DeviceLog);
		for (const { entry, more, lastAt } of counts) {
			const stored = doc.entries.findLast((one) => one.at === entry.at && one.device === entry.device && one.path === entry.path && one.method === entry.method && one.summary === entry.summary && one.why === entry.why && one.outcome === entry.outcome);
			if (stored === undefined) continue;
			stored.count = (stored.count ?? 1) + more;
			stored.lastAt = lastAt;
		}
		let kept = [...doc.entries, ...entries].filter((one) => now - (one.lastAt ?? one.at) < KEPT);
		for (const device of new Set(entries.map((one) => one.device))) {
			// Only what the engine itself did is kept past the share: a device's own refused requests, under any name, are in it.
			const mine = kept.filter((one) => one.device === device && !(LOG_KEPT.has(one.method) && one.outcome === "done"));
			if (mine.length <= MAX_PER_DEVICE) continue;
			// Of what is over, the side (done, or refused and failed) past its half gives up its oldest first, so that no
			// flood of refusals or failures, of any request in any words, pushes out what the device did, nor the reverse (#997).
			let over = mine.length - MAX_PER_DEVICE;
			const dropped = new Set<DeviceLogEntry>();
			for (const done of [false, true]) {
				const side = mine.filter((one) => (one.outcome === "done") === done);
				const given = Math.min(over, Math.max(0, side.length - MAX_PER_DEVICE / 2));
				for (const one of side.slice(0, given)) dropped.add(one);
				over -= given;
			}
			kept = kept.filter((one) => !dropped.has(one));
		}
		// Past every device's share (a device removed after 90 days leaves its entries to theirs), the oldest go first.
		doc.entries = kept.length > MAX_LOG ? kept.slice(kept.length - MAX_LOG) : kept;
	}, context);
}

/** A method as the log names it: a request the lists place, or one of the log's own; anything else is "unknown". */
function loggedMethod(method: string): string {
	return method.length <= MAX_METHOD && (LOG_OWN.has(method) || devicePlacement(method) !== null) ? method : "unknown";
}

/**
 * A method a device named in a request, as the log names it: the log's own names (a pairing, an attach, an offer of a
 * Face ID key) are the engine's to write, for what it did, so a device's request under one of them is "unknown" (#786).
 */
export function requestLogged(method: string): string {
	return LOG_OWN.has(method) ? "unknown" : method;
}

/**
 * Adds an entry to the devices' log: its method one the engine knows, its summary and why cleaned (`unhidden`), masked
 * and cut short, here whoever made them, so that no line skips it (#997). Each device keeps its own newest 2,000
 * entries, so that no device pushes out another's, and its pairing and suspension stay their 90 days; of them, its
 * newest 1,000 done and its newest 1,000 refused or failed, whatever the other side does.
 *
 * Off the request's path: a commit rewrites the whole log (some 6 MB full) and holds the engine's one thread while it
 * does, so entries wait in memory and are written together at most two seconds after the first. `urgent` writes them
 * at once, and resolves once they are stored: for what must outlive a crash (a pairing, a suspension and the refusal
 * that made it, a request that widens). A clean stop writes what waits (`flushDeviceLog`). A refusal or a failure like
 * one of the device's from the last minute, about the same thing (`mergedBy`), adds to that entry's `count` and `lastAt`
 * instead of making one; the entry keeps the first one's words.
 */
export async function logDevice(entry: Omit<DeviceLogEntry, "at"> & { at?: number }, urgent = false): Promise<void> {
	if (unreadable !== null) return;
	const at = entry.at ?? Date.now();
	const method = loggedMethod(entry.method);
	const why = entry.why === undefined ? undefined : clip(maskKeys(unhidden(entry.why)), MAX_WHY);
	const made: DeviceLogEntry = { ...entry, at, method, summary: clip(maskKeys(unhidden(entry.summary)), MAX_SUMMARY), ...(why === undefined ? {} : { why }) };
	const key = mergedBy(made);
	const known = key === undefined ? undefined : refusalsMade.get(key);
	if (known !== undefined && at - known.entry.at < COALESCE_MS) {
		if (pendingLog.includes(known.entry)) {
			known.entry.count = (known.entry.count ?? 1) + 1;
			known.entry.lastAt = at;
		} else {
			known.more += 1;
			known.lastAt = at;
		}
	} else {
		if (key !== undefined) {
			for (const [old, one] of refusalsMade) if (at - one.entry.at >= COALESCE_MS && one.more === 0) refusalsMade.delete(old);
			const previous = refusalsMade.get(key);
			if (previous !== undefined && previous.more > 0) {
				// The record this replaces holds counts not written yet (#1063): onto its entry if that still waits, or it
				// is owed a write, never dropped.
				if (pendingLog.includes(previous.entry)) {
					previous.entry.count = (previous.entry.count ?? 1) + previous.more;
					previous.entry.lastAt = previous.lastAt;
				} else refusalsOwed.push(previous);
			}
			refusalsMade.set(key, { entry: made, more: 0, lastAt: at });
		}
		pendingLog.push(made);
	}
	if (urgent) return flushDeviceLog();
	if (flushTimer === undefined) {
		flushTimer = setTimeout(() => void flushDeviceLog().catch((error) => log("devices: the log could not be written:", error instanceof Error ? error.message : error)), FLUSH_MS);
		flushTimer.unref();
	}
}

/** The log as the Devices page and a device read it: what is stored and what waits in memory, together. */
async function logEntries(device: string | null, before: number | undefined, count = 200): Promise<DeviceLogEntry[]> {
	const stored = ((await harness.snapshot(DeviceLog, context))?.entries ?? []).map((entry) => ({ ...entry }));
	for (const one of [...refusalsMade.values(), ...refusalsOwed]) {
		if (one.more === 0) continue;
		const entry = stored.findLast((e) => e.at === one.entry.at && e.device === one.entry.device && e.path === one.entry.path && e.method === one.entry.method && e.summary === one.entry.summary && e.why === one.entry.why && e.outcome === one.entry.outcome);
		if (entry === undefined) continue;
		entry.count = (entry.count ?? 1) + one.more;
		entry.lastAt = one.lastAt;
	}
	const entries = [...stored, ...pendingLog.map((entry) => ({ ...entry }))];
	return entries.filter((entry) => (device === null || entry.device === device) && (before === undefined || entry.at < before)).slice(-count).reverse();
}

// ---- What the person at the Mac is told (4.4)

type Notice = { kind: "claim" | "paired" | "widening" | "suspended" | "presenceKey"; device: string | null; text: string; at: number };

/** The connections the engine took for the app that asked for the `devices` event: the app's alone (3.3). */
const watchers = new Set<Client>();
let window: PairingWindow | null = null;
let closed: { why: string; at: number } | null = null;

/**
 * The relay refused a Live Activity push for this Mac's clock, or no longer does (#915): the Devices page is told, once
 * for each, and not at every refusal a minute apart.
 */
export function pushClockChanged(wrong: boolean): void {
	if (pushClockWrong === wrong) return;
	pushClockWrong = wrong;
	announce();
}

/** The `devices` event: everything the Devices page shows, and, when there is one, what the Mac should notify of. */
export function devicesEvent(notice?: Notice) {
	const claim = window?.claim ?? null;
	return {
		event: "devices",
		/** Why the stored record could not be read, and so no device can pair or connect; null when it was read. */
		unreadable,
		remote: state.remote,
		relay: state.relay,
		macName: macName(),
		pairing: state.pairing,
		macKeys: state.macKeys,
		helper: remoteHooks.helper(),
		/** Where this Mac's pairing is registered beside the relay now set (#917, #1013): what the page offers by. */
		pairingRegistered: pairingRegisteredNow(),
		/** The relay refused a Live Activity push for this Mac's clock, until one of its own goes unanswered (#915). */
		...(pushClockWrong ? { pushClock: true as const } : {}),
		devices: state.devices,
		sessions: remoteHooks.sessions(),
		pairingWindow:
			window === null
				? null
				: {
						expires: window.expires,
						claim: claim === null ? null : { name: claim.device.name, model: claim.device.model, system: claim.device.system, path: claim.path, at: claim.at, replaces: claim.replaces, wrongDigits: claim.wrongDigits },
					},
		closed,
		...(notice === undefined ? {} : { notice }),
	};
}

function announce(notice?: Notice): void {
	if (watchers.size === 0) return;
	const line = `${JSON.stringify(devicesEvent(notice))}\n`;
	for (const client of watchers) {
		if (client.socket.destroyed) watchers.delete(client);
		else client.socket.write(line);
	}
}

/** A connection that went: it is sent nothing more. */
export function devicesClientGone(client: Client): void {
	watchers.delete(client);
}

/** Tells the person at the Mac: an event the app turns into a notification. */
export function notify(kind: Notice["kind"], device: string | null, text: string): void {
	announce({ kind, device, text: maskKeys(text), at: Date.now() });
}

/** Sessions opened, moved or closed: the Devices page and the menu bar say who is attached (4.4). */
export function sessionsChanged(): void {
	announce();
}

/** The Mac's name, as the pairing payload and a device are told it. */
/**
 * The characters a phone does not show in a name (RemoteKit's `ShownText`): controls, and the invisible and
 * direction-changing ones, U+200B to U+200F, U+202A to U+202E, U+2066 to U+2069 and U+FEFF. RemoteKit refuses a pairing
 * payload or a `paired` line whose name holds one; the engine strips them instead, so that a Mac named with an emoji
 * sequence (a zero-width joiner) or a right-to-left mark can still pair. And lone surrogates, half a character, which
 * a Swift string cannot hold, and which JSON carries as an escape: a claim's name, model and system are stripped of
 * the same before the Mac shows them (#881).
 */
const NOT_SHOWN = /[\p{Cc}\p{Cs}\u200B-\u200F\u202A-\u202E\u2066-\u2069\uFEFF]/gu;
/** The longest name RemoteKit takes, in UTF-8 bytes (`PairingPayload.maxNameLength`). */
export const MAX_NAME_BYTES = 128;

/** `text` as a phone may show it: those characters taken out, cut to 128 bytes between characters, trimmed; or `fallback`. */
export function shownName(text: string, fallback: string): string {
	let out = "";
	let bytes = 0;
	for (const character of text.replace(NOT_SHOWN, "").trim()) {
		bytes += Buffer.byteLength(character);
		if (bytes > MAX_NAME_BYTES) break;
		out += character;
	}
	out = out.trim();
	return out === "" ? fallback : out;
}

/** The Mac's name, as the pairing payload, `paired` and a device's `device` event give it: one a phone shows. */
export const macNameNow = () => shownName(state.macName || hostname().replace(/\.local$/, ""), "Mac");
const macName = macNameNow;

// ---- Pairing (3.1, 3.3)

type ClaimedDevice = { name: string; model: string; system: string; build: string; deviceKey: string; presenceKey: string; channelKey: string; recordKey: string };
type Claim = { id: string; at: number; path: "relay" | "home"; device: ClaimedDevice; attestKeyId: string; digits: string; wrongDigits: number; replaces: string | null };
type PairingWindow = { secret: Buffer; pairing: string; expires: number; claiming: boolean; claim: Claim | null; wrongTries: number; timer: ReturnType<typeof setTimeout> };

/**
 * The device the engine's last pairing saved, the path its claim came by, and the device it replaced, if any: the one
 * `pairUnkept` may take back.
 */
let lastPaired: { device: string; path: "relay" | "home"; replaced: string | null } | null = null;

export const SECOND_CLAIM = "Another device tried to use this code. Start again, and don't show the code on a shared or recorded screen.";
const NO_WINDOW = "No pairing is open on this Mac.";

/**
 * Why a claim was refused, in a word the phone is told (`pairRefused` on the pairing channel, docs/remotekit.md, #881):
 * `unsaved`, the Mac could not save the pairing; `cancelled`, the person closed the pairing on the Mac. pi² Remote
 * passes the word on and never the engine's words; any other refusal carries none, and the phone is told nothing.
 */
export type PairRefusalWord = "unsaved" | "cancelled";

/** Closes the join window, for `why`, refusing a claim that waits; the secret is gone with it. */
function closeWindow(why: string | null): void {
	const open = window;
	if (open === null) return;
	window = null;
	clearTimeout(open.timer);
	open.secret.fill(0);
	// No `why`: the person closed it on the Mac (Cancel, a new code, remote access turned off).
	if (open.claim !== null) remoteHooks.toHelper({ kind: "pairRefused", claim: open.claim.id, why: why ?? "The pairing was closed on the Mac.", ...(why === null ? { reason: "cancelled" satisfies PairRefusalWord } : {}) });
	remoteHooks.toHelper({ kind: "closeJoin" });
	closed = why === null ? null : { why, at: Date.now() };
	if (why !== null) log("devices: the pairing window closed:", why);
	announce();
	remoteHooks.changed();
}

/** pi² Remote stopped: a claim's channel went with it, so its phone could never be answered. The window closes. */
export function helperGone(): void {
	if (window !== null && window.pairing !== "") closeWindow("pi² Remote stopped while the code was open. Start again.");
}

/** The checks a claim's attestation is put through; a test engine's stand-in, or App Attest's verifier (#672). */
type Verify = (attestation: Uint8Array, expected: { teamId: string; bundleId: string; keyId: Uint8Array; clientDataHash: Uint8Array; environments: AppAttestEnvironment[] }) => Promise<AppAttestResult>;

/**
 * A development engine's stand-in for App Attest (`PI2_APP_ATTEST_STAND_IN`), for the tests: it takes an
 * "attestation" that is JSON naming what App Attest would have checked, and refuses one that names other client data or
 * another key, as App Attest's would. A release engine never reads the switch (testswitches.ts).
 */
const standInVerify: Verify = async (attestation, expected) => {
	let given: Record<string, unknown>;
	try {
		given = JSON.parse(Buffer.from(attestation).toString("utf8"));
	} catch {
		throw new AppAttestError("malformed", "The attestation is not one the stand-in made.");
	}
	if (given.standIn !== "pi2-app-attest") throw new AppAttestError("malformed", "The attestation is not one the stand-in made.");
	if (given.appId !== `${expected.teamId}.${expected.bundleId}`) throw new AppAttestError("app-id", "The attestation was made for another app.");
	if (!same(Buffer.from(String(given.keyId), "base64"), expected.keyId)) throw new AppAttestError("key-id", "The attestation is for another key than the one named.");
	if (!same(Buffer.from(String(given.clientDataHash), "base64url"), expected.clientDataHash)) throw new AppAttestError("nonce", "The attestation was made for other client data.");
	const environment = given.environment as AppAttestEnvironment;
	if (!expected.environments.includes(environment)) throw new AppAttestError("environment", "The attestation comes from an App Attest environment that is not taken.");
	return {
		publicKey: new Uint8Array(65),
		environment,
		receipt: new Uint8Array(0),
		validationCategory: typeof given.validationCategory === "number" ? given.validationCategory : null,
		bundleVersion: typeof given.bundleVersion === "string" ? given.bundleVersion : null,
	};
};

/**
 * Apple's launch validation category (`apple_validation_category_01`) a claim's attestation must carry: 1, an app the
 * system distributed (the App Store, TestFlight), in every engine; 3, a build signed for development, only in a
 * development engine. Anything else, and none at all (a system before iOS 27, which pi² for iPhone does not run on),
 * is refused.
 */
const takenCategories = () => (release ? [1] : [1, 3]);
/** App Attest's environments, named: a release engine takes production keys alone; a development engine both. */
const takenEnvironments = (): AppAttestEnvironment[] => (release ? ["production"] : ["production", "development"]);

/** Opens a join window (`devices.pairStart`): its answer, the payload, holds `s` and goes to the app alone (3.1). */
async function pairStart(): Promise<{ payload: string; expires: number }> {
	if (!remoteOn()) throw new Error("Turn on Reach from an iPhone first.");
	if (activeDevices().length >= MAX_DEVICES) throw new Error(`${MAX_DEVICES} devices are paired already. Revoke one first.`);
	if (state.relay === "") throw new Error("This build of pi² has no relay to pair through.");
	closeWindow(null);
	closed = null;
	// A placeholder window, so that pi² Remote is wanted while it starts; the real one replaces it below.
	const secret = randomBytes(32);
	const expires = Date.now() + WINDOW_MS;
	window = { secret, pairing: "", expires, claiming: false, claim: null, wrongTries: 0, timer: setTimeout(() => closeWindow("The code expired."), WINDOW_MS) };
	remoteHooks.changed();
	try {
		const { addresses } = await remoteHooks.ready();
		if (state.pairing !== null) {
			const refused = pairingElsewhere(await remoteHooks.relayWord(RELAY_WORD_WAIT_MS));
			if (refused !== null) throw new Error(refused);
		}
		if (state.pairing === null) {
			remoteHooks.toHelper({ kind: "register", relay: state.relay });
			await waitForPairing();
		}
		const keys = state.macKeys;
		if (keys === null || state.pairing === null) throw new Error("pi² Remote has not said which keys and pairing this Mac has.");
		if (window?.secret !== secret) throw new Error("The pairing was closed while it started.");
		window.pairing = state.pairing;
		remoteHooks.toHelper({ kind: "openJoin", secret: secret.toString("base64url"), tokenHash: joinTokenHash(secret, state.pairing), expires });
		const parameters: [string, string][] = [
			["v", "2"],
			["p", state.pairing],
			["n", macName()],
			["c", keys.channel],
			["i", keys.identity],
			["r", keys.record],
			["s", secret.toString("base64url")],
			["u", state.relay],
			["a", addresses.join(",")],
			["e", String(Math.floor(expires / 1000))],
		];
		announce();
		return { payload: `pi2://pair?${parameters.map(([name, value]) => `${name}=${encodeURIComponent(value)}`).join("&")}`, expires };
	} catch (error) {
		if (window?.secret === secret) closeWindow(null);
		throw error;
	}
}

/** How long `pairStart` waits for pi² Remote's word about the relay's address now set (#1013). */
const RELAY_WORD_WAIT_MS = 15_000;
export const PAIRING_AT_ANOTHER_RELAY = "This Mac's pairing belongs to another relay. Start again at this relay first, or set the relay's address back.";
export const PAIRING_AT_ANOTHER_RELAY_OFF = "This Mac's pairing belongs to another relay. Set the relay's address back, or turn on Reach through pi²'s relay and start again at this relay.";
export const PAIRING_AT_NO_RELAY = "This Mac's pairing is registered at no relay. Start again at this relay first, or turn Reach through pi²'s relay off.";
export const RELAY_WORD_MISSING = "pi² Remote has not said whether this Mac's pairing belongs to the relay now set. Try again in a moment.";

/**
 * Why no pairing may open now, or null (#1013): a pairing code names the pairing's id with the relay's address now set,
 * and the phone tries that relay at once, so a code for a pairing registered at another relay would show its id to this
 * one, which #678's security read rules out; whatever the relay switch says, since the phone does not know it. One made
 * with the relay off (`none`) is registered nowhere: its code may name it to a relay while the switch is off, as its
 * first did; with the switch on the page offers to start again instead, and so does the engine. A word not said within
 * the wait refuses too: nothing opens on a guess.
 */
function pairingElsewhere(word: Record<string, unknown> | null): string | null {
	if (word === null) return RELAY_WORD_MISSING;
	if (word.registered === "another-relay") return state.remote.relay ? PAIRING_AT_ANOTHER_RELAY : PAIRING_AT_ANOTHER_RELAY_OFF;
	if (word.registered === "none" && state.remote.relay) return PAIRING_AT_NO_RELAY;
	if (word.registered !== "here" && word.registered !== "none") return RELAY_WORD_MISSING;
	return null;
}

/** Waits for pi² Remote to report the pairing the relay gave it, after `register`. */
async function waitForPairing(): Promise<void> {
	const deadline = Date.now() + 60_000;
	while (state.pairing === null) {
		if (Date.now() > deadline) throw new Error("pi²'s relay did not give this Mac a pairing. Try again in a moment.");
		await new Promise((resolve) => setTimeout(resolve, 100));
	}
}

/** One of the window's three wrong tries: a wrong token at the relay, or a wrong pre-shared key at home (3.1). */
export function pairWrong(): void {
	if (window === null) return;
	window.wrongTries += 1;
	if (window.wrongTries >= 3) closeWindow("Three tries with a wrong code. Start again.");
}

/**
 * Why pi² Remote refused a claimer itself, one that proved the pairing's secret but whose claim never reached the
 * engine (`remote.pairRefused`): its first line was not `pair`, its claim was not signed for its channel, or it went
 * quiet. As any refused claim, it closes the window (3.3 step 5). A claim that does not decrypt is a wrong try instead
 * (`remote.pairWrong`).
 */
const HELPER_REFUSALS: Record<string, string> = {
	"not-pair": "A phone's claim was refused: its first line was not a claim to pair.",
	"not-bound": "A phone's claim was refused: its claim was not signed for its channel.",
	silent: "A phone's claim was refused: it went quiet.",
	// Not the claimer's doing (#887): the Keychain or the data folder refused pi² Remote's write of the home key.
	"not-kept": "pi² Remote could not keep the pairing on this Mac. Start again.",
};

export function pairRefusedByHelper(why: unknown): void {
	if (typeof why !== "string" || !Object.hasOwn(HELPER_REFUSALS, why)) throw new Error(`why is one of ${Object.keys(HELPER_REFUSALS).join(", ")}`);
	if (window === null || window.pairing === "") throw new Error(NO_WINDOW);
	closeWindow(HELPER_REFUSALS[why]!);
}

/** How long after `paired` pi² Remote may take a pairing back (`remote.pairUnkept`). */
export const UNKEPT_WITHIN = 60_000;
export const NOT_KEPT = "The Mac could not save the pairing. Start again.";

/**
 * A pairing the engine made that pi² Remote could not keep on its side (`remote.pairUnkept`, #887): its write of the
 * device and the home key failed after the engine sent `paired`, so it holds no device and the phone was sent `bye`.
 * The device goes as if it had never been paired: its record removed, not revoked, so nothing of it is kept to refuse a
 * new claim with the same keys. A device it replaced stays revoked: pi² Remote has dropped it and made a new home key.
 *
 * remote.ts takes it only from the pi² Remote that was sent that `paired`, for that device alone, within a minute of
 * it, once. Here, whatever remote.ts checked: the device paired, not revoked, never attached, and paired less than a
 * minute ago. So no older device, nor one a phone has used, can be removed this way.
 */
export async function pairUnkept(id: unknown): Promise<void> {
	const device = pairedDevice(id);
	const now = Date.now();
	const last = lastPaired;
	if (device === undefined || last?.device !== device.id || device.lastSeenAt !== null || now < device.pairedAt || now - device.pairedAt >= UNKEPT_WITHIN) {
		throw new Error("That device is not one pi² Remote paired this last minute.");
	}
	lastPaired = null;
	await change((doc) => {
		doc.devices = doc.devices.filter((one) => one.id !== device.id);
	});
	failures.delete(device.id);
	// Removed, not revoked: but the device is gone, so what is kept for it elsewhere goes as a revoked device's does.
	tellRevoked(device.id);
	remoteHooks.closeSessions(device.id, "The pairing was not kept.");
	closed = { why: NOT_KEPT, at: now };
	log("devices: pi² Remote could not keep the pairing it was sent; the device was taken back");
	// Which phone, by its name as shown (the record is gone, so the Devices page cannot name it), and the device it
	// replaced, which stays revoked.
	const replaced = last.replaced === null ? undefined : state.devices.find((one) => one.id === last.replaced);
	const summary = `Pairing of “${device.name}” taken back${replaced === undefined ? "" : `; it had replaced “${replaced.name}”, which stays revoked`}`;
	await logDevice({ device: device.id, path: last.path, method: "pair", summary, presence: false, outcome: "failed", why: "pi² Remote could not keep the pairing on this Mac." }, true);
	announce();
}

/**
 * A phone's claim to pair (`remote.pairClaim`, 3.3 step 5), checked here whatever pi² Remote checked: the window open
 * and with no other claim, the claim's signature by the device key it names over this channel's binding, App Attest's
 * attestation for that very key and channel, and fewer than five devices. One claim per window: a second, on either
 * path, closes the window and refuses both; one that fails a check closes it too.
 */
export async function pairClaim(params: Params): Promise<{ claim: string }> {
	const open = window;
	if (open === null || open.pairing === "" || open.expires <= Date.now()) throw new Error(NO_WINDOW);
	if (open.claiming || open.claim !== null) {
		closeWindow(SECOND_CLAIM);
		throw new Error(SECOND_CLAIM);
	}
	open.claiming = true;
	try {
		const claim = await checkClaim(open, params);
		if (window !== open) throw new Error(SECOND_CLAIM);
		open.claim = claim;
		open.claiming = false;
		notify("claim", null, `${claim.device.name} wants to pair with this Mac. Type the digits it shows to pair it.`);
		return { claim: claim.id };
	} catch (error) {
		const why = error instanceof Error ? error.message : String(error);
		if (window === open) closeWindow(why === SECOND_CLAIM ? SECOND_CLAIM : `A phone's claim was refused: ${why}`);
		throw error;
	}
}

async function checkClaim(open: PairingWindow, params: Params): Promise<Claim> {
	if (!exactly(params, ["claim", "binding", "challenge", "path"])) throw new Error("The claim is not in the form pi² Remote sends.");
	const binding = fromBase64url(params.binding, 32);
	const challenge = fromBase64url(params.challenge, 32);
	if (binding === null || challenge === null) throw new Error("The claim's binding or challenge is not 32 bytes.");
	if (params.path !== "relay" && params.path !== "home") throw new Error("The claim names no path it came by.");
	const claim = params.claim;
	if (!exactly(claim, ["v", "device", "attestation", "keyId", "signed", "signature"]) || claim.v !== 2) throw new Error("The claim is not a pair line.");
	const device = claim.device;
	if (!exactly(device, ["name", "model", "system", "build", "deviceKey", "presenceKey", "channelKey", "recordKey"])) throw new Error("The claim does not describe a device.");
	if (!plainText(device.name, 128) || !plainText(device.model, 64) || !plainText(device.system, 64) || !buildText(device.build)) {
		throw new Error("The claim's name, model, system or build is not one.");
	}
	const deviceKey = p256Key(device.deviceKey);
	if (deviceKey === null || p256Key(device.presenceKey) === null || p256Key(device.recordKey) === null || fromBase64url(device.channelKey, 32) === null) {
		throw new Error("A key in the claim is not one.");
	}
	if (device.deviceKey === device.presenceKey) throw new Error("The claim's presence key is its device key.");
	const signed = readSigned(claim.signed, ["v", "kind", "pairing", "binding"]);
	if (signed === null || signed.v !== 2 || signed.kind !== "pair" || typeof signed.pairing !== "string" || typeof signed.binding !== "string") {
		throw new Error("The claim's signed text is not a claim to pair.");
	}
	if (!sameText(signed.pairing, open.pairing)) throw new Error("The claim is for another pairing.");
	if (!sameText(signed.binding, params.binding as string)) throw new Error("The claim was signed for another channel.");
	if (!signedBy(claim.signed as string, claim.signature, deviceKey)) throw new Error("The claim is not signed by the device key it names.");
	if (activeDevices().length >= MAX_DEVICES) throw new Error(`${MAX_DEVICES} devices are paired already.`);
	if (state.devices.some((one) => one.deviceKey !== "" && sameText(one.deviceKey, device.deviceKey as string))) throw new Error("That device key is paired already.");
	// A revoked device keeps only its key's hash: the same key cannot pair again while the record is kept (90 days).
	const claimedHash = keyHash(device.deviceKey as string);
	if (state.devices.some((one) => one.deviceKeyHash !== undefined && sameText(one.deviceKeyHash, claimedHash))) throw new Error("That device key was revoked on this Mac.");

	// A build without App Attest (the simulator) sends none (attestation and keyId null). Only a throwaway copy's engine
	// takes it, one scripts/test-copy started with --remote, and never a release engine, which reads no test switch
	// (iphone.md 10). Such a device is paired with no App Attest key, and pi² Remote is told none.
	const unattested = claim.attestation === null && claim.keyId === null && !release && testCopySuffix() !== undefined && testSwitch("PI2_PAIR_UNATTESTED") === "1";
	if (!unattested) {
		// App Attest (P37): a genuine pi² for iPhone vouches for this very device key on this very channel.
		const attestation = fromBase64url(claim.attestation);
		const keyId = fromBase64(claim.keyId, 32);
		if (attestation === null || attestation.length === 0 || keyId === null) throw new Error("The claim has no App Attest attestation.");
		if (state.devices.some((one) => sameText(one.attestKeyId, claim.keyId as string))) throw new Error("That App Attest key is tied to another pairing already.");
		const teamId = testSwitch("PI2_APP_ATTEST_TEAM") ?? IPHONE_TEAM_ID;
		if (teamId === null) throw new Error("This build of pi² cannot check App Attest yet: it does not know pi²'s team id.");
		const clientDataHash = createHash("sha256").update(challenge).update(fromBase64url(device.deviceKey)!).update(binding).digest();
		const check: Verify = testSwitch("PI2_APP_ATTEST_STAND_IN") === "1" ? standInVerify : (bytes, expected) => verifyAttestation(bytes, expected);
		let attested: AppAttestResult;
		try {
			// No `now`: an attestation is checked as it arrives, at the Mac's own time (appattest.ts).
			attested = await check(attestation, { teamId, bundleId: IPHONE_BUNDLE_ID, keyId, clientDataHash, environments: takenEnvironments() });
		} catch (error) {
			throw new Error(`App Attest: ${error instanceof Error ? error.message : String(error)}`);
		}
		if (attested.validationCategory === null || !takenCategories().includes(attested.validationCategory)) {
			throw new Error(`App Attest: the app was not launched as a ${release ? "distributed" : "distributed or development"} build of pi² for iPhone.`);
		}
		if (attested.bundleVersion === null || !sameText(attested.bundleVersion, device.build as string)) throw new Error("App Attest: the app's build is not the one the claim names.");
	}

	// The name, model and system as a phone shows names (`shownName`): the Mac shows them at confirming and at Replace,
	// and a right-to-left override or an invisible character there could make one device read as another (#881).
	const shown = { ...(device as ClaimedDevice), name: shownName(device.name, "iPhone"), model: shownName(device.model, "iPhone"), system: shownName(device.system, "iOS") };
	const replaces = activeDevices().find((one) => one.name === shown.name && one.model === shown.model)?.id ?? null;
	return {
		id: `claim_${randomBytes(12).toString("base64url")}`,
		at: Date.now(),
		path: params.path,
		device: shown,
		attestKeyId: unattested ? "" : (claim.keyId as string),
		digits: pairingDigits(open.secret, binding),
		wrongDigits: 0,
		replaces,
	};
}

/**
 * The digits the person typed on the Mac (`devices.pairConfirm`, 3.3 step 7): the engine pairs only if they are the
 * claim's. Three wrong entries close the window. With `replace`, a claim that matches a paired device's name and model
 * revokes it in the same commit.
 */
async function pairConfirm(params: Params): Promise<{ device: string }> {
	const open = window;
	const claim = open?.claim ?? null;
	if (open === null || claim === null) throw new Error("No phone is waiting to pair.");
	if (typeof params.digits !== "string" || !/^[0-9]{6}$/.test(params.digits)) throw new Error("Type the six digits the phone shows.");
	if (!sameText(params.digits, claim.digits)) {
		claim.wrongDigits += 1;
		if (claim.wrongDigits >= 3) closeWindow("Three wrong entries. Start again.");
		else announce();
		throw new Error("Those are not the digits the phone shows.");
	}
	const replaced = params.replace === true ? claim.replaces : null;
	// The phone is answered through the pi² Remote that carried its claim: with none running, it never could be.
	const addresses = remoteHooks.addresses();
	if (addresses === null) {
		closeWindow("pi² Remote is not running, so the phone could not be told. Start again.");
		throw new Error("pi² Remote is not running, so the phone could not be told. Start again.");
	}
	const now = Date.now();
	const device: Device = {
		id: `dev_${randomBytes(16).toString("base64url")}`,
		name: shownName(claim.device.name, "iPhone"),
		model: claim.device.model,
		system: claim.device.system,
		deviceKey: claim.device.deviceKey,
		presenceKey: claim.device.presenceKey,
		pendingPresenceKey: null,
		channelKey: claim.device.channelKey,
		recordKey: claim.device.recordKey,
		attestKeyId: claim.attestKeyId,
		build: claim.device.build,
		suspendedAt: null,
		pairedAt: now,
		lastSeenAt: null,
		lastPath: null,
		revokedAt: null,
	};
	// The claim is spent, and the window closed, before anything is stored: it pairs once, and no claim can come
	// while the device is saved.
	open.claim = null;
	// pi² Remote stays wanted while the device is saved, however long the disk takes: with no device paired yet, the
	// window's closing would otherwise leave it unwanted, and stopped two seconds later with `paired` still to send.
	saving += 1;
	try {
		closeWindow(null);
		await change((doc) => {
			if (replaced !== null) for (const old of doc.devices) if (old.id === replaced) forget(old, now);
			doc.devices.push(device);
		});
	} catch (error) {
		// Nothing was stored: the phone waiting on its pairing channel is told so, rather than left without an answer.
		remoteHooks.toHelper({ kind: "pairRefused", claim: claim.id, why: NOT_KEPT, reason: "unsaved" satisfies PairRefusalWord });
		throw error;
	} finally {
		saving -= 1;
		remoteHooks.changed();
	}
	if (replaced !== null) {
		// Its settings and anything else kept for it go with it, as a revoked device's do (#905's second read).
		tellRevoked(replaced);
		remoteHooks.toHelper({ kind: "revoke", device: replaced });
		remoteHooks.closeSessions(replaced, "replaced");
	}
	lastPaired = { device: device.id, path: claim.path, replaced };
	remoteHooks.toHelper({
		kind: "paired",
		claim: claim.id,
		device: { id: device.id, deviceKey: device.deviceKey, presenceKey: device.presenceKey, channelKey: device.channelKey, recordKey: device.recordKey, attestKeyId: device.attestKeyId === "" ? null : device.attestKeyId },
		paired: { device: device.id, pairing: state.pairing, name: macName(), addresses },
	});
	await logDevice({ device: device.id, path: claim.path, method: "pair", summary: summarize("pair", {}), presence: false, outcome: "done" }, true);
	// pi² Remote may have taken it back meanwhile (`pairUnkept`).
	if (pairedDevice(device.id) !== undefined) notify("paired", device.id, `${device.name} was paired with this Mac.`);
	return { device: device.id };
}

/** Revokes a device in the record: from now on no attach, presence signature or sealed item of it is taken (3.6). */
function forget(device: Device, now: number): void {
	if (device.deviceKey !== "") device.deviceKeyHash = keyHash(device.deviceKey);
	device.revokedAt = now;
	device.deviceKey = "";
	device.presenceKey = null;
	device.pendingPresenceKey = null;
	device.channelKey = "";
	device.recordKey = "";
	device.suspendedAt = null;
}

/** Told of each device revoked, once its record says so: what is kept for it elsewhere goes with it (pushes.ts). */
export const revokedWatchers = new Set<(device: string) => void>();

/**
 * Tells every watcher of a device taken away — revoked, taken back or replaced — each in its own `try`: no watcher's fault
 * keeps the others from hearing it. A device whose record now refuses it is gone to the watchers whether it was revoked
 * or removed (#905's second read).
 */
function tellRevoked(id: string): void {
	for (const watch of revokedWatchers) {
		try {
			watch(id);
		} catch (error) {
			log("devices: a watcher of revocations failed:", error instanceof Error ? error.message : error);
		}
	}
}

async function revoke(id: string): Promise<void> {
	const device = pairedDevice(id);
	if (device === undefined) throw new Error("No such device is paired.");
	await change((doc) => {
		for (const one of doc.devices) if (one.id === id) forget(one, Date.now());
	});
	failures.delete(id);
	// Before the two below: no watcher's fault keeps the revocation from pi² Remote and the device's sessions.
	tellRevoked(id);
	// `revoke` first: pi² Remote sends the phone its signed `revoked` line on the channel, which closing the sessions
	// next would otherwise have ended (3.6).
	remoteHooks.toHelper({ kind: "revoke", device: id });
	remoteHooks.closeSessions(id, "revoked");
}

// ---- Starting again at the relay now set (#917)

/**
 * What pi² Remote says of the relay path (`remote.state`'s `relay.reason`) when this Mac's pairing cannot use the relay
 * now set, and only a new pairing can: it was registered at another relay, whose pairing's id pi² Remote never shows to
 * this one (#678's security read), or at none (pi² Remote made its id, or could not keep its registration).
 */
export const START_AGAIN_REASONS: readonly string[] = ["another-relay", "unregistered"];
/** Pairings forgotten by starting again, this run: pi² Remote's word naming one is not taken back (`helperReported`). */
const forgottenPairings = new Set<string>();
/** `devices.startAgain` calls asking pi² Remote for its word: it is wanted meanwhile, with no device paired too. */
let askingAgain = 0;
export const NOTHING_TO_START_AGAIN = "pi² Remote does not say this Mac's pairing belongs to another relay or to none, so there is nothing to start again.";
/** `devices.startAgain` refused: what the person's yes was about is not what the Mac holds now (#917's second read). */
export const START_AGAIN_CHANGED = "This Mac's pairing, the relay's address or the switches changed while starting again; nothing was changed. Try again.";

/**
 * Where this Mac's pairing is registered beside the relay's address now set, by pi² Remote's last word about this
 * address and this pairing (`registered`, #1013), remembered while pi² Remote is stopped, as it is with no device
 * paired: `here`, `another-relay`, `none`, or null when there is no such word. The Devices page offers to start again,
 * and offers no pairing code, by it, as `pairStart` and `startAgain` decide by the live word.
 */
function pairingRegisteredNow(): string | null {
	if (!remoteOn() || state.pairing === null) return null;
	const registered = remoteHooks.lastRelayWord()?.registered;
	return typeof registered === "string" ? registered : null;
}

/**
 * `devices.startAgain`, the person's word on the Mac (FOR_THE_PERSON_SETTINGS, MAC_ONLY): every device revoked as Revoke
 * revokes each, and the pairing forgotten, in one commit; then pi² Remote is told each revocation (the phones attached
 * are sent the signed `revoked` line) and `forgetPairing`. It registers nothing: the next `devices.pairStart` finds no
 * pairing and has pi² Remote register one at the relay now set, as a first pairing does, with the window it opens. Only
 * while pi² Remote says the pairing cannot use this relay, so that it never unpairs the phones of a pairing that can.
 * The old relay is not contacted: pi² Remote asks a relay to remove a device only while connected there as this
 * pairing's Mac, which it is not at another relay's address (nor ever, for a pairing made with the relay off).
 * The pairing, the relay's address and the switches are read again immediately before that commit, with nothing awaited
 * between the two, so that a setting changed while pi² Remote's word was awaited refuses instead (#917's second read).
 */
async function startAgain(): Promise<{ revoked: string[] }> {
	if (!remoteOn()) throw new Error("Turn on Reach from an iPhone first.");
	if (!state.remote.relay || state.relay === "") throw new Error("Turn on Reach through pi²'s relay, with its address, first.");
	if (state.pairing === null) throw new Error(NOTHING_TO_START_AGAIN);
	// What the person's yes is about, recorded before anything is awaited: the pairing as it is now, and the relay's
	// address this start acts on. The commit that revokes and forgets checks that both are still these (#917's second
	// read): a settings change while pi² Remote's word is awaited refuses, with nothing revoked or forgotten.
	const pairing = state.pairing;
	const address = state.relay;
	// As pairStart (#1013): pi² Remote started if it is not running (no device paired), and its word about the address
	// now set awaited, within the same bound; no word, no start again.
	askingAgain += 1;
	try {
		remoteHooks.changed();
		await remoteHooks.ready();
		const word = await remoteHooks.relayWord(RELAY_WORD_WAIT_MS);
		if (word === null) throw new Error(RELAY_WORD_MISSING);
		if (word.registered !== "another-relay" && word.registered !== "none") throw new Error(NOTHING_TO_START_AGAIN);
		return await forgetAll(word.registered === "another-relay" ? "another-relay" : "unregistered", pairing, address, word);
	} finally {
		askingAgain -= 1;
		remoteHooks.changed();
	}
}

/**
 * Whether what `devices.startAgain` read when it started has moved since: the pairing, the relay's address, the
 * switches that start needs, or the address pi² Remote's word is about. Checked in the commit's own synchronous stretch,
 * so nothing can change between the check and the write.
 */
function startAgainMoved(doc: DevicesState, pairing: string, address: string, word: Record<string, unknown>): boolean {
	return doc.pairing !== pairing || doc.relay !== address || !(doc.remote.on && doc.remote.preview) || !doc.remote.relay || word.address !== address;
}

async function forgetAll(reason: string, pairing: string, address: string, word: Record<string, unknown>): Promise<{ revoked: string[] }> {
	if (startAgainMoved(state, pairing, address, word)) throw new Error(START_AGAIN_CHANGED);
	const revoked = activeDevices().map((device) => device.id);
	const now = Date.now();
	closeWindow(null);
	await change((doc) => {
		// The same check again on the record the commit writes, with nothing awaited since it: a switch, the address or
		// the pairing that changed while the word was awaited refuses, revoking and forgetting nothing.
		if (startAgainMoved(doc, pairing, address, word)) throw new Error(START_AGAIN_CHANGED);
		for (const one of doc.devices) if (revoked.includes(one.id)) forget(one, now);
		doc.pairing = null;
	});
	forgottenPairings.add(pairing);
	for (const id of revoked) {
		failures.delete(id);
		tellRevoked(id);
		// As `revoke`: the phone's signed `revoked` line first, then its sessions.
		remoteHooks.toHelper({ kind: "revoke", device: id });
		remoteHooks.closeSessions(id, "revoked");
	}
	remoteHooks.toHelper({ kind: "forgetPairing", pairing });
	log(`devices: started again at the relay now set, as the person asked: ${revoked.length} device(s) revoked and the pairing forgotten (${reason})`);
	return { revoked };
}

// ---- A phone's leave, passed on by the relay (3.6; #813, #929)

/** How far ahead of the Mac's clock a leave may be dated: RemoteKit's `RelayLeaveNotice.aheadAtMost`. */
const LEAVE_AHEAD = 10 * 60_000;
/** The latest time the relay and RemoteKit read (`RelayLimits.maxTime`, the year 2286). */
const LATEST_TIME = 9_999_999_999_999;
export const NOT_A_LEAVE = "remote.left takes a device, its time and its notice (64 bytes).";
export const LEAVE_NOT_SIGNED = "The leave is not signed by the device key for this pairing and this Mac.";
/** Devices whose leave is being taken: a repeat meanwhile is answered as one, and the device revoked once. */
const leaving = new Set<string>();

/**
 * A phone's leave (`remote.left { device, at, notice }`): the person unpaired the phone on the phone itself, which
 * signed with its device key the leave text for this Mac, and the relay passed it on. pi² Remote checked the notice
 * against the device key on its own list (`RelayLeft.verified`); it is checked again here, against the device key in
 * this record, with this record's pairing and the identity key pi² Remote reported, as a mailbox item is: so a faulty or
 * replaced pi² Remote can revoke a device this way only with its phone's own notice, which the phone signs only as it
 * unpairs and deletes its keys. The device is revoked as `devices.forgetSelf` revokes it, and the log says the phone
 * unpaired itself.
 *
 * Once per device: a repeat (the relay passing it on again, now or at the next `ready`, or in the other form of the
 * same ECDSA signature, s or n − s, which verifies as well) finds the device revoked, or being revoked, and is
 * answered `{ revoked: false }`, with nothing done or logged. Its age is not bounded (remotekit.md, "The leave
 * notice"): only a time ahead of the Mac's clock by more than ten minutes is refused.
 */
export async function deviceLeft(params: Params): Promise<{ revoked: boolean }> {
	const { device, at, notice } = params;
	if (Object.keys(params).some((key) => key !== "device" && key !== "at" && key !== "notice") || typeof device !== "string") throw new Error(NOT_A_LEAVE);
	if (typeof at !== "number" || !Number.isSafeInteger(at) || at < 1 || at > LATEST_TIME || fromBase64url(notice, 64) === null) throw new Error(NOT_A_LEAVE);
	const record = state.devices.find((one) => one.id === device);
	if (record === undefined) throw new Error("No such device is paired.");
	if (record.revokedAt !== null || leaving.has(record.id)) return { revoked: false };
	if (at > Date.now() + LEAVE_AHEAD) throw new Error("The leave is dated more than ten minutes ahead of the Mac's clock.");
	const key = p256Key(record.deviceKey);
	const identity = state.macKeys?.identity;
	if (key === null || state.pairing === null || identity === undefined) throw new Error(LEAVE_NOT_SIGNED);
	const text = JSON.stringify({ v: 2, kind: "leave", pairing: state.pairing, device: record.id, mac: identity, at });
	if (!signedBy(text, notice, key)) throw new Error(LEAVE_NOT_SIGNED);
	leaving.add(record.id);
	try {
		await revoke(record.id);
	} finally {
		leaving.delete(record.id);
	}
	log("devices: a phone unpaired itself: its leave, signed by its device key and passed on by the relay, was checked, and the device revoked");
	// The device is revoked whatever the log's write does: a failure to write it is said in engine.log, not to pi² Remote.
	await logDevice({ device: record.id, path: "relay", method: "leave", summary: summarize("leave", {}), presence: false, outcome: "done" }, true).catch((error) =>
		log("devices: the log could not be written:", error instanceof Error ? error.message : error),
	);
	return { revoked: true };
}

// ---- Attach and resume (3.4, 4.3, 5.8)

const challenges = new Map<string, number>();

/** A fresh challenge for one attach or resume (`remote.attachBegin`), good once, for two minutes. */
export function attachChallenge(): { challenge: string } {
	const now = Date.now();
	for (const [challenge, expires] of challenges) if (expires <= now) challenges.delete(challenge);
	// pi² Remote asks for a few a minute per device; more waiting at once than this is a fault, and the oldest go.
	while (challenges.size >= 256) challenges.delete(challenges.keys().next().value!);
	const challenge = randomBytes(32).toString("base64url");
	challenges.set(challenge, now + CHALLENGE_MS);
	return { challenge };
}

/** Takes a challenge this engine issued and has not seen used, once. Compared in constant time. */
function takeChallenge(given: string): boolean {
	const now = Date.now();
	let found: string | undefined;
	for (const [challenge, expires] of challenges) if (expires > now && sameText(challenge, given)) found = challenge;
	if (found === undefined) return false;
	challenges.delete(found);
	return true;
}

/**
 * Refused presence signatures and attaches, by device: five in ten minutes suspend it (3.6, 4.5). Only live ones count
 * (#891): an attach, a resume or an offer of a new Face ID key, each bound to a challenge this engine issued and to its
 * channel. A mailbox item whose presence signature fails is logged and not counted, since a relay can hold back a
 * device's genuine items and deliver them after its Face ID key changed; so is an attach refused only because the key
 * that signed it waits to be accepted on the Mac (`checkAttach`).
 */
const failures = new Map<string, number[]>();

/**
 * A refusal of something the device key signed: counted first, so that a log that cannot be written never keeps it from
 * counting, then logged. Only what the device key proved is the device's can count: a stranger who signs with a key of
 * its own, or none, neither suspends the real device nor writes its log.
 */
async function refused(device: Device, path: DevicePath, method: string, why: string, params: Params = {}): Promise<void> {
	const now = Date.now();
	const recent = [...(failures.get(device.id) ?? []), now].filter((at) => now - at < SUSPEND_WITHIN);
	failures.set(device.id, recent);
	await refusedUncounted(device, path, method, why, params);
	if (recent.length >= SUSPEND_AFTER && device.suspendedAt === null) await suspend(device, path);
}

/** A refusal of something the device key signed, logged and not counted towards the device's suspension. */
async function refusedUncounted(device: Device, path: DevicePath, method: string, why: string, params: Params = {}): Promise<void> {
	try {
		await logDevice({ device: device.id, path, method, summary: summarize(method, params), presence: false, outcome: "refused", why });
	} catch (error) {
		log("devices: the log could not be written:", error instanceof Error ? error.message : error);
	}
}

/** What no key of the device's signed: a line in engine.log, at most once a minute for each device, and nothing else. */
const unsignedSaid = new Map<string, number>();
function unsigned(device: string, what: string): void {
	const now = Date.now();
	if (now - (unsignedSaid.get(device) ?? 0) < 60_000) return;
	unsignedSaid.set(device, now);
	log(`devices: refused ${what} for ${device} not signed by its device key (said once a minute)`);
}

/**
 * Suspends a device. Its `suspend` entry, and the refusals that led to it still waiting in memory, are written in the
 * same commit as the suspension, or in a write of the log already queued before it (#881): a crash can leave the entry
 * without the suspension, never a suspended device with no entry saying why.
 */
async function suspend(device: Device, path: DevicePath): Promise<void> {
	if (unreadable !== null) throw new Error(unreadable);
	const why = `${SUSPEND_AFTER} refused presence signatures or attaches in ten minutes`;
	const at = Date.now();
	await logDevice({ at, device: device.id, path, method: "suspend", summary: summarize("suspend", {}), presence: false, outcome: "done", why });
	await flushDeviceLog((doc) => {
		for (const one of doc.devices) if (one.id === device.id && one.revokedAt === null) one.suspendedAt = at;
	});
	state = (await harness.snapshot(Devices, context)) ?? state;
	announce();
	remoteHooks.changed();
	failures.delete(device.id);
	remoteHooks.closeSessions(device.id, "suspended");
	notify("suspended", device.id, `${device.name} was suspended after ${why}. Resume it on the Devices page if it was you.`);
}

/** `presenceKey`: the key the attach's presence signature was checked against (#786). */
export type Attached = { device: Device; path: Exclude<DevicePath, "mailbox">; session: string | null; presenceKey: string };

/**
 * The reasons a refusal of `remote.attach` may carry beside its words (`data.reason`, #818), which pi² Remote turns
 * into the phone's `refused` line (docs/remotekit.md, "The refused line") without reading the words. Only for an attach
 * the device key signed: a revoked or unknown device, an attach not signed by the device key, and every other refusal
 * carry none, and the phone is told nothing.
 */
export type AttachRefusal = "update" | "suspended" | "presence" | "clock";
const attachRefused = (why: string, reason: AttachRefusal) => new RequestError(why, { reason });

/**
 * Checks an attach or a resume (`remote.attach`, 3.4) as the engine's own: the device paired, not revoked or suspended,
 * of a build at or above the minimum; both signatures, the device key's and the presence key's, over the same text,
 * against the engine's own record; the challenge one this engine issued, used once; the binding this channel's; `at`
 * within two minutes. Each refusal of a known device counts towards its suspension and is logged, but one: an attach
 * whose presence signature is its new Face ID key's, which waits to be accepted on the Mac, and which passed every other
 * check, is logged and not counted (#891), so that a person who opens pi² on the phone before accepting the key does not
 * suspend it. Four refusals carry a reason for the phone beside their words (`AttachRefusal`).
 */
export async function checkAttach(params: Params): Promise<Attached> {
	if (!remoteOn()) throw new Error("Reach from an iPhone is off on this Mac.");
	if (!exactly(params, ["attach", "binding", "path"])) throw new Error("The attach is not in the form pi² Remote sends.");
	const path = params.path;
	if (path !== "relay" && path !== "home" && path !== "direct") throw new Error("The attach names no path it came by.");
	const attach = params.attach;
	if (!exactly(attach, ["signed", "signature", "presence"])) throw new Error("The attach line is not one.");
	const signed = readSigned(attach.signed, ["v", "kind", "pairing", "device", "session", "binding", "challenge", "build", "at"]);
	if (signed === null || signed.v !== 2 || signed.kind !== "attach") throw new Error("The attach's signed text is not an attach.");
	const device = state.devices.find((one) => one.id === signed.device);
	if (device === undefined) throw new Error("No such device is paired with this Mac.");
	if (device.revokedAt !== null) throw new Error("This device was revoked on the Mac.");
	const text = attach.signed as string;
	if (device.suspendedAt !== null) {
		const why = "This device is suspended. Resume it on the Mac's Devices page.";
		throw signedBy(text, attach.signature, p256Key(device.deviceKey)!) ? attachRefused(why, "suspended") : new Error(why);
	}
	const method = signed.session === null ? "attach" : "resume";
	// `logged`: the log's words, where they say more than the phone is told.
	const refuse = async (why: string, reason?: AttachRefusal, logged = why): Promise<never> => {
		await refused(device, path, method, logged);
		throw reason === undefined ? new Error(why) : attachRefused(why, reason);
	};
	// Until the device key proved the attach is the device's, nothing is counted against it (pi² Remote checks the same
	// signature first, 3.4, so only a faulty one sends such an attach).
	if (!signedBy(text, attach.signature, p256Key(device.deviceKey)!)) {
		unsigned(device.id, "an attach");
		throw new Error("The attach is not signed by the device key.");
	}
	const presenceKey = device.presenceKey === null ? null : p256Key(device.presenceKey);
	// A key that waits signs nothing: only the accepted one opens a session, and a phone whose new key waits is told so.
	// The waiting key is tried only to decide whether the refusal counts: signed by it, the attach goes through every
	// other check, each counted as ever, and is refused at the end uncounted (#891). A presence signature neither key
	// made counts, whether a key waits or not, so a waiting key frees from counting only its own holder's attaches.
	let keyWaits = false;
	if (presenceKey === null || !signedBy(text, attach.presence, presenceKey)) {
		const waiting = device.pendingPresenceKey === null ? null : p256Key(device.pendingPresenceKey);
		if (waiting === null || !signedBy(text, attach.presence, waiting)) {
			// The phone is told its key waits, as ever; the log tells this counted refusal from the uncounted one below by its
			// words, so that the two never merge into one entry (#1008's security read, #997).
			return refuse(
				presenceKey === null || device.pendingPresenceKey !== null ? PRESENCE_KEY_WAITS : PRESENCE_NOT_THE_KEYS,
				"presence",
				device.pendingPresenceKey !== null ? PRESENCE_BY_NEITHER_KEY : PRESENCE_NOT_THE_KEYS,
			);
		}
		keyWaits = true;
	}
	if (typeof signed.challenge !== "string" || !takeChallenge(signed.challenge)) return refuse("The attach's challenge is not one this Mac issued, or was used.");
	if (typeof signed.pairing !== "string" || state.pairing === null || !sameText(signed.pairing, state.pairing)) return refuse("The attach is for another pairing.");
	if (typeof signed.binding !== "string" || fromBase64url(params.binding, 32) === null || !sameText(signed.binding, params.binding as string)) {
		return refuse("The attach was signed for another channel.");
	}
	if (typeof signed.at !== "number" || !Number.isSafeInteger(signed.at) || Math.abs(Date.now() - signed.at) > AT_WITHIN) return refuse("The attach's time is more than two minutes from the Mac's.", "clock");
	if (signed.session !== null && (typeof signed.session !== "string" || !/^[A-Za-z0-9_-]{1,64}$/.test(signed.session))) return refuse("The attach names no session.");
	if (!buildText(signed.build)) return refuse("The attach names no build.");
	if (!buildAtLeast(signed.build, MINIMUM_PHONE_BUILD)) throw attachRefused("This build of pi² for iPhone is too old for this Mac. Update it.", "update");
	if (keyWaits) {
		await refusedUncounted(device, path, method, PRESENCE_KEY_WAITS);
		throw attachRefused(PRESENCE_KEY_WAITS, "presence");
	}
	const build = signed.build;
	await change((doc) => {
		for (const one of doc.devices) {
			if (one.id !== device.id) continue;
			one.lastSeenAt = Date.now();
			one.lastPath = path;
			one.build = build;
		}
	});
	const attached: Attached = { device, path, session: signed.session as string | null, presenceKey: device.presenceKey as string };
	return { ...attached, device: attachHolds(attached) };
}

/**
 * The device of an attach checked, as the record has it now, or a plain refusal (#786): still paired, not suspended,
 * its presence key still the one the attach was signed by. A key accepted or a revocation saved while the attach's own
 * save was under way would otherwise let it open a session under the old key, or find no device. Called again by
 * remote.ts with nothing awaited before the session opens. Not counted: the device did nothing wrong.
 */
export function attachHolds(attached: Pick<Attached, "device" | "presenceKey">): Device {
	const now = pairedDevice(attached.device.id);
	if (now === undefined) throw new Error("This device was revoked on the Mac.");
	if (now.suspendedAt !== null) throw new Error("This device is suspended. Resume it on the Mac's Devices page.");
	if (now.presenceKey === null || !sameText(now.presenceKey, attached.presenceKey)) throw new Error(PRESENCE_KEY_CHANGED);
	return now;
}

/** An attach or resume taken, in the log (4.4). */
export async function attachTaken(device: string, path: DevicePath, resumed: boolean): Promise<void> {
	const method = resumed ? "resume" : "attach";
	await logDevice({ device, path, method, summary: summarize(method, {}), presence: true, outcome: "done" });
}

// ---- A new Face ID key (3.2, 4.3, 4.4; #786)

export const PRESENCE_KEY_WAITS = "This device's new Face ID key waits to be accepted on the Mac.";
const PRESENCE_NOT_THE_KEYS = "The attach's presence signature is not the presence key's.";
/** The log's words for an attach whose presence signature neither the accepted key nor the waiting one made: counted. */
export const PRESENCE_BY_NEITHER_KEY = "The attach's presence signature is neither the presence key's nor the new Face ID key's that waits; counted towards suspension.";
export const PRESENCE_KEY_ALREADY_WAITS = "A new Face ID key already waits to be accepted on the Mac. Accept or refuse it there first.";
const NO_KEY_WAITS = "No new Face ID key waits for this device.";
export const PRESENCE_KEY_CHANGED = "This device's Face ID key changed on the Mac while it attached. Open pi² with Face ID again.";
const KEY_ANSWERED = "The new Face ID key changed while you answered. Look at the Devices page again.";

/**
 * Changes the record and writes the log's entry for it in one commit, so that a crash cannot leave either without the
 * other (#786); what waited in memory for the log is written first, so the log stays in order. `edit` answers whether it
 * changed anything: if not, nothing is written.
 */
async function changeLogged(edit: (doc: DevicesState) => boolean, entry: Omit<DeviceLogEntry, "at" | "summary" | "presence" | "outcome">): Promise<boolean> {
	if (unreadable !== null) throw new Error(unreadable);
	await flushDeviceLog();
	let changed = false;
	await harness.commit(async (tx) => {
		changed = edit(await tx.doc(Devices));
		if (changed) (await tx.doc(DeviceLog)).entries.push({ ...entry, at: Date.now(), summary: summarize(entry.method, {}), presence: false, outcome: "done" });
	}, context);
	state = (await harness.snapshot(Devices, context)) ?? state;
	announce();
	remoteHooks.changed();
	return changed;
}

/**
 * A phone's offer of a new presence key, made when Face ID was enrolled again or turned on later (`remote.presenceKey`,
 * 3.2). The old key no longer signs, so the phone can open no session to send a request; the offer comes as an attach
 * does, through pi² Remote on a channel: `{ offer: { signed, signature, presence }, binding, path }`, with `signed` =
 * `{"v":2,"kind":"presenceKey","pairing","device","binding","challenge","presenceKey","build","at"}`, signed by the device
 * key and by the offered key itself, so that the phone proves it holds it; the challenge one `remote.attachBegin`
 * issued, the binding this channel's, the build at or above the minimum, as an attach's, `at` within two minutes. The
 * key is a P-256 key in the one form RemoteKit takes (`p256Key`). A key taken is kept as the device's *waiting* key, used for
 * nothing (no attach, resume or sealed item is checked against it) until the person accepts it on the Mac
 * (`devices.acceptPresenceKey`), and the Mac is told at once (4.4).
 *
 * One key waits at a time: a second offer while one waits is refused, never put in its place, and counted towards the
 * device's suspension as any refused attach is, so that a phone cannot flood the Mac with offers or notices. The same
 * key offered again is answered as waiting, without a second notice; the key in use offered again is answered as
 * accepted, without counting, so that a phone can learn its key was accepted without attaching to find out.
 *
 * Three refusals carry the reason an attach's would (`AttachRefusal`, #891), which pi² Remote tells the phone in place
 * of a bare end: `suspended` (only for an offer the device key signed; not counted, as before), `clock` (counted, as
 * before) and `update` (not counted, as before). A second key while one waits carries none (counted, as before): the key
 * that waits is not this phone's, and `presence` would have the phone tell the person to accept it on the Mac.
 */
export async function offerPresenceKey(params: Params): Promise<{ waiting: true } | { accepted: true }> {
	if (!remoteOn()) throw new Error("Reach from an iPhone is off on this Mac.");
	if (!exactly(params, ["offer", "binding", "path"])) throw new Error("The offer is not in the form pi² Remote sends.");
	const path = params.path;
	if (path !== "relay" && path !== "home" && path !== "direct") throw new Error("The offer names no path it came by.");
	const offer = params.offer;
	if (!exactly(offer, ["signed", "signature", "presence"])) throw new Error("The offer line is not one.");
	const signed = readSigned(offer.signed, ["v", "kind", "pairing", "device", "binding", "challenge", "presenceKey", "build", "at"]);
	if (signed === null || signed.v !== 2 || signed.kind !== "presenceKey") throw new Error("The offer's signed text is not an offer of a Face ID key.");
	const device = state.devices.find((one) => one.id === signed.device);
	if (device === undefined) throw new Error("No such device is paired with this Mac.");
	if (device.revokedAt !== null) throw new Error("This device was revoked on the Mac.");
	const text = offer.signed as string;
	if (device.suspendedAt !== null) {
		const why = "This device is suspended. Resume it on the Mac's Devices page.";
		throw signedBy(text, offer.signature, p256Key(device.deviceKey)!) ? attachRefused(why, "suspended") : new Error(why);
	}
	// As for an attach: nothing is counted against the device until its device key proved the offer is its own.
	if (!signedBy(text, offer.signature, p256Key(device.deviceKey)!)) {
		unsigned(device.id, "an offer of a Face ID key");
		throw new Error("The offer is not signed by the device key.");
	}
	const refuse = async (why: string, reason?: AttachRefusal): Promise<never> => {
		await refused(device, path, "presenceKey", why);
		throw reason === undefined ? new Error(why) : attachRefused(why, reason);
	};
	if (typeof signed.challenge !== "string" || !takeChallenge(signed.challenge)) return refuse("The offer's challenge is not one this Mac issued, or was used.");
	if (typeof signed.pairing !== "string" || state.pairing === null || !sameText(signed.pairing, state.pairing)) return refuse("The offer is for another pairing.");
	if (typeof signed.binding !== "string" || fromBase64url(params.binding, 32) === null || !sameText(signed.binding, params.binding as string)) {
		return refuse("The offer was signed for another channel.");
	}
	if (typeof signed.at !== "number" || !Number.isSafeInteger(signed.at) || Math.abs(Date.now() - signed.at) > AT_WITHIN) return refuse("The offer's time is more than two minutes from the Mac's.", "clock");
	if (!buildText(signed.build)) return refuse("The offer names no build.");
	if (!buildAtLeast(signed.build, MINIMUM_PHONE_BUILD)) throw attachRefused("This build of pi² for iPhone is too old for this Mac. Update it.", "update");
	const build = signed.build;
	const offered = signed.presenceKey;
	const key = p256Key(offered);
	if (key === null || typeof offered !== "string") return refuse("The offered Face ID key is not a P-256 key in the form pi² for iPhone writes one.");
	if (!signedBy(text, offer.presence, key)) return refuse("The offer is not signed by the key it offers.");
	if (sameText(offered, device.deviceKey)) return refuse("The offered Face ID key is the device key.");
	if (device.presenceKey !== null && sameText(offered, device.presenceKey)) return { accepted: true };
	if (device.pendingPresenceKey !== null) {
		if (sameText(offered, device.pendingPresenceKey)) return { waiting: true };
		return refuse(PRESENCE_KEY_ALREADY_WAITS);
	}
	const taken = await changeLogged(
		(doc) => {
			let changed = false;
			for (const one of doc.devices) {
				if (one.id !== device.id || one.revokedAt !== null || one.pendingPresenceKey !== null) continue;
				one.pendingPresenceKey = offered;
				one.lastSeenAt = Date.now();
				one.lastPath = path;
				one.build = build;
				changed = true;
			}
			return changed;
		},
		{ device: device.id, path, method: "presenceKey" },
	);
	if (!taken) return refuse(PRESENCE_KEY_ALREADY_WAITS);
	notify("presenceKey", device.id, `Face ID was set up again on ${device.name}. Accept the new key in Settings › Devices only if you did it yourself.`);
	return { waiting: true };
}

/**
 * The person accepts a device's waiting key on the Mac (`devices.acceptPresenceKey`, the app's alone): it replaces the
 * presence key, and writes the log's entry, in one commit; pi² Remote is told the new key, then the device's sessions,
 * opened under the old one, end, as at a revocation. An attach checked against the old key while this was saved is
 * refused (`attachHolds`).
 */
async function acceptPresenceKey(id: string): Promise<void> {
	const device = pairedDevice(id);
	if (device === undefined) throw new Error("No such device is paired.");
	const key = device.pendingPresenceKey;
	if (key === null) throw new Error(NO_KEY_WAITS);
	const accepted = await changeLogged(
		(doc) => {
			let changed = false;
			for (const one of doc.devices) {
				if (one.id !== id || one.revokedAt !== null || one.pendingPresenceKey !== key) continue;
				one.presenceKey = key;
				one.pendingPresenceKey = null;
				changed = true;
			}
			return changed;
		},
		{ device: id, path: device.lastPath ?? "relay", method: "devices.acceptPresenceKey" },
	);
	if (!accepted) throw new Error(KEY_ANSWERED);
	remoteHooks.toHelper({ kind: "presenceKey", device: id, presenceKey: key });
	remoteHooks.closeSessions(id, "Its new Face ID key was accepted on the Mac.");
}

/**
 * The person refuses a device's waiting key (`devices.refusePresenceKey`, the app's alone): the key read, and no other,
 * is dropped, and logged in the same commit.
 */
async function refusePresenceKey(id: string): Promise<void> {
	const device = pairedDevice(id);
	if (device === undefined) throw new Error("No such device is paired.");
	const key = device.pendingPresenceKey;
	if (key === null) throw new Error(NO_KEY_WAITS);
	const dropped = await changeLogged(
		(doc) => {
			let changed = false;
			for (const one of doc.devices) {
				if (one.id !== id || one.revokedAt !== null || one.pendingPresenceKey !== key) continue;
				one.pendingPresenceKey = null;
				changed = true;
			}
			return changed;
		},
		{ device: id, path: device.lastPath ?? "relay", method: "devices.refusePresenceKey" },
	);
	if (!dropped) throw new Error(KEY_ANSWERED);
}

// ---- Sealed items from the mailbox (4.3, 5.3)

const ITEM_FIELDS = ["v", "kind", "pairing", "device", "method", "params", "nonce", "at"] as const;
export const ITEM_TOO_OLD = "Not sent: more than a day passed before your Mac saw it.";
export const ITEM_TOO_OLD_FACE = "Not sent: more than an hour passed before your Mac saw it.";
/** A sealed item whose nonce was taken before: the relay handed it over again, or it was copied. */
export const ITEM_TAKEN_BEFORE = "The item was taken before.";

/** A sealed item that could not be taken now but could later (its nonce not stored): left at the relay, which hands it over again (#806). */
export class ItemNotYet extends Error {}

/**
 * Checks a request a device sealed into the mailbox, once opened by pi² Remote, before it is handled
 * (remote.mailboxIn, #678, calls this): remote access on; the device paired and not suspended; first its form and the
 * device key's signature over the exact `signed` text, before anything is written or counted, since the relay, which
 * the contract does not trust, can hand pi² Remote any item "from" a device; then, logged and not counted, `at` at most
 * a day old and not ahead of the Mac's clock by more than five minutes, and its nonce not taken before (read); then,
 * logged and not counted (#891), the presence key's signature; then, logged, that the request is the one signed, for this
 * pairing, its row of the device's table allowing the mailbox, `at` at most an hour old for one that widens, and its
 * nonce never taken before, stored before this answers, after a restart too.
 */
export async function checkRequestItem(device: string, item: unknown, approvals: Omit<DeviceSession, "path">, now = Date.now()): Promise<{ method: string; params: Params; widens: boolean }> {
	if (!remoteOn()) throw new Error("Reach from an iPhone is off on this Mac.");
	const record = pairedDevice(device);
	if (record === undefined) throw new Error("No such device is paired with this Mac.");
	if (record.suspendedAt !== null) throw new Error("This device is suspended. Resume it on the Mac's Devices page.");
	if (!exactly(item, ["v", "request", "signed", "signature", "presence"]) || item.v !== 2) throw new Error("The item is not a request.");
	const request = item.request;
	if (!exactly(request, ["method", "params"]) || typeof request.method !== "string" || typeof request.params !== "object" || request.params === null || Array.isArray(request.params)) {
		throw new Error("The item's request is not one.");
	}
	const signed = readSigned(item.signed, ITEM_FIELDS);
	if (signed === null || signed.v !== 2 || signed.kind !== "request") throw new Error("The item's signed text is not a request.");
	if (!signedBy(item.signed as string, item.signature, p256Key(record.deviceKey)!)) {
		unsigned(device, "a sealed item");
		throw new Error("The item is not signed by the device key.");
	}
	// From here on the device key proved the item is the device's own.
	const refuse = async (why: string, method = requestLogged(String(request.method))): Promise<never> => {
		try {
			await logDevice({ device, path: "mailbox", method, summary: summarize(method, request.params as Params), presence: false, outcome: "refused", why });
		} catch (error) {
			log("devices: the log could not be written:", error instanceof Error ? error.message : error);
		}
		throw new Error(why);
	};
	// A relay can hand over again any item it ever held, long after the device's Face ID key changed: an item past the
	// longest any item waits, or one taken before, is refused before the presence signature is looked at (#921's
	// security read), and a presence signature that fails is refused and logged, never counted towards suspension
	// (#891): only live attaches count, so that items a relay held back and delivered after a Face ID change cannot
	// suspend the device.
	const nonce = signed.nonce;
	if (fromBase64url(nonce, 16) === null) return refuse("The item's nonce is not one.");
	const at = signed.at;
	if (typeof at !== "number" || !Number.isSafeInteger(at) || at > now + ITEM_AHEAD) return refuse("The item's time is ahead of the Mac's.");
	if (now - at > DAY) return refuse(ITEM_TOO_OLD);
	let seen: boolean;
	try {
		seen = Object.hasOwn((await harness.snapshot(DeviceNonces, context))?.taken ?? {}, `${device}:${nonce as string}`);
	} catch (error) {
		throw new ItemNotYet(`The item's nonce could not be read: ${error instanceof Error ? error.message : String(error)}`);
	}
	if (seen) return refuse(ITEM_TAKEN_BEFORE);
	const presenceKey = record.presenceKey === null ? null : p256Key(record.presenceKey);
	if (presenceKey === null || !signedBy(item.signed as string, item.presence, presenceKey)) return refuse("The item's presence signature is not the presence key's.");
	if (signed.device !== device || typeof signed.pairing !== "string" || state.pairing === null || !sameText(signed.pairing, state.pairing)) return refuse("The item is for another device or pairing.");
	if (signed.method !== request.method || JSON.stringify(signed.params) !== JSON.stringify(request.params)) return refuse("The item's request is not the one signed.");
	const method = request.method;
	const params = request.params as Params;
	const answer = deviceMay(method, params, { path: "mailbox", ...approvals });
	if (answer === "no") return refuse(ONLY_ON_THE_MAC);
	if (now - at > (answer === "face" ? 3_600_000 : DAY)) return refuse(answer === "face" ? ITEM_TOO_OLD_FACE : ITEM_TOO_OLD);
	let replayed = false;
	try {
		await harness.commit(async (tx) => {
			const doc = await tx.doc(DeviceNonces);
			const key = `${device}:${nonce as string}`;
			if (Object.hasOwn(doc.taken, key)) replayed = true;
			else doc.taken[key] = now;
			for (const [taken, when] of Object.entries(doc.taken)) if (now - when > NONCES_KEPT) delete doc.taken[taken];
		}, context);
	} catch (error) {
		throw new ItemNotYet(`The item's nonce could not be stored: ${error instanceof Error ? error.message : String(error)}`);
	}
	if (replayed) return refuse(ITEM_TAKEN_BEFORE);
	return { method, params, widens: answer === "face" };
}

// ---- The requests (devices.*), each in FOR_THE_PERSON_SETTINGS but devices.self and devices.forgetSelf (4.1)

const deviceId = (params: Params): string => {
	if (typeof params.device !== "string") throw new Error("device must be a device's id");
	return params.device;
};

/** The requests of this file, which main.ts adds to its table, `client` being the connection that sent each. */
export const deviceRequests: Record<string, (params: Params, client: Client) => Promise<unknown>> = {
	"devices.watch": async (_params, client) => {
		watchers.add(client);
		return devicesEvent();
	},
	"devices.set": async (params) => {
		const switches = ["on", "relay", "home", "direct", "preview"] as const;
		for (const [key, value] of Object.entries(params)) {
			if (key === "relayAddress") continue;
			if (!(switches as readonly string[]).includes(key) || typeof value !== "boolean") throw new Error(`Unknown setting: ${key}`);
		}
		const address = params.relayAddress;
		const relay = typeof address === "string" ? relayAddress(address) : null;
		if (address !== undefined && relay === null) throw new Error("The relay's address is wss://host/path, with no user name or password.");
		await change((doc) => {
			for (const key of switches) if (typeof params[key] === "boolean") doc.remote[key] = params[key] as boolean;
			if (relay !== null) doc.relay = relay;
		});
		if (!remoteOn()) {
			closeWindow(null);
			for (const device of state.devices) remoteHooks.closeSessions(device.id, "Reach from an iPhone was turned off.");
		}
		remoteHooks.toHelper({ kind: "settings", relay: state.relay, switches: state.remote });
		return devicesEvent();
	},
	"devices.pairStart": async () => pairStart(),
	"devices.pairCancel": async () => {
		closeWindow(null);
		return {};
	},
	"devices.pairConfirm": async (params) => pairConfirm(params),
	"devices.rename": async (params) => {
		const id = deviceId(params);
		if (!plainText(params.name, 128)) throw new Error("A device's name is 1 to 128 bytes of text.");
		if (pairedDevice(id) === undefined) throw new Error("No such device is paired.");
		await change((doc) => {
			for (const one of doc.devices) if (one.id === id) one.name = shownName(params.name as string, one.model);
		});
		remoteHooks.recordChanged(id);
		return {};
	},
	"devices.revoke": async (params) => {
		await revoke(deviceId(params));
		return {};
	},
	"devices.acceptPresenceKey": async (params) => {
		await acceptPresenceKey(deviceId(params));
		return {};
	},
	"devices.refusePresenceKey": async (params) => {
		await refusePresenceKey(deviceId(params));
		return {};
	},
	"devices.startAgain": async (params) => {
		if (Object.keys(params).length > 0) throw new Error("devices.startAgain takes nothing.");
		return startAgain();
	},
	"devices.resume": async (params) => {
		const id = deviceId(params);
		if (pairedDevice(id) === undefined) throw new Error("No such device is paired.");
		failures.delete(id);
		await change((doc) => {
			for (const one of doc.devices) if (one.id === id) one.suspendedAt = null;
		});
		return {};
	},
	"devices.log": async (params) => {
		const device = params.device === undefined ? null : deviceId(params);
		const before = params.before;
		if (before !== undefined && typeof before !== "number") throw new Error("before must be a time");
		return { entries: await logEntries(device, before) };
	},
	// A device's own: refused outside a device session.
	"devices.self": async (_params, client) => {
		const device = pairedDevice(client.device?.id);
		if (device === undefined) throw new Error("Only a paired device asks this, of itself.");
		const { id, name, model, system, build, pairedAt, lastSeenAt, lastPath } = device;
		return { device: { id, name, model, system, build, pairedAt, lastSeenAt, lastPath }, log: await logEntries(id, undefined) };
	},
	"devices.forgetSelf": async (_params, client) => {
		const device = pairedDevice(client.device?.id);
		if (device === undefined) throw new Error("Only a paired device asks this, of itself.");
		await revoke(device.id);
		return {};
	},
};

// With a record that could not be read, every request but devices.watch (which says why) is refused, and nothing is
// written over it.
for (const [name, handler] of Object.entries(deviceRequests)) {
	if (name === "devices.watch") continue;
	deviceRequests[name] = async (params, client) => {
		if (unreadable !== null) throw new Error(unreadable);
		return handler(params, client);
	};
}

/**
 * A relay's address in its one written form (the URL parser's), or null: wss:// anywhere; ws:// only to this Mac, and
 * only in a development engine (iphone.md 10); no user name or password, no query or fragment, no host ending in a
 * dot. pi² Remote keeps a relay key for each exact address, so two spellings of one relay must be one address.
 */
function relayAddress(text: string): string | null {
	let url: URL;
	try {
		url = new URL(text);
	} catch {
		return null;
	}
	if (url.username !== "" || url.password !== "" || url.search !== "" || url.hash !== "" || url.hostname === "" || url.hostname.endsWith(".")) return null;
	if (url.protocol === "wss:" || (!release && url.protocol === "ws:" && ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname))) return url.href;
	return null;
}
