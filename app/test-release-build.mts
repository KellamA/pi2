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
			// The app's answer to engine.info (a device's leaves out the path, #673).
			const changed = original.replace("{ build, main: engineMain,", '{ build: "wrong-build", main: engineMain,');
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
	// pi² Remote (#675): what app/remote-helper.sh must not give it, each in a copy signed again ad hoc so that only the
	// helper's check can refuse it. A team of its own other than the app's needs two Developer IDs, and is not tried.
	const helper = (copy: string) => join(copy, "Contents/Helpers/pi² Remote.app");
	const entitlements = join(scratch, "dyld.entitlements");
	writeFileSync(entitlements, '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict><key>com.apple.security.cs.allow-dyld-environment-variables</key><true/></dict></plist>\n');
	const helperFaults: [string, (copy: string) => void, RegExp][] = [
		["no-helper", (copy) => rmSync(join(copy, "Contents/Helpers"), { recursive: true }), /has no pi² Remote/],
		["helper-entitlement", (copy) => execFileSync("/usr/bin/codesign", ["--force", "--sign", "-", "--entitlements", entitlements, helper(copy)], { stdio: "pipe" }), /entitlements it may not have: com\.apple\.security\.cs\.allow-dyld-environment-variables/],
		[
			"helper-development",
			(copy) => {
				// A stand-in for a development build of the helper: an executable naming its key file.
				writeFileSync(join(helper(copy), "Contents/MacOS/pi² Remote"), "#!/bin/sh\n# remote-keys.json\nexit 78\n", { mode: 0o755 });
				execFileSync("/usr/bin/codesign", ["--force", "--sign", "-", helper(copy)], { stdio: "pipe" });
			},
			/names remote-keys\.json, which only a development build has/,
		],
		["helper-runtime", () => {}, /does not have the hardened runtime, which the app has/],
	];
	for (const [fault, change, says] of helperFaults) {
		const copy = join(scratch, `${fault}.app`);
		execFileSync("/usr/bin/ditto", [app, copy]);
		change(copy);
		// The app signed again over the changed helper; for helper-runtime, the app with the hardened runtime and the helper without.
		execFileSync("/usr/bin/codesign", ["--force", ...(fault === "helper-runtime" ? ["--options", "runtime"] : []), "--sign", "-", copy], { stdio: "pipe" });
		const result = spawnSync(process.execPath, [check, copy], { encoding: "utf8", timeout: 10 * 60_000 });
		assert.ifError(result.error);
		const output = result.stdout + result.stderr;
		assert.equal(result.status, 1, output);
		assert.match(output, /its code signature holds/, output);
		assert.match(output, says, output);
		console.log(`ok  ${fault} is refused by the check of pi² Remote`);
	}
} finally {
	rmSync(scratch, { recursive: true, force: true });
}
