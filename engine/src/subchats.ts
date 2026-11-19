// An agent's own sub-chats: seeing how each stands, and archiving the finished ones (issue #150). See docs/archive.md.
//
// `delegate` leaves a sub-chat behind for every task. An agent that hands out a lot of work can list them and put the
// finished ones away, within bounds: only sub-chats of its own conversation, never one that is working or waiting on
// the person, and archived, never deleted, so the person can read and restore it from the Archive. Archiving stops the
// commands a sub-chat left running in the background, and leaves a worktree of its own where it is, as archiving by
// hand does. The calling conversation gets a line saying what was put away.

import { realpathSync } from "node:fs";
import { sep } from "node:path";
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
import { type BranchInfo, inspect, removeWorktree, whyKeepWorktree, type Worktree, worktreeOf } from "./worktrees.ts";

/** A line in the calling conversation's transcript: which sub-chats were archived, or restored to be continued. */
export const SUBCHATS_ENTRY = "pi2.subchats";

type Named = { id: number; title: string };
type MarkerData = { action: "archived" | "restored"; chats: Named[]; stopped?: number; removed?: string[] };

/** What the transcript shows for a `SUBCHATS_ENTRY`. */
export function subChatsMarker(data: unknown): string {
	const entry = (data !== null && typeof data === "object" ? data : {}) as Partial<MarkerData>;
	const chats = Array.isArray(entry.chats) ? entry.chats.filter((chat) => typeof chat?.id === "number") : [];
	const named = chats.map((chat) => `${typeof chat.title === "string" && chat.title.trim() !== "" ? `“${chat.title.trim()}” ` : ""}(${chat.id})`).join(", ");
	if (entry.action === "restored") return `The agent restored sub-chat ${named} from the Archive to continue it`;
	const one = chats.length === 1;
	const stopped = typeof entry.stopped === "number" && entry.stopped > 0 ? ` ${entry.stopped} background command${entry.stopped === 1 ? "" : "s"} ${one ? "it" : "they"} left running ${entry.stopped === 1 ? "was" : "were"} stopped.` : "";
	const branches = Array.isArray(entry.removed) ? entry.removed.filter((branch) => typeof branch === "string") : [];
	const removed = branches.length === 0 ? "" : ` The agent removed ${branches.length === 1 ? "a worktree" : `${branches.length} worktrees`} with nothing uncommitted or unmerged; ${branches.length === 1 ? "its branch" : "their branches"} ${branches.join(", ")} ${branches.length === 1 ? "is" : "are"} kept.`;
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
	if (info.state === "merged") parts.push(`merged into ${info.base}`);
	else if (info.unmerged !== null && info.base !== null) parts.push(info.unmerged === 0 ? `no commits that are not on ${info.base}` : `${plural(info.unmerged, "commit")} not on ${info.base}`);
	if (info.upstream !== null && info.ahead > 0) parts.push(`${plural(info.ahead, "commit")} not pushed to ${info.upstream}`);
	return parts.join(", ");
}

/**
 * Whether a sub-chat or one of its own sub-chats is busy, waiting on the person or waiting for a provider's limit, and if
 * so, in words.
 */
function activity(host: Host, ids: number[]): string | undefined {
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
 * The end of `sub_chats`' list: how much of each signed-in subscription's windows is used and when each resets, and
 * which subscription this conversation and each agent it can hand work to runs on. Nothing when no feature knows.
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
	for (const id of host.agent(host.meta(api.conversationId)?.agentId)?.delegates ?? []) {
		const agent = host.agent(id);
		// What a new sub-chat with that agent would run on: its own model, or the default one.
		if (agent !== undefined) add((await host.agentChange(agent, { subChat: true }).catch(() => undefined))?.model?.provider, agent.name);
	}
	return ["", ...limitsReport(views, users, Date.now())];
}

export const SUB_CHATS_DESCRIPTION =
	"See the sub-chats this conversation opened with delegate, and archive the ones whose work is finished. Actions:\n" +
	"- list: each sub-chat's number, agent and title; whether it is working, waiting for a provider's limit (and until when), waiting on the person or idle; the folder and branch it works in (for a worktree of its own, whether anything is uncommitted and whether its branch is merged); and the commands it left running in the background. Archived ones are named at the end. " +
	"Then how much of each signed-in subscription's allowance is used and when each window resets, and which subscription you and each of your agents run on: list before starting more sub-chats when a window may be nearly used up.\n" +
	"- archive: put away the sub-chats numbered in `chats`. Use it once you have what you needed from a sub-chat and will not continue it, or when the person asks you to tidy up. " +
	"An archived sub-chat leaves the sidebar for the Archive, where the person can read and restore it; nothing is deleted. Commands it left running in the background are stopped, and the answer says which. " +
	"A worktree of its own is left as it is, unless you pass `remove_worktree: true` and removing it loses nothing: nothing uncommitted and no commits that are not on the branch it was made from (fetch first if it was merged elsewhere). Its branch is kept either way. " +
	"A sub-chat that is working or waiting on the person is not archived. Continuing an archived sub-chat with delegate and its number restores it.\n" +
	"- wait: wait for the next sub-chat you started with `wait: false` (or one of `chats`) to finish, and get its answer here instead of being woken for it; those already finished come at once.";

/** The `sub_chats` tool. Offered with `delegate`, to conversations that can hand work on. */
export function subChatsTool(host: Host) {
	return defineTool({
		name: "sub_chats",
		description: SUB_CHATS_DESCRIPTION,
		parameters: obj({
			action: str({ description: "list, archive or wait" }),
			chats: opt(arr(int(), { description: "For archive: the numbers of the sub-chats to archive. For wait: the sub-chats to wait for, by default all" })),
			remove_worktree: opt(bool({ description: "For archive: also remove each one's worktree of its own, if nothing would be lost (nothing uncommitted, no commits that are not on the branch it was made from). Its branch is kept." })),
		}),
		// Listing changes nothing, and archiving what is archived changes nothing.
		replay: "safe",
		execute: async (args, api, context): Promise<ToolExecutionResult> => {
			const caller = api.conversationId as unknown as number;
			const all = host.conversations();
			const mine = subChatsOf(all, caller);
			const parentWorktree = await worktreeOf(api, caller, context);
			const titleOf = (id: number) => all[String(id)]?.title ?? "";
			const agentOf = (id: number) => host.agent(all[String(id)]?.agentId)?.name ?? "an agent that was deleted";
			const action = args.action.trim().toLowerCase();

			if (action === "list") {
				// Those archived on their own; a sub-chat of an archived one goes with it.
				const archived = mine.filter((id) => isArchived(all[String(id)]));
				const listed = mine.filter((id) => !archived.includes(id) && !archived.includes(all[String(id)]?.parent ?? -1));
				const limits = await limitsOf(host, api, context);
				if (mine.length === 0) return { output: text(["This conversation has no sub-chats. delegate opens one.", ...limits].join("\n")), details: { action, count: 0 } };
				const lines: string[] = [];
				for (const id of listed) {
					const meta = all[String(id)]!;
					const busy = activity(host, [id, ...subChatsOf(all, id)]);
					const state = busy === undefined ? "idle" : watchedSubChats(caller).includes(id) ? `${busy}, and its answer will come to you as a message` : busy;
					const where = whereWords(await whereOf(api, id, parentWorktree, context));
					const commands = runningCommandsOf(id);
					const running = commands.length === 0 ? "no background commands running" : `background commands running: ${commands.map((command) => `${command.id} \`${command.command}\``).join(", ")}`;
					const under = meta.parent === caller ? "" : ` (a sub-chat of ${meta.parent})`;
					lines.push(`- ${id}${under}: ${agentOf(id)}, “${meta.title}”. ${state[0]!.toUpperCase()}${state.slice(1)}; last used ${elapsed(Date.now() - meta.updatedAt)} ago. It ${where}. ${running[0]!.toUpperCase()}${running.slice(1)}.`);
					const usage = await host.subChatUsage(id, context);
					if (usage !== "") lines.push(`  ${usage}`);
				}
				const head = listed.length === 0 ? "Every sub-chat of this conversation is archived." : "Sub-chats of this conversation:";
				const tail = archived.length === 0 ? [] : [`Archived: ${archived.map((id) => `${id} (“${titleOf(id)}”)`).join(", ")}. Continuing one with delegate restores it.`];
				for (const id of archived) {
					const usage = await host.subChatUsage(id, context);
					if (usage !== "") tail.push(`  ${id}: ${usage}`);
				}
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
			if (action !== "archive") return { output: text(`Unknown action "${args.action}". Use list, archive or wait.`), isError: true };
			const asked = [...new Set(args.chats ?? [])];
			if (asked.length === 0) return { output: text("archive needs `chats`: the numbers of the sub-chats to archive, from list."), isError: true };
			const lines: string[] = [];
			const archived: Named[] = [];
			const refused: number[] = [];
			let stopped = 0;
			/** The branches of worktrees removed on this call; each is kept. */
			const removed: string[] = [];
			/** What becomes of an archived sub-chat's worktree of its own: removed when asked and nothing would be lost, else left. */
			const worktreeAfter = async (id: number, where: Where): Promise<string[]> => {
				if (where.own === undefined) return [];
				const own = where.own;
				// The branch it is on now: it may have gone on to a new one after its first was merged (#206).
				const branch = where.info?.branch ?? own.branch;
				const standing = where.info === undefined ? "" : ` (${branchWords(where.info)})`;
				if (args.remove_worktree === true) {
					try {
						const result = await removeWorktree(id, { force: false, deleteBranch: false, onlyIfMerged: true });
						const kept = result.branch ?? branch;
						removed.push(kept);
						return [`Removed its worktree at ${own.path}; the branch ${kept} is kept.`];
					} catch (error) {
						return [`Its worktree was not removed: ${error instanceof Error ? error.message : String(error)}. See Branches → Left Behind.`];
					}
				}
				const left = `Its worktree at ${own.path}, branch ${branch}${standing}, was left where it is`;
				if (whyKeepWorktree(where.info) !== undefined) return [`${left}; it is listed in Branches under Left Behind.`];
				return [`${left}. Nothing would be lost by removing it: pass remove_worktree: true to remove it.`];
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
				const busy = activity(host, [id, ...subChatsOf(all, id)]);
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
			if (archived.length > 0 || removed.length > 0) {
				await noteSubChats(api, api.conversationId, { action: "archived", chats: archived, stopped, removed }, `sub_chats:${String(api.taskId)}`, context);
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
