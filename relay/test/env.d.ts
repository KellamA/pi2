// What the tests' `env` holds: the relay's own bindings and settings, as vitest.config.ts gives them.
import type { Env as RelayEnv } from "../src/settings.ts";

declare global {
	namespace Cloudflare {
		interface Env extends RelayEnv {}
	}
}
