// Checks the Worker as Wrangler bundles it for a deploy, without deploying anything (README.md, "The verifier"): that
// App Attest's verifier in it is the engine's own file, engine/src/appattest.ts, taken by its path, and that nothing
// of the relay's own is another verifier. Builds with `wrangler deploy --dry-run`, which uploads nothing, in a
// temporary folder that is also Wrangler's home for the run, so it reads no sign-in and leaves nothing behind.
//
//   npm run check-bundle

import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const relay = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const verifier = resolve(relay, "../engine/src/appattest.ts");
const temporary = mkdtempSync(join(tmpdir(), "pi2-relay-bundle-"));
const failures = [];

try {
	execFileSync(
		join(relay, "node_modules/.bin/wrangler"),
		["deploy", "--dry-run", "--outdir", join(temporary, "out"), "--metafile", join(temporary, "meta.json")],
		{
			cwd: relay,
			stdio: ["ignore", "ignore", "inherit"],
			env: {
				PATH: process.env.PATH,
				HOME: temporary,
				WRANGLER_SEND_METRICS: "false",
				WRANGLER_LOG_PATH: join(temporary, "logs"),
			},
		},
	);
	const meta = JSON.parse(readFileSync(join(temporary, "meta.json"), "utf8"));
	const inputs = Object.keys(meta.inputs).map((input) => resolve(relay, input));

	if (!inputs.includes(verifier)) failures.push("the bundle does not include engine/src/appattest.ts");
	for (const input of inputs) {
		if (input === verifier) continue;
		if (!input.startsWith(join(relay, "src") + "/")) failures.push(`the bundle includes a file from outside relay/src: ${relative(relay, input)}`);
		if (/function\s+verifyAttestation\b|APPLE_APP_ATTEST_ROOT\s*=/.test(readFileSync(input, "utf8"))) {
			failures.push(`relay/${relative(relay, input)} holds a verifier of its own`);
		}
	}
	const bundle = readFileSync(join(temporary, "out", "index.js"), "utf8");
	const root = /APPLE_APP_ATTEST_ROOT_SHA256 = "([0-9a-f]{64})"/.exec(readFileSync(verifier, "utf8"))?.[1];
	if (root === undefined || !bundle.includes(root)) failures.push("the bundle does not carry the engine's pinned root");
} finally {
	rmSync(temporary, { recursive: true, force: true });
}

if (failures.length > 0) {
	for (const failure of failures) process.stderr.write(`check-bundle: ${failure}\n`);
	process.exit(1);
}
process.stdout.write("check-bundle: the Worker's verifier is engine/src/appattest.ts, and the relay has no other.\n");
