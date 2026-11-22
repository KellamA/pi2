// The relay's own few uses of Web Crypto: P-256 keys as RemoteKit writes them, their signatures, SHA-256 and HMAC.

import { fromBase64url, same, utf8 } from "./bytes.ts";

/** A P-256 public key's SPKI DER with an uncompressed point, the one encoding CryptoKit writes (docs/remotekit.md). */
const SPKI_LENGTH = 91;
const SPKI_P256_HEAD = new Uint8Array([
	0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03,
	0x01, 0x07, 0x03, 0x42, 0x00, 0x04,
]);

/** The bytes of a P-256 public key written as RemoteKit writes one (SPKI DER, base64url), or null. */
export function publicKeyBytes(text: string): Uint8Array<ArrayBuffer> | null {
	const der = fromBase64url(text, SPKI_LENGTH);
	if (der === null || !same(der.subarray(0, SPKI_P256_HEAD.length), SPKI_P256_HEAD)) return null;
	return new Uint8Array(der);
}

/** Whether `text` is a P-256 public key on the curve, in the one encoding taken. */
export async function isPublicKey(text: string): Promise<boolean> {
	return (await importKey(text)) !== null;
}

async function importKey(text: string): Promise<CryptoKey | null> {
	const der = publicKeyBytes(text);
	if (der === null) return null;
	try {
		return await crypto.subtle.importKey("spki", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
	} catch {
		return null;
	}
}

/**
 * Whether `signature` (64 bytes, r then s, base64url) is the key's ECDSA P-256 signature over SHA-256 of `text`'s UTF-8
 * bytes. Web Crypto reads ECDSA signatures in that same form (IEEE P1363).
 */
export async function verifySignature(key: string, signature: string, text: string): Promise<boolean> {
	const raw = fromBase64url(signature, 64);
	const imported = await importKey(key);
	if (raw === null || imported === null) return false;
	try {
		return await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, imported, new Uint8Array(raw), utf8(text));
	} catch {
		return false;
	}
}

export async function sha256(bytes: Uint8Array<ArrayBuffer>): Promise<Uint8Array<ArrayBuffer>> {
	return new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
}

export async function hmac(key: Uint8Array<ArrayBuffer>, message: Uint8Array<ArrayBuffer>): Promise<Uint8Array<ArrayBuffer>> {
	const imported = await crypto.subtle.importKey("raw", key, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
	return new Uint8Array(await crypto.subtle.sign("HMAC", imported, message));
}
