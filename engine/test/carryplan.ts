// Carrying over's plan (#458, docs/projects.md 9.2 to 9.7), worked out from documents built here to the shape of a real
// library, without an engine: hundreds of conversations across repositories, their subfolders, linked worktrees,
// pi²'s worktrees and a submodule; sub-chats several deep; archived and deleted ones; chats and their versions;
// conversations with no folder; an agent since deleted; two agents sharing a folder; notes and variables; and projects
// the person made by hand. The folders are real, made in a temporary folder with `.git` entries of each kind, since the
// grouping reads them (without running git). carryover.ts (the test) runs a plan through a real engine.

import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, dirname, join } from "node:path";
import { type CarrySnapshot, fingerprint, groupingKey, Grouping, planCarryOver, reportOf } from "../src/carryplan.ts";
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
// A folder that has gone, under a symbolic link to pi²'s worktree: found inside what the link leads to (9.2).
const dataLink = join(work, "data-link");
symlinkSync(join(work, "data"), dataLink);
assert.equal(groupingKey(join(dataLink, "worktrees", "repo-7", "fix-login", "gone-since"), worktrees), repo);
assert.equal(groupingKey(join(dataLink, "worktrees", "repo-7", "fix-login"), worktrees), repo);
// The case the disk has (macOS's own real path), so one repository stored with two casings is one key.
const otherCase = join(dirname(repo), basename(repo).toUpperCase());
if (process.platform === "darwin" && existsSync(otherCase)) assert.equal(groupingKey(join(otherCase, "engine"), worktrees), repo);
// The walk upwards stops at the home folder: a repository there (dotfiles) does not hold every folder under it.
const home = join(work, "home");
mkdirSync(join(home, ".git"), { recursive: true });
mkdirSync(join(home, "Documents", "letters"), { recursive: true });
assert.equal(groupingKey(join(home, "Documents", "letters"), worktrees, home), join(home, "Documents", "letters"));
assert.equal(groupingKey(home, worktrees, home), home, "the home folder itself is its own repository");
assert.equal(groupingKey(join(home, "Documents", "letters"), worktrees, work), home, "without the stop, the repository above");
// A worktree whose repository has gone, and a bare repository's worktree: keyed as before, with a line for the report.
const orphanWorktree = join(work, "orphan-worktree");
mkdirSync(orphanWorktree);
writeFileSync(join(orphanWorktree, ".git"), `gitdir: ${join(work, "vanished", ".git", "worktrees", "orphan")}\n`);
const bare = join(work, "bare.git");
mkdirSync(join(bare, "worktrees", "feature"), { recursive: true });
writeFileSync(join(bare, "HEAD"), "ref: refs/heads/main\n");
const bareWorktree = join(work, "bare-feature");
mkdirSync(bareWorktree);
writeFileSync(join(bareWorktree, ".git"), `gitdir: ${join(bare, "worktrees", "feature")}\n`);
const grouping = new Grouping([...worktrees, { path: join(work, "made-of-gone"), repo: join(work, "gone-repo") }]);
assert.deepEqual(grouping.keyed(orphanWorktree), { key: join(work, "vanished"), notice: `The repository ${join(work, "vanished")}, which ${orphanWorktree} is a worktree of, has gone: this project's folder is missing.` });
assert.match(grouping.keyed(bareWorktree).notice!, /is a worktree of the bare repository .*bare\.git: each of its worktrees is a project of its own\.$/);
assert.equal(grouping.keyed(bareWorktree).key, bareWorktree);
assert.match(grouping.keyed(join(work, "made-of-gone", "x")).notice!, /which pi² made a worktree of, has gone/);
assert.equal(grouping.keyed(repo).notice, undefined);
assert.equal(grouping.inRepository(engineDir), true);
assert.equal(grouping.inRepository(plain), false);
step("grouping keys: a repository, its subfolders, linked worktrees and pi²'s worktrees are one; a submodule is its own; the home folder stops the walk; a repository gone and a bare one are said");

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
assert.deepEqual(report.leftOut, { chats: 1, deleted: deletedCount, deletedProject: 0, notesLeft: 1 });
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
// whose conversation was deleted, likewise. The deleted agent's is left; the note of an agent with no copy anywhere waits
// for one, recorded nowhere.
const notes = new Map(plan.projects.map((entry) => [entry.key, entry.notes]));
const withAtlas = plan.projects.filter((entry) => entry.copies.some((copy) => copy.template === "atlas")).map((entry) => entry.key);
assert.ok(withAtlas.length > 3);
for (const key of withAtlas) {
	const here = notes.get(key)!.map((note) => note.note);
	assert.deepEqual(here, key === repo ? ["m1", "m2", "m3"] : ["m2", "m3"], key);
}
assert.deepEqual(plan.left, ["ghost m1"]);
assert.ok(!plan.projects.some((entry) => entry.notes.some((note) => note.agent === "lonely")));
step("notes go to each project with a copy of their agent, for the copy alone; a deleted agent's are left");

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
	const copyOf = new Map<string, string>();
	for (const copy of entry.copies) {
		const copyId = copy.existing ?? `${copy.template}-copy-${index}`;
		if (copy.existing === null) after.agents[copyId] = agent(copyId, { name: copy.name, projectId: id, template: { id: copy.template, copiedAt: 1, templateUpdatedAt: 1 } });
		after.projects.carry.copies[`${id} ${copy.template}`] = copyId;
		copyOf.set(copy.template, copyId);
	}
	for (const one of entry.conversations) {
		const meta = after.conversations[String(one.id)]!;
		meta.projectId = id;
		if (one.template !== null) meta.projectAgentId = copyOf.get(one.template)!;
	}
	// Each project's commit records the notes it took, for that project (9.7).
	for (const note of entry.notes) after.projects.carry.notes[`${id} ${note.agent} ${note.note}`] = { projectId: id, noteId: "n1" };
}
for (const dealt of plan.left) after.projects.carry.notes[dealt] = "left";
const again = planCarryOver(after);
assert.equal(fingerprint(again), null, JSON.stringify(again.projects.slice(0, 2)));
/** The documents after that run, with nothing left to do, for the checks below. */
const settled = structuredClone(after);
assert.equal(reportOf(again, after.projects.carry, after.agents).already, tops.filter((id) => meta(id).deleted !== true).length + 5);
// A conversation made since in no project goes into its folder's project as a first run would put it, and a
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
// One made later (9.9): the plan for that conversation alone.
const alone = planCarryOver(after, since);
assert.equal(alone.projects.length, 1);
assert.deepEqual(alone.projects[0]!.conversations.map((one) => one.id), [since]);
step("a second run with nothing new has an empty plan; what is new since goes where a first run would put it");

// ---- Lookup's tie-breaks, and two keys reaching one project (9.4)

{
	const docs = structuredClone(settled);
	const noneId = docs.projects.carry.folders.none!;
	// A project the person made by hand with no folder, more recently changed than the one carrying over made: never taken
	// for "no folder", which keeps going where the record sends it.
	docs.projects.projects["p-loose"] = project("p-loose", null, { name: "Loose ends", createdAt: 0, updatedAt: 9e9 });
	const loose = make({ agentId: "forge" }, null);
	docs.conversations[String(loose)] = conversations[String(loose)]!;
	docs.folders[String(loose)] = null;
	const one = planCarryOver(docs);
	assert.deepEqual(one.projects.map((entry) => [entry.existing, entry.adopted]), [[noneId, false]]);
	// Even with the record gone, a hand-made project with no folder is not adopted for "no folder"; the oldest carried one is.
	delete docs.projects.carry.folders.none;
	assert.deepEqual(planCarryOver(docs).projects.map((entry) => [entry.existing, entry.adopted, entry.recordKeys]), [[noneId, true, ["none"]]]);
	step("no folder: the project recorded is kept, and one the person made by hand is never adopted for it");
}
{
	const docs = structuredClone(settled);
	const repoId = docs.projects.carry.folders[repo]!;
	// Two projects whose folders key to the repository: the person's for a subfolder, newer, and one for the checkout itself.
	docs.projects.projects["p-sub"] = project("p-sub", engineDir, { name: "Engine", createdAt: 0, updatedAt: 9e9 });
	const fresh = make({ agentId: "scout" }, linked);
	docs.conversations[String(fresh)] = conversations[String(fresh)]!;
	docs.folders[String(fresh)] = linked;
	const ofRepo = () => planCarryOver(docs).projects.find((entry) => entry.key === repo)!.existing;
	assert.equal(ofRepo(), repoId, "the one recorded is kept");
	delete docs.projects.carry.folders[repo];
	// Unrecorded: the one whose folder is the key itself, though the other is older.
	assert.equal(ofRepo(), repoId);
	delete docs.projects.projects[repoId];
	assert.equal(ofRepo(), "p-sub", "else the oldest");
	step("among projects sharing a key: the one recorded, then the folder that is the key, then the oldest");
}
{
	// The repository's project moved to another folder: the record still sends the repository's conversations to it, and a
	// conversation in its new folder finds it by that folder. Both keys are recorded, so neither is adopted again.
	const docs = structuredClone(settled);
	const repoId = docs.projects.carry.folders[repo]!;
	// Its new folder sorts after the repository, so the entry is made first for the key the record found.
	const moved = join(work, "zz-moved");
	mkdirSync(moved);
	docs.projects.projects[repoId]!.folder = moved;
	const inRepo = make({ agentId: "scout" }, repo);
	const inMoved = make({ agentId: "scout" }, moved);
	for (const [id, folder] of [[inRepo, repo], [inMoved, moved]] as const) {
		docs.conversations[String(id)] = conversations[String(id)]!;
		docs.folders[String(id)] = folder;
	}
	const both = planCarryOver(docs);
	assert.equal(both.projects.length, 1);
	assert.deepEqual(both.projects[0]!.recordKeys, [moved]);
	assert.equal(both.projects[0]!.adopted, true);
	for (const key of both.projects[0]!.recordKeys) docs.projects.carry.folders[key] = repoId;
	for (const id of [inRepo, inMoved]) docs.conversations[String(id)]!.projectId = repoId;
	const later = make({ agentId: "scout" }, moved);
	docs.conversations[String(later)] = conversations[String(later)]!;
	docs.folders[String(later)] = moved;
	assert.equal(planCarryOver(docs).projects[0]!.adopted, false, "recorded, not adopted again");
	step("a project reached by two keys records each, and is not adopted again");
}

// ---- Sub-chats made with the switch off in a conversation carried over (#715): given the project's copy

{
	const docs = structuredClone(settled);
	const repoId = docs.projects.carry.folders[repo]!;
	const scoutCopy = docs.projects.carry.copies[`${repoId} scout`]!;
	const root = Object.entries(docs.conversations).find(([, one]) => one.projectId === repoId && one.parent === undefined && one.deleted !== true)![0];
	// As the versions with the switch made one with it off: its parent's `projectId`, its template, no `projectAgentId`.
	const offSub = make({ agentId: "scout", parent: Number(root), projectId: repoId });
	docs.conversations[String(offSub)] = conversations[String(offSub)]!;
	// One whose agent has no copy in the project, one deleted, one of the project's own agent, and one in a deleted project.
	const noCopy = make({ agentId: "lonely", parent: Number(root), projectId: repoId });
	const deletedSub = make({ agentId: "scout", parent: Number(root), projectId: repoId, deleted: true });
	const own = make({ agentId: scoutCopy, parent: Number(root), projectId: repoId });
	const noneId = docs.projects.carry.folders.none!;
	const noneRoot = Object.entries(docs.conversations).find(([, one]) => one.projectId === noneId && one.parent === undefined && one.deleted !== true)![0];
	const inDeleted = make({ agentId: "scout", parent: Number(noneRoot), projectId: noneId });
	for (const id of [noCopy, deletedSub, own, inDeleted]) docs.conversations[String(id)] = conversations[String(id)]!;
	const deletedProject = structuredClone(docs);
	deletedProject.projects.projects[noneId]!.deletedAt = 9;
	const fixed = planCarryOver(deletedProject);
	assert.deepEqual(fixed.projects.map((entry) => [entry.existing, entry.fixes]), [[repoId, [{ id: offSub, copy: scoutCopy }]]]);
	assert.deepEqual(fixed.projects[0]!.conversations, [], "nothing else to carry");
	assert.equal(reportOf(fixed, deletedProject.projects.carry, deletedProject.agents).projects[0]!.subChatsPutRight, 1);
	assert.notEqual(fingerprint(fixed), null);
	// In a project not deleted, each gets its own project's copy.
	const both = planCarryOver(docs);
	const noneScout = docs.projects.carry.copies[`${noneId} scout`];
	const fixesOf = Object.fromEntries(both.projects.map((entry) => [entry.existing, entry.fixes]));
	assert.deepEqual(fixesOf, { [repoId]: [{ id: offSub, copy: scoutCopy }], ...(noneScout === undefined ? {} : { [noneId]: [{ id: inDeleted, copy: noneScout }] }) });
	// Once put right, nothing is left to do; a copy the person deleted since gives none.
	deletedProject.conversations[String(offSub)]!.projectAgentId = scoutCopy;
	assert.equal(fingerprint(planCarryOver(deletedProject)), null);
	delete deletedProject.conversations[String(offSub)]!.projectAgentId;
	delete deletedProject.agents[scoutCopy];
	assert.equal(fingerprint(planCarryOver(deletedProject)), null, "the deleted copy stands: it runs as its template");
	step("a sub-chat made with the switch off in a carried conversation is given its project's copy, and only that");
}

// ---- Notes, recorded per project: a project that gets a copy later gets them then (9.7)

{
	const docs = structuredClone(settled);
	const fresh = join(work, "fresh");
	mkdirSync(fresh, { recursive: true });
	// Atlas used in a new folder after the first run: its new copy there gets the person's note and the one written in a
	// conversation since deleted, not the one written in the repository, which has its own copy.
	const atlasLater = make({ agentId: "atlas" }, fresh);
	docs.conversations[String(atlasLater)] = conversations[String(atlasLater)]!;
	docs.folders[String(atlasLater)] = fresh;
	// Lonely, with no copy anywhere until now, used in the plain folder: its note goes there.
	const lonelyLater = make({ agentId: "lonely" }, plain);
	docs.conversations[String(lonelyLater)] = conversations[String(lonelyLater)]!;
	docs.folders[String(lonelyLater)] = plain;
	const later = planCarryOver(docs);
	const at = (key: string) => later.projects.find((entry) => entry.key === key)!;
	assert.deepEqual(at(fresh).notes.map((note) => note.note), ["m2", "m3"]);
	assert.deepEqual(at(plain).notes.map((note) => `${note.agent} ${note.note}`), ["lonely m1"]);
	assert.deepEqual(later.left, []);
	// The person writes a note for Atlas, and a Builder conversation is made in the repository: the repository's project is
	// in the plan for Builder alone, and still gets the note for its copy of Atlas, as does every other project with one.
	docs.memory.agents.atlas!.notes.push({ id: "m4", text: "Ask before deleting branches.", createdAt: 20, conversation: null });
	const builderLater = make({ agentId: "builder" }, repo);
	docs.conversations[String(builderLater)] = conversations[String(builderLater)]!;
	docs.folders[String(builderLater)] = repo;
	const withNote = planCarryOver(docs);
	const atlasProjects = Object.entries(docs.projects.carry.copies).filter(([pair, copy]) => pair.endsWith(" atlas") && docs.agents[copy] !== undefined).map(([pair]) => pair.split(" ")[0]);
	const gotIt = withNote.projects.filter((entry) => entry.notes.some((note) => note.note === "m4")).map((entry) => entry.existing ?? entry.key);
	assert.deepEqual(gotIt.sort(), [...atlasProjects, fresh].sort());
	const repoEntry = withNote.projects.find((entry) => entry.key === repo)!;
	assert.deepEqual(repoEntry.copies.map((copy) => copy.template), ["builder"]);
	assert.deepEqual(repoEntry.notes.map((note) => note.note), ["m4"]);
	assert.equal(repoEntry.notes[0]!.copy, docs.projects.carry.copies[`${repoEntry.existing} atlas`]);
	// A note recorded for one project is not copied there again, while another project still gets it.
	const firstId = atlasProjects[0]!;
	docs.projects.carry.notes[`${firstId} atlas m4`] = { projectId: firstId, noteId: "n9" };
	assert.ok(!planCarryOver(docs).projects.some((entry) => entry.existing === firstId && entry.notes.some((note) => note.note === "m4")));
	step("a note goes to each project with a copy, recorded per project: a copy made later, a template's first copy, and a project in the plan for another agent all get it");
}

{
	const docs = structuredClone(settled);
	const repoId = docs.projects.carry.folders[repo]!;
	const atlasCopy = docs.projects.carry.copies[`${repoId} atlas`]!;
	const existing = make({ agentId: "atlas" }, other);
	const newFolder = join(work, "atlas-later");
	const fresh = make({ agentId: "atlas" }, newFolder);
	for (const [id, folder] of [[existing, other], [fresh, newFolder]] as const) {
		docs.conversations[String(id)] = conversations[String(id)]!;
		docs.folders[String(id)] = folder;
	}
	const notesAt = (plan: ReturnType<typeof planCarryOver>, folder: string) => plan.projects.find((entry) => entry.key === folder)!.notes.map((note) => note.note);
	const check = () => {
		const full = planCarryOver(docs);
		for (const [id, folder, expected] of [[existing, other, []], [fresh, newFolder, ["m2", "m3"]]] as const) {
			const one = notesAt(planCarryOver(docs, id), folder);
			assert.deepEqual(one, expected);
			assert.ok(one.every((note) => notesAt(full, folder).includes(note)), "a one-conversation plan sends no note the full plan would not");
		}
	};
	// The regression with only one conversation left, and a home copy recorded by a prior run.
	const freshMeta = docs.conversations[String(fresh)]!;
	delete docs.conversations[String(fresh)];
	assert.deepEqual(notesAt(planCarryOver(docs, existing), other), []);
	docs.conversations[String(fresh)] = freshMeta;
	check();
	docs.agents[atlasCopy]!.removedAt = 2;
	check();
	delete docs.agents[atlasCopy];
	check();
	// A note with an uncarried home: only the full plan sees the other conversation and the copy it would adopt.
	delete docs.projects.carry.copies[`${repoId} atlas`];
	delete docs.conversations[String(latest)]!.projectId;
	docs.folders[String(latest)] = repo;
	check();
	step("a later conversation cannot copy another project's notes, even into a new copy or from a removed copy or uncarried home");
}

// ---- Copies: a worktree where there is no repository, and one conversation with its sub-chats (9.5, 9.9)

{
	const docs = structuredClone(settled);
	docs.agents.builder!.worktree = true;
	docs.home = home;
	const fresh = join(home, "Documents", "letters");
	const homeGrouping = new Grouping(worktrees, home);
	assert.equal(homeGrouping.inRepository(fresh), false, "a plain folder under a dotfiles repository");
	assert.equal(homeGrouping.inRepository(home), true, "the home folder itself remains a repository");
	const inPlain = make({ agentId: "builder" }, fresh);
	const inRepoAgain = make({ agentId: "builder" }, repo);
	const child = make({ agentId: "scout", parent: inPlain });
	for (const id of [inPlain, inRepoAgain, child]) docs.conversations[String(id)] = conversations[String(id)]!;
	docs.folders[String(inPlain)] = fresh;
	docs.folders[String(inRepoAgain)] = repo;
	const plain2 = planCarryOver(docs);
	assert.equal(plain2.projects.find((entry) => entry.key === fresh)!.copies.find((copy) => copy.template === "builder")!.worktreeOff, true);
	assert.equal(reportOf(plain2, docs.projects.carry, docs.agents).projects.find((entry) => entry.key === fresh)!.copies.find((copy) => copy.template === "builder")!.worktreeOff, true);
	// Its copy in the repository exists already (deleted by the person there: nothing made); a new one would keep worktrees.
	const repoId = docs.projects.carry.folders[repo]!;
	delete docs.projects.carry.copies[`${repoId} builder`];
	for (const [id, agent] of Object.entries(docs.agents)) if (agent.projectId === repoId && agent.template?.id === "builder") delete docs.agents[id];
	assert.equal(planCarryOver(docs).projects.find((entry) => entry.key === repo)!.copies.find((copy) => copy.template === "builder")!.worktreeOff, false);
	// The plan for one conversation takes its sub-chats with it.
	assert.deepEqual(planCarryOver(docs, inPlain).projects[0]!.conversations.map((one) => [one.id, one.subChat]), [[inPlain, false], [child, true]]);
	// An archived conversation left in no project goes into its folder's archived project without restoring it.
	const archivedId = docs.projects.carry.folders[archivedPlace]!;
	const leftArchived = make({ agentId: "scout", archivedAt: 30 }, archivedPlace);
	const leftLive = make({ agentId: "scout" }, archivedPlace);
	for (const id of [leftArchived, leftLive]) {
		docs.conversations[String(id)] = conversations[String(id)]!;
		docs.folders[String(id)] = archivedPlace;
	}
	docs.projects.projects[archivedId]!.archivedAt = 9;
	assert.equal(planCarryOver(docs, leftArchived).projects[0]!.restore, false);
	assert.equal(planCarryOver(docs, leftLive).projects[0]!.restore, true);
	step("a copy that would make worktrees where there is no repository does not, and says so; one conversation takes its sub-chats; only a live one restores");
}

// ---- Copies are made in carrying over's own commits, without the features' agentDuplicated hooks (features.ts)

const sources = new URL("../src/", import.meta.url);
const hooked = readdirSync(sources)
	.filter((name) => name.endsWith(".ts") && /^\s*agentDuplicated:/m.test(readFileSync(new URL(name, sources), "utf8")))
	.sort();
assert.deepEqual(hooked, ["knowledge.ts", "variables.ts"], "a new agentDuplicated hook: carryover.ts's applyProject must do its part too");
step("only memory's and variables' agentDuplicated hooks exist, whose part carrying over does itself");
