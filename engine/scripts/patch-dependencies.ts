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
import { COMPACTION_PATCHES } from "./patch-compaction.ts";

type Patch = { why: string; file: string; find: string; replace: string };

const PATCHES: Patch[] = [
	...COMPACTION_PATCHES,
	{
		why: "tool declarations cannot depend on the conversation (#431)",
		file: "node_modules/@earendil-works/pi-durable/dist/harness/harness.js",
		find: `        return resolveAgent(state, registry, resolveSettings(this.#hostSettings()), (error, extension) => this.#report(error, { kind: "extension_error", conversationId: id, extension }, context));`,
		replace: `        const agent = resolveAgent(state, registry, resolveSettings(this.#hostSettings()), (error, extension) => this.#report(error, { kind: "extension_error", conversationId: id, extension }, context));
        // Patched by pi2: the host can choose declarations for this conversation after resolving names and wraps.
        return this.#options.conversationAgent === undefined ? agent : this.#options.conversationAgent(agent, id, this, context);`,
	},
	{
		why: "type the conversation agent option",
		file: "node_modules/@earendil-works/pi-durable/dist/harness/types.d.ts",
		find: `    readonly registry: RegistryReader<Tool>;
    /** Run settings,`,
		replace: `    readonly registry: RegistryReader<Tool>;
    /** Patched by pi2: choose tool declarations for a conversation, after its agent has been resolved. */
    readonly conversationAgent?: (agent: Agent<Tool>, id: ConversationId, read: DocumentReader, context: Context) => Agent<Tool> | Promise<Agent<Tool>>;
    /** Run settings,`,
	},
	{
		// Commands moved to the background at their time limit must inherit the run's file from their very start (#300).
		// Keep exec's own stdin/stdout/stderr, output handling and cancellation; append only caller-owned descriptors 3+.
		why: "foreground commands cannot inherit their run's file",
		file: "node_modules/@earendil-works/pi-durable/dist/env/node.js",
		find: `                    stdio: [stdinCommand === undefined ? "ignore" : "pipe", "pipe", "pipe"],`,
		replace: `                    // Patched by pi2: extra descriptors carry the run's file, without changing exec's three streams.
                    stdio: [stdinCommand === undefined ? "ignore" : "pipe", "pipe", "pipe", ...(options?.extraStdio ?? [])],`,
	},
	{
		why: "type the Node exec option for inherited run descriptors",
		file: "node_modules/@earendil-works/pi-durable/dist/env/index.d.ts",
		find: `export interface ShellExecOptions {
    cwd?: string;`,
		replace: `export interface ShellExecOptions {
    /** Patched by pi2: local Node exec only; inherited descriptors starting at fd 3. */
    extraStdio?: readonly ("ignore" | "pipe" | number)[];
    cwd?: string;`,
	},
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
	{
		// Keep the same task (and its submissions and owner) when the person changes model during a limit wait. Move
		// its sleep deadline in the same commit as the new model. The retry phase places queued steers as usual, then
		// prepares a fresh first attempt, without carrying over the old model's compaction or retry count. Issue #358.
		why: "a person cannot end a generation's retry sleep without stopping the run",
		file: "node_modules/@earendil-works/pi-durable/dist/session/transaction.js",
		find: `    /** Internal: replace one task record completely. Tasks change their own state through their runtime. */`,
		replace: `    /** Patched by pi2: expedite a generation retry read in this transaction, if it is still sleeping. */
    carryOnGeneration(task, now) {
        if (task.kind !== "pi.generation" || task.abortRequested || task.state.status !== "sleeping" ||
            task.state.until <= now || task.state.checkpoint.phase !== "retry" || task.state.checkpoint.poll !== undefined)
            return false;
        this.setTask({ ...task, state: { status: "sleeping", until: 0, checkpoint: { phase: "retry", until: 0, attempt: 0 } } });
        return true;
    }
    /** Internal: replace one task record completely. Tasks change their own state through their runtime. */`,
	},
	{
		why: "type the generation retry operation",
		file: "node_modules/@earendil-works/pi-durable/dist/types.d.ts",
		find: `export interface Tx {
    conversation`,
		replace: `export interface Tx {
    /** Patched by pi2: expedite a generation retry read in this transaction, if it is still sleeping. */
    carryOnGeneration(task: TaskRecord<JsonValue, JsonValue, JsonValue>, now: number): boolean;
    conversation`,
	},
	{
		// A message the person sends to steer a run is placed after the run's current round of tool calls. A run waiting to
		// ask a model again (a retry's sleep, and so a wait for a provider's limit, which can be hours) has no round: the
		// message was placed only after the request following the wait had been answered, and that answer was to the
		// conversation as it was before the message. This places queued steers, and writes, as the sleep ends, before
		// the next attempt's request is made, so that request carries them. Until then the message stays queued, where
		// the person can take it back, and Stop ends the run as ever. Not after a reset (a handoff), which only a round
		// places. Issue #324.
		why: "a message sent while a run waits for a provider's limit is only read after the next answer",
		file: "node_modules/@earendil-works/pi-durable/dist/harness/generation.js",
		find: `            await runtime.commit(async (tx) => {
                const live = await tx.doc(LiveDoc, runtime.conversationId);
                const kept = compacted === undefined ? {} : { compacted };
                // A poll the host died during polls its response again, as the next attempt.`,
		replace: `            await runtime.commit(async (tx) => {
                // Patched by pi2 (engine/scripts/patch-dependencies.ts): what was sent to steer during the wait is placed
                // now, so the next attempt's request carries it. Read before the commit's first table write.
                const boundary = poll === undefined ? await prepareBoundary(tx, runtime.conversationId, runtime.settings) : undefined;
                const live = await tx.doc(LiveDoc, runtime.conversationId);
                if (boundary !== undefined && !hasQueuedReset(boundary.inbox.items) && boundary.inbox.items.some((item) => item.mode === "steer" || item.mode === "write")) {
                    const { users } = await applyBoundary(tx, boundary, "postTools", runtime.now());
                    if (live.run?.taskId === runtime.taskId)
                        live.run.inputs.push(...users);
                }
                const kept = compacted === undefined ? {} : { compacted };
                // A poll the host died during polls its response again, as the next attempt.`,
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
