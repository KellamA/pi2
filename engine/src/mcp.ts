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

type Live = { client?: McpClient; status: McpServerStatus["status"]; error: string | null; tools: McpToolInfo[]; registrations: ToolRegistration[] };

export class McpServers {
	readonly #path: string;
	readonly #credentials: CredentialStore;
	#configs: McpServerConfig[];
	readonly #live = new Map<string, Live>();
	readonly #tokens = new Set<string>();
	/** Called whenever a server's status or tools change. */
	onChange: () => void = () => {};

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

	async remove(id: string): Promise<void> {
		if (!this.#configs.some((c) => c.id === id)) throw new Error(`Unknown server: ${id}`);
		await this.#disconnect(id);
		this.#live.delete(id);
		this.#configs = this.#configs.filter((c) => c.id !== id);
		this.#persist();
		if (this.#tokens.delete(id)) await this.#credentials.delete(`mcp-${id}`);
		this.onChange();
	}

	async reconnect(id: string): Promise<void> {
		const config = this.#configs.find((c) => c.id === id);
		if (config === undefined) throw new Error(`Unknown server: ${id}`);
		await this.#connect(config);
	}

	async stop(): Promise<void> {
		await Promise.all([...this.#live.keys()].map((id) => this.#disconnect(id)));
	}

	async #disconnect(id: string): Promise<void> {
		const client = this.#live.get(id)?.client;
		if (client !== undefined) await client.close().catch(() => {});
	}

	async #connect(config: McpServerConfig): Promise<void> {
		await this.#disconnect(config.id);
		if (!config.enabled) {
			this.#live.set(config.id, { status: "off", error: null, tools: [], registrations: [] });
			this.onChange();
			return;
		}
		const live: Live = { status: "connecting", error: null, tools: [], registrations: [] };
		this.#live.set(config.id, live);
		this.onChange();
		try {
			let transport: McpTransport;
			if (config.transport === "stdio") {
				transport = new StdioTransport({ command: config.command!, args: config.args ?? [], stderr: "pipe" });
			} else {
				const token = this.#tokens.has(config.id) ? (await this.#credentials.read(`mcp-${config.id}`)) : undefined;
				const key = token?.type === "api_key" ? token.key : undefined;
				transport = new StreamableHttpTransport({ url: config.url!, ...(key ? { headers: { authorization: `Bearer ${key}` } } : {}) });
			}
			const client = new McpClient({ name: "pi2", version: "0.1.0", requestTimeoutMs: 60_000 });
			await client.connect(transport);
			const tools = await client.listTools();
			const taken = new Set<string>();
			live.client = client;
			for (const tool of tools) {
				const toolName = createMcpToolName(config.id, tool.name, (candidate) => taken.has(candidate));
				taken.add(toolName);
				live.tools.push({ name: tool.name, toolName, description: tool.description ?? tool.title ?? tool.name, readOnly: tool.annotations?.readOnlyHint === true });
				live.registrations.push(
					defineTool({
						name: toolName,
						description: `[${config.name}] ${tool.description ?? tool.title ?? tool.name}`,
						parameters: normalizeMcpInputSchema(tool.inputSchema) as never,
						execute: async (args, _api, context) => {
							const result = await client.callTool(tool.name, args as Record<string, unknown>, { signal: context.abortSignal });
							const limited = await limitMcpContent(toLlmContent(result));
							// MCP reports tool failures in the result, not as a protocol error.
							return { output: limited.content as never, isError: result.isError === true };
						},
					}) as ToolRegistration,
				);
			}
			live.status = "connected";
			client.onClose(() => {
				// The server went away on its own (not replaced by a reconnect): show it, and drop its tools.
				if (this.#live.get(config.id) !== live || live.status !== "connected") return;
				live.status = "error";
				live.error = "The server disconnected.";
				live.tools = [];
				live.registrations = [];
				this.onChange();
			});
		} catch (error) {
			live.status = "error";
			live.error = error instanceof Error ? error.message : String(error);
		}
		this.onChange();
	}

	#persist(): void {
		writeFileSync(this.#path, JSON.stringify(this.#configs, null, "\t"));
	}
}
