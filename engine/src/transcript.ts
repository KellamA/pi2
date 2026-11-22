// A conversation's entries as the app is sent them (#483, moved from main.ts): each stored entry made into an item of
// the transcript (`toItem`), with the text, pictures and tool calls it holds. Plain functions of an entry; the
// conversation's state and its events are conversationevents.ts's.

import type { EntryRecord } from "@earendil-works/pi-durable";
import { type AttachmentNote, readUserEntryData } from "./attachments.ts";
import { BACKGROUND_ENTRY, backgroundMarker, backgroundMarkerDetails } from "./background.ts";
import { type CompactionMarker, compactionMarker } from "./compaction.ts";
import { githubItem } from "./github.ts";
import { CARRY_ON_ENTRY } from "./limitwait.ts";
import { LOCAL_RETRY_ENTRY } from "./localrun.ts";
import { NETWORK_RESUMED_ENTRY } from "./networkwait.ts";
import { projectItem } from "./orchestrator.ts";
import { SUBCHATS_ENTRY, subChatsMarker } from "./subchats.ts";
import { THINKING_RETRY_ENTRY } from "./thinkingretry.ts";
import { WAKE_ENTRY, WAKE_NOTE, wakeMarker, wakeMarkerDetails, wakeNoteMarker } from "./wakes.ts";
import { SETUP_ENTRY, setupItem } from "./worktrees.ts";

export function textOf(content: unknown, markImages = true): string {
	if (typeof content === "string") return content;
	if (!Array.isArray(content)) return "";
	return content.map((block) => (block?.type === "text" && typeof block.text === "string" ? block.text : block?.type === "image" && markImages ? "[image]" : "")).join("");
}

export function imagesOf(content: unknown): { data: string; mimeType: string }[] {
	if (!Array.isArray(content)) return [];
	return content.flatMap((block) => (block?.type === "image" && typeof block.data === "string" && typeof block.mimeType === "string" ? [{ data: block.data, mimeType: block.mimeType }] : []));
}

type ToolCall = { callId: string; name: string; arguments: unknown };
export type Item =
	| { id: number; kind: "user"; text: string; attachments: AttachmentNote[]; images: number }
	| { id: number; kind: "assistant"; text: string; thinking: string; toolCalls: ToolCall[]; stop: string; error: string | null; model: string | null }
	| { id: number; kind: "tool"; callId: string; name: string; text: string; isError: boolean; details: unknown; images: number }
	| { id: number; kind: "marker"; text: string; details?: { background?: { id: string }; wake?: { text: string }; answers?: { need: string; ended: string; label?: string }[]; compaction?: CompactionMarker } }
	| ReturnType<typeof setupItem>;

export type AssistantLike = { content?: unknown; stopReason?: string; errorMessage?: string; model?: string };

export function assistantParts(message: AssistantLike): { text: string; thinking: string; toolCalls: ToolCall[] } {
	const blocks = Array.isArray(message.content) ? message.content : [];
	return {
		text: textOf(message.content),
		thinking: blocks.map((b) => (b?.type === "thinking" && typeof b.thinking === "string" ? b.thinking : "")).join(""),
		toolCalls: blocks.filter((b) => b?.type === "toolCall").map((b) => ({ callId: String(b.id), name: String(b.name), arguments: b.arguments ?? {} })),
	};
}

/** A tool result's `details`, wherever this version of pi durable keeps them on the entry. */
function detailsOf(entry: EntryRecord): unknown {
	const data = entry.data as { details?: unknown } | undefined;
	const message = entry.model?.[0] as { details?: unknown } | undefined;
	return data?.details ?? message?.details ?? null;
}

/**
 * Which Needs you items a wake answered, and how (the wake kind `answer`, needs.ts): the item's id and a few words
 * ("was allowed"), for the conversation's page to turn the card that asked into a line with its outcome (#474).
 */
export function answeredNeeds(data: unknown): { need: string; ended: string; label?: string }[] {
	return wakeAnswerItems(data)
		.filter((item) => typeof item.ref === "string" && typeof item.ended === "string")
		.map((item) => ({ need: item.ref as string, ended: item.ended as string, ...(typeof item.label === "string" ? { label: item.label } : {}) }));
}

/** A wake's data items of the answer kind, as stored (wakes.ts): unchecked apart from their kind. */
function wakeAnswerItems(data: unknown): { ref: unknown; ended: unknown; label: unknown }[] {
	const items = data !== null && typeof data === "object" && Array.isArray((data as { items?: unknown }).items) ? (data as { items: unknown[] }).items : [];
	return items.filter((item): item is { ref: unknown; ended: unknown; label: unknown } => item !== null && typeof item === "object" && (item as { kind?: unknown }).kind === "answer");
}

/** The label a wake's data gives the Needs you item `need` ("the request “…”"), where it has one. */
export function wakeLabel(data: unknown, need: string): string | undefined {
	const item = wakeAnswerItems(data).find((one) => one.ref === need);
	return typeof item?.label === "string" ? item.label : undefined;
}

export function toItem(entry: EntryRecord): Item | undefined {
	const id = entry.id as unknown as number;
	if (entry.kind === "pi.reset") return { id, kind: "marker", text: "Context reset" };
	if (entry.kind === "pi.compaction") return { id, kind: "marker", ...compactionMarker(entry) };
	if (entry.kind === "pi2.compactionTooShort") return { id, kind: "marker", text: "There is too little here to summarise yet." };
	if (entry.kind === SETUP_ENTRY) return setupItem(id, entry.data);
	if (entry.kind === THINKING_RETRY_ENTRY || entry.kind === CARRY_ON_ENTRY || entry.kind === LOCAL_RETRY_ENTRY || entry.kind === NETWORK_RESUMED_ENTRY) return { id, kind: "marker", text: (entry.data as { text: string }).text };
	if (entry.kind === BACKGROUND_ENTRY) {
		// With the command's id, so the line can open the window with its output.
		const details = backgroundMarkerDetails(entry.data);
		return { id, kind: "marker", text: backgroundMarker(entry.data), ...(details === undefined ? {} : { details }) };
	}
	if (entry.kind === SUBCHATS_ENTRY) return { id, kind: "marker", text: subChatsMarker(entry.data) };
	// Show the same model input behind the line, including wakes stored before the row could open (#318).
	if (entry.kind === WAKE_ENTRY) {
		const content = textOf((entry.model?.[0] as { content?: unknown } | undefined)?.content);
		const answers = answeredNeeds(entry.data);
		const details = { ...wakeMarkerDetails(entry.data), ...(answers.length > 0 ? { answers } : {}), wake: { text: content } };
		return { id, kind: "marker", text: wakeMarker(entry.data), details };
	}
	if (entry.kind === WAKE_NOTE) return { id, kind: "marker", text: wakeNoteMarker(entry.data) };
	// What a project's orchestrator is told, and the line in a conversation the person wrote to (orchestrator.ts).
	const told = entry.kind.startsWith("pi2.") ? (projectItem(entry) ?? githubItem(entry)) : undefined;
	if (told !== undefined) return told;
	const message = entry.model?.[0] as (AssistantLike & { role?: string; toolCallId?: string; toolName?: string; isError?: boolean }) | undefined;
	if (message === undefined) return undefined;
	switch (message.role) {
		case "user": {
			// A message sent with attachments recorded what the person typed apart from the files' contents. Its pictures
			// are counted, as a tool result's are, and fetched one at a time.
			const own = readUserEntryData(entry);
			return { id, kind: "user", text: own?.text ?? textOf(message.content), attachments: own?.attachments ?? [], images: imagesOf(message.content).length };
		}
		case "assistant":
			return { id, kind: "assistant", ...assistantParts(message), stop: message.stopReason ?? "stop", error: message.errorMessage ?? null, model: message.model ?? null };
		case "toolResult":
			// Pictures are not sent with the transcript: the app is told how many there are and fetches one when it shows it.
			return { id, kind: "tool", callId: String(message.toolCallId), name: String(message.toolName), text: textOf(message.content, false), isError: message.isError === true, details: detailsOf(entry), images: imagesOf(message.content).length };
		default:
			return undefined;
	}
}
