// Opening a long conversation newest first (#380, src/opening.ts): how the parts are cut, then a real engine with the
// demo model and a conversation of long command outputs, opened by an app that asks for newest first and by one that
// does not, with a message sent while the older parts come, and closed and opened again while they come. Then the
// entries older than the engine's window of 300, which come a part at a time when the app asks (#440).

import assert from "node:assert/strict";
import { type ChildProcess, execFileSync, spawn } from "node:child_process";
import { mkdtempSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FIRST_BYTES, FIRST_COUNT, ItemJSON, OLDER_BYTES, olderPart, partStart } from "../src/opening.ts";
import { EngineClient, stop } from "./patience.ts";

function step(name: string): void {
	console.log(`ok  ${name}`);
}

// ---- How the parts are cut

{
	const items = (kinds: string) => [...kinds].map((k, id) => ({ id, kind: k === "u" ? "user" : k === "a" ? "assistant" : "tool" }));
	const each = (bytes: number) => () => bytes;
	// Ten bytes each: the newest that come to 30 bytes.
	assert.equal(partStart(items("uauauaua"), each(10), 30), 5);
	// The count is reached first.
	assert.equal(partStart(items("uauauaua"), each(1), 1000, 3), 5);
	// One entry larger than the whole budget still goes, alone.
	assert.equal(partStart(items("uaua"), each(1000), 30), 3);
	// A part does not start with a tool result: it reaches back over the other results to the answer that called them.
	assert.equal(partStart(items("uattttua"), each(10), 50), 1);
	assert.equal(partStart(items("ttta"), each(10), 20), 0, "results with no answer before them go to the start");
	// A part that ends before the end, as the later parts do.
	assert.equal(partStart(items("uauauaua"), each(10), 20, Infinity, 4), 2);
	assert.equal(partStart([], each(10), 20), 0);
	step("a part is the newest entries up to a size or a count, at least one, never starting at a tool result");

	const json = new ItemJSON<object>();
	const list = [{ id: 1, text: "a \"quoted\"\nline" }, { id: 2, text: "é" }];
	const line = json.line({ event: "conversation.older", id: 7, earlier: 0 }, list);
	assert.deepEqual(JSON.parse(line), { event: "conversation.older", id: 7, earlier: 0, items: list });
	assert.deepEqual(JSON.parse(json.line({}, [])), { items: [] });
	assert.equal(json.size(list[0]!), JSON.stringify(list[0]).length);
	step("an event line made of each item's JSON reads back as the event");
}

// ---- How a part older than the window is read (#440)

{
	// Entries 1 to 12, newest first in pages of 5, as Conversation.entries gives them from entry 12 down. Entry 9 shows as
	// nothing; 6 and 7 are the results of 5's calls.
	const kinds: Record<number, string> = { 1: "user", 2: "assistant", 3: "user", 4: "user", 5: "assistant", 6: "tool", 7: "tool", 8: "user", 9: "none", 10: "assistant", 11: "user", 12: "assistant" };
	const pages = (from: number) => {
		const reads: number[] = [];
		const read = async (cursor: number | undefined) => {
			const start = cursor ?? from;
			reads.push(start);
			const ids = Array.from({ length: Math.min(5, start) }, (_, i) => start - i);
			return { items: ids.map((id) => ({ id })), next: start - 5 > 0 ? start - 5 : undefined };
		};
		return { read, reads };
	};
	const toItem = ({ id }: { id: number }) => (kinds[id] === "none" ? undefined : { id, kind: kinds[id]! });
	const ten = () => 10;

	let { read, reads } = pages(12);
	let part = await olderPart(read, toItem, ten, 30);
	assert.deepEqual(part.items.map((item) => item.id), [10, 11, 12], "30 bytes: three items, passing over the one that shows as nothing");
	assert.equal(part.next, 9, "read on from the newest entry not taken");
	assert.deepEqual(reads, [12], "no more read than needed");

	// From 9: 8, 7 and 6 come to 30 bytes, but a part does not start with a tool result: it takes 5, which called them.
	({ read, reads } = pages(9));
	part = await olderPart(read, toItem, ten, 30);
	assert.deepEqual(part.items.map((item) => item.id), [5, 6, 7, 8]);
	assert.equal(part.next, 4);
	assert.deepEqual(reads, [9, 4], "read on into the next page");

	// The rest, to the start of the conversation: nothing older.
	({ read } = pages(4));
	part = await olderPart(read, toItem, ten, 1000);
	assert.deepEqual(part.items.map((item) => item.id), [1, 2, 3, 4]);
	assert.equal(part.next, undefined);

	// One entry larger than the budget still comes, alone; and a scan with nothing in it gives nothing.
	({ read } = pages(12));
	assert.deepEqual((await olderPart(read, toItem, () => 1000, 30)).items.map((item) => item.id), [12]);
	assert.deepEqual(await olderPart(async () => ({ items: [] }), toItem, ten, 30), { items: [], next: undefined });
	step("a part older than the window is the entries before it up to a size, at least one, never starting at a tool result");
}

// ---- A real engine

const home = mkdtempSync(join(tmpdir(), "pi2-opening-"));
const scratch = realpathSync(mkdtempSync(join(tmpdir(), "pi2-opening-work-")));
const main = join(import.meta.dirname, "..", "src", "main.ts");
const KEYCHAIN_SERVICE = `dev.pi2.credentials.test-opening-${process.pid}`;
process.env.PI2_LOGIN_SHELL ??= "off";
// The chat below has 160 answers to write.
process.env.PI2_DEMO_TOKENS_PER_SECOND ??= "100000";
const env = { ...process.env, PI2_HOME: home, PI2_KEYCHAIN_SERVICE: KEYCHAIN_SERVICE };

let engine: ChildProcess | undefined;
process.on("exit", () => {
	if (engine !== undefined && engine.exitCode === null && engine.signalCode === null) engine.kill("SIGKILL");
	rmSync(home, { recursive: true, force: true });
	rmSync(scratch, { recursive: true, force: true });
	if (process.platform !== "darwin") return;
	try {
		while (true) execFileSync("/usr/bin/security", ["delete-generic-password", "-s", KEYCHAIN_SERVICE], { stdio: "ignore" });
	} catch {
		// None left.
	}
});

type Item = { id: number; kind: string };
type Event = { event: string; id: number; reset?: boolean; items: Item[]; earlier?: number; bytes: number };

/** A client that keeps every event about conversations in order, and the list they make, as the app would. */
class Recorder extends EngineClient {
	log: Event[] = [];
	list: Item[] = [];
	earlier = 0;
	onEvent: (event: Event) => void = () => {};

	override receive(message: any): void {
		super.receive(message);
		if (message.event !== "conversation" && message.event !== "conversation.older") return;
		const event = { ...message, bytes: JSON.stringify(message).length } as Event;
		this.log.push(event);
		if (message.event === "conversation") {
			if (message.reset) this.list = [];
			this.list.push(...message.items);
			if (message.reset) this.earlier = message.earlier ?? 0;
		} else {
			assert.ok(this.list.length === 0 || message.items.length === 0 || message.items.at(-1).id < this.list[0]!.id, "older entries come before those the app has");
			this.list.unshift(...message.items);
			this.earlier = message.earlier;
		}
		this.onEvent(event);
	}
}

engine = spawn(process.execPath, [main], { env, stdio: ["ignore", "ignore", "inherit"] });
const clients: EngineClient[] = [];
const connect = async () => {
	const client = await Recorder.connect(engine!, home);
	clients.push(client);
	return client;
};
try {
	const maker = await connect();
	const { id } = await maker.call("conversation.create", { model: { provider: "demo", modelId: "demo-1" } });
	await maker.call("conversation.configure", { id, access: "full", cwd: scratch });
	await maker.call("conversation.open", { id });
	// First many short entries, which the engine's window of 300 leaves out once the long ones come (#440).
	// Each turn short enough that summarising the context never leaves out the message that set the work.
	for (let round = 0; round < 5; round++) {
		await maker.call("submit", { id, text: "/work 50 100000 seq 1 400" });
		await maker.until("the short work to end", () => {
			const last = maker.list.at(-1) as (Item & { toolCalls?: unknown[]; text?: string }) | undefined;
			return !maker.conversations.get(id)?.state.busy && last?.kind === "assistant" && last.toolCalls?.length === 0 && maker.list.length > 101 * round;
		});
	}
	// Long command outputs, about 9 KB each, until the window holds more than the first part and two later ones.
	for (let round = 0; round < 12; round++) {
		await maker.call("submit", { id, text: "/work 8 100000 seq 1 2000" });
		await maker.until("the work to end", () => {
			const conv = maker.conversations.get(id);
			const last = conv?.items.at(-1);
			return conv !== undefined && !conv.state.busy && last?.kind === "assistant" && last.toolCalls.length === 0;
		});
		if (JSON.stringify(maker.conversations.get(id).items.slice(-300)).length > FIRST_BYTES + 2 * OLDER_BYTES) break;
	}
	await maker.call("conversation.close", { id });
	// The maker had the conversation open while it grew, so it was sent every entry.
	const everything = maker.list.map((item) => item.id);
	assert.ok(everything.length > 400, `the conversation is longer than the engine's window (${everything.length} entries)`);

	// An app that does not ask gets it all in one event, as before.
	const plain = await connect();
	await plain.call("conversation.open", { id });
	const whole = plain.log[0]!;
	assert.equal(whole.event, "conversation");
	assert.ok(whole.reset);
	assert.equal(whole.earlier, undefined, "an older app is told of nothing still to come");
	assert.equal((whole as { more?: unknown }).more, undefined, "nor of anything older");
	const all = whole.items.map((item) => item.id);
	assert.ok(all.length <= 300 && all.length < everything.length, "it is the window, not every entry");
	assert.deepEqual(everything.slice(-all.length), all);
	assert.ok(whole.bytes > FIRST_BYTES + 2 * OLDER_BYTES, `the conversation is long enough to come in parts (${whole.bytes} bytes)`);
	step(`without newestFirst, ${all.length} entries come in one event of ${Math.round(whole.bytes / 1024)} KB`);

	// An app that asks gets the newest first, then the rest, newest first, each part before the one it has.
	const app = await connect();
	await app.call("conversation.open", { id, newestFirst: true });
	await app.until("every older part", () => app.earlier === 0 && app.log.length > 1);
	const [first, ...rest] = app.log;
	assert.equal(first!.event, "conversation");
	assert.ok(first!.reset);
	assert.ok(first!.items.length <= FIRST_COUNT, "at most the first part's count");
	assert.ok(first!.items.length >= 1);
	assert.notEqual(first!.items[0]!.kind, "tool", "the first part does not start with a tool result");
	assert.equal(first!.earlier, all.length - first!.items.length, "the first event says how many are still to come");
	const firstBytes = JSON.stringify(first!.items).length;
	assert.ok(firstBytes < FIRST_BYTES + 20 * 1024, `the first part is about ${FIRST_BYTES} bytes at most (${firstBytes})`);
	assert.ok(rest.length >= 2, "the rest comes in several parts");
	for (const event of rest) {
		assert.equal(event.event, "conversation.older");
		// The window itself can start with tool results, whose answer is older than it (#440).
		if (event.earlier !== 0) assert.notEqual(event.items[0]!.kind, "tool");
		assert.ok(JSON.stringify(event.items).length < OLDER_BYTES + 20 * 1024, "each later part is about its size at most");
	}
	assert.deepEqual(rest.map((event) => event.earlier), rest.map((_, i) => all.length - first!.items.length - rest.slice(0, i + 1).reduce((sum, e) => sum + e.items.length, 0)));
	assert.deepEqual(app.list.map((item) => item.id), all, "the parts make the same list");
	assert.equal((first as { more?: unknown }).more, true, "the first event says there are entries older than the window");
	step(`with newestFirst, ${first!.items.length} entries (${Math.round(first!.bytes / 1024)} KB) come first, then ${rest.length} older parts`);

	// Older than the window: a part each time the app asks, until there is nothing older (#440).
	const asked = app.log.length;
	let answer: { more: boolean };
	let requests = 0;
	do {
		const before = app.log.length;
		answer = await app.call("conversation.older", { id });
		requests++;
		const sent = app.log.slice(before);
		assert.equal(sent.length, 1, "one part a request, sent before the answer");
		const part = sent[0]! as Event & { more?: boolean };
		assert.equal(part.event, "conversation.older");
		assert.equal(part.earlier, 0);
		assert.equal(part.more, answer.more, "the event and the answer agree on whether there is more");
		assert.ok(part.items.length >= 1);
		assert.notEqual(part.items[0]!.kind, "tool", "a part does not start with a tool result");
		assert.ok(JSON.stringify(part.items).length < OLDER_BYTES + 20 * 1024, "each part is about its size at most");
	} while (answer.more);
	assert.deepEqual(app.list.map((item) => item.id), everything, "the parts make every entry, in order, once");
	assert.ok(requests >= 2, `the entries older than the window came in several parts (${requests})`);
	const none = app.log.length;
	assert.deepEqual(await app.call("conversation.older", { id }), { more: false });
	assert.equal(app.log.length, none, "nothing is sent once there is nothing older");
	assert.ok(app.log.slice(asked).every((event) => event.event === "conversation.older"));
	await assert.rejects(plain.call("conversation.older", { id: id + 1000 }), /not open/);
	step(`entries older than the window come when asked, in ${requests} parts, until there are none`);

	// A message sent while the older parts come arrives at the end as usual, and the parts still go before.
	await app.call("conversation.close", { id });
	const busy = await connect();
	let sent = false;
	busy.onEvent = (event) => {
		if (sent || event.event !== "conversation" || !event.reset) return;
		sent = true;
		void busy.call("submit", { id, text: "Hello" });
	};
	await busy.call("conversation.open", { id, newestFirst: true });
	const after = await busy.until("the answer, and every older part", () => {
		const last = busy.list.at(-1) as (Item & { text?: string }) | undefined;
		return busy.earlier === 0 && last?.kind === "assistant" && /^You said: "Hello"/.test(last.text ?? "") && !busy.conversations.get(id)?.state.busy ? busy.list : undefined;
	});
	const ids = after.map((item) => item.id);
	assert.deepEqual(ids.slice(0, all.length), all, "the older entries are all there, in order");
	assert.ok(ids.length > all.length && ids.slice(all.length).every((value, i, list) => i === 0 || value > list[i - 1]!), "and the new ones after them");
	step("an entry arriving while the older parts come goes at the end, and they before");

	// Closed and opened again while the older parts come: nothing of the first list follows the new start.
	await busy.call("conversation.close", { id });
	const again = await connect();
	let reopened = false;
	again.onEvent = (event) => {
		if (reopened || event.event !== "conversation" || !event.reset) return;
		reopened = true;
		void again.call("conversation.close", { id }).then(() => again.call("conversation.open", { id, newestFirst: true }));
	};
	await again.call("conversation.open", { id, newestFirst: true });
	await again.until("the second opening's parts", () => again.log.filter((event) => event.reset).length === 2 && again.earlier === 0);
	const second = again.log.findLastIndex((event) => event.reset);
	assert.ok(again.log.slice(second + 1).every((event) => event.event === "conversation.older"));
	// The window is the newest 300 entries again, so it starts after the two the message added.
	const reopenedIds = again.list.map((item) => item.id);
	assert.deepEqual(reopenedIds, ids.slice(ids.length - reopenedIds.length), "the second opening's parts make the whole list, once");
	assert.ok(reopenedIds.length >= all.length, "the whole window");
	step("closing stops the older parts; opening again starts them over");

	await assert.rejects(again.call("conversation.open", { id, newestFirst: "yes" }), /newestFirst must be true or false/);
	step("newestFirst is true or false");

	// A chat's version reads its own history, with what it shares with the version it was made from (#440).
	const chatter = await connect();
	const { id: chat } = await chatter.call("conversation.create", { chat: true, model: { provider: "demo", modelId: "demo-1" } });
	await chatter.call("conversation.open", { id: chat, newestFirst: true });
	const said = (n: number | string) => () => {
		const last = (chatter.list as (Item & { text?: string })[]).findLast((item) => item.kind === "assistant");
		return (last?.text ?? "").includes(`You said: "message ${n}"`) && !chatter.conversations.get(chat)?.state.busy;
	};
	for (let n = 1; n <= 160; n++) {
		await chatter.call("submit", { id: chat, text: `message ${n}` });
		await chatter.until(`the answer to message ${n}`, said(n));
	}
	const original = chatter.list.map((item) => item.id);
	const last = (chatter.list as (Item & { text?: string })[]).findLast((item) => item.kind === "user")!;
	assert.equal(last.text, "message 160");
	const resets = chatter.log.filter((event) => event.reset).length;
	await chatter.call("conversation.edit", { id: chat, entryId: last.id, text: "message 160, edited" });
	await chatter.until("the edited message answered, in its own version", () => chatter.log.filter((event) => event.reset).length > resets && chatter.earlier === 0 && said("160, edited")());
	const start = chatter.log.findLast((event) => event.reset)! as Event & { more?: boolean };
	assert.equal(start.more, true, "the version has entries older than its window");
	const ownWindow = chatter.list.map((item) => item.id);
	assert.ok(ownWindow.length < original.length && ownWindow[0]! < last.id, `its window reaches into what it shares (${ownWindow.length} entries from ${ownWindow[0]}, the edited message ${last.id})`);
	let more = true;
	while (more) ({ more } = await chatter.call("conversation.older", { id: chat }));
	const version = chatter.list.map((item) => item.id);
	const shared = original.slice(0, original.indexOf(last.id));
	assert.deepEqual(version.slice(0, shared.length), shared, "its older entries are those it shares, from the first message");
	assert.deepEqual(version.slice(shared.length), ownWindow.slice(ownWindow.indexOf(version[shared.length]!)), "then its own");
	assert.ok(!version.includes(last.id), "and none of the version it was made from after the point they part");
	step(`a chat's version of ${version.length} entries pages back through the history it shares`);
} finally {
	for (const client of clients) client.close();
	await stop(engine);
}
