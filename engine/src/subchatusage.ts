import type { Context } from "@earendil-works/chord/context";
import { AssistantEntry, type ConversationId, type Cursor, type Harness, ToolResultEntry, UsageDoc } from "@earendil-works/pi-durable";
import { duration } from "./limitwait.ts";

const tokens = new Intl.NumberFormat("en-US", { notation: "compact", maximumSignificantDigits: 3 });

type Interval = [start: number, end: number];
type Summary = { requests: number; ms: number; fresh: number; cached: number; output: number; largest: number };

/** Count overlapping tool calls only once, and leave out the gaps between pieces of work. */
function worked(intervals: Interval[]): number {
	let total = 0;
	let end = -Infinity;
	for (const [from, to] of intervals.sort((a, b) => a[0] - b[0])) {
		total += Math.max(0, to - Math.max(from, end));
		end = Math.max(end, to);
	}
	return total;
}

export function usageWords({ requests, ms, fresh, cached, output, largest }: Summary): string {
	const time = ms <= 0 ? "" : ms < 1_000 ? "<1 s" : duration(ms);
	const activity = requests > 0 ? `${requests.toLocaleString("en-US")} request${requests === 1 ? "" : "s"}${time === "" ? "" : ` over ${time}`}` : time;
	const read = fresh > 0 && cached > 0
		? `read ${tokens.format(fresh)} tokens new and ${tokens.format(cached)} from the cache`
		: fresh > 0 ? `read ${tokens.format(fresh)} tokens new` : cached > 0 ? `read ${tokens.format(cached)} tokens from the cache` : "";
	const writing = output > 0 ? `wrote ${tokens.format(output)}${read === "" ? " tokens" : ""}` : "";
	const parts = [activity, [read, writing].filter(Boolean).join(", "), largest > 0 ? `largest prompt ${tokens.format(largest)}` : ""].filter(Boolean);
	return parts.length === 0 ? "" : `Used: ${parts.join("; ")}.`;
}

/** Lifetime use, read from the same ledger as Usage and from the durable responses (not just the active context). */
export async function subChatUsage(harness: Pick<Harness, "snapshot" | "conversation">, id: number, context: Context): Promise<string> {
	const conversationId = id as unknown as ConversationId;
	const ledger = await harness.snapshot(UsageDoc, conversationId, context);
	if (ledger === undefined) return "";
	let fresh = 0;
	let cached = 0;
	let output = 0;
	for (const usage of [...Object.values(ledger.models), ...Object.values(ledger.tools)]) {
		// Cache writes are fresh input too. The optional 1h counter is already part of cacheWrite.
		fresh += (usage.input ?? 0) + (usage.cacheWrite ?? 0);
		cached += usage.cacheRead ?? 0;
		output += usage.output ?? 0;
	}

	let requests = 0;
	let largest = 0;
	const intervals: Interval[] = [];
	const conv = await harness.conversation(conversationId, context);
	if (conv !== undefined) {
		let cursor: Cursor | undefined;
		do {
			const page = await conv.entries({}, 100, cursor, context);
			for (const entry of page.items) {
				if (entry.conversationId !== conversationId) continue; // A fork did not make its inherited requests.
				const message = entry.model?.[0];
				if (entry.kind === AssistantEntry.kind && message?.role === "assistant") {
					requests++;
					const usage = message.usage;
					largest = Math.max(largest, (usage?.input ?? 0) + (usage?.cacheRead ?? 0) + (usage?.cacheWrite ?? 0));
					if (message.durationMs !== undefined && message.durationMs > 0) intervals.push([message.timestamp, message.timestamp + message.durationMs]);
				}
				if (entry.kind === ToolResultEntry.kind && message?.role === "toolResult" && message.toolName !== "ask_user" && message.durationMs !== undefined && message.durationMs > 0) {
					intervals.push([message.timestamp - message.durationMs, message.timestamp]);
				}
			}
			cursor = page.next;
		} while (cursor !== undefined);
	}
	return usageWords({ requests, ms: worked(intervals), fresh, cached, output, largest });
}
