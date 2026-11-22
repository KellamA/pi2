// Saving agents and their allowed commands (#483, moved from main.ts): `saveAgent`, which every way of saving one goes
// through, with its checks and defaults; keeping and removing an allowed command; and the `agents.*` and `rules.*`
// requests. main.ts hands over what they use of the engine (`wireAgentRequests`).

import { randomUUID } from "node:crypto";
import { existsSync, statSync } from "node:fs";
import { isAbsolute } from "node:path";
import type { Context } from "@earendil-works/chord/context";
import type { Harness, Tx } from "@earendil-works/pi-durable";
import { validateBrowser } from "./browser.ts";
import { validateToolsOff, validateToolsOn } from "./builtins.ts";
import { validateCompactionTokens } from "./compaction.ts";
import { validateComputer } from "./computer.ts";
import type { Host } from "./extensions.ts";
import type { AgentSaveOptions } from "./features.ts";
import { agents } from "./indexes.ts";
import { projectAgentFolder } from "./projectagents.ts";
import { validateReferenceFiles } from "./reference.ts";
import { type Params, text } from "./requests.ts";
import { type CommandRule, ruleFolder, ruleRefusal, sameFolder, wordsOf } from "./rules.ts";
import { validateScheduleSettings } from "./selfschedule.ts";
import { ACCESS_LEVELS, type AgentProfile, Agents } from "./state.ts";
import { inRepository, madeWorktrees } from "./worktrees.ts";

// What this file uses of the running engine, handed over by main.ts once it has them (`wireAgentRequests`).
let harness: Harness;
let context: Context;
let log: (...parts: unknown[]) => void;
let host: Host;

export function wireAgentRequests(parts: { harness: Harness; context: Context; log: typeof log; host: Host }): void {
	({ harness, context, log, host } = parts);
}

// Saving and duplicating share validation and defaults; the app never assembles a copy.
export async function saveAgent(given: Partial<AgentProfile> | undefined, options: AgentSaveOptions = {}): Promise<{ id: string }> {
	const copiedRules = options.copiedRules;
	let input = given;
	let name = typeof input?.name === "string" ? input.name.trim() : "";
	if (input === undefined || name === "") throw new Error("Give the agent a name");
	if (input.id !== undefined && agents[input.id] === undefined) throw new Error(`Unknown agent: ${input.id}`);
	// The project it is in: a new one's as the engine makes it, never as the app sends it (docs/projects.md, 3.3).
	const project = input.id === undefined ? options.project : agents[input.id]?.projectId;
	// A project agent works in its project's folder, which the engine sets; another is refused.
	if (project !== undefined) input = { ...input, cwd: projectAgentFolder(project, input.cwd) };
	if (input.access !== undefined && !ACCESS_LEVELS.includes(input.access)) throw new Error(`Unknown access level: ${String(input.access)}`);
	if (project === undefined && typeof input.cwd === "string" && !(existsSync(input.cwd) && statSync(input.cwd).isDirectory())) throw new Error(`Not a folder: ${input.cwd}`);
	if (input.worktree !== undefined && typeof input.worktree !== "boolean") throw new Error("worktree must be true or false");
	if (input.setup !== undefined && typeof input.setup !== "string") throw new Error("The set-up command must be text");
	if (typeof input.setup === "string" && input.setup.length > 4_000) throw new Error("The set-up command is too long: keep it under 4,000 characters, or put it in a script");
	if (input.maxTurns !== undefined && input.maxTurns !== null && !(Number.isInteger(input.maxTurns) && input.maxTurns >= 1)) throw new Error("The turn limit must be a whole number, 1 or more");
	// Names are unique among the templates (agents of no project), and among the agents of each project: every project's
	// orchestrator may be called Orchestrator (docs/projects.md, 3.3). Removed agents count.
	const taken = Object.values(agents).some((other) => other.id !== input.id && other.projectId === project && other.name.toLowerCase() === name.toLowerCase());
	if (taken && copiedRules === undefined) throw new Error(`There is already an agent called ${name}`);
	// New identities are allocated in the commit, so two requests cannot pick the same name or id.
	let id = input.id ?? "";
	const previous = agents[id];
	const agent: AgentProfile = {
		id,
		name,
		description: (input.description ?? previous?.description ?? "").trim(),
		color: input.color ?? previous?.color ?? "violet",
		model: input.model === undefined ? (previous?.model ?? null) : input.model,
		thinkingLevel: input.thinkingLevel === undefined ? (previous?.thinkingLevel ?? null) : input.thinkingLevel,
		instructions: input.instructions ?? previous?.instructions ?? "",
		access: input.access ?? previous?.access ?? "none",
		cwd: input.cwd === undefined ? (previous?.cwd ?? null) : input.cwd,
		worktree: input.worktree ?? previous?.worktree ?? false,
		setup: (input.setup ?? previous?.setup ?? "").trim(),
		delegates: (input.delegates ?? previous?.delegates ?? []).filter((other) => other !== id),
		maxTurns: input.maxTurns === undefined ? (previous?.maxTurns ?? null) : input.maxTurns,
		codeMode: input.codeMode ?? previous?.codeMode ?? false,
		mcpServers: input.mcpServers ?? previous?.mcpServers ?? [],
		files: input.files === undefined ? (previous?.files ?? []) : validateReferenceFiles(input.files),
		computer: input.computer === undefined ? (previous?.computer ?? { enabled: false, apps: [], ask: true, testCopies: false }) : validateComputer(input.computer),
		browser: input.browser === undefined ? (previous?.browser ?? { enabled: false, ask: true }) : validateBrowser(input.browser),
		schedule: input.schedule === undefined ? (previous?.schedule ?? { enabled: false }) : validateScheduleSettings(input.schedule),
		toolsOff: input.toolsOff === undefined ? (previous?.toolsOff ?? []) : validateToolsOff(input.toolsOff),
		toolsOn: input.toolsOn === undefined ? (previous?.toolsOn ?? []) : validateToolsOn(input.toolsOn),
		compactionTokens: input.compactionTokens === undefined ? (previous?.compactionTokens ?? null) : validateCompactionTokens(input.compactionTokens, 0),
		createdAt: previous?.createdAt ?? Date.now(),
	};
	if (agent.worktree === true && (agent.cwd === null || !(await inRepository(agent.cwd)))) {
		throw new Error("To give each conversation its own worktree, choose a folder in a git repository for the agent");
	}
	// In the caller's commit when it gives one (a change an agent makes through a tool, recorded with it: changes.ts).
	const write = async (tx: Tx) => {
		const doc = await tx.doc(Agents);
		if (input.id === undefined) {
			const base = name;
			const taken = () => Object.values(doc.agents).some((other) => other.projectId === project && other.name.toLowerCase() === name.toLowerCase());
			if (copiedRules !== undefined) {
				for (let n = 2; taken(); n++) name = `${base} ${n}`;
			} else if (taken()) throw new Error(`There is already an agent called ${name}`);
			const slug = name.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "") || "agent";
			// A deleted copy may still own conversations, schedules and worktrees. Never reuse its identity; nor a project
			// agent's, whose name another project's agents may have too.
			id = copiedRules === undefined && project === undefined ? slug : `${slug}-${randomUUID()}`;
			for (let n = 2; doc.agents[id] !== undefined; n++) id = `${slug}-${n}`;
			agent.id = id;
			agent.name = name;
			agent.delegates = agent.delegates.filter((other) => other !== id);
		}
		// Save never accepts rules from the app. Duplication alone supplies rules from the stored source.
		const rules: CommandRule[] = JSON.parse(JSON.stringify(copiedRules ?? doc.agents[id]?.commandRules ?? []));
		// Nor variables: they change through their own requests, and a copy gets theirs from variables.ts.
		const variables = doc.agents[id]?.variables;
		// Nor Allow everything, which has its own request; a new agent, a duplicate among them, never has it (#294).
		const everything = doc.agents[id]?.allowEverything === true;
		// Nor what marks a project agent (docs/projects.md, 3.3): kept as stored, whatever is sent, or as the engine sets it.
		const stored = doc.agents[id];
		const marks = JSON.parse(
			JSON.stringify({
				projectId: stored === undefined ? project : stored.projectId,
				role: stored?.role,
				template: stored?.template,
				madeBy: stored?.madeBy,
				updatedAt: stored?.updatedAt,
				removedAt: stored?.removedAt,
				...options.marks,
			}),
		);
		// When it was last saved, for Update from template (3.3).
		marks.updatedAt = Date.now();
		doc.agents[id] = {
			...agent,
			commandRules: rules,
			...(variables === undefined ? {} : { variables: JSON.parse(JSON.stringify(variables)) }),
			...(everything ? { allowEverything: true as const } : {}),
			...marks,
		};
	};
	if (options.tx !== undefined) await write(options.tx);
	else await harness.commit(write, context);
	// The agent's conversations pick up what it may now do at their next message; see syncTools.
	return { id };
}

// ---- Rules for an agent's shell commands (rules.ts). They live on the agent, so deleting it deletes them.

const sameWords = (a: readonly string[], b: readonly string[]) => a.length === b.length && a.every((word, index) => word === b[index]);

/**
 * Keep a rule, whether it was chosen in an approval or typed in the agent's settings: both pass the same checks, and a
 * folder inside a worktree pi² made is kept as the same folder of the repository's main checkout (rules.ts, `ruleFolder`).
 */
export async function addCommandRule(agentId: string, folder: string, words: string[]): Promise<CommandRule> {
	const refused = ruleRefusal(words);
	if (refused !== undefined) throw new Error(refused);
	const rule: CommandRule = { folder: ruleFolder(folder, await madeWorktrees(harness, context)), words: [...words], createdAt: Date.now() };
	await harness.commit(async (tx) => {
		const agent = (await tx.doc(Agents)).agents[agentId];
		if (agent === undefined) throw new Error(`Unknown agent: ${agentId}`);
		const rules: CommandRule[] = JSON.parse(JSON.stringify(agent.commandRules ?? []));
		if (rules.some((other) => sameFolder(other.folder, rule.folder) && sameWords(other.words, rule.words))) return;
		agent.commandRules = [...rules, rule];
	}, context);
	return rule;
}

async function removeCommandRule(agentId: string, folder: string, words: string[]): Promise<void> {
	await harness.commit(async (tx) => {
		const agent = (await tx.doc(Agents)).agents[agentId];
		if (agent === undefined) throw new Error(`Unknown agent: ${agentId}`);
		const rules: CommandRule[] = JSON.parse(JSON.stringify(agent.commandRules ?? []));
		const kept = rules.filter((rule) => !(sameFolder(rule.folder, folder) && sameWords(rule.words, words)));
		if (kept.length === rules.length) throw new Error("That allowed command is already gone");
		agent.commandRules = kept;
	}, context);
}

export const agentRequests: Record<string, (params: Params) => Promise<unknown>> = {
	"agents.save": async (params) => saveAgent(params.agent as Partial<AgentProfile> | undefined),
	/**
	 * Allow everything on or off for an agent (#294). The app asks the person to confirm before it turns it on. Its
	 * conversations take the change at their next message (`takeSwitch`).
	 */
	"agents.allowEverything": async (params) => {
		const id = text(params, "id");
		if (typeof params.on !== "boolean") throw new Error("on must be true or false");
		const on = params.on;
		await harness.commit(async (tx) => {
			const agent = (await tx.doc(Agents)).agents[id];
			if (agent === undefined) throw new Error(`Unknown agent: ${id}`);
			if (on) agent.allowEverything = true;
			else delete agent.allowEverything;
		}, context);
		log("agent", id, on ? "now allows everything" : "no longer allows everything");
		return {};
	},
	"agents.duplicate": async (params) => {
		const sourceId = text(params, "id");
		const source = agents[sourceId];
		if (source === undefined) throw new Error(`Unknown agent: ${sourceId}`);
		// A project agent's copy is in the same project (docs/projects.md, 4.2): not its orchestrator, nor made from its template.
		const { id } = await saveAgent(
			{ ...structuredClone(source), id: undefined, name: `${source.name} copy` },
			{ copiedRules: structuredClone(source.commandRules ?? []), ...(source.projectId === undefined ? {} : { project: source.projectId }) },
		);
		for (const feature of host.features) await feature.agentDuplicated?.(sourceId, id);
		return { id };
	},
	"agents.delete": async (params) => {
		const id = text(params, "id");
		if (agents[id] === undefined) throw new Error(`Unknown agent: ${id}`);
		// At least one agent of no project: the one a conversation starts with when none is named, and a template to copy
		// into a project.
		if (agents[id].projectId === undefined && Object.values(agents).filter((agent) => agent.projectId === undefined).length === 1) throw new Error("Keep at least one agent");
		// A project always has its orchestrator (docs/projects.md, 3.3).
		if (agents[id].role === "orchestrator") throw new Error(`${agents[id].name} is the project's orchestrator. Make another agent the orchestrator first.`);
		for (const feature of host.features) await feature.deletingAgent?.(id);
		await harness.commit(async (tx) => {
			const doc = await tx.doc(Agents);
			delete doc.agents[id];
			for (const other of Object.values(doc.agents)) other.delegates = other.delegates.filter((d) => d !== id);
		}, context);
		return {};
	},
	/** A rule typed in an agent's settings: `command` is its words, such as "npm test". */
	"rules.add": async (params) => {
		const agentId = text(params, "agentId");
		if (agents[agentId] === undefined) throw new Error(`Unknown agent: ${agentId}`);
		const folder = text(params, "folder");
		if (!isAbsolute(folder) || !(existsSync(folder) && statSync(folder).isDirectory())) throw new Error(`Not a folder: ${folder}`);
		return { rule: await addCommandRule(agentId, folder, wordsOf(text(params, "command"))) };
	},
	"rules.remove": async (params) => {
		const words = params.words;
		if (!Array.isArray(words) || words.some((word) => typeof word !== "string")) throw new Error("words must be a list of words");
		await removeCommandRule(text(params, "agentId"), text(params, "folder"), words as string[]);
		return {};
	},
};
