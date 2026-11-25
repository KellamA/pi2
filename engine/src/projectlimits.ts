// The project's admission check (docs/projects.md, 8.3). It never asks a provider or reserves future spend.
import { randomUUID } from "node:crypto";
import { AgentDoc, type ConversationId, type Tx } from "@earendil-works/pi-durable";
import type { Host } from "./extensions.ts";
import type { Feature } from "./features.ts";
import { type ProviderLimits, subscriptionWords, windowWords } from "./limits.ts";
import { putNeed } from "./needs.ts";
import { addNews, type LimitReading, type Project, Projects, type Start } from "./projects.ts";
import { RequestError } from "./requesterror.ts";
import { Agents, Library, type ModelRef } from "./state.ts";
import { installLimitAnswers } from "./projectlimitstarts.ts";

type Breach = Omit<LimitReading, "id">;
export type Admission = { ok: true; note?: string } | { ok: false; limit: LimitReading };
export type AdmissionSite = {
	tx: Tx;
	/** The configured model, not the profile's suggestion (default model, or a conversation that changed models). */
	model: ModelRef | null | undefined;
	/** #458 can supply the folder's project when it attributes a new conversation independently of its agent. */
	projectId?: string;
	callId?: string;
	/** The receipt on a claimed card, not a token from a socket client. */
	card?: readonly LimitReading[];
};

type Confirmation = { start: string; readings: LimitReading[]; expires: number };
const confirmations = new Map<string, Confirmation>();
const CONFIRM_MS = 15 * 60_000;
let host: Host | undefined;
let spentToday: (tx: Tx, projectId: string) => Promise<number> = async () => 0;

export function wireProjectSpend(read: typeof spentToday): void {
	spentToday = read;
}

function planBreaches(max: number | null, view: ProviderLimits | undefined, now: number): { breaches: Breach[]; missing: boolean } {
	if (max === null) return { breaches: [], missing: false };
	const windows = view?.fetchedAt != null ? view.windows.filter((window) => window.resetsAt === null || window.resetsAt > now) : [];
	return {
		missing: windows.length === 0,
		breaches: windows.filter((window) => window.usedPercent >= max).sort((a, b) => b.usedPercent - a.usedPercent || a.id.localeCompare(b.id)).map((window) => ({
			limit: "planShare", provider: view!.id, window: window.id, used: window.usedPercent, max, resetsAt: window.resetsAt,
			reason: `the project's limit stops new agents while a plan window they would run on is ${max}% used or more, and ${subscriptionWords(view!)} has its ${windowWords(window, now)}`,
		})),
	};
}

/** The next local midnight, including on days when the clock changes. */
export function localMidnight(now: number): number {
	const day = new Date(now);
	return +day.setHours(24, 0, 0, 0);
}

async function readings(tx: Tx, project: Project, model: ModelRef | null | undefined): Promise<{ breaches: Breach[]; missing: boolean }> {
	const max = project.settings.limits.dailySpend;
	const used = max === null ? 0 : await spentToday(tx, project.id);
	const now = Date.now();
	const view = project.settings.limits.planShare === null || model == null ? undefined : host?.features.find((feature) => feature.planLimits !== undefined)?.planLimits?.().find((plan) => plan.id === model.provider);
	const result = planBreaches(project.settings.limits.planShare, view, now);
	if (max !== null && used >= max) result.breaches.push({
		limit: "dailySpend", provider: null, window: null, used, max, resetsAt: localMidnight(now),
		reason: `the project has spent $${used.toFixed(2)} today, reaching its daily limit of $${max.toFixed(2)}`,
	});
	return result;
}

/**
 * Match each current breach to a different reading the person confirmed for this one start. A reading covers its own
 * limit at whatever it reads now (#953): the same kind, provider, window and reset (for spend, the same day), at no
 * tighter a limit, however much more was spent or used since. A tighter limit, a limit or window it did not name (but
 * for a lower window of the same plan), or a new day or window is a new decision.
 */
export function uncovered(current: readonly Breach[], confirmed: readonly LimitReading[]): Breach | undefined {
	const remaining = [...confirmed];
	for (const limit of current) {
		const same = (reading: LimitReading) => reading.limit === limit.limit && reading.provider === limit.provider && reading.max <= limit.max;
		let index = remaining.findIndex((reading) => same(reading) && reading.window === limit.window && reading.resetsAt === limit.resetsAt);
		if (index === -1 && limit.limit === "planShare") {
			// A different window can count only when it is lower, and the reading is not needed for its own window.
			index = remaining.findIndex((reading) => same(reading) && reading.window !== limit.window && reading.used > limit.used && !current.some((each) => each.provider === reading.provider && each.window === reading.window));
		}
		if (index === -1) return limit;
		remaining.splice(index, 1);
	}
	return undefined;
}

/** Replace the reading for the same window/day, rather than accumulating every revision of it. */
export function rememberReading(previous: readonly LimitReading[], next: LimitReading): LimitReading[] {
	return [...previous.filter((reading) => reading.limit !== next.limit || reading.provider !== next.provider || reading.window !== next.window), next];
}

function startKey(start: Start, model: AdmissionSite["model"], projectId: string): string {
	return JSON.stringify([projectId, model?.provider, model?.modelId, start.kind, start.agentId, start.parent, start.chat, start.work, start.title, start.task, Object.entries(start.options).sort(([a], [b]) => a.localeCompare(b))]);
}

export function confirmLimit(given: unknown): string | undefined {
	if (given === undefined) return undefined;
	if (typeof given !== "string") throw new Error("confirmLimit must be the id of the limit reading");
	return given;
}

export function limitError(limit: LimitReading): RequestError {
	return new RequestError(`Past the project's limit: ${limit.reason}. Work already running carries on.`, { limit });
}

export function limitRefusal(limit: LimitReading, card: boolean): string {
	return `Not started: ${limit.reason}. Work already running carries on. ${card ? "The person can start it anyway from the card under Needs you, or raise the limit." : "The person can raise the limit in the project's settings."}`;
}

/**
 * Run inside the transaction that starts work, after any switch approval. A refused tool start returns (does not
 * throw), so its card and news can commit without the start. The card's handler uses this same check without making
 * a second card. A socket confirmation is private to one exact start and consumed synchronously, including on a race.
 */
export async function admit(start: Start, confirm: string | undefined, site: AdmissionSite): Promise<Admission> {
	const { tx } = site;
	const origin = start.chat ?? start.parent ?? (start.by.kind === "agent" ? start.by.conversationId : null);
	const projectId = site.projectId ?? (origin === null ? (await tx.doc(Agents)).agents[start.agentId]?.projectId : (await tx.doc(Library)).conversations[String(origin)]?.projectId);
	if (projectId === undefined) return { ok: true };
	const project = (await tx.doc(Projects)).projects[projectId];
	if (project === undefined || project.deletedAt !== undefined) return { ok: true };
	const { breaches, missing } = await readings(tx, project, site.model);
	const key = startKey(start, site.model, projectId);
	const now = Date.now();
	for (const [id, candidate] of confirmations) if (candidate.expires <= now) confirmations.delete(id);
	const token = start.by.kind === "person" && confirm !== undefined ? confirmations.get(confirm) : undefined;
	const matched = token?.start === key;
	if (matched) confirmations.delete(confirm!);
	const approved = site.card ?? (matched ? token!.readings : []);
	const blocked = uncovered(breaches, approved);
	const notes = missing ? ["Plan limits: no reading of this plan's windows yet."] : [];
	if (blocked === undefined || (start.by.kind === "agent" && site.card === undefined && project.settings.withoutAsking.passLimits)) {
		if (blocked !== undefined) for (const reading of breaches) notes.push(`Passed a project limit: ${reading.reason}.`);
		return notes.length === 0 ? { ok: true } : { ok: true, note: notes.join("\n") };
	}
	const limit = { ...blocked, id: randomUUID() };
	if (site.card === undefined) {
		if (start.by.kind === "person") {
			confirmations.set(limit.id, { start: key, readings: rememberReading(approved, limit), expires: now + CONFIRM_MS });
		} else if (project.conversation !== null && site.callId !== undefined) {
			const need = await putNeed(tx, { kind: "limit", projectId, conversationId: project.conversation, callId: site.callId, start, limit });
			const news = (await tx.doc(Projects)).news[projectId] ?? [];
			if (!news.some((item) => item.kind === "limit" && item.ref === need.id)) {
				await addNews(tx, projectId, { kind: "limit", ref: need.id, text: `Start with ${start.agentName} held: ${limit.reason}.` });
			}
		}
	}
	return { ok: false, limit };
}

/** Only report wakes call this, with the receiving conversation's actual model. No card, even with passLimits on. */
export async function reportPastLimit(tx: Tx, projectId: string, conversationId: number): Promise<boolean> {
	const project = (await tx.doc(Projects)).projects[projectId];
	if (project === undefined || project.deletedAt !== undefined || (project.settings.limits.planShare === null && project.settings.limits.dailySpend === null)) return false;
	const model = host?.features.some((feature) => feature.planLimits !== undefined) ? (await tx.doc(AgentDoc, conversationId as unknown as ConversationId)).model : undefined;
	return (await readings(tx, project, model)).breaches.length > 0;
}

export const projectLimits: Feature = (wired, engine) => {
	host = wired;
	return installLimitAnswers(wired, engine);
};
