// Backups: a folder holding a consistent copy of the database and the app's settings files. Keys and sign-ins live
// in the Keychain and are not part of a backup.

import { cpSync, existsSync, mkdirSync, readdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { backup, DatabaseSync } from "node:sqlite";

const SETTINGS_FILES = ["endpoints.json", "added-models.json", "mcp.json", "settings.json", "credentials.json"];
const DATABASE = "session.sqlite";

const stamp = (at = new Date()) =>
	`${at.getFullYear()}${String(at.getMonth() + 1).padStart(2, "0")}${String(at.getDate()).padStart(2, "0")}-${String(at.getHours()).padStart(2, "0")}${String(at.getMinutes()).padStart(2, "0")}${String(at.getSeconds()).padStart(2, "0")}`;

/** What marks a backup folder still being written: it is renamed without it once whole (#715). */
export const PARTIAL = ".partial";

/**
 * Tests hold a copy at a point, to stop the engine there as a crash would: while the file `PI2_BACKUP_GATE` names exists,
 * a copy waits once its folder is made, having written `<file>.started`.
 */
async function gate(): Promise<void> {
	const file = process.env.PI2_BACKUP_GATE;
	if (file === undefined || !existsSync(file)) return;
	writeFileSync(`${file}.started`, "");
	while (existsSync(file)) await new Promise((resolve) => setTimeout(resolve, 50));
}

/**
 * Write a backup into a new folder inside `directory` and return its path. Safe while the engine is running. The copy is
 * written under the folder's name with `.partial` after it and renamed once whole, so a copy that fails is removed and
 * one cut off by a crash is never taken for a backup (`removePartialBackups` clears it later).
 */
export async function createBackup(home: string, directory: string): Promise<string> {
	if (!existsSync(directory)) throw new Error(`Not a folder: ${directory}`);
	const target = join(directory, `pi2-backup-${stamp()}`);
	if (existsSync(target)) throw new Error(`A backup of this second is already there: ${target}`);
	const partial = `${target}${PARTIAL}`;
	mkdirSync(partial);
	try {
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
		renameSync(partial, target);
	} catch (error) {
		rmSync(partial, { recursive: true, force: true });
		throw error;
	}
	return target;
}

/**
 * Remove the copies a crash left unfinished in `directory`: the folders named `pi2-backup-….partial`, and nothing else.
 * Answers how many it removed.
 */
export function removePartialBackups(directory: string): number {
	if (!existsSync(directory) || !statSync(directory).isDirectory()) return 0;
	let removed = 0;
	for (const entry of readdirSync(directory, { withFileTypes: true })) {
		if (!entry.isDirectory() || !entry.name.startsWith("pi2-backup-") || !entry.name.endsWith(PARTIAL)) continue;
		rmSync(join(directory, entry.name), { recursive: true, force: true });
		removed++;
	}
	return removed;
}

/**
 * Replace the data in `home` with a backup. Only for when no engine is running. What was there is moved into a
 * `before-restore-…` folder inside `home`, not deleted. Returns that folder's path.
 */
export function restoreBackup(home: string, from: string): string {
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
