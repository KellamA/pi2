// Deploys the relay to one of its two deployments (wrangler.jsonc, docs/relay.md "Deploying"), or, with --dry-run,
// builds it as that deploy would and uploads nothing. The one way the relay is deployed: .github/workflows/relay.yml
// runs it once the owner approves, and the owner runs it by hand otherwise.
//
//   node scripts/deploy.mjs development|production [--dry-run]
//
// Before anything is built it checks what the deployment would be, as Wrangler reads wrangler.jsonc: logs, Logpush and
// tail consumers off, no preview or version addresses, no secret among the variables, and for production a custom
// domain and no workers.dev address. Then it runs `wrangler deploy` as scripts/isolated.mjs runs a tool: a throwaway
// home folder, Wrangler's usage events off, `--config` named; and it passes the Cloudflare token and account id on
// (CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID), and nothing else of the caller's environment but PATH. A dry run
// passes neither.

import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
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
// The settings a deployment keeps as Workers secrets, never in wrangler.jsonc, which is public (README.md, "Settings").
const SECRETS = ["APP_ATTEST_TEAM_ID", "ADDRESS_KEY", "APNS_KEY", "APNS_KEY_ID", "APNS_TEAM_ID"];

home = mkdtempSync(join(tmpdir(), "pi2-relay-deploy-"));
for (const folder of ["config", "cache", "data", "logs"]) mkdirSync(join(home, folder));
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
	const problems = check(readConfig());
	if (problems.refuse.length > 0) {
		for (const problem of problems.refuse) process.stderr.write(`deploy: ${problem}\n`);
		if (!dryRun) fail(`not deploying the ${deployment} relay.`);
		process.stderr.write(`deploy: a deploy would stop here; building anyway, since this is a dry run.\n`);
	}
	const wrangler = ["deploy", "--config", "wrangler.jsonc", "--env", deployment];
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

/** What would make this deployment other than docs/iphone.md 5.3 and docs/relay.md say it is. */
function check(config) {
	const refuse = [];
	if (config.name !== `pi2-relay-${deployment}`) refuse.push(`the ${deployment} environment of wrangler.jsonc is missing, or has another name`);
	const logs = config.observability ?? {};
	if (logs.enabled !== false || logs.logs?.enabled !== false || logs.logs?.invocation_logs !== false) refuse.push("Workers Logs or invocation logs are not off");
	if (config.logpush === true) refuse.push("Logpush is on");
	if ((config.tail_consumers ?? []).length > 0 || (config.streaming_tail_consumers ?? []).length > 0) refuse.push("a tail consumer is set");
	if (config.preview_urls !== false) refuse.push("preview and version addresses are not off");
	if (config.send_metrics !== false) refuse.push("Wrangler's usage events are not off");
	const secrets = Object.keys(config.vars ?? {}).filter((name) => SECRETS.includes(name));
	if (secrets.length > 0) refuse.push(`wrangler.jsonc names a secret among its variables: ${secrets.join(", ")}`);
	if (deployment === "production") {
		if (config.workers_dev !== false) refuse.push("production has a workers.dev address, which no rate limit of the domain's covers");
		const domains = (config.routes ?? []).filter((route) => typeof route === "object" && route.custom_domain === true);
		if (domains.length === 0) refuse.push("production has no custom domain yet: add it to wrangler.jsonc (docs/relay.md, \"The production relay\")");
	}
	return { refuse };
}

function fail(message) {
	process.stderr.write(`deploy: ${message}\n`);
	if (home !== undefined) rmSync(home, { recursive: true, force: true });
	process.exit(1);
}
