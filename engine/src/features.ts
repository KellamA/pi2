// Features that plug into the engine from a file of their own.
//
// A feature can add tools, prompt sections and hooks to every conversation, answer requests from the app, and add
// fields to the conversation state the app is sent. Each lives in one file that exports a `Feature`; the list at the
// bottom is the only place that names them. Nothing else in the engine needs to change to add one.

import type { Context } from "@earendil-works/chord/context";
import type { AssistantMessage } from "@earendil-works/pi-ai";
import type { ConversationId, ConversationView, Harness, HookRegistration, PromptSection, ToolRegistration, Wrap } from "@earendil-works/pi-durable";
import type { Host } from "./extensions.ts";
import type { ChatSettings } from "./chat.ts";
import type { Providers } from "./providers.ts";
import type { Access, AgentProfile, Meta, ModelRef } from "./state.ts";

import { background } from "./background.ts";
import { promptCache } from "./cache.ts";
import { chat } from "./chat.ts";
import { coauthor } from "./coauthor.ts";
import { commands } from "./commands.ts";
import { compaction } from "./compaction.ts";
import { documents } from "./documents.ts";
import { heed } from "./heed.ts";
import { knowledge } from "./knowledge.ts";
import { limits, type ProviderLimits } from "./limits.ts";
import { type EpisodeChange, limitWait, type Wait } from "./limitwait.ts";
import { localRun } from "./localrun.ts";
import { localModels } from "./localmodels.ts";
import { look } from "./look.ts";
import { order } from "./order.ts";
import { pictures } from "./pictures.ts";
import { plan } from "./plan.ts";
import { priority } from "./priority.ts";
import { projects } from "./projects.ts";
import { reads } from "./reading.ts";
import { runCode } from "./runcode.ts";
import { scratch } from "./scratch.ts";
import { selfSchedule } from "./selfschedule.ts";
import { variables } from "./variables.ts";
import { wakes } from "./wakes.ts";
import { thinkingNotices } from "./thinkingretry.ts";
import { worktrees } from "./worktrees.ts";

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
	/** Chat mode's settings as they are now (chat.ts). */
	chatSettings(): ChatSettings;
	/** The person's choice for Make pictures, across chats and agents. Null lets pi² choose. */
	pictureModel(): ModelRef | null;
	setPictureModel(model: ModelRef | null): void;
	/** The providers. Ask `providers().models.getAuth()` for a token: it renews and stores one that is about to expire. */
	providers(): Providers;
	/** Whether a conversation (or one of its sub-chats' runs) is working right now. */
	busy(id: number): boolean;
	/** The conversations the connected apps show: open in a pane, or chat mode's current chat (`conversations.shown`). */
	shown(): ReadonlySet<number>;
	/** How many apps are connected. */
	apps(): number;
	/** Send a conversation's state again to the apps showing it: for a change to what a feature's `state` reads from outside the conversation's documents. */
	stateChanged(id: number): void;
	/** Send Activity again to every app: for a change to what a feature's `activity` says. */
	activityChanged(): void;
	/** Why no new work may start now, in words, when today's budget is used up; undefined otherwise. */
	overBudget(): string | undefined;
	/** Send the providers and their models again to every app, as after a sign-in: for a change to what they offer. */
	providersChanged(): void;
	/** A key of settings.json, as the engine read it at start or last saved it; undefined when absent. */
	setting(key: "projects"): unknown;
	/** Change a key of settings.json and save the file. The engine keeps the file, so a feature never writes it itself. */
	saveSetting(key: "projects", value: unknown): void;
};

export type FeatureParts = {
	// biome-ignore lint/suspicious/noExplicitAny: tools of any parameter shape
	tools?: ToolRegistration<any, any>[];
	sections?: PromptSection[];
	hooks?: HookRegistration[];
	/** Changes to tools from elsewhere (pi durable's coding tools, say), applied wherever they are offered. */
	// biome-ignore lint/suspicious/noExplicitAny: tools of any parameter shape
	wraps?: Wrap<any>[];
	/** Which of this feature's tools a conversation with this access and agent is given, in a sub-chat or not. */
	toolNames?(access: Access, agent: AgentProfile | undefined, where: { subChat: boolean }): string[];
	/** Which of this feature's tools a chat (chat.ts) is given, with chat mode's settings as they are now. */
	chatToolNames?(): string[];
	/** Which of this feature's tools could do nothing right now, so are offered to no conversation, a chat included. */
	withheld?(): string[];
	/** Requests from the app, by method name. Throw an Error with a plain message to refuse. */
	handlers?: Record<string, (params: Record<string, unknown>) => Promise<unknown>>;
	/** Extra fields of the conversation state the app is sent, from the conversation's view. */
	state?(view: ConversationView, meta: Meta | undefined): Record<string, unknown>;
	/** Extra fields of a conversation's row in Activity, while it has work running. */
	activity?(id: number): Record<string, unknown>;
	/** Which conversations have work running changed (a run started, ended or was stopped). */
	runsChanged?(working: ReadonlySet<number>): void;
	/**
	 * Asked by pi-durable before it retries a failed model request (`message`), or one the engine stopped during (no
	 * message): how long to wait instead (`waitMs`; false ends the run), and how many attempts were spent on such waits.
	 * Only one feature answers it. See engine/scripts/patch-dependencies.ts.
	 */
	retry?(message: AssistantMessage | undefined, attempt: number, conversationId: number): { waitMs?: number | false; spent: number };
	/**
	 * How every signed-in subscription's windows stand, as Usage shows them: for `delegate`'s result and `sub_chats`' list,
	 * which tell an agent that hands out work how much of the allowance is left. Only one feature answers it (limits.ts).
	 */
	planLimits?(): ProviderLimits[];
	/** The wait for a provider's limit a conversation's run is in, if any: for `sub_chats`' list. Only one feature answers it (limitwait.ts). */
	limitWaitOf?(id: number): Wait | undefined;
	/** The person's choice to advance sleeping generation retries with a different model (limitwait.ts). */
	carryOn?(id: ConversationId, model: ModelRef, scope: { subChats: true } | { since: number }): Promise<number[]>;
	/**
	 * A provider's limit was reached (or what is known of it changed), the runs that waited for it carry on, or none waits
	 * any more. Told to every feature by limitwait.ts; limits.ts keeps the Inbox notice.
	 */
	limitEpisode?(change: EpisodeChange): void;
	/**
	 * Fields of `local.status` and the `local` event, about models on this Mac: what is installed comes from localmodels.ts,
	 * what is running from the feature that runs them. Call `localChanged()` (localmodels.ts) when they change.
	 */
	localStatus?(): Record<string, unknown>;
	/** Runs once when the harness is open, before the engine listens or runs anything: load what the rest needs at once. */
	start?(): Promise<void>;
	/**
	 * After an engine that stopped unexpectedly: extra fields of the `recovery` event, about what this feature found that
	 * engine had left. Asked once, after `start`.
	 */
	recovery?(): Record<string, unknown>;
	/** Events sent to each app as it connects, so it need not wait for the next change. */
	greeting?(): unknown[];
	/** A provider was signed in or out, or its key or endpoint changed. */
	providersChanged?(): void;
	/** The person started a conversation from `agent` (not a chat, sub-chat, fork or scheduled run). */
	created?(id: number, agent: AgentProfile): Promise<void>;
	/** An agent was duplicated: copy person-set feature settings, never its history. */
	agentDuplicated?(sourceId: string, copyId: string): Promise<void>;
	/**
	 * The engine made an agent itself from settings of its own, not from another agent (a project's default orchestrator,
	 * projects.ts): set what this feature keeps for it outside its profile.
	 */
	agentMade?(agentId: string, settings: { memory: boolean }): Promise<void>;
	/** An agent is about to be deleted: remove what this feature keeps for it outside its profile. Throw to keep the agent. */
	deletingAgent?(agentId: string): Promise<void>;
	/** A conversation's folder was changed by the person. */
	folderChanged?(id: number): void;
	/** A conversation's model was changed by the person. */
	modelChanged?(id: number): void;
	/** Which conversations the apps show changed: one was opened or closed in a pane, or an app connected or quit. */
	shownChanged?(): void;
	/** Which conversations are archived or deleted has changed; `engine.library()` already says so. */
	putAwayChanged?(): void;
	/** The person sent a message to a conversation. */
	messageSent?(id: number): void;
	/** The person stopped a conversation's agent. */
	stopped?(id: number): void;
	/** What was spent, or the daily budget, has been counted again: `engine.overBudget()` may say something else now. */
	usageChanged?(): void;
	/** The engine is stopping cleanly: stop what this feature started. The app waits a few seconds for the engine, so be quick. */
	stopping?(): Promise<void>;
};

export type Feature = (host: Host, engine: Engine) => FeatureParts;

// `order` wraps tools that `commands` and `reads` wrap too, and adds to what those made of them, so it comes after them.
// The order of the sections no longer matters for what is sent: each keeps its place in a conversation (sections.ts,
// #186), so one that comes or goes is sent alone wherever it is declared. `limitWait` starts first, so the waits it
// keeps are loaded before what another feature's start sets going can ask about one.
//
// One a line, so that two pull requests adding a feature each do not change the same line. Where a new one does not
// need a place of its own, put it beside the feature most like it rather than at the end, where the next one would go too.
export const FEATURES: Feature[] = [
	limitWait,
	compaction,
	plan,
	knowledge,
	look,
	documents,
	runCode,
	pictures,
	chat,
	limits,
	promptCache,
	selfSchedule,
	worktrees,
	commands,
	reads,
	scratch,
	variables,
	coauthor,
	priority,
	thinkingNotices,
	wakes,
	background,
	heed,
	localRun,
	order,
	localModels,
	// The projects epic (docs/projects.md). Their greetings go to an app in this order (4.4), so each later issue adds its
	// feature on its own line, in place of the comment that names it.
	projects,
	// projectRules (#459)
	// needs (#462)
	// reports (#463)
	// work (#467)
	// github (#468)
];
