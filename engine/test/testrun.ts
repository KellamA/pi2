// The check at the end of a run (#577): runs over a folder of its own. One where every file reports must pass; one
// where a file ends before its tests report must fail and name it, even though every test that ran passed.

import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runTests } from "../scripts/test-run.ts";

const folder = mkdtempSync(join(tmpdir(), "pi2-testrun-"));
try {
	writeFileSync(join(folder, "reports.ts"), 'console.log("ok  a file that reports");\n');
	writeFileSync(join(folder, "quiet.ts"), 'import { test } from "node:test";\ntest("a test that never reports", () => {});\nprocess.exit(0);\n');
	const all = runTests(folder, ["reports.ts"]);
	assert.equal(all.status, 0, "a run in which every file reported should pass");
	assert.deepEqual(all.missing, [], "no file should be named as missing");
	const silent = runTests(folder, ["reports.ts", "quiet.ts"]);
	assert.equal(silent.status, 1, "a run in which a file never reported should fail");
	assert.deepEqual(silent.missing, ["quiet.ts"], "the file that never reported should be named");
	console.log("ok  a run over a folder where one file never reports fails and names it");
} finally {
	rmSync(folder, { recursive: true, force: true });
}
