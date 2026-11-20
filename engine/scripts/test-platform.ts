// CI's partition, not a portability promise. Only files verified unchanged on Linux go here; a new test is still
// discovered automatically and stays on macOS until verified. One list defines both halves so none is lost.
// credentialsplatform alone runs on both: its Mac half proves the file store cannot be selected there. "local"
// runs the whole suite, as npm test does, and every group's run is checked afterwards: a file that did not report
// fails it, by name (#577).
import { join } from "node:path";
import { installedState, STALE_MESSAGE } from "./installed.ts";
import { testFiles } from "./test-files.ts";
import { runTests } from "./test-run.ts";

// Before anything is chosen or started: an install older than the checkout fails tests in ways that name neither.
if (installedState(join(import.meta.dirname, "..")) !== "current") {
	console.error(STALE_MESSAGE);
	process.exit(1);
}

const linux = new Set([
	"addedmodels", "cache", "chat", "codemode", "credentialsplatform", "earlystop", "everything", "exec", "heed", "latepath", "limits", "limitwait",
	"localmodels", "log", "look", "mcppath", "mcpreconnect", "modellists", "offered", "pictures", "reading", "rules", "runcode", "sections", "shellpath", "socket",
	"testcopies", "versions", "wakes",
]);
const group = process.argv[2];
if (group !== "linux" && group !== "macos" && group !== "local") throw new Error("Choose linux, macos or local");
const tests = testFiles(join(import.meta.dirname, "..", "test"));
for (const name of linux) if (!tests.includes(`${name}.ts`)) throw new Error(`Missing Linux test: ${name}`);
const selected = group === "local" ? tests : tests.filter((name) => name === "credentialsplatform.ts" || linux.has(name.slice(0, -3)) === (group === "linux"));
if (selected.length === 0) throw new Error(`No tests for ${group}`);
console.log(group === "local" ? `local: ${selected.length} test files` : `${group}: ${selected.join(", ")}`);
process.exit(runTests(join(import.meta.dirname, ".."), selected.map((name) => `test/${name}`)).status);
