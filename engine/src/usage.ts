// Usage (#483, moved from main.ts): totals from pi durable's own counters, priced by how each provider is connected,
// plus a per-day ledger for "today" and the daily budget, sent to the apps as the `usage` event. main.ts hands over
// what it uses of the engine (`wireUsage`) and starts the counting: the project limits' reading of the ledger, the
// watch on usage documents and the first count.

import type { Context } from "@earendil-works/chord/context";
import { type ConversationId, defineDoc, type Harness, UsageDoc } from "@earendil-works/pi-durable";
import { isPutAway } from "./archive.ts";
import { isChat } from "./chat.ts";
import { broadcast } from "./clients.ts";
import type { Host } from "./extensions.ts";
import { library } from "./indexes.ts";
import { lookUsageModel } from "./picturelook.ts";
import { pictureUsageModel } from "./pictures.ts";
import { allProjects } from "./projects.ts";
import { type Amount, dayKey, noSpend, noteConversationSpend, type SpendDoc } from "./projectspend.ts";
import { DEMO_MODEL, DEMO_PROVIDER, type Providers } from "./providers.ts";
import { Library, type Meta } from "./state.ts";
import { testSwitch } from "./testswitches.ts";

// What this file uses of the running engine, handed over by main.ts once it has them (`wireUsage`).
let harness: Harness;
let context: Context;
let settings: { dailyBudget?: number | null };
let providers: Providers;
let host: Host;
let log: (...parts: unknown[]) => void;
/** Whether the engine is stopping (main.ts, `stop`). */
let stopping: () => boolean;

export function wireUsage(parts: { harness: Harness; context: Context; settings: typeof settings; providers: Providers; host: Host; log: typeof log; stopping: typeof stopping }): void {
	({ harness, context, settings, providers, host, log, stopping } = parts);
}

/** Signing in or out changes which usage has a price: the next count prices all of it again. */
export function repriceUsage(): void {
	usagePricingChanged = true;
}

export type UsageJson = { input?: number; output?: number; cacheRead?: number; cacheWrite?: number; totalTokens?: number; cost?: { total?: number } };
export type UsageDocShape = { models?: Record<string, UsageJson>; tools?: Record<string, UsageJson> };
/**
 * What a usage entry cost. Providers report this themselves; the scripted demo model is free, except that tests give
 * it a price (PI2_DEMO_COST, dollars per million tokens) so that spend and budgets have something to count.
 */
const demoPrice = Number(testSwitch("PI2_DEMO_COST") ?? 0);
/**
 * Providers signed in with a subscription. pi-ai prices every answer at the model's list price, which is not what a
 * subscription costs, so their usage counts tokens only: no dollar figure, and nothing towards the daily budget.
 * This follows how the provider is connected now, so switching a provider between a subscription and a key
 * re-labels its earlier usage too.
 */
let subscriptions = new Set<string>();
const onSubscription = (key: string) => subscriptions.has(key.split("/")[0]!);
/** Added/discovered models have no verified price: Usage says so rather than mistaking the zero estimate for free. */
const unpriced = (key: string) => {
	const slash = key.indexOf("/");
	return !onSubscription(key) && providers.hasUnknownPrice(key.slice(0, slash), key.slice(slash + 1));
};
const costOf = (key: string, usage: UsageJson) => {
	if (onSubscription(key)) return 0;
	return key === `${DEMO_PROVIDER}/${DEMO_MODEL}` && demoPrice > 0 ? ((usage.totalTokens ?? 0) * demoPrice) / 1_000_000 : (usage.cost?.total ?? 0);
};
export const usageTotals = (usage: UsageDocShape | undefined) => {
	let cost = 0;
	let tokens = 0;
	for (const [key, entry] of [...Object.entries(usage?.models ?? {}), ...Object.entries(usage?.tools ?? {})]) {
		cost += costOf(key, entry);
		tokens += entry.totalTokens ?? 0;
	}
	return { cost, tokens };
};

export const usageById = new Map<ConversationId, { doc: UsageDocShape; totals: ReturnType<typeof usageTotals> }>();
let usagePricingChanged = true;
export let usageTimer: ReturnType<typeof setTimeout> | undefined;

export function usageRowsChanged(before: Record<string, Meta>, after: Record<string, Meta>): boolean {
	const changed = (old: Meta | undefined, next: Meta | undefined) =>
		(old === undefined) !== (next === undefined) || old?.title !== next?.title || old?.parent !== next?.parent ||
		old?.agentId !== next?.agentId || old?.projectId !== next?.projectId || isChat(old) !== isChat(next) || isPutAway(old) !== isPutAway(next);
	for (const [id, { totals }] of usageById) {
		if (totals.tokens === 0) continue;
		const meta = before[String(id)];
		if (changed(meta, after[String(id)])) return true;
		const root = String(meta?.parent ?? id);
		if (root !== String(id) && changed(before[root], after[root])) return true;
	}
	return false;
}

export const Spend = defineDoc<SpendDoc>({
	kind: "pi2.spend",
	version: 1,
	scope: "session",
	initial: () => ({ days: {}, lastCost: 0, lastTokens: 0 }),
	checkpointWhen: () => true,
});
export let usageSummary: Record<string, unknown> = { event: "usage", models: [], agents: [], chats: { cost: 0, tokens: 0 }, conversations: [], total: { cost: 0, tokens: 0 }, today: { cost: 0, tokens: 0 }, days: [], budget: { daily: null }, overBudget: false };
let todayCost = 0;
export const overBudget = () => typeof settings.dailyBudget === "number" && todayCost >= settings.dailyBudget;

// A published value is already a durable snapshot. Only the initial scan and definition-free copies need a read.
export const dirtyUsage = new Map<ConversationId, UsageDocShape | undefined | "read">();

let usageRefresh = Promise.resolve();
/** Serialize budget changes and background refreshes so a delayed ledger write cannot publish older totals. */
export function refreshUsage(): Promise<void> {
	const refresh = usageRefresh.then(updateUsage);
	usageRefresh = refresh.catch(() => {});
	return refresh;
}

type UsageCounters = { input: number; output: number; totalTokens: number; cost: { total: number } };
const emptyUsage = (): UsageCounters => ({ input: 0, output: 0, totalTokens: 0, cost: { total: 0 } });
function addUsageCounters(sum: UsageCounters, value: UsageJson): void {
	sum.input += value.input ?? 0;
	sum.output += value.output ?? 0;
	sum.totalTokens += value.totalTokens ?? 0;
	sum.cost.total += value.cost?.total ?? 0;
}

function sessionUsage(): UsageDocShape {
	// As in Harness.usage(), add each model/tool in durable conversation ID order, including conversations not in
	// the library. Keep raw costs here: rounding after per-conversation pricing can change the session total.
	const models: Record<string, UsageCounters> = Object.create(null);
	const tools: Record<string, UsageCounters> = Object.create(null);
	for (const [, { doc }] of [...usageById].sort(([a], [b]) => Number(a) - Number(b))) {
		for (const [source, target] of [[doc.models, models], [doc.tools, tools]] as const) {
			for (const [key, value] of Object.entries(source ?? {})) {
				addUsageCounters(target[key] ??= emptyUsage(), value);
			}
		}
	}
	return { models, tools };
}

/** Project picture rows from the tool ledger, without adding a second copy of the spend to model totals. */
function pictureRows(tools: UsageDocShape["tools"]) {
	const rows = new Map<string, { usage: UsageCounters; unpriced: boolean }>();
	for (const [bucket, usage] of Object.entries(tools ?? {})) {
		const model = pictureUsageModel(bucket);
		if (model === undefined) continue;
		const row = rows.get(model.key) ?? { usage: emptyUsage(), unpriced: false };
		addUsageCounters(row.usage, usage);
		row.unpriced ||= model.unpriced;
		rows.set(model.key, row);
	}
	return [...rows].map(([key, { usage, unpriced }]) => {
		const slash = key.indexOf("/");
		const provider = key.slice(0, slash);
		const model = providers.models.getModelOfType("image", provider, key.slice(slash + 1));
		const providerName = providers.models.getProvider(provider)?.name ?? provider;
		return {
			key, input: usage.input, output: usage.output, tokens: usage.totalTokens, cost: usage.cost.total, unpriced,
			pictureName: model === undefined ? key : `${providerName} · ${model.name}`,
		};
	});
}

/** The rows of models that looked at pictures for models that cannot see them (#540), from the same tool ledger. */
function lookRows(tools: UsageDocShape["tools"]) {
	const rows = new Map<string, { usage: UsageCounters; unpriced: boolean }>();
	for (const [bucket, usage] of Object.entries(tools ?? {})) {
		const model = lookUsageModel(bucket);
		if (model === undefined) continue;
		const row = rows.get(model.key) ?? { usage: emptyUsage(), unpriced: false };
		addUsageCounters(row.usage, usage);
		row.unpriced ||= model.unpriced;
		rows.set(model.key, row);
	}
	return [...rows].map(([key, { usage, unpriced }]) => {
		const slash = key.indexOf("/");
		const provider = key.slice(0, slash);
		const model = providers.models.getModel(provider, key.slice(slash + 1));
		const providerName = providers.models.getProvider(provider)?.name ?? provider;
		// Such a model can also answer conversations of its own, which have a row of their own: say what this one is for.
		return {
			key, input: usage.input, output: usage.output, tokens: usage.totalTokens, cost: usage.cost.total, unpriced,
			lookName: model === undefined ? `${key} · looking at pictures` : `${providerName} · ${model.name} · looking at pictures`,
		};
	});
}

let session: UsageDocShape = {};
async function updateUsage(): Promise<void> {
	const repriced = usagePricingChanged;
	if (usagePricingChanged) {
		usagePricingChanged = false;
		try {
			subscriptions = await providers.subscriptionProviders();
		} catch (error) {
			usagePricingChanged = true;
			throw error;
		}
		for (const entry of usageById.values()) entry.totals = usageTotals(entry.doc);
	}
	// Swap batches before reading so a revision published during the refresh is not lost.
	const batch = [...dirtyUsage];
	dirtyUsage.clear();
	try {
		for (const [id, pending] of batch) {
			const doc = pending === "read" ? await harness.snapshot(UsageDoc, id, context) : pending;
			if (doc === undefined || (Object.keys(doc.models ?? {}).length === 0 && Object.keys(doc.tools ?? {}).length === 0)) usageById.delete(id);
			else usageById.set(id, { doc, totals: usageTotals(doc) });
		}
	} catch (error) {
		for (const [id, pending] of batch) if (!dirtyUsage.has(id)) dirtyUsage.set(id, pending);
		throw error;
	}
	if (batch.length > 0) session = sessionUsage();
	const total = usageTotals(session);
	// Whatever was spent since the last look belongs to today.
	const day = dayKey();
	const spend = await harness.commit(async (tx) => {
		const doc = await tx.doc(Spend);
		const changed = repriced ? [...usageById.keys(), ...batch.map(([id]) => id)] : batch.map(([id]) => id);
		if (changed.length > 0) noteConversationSpend(doc, [...new Set(changed)].map((id) => [String(id), usageById.get(id)?.totals ?? noSpend()]), day);
		// The total only falls when usage stops being priced (a provider now on a subscription); take that back off today.
		const delta = { cost: total.cost - doc.lastCost, tokens: Math.max(0, total.tokens - doc.lastTokens) };
		if (delta.cost !== 0 || delta.tokens > 0) {
			// Create the day, then read it back: only the document's own copy records changes.
			doc.days[day] ??= { cost: 0, tokens: 0 };
			const today = doc.days[day]!;
			today.cost = Math.max(0, today.cost + delta.cost);
			today.tokens += delta.tokens;
			doc.lastCost = total.cost;
			doc.lastTokens = total.tokens;
		}
		// A plain copy: the document itself is only readable inside this commit.
		const projects = new Map<string, Amount>();
		for (const project of Object.values(allProjects())) if (project.deletedAt === undefined) projects.set(project.id, noSpend());
		if (projects.size > 0) for (const [id, meta] of Object.entries((await tx.doc(Library)).conversations)) {
			const sum = meta.projectId === undefined ? undefined : projects.get(meta.projectId);
			const used = doc.conversations?.[id];
			if (sum === undefined || used?.day !== day) continue;
			sum.cost += used.today.cost;
			sum.tokens += used.today.tokens;
		}
		return { days: JSON.parse(JSON.stringify(doc.days)) as Record<string, Amount>, projects: [...projects].map(([id, today]) => ({ id, today })) };
	}, context);
	const today = spend.days[day] ?? noSpend();
	todayCost = today.cost;

	const byAgent = new Map<string, { cost: number; tokens: number }>();
	// Chats are the built-in assistant's, not an agent's: counted on their own.
	const chats = { cost: 0, tokens: 0 };
	const byConversation: { id: number; title: string; cost: number; tokens: number; chat: boolean }[] = [];
	for (const [id, meta] of Object.entries(library.conversations)) {
		const usage = usageById.get(Number(id) as unknown as ConversationId)?.totals;
		if (usage === undefined || usage.tokens === 0) continue;
		const agent = isChat(meta) ? chats : (byAgent.get(meta.agentId ?? "") ?? { cost: 0, tokens: 0 });
		agent.cost += usage.cost;
		agent.tokens += usage.tokens;
		if (!isChat(meta)) byAgent.set(meta.agentId ?? "", agent);
		// A subagent's spend is shown under the conversation that started it.
		const root = meta.parent ?? Number(id);
		const row = byConversation.find((r) => r.id === root);
		if (row !== undefined) {
			row.cost += usage.cost;
			row.tokens += usage.tokens;
		} else if (!isPutAway(library.conversations[String(root)])) {
			byConversation.push({ id: root, title: library.conversations[String(root)]?.title ?? "", ...usage, chat: isChat(library.conversations[String(root)]) });
		}
	}
	usageSummary = {
		event: "usage",
		models: [
			...Object.entries(session.models ?? {}).map(([key, usage]) => ({ key, input: usage.input ?? 0, output: usage.output ?? 0, tokens: usage.totalTokens ?? 0, cost: costOf(key, usage), subscription: onSubscription(key), unpriced: unpriced(key) })),
			...pictureRows(session.tools),
			...lookRows(session.tools),
		].sort((x, y) => y.tokens - x.tokens),
		agents: [...byAgent].map(([agentId, usage]) => ({ agentId, ...usage })).sort((x, y) => y.tokens - x.tokens),
		chats,
		projects: spend.projects,
		conversations: byConversation.sort((x, y) => y.cost - x.cost || y.tokens - x.tokens).slice(0, 8),
		total,
		today,
		days: Object.entries(spend.days).sort(([x], [y]) => x.localeCompare(y)).slice(-14).map(([day, usage]) => ({ day, ...usage })),
		budget: { daily: settings.dailyBudget ?? null },
		overBudget: overBudget(),
	};
	broadcast(usageSummary);
	for (const feature of host.features) feature.usageChanged?.();
}
/** Batch nearby changes without putting the next count off indefinitely when requests keep finishing. */
export function scheduleUsageRefresh(): void {
	if (stopping() || usageTimer !== undefined) return;
	usageTimer = setTimeout(() => {
		usageTimer = undefined;
		void refreshUsage().catch((error) => log("usage refresh failed:", error));
	}, 400);
}
