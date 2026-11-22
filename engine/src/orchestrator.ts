// One conversation with a project's orchestrator, what it is told of the project, and Start fresh (#466).
//
// docs/projects.md is the contract: 6.1 for the `project` section, 6.3 to 6.6 for the rest. The project's state is not a
// prompt section, which would be sent again whole at almost every turn of a busy orchestrator and stay in its context
// until a summary. It reaches the orchestrator in two typed entries of its transcript instead, each given once, after
// the cached prompt:
//
// - a catch-up (`pi2.catchUp`), in front of each input placed in its current conversation, with the project's `news`
//   (projects.ts) it has not been given yet. It is appended in the commit that places the input, through a hook pi
//   durable calls as it places one (`placeInput`, engine/scripts/patch-dependencies.ts), so a message queued or sent to
//   steer gets the news there is when it is placed, and the news it gives is cleared in that same commit;
// - a state block (`pi2.state`), in front of the first input of a new conversation with the orchestrator, in place of a
//   catch-up, and at the end of what pi² adds to a summary of it (compaction.ts). A summary clears no news.
//
// Start fresh (`projects.startFresh`, and `projects.setOrchestrator`, which also changes the roles) makes that new
// conversation, and moves to it what the old one was waiting for, in one commit (6.5). The old one stays readable, in
// the project's `earlier`, and takes no messages.
//
// Also here: what the person writes straight to another agent of a project, told to the orchestrator at its next turn
// (`pi2.toldOrchestrator`, and a piece of news with `keep`); `sub_chats` and `delegate` reaching the sub-chats of earlier
// conversations; `library`'s `orchestrator`, the conversation state's `project`, `activity`'s `lastLine` and
// `projects`' `lastWords`.
//
// The state block's work for a project with a GitHub repository attached comes from github.ts (#468), through
// `wireWorkState`; for any other project, from the list kept by pi² (work.ts).
// Outside a project, nothing here adds anything to what a conversation is told.

import { type ConversationId, defineDoc, type EntryRecord, InboxDoc, LiveDoc, type Tx } from "@earendil-works/pi-durable";
import type { Host } from "./extensions.ts";
import type { Engine, Feature } from "./features.ts";
import { needItems } from "./needs.ts";
import {
	allProjects,
	inProject,
	type News,
	type Project,
	PROJECT_ARCHIVED,
	projectDeleted,
	Projects,
	type ProjectsDoc,
	type ProjectRow,
	reloadProjects,
	type SwitchName,
	wireFresh,
	wireLastWords,
} from "./projects.ts";
import { type Report, Reports } from "./reports.ts";
import { type AgentProfile, Agents, Library, type Meta } from "./state.ts";
import { reloadWakes, wakeUp, Wakes } from "./wakes.ts";
import { Work, type WorkState } from "./work.ts";

// ---- Entries

/** What the orchestrator was told had changed since its last turn: `{ news }`, read by the model just before its input. */
export const CATCH_UP_ENTRY = "pi2.catchUp";
/** The project as it stands, at the start of a new conversation with the orchestrator: `{ snapshot }`. */
export const STATE_ENTRY = "pi2.state";
/** A line for the person, in another agent's conversation they wrote to: the orchestrator will be told. Display only. */
export const TOLD_ENTRY = "pi2.toldOrchestrator";

/** The most characters a catch-up holds (6.4). */
export const CATCH_UP_ROOM = 4_000;
/** The most pieces of news kept besides those with `keep`; past that the oldest go, and are counted (6.4). */
export const NEWS_KEPT = 200;
/** How much of a message the person wrote to another agent the orchestrator is told (6.4). */
const MESSAGE_CHARS = 300;
/** Each list of the state block is whole up to this many, then says how many more (6.4). */
const LISTED = 30;

/**
 * A conversation with the orchestrator that has not yet been given its state block: one Start fresh or a new project
 * made. The block is given in front of its first input, and this is cleared in the same commit.
 */
const Fresh = defineDoc<{ pending: boolean }>({
	kind: "pi2.orchestratorFresh",
	version: 1,
	scope: "conversation",
	history: "latest",
	fork: "initial",
	initial: () => ({ pending: false }),
	checkpointWhen: () => true,
});

/** The project as it stands (6.4), made from the documents when it is given, in a fixed order. */
export type StateSnapshot = {
	at: number;
	/** Runs of the project's sub-chats going now: number, agent, title, since, waiting for a limit until, or null. */
	working: { chat: number; agent: string; title: string; since: number; limitUntil: number | null }[];
	/** Everything under Needs you for the project: its id, kind and one line (the question, the change, the command). */
	needs: { id: string; kind: string; line: string; conversation: number }[];
	/** Reports not delivered: sub-chat, agent, title, outcome, when. */
	reports: { chat: number; agent: string; title: string; outcome: string; at: number }[];
	/** Open work: counts by state, and every item in progress, waiting or blocked with who holds it. */
	work: { counts: Record<string, number>; held: { id: number; title: string; state: string; agent: string | null }[] };
	/** News with `keep` not yet given. */
	messages: string[];
};

// ---- The state block's work, which github.ts wires in for a project with a repository

/** The states of open work, in the order the state block says them. */
const OPEN: readonly WorkState[] = ["open", "in_progress", "waiting", "blocked"];

/** The work list kept by pi² (work.ts), as the state block says it: nothing when it has no open work. */
async function localWork(tx: Tx, project: Project): Promise<StateSnapshot["work"]> {
	const items = Object.values((await tx.doc(Work)).projects[project.id]?.items ?? {}).filter((item) => OPEN.includes(item.state));
	if (items.length === 0) return { counts: {}, held: [] };
	const counts = Object.fromEntries(OPEN.map((state) => [state, items.filter((item) => item.state === state).length]));
	const held = items
		.filter((item) => item.state !== "open")
		.sort((a, b) => OPEN.indexOf(a.state) - OPEN.indexOf(b.state) || a.id - b.id)
		.map((item) => ({ id: item.id, title: item.title, state: item.state, agent: item.takenBy === null ? null : agentName(item.takenBy.agentId) }));
	return { counts, held };
}

type WorkReader = (tx: Tx, project: Project) => Promise<StateSnapshot["work"]>;
let workState: WorkReader = localWork;

/** github.ts (#468) supplies the work of a project with a repository attached; `read` is given every project, and may hand back to the list kept by pi². */
export function wireWorkState(read: (tx: Tx, project: Project, local: WorkReader) => Promise<StateSnapshot["work"]>): void {
	workState = (tx, project) => read(tx, project, localWork);
}

// ---- Words

const pad = (n: number) => String(n).padStart(2, "0");
const clock = (at: number) => {
	const d = new Date(at);
	return `${pad(d.getHours())}:${pad(d.getMinutes())}`;
};
const MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];
const day = (at: number) => {
	const d = new Date(at);
	return `${d.getDate()} ${MONTHS[d.getMonth()]} ${clock(at)}`;
};
/** One line, cut to `max` characters with an ellipsis. */
const oneLine = (text: string, max: number) => {
	const line = text.replace(/\s+/g, " ").trim();
	return line.length > max ? `${line.slice(0, max - 1).trimEnd()}…` : line;
};
/** The last line of `text` that says something, cut to `max` characters; null when there is none. */
export function lastLineOf(text: string, max: number): string | null {
	const line = text
		.split("\n")
		.map((each) => each.trim())
		.filter((each) => each !== "")
		.at(-1);
	return line === undefined ? null : oneLine(line, max);
}
const textOf = (content: unknown): string =>
	typeof content === "string"
		? content
		: Array.isArray(content)
			? content.map((block) => (block?.type === "text" && typeof block.text === "string" ? block.text : "")).join("")
			: "";
/** A list whole up to `LISTED`, then how many more and which tool lists them. */
const listed = (items: string[], tool: string) => (items.length <= LISTED ? items.join("; ") : `${items.slice(0, LISTED).join("; ")}; and ${items.length - LISTED} more; ${tool} lists them`);

/** The text of a catch-up holding `given`, with what was dropped and what waits for the next one. */
function catchUpText(given: News[], dropped: number, more: number): string {
	const lines = ["[pi² — what changed in the project since your last turn]", ...given.map((news) => `- ${news.text}`)];
	if (dropped > 0) lines.push(`(and ${dropped} older ${dropped === 1 ? "change" : "changes"} not listed)`);
	if (more > 0) lines.push(`…and ${more} more, given at your next turn; reports and work list them now.`);
	return lines.join("\n");
}

/**
 * What one catch-up gives of `news` (oldest first), within `CATCH_UP_ROOM` characters (6.4): every piece with `keep`,
 * then the newest of the rest that fit. Past `NEWS_KEPT` pieces without `keep`, the oldest are dropped and counted.
 * `cleared` is what leaves `news`: what is given and what is dropped; the rest waits for the next input.
 */
export function catchUp(news: readonly News[], room = CATCH_UP_ROOM): { text: string; given: News[]; cleared: Set<string> } {
	const plain = news.filter((each) => each.keep !== true);
	const dropped = plain.slice(0, Math.max(0, plain.length - NEWS_KEPT));
	const candidates = news.filter((each) => !dropped.includes(each));
	const chosen = new Set(candidates.filter((each) => each.keep === true));
	// The room a line takes, with the footers it may need; the footers are counted at their longest.
	const footer = catchUpText([], dropped.length, candidates.length).length;
	let used = footer + [...chosen].reduce((sum, each) => sum + each.text.length + 3, 0);
	for (const each of [...candidates].reverse()) {
		if (chosen.has(each)) continue;
		const size = each.text.length + 3;
		if (used + size > room) continue;
		chosen.add(each);
		used += size;
	}
	const given = candidates.filter((each) => chosen.has(each));
	const more = candidates.length - given.length;
	return { text: catchUpText(given, dropped.length, more), given, cleared: new Set([...given, ...dropped].map((each) => each.id)) };
}

/** The state block's text (6.4): each part "none" when empty, every list whole up to 30 entries. */
export function stateText(snapshot: StateSnapshot): string {
	const working = snapshot.working.map(
		(run) => `sub-chat ${run.chat} “${run.title}” (${run.agent}, ${run.limitUntil === null ? `since ${clock(run.since)}` : `waiting for its provider's limit until ${clock(run.limitUntil)}`})`,
	);
	const needs = snapshot.needs.map((need) => need.line);
	const reports = snapshot.reports.map((report) => `sub-chat ${report.chat} “${report.title}” (${report.agent}) ${report.outcome} at ${clock(report.at)}`);
	const counts = Object.entries(snapshot.work.counts);
	const held = new Map<string, string[]>();
	for (const item of snapshot.work.held) held.set(item.state, [...(held.get(item.state) ?? []), `#${item.id} ${item.agent ?? "nobody"}`]);
	const words = (state: string) => state.replace(/_/g, " ");
	const work =
		counts.length === 0 && snapshot.work.held.length === 0
			? "none."
			: [
					`${counts.map(([state, count]) => `${count} ${words(state)}`).join(", ")}.`,
					...[...held].map(([state, items]) => `${words(state).charAt(0).toUpperCase()}${words(state).slice(1)}: ${listed(items, "work")}.`),
				].join(" ");
	return [
		`[pi² — the project as it stands, ${day(snapshot.at)}]`,
		`Working now: ${working.length === 0 ? "none" : listed(working, "sub_chats")}.`,
		`Under Needs you: ${needs.length === 0 ? "none" : listed(needs, "needs_you")}.`,
		`Reports not read: ${reports.length === 0 ? "none" : listed(reports, "reports")}.`,
		`Work: ${work}`,
		...snapshot.messages,
	].join("\n");
}

// ---- The state, from the documents

let host: Host | undefined;
/** When each conversation's current run was first seen, for "since". In memory: an engine started again counts from then. */
const since = new Map<number, number>();

const isPutAway = (meta: Meta | undefined) => meta === undefined || meta.deleted === true || meta.archivedAt !== undefined;
const agentName = (id: string | undefined) => (id === undefined ? "an agent that was deleted" : (host?.agent(id)?.name ?? "an agent that was deleted"));
const outcomeWords = (outcome: NonNullable<Report["ended"]>["outcome"]) => (outcome === "answered" ? "answered" : outcome === "failed" ? "failed" : "was stopped");
const where = (conversation: number, conversations: Record<string, Meta>) => (conversations[String(conversation)]?.parent === undefined ? `conversation ${conversation}` : `sub-chat ${conversation}`);

/** One line for an item under Needs you, as the state block shows it. */
function needLine(item: ReturnType<typeof needItems>[number], conversations: Record<string, Meta>): string {
	const quoted = (text: string) => `“${oneLine(text, 120)}”`;
	switch (item.kind) {
		case "question":
			return `${item.id} question ${quoted(item.question)}`;
		case "decision":
			return `${item.id} decision ${quoted(item.question)}`;
		case "reach":
			return `${item.id} a request to ${oneLine(item.change.summary, 120)}`;
		case "rule":
			return `${item.id} a proposed rule ${quoted(item.text)}`;
		case "limit":
			return `${item.id} a start past a limit: ${oneLine(item.limit.reason, 120)}`;
		case "approval": {
			const command = (item.arguments as { command?: unknown } | null)?.command;
			const what = item.tool === "bash" && typeof command === "string" ? `command \`${oneLine(command, 100)}\`` : item.tool;
			return `an approval for ${item.agentName ?? "an agent"}'s ${what} (${where(item.conversationId, conversations)})`;
		}
	}
}

/** The project as it stands, read in the commit `tx` that gives it (the Inbox and who is working, as they are now). */
async function snapshotOf(tx: Tx, project: Project, news: readonly News[], now: number): Promise<StateSnapshot> {
	const conversations = host?.conversations() ?? {};
	const waitOf = host?.features.find((feature) => feature.limitWaitOf !== undefined)?.limitWaitOf;
	const working: StateSnapshot["working"] = Object.entries(conversations)
		.filter(([id, meta]) => meta.projectId === project.id && meta.parent !== undefined && !isPutAway(meta) && host?.working(Number(id)) === true)
		.map(([id, meta]) => ({
			chat: Number(id),
			agent: host?.agentOf(Number(id) as unknown as ConversationId)?.name ?? "an agent that was deleted",
			title: meta.title,
			since: since.get(Number(id)) ?? meta.updatedAt,
			limitUntil: waitOf?.(Number(id))?.until ?? null,
		}))
		.sort((a, b) => a.chat - b.chat);
	const needs = needItems()
		.filter((item) => item.projectId === project.id)
		.map((item) => ({ id: item.id, kind: item.kind, line: needLine(item, conversations), conversation: item.conversationId }));
	const reports = ((await tx.doc(Reports)).projects[project.id] ?? [])
		.filter((report) => report.ended !== null && report.delivered === null)
		.sort((a, b) => a.ended!.at - b.ended!.at || a.submissionId - b.submissionId)
		.map((report) => ({ chat: report.conversationId, agent: agentName(report.agentId), title: report.title, outcome: outcomeWords(report.ended!.outcome), at: report.ended!.at }));
	return { at: now, working, needs, reports, work: await workState(tx, project), messages: news.filter((each) => each.keep === true).map((each) => each.text) };
}

const userMessage = (text: string, now: number) => ({ role: "user" as const, content: [{ type: "text" as const, text }], timestamp: now });

/** The project whose current conversation with the orchestrator `conversation` is, neither archived nor deleted. */
const currentOf = (doc: ProjectsDoc, conversation: number): Project | undefined =>
	Object.values(doc.projects).find((project) => project.conversation === conversation && project.archivedAt === undefined && project.deletedAt === undefined);

/**
 * pi durable places an input in conversation `conversationId`, in the commit `tx` (the `placeInput` setting, main.ts):
 * the person's message that starts a turn, a wake, a queued message placed, or a steer placed in the middle of a turn.
 * In a project's current conversation with the orchestrator, the state block or the catch-up goes
 * in front of it, and the news it gives leaves `news` in the same commit. Anywhere else it does nothing at all.
 */
export async function placeInput(tx: Tx, conversationId: number, now: number): Promise<void> {
	const doc = await tx.doc(Projects);
	const project = currentOf(doc, conversationId);
	if (project === undefined) return;
	const news = doc.news[project.id] ?? [];
	const fresh = await tx.doc(Fresh, conversationId as unknown as ConversationId);
	if (fresh.pending) {
		// The state block represents every piece of news (6.4): the messages kept are in it, the rest in its lists.
		const snapshot = await snapshotOf(tx, project, news, now);
		await tx.appendEntry(conversationId as unknown as ConversationId, { kind: STATE_ENTRY, data: { snapshot }, model: [userMessage(stateText(snapshot), now)] });
		fresh.pending = false;
		if (news.length > 0) delete doc.news[project.id];
		return;
	}
	if (news.length === 0) return;
	const told = catchUp(news);
	if (told.given.length > 0 || told.cleared.size > 0) {
		await tx.appendEntry(conversationId as unknown as ConversationId, { kind: CATCH_UP_ENTRY, data: { news: told.given }, model: [userMessage(told.text, now)] });
	}
	const rest = news.filter((each) => !told.cleared.has(each.id));
	if (rest.length === 0) delete doc.news[project.id];
	else doc.news[project.id] = rest;
}

/**
 * The state block pi² adds at the end of a summary of a project's current conversation with the orchestrator, in the
 * commit that places the summary (compaction.ts, `compactionCheckpoint`). It clears no news: what came before the
 * summary still comes in the next catch-up. Undefined anywhere else.
 */
export async function summaryState(tx: Tx, conversationId: number): Promise<string | undefined> {
	const doc = await tx.doc(Projects);
	const project = currentOf(doc, conversationId);
	if (project === undefined) return undefined;
	return stateText(await snapshotOf(tx, project, doc.news[project.id] ?? [], Date.now()));
}

// ---- Earlier conversations

/**
 * The earlier conversations of the project whose current conversation with the orchestrator `conversation` is: their
 * sub-chats are its own too (`sub_chats`, `delegate` with `chat`; 5.8). None for any other.
 */
export function earlierOf(conversation: number): number[] {
	const project = inProject(conversation);
	return project !== undefined && project.conversation === conversation ? [...project.earlier] : [];
}

/** Whether conversation `caller` may reach a sub-chat whose parent is `parent`: its own, or an earlier conversation's. */
export function ownsSubChat(caller: number, parent: number | undefined): boolean {
	return parent !== undefined && (parent === caller || earlierOf(caller).includes(parent));
}

type Role = "current" | "earlier";
/**
 * Every project's current and earlier conversations with its orchestrator, deleted projects' too, as the last commit to
 * `pi2.projects` left them. Kept here from the commit itself, so that the library sent after it says so at once.
 */
let roles = new Map<number, Role>();
const rolesIn = (doc: ProjectsDoc | undefined) => {
	const found = new Map<number, Role>();
	for (const project of Object.values(doc?.projects ?? {})) {
		for (const earlier of project.earlier) found.set(earlier, "earlier");
		if (project.conversation !== null) found.set(project.conversation, "current");
	}
	return found;
};

/** `library`'s `orchestrator`: whether a conversation is a project's current or earlier conversation with its orchestrator. */
export function orchestratorRole(conversation: number): Role | null {
	return roles.get(conversation) ?? null;
}

/** An earlier conversation with the orchestrator takes no messages (3.5). */
export function refuseEarlier(conversation: number): void {
	if (inProject(conversation)?.earlier.includes(conversation) === true) throw new Error("This is an earlier conversation with the orchestrator. Write in the current one.");
}

/**
 * Where the person's answer to what conversation `conversation` put under Needs you goes (6.5): the current
 * conversation with the orchestrator, when `conversation` is an earlier one; else itself.
 */
export async function answerGoesTo(tx: Tx, conversation: number): Promise<{ to: number; earlier: boolean }> {
	const project = Object.values((await tx.doc(Projects)).projects).find((each) => each.earlier.includes(conversation) && each.deletedAt === undefined);
	return project === undefined || project.conversation === null ? { to: conversation, earlier: false } : { to: project.conversation, earlier: true };
}

// ---- What the person writes to another agent (6.4)

/**
 * For a message the person sends to conversation `conversation`: in a project neither archived nor deleted, when it is not the current
 * conversation with the orchestrator, what to do in the commit that takes the message: a piece of news with `keep`, and
 * a line in that conversation saying the orchestrator will be told. Undefined anywhere else, which changes nothing.
 */
export function tellOrchestrator(conversation: number): ((tx: Tx, text: string, files: number) => Promise<void>) | undefined {
	const project = inProject(conversation);
	if (project === undefined || project.conversation === conversation || project.conversation === null) return undefined;
	return async (tx, text, files) => {
		const conversations = (await tx.doc(Library)).conversations;
		const meta = conversations[String(conversation)];
		const agents = (await tx.doc(Agents)).agents;
		const name = host?.agentOf(conversation as unknown as ConversationId)?.name ?? (meta?.agentId === undefined ? undefined : agents[meta.agentId]?.name) ?? "an agent";
		const place = where(conversation, conversations);
		const said = text.replace(/\s+/g, " ").trim();
		const quoted = said.length > MESSAGE_CHARS ? `“${said.slice(0, MESSAGE_CHARS).trimEnd()}…” (the whole message is in ${place})` : `“${said}”`;
		const sent = files === 0 ? "" : ` (with ${files} ${files === 1 ? "file" : "files"})`;
		const line = said === "" ? `The person sent ${name} ${files} ${files === 1 ? "file" : "files"} in ${place}.` : `The person wrote to ${name} in ${place}${sent}: ${quoted}`;
		const doc = await tx.doc(Projects);
		if (doc.projects[project.id] === undefined) return;
		const item: News = { id: `w${doc.nextNews}`, at: Date.now(), kind: "message", text: line, ref: String(conversation), keep: true };
		doc.nextNews += 1;
		doc.news[project.id] = [...(doc.news[project.id] ?? []), item];
		await tx.appendEntry(conversation as unknown as ConversationId, { kind: TOLD_ENTRY, data: { news: item.id } });
	};
}

// ---- What the app is sent

/** The transcript's item for an entry of this file's kinds; undefined for any other (transcript.ts, `toItem`). */
export function projectItem(entry: EntryRecord): { id: number; kind: "marker"; text: string; details?: { wake: { text: string } } } | undefined {
	const id = entry.id as unknown as number;
	const model = textOf((entry.model?.[0] as { content?: unknown } | undefined)?.content);
	if (entry.kind === CATCH_UP_ENTRY) {
		const count = (entry.data as { news?: unknown[] } | undefined)?.news?.length ?? 0;
		return { id, kind: "marker", text: `pi² told the orchestrator what changed (${count})`, details: { wake: { text: model } } };
	}
	if (entry.kind === STATE_ENTRY) return { id, kind: "marker", text: "pi² told the orchestrator how the project stands", details: { wake: { text: model } } };
	if (entry.kind === TOLD_ENTRY) return { id, kind: "marker", text: "The orchestrator will be told" };
	return undefined;
}

// ---- The `project` section (6.1)

const SWITCH_WORDS: Record<SwitchName, string> = {
	startAgents: "start agents",
	fileWork: "file work",
	closeWork: "close work",
	makeAgents: "make and change agents",
	addRules: "add rules",
	merge: "merge",
	release: "release",
	passLimits: "go past a limit",
};
const PROJECT_TOOLS = ["project_agents", "project_settings", "project_rules"];

const folderWords = (project: Project) => (project.folder === null ? "with no folder" : `in ${project.folder}`);
const listWords = (project: Project) => (project.repository === null ? "kept by pi²" : `the issues and pull requests of github.com/${project.repository.owner}/${project.repository.name}`);
const and = (items: string[]) => (items.length <= 1 ? items.join("") : `${items.slice(0, -1).join(", ")} and ${items.at(-1)}`);
const dollars = (amount: number) => (Number.isInteger(amount) ? `$${amount}` : `$${amount.toFixed(2)}`);

/**
 * The `project` section's text for conversation `conversation` of `project`, worked out from documents only, so that it
 * changes only when the project's name, folder, repository, settings or orchestrator change (6.1). A line about a tool
 * is there only while the tool is offered, so that nothing tells the model of a tool it does not have.
 */
export function projectSection(project: Project, conversation: number, offered: ReadonlySet<string>): string {
	if (project.conversation === conversation) {
		const settings = project.settings;
		const free = (Object.keys(SWITCH_WORDS) as SwitchName[]).filter((name) => settings.withoutAsking[name]);
		const asks = (Object.keys(SWITCH_WORDS) as SwitchName[]).filter((name) => !settings.withoutAsking[name]);
		const limits = [
			...(settings.limits.planShare === null ? [] : [`no new agent starts while a plan window it would run on is ${settings.limits.planShare}% used or more`]),
			...(settings.limits.dailySpend === null ? [] : [`${settings.limits.planShare === null ? "no new agent starts" : "and none"} once the project has spent ${dollars(settings.limits.dailySpend)} today`]),
		];
		const tools = PROJECT_TOOLS.filter((name) => offered.has(name));
		return [
			`You are the orchestrator of the pi² project “${project.name}”, ${folderWords(project)}. The person talks to you here; this is the project's one conversation with you.`,
			...(offered.has("work") ? [`Its work list is ${listWords(project)}. Keep it with the work tool, not with scripts or gh of your own.`] : []),
			...(tools.length === 0
				? []
				: [`Change the project with ${and(tools)}; each change shows here with Undo for the person. A change that lets agents do more is never made by a tool: it is put to the person, who allows or refuses it.`]),
			[
				...(free.length === 0 ? [] : [`You may, without asking: ${free.map((name) => SWITCH_WORDS[name]).join(", ")}.`]),
				...(asks.length === 0 ? [] : [`You ask first to: ${asks.map((name) => SWITCH_WORDS[name]).join(", ")}.`]),
				...(asks.includes("release") ? ["“Release” is the person's policy: pi² cannot check it, so keep to it yourself."] : []),
			].join(" "),
			limits.length === 0 ? "Limits: none." : `Limits: ${limits.join(", ")}. Past a limit a start is refused with the reason, and reports do not wake you.`,
			`A report from an agent ${settings.wakeOnReports ? "wakes you" : "does not wake you; it waits until you read it with reports"}.${offered.has("reports") ? " Choose otherwise for particular hand-offs with reports." : ""}`,
			"When something happens in the project while you are not answering, pi² tells you at the start of your next turn.",
			...(offered.has("needs_you") ? ["Put a decision that is the person's to them with needs_you and carry on; do not stop to wait for it."] : []),
		].join("\n");
	}
	const conversations = host?.conversations() ?? {};
	const meta = conversations[String(conversation)];
	const name = host?.agentOf(conversation as unknown as ConversationId)?.name ?? "an agent";
	const orchestrator = host?.agent(project.orchestratorId)?.name ?? "Another agent";
	const parent = meta?.parent;
	// A sub-chat of the orchestrator's conversation, current or earlier, reports to it.
	const reports = parent !== undefined && (parent === project.conversation || project.earlier.includes(parent));
	return [
		`You are ${name}, an agent of the pi² project “${project.name}”, ${folderWords(project)}. ${orchestrator} is its orchestrator.${reports ? " It handed you this work, and your answer is your report to it." : ""}`,
		...(offered.has("work") ? [`The project's work list is ${listWords(project)}. Keep it with the work tool: take what you work on, note progress, and finish it with what was done.`] : []),
		// A worker is told which of its two ways to ask the person to use when (5.8, #507).
		...(parent !== undefined && offered.has("needs_you")
			? [
				"When something is the person's to decide and your work can go on without it, put it to them with needs_you and carry on: their answer comes to you as you work, or, once you have finished, to the agent that handed you this work. Use ask_user only when your next step needs the answer and there is nothing else to do meanwhile.",
				]
			: []),
	].join("\n");
}

/** The `project` section, in its place before `project_rules` (6.1). Nothing outside a project neither archived nor deleted. */
export const projectPrompt: Feature = (given) => {
	host = given;
	return {
		sections: [
			{
				key: "project",
				render: ({ conversationId, agent }) => {
					const project = inProject(Number(conversationId));
					if (project === undefined) return undefined;
					return projectSection(project, Number(conversationId), new Set(agent.tools.map((tool) => tool.name)));
				},
			},
		],
	};
};

// ---- Start fresh (6.5)

/** "Make a fresh conversation for project `id`, with `agentId` as its orchestrator if given": its id. */
async function startFresh(host: Host, engine: Engine, id: string, agentId: string | undefined): Promise<number> {
	const project = allProjects()[id];
	if (project === undefined || project.deletedAt !== undefined) throw new Error(`Unknown project: ${id}`);
	if (project.archivedAt !== undefined) throw new Error(PROJECT_ARCHIVED);
	const found: AgentProfile | undefined = engine.agents()[agentId ?? project.orchestratorId];
	if (agentId !== undefined) {
		if (found === undefined || found.removedAt !== undefined) throw new Error(`Unknown agent: ${agentId}`);
		if (found.projectId !== id) throw new Error(`${found.name} is not an agent of this project`);
		if (agentId === project.orchestratorId) throw new Error(`${found.name} is the project's orchestrator already. To begin again with it, start a fresh conversation.`);
	}
	if (found === undefined) throw new Error("The project's orchestrator was deleted");
	const agent = found;
	const old = project.conversation;
	const oldMeta = old === null ? undefined : host.conversations()[String(old)];
	const before = old !== null && oldMeta !== undefined && oldMeta.deleted !== true ? old : null;
	if (before !== null && host.inbox.list().some((item) => item.conversationId === before)) throw new Error("Answer what the orchestrator is waiting for first.");
	const now = Date.now();
	const chosen = { ...agent, role: "orchestrator" as const, updatedAt: now };
	const configured = await host.agentChange(chosen, { subChat: false });
	const created = await engine.harness().createConversation(
		{
			ownership: { kind: "ownerless" },
			agent: configured,
			init: async (tx, conversation) => {
				const fresh = conversation as unknown as number;
				if (before !== null) {
					const queued = (await tx.doc(InboxDoc, before as unknown as ConversationId)).items.some((item) => item.mode !== "write");
					if (queued) throw new Error("Send or take back your queued message first.");
					if ((await tx.doc(LiveDoc, before as unknown as ConversationId)).run !== undefined) throw new Error("The orchestrator is answering. Let it finish, or stop it, first.");
				}
				const doc = await tx.doc(Projects);
				const stored = doc.projects[id];
				if (stored === undefined || stored.deletedAt !== undefined) throw new Error(`Unknown project: ${id}`);
				if (stored.archivedAt !== undefined) throw new Error(PROJECT_ARCHIVED);
				if (stored.conversation !== old) throw new Error("The project's conversation changed meanwhile. Try again.");
				if (before !== null) stored.earlier = [...stored.earlier, before];
				stored.conversation = fresh;
				stored.updatedAt = now;
				const agents = (await tx.doc(Agents)).agents;
				if (agentId !== undefined) {
					// The roles change in the same commit as the conversation (6.5).
					const previous = agents[stored.orchestratorId];
					if (previous !== undefined) {
						delete previous.role;
						previous.updatedAt = now;
					}
					const next = agents[agentId];
					if (next === undefined || next.removedAt !== undefined || next.projectId !== id) throw new Error(`Unknown agent: ${agentId}`);
					next.role = "orchestrator";
					next.updatedAt = now;
					stored.orchestratorId = agentId;
				}
				(await tx.doc(Library)).conversations[String(fresh)] = {
					title: "",
					createdAt: now,
					updatedAt: now,
					access: agent.access,
					agentId: agent.id,
					projectId: id,
					...(before === null ? {} : { freshFrom: before }),
				};
				(await tx.doc(Fresh, conversation)).pending = true;
				if (before === null) return;
				// What the old conversation was waiting for moves to the new one (6.5's table).
				const wakes = await tx.doc(Wakes);
				for (const watch of Object.values(wakes.watching)) {
					if (watch.conversationId !== before) continue;
					watch.conversationId = fresh;
					if (watch.kind === "background") watch.label = `${watch.label}, started in your earlier conversation`;
				}
				const arrived = wakes.arrived[String(before)];
				if (arrived !== undefined) {
					wakes.arrived[String(fresh)] = [...(wakes.arrived[String(fresh)] ?? []), ...arrived];
					delete wakes.arrived[String(before)];
				}
				// The hourly cap still holds; the person's Stop and the budget do not move.
				const hour = now - 3_600_000;
				const woken = (wakes.woken[String(before)] ?? []).filter((at) => at > hour);
				if (woken.length > 0) wakes.woken[String(fresh)] = [...woken, ...(wakes.woken[String(fresh)] ?? [])].sort((a, b) => a - b);
				if (wakes.held[String(before)]?.why === "cap") {
					wakes.held[String(fresh)] = wakes.held[String(before)]!;
					delete wakes.held[String(before)];
				}
			},
		},
		engine.context(),
	);
	const conversation = created.id as unknown as number;
	await reloadProjects();
	await reloadWakes();
	// What features do for a conversation the person starts with an agent; the conversation is made by now.
	for (const feature of host.features) {
		try {
			await feature.created?.(conversation, chosen);
		} catch (error) {
			engine.log("a fresh conversation was made for project", id, "but a feature could not set it up:", error instanceof Error ? error.message : error);
		}
	}
	// Wakes that had arrived and not been handed over are handed over by its first wake.
	wakeUp(conversation);
	engine.log(`project ${id} started fresh in conversation ${conversation}${before === null ? "" : `, after ${before}`}${agentId === undefined ? "" : `, with ${agent.name} as its orchestrator`}`);
	return conversation;
}

/** Start fresh for a project, once the feature has started; undefined before. */
let freshFor: ((id: string) => Promise<number>) | undefined;

/**
 * The project's current conversation with its orchestrator, made as the hub makes it when there is none yet (a project
 * whose orchestrator was never opened, or whose conversation was deleted): for chat mode's Continue with an Agent, which
 * writes to it as the person (#654, docs/chat.md). Making one where there is none moves nothing, so it is not the
 * person's Start fresh, which `projects.startFresh` is.
 */
export async function orchestratorConversation(id: string): Promise<number> {
	const project = allProjects()[id];
	if (project === undefined || project.deletedAt !== undefined) throw new Error(`Unknown project: ${id}`);
	if (project.archivedAt !== undefined) throw new Error(PROJECT_ARCHIVED);
	if (project.conversation !== null) return project.conversation;
	if (freshFor === undefined) throw new Error("The engine is still starting. Try again in a moment.");
	return freshFor(id);
}

// ---- The feature

export const orchestrator: Feature = (given, engine) => {
	host = given;
	freshFor = (id) => startFresh(given, engine, id, undefined);
	/** By project: the last line of its orchestrator's last finished answer (4.3). */
	const lastWords = new Map<string, { text: string; at: number }>();
	/** By conversation of a project: the last line its agent wrote, for Activity (4.3). */
	const lastLines = new Map<number, string>();
	let announceProjects = () => {};
	const workingNow = new Set<number>();

	/** An assistant message: its text, and whether it is a finished answer rather than one that calls tools. */
	const assistant = (message: unknown): { text: string; finished: boolean; at: number } | undefined => {
		const m = message as { role?: string; content?: unknown; stopReason?: string; timestamp?: number } | undefined;
		if (m?.role !== "assistant") return undefined;
		return { text: textOf(m.content), finished: m.stopReason === "stop" || m.stopReason === "length", at: typeof m.timestamp === "number" ? m.timestamp : Date.now() };
	};
	const noteLine = (conversation: number, text: string) => {
		const line = lastLineOf(text, 140);
		if (line === null || lastLines.get(conversation) === line) return;
		lastLines.set(conversation, line);
		if (workingNow.has(conversation)) engine.activityChanged();
	};
	const noteWords = (conversation: number, said: { text: string; at: number }) => {
		const project = Object.values(allProjects()).find((each) => each.conversation === conversation);
		const line = lastLineOf(said.text, 200);
		if (project === undefined || line === null) return;
		const before = lastWords.get(project.id);
		if (before !== undefined && before.at > said.at) return;
		lastWords.set(project.id, { text: line, at: said.at });
		announceProjects();
	};
	/** The last finished answer of each project's current conversation, read once as the engine starts. */
	const loadLastWords = async () => {
		for (const project of Object.values(allProjects())) {
			if (project.conversation === null || lastWords.has(project.id)) continue;
			const conv = await engine.harness().conversation(project.conversation as unknown as ConversationId, engine.context());
			if (conv === undefined) continue;
			let cursor: Parameters<typeof conv.entries>[2];
			for (let page = 0; page < 20; page++) {
				const found = await conv.entries({ order: "descending" }, 50, cursor, engine.context());
				const said = found.items.map((entry) => assistant(entry.model?.[0])).find((each) => each !== undefined && each.finished && lastLineOf(each.text, 200) !== null);
				if (said !== undefined) {
					noteWords(project.conversation, said);
					break;
				}
				cursor = found.next;
				if (cursor === undefined) break;
			}
		}
	};

	return {
		start: async () => {
			roles = rolesIn(await engine.harness().snapshot(Projects, engine.context()));
			wireFresh(async (tx, conversation) => {
				(await tx.doc(Fresh, conversation as unknown as ConversationId)).pending = true;
			});
			announceProjects = wireLastWords((projectId): ProjectRow["lastWords"] => {
				const words = lastWords.get(projectId);
				return words === undefined ? null : { ...words };
			});
			// Answers as they are committed, and the answer being written as it is stored, of conversations in projects.
			engine.harness().observeCommits({
				advance: ({ changes }) => {
					for (const change of changes) {
						if (change.type === "document" && change.kind === "change" && change.record.kind === "pi2.projects") {
							// Who is the orchestrator's conversation, now or earlier: the library and those conversations' states again.
							const next = rolesIn(change.value as unknown as ProjectsDoc);
							const moved = [...new Set([...roles.keys(), ...next.keys()])].filter((id) => roles.get(id) !== next.get(id));
							if (moved.length === 0) continue;
							roles = next;
							engine.libraryChanged();
							for (const id of moved) engine.stateChanged(id);
						} else if (change.type === "entry") {
							const conversation = change.value.conversationId as unknown as number;
							if (host?.conversations()[String(conversation)]?.projectId === undefined) continue;
							const said = assistant(change.value.model?.[0]);
							if (said === undefined) continue;
							noteLine(conversation, said.text);
							if (said.finished) noteWords(conversation, said);
						} else if (change.type === "document" && change.kind === "change" && change.record.kind === "pi.live" && change.conversationId !== undefined) {
							const conversation = change.conversationId as unknown as number;
							if (host?.conversations()[String(conversation)]?.projectId === undefined) continue;
							const partial = (change.value as { generation?: { message?: unknown } }).generation?.message;
							const said = assistant(partial);
							if (said !== undefined) noteLine(conversation, said.text);
						}
					}
				},
				end: () => {},
			});
			// Once every feature has started, the projects among them.
			void given.ready.then(loadLastWords).catch((error) => engine.log("could not read the orchestrators' last words:", error instanceof Error ? error.message : error));
		},
		runsChanged: (working) => {
			const now = Date.now();
			for (const id of working) if (!since.has(id)) since.set(id, now);
			for (const id of [...since.keys()]) if (!working.has(id)) since.delete(id);
			workingNow.clear();
			for (const id of working) workingNow.add(id);
		},
		// The conversation state's `project` (4.3), only for a conversation of a project: any other's state is as before. A
		// deleted project's conversations are in none (3.6, #458).
		state: (view, meta) => {
			if (meta?.projectId === undefined || projectDeleted(meta.projectId)) return {};
			return { project: { id: meta.projectId, orchestrator: orchestratorRole(view.conversation.id as unknown as number) } };
		},
		// Activity's `lastLine` (4.3), only for a conversation of a project.
		activity: (id) => {
			const projectId = host?.conversations()[String(id)]?.projectId;
			return projectId === undefined || projectDeleted(projectId) ? {} : { lastLine: lastLines.get(id) ?? null };
		},
		handlers: {
			/** `{ id }`: a fresh conversation with the orchestrator, beginning with the state block (6.5). */
			"projects.startFresh": async (params) => {
				if (typeof params.id !== "string") throw new Error("id must be a project's id");
				return { conversation: await startFresh(given, engine, params.id, undefined) };
			},
			/** `{ id, agentId }`: another agent of the project as its orchestrator, with a fresh conversation, in one commit (6.5). */
			"projects.setOrchestrator": async (params) => {
				if (typeof params.id !== "string") throw new Error("id must be a project's id");
				if (typeof params.agentId !== "string") throw new Error("agentId must be an agent's id");
				return { conversation: await startFresh(given, engine, params.id, params.agentId) };
			},
		},
	};
};
