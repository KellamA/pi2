// What the patches in a checkout were applied to (#521). `npm ci` records a hash of them in node_modules, and the
// type-check and the tests compare it before they run. A worktree that merged `main` without installing again has its
// dependencies patched the old way, and would otherwise fail in ways that say nothing about the change being tested.
//
// Nothing under src may import this: the engine, and a release, never compare it.

import { createHash } from "node:crypto";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";

/** What to tell whoever runs a check against dependencies older than the checkout. */
export const STALE_MESSAGE = "The installed dependencies are older than this checkout: run `npm --prefix engine ci`.";

const STAMP = join("node_modules", ".pi2-installed.json");

/**
 * The names of the patches, which are what decide how the dependencies are patched. A release bundle's engine folder
 * has no scripts folder, since app/build.sh copies only src and runs this checkout's patch-dependencies.ts against it.
 */
function patchNames(engineDir: string): string[] {
	try {
		return readdirSync(join(engineDir, "scripts")).filter((name) => name.startsWith("patch-") && name.endsWith(".ts"));
	} catch {
		return [];
	}
}

/** A hash of everything that decides how the dependencies are patched: the patches by name, then the lock file. */
export function installHash(engineDir: string): string {
	const hash = createHash("sha256");
	for (const name of patchNames(engineDir).sort()) {
		// A separator, so that the end of one patch cannot be read as the beginning of the next.
		hash.update(readFileSync(join(engineDir, "scripts", name))).update("\0");
	}
	hash.update(readFileSync(join(engineDir, "package-lock.json")));
	return hash.digest("hex");
}

/** Whether the dependencies installed in `engineDir` are patched as this checkout says. */
export function installedState(engineDir: string): "current" | "stale" | "missing" {
	if (!existsSync(join(engineDir, "node_modules"))) return "missing";
	let stamped: unknown;
	try {
		stamped = (JSON.parse(readFileSync(join(engineDir, STAMP), "utf8")) as { hash?: unknown }).hash;
	} catch {
		// No stamp, or one that cannot be read: a tree installed before there was a stamp, or half written.
		return "missing";
	}
	return stamped === installHash(engineDir) ? "current" : "stale";
}
