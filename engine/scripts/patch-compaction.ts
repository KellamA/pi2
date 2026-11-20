// pi durable owns the cut, summary request, usage, retries and durable queue. These adapters add pi²'s
// earlier threshold, a tool-round boundary, and a barrier for person-requested summaries while idle.
const dir = "node_modules/@earendil-works/pi-durable/dist/harness/";
const patch = (file: string, why: string, find: string, replace: string) => ({ file: dir + file, why, find, replace });

export const COMPACTION_PATCHES = [
	patch("generation.js", "an agent's earlier size needs a safe, non-fatal compaction boundary", `            const threshold = compacted === undefined
                ? thresholdCompaction(view, entries, resolved.contextWindow, compactionPolicy(settings, model, agent.compaction))
                : undefined;
            if (threshold === "blocking") {
                // Compact first and prepare again; the transcript is unchanged until the compaction appends.
                await runtime.commit(async (tx) => {
                    const child = await createCompaction(tx, conversationId, { reason: "threshold" }, runtime.taskId);
                    const checkpoint = { phase: "prepare", attempt, compacted: child, threshold: true };`, `            const policy = compactionPolicy(settings, model, agent.compaction);
            const early = settings.compaction.early?.(conversationId, resolved.contextWindow, policy);
            const automaticContext = compacted === undefined && policy.enabled
                ? await automaticCompactionContext(runtime, view, entries.flatMap((entry) => entry.model ?? []), context)
                : undefined;
            const threshold = automaticContext !== undefined
                ? thresholdCompaction(view, automaticContext.tokens, resolved.contextWindow, policy, early)
                : undefined;
            if (threshold !== undefined) {
                // No request can overtake the summary. Only a window-edge failure stops the generation.
                await runtime.commit(async (tx) => {
                    const child = await createCompaction(tx, conversationId, {
                        automaticContext,
                        reason: threshold === "size" ? "size" : "threshold",
                        ...(threshold === "size" ? { keepRecentTokens: early.keepRecentTokens } : {}),
                    }, runtime.taskId);
                    const checkpoint = { phase: "afterThresholdCompact", attempt, compacted: child, threshold: threshold === "blocking" };`),
	patch("generation.js", "threshold compaction no longer races requests", `                // Checked in this commit, so a compaction admitted during preparation counts.
                if (threshold === "background" && (await tx.doc(LiveDoc, conversationId)).compactions === undefined) {
                    await createCompaction(tx, conversationId, { reason: "threshold" });
                }
                const request = {`, `                // A summary, if needed, has already run before reaching this request.
                const request = {`),
	patch("generation.js", "use the harness's reserve and cut policy for the earlier size", `function thresholdCompaction(view, planned, contextWindow, policy) {
    if (!policy.enabled || contextWindow <= 0)
        return undefined;
    const tokens = estimateContext(view, planned.flatMap((entry) => entry.model ?? []));
    const blocking = contextWindow - policy.reserveTokens;
    const background = blocking - policy.backgroundTokens;
    const over = tokens > blocking ? "blocking" : policy.backgroundTokens > 0 && tokens > background ? "background" : undefined;
    if (over === undefined || selectCut(view, policy.keepRecentTokens) === undefined)
        return undefined;
    return over;
}`, `async function automaticCompactionContext(runtime, view, extra, context) {
    const candidate = { head: view.head?.id ?? null, tokens: estimateContext(view, extra) };
    const live = await runtime.snapshot(LiveDoc, runtime.conversationId, context);
    if (runtime.settings.compaction.automaticReady?.(live?.compactionCooldown, candidate, runtime.now()) === false)
        return undefined;
    return candidate;
}
function thresholdCompaction(view, tokens, contextWindow, policy, early) {
    if (contextWindow <= 0)
        return undefined;
    const blocking = contextWindow - policy.reserveTokens;
    const background = blocking - policy.backgroundTokens;
    if (tokens > blocking && selectCut(view, policy.keepRecentTokens) !== undefined)
        return "blocking";
    if (early !== undefined && tokens > contextWindow - early.reserveTokens && selectCut(view, early.keepRecentTokens) !== undefined)
        return "size";
    if (policy.backgroundTokens > 0 && tokens > background && selectCut(view, policy.keepRecentTokens) !== undefined)
        return "background";
    return undefined;
}`),
	patch("generation.js", "place steers admitted during a threshold summary before the next model step", `        request: async (task, runtime, context) => {`, `        afterThresholdCompact: async (task, runtime, context) => {
            const { attempt, compacted, threshold, overflow } = task.state.checkpoint;
            const [outcome] = await runtime.outcomes([compacted], context);
            const failed = (threshold || overflow !== undefined) && outcome?.status !== "completed";
            await runtime.commit(async (tx) => {
                const boundary = await prepareBoundary(tx, runtime.conversationId, runtime.settings);
                const live = await tx.doc(LiveDoc, runtime.conversationId);
                // Leave resets (and what follows them) to the ordinary run boundary.
                if (!failed && !hasQueuedReset(boundary.inbox.items)) {
                    const { users } = await applyBoundary(tx, boundary, "postTools", runtime.now());
                    live.run?.inputs.push(...users);
                }
                return { status: "running", checkpoint: { phase: "prepare", attempt, compacted, ...(threshold === undefined ? {} : { threshold }), ...(overflow === undefined ? {} : { overflow }) } };
            }, context);
        },
        request: async (task, runtime, context) => {`),
	patch("generation.js", "check the cooldown even if the provider rather than the estimate detects the limit", `        if (selectCut(view, compaction.keepRecentTokens) !== undefined) {
            const text = message.errorMessage ?? "Context overflow";`, `        const automaticContext = await automaticCompactionContext(runtime, view, [], context);
        if (automaticContext !== undefined && selectCut(view, compaction.keepRecentTokens) !== undefined) {
            const text = message.errorMessage ?? "Context overflow";`),
	patch("generation.js", "place steers after overflow compaction too", `                const child = await createCompaction(tx, conversationId, { reason: "overflow" }, runtime.taskId);
                const checkpoint = { phase: "prepare", attempt, compacted: child, overflow: text };`, `                const child = await createCompaction(tx, conversationId, { reason: "overflow", automaticContext }, runtime.taskId);
                const checkpoint = { phase: "afterThresholdCompact", attempt, compacted: child, overflow: text };`),
	patch("generation.js", "resume a tool round after its summary, without restarting tools", `            const { assistant, tools, pending } = task.state.checkpoint;
            const [next, ...rest] = pending;
            if (next === undefined)
                return finishToolRound(runtime, assistant, tools, context);`, `            const { assistant, tools, pending, summarized } = task.state.checkpoint;
            const [next, ...rest] = pending;
            if (next === undefined)
                return finishToolRound(runtime, assistant, tools, context, summarized);`),
	patch("generation.js", "read a compaction request from the settled tool round", `async function finishToolRound(runtime, assistant, tools, context) {`, `async function finishToolRound(runtime, assistant, tools, context, summarized) {`),
	patch("generation.js", "do not repeat the afterTools hook after compaction", `    await runtime.hooks.each("afterTools", (hook) => hook(assistant, results, runtime, context));`, `    if (!summarized)
        await runtime.hooks.each("afterTools", (hook) => hook(assistant, results, runtime, context));`),
	patch("generation.js", "start a tool-requested summary after every tool has returned and before steers", `    const handoff = ordered.findLast((control) => control?.handoff !== undefined)?.handoff;
    // Read from the phase's agent`, `    const handoff = ordered.findLast((control) => control?.handoff !== undefined)?.handoff;
    const notes = ordered.flatMap((control) => control?.compact === undefined ? [] : [control.compact]);
    if (!summarized && notes.length > 0 && handoff === undefined) {
        await runtime.commit(async (tx) => {
            const child = await createCompaction(tx, conversationId, {
                reason: "agent", instructions: notes.join("\\n\\n"), keepRecentTokens: 0,
            }, runtime.taskId);
            const checkpoint = { phase: "tools", assistant, tools, pending: [], summarized: true };
            return { status: "waiting", checkpoint, on: [child], policy: "allSettled" };
        }, context);
        return;
    }
    // Read from the phase's agent`),
	patch("generation.js", "keep the input size of the last request even when its entry is off-screen", `    return tx.appendEntry(AssistantEntry, conversationId, { model: [message] });`, `    const { input, cacheRead, cacheWrite, totalTokens } = message.usage;
    if (totalTokens > 0)
        (await tx.doc(LiveDoc, conversationId)).lastRequestInputTokens = input + cacheRead + cacheWrite;
    return tx.appendEntry(AssistantEntry, conversationId, { model: [message] });`),
	patch("harness.js", "one manual summary at an idle boundary, never racing another context writer", `        return this.#host.harness.commitWith((tx) => createCompaction(tx, this.id, input), context);`, `        return this.#host.harness.commitWith(async (tx) => {
            const live = await tx.doc(LiveDoc, this.id);
            if (live.run !== undefined || live.compactions?.length > 0)
                throw new Error("Wait for this conversation to finish answering or summarizing, then try again.");
            return createCompaction(tx, this.id, input);
        }, context);`),
	patch("submissions.js", "durably queue inputs behind a manual summary (including a wake racing admission)", `    const busy = live.run !== undefined;`, `    const summarizing = live.compactions?.some((status) => status.trigger === "manual") === true;
    const busy = live.run !== undefined || summarizing;`),
	patch("compaction.js", "manual compaction releases the durable input queue at its own boundary", `import { admitSubmission } from "./submissions.js";`, `import { admitSubmission } from "./submissions.js";
import { startRun } from "./generation.js";
import { applyBoundary, isStale, prepareBoundary } from "./inbox.js";`),
	patch("compaction.js", "allow explicit and earlier compactions to keep a different recent tail; notice a manual request with no cut", `            const cut = selectCut(view, policy.keepRecentTokens);
            if (cut === undefined)
                return complete(runtime, context);`, `            const cut = selectCut(view, task.input.keepRecentTokens ?? policy.keepRecentTokens);
            if (cut === undefined)
                return complete(runtime, context, task.input.reason === "manual");`),
	patch("compaction.js", "give the summary its own output allowance and use the lowest thinking level", `                thinkingLevel: agent.thinkingLevel,
                streamOptions: settings.stream,
                maxTokens: Math.min(Math.floor(0.8 * policy.reserveTokens), model.maxTokens > 0 ? model.maxTokens : Number.POSITIVE_INFINITY),`, `                thinkingLevel: settings.compaction.summaryThinking?.(model) ?? "off",
                streamOptions: settings.stream,
                maxTokens: Math.min(settings.compaction.summaryTokens ?? 16_384,
                    model.maxTokens > 0 ? model.maxTokens : Number.POSITIVE_INFINITY),`),
	patch("compaction.js", "give the summarizer pi²'s retention instructions without recording them as the agent's note", `                    content: [{ type: "text", text: summaryPrompt(summarizedMessages(view, cut), task.input.instructions) }],`, `                    content: [{ type: "text", text: summaryPrompt(summarizedMessages(view, cut),
                        [runtime.settings.compaction.instructions, task.input.instructions].filter(Boolean).join("\\n\\n") || undefined, request.shorter ? maxTokens : undefined) }],`),
	patch("compaction.js", "do not inherit reasoning from stream settings", `            const { deferred: _deferred, ...forwarded } = streamOptions;`, `            const { deferred: _deferred, reasoning: _reasoning, ...forwarded } = streamOptions;`),
	patch("compaction.js", "use the host's provider adapters, including learned thinking levels", `            const message = await runtime.models.completeSimple(model, { messages }, options);`, `            const message = await runtime.models.streamSimple(model, { messages }, options).result();`),
	patch("compaction.js", "retry a length stop once, after recording what it cost", `                if (summary !== undefined)
                    return placeSummary(tx, runtime, current, live, firstKept, summary);
                if (retry) {`, `                if (summary !== undefined)
                    return placeSummary(tx, runtime, current, live, firstKept, summary);
                if (message.stopReason === "length" && !request.shorter) {
                    const status = compactionStatus(live, runtime.taskId);
                    if (status !== undefined)
                        status.attempt += 1;
                    // No portable way to resume a completed response. Keep the same source and leave the partial text out.
                    return { status: "running", checkpoint: { phase: "summarize", ...request, shorter: true } };
                }
                if (retry) {`),
	patch("compaction.js", "keep the displayed attempt count increasing across both kinds of retry", `                    status.attempt = attempt;`, `                    status.attempt += 1;`),
	patch("compaction.js", "give a length retry a concrete shorter target and prioritize what later work needs", `function summaryPrompt(messages, instructions) {
    const focus = instructions === undefined ? "" : \x60\\n\\nAdditional focus: \${instructions}\x60;
    return \x60<conversation>\\n\${serializeConversation(messages)}\\n</conversation>\\n\\n\${SUMMARIZATION_PROMPT}\${focus}\x60;
}`, `function summaryPrompt(messages, instructions, retryBudget) {
    const focus = instructions === undefined ? "" : \x60\\n\\nAdditional focus: \${instructions}\x60;
    const shorter = retryBudget === undefined ? "" : \x60\\n\\nThe previous summary hit the output limit. Write a complete, shorter summary in at most \${Math.max(1, Math.floor(retryBudget / 2))} tokens. Keep only what later work needs: open requests, decisions, standing instructions, blockers, and what is running. Drop background and incidental detail.\x60;
    return \x60<conversation>\\n\${serializeConversation(messages)}\\n</conversation>\\n\\n\${SUMMARIZATION_PROMPT}\${focus}\${shorter}\x60;
}`),
	patch("compaction.js", "record the estimated active size when admitting an automatic summary", `    const status = { taskId, trigger: input.reason, blocking: owner !== undefined, attempt: 1 };`, `    const status = { taskId, trigger: input.reason, blocking: owner !== undefined, attempt: 1,
        ...(input.automaticContext === undefined ? {} : { automaticContext: input.automaticContext }) };`),
	patch("compaction.js", "a successful summary clears the warning and the cooldown", `    delete live.compactionFailure;`, `    delete live.compactionFailure;
    delete live.compactionCooldown;`),
	patch("compaction.js", "attach authoritative state at commit time and place the marker before queued inputs", `    const text = \x60\${SUMMARY_PREFIX}\${summary}\${SUMMARY_SUFFIX}\x60;
    const entry = {
        kind: CompactionEntry.kind,
        head: firstKept,
        model: [{ role: "user", content: [{ type: "text", text }], timestamp: runtime.now() }],
        data: { reason: current.input.reason },
    };
    const result = current.owner === undefined`, `    const { reason, instructions } = current.input;
    const extra = await runtime.settings.compaction.checkpoint?.(tx, runtime.conversationId, reason, instructions);
    const text = SUMMARY_PREFIX + summary + SUMMARY_SUFFIX + (extra?.text ?? "");
    const entry = {
        kind: CompactionEntry.kind,
        head: firstKept,
        model: [{ role: "user", content: [{ type: "text", text }], timestamp: runtime.now() }],
        data: { reason, ...(instructions === undefined ? {} : { note: instructions }), ...extra?.data },
    };
    if (reason === "manual" && live.run === undefined) {
        const { entryId } = await finishIdleCompaction(tx, runtime.conversationId, live, runtime.settings, runtime.now(), entry);
        return { status: "terminal", outcome: { status: "completed", result: entryId === undefined ? {} : { entryId } } };
    }
    const result = current.owner === undefined`),
	patch("compaction.js", "release queued messages after an unsuccessful manual summary", `                failCompactionStatus(live, runtime.taskId, text);`, `                await finishWithoutSummary(tx, runtime, live, text);`),
	patch("compaction.js", "release any new messages admitted after Stop withdrew older ones", `            removeCompactionStatus(await tx.doc(LiveDoc, runtime.conversationId), runtime.taskId);
            return { status: "terminal", outcome: { status: "aborted" } };`, `            await finishWithoutSummary(tx, runtime, await tx.doc(LiveDoc, runtime.conversationId));
            return { status: "terminal", outcome: { status: "aborted" } };`),
	patch("compaction.js", "place a display-only notice for short manual requests before releasing queued messages", `async function complete(runtime, context) {
    await runtime.commit(async (tx) => {
        removeCompactionStatus(await tx.doc(LiveDoc, runtime.conversationId), runtime.taskId);
        return { status: "terminal", outcome: { status: "completed", result: {} } };`, `async function complete(runtime, context, noticeTooShort = false) {
    await runtime.commit(async (tx) => {
        const notice = noticeTooShort ? { kind: "pi2.compactionTooShort" } : undefined;
        await finishWithoutSummary(tx, runtime, await tx.doc(LiveDoc, runtime.conversationId), undefined, notice);
        return { status: "terminal", outcome: { status: "completed", result: {} } };`),
	patch("compaction.js", "release queued messages if the summary has too many interruptions", `    const message = \x60Compaction was interrupted \${cutOffCount(task)}\x60;
    await runtime.commit(async (tx) => {
        failCompactionStatus(await tx.doc(LiveDoc, runtime.conversationId), runtime.taskId, message);`, `    const message = \x60Compaction was interrupted \${cutOffCount(task)}\x60;
    await runtime.commit(async (tx) => {
        await finishWithoutSummary(tx, runtime, await tx.doc(LiveDoc, runtime.conversationId), message);`),
	patch("compaction.js", "release queued messages if the summary's model cannot be found", `    const message = ref === undefined ? "No model is configured" : \x60Model \${ref.provider}/\${ref.modelId} is not available\x60;
    await runtime.commit(async (tx) => {
        failCompactionStatus(await tx.doc(LiveDoc, runtime.conversationId), runtime.taskId, message);`, `    const message = ref === undefined ? "No model is configured" : \x60Model \${ref.provider}/\${ref.modelId} is not available\x60;
    await runtime.commit(async (tx) => {
        await finishWithoutSummary(tx, runtime, await tx.doc(LiveDoc, runtime.conversationId), message);`),
	patch("compaction.js", "end a manual summary and start its next queued run in one commit", `/** Remove the status and complete without a summary. */`, `/** A failed or declined summary does not write anything of its own. */
async function finishWithoutSummary(tx, runtime, live, error, notice) {
    const manual = compactionStatus(live, runtime.taskId)?.trigger === "manual";
    if (error === undefined)
        removeCompactionStatus(live, runtime.taskId);
    else
        failCompactionStatus(live, runtime.taskId, error, runtime.now());
    if (manual)
        await finishIdleCompaction(tx, runtime.conversationId, live, runtime.settings, runtime.now(), notice);
}
export async function finishIdleCompaction(tx, id, live, settings, now, entry) {
    // A manual compaction started before the upgrade could still belong to a busy conversation.
    if (live.run !== undefined || live.compactions?.some((status) => status.trigger === "manual"))
        return {};
    const boundary = await prepareBoundary(tx, id, settings);
    let entryId;
    if (entry !== undefined && !isStale(boundary, entry)) {
        entryId = (await tx.appendEntry(id, entry)).id;
        if (entry.head !== undefined)
            boundary.head = entry.head;
    }
    const { users, first } = await applyBoundary(tx, boundary, "final", now);
    if (users.length > 0)
        await startRun(tx, id, live, { inputs: users, first });
    return { entryId };
}
/** Remove the status and complete without a summary. */`),
	patch("harness.js", "faulted compactions must release queued inputs too", `            settleOutcome: settleSchedulerOutcome,`, `            settleOutcome: (tx, record, outcome) => settleSchedulerOutcome(tx, record, outcome, settings(), now()),`),
	patch("live.js", "faulted manual compactions must release queued inputs too", `import { convertPartial } from "./generation.js";`, `import { convertPartial } from "./generation.js";
import { finishIdleCompaction } from "./compaction.js";`),
	patch("live.js", "pass settings to the scheduler's compaction cleanup", `export async function settleSchedulerOutcome(tx, record, outcome) {`, `export async function settleSchedulerOutcome(tx, record, outcome, settings, now) {`),
	patch("live.js", "persist the automatic cooldown independently of the warning", `export function failCompactionStatus(live, taskId, error) {
    const status = compactionStatus(live, taskId);
    if (status !== undefined)
        live.compactionFailure = { taskId: status.taskId, trigger: status.trigger, error };`, `export function failCompactionStatus(live, taskId, error, now) {
    const status = compactionStatus(live, taskId);
    if (status !== undefined) {
        live.compactionFailure = { taskId: status.taskId, trigger: status.trigger, error };
        if (status.automaticContext !== undefined)
            live.compactionCooldown = { ...status.automaticContext, at: now };
    }`),
	patch("live.js", "release the queue after an unexpected compaction error", `        if (cutOff)
            removeCompactionStatus(live, record.id);
        else
            failCompactionStatus(live, record.id, outcome.status === "faulted" ? outcome.error.message : outcome.reason);
        return;`, `        const manual = compactionStatus(live, record.id)?.trigger === "manual";
        if (cutOff)
            removeCompactionStatus(live, record.id);
        else
            failCompactionStatus(live, record.id, outcome.status === "faulted" ? outcome.error.message : outcome.reason, now);
        if (manual && !record.abortRequested)
            await finishIdleCompaction(tx, record.conversationId, live, settings, now);
        return;`),
];
