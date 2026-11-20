// Stops the type-check and the tests before they run against dependencies older than the checkout (#521), with the one
// line that says what to do about it. A program of its own, so that npm's scripts can put it in front of each command.

import { join } from "node:path";
import { installedState, STALE_MESSAGE } from "./installed.ts";

if (installedState(join(import.meta.dirname, "..")) !== "current") {
	console.error(STALE_MESSAGE);
	process.exit(1);
}
