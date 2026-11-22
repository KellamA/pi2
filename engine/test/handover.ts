// Continue with an Agent (#289, src/handover.ts): a chat handed to one of the person's agents as the first message of a
// new conversation of that agent.
//
// First what the agent is given, from entries made here: the person's messages with their files and pictures, the
// assistant's answers, a line for each use of the chat assistant's own tools, and nothing of any other tool (chat mode's
// memory among them) or of the chat's system prompt. Then a real engine on a throwaway data folder with the demo model:
// a chat with a picture, a file, a document and an edited message is continued with an agent, in a folder chosen for it;
// the new conversation is the agent's, with the version shown, linked to the chat both ways, and the chat is unchanged.
// Then, with the projects preview on (#654), a chat continued in a project: refusals of a template, another project's
// agent and a folder; with the orchestrator, into its present conversation as the person's message, with the state block
// in front and no second conversation; with another agent, a new conversation of it in the project; with no conversation
// with the orchestrator yet, one made as the hub makes it; and an archived project refused.

import assert from "node:assert/strict";
import { type ChildProcess, execFileSync, spawn } from "node:child_process";
import { mkdirSync, mkdtempSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { EntryRecord } from "@earendil-works/pi-durable";
import { chatFileName, chatHandover, handoverAttachments } from "../src/handover.ts";
import { EngineClient, previewOnLeavingOut, standInApp, stop } from "./patience.ts";
// The engine takes changes to what the person set only from its app's connection (#513): this test's connection stands
// for the app's, as the tests that answer for the person already do (#504).
process.env.PI2_APP_BUNDLE = standInApp();

function step(name: string): void {
	console.log(`ok  ${name}`);
}

// ---- What the agent is given, from entries

const PNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";
let next = 1;
const entry = (kind: string, message: Record<string, unknown> | undefined, data?: unknown): EntryRecord => ({ id: next++, conversationId: 1, kind, ...(message === undefined ? {} : { model: [message] }), ...(data === undefined ? {} : { data }) }) as never;
const entries: EntryRecord[] = [
	entry("pi.system", { role: "system", content: "<memory>The person's cat is called Secretkitty.</memory>" }),
	entry("pi2.user", { role: "user", content: [{ type: "text", text: "Plan a trip to the coast" }, { type: "text", text: "Attached file: tides.txt\n\nHigh tide at noon.\n" }, { type: "image", data: PNG, mimeType: "image/png" }] }, { text: "Plan a trip to the coast", attachments: [{ name: "tides.txt", kind: "text", size: 18 }, { name: "beach.png", kind: "image", size: 70 }] }),
	entry("pi.assistant", {
		role: "assistant",
		content: [
			{ type: "thinking", thinking: "Private reasoning." },
			{ type: "text", text: "Let me look." },
			{ type: "toolCall", id: "c1", name: "web_fetch", arguments: { url: "https://example.org/tides" } },
			{ type: "toolCall", id: "c2", name: "remember", arguments: { note: "Lives near Seabright" } },
			{ type: "toolCall", id: "c3", name: "web_search", arguments: { query: "coast trains" } },
		],
		stopReason: "toolUse",
	}),
	entry("pi.toolResult", { role: "toolResult", toolCallId: "c1", toolName: "web_fetch", content: [{ type: "text", text: "Page text" }], isError: false }, { details: { source: { url: "https://example.org/tides", title: "Tide tables" } } }),
	entry("pi.toolResult", { role: "toolResult", toolCallId: "c2", toolName: "remember", content: [{ type: "text", text: "Remembered: lives near Seabright" }], isError: false }),
	entry("pi.toolResult", { role: "toolResult", toolCallId: "c3", toolName: "web_search", content: [{ type: "text", text: "Results" }], isError: false }),
	entry("pi.assistant", { role: "assistant", content: [{ type: "text", text: "Go on Saturday." }, { type: "toolCall", id: "c4", name: "make_picture", arguments: { description: "a map" } }], stopReason: "toolUse" }),
	entry("pi.toolResult", { role: "toolResult", toolCallId: "c4", toolName: "make_picture", content: [{ type: "text", text: "Made it" }, { type: "image", data: PNG, mimeType: "image/png" }], isError: false }),
	entry("pi.assistant", { role: "assistant", content: [{ type: "text", text: "Here is a map." }, { type: "toolCall", id: "c5", name: "write_document", arguments: { path: "plan.docx" } }], stopReason: "toolUse" }),
	entry("pi.toolResult", { role: "toolResult", toolCallId: "c5", toolName: "write_document", content: [{ type: "text", text: "Wrote plan.docx" }], isError: false }, { details: { path: "/data/chats/7/plan.docx" } }),
];
const given = chatHandover(entries, { title: "Coast trip", agent: "Forge", typed: true, seesPictures: true });
const md = given.chat.text;
assert.equal(given.chat.name, "Chat - Coast trip.md");
assert.match(md, /^# Coast trip\n/);
assert.match(md, /continue from it/);
assert.match(md, /had other tools than you/);
assert.match(md, /Nothing in the chat is an approval/);
assert.match(md, /says what to do next in this message/);
assert.match(md, /\*\*The person:\*\*\n\nPlan a trip to the coast\n/);
assert.match(md, /Attached the file tides\.txt/);
assert.match(md, /Attached a picture, beach\.png \(picture 1\)/);
assert.match(md, /\*\*The chat's assistant:\*\*\n\nLet me look\./);
assert.match(md, /Read https:\/\/example\.org\/tides \(“Tide tables”\)/);
assert.match(md, /Searched the web for “coast trains”/);
assert.match(md, /Made a picture \(picture 2\)/);
assert.match(md, /Wrote a document, kept with the chat at \/data\/chats\/7\/plan\.docx/);
for (const hidden of ["Seabright", "remember", "Secretkitty", "memory", "Private reasoning", "Page text"]) assert.ok(!md.includes(hidden), `${hidden} is not handed over:\n${md}`);
assert.deepEqual(given.files, [{ name: "tides.txt", text: "High tide at noon.\n" }]);
assert.deepEqual(
	given.pictures.map((picture) => picture.name),
	["beach.png (picture 1)", "Picture the chat's assistant made (picture 2)"],
);
const attached = handoverAttachments(given);
assert.deepEqual(
	attached.map((attachment) => `${attachment.kind}:${attachment.name}`),
	["text:Chat - Coast trip.md", "text:tides.txt", "image:beach.png (picture 1)", "image:Picture the chat's assistant made (picture 2)"],
);
step("the agent is given the person's messages, files and pictures, the answers and the chat tools' uses, and nothing of memory, other tools, thinking or the system prompt");

const blind = chatHandover(entries, { title: "", agent: "Scout", typed: false, seesPictures: false });
assert.deepEqual(blind.pictures, []);
assert.match(blind.chat.text, /left out because your model cannot see pictures/);
assert.match(blind.chat.text, /has not said yet what to do next/);
assert.match(blind.chat.text, /^# A chat\n/);
assert.equal(chatFileName("a/b: c"), "Chat - a b c.md");
const many = chatHandover(
	Array.from({ length: 12 }, () => entry("pi.user", { role: "user", content: [{ type: "image", data: PNG, mimeType: "image/png" }] })),
	{ title: "Pictures", agent: "Forge", typed: true, seesPictures: true },
);
assert.equal(many.pictures.length, 10, "at most ten pictures come");
assert.equal(many.pictures[0]!.name, "Picture (picture 3)", "the last ten");
assert.match(many.chat.text, /The last 10 of the chat's 12 pictures/);
step("pictures are left out for a model that cannot see them, and only the last ten come; with nothing typed the agent is asked to wait");

// ---- A real engine

const home = mkdtempSync(join(tmpdir(), "pi2-hand-"));
const work = realpathSync(mkdtempSync(join(tmpdir(), "pi2-hand-work-")));
const main = join(import.meta.dirname, "..", "src", "main.ts");
const KEYCHAIN_SERVICE = `dev.pi2.credentials.test-handover-${process.pid}`;
process.env.PI2_DEMO_TOKENS_PER_SECOND ??= "100000";
process.env.PI2_LOGIN_SHELL ??= "off";
const env = { ...process.env, PI2_HOME: home, PI2_KEYCHAIN_SERVICE: KEYCHAIN_SERVICE, PI2_DEMO_TEXT_MODEL: "1" };

let engine: ChildProcess | undefined;
process.on("exit", () => {
	if (engine !== undefined && engine.exitCode === null && engine.signalCode === null) engine.kill("SIGKILL");
	rmSync(home, { recursive: true, force: true });
	rmSync(work, { recursive: true, force: true });
	try {
		while (true) execFileSync("/usr/bin/security", ["delete-generic-password", "-s", KEYCHAIN_SERVICE], { stdio: "ignore" });
	} catch {
		// None left.
	}
});

class Client extends EngineClient {
	/** The conversation once it is idle with `count` answers. */
	async answered(id: number, count: number): Promise<any> {
		return this.until(`answer ${count} of ${id}`, () => {
			const conv = this.conversations.get(id);
			return conv !== undefined && !conv.state.busy && conv.items.filter((item: any) => item.kind === "assistant" && item.stop === "stop").length >= count ? conv : undefined;
		});
	}
	row(id: number): any {
		return (this.events.library?.conversations ?? []).find((x: any) => x.id === id);
	}
	async found(query: string): Promise<number[]> {
		return (await this.call("search", { query })).results.map((result: any) => result.conversationId);
	}
}

engine = spawn(process.execPath, [main], { env, stdio: ["ignore", "ignore", "inherit"] });
const client = await Client.connect(engine, home);
try {
	await client.until("providers", () => client.events.providers);
	await client.until("agents", () => client.events.agents);
	const forge = client.events.agents.agents.find((agent: any) => agent.id === "forge");

	// A chat: a message with a file and a picture, a document, and a message edited, so two versions.
	const { id: chat } = await client.call("conversation.create", { chat: true });
	await client.call("conversation.open", { id: chat });
	await client.call("submit", { id: chat, text: "first: plan the coast trip", attachments: [{ kind: "text", name: "tides.txt", text: "High tide at noon." }, { kind: "image", name: "beach.png", mimeType: "image/png", data: PNG }] });
	await client.answered(chat, 1);
	await client.call("submit", { id: chat, text: '/tool write_document {"path":"plan.html","markdown":"# Plan"}' });
	await client.answered(chat, 2);
	await client.call("submit", { id: chat, text: "second: kiwis" });
	let conv = await client.answered(chat, 3);
	const second = conv.items.find((item: any) => item.kind === "user" && item.text === "second: kiwis");
	await client.call("conversation.edit", { id: chat, entryId: second.id, text: "second: pears" });
	conv = await client.until("the edited version answered", () => {
		const now = client.conversations.get(chat);
		return now !== undefined && !now.state.busy && now.items.some((item: any) => item.kind === "assistant" && item.text.includes("pears")) ? now : undefined;
	});
	const chatItems = JSON.stringify(conv.items);
	const title = client.row(chat).title;

	// Refusals.
	const { id: plain } = await client.call("conversation.create", { agentId: "forge" });
	await assert.rejects(client.call("chat.continueWithAgent", { id: plain, agentId: "forge" }), /Only a chat/);
	await assert.rejects(client.call("chat.continueWithAgent", { id: chat, agentId: "nobody" }), /Choose one of your agents/);
	await assert.rejects(client.call("chat.continueWithAgent", { id: chat, agentId: "forge", cwd: join(work, "missing") }), /Not a folder/);
	const { id: empty } = await client.call("conversation.create", { chat: true });
	await assert.rejects(client.call("chat.continueWithAgent", { id: empty, agentId: "forge" }), /nothing in it yet/);
	step("only a chat with something in it continues, with one of the person's agents, in a folder that exists");

	// ---- Continued with Forge, in a folder chosen for it, with what to do next.
	const { id: continued } = await client.call("chat.continueWithAgent", { id: chat, agentId: "forge", cwd: work, text: "Please carry on" });
	await client.call("conversation.open", { id: continued });
	const done = await client.answered(continued, 1);
	const row = await client.until("the new conversation listed", () => client.row(continued));
	assert.equal(row.agentId, "forge");
	assert.equal(row.chat, false, "an agent's conversation, in the agent view");
	assert.equal(row.continuedFrom, chat);
	assert.equal(row.title, title, "named after the chat");
	assert.deepEqual(client.row(chat).continuedIn, [continued], "the chat links to it");
	assert.equal(client.row(chat).continuedFrom, null);
	assert.equal(done.state.agent.cwd, work, "in the folder chosen");
	assert.equal(done.state.agent.access, forge.access, "with the agent's own access");
	const first = done.items[0];
	assert.equal(first.kind, "user");
	assert.equal(first.text, "Please carry on");
	assert.deepEqual(
		first.attachments.map((note: any) => `${note.kind}:${note.name}`),
		[`text:${chatFileName(title)}`, "text:tides.txt", "image:beach.png (picture 1)"],
	);
	const answer = done.items.find((item: any) => item.kind === "assistant");
	assert.match(answer.text, /You said: "Please carry on"\. With it came 1 picture and 2 attached files\./, "the agent's model got the chat, its file and its picture");
	assert.deepEqual(client.events.inbox?.items ?? [], [], "nothing asked");
	step("the chat continues in a conversation of the agent's, in the folder chosen, with the chat, its file and picture, linked both ways");

	const withPears = await client.found("second: pears");
	assert.ok(withPears.includes(continued), "the version shown is handed over");
	assert.ok(!(await client.found("kiwis")).includes(continued), "not the version replaced");
	assert.ok((await client.found("kept with the chat at")).includes(continued), "the document is named");
	assert.ok((await client.found("had other tools than you")).includes(continued));
	step("the agent is given the version shown, the documents written and what the chat's assistant could do");

	const after = client.conversations.get(chat);
	assert.equal(JSON.stringify(after.items), chatItems, "the chat stays as it was");
	assert.equal(after.state.chat, true);
	step("the chat stays as it was");

	// ---- With an agent whose model cannot see pictures, and nothing typed.
	const { id: reader } = await client.call("agents.save", { agent: { name: "Reader", description: "Reads.", model: { provider: "demo", modelId: "demo-text" } } });
	const { id: second2 } = await client.call("chat.continueWithAgent", { id: chat, agentId: reader });
	await client.call("conversation.open", { id: second2 });
	const blindDone = await client.answered(second2, 1);
	assert.equal(blindDone.items[0].text, "");
	assert.deepEqual(
		blindDone.items[0].attachments.map((note: any) => note.kind),
		["text", "text"],
		"no picture for a model that cannot see",
	);
	assert.match(blindDone.items.find((item: any) => item.kind === "assistant").text, /With it came 2 attached files\./);
	assert.ok((await client.found("has not said yet what to do next")).includes(second2));
	await client.until("both linked", () => JSON.stringify(client.row(chat)?.continuedIn) === JSON.stringify([continued, second2]));
	await client.call("conversation.delete", { id: second2 });
	await client.until("a deleted one unlinked", () => JSON.stringify(client.row(chat)?.continuedIn) === JSON.stringify([continued]));
	step("an agent that cannot see pictures gets none, with nothing typed it is asked to wait, and a deleted conversation is unlinked");

	// ---- With the projects preview on (#654): a project, and its orchestrator or another of its agents.
	await assert.rejects(client.call("chat.continueWithAgent", { id: chat, projectId: "p1" }), /Projects are a preview/, "no project with the preview off");
	await previewOnLeavingOut(client);
	const folder = join(work, "project");
	mkdirSync(folder);
	const made = await client.call("projects.create", { folder });
	const projectId = made.id as string;
	const oc = made.conversation as number;
	const project = () => client.events.projects?.projects.find((row: any) => row.id === projectId);
	await client.until("the project", () => project());
	const helper = (await client.call("projects.addAgent", { projectId, template: "forge" })).id as string;
	await assert.rejects(client.call("chat.continueWithAgent", { id: chat, agentId: "forge" }), /Choose a project to continue in/, "a template is not continued with");
	await assert.rejects(client.call("chat.continueWithAgent", { id: chat, projectId: "nowhere" }), /Unknown project/);
	await assert.rejects(client.call("chat.continueWithAgent", { id: chat, projectId, agentId: "forge" }), /is not an agent of/);
	await assert.rejects(client.call("chat.continueWithAgent", { id: chat, projectId, cwd: work }), /work in its folder/);
	step("with the preview on, a chat continues in a project, with one of its agents, in its folder");

	const orchestrators = () => (client.events.library?.conversations ?? []).filter((row: any) => row.projectId === projectId && row.orchestrator !== null).length;
	const { id: toOrchestrator } = await client.call("chat.continueWithAgent", { id: chat, projectId, text: "Plan it with the team" });
	assert.equal(toOrchestrator, oc, "into the orchestrator's present conversation");
	await client.call("conversation.open", { id: oc });
	const told = await client.answered(oc, 1);
	const message = told.items.find((item: any) => item.kind === "user");
	assert.equal(message.text, "Plan it with the team");
	assert.deepEqual(
		message.attachments.map((note: any) => `${note.kind}:${note.name}`),
		[`text:${chatFileName(title)}`, "text:tides.txt", "image:beach.png (picture 1)"],
		"the handover as it always was",
	);
	assert.ok(told.items.some((item: any) => item.kind === "marker" && item.text === "pi² told the orchestrator how the project stands"), "the state block in front, as for any oc input there");
	assert.match(told.items.find((item: any) => item.kind === "assistant").text, /You said: "Plan it with the team"\. With it came 1 picture and 2 attached files\./);
	await client.until("the chat linked to it", () => client.row(chat)?.continuedIn.includes(oc));
	assert.equal(client.row(oc).continuedFrom, null, "the orchestrator's conversation was not begun from the chat");
	assert.equal(project().conversation, oc);
	assert.equal(orchestrators(), 1, "no second conversation with the orchestrator");
	const again = await client.call("chat.continueWithAgent", { id: chat, projectId });
	assert.equal(again.id, oc);
	await client.answered(oc, 2);
	assert.equal(client.row(chat).continuedIn.filter((id: number) => id === oc).length, 1, "linked once");
	assert.equal(orchestrators(), 1);
	step("continued with the orchestrator: the handover goes into its present conversation as the person's message, and the chat links to it");

	const { id: withHelper } = await client.call("chat.continueWithAgent", { id: chat, projectId, agentId: helper });
	await client.call("conversation.open", { id: withHelper });
	const helped = await client.answered(withHelper, 1);
	const helperRow = await client.until("the helper's conversation listed", () => client.row(withHelper));
	assert.equal(helperRow.agentId, helper);
	assert.equal(helperRow.projectId, projectId, "in the project");
	assert.equal(helperRow.continuedFrom, chat);
	assert.equal(helperRow.title, title);
	assert.equal(helped.state.agent.cwd, realpathSync(folder), "in the project's folder");
	assert.equal(helped.items[0].attachments[0].name, chatFileName(title));
	step("continued with another agent of the project: a new conversation of that agent in the project, linked both ways");

	await client.call("conversation.delete", { id: oc });
	await client.until("the project with no conversation", () => project()?.conversation === null);
	const { id: fresh } = await client.call("chat.continueWithAgent", { id: chat, projectId });
	assert.notEqual(fresh, oc);
	await client.until("the new one is the project's", () => project()?.conversation === fresh);
	await client.call("conversation.open", { id: fresh });
	const freshDone = await client.answered(fresh, 1);
	assert.ok(freshDone.items.some((item: any) => item.kind === "marker" && item.text === "pi² told the orchestrator how the project stands"));
	assert.equal(freshDone.items.find((item: any) => item.kind === "user").attachments[0].name, chatFileName(title));
	step("a project with no conversation with its orchestrator has one made, as the hub makes it, and the handover goes there");

	await client.call("projects.archive", { id: projectId });
	await assert.rejects(client.call("chat.continueWithAgent", { id: chat, projectId }), /archived/);
	step("an archived project takes no chat");
} finally {
	client.close();
	await stop(engine);
}
