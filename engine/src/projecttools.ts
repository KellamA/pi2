// The orchestrator's tools to change its project (#465): `project_agents`, `project_settings` and `project_rules`,
// docs/projects.md 5.2 to 5.4, with the table of 5.9 and the reach of section 7.
//
// Only the project's orchestrator, in its current conversation with the person, may use them (5.1); reading is open to
// any access, changing takes Ask first or Full access. Each change is worked out against what is stored now, in the
// tool's own commit: what does not widen reach is made at once and recorded with its Undo (changes.ts); what widens is
// never made by the tool, but put to the person as one reach request, and the agent is told so. A call run again after
// a crash finds what it did, by its call id. `makeAgents` off makes `project_agents` ask first, as an approval
// (`requireSwitch`); `addRules` off makes an added rule a proposal.

import type { Context } from "@earendil-works/chord/context";
import { defineDoc, defineTool, type JsonObject, type ToolExecutionApi, type ToolExecutionResult, type Tx } from "@earendil-works/pi-durable";
import { arr, bool, int, nullable, num, obj, opt, str } from "@earendil-works/pi-schema";
import { BUILT_IN_TOOLS } from "./builtins.ts";
import { afterChanges, applyAgentFields, applyOp, askedText, askReach, canSetOrchestrator, type ChangeBy, changeIn, checkOp, inverseOf, memoryOf, type Op, opWidens, reachOf, record, undoIn, undoRefusal } from "./changes.ts";
import type { Host } from "./extensions.ts";
import type { Engine } from "./features.ts";
import { putNeed } from "./needs.ts";
import { removeAgentIn, TEMPLATE_DELETED, TEMPLATE_SETTINGS } from "./projectagents.ts";
import { addRule, editRule, moveRule, type ProjectRule, ruleBinding, rulesIn, ruleText } from "./projectrules.ts";
import { changeProjectSettings, checkFolder, inProject, type Project, Projects, requireSwitch, SWITCH_NAMES, type SwitchName } from "./projects.ts";
import { ACCESS_LABELS, AGENT_FIELDS, type AgentValues, agentFieldWidens, agentValues, copy, describeFields, type Field, labelOf, PROJECT_FIELDS, projectFieldWidens, projectValues, render, same, splitNew } from "./reach.ts";
import { type CommandRule, type MadeWorktree, ruleFolder, ruleRefusal, sameFolder, wordsOf } from "./rules.ts";
import { ACCESS_LEVELS, type Access, type AgentProfile, Agents, type ModelRef } from "./state.ts";
import { madeWorktrees } from "./worktrees.ts";

export const TOOL_NAMES = ["project_agents", "project_settings", "project_rules"] as const;

// ---- Results

const text = (value: string) => [{ type: "text" as const, text: value }];
const refuse = (value: string): ToolExecutionResult => ({ output: text(value), isError: true });

/** What a call did, as kept for a call run again: the text the model is given, and the change and request it made. */
type Done = { text: string; change?: number; need?: string };

const answer = (done: Done): ToolExecutionResult => {
	const details: JsonObject = {};
	if (done.change !== undefined) details.change = done.change;
	if (done.need !== undefined) details.need = done.need;
	return { output: text(done.text), ...(Object.keys(details).length === 0 ? {} : { details }) };
};

/** What each call did, kept with the call's task, so that the call run again after a crash finds it and does no more. */
const Calls = defineDoc<{ results: Record<string, JsonObject> }>({
	kind: "pi2.projectToolCall",
	version: 1,
	scope: "task",
	initial: () => ({ results: {} }),
	checkpointWhen: () => true,
});

const key = (api: ToolExecutionApi) => `call:${api.callId}`;
const prior = async (api: ToolExecutionApi, context: Context): Promise<Done | undefined> => (await api.snapshot(Calls, api.taskId, context))?.results[key(api)] as Done | undefined;

/**
 * Run `work` in the call's own commit, once: everything it changes, records and asks for is stored together with what
 * the call answers. A refusal it throws changes nothing, and is the model's answer.
 */
async function once(api: ToolExecutionApi, context: Context, work: (tx: Tx) => Promise<Done>): Promise<ToolExecutionResult> {
	try {
		const done = await api.commit(async (tx) => {
			const { results } = await tx.doc(Calls, api.taskId);
			const earlier = results[key(api)] as Done | undefined;
			if (earlier !== undefined) return earlier;
			const value = await work(tx);
			results[key(api)] = JSON.parse(JSON.stringify(value)) as JsonObject;
			return value;
		}, context);
		await afterChanges();
		return answer(done);
	} catch (error) {
		return refuse(error instanceof Error ? error.message : String(error));
	}
}

// ---- Who is calling

type Call = { conversationId: number; project: Project; agentId: string; access: Access; by: Extract<ChangeBy, { kind: "agent" }> };

const NOT_HERE = "This works only in a project's conversation with its orchestrator, with projects turned on.";
const NOT_ORCHESTRATOR = "Only the project's orchestrator, in its conversation with the person, changes the project. Say what you need in your answer, for the orchestrator to do.";
const NO_ACCESS = "This agent's access does not let it change the project: that takes Ask first or Full access.";

/** The orchestrator's current conversation of a project neither archived nor deleted, with the preview on (5.1); else why not. */
function callOf(host: Host, api: ToolExecutionApi): Call | string {
	const conversationId = api.conversationId as unknown as number;
	const meta = host.meta(api.conversationId);
	const project = inProject(conversationId);
	if (project === undefined) return NOT_HERE;
	if (meta?.parent !== undefined || project.conversation !== conversationId) return NOT_ORCHESTRATOR;
	const agentId = host.agentOf(api.conversationId)?.id ?? "";
	return { conversationId, project, agentId, access: meta?.access ?? "none", by: { kind: "agent", agentId, conversationId, callId: api.callId } };
}

const mayChange = (call: Call) => call.access === "ask" || call.access === "full";

/** The project as stored in the commit `tx`, still neither archived nor deleted. */
async function projectIn(tx: Tx, id: string): Promise<Project> {
	const project = (await tx.doc(Projects)).projects[id];
	const why = await checkOp(tx, id, { kind: "project.change", fields: [] });
	if (project === undefined || why !== undefined) throw new Error(why ?? `Unknown project: ${id}`);
	return project;
}

// ---- Agents and their settings

/** An agent of project `projectId`, by its name (any case) or id: removed ones only when `removed`. */
function agentNamed(agents: Record<string, AgentProfile>, projectId: string, name: string, removed = false): AgentProfile | undefined {
	const wanted = name.trim();
	return Object.values(agents).find((agent) => agent.projectId === projectId && (agent.removedAt !== undefined) === removed && (agent.id === wanted || agent.name.toLowerCase() === wanted.toLowerCase()));
}

/** An agent of the project, or the refusal that says why there is none. */
function agentOrRefuse(agents: Record<string, AgentProfile>, projectId: string, name: string | undefined, removed = false): AgentProfile {
	if (name === undefined || name.trim() === "") throw new Error("Give the agent's name in agent.");
	const agent = agentNamed(agents, projectId, name, removed);
	if (agent !== undefined) return agent;
	if (agentNamed(agents, projectId, name, !removed) !== undefined) throw new Error(removed ? `${name} is not removed.` : `${name} is removed; restore it first.`);
	throw new Error(`${name} is not an agent of this project. list shows them.`);
}

/** A template (an agent of no project, not removed), by name or id. */
function templateNamed(agents: Record<string, AgentProfile>, name: string): AgentProfile | undefined {
	const wanted = name.trim();
	return Object.values(agents).find((agent) => agent.projectId === undefined && agent.removedAt === undefined && (agent.id === wanted || agent.name.toLowerCase() === wanted.toLowerCase()));
}

const namesIn = (agents: Record<string, AgentProfile>) => (id: string) => agents[id]?.name ?? id;

/** What a new agent made from settings alone starts from, as `agents.save` would give it. */
const NEW_AGENT: AgentProfile = { id: "", name: "", description: "", color: "violet", model: null, thinkingLevel: null, instructions: "", access: "none", cwd: null, delegates: [], maxTurns: null, createdAt: 0 };

type Settings = {
	name?: string;
	description?: string;
	instructions?: string;
	model?: string;
	thinking?: string;
	access?: string;
	worktree?: boolean;
	setup?: string;
	turn_limit?: number | null;
	summarise_at?: number | null;
	memory?: boolean;
	code_mode?: boolean;
	delegates?: string[];
	built_in_tools?: { on?: string[]; off?: string[] };
	computer?: { enabled?: boolean; apps?: string[]; ask?: boolean; test_copies?: boolean };
	browser?: { enabled?: boolean; ask?: boolean };
	mcp_servers?: string[];
	reference_files?: string[];
	schedule?: boolean;
	allowed_commands?: { add?: string[]; remove?: string[] };
	allow_everything?: boolean;
};

/** "provider/model id", or "default" for the app's default model. */
function modelOf(given: string): ModelRef | null {
	const value = given.trim();
	if (value === "" || value.toLowerCase() === "default") return null;
	const slash = value.indexOf("/");
	if (slash <= 0 || slash === value.length - 1) throw new Error('model must be "provider/model id", as the model menu names it, or "default"');
	return { provider: value.slice(0, slash), modelId: value.slice(slash + 1) };
}

/**
 * An agent's settings, `base` with what `settings` changes, checked as far as the tool can; `engine.saveAgent` checks
 * the rest when they are saved. Allowed commands are words in the project's folder.
 */
function wanted(base: AgentValues, settings: Settings, at: { agents: Record<string, AgentProfile>; project: Project; self?: string; worktrees: MadeWorktree[] }): AgentValues {
	const next = copy(base);
	if (settings.name !== undefined) {
		if (settings.name.trim() === "") throw new Error("Give the agent a name.");
		next.name = settings.name.trim();
	}
	if (settings.description !== undefined) next.description = settings.description.trim();
	if (settings.instructions !== undefined) next.instructions = settings.instructions;
	if (settings.model !== undefined) next.model = modelOf(settings.model);
	if (settings.thinking !== undefined) next.thinkingLevel = ["", "default"].includes(settings.thinking.trim().toLowerCase()) ? null : settings.thinking.trim();
	if (settings.access !== undefined) {
		if (!ACCESS_LEVELS.includes(settings.access as Access)) throw new Error("access must be none, read, ask or full");
		next.access = settings.access;
	}
	if (settings.worktree !== undefined) next.worktree = settings.worktree;
	if (settings.setup !== undefined) next.setup = settings.setup.trim();
	if (settings.turn_limit !== undefined) next.maxTurns = settings.turn_limit;
	if (settings.summarise_at !== undefined) next.compactionTokens = settings.summarise_at;
	if (settings.memory !== undefined) next.memory = settings.memory;
	if (settings.code_mode !== undefined) next.codeMode = settings.code_mode;
	if (settings.allow_everything !== undefined) next.allowEverything = settings.allow_everything;
	if (settings.schedule !== undefined) next.schedule = { enabled: settings.schedule };
	if (settings.delegates !== undefined) {
		next.delegates = [
			...new Set(
				settings.delegates.map((name) => {
					const agent = agentNamed(at.agents, at.project.id, name);
					if (agent === undefined) throw new Error(`${name} is not an agent of this project.`);
					if (agent.id === at.self) throw new Error("An agent cannot hand work to itself.");
					return agent.id;
				}),
			),
		];
	}
	if (settings.built_in_tools !== undefined) {
		const off = new Set(next.toolsOff as string[]);
		const on = new Set(next.toolsOn as string[]);
		const known = (name: string) => {
			const tool = BUILT_IN_TOOLS.find((one) => one.key === name);
			if (tool === undefined) throw new Error(`Unknown built-in tool: ${name}. They are: ${BUILT_IN_TOOLS.map((one) => one.key).join(", ")}.`);
			return tool;
		};
		for (const name of settings.built_in_tools.on ?? []) known(name).offByDefault ? on.add(name) : off.delete(name);
		for (const name of settings.built_in_tools.off ?? []) known(name).offByDefault ? on.delete(name) : off.add(name);
		next.toolsOff = BUILT_IN_TOOLS.filter((tool) => off.has(tool.key)).map((tool) => tool.key);
		next.toolsOn = BUILT_IN_TOOLS.filter((tool) => on.has(tool.key)).map((tool) => tool.key);
	}
	if (settings.computer !== undefined) {
		const was = next.computer as { enabled: boolean; apps: string[]; ask: boolean; testCopies: boolean };
		const given = settings.computer;
		next.computer = { enabled: given.enabled ?? was.enabled, apps: given.apps === undefined ? was.apps : [...new Set(given.apps)], ask: given.ask ?? was.ask, testCopies: given.test_copies ?? was.testCopies };
	}
	if (settings.browser !== undefined) {
		const was = next.browser as { enabled: boolean; ask: boolean };
		next.browser = { enabled: settings.browser.enabled ?? was.enabled, ask: settings.browser.ask ?? was.ask };
	}
	if (settings.mcp_servers !== undefined) next.mcpServers = [...new Set(settings.mcp_servers.map((one) => one.trim()))];
	if (settings.reference_files !== undefined) {
		const was = next.files as { path: string; note: string }[];
		next.files = [...new Set(settings.reference_files.map((one) => one.trim()))].map((path) => was.find((file) => file.path === path) ?? { path, note: "" });
	}
	if (settings.allowed_commands !== undefined) {
		if (at.project.folder === null) throw new Error("This project has no folder, so its agents have no allowed commands.");
		const folder = ruleFolder(at.project.folder, at.worktrees);
		let rules = copy(next.commandRules as CommandRule[]);
		const matches = (rule: CommandRule, words: string[]) => sameFolder(rule.folder, folder) && same(rule.words, words);
		for (const command of settings.allowed_commands.add ?? []) {
			const words = wordsOf(command);
			const refused = ruleRefusal(words);
			if (refused !== undefined) throw new Error(refused);
			if (!rules.some((rule) => matches(rule, words))) rules.push({ folder, words, createdAt: Date.now() });
		}
		for (const command of settings.allowed_commands.remove ?? []) {
			const words = wordsOf(command);
			const kept = rules.filter((rule) => !matches(rule, words));
			if (kept.length === rules.length) throw new Error(`There is no allowed command “${command}” in the project's folder.`);
			rules = kept;
		}
		next.commandRules = rules;
	}
	return next;
}

/** The profile `engine.saveAgent` takes, from an agent's settings: all but those it never takes from a request. */
function profileOf(values: AgentValues): Partial<AgentProfile> {
	const { memory: _memory, commandRules: _rules, allowEverything: _everything, ...profile } = copy(values);
	return profile as unknown as Partial<AgentProfile>;
}

/** "access to Read files; model to the default model". */
const describeChange = (fields: Field[], names?: (id: string) => string) => fields.map((field) => `${labelOf(field.name)} to ${render(field.name, field.after, names)}`).join("; ");

/**
 * Change agent `agent`'s settings by `fields`, in the commit `tx`: what does not widen reach is made and recorded as one
 * change; what widens is asked for, as one request. `lead` begins the change's line ("Changed Forge"); `marks` are set with the change
 * when nothing is asked for (Update from template's).
 */
async function changeAgent(tx: Tx, call: Call, agent: AgentProfile, fields: Field[], agents: Record<string, AgentProfile>, lead: string, why: string | null, marks?: Pick<AgentProfile, "template">): Promise<Done> {
	const names = namesIn(agents);
	if (fields.length === 0) return { text: `Nothing to change: ${agent.name} has those settings already.` };
	const made = fields.filter((field) => !agentFieldWidens(field.name, field.before, field.after));
	const asked = fields.filter((field) => agentFieldWidens(field.name, field.before, field.after));
	const lines: string[] = [];
	const done: Done = { text: "" };
	if (made.length > 0) {
		await applyAgentFields(tx, agent.id, made, asked.length === 0 ? marks : undefined);
		const op: Op = { kind: "agent.change", id: agent.id, fields: made };
		const summary = `${lead}: ${describeChange(made, names)}`;
		const change = await record(tx, call.project.id, { by: call.by, op, inverse: inverseOf(op), summary });
		lines.push(`${summary}. The person can undo it. (change ${change.id})`);
		done.change = change.id;
	}
	if (asked.length > 0) {
		const name = (made.find((field) => field.name === "name")?.after as string | undefined) ?? agent.name;
		const reach = reachOf({ kind: "agent.change", id: agent.id, fields: asked }, `Change ${name}: ${describeFields(asked, names)}`);
		const { need, already } = await askReach(tx, { projectId: call.project.id, conversationId: call.conversationId, callId: call.by.callId, change: reach, why });
		lines.push(askedText(reach.summary, need, already));
		done.need = need.id;
	}
	done.text = lines.join("\n");
	return done;
}

const AGENTS_DESCRIPTION =
	"Make, change, remove and restore the agents of this project, and list them and the templates. Only the project's orchestrator has it.\n" +
	"- list: the project's agents, with model, access, whether each is working, and description. templates: the templates a new agent can be copied from.\n" +
	"- make: a new agent, from `settings` (a name at least), or a copy of `template` changed by `settings`.\n" +
	"- change: change `agent`'s `settings`; those not given are kept.\n" +
	"- remove: take `agent` out of use: it is offered to nobody, and the person can restore it. restore: put a removed `agent` back.\n" +
	"- update_from_template: what would change in `agent` to match its template; with `apply: true`, change it.\n" +
	"Each change is made at once, and the person sees it as a line they can undo; the result ends with its number. A setting that widens what agents may do (more access, Allow everything, a built-in tool, app, MCP server, reference file, allowed command or delegate added, computer use, the browser, scheduling, worktrees, a set-up command, memory) is never made by this tool: it is put to the person, whose answer comes to you later. Give `why` to tell them why. Variables, sign-ins, colours and the templates themselves are the person's.";

function agentsTool(host: Host, engine: Engine) {
	return defineTool({
		name: "project_agents",
		description: AGENTS_DESCRIPTION,
		parameters: obj({
			action: str({ description: "list, templates, make, change, remove, restore or update_from_template" }),
			agent: opt(str({ description: "The name of an agent of the project: change, remove, restore, update_from_template" })),
			template: opt(str({ description: "make: the name of a template to copy" })),
			settings: opt(
				obj(
					{
						name: opt(str()),
						description: opt(str()),
						instructions: opt(str()),
						model: opt(str({ description: '"provider/model id", as the model menu names it, or "default"' })),
						thinking: opt(str({ description: "The thinking level, or default" })),
						access: opt(str({ description: "none (tools off), read (read files), ask (ask first) or full (full access)" })),
						worktree: opt(bool({ description: "Each conversation gets a git worktree of its own" })),
						setup: opt(str({ description: "A command run in each new worktree" })),
						turn_limit: opt(nullable(int({ description: "The most turns a run may take; null for none" }))),
						summarise_at: opt(nullable(int({ description: "Summarise the conversation at this many tokens; null for the default" }))),
						memory: opt(bool()),
						code_mode: opt(bool()),
						delegates: opt(arr(str(), { description: "The names of the project's agents it may hand work to" })),
						built_in_tools: opt(obj({ on: opt(arr(str())), off: opt(arr(str())) }, { description: `Built-in tools by key: ${BUILT_IN_TOOLS.map((tool) => tool.key).join(", ")}` })),
						computer: opt(obj({ enabled: opt(bool()), apps: opt(arr(str(), { description: "Bundle ids" })), ask: opt(bool()), test_copies: opt(bool()) })),
						browser: opt(obj({ enabled: opt(bool()), ask: opt(bool()) })),
						mcp_servers: opt(arr(str(), { description: "The ids of the person's MCP servers" })),
						reference_files: opt(arr(str(), { description: "Absolute paths" })),
						schedule: opt(bool({ description: "It may set schedules for itself" })),
						allowed_commands: opt(obj({ add: opt(arr(str())), remove: opt(arr(str())) }, { description: "Commands it may run without asking, such as \"npm test\", in the project's folder" })),
						allow_everything: opt(bool()),
					},
					{ description: "make and change: the settings to set; those not given are kept" },
				),
			),
			apply: opt(bool({ description: "update_from_template: true to change it; by default it only says what would change" })),
			why: opt(str({ description: "For a change that widens what agents may do: why, shown to the person" })),
		}),
		replay: "safe",
		execute: async (args, api, context): Promise<ToolExecutionResult> => {
			const call = callOf(host, api);
			if (typeof call === "string") return refuse(call);
			const action = args.action.trim().toLowerCase();
			const agents = engine.agents();
			const project = call.project;
			if (action === "list") {
				const conversations = host.conversations();
				const working = (id: string) => Object.entries(conversations).some(([key, meta]) => meta.deleted !== true && host.agentOf(Number(key) as never)?.id === id && host.working(Number(key)));
				const line = (agent: AgentProfile) =>
					`- ${agent.name}${agent.role === "orchestrator" ? " (the orchestrator, you)" : ""}${agent.removedAt !== undefined ? " (removed)" : ""}: ${render("model", agent.model ?? null)}, ${ACCESS_LABELS[agent.access]}${agent.removedAt === undefined ? `, ${working(agent.id) ? "working" : "idle"}` : ""}${agent.description.trim() === "" ? "" : `. ${agent.description.trim()}`}`;
				const mine = Object.values(agents)
					.filter((agent) => agent.projectId === project.id)
					.sort((a, b) => Number(a.removedAt !== undefined) - Number(b.removedAt !== undefined) || a.createdAt - b.createdAt);
				return { output: text(`The agents of ${project.name}:\n${mine.map(line).join("\n")}`) };
			}
			if (action === "templates") {
				const templates = Object.values(agents)
					.filter((agent) => agent.projectId === undefined && agent.removedAt === undefined)
					.sort((a, b) => a.name.localeCompare(b.name));
				if (templates.length === 0) return { output: text("There are no templates.") };
				return { output: text(`Templates a new agent can be copied from:\n${templates.map((one) => `- ${one.name}${one.description.trim() === "" ? "" : `: ${one.description.trim()}`}`).join("\n")}`) };
			}
			if (!["make", "change", "remove", "restore", "update_from_template"].includes(action)) return refuse(`Unknown action: ${args.action}. Use list, templates, make, change, remove, restore or update_from_template.`);
			if (!mayChange(call)) return refuse(NO_ACCESS);
			const earlier = await prior(api, context);
			if (earlier !== undefined) return answer(earlier);
			// Refuse what cannot be done before asking the person about it.
			let what: string;
			try {
				if (action === "make") {
					if (args.template !== undefined && templateNamed(agents, args.template) === undefined) throw new Error(`There is no template called ${args.template}. templates lists them.`);
					const name = args.settings?.name ?? (args.template === undefined ? undefined : templateNamed(agents, args.template)?.name);
					if (name === undefined || name.trim() === "") throw new Error("Give the new agent a name in settings, or a template to copy.");
					what = `Make the agent ${name.trim()}${args.template === undefined ? "" : `, a copy of the template ${templateNamed(agents, args.template)!.name}`}.`;
				} else {
					const agent = agentOrRefuse(agents, project.id, args.agent, action === "restore");
					if (action === "change") what = `Change ${agent.name}'s settings: ${Object.keys(args.settings ?? {}).join(", ") || "none"}.`;
					else if (action === "remove") what = `Remove the agent ${agent.name}.`;
					else if (action === "restore") what = `Restore the agent ${agent.name}.`;
					else what = `Update ${agent.name} from its template.`;
				}
			} catch (error) {
				return refuse((error as Error).message);
			}
			// Only Update from template's look at what would change changes nothing, and so asks nothing.
			if (!(action === "update_from_template" && args.apply !== true)) {
				const allowed = await requireSwitch({ conversationId: call.conversationId, id: String(api.taskId), callId: api.callId, tool: "project_agents", arguments: args, api, context }, "makeAgents", what);
				if (!allowed.ok) return refuse(allowed.reason);
			}
			const worktrees = args.settings?.allowed_commands === undefined ? [] : await madeWorktrees(api, context);
			const why = args.why?.trim() || null;
			return once(api, context, async (tx) => {
				await projectIn(tx, project.id);
				const stored = (await tx.doc(Agents)).agents;
				const all = copy(stored);
				if (action === "make") {
					let base: AgentValues;
					let template: AgentProfile | undefined;
					if (args.template !== undefined) {
						template = templateNamed(all, args.template);
						if (template === undefined) throw new Error(`There is no template called ${args.template}. templates lists them.`);
						base = agentValues(template, await memoryOf(tx, template.id));
						// Its delegates as the project's copies of the templates they name (3.3); one with none is left out.
						const copyOf = (id: string) =>
							Object.values(all)
								.filter((agent) => agent.projectId === project.id && agent.removedAt === undefined && agent.template?.id === id)
								.sort((a, b) => a.createdAt - b.createdAt)[0]?.id;
						base.delegates = template.delegates.map(copyOf).filter((id): id is string => id !== undefined);
						base.allowEverything = false;
					} else base = agentValues(NEW_AGENT, false);
					const want = wanted(base, args.settings ?? {}, { agents: all, project, worktrees });
					if (want.name === "") throw new Error("Give the new agent a name in settings, or a template to copy.");
					// Made at the baseline for every setting that would widen reach, and one request for all of those (7.1, 7.2).
					const { made, asked } = splitNew(want);
					const now = Date.now();
					const { id } = await engine.saveAgent(
						{ ...profileOf(made), id: undefined, cwd: project.folder },
						{
							tx,
							project: project.id,
							marks: { madeBy: { agentId: call.agentId, conversationId: call.conversationId }, ...(template === undefined ? {} : { template: { id: template.id, copiedAt: now, templateUpdatedAt: template.updatedAt ?? template.createdAt } }) },
							// A copy takes " 2", " 3"… when its name is taken, as a duplicate does; its allowed commands are asked for.
							...(template === undefined ? {} : { copiedRules: [] }),
						},
					);
					const agent = copy((await tx.doc(Agents)).agents[id]!);
					const summary = `Made the agent ${agent.name}${template === undefined ? "" : `, a copy of the template ${template.name}`} (${render("model", agent.model)}, ${ACCESS_LABELS[agent.access]})`;
					const change = await record(tx, project.id, { by: call.by, op: { kind: "agent.make", agent }, inverse: { kind: "agent.remove", id }, summary });
					const done: Done = { text: `${summary}. The person can undo it. (change ${change.id})`, change: change.id };
					if (asked.length === 0) return done;
					const reach = reachOf({ kind: "agent.change", id, fields: asked }, `Change ${agent.name}: ${describeFields(asked, namesIn({ ...all, [id]: agent }))}`);
					const { need, already } = await askReach(tx, { projectId: project.id, conversationId: call.conversationId, callId: api.callId, change: reach, why });
					return { text: `${done.text}\n${askedText(reach.summary, need, already)}`, change: change.id, need: need.id };
				}
				const agent = agentOrRefuse(all, project.id, args.agent, action === "restore");
				if (action === "remove") {
					await removeAgentIn(tx, agent.id);
					const summary = `Removed the agent ${agent.name}`;
					const change = await record(tx, project.id, { by: call.by, op: { kind: "agent.remove", id: agent.id }, inverse: { kind: "agent.restore", id: agent.id }, summary });
					return { text: `${summary}: it is offered to nobody now. The person can undo it. (change ${change.id})`, change: change.id };
				}
				if (action === "restore") {
					const op: Op = { kind: "agent.restore", id: agent.id };
					await applyOp(tx, project.id, op);
					const summary = `Restored the agent ${agent.name}`;
					const change = await record(tx, project.id, { by: call.by, op, inverse: inverseOf(op), summary });
					return { text: `${summary}, with every setting it had. The person can undo it. (change ${change.id})`, change: change.id };
				}
				const now = agentValues(agent, await memoryOf(tx, agent.id));
				if (action === "change") {
					const want = wanted(now, args.settings ?? {}, { agents: all, project, self: agent.id, worktrees });
					const fields = AGENT_FIELDS.filter((name) => !same(now[name], want[name])).map((name): Field => ({ name, before: now[name], after: want[name] }));
					return changeAgent(tx, call, agent, fields, all, `Changed ${agent.name}`, why);
				}
				// update_from_template
				if (agent.template === undefined) throw new Error(`${agent.name} was not made from a template.`);
				const template = all[agent.template.id];
				if (template === undefined || template.projectId !== undefined) throw new Error(`${TEMPLATE_DELETED}.`);
				const theirs = agentValues(template, await memoryOf(tx, template.id));
				const fields = [...TEMPLATE_SETTINGS, "memory" as const].filter((name) => !same(now[name], theirs[name])).map((name): Field => ({ name, before: now[name], after: theirs[name] }));
				if (args.apply !== true) {
					if (fields.length === 0) return { text: `${agent.name} has every setting of the template ${template.name} already.` };
					return { text: `Updating ${agent.name} from the template ${template.name} would change: ${describeFields(fields, namesIn(all))}. Nothing was changed; call again with apply: true to update it.` };
				}
				const marks = { template: { id: template.id, copiedAt: Date.now(), templateUpdatedAt: template.updatedAt ?? template.createdAt } };
				return changeAgent(tx, call, agent, fields, all, `Updated ${agent.name} from its template`, why, marks);
			});
		},
	});
}

// ---- The project's settings

const SWITCH_KEYS: Record<string, SwitchName> = {
	start_agents: "startAgents",
	file_work: "fileWork",
	close_work: "closeWork",
	make_agents: "makeAgents",
	add_rules: "addRules",
	merge: "merge",
	release: "release",
	pass_limits: "passLimits",
};
const SWITCH_WORDS = Object.fromEntries(Object.entries(SWITCH_KEYS).map(([words, name]) => [name, words])) as Record<SwitchName, string>;

type ProjectChanges = {
	name?: string;
	folder?: string | null;
	repository?: string | null;
	without_asking?: Record<string, boolean>;
	limits?: { plan_share?: number | null; daily_spend?: number | null };
};

const SETTINGS_DESCRIPTION =
	"See and change this project's settings. Only the project's orchestrator has it.\n" +
	"- show: its name, folder, work list, the switches for what you may do without asking, and its limits.\n" +
	"- change: make `changes`. Renaming, turning a switch off and lowering a limit are made at once, and the person can undo them. Changing the folder, turning a switch on, and raising or removing a limit widen what agents may do, so they are put to the person, whose answer comes to you later; give `why`.\n" +
	"- set_orchestrator: ask the person to make `agent` the project's orchestrator in your place.\n" +
	"- undo: undo change `change`, the number at the end of a change's result. An undo that would widen what agents may do is put to the person.";

function settingsTool(host: Host, engine: Engine) {
	return defineTool({
		name: "project_settings",
		description: SETTINGS_DESCRIPTION,
		parameters: obj({
			action: str({ description: "show, change, set_orchestrator or undo" }),
			changes: opt(
				obj({
					name: opt(str()),
					folder: opt(nullable(str({ description: "The project's folder, an absolute path; null for none" }))),
					repository: opt(nullable(str({ description: '"owner/name"' }))),
					without_asking: opt(
						obj(
							{
								start_agents: opt(bool()),
								file_work: opt(bool()),
								close_work: opt(bool()),
								make_agents: opt(bool()),
								add_rules: opt(bool()),
								merge: opt(bool()),
								release: opt(bool()),
								pass_limits: opt(bool()),
							},
							{ description: "What you may do without asking: true lets you, false asks the person first" },
						),
					),
					limits: opt(obj({ plan_share: opt(nullable(int({ description: "Percent, 1 to 100" }))), daily_spend: opt(nullable(num({ description: "Dollars" }))) })),
				}),
			),
			agent: opt(str({ description: "set_orchestrator: the agent of the project to become the orchestrator" })),
			change: opt(int({ description: "undo: the number of a change" })),
			why: opt(str({ description: "For a change that widens what agents may do: why, shown to the person" })),
		}),
		replay: "safe",
		execute: async (args, api, context): Promise<ToolExecutionResult> => {
			const call = callOf(host, api);
			if (typeof call === "string") return refuse(call);
			const action = args.action.trim().toLowerCase();
			const project = call.project;
			if (action === "show") {
				const settings = project.settings;
				const lines = [
					`Project: ${project.name}`,
					`Folder: ${project.folder ?? "none"}`,
					`Work list: ${project.repository === null ? "kept by pi²" : `the issues of ${project.repository.owner}/${project.repository.name} on GitHub`}`,
					`Without asking, you may: ${SWITCH_NAMES.map((name) => `${SWITCH_WORDS[name]} ${settings.withoutAsking[name] ? "on" : "off"}`).join(", ")}`,
					`Waking on reports: ${settings.wakeOnReports ? "on" : "off"} (the person's switch)`,
					`Limits: plan share ${render("limits.planShare", settings.limits.planShare)}, daily spending ${render("limits.dailySpend", settings.limits.dailySpend)}`,
				];
				return { output: text(lines.join("\n")) };
			}
			if (!["change", "set_orchestrator", "undo"].includes(action)) return refuse(`Unknown action: ${args.action}. Use show, change, set_orchestrator or undo.`);
			if (!mayChange(call)) return refuse(NO_ACCESS);
			if (action === "set_orchestrator" && !canSetOrchestrator()) return refuse("pi² cannot make another agent the orchestrator yet: that comes with Start fresh. Tell the person, if it matters.");
			const why = args.why?.trim() || null;
			return once(api, context, async (tx) => {
				const stored = await projectIn(tx, project.id);
				if (action === "change") {
					const given = (args.changes ?? {}) as ProjectChanges;
					if (given.repository !== undefined) throw new Error("pi² cannot attach a repository to a project yet. Tell the person, if it matters.");
					const now = projectValues(stored);
					const want = { ...now };
					if (given.name !== undefined) want.name = given.name.trim();
					if (given.folder !== undefined) want.folder = checkFolder(given.folder);
					for (const [words, on] of Object.entries(given.without_asking ?? {})) {
						const name = SWITCH_KEYS[words];
						if (name === undefined) throw new Error(`Unknown switch: ${words}. They are: ${Object.keys(SWITCH_KEYS).join(", ")}.`);
						want[`withoutAsking.${name}`] = on;
					}
					if (given.limits?.plan_share !== undefined) want["limits.planShare"] = given.limits.plan_share;
					if (given.limits?.daily_spend !== undefined) want["limits.dailySpend"] = given.limits.daily_spend;
					const fields = PROJECT_FIELDS.filter((name) => !same(now[name], want[name])).map((name): Field => ({ name, before: now[name], after: want[name] }));
					if (fields.length === 0) return { text: "Nothing to change: the project has those settings already." };
					// Checked now, as `projects.set` checks them, so that what is asked for could be made.
					const limits = Object.fromEntries(fields.filter((field) => field.name.startsWith("limits.")).map((field) => [field.name.slice(7), field.after]));
					if (Object.keys(limits).length > 0) changeProjectSettings(stored.settings, { limits });
					const made = fields.filter((field) => !projectFieldWidens(field.name, field.before, field.after));
					const asked = fields.filter((field) => projectFieldWidens(field.name, field.before, field.after));
					const lines: string[] = [];
					const done: Done = { text: "" };
					if (made.length > 0) {
						const op: Op = { kind: "project.change", fields: made };
						await applyOp(tx, project.id, op);
						const summary = `Changed the project: ${describeChange(made)}`;
						const change = await record(tx, project.id, { by: call.by, op, inverse: inverseOf(op), summary });
						lines.push(`${summary}. The person can undo it. (change ${change.id})`);
						done.change = change.id;
					}
					if (asked.length > 0) {
						const reach = reachOf({ kind: "project.change", fields: asked }, `Change the project ${stored.name}: ${describeFields(asked)}`);
						const { need, already } = await askReach(tx, { projectId: project.id, conversationId: call.conversationId, callId: api.callId, change: reach, why });
						lines.push(askedText(reach.summary, need, already));
						done.need = need.id;
					}
					done.text = lines.join("\n");
					return done;
				}
				if (action === "set_orchestrator") {
					const agents = (await tx.doc(Agents)).agents;
					const agent = agentOrRefuse(agents, project.id, args.agent);
					if (agent.id === stored.orchestratorId) throw new Error(`${agent.name} is the orchestrator already.`);
					const from = agents[stored.orchestratorId]?.name ?? "the orchestrator";
					const reach = reachOf({ kind: "orchestrator.set", from: stored.orchestratorId, to: agent.id }, `Make ${agent.name} the project's orchestrator in place of ${from}: it starts a fresh conversation with ${agent.name}, and cannot be undone`);
					const { need, already } = await askReach(tx, { projectId: project.id, conversationId: call.conversationId, callId: api.callId, change: reach, why });
					return { text: already ? askedText(reach.summary, need, true) : `${reach.summary}: this is the person's to decide, so it was put to them as ${need.id}. You will be told their answer. Do not ask again meanwhile.`, need: need.id };
				}
				// undo
				if (args.change === undefined) throw new Error("Give the number of the change to undo in change.");
				const found = await changeIn(tx, args.change);
				if (found === undefined || found.projectId !== project.id) throw new Error(`There is no change ${args.change} in this project.`);
				const refused = undoRefusal(found, args.change);
				if (refused !== undefined) throw new Error(refused);
				const inverse = found.change.inverse!;
				const blocked = await checkOp(tx, project.id, inverse);
				if (blocked !== undefined) throw new Error(blocked);
				// An agent's undo is checked against reach, as any change it makes (3.12): undoing the removal of a rule, say.
				if (opWidens(inverse)) {
					const reach = reachOf(inverse, `Undo change ${args.change}: ${found.change.summary}`, args.change);
					const { need, already } = await askReach(tx, { projectId: project.id, conversationId: call.conversationId, callId: api.callId, change: reach, why });
					return { text: askedText(reach.summary, need, already), need: need.id };
				}
				const undo = await undoIn(tx, args.change, call.by, { kind: "agent", agentId: call.agentId, conversationId: call.conversationId });
				return { text: `Undid change ${args.change}: ${found.change.summary}. (change ${undo.id})`, change: undo.id };
			});
		},
	});
}

// ---- Rules

const RULES_DESCRIPTION =
	"The person's rules for this project, which its agents keep at every turn: every agent, or only you, the orchestrator. Only the orchestrator has this tool.\n" +
	"- list: each rule with its id, whom it binds and who added it.\n" +
	"- add: for a rule the person has told you to keep. To suggest one yourself, use propose. The person sees it added, with Undo; with the project's settings asking, it is proposed to them instead.\n" +
	"- propose: put a rule to the person, who accepts, edits or refuses it; you will be told which.\n" +
	"- edit: change rule `rule`'s `text` or whom it `binds`. Making it bind every agent is made at once; any other edit is put to the person.\n" +
	"- move: put rule `rule` at place `to`, counted from 1. Order decides nothing but the order shown.\n" +
	"- remove: ask the person to remove rule `rule`.";

const bindsWords = (binds: ProjectRule["binds"]) => (binds === "everyone" ? "every agent" : "the orchestrator");

function rulesTool(host: Host, engine: Engine) {
	return defineTool({
		name: "project_rules",
		description: RULES_DESCRIPTION,
		parameters: obj({
			action: str({ description: "list, add, propose, edit, move or remove" }),
			rule: opt(str({ description: "The rule's id, such as r3: edit, move, remove" })),
			text: opt(str({ description: "add, propose, edit: the rule, as the agents will read it" })),
			binds: opt(str({ description: "add, propose, edit: everyone (the default) or orchestrator" })),
			to: opt(int({ description: "move: the place, counted from 1" })),
			why: opt(str({ description: "propose, and an edit or removal put to the person: why, shown to them" })),
		}),
		replay: "safe",
		execute: async (args, api, context): Promise<ToolExecutionResult> => {
			const call = callOf(host, api);
			if (typeof call === "string") return refuse(call);
			const action = args.action.trim().toLowerCase();
			const project = call.project;
			if (action === "list") {
				const rules = await api.commit((tx) => rulesIn(tx, project.id), context);
				if (rules.length === 0) return { output: text("This project has no rules.") };
				const agents = engine.agents();
				const who = (rule: ProjectRule) =>
					rule.addedBy.kind === "person" ? "the person" : rule.addedBy.kind === "agent" ? (agents[rule.addedBy.agentId]?.name ?? "an agent") : `the person, from ${agents[rule.addedBy.agentId]?.name ?? "an agent"}'s proposal`;
				return { output: text(`The project's rules, in order:\n${rules.map((rule) => `- ${rule.id} (binds ${bindsWords(rule.binds)}; added by ${who(rule)}): ${rule.text}`).join("\n")}`) };
			}
			if (!["add", "propose", "edit", "move", "remove"].includes(action)) return refuse(`Unknown action: ${args.action}. Use list, add, propose, edit, move or remove.`);
			if (!mayChange(call)) return refuse(NO_ACCESS);
			const why = args.why?.trim() || null;
			return once(api, context, async (tx) => {
				const stored = await projectIn(tx, project.id);
				if (action === "add" || action === "propose") {
					if (args.text === undefined) throw new Error("Give the rule's text.");
					const text = ruleText(args.text);
					const binds = ruleBinding(args.binds ?? "everyone");
					if (action === "add" && stored.settings.withoutAsking.addRules) {
						const rule = await addRule(tx, project.id, { text, binds, addedBy: { kind: "agent", agentId: call.agentId, conversationId: call.conversationId } });
						const at = (await rulesIn(tx, project.id)).length - 1;
						const summary = `Added rule ${rule.id}: “${rule.text}”`;
						const change = await record(tx, project.id, { by: call.by, op: { kind: "rule.add", rule, at }, inverse: { kind: "rule.remove", rule, at }, summary });
						return { text: `Added rule ${rule.id}, binding ${bindsWords(binds)}: “${rule.text}”. The person sees it, and can undo it. (change ${change.id})`, change: change.id };
					}
					const need = await putNeed(tx, { kind: "rule", projectId: project.id, conversationId: call.conversationId, callId: api.callId, text, binds, why });
					const lead = action === "add" ? "The project's settings have rules proposed to the person first, so it" : "It";
					return { text: `${lead} was put to the person as ${need.id}, who will accept, edit or refuse it. You will be told which.`, need: need.id };
				}
				if (args.rule === undefined) throw new Error("Give the rule's id in rule, such as r3.");
				const rules = await rulesIn(tx, project.id);
				const at = rules.findIndex((rule) => rule.id === args.rule!.trim());
				if (at === -1) throw new Error(`There is no rule ${args.rule} in this project. list shows them.`);
				const rule = rules[at]!;
				if (action === "move") {
					if (args.to === undefined) throw new Error("Give the place to move it to in to, counted from 1.");
					const from = await moveRule(tx, project.id, rule.id, args.to - 1);
					if (from === args.to - 1) return { text: `Rule ${rule.id} is at place ${args.to} already.` };
					const op: Op = { kind: "rule.move", id: rule.id, from, to: args.to - 1 };
					const change = await record(tx, project.id, { by: call.by, op, inverse: inverseOf(op), summary: `Moved rule ${rule.id} to place ${args.to}` });
					return { text: `Moved rule ${rule.id} to place ${args.to}. The person can undo it. (change ${change.id})`, change: change.id };
				}
				if (action === "remove") {
					const op: Op = { kind: "rule.remove", rule, at };
					const reach = reachOf(op, `Remove rule ${rule.id}: “${rule.text}”`);
					const { need, already } = await askReach(tx, { projectId: project.id, conversationId: call.conversationId, callId: api.callId, change: reach, why });
					return { text: askedText(reach.summary, need, already), need: need.id };
				}
				// edit
				const after = { text: args.text === undefined ? rule.text : ruleText(args.text), binds: args.binds === undefined ? rule.binds : ruleBinding(args.binds) };
				if (after.text === rule.text && after.binds === rule.binds) return { text: `Nothing to change: rule ${rule.id} says that already.` };
				const op: Op = { kind: "rule.edit", id: rule.id, before: { text: rule.text, binds: rule.binds }, after };
				const parts = [...(after.text === rule.text ? [] : [`text to “${after.text}”`]), ...(after.binds === rule.binds ? [] : [`binding ${bindsWords(after.binds)}`])].join(", ");
				if (opWidens(op)) {
					const reach = reachOf(op, `Edit rule ${rule.id}: ${parts}`);
					const { need, already } = await askReach(tx, { projectId: project.id, conversationId: call.conversationId, callId: api.callId, change: reach, why });
					return { text: askedText(reach.summary, need, already), need: need.id };
				}
				await editRule(tx, project.id, rule.id, after);
				const summary = `Edited rule ${rule.id}: ${parts}`;
				const change = await record(tx, project.id, { by: call.by, op, inverse: inverseOf(op), summary });
				return { text: `${summary}. The person can undo it. (change ${change.id})`, change: change.id };
			});
		},
	});
}

/** The three tools, for the changes feature to offer (changes.ts). */
export function projectTools(host: Host, engine: Engine) {
	return [agentsTool(host, engine), settingsTool(host, engine), rulesTool(host, engine)];
}
