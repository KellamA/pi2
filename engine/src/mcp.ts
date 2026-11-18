// MCP servers: external tool providers the person connects, offered to the agents they choose.

import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { CredentialStore } from "@earendil-works/pi-ai";
import { defineExtension, defineTool, type Extension, type ToolRegistration } from "@earendil-works/pi-durable";
import {
	createMcpToolName,
	limitMcpContent,
	McpClient,
	type McpTransport,
	normalizeMcpInputSchema,
	StdioTransport,
	StreamableHttpTransport,
	toLlmContent,
} from "@earendil-works/pi-mcp";
import { commandEnvironment } from "./environment.ts";
import { fromShell } from "./shellpath.ts";
import type { AgentVariable } from "./state.ts";
import { MAX_VARIABLES, VariableValues, variableName, variableValue, withValue } from "./variables.ts";

/**
 * The Keychain item a server's variables are kept in, under the service sign-ins are kept under (variables.ts). "/" is
 * not allowed in a provider id, so it is never mistaken for one, nor for an agent's `variables/<agent id>`.
 */
export const serverVariablesAccount = (serverId: string): string => `mcp-variables/${serverId}`;

export type McpServerConfig = {
	id: string;
	name: string;
	transport: "stdio" | "http";
	/** stdio: the program and its arguments. */
	command?: string;
	args?: string[];
	/**
	 * stdio: environment variables of its own (issue #273): names, and whether each has a value. The values are in the
	 * Keychain (`serverVariablesAccount`), never here. Changed only through `setVariable` and `removeVariable`.
	 */
	variables?: AgentVariable[];
	/** http: the server's URL. A bearer token, when set, is kept in the Keychain, not here. */
	url?: string;
	enabled: boolean;
};

export type McpToolInfo = { name: string; toolName: string; description: string; readOnly: boolean };
export type McpServerStatus = McpServerConfig & { status: "connected" | "connecting" | "off" | "error"; error: string | null; hasToken: boolean; tools: McpToolInfo[] };

/**
 * How long a copy of a server that another has replaced may keep running for a call still going on it. A call usually
 * ends far sooner (a request times out after a minute without word from the server), but one the server keeps reporting
 * progress on has no end of its own.
 */
export const LINGER_MS = 10 * 60_000;

/** A server process (or HTTP session) the engine is talking to, and how many tool calls it is answering right now. */
type Connection = {
	/** The id of the server it is a copy of. */
	server: string;
	client: McpClient;
	calls: number;
	retired: boolean;
	/** Why it was closed, for a call it cut off: set once it is closed, by the engine or on its own. */
	ended?: string;
	/** Closes it, retired with a call still running, once that has gone on for `lingerMs`. */
	linger?: NodeJS.Timeout;
};
type Live = {
	connection?: Connection;
	status: McpServerStatus["status"];
	error: string | null;
	tools: McpToolInfo[];
	registrations: ToolRegistration[];
	/**
	 * A server run as a program: what of its environment came from the login shell (its PATH and SSH_AUTH_SOCK,
	 * shellpath.ts `fromShell`), which it and whatever it starts keep.
	 */
	path?: string;
};
type Opened = { connection: Connection; tools: McpToolInfo[]; registrations: ToolRegistration[] };

export class McpServers {
	readonly #path: string;
	readonly #credentials: CredentialStore;
	readonly #values: VariableValues;
	#configs: McpServerConfig[];
	readonly #live = new Map<string, Live>();
	readonly #tokens = new Set<string>();
	/** Every connection still open, current or retired, so that stopping closes them all. */
	readonly #connections = new Set<Connection>();
	/** Servers being started again with a new PATH, so that each is started again once at a time. */
	readonly #restarting = new Set<string>();
	#stopped = false;
	/** Called whenever a server's status or tools change. */
	onChange: () => void = () => {};
	/** Where to say what was done without being asked: a server started again with a new PATH, a call cut off. */
	log: (...parts: unknown[]) => void = () => {};
	/** How long a replaced copy of a server may keep running for a call still going on it (tests make it short). */
	lingerMs = LINGER_MS;

	constructor(home: string, credentials: CredentialStore, values = new VariableValues()) {
		this.#path = join(home, "mcp.json");
		this.#credentials = credentials;
		this.#values = values;
		try {
			this.#configs = JSON.parse(readFileSync(this.#path, "utf8"));
		} catch {
			this.#configs = [];
		}
	}

	async start(): Promise<void> {
		for (const info of await this.#credentials.list()) if (info.providerId.startsWith("mcp-")) this.#tokens.add(info.providerId.slice(4));
		await Promise.all(
			this.#configs.map(async (config) => {
				await this.#checkVariables(config);
				const current = this.#configs.find((c) => c.id === config.id);
				if (current !== undefined) await this.#connect(current);
			}),
		);
	}

	list(): McpServerStatus[] {
		return this.#configs.map((config) => {
			const live = this.#live.get(config.id);
			return { ...config, status: live?.status ?? "off", error: live?.error ?? null, hasToken: this.#tokens.has(config.id), tools: live?.tools ?? [] };
		});
	}

	/** The extension holding every connected server's tools. Installing it again replaces the previous one. */
	extension(): Extension {
		return defineExtension({ name: "pi2.mcp", tools: [...this.#live.values()].flatMap((live) => live.registrations) });
	}

	/** Tool names of the given servers, for an agent's tool list. */
	toolNames(serverIds: readonly string[]): string[] {
		return serverIds.flatMap((id) => this.#live.get(id)?.tools.map((tool) => tool.toolName) ?? []);
	}

	/** Whether a tool is an MCP tool whose server did not mark it read-only; those wait for approval like commands do. */
	changesThings(toolName: string): boolean {
		for (const live of this.#live.values()) {
			const tool = live.tools.find((t) => t.toolName === toolName);
			if (tool !== undefined) return !tool.readOnly;
		}
		return false;
	}

	/**
	 * Add or change a server. A new server run as a program can be given `variables` too (issue #298), names with their
	 * values: they are checked, the values put in the Keychain, and the server started once, with them. An existing
	 * server's variables change through their own requests, and saving it keeps them.
	 */
	async save(input: {
		id?: string;
		name: string;
		transport: string;
		command?: string;
		args?: string[];
		url?: string;
		enabled?: boolean;
		token?: string;
		variables?: { name: unknown; value: unknown }[];
	}): Promise<McpServerConfig> {
		const name = input.name.trim();
		if (name === "") throw new Error("Give the server a name");
		if (input.transport !== "stdio" && input.transport !== "http") throw new Error("Choose how to reach the server");
		if (input.transport === "stdio" && (input.command ?? "").trim() === "") throw new Error("Enter the command that starts the server");
		if (input.transport === "http" && !/^https?:\/\/\S+$/.test((input.url ?? "").trim())) throw new Error("The URL must start with http:// or https://");
		const given = this.#givenVariables(input);
		let id = input.id;
		if (id === undefined) {
			const slug = name.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "") || "server";
			id = slug;
			for (let n = 2; this.#configs.some((c) => c.id === id); n++) id = `${slug}-${n}`;
		} else if (!this.#configs.some((c) => c.id === id)) {
			throw new Error(`Unknown server: ${id}`);
		}
		// Its variables are kept as they are: they change through their own requests.
		let variables = this.#configs.find((c) => c.id === id)?.variables;
		if (given.length > 0) {
			// The values first, so mcp.json never names one the Keychain does not hold. A new id starts with no item: one
			// left by a server of the same name removed by hand is not inherited.
			const account = serverVariablesAccount(id);
			try {
				await this.#values.forget(account);
				for (const { name, value } of given) await this.#values.set(account, name, value);
			} catch (error) {
				await this.#values.forget(account).catch(() => {});
				throw new Error(`The server was not added: its variables could not be kept in the Keychain (${error instanceof Error ? error.message : String(error)}).`);
			}
			variables = given.map(({ name }) => ({ name, set: true }));
		}
		const config: McpServerConfig = {
			id,
			name,
			transport: input.transport,
			...(input.transport === "stdio" ? { command: input.command!.trim(), args: (input.args ?? []).filter((a) => a !== "") } : { url: input.url!.trim() }),
			...(variables !== undefined && variables.length > 0 ? { variables } : {}),
			enabled: input.enabled ?? true,
		};
		if (input.token !== undefined && input.token.trim() !== "") {
			await this.#credentials.modify(`mcp-${id}`, async () => ({ type: "api_key", key: input.token!.trim() }));
			this.#tokens.add(id);
		}
		this.#configs = [...this.#configs.filter((c) => c.id !== id), config];
		this.#persist();
		await this.#connect(config);
		return config;
	}

	/**
	 * The person asked for the server to go, so it goes at once, with every copy of it still running: a call running on
	 * one ends with an error that says why, rather than finishing on a server that is no longer there.
	 */
	async remove(id: string): Promise<void> {
		const config = this.#configs.find((c) => c.id === id);
		if (config === undefined) throw new Error(`Unknown server: ${id}`);
		// Its values first, so that a server whose values could not be removed is still there to try again with.
		if ((config.variables ?? []).length > 0) {
			try {
				await this.#values.forget(serverVariablesAccount(id));
			} catch (error) {
				throw new Error(`The server was not removed: its variables could not be removed from the Keychain (${error instanceof Error ? error.message : String(error)}).`);
			}
		}
		const current = this.#configs.find((c) => c.id === id);
		// Removed meanwhile, by another request.
		if (current === undefined) return;
		this.#live.delete(id);
		this.#configs = this.#configs.filter((c) => c.id !== id);
		this.#persist();
		this.onChange();
		await this.#end(current, "removed");
		if (this.#tokens.delete(id)) await this.#credentials.delete(`mcp-${id}`);
	}

	/**
	 * Set or replace the value of one of the variables of a server run as a program, adding the name if it is new, and
	 * start the server again with it, as saving it does: a call running on the copy it replaces is not cut off.
	 */
	async setVariable(id: string, rawName: unknown, rawValue: unknown): Promise<void> {
		const config = this.#stdio(id);
		const name = variableName(rawName);
		const value = variableValue(rawValue);
		const list = config.variables ?? [];
		if (!list.some((variable) => variable.name === name) && list.length >= MAX_VARIABLES) throw new Error(`A server can have ${MAX_VARIABLES} variables at most.`);
		// The value first: mcp.json never says there is one that the Keychain does not hold.
		await this.#values.set(serverVariablesAccount(id), name, value);
		await this.#connect(this.#changeVariables(id, (current) => withValue(current, name)));
	}

	/** Remove one of a server's variables, its value with it, and start the server again without it. */
	async removeVariable(id: string, name: unknown): Promise<void> {
		this.#stdio(id);
		if (typeof name !== "string") throw new Error("Say which variable to remove.");
		// The name first: from then on the server is not started with it, even if the Keychain cannot be changed now.
		const config = this.#changeVariables(id, (current) => current.filter((variable) => variable.name !== name));
		try {
			await this.#values.remove(serverVariablesAccount(id), name);
		} finally {
			await this.#connect(config);
		}
	}

	/**
	 * Start the server again, as saving it does. The copy running, if any, goes on answering until the new one has
	 * connected and listed its tools, and is then closed once no call is left on it (or after `lingerMs`), so a call
	 * running on it is not cut off and its tools do not drop out meanwhile. If the new one fails, the server shows why,
	 * and the old copy is closed in the same way.
	 */
	async reconnect(id: string): Promise<void> {
		const config = this.#configs.find((c) => c.id === id);
		if (config === undefined) throw new Error(`Unknown server: ${id}`);
		await this.#connect(config);
	}

	/**
	 * The PATH the engine gives what it starts has changed: the login shell was too slow for start-up and its PATH was
	 * taken when it came (shellpath.ts), with its SSH_AUTH_SOCK. Bring every server run as a program that was started
	 * with another PATH or SSH_AUTH_SOCK onto them, so that it ends up as a quicker start would have left it (issue #98):
	 *
	 * - one that failed to start (its program may only be on the new PATH) is connected again; nothing is using it;
	 * - one that is connected is started again alongside the one running, and put in its place only once it has
	 *   connected and listed its tools. Its tools never drop out meanwhile, and a call already running finishes on the
	 *   process that started it, which is closed once no call is left on it. If it fails to start with the new PATH,
	 *   the one running is kept, as it was;
	 * - one still connecting is looked at again once it has connected or failed.
	 *
	 * A server started with the PATH the engine has now is left alone, so a PATH that did not change restarts nothing.
	 */
	followPath(): void {
		for (const config of this.#configs) this.#follow(config);
	}

	async stop(): Promise<void> {
		this.#stopped = true;
		await Promise.all([...this.#connections].map((connection) => this.#close(connection, "pi² stopped while this call was running, so the call was stopped.")));
	}

	/** The variables a new server is added with, checked as `setVariable` checks one, before anything is kept. */
	#givenVariables(input: { id?: string; transport: string; variables?: unknown }): { name: string; value: string }[] {
		if (input.variables === undefined) return [];
		if (!Array.isArray(input.variables)) throw new Error("The variables must be a list of names and values.");
		if (input.variables.length === 0) return [];
		if (input.id !== undefined) throw new Error("Change an existing server's variables with Variables…, not by saving it.");
		if (input.transport !== "stdio") throw new Error("Only a server pi² runs as a program has variables.");
		if (input.variables.length > MAX_VARIABLES) throw new Error(`A server can have ${MAX_VARIABLES} variables at most.`);
		const seen = new Set<string>();
		return input.variables.map((variable: { name?: unknown; value?: unknown } | null) => {
			const name = variableName(variable?.name);
			if (seen.has(name)) throw new Error(`${name} is given twice.`);
			seen.add(name);
			return { name, value: variableValue(variable?.value) };
		});
	}

	/** A server run as a program, the only kind that has variables. */
	#stdio(id: string): McpServerConfig {
		const config = this.#configs.find((c) => c.id === id);
		if (config === undefined) throw new Error(`Unknown server: ${id}`);
		if (config.transport !== "stdio") throw new Error("Only a server pi² runs as a program has variables.");
		return config;
	}

	/** Change a server's list of variables in mcp.json, and return its configuration as it is then, to start it again with. */
	#changeVariables(id: string, change: (list: AgentVariable[]) => AgentVariable[]): McpServerConfig {
		// As it is now: it may have been saved again or removed while the Keychain was being changed.
		const current = this.#configs.find((c) => c.id === id);
		if (current === undefined) throw new Error(`Unknown server: ${id}`);
		const config: McpServerConfig = { ...current, variables: change(current.variables ?? []) };
		if (config.variables!.length === 0) delete config.variables;
		this.#configs = this.#configs.map((c) => (c.id === id ? config : c));
		this.#persist();
		return config;
	}

	/**
	 * A server whose mcp.json says a variable has a value the Keychain does not hold (a backup restored on another Mac or
	 * in another copy of pi², or an item removed by hand) is put right, so the settings do not show a value that is not
	 * there. If the Keychain cannot be read, it is left as it is, and starting the server says why.
	 */
	async #checkVariables(config: McpServerConfig): Promise<void> {
		if (!(config.variables ?? []).some((variable) => variable.set)) return;
		try {
			const kept = await this.#values.read(serverVariablesAccount(config.id));
			if (config.variables!.every((variable) => !variable.set || variable.name in kept)) return;
			const current = this.#configs.find((c) => c.id === config.id);
			if (current === undefined) return;
			const fixed = { ...current, variables: (current.variables ?? []).map((variable) => ({ ...variable, set: variable.set && variable.name in kept })) };
			this.#configs = this.#configs.map((c) => (c.id === config.id ? fixed : c));
			this.#persist();
			this.log(`MCP server ${config.name}: some of its variables had no value in the Keychain, and are shown as not set`);
		} catch (error) {
			this.log(`MCP server ${config.name}: its variables could not be read from the Keychain:`, error instanceof Error ? error.message : error);
		}
	}

	/** The variables a server run as a program is started with. Throws when they cannot be read, rather than start it without them. */
	async #variablesOf(config: McpServerConfig): Promise<Record<string, string>> {
		const wanted = (config.variables ?? []).filter((variable) => variable.set);
		if (wanted.length === 0) return {};
		let kept: Record<string, string>;
		try {
			kept = await this.#values.read(serverVariablesAccount(config.id));
		} catch (error) {
			throw new Error(`Its variables could not be read from the Keychain, so it was not started: ${error instanceof Error ? error.message : String(error)}`);
		}
		const given: Record<string, string> = {};
		for (const variable of wanted) if (variable.name in kept) given[variable.name] = kept[variable.name]!;
		return given;
	}

	/** Close every copy of a server the person removed or switched off, now, saying so to any call running on one. */
	async #end(config: McpServerConfig, how: "removed" | "switched off"): Promise<void> {
		const ending = [...this.#connections].filter((connection) => connection.server === config.id);
		const calls = ending.reduce((sum, connection) => sum + connection.calls, 0);
		if (calls > 0) this.log(`MCP server ${config.name} ${how}; ${calls === 1 ? "the call" : `the ${calls} calls`} running on it stopped`);
		const reason = `The MCP server ${config.name} was ${how} while this call was running, so the call was stopped. Whatever it did before then may have happened.`;
		await Promise.all(ending.map((connection) => this.#close(connection, reason)));
	}

	/** `reason` is what a call still running on it is told. */
	async #close(connection: Connection, reason?: string): Promise<void> {
		connection.ended ??= reason;
		clearTimeout(connection.linger);
		this.#connections.delete(connection);
		await connection.client.close().catch(() => {});
	}

	/**
	 * A connection another has replaced: closed as soon as no tool call is running on it, and in any case after
	 * `lingerMs`, so that a call that never ends does not keep it running.
	 */
	#retire(connection: Connection | undefined, name: string): void {
		if (connection === undefined || connection.retired) return;
		connection.retired = true;
		if (connection.calls === 0) return void this.#close(connection);
		const [count, unit] = this.lingerMs >= 60_000 ? [Math.round(this.lingerMs / 60_000), "minute"] : [Math.round(this.lingerMs / 1000), "second"];
		const after = `${count} ${unit}${count === 1 ? "" : "s"}`;
		connection.linger = setTimeout(() => {
			this.log(`MCP server ${name}: the copy it replaced closed after ${after} with ${connection.calls === 1 ? "a call" : `${connection.calls} calls`} still running`);
			void this.#close(connection, `The MCP server ${name} was started again while this call was running, and the call was stopped after ${after} so that the copy it ran on could close. Whatever it did before then may have happened.`);
		}, this.lingerMs);
		connection.linger.unref();
	}

	/** What of the login shell's a server would be started with now (PATH, SSH_AUTH_SOCK); undefined for one that is not a program. */
	#pathFor(config: McpServerConfig): string | undefined {
		return config.transport === "stdio" ? fromShell() : undefined;
	}

	#follow(config: McpServerConfig): void {
		if (this.#stopped || !config.enabled || config.transport !== "stdio" || this.#restarting.has(config.id)) return;
		const live = this.#live.get(config.id);
		if (live === undefined || live.path === this.#pathFor(config)) return;
		if (live.status === "error") void this.#connect(config);
		else if (live.status === "connected") void this.#restart(config, live);
		// "connecting": #connect follows it when it settles.
	}

	/** Start `config` again with the PATH the engine has now, in place of `old`, without cutting off a call. */
	async #restart(config: McpServerConfig, old: Live): Promise<void> {
		this.#restarting.add(config.id);
		try {
			const path = this.#pathFor(config);
			let opened: Opened;
			try {
				opened = await this.#open(config);
			} catch (error) {
				if (this.#stopped) return;
				this.log(`MCP server ${config.name} could not be started again with the new PATH (${error instanceof Error ? error.message : String(error)}); it keeps running as it was started`);
				return;
			}
			// Reconnected, removed or switched off meanwhile, or the engine is stopping: this one is not wanted.
			if (this.#stopped || this.#live.get(config.id) !== old) return void this.#close(opened.connection);
			this.#live.set(config.id, { status: "connected", error: null, path, ...opened });
			this.#retire(old.connection, config.name);
			this.log(`MCP server ${config.name} started again with the new PATH${old.connection !== undefined && old.connection.calls > 0 ? "; the one it replaces stops once its calls are done" : ""}`);
			this.onChange();
		} finally {
			this.#restarting.delete(config.id);
		}
	}

	/** Connect `config`, in place of the copy running if there is one (see `reconnect`), or switch it off. */
	async #connect(config: McpServerConfig): Promise<void> {
		const before = this.#live.get(config.id);
		if (!config.enabled) {
			this.#live.set(config.id, { status: "off", error: null, tools: [], registrations: [] });
			this.onChange();
			await this.#end(config, "switched off");
			return;
		}
		// A connection on a Live is one that is open (`#watch` takes it off when it closes), so it can go on answering.
		const running = before?.connection;
		const live: Live = {
			status: "connecting",
			error: null,
			tools: running !== undefined ? before!.tools : [],
			registrations: running !== undefined ? before!.registrations : [],
			...(running !== undefined ? { connection: running } : {}),
			path: this.#pathFor(config),
		};
		this.#live.set(config.id, live);
		this.onChange();
		try {
			const opened = await this.#open(config);
			// Reconnected or removed meanwhile, or the engine is stopping: this connection is not wanted.
			if (this.#stopped || this.#live.get(config.id) !== live) return void this.#close(opened.connection);
			this.#live.set(config.id, { status: "connected", error: null, path: live.path, ...opened });
		} catch (error) {
			if (this.#live.get(config.id) !== live) return;
			this.#live.set(config.id, { status: "error", error: error instanceof Error ? error.message : String(error), tools: [], registrations: [], path: live.path });
		}
		// `live.connection`, not `running`: the copy that was running may have gone on its own meanwhile.
		const replaced = live.connection;
		if (replaced !== undefined && replaced.calls > 0) this.log(`MCP server ${config.name} started again; the copy it replaces stops once its calls are done`);
		this.#retire(replaced, config.name);
		this.onChange();
		// The PATH may have changed while it was starting.
		this.#follow(config);
	}

	/**
	 * Notes a connection that closed, by the engine or on its own. One a server is using goes off it: a server that went
	 * away on its own shows so and its tools drop out; one being started again keeps waiting for its new copy.
	 */
	#watch(config: McpServerConfig, connection: Connection): void {
		connection.client.onClose(() => {
			connection.ended ??= `The MCP server ${config.name} stopped while this call was running.`;
			clearTimeout(connection.linger);
			this.#connections.delete(connection);
			const live = this.#live.get(config.id);
			if (live?.connection !== connection) return;
			delete live.connection;
			live.tools = [];
			live.registrations = [];
			if (live.status === "connected") {
				live.status = "error";
				live.error = "The server disconnected.";
			}
			this.onChange();
		});
	}

	/** Start the server and list its tools. Throws if it cannot be reached; leaves nothing running then. */
	async #open(config: McpServerConfig): Promise<Opened> {
		let transport: McpTransport;
		if (config.transport === "stdio") {
			// The engine's environment as it is now (its PATH may have changed since the last start), less pi²'s own
			// settings, with the server's own variables, which win over the engine's.
			transport = new StdioTransport({ command: config.command!, args: config.args ?? [], stderr: "pipe", env: commandEnvironment(await this.#variablesOf(config)), inheritEnv: false });
		} else {
			const token = this.#tokens.has(config.id) ? (await this.#credentials.read(`mcp-${config.id}`)) : undefined;
			const key = token?.type === "api_key" ? token.key : undefined;
			transport = new StreamableHttpTransport({ url: config.url!, ...(key ? { headers: { authorization: `Bearer ${key}` } } : {}) });
		}
		const client = new McpClient({ name: "pi2", version: "0.1.0", requestTimeoutMs: 60_000 });
		const connection: Connection = { server: config.id, client, calls: 0, retired: false };
		this.#connections.add(connection);
		let tools: Awaited<ReturnType<McpClient["listTools"]>>;
		try {
			await client.connect(transport);
			tools = await client.listTools();
		} catch (error) {
			await this.#close(connection);
			throw error;
		}
		this.#watch(config, connection);
		const taken = new Set<string>();
		const opened: Opened = { connection, tools: [], registrations: [] };
		for (const tool of tools) {
			const toolName = createMcpToolName(config.id, tool.name, (candidate) => taken.has(candidate));
			taken.add(toolName);
			const readOnly = tool.annotations?.readOnlyHint === true;
			opened.tools.push({ name: tool.name, toolName, description: tool.description ?? tool.title ?? tool.name, readOnly });
			opened.registrations.push(
				defineTool({
					name: toolName,
					description: `[${config.name}] ${tool.description ?? tool.title ?? tool.name}`,
					parameters: normalizeMcpInputSchema(tool.inputSchema) as never,
					// A tool its server does not mark read-only may change things, as the tools in IN_ORDER do, so an
					// answer with a call to one runs its calls in order (src/order.ts, #190): a read of what it wrote,
					// through the same server or another tool, comes after it. Read-only ones still run side by side.
					...(readOnly ? {} : { executionMode: "sequential" as const }),
					execute: async (args, _api, context) => {
						// The server as it is when the call runs, not as it was when this tool was listed: a call
						// that was waiting (for an approval, say) while the server was started again goes to the new
						// one rather than to one that has been closed.
						const current = this.#live.get(config.id)?.connection;
						if (current === undefined) throw new Error(`${config.name} is not connected`);
						// Counted, so that a server started again is closed only once no call is running on it.
						current.calls++;
						try {
							const result = await current.client.callTool(tool.name, args as Record<string, unknown>, { signal: context.abortSignal });
							const limited = await limitMcpContent(toLlmContent(result));
							// MCP reports tool failures in the result, not as a protocol error.
							return { output: limited.content as never, isError: result.isError === true };
						} catch (error) {
							// Cut off because the server went (removed, switched off, replaced long ago, or gone on its own):
							// say so, rather than "MCP connection closed". A call the conversation stopped stays as it was.
							if (current.ended !== undefined && context.abortSignal?.aborted !== true) throw new Error(current.ended);
							throw error;
						} finally {
							current.calls--;
							if (current.retired && current.calls === 0) void this.#close(current);
						}
					},
				}) as ToolRegistration,
			);
		}
		return opened;
	}

	#persist(): void {
		writeFileSync(this.#path, JSON.stringify(this.#configs, null, "\t"));
	}
}
