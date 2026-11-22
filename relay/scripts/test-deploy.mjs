// Tests scripts/deploy.mjs without deploying anything: in a copy of relay/ in a temporary folder (its node_modules
// linked, engine/src/appattest.ts beside it as the bundle needs), with no Cloudflare variable in the environment, it
// builds both deployments as dry runs, and checks each refusal: a configuration that turns something on, a binding
// or a build step the relay does not have, a secret among the variables, production with no domain, a deploy with no
// token. And that a `.env` file planted in relay/ is not read by Wrangler (it could send the token elsewhere).
//
//   npm run test-deploy

import { spawnSync } from "node:child_process";
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { after, before, test } from "node:test";
import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";

const relay = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const original = readFileSync(join(relay, "wrangler.jsonc"), "utf8");
let root;
let copy;

before(() => {
	root = mkdtempSync(join(tmpdir(), "pi2-relay-test-deploy-"));
	copy = join(root, "relay");
	cpSync(relay, copy, { recursive: true, filter: (path) => !/\/(node_modules|\.wrangler)(\/|$)/.test(path.slice(relay.length)) });
	symlinkSync(join(relay, "node_modules"), join(copy, "node_modules"));
	mkdirSync(join(root, "engine/src"), { recursive: true });
	cpSync(join(relay, "../engine/src/appattest.ts"), join(root, "engine/src/appattest.ts"));
	mkdirSync(join(root, "home"));
});

after(() => rmSync(root, { recursive: true, force: true }));

/** Runs the copy's deploy.mjs with a wrangler.jsonc changed by `change`, and gives its status and what it wrote. */
function deploy(args, change = (text) => text) {
	writeFileSync(join(copy, "wrangler.jsonc"), change(original));
	const run = spawnSync(process.execPath, [join(copy, "scripts/deploy.mjs"), ...args], {
		cwd: copy,
		env: { PATH: process.env.PATH ?? "", HOME: join(root, "home") },
		encoding: "utf8",
	});
	return { status: run.status, output: `${run.stdout}${run.stderr}` };
}

/** `text` with `from` replaced by `to`, which must be there exactly once. */
function replace(text, from, to) {
	assert.equal(text.split(from).length, 2, `wrangler.jsonc holds ${JSON.stringify(from)} once`);
	return text.replace(from, to);
}

test("both deployments build as dry runs; production says it has no domain yet", () => {
	const development = deploy(["development", "--dry-run"]);
	assert.equal(development.status, 0, development.output);
	const production = deploy(["production", "--dry-run"]);
	assert.equal(production.status, 0, production.output);
	assert.match(production.output, /production has no custom domain yet/);
});

test("a .env file in relay/ is not read", () => {
	const planted = join(root, "planted.ndjson");
	writeFileSync(join(copy, ".env.development"), `WRANGLER_OUTPUT_FILE_PATH=${planted}\n`);
	try {
		const run = deploy(["development", "--dry-run"]);
		assert.equal(run.status, 0, run.output);
		assert.equal(existsSync(planted), false, "Wrangler took WRANGLER_OUTPUT_FILE_PATH from relay/.env.development");
	} finally {
		rmSync(join(copy, ".env.development"));
	}
});

test("a deploy with no token stops before Wrangler", () => {
	const run = deploy(["development"]);
	assert.equal(run.status, 1);
	assert.match(run.output, /CLOUDFLARE_API_TOKEN is not set/);
});

test("production with no custom domain is not deployed", () => {
	const run = deploy(["production"]);
	assert.equal(run.status, 1);
	assert.match(run.output, /not deploying the production relay/);
});

test("a wrong argument is refused", () => {
	assert.equal(deploy([]).status, 1);
	assert.equal(deploy(["staging", "--dry-run"]).status, 1);
});

/** A change to the development environment of wrangler.jsonc alone. */
function development(from, to) {
	return (text) => {
		const start = text.indexOf('"development": {');
		const end = text.indexOf('"production": {');
		return text.slice(0, start) + replace(text.slice(start, end), from, to) + text.slice(end);
	};
}

const refusals = [
	["Logpush on", (text) => replace(text, '"logpush": false,', '"logpush": true,'), /Logpush is not off/],
	["traces on", (text) => replace(text, '"traces": { "enabled": false }', '"traces": { "enabled": true }'), /traces and Issues are not all off/],
	["invocation logs on", (text) => replace(text, '"invocation_logs": false', '"invocation_logs": true'), /are not all off/],
	["preview addresses on", development('"preview_urls": false,\n\t\t\t"vars"', '"preview_urls": true,\n\t\t\t"vars"'), /preview and version addresses are not off/],
	["a build command", (text) => replace(text, '"main": "src/index.ts",', '"main": "src/index.ts",\n\t"build": { "command": "true" },'), /build step/],
	["a KV namespace", development('"tail_consumers": [],', '"tail_consumers": [],\n\t\t\t"kv_namespaces": [{ "binding": "KV", "id": "0123456789abcdef0123456789abcdef" }],'), /sets `kv_namespaces`/],
	["a tail consumer", development('"tail_consumers": [],', '"tail_consumers": [{ "service": "elsewhere" }],'), /sets `tail_consumers`/],
	["a fourth Durable Object", development('{ "name": "ADDRESSES", "class_name": "Address" }', '{ "name": "ADDRESSES", "class_name": "Address" },\n\t\t\t\t\t{ "name": "OTHER", "class_name": "Pairing" }'), /not exactly the relay's three/],
	["a secret among the variables", development('"APP_ATTEST_ENVIRONMENTS": "development",', '"APP_ATTEST_ENVIRONMENTS": "development",\n\t\t\t\t"ADDRESS_KEY": "not a secret any more, being here",'), /not the relay's settings, or are its secrets: ADDRESS_KEY/],
	["a route on the development relay", development('"name": "pi2-relay-development",', '"name": "pi2-relay-development",\n\t\t\t"routes": [{ "pattern": "relay.example.com", "custom_domain": true }],'), /development relay has a route/],
];

for (const [what, change, message] of refusals) {
	test(`a dry run refuses ${what}`, () => {
		const run = deploy(["development", "--dry-run"], change);
		assert.equal(run.status, 1, run.output);
		assert.match(run.output, message);
		assert.match(run.output, /not building the development relay/);
	});
}
