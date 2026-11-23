// The deployment's settings (README.md, "Settings"). None has a default: a relay that is not given every one of them,
// well formed, refuses every connection, rather than guessing what a deployment meant (docs/iphone.md 9.2: nothing of
// the owner's is in the code, and another deployment is the same code with other settings).

import type { AppAttestEnvironment } from "./attest.ts";
import { type Build, readBuild } from "./protocol.ts";

export type Env = {
	PAIRINGS: DurableObjectNamespace<import("./pairing.ts").Pairing>;
	ATTEST_KEYS: DurableObjectNamespace<import("./claims.ts").AttestKey>;
	ADDRESSES: DurableObjectNamespace<import("./addresses.ts").Address>;
	APP_ATTEST_TEAM_ID?: string;
	APP_ATTEST_BUNDLE_ID?: string;
	APP_ATTEST_ENVIRONMENTS?: string;
	APP_ATTEST_CATEGORIES?: string;
	MIN_BUILD_MAC?: string;
	MIN_BUILD_DEVICE?: string;
	ADDRESS_KEY?: string;
	/** The push key (apns.ts), secrets the owner sets with `wrangler secret put`; a relay without them sends no push. */
	APNS_KEY?: string;
	APNS_KEY_ID?: string;
	APNS_TEAM_ID?: string;
};

export type Settings = {
	teamId: string;
	bundleId: string;
	/** The App Attest environments a join takes. */
	environments: AppAttestEnvironment[];
	/** Apple's validation categories a join takes, and whether it takes an attestation that carries none. */
	categories: { values: number[]; none: boolean };
	minimum: { mac: Build; device: Build };
	addressKey: string;
};

/** The settings, or null if any is missing or not well formed. */
export function readSettings(env: Env): Settings | null {
	const teamId = env.APP_ATTEST_TEAM_ID;
	const bundleId = env.APP_ATTEST_BUNDLE_ID;
	if (typeof teamId !== "string" || !/^[A-Z0-9]{10}$/.test(teamId)) return null;
	if (typeof bundleId !== "string" || bundleId.length > 155 || !/^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$/.test(bundleId)) return null;

	const environments = list(env.APP_ATTEST_ENVIRONMENTS);
	if (environments === null || !environments.every((name) => name === "production" || name === "development")) return null;

	const categoryNames = list(env.APP_ATTEST_CATEGORIES);
	if (categoryNames === null) return null;
	const categories = { values: [] as number[], none: false };
	for (const name of categoryNames) {
		if (name === "none") categories.none = true;
		// Apple's categories are 1 to 10; 0 is "invalid", and 7 to 9 are what the system makes in restricted situations.
		else if (/^(?:[1-6]|10)$/.test(name)) categories.values.push(Number(name));
		else return null;
	}

	const mac = readBuild(env.MIN_BUILD_MAC);
	const device = readBuild(env.MIN_BUILD_DEVICE);
	if (mac === null || device === null) return null;

	const addressKey = env.ADDRESS_KEY;
	if (typeof addressKey !== "string" || addressKey.length < 32) return null;

	return {
		teamId,
		bundleId,
		environments: environments as AppAttestEnvironment[],
		categories,
		minimum: { mac, device },
		addressKey,
	};
}

/** A comma-separated list with no empty, repeated or spaced item, or null. */
function list(text: string | undefined): string[] | null {
	if (typeof text !== "string" || text === "") return null;
	const items = text.split(",");
	if (items.some((item) => item === "" || item.trim() !== item) || new Set(items).size !== items.length) return null;
	return items;
}
