// Running schedules (#483, moved from main.ts): arming the timer for the next one due, starting a run (`fire`: a new
// conversation with the schedule's agent, then its prompt, `deliver`), holding a schedule whose project was deleted,
// and the `schedules.*` requests. The rules of a schedule and its times are schedules.ts's. main.ts hands over what it
// uses of the engine (`wireSchedules`), watches the schedules document and sets what it says (`setSchedules`).

import type { Context } from "@earendil-works/chord/context";
import type { AgentChange, Conversation, ConversationId, Harness } from "@earendil-works/pi-durable";
import { carriedProjectFor } from "./carryover.ts";
import type { Host } from "./extensions.ts";
import { agents } from "./indexes.ts";
import { PROJECT_ARCHIVED, PROJECT_DELETED, Projects, refuseStartWith, startWithRefusal } from "./projects.ts";
import { checkPersonStart, type Params, startConfirmation, text } from "./requests.ts";
import { RequestError } from "./requesterror.ts";
import { nextRun, type Schedule, Schedules, validateRepeat } from "./schedules.ts";
import { type AgentProfile, Agents, Library, type ModelRef, projectFrom, scheduleRunsAs } from "./state.ts";
import { overBudget } from "./usage.ts";

// What this file uses of the running engine, handed over by main.ts once it has them (`wireSchedules`).
let harness: Harness;
let context: Context;
let log: (...parts: unknown[]) => void;
let host: Host;
let takeSwitch: (id: ConversationId) => Promise<void>;
let syncTools: (conv: Conversation) => Promise<void>;
let agentChange: (agent: AgentProfile, options: { subChat: boolean; projectId?: string | null; model?: ModelRef }) => Promise<AgentChange>;

export function wireSchedules(parts: { harness: Harness; context: Context; log: typeof log; host: Host; takeSwitch: typeof takeSwitch; syncTools: typeof syncTools; agentChange: typeof agentChange }): void {
	({ harness, context, log, host, takeSwitch, syncTools, agentChange } = parts);
}

/** The schedules document as main.ts's watch last read it. */
export function setSchedules(value: typeof schedules): void {
	schedules = value;
}

let schedules: Record<string, Schedule> = {};
export const schedulesEvent = () => ({ event: "schedules", schedules: Object.values(schedules).sort((x, y) => x.createdAt - y.createdAt) });
export let scheduleTimer: ReturnType<typeof setTimeout> | undefined;
const firing = new Set<string>();
const scheduleRecheck = new Map<string, number>();

/** Hold a schedule left by an earlier engine, unless the person has reassigned it since this attempt. */
async function holdDeletedSchedule(schedule: Schedule): Promise<void> {
	const held = await harness.commit(async (tx) => {
		const current = (await tx.doc(Schedules)).schedules[schedule.id];
		if (current?.agentId !== schedule.agentId || current.holdReason !== undefined) return false;
		current.holdReason = PROJECT_DELETED;
		return true;
	}, context);
	if (held) log("schedule", schedule.id, "held:", PROJECT_DELETED);
}

/** Submit the prompt of a run whose conversation exists. The request ID makes doing this twice harmless. */
async function deliver(id: string): Promise<void> {
	const schedule = schedules[id];
	const pending = schedule?.pending;
	if (schedule === undefined || schedule.holdReason !== undefined || pending == null) return;
	const conv = await harness.conversation(pending.conversationId as unknown as ConversationId, context);
	if (conv !== undefined) {
		await takeSwitch(conv.id);
		// Its tools as this conversation's, not as its agent's before it was made: a run made as a project's orchestrator
		// is not its current conversation, and has none of the tools only that one has (docs/projects.md, 3.13).
		await syncTools(conv).catch((error) => log("could not update the tools of conversation", conv.id, error instanceof Error ? error.message : ""));
	}
	const held = await harness.commit(async (tx) => {
		const current = (await tx.doc(Schedules)).schedules[id];
		if (current?.pending?.runAt !== pending.runAt || current.holdReason !== undefined) return false;
		const meta = (await tx.doc(Library)).conversations[String(pending.conversationId)];
		const { agents } = await tx.doc(Agents);
		const projects = (await tx.doc(Projects)).projects;
		const own = meta?.agentId === undefined ? undefined : agents[meta.agentId];
		const agent = agents[current.agentId];
		if ((own !== undefined && startWithRefusal(own, projects) === PROJECT_DELETED) || (agent !== undefined && startWithRefusal(agent, projects) === PROJECT_DELETED)) {
			current.holdReason = PROJECT_DELETED;
			return true;
		}
		await conv?.submit(tx, { type: "input", content: current.prompt, requestId: `schedule:${id}:${pending.runAt}` });
		current.pending = null;
		return false;
	}, context);
	if (held) log("schedule", id, "held:", PROJECT_DELETED);
}

/**
 * The agent a run of `schedule` is made with (docs/projects.md, 3.13): the one it runs as, but for a schedule carried to
 * a copy in an archived project, its template, whose run is carried into that project and restores it, as a schedule's
 * run did before it was carried (3.6, 9.9).
 */
function firesAs(schedule: Schedule): string {
	const id = scheduleRunsAs(schedule, agents);
	const copy = agents[id];
	return id !== schedule.agentId && copy !== undefined && startWithRefusal(copy) === PROJECT_ARCHIVED ? schedule.agentId : id;
}

/** Start one run of a schedule: a new conversation with its agent, then its prompt. */
async function fire(id: string, manual: boolean, confirm?: string): Promise<string | undefined> {
	const schedule = schedules[id];
	if (schedule === undefined || firing.has(id)) return;
	if (schedule.holdReason !== undefined) {
		if (manual) throw new Error(schedule.holdReason);
		return;
	}
	firing.add(id);
	try {
		const agent = agents[firesAs(schedule)] ?? Object.values(agents).sort((x, y) => x.createdAt - y.createdAt)[0];
		if (agent === undefined) return;
		if (agent.projectId !== undefined) refuseStartWith(agent);
		const change = await agentChange(agent, { subChat: false });
		const carriedInto = await carriedProjectFor(agent, change.cwd ?? null);
		let note: string | undefined;
		const now = Date.now();
		const due = schedule.nextRunAt;
		const created = await harness.createConversation(
			{
				ownership: { kind: "ownerless" },
				agent: change,
				// The conversation and the schedule's bookkeeping are one commit: a crash leaves both or neither.
				init: async (tx, conversationId) => {
					const current = (await tx.doc(Schedules)).schedules[id];
					if (current?.holdReason !== undefined) throw new Error(current.holdReason);
					if (current === undefined || current.agentId !== schedule.agentId || (!manual && current.nextRunAt !== due)) throw new Error("The schedule changed while it was starting");
					if (agent.projectId !== undefined || carriedInto !== undefined) note = await checkPersonStart(tx, agent, change.model, confirm, { schedule: id }, current.prompt, carriedInto);
					(await tx.doc(Library)).conversations[String(conversationId)] = { title: current.title, createdAt: now, updatedAt: now, access: agent.access, agentId: agent.id, ...projectFrom(agent) };
					current.pending = { conversationId: conversationId as unknown as number, runAt: now };
					current.lastRunAt = now;
					current.lastConversationId = conversationId as unknown as number;
					if (!manual) {
						// Runs missed while the engine was off are not replayed one by one: the next run is in the future.
						current.nextRunAt = nextRun(current.repeat, now);
						if (current.nextRunAt === null) current.enabled = false;
					}
				},
			},
			context,
		);
		for (const feature of host.features) await feature.made?.(created.id as unknown as number);
		schedules = (await harness.snapshot(Schedules, context))?.schedules ?? schedules;
		await deliver(id);
		scheduleRecheck.delete(id);
		return note;
	} catch (error) {
		if (error instanceof Error && error.message === PROJECT_DELETED) {
			await holdDeletedSchedule(schedule);
			if (manual) throw error;
			return;
		}
		// Run Now tells the person why nothing started: a limit, or a project archived (docs/projects.md, 3.13).
		if (manual && (error instanceof RequestError || (error instanceof Error && error.message === PROJECT_ARCHIVED))) throw error;
		// An automatic run stays due until admitted; don't spin on a refusal with a past nextRunAt.
		if (!manual && (agents[firesAs(schedule)]?.projectId !== undefined || error instanceof RequestError)) scheduleRecheck.set(id, Date.now() + 60_000);
		log("schedule", id, "did not start:", error instanceof Error ? error.message : error);
	} finally {
		firing.delete(id);
	}
}

export function armSchedules(): void {
	clearTimeout(scheduleTimer);
	const due = Object.values(schedules).filter((x) => x.holdReason === undefined && x.enabled && x.nextRunAt !== null);
	if (due.length === 0) return;
	const next = Math.min(...due.map((x) => Math.max(x.nextRunAt!, scheduleRecheck.get(x.id) ?? 0)));
	// setTimeout cannot wait longer than about 24 days; waking early and re-arming is harmless.
	// While the budget is used up a due run stays due; look again in a minute rather than spinning.
	const soonest = overBudget() ? 60_000 : 0;
	scheduleTimer = setTimeout(() => void tickSchedules(), Math.min(Math.max(next - Date.now(), soonest), 2_000_000_000));
}

export async function tickSchedules(): Promise<void> {
	const now = Date.now();
	for (const schedule of Object.values(schedules)) {
		if (schedule.holdReason !== undefined) continue;
		const agent = agents[schedule.agentId];
		if (agent !== undefined && startWithRefusal(agent) === PROJECT_DELETED) {
			await holdDeletedSchedule(schedule).catch((error) => log("schedule", schedule.id, "could not be held:", error));
		} else if (schedule.pending !== null) await deliver(schedule.id).catch((error) => log("schedule", schedule.id, "delivery failed:", error));
		else if (schedule.enabled && schedule.nextRunAt !== null && schedule.nextRunAt <= now && (scheduleRecheck.get(schedule.id) ?? 0) <= now) {
			// Out of budget: the run stays due and starts once there is budget again.
			if (overBudget()) log("schedule", schedule.id, "is waiting: today's budget is used up");
			else await fire(schedule.id, false);
		}
	}
	armSchedules();
}

export const scheduleRequests: Record<string, (params: Params) => Promise<unknown>> = {
	"schedules.save": async (params) => {
		const input = params.schedule as Partial<Schedule> | undefined;
		const title = typeof input?.title === "string" ? input.title.trim() : "";
		const prompt = typeof input?.prompt === "string" ? input.prompt.trim() : "";
		if (input === undefined || title === "") throw new Error("Give the schedule a name");
		if (prompt === "") throw new Error("Write what the agent should do");
		if (typeof input.agentId !== "string" || agents[input.agentId] === undefined) throw new Error("Choose an agent");
		const repeat = validateRepeat(input.repeat);
		const previous = input.id === undefined ? undefined : schedules[input.id];
		if (input.id !== undefined && previous === undefined) throw new Error(`Unknown schedule: ${input.id}`);
		const now = Date.now();
		const enabled = input.enabled ?? previous?.enabled ?? true;
		const next = nextRun(repeat, now);
		if (repeat.kind === "once" && next === null && enabled) throw new Error("That time has already passed");
		const id = input.id ?? `s${now.toString(36)}${Math.floor(Math.random() * 1e6).toString(36)}`;
		const schedule: Schedule = {
			id,
			title,
			agentId: input.agentId,
			prompt,
			repeat,
			enabled: enabled && next !== null,
			nextRunAt: next,
			lastRunAt: previous?.lastRunAt ?? null,
			lastConversationId: previous?.lastConversationId ?? null,
			// A held prompt belongs to the old conversation, not to the agent the person is now choosing.
			pending: previous?.holdReason === undefined ? previous?.pending ?? null : null,
			createdAt: previous?.createdAt ?? now,
			// Who made it is kept through the person's edits; the app cannot set it.
			...(previous?.createdBy !== undefined ? { createdBy: previous.createdBy } : {}),
			// The project's copy it was carried to stays while its agent does; another agent chosen is the person's choice
			// (docs/projects.md, 3.13). The app cannot set it either.
			...(previous?.projectAgentId !== undefined && previous.agentId === input.agentId ? { projectAgentId: previous.projectAgentId } : {}),
		};
		await harness.commit(async (tx) => {
			const agent = (await tx.doc(Agents)).agents[schedule.agentId];
			if (agent === undefined) throw new Error("Choose an agent");
			if (agent.projectId !== undefined && startWithRefusal(agent, (await tx.doc(Projects)).projects) === PROJECT_DELETED) throw new Error(PROJECT_DELETED);
			(await tx.doc(Schedules)).schedules[id] = schedule;
		}, context);
		return { id };
	},
	"schedules.delete": async (params) => {
		const id = text(params, "id");
		await harness.commit(async (tx) => void delete (await tx.doc(Schedules)).schedules[id], context);
		return {};
	},
	"schedules.runNow": async (params) => {
		const id = text(params, "id");
		if (schedules[id] === undefined) throw new Error(`Unknown schedule: ${id}`);
		const note = await fire(id, true, startConfirmation(params));
		return { conversationId: schedules[id]?.lastConversationId ?? null, ...(note === undefined ? {} : { note }) };
	},
};
