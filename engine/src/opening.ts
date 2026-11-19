// Opening a long conversation newest first (#380). The app asks `conversation.open` with `newestFirst`, and the engine
// sends the newest entries in the first `conversation` event, as many as fit in FIRST_BYTES or FIRST_COUNT, then the
// rest in `conversation.older` events of at most OLDER_BYTES, newest first, letting other work through between them.
// Every step of opening (the engine making the JSON, the app reading it and handing it to the page, the page drawing
// it) grows with the bytes, and an entry can be 0.3 KB or 50 KB, so the parts are bounded by size; the count bounds a
// conversation of many small entries. docs/transcript.md has the whole contract.

/** The most the first part holds: about a screen of entries with long command outputs. */
export const FIRST_BYTES = 64 * 1024;
/** The most entries the first part holds, for conversations of short ones. */
export const FIRST_COUNT = 40;
/** The most each later part holds. */
export const OLDER_BYTES = 256 * 1024;

type Entry = { kind: string };

/**
 * Where the part that ends at `end` starts: entries are taken from `end` back until they come to `bytes` (by `size`)
 * or number `count`, and always at least one. A part never starts with a tool result: it reaches back to the answer
 * whose call it is, which comes just before its results, so a call and its results arrive together.
 */
export function partStart<T extends Entry>(items: readonly T[], size: (item: T) => number, bytes: number, count = Infinity, end = items.length): number {
	let start = end;
	let total = 0;
	while (start > 0 && (start === end || (total < bytes && end - start < count))) total += size(items[--start]!);
	while (start > 0 && items[start]!.kind === "tool") start--;
	return start;
}

/**
 * Each item's JSON, made once however often it is asked for, and an event line made of them, so that measuring a
 * part costs nothing more than sending it.
 */
export class ItemJSON<T extends object> {
	#made = new Map<T, string>();

	of(item: T): string {
		let json = this.#made.get(item);
		if (json === undefined) {
			json = JSON.stringify(item);
			this.#made.set(item, json);
		}
		return json;
	}

	size = (item: T): number => this.of(item).length;

	/** The event `fields` with `items` added, as one line of JSON. */
	line(fields: Record<string, unknown>, items: readonly T[]): string {
		const head = JSON.stringify(fields);
		return `${head.slice(0, -1)}${head.length > 2 ? "," : ""}"items":[${items.map((item) => this.of(item)).join(",")}]}`;
	}
}
