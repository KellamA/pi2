// The environment of what the engine starts for an agent (src/environment.ts): a real engine on a throwaway data folder,
// itself started with pi²'s own variables set, as the app and the login item start it. A shell command, a background
// command, a worktree's set-up command and an MCP server each write down their environment; none may have the
// variables that configure pi² (issue #195), and the run marker must still be passed on. The commands get their
// conversation's scratch folder (src/scratch.ts, issue #180), which a sub-chat has its own of, an archived
// conversation keeps and a deleted one loses.

import assert from "node:assert/strict";
import { type ChildProcess, execFileSync, spawn } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { commandEnvironment, passedOn } from "../src/environment.ts";
import { describeScratch, scratchFolder, scratchGone, scratchRoot, sweepScratch } from "../src/scratch.ts";
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

	// ---- Where scratch folders are, and which are no longer wanted

	{
		const folder = scratchFolder(home, 12);
		assert.match(folder, new RegExp(`^/tmp/pi2-${process.getuid!()}/scratch-[0-9a-f]{8}/12$`));
		assert.ok(Buffer.byteLength(folder) <= 40 && !folder.includes(" "), `short and without spaces: ${folder}`);
		assert.equal(scratchFolder(`${home}/`, 12), folder, "a trailing slash names the same data folder");
		assert.notEqual(scratchRoot(join(scratch, "other")), scratchRoot(home), "another data folder has folders of its own");
		const conversations = { "1": { deleted: true }, "2": {}, "3": { parent: 1 }, "4": { parent: 2 }, "5": { archivedAt: 1 }, "6": { parent: 5 } } as never;
		assert.deepEqual([1, 2, 3, 4, 5, 6, 7].filter((id) => scratchGone(conversations, id)), [1, 3, 7], "deleted, a sub-chat of a deleted one, or unknown; not archived");
		const swept = join(scratch, "swept");
		for (const name of ["1", "2", "notes"]) mkdirSync(join(swept, name), { recursive: true });
		sweepScratch(swept, (id) => id === 1);
		assert.deepEqual([existsSync(join(swept, "1")), existsSync(join(swept, "2")), existsSync(join(swept, "notes"))], [false, true, true], "only a gone conversation's folder is removed");
		step("each conversation's scratch folder has a short path of its own, kept until it is deleted");
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
	const { id: helper } = await client.call("agents.save", { agent: { name: "Helper", access: "full", cwd: project } });
	const { id: agent } = await client.call("agents.save", { agent: { name: "Worker", access: "full", cwd: project, worktree: true, setup: writeEnv(setupFile), mcpServers: ["env"], delegates: [helper] } });
	const { id } = await client.call("conversation.create", { agentId: agent });
	await client.call("conversation.open", { id });
	const { id: other } = await client.call("conversation.create", { agentId: helper });
	await client.call("conversation.open", { id: other });

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
	assert.equal(seen["an MCP server"].PI2_RUN, MARKER, "an MCP server carries on the marker of the run that started the engine");
	for (const what of ["a shell command", "a background command", "a set-up command"] as const) {
		assert.match(seen[what].PI2_RUN ?? "", /^[0-9a-f]{32}$/, `${what} gets a marker`);
		assert.notEqual(seen[what].PI2_RUN, MARKER, `${what} gets a marker of its own`);
	}
	step("a shell command, a background command, a set-up command and an MCP server do not get pi²'s own variables");

	// ---- The scratch folder

	const own = scratchFolder(home, id);
	for (const what of ["a shell command", "a background command", "a set-up command"] as const) assert.equal(seen[what].PI2_SCRATCH, own, `${what} gets the conversation's scratch folder`);
	assert.equal(seen["an MCP server"].PI2_SCRATCH, undefined, "an MCP server, which no one conversation has, gets none");
	assert.ok(statSync(own).isDirectory(), "it is there");
	assert.equal(statSync(own).mode & 0o777, 0o700, "and only this user can open it");
	assert.equal(statSync(join(own, "..", "..")).mode & 0o777, 0o700, "nor the folder it is in");
	assert.equal((await tool(id, `/bash echo kept > "$PI2_SCRATCH/note"`)).isError, false);
	assert.equal((await tool(id, `/bash cat "$PI2_SCRATCH/note"`)).text.trim(), "kept", "what one command leaves there the next finds");
	rmSync(own, { recursive: true });
	assert.equal((await tool(id, `/bash test -d "$PI2_SCRATCH" && echo there`)).text.trim(), "there", "a folder taken away (as macOS clears old ones in /tmp) is made again for the next command");
	const told = await tool(id, "/system scratch");
	void told;
	const system = client.conversations.get(id).items.filter((item: any) => item.kind === "assistant").at(-1).text as string;
	assert.ok(system.includes(describeScratch(own)), `the system prompt names it: ${system}`);
	step("a conversation's commands get a scratch folder of its own, named in the system prompt, kept between commands");

	const subFile = join(scratch, "sub.env");
	const handed = await tool(id, `/delegate Helper: /bash ${writeEnv(subFile)}`);
	const sub = handed.details.conversationId as number;
	assert.equal(typeof sub, "number", JSON.stringify(handed));
	assert.equal((await written(subFile)).PI2_SCRATCH, scratchFolder(home, sub), "a sub-chat gets a scratch folder of its own");
	assert.notEqual(scratchFolder(home, sub), own);

	// Archived, a conversation can be restored, so it keeps its folder; deleted, it and its sub-chat's go.
	await client.call("conversation.archive", { id });
	// The engine looks at the folders before it sends the apps the list that has it archived.
	await client.until("archived", () => client.events.library?.archived?.some((each: any) => each.id === id));
	await tool(other, "/bash true");
	assert.ok(existsSync(own) && existsSync(scratchFolder(home, sub)), "an archived conversation keeps its scratch folder, and its sub-chat's");
	await client.call("conversation.delete", { id });
	await until("the deleted conversation's scratch folders to go", () => !existsSync(own) && !existsSync(scratchFolder(home, sub)));
	assert.ok(existsSync(scratchFolder(home, other)), "another conversation's is left alone");
	step("a sub-chat has its own; archiving keeps them, deleting removes them");

	client.close();
	await stop(engine);
} finally {
	for (const engine of engines) await stop(engine);
	rmSync(scratch, { recursive: true, force: true });
	rmSync(scratchRoot(home), { recursive: true, force: true });
}

console.log("environment: ok (what an agent's commands are started with)");
