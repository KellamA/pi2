// App Attest's verifier (#672, src/appattest.ts) against Apple's own: the root it pins is the one Apple publishes, and
// Apple's sample attestation passes (fixtures in appattest.json, each with where it came from and its SHA-256); then
// the same sample altered one thing at a time, each refused at the check that should refuse it: the caller's team, app,
// key, client data, environment and time; the counter, the aaguid, the key and the extensions in the authenticator
// data; the certificates swapped, dropped, added and re-signed; a whole chain forged under a root of the test's own,
// with Apple's names, and one whose leaf is signed by a key of the test's own under Apple's real intermediate; CBOR in
// forms App Attest does not make. Then fuzzing: every truncation, every byte changed, and random edits, of the
// attestation and of its leaf certificate, all refused but changes inside the receipt, which is passed on unchecked.
//
// Last, that the file runs unchanged in a Cloudflare Worker: it is type-checked with Web Worker types and no Node
// types, and run, in a child process, as a module in a context holding only the Web globals Workers have, where any
// import is refused; the same harness is shown to catch a `node:` import and a Node global.

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash, KeyObject, X509Certificate } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
import { tmpdir } from "node:os";
import { join } from "node:path";
import vm from "node:vm";
import {
	APPLE_APP_ATTEST_ROOT,
	APPLE_APP_ATTEST_ROOT_SHA256,
	AppAttestError,
	type AppAttestExpected,
	type AppAttestReason,
	verifyAttestation,
} from "../src/appattest.ts";

const WORKER_CONTEXT = "--in-a-workers-context";
const SOURCE = join(import.meta.dirname, "..", "src", "appattest.ts");

type Sample = {
	name: string;
	attestationSha256: string;
	teamId: string;
	bundleId: string;
	clientDataHash: string;
	keyId: string;
	environment: "production" | "development";
	leafValid: [string, string];
	expected: { nonce: string; rpIdHash: string; validationCategory: number; bundleVersion: string; receiptLength: number };
	attestation: string;
};
type Fixture = { root: { pem: string; pemSha256: string; derSha256: string }; samples: Sample[] };

const fixture = JSON.parse(readFileSync(join(import.meta.dirname, "appattest.json"), "utf8")) as Fixture;

function step(name: string): void {
	console.log(`ok  ${name}`);
}

const sha256 = (bytes: Uint8Array | string) => new Uint8Array(createHash("sha256").update(bytes).digest());
const hex = (bytes: Uint8Array) => Buffer.from(bytes).toString("hex");
const base64 = (text: string) => new Uint8Array(Buffer.from(text, "base64"));
const utf8 = (text: string) => new TextEncoder().encode(text);
const concat = (...parts: Uint8Array[]): Uint8Array<ArrayBuffer> => Uint8Array.from(Buffer.concat(parts));

/** What a sample expects, at a time inside its leaf's dates. */
function expectationsOf(sample: Sample): AppAttestExpected {
	const [from, until] = sample.leafValid.map(Date.parse);
	return {
		teamId: sample.teamId,
		bundleId: sample.bundleId,
		keyId: base64(sample.keyId),
		clientDataHash: utf8(sample.clientDataHash),
		environments: [sample.environment],
		now: (from + until) / 2,
	};
}

/** The reason `attestation` is refused for, or null if it passes. */
async function outcome(attestation: Uint8Array, expected: AppAttestExpected): Promise<AppAttestReason | null> {
	try {
		await verifyAttestation(attestation, expected);
		return null;
	} catch (error) {
		if (error instanceof AppAttestError) return error.reason;
		throw error;
	}
}

async function refused(attestation: Uint8Array, expected: AppAttestExpected, reason: AppAttestReason, what: string): Promise<void> {
	assert.equal(await outcome(attestation, expected), reason, what);
	step(`${what}: refused (${reason})`);
}

// CBOR, to build attestations again with one thing changed: shortest heads, entries in the order given.

type Value = number | string | Uint8Array | Value[] | [Value, Value][] | { raw: Uint8Array };

function head(major: number, argument: number): Uint8Array {
	if (argument < 24) return Uint8Array.of((major << 5) | argument);
	if (argument < 0x100) return Uint8Array.of((major << 5) | 24, argument);
	if (argument < 0x10000) return Uint8Array.of((major << 5) | 25, argument >> 8, argument & 0xff);
	return Uint8Array.of((major << 5) | 26, argument >>> 24, (argument >> 16) & 0xff, (argument >> 8) & 0xff, argument & 0xff);
}

function cbor(value: Value): Uint8Array {
	if (typeof value === "number") return value >= 0 ? head(0, value) : head(1, -1 - value);
	if (typeof value === "string") return concat(head(3, utf8(value).length), utf8(value));
	if (value instanceof Uint8Array) return concat(head(2, value.length), value);
	if ("raw" in value) return value.raw;
	if (isMap(value)) return concat(head(5, value.length), ...value.flatMap(([key, item]) => [cbor(key), cbor(item)]));
	return concat(head(4, value.length), ...value.map(cbor));
}

/** A map is written as a list of pairs tagged by this. */
const MAPS = new WeakSet<object>();
function map(...entries: [Value, Value][]): [Value, Value][] {
	MAPS.add(entries);
	return entries;
}
function isMap(value: Value[] | [Value, Value][]): value is [Value, Value][] {
	return MAPS.has(value);
}

type Parts = { fmt: string; x5c: Uint8Array[]; receipt: Uint8Array; authData: Uint8Array };

function attestationOf(parts: Parts): Uint8Array {
	return cbor(map(["fmt", parts.fmt], ["attStmt", map(["x5c", parts.x5c], ["receipt", parts.receipt])], ["authData", parts.authData]));
}

// The sample's parts, read with the test's own small reader rather than the verifier's.
function partsOf(attestation: Uint8Array): Parts & { receiptAt: number } {
	let at = 0;
	const read = (): { major: number; argument: number; start: number } => {
		const start = at;
		const initial = attestation[at++];
		const info = initial & 31;
		let argument = info;
		if (info >= 24) {
			const size = 1 << (info - 24);
			argument = 0;
			for (let i = 0; i < size; i++) argument = argument * 256 + attestation[at++];
		}
		return { major: initial >> 5, argument, start };
	};
	const bytes = () => {
		const { argument } = read();
		at += argument;
		return { value: attestation.slice(at - argument, at), start: at - argument };
	};
	const text = () => new TextDecoder().decode(bytes().value);
	assert.equal(read().argument, 3);
	assert.equal(text(), "fmt");
	const fmt = text();
	assert.equal(text(), "attStmt");
	assert.equal(read().argument, 2);
	assert.equal(text(), "x5c");
	const count = read().argument;
	const x5c = Array.from({ length: count }, () => bytes().value);
	assert.equal(text(), "receipt");
	const receipt = bytes();
	assert.equal(text(), "authData");
	const authData = bytes().value;
	assert.equal(at, attestation.length);
	return { fmt, x5c, receipt: receipt.value, authData, receiptAt: receipt.start };
}

// DER, to take certificates apart and make new ones.

function der(tag: number, ...contents: Uint8Array[]): Uint8Array<ArrayBuffer> {
	const content = concat(...contents);
	const length = content.length;
	const lengthBytes =
		length < 0x80 ? Uint8Array.of(length) : length < 0x100 ? Uint8Array.of(0x81, length) : Uint8Array.of(0x82, length >> 8, length & 0xff);
	return concat(Uint8Array.of(tag), lengthBytes, content);
}

/** The elements inside the one element `bytes` holds, each whole. */
function inside(bytes: Uint8Array): Uint8Array[] {
	const element = (at: number) => {
		let length = bytes[at + 1];
		let start = at + 2;
		if (length & 0x80) {
			const size = length & 0x7f;
			length = 0;
			for (let i = 0; i < size; i++) length = length * 256 + bytes[start + i];
			start += size;
		}
		return { start, end: start + length };
	};
	const outer = element(0);
	const found: Uint8Array[] = [];
	for (let at = outer.start; at < outer.end; ) {
		const { end } = element(at);
		found.push(bytes.slice(at, end));
		at = end;
	}
	return found;
}

/** A positive INTEGER from big-endian bytes, as DER writes it. */
function integer(bytes: Uint8Array): Uint8Array {
	let start = 0;
	while (start < bytes.length - 1 && bytes[start] === 0) start++;
	const value = bytes.slice(start);
	return der(0x02, value[0] & 0x80 ? concat(Uint8Array.of(0), value) : value);
}

const NONCE_OID = Uint8Array.of(0x2a, 0x86, 0x48, 0x86, 0xf7, 0x63, 0x64, 0x08, 0x02);

/** `certificate` with its key and, for a leaf, its nonce replaced, signed again by `signer` with its own algorithm. */
async function reissue(certificate: Uint8Array, spki: Uint8Array, signer: CryptoKey, nonce?: Uint8Array): Promise<Uint8Array> {
	const [tbs, algorithm] = inside(certificate);
	const fields = inside(tbs);
	if (nonce !== undefined) {
		const list = inside(inside(fields[7])[0]);
		const replaced = list.map((extension) =>
			hex(inside(extension)[0]).includes(hex(NONCE_OID))
				? der(0x30, der(0x06, NONCE_OID), der(0x04, der(0x30, der(0xa1, der(0x04, nonce)))))
				: extension,
		);
		fields[7] = der(0xa3, der(0x30, ...replaced));
	}
	fields[6] = spki;
	const newTbs = der(0x30, ...fields);
	// ecdsa-with-SHA384 ends 04 03 03, ecdsa-with-SHA256 04 03 02.
	const hash = hex(algorithm).endsWith("040303") ? "SHA-384" : "SHA-256";
	const raw = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash }, signer, newTbs));
	const half = raw.length / 2;
	const signature = der(0x30, integer(raw.slice(0, half)), integer(raw.slice(half)));
	return der(0x30, newTbs, algorithm, der(0x03, Uint8Array.of(0), signature));
}

const ecdsa = (namedCurve: "P-256" | "P-384") =>
	crypto.subtle.generateKey({ name: "ECDSA", namedCurve }, true, ["sign", "verify"]) as Promise<CryptoKeyPair>;
const spkiOf = async (key: CryptoKey) => new Uint8Array(await crypto.subtle.exportKey("spki", key));

/** A seeded generator, so that a failing case can be run again. */
function random(seed: number): () => number {
	let state = seed >>> 0;
	return () => {
		state = (state + 0x6d2b79f5) >>> 0;
		let t = state;
		t = Math.imul(t ^ (t >>> 15), t | 1);
		t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
		return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
	};
}

async function main(): Promise<void> {
	// The pinned root is Apple's, byte for byte.
	const pem = fixture.root.pem;
	assert.equal(hex(sha256(pem)), fixture.root.pemSha256, "the fixture's PEM is the one recorded");
	const rootDer = base64(pem.replace(/-----(BEGIN|END) CERTIFICATE-----/g, "").replace(/\s/g, ""));
	assert.equal(hex(sha256(rootDer)), fixture.root.derSha256);
	assert.equal(APPLE_APP_ATTEST_ROOT_SHA256, fixture.root.derSha256);
	assert.deepEqual(base64(APPLE_APP_ATTEST_ROOT), rootDer, "the verifier pins the root Apple publishes");
	const rootCertificate = new X509Certificate(rootDer);
	assert.match(rootCertificate.subject, /CN=Apple App Attestation Root CA/);
	assert.ok(rootCertificate.verify(rootCertificate.publicKey), "the root is self-signed");
	step("the pinned root is Apple's App Attestation Root CA, by its bytes and SHA-256");

	for (const sample of fixture.samples) {
		const attestation = base64(sample.attestation);
		assert.equal(hex(sha256(attestation)), sample.attestationSha256);
		const expected = expectationsOf(sample);
		const result = await verifyAttestation(attestation, expected);
		assert.equal(result.environment, sample.environment);
		assert.deepEqual(sha256(result.publicKey), base64(sample.keyId), "the key returned is the one the key id names");
		assert.equal(result.validationCategory, sample.expected.validationCategory);
		assert.equal(result.bundleVersion, sample.expected.bundleVersion);
		assert.equal(result.receipt.length, sample.expected.receiptLength);
		const parts = partsOf(attestation);
		assert.deepEqual(parts.authData.slice(0, 32), base64(sample.expected.rpIdHash));
		assert.deepEqual(sha256(concat(parts.authData, utf8(sample.clientDataHash))), base64(sample.expected.nonce));
		// And at the first and the last second of the leaf's dates.
		for (const edge of sample.leafValid) assert.equal(await outcome(attestation, { ...expected, now: Date.parse(edge) }), null);
		step(`${sample.name}: passes, with its key, environment, category, version and receipt`);
	}

	const sample = fixture.samples[0];
	const attestation = base64(sample.attestation);
	const expected = expectationsOf(sample);
	const parts = partsOf(attestation);
	const [from, until] = sample.leafValid.map(Date.parse);

	// What the caller expects, not met.
	await refused(attestation, { ...expected, teamId: "1234567891" }, "app-id", "another team");
	await refused(attestation, { ...expected, bundleId: "com.example.otherapp" }, "app-id", "another app");
	await refused(attestation, { ...expected, environments: ["development"] }, "environment", "a production key where development is taken");
	const otherKey = base64(sample.keyId);
	otherKey[0] ^= 1;
	await refused(attestation, { ...expected, keyId: otherKey }, "key-id", "another key id");
	await refused(attestation, { ...expected, clientDataHash: utf8("example_server_challengf") }, "nonce", "other client data");
	await refused(attestation, { ...expected, clientDataHash: sha256(sample.clientDataHash) }, "nonce", "the client data's SHA-256 in place of what was attested");
	await refused(attestation, { ...expected, now: from - 1000 }, "not-yet-valid", "a second before the leaf is valid");
	await refused(attestation, { ...expected, now: until + 1000 }, "expired", "a second after the leaf expires");
	await refused(attestation, { ...expected, now: undefined }, "expired", "now, long after the leaf expired");
	await refused(attestation, { ...expected, teamId: "abcdefghij" }, "options", "a team id that is not one");
	await refused(attestation, { ...expected, keyId: new Uint8Array(31) }, "options", "a key id of 31 bytes");
	await refused(attestation, { ...expected, clientDataHash: new Uint8Array(0) }, "options", "empty client data");
	await refused(attestation, { ...expected, environments: [] }, "options", "no environment taken");

	// The authenticator data altered. The field checks come before the nonce, so each fails at its own.
	const altered = (offset: number, bytes: number[]) => {
		const authData = parts.authData.slice();
		authData.set(bytes, offset);
		return attestationOf({ ...parts, authData });
	};
	await refused(altered(0, [parts.authData[0] ^ 1]), expected, "app-id", "the RP ID hash changed");
	await refused(altered(33, [0, 0, 0, 1]), expected, "counter", "a counter of 1");
	await refused(altered(33, [0x80, 0, 0, 0]), expected, "counter", "a counter of 2^31");
	const development = [...utf8("appattestdevelop")];
	await refused(altered(37, development), expected, "environment", "a development aaguid where production is taken");
	await refused(altered(37, development), { ...expected, environments: ["development"] }, "nonce", "a development aaguid taken, but not the one attested");
	await refused(altered(37, [...utf8("appattest"), 0, 0, 0, 0, 0, 0, 1]), { ...expected, environments: ["production", "development"] }, "environment", "an aaguid of neither environment");
	await refused(altered(55, [parts.authData[55] ^ 1]), { ...expected }, "key-id", "the credential id changed");
	await refused(altered(97, [parts.authData[97] ^ 1]), expected, "key-id", "the COSE key's x changed");
	await refused(altered(32, [0x41]), expected, "nonce", "a flag added");
	await refused(altered(32, [0x00]), expected, "malformed", "the attested-data flag taken away");
	await refused(altered(53, [0, 31]), expected, "malformed", "a credential id length of 31");
	const version = parts.authData.indexOf(0x61, parts.authData.length - 40);
	assert.equal(parts.authData[version + 1], 0x31, "the bundle version is where the test thinks");
	await refused(altered(version + 1, [0x32]), expected, "nonce", "the bundle version changed");
	await refused(attestationOf({ ...parts, authData: parts.authData.slice(0, 164) }), expected, "nonce", "the extensions taken out");
	await refused(attestationOf({ ...parts, authData: concat(parts.authData, Uint8Array.of(0)) }), expected, "malformed", "a byte after the extensions");
	await refused(attestationOf({ ...parts, authData: concat(parts.authData.slice(0, 164), cbor(map(["apple_validation_category_01", 1]))) }), expected, "malformed", "a validation category that is not four bytes");
	await refused(attestationOf({ ...parts, authData: concat(parts.authData.slice(0, 87), cbor(map([1, 2], [3, -7], [-1, 2], [-2, parts.authData.slice(97, 129)], [-3, parts.authData.slice(132, 164)])), parts.authData.slice(164)) }), expected, "malformed", "a COSE key on another curve");

	// The attestation's structure altered.
	const [leaf, intermediate] = parts.x5c;
	await refused(attestationOf({ ...parts, fmt: "packed" }), expected, "malformed", "another format");
	await refused(attestationOf({ ...parts, x5c: [leaf] }), expected, "malformed", "the leaf alone");
	await refused(attestationOf({ ...parts, x5c: [leaf, intermediate, rootDer] }), expected, "malformed", "the root added");
	await refused(attestationOf({ ...parts, x5c: [intermediate, leaf] }), expected, "root", "the two certificates swapped");
	await refused(attestationOf({ ...parts, x5c: [leaf, leaf] }), expected, "root", "the leaf twice");
	await refused(attestationOf({ ...parts, x5c: [leaf, rootDer] }), expected, "chain", "the root in the intermediate's place");
	await refused(attestationOf({ ...parts, receipt: new Uint8Array(0) }), expected, "malformed", "an empty receipt");
	await refused(cbor(map(["fmt", "apple-appattest"], ["attStmt", map(["x5c", parts.x5c])], ["authData", parts.authData])), expected, "malformed", "no receipt");
	await refused(cbor(map(["fmt", "apple-appattest"], ["attStmt", map(["x5c", parts.x5c], ["receipt", parts.receipt])], ["authData", parts.authData], ["more", 1])), expected, "malformed", "a key added");
	await refused(cbor(map(["attStmt", map(["x5c", parts.x5c], ["receipt", parts.receipt])], ["fmt", "apple-appattest"], ["authData", parts.authData])), expected, "malformed", "keys out of order");
	await refused(cbor(map(["fmt", "apple-appattest"], ["fmt", "apple-appattest"], ["authData", parts.authData])), expected, "malformed", "a key twice");
	await refused(cbor(map(["fmt", "apple-appattest"], ["attStmt", map(["x5c", parts.x5c], ["receipt", parts.receipt])], ["authData", "text"])), expected, "malformed", "authData as text");
	await refused(cbor(map(["fmt", "apple-appattest"], ["attStmt", map(["x5c", parts.x5c], ["receipt", parts.receipt])], ["authData", { raw: concat(Uint8Array.of(0x5a, 0, 0, 0, parts.authData.length), parts.authData) }])), expected, "malformed", "a length in a longer head than it needs");
	await refused(concat(Uint8Array.of(0xd8, 0x18), attestation), expected, "malformed", "the attestation in a tag");
	await refused(cbor(map(["fmt", "apple-appattest"], ["attStmt", map(["x5c", { raw: concat(Uint8Array.of(0x9f), cbor(leaf), cbor(intermediate), Uint8Array.of(0xff)) }], ["receipt", parts.receipt])], ["authData", parts.authData])), expected, "malformed", "an array of indefinite length");
	await refused(concat(attestation, Uint8Array.of(0)), expected, "malformed", "a byte after the attestation");
	await refused(concat(attestation, new Uint8Array(32 * 1024)), expected, "malformed", "an attestation larger than App Attest makes");

	// The certificates' signatures altered.
	const flipLast = (bytes: Uint8Array) => {
		const copy = bytes.slice();
		copy[copy.length - 1] ^= 1;
		return copy;
	};
	await refused(attestationOf({ ...parts, x5c: [flipLast(leaf), intermediate] }), expected, "chain", "the leaf's signature changed");
	await refused(attestationOf({ ...parts, x5c: [leaf, flipLast(intermediate)] }), expected, "root", "the intermediate's signature changed");

	// A whole chain forged, with Apple's names and dates, under a root of the test's own; the forgery is checked to be a
	// well-made chain by Node's own X.509, so that the verifier's refusal is the pin's and nothing else's.
	const fakeRoot = await ecdsa("P-384");
	const fakeIntermediate = await ecdsa("P-384");
	const attested = await ecdsa("P-256");
	const point = (await spkiOf(attested.publicKey)).slice(-65);
	const forgedKeyId = sha256(point);
	const forgedAuthData = parts.authData.slice();
	forgedAuthData.set(forgedKeyId, 55);
	forgedAuthData.set(point.slice(1, 33), 97);
	forgedAuthData.set(point.slice(33), 132);
	const forgedNonce = sha256(concat(forgedAuthData, utf8(sample.clientDataHash)));
	const forgedIntermediate = await reissue(intermediate, await spkiOf(fakeIntermediate.publicKey), fakeRoot.privateKey);
	const forgedLeaf = await reissue(leaf, await spkiOf(attested.publicKey), fakeIntermediate.privateKey, forgedNonce);
	const nodeIntermediate = new X509Certificate(forgedIntermediate);
	const nodeLeaf = new X509Certificate(forgedLeaf);
	assert.ok(nodeIntermediate.verify(KeyObject.from(fakeRoot.publicKey)), "the forged intermediate is signed by the fake root");
	assert.ok(nodeLeaf.verify(nodeIntermediate.publicKey), "the forged leaf is signed by the forged intermediate");
	assert.ok(nodeLeaf.checkIssued(nodeIntermediate), "the forged leaf names the forged intermediate");
	assert.equal(nodeIntermediate.issuer, rootCertificate.subject, "the forged intermediate names Apple's root");
	const forgedExpected = { ...expected, keyId: forgedKeyId };
	await refused(attestationOf({ ...parts, x5c: [forgedLeaf, forgedIntermediate], authData: forgedAuthData }), forgedExpected, "root", "a whole chain forged under a root of the test's own, with Apple's names");
	const leafUnderApple = await reissue(leaf, await spkiOf(attested.publicKey), fakeIntermediate.privateKey, forgedNonce);
	await refused(attestationOf({ ...parts, x5c: [leafUnderApple, intermediate], authData: forgedAuthData }), forgedExpected, "chain", "a leaf of the test's own under Apple's real intermediate");
	// Apple's leaf, with the authenticator data of the test's own key: the leaf's key is not the one named.
	await refused(attestationOf({ ...parts, authData: forgedAuthData }), forgedExpected, "key-id", "Apple's leaf with another key's authenticator data");

	// Fuzzing. Every truncation of the attestation.
	for (let length = 0; length < attestation.length; length++) {
		assert.equal(await outcome(attestation.subarray(0, length), expected), "malformed", `truncated to ${length} bytes`);
	}
	step(`every truncation of the attestation (${attestation.length}): refused (malformed)`);

	// Every truncation of each certificate, in an attestation otherwise well formed.
	for (const [index, certificate] of parts.x5c.entries()) {
		for (let length = 0; length < certificate.length; length++) {
			const x5c = [...parts.x5c];
			x5c[index] = certificate.subarray(0, length);
			assert.equal(await outcome(attestationOf({ ...parts, x5c }), expected), "malformed", `certificate ${index} truncated to ${length} bytes`);
		}
	}
	step("every truncation of the leaf and of the intermediate: refused (malformed)");

	// Every byte changed, two ways. The receipt's own bytes are passed on unchecked, so a change there passes, and the
	// receipt returned is the changed one; every other change is refused.
	const receiptStart = parts.receiptAt;
	const receiptEnd = receiptStart + parts.receipt.length;
	let refusedChanges = 0;
	let receiptChanges = 0;
	const reasons = new Map<string, number>();
	for (let offset = 0; offset < attestation.length; offset++) {
		const inReceipt = offset >= receiptStart && offset < receiptEnd;
		if (inReceipt && offset % 97 !== 0) continue;
		for (const mask of [0x01, 0x80]) {
			const changed = attestation.slice();
			changed[offset] ^= mask;
			const reason = await outcome(changed, expected);
			if (inReceipt) {
				assert.equal(reason, null, `a change in the receipt at ${offset} is passed on`);
				const result = await verifyAttestation(changed, expected);
				assert.equal(result.receipt[offset - receiptStart], changed[offset]);
				receiptChanges++;
			} else {
				assert.notEqual(reason, null, `byte ${offset} changed with ${mask} passes`);
				reasons.set(reason as string, (reasons.get(reason as string) ?? 0) + 1);
				refusedChanges++;
			}
		}
	}
	step(`every byte outside the receipt changed two ways: ${refusedChanges} refused (${[...reasons].map(([reason, count]) => `${reason} ${count}`).join(", ")}); ${receiptChanges} changes in the receipt passed on as they are`);

	// Random edits outside the receipt: one to four bytes changed, the last edit perhaps a byte put in or taken out
	// instead (after which positions move, so it is the last).
	const next = random(672);
	const outside = (position: number) => position < receiptStart || position >= receiptEnd;
	for (let round = 0; round < 3000; round++) {
		const bytes = Array.from(attestation);
		const edits = 1 + Math.floor(next() * 4);
		let changed = false;
		for (let edit = 0; edit < edits; edit++) {
			const position = Math.floor(next() * bytes.length);
			if (!outside(position)) continue;
			const kind = Math.floor(next() * 3);
			const byte = Math.floor(next() * 256);
			if (kind === 0 && bytes[position] !== byte) {
				bytes[position] = byte;
				changed = true;
			} else if (kind === 1) {
				bytes.splice(position, 0, byte);
				changed = true;
			} else if (kind === 2) {
				bytes.splice(position, 1);
				changed = true;
			}
			if (kind !== 0) break;
		}
		if (!changed) continue;
		assert.notEqual(await outcome(Uint8Array.from(bytes), expected), null, `random round ${round} passes`);
	}
	step("3000 rounds of random edits outside the receipt: all refused");

	// Every byte of the leaf changed, in an attestation otherwise well formed: the CBOR stays right, so this reaches
	// the certificate's own reading and its signature.
	for (const [index, certificate] of parts.x5c.entries()) {
		for (let offset = 0; offset < certificate.length; offset++) {
			const x5c = [...parts.x5c];
			x5c[index] = certificate.slice();
			x5c[index][offset] ^= 0x01;
			assert.notEqual(await outcome(attestationOf({ ...parts, x5c }), expected), null, `certificate ${index} byte ${offset} changed passes`);
		}
	}
	step("every byte of the leaf and of the intermediate changed: all refused");

	await workersCompatible();
}

// That src/appattest.ts builds unchanged in a Cloudflare Worker (P8). Two proofs, neither by promise.
async function workersCompatible(): Promise<void> {
	// Type-checked with the Web Worker library and no Node types at all: a `node:` import or a Node global is an error.
	const folder = mkdtempSync(join(tmpdir(), "pi2-appattest-"));
	try {
		const tsc = join(import.meta.dirname, "..", "node_modules", ".bin", "tsc");
		const check = (file: string) => {
			const config = join(folder, "tsconfig.json");
			writeFileSync(
				config,
				JSON.stringify({
					compilerOptions: {
						target: "ES2023",
						module: "ESNext",
						moduleResolution: "bundler",
						strict: true,
						noEmit: true,
						noUnusedLocals: true,
						noUnusedParameters: true,
						lib: ["ES2023", "WebWorker"],
						types: [],
						skipLibCheck: true,
					},
					files: [file],
				}),
			);
			return spawnSync(tsc, ["-p", config], { encoding: "utf8" });
		};
		const good = check(SOURCE);
		assert.equal(good.status, 0, `src/appattest.ts with Web Worker types alone:\n${good.stdout}${good.stderr}`);
		const probe = join(folder, "probe.ts");
		writeFileSync(probe, 'import { createHash } from "node:crypto";\nexport const probe = () => [createHash, Buffer.from("x"), process.pid];\n');
		const bad = check(probe);
		assert.notEqual(bad.status, 0, "the same check refuses a Node import and Node globals");
		assert.match(bad.stdout, /node:crypto/);
		assert.match(bad.stdout, /Buffer/);
		assert.match(bad.stdout, /process/);
		step("src/appattest.ts type-checks with Web Worker types and no Node types, a check that refuses node:crypto, Buffer and process");
	} finally {
		rmSync(folder, { recursive: true, force: true });
	}

	// Run as a module in a context with only the Web globals a Worker has, where any import is refused. VM modules
	// need a flag of their own, so a child process does it.
	const child = spawnSync(process.execPath, ["--experimental-vm-modules", "--no-warnings", import.meta.filename, WORKER_CONTEXT], {
		encoding: "utf8",
		env: { ...process.env, NODE_TEST_CONTEXT: undefined },
	});
	assert.equal(child.status, 0, child.stderr);
	const report = JSON.parse(child.stdout) as { verified: string; refused: string; importRefused: string; globalMissing: string };
	assert.equal(report.verified, "production 65", "the sample passes in the Workers context");
	assert.equal(report.refused, "nonce", "an altered one is refused there");
	assert.match(report.importRefused, /node:crypto/, "the harness refuses a node: import");
	assert.match(report.globalMissing, /Buffer is not defined/, "the harness has no Node globals");
	step("src/appattest.ts runs in a context of the Web globals alone with every import refused: the sample passes, an altered one is refused, and the harness catches a node: import and a Node global");
}

/** The globals the file may use: what Cloudflare Workers have, Web Crypto among them. JavaScript's own come with any context. */
function workersGlobals() {
	return { crypto: globalThis.crypto, atob, btoa, TextEncoder, TextDecoder, console };
}

// The child's side: the file's own source, types stripped, as a module in a fresh context.
async function inAWorkersContext(): Promise<void> {
	const source = stripTypeScriptTypes(readFileSync(SOURCE, "utf8"));
	const sample = fixture.samples[0];
	const run = async (code: string, clientData: string) => {
		const context = vm.createContext(workersGlobals());
		const verifier = new vm.SourceTextModule(code, { context, identifier: "appattest.ts" });
		const driver = new vm.SourceTextModule(
			`import { verifyAttestation, probe } from "./appattest.ts";
			const bytes = (text) => Uint8Array.from(atob(text), (character) => character.charCodeAt(0));
			if (probe) probe();
			try {
				const result = await verifyAttestation(bytes(${JSON.stringify(sample.attestation)}), {
					teamId: ${JSON.stringify(sample.teamId)},
					bundleId: ${JSON.stringify(sample.bundleId)},
					keyId: bytes(${JSON.stringify(sample.keyId)}),
					clientDataHash: new TextEncoder().encode(${JSON.stringify(clientData)}),
					environments: [${JSON.stringify(sample.environment)}],
					now: ${expectationsOf(sample).now},
				});
				globalThis.outcome = result.environment + " " + result.publicKey.length;
			} catch (error) {
				globalThis.outcome = error.reason ?? String(error);
			}`,
			{ context, identifier: "driver" },
		);
		const link = (specifier: string) => {
			if (specifier === "./appattest.ts") return verifier;
			throw new Error(`refused the import of ${specifier}`);
		};
		await verifier.link(link);
		await driver.link(link);
		await driver.evaluate();
		return String((context as { outcome?: unknown }).outcome);
	};
	const caught = async (attempt: () => Promise<string>) => {
		try {
			return `not caught: ${await attempt()}`;
		} catch (error) {
			return String(error);
		}
	};
	const withProbe = `${source}\nexport const probe = undefined;\n`;
	console.log(
		JSON.stringify({
			verified: await run(withProbe, sample.clientDataHash),
			refused: await run(withProbe, `${sample.clientDataHash}!`),
			importRefused: await caught(() => run(`import { createHash } from "node:crypto";\n${source}\nexport const probe = () => createHash;\n`, sample.clientDataHash)),
			globalMissing: await caught(() => run(`${source}\nexport const probe = () => Buffer.from("x");\n`, sample.clientDataHash)),
		}),
	);
}

if (process.argv.includes(WORKER_CONTEXT)) await inAWorkersContext();
else await main();
