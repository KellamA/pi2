// A pairing's Durable Object (docs/iphone.md 5.3): one for each pairing, named by its id. It holds the pairing's
// sockets with the WebSocket Hibernation API, so a pairing whose sockets are idle costs nothing while they stay
// connected; passes sealed bytes between the Mac and its phones without reading past a device's id; keeps the pairing's
// small state (the Mac's relay key, the devices' keys and push tokens, the join window), its mailbox and its limits.
//
// How a connection goes (README.md, "The protocol"): it says `hello` (or `register`), the relay answers a challenge,
// the end signs it (`proof`), or a phone that has no slot yet answers with `join`; only then is it "ready", and only a
// ready socket's messages pass anywhere or count against the pairing's limits. A socket that has not proved itself
// within ten seconds is closed.

import { DurableObject } from "cloudflare:workers";
import { verifyAttestation } from "./attest.ts";
import { base64url, concat, fromBase64url, random, same } from "./bytes.ts";
import { publicKeyBytes, sha256, verifySignature } from "./crypto.ts";
import { checkAttestation, joinClientDataHash, type Verifier } from "./join.ts";
import { Counters, type Day, dayOf, LIMITS, type Limits } from "./limits.ts";
import { DAY, HOUR, Mailbox } from "./mailbox.ts";
import {
	type AddDevice,
	compareBuilds,
	deviceIdBytes,
	type Hello,
	type Join,
	MAX_BINARY,
	type Message,
	PAIRING_HEADER,
	proofText,
	type Put,
	readMessage,
	ROUTE_HEADER,
	type Why,
} from "./protocol.ts";
import { type Env, readSettings, type Settings } from "./settings.ts";

/** How long a connection has to prove itself (3.4: ten seconds). */
const PROVE_WITHIN = 10 * 1000;
/** Connections waiting to prove themselves, at most; a newer one closes the oldest. */
const MAX_WAITING = 16;
/** A pending pairing, which no device was ever added to, is deleted after 15 minutes (6.6). */
const PENDING_FOR = 15 * 60 * 1000;
/** A pairing with no connection for 60 days is deleted (5.3). */
const IDLE_FOR = 60 * DAY;
/** A join window lasts five minutes at most (5.3). */
const WINDOW_FOR = 5 * 60 * 1000;
/** Three refused joins close the window (3.3). */
const WINDOW_TRIES = 3;
/** Phones that may join one window: the engine needs to see a second claim to close it (3.3 step 6). */
const WINDOW_JOINS = 3;
/** Devices listed at most (3.5). */
const MAX_DEVICES = 5;
/** A Mac socket that has sent nothing, not even a ping, for this long is taken for gone (it pings every 30 seconds). */
const MAC_GONE_AFTER = 90 * 1000;
/** A pairing past twice a limit is closed for an hour (6.6). */
const BLOCKED_FOR = HOUR;

const PING = '{"ping":{}}';
const PONG = '{"pong":{}}';

/** What the relay knows of a pairing, kept in its storage. */
type Meta = {
	pairing: string;
	/** The Mac's relay public key, SPKI DER in base64url. */
	relayKey: string;
	/** Until a device is added, when the pairing is deleted; null once one has been. */
	pendingUntil: number | null;
	/** The last time an end connected, or was connected, for the 60 days. */
	lastSeen: number;
	blockedUntil: number | null;
	window: Window | null;
	/** Devices that left while the Mac was away, which it is told when it next connects (3.6). */
	left: string[];
};

type Window = { id: string; tokenHash: string; expires: number; tries: number; joins: number };

/** A device's slot: listed once the Mac added it; until then, a phone that joined the open window. */
type Device = {
	key: string;
	listed: boolean;
	/** The App Attest keys tied to it: the one it joined with, and the one the Mac checked, if another. */
	attestKeyIds: string[];
	token: { apns: string; environment: "development" | "production" } | null;
};

/** What each socket is, kept on it so it survives hibernation. */
type Attachment = {
	/** When it connected, for the ten seconds. */
	at: number;
	/**
	 * `hello` and `register`: waiting for that first message; `mac?`, `device?`, `join?` and `register?`: challenged,
	 * waiting for its proof or its join; `mac`, `device` and `joined`: ready.
	 */
	kind: "hello" | "register" | "mac?" | "device?" | "join?" | "register?" | "mac" | "device" | "joined";
	/** The pairing the Worker named for it. */
	pairing: string;
	challenge?: string;
	device?: string;
	relayKey?: string;
	/** The last time a Mac socket was heard from, kept at most every ten seconds. */
	seen?: number;
};

const CLOSE: Record<Why, number> = {
	malformed: 4000,
	unavailable: 4001,
	"unknown-pairing": 4002,
	"not-listed": 4002,
	signature: 4002,
	"window-closed": 4002,
	token: 4002,
	attestation: 4002,
	category: 4002,
	"bundle-version": 4002,
	"attest-key-taken": 4002,
	"device-key": 4002,
	"unknown-device": 4002,
	exists: 4002,
	full: 4002,
	"mailbox-full": 4002,
	"update-required": 4003,
	"another-mac": 4004,
	limits: 4005,
	"too-many": 4006,
	timeout: 4007,
	removed: 4008,
	left: 4008,
	deleted: 4008,
	"window-ended": 4008,
	replaced: 4009,
};

export class Pairing extends DurableObject<Env> {
	/** App Attest's verifier and the client data hash a join is checked with. Tests stand them in; nothing else does. */
	verify: Verifier = verifyAttestation;
	clientDataHash: (challenge: Uint8Array, deviceKey: Uint8Array) => Promise<Uint8Array> = joinClientDataHash;
	/** 6.6's limits; tests make them smaller. */
	limits: Limits = LIMITS;

	private meta: Meta | null = null;
	private devices: Record<string, Device> = {};
	private counters = new Counters({ day: "", messages: 0, bytes: 0 });
	private readonly mailbox: Mailbox;

	constructor(ctx: DurableObjectState, env: Env) {
		super(ctx, env);
		this.mailbox = new Mailbox(ctx.storage.sql);
		// The Mac's ping every 30 seconds is answered without waking the object (5.9).
		ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair(PING, PONG));
		void ctx.blockConcurrencyWhile(async () => {
			this.meta = (await ctx.storage.get<Meta>("meta")) ?? null;
			this.devices = (await ctx.storage.get<Record<string, Device>>("devices")) ?? {};
			const day = await ctx.storage.get<Day>("day");
			if (day !== undefined) this.counters = new Counters(day);
		});
	}

	async fetch(request: Request): Promise<Response> {
		const route = request.headers.get(ROUTE_HEADER);
		const pairing = request.headers.get(PAIRING_HEADER);
		if ((route !== "hello" && route !== "register") || pairing === null) return new Response(null, { status: 400 });
		const now = Date.now();

		const waiting = this.sockets().filter(([, attachment]) => !isReady(attachment));
		if (waiting.length >= MAX_WAITING) {
			const [oldest] = waiting.sort(([, a], [, b]) => a.at - b.at)[0];
			this.refuse(oldest, "too-many");
		}

		const [client, server] = Object.values(new WebSocketPair());
		this.ctx.acceptWebSocket(server);
		server.serializeAttachment({ at: now, kind: route, pairing } satisfies Attachment);
		await this.schedule(now + PROVE_WITHIN);
		return new Response(null, { status: 101, webSocket: client });
	}

	async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
		const attachment = ws.deserializeAttachment() as Attachment | null;
		if (attachment === null) return;
		const settings = readSettings(this.env);
		if (settings === null) return this.refuse(ws, "unavailable");
		const now = Date.now();
		if (!isReady(attachment)) return this.handshake(ws, attachment, message, settings, now);

		// Only from here on is traffic counted: this socket has proved itself as the pairing's Mac or one of its phones.
		const size = typeof message === "string" ? message.length : message.byteLength;
		const verdict = this.counters.count(size, now, this.limits);
		if (this.counters.due) await this.saveDay();
		if (!verdict.pass) {
			if (verdict.block) return this.block(now);
			return send(ws, { busy: { until: verdict.until } });
		}
		if (attachment.kind === "mac" && (attachment.seen === undefined || now - attachment.seen > 10_000)) {
			ws.serializeAttachment({ ...attachment, seen: now } satisfies Attachment);
		}

		if (typeof message !== "string") return this.pass(ws, attachment, new Uint8Array(message));
		const read = readMessage(message);
		if (read === null) return this.refuse(ws, "malformed");
		if (attachment.kind === "mac") return this.fromMac(ws, read, now);
		if (attachment.kind === "device") return this.fromDevice(ws, attachment, read, now);
		// A phone that joined speaks only through the channel until the Mac adds it.
		return this.refuse(ws, "malformed");
	}

	async webSocketClose(ws: WebSocket): Promise<void> {
		this.gone(ws);
	}

	async webSocketError(ws: WebSocket): Promise<void> {
		this.gone(ws);
	}

	async alarm(): Promise<void> {
		const now = Date.now();
		for (const [ws, attachment] of this.sockets()) {
			if (!isReady(attachment) && now - attachment.at >= PROVE_WITHIN) this.refuse(ws, "timeout");
		}
		const meta = this.meta;
		if (meta === null) {
			// An object a stranger woke by naming a pairing that does not exist keeps nothing.
			if (this.sockets().length === 0) await this.ctx.storage.deleteAll();
			else await this.schedule();
			return;
		}
		if (meta.window !== null && meta.window.expires <= now) await this.closeWindow();
		if ((meta.pendingUntil !== null && meta.pendingUntil <= now) || now - this.lastSeen(now) >= IDLE_FOR) {
			return this.deletePairing();
		}
		if (meta.blockedUntil !== null && meta.blockedUntil <= now) meta.blockedUntil = null;
		await this.save();
		this.mailbox.expire(now);
		await this.forgetOldDay(now);
		if (this.counters.day.day !== "") await this.saveDay();
		await this.schedule();
	}

	// The handshake: hello or register, a challenge, then a proof or a join.

	private async handshake(ws: WebSocket, attachment: Attachment, message: string | ArrayBuffer, settings: Settings, now: number): Promise<void> {
		if (typeof message !== "string") return this.refuse(ws, "malformed");
		const read = readMessage(message);
		if (read === null) return this.refuse(ws, "malformed");
		switch (attachment.kind) {
			case "hello":
				if (read.type !== "hello") return this.refuse(ws, "malformed");
				return this.hello(ws, attachment, read, settings, now);
			case "register":
				if (read.type !== "register") return this.refuse(ws, "malformed");
				if (compareBuilds(read.build, settings.minimum.mac) < 0) return this.refuse(ws, "update-required");
				if (this.meta !== null) return this.refuse(ws, "unavailable");
				return this.challenge(ws, { ...attachment, kind: "register?", relayKey: read.relayKey });
			case "join?":
				if (read.type !== "join") return this.refuse(ws, "malformed");
				return this.join(ws, attachment, read, settings, now);
			case "mac?":
			case "device?":
			case "register?":
				if (read.type !== "proof") return this.refuse(ws, "malformed");
				return this.prove(ws, attachment, read.signature, now);
			default:
				return this.refuse(ws, "malformed");
		}
	}

	private async hello(ws: WebSocket, attachment: Attachment, hello: Hello, settings: Settings, now: number): Promise<void> {
		if (compareBuilds(hello.build, hello.role === "mac" ? settings.minimum.mac : settings.minimum.device) < 0) {
			return this.refuse(ws, "update-required");
		}
		const meta = this.meta;
		if (meta === null || meta.pairing !== hello.pairing || attachment.pairing !== hello.pairing) return this.refuse(ws, "unknown-pairing");
		if (meta.blockedUntil !== null && meta.blockedUntil > now) {
			send(ws, { refused: { why: "limits", until: meta.blockedUntil } });
			return close(ws, "limits");
		}
		// A second Mac is challenged too: only one that proves it holds the relay key is worth telling the connected Mac
		// about, so that a stranger who knows the pairing's id cannot raise the alarm (prove, below).
		if (hello.role === "mac") return this.challenge(ws, { ...attachment, kind: "mac?" });
		if (hello.device !== null) {
			if (this.devices[hello.device]?.listed !== true) return this.refuse(ws, "not-listed");
			return this.challenge(ws, { ...attachment, kind: "device?", device: hello.device });
		}
		// A phone with no slot yet, come to join the open window.
		if (!this.windowOpen(now)) return this.refuse(ws, "window-closed");
		if (meta.window!.joins >= WINDOW_JOINS) return this.refuse(ws, "full");
		return this.challenge(ws, { ...attachment, kind: "join?" });
	}

	private challenge(ws: WebSocket, attachment: Attachment): void {
		const challenge = base64url(random(32));
		ws.serializeAttachment({ ...attachment, challenge } satisfies Attachment);
		send(ws, { challenge });
	}

	private async prove(ws: WebSocket, attachment: Attachment, signature: string, now: number): Promise<void> {
		const challenge = attachment.challenge!;
		if (attachment.kind === "register?") {
			const key = attachment.relayKey!;
			if (!(await verifySignature(key, signature, proofText("register", "", "", challenge)))) return this.refuse(ws, "signature");
			if (this.meta !== null) return this.refuse(ws, "unavailable");
			this.mailbox.create();
			this.meta = {
				pairing: attachment.pairing,
				relayKey: key,
				pendingUntil: now + PENDING_FOR,
				lastSeen: now,
				blockedUntil: null,
				window: null,
				left: [],
			};
			await this.save();
			ws.serializeAttachment({ at: attachment.at, kind: "mac", pairing: attachment.pairing, challenge, seen: now } satisfies Attachment);
			send(ws, { registered: { pairing: attachment.pairing } });
			return this.schedule();
		}

		const meta = this.meta;
		if (meta === null) return this.refuse(ws, "unknown-pairing");
		if (attachment.kind === "mac?") {
			if (!(await verifySignature(meta.relayKey, signature, proofText("mac", meta.pairing, "", challenge)))) return this.refuse(ws, "signature");
			// A Mac socket is connected and alive (or proved itself while this one's signature was being checked).
			if (this.macAlive(now)) return this.anotherMac(ws);
			const old = this.mac();
			if (old !== null) this.refuse(old, "replaced");
			ws.serializeAttachment({ ...attachment, kind: "mac", seen: now } satisfies Attachment);
			meta.lastSeen = now;
			await this.save();
			send(ws, {
				ready: {
					devices: Object.entries(this.devices)
						.filter(([, device]) => device.listed)
						.map(([device]) => ({ device, online: this.deviceSocket(device) !== null })),
					left: meta.left,
					pending: meta.pendingUntil !== null,
					mail: this.mailbox.count("mac"),
				},
			});
			if (meta.left.length > 0) {
				meta.left = [];
				await this.save();
			}
			for (const [socket, other] of this.sockets()) {
				if (other.kind === "device" || other.kind === "joined") send(socket, { mac: { online: true } });
			}
			return;
		}

		// A listed device.
		const id = attachment.device!;
		const device = this.devices[id];
		if (device?.listed !== true) return this.refuse(ws, "not-listed");
		if (!(await verifySignature(device.key, signature, proofText("device", meta.pairing, id, challenge)))) return this.refuse(ws, "signature");
		if (this.devices[id]?.listed !== true) return this.refuse(ws, "not-listed");
		const old = this.deviceSocket(id);
		if (old !== null) this.refuse(old, "replaced");
		ws.serializeAttachment({ ...attachment, kind: "device" } satisfies Attachment);
		meta.lastSeen = now;
		await this.save();
		const mac = this.mac();
		send(ws, { ready: { mac: mac !== null, mail: this.mailbox.count(id) } });
		if (mac !== null) send(mac, { online: { device: id } });
	}

	/**
	 * A phone's join (3.3 step 2): the window is open, the token is the window's, and its attestation is a genuine
	 * pi² for iPhone's for this device key, with an App Attest key tied to no other pairing or device. Each refusal
	 * counts against the window's three tries, and the third closes it.
	 */
	private async join(ws: WebSocket, attachment: Attachment, join: Join, settings: Settings, now: number): Promise<void> {
		const meta = this.meta;
		if (meta === null || join.pairing !== meta.pairing) return this.refuse(ws, "unknown-pairing");
		if (!this.windowOpen(now)) return this.refuse(ws, "window-closed");
		const window = meta.window!;
		if (!same(await sha256(join.token), fromBase64url(window.tokenHash, 32)!)) return this.refuseJoin(ws, window.id, "token");

		const deviceKey = publicKeyBytes(join.deviceKey)!;
		const clientDataHash = await this.clientDataHash(fromBase64url(attachment.challenge!, 32)!, deviceKey);
		const why = await checkAttestation(this.verify, settings, join.attestation, join.keyIdBytes, clientDataHash);
		if (why !== null) return this.refuseJoin(ws, window.id, why);

		const device = `dev_${base64url(random(16))}`;
		const key = this.env.ATTEST_KEYS.get(this.env.ATTEST_KEYS.idFromName(join.keyId));
		if (!(await key.tie(meta.pairing, device))) return this.refuseJoin(ws, window.id, "attest-key-taken");
		// The window may have closed, or filled, while the attestation was checked.
		const still = this.meta?.window;
		if (this.meta !== meta || still?.id !== window.id || !this.windowOpen(Date.now()) || still.joins >= WINDOW_JOINS) {
			await key.untie(meta.pairing, device);
			return this.refuse(ws, still?.id === window.id && still.joins >= WINDOW_JOINS ? "full" : "window-closed");
		}
		still.joins += 1;
		this.devices[device] = { key: join.deviceKey, listed: false, attestKeyIds: [join.keyId], token: null };
		await this.save();
		ws.serializeAttachment({ ...attachment, kind: "joined", device } satisfies Attachment);
		send(ws, { joined: { device } });
		const mac = this.mac();
		if (mac !== null) send(mac, { joined: { device, deviceKey: join.deviceKey, keyId: join.keyId } });
	}

	private async refuseJoin(ws: WebSocket, windowId: string, why: Why): Promise<void> {
		const window = this.meta?.window;
		if (window?.id === windowId) {
			window.tries += 1;
			if (window.tries >= WINDOW_TRIES) await this.closeWindow();
			else await this.save();
		}
		this.refuse(ws, why);
	}

	// What a ready end sends.

	/** Passes a binary message on: a phone's to the Mac with its id in front, the Mac's to the phone its id names. */
	private pass(ws: WebSocket, attachment: Attachment, bytes: Uint8Array): void {
		if (bytes.length > MAX_BINARY) return this.refuse(ws, "malformed");
		if (attachment.kind === "mac") {
			if (bytes.length <= 16) return this.refuse(ws, "malformed");
			const device = `dev_${base64url(bytes.subarray(0, 16))}`;
			const target = this.deviceSocket(device) ?? this.joinedSocket(device);
			if (target === null) return send(ws, { offline: { device } });
			return sendBytes(target, bytes.slice(16));
		}
		if (bytes.length === 0) return this.refuse(ws, "malformed");
		const mac = this.mac();
		if (mac === null) return send(ws, { mac: { online: false } });
		sendBytes(mac, concat(deviceIdBytes(attachment.device!), bytes));
	}

	private async fromMac(ws: WebSocket, message: Message, now: number): Promise<void> {
		const meta = this.meta!;
		switch (message.type) {
			case "openJoin": {
				if (message.expires <= now) return refused(ws, "openJoin", "malformed");
				if (meta.window !== null) await this.closeWindow();
				meta.window = {
					id: base64url(random(16)),
					tokenHash: base64url(message.tokenHash),
					expires: Math.min(message.expires, now + WINDOW_FOR),
					tries: 0,
					joins: 0,
				};
				await this.save();
				await this.schedule();
				return ok(ws, "openJoin");
			}
			case "closeJoin":
				await this.closeWindow();
				return ok(ws, "closeJoin");
			case "addDevice":
				return this.addDevice(ws, message);
			case "removeDevice":
				if (this.devices[message.device] === undefined) return refused(ws, "removeDevice", "unknown-device");
				await this.removeDevice(message.device, "removed");
				return ok(ws, "removeDevice");
			case "deletePairing":
				ok(ws, "deletePairing");
				return this.deletePairing();
			case "state": {
				if (this.devices[message.device]?.listed !== true) return refused(ws, "state", "unknown-device");
				this.mailbox.setState(message.device, message.id, message.item, now + DAY);
				await this.schedule();
				const socket = this.deviceSocket(message.device);
				if (socket !== null) send(socket, { mail: {} });
				return ok(ws, "state");
			}
			case "put":
				if (this.devices[message.to]?.listed !== true) return refused(ws, "put", "unknown-device");
				return this.put(ws, message, "mac", now);
			case "take":
				return this.take(ws, "mac", now);
			default:
				return this.refuse(ws, "malformed");
		}
	}

	private async fromDevice(ws: WebSocket, attachment: Attachment, message: Message, now: number): Promise<void> {
		const id = attachment.device!;
		const device = this.devices[id];
		if (device?.listed !== true) return this.refuse(ws, "not-listed");
		switch (message.type) {
			case "put":
				if (message.to !== "mac") return this.refuse(ws, "malformed");
				return this.put(ws, message, id, now);
			case "take":
				return this.take(ws, id, now);
			case "token":
				device.token = { apns: message.apns, environment: message.environment };
				await this.save();
				return ok(ws, "token");
			case "leave": {
				const meta = this.meta!;
				if (!(await verifySignature(device.key, message.signature, proofText("leave", meta.pairing, id, attachment.challenge!)))) {
					return this.refuse(ws, "signature");
				}
				await this.removeDevice(id, "left");
				const mac = this.mac();
				if (mac !== null) send(mac, { left: { device: id } });
				else if (this.meta !== null) {
					this.meta.left.push(id);
					await this.save();
				}
				return;
			}
			default:
				return this.refuse(ws, "malformed");
		}
	}

	private async addDevice(ws: WebSocket, message: AddDevice): Promise<void> {
		const meta = this.meta!;
		const refusal = this.cannotAdd(message);
		if (refusal !== null) return refused(ws, "addDevice", refusal);
		const key = this.env.ATTEST_KEYS.get(this.env.ATTEST_KEYS.idFromName(message.attestKeyId));
		const joined = this.devices[message.device];

		// Tie the App Attest key the Mac checked to this device. A phone that joined under another slot with this key has
		// it moved here, and that slot is let go.
		let from: string | null = null;
		const tiedBefore = joined?.attestKeyIds.includes(message.attestKeyId) === true;
		if (!tiedBefore && !(await key.tie(meta.pairing, message.device))) {
			from = Object.keys(this.devices).find((id) => !this.devices[id].listed && this.devices[id].attestKeyIds.includes(message.attestKeyId)) ?? null;
			if (from === null || !(await key.retie(meta.pairing, from, message.device))) return refused(ws, "addDevice", "attest-key-taken");
		}
		// The pairing may have changed while the key was being tied.
		const late = this.meta !== meta ? "unknown-device" : this.cannotAdd(message);
		if (late !== null) {
			if (!tiedBefore) await key.untie(meta.pairing, message.device);
			return refused(ws, "addDevice", late);
		}
		if (from !== null && this.devices[from] !== undefined) {
			const others = this.devices[from].attestKeyIds.filter((id) => id !== message.attestKeyId);
			await this.forgetSlot(from, others, "replaced");
		}
		const existing = this.devices[message.device];
		if (existing !== undefined) {
			if (!existing.attestKeyIds.includes(message.attestKeyId)) existing.attestKeyIds.push(message.attestKeyId);
			existing.listed = true;
		} else {
			this.devices[message.device] = { key: message.deviceKey, listed: true, attestKeyIds: [message.attestKeyId], token: null };
		}
		meta.pendingUntil = null;
		await this.save();
		const socket = this.joinedSocket(message.device);
		if (socket !== null) {
			socket.serializeAttachment({ ...(socket.deserializeAttachment() as Attachment), kind: "device" } satisfies Attachment);
		}
		await this.schedule();
		return ok(ws, "addDevice");
	}

	/** Why the Mac's `addDevice` cannot be done as things stand, or null. */
	private cannotAdd(message: AddDevice): Why | null {
		const existing = this.devices[message.device];
		if (existing?.listed === true) return "exists";
		if (Object.values(this.devices).filter((device) => device.listed).length >= MAX_DEVICES) return "full";
		// The phone that joined under this id: the Mac must have checked the same device key it joined with.
		if (existing !== undefined && existing.key !== message.deviceKey) return "device-key";
		return null;
	}

	private async put(ws: WebSocket, message: Put, writer: string, now: number): Promise<void> {
		// An item carrying a presence signature is kept an hour, any other a day (4.3, 5.3).
		const expires = now + (message.presence ? HOUR : DAY);
		const why = this.mailbox.put(message.to, writer, message.id, message.item, message.presence, expires, now);
		if (why !== null) return refused(ws, "put", why);
		await this.schedule();
		const reader = message.to === "mac" ? this.mac() : this.deviceSocket(message.to);
		if (reader !== null) send(reader, { mail: {} });
		return ok(ws, "put");
	}

	private async take(ws: WebSocket, reader: string, now: number): Promise<void> {
		const { items, state } = this.mailbox.take(reader, now);
		for (const item of items) {
			send(ws, { item: { from: item.writer, id: item.id, item: base64url(item.item), presence: item.presence } });
		}
		if (state !== null) send(ws, { state: { id: state.id, item: base64url(state.item) } });
		send(ws, { taken: { count: items.length + (state === null ? 0 : 1) } });
	}

	// Revocation, leaving, deleting.

	/** Removes a device's slot: closes its socket, deletes its keys, push token and mailbox, unties its App Attest keys. */
	private async removeDevice(id: string, why: "removed" | "left"): Promise<void> {
		const device = this.devices[id];
		if (device === undefined) return;
		await this.forgetSlot(id, device.attestKeyIds, why);
	}

	private async forgetSlot(id: string, attestKeyIds: string[], why: Why): Promise<void> {
		const meta = this.meta;
		delete this.devices[id];
		this.mailbox.forget(id);
		await this.save();
		if (meta !== null) {
			for (const keyId of attestKeyIds) await this.env.ATTEST_KEYS.get(this.env.ATTEST_KEYS.idFromName(keyId)).untie(meta.pairing, id);
		}
		// Closed last, so that once a socket learns it was removed, nothing of it is left.
		for (const [ws, attachment] of this.sockets()) {
			if (attachment.device === id) this.refuse(ws, why);
		}
	}

	/** Closes the join window, and the slots of phones that joined it and were not added. */
	private async closeWindow(): Promise<void> {
		const meta = this.meta;
		if (meta === null) return;
		meta.window = null;
		await this.save();
		for (const [id, device] of Object.entries(this.devices)) {
			if (!device.listed) await this.forgetSlot(id, device.attestKeyIds, "window-ended");
		}
	}

	/** Deletes the pairing: every socket closed, every App Attest key untied, and all it kept. */
	private async deletePairing(): Promise<void> {
		const meta = this.meta;
		const devices = this.devices;
		this.meta = null;
		this.devices = {};
		this.counters = new Counters({ day: "", messages: 0, bytes: 0 });
		await this.ctx.storage.deleteAlarm();
		await this.ctx.storage.deleteAll();
		if (meta !== null) {
			for (const [id, device] of Object.entries(devices)) {
				for (const keyId of device.attestKeyIds) await this.env.ATTEST_KEYS.get(this.env.ATTEST_KEYS.idFromName(keyId)).untie(meta.pairing, id);
			}
		}
		// Closed last, so that once an end learns the pairing was deleted, nothing of it is left.
		for (const [ws] of this.sockets()) this.refuse(ws, "deleted");
	}

	/** Past twice a limit: every ready socket closed, and the pairing refused for an hour (6.6). */
	private async block(now: number): Promise<void> {
		const meta = this.meta;
		if (meta === null) return;
		meta.blockedUntil = now + BLOCKED_FOR;
		await this.save();
		await this.saveDay();
		for (const [ws, attachment] of this.sockets()) {
			if (!isReady(attachment)) continue;
			send(ws, { refused: { why: "limits", until: meta.blockedUntil } });
			close(ws, "limits");
		}
		await this.schedule();
	}

	// The sockets.

	private sockets(): [WebSocket, Attachment][] {
		const out: [WebSocket, Attachment][] = [];
		for (const ws of this.ctx.getWebSockets()) {
			const attachment = ws.deserializeAttachment() as Attachment | null;
			if (attachment !== null && ws.readyState === WebSocket.OPEN) out.push([ws, attachment]);
		}
		return out;
	}

	private mac(): WebSocket | null {
		return this.sockets().find(([, attachment]) => attachment.kind === "mac")?.[0] ?? null;
	}

	/**
	 * Whether a Mac socket is connected and has been heard from lately. One that has sent nothing, not even a ping, for
	 * 90 seconds is gone without having closed, and a new Mac may take its place.
	 */
	private macAlive(now: number): boolean {
		const found = this.sockets().find(([, attachment]) => attachment.kind === "mac");
		if (found === undefined) return false;
		const [ws, attachment] = found;
		const pinged = this.ctx.getWebSocketAutoResponseTimestamp(ws)?.getTime() ?? 0;
		return now - Math.max(attachment.at, attachment.seen ?? 0, pinged) < MAC_GONE_AFTER;
	}

	/**
	 * A second Mac that proved itself is refused, and the connected one told (3.4): the relay never replaces a live Mac
	 * socket. Only something holding the relay key gets this far, so the Devices page's warning means what it says.
	 */
	private anotherMac(ws: WebSocket): void {
		const mac = this.mac();
		if (mac !== null) send(mac, { anotherMac: {} });
		this.refuse(ws, "another-mac");
	}

	private deviceSocket(device: string): WebSocket | null {
		return this.sockets().find(([, attachment]) => attachment.kind === "device" && attachment.device === device)?.[0] ?? null;
	}

	private joinedSocket(device: string): WebSocket | null {
		return this.sockets().find(([, attachment]) => attachment.kind === "joined" && attachment.device === device)?.[0] ?? null;
	}

	private gone(ws: WebSocket): void {
		const attachment = ws.deserializeAttachment() as Attachment | null;
		if (attachment === null) return;
		// Mark it, so that the sockets still listed while it closes are not taken for it.
		ws.serializeAttachment(null);
		if (attachment.kind === "mac") {
			for (const [socket, other] of this.sockets()) {
				if (other.kind === "device" || other.kind === "joined") send(socket, { mac: { online: false } });
			}
		} else if (attachment.kind === "device" || attachment.kind === "joined") {
			const mac = this.mac();
			if (mac !== null) send(mac, { offline: { device: attachment.device } });
		}
	}

	private refuse(ws: WebSocket, why: Why): void {
		send(ws, { refused: { why } });
		close(ws, why);
	}

	/** Whether a day's counts are kept from an earlier day, and so are to be forgotten. */
	private async forgetOldDay(now: number): Promise<void> {
		if (this.counters.day.day === "" || this.counters.day.day === dayOf(now)) return;
		this.counters = new Counters({ day: "", messages: 0, bytes: 0 });
		await this.ctx.storage.delete("day");
	}

	private windowOpen(now: number): boolean {
		const window = this.meta?.window;
		return window !== null && window !== undefined && window.expires > now && window.tries < WINDOW_TRIES;
	}

	private lastSeen(now: number): number {
		const meta = this.meta!;
		if (this.sockets().some(([, attachment]) => isReady(attachment))) meta.lastSeen = now;
		return meta.lastSeen;
	}

	// Storage.

	private async save(): Promise<void> {
		if (this.meta === null) return;
		await this.ctx.storage.put({ meta: this.meta, devices: this.devices });
	}

	private async saveDay(): Promise<void> {
		if (this.meta === null) return;
		await this.ctx.storage.put("day", this.counters.day);
		this.counters.saved();
	}

	/** Sets the alarm for the next thing due: a socket's ten seconds, the window, the pending or idle pairing, an item. */
	private async schedule(soon?: number): Promise<void> {
		const times: number[] = [];
		if (soon !== undefined) times.push(soon);
		for (const [, attachment] of this.sockets()) {
			if (!isReady(attachment)) times.push(attachment.at + PROVE_WITHIN);
		}
		const meta = this.meta;
		if (meta !== null) {
			if (meta.window !== null) times.push(meta.window.expires);
			if (meta.pendingUntil !== null) times.push(meta.pendingUntil);
			if (meta.blockedUntil !== null) times.push(meta.blockedUntil);
			times.push(meta.lastSeen + IDLE_FOR);
			const expiry = this.mailbox.nextExpiry();
			if (expiry !== null) times.push(expiry);
			// The day's counts are kept for a day.
			if (this.counters.day.day !== "") times.push(Date.parse(`${dayOf(Date.now())}T00:00:00Z`) + DAY);
		}
		if (times.length === 0) return;
		const next = Math.min(...times);
		const current = await this.ctx.storage.getAlarm();
		if (current === null || current > next || current < Date.now()) await this.ctx.storage.setAlarm(next);
	}
}

function isReady(attachment: Attachment): boolean {
	return attachment.kind === "mac" || attachment.kind === "device" || attachment.kind === "joined";
}

function send(ws: WebSocket, message: object): void {
	try {
		ws.send(JSON.stringify(message));
	} catch {
		// Closed while this was being sent: nothing to tell it.
	}
}

function sendBytes(ws: WebSocket, bytes: Uint8Array): void {
	try {
		ws.send(bytes);
	} catch {
		// As above.
	}
}

/** Closes a socket the relay is done with. It is marked first, so that its closing tells nobody it went offline. */
function close(ws: WebSocket, why: Why): void {
	try {
		ws.serializeAttachment(null);
		ws.close(CLOSE[why], why);
	} catch {
		// Already closing.
	}
}

function ok(ws: WebSocket, what: Message["type"]): void {
	send(ws, { ok: { what } });
}

/** A request the relay does not carry out, on a socket it keeps open. */
function refused(ws: WebSocket, what: Message["type"], why: Why): void {
	send(ws, { refused: { what, why } });
}
