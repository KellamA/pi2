// A message from the person gets through while an agent waits (issue #295). See docs/architecture.md, "A message while
// an agent waits".
//
// A message sent to a busy conversation to steer it is placed by pi durable after the current round of tool calls: once
// every call of the answer has returned. A call that only waits (for a sub-chat's answer, for a background command's
// output, for the person's answer to a question) could hold it for an hour. So such a call stops waiting when one comes
// and says so in its result, and the round ends; what it waited for carries on. A call that is doing something (a
// command in the foreground, an edit, a call to an MCP tool, a script) is left to finish, and the message comes after it.
//
// A sub-chat whose wait ended this way carries on as one handed over with `wait: false` (wakes.ts): its answer comes to
// the agent as a message when it is done, waking it if it is not answering, or `sub_chats` with `wait` waits for it.

import { type Context, withCancel } from "@earendil-works/chord/context";
import {
	type ConversationId,
	type ConversationView,
	type DocumentReader,
	type EntryRecord,
	InboxDoc,
	type SettledSubmissionRecord,
	type SubmissionId,
	type ToolExecutionApi,
} from "@earendil-works/pi-durable";
import { commandLine } from "./background.ts";
import type { Engine, Feature } from "./features.ts";

/**
 * Tools whose calls only wait, and so stop waiting when the person sends a message: `delegate` (for a sub-chat's answer),
 * `sub_chats` (with `wait`; its other actions take no time), `background` (a read with `wait`; the same) and `ask_user`
 * (for the person, who wrote instead). Every other call is left to finish: a command in the foreground, an edit or a
 * write, a call to an MCP tool, a code mode script and the calls it makes, computer use and the browser, which are doing
 * something that cannot be left half done.
 */
export const GIVES_WAY = new Set(["delegate", "sub_chats", "background", "ask_user"]);

let engine: Engine | undefined;

/** Calls waiting in each conversation, told when the person sends it a message. */
const listeners = new Map<number, Set<() => void>>();

/** The person sent `conversationId` a message to steer it. Called once it is admitted. */
export function messageSent(conversationId: number): void {
	for (const heard of [...(listeners.get(conversationId) ?? [])]) heard();
}

/** Whether a message from the person to steer the conversation is waiting to be placed. */
async function messageWaiting(read: DocumentReader, conversationId: number, context: Context): Promise<boolean> {
	const inbox = await read.snapshot(InboxDoc, conversationId as unknown as ConversationId, context);
	return (inbox?.items ?? []).some((item) => item.mode === "steer");
}

/**
 * Wait with `wait`, unless the person sends the conversation a message first, or one is already waiting: then the wait
 * is cancelled (its context, not what it waited for) and this says so. Stopping the call rejects as before. A call a code
 * mode script made is part of that script, which is doing something, so it waits as it always did.
 */
export async function unlessMessaged<T>(
	api: Pick<ToolExecutionApi, "conversationId" | "callId"> & DocumentReader,
	wait: (context: Context) => Promise<T>,
	context: Context,
): Promise<{ value: T } | { messaged: true }> {
	if (api.callId.includes("/")) return { value: await wait(context) };
	const id = api.conversationId as unknown as number;
	const own = listeners.get(id) ?? new Set();
	listeners.set(id, own);
	let heard = () => {};
	const message = new Promise<{ messaged: true }>((resolve) => (heard = () => resolve({ messaged: true })));
	own.add(heard);
	const { context: waiting, cancel } = withCancel(context);
	try {
		// Listened for first, then looked for, so that a message sent in between is not missed.
		if (await messageWaiting(api, id, context)) return { messaged: true };
		const work = wait(waiting).then((value) => ({ value }));
		const first = await Promise.race([work, message]);
		if ("value" in first) return first;
		// Cancelled, the wait rejects at once; one that got what it waited for in the same moment (taken from a list, say)
		// gives it, so that nothing it took is lost.
		cancel();
		return (await work.catch(() => undefined)) ?? first;
	} finally {
		own.delete(heard);
		if (own.size === 0) listeners.delete(id);
		cancel();
	}
}

/** Stop a sub-chat's run, without waiting for it. */
function stopChat(chat: number): void {
	const running = engine!;
	void running
		.harness()
		.conversation(chat as unknown as ConversationId, running.context())
		.then((conv) => conv?.abort(running.context()))
		.catch((error) => running.log("could not stop sub-chat", chat, error instanceof Error ? error.message : error));
}

/**
 * Wait for a sub-chat's answer to `submission`, as `delegate` does, unless the person sends a message first: then the
 * sub-chat carries on, and the caller hands it over to be woken for (wakes.ts). Stopping the call stops the sub-chat's
 * run: it belongs to no call (extensions.ts), so pi durable would not.
 */
export async function waitForChat(api: ToolExecutionApi, chat: number, submission: SubmissionId, context: Context): Promise<{ settled: SettledSubmissionRecord } | { messaged: true }> {
	const running = engine!;
	const handle = await running.harness().submission(submission, running.context());
	if (handle === undefined) throw new Error(`The sub-chat's message ${submission} is not known`);
	const stop = () => stopChat(chat);
	context.abortSignal?.addEventListener("abort", stop, { once: true });
	try {
		const outcome = await unlessMessaged(api, (waiting) => handle.wait(waiting), context);
		return "messaged" in outcome ? outcome : { settled: outcome.value };
	} finally {
		context.abortSignal?.removeEventListener("abort", stop);
	}
}

type Slot = { callId: string; name: string; status: string; details?: unknown };

/** A call's arguments, from the newest answer that made calls. */
function callArguments(view: ConversationView): Map<string, Record<string, unknown>> {
	const found = new Map<string, Record<string, unknown>>();
	for (let i = view.entries.length - 1; i >= 0; i--) {
		const message = (view.entries[i] as EntryRecord).model?.[0] as { role?: string; content?: unknown } | undefined;
		if (message?.role !== "assistant" || !Array.isArray(message.content)) continue;
		for (const block of message.content as { type?: string; id?: string; arguments?: unknown }[]) {
			if (block?.type === "toolCall" && typeof block.id === "string") found.set(block.id, (block.arguments ?? {}) as Record<string, unknown>);
		}
		if (found.size > 0) break;
	}
	return found;
}

const quoted = (value: unknown, most = 60) => {
	const line = commandLine(typeof value === "string" ? value : "");
	return `\`${line.length > most ? `${line.slice(0, most - 1)}…` : line}\``;
};

/** A call that holds a message back, in words: "the command `npm test`". */
function holding(slot: Slot, args: Record<string, unknown>, approval: boolean): string {
	const what = (() => {
		switch (slot.name) {
			case "bash":
				return `the command ${quoted(args.command)}`;
			case "write":
			case "edit":
				return `${slot.name === "edit" ? "the edit of" : "writing"} ${quoted(args.path)}`;
			case "write_document":
				return `writing ${quoted(args.path)}`;
			case "codemode":
				return "a script";
			case "computer":
				return "an action on the screen";
			case "browser":
				return "an action in the browser";
			default:
				return `the ${slot.name} call`;
		}
	})();
	return approval ? `your answer about ${what}` : what;
}

/** A call that stops waiting when a message comes, in words: "the wait for sub-chat 12". */
function giving(slot: Slot, args: Record<string, unknown>): string {
	if (slot.name === "ask_user") return "its question to you";
	if (slot.name === "background") return `the wait for ${typeof args.id === "string" ? args.id : "a background command"}`;
	if (slot.name === "sub_chats") return "the wait for its sub-chats";
	const details = (slot.details ?? {}) as { conversationId?: unknown; agentName?: unknown };
	const chat = typeof details.conversationId === "number" ? details.conversationId : typeof args.chat === "number" ? args.chat : undefined;
	const who = typeof details.agentName === "string" && details.agentName !== "" ? `${details.agentName}'s sub-chat` : "a sub-chat";
	return `the wait for ${who}${chat === undefined ? "" : ` ${chat}`}`;
}

/**
 * What a message sent to steer the conversation now would wait for, while it is working: `holds`, the calls it is placed
 * after, each in words; and `ends`, the waits it would end. No holds: it reaches the agent once its current step ends.
 * `retryAt`: the run is waiting to ask the model again (a retry, or a wait for a provider's limit, #324), and the message
 * is placed when it does, so that request carries it; not before, however long the wait.
 */
export function messageWaits(view: ConversationView, conversationId: number, approvals: { callId: string; conversationId: number }[]): { holds: string[]; ends: string[]; retryAt?: number } | null {
	const live = (view.docs["pi.live"] ?? {}) as { run?: unknown; tools?: Slot[]; generation?: { retry?: { at?: unknown } } };
	if (live.run === undefined) return null;
	const retryAt = live.generation?.retry?.at;
	if (typeof retryAt === "number") return { holds: [], ends: [], retryAt };
	const slots = (live.tools ?? []).filter((slot) => slot.status !== "done");
	if (slots.length === 0) return { holds: [], ends: [] };
	const args = callArguments(view);
	const holds: string[] = [];
	const ends: string[] = [];
	for (const slot of slots) {
		const own = args.get(slot.callId) ?? {};
		// A call that only waits gives way, and one not yet started that only waits will not wait at all.
		if (GIVES_WAY.has(slot.name)) {
			if (slot.status === "running") ends.push(giving(slot, own));
			continue;
		}
		holds.push(holding(slot, own, approvals.some((item) => item.callId === slot.callId && item.conversationId === conversationId)));
	}
	return { holds, ends };
}

export const heed: Feature = (given, running) => {
	engine = running;
	return {
		state: (view) => {
			const id = view.conversation.id as unknown as number;
			return { messageWaits: messageWaits(view, id, given.inbox.list().filter((item) => item.kind === "approval")) };
		},
	};
};
