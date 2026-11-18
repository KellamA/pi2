// Test copies of pi² for computer use (#146): a switch in an agent's computer use settings, off by default, with which
// the agent may use throwaway test copies of pi² (bundle ids beginning dev.pi2.app.test) without listing them, and act
// in them instead of only looking. A real engine on a throwaway data folder, driven over its socket with the demo
// model; this client stands in for the app, as engine.ts does for computer use. Whether a running app really is such
// a copy is the app's to check (ComputerKit's TestCopy), so what is checked here is what the engine allows and what it
// tells the app.

import assert from "node:assert/strict";
import { type ChildProcess, execFileSync, spawn } from "node:child_process";
import { mkdtempSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { EngineClient, stop } from "./patience.ts";

const home = mkdtempSync(join(tmpdir(), "pi2-copies-"));
const scratch = realpathSync(mkdtempSync(join(tmpdir(), "pi2-copies-work-")));
const main = join(import.meta.dirname, "..", "src", "main.ts");
const KEYCHAIN_SERVICE = `dev.pi2.credentials.test-copies-${process.pid}`;
process.env.PI2_DEMO_TOKENS_PER_SECOND ??= "100000";
process.env.PI2_LOGIN_SHELL ??= "off";
const env = { ...process.env, PI2_HOME: home, PI2_KEYCHAIN_SERVICE: KEYCHAIN_SERVICE };

let engine: ChildProcess | undefined;
process.on("exit", () => {
	if (engine !== undefined && engine.exitCode === null && engine.signalCode === null) engine.kill("SIGKILL");
	rmSync(home, { recursive: true, force: true });
	rmSync(scratch, { recursive: true, force: true });
	try {
		while (true) execFileSync("/usr/bin/security", ["delete-generic-password", "-s", KEYCHAIN_SERVICE], { stdio: "ignore" });
	} catch {
		// None left.
	}
});

function step(name: string): void {
	console.log(`ok  ${name}`);
}

const NOTES = "com.example.notes";
const COPY = "dev.pi2.app.test-146";

class Client extends EngineClient {
	/** What the engine asked this stand-in app to do on screen. */
	computerRequests: any[] = [];

	override receive(message: any): void {
		if (message.event !== "computer") return super.receive(message);
		this.computerRequests.push(message);
		const reply =
			message.action === "describe"
				? { ok: true, text: `Click the “Send” button in ${message.app}` }
				: { ok: true, text: `${message.action} done in ${message.app ?? "no app"}`, summary: `${message.action} ${message.app ?? ""}` };
		void this.call("computer.result", { requestId: message.requestId, ...reply }).catch(() => {});
	}

	get inbox(): any[] {
		return this.events.inbox?.items ?? [];
	}

	items(id: number): any[] {
		return this.conversations.get(id)?.items ?? [];
	}

	/** Submits `text` and waits until the run is over, with `tools` tool results in all. */
	async run(id: number, text: string): Promise<void> {
		const before = this.items(id).filter((item) => item.kind === "assistant").length;
		await this.call("submit", { id, text });
		await this.until(`the run for ${text}`, () => {
			const conv = this.conversations.get(id);
			return conv !== undefined && !conv.state.busy && this.items(id).filter((item) => item.kind === "assistant").length > before;
		});
	}

	/** The result of one computer call, made by the demo model in conversation `id`. */
	async use(id: number, args: Record<string, unknown>): Promise<{ text: string; isError: boolean }> {
		const results = () => this.items(id).filter((item) => item.kind === "tool");
		const before = results().length;
		await this.call("submit", { id, text: `/computer ${JSON.stringify(args)}` });
		await this.until(`the result of ${JSON.stringify(args)}`, () => {
			const conv = this.conversations.get(id);
			return conv !== undefined && !conv.state.busy && results().length > before;
		});
		return results().at(-1);
	}

	/** Waits for the approval a computer call asks, and answers it. */
	async decide(id: number, decision: "once" | "always" | "deny"): Promise<any> {
		const asked = await this.until("an approval", () => this.inbox.find((item) => item.conversationId === id && item.tool === "computer"));
		await this.call("inbox.decide", { id: asked.id, decision });
		return asked;
	}

	/** The tools offered in a conversation, and its computer use section. */
	async offered(id: number): Promise<{ tools: string[]; section: string }> {
		await this.run(id, "/system computer_use");
		const answer = this.items(id).filter((item) => item.kind === "assistant").at(-1).text as string;
		return {
			tools: answer.slice(answer.lastIndexOf("\nTOOLS: ") + 8).split(", "),
			section: answer.slice(answer.indexOf("<<computer_use>>\n") + 17, answer.lastIndexOf("\nTOOLS: ")),
		};
	}
}

engine = spawn(process.execPath, [main], { env, stdio: ["ignore", "ignore", "inherit"] });
const client = await Client.connect(engine, home);
try {
	await client.until("providers", () => client.events.providers);
	const saved = (id: string) => client.events.agents?.agents?.find((x: any) => x.id === id);
	const agentOf = async (agent: Record<string, unknown>): Promise<string> => {
		const { id } = await client.call("agents.save", { agent });
		const computer = JSON.stringify(agent.computer ?? null);
		await client.until(`agent ${agent.name}`, () => {
			const got = saved(id)?.computer;
			const want = JSON.parse(computer);
			return got !== undefined && (want === null || (got.testCopies === (want.testCopies === true) && JSON.stringify(got.apps) === JSON.stringify(want.apps ?? [])));
		});
		return id;
	};
	const conversationOf = async (agentId: string): Promise<number> => {
		const { id } = await client.call("conversation.create", { agentId });
		await client.call("conversation.open", { id });
		return id;
	};
	const sent = (action: string, app: string) => client.computerRequests.filter((r) => r.action === action && r.app?.toLowerCase() === app.toLowerCase());
	await client.call("computer.register");

	// ---- What a test copy is, by bundle id
	const policy = await import("../src/computer.ts");
	assert.ok([COPY, "dev.pi2.app.test", "DEV.PI2.APP.TEST-7", "dev.pi2.app.test-7-b"].every(policy.isTestCopy), "a test copy, in any case");
	assert.ok(!["dev.pi2.app", "dev.pi2.app.dev", "dev.pi2.app.146", "dev.pi2.apptest", "dev.pi2.app.tes", "com.example.dev.pi2.app.test-1", "test.dev.pi2.app.test"].some(policy.isTestCopy), "pi² itself, the development build, other copies and other apps are not");
	assert.equal(policy.validateComputer({ enabled: true, apps: [NOTES] }).testCopies, false, "off unless turned on");
	assert.equal(policy.validateComputer({ enabled: true, testCopies: "yes" }).testCopies, false, "only true turns it on");
	step("a test copy is a bundle id beginning dev.pi2.app.test; the switch is off unless turned on");

	// ---- Off, as every agent is unless the person turns it on: nothing changes
	const plainId = await agentOf({ name: "Plain", access: "full", cwd: scratch, computer: { enabled: true, apps: [NOTES, "dev.pi2.app.test-9"] } });
	assert.equal(saved(plainId).computer.testCopies, false, "saved off");
	const plain = await conversationOf(plainId);
	const plainSection = (await client.offered(plain)).section;
	assert.ok(plainSection.includes("dev.pi2.app.test-9 (look only)") && !plainSection.includes("test copies"), plainSection);
	const notListed = await client.use(plain, { action: "screenshot", app: COPY });
	assert.ok(notListed.isError && /may not use/.test(notListed.text) && !/test copies/.test(notListed.text), notListed.text);
	assert.equal(sent("screenshot", COPY).length, 0, "an unlisted copy never reaches the app");
	const listedClick = await client.use(plain, { action: "click", app: "dev.pi2.app.test-9", element: 1 });
	assert.ok(listedClick.isError && /only be looked at/.test(listedClick.text), "a listed copy is look-only, as before");
	assert.ok(!(await client.use(plain, { action: "screenshot", app: "dev.pi2.app.test-9" })).isError, "and can be looked at");
	assert.ok(client.computerRequests.every((r) => r.testCopies === undefined), "the app is not told test copies may be used");
	assert.ok(!(await client.offered(await conversationOf(await agentOf({ name: "Empty", access: "full", cwd: scratch, computer: { enabled: true, apps: [] } })))).tools.includes("computer"), "no apps and no test copies: no computer tool, as before (#177)");
	step("off: an unlisted copy is refused, a listed one is look-only, and the app is told nothing new");

	// ---- On, with no app listed: the tool comes, and test copies can be used, with approval as the agent's settings say
	const testerId = await agentOf({ name: "Tester", access: "full", cwd: scratch, computer: { enabled: true, apps: [], testCopies: true } });
	const tester = await conversationOf(testerId);
	const seen = await client.offered(tester);
	assert.ok(seen.tools.includes("computer"), `the switch alone brings the computer tool: ${seen.tools.join(" ")}`);
	assert.ok(seen.section.includes("test copies of pi²") && seen.section.includes("none besides test copies") && seen.section.includes("wait for the person's approval"), seen.section);
	assert.ok(!(await client.use(tester, { action: "list_apps" })).isError);
	assert.ok(client.computerRequests.at(-1).testCopies === true && client.computerRequests.at(-1).apps.length === 0, "list_apps tells the app to list test copies");
	const shot = await client.use(tester, { action: "screenshot", app: COPY });
	assert.ok(!shot.isError && sent("screenshot", COPY).at(-1).testCopies === true, "looking at an unlisted copy reaches the app, which is told why it may");
	assert.equal(client.inbox.length, 0, "looking is not asked about");

	await client.call("submit", { id: tester, text: `/computer ${JSON.stringify({ action: "click", app: COPY, element: 1 })}` });
	const asked = await client.decide(tester, "once");
	assert.equal(asked.question, `Click the “Send” button in ${COPY}`, "the approval says what will be clicked, as for any app");
	assert.equal(sent("describe", COPY).at(-1).testCopies, true, "the app describing the action is told too, or it would refuse a copy");
	await client.until("the click", () => sent("click", COPY).length === 1 && !client.conversations.get(tester).state.busy);
	assert.equal(sent("click", COPY)[0].testCopies, true);
	assert.ok(!client.items(tester).filter((item) => item.kind === "tool").at(-1).isError, "the click went through once allowed");

	await client.call("submit", { id: tester, text: `/computer ${JSON.stringify({ action: "type", app: COPY, text: "hello" })}` });
	await client.decide(tester, "deny");
	await client.until("the denial", () => !client.conversations.get(tester).state.busy);
	assert.equal(sent("type", COPY).length, 0, "a denied action never reaches the copy");
	step("on: the tool comes without an app; a copy is listed, looked at and acted on, each action asked about");

	// ---- On: what stays refused
	await assert.rejects(client.call("agents.save", { agent: { id: testerId, name: "Tester", computer: { enabled: true, apps: ["dev.pi2.app"], testCopies: true } } }), /pi² itself/);
	const refused = async (app: string, pattern: RegExp, why: string) => {
		const result = await client.use(tester, { action: "click", app, element: 1 });
		assert.ok(result.isError && pattern.test(result.text), `${why}: ${result.text}`);
		assert.ok(sent("click", app).length === 0 && sent("describe", app).length === 0, `${why}: nothing reaches the app`);
	};
	await refused("dev.pi2.app", /may not use/, "pi² itself");
	await refused("DEV.PI2.APP", /may not use/, "pi² itself in another case");
	await refused("dev.pi2.app.dev", /may not use/, "the development build as built");
	await refused("dev.pi2.app.146", /may not use/, "a copy whose suffix does not begin with test");
	await refused("com.apple.Terminal", /may not use/, "a terminal");
	await refused(NOTES, /may not use/, "an app that is not listed");
	assert.equal(client.inbox.length, 0, "none of them is asked about");
	await agentOf({ name: "Tester", id: testerId, access: "full", cwd: scratch, computer: { enabled: true, apps: ["dev.pi2.app.dev", "com.apple.Safari"], testCopies: true } });
	await refused("dev.pi2.app.dev", /only be looked at/, "a listed development build is still look-only");
	await refused("com.apple.Safari", /only be looked at/, "a browser is still look-only");
	const listedSection = (await client.offered(tester)).section;
	assert.ok(listedSection.includes("dev.pi2.app.dev (look only)") && listedSection.includes("com.apple.Safari (look only)"), listedSection);
	step("on: pi² itself, the development build, other copies, terminals and unlisted apps stay refused; look-only stays look-only");

	// ---- Asking follows the agent's own setting
	await agentOf({ name: "Tester", id: testerId, access: "full", cwd: scratch, computer: { enabled: true, apps: [], testCopies: true, ask: false } });
	await client.until("asking off", () => saved(testerId).computer.ask === false);
	const quiet = await client.use(tester, { action: "menu", app: "Dev.Pi2.App.Test-146", path: "File > New" });
	assert.ok(!quiet.isError && sent("menu", COPY).length === 1 && client.inbox.length === 0, "with asking off, as for any app, it acts without asking");
	step("with asking off, a copy is acted on without asking, as any allowed app is");

	// ---- A sub-chat follows its own agent's switch, never its parent's
	const helperId = await agentOf({ name: "Helper", access: "full", cwd: scratch, computer: { enabled: true, apps: [NOTES] } });
	const leadId = await agentOf({ name: "Lead", access: "full", cwd: scratch, computer: { enabled: true, apps: [], testCopies: true }, delegates: [helperId] });
	const lead = await conversationOf(leadId);
	const before = new Set((client.events.library?.conversations ?? []).map((x: any) => x.id));
	await client.run(lead, "/delegate Helper: Hello");
	const sub = await client.until("the sub-chat", () => (client.events.library?.conversations ?? []).find((x: any) => x.parent === lead && !before.has(x.id))?.id as number | undefined);
	await client.call("conversation.open", { id: sub });
	const inSub = await client.use(sub, { action: "screenshot", app: COPY });
	assert.ok(inSub.isError && /may not use/.test(inSub.text), "the parent's switch does not reach the sub-chat of an agent without it");
	await agentOf({ name: "Helper", id: helperId, access: "full", cwd: scratch, computer: { enabled: true, apps: [NOTES], testCopies: true } });
	await agentOf({ name: "Lead", id: leadId, access: "full", cwd: scratch, computer: { enabled: true, apps: [NOTES] }, delegates: [helperId] });
	const subOn = await client.use(sub, { action: "screenshot", app: COPY });
	assert.ok(!subOn.isError && sent("screenshot", COPY).at(-1).conversationId === sub, "with its own agent's switch on, the sub-chat may use a copy");
	const leadOff = await client.use(lead, { action: "screenshot", app: COPY });
	assert.ok(leadOff.isError && /may not use/.test(leadOff.text), "and the parent, now off, may not");
	step("a sub-chat follows its own agent's switch, never its parent's");
} finally {
	client.close();
	await stop(engine);
}
