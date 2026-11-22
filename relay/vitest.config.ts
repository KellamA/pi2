// The relay's tests run inside the Workers runtime (workerd), through Cloudflare's Vitest integration: the same runtime
// the relay runs in, with its Durable Objects and their storage, all on this computer. Never in Node's `vm` contexts,
// where App Attest's verifier refuses every byte array as another context's (#672's second security read).
//
// The settings are a test deployment's, none of them pi²'s: Apple's sample attestation's team and bundle ids
// (engine/test/appattest.json), so that the sample runs through `join`.

import { cloudflareTest } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

export default defineConfig({
	plugins: [
		cloudflareTest({
			wrangler: { configPath: "./wrangler.jsonc" },
			miniflare: {
				bindings: {
					APP_ATTEST_TEAM_ID: "1234567890",
					APP_ATTEST_BUNDLE_ID: "com.example.myapp",
					APP_ATTEST_ENVIRONMENTS: "production",
					APP_ATTEST_CATEGORIES: "1,2,4,none",
					MIN_BUILD_MAC: "100",
					MIN_BUILD_DEVICE: "1",
					ADDRESS_KEY: "a test deployment's key for addresses, not a secret",
				},
			},
		}),
	],
	test: { include: ["test/**/*.test.ts"] },
});
