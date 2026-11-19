// Reach (#465): what an agent may change itself and what it can only ask for. docs/projects.md, section 7, is the
// contract this file builds: every setting of an agent and of a project classed as widening reach or not (7.1), the
// baseline a new agent made by an agent starts from (7.2), and how each setting reads to the person.
//
// A setting is compared as stored now with what the change would make it, setting by setting. A setting the tables do
// not name, or one added to agents or projects later, counts as widening until this file names it.

import type { CommandRule } from "./rules.ts";
import { sameFolder } from "./rules.ts";
import type { ProjectSettings } from "./projects.ts";
import { SWITCH_NAMES, type SwitchName } from "./projects.ts";
import type { Access, AgentProfile } from "./state.ts";

/** One setting changed: its name, what it is now and what the change makes it (3.12). */
export type Field = { name: string; before: unknown; after: unknown };

/**
 * The settings of an agent a tool may change, as `Field` names: `AgentProfile`'s own, and `memory`, the memory switch
 * knowledge.ts keeps outside the profile. Not here, so not offered to any tool: `variables` (the person's alone), `cwd`
 * (set by the engine), `role` (`set_orchestrator`), the marks of 3.3 and `removedAt` (`remove` and `restore`).
 */
export const AGENT_FIELDS = [
	"name",
	"description",
	"color",
	"instructions",
	"model",
	"thinkingLevel",
	"maxTurns",
	"compactionTokens",
	"codeMode",
	"access",
	"allowEverything",
	"toolsOff",
	"toolsOn",
	"computer",
	"browser",
	"mcpServers",
	"files",
	"schedule",
	"commandRules",
	"worktree",
	"setup",
	"delegates",
	"memory",
] as const;
export type AgentField = (typeof AGENT_FIELDS)[number];

/** An agent's settings as a tool sees them, each as `agents.save` stores it, so that equal settings compare equal. */
export type AgentValues = Record<AgentField, unknown>;

/** The value of each setting of `agent`, as stored, with the defaults `agents.save` gives one saved before it existed. */
export function agentValues(agent: AgentProfile, memory: boolean): AgentValues {
	return {
		name: agent.name,
		description: agent.description ?? "",
		color: agent.color ?? "violet",
		instructions: agent.instructions ?? "",
		model: agent.model ?? null,
		thinkingLevel: agent.thinkingLevel ?? null,
		maxTurns: agent.maxTurns ?? null,
		compactionTokens: agent.compactionTokens ?? null,
		codeMode: agent.codeMode === true,
		access: agent.access ?? "none",
		allowEverything: agent.allowEverything === true,
		toolsOff: [...(agent.toolsOff ?? [])],
		toolsOn: [...(agent.toolsOn ?? [])],
		computer: { enabled: agent.computer?.enabled === true, apps: [...(agent.computer?.apps ?? [])], ask: agent.computer?.ask !== false, testCopies: agent.computer?.testCopies === true },
		browser: { enabled: agent.browser?.enabled === true, ask: agent.browser?.ask !== false },
		mcpServers: [...(agent.mcpServers ?? [])],
		files: copy(agent.files ?? []),
		schedule: { enabled: agent.schedule?.enabled === true },
		commandRules: copy(agent.commandRules ?? []),
		worktree: agent.worktree === true,
		setup: agent.setup ?? "",
		delegates: [...agent.delegates],
		memory,
	};
}

/**
 * A plain copy of a value as JSON holds it. What a commit's document gives is a draft that `structuredClone` cannot
 * copy, and every value here is stored as JSON anyway.
 */
export const copy = <T>(value: T): T => (value === undefined ? value : (JSON.parse(JSON.stringify(value)) as T));

/** JSON with every object's keys in order, so two values that differ only in the order of their keys compare equal. */
export function canonical(value: unknown): string {
	return JSON.stringify(value ?? null, (_key, inner) =>
		inner !== null && typeof inner === "object" && !Array.isArray(inner) ? Object.fromEntries(Object.entries(inner).sort(([a], [b]) => a.localeCompare(b))) : inner,
	);
}

export const same = (a: unknown, b: unknown) => canonical(a) === canonical(b);

const ACCESS_ORDER: readonly Access[] = ["none", "read", "ask", "full"];
const strings = (value: unknown): string[] => (Array.isArray(value) ? value.filter((one): one is string => typeof one === "string") : []);
const added = (before: unknown, after: unknown) => strings(after).some((one) => !strings(before).includes(one));
const object = (value: unknown): Record<string, unknown> => (value !== null && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : {});

/**
 * Whether changing an agent's setting `name` from `before` to `after` widens what it may do or reach (7.1). A setting
 * not named here widens on any change.
 */
export function agentFieldWidens(name: string, before: unknown, after: unknown): boolean {
	if (same(before, after)) return false;
	switch (name) {
		case "name":
		case "description":
		case "color":
		case "instructions":
		case "model":
		case "thinkingLevel":
		case "maxTurns":
		case "compactionTokens":
		case "codeMode":
			return false;
		case "access":
			return ACCESS_ORDER.indexOf(after as Access) > ACCESS_ORDER.indexOf(before as Access);
		case "allowEverything":
			return after === true && before !== true;
		case "toolsOff":
			// A key taken out: a built-in tool turned back on.
			return added(after, before);
		case "toolsOn":
			return added(before, after);
		case "computer": {
			const [was, now] = [object(before), object(after)];
			return (now.enabled === true && was.enabled !== true) || added(was.apps, now.apps) || (now.testCopies === true && was.testCopies !== true) || (now.ask === false && was.ask !== false);
		}
		case "browser": {
			const [was, now] = [object(before), object(after)];
			return (now.enabled === true && was.enabled !== true) || (now.ask === false && was.ask !== false);
		}
		case "mcpServers":
		case "delegates":
			return added(before, after);
		case "files": {
			// One added: by its path. A note changed on a file already there changes nothing it can read.
			const paths = (value: unknown) => (Array.isArray(value) ? value.map((file) => object(file).path) : []);
			return paths(after).some((path) => !paths(before).includes(path));
		}
		case "schedule":
			return object(after).enabled === true && object(before).enabled !== true;
		case "commandRules": {
			const rules = (value: unknown) => (Array.isArray(value) ? (value as CommandRule[]) : []);
			return rules(after).some((rule) => !rules(before).some((old) => sameFolder(old.folder, rule.folder) && same(old.words, rule.words)));
		}
		case "worktree":
		case "memory":
			return after === true && before !== true;
		case "setup":
			// Set or changed; cleared narrows.
			return typeof after === "string" && after !== "";
		default:
			return true;
	}
}

/** The settings of a project a tool may change, as `Field` names. `wakeOnReports` is the person's switch, never here. */
export const PROJECT_FIELDS = ["name", "folder", "repository", ...SWITCH_NAMES.map((name) => `withoutAsking.${name}`), "limits.planShare", "limits.dailySpend"] as const;

/** The value of each setting of a project, by `Field` name. */
export function projectValues(project: { name: string; folder: string | null; repository: unknown; settings: ProjectSettings }): Record<string, unknown> {
	return {
		name: project.name,
		folder: project.folder,
		repository: project.repository,
		...Object.fromEntries(SWITCH_NAMES.map((name) => [`withoutAsking.${name}`, project.settings.withoutAsking[name]])),
		"limits.planShare": project.settings.limits.planShare,
		"limits.dailySpend": project.settings.limits.dailySpend,
	};
}

/** Whether changing a project's setting `name` from `before` to `after` widens reach (7.1). Unnamed: any change does. */
export function projectFieldWidens(name: string, before: unknown, after: unknown): boolean {
	if (same(before, after)) return false;
	if (name === "name") return false;
	if (name === "folder" || name === "repository") return true;
	if (name.startsWith("withoutAsking.") && SWITCH_NAMES.includes(name.slice(14) as SwitchName)) return after === true;
	if (name === "limits.planShare" || name === "limits.dailySpend") {
		// Raised, or turned off. Setting one where there was none lowers it.
		if (after === null) return before !== null;
		if (before === null) return false;
		return typeof after !== "number" || typeof before !== "number" || after > before;
	}
	return true;
}

/**
 * A new agent made by an agent (7.2): access at most Ask first; Allow everything, computer use, the browser, scheduling,
 * worktrees and memory off; no MCP server, reference file, allowed command, set-up command or delegate; the built-in
 * tools as a new agent has them. Everything else as asked.
 */
export function baselineOf(wanted: AgentValues): AgentValues {
	const access = ACCESS_ORDER.indexOf(wanted.access as Access) > ACCESS_ORDER.indexOf("ask") ? "ask" : wanted.access;
	return {
		...wanted,
		access,
		allowEverything: false,
		computer: { enabled: false, apps: [], ask: true, testCopies: false },
		browser: { enabled: false, ask: true },
		schedule: { enabled: false },
		worktree: false,
		memory: false,
		mcpServers: [],
		files: [],
		commandRules: [],
		setup: "",
		delegates: [],
		toolsOff: [],
		toolsOn: [],
	};
}

/**
 * Split what a new agent should have into what it is made with and what is asked for: each setting that would widen
 * reach over the baseline is made at the baseline and asked for, as one request (7.1).
 */
export function splitNew(wanted: AgentValues): { made: AgentValues; asked: Field[] } {
	const base = baselineOf(wanted);
	const made = { ...wanted };
	const asked: Field[] = [];
	for (const name of AGENT_FIELDS) {
		if (!agentFieldWidens(name, base[name], wanted[name])) continue;
		made[name] = base[name];
		asked.push({ name, before: base[name], after: wanted[name] });
	}
	return { made, asked };
}

// ---- How a setting reads to the person and to the agent

export const ACCESS_LABELS: Record<Access, string> = { none: "Tools off", read: "Read files", ask: "Ask first", full: "Full access" };

const LABELS: Record<string, string> = {
	name: "name",
	description: "description",
	color: "colour",
	instructions: "instructions",
	model: "model",
	thinkingLevel: "thinking",
	maxTurns: "turn limit",
	compactionTokens: "summarise at",
	codeMode: "code mode",
	access: "access",
	allowEverything: "Allow everything",
	toolsOff: "built-in tools left out",
	toolsOn: "built-in tools turned on",
	computer: "computer use",
	browser: "the browser",
	mcpServers: "MCP servers",
	files: "reference files",
	schedule: "scheduling",
	commandRules: "allowed commands",
	worktree: "worktrees",
	setup: "set-up command",
	delegates: "agents it may hand work to",
	memory: "memory",
	folder: "folder",
	repository: "repository",
	"limits.planShare": "plan share limit",
	"limits.dailySpend": "daily spending limit",
	"withoutAsking.startAgents": "start agents without asking",
	"withoutAsking.fileWork": "file work without asking",
	"withoutAsking.closeWork": "close work without asking",
	"withoutAsking.makeAgents": "make agents without asking",
	"withoutAsking.addRules": "add rules without asking",
	"withoutAsking.merge": "merge without asking",
	"withoutAsking.release": "release without asking",
	"withoutAsking.passLimits": "pass limits without asking",
};

export const labelOf = (name: string) => LABELS[name] ?? name;

/** A setting's value in a few words. `names` turns an agent's id into its name, for `delegates`. */
export function render(name: string, value: unknown, names: (id: string) => string = (id) => id): string {
	const quoted = (text: string) => {
		const line = text.replace(/\s+/g, " ").trim();
		return line === "" ? "none" : `“${line.length > 60 ? `${line.slice(0, 59).trimEnd()}…` : line}”`;
	};
	const list = (items: string[]) => (items.length === 0 ? "none" : items.join(", "));
	switch (name) {
		case "access":
			return ACCESS_LABELS[value as Access] ?? String(value);
		case "model": {
			const model = object(value);
			return value === null ? "the default model" : `${String(model.provider)}/${String(model.modelId)}`;
		}
		case "computer": {
			const computer = object(value);
			if (computer.enabled !== true) return "off";
			return `on, apps: ${list(strings(computer.apps))}, ${computer.ask === false ? "acting without asking" : "asking first"}${computer.testCopies === true ? ", test copies of pi² too" : ""}`;
		}
		case "browser": {
			const browser = object(value);
			return browser.enabled !== true ? "off" : `on, ${browser.ask === false ? "acting without asking" : "asking first"}`;
		}
		case "schedule":
			return object(value).enabled === true ? "on" : "off";
		case "files":
			return list(Array.isArray(value) ? value.map((file) => String(object(file).path)) : []);
		case "commandRules":
			return list(Array.isArray(value) ? value.map((rule) => strings(object(rule).words).join(" ")) : []);
		case "delegates":
			return list(strings(value).map(names));
		case "limits.dailySpend":
			return value === null ? "none" : `$${String(value)} a day`;
		case "limits.planShare":
			return value === null ? "none" : `${String(value)}%`;
		case "repository": {
			const repository = object(value);
			return value === null ? "none" : `${String(repository.owner)}/${String(repository.name)}`;
		}
	}
	if (typeof value === "boolean") return value ? "on" : "off";
	if (value === null || value === undefined) return "none";
	if (typeof value === "string") return quoted(value);
	if (Array.isArray(value)) return list(value.map((one) => (typeof one === "string" ? one : canonical(one))));
	return typeof value === "number" ? value.toLocaleString("en") : canonical(value);
}

/** "access Full access (now Ask first)", for each field, joined. */
export function describeFields(fields: Field[], names?: (id: string) => string): string {
	return fields.map((field) => `${labelOf(field.name)} ${render(field.name, field.after, names)} (now ${render(field.name, field.before, names)})`).join("; ");
}
