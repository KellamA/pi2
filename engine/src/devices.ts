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
// a binding, a challenge or the digits takes a time that depends on the length alone. Nothing key-shaped goes into the
// devices' log (`maskKeys`), and the pairing's secret `s` goes only into the answer to `devices.pairStart`, on the
// app's own connection, and to pi² Remote, never into an event or a log (3.1).

import { createHash, createHmac, createPublicKey, type KeyObject, randomBytes, timingSafeEqual, verify } from "node:crypto";
import { hostname } from "node:os";
import type { Context } from "@earendil-works/chord/context";
import { defineDoc, type Harness } from "@earendil-works/pi-durable";
import { type DevicePath, deviceMay, type DeviceSession, devicePlacement, ONLY_ON_THE_MAC } from "./answers.ts";
import { AppAttestError, type AppAttestEnvironment, type AppAttestResult, verifyAttestation } from "./appattest.ts";
import type { Client } from "./clients.ts";
import { testSwitch } from "./testswitches.ts";

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
	attestKeyId: string; // the App Attest key the Mac checked at pairing, as DCAppAttestService names it (base64)
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
	/** pi² Remote's own state, for the Devices page. */
	helper: () => { running: boolean; stoppedInLastHour: number };
	/** Each device session's record changed: its `device` event is sent again. */
	recordChanged: (device: string) => void;
	/** The Mac's addresses as the running pi² Remote said them, or null when none has said hello. */
	addresses: () => string[] | null;
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
	return unreadable === null && state.remote.preview && state.remote.on && (activeDevices().length > 0 || window !== null || saving > 0);
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
	const pairing = given.pairing ?? null;
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

/** A P-256 public key written as SPKI DER in base64url, in the one encoding a key has. */
export function p256Key(text: unknown): KeyObject | null {
	if (typeof text !== "string" || text.length > 200) return null;
	const der = fromBase64url(text);
	if (der === null) return null;
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

/** `text` with every key-shaped string in it replaced by KEY_HIDDEN. */
export function maskKeys(text: string): string {
	const spans: [number, number][] = [];
	for (const { start, run, least, keep } of KEY_SHAPES) {
		start.lastIndex = 0;
		for (let found = start.exec(text); found !== null; found = start.exec(text)) {
			const after = found.index + found[0].length;
			let end = after;
			while (end < text.length && run(text.charCodeAt(end))) end++;
			if (end - after >= least) spans.push([keep === true ? after : found.index, end]);
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
		spans.push([found.index, end]);
		PEM_BEGIN.lastIndex = end;
	}
	if (spans.length === 0) return text;
	spans.sort((a, b) => a[0] - b[0]);
	let out = "";
	let at = 0;
	for (const [from, to] of spans) {
		if (to <= at) continue;
		if (from >= at) out += text.slice(at, from) + KEY_HIDDEN;
		at = to;
	}
	return out + text.slice(at);
}

/** What stands in a device's copy for a value nested deeper than it is walked. */
export const TOO_DEEP = "[too deep to show]";
const MAX_DEPTH = 256;
/**
 * Set beside an approval a device is sent when masking hid part of it, or part was too deep: the phone does not show
 * the whole call, and the engine takes no allowing answer to it from a device (`approvalHidden`, answers.ts).
 */
export const PART_HIDDEN = "partHidden";

/**
 * `value`, a decoded JSON value, with every string in it masked, the keys of its objects included, and what is nested
 * deeper than 256 levels replaced by TOO_DEEP. Masking the strings rather than the JSON text is what makes it hold: in
 * the text a key after a line break follows `\n`, and one after a colour code follows `\u001b[32m`. `masking.hidden` is
 * set when anything was hidden; an approval (an object of kind "approval" with an id) also gets PART_HIDDEN.
 */
export function maskValue(value: unknown, masking: { hidden: boolean } = { hidden: false }, depth = 0): unknown {
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
	if (Array.isArray(value)) return value.map((item) => maskValue(item, masking, depth + 1));
	const record = value as Record<string, unknown>;
	const approval = record.kind === "approval" && typeof record.id === "string";
	const own = approval ? { hidden: false } : masking;
	// No prototype: a key `__proto__` stays a key.
	const out: Record<string, unknown> = Object.create(null);
	for (const [key, item] of Object.entries(record)) {
		const name = maskKeys(key);
		if (name !== key) own.hidden = true;
		out[name] = maskValue(item, own, depth + 1);
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
 * A line for the log saying what a request did, by its method and parameters: the conversation or project it names, by
 * name. An issue that lets a device send a new request adds its line here (12.1). Never the text of a message, which
 * may hold anything.
 */
export function summarize(given: string, params: Params): string {
	const method = loggedMethod(given);
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
		"conversation.rename": () => `Renamed a conversation to “${String(params.title ?? "")}”`,
		"conversation.delete": () => `Deleted${inConversation}`,
		"conversation.configure": () => `Changed the settings of${inConversation || " a conversation"}`,
		"inbox.decide": () => `Answered an approval: ${["once", "always", "rule", "deny"].includes(params.decision as string) ? String(params.decision) : "?"}`,
		"inbox.answer": () => "Answered a question",
		"needs.answer": () => `Answered under Needs you${inProject}`,
		"agents.allowEverything": () => `Turned Allow everything ${params.on === true ? "on" : "off"}`,
		"agents.save": () => "Changed an agent's settings",
		"github.merge": () => `Merged #${String(params.number)}${inProject}`,
		"github.settle": () => `Marked a write ${params.happened === true ? "done" : "not done"}${inProject}`,
		"work.act": () => `${clip(String(params.action ?? "Acted on"), 24)} work #${clip(String(params.id), 12)}${inProject}`,
		"devices.forgetSelf": () => "Unpaired itself",
		pair: () => "Paired",
		attach: () => "Attached",
		resume: () => "Resumed",
		suspend: () => "Suspended",
	};
	return clip(maskKeys(lines[method]?.() ?? `${method}${inConversation}${inProject}`), MAX_SUMMARY);
}

/** At most `max` characters of `text`, with an ellipsis where it was cut. */
const clip = (text: string, max: number) => (text.length <= max ? text : `${text.slice(0, max - 1)}…`);

/** What the log may name, beside the requests the device lists place. */
const LOG_OWN = new Set(["pair", "attach", "resume", "suspend", "unknown"]);
/** The entries one device's flood cannot push out: they stay their 90 days. */
const LOG_KEPT = new Set(["pair", "suspend"]);
const MAX_METHOD = 64;
const MAX_SUMMARY = 200;
const MAX_WHY = 200;
/** Each device's share of the log, so that one device cannot push out another's entries (5 devices, 10,000 in all). */
const MAX_PER_DEVICE = MAX_LOG / MAX_DEVICES;
/** Refusals of the same request for the same reason, from the same device and path, within this, are one entry. */
const COALESCE_MS = 60_000;

/** How long new entries wait in memory before they are written together. */
const FLUSH_MS = 2_000;
/** Entries made and not yet written: the next write takes them all, at most FLUSH_MS after the first. */
const pendingLog: DeviceLogEntry[] = [];
/**
 * The refusal entries made this last minute, by device, path, method and why, with how many like them came since and
 * are not yet written. While its entry waits in `pendingLog`, a repeat adds to the entry itself.
 */
const refusalsMade = new Map<string, { entry: DeviceLogEntry; more: number; lastAt: number }>();
let flushTimer: ReturnType<typeof setTimeout> | undefined;
let flushing: Promise<void> = Promise.resolve();

/** Writes what waits in memory, in one commit, after any write already under way. */
export function flushDeviceLog(): Promise<void> {
	clearTimeout(flushTimer);
	flushTimer = undefined;
	flushing = flushing.then(writePending, writePending);
	return flushing;
}

async function writePending(): Promise<void> {
	const entries = pendingLog.splice(0);
	const counts = [...refusalsMade.values()].filter((one) => one.more > 0 && !entries.includes(one.entry)).map((one) => ({ ...one }));
	for (const one of refusalsMade.values()) if (!entries.includes(one.entry)) one.more = 0;
	if (entries.length === 0 && counts.length === 0) return;
	const now = Date.now();
	await harness.commit(async (tx) => {
		const doc = await tx.doc(DeviceLog);
		for (const { entry, more, lastAt } of counts) {
			const stored = doc.entries.findLast((one) => one.at === entry.at && one.device === entry.device && one.path === entry.path && one.method === entry.method && one.why === entry.why && one.outcome === "refused");
			if (stored === undefined) continue;
			stored.count = (stored.count ?? 1) + more;
			stored.lastAt = lastAt;
		}
		let kept = [...doc.entries, ...entries].filter((one) => now - (one.lastAt ?? one.at) < KEPT);
		for (const device of new Set(entries.map((one) => one.device))) {
			const mine = kept.filter((one) => one.device === device && !LOG_KEPT.has(one.method));
			if (mine.length <= MAX_PER_DEVICE) continue;
			const dropped = new Set(mine.slice(0, mine.length - MAX_PER_DEVICE));
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
 * Adds an entry to the devices' log: its method one the engine knows, its summary and why masked and cut short. Each
 * device keeps its own newest 2,000 entries, so that no device pushes out another's, and its pairing and suspension stay
 * their 90 days.
 *
 * Off the request's path: a commit rewrites the whole log (some 6 MB full) and holds the engine's one thread while it
 * does, so entries wait in memory and are written together at most two seconds after the first. `urgent` writes them
 * at once, and resolves once they are stored: for what must outlive a crash (a pairing, a suspension and the refusal
 * that made it, a request that widens). A clean stop writes what waits (`flushDeviceLog`). A refusal like one of the
 * device's from the last minute adds to that entry's `count` instead of making one.
 */
export async function logDevice(entry: Omit<DeviceLogEntry, "at"> & { at?: number }, urgent = false): Promise<void> {
	if (unreadable !== null) return;
	const at = entry.at ?? Date.now();
	const method = loggedMethod(entry.method);
	const why = entry.why === undefined ? undefined : clip(maskKeys(entry.why), MAX_WHY);
	const made: DeviceLogEntry = { ...entry, at, method, summary: clip(maskKeys(entry.summary), MAX_SUMMARY), ...(why === undefined ? {} : { why }) };
	const key = JSON.stringify([made.device, made.path, made.method, made.why ?? null]);
	const known = made.outcome === "refused" ? refusalsMade.get(key) : undefined;
	if (known !== undefined && at - known.entry.at < COALESCE_MS) {
		if (pendingLog.includes(known.entry)) {
			known.entry.count = (known.entry.count ?? 1) + 1;
			known.entry.lastAt = at;
		} else {
			known.more += 1;
			known.lastAt = at;
		}
	} else {
		if (made.outcome === "refused") {
			for (const [old, one] of refusalsMade) if (at - one.entry.at >= COALESCE_MS && one.more === 0) refusalsMade.delete(old);
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
	for (const one of refusalsMade.values()) {
		if (one.more === 0) continue;
		const entry = stored.findLast((e) => e.at === one.entry.at && e.device === one.entry.device && e.method === one.entry.method && e.why === one.entry.why && e.outcome === "refused");
		if (entry === undefined) continue;
		entry.count = (entry.count ?? 1) + one.more;
		entry.lastAt = one.lastAt;
	}
	const entries = [...stored, ...pendingLog.map((entry) => ({ ...entry }))];
	return entries.filter((entry) => (device === null || entry.device === device) && (before === undefined || entry.at < before)).slice(-count).reverse();
}

// ---- What the person at the Mac is told (4.4)

type Notice = { kind: "claim" | "paired" | "widening" | "suspended"; device: string | null; text: string; at: number };

/** The connections the engine took for the app that asked for the `devices` event: the app's alone (3.3). */
const watchers = new Set<Client>();
let window: PairingWindow | null = null;
let closed: { why: string; at: number } | null = null;

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
 * sequence (a zero-width joiner) or a right-to-left mark can still pair.
 */
const NOT_SHOWN = /[\p{Cc}\u200B-\u200F\u202A-\u202E\u2066-\u2069\uFEFF]/gu;
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

export const SECOND_CLAIM = "Another device tried to use this code. Start again, and don't show the code on a shared or recorded screen.";
const NO_WINDOW = "No pairing is open on this Mac.";

/** Closes the join window, for `why`, refusing a claim that waits; the secret is gone with it. */
function closeWindow(why: string | null): void {
	const open = window;
	if (open === null) return;
	window = null;
	clearTimeout(open.timer);
	open.secret.fill(0);
	if (open.claim !== null) remoteHooks.toHelper({ kind: "pairRefused", claim: open.claim.id, why: why ?? "The pairing was closed on the Mac." });
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

	const replaces = activeDevices().find((one) => one.name === device.name && one.model === device.model)?.id ?? null;
	return {
		id: `claim_${randomBytes(12).toString("base64url")}`,
		at: Date.now(),
		path: params.path,
		device: device as ClaimedDevice,
		attestKeyId: claim.keyId as string,
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
		remoteHooks.toHelper({ kind: "pairRefused", claim: claim.id, why: "The Mac could not save the pairing. Start again." });
		throw error;
	} finally {
		saving -= 1;
		remoteHooks.changed();
	}
	if (replaced !== null) {
		remoteHooks.toHelper({ kind: "revoke", device: replaced });
		remoteHooks.closeSessions(replaced, "replaced");
	}
	remoteHooks.toHelper({
		kind: "paired",
		claim: claim.id,
		device: { id: device.id, deviceKey: device.deviceKey, presenceKey: device.presenceKey, channelKey: device.channelKey, recordKey: device.recordKey, attestKeyId: device.attestKeyId },
		paired: { device: device.id, pairing: state.pairing, name: macName(), addresses },
	});
	await logDevice({ device: device.id, path: claim.path, method: "pair", summary: summarize("pair", {}), presence: false, outcome: "done" }, true);
	notify("paired", device.id, `${device.name} was paired with this Mac.`);
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

async function revoke(id: string): Promise<void> {
	const device = pairedDevice(id);
	if (device === undefined) throw new Error("No such device is paired.");
	await change((doc) => {
		for (const one of doc.devices) if (one.id === id) forget(one, Date.now());
	});
	failures.delete(id);
	// `revoke` first: pi² Remote sends the phone its signed `revoked` line on the channel, which closing the sessions
	// next would otherwise have ended (3.6).
	remoteHooks.toHelper({ kind: "revoke", device: id });
	remoteHooks.closeSessions(id, "revoked");
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

/** Refused presence signatures and attaches, by device: five in ten minutes suspend it (3.6, 4.5). */
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
	try {
		await logDevice({ device: device.id, path, method, summary: summarize(method, params), presence: false, outcome: "refused", why });
	} catch (error) {
		log("devices: the log could not be written:", error instanceof Error ? error.message : error);
	}
	if (recent.length >= SUSPEND_AFTER && device.suspendedAt === null) await suspend(device, path);
}

/** What no key of the device's signed: a line in engine.log, at most once a minute for each device, and nothing else. */
const unsignedSaid = new Map<string, number>();
function unsigned(device: string, what: string): void {
	const now = Date.now();
	if (now - (unsignedSaid.get(device) ?? 0) < 60_000) return;
	unsignedSaid.set(device, now);
	log(`devices: refused ${what} for ${device} not signed by its device key (said once a minute)`);
}

async function suspend(device: Device, path: DevicePath): Promise<void> {
	await change((doc) => {
		for (const one of doc.devices) if (one.id === device.id && one.revokedAt === null) one.suspendedAt = Date.now();
	});
	failures.delete(device.id);
	remoteHooks.closeSessions(device.id, "suspended");
	const why = `${SUSPEND_AFTER} refused presence signatures or attaches in ten minutes`;
	await logDevice({ device: device.id, path, method: "suspend", summary: summarize("suspend", {}), presence: false, outcome: "done", why }, true);
	notify("suspended", device.id, `${device.name} was suspended after ${why}. Resume it on the Devices page if it was you.`);
}

export type Attached = { device: Device; path: Exclude<DevicePath, "mailbox">; session: string | null };

/**
 * Checks an attach or a resume (`remote.attach`, 3.4) as the engine's own: the device paired, not revoked or suspended,
 * of a build at or above the minimum; both signatures, the device key's and the presence key's, over the same text,
 * against the engine's own record; the challenge one this engine issued, used once; the binding this channel's; `at`
 * within two minutes. Each refusal of a known device counts towards its suspension and is logged.
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
	if (device.suspendedAt !== null) throw new Error("This device is suspended. Resume it on the Mac's Devices page.");
	const method = signed.session === null ? "attach" : "resume";
	const refuse = async (why: string): Promise<never> => {
		await refused(device, path, method, why);
		throw new Error(why);
	};
	const text = attach.signed as string;
	// Until the device key proved the attach is the device's, nothing is counted against it (pi² Remote checks the same
	// signature first, 3.4, so only a faulty one sends such an attach).
	if (!signedBy(text, attach.signature, p256Key(device.deviceKey)!)) {
		unsigned(device.id, "an attach");
		throw new Error("The attach is not signed by the device key.");
	}
	const presenceKey = device.presenceKey === null ? null : p256Key(device.presenceKey);
	if (presenceKey === null) return refuse("This device's Face ID key waits to be accepted on the Mac.");
	if (!signedBy(text, attach.presence, presenceKey)) return refuse("The attach's presence signature is not the presence key's.");
	if (typeof signed.challenge !== "string" || !takeChallenge(signed.challenge)) return refuse("The attach's challenge is not one this Mac issued, or was used.");
	if (typeof signed.pairing !== "string" || state.pairing === null || !sameText(signed.pairing, state.pairing)) return refuse("The attach is for another pairing.");
	if (typeof signed.binding !== "string" || fromBase64url(params.binding, 32) === null || !sameText(signed.binding, params.binding as string)) {
		return refuse("The attach was signed for another channel.");
	}
	if (typeof signed.at !== "number" || !Number.isSafeInteger(signed.at) || Math.abs(Date.now() - signed.at) > AT_WITHIN) return refuse("The attach's time is more than two minutes from the Mac's.");
	if (signed.session !== null && (typeof signed.session !== "string" || !/^[A-Za-z0-9_-]{1,64}$/.test(signed.session))) return refuse("The attach names no session.");
	if (!buildText(signed.build)) return refuse("The attach names no build.");
	if (!buildAtLeast(signed.build, MINIMUM_PHONE_BUILD)) throw new Error("This build of pi² for iPhone is too old for this Mac. Update it.");
	const build = signed.build;
	await change((doc) => {
		for (const one of doc.devices) {
			if (one.id !== device.id) continue;
			one.lastSeenAt = Date.now();
			one.lastPath = path;
			one.build = build;
		}
	});
	return { device: pairedDevice(device.id)!, path, session: signed.session as string | null };
}

/** An attach or resume taken, in the log (4.4). */
export async function attachTaken(device: string, path: DevicePath, resumed: boolean): Promise<void> {
	const method = resumed ? "resume" : "attach";
	await logDevice({ device, path, method, summary: summarize(method, {}), presence: true, outcome: "done" });
}

// ---- Sealed items from the mailbox (4.3, 5.3)

const ITEM_FIELDS = ["v", "kind", "pairing", "device", "method", "params", "nonce", "at"] as const;
export const ITEM_TOO_OLD = "Not sent: more than a day passed before your Mac saw it.";
export const ITEM_TOO_OLD_FACE = "Not sent: more than an hour passed before your Mac saw it.";

/**
 * Checks a request a device sealed into the mailbox, once opened by pi² Remote, before it is handled
 * (remote.mailboxIn, #678, calls this): remote access on; the device paired and not suspended; first its form and the
 * device key's signature over the exact `signed` text, before anything is written or counted, since the relay, which
 * the contract does not trust, can hand pi² Remote any item "from" a device; then, logged and counted, the presence
 * key's signature, that the request is the one signed, for this pairing, its row of the device's table allowing the
 * mailbox, `at` at most a day old (an hour for one that widens) and not ahead of the Mac's clock by more than five
 * minutes, and its nonce never taken before, stored before this answers, after a restart too.
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
	const refuse = async (why: string, method = String(request.method)): Promise<never> => {
		try {
			await logDevice({ device, path: "mailbox", method, summary: summarize(method, request.params as Params), presence: false, outcome: "refused", why });
		} catch (error) {
			log("devices: the log could not be written:", error instanceof Error ? error.message : error);
		}
		throw new Error(why);
	};
	const presenceKey = record.presenceKey === null ? null : p256Key(record.presenceKey);
	if (presenceKey === null || !signedBy(item.signed as string, item.presence, presenceKey)) {
		await refused(record, "mailbox", String(request.method), "The item's presence signature is not the presence key's.", request.params as Params);
		throw new Error("The item's presence signature is not the presence key's.");
	}
	if (signed.device !== device || typeof signed.pairing !== "string" || state.pairing === null || !sameText(signed.pairing, state.pairing)) return refuse("The item is for another device or pairing.");
	if (signed.method !== request.method || JSON.stringify(signed.params) !== JSON.stringify(request.params)) return refuse("The item's request is not the one signed.");
	const method = request.method;
	const params = request.params as Params;
	const answer = deviceMay(method, params, { path: "mailbox", ...approvals });
	if (answer === "no") return refuse(ONLY_ON_THE_MAC);
	const nonce = signed.nonce;
	if (fromBase64url(nonce, 16) === null) return refuse("The item's nonce is not one.");
	const at = signed.at;
	if (typeof at !== "number" || !Number.isSafeInteger(at) || at > now + ITEM_AHEAD) return refuse("The item's time is ahead of the Mac's.");
	if (now - at > (answer === "face" ? 3_600_000 : DAY)) return refuse(answer === "face" ? ITEM_TOO_OLD_FACE : ITEM_TOO_OLD);
	let replayed = false;
	await harness.commit(async (tx) => {
		const doc = await tx.doc(DeviceNonces);
		const key = `${device}:${nonce as string}`;
		if (Object.hasOwn(doc.taken, key)) replayed = true;
		else doc.taken[key] = now;
		for (const [taken, when] of Object.entries(doc.taken)) if (now - when > NONCES_KEPT) delete doc.taken[taken];
	}, context);
	if (replayed) return refuse("The item was taken before.");
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
		if (address !== undefined && (typeof address !== "string" || !relayAddress(address))) throw new Error("The relay's address is wss://host/path.");
		await change((doc) => {
			for (const key of switches) if (typeof params[key] === "boolean") doc.remote[key] = params[key] as boolean;
			if (typeof address === "string") doc.relay = address;
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

/** A relay's address: wss:// anywhere; ws:// only to this Mac, and only in a development engine (iphone.md 10). */
function relayAddress(text: string): boolean {
	let url: URL;
	try {
		url = new URL(text);
	} catch {
		return false;
	}
	if (url.protocol === "wss:") return url.hostname !== "" && url.search === "" && url.hash === "";
	return !release && url.protocol === "ws:" && ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname);
}
