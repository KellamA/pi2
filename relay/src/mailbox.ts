// The mailbox (docs/iphone.md 5.3): sealed items kept for an end that is away, in the pairing's own SQLite storage. The
// relay cannot open them; it keeps each for its reader until the reader says it has kept it (`took`), or until it
// expires, within the contract's bounds. A take hands items over without deleting them (#806), so that an item on its
// way when a socket drops, or taken by an app that ends before it has kept it, is handed over again at the next take.

export const DAY = 24 * 60 * 60 * 1000;
export const HOUR = 60 * 60 * 1000;

/** The bounds of 5.3's table. */
export const MAILBOX = {
	/** For the Mac: up to 200 items, 1 MB in all, and at most 50 items and 256 KB from any one device. */
	macItems: 200,
	macBytes: 1024 * 1024,
	perDeviceItems: 50,
	perDeviceBytes: 256 * 1024,
	/** For each device: the latest state and up to 100 items. */
	deviceItems: 100,
};

export type Item = { writer: string; id: string; item: Uint8Array<ArrayBuffer>; presence: boolean };
export type Refusal = "exists" | "mailbox-full";

export class Mailbox {
	constructor(private readonly sql: SqlStorage) {}

	/** Makes the tables, once the pairing is registered: a pairing that does not exist keeps nothing. */
	create(): void {
		this.sql.exec(
			"CREATE TABLE IF NOT EXISTS items (reader TEXT NOT NULL, writer TEXT NOT NULL, id TEXT NOT NULL, item BLOB NOT NULL, " +
				"presence INTEGER NOT NULL, expires INTEGER NOT NULL, PRIMARY KEY (reader, id))",
		);
		this.sql.exec("CREATE TABLE IF NOT EXISTS states (device TEXT PRIMARY KEY, id TEXT NOT NULL, item BLOB NOT NULL, expires INTEGER NOT NULL)");
	}

	/** Keeps an item for `reader` ("mac" or a device's id) until `expires`, if there is room. */
	put(reader: string, writer: string, id: string, item: Uint8Array<ArrayBuffer>, presence: boolean, expires: number, now: number): Refusal | null {
		this.expire(now);
		if (this.sql.exec("SELECT 1 FROM items WHERE reader = ? AND id = ?", reader, id).toArray().length > 0) return "exists";
		const all = this.sql.exec<{ n: number; size: number }>("SELECT count(*) AS n, coalesce(sum(length(item)), 0) AS size FROM items WHERE reader = ?", reader).one();
		if (reader === "mac") {
			const mine = this.sql
				.exec<{ n: number; size: number }>("SELECT count(*) AS n, coalesce(sum(length(item)), 0) AS size FROM items WHERE reader = 'mac' AND writer = ?", writer)
				.one();
			if (all.n >= MAILBOX.macItems || all.size + item.length > MAILBOX.macBytes) return "mailbox-full";
			if (mine.n >= MAILBOX.perDeviceItems || mine.size + item.length > MAILBOX.perDeviceBytes) return "mailbox-full";
		} else if (all.n >= MAILBOX.deviceItems) {
			return "mailbox-full";
		}
		this.sql.exec("INSERT INTO items (reader, writer, id, item, presence, expires) VALUES (?, ?, ?, ?, ?, ?)", reader, writer, id, item.buffer, presence ? 1 : 0, expires);
		return null;
	}

	/** Keeps the Mac's latest state for a device, in place of the one before. */
	setState(device: string, id: string, item: Uint8Array<ArrayBuffer>, expires: number): void {
		this.sql.exec("INSERT OR REPLACE INTO states (device, id, item, expires) VALUES (?, ?, ?, ?)", device, id, item.buffer, expires);
	}

	/**
	 * What waits for `reader`, oldest first, and its state for a device. Nothing is deleted: what the reader has kept, it
	 * names in `took`, and the rest is handed over again at the next take, until it expires.
	 */
	take(reader: string, now: number): { items: Item[]; state: { id: string; item: Uint8Array<ArrayBuffer> } | null } {
		this.expire(now);
		const items = this.sql
			.exec<{ writer: string; id: string; item: ArrayBuffer; presence: number }>("SELECT writer, id, item, presence FROM items WHERE reader = ? ORDER BY rowid", reader)
			.toArray()
			.map((row) => ({ writer: row.writer, id: row.id, item: new Uint8Array(row.item), presence: row.presence === 1 }));
		let state = null;
		if (reader !== "mac") {
			const row = this.sql.exec<{ id: string; item: ArrayBuffer }>("SELECT id, item FROM states WHERE device = ?", reader).toArray()[0];
			if (row !== undefined) state = { id: row.id, item: new Uint8Array(row.item) };
		}
		return { items, state };
	}

	/**
	 * Deletes what `reader` says it has kept: its own items, and its own state, with these ids. Nothing of another
	 * reader's is touched, whatever ids it names; an id not there (expired, acknowledged before, or never there) is
	 * passed over, so that the same `took` sent again after a drop does nothing more. A state the Mac has replaced since
	 * it was taken has another id, and stays. The ids go in as one JSON array, since a statement takes few bindings.
	 */
	took(reader: string, ids: string[]): void {
		const list = JSON.stringify(ids);
		this.sql.exec("DELETE FROM items WHERE reader = ? AND id IN (SELECT value FROM json_each(?))", reader, list);
		if (reader !== "mac") this.sql.exec("DELETE FROM states WHERE device = ? AND id IN (SELECT value FROM json_each(?))", reader, list);
	}

	/** How many items wait for `reader`. */
	count(reader: string): number {
		return this.sql.exec<{ n: number }>("SELECT count(*) AS n FROM items WHERE reader = ?", reader).one().n;
	}

	/** Deletes everything for and from a device: it was removed, or it left. */
	forget(device: string): void {
		this.sql.exec("DELETE FROM items WHERE reader = ? OR writer = ?", device, device);
		this.sql.exec("DELETE FROM states WHERE device = ?", device);
	}

	expire(now: number): void {
		this.sql.exec("DELETE FROM items WHERE expires <= ?", now);
		this.sql.exec("DELETE FROM states WHERE expires <= ?", now);
	}

	/** When the next item or state expires, or null if nothing waits. */
	nextExpiry(): number | null {
		const row = this.sql
			.exec<{ at: number | null }>("SELECT min(at) AS at FROM (SELECT min(expires) AS at FROM items UNION ALL SELECT min(expires) AS at FROM states)")
			.one();
		return row.at;
	}
}
