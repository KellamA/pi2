// What the relay's tests share: a client end of a socket, keys that sign as RemoteKit's do, and the steps of the
// protocol that most tests go through before what they test.

import { env, runInDurableObject } from "cloudflare:test";
import { exports } from "cloudflare:workers";
import { expect } from "vitest";
import type { AppAttestExpected, AppAttestResult } from "../src/attest.ts";
import { base64, base64url, random, utf8 } from "../src/bytes.ts";
import { sha256 } from "../src/crypto.ts";
import type { Pairing } from "../src/pairing.ts";
import { proofText } from "../src/protocol.ts";

type Fetcher = { fetch(input: string, init?: RequestInit): Promise<Response> };
export const worker = (exports as unknown as { default: Fetcher }).default;

export type Received = string | Uint8Array | { closed: number; reason: string };

/** The client's end of a socket, which keeps what it is sent until a test reads it. */
export class Client {
	private readonly queue: Received[] = [];
	private readonly waiting: ((message: Received) => void)[] = [];
	private closedWith: { closed: number; reason: string } | null = null;

	constructor(readonly ws: WebSocket) {
		ws.accept();
		// Binary messages as bytes, not a Blob, which a newer compatibility date gives a client's socket by default.
		ws.binaryType = "arraybuffer";
		ws.addEventListener("message", (event) => {
			this.deliver(typeof event.data === "string" ? event.data : new Uint8Array(event.data as ArrayBuffer));
		});
		ws.addEventListener("close", (event) => {
			this.closedWith = { closed: event.code, reason: event.reason };
			this.deliver(this.closedWith);
		});
	}

	private deliver(message: Received): void {
		const waiter = this.waiting.shift();
		if (waiter !== undefined) waiter(message);
		else this.queue.push(message);
	}

	/** The next thing that arrives: a text, bytes, or the socket's closing. */
	next(): Promise<Received> {
		const message = this.queue.shift();
		if (message !== undefined) return Promise.resolve(message);
		if (this.closedWith !== null) return Promise.resolve(this.closedWith);
		return new Promise((resolve) => this.waiting.push(resolve));
	}

	/** The next message, which must be a text, read as JSON. */
	async json(): Promise<any> {
		const message = await this.next();
		if (typeof message !== "string") throw new Error(`expected a text message, got ${message instanceof Uint8Array ? "bytes" : JSON.stringify(message)}`);
		return JSON.parse(message);
	}

	async bytes(): Promise<Uint8Array> {
		const message = await this.next();
		if (!(message instanceof Uint8Array)) throw new Error(`expected bytes, got ${JSON.stringify(message)}`);
		return message;
	}

	send(message: object): void {
		this.ws.send(JSON.stringify(message));
	}

	sendText(text: string): void {
		this.ws.send(text);
	}

	sendBytes(bytes: Uint8Array): void {
		this.ws.send(bytes);
	}

	/** Expects the relay to refuse with `why` and close the socket. */
	async refused(why: string): Promise<void> {
		expect(await this.json()).toEqual({ refused: { why } });
		const closed = await this.next();
		expect(closed).toMatchObject({ reason: why });
	}

	/** Waits until every message the relay sent this socket before this point has arrived (a `take` and its answer). */
	async settle(): Promise<Received[]> {
		this.send({ take: {} });
		const before: Received[] = [];
		for (;;) {
			const message = await this.next();
			if (typeof message === "string" && message.startsWith('{"taken":')) return before;
			if (typeof message === "object" && "closed" in message) throw new Error("closed while settling");
			before.push(message);
		}
	}

	close(): void {
		try {
			this.ws.close(1000);
		} catch {
			// Already closed.
		}
	}
}

let addresses = 0;
/** A new address for each registration, so that tests do not run into the limit for one address unless they mean to. */
export function newAddress(): string {
	addresses += 1;
	return `198.51.${(addresses >> 8) & 255}.${addresses & 255}`;
}

/** Opens a socket to the relay: to a pairing's object if `pairing` is given, or to register one. */
export async function connect(pairing?: string, address = newAddress()): Promise<Client> {
	const headers: Record<string, string> = { Upgrade: "websocket" };
	if (pairing !== undefined) headers["Pi2-Pairing"] = pairing;
	else headers["CF-Connecting-IP"] = address;
	const response = await worker.fetch("https://relay.test/v1", { headers });
	expect(response.status).toBe(101);
	return new Client(response.webSocket!);
}

/** A P-256 key that signs as RemoteKit's keys do: SPKI DER in base64url, signatures of 64 bytes, r then s. */
export type Key = { publicKey: string; der: Uint8Array<ArrayBuffer>; sign(text: string): Promise<string> };

export async function newKey(): Promise<Key> {
	const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair;
	const der = new Uint8Array((await crypto.subtle.exportKey("spki", pair.publicKey)) as ArrayBuffer);
	return {
		publicKey: base64url(der),
		der,
		async sign(text: string) {
			return base64url(new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, pair.privateKey, utf8(text))));
		},
	};
}

export const MAC_BUILD = "120";
export const PHONE_BUILD = "3";

export type Mac = { client: Client; pairing: string; key: Key };

/** Registers a new pairing, as a Mac does, and gives the Mac's socket, ready. */
export async function register(address = newAddress()): Promise<Mac> {
	const key = await newKey();
	const client = await connect(undefined, address);
	client.send({ register: { v: 1, build: MAC_BUILD, relayKey: key.publicKey } });
	const { challenge } = await client.json();
	client.send({ proof: { signature: await key.sign(proofText("register", "", "", challenge)) } });
	const { registered } = await client.json();
	return { client, pairing: registered.pairing, key };
}

/** Connects as the pairing's Mac again, and gives what `ready` said. */
export async function macHello(mac: Mac): Promise<{ client: Client; ready: any }> {
	const client = await connect(mac.pairing);
	client.send({ hello: { v: 1, role: "mac", pairing: mac.pairing, build: MAC_BUILD } });
	const { challenge } = await client.json();
	client.send({ proof: { signature: await mac.key.sign(proofText("mac", mac.pairing, "", challenge)) } });
	const { ready } = await client.json();
	return { client, ready };
}

export type Phone = { device: string; key: Key; attestKeyId: string };

export function newAttestKeyId(): string {
	return base64(random(32));
}

/**
 * Pairs a phone as pi² Remote and the phone do over the relay: the Mac opens a window, the phone joins it (with the
 * stand-in verifier), the Mac adds it and closes the window, and the phone's socket closes, leaving it listed and away.
 * `client` is the Mac's connected socket.
 */
export async function addPhone(mac: Mac, client = mac.client): Promise<Phone> {
	await standInVerifier(mac.pairing);
	const token = await openWindow(mac, client);
	const joining = await joinHello(mac.pairing);
	sendJoin(mac.pairing, joining, token);
	const { joined } = await joining.client.json();
	const phone = { device: joined.device as string, key: joining.key, attestKeyId: joining.keyId };
	expect(await client.json()).toEqual({ joined: { device: phone.device, deviceKey: phone.key.publicKey, keyId: phone.attestKeyId } });
	client.send({ addDevice: { device: phone.device, deviceKey: phone.key.publicKey, attestKeyId: phone.attestKeyId } });
	expect(await client.json()).toEqual({ ok: { what: "addDevice" } });
	client.send({ closeJoin: {} });
	expect(await client.json()).toEqual({ ok: { what: "closeJoin" } });
	joining.client.close();
	expect(await client.json()).toEqual({ offline: { device: phone.device } });
	return phone;
}

/** Connects as a listed phone, and gives its socket, ready. */
export async function phoneHello(pairing: string, phone: Phone): Promise<{ client: Client; ready: any }> {
	const client = await connect(pairing);
	client.send({ hello: { v: 1, role: "device", pairing, device: phone.device, build: PHONE_BUILD } });
	const { challenge } = await client.json();
	client.send({ proof: { signature: await phone.key.sign(proofText("device", pairing, phone.device, challenge)) } });
	const { ready } = await client.json();
	return { client, ready };
}

export function pairingObject(pairing: string): DurableObjectStub<Pairing> {
	return env.PAIRINGS.get(env.PAIRINGS.idFromName(pairing));
}

/** A stand-in for App Attest's verifier, in the pairing's object, which records what it was asked. */
export type StandIn = { asked: AppAttestExpected[]; attestations: Uint8Array[] };

export async function standInVerifier(
	pairing: string,
	answer: (attestation: Uint8Array, expected: AppAttestExpected) => AppAttestResult = () => attested(),
): Promise<StandIn> {
	const record: StandIn = { asked: [], attestations: [] };
	await runInDurableObject(pairingObject(pairing), (instance: Pairing) => {
		instance.verify = async (attestation, expected) => {
			record.asked.push(expected);
			record.attestations.push(attestation);
			return answer(attestation, expected);
		};
	});
	return record;
}

/** What the verifier gives for a genuine attestation; `category` and `bundleVersion` as Apple says them. */
export function attested(category: number | null = 2, bundleVersion: string | null = PHONE_BUILD): AppAttestResult {
	return {
		publicKey: new Uint8Array(65),
		environment: "production",
		receipt: new Uint8Array(1),
		validationCategory: category,
		bundleVersion,
	};
}

/** Opens the pairing's join window, as the Mac does when it shows its code, and gives the token the code carries. */
export async function openWindow(mac: Mac, client = mac.client, expires = Date.now() + 5 * 60 * 1000): Promise<Uint8Array<ArrayBuffer>> {
	const token = random(32);
	client.send({ openJoin: { tokenHash: base64url(await sha256(token)), expires } });
	expect(await client.json()).toEqual({ ok: { what: "openJoin" } });
	return token;
}

export type Joining = { client: Client; key: Key; keyId: string; challenge: string };

/** A phone with no slot says hello and is challenged. */
export async function joinHello(pairing: string): Promise<Joining> {
	const client = await connect(pairing);
	client.send({ hello: { v: 1, role: "device", pairing, build: PHONE_BUILD } });
	const { challenge } = await client.json();
	return { client, key: await newKey(), keyId: newAttestKeyId(), challenge };
}

/** Sends the join; the attestation is whatever bytes the stand-in is to see. */
export function sendJoin(pairing: string, joining: Joining, token: Uint8Array, attestation = utf8("an attestation")): void {
	joining.client.send({
		join: { pairing, deviceKey: joining.key.publicKey, attestation: base64url(attestation), keyId: joining.keyId, token: base64url(token) },
	});
}

/** A sealed item's bytes, as the relay sees them: an uncompressed point's first byte, then anything. */
export function sealedItem(size = 200, fill = 7): Uint8Array<ArrayBuffer> {
	const item = new Uint8Array(size).fill(fill);
	item[0] = 0x04;
	return item;
}

export function itemId(): string {
	return base64url(random(16));
}
