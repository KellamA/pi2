
// An MCP server run as a program has environment variables of its own (src/mcp.ts, issue #273), kept as an agent's are
// (src/variables.ts, issue #96): values in a Keychain service of this run's own, never in mcp.json or a backup; the
// same names refused; a change starts the server again without cutting off a call running on it (#138); removing the
// server removes its values. The stand-in server reports the environment it was started with, through a tool and in a
// file it writes as it starts, and has a tool that answers only once a file is there.

import assert from "node:assert/strict";
import { type ChildProcess, spawn, spawnSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { KeychainObjects } from "../src/credentials.ts";
import { McpServers, serverVariablesAccount } from "../src/mcp.ts";
import { socketPathFor } from "../src/socket.ts";
import { refusal, VariableValues } from "../src/variables.ts";
import { EngineClient, standInApp, stop, until } from "./patience.ts";
// The engine takes changes to what the person set only from its app's connection (#513): this test's connection stands
// for the app's, as the tests that answer for the person already do (#504).
process.env.PI2_APP_BUNDLE = standInApp();

const scratch = realpathSync(mkdtempSync(join(tmpdir(), "pi2-mcpvariables-")));
const main = join(import.meta.dirname, "..", "src", "main.ts");
// This run's own, never the real one, so that runs side by side do not share values.
const SERVICE = `dev.pi2.credentials.test-mcpvariables-${process.pid}`;
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
function starts(name: string): { name: string; pid: number }[] {
	const lines = existsSync(startsFile) ? readFileSync(startsFile, "utf8").split("\n").filter((line) => line !== "") : [];
	return lines.map((line) => line.split(" ")).map(([server, pid]) => ({ name: server!, pid: Number(pid) })).filter((start) => start.name === name);
}
/** The environment the server process `pid` was started with, as it wrote it down. */
const envOf = (pid: number): Record<string, string> => JSON.parse(readFileSync(join(scratch, `env-${pid}.json`), "utf8"));
const keychain = (account: string) => spawnSync("/usr/bin/security", ["find-generic-password", "-s", SERVICE, "-a", account, "-w"], { encoding: "utf8" });
/** Every file under `folder` that holds `text`. */
const holding = (folder: string, text: string): string[] =>
	readdirSync(folder, { recursive: true, withFileTypes: true })
		.filter((entry) => entry.isFile() && readFileSync(join(entry.parentPath, entry.name)).includes(text))
		.map((entry) => join(entry.parentPath, entry.name));

// `node server.mjs <name> <starts file> <scratch>`: writes its environment to env-<pid>.json, then says it started;
// answers `env` with its environment, and `hold` once the file named in its arguments is there (saying first, in the
// file `held`, that it holds).
const serverPath = join(scratch, "server.mjs");
writeFileSync(
	serverPath,
	`
import { appendFileSync, existsSync, renameSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { createInterface } from "node:readline";
const [name, startsFile, folder] = process.argv.slice(2);
const envFile = join(folder, "env-" + process.pid + ".json");
writeFileSync(envFile + ".part", JSON.stringify(process.env));
renameSync(envFile + ".part", envFile);
appendFileSync(startsFile, name + " " + process.pid + "\\n");
const reply = (id, result) => process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, result }) + "\\n");
const text = (id, value) => reply(id, { content: [{ type: "text", text: value }] });
const schema = { type: "object", properties: { gate: { type: "string" }, held: { type: "string" } } };
createInterface({ input: process.stdin }).on("line", (line) => {
	const message = JSON.parse(line);
	if (message.method === "initialize") reply(message.id, { protocolVersion: message.params.protocolVersion, capabilities: { tools: {} }, serverInfo: { name, version: "1" } });
	else if (message.method === "tools/list") reply(message.id, { tools: [
		{ name: "env", description: "Say what this process sees", inputSchema: schema, annotations: { readOnlyHint: true } },
		{ name: "hold", description: "Answer once a file is there", inputSchema: schema, annotations: { readOnlyHint: true } },
	] });
	else if (message.method === "tools/call" && message.params.name === "env") text(message.id, JSON.stringify({ pid: process.pid, env: process.env }));
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
const serverConfig = (id: string, name: string) => ({ id, name, transport: "stdio", command: process.execPath, args: [serverPath, id, startsFile, scratch], enabled: true });

try {
	// ---- In the engine's own process, calling the tools as a conversation would

	{
		const home = join(scratch, "unit");
		mkdirSync(home);
		writeFileSync(join(home, "mcp.json"), JSON.stringify([serverConfig("tok", "Tok"), { id: "web", name: "Web", transport: "http", url: "https://mcp.example.invalid/mcp", enabled: false }]));
		const credentials = { list: async () => [], read: async () => undefined, modify: async () => {}, delete: async () => {} };
		const open = () => new McpServers(home, credentials as never, new VariableValues(new KeychainObjects(SERVICE)));
		let servers = open();
		const logged: string[] = [];
		servers.log = (...parts) => void logged.push(parts.join(" "));
		const server = (id: string) => servers.list().find((s) => s.id === id)!;
		/** Calls tool `name` of server `id` the way the engine runs a tool, through the extension as it is now. */
		const callTool = async (id: string, name: string, args: object = {}): Promise<string> => {
			const toolName = server(id).tools.find((tool) => tool.name === name)!.toolName;
			const registration = servers.extension().tools!.find((tool) => tool.name === toolName) as any;
			const result = await registration.execute(args, {}, { abortSignal: new AbortController().signal });
			assert.equal(result.isError, false);
			return result.output.map((block: { text: string }) => block.text).join("");
		};
		/** What the server answering now sees. */
		const seen = async (): Promise<{ pid: number; env: Record<string, string> }> => JSON.parse(await callTool("tok", "env"));
		const saved = () => JSON.parse(readFileSync(join(home, "mcp.json"), "utf8")).find((config: { id: string }) => config.id === "tok");
		const TOKEN = `token-${randomUUID()}`;
		try {
			await servers.start();
			assert.equal(server("tok").status, "connected", server("tok").error ?? "");
			const [first] = starts("tok");
			assert.equal(envOf(first!.pid).SERVER_TOKEN, undefined);

			// Set with a call running on the copy that has none.
			const call = { held: join(scratch, "held-1"), gate: join(scratch, "gate-1") };
			const held = callTool("tok", "hold", call);
			held.catch(() => {});
			await until("the server to hold the call", () => existsSync(call.held) && readFileSync(call.held, "utf8") !== "");
			await servers.setVariable("tok", " SERVER_TOKEN ", TOKEN);
			const now = await seen();
			assert.notEqual(now.pid, first!.pid, "setting a variable starts the server again");
			assert.equal(now.env.SERVER_TOKEN, TOKEN, "and the new copy gets it");
			assert.equal(envOf(now.pid).SERVER_TOKEN, TOKEN, "from the moment it starts");
			assert.ok(alive(first!.pid), "the copy the call is running on is left running");
			writeFileSync(call.gate, "");
			assert.equal(await held, `held by ${first!.pid}`, "and the call finishes there");
			await until("the replaced copy to stop once its call is done", () => !alive(first!.pid));
			step("setting a server's variable starts it again with it, without cutting off a call running on it");

			assert.deepEqual(server("tok").variables, [{ name: "SERVER_TOKEN", set: true }], "the server's settings list the name, and that it has a value");
			assert.ok(!JSON.stringify(servers.list()).includes(TOKEN), "the app is never sent a value");
			assert.deepEqual(saved().variables, [{ name: "SERVER_TOKEN", set: true }], "mcp.json holds the name");
			assert.deepEqual(holding(home, TOKEN), [], "but no file in the data folder holds the value");
			assert.ok(keychain(serverVariablesAccount("tok")).stdout.includes(TOKEN), "which is in the Keychain, under the engine's service");
			step("a server's variable's value is in the Keychain, and only its name in mcp.json");

			for (const name of ["PATH", "PI2_SCRATCH", "BASH_ENV", "DYLD_INSERT_LIBRARIES", "NOT-A-NAME"]) {
				await assert.rejects(servers.setVariable("tok", name, "x"), (error: Error) => error.message === refusal(name), `${name} is refused, saying why`);
			}
			await assert.rejects(servers.setVariable("tok", "OK_NAME", "a\0b"), /NUL/);
			await assert.rejects(servers.setVariable("web", "OK_NAME", "x"), /Only a server pi² runs as a program has variables/);
			await assert.rejects(servers.setVariable("nope", "OK_NAME", "x"), /Unknown server: nope/);
			assert.deepEqual(server("tok").variables, [{ name: "SERVER_TOKEN", set: true }], "nothing refused was kept");
			step("the names an agent's variables may not have are refused for a server too, saying why");

			await servers.setVariable("tok", "SERVER_TOKEN", `${TOKEN}-new`);
			await servers.setVariable("tok", "SPACED", "two words and 'quotes'");
			let env = (await seen()).env;
			assert.equal(env.SERVER_TOKEN, `${TOKEN}-new`, "a value replaced counts from the next start");
			assert.equal(env.SPACED, "two words and 'quotes'", "each value is given as it was set");
			await servers.removeVariable("tok", "SPACED");
			env = (await seen()).env;
			assert.equal(env.SPACED, undefined, "a variable removed is no longer given");
			assert.ok(!keychain(serverVariablesAccount("tok")).stdout.includes("two words"), "and its value is gone from the Keychain");
			assert.deepEqual(server("tok").variables, [{ name: "SERVER_TOKEN", set: true }]);
			step("a server's variable can be replaced, and removed with its value");

			await servers.save({ id: "tok", name: "Tok again", transport: "stdio", command: process.execPath, args: serverConfig("tok", "Tok").args });
			assert.deepEqual(server("tok").variables, [{ name: "SERVER_TOKEN", set: true }], "saving the server's other settings keeps its variables");
			assert.equal((await seen()).env.SERVER_TOKEN, `${TOKEN}-new`);
			step("saving a server's other settings keeps its variables");

			// A value the Keychain does not hold (a backup restored elsewhere): shown as not set once the engine starts again.
			await servers.setVariable("tok", "GONE", "soon");
			await servers.stop();
			await new KeychainObjects(SERVICE).write(serverVariablesAccount("tok"), { SERVER_TOKEN: `${TOKEN}-new` });
			servers = open();
			servers.log = (...parts) => void logged.push(parts.join(" "));
			await servers.start();
			assert.equal(server("tok").status, "connected", server("tok").error ?? "");
			assert.deepEqual(server("tok").variables, [{ name: "SERVER_TOKEN", set: true }, { name: "GONE", set: false }], "a value the Keychain lacks shows as not set");
			assert.deepEqual(saved().variables, [{ name: "SERVER_TOKEN", set: true }, { name: "GONE", set: false }], "in mcp.json too");
			assert.ok(logged.includes("MCP server Tok again: some of its variables had no value in the Keychain, and are shown as not set"), logged.join("\n"));
			env = (await seen()).env;
			assert.equal(env.SERVER_TOKEN, `${TOKEN}-new`);
			assert.equal(env.GONE, undefined);
			step("a variable whose value the Keychain lacks is shown as not set when the engine starts");

			const last = (await seen()).pid;
			await servers.remove("tok");
			assert.equal(keychain(serverVariablesAccount("tok")).status, 44, "removing a server removes its values from the Keychain");
			await until("the removed server to stop", () => !alive(last));
			step("removing a server removes its values from the Keychain");

			// Added with its variables (#298): checked first, kept in the Keychain, and the server started once, with them.
			const adding = { name: "Added", transport: "stdio", command: process.execPath, args: [serverPath, "added", startsFile, scratch] };
			const ADDED = `added-${randomUUID()}`;
			await assert.rejects(servers.save({ ...adding, variables: [{ name: "PATH", value: "x" }] }), (error: Error) => error.message === refusal("PATH"));
			await assert.rejects(servers.save({ ...adding, variables: [{ name: "A", value: "1" }, { name: " A ", value: "2" }] }), /A is given twice/);
			await assert.rejects(servers.save({ ...adding, variables: [{ name: "A", value: "a\0b" }] }), /NUL/);
			await assert.rejects(servers.save({ name: "Remote", transport: "http", url: "https://mcp.example.invalid/mcp", variables: [{ name: "A", value: "1" }] }), /Only a server pi² runs as a program/);
			await assert.rejects(servers.save({ ...adding, id: "web", variables: [{ name: "A", value: "1" }] }), /Variables…/);
			assert.equal(server("added"), undefined, "nothing refused was added");
			assert.deepEqual(starts("added"), [], "or started");
			const { id: addedId } = await servers.save({ ...adding, variables: [{ name: "SERVER_TOKEN", value: ADDED }, { name: "OTHER", value: "two words" }] });
			assert.equal(addedId, "added");
			assert.equal(server("added").status, "connected", server("added").error ?? "");
			const addedStarts = starts("added");
			assert.equal(addedStarts.length, 1, "the server is started once");
			assert.equal(envOf(addedStarts[0]!.pid).SERVER_TOKEN, ADDED, "with its variables from the first start");
			assert.equal(envOf(addedStarts[0]!.pid).OTHER, "two words");
			assert.deepEqual(server("added").variables, [{ name: "SERVER_TOKEN", set: true }, { name: "OTHER", set: true }]);
			const addedSaved = JSON.parse(readFileSync(join(home, "mcp.json"), "utf8")).find((config: { id: string }) => config.id === "added");
			assert.deepEqual(addedSaved.variables, [{ name: "SERVER_TOKEN", set: true }, { name: "OTHER", set: true }], "mcp.json holds the names");
			assert.deepEqual(holding(home, ADDED), [], "and no file in the data folder the value");
			assert.ok(keychain(serverVariablesAccount("added")).stdout.includes(ADDED), "which is in the Keychain");
			await servers.remove("added");
			assert.equal(keychain(serverVariablesAccount("added")).status, 44);
			step("a server can be added with its variables, which it is started with from the first start");
		} finally {
			await servers.stop();
		}
	}

	// ---- A real engine, driven as the app drives it

	const home = join(scratch, "home");
	mkdirSync(home);
	writeFileSync(join(home, "mcp.json"), JSON.stringify([serverConfig("e", "E")]));
	const engine = spawn(process.execPath, [main], {
		env: { ...process.env, PI2_HOME: home, PI2_KEYCHAIN_SERVICE: SERVICE, PI2_LOGIN_SHELL: "off", PI2_DEMO_TOKENS_PER_SECOND: "1000" },
		stdio: ["ignore", "ignore", "inherit"],
	});
	engines.push(engine);
	const client = await EngineClient.connect(engine, home);
	const server = () => (client.events.mcp?.servers ?? []).find((s: { id: string }) => s.id === "e");
	await client.until("the server to connect", () => server()?.status === "connected");
	const TOKEN = `token-${randomUUID()}`;
	await client.call("mcp.setVariable", { id: "e", name: "E_TOKEN", value: TOKEN });
	await assert.rejects(client.call("mcp.setVariable", { id: "e", name: "PI2_HOME", value: "x" }), (error: Error) => error.message === refusal("PI2_HOME"));
	await client.until("the server to start again", () => server()?.status === "connected" && starts("e").length === 2);
	assert.equal(envOf(starts("e")[1]!.pid).E_TOKEN, TOKEN, "the server started again gets the variable");
	assert.deepEqual(server().variables, [{ name: "E_TOKEN", set: true }], "the app is sent the name");
	assert.ok(!JSON.stringify(client.events.mcp).includes(TOKEN), "never the value");
	const { path: backupPath } = await client.call("backup.create", { directory: scratch });
	assert.deepEqual(holding(home, TOKEN), [], "no file in the data folder holds the value");
	assert.deepEqual(holding(backupPath, TOKEN), [], "nor does a backup");
	assert.ok(holding(backupPath, "E_TOKEN").length > 0, "which does hold the name");
	await client.call("mcp.removeVariable", { id: "e", name: "E_TOKEN" });
	await client.until("the server to start again without it", () => server()?.status === "connected" && starts("e").length === 3);
	assert.equal(envOf(starts("e")[2]!.pid).E_TOKEN, undefined);
	assert.equal(keychain(serverVariablesAccount("e")).status, 44, "the last value removed takes the Keychain item with it");
	await client.call("mcp.setVariable", { id: "e", name: "E_TOKEN", value: TOKEN });
	await client.call("mcp.delete", { id: "e" });
	assert.equal(keychain(serverVariablesAccount("e")).status, 44, "removing the server in the app removes its values");
	step("the app sets and removes a server's variables, is sent only their names, and a backup holds no value");

	client.close();
	await stop(engine);
} finally {
	for (const engine of engines) await stop(engine);
	const reached = socketPathFor(join(scratch, "home"));
	if (reached !== join(scratch, "home", "engine.sock")) rmSync(join(reached, ".."), { force: true });
	for (const name of ["tok", "e"]) {
		for (const { pid } of starts(name)) if (alive(pid) && spawnSync("/bin/ps", ["-o", "command=", "-p", String(pid)], { encoding: "utf8" }).stdout.includes(serverPath)) process.kill(pid, "SIGKILL");
		// Whatever was left in this run's Keychain service, should a check have failed before it was removed.
		const account = serverVariablesAccount(name);
		spawnSync("/usr/bin/security", ["delete-generic-password", "-s", SERVICE, "-a", account]);
		for (let i = 0; i < 4; i++) spawnSync("/usr/bin/security", ["delete-generic-password", "-s", SERVICE, "-a", `${account}:${i}`]);
	}
	rmSync(scratch, { recursive: true, force: true });
}

console.log("mcpvariables: ok (an MCP server's own variables)");
