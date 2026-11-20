// What happens to a tool call running on an MCP server when the person reconnects, edits, removes or switches off that
// server (issue #138). Reconnect and an edit start the new copy beside the one running, which finishes its calls and
// then stops; remove and switch off stop every copy at once, and the call is told why; a replaced copy whose call never
// ends is stopped after a while all the same.
//
// The test MCP server says in a file each time it starts, can be held before it answers `initialize` (while a file is
// there), and has a tool that answers only once a file is there: nothing here is timed, except the bound on how long a
// replaced copy may run, which is what one check is about.

import assert from "node:assert/strict";
import { type ChildProcess, spawn, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { McpServers } from "../src/mcp.ts";
import { socketPathFor } from "../src/socket.ts";
import { EngineClient, standInApp, stop, until } from "./patience.ts";
// The engine takes changes to what the person set only from its app's connection (#513): this test's connection stands
// for the app's, as the tests that answer for the person already do (#504).
process.env.PI2_APP_BUNDLE = standInApp();

const scratch = realpathSync(mkdtempSync(join(tmpdir(), "pi2-mcpreconnect-")));
const main = join(import.meta.dirname, "..", "src", "main.ts");
const engines: ChildProcess[] = [];
/** Every server process started, from the file the servers write: name and process number. */
const startsFile = join(scratch, "starts");

function step(name: string): void {
	console.log(`ok  ${name}`);
}
const alive = (pid: number): boolean => {
	try {
		process.kill(pid, 0);
		return true;
	} catch {
		return false;
	}
};
function starts(name?: string): { name: string; pid: number }[] {
	const lines = existsSync(startsFile) ? readFileSync(startsFile, "utf8").split("\n").filter((line) => line !== "") : [];
	return lines.map((line) => line.split(" ")).map(([server, pid]) => ({ name: server!, pid: Number(pid) })).filter((start) => name === undefined || start.name === name);
}

// The test server. `node server.mjs <name> <starts file> <slow file>`: says it started, answers `initialize` only while
// the slow file is not there, then answers `env` with its process number, and `hold` once the file named in its
// arguments is there (saying first, in the file `held`, that it holds).
const serverPath = join(scratch, "server.mjs");
writeFileSync(
	serverPath,
	`
import { appendFileSync, existsSync, writeFileSync } from "node:fs";
import { createInterface } from "node:readline";
const [name, startsFile, slowFile] = process.argv.slice(2);
appendFileSync(startsFile, name + " " + process.pid + "\\n");
const reply = (id, result) => process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, result }) + "\\n");
const text = (id, value) => reply(id, { content: [{ type: "text", text: value }] });
const when = (ready, then) => {
	if (ready()) return then();
	const wait = setInterval(() => {
		if (!ready()) return;
		clearInterval(wait);
		then();
	}, 25);
};
const schema = { type: "object", properties: { gate: { type: "string" }, held: { type: "string" } } };
createInterface({ input: process.stdin }).on("line", (line) => {
	const message = JSON.parse(line);
	if (message.method === "initialize") when(() => !existsSync(slowFile), () => reply(message.id, { protocolVersion: message.params.protocolVersion, capabilities: { tools: {} }, serverInfo: { name, version: "1" } }));
	else if (message.method === "tools/list") reply(message.id, { tools: [
		{ name: "env", description: "Say which process this is", inputSchema: schema, annotations: { readOnlyHint: true } },
		{ name: "hold", description: "Answer once a file is there", inputSchema: schema, annotations: { readOnlyHint: true } },
	] });
	else if (message.method === "tools/call" && message.params.name === "env") text(message.id, String(process.pid));
	else if (message.method === "tools/call") {
		writeFileSync(message.params.arguments.held, String(process.pid));
		when(() => existsSync(message.params.arguments.gate), () => text(message.id, "held by " + process.pid));
	}
	else if (message.id !== undefined) reply(message.id, {});
});
`,
);

const slow = (name: string) => join(scratch, `slow-${name}`);
const serverConfig = (id: string, name: string) => ({ id, name, transport: "stdio", command: process.execPath, args: [serverPath, id, startsFile, slow(id)], enabled: true });
let holds = 0;
/** Files for one held call: where the server says it holds it, and the file that lets it answer. */
function hold(): { held: string; gate: string } {
	holds++;
	return { held: join(scratch, `held-${holds}`), gate: join(scratch, `gate-${holds}`) };
}
const holding = (held: string) => until("the server to hold the call", () => existsSync(held) && readFileSync(held, "utf8") !== "" && Number(readFileSync(held, "utf8")));

try {
	// ---- In the engine's own process, calling the tools as a conversation would

	{
		const home = join(scratch, "unit");
		mkdirSync(home);
		writeFileSync(join(home, "mcp.json"), JSON.stringify([serverConfig("a", "A"), serverConfig("b", "B"), serverConfig("c", "C")]));
		const credentials = { list: async () => [], read: async () => undefined, modify: async () => {}, delete: async () => {} };
		const servers = new McpServers(home, credentials as never);
		const logged: string[] = [];
		servers.log = (...parts) => void logged.push(parts.join(" "));
		const server = (id: string) => servers.list().find((s) => s.id === id)!;
		/** Calls tool `name` of server `id` the way the engine runs a tool, through the extension as it is now. */
		const callTool = async (id: string, name: string, args: object = {}, signal = new AbortController().signal): Promise<string> => {
			const toolName = server(id).tools.find((tool) => tool.name === name)!.toolName;
			const registration = servers.extension().tools!.find((tool) => tool.name === toolName) as any;
			const result = await registration.execute(args, {}, { abortSignal: signal });
			assert.equal(result.isError, false);
			return result.output.map((block: { text: string }) => block.text).join("");
		};
		/** A call left running, to be awaited later: it may fail before then, which is not yet a failure of the test. */
		const startCall = (id: string, name: string, args: object, signal?: AbortSignal): Promise<string> => {
			const running = callTool(id, name, args, signal);
			running.catch(() => {});
			return running;
		};
		try {
			await servers.start();
			for (const id of ["a", "b", "c"]) assert.equal(server(id).status, "connected", server(id).error ?? "");

			// Reconnect, with a call running and the new copy slow to start.
			const [a1] = starts("a");
			const call = hold();
			const held = startCall("a", "hold", call);
			assert.equal(await holding(call.held), a1!.pid);
			writeFileSync(slow("a"), "");
			const reconnected = servers.reconnect("a");
			const a2 = await until("a second copy to start", () => starts("a")[1]);
			assert.equal(server("a").status, "connecting");
			assert.deepEqual(server("a").tools.map((tool) => tool.name), ["env", "hold"], "its tools stay while the new copy starts");
			assert.equal(await callTool("a", "env"), String(a1!.pid), "and a new call meanwhile goes to the copy running");
			rmSync(slow("a"));
			await reconnected;
			assert.equal(server("a").status, "connected");
			assert.equal(await callTool("a", "env"), String(a2.pid), "once it has connected, the new copy answers");
			assert.ok(alive(a1!.pid), "the copy the call is running on is left running");
			writeFileSync(call.gate, "");
			assert.equal(await held, `held by ${a1!.pid}`, "the call finishes on the copy it started on");
			await until("the replaced copy to stop once its call is done", () => !alive(a1!.pid));
			assert.deepEqual(logged, ["MCP server A started again; the copy it replaces stops once its calls are done"]);
			step("Reconnect starts a new copy beside the one running, which finishes its call and then stops");

			// An edit that leaves the server unable to start, with a call running.
			const edited = hold();
			const editedCall = startCall("a", "hold", edited);
			assert.equal(await holding(edited.held), a2.pid);
			await servers.save({ id: "a", name: "A", transport: "stdio", command: join(scratch, "no-such-program"), args: [] });
			assert.equal(server("a").status, "error");
			assert.deepEqual(server("a").tools, [], "a server that failed to start offers no tools");
			assert.ok(alive(a2.pid), "the copy the call is running on is left running");
			writeFileSync(edited.gate, "");
			assert.equal(await editedCall, `held by ${a2.pid}`, "and the call finishes there");
			await until("that copy to stop once its call is done", () => !alive(a2.pid));
			await servers.save(serverConfig("a", "A"));
			assert.equal(server("a").status, "connected");
			step("an edit that fails shows why, and the copy it replaces still finishes its call");

			// Remove, with a call running.
			const [a3] = starts("a").slice(-1);
			const removed = hold();
			const removedCall = startCall("a", "hold", removed);
			assert.equal(await holding(removed.held), a3!.pid);
			logged.length = 0;
			await servers.remove("a");
			await assert.rejects(removedCall, /^Error: The MCP server A was removed while this call was running, so the call was stopped\./);
			await until("the removed server to stop", () => !alive(a3!.pid));
			assert.equal(server("a"), undefined);
			assert.deepEqual(logged, ["MCP server A removed; the call running on it stopped"]);
			step("removing a server stops it at once, and a call running on it is told why");

			// Switch off, with one call on a copy being replaced and another on the copy that replaces it.
			const [b1] = starts("b");
			const first = hold();
			const firstCall = startCall("b", "hold", first);
			assert.equal(await holding(first.held), b1!.pid);
			await servers.reconnect("b");
			const b2 = starts("b")[1]!;
			const second = hold();
			const secondCall = startCall("b", "hold", second);
			assert.equal(await holding(second.held), b2.pid);
			logged.length = 0;
			await servers.save({ ...serverConfig("b", "B"), enabled: false });
			assert.equal(server("b").status, "off");
			for (const call of [firstCall, secondCall]) await assert.rejects(call, /^Error: The MCP server B was switched off while this call was running, so the call was stopped\./);
			await until("both copies to stop", () => !alive(b1!.pid) && !alive(b2.pid));
			assert.deepEqual(logged, ["MCP server B switched off; the 2 calls running on it stopped"]);
			step("switching a server off stops every copy of it at once, the one being replaced too");

			// A replaced copy whose call does not end.
			servers.lingerMs = 1000;
			const [c1] = starts("c");
			const stuck = hold();
			const stuckCall = startCall("c", "hold", stuck);
			assert.equal(await holding(stuck.held), c1!.pid);
			logged.length = 0;
			await servers.reconnect("c");
			assert.equal(server("c").status, "connected");
			await assert.rejects(stuckCall, /^Error: The MCP server C was started again while this call was running, and the call was stopped after 1 second so that the copy it ran on could close\./);
			await until("the replaced copy to stop", () => !alive(c1!.pid));
			assert.equal(await callTool("c", "env"), String(starts("c")[1]!.pid), "the new copy answers");
			assert.deepEqual(logged, ["MCP server C started again; the copy it replaces stops once its calls are done", "MCP server C: the copy it replaced closed after 1 second with a call still running"]);
			step("a replaced copy is stopped after a while even if its call has not ended, and the call is told why");

			// A call on a replaced copy that the conversation stops.
			// Longer than any wait here, so that only the stop can close the copy.
			servers.lingerMs = 24 * 3_600_000;
			const c2 = starts("c")[1]!;
			const stopped = hold();
			const stopping = new AbortController();
			const stoppedCall = startCall("c", "hold", stopped, stopping.signal);
			assert.equal(await holding(stopped.held), c2.pid);
			await servers.reconnect("c");
			assert.ok(alive(c2.pid));
			stopping.abort();
			await assert.rejects(stoppedCall, (error: Error) => error.name === "AbortError", "a call the conversation stopped ends as stopped");
			await until("the replaced copy to stop once its call was stopped", () => !alive(c2.pid));
			step("stopping a call on a replaced copy closes that copy at once");
		} finally {
			await servers.stop();
		}
	}

	// ---- A real engine, driven as the app drives it, with the demo model calling the tools

	const home = join(scratch, "home");
	mkdirSync(home);
	writeFileSync(join(home, "mcp.json"), JSON.stringify([serverConfig("e", "E")]));
	const engine = spawn(process.execPath, [main], {
		env: { ...process.env, PI2_HOME: home, PI2_KEYCHAIN_SERVICE: "dev.pi2.credentials.test-mcpreconnect", PI2_LOGIN_SHELL: "off", PI2_DEMO_TOKENS_PER_SECOND: "1000" },
		stdio: ["ignore", "ignore", "inherit"],
	});
	engines.push(engine);
	const client = await EngineClient.connect(engine, home);
	const server = () => (client.events.mcp?.servers ?? []).find((s: { id: string }) => s.id === "e");
	await client.until("the server to connect", () => server()?.status === "connected");
	const toolName = (name: string) => server().tools.find((tool: { name: string }) => tool.name === name).toolName;
	const { id: agent } = await client.call("agents.save", { agent: { name: "Caller", access: "full", mcpServers: ["e"] } });
	const { id: conversation } = await client.call("conversation.create", { agentId: agent });
	await client.call("conversation.open", { id: conversation });
	const results = () => (client.conversations.get(conversation)?.items ?? []).filter((item: { kind: string }) => item.kind === "tool");
	/** Has the demo model call `tool`; `result` is the call's result, once the answer is over. */
	const mcpCall = async (tool: string, args: object = {}): Promise<{ result: Promise<{ text: string; isError: boolean }> }> => {
		const before = results().length;
		await client.call("submit", { id: conversation, text: `/mcp ${tool} ${JSON.stringify(args)}` });
		const result = client.until(`the result of ${tool}`, () => {
			const conv = client.conversations.get(conversation);
			return conv !== undefined && !conv.state.busy && results().length > before && conv.items.at(-1)?.kind === "assistant" ? results().at(-1) : undefined;
		});
		result.catch(() => {}); // awaited later; a failure then is the one reported
		return { result };
	};

	const [e1] = starts("e");
	const reconnectCall = hold();
	const { result: reconnectResult } = await mcpCall(toolName("hold"), reconnectCall);
	assert.equal(await holding(reconnectCall.held), e1!.pid);
	await client.call("mcp.reconnect", { id: "e" });
	await client.until("the server to be connected again", () => server()?.status === "connected" && starts("e").length === 2);
	assert.ok(alive(e1!.pid), "the copy the call is running on is left running");
	writeFileSync(reconnectCall.gate, "");
	const finished = await reconnectResult;
	assert.equal(finished.isError, false, finished.text);
	assert.equal(finished.text, `held by ${e1!.pid}`, "Reconnect in Settings leaves the call to finish");
	await until("the replaced copy to stop", () => !alive(e1!.pid));
	step("Reconnect from the app does not cut off a conversation's call");

	const e2 = starts("e")[1]!;
	const removeCall = hold();
	const { result: removeResult } = await mcpCall(toolName("hold"), removeCall);
	assert.equal(await holding(removeCall.held), e2.pid);
	await client.call("mcp.delete", { id: "e" });
	const cut = await removeResult;
	assert.equal(cut.isError, true);
	assert.match(cut.text, /The MCP server E was removed while this call was running, so the call was stopped\./, "the agent is told why the call ended");
	await until("the removed server to stop", () => !alive(e2.pid));
	step("removing a server in the app ends a conversation's call with a clear answer");

	client.close();
	await stop(engine);
} finally {
	for (const engine of engines) await stop(engine);
	const reached = socketPathFor(join(scratch, "home"));
	if (reached !== join(scratch, "home", "engine.sock")) rmSync(join(reached, ".."), { force: true });
	// Had a check failed part-way, a test server could be left: stop any that is still this test's own.
	for (const { pid } of starts()) {
		if (spawnSync("/bin/ps", ["-o", "command=", "-p", String(pid)], { encoding: "utf8" }).stdout.includes(serverPath)) process.kill(pid, "SIGKILL");
	}
	rmSync(scratch, { recursive: true, force: true });
}

console.log("mcpreconnect: ok (reconnecting, editing, removing or switching off an MCP server with a call running)");
