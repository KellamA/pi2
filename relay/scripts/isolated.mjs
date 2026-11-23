// Runs one of the relay's development tools (Wrangler, Vitest, TypeScript) so that it writes nothing outside relay/ and
// a temporary folder, and sends nothing: a throwaway home folder for the run (Wrangler writes a device id and logs
// under the home's preferences, Vitest a token under its application support), `WRANGLER_SEND_METRICS=false` (Wrangler
// 4.166's project setting `send_metrics` does not cover every event it sends), and no Cloudflare credential from the
// caller's environment. Every script in package.json that runs a tool goes through this (README.md, "Tests").
//
//   node scripts/isolated.mjs <tool in node_modules/.bin> [arguments…]

import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const relay = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const [tool, ...args] = process.argv.slice(2);
if (tool === undefined || !/^[a-z][a-z0-9-]*$/.test(tool)) {
	process.stderr.write("isolated: name a tool in node_modules/.bin\n");
	process.exit(2);
}

const home = mkdtempSync(join(tmpdir(), "pi2-relay-home-"));
for (const folder of ["config", "cache", "data", "logs"]) mkdirSync(join(home, folder));
const env = Object.fromEntries(Object.entries(process.env).filter(([name]) => !name.startsWith("CLOUDFLARE_") && !name.startsWith("CF_")));
Object.assign(env, {
	HOME: home,
	XDG_CONFIG_HOME: join(home, "config"),
	XDG_CACHE_HOME: join(home, "cache"),
	XDG_DATA_HOME: join(home, "data"),
	WRANGLER_SEND_METRICS: "false",
	WRANGLER_LOG_PATH: join(home, "logs"),
});

let status = 1;
try {
	const run = spawnSync(join(relay, "node_modules/.bin", tool), args, { cwd: relay, env, stdio: "inherit" });
	status = run.status ?? 1;
} finally {
	rmSync(home, { recursive: true, force: true });
}
process.exit(status);
