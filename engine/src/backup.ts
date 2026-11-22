
// Backups: a folder holding a consistent copy of the database and the app's settings files. Keys and sign-ins live
// in the Keychain and are not part of a backup.

import { cpSync, existsSync, mkdirSync, readdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { basename, dirname, join } from "node:path";
import { backup, DatabaseSync } from "node:sqlite";
import { testSwitch } from "./testswitches.ts";

const SETTINGS_FILES = ["endpoints.json", "added-models.json", "mcp.json", "settings.json", "credentials.json"];
const DATABASE = "session.sqlite";

const stamp = (at = new Date()) =>
	`${at.getFullYear()}${String(at.getMonth() + 1).padStart(2, "0")}${String(at.getDate()).padStart(2, "0")}-${String(at.getHours()).padStart(2, "0")}${String(at.getMinutes()).padStart(2, "0")}${String(at.getSeconds()).padStart(2, "0")}`;

/** What marks a backup folder still being written: it is renamed without it once whole (#715). */
export const PARTIAL = ".partial";

/**
 * Inside a copy being written: who writes it, `{ pid, home }`, so that another engine (another data folder's, backing up
 * into the same folder) leaves it alone while that process lives (#792). Removed before the rename.
 */
export const OWNER = ".pi2-backup-owner";

/**
 * In the data folder: the copies this data folder's engines have started and not yet finished or removed, by the path
 * of their `.partial`, and the last backup that did not finish, for the Storage page (#792).
 */
export const RECORD = "backups.json";

/** The last backup that did not finish: where it was going, when it started, and why (null: the engine stopped). */
export type Unfinished = { folder: string; startedAt: number; reason: string | null };
type BackupRecord = { running: { [partial: string]: number }; unfinished: Unfinished | null };

/** The copies this engine is writing now, by the path of their `.partial`: never removed, whatever else says (#792). */
const writing = new Set<string>();

function readRecord(home: string): BackupRecord {
	try {
		const parsed = JSON.parse(readFileSync(join(home, RECORD), "utf8"));
		return { running: typeof parsed.running === "object" && parsed.running !== null ? parsed.running : {}, unfinished: parsed.unfinished ?? null };
	} catch {
		return { running: {}, unfinished: null };
	}
}

/** Read, changed and written in one synchronous step, so two backups of this engine never lose each other's entry. */
function changeRecord(home: string, change: (record: BackupRecord) => void): void {
	const record = readRecord(home);
	change(record);
	const file = join(home, RECORD);
	writeFileSync(`${file}.tmp`, JSON.stringify(record, null, "\t"));
	renameSync(`${file}.tmp`, file);
}

/** What the Storage page says of the last backup: whether it did not finish (#792). */
export function backupStatus(home: string): { unfinished: Unfinished | null } {
	return { unfinished: readRecord(home).unfinished };
}

/**
 * Tests hold a copy at a point, to stop the engine there as a crash would: while the file `PI2_BACKUP_GATE` names exists,
 * a copy waits once its folder is made, having written `<file>.started`. Only in a development engine (testswitches.ts).
 */
async function gate(): Promise<void> {
	const file = testSwitch("PI2_BACKUP_GATE");
	if (file === undefined || !existsSync(file)) return;
	writeFileSync(`${file}.started`, "");
	while (existsSync(file)) await new Promise((resolve) => setTimeout(resolve, 50));
}

/**
 * Write a backup into a new folder inside `directory` and return its path. Safe while the engine is running. The copy is
 * written under the folder's name with `.partial` after it and renamed once whole, so a copy that fails is removed and
 * one cut off by a crash is never taken for a backup: the next start removes it (`tidyBackups`), and so does the next
 * backup into the same folder (`removePartialBackups`).
 */
export async function createBackup(home: string, directory: string): Promise<string> {
	if (!existsSync(directory)) throw new Error(`Not a folder: ${directory}`);
	tidyRecorded(home);
	removePartialBackups(directory);
	const target = join(directory, `pi2-backup-${stamp()}`);
	if (existsSync(target)) throw new Error(`A backup of this second is already there: ${target}`);
	const partial = `${target}${PARTIAL}`;
	if (existsSync(partial)) throw new Error(`A backup of this second is already being made: ${partial}`);
	const startedAt = Date.now();
	changeRecord(home, (record) => void (record.running[partial] = startedAt));
	writing.add(partial);
	try {
		mkdirSync(partial);
		// At once after the folder, with nothing awaited between: another engine tidying this folder sees whose it is.
		writeFileSync(join(partial, OWNER), JSON.stringify({ pid: process.pid, home }));
		await gate();
		// SQLite's own online backup: a consistent snapshot even while the engine is writing.
		const source = new DatabaseSync(join(home, DATABASE), { readOnly: true });
		try {
			await backup(source, join(partial, DATABASE));
		} finally {
			source.close();
		}
		for (const name of SETTINGS_FILES) if (existsSync(join(home, name))) cpSync(join(home, name), join(partial, name));
		writeFileSync(join(partial, "manifest.json"), JSON.stringify({ app: "pi2", format: 1, createdAt: Date.now() }, null, "\t"));
		rmSync(join(partial, OWNER));
		renameSync(partial, target);
	} catch (error) {
		rmSync(partial, { recursive: true, force: true });
		writing.delete(partial);
		changeRecord(home, (record) => {
			delete record.running[partial];
			record.unfinished = { folder: directory, startedAt, reason: error instanceof Error ? error.message : String(error) };
		});
		throw error;
	}
	writing.delete(partial);
	changeRecord(home, (record) => {
		delete record.running[partial];
		record.unfinished = null;
	});
	return target;
}

/** Whether a process other than this one is `pid` and alive: EPERM is one of another user's, still there. */
function otherAlive(pid: unknown): boolean {
	if (typeof pid !== "number" || !Number.isInteger(pid) || pid <= 0 || pid === process.pid) return false;
	try {
		process.kill(pid, 0);
		return true;
	} catch (error) {
		return (error as NodeJS.ErrnoException).code === "EPERM";
	}
}

/** Whether a copy's writer may still be at work on it: this engine's own copies, or another live process's (#792). */
function live(partial: string): boolean {
	if (writing.has(partial)) return true;
	try {
		return otherAlive(JSON.parse(readFileSync(join(partial, OWNER), "utf8")).pid);
	} catch {
		// No owner file: an engine from before #792 made it, or the file was never written. No writer to wait for.
		return false;
	}
}

/**
 * Remove the copies a crash left unfinished in `directory`: the folders named `pi2-backup-….partial` that no live
 * writer has, and nothing else. A copy this engine is writing, or one whose owner file names another process that is
 * alive, stays; age is never the test (#792). Answers how many it removed.
 */
export function removePartialBackups(directory: string): number {
	if (!existsSync(directory) || !statSync(directory).isDirectory()) return 0;
	let removed = 0;
	for (const entry of readdirSync(directory, { withFileTypes: true })) {
		if (!entry.isDirectory() || !entry.name.startsWith("pi2-backup-") || !entry.name.endsWith(PARTIAL)) continue;
		const partial = join(directory, entry.name);
		if (live(partial)) continue;
		rmSync(partial, { recursive: true, force: true });
		removed++;
	}
	return removed;
}

/**
 * The copies this data folder's record says were started and that this engine is not writing: an engine before this
 * one stopped while making them. Each is removed where its folder can be reached, and kept on the record to try again
 * where it cannot (a disk not there now); the last backup is then one that did not finish, unless it was whole.
 * Answers the paths it removed.
 */
function tidyRecorded(home: string): string[] {
	const record = readRecord(home);
	const stale = Object.entries(record.running).filter(([partial]) => !writing.has(partial));
	if (stale.length === 0) return [];
	const removed: string[] = [];
	changeRecord(home, (current) => {
		for (const [partial, startedAt] of stale) {
			if (!(partial in current.running)) continue;
			const folder = dirname(partial);
			if (!basename(partial).startsWith("pi2-backup-") || !partial.endsWith(PARTIAL)) {
				delete current.running[partial];
				continue;
			}
			if (!existsSync(partial.slice(0, -PARTIAL.length)) && (current.unfinished === null || current.unfinished.startedAt <= startedAt)) {
				current.unfinished = { folder, startedAt, reason: null };
			}
			if (!existsSync(folder)) continue;
			if (existsSync(partial)) {
				rmSync(partial, { recursive: true, force: true });
				removed.push(partial);
			}
			delete current.running[partial];
		}
	});
	return removed;
}

/**
 * At the engine's start (#792): no backup is being written yet, and only one engine runs on a data folder, so every copy
 * its record names is left from an engine that stopped while making it. Removes them and says so in the log; the Storage
 * page then says the last backup did not finish. Never throws: start-up goes on whatever is there.
 */
export function tidyBackups(home: string, log: (...parts: unknown[]) => void): void {
	try {
		for (const partial of tidyRecorded(home)) log("backup: removed the unfinished copy", partial, "left by an engine that stopped while making it");
	} catch (error) {
		log("backup: could not tidy the unfinished copies:", error instanceof Error ? error.message : String(error));
	}
}

/**
 * Replace the data in `home` with a backup. Only for when no engine is running. What was there is moved into a
 * `before-restore-…` folder inside `home`, not deleted. Returns that folder's path.
 */
export function restoreBackup(home: string, from: string): string {
	// A copy cut off part way can already hold its manifest: the rename is its last step (#792).
	if (from.replace(/\/+$/, "").endsWith(PARTIAL) || existsSync(join(from, OWNER))) {
		throw new Error("That backup did not finish, so it cannot be restored. Choose a pi2-backup folder without “.partial” in its name.");
	}
	let manifest: { app?: string; format?: number };
	try {
		manifest = JSON.parse(readFileSync(join(from, "manifest.json"), "utf8"));
	} catch {
		throw new Error("That folder is not a pi2 backup");
	}
	if (manifest.app !== "pi2" || !existsSync(join(from, DATABASE))) throw new Error("That folder is not a pi2 backup");
	if (manifest.format !== 1) throw new Error("That backup was made by a newer version of pi2");
	const aside = join(home, `before-restore-${stamp()}`);
	mkdirSync(aside, { recursive: true });
	for (const name of [DATABASE, `${DATABASE}-wal`, `${DATABASE}-shm`, ...SETTINGS_FILES]) {
		if (existsSync(join(home, name))) renameSync(join(home, name), join(aside, name));
	}
	for (const name of [DATABASE, ...SETTINGS_FILES]) if (existsSync(join(from, name))) cpSync(join(from, name), join(home, name));
	return aside;
}
