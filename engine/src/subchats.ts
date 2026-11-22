// An agent's own sub-chats: seeing how each stands, archiving the finished ones (issue #150; docs/archive.md), and
// stopping a run that has been overtaken (#789).
//
// `delegate` leaves a sub-chat behind for every task. An agent that hands out a lot of work can list them and put the
// finished ones away, within bounds: only sub-chats of its own conversation, never one that is working or waiting on
// the person, and archived, never deleted, so the person can read and restore it from the Archive. Archiving stops the
// commands a sub-chat left running in the background, and leaves a worktree of its own where it is, as archiving by
// hand does. The calling conversation gets a line saying what was put away.
//
// Stopping is the person's Stop on that sub-chat, through the same two calls as the engine's `abort` request (main.ts):
// pi durable's abort of the conversation, then each feature's `stopped`. So its run ends as "aborted", and the agent
// that handed it the work gets the report a run the person stopped gives, once, by its usual way. Never a sub-chat that
// waits on the person's approval or question, which Stop would take away unanswered.

import { realpathSync } from "node:fs";
import { basename, sep } from "node:path";
import type { Context } from "@earendil-works/chord/context";
import { AgentDoc, type ConversationId, defineTool, type ToolExecutionApi, type ToolExecutionResult } from "@earendil-works/pi-durable";
import { arr, bool, int, obj, opt, str } from "@earendil-works/pi-schema";
import { isArchived, isDeleted } from "./archive.ts";
import { limitsReport, resetWords } from "./limits.ts";
import type { Wait } from "./limitwait.ts";
import { elapsed, runningCommandsOf, stopCommandsOf } from "./background.ts";
import type { Host } from "./extensions.ts";
import { Library, type Meta } from "./state.ts";
import { nextSubChats, watchedSubChats } from "./wakes.ts";
import { unlessMessaged } from "./heed.ts";
import { earlierOf } from "./orchestrator.ts";
import { latestReport, orchestratorOf } from "./reports.ts";
import { allWorktrees, type BranchInfo, changesOn, containedIn, inspect, removeWorktree, squashTarget, whyKeepWorktree, type Worktree, worktreeOf } from "./worktrees.ts";

/** A line in the calling conversation's transcript: which sub-chats were archived, or restored to be continued. */
export const SUBCHATS_ENTRY = "pi2.subchats";

type Named = { id: number; title: string };
/**
 * `removed`: branches of worktrees removed with nothing uncommitted or unmerged, each kept; `deleted`: those whose merged
 * branch was deleted with them; `squashed`: those removed by name whose changes were on the default branch under other
 * commits, each branch kept (#778).
 */
type MarkerData = {
	action: "archived" | "restored" | "stopped" | "stoppedBy";
	chats: Named[];
	stopped?: number;
	removed?: string[];
	deleted?: string[];
	squashed?: string[];
	/** For `stoppedBy`, the line in a stopped sub-chat: the name of the agent that stopped it; `chats` is its conversation. */
	by?: string;
};

/** What the transcript shows for a `SUBCHATS_ENTRY`. */
export function subChatsMarker(data: unknown): string {
	const entry = (data !== null && typeof data === "object" ? data : {}) as Partial<MarkerData>;
	const chats = Array.isArray(entry.chats) ? entry.chats.filter((chat) => typeof chat?.id === "number") : [];
	const named = chats.map((chat) => `${typeof chat.title === "string" && chat.title.trim() !== "" ? `“${chat.title.trim()}” ` : ""}(${chat.id})`).join(", ");
	if (entry.action === "restored") return `The agent restored sub-chat ${named} from the Archive to continue it`;
	const one = chats.length === 1;
	if (entry.action === "stopped") return `The agent stopped the run of ${one ? "sub-chat" : `${chats.length} sub-chats:`} ${named}`;
	if (entry.action === "stoppedBy") {
		const by = typeof entry.by === "string" && entry.by.trim() !== "" ? entry.by.trim() : "The agent that handed it this work";
		return `${by} stopped this run${named === "" ? "" : ` from conversation ${named}`}`;
	}
	const stopped = typeof entry.stopped === "number" && entry.stopped > 0 ? ` ${entry.stopped} background command${entry.stopped === 1 ? "" : "s"} ${one ? "it" : "they"} left running ${entry.stopped === 1 ? "was" : "were"} stopped.` : "";
	const list = (value: unknown) => (Array.isArray(value) ? value.filter((branch): branch is string => typeof branch === "string") : []);
	const branches = list(entry.removed);
	const deleted = list(entry.deleted);
	const squashed = list(entry.squashed);
	const worktrees = (count: number) => (count === 1 ? "a worktree" : `${count} worktrees`);
	const removed =
		(branches.length === 0 ? "" : ` The agent removed ${worktrees(branches.length)} with nothing uncommitted or unmerged; ${branches.length === 1 ? "its branch" : "their branches"} ${branches.join(", ")} ${branches.length === 1 ? "is" : "are"} kept.`) +
		(deleted.length === 0 ? "" : ` The agent removed ${worktrees(deleted.length)} with nothing uncommitted or unmerged, and deleted ${deleted.length === 1 ? "its merged branch" : "their merged branches"} ${deleted.join(", ")}.`) +
		(squashed.length === 0 ? "" : ` The agent removed ${worktrees(squashed.length)} whose changes are on the default branch under other commits; ${squashed.length === 1 ? "its branch" : "their branches"} ${squashed.join(", ")} ${squashed.length === 1 ? "is" : "are"} kept.`);
	if (chats.length === 0) return removed.trim();
	return `The agent archived ${one ? "sub-chat" : `${chats.length} sub-chats:`} ${named}. ${one ? "It is" : "They are"} in the Archive, where you can read or restore ${one ? "it" : "them"}.${stopped}${removed}`;
}

/** Write a `SUBCHATS_ENTRY` into a conversation. Display only: the model reads the tool's answer instead. */
export async function noteSubChats(api: Pick<ToolExecutionApi, "conversation">, conversationId: ConversationId, data: MarkerData, requestId: string, context: Context): Promise<void> {
	const conv = await api.conversation(conversationId, context);
	// The request id makes a call run again after a crash write the line once.
	await conv?.submit({ type: "write", entry: { kind: SUBCHATS_ENTRY, data }, requestId }, context);
}

/** The sub-chats under `root`, and theirs, oldest first. Deleted ones are gone for good and are left out. */
export function subChatsOf(all: Record<string, Meta>, root: number): number[] {
	const found: number[] = [];
	const queue = [root];
	while (queue.length > 0) {
		const parent = queue.shift()!;
		for (const [key, meta] of Object.entries(all)) {
			const id = Number(key);
			if (meta.parent !== parent || meta.version === true || isDeleted(meta) || found.includes(id)) continue;
			found.push(id);
			queue.push(id);
		}
	}
	return found.sort((a, b) => (all[String(a)]?.createdAt ?? 0) - (all[String(b)]?.createdAt ?? 0) || a - b);
}

const plural = (count: number, word: string) => `${count} ${word}${count === 1 ? "" : "s"}`;

function realish(path: string): string {
	try {
		return realpathSync(path);
	} catch {
		return path;
	}
}
const within = (folder: string, root: string) => (realish(folder) + sep).startsWith(realish(root) + sep);

/** How a branch stands, in words: "2 uncommitted changes, 3 commits not on main". */
export function branchWords(info: BranchInfo): string {
	if (info.state === "missing") return "its folder is gone";
	if (info.state === "unavailable") return "its checkout status is unavailable";
	const parts: string[] = [];
	if (info.operation !== null) parts.push(`a ${info.operation} stopped half way`);
	const changes = info.changes + info.conflicts;
	parts.push(changes > 0 ? plural(changes, "uncommitted change") : "nothing uncommitted");
	if (info.conflicts > 0) parts.push(`${plural(info.conflicts, "file")} with conflicts`);
	// Merged is on what it was made from, or on the default branch (#778).
	const contained = containedIn(info);
	if (info.state === "merged") parts.push(`merged into ${contained ?? info.base}`);
	else if (info.branch === null && contained !== null) parts.push(`detached at ${info.head}, a commit on ${contained}`);
	else if (info.unmerged !== null && info.base !== null) {
		if (info.unmerged === 0) parts.push(`no commits that are not on ${info.base}`);
		else if (contained !== null) parts.push(`every commit on ${contained}`);
		else parts.push(`${plural(info.unmerged, "commit")} not on ${info.base}${info.defaultBranch !== null && info.unmergedDefault !== null ? `, ${info.unmergedDefault} not on ${info.defaultBranch}` : ""}`);
	}
	if (info.upstream !== null && info.ahead > 0) parts.push(`${plural(info.ahead, "commit")} not pushed to ${info.upstream}`);
	return parts.join(", ");
}

/**
 * Whether a sub-chat or one of its own sub-chats is busy, waiting on the person or waiting for a provider's limit, and if
 * so, in words.
 */
export function subChatActivity(host: Host, ids: number[]): string | undefined {
	const waiting = host.inbox.list().filter((item) => ids.includes(item.conversationId));
	if (waiting.length > 0) return `waiting on the person (${waiting[0]!.kind === "question" ? "a question" : "an approval"})`;
	if (!ids.some((id) => host.working(id))) return undefined;
	const feature = host.features.find((candidate) => candidate.limitWaitOf !== undefined);
	for (const id of ids) {
		const wait = feature?.limitWaitOf?.(id);
		if (wait !== undefined) return limitWaitWords(wait, Date.now());
	}
	return "working";
}

/** "waiting for Anthropic's rate limit until 18:20 (in 1 h 45 min), the time Anthropic named; it carries on by itself then". */
export function limitWaitWords(wait: Pick<Wait, "kind" | "until" | "told" | "providerName">, now: number): string {
	const name = wait.providerName;
	if (wait.kind === "overloaded") return `waiting for ${name}, which is overloaded; it asks again ${resetWords(wait.until, now)} and carries on by itself`;
	if (wait.told) return `waiting for ${name}'s rate limit until ${resetWords(wait.until, now).replace(/^(at|on) /, "")}, the time ${name} named; it carries on by itself then`;
	return `waiting for ${name}'s rate limit; ${name} named no time, so it asks again ${resetWords(wait.until, now)} and carries on by itself`;
}

type Where = { cwd: string | null; own: Worktree | undefined; info: BranchInfo | undefined; shared: Worktree | undefined };

/** Where a sub-chat works, and how the branch there stands. */
async function whereOf(api: ToolExecutionApi, id: number, parentWorktree: Worktree | undefined, context: Context): Promise<Where> {
	const cwd = (await api.snapshot(AgentDoc, id as unknown as ConversationId, context))?.cwd ?? null;
	const own = await worktreeOf(api, id, context);
	const shared = own === undefined && cwd !== null && parentWorktree !== undefined && within(cwd, parentWorktree.path) ? parentWorktree : undefined;
	const info = cwd === null && own === undefined ? undefined : await inspect(cwd ?? own!.path, own).catch(() => undefined);
	return { cwd, own, info, shared };
}

function whereWords(where: Where): string {
	if (where.own !== undefined) {
		const standing = where.info === undefined ? "" : `: ${branchWords(where.info)}`;
		return `works in a worktree of its own at ${where.own.path}, on the branch ${where.info?.branch ?? where.own.branch}${where.own.base ? ` (made from ${where.own.base})` : ""}${standing}`;
	}
	if (where.cwd === null) return "works in pi²'s scratch folder";
	if (where.shared !== undefined) return `works in this conversation's worktree, ${where.cwd}, on the branch ${where.info?.branch ?? where.shared.branch}`;
	const branch = where.info === undefined ? "" : where.info.branch === null ? ", on a detached HEAD" : `, on the branch ${where.info.branch}`;
	return `works in ${where.cwd}${branch}`;
}

/**
 * For a worktree kept only for commits that are not merged: the default branch its changes are on under other commits,
 * when a rebase or a squash merged it (#778); else null. Asked only here, where removal is judged, not at every look.
 */
export async function squashedOnto(info: BranchInfo | undefined): Promise<string | null> {
	if (info === undefined || info.branch === null || info.head === null || info.state === "missing" || info.state === "unavailable") return null;
	if (info.operation !== null || info.changes + info.conflicts > 0 || info.unmerged === null || containedIn(info) !== null) return null;
	const onto = squashTarget(info);
	return onto !== null && (await changesOn(info.root, onto, "HEAD")) ? onto : null;
}

/** Why a worktree merged by a rebase or a squash is not removed unasked, and how to ask. */
const squashWords = (onto: string) =>
	`its changes are on ${onto} under other commits (merged by a rebase or a squash), but its own commits are not, so it is removed only when named: archive it again with remove_worktree: true and its number in squash_merged. Its branch is kept either way`;

/**
 * What an archived sub-chat's worktree of its own is now, for its line in the archived list (#778): its folder's name,
 * its branch and how that stands, and whether removing it would lose anything, and if so what.
 */
async function leftWorktreeWords(own: Worktree, info: BranchInfo | undefined): Promise<string> {
	const on = info?.branch === null ? `detached at ${info.head} (made on the branch ${own.branch})` : `on the branch ${info?.branch ?? own.branch}`;
	const head = `Its worktree is still there: ${basename(own.path)}, ${on}${info === undefined ? "" : ` (${branchWords(info)})`}.`;
	const why = whyKeepWorktree(info);
	if (why === undefined) return `${head} Nothing would be lost by removing it: archive it again with remove_worktree: true, and delete_branch: true to delete its merged branch too.`;
	const onto = await squashedOnto(info);
	if (onto !== null) return `${head} It is kept: ${squashWords(onto)}.`;
	return `${head} It is kept because ${why}.`;
}

/**
 * The end of `sub_chats`' list: how much of each signed-in subscription's windows is used and when each resets, and
 * which subscription this conversation and each agent it can hand work to runs on; and the providers whose limit a
 * refusal said is used up until a time it named (#556). Nothing when no feature knows.
 */
async function limitsOf(host: Host, api: ToolExecutionApi, context: Context): Promise<string[]> {
	const views = host.features.find((feature) => feature.planLimits !== undefined)?.planLimits?.();
	if (views === undefined) return [];
	const users = new Map<string, string[]>();
	const add = (provider: string | undefined, who: string) => {
		if (provider === undefined) return;
		users.set(provider, [...(users.get(provider) ?? []), who]);
	};
	add((await api.snapshot(AgentDoc, api.conversationId, context))?.model?.provider, "this conversation");
	for (const agent of host.delegatesOf(api.conversationId)) {
		// What a new sub-chat with that agent would run on: its own model, or the default one.
		add((await host.agentChange(agent, { subChat: true }).catch(() => undefined))?.model?.provider, agent.name);
	}
	const remembered = host.features.find((feature) => feature.rememberedLimits !== undefined)?.rememberedLimits?.() ?? [];
	return ["", ...limitsReport(views, users, Date.now(), remembered)];
}

/** How many archived sub-chats `list` with `archived: true` gives at a time (#636). */
export const ARCHIVED_PAGE = 40;

const when = (at: number) => `${new Date(at).toISOString().slice(0, 16).replace("T", " ")}Z`;

/**
 * A page of the archived sub-chats `ids`, newest archived first: those after `cursor`, the last one the page before gave,
 * so that a page is the same however many are archived meanwhile. `shown`: how many came before it. Undefined when the
 * cursor names none of them now (restored, or never one).
 */
export function archivedPage(ids: number[], archivedAt: (id: number) => number, cursor: number | undefined, size = ARCHIVED_PAGE): { page: number[]; shown: number; left: number; total: number } | undefined {
	const later = (a: number, b: number) => archivedAt(b) - archivedAt(a) || b - a;
	const newest = [...ids].sort(later);
	if (cursor !== undefined && !ids.includes(cursor)) return undefined;
	const rest = cursor === undefined ? newest : newest.filter((id) => later(cursor, id) < 0);
	const page = rest.slice(0, size);
	return { page, shown: newest.length - rest.length, left: rest.length - page.length, total: newest.length };
}

/**
 * `sub_chats` with `stop` (#789): the person's Stop on each of `asked` that is the caller's own sub-chat and working, as
 * the engine's `abort` request does it (main.ts), with a line in the sub-chat naming who stopped it and one in the caller.
 * The report of a run stopped so is the report of one the person stopped, given by its usual way (reports.ts, wakes.ts).
 */
async function stopSubChats(host: Host, api: ToolExecutionApi, caller: number, mine: number[], asked: number[], context: Context): Promise<ToolExecutionResult> {
	const chats = [...new Set(asked)];
	if (chats.length === 0) return { output: text("stop needs `chats`: the numbers of the sub-chats whose runs to stop, from list."), isError: true };
	const all = host.conversations();
	const by = host.agentOf(api.conversationId)?.name;
	const lines: string[] = [];
	const stopped: Named[] = [];
	const idle: number[] = [];
	const refused: number[] = [];
	for (const id of chats) {
		const meta = all[String(id)];
		if (id === caller) {
			lines.push(`- ${id}: that is this conversation, not one of its sub-chats, so nothing was stopped.`);
			refused.push(id);
			continue;
		}
		if (meta === undefined || !mine.includes(id)) {
			lines.push(`- ${id}: there is no sub-chat ${id} in this conversation, so nothing was stopped.`);
			refused.push(id);
			continue;
		}
		// Stop takes away unanswered an approval or a question its run waits on, and one of a sub-chat of its own that it
		// waits for, since stopping a call that waits for a sub-chat stops that too (heed.ts). Its own sub-chats are all
		// counted, waited for or not: refusing one Stop would not harm is the safe side.
		const below = subChatsOf(all, id);
		const waiting = host.inbox.list().find((item) => item.conversationId === id || below.includes(item.conversationId));
		if (waiting !== undefined) {
			const whose = waiting.conversationId === id ? "it is" : `its sub-chat ${waiting.conversationId} is`;
			lines.push(`- ${id}: not stopped, because ${whose} waiting on the person (${waiting.kind === "question" ? "a question" : "an approval"}), which stopping could take away unanswered. Stop it once they have answered.`);
			refused.push(id);
			continue;
		}
		if (!host.working(id)) {
			const busy = below.filter((each) => host.working(each));
			const one = busy.length === 1;
			const note = busy.length === 0 ? "" : ` Its own sub-chat${one ? "" : "s"} ${busy.join(", ")} ${one ? "is" : "are"} working: name ${one ? "it" : "them"} to stop ${one ? "it" : "them"}.`;
			lines.push(`- ${id}: was not working, so there was nothing to stop.${note}`);
			idle.push(id);
			continue;
		}
		const conv = await api.conversation(id as unknown as ConversationId, context);
		if (conv === undefined) {
			lines.push(`- ${id}: there is no sub-chat ${id} in this conversation, so nothing was stopped.`);
			refused.push(id);
			continue;
		}
		await conv.abort(context);
		for (const feature of host.features) feature.stopped?.(id);
		// Where the person sees who stopped it, after the run it ended. The request id writes it once after a crash.
		const from: Named = { id: caller, title: all[String(caller)]?.title ?? "" };
		await noteSubChats(api, id as unknown as ConversationId, { action: "stoppedBy", chats: [from], ...(by === undefined ? {} : { by }) }, `sub_chats:${String(api.taskId)}:${id}`, context);
		stopped.push({ id, title: meta.title });
		lines.push(`- ${id}: stopped (“${meta.title}”). If its answer was to come to you, its report comes instead, saying its run was stopped. To continue it, call delegate again with chat: ${id}.`);
	}
	if (stopped.length > 0) await noteSubChats(api, api.conversationId, { action: "stopped", chats: stopped }, `sub_chats:${String(api.taskId)}`, context);
	return {
		output: text(lines.join("\n")),
		details: { action: "stop", stopped: stopped.map((chat) => chat.id), idle, refused },
		...(stopped.length === 0 && idle.length === 0 ? { isError: true } : {}),
	};
}

export const SUB_CHATS_DESCRIPTION =
	"See the sub-chats this conversation opened with delegate, stop one whose run was overtaken, and archive the ones whose work is finished. Actions:\n" +
	"- list: each sub-chat that is not archived: its number, agent and title; whether it is working, waiting for a provider's limit (and until when), waiting on the person or idle; the folder and branch it works in (for a worktree of its own, whether anything is uncommitted and whether its branch is merged); and the commands it left running in the background. Archived ones are only counted: `archived: true` lists them, newest first, a page at a time (pass back `cursor` to continue; `usage: true` adds what each used; `with_worktree: true` lists only those that still have a worktree of their own), and `chats` looks up those numbered, archived or not. An archived one that still has a worktree of its own says so: its folder, its branch, and whether removing it would lose anything, and if so what. " +
	"Then how much of each signed-in subscription's allowance is used and when each window resets, and which subscription you and each of your agents run on: list before starting more sub-chats when a window may be nearly used up.\n" +
	"- archive: put away the sub-chats numbered in `chats`. Use it once you have what you needed from a sub-chat and will not continue it, or when the person asks you to tidy up. " +
	"An archived sub-chat leaves the sidebar for the Archive, where the person can read and restore it; nothing is deleted. Commands it left running in the background are stopped, and the answer says which. " +
	"A worktree of its own is left as it is, unless you pass `remove_worktree: true` and removing it loses nothing: nothing uncommitted, and every commit of its HEAD (on a branch or detached) on what it was made from or on the repository's default branch as last fetched (fetch first if it was merged elsewhere). Its branch is kept, unless you also pass `delete_branch: true`, which deletes the local branch too when every commit on it is on one of those and no other worktree has it checked out, as `git branch -d` would; never a remote branch. " +
	"A branch merged by a rebase or a squash (its changes are on the default branch under other commits) is reported as such and kept; its worktree is removed only when you also name the sub-chat in `squash_merged`, and its branch is kept even then. " +
	"A sub-chat that is working or waiting on the person is not archived. Continuing an archived sub-chat with delegate and its number restores it.\n" +
	"- stop: stop the run of each sub-chat numbered in `chats`, as the person's Stop on it would: use it when its task was overtaken or it is plainly going the wrong way, rather than letting it spend on. The answer says of each whether it was stopped or was not working. " +
	"One waiting on the person's approval or question is not stopped. Commands it left running in the background go on, as after the person's Stop (archiving it stops them); if its answer was to come to you, its report comes instead, saying it was stopped. Continue it with delegate and its number.\n" +
	"- wait: wait for the next sub-chat you started with `wait: false` (or one of `chats`) to finish, and get its answer here instead of being woken for it; those already finished come at once.";

/** The `sub_chats` tool. Offered with `delegate`, to conversations that can hand work on. */
export function subChatsTool(host: Host) {
	return defineTool({
		name: "sub_chats",
		description: SUB_CHATS_DESCRIPTION,
		parameters: obj({
			action: str({ description: "list, archive, stop or wait" }),
			chats: opt(arr(int(), { description: "For list: look up these sub-chats, archived or not. For archive: the numbers of the sub-chats to archive. For stop: the sub-chats whose runs to stop. For wait: the sub-chats to wait for, by default all" })),
			archived: opt(bool({ description: "For list: list the archived sub-chats instead, newest first, a page at a time" })),
			usage: opt(bool({ description: "For list with archived or chats: add what each archived one used" })),
			cursor: opt(int({ description: "For list with archived: the cursor the previous page ended with, to continue" })),
			with_worktree: opt(bool({ description: "For list with archived: only the archived sub-chats that still have a worktree of their own" })),
			remove_worktree: opt(bool({ description: "For archive: also remove each one's worktree of its own, if nothing would be lost (nothing uncommitted, and every commit on what it was made from or on the default branch). Its branch is kept unless delete_branch is true." })),
			delete_branch: opt(bool({ description: "For archive: remove each one's worktree as remove_worktree does, and delete its local branch too when every commit on it is merged there and no other worktree has it checked out. Never a remote branch." })),
			squash_merged: opt(arr(int(), { description: "For archive with remove_worktree: sub-chats whose branch was reported as merged by a rebase or a squash (its changes on the default branch under other commits), whose worktrees you have decided to remove. Checked again; their branches are kept." })),
		}),
		// Listing changes nothing, archiving what is archived changes nothing, and stopping what is stopped changes nothing.
		replay: "safe",
		execute: async (args, api, context): Promise<ToolExecutionResult> => {
			const caller = api.conversationId as unknown as number;
			const all = host.conversations();
			// An orchestrator's are those of its earlier conversations too, still working or not archived (docs/projects.md, 5.8).
			const earlier = earlierOf(caller);
			const fromEarlier = earlier.flatMap((root) => subChatsOf(all, root).filter((id) => !isArchived(all[String(id)]) && !isArchived(all[String(all[String(id)]?.parent)])));
			const mine = [...subChatsOf(all, caller), ...fromEarlier];
			/** For an orchestrator: whether a sub-chat's last report was given to it (reports.ts). */
			const reported = (id: number) => {
				if (orchestratorOf(caller) === undefined) return "";
				const report = latestReport(id);
				if (report === undefined || report.ended === null) return "";
				return report.delivered === null ? " Its last report has not been read yet." : " Its last report was given to you.";
			};
			const parentWorktree = await worktreeOf(api, caller, context);
			const agentOf = (id: number) => host.agentOf(id as unknown as ConversationId)?.name ?? "an agent that was deleted";
			const action = args.action.trim().toLowerCase();

			if (action === "list") {
				// Those archived on their own; a sub-chat of an archived one goes with it.
				const archived = mine.filter((id) => isArchived(all[String(id)]));
				const goneWith = (id: number) => archived.includes(all[String(id)]?.parent ?? -1);
				const listed = mine.filter((id) => !archived.includes(id) && !goneWith(id));
				const under = (meta: Meta) => (meta.parent === caller ? "" : earlier.includes(meta.parent!) ? ` (from your earlier conversation ${meta.parent})` : ` (a sub-chat of ${meta.parent})`);
				/** A sub-chat that is not archived: how it stands, where it works, what it left running, and what it used. */
				const current = async (id: number): Promise<string[]> => {
					const meta = all[String(id)]!;
					const busy = subChatActivity(host, [id, ...subChatsOf(all, id)]);
					const state = busy === undefined ? "idle" : watchedSubChats(caller).includes(id) ? `${busy}, and its answer will come to you as a message` : busy;
					const where = whereWords(await whereOf(api, id, parentWorktree, context));
					const commands = runningCommandsOf(id);
					const running = commands.length === 0 ? "no background commands running" : `background commands running: ${commands.map((command) => `${command.id} \`${command.command}\``).join(", ")}`;
					const lines = [`- ${id}${under(meta)}: ${agentOf(id)}, “${meta.title}”. ${state[0]!.toUpperCase()}${state.slice(1)}; last used ${elapsed(Date.now() - meta.updatedAt)} ago. It ${where}. ${running[0]!.toUpperCase()}${running.slice(1)}.${reported(id)}`];
					const usage = await host.subChatUsage(id, context);
					if (usage !== "") lines.push(`  ${usage}`);
					return lines;
				};
				/**
				 * An archived sub-chat, or one put away with the sub-chat it belongs to: a line, without where it worked, and what it
				 * used only when asked. An orchestrator's archive only grows, so its list must not (#636).
				 */
				const worktrees = await allWorktrees(api, context);
				const putAway = async (id: number): Promise<string[]> => {
					const meta = all[String(id)]!;
					const how = archived.includes(id) ? `Archived ${when(meta.archivedAt!)}` : `Archived with sub-chat ${meta.parent}`;
					// A worktree of its own still on disk says so, and whether it can go (#778): asked of git only for these.
					const own = worktrees[String(id)];
					const worktree = own === undefined ? "" : ` ${await leftWorktreeWords(own, await inspect(own.path, own).catch(() => undefined))}`;
					const lines = [`- ${id}${under(meta)}: ${agentOf(id)}, “${meta.title}”. ${how}; last used ${elapsed(Date.now() - meta.updatedAt)} ago.${worktree}`];
					if (args.usage === true) {
						const usage = await host.subChatUsage(id, context);
						if (usage !== "") lines.push(`  ${usage}`);
					}
					return lines;
				};
				const restores = "Continuing an archived one with delegate and its number restores it.";

				if (args.chats !== undefined && args.chats.length > 0) {
					const lines: string[] = [];
					let found = 0;
					for (const id of [...new Set(args.chats)]) {
						if (all[String(id)] === undefined || !mine.includes(id)) {
							lines.push(`- ${id}: there is no sub-chat ${id} in this conversation.`);
							continue;
						}
						found += 1;
						lines.push(...(listed.includes(id) ? await current(id) : await putAway(id)));
					}
					if (args.chats.some((id) => !listed.includes(id) && mine.includes(id))) lines.push(restores);
					return { output: text(lines.join("\n")), details: { action, count: found }, ...(found === 0 ? { isError: true } : {}) };
				}

				/** Archived ones, and ones put away with them, whose worktree of their own is still on record. */
				const withWorktree = mine.filter((id) => (archived.includes(id) || goneWith(id)) && worktrees[String(id)] !== undefined);

				if (args.archived === true) {
					const narrowed = args.with_worktree === true;
					if (archived.length === 0) return { output: text("No sub-chat of this conversation is archived."), details: { action, count: 0, archived: 0 } };
					if (narrowed && withWorktree.length === 0) return { output: text("No archived sub-chat of this conversation still has a worktree of its own."), details: { action, count: 0, archived: 0 } };
					// One put away with its parent is listed by when its parent was archived. The cursor stays valid when the sub-chat it
					// names has had its worktree removed since the page before.
					const archivedAt = (id: number) => all[String(id)]!.archivedAt ?? all[String(all[String(id)]!.parent)]?.archivedAt ?? 0;
					const among = narrowed ? [...new Set([...withWorktree, ...(args.cursor !== undefined && (archived.includes(args.cursor) || goneWith(args.cursor)) ? [args.cursor] : [])])] : archived;
					const found = archivedPage(among, archivedAt, args.cursor);
					if (found === undefined) return { output: text("Invalid cursor: it names no archived sub-chat of this conversation now. Start again without it."), isError: true };
					const { page, shown, left } = found;
					const total = narrowed ? withWorktree.length : found.total;
					const which = narrowed ? "Archived sub-chats of this conversation that still have a worktree of their own" : "Archived sub-chats of this conversation";
					const lines = [page.length === 0 ? `No more archived sub-chats: all ${total} were listed.` : `${which}, newest first: ${shown + 1} to ${shown + page.length} of ${total}.`];
					for (const id of page) lines.push(...(await putAway(id)));
					if (left > 0) lines.push(`${left} more: list again with archived: true${narrowed ? ", with_worktree: true" : ""} and cursor: ${page.at(-1)}.`);
					if (page.length > 0) lines.push(restores);
					return { output: text(lines.join("\n")), details: { action, count: page.length, archived: total } };
				}

				const limits = await limitsOf(host, api, context);
				if (mine.length === 0) return { output: text(["This conversation has no sub-chats. delegate opens one.", ...limits].join("\n")), details: { action, count: 0 } };
				const lines: string[] = [];
				for (const id of listed) lines.push(...(await current(id)));
				const head = listed.length === 0 ? "Every sub-chat of this conversation is archived." : "Sub-chats of this conversation:";
				const stillThere = withWorktree.length === 0 ? "" : ` ${withWorktree.length === 1 ? "One of them still has a worktree of its own" : `${withWorktree.length} of them still have a worktree of their own`}: \`archived: true, with_worktree: true\` lists ${withWorktree.length === 1 ? "it" : "them"}.`;
				const tail = archived.length === 0 ? [] : [`${archived.length} archived; \`archived: true\` lists them, and \`chats\` looks one up by its number.${stillThere} ${restores}`];
				return { output: text([head, ...lines, ...tail, ...limits].join("\n")), details: { action, count: listed.length, archived: archived.length } };
			}

			if (action === "wait") {
				// A message from the person ends the wait (heed.ts): what has not come yet still wakes the agent when it does.
				const waited = await unlessMessaged(api, (waiting) => nextSubChats(caller, args.chats, waiting), context);
				if ("messaged" in waited) {
					return {
						output: text("The person sent you a message, so this stopped waiting; their message follows. The sub-chats are still working: their answers will come to you as messages when they are done, or wait for them here again."),
						details: { action, count: 0, waitEnded: true },
					};
				}
				const came = waited.value;
				if (came === "none") {
					return { output: text("No sub-chat of this conversation is working without being waited for, so there is nothing to wait for. delegate with `wait: false` starts one; list shows how each stands."), details: { action, count: 0 } };
				}
				return { output: text(came.map((each) => each.text).join("\n\n---\n\n")), details: { action, count: came.length } };
			}
			if (action === "stop") return await stopSubChats(host, api, caller, mine, args.chats ?? [], context);
			if (action !== "archive") return { output: text(`Unknown action "${args.action}". Use list, archive, stop or wait.`), isError: true };
			const asked = [...new Set(args.chats ?? [])];
			if (asked.length === 0) return { output: text("archive needs `chats`: the numbers of the sub-chats to archive, from list."), isError: true };
			const lines: string[] = [];
			const archived: Named[] = [];
			const refused: number[] = [];
			let stopped = 0;
			/** The branches of worktrees removed on this call: kept, deleted with them, and kept after a removal by name (#778). */
			const removed: string[] = [];
			const deleted: string[] = [];
			const squashed: string[] = [];
			const deleteBranch = args.delete_branch === true;
			const removing = args.remove_worktree === true || deleteBranch;
			const named = new Set(args.squash_merged ?? []);
			/** What becomes of an archived sub-chat's worktree of its own: removed when asked and nothing would be lost, else left. */
			const worktreeAfter = async (id: number, where: Where): Promise<string[]> => {
				if (where.own === undefined) return [];
				const own = where.own;
				// The branch it is on now: it may have gone on to a new one after its first was merged (#206).
				const branch = where.info?.branch ?? own.branch;
				const standing = where.info === undefined ? "" : ` (${branchWords(where.info)})`;
				if (removing) {
					try {
						const result = await removeWorktree(id, { force: false, deleteBranch, onlyIfMerged: true, squashed: named.has(id) });
						if (result.branch === null) {
							removed.push(own.branch);
							const on = where.info === undefined ? "" : ` (${branchWords(where.info)})`;
							return [`Removed its worktree at ${own.path}${on}; the branch ${own.branch} it was made on is kept.`];
						}
						if (result.branchDeleted) {
							deleted.push(result.branch);
							return [`Removed its worktree at ${own.path} and deleted its local branch ${result.branch}, whose commits are all merged.`];
						}
						if (result.squashed !== null) {
							squashed.push(result.branch);
							const byHand = deleteBranch ? `, since they are not on ${result.squashed}: delete it by hand (git branch -D ${result.branch}) if nothing on it is wanted` : "";
							return [`Removed its worktree at ${own.path}, whose changes are on ${result.squashed} under other commits; the branch ${result.branch} is kept with its own commits${byHand}.`];
						}
						removed.push(result.branch);
						return [`Removed its worktree at ${own.path}; the branch ${result.branch} is kept${result.keptBecause === null ? "" : ` because ${result.keptBecause}`}.`];
					} catch (error) {
						// Kept for commits that are not merged: say so when a rebase or a squash put its changes on the default branch.
						const onto = named.has(id) || whyKeepWorktree(where.info) === undefined ? null : await squashedOnto(where.info);
						if (onto !== null) return [`Its worktree was not removed: ${squashWords(onto)}.`];
						return [`Its worktree was not removed: ${error instanceof Error ? error.message : String(error)}. See Branches → Left Behind.`];
					}
				}
				const left = `Its worktree at ${own.path}, branch ${branch}${standing}, was left where it is`;
				if (whyKeepWorktree(where.info) !== undefined) {
					const onto = await squashedOnto(where.info);
					const squash = onto === null ? "" : squashWords(onto);
					return [`${left}; it is listed in Branches under Left Behind.${squash === "" ? "" : ` ${squash[0]!.toUpperCase()}${squash.slice(1)}.`}`];
				}
				return [`${left}. Nothing would be lost by removing it: pass remove_worktree: true to remove it, and delete_branch: true to delete its merged branch too.`];
			};
			for (const id of asked) {
				const meta = all[String(id)];
				if (meta === undefined || !mine.includes(id)) {
					lines.push(`- ${id}: there is no sub-chat ${id} in this conversation, so nothing was archived.`);
					refused.push(id);
					continue;
				}
				if (isArchived(meta)) {
					const own = await whereOf(api, id, parentWorktree, context);
					lines.push([`- ${id}: already archived.`, ...(await worktreeAfter(id, own))].join(" "));
					continue;
				}
				const busy = subChatActivity(host, [id, ...subChatsOf(all, id)]);
				if (busy !== undefined) {
					lines.push(`- ${id}: not archived, because it is ${busy}. Archive it once it has finished.`);
					refused.push(id);
					continue;
				}
				const where = await whereOf(api, id, parentWorktree, context);
				// Its commands, and those of its own sub-chats, are stopped first, so the answer can say they were.
				const commands = [id, ...subChatsOf(all, id)].flatMap((each) => runningCommandsOf(each));
				await Promise.all([id, ...subChatsOf(all, id)].map((each) => stopCommandsOf(each, "was stopped because the sub-chat was archived")));
				stopped += commands.length;
				await api.commit(async (tx) => {
					const stored = (await tx.doc(Library)).conversations[String(id)];
					if (stored !== undefined && stored.archivedAt === undefined) stored.archivedAt = Date.now();
				}, context);
				archived.push({ id, title: meta.title });
				const parts = [`- ${id}: archived (“${meta.title}”).`];
				if (commands.length > 0) parts.push(`Stopped the background command${commands.length === 1 ? "" : "s"} it left running: ${commands.map((command) => `${command.id} \`${command.command}\``).join(", ")}.`);
				parts.push(...(await worktreeAfter(id, where)));
				lines.push(parts.join(" "));
			}
			if (archived.length > 0 || removed.length + deleted.length + squashed.length > 0) {
				const data: MarkerData = { action: "archived", chats: archived, stopped, removed, ...(deleted.length > 0 ? { deleted } : {}), ...(squashed.length > 0 ? { squashed } : {}) };
				await noteSubChats(api, api.conversationId, data, `sub_chats:${String(api.taskId)}`, context);
			}
			if (archived.length > 0) {
				lines.push(archived.length === 1 ? "The person can read or restore it from the Archive." : "The person can read or restore them from the Archive.");
			}
			return {
				output: text(lines.join("\n")),
				details: { action, archived: archived.map((chat) => chat.id), refused, stopped },
				...(archived.length === 0 && refused.length > 0 ? { isError: true } : {}),
			};
		},
	});
}

const text = (value: string) => [{ type: "text" as const, text: value }];
