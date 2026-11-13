// Fixes in installed dependencies that their own releases do not have yet. Run after every install: `npm ci` runs it
// as `postinstall`, and app/build.sh runs it on the engine it puts in a release bundle (installed with --ignore-scripts).
//
//   node scripts/patch-dependencies.ts [engine folder]
//
// Each patch replaces an exact piece of a file. A file that already has the replacement is left alone, so running it
// twice is harmless. If neither the original nor the replacement is there, the dependency changed: the script fails, so
// whoever updated it checks whether the fix is still needed, and then updates or removes the patch here.

import { readFileSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";

type Patch = { why: string; file: string; find: string; replace: string };

const PATCHES: Patch[] = [
	{
		// After a command exits, pi-durable waits 100 ms for more output and then closes the pipes. Each turn of the event
		// loop runs timers before it reads pipes, so when the engine is busy for longer than that (just after a restart,
		// say) the timer fires first and output already in the pipe is thrown away: the command succeeds with no output.
		// Waiting one setImmediate lets the poll phase read the pipe first; new output arms a new timer. Issue #13; reported as https://github.com/earendil-works/pi/issues/12157.
		why: "command output lost when the event loop is busy as a command exits",
		file: "node_modules/@earendil-works/pi-durable/dist/env/node.js",
		find: `            postExitTimer = setTimeout(() => {
                if (spillIsDraining())
                    armIdleTimer();
                else
                    finalize();
            }, EXIT_STDIO_GRACE_MS);`,
		replace: `            // Patched by pi2 (engine/scripts/patch-dependencies.ts): timers run before pipes are read, so let one poll
            // phase read output that arrived while the event loop was busy before deciding the streams are idle.
            const timer = setTimeout(() => {
                setImmediate(() => {
                    if (settled || postExitTimer !== timer)
                        return;
                    if (spillIsDraining())
                        armIdleTimer();
                    else
                        finalize();
                });
            }, EXIT_STDIO_GRACE_MS);
            postExitTimer = timer;`,
	},
];

const engine = resolve(process.argv[2] ?? join(import.meta.dirname, ".."));
let failed = false;
for (const patch of PATCHES) {
	const path = join(engine, patch.file);
	let text: string;
	try {
		text = readFileSync(path, "utf8");
	} catch {
		console.error(`patch-dependencies: ${patch.file} is missing; cannot fix: ${patch.why}`);
		failed = true;
		continue;
	}
	if (text.includes(patch.replace)) continue;
	const at = text.indexOf(patch.find);
	if (at === -1 || text.indexOf(patch.find, at + 1) !== -1) {
		console.error(`patch-dependencies: ${patch.file} changed; check whether this is still needed and update the patch: ${patch.why}`);
		failed = true;
		continue;
	}
	writeFileSync(path, text.slice(0, at) + patch.replace + text.slice(at + patch.find.length));
	console.log(`patch-dependencies: ${patch.file}: ${patch.why}`);
}
if (failed) process.exit(1);
