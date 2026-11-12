// Backups: a folder holding a consistent copy of the database and the app's settings files. Keys and sign-ins live
// in the Keychain and are not part of a backup.

import { cpSync, existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { backup, DatabaseSync } from "node:sqlite";

const SETTINGS_FILES = ["endpoints.json", "mcp.json", "settings.json", "credentials.json"];
const DATABASE = "session.sqlite";

const stamp = (at = new Date()) =>
	`${at.getFullYear()}${String(at.getMonth() + 1).padStart(2, "0")}${String(at.getDate()).padStart(2, "0")}-${String(at.getHours()).padStart(2, "0")}${String(at.getMinutes()).padStart(2, "0")}${String(at.getSeconds()).padStart(2, "0")}`;

/** Write a backup into a new folder inside `directory` and return its path. Safe while the engine is running. */
export async function createBackup(home: string, directory: string): Promise<string> {
	if (!existsSync(directory)) throw new Error(`Not a folder: ${directory}`);
	const target = join(directory, `pi2-backup-${stamp()}`);
	mkdirSync(target);
	// SQLite's own online backup: a consistent snapshot even while the engine is writing.
	const source = new DatabaseSync(join(home, DATABASE), { readOnly: true });
	try {
		await backup(source, join(target, DATABASE));
	} finally {
		source.close();
	}
	for (const name of SETTINGS_FILES) if (existsSync(join(home, name))) cpSync(join(home, name), join(target, name));
	writeFileSync(join(target, "manifest.json"), JSON.stringify({ app: "pi2", format: 1, createdAt: Date.now() }, null, "\t"));
	return target;
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
