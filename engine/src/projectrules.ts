// Project rules (#459): the board's document and requests, and the instructions the model gets outside its history.
import { defineDoc, type Tx } from "@earendil-works/pi-durable";
import type { Feature } from "./features.ts";
import { inProject, PROJECT_ARCHIVED, Projects, requirePreview, wireRuleTokens } from "./projects.ts";

export type ProjectRulesDoc = { projects: Record<string, { rules: ProjectRule[]; next: number }> };

export type ProjectRule = {
	id: string;
	text: string;
	binds: "orchestrator" | "everyone";
	addedBy:
		| { kind: "person" }
		| { kind: "agent"; agentId: string; conversationId: number }
		| { kind: "proposal"; agentId: string; conversationId: number; need: string };
	createdAt: number;
	updatedAt: number;
};

const emptyRules = (): ProjectRulesDoc => ({ projects: {} });
const ProjectRules = defineDoc<ProjectRulesDoc>({
	kind: "pi2.projectRules",
	version: 1,
	scope: "session",
	initial: emptyRules,
	checkpointWhen: () => true,
});

/** A rule's text as stored: its lines trimmed, blank ones dropped; 1 to 1,000 characters. */
export function ruleText(value: unknown): string {
	if (typeof value !== "string") throw new Error("text must be a string");
	const text = value.split(/\r\n?|\n/).map((line) => line.trim()).filter(Boolean).join("\n");
	if (text.length === 0 || text.length > 1_000) throw new Error("A rule must be 1 to 1,000 characters long");
	return text;
}

export function ruleBinding(value: unknown): ProjectRule["binds"] {
	if (value !== "orchestrator" && value !== "everyone") throw new Error('binds must be "orchestrator" or "everyone"');
	return value;
}

function projectIdOf(value: unknown): string {
	if (typeof value !== "string") throw new Error("projectId must be a project's id");
	return value;
}

async function checkProject(tx: Tx, projectId: string): Promise<void> {
	const { projects } = await tx.doc(Projects);
	const project = Object.hasOwn(projects, projectId) ? projects[projectId] : undefined;
	if (project === undefined || project.deletedAt !== undefined) throw new Error(`Unknown project: ${projectId}`);
	if (project.archivedAt !== undefined) throw new Error(PROJECT_ARCHIVED);
}

/**
 * Append a rule in the caller's commit. The person's request supplies its own `addedBy` (never the request's);
 * `project_rules` `add` calls it with the `addRules` switch on, and the handler of a proposal once the person accepts it
 * (changes.ts).
 */
export async function addRule(tx: Tx, projectId: string, given: { text: unknown; binds: unknown; addedBy: ProjectRule["addedBy"] }): Promise<ProjectRule> {
	requirePreview();
	const text = ruleText(given.text);
	const binds = ruleBinding(given.binds);
	await checkProject(tx, projectId);
	const doc = await tx.doc(ProjectRules);
	doc.projects[projectId] ??= { rules: [], next: 1 };
	// Re-read through the draft so changes to a newly inserted list are tracked too.
	const list = doc.projects[projectId]!;
	if (list.rules.length >= 50) throw new Error("This project has 50 rules, the most it can have. Remove one first.");
	const now = Date.now();
	const rule: ProjectRule = { id: `r${list.next++}`, text, binds, addedBy: given.addedBy, createdAt: now, updatedAt: now };
	list.rules.push(rule);
	return rule;
}

/** A plain copy of what a commit's document holds: its drafts are not plain objects. */
const plain = <T>(value: T): T => JSON.parse(JSON.stringify(value)) as T;

/** The rules of a project not deleted or archived, in the commit `tx`, and rule `id`'s place among them. */
async function ruleIn(tx: Tx, projectId: string, id: string): Promise<{ rules: ProjectRule[]; at: number }> {
	await checkProject(tx, projectId);
	const rules = (await tx.doc(ProjectRules)).projects[projectId]?.rules;
	const at = rules?.findIndex((rule) => rule.id === id) ?? -1;
	if (rules === undefined || at === -1) throw new Error(`Unknown rule: ${id}`);
	return { rules, at };
}

/** The rules of a project as stored in the commit `tx`: a copy, to read. */
export async function rulesIn(tx: Tx, projectId: string): Promise<ProjectRule[]> {
	return plain((await tx.doc(ProjectRules)).projects[projectId]?.rules ?? []);
}

/**
 * Change rule `id`'s text or whom it binds in the caller's commit, each checked: `projects.rules.edit`, and the operation
 * `rule.edit` (changes.ts). Answers the rule as it was and as it is.
 */
export async function editRule(tx: Tx, projectId: string, id: string, given: { text?: unknown; binds?: unknown }): Promise<{ before: ProjectRule; after: ProjectRule }> {
	const { rules, at } = await ruleIn(tx, projectId, id);
	const rule = rules[at]!;
	const before = plain(rule);
	const text = given.text === undefined ? rule.text : ruleText(given.text);
	const binds = given.binds === undefined ? rule.binds : ruleBinding(given.binds);
	if (text !== rule.text || binds !== rule.binds) {
		rule.text = text;
		rule.binds = binds;
		rule.updatedAt = Date.now();
	}
	return { before, after: plain(rule) };
}

/** Move rule `id` to place `to`, counted from 0, in the caller's commit: `projects.rules.move` and `rule.move`. Answers where it was. */
export async function moveRule(tx: Tx, projectId: string, id: string, to: unknown): Promise<number> {
	const { rules, at } = await ruleIn(tx, projectId, id);
	if (typeof to !== "number" || !Number.isInteger(to) || to < 0 || to >= rules.length) throw new Error(`to must be a whole number from 0 to ${rules.length - 1}`);
	if (at !== to) rules.splice(to, 0, rules.splice(at, 1)[0]!);
	return at;
}

/** Remove rule `id` in the caller's commit: `projects.rules.remove` and `rule.remove`. Answers the rule and where it was. */
export async function removeRule(tx: Tx, projectId: string, id: string): Promise<{ rule: ProjectRule; at: number }> {
	const { rules, at } = await ruleIn(tx, projectId, id);
	const [rule] = rules.splice(at, 1);
	return { rule: plain(rule!), at };
}

/**
 * Put a removed rule back, with its id, at place `at` (or the end), in the caller's commit: the Undo of a removal
 * (`rule.add` with the rule it removed). Refused when a rule has that id, or the project has the most it can have.
 */
export async function putBackRule(tx: Tx, projectId: string, rule: ProjectRule, at?: number): Promise<void> {
	await checkProject(tx, projectId);
	const doc = await tx.doc(ProjectRules);
	doc.projects[projectId] ??= { rules: [], next: 1 };
	const list = doc.projects[projectId]!;
	if (list.rules.some((one) => one.id === rule.id)) throw new Error(`There is already a rule ${rule.id}`);
	if (list.rules.length >= 50) throw new Error("This project has 50 rules, the most it can have. Remove one first.");
	const place = at === undefined ? list.rules.length : Math.max(0, Math.min(at, list.rules.length));
	list.rules.splice(place, 0, plain(rule));
	const number = Number(rule.id.slice(1));
	if (Number.isInteger(number) && number >= list.next) list.next = number + 1;
}

const KEY = "project_rules";
const INTRO = "The person's rules for this project. Keep every one at every turn. Their order is only the order they are shown in; none outranks another. If two seem to conflict, or the person asks for something a rule forbids, say so and ask them.";
let current: ProjectRulesDoc = emptyRules();

/** Use the board's numbering even when the viewer sees only some of its rules. */
function section(projectId: string, orchestrator: boolean): string | undefined {
	const rules = current.projects[projectId]?.rules ?? [];
	const lines = [INTRO];
	let last: ProjectRule["binds"] | undefined;
	for (const [index, rule] of rules.entries()) {
		if (rule.binds === "orchestrator" && !orchestrator) continue;
		if (rule.binds !== last) lines.push(rule.binds === "orchestrator" ? "For you, the orchestrator:" : "For every agent:");
		lines.push(`${index + 1}. ${rule.text}`);
		last = rule.binds;
	}
	return last === undefined ? undefined : `<${KEY}>\n${lines.join("\n")}\n</${KEY}>`;
}

/** Separate places in FEATURES for the prompt (6.1) and the greeting (4.4). */
export const projectRulesPrompt: Feature = (host) => ({
	sections: [{
		key: KEY,
		tag: false, // The estimate uses the exact same tagged text.
		render: ({ conversationId }) => {
			const project = inProject(Number(conversationId));
			if (project === undefined) return undefined;
			// The agent it runs as (state.ts, `runsAs`): its agentId, but for a conversation carried over.
			return section(project.id, host.agentOf(conversationId)?.id === project.orchestratorId);
		},
	}],
});

export const projectRules: Feature = (_host, engine) => {
	const event = () => ({
		event: "projectRules" as const,
		projects: Object.fromEntries(Object.entries(current.projects).filter(([, list]) => list.rules.length > 0).map(([id, list]) => [id, list.rules])),
	});
	let sent = "";
	const updateRule = (edit: (tx: Tx, projectId: string, id: string, params: Record<string, unknown>) => Promise<unknown>) => async (params: Record<string, unknown>) => {
		requirePreview();
		const projectId = projectIdOf(params.projectId);
		const { id } = params;
		if (typeof id !== "string") throw new Error("id must be a rule's id");
		await engine.harness().commit((tx) => edit(tx, projectId, id, params), engine.context());
		return {};
	};
	return {
		start: async () => {
			const harness = engine.harness();
			current = await harness.snapshot(ProjectRules, engine.context()) ?? emptyRules();
			const rulesChanged = wireRuleTokens((id) => ({
				orchestrator: Math.ceil((section(id, true)?.length ?? 0) / 4),
				agents: Math.ceil((section(id, false)?.length ?? 0) / 4),
			}));
			sent = JSON.stringify(event());
			rulesChanged();
			// Use the committed revision: both socket requests and #465's commits are visible before the next request.
			harness.observeCommits({
				advance: ({ changes }) => {
					const change = changes.find((one) => one.type === "document" && one.record.kind === ProjectRules.definition.kind);
					if (change?.type !== "document") return;
					current = change.kind === "change" ? change.value as ProjectRulesDoc : emptyRules();
					const next = event();
					const line = JSON.stringify(next);
					if (line === sent) return;
					sent = line;
					engine.broadcast(next);
					rulesChanged();
				},
				end: () => {},
			});
		},
		greeting: () => [event()],
		handlers: {
			"projects.rules.add": async (params) => {
				requirePreview();
				const projectId = projectIdOf(params.projectId);
				return engine.harness().commit(async (tx) => ({ id: (await addRule(tx, projectId, { text: params.text, binds: params.binds, addedBy: { kind: "person" } })).id }), engine.context());
			},
			"projects.rules.edit": updateRule((tx, projectId, id, params) => editRule(tx, projectId, id, { text: params.text, binds: params.binds })),
			"projects.rules.move": updateRule((tx, projectId, id, params) => moveRule(tx, projectId, id, params.to)),
			"projects.rules.remove": updateRule((tx, projectId, id) => removeRule(tx, projectId, id)),
		},
	};
};
