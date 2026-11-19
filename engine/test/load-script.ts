import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { once } from "node:events";
import { mkdtemp, rm } from "node:fs/promises";
import { createServer, type Socket } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { test, type TestContext } from "node:test";
import { fileURLToPath } from "node:url";

const script = fileURLToPath(new URL("../../scripts/load.mts", import.meta.url));

// Only the load script runs here. A stand-in socket drives fixture and fallback outcomes without starting an app or model.
async function run(t: TestContext, entries: number, fixture: number | "missing" | "unanswered") {
	const folder = await mkdtemp(join(tmpdir(), "pi2-load-test-"));
	const path = join(folder, "engine.sock");
	const archived: number[] = [];
	const turns: string[] = [];
	let nextConversation = 0;
	const sockets = new Set<Socket>();
	const server = createServer(socket => {
		sockets.add(socket);
		socket.once("close", () => sockets.delete(socket));
		const send = (message: object) => socket.write(`${JSON.stringify(message)}\n`);
		createInterface({ input: socket }).on("line", (line) => {
			const { id, method, params } = JSON.parse(line);
			const reply = (result: object = {}) => send({ id, result });
			switch (method) {
				case "conversation.create": return reply({ id: ++nextConversation });
				case "conversation.configure":
				case "conversation.open":
				case "conversation.close": return reply();
				case "conversation.archive":
					archived.push(params.id);
					return reply();
				case "test-copy.fill":
					return typeof fixture === "number"
						? reply({ id: ++nextConversation, entries: fixture })
						: send({ id, error: "Unknown method: test-copy.fill" });
				case "submit": {
					turns.push(params.text);
					if (fixture !== "unanswered") {
						// Simulate a coalesced watch with no busy state, and a reset that resends the previous answer.
						const first = (turns.length - 1) * 15;
						const start = first === 0 ? 1 : 0;
						const items = Array.from({ length: 16 - start }, (_, i) => ({ id: first + i + start }));
						send({ event: "conversation", id: params.id, reset: true, items, state: { busy: false } });
					}
					return reply({ submissionId: turns.length });
				}
				case "submission.get":
					return reply({ busy: false, submission: fixture === "unanswered"
						? { status: "unanswered", reason: "stand-in stopped" }
						: { status: "done", answer: params.submissionId * 15 } });
				default: return send({ id, error: `Unexpected method: ${method}` });
			}
		});
	});
	t.after(async () => {
		for (const socket of sockets) socket.destroy();
		await new Promise<void>(resolve => server.close(() => resolve()));
		await rm(folder, { recursive: true, force: true });
	});
	server.listen(path);
	await once(server, "listening");
	const { code, stdout, stderr } = await new Promise<{ code: unknown; stdout: string; stderr: string }>((resolve) => {
		execFile(process.execPath, [script, "--socket", path, "--large", String(entries), "--runs", "0", "--before", "0", "--seconds", "0"],
			{ env: { ...process.env, PI2_SCRATCH: folder }, timeout: 120_000 },
			(error, stdout, stderr) => resolve({ code: error ? error.code : 0, stdout, stderr }));
	});
	return { code, stdout, stderr, archived, turns };
}

for (const entries of [200, 600]) test(`load makes exactly ${entries} fixture entries without submitting demo work`, async t => {
	const runResult = await run(t, entries, entries);
	assert.equal(runResult.code, 0, runResult.stderr);
	assert.match(runResult.stdout, new RegExp(`Large conversation #2 has ${entries} entries\\.`));
	assert.deepEqual(runResult.turns, []);
	assert.deepEqual(runResult.archived, [1, 2]);
});

test("load falls back to short turns and counts each entry once", async t => {
	const result = await run(t, 42, "missing");
	assert.equal(result.code, 0, result.stderr);
	assert.match(result.stdout, /Large conversation #2 has 45 entries\./);
	assert.equal(result.turns.length, 3);
	assert.ok(result.turns.every(turn => /^\/work (?:[1-9]|10) /.test(turn)));
	assert.deepEqual(result.archived, [1, 2]);
});

test("load fails without measuring when the fixture count is wrong or fallback stops", async t => {
	for (const [fixture, reason] of [[199, /the fixture reported 199 entries, expected 200/], ["unanswered", /ended without an answer: stand-in stopped/]] as const) {
		const result = await run(t, 200, fixture);
		assert.equal(result.code, 1, result.stderr);
		assert.match(result.stderr, reason);
		assert.doesNotMatch(result.stdout, /Measuring for/);
		assert.deepEqual(result.archived, [1, 2]);
	}
});
