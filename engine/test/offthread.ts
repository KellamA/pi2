// The engine's own short programs (git, `security`, `ps`, `lsof`, `textutil`) run from a worker thread, so that
// starting them never holds the engine's thread (#344, src/offthread.ts). What they give back is what `execFile` gives.

import assert from "node:assert/strict";
import { mkdtempSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { isMainThread } from "node:worker_threads";
import { execFileOffThread, runOffThread } from "../src/offthread.ts";

const folder = realpathSync(mkdtempSync(join(tmpdir(), "pi2-offthread-")));
process.on("exit", () => rmSync(folder, { recursive: true, force: true }));

function step(name: string): void {
	console.log(`ok  ${name}`);
}

assert.ok(isMainThread);
const ok = await runOffThread("/bin/sh", ["-c", 'printf "%s|%s" "$PWD" "$PI2_OFFTHREAD"; printf oops >&2'], { cwd: folder, env: { PI2_OFFTHREAD: "here", PATH: "/usr/bin:/bin" } });
assert.equal(ok.error, null);
assert.equal(ok.stdout, `${folder}|here`, "in the folder and with the environment given");
assert.equal(ok.stderr, "oops");
step("a program runs in the folder and with the environment it is given, and its output comes back");

const failed = await runOffThread("/bin/sh", ["-c", "echo out; exit 3"]);
assert.equal(failed.error?.code, 3, "a program that fails says its exit code");
assert.equal(failed.stdout, "out\n", "and what it printed");
const missing = await runOffThread(join(folder, "no-such-program"), []);
assert.equal(missing.error?.code, "ENOENT", "a program that is not there says so, as execFile does");
step("failures come back as execFile gives them");

const input = await runOffThread("/bin/cat", [], { input: "given on standard input" });
assert.equal(input.stdout, "given on standard input");
const closed = await runOffThread("/bin/cat", []);
assert.equal(closed.stdout, "", "without input, standard input is closed at once, so a program reading it does not wait");
step("input is written to its standard input, which is then closed");

const slow = await runOffThread("/bin/sleep", ["600"], { timeout: 200 });
assert.equal(slow.error?.killed, true, "one that runs past its time limit is stopped");
step("a program past its time limit is stopped");

// Several at once, each answered as its own.
const many = await Promise.all(Array.from({ length: 20 }, (_, i) => runOffThread("/bin/echo", [String(i)])));
assert.deepEqual(
	many.map((ran) => ran.stdout.trim()),
	Array.from({ length: 20 }, (_, i) => String(i)),
);
const viaCallback = await new Promise<string>((resolve) => execFileOffThread("/bin/echo", ["called back"], {}, (_error, stdout) => resolve(stdout)));
assert.equal(viaCallback, "called back\n");
step("many at once each get their own answer, and execFile's callback form works");
// Nothing else keeps this process alive: it ends here, so the worker does not hold it open once nothing is waiting.
