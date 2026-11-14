// What pi2 adds to every conversation: approval before risky tools, a way to ask the person, and delegation.

import { resolve } from "node:path";
import {
	type AgentChange,
	AgentDoc,
	configure,
	type ConversationId,
	defineExtension,
	defineTool,
	type DocumentReader,
	type Extension,
	GenerationTask,
	hook,
	type HookApi,
	section,
	type ToolHookCall,
	ToolTask,
	type Tx,
} from "@earendil-works/pi-durable";
import { bool, int, num, obj, opt, str } from "@earendil-works/pi-schema";
import type { Context } from "@earendil-works/chord/context";
import {
	BROWSER_ACTIONS,
	type BrowserAction,
	type BrowserHost,
	type BrowserRequest,
	checkAddress,
	describeBrowser,
	plainBrowserDescription,
	searchAddress,
	UNASKED,
	uploadable,
} from "./browser.ts";
import { ACTIONS, type ComputerHost, describeComputer, isNever, isViewOnly, LOOKING, plainDescription, pruneScreenshots } from "./computer.ts";
import { describeReferenceFiles, readReference } from "./reference.ts";
import type { FeatureParts } from "./features.ts";
import { judgeCommand, proposeRule, ruleFolder } from "./rules.ts";
import { isPutAway } from "./archive.ts";
import { type AgentProfile, type Inbox, type InboxItem, Library, type Meta } from "./state.ts";
import { madeWorktrees, repoOf } from "./worktrees.ts";

type RuleProposal = NonNullable<InboxItem["rule"]>;

/** Tools that change things on the Mac, and so wait for approval when a conversation's access is "ask". */
const GATED = new Set(["bash", "write", "edit", "write_document"]);

export type Host = {
	/** Features in files of their own; their tools, sections and hooks join this extension's. Filled in by main. */
	features: FeatureParts[];
	inbox: Inbox;
	computer: ComputerHost;
	browser: BrowserHost;
	/** The folder a conversation works in when none was chosen for it. */
	scratchFolder(): string;
	/** Whether a tool outside the built-in set changes things, and so needs approval under "ask". */
	changesThings(tool: string): boolean;
	meta(conversationId: ConversationId): Meta | undefined;
	agent(id: string | undefined): AgentProfile | undefined;
	allowAlways(conversationId: ConversationId, tool: string): Promise<void>;
	/** Keep a rule the person chose in an approval, after the same checks as one added by hand. Never throws. */
	addRule(agentId: string, folder: string, words: string[]): Promise<void>;
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

/** What the model is told when the person says no. */
const DECLINED = "The person declined this action. Do not retry it; ask what they would like instead.";

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
				if (meta === undefined || meta.parent !== parent || isPutAway(meta) || agent === undefined) {
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

	/** The browser settings of the agent a conversation belongs to. */
	const browserOf = (conversationId: ConversationId) => host.agent(host.meta(conversationId)?.agentId)?.browser;

	type BrowserArgs = { action: string; url?: string; query?: string; element?: number; text?: string; submit?: boolean; option?: string; dy?: number; path?: string; offset?: number };

	/**
	 * What a browser call asks of the app, or why it cannot run. Checked before asking the person and again before
	 * acting. The address, the search and the file to upload are settled here, so the app is only ever sent a public
	 * http(s) address and a file the agent may use.
	 */
	const prepareBrowser = async (api: DocumentReader & { conversationId: ConversationId }, args: BrowserArgs, context: Context): Promise<{ request: BrowserRequest } | { refused: string }> => {
		if (browserOf(api.conversationId)?.enabled !== true) return { refused: "The browser is turned off for this agent." };
		const action = args.action.trim() as BrowserAction;
		if (!BROWSER_ACTIONS.includes(action)) return { refused: `Unknown action "${args.action}". Use one of: ${BROWSER_ACTIONS.join(", ")}.` };
		if ((action === "click" || action === "type" || action === "select" || action === "upload") && args.element === undefined) {
			return { refused: `${action} needs \`element\`, a number from the latest view of the page.` };
		}
		switch (action) {
			case "open": {
				const checked = checkAddress(args.url ?? "");
				return "refused" in checked ? checked : { request: { action, url: checked.url } };
			}
			case "search": {
				const query = (args.query ?? "").trim();
				return query === "" ? { refused: "search needs `query`, the words to search for." } : { request: { action, query, url: searchAddress(query) } };
			}
			case "read":
				if (args.offset !== undefined && args.offset < 0) return { refused: "`offset` cannot be negative." };
				return { request: { action, ...(args.offset !== undefined && args.offset > 0 ? { offset: args.offset } : {}) } };
			case "screenshot":
			case "back":
				return { request: { action } };
			case "scroll":
				if (args.dy === undefined || args.dy === 0) return { refused: "scroll needs `dy`: pages to scroll, positive for down." };
				return { request: { action, dy: args.dy } };
			case "click":
				return { request: { action, element: args.element! } };
			case "type":
				if (args.text === undefined) return { refused: "type needs `text`. An empty text clears the field." };
				return { request: { action, element: args.element!, text: args.text, ...(args.submit === true ? { submit: true } : {}) } };
			case "select":
				if (args.option === undefined || args.option.trim() === "") return { refused: "select needs `option`, the choice to pick, as the page words it." };
				return { request: { action, element: args.element!, option: args.option } };
			case "upload": {
				// The conversation's folder counts only when the conversation may read files there: with tools off, an
				// agent that cannot open a file should not be able to send it to a website either.
				const reads = host.meta(api.conversationId)?.access !== "none";
				const folder = reads ? ((await api.snapshot(AgentDoc, api.conversationId, context))?.cwd ?? host.scratchFolder()) : undefined;
				const file = uploadable(args.path ?? "", folder, filesOf(api.conversationId));
				return "refused" in file ? file : { request: { action, element: args.element!, path: file.path } };
			}
		}
	};

	/**
	 * What the approval step settled about a call, for the tool to act on: the description the app gave, which the action
	 * must still match when it runs, or the app's reason why it cannot be done at all. Kept by call, in memory: after a
	 * restart the hook runs again before the tool does.
	 */
	const browserVerdicts = new Map<string, { expect: string } | { refuse: string }>();
	const settleBrowser = (callId: string, verdict: { expect: string } | { refuse: string }) => {
		browserVerdicts.set(callId, verdict);
		// A call stopped between the question and the action leaves its verdict behind; do not let those pile up.
		if (browserVerdicts.size > 200) browserVerdicts.delete(browserVerdicts.keys().next().value!);
	};

	const browserTool = defineTool({
		name: "browser",
		description:
			"Browse the web in pi²'s own browser, which the person can watch and use too. Every action answers with the page as it is afterwards: its title and address, a numbered list of what can be acted on, and its text, where [n] marks where each of those sits. `element` is always a number from the latest view. Actions:\n" +
			"- open: go to `url`.\n" +
			"- search: search the web for `query`; the results come back as a page.\n" +
			"- read: the current page again, as it is now. A long page comes in parts; `offset` starts further in.\n" +
			"- screenshot: a picture of the page as it looks, if you can see images.\n" +
			"- click: a link, button, checkbox or other `element`.\n" +
			"- type: put `text` into the field `element`, replacing what it holds. `submit`: true presses Return afterwards. Password fields are refused: the person signs in themselves.\n" +
			"- select: pick `option` in the drop-down list `element`, by the words the page shows for it.\n" +
			"- scroll: `dy` pages, positive for down. Reading does not need it; use it for pages that load more as they are scrolled.\n" +
			"- back: return to the page before.\n" +
			"- upload: choose the file at `path` in the file input `element`. Only a file in this conversation's folder or one of your reference files.",
		parameters: obj({
			action: str({ description: `One of: ${BROWSER_ACTIONS.join(", ")}` }),
			url: opt(str({ description: "The address to open; http or https" })),
			query: opt(str({ description: "What to search the web for" })),
			element: opt(int({ description: "A number from the latest view of the page" })),
			text: opt(str({ description: "Text to put into the field" })),
			submit: opt(bool({ description: "Press Return after typing" })),
			option: opt(str({ description: "The choice to pick in a drop-down list" })),
			dy: opt(int({ description: "Pages to scroll; positive scrolls down" })),
			path: opt(str({ description: "Full path of the file to upload" })),
			offset: opt(int({ description: "For read: the character of the page's text to start at" })),
		}),
		// A click or a submitted form cut off by a crash is not repeated: it may already have happened. The agent is told.
		replay: "unsafe",
		// One action at a time: each depends on the page the last one left.
		executionMode: "sequential",
		execute: async (args, api, context) => {
			const verdict = browserVerdicts.get(api.callId);
			browserVerdicts.delete(api.callId);
			const prepared = await prepareBrowser(api, args, context);
			if ("refused" in prepared) return { output: text(prepared.refused), isError: true };
			if (verdict !== undefined && "refuse" in verdict) return { output: text(verdict.refuse), isError: true };
			const request = prepared.request;
			let note = "";
			if (request.action === "screenshot") {
				// A model that cannot see images is given the page as text instead, and no picture is taken.
				const ref = (await api.agent(context)).model;
				const model = ref === undefined ? undefined : api.models.getModel(ref.provider, ref.modelId);
				if (model !== undefined && !model.input.includes("image")) {
					request.action = "read";
					note = "Your model cannot see pictures, so here is the page as text instead.\n\n";
				}
			}
			const reply = await host.browser.perform(
				{ ...request, ...(verdict !== undefined ? { expect: verdict.expect } : {}), conversationId: api.conversationId as unknown as number, agentName: agentNameOf(api.conversationId) },
				context,
				// Loading a slow page is given longer than a click in a window.
				90_000,
			);
			// The short line is what the person reads on the call's card.
			if (reply.summary !== undefined) await api.details({ summary: reply.summary }, context);
			const content: ({ type: "text"; text: string } | { type: "image"; data: string; mimeType: string })[] = [{ type: "text", text: note + reply.text }];
			if (reply.image !== undefined) content.push({ type: "image", data: reply.image.data, mimeType: reply.image.mimeType });
			return { output: content, ...(reply.ok ? {} : { isError: true }) };
		},
	});

	/**
	 * The browser's own rule for asking first: by what an action would do, site by site, whatever the file access.
	 * Looking and moving between pages are never asked about, and neither is following a plain link, which only goes
	 * where opening its address would.
	 */
	const approveBrowser = async (call: ToolHookCall, api: HookApi, context: Context): Promise<{ block: string } | undefined> => {
		const args = call.arguments as BrowserArgs;
		browserVerdicts.delete(call.id);
		if (typeof args.action !== "string") return undefined;
		const action = args.action.trim();
		if (UNASKED.has(action) || browserOf(api.conversationId)?.ask === false) return undefined;
		// A call that cannot run anyway is not worth a question; the tool explains why itself.
		const prepared = await prepareBrowser(api, args, context);
		if ("refused" in prepared) return undefined;
		const conversationId = api.conversationId as unknown as number;
		// Ask the app what the action would do, so the person approves "Click “Submit” on example.com", not "element 12".
		const described = await host.browser.perform({ ...prepared.request, action: "describe", of: action, conversationId, agentName: agentNameOf(api.conversationId) }, context, 5_000);
		let description = plainBrowserDescription(args);
		let site = "";
		if (described.ok) {
			site = described.host ?? "";
			if (described.text.trim() !== "") {
				description = described.text.trim();
				// The action is done only if this is still what it would do when it runs.
				settleBrowser(call.id, { expect: described.text });
				if (action === "click" && described.navigates === true) return undefined;
			}
		} else if (described.unreachable !== true || !host.browser.available) {
			// The app says it cannot be done (no such element, a password field), or there is no app. Nothing is asked,
			// and the tool answers with the reason instead of trying.
			settleBrowser(call.id, { refuse: described.text.trim() === "" ? "The browser could not do that." : described.text });
			return undefined;
		}
		const key = site === "" ? undefined : `browser:${site}`;
		if (key !== undefined && host.meta(api.conversationId)?.autoApprove?.includes(key)) return undefined;
		const decision = await host.inbox.ask(
			{
				id: String(api.taskId),
				kind: "approval",
				conversationId,
				callId: call.id,
				tool: call.name,
				arguments: call.arguments,
				question: description,
				...(site === "" ? {} : { site }),
				createdAt: Date.now(),
			},
			context,
		);
		// Without a site to name there is nothing for "always" to cover, so it allows this once.
		if (decision === "always" && key !== undefined) await host.allowAlways(api.conversationId, key);
		return decision === "deny" ? { block: DECLINED } : undefined;
	};

	/**
	 * Commands a rule let through, by tool task, so their results can say so (see `afterTool`). Kept in memory: a command
	 * cut off by a crash ends as interrupted, and its result then simply goes without the note.
	 */
	const allowedByRule = new Map<string, string[]>();

	/**
	 * The person's rules for an agent's shell commands (rules.ts): whether this command is covered where it runs, and if
	 * not, the rule to offer. Rules belong to the agent and a folder, so they hold in every conversation of that agent in
	 * that folder, sub-chats and scheduled runs included, and in the same folder of every worktree pi² made from that
	 * repository: a rule offered inside one is for the main checkout's folder (`ruleFolder`).
	 */
	const shellRules = async (call: ToolHookCall, api: HookApi, context: Context): Promise<{ allowed: boolean; proposal?: RuleProposal }> => {
		const agent = host.agent(host.meta(api.conversationId)?.agentId);
		const command = (call.arguments as { command?: unknown }).command;
		if (agent === undefined || typeof command !== "string") return { allowed: false };
		const folder = resolve((await api.snapshot(AgentDoc, api.conversationId, context))?.cwd ?? host.scratchFolder());
		const made = await madeWorktrees(api, context);
		const verdict = judgeCommand(command, folder, agent.commandRules ?? [], made);
		if (verdict.allowed) {
			allowedByRule.set(String(api.taskId), verdict.rules);
			if (allowedByRule.size > 200) allowedByRule.delete(allowedByRule.keys().next().value!);
			return { allowed: true };
		}
		const words = proposeRule(command);
		if (words === undefined) return { allowed: false };
		const kept = ruleFolder(folder, made);
		// The approval says so when the rule will also hold in worktrees: it is kept for a main checkout's folder.
		const acrossWorktrees = kept !== folder || (await repoOf(kept))?.worktree === false;
		return { allowed: false, proposal: { words, folder: kept, ...(acrossWorktrees ? { worktrees: true as const } : {}) } };
	};

	return defineExtension({
		name: "pi2",
		tools: [askUser, delegate, readReferenceTool, computerTool, browserTool, ...host.features.flatMap((feature) => feature.tools ?? [])],
		sections: [
			section("computer_use", (input) => {
				if (!input.agent.tools.some((tool) => tool.name === "computer")) return undefined;
				return describeComputer(computerOf(input.conversationId));
			}),
			section("browser", (input) => {
				if (!input.agent.tools.some((tool) => tool.name === "browser")) return undefined;
				return describeBrowser(browserOf(input.conversationId));
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
			...host.features.flatMap((feature) => feature.sections ?? []),
		],
		hooks: [
			...host.features.flatMap((feature) => feature.hooks ?? []),
			// Screenshots go stale; only the newest are sent to the model, whatever the transcript holds.
			hook(GenerationTask, {
				beforeRequest: (request) => ({ messages: pruneScreenshots(request.messages) }),
			}),
			hook(ToolTask, {
				beforeTool: async (call, api, context) => {
					if (call.name === "browser") return approveBrowser(call, api, context);
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
					let proposal: RuleProposal | undefined;
					if (call.name === "bash") {
						const rules = await shellRules(call, api, context);
						if (rules.allowed) return undefined;
						proposal = rules.proposal;
					}
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
							...(proposal === undefined ? {} : { rule: proposal }),
							createdAt: Date.now(),
						},
						context,
					);
					if (decision === "always") await host.allowAlways(api.conversationId, key);
					// The rule is the engine's own proposal; the app only says "rule". Either way the person allowed this command.
					if (decision === "rule" && proposal !== undefined && meta?.agentId !== undefined) await host.addRule(meta.agentId, proposal.folder, proposal.words);
					return decision === "deny" ? { block: DECLINED } : undefined;
				},
				afterTool: (_call, result, api) => {
					const rules = allowedByRule.get(String(api.taskId));
					if (rules === undefined) return undefined;
					allowedByRule.delete(String(api.taskId));
					// Stopped by a later check, the command never ran, and no rule allowed anything.
					if (result.diagnostics?.some((diagnostic) => diagnostic.code === "blocked")) return undefined;
					const details = result.details !== null && typeof result.details === "object" && !Array.isArray(result.details) ? result.details : {};
					// The transcript shows which rule let the command run without asking.
					return { ...result, details: { ...details, allowedBy: rules } };
				},
			}),
		],
	});
}
