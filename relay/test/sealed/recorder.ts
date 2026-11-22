// The recorder (docs/iphone.md 10, #683): it stands at the relay's edge, in front of the relay's own Worker, and keeps
// everything the relay is given and gives: each connection's request (its address and every header), every message
// in and out, text or bytes, in order, and how each side closed. It passes everything on as it came, so the relay and
// its clients behave as they would without it. It reads back what the relay's objects keep (`dump`), and the pushes the
// local stand-in for Apple's service is asked to send (`push`, for P20, #689: the relay sends none yet).
//
// For tests only, in relay/test: never imported by relay/src, so never in the deployed bundle, which
// scripts/check-bundle.mjs refuses if any of its inputs is outside relay/src.

import type { Event, Push, Stored } from "./scan.ts";

type Handler = (request: Request) => Promise<Response>;

/** A WebSocket close code a socket may be closed with by a program: 1000, or 3000 to 4999. Others mean "none was sent". */
function sendable(code: number): number {
	return code === 1000 || (code >= 3000 && code <= 4999) ? code : 1000;
}

export class Recorder {
	readonly events: Event[] = [];
	readonly pushes: Push[] = [];
	private sockets = 0;

	/** Hands `request` to the relay, and keeps everything that passes on the socket it gives back. */
	async fetch(request: Request, relay: Handler): Promise<Response> {
		const socket = ++this.sockets;
		const headers = [...request.headers];
		const response = await relay(request);
		this.events.push({ socket, kind: "open", method: request.method, url: request.url, headers, status: response.status });
		const upstream = response.webSocket;
		if (response.status !== 101 || upstream === null) return response;

		const [client, server] = Object.values(new WebSocketPair());
		upstream.accept();
		server.accept();
		// Bytes as bytes, not Blobs, which a newer compatibility date gives a socket by default.
		upstream.binaryType = "arraybuffer";
		server.binaryType = "arraybuffer";
		const keep = (from: "end" | "relay", data: string | ArrayBuffer) => {
			if (typeof data === "string") this.events.push({ socket, kind: "text", from, text: data });
			else this.events.push({ socket, kind: "bytes", from, bytes: new Uint8Array(data.slice(0)) });
		};
		server.addEventListener("message", (event) => {
			keep("end", event.data as string | ArrayBuffer);
			try {
				upstream.send(event.data as string | ArrayBuffer);
			} catch {
				// The relay's side is closing: its close follows.
			}
		});
		upstream.addEventListener("message", (event) => {
			keep("relay", event.data as string | ArrayBuffer);
			try {
				server.send(event.data as string | ArrayBuffer);
			} catch {
				// The end's side is closing.
			}
		});
		const closed = { end: false, relay: false };
		server.addEventListener("close", (event) => {
			if (closed.end) return;
			closed.end = true;
			this.events.push({ socket, kind: "close", from: "end", code: event.code, reason: event.reason });
			try {
				upstream.close(sendable(event.code), event.reason);
			} catch {
				// Already closed.
			}
		});
		upstream.addEventListener("close", (event) => {
			if (closed.relay) return;
			closed.relay = true;
			this.events.push({ socket, kind: "close", from: "relay", code: event.code, reason: event.reason });
			try {
				server.close(sendable(event.code), event.reason);
			} catch {
				// Already closed.
			}
		});
		server.addEventListener("error", () => {
			try {
				upstream.close(1011, "");
			} catch {
				// Already closed.
			}
		});
		upstream.addEventListener("error", () => {
			try {
				server.close(1011, "");
			} catch {
				// Already closed.
			}
		});
		return new Response(null, { status: 101, webSocket: client });
	}

	/** Keeps a push the stand-in for Apple's service was asked to send (P20 hands each to this). */
	push(push: Push): void {
		this.pushes.push(push);
	}

	/** The pairings and App Attest keys the recording names, whose objects `dump` reads back. */
	named(): { pairings: string[]; attestKeys: string[] } {
		const pairings = new Set<string>();
		const attestKeys = new Set<string>();
		for (const event of this.events) {
			if (event.kind === "open") {
				for (const [name, value] of event.headers) if (name.toLowerCase() === "pi2-pairing") pairings.add(value);
			}
			if (event.kind !== "text") continue;
			let value: any;
			try {
				value = JSON.parse(event.text);
			} catch {
				continue;
			}
			if (typeof value?.registered?.pairing === "string") pairings.add(value.registered.pairing);
			if (typeof value?.hello?.pairing === "string") pairings.add(value.hello.pairing);
			for (const id of [value?.join?.keyId, value?.joined?.keyId, value?.addDevice?.attestKeyId]) if (typeof id === "string") attestKeys.add(id);
		}
		return { pairings: [...pairings], attestKeys: [...attestKeys] };
	}
}

/** What a Durable Object keeps, read back from its own storage: for the objects of the recording relay (worker.ts). */
export async function dump(object: Stored["object"], name: string, ctx: DurableObjectState): Promise<Stored> {
	const kv = Object.fromEntries(await ctx.storage.list());
	const tables: Stored["tables"] = {};
	const names = ctx.storage.sql.exec<{ name: string }>("SELECT name FROM sqlite_master WHERE type = 'table'").toArray();
	for (const { name: table } of names) {
		// The runtime's own tables: the key-value pairs above, read through its own interface; SQLite's; and the local
		// runtime's record of the object's name (the pairing's id, the key's id, the address's hash), which it is named by.
		if (table.startsWith("_cf_") || table.startsWith("sqlite_") || table === "__miniflare_do_name") continue;
		tables[table] = ctx.storage.sql.exec(`SELECT * FROM "${table.replaceAll('"', '""')}"`).toArray().map((row) =>
			Object.fromEntries(Object.entries(row).map(([column, value]) => [column, value instanceof ArrayBuffer ? new Uint8Array(value) : value])),
		);
	}
	const sockets = ctx.getWebSockets().map((ws) => ws.deserializeAttachment());
	return { object, name, kv, tables, sockets };
}
