// pi durable places every input through `appendInput`: the input that starts a run of an idle conversation, and a queued
// message or a steer at a boundary. A project's orchestrator is told what changed in the project in front of each input
// it is given (engine/src/orchestrator.ts, docs/projects.md 6.4), in the commit that places it, so the host is given a
// hook there: `placeInput(tx, conversationId, now)`, a setting like `compaction.checkpoint`, carried from the settings
// to every boundary. It may append entries; it must not read tables (`tx.entry`, `tx.scanEntries`…), which a commit
// that has written cannot do. Without the setting nothing changes.
const dir = "node_modules/@earendil-works/pi-durable/dist/harness/";
const patch = (file: string, why: string, find: string, replace: string) => ({ file: dir + file, why, find, replace });

export const INPUT_PATCHES = [
	patch(
		"agent.js",
		"keep the host's input hook in the resolved settings",
		`        afterFailedRun: settings?.afterFailedRun ?? "keep",`,
		`        afterFailedRun: settings?.afterFailedRun ?? "keep",
        // Patched by pi2 (engine/scripts/patch-inputs.ts): the host's hook as an input is placed.
        ...(settings?.placeInput === undefined ? {} : { placeInput: settings.placeInput }),`,
	),
	patch(
		"inbox.js",
		"carry the input hook on a boundary",
		`        followUpMode: modes.followUpMode,
        head,
    };`,
		`        followUpMode: modes.followUpMode,
        head,
        // Patched by pi2 (engine/scripts/patch-inputs.ts).
        placeInput: modes.placeInput,
    };`,
	),
	patch(
		"inbox.js",
		"call the input hook for an input placed at a boundary",
		`        const entry = await appendInput(tx, conversationId, item.content, item.entry, now);`,
		`        const entry = await appendInput(tx, conversationId, item.content, item.entry, now, boundary.placeInput);`,
	),
	patch(
		"inbox.js",
		"let the host append entries in front of an input as it is placed",
		`export function appendInput(tx, conversationId, content, entry, now) {
    const message = { role: "user", content, timestamp: now };`,
		`export async function appendInput(tx, conversationId, content, entry, now, placeInput) {
    // Patched by pi2 (engine/scripts/patch-inputs.ts): what the host puts in front of this input, in this commit.
    await placeInput?.(tx, conversationId, now);
    const message = { role: "user", content, timestamp: now };`,
	),
	patch(
		"submissions.js",
		"call the input hook for an input that starts a run",
		`    const entry = await appendInput(tx, conversationId, draft.content, draft.entry, now);`,
		`    const entry = await appendInput(tx, conversationId, draft.content, draft.entry, now, queueModes.placeInput);`,
	),
	patch(
		"types.d.ts",
		"type the input hook",
		`    readonly restartLimit?: number;
};
/**
 * What a failed run does`,
		`    readonly restartLimit?: number;
    /**
     * Patched by pi2 (engine/scripts/patch-inputs.ts): called in the commit that places an input, before its entry is
     * appended, so the host may append entries in front of it. It must not read tables.
     */
    readonly placeInput?: (tx: Tx, conversationId: ConversationId, now: number) => Promise<void>;
};
/**
 * What a failed run does`,
	),
];
