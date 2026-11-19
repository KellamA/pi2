// Carrying over's plan (#458, docs/projects.md 9.2 to 9.7), worked out from documents built here to the shape of a real
// library, without an engine: hundreds of conversations across repositories, their subfolders, linked worktrees,
// pi²'s worktrees and a submodule; sub-chats several deep; archived and deleted ones; chats and their versions;
// conversations with no folder; an agent since deleted; two agents sharing a folder; notes and variables; and projects
// the person made by hand. The folders are real, made in a temporary folder with `.git` entries of each kind, since the
// grouping reads them (without running git). carryover.ts (the test) runs a plan through a real engine.

import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { type CarrySnapshot, fingerprint, groupingKey, planCarryOver, reportOf } from "../src/carryover.ts";
import type { MemoryDoc } from "../src/knowledge.ts";
import { defaultProjectSettings, type Project, type ProjectsDoc } from "../src/projects.ts";
import type { AgentProfile, Meta } from "../src/state.ts";

const work = realpathSync(mkdtempSync(join(tmpdir(), "pi2-carryplan-")));
process.on("exit", () => rmSync(work, { recursive: true, force: true }));

function step(name: string): void {
	console.log(`ok  ${name}`);
}

// ---- Folders of every kind (9.2)

const repo = join(work, "repo");
const engineDir = join(repo, "engine", "src");
const linked = join(work, "linked-checkout");
const submodule = join(repo, "vendor", "lib");
const other = join(work, "other");
const plain = join(work, "plain", "notes");
const pi2Worktree = join(work, "data", "worktrees", "repo-7", "fix-login");
const gone = join(repo, "removed-since");
const goneElsewhere = join(work, "never-made", "x");
for (const folder of [join(repo, ".git", "worktrees", "linked"), join(repo, ".git", "modules", "lib"), engineDir, linked, submodule, join(other, ".git"), plain, pi2Worktree]) {
	mkdirSync(folder, { recursive: true });
}
writeFileSync(join(linked, ".git"), `gitdir: ${join(repo, ".git", "worktrees", "linked")}\n`);
writeFileSync(join(submodule, ".git"), "gitdir: ../../.git/modules/lib\n");
// pi²'s worktree's own .git file points somewhere odd: its record, not the file, decides (9.2, 3).
writeFileSync(join(pi2Worktree, ".git"), "gitdir: /nowhere/at/all\n");
const worktrees = [{ path: pi2Worktree, repo }];

assert.equal(groupingKey(null, worktrees), "none");
assert.equal(groupingKey(repo, worktrees), repo);
assert.equal(groupingKey(engineDir, worktrees), repo, "a subfolder is its repository");
assert.equal(groupingKey(linked, worktrees), repo, "a linked worktree is its main checkout");
assert.equal(groupingKey(submodule, worktrees), submodule, "a submodule is a project of its own");
assert.equal(groupingKey(pi2Worktree, worktrees), repo, "a worktree pi² made is the checkout it was made from");
assert.equal(groupingKey(join(pi2Worktree, "deep"), worktrees), repo);
assert.equal(groupingKey(other, worktrees), other);
assert.equal(groupingKey(plain, worktrees), plain, "no repository: the folder itself");
assert.equal(groupingKey(gone, worktrees), repo, "a folder that has gone, in a repository that has not");
assert.equal(groupingKey(goneElsewhere, worktrees), goneElsewhere, "a folder that has gone, by its path as stored");
step("grouping keys: a repository, its subfolders, linked worktrees and pi²'s worktrees are one; a submodule is its own");

// ---- Agents: a starter set, one sharing a folder, one deleted since (only its conversations and notes remain)

const agent = (id: string, extra: Partial<AgentProfile> = {}): AgentProfile => ({
	id,
	name: id[0]!.toUpperCase() + id.slice(1),
	description: "",
	color: "violet",
	model: null,
	thinkingLevel: null,
	instructions: `You are ${id}.`,
	access: "ask",
	cwd: null,
	delegates: [],
	maxTurns: null,
	createdAt: 1000 + id.length,
	...extra,
});
const agents: Record<string, AgentProfile> = {
	atlas: agent("atlas", { delegates: ["scout", "forge"], createdAt: 1 }),
	forge: agent("forge", { cwd: repo, createdAt: 2, variables: [{ name: "GH_TOKEN", set: true }, { name: "EMPTY", set: false }] }),
	scout: agent("scout", { access: "read", createdAt: 3 }),
	builder: agent("builder", { cwd: repo, createdAt: 4, allowEverything: true }),
	lonely: agent("lonely", { createdAt: 5 }),
};

// ---- Hundreds of conversations, from a seeded generator, so the library is the same every run

let seed = 458;
const random = () => {
	seed = (seed * 1103515245 + 12345) % 2 ** 31;
	return seed / 2 ** 31;
};
const pick = <T>(list: readonly T[]): T => list[Math.floor(random() * list.length)]!;
const conversations: Record<string, Meta> = {};
const folders: Record<string, string | null> = {};
let next = 1;
const make = (fields: Partial<Meta>, folder: string | null = null): number => {
	const id = next++;
	conversations[String(id)] = { title: `Conversation ${id}`, createdAt: id * 10, updatedAt: id * 10, access: "ask", ...fields };
	if (fields.parent === undefined) folders[String(id)] = folder;
	return id;
};
const places = [repo, engineDir, linked, pi2Worktree, submodule, other, plain, null, gone];
const who = ["atlas", "forge", "scout", "builder", "ghost"];
const tops: number[] = [];
for (let n = 0; n < 360; n++) {
	const roll = random();
	const id = make(
		{
			agentId: pick(who),
			...(roll < 0.12 ? { archivedAt: 5 } : {}),
			...(roll >= 0.12 && roll < 0.2 ? { deleted: true as const } : {}),
		},
		pick(places),
	);
	tops.push(id);
}
// Sub-chats several deep, of conversations kept, archived and deleted, each in its own folder somewhere else.
const subChats: number[] = [];
for (let n = 0; n < 140; n++) {
	const parent = random() < 0.6 ? pick(tops) : pick(subChats.length > 0 ? subChats : tops);
	const id = make({ agentId: pick(["scout", "forge", "builder"]), parent, ...(random() < 0.1 ? { deleted: true as const } : {}) });
	subChats.push(id);
}
// The most recently used conversation that hands out work, in the repository: the orchestrator's (9.6).
const latest = make({ agentId: "atlas", title: "Plan the release" }, engineDir);
conversations[String(latest)]!.updatedAt = 1e9;
make({ agentId: "scout", parent: latest });
// Same time, lower id wins: in the other repository, two conversations with sub-chats and one time.
const otherA = make({ agentId: "forge", title: "First" }, other);
const otherB = make({ agentId: "atlas", title: "Second" }, other);
for (const id of [otherA, otherB]) {
	conversations[String(id)]!.updatedAt = 5e8;
	make({ agentId: "scout", parent: id });
}
// Chats and a chat's version, which carrying over leaves out.
const chat = make({ chat: true });
make({ chat: true, version: true, parent: chat });
make({ chat: true, deleted: true });
// A folder whose conversations are all archived: its project is made archived, with the default orchestrator.
const archivedPlace = join(work, "archived-only");
mkdirSync(archivedPlace);
const archivedOnly = [make({ agentId: "scout", archivedAt: 9 }, archivedPlace), make({ agentId: "scout", archivedAt: 9 }, archivedPlace)];
make({ agentId: "forge", parent: archivedOnly[0] });

// ---- Notes, and projects the person made by hand

const memory: MemoryDoc = {
	agents: {
		atlas: {
			enabled: true,
			next: 4,
			notes: [
				{ id: "m1", text: "The release branch is cut on Fridays.", createdAt: 11, conversation: latest },
				{ id: "m2", text: "The person prefers short answers.", createdAt: 12, conversation: null },
				{ id: "m3", text: "Written somewhere since deleted.", createdAt: 13, conversation: tops.find((id) => conversations[String(id)]!.deleted === true)! },
			],
		},
		ghost: { enabled: true, next: 2, notes: [{ id: "m1", text: "A note of an agent deleted since.", createdAt: 14, conversation: null }] },
		lonely: { enabled: true, next: 2, notes: [{ id: "m1", text: "No conversation of mine anywhere.", createdAt: 15, conversation: null }] },
		scout: { enabled: false, next: 1, notes: [] },
	},
	chat: { next: 2, notes: [{ id: "c1", text: "A chat's note stays with chats.", createdAt: 16, conversation: null }] },
};
const project = (id: string, folder: string | null, extra: Partial<Project> = {}): Project => ({
	id,
	name: id,
	folder,
	repository: null,
	orchestratorId: `${id}-orchestrator`,
	conversation: null,
	earlier: [],
	settings: defaultProjectSettings("new"),
	createdAt: 1,
	updatedAt: 1,
	...extra,
});
// The person made a project for the other repository by hand, and one for the plain folder they deleted since.
const doc: ProjectsDoc = {
	projects: {
		"p-other": project("p-other", other, { name: "Other work" }),
		"p-gone": project("p-gone", plain, { name: "notes", deletedAt: 3 }),
	},
	carry: { ranAt: null, backup: null, folders: {}, copies: {}, notes: {}, secrets: [] },
	news: {},
	nextNews: 1,
};
agents["p-other-orchestrator"] = agent("p-other-orchestrator", { name: "Orchestrator", projectId: "p-other", role: "orchestrator", cwd: other });
// A copy of Forge the person made in that project by hand: adopted, not made again (9.5, 2).
agents["forge-by-hand"] = agent("forge-by-hand", { name: "Forge", projectId: "p-other", cwd: other, template: { id: "forge", copiedAt: 1, templateUpdatedAt: 2 }, createdAt: 50 });

const snapshot: CarrySnapshot = { conversations, folders, agents, memory, worktrees, projects: doc };
const started = performance.now();
const plan = planCarryOver(structuredClone(snapshot));
const took = performance.now() - started;
const report = reportOf(plan, doc.carry, agents);
console.log(`    planned ${Object.keys(conversations).length} conversations in ${took.toFixed(0)} ms`);

// ---- What the report must say, worked out here the plain way

const meta = (id: number) => conversations[String(id)]!;
const rootOf = (id: number): number => (meta(id).parent === undefined ? id : rootOf(meta(id).parent!));
const keyOf = (id: number) => groupingKey(folders[String(rootOf(id))] ?? null, worktrees);
const carried = Object.keys(conversations)
	.map(Number)
	.filter((id) => meta(id).chat !== true && meta(id).deleted !== true && meta(rootOf(id)).deleted !== true);
const expected = new Map<string, { conversations: number; archived: number; subChats: number }>();
for (const id of carried) {
	const counts = expected.get(keyOf(id)) ?? { conversations: 0, archived: 0, subChats: 0 };
	if (meta(id).parent !== undefined) counts.subChats++;
	else if (meta(id).archivedAt !== undefined) counts.archived++;
	else counts.conversations++;
	expected.set(keyOf(id), counts);
}
assert.deepEqual(
	report.projects.map((entry) => entry.key),
	[...expected.keys()].sort(),
	"one project for each key, in the order of the keys",
);
for (const entry of report.projects) {
	const counts = expected.get(entry.key)!;
	assert.deepEqual({ conversations: entry.conversations, archived: entry.archivedConversations, subChats: entry.subChats }, counts, entry.key);
}
const deletedCount = Object.keys(conversations)
	.map(Number)
	.filter((id) => meta(id).chat !== true && meta(id).version !== true && (meta(id).deleted === true || meta(rootOf(id)).deleted === true)).length;
assert.deepEqual(report.leftOut, { chats: 1, deleted: deletedCount, notesLeft: 2 });
assert.equal(report.already, 0);
assert.ok(carried.length > 300, `${carried.length} conversations carried`);
step(`the report: one project per key, every conversation counted once, ${report.leftOut.deleted} deleted and the chats left out`);

const entryOf = (key: string) => report.projects.find((entry) => entry.key === key)!;
const repoEntry = entryOf(repo);
assert.equal(repoEntry.name, "repo");
assert.equal(repoEntry.existing, null);
assert.equal(repoEntry.archived, false);
assert.deepEqual(repoEntry.orchestrator, { conversation: latest, title: "Plan the release", template: "atlas" });
// Two agents sharing the folder each get a copy; Atlas's delegates are followed; the deleted agent has none.
assert.deepEqual(repoEntry.copies.map((copy) => copy.template).sort(), ["atlas", "builder", "forge", "scout"]);
const forgeCopy = repoEntry.copies.find((copy) => copy.template === "forge")!;
assert.deepEqual(forgeCopy.variables, ["GH_TOKEN"], "only the variables with values");
assert.equal(forgeCopy.allowEverything, false);
assert.equal(forgeCopy.folder, null, "Forge's own folder is this project's");
assert.equal(repoEntry.copies.find((copy) => copy.template === "builder")!.allowEverything, true);
step("a repository with its worktrees and subfolders is one project, with a copy of each agent and the orchestrator by 9.6");

// The other repository: the person's project, adopted by its folder; their copy of Forge adopted; the orchestrator stands.
const otherEntry = entryOf(other);
assert.equal(otherEntry.existing, "p-other");
assert.equal(otherEntry.adopted, true);
assert.equal(otherEntry.name, "Other work");
assert.equal(otherEntry.orchestrator, null, "an existing project's orchestrator stands");
assert.equal(otherEntry.copies.find((copy) => copy.template === "forge")!.existing, "forge-by-hand");
// The plain folder's project was deleted: a new one, named after the folder now that the name is free again.
assert.equal(entryOf(plain).existing, null);
assert.equal(entryOf(plain).name, "notes");
// No folder: one project.
assert.equal(entryOf("none").name, "No folder");
// A submodule's own project, whose copies' templates have folders in the repository: reported, since new sub-chats move.
assert.equal(entryOf(submodule).copies.find((copy) => copy.template === "forge")?.folder, repo);
// Archived only: made archived, with the default orchestrator and no conversation until it is restored.
const archivedEntry = entryOf(archivedPlace);
assert.equal(archivedEntry.archived, true);
assert.deepEqual(archivedEntry.orchestrator, { conversation: null, title: null, template: null });
step("adoption by folder, a deleted project's folder made anew, no folder, a submodule, and a project made archived");

// Ties: the same time, the lowest conversation id. The other repository's project exists, so try it in a library without.
const without = structuredClone(snapshot);
delete without.projects.projects["p-other"];
delete without.agents["p-other-orchestrator"];
delete without.agents["forge-by-hand"];
const tied = reportOf(planCarryOver(without), without.projects.carry, without.agents);
assert.equal(tied.projects.find((entry) => entry.key === other)!.orchestrator!.conversation, otherA);
step("the orchestrator's tie-break: most recently updated, then the lowest conversation id");

// Notes: m1, written in the repository, goes there only; m2, the person's, to every project with a copy of Atlas; m3,
// whose conversation was deleted, likewise; the deleted agent's and the agent with no copy anywhere's are left.
const notes = new Map(plan.projects.map((entry) => [entry.key, entry.notes]));
const withAtlas = plan.projects.filter((entry) => entry.copies.some((copy) => copy.template === "atlas")).map((entry) => entry.key);
assert.ok(withAtlas.length > 3);
for (const key of withAtlas) {
	const here = notes.get(key)!.map((note) => note.note);
	assert.deepEqual(here, key === repo ? ["m1", "m2", "m3"] : ["m2", "m3"], key);
}
assert.deepEqual(plan.left.sort(), ["ghost m1", "lonely m1"]);
// Each note is recorded once, by the last project it goes to.
const records = plan.projects.flatMap((entry) => entry.notes.filter((note) => note.record).map((note) => `${note.agent} ${note.note}`));
assert.deepEqual(records.sort(), ["atlas m1", "atlas m2", "atlas m3"]);
step("notes go to the projects with a copy of their agent, for the copy alone, each recorded once; the rest are left");

// ---- One plan: the same documents give the same plan, whatever order they were stored in

const shuffled = structuredClone(snapshot);
const reorder = <T>(record: Record<string, T>) => Object.fromEntries(Object.entries(record).sort(() => random() - 0.5));
shuffled.conversations = reorder(shuffled.conversations);
shuffled.agents = reorder(shuffled.agents);
shuffled.folders = reorder(shuffled.folders);
assert.equal(fingerprint(planCarryOver(shuffled)), report.plan);
assert.match(report.plan!, /^[0-9a-f]{32}$/);
// Anything that changes what would be done changes the fingerprint.
const changed = structuredClone(snapshot);
changed.conversations["9999"] = { title: "New since", createdAt: 1, updatedAt: 1, access: "ask", agentId: "forge" };
changed.folders["9999"] = repo;
assert.notEqual(fingerprint(planCarryOver(changed)), report.plan);
step("the same documents give the same fingerprint, in any order; a new conversation changes it");

// ---- After a run, by its record: nothing to do

const after = structuredClone(snapshot);
for (const [index, entry] of plan.projects.entries()) {
	const id = entry.existing ?? `p-new-${index}`;
	if (entry.existing === null) after.projects.projects[id] = project(id, entry.folder, { name: entry.name, carriedAt: 1 });
	after.projects.carry.folders[entry.key] = id;
	for (const copy of entry.copies) {
		const copyId = copy.existing ?? `${copy.template}-copy-${index}`;
		if (copy.existing === null) after.agents[copyId] = agent(copyId, { name: copy.name, projectId: id, template: { id: copy.template, copiedAt: 1, templateUpdatedAt: 1 } });
		after.projects.carry.copies[`${id} ${copy.template}`] = copyId;
	}
	for (const one of entry.conversations) after.conversations[String(one.id)]!.projectId = id;
	for (const note of entry.notes) if (note.record) after.projects.carry.notes[`${note.agent} ${note.note}`] = { projectId: id, noteId: "n1" };
}
for (const dealt of plan.left) after.projects.carry.notes[dealt] = "left";
const again = planCarryOver(after);
assert.equal(fingerprint(again), null, JSON.stringify(again.projects.slice(0, 2)));
assert.equal(reportOf(again, after.projects.carry, after.agents).already, tops.filter((id) => meta(id).deleted !== true).length + 5);
// A conversation made since, with the preview off, goes into its folder's project as a first run would put it, and a
// copy the person deleted since is not made again: its conversations run as their own agent.
const since = make({ agentId: "builder" }, linked);
after.conversations[String(since)] = conversations[String(since)]!;
after.folders[String(since)] = linked;
const repoId = after.projects.carry.folders[repo]!;
delete after.agents[after.projects.carry.copies[`${repoId} builder`]!];
const late = planCarryOver(after);
assert.equal(late.projects.length, 1);
assert.equal(late.projects[0]!.existing, repoId);
assert.equal(late.projects[0]!.adopted, false, "found by the record, not adopted");
assert.deepEqual(late.projects[0]!.copies, [], "the deleted copy is not made again");
assert.deepEqual(late.projects[0]!.conversations, [{ id: since, template: null, archived: false, subChat: false }]);
// One made later with the preview on (9.9): the plan for that conversation alone.
const alone = planCarryOver(after, since);
assert.equal(alone.projects.length, 1);
assert.deepEqual(alone.projects[0]!.conversations.map((one) => one.id), [since]);
step("a second run with nothing new has an empty plan; what is new since goes where a first run would put it");
