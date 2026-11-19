// Kept outside src so it isn't shipped with the installed engine. Loaded only for scripts/test-copy.
import { fauxAssistantMessage, fauxText, fauxToolCall } from "@earendil-works/pi-ai/providers/faux";
import { AssistantEntry, type ConversationId, ToolResultEntry, type Tx, UserEntry } from "@earendil-works/pi-durable";

export function fixtureSize(value: unknown): number {
	if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 1 || value > 10_000) {
		throw new Error("entries must be a positive integer (up to 10000)");
	}
	return value;
}

/** Append real transcript entries in the creating transaction. No submissions, model calls or commands run. */
export async function seedTranscript(tx: Tx, id: ConversationId, entries: number, timestamp: number): Promise<void> {
	const command = "fixture: inspect example build output";
	const output = Array.from({ length: 100 }, (_, i) => `  ${i + 1}: checking example/module-${i + 1}.ts … passed\n`).join("");
	for (let i = 0; i < entries; i += 4) {
		const turn = i / 4 + 1;
		await tx.appendEntry(UserEntry, id, { model: [{ role: "user", content: `Check example build ${turn}.`, timestamp }] });
		if (entries - i < 3) {
			if (entries - i === 2) await tx.appendEntry(AssistantEntry, id, { model: [fauxAssistantMessage("The example build passed.")] });
			break;
		}
		const call = fauxToolCall("bash", { command }, { id: `fixture-${turn}` });
		await tx.appendEntry(AssistantEntry, id, {
			model: [fauxAssistantMessage([fauxText("Checking the example build."), call], { stopReason: "toolUse" })],
		});
		await tx.appendEntry(ToolResultEntry, id, {
			model: [{ role: "toolResult", toolCallId: call.id, toolName: "bash", content: [{ type: "text", text: `Example build ${turn}\n${output}` }], isError: false, timestamp }],
			data: { diagnostics: [] },
		});
		if (i + 3 < entries) await tx.appendEntry(AssistantEntry, id, { model: [fauxAssistantMessage("The example build passed.")] });
	}
}
