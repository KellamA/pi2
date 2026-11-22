// AppCheck alone, without an engine (#740): how often it runs the app bundle's `pi2-peer` for one connection, and what
// it makes of a run that does not answer in time. A stand-in bundle's helper counts its runs in a file and writes down,
// each time, the bundle it was given and the inode of the connection it was handed as descriptor 3, so that the
// second ask can be seen to check the same connection and bundle as the first. engine/test/answers.ts checks the
// refusals through a real engine.

import assert from "node:assert/strict";
import { fstatSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { connect, createServer, type Socket } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { AppCheck } from "../src/answers.ts";
import { standInApp } from "./patience.ts";

function step(name: string): void {
	console.log(`ok  ${name}`);
}

const folder = mkdtempSync(join(tmpdir(), "pi2-appcheck-"));
process.on("exit", () => rmSync(folder, { recursive: true, force: true }));

// The helper's limit. A run that is to be slow sleeps far past it and is killed; one that answers does at once, and
// has all of this to do it in, so that a busy Mac does not turn an answer into a time-out.
const PATIENCE_MS = 3_000;

/** A stand-in bundle whose helper sleeps on the runs `slow` names (1 for its first) and otherwise answers `answer`. */
function helper(name: string, slow: number[], answer: { app: boolean; why: string }) {
	const runs = join(folder, `${name}.runs`);
	writeFileSync(runs, "");
	const bundle = standInApp(`#!/bin/sh
echo "$1 $(stat -L -f %i /dev/fd/3 2>/dev/null || stat -L -c %i /dev/fd/3)" >> '${runs}'
case " ${slow.join(" ")} " in *" $(wc -l < '${runs}' | tr -d ' ') "*) exec sleep 600 ;; esac
echo '${JSON.stringify(answer)}'
`);
	/** Each run so far: the bundle it was given, and the inode of the connection it was handed. */
	const asked = () => readFileSync(runs, "utf8").trim().split("\n").filter(Boolean).map((line) => line.split(" "));
	return { bundle, asked };
}

/** One connection to a socket of the test's own, as the engine sees it: the server's end, with its descriptor's inode. */
async function connection(): Promise<{ socket: Socket; inode: string; close: () => void }> {
	const path = join(folder, `s${Math.random().toString(36).slice(2, 8)}`);
	const server = createServer();
	await new Promise<void>((resolve) => server.listen(path, resolve));
	const client = connect(path);
	const [socket] = await Promise.all([new Promise<Socket>((resolve) => server.once("connection", resolve)), new Promise((resolve) => client.once("connect", resolve))]);
	const fd = (socket as unknown as { _handle: { fd: number } })._handle.fd;
	const inode = String(fstatSync(fd, { bigint: true }).ino);
	return { socket, inode, close: () => (client.destroy(), socket.destroy(), server.close()) };
}

const logged: string[] = [];
const log = (...parts: unknown[]) => logged.push(parts.join(" "));

// ---- Slow the first time: asked once more, and the app is known
{
	const { bundle, asked } = helper("first-slow", [1], { app: true, why: "the stand-in app" });
	const { socket, inode, close } = await connection();
	const check = new AppCheck(bundle, log, PATIENCE_MS);
	assert.deepEqual(await check.verdict(socket), { app: true, why: "the stand-in app" });
	assert.deepEqual(asked(), [[bundle, inode], [bundle, inode]], "asked twice, about the same connection and the same bundle");
	assert.ok(logged.some((line) => line.endsWith(`did not answer within ${PATIENCE_MS / 1000} seconds (asking once more)`)), logged.join("\n"));
	assert.deepEqual(await check.verdict(socket), { app: true, why: "the stand-in app" });
	assert.equal(asked().length, 2, "and the answer is kept for the connection's life");
	close();
	step("a helper that does not answer in time is asked once more, about the same connection, and its answer kept");
}

// ---- Slow both times: refused after exactly two runs, and nothing of them kept
{
	const { bundle, asked } = helper("always-slow", [1, 2], { app: true, why: "the stand-in app, at last" });
	const { socket, inode, close } = await connection();
	const check = new AppCheck(bundle, log, PATIENCE_MS);
	const refused = await check.verdict(socket);
	assert.equal(refused.app, false);
	assert.match(refused.why, new RegExp(`^the connection could not be checked: .*pi2-peer did not answer within ${PATIENCE_MS / 1000} seconds$`));
	assert.deepEqual(asked(), [[bundle, inode], [bundle, inode]], "refused after exactly two runs");
	// Had a third run been made, or a time-out kept, this would differ: the next ask is a run of its own, which answers.
	assert.deepEqual(await check.verdict(socket), { app: true, why: "the stand-in app, at last" });
	assert.equal(asked().length, 3, "the next request checks again");
	close();
	step("a helper that never answers in time is refused after two runs, and the connection is checked again next time");
}

// ---- A no: final, and not asked again
{
	const { bundle, asked } = helper("no", [], { app: false, why: "not the app" });
	const { socket, close } = await connection();
	const check = new AppCheck(bundle, log, PATIENCE_MS);
	const before = logged.length;
	assert.deepEqual(await check.verdict(socket), { app: false, why: "not the app" });
	assert.deepEqual(await check.verdict(socket), { app: false, why: "not the app" });
	assert.equal(asked().length, 1, "asked once, for the connection's life");
	assert.ok(!logged.slice(before).some((line) => line.includes("asking once more")));
	close();
	step("a helper that answers no is asked once, and the no is final");
}
