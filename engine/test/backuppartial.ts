// A backup cut off part way (#792): its `.partial` is removed at the next start and before the next backup into the same
// folder, never while something is writing it, and never restored from; the Storage page is told it did not finish.
//
// Real engines on a throwaway data folder and Keychain service, the stand-in app (a backup is the person's to ask for,
// #504), and the gate that holds a copy once its folder is made (`PI2_BACKUP_GATE`). In the chosen folder beforehand:
// a `.partial` whose owner file names this test's own process (alive, another data folder's: kept), one whose owner has
// ended and one with no owner file (removed before the next backup there), and a folder of the person's own without the
// mark (kept). Then: a backup held at the gate and the engine killed there; the next start removes that copy at once,
// says the last backup did not finish and lists nothing; a copy with its manifest but cut off is refused by restore;
// two backups into the same folder at once, the second started while the first is held, each leaving the other's copy
// alone; both whole, and the page's line gone.

import assert from "node:assert/strict";
import { type ChildProcess, execFileSync, spawn, spawnSync } from "node:child_process";
import { closeSync, existsSync, mkdirSync, mkdtempSync, openSync, readdirSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { OWNER, RECORD, restoreBackup } from "../src/backup.ts";
import { EngineClient, standInApp, stop, until } from "./patience.ts";

const main = join(import.meta.dirname, "..", "src", "main.ts");
const work = realpathSync(mkdtempSync(join(tmpdir(), "pi2-backup-partial-")));
const home = join(work, "home");
const chosen = join(work, "chosen");
mkdirSync(home);
mkdirSync(chosen);
const gate = join(work, "backup-gate");
const service = `dev.pi2.credentials.test-backup-partial-${process.pid}`;
const app = standInApp();
const engines: ChildProcess[] = [];
process.on("exit", () => {
	for (const engine of engines) if (engine.exitCode === null && engine.signalCode === null) engine.kill("SIGKILL");
	rmSync(work, { recursive: true, force: true });
	try {
		while (true) execFileSync("/usr/bin/security", ["delete-generic-password", "-s", service], { stdio: "ignore" });
	} catch {
		// None left.
	}
});

function step(name: string): void {
	console.log(`ok  ${name}`);
}

function start(): ChildProcess {
	const log = openSync(join(home, "engine.log"), "a");
	const engine = spawn(process.execPath, [main], {
		env: { ...process.env, PI2_HOME: home, PI2_KEYCHAIN_SERVICE: service, PI2_LOGIN_SHELL: "off", PI2_CARRY_NEVER: "1", PI2_APP_BUNDLE: app, PI2_BACKUP_GATE: gate },
		stdio: ["ignore", log, log],
	});
	closeSync(log);
	engines.push(engine);
	return engine;
}

const partials = () => readdirSync(chosen).filter((name) => name.endsWith(".partial")).sort();
/** The folders in `chosen` a restore would take: whole backups, with their manifest. */
const listed = () => readdirSync(chosen).filter((name) => !name.endsWith(".partial") && existsSync(join(chosen, name, "manifest.json"))).sort();
const held = () => until("the backup held at the gate", () => existsSync(`${gate}.started`));

// ---- The chosen folder beforehand

const othersLive = "pi2-backup-20000101-000000.partial";
const ownerGone = "pi2-backup-20000101-000001.partial";
const noOwner = "pi2-backup-20000101-000002.partial";
const theirs = "pi2-backup-kept-by-hand";
const ended = spawnSync(process.execPath, ["-e", ""]).pid!;
for (const [name, owner] of [[othersLive, { pid: process.pid, home: join(work, "another") }], [ownerGone, { pid: ended, home: join(work, "another") }], [noOwner, null]] as const) {
	mkdirSync(join(chosen, name));
	writeFileSync(join(chosen, name, "session.sqlite"), "");
	if (owner !== null) writeFileSync(join(chosen, name, OWNER), JSON.stringify(owner));
}
mkdirSync(join(chosen, theirs));

// ---- A backup killed part way

writeFileSync(gate, "");
let engine = start();
let client = await EngineClient.connect(engine, home);
assert.deepEqual((await client.call("engine.info")).backup, { unfinished: null }, "nothing to say on a new data folder");
const killed = client.call("backup.create", { directory: chosen });
killed.catch(() => {});
await held();
const cut = partials().filter((name) => ![othersLive, ownerGone, noOwner].includes(name));
assert.equal(cut.length, 1, "the copy being made, marked .partial");
assert.deepEqual(JSON.parse(readFileSync(join(chosen, cut[0]!, OWNER), "utf8")), { pid: engine.pid, home }, "with its owner inside");
assert.deepEqual(partials(), [cut[0]!, othersLive].sort(), "the partials with no live writer removed before it began");
assert.deepEqual(Object.keys(JSON.parse(readFileSync(join(home, RECORD), "utf8")).running), [join(chosen, cut[0]!)], "and on the data folder's record");
engine.kill("SIGKILL");
await stop(engine);
client.close();
rmSync(gate);
rmSync(`${gate}.started`);
assert.ok(existsSync(join(chosen, cut[0]!)), "left behind by the kill");
step("a backup into a chosen folder, killed part way, leaves its .partial with its owner, on the record");

// ---- The next start removes it, and says the last backup did not finish

engine = start();
client = await EngineClient.connect(engine, home);
assert.ok(!existsSync(join(chosen, cut[0]!)), "removed as the engine started");
assert.ok(readFileSync(join(home, "engine.log"), "utf8").includes(`backup: removed the unfinished copy ${join(chosen, cut[0]!)}`), "and said in the log");
assert.ok(existsSync(join(chosen, othersLive)), "another live process's copy stays");
assert.ok(existsSync(join(chosen, theirs)), "a folder without the mark stays");
assert.deepEqual(listed(), [], "no backup to offer");
const status = (await client.call("engine.info")).backup;
assert.equal(status.unfinished.folder, chosen);
assert.equal(status.unfinished.reason, null, "the engine stopped while making it");
assert.equal(typeof status.unfinished.startedAt, "number");
assert.deepEqual(JSON.parse(readFileSync(join(home, RECORD), "utf8")).running, {}, "nothing left on the record");
step("the next start removes it, lists no backup, and the Storage page is told the last backup did not finish");

// ---- A copy cut off after its manifest is never restored

{
	const fake = join(work, "pi2-backup-20000101-000003.partial");
	mkdirSync(fake);
	writeFileSync(join(fake, "session.sqlite"), "");
	writeFileSync(join(fake, "manifest.json"), JSON.stringify({ app: "pi2", format: 1, createdAt: 0 }));
	const elsewhere = join(work, "restore-home");
	mkdirSync(elsewhere);
	assert.throws(() => restoreBackup(elsewhere, fake), /did not finish/);
	const renamed = join(work, "renamed-by-hand");
	mkdirSync(renamed);
	for (const name of ["session.sqlite", "manifest.json"]) writeFileSync(join(renamed, name), readFileSync(join(fake, name)));
	writeFileSync(join(renamed, OWNER), JSON.stringify({ pid: 1, home }));
	assert.throws(() => restoreBackup(elsewhere, renamed), /did not finish/, "nor one renamed with its owner file still inside");
	assert.deepEqual(readdirSync(elsewhere), [], "and nothing moved");
}
step("a copy cut off after its manifest is refused by restore, by its name or its owner file");

// ---- Two backups into the same folder at once: neither removes the other's copy

writeFileSync(gate, "");
const first = client.call("backup.create", { directory: chosen });
await held();
const firstPartial = partials().find((name) => name !== othersLive)!;
assert.deepEqual(partials(), [firstPartial, othersLive].sort());
rmSync(`${gate}.started`);
// A second of its own, so that its folder has a name of its own.
await until("the next second", () => partialName() !== firstPartial);
const second = client.call("backup.create", { directory: chosen });
await held();
assert.equal(partials().length, 3, "the first's copy left alone by the second's tidying, beside its own");
assert.ok(existsSync(join(chosen, firstPartial)));
rmSync(gate);
const made = [(await first).path, (await second).path];
for (const path of made) {
	assert.ok(existsSync(join(path, "manifest.json")) && existsSync(join(path, "session.sqlite")), `${path} whole`);
	assert.ok(!existsSync(join(path, OWNER)), "with no owner file left in it");
}
assert.deepEqual(listed(), made.map((path) => path.slice(chosen.length + 1)).sort(), "both backups there");
assert.deepEqual(partials(), [othersLive], "and no copy of this engine's left");
assert.deepEqual((await client.call("engine.info")).backup, { unfinished: null }, "the page's line gone once a backup is whole");
client.close();
await stop(engine);
step("two backups into one folder at once each leave the other's copy alone, and both finish");

/** The name a backup started now would have, as backup.ts stamps it. */
function partialName(): string {
	const at = new Date();
	const two = (value: number) => String(value).padStart(2, "0");
	return `pi2-backup-${at.getFullYear()}${two(at.getMonth() + 1)}${two(at.getDate())}-${two(at.getHours())}${two(at.getMinutes())}${two(at.getSeconds())}.partial`;
}
