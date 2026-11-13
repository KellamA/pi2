// Features that plug into the engine from a file of their own.
//
// A feature can add tools, prompt sections and hooks to every conversation, answer requests from the app, and add
// fields to the conversation state the app is sent. Each lives in one file that exports a `Feature`; the list at the
// bottom is the only place that names them. Nothing else in the engine needs to change to add one.

import type { Context } from "@earendil-works/chord/context";
import type { ConversationView, Harness, HookRegistration, PromptSection, ToolRegistration } from "@earendil-works/pi-durable";
import type { Host } from "./extensions.ts";
import type { Providers } from "./providers.ts";
import type { Access, AgentProfile, Meta } from "./state.ts";

import { knowledge } from "./knowledge.ts";
import { limits } from "./limits.ts";
import { look } from "./look.ts";
import { plan } from "./plan.ts";

/** What a feature may use of the running engine. Getters, because features are made before the harness is open. */
export type Engine = {
	harness(): Harness;
	context(): Context;
	/** The data folder. */
	home: string;
	/** Send an event to every connected app. */
	broadcast(message: unknown): void;
	log(...args: unknown[]): void;
	agents(): Record<string, AgentProfile>;
	library(): { conversations: Record<string, Meta> };
	/** The providers. Ask `providers().models.getAuth()` for a token: it renews and stores one that is about to expire. */
	providers(): Providers;
};

export type FeatureParts = {
	// biome-ignore lint/suspicious/noExplicitAny: tools of any parameter shape
	tools?: ToolRegistration<any, any>[];
	sections?: PromptSection[];
	hooks?: HookRegistration[];
	/** Which of this feature's tools a conversation with this access and agent is given. */
	toolNames?(access: Access, agent: AgentProfile | undefined): string[];
	/** Requests from the app, by method name. Throw an Error with a plain message to refuse. */
	handlers?: Record<string, (params: Record<string, unknown>) => Promise<unknown>>;
	/** Extra fields of the conversation state the app is sent, from the conversation's view. */
	state?(view: ConversationView, meta: Meta | undefined): Record<string, unknown>;
	/** Runs once when the harness is open, before the engine listens or runs anything: load what the rest needs at once. */
	start?(): Promise<void>;
	/** Events sent to each app as it connects, so it need not wait for the next change. */
	greeting?(): unknown[];
	/** A provider was signed in or out, or its key or endpoint changed. */
	providersChanged?(): void;
};

export type Feature = (host: Host, engine: Engine) => FeatureParts;

export const FEATURES: Feature[] = [plan, knowledge, look, limits];
