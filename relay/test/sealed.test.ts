// The relay sees only sealed bytes (docs/iphone.md 10 and 13, decision 8; #683, P15). The live check, RemoteKit's two
// ends through the recording relay, is `scripts/relay-protocol-test --sealed` (CI's "Relay (sealed bytes)"). Here, in
// workerd with the rest of the relay's tests:
//
// - its logs stay off, and nothing it runs writes to the console: its configuration, its code, and a whole session
//   with every method of the console watched;
// - the recorder (sealed/recorder.ts) sees everything at the relay's edge, and the check (sealed/scan.ts) finds a
//   marker planted in clear, in the bytes, an item and the storage, where a session of sealed bytes leaves it nothing;
// - the check's own parts: every form it looks for, and the allow-list of what the relay may see.

import { runInDurableObject } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import appAttest from "../../engine/src/appattest.ts?raw";
import wrangler from "../wrangler.jsonc?raw";
import { base64url, concat, fromBase64url, random, utf8 } from "../src/bytes.ts";
import { sha256 } from "../src/crypto.ts";
import type { Pairing } from "../src/pairing.ts";
import { proofText } from "../src/protocol.ts";
import { Client, MAC_BUILD, newAddress, newAttestKeyId, newDeviceId, newKey, PHONE_BUILD, pairingObject, sealedItem, standInVerifier, worker } from "./helpers.ts";
import { dump, Recorder } from "./sealed/recorder.ts";
import {
	base64Middle,
	byteForms,
	check,
	type Event,
	findAll,
	forms,
	type Marker,
	messageFault,
	type Recording,
	requestFault,
	type Session,
	sha256 as hashOf,
	type Stored,
	storedFaults,
	toBase64,
	toHex,
} from "./sealed/scan.ts";

const sources = import.meta.glob<string>("../src/**/*.ts", { query: "?raw", import: "default", eager: true });

beforeEach(() => {
	vi.useFakeTimers({ toFake: ["Date"] });
	vi.setSystemTime(Date.parse("2026-11-20T12:00:00Z"));
});
afterEach(() => {
	vi.useRealTimers();
	vi.restoreAllMocks();
});

/** A JSONC text read as JSON: its comments taken out, the strings left as they are. */
function jsonc(text: string): any {
	let out = "";
	for (let index = 0; index < text.length; index++) {
		const character = text[index];
		if (character === '"') {
			const end = stringEnd(text, index);
			out += text.slice(index, end);
			index = end - 1;
		} else if (text.startsWith("//", index)) {
			index = text.indexOf("\n", index) - 1;
			if (index < 0) break;
		} else if (text.startsWith("/*", index)) {
			index = text.indexOf("*/", index) + 1;
		} else {
			out += character;
		}
	}
	return JSON.parse(out.replace(/,(\s*[}\]])/g, "$1"));
}

function stringEnd(text: string, start: number): number {
	for (let index = start + 1; index < text.length; index++) {
		if (text[index] === "\\") index++;
		else if (text[index] === '"') return index + 1;
	}
	return text.length;
}

/** TypeScript with its comments, strings and template texts taken out, so that only code is left to search. */
function codeOnly(source: string): string {
	let out = "";
	for (let index = 0; index < source.length; index++) {
		const character = source[index];
		if (source.startsWith("//", index)) {
			const end = source.indexOf("\n", index);
			index = (end < 0 ? source.length : end) - 1;
		} else if (source.startsWith("/*", index)) {
			index = source.indexOf("*/", index) + 1;
		} else if (character === '"' || character === "'" || character === "`") {
			let end = index + 1;
			while (end < source.length && source[end] !== character) end += source[end] === "\\" ? 2 : 1;
			out += `${character}${character}`;
			index = end;
		} else {
			out += character;
		}
	}
	return out;
}

describe("the relay logs nothing", () => {
	it("keeps Workers Logs, invocation logs, Logpush and tail Workers off, in every environment of its configuration", () => {
		const config = jsonc(wrangler);
		const off = (scope: any, name: string) => {
			expect(scope.observability, `${name}: observability`).toEqual({ enabled: false, logs: { enabled: false, invocation_logs: false } });
			expect(scope.logpush ?? false, `${name}: logpush`).toBe(false);
			expect(scope.tail_consumers ?? [], `${name}: tail_consumers`).toEqual([]);
			expect(scope.streaming_tail_consumers ?? [], `${name}: streaming_tail_consumers`).toEqual([]);
		};
		off(config, "the relay");
		// The deployments' environments (P9) each say it again: an environment that left it out would take Wrangler's
		// defaults, which are not all off.
		for (const [name, environment] of Object.entries(config.env ?? {})) off(environment, `the environment ${name}`);
	});

	it("has no use of the console in its code, nor in the verifier it bundles", () => {
		const files = { ...sources, "../../engine/src/appattest.ts": appAttest };
		expect(Object.keys(files).length).toBeGreaterThan(10);
		for (const [name, source] of Object.entries(files)) {
			expect(codeOnly(source), name).not.toMatch(/\bconsole\b/);
			// And nothing of the relay's own comes from its tests, where the recorder is.
			if (name.startsWith("../src/")) expect(source, name).not.toMatch(/from\s+["'][^"']*\btest\//);
		}
		// The search finds a use where there is one.
		expect(codeOnly('// console.log("a")\nconst a = 1; console.error(a);')).toMatch(/\bconsole\b/);
		expect(codeOnly('// console.log("a")\nconst a = "console.log";')).not.toMatch(/\bconsole\b/);
	});

	it("writes nothing to the console through a whole session, refusals and revoking included", async () => {
		// The console's methods are its prototype's in workerd, so they are named here: every one the console has.
		const names = [
			"log", "info", "warn", "error", "debug", "trace", "dir", "dirxml", "table", "assert", "count", "countReset", "group",
			"groupCollapsed", "groupEnd", "time", "timeEnd", "timeLog",
		] as const;
		const watched = names.filter((name) => typeof console[name] === "function").map((name) => vi.spyOn(console, name));
		expect(watched.length).toBeGreaterThan(10);
		const recorder = new Recorder();
		const session = await sealedSession(recorder);
		await plant(session);
		// Refusals, a phone leaving, and the pairing deleted.
		const stranger = await through(recorder, session.pairing);
		stranger.sendText("not JSON");
		await stranger.refused("malformed");
		session.mac.send({ removeDevice: { device: session.device } });
		expect(await answer(session.mac)).toEqual({ ok: { what: "removeDevice" } });
		session.mac.send({ deletePairing: {} });
		await session.mac.next();
		watched.forEach((spy, index) => expect(spy, `console.${names[index]}`).not.toHaveBeenCalled());
	});
});

/** The next message that is not a notice of mail, read as JSON. */
async function answer(client: Client): Promise<any> {
	for (;;) {
		const message = await client.json();
		if (!("mail" in message)) return message;
	}
}

/** A connection through the recorder to the relay's own Worker. */
async function through(recorder: Recorder, pairing?: string): Promise<Client> {
	const headers: Record<string, string> = { Upgrade: "websocket" };
	if (pairing !== undefined) headers["Pi2-Pairing"] = pairing;
	else headers["CF-Connecting-IP"] = newAddress();
	const response = await recorder.fetch(new Request("https://relay.test/v1", { headers }), (request) => worker.fetch(request.url, { method: request.method, headers: request.headers }));
	expect(response.status).toBe(101);
	return new Client(response.webSocket!);
}

type SealedSessionState = {
	recorder: Recorder;
	pairing: string;
	mac: Client;
	phone: Client;
	device: string;
	/** What the session's ends say of it, for `check`: here the Noise messages and items are random bytes. */
	session: Session;
};

/**
 * A session through the recorder, as RemoteKit's ends would make one, with random bytes for its Noise messages and
 * sealed items (the live check sends RemoteKit's own): register, the Mac's hello, a phone joining and added, bytes both
 * ways, items both ways, a state, a push token; an item left in each mailbox.
 */
async function sealedSession(recorder: Recorder): Promise<SealedSessionState> {
	const session: Session = { markers: [], secrets: [], noise: [], items: [], kept: [] };
	const macKey = await newKey();
	const registering = await through(recorder);
	registering.send({ register: { v: 1, build: MAC_BUILD, relayKey: macKey.publicKey } });
	const { challenge: first } = await registering.json();
	registering.send({ proof: { signature: await macKey.sign(proofText("register", "", "", first)) } });
	const { registered } = await registering.json();
	const pairing: string = registered.pairing;
	registering.close();

	const mac = await through(recorder, pairing);
	mac.send({ hello: { v: 1, role: "mac", pairing, build: MAC_BUILD } });
	const { challenge } = await mac.json();
	mac.send({ proof: { signature: await macKey.sign(proofText("mac", pairing, "", challenge)) } });
	expect(await mac.json()).toMatchObject({ ready: { pending: true } });

	await standInVerifier(pairing);
	const token = random(32);
	mac.send({ openJoin: { tokenHash: base64url(await sha256(token)), expires: Date.now() + 60_000 } });
	expect(await mac.json()).toEqual({ ok: { what: "openJoin" } });
	const phoneKey = await newKey();
	const phone = await through(recorder, pairing);
	phone.send({ hello: { v: 1, role: "device", pairing, build: PHONE_BUILD } });
	await phone.json();
	const keyId = newAttestKeyId();
	phone.send({ join: { pairing, deviceKey: phoneKey.publicKey, attestation: base64url(random(300)), keyId, token: base64url(token) } });
	const { joined } = await phone.json();
	await mac.json();
	const device = newDeviceId();
	mac.send({ addDevice: { device, deviceKey: phoneKey.publicKey, attestKeyId: newAttestKeyId() } });
	expect(await mac.json()).toEqual({ ok: { what: "addDevice" } });
	mac.send({ closeJoin: {} });
	expect(await mac.json()).toEqual({ ok: { what: "closeJoin" } });
	expect(joined.device).toMatch(/^dev_/);

	// The channel's bytes, both ways.
	const id = fromBase64url(device.slice(4), 16)!;
	for (const size of [96, 48, 300]) {
		const noise = random(size);
		session.noise.push(await hashOf(noise));
		phone.sendBytes(noise);
		expect([...(await mac.bytes())]).toEqual([...concat(id, noise)]);
		const back = random(size);
		session.noise.push(await hashOf(back));
		mac.sendBytes(concat(id, back));
		expect([...(await phone.bytes())]).toEqual([...back]);
	}

	// Items both ways, a state, one item left in each mailbox; and a push token.
	const item = async (keep: boolean) => {
		const bytes = sealedItem(200 + session.items.length, 0);
		bytes.set(random(199), 1);
		session.items.push(await hashOf(bytes));
		if (keep) session.kept.push(await hashOf(bytes));
		return base64url(bytes);
	};
	for (const keep of [false, true]) {
		phone.send({ put: { to: "mac", id: base64url(random(16)), item: await item(keep), presence: true } });
		expect(await answer(phone)).toEqual({ ok: { what: "put" } });
		mac.send({ put: { to: device, id: base64url(random(16)), item: await item(keep) } });
		expect(await answer(mac)).toEqual({ ok: { what: "put" } });
		mac.send({ state: { device, id: base64url(random(16)), item: await item(keep) } });
		expect(await answer(mac)).toEqual({ ok: { what: "state" } });
		if (keep) break;
		for (const end of [mac, phone]) {
			const before = await end.settle();
			expect(before.length).toBeGreaterThan(0);
		}
	}
	phone.send({ token: { apns: "ab".repeat(32), environment: "development" } });
	expect(await answer(phone)).toEqual({ ok: { what: "token" } });
	return { recorder, pairing, mac, phone, device, session };
}

const PLANTED = "a marker planted in clear 5a0c";

/** Plants the marker in clear: as the channel's bytes from the phone, and in an item the Mac leaves for it. */
async function plant(state: SealedSessionState): Promise<void> {
	state.session.markers.push({ place: "planted", text: PLANTED });
	state.phone.sendBytes(utf8(PLANTED));
	await state.mac.bytes();
	const item = concat(new Uint8Array([4]), new Uint8Array(80), utf8(PLANTED));
	state.session.kept.push(await hashOf(item));
	state.mac.send({ put: { to: state.device, id: base64url(random(16)), item: base64url(item) } });
	expect(await answer(state.mac)).toEqual({ ok: { what: "put" } });
}

async function readBack(state: SealedSessionState): Promise<Recording> {
	const stored = await runInDurableObject(pairingObject(state.pairing), (_: Pairing, ctx) => dump("pairing", state.pairing, ctx));
	return { events: [...state.recorder.events], stored: [stored], pushes: [...state.recorder.pushes] };
}

describe("the recorder and the check, in workerd", () => {
	it("sees every message both ways, finds nothing in a session of sealed bytes, and finds a marker planted in clear", async () => {
		const state = await sealedSession(new Recorder());
		const clean = await readBack(state);
		// Everything the relay was given and gave, in order, with each socket's request.
		expect(clean.events.filter((event) => event.kind === "open").length).toBe(3);
		expect(clean.events.filter((event) => event.kind === "bytes").length).toBe(12);
		expect(clean.events.some((event) => event.kind === "text" && event.from === "relay" && event.text.startsWith('{"challenge":'))).toBe(true);
		expect(Object.keys(clean.stored[0].tables).sort()).toEqual(["items", "states"]);
		expect(await check(clean, null, state.session)).toEqual([]);

		await plant(state);
		const planted = await readBack(state);
		const findings = await check(planted, null, state.session);
		const where = (rule: string) => findings.filter((finding) => finding.rule === rule).map((finding) => finding.where);
		expect(where("readable").some((place) => place.endsWith("bytes from the end"))).toBe(true);
		expect(where("readable").some((place) => place.endsWith("bytes from the relay"))).toBe(true);
		expect(where("readable").some((place) => place.endsWith("a text from the end"))).toBe(true);
		expect(where("readable").some((place) => place.includes("tables.items"))).toBe(true);
		expect(where("not-noise").length).toBe(2);
		expect(where("not-sealed").length).toBe(1);
		expect(findings.filter((finding) => !["readable", "not-noise", "not-sealed"].includes(finding.rule))).toEqual([]);
	});

	it("fails when it could not have seen the session: a Noise message or a kept item it never saw", async () => {
		const state = await sealedSession(new Recorder());
		const recording = await readBack(state);
		const missing: Session = { ...state.session, noise: [...state.session.noise, "00".repeat(32)], kept: [...state.session.kept, "11".repeat(32)] };
		expect((await check(recording, null, missing)).map((finding) => finding.rule)).toEqual(["unseen", "unseen"]);
		const empty: Recording = { events: [], stored: [], pushes: [] };
		expect((await check(empty, null, state.session)).every((finding) => finding.rule === "unseen")).toBe(true);
		expect((await check(empty, [], state.session)).length).toBeGreaterThan(0);
	});

	it("passes the relay's refusals and closings through as they were", async () => {
		const recorder = new Recorder();
		const client = await through(recorder, base64url(random(16)));
		client.send({ hello: { v: 1, role: "mac", pairing: base64url(random(16)), build: MAC_BUILD } });
		await client.refused("unknown-pairing");
		const closing = recorder.events.find((event) => event.kind === "close");
		expect(closing).toMatchObject({ from: "relay", reason: "unknown-pairing" });
		const refused = await recorder.fetch(new Request("https://relay.test/v1", { headers: { Upgrade: "websocket", Origin: "https://example.com" } }), (request) =>
			worker.fetch(request.url, { method: request.method, headers: request.headers }),
		);
		expect(refused.status).toBe(403);
		expect(recorder.events.at(-1)).toMatchObject({ kind: "open", status: 403 });
	});
});

describe("the forms a marker is looked for in", () => {
	const marker = "Marker phone — 9c4e « x »";
	const noise = () => random(2000);

	it("finds the marker in each of its forms, anywhere among other bytes", () => {
		const all = forms(marker);
		expect(all.map((form) => form.form)).toEqual(expect.arrayContaining(["UTF-8", "UTF-16LE", "UTF-16BE", "hex", "HEX", "base64 +0", "base64 +1", "base64 +2", "JSON \\u", "percent"]));
		for (const { form, bytes } of all) {
			const haystack = concat(noise(), bytes, noise());
			expect(findAll([{ place: "test", text: marker }], [], [{ where: "here", bytes: haystack }]).map((finding) => finding.detail), form).toContain(`the test marker, as ${form}`);
		}
	});

	it("finds it in base64 and base64url wherever it starts, as a whole encoding would write it", () => {
		for (let before = 0; before < 6; before++) {
			const encoded = toBase64(concat(random(before), utf8(marker), random(5)));
			for (const text of [encoded, encoded.replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "")]) {
				const found = findAll([{ place: "test", text: marker }], [], [{ where: "here", bytes: utf8(text) }]);
				expect(found.length, `${before} bytes before, ${text}`).toBeGreaterThan(0);
			}
		}
		// The middle of an encoding depends on the marker alone.
		expect(base64Middle(utf8("abcdefghijkl"), 0)).toBe(btoa("abcdefghijkl"));
		expect(btoa("x" + "abcdefghijkl")).toContain(base64Middle(utf8("abcdefghijkl"), 1));
	});

	it("finds a secret's bytes as they are, in hex and in base64", () => {
		const secret = random(32);
		for (const { form, bytes } of byteForms(secret)) {
			expect(findAll([], [secret], [{ where: "here", bytes: concat(noise(), bytes, noise()) }]).length, form).toBeGreaterThan(0);
		}
		expect(findAll([], [secret], [{ where: "here", bytes: utf8(toHex(secret).toUpperCase()) }]).length).toBeGreaterThan(0);
	});

	it("finds nothing in a megabyte of random bytes, nor in its base64", () => {
		const markers: Marker[] = [{ place: "a", text: marker }, { place: "b", text: "conversation.submit" }];
		const bytes = concat(...Array.from({ length: 16 }, () => random(1 << 16)));
		expect(findAll(markers, [random(32)], [{ where: "random", bytes }, { where: "base64", bytes: utf8(toBase64(bytes)) }])).toEqual([]);
	});

	it("refuses a marker too short to look for", () => {
		expect(() => findAll([{ place: "short", text: "eleven byte" }], [], [])).toThrow(/too short/);
	});
});

describe("the allow-list of what the relay may see", () => {
	const pairing = base64url(random(16));
	const device = newDeviceId();
	const item = base64url(sealedItem());

	it("takes the protocol's messages as they are", async () => {
		const key = (await newKey()).publicKey;
		const fromEnd = [
			{ register: { v: 1, build: "120", relayKey: key } },
			{ hello: { v: 1, role: "device", pairing, device, build: "3.1", ext: {} } },
			{ put: { to: "mac", id: base64url(random(16)), item, presence: true } },
			{ state: { device, id: base64url(random(16)), item } },
			{ token: { apns: "ab".repeat(32), environment: "production" } },
			{ ping: {} },
		];
		for (const message of fromEnd) expect(messageFault(JSON.stringify(message), "end"), JSON.stringify(message)).toBeNull();
		const fromRelay = [
			{ challenge: base64url(random(32)) },
			{ ready: { devices: [{ device, online: true }], left: [], pending: false, mail: 2 } },
			{ ready: { mac: true, mail: 0 } },
			{ refused: { what: "put", why: "mailbox-full" } },
			{ item: { from: device, id: base64url(random(16)), item, presence: false } },
			{ held: { device, until: Date.now() } },
		];
		for (const message of fromRelay) expect(messageFault(JSON.stringify(message), "relay"), JSON.stringify(message)).toBeNull();
	});

	it("refuses a field or a message it does not list, and readable text where an id, a word or a sealed item goes", () => {
		const refused: [object, "end" | "relay"][] = [
			[{ hello: { v: 1, role: "device", pairing, device, build: "3.1", name: "Marker phone" } }, "end"],
			[{ hello: { v: 1, role: "device", pairing, device, build: "3.1", ext: { name: "Marker phone" } } }, "end"],
			[{ note: { text: "hello" } }, "end"],
			[{ put: { to: "mac", id: base64url(random(16)), item: base64url(utf8("a request in clear, long enough to be an item's size at all: ".repeat(2))) } }, "end"],
			[{ removeDevice: { device: "Marker phone" } }, "end"],
			[{ refused: { why: "the phone Marker phone is gone" } }, "relay"],
			[{ ready: { mac: true, mail: 0, macName: "Marker Mac" } }, "relay"],
			[{ joined: { device, name: "Marker phone" } }, "relay"],
			[{ challenge: "Marker" }, "relay"],
		];
		for (const [message, from] of refused) expect(messageFault(JSON.stringify(message), from), JSON.stringify(message)).not.toBeNull();
	});

	it("refuses a header it does not list, and an address that carries more than /v1", () => {
		const open = (url: string, headers: [string, string][]): Extract<Event, { kind: "open" }> => ({ socket: 1, kind: "open", method: "GET", url, headers, status: 101 });
		expect(requestFault(open("https://relay.test/v1", [["upgrade", "websocket"], ["pi2-pairing", pairing]]))).toBeNull();
		expect(requestFault(open("https://relay.test/v1", [["x-device-name", "Marker phone"]]))).not.toBeNull();
		expect(requestFault(open("https://relay.test/v1", [["pi2-pairing", "Marker phone"]]))).not.toBeNull();
		expect(requestFault(open("https://relay.test/v1?device=Marker", []))).not.toBeNull();
		// What the system's WebSocket sends of its own accord, which says something of the person and the device (#678's S2).
		expect(requestFault(open("https://relay.test/v1", [["accept-language", "en-US,en;q=0.9"]]))).not.toBeNull();
		expect(requestFault(open("https://relay.test/v1", [["user-agent", "pi2 (unknown version) CFNetwork/3896.200.61 Darwin/27.2.0"]]))).toMatch(/User-Agent/);
	});

	it("refuses a key, a field or a table the relay's objects do not keep today", () => {
		const meta = { pairing, relayKey: base64url(concat(new Uint8Array([0x30]), random(90))), pendingUntil: null, lastSeen: Date.now(), blocked: {}, window: null, left: [] };
		const stored = (kv: Record<string, unknown>, tables: Stored["tables"] = {}): Stored => ({ object: "pairing", name: pairing, kv, tables, sockets: [] });
		expect(storedFaults([stored({ meta })])).toEqual([]);
		expect(storedFaults([stored({ meta: { ...meta, macName: "Marker Mac" } })])).not.toEqual([]);
		expect(storedFaults([stored({ meta, log: ["a message"] })])).not.toEqual([]);
		expect(storedFaults([stored({ meta }, { log: [{ text: "a message" }] })])).not.toEqual([]);
		expect(storedFaults([stored({ meta }, { items: [{ reader: "mac", writer: device, id: base64url(random(16)), item: utf8("in clear".repeat(20)), presence: 0, expires: Date.now() }] })])).not.toEqual([]);
	});
});
