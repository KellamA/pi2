// A message from the person gets through while an agent waits (issue #295). See docs/architecture.md, "A message while
// an agent waits".
//
// A message sent to a busy conversation to steer it is placed by pi durable after the current round of tool calls: once
// every call of the answer has returned. A call that only waits (for a sub-chat's answer, for a background command's
// output, for the person's answer to a question) could hold it for an hour. So such a call stops waiting when one comes
// and says so in its result, and the round ends; what it waited for carries on. A call that is doing something (a
// command in the foreground, an edit, a call to an MCP tool, a script) is left to finish, and the message comes after it.
//
// A sub-chat whose wait ended this way still owes its answer. The agent can wait for it again (`delegate` with `chat`
// and no task), and if it does not, the answer is added to the agent's conversation when it comes, without starting an
// answer of its own. Exactly one of the two happens: the sub-chat's `answerOwed` in the library is cleared by whichever
// delivers the answer, in the commit that does.

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
import type { Host } from "./extensions.ts";
import { unfinished } from "./extensions.ts";
import type { Engine, Feature } from "./features.ts";
import { Library } from "./state.ts";

/** The line in a conversation where a sub-chat's answer was added after the agent had stopped waiting for it. */
export const OWED_ANSWER_ENTRY = "pi2.owed-answer";

/**
 * Tools whose calls only wait, and so stop waiting when the person sends a message: `delegate` (for a sub-chat's answer),
 * `background` (a read with `wait`; its other actions take no time) and `ask_user` (for the person, who wrote instead).
 * Every other call is left to finish: a command in the foreground, an edit or a write, a call to an MCP tool, a code mode
 * script and the calls it makes, computer use and the browser, which are doing something that cannot be left half done.
 */
export const GIVES_WAY = new Set(["delegate", "background", "ask_user"]);

let host: Host | undefined;
let engine: Engine | undefined;

/** Calls waiting in each conversation, told when the person sends it a message. */
const listeners = new Map<number, Set<() => void>>();
/** How many calls are waiting for each submission of a sub-chat: while any is, its answer is theirs to give. */
const waitedFor = new Map<number, number>();
/** Owed answers being watched for, by submission. */
const watching = new Set<number>();
/** A submission's id as the library keeps it. */
const idOf = (submission: SubmissionId) => submission as unknown as number;

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
		// Cancelling it when the message wins rejects it; that is expected and nobody is waiting on it then.
		work.catch(() => {});
		return await Promise.race([work, message]);
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
 * sub-chat carries on, its answer is owed, and this says it was let go. Stopping the call stops the sub-chat's run.
 */
export async function waitForChat(api: ToolExecutionApi, chat: number, submission: SubmissionId, context: Context): Promise<{ settled: SettledSubmissionRecord } | { messaged: true }> {
	const running = engine!;
	const handle = await running.harness().submission(submission, running.context());
	if (handle === undefined) throw new Error(`The sub-chat's message ${submission} is not known`);
	const stop = () => stopChat(chat);
	context.abortSignal?.addEventListener("abort", stop, { once: true });
	const id = idOf(submission);
	waitedFor.set(id, (waitedFor.get(id) ?? 0) + 1);
	// Whether the answer is owed once this call is over: so far, as the library says (a call that waits for it again).
	let owed = (await owedBy(api, chat, context)) === submission;
	try {
		const outcome = await unlessMessaged(api, (waiting) => handle.wait(waiting), context);
		await api.commit(async (tx) => {
			const stored = (await tx.doc(Library)).conversations[String(chat)];
			if (stored === undefined) return;
			if ("messaged" in outcome) stored.answerOwed = id;
			else if (stored.answerOwed === id) delete stored.answerOwed;
		}, context);
		owed = "messaged" in outcome;
		return "messaged" in outcome ? outcome : { settled: outcome.value };
	} finally {
		context.abortSignal?.removeEventListener("abort", stop);
		const left = (waitedFor.get(id) ?? 1) - 1;
		if (left === 0) waitedFor.delete(id);
		else waitedFor.set(id, left);
		// Owed, and nobody waiting for it now: it is added to the parent when it comes, or now if it already has.
		if (owed) watch(chat, id);
	}
}

/** The answer a sub-chat owes its parent, if any: its submission. */
export async function owedBy(read: DocumentReader, chat: number, context: Context): Promise<SubmissionId | undefined> {
	return (await read.snapshot(Library, context))?.conversations[String(chat)]?.answerOwed as SubmissionId | undefined;
}

/** Add an owed answer to the parent once it comes, unless a call is waiting for it then. */
function watch(chat: number, submission: number): void {
	if (watching.has(submission)) return;
	const running = engine!;
	watching.add(submission);
	void (async () => {
		try {
			const handle = await running.harness().submission(submission as unknown as SubmissionId, running.context());
			if (handle === undefined) return;
			const settled = await handle.wait(running.context());
			watching.delete(submission);
			if (waitedFor.has(submission)) return;
			await deliver(chat, submission, settled);
		} catch (error) {
			running.log("could not deliver the answer of sub-chat", chat, error instanceof Error ? error.message : error);
		} finally {
			watching.delete(submission);
		}
	})();
}

/** What the agent is given when a sub-chat's answer comes after it stopped waiting for it. */
async function owedWords(chat: number, settled: SettledSubmissionRecord): Promise<string> {
	const meta = engine!.library().conversations[String(chat)];
	const name = host!.agent(meta?.agentId)?.name ?? "The agent";
	const title = meta?.title ?? "";
	if (settled.status !== "done" || settled.type !== "input") {
		const reason = "reason" in settled && settled.reason !== undefined ? String(settled.reason) : undefined;
		const detail = "detail" in settled && settled.detail !== undefined ? String(settled.detail) : undefined;
		return `[Sub-chat ${chat}, “${title}”, ended after you stopped waiting for it.] ${unfinished(name, chat, reason, detail)}`;
	}
	const answer = await host!.answerText(chat as unknown as ConversationId, settled.answer);
	return `[Sub-chat ${chat}, “${title}”, with ${name}, answered after you stopped waiting for it:]\n\n${answer}\n\n(To continue it, call delegate again with chat: ${chat}.)`;
}

/** Add an owed answer to the parent's conversation, once: only if it is still owed, and clearing that in the same commit. */
async function deliver(chat: number, submission: number, settled: SettledSubmissionRecord): Promise<void> {
	const running = engine!;
	// Whether it is still owed is decided in the commit: the engine's copy of the library can be a moment behind.
	const meta = running.library().conversations[String(chat)];
	if (meta?.parent === undefined) return;
	const words = await owedWords(chat, settled);
	const parent = await running.harness().conversation(meta.parent as unknown as ConversationId, running.context());
	const answered = settled.status === "done";
	await running.harness().commit(async (tx) => {
		const library = await tx.doc(Library);
		const stored = library.conversations[String(chat)];
		if (stored?.answerOwed !== submission) return;
		// Into the parent's context as the person's side of it, without starting an answer: placed at once when the parent
		// is idle, and after its current round when it is working.
		if (parent !== undefined && library.conversations[String(meta.parent)]?.deleted !== true) {
			await parent.submit(tx, {
				type: "write",
				entry: { kind: OWED_ANSWER_ENTRY, data: { chat, title: stored.title, answered }, model: [{ role: "user", content: [{ type: "text", text: words }], timestamp: Date.now() }] },
			});
		}
		delete stored.answerOwed;
	}, running.context());
}

/** What the transcript shows where an owed answer was added. */
export function owedMarker(data: unknown): string {
	const entry = (data !== null && typeof data === "object" ? data : {}) as { chat?: unknown; title?: unknown; answered?: unknown };
	const chat = typeof entry.chat === "number" ? ` ${entry.chat}` : "";
	const title = typeof entry.title === "string" && entry.title.trim() !== "" ? ` (“${entry.title.trim()}”)` : "";
	return entry.answered === false
		? `Sub-chat${chat}${title} ended without an answer after the agent stopped waiting for it; the agent was told why`
		: `Sub-chat${chat}${title} answered after the agent stopped waiting for it; the agent was given its answer`;
}

/**
 * The person stopped a conversation: its sub-chats whose waits a message ended are its work too, and the agent has no
 * way to stop them itself, so they are stopped with it. Their answers, that they did not finish, are added as owed.
 */
export function stopLetGo(parent: number): void {
	for (const [key, meta] of Object.entries(engine?.library().conversations ?? {})) {
		if (meta.parent === parent && meta.answerOwed !== undefined) stopChat(Number(key));
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
	const details = (slot.details ?? {}) as { conversationId?: unknown; agentName?: unknown };
	const chat = typeof details.conversationId === "number" ? details.conversationId : typeof args.chat === "number" ? args.chat : undefined;
	const who = typeof details.agentName === "string" && details.agentName !== "" ? `${details.agentName}'s sub-chat` : "a sub-chat";
	return `the wait for ${who}${chat === undefined ? "" : ` ${chat}`}`;
}

/**
 * What a message sent to steer the conversation now would wait for, while it is working: `holds`, the calls it is placed
 * after, each in words; and `ends`, the waits it would end. No holds: it reaches the agent once its current step ends.
 */
export function messageWaits(view: ConversationView, conversationId: number, approvals: { callId: string; conversationId: number }[]): { holds: string[]; ends: string[] } | null {
	const live = (view.docs["pi.live"] ?? {}) as { run?: unknown; tools?: Slot[] };
	if (live.run === undefined) return null;
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
	host = given;
	engine = running;
	return {
		state: (view) => {
			const id = view.conversation.id as unknown as number;
			return { messageWaits: messageWaits(view, id, given.inbox.list().filter((item) => item.kind === "approval")) };
		},
		// Answers owed when the last engine stopped are watched for again; the calls that waited were run again too.
		start: async () => {
			for (const [key, meta] of Object.entries(running.library().conversations)) {
				if (meta.answerOwed !== undefined) watch(Number(key), meta.answerOwed);
			}
		},
	};
};
