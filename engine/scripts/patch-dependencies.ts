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
	{
		// A model request that a provider refuses for its rate limit (HTTP 429) or because it is overloaded (529) is retried
		// three times, 2, 4 and 8 seconds apart, whatever the provider said about when to ask again, and the run then ends:
		// work handed to ten sub-chats at once stopped until someone typed "continue" in each. These two let the engine
		// decide the wait for such an answer itself (src/limitwait.ts): as long as the provider says, or a backoff with
		// jitter, for hours if need be. The wait stays pi-durable's own stored sleep, so it is shown as a retry, survives a
		// restart and ends with Stop. `policy.host` answers `{ waitMs, spent }`: `waitMs` a wait in milliseconds, `false`
		// to end the run now, or undefined to leave the error to the policy; `spent`, how many of the attempts were
		// refusals of that kind, which do not count against `maxRetries`. Issue #183.
		why: "a provider's rate limit ends a run after three quick retries",
		file: "node_modules/@earendil-works/pi-durable/dist/harness/generation.js",
		find: `    const policy = settings.retry;
    // An overflow is never retried: only a compaction can make the next request fit.
    const retry = message.stopReason === "error" &&
        !overflow &&
        isRetryableAssistantError(message) &&
        policy.enabled &&
        attempt <= policy.maxRetries;
    const until = retry ? runtime.now() + retryDelayMs(policy, attempt) : 0;`,
		replace: `    const policy = settings.retry;
    // Patched by pi2 (engine/scripts/patch-dependencies.ts): the host may decide the wait for an error itself, such as
    // a provider's rate limit, and the attempts it spent on such waits do not count against the retries.
    const host = typeof policy.host === "function" && policy.enabled
        ? policy.host(message.stopReason === "error" && !overflow ? message : undefined, attempt, conversationId)
        : undefined;
    const counted = Math.max(1, attempt - (host?.spent ?? 0));
    // An overflow is never retried: only a compaction can make the next request fit.
    const retry = host?.waitMs !== undefined
        ? host.waitMs !== false
        : message.stopReason === "error" &&
            !overflow &&
            isRetryableAssistantError(message) &&
            policy.enabled &&
            counted <= policy.maxRetries;
    const until = retry ? runtime.now() + (typeof host?.waitMs === "number" ? Math.max(0, host.waitMs) : retryDelayMs(policy, counted)) : 0;`,
	},
	{
		// The same for a request the engine stopped during: attempts spent waiting for a limit leave the usual retries for
		// a restart, as if there had been no wait. See the patch above.
		why: "a restart after waiting for a provider's rate limit ends the run",
		file: "node_modules/@earendil-works/pi-durable/dist/harness/generation.js",
		find: `    const policy = runtime.settings.retry;
    const retry = policy.enabled && attempt <= policy.maxRetries;
    const until = retry ? runtime.now() + retryDelayMs(policy, attempt) : 0;`,
		replace: `    const policy = runtime.settings.retry;
    // Patched by pi2 (engine/scripts/patch-dependencies.ts): attempts spent waiting for a provider's limit do not count.
    const spent = typeof policy.host === "function" && policy.enabled ? (policy.host(undefined, attempt, runtime.conversationId)?.spent ?? 0) : 0;
    const counted = Math.max(1, attempt - spent);
    const retry = policy.enabled && counted <= policy.maxRetries;
    const until = retry ? runtime.now() + retryDelayMs(policy, counted) : 0;`,
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
