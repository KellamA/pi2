// Checks the Worker as Wrangler bundles it for a deploy, without deploying anything (README.md, "The verifier"): that
// App Attest's verifier in it is the engine's own file, engine/src/appattest.ts, taken by its path, and that nothing
// of the relay's own is another verifier, under its own names or others. Builds with `wrangler deploy --dry-run`, which uploads nothing, in a
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
		// `--config` names the project, which also keeps Wrangler from looking for one to set up (and sending events of it).
		["deploy", "--dry-run", "--config", "wrangler.jsonc", "--outdir", join(temporary, "out"), "--metafile", join(temporary, "meta.json")],
		{
			cwd: relay,
			stdio: ["ignore", "ignore", "inherit"],
			env: {
				PATH: process.env.PATH,
				HOME: temporary,
				XDG_CONFIG_HOME: join(temporary, "config"),
				WRANGLER_SEND_METRICS: "false",
				WRANGLER_LOG_PATH: join(temporary, "logs"),
			},
		},
	);
	const meta = JSON.parse(readFileSync(join(temporary, "meta.json"), "utf8"));
	const inputs = Object.keys(meta.inputs).map((input) => resolve(relay, input));
	const source = readFileSync(verifier, "utf8");

	// What only a copy of the verifier would hold: a definition of any name the engine's file exports, its pinned root
	// (each line of its base64) and fingerprint, and its other long constants (the environments' AAGUIDs, the object
	// identifiers it looks for), so that a copy with its names changed is caught as well.
	const names = [...source.matchAll(/^export (?:async )?(?:function|class|const|let|type) ([A-Za-z_$][\w$]*)/gm)].map((match) => match[1]);
	const definition = new RegExp(`\\b(?:function|class|const|let|var|type)\\s+(?:${names.join("|")})\\b`);
	const rootStart = source.indexOf("export const APPLE_APP_ATTEST_ROOT =");
	const rootLines = [...source.slice(rootStart, source.indexOf(";", rootStart)).matchAll(/"([A-Za-z0-9+/=]{40,})"/g)].map((match) => match[1]);
	const constants = [...source.matchAll(/"([0-9a-f]{14,})"/g)].map((match) => match[1]);
	if (names.length < 4 || rootLines.length < 4 || constants.length < 4) failures.push("could not read engine/src/appattest.ts's names and constants");
	const marks = [...rootLines, ...constants];

	if (!inputs.includes(verifier)) failures.push("the bundle does not include engine/src/appattest.ts");
	for (const input of inputs) {
		if (input === verifier) continue;
		const name = `relay/${relative(relay, input)}`;
		if (!input.startsWith(join(relay, "src") + "/")) failures.push(`the bundle includes a file from outside relay/src: ${relative(relay, input)}`);
		const text = readFileSync(input, "utf8");
		if (definition.test(text)) failures.push(`${name} defines a name of the verifier's`);
		if (marks.some((mark) => text.includes(mark))) failures.push(`${name} holds a constant of the verifier's`);
	}
	const bundle = readFileSync(join(temporary, "out", "index.js"), "utf8");
	const root = /APPLE_APP_ATTEST_ROOT_SHA256 = "([0-9a-f]{64})"/.exec(source)?.[1];
	if (root === undefined || bundle.split(root).length !== 2) failures.push("the bundle does not carry the engine's pinned root exactly once");
} finally {
	rmSync(temporary, { recursive: true, force: true });
}

if (failures.length > 0) {
	for (const failure of failures) process.stderr.write(`check-bundle: ${failure}\n`);
	process.exit(1);
}
process.stdout.write("check-bundle: the Worker's verifier is engine/src/appattest.ts, and the relay has no other.\n");
