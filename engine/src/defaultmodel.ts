// The default model (#483, moved from main.ts): the one an agent with no model of its own starts on (#617,
// `defaultModel`, with `defaultNow` for what is decided inside a commit), the one a new chat starts on (`chatModel`),
// remembering the person's pick, and the events that say them: `providers`, which carries the default too,
// `agentDefault` and `chat`. main.ts hands over what they use of the engine (`wireDefaultModel`).

import { type ChatSettings, chatSettings } from "./chat.ts";
import { broadcast } from "./clients.ts";
import type { Host } from "./extensions.ts";
import { DEMO_MODEL, DEMO_PROVIDER, defaultThinking, type Providers } from "./providers.ts";
import type { ModelRef } from "./state.ts";
import { repriceUsage, scheduleUsageRefresh } from "./usage.ts";

// What this file uses of the running engine, handed over by main.ts once it has them (`wireDefaultModel`).
let settings: {
	defaultModel?: ModelRef;
	agentDefault?: { model: ModelRef; thinkingLevel: string | null };
	onboarded?: boolean;
	hiddenModels?: Record<string, string[]>;
	chat?: ChatSettings;
	lastChatModel?: ModelRef;
};
let saveSettings: () => void;
let providers: Providers;
let host: Host;
let log: (...parts: unknown[]) => void;
/** What `followedModel` says may have changed for some conversations: their apps are sent their state again (main.ts). */
let followersChanged: () => void;

export function wireDefaultModel(parts: { settings: typeof settings; saveSettings: typeof saveSettings; providers: Providers; host: Host; log: typeof log; followersChanged: typeof followersChanged }): void {
	({ settings, saveSettings, providers, host, log, followersChanged } = parts);
}

/**
 * The default model for agents as `defaultModel` last worked it out, for what is decided inside a commit, where the
 * providers are not asked (`followedModel`). Worked out again whenever the providers or the settings change, and as
 * each app connects.
 */
export let defaultNow: ModelRef = { provider: DEMO_PROVIDER, modelId: DEMO_MODEL };

export async function providersEvent() {
	const [list, all] = await Promise.all([providers.listProviders(), providers.listModels()]);
	// Hidden models stay in the list, marked: settings shows them, the pickers leave them out, and one already in use keeps working.
	const models = all.map((model) => ({ ...model, hidden: settings.hiddenModels?.[model.provider]?.includes(model.id) === true }));
	return { event: "providers", providers: list, models, defaultModel: await defaultModel(), onboarded: settings.onboarded === true };
}
export async function announceProviders(): Promise<void> {
	broadcast(await providersEvent());
	// A provider signed out, or a model switched off, can make the default for agents fall back, or come back.
	broadcast(await agentDefaultEvent());
	// Signing in or out changes which usage has a price.
	repriceUsage();
	scheduleUsageRefresh();
	for (const feature of host.features) feature.providersChanged?.();
}

/**
 * The model an agent with none of its own starts a conversation on: the one chosen in Settings › General (#617) while
 * its provider offers it and it is not switched off; else the one last picked in a conversation, if still usable; else
 * the demo model.
 */
export async function defaultModel(): Promise<ModelRef> {
	const chosen = settings.agentDefault?.model;
	const model =
		chosen !== undefined && !hiddenModel(chosen) && (await usable(chosen))
			? chosen
			: settings.defaultModel !== undefined && (await usable(settings.defaultModel))
				? settings.defaultModel
				: { provider: DEMO_PROVIDER, modelId: DEMO_MODEL };
	if (!sameModel(model, defaultNow)) {
		defaultNow = model;
		followersChanged();
	}
	return model;
}

const hiddenModel = (model: ModelRef) => settings.hiddenModels?.[model.provider]?.includes(model.modelId) === true;
export const sameModel = (a: ModelRef | null | undefined, b: ModelRef | null | undefined) => a?.provider === b?.provider && a?.modelId === b?.modelId;

/** The thinking level of a conversation on the default model: the one chosen with it in Settings, else the model's own. */
export function defaultModelThinking(model: ModelRef): string | null {
	const chosen = settings.agentDefault;
	return chosen !== undefined && chosen.thinkingLevel !== null && sameModel(chosen.model, model) ? chosen.thinkingLevel : defaultThinking(model);
}

/**
 * Settings › General's default model for agents (#617): what was chosen (null for the model used last), and the model a
 * conversation of an agent with none of its own starts on now, which differs from the choice when it fell back.
 */
export async function agentDefaultEvent() {
	const chosen = settings.agentDefault ?? null;
	const using = await defaultModel();
	return { event: "agentDefault", model: chosen?.model ?? null, thinkingLevel: chosen?.thinkingLevel ?? null, using, fellBack: chosen !== null && !sameModel(chosen.model, using) };
}

/** A choice in a conversation's model menu counts for future conversations, too. */
export function rememberModel(model: ModelRef, chat: boolean): void {
	if (chat) settings.lastChatModel = model;
	else settings.defaultModel = model;
	saveSettings();
	// While no default for agents is chosen in Settings, this is it: the app shows it for each agent with no model of its own.
	if (!chat) void announceDefault().catch((error) => log("announcing the default model failed:", error instanceof Error ? error.message : error));
}

/** The default model for agents, as the providers event and Settings › General show it. */
export async function announceDefault(): Promise<void> {
	broadcast(await providersEvent());
	broadcast(await agentDefaultEvent());
	// The thinking level chosen with the default model can change without the model changing.
	followersChanged();
}

/** Whether `model`'s provider is connected and offers it now. */
export async function usable(model: ModelRef): Promise<boolean> {
	return (await providers.models.getAvailable(model.provider).catch(() => [])).some((m) => m.id === model.modelId);
}

/**
 * The model a new chat starts with: the one used last in a chat, else chat mode's default model, else the agent view's.
 * Choosing a default model in Settings forgets the last one used (`chat.set`), so the choice counts from the next chat.
 */
export async function chatModel(): Promise<ModelRef> {
	for (const wanted of [settings.lastChatModel, chatSettings(settings.chat).defaultModel]) {
		if (wanted !== undefined && wanted !== null && (await usable(wanted))) return wanted;
	}
	return defaultModel();
}

export const chatEvent = () => ({ event: "chat", ...chatSettings(settings.chat) });
