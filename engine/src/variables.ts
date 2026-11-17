
// Environment variables of an agent's own (issue #96), which the person sets in the agent's settings: a token for a
// command-line tool (GH_TOKEN), a host to talk to, the like. Every command the agent runs gets them: shell commands,
// background commands and its worktrees' set-up command. A sub-chat gets the variables of the agent it is a
// conversation of, never those of the agent that handed it the work.
//
// A value may be a secret, so values are kept in the Keychain, under the service the engine keeps sign-ins under, in
// one item per agent named `variables/<agent id>` (credentials.ts). Never in the database, a settings file or a
// backup: the agent's profile holds the names only, and whether each has a value. The app shows the names; a value can
// be set and replaced, never read back, as an API key is. Duplicating an agent copies the names without the values,
// so that a secret is never copied silently: the person sets them again for the copy. Deleting the agent removes its
// values from the Keychain.
//
// MCP servers do not get them. One server process serves every agent that uses it, so it cannot take one agent's
// variables, and a server has a configuration of its own, where what it needs belongs.
//
// The engine sets some variables of commands itself, and a name that would undo or weaken one of them is refused,
// saying why (`refusal`).

import type { Context } from "@earendil-works/chord/context";
import { KeychainObjects } from "./credentials.ts";
import type { Engine, Feature } from "./features.ts";
import { type AgentProfile, type AgentVariable, Agents } from "./state.ts";

/** At most this many variables an agent. */
export const MAX_VARIABLES = 50;
/** At most this many bytes a value. */
export const MAX_VALUE_BYTES = 16 * 1024;
const MAX_NAME = 100;

/** The Keychain item an agent's values are kept in. */
export const variablesAccount = (agentId: string): string => `variables/${agentId}`;

/** Names the shell itself reads as it starts, which would change what it does with every command. */
const SHELL_OWN = new Set(["BASH_ENV", "ENV", "SHELLOPTS", "BASHOPTS", "PS4", "IFS", "CDPATH", "GLOBIGNORE", "POSIXLY_CORRECT"]);

/** Why `name` cannot be one of an agent's variables, or undefined if it can. */
export function refusal(name: string): string | undefined {
	if (name === "") return "Give the variable a name.";
	if (name.length > MAX_NAME) return `The name is too long: keep it under ${MAX_NAME} characters.`;
	if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(name)) return `“${name}” is not a name a shell can use: letters, digits and _ only, not starting with a digit.`;
	if (name === "PATH") return "PATH is not set here: pi² gives commands the PATH of your login shell, so change it in your shell's profile, and it counts from the next time pi² starts.";
	if (name.startsWith("PI2_")) return "Names that start with PI2_ are pi²'s own: it sets some of them for each command itself (PI2_SCRATCH, the conversation's scratch folder, and PI2_RUN, which it finds what a command started by), and keeps the rest out of what commands get.";
	if (SHELL_OWN.has(name) || name.startsWith("BASH_")) return `${name} is not allowed: bash reads it as it starts every command, so it would change what each command does, including the ones the agent's rules let it run without asking.`;
	if (name.startsWith("DYLD_")) return `${name} would never arrive: macOS takes DYLD_ variables away from /bin/bash, which runs every command.`;
	return undefined;
}

let running: { values(agent: AgentProfile): Promise<Record<string, string>>; meta(id: number): { agentId?: string } | undefined; agents(): Record<string, AgentProfile> } | undefined;

/**
 * What a command of conversation `id` adds to its environment: the variables of the conversation's own agent that have
 * a value. Nothing for a conversation with no agent, or outside a running engine. Throws when the values cannot be read
 * from the Keychain, rather than run a command without what the person gave it.
 */
export async function agentVariables(id: number): Promise<Record<string, string>> {
	if (running === undefined) return {};
	const agent = running.agents()[running.meta(id)?.agentId ?? ""];
	if (agent === undefined || !(agent.variables ?? []).some((variable) => variable.set)) return {};
	try {
		return await running.values(agent);
	} catch (error) {
		throw new Error(`The variables you gave ${agent.name} could not be read from the Keychain, so the command was not run: ${error instanceof Error ? error.message : String(error)}`);
	}
}

export const variables: Feature = (host, engine: Engine) => {
	const keychain = new KeychainObjects();
	/** Each agent's values as last read from or written to the Keychain, so a command does not ask the Keychain each time. */
	const known = new Map<string, Record<string, string>>();

	const read = async (agentId: string): Promise<Record<string, string>> => {
		const cached = known.get(agentId);
		if (cached !== undefined) return cached;
		const stored = (await keychain.read(variablesAccount(agentId))) ?? {};
		const values: Record<string, string> = {};
		for (const [name, value] of Object.entries(stored)) if (typeof value === "string") values[name] = value;
		known.set(agentId, values);
		return values;
	};

	/** Change an agent's list of variables in its profile. */
	const edit = async (agentId: string, change: (list: AgentVariable[]) => AgentVariable[], context: Context = engine.context()) => {
		await engine.harness().commit(async (tx) => {
			const agent = (await tx.doc(Agents)).agents[agentId];
			if (agent === undefined) throw new Error(`Unknown agent: ${agentId}`);
			agent.variables = change(JSON.parse(JSON.stringify(agent.variables ?? [])));
		}, context);
	};

	const agentOf = (params: Record<string, unknown>): AgentProfile => {
		const id = params.agentId;
		const agent = typeof id === "string" ? engine.agents()[id] : undefined;
		if (agent === undefined) throw new Error(`Unknown agent: ${String(id)}`);
		return agent;
	};
	const nameOf = (params: Record<string, unknown>): string => {
		if (typeof params.name !== "string") throw new Error("Give the variable a name.");
		const name = params.name.trim();
		const refused = refusal(name);
		if (refused !== undefined) throw new Error(refused);
		return name;
	};

	/**
	 * A profile that says a variable has a value the Keychain does not hold (a backup restored on another Mac or in
	 * another copy of pi², or an item removed by hand) is put right, so the settings do not show a value that is not there.
	 */
	const check = async () => {
		for (const agent of Object.values(engine.agents())) {
			if (!(agent.variables ?? []).some((variable) => variable.set)) continue;
			try {
				const values = await read(agent.id);
				if (agent.variables!.every((variable) => !variable.set || variable.name in values)) continue;
				await edit(agent.id, (list) => list.map((variable) => ({ ...variable, set: variable.set && variable.name in values })));
				engine.log(`variables of agent ${agent.id}: some had no value in the Keychain, and are shown as not set`);
			} catch (error) {
				engine.log(`variables of agent ${agent.id} could not be read from the Keychain:`, error instanceof Error ? error.message : error);
			}
		}
	};

	running = {
		values: async (agent) => {
			const values = await read(agent.id);
			const given: Record<string, string> = {};
			for (const variable of agent.variables ?? []) if (variable.set && variable.name in values) given[variable.name] = values[variable.name]!;
			return given;
		},
		meta: (id) => host.meta(id as never),
		agents: () => engine.agents(),
	};

	return {
		// Not waited for: the engine need not wait for the Keychain to start, and a command reads what it needs anyway.
		start: async () => void check(),
		handlers: {
			/** Set or replace the value of one of an agent's variables, adding the name if it is new. */
			"variables.set": async (params) => {
				const agent = agentOf(params);
				const name = nameOf(params);
				const value = params.value;
				if (typeof value !== "string") throw new Error("The value must be text.");
				if (value.includes("\0")) throw new Error("The value cannot hold a NUL character, which no program can be given.");
				if (Buffer.byteLength(value) > MAX_VALUE_BYTES) throw new Error(`The value is too long: keep it under ${MAX_VALUE_BYTES / 1024} KB.`);
				const list = agent.variables ?? [];
				if (!list.some((variable) => variable.name === name) && list.length >= MAX_VARIABLES) throw new Error(`An agent can have ${MAX_VARIABLES} variables at most.`);
				// The value first: the profile never says there is one that the Keychain does not hold.
				await keychain.exclusive(variablesAccount(agent.id), async () => {
					known.delete(agent.id);
					const values = await read(agent.id);
					const next = { ...values, [name]: value };
					await keychain.write(variablesAccount(agent.id), next, "the value");
					known.set(agent.id, next);
				});
				await edit(agent.id, (current) => (current.some((variable) => variable.name === name) ? current.map((variable) => (variable.name === name ? { name, set: true } : variable)) : [...current, { name, set: true }]));
				return {};
			},
			/** Remove one of an agent's variables, its value with it. */
			"variables.remove": async (params) => {
				const agent = agentOf(params);
				if (typeof params.name !== "string") throw new Error("Say which variable to remove.");
				const name = params.name;
				// The name first: from then on no command gets it, even if the Keychain cannot be changed now.
				await edit(agent.id, (current) => current.filter((variable) => variable.name !== name));
				await keychain.exclusive(variablesAccount(agent.id), async () => {
					known.delete(agent.id);
					const values = { ...(await read(agent.id)) };
					if (!(name in values)) return;
					delete values[name];
					if (Object.keys(values).length === 0) await keychain.delete(variablesAccount(agent.id));
					else await keychain.write(variablesAccount(agent.id), values, "the change");
					known.set(agent.id, values);
				});
				return {};
			},
		},
		// The copy gets the names, not the values: a secret is not copied without the person doing it.
		agentDuplicated: async (sourceId, copyId) => {
			const names = (engine.agents()[sourceId]?.variables ?? []).map((variable) => ({ name: variable.name, set: false }));
			if (names.length > 0) await edit(copyId, () => names);
		},
		// Before the agent goes, so that an agent whose values could not be removed is still there to try again with.
		deletingAgent: async (agentId) => {
			await keychain.exclusive(variablesAccount(agentId), async () => {
				known.delete(agentId);
				try {
					await keychain.delete(variablesAccount(agentId));
				} catch (error) {
					throw new Error(`The agent was not deleted: its variables could not be removed from the Keychain (${error instanceof Error ? error.message : String(error)}).`);
				}
			});
		},
	};
};
