// The task list an agent keeps while it works on something with several steps.
//
// One durable document per conversation holds the list. A fork starts with its parent's list; a sub-chat has its own.
// The app is sent it as `plan` in the conversation state. See features.ts for what a feature can add.

import type { Context } from "@earendil-works/chord/context";
import { type ConversationId, defineDoc, defineTool, section } from "@earendil-works/pi-durable";
import { arr, obj, str } from "@earendil-works/pi-schema";
import type { Feature } from "./features.ts";

export type PlanStatus = "pending" | "in_progress" | "completed";
export type PlanItem = { content: string; status: PlanStatus };
export type Plan = { items: PlanItem[]; updatedAt: number };

export const MAX_ITEMS = 20;
export const MAX_LENGTH = 120;
const STATUSES: readonly string[] = ["pending", "in_progress", "completed"];

/** A conversation's list. Conversation-scoped, so it survives a restart, and a fork carries it along. */
const PlanDoc = defineDoc<{ items: PlanItem[]; updatedAt: number }>({
	kind: "pi2.plan",
	version: 1,
	scope: "conversation",
	history: "latest",
	fork: "current",
	initial: () => ({ items: [], updatedAt: 0 }),
	checkpointWhen: () => true,
});

/** Check a list the model sent; a plain message says what to fix, or the cleaned list comes back. */
export function checkPlan(items: readonly { content: string; status: string }[]): PlanItem[] | string {
	if (items.length === 0) return "The list is empty. Send at least one item.";
	if (items.length > MAX_ITEMS) return `The list has ${items.length} items; the most allowed is ${MAX_ITEMS}. Merge steps into fewer, larger ones.`;
	const clean: PlanItem[] = [];
	for (const [index, item] of items.entries()) {
		const content = item.content.trim().replace(/\s+/g, " ");
		if (content === "") return `Item ${index + 1} has no text.`;
		if (content.length > MAX_LENGTH) return `Item ${index + 1} is ${content.length} characters; keep each to ${MAX_LENGTH} or fewer, as a short phrase.`;
		if (!STATUSES.includes(item.status)) return `Item ${index + 1} has the status "${item.status}"; use pending, in_progress or completed.`;
		clean.push({ content, status: item.status as PlanStatus });
	}
	const working = clean.filter((item) => item.status === "in_progress").length;
	if (working > 1) return `${working} items are in_progress; keep exactly one at a time and mark the others pending or completed.`;
	return clean;
}

/** What the app is shown, by conversation. Filled when a conversation is opened and when its list changes. */
const known = new Map<number, Plan | null>();
let read: ((id: ConversationId) => Promise<Plan | null>) | undefined;

/** Load a conversation's list so its state can carry it. Call before the first state is sent for the conversation. */
export async function preparePlan(id: number): Promise<void> {
	if (known.has(id) || read === undefined) return;
	known.set(id, await read(id as unknown as ConversationId));
}

const GUIDE = [
	"Use update_plan to keep a task list when the work has three or more distinct steps. The person sees it pinned above the message field.",
	"Write the list before you start, keep exactly one item in_progress, and mark an item completed as soon as it is done, not in a batch at the end.",
	"Each call replaces the whole list, so send it again when the plan changes. Keep items to short phrases. Do not use it for a single quick answer.",
].join(" ");

export const plan: Feature = (_host, engine) => {
	read = async (id) => {
		const doc = await engine.harness().snapshot(PlanDoc, id, engine.context());
		return doc === undefined || doc.items.length === 0 ? null : { items: doc.items.map((item) => ({ ...item })), updatedAt: doc.updatedAt };
	};

	const updatePlan = defineTool({
		name: "update_plan",
		description:
			"Keep a short task list for this conversation, shown to the person above the message field. Send the whole list every time: items of { content, status } with status pending, in_progress or completed. " +
			`1 to ${MAX_ITEMS} items, each a short phrase, at most one in_progress. It replaces the previous list.`,
		parameters: obj({ items: arr(obj({ content: str(), status: str() })) }),
		replay: "safe", // replacing the list with the same list again changes nothing
		execute: async (args, api, context) => {
			const checked = checkPlan(args.items);
			if (typeof checked === "string") return { output: [{ type: "text" as const, text: `${checked} The task list is unchanged.` }], isError: true };
			const stored: Plan = { items: checked, updatedAt: Date.now() };
			await api.commit(async (tx) => {
				const doc = await tx.doc(PlanDoc, api.conversationId);
				doc.items = stored.items;
				doc.updatedAt = stored.updatedAt;
			}, context as Context);
			known.set(api.conversationId as unknown as number, stored);
			const done = checked.filter((item) => item.status === "completed").length;
			return { output: [{ type: "text" as const, text: `${done} of ${checked.length} done` }] };
		},
	});

	return {
		tools: [updatePlan],
		toolNames: () => ["update_plan"],
		sections: [section("task_list", (input) => (input.agent.tools.some((tool) => tool.name === "update_plan") ? GUIDE : undefined))],
		state: (view) => ({ plan: known.get(view.conversation.id as unknown as number) ?? null }),
	};
};
