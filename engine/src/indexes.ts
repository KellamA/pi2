// What the engine knows now of its documents, kept up to date by main.ts's watches (#483, moved from main.ts): the
// library (every conversation's record), the agents, which version each chat shows, and which conversations have work
// running. They are read where they are needed as imports, which follow every change; only main.ts's watches change
// them, through the setters at the end.

import type { ConversationId } from "@earendil-works/pi-durable";
import type { AgentProfile, Meta } from "./state.ts";
import { type ChatVersions, chatIdOf } from "./versions.ts";

export let library: { conversations: Record<string, Meta> } = { conversations: {} };
export let agents: Record<string, AgentProfile> = {};

/** Which version of each chat is shown (versions.ts); kept up to date by a watch in main.ts. */
export let versions: { chats: Record<string, ChatVersions> } = { chats: {} };

/** The chat a version belongs to, or the conversation itself. */
export function chatOf(id: number | ConversationId): number {
	return chatIdOf(library.conversations, id as number);
}
/** A sub-chat, handed work by another conversation; not a chat's version. */
export function isSubChat(meta: Meta | undefined): boolean {
	return meta?.parent !== undefined && meta.version !== true;
}

export let busyConversations = new Set<number>();
/** Every conversation with live work, sub-chats included. */
export let working = new Set<number>();

type Graph = { tasks: Record<string, { conversationId?: unknown }> };
/** The conversation `id` belongs to: itself, or the one whose sub-chat it is. */
export const rootOf = (id: number): number => library.conversations[String(id)]?.parent ?? id;
export const conversationsWithWork = (graph: Graph) => new Set(Object.values(graph.tasks).map((task) => task.conversationId as number));

/** When each conversation's current work was first seen, for "running for…" in the app. */
export const since = new Map<number, number>();
export const refreshBusy = () => {
	const now = Date.now();
	for (const id of working) if (!since.has(id)) since.set(id, now);
	for (const id of [...since.keys()]) if (!working.has(id)) since.delete(id);
	busyConversations = new Set([...working].map(rootOf));
};

export function setLibrary(value: typeof library): void {
	library = value;
}
export function setAgents(value: typeof agents): void {
	agents = value;
}
export function setVersions(value: typeof versions): void {
	versions = value;
}
export function setWorking(value: typeof working): void {
	working = value;
}
