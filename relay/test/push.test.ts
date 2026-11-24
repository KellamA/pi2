
// Pushes (docs/iphone.md 7, 6.6; README.md, "Pushes"; #689): a phone's push token kept and dropped, the Mac's `push`
// posted to a stand-in for Apple's service exactly as Apple takes it, with the payload's words fixed and the Mac's bytes
// only in `sealed`; the provider token's life; each of Apple's answers; the push limits; and the writes all of it makes.

import { env, runDurableObjectAlarm, runInDurableObject } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { ALERT, Apns, apnsFor, MAX_PAYLOAD, MAX_SEALED, MAX_WAITING_PUSHES, payload, PUSH_LIMITS, type PushLimits, readCredentials, SEALED_SIZES } from "../src/apns.ts";
import { base64url, fromBase64url, hex, random, utf8 } from "../src/bytes.ts";
import type { Pairing } from "../src/pairing.ts";
import { proofText } from "../src/protocol.ts";
import { type Answer, ApnsStandIn } from "./apns.ts";
import { addPhone, type Client, countStorageWrites, type Mac, pairingObject, type Phone, phoneHello, register, sealedItem } from "./helpers.ts";

const NOON = Date.parse("2026-11-20T12:00:00Z");
const MINUTE = 60 * 1000;
const HOUR = 60 * MINUTE;
/** The test deployment's phone app (vitest.config.ts), which is the topic of its pushes. */
const TOPIC = "com.example.myapp";

beforeEach(() => {
	vi.useFakeTimers({ toFake: ["Date"] });
	vi.setSystemTime(NOON);
});
afterEach(() => {
	vi.useRealTimers();
});

/** Puts a stand-in for Apple's service in the pairing's object, in place of the deployment's push key and `fetch`. */
async function standInApns(pairing: string, standIn = new ApnsStandIn()): Promise<ApnsStandIn> {
	await runInDurableObject(pairingObject(pairing), (instance: Pairing) => {
		instance.apns = standIn.client;
	});
	return standIn;
}

async function setPushLimits(pairing: string, limits: Partial<PushLimits>): Promise<void> {
	await runInDurableObject(pairingObject(pairing), (instance: Pairing) => {
		instance.pushLimits = { ...PUSH_LIMITS, ...limits };
	});
}

type Paired = { mac: Mac; phone: Phone; client: Client; token: string; standIn: ApnsStandIn };

/** A pairing with a phone listed, connected, and its push token given; and Apple's service stood in. */
async function paired(environment: "development" | "production" = "development", mac?: Mac): Promise<Paired> {
	mac ??= await register();
	const phone = await addPhone(mac);
	const { client } = await phoneHello(mac.pairing, phone);
	expect(await mac.client.json()).toEqual({ online: { device: phone.device } });
	const token = hex(random(32));
	client.send({ token: { apns: token, environment } });
	expect(await client.json()).toEqual({ ok: { what: "token" } });
	let standIn = standIns.get(mac.pairing);
	if (standIn === undefined) standIns.set(mac.pairing, (standIn = await standInApns(mac.pairing)));
	return { mac, phone, client, token, standIn };
}
/** Each pairing's one stand-in, shared by the phones paired with it. */
const standIns = new Map<string, ApnsStandIn>();

function sealed(size = 696): string {
	return base64url(sealedItem(size, 9));
}

/** The Mac asks for a push, and gives what the relay answered. */
async function push(mac: Mac, device: string, kind: "alert" | "background" = "alert", extra: object = {}): Promise<unknown> {
	mac.client.send({ push: { device, kind, sealed: sealed(), ...extra } });
	return mac.client.json();
}

const OK = { ok: { what: "push" } };
const refusal = (why: string) => ({ refused: { what: "push", why } });

async function storedToken(pairing: string, device: string): Promise<unknown> {
	return runInDurableObject(pairingObject(pairing), async (_: Pairing, state) => {
		const devices = await state.storage.get<Record<string, { token: unknown }>>("devices");
		return devices?.[device]?.token;
	});
}

describe("pushes", () => {
	it("posts an alert to Apple's sandbox exactly as the contract has it: fixed words, the Mac's bytes only in sealed", async () => {
		const { mac, phone, token, standIn } = await paired();
		const collapse = base64url(random(32));
		const bytes = sealed(1464);
		mac.client.send({ push: { device: phone.device, kind: "alert", sealed: bytes, collapse } });
		expect(await mac.client.json()).toEqual(OK);

		expect(standIn.pushes).toHaveLength(1);
		const [sent] = standIn.pushes;
		expect(sent.environment).toBe("development");
		expect(sent.token).toBe(token);
		expect(sent.headers).toEqual({
			"apns-topic": TOPIC,
			"apns-push-type": "alert",
			"apns-priority": "10",
			"apns-expiration": String(NOON / 1000 + 3600),
			"apns-collapse-id": collapse,
		});
		expect(sent.payload).toBe(`{"aps":{"alert":{"title":"pi²","body":"Something needs you"},"mutable-content":1},"sealed":"${bytes}"}`);
		expect(sent.providerToken.verified).toBe(true);
		expect(sent.providerToken.header).toEqual({ alg: "ES256", kid: standIn.keyId });
		expect(sent.providerToken.claims).toEqual({ iss: standIn.teamId, iat: NOON / 1000 });
	});

	it("posts a background push with priority 5 and content-available alone, and a production token to production", async () => {
		const { mac, phone, standIn } = await paired("production");
		const bytes = sealed(696);
		mac.client.send({ push: { device: phone.device, kind: "background", sealed: bytes } });
		expect(await mac.client.json()).toEqual(OK);
		const [sent] = standIn.pushes;
		expect(sent.environment).toBe("production");
		expect(sent.headers).toEqual({ "apns-topic": TOPIC, "apns-push-type": "background", "apns-priority": "5", "apns-expiration": String(NOON / 1000 + 3600) });
		expect(sent.payload).toBe(`{"aps":{"content-available":1},"sealed":"${bytes}"}`);
	});

	it("pads sealed items to three sizes that make payloads of at most 1, 2 and 4 KB for both kinds", () => {
		expect(MAX_SEALED).toBe(3000);
		expect(SEALED_SIZES).toEqual([696, 1464, 3000]);
		const sizes = (kind: "alert" | "background") => SEALED_SIZES.map((size) => utf8(payload(kind, base64url(sealedItem(size)))).length);
		expect(sizes("alert")).toEqual([1023, 2047, 4095]);
		expect(sizes("background")).toEqual([971, 1995, 4043]);
		// One byte more would not fit an alert's class.
		expect(SEALED_SIZES.map((size, index) => utf8(payload("alert", base64url(sealedItem(size + 1)))).length > [1024, 2048, 4096][index])).toEqual([true, true, true]);
		expect(utf8(payload("alert", base64url(sealedItem(MAX_SEALED)))).length).toBeLessThanOrEqual(MAX_PAYLOAD);
		expect(utf8(payload("background", base64url(sealedItem(MAX_SEALED)))).length).toBeLessThanOrEqual(MAX_PAYLOAD);
		expect(JSON.parse(payload("alert", "x")).aps.alert).toEqual(ALERT);
	});

	it("closes the Mac's socket for a push that is not one: too large, not a padded size, not sealed, a collapse id on a background push", async () => {
		for (const body of [
			{ kind: "alert", sealed: base64url(sealedItem(MAX_SEALED + 1)) },
			{ kind: "alert", sealed: base64url(sealedItem(1000)) },
			{ kind: "background", sealed: base64url(sealedItem(697)) },
			{ kind: "alert", sealed: base64url(new Uint8Array(696).fill(1)) },
			{ kind: "background", sealed: sealed(), collapse: base64url(random(32)) },
			{ kind: "alert", sealed: sealed(), collapse: base64url(random(16)) },
			{ kind: "activity", sealed: sealed() },
			{ kind: "alert", sealed: sealed(), title: "Words of the Mac's" },
		]) {
			const { mac, phone, standIn } = await paired();
			mac.client.send({ push: { device: phone.device, ...body } });
			await mac.client.refused("malformed");
			expect(standIn.pushes).toEqual([]);
		}
		// The largest that fits is taken.
		const { mac, phone, standIn } = await paired();
		mac.client.send({ push: { device: phone.device, kind: "alert", sealed: base64url(sealedItem(MAX_SEALED)) } });
		expect(await mac.client.json()).toEqual(OK);
		expect(utf8(standIn.pushes[0].payload).length).toBe(4095);
	});

	it("takes a push only from the Mac: a phone that asks for one is refused and closed", async () => {
		const { phone, client, standIn } = await paired();
		client.send({ push: { device: phone.device, kind: "alert", sealed: sealed() } });
		await client.refused("malformed");
		expect(standIn.pushes).toEqual([]);
	});

	it("refuses a push for a device with no token, one not listed, one removed and one that left, sending nothing", async () => {
		const mac = await register();
		const { phone, client, standIn } = await paired("development", mac);
		const quiet = await addPhone(mac);
		expect(await push(mac, quiet.device)).toEqual(refusal("no-token"));
		expect(await push(mac, `dev_${base64url(random(16))}`)).toEqual(refusal("unknown-device"));

		// The phone drops its token, and gives it again.
		client.send({ dropToken: {} });
		expect(await client.json()).toEqual({ ok: { what: "dropToken" } });
		expect(await push(mac, phone.device)).toEqual(refusal("no-token"));
		const token = hex(random(32));
		client.send({ token: { apns: token, environment: "development" } });
		expect(await client.json()).toEqual({ ok: { what: "token" } });
		expect(await push(mac, phone.device)).toEqual(OK);

		// It leaves: its token goes with its slot.
		const notice = await phone.key.sign("a stand-in for the leave notice");
		const signature = await phone.key.sign(proofText("leave", mac.pairing, phone.device, await challengeOf(mac.pairing, phone.device)));
		const at = Date.now();
		client.send({ leave: { signature, at, notice } });
		await client.refused("left");
		expect(await mac.client.json()).toEqual({ left: { device: phone.device, at, notice } });
		expect(await storedToken(mac.pairing, phone.device)).toBeUndefined();
		expect(await push(mac, phone.device)).toEqual(refusal("unknown-device"));
		expect(standIn.pushes).toHaveLength(1);

		// Another is removed by the Mac: the same.
		const other = await paired("development", mac);
		mac.client.send({ removeDevice: { device: other.phone.device } });
		await other.client.refused("removed");
		expect(await mac.client.json()).toEqual({ ok: { what: "removeDevice" } });
		expect(await storedToken(mac.pairing, other.phone.device)).toBeUndefined();
		expect(await push(mac, other.phone.device)).toEqual(refusal("unknown-device"));
	});

	it("answers every push unavailable on a relay with no push key, and reads the key from the deployment's secrets", async () => {
		const mac = await register();
		const phone = await addPhone(mac);
		const { client } = await phoneHello(mac.pairing, phone);
		expect(await mac.client.json()).toEqual({ online: { device: phone.device } });
		client.send({ token: { apns: hex(random(32)), environment: "development" } });
		expect(await client.json()).toEqual({ ok: { what: "token" } });
		// The tests' deployment has no push key: nothing is posted anywhere.
		expect(await push(mac, phone.device)).toEqual(refusal("unavailable"));

		const { pem } = await ApnsStandIn.pem();
		const secrets = { ...env, APNS_KEY: pem, APNS_KEY_ID: "ABCDE12345", APNS_TEAM_ID: "TEAM123456" };
		expect(readCredentials(secrets)).toMatchObject({ keyId: "ABCDE12345", teamId: "TEAM123456" });
		expect(apnsFor(secrets, TOPIC)).toBe(apnsFor(secrets, TOPIC));
		expect(apnsFor(secrets, TOPIC)?.topic).toBe(TOPIC);
		for (const wrong of [
			{ APNS_KEY: undefined },
			{ APNS_KEY_ID: undefined },
			{ APNS_TEAM_ID: undefined },
			{ APNS_KEY_ID: "abcde12345" },
			{ APNS_TEAM_ID: "TEAM12345" },
			{ APNS_KEY: pem.replace("PRIVATE KEY", "PUBLIC KEY") },
			{ APNS_KEY: "not a key" },
		]) {
			expect(readCredentials({ ...secrets, ...wrong })).toBeNull();
			expect(apnsFor({ ...secrets, ...wrong }, TOPIC)).toBeNull();
		}
	});

	it("signs with a .p8 key from the secrets, and says nothing of a key that does not import", async () => {
		const { pem, publicKey } = await ApnsStandIn.pem();
		const credentials = readCredentials({ ...env, APNS_KEY: pem, APNS_KEY_ID: "ABCDE12345", APNS_TEAM_ID: "TEAM123456" })!;
		const posted: RequestInit[] = [];
		const apns = new Apns(credentials, TOPIC, async (_, init) => {
			posted.push(init);
			return new Response(null, { status: 200 });
		});
		expect(await apns.send({ apns: "ab".repeat(32), environment: "production" }, { kind: "alert", sealed: sealed(), collapse: null }, NOON)).toBe("sent");
		const [head, claims, signature] = (new Headers(posted[0].headers).get("authorization") ?? "").replace("bearer ", "").split(".");
		const verified = await crypto.subtle.verify(
			{ name: "ECDSA", hash: "SHA-256" },
			publicKey,
			new Uint8Array(fromBase64url(signature, 64)!),
			utf8(`${head}.${claims}`),
		);
		expect(verified).toBe(true);

		// A PEM whose bytes are not a P-256 key: the push is unavailable, and nothing is posted or thrown.
		const broken = readCredentials({ ...env, APNS_KEY: `-----BEGIN PRIVATE KEY-----\n${btoa("x".repeat(64))}\n-----END PRIVATE KEY-----`, APNS_KEY_ID: "ABCDE12345", APNS_TEAM_ID: "TEAM123456" })!;
		expect(broken).not.toBeNull();
		let calls = 0;
		const nowhere = new Apns(broken, TOPIC, async () => {
			calls += 1;
			return new Response(null, { status: 200 });
		});
		expect(await nowhere.send({ apns: "ab".repeat(32), environment: "production" }, { kind: "alert", sealed: sealed(), collapse: null }, NOON)).toBe("unavailable");
		expect(calls).toBe(0);
	});
});

describe("Apple's answers", () => {
	for (const answer of [
		{ status: 410, reason: "Unregistered" },
		{ status: 410, reason: "ExpiredToken" },
		{ status: 400, reason: "BadDeviceToken" },
		{ status: 400, reason: "DeviceTokenNotForTopic" },
	]) {
		it(`forgets a token Apple answers ${answer.status} ${answer.reason}, and tells the Mac`, async () => {
			const { mac, phone, standIn } = await paired();
			standIn.answers.push(answer);
			expect(await push(mac, phone.device)).toEqual(refusal("token-dead"));
			expect(await storedToken(mac.pairing, phone.device)).toBeNull();
			expect(await push(mac, phone.device)).toEqual(refusal("no-token"));
			expect(standIn.pushes).toHaveLength(1);
		});
	}

	it("keeps a token the phone gave while Apple was answering that the old one is dead", async () => {
		const { mac, phone, client, standIn } = await paired();
		let release!: () => void;
		const later = new Promise<void>((resolve) => (release = resolve));
		standIn.answers.push(async () => {
			await later;
			return { status: 410, reason: "Unregistered" };
		});
		mac.client.send({ push: { device: phone.device, kind: "alert", sealed: sealed() } });
		await vi.waitFor(() => expect(standIn.pushes).toHaveLength(1));
		const fresh = hex(random(32));
		client.send({ token: { apns: fresh, environment: "development" } });
		expect(await client.json()).toEqual({ ok: { what: "token" } });
		release();
		expect(await mac.client.json()).toEqual(refusal("token-dead"));
		expect(await storedToken(mac.pairing, phone.device)).toEqual({ apns: fresh, environment: "development" });
	});

	it("backs off an environment after a 5XX or a failed connection, 30 seconds doubling, and sends nothing meanwhile", async () => {
		const { mac, phone, standIn } = await paired();
		const production = await paired("production", mac);
		const development = () => standIn.pushes.filter((sent) => sent.environment === "development");
		standIn.answers.push({ status: 503, reason: "ServiceUnavailable" });
		expect(await push(mac, phone.device)).toEqual(refusal("push-later"));
		expect(await push(mac, phone.device)).toEqual(refusal("push-later"));
		expect(development()).toHaveLength(1);
		// Production is another service, and is not held back.
		expect(await push(mac, production.phone.device)).toEqual(OK);

		vi.setSystemTime(NOON + 30 * 1000);
		standIn.unreachable = true;
		expect(await push(mac, phone.device)).toEqual(refusal("push-later"));
		standIn.unreachable = false;
		// The second back-off is twice the first.
		vi.setSystemTime(NOON + 89 * 1000);
		expect(await push(mac, phone.device)).toEqual(refusal("push-later"));
		vi.setSystemTime(NOON + 90 * 1000);
		expect(await push(mac, phone.device)).toEqual(OK);
		// A success starts the back-off afresh.
		standIn.answers.push({ status: 500, reason: "InternalServerError" });
		expect(await push(mac, phone.device)).toEqual(refusal("push-later"));
		vi.setSystemTime(NOON + 120 * 1000);
		expect(await push(mac, phone.device)).toEqual(OK);
		expect(development()).toHaveLength(4);
		expect(standIn.pushes.filter((sent) => sent.environment === "production")).toHaveLength(1);
	});

	it("holds back one device token for a minute after TooManyRequests, and no other", async () => {
		const { mac, phone, standIn } = await paired();
		const other = await paired("development", mac);
		standIn.answers.push({ status: 429, reason: "TooManyRequests" });
		expect(await push(mac, phone.device)).toEqual(refusal("push-later"));
		expect(await push(mac, phone.device)).toEqual(refusal("push-later"));
		expect(await push(mac, other.phone.device)).toEqual(OK);
		vi.setSystemTime(NOON + MINUTE);
		expect(await push(mac, phone.device)).toEqual(OK);
	});

	it("refuses pushes to an environment for an hour after Apple refuses the relay's key there", async () => {
		const { mac, phone, standIn } = await paired();
		const production = await paired("production", mac);
		standIn.answers.push({ status: 403, reason: "BadEnvironmentKeyIdInToken" });
		expect(await push(mac, phone.device)).toEqual(refusal("unavailable"));
		vi.setSystemTime(NOON + HOUR - 1);
		expect(await push(mac, phone.device)).toEqual(refusal("unavailable"));
		expect(await push(mac, production.phone.device)).toEqual(OK);
		vi.setSystemTime(NOON + HOUR);
		expect(await push(mac, phone.device)).toEqual(OK);
		expect(standIn.pushes).toHaveLength(3);
	});

	it("answers a request of the relay's own that Apple found wrong unavailable, holding nothing back", async () => {
		const { mac, phone, standIn } = await paired();
		standIn.answers.push({ status: 400, reason: "BadCollapseId" });
		expect(await push(mac, phone.device)).toEqual(refusal("unavailable"));
		expect(await push(mac, phone.device)).toEqual(OK);
	});

	it("gives up on an answer that does not come, as on a failed connection, and the pushes behind it go on", async () => {
		const { mac, phone, standIn } = await paired();
		const other = await paired("production", mac);
		standIn.timeout = 50;
		// An answer that never comes: the request is ended only by its signal, as `fetch`'s would be.
		standIn.answers.push((_, signal) => new Promise((_resolve, reject) => signal!.addEventListener("abort", () => reject(signal!.reason))));
		mac.client.send({ push: { device: phone.device, kind: "alert", sealed: sealed() } });
		mac.client.send({ push: { device: other.phone.device, kind: "alert", sealed: sealed() } });
		expect(await mac.client.json()).toEqual(refusal("push-later"));
		expect(await mac.client.json()).toEqual(OK);
		// The environment rests, as after a 5XX.
		expect(await push(mac, phone.device)).toEqual(refusal("push-later"));
		expect(standIn.pushes).toHaveLength(2);
	});

	it(`keeps at most ${MAX_WAITING_PUSHES} pushes waiting, answering one more push-later in its turn without sending it`, async () => {
		const { mac, phone, standIn } = await paired();
		let release!: () => void;
		const later = new Promise<void>((resolve) => (release = resolve));
		standIn.answers.push(async () => {
			await later;
			return { status: 200 };
		});
		for (let index = 0; index < MAX_WAITING_PUSHES + 3; index++) mac.client.send({ push: { device: phone.device, kind: "alert", sealed: sealed() } });
		// Every push has been taken in, and none answered.
		expect(await mac.client.settle()).toEqual([]);
		release();
		for (let index = 0; index < MAX_WAITING_PUSHES; index++) expect(await mac.client.json()).toEqual(OK);
		for (let index = 0; index < 3; index++) expect(await mac.client.json()).toEqual(refusal("push-later"));
		expect(standIn.pushes).toHaveLength(MAX_WAITING_PUSHES);
		// Once they are done, pushes wait again.
		expect(await push(mac, phone.device)).toEqual(OK);
	});

	it("answers the Mac's pushes in the order it asked, one at a time", async () => {
		const { mac, phone, token, standIn } = await paired();
		const other = await paired("development", mac);
		let release!: () => void;
		const later = new Promise<void>((resolve) => (release = resolve));
		standIn.answers.push(async () => {
			await later;
			return { status: 410, reason: "Unregistered" };
		});
		mac.client.send({ push: { device: phone.device, kind: "alert", sealed: sealed() } });
		mac.client.send({ push: { device: other.phone.device, kind: "alert", sealed: sealed() } });
		await vi.waitFor(() => expect(standIn.pushes).toHaveLength(1));
		release();
		expect(await mac.client.json()).toEqual(refusal("token-dead"));
		expect(await mac.client.json()).toEqual(OK);
		expect(standIn.pushes.map((sent) => sent.token)).toEqual([token, other.token]);
	});
});

describe("the provider token", () => {
	it("is reused for 50 minutes, then made again with a new iat", async () => {
		const { mac, phone, standIn } = await paired();
		expect(await push(mac, phone.device)).toEqual(OK);
		vi.setSystemTime(NOON + 50 * MINUTE - 1000);
		expect(await push(mac, phone.device)).toEqual(OK);
		vi.setSystemTime(NOON + 50 * MINUTE);
		expect(await push(mac, phone.device)).toEqual(OK);
		const [first, second, third] = standIn.pushes.map((sent) => sent.providerToken);
		expect(second.text).toBe(first.text);
		expect(third.text).not.toBe(first.text);
		expect(third.claims).toEqual({ iss: standIn.teamId, iat: (NOON + 50 * MINUTE) / 1000 });
	});

	it("is not made again within 20 minutes when Apple calls it stale, and is after", async () => {
		const { mac, phone, standIn } = await paired();
		standIn.answers.push({ status: 200 }, { status: 403, reason: "ExpiredProviderToken" });
		expect(await push(mac, phone.device)).toEqual(OK);
		vi.setSystemTime(NOON + 19 * MINUTE);
		expect(await push(mac, phone.device)).toEqual(refusal("push-later"));
		expect(await push(mac, phone.device)).toEqual(OK);
		standIn.answers.push({ status: 403, reason: "ExpiredProviderToken" });
		vi.setSystemTime(NOON + 20 * MINUTE);
		expect(await push(mac, phone.device)).toEqual(refusal("push-later"));
		expect(await push(mac, phone.device)).toEqual(OK);
		const tokens = standIn.pushes.map((sent) => sent.providerToken.text);
		expect(new Set(tokens.slice(0, 4)).size).toBe(1);
		expect(tokens[4]).not.toBe(tokens[0]);
	});

	it("is kept after TooManyProviderTokenUpdates, and the environment rests a minute", async () => {
		const { mac, phone, standIn } = await paired();
		standIn.answers.push({ status: 429, reason: "TooManyProviderTokenUpdates" });
		expect(await push(mac, phone.device)).toEqual(refusal("push-later"));
		vi.setSystemTime(NOON + MINUTE - 1);
		expect(await push(mac, phone.device)).toEqual(refusal("push-later"));
		vi.setSystemTime(NOON + MINUTE);
		expect(await push(mac, phone.device)).toEqual(OK);
		expect(standIn.pushes).toHaveLength(2);
		expect(standIn.pushes[1].providerToken.text).toBe(standIn.pushes[0].providerToken.text);
	});
});

describe("push limits", () => {
	it("counts each device's alerts and background pushes an hour apart, refusing past the limit without sending", async () => {
		expect(PUSH_LIMITS).toEqual({ alert: 120, background: 60, activity: 60 });
		const { mac, phone, standIn } = await paired();
		const other = await paired("development", mac);
		await setPushLimits(mac.pairing, { alert: 3, background: 2 });
		for (let index = 0; index < 3; index++) expect(await push(mac, phone.device)).toEqual(OK);
		expect(await push(mac, phone.device)).toEqual(refusal("push-limit"));
		for (let index = 0; index < 2; index++) expect(await push(mac, phone.device, "background")).toEqual(OK);
		expect(await push(mac, phone.device, "background")).toEqual(refusal("push-limit"));
		// Another device has its own.
		expect(await push(mac, other.phone.device)).toEqual(OK);
		expect(standIn.pushes).toHaveLength(6);
		// A refused push is not counted as a sent one, and the next hour starts afresh.
		vi.setSystemTime(Math.ceil(NOON / HOUR) * HOUR + HOUR);
		expect(await push(mac, phone.device)).toEqual(OK);
	});

	it("counts the pairing's pushes too, so that a device removed and another added does not start afresh", async () => {
		const mac = await register();
		await setPushLimits(mac.pairing, { alert: 1 });
		const phones: Paired[] = [];
		for (let index = 0; index < 5; index++) {
			phones.push(await paired("development", mac));
			expect(await push(mac, phones[index].phone.device)).toEqual(OK);
		}
		mac.client.send({ removeDevice: { device: phones[0].phone.device } });
		await phones[0].client.refused("removed");
		expect(await mac.client.json()).toEqual({ ok: { what: "removeDevice" } });
		const sixth = await paired("development", mac);
		expect(await push(mac, sixth.phone.device)).toEqual(refusal("push-limit"));
		await setPushLimits(mac.pairing, { alert: 2 });
		expect(await push(mac, sixth.phone.device)).toEqual(OK);
	});

	it("drops a removed device's counts in the same write that removes it, keeping the pairing's", async () => {
		const { mac, phone, client } = await paired();
		expect(await push(mac, phone.device)).toEqual(OK);
		const writes = await countStorageWrites(mac.pairing);
		mac.client.send({ removeDevice: { device: phone.device } });
		await client.refused("removed");
		expect(await mac.client.json()).toEqual({ ok: { what: "removeDevice" } });
		expect(writes.what.filter((what) => what === "put")).toHaveLength(1);
		expect((await storedCounts(mac.pairing))!.counts).toEqual({ pairing: { alert: 1, background: 0 } });
	});

	it("clears the counts at the pairing's alarm once their hour is over", async () => {
		const { mac, phone } = await paired();
		expect(await push(mac, phone.device)).toEqual(OK);
		const end = Math.ceil(NOON / HOUR + 0.5) * HOUR;
		// Before the hour is over, the alarm keeps them.
		vi.setSystemTime(end - 1);
		await runDurableObjectAlarm(pairingObject(mac.pairing));
		expect((await storedCounts(mac.pairing))!.counts[phone.device]).toEqual({ alert: 1, background: 0 });
		vi.setSystemTime(end);
		await runDurableObjectAlarm(pairingObject(mac.pairing));
		expect((await storedCounts(mac.pairing))!.counts).toEqual({});
		// And the alarm after it is not set for the counts.
		vi.setSystemTime(end + 1000);
		expect(await push(mac, phone.device)).toEqual(OK);
		expect((await storedCounts(mac.pairing))!.counts[phone.device]).toEqual({ alert: 1, background: 0 });
	});

	it("survives the object being evicted: the counts are stored", async () => {
		const { mac, phone } = await paired();
		await setPushLimits(mac.pairing, { alert: 2 });
		expect(await push(mac, phone.device)).toEqual(OK);
		expect(await push(mac, phone.device)).toEqual(OK);
		const counts = await runInDurableObject(pairingObject(mac.pairing), (_: Pairing, state) => state.storage.get<{ counts: Record<string, unknown> }>("pushes"));
		expect(counts!.counts[phone.device]).toEqual({ alert: 2, background: 0 });
		expect(counts!.counts.pairing).toEqual({ alert: 2, background: 0 });
	});
});

describe("writes", () => {
	it("writes a token only when it changes, a drop only when there was one, and one write for each push sent", async () => {
		const { mac, phone, client, token } = await paired();
		await setPushLimits(mac.pairing, { alert: 2 });
		const writes = await countStorageWrites(mac.pairing);

		// The phone gives the same token at every connection: nothing written.
		for (let index = 0; index < 5; index++) {
			client.send({ token: { apns: token, environment: "development" } });
			expect(await client.json()).toEqual({ ok: { what: "token" } });
		}
		expect(writes.count).toBe(0);
		client.send({ token: { apns: token, environment: "production" } });
		expect(await client.json()).toEqual({ ok: { what: "token" } });
		expect(writes.count).toBe(1);

		// Two pushes sent, one write each, and the alarm set for the end of the hour at its first; refused ones, none.
		expect(await push(mac, phone.device)).toEqual(OK);
		expect(await push(mac, phone.device)).toEqual(OK);
		expect(writes.what).toEqual(["put", "put", "setAlarm", "put"]);
		for (let index = 0; index < 10; index++) expect(await push(mac, phone.device)).toEqual(refusal("push-limit"));
		expect(writes.count).toBe(4);

		for (let index = 0; index < 3; index++) {
			client.send({ dropToken: {} });
			expect(await client.json()).toEqual({ ok: { what: "dropToken" } });
		}
		expect(writes.count).toBe(5);
		for (let index = 0; index < 10; index++) expect(await push(mac, phone.device)).toEqual(refusal("no-token"));
		expect(writes.count).toBe(5);
	});

	it("makes two writes for a push whose token Apple calls dead, the count and the token forgotten, and sets the hour's alarm", async () => {
		const { mac, phone, standIn } = await paired();
		standIn.answers.push({ status: 410, reason: "Unregistered" } satisfies Answer);
		const writes = await countStorageWrites(mac.pairing);
		expect(await push(mac, phone.device)).toEqual(refusal("token-dead"));
		expect(writes.what).toEqual(["put", "setAlarm", "put"]);
	});
});

async function storedCounts(pairing: string): Promise<{ hour: number; counts: Record<string, unknown> } | undefined> {
	return runInDurableObject(pairingObject(pairing), (_: Pairing, state) => state.storage.get("pushes"));
}

/** The challenge a listed phone's ready socket was given, which its `leave` signs. */
async function challengeOf(pairing: string, device: string): Promise<string> {
	return runInDurableObject(pairingObject(pairing), (_: Pairing, state) => {
		for (const ws of state.getWebSockets()) {
			const attachment = ws.deserializeAttachment() as { kind: string; device?: string; challenge?: string } | null;
			if (attachment?.kind === "device" && attachment.device === device) return attachment.challenge!;
		}
		throw new Error("no socket for the device");
	});
}
