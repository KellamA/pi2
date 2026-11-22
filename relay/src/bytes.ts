// Bytes and their texts, read strictly: every text the relay takes is the one way of writing its bytes, as RemoteKit
// writes them (docs/remotekit.md, "Everywhere"), so that two texts never stand for the same id or key.

const ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
const STANDARD = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

function table(alphabet: string): Int8Array {
	const values = new Int8Array(128).fill(-1);
	for (let index = 0; index < alphabet.length; index++) values[alphabet.charCodeAt(index)] = index;
	return values;
}
const URL_VALUES = table(ALPHABET);
const STANDARD_VALUES = table(STANDARD);

function encodeWith(alphabet: string, bytes: Uint8Array): string {
	let out = "";
	let index = 0;
	for (; index + 3 <= bytes.length; index += 3) {
		const n = (bytes[index] << 16) | (bytes[index + 1] << 8) | bytes[index + 2];
		out += alphabet[(n >> 18) & 63] + alphabet[(n >> 12) & 63] + alphabet[(n >> 6) & 63] + alphabet[n & 63];
	}
	const rest = bytes.length - index;
	if (rest === 1) {
		const n = bytes[index] << 16;
		out += alphabet[(n >> 18) & 63] + alphabet[(n >> 12) & 63];
	} else if (rest === 2) {
		const n = (bytes[index] << 16) | (bytes[index + 1] << 8);
		out += alphabet[(n >> 18) & 63] + alphabet[(n >> 12) & 63] + alphabet[(n >> 6) & 63];
	}
	return out;
}

function decodeWith(values: Int8Array, text: string): Uint8Array | null {
	if (text.length % 4 === 1) return null;
	const out = new Uint8Array(Math.floor((text.length * 3) / 4));
	let buffer = 0;
	let bits = 0;
	let at = 0;
	for (let index = 0; index < text.length; index++) {
		const code = text.charCodeAt(index);
		const value = code < 128 ? values[code] : -1;
		if (value < 0) return null;
		buffer = (buffer << 6) | value;
		bits += 6;
		if (bits >= 8) {
			bits -= 8;
			out[at++] = (buffer >> bits) & 0xff;
			buffer &= (1 << bits) - 1;
		}
	}
	// The bits left over must be zero, or two texts would stand for the same bytes.
	if (buffer !== 0) return null;
	return out;
}

/** Base64url without padding (RFC 4648 section 5). */
export function base64url(bytes: Uint8Array): string {
	return encodeWith(ALPHABET, bytes);
}

/** The bytes a base64url text stands for, `count` of them if given, or null if it is not written as `base64url` writes it. */
export function fromBase64url(text: string, count?: number): Uint8Array | null {
	if (count !== undefined && text.length !== Math.ceil((count * 4) / 3)) return null;
	const bytes = decodeWith(URL_VALUES, text);
	if (bytes === null || (count !== undefined && bytes.length !== count)) return null;
	return bytes;
}

/**
 * The bytes of standard base64 with its padding, as `DCAppAttestService` gives a key's identifier (and RemoteKit's
 * `pair` carries it): only the one way of writing them.
 */
export function fromBase64(text: string, count: number): Uint8Array | null {
	const unpadded = Math.ceil((count * 4) / 3);
	const padded = Math.ceil(count / 3) * 4;
	if (text.length !== padded || text.slice(unpadded) !== "=".repeat(padded - unpadded)) return null;
	const bytes = decodeWith(STANDARD_VALUES, text.slice(0, unpadded));
	return bytes !== null && bytes.length === count ? bytes : null;
}

export function base64(bytes: Uint8Array): string {
	const text = encodeWith(STANDARD, bytes);
	return text + "=".repeat((4 - (text.length % 4)) % 4);
}

export function hex(bytes: Uint8Array): string {
	let out = "";
	for (const byte of bytes) out += byte.toString(16).padStart(2, "0");
	return out;
}

/** Whether `a` and `b` hold the same bytes, in a time that depends on their lengths alone. */
export function same(a: Uint8Array, b: Uint8Array): boolean {
	if (a.length !== b.length) return false;
	let difference = 0;
	for (let index = 0; index < a.length; index++) difference |= a[index] ^ b[index];
	return difference === 0;
}

export function concat(...parts: Uint8Array[]): Uint8Array<ArrayBuffer> {
	const out = new Uint8Array(parts.reduce((sum, part) => sum + part.length, 0));
	let at = 0;
	for (const part of parts) {
		out.set(part, at);
		at += part.length;
	}
	return out;
}

export function utf8(text: string): Uint8Array<ArrayBuffer> {
	return new TextEncoder().encode(text);
}

export function random(count: number): Uint8Array<ArrayBuffer> {
	return crypto.getRandomValues(new Uint8Array(count));
}
