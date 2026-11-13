// The app's own durable state, and the in-memory list of things waiting on the person.

import type { BrowserSettings } from "./browser.ts";
import type { ComputerSettings } from "./computer.ts";
import type { ReferenceFile } from "./reference.ts";
import type { CommandRule } from "./rules.ts";
import { awaitWithContext, type Context } from "@earendil-works/chord/context";
import { defineDoc } from "@earendil-works/pi-durable";

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
	/**
	 * Shell commands it may run without asking under "ask first", folder by folder (see rules.ts). Changed only through
	 * `rules.add`, `rules.remove` and an approval's "rule" answer, never by saving the agent.
	 */
	commandRules?: CommandRule[];
	createdAt: number;
};

export type Meta = {
	title: string;
	createdAt: number;
	updatedAt: number;
	archived?: boolean;
	access: Access;
	agentId?: string;
	/** Tools the person chose "always allow" for in this conversation. */
	autoApprove?: string[];
	/** A subagent's conversation: kept out of the sidebar and reached through its parent. */
	parent?: number;
};

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
	/**
	 * For a shell command: the rule the engine would make if the person answers "rule". The engine keeps its own copy and
	 * makes the rule from that, never from anything the app sends back.
	 */
	rule?: { words: string[]; folder: string };
	createdAt: number;
};

/**
 * Waiting calls live in memory: each is a tool task parked inside its hook or its `execute()`. After a restart the
 * Harness runs that code again, so the item reappears; nothing here needs to be stored.
 */
export class Inbox {
	readonly #waiting = new Map<string, { item: InboxItem; resolve: (answer: string) => void }>();
	onChange: () => void = () => {};

	/** Show `item` and wait for the person. Rejects when the run is stopped. */
	async ask(item: InboxItem, context: Context): Promise<string> {
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
