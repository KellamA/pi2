// An agent can schedule its own work: a prompt it will be sent in a new conversation later, once or repeating.
//
// Per agent and off by default. The person approves every new schedule, and there is no "always allow": a schedule
// runs later with no one watching, so each one is a decision of its own. The agent can list its schedules and cancel
// the ones it set, never the person's, and it never schedules another agent. The schedules themselves are the same rows
// the person makes in Activity (schedules.ts), marked with `createdBy`; main.ts watches them and runs them.
// See docs/schedules.md.

import { type ConversationId, defineTool, section } from "@earendil-works/pi-durable";
import { int, obj, opt, str } from "@earendil-works/pi-schema";
import type { Feature } from "./features.ts";
import { nextRun, type Repeat, type Schedule, Schedules, validateRepeat } from "./schedules.ts";
import type { AgentProfile } from "./state.ts";

export type ScheduleSettings = { enabled: boolean };

export function validateScheduleSettings(input: unknown): ScheduleSettings {
	const value = (input ?? {}) as Partial<ScheduleSettings>;
	return { enabled: value.enabled === true };
}

/** The shortest gap between runs of a repeating schedule an agent sets. */
export const MIN_INTERVAL_MINUTES = 15;
/** The longest, as the schedules the person makes allow. */
const MAX_INTERVAL_MINUTES = 60 * 24 * 30;
/** How many schedules each agent may have set that can still run. */
export const MAX_AGENT_SCHEDULES = 20;
export const MAX_TITLE = 80;
export const MAX_PROMPT = 2000;
/** How far ahead a one-off run may be set. */
const MAX_AHEAD_DAYS = 366;

const TOOL_NAMES = ["schedule_task", "list_schedules", "cancel_schedule"];

// ---- Times, in the Mac's local time

const WEEKDAYS = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"];
const MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];
const pad = (n: number) => String(n).padStart(2, "0");
const capital = (value: string) => value.charAt(0).toUpperCase() + value.slice(1);
const clock = (hour: number, minute: number) => `${pad(hour)}:${pad(minute)}`;
const weekdayOf = (ms: number) => capital(WEEKDAYS[new Date(ms).getDay()]!);

/** "2026-11-13 07:30": what the model is told, and the form it gives times back in. */
export function localStamp(ms: number): string {
	const d = new Date(ms);
	return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${clock(d.getHours(), d.getMinutes())}`;
}

/**
 * "Friday 13 November at 07:30", with the year when it is not this one: what the person reads. Never "tomorrow": an
 * approval can wait in the Inbox past midnight, and would then name the wrong day.
 */
export function plainMoment(ms: number, now = Date.now()): string {
	const d = new Date(ms);
	const year = d.getFullYear() === new Date(now).getFullYear() ? "" : ` ${d.getFullYear()}`;
	return `${weekdayOf(ms)} ${d.getDate()} ${MONTHS[d.getMonth()]}${year} at ${clock(d.getHours(), d.getMinutes())}`;
}

/** How often a schedule runs: "every day at 07:00", "every Monday at 09:00", "every 2 hours", "once, on …". */
export function describeRepeat(repeat: Repeat, now = Date.now()): string {
	switch (repeat.kind) {
		case "once":
			return `once, on ${plainMoment(repeat.at, now)}`;
		case "daily":
			return `every day at ${clock(repeat.hour, repeat.minute)}`;
		case "weekly":
			return `every ${capital(WEEKDAYS[repeat.weekday] ?? "week")} at ${clock(repeat.hour, repeat.minute)}`;
		case "interval": {
			const m = repeat.minutes;
			if (m % 1440 === 0) return m === 1440 ? "every 24 hours" : `every ${m / 1440} days`;
			if (m % 60 === 0) return m === 60 ? "every hour" : `every ${m / 60} hours`;
			return `every ${m} minutes`;
		}
	}
}

/** When a new schedule would run, for its approval: "every day at 07:00, first run Friday 13 November at 07:00". */
export function describeWhen(repeat: Repeat, first: number, now = Date.now()): string {
	return repeat.kind === "once" ? describeRepeat(repeat, now) : `${describeRepeat(repeat, now)}, first run ${plainMoment(first, now)}`;
}

/** The time zone runs are reckoned in, which is the Mac's own: "Europe/Berlin (UTC+01:00)". */
export function timeZone(at = Date.now()): string {
	const name = Intl.DateTimeFormat().resolvedOptions().timeZone || "local time";
	const offset = -new Date(at).getTimezoneOffset();
	return `${name} (UTC${offset < 0 ? "-" : "+"}${pad(Math.floor(Math.abs(offset) / 60))}:${pad(Math.abs(offset) % 60)})`;
}

/** A local date and time, "2026-11-13 09:00" (a "T" between and seconds are taken too), or undefined. No time zone. */
export function readLocalTime(value: string): number | undefined {
	const m = /^(\d{4})-(\d{2})-(\d{2})[ T](\d{1,2}):(\d{2})(?::(\d{2}))?$/.exec(value.trim());
	if (m === null) return undefined;
	const [year, month, day, hour, minute, second] = [m[1], m[2], m[3], m[4], m[5], m[6] ?? "0"].map(Number) as [number, number, number, number, number, number];
	const date = new Date(year, month - 1, day, hour, minute, second, 0);
	// 31 November, or an hour skipped when the clocks go forward, comes out as another time: refuse it rather than guess.
	if (date.getFullYear() !== year || date.getMonth() !== month - 1 || date.getDate() !== day || date.getHours() !== hour || date.getMinutes() !== minute) return undefined;
	return date.getTime();
}

function readClock(value: string | undefined, what: string): { hour: number; minute: number } | string {
	const m = /^(\d{1,2}):(\d{2})$/.exec((value ?? "").trim());
	if (m === null || Number(m[1]) > 23 || Number(m[2]) > 59) return `${what} needs \`time\` as HH:MM on the 24-hour clock, such as "07:30" or "18:00".`;
	return { hour: Number(m[1]), minute: Number(m[2]) };
}

export type TimingArgs = { repeat: string; at?: string; in_minutes?: number; time?: string; weekday?: string; minutes?: number };

/** The rule a schedule_task call asks for, or a plain message saying what to fix. */
export function resolveTiming(args: TimingArgs, now: number): Repeat | string {
	let repeat: Repeat;
	switch (args.repeat.trim().toLowerCase()) {
		case "once": {
			if (args.at !== undefined && args.in_minutes !== undefined) return "Give `at` or `in_minutes`, not both.";
			const tomorrow = localStamp(now + 86_400_000).slice(0, 10);
			let at: number;
			if (args.in_minutes !== undefined) {
				if (!Number.isInteger(args.in_minutes) || args.in_minutes < 1) return "`in_minutes` must be a whole number of minutes, 1 or more.";
				at = now + args.in_minutes * 60_000;
			} else if (args.at !== undefined) {
				const read = readLocalTime(args.at);
				if (read === undefined) return `\`at\` must be a local date and time, YYYY-MM-DD HH:MM, such as "${tomorrow} 09:00", with no time zone: times are this Mac's, in ${timeZone(now)}.`;
				at = read;
			} else {
				return `A one-off schedule needs \`at\`, a local date and time such as "${tomorrow} 09:00", or \`in_minutes\` from now.`;
			}
			if (at <= now) return `${localStamp(at)} has already passed: it is now ${localStamp(now)} in ${timeZone(now)}. Give a later time, or use \`in_minutes\`.`;
			if (at > now + MAX_AHEAD_DAYS * 86_400_000) return `That is more than a year ahead. Schedule something within the next ${MAX_AHEAD_DAYS} days.`;
			repeat = { kind: "once", at };
			break;
		}
		case "daily": {
			const time = readClock(args.time, "A daily schedule");
			if (typeof time === "string") return time;
			repeat = { kind: "daily", ...time };
			break;
		}
		case "weekly": {
			const day = (args.weekday ?? "").trim().toLowerCase();
			const weekday = WEEKDAYS.findIndex((name) => day !== "" && (name === day || name.slice(0, 3) === day));
			if (weekday === -1) return "A weekly schedule needs `weekday`: monday, tuesday, wednesday, thursday, friday, saturday or sunday.";
			const time = readClock(args.time, "A weekly schedule");
			if (typeof time === "string") return time;
			repeat = { kind: "weekly", weekday, ...time };
			break;
		}
		case "interval": {
			const minutes = args.minutes;
			if (minutes === undefined) return `An interval schedule needs \`minutes\`, the minutes between runs: ${MIN_INTERVAL_MINUTES} or more.`;
			if (!Number.isInteger(minutes) || minutes < MIN_INTERVAL_MINUTES) return `A repeating schedule can run at most every ${MIN_INTERVAL_MINUTES} minutes, so ${minutes} is too often. Ask for ${MIN_INTERVAL_MINUTES} or more.`;
			if (minutes > MAX_INTERVAL_MINUTES) return `The longest gap between runs is ${MAX_INTERVAL_MINUTES} minutes (30 days).`;
			repeat = { kind: "interval", minutes };
			break;
		}
		default:
			return `Unknown \`repeat\` "${args.repeat}". Use once, daily, weekly or interval.`;
	}
	try {
		// The same check as a schedule the person makes, so the engine never stores a rule it cannot run.
		return validateRepeat(repeat);
	} catch (error) {
		return `${error instanceof Error ? error.message : String(error)}.`;
	}
}

/** The title on one line and the prompt trimmed, or what to fix. */
export function checkWords(title: string, prompt: string): { title: string; prompt: string } | string {
	const cleanTitle = title.replace(/\s+/g, " ").trim();
	const cleanPrompt = prompt.trim();
	if (cleanTitle === "") return "Give the schedule a short `title`, which the person sees.";
	if (cleanTitle.length > MAX_TITLE) return `The title is ${cleanTitle.length} characters; keep it to ${MAX_TITLE} or fewer.`;
	if (cleanPrompt === "") return "Write the `prompt`: what you should do when it runs.";
	if (cleanPrompt.length > MAX_PROMPT) return `The prompt is ${cleanPrompt.length} characters; the most is ${MAX_PROMPT}. Say it more briefly.`;
	return { title: cleanTitle, prompt: cleanPrompt };
}

/** A one-off that has run has nothing left to do; it stays listed until removed, but does not count towards the cap. */
const finished = (schedule: Schedule) => schedule.repeat.kind === "once" && schedule.nextRunAt === null;
/** Set by this agent, for this agent. One the person moved to another agent is theirs now. */
const ownBy = (schedule: Schedule, agentId: string) => schedule.agentId === agentId && schedule.createdBy?.agentId === agentId;
const counted = (schedules: Record<string, Schedule>, agentId: string) => Object.values(schedules).filter((s) => ownBy(s, agentId) && !finished(s)).length;

/** The prompt section: how to use the tools, and the date and time zone, so "tomorrow at 9" can be worked out. */
export function describeScheduling(now = Date.now()): string {
	const d = new Date(now);
	// The date only, not the clock: the section is sent again whenever it changes, and a clock would change every time.
	const today = `${weekdayOf(now)} ${d.getDate()} ${MONTHS[d.getMonth()]} ${d.getFullYear()} (${localStamp(now).slice(0, 10)})`;
	return [
		'You can schedule your own work with schedule_task: a prompt you will be sent in a new conversation, once at a set time or repeating. Use it when you are asked for something to happen later or regularly, such as "check this every morning" or "look again in two hours". Do not set one nobody asked for.',
		"The person approves each new schedule before it is set. Each run starts a fresh conversation that sees nothing of this one, often with no one watching, so write the prompt to stand on its own: what to do, where, and what to report.",
		`Times are this Mac's local time, in ${timeZone(now)}. Today is ${today}. For a time counted from now, such as "in two hours", use in_minutes; list_schedules tells you the current time.`,
		`Repeating schedules run at most every ${MIN_INTERVAL_MINUTES} minutes, and you can have at most ${MAX_AGENT_SCHEDULES} schedules that you set. list_schedules shows your schedules; cancel_schedule removes one you set. You cannot change or cancel a schedule the person set, or schedule work for another agent.`,
	].join("\n");
}

const text = (value: string) => [{ type: "text" as const, text: value }];
const fail = (message: string) => ({ output: text(message), isError: true });

const OFF = "Scheduling is turned off for this agent. The person can turn it on in the agent's settings, or set a schedule themselves in Activity.";
const DECLINED = "The person declined this schedule, so nothing was scheduled. Do not ask for it again unless they bring it up.";
const FULL = `You already have ${MAX_AGENT_SCHEDULES} schedules that you set, the most there can be. Cancel one that is no longer needed (list_schedules shows them), then try again.`;

export const selfSchedule: Feature = (host) => {
	/** The agent a conversation belongs to, when it may schedule. Read at every call, so turning it off counts at once. */
	const scheduler = (conversationId: ConversationId): AgentProfile | undefined => {
		const agent = host.agent(host.meta(conversationId)?.agentId);
		return agent?.schedule?.enabled === true ? agent : undefined;
	};

	const scheduleTask = defineTool({
		name: "schedule_task",
		description:
			"Schedule work for yourself: when it comes due you will be sent `prompt` in a new conversation, which may have no one watching. The person is asked to approve it first. `repeat` is one of:\n" +
			'- once: at `at`, a local date and time such as "2026-11-13 09:00", or `in_minutes` from now.\n' +
			'- daily: every day at `time`, such as "07:30" (24-hour clock).\n' +
			"- weekly: every `weekday` (monday to sunday) at `time`.\n" +
			`- interval: every \`minutes\` minutes, ${MIN_INTERVAL_MINUTES} or more.\n` +
			"Times are this Mac's local time, with no time zone; the <scheduling> section gives today's date and the time zone. " +
			`\`title\` is a short name the person sees (${MAX_TITLE} characters at most); \`prompt\` is what you will be told to do (${MAX_PROMPT} at most), written to stand on its own.`,
		parameters: obj({
			title: str({ description: "A short name for the schedule, shown to the person" }),
			prompt: str({ description: "What to do when it runs, written so it stands on its own" }),
			repeat: str({ description: "once, daily, weekly or interval" }),
			at: opt(str({ description: "For once: the local date and time, YYYY-MM-DD HH:MM" })),
			in_minutes: opt(int({ description: "For once, instead of at: minutes from now" })),
			time: opt(str({ description: "For daily and weekly: the local time, HH:MM on the 24-hour clock" })),
			weekday: opt(str({ description: "For weekly: monday, tuesday, wednesday, thursday, friday, saturday or sunday" })),
			minutes: opt(int({ description: `For interval: minutes between runs, ${MIN_INTERVAL_MINUTES} or more` })),
		}),
		// A rerun after a crash finds the schedule it already made (by the id it kept) and does not make another; one cut
		// off while waiting for the person asks again.
		replay: "safe",
		execute: async (args, api, context) => {
			const agent = scheduler(api.conversationId);
			if (agent === undefined) return fail(OFF);
			const words = checkWords(args.title, args.prompt);
			if (typeof words === "string") return fail(words);
			const resolved = resolveTiming(args, Date.now());
			if (typeof resolved === "string") return fail(resolved);
			// Kept with the call: after a restart the same schedule, with the same id and the same "in 2 hours", is asked about.
			const now = Date.now();
			const kept = await api.memo<{ id: string; repeat: Repeat }>("schedule", { id: `s${now.toString(36)}${Math.floor(Math.random() * 1e6).toString(36)}`, repeat: resolved }, context);
			const { id, repeat } = kept;

			const made = (schedule: Schedule) => {
				const next = schedule.nextRunAt ?? Date.now();
				const first = schedule.repeat.kind === "once" ? "It runs" : "The first run is";
				return {
					output: text(
						`Scheduled “${schedule.title}” (${schedule.id}): ${describeRepeat(schedule.repeat)}. ${first} at ${localStamp(next)} (${weekdayOf(next)}). ` +
							"Each run starts a new conversation with your prompt. Cancel it with cancel_schedule if it is no longer wanted.",
					),
					details: { id: schedule.id, title: schedule.title, when: describeRepeat(schedule.repeat) },
				};
			};
			const existing = (await api.snapshot(Schedules, context))?.schedules ?? {};
			if (existing[id] !== undefined) return made(existing[id]!);
			// Nothing is asked that could not be done.
			if (counted(existing, agent.id) >= MAX_AGENT_SCHEDULES) return fail(FULL);
			const first = nextRun(repeat, Date.now());
			if (first === null) return fail(`${repeat.kind === "once" ? localStamp(repeat.at) : "That time"} has already passed: it is now ${localStamp(Date.now())}. Give a later time.`);

			const when = describeWhen(repeat, first);
			const decision = await host.inbox.ask(
				{
					id: String(api.taskId),
					kind: "approval",
					conversationId: api.conversationId as unknown as number,
					callId: api.callId,
					tool: "schedule_task",
					arguments: args,
					question: `${agent.name} wants to schedule “${words.title}”: ${when} — ${words.prompt}`,
					when: capital(when),
					createdAt: Date.now(),
				},
				context,
			);
			// Only once or deny is offered. "always" from another app counts as once: nothing is remembered either way.
			if (decision !== "once" && decision !== "always") return fail(DECLINED);
			// The switch may have been turned off while the question waited.
			if (scheduler(api.conversationId)?.id !== agent.id) return fail(OFF);

			const result = await api.commit<{ schedule: Schedule } | { refused: string }>(async (tx) => {
				const doc = await tx.doc(Schedules);
				const already = doc.schedules[id];
				if (already !== undefined) return { schedule: JSON.parse(JSON.stringify(already)) as Schedule };
				if (counted(doc.schedules, agent.id) >= MAX_AGENT_SCHEDULES) return { refused: FULL };
				const at = Date.now();
				// The first run the person was shown, unless the decision took so long that it went by.
				const next = first > at ? first : nextRun(repeat, at);
				if (next === null) return { refused: `${localStamp(first)} went by while the person was deciding, so nothing was scheduled. It is now ${localStamp(at)}.` };
				const schedule: Schedule = {
					id,
					title: words.title,
					agentId: agent.id,
					prompt: words.prompt,
					repeat,
					enabled: true,
					nextRunAt: next,
					lastRunAt: null,
					lastConversationId: null,
					pending: null,
					createdAt: at,
					createdBy: { agentId: agent.id, conversationId: api.conversationId as unknown as number },
				};
				doc.schedules[id] = schedule;
				return { schedule };
			}, context);
			return "refused" in result ? fail(result.refused) : made(result.schedule);
		},
	});

	const listSchedules = defineTool({
		name: "list_schedules",
		description: "List your schedules: each one's id, title, when it runs, its next run, whether it is on, and whether you or the person set it. Also tells you the current local time.",
		parameters: obj({}),
		replay: "safe", // reading changes nothing
		execute: async (_args, api, context) => {
			const agent = scheduler(api.conversationId);
			if (agent === undefined) return fail(OFF);
			const all = (await api.snapshot(Schedules, context))?.schedules ?? {};
			const mine = Object.values(all)
				.filter((s) => s.agentId === agent.id)
				.sort((x, y) => x.createdAt - y.createdAt);
			const now = Date.now();
			const lines = [`It is now ${plainMoment(now, now)} (${localStamp(now)}, ${timeZone(now)}).`];
			if (mine.length === 0) lines.push("You have no schedules.");
			else lines.push(`Your schedules (${mine.length}):`);
			for (const s of mine) {
				const state = finished(s) ? "finished" : !s.enabled || s.nextRunAt === null ? "turned off" : `next run ${localStamp(s.nextRunAt)} (${weekdayOf(s.nextRunAt)})`;
				const who = ownBy(s, agent.id) ? "set by you" : s.createdBy === undefined ? "set by the person, so you cannot cancel it" : "not set by you, so you cannot cancel it";
				const prompt = s.prompt.replace(/\s+/g, " ").trim();
				lines.push(`- ${s.id}: “${s.title}”, ${describeRepeat(s.repeat, now)}; ${state}; ${who}.`, `  Prompt: ${prompt.length > 200 ? `${prompt.slice(0, 200)}…` : prompt}`);
			}
			lines.push(`You set ${counted(all, agent.id)} of the ${MAX_AGENT_SCHEDULES} schedules you may have; finished one-off schedules do not count.`);
			return { output: text(lines.join("\n")), details: { count: mine.length } };
		},
	});

	const cancelSchedule = defineTool({
		name: "cancel_schedule",
		description: "Cancel one of your schedules by its id from list_schedules, so it does not run again. Only a schedule you set; one the person set is theirs to change.",
		parameters: obj({ id: str({ description: "The schedule's id, from list_schedules" }) }),
		replay: "safe", // removing a schedule that is already gone changes nothing
		execute: async (args, api, context) => {
			const agent = scheduler(api.conversationId);
			if (agent === undefined) return fail(OFF);
			const id = args.id.trim();
			const result = await api.commit(async (tx) => {
				const doc = await tx.doc(Schedules);
				const schedule = doc.schedules[id];
				if (schedule === undefined || schedule.agentId !== agent.id) return { missing: true as const };
				const title = schedule.title;
				if (!ownBy(schedule, agent.id)) return { theirs: title };
				delete doc.schedules[id];
				return { title };
			}, context);
			if ("missing" in result) return fail(`There is no schedule ${id} of yours. list_schedules shows your schedules and their ids.`);
			if ("theirs" in result) {
				return fail(`“${result.theirs}” was set by the person, not by you, so you cannot cancel it. If it should stop, tell the person: they can turn it off or delete it in Activity.`);
			}
			return { output: text(`Cancelled “${result.title}” (${id}). It will not run again.`), details: { id, title: result.title } };
		},
	});

	return {
		tools: [scheduleTask, listSchedules, cancelSchedule],
		toolNames: (_access, agent) => (agent?.schedule?.enabled === true ? TOOL_NAMES : []),
		sections: [section("scheduling", (input) => (input.agent.tools.some((tool) => tool.name === "schedule_task") ? describeScheduling() : undefined))],
	};
};
