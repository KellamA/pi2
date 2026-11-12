// What pi2 adds to every conversation: approval before risky tools, a way to ask the person, and delegation.

import {
	type AgentChange,
	configure,
	type ConversationId,
	defineExtension,
	defineTool,
	type Extension,
	GenerationTask,
	hook,
	section,
	ToolTask,
	type Tx,
} from "@earendil-works/pi-durable";
import { int, num, obj, opt, str } from "@earendil-works/pi-schema";
import type { Context } from "@earendil-works/chord/context";
import { ACTIONS, type ComputerHost, describeComputer, isNever, isViewOnly, LOOKING, plainDescription, pruneScreenshots } from "./computer.ts";
import { describeReferenceFiles, readReference } from "./reference.ts";
import { type AgentProfile, type Inbox, Library, type Meta } from "./state.ts";

/** Tools that change things on the Mac, and so wait for approval when a conversation's access is "ask". */
const GATED = new Set(["bash", "write", "edit"]);

export type Host = {
	inbox: Inbox;
	computer: ComputerHost;
	/** Whether a tool outside the built-in set changes things, and so needs approval under "ask". */
	changesThings(tool: string): boolean;
	meta(conversationId: ConversationId): Meta | undefined;
	agent(id: string | undefined): AgentProfile | undefined;
	allowAlways(conversationId: ConversationId, tool: string): Promise<void>;
	/** How a conversation of `agent` is configured; `delegate` false leaves the delegation tool out. */
	agentChange(agent: AgentProfile, options: { delegate: boolean }): Promise<AgentChange>;
	answerText(conversationId: ConversationId, submissionAnswer: unknown): Promise<string>;
	/**
	 * Send a message to a sub-chat that an earlier call created, and wait for its answer. Stopping the caller stops
	 * the sub-chat's run too. Resolves with the answer, or `undefined` with a reason when there was none.
	 */
	continueChat(conversationId: number, content: string, requestId: string, context: Context): Promise<{ answer: string } | { reason: string }>;
};

const text = (value: string) => [{ type: "text" as const, text: value }];

/** The agents a conversation may delegate to, from its own agent's list. */
function delegatesOf(host: Host, conversationId: ConversationId): AgentProfile[] {
	const own = host.agent(host.meta(conversationId)?.agentId);
	return (own?.delegates ?? []).map((id) => host.agent(id)).filter((a): a is AgentProfile => a !== undefined);
}

export function pi2Extension(host: Host): Extension {
	const askUser = defineTool({
		name: "ask_user",
		description: "Ask the person a question and wait for their answer. Use it when you need a decision or a fact only they have; do not use it for things you can find out yourself.",
		parameters: obj({ question: str() }),
		replay: "safe", // after a restart the question is simply asked again
		execute: async (args, api, context) => {
			const answer = await host.inbox.ask(
				{
					id: String(api.taskId),
					kind: "question",
					conversationId: api.conversationId as unknown as number,
					callId: api.callId,
					tool: "ask_user",
					arguments: args,
					question: args.question,
					createdAt: Date.now(),
				},
				context,
			);
			return { output: text(answer) };
		},
	});

	const delegate = defineTool({
		name: "delegate",
		description:
			"Hand a self-contained task to another agent and get its answer back. Name one of the agents listed in the <agents> section, and write the task so it stands on its own: the other agent sees none of this conversation. " +
			"Each call opens a sub-chat the person can watch. To carry on an earlier sub-chat instead of starting a new one, pass its number as `chat`; that agent then still remembers what it did there.",
		parameters: obj({ agent: str(), task: str(), chat: opt(int({ description: "Number of an earlier sub-chat of this conversation to continue" })) }),
		replay: "safe", // a rerun after a crash finds the same child conversation and submission
		execute: async (args, api, context) => {
			const parent = api.conversationId as unknown as number;
			const footer = (id: number, name: string) => `\n\n(Sub-chat ${id} with ${name}. To continue it, call delegate again with chat: ${id}.)`;
			if (args.chat !== undefined) {
				const meta = host.meta(args.chat as unknown as ConversationId);
				const agent = host.agent(meta?.agentId);
				if (meta === undefined || meta.parent !== parent || meta.archived === true || agent === undefined) {
					return { output: text(`There is no sub-chat ${args.chat} in this conversation to continue. Leave \`chat\` out to start a new one.`), isError: true };
				}
				await api.details({ conversationId: args.chat, agentId: agent.id, agentName: agent.name }, context);
				const result = await host.continueChat(args.chat, args.task, `delegate:${String(api.taskId)}`, context);
				if ("reason" in result) return { output: text(`${agent.name} did not finish the task (${result.reason}).`), isError: true };
				return { output: text(result.answer + footer(args.chat, agent.name)) };
			}
			const allowed = delegatesOf(host, api.conversationId);
			const target = allowed.find((a) => a.name.toLowerCase() === args.agent.trim().toLowerCase() || a.id === args.agent.trim());
			if (target === undefined) {
				const names = allowed.map((a) => a.name).join(", ");
				return { output: text(names === "" ? "This conversation has no agents to delegate to." : `Unknown agent "${args.agent}". Available: ${names}.`), isError: true };
			}
			const change = await host.agentChange(target, { delegate: false });
			const child = await api.commit(async (tx: Tx) => {
				const existing = (await tx.scanConversations({ ownerTaskId: api.taskId }, 1)).items[0];
				if (existing !== undefined) return existing.id;
				const created = await tx.createConversation({ ownership: { kind: "task", taskId: api.taskId } });
				await configure(tx, created.id, change);
				const now = Date.now();
				(await tx.doc(Library)).conversations[String(created.id)] = {
					title: `${target.name}: ${args.task.trim().split("\n")[0]!.slice(0, 60)}`,
					createdAt: now,
					updatedAt: now,
					access: target.access,
					agentId: target.id,
					parent,
				};
				return created.id;
			}, context);
			// Lets the app open the subagent's transcript from the call's card.
			await api.details({ conversationId: child as unknown as number, agentId: target.id, agentName: target.name }, context);
			const handle = (await api.conversation(child, context))!;
			const submission = await handle.submit({ type: "input", content: args.task, requestId: `delegate:${String(api.taskId)}` }, context);
			const settled = await submission.wait(context);
			if (settled.status !== "done" || settled.type !== "input") {
				const why = "reason" in settled && settled.reason !== undefined ? ` (${String(settled.reason)})` : "";
				return { output: text(`${target.name} did not finish the task${why}.`), isError: true };
			}
			return { output: text((await host.answerText(child, settled.answer)) + footer(child as unknown as number, target.name)) };
		},
	});

	/** The reference files of the agent a conversation belongs to, as they are listed now. */
	const filesOf = (conversationId: ConversationId) => host.agent(host.meta(conversationId)?.agentId)?.files ?? [];

	const readReferenceTool = defineTool({
		name: "read_reference",
		description:
			"Read one of the reference files the person gave you, listed in the <reference_files> section, or list one of the reference folders. Pass the full path. Long files come in windows of lines; pass `offset` for the next one.",
		parameters: obj({
			path: str(),
			offset: opt(int({ description: "Line to start at, from 1" })),
			limit: opt(int({ description: "How many lines to read" })),
		}),
		replay: "safe", // reading changes nothing
		execute: async (args, api) => {
			const result = readReference(filesOf(api.conversationId), args.path, args.offset, args.limit);
			return { output: text(result.text), ...(result.isError ? { isError: true } : {}) };
		},
	});

	/** The computer-use settings of the agent a conversation belongs to. */
	const computerOf = (conversationId: ConversationId) => host.agent(host.meta(conversationId)?.agentId)?.computer;
	const agentNameOf = (conversationId: ConversationId) => host.agent(host.meta(conversationId)?.agentId)?.name ?? "An agent";

	type ComputerArgs = { action: string; app?: string; element?: number; x?: number; y?: number; text?: string; dy?: number; count?: number; path?: string };

	/** Why a computer call cannot run, or undefined when it can. Checked before asking the person and again before acting. */
	const refusal = (conversationId: ConversationId, args: ComputerArgs): string | undefined => {
		const settings = computerOf(conversationId);
		if (settings?.enabled !== true) return "Computer use is turned off for this agent.";
		const action = args.action.trim();
		if (!(ACTIONS as readonly string[]).includes(action)) return `Unknown action "${args.action}". Use one of: ${ACTIONS.join(", ")}.`;
		if (action === "list_apps") return undefined;
		if (args.app === undefined || args.app.trim() === "") return `${action} needs \`app\`, a bundle ID from list_apps.`;
		if (!settings.apps.includes(args.app)) return `You may not use ${args.app}. Apps you may use: ${settings.apps.join(", ") || "none; the person adds them in this agent's settings"}.`;
		if (isNever(args.app)) return `${args.app} cannot be used by an agent.`;
		if (!LOOKING.has(action) && action !== "open_app" && isViewOnly(args.app)) return `${args.app} can only be looked at, not controlled.`;
		if (action === "click" && args.element === undefined && (args.x === undefined || args.y === undefined)) return "click needs `element`, or both `x` and `y`.";
		if ((action === "type" || action === "key") && (args.text === undefined || args.text === "")) return `${action} needs \`text\`.`;
		if (action === "scroll" && (args.dy === undefined || args.dy === 0)) return "scroll needs `dy`: pages to scroll, positive for down.";
		if (action === "menu" && (args.path === undefined || args.path.trim() === "")) return 'menu needs `path`, such as "File > Save".';
		return undefined;
	};

	/** The request the app is sent: only the fields the action uses. */
	const requestOf = (args: ComputerArgs) => ({
		...(args.app !== undefined ? { app: args.app } : {}),
		...(args.element !== undefined ? { element: args.element } : {}),
		...(args.x !== undefined ? { x: args.x } : {}),
		...(args.y !== undefined ? { y: args.y } : {}),
		...(args.text !== undefined ? { text: args.text } : {}),
		...(args.dy !== undefined ? { dy: args.dy } : {}),
		...(args.count !== undefined ? { count: args.count } : {}),
		...(args.path !== undefined ? { path: args.path } : {}),
	});

	const computerTool = defineTool({
		name: "computer",
		description:
			"Use an app on the person's Mac, one window at a time, in the background. `app` is a bundle ID from list_apps. Every action answers with the window as it is afterwards. Actions:\n" +
			"- list_apps: the apps you may use, and which are running.\n" +
			"- open_app: start `app`, or bring its window back if it has none.\n" +
			"- screenshot: see `app`'s front window. Returns a numbered list of its controls and, if you can see images, a picture.\n" +
			"- click: a control by its `element` number from the latest screenshot of that app, or the point `x`,`y` in that screenshot's pixels. `count`: 2 for a double-click.\n" +
			"- type: `text` into `element`, or where the cursor is. It is inserted at the cursor; it does not replace what is there.\n" +
			'- key: press `text`, a key or combination: "return", "tab", "escape", "delete", "up", "cmd+s", "shift+cmd+z".\n' +
			"- scroll: `dy` pages, positive for down, in `element` or at `x`,`y`, or the window's main scrolling area.\n" +
			'- menu: choose a menu bar item by `path`, such as "File > Export…".',
		parameters: obj({
			action: str({ description: `One of: ${ACTIONS.join(", ")}` }),
			app: opt(str({ description: "Bundle ID of the app, from list_apps" })),
			element: opt(int({ description: "A control's number from the latest screenshot of this app" })),
			x: opt(num({ description: "Horizontal position, in pixels of the latest screenshot" })),
			y: opt(num({ description: "Vertical position, in pixels of the latest screenshot" })),
			text: opt(str({ description: "Text to type, or the key combination to press" })),
			dy: opt(int({ description: "Pages to scroll; positive scrolls down" })),
			count: opt(int({ description: "Number of clicks: 1 or 2" })),
			path: opt(str({ description: "Menu path, items separated by >" })),
		}),
		// A click or keystroke cut off by a crash is not repeated: it may already have happened. The agent is told.
		replay: "unsafe",
		// One action at a time: each depends on the window the last one left.
		executionMode: "sequential",
		execute: async (args, api, context) => {
			const refused = refusal(api.conversationId, args);
			if (refused !== undefined) return { output: text(refused), isError: true };
			// A model that cannot see images gets the list of controls and the window's text, and no picture is taken.
			const ref = (await api.agent(context)).model;
			const model = ref === undefined ? undefined : api.models.getModel(ref.provider, ref.modelId);
			const reply = await host.computer.perform(
				{
					action: args.action.trim() as (typeof ACTIONS)[number],
					conversationId: api.conversationId as unknown as number,
					agentName: agentNameOf(api.conversationId),
					image: model?.input.includes("image") ?? true,
					...(args.action.trim() === "list_apps" ? { apps: computerOf(api.conversationId)?.apps ?? [] } : {}),
					...requestOf(args),
				},
				context,
			);
			// The short line is what the person reads on the call's card.
			if (reply.summary !== undefined) await api.details({ summary: reply.summary }, context);
			const content: ({ type: "text"; text: string } | { type: "image"; data: string; mimeType: string })[] = [{ type: "text", text: reply.text }];
			if (reply.image !== undefined) content.push({ type: "image", data: reply.image.data, mimeType: reply.image.mimeType });
			return { output: content, ...(reply.ok ? {} : { isError: true }) };
		},
	});

	return defineExtension({
		name: "pi2",
		tools: [askUser, delegate, readReferenceTool, computerTool],
		sections: [
			section("computer_use", (input) => {
				if (!input.agent.tools.some((tool) => tool.name === "computer")) return undefined;
				return describeComputer(computerOf(input.conversationId));
			}),
			section("reference_files", (input) => {
				if (!input.agent.tools.some((tool) => tool.name === "read_reference")) return undefined;
				return describeReferenceFiles(filesOf(input.conversationId));
			}),
			section("agents", (input) => {
				const offered = input.agent.tools.some((tool) => tool.name === "delegate");
				const agents = offered ? delegatesOf(host, input.conversationId) : [];
				if (agents.length === 0) return undefined;
				return [
					"You can hand work to these agents with the delegate tool:",
					...agents.map((a) => `- ${a.name}: ${a.description}`),
					"Each delegation opens a sub-chat under this conversation. Start a new one for a new piece of work; continue an existing one (pass its number as `chat`) when the work builds on what that agent already did.",
				].join("\n");
			}),
		],
		hooks: [
			// Screenshots go stale; only the newest are sent to the model, whatever the transcript holds.
			hook(GenerationTask, {
				beforeRequest: (request) => ({ messages: pruneScreenshots(request.messages) }),
			}),
			hook(ToolTask, {
				beforeTool: async (call, api, context) => {
					const meta = host.meta(api.conversationId);
					const isComputer = call.name === "computer";
					const args = call.arguments as ComputerArgs;
					let description: string | null = null;
					if (isComputer) {
						// Computer use has its own rule: whatever changes something asks, app by app, whatever the file access.
						// A call that cannot run anyway is not worth a question; the tool explains why itself.
						if (typeof args.action !== "string" || refusal(api.conversationId, args) !== undefined) return undefined;
						if (computerOf(api.conversationId)?.ask === false || LOOKING.has(args.action.trim())) return undefined;
					} else if (meta?.access !== "ask" || !(GATED.has(call.name) || host.changesThings(call.name))) {
						return undefined;
					}
					const key = isComputer ? `computer:${args.app ?? ""}` : call.name;
					if (meta?.autoApprove?.includes(key)) return undefined;
					if (isComputer) {
						// Ask the app what the action would act on, so the person approves "the Send button", not "control 12".
						const described = await host.computer.perform(
							{ action: "describe", of: args.action.trim(), conversationId: api.conversationId as unknown as number, agentName: agentNameOf(api.conversationId), ...requestOf(args) },
							context,
							5_000,
						);
						description = described.ok && described.text.trim() !== "" ? described.text.trim() : plainDescription(args);
					}
					const decision = await host.inbox.ask(
						{
							id: String(api.taskId),
							kind: "approval",
							conversationId: api.conversationId as unknown as number,
							callId: call.id,
							tool: call.name,
							arguments: call.arguments,
							question: description,
							createdAt: Date.now(),
						},
						context,
					);
					if (decision === "always") await host.allowAlways(api.conversationId, key);
					return decision === "deny" ? { block: "The person declined this action. Do not retry it; ask what they would like instead." } : undefined;
				},
			}),
		],
	});
}
