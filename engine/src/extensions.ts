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
	type ToolExecutionApi,
	type SettledSubmissionRecord,
	type SubmissionId,
	type ToolHookCall,
	ToolTask,
	type Tx,
} from "@earendil-works/pi-durable";
import { bool, int, num, obj, opt, str } from "@earendil-works/pi-schema";
import { awaitWithContext, type Context } from "@earendil-works/chord/context";
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
import { ACTIONS, type ComputerHost, describeComputer, givenApp, isNever, LOOKING, lookOnly, mayUse, plainDescription, pruneScreenshots } from "./computer.ts";
import { describeReferenceFiles, readReference } from "./reference.ts";
import type { FeatureParts } from "./features.ts";
import { judgeCommand, proposeRule, ruleFolder } from "./rules.ts";
import { isArchived, isPutAway } from "./archive.ts";
import { noteSubChats, subChatsTool } from "./subchats.ts";
import { ALLOWED_BY_EVERYTHING, type AgentProfile, type Inbox, type InboxItem, Library, type Meta, projectFrom } from "./state.ts";
import { madeWorktrees, makeWorktree, repoOf, subChatFolder, worktreeOf } from "./worktrees.ts";
import { limitOf } from "./limitwait.ts";
import { CARRY_ON, plainProviderError } from "./providererror.ts";
import { nearlyUsedUp } from "./limits.ts";
import { unlessMessaged } from "./heed.ts";
import { handOffWords, reportRun, waitForRun } from "./reports.ts";
import { watch } from "./wakes.ts";

type RuleProposal = NonNullable<InboxItem["rule"]>;

/** Tools that change things on the Mac, and so wait for approval when a conversation's access is "ask". */
const GATED = new Set(["bash", "write", "edit", "write_document"]);

export type Host = {
	/** Features in files of their own; their tools, sections and hooks join this extension's. Filled in by main. */
	features: FeatureParts[];
	/**
	 * Settles once the engine has its conversations, agents and `PATH`, just before it resumes the last engine's work.
	 * Every tool call waits for it before anything is decided: work can be set going earlier than that (a feature
	 * writing into a transcript as it starts, a schedule that came due), and a call judged against agents not yet
	 * loaded would be asked about without its rule, or asked about although a rule covers it.
	 */
	ready: Promise<void>;
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
	/** How a conversation of `agent` is configured; a sub-chat goes without handing work on and scheduling. */
	agentChange(agent: AgentProfile, options: { subChat: boolean }): Promise<AgentChange>;
	answerText(conversationId: ConversationId, submissionAnswer: unknown): Promise<string>;
	subChatUsage(conversationId: number, context: Context): Promise<string>;
	/**
	 * Send a message to a sub-chat that an earlier call created, without waiting for its answer (`waitForChat` in heed.ts
	 * waits for it): its submission's id, or undefined when it is gone.
	 */
	sendToChat(conversationId: number, content: string, requestId: string): Promise<number | undefined>;
	/** Every conversation pi² keeps, by id: sub-chats, archived and deleted ones included. */
	conversations(): Record<string, Meta>;
	/** Whether a conversation has work running: a run, a tool call, a question or approval it waits on. */
	working(conversationId: number): boolean;
};

const text = (value: string) => [{ type: "text" as const, text: value }];

/** What the model is told when the person says no. */
const DECLINED = "The person declined this action. Do not retry it; ask what they would like instead.";

/** The longest title an agent may give a sub-chat; the sidebar shows far less. */
const TITLE_MAX = 80;

/** A sub-chat's title as an agent gave it: on one line, trimmed and cut to `TITLE_MAX`; undefined when there is none. */
export function titleOf(given: string | undefined): string | undefined {
	const title = (given ?? "").replace(/\s+/g, " ").trim();
	if (title === "") return undefined;
	return title.length > TITLE_MAX ? `${title.slice(0, TITLE_MAX - 1).trimEnd()}…` : title;
}

/**
 * What `delegate` answers when a sub-chat's run ended without an answer: why, in the provider's own words when it was
 * the provider's error (shortened, with no keys or account identifiers), and how to carry on unless `advise` is false.
 */
export function unfinished(name: string, chat: number, reason: string | undefined, detail: string | undefined, advise = true): string {
	const resume = advise ? ` The sub-chat is kept as it stopped: to carry on from there, call delegate again with chat: ${chat}.` : "";
	if (reason === "model_error") {
		let said = plainProviderError(detail ?? "") || "no message";
		// The engine's own notice about giving up on a limit can also tell the agent to continue.
		if (!advise && detail?.trimEnd().endsWith(CARRY_ON) && said.endsWith(` ${CARRY_ON}`)) said = said.slice(0, -CARRY_ON.length - 1);
		const limit = advise && detail !== undefined && !detail.includes(CARRY_ON) && limitOf(detail, undefined, Date.now()) !== undefined;
		const why = limit ? " The provider refused it for its limit, so carrying on works once the limit has reset." : "";
		return `${name} did not finish the task: the model's provider answered with an error: “${said}”.${why}${resume}`;
	}
	if (reason === "aborted") return `${name} did not finish the task: its run was stopped, by the person or with this conversation.${resume}`;
	const said = detail === undefined || detail === "" ? "" : `: ${plainProviderError(detail)}`;
	return `${name} did not finish the task (${reason ?? "no answer"}${said}).${resume}`;
}

/** The end of `delegate`'s answer: which sub-chat did the work, where, and how to carry it on. */
async function footerOf(read: DocumentReader, id: number, name: string, title: string, note: string, context: Context): Promise<string> {
	const own = await worktreeOf(read, id, context);
	const where = own === undefined ? "" : `, working in a worktree of its own at ${own.path} on the branch ${own.branch}`;
	return `\n\n(Sub-chat ${id}, “${title}”, with ${name}${where}.${note} To continue it, call delegate again with chat: ${id}.)`;
}

/** What the sub-chat used, then how its subscription's windows stand if they are nearly used up. */
async function resultUsage(host: Host, read: DocumentReader, id: number, context: Context): Promise<string> {
	const usage = await host.subChatUsage(id, context);
	const provider = (await read.snapshot(AgentDoc, id as unknown as ConversationId, context))?.model?.provider;
	const views = host.features.find((feature) => feature.planLimits !== undefined)?.planLimits?.() ?? [];
	const line = nearlyUsedUp(views.find((view) => view.id === provider), Date.now());
	return [usage, line].filter(Boolean).map((each) => `\n\n${each}`).join("");
}

type SubChatResult = { text: string; failed: false } | { text: string; failed: true; withoutAdvice: string; usage: string };

/**
 * A sub-chat's work as `delegate` gives it, for one that was not waited for (wakes.ts): its answer and how to carry it
 * on, or why it has none. `settled` is undefined when its submission could not be found.
 */
export async function subChatResult(host: Host, read: DocumentReader, child: number, name: string, settled: SettledSubmissionRecord | undefined, context: Context): Promise<SubChatResult> {
	if (settled === undefined || settled.status !== "done" || settled.type !== "input") {
		const reason = settled === undefined ? "its message could not be found" : "reason" in settled && settled.reason !== undefined ? String(settled.reason) : undefined;
		const detail = settled !== undefined && "detail" in settled && settled.detail !== undefined ? String(settled.detail) : undefined;
		return {
			text: unfinished(name, child, reason, detail),
			withoutAdvice: unfinished(name, child, reason, detail, false),
			usage: await resultUsage(host, read, child, context),
			failed: true,
		};
	}
	const title = host.meta(child as unknown as ConversationId)?.title ?? "";
	return { text: (await host.answerText(child as unknown as ConversationId, settled.answer)) + (await footerOf(read, child, name, title, "", context)) + (await resultUsage(host, read, child, context)), failed: false };
}

/** What becomes of a sub-chat's answer that `delegate` does not wait for. */
const COMES_AS_MESSAGE = 'Its answer will come to you as a message when it is done, waking you if you are not answering then; sub_chats with action "wait" waits for it here instead.';

/** What `delegate` answers at once when it does not wait, and what becomes of the answer (`how`, in a project: reports.ts). */
const startedWords = (id: number, name: string, title: string, how = COMES_AS_MESSAGE) =>
	`Sub-chat ${id}, “${title}”, with ${name}, is working on it. ${how} To continue it later, call delegate again with chat: ${id}.`;

/** The agents a conversation may delegate to, from its own agent's list. */
function delegatesOf(host: Host, conversationId: ConversationId): AgentProfile[] {
	const own = host.agent(host.meta(conversationId)?.agentId);
	return (own?.delegates ?? []).map((id) => host.agent(id)).filter((a): a is AgentProfile => a !== undefined);
}

/**
 * The person's command rules applied to a `bash` call's `command` where its conversation works (rules.ts), with the folder
 * and worktrees they were judged against. Undefined when there is no agent or no command to judge.
 */
async function judgeShell(host: Host, conversationId: ConversationId, command: unknown, read: DocumentReader, context: Context) {
	const agent = host.agent(host.meta(conversationId)?.agentId);
	if (agent === undefined || typeof command !== "string") return undefined;
	const folder = resolve((await read.snapshot(AgentDoc, conversationId, context))?.cwd ?? host.scratchFolder());
	const made = await madeWorktrees(read, context);
	return { command, folder, made, verdict: judgeCommand(command, folder, agent.commandRules ?? [], made) };
}

/**
 * Whether a `bash` call running `command` in this conversation would wait for the person's approval, judged as
 * `beforeTool` judges it, with the settings as they are now: under Ask first, unless Always Allow bash Here or a command
 * rule covers it. A command in the background is judged exactly as one that is waited for, so this answers for both.
 * commands.ts asks it before moving a command that reached its time limit to the background: only one that starting
 * there would not have asked about is moved.
 */
export async function commandAsks(host: Host, conversationId: ConversationId, command: string, read: DocumentReader, context: Context): Promise<boolean> {
	const meta = host.meta(conversationId);
	// The same three checks as `beforeTool`'s for `bash`, in the same order, after Allow everything, under which the
	// approval would be answered without asking (state.ts, `Inbox`).
	if (meta?.allowEverything === true) return false;
	if (meta?.access !== "ask") return false;
	if (meta.autoApprove?.includes("bash")) return false;
	return (await judgeShell(host, conversationId, command, read, context))?.verdict.allowed !== true;
}

export function pi2Extension(host: Host): Extension {
	const askUser = defineTool({
		name: "ask_user",
		description: "Ask the person a question and wait for their answer. Use it when you need a decision or a fact only they have; do not use it for things you can find out yourself.",
		parameters: obj({ question: str() }),
		replay: "safe", // after a restart the question is simply asked again
		execute: async (args, api, context) => {
			const asked = await unlessMessaged(
				api,
				(waiting) =>
					host.inbox.ask(
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
						api,
						waiting,
					),
				context,
			);
			// The person wrote a message instead of answering (heed.ts): the question is taken away, and the message follows.
			if ("messaged" in asked) return { output: text("The person sent you a message instead of answering this question; it follows. Ask again if you still need the answer."), details: { waitEnded: true } };
			return { output: text(asked.value) };
		},
	});

	const delegate = defineTool({
		name: "delegate",
		description:
			"Hand a self-contained task to another agent and get its answer back. Name one of the agents listed in the <agents> section, and write the task so it stands on its own: the other agent sees none of this conversation. " +
			"Each call opens a sub-chat the person can watch. To carry on an earlier sub-chat instead of starting a new one, pass its number as `chat`; that agent then still remembers what it did there. " +
			"Once a sub-chat's work is done and you will not continue it, archive it with sub_chats.\n" +
			"With `wait: false` the call returns at once with the sub-chat's number, and its answer comes to you later as a message, waking you if you are not answering: use it to keep several going and stay reachable meanwhile.\n" +
			"Give each new sub-chat a short `title` that tells it apart from the others in the person's sidebar, such as \"Fix login timeout\"; without one it is named after the agent and the first words of the task, or the worktree's branch. Passing `title` with `chat` renames that sub-chat, unless the person renamed it themselves.\n" +
			"A new sub-chat works in this conversation's folder. To give it a git worktree of its own instead, pass `worktree` with a branch name: use it when several sub-chats change the same repository at once, so each works on its own branch in its own checkout and none disturbs the others or this folder. " +
			"pi² makes the worktree from the repository the sub-chat would work in, as New Worktree… does: the sub-chat works there and is told so, the agent's set-up command runs in it, and the person sees its branch. " +
			"The new branch starts from the commit this conversation's folder is on, or from `from`: a branch, tag or commit as the repository has it now (it is not fetched first, so fetch first if you need the latest). A branch that already exists is checked out as it is, unless `from` is given. " +
			"If the worktree cannot be made, the call fails with the reason and nothing is handed over. Continuing a sub-chat keeps the folder it has. Depending on the person's settings, they may be asked before the worktree is made.\n" +
			"If the person sends you a message while you wait, the call stops waiting and you get their message; the sub-chat carries on as if you had passed `wait: false`.",
		parameters: obj({
			agent: str(),
			task: str(),
			chat: opt(int({ description: "Number of an earlier sub-chat of this conversation to continue" })),
			title: opt(str({ description: `A short name for the sub-chat that the person sees, ${TITLE_MAX} characters at most, such as "Fix login timeout". With chat, renames it` })),
			worktree: opt(str({ description: "For a new sub-chat: the branch for a git worktree of its own, such as \"fix-login-timeout\"" })),
			from: opt(str({ description: "With worktree: what the new branch starts from, such as \"origin/main\"; by default the commit this conversation's folder is on" })),
			wait: opt(bool({ description: "false: return at once; the answer comes later as a message. Default true" })),
		}),
		replay: "safe", // a rerun after a crash finds the same child conversation and submission
		execute: async (args, api, context) => {
			const parent = api.conversationId as unknown as number;
			const footer = (id: number, name: string, title: string, note = "") => footerOf(api, id, name, title, note, context);
			const usage = (id: number) => resultUsage(host, api, id, context);
			/** For `wait: false`: watch the sub-chat's answer, to wake this agent with it, and answer at once. */
			const handOff = async (child: number, submissionId: number, name: string, title: string, agentId: string) => {
				// A run of a project's orchestrator has a report, kept before the watch (reports.ts).
				await reportRun(parent, { submissionId, conversationId: child, agentId, title });
				const refused = await watch({ key: `delegate:${String(api.taskId)}`, conversationId: parent, kind: "subchat", ref: String(child), label: `sub-chat ${child} “${title}”`, startedAt: Date.now(), submissionId, agent: name });
				if (refused !== undefined) return { output: text(refused), isError: true };
				return { output: text(startedWords(child, name, title, handOffWords(parent))) };
			};
			/**
			 * Wait for a sub-chat's answer to `submission` and give it, unless the person sends a message first (heed.ts): then
			 * the sub-chat carries on as one handed over with `wait: false`, its answer coming later as a message.
			 */
			const answer = async (chat: number, agent: AgentProfile, title: string, submission: number, note = "") => {
				// Its report, in a project, is taken by this wait (reports.ts); `taken` is false if it was given another way first.
				const outcome = await waitForRun(api, parent, { submissionId: submission, conversationId: chat, agentId: agent.id, title }, context);
				if ("messaged" in outcome) {
					const handed = await handOff(chat, submission, agent.name, title, agent.id);
					if (handed.isError === true) return handed;
					return {
						output: text(
							`The person sent you a message, so you stopped waiting for sub-chat ${chat} (“${title}”, with ${agent.name}); their message follows. ` +
								`The sub-chat is still working on the task: nothing was stopped. ${handOffWords(parent) ?? COMES_AS_MESSAGE} To continue it later, call delegate again with chat: ${chat}.` +
								note,
						),
						details: { conversationId: chat, agentId: agent.id, agentName: agent.name, waitEnded: true },
					};
				}
				if (!outcome.taken) return { output: text(`The report of sub-chat ${chat}'s run was already given to you, so it is not given again here. To continue it, call delegate again with chat: ${chat}.`) };
				const settled = outcome.settled;
				if (settled.status !== "done" || settled.type !== "input") {
					const reason = "reason" in settled && settled.reason !== undefined ? String(settled.reason) : undefined;
					const detail = "detail" in settled && settled.detail !== undefined ? String(settled.detail) : undefined;
					return { output: text(unfinished(agent.name, chat, reason, detail) + note + (await usage(chat))), isError: true };
				}
				const kept = (await api.snapshot(Library, context))?.conversations[String(chat)]?.title ?? title;
				return { output: text((await host.answerText(chat as unknown as ConversationId, settled.answer)) + (await footer(chat, agent.name, kept, note)) + (await usage(chat))) };
			};
			const title = titleOf(args.title);
			if (args.from !== undefined && args.worktree === undefined) return { output: text("`from` says where a sub-chat's worktree starts; pass it with `worktree`."), isError: true };
			if (args.worktree !== undefined && args.chat !== undefined) {
				return { output: text("`worktree` is for a new sub-chat. A sub-chat that is continued keeps the folder it has; leave `chat` out to start a new one in a worktree."), isError: true };
			}
			if (args.worktree !== undefined && args.worktree.trim() === "") return { output: text("`worktree` needs a branch name, such as \"fix-login-timeout\"."), isError: true };
			if (args.chat !== undefined) {
				const meta = host.meta(args.chat as unknown as ConversationId);
				const agent = host.agent(meta?.agentId);
				if (meta === undefined || meta.parent !== parent || (isPutAway(meta) && !isArchived(meta)) || agent === undefined) {
					return { output: text(`There is no sub-chat ${args.chat} in this conversation to continue. Leave \`chat\` out to start a new one.`), isError: true };
				}
				// One this conversation archived (sub_chats) comes back to be continued; the line says so.
				if (isArchived(meta)) {
					await api.commit(async (tx) => void delete (await tx.doc(Library)).conversations[String(args.chat)]?.archivedAt, context);
					await noteSubChats(api, api.conversationId, { action: "restored", chats: [{ id: args.chat, title: meta.title }] }, `delegate:${String(api.taskId)}:restored`, context);
				}
				// A new title renames it, unless the person chose its name: theirs stands.
				let named = meta.title;
				let note = "";
				if (title !== undefined && title !== meta.title) {
					if (meta.renamed === true) note = " The person renamed this sub-chat, so it keeps their name.";
					else {
						await api.commit(async (tx) => {
							const stored = (await tx.doc(Library)).conversations[String(args.chat)];
							if (stored !== undefined && stored.renamed !== true) stored.title = title;
						}, context);
						named = title;
					}
				}
				await api.details({ conversationId: args.chat, agentId: agent.id, agentName: agent.name }, context);
				const sent = await host.sendToChat(args.chat, args.task, `delegate:${String(api.taskId)}`);
				if (sent === undefined) return { output: text(`Sub-chat ${args.chat} could not be reached.`), isError: true };
				if (args.wait === false) {
					const handed = await handOff(args.chat, sent, agent.name, named, agent.id);
					return note === "" || handed.isError === true ? handed : { output: text(`${startedWords(args.chat, agent.name, named, handOffWords(parent))}${note}`) };
				}
				return answer(args.chat, agent, named, sent, note);
			}
			const allowed = delegatesOf(host, api.conversationId);
			const target = allowed.find((a) => a.name.toLowerCase() === args.agent.trim().toLowerCase() || a.id === args.agent.trim());
			if (target === undefined) {
				const names = allowed.map((a) => a.name).join(", ");
				return { output: text(names === "" ? "This conversation has no agents to delegate to." : `Unknown agent "${args.agent}". Available: ${names}.`), isError: true };
			}
			const profile = await host.agentChange(target, { subChat: true });
			// The helper works where its parent works now (its worktree, say), unless it has a project of its own elsewhere.
			const here = (await api.snapshot(AgentDoc, api.conversationId, context))?.cwd ?? null;
			const change = { ...profile, cwd: await subChatFolder(here, target.cwd) };
			const named = title ?? (args.worktree !== undefined ? `${target.name}: ${args.worktree.trim()}` : `${target.name}: ${args.task.trim().split("\n")[0]!.slice(0, 60)}`);
			const waits = args.wait !== false;
			const child = await api.commit(async (tx: Tx) => {
				// A call run again after a crash finds the sub-chat it made: one made before #295 was owned by its call.
				const owned = (await tx.scanConversations({ ownerTaskId: api.taskId }, 1)).items[0];
				if (owned !== undefined) return owned.id;
				const library = await tx.doc(Library);
				const made = Object.entries(library.conversations).find(([, meta]) => meta.madeBy === String(api.taskId));
				if (made !== undefined) return Number(made[0]) as unknown as ConversationId;
				// A sub-chat belongs to no call, waited for or not: work a call owns keeps the call, and so the whole answer, from
				// ending until it is done, and a wait a message from the person ends must leave it running (heed.ts). A call that
				// waits stops it when the call is stopped (`waitForChat`). It starts as a copy of this conversation's agent, as
				// one owned by the call did.
				const created = await tx.createConversation({ ownership: { kind: "ownerless" } });
				Object.assign(await tx.doc(AgentDoc, created.id), JSON.parse(JSON.stringify(await tx.doc(AgentDoc, api.conversationId))));
				await configure(tx, created.id, change);
				const now = Date.now();
				library.conversations[String(created.id)] = {
					title: named,
					createdAt: now,
					updatedAt: now,
					access: target.access,
					agentId: target.id,
					parent,
					madeBy: String(api.taskId),
					// Its own agent's Allow everything, never its parent's (#294).
					...(target.allowEverything === true ? { allowEverything: true as const } : {}),
					// In its parent's project, if the parent is in one (projects.ts).
					...projectFrom(library.conversations[String(parent)]),
				};
				return created.id;
			}, context);
			if (args.worktree !== undefined) {
				const failed = await giveWorktree(api, child as unknown as number, args.worktree, args.from, context);
				if (failed !== undefined) return { output: text(`No worktree could be made for the sub-chat, so nothing was handed over: ${failed}`), isError: true };
			}
			// Lets the app open the subagent's transcript from the call's card.
			await api.details({ conversationId: child as unknown as number, agentId: target.id, agentName: target.name }, context);
			if (!waits) {
				// Belonging to no call, it is reached as the person's messages reach a conversation.
				const sent = await host.sendToChat(child as unknown as number, args.task, `delegate:${String(api.taskId)}`);
				if (sent === undefined) return { output: text("The sub-chat could not be reached, so nothing was handed over."), isError: true };
				return await handOff(child as unknown as number, sent, target.name, named, target.id);
			}
			const handle = (await api.conversation(child, context))!;
			const submission = await handle.submit({ type: "input", content: args.task, requestId: `delegate:${String(api.taskId)}` }, context);
			await api.commit(async (tx) => {
				const meta = (await tx.doc(Library)).conversations[String(child)];
				if (meta !== undefined) meta.subChatTask = Math.max(meta.subChatTask ?? 0, submission.id as number);
			}, context);
			return answer(child as unknown as number, target, named, submission.id as number);
		},
	});

	/**
	 * Give a sub-chat just made by `delegate` its own worktree, through the code New Worktree… uses. Returns why it could not,
	 * having put the empty sub-chat away for good, or undefined once it has one (a call run again after a crash finds it).
	 */
	async function giveWorktree(api: ToolExecutionApi, child: number, branch: string, from: string | undefined, context: Context): Promise<string | undefined> {
		const meta = (await api.snapshot(Library, context))?.conversations[String(child)];
		if (meta?.deleted === true) return "it failed before, and the sub-chat was removed.";
		if ((await worktreeOf(api, child, context)) !== undefined) return undefined;
		try {
			await makeWorktree(child, branch.trim(), from);
			return undefined;
		} catch (error) {
			// The sub-chat never had a message: nothing in it is worth keeping, so it is not left in the sidebar.
			await api.commit(async (tx) => {
				const stored = (await tx.doc(Library)).conversations[String(child)];
				if (stored !== undefined) stored.deleted = true;
			}, context);
			// The reasons are worded for the person making a worktree for the conversation in front of them.
			const reason = (error instanceof Error ? error.message : String(error)).replace(/^This conversation/, "The sub-chat");
			return /[.!?]$/.test(reason) ? reason : `${reason}.`;
		}
	}

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
			const result = await readReference(filesOf(api.conversationId), args.path, args.offset, args.limit);
			return { output: text(result.text), ...(result.isError ? { isError: true } : {}) };
		},
	});

	/** The computer-use settings of the agent a conversation belongs to. */
	const computerOf = (conversationId: ConversationId) => host.agent(host.meta(conversationId)?.agentId)?.computer;
	/** Whether a conversation may use any app, not only its agent's list: it allows everything (#294), as of its latest message. */
	const anyApp = (conversationId: ConversationId) => host.meta(conversationId)?.allowEverything === true;
	const agentNameOf = (conversationId: ConversationId) => host.agent(host.meta(conversationId)?.agentId)?.name ?? "An agent";
	/** Told to the app with every request of an agent that may use test copies, which it checks for itself before acting. */
	const testCopiesOf = (conversationId: ConversationId) => (computerOf(conversationId)?.testCopies === true ? { testCopies: true } : {});

	type ComputerArgs = { action: string; app?: string; element?: number; x?: number; y?: number; text?: string; dy?: number; count?: number; path?: string };

	/** Why a computer call cannot run, or undefined when it can. Checked before asking the person and again before acting. */
	const refusal = (conversationId: ConversationId, args: ComputerArgs): string | undefined => {
		const settings = computerOf(conversationId);
		if (settings?.enabled !== true) return "Computer use is turned off for this agent.";
		const action = args.action.trim();
		if (!(ACTIONS as readonly string[]).includes(action)) return `Unknown action "${args.action}". Use one of: ${ACTIONS.join(", ")}.`;
		if (action === "list_apps") return undefined;
		if (args.app === undefined || args.app.trim() === "") return `${action} needs \`app\`, a bundle ID from list_apps.`;
		const any = anyApp(conversationId);
		if (!mayUse(settings, args.app, any)) {
			const listed = settings.apps.join(", ") || (settings.testCopies === true ? "none listed" : "none; the person adds them in this agent's settings");
			return `You may not use ${args.app}. Apps you may use: ${listed}${settings.testCopies === true ? ", and test copies of pi² (dev.pi2.app.test…)" : ""}.`;
		}
		if (isNever(args.app)) return `${args.app} cannot be used by an agent.`;
		if (!LOOKING.has(action) && action !== "open_app" && lookOnly(settings, args.app, any)) return `${args.app} can only be looked at, not controlled.`;
		if ((action === "click" || action === "context_menu") && args.element === undefined && (args.x === undefined || args.y === undefined)) {
			return `${action} needs \`element\`, or both \`x\` and \`y\`.`;
		}
		if ((action === "type" || action === "key") && (args.text === undefined || args.text === "")) return `${action} needs \`text\`.`;
		if (action === "scroll" && (args.dy === undefined || args.dy === 0)) return "scroll needs `dy`: pages to scroll, positive for down.";
		if (action === "menu" && (args.path === undefined || args.path.trim() === "")) return 'menu needs `path`, such as "File > Save".';
		return undefined;
	};

	/**
	 * The call with `app` spelled as in the agent's settings. macOS treats bundle ids without regard to case, so one app
	 * is one app however the agent spells it: one approval for the rest of the conversation, and one name sent to the app.
	 */
	const asGiven = (conversationId: ConversationId, args: ComputerArgs): ComputerArgs => {
		const app = typeof args.app !== "string" ? undefined : givenApp(computerOf(conversationId)?.apps ?? [], args.app);
		return app === undefined ? args : { ...args, app };
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
			"- context_menu: open the context menu of `element`, or of what is at `x`,`y`, as a right-click does. Its items are then listed first among the controls: click one to choose it, or key escape to close the menu.\n" +
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
		execute: async (call, api, context) => {
			const args = asGiven(api.conversationId, call);
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
					...(anyApp(api.conversationId) ? { anyApp: true } : {}),
					...testCopiesOf(api.conversationId),
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
			api,
			context,
		);
		// Without a site to name there is nothing for "always" to cover, so it allows this once.
		if (decision === "always" && key !== undefined) await host.allowAlways(api.conversationId, key);
		return decision === "deny" ? { block: DECLINED } : undefined;
	};

	/**
	 * A worktree for a new sub-chat makes a branch in the repository and runs the other agent's set-up command. That is
	 * done without asking only where the person has already let it happen: the calling conversation has full access (it
	 * could run `git worktree add` itself), or the agent handed the work has its conversations given worktrees anyway.
	 * Otherwise the person is asked, whatever the file access, since an agent without full access could not do it at all.
	 */
	const approveWorktree = async (call: ToolHookCall, api: HookApi, context: Context): Promise<{ block: string } | undefined> => {
		const args = call.arguments as { agent?: unknown; worktree?: unknown; from?: unknown; chat?: unknown };
		// A call that cannot run anyway is not worth a question; the tool explains why itself.
		if (typeof args.worktree !== "string" || args.worktree.trim() === "" || args.chat !== undefined || typeof args.agent !== "string") return undefined;
		const meta = host.meta(api.conversationId);
		if (meta?.access === "full" || meta?.autoApprove?.includes("delegate")) return undefined;
		const name = args.agent.trim().toLowerCase();
		const target = delegatesOf(host, api.conversationId).find((a) => a.name.toLowerCase() === name || a.id === args.agent);
		if (target === undefined || target.worktree === true) return undefined;
		const from = typeof args.from === "string" && args.from.trim() !== "" ? args.from.trim() : undefined;
		const decision = await host.inbox.ask(
			{
				id: String(api.taskId),
				kind: "approval",
				conversationId: api.conversationId as unknown as number,
				callId: call.id,
				tool: call.name,
				arguments: call.arguments,
				question: `Make a git worktree on the branch ${args.worktree.trim()}, ${from === undefined ? "from the commit this conversation's folder is on" : `from ${from}`}, for a new sub-chat with ${target.name}.`,
				createdAt: Date.now(),
			},
			api,
			context,
		);
		if (decision === "always") await host.allowAlways(api.conversationId, "delegate");
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
		const judged = await judgeShell(host, api.conversationId, (call.arguments as { command?: unknown }).command, api, context);
		if (judged === undefined) return { allowed: false };
		const { command, folder, made, verdict } = judged;
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
		tools: [askUser, delegate, subChatsTool(host), readReferenceTool, computerTool, browserTool, ...host.features.flatMap((feature) => feature.tools ?? [])],
		wraps: host.features.flatMap((feature) => feature.wraps ?? []),
		sections: [
			section("computer_use", (input) => {
				if (!input.agent.tools.some((tool) => tool.name === "computer")) return undefined;
				return describeComputer(computerOf(input.conversationId), anyApp(input.conversationId));
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
					"Each delegation opens a sub-chat under this conversation. Start a new one for a new piece of work, with a short `title` so the person can tell it from the others; continue an existing one (pass its number as `chat`) when the work builds on what that agent already did. " +
						"sub_chats lists them with how each stands, and archives the ones that are finished, so the person's sidebar shows only work still going.",
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
					await awaitWithContext(host.ready, context);
					if (call.name === "browser") return approveBrowser(call, api, context);
					if (call.name === "delegate") return approveWorktree(call, api, context);
					const meta = host.meta(api.conversationId);
					const isComputer = call.name === "computer";
					const args = isComputer ? asGiven(api.conversationId, call.arguments as ComputerArgs) : (call.arguments as ComputerArgs);
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
							{
								action: "describe",
								of: args.action.trim(),
								conversationId: api.conversationId as unknown as number,
								agentName: agentNameOf(api.conversationId),
								...(anyApp(api.conversationId) ? { anyApp: true } : {}),
								...testCopiesOf(api.conversationId),
								...requestOf(args),
							},
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
							// A command that will be left running: the approval says so, and is otherwise a command's.
							...(call.name === "bash" && (call.arguments as { background?: unknown }).background === true ? { background: true as const } : {}),
							createdAt: Date.now(),
						},
						api,
						context,
					);
					if (decision === "always") await host.allowAlways(api.conversationId, key);
					// The rule is the engine's own proposal; the app only says "rule". Either way the person allowed this command.
					if (decision === "rule" && proposal !== undefined && meta?.agentId !== undefined) await host.addRule(meta.agentId, proposal.folder, proposal.words);
					return decision === "deny" ? { block: DECLINED } : undefined;
				},
				afterTool: async (_call, result, api, context) => {
					const rules = allowedByRule.get(String(api.taskId));
					allowedByRule.delete(String(api.taskId));
					// A call blocked by a later hook never ran.
					if (result.diagnostics?.some((diagnostic) => diagnostic.code === "blocked")) return undefined;
					const byEverything = (await api.memo(ALLOWED_BY_EVERYTHING, context)) === true;
					if (!byEverything && rules === undefined) return undefined;
					const details = result.details !== null && typeof result.details === "object" && !Array.isArray(result.details) ? { ...result.details } : {};
					if (byEverything) details.allowedByEverything = true;
					else if (rules !== undefined) details.allowedBy = rules;
					return { ...result, details };
				},
			}),
		],
	});
}
