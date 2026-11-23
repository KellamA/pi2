// Deploys the relay to one of its two deployments (wrangler.jsonc, docs/relay.md "Deploying"), or, with --dry-run,
// builds it as that deploy would and uploads nothing. The one way the relay is deployed: .github/workflows/relay.yml
// runs it once the owner approves, and the owner runs it by hand otherwise.
//
//   node scripts/deploy.mjs development|production [--dry-run]
//
// Before anything is built it checks what the deployment would be, as Wrangler reads wrangler.jsonc, against what it
// may be: logs, traces, Issues, Logpush and tail consumers off; no preview or version addresses; no build command;
// the three Durable Objects and the settings' variables as its only bindings, and no secret among them; the
// migrations and the compatibility date and flags exactly as listed below; for production, a custom domain and no workers.dev address. Anything else refuses, a dry run included (so CI fails a pull
// request that changes one), but for production's missing domain, which a dry run only reports.
//
// Then it runs `wrangler deploy` as scripts/isolated.mjs runs a tool: a throwaway home folder, Wrangler's usage events
// off, `--config` named, and `--env-file` naming an empty file, so that Wrangler reads no `.env` file of relay/ (one
// could set CLOUDFLARE_API_BASE_URL and send the token elsewhere). It passes the Cloudflare token and account id on
// (CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID), and nothing else of the caller's environment but PATH. A dry run
// passes neither. scripts/test-deploy.mjs tests the refusals and the `.env` file left unread.

import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const relay = resolve(dirname(fileURLToPath(import.meta.url)), "..");
let home;
const args = process.argv.slice(2);
const dryRun = args.includes("--dry-run");
const names = args.filter((arg) => arg !== "--dry-run");
const deployment = names[0];
if (names.length !== 1 || (deployment !== "development" && deployment !== "production")) {
	fail("usage: node scripts/deploy.mjs development|production [--dry-run]");
}

// The variables a deployment may have: the settings that are not secret (README.md, "Settings"). The secrets
// (APP_ATTEST_TEAM_ID, ADDRESS_KEY, and the push key's) are never in wrangler.jsonc, which is public.
const VARIABLES = ["APP_ATTEST_BUNDLE_ID", "APP_ATTEST_ENVIRONMENTS", "APP_ATTEST_CATEGORIES", "MIN_BUILD_MAC", "MIN_BUILD_DEVICE"];
const OBJECTS = [
	{ name: "PAIRINGS", class_name: "Pairing" },
	{ name: "ATTEST_KEYS", class_name: "AttestKey" },
	{ name: "ADDRESSES", class_name: "Address" },
];
// The Durable Objects' migrations, whole. A deploy applies whatever wrangler.jsonc lists, and both relays are on one
// account with one token: a class transferred from the other relay, deleted (every pairing with it) or renamed, or a
// new tag, would act on stored pairings. So any change refuses until this list is changed too, in the same reviewed
// pull request as the migration (docs/relay.md, "What the workflow does").
const MIGRATIONS = [{ tag: "v1", new_sqlite_classes: ["Pairing", "AttestKey", "Address"] }];
// The runtime: Node's modules off, and the date wrangler.jsonc names. A later date or another flag is changed here too.
const COMPATIBILITY = { date: "2026-11-01", flags: ["no_nodejs_compat", "no_nodejs_compat_v2"] };
// What Wrangler's resolved configuration may hold that is not empty. Anything else (a binding of any other kind,
// assets, `unsafe`, a key a later Wrangler adds) refuses, so that nothing reaches a deployment unchecked.
const ALLOWED = new Set([
	// Wrangler's own bookkeeping and local development's settings.
	"configPath",
	"userConfigPath",
	"topLevelName",
	"definedEnvironments",
	"targetEnvironment",
	"jsx_factory",
	"jsx_fragment",
	"python_modules",
	"dev",
	// What wrangler.jsonc says, each checked below.
	"name",
	"main",
	"compatibility_date",
	"compatibility_flags",
	"send_metrics",
	"dependencies_instrumentation",
	"keep_vars",
	"observability",
	"logpush",
	"upload_source_maps",
	"workers_dev",
	"preview_urls",
	"routes",
	"build",
	"vars",
	"durable_objects",
	"migrations",
]);

home = mkdtempSync(join(tmpdir(), "pi2-relay-deploy-"));
for (const folder of ["config", "cache", "data", "logs"]) mkdirSync(join(home, folder));
const noEnvFile = join(home, "empty.env");
writeFileSync(noEnvFile, "");
const env = {
	PATH: process.env.PATH ?? "",
	HOME: home,
	XDG_CONFIG_HOME: join(home, "config"),
	XDG_CACHE_HOME: join(home, "cache"),
	XDG_DATA_HOME: join(home, "data"),
	WRANGLER_SEND_METRICS: "false",
	WRANGLER_LOG_PATH: join(home, "logs"),
};

let status = 1;
try {
	const { refuse, noDomain } = check(readConfig());
	for (const problem of refuse) process.stderr.write(`deploy: ${problem}\n`);
	if (refuse.length > 0) fail(`not ${dryRun ? "building" : "deploying"} the ${deployment} relay.`);
	if (noDomain) {
		process.stderr.write("deploy: production has no custom domain yet: add it to wrangler.jsonc (docs/relay.md, \"The production relay\")\n");
		if (!dryRun) fail("not deploying the production relay.");
		process.stderr.write("deploy: a deploy would stop here; building anyway, since this is a dry run.\n");
	}
	const wrangler = ["deploy", "--config", "wrangler.jsonc", "--env", deployment, "--env-file", noEnvFile];
	if (dryRun) {
		wrangler.push("--dry-run", "--outdir", join(home, "out"));
	} else {
		for (const name of ["CLOUDFLARE_API_TOKEN", "CLOUDFLARE_ACCOUNT_ID"]) {
			const value = process.env[name];
			if (value === undefined || value === "") fail(`${name} is not set: the deploy needs the token and the account id of the relay's Cloudflare account.`);
			env[name] = value;
		}
	}
	const run = spawnSync(join(relay, "node_modules/.bin/wrangler"), wrangler, { cwd: relay, env, stdio: "inherit" });
	status = run.status ?? 1;
	if (status === 0 && !dryRun) {
		process.stdout.write(
			`\ndeploy: the ${deployment} relay is deployed. Check it with \`node relay/scripts/register.mjs wss://<its address>/v1\` (docs/relay.md).\n`,
		);
	}
} finally {
	rmSync(home, { recursive: true, force: true });
}
process.exit(status);

/** The deployment's configuration, as Wrangler resolves it, read in a child with the same isolated environment. */
function readConfig() {
	const script = `
		import { unstable_readConfig } from "wrangler";
		const config = unstable_readConfig({ config: "wrangler.jsonc", env: ${JSON.stringify(deployment)} });
		process.stdout.write(JSON.stringify(config));
	`;
	const run = spawnSync(process.execPath, ["--input-type=module", "-e", script], { cwd: relay, env, encoding: "utf8", stdio: ["ignore", "pipe", "inherit"] });
	if (run.status !== 0) fail("could not read wrangler.jsonc (has `npm ci` been run in relay/?)");
	return JSON.parse(run.stdout);
}

/** Whether a resolved value is empty: nothing, false, an empty list, or an object of nothing but empty values. */
function empty(value) {
	if (value === undefined || value === null || value === false) return true;
	if (Array.isArray(value)) return value.length === 0;
	if (typeof value === "object") return Object.values(value).every(empty);
	return false;
}

function same(a, b) {
	return JSON.stringify(a) === JSON.stringify(b);
}

/** What would make this deployment other than docs/iphone.md 5.3 and docs/relay.md say it is. */
function check(config) {
	const refuse = [];
	for (const [key, value] of Object.entries(config)) {
		if (!ALLOWED.has(key) && !empty(value)) refuse.push(`wrangler.jsonc sets \`${key}\`, which no deployment of the relay has`);
	}
	if (config.name !== `pi2-relay-${deployment}`) refuse.push(`the ${deployment} environment of wrangler.jsonc is missing, or has another name`);
	if (!same(config.observability, { enabled: false, logs: { enabled: false, invocation_logs: false }, traces: { enabled: false }, issues: { enabled: false } })) {
		refuse.push("logs, invocation logs, traces and Issues are not all off, exactly as wrangler.jsonc writes them");
	}
	if (config.logpush !== false) refuse.push("Logpush is not off");
	if (config.preview_urls !== false) refuse.push("preview and version addresses are not off");
	if (config.send_metrics !== false) refuse.push("Wrangler's usage events are not off");
	if (config.dependencies_instrumentation?.enabled !== false) refuse.push("Wrangler's report of the packages used is not off");
	if (config.keep_vars !== false) refuse.push("`keep_vars` is on: variables added in the dashboard would outlive a deploy");
	if (config.main !== join(relay, "src/index.ts")) refuse.push("the Worker's entry is not src/index.ts");
	if (!same(config.migrations, MIGRATIONS)) refuse.push("the Durable Objects' migrations are not the ones deploy.mjs expects: change MIGRATIONS there in the same pull request");
	if (config.compatibility_date !== COMPATIBILITY.date) refuse.push(`the compatibility date is not ${COMPATIBILITY.date}: change COMPATIBILITY in deploy.mjs in the same pull request`);
	if (!same(config.compatibility_flags, COMPATIBILITY.flags)) refuse.push("the compatibility flags are not exactly Node's modules off");
	// Wrangler runs a build command in a shell, which on a deploy would have the token in reach.
	if (Object.keys(config.build ?? {}).some((key) => key !== "watch_dir")) refuse.push("wrangler.jsonc has a build step, which a deploy would run beside the token");
	if (!same(config.durable_objects, { bindings: OBJECTS })) refuse.push("the Durable Objects are not exactly the relay's three");
	const unknown = Object.keys(config.vars ?? {}).filter((name) => !VARIABLES.includes(name));
	if (unknown.length > 0) refuse.push(`wrangler.jsonc has variables that are not the relay's settings, or are its secrets: ${unknown.join(", ")}`);
	const routes = config.routes ?? [];
	if (routes.some((route) => typeof route !== "object" || route.custom_domain !== true)) refuse.push("a route is not a custom domain");
	let noDomain = false;
	if (deployment === "production") {
		if (config.workers_dev !== false) refuse.push("production has a workers.dev address, which no rate limit of the domain's covers");
		noDomain = routes.length === 0;
	} else if (routes.length > 0) {
		refuse.push("the development relay has a route: it lives at its workers.dev address");
	}
	return { refuse, noDomain };
}

function fail(message) {
	process.stderr.write(`deploy: ${message}\n`);
	if (home !== undefined) rmSync(home, { recursive: true, force: true });
	process.exit(1);
}
