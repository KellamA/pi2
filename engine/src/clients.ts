// The apps connected to the engine's socket (#483, moved from main.ts): each connection with what it has open, and
// sending an event to one of them or to every one. main.ts makes a client as one connects and takes it away as it goes.
// A paired device's session is a client too (remote.ts, #673), whose lines go to pi² Remote tagged with the session.

/** Where a client's lines go: the connection's socket, or a device session's tagged lines (remote.ts). */
export type Wire = { write(line: string): unknown; readonly destroyed: boolean; destroy(): unknown };

/** `follow` watches the version a chat shows now, if that changed (versions.ts). */
export type Subscription = { push: () => void; stop: () => Promise<unknown>; follow: () => Promise<void>; older: () => Promise<{ more: boolean }> };
/**
 * `shown`: the conversations this app has on screen, in its panes or as chat mode's chat (`conversations.shown`).
 * `testCopy`: this connection gave the key of the test copy this engine runs (`test-copy.answerer`), so it may act for the person.
 * `device`: a paired device's session (remote.ts), never the app's, whatever it sends (docs/iphone.md 4.1).
 */
export type Client = { socket: Wire; subscriptions: Map<number, Subscription>; shown: Set<number>; testCopy?: true; device?: { id: string; session: string } };
export const clients = new Set<Client>();

export function send(client: Client, message: unknown): void {
	if (!client.socket.destroyed) client.socket.write(`${JSON.stringify(message)}\n`);
}
export function broadcast(message: unknown): void {
	if (clients.size === 0) return;
	// Made into text once, however many apps are connected.
	const line = `${JSON.stringify(message)}\n`;
	for (const client of clients) if (!client.socket.destroyed) client.socket.write(line);
}

/**
 * Sends the event `make` makes to every app at most once every `ms`: at once when none went in the last `ms`, else once
 * at the end of it, made then, so the last state is always sent. Activity lists every run, and was sent again whole for
 * each change to any of them: with 20 runs working, 55 events a second, 360 KB, each of which the app decoded and laid
 * out (#344). The library and the Inbox, sent a few times a second at most, go at once: what is done next often reads
 * them (an approval answered must leave the Inbox before it could be answered again).
 */
export function coalesced(make: () => unknown, ms = 250): () => void {
	let last = Number.NEGATIVE_INFINITY;
	let timer: ReturnType<typeof setTimeout> | undefined;
	const now = () => {
		timer = undefined;
		last = performance.now();
		broadcast(make());
	};
	return () => {
		if (timer !== undefined) return;
		const wait = last + ms - performance.now();
		if (wait <= 0) now();
		else timer = setTimeout(now, wait);
	};
}
