
// Live Activity pushes (docs/iphone.md 7; README.md, "Pushes"; #700): a phone's activity tokens kept, bounded and
// dropped; the Mac's activity push posted to the stand-in for Apple's service exactly as Apple takes it, numbers only,
// held to their shape; Apple's answers; the push limits; and the writes.

import { runInDurableObject } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
	ACTIVITY_TOKEN_FOR,
	ActivityStamps,
	activityPayload,
	AT_AHEAD,
	AT_BEHIND,
	MAX_ACTIVITIES,
	MAX_COUNT,
	PUSH_LIMITS,
	type PushLimits,
} from "../src/apns.ts";
import { base64url, hex, random } from "../src/bytes.ts";
import type { Pairing } from "../src/pairing.ts";
import { ApnsStandIn } from "./apns.ts";
import { addPhone, type Client, countStorageWrites, type Mac, pairingObject, type Phone, phoneHello, register, sealedItem } from "./helpers.ts";

/** The time of the payloads the phone's tests read (iphone/Tests/LiveActivityTests.swift, `relayUpdate`, `relayEnd`). */
const NOW = 1_764_150_000 * 1000;
const AT = 1_764_149_990_000;
const MINUTE = 60 * 1000;
const HOUR = 60 * MINUTE;
const TOPIC = "com.example.myapp";

beforeEach(() => {
	vi.useFakeTimers({ toFake: ["Date"] });
	vi.setSystemTime(NOW);
});
afterEach(() => {
	vi.useRealTimers();
});

type Paired = { mac: Mac; phone: Phone; client: Client; standIn: ApnsStandIn; activity: string; token: string };

/** A pairing with a phone listed and connected, one Live Activity's token given, and Apple's service stood in. */
async function paired(environment: "development" | "production" = "development", mac?: Mac): Promise<Paired> {
	mac ??= await register();
	const phone = await addPhone(mac);
	const { client } = await phoneHello(mac.pairing, phone);
	expect(await mac.client.json()).toEqual({ online: { device: phone.device } });
	const activity = base64url(random(16));
	const token = hex(random(80));
	client.send({ activityToken: { activity, apns: token, environment } });
	expect(await client.json()).toEqual({ ok: { what: "activityToken" } });
	let standIn = standIns.get(mac.pairing);
	if (standIn === undefined) {
		standIn = new ApnsStandIn();
		standIns.set(mac.pairing, standIn);
		const client = standIn.client;
		await runInDurableObject(pairingObject(mac.pairing), (instance: Pairing) => {
			instance.apns = client;
		});
	}
	return { mac, phone, client, standIn, activity, token };
}
const standIns = new Map<string, ApnsStandIn>();

async function setPushLimits(pairing: string, limits: Partial<PushLimits>): Promise<void> {
	await runInDurableObject(pairingObject(pairing), (instance: Pairing) => {
		instance.pushLimits = { ...PUSH_LIMITS, ...limits };
	});
}

const STATE = { working: 3, needs: 1, finished: 2, at: AT };

/** The Mac asks for a Live Activity push, and gives what the relay answered. */
async function activityPush(mac: Mac, device: string, activity: string, event: "update" | "end" = "update", state: object = STATE): Promise<unknown> {
	mac.client.send({ push: { device, kind: "activity", activity, event, state } });
	return mac.client.json();
}

const OK = { ok: { what: "push" } };
const refusal = (why: string) => ({ refused: { what: "push", why } });

async function storedActivities(pairing: string, device: string): Promise<unknown> {
	return runInDurableObject(pairingObject(pairing), async (_: Pairing, state) => {
		const devices = await state.storage.get<Record<string, { activities?: unknown }>>("devices");
		return devices?.[device]?.activities;
	});
}

describe("Live Activity pushes", () => {
	it("posts an update to the activity's own token, exactly as Apple takes it: the live activity's topic and type, numbers only", async () => {
		const { mac, phone, standIn, activity, token } = await paired();
		expect(await activityPush(mac, phone.device, activity)).toEqual(OK);
		expect(standIn.pushes).toHaveLength(1);
		const [sent] = standIn.pushes;
		expect(sent.environment).toBe("development");
		expect(sent.token).toBe(token);
		expect(sent.headers).toEqual({
			"apns-topic": `${TOPIC}.push-type.liveactivity`,
			"apns-push-type": "liveactivity",
			"apns-priority": "5",
			"apns-expiration": String(NOW / 1000 + 3600),
		});
		// Exactly what the phone's test reads (LiveActivityTests.relayUpdate): if one changes, both must.
		expect(sent.payload).toBe('{"aps":{"timestamp":1764150000,"event":"update","content-state":{"working":3,"needs":1,"finished":2,"at":1764149990000}}}');
		expect(sent.providerToken.verified).toBe(true);
	});

	it("posts an end that leaves the last numbers on the Lock Screen for 15 minutes, and a production token to production", async () => {
		const { mac, phone, standIn, activity } = await paired("production");
		expect(await activityPush(mac, phone.device, activity, "end", { working: 0, needs: 0, finished: 5, at: AT })).toEqual(OK);
		const [sent] = standIn.pushes;
		expect(sent.environment).toBe("production");
		// LiveActivityTests.relayEnd.
		expect(sent.payload).toBe(
			'{"aps":{"timestamp":1764150000,"event":"end","content-state":{"working":0,"needs":0,"finished":5,"at":1764149990000},"dismissal-date":1764150900}}',
		);
	});

	it("writes the payload from the four numbers alone, and refuses to write anything else", () => {
		expect(activityPayload({ event: "update", state: { working: MAX_COUNT, needs: 0, finished: 0, at: 1 } }, NOW)).toBe(
			`{"aps":{"timestamp":1764150000,"event":"update","content-state":{"working":${MAX_COUNT},"needs":0,"finished":0,"at":1}}}`,
		);
		// Something that is not one of the numbers never reaches a payload, even if it got past the reading.
		const sneaky = { working: 1, needs: 1, finished: 1, at: AT, title: "words" } as unknown as typeof STATE;
		expect(JSON.parse(activityPayload({ event: "update", state: sneaky }, NOW)).aps["content-state"]).toEqual({ working: 1, needs: 1, finished: 1, at: AT });
		for (const bad of [{ working: -1 }, { needs: 1.5 }, { finished: MAX_COUNT + 1 }, { working: "3" }, { at: 0 }, { at: 1e16 }]) {
			expect(() => activityPayload({ event: "update", state: { ...STATE, ...bad } as typeof STATE }, NOW)).toThrow();
		}
	});

	it("closes the Mac's socket for an activity push that is not one: more than numbers, numbers out of shape, no activity", async () => {
		for (const body of [
			{ activity: "x", event: "update", state: STATE },
			// No activity at all (undefined is left out of the JSON).
			{ activity: undefined, event: "update", state: STATE },
			{ event: "start", state: STATE },
			{ event: "update", state: { ...STATE, title: "pi2" } },
			{ event: "update", state: { working: 3, needs: 1, finished: 2 } },
			{ event: "update", state: { ...STATE, working: -1 } },
			{ event: "update", state: { ...STATE, needs: 2.5 } },
			{ event: "update", state: { ...STATE, finished: MAX_COUNT + 1 } },
			{ event: "update", state: { ...STATE, working: "3" } },
			{ event: "update", state: { ...STATE, at: 0 } },
			{ event: "update", state: { ...STATE, at: 1e16 } },
			{ event: "update", state: STATE, sealed: base64url(sealedItem(696)) },
			{ event: "update", state: STATE, alert: "Forge needs approval" },
			{ event: "update", state: STATE, collapse: base64url(random(32)) },
			{ event: "update", state: [3, 1, 2, AT] },
		]) {
			const { mac, phone, standIn, activity } = await paired();
			mac.client.send({ push: { device: phone.device, kind: "activity", activity, ...body } });
			await mac.client.refused("malformed");
			expect(standIn.pushes).toEqual([]);
		}
	});

	it("takes an activity's token only from the phone, and an activity push only from the Mac", async () => {
		const { mac, phone, client, standIn, activity } = await paired();
		client.send({ push: { device: phone.device, kind: "activity", activity, event: "update", state: STATE } });
		await client.refused("malformed");
		mac.client.send({ activityToken: { activity, apns: hex(random(80)), environment: "development" } });
		await mac.client.refused("malformed");
		expect(standIn.pushes).toEqual([]);
	});

	it("refuses a push to an activity the phone gave no token for, dropped, or whose time is over; and to a device not listed", async () => {
		const mac = await register();
		const { phone, client, standIn, activity } = await paired("development", mac);
		expect(await activityPush(mac, phone.device, base64url(random(16)))).toEqual(refusal("no-token"));
		expect(await activityPush(mac, `dev_${base64url(random(16))}`, activity)).toEqual(refusal("unknown-device"));

		client.send({ dropActivity: { activity } });
		expect(await client.json()).toEqual({ ok: { what: "dropActivity" } });
		expect(await storedActivities(mac.pairing, phone.device)).toEqual({});
		expect(await activityPush(mac, phone.device, activity)).toEqual(refusal("no-token"));

		// Given again, then kept twelve hours.
		const token = hex(random(80));
		client.send({ activityToken: { activity, apns: token, environment: "development" } });
		expect(await client.json()).toEqual({ ok: { what: "activityToken" } });
		vi.setSystemTime(NOW + ACTIVITY_TOKEN_FOR - 1);
		expect(await activityPush(mac, phone.device, activity)).toEqual(OK);
		vi.setSystemTime(NOW + ACTIVITY_TOKEN_FOR);
		expect(await activityPush(mac, phone.device, activity)).toEqual(refusal("no-token"));
		expect(await storedActivities(mac.pairing, phone.device)).toEqual({});
		expect(standIn.pushes).toHaveLength(1);
	});

	it("keeps five activities' tokens a device at most, the oldest going first; and goes with the device", async () => {
		const { mac, phone, client, activity } = await paired();
		const later: string[] = [];
		for (let index = 0; index < MAX_ACTIVITIES; index++) {
			vi.setSystemTime(NOW + (index + 1) * MINUTE);
			const id = base64url(random(16));
			later.push(id);
			client.send({ activityToken: { activity: id, apns: hex(random(80)), environment: "development" } });
			expect(await client.json()).toEqual({ ok: { what: "activityToken" } });
		}
		const kept = (await storedActivities(mac.pairing, phone.device)) as Record<string, { until: number }>;
		expect(Object.keys(kept).sort()).toEqual([...later].sort());
		expect(await activityPush(mac, phone.device, activity)).toEqual(refusal("no-token"));
		expect(await activityPush(mac, phone.device, later[0])).toEqual(OK);

		mac.client.send({ removeDevice: { device: phone.device } });
		await client.refused("removed");
		expect(await mac.client.json()).toEqual({ ok: { what: "removeDevice" } });
		expect(await storedActivities(mac.pairing, phone.device)).toBeUndefined();
		expect(await activityPush(mac, phone.device, later[0])).toEqual(refusal("unknown-device"));
	});

	it("checks a token's shape: hexadecimal, 32 to 100 bytes, and the activity's id 16 bytes", async () => {
		for (const body of [
			{ activity: base64url(random(16)), apns: "AB".repeat(80), environment: "development" },
			{ activity: base64url(random(16)), apns: "ab".repeat(101), environment: "development" },
			{ activity: base64url(random(16)), apns: "ab".repeat(80), environment: "sandbox" },
			{ activity: base64url(random(8)), apns: "ab".repeat(80), environment: "development" },
			{ activity: base64url(random(16)), apns: "ab".repeat(80), environment: "development", project: "pi2" },
		]) {
			const { client } = await paired();
			client.send({ activityToken: body });
			await client.refused("malformed");
		}
	});
});

describe("Apple's answers to a Live Activity push", () => {
	it("forgets an activity's token Apple answers 410 (the activity is over), and tells the Mac", async () => {
		const { mac, phone, standIn, activity } = await paired();
		standIn.answers.push({ status: 410, reason: "Unregistered" });
		expect(await activityPush(mac, phone.device, activity)).toEqual(refusal("token-dead"));
		expect(await storedActivities(mac.pairing, phone.device)).toEqual({});
		expect(await activityPush(mac, phone.device, activity)).toEqual(refusal("no-token"));
		expect(standIn.pushes).toHaveLength(1);
	});

	it("holds back Live Activity pushes alone for an hour when Apple refuses their topic, never the alerts", async () => {
		const { mac, phone, client, standIn, activity } = await paired();
		client.send({ token: { apns: hex(random(32)), environment: "development" } });
		expect(await client.json()).toEqual({ ok: { what: "token" } });
		standIn.answers.push({ status: 400, reason: "TopicDisallowed" });
		expect(await activityPush(mac, phone.device, activity)).toEqual(refusal("unavailable"));
		expect(await activityPush(mac, phone.device, activity)).toEqual(refusal("unavailable"));
		expect(standIn.pushes).toHaveLength(1);
		// The alerts' topic is another, and still goes.
		mac.client.send({ push: { device: phone.device, kind: "alert", sealed: base64url(sealedItem(696, 9)) } });
		expect(await mac.client.json()).toEqual(OK);
		vi.setSystemTime(NOW + HOUR);
		expect(await activityPush(mac, phone.device, activity)).toEqual(OK);
	});

	it("is held back with the environment after a 5XX, as every push is", async () => {
		const { mac, phone, standIn, activity } = await paired();
		standIn.answers.push({ status: 503, reason: "ServiceUnavailable" });
		expect(await activityPush(mac, phone.device, activity)).toEqual(refusal("push-later"));
		expect(await activityPush(mac, phone.device, activity)).toEqual(refusal("push-later"));
		vi.setSystemTime(NOW + 30 * 1000);
		expect(await activityPush(mac, phone.device, activity)).toEqual(OK);
	});
});

describe("what a Live Activity push may carry, and when", () => {
	it("writes no event but update or end, whatever got past the reading", () => {
		for (const event of ["start", "", "update ", "END"]) {
			expect(() => activityPayload({ event: event as "update", state: STATE }, NOW)).toThrow();
		}
		expect(() => activityPayload({ event: "update", state: STATE }, NOW, 0)).toThrow();
		expect(() => activityPayload({ event: "update", state: STATE }, NOW, 1.5)).toThrow();
	});

	it("takes `at` from a day behind the relay's clock to five minutes ahead, and answers clock past either, sending, counting and writing nothing", async () => {
		expect(AT_BEHIND).toBe(24 * HOUR);
		expect(AT_AHEAD).toBe(5 * MINUTE);
		const { mac, phone, standIn, activity } = await paired();
		const writes = await countStorageWrites(mac.pairing);
		for (const at of [NOW - AT_BEHIND - 1, NOW + AT_AHEAD + 1, 1]) {
			expect(await activityPush(mac, phone.device, activity, "update", { ...STATE, at })).toEqual(refusal("clock"));
		}
		expect(writes.count).toBe(0);
		expect(standIn.pushes).toEqual([]);
		// The socket stays open, and each edge itself is taken.
		for (const at of [NOW - AT_BEHIND, NOW + AT_AHEAD]) {
			expect(await activityPush(mac, phone.device, activity, "update", { ...STATE, at })).toEqual(OK);
		}
		expect(standIn.pushes.map((sent) => JSON.parse(sent.payload).aps["content-state"].at)).toEqual([NOW - AT_BEHIND, NOW + AT_AHEAD]);
	});

	it("never gives one activity the same timestamp twice: an end in the same second as an update comes after it", async () => {
		const { mac, phone, client, standIn, activity } = await paired();
		const other = base64url(random(16));
		client.send({ activityToken: { activity: other, apns: hex(random(80)), environment: "development" } });
		expect(await client.json()).toEqual({ ok: { what: "activityToken" } });
		const second = NOW / 1000;
		const stamps = () => standIn.pushes.map((sent) => JSON.parse(sent.payload).aps.timestamp);
		expect(await activityPush(mac, phone.device, activity, "update")).toEqual(OK);
		expect(await activityPush(mac, phone.device, activity, "end", { working: 0, needs: 0, finished: 2, at: AT })).toEqual(OK);
		// Another activity has its own.
		expect(await activityPush(mac, phone.device, other, "update")).toEqual(OK);
		expect(stamps()).toEqual([second, second + 1, second]);
		const end = JSON.parse(standIn.pushes[1].payload).aps;
		expect(end["dismissal-date"]).toBe(second + 1 + 15 * 60);
		// A second later the clock has not caught up with the end's: one past it; once it has, the clock's own.
		vi.setSystemTime(NOW + 1000);
		expect(await activityPush(mac, phone.device, activity, "update")).toEqual(OK);
		vi.setSystemTime(NOW + 10_000);
		expect(await activityPush(mac, phone.device, activity, "update")).toEqual(OK);
		expect(stamps().slice(3)).toEqual([second + 2, second + 10]);
	});

	it("keeps its timestamps for a few dozen activities, and lets go of old ones", () => {
		const stamps = new ActivityStamps();
		for (let index = 0; index < 100; index++) expect(stamps.next(`a${index}`, NOW)).toBe(NOW / 1000);
		expect(stamps.next("a99", NOW)).toBe(NOW / 1000 + 1);
		// Two minutes on, the old ones go when it next grows, and none is given a timestamp behind the clock.
		expect(stamps.next("a0", NOW + 2 * MINUTE)).toBe(NOW / 1000 + 120);
		expect((stamps as unknown as { last: Map<string, number> }).last.size).toBe(1);
	});
});

describe("Live Activity limits and writes", () => {
	it("counts Live Activity pushes against their own limit, 60 a device an hour, apart from alerts", async () => {
		expect(PUSH_LIMITS.activity).toBe(60);
		const { mac, phone, client, standIn, activity } = await paired();
		client.send({ token: { apns: hex(random(32)), environment: "development" } });
		expect(await client.json()).toEqual({ ok: { what: "token" } });
		await setPushLimits(mac.pairing, { activity: 2, alert: 1 });
		expect(await activityPush(mac, phone.device, activity)).toEqual(OK);
		expect(await activityPush(mac, phone.device, activity)).toEqual(OK);
		expect(await activityPush(mac, phone.device, activity)).toEqual(refusal("push-limit"));
		mac.client.send({ push: { device: phone.device, kind: "alert", sealed: base64url(sealedItem(696, 9)) } });
		expect(await mac.client.json()).toEqual(OK);
		expect(standIn.pushes).toHaveLength(3);
		const counts = await runInDurableObject(pairingObject(mac.pairing), (_: Pairing, state) => state.storage.get<{ counts: Record<string, unknown> }>("pushes"));
		expect(counts!.counts[phone.device]).toEqual({ alert: 1, background: 0, activity: 2 });
		vi.setSystemTime(Math.ceil(NOW / HOUR) * HOUR + HOUR);
		expect(await activityPush(mac, phone.device, activity)).toEqual(OK);
	});

	it("writes an activity's token only when it changes, and one write for each push sent", async () => {
		const { mac, phone, client, activity, token } = await paired();
		const writes = await countStorageWrites(mac.pairing);
		for (let index = 0; index < 5; index++) {
			client.send({ activityToken: { activity, apns: token, environment: "development" } });
			expect(await client.json()).toEqual({ ok: { what: "activityToken" } });
		}
		expect(writes.count).toBe(0);
		expect(await activityPush(mac, phone.device, activity)).toEqual(OK);
		expect(await activityPush(mac, phone.device, activity)).toEqual(OK);
		expect(writes.what).toEqual(["put", "setAlarm", "put"]);
		for (let index = 0; index < 3; index++) {
			client.send({ dropActivity: { activity } });
			expect(await client.json()).toEqual({ ok: { what: "dropActivity" } });
		}
		expect(writes.count).toBe(4);
		for (let index = 0; index < 5; index++) expect(await activityPush(mac, phone.device, activity)).toEqual(refusal("no-token"));
		expect(writes.count).toBe(4);
	});
});
