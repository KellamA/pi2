// MCP servers started before a slow login shell's PATH is taken are started again with it (issue #98): one whose
// program is only on that PATH ends up connected, one that connected early ends up running with it, and a call running
// on the early one is not cut off.
//
// The engine is given a stand-in login shell that answers only when the test lets it (a file appears), so it always
// starts with the usual folders, however busy the Mac. The test MCP server says in a file each time it starts, with
// which PATH, and has a tool that waits for a file too: nothing here is timed.

import assert from "node:assert/strict";
import { type ChildProcess, spawn, spawnSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";
import { McpServers } from "../src/mcp.ts";
import { socketPathFor } from "../src/socket.ts";
import { listening, running, standInApp, stop, until } from "./patience.ts";
// The engine takes changes to what the person set only from its app's connection (#513): this test's connection stands
// for the app's, as the tests that answer for the person already do (#504).
process.env.PI2_APP_BUNDLE = standInApp();

const scratch = realpathSync(mkdtempSync(join(tmpdir(), "pi2-mcppath-")));
const BARE = "/usr/bin:/bin:/usr/sbin:/sbin";
const main = join(import.meta.dirname, "..", "src", "main.ts");
const engines: ChildProcess[] = [];
/** Every server process started, from the file the servers write: name, process number, PATH. */
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
type Start = { name: string; pid: number; path: string };
function starts(name?: string): Start[] {
	const lines = existsSync(startsFile) ? readFileSync(startsFile, "utf8").split("\n").filter((line) => line !== "") : [];
	return lines
		.map((line) => {
			const [server, pid, ...path] = line.split(" ");
			return { name: server!, pid: Number(pid), path: path.join(" ") };
		})
		.filter((start) => name === undefined || start.name === name);
}

// The test server. `node server.mjs <name> <starts file>`: says it started, then answers `env` with its process number
// and PATH, and `hold` once the file named in its arguments is there (saying first, in the file `held`, that it holds).
const serverPath = join(scratch, "server.mjs");
writeFileSync(
	serverPath,
	`
import { appendFileSync, existsSync, writeFileSync } from "node:fs";
import { createInterface } from "node:readline";
const [name, startsFile] = process.argv.slice(2);
appendFileSync(startsFile, name + " " + process.pid + " " + process.env.PATH + "\\n");
const reply = (id, result) => process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, result }) + "\\n");
const text = (id, value) => reply(id, { content: [{ type: "text", text: value }] });
const schema = { type: "object", properties: { gate: { type: "string" }, held: { type: "string" } } };
createInterface({ input: process.stdin }).on("line", (line) => {
	const message = JSON.parse(line);
	if (message.method === "initialize") reply(message.id, { protocolVersion: message.params.protocolVersion, capabilities: { tools: {} }, serverInfo: { name, version: "1" } });
	else if (message.method === "tools/list") reply(message.id, { tools: [
		{ name: "env", description: "Say which process this is, and its PATH", inputSchema: schema, annotations: { readOnlyHint: true } },
		{ name: "hold", description: "Answer once a file is there", inputSchema: schema, annotations: { readOnlyHint: true } },
	] });
	else if (message.method === "tools/call" && message.params.name === "env") text(message.id, process.pid + " " + process.env.PATH);
	else if (message.method === "tools/call") {
		writeFileSync(message.params.arguments.held, String(process.pid));
		const wait = setInterval(() => {
			if (!existsSync(message.params.arguments.gate)) return;
			clearInterval(wait);
			text(message.id, "held by " + process.pid);
		}, 25);
	}
	else if (message.id !== undefined) reply(message.id, {});
});
`,
);

/** A stand-in login shell that answers with `path`, but not before the file `gate` is there. */
function gatedShell(folder: string, gate: string, path: string): string {
	mkdirSync(folder, { recursive: true });
	const shell = join(folder, "zsh");
	// It gives up once the scratch folder is gone, so it is never left waiting whatever became of the test.
	writeFileSync(shell, `#!/bin/sh\n[ "$1" = "-ilc" ] || exit 0\nwhile [ ! -e "${gate}" ]; do [ -d "${scratch}" ] || exit 1; sleep 0.05; done\nPATH="${path}"\nexport PATH\neval "$2"\n`);
	chmodSync(shell, 0o755);
	return shell;
}

try {
	// A program only on the late PATH, which starts the test server.
	const tools = join(scratch, "tools");
	mkdirSync(tools);
	writeFileSync(join(tools, "pi2-mcp-late"), `#!/bin/sh\nexec "${process.execPath}" "${serverPath}" late "${startsFile}"\n`);
	chmodSync(join(tools, "pi2-mcp-late"), 0o755);
	const latePath = `${tools}:/usr/bin:/bin`;

	// ---- In the engine's own process: only a PATH that changed starts a server again

	{
		const home = join(scratch, "unit");
		mkdirSync(home);
		writeFileSync(join(home, "mcp.json"), JSON.stringify([{ id: "unit", name: "Unit", transport: "stdio", command: process.execPath, args: [serverPath, "unit", startsFile], enabled: true }]));
		const credentials = { list: async () => [], read: async () => undefined, modify: async () => {}, delete: async () => {} };
		const servers = new McpServers(home, credentials as never);
		const logged: string[] = [];
		servers.log = (...parts) => void logged.push(parts.join(" "));
		const pathBefore = process.env.PATH;
		process.env.PATH = BARE;
		try {
			await servers.start();
			assert.equal(servers.list()[0]!.status, "connected", servers.list()[0]!.error ?? "");
			const [first] = await until("the server to start", () => (starts("unit").length === 1 ? starts("unit") : undefined));
			servers.followPath();
			await sleep(200);
			assert.equal(starts("unit").length, 1, "a server started with the PATH the engine has is not started again");
			process.env.PATH = `${tools}:${BARE}`;
			servers.followPath();
			const second = await until("the server to be started again", () => starts("unit")[1]);
			assert.equal(second.path, process.env.PATH, "it is started with the new PATH");
			await until("the one it replaces to be closed", () => !alive(first!.pid));
			assert.equal(servers.list()[0]!.status, "connected");
			assert.deepEqual(logged, ["MCP server Unit started again with the new PATH"]);
			servers.followPath();
			await sleep(200);
			assert.equal(starts("unit").length, 2, "and only once");
		} finally {
			process.env.PATH = pathBefore;
			await servers.stop();
		}
		step("only a server started with another PATH is started again");
	}

	// ---- A real engine whose login shell answers late

	const home = join(scratch, "home");
	mkdirSync(home);
	writeFileSync(
		join(home, "mcp.json"),
		JSON.stringify([
			{ id: "late", name: "Late", transport: "stdio", command: "pi2-mcp-late", args: [], enabled: true },
			{ id: "early", name: "Early", transport: "stdio", command: process.execPath, args: [serverPath, "early", startsFile], enabled: true },
		]),
	);
	const shellGate = join(scratch, "shell-gate");
	const engine = spawn(process.execPath, [main], {
		env: {
			...process.env,
			PATH: BARE,
			PI2_LOGIN_SHELL: gatedShell(join(scratch, "shell"), shellGate, latePath),
			// The stand-in never answers within this; the engine goes on without it at once.
			PI2_LOGIN_SHELL_TIMEOUT_SECONDS: "1",
			PI2_HOME: home,
			PI2_KEYCHAIN_SERVICE: "dev.pi2.credentials.test-mcppath",
			PI2_DEMO_TOKENS_PER_SECOND: "1000",
		},
		stdio: ["ignore", "ignore", "pipe"],
	});
	engines.push(engine);
	const log: string[] = [];
	let rest = "";
	engine.stderr!.setEncoding("utf8").on("data", (chunk: string) => {
		const all = (rest + chunk).split("\n");
		rest = all.pop()!;
		log.push(...all);
	});
	const logged = (pattern: RegExp) => log.some((line) => pattern.test(line));
	/** Waits for `met`, unless the engine exits first, when it cannot come. */
	const whileUp = <T>(what: string, met: () => T | undefined | false): Promise<T> =>
		until(what, met, { over: () => (running(engine) ? undefined : `the engine exited:\n${log.join("\n")}`) });
	const socket = await listening(engine, home);
	await whileUp("the engine to say it listens", () => logged(/listening on /));
	assert.ok(logged(/PATH not taken from the login shell \(zsh did not answer within 1 second\).*still listening/), log.join("\n"));

	type Item = { kind: string; text?: string; isError?: boolean };
	type Server = { id: string; status: string; error: string | null; tools: { name: string; toolName: string }[] };
	const conversations = new Map<number, { items: Item[]; busy: boolean }>();
	let servers: Server[] = [];
	let next = 1;
	const replies = new Map<number, { resolve: (value: any) => void; reject: (error: Error) => void }>();
	let buffer = "";
	socket.setEncoding("utf8").on("data", (chunk: string) => {
		buffer += chunk;
		const received = buffer.split("\n");
		buffer = received.pop()!;
		for (const line of received) {
			const message = JSON.parse(line);
			if (message.event === "mcp") servers = message.servers;
			else if (message.event === "conversation") {
				const view = conversations.get(message.id) ?? { items: [], busy: false };
				if (message.reset) view.items = [];
				view.items.push(...message.items);
				view.busy = message.state.busy;
				conversations.set(message.id, view);
			} else if (typeof message.id === "number") {
				const reply = replies.get(message.id);
				replies.delete(message.id);
				if (message.error !== undefined) reply?.reject(new Error(message.error));
				else reply?.resolve(message.result);
			}
		}
	});
	const call = (method: string, params: Record<string, unknown> = {}): Promise<any> => {
		const id = next++;
		socket.write(`${JSON.stringify({ id, method, params })}\n`);
		return new Promise((resolve, reject) => replies.set(id, { resolve, reject }));
	};
	const server = (id: string) => servers.find((s) => s.id === id);
	const toolName = (id: string, name: string) => server(id)!.tools.find((tool) => tool.name === name)!.toolName;
	const results = (conversation: number) => (conversations.get(conversation)?.items ?? []).filter((item) => item.kind === "tool");
	/** Calls an MCP tool through the demo model and waits for the answer. */
	const mcpCall = async (conversation: number, tool: string, args: object = {}): Promise<Item> => {
		const before = results(conversation).length;
		await call("submit", { id: conversation, text: `/mcp ${tool} ${JSON.stringify(args)}` });
		return whileUp(`the result of ${tool}`, () => {
			const view = conversations.get(conversation);
			return view !== undefined && !view.busy && results(conversation).length > before && view.items.at(-1)?.kind === "assistant" ? results(conversation).at(-1) : undefined;
		});
	};

	// Before the shell answers: the server whose program is only on its PATH failed; the other runs without it.
	await whileUp("both servers to be tried", () => server("late")?.status === "error" && server("early")?.status === "connected");
	assert.match(server("late")!.error ?? "", /ENOENT|not found/i, server("late")!.error ?? "");
	const [early] = starts("early");
	assert.ok(early !== undefined && !early.path.split(":").includes(tools), `the early server has the usual folders: ${early?.path}`);
	assert.equal(starts("late").length, 0);

	const { id: agent } = await call("agents.save", { agent: { name: "Caller", access: "full", mcpServers: ["late", "early"] } });
	const { id: holding } = await call("conversation.create", { agentId: agent });
	const { id: other } = await call("conversation.create", { agentId: agent });
	await call("conversation.open", { id: holding });
	await call("conversation.open", { id: other });
	const envEarly = toolName("early", "env");
	assert.match((await mcpCall(other, envEarly)).text ?? "", new RegExp(`^${early.pid} `), "the early server answers");

	// A call that is running on the early server when the shell answers.
	const held = join(scratch, "held");
	const callGate = join(scratch, "call-gate");
	await call("submit", { id: holding, text: `/mcp ${toolName("early", "hold")} ${JSON.stringify({ gate: callGate, held })}` });
	await whileUp("the early server to be holding the call", () => existsSync(held) && readFileSync(held, "utf8") !== "");
	assert.equal(Number(readFileSync(held, "utf8")), early.pid);
	step("an engine whose shell is slow starts its MCP servers with the usual folders");

	writeFileSync(shellGate, "");
	await whileUp("the engine to take the late PATH", () => logged(/PATH taken from zsh/));
	const late = await whileUp("the late server to start", () => starts("late")[0]);
	assert.equal(late.path, `${latePath}:/usr/sbin:/sbin`, "the server whose program is on the late PATH is started with it");
	const again = await whileUp("the early server to be started again", () => starts("early")[1]);
	assert.equal(again.path, late.path, "the early server is started again with the late PATH");
	await whileUp("the early server to be swapped in", () => logged(/MCP server Early started again with the new PATH; the one it replaces stops once its calls are done/));
	await whileUp("the late server to connect", () => server("late")?.status === "connected");
	assert.equal(server("early")?.status, "connected");
	assert.ok(logged(/PATH not taken.*still listening/) && !log.some((line) => line.includes(tools)), "the log does not list the shell's folders");

	// The call is still running on the server it started on, and the other conversation already reaches the new one.
	assert.ok(alive(early.pid), "the server the call is running on is left running");
	assert.equal(conversations.get(holding)?.busy, true, "the conversation is still waiting for the call");
	assert.ok(!results(holding).some((item) => item.text?.startsWith("held by")), "and has no answer from it yet");
	assert.equal((await mcpCall(other, envEarly)).text, `${again.pid} ${late.path}`, "a new call goes to the server started with the late PATH");
	assert.equal((await mcpCall(other, toolName("late", "env"))).text, `${late.pid} ${late.path}`, "the late server's tools can be called");
	step("when the shell answers, the failed server connects and the early one is started again beside it");

	writeFileSync(callGate, "");
	const finished = await whileUp("the held call to finish", () => {
		const view = conversations.get(holding);
		return view !== undefined && !view.busy && view.items.at(-1)?.kind === "assistant" ? results(holding).at(-1) : undefined;
	});
	assert.equal(finished.isError, false, finished.text ?? "");
	assert.equal(finished.text, `held by ${early.pid}`, "the call finishes on the server it started on");
	await whileUp("the server it replaced to stop once the call was done", () => !alive(early.pid));
	assert.equal((await mcpCall(holding, envEarly)).text, `${again.pid} ${late.path}`, "the conversation goes on, with the new server");
	assert.equal(starts("early").length + starts("late").length, 3, "nothing else was started");
	step("a call running on the early server is not cut off, and that server stops after it");

	socket.destroy();
	const exited = new Promise<number | null>((resolve) => engine.once("exit", resolve));
	engine.kill("SIGTERM");
	assert.equal(await exited, 0);
	await until("the servers to stop with the engine", () => !alive(again.pid) && !alive(late.pid));
	step("the servers stop with the engine");
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

console.log("mcppath: ok (MCP servers are started again with a slow login shell's PATH)");
