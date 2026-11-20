// The engine's test files, in one place, so that `npm test` and CI's two groups take the same list (#577). A
// program's list, not a shell's pattern: what a pattern matches depends on the shell that runs it, and the list a
// run is checked against has to be the list it was given. A file that is not a test goes in here beside the others:
// patience.ts holds the helpers the tests share, browser.ts needs the browser probe, and localserver.ts stands in
// for an engine rather than testing one.

import { readdirSync } from "node:fs";

const NOT_TESTS = new Set(["patience.ts", "browser.ts", "localserver.ts"]);

export function testFiles(folder: string): string[] {
	return readdirSync(folder)
		.filter((name) => name.endsWith(".ts") && !NOT_TESTS.has(name))
		.sort();
}
