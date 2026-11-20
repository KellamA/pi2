// Runs the engine's test files and checks afterwards that every one of them reported (#577). A file that ends
// before its tests report, or that was never started at all, leaves nothing in the output that names it: node counts
// a file that ends as a pass, so a silent omission passes too. The events the run gives its reporter are read
// afterwards, and a file that should have run and did not report fails the run by name, even when every test that
// ran passed.

import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";

export type Run = { status: number; missing: string[] };

/** Runs `files`, named from `cwd`, and says which of them did not report. */
export function runTests(cwd: string, files: string[]): Run {
	const folder = mkdtempSync(join(tmpdir(), "pi2-test-events-"));
	const events = join(folder, "events.jsonl");
	try {
		const result = spawnSync(
			process.execPath,
			[
				"--test",
				"--test-reporter=spec",
				"--test-reporter-destination=stdout",
				`--test-reporter=${join(import.meta.dirname, "test-report.ts")}`,
				`--test-reporter-destination=${events}`,
				...files,
			],
			// A test that runs a run of its own would otherwise have its files skipped: node's runner reads
			// NODE_TEST_CONTEXT, which it sets in the children it starts, as "this process is already a child".
			{ cwd, stdio: "inherit", env: { ...process.env, NODE_TEST_CONTEXT: undefined } },
		);
		if (result.error) throw result.error;
		const reported = names(events, files);
		const missing = files.filter((file) => !reported.has(basename(file)));
		if (missing.length > 0) {
			console.error(`test: ${missing.length} of ${files.length} test files did not report: ${missing.join(", ")}`);
			console.error("test: a file that ends before its tests report counts as a pass, so this run cannot be trusted");
		} else {
			console.log(`test: all ${files.length} test files reported`);
		}
		return { status: missing.length > 0 ? 1 : result.status ?? 1, missing };
	} finally {
		rmSync(folder, { recursive: true, force: true });
	}
}

// The files whose events say something of their own ran: a test by name, a failure to load, or output the file
// printed. A file that ends without any of that gets one event, a pass named after the file itself, which is no
// report at all: node makes it for a file that exits before its tests are registered, as well as for one that
// prints its own "ok" lines and ends. The printed lines are what tell the two apart.
function names(events: string, files: string[]): Set<string> {
	const given = new Map(files.map((file) => [basename(file), file]));
	const reported = new Set<string>();
	// A run that wrote no events at all reported nothing, so every file is missing and the run fails, as it should.
	if (!existsSync(events)) return reported;
	for (const line of readFileSync(events, "utf8").split("\n")) {
		if (line === "") continue;
		const event = JSON.parse(line) as { type: string; name?: string; file?: string };
		const file = event.file === undefined ? "" : basename(event.file);
		if (file === "") continue;
		const ran =
			(event.type === "test:pass" && event.name !== given.get(file)) ||
			event.type === "test:fail" ||
			event.type === "test:stdout" ||
			event.type === "test:stderr";
		if (ran) reported.add(file);
	}
	return reported;
}
