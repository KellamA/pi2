// The events every app is sent about the engine as a whole (#483, moved from main.ts): the library (`libraryEvent`,
// the conversations in the sidebar and the Archive), the agents, the Inbox, and Activity (`activityEvent`, sent at most
// four times a second by `announceActivity`). Each is made from the live indexes (indexes.ts) as they are when it is
// sent. main.ts hands over what they use of the engine (`wireAppEvents`).

import { isArchived, isDeleted, isPutAway } from "./archive.ts";
import { BUILT_IN_TOOLS } from "./builtins.ts";
import { isChat } from "./chat.ts";
import { broadcast, coalesced } from "./clients.ts";
import type { Host } from "./extensions.ts";
import { agents, busyConversations, chatOf, library, rootOf, since, working } from "./indexes.ts";
import { orchestratorRole } from "./orchestrator.ts";
import { runningCommands } from "./running.ts";
import { agentOf, type Inbox, runsAs } from "./state.ts";

// What this file uses of the running engine, handed over by main.ts once it has them (`wireAppEvents`).
let settings: { autoArchiveDays?: number | null };
let inbox: Inbox;
let host: Host;

export function wireAppEvents(parts: { settings: typeof settings; inbox: Inbox; host: Host }): void {
	({ settings, inbox, host } = parts);
}

export const announceActivity = coalesced(() => activityEvent());

export function libraryEvent() {
	const conversations = Object.entries(library.conversations)
		// Sub-chats are listed too, pointing at their parent, unless either of them was archived or deleted. A chat's
		// versions are not: the chat stands for them.
		.filter(([, meta]) => meta.version !== true && !isPutAway(meta) && (meta.parent === undefined || !isPutAway(library.conversations[String(meta.parent)])))
		.map(([id, meta]) => ({
			id: Number(id),
			title: meta.title,
			createdAt: meta.createdAt,
			updatedAt: meta.updatedAt,
			// A conversation shows as working while it or any of its sub-chats is; a sub-chat only for itself.
			busy: meta.parent === undefined ? busyConversations.has(Number(id)) : working.has(Number(id)),
			agentId: meta.agentId ?? null,
			parent: meta.parent ?? null,
			// Chat mode lists only chats, and the agent view never does (chat.ts).
			chat: isChat(meta),
			pinned: meta.pinned === true,
			// Continue with an Agent (#289): the chat a conversation was continued from, and the conversations a chat was
			// continued in, leaving out any deleted since.
			continuedFrom: meta.continuedFrom ?? null,
			continuedIn: (meta.continuedIn ?? []).filter((other) => library.conversations[String(other)] !== undefined && !isDeleted(library.conversations[String(other)])),
			// Allow everything as this conversation took it at its latest message; the app warns while it or its agent has it.
			allowEverything: meta.allowEverything === true,
			// The project it belongs to (projects.ts), archived or not.
			projectId: meta.projectId ?? null,
			// The agent it runs as now (state.ts, `runsAs`): its `agentId`, but for a conversation carried over.
			runsAs: runsAs(meta, agents) ?? null,
			// A project's current or earlier conversation with its orchestrator (orchestrator.ts), or null.
			orchestrator: orchestratorRole(Number(id)),
			// The conversation with the orchestrator this one was started fresh from.
			freshFrom: meta.freshFrom ?? null,
		}))
		.sort((a, b) => b.updatedAt - a.updatedAt);
	// The Archive: archived conversations, and sub-chats an agent archived on their own while their conversation stays in
	// the sidebar. A sub-chat of an archived conversation is reached through that conversation.
	const archived = Object.entries(library.conversations)
		.filter(([, meta]) => meta.version !== true && isArchived(meta) && (meta.parent === undefined || !isPutAway(library.conversations[String(meta.parent)])))
		.map(([id, meta]) => ({
			id: Number(id),
			title: meta.title,
			createdAt: meta.createdAt,
			updatedAt: meta.updatedAt,
			archivedAt: meta.archivedAt as number,
			agentId: meta.agentId ?? null,
			subChats: Object.values(library.conversations).filter((child) => child.parent === Number(id) && child.version !== true && !isDeleted(child)).length,
			parent: meta.parent ?? null,
			parentTitle: meta.parent === undefined ? null : (library.conversations[String(meta.parent)]?.title ?? ""),
			chat: isChat(meta),
			pinned: meta.pinned === true,
			projectId: meta.projectId ?? null,
		}))
		.sort((a, b) => b.archivedAt - a.archivedAt);
	return { event: "library", conversations, archived, autoArchiveDays: settings.autoArchiveDays ?? null };
}

export function agentsEvent() {
	// The list of built-in tools goes with them, so the settings show what the engine offers without a copy of their own.
	return { event: "agents", agents: Object.values(agents).sort((a, b) => a.createdAt - b.createdAt), builtInTools: BUILT_IN_TOOLS };
}

/** Everything waiting on the person, with enough context to answer from anywhere in the app. */
export function inboxEvent() {
	const items = inbox.list().map((item) => {
		// A question from a chat's version is the chat's: the app shows the chat under its own id.
		const conversationId = chatOf(item.conversationId);
		const meta = library.conversations[String(conversationId)];
		const root = meta?.parent ?? conversationId;
		return {
			...item,
			conversationId,
			title: meta?.title ?? "",
			agentName: agentOf(meta, agents)?.name ?? null,
			rootConversationId: root,
			rootTitle: library.conversations[String(root)]?.title ?? "",
		};
	});
	return { event: "inbox", items };
}
/** Send the Inbox again, and tell the features that show it (Needs you, needs.ts). */
export function announceInbox() {
	broadcast(inboxEvent());
	for (const feature of host.features) feature.inboxChanged?.();
}

/** What is running right now, one row per conversation with live work; subagents point at their parent. */
export function activityEvent() {
	const waiting = new Set(inbox.list().map((item) => item.conversationId));
	const runs = [...working]
		.map((id) => {
			// A chat's version shows as the chat, which is what the app can open.
			const shown = chatOf(id);
			const meta = library.conversations[String(shown)];
			return {
				conversationId: shown,
				parent: meta?.parent ?? null,
				rootConversationId: rootOf(id),
				title: meta?.title ?? "",
				agentId: meta?.agentId ?? null,
				projectId: meta?.projectId ?? null,
				// The agent it runs as now (state.ts, `runsAs`).
				runsAs: runsAs(meta, agents) ?? null,
				// A chat answering is shown as a chat, not as an agent's work.
				chat: isChat(meta),
				status: waiting.has(id) ? "waiting" : "working",
				since: since.get(id) ?? Date.now(),
				// What features add (a wait for a provider's limit, say).
				...Object.assign({}, ...host.features.map((feature) => feature.activity?.(id) ?? {})),
				// Its shell commands running in the foreground, with their clocks (running.ts).
				commands: runningCommands.of(id),
			};
		})
		.sort((x, y) => x.since - y.since);
	return { event: "activity", runs };
}
