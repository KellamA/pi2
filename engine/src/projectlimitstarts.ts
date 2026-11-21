// The hand-off behind a limit card. Claim writes the accepted start before the tool that asked for it can be forgotten.
import { AgentDoc, type AgentChange, configure, type ConversationId, defineDoc, type JsonObject, type Tx } from "@earendil-works/pi-durable";
import { isArchived, isPutAway } from "./archive.ts";
import type { Host } from "./extensions.ts";
import type { Engine, FeatureParts } from "./features.ts";
import { type StoredNeed, onAnswer } from "./needs.ts";
import { ownsSubChat } from "./orchestrator.ts";
import { admit, rememberReading } from "./projectlimits.ts";
import { addNews, PROJECT_ARCHIVED, Projects, type Start } from "./projects.ts";
import { reportRun } from "./reports.ts";
import { Agents, Library, type AgentProfile, type ModelRef, type Meta, runsAs } from "./state.ts";
import { watch } from "./wakes.ts";
import { makeWorktree, subChatBranch, subChatFolder, worktreeOf } from "./worktrees.ts";

const conversation = (id: number) => id as unknown as ConversationId;
const copy = <T>(value: T): T => JSON.parse(JSON.stringify(value));

/** `branch`: the worktree a new sub-chat gets from its agent's own setting, with no `worktree` given (#604). */
type Pending = { projectId: string; start: Start; child: number; model: ModelRef | null; title: string; branch?: string };
type PendingDoc = { starts: Record<string, Pending> };
const AllowedStarts = defineDoc<JsonObject>({
	kind: "pi2.allowedStarts", version: 1, scope: "session", initial: () => ({ starts: {} }), checkpointWhen: () => true,
});
const allowedIn = async (tx: Tx) => (await tx.doc(AllowedStarts)) as unknown as PendingDoc;

/** The same child setup for delegate and Start Anyway. A child's project is the parent's, not its target's. */
export async function createDelegateChild(tx: Tx, args: { parent: number; target: AgentProfile; change: AgentChange; title: string; key: string }): Promise<ConversationId> {
	const { parent, target, change, title, key } = args;
	const library = (await tx.doc(Library)).conversations;
	const created = await tx.createConversation({ ownership: { kind: "ownerless" } });
	Object.assign(await tx.doc(AgentDoc, created.id), copy(await tx.doc(AgentDoc, conversation(parent))));
	await configure(tx, created.id, change);
	const now = Date.now();
	const projectId = library[String(parent)]?.projectId;
	library[String(created.id)] = {
		title, parent, madeBy: key, createdAt: now, updatedAt: now, access: target.access, agentId: target.id,
		...(target.allowEverything === true ? { allowEverything: true as const } : {}),
		...(projectId === undefined ? {} : { projectId }),
	};
	return created.id;
}

type LimitNeed = Extract<StoredNeed, { kind: "limit" }>;
/** `child` null: work on GitHub, where the claim and the start come after this commit (github.ts, #468). */
type AssignmentAnswer = (tx: Tx, need: LimitNeed) => Promise<{ limit: LimitNeed["limit"] } | { child: number | null; after?: () => Promise<void> }>;
let startAssignment: AssignmentAnswer | undefined;
/** #467 registers the same atomic assignment used by `work`, with the exact task held in the card. */
export function onLimitAssignment(start: AssignmentAnswer): void {
	startAssignment = start;
}

/** A continued child can have been archived, but not deleted, moved or switched to a different agent. */
export function checkChild(meta: Meta | undefined, parent: number, agentId: string, agents: Record<string, AgentProfile>): asserts meta is Meta {
	// Its own, or, for an orchestrator, one of its earlier conversations' (orchestrator.ts, #466).
	if (meta === undefined || !ownsSubChat(parent, meta.parent) || (isPutAway(meta) && !isArchived(meta)) || runsAs(meta, agents) !== agentId) throw new Error("That sub-chat is no longer available to continue.");
}

export function installLimitAnswers(host: Host, engine: Engine): FeatureParts {
	const executing = new Map<string, Promise<void>>();
	const harness = () => engine.harness();
	const context = () => engine.context();
	const decided = (tx: Tx, projectId: string, id: string, line: string) => addNews(tx, projectId, { kind: "limit", ref: id, text: line });

	async function finish(id: string, pending: Pending, failure?: string): Promise<void> {
		await harness().commit(async (tx) => {
			const doc = await allowedIn(tx);
			if (doc.starts[id] === undefined) return;
			delete doc.starts[id];
			if (failure !== undefined && pending.start.kind === "new") {
				const meta = (await tx.doc(Library)).conversations[String(pending.child)];
				if (meta !== undefined && meta.subChatTask === undefined) meta.deleted = true;
			}
			await decided(tx, pending.projectId, id, failure === undefined
				? `The person allowed the start with ${pending.start.agentName}: sub-chat ${pending.child} “${pending.title}”.`
				: `The person allowed the start with ${pending.start.agentName}, but it could not start: ${failure}`);
		}, context());
	}

	function run(id: string, pending: Pending): Promise<void> {
		const already = executing.get(id);
		if (already !== undefined) return already;
		const run = (async () => {
			const { start, child, projectId } = pending;
			const parent = start.parent!;
			const key = `limit:${id}`;
			const branch = typeof start.options.worktree === "string" ? start.options.worktree.trim() : pending.branch;
			if (branch !== undefined) {
				try {
					if ((await worktreeOf(harness(), child, context())) === undefined) await makeWorktree(child, branch, typeof start.options.from === "string" ? start.options.from : undefined);
				} catch (error) {
					await finish(id, pending, error instanceof Error ? error.message : String(error));
					throw error;
				}
			}
			let unavailable: string | undefined;
			const sent = await host.sendToChat(child, start.task, key, async (tx, meta, model) => {
				const project = (await tx.doc(Projects)).projects[projectId];
				const library = (await tx.doc(Library)).conversations;
				const agents = (await tx.doc(Agents)).agents;
				try {
					if (project?.deletedAt !== undefined || project?.archivedAt !== undefined || isPutAway(library[String(parent)])) throw new Error("The project or parent conversation was put away.");
					checkChild(meta, parent, start.agentId, agents);
					if (JSON.stringify(model ?? null) !== JSON.stringify(pending.model)) throw new Error("The sub-chat's model changed. Ask for the start again.");
				} catch (error) {
					unavailable = error instanceof Error ? error.message : String(error);
					return false;
				}
				delete meta.archivedAt;
				if (start.title !== null && meta.renamed !== true) meta.title = start.title;
				return true;
			});
			if (sent === undefined) {
				await finish(id, pending, unavailable ?? "The sub-chat could not be reached.");
				throw new Error(unavailable ?? "The sub-chat could not be reached.");
			}
			// The tool that asked has already answered, even if it asked to wait. Give the result through the report/watch.
			await reportRun(parent, { submissionId: sent, conversationId: child, agentId: start.agentId, title: pending.title });
			await watch({ key, conversationId: parent, kind: "subchat", ref: String(child), label: `sub-chat ${child} “${pending.title}”`, startedAt: Date.now(), submissionId: sent, agent: start.agentName });
			await finish(id, pending);
		})().finally(() => executing.delete(id));
		executing.set(id, run);
		return run;
	}

	onAnswer("limit", async (tx, need, answer) => {
		const { id, projectId, start } = need;
		if (!answer.start) {
			await decided(tx, projectId, id, `The person left the start with ${start.agentName} unstarted.`);
			return;
		}
		const project = (await tx.doc(Projects)).projects[projectId];
		if (project === undefined || project.deletedAt !== undefined) throw new Error(`Unknown project: ${projectId}`);
		if (project.archivedAt !== undefined) throw new Error(PROJECT_ARCHIVED);
		if (start.kind === "assign") {
			if (startAssignment === undefined) throw new Error("Work assignment is not available yet.");
			const result = await startAssignment(tx, need);
			if ("limit" in result) {
				need.confirmed = rememberReading(need.confirmed ?? [], need.limit);
				need.limit = result.limit;
				return { keep: true };
			}
			await decided(tx, projectId, id, result.child === null
				? `The person allowed work #${start.work} to start with ${start.agentName}; it starts once it is claimed on GitHub.`
				: `The person allowed work #${start.work} to start with ${start.agentName}: sub-chat ${result.child}.`);
			return { after: result.after };
		}
		const parent = start.parent;
		if (parent === null || (start.kind !== "new" && start.kind !== "continue")) throw new Error("The held start is no longer available.");
		const library = (await tx.doc(Library)).conversations;
		const parentMeta = library[String(parent)];
		if (parentMeta?.projectId !== projectId || isPutAway(parentMeta)) throw new Error("The parent conversation was put away.");
		const agents = (await tx.doc(Agents)).agents;
		const target = agents[start.agentId];
		if (target === undefined || target.removedAt !== undefined || (target.projectId !== undefined && target.projectId !== projectId)) throw new Error(`Unknown agent: ${start.agentId}`);
		const existing = start.chat === null ? undefined : library[String(start.chat)];
		let change: AgentChange | undefined;
		let model: ModelRef | null | undefined;
		if (start.kind === "continue" && start.chat !== null) {
			checkChild(existing, parent, target.id, agents);
			model = (await tx.doc(AgentDoc, conversation(start.chat))).model;
		} else {
			const here = (await tx.doc(AgentDoc, conversation(parent))).cwd ?? null;
			change = { ...await host.agentChange(target, { subChat: true }), cwd: await subChatFolder(here, target.cwd) };
			model = change.model;
		}
		const card = rememberReading(need.confirmed ?? [], need.limit);
		const result = await admit(start, undefined, { tx, model, card });
		if (!result.ok) {
			need.confirmed = card;
			need.limit = result.limit;
			return { keep: true };
		}
		const over = engine.overBudget();
		if (over !== undefined) throw new Error(`${over} Raise it in Usage to carry on.`);
		const title = existing?.renamed === true ? existing.title : start.title ?? existing?.title ?? (typeof start.options.worktree === "string" ? `${target.name}: ${start.options.worktree.trim()}` : `${target.name}: ${start.task.trim().split("\n")[0]!.slice(0, 60)}`);
		const child = start.chat ?? Number(await createDelegateChild(tx, { parent, target, change: change!, title, key: `limit:${id}` }));
		// A new sub-chat of an agent whose own setting gives it a worktree gets one, as `delegate`'s does (#604).
		const branch = start.kind === "new" && typeof start.options.worktree !== "string" ? await subChatBranch(undefined, target, change?.cwd ?? null) : undefined;
		const pending: Pending = { projectId, start, child, model: copy(model ?? null), title, ...(branch === undefined ? {} : { branch }) };
		(await allowedIn(tx)).starts[id] = pending;
		return { after: () => run(id, pending) };
	});

	return { start: async () => {
		const saved = (await harness().snapshot(AllowedStarts, context())) as PendingDoc | undefined;
		if (saved === undefined) return;
		void host.ready.then(async () => {
			for (const [id, pending] of Object.entries(saved.starts)) await run(id, copy(pending)).catch((error) => engine.log("could not finish allowed start", id, error));
		});
	} };
}
