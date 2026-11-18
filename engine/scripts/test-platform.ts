// CI's partition, not a portability promise. Only files verified unchanged on Linux go here; a new test is still
// discovered automatically and stays on macOS until verified. One list defines both halves so none is lost.
// credentialsplatform alone runs on both: its Mac half proves the file store cannot be selected there.
import { spawnSync } from "node:child_process";
import { readdirSync } from "node:fs";

const linux = new Set([
	"addedmodels", "cache", "chat", "codemode", "credentialsplatform", "earlystop", "everything", "exec", "heed", "latepath", "limits", "limitwait",
	"localmodels", "log", "look", "mcppath", "mcpreconnect", "modellists", "offered", "pictures", "reading", "rules", "runcode", "sections", "shellpath", "socket",
	"testcopies", "versions", "wakes",
]);
const group = process.argv[2];
if (group !== "linux" && group !== "macos") throw new Error("Choose linux or macos");
const tests = readdirSync(new URL("../test/", import.meta.url))
	.filter((name) => name.endsWith(".ts") && name !== "patience.ts" && name !== "browser.ts" && name !== "localserver.ts")
	.sort();
for (const name of linux) if (!tests.includes(`${name}.ts`)) throw new Error(`Missing Linux test: ${name}`);
const selected = tests.filter((name) => name === "credentialsplatform.ts" || linux.has(name.slice(0, -3)) === (group === "linux"));
if (selected.length === 0) throw new Error(`No tests for ${group}`);
console.log(`${group}: ${selected.join(", ")}`);
const result = spawnSync(process.execPath, ["--test", "--test-reporter=spec", ...selected.map((name) => `test/${name}`)], { stdio: "inherit" });
if (result.error) throw result.error;
process.exit(result.status ?? 1);
