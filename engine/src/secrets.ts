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
// more. It is kept in memory alone, and never logged, written or sent: nothing here says anything of a value, only
// where in a text one stands. A value replaced or removed is still looked for until the engine stops (transcripts
// still hold it, and replacing a key or refreshing a sign-in's token does not always revoke the old one), the latest
// RETIRED_KEPT of them, the oldest forgotten first.
//
// A value is looked for once it has LEAST_SECRET characters or more, without the white space around it, and is not one
// character repeated (or nearly: four different characters at least); a value of several lines is looked for whole and
// line by line, and in the form JSON writes it inside a string. A shorter value (a PIN, a port, "prod") is not looked
// for: it would be found inside ordinary words and numbers, hiding them and making every approval that holds them one a
// phone may only deny. A value of 8 characters or more is hidden wherever it appears, ordinary or not: a variable that
// holds a host or a word ("localhost", "production") is hidden in what a phone is sent too.
//
// A value is found by its ends, its first 8 characters (its head) and its last 8 (its foot), never compared whole:
// wherever a head stands, the value's length from there is hidden (to the text's end if it ends first); wherever a foot
// stands, the value's length up to it (from the text's start if it starts later). So a value is hidden whole, and so is
// any part of it that holds one of its ends: an answer or an output still coming, sent whole so far each time it grows,
// and a text cut at its front (a background command's kept output, a snippet), at its end, or in its middle (run_code's
// "characters left out"). Of a value written out, at most its first 7 and its last 7 characters can show, at a cut. And
// what follows a head or comes before a foot is never compared: a phone that sends text and reads it back masked or
// not learns only whether it held 8 characters that begin or end a value, never a value one character at a time. The
// cost is hiding a little too much where a head or a foot stands in ordinary text: of several values with the same
// head, the longest's length is hidden. A head or a foot with fewer than four different characters ("00000000") would
// hide too much of ordinary text: such a value is compared whole at its plain end instead.
//
// The search runs over every string of every line a device is sent, which can be 64 MiB, so it does not look for each
// value in turn. A head or a foot has 8 characters, so it holds one of its five four-character pieces at a position
// that is a multiple of five: the text is read one piece in five, each piece looked up among the heads' and feet's
// pieces, and only where one matches is the head or foot compared. Each head and each foot is one entry whatever the
// number of values that share it, so the cost is the text's length, and the values only count by how many different
// heads and feet share a piece (engine/test/devices.ts holds it to what `indexOf` finds, and measures it).

import type { Credential, CredentialStore } from "@earendil-works/pi-ai";

/** The fewest characters of a value looked for, and the length of its head and its foot. */
export const LEAST_SECRET = 8;
/** What stands in a device's copy, or a push, for a secret the engine knows (docs/iphone.md 7). */
export const SECRET_HIDDEN = "•••";
/** How many replaced or removed values are still looked for, the oldest forgotten first. */
export const RETIRED_KEPT = 1_000;

/** The piece looked up, and how far apart: LEAST_SECRET >= STRIDE + PIECE - 1, so a head or a foot always holds one. */
const PIECE = 4;
const STRIDE = 5;
/** The bits of a piece's hash kept in the filter, which answers most pieces without a lookup. */
const FILTER_BITS = 20;

/** The values each source (an account of the Keychain) holds, as they are looked for. */
const sources = new Map<string, readonly string[]>();
/** Values a source held and no longer does, oldest first, at most RETIRED_KEPT. */
let retired: string[] = [];
/** The search over every source's values; null when one changed since it was built. */
let built: Search | null = null;

/**
 * What a piece of the text may stand for: a head (the value's length hidden from it), a foot (the value's length hidden
 * up to it), or a value compared whole, whose ends are too plain to stand for it. `length`: the longest value's.
 */
type Entry = { kind: "head" | "foot" | "whole"; text: string; offset: number; length: number };
type Search = { filter: Uint32Array; at: Map<number, Entry[]> };

const MIX = 0x9e3779b1 | 0;
const pieceHash = (text: string, at: number): number =>
	Math.imul(Math.imul(Math.imul(text.charCodeAt(at), MIX) ^ text.charCodeAt(at + 1), MIX) ^ text.charCodeAt(at + 2), MIX) ^ text.charCodeAt(at + 3);

const plain = (text: string) => new Set(text).size < 4;

/** The forms of `value` looked for: none if it is too short, or one character over and over. */
function forms(value: string, into: Set<string>): void {
	for (const one of [value, ...value.split(/\r\n|\r|\n/)]) {
		const trimmed = one.trim();
		if (trimmed.length < LEAST_SECRET || plain(trimmed)) continue;
		into.add(trimmed);
		const escaped = JSON.stringify(trimmed).slice(1, -1);
		if (escaped !== trimmed) into.add(escaped);
	}
}

/** `values` are no longer held: still looked for, the latest RETIRED_KEPT. */
function retire(values: Iterable<string>): void {
	const leaving = new Set(values);
	if (leaving.size === 0) return;
	retired = [...retired.filter((value) => !leaving.has(value)), ...leaving].slice(-RETIRED_KEPT);
}

/** The values `source` holds now are `values` (the strings among them); what it held before is retired. */
export function knowSecrets(source: string, values: Iterable<unknown>): void {
	const taken = new Set<string>();
	for (const value of values) if (typeof value === "string") forms(value, taken);
	const before = sources.get(source) ?? [];
	if (before.length === taken.size && before.every((value) => taken.has(value))) return;
	retire(before.filter((value) => !taken.has(value)));
	if (taken.size === 0) sources.delete(source);
	else sources.set(source, [...taken]);
	built = null;
}

/** `values` are looked for too, beside what `source` already holds: a value given, before the Keychain has it. */
export function addSecrets(source: string, values: Iterable<unknown>): void {
	knowSecrets(source, [...(sources.get(source) ?? []), ...values]);
}

/** `source` holds nothing any more: what it held is retired. */
export function forgetSecrets(source: string): void {
	const before = sources.get(source);
	if (before === undefined) return;
	sources.delete(source);
	retire(before);
	built = null;
}

/** Nothing is looked for, retired values neither: for the tests alone, which share one set across their steps. */
export function forgetEverySecret(): void {
	sources.clear();
	retired = [];
	built = null;
}

function search(): Search | null {
	if (built !== null) return built;
	const values = new Set<string>(retired);
	for (const held of sources.values()) for (const value of held) values.add(value);
	if (values.size === 0) return null;
	// One entry for each head, each foot and each value compared whole, with the longest value's length.
	const entries = new Map<string, Entry>();
	const add = (kind: Entry["kind"], text: string, length: number) => {
		const key = `${kind} ${text}`;
		const known = entries.get(key);
		if (known === undefined) entries.set(key, { kind, text, offset: 0, length });
		else known.length = Math.max(known.length, length);
	};
	for (const value of values) {
		const head = value.slice(0, LEAST_SECRET);
		const foot = value.slice(-LEAST_SECRET);
		if (!plain(head)) add("head", head, value.length);
		if (!plain(foot)) add("foot", foot, value.length);
		if (plain(head) && plain(foot)) add("whole", value, value.length);
	}
	const filter = new Uint32Array(1 << (FILTER_BITS - 5));
	const at = new Map<number, Entry[]>();
	for (const entry of entries.values()) {
		// A head's, a foot's and a whole value's pieces are those of its first 8 characters.
		for (let offset = 0; offset < STRIDE; offset++) {
			const hash = pieceHash(entry.text, offset);
			const bit = hash >>> (32 - FILTER_BITS);
			filter[bit >>> 5]! |= 1 << (bit & 31);
			const placed = { ...entry, offset };
			const list = at.get(hash);
			if (list === undefined) at.set(hash, [placed]);
			else list.push(placed);
		}
	}
	built = { filter, at };
	return built;
}

/**
 * Where in `text` a value the engine knows, or a part of one that holds one of its ends, stands, as [from, to) spans:
 * from a head, the value's length on; up to a foot, the value's length back; a plain value where it stands whole. In no
 * order, and overlapping as they do, but for spans that follow one another, joined as they come.
 */
export function secretSpans(text: string): [number, number][] {
	const spans: [number, number][] = [];
	if (text.length < LEAST_SECRET) return spans;
	const found = search();
	if (found === null) return spans;
	const { filter, at } = found;
	const push = (from: number, to: number) => {
		const last = spans[spans.length - 1];
		// A head repeated, as a run of one prefix is: one span, not one an occurrence.
		if (last !== undefined && from >= last[0] && from < last[1]) last[1] = Math.max(last[1], to);
		else spans.push([from, to]);
	};
	const last = text.length - PIECE;
	for (let probe = 0; probe <= last; probe += STRIDE) {
		const hash = pieceHash(text, probe);
		const bit = hash >>> (32 - FILTER_BITS);
		if ((filter[bit >>> 5]! & (1 << (bit & 31))) === 0) continue;
		const list = at.get(hash);
		if (list === undefined) continue;
		for (const entry of list) {
			const from = probe - entry.offset;
			if (from < 0 || !text.startsWith(entry.text, from)) continue;
			if (entry.kind === "head") push(from, Math.min(text.length, from + entry.length));
			else if (entry.kind === "foot") push(Math.max(0, from + LEAST_SECRET - entry.length), from + LEAST_SECRET);
			else push(from, from + entry.length);
		}
	}
	return spans;
}

/** How many values are looked for, those retired among them: for the tests, which never see the values themselves. */
export function secretCount(): number {
	const values = new Set<string>(retired);
	for (const held of sources.values()) for (const value of held) values.add(value);
	return values.size;
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
