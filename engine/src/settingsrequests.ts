// The requests that change what the person set in settings.json (#483, moved from main.ts): the daily budget,
// finishing onboarding, compaction (with its event), the default model for agents, archiving after a while, and chat
// mode. main.ts keeps the file and hands over what they use of the engine (`wireSettingsRequests`).

import { validateAutoArchive } from "./archive.ts";
import { libraryEvent } from "./appevents.ts";
import { type ChatSettings, changeChatSettings, chatSettings } from "./chat.ts";
import { broadcast } from "./clients.ts";
import { validateCompactionTokens } from "./compaction.ts";
import { agentDefaultEvent, announceDefault, announceProviders, chatEvent } from "./defaultmodel.ts";
import type { Providers } from "./providers.ts";
import type { Params } from "./requests.ts";
import type { ModelRef } from "./state.ts";
import { refreshUsage } from "./usage.ts";

// What this file uses of the running engine, handed over by main.ts once it has them (`wireSettingsRequests`).
let settings: {
	agentDefault?: { model: ModelRef; thinkingLevel: string | null };
	dailyBudget?: number | null;
	onboarded?: boolean;
	autoArchiveDays?: number | null;
	defaultCompactionTokens?: number | null;
	chat?: ChatSettings;
	lastChatModel?: ModelRef;
};
let saveSettings: () => void;
let providers: Providers;
/** Archive what has gone unused for as long as the person chose (main.ts). */
let sweepArchive: () => Promise<void>;

export function wireSettingsRequests(parts: { settings: typeof settings; saveSettings: typeof saveSettings; providers: Providers; sweepArchive: typeof sweepArchive }): void {
	({ settings, saveSettings, providers, sweepArchive } = parts);
}

export const compactionSettingsEvent = () => ({ event: "compactionSettings", defaultCompactionTokens: settings.defaultCompactionTokens ?? null });

export const settingsRequests: Record<string, (params: Params) => Promise<unknown>> = {
	"usage.setBudget": async (params) => {
		const daily = params.daily;
		if (daily !== null && !(typeof daily === "number" && Number.isFinite(daily) && daily > 0)) throw new Error("The budget must be an amount above zero, or off");
		settings.dailyBudget = daily as number | null;
		saveSettings();
		await refreshUsage();
		return {};
	},
	"settings.finishOnboarding": async () => {
		settings.onboarded = true;
		saveSettings();
		await announceProviders();
		return {};
	},
	"settings.getCompaction": async () => ({ defaultCompactionTokens: settings.defaultCompactionTokens ?? null }),
	"settings.setCompaction": async (params) => {
		settings.defaultCompactionTokens = validateCompactionTokens(params.defaultCompactionTokens);
		saveSettings();
		const event = compactionSettingsEvent();
		broadcast(event);
		return { defaultCompactionTokens: event.defaultCompactionTokens };
	},
	/**
	 * The default model for agents (#617): `{ model: { provider, modelId } | null, thinkingLevel?: string | null }`. Null
	 * goes back to the model last picked in a conversation. Every agent with no model of its own starts its next
	 * conversation on it; conversations already started keep theirs. Answers as the `agentDefault` event says.
	 */
	"settings.setAgentDefault": async (params) => {
		if (!("model" in params)) throw new Error("model must be { provider, modelId }, or null for the model used last");
		if (params.model === null) delete settings.agentDefault;
		else {
			const { provider, modelId } = (params.model ?? {}) as Partial<ModelRef>;
			if (typeof provider !== "string" || typeof modelId !== "string") throw new Error("model must be { provider, modelId }, or null for the model used last");
			if (providers.models.getModel(provider, modelId) === undefined) throw new Error(`Unknown model: ${provider}/${modelId}`);
			const level = params.thinkingLevel ?? null;
			if (level !== null) {
				const levels = (await providers.listModels()).find((model) => model.provider === provider && model.id === modelId)?.thinkingLevels ?? [];
				if (typeof level !== "string" || !levels.includes(level)) throw new Error(`${provider}/${modelId} has no thinking level ${String(level)}`);
			}
			settings.agentDefault = { model: { provider, modelId }, thinkingLevel: level as string | null };
		}
		saveSettings();
		await announceDefault();
		const { event: _, ...answer } = await agentDefaultEvent();
		return answer;
	},
	"settings.setAutoArchive": async (params) => {
		settings.autoArchiveDays = validateAutoArchive(params.days);
		saveSettings();
		broadcast(libraryEvent());
		// Chosen now, so applied now: the person sees what the setting does without waiting for the next check.
		await sweepArchive();
		return {};
	},
	/** Chat mode's settings (chat.ts): any of `instructions`, `defaultModel`, `web`, `memory`. Answers with all four. */
	"chat.set": async (params) => {
		const after = changeChatSettings(chatSettings(settings.chat), params, (model) => providers.models.getModel(model.provider, model.modelId) !== undefined);
		settings.chat = after;
		// A default chosen now counts from the next chat, over the model used last.
		if (params.defaultModel !== undefined) delete settings.lastChatModel;
		saveSettings();
		broadcast(chatEvent());
		// The web setting is where a new chat's web switch starts; chats already made keep their own (#287). The memory
		// switch changes what every chat is offered, from its next message (syncTools).
		return after;
	},
};
