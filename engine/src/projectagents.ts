// Agents of a project, and templates (#457): docs/projects.md, 3.3 and 3.4, and the agent requests of 4.2.
//
// A project agent is an ordinary agent in `pi2.agents` with a `projectId`; a template is an agent with none, so every
// agent that exists today is a template as it stands. Saving, duplicating and deleting stay `agents.save`,
// `agents.duplicate` and `agents.delete` in main.ts, which share their checks with what this file adds through
// `engine.saveAgent`: copying a template into a project, Update from template, putting back an agent removed through a
// tool, and which agents a conversation may hand work to. Which agent a conversation runs as is `runsAs` in state.ts.
//
// What later issues fill in, and what it does until then:
//
// - `removeAgent(id)` is what `project_agents` `remove` does (#465, as its operation `agent.remove`). Nothing calls it
//   until #465 lands; `agents.restore` and the operation `agent.restore` put an agent back.
// - `delegate` calls `admit` (projects.ts) for every start in a project, and asks first through `requireSwitch` while
//   `startAgents` is off (extensions.ts). `admit` admits every start until #464 fills it in.
// - A copy made by an agent (#465) is made at the baseline of 7.2 and asks for the rest; `copyTemplate` here is the
//   person's (and carrying over's, #458), which copies every setting as 3.3 says.

import { realpathSync } from "node:fs";
import type { Tx } from "@earendil-works/pi-durable";
import type { Host } from "./extensions.ts";
import type { Engine, Feature, FeatureParts } from "./features.ts";
import { allProjects, inProject, PROJECT_ARCHIVED, type Project, projectOf, Projects, projectsOn, requirePreview } from "./projects.ts";
import { type AgentProfile, agentOf, Agents } from "./state.ts";

/** What `agents.save` refuses for a project agent given a folder that is not its project's (3.3). */
export const AGENT_IN_FOLDER = "An agent of a project works in the project's folder";
/** Update from template, for a copy whose template is gone (3.3). */
export const TEMPLATE_DELETED = "The template this agent was made from has been deleted";

/**
 * The settings Update from template compares and changes: every setting a copy takes from its template but its name,
 * `cwd`, `delegates`, allowed commands, variables and Allow everything, which are the project's own (3.3). The memory
 * switch, which knowledge.ts keeps outside the profile, is compared too, as `memory`.
 */
export const TEMPLATE_SETTINGS = [
	"description",
	"color",
	"model",
	"thinkingLevel",
	"instructions",
	"access",
	"worktree",
	"setup",
	"maxTurns",
	"codeMode",
	"mcpServers",
	"files",
	"computer",
	"browser",
	"schedule",
	"toolsOff",
	"toolsOn",
	"compactionTokens",
] as const;

/** One setting Update from template would change: its value in the copy now, and in the template. */
export type TemplateChange = { setting: (typeof TEMPLATE_SETTINGS)[number] | "memory"; now: unknown; template: unknown };

/**
 * A setting as `agents.save` stores it, so an agent saved before a setting existed (the starter agents have no
 * `computer`, say) compares equal to a copy saved since, which has the default.
 */
function normal(setting: (typeof TEMPLATE_SETTINGS)[number], agent: AgentProfile): unknown {
	switch (setting) {
		case "description":
			return agent.description ?? "";
		case "color":
			return agent.color ?? "violet";
		case "model":
			return agent.model ?? null;
		case "thinkingLevel":
			return agent.thinkingLevel ?? null;
		case "instructions":
			return agent.instructions ?? "";
		case "access":
			return agent.access ?? "none";
		case "worktree":
			return agent.worktree ?? false;
		case "setup":
			return agent.setup ?? "";
		case "maxTurns":
			return agent.maxTurns ?? null;
		case "codeMode":
			return agent.codeMode ?? false;
		case "mcpServers":
			return agent.mcpServers ?? [];
		case "files":
			return agent.files ?? [];
		case "computer":
			return { enabled: agent.computer?.enabled === true, apps: agent.computer?.apps ?? [], ask: agent.computer?.ask !== false, testCopies: agent.computer?.testCopies === true };
		case "browser":
			return { enabled: agent.browser?.enabled === true, ask: agent.browser?.ask !== false };
		case "schedule":
			return { enabled: agent.schedule?.enabled === true };
		case "toolsOff":
			return agent.toolsOff ?? [];
		case "toolsOn":
			return agent.toolsOn ?? [];
		case "compactionTokens":
			return agent.compactionTokens ?? null;
	}
}

/** JSON with every object's keys in order, so two values that differ only in the order of their keys compare equal. */
function canonical(value: unknown): string {
	return JSON.stringify(value, (_key, inner) =>
		inner !== null && typeof inner === "object" && !Array.isArray(inner) ? Object.fromEntries(Object.entries(inner).sort(([a], [b]) => a.localeCompare(b))) : inner,
	);
}

/** What Update from template would change in `copy`, setting by setting, in the order of `TEMPLATE_SETTINGS`. */
export function templateChanges(copy: AgentProfile, template: AgentProfile, memory?: { copy: boolean; template: boolean }): TemplateChange[] {
	const changes: TemplateChange[] = [];
	for (const setting of TEMPLATE_SETTINGS) {
		const now = normal(setting, copy);
		const then = normal(setting, template);
		if (canonical(now) !== canonical(then)) changes.push({ setting, now, template: then });
	}
	if (memory !== undefined && memory.copy !== memory.template) changes.push({ setting: "memory", now: memory.copy, template: memory.template });
	return changes;
}

/**
 * The agents a conversation may hand work to, in order (3.3, 5.1). With the preview off, those its agent's `delegates`
 * name, as before projects. With it on: in its project's orchestrator's current conversation, every other agent of the
 * project, whatever its `delegates` say; in any other conversation of a project, those its `delegates` name that are
 * agents of that project; outside any project, those that are templates. An agent removed through a tool is offered to
 * nobody. `conversationId` is undefined for a conversation not made yet, which will be in its agent's project.
 */
export function delegateTargets(own: AgentProfile | undefined, agents: Record<string, AgentProfile>, conversationId?: number): AgentProfile[] {
	const named = (own?.delegates ?? []).map((id) => agents[id]).filter((agent): agent is AgentProfile => agent !== undefined && agent.removedAt === undefined);
	if (!projectsOn()) return named;
	const projectId = conversationId === undefined ? own?.projectId : projectOf(conversationId)?.id;
	if (projectId === undefined) return named.filter((agent) => agent.projectId === undefined);
	const project = conversationId === undefined ? undefined : inProject(conversationId);
	if (project !== undefined && project.conversation === conversationId) {
		return Object.values(agents)
			.filter((agent) => agent.projectId === project.id && agent.removedAt === undefined && agent.id !== own?.id)
			.sort((a, b) => a.createdAt - b.createdAt);
	}
	return named.filter((agent) => agent.projectId === projectId);
}

/**
 * Whether `agents.save` stamps `updatedAt`. Not while the preview has never been on, when nothing new is written
 * (section 2); always once there is a project, whatever the preview, so that a template's `updatedAt` stays true for
 * the copies made of it. With the preview on and no project yet, too.
 */
export function stampsAgents(): boolean {
	return projectsOn() || Object.keys(allProjects()).length > 0;
}

/**
 * The folder a project agent works in, for `agents.save`: its project's, whatever it is sent, and a folder given that is
 * not the project's is refused (3.3). The project's folder is not checked again: one that has gone since is kept.
 */
export function projectAgentFolder(projectId: string, given: unknown): string | null {
	const folder = allProjects()[projectId]?.folder ?? null;
	if (given === undefined || given === folder) return folder;
	if (typeof given === "string" && folder !== null) {
		try {
			if (realpathSync(given) === folder) return folder;
		} catch {
			// Not a folder at all: not the project's either.
		}
	}
	throw new Error(AGENT_IN_FOLDER);
}

/** The engine's host and engine, once the feature is made: for `removeAgent`, which a tool calls (#465). */
let wired: { host: Host; engine: Engine } | undefined;

/**
 * Remove a project agent through a tool (5.2, 3.12): kept whole, its variables' values in the Keychain, offered to
 * nobody, listed as removed, and put back by `agents.restore`. Refuses the orchestrator, and an agent working now. #465's
 * `project_agents` `remove` calls it, as the operation `agent.remove`; nothing does before.
 */
export async function removeAgent(id: string): Promise<void> {
	if (wired === undefined) throw new Error("The project agents feature is not running");
	const { engine } = wired;
	await engine.harness().commit((tx) => removeAgentIn(tx, id), engine.context());
}

/** `removeAgent` in the caller's commit `tx`, with the same checks, read from that commit: the operation `agent.remove` (changes.ts). */
export async function removeAgentIn(tx: Tx, id: string): Promise<void> {
	if (wired === undefined) throw new Error("The project agents feature is not running");
	const { host } = wired;
	const agents = (await tx.doc(Agents)).agents;
	const agent = agents[id];
	if (agent?.projectId === undefined || agent.removedAt !== undefined) throw new Error(`Unknown agent: ${id}`);
	const project = (await tx.doc(Projects)).projects[agent.projectId];
	if (project === undefined || project.deletedAt !== undefined) throw new Error(`Unknown project: ${agent.projectId}`);
	if (project.archivedAt !== undefined) throw new Error(PROJECT_ARCHIVED);
	if (agent.role === "orchestrator") throw new Error(`${agent.name} is the project's orchestrator. Make another agent the orchestrator first.`);
	const working = Object.entries(host.conversations()).find(([key, meta]) => meta.deleted !== true && agentOf(meta, agents)?.id === id && host.working(Number(key)));
	if (working !== undefined) {
		throw new Error(`${agent.name} is working on ${working[1].parent === undefined ? "conversation" : "sub-chat"} ${working[0]}. Wait for it, or ask the person to stop it.`);
	}
	agent.removedAt = Date.now();
}

export const projectAgents: Feature = (host, engine) => {
	wired = { host, engine };

	/** A project that exists and was not deleted; for a change, one not archived either (4.1). */
	const projectFor = (value: unknown, changing: boolean): Project => {
		const project = typeof value === "string" ? allProjects()[value] : undefined;
		if (project === undefined || project.deletedAt !== undefined) throw new Error(`Unknown project: ${String(value)}`);
		if (changing && project.archivedAt !== undefined) throw new Error(PROJECT_ARCHIVED);
		return project;
	};
	/** An agent of a project, not removed, by the id a request gives (4.1). */
	const projectAgent = (value: unknown): AgentProfile => {
		const agent = typeof value === "string" ? engine.agents()[value] : undefined;
		if (agent?.projectId === undefined || agent.removedAt !== undefined) throw new Error(`Unknown agent: ${String(value)}`);
		return agent;
	};

	/**
	 * The memory switch, which knowledge.ts keeps outside the profile: read from the `memory` event it sends and set
	 * through its own request, so that this file needs nothing more of it while #461 changes it.
	 */
	const memoryFeature = (): FeatureParts | undefined => host.features.find((feature) => feature.handlers?.["memory.setEnabled"] !== undefined);
	const memoryOn = (agentId: string): boolean => {
		const event = memoryFeature()?.greeting?.().find((each) => (each as { event?: unknown }).event === "memory") as { agents?: Record<string, { enabled?: boolean }> } | undefined;
		return event?.agents?.[agentId]?.enabled === true;
	};

	/**
	 * Copy template `templateId` into `project` (3.3), by the person (or by carrying over, #458): through the same path as
	 * `agents.duplicate`, but into the project, with its folder, the template it came from, its `delegates` mapped to the
	 * project's copies of the templates they name (one with none is left out), and every allowed command. The memory
	 * switch and the variables' names are copied by the features that keep them, as for a duplicate; Allow everything and
	 * the variables' values are not. No conversation, schedule or worktree is copied.
	 */
	const copyTemplate = async (project: Project, templateId: unknown): Promise<{ id: string }> => {
		const agents = engine.agents();
		const template = typeof templateId === "string" ? agents[templateId] : undefined;
		if (template === undefined || template.projectId !== undefined) throw new Error(`Unknown agent: ${String(templateId)}`);
		const copyOf = (id: string) =>
			Object.values(agents)
				.filter((agent) => agent.projectId === project.id && agent.template?.id === id)
				.sort((a, b) => a.createdAt - b.createdAt)[0]?.id;
		const delegates = template.delegates.map(copyOf).filter((id): id is string => id !== undefined);
		const now = Date.now();
		const { id } = await engine.saveAgent(
			{ ...structuredClone(template), id: undefined, cwd: project.folder, delegates },
			{
				copiedRules: structuredClone(template.commandRules ?? []),
				project: project.id,
				marks: { template: { id: template.id, copiedAt: now, templateUpdatedAt: template.updatedAt ?? template.createdAt } },
			},
		);
		for (const feature of host.features) await feature.agentDuplicated?.(template.id, id);
		return { id };
	};

	return {
		handlers: {
			/**
			 * `{ projectId, template?, agent? }`: an agent of the project, a copy of `template` or made from `agent` (the
			 * fields `agents.save` takes), with the same checks as `agents.save`. Answers `{ id }`.
			 */
			"projects.addAgent": async (params) => {
				requirePreview();
				const project = projectFor(params.projectId, true);
				if (params.template !== undefined && params.agent !== undefined) throw new Error("Give a template to copy, or the agent's settings, not both");
				if (params.template !== undefined) return copyTemplate(project, params.template);
				if (params.agent === null || typeof params.agent !== "object" || Array.isArray(params.agent)) throw new Error("agent must be the agent's settings, or give a template to copy");
				return engine.saveAgent({ ...(params.agent as Partial<AgentProfile>), id: undefined }, { project: project.id });
			},
			/** `{ id }`: put back a project agent removed through a tool. Nothing to do for one not removed. */
			"agents.restore": async (params) => {
				requirePreview();
				const agent = typeof params.id === "string" ? engine.agents()[params.id] : undefined;
				if (agent?.projectId === undefined) throw new Error(`Unknown agent: ${String(params.id)}`);
				projectFor(agent.projectId, true);
				if (agent.removedAt === undefined) return {};
				await engine.harness().commit(async (tx) => void delete (await tx.doc(Agents)).agents[agent.id]?.removedAt, engine.context());
				return {};
			},
			/**
			 * `{ id, apply }`: what Update from template would change in a copy, setting by setting, and with `apply: true`,
			 * changes it, through `agents.save`'s checks, and notes when the copy was brought up to date. With `apply` false
			 * or absent it changes nothing, and is allowed in an archived project.
			 */
			"agents.updateFromTemplate": async (params) => {
				requirePreview();
				if (params.apply !== undefined && typeof params.apply !== "boolean") throw new Error("apply must be true or false");
				const copy = projectAgent(params.id);
				projectFor(copy.projectId, params.apply === true);
				if (copy.template === undefined) throw new Error(`${copy.name} was not made from a template`);
				const template = engine.agents()[copy.template.id];
				if (template === undefined || template.projectId !== undefined) throw new Error(TEMPLATE_DELETED);
				const memory = { copy: memoryOn(copy.id), template: memoryOn(template.id) };
				const changes = templateChanges(copy, template, memoryFeature() === undefined ? undefined : memory);
				if (params.apply !== true) return { changes, applied: false };
				const settings = Object.fromEntries(changes.filter((change) => change.setting !== "memory").map((change) => [change.setting, structuredClone(change.template)]));
				const now = Date.now();
				await engine.saveAgent(
					{ ...settings, id: copy.id, name: copy.name },
					{ marks: { template: { id: template.id, copiedAt: now, templateUpdatedAt: template.updatedAt ?? template.createdAt } } },
				);
				if (changes.some((change) => change.setting === "memory")) await memoryFeature()?.handlers?.["memory.setEnabled"]?.({ agentId: copy.id, enabled: memory.template });
				return { changes, applied: true };
			},
		},
	};
};
