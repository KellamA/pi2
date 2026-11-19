// Project notes in pi2.memory (#461). knowledge.ts keeps the legacy notebooks and the memory feature's one event.

import type { Context } from "@earendil-works/chord/context";
import { defineDoc, type ToolExecutionApi, type Tx } from "@earendil-works/pi-durable";
import { record } from "./changes.ts";
import type { MemoryDoc } from "./knowledge.ts";
import { PROJECT_ARCHIVED, Projects } from "./projects.ts";
import { Agents } from "./state.ts";

export type ProjectNote = {
	id: string;
	text: string;
	createdAt: number;
	conversation: number | null;
	agentId: string | null;
	audience: string | null;
	carriedFrom?: { agentId: string; agentName: string; id: string };
};
export type ProjectNotebook = { notes: ProjectNote[]; next: number };
export type NoteOp = { kind: "note.add"; note: ProjectNote } | { kind: "note.remove"; note: ProjectNote };

type NoteChange = {
	by: { kind: "agent"; agentId: string; conversationId: number; callId: string };
	op: NoteOp;
	inverse: NoteOp;
	summary: string;
};

/** Record a note added or removed through a tool in the record of changes (changes.ts), in the note's commit: its id. */
export async function recordNoteChange(tx: Tx, projectId: string, change: NoteChange): Promise<number | undefined> {
	return (await record(tx, projectId, change)).id;
}

/**
 * Put a removed note back with its id, in the caller's commit: the Undo of a removal (`note.add` with the note it
 * removed). Refused when a note has that id. The limit on notes is not checked: the note was there before.
 */
export function putBackProjectNote(doc: MemoryDoc, projectId: string, note: ProjectNote): void {
	const book = projectNotebook(doc, projectId);
	if (book.notes.some((one) => one.id === note.id)) throw new Error(`There is already a note ${note.id}`);
	// Where it was, by when it was made.
	const at = book.notes.findIndex((one) => one.createdAt > note.createdAt);
	book.notes.splice(at === -1 ? book.notes.length : at, 0, JSON.parse(JSON.stringify(note)) as ProjectNote);
	const number = Number(note.id.slice(1));
	if (Number.isInteger(number) && number >= book.next) book.next = number + 1;
}

export async function checkNoteProject(tx: Tx, id: string): Promise<void> {
	const { projects } = await tx.doc(Projects);
	if (!Object.hasOwn(projects, id) || projects[id]!.deletedAt !== undefined) throw new Error(`Unknown project: ${id}`);
	if (projects[id]!.archivedAt !== undefined) throw new Error(PROJECT_ARCHIVED);
}

export async function checkNoteAudience(tx: Tx, projectId: string, audience: unknown): Promise<string | null> {
	if (audience === null) return null;
	if (typeof audience !== "string") throw new Error("audience must be an agent's id or null");
	const { agents } = await tx.doc(Agents);
	const agent = Object.hasOwn(agents, audience) ? agents[audience] : undefined;
	if (agent?.projectId !== projectId || agent.removedAt !== undefined) throw new Error(`Unknown agent: ${audience}`);
	return audience;
}

/** A notebook is made only when its first note is added. #458 can use this for carried-over notes in its own commit. */
export function projectNotebook(doc: MemoryDoc, id: string): ProjectNotebook {
	doc.projects ??= {};
	doc.projects[id] ??= { notes: [], next: 1 };
	return doc.projects[id]!;
}

const givenTo = (note: ProjectNote, agentId: string) => note.audience === null || note.audience === agentId;
export function projectNotesFor(book: ProjectNotebook | undefined, agentId: string): ProjectNote[] {
	return book?.notes.filter((note) => givenTo(note, agentId)) ?? [];
}

export function addProjectNote(doc: MemoryDoc, projectId: string, input: Pick<ProjectNote, "text" | "conversation" | "agentId">, limit: number): ProjectNote | undefined {
	if ((doc.projects?.[projectId]?.notes.length ?? 0) >= limit) return undefined;
	const book = projectNotebook(doc, projectId);
	const note: ProjectNote = { id: `n${book.next++}`, ...input, createdAt: Date.now(), audience: null };
	book.notes.push(note);
	return note;
}

export function removeProjectNote(book: ProjectNotebook | undefined, id: unknown, agentId?: string): ProjectNote | undefined {
	if (book === undefined) return undefined;
	const note = book.notes.find((n) => n.id === id && (agentId === undefined || givenTo(n, agentId)));
	if (note === undefined) return undefined;
	const removed = JSON.parse(JSON.stringify(note)) as ProjectNote;
	book.notes = book.notes.filter((n) => n.id !== id);
	return removed;
}

type NoteToolResult = { saved: string; already?: true; change?: number } | { full: true } | { forgot: string; change?: number } | { missing: string[] };

// Keep the result with the write, not in the notebook: even if someone edits, removes or restores the note before
// a crash replays the tool, the same call does not touch it again. The task's document goes away with the task.
const NoteCall = defineDoc<{ results: Record<string, NoteToolResult> }>({
	kind: "pi2.projectNoteCall",
	version: 1,
	scope: "task",
	initial: () => ({ results: {} }),
	checkpointWhen: () => true,
});

export function priorProjectNoteCall(api: ToolExecutionApi, context: Context): Promise<NoteToolResult | undefined> {
	return api.snapshot(NoteCall, api.taskId, context).then((doc) => doc?.results[`call:${api.callId}`]);
}

export async function changeProjectNoteFromTool(
	tx: Tx,
	doc: MemoryDoc,
	projectId: string,
	agentId: string,
	api: ToolExecutionApi,
	what: { kind: "remember"; text: string } | { kind: "forget"; id: string },
	limit: number,
): Promise<NoteToolResult> {
	const { results } = await tx.doc(NoteCall, api.taskId);
	const key = `call:${api.callId}`;
	if (results[key] !== undefined) return results[key];
	await checkNoteProject(tx, projectId);
	await checkNoteAudience(tx, projectId, agentId);
	const conversationId = api.conversationId as unknown as number;
	const book = doc.projects?.[projectId];
	const record = (note: ProjectNote, kind: NoteOp["kind"]) =>
		recordNoteChange(tx, projectId, {
			by: { kind: "agent", agentId, conversationId, callId: api.callId },
			op: { kind, note },
			inverse: { kind: kind === "note.add" ? "note.remove" : "note.add", note },
			summary: `${kind === "note.add" ? "Remembered" : "Forgot"} project note ${note.id}`,
		});
	if (what.kind === "remember") {
		// A private copy is not a shared note, and must not stop an agent from adding one or give away its id.
		const same = book?.notes.find((note) => note.audience === null && note.text.toLowerCase() === what.text.toLowerCase());
		if (same !== undefined) return (results[key] = { saved: same.id, already: true });
		const note = addProjectNote(doc, projectId, { text: what.text, conversation: conversationId, agentId }, limit);
		if (note === undefined) return (results[key] = { full: true });
		const change = await record(note, "note.add");
		return (results[key] = { saved: note.id, ...(change === undefined ? {} : { change }) });
	}
	const note = removeProjectNote(book, what.id, agentId);
	if (note === undefined) return (results[key] = { missing: projectNotesFor(book, agentId).map((n) => n.id) });
	const change = await record(note, "note.remove");
	return (results[key] = { forgot: note.id, ...(change === undefined ? {} : { change }) });
}
