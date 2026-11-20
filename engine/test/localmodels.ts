// Models on this Mac, the downloads (#292): the downloader against a stand-in server on 127.0.0.1 that serves small
// files in pieces, drops the connection, stalls, is busy, refuses, ignores a range and sends the wrong bytes; then a
// real engine given a catalog of its own (PI2_LOCAL_CATALOG) whose engine and packs that stand-in serves: licences
// asked for first, what fits, a checksum that does not match, pause, resume, an engine killed and started again in
// the middle of a download, cancelling, the disk check, configuring and removing. Nothing real is downloaded or run.

import assert from "node:assert/strict";
import { type ChildProcess, execFileSync, spawn } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { createServer, type ServerResponse } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { type DownloadError, download } from "../src/download.ts";
import type { Catalog, CatalogFile } from "../src/localcatalog.ts";
import { EngineClient, standInApp, stop, until } from "./patience.ts";
// The engine takes changes to what the person set only from its app's connection (#513): this test's connection stands
// for the app's, as the tests that answer for the person already do (#504).
process.env.PI2_APP_BUNDLE = standInApp();

/** Whether a process runs: one that has ended and waits only to be reaped (Z) runs nothing. */
const alive = (pid: number) => {
	try {
		return !execFileSync("/bin/ps", ["-o", "stat=", "-p", String(pid)], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim().startsWith("Z");
	} catch {
		return false;
	}
};

function step(name: string): void {
	console.log(`ok  ${name}`);
}

const temporary: string[] = [];
const KEYCHAIN_SERVICE = `dev.pi2.credentials.test-localmodels-${process.pid}`;
process.on("exit", () => {
	for (const folder of temporary) rmSync(folder, { recursive: true, force: true });
	for (let i = 0; i < 100; i++) {
		try {
			execFileSync("/usr/bin/security", ["delete-generic-password", "-s", KEYCHAIN_SERVICE], { stdio: "ignore" });
		} catch {
			break;
		}
	}
});
const folder = (prefix: string) => {
	const made = mkdtempSync(join(tmpdir(), prefix));
	temporary.push(made);
	return made;
};

// ---- The stand-in server

/**
 * How the stand-in serves a file. `fast`: at once. `slow`: 16 KB every 20 ms, so a download is under way for a while.
 * `drop`: part of it, then the connection is cut (once). `stall`: part of it, then nothing, with the connection open
 * (once). `busy`: HTTP 503 (twice). `refuse`: HTTP 403. `wrong`: other bytes of the same length. `whole`: the whole
 * file, whatever range was asked for. `long`: more bytes than the file has, with no length given.
 */
type Mode = "fast" | "slow" | "drop" | "stall" | "busy" | "refuse" | "wrong" | "whole" | "long";
const served = new Map<string, Buffer>();
const modes = new Map<string, Mode>();
const busyLeft = new Map<string, number>();
const requests: { path: string; start: number }[] = [];

function trickle(response: ServerResponse, bytes: Buffer): void {
	let at = 0;
	const next = () => {
		if (response.destroyed) return;
		if (at >= bytes.length) {
			response.end();
			return;
		}
		response.write(bytes.subarray(at, at + 16 * 1024));
		at += 16 * 1024;
		setTimeout(next, 20);
	};
	next();
}

const standIn = createServer((request, response) => {
	const path = request.url ?? "";
	const range = /^bytes=(\d+)-$/.exec(request.headers.range ?? "");
	const start = range === null ? 0 : Number(range[1]);
	requests.push({ path, start });
	const body = served.get(path);
	if (body === undefined) {
		response.writeHead(404, "Not Found").end("not here");
		return;
	}
	const mode = modes.get(path) ?? "fast";
	if (mode === "refuse") {
		response.writeHead(403, "Forbidden").end("no");
		return;
	}
	if (mode === "busy") {
		const left = (busyLeft.get(path) ?? 2) - 1;
		busyLeft.set(path, left);
		if (left <= 0) modes.set(path, "fast");
		response.writeHead(503, "Service Unavailable").end("busy");
		return;
	}
	if (mode === "long") {
		response.writeHead(200, { "content-type": "application/octet-stream" });
		response.end(Buffer.concat([body, Buffer.from("and some more")]));
		return;
	}
	const bytes = mode === "wrong" ? Buffer.from(body.map((byte) => byte ^ 0xff)) : body;
	if (mode === "whole" || start === 0) {
		response.writeHead(200, { "content-length": String(bytes.length) });
	} else {
		response.writeHead(206, { "content-length": String(bytes.length - start), "content-range": `bytes ${start}-${bytes.length - 1}/${bytes.length}` });
	}
	const rest = mode === "whole" ? bytes : bytes.subarray(start);
	if (mode === "drop" || mode === "stall") {
		modes.set(path, "fast");
		response.write(rest.subarray(0, Math.floor(rest.length / 3)));
		if (mode === "drop") setTimeout(() => response.destroy(), 50);
		return; // a stall: the connection stays open, and nothing more comes
	}
	if (mode === "slow") trickle(response, rest);
	else response.end(rest);
});
await new Promise<void>((resolve) => standIn.listen(0, "127.0.0.1", resolve));
const base = `http://127.0.0.1:${(standIn.address() as { port: number }).port}`;

function serve(path: string, body: Buffer, mode: Mode = "fast"): CatalogFile {
	served.set(path, body);
	modes.set(path, mode);
	return { url: `${base}${path}`, name: path.split("/").at(-1)!, size: body.length, sha256: createHash("sha256").update(body).digest("hex") };
}

// ---- The downloader on its own

const quick = (signal = new AbortController().signal, seen: DownloadError[] = []) => ({
	signal,
	stallMs: 1_500,
	retries: 4,
	retryMs: 10,
	progress: () => {},
	retrying: (error: DownloadError) => seen.push(error),
});

try {
	const work = folder("pi2-local-dl-");
	const body = randomBytes(600 * 1024);
	const sha = createHash("sha256").update(body).digest("hex");
	const fileFor = (mode: Mode) => serve(`/dl/${mode}.bin`, body, mode);
	const got = async (mode: Mode) => {
		const file = fileFor(mode);
		const dest = join(work, `${mode}.bin`);
		const seen: DownloadError[] = [];
		await download(file, dest, quick(undefined, seen));
		assert.equal(createHash("sha256").update(readFileSync(dest)).digest("hex"), sha);
		assert.equal(existsSync(`${dest}.part`), false);
		return { seen, asked: requests.filter((r) => r.path === `/dl/${mode}.bin`) };
	};

	let result = await got("fast");
	assert.deepEqual(result.asked.map((r) => r.start), [0]);
	step("a file is downloaded whole and checked, and only then has its name");

	result = await got("drop");
	assert.equal(result.seen[0]?.kind, "network");
	assert.match(result.seen[0]!.message, /^The connection to 127\.0\.0\.1:\d+ (dropped during the download|closed before the whole file arrived)\./);
	assert.equal(result.asked.length, 2);
	assert.ok(result.asked[1]!.start > 0, "the second request carries on where the first stopped");
	step("a dropped connection is tried again, carrying on from where it stopped");

	result = await got("stall");
	assert.equal(result.seen[0]?.kind, "stalled");
	assert.ok(result.asked[1]!.start > 0);
	step("a stalled connection is dropped and tried again from where it stopped");

	result = await got("busy");
	assert.deepEqual(result.seen.map((e) => e.kind), ["server", "server"]);
	assert.match(result.seen[0]!.message, /is having trouble \(HTTP 503 Service Unavailable\)/);
	step("a busy server is asked again");

	// A part already there from an earlier try, and a server that sends the whole file anyway.
	const whole = fileFor("whole");
	writeFileSync(join(work, "whole.bin.part"), body.subarray(0, 100 * 1024));
	await download(whole, join(work, "whole.bin"), quick());
	assert.equal(createHash("sha256").update(readFileSync(join(work, "whole.bin"))).digest("hex"), sha);
	step("a server that ignores the range is read from the start, and the file still matches");

	const failure = async (file: CatalogFile, dest: string, signal?: AbortSignal) => {
		const seen: DownloadError[] = [];
		const error = await download(file, dest, quick(signal, seen)).then(
			() => assert.fail("the download should have failed"),
			(e: DownloadError) => e,
		);
		return { error, seen };
	};
	let failed = await failure(fileFor("refuse"), join(work, "refuse.bin"));
	assert.equal(failed.error.kind, "refused");
	assert.equal(failed.seen.length, 0, "a refusal is not tried again");
	assert.match(failed.error.message, /^127\.0\.0\.1:\d+ refused the download \(HTTP 403 Forbidden\)\. The file may have moved or been withdrawn; a newer pi² may know where it is now\.$/);
	step("a refusal fails at once, in words a person understands");

	failed = await failure(fileFor("wrong"), join(work, "wrong.bin"));
	assert.equal(failed.error.kind, "mismatch");
	assert.match(failed.error.message, /is not the one pi² expected: its checksum does not match\. It was deleted, and nothing in it was run\./);
	assert.equal(existsSync(join(work, "wrong.bin")), false);
	assert.equal(existsSync(join(work, "wrong.bin.part")), false);
	step("the wrong bytes fail the checksum, and nothing of them is kept");

	failed = await failure(fileFor("long"), join(work, "long.bin"));
	assert.equal(failed.error.kind, "mismatch");
	assert.equal(existsSync(join(work, "long.bin.part")), false);
	step("more bytes than the file has fail as the wrong file");

	// A part with the wrong bytes in it, from before: the whole file fails its check, and is gone.
	const spoiled = fileFor("fast");
	writeFileSync(join(work, "spoiled.bin.part"), randomBytes(200 * 1024));
	failed = await failure(spoiled, join(work, "spoiled.bin"));
	assert.equal(failed.error.kind, "mismatch");
	assert.equal(existsSync(join(work, "spoiled.bin.part")), false);
	step("a spoiled part on disk is found out by the checksum and removed");

	failed = await failure({ ...spoiled, url: spoiled.url.replace("127.0.0.1", "localhost") }, join(work, "plain.bin"));
	assert.equal(failed.error.kind, "refused");
	assert.match(failed.error.message, /only over HTTPS/);
	step("only HTTPS is used, apart from the stand-in on 127.0.0.1");

	failed = await failure({ ...spoiled, url: `${base}/dl/nowhere.bin` }, join(work, "gone.bin"));
	assert.match(failed.error.message, /refused the download \(HTTP 404 Not Found\)/);
	const closed = createServer();
	await new Promise<void>((resolve) => closed.listen(0, "127.0.0.1", resolve));
	const port = (closed.address() as { port: number }).port;
	await new Promise<void>((resolve) => closed.close(() => resolve()));
	failed = await failure({ ...spoiled, url: `http://127.0.0.1:${port}/x` }, join(work, "offline.bin"));
	assert.equal(failed.error.kind, "network");
	assert.equal(failed.seen.length, 4, "no network is tried again before it gives up");
	assert.match(failed.error.message, /^pi² could not reach 127\.0\.0\.1:\d+\. Check the network connection; the download carries on from where it stopped\.$/);
	step("no network is tried again, then said plainly");

	// Paused in the middle: what it has is kept.
	const slow = serve("/dl/paused.bin", randomBytes(2 * 1024 * 1024), "slow");
	const pausing = new AbortController();
	const pausedDest = join(work, "paused.bin");
	const pausedRun = download(slow, pausedDest, { ...quick(pausing.signal), progress: (received) => received > 64 * 1024 && pausing.abort("paused") });
	const stopped = await pausedRun.then(() => assert.fail("it should have stopped"), (e: DownloadError) => e);
	assert.equal(stopped.kind, "stopped");
	assert.ok(statSync(`${pausedDest}.part`).size > 0, "the part is kept");
	modes.set("/dl/paused.bin", "fast");
	await download(slow, pausedDest, quick());
	assert.equal(requests.filter((r) => r.path === "/dl/paused.bin").at(-1)!.start > 0, true);
	assert.equal(createHash("sha256").update(readFileSync(pausedDest)).digest("hex"), slow.sha256);
	step("a paused download keeps its part and carries on from it");
} catch (error) {
	standIn.closeAllConnections();
	standIn.close();
	throw error;
}

// ---- A real engine, with a catalog of its own

// The engine: a small archive with an executable, stored without its execute bit. It is no server: trying the model
// starts it, and it ends at once.
const packaging = folder("pi2-local-pack-");
mkdirSync(join(packaging, "strata-test", "bin"), { recursive: true });
writeFileSync(join(packaging, "strata-test", "bin", "strata"), "#!/bin/sh\necho not a server\n");
chmodSync(join(packaging, "strata-test", "bin", "strata"), 0o644);
writeFileSync(join(packaging, "strata-test", "README"), "a stand-in engine\n");
execFileSync("/usr/bin/tar", ["-czf", join(packaging, "engine.tar.gz"), "-C", packaging, "strata-test"]);
const engineArchive = serve("/engine/strata-test.tar.gz", readFileSync(join(packaging, "engine.tar.gz")), "wrong");
// Its control package: a stand-in for its Python, which plays Strata's commands. `strata.py components install-file`
// installs the engine in Strata's component folder; `setup.py` prepares a pack as Strata's setup does (its steps, a
// pack folder and a run config in the control package's folder), noting its environment and arguments, and fails when
// the file STRATA_TEST_FAIL names is there, or waits while the one STRATA_TEST_HOLD names is; the server is no server.
const control = join(packaging, "control");
mkdirSync(join(control, "python", "bin"), { recursive: true });
mkdirSync(join(control, "serve"), { recursive: true });
for (const name of ["strata.py", "setup.py", join("serve", "server.py")]) writeFileSync(join(control, name), "# a stand-in: python/bin/python3 plays it\n");
writeFileSync(
	join(control, "python", "bin", "python3"),
	`#!/bin/sh
case "$(basename "$1")" in
strata.py)
  mkdir -p "$XDG_DATA_HOME/strata/components/engine/0.0.1-test" && echo "Engine 0.0.1-test is installed" ;;
setup.py)
  shift
  while [ $# -gt 0 ]; do case "$1" in --model) model=$2; shift ;; --gguf-dir) files=$2; shift ;; --data-dir) data=$2; shift ;; esac; shift; done
  env > "$data/setup.env"
  echo "$$" > "$data/setup.pid"
  echo "Strata on a Mac (Apple Silicon, Metal)"
  echo "=== Step 1: checking your Mac ==="
  while [ -n "$STRATA_TEST_HOLD" ] && [ -f "$STRATA_TEST_HOLD" ]; do sleep 0.05; done
  if [ -n "$STRATA_TEST_FAIL" ] && [ -f "$STRATA_TEST_FAIL" ]; then
    echo ""; echo "  [X]  the draft layer's download keeps stopping (exit 3)"; echo "       run setup again - what is downloaded is kept"
    echo ""; echo "Setup stopped. Fix the item above and run it again - everything already done is kept and skipped."; exit 1
  fi
  echo "=== Step 6: preparing the model for Strata ==="
  echo "  MTP draft layer:   2.60 / 5.21 GB (50%)" >&2
  mkdir -p "$data/packs/$model"
  lower=$(echo "$model" | tr A-Z a-z)
  printf '{"exe":"component:strata-engine","args":["--pack","%s","--native","%s","--max-context","65536","--vision"],"vision":{"mmproj":"x"}}' "$data/packs/$model" "$files" > "strata-$lower.json"
  echo "=== Step 7: writing the run settings ==="; echo "All set." ;;
*) echo "not a server" ;;
esac
`,
);
chmodSync(join(control, "python", "bin", "python3"), 0o755);
execFileSync("/usr/bin/tar", ["-czf", join(packaging, "control.tar.gz"), "-C", control, "."]);
const controlArchive = serve("/engine/strata-control-test.tar.gz", readFileSync(join(packaging, "control.tar.gz")));

const bigFiles = [serve("/packs/big-1.gguf", randomBytes(3 * 1024 * 1024)), serve("/packs/big-2.gguf", randomBytes(1024 * 1024)), serve("/packs/big-vision.gguf", randomBytes(64 * 1024))];
const smallFiles = [serve("/packs/small-1.gguf", randomBytes(8 * 1024 * 1024), "slow")];
const licence = { name: "Test Licence", url: "https://example.invalid/licence", summary: "For tests." };
const catalog: Catalog = {
	engine: { version: "0.0.1-test", archive: engineArchive, executable: "strata", control: { version: "0.0.2-test", archive: controlArchive }, licences: [licence] },
	models: [
		{
			id: "test-model",
			name: "Test Model",
			packs: [
				{ id: "test-big", pack: "BIG", provider: "Tests", note: "The better one.", needsGB: 63, recommendedFromGB: 96, files: bigFiles, visionFile: "big-vision.gguf", prepareBytes: 0, prepare: { family: "test", model: "BIG", config: "strata-big.json" }, licences: [licence] },
				{ id: "test-small", pack: "SMALL", provider: "Tests", note: "Too big for any Mac.", needsGB: 200, recommendedFromGB: 256, files: smallFiles, visionFile: null, prepareBytes: 0, prepare: { family: "test", model: "SMALL", config: "strata-small.json" }, licences: [licence] },
				{ id: "test-later", pack: "LATER", provider: "Tests", note: "Not yet.", needsGB: 10, recommendedFromGB: 16, files: [], visionFile: null, prepareBytes: 0, prepare: null, licences: [licence], unavailable: "Not offered yet, for a test." },
			],
		},
	],
	preference: ["test-big", "test-small"],
};
const home = folder("pi2-local-engine-");
const catalogFile = join(home, "..", `${home.split("/").at(-1)}-catalog.json`);
temporary.push(catalogFile);
writeFileSync(catalogFile, JSON.stringify(catalog));

const environment = Object.fromEntries(Object.entries(process.env).filter(([name]) => !/(API_KEY|TOKEN|SECRET)/.test(name)));
/** What the engines have logged. */
let logged = "";
// Files that tell the stand-in setup to fail, or to wait; there only while a test wants it.
const failSetup = join(home, "..", `${home.split("/").at(-1)}-fail`);
const holdSetup = join(home, "..", `${home.split("/").at(-1)}-hold`);
temporary.push(failSetup, holdSetup);
function startEngine(extra: Record<string, string> = {}): ChildProcess {
	const child = spawn(process.execPath, [join(import.meta.dirname, "..", "src", "main.ts")], {
		env: {
			...environment,
			PI2_HOME: home,
			PI2_KEYCHAIN_SERVICE: KEYCHAIN_SERVICE,
			PI2_LOGIN_SHELL: "off",
			PI2_LOCAL_CATALOG: catalogFile,
			PI2_LOCAL_MEMORY_GB: "128",
			PI2_LOCAL_RETRY_MS: "20",
			PI2_LOCAL_RETRIES: "3",
			PI2_LOCAL_STALL_MS: "5000",
			PI2_LOCAL_KEEP_FREE: "0",
			// A Python path of the person's own, which no Strata command may be given.
			PYTHONPATH: "/nowhere",
			STRATA_TEST_FAIL: failSetup,
			STRATA_TEST_HOLD: holdSetup,
			...extra,
		},
		stdio: ["ignore", "ignore", "pipe"],
	});
	child.stderr!.setEncoding("utf8").on("data", (chunk: string) => {
		logged += chunk;
		process.stderr.write(chunk);
	});
	return child;
}

type Download = { id: string; state: string; phase: string | null; error: string | null; received: number; total: number; stage: string; prepare: { step: number | null; stage: string | null; fraction: number | null } | null; log: string | null };
type Status = {
	platform: { supported: boolean; memoryGB: number };
	engine: { installed: { version: string; path: string; folder: string; control: { version: string; folder: string }; component?: boolean } | null; pinned: { version: string }; update: boolean };
	catalog: { packs: { id: string; fit: string; recommended: boolean; unavailable: string | null; installed: boolean; size: number }[] }[];
	models: { id: string; path: string; contextSize: number; config?: string; preparedWith?: string; options: { vision: boolean; visionFile: string | null; parallel: number } }[];
	downloads: Download[];
	folder: { path: string; isDefault: boolean };
};
class Client extends EngineClient {
	status: Status | undefined;
	progress: Download[] = [];
	override receive(message: any): void {
		if (message.event === "local") this.status = message;
		else if (message.event === "local.progress") this.progress.push(message.download);
		else super.receive(message);
	}
	download(id: string): Download | undefined {
		return this.status?.downloads.find((d) => d.id === id);
	}
}
const onDisk = (): { engine: Status["engine"]["installed"]; models: Status["models"] } => JSON.parse(readFileSync(join(home, "local-models.json"), "utf8"));
const excluded = (path: string) => execFileSync("/usr/bin/tmutil", ["isexcluded", path], { encoding: "utf8" }).startsWith("[Excluded]");

let engine = startEngine();
try {
	let client = await Client.connect(engine, home);
	let status = await client.until("the local status", () => client.status);
	if (!status.platform.supported) {
		// Strata runs on Apple silicon only; on any other Mac the rest cannot be tried.
		await assert.rejects(client.call("local.engine.install", { accept: true }), /Strata runs only on Macs with Apple silicon/);
		step("a Mac that cannot run Strata is told so, and nothing is downloaded");
		await stop(engine);
		standIn.close();
		process.exit(0);
	}
	const packs = Object.fromEntries(status.catalog[0]!.packs.map((p) => [p.id, p]));
	assert.deepEqual(
		{ big: [packs["test-big"]!.fit, packs["test-big"]!.recommended], small: [packs["test-small"]!.fit, packs["test-small"]!.recommended], later: packs["test-later"]!.unavailable },
		{ big: ["fits", true], small: ["streams", false], later: "Not offered yet, for a test." },
	);
	assert.equal(packs["test-big"]!.size, 3 * 1024 * 1024 + 1024 * 1024 + 64 * 1024);
	step("which packs fit 128 GB, which one is recommended, and which cannot be had yet");

	await assert.rejects(client.call("local.engine.install", {}), /Read Strata's licence first/);
	await assert.rejects(client.call("local.model.install", { pack: "test-big" }), /Read Test Model's licence first/);
	await assert.rejects(client.call("local.model.install", { pack: "test-later", accept: true }), /Not offered yet, for a test\./);
	assert.equal(requests.filter((r) => r.path.startsWith("/engine") || r.path.startsWith("/packs")).length, 0);
	await assert.rejects(client.call("local.engine.install", { accept: "yes" }), /Read Strata's licence first/);
	step("nothing is downloaded before its licence is agreed to");

	// The server sends the wrong bytes: the archive is deleted, and nothing is unpacked or made runnable.
	await client.call("local.engine.install", { accept: true });
	let failed = await client.until("the engine's download failed", () => client.download("engine")?.state === "failed" && client.download("engine"));
	assert.match(failed.error ?? "", /its checksum does not match\. It was deleted, and nothing in it was run\./);
	assert.equal(existsSync(join(home, "local", "engine")), false, "nothing was unpacked");
	assert.equal(existsSync(join(home, "local", "downloads", "strata-test.tar.gz")), false);
	assert.equal(existsSync(join(home, "local", "downloads", "strata-test.tar.gz.part")), false);
	assert.equal(onDiskOrNull(), null);
	step("an engine whose checksum does not match is deleted, not unpacked, and the person is told why");

	modes.set("/engine/strata-test.tar.gz", "drop");
	await client.call("local.download.resume", { id: "engine" });
	status = await client.until("the engine set up", () => client.status?.engine.installed !== null && client.status?.downloads.length === 0 && client.status);
	const executable = status.engine.installed!.path;
	assert.equal(executable, join(home, "local", "engine", "0.0.1-test", "strata-test", "bin", "strata"));
	assert.equal(statSync(executable).mode & 0o777, 0o755, "made runnable once checked");
	assert.deepEqual(onDisk().engine, {
		version: "0.0.1-test",
		path: executable,
		folder: join(home, "local", "engine", "0.0.1-test"),
		control: { version: "0.0.2-test", folder: join(home, "local", "control", "0.0.2-test") },
		component: true,
	});
	assert.ok(existsSync(join(home, "local", "control", "0.0.2-test", "serve", "server.py")), "the control package is unpacked whole");
	assert.ok(existsSync(join(home, "local", "strata", "data", "strata", "components", "engine", "0.0.1-test")), "the engine is installed where Strata's server finds it, in pi²'s folder for Strata");
	assert.equal(existsSync(join(home, "local", "downloads")), false, "the archives go once unpacked");
	assert.equal(excluded(join(home, "local")), true, "Time Machine skips the folder");
	assert.equal(status.engine.update, false);
	step("the engine is downloaded through a dropped connection, checked, unpacked and made runnable, outside backups");

	// A model, slowly: paused in the middle, resumed, then the engine is killed and started again.
	client.progress = [];
	await client.call("local.model.install", { pack: "test-small", accept: true });
	await client.until("some of it arrived", () => client.progress.some((p) => p.id === "test-small" && p.received > 128 * 1024));
	await client.call("local.download.pause", { id: "test-small" });
	let paused = client.download("test-small")!;
	assert.equal(paused.state, "paused");
	const part = join(home, "local", "models", "test-small", "small-1.gguf.part");
	const kept = statSync(part).size;
	assert.ok(kept > 0 && paused.received === kept, "what it has is kept, and said");
	step("a download in progress sends its progress, and pauses keeping what it has");

	await client.call("local.download.resume", { id: "test-small" });
	await client.until("more of it arrived", () => client.progress.some((p) => p.id === "test-small" && p.received > kept + 64 * 1024));
	const asked = requests.filter((r) => r.path === "/packs/small-1.gguf");
	assert.ok(asked.at(-1)!.start >= kept, "it carried on from the part");
	engine.kill("SIGKILL");
	await stop(engine);
	client.close();
	modes.set("/packs/small-1.gguf", "fast");
	// Once downloaded, Strata's setup prepares it, and waits here: the engine is killed while it does.
	writeFileSync(holdSetup, "");
	engine = startEngine();
	client = await Client.connect(engine, home);
	const preparing = await client.until("preparing it", () => client.download("test-small")?.prepare?.step === 1 && client.download("test-small"));
	assert.ok(requests.filter((r) => r.path === "/packs/small-1.gguf").at(-1)!.start > 0, "after the restart it carried on from the part");
	assert.deepEqual([preparing.stage, preparing.phase, preparing.prepare!.stage], ["prepare", "preparing", "checking your Mac"]);
	assert.equal(onDiskOrNull() !== null && onDisk().models.some((m) => m.id === "test-small"), false, "it is not offered before it is prepared");
	const prepared = join(home, "local", "models", "test-small", "prepared");
	const setupPid = Number(await until("the setup's pid", () => existsSync(join(prepared, "setup.pid")) && readFileSync(join(prepared, "setup.pid"), "utf8").trim()));
	await until("its process on record", () => JSON.parse(readFileSync(join(home, "local-setup.json"), "utf8")).downloads.some((d: { process?: unknown }) => d.process !== undefined));
	const ran = readFileSync(join(prepared, "setup.env"), "utf8").split("\n");
	for (const [name, value] of [
		["HOME", join(home, "local", "strata", "home")],
		["XDG_DATA_HOME", join(home, "local", "strata", "data")],
		["STRATA_HOME", join(home, "local", "strata", "strata")],
		["STRATA_CONTROL_INSTALL", "1"],
		["PYTHONNOUSERSITE", "1"],
	]) assert.ok(ran.includes(`${name}=${value}`), `Strata's setup runs with ${name}=${value}`);
	assert.equal(ran.some((line) => line.startsWith("PYTHONPATH=")), false, "and no Python path of the person's");
	engine.kill("SIGKILL");
	await stop(engine);
	client.close();
	assert.ok(alive(setupPid), "an engine killed outright leaves Strata's setup running for the moment");
	engine = startEngine();
	client = await Client.connect(engine, home);
	await until("the next engine stops the setup it left", () => !alive(setupPid));
	await until("and starts it again", () => existsSync(join(prepared, "setup.pid")) && Number(readFileSync(join(prepared, "setup.pid"), "utf8")) !== setupPid);
	assert.match(logged, /Strata's setup preparing test-small, left by the last engine, was stopped/);
	rmSync(holdSetup);
	status = await client.until("the model set up after the restart", () => client.status?.models.some((m) => m.id === "test-small") && client.status);
	const small = status.models.find((m) => m.id === "test-small")!;
	assert.deepEqual(onDisk().models.find((m) => m.id === "test-small"), {
		id: "test-small",
		name: "Test Model (SMALL)",
		pack: "SMALL",
		path: join(home, "local", "models", "test-small", "small-1.gguf"),
		contextSize: 65_536,
		options: { vision: false, visionFile: null, parallel: 1 },
		config: join(home, "local", "configs", "test-small.json"),
		preparedWith: "0.0.2-test",
	});
	assert.deepEqual(JSON.parse(readFileSync(small.config!, "utf8")).args.slice(0, 2), ["--pack", join(prepared, "packs", "SMALL")], "pi² keeps the run config Strata's setup wrote");
	const printed = readFileSync(join(home, "local", "logs", "test-small.prepare.log"), "utf8");
	assert.ok(printed.includes("MTP draft layer:   2.60 / 5.21 GB (50%)") && printed.includes("All set."), "what setup printed, on either stream, is in its log");
	assert.equal(createHash("sha256").update(readFileSync(small.path)).digest("hex"), smallFiles[0]!.sha256);
	assert.equal(excluded(join(home, "local", "models", "test-small")), true);
	step("a download carries on by itself after the engine is killed, is prepared by Strata's setup in pi²'s folders, also after the engine is killed while it does, and is listed once prepared");

	// Configuring.
	await client.call("local.model.configure", { id: "test-small", contextSize: 131_072, options: { parallel: 2 } });
	assert.deepEqual([onDisk().models[0]!.contextSize, onDisk().models[0]!.options.parallel], [131_072, 2]);
	await assert.rejects(client.call("local.model.configure", { id: "test-small", contextSize: 1000 }), /The context size must be one of/);
	await assert.rejects(client.call("local.model.configure", { id: "test-small", options: { vision: true } }), /This pack has no picture reader/);
	await assert.rejects(client.call("local.model.configure", { id: "test-small", options: { parallel: 9 } }), /from 1 to 4/);
	step("a model's context size and requests at once are set, and wrong values refused");

	// The test's engine is no server: it ends at once, and trying the model says so (the running part, #291, starts it).
	await assert.rejects(client.call("local.model.try", { id: "test-small" }), /could not be started on this Mac: Strata exited with code 0 before the model was loaded/);
	step("trying a model that cannot start says why");

	// A folder of the person's, and cancelling: what the download left goes.
	const chosen = folder("pi2-local-chosen-");
	await assert.rejects(client.call("local.model.folder", { path: join(chosen, "nope") }), /There is no folder at/);
	await client.call("local.model.folder", { path: chosen });
	modes.set("/packs/big-1.gguf", "slow");
	client.progress = [];
	await client.call("local.model.install", { pack: "test-big", accept: true });
	await client.until("some of the big pack arrived", () => client.progress.some((p) => p.id === "test-big" && p.received > 64 * 1024));
	assert.ok(existsSync(join(chosen, "test-big", "big-1.gguf.part")));
	await client.call("local.download.cancel", { id: "test-big" });
	assert.equal(existsSync(join(chosen, "test-big")), false, "the cancelled download's folder is gone");
	assert.equal(client.download("test-big"), undefined);
	step("a download goes to the folder chosen for models, and cancelling it removes what it left");

	// Back to pi²'s own folder, and the whole of the big pack, with its picture reader, from files of the person's own
	// where they match: a Strata data folder with the first file and a wrong second one, and the draft layer's tensors.
	await client.call("local.model.folder", { path: null });
	const mine = folder("pi2-local-mine-");
	mkdirSync(join(mine, "Strata-data", "models", "big"), { recursive: true });
	mkdirSync(join(mine, "Strata-data", "mtp", "tensors"), { recursive: true });
	writeFileSync(join(mine, "Strata-data", "models", "big", "big-1.gguf"), served.get("/packs/big-1.gguf")!);
	writeFileSync(join(mine, "Strata-data", "models", "big", "big-2.gguf"), randomBytes(1024 * 1024));
	writeFileSync(join(mine, "Strata-data", "mtp", "mtp-inventory.json"), "{}");
	writeFileSync(join(mine, "Strata-data", "mtp", "tensors", "mtp.fc.bin"), "tensor");
	await assert.rejects(client.call("local.model.install", { pack: "test-big", accept: true, from: join(mine, "Strata-data", "mtp") }), /None of the files of Test Model \(BIG\) is in .* by name and size/);
	modes.set("/packs/big-2.gguf", "stall");
	writeFileSync(failSetup, "");
	const firstAsked = requests.length;
	await client.call("local.model.install", { pack: "test-big", accept: true, from: mine });
	failed = await client.until("preparing it failed", () => client.download("test-big")?.state === "failed" && client.download("test-big"));
	assert.equal(failed.stage, "prepare");
	assert.match(
		failed.error ?? "",
		/^Test Model \(BIG\) could not be prepared\. Strata's setup stopped: the draft layer's download keeps stopping \(exit 3\) run setup again - what is downloaded is kept\. What it printed is in .*test-big\.prepare\.log\. Press Try Again: what was done is kept\.$/,
	);
	assert.equal(onDisk().models.some((m) => m.id === "test-big"), false, "a model that could not be prepared is not offered");
	const since = requests.slice(firstAsked).map((r) => r.path);
	assert.equal(since.includes("/packs/big-1.gguf"), false, "the person's own file that matched is not downloaded");
	assert.ok(since.includes("/packs/big-2.gguf") && since.includes("/packs/big-vision.gguf"), "one that does not match, or is not there, is");
	assert.equal(readFileSync(join(home, "local", "models", "test-big", "prepared", "mtp", "tensors", "mtp.fc.bin"), "utf8"), "tensor", "the draft layer's tensors are taken for Strata's setup to check");
	assert.ok(existsSync(join(mine, "Strata-data", "models", "big", "big-1.gguf")) && existsSync(join(mine, "Strata-data", "mtp", "tensors", "mtp.fc.bin")), "the person's files stay where they were");
	rmSync(failSetup);
	await client.call("local.download.resume", { id: "test-big" });
	status = await client.until("the big pack set up", () => client.status?.models.some((m) => m.id === "test-big") && client.status);
	const big = status.models.find((m) => m.id === "test-big")!;
	assert.deepEqual(big.options, { vision: true, visionFile: join(home, "local", "models", "test-big", "big-vision.gguf"), parallel: 1 });
	assert.equal(status.catalog[0]!.packs.find((p) => p.id === "test-big")!.installed, true);
	for (const file of bigFiles) assert.equal(createHash("sha256").update(readFileSync(join(home, "local", "models", "test-big", file.name))).digest("hex"), file.sha256);
	step("files of the person's own are used where they match and downloaded where not, through a stalled connection; a preparation that fails says why, and Try Again carries on");

	await client.call("local.model.remove", { id: "test-big" });
	assert.equal(existsSync(join(home, "local", "models", "test-big")), false);
	assert.equal(existsSync(join(home, "local", "configs", "test-big.json")), false);
	assert.equal(onDisk().models.some((m) => m.id === "test-big"), false);
	step("removing a model removes its files, what preparing it made, and its entry");

	// No space: a disk that cannot hold the download and the room pi² keeps is refused before anything is asked.
	client.close();
	await stop(engine);
	engine = startEngine({ PI2_LOCAL_KEEP_FREE: String(1e18) });
	client = await Client.connect(engine, home);
	await client.until("the local status", () => client.status);
	const before = requests.length;
	await assert.rejects(
		client.call("local.model.install", { pack: "test-big", accept: true }),
		/Not enough free disk space: this needs 4\.3 MB more and pi² leaves 1000000000 GB free for the Mac, but the disk has [\d.]+ GB free\. Free up some space or choose another folder for models, then try again\.$/,
	);
	assert.equal(requests.length, before, "nothing was asked of the server");
	assert.equal(client.status?.downloads.length, 0);
	step("a download the disk has no room for is refused first, in plain words");

	await client.call("local.engine.remove");
	assert.equal(existsSync(join(home, "local", "engine")), false);
	assert.equal(existsSync(join(home, "local", "control")), false);
	assert.equal(existsSync(join(home, "local", "strata")), false);
	assert.equal(onDisk().engine, null);
	step("removing the engine removes it");
	client.close();

	// A pack downloaded while there is no engine waits for it, and is prepared once it is set up.
	await stop(engine);
	engine = startEngine();
	client = await Client.connect(engine, home);
	await client.until("the local status", () => client.status);
	await client.call("local.model.install", { pack: "test-big", accept: true });
	const waiting = await client.until("downloaded, waiting for the engine", () => client.download("test-big")?.state === "waiting" && client.download("test-big"));
	assert.equal(waiting.error, "Downloaded and checked. Preparing it for Strata needs the engine: get Strata above, and preparing starts by itself.");
	assert.equal(onDisk().models.some((m) => m.id === "test-big"), false);
	modes.set("/engine/strata-test.tar.gz", "fast");
	await client.call("local.engine.install", { accept: true });
	await client.until("prepared once the engine is set up", () => client.status?.models.some((m) => m.id === "test-big"));
	step("a pack downloaded before the engine waits for it, and is prepared once it is set up");
	client.close();
} finally {
	await stop(engine);
	standIn.closeAllConnections();
	standIn.close();
}

function onDiskOrNull(): unknown {
	return existsSync(join(home, "local-models.json")) ? onDisk().engine : null;
}
