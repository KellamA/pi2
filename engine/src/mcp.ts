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

export type McpServerConfig = {
	id: string;
	name: string;
	transport: "stdio" | "http";
	/** stdio: the program and its arguments. */
	command?: string;
	args?: string[];
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
	/** A server run as a program: the PATH it was started with, which it and whatever it starts keep. */
	path?: string;
};
type Opened = { connection: Connection; tools: McpToolInfo[]; registrations: ToolRegistration[] };

export class McpServers {
	readonly #path: string;
	readonly #credentials: CredentialStore;
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

	constructor(home: string, credentials: CredentialStore) {
		this.#path = join(home, "mcp.json");
		this.#credentials = credentials;
		try {
			this.#configs = JSON.parse(readFileSync(this.#path, "utf8"));
		} catch {
			this.#configs = [];
		}
	}

	async start(): Promise<void> {
		for (const info of await this.#credentials.list()) if (info.providerId.startsWith("mcp-")) this.#tokens.add(info.providerId.slice(4));
		await Promise.all(this.#configs.map((config) => this.#connect(config)));
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

	async save(input: { id?: string; name: string; transport: string; command?: string; args?: string[]; url?: string; enabled?: boolean; token?: string }): Promise<McpServerConfig> {
		const name = input.name.trim();
		if (name === "") throw new Error("Give the server a name");
		if (input.transport !== "stdio" && input.transport !== "http") throw new Error("Choose how to reach the server");
		if (input.transport === "stdio" && (input.command ?? "").trim() === "") throw new Error("Enter the command that starts the server");
		if (input.transport === "http" && !/^https?:\/\/\S+$/.test((input.url ?? "").trim())) throw new Error("The URL must start with http:// or https://");
		let id = input.id;
		if (id === undefined) {
			const slug = name.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "") || "server";
			id = slug;
			for (let n = 2; this.#configs.some((c) => c.id === id); n++) id = `${slug}-${n}`;
		} else if (!this.#configs.some((c) => c.id === id)) {
			throw new Error(`Unknown server: ${id}`);
		}
		const config: McpServerConfig = {
			id,
			name,
			transport: input.transport,
			...(input.transport === "stdio" ? { command: input.command!.trim(), args: (input.args ?? []).filter((a) => a !== "") } : { url: input.url!.trim() }),
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
		this.#live.delete(id);
		this.#configs = this.#configs.filter((c) => c.id !== id);
		this.#persist();
		this.onChange();
		await this.#end(config, "removed");
		if (this.#tokens.delete(id)) await this.#credentials.delete(`mcp-${id}`);
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
	 * taken when it came (shellpath.ts). Bring every server run as a program that was started with another PATH onto
	 * it, so that it ends up as a quicker start would have left it (issue #98):
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

	/** The PATH a server would be started with now; undefined for one that is not a program. */
	#pathFor(config: McpServerConfig): string | undefined {
		return config.transport === "stdio" ? process.env.PATH : undefined;
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
			// The engine's environment as it is now (its PATH may have changed since the last start), less pi²'s own settings.
			transport = new StdioTransport({ command: config.command!, args: config.args ?? [], stderr: "pipe", env: commandEnvironment(), inheritEnv: false });
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
			opened.tools.push({ name: tool.name, toolName, description: tool.description ?? tool.title ?? tool.name, readOnly: tool.annotations?.readOnlyHint === true });
			opened.registrations.push(
				defineTool({
					name: toolName,
					description: `[${config.name}] ${tool.description ?? tool.title ?? tool.name}`,
					parameters: normalizeMcpInputSchema(tool.inputSchema) as never,
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
