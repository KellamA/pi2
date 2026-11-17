// What a conversation is told about code mode (src/codemode.ts, issue #163): a real engine on a throwaway data folder,
// driven over its socket with the demo model. Its tools are all given to the model directly, so the `codemode` section
// is a few lines and declares none of them; a conversation without code mode gets no section; a script still calls,
// finds and describes every tool, including those the section does not show. The fuller listing, for tools a script can
// call that the model was not given, is checked on the section itself, since no conversation in pi² has such tools.
//
// It also prints how long each section of the system prompt is, for a plain agent, one with everything switched on,
// and one with a test MCP server of many tools.

import assert from "node:assert/strict";
import { type ChildProcess, execFileSync, spawn } from "node:child_process";
import { mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { PromptInput, ToolRegistration } from "@earendil-works/pi-durable";
import { createBashTool, createReadTool } from "@earendil-works/pi-durable/tools";
import { CodemodeSandbox } from "@earendil-works/pi-codemode";
import { codemodeExtension } from "../src/codemode.ts";
import { EngineClient, stop } from "./patience.ts";

const home = mkdtempSync(join(tmpdir(), "pi2-cm-"));
const scratch = realpathSync(mkdtempSync(join(tmpdir(), "pi2-cm-work-")));
const main = join(import.meta.dirname, "..", "src", "main.ts");
const KEYCHAIN_SERVICE = `dev.pi2.credentials.test-codemode-${process.pid}`;
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

// ---- The section on its own: tools a script can call that the model was not given are declared in full

const sectionOf = (tools: ToolRegistration[], offered: string[]) => {
	const extension = codemodeExtension({ sandbox: new CodemodeSandbox() });
	const codemode = extension.tools!.find((tool) => tool.name === "codemode")!;
	const section = extension.sections!.find((candidate) => candidate.key === "codemode")!;
	const all = [codemode, ...tools];
	const input = { agent: { tools: all.filter((tool) => offered.includes(tool.name)), callable: tools, deferred: [] } } as unknown as PromptInput;
	return section.render(input, undefined as never) as Promise<string | undefined>;
};
const lookup: ToolRegistration = {
	name: "lookup_order",
	description: "Look up an order by its number.",
	parameters: { type: "object", properties: { number: { type: "string", description: "The order's number" } }, required: ["number"] },
	execute: async () => ({ output: "" }),
} as unknown as ToolRegistration;
{
	const bash = createBashTool();
	const read = createReadTool();
	const short = await sectionOf([read, bash, lookup], ["codemode", "read", "bash", "lookup_order"]);
	assert.ok(short !== undefined && !short.includes("declare const tools") && !short.includes("lookup_order"), `every tool given directly: no declarations\n${short}`);
	const fuller = await sectionOf([read, bash, lookup], ["codemode", "read", "bash"]);
	assert.ok(fuller !== undefined && fuller.startsWith(short!), `the same few lines first\n${fuller}`);
	assert.match(fuller!, /### `lookup_order`\nLook up an order by its number\.[\s\S]*declare const tools: \{ lookup_order\(args: \{[\s\S]*number: string;/, "the tool not given directly is declared in full");
	assert.ok(!fuller!.includes("### `read`") && !fuller!.includes("### `bash`"), "the tools given directly are not declared again");
	assert.equal(await sectionOf([read, bash], ["read", "bash"]), undefined, "no code mode, no section");
	assert.equal(await sectionOf([], ["codemode"]), undefined, "nothing a script can call, no section");
	const description = codemodeExtension({ sandbox: new CodemodeSandbox() }).tools!.find((tool) => tool.name === "codemode")!.description;
	assert.ok(description.includes("The `codemode` section of the system prompt says which tools scripts can call."), description);
	assert.ok(!description.includes("as far as space allows") && !description.includes("section does not list"), "the tool's description no longer says the section lists every tool");
	step("the section declares only tools a script can call that the model was not given, and is left out without code mode");
}

// ---- A test MCP server with many tools

const MANY = 40;
const serverPath = join(home, "many-tools-server.mjs");
writeFileSync(
	serverPath,
	`
import { createInterface } from "node:readline";
const reply = (id, result) => process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, result }) + "\\n");
const tools = Array.from({ length: ${MANY} }, (_, n) => ({
	name: "record_" + n,
	description: "Look up record " + n + " in the test catalogue and return its fields. Use it when the person asks about record " + n + "; it reads only and changes nothing.",
	inputSchema: { type: "object", properties: {
		id: { type: "string", description: "The record's identifier" },
		fields: { type: "array", items: { type: "string" }, description: "Fields to return; all when absent" },
		limit: { type: "integer", description: "At most this many results", minimum: 1 },
	}, required: ["id"] },
	annotations: { readOnlyHint: true },
}));
createInterface({ input: process.stdin }).on("line", (line) => {
	const message = JSON.parse(line);
	if (message.method === "initialize") reply(message.id, { protocolVersion: message.params.protocolVersion, capabilities: { tools: {} }, serverInfo: { name: "many", version: "1" } });
	else if (message.method === "tools/list") reply(message.id, { tools });
	else if (message.method === "tools/call") reply(message.id, { content: [{ type: "text", text: message.params.name + " of " + message.params.arguments.id }] });
	else if (message.id !== undefined) reply(message.id, {});
});
`,
);

class Client extends EngineClient {
	/** What the demo model answers to `text`, once its run is over. */
	async answer(id: number, text: string): Promise<string> {
		const assistant = () => (this.conversations.get(id)?.items ?? []).filter((item: any) => item.kind === "assistant");
		const before = assistant().length;
		await this.call("submit", { id, text });
		await this.until(`answer to ${text}`, () => {
			const conv = this.conversations.get(id);
			return conv !== undefined && !conv.state.busy && assistant().length > before;
		});
		return assistant().at(-1).text as string;
	}
	/** What the script `code` printed, once the answer after it is in. */
	async script(id: number, code: string): Promise<string> {
		const results = () => (this.conversations.get(id)?.items ?? []).filter((item: any) => item.kind === "tool");
		const before = results().length;
		await this.answer(id, `/code ${code}`);
		assert.ok(results().length > before, `the script ran: ${code}`);
		const text = results().at(-1).text as string;
		assert.ok(text.startsWith("Script completed\n") && text.includes("\nOutput:\n"), text);
		return text.slice(text.indexOf("\nOutput:\n") + 9);
	}
	async conversation(agent: Record<string, unknown>): Promise<number> {
		const { id: agentId } = await this.call("agents.save", { agent });
		await this.until(`agent ${agent.name}`, () => this.events.agents?.agents?.some((x: any) => x.id === agentId));
		const { id } = await this.call("conversation.create", { agentId });
		await this.call("conversation.open", { id });
		return id;
	}
}

engine = spawn(process.execPath, [main], { env, stdio: ["ignore", "ignore", "inherit"] });
const client = await Client.connect(engine, home);
try {
	await client.until("providers", () => client.events.providers);
	const { id: server } = await client.call("mcp.save", { name: "Many", transport: "stdio", command: process.execPath, args: [serverPath] });
	const connected = await client.until("mcp connected", () => client.events.mcp?.servers?.find((x: any) => x.id === server && x.status !== "connecting"));
	assert.equal(connected.status, "connected", connected.error ?? "");
	assert.equal(connected.tools.length, MANY);

	const plainOff = await client.conversation({ name: "Plain", access: "full", cwd: scratch });
	const plain = await client.conversation({ name: "Plain scripter", access: "full", cwd: scratch, codeMode: true });
	const helper = (client.events.agents.agents as any[]).find((x) => x.name === "Plain").id;
	const everything = await client.conversation({
		name: "Everything",
		access: "full",
		cwd: scratch,
		codeMode: true,
		computer: { enabled: true, apps: ["com.apple.Notes"] },
		browser: { enabled: true },
		schedule: { enabled: true },
		delegates: [helper],
	});
	const many = await client.conversation({ name: "Many tools", access: "full", cwd: scratch, codeMode: true, mcpServers: [server] });

	// How long each part of the system prompt is, in characters, for the report.
	const cases: [string, number][] = [
		["(a) plain, code mode off", plainOff],
		["(a) plain, code mode on", plain],
		["(b) everything on", everything],
		["(c) MCP server with many tools", many],
	];
	for (const [name, id] of cases) {
		const sizes = (await client.answer(id, "/system sizes")).split("\n").slice(1);
		const total = sizes.filter((line) => !line.startsWith("(tools")).reduce((sum, line) => sum + Number(line.split(" ").at(-1)), 0);
		console.log(`# ${name}: system prompt ${total} characters\n#   ${sizes.join("\n#   ")}`);
	}

	const sectionIn = async (id: number) => {
		const answer = await client.answer(id, "/system codemode");
		const text = answer.slice(answer.indexOf("<<codemode>>\n") + 13, answer.lastIndexOf("\nTOOLS: "));
		return { text, offered: answer.slice(answer.lastIndexOf("\nTOOLS: ") + 8).split(", ") };
	};

	// (a) Code mode off: no section at all. On: a few lines, no declarations.
	assert.equal((await sectionIn(plainOff)).text, "(none)", "no code mode, no codemode section");
	const short = await sectionIn(plain);
	assert.ok(short.offered.includes("codemode") && short.offered.includes("bash"));
	assert.ok(short.text.startsWith("<codemode>\nScripts can call your other tools"), short.text);
	assert.ok(!short.text.includes("declare const tools"), `no declarations in the short form:\n${short.text}`);
	assert.ok(short.text.length < 1000, `the short form is a few lines (${short.text.length} characters):\n${short.text}`);
	console.log(`# the short section:\n${short.text}`);
	step("a plain agent: no codemode section without code mode, a few lines with it");

	// (b) Everything on: still the few lines.
	const all = await sectionIn(everything);
	for (const name of ["computer", "browser", "schedule_task", "delegate"]) assert.ok(all.offered.includes(name), `${name} is offered: ${all.offered}`);
	assert.ok(!all.text.includes("declare const tools") && all.text.length < 1000, all.text);
	step("everything switched on: the same few lines");

	// (c) Forty MCP tools, all given directly: the few lines again, none of the forty in them.
	const mcp = await sectionIn(many);
	const last = connected.tools.at(-1).toolName as string;
	assert.ok(mcp.offered.includes(last), `the MCP tools are given directly: ${mcp.offered}`);
	assert.ok(!mcp.text.includes("declare const tools") && !mcp.text.includes("record_"), mcp.text);
	step("forty MCP tools, all given directly: the same few lines");

	// A script still calls, lists, finds and describes the tools the section does not show.
	const called = await client.script(many, `text(await tools.${last}({ id: "x7" }))`);
	assert.equal(called, `record_${MANY - 1} of x7`);
	const listed = await client.script(many, "text(ALL_TOOLS.map((tool) => tool.name).join(' '))");
	assert.ok(listed.includes(last) && listed.includes("bash") && listed.includes("read"), listed);
	const found = await client.script(many, `text((await searchTools("record ${MANY - 1} catalogue")).map((tool) => tool.name).join(" "))`);
	assert.ok(found.split(" ").includes(last), found);
	const described = await client.script(many, `text(await describeTool("${last}"))`);
	assert.match(described, new RegExp(`declare const tools: \\{ ${last}\\(args: \\{[\\s\\S]*id: string;`), described);
	const shell = await client.script(plain, "const r = await tools.bash({ command: 'echo from-a-script' }); text(r.exitCode + ' ' + r.output.trim())");
	assert.equal(shell, "0 from-a-script", "bash resolves to the object the short section says");
	step("a script calls, lists, finds and describes tools the section does not show");
} finally {
	client.close();
	await stop(engine);
}
