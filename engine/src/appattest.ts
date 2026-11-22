// App Attest's verifier (#672, P37 of docs/iphone.md): is this attestation the work of a genuine pi² for iPhone, signed
// by pi²'s team, vouching for the key it names, made for the client data the caller expects? The Mac checks a phone's
// pairing claim with it (3.3, step 5) and the relay a phone's join (step 2); the relay's build includes this very file
// (P8), so it runs unchanged in a Cloudflare Worker as well as in the engine.
//
// Hence what it does not do: it imports nothing, and uses only what both runtimes have, Web Crypto (`crypto.subtle`),
// `atob`, `TextEncoder` and `TextDecoder`, with no Node module and no Node global. engine/test/appattest.ts proves it by
// running the file in a context that holds only those, where an import of any module is refused.
//
// The steps are Apple's, "Validating apps that connect to your server" (developer.apple.com/documentation/devicecheck/
// validating-apps-that-connect-to-your-server), in an order of our own: the authenticator data's own fields first,
// then the certificates, then the nonce, so that each failure names the check that failed rather than a later one it
// upset (an altered counter would otherwise fail as a wrong nonce). Every step is made whatever the order; any one
// failing refuses the attestation.
//
// The parsers read exactly what App Attest makes and refuse everything else: CBOR in its deterministic form (shortest
// heads, keys in order, no tags, floats or indefinite lengths), DER with minimal lengths, exactly two certificates (the
// leaf and Apple's intermediate), and certificates of the one shape Apple issues. No third-party library: what is read
// is small, and an attestation is the first thing a stranger can send the relay.

export type AppAttestEnvironment = "production" | "development";

export type AppAttestExpected = {
	/** The App ID prefix, pi²'s team id: ten upper-case letters or digits. */
	teamId: string;
	/** The phone app's bundle id, such as `dev.pi2.ios`. */
	bundleId: string;
	/** The key's identifier as `DCAppAttestService.generateKey` gave it, decoded from base64: 32 bytes. */
	keyId: Uint8Array;
	/** What the phone passed to `attestKey` as `clientDataHash`, as the caller works it out for itself. */
	clientDataHash: Uint8Array;
	/** The App Attest environments taken: a release build's key is `production`, a debug build's `development`. */
	environments: readonly AppAttestEnvironment[];
	/** The time the certificates must be valid at, in milliseconds since 1970; now if left out. */
	now?: number;
};

export type AppAttestResult = {
	/** The attested key's public half, X9.62 uncompressed (65 bytes), whose SHA-256 is the key id. */
	publicKey: Uint8Array;
	environment: AppAttestEnvironment;
	/** Apple's receipt, unchecked here: it is for Apple's fraud-metric service. */
	receipt: Uint8Array;
	/** `apple_validation_category_01` of the authenticator data's extensions, where Apple gives it. */
	validationCategory: number | null;
	/** `apple_bundle_version_01`, where Apple gives it. */
	bundleVersion: string | null;
};

/**
 * Why an attestation was refused: `options`, the caller's expectations are not well formed; `malformed`, the bytes are
 * not an attestation of the shape App Attest makes; `app-id`, made for another app; `counter`, not a new key's;
 * `environment`, from an environment not taken; `key-id`, for another key than the one named; `not-yet-valid` and
 * `expired`, a certificate outside its dates; `chain`, the certificates do not chain as Apple's do; `root`, not
 * issued under Apple's App Attest root; `nonce`, made for other client data.
 */
export type AppAttestReason =
	| "options"
	| "malformed"
	| "app-id"
	| "counter"
	| "environment"
	| "key-id"
	| "not-yet-valid"
	| "expired"
	| "chain"
	| "root"
	| "nonce";

export class AppAttestError extends Error {
	readonly reason: AppAttestReason;
	constructor(reason: AppAttestReason, message: string) {
		super(message);
		this.name = "AppAttestError";
		this.reason = reason;
	}
}

/**
 * Apple App Attestation Root CA, as Apple publishes it at https://www.apple.com/certificateauthority/private/
 * (Apple_App_Attestation_Root_CA.pem), in DER, valid from 18 March 2020 to 15 March 2045. Pinned by its bytes: no other
 * root is ever taken, and nothing outside this file can name one.
 */
export const APPLE_APP_ATTEST_ROOT =
	"MIICITCCAaegAwIBAgIQC/O+DvHN0uD7jG5yH2IXmDAKBggqhkjOPQQDAzBSMSYwJAYDVQQDDB1BcHBsZSBBcHAgQXR0ZXN0YXRpb24gUm9vdCBD" +
	"QTETMBEGA1UECgwKQXBwbGUgSW5jLjETMBEGA1UECAwKQ2FsaWZvcm5pYTAeFw0yMDAzMTgxODMyNTNaFw00NTAzMTUwMDAwMDBaMFIxJjAkBgNV" +
	"BAMMHUFwcGxlIEFwcCBBdHRlc3RhdGlvbiBSb290IENBMRMwEQYDVQQKDApBcHBsZSBJbmMuMRMwEQYDVQQIDApDYWxpZm9ybmlhMHYwEAYHKoZI" +
	"zj0CAQYFK4EEACIDYgAERTHhmLW07ATaFQIEVwTtT4dyctdhNbJhFs/Ii2FdCgAHGbpphY3+d8qjuDngIN3WVhQUBHAoMeQ/cLiP1sOUtgjqK9au" +
	"Yen1mMEvRq9Sk3Jm5X8U62H+xTD3FE9TgS41o0IwQDAPBgNVHRMBAf8EBTADAQH/MB0GA1UdDgQWBBSskRBTM72+aEH/pwyp5frq5eWKoTAOBgNV" +
	"HQ8BAf8EBAMCAQYwCgYIKoZIzj0EAwMDaAAwZQIwQgFGnByvsiVbpTKwSga0kP0e8EeDS4+sQmTvb7vn53O5+FRXgeLhpJ06ysC5PrOyAjEAp5U4" +
	"xDgEgllF7En3VcE3iexZZtKeYnpqtijVoyFraWVIyd/dganmrduC1bmTBGwD";

/** The SHA-256 of the pinned root's DER, Apple's fingerprint of it; checked before the root is used. */
export const APPLE_APP_ATTEST_ROOT_SHA256 = "1cb9823ba28ba6ad2d33a006941de2ae4f513ef1d4e831b9f7e0fa7b6242c932";

/** Larger than any attestation App Attest makes (some 6 KB, most of it the receipt), so that a stranger's is bounded. */
const MAX_ATTESTATION = 32 * 1024;

/** The authenticator data's `aaguid` for each environment: "appattestdevelop", and "appattest" and seven zeros. */
const AAGUIDS: Record<AppAttestEnvironment, string> = {
	development: "617070617474657374646576656c6f70",
	production: "61707061747465737400000000000000",
};

// Object identifiers, by the hex of their DER content.
const OID = {
	ecPublicKey: "2a8648ce3d0201",
	p256: "2a8648ce3d030107",
	p384: "2b81040022",
	ecdsaSha256: "2a8648ce3d040302",
	ecdsaSha384: "2a8648ce3d040303",
	basicConstraints: "551d13",
	keyUsage: "551d0f",
	/** Apple's App Attest nonce, 1.2.840.113635.100.8.2. */
	nonce: "2a864886f763640802",
} as const;

type Bytes = Uint8Array<ArrayBuffer>;
type Curve = "P-256" | "P-384";
const CURVE_SIZE: Record<Curve, number> = { "P-256": 32, "P-384": 48 };

/**
 * Checks `attestation`, App Attest's attestation object as the phone sent it, against what the caller expects, and
 * gives the attested key and what Apple says of the app. Throws `AppAttestError` with the reason it was refused.
 */
export async function verifyAttestation(attestation: Uint8Array, expected: AppAttestExpected): Promise<AppAttestResult> {
	const { appId, keyId, clientDataHash, environments, now } = readExpected(expected);
	if (attestation.length > MAX_ATTESTATION) refuse("malformed", "The attestation is larger than App Attest makes.");
	// A copy, so that nothing the caller changes while this waits on Web Crypto changes what was checked.
	const object = readAttestationObject(new Uint8Array(attestation));
	const auth = readAuthenticatorData(object.authData);
	const leaf = readCertificate(object.x5c[0]);
	const intermediate = readCertificate(object.x5c[1]);
	const root = await pinnedRoot();

	// Apple's step 6: the RP ID hash is the SHA-256 of the App ID, the team id, a dot and the bundle id.
	if (!same(auth.rpIdHash, await sha256(new TextEncoder().encode(appId)))) {
		refuse("app-id", "The attestation was made for another app.");
	}
	// Step 7: a key that was only just made has signed nothing yet.
	if (auth.counter !== 0) refuse("counter", "The attestation's counter is not zero.");
	// Step 8: the environment.
	const environment = environments.find((name) => hex(auth.aaguid) === AAGUIDS[name]);
	if (environment === undefined) refuse("environment", "The attestation comes from an App Attest environment that is not taken.");
	// Step 9: the credential is the key named.
	if (!same(auth.credentialId, keyId)) refuse("key-id", "The attestation is for another key than the one named.");

	// Step 1: the leaf and Apple's intermediate, chained to the pinned root, each within its dates.
	for (const certificate of [root, intermediate, leaf]) {
		if (now < certificate.notBefore) refuse("not-yet-valid", "A certificate of the attestation is not valid yet.");
		if (now > certificate.notAfter) refuse("expired", "A certificate of the attestation has expired.");
	}
	if (!same(intermediate.issuer, root.subject)) refuse("root", "The attestation's intermediate certificate is not issued by Apple's App Attest root.");
	if (!isAuthority(intermediate)) refuse("chain", "The attestation's intermediate certificate is not a certificate authority.");
	if (isAuthority(leaf)) refuse("chain", "The attestation's leaf certificate is a certificate authority.");
	if (!same(leaf.issuer, intermediate.subject)) refuse("chain", "The attestation's leaf certificate is not issued by its intermediate.");
	if (!(await signedBy(intermediate, root))) refuse("root", "The attestation's intermediate certificate is not signed by Apple's App Attest root.");
	if (!(await signedBy(leaf, intermediate))) refuse("chain", "The attestation's leaf certificate is not signed by its intermediate.");

	// Step 5: the leaf's key, X9.62 uncompressed, is the key named, and is the key the authenticator data carries.
	if (leaf.curve !== "P-256") refuse("key-id", "The attested key is not a P-256 key.");
	if (!same(await sha256(leaf.point), keyId)) refuse("key-id", "The attested key is not the key named.");
	if (!same(auth.x, leaf.point.subarray(1, 33)) || !same(auth.y, leaf.point.subarray(33))) {
		refuse("key-id", "The authenticator data carries another key than the certificate.");
	}

	// Steps 2 to 4: the leaf's nonce is the SHA-256 of the authenticator data followed by the client data hash.
	const nonce = await sha256(concat(object.authData, clientDataHash));
	if (!same(leafNonce(leaf), nonce)) refuse("nonce", "The attestation was made for other client data.");

	return {
		publicKey: leaf.point.slice(),
		environment,
		receipt: object.receipt.slice(),
		validationCategory: auth.validationCategory,
		bundleVersion: auth.bundleVersion,
	};
}

function refuse(reason: AppAttestReason, message: string): never {
	throw new AppAttestError(reason, message);
}

function readExpected(expected: AppAttestExpected) {
	const { teamId, bundleId, environments } = expected;
	if (typeof teamId !== "string" || !/^[A-Z0-9]{10}$/.test(teamId)) refuse("options", "The team id is not ten upper-case letters or digits.");
	if (typeof bundleId !== "string" || !/^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$/.test(bundleId)) refuse("options", "The bundle id is not one.");
	if (expected.keyId?.length !== 32) refuse("options", "The key id is not 32 bytes.");
	const length = expected.clientDataHash?.length;
	if (typeof length !== "number" || length < 1 || length > 1024) refuse("options", "The client data hash is empty or too long.");
	if (!Array.isArray(environments) || environments.length === 0 || !environments.every((name) => name === "production" || name === "development")) {
		refuse("options", "The environments taken are not production, development or both.");
	}
	const now = expected.now ?? Date.now();
	if (!Number.isFinite(now)) refuse("options", "The time is not a time.");
	return {
		appId: `${teamId}.${bundleId}`,
		keyId: new Uint8Array(expected.keyId),
		clientDataHash: new Uint8Array(expected.clientDataHash),
		environments: [...expected.environments],
		now,
	};
}

// The attestation object: {"fmt": "apple-appattest", "attStmt": {"x5c": [leaf, intermediate], "receipt": …},
// "authData": …}, and nothing else.
function readAttestationObject(bytes: Bytes) {
	const top = textKeys(decodeCbor(bytes), ["fmt", "attStmt", "authData"]);
	const fmt = top.get("fmt");
	if (fmt?.kind !== "text" || fmt.value !== "apple-appattest") refuse("malformed", "The attestation is not in App Attest's format.");
	const statement = textKeys(top.get("attStmt"), ["x5c", "receipt"]);
	const x5c = statement.get("x5c");
	if (x5c?.kind !== "array" || x5c.items.length !== 2) refuse("malformed", "The attestation does not hold exactly two certificates.");
	const certificates = x5c.items.map((item) => {
		if (item.kind !== "bytes") refuse("malformed", "A certificate of the attestation is not bytes.");
		return item.value;
	});
	const receipt = statement.get("receipt");
	if (receipt?.kind !== "bytes" || receipt.value.length === 0) refuse("malformed", "The attestation's receipt is missing.");
	const authData = top.get("authData");
	if (authData?.kind !== "bytes") refuse("malformed", "The attestation's authenticator data is missing.");
	return { x5c: certificates, receipt: receipt.value, authData: authData.value };
}

/** A map whose keys are exactly `names`, as text, by name. */
function textKeys(value: Cbor | undefined, names: string[]): Map<string, Cbor> {
	if (value?.kind !== "map" || value.entries.length !== names.length) refuse("malformed", "The attestation is not in App Attest's format.");
	const found = new Map<string, Cbor>();
	for (const [key, item] of value.entries) {
		if (key.kind !== "text" || !names.includes(key.value)) refuse("malformed", "The attestation is not in App Attest's format.");
		found.set(key.value, item);
	}
	return found;
}

// The authenticator data (WebAuthn's, as App Attest fills it): the RP ID hash (32 bytes), the flags (1), the counter
// (4, big-endian), and the attested credential: the aaguid (16), the credential id's length (2) and the id (32), and the
// key as COSE; then, where Apple adds them, extensions as a CBOR map. Nothing may follow.
function readAuthenticatorData(data: Bytes) {
	if (data.length < 55) refuse("malformed", "The authenticator data is too short.");
	const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
	const flags = data[32];
	// The attested credential data is there only when the flags say so; App Attest's always is.
	if ((flags & 0x40) === 0) refuse("malformed", "The authenticator data holds no attested key.");
	if (view.getUint16(53) !== 32) refuse("malformed", "The authenticator data's credential id is not 32 bytes.");
	const keyStart = 55 + 32;
	if (data.length <= keyStart) refuse("malformed", "The authenticator data is too short.");
	const key = readCbor(data, keyStart, 0);
	const coseKey = readCoseKey(key.value);
	let validationCategory: number | null = null;
	let bundleVersion: string | null = null;
	if (key.end < data.length) {
		const extensions = readCbor(data, key.end, 0);
		if (extensions.end !== data.length) refuse("malformed", "Something follows the authenticator data's extensions.");
		({ validationCategory, bundleVersion } = readExtensions(extensions.value));
	}
	return {
		rpIdHash: data.subarray(0, 32),
		counter: view.getUint32(33),
		aaguid: data.subarray(37, 53),
		credentialId: data.subarray(55, keyStart),
		...coseKey,
		validationCategory,
		bundleVersion,
	};
}

// The key as COSE: an EC2 key (kty 2) for ES256 (alg -7) on P-256 (crv 1), with its x and y; nothing more.
function readCoseKey(key: Cbor) {
	if (key.kind !== "map" || key.entries.length !== 5) refuse("malformed", "The authenticator data's key is not a P-256 key.");
	const fields = new Map<number, Cbor>();
	for (const [label, value] of key.entries) {
		if (label.kind !== "uint" && label.kind !== "nint") refuse("malformed", "The authenticator data's key is not a P-256 key.");
		fields.set(label.value, value);
	}
	const int = (label: number, wanted: number) => {
		const value = fields.get(label);
		return (value?.kind === "uint" || value?.kind === "nint") && value.value === wanted;
	};
	const coordinate = (label: number) => {
		const value = fields.get(label);
		if (value?.kind !== "bytes" || value.value.length !== 32) refuse("malformed", "The authenticator data's key is not a P-256 key.");
		return value.value;
	};
	if (!int(1, 2) || !int(3, -7) || !int(-1, 1)) refuse("malformed", "The authenticator data's key is not a P-256 key.");
	return { x: coordinate(-2), y: coordinate(-3) };
}

// Apple's extensions: text keys, each with a text, bytes or unsigned value. The two Apple documents are read; others
// are let pass if well formed, so that one Apple adds later does not refuse every phone (they carry nothing this
// checks).
function readExtensions(extensions: Cbor) {
	if (extensions.kind !== "map") refuse("malformed", "The authenticator data's extensions are not a map.");
	let validationCategory: number | null = null;
	let bundleVersion: string | null = null;
	for (const [key, value] of extensions.entries) {
		if (key.kind !== "text" || (value.kind !== "text" && value.kind !== "bytes" && value.kind !== "uint")) {
			refuse("malformed", "The authenticator data's extensions are not of the shape Apple gives.");
		}
		if (key.value === "apple_validation_category_01") {
			// A UInt32, as four bytes, least significant first (Apple's sample has 01 00 00 00 for 1).
			if (value.kind !== "bytes" || value.value.length !== 4) refuse("malformed", "The validation category is not four bytes.");
			validationCategory = new DataView(value.value.buffer, value.value.byteOffset, 4).getUint32(0, true);
		} else if (key.value === "apple_bundle_version_01") {
			if (value.kind !== "text") refuse("malformed", "The bundle version is not text.");
			bundleVersion = value.value;
		}
	}
	return { validationCategory, bundleVersion };
}

// CBOR, as much of it as App Attest uses: unsigned and negative integers, byte and text strings, arrays and maps, in
// the deterministic encoding (RFC 8949 4.2.1). Refused: tags, floats and simple values, indefinite lengths, integers
// or lengths of eight bytes, a head longer than it need be, map keys out of order or repeated, text that is not UTF-8,
// and anything nested deeper than App Attest nests.

type Cbor =
	| { kind: "uint"; value: number }
	| { kind: "nint"; value: number }
	| { kind: "bytes"; value: Bytes }
	| { kind: "text"; value: string }
	| { kind: "array"; items: Cbor[] }
	| { kind: "map"; entries: [Cbor, Cbor][] };

const MAX_DEPTH = 4;

function decodeCbor(bytes: Bytes): Cbor {
	const { value, end } = readCbor(bytes, 0, 0);
	if (end !== bytes.length) refuse("malformed", "Something follows the attestation.");
	return value;
}

function readCbor(bytes: Bytes, at: number, depth: number): { value: Cbor; end: number } {
	if (depth > MAX_DEPTH) refuse("malformed", "The attestation is nested deeper than App Attest's.");
	if (at >= bytes.length) refuse("malformed", "The attestation ends too soon.");
	const initial = bytes[at];
	const major = initial >> 5;
	const info = initial & 31;
	let argument: number;
	let next = at + 1;
	if (info < 24) {
		argument = info;
	} else if (info === 24 || info === 25 || info === 26) {
		const size = info === 24 ? 1 : info === 25 ? 2 : 4;
		if (next + size > bytes.length) refuse("malformed", "The attestation ends too soon.");
		argument = 0;
		for (let i = 0; i < size; i++) argument = argument * 256 + bytes[next + i];
		next += size;
		const least = info === 24 ? 24 : info === 25 ? 0x100 : 0x10000;
		if (argument < least) refuse("malformed", "The attestation is not in CBOR's shortest form.");
	} else {
		refuse("malformed", "The attestation holds a CBOR length or value App Attest does not use.");
	}
	switch (major) {
		case 0:
			return { value: { kind: "uint", value: argument }, end: next };
		case 1:
			return { value: { kind: "nint", value: -1 - argument }, end: next };
		case 2:
		case 3: {
			if (argument > bytes.length - next) refuse("malformed", "The attestation ends too soon.");
			const content = bytes.subarray(next, next + argument);
			const end = next + argument;
			if (major === 2) return { value: { kind: "bytes", value: content }, end };
			let text: string;
			try {
				text = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(content);
			} catch {
				refuse("malformed", "The attestation holds text that is not UTF-8.");
			}
			return { value: { kind: "text", value: text }, end };
		}
		case 4: {
			// Each item takes a byte at least, so a count beyond what is left is refused before anything is made.
			if (argument > bytes.length - next) refuse("malformed", "The attestation ends too soon.");
			const items: Cbor[] = [];
			for (let i = 0; i < argument; i++) {
				const item = readCbor(bytes, next, depth + 1);
				items.push(item.value);
				next = item.end;
			}
			return { value: { kind: "array", items }, end: next };
		}
		case 5: {
			if (argument > (bytes.length - next) / 2) refuse("malformed", "The attestation ends too soon.");
			const entries: [Cbor, Cbor][] = [];
			let previous: Bytes | null = null;
			for (let i = 0; i < argument; i++) {
				const keyStart = next;
				const key = readCbor(bytes, next, depth + 1);
				if (key.value.kind !== "uint" && key.value.kind !== "nint" && key.value.kind !== "text") {
					refuse("malformed", "The attestation has a map key App Attest does not use.");
				}
				const encoded = bytes.subarray(keyStart, key.end);
				if (previous !== null && compare(previous, encoded) >= 0) refuse("malformed", "The attestation's map keys are out of order or repeated.");
				previous = encoded;
				const value = readCbor(bytes, key.end, depth + 1);
				entries.push([key.value, value.value]);
				next = value.end;
			}
			return { value: { kind: "map", entries }, end: next };
		}
		default:
			refuse("malformed", "The attestation holds a CBOR tag or simple value App Attest does not use.");
	}
}

// DER, as much of it as a certificate of App Attest's uses: low tag numbers only, definite lengths of at most three
// bytes, each in its shortest form, and each element ending exactly where its parent does.

type Der = { tag: number; content: Bytes; whole: Bytes };

function readDer(bytes: Bytes, at: number): { element: Der; end: number } {
	if (at + 2 > bytes.length) refuse("malformed", "A certificate ends too soon.");
	const tag = bytes[at];
	if ((tag & 0x1f) === 0x1f) refuse("malformed", "A certificate holds a tag of a form it should not.");
	let length = bytes[at + 1];
	let start = at + 2;
	if (length >= 0x80) {
		const size = length & 0x7f;
		if (size === 0 || size > 3) refuse("malformed", "A certificate holds a length of a form it should not.");
		if (start + size > bytes.length) refuse("malformed", "A certificate ends too soon.");
		if (bytes[start] === 0) refuse("malformed", "A certificate holds a length longer than it need be.");
		length = 0;
		for (let i = 0; i < size; i++) length = length * 256 + bytes[start + i];
		if (length < 0x80) refuse("malformed", "A certificate holds a length longer than it need be.");
		start += size;
	}
	if (length > bytes.length - start) refuse("malformed", "A certificate ends too soon.");
	const end = start + length;
	return { element: { tag, content: bytes.subarray(start, end), whole: bytes.subarray(at, end) }, end };
}

/** The one element `bytes` holds, which must be a `tag`. */
function only(bytes: Bytes, tag: number): Der {
	const { element, end } = readDer(bytes, 0);
	if (end !== bytes.length || element.tag !== tag) refuse("malformed", "A certificate is not of the shape Apple issues.");
	return element;
}

/** The elements inside a constructed one, which must fill it. */
function children(element: Der): Der[] {
	const found: Der[] = [];
	for (let at = 0; at < element.content.length; ) {
		const { element: child, end } = readDer(element.content, at);
		found.push(child);
		at = end;
	}
	return found;
}

function expectTag(element: Der | undefined, tag: number): Der {
	if (element === undefined || element.tag !== tag) refuse("malformed", "A certificate is not of the shape Apple issues.");
	return element;
}

type Certificate = {
	tbs: Bytes;
	hash: "SHA-256" | "SHA-384";
	signature: Bytes;
	issuer: Bytes;
	subject: Bytes;
	notBefore: number;
	notAfter: number;
	curve: Curve;
	spki: Bytes;
	point: Bytes;
	extensions: Map<string, { critical: boolean; value: Bytes }>;
};

// Certificate ::= SEQUENCE { tbsCertificate, signatureAlgorithm, signatureValue BIT STRING }, an X.509 v3 one with an
// ECDSA key and signature, extensions and no unique ids.
function readCertificate(bytes: Bytes): Certificate {
	const parts = children(only(bytes, 0x30));
	if (parts.length !== 3) refuse("malformed", "A certificate is not of the shape Apple issues.");
	const tbs = expectTag(parts[0], 0x30);
	const outerAlgorithm = expectTag(parts[1], 0x30);
	const fields = children(tbs);
	if (fields.length !== 8) refuse("malformed", "A certificate is not of the shape Apple issues.");
	const [version, serial, algorithm, issuer, validity, subject, spki, extensions] = fields;
	// [0] EXPLICIT Version, v3 (2).
	if (expectTag(version, 0xa0).content.length !== 3 || hex(version.content) !== "020102") refuse("malformed", "A certificate is not an X.509 v3 one.");
	const serialNumber = expectTag(serial, 0x02).content;
	if (serialNumber.length === 0 || serialNumber.length > 21) refuse("malformed", "A certificate's serial number is not one.");
	if (!same(expectTag(algorithm, 0x30).whole, outerAlgorithm.whole)) refuse("malformed", "A certificate's two signature algorithms differ.");
	const times = children(expectTag(validity, 0x30));
	if (times.length !== 2) refuse("malformed", "A certificate's dates are not two.");
	const key = readPublicKey(expectTag(spki, 0x30));
	return {
		tbs: tbs.whole,
		hash: signatureHash(outerAlgorithm),
		signature: bitString(expectTag(parts[2], 0x03)),
		issuer: expectTag(issuer, 0x30).whole,
		subject: expectTag(subject, 0x30).whole,
		notBefore: readTime(times[0]),
		notAfter: readTime(times[1]),
		...key,
		spki: spki.whole,
		extensions: readExtensionList(expectTag(extensions, 0xa3)),
	};
}

// AlgorithmIdentifier for ECDSA: the OID alone, with no parameters.
function signatureHash(algorithm: Der): "SHA-256" | "SHA-384" {
	const parts = children(algorithm);
	const oid = parts.length === 1 ? hex(expectTag(parts[0], 0x06).content) : "";
	if (oid === OID.ecdsaSha256) return "SHA-256";
	if (oid === OID.ecdsaSha384) return "SHA-384";
	refuse("malformed", "A certificate is signed with an algorithm App Attest does not use.");
}

// SubjectPublicKeyInfo: { { id-ecPublicKey, P-256 or P-384 }, the point, uncompressed }.
function readPublicKey(spki: Der): { curve: Curve; point: Bytes } {
	const parts = children(spki);
	if (parts.length !== 2) refuse("malformed", "A certificate's key is not an EC key.");
	const algorithm = children(expectTag(parts[0], 0x30));
	if (algorithm.length !== 2 || hex(expectTag(algorithm[0], 0x06).content) !== OID.ecPublicKey) refuse("malformed", "A certificate's key is not an EC key.");
	const named = hex(expectTag(algorithm[1], 0x06).content);
	const curve: Curve | null = named === OID.p256 ? "P-256" : named === OID.p384 ? "P-384" : null;
	if (curve === null) refuse("malformed", "A certificate's key is on a curve App Attest does not use.");
	const point = bitString(expectTag(parts[1], 0x03));
	if (point.length !== 1 + 2 * CURVE_SIZE[curve] || point[0] !== 0x04) refuse("malformed", "A certificate's key is not an uncompressed point.");
	return { curve, point };
}

/** A BIT STRING's bits, which must be whole bytes. */
function bitString(element: Der): Bytes {
	if (element.content.length < 1 || element.content[0] !== 0) refuse("malformed", "A certificate's bit string is not whole bytes.");
	return element.content.subarray(1);
}

// UTCTime (YYMMDDHHMMSSZ) or GeneralizedTime (YYYYMMDDHHMMSSZ), in UTC, to the second.
function readTime(element: Der): number {
	if (element.content.length > 15) refuse("malformed", "A certificate's date is not one.");
	const text = String.fromCharCode(...element.content);
	const pattern = element.tag === 0x17 ? /^(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/ : element.tag === 0x18 ? /^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/ : null;
	const match = pattern?.exec(text);
	if (!match) refuse("malformed", "A certificate's date is not one.");
	const numbers = match.slice(1).map(Number);
	const year = element.tag === 0x17 ? (numbers[0] < 50 ? 2000 : 1900) + numbers[0] : numbers[0];
	const [, month, day, hour, minute, second] = numbers;
	const time = Date.UTC(year, month - 1, day, hour, minute, second);
	const date = new Date(time);
	// Date.UTC carries an impossible day or hour into the next; a real date comes back as it went in.
	if (date.getUTCFullYear() !== year || date.getUTCMonth() !== month - 1 || date.getUTCDate() !== day || date.getUTCHours() !== hour || date.getUTCMinutes() !== minute || date.getUTCSeconds() !== second) {
		refuse("malformed", "A certificate's date is not one.");
	}
	return time;
}

// [3] EXPLICIT Extensions: SEQUENCE OF { extnID, critical BOOLEAN DEFAULT FALSE, extnValue OCTET STRING }. Each id once;
// critical only where this file reads the extension (basic constraints and key usage), as X.509 asks of any reader.
function readExtensionList(element: Der): Certificate["extensions"] {
	const inner = children(element);
	if (inner.length !== 1) refuse("malformed", "A certificate's extensions are not of the shape Apple issues.");
	const list = children(expectTag(inner[0], 0x30));
	if (list.length === 0) refuse("malformed", "A certificate's extensions are empty.");
	const found: Certificate["extensions"] = new Map();
	for (const extension of list) {
		const parts = children(expectTag(extension, 0x30));
		if (parts.length !== 2 && parts.length !== 3) refuse("malformed", "A certificate's extension is not of the shape Apple issues.");
		const id = hex(expectTag(parts[0], 0x06).content);
		// DER leaves a FALSE default out, so a critical flag that is there says TRUE.
		const critical = parts.length === 3;
		if (critical && hex(expectTag(parts[1], 0x01).content) !== "ff") refuse("malformed", "A certificate's critical flag is not DER's TRUE.");
		const value = expectTag(parts[parts.length - 1], 0x04).content;
		if (found.has(id)) refuse("malformed", "A certificate has an extension twice.");
		if (critical && id !== OID.basicConstraints && id !== OID.keyUsage) refuse("chain", "A certificate has a critical extension this check does not read.");
		found.set(id, { critical, value });
	}
	return found;
}

// A certificate authority: basic constraints say cA TRUE, and key usage allows signing certificates. A certificate with
// neither extension is not one.
function isAuthority(certificate: Certificate): boolean {
	const constraints = certificate.extensions.get(OID.basicConstraints);
	if (constraints === undefined) return false;
	// SEQUENCE { cA BOOLEAN DEFAULT FALSE, pathLenConstraint INTEGER OPTIONAL }, the length only beside cA TRUE.
	const fields = children(only(constraints.value, 0x30));
	let next = 0;
	let ca = false;
	if (fields[next]?.tag === 0x01) {
		if (hex(fields[next].content) !== "ff") refuse("malformed", "A certificate's basic constraints are not of the shape Apple issues.");
		ca = true;
		next++;
	}
	if (ca && fields[next]?.tag === 0x02) next++;
	if (next !== fields.length) refuse("malformed", "A certificate's basic constraints are not of the shape Apple issues.");
	if (!ca) return false;
	const usage = certificate.extensions.get(OID.keyUsage);
	if (usage === undefined) return false;
	const bits = only(usage.value, 0x03).content;
	// keyCertSign is bit 5: the first byte after the count of unused bits, 0x04.
	return bits.length >= 2 && (bits[1] & 0x04) !== 0;
}

// Apple's nonce extension: SEQUENCE { [1] EXPLICIT OCTET STRING (32 bytes) }, exactly.
function leafNonce(leaf: Certificate): Bytes {
	const extension = leaf.extensions.get(OID.nonce);
	if (extension === undefined) refuse("nonce", "The attestation's certificate holds no nonce.");
	const sequence = children(only(extension.value, 0x30));
	if (sequence.length !== 1) refuse("malformed", "The attestation's nonce is not of the shape Apple issues.");
	const tagged = children(expectTag(sequence[0], 0xa1));
	if (tagged.length !== 1) refuse("malformed", "The attestation's nonce is not of the shape Apple issues.");
	const nonce = expectTag(tagged[0], 0x04).content;
	if (nonce.length !== 32) refuse("malformed", "The attestation's nonce is not 32 bytes.");
	return nonce;
}

async function signedBy(certificate: Certificate, issuer: Certificate): Promise<boolean> {
	const key = await crypto.subtle.importKey("spki", issuer.spki, { name: "ECDSA", namedCurve: issuer.curve }, false, ["verify"]);
	const signature = rawSignature(certificate.signature, CURVE_SIZE[issuer.curve]);
	if (signature === null) return false;
	return crypto.subtle.verify({ name: "ECDSA", hash: certificate.hash }, key, signature, certificate.tbs);
}

// X.509 carries ECDSA's signature as SEQUENCE { r INTEGER, s INTEGER }; Web Crypto takes r and s side by side, each
// padded to the curve's size. Null for one that cannot be a signature on that curve.
function rawSignature(der: Bytes, size: number): Bytes | null {
	const parts = children(only(der, 0x30));
	if (parts.length !== 2) return null;
	const raw = new Uint8Array(2 * size);
	for (const [index, part] of parts.entries()) {
		let value = expectTag(part, 0x02).content;
		if (value.length === 0 || (value[0] & 0x80) !== 0) return null;
		if (value[0] === 0 && value.length > 1) {
			if ((value[1] & 0x80) === 0) refuse("malformed", "A certificate's signature holds an integer longer than it need be.");
			value = value.subarray(1);
		}
		if (value.length > size) return null;
		raw.set(value, (index + 1) * size - value.length);
	}
	return raw;
}

let root: Promise<Certificate> | null = null;

/** The pinned root, read once, after its bytes are checked against Apple's fingerprint. */
function pinnedRoot(): Promise<Certificate> {
	root ??= (async () => {
		const bytes = Uint8Array.from(atob(APPLE_APP_ATTEST_ROOT), (character) => character.charCodeAt(0));
		if (hex(await sha256(bytes)) !== APPLE_APP_ATTEST_ROOT_SHA256) refuse("root", "The pinned root is not Apple's App Attest root.");
		return readCertificate(bytes);
	})();
	return root;
}

async function sha256(bytes: Bytes): Promise<Bytes> {
	return new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
}

function concat(first: Bytes, second: Bytes): Bytes {
	const joined = new Uint8Array(first.length + second.length);
	joined.set(first);
	joined.set(second, first.length);
	return joined;
}

function same(first: Uint8Array, second: Uint8Array): boolean {
	if (first.length !== second.length) return false;
	let difference = 0;
	for (let i = 0; i < first.length; i++) difference |= first[i] ^ second[i];
	return difference === 0;
}

function compare(first: Bytes, second: Bytes): number {
	for (let i = 0; i < Math.min(first.length, second.length); i++) if (first[i] !== second[i]) return first[i] - second[i];
	return first.length - second.length;
}

function hex(bytes: Uint8Array): string {
	let text = "";
	for (const byte of bytes) text += byte.toString(16).padStart(2, "0");
	return text;
}
