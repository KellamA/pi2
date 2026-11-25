// What the app is sent of a conversation (#483, moved from main.ts): its state (`stateOf`: whether it works, its
// tools' slots, its context, its model, what features add), the `conversation` events that keep an open one up to
// date (`subscribe`, newest first and in parts as opening.ts says), and the requests that read one: opening and closing
// it, older entries, a picture, an export, and search. Its entries as items are transcript.ts's. main.ts hands over
// what they use of the engine (`wireConversationEvents`).

import type { Context } from "@earendil-works/chord/context";
import type { Conversation, ConversationView, EntryRecord } from "@earendil-works/pi-durable";
import { isArchived, isDeleted } from "./archive.ts";
import { describeAttachments, readUserEntryData } from "./attachments.ts";
import { linesOf } from "./changes.ts";
import { isChat } from "./chat.ts";
import { type Client, send, type Subscription } from "./clients.ts";
import { compactionErrorText } from "./compaction.ts";
import { KEY_HIDDEN, maskKeys } from "./devices.ts";
import type { Host } from "./extensions.ts";
import { agents, chatOf, library, versions } from "./indexes.ts";
import { storedNeeds } from "./needs.ts";
import { FIRST_BYTES, FIRST_COUNT, ItemJSON, OLDER_BYTES, olderPart, partStart } from "./opening.ts";
import { preparePlan } from "./plan.ts";
import type { Providers } from "./providers.ts";
import { type Params, text } from "./requests.ts";
import { runningCommands } from "./running.ts";
import { SECRET_HIDDEN } from "./secrets.ts";
import { agentOf, type Meta, type ModelRef } from "./state.ts";
import { type AssistantLike, answeredNeeds, assistantParts, imagesOf, type Item, textOf, toItem, wakeLabel } from "./transcript.ts";
import { type UsageDocShape, type UsageJson, usageTotals } from "./usage.ts";
import { points, versionsAllowed } from "./versions.ts";
import { WAKE_ENTRY } from "./wakes.ts";
import { setupMarkdown } from "./worktrees.ts";

// What this file uses of the running engine, handed over by main.ts once it has them (`wireConversationEvents`).
let providers: Providers;
let host: Host;
let context: Context;
let log: (...parts: unknown[]) => void;
/** A conversation the app names by its id: a chat's version shown (main.ts, `conversation`). */
let conversation: (id: unknown) => Promise<Conversation>;
/** The model and thinking level a project's conversation takes from its agent at its next message (main.ts). */
let followedModel: (id: number, meta: Meta | undefined) => { model: ModelRef; thinkingLevel: string | null } | undefined;
/** Whether a chat may read the web (main.ts). */
let chatWeb: (id: number) => boolean;

export function wireConversationEvents(parts: { providers: Providers; host: Host; context: Context; log: typeof log; conversation: typeof conversation; followedModel: typeof followedModel; chatWeb: typeof chatWeb }): void {
	({ providers, host, context, log, conversation, followedModel, chatWeb } = parts);
}

type LiveDocShape = {
	run?: { turns?: number };
	generation?: { message?: AssistantLike; retry?: { at: number; error: string } };
	tools?: { callId: string; name: string; status: string; output?: string; details?: unknown }[];
	runFailure?: { reason: string; detail?: string };
	compactions?: unknown[];
	compactionFailure?: { taskId: number; error: string };
	lastRequestInputTokens?: number;
};

/** How full the model's context is, from the newest answer's own token counts. */
function contextOf(view: ConversationView, model: ModelRef | undefined) {
	const window = model === undefined ? undefined : providers.models.getModel(model.provider, model.modelId)?.contextWindow;
	for (let i = view.entries.length - 1; i >= 0; i--) {
		const entry = view.entries[i]!;
		if (entry.kind === "pi.reset") break;
		const usage = (entry.model?.[0] as { role?: string; usage?: UsageJson } | undefined)?.usage;
		if (usage === undefined) continue;
		const input = (usage.input ?? 0) + (usage.cacheRead ?? 0) + (usage.cacheWrite ?? 0);
		return { used: input + (usage.output ?? 0), window: window ?? null, input };
	}
	return { used: 0, window: window ?? null, input: null };
}

/**
 * What a run's failure says, for the model it was asked of. pi durable names a model it cannot find by its key, and a
 * provider's refusal of a model added by hand does not say that pi² only guessed it was there; both are said plainly.
 */
function failureDetail(failure: { reason: string; detail?: string }, model: ModelRef | undefined): string | null {
	const provider = model === undefined ? undefined : providers.models.getProvider(model.provider);
	if (failure.reason === "no_model" && model !== undefined) {
		const what =
			provider === undefined
				? `${model.modelId}'s provider, ${model.provider}, is no longer connected.`
				: `${provider.name} has no model ${model.modelId} now. A model added by hand and then removed, or one a provider no longer lists, cannot be used.`;
		return `${what} Choose another model from the toolbar, then press Continue.`;
	}
	if (failure.reason === "model_error" && model !== undefined && providers.isAddedByHand(model.provider, model.modelId)) {
		const said = failure.detail ?? "";
		return `${said}${said === "" || /[.!?]$/.test(said) ? "" : "."} ${model.modelId} was added by hand in Settings › Providers: if ${provider?.name ?? model.provider} does not offer it to this sign-in or key, or names it otherwise, choose another model or change the id there.`.trim();
	}
	return failure.detail ?? null;
}

function stateOf(view: ConversationView, meta: Meta | undefined) {
	const live = (view.docs["pi.live"] ?? {}) as LiveDocShape;
	const agent = (view.docs["pi.agent"] ?? {}) as { model?: ModelRef; thinkingLevel?: string; cwd?: string };
	// The model its next message runs on: its agent's, for a project's conversation that is not working (`followedModel`);
	// while it works, the one its run has.
	const next = live.run === undefined ? followedModel(view.conversation.id as unknown as number, meta) : undefined;
	const inbox = (view.docs["pi.inbox"] ?? {}) as { items?: { id: number; mode: string; content?: unknown; entry?: { kind?: unknown; data?: unknown } }[] };
	const partial = live.generation?.message;
	const { input, ...contextSize } = contextOf(view, agent.model);
	const id = view.conversation.id as unknown as number;
	/** A command running in the foreground: when it started and last printed, for the clock on its row (running.ts). */
	const clock = (callId: string) => {
		const running = runningCommands.clock(id, callId);
		return running === undefined ? {} : { startedAt: running.startedAt, lastOutputAt: running.lastOutputAt };
	};
	return {
		busy: live.run !== undefined,
		turns: live.run?.turns ?? 0,
		partial: partial === undefined ? null : assistantParts(partial),
		retry: live.generation?.retry ?? null,
		tools: (live.tools ?? []).map((slot) => ({ callId: slot.callId, name: slot.name, status: slot.status, output: slot.output ?? "", details: slot.details ?? null, ...clock(slot.callId) })),
		failure: live.runFailure === undefined ? null : { reason: live.runFailure.reason, detail: failureDetail(live.runFailure, agent.model) },
		usage: usageTotals(view.docs["pi.usage"] as UsageDocShape | undefined),
		context: contextSize,
		lastRequestInputTokens: live.lastRequestInputTokens ?? input,
		compacting: (live.compactions ?? []).length > 0,
		compactionError: live.compactionFailure === undefined ? null : compactionErrorText(live.compactionFailure.error),
		compactionErrorId: live.compactionFailure?.taskId ?? null,
		// An archived conversation, or a sub-chat of one, is not in the list the app is sent; its title and standing
		// come with it here, so it can still be shown, read-only.
		title: meta?.title ?? "",
		// A chat of the built-in assistant (chat.ts): the page shows chat mode's own controls only then.
		chat: isChat(meta),
		// A chat's web switch (#287): whether its next message may read the web. Null for any other conversation.
		web: isChat(meta) ? chatWeb(id) : null,
		archived: isArchived(meta) || (meta?.parent !== undefined && isArchived(library.conversations[String(meta.parent)])),
		queued: (inbox.items ?? [])
			.filter((item) => item.mode !== "write")
			.map((item) => {
				const own = readUserEntryData(item.entry);
				return { id: item.id, mode: item.mode, text: own?.text ?? textOf(item.content), attachments: own?.attachments ?? [] };
			}),
		agent: {
			model: next?.model ?? agent.model ?? null,
			thinkingLevel: next === undefined ? (agent.thinkingLevel ?? null) : next.thinkingLevel,
			cwd: agent.cwd ?? null,
			access: meta?.access ?? "none",
			agentId: meta?.agentId ?? null,
			parent: meta?.parent ?? null,
		},
		// Where the versions of what is shown part, and which is shown; null where they are not offered (versions.ts).
		versions: versionsAllowed(meta) ? points(versions.chats[String(chatOf(id))], chatOf(id), new Set(view.entries.map((entry) => entry.id as unknown as number))) : null,
		// What features add (see features.ts).
		...Object.assign({}, ...host.features.map((feature) => feature.state?.(view, meta) ?? {})),
	};
}

/**
 * Sends the app a conversation as it changes. A chat with several versions is sent as the version it shows, under the
 * chat's id, and starts over with that version's entries when another is shown.
 *
 * With `newestFirst` (#380, opening.ts), each list sent from the start goes in parts: the newest entries first, with
 * how many are still to come, then the older ones in `conversation.older` events, newest first, one a turn so the
 * engine's thread is never held for long. Entries committed meanwhile go as usual, and a new start drops what of the
 * old list was still to come. Each list sent from the start says whether the conversation has entries before it
 * (`more`), and those come a part at a time when the app asks (`older`, #440).
 *
 * With `tail` (#618), only that newest part is sent: what is older comes when the app asks, as entries older than the
 * window do. The Dashboard's window onto each orchestrator shows only the end of the conversation, and five of them
 * should not each take in the engine's whole window.
 */
async function subscribe(client: Client, id: number, newestFirst = false, tail = false): Promise<void> {
	if (client.subscriptions.has(id)) return;
	let watch: Awaited<ReturnType<Conversation["watch"]>> | undefined;
	let view: ConversationView | undefined;
	/** The conversation `view` is of: the chat's version shown, whose own history the older entries are read from. */
	let source: Conversation | undefined;
	let lastSent: unknown;
	/** The newest entry older than any the app was sent, to read older entries from; undefined when there is none. */
	let below: EntryRecord["id"] | undefined;
	/** Counts the lists sent from the start, so a part read for one is not sent after the next. */
	let lists = 0;
	let reading: Promise<unknown> | undefined;
	/** The entries of the list sent last that the app has still to be sent, oldest first, and their JSON. */
	let older: Item[] = [];
	let olderJSON = new ItemJSON<Item>();
	let sending: NodeJS.Immediate | undefined;
	const sendOlder = () => {
		if (sending !== undefined || older.length === 0) return;
		sending = setImmediate(() => {
			sending = undefined;
			// Closed, or the app gone: nothing more of it is wanted.
			if (client.subscriptions.get(id) !== subscription || client.socket.destroyed) {
				older = [];
				return;
			}
			const start = partStart(older, olderJSON.size, OLDER_BYTES);
			const part = older.slice(start);
			older = older.slice(0, start);
			client.socket.write(`${olderJSON.line({ event: "conversation.older", id, earlier: older.length }, part)}\n`);
			if (older.length === 0) olderJSON = new ItemJSON<Item>();
			sendOlder();
		});
	};
	const push = () => {
		if (view === undefined) return;
		// Entries never change once committed, so the app is only sent the ones it does not have yet.
		const index = lastSent === undefined ? -1 : view.entries.findIndex((entry) => entry.id === lastSent);
		const reset = lastSent === undefined || index === -1;
		const fresh = reset ? view.entries : view.entries.slice(index + 1);
		if (view.entries.length > 0) lastSent = view.entries.at(-1)!.id;
		const items = fresh.map(toItem).filter((item) => item !== undefined);
		const state = stateOf(view, library.conversations[String(id)]);
		if (reset) {
			below = view.before;
			lists++;
		}
		if (!(reset && newestFirst)) {
			send(client, { event: "conversation", id, reset, items, state });
			return;
		}
		olderJSON = new ItemJSON<Item>();
		const start = partStart(items, olderJSON.size, FIRST_BYTES, FIRST_COUNT);
		if (tail) {
			// The rest is read from the store when asked, from the newest entry not sent (`readOlder`).
			older = [];
			if (start > 0) below = items[start - 1]!.id as unknown as EntryRecord["id"];
		} else older = items.slice(0, start);
		const more = below !== undefined;
		if (!client.socket.destroyed) client.socket.write(`${olderJSON.line({ event: "conversation", id, reset, state, earlier: older.length, more }, items.slice(start))}\n`);
		sendOlder();
	};
	/**
	 * Sends the app the part of entries just before the oldest it was sent, as `conversation.older`, and says whether any
	 * are older still. Nothing while the list's own parts are still going, or while a part is being read already.
	 */
	const readOlder = async (): Promise<{ more: boolean }> => {
		if (older.length > 0 || sending !== undefined) return { more: true };
		if (reading !== undefined) {
			await reading.catch(() => {});
			return { more: below !== undefined };
		}
		const from = below;
		const conv = source;
		if (from === undefined || conv === undefined) return { more: false };
		const list = lists;
		const json = new ItemJSON<Item>();
		const read = olderPart(
			(cursor) => conv.entries({ maxEntryId: from, order: "descending" }, 100, cursor as never, context),
			toItem,
			json.size,
			OLDER_BYTES,
		);
		reading = read;
		try {
			const part = await read;
			// Started over meanwhile, or closed: the new list says what is older than it.
			if (list !== lists || client.subscriptions.get(id) !== subscription) return { more: below !== undefined };
			below = part.next;
			const more = below !== undefined;
			if (!client.socket.destroyed) client.socket.write(`${json.line({ event: "conversation.older", id, earlier: 0, more }, part.items)}\n`);
			return { more };
		} finally {
			reading = undefined;
		}
	};
	let following = Promise.resolve();
	const attach = async () => {
		const conv = await conversation(id);
		if (watch !== undefined && view?.conversation.id === conv.id) return;
		const next = await conv.watch(context, { min: 300, max: 600 });
		// A feature's own documents are not part of the view; the task list is loaded here so the first state carries it.
		await preparePlan(conv.id as unknown as number);
		const previous = watch;
		watch = next;
		view = next.value;
		source = conv;
		lastSent = undefined;
		push();
		next.start(async (call) => {
			if (call.kind !== "value" || watch !== next) return;
			view = call.value;
			push();
		});
		await previous?.stop();
	};
	// One at a time, so two quick changes of version never leave two watches.
	const follow = () => (following = following.then(attach).catch((error) => log("could not follow conversation", id, error instanceof Error ? error.message : "")));
	const subscription: Subscription = { push, stop: async () => watch?.stop(), follow, older: readOlder };
	client.subscriptions.set(id, subscription);
	try {
		await attach();
	} catch (error) {
		client.subscriptions.delete(id);
		throw error;
	}
}

/** The most characters of entries one search from a paired device looks at, masked or not: masked all, some 0.3 s. */
export const SEARCH_MASKED_CHARS = 64 * 1024 * 1024;

export const conversationRequests: Record<string, (params: Params, client: Client) => Promise<unknown>> = {
	/**
	 * `{ id, newestFirst?, tail? }`: send the app the conversation, and keep sending it as it changes. With `newestFirst`,
	 * a long one comes in parts, the newest first (`subscribe`); an app that does not ask gets it in one event. With
	 * `tail`, only the newest part comes, and the rest when asked (#618).
	 */
	"conversation.open": async (params, client) => {
		await conversation(params.id);
		if (params.newestFirst !== undefined && typeof params.newestFirst !== "boolean") throw new Error("newestFirst must be true or false");
		if (params.tail !== undefined && typeof params.tail !== "boolean") throw new Error("tail must be true or false");
		await subscribe(client, params.id as number, params.newestFirst === true || params.tail === true, params.tail === true);
		return {};
	},
	/**
	 * `{ id }`: send the app, as a `conversation.older` event, the part of the conversation just before the oldest entry
	 * it was sent since it opened it, and answer `{ more }`, whether there are older entries still (#440). The app asks
	 * when the person scrolls up to the top of what it has.
	 */
	"conversation.older": async (params, client) => {
		const subscription = client.subscriptions.get(params.id as number);
		if (subscription === undefined) throw new Error("That conversation is not open");
		return subscription.older();
	},
	"conversation.close": async (params, client) => {
		const subscription = client.subscriptions.get(params.id as number);
		client.subscriptions.delete(params.id as number);
		await subscription?.stop();
		return {};
	},
	/**
	 * `{ query }`: the entries whose text holds it, newest first, at most 40, each with a snippet around it. From a paired
	 * device, matched and cut on the text as the device is sent it, masked (`maskKeys`, devices.ts, #894): matched on the
	 * text as it is, whether a query finds an entry would tell a phone what its copy hides, a character a query. An entry
	 * whose text, as it is, does not hold the query cannot hold it masked, but for a query with a mark's characters in it,
	 * so only the others are masked; and one search looks at most at SEARCH_MASKED_CHARS of entries' text, counted
	 * whether masked or not, then ends with what it found: where it ends depends on how long the entries are, never on what they hold.
	 */
	search: async (params, client) => {
		const query = text(params, "query").trim().toLowerCase();
		if (query.length < 2) return { results: [] };
		const device = (client as Client | undefined)?.device !== undefined;
		// A query that can meet a mark: in it, or inside one.
		const meetsMark = [...`${KEY_HIDDEN}${SECRET_HIDDEN}`].some((character) => !/[a-z ]/.test(character) && query.includes(character)) || KEY_HIDDEN.includes(query);
		let masked = 0;
		const results: { conversationId: number; title: string; entryId: number; role: string; snippet: string; archived: boolean; chat: boolean }[] = [];
		// Archived conversations are searched too: finding something again is what they are kept for.
		const ids = Object.entries(library.conversations)
			.filter(([, meta]) => !isDeleted(meta) && meta.parent === undefined)
			.sort(([, x], [, y]) => y.updatedAt - x.updatedAt)
			.map(([id]) => Number(id));
		for (const id of ids) {
			// A chat is searched as it is shown: its version shown.
			const conv = await conversation(id).catch(() => undefined);
			if (conv === undefined) continue;
			let cursor: unknown;
			// Newest first, at most 2,000 entries of each conversation.
			for (let page = 0; page < 10 && results.length < 40; page++) {
				const batch = await conv.entries({ order: "descending" }, 200, cursor as never, context);
				for (const entry of batch.items) {
					const message = entry.model?.[0] as { role?: string; content?: unknown } | undefined;
					if (message?.role !== "user" && message?.role !== "assistant") continue;
					let body = textOf(message.content, false);
					if (device) {
						// Every entry looked at counts, masked or not, so that where the search stops says nothing of the text.
						masked += body.length;
						if (masked > SEARCH_MASKED_CHARS) break;
						if (!meetsMark && !body.toLowerCase().includes(query)) continue;
						body = maskKeys(body);
					}
					const at = body.toLowerCase().indexOf(query);
					if (at === -1) continue;
					const start = Math.max(0, at - 40);
					const snippet = (start > 0 ? "…" : "") + body.slice(start, at + query.length + 80).replace(/\s+/g, " ") + (at + query.length + 80 < body.length ? "…" : "");
					results.push({ conversationId: id, title: library.conversations[String(id)]?.title ?? "", entryId: entry.id as unknown as number, role: message.role, snippet, archived: isArchived(library.conversations[String(id)]), chat: isChat(library.conversations[String(id)]) });
					if (results.length >= 40) break;
				}
				cursor = (batch as { next?: unknown }).next;
				if (cursor === undefined || masked > SEARCH_MASKED_CHARS) break;
			}
			if (results.length >= 40 || masked > SEARCH_MASKED_CHARS) break;
		}
		return { results };
	},
	/** One picture of an entry: a screenshot in a tool result, or a picture the person attached to a message. */
	"conversation.image": async (params) => {
		const conv = await conversation(params.id);
		const entryId = params.entryId;
		if (typeof entryId !== "number") throw new Error("entryId must be a number");
		const page = await conv.entries({ minEntryId: entryId as never, maxEntryId: entryId as never }, 1, undefined, context);
		const message = page.items[0]?.model?.[0] as { content?: unknown } | undefined;
		const image = imagesOf(message?.content)[typeof params.index === "number" ? params.index : 0];
		if (image === undefined) throw new Error("That entry has no such picture");
		return image;
	},
	"conversation.export": async (params) => {
		const conv = await conversation(params.id);
		const meta = library.conversations[String(chatOf(conv.id))];
		const items: Item[] = [];
		/** How each Needs you item this conversation put was ended (the wake kind `answer`), where a wake tells it. */
		const answered = new Map<string, { label: string; ended: string }>();
		let cursor: unknown;
		for (;;) {
			const batch = await conv.entries({ order: "ascending" }, 500, cursor as never, context);
			for (const entry of batch.items) {
				if (entry.kind === WAKE_ENTRY) {
					for (const answer of answeredNeeds(entry.data)) {
						const label = wakeLabel(entry.data, answer.need);
						if (label !== undefined) answered.set(answer.need, { label, ended: answer.ended });
					}
				}
				const item = toItem(entry);
				if (item !== undefined) items.push(item);
			}
			cursor = (batch as { next?: unknown }).next;
			if (cursor === undefined || batch.items.length === 0) break;
		}
		if (params.format === "json") return { text: JSON.stringify({ title: meta?.title ?? "", agent: agentOf(meta, agents)?.name ?? null, chat: isChat(meta), exportedAt: new Date().toISOString(), items }, null, 2) };
		const agentName = agentOf(meta, agents)?.name ?? "Assistant";
		const fence = "```";
		const clip = (value: string) => (value.length > 4000 ? `${value.slice(0, 4000)}\n… (${value.length - 4000} more characters)` : value);
		const results = new Map(items.flatMap((item) => (item.kind === "tool" ? [[item.callId, item] as const] : [])));
		// The changes made in this conversation (3.12), for each call's line; a change the person allowed has no
		// call of its own, so its line rides on the request that asked for it. The needs still waiting (3.9).
		const changes = new Map(linesOf(conv.id).map((line) => [line.id, line]));
		const waiting = new Map(storedNeeds().map((need) => [need.id, need]));
		/** A call's change, as one quiet line: its summary, and that it was undone (3.12). */
		const changeLine = (id: unknown): string | null => {
			if (typeof id !== "number") return null;
			const change = changes.get(id);
			return change === undefined ? null : `${change.summary}${change.undone ? " (undone)" : ""}`;
		};
		/** The line of the change allowing the request `id` made, where it made one. */
		const allowedLine = (id: string): string | null => {
			const made = [...changes.values()].find((change) => change.need === id);
			return made === undefined ? null : `${made.summary}${made.undone ? " (undone)" : ""}`;
		};
		/** A call's reach request or proposed rule, as one line with its outcome (3.9, 7.2). */
		const needLine = (id: unknown): string | null => {
			if (typeof id !== "string") return null;
			const told = answered.get(id);
			if (told !== undefined) return `${told.label} ${told.ended}`;
			const need = waiting.get(id);
			if (need === undefined) return "a request that no longer waits for you";
			const label = need.kind === "rule" ? `the proposed rule “${need.text}”` : need.kind === "reach" ? `the request “${need.change.summary}”` : need.kind === "limit" ? "a start the project's limit stopped" : `the question “${need.question}”`;
			return `${label} waits for you`;
		};
		const lines: string[] = [`# ${meta?.title || "Conversation"}`, ""];
		for (const item of items) {
			if (item.kind === "user") {
				lines.push("## You", "", item.text, "");
				const attached = describeAttachments(item.attachments, item.images);
				if (attached !== undefined) lines.push(`*${attached}*`, "");
			} else if (item.kind === "marker") lines.push(`*${item.text}*`, "");
			else if (item.kind === "setup") {
				// Its start is left out once its end is there, as the conversation shows it.
				const run = item.details.run;
				const ended = item.details.status === "running" && items.some((other) => other.kind === "setup" && other.details.run === run && other.details.status !== "running");
				if (!ended) lines.push(setupMarkdown(item.details), "");
			}
			else if (item.kind === "assistant") {
				lines.push(`## ${agentName}${item.stop === "aborted" || item.stop === "error" ? " (interrupted)" : ""}`, "");
				if (item.text !== "") lines.push(item.text, "");
				for (const call of item.toolCalls) {
					const result = results.get(call.callId);
					lines.push(`**Tool: ${call.name}**`, "");
					if ((result?.details as { allowedByEverything?: unknown } | null)?.allowedByEverything === true) lines.push("*Allowed by Allow everything.*", "");
					lines.push(`${fence}json`, JSON.stringify(call.arguments, null, 2), fence, "");
					if (result !== undefined) lines.push(result.isError ? "Result (error):" : "Result:", "", fence, clip(result.text), fence, "");
					// The quiet line for what the call changed, and the one line for what it asked (3.12, 7.2).
					const details = (result?.details ?? null) as { change?: unknown; need?: unknown } | null;
					const changed = changeLine(details?.change);
					if (changed !== null) lines.push(`*${changed}*`, "");
					const asked = needLine(details?.need);
					if (asked !== null) lines.push(`*${asked}*`, "");
					// What allowing the request made, when it made something: its line, with its Undo's mark.
					if (typeof details?.need === "string") {
						const allowed = allowedLine(details.need);
						if (allowed !== null) lines.push(`*${allowed}*`, "");
					}
				}
			}
		}
		return { text: lines.join("\n") };
	},
};
