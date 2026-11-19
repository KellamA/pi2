// The app's own durable state, and the in-memory list of things waiting on the person.

import type { BrowserSettings } from "./browser.ts";
import type { ComputerSettings } from "./computer.ts";
import type { ReferenceFile } from "./reference.ts";
import type { ScheduleSettings } from "./selfschedule.ts";
import type { CommandRule } from "./rules.ts";
import { projectsOn, type SwitchName } from "./projects.ts";
import { awaitWithContext, type Context } from "@earendil-works/chord/context";
import { defineDoc, type HookApi } from "@earendil-works/pi-durable";

export type ModelRef = { provider: string; modelId: string };

/** What tools a conversation may use: nothing, reading files, everything with approval, or everything unattended. */
export type Access = "none" | "read" | "ask" | "full";
export const ACCESS_LEVELS: readonly Access[] = ["none", "read", "ask", "full"];

/** A saved setup that conversations start from. */
export type AgentProfile = {
	id: string;
	name: string;
	description: string;
	/** One of the app's avatar colours, by name. */
	color: string;
	/** Null follows the app's default model. */
	model: ModelRef | null;
	thinkingLevel: string | null;
	instructions: string;
	access: Access;
	cwd: string | null;
	/** Whether each conversation the person starts gets a git worktree of its own, made from `cwd` (worktrees.ts). */
	worktree?: boolean;
	/**
	 * A shell command run once in each new worktree of this agent's conversations, right after pi² makes it (worktrees.ts).
	 * Typed by the person in the agent's settings, so it runs without asking; saved only through `agents.save`.
	 */
	setup?: string;
	/** IDs of the agents this one may hand work to. */
	delegates: string[];
	maxTurns: number | null;
	/** Whether the agent may write scripts that call its tools. */
	codeMode?: boolean;
	/** IDs of the MCP servers whose tools the agent gets. */
	mcpServers?: string[];
	/** Files and folders every conversation of the agent may read. */
	files?: ReferenceFile[];
	/** Whether the agent may use apps on this Mac, and which. */
	computer?: ComputerSettings;
	/** Whether the agent may browse the web in pi²'s own browser. */
	browser?: BrowserSettings;
	/** Whether the agent may set schedules for itself, each approved by the person. Off when absent. */
	schedule?: ScheduleSettings;
	/** Keys of the built-in tools it is not offered (builtins.ts). Absent or empty: all of them. */
	toolsOff?: string[];
	/** Keys of the built-in tools off by default that it is offered (builtins.ts). Absent or empty: none of them. */
	toolsOn?: string[];
	/** Early summarizing in tokens; null or absent follows the default for all agents. */
	compactionTokens?: number | null;
	/**
	 * Shell commands it may run without asking under "ask first", folder by folder (see rules.ts). Changed only through
	 * `rules.add`, `rules.remove` and an approval's "rule" answer, never by saving the agent.
	 */
	commandRules?: CommandRule[];
	/**
	 * Environment variables of its own, which its shell, background and set-up commands get (variables.ts). Names only,
	 * and whether each has a value: the values are in the Keychain. Changed only through `variables.set` and
	 * `variables.remove`, never by saving the agent.
	 */
	variables?: AgentVariable[];
	/**
	 * Allow everything (#294): its conversations are asked about nothing and may use any app. Set only through
	 * `agents.allowEverything`, after the app's confirmation; never by saving the agent, and never copied to a duplicate.
	 * A conversation takes it at each message (`takeAgentSwitch`), so a change counts from its next message.
	 */
	allowEverything?: true;
	createdAt: number;
	// What marks a project agent (docs/projects.md, 3.3). All optional: an agent saved before has none, and is a template.
	// `agents.save` keeps them as stored, whatever it is sent.
	/** The project it belongs to (projects.ts). */
	projectId?: string;
	/** The project's orchestrator. Exactly one agent of each project not deleted has it. */
	role?: "orchestrator";
	/** A copy: the template it was made from, when, and the template's `updatedAt` then. */
	template?: { id: string; copiedAt: number; templateUpdatedAt: number };
	/** Made by an agent through a tool (#465): which, and in which conversation. Absent: made by the person or by carrying over. */
	madeBy?: { agentId: string; conversationId: number };
	/** When it was last saved. Absent in an agent not saved since this field came: read as `createdAt`. */
	updatedAt?: number;
	/**
	 * Removed through a tool (projectagents.ts, `removeAgent`): kept whole, with its variables' values, offered to nobody,
	 * put back by `agents.restore`, and deleted for good only by the person (`agents.delete`).
	 */
	removedAt?: number;
};

/** A variable of an agent's own: its name, and whether a value is kept for it in the Keychain. */
export type AgentVariable = { name: string; set: boolean };

export type Meta = {
	title: string;
	createdAt: number;
	updatedAt: number;
	/**
	 * When it was archived: out of the sidebar, kept in the Archive, and restorable (archive.ts). The person archives a
	 * conversation with its sub-chats; an agent can archive a sub-chat of its own conversation on its own (subchats.ts).
	 */
	archivedAt?: number;
	/** The person deleted it: it is shown nowhere again. */
	deleted?: boolean;
	/** What deleting set before there was an archive. Turned into `deleted` once, at start-up. */
	archived?: boolean;
	access: Access;
	agentId?: string;
	/** Tools the person chose "always allow" for in this conversation. */
	autoApprove?: string[];
	/** The person gave it its title themselves: an agent continuing it as a sub-chat does not rename it (extensions.ts). */
	renamed?: boolean;
	/** A subagent's conversation: kept out of the sidebar and reached through its parent. */
	parent?: number;
	/**
	 * The `delegate` call that made a sub-chat it did not wait for (`wait: false`). Such a sub-chat belongs to no call, so
	 * that the call can end while it works; this lets the call, run again after a crash, find it rather than make another.
	 */
	madeBy?: string;
	/** The latest task handed to this sub-chat, as a durable input submission. */
	subChatTask?: number;
	/**
	 * One of a chat's versions after the first (versions.ts), with the chat as its `parent`: shown in the chat's place when
	 * current, and never on its own.
	 */
	version?: true;
	/** A chat: a conversation of pi²'s built-in chat assistant (chat.ts), with no `agentId`. */
	chat?: true;
	/**
	 * A chat whose web switch is off (#287): it is offered no web tools from its next message. A new chat takes chat
	 * mode's `web` setting; the person changes it by the chat's message field (`conversation.configure`).
	 */
	web?: false;
	/** A conversation of an agent's that a chat was continued in (Continue with an Agent, #289): that chat. */
	continuedFrom?: number;
	/** A chat that was continued with an agent (#289): the conversations it was continued in, oldest first. */
	continuedIn?: number[];
	/** The person pinned it to the top of its list (`conversation.pin`). */
	pinned?: true;
	/**
	 * Its agent had Allow everything on at this conversation's latest message: nothing it does waits for approval
	 * (see `Inbox`). Taken from its own agent at each message, never from the conversation that handed it work.
	 */
	allowEverything?: true;
	/**
	 * The project it belongs to (projects.ts): set as it is made, on every conversation of a project, sub-chats included
	 * (taken from the parent). Never on a chat. Nothing in the epic changes `agentId`.
	 */
	projectId?: string;
	/**
	 * For a conversation carried over (#458 sets it; nothing does before): the project's copy of its agent, which it runs
	 * as while the preview is on (`runsAs`).
	 */
	projectAgentId?: string;
};

/**
 * The agent whose settings conversation `meta` uses at its next message (docs/projects.md, 3.4): its project's copy of
 * its agent, for a conversation carried over, while the preview is on and the copy is neither removed nor deleted; else
 * its `agentId`, as before projects. Every lookup of a conversation's agent goes through this, or through `agentOf`.
 */
export function runsAs(meta: Meta | undefined, agents: Record<string, AgentProfile>): string | undefined {
	const copy = meta?.projectAgentId === undefined ? undefined : agents[meta.projectAgentId];
	if (projectsOn() && copy !== undefined && copy.removedAt === undefined) return meta!.projectAgentId;
	return meta?.agentId;
}

/**
 * The agent conversation `meta` runs as (`runsAs`), or undefined when there is none: a chat, an agent deleted, or one
 * removed through a tool, whose conversations keep the setup they have, as those of a deleted agent do (3.4).
 */
export function agentOf(meta: Meta | undefined, agents: Record<string, AgentProfile>): AgentProfile | undefined {
	const id = runsAs(meta, agents);
	const agent = id === undefined ? undefined : agents[id];
	return agent?.removedAt === undefined ? agent : undefined;
}

/**
 * The `projectId` a new conversation takes from what it is made from: the agent it is made with, or the conversation
 * it is a sub-chat or a fork of. Nothing when that is in no project.
 */
export function projectFrom(source: { projectId?: string } | undefined): { projectId?: string } {
	return source?.projectId === undefined ? {} : { projectId: source.projectId };
}

/**
 * Take the agent's Allow everything switch into a conversation, as each message is sent: turning it on or off counts
 * from each conversation's next message, never in the middle of a run. Returns whether anything changed.
 */
export function takeAgentSwitch(meta: Meta, agent: AgentProfile | undefined): boolean {
	const on = agent?.allowEverything === true;
	if ((meta.allowEverything === true) === on) return false;
	if (on) meta.allowEverything = true;
	else delete meta.allowEverything;
	return true;
}

/** Index of conversations: titles, order, tool access. */
export const Library = defineDoc<{ conversations: Record<string, Meta> }>({
	kind: "pi2.library",
	version: 1,
	scope: "session",
	initial: () => ({ conversations: {} }),
	checkpointWhen: () => true,
});

export const Agents = defineDoc<{ agents: Record<string, AgentProfile> }>({
	kind: "pi2.agents",
	version: 1,
	scope: "session",
	initial: () => ({ agents: {} }),
	checkpointWhen: () => true,
});

export function starterAgents(now: number): AgentProfile[] {
	const base = { model: null, thinkingLevel: null, cwd: null, maxTurns: null };
	return [
		{
			...base,
			id: "atlas",
			name: "Atlas",
			description: "General assistant. Hands research and coding to the others.",
			color: "violet",
			instructions: "You are a helpful, direct assistant. Delegate focused research or coding work when another agent is better placed to do it, then give the person one clear answer.",
			access: "none",
			delegates: ["scout", "forge"],
			createdAt: now,
		},
		{
			...base,
			id: "forge",
			name: "Forge",
			description: "Careful coding agent. Asks before changing files or running commands.",
			color: "orange",
			instructions: "You are a concise coding assistant. Reproduce a problem before fixing it, keep changes minimal, and run the tests after every change.",
			access: "ask",
			delegates: [],
			createdAt: now + 1,
		},
		{
			...base,
			id: "scout",
			name: "Scout",
			description: "Researcher. Reads files and reports what it finds.",
			color: "teal",
			instructions: "You are a careful researcher. Read what you need, cite the files you used, and say plainly when you are not sure.",
			access: "read",
			delegates: [],
			createdAt: now + 2,
		},
	];
}

// ---- Inbox: approvals and questions a run is waiting on

export type InboxItem = {
	id: string;
	kind: "approval" | "question";
	conversationId: number;
	callId: string;
	tool: string;
	arguments: unknown;
	question: string | null;
	/** For a browser action: the site it would act on, which is what "always allow" then covers. */
	site?: string;
	/** For a schedule an agent asks to set: when it would run, in words, such as "Every day at 07:00, first run …". */
	when?: string;
	/**
	 * For a shell command: the rule the engine would make if the person answers "rule". The engine keeps its own copy and
	 * makes the rule from that, never from anything the app sends back. `worktrees` when the rule will also hold in the
	 * same folder of every worktree pi² makes from that repository (rules.ts, `ruleFolder`).
	 */
	rule?: { words: string[]; folder: string; worktrees?: true };
	/** For a shell command: it would be started and left running in the background (background.ts), so the approval says so. */
	background?: true;
	/**
	 * Asked because a switch of the conversation's project is off (projects.ts, `requireSwitch`): which. It is answered
	 * only Allow Once or Deny, and Allow everything does not answer it.
	 */
	projectSwitch?: SwitchName;
	createdAt: number;
};

/** The tool task remembers why its approval was skipped, even if it is interrupted by a restart. */
export const ALLOWED_BY_EVERYTHING = "pi2.allowedByEverything";

/**
 * Waiting calls live in memory: each is a tool task parked inside its hook or its `execute()`. After a restart the
 * Harness runs that code again, so the item reappears; nothing here needs to be stored.
 */
export class Inbox {
	readonly #waiting = new Map<string, { item: InboxItem; resolve: (answer: string) => void }>();
	readonly #unasked: (conversationId: number) => Promise<boolean>;
	onChange: () => void = () => {};

	/**
	 * `unasked` says whether a conversation's approvals go without asking: Allow everything (#294). Every approval an
	 * agent waits on comes through `ask`, so this is the one place that decides it, whatever kind of approval it is.
	 */
	constructor(unasked: (conversationId: number) => Promise<boolean> = async () => false) {
		this.#unasked = unasked;
	}

	/**
	 * Show `item` and wait for the person. Rejects when the run is stopped. An approval in a conversation that allows
	 * everything is answered "once" at once, without being shown: allowed this time, with nothing remembered (no rule,
	 * no "always"), so turning the switch off later leaves nothing behind. A question is always asked, and so is an
	 * approval a project's switch asks for (`projectSwitch`): the switch is the person's newer, narrower choice.
	 */
	async ask(item: InboxItem, api: Pick<HookApi, "memo">, context: Context): Promise<string> {
		if (item.kind === "approval" && item.projectSwitch === undefined && (await this.#unasked(item.conversationId))) {
			await api.memo(ALLOWED_BY_EVERYTHING, true, context);
			return "once";
		}
		const answer = new Promise<string>((resolve) => this.#waiting.set(item.id, { item, resolve }));
		this.onChange();
		try {
			return await awaitWithContext(answer, context);
		} finally {
			this.#waiting.delete(item.id);
			this.onChange();
		}
	}

	answer(id: string, value: string): boolean {
		const waiting = this.#waiting.get(id);
		waiting?.resolve(value);
		return waiting !== undefined;
	}

	get(id: string): InboxItem | undefined {
		return this.#waiting.get(id)?.item;
	}

	list(): InboxItem[] {
		return [...this.#waiting.values()].map((w) => w.item).sort((a, b) => a.createdAt - b.createdAt);
	}
}
