// The time at the start of each line of engine.log (src/log.ts): on a stand-in stream, and on a real engine's output.

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { stamp, timeLines } from "../src/log.ts";

function step(name: string): void {
	console.log(`ok  ${name}`);
}

// The form app.log has: Swift's `Date().formatted(.iso8601)`, in UTC to the second.
assert.equal(stamp(new Date(Date.UTC(2026, 10, 16, 18, 3, 12, 987))), "2026-11-16T18:03:12Z");
assert.equal(stamp(new Date(Date.UTC(2026, 0, 2, 3, 4, 5, 0))), "2026-01-02T03:04:05Z");
step("the time reads as app.log's does: ISO 8601, UTC, to the second");

// A stand-in for process.stderr: keeps what is written, and answers each write's callback.
function standIn() {
	const written: Buffer[] = [];
	const stream = {
		write(chunk: string | Uint8Array, encoding?: unknown, callback?: unknown): boolean {
			written.push(Buffer.from(chunk as Uint8Array));
			const done = typeof encoding === "function" ? encoding : callback;
			if (typeof done === "function") done();
			return true;
		},
	} as unknown as NodeJS.WriteStream;
	let clock = Date.UTC(2026, 10, 16, 18, 3, 12);
	timeLines(stream, () => new Date(clock));
	return { stream, text: () => Buffer.concat(written).toString("utf8"), tick: () => (clock += 1000) };
}

{
	const { stream, text, tick } = standIn();
	stream.write("one line\n");
	tick();
	stream.write("two\nlines at once\n");
	tick();
	stream.write("a line in ");
	tick();
	stream.write("pieces\n");
	stream.write("\n");
	stream.write("after an empty one\n");
	assert.equal(
		text(),
		[
			"2026-11-16T18:03:12Z one line",
			"2026-11-16T18:03:13Z two",
			"2026-11-16T18:03:13Z lines at once",
			"2026-11-16T18:03:14Z a line in pieces",
			"2026-11-16T18:03:15Z",
			"2026-11-16T18:03:15Z after an empty one",
			"",
		].join("\n"),
	);
	step("each line gets the time once, at its start: one written in pieces the time of its first, an empty one the time alone");
}

{
	const { stream, text } = standIn();
	const calls: string[] = [];
	stream.write(Buffer.from("bytes ü\nand "), () => calls.push("first"));
	// A character split between two writes stays whole.
	const split = Buffer.from("ü\n");
	stream.write(split.subarray(0, 1));
	stream.write(split.subarray(1), () => calls.push("second"));
	stream.write("68690a", "hex", () => calls.push("third"));
	stream.write("");
	assert.equal(text(), "2026-11-16T18:03:12Z bytes ü\n2026-11-16T18:03:12Z and ü\n2026-11-16T18:03:12Z hi\n");
	assert.deepEqual(calls, ["first", "second", "third"], "each write's callback is answered");
	step("bytes, text in another encoding and callbacks are passed on; a character split across writes is left whole");
}

{
	// Through console and Node's own warnings, as the engine has them.
	const script = [
		`import { timeLines } from ${JSON.stringify(join(import.meta.dirname, "..", "src", "log.ts"))};`,
		"timeLines(process.stdout); timeLines(process.stderr);",
		'console.log("out"); console.error("err\\nsecond"); process.emitWarning("careful");',
	].join("\n");
	const result = spawnSync(process.execPath, ["--input-type=module", "-e", script], { encoding: "utf8" });
	assert.equal(result.status, 0, result.stderr);
	const lines = (result.stdout + result.stderr).split("\n").filter((line) => line !== "");
	assert.ok(lines.length >= 4 && lines.every((line) => /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ /.test(line)), lines.join("\n"));
	assert.ok(lines.some((line) => line.endsWith(" out")) && lines.some((line) => line.endsWith(" second")) && lines.some((line) => line.includes("Warning: careful")), lines.join("\n"));
	step("console.log, console.error and Node's warnings all get the time");
}

{
	// `--restore` writes its output as it is: the app reads it, and shows its error to the person.
	const home = mkdtempSync(join(tmpdir(), "pi2-log-"));
	try {
		const result = spawnSync(process.execPath, [join(import.meta.dirname, "..", "src", "main.ts"), "--restore", join(home, "not-a-backup")], {
			encoding: "utf8",
			env: { ...process.env, PI2_HOME: home, PI2_KEYCHAIN_SERVICE: "dev.pi2.credentials.test-log", PI2_LOGIN_SHELL: "off" },
		});
		assert.notEqual(result.status, 0);
		assert.ok(result.stderr.trim() !== "" && !/^\d{4}-/.test(result.stderr), result.stderr);
	} finally {
		rmSync(home, { recursive: true, force: true });
	}
	step("--restore's output has no time on it");
}
console.log("PASS");
