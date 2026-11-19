// Attribute the existing Usage ledger's per-conversation deltas to projects, including sub-chats and put-away work.
export type Amount = { cost: number; tokens: number };
export type DailySpend = { last: Amount; day: string; today: Amount };
export type SpendDoc = {
	days: Record<string, Amount>;
	lastCost: number;
	lastTokens: number;
	/** Per conversation (not project), so carrying a conversation over includes what it spent that day. */
	conversations?: Record<string, DailySpend>;
};
export const noSpend = (): Amount => ({ cost: 0, tokens: 0 });
export const dayKey = (at = new Date()) => `${at.getFullYear()}-${String(at.getMonth() + 1).padStart(2, "0")}-${String(at.getDate()).padStart(2, "0")}`;

export function conversationSpend(prior: DailySpend | undefined, total: Amount, day: string, seed: boolean = false): DailySpend {
	const previous = prior?.day === day ? prior.today : noSpend();
	const last = prior?.last ?? (seed ? total : noSpend());
	return { last: total, day, today: { cost: Math.max(0, previous.cost + (total.cost - last.cost)), tokens: previous.tokens + Math.max(0, total.tokens - last.tokens) } };
}

export function noteConversationSpend(doc: SpendDoc, usage: Iterable<[string, Amount]>, day: string): void {
	const seed = doc.conversations === undefined && (doc.lastCost !== 0 || doc.lastTokens !== 0);
	doc.conversations ??= {};
	for (const [id, total] of usage) {
		const prior = doc.conversations[id];
		if (prior?.last.cost === total.cost && prior.last.tokens === total.tokens) continue;
		doc.conversations[id] = conversationSpend(prior, total, day, seed);
	}
}
