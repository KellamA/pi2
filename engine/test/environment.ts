// The environment of what the engine starts for an agent (src/environment.ts): a real engine on a throwaway data folder,
// itself started with pi²'s own variables set, as the app and the login item start it. A shell command, a background
// command, a worktree's set-up command and an MCP server each write down their environment; none may have the
// variables that configure pi² (issue #195), and the run marker must still be passed on.

import assert from "node:assert/strict";
import { type ChildProcess, execFileSync, spawn } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { commandEnvironment, passedOn } from "../src/environment.ts";
import { EngineClient, stop, until } from "./patience.ts";

// Commits made here use a fixed identity and none of the person's own git settings.
process.env.GIT_CONFIG_GLOBAL = "/dev/null";
process.env.GIT_CONFIG_NOSYSTEM = "1";
Object.assign(process.env, { GIT_AUTHOR_NAME: "Test", GIT_AUTHOR_EMAIL: "test@example.invalid", GIT_COMMITTER_NAME: "Test", GIT_COMMITTER_EMAIL: "test@example.invalid" });

const scratch = realpathSync(mkdtempSync(join(tmpdir(), "pi2-env-")));
const home = join(scratch, "home");
mkdirSync(home);
const main = join(import.meta.dirname, "..", "src", "main.ts");
const engines: ChildProcess[] = [];

function step(name: string): void {
	console.log(`ok  ${name}`);
}

/** An environment as `env` prints it. Values here have no line breaks. */
function parse(text: string): Record<string, string> {
	const env: Record<string, string> = {};
	for (const line of text.split("\n")) {
		const at = line.indexOf("=");
		if (at > 0) env[line.slice(0, at)] = line.slice(at + 1);
	}
	return env;
}
/** The environment a command wrote to `file`, once it has (it writes to another file first, then moves it there). */
const written = (file: string): Promise<Record<string, string>> => until(`${file} to be written`, () => existsSync(file) && parse(readFileSync(file, "utf8")));
/** A command that writes its environment to `file`, whole or not at all. */
const writeEnv = (file: string) => `/usr/bin/env > '${file}.part' && mv '${file}.part' '${file}'`;

// What the engine is started with: pi²'s own variables, as the app and the login item set them and as tests do, and a
// run marker, as an engine started by a set-up or background command has.
const MARKER = "0123456789abcdef0123456789abcdef";
const PI2_OWN = {
	PI2_HOME: home,
	PI2_KEYCHAIN_SERVICE: "dev.pi2.credentials.test-environment",
	PI2_LOGIN_SHELL: "off",
	PI2_DEMO_TOKENS_PER_SECOND: "1000",
	PI2_SHOW: "inbox",
	PI2_WINDOW_BEHIND: "1",
};

try {
	// ---- Which variables are passed on

	{
		const from = { PATH: "/usr/bin:/bin", HOME: "/Users/someone", PI2_HOME: "/data", PI2_KEYCHAIN_SERVICE: "svc", PI2_SHOW: "inbox", PI2_FUTURE: "x", PI2_RUN: MARKER, PI2X: "kept", NOT_PI2_HOME: "kept" };
		assert.deepEqual(commandEnvironment({}, from), { PATH: "/usr/bin:/bin", HOME: "/Users/someone", PI2_RUN: MARKER, PI2X: "kept", NOT_PI2_HOME: "kept" });
		assert.deepEqual(commandEnvironment({ PI2_RUN: "f".repeat(32), LC_ALL: "C" }, from).PI2_RUN, "f".repeat(32), "what is added wins over what is passed on");
		assert.equal(passedOn("PI2_LOGIN_SHELL"), false);
		assert.equal(passedOn("PI2_RUN"), true);
		step("pi²'s own variables are left out, the run marker and everything else passed on");
	}

	// ---- A real engine

	const project = join(scratch, "project");
	mkdirSync(project);
	const git = (...args: string[]) => execFileSync("git", args, { cwd: project, stdio: ["ignore", "pipe", "pipe"] });
	git("init", "-q", "-b", "main");
	writeFileSync(join(project, "README.md"), "hello\n");
	git("add", ".");
	git("commit", "-q", "-m", "first");

	// A test MCP server that writes its environment to a file as it starts.
	const serverFile = join(scratch, "server.env");
	const serverPath = join(scratch, "server.mjs");
	writeFileSync(
		serverPath,
		`
import { renameSync, writeFileSync } from "node:fs";
import { createInterface } from "node:readline";
const file = process.argv[2];
writeFileSync(file + ".part", Object.entries(process.env).map(([name, value]) => name + "=" + value).join("\\n") + "\\n");
renameSync(file + ".part", file);
const reply = (id, result) => process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, result }) + "\\n");
createInterface({ input: process.stdin }).on("line", (line) => {
	const message = JSON.parse(line);
	if (message.method === "initialize") reply(message.id, { protocolVersion: message.params.protocolVersion, capabilities: { tools: {} }, serverInfo: { name: "env", version: "1" } });
	else if (message.method === "tools/list") reply(message.id, { tools: [] });
	else if (message.id !== undefined) reply(message.id, {});
});
`,
	);
	writeFileSync(join(home, "mcp.json"), JSON.stringify([{ id: "env", name: "Env", transport: "stdio", command: process.execPath, args: [serverPath, serverFile], enabled: true }]));

	const engine = spawn(process.execPath, [main], { env: { ...process.env, ...PI2_OWN, PI2_RUN: MARKER, TEST_PASSED_ON: "yes" }, stdio: ["ignore", "ignore", "inherit"] });
	engines.push(engine);
	const client = await EngineClient.connect(engine, home);
	await client.until("first events", () => client.events.providers && client.events.mcp);

	/** Sends a message the demo model answers with a tool call, and waits for the answer after it. */
	const tool = async (id: number, text: string): Promise<any> => {
		const before = client.conversations.get(id)?.items.filter((item: any) => item.kind === "assistant").length ?? 0;
		await client.call("submit", { id, text });
		return await client.until(`the answer to ${text}`, () => {
			const conv = client.conversations.get(id);
			if (conv === undefined || conv.state.busy || conv.items.filter((item: any) => item.kind === "assistant").length <= before) return undefined;
			return conv.items.filter((item: any) => item.kind === "tool").at(-1);
		});
	};

	const setupFile = join(scratch, "setup.env");
	const { id: agent } = await client.call("agents.save", { agent: { name: "Worker", access: "full", cwd: project, worktree: true, setup: writeEnv(setupFile), mcpServers: ["env"] } });
	const { id } = await client.call("conversation.create", { agentId: agent });
	await client.call("conversation.open", { id });

	const shellFile = join(scratch, "shell.env");
	const shellResult = await tool(id, `/bash ${writeEnv(shellFile)}`);
	assert.equal(shellResult.isError, false, shellResult.text);
	const backgroundFile = join(scratch, "background.env");
	await tool(id, `/background ${writeEnv(backgroundFile)}`);

	const seen = { "a shell command": await written(shellFile), "a background command": await written(backgroundFile), "a set-up command": await written(setupFile), "an MCP server": await written(serverFile) };
	for (const [what, env] of Object.entries(seen)) {
		for (const name of Object.keys(PI2_OWN)) assert.equal(env[name], undefined, `${what} does not get ${name}`);
		assert.equal(env.TEST_PASSED_ON, "yes", `${what} gets the engine's other variables`);
		assert.equal(env.PATH, process.env.PATH, `${what} gets the engine's PATH`);
	}
	assert.equal(seen["a shell command"].PI2_RUN, MARKER, "a shell command carries on the marker of the run that started the engine");
	assert.equal(seen["an MCP server"].PI2_RUN, MARKER, "and so does an MCP server");
	for (const what of ["a background command", "a set-up command"] as const) assert.match(seen[what].PI2_RUN ?? "", /^[0-9a-f]{32}$/, `${what} gets a marker`);
	assert.notEqual(seen["a background command"].PI2_RUN, MARKER, "of its own");
	assert.notEqual(seen["a set-up command"].PI2_RUN, MARKER, "of its own");
	step("a shell command, a background command, a set-up command and an MCP server do not get pi²'s own variables");

	client.close();
	await stop(engine);
} finally {
	for (const engine of engines) await stop(engine);
	rmSync(scratch, { recursive: true, force: true });
}

console.log("environment: ok (what an agent's commands are started with)");
