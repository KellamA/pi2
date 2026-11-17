// Negative controls for the real packaged-engine check. Takes an already built release app; changes copies only.
// Run after build.sh release. No release keys, tag, signing identity or publication.
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";

const app = resolve(process.argv[2]!);
const scratch = mkdtempSync("/tmp/pi2-negative-");
const check = join(import.meta.dirname, "check-release-build.mts");
try {
	for (const fault of ["missing-module", "wrong-build"]) {
		const copy = join(scratch, `${fault}.app`);
		execFileSync("/usr/bin/ditto", [app, copy]);
		const src = join(copy, "Contents/Resources/engine/src");
		if (fault === "missing-module") rmSync(join(src, "socket.ts"));
		else {
			const main = join(src, "main.ts");
			const original = readFileSync(main, "utf8");
			const changed = original.replace('"engine.info": async () => ({ build,', '"engine.info": async () => ({ build: "wrong-build",');
			assert.notEqual(changed, original, "the negative control must change engine.info");
			writeFileSync(main, changed);
		}
		// Keep the resource seal valid: this must fail the engine check, not just codesign verification.
		execFileSync("/usr/bin/codesign", ["--force", "--sign", "-", copy], { stdio: "pipe" });
		const result = spawnSync(process.execPath, [check, copy], { encoding: "utf8", timeout: 10 * 60_000 });
		assert.ifError(result.error);
		const output = result.stdout + result.stderr;
		assert.equal(result.status, 1, output);
		assert.match(output, /its code signature holds/, output);
		assert.match(output, fault === "missing-module" ? /ERR_MODULE_NOT_FOUND/ : /The engine says it is build wrong-build/, output);
		console.log(`ok  ${fault} is rejected after verifying the signature`);
	}
} finally {
	rmSync(scratch, { recursive: true, force: true });
}
