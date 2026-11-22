// Compare Usage's live rollup with the durable ledgers scanned from scratch, with no engine running.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { BACKGROUND_CONTEXT as context } from "@earendil-works/chord/context";
import { createModels } from "@earendil-works/pi-ai";
import { createRegistry, Harness, UsageDoc, type ConversationId, type UsageState } from "@earendil-works/pi-durable";
import { openNodeSqliteStorage } from "@earendil-works/pi-durable/storage/sqlite/node";
import { EngineClient, standInApp, stop } from "./patience.ts";

// This test is about conversations in no project, made with the agents of no project: its engines carry nothing into
// projects (`PI2_CARRY_NEVER`, carryover.ts), as the last version with the switch never on did (#715).
process.env.PI2_CARRY_NEVER = "1";

const home = mkdtempSync(join(tmpdir(), "pi2-usage-"));
const price = 5;
const model = { provider: "demo", modelId: "demo-1" };
const key = "demo/demo-1";
const env = { ...process.env, PI2_HOME: home, PI2_KEYCHAIN_SERVICE: `dev.pi2.credentials.test-usage-${process.pid}`, PI2_LOGIN_SHELL: "off", PI2_DEMO_COST: String(price), PI2_DEMO_TOKENS_PER_SECOND: "100000", PI2_APP_BUNDLE: standInApp() };
const start = () => spawn(process.execPath, [join(import.meta.dirname, "../src/main.ts")], { env, stdio: ["ignore", "ignore", "inherit"] });
const cost = (tokens: number) => tokens * price / 1_000_000;
const count = (doc: Readonly<UsageState> | undefined) => {
	const tokens = doc?.models[key]?.totalTokens ?? 0;
	return { cost: cost(tokens), tokens };
};
const add = (a: ReturnType<typeof count>, b: ReturnType<typeof count>) => ({ cost: a.cost + b.cost, tokens: a.tokens + b.tokens });
const dayKey = (day: Date) => [day.getFullYear(), String(day.getMonth() + 1).padStart(2, "0"), String(day.getDate()).padStart(2, "0")].join("-");

let engine = start();
let client: EngineClient | undefined;
try {
	const socket = (client = await EngineClient.connect(engine, home));
	const create = async (params: Record<string, unknown> = {}): Promise<number> => {
		const { id } = await socket.call("conversation.create", { model, ...params });
		await socket.call("conversation.open", { id });
		return id;
	};
	const finished = (id: number, after: number) => socket.until(`work to finish in ${id}`, () => {
		const conv = socket.conversations.get(id);
		return !conv?.state.busy && conv?.items.length > after && conv.items.at(-1)?.kind === "assistant" ? conv : undefined;
	});
	const send = async (id: number, text: string) => {
		const before = socket.conversations.get(id)?.items.length ?? 0;
		await socket.call("submit", { id, text });
		return finished(id, before);
	};
	const parent = await create({ agentId: "atlas" });
	const archived = await create({ agentId: "forge" });
	const deleted = await create({ agentId: "forge" });
	const chat = await create({ chat: true });

	// Count a model request that called a tool without waiting for that tool, or the run, to finish.
	await socket.call("submit", { id: archived, text: "/ask Which colour?" });
	const question = await socket.until("the question", () => socket.events.inbox?.items.find((item: any) => item.conversationId === archived && item.kind === "question"));
	const whileWaiting = await socket.until("spend while the question is still waiting", () => socket.events.usage?.total.tokens > 0 && socket.events.usage);
	assert.equal(socket.conversations.get(archived).state.busy, true);
	assert.equal(whileWaiting.conversations[0].id, archived);
	await socket.call("inbox.answer", { id: question.id, text: "blue" });
	await finished(archived, 0);

	const [parentView] = await Promise.all([send(parent, "/delegate Scout: say hello"), send(deleted, "To be deleted"), send(chat, "A chat reply")]);
	const handoff = parentView.items.find((item: any) => item.kind === "tool" && item.details?.conversationId !== undefined);
	assert.equal(handoff.isError, false, handoff.text);
	assert.match(handoff.text, /Used: 1 request/);
	const child = handoff.details.conversationId as number;
	await socket.call("conversation.open", { id: child });
	await send(child, "Another request, this time to the sub-chat");
	await send(parent, "Another request to the parent too");
	const title = "Spend with a sub-chat";
	await socket.call("conversation.rename", { id: parent, title });

	const stateTokens = [parent, archived, deleted, chat, child].reduce((sum, id) => sum + socket.conversations.get(id).state.usage.tokens, 0);
	assert.ok(stateTokens > whileWaiting.total.tokens);
	const liveRows = () => socket.events.usage?.conversations as Array<{ id: number; title: string }> | undefined;
	await socket.until("totals caught up and rows shown", () => socket.events.usage?.total.tokens === stateTokens && liveRows()?.length === 4);
	await socket.call("conversation.archive", { id: archived });
	await socket.until("archived spend row hidden", () => liveRows()?.length === 3 && !liveRows()?.some((row) => row.id === archived));
	await socket.call("conversation.unarchive", { id: archived });
	await socket.until("restored spend row shown", () => liveRows()?.some((row) => row.id === archived));
	await socket.call("conversation.archive", { id: archived });
	await socket.call("conversation.delete", { id: deleted });
	await socket.until("only the parent and chat shown, with the updated title", () => liveRows()?.length === 2 && liveRows()?.some((row) => row.id === parent && row.title === title));
	const daily = 0.000001;
	await socket.call("usage.setBudget", { daily });
	const beforeBudget = dayKey(new Date());
	const live = await socket.until("budget set", () => socket.events.usage?.budget?.daily === daily && socket.events.usage);
	const liveDay = dayKey(new Date());
	assert.equal(live.overBudget, live.today.cost >= daily);
	if (beforeBudget === liveDay && live.overBudget) await assert.rejects(socket.call("submit", { id: parent, text: "Over budget" }), /budget/);
	client.close();
	await stop(engine);

	const storage = await openNodeSqliteStorage(join(home, "session.sqlite"));
	const harness = await Harness.open(storage, { registry: createRegistry(), models: createModels() }, context);
	try {
		const all = await harness.usage(context);
		const at = async (id: number) => count(await harness.snapshot(UsageDoc, id as unknown as ConversationId, context));
		const [p, a, d, c, s] = await Promise.all([at(parent), at(archived), at(deleted), at(chat), at(child)]);
		for (const each of [p, a, d, c, s]) assert.ok(each.tokens > 0);
		const total = count(all);
		assert.equal(total.tokens, stateTokens);
		assert.deepEqual(live.total, total);
		const demo = all.models[key]!;
		assert.deepEqual(live.models, [{ key, input: demo.input, output: demo.output, ...total, subscription: false, unpriced: false }]);
		assert.deepEqual(live.agents, [{ agentId: "atlas", ...p }, { agentId: "forge", ...add(a, d) }, { agentId: "scout", ...s }].sort((x, y) => y.tokens - x.tokens));
		assert.deepEqual(live.chats, c);
		assert.deepEqual(live.conversations, [
			{ id: parent, title, chat: false, ...add(p, s) },
			{ id: chat, title: "A chat reply", chat: true, ...c },
		].sort((x, y) => y.cost - x.cost || y.tokens - x.tokens));
		const spent = live.days.reduce((sum: ReturnType<typeof count>, day: ReturnType<typeof count>) => add(sum, day), { cost: 0, tokens: 0 });
		assert.equal(spent.tokens, total.tokens);
		assert.ok(Math.abs(spent.cost - total.cost) < 1e-9);
		if (live.days.length === 1 && live.days[0].day === liveDay && liveDay === beforeBudget) {
			assert.deepEqual(live.today, { cost: spent.cost, tokens: spent.tokens });
			assert.equal(live.overBudget, true);
		}
	} finally {
		await harness.close(context);
	}

	engine = start();
	client = await EngineClient.connect(engine, home);
	const after = await client.until("start-up usage", () => client!.events.usage);
	const { today, overBudget, ...rollup } = live;
	const { today: afterToday, overBudget: afterOverBudget, ...afterRollup } = after;
	assert.deepEqual(afterRollup, rollup, "start-up counts the same spend without charging any of it again");
	if (dayKey(new Date()) === liveDay) {
		assert.deepEqual(afterToday, today);
		assert.equal(afterOverBudget, overBudget);
		if (afterOverBudget) await assert.rejects(client.call("submit", { id: parent, text: "Over budget" }), /budget/);
	}
	console.log("ok  usage follows requests, keeps put-away spend, and agrees with a full recount across restart");
} finally {
	client?.close();
	await stop(engine);
	rmSync(home, { recursive: true, force: true });
}
