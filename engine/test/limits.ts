// The refresh handler's minimum interval, on the tracker's own clock. The real-engine checks in engine.ts use
// interval zero: no pair of socket round trips on a busy Mac has to fit inside a short window.
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import type { Engine } from "../src/features.ts";
import { limits } from "../src/limits.ts";

test("limits.refresh suppresses requests until the minimum interval ends", async (t) => {
	const home = mkdtempSync(join(tmpdir(), "pi2-limits-clock-"));
	t.after(() => rmSync(home, { recursive: true, force: true }));
	let now = Date.now();
	t.mock.method(Date, "now", () => now);
	let hits = 0;
	t.mock.method(globalThis, "fetch", async (url: string) => {
		assert.equal(url, "https://api.anthropic.com/api/oauth/usage");
		hits++;
		return new Response(JSON.stringify({ five_hour: { utilization: 47 }, seven_day: null }));
	});
	// Only the usage-address path is needed here: no provider stream, Keychain or real network request.
	const providers = {
		subscriptionProviders: async () => new Set(["anthropic"]),
		models: {
			getProviders: () => [{ id: "anthropic", auth: {} }],
			getProvider: () => ({ name: "Anthropic" }),
			getAuth: async () => ({ source: "OAuth", auth: { apiKey: "limits-test-not-a-real-token" } }),
		},
	};
	const feature = limits({} as Parameters<typeof limits>[0], { home, providers: () => providers, broadcast: () => {}, log: () => {} } as unknown as Engine);
	const refresh = () => feature.handlers!["limits.refresh"]!({});
	// Joins the first look started by the tracker, and waits for the reading itself, not a timer or a broadcast.
	await refresh();
	assert.equal(hits, 1, "the first look asks once");
	await refresh();
	assert.equal(hits, 1, "another refresh at the same instant sends nothing");
	now += 59_999;
	await refresh();
	assert.equal(hits, 1, "still suppressed just before the minute ends");
	now++;
	await refresh();
	assert.equal(hits, 2, "allowed at the exact boundary");
	await refresh();
	assert.equal(hits, 2, "the successful refresh starts another interval");
});
