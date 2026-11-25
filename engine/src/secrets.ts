
// The values of the secrets the engine knows (docs/iphone.md 5.7 and 7, #894): agents' variables and MCP servers'
// variables (variables.ts, `VariableValues`), and providers' keys and tokens, MCP servers' tokens among them (the
// credential store, through `watchingSecrets`). A phone is sent every line of a conversation, and pushed an approval's
// call, so an agent that reads one of them from a file or its environment and writes it into a command or an answer
// would put it on the phone's card and its Lock Screen. `maskKeys` (devices.ts) replaces each of them wherever it
// appears in a string sent to a device or pushed, as it replaces a key by its shape, and an approval that had one
// masked is marked `partHidden` with it.
//
// The set is learnt from the reads the engine makes anyway, for runs and at start (agents' and MCP servers' variables
// are read as the engine starts, to check them; providers' credentials are read once at start by
// `knowStoredSecrets`, then kept by the store), so no request a phone sends makes the engine read the Keychain once
// more. It is kept in memory alone, replaced when a value is set, changed or removed, and never logged, written or
// sent: nothing here says anything of a value, only where in a text one stands.
//
// A value is looked for once it has LEAST_SECRET characters or more, without the white space around it, and is not one
// character repeated (or nearly: four different characters at least); a value of several lines is looked for whole and
// line by line, and in the form JSON writes it inside a string. A text that ends with a value's first 8 characters or
// more has them hidden too: an answer or an output still coming is sent whole so far each time it grows, so a value
// written out shows at most its first 7 characters while it comes. A shorter value (a PIN, a port, "prod") is not looked
// for: it would be found inside ordinary words and numbers, hiding them and making every approval that holds them
// one a phone may only deny. A value of 8 characters or more is still hidden wherever it appears, ordinary or not: a
// variable that holds a host or a word ("localhost", "production") is hidden in what a phone is sent too.
//
// The search runs over every string of every line a device is sent, which can be 64 MiB, so it does not look for each
// value in turn. Every value has 8 characters or more, so each place it stands holds one of its first five
// four-character pieces at a position that is a multiple of five: the text is read one piece in five, each piece
// looked up among the values' pieces, and only where one matches is the value compared whole. Its cost is the text's
// length, whatever the number of values (engine/test/devices.ts holds it to the values found by `indexOf`).

import type { Credential, CredentialStore } from "@earendil-works/pi-ai";

/** The fewest characters of a value looked for. */
export const LEAST_SECRET = 8;
/** What stands in a device's copy, or a push, for a secret the engine knows (docs/iphone.md 7). */
export const SECRET_HIDDEN = "•••";

/** The piece looked up, and how far apart: LEAST_SECRET >= STRIDE + PIECE - 1, so a value always holds one. */
const PIECE = 4;
const STRIDE = 5;
/** The bits of a piece's hash kept in the filter, which answers most pieces without a lookup. */
const FILTER_BITS = 20;

/** The values each source (an account of the Keychain) holds, as they are looked for. */
const sources = new Map<string, readonly string[]>();
/** The search over every source's values; null when one changed since it was built. */
let built: Search | null = null;

type Search = { filter: Uint32Array; at: Map<number, { value: string; offset: number }[]> };

const MIX = 0x9e3779b1 | 0;
const pieceHash = (text: string, at: number): number =>
	Math.imul(Math.imul(Math.imul(text.charCodeAt(at), MIX) ^ text.charCodeAt(at + 1), MIX) ^ text.charCodeAt(at + 2), MIX) ^ text.charCodeAt(at + 3);

/** The forms of `value` looked for: none if it is too short, or one character over and over. */
function forms(value: string, into: Set<string>): void {
	for (const one of [value, ...value.split(/\r\n|\r|\n/)]) {
		const trimmed = one.trim();
		if (trimmed.length < LEAST_SECRET || new Set(trimmed).size < 4) continue;
		into.add(trimmed);
		const escaped = JSON.stringify(trimmed).slice(1, -1);
		if (escaped !== trimmed) into.add(escaped);
	}
}

/** The values `source` holds now are `values` (the strings among them): what it held before is no longer looked for. */
export function knowSecrets(source: string, values: Iterable<unknown>): void {
	const taken = new Set<string>();
	for (const value of values) if (typeof value === "string") forms(value, taken);
	const before = sources.get(source);
	if (before !== undefined && before.length === taken.size && before.every((value) => taken.has(value))) return;
	if (taken.size === 0) sources.delete(source);
	else sources.set(source, [...taken]);
	built = null;
}

/** `values` are looked for too, beside what `source` already holds: a value given, before the Keychain has it. */
export function addSecrets(source: string, values: Iterable<unknown>): void {
	knowSecrets(source, [...(sources.get(source) ?? []), ...values]);
}

/** `source` holds nothing any more. */
export function forgetSecrets(source: string): void {
	if (sources.delete(source)) built = null;
}

function search(): Search | null {
	if (sources.size === 0) return null;
	if (built !== null) return built;
	const filter = new Uint32Array(1 << (FILTER_BITS - 5));
	const at = new Map<number, { value: string; offset: number }[]>();
	const seen = new Set<string>();
	for (const values of sources.values()) {
		for (const value of values) {
			if (seen.has(value)) continue;
			seen.add(value);
			for (let offset = 0; offset < STRIDE; offset++) {
				const hash = pieceHash(value, offset);
				const bit = hash >>> (32 - FILTER_BITS);
				filter[bit >>> 5]! |= 1 << (bit & 31);
				const list = at.get(hash);
				if (list === undefined) at.set(hash, [{ value, offset }]);
				else list.push({ value, offset });
			}
		}
	}
	built = { filter, at };
	return built;
}

/**
 * Where in `text` a value the engine knows stands, as [from, to) spans, in no order, overlapping as the values do; and
 * where it ends with the first LEAST_SECRET characters or more of one, as a transcript's answer or output still coming
 * does, sent again whole as it grows: of a value written out, at most its first LEAST_SECRET - 1 characters are shown.
 */
export function secretSpans(text: string): [number, number][] {
	const spans: [number, number][] = [];
	if (text.length < LEAST_SECRET) return spans;
	const found = search();
	if (found === null) return spans;
	const { filter, at } = found;
	const last = text.length - PIECE;
	for (let probe = 0; probe <= last; probe += STRIDE) {
		const hash = pieceHash(text, probe);
		const bit = hash >>> (32 - FILTER_BITS);
		if ((filter[bit >>> 5]! & (1 << (bit & 31))) === 0) continue;
		const list = at.get(hash);
		if (list === undefined) continue;
		for (const { value, offset } of list) {
			const from = probe - offset;
			if (from < 0) continue;
			if (text.startsWith(value, from)) spans.push([from, from + value.length]);
			// The text ends with the value's start: an answer or an output still coming, sent whole so far each time.
			else if (text.length - from >= LEAST_SECRET && text.length - from < value.length && value.startsWith(text.slice(from))) spans.push([from, text.length]);
		}
	}
	return spans;
}

/** How many values are looked for: for the tests, which never see the values themselves. */
export function secretCount(): number {
	let count = 0;
	for (const values of sources.values()) count += values.length;
	return count;
}

// ---- Providers' keys and tokens

/** A credential's own field names that hold a secret: its key and its tokens, and anything named like one. */
const SECRET_NAME = /^(?:key|access|refresh)$|token|secret|password|passwd|apikey|api_key/i;

/** The secrets of a credential: an API key, OAuth's tokens, and any value of its own or its `env` named like a secret. */
function secretsOf(credential: Credential): string[] {
	const found: string[] = [];
	for (const [name, value] of Object.entries(credential)) {
		if (typeof value === "string" && SECRET_NAME.test(name)) found.push(value);
	}
	const env = (credential as { env?: unknown }).env;
	if (typeof env === "object" && env !== null) {
		for (const [name, value] of Object.entries(env)) if (typeof value === "string" && SECRET_NAME.test(name)) found.push(value);
	}
	return found;
}

const credentialSource = (providerId: string) => `credential:${providerId}`;

/**
 * `store`, learning the secrets of each credential it reads or writes, and forgetting those it deletes. It reads
 * nothing more than its caller asks of it.
 */
export function watchingSecrets(store: CredentialStore): CredentialStore {
	const know = (providerId: string, credential: Credential | undefined) => {
		if (credential === undefined) forgetSecrets(credentialSource(providerId));
		else knowSecrets(credentialSource(providerId), secretsOf(credential));
	};
	return {
		read: async (providerId, options) => {
			const credential = await store.read(providerId, options);
			know(providerId, credential);
			return credential;
		},
		list: (options) => store.list(options),
		modify: async (providerId, change, options) => {
			const credential = await store.modify(
				providerId,
				async (current) => {
					const next = await change(current);
					// Looked for from before it is written: it is a secret whether or not the store keeps it.
					if (next !== undefined) addSecrets(credentialSource(providerId), secretsOf(next));
					return next;
				},
				options,
			);
			know(providerId, credential);
			return credential;
		},
		delete: async (providerId, options) => {
			await store.delete(providerId, options);
			forgetSecrets(credentialSource(providerId));
		},
	};
}

/**
 * Reads every credential the store lists, once, as the engine starts, so that a provider's key not yet used since is
 * looked for too. The store keeps what it read (credentials.ts), so the reads a run makes later cost nothing more. A
 * credential that cannot be read is left: the store says why when a run asks for it.
 */
export async function knowStoredSecrets(store: CredentialStore): Promise<void> {
	let listed: readonly { providerId: string }[];
	try {
		listed = await store.list();
	} catch {
		return;
	}
	await Promise.all(listed.map((info) => store.read(info.providerId).catch(() => undefined)));
}
