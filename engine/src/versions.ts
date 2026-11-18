// Versions of a chat (#285): Try Again under an answer, Edit on the person's own message, and the small control that
// steps between the versions a point has, with the conversation below following the version shown.
//
// Every version after the first is a fork (pi durable's `conversation.fork`), made at the entry the versions part at:
// it sees the conversation up to that entry, compactions included, starts with the agent and code mode's store as they
// were there, and counts its own usage from nothing, so nothing is counted twice. A fork is a conversation of its own,
// kept out of sight: its record in the library has `parent` (the chat) and `version: true`, so that the chat's busy
// state, usage, archiving and deleting take its versions with it, as they take a conversation's sub-chats, and the
// sidebar, the Archive and search leave them out.
//
// The chat keeps its id. A document says which version is current; requests on the chat act on that version, and the
// app's conversation event for the chat follows it (main.ts). A fork is always made from the conversation that owns the
// entry, so the versions at a point are that conversation's own continuation and the forks made there, oldest first.
//
// Only for chats: an agent's conversation may have changed files that going back would not undo.

import type { Context } from "@earendil-works/chord/context";
import { AgentDoc, type Conversation, type ConversationId, defineDoc, type EntryId, type EntryRecord, type Harness, type Tx, UserEntry } from "@earendil-works/pi-durable";
import { isAttachmentBlock, readUserEntryData, USER_ENTRY_KIND } from "./attachments.ts";
import { isChat } from "./chat.ts";
import { Library, type Meta, type ModelRef } from "./state.ts";

/** One version of a chat: where it parts from the one it was made from (`at`, an entry of `from`), and when it was last shown. */
export type Line = {
	/** The conversation it was forked from; null for the chat itself. */
	from: number | null;
	/** The entry of `from` it sees up to; null for a version that starts afresh (the first message edited), and for the chat itself. */
	at: number | null;
	createdAt: number;
	/** Bigger for the version shown more recently: stepping to a point's version shows the one under it last shown. */
	shown: number;
};
export type ChatVersions = { current: number; seq: number; lines: Record<string, Line> };

/** Which version of each chat is current, and how its versions part. A chat with one version has no record. */
export const Versions = defineDoc<{ chats: Record<string, ChatVersions> }>({
	kind: "pi2.versions",
	version: 1,
	scope: "session",
	initial: () => ({ chats: {} }),
	checkpointWhen: () => true,
});

/** A point where versions part, on the path shown: after entry `after` (null: before the first message), version `index` of `count`. */
export type Point = { after: number | null; index: number; count: number };

const ROOT: Line = { from: null, at: null, createdAt: 0, shown: 0 };

function lineOf(chat: ChatVersions | undefined, chatId: number, id: number): Line | undefined {
	return chat?.lines[String(id)] ?? (id === chatId ? ROOT : undefined);
}

/** The version shown, and the ones it was made from, back to the chat itself. */
export function chainOf(chat: ChatVersions | undefined, chatId: number): number[] {
	const chain: number[] = [];
	for (let id: number | null = chat?.current ?? chatId; id !== null && !chain.includes(id); id = lineOf(chat, chatId, id)?.from ?? null) chain.push(id);
	return chain;
}

const forksAt = (chat: ChatVersions | undefined, owner: number, at: number | null) =>
	Object.entries(chat?.lines ?? {})
		.filter(([, line]) => line.from === owner && line.at === at)
		.sort(([a, x], [b, y]) => x.createdAt - y.createdAt || Number(a) - Number(b))
		.map(([id]) => Number(id));

/** The versions at a point of `owner`: its own continuation first, then the forks made there, oldest first. */
export function alternatives(chat: ChatVersions | undefined, owner: number, at: number | null): number[] {
	return [owner, ...forksAt(chat, owner, at)];
}

/** Every point on the path shown where there is more than one version, in the order they come. `visible` holds the path's entries. */
export function points(chat: ChatVersions | undefined, chatId: number, visible: ReadonlySet<number>): Point[] {
	if (chat === undefined) return [];
	const chain = chainOf(chat, chatId);
	const seen = new Set<string>();
	const found: Point[] = [];
	for (const line of Object.values(chat.lines)) {
		if (line.from === null) continue;
		const key = `${line.from}/${line.at}`;
		if (seen.has(key)) continue;
		seen.add(key);
		// A fresh start parts before the chat's first message; any other point is an entry of the path.
		if (line.at === null ? line.from !== chatId : !visible.has(line.at)) continue;
		const versions = alternatives(chat, line.from, line.at);
		const shown = chain.find((id) => chat.lines[String(id)]?.from === line.from && chat.lines[String(id)]?.at === line.at);
		found.push({ after: line.at, index: shown === undefined ? 0 : versions.indexOf(shown), count: versions.length });
	}
	return found.sort((x, y) => (x.after ?? -1) - (y.after ?? -1));
}

/** The version to show for `choice` at a point of `owner`: the one under it shown last, so the conversation below is as it was left. */
export function landing(chat: ChatVersions | undefined, chatId: number, owner: number, at: number | null, choice: number): number {
	const below = (id: number): number[] => [id, ...Object.entries(chat?.lines ?? {}).flatMap(([other, line]) => (line.from === id && Number(other) !== id ? below(Number(other)) : []))];
	// The owner's own continuation holds the owner and whatever parts from it after the point; other forks at the point are its siblings.
	const candidates =
		choice !== owner
			? below(choice)
			: [owner, ...Object.entries(chat?.lines ?? {}).flatMap(([id, line]) => (line.from === owner && line.at !== null && (at === null || line.at > at) ? below(Number(id)) : []))];
	return candidates.reduce((best, id) => ((lineOf(chat, chatId, id)?.shown ?? 0) > (lineOf(chat, chatId, best)?.shown ?? 0) ? id : best));
}

/** The chat a conversation is a version of, or the conversation itself. */
export function chatIdOf(conversations: Record<string, Meta>, id: number): number {
	const meta = conversations[String(id)];
	return meta?.version === true && meta.parent !== undefined ? meta.parent : id;
}

/** Whether Try Again, Edit and versions are offered for a conversation: only a chat (chat.ts). */
export function versionsAllowed(meta: Meta | undefined): boolean {
	return isChat(meta) && meta?.parent === undefined;
}

/** Whether an entry is a message the person sent: plain, or with attachments. */
export const isUserMessage = (entry: EntryRecord | undefined): entry is EntryRecord => entry !== undefined && (UserEntry.is(entry) || entry.kind === USER_ENTRY_KIND);

/** What an edited message sends: the new text, with whatever the old one had attached. */
export function editedInput(original: EntryRecord, text: string): { content: unknown; entry?: { kind: string; data: { text: string; attachments: unknown[] } } } {
	const own = readUserEntryData(original);
	if (own === undefined || own.attachments.length === 0) {
		if (text.trim() === "") throw new Error("The message is empty");
		return { content: text };
	}
	const blocks = (original.model?.[0] as { content?: unknown } | undefined)?.content;
	const kept = Array.isArray(blocks) ? blocks.filter((block) => block?.type === "image" || (block?.type === "text" && typeof block.text === "string" && isAttachmentBlock(block.text))) : [];
	return {
		content: [...(text.trim() === "" ? [] : [{ type: "text", text }]), ...kept],
		entry: { kind: USER_ENTRY_KIND, data: { text: text.trim() === "" ? "" : text, attachments: own.attachments } },
	};
}

/** What the requests need of the engine. */
export type VersionsHost = {
	harness: Harness;
	context: Context;
	library(): Record<string, Meta>;
	versions(): { chats: Record<string, ChatVersions> };
	/** Whether the conversation has work running. */
	busy(id: number): boolean;
	/** Refuses, with a plain message, what may not start now: the chat is archived or deleted, or today's budget is spent. */
	mayStart(chatId: number): void;
	/** Whether a model can be used. */
	modelExists(model: ModelRef): boolean;
	/** Brings a conversation's tools in line with its agent's settings, as before any message. */
	syncTools(conv: Conversation): Promise<void>;
	/** The chat was used now. */
	touched(chatId: number): Promise<void>;
};

const integer = (value: unknown, name: string): number => {
	if (typeof value !== "number" || !Number.isInteger(value)) throw new Error(`${name} must be a whole number`);
	return value;
};

export function versionRequests(host: VersionsHost): Record<string, (params: Record<string, unknown>) => Promise<unknown>> {
	const { harness, context } = host;

	async function open(id: number): Promise<Conversation> {
		const conv = await harness.conversation(id as unknown as ConversationId, context);
		if (conv === undefined) throw new Error(`Unknown conversation: ${id}`);
		return conv;
	}

	/** The chat a request names, and its version shown. */
	async function chatOf(params: Record<string, unknown>) {
		const chatId = integer(params.id, "id");
		const meta = host.library()[String(chatId)];
		if (meta === undefined) throw new Error(`Unknown conversation: ${chatId}`);
		if (!versionsAllowed(meta)) throw new Error("Try Again, Edit and versions are for chats only: an agent's conversation may have changed files that going back would not undo.");
		const chat = host.versions().chats[String(chatId)];
		return { chatId, chat, current: await open(chat?.current ?? chatId) };
	}

	/** An entry of the version shown, or a refusal: one that is not on its path is not in view. */
	async function entryOf(conv: Conversation, id: number): Promise<EntryRecord> {
		const entry = (await conv.entries({ minEntryId: id as unknown as EntryId, maxEntryId: id as unknown as EntryId }, 1, undefined, context)).items[0];
		if (entry === undefined) throw new Error("That message is not in the version shown");
		return entry;
	}

	/** The person's message an answer answers: the newest of theirs at or before it. */
	async function messageFor(conv: Conversation, id: number): Promise<EntryRecord> {
		let cursor: unknown;
		for (let page = 0; page < 10; page++) {
			const batch = await conv.entries({ maxEntryId: id as unknown as EntryId, order: "descending" }, 200, cursor as never, context);
			const found = batch.items.find(isUserMessage);
			if (found !== undefined) return found;
			cursor = (batch as { next?: unknown }).next;
			if (cursor === undefined) break;
		}
		throw new Error("There is no message of yours before that answer to answer again");
	}

	/** Stops an answer being written, as Stop does: what it wrote so far stays, interrupted, in its version. */
	async function settle(conv: Conversation): Promise<void> {
		if (host.busy(conv.id as unknown as number)) await conv.abort(context);
	}

	/**
	 * A new version, current from its first commit: a fork of `owner` at `at`, or a fresh start when `at` is null. It
	 * starts with the settings of the version shown (model, thinking, tools), or `model` when one was chosen.
	 */
	async function newVersion(chatId: number, current: Conversation, owner: number, at: number | null, model?: ModelRef): Promise<Conversation> {
		const settings = JSON.parse(JSON.stringify((await harness.snapshot(AgentDoc, current.id, context)) ?? {})) as Record<string, unknown>;
		if (model !== undefined) settings.model = { provider: model.provider, modelId: model.modelId };
		const now = Date.now();
		const init = async (tx: Tx, id: ConversationId) => {
			const agent = (await tx.doc(AgentDoc, id)) as Record<string, unknown>;
			for (const key of Object.keys(agent)) if (!(key in settings)) delete agent[key];
			Object.assign(agent, settings);
			const library = (await tx.doc(Library)).conversations;
			const chatMeta = library[String(chatId)];
			if (chatMeta === undefined) throw new Error("That conversation was deleted");
			const { archivedAt: _a, deleted: _d, archived: _o, renamed: _r, ...kept } = JSON.parse(JSON.stringify(chatMeta)) as Meta;
			library[String(id)] = { ...kept, createdAt: now, updatedAt: now, parent: chatId, version: true };
			const doc = await tx.doc(Versions);
			doc.chats[String(chatId)] ??= { current: chatId, seq: 0, lines: { [String(chatId)]: { from: null, at: null, createdAt: chatMeta.createdAt, shown: 0 } } };
			const chat = doc.chats[String(chatId)]!;
			chat.seq += 1;
			chat.lines[String(id)] = { from: owner, at, createdAt: now, shown: chat.seq };
			chat.current = id as unknown as number;
		};
		const ownerless = { kind: "ownerless" as const };
		const made = at === null ? await harness.createConversation({ ownership: ownerless, init }, context) : await (await open(owner)).fork(at as unknown as EntryId, { ownership: ownerless, init }, context);
		await host.syncTools(made);
		return made;
	}

	return {
		/** Answers a message again, as a new version, optionally with another model. `entryId`: the answer, or the message. */
		"conversation.retry": async (params) => {
			const { chatId, chat, current } = await chatOf(params);
			host.mayStart(chatId);
			let model: ModelRef | undefined;
			if (params.model !== undefined && params.model !== null) {
				model = params.model as ModelRef;
				if (typeof model?.provider !== "string" || typeof model.modelId !== "string" || !host.modelExists(model)) throw new Error(`Unknown model: ${String(model?.provider)}/${String(model?.modelId)}`);
			}
			const message = await messageFor(current, integer(params.entryId, "entryId"));
			await settle(current);
			const owner = message.conversationId as unknown as number;
			if (lineOf(chat, chatId, owner) === undefined) throw new Error("That message is not in the version shown");
			// Nothing came after the message (its answer failed before a word of it was kept): answer it in place.
			const after = await current.entries({ minEntryId: ((message.id as unknown as number) + 1) as unknown as EntryId, order: "ascending" }, 1, undefined, context);
			let target: Conversation;
			if (owner === (current.id as unknown as number) && after.items.length === 0) {
				target = current;
				if (model !== undefined) await current.configure({ model }, context);
				await host.syncTools(current);
			} else target = await newVersion(chatId, current, owner, message.id as unknown as number, model);
			await target.submit({ type: "continue" }, context);
			await host.touched(chatId);
			return { id: chatId, version: target.id };
		},
		/** Sends an edited message in place of one of the person's, as a new version: the earlier one is kept. */
		"conversation.edit": async (params) => {
			const { chatId, chat, current } = await chatOf(params);
			host.mayStart(chatId);
			if (typeof params.text !== "string") throw new Error("Missing text");
			const original = await entryOf(current, integer(params.entryId, "entryId"));
			if (!isUserMessage(original)) throw new Error("Only your own messages can be edited");
			const input = editedInput(original, params.text);
			await settle(current);
			// The versions part at the entry before the message; a first message has none, and starts afresh.
			const before = (await current.entries({ maxEntryId: ((original.id as unknown as number) - 1) as unknown as EntryId, order: "descending" }, 1, undefined, context)).items[0];
			const owner = before === undefined ? chatId : (before.conversationId as unknown as number);
			if (lineOf(chat, chatId, owner) === undefined) throw new Error("That message is not in the version shown");
			const target = await newVersion(chatId, current, owner, before === undefined ? null : (before.id as unknown as number));
			await target.submit({ type: "input", content: input.content as string, ...(input.entry === undefined ? {} : { entry: input.entry as never }) }, context);
			await host.touched(chatId);
			return { id: chatId, version: target.id };
		},
		/** Shows another version at a point: `after` the entry the versions part at (null: the first message), `index` among them. */
		"conversation.version": async (params) => {
			const { chatId, chat, current } = await chatOf(params);
			if (host.busy(current.id as unknown as number)) throw new Error("Wait until the answer is finished, or stop it, before going to another version.");
			const after = params.after === null || params.after === undefined ? null : integer(params.after, "after");
			const owner = after === null ? chatId : ((await entryOf(current, after)).conversationId as unknown as number);
			if (lineOf(chat, chatId, owner) === undefined) throw new Error("That message is not in the version shown");
			const versions = alternatives(chat, owner, after);
			const index = integer(params.index, "index");
			if (versions.length < 2 || index < 0 || index >= versions.length) throw new Error("There is no such version");
			const target = landing(chat, chatId, owner, after, versions[index]!);
			await harness.commit(async (tx) => {
				const record = (await tx.doc(Versions)).chats[String(chatId)];
				if (record === undefined || record.lines[String(target)] === undefined) throw new Error("There is no such version");
				record.seq += 1;
				record.lines[String(target)]!.shown = record.seq;
				record.current = target;
			}, context);
			return { id: chatId, version: target };
		},
	};
}
