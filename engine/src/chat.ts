// pi²'s built-in chat assistant: chat mode's conversations (#172, #283).
//
// A chat is a conversation of this assistant, not of one of the person's agents: its record in the library has
// `chat: true` and no `agentId`. The assistant is defined here and in the engine's request handlers, never in the list
// of agents, so it cannot be edited, deleted, duplicated, scheduled or handed work. It has no folder, no shell, no file
// tools, no computer use, no browser with sign-ins and no delegation: only the tools `CHAT_TOOLS` names (builtins.ts),
// none of which changes anything on the Mac, so nothing it does asks for an approval.
//
// A document it writes is kept in a folder of the chat's own in the data folder (`chats/<id>`), never in a folder of
// the person's, and goes when the chat is deleted, as a scratch folder does.

import { mkdirSync } from "node:fs";
import { join } from "node:path";
import { section } from "@earendil-works/pi-durable";
import type { Feature } from "./features.ts";
import { scratchGone, sweepScratch } from "./scratch.ts";
import type { Meta, ModelRef } from "./state.ts";

/** The settings of chat mode, under `chat` in the engine's settings.json. */
export type ChatSettings = {
	/** What the person wants every chat to know about them and how to answer: the `chat_instructions` section. */
	instructions: string;
	/** The model a new chat starts with; null: the model used last in a chat. */
	defaultModel: ModelRef | null;
	/** Whether a chat may read the web (#287 adds a switch for each chat). */
	web: boolean;
	/** Whether chats remember lasting things across chats, and read the agents' notes (knowledge.ts). */
	memory: boolean;
};

export const CHAT_DEFAULTS: ChatSettings = { instructions: "", defaultModel: null, web: true, memory: true };

/** The longest the chat instructions may be. */
export const MAX_CHAT_INSTRUCTIONS = 20_000;

/** The settings as stored, with a default for anything missing or malformed, so an older settings file reads as the defaults. */
export function chatSettings(stored: unknown): ChatSettings {
	const given = (stored ?? {}) as Partial<Record<keyof ChatSettings, unknown>>;
	const model = given.defaultModel as Partial<ModelRef> | null | undefined;
	return {
		instructions: typeof given.instructions === "string" ? given.instructions : CHAT_DEFAULTS.instructions,
		defaultModel: typeof model?.provider === "string" && typeof model.modelId === "string" ? { provider: model.provider, modelId: model.modelId } : null,
		web: typeof given.web === "boolean" ? given.web : CHAT_DEFAULTS.web,
		memory: typeof given.memory === "boolean" ? given.memory : CHAT_DEFAULTS.memory,
	};
}

/**
 * `current` changed by what `chat.set` was sent: any of the four, each checked. Throws with a plain message, and then
 * nothing changes. `known` says whether a model exists, so a default the pickers could not show is refused.
 */
export function changeChatSettings(current: ChatSettings, params: Record<string, unknown>, known: (model: ModelRef) => boolean): ChatSettings {
	const next = { ...current };
	if (params.instructions !== undefined) {
		if (typeof params.instructions !== "string") throw new Error("instructions must be text");
		const instructions = params.instructions.trim();
		if (instructions.length > MAX_CHAT_INSTRUCTIONS) throw new Error(`The chat instructions can be ${MAX_CHAT_INSTRUCTIONS.toLocaleString("en")} characters at most; these are ${instructions.length.toLocaleString("en")}`);
		next.instructions = instructions;
	}
	if (params.defaultModel !== undefined) {
		const model = params.defaultModel as Partial<ModelRef> | null;
		if (model === null) next.defaultModel = null;
		else if (typeof model?.provider !== "string" || typeof model.modelId !== "string") throw new Error("defaultModel must be { provider, modelId }, or null for the model used last in a chat");
		else if (!known({ provider: model.provider, modelId: model.modelId })) throw new Error(`Unknown model: ${model.provider}/${model.modelId}`);
		else next.defaultModel = { provider: model.provider, modelId: model.modelId };
	}
	for (const key of ["web", "memory"] as const) {
		if (params[key] === undefined) continue;
		if (typeof params[key] !== "boolean") throw new Error(`${key} must be true or false`);
		next[key] = params[key];
	}
	return next;
}

export const isChat = (meta: Meta | undefined): boolean => meta?.chat === true;

/** Where the documents of chat `id` are kept: a folder of its own in the data folder. */
export const chatFolder = (home: string, id: number): string => join(home, "chats", String(id));

/** Make chat `id`'s folder if it is not there, and give its path. */
export function makeChatFolder(home: string, id: number): string {
	const folder = chatFolder(home, id);
	mkdirSync(folder, { recursive: true, mode: 0o700 });
	return folder;
}

/** What the assistant is told about itself, in every chat. Steady: it changes only with the tools the chat has. */
export function describeChat(tools: readonly string[]): string {
	const lines = [
		"You are the chat assistant of pi², a Mac app. The person comes here to ask questions and to talk things through: answer directly, and use Markdown where it helps.",
		"This chat has no folder. You cannot see or change the person's files, run commands or use the apps on their Mac, and nothing you do changes anything on it. If they need that done, say that one of their agents in pi² can do it.",
	];
	if (tools.includes("web_fetch")) lines.push("You can search the web and read pages; do so when the answer depends on facts you may not have, or on anything recent.");
	if (tools.includes("write_document")) lines.push("A document you write with write_document is kept with this chat, where the person opens it or saves it elsewhere: give it a plain file name, not a folder.");
	return lines.join("\n");
}

/** The chat instructions from Settings, as the `chat_instructions` section of every chat's prompt; nothing when there are none. */
export function describeChatInstructions(instructions: string): string | undefined {
	const text = instructions.trim();
	if (text === "") return undefined;
	return `The person wrote these instructions in pi²'s Settings, for every chat: what they want you to know about them and how they want you to answer. Follow them, unless what they ask in this chat says otherwise.\n\n${text}`;
}

export const chat: Feature = (host, engine) => {
	const sweep = () => {
		try {
			const conversations = engine.library().conversations;
			sweepScratch(join(engine.home, "chats"), (id) => scratchGone(conversations, id));
		} catch (error) {
			engine.log("chat folders could not be tidied:", error instanceof Error ? error.message : error);
		}
	};
	return {
		sections: [
			section("chat", (input) => (isChat(host.meta(input.conversationId)) ? describeChat(input.agent.tools.map((tool) => tool.name)) : undefined)),
			// Read at every request, so a change in Settings counts from the next message of every chat.
			section("chat_instructions", (input) => (isChat(host.meta(input.conversationId)) ? describeChatInstructions(engine.chatSettings().instructions) : undefined)),
		],
		start: async () => sweep(),
		putAwayChanged: sweep,
	};
};
