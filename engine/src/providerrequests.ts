// The requests about providers and their models (#483, moved from main.ts): signing in and out, keys, endpoints of
// one's own, models added by hand, and which models the pickers hide. main.ts hands over what they use of the engine
// (`wireProviderRequests`); the providers themselves are providers.ts's.

import type { AuthEvent, AuthPrompt } from "@earendil-works/pi-ai";
import { type Client, send } from "./clients.ts";
import { DISCOVERY_PROVIDERS, newestOnly, type Providers } from "./providers.ts";
import { type Params, text } from "./requests.ts";
import { scheduleUsageRefresh } from "./usage.ts";

// What this file uses of the running engine, handed over by main.ts once it has them (`wireProviderRequests`).
let providers: Providers;
let settings: { hiddenModels?: Record<string, string[]> };
let saveSettings: () => void;
let announceProviders: () => Promise<void>;
let log: (...parts: unknown[]) => void;

export function wireProviderRequests(parts: { providers: Providers; settings: typeof settings; saveSettings: typeof saveSettings; announceProviders: typeof announceProviders; log: typeof log }): void {
	({ providers, settings, saveSettings, announceProviders, log } = parts);
}

/** Also used at startup and by the timer: one slow provider never holds up another's announcement. */
export async function refreshDiscoveredProviders(): Promise<void> {
	await Promise.all(DISCOVERY_PROVIDERS.map(async (id) => {
		if (await providers.refreshDiscoveredModels(id)) await announceProviders();
	}));
}

function refreshAfterCredentialChange(id: string): void {
	if (!(DISCOVERY_PROVIDERS as readonly string[]).includes(id)) return;
	void providers.refreshDiscoveredModels(id).then(async () => {
		// If an older request was in flight, its invalidated result must finish before the new one starts.
		await providers.refreshDiscoveredModels(id);
		await announceProviders();
	}).catch((error) => log("announcing discovered models failed:", error));
}

const pendingPrompts = new Map<string, (answer: string) => void>();
const logins = new Map<string, AbortController>();
let nextLocalId = 1;

export const providerRequests: Record<string, (params: Params, client: Client) => Promise<unknown>> = {
	"providers.setHiddenModels": async (params) => {
		const id = text(params, "id");
		const available = (await providers.listModels()).filter((model) => model.provider === id).map((model) => model.id);
		if (available.length === 0) throw new Error("That provider has no models to choose from yet");
		const hidden = params.newest === true ? available.filter((model) => !newestOnly(available).has(model)) : params.hidden;
		if (!Array.isArray(hidden) || hidden.some((model) => typeof model !== "string")) throw new Error("hidden must be a list of model ids");
		settings.hiddenModels = { ...settings.hiddenModels, [id]: hidden as string[] };
		if (hidden.length === 0) delete settings.hiddenModels[id];
		saveSettings();
		// Answer first: asking every provider about its sign-in takes a moment, and the sheet is waiting.
		void announceProviders().catch((error) => log("announcing providers failed:", error));
		return { hidden };
	},
	"providers.draftModel": async (params) =>
		providers.draftModel(text(params, "provider"), text(params, "id"), {
			...(typeof params.basedOn === "string" ? { basedOn: params.basedOn } : {}),
			...(typeof params.api === "string" ? { api: params.api } : {}),
		}),
	"providers.addModel": async (params) => {
		const model = await providers.addModel(params as never);
		await announceProviders();
		scheduleUsageRefresh();
		return model;
	},
	"providers.ask": async (params) => {
		const listing = await providers.askProvider(text(params, "id"));
		// A refreshed catalog may hold new models, or ones that were added by hand.
		if (listing.refreshed) await announceProviders();
		return listing;
	},
	"providers.removeModel": async (params) => {
		providers.removeModel(text(params, "provider"), text(params, "id"));
		await announceProviders();
		scheduleUsageRefresh();
		return {};
	},

	"providers.setKey": async (params) => {
		await providers.setKey(text(params, "id"), text(params, "key"));
		await announceProviders();
		refreshAfterCredentialChange(text(params, "id"));
		return {};
	},
	"providers.logout": async (params) => {
		await providers.logout(text(params, "id"));
		await announceProviders();
		return {};
	},
	"providers.login": async (params, client) => {
		const loginId = `login-${nextLocalId++}`;
		const abort = new AbortController();
		logins.set(loginId, abort);
		send(client, { event: "auth", loginId, kind: "started", providerId: params.id });
		try {
			await providers.login(text(params, "id"), {
				signal: abort.signal,
				notify: (event: AuthEvent) => send(client, { event: "auth", loginId, kind: "notify", notice: event }),
				prompt: (prompt: AuthPrompt) =>
					new Promise<string>((resolve, reject) => {
						const promptId = `prompt-${nextLocalId++}`;
						const { signal, ...shown } = prompt;
						const done = () => pendingPrompts.delete(promptId);
						pendingPrompts.set(promptId, (answer) => (done(), resolve(answer)));
						const cancel = () => (done(), send(client, { event: "auth", loginId, kind: "promptClosed", promptId }), reject(new Error("Cancelled")));
						signal?.addEventListener("abort", cancel, { once: true });
						abort.signal.addEventListener("abort", cancel, { once: true });
						send(client, { event: "auth", loginId, kind: "prompt", promptId, prompt: shown });
					}),
			});
			await announceProviders();
			refreshAfterCredentialChange(text(params, "id"));
			return {};
		} finally {
			logins.delete(loginId);
			send(client, { event: "auth", loginId, kind: "finished" });
		}
	},
	"auth.answer": async (params) => {
		pendingPrompts.get(text(params, "promptId"))?.(text(params, "value"));
		return {};
	},
	"auth.cancel": async (params) => {
		logins.get(text(params, "loginId"))?.abort();
		return {};
	},

	"endpoints.probe": async (params) => ({ models: await providers.probeEndpoint(text(params, "baseUrl"), params.key as string | undefined) }),
	"endpoints.save": async (params) => {
		const saved = await providers.saveEndpoint(params as never);
		await announceProviders();
		return { id: saved.id };
	},
	"endpoints.remove": async (params) => {
		await providers.removeEndpoint(text(params, "id"));
		await announceProviders();
		return {};
	},
};
