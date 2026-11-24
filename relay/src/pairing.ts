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
import { type Apns, apnsFor, MAX_WAITING_PUSHES, PUSH_LIMITS, PushCounts, type PushHour, type PushLimits } from "./apns.ts";
import { verifyAttestation } from "./attest.ts";
import { base64url, concat, fromBase64url, random, same } from "./bytes.ts";
import { publicKeyBytes, sha256, verifySignature } from "./crypto.ts";
import { checkAttestation, joinClientDataHash, type Verifier } from "./join.ts";
import { Counters, type Day, JOINED_LIMITS, LIMITS, type Limits, PENDING_LIMITS } from "./limits.ts";
import { DAY, HOUR, Mailbox } from "./mailbox.ts";
import {
	type AddDevice,
	compareBuilds,
	deviceIdBytes,
	type Hello,
	type Join,
	type Left,
	MAX_BINARY,
	type Message,
	PAIRING_HEADER,
	proofText,
	type Push,
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
/** How often the time an end was last connected is written, at most. */
const TOUCH_EVERY = 60 * 1000;
/** A pairing with no connection for 60 days is deleted (5.3). */
const IDLE_FOR = 60 * DAY;
/** A join window lasts five minutes at most (5.3). */
const WINDOW_FOR = 5 * 60 * 1000;
/** Three refused joins close the window (3.3). */
const WINDOW_TRIES = 3;
/** Phones that may join one window: the engine needs to see a second claim to close it (3.3 step 6). */
const WINDOW_JOINS = 3;
/**
 * Join windows the Mac may open in any minute (6.6). Opening one is a write or two, and closing it another, so the Mac's
 * whole allowance of messages spent on them would be hundreds of writes a second; a person pairing a phone, and trying
 * again a few times, opens a handful in some minutes.
 */
const WINDOWS_A_MINUTE = 10;
const MINUTE = 60 * 1000;
/** Devices listed at most (3.5). */
const MAX_DEVICES = 5;
/** A Mac socket that has sent nothing, not even a ping, for this long is taken for gone (it pings every 30 seconds). */
const MAC_GONE_AFTER = 90 * 1000;
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
	/** The ends past their day's limit, by "mac" or device id, and until when each is held off (6.6). */
	blocked: Record<string, number>;
	window: Window | null;
	/**
	 * Devices that left while the Mac was away, which it is told when it next connects (3.6), each with the time and the
	 * notice its phone signed for the Mac. At most five: only the Mac adds a device, and the list is emptied when it connects.
	 */
	left: Left[];
	/** When the join windows of the last minute were opened, for their limit (`WINDOWS_A_MINUTE`). */
	opened?: number[];
};

type Window = { id: string; tokenHash: string; expires: number; tries: number; joins: number };

/** A device's slot: listed once the Mac added it; until then, a phone that joined the open window. */
type Device = {
	key: string;
	listed: boolean;
	/** The App Attest key the relay checked when the phone joined, tied to this device (claims.ts). */
	attestKeyIds: string[];
	/**
	 * The App Attest key the Mac checked at pairing, as `addDevice` named it: recorded, never tied, since the relay never
	 * checked its attestation. A key is attested once, so it is another key than the relay's (3.2).
	 */
	macKeyId: string | null;
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
	"not-joined": 4002,
	"unknown-device": 4002,
	exists: 4002,
	full: 4002,
	"mailbox-full": 4002,
	busy: 4010,
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
	"no-token": 4002,
	"token-dead": 4002,
	"push-limit": 4002,
	"push-later": 4002,
};

export class Pairing extends DurableObject<Env> {
	/** App Attest's verifier and the client data hash a join is checked with. Tests stand them in; nothing else does. */
	verify: Verifier = verifyAttestation;
	clientDataHash: (challenge: Uint8Array, deviceKey: Uint8Array) => Promise<Uint8Array> = joinClientDataHash;
	/** 6.6's limits for each end, and the smaller ones of a phone that has only joined; tests make them smaller. */
	limits: Limits = LIMITS;
	joinedLimits: Limits = JOINED_LIMITS;
	pendingLimits: Limits = PENDING_LIMITS;
	/** The join windows the Mac may open in any minute; tests change it. */
	windowsAMinute = WINDOWS_A_MINUTE;

	/** The object of an App Attest key's tie (claims.ts). Tests stand it in, to make its calls fail; nothing else does. */
	keyObject(keyId: string): Pick<DurableObjectStub<import("./claims.ts").AttestKey>, "tie" | "retie" | "untie"> {
		return this.env.ATTEST_KEYS.get(this.env.ATTEST_KEYS.idFromName(keyId));
	}

	/** Apple's push service with the deployment's push key (apns.ts). Tests stand in Apple's service (test/apns.ts); nothing else does. */
	apns: (topic: string) => Apns | null = (topic) => apnsFor(this.env, topic);
	/** 6.6's push limits; tests make them smaller. */
	pushLimits: PushLimits = PUSH_LIMITS;
	private pushCounts = new PushCounts(undefined);
	/** The pushes in hand, one at a time, so that the Mac's answers come in the order it asked; and how many wait. */
	private pushing: Promise<void> = Promise.resolve();
	private pushesWaiting = 0;

	private meta: Meta | null = null;
	private devices: Record<string, Device> = {};
	private counters = new Counters({});
	private readonly mailbox: Mailbox;

	constructor(ctx: DurableObjectState, env: Env) {
		super(ctx, env);
		this.mailbox = new Mailbox(ctx.storage.sql);
		// The Mac's ping every 30 seconds is answered without waking the object (5.9).
		ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair(PING, PONG));
		void ctx.blockConcurrencyWhile(async () => {
			this.meta = (await ctx.storage.get<Meta>("meta")) ?? null;
			this.devices = (await ctx.storage.get<Record<string, Device>>("devices")) ?? {};
			const days = await ctx.storage.get<Record<string, Day>>("days");
			if (days !== undefined) this.counters = new Counters(days);
			this.pushCounts = new PushCounts(await ctx.storage.get<PushHour>("pushes"));
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

		// The sender must still be there, as things stand at this message: a deleted pairing's or a removed device's
		// socket passes nothing, whatever was in flight while it was being closed.
		const meta = this.meta;
		if (meta === null) return this.refuse(ws, "deleted");
		if (attachment.kind !== "mac" && this.devices[attachment.device!] === undefined) return this.refuse(ws, "removed");

		// Only from here on is traffic counted: this socket has proved itself as the pairing's Mac or one of its phones,
		// and it is counted as its own sender's alone. The Mac's requests that take a device, the window or the pairing
		// away are not counted when they do take something away, so that nothing ever keeps the Mac from them; a few in a
		// pairing's life. When there is nothing to take away they are counted like anything else, so that repeating them
		// costs the relay nothing it does not count.
		const read = typeof message === "string" ? readMessage(message) : null;
		// A pending pairing (no phone added yet) has nothing to revoke, and its Mac needs no genuine app: everything it
		// sends is counted, against the small allowance of PENDING_LIMITS, decided from the record before any write.
		const pending = meta.pendingUntil !== null;
		const control =
			attachment.kind === "mac" &&
			!pending &&
			((read?.type === "removeDevice" && this.devices[read.device] !== undefined) ||
				(read?.type === "closeJoin" && meta.window !== null) ||
				read?.type === "deletePairing");
		if (!control) {
			const sender = attachment.kind === "mac" ? "mac" : attachment.device!;
			const blocked = meta.blocked[sender];
			if (blocked !== undefined && blocked > now) return this.holdOff(ws, blocked);
			const size = typeof message === "string" ? new TextEncoder().encode(message).length : message.byteLength;
			const limits = attachment.kind === "joined" ? this.joinedLimits : attachment.kind === "mac" && pending ? this.pendingLimits : this.limits;
			const verdict = this.counters.count(sender, size, now, limits);
			if (this.counters.due) await this.saveDays();
			if (!verdict.pass) {
				if (verdict.day) {
					meta.blocked[sender] = verdict.until;
					await this.save();
					await this.schedule();
				}
				return this.holdOff(ws, verdict.until);
			}
		}
		if (attachment.kind === "mac" && (attachment.seen === undefined || now - attachment.seen > 10_000)) {
			ws.serializeAttachment({ ...attachment, seen: now } satisfies Attachment);
		}

		if (typeof message !== "string") return this.pass(ws, attachment, new Uint8Array(message));
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
		// Only what changed is written: an alarm that finds nothing to do writes nothing but the next alarm.
		let changed = this.sockets().some(([, attachment]) => isReady(attachment)) && this.touch(now);
		if ((meta.pendingUntil !== null && meta.pendingUntil <= now) || now - meta.lastSeen >= IDLE_FOR) {
			return this.deletePairing();
		}
		for (const [sender, until] of Object.entries(meta.blocked)) {
			if (until > now) continue;
			delete meta.blocked[sender];
			changed = true;
		}
		// The push counts of an hour that is over are not kept past it.
		if (this.pushCounts.roll(now)) changed = true;
		if (changed) await this.save();
		this.mailbox.expire(now);
		if (this.counters.forgetBefore(now) || this.counters.dirty) await this.saveDays();
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
		// A second Mac is challenged too: only one that proves it holds the relay key is worth telling the connected Mac
		// about, so that a stranger who knows the pairing's id cannot raise the alarm (prove, below).
		if (hello.role === "mac") return this.challenge(ws, { ...attachment, kind: "mac?" });
		if (hello.device !== null) {
			if (this.devices[hello.device]?.listed !== true) return this.refuse(ws, "not-listed");
			// A phone past its day's limit is held off for the hour; nobody else is, the Mac least of all.
			const blocked = meta.blocked[hello.device];
			if (blocked !== undefined && blocked > now) return this.holdOff(ws, blocked);
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
				blocked: {},
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
			if (this.touch(now)) await this.save();
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
		if (this.touch(now)) await this.save();
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
		let tied: boolean;
		try {
			tied = await this.keyObject(join.keyId).tie(meta.pairing, device);
		} catch {
			return this.refuse(ws, "unavailable");
		}
		if (!tied) return this.refuseJoin(ws, window.id, "attest-key-taken");
		// The window may have closed, or filled, while the attestation was checked.
		const still = this.meta?.window;
		if (this.meta !== meta || still?.id !== window.id || !this.windowOpen(Date.now()) || still.joins >= WINDOW_JOINS) {
			this.refuse(ws, still?.id === window.id && still.joins >= WINDOW_JOINS ? "full" : "window-closed");
			return this.untie(meta.pairing, device, [join.keyId]);
		}
		still.joins += 1;
		this.devices[device] = { key: join.deviceKey, listed: false, attestKeyIds: [join.keyId], macKeyId: null, token: null };
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
				// Past the minute's windows, the Mac is held off as past any other limit, until the oldest is a minute old.
				// The times are kept in the record that opening a window writes anyway, so they cost no write of their own and
				// last when the object leaves memory; one refused writes nothing.
				const opened = (meta.opened ?? []).filter((time) => now - time < MINUTE);
				if (opened.length >= this.windowsAMinute) return this.holdOff(ws, opened[0] + MINUTE);
				meta.opened = [...opened, now];
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
				// A device already gone is removed: the Mac asking again, after a failure it could not see, is answered as done.
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
			case "took":
				this.mailbox.took("mac", message.ids);
				return ok(ws, "took");
			case "push":
				// At most MAX_WAITING_PUSHES wait their turn; one past that is answered push-later in its turn, kept meanwhile
				// as no more than its socket.
				return this.inTurn(this.pushesWaiting < MAX_WAITING_PUSHES ? this.pushStep(ws, message) : laterStep(ws));
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
			case "took":
				this.mailbox.took(id, message.ids);
				return ok(ws, "took");
			case "token":
				// The phone gives its token at every connection (apns.ts): written only when it changed.
				if (device.token?.apns !== message.apns || device.token.environment !== message.environment) {
					device.token = { apns: message.apns, environment: message.environment };
					await this.save();
				}
				return ok(ws, "token");
			case "dropToken":
				if (device.token !== null) {
					device.token = null;
					await this.save();
				}
				return ok(ws, "dropToken");
			case "leave": {
				const meta = this.meta!;
				if (!(await verifySignature(device.key, message.signature, proofText("leave", meta.pairing, id, attachment.challenge!)))) {
					return this.refuse(ws, "signature");
				}
				await this.removeDevice(id, "left");
				// The phone's notice goes to the Mac as it came: the relay cannot check it, and the Mac believes nothing else.
				const left: Left = { device: id, at: message.at, notice: message.notice };
				const mac = this.mac();
				if (mac !== null) send(mac, { left });
				else if (this.meta !== null) {
					this.meta.left.push(left);
					await this.save();
				}
				return;
			}
			default:
				return this.refuse(ws, "malformed");
		}
	}

	/**
	 * The Mac adds a phone it paired (3.3 step 8), under the engine's id for it. Only a phone that joined this pairing at
	 * the relay, with its App Attest attestation, can be added, so the relay carries traffic only between a Mac and a
	 * genuine pi² for iPhone (6.6), whatever a Mac of someone's own making asks. The joined slot is found by the device
	 * key, which both of the phone's attestations bind (the relay's at the join, the Mac's in `pair`); the phone has two
	 * App Attest keys, since a key is attested once (3.2), so `attestKeyId` is the Mac's, which the relay never saw. The
	 * relay's own key's tie moves to the engine's id, and the Mac's is recorded, not tied.
	 */
	private async addDevice(ws: WebSocket, message: AddDevice): Promise<void> {
		const meta = this.meta!;
		const found = this.addable(message);
		if (typeof found !== "object") return refused(ws, "addDevice", found);
		const { slot, others } = found;
		const relayKeys = this.devices[slot].attestKeyIds;
		if (slot !== message.device) {
			for (const keyId of relayKeys) {
				let moved: boolean;
				try {
					moved = await this.keyObject(keyId).retie(meta.pairing, slot, message.device);
				} catch {
					return refused(ws, "addDevice", "unavailable");
				}
				if (!moved) return refused(ws, "addDevice", "attest-key-taken");
			}
		}
		// The pairing may have changed while the ties were being moved.
		const late = this.meta !== meta ? "not-joined" : this.addable(message);
		if (typeof late !== "object" || late.slot !== slot) {
			if (slot !== message.device) {
				for (const keyId of relayKeys) await this.keyObject(keyId).retie(meta.pairing, message.device, slot).catch(() => false);
			}
			return refused(ws, "addDevice", typeof late !== "object" ? late : "not-joined");
		}

		const device: Device = { ...this.devices[slot], listed: true, macKeyId: message.attestKeyId };
		// The same phone's other slots are let go: their sockets closed now, their ties untied below.
		const dropped = others.filter((id) => this.devices[id] !== undefined).map((id) => [id, this.dropSlot(id, "replaced")] as const);
		delete this.devices[slot];
		this.counters.forget(slot);
		this.devices[message.device] = device;
		meta.pendingUntil = null;
		await this.save();
		// The phone's socket carries on under the engine's id, so the pairing exchange on it is not cut: the Mac's bytes for
		// it now carry that id, and so do its bytes to the Mac. The phone learns the id in `paired`, and says it at its
		// next hello.
		const socket = this.joinedSocket(slot);
		if (socket !== null) {
			socket.serializeAttachment({ ...(socket.deserializeAttachment() as Attachment), kind: "device", device: message.device } satisfies Attachment);
		}
		await this.schedule();
		ok(ws, "addDevice");
		for (const [id, keyIds] of dropped) await this.untie(meta.pairing, id, keyIds);
	}

	/**
	 * The slot of the joined phone the Mac's `addDevice` is for, found by its device key, and the other slots the same
	 * phone joined with (its socket dropped after `join` and it joined again); or why it cannot be added. The slot with a
	 * live socket is taken, else the latest; the others are let go.
	 */
	private addable(message: AddDevice): { slot: string; others: string[] } | Why {
		if (this.devices[message.device]?.listed === true) return "exists";
		const named = this.devices[message.device];
		// The engine's id names the slot only if the Mac chose to use the slot's own id; then it must be that phone.
		if (named !== undefined && named.key !== message.deviceKey) return "device-key";
		const slots = Object.keys(this.devices).filter((id) => !this.devices[id].listed && this.devices[id].key === message.deviceKey);
		if (slots.length === 0) return "not-joined";
		const slot = named !== undefined ? message.device : (slots.findLast((id) => this.joinedSocket(id) !== null) ?? slots[slots.length - 1]);
		if (Object.values(this.devices).filter((device) => device.listed).length >= MAX_DEVICES) return "full";
		return { slot, others: slots.filter((id) => id !== slot) };
	}

	private async put(ws: WebSocket, message: Put, writer: string, now: number): Promise<void> {
		// An item marked `presence`, whose request is a `"face"` one (a widening answer, 4.2, 4.3), is kept an hour, any
		// other a day (5.3). The relay sees only the flag.
		const expires = now + (message.presence ? HOUR : DAY);
		const why = this.mailbox.put(message.to, writer, message.id, message.item, message.presence, expires, now);
		if (why !== null) return refused(ws, "put", why);
		await this.schedule();
		const reader = message.to === "mac" ? this.mac() : this.deviceSocket(message.to);
		if (reader !== null) send(reader, { mail: {} });
		return ok(ws, "put");
	}

	/**
	 * Hands over what waits for `reader`, deleting nothing: the reader names what it kept in `took`, and the rest comes
	 * again at its next take, until it expires (#806).
	 *
	 * What a take hands over **again**, an item or a state a take handed over before and the reader did not acknowledge,
	 * counts against the reader's own day of data (500 MB), as if it had sent it. A reader that never says what it kept
	 * would otherwise be sent its whole mailbox, up to some 2 MB, at every take, as often as its messages allow (100 a
	 * second): a take is a few bytes in, and nothing else that small brings so much out. What it is handed for the first
	 * time is not charged to it: its writer paid for it with its `put` (or the Mac with its `state`), so no end's writing
	 * spends another's day (6.6), and an honest reader, which acknowledges what it takes, is charged nothing for its
	 * takes. Against the day alone, not the second's 2 MB, so that a phone's full mailbox handed over again (100 items of
	 * 16 KB and its state, some 2.2 MB as sent) and the `took` after it pass. An item handed over on a socket that dropped
	 * before it arrived is charged when it comes again: one mailbox for each drop, at most.
	 */
	private async take(ws: WebSocket, reader: string, now: number): Promise<void> {
		const { items, state } = this.mailbox.take(reader, now);
		const texts: string[] = [];
		// Every text here is ASCII (ids, base64url), so its length is its size in bytes.
		let again = 0;
		for (const item of items) {
			const text = JSON.stringify({ item: { from: item.writer, id: item.id, item: base64url(item.item), presence: item.presence } });
			texts.push(text);
			if (item.handed) again += text.length;
		}
		if (state !== null) {
			const text = JSON.stringify({ state: { id: state.id, item: base64url(state.item) } });
			texts.push(text);
			if (state.handed) again += text.length;
		}
		texts.push(JSON.stringify({ taken: { count: items.length + (state === null ? 0 : 1) } }));
		if (again > 0) {
			this.counters.addToDay(reader, again, now);
			// Saved by weight (limits.ts), so that an object leaving memory forgets at most a few megabytes of it.
			if (this.counters.due) await this.saveDays();
		}
		for (const text of texts) sendText(ws, text);
	}

	// Revocation, leaving, deleting.

	/** Removes a device's slot: closes its socket, deletes its keys, push token and mailbox, unties its App Attest keys. */
	private async removeDevice(id: string, why: "removed" | "left"): Promise<void> {
		const device = this.devices[id];
		if (device === undefined) return;
		await this.forgetSlot(id, why);
	}

	/**
	 * Forgets a slot and closes its socket before anything waits on another object, so that nothing of it passes
	 * meanwhile, and whether or not the calls to untie its App Attest keys succeed (each tie goes by itself in a week).
	 */
	private async forgetSlot(id: string, why: Why): Promise<void> {
		const keyIds = this.dropSlot(id, why);
		await this.save();
		if (this.meta !== null) await this.untie(this.meta.pairing, id, keyIds);
	}

	/** The part of forgetting a slot that waits on nothing: its record and its socket gone. Gives its App Attest keys. */
	private dropSlot(id: string, why: Why): string[] {
		const keyIds = this.devices[id]?.attestKeyIds ?? [];
		delete this.devices[id];
		this.mailbox.forget(id);
		this.counters.forget(id);
		// Its push counts go in the same write as its record; only the pairing's count remembers its pushes.
		this.pushCounts.forget(id);
		if (this.meta !== null) delete this.meta.blocked[id];
		for (const [ws, attachment] of this.sockets()) {
			if (attachment.kind !== "mac" && attachment.device === id) this.refuse(ws, why);
		}
		return keyIds;
	}

	/** Unties App Attest keys, as well as it can: a call that fails leaves a tie that goes by itself (claims.ts). */
	private async untie(pairing: string, device: string, keyIds: string[]): Promise<void> {
		for (const keyId of keyIds) {
			try {
				await this.keyObject(keyId).untie(pairing, device);
			} catch {
				// The tie expires by itself.
			}
		}
	}

	/** Closes the join window, and the slots of phones that joined it and were not added. */
	private async closeWindow(): Promise<void> {
		const meta = this.meta;
		// No window, nothing to write: slots of joined phones exist only while their window does.
		if (meta === null || meta.window === null) return;
		meta.window = null;
		// Every joined slot's socket closed before anything waits, then one write, then the unties.
		const dropped = Object.entries(this.devices)
			.filter(([, device]) => !device.listed)
			.map(([id]) => [id, this.dropSlot(id, "window-ended")] as const);
		await this.save();
		for (const [id, keyIds] of dropped) await this.untie(meta.pairing, id, keyIds);
	}

	/** Deletes the pairing: every socket closed first, then all it kept, then its App Attest keys untied. */
	private async deletePairing(): Promise<void> {
		const meta = this.meta;
		const devices = this.devices;
		this.meta = null;
		this.devices = {};
		this.counters = new Counters({});
		this.pushCounts = new PushCounts(undefined);
		for (const [ws] of this.sockets()) this.refuse(ws, "deleted");
		await this.ctx.storage.deleteAlarm();
		await this.ctx.storage.deleteAll();
		if (meta !== null) {
			for (const [id, device] of Object.entries(devices)) await this.untie(meta.pairing, id, device.attestKeyIds);
		}
	}

	/**
	 * Past a limit, the end's own socket is closed with `busy` and when it may come back (6.6): nothing is dropped from
	 * the middle of its channel, which would break it; it reconnects and resumes (5.8).
	 */
	private holdOff(ws: WebSocket, until: number): void {
		const attachment = ws.deserializeAttachment() as Attachment | null;
		send(ws, { busy: { until } });
		close(ws, "busy");
		// The Mac is told which phone was held off and until when, for its Devices page (6.6), and that it is gone.
		if (attachment !== null && (attachment.kind === "device" || attachment.kind === "joined")) {
			const mac = this.mac();
			if (mac !== null) {
				send(mac, { held: { device: attachment.device, until } });
				send(mac, { offline: { device: attachment.device } });
			}
		}
	}

	// Pushes.

	/**
	 * The Mac asks for a push to one of its devices (7), on its proved socket as all its requests are: sent through
	 * Apple's service with the device's token, its content the sealed bytes the Mac gave (apns.ts). Only the Mac can ask
	 * (6.6). Counted against 6.6's push limits before it is sent, with one write for each push sent and none for one
	 * refused; a token Apple calls dead is forgotten.
	 */
	private async push(ws: WebSocket, message: Push): Promise<void> {
		const now = Date.now();
		const device = this.devices[message.device];
		if (this.meta === null || device?.listed !== true) return refused(ws, "push", "unknown-device");
		const token = device.token;
		if (token === null) return refused(ws, "push", "no-token");
		const settings = readSettings(this.env);
		const apns = settings === null ? null : this.apns(settings.bundleId);
		if (apns === null) return refused(ws, "push", "unavailable");
		const held = apns.held(token, now);
		if (held !== null) return refused(ws, "push", held);
		if (!this.pushCounts.allows(message.device, message.kind, now, this.pushLimits)) return refused(ws, "push", "push-limit");
		const first = this.pushCounts.add(message.device, message.kind, now);
		await this.ctx.storage.put("pushes", this.pushCounts.stored());
		// The hour's first push sets the alarm for the hour's end, which clears the counts.
		if (first) await this.schedule();
		const outcome = await apns.send(token, message, now);
		if (outcome === "sent") return ok(ws, "push");
		// Forgotten only if it is still the token Apple refused: the phone may have given another meanwhile.
		const still = this.devices[message.device];
		if (outcome === "token-dead" && still?.token?.apns === token.apns && still.token.environment === token.environment) {
			still.token = null;
			await this.save();
		}
		return refused(ws, "push", outcome);
	}

	private inTurn(step: () => Promise<void> | void): Promise<void> {
		const turn = this.pushing.then(step);
		this.pushing = turn.catch(() => undefined);
		return turn;
	}

	private pushStep(ws: WebSocket, message: Push): () => Promise<void> {
		this.pushesWaiting += 1;
		return () => this.push(ws, message).finally(() => (this.pushesWaiting -= 1));
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

	private windowOpen(now: number): boolean {
		const window = this.meta?.window;
		return window !== null && window !== undefined && window.expires > now && window.tries < WINDOW_TRIES;
	}

	/**
	 * Notes that an end is connected, for the 60 days: at most once a minute, so that reconnecting does not make a write
	 * each time. Says whether the record changed.
	 */
	private touch(now: number): boolean {
		const meta = this.meta!;
		if (now - meta.lastSeen < TOUCH_EVERY) return false;
		meta.lastSeen = now;
		return true;
	}

	// Storage.

	private async save(): Promise<void> {
		if (this.meta === null) return;
		// The push counts ride along when they changed (a device dropped, an hour over), in the same write.
		this.pushCounts.roll(Date.now());
		const record: Record<string, unknown> = { meta: this.meta, devices: this.devices };
		if (this.pushCounts.dirty) record.pushes = this.pushCounts.stored();
		await this.ctx.storage.put(record);
	}

	private async saveDays(): Promise<void> {
		if (this.meta === null) return;
		await this.ctx.storage.put("days", this.counters.days);
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
			times.push(...Object.values(meta.blocked));
			times.push(meta.lastSeen + IDLE_FOR);
			const expiry = this.mailbox.nextExpiry();
			if (expiry !== null) times.push(expiry);
			const pushesEnd = this.pushCounts.ends;
			if (pushesEnd !== null) times.push(pushesEnd);
			// The day's counts are kept for the day.
			if (Object.keys(this.counters.days).length > 0) times.push(Date.parse(`${new Date().toISOString().slice(0, 10)}T00:00:00Z`) + DAY);
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
	sendText(ws, JSON.stringify(message));
}

function sendText(ws: WebSocket, text: string): void {
	try {
		ws.send(text);
	} catch {
		// Closed while this was being sent: nothing to tell it.
	}
}

/** A push past MAX_WAITING_PUSHES: answered in its turn, holding nothing of it but its socket. */
function laterStep(ws: WebSocket): () => void {
	return () => refused(ws, "push", "push-later");
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
