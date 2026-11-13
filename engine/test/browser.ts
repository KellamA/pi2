// The engine and the browser together: a real engine on a throwaway data folder, and the browser probe standing in for
// the app, working pages the probe serves to itself. No real website is loaded and no window is shown.
//
// This is not part of `npm test`, because it needs the probe, which is built with Swift:
//
//   cd app && swift build --product pi2-browser-probe
//   cd engine && npm run test:browser
//
// `engine.ts` checks the engine's rules with a scripted stand-in for the app. This checks that the engine and BrowserKit
// mean the same thing by every message: what the approval card says is what BrowserKit would do, and what was approved
// is what gets done.

import assert from "node:assert/strict";
import { type ChildProcess, spawn } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { connect, type Socket } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { setTimeout as sleep } from "node:timers/promises";

const probePath = join(import.meta.dirname, "..", "..", "app", ".build", "debug", "pi2-browser-probe");
if (!existsSync(probePath)) {
	console.error("The browser probe is not built. Run: cd app && swift build --product pi2-browser-probe");
	process.exit(2);
}

const home = mkdtempSync(join(tmpdir(), "pi2-browser-test-"));
const socketPath = join(home, "engine.sock");
const main = join(import.meta.dirname, "..", "src", "main.ts");
// The demo model types slowly for people; every engine this test starts makes it fast.
process.env.PI2_DEMO_TOKENS_PER_SECOND ??= "1000";
const KEYCHAIN_SERVICE = process.env.PI2_TEST_KEYCHAIN_SERVICE ?? "dev.pi2.credentials.test";

type Item = { id: number; kind: string; text: string; isError?: boolean };
type InboxItem = { id: string; tool: string; conversationId: number; question: string | null; site?: string };

class Client {
	socket!: Socket;
	items = new Map<number, Item[]>();
	busy = new Map<number, boolean>();
	inbox: InboxItem[] = [];
	agents: { id: string; browser?: { enabled: boolean } }[] = [];
	#nextId = 1;
	#replies = new Map<number, { resolve: (v: any) => void; reject: (e: Error) => void }>();

	static async attach(): Promise<Client> {
		const client = new Client();
		for (let attempt = 0; ; attempt++) {
			try {
				if (!existsSync(socketPath)) throw new Error("no socket yet");
				client.socket = connect(socketPath);
				await new Promise<void>((resolve, reject) => client.socket.once("connect", resolve).once("error", reject));
				break;
			} catch (error) {
				if (attempt >= 200) throw error;
				await sleep(50);
			}
		}
		let buffer = "";
		client.socket.setEncoding("utf8").on("data", (chunk: string) => {
			buffer += chunk;
			const lines = buffer.split("\n");
			buffer = lines.pop()!;
			for (const line of lines) client.receive(JSON.parse(line));
		});
		client.socket.on("error", () => {});
		return client;
	}

	receive(message: any): void {
		if (message.event === "inbox") this.inbox = message.items;
		else if (message.event === "agents") this.agents = message.agents;
		else if (message.event === "conversation") {
			const items = message.reset ? [] : (this.items.get(message.id) ?? []);
			items.push(...message.items);
			this.items.set(message.id, items);
			this.busy.set(message.id, message.state.busy);
		} else if (message.id !== undefined && message.id !== null) {
			const reply = this.#replies.get(message.id);
			this.#replies.delete(message.id);
			if (message.error !== undefined) reply?.reject(new Error(message.error));
			else reply?.resolve(message.result);
		}
	}

	call(method: string, params: Record<string, unknown> = {}): Promise<any> {
		const id = this.#nextId++;
		this.socket.write(`${JSON.stringify({ id, method, params })}\n`);
		return new Promise((resolve, reject) => this.#replies.set(id, { resolve, reject }));
	}

	async until<T>(what: string, check: () => T | undefined | false, timeoutMs = 60_000): Promise<T> {
		const deadline = Date.now() + timeoutMs;
		for (;;) {
			const value = check();
			if (value !== undefined && value !== false) return value;
			if (Date.now() > deadline) throw new Error(`Timed out waiting for: ${what}`);
			await sleep(50);
		}
	}

	results(id: number): Item[] {
		return (this.items.get(id) ?? []).filter((item) => item.kind === "tool");
	}
}

function step(name: string): void {
	console.log(`ok  ${name}`);
}

/** The number the newest view gave the element whose line holds `words`. */
function element(view: string, words: string): number {
	const line = view.split("\n").find((candidate) => /^\[\d+\] /.test(candidate) && candidate.includes(words));
	assert.ok(line, `the page lists something with ${words}:\n${view}`);
	return Number(line.slice(1, line.indexOf("]")));
}

const engine = spawn(process.execPath, [main], { env: { ...process.env, PI2_HOME: home, PI2_KEYCHAIN_SERVICE: KEYCHAIN_SERVICE }, stdio: ["ignore", "ignore", "inherit"] });
let probe: ChildProcess | undefined;
try {
	const client = await Client.attach();

	// The probe is the app as far as the browser goes: it registers as the browser host and answers with BrowserKit.
	probe = spawn(probePath, ["--engine", socketPath], { stdio: ["pipe", "pipe", "inherit"] });
	const said: string[] = [];
	createInterface({ input: probe.stdout! }).on("line", (line) => said.push(line));
	const hear = (start: string) => client.until(`the probe to say "${start}"`, () => said.find((line) => line.startsWith(start)));
	const site = (await hear("ready ")).slice(6);
	/** Put a fixture page in front of a conversation, as the person would in the Browser window. */
	const show = async (conversation: number, path: string) => {
		const told = said.length;
		probe!.stdin!.write(`open ${conversation} ${path}\n`);
		await client.until(`${path} to open`, () => said.slice(told).includes(`opened ${conversation}`));
	};

	mkdirSync(join(home, "refs"));
	const resume = join(home, "refs", "resume.txt");
	writeFileSync(resume, "Ada Lovelace, analyst and metaphysician.");
	await client.call("agents.save", { agent: { id: "atlas", name: "Atlas", browser: { enabled: true }, files: [{ path: resume, note: "CV" }] } });
	await client.until("the browser switched on", () => client.agents.find((agent) => agent.id === "atlas")?.browser?.enabled === true);

	const start = async () => {
		const { id } = await client.call("conversation.create", { agentId: "atlas" });
		await client.call("conversation.open", { id });
		return id as number;
	};
	const calls = new Map<number, number>();
	/** Have the demo model make one browser call, and wait for its result unless a question is expected first. */
	const browse = async (id: number, args: Record<string, unknown>, wait = true): Promise<Item> => {
		const count = (calls.get(id) ?? 0) + 1;
		calls.set(id, count);
		await client.call("submit", { id, text: `/browser ${JSON.stringify(args)}` });
		if (!wait) return undefined as never;
		return settled(id);
	};
	const settled = (id: number) => client.until("the call's result", () => (client.results(id).length === calls.get(id) && client.busy.get(id) === false ? client.results(id).at(-1) : undefined));
	const asked = (id: number) => client.until("a question", () => client.inbox.find((item) => item.tool === "browser" && item.conversationId === id));

	const a = await start();
	const refused = await browse(a, { action: "open", url: `${site}/form` });
	assert.ok(refused.isError && /off limits/.test(refused.text), "the engine does not open an address on this Mac, the fixture pages included");
	const nothing = await browse(a, { action: "read" });
	assert.ok(nothing.isError && /No page is open/.test(nothing.text), nothing.text);
	step("the engine refuses a local address before the browser is asked; without a page there is nothing to read");

	await show(a, "/form");
	let page = await browse(a, { action: "read" });
	assert.ok(!page.isError && page.text.includes("Page: Job application") && page.text.includes("text field “Full name”"), page.text);
	assert.equal(client.inbox.length, 0, "reading is not asked about");
	page = await browse(a, { action: "click", element: element(page.text, "“Next page”") });
	assert.ok(!page.isError && page.text.startsWith("Followed the link “Next page”.") && page.text.includes(`Address: ${site}/next`), page.text);
	assert.equal(client.inbox.length, 0, "following a plain link is not asked about");
	page = await browse(a, { action: "back" });
	assert.ok(page.text.includes(`Address: ${site}/form`), page.text);
	step("reading, following a plain link and going back happen without a question");

	await browse(a, { action: "type", element: element(page.text, "“Full name”"), text: "Ada" }, false);
	const typing = await asked(a);
	assert.equal(typing.question, "Type “Ada” into the “Full name” field on 127.0.0.1", "the question is BrowserKit's description of the action");
	assert.equal(typing.site, "127.0.0.1");
	await client.call("inbox.decide", { id: typing.id, decision: "always" });
	page = await settled(a);
	assert.ok(!page.isError && page.text.startsWith("Typed “Ada” into “Full name”.") && page.text.includes("holds “Ada”"), page.text);
	page = await browse(a, { action: "click", element: element(page.text, "“Greet”") });
	assert.ok(!page.isError && page.text.includes("Hello, Ada!"), page.text);
	assert.equal(client.inbox.length, 0, "“always” covers the site for the rest of the conversation");
	step("typing waits for approval, worded by BrowserKit; once the site is allowed, a button is clicked without asking");

	const secret = await browse(a, { action: "type", element: element(page.text, "“Password”"), text: "hunter2" });
	assert.ok(secret.isError && /does not type passwords/.test(secret.text), secret.text);
	page = await browse(a, { action: "read" });
	assert.ok(page.text.includes("password untouched"), "the password field was not touched");
	step("a password field is refused, on an allowed site too");

	page = await browse(a, { action: "upload", element: element(page.text, "file input"), path: resume });
	assert.ok(!page.isError && page.text.startsWith("Chose resume.txt"), page.text);
	const elsewhere = await browse(a, { action: "upload", element: element(page.text, "file input"), path: join(home, "settings.json") });
	assert.ok(elsewhere.isError && /cannot be uploaded/.test(elsewhere.text), elsewhere.text);
	page = await browse(a, { action: "click", element: element(page.text, "“Submit application”") });
	assert.ok(page.text.includes("Page: Application received") && page.text.includes("name = Ada") && page.text.includes("resume = file resume.txt (40 bytes"), page.text);
	step("a reference file is uploaded and the form is sent with it; a file the agent was not given is refused");

	// A second conversation has its own page, and its own say over what is allowed.
	const b = await start();
	await show(b, "/form");
	page = await browse(b, { action: "read" });
	const greet = element(page.text, "“Greet”");
	await browse(b, { action: "click", element: greet }, false);
	const denied = await asked(b);
	assert.equal(denied.question, "Click “Greet” on 127.0.0.1");
	await client.call("inbox.decide", { id: denied.id, decision: "deny" });
	assert.ok((await settled(b)).isError);
	page = await browse(b, { action: "read" });
	assert.ok(!page.text.includes("Hello,"), "a denied click did not happen");
	step("another conversation is asked afresh, and a denied click is not made");

	// The page changes while the question is open: what was approved is no longer there to do.
	await browse(b, { action: "click", element: greet }, false);
	const stale = await asked(b);
	await show(b, "/next");
	await client.call("inbox.decide", { id: stale.id, decision: "once" });
	const late = await settled(b);
	assert.ok(late.isError && /changed since your last view/.test(late.text), late.text);
	step("an approval does not carry over to a page that has changed since");
	console.log("PASS");
} finally {
	probe?.kill("SIGTERM");
	engine.kill("SIGTERM");
	await sleep(400);
	rmSync(home, { recursive: true, force: true });
}
process.exit(0);
