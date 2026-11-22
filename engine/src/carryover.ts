// Carrying over (#458): docs/projects.md, section 9. What a person has today is put into projects, with nothing lost,
// nothing deleted and nothing the old way reads changed: it only adds documents, adds fields the old way does not read
// (`projectId`, `projectAgentId`), and copies agents.
//
// This file is the run: the plan, worked out from the documents alone, with its report and fingerprint, is carryplan.ts's.
// A real run works the plan out again and goes ahead only if the fingerprint is the same. A run commits one project at a
// time, each commit finding what an earlier one did and recording what it did itself, so a run cut off part way is
// finished by the next, and a second run with nothing new has an empty plan and writes nothing at all.
//
// Copying the variables' values into the Keychain is a step after the commits, taken again at every engine start and
// with `projects.retrySecrets` until done (`carry.secrets`).
//
// Since #483 took the preview switch out, the run is the engine's own, at every start (`update`, #715): the first start
// of a version without the switch makes a copy of the data before anything changes, records it as
// `carry.removalBackup`, runs the plan with its own fingerprint, and writes `projects: { preview: true }` into
// settings.json for the versions before it; every later start finds nothing new and writes nothing.
//
// What is not done here, and why:
//
// - The watches' `wake` (9.1) is #463's field. A project carrying over makes has `wakeOnReports` on, which #463 reads as
//   waking for each report, so a sub-chat handed over without waiting wakes the orchestrator as it did.
// - The update's copy of the data is made once, at its first start, not before each conversation made later (9.9),
//   which only adds one conversation's fields to what the copy already holds.
// - No conversation is made with a project's default orchestrator: `conversation` stays null until the person first
//   opens or writes to the orchestrator, when the app makes it with `projects.startFresh` (orchestrator.ts), which marks
//   it to begin with the state block. A person with thirty folders gets no thirty empty conversations.
// - Copies are made here, inside each project's commit, not through `engine.saveAgent`, which commits on its own: a run
//   cut off part way must never leave a copy without its project. So the features' `agentDuplicated` hooks are not run;
//   what knowledge.ts's and variables.ts's do (the memory switch, the variables' names) is done here, in the same commit.

import { randomUUID } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { AgentDoc, type ConversationId, type Tx } from "@earendil-works/pi-durable";
import { createBackup, removePartialBackups } from "./backup.ts";
import { type CarryPlan, type CarrySnapshot, Grouping, lookUp, pending, planCarryOver, type PlannedProject, reportOf, scheduleCopies, unique } from "./carryplan.ts";
import type { Feature } from "./features.ts";
import { Memory } from "./knowledge.ts";
import { projectNotebook } from "./projectnotes.ts";
import {
	carryRecord,
	DEFAULT_ORCHESTRATOR,
	defaultProjectSettings,
	MAX_PROJECT_NAME,
	type Project,
	Projects,
	type ProjectsDoc,
	wireCarryOver,
} from "./projects.ts";
import { RequestError } from "./requesterror.ts";
import { Schedules } from "./schedules.ts";
import { type AgentProfile, Agents, Library, type Meta } from "./state.ts";
import { copyAgentValues } from "./variables.ts";
import { madeWorktrees } from "./worktrees.ts";

/** `projects.carryOver` without `dryRun: true`: the run is the engine's, at every start, since #483 (#715). */
export const CARRIES_ITSELF = "Carrying over runs by itself when the engine starts. Only a dry run is taken: give dryRun: true.";

// ---- Restoring one conversation of a deleted project (3.6, #531)

/** The refusal of a restore whose plan is not the one the person was shown (3.6). */
export const RESTORE_CHANGED = "What the restore would do has changed since you looked. Look at it again.";
/** A conversation that cannot be restored: it is in no project, or in one that was not deleted (3.6). */
export const NOT_OF_DELETED_PROJECT = "This conversation is not of a deleted project.";
/** The family moves as one (3.6): a sub-chat is restored through the conversation it belongs to. */
export const RESTORE_SUB_CHAT = "A sub-chat is restored with the conversation it belongs to. Restore that one.";
/** Nothing may be working or waiting in the family (3.6), though deleting the project guaranteed none was. */
export const STOP_RESTORE = "This conversation, or one of its sub-chats, is working or waiting on the person. Stop it first.";
export const RESTORE_FOLDER_MISSING = "The folder of this conversation or one of its sub-chats is missing. Put it back before restoring.";

// ---- The run (9.8)

/**
 * Tests hold a run at a point, to stop the engine there as a crash would: while the file the variable `name` names
 * exists, the run waits there, having written `<file>.started`. `PI2_CARRY_SECRETS_GATE` holds the Keychain step;
 * `PI2_CARRY_COMMIT_GATE` holds the run before each project's commit but the first; `PI2_RESTORE_COMMIT_GATE` holds
 * a restore after it has checked the plan but before its transaction.
 */
async function gate(name: "PI2_CARRY_SECRETS_GATE" | "PI2_CARRY_COMMIT_GATE" | "PI2_RESTORE_COMMIT_GATE"): Promise<void> {
	const file = process.env[name];
	if (file === undefined || !existsSync(file)) return;
	writeFileSync(`${file}.started`, "");
	while (existsSync(file)) await new Promise((resolve) => setTimeout(resolve, 50));
}

/**
 * Whether this is a release engine: one with a `BUILD` file next to `src`, as main.ts reads it (a development engine has
 * none). Test switches that would leave a person's data as the last version left it are not honoured in one.
 */
const releaseBuild = (() => {
	try {
		return readFileSync(join(dirname(fileURLToPath(import.meta.url)), "..", "BUILD"), "utf8").trim() !== "";
	} catch {
		return false;
	}
})();

/**
 * Tests make a data folder as the last version with the switch left it, the switch never turned on, with this engine:
 * with `PI2_CARRY_NEVER=1` nothing is carried, at start or as conversations are made, and the update records nothing
 * (test/carryover.ts, test/projectschedules.ts). Two tests that follow the agents of no project themselves run with it
 * too, test/engine.ts and test/worktrees.ts (#718); the others make their conversations with a project's agents.
 * Only in a development engine (as `PI2_TEST_COPY`, main.ts): a release engine ignores it, and says so at start.
 */
const carryNeverAsked = () => process.env.PI2_CARRY_NEVER === "1";
const carriesNothing = () => carryNeverAsked() && !releaseBuild;

/** An agent's id as made for a project: its name's slug and a UUID, never reused, whatever is deleted later. */
const agentIdFor = (name: string) => `${name.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "") || "agent"}-${randomUUID()}`;

/** What one project's commit is given beyond its plan: the ids made for it, and what the whole run records with it. */
type Made = {
	projectId: string;
	copies: Record<string, string>;
	/** The default orchestrator, made whole before the commit. */
	orchestrator: AgentProfile | undefined;
	now: number;
	/** A full run's: `ranAt`, the backup (none when there was nothing to copy), and the notes left; a conversation made later (9.9) records none of them. */
	run: { backup: string | null; left: string[] } | undefined;
};

/** Something the plan counted on is no longer so, part way through a run: it stops, and the next run finds what was done. */
export const CHANGED_DURING = "Something changed while carrying over ran, so it stopped part way. Look at it again, and run it again.";

/**
 * One project of the plan, in one commit (9.8, 4): the project, its copies, the conversations' fields, the notes, and the
 * record. Everything it finds done (by an earlier run, or by the person since) it leaves as it is.
 */
export async function applyProject(tx: Tx, entry: PlannedProject, made: Made, grouping: Grouping): Promise<void> {
	const doc = await tx.doc(Projects);
	const { agents } = await tx.doc(Agents);
	const { conversations } = await tx.doc(Library);
	const memory = await tx.doc(Memory);
	const { now } = made;
	let project: Project;
	if (entry.existing !== null) {
		const found = doc.projects[entry.existing];
		if (found === undefined || found.deletedAt !== undefined) throw new Error(CHANGED_DURING);
		project = found;
		if (entry.restore && project.archivedAt !== undefined) {
			delete project.archivedAt;
			project.updatedAt = now;
		}
	} else {
		// Made meanwhile, by another run or by the person: this plan no longer holds.
		const recorded = doc.carry.folders[entry.key];
		const recordedLive = recorded !== undefined && doc.projects[recorded] !== undefined && doc.projects[recorded].deletedAt === undefined;
		const sameFolder = entry.folder !== null && Object.values(doc.projects).some((other) => other.deletedAt === undefined && other.folder === entry.folder);
		if (recordedLive || sameFolder) throw new Error(CHANGED_DURING);
		const names = new Set(Object.values(doc.projects).filter((other) => other.deletedAt === undefined).map((other) => other.name.toLowerCase()));
		project = {
			id: made.projectId,
			name: unique(entry.name, names, MAX_PROJECT_NAME),
			folder: entry.folder,
			repository: null,
			orchestratorId: "",
			conversation: null,
			earlier: [],
			settings: defaultProjectSettings("carried"),
			createdAt: now,
			updatedAt: now,
			...(entry.archived ? { archivedAt: now } : {}),
			carriedAt: now,
		};
	}
	for (const key of entry.recordKeys) doc.carry.folders[key] = project.id;

	// The copies (9.5, 3.3): found ones as they are; made ones from the template, with what the plan said it takes.
	const copyOf: Record<string, string> = {};
	const madeNow: string[] = [];
	for (const planned of entry.copies) {
		const pair = `${project.id} ${planned.template}`;
		const recorded = doc.carry.copies[pair];
		if (planned.existing !== null || recorded !== undefined) {
			const id = planned.existing ?? recorded!;
			if (agents[id] === undefined) continue;
			if (doc.carry.copies[pair] === undefined) doc.carry.copies[pair] = id;
			copyOf[planned.template] = id;
			continue;
		}
		const template = agents[planned.template];
		// A restore may copy an agent of the deleted project it comes from (3.6, `entry.from`); anything else with a project is not a template.
		if (template === undefined || (template.projectId !== undefined && template.projectId !== entry.from)) throw new Error(CHANGED_DURING);
		// The report listed what the copy takes beyond a copy made by hand. A template that has gained one of those since
		// stops the run; one that has lost one gives the copy what is left of it.
		const valuesNow = (template.variables ?? []).filter((variable) => variable.set).map((variable) => variable.name);
		const memoryNow = memory.agents[template.id]?.enabled === true;
		const worktreeOff = template.worktree === true && (project.folder === null || !grouping.inRepository(project.folder));
		if ((template.allowEverything === true && !planned.allowEverything) || valuesNow.some((name) => !planned.variables.includes(name)) || (memoryNow && !planned.memory) || (worktreeOff && !planned.worktreeOff)) {
			throw new Error(CHANGED_DURING);
		}
		// Documents in a commit are not plain objects: copied through JSON, as every commit here copies them.
		const copy: AgentProfile = JSON.parse(JSON.stringify(template));
		delete copy.allowEverything;
		delete copy.madeBy;
		delete copy.removedAt;
		delete copy.role;
		copy.id = made.copies[planned.template]!;
		copy.name = planned.name;
		copy.cwd = project.folder;
		copy.projectId = project.id;
		copy.template = { id: template.id, copiedAt: now, templateUpdatedAt: template.updatedAt ?? template.createdAt };
		copy.createdAt = now;
		copy.updatedAt = now;
		copy.commandRules = copy.commandRules ?? [];
		// The names alone: a value is in the Keychain only once the step after this commit has copied it.
		if (template.variables !== undefined) copy.variables = template.variables.map((variable) => ({ name: variable.name, set: false }));
		if (planned.allowEverything && template.allowEverything === true) copy.allowEverything = true;
		// No worktree where the project's folder is no repository: there is nothing to make one from (agents.save's check).
		if (worktreeOff) copy.worktree = false;
		agents[copy.id] = copy;
		doc.carry.copies[pair] = copy.id;
		memory.agents[copy.id] = { enabled: planned.memory && memoryNow, notes: [], next: 1 };
		const names = planned.variables.filter((name) => valuesNow.includes(name));
		if (names.length > 0) doc.carry.secrets.push({ copyId: copy.id, templateId: template.id, names, tries: 0, lastError: null });
		copyOf[planned.template] = copy.id;
		madeNow.push(copy.id);
	}
	// Each copy made hands work to the project's copies of the templates its template named (3.3). Changed in the
	// document itself: what was put in it is not the object it was given.
	for (const id of madeNow) {
		const copy = agents[id]!;
		const named = agents[copy.template!.id]?.delegates ?? [];
		copy.delegates = named.map((other) => copyOf[other]).filter((other): other is string => other !== undefined && other !== id);
	}

	// The orchestrator of a project made (9.6). The default one has no conversation until the person opens it.
	if (entry.existing === null && entry.orchestrator !== null) {
		if (entry.orchestrator.template !== null) {
			const chosen = copyOf[entry.orchestrator.template];
			if (chosen === undefined) throw new Error(CHANGED_DURING);
			agents[chosen]!.role = "orchestrator";
			project.orchestratorId = chosen;
		} else {
			const orchestrator = made.orchestrator!;
			agents[orchestrator.id] = orchestrator;
			memory.agents[orchestrator.id] = { enabled: DEFAULT_ORCHESTRATOR.memory, notes: [], next: 1 };
			project.orchestratorId = orchestrator.id;
		}
	}
	doc.projects[project.id] = project;

	// The conversations: `projectId`, and the copy each runs as; nothing else of theirs changes (9.6).
	const moved = new Set<number>();
	for (const planned of entry.conversations) {
		const meta = conversations[String(planned.id)];
		if (meta === undefined || meta.deleted === true || meta.projectId !== undefined) continue;
		meta.projectId = project.id;
		const copy = planned.template === null ? undefined : copyOf[planned.template];
		if (copy !== undefined) meta.projectAgentId = copy;
		moved.add(planned.id);
	}
	// Sub-chats already in the project that ran as the template: the copy now, if it is still there (#715).
	for (const fix of entry.fixes) {
		const meta = conversations[String(fix.id)];
		if (meta === undefined || meta.deleted === true || meta.projectId !== project.id || meta.projectAgentId !== undefined || agents[fix.copy] === undefined) continue;
		meta.projectAgentId = fix.copy;
	}
	// The conversation chosen as the orchestrator's must be one this commit took: not deleted or taken since.
	if (entry.existing === null && entry.orchestrator?.conversation != null) {
		if (!moved.has(entry.orchestrator.conversation)) throw new Error(CHANGED_DURING);
		// In the document itself: what was put in it is not the object it was given.
		doc.projects[project.id]!.conversation = entry.orchestrator.conversation;
	}

	// The notes, each for its agent's copy alone, recorded for this project in this commit (9.7).
	for (const note of entry.notes) {
		const dealt = `${project.id} ${note.agent} ${note.note}`;
		if (doc.carry.notes[dealt] !== undefined) continue;
		const audience = note.copy ?? copyOf[note.agent];
		if (audience === undefined || agents[audience] === undefined || agents[audience].removedAt !== undefined) continue;
		const book = projectNotebook(memory, project.id);
		const same = book.notes.find((other) => other.audience === audience && other.text.toLowerCase() === note.text.toLowerCase());
		let id = same?.id;
		if (id === undefined) {
			id = `n${book.next++}`;
			book.notes.push({
				id,
				text: note.text,
				createdAt: note.createdAt,
				conversation: null,
				agentId: note.byAgent ? audience : null,
				audience,
				carriedFrom: { agentId: note.agent, agentName: note.agentName, id: note.note },
			});
		}
		doc.carry.notes[dealt] = { projectId: project.id, noteId: id };
	}

	if (made.run !== undefined) {
		for (const dealt of made.run.left) if (doc.carry.notes[dealt] === undefined) doc.carry.notes[dealt] = "left";
		if (doc.carry.backup === null) doc.carry.backup = made.run.backup;
		doc.carry.ranAt = now;
	}
}

// ---- The feature

/** Set as the feature is made: the project a new conversation in `cwd` would be carried into, for `admit` (8.3). */
let projectForFolder: ((cwd: string | null) => Promise<string | undefined>) | undefined;

/**
 * The project a conversation the person starts with `agent`, working in `cwd`, will be carried into as it is made (9.9),
 * so that its start is checked against that project's limits (8.3): for a template, the project of its folder, if one
 * exists. Undefined otherwise: an agent of a project is checked against its own, and a project made
 * for the folder has no limits.
 */
export async function carriedProjectFor(agent: AgentProfile, cwd: string | null): Promise<string | undefined> {
	if (agent.projectId !== undefined || projectForFolder === undefined) return undefined;
	return projectForFolder(cwd);
}

export const carryOver: Feature = (host, engine) => {
	/** One run at a time, a conversation made later (9.9) included, so two never work from the same documents. */
	let queue: Promise<unknown> = Promise.resolve();
	const serially = <T>(work: () => Promise<T>): Promise<T> => {
		const next = queue.then(work, work);
		queue = next.catch(() => {});
		return next;
	};
	let secretsQueue: Promise<unknown> = Promise.resolve();

	const storedProjects = async (): Promise<ProjectsDoc> => {
		const stored = await engine.harness().snapshot(Projects, engine.context());
		return JSON.parse(JSON.stringify(stored ?? { projects: {}, carry: { ranAt: null, backup: null, folders: {}, copies: {}, notes: {}, secrets: [] }, news: {}, nextNews: 1 }));
	};

	/** The documents, as stored now. Other uncarried conversations can determine where a note belongs (9.7). */
	const folderOf = async (id: number, tx?: Tx): Promise<string | null> => {
		const conversation = id as unknown as ConversationId;
		const agent = tx === undefined
			? await engine.harness().snapshot(AgentDoc, conversation, engine.context())
			: await tx.doc(AgentDoc, conversation);
		return agent?.cwd ?? null;
	};
	const snapshot = async (tx?: Tx): Promise<CarrySnapshot> => {
		const harness = engine.harness();
		const context = engine.context();
		const library = tx === undefined ? await harness.snapshot(Library, context) : await tx.doc(Library);
		const conversations = library?.conversations ?? {};
		const folders: Record<string, string | null> = {};
		for (const [id, meta] of Object.entries(conversations)) {
			if (meta.parent !== undefined || meta.chat === true || meta.version === true || meta.deleted === true || meta.projectId !== undefined) continue;
			folders[id] = await folderOf(Number(id), tx);
		}
		const agents = tx === undefined ? await harness.snapshot(Agents, context) : await tx.doc(Agents);
		const memory = tx === undefined ? await harness.snapshot(Memory, context) : await tx.doc(Memory);
		return {
			conversations,
			folders,
			agents: agents?.agents ?? {},
			memory: memory ?? { agents: {} },
			worktrees: await madeWorktrees(harness, context, tx),
			projects: tx === undefined ? await storedProjects() : await tx.doc(Projects),
		};
	};

	/** The plan as the documents give it now, with its report. */
	const look = async (only?: number) => {
		const documents = await snapshot();
		const plan = planCarryOver(documents, only);
		return { plan, documents, report: reportOf(plan, documents.projects.carry, documents.agents) };
	};

	/** What one project's commit is given beyond its plan: the ids made for it, and the default orchestrator. */
	const madeFor = (entry: PlannedProject, now: number): Made => {
		const projectId = entry.existing ?? `p-${randomUUID()}`;
		const copies = Object.fromEntries(entry.copies.filter((copy) => copy.existing === null).map((copy) => [copy.template, agentIdFor(copy.name)]));
		let orchestrator: AgentProfile | undefined;
		if (entry.existing === null && entry.orchestrator?.template === null) {
			const { memory: _, ...settings } = DEFAULT_ORCHESTRATOR;
			const taken = new Set(entry.copies.map((copy) => copy.name.toLowerCase()));
			const name = unique(settings.name, taken);
			orchestrator = { ...structuredClone(settings), name, id: agentIdFor(name), cwd: entry.folder, createdAt: now, projectId, role: "orchestrator", updatedAt: now };
		}
		return { projectId, copies, orchestrator, now, run: undefined };
	};

	/** Each project of `plan` in a commit of its own, in order. */
	const apply = async (plan: CarryPlan, documents: CarrySnapshot, run: Made["run"]) => {
		const grouping = new Grouping(documents.worktrees, documents.home);
		const last = plan.projects.length - 1;
		for (const [index, entry] of plan.projects.entries()) {
			if (index > 0) await gate("PI2_CARRY_COMMIT_GATE");
			const made = { ...madeFor(entry, Date.now()), run: run === undefined ? undefined : { backup: run.backup, left: index === last ? run.left : [] } };
			await engine.harness().commit(async (tx) => applyProject(tx, entry, made, grouping), engine.context());
		}
		// Nothing but notes left to record: one commit for them.
		if (plan.projects.length === 0 && run !== undefined && run.left.length > 0) {
			await engine.harness().commit(async (tx) => {
				const doc = await tx.doc(Projects);
				for (const dealt of run.left) if (doc.carry.notes[dealt] === undefined) doc.carry.notes[dealt] = "left";
				if (doc.carry.backup === null) doc.carry.backup = run.backup;
				doc.carry.ranAt = Date.now();
			}, engine.context());
		}
	};

	/**
	 * Copy the variables' values still pending into the Keychain (9.5): each copy done is taken off the list, one that fails
	 * keeps its error and is tried again at the next engine start or `projects.retrySecrets`.
	 */
	const retrySecrets = (): Promise<void> => {
		const next = secretsQueue.then(async () => {
			const stored = await engine.harness().snapshot(Projects, engine.context());
			const items = stored?.carry.secrets ?? [];
			if (items.length === 0) return;
			await gate("PI2_CARRY_SECRETS_GATE");
			const agents = (await engine.harness().snapshot(Agents, engine.context()))?.agents ?? {};
			const outcome = new Map<string, string | null>();
			for (const item of items) {
				if (agents[item.copyId] === undefined) {
					outcome.set(item.copyId, null);
					engine.log("carrying over: the copy", item.copyId, "was deleted before its variables' values were copied");
					continue;
				}
				if (agents[item.templateId] === undefined) {
					// Its values went with it (variables.ts, `deletingAgent`): there is nothing left to copy.
					outcome.set(item.copyId, null);
					engine.log("carrying over: the agent", item.templateId, "was deleted before its variables' values were copied to", item.copyId);
					continue;
				}
				try {
					await copyAgentValues(item.templateId, item.copyId, item.names);
					outcome.set(item.copyId, null);
				} catch (error) {
					outcome.set(item.copyId, error instanceof Error ? error.message : String(error));
				}
			}
			await engine.harness().commit(async (tx) => {
				const doc = await tx.doc(Projects);
				doc.carry.secrets = doc.carry.secrets.flatMap((item) => {
					if (!outcome.has(item.copyId)) return [item];
					const error = outcome.get(item.copyId)!;
					return error === null ? [] : [{ ...item, tries: item.tries + 1, lastError: error }];
				});
			}, engine.context());
		});
		secretsQueue = next.catch((error) => engine.log("carrying over could not copy variables' values:", error instanceof Error ? error.message : error));
		return next;
	};

	/**
	 * Give the schedules on templates their project's copy (3.13), in a commit of the schedules alone, found again inside
	 * it; nothing is written when there is nothing to carry. Called inside `serially`, after a run or a carry.
	 */
	const carrySchedules = async (): Promise<void> => {
		const harness = engine.harness();
		const context = engine.context();
		const grouping = new Grouping(await madeWorktrees(harness, context));
		const pending = scheduleCopies((await harness.snapshot(Schedules, context))?.schedules ?? {}, (await harness.snapshot(Agents, context))?.agents ?? {}, await storedProjects(), grouping);
		if (pending.length === 0) return;
		const carried = await harness.commit(async (tx) => {
			const { schedules } = await tx.doc(Schedules);
			const found = scheduleCopies(schedules, (await tx.doc(Agents)).agents, await tx.doc(Projects), grouping);
			for (const { schedule, copy } of found) schedules[schedule]!.projectAgentId = copy;
			return found;
		}, context);
		for (const { schedule, copy } of carried) engine.log("carried schedule", schedule, "to", copy);
	};

	/** Why the update's copy of the data, or its carrying over, failed at this start (#715): the event's `removalFailed`. */
	let removalFailed: string | null = null;
	/** Sends the `projects` event again, once `wireCarryOver` has given it: for `removalFailed`, which is no document's. */
	let announce = () => {};
	const failed = (reason: string) => {
		removalFailed = reason;
		engine.log("carrying over at the update:", reason);
		announce();
	};
	const message = (error: unknown) => (error instanceof Error ? error.message : String(error));
	/** An error's message inside a sentence of the person's: without its own full stop. */
	const reasonOf = (error: unknown) => message(error).replace(/[.\s]+$/, "");

	/**
	 * The update that took the switch out (#715), at every engine start, once every feature has started: the first time,
	 * a copy of the data before anything changes (recorded as `carry.removalBackup`, apart from `carry.backup`); then the
	 * plan, worked out and applied with its own fingerprint, as a run the person started did (9.8); then `projects:
	 * { preview: true }` in settings.json, so the last version with the switch shows projects if someone goes back to it.
	 * Nothing is shown first. With nothing new it writes nothing. If the copy cannot be made, nothing is carried and it is
	 * tried again at the next start; a run cut off part way is finished by the next. Answers whether the conversations in
	 * no project may be swept now (`strays`).
	 */
	const update = () =>
		serially(async (): Promise<boolean> => {
			if (carriesNothing()) return false;
			const harness = engine.harness();
			const context = engine.context();
			const folder = join(engine.home, "backups");
			// Copies an engine killed while making them left unfinished: never taken for a backup, so removed (#715).
			let unfinished = 0;
			try {
				unfinished = removePartialBackups(folder);
			} catch (error) {
				engine.log("carrying over at the update: could not remove an unfinished copy of the data:", message(error));
			}
			if (unfinished > 0) engine.log(`carrying over at the update: removed ${unfinished} unfinished cop${unfinished === 1 ? "y" : "ies"} of the data left by an engine that stopped while making ${unfinished === 1 ? "it" : "them"}`);
			const stored = await harness.snapshot(Projects, context);
			let removal = stored?.carry.removalBackup;
			if (removal === undefined) {
				// Nothing to copy on a data folder with no conversation and no project: a new installation.
				const library = (await harness.snapshot(Library, context))?.conversations ?? {};
				const notes = Object.values((await harness.snapshot(Memory, context))?.agents ?? {}).some((agent) => agent.notes.length > 0);
				const anything = stored !== undefined || Object.keys(library).length > 0 || notes;
				let path: string | null = null;
				if (anything) {
					try {
						mkdirSync(folder, { recursive: true });
						path = await createBackup(engine.home, folder);
					} catch (error) {
						failed(`The copy of your data could not be made, so nothing was moved into projects: ${reasonOf(error)}. pi² tries again when it next starts.`);
						return false;
					}
					engine.log("carrying over at the update: backed up to", path);
				}
				const at = Date.now();
				removal = await harness.commit(async (tx) => {
					const doc = await tx.doc(Projects);
					doc.carry.removalBackup ??= { path, at };
					return { ...doc.carry.removalBackup };
				}, context);
			}
			// The Keychain step for variables' values still pending, only once the copy exists: before it nothing is written.
			// Not waited for: the engine need not wait for the Keychain.
			void retrySecrets().catch(() => {});
			try {
				const { plan, report, documents } = await look();
				if (report.plan !== null) {
					// The run's backup, for 9.8's record, is this copy, unless an older run's is recorded.
					await apply(plan, documents, { backup: removal.path, left: plan.left });
					engine.log(`carried over at the update: ${plan.projects.length} project${plan.projects.length === 1 ? "" : "s"}, plan ${report.plan}`);
				}
			} catch (error) {
				failed(`Moving your conversations into projects stopped part way: ${reasonOf(error)}. pi² finishes it when it next starts.`);
				return false;
			}
			if ((engine.setting("projects") as { preview?: unknown } | undefined)?.preview !== true) {
				engine.saveSetting("projects", { preview: true });
				engine.log("carrying over at the update: settings.json says projects are on, for the versions before it");
			}
			await carrySchedules().catch((error) => engine.log("could not carry the schedules:", message(error)));
			await retrySecrets().catch(() => {});
			if (removalFailed !== null) {
				removalFailed = null;
				announce();
			}
			return true;
		});

	const checkIdle = (family: ReadonlySet<number>) => {
		if ([...family].some((member) => host.working(member)) || host.inbox.list().some((item) => family.has(item.conversationId))) {
			throw new Error(STOP_RESTORE);
		}
	};

	/** The family and its plan (3.6); in the move's transaction these are read from the documents it will write. */
	const lookRestore = async (id: number, tx?: Tx) => {
		const documents = await snapshot(tx);
		const root = documents.conversations[String(id)];
		if (root === undefined || root.deleted === true) throw new Error(`Unknown conversation: ${id}`);
		if (root.parent !== undefined) throw new Error(RESTORE_SUB_CHAT);
		const from = root.projectId;
		if (root.chat === true || root.version === true || from === undefined || documents.projects.projects[from]?.deletedAt === undefined) {
			throw new Error(NOT_OF_DELETED_PROJECT);
		}
		const children = new Map<number, number[]>();
		for (const [key, meta] of Object.entries(documents.conversations)) {
			if (meta.version === true || meta.parent === undefined) continue;
			if (!children.has(meta.parent)) children.set(meta.parent, []);
			children.get(meta.parent)!.push(Number(key));
		}
		const family = new Set<number>([id]);
		for (const member of family) for (const child of children.get(member) ?? []) family.add(child);
		checkIdle(family);
		const scheduleDoc = tx === undefined ? await engine.harness().snapshot(Schedules, engine.context()) : await tx.doc(Schedules);
		if (Object.values(scheduleDoc?.schedules ?? {}).some((schedule) => schedule.pending !== null && family.has(schedule.pending.conversationId))) {
			throw new Error(STOP_RESTORE);
		}
		// A restore is a carry of this family (9.9), stripped of the old project and the root's archived state.
		const conversations: Record<string, Meta> = JSON.parse(JSON.stringify(documents.conversations));
		const folders = { ...documents.folders };
		for (const member of family) {
			const meta = conversations[String(member)]!;
			if (meta.deleted === true || meta.chat === true) continue;
			const cwd = await folderOf(member, tx);
			if (cwd !== null) {
				let directory = false;
				try { directory = statSync(cwd).isDirectory(); } catch { /* Gone or no longer reachable. */ }
				if (!directory) throw new Error(RESTORE_FOLDER_MISSING);
			}
			if (member === id) folders[String(id)] = cwd;
			delete meta.projectId;
			delete meta.projectAgentId;
		}
		delete conversations[String(id)]!.archivedAt;
		const plan = planCarryOver({ ...documents, conversations, folders }, id, { from });
		const entry = plan.projects[0]!;
		const rootTemplate = entry.conversations.find((one) => one.id === id)!.template;
		const rootCopy = entry.copies.find((copy) => copy.template === rootTemplate);
		const removed = rootCopy?.existing != null && documents.agents[rootCopy.existing]?.removedAt !== undefined;
		const rootAgent = removed ? null : rootTemplate;
		const original = root.agentId === undefined ? undefined : documents.agents[root.agentId];
		// A removed or deleted copy stays that way. Tell the person what this means for the root (3.4).
		if (rootAgent === null && original !== undefined) {
			const reason = removed ? "This project’s copy was removed and will not be used." : "No copy will be made for this conversation.";
			entry.notices.push(`${reason} It keeps ${original.name} as its agent.${original.projectId === from ? " That agent still belongs to the deleted project and is not available for new starts." : ""}`);
		} else if (rootAgent === null && root.agentId !== undefined) {
			entry.notices.push("Its original agent was deleted. This conversation keeps the setup it has.");
		}
		const report = { ...reportOf(plan, documents.projects.carry, documents.agents), rootAgent, restoresProject: entry.restore };
		return { report, documents, from, family, entry };
	};

	const restore = (id: number, dryRun: boolean, given: string | null) =>
		serially(async () => {
			const preview = await lookRestore(id);
			if (dryRun) return preview.report;
			if (given !== preview.report.plan) throw new RequestError(RESTORE_CHANGED, preview.report);
			let backup = preview.documents.projects.carry.backup;
			let newBackup: string | undefined;
			if (backup === null) {
				const folder = join(engine.home, "backups");
				mkdirSync(folder, { recursive: true });
				newBackup = backup = await createBackup(engine.home, folder);
				engine.log("restoring: backed up to", backup);
			}
			await gate("PI2_RESTORE_COMMIT_GATE");
			const { report, entry, from, projectId } = await engine.harness().commit(async (tx) => {
				// Other requests do not share the carry queue. Replan inside the write transaction, after the backup.
				const { report, documents, entry, from, family } = await lookRestore(id, tx);
				if (given !== report.plan) throw new RequestError(RESTORE_CHANGED, report);
				const library = await tx.doc(Library);
				for (const { id: member } of entry.conversations) {
					const meta = library.conversations[String(member)]!;
					delete meta.projectId;
					delete meta.projectAgentId;
					if (member === id) delete meta.archivedAt;
				}
				const made = madeFor(entry, Date.now());
				await applyProject(tx, entry, made, new Grouping(documents.worktrees, documents.home));
				const { projects, carry } = await tx.doc(Projects);
				const source = projects[from]!;
				if (source.conversation === id) source.conversation = null;
				if (source.earlier.includes(id)) source.earlier = source.earlier.filter((other) => other !== id);
				if (carry.backup === null) carry.backup = backup;
				checkIdle(family);
				return { report, entry, from, projectId: made.projectId };
			}, engine.context()).catch(async (error) => {
				// A refused first restore must not leave an unrecorded backup in the way of retrying it.
				if (newBackup !== undefined) {
					try {
						if ((await storedProjects()).carry.backup !== newBackup) rmSync(newBackup, { force: true, recursive: true });
					} catch (cleanup) {
						engine.log("restoring: could not clean up the unused backup", cleanup);
					}
				}
				throw error;
			});
			engine.log(`restored conversation ${id} of the deleted project ${from} into ${projectId}`);
			if (entry.copies.some((copy) => copy.existing === null && copy.variables.length > 0)) await retrySecrets().catch(() => {});
			const stored = (await engine.harness().snapshot(Projects, engine.context()))?.carry ?? carryRecord();
			const agents = (await engine.harness().snapshot(Agents, engine.context()))?.agents ?? {};
			return { ...report, projectId, backup: stored.backup, secretsPending: pending(stored, agents) };
		});

	/** Whether the update's copy of the data is recorded (#715): until it is, nothing is carried. */
	const updated = async () => !carriesNothing() && (await storedProjects()).carry.removalBackup !== undefined;

	/** A top-level conversation not yet in a project: into the project of its folder (9.9). */
	const carryOne = (id: number) =>
		serially(async () => {
			if (!(await updated())) return;
			const { plan, documents } = await look(id);
			if (plan.projects.length === 0) return;
			await apply(plan, documents, undefined);
			await carrySchedules().catch((error) => engine.log("could not carry the schedules:", message(error)));
			if (plan.projects.some((entry) => entry.copies.some((copy) => copy.existing === null && copy.variables.length > 0))) void retrySecrets().catch(() => {});
		});

	/**
	 * Every top-level conversation that is not a chat, not deleted and in no project, carried one by one: at engine start,
	 * after the update's run, and after a conversation made later could not be carried, so that one left behind (by a
	 * crash between the commit that made it and the one that carries it, or by a failure) is carried still. Not before
	 * the update's copy of the data is recorded. A conversation of a deleted project keeps its `projectId` (3.6).
	 */
	const strays = async (): Promise<void> => {
		if (!(await updated())) return;
		const conversations = (await engine.harness().snapshot(Library, engine.context()))?.conversations ?? {};
		const left = Object.entries(conversations)
			.filter(([, meta]) => meta.parent === undefined && meta.chat !== true && meta.version !== true && meta.deleted !== true && meta.projectId === undefined)
			.map(([id]) => Number(id))
			.sort((a, b) => a - b);
		for (const id of left) {
			await carryOne(id).catch((error) => engine.log("could not carry conversation", id, "into a project:", message(error)));
		}
		await serially(carrySchedules).catch((error) => engine.log("could not carry the schedules:", message(error)));
	};

	projectForFolder = async (cwd) => {
		const projects = await storedProjects();
		const grouping = new Grouping(await madeWorktrees(engine.harness(), engine.context()));
		const live = Object.values(projects.projects).filter((project) => project.deletedAt === undefined);
		const keys = new Map(live.map((project) => [project.id, project.folder === null ? "none" : grouping.key(project.folder)]));
		return lookUp(grouping.key(cwd), live, keys, projects.carry.folders)?.project.id;
	};

	announce = wireCarryOver({
		state: () => {
			const carry = carryRecord();
			const removalBackup = carry.removalBackup?.path == null ? null : { path: carry.removalBackup.path, at: carry.removalBackup.at };
			if (carry.ranAt === null && carry.backup === null && carry.secrets.length === 0 && removalBackup === null && removalFailed === null) return null;
			return { ranAt: carry.ranAt, backup: carry.backup, removalBackup, removalFailed, secretsPending: pending(carry, engine.agents()) };
		},
	});

	return {
		start: async () => {
			if (carryNeverAsked()) {
				engine.log(releaseBuild ? "PI2_CARRY_NEVER is set and ignored: a release engine always carries over" : "PI2_CARRY_NEVER is set: this development engine carries nothing into projects");
			}
			// Once every feature has started: the update's run (#715), then any conversation left in no project.
			void host.ready
				.then(update)
				.then((swept) => (swept ? strays() : undefined))
				.catch((error) => failed(`Moving your conversations into projects stopped: ${reasonOf(error)}. pi² tries again when it next starts.`));
		},
		// The plan for that one conversation leaves out a sub-chat, a chat and one in a project already.
		made: async (id) => {
			try {
				await carryOne(id);
			} catch (error) {
				engine.log("could not carry conversation", id, "into a project:", message(error));
				// Once more, with any other left behind; a failure there is logged, and the next engine start tries again.
				void strays();
			}
		},
		handlers: {
			/**
			 * `{ dryRun: true }`: the report of what a run would do now, changing nothing, for a script or a test. The run
			 * itself is the engine's, at every start (`update`).
			 */
			"projects.carryOver": async (params) => {
				if (params.dryRun !== true) throw new Error(CARRIES_ITSELF);
				return (await serially(() => look())).report;
			},
			/** `{}`: try again to copy the variables' values still pending, and answer what is still pending. */
			"projects.retrySecrets": async () => {
				await retrySecrets().catch(() => {});
				const carry = (await engine.harness().snapshot(Projects, engine.context()))?.carry;
				const agents = (await engine.harness().snapshot(Agents, engine.context()))?.agents ?? {};
				return { secrets: carry === undefined ? [] : pending(carry, agents) };
			},
			/**
			 * `{ id, dryRun?, plan? }` (3.6, #531): the restore of one conversation of a deleted project. With `dryRun`, the report of what the restore would do, changing nothing; without, `plan` must be
			 * the dry run's, and the move is one commit with a backup first, taken only from the app (answers.ts).
			 */
			"projects.restoreConversation": async (params) => {
				if (typeof params.id !== "number") throw new Error("id must be a conversation's id");
				if (params.dryRun !== undefined && typeof params.dryRun !== "boolean") throw new Error("dryRun must be true or false");
				if (params.plan !== undefined && params.plan !== null && typeof params.plan !== "string") throw new Error("plan must be the plan of the report you were shown");
				return restore(params.id, params.dryRun === true, (params.plan as string | null | undefined) ?? null);
			},
		},
	};
};
