// The stamp that says which patches an install carries (#521), without an engine: a temporary folder shaped like an
// engine folder, with its stamp missing, current, and stale in two ways, then the hash's own rules. It never touches
// the real node_modules.

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { installHash, installedState, STALE_MESSAGE } from "../scripts/installed.ts";

function step(name: string): void {
	console.log(`ok  ${name}`);
}

const root = mkdtempSync(join(tmpdir(), "pi2-installed-test-"));
process.on("exit", () => rmSync(root, { recursive: true, force: true }));

/** A folder shaped like an engine folder: patch files, the lock file, and node_modules if asked for. */
function engineFolder(name: string, patches: [string, string][], { installed = true } = {}): string {
	const dir = join(root, name);
	mkdirSync(join(dir, "scripts"), { recursive: true });
	if (installed) mkdirSync(join(dir, "node_modules"));
	for (const [file, text] of patches) writeFileSync(join(dir, "scripts", `patch-${file}.ts`), text);
	writeFileSync(join(dir, "package-lock.json"), `${JSON.stringify({ lockfileVersion: 3 })}\n`);
	return dir;
}

/** What patch-dependencies.ts writes once every patch is applied. */
function stamp(dir: string): void {
	writeFileSync(join(dir, "node_modules", ".pi2-installed.json"), `${JSON.stringify({ hash: installHash(dir) })}\n`);
}

const patches: [string, string][] = [["a", "one"], ["b", "two"]];

// ---- Missing

const engine = engineFolder("engine", patches);
assert.equal(installedState(engine), "missing", "no stamp");
assert.equal(installedState(engineFolder("no-modules", patches, { installed: false })), "missing", "no node_modules");
assert.equal(STALE_MESSAGE.endsWith("run `npm --prefix engine ci`."), true, "the message says what to do");
step("missing: an installed tree with no stamp, and one with no node_modules");

// ---- Current

stamp(engine);
assert.equal(installedState(engine), "current");
step("current: the stamp patch-dependencies.ts writes after its last patch");

// ---- Stale

writeFileSync(join(engine, "scripts", "patch-a.ts"), "one, patched again since");
assert.equal(installedState(engine), "stale", "a patch changed");
step("stale: a patch changed after the install");

stamp(engine);
writeFileSync(join(engine, "package-lock.json"), `${JSON.stringify({ lockfileVersion: 3, packages: {} })}\n`);
assert.equal(installedState(engine), "stale", "the lock file changed");
step("stale: the lock file changed after the install");

// ---- What the hash is over

// By hand, the way installHash says: each patch in name order, then the lock file. A folder whose patches were written
// in the other order hashes the same, so nothing depends on how the disk happens to list them.
const written = engineFolder("written-in-order", patches);
const writtenReversed = engineFolder("written-backwards", [...patches].reverse());
const byName = createHash("sha256")
	.update(readFileSync(join(written, "scripts", "patch-a.ts"))).update("\0")
	.update(readFileSync(join(written, "scripts", "patch-b.ts"))).update("\0")
	.update(readFileSync(join(written, "package-lock.json")))
	.digest("hex");
assert.equal(installHash(written), byName);
assert.equal(installHash(writtenReversed), byName);
step("the hash is the patches by name, then the lock file, whatever order they were written in");

writeFileSync(join(written, "scripts", "installed.ts"), "// not a patch\n");
writeFileSync(join(written, "scripts", "patches.md"), "not a patch either\n");
assert.equal(installHash(written), byName);
step("a file in scripts that is not a patch-*.ts does not change the hash");

// ---- Running the script twice

// A tree that carries the stamp is refused by the script itself, since a second pass would apply some patches twice
// (#584). The folder it refuses is left as it was, stamp and all.
const stamped = mkdtempSync(join(tmpdir(), "pi2-stamped-test-"));
mkdirSync(join(stamped, "node_modules"), { recursive: true });
const stampFile = join(stamped, "node_modules", ".pi2-installed.json");
const stampText = `${JSON.stringify({ hash: "a stamp from an install that is not here" })}\n`;
writeFileSync(stampFile, stampText);
const refusal = spawnSync(process.execPath, [join(import.meta.dirname, "..", "scripts", "patch-dependencies.ts"), stamped], { encoding: "utf8" });
assert.equal(refusal.status, 1, "it exits 1 rather than patching the tree again");
assert.equal(refusal.stderr.includes("already patched"), true, "it says why, and what to run instead");
assert.equal(readFileSync(stampFile, "utf8"), stampText, "the stamp file is left as it was");
rmSync(stamped, { recursive: true, force: true });
step("a tree already patched is refused, and left as it was");
