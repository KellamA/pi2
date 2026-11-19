// What an agent knows before the first message: a project's own instructions file, and the agent's memory.
// See docs/knowledge.md.

import { closeSync, fstatSync, openSync, readSync, realpathSync, statSync } from "node:fs";
import { dirname, join, sep } from "node:path";
import { AgentDoc, type ConversationId, defineDoc, defineTool, LiveDoc, type LiveState, section, type Tx } from "@earendil-works/pi-durable";
import { obj, opt, str } from "@earendil-works/pi-schema";
import { isChat } from "./chat.ts";
import type { Feature } from "./features.ts";
import {
	addProjectNote,
	changeProjectNoteFromTool,
	checkNoteAudience,
	checkNoteProject,
	type ProjectNotebook,
	priorProjectNoteCall,
	projectNotesFor,
	removeProjectNote,
} from "./projectnotes.ts";
import { inProject, projectOf, projectsOn, requirePreview } from "./projects.ts";

// ---- Project instructions

/** The files looked for in each folder, in order of preference. */
export const INSTRUCTION_FILES = ["AGENTS.md", "CLAUDE.md"] as const;
/** The most characters of instructions given, all files together. */
export const MAX_INSTRUCTION_CHARS = 24_000;
/** Bytes read from a file: enough for the cap even when every character takes four. */
const MAX_INSTRUCTION_BYTES = MAX_INSTRUCTION_CHARS * 4 + 4;

/** One folder's instructions file. `folder` is a real path; `text` is cut to its share of the cap when `cut`. */
export type ProjectInstructions = { folder: string; file: string; text: string; cut: boolean };

/**
 * The folders whose instructions apply to `folder` (a real path), from the top of its git repository down to it.
 * The top is the nearest folder with a `.git` entry: a folder in a main checkout, a file in a worktree. Found without
 * starting git, because this runs for every model request. A folder in no repository applies alone.
 */
function instructionFolders(folder: string): string[] {
	const folders: string[] = [];
	for (let at = folder; ; at = dirname(at)) {
		folders.push(at);
		try {
			const entry = statSync(join(at, ".git"));
			if (entry.isDirectory() || entry.isFile()) return folders.reverse();
		} catch {
			// No .git here: keep going up.
		}
		if (dirname(at) === at) return [folder];
	}
}

/**
 * The first of the listed files that is a plain text file really inside `root` (a real path). A link that leads out of
 * the folder is not followed, and a missing, unreadable or non-text file counts as absent. Not yet cut to any share.
 */
function readInstructionsIn(root: string): { file: string; text: string } | undefined {
	for (const file of INSTRUCTION_FILES) {
		let fd: number | undefined;
		try {
			const real = realpathSync(join(root, file));
			if (!real.startsWith(root.endsWith(sep) ? root : root + sep)) continue;
			fd = openSync(real, "r");
			if (!fstatSync(fd).isFile()) continue;
			const buffer = Buffer.alloc(MAX_INSTRUCTION_BYTES);
			const count = readSync(fd, buffer, 0, buffer.length, 0);
			const bytes = buffer.subarray(0, count);
			if (bytes.subarray(0, 8000).includes(0)) continue;
			const text = bytes.toString("utf8").trim();
			if (text === "") continue;
			return { file, text };
		} catch {
			// Missing, unreadable: try the next file.
		} finally {
			if (fd !== undefined) closeSync(fd);
		}
	}
	return undefined;
}

/**
 * The project instructions for working in `folder`: in it and in each folder above it up to the top of its git
 * repository, one file per folder, the top's first. Together they are cut to `MAX_INSTRUCTION_CHARS`, shared so that a
 * file shorter than an equal share is given whole and the longer ones split what is left equally: no file is crowded
 * out by another, however long that one is.
 */
export function readProjectInstructions(folder: string): ProjectInstructions[] {
	let start: string;
	try {
		start = realpathSync(folder);
	} catch {
		return [];
	}
	const found = instructionFolders(start).flatMap((at) => {
		const one = readInstructionsIn(at);
		return one === undefined ? [] : [{ folder: at, ...one }];
	});
	const share = new Map<(typeof found)[number], number>();
	let left = MAX_INSTRUCTION_CHARS;
	[...found].sort((a, b) => a.text.length - b.text.length).forEach((one, index, shortestFirst) => {
		const given = Math.min(one.text.length, Math.floor(left / (shortestFirst.length - index)));
		share.set(one, given);
		left -= given;
	});
	return found.map((one) => {
		const given = share.get(one)!;
		const cut = one.text.length > given;
		return { folder: one.folder, file: one.file, text: cut ? one.text.slice(0, given) : one.text, cut };
	});
}

export function describeProjectInstructions(folder: string): string | undefined {
	const found = readProjectInstructions(folder);
	if (found.length === 0) return undefined;
	let own: string;
	try {
		own = realpathSync(folder);
	} catch {
		return undefined;
	}
	const where = (one: ProjectInstructions) => (one.folder === own ? "this folder" : `${one.folder}, a folder above this one in its git repository`);
	const body = (one: ProjectInstructions) => {
		const path = one.folder === own ? `${one.file} in this folder` : join(one.folder, one.file);
		const limit = MAX_INSTRUCTION_CHARS.toLocaleString("en-US");
		const note = !one.cut
			? ""
			: found.length === 1
				? `\n\n(This file is longer than ${limit} characters; the rest is not shown. Read ${path} for the rest.)`
				: `\n\n(This file is cut here, to keep the project's instructions to ${limit} characters in all; the rest is not shown. Read ${path} for the rest.)`;
		return `${one.text}${note}`;
	};
	if (found.length === 1) return `From ${found[0]!.file} in ${where(found[0]!)}. These are the project's instructions for working in this folder:\n\n${body(found[0]!)}`;
	return [
		`These are the project's instructions for working in this folder, from ${found.length} files: the outermost folder's first, the nearest folder's last. Where they differ, the nearer one has the last word.`,
		...found.map((one) => `From ${one.file} in ${where(one)}:\n\n${body(one)}`),
	].join("\n\n");
}

// ---- Memory

export const MAX_NOTE_CHARS = 400;
export const MAX_NOTES = 60;

export type Note = {
	id: string;
	text: string;
	createdAt: number;
	/** The conversation it was written in; null for a note the person wrote by hand. */
	conversation: number | null;
	/** The tool call that wrote it, so a call run again after a crash does not add it twice. */
	call?: string;
};
export type AgentMemory = { enabled: boolean; notes: Note[]; next: number };
/** Chat mode's own notes (#288): one set for every chat, apart from every agent's. Its switch is `chat.memory` in the settings. */
export type ChatMemory = { notes: Note[]; next: number };
export type MemoryDoc = { agents: Record<string, AgentMemory>; chat?: ChatMemory; projects?: Record<string, ProjectNotebook> };

/** Whose notes: chat mode's, or one agent's. */
type Owner = { chat: true } | { chat: false; agentId: string };
const CHAT: Owner = { chat: true };

/** The tools of a chat while chat mode's memory is on: its own notes, and a look at the agents' that changes nothing. */
export const CHAT_MEMORY_TOOLS = ["remember", "forget", "agent_notes"] as const;

/** The most characters `agent_notes` gives at once: one agent's notes when it has as many as it may. */
export const MAX_AGENT_NOTES_CHARS = MAX_NOTES * MAX_NOTE_CHARS;

/**
 * One session-scoped document: the agents' notes keyed by agent id, and chat mode's under `chat`. Notes of a deleted
 * agent stay behind, unseen and harmless.
 */
// #458 carries notes over in its own commit using this token. Until then nothing is copied from agents.
export const Memory = defineDoc<MemoryDoc>({
	kind: "pi2.memory",
	version: 1,
	scope: "session",
	initial: () => ({ agents: {} }),
	checkpointWhen: () => true,
});

const text = (value: string) => [{ type: "text" as const, text: value }];
/** One line, tidy: a note the agent writes is shown in a list and in the prompt. */
const tidy = (value: string) => value.replace(/\s+/g, " ").trim();
/** A note the person writes keeps the line breaks they typed with Shift-Return (#198): each line tidied, blank ones dropped. */
const tidyLines = (value: string) =>
	value
		.split(/\r\n|[\n\r\u2028\u2029]/)
		.map(tidy)
		.filter((line) => line !== "")
		.join("\n");

export const knowledge: Feature = (host, engine) => {
	let memory: Record<string, AgentMemory> = {};
	let chatMemory: ChatMemory = { notes: [], next: 1 };
	let projectMemory: Record<string, ProjectNotebook> = {};
	let revision = 0;

	const shown = (notes: Note[]) => notes.map((n) => ({ id: n.id, text: n.text, createdAt: n.createdAt, conversation: n.conversation }));
	const event = () => ({
		event: "memory",
		agents: Object.fromEntries(Object.entries(memory).map(([id, m]) => [id, { enabled: m.enabled, notes: shown(m.notes) }])),
		// Chat mode's own; whether it is on is `memory` in the `chat` event.
		chat: { notes: shown(chatMemory.notes) },
		projects: Object.fromEntries(Object.entries(projectMemory).map(([id, book]) => [id, { notes: book.notes }])),
	});

	const adopt = (doc: MemoryDoc | undefined) => {
		memory = doc?.agents ?? {};
		chatMemory = doc?.chat ?? { notes: [], next: 1 };
		projectMemory = doc?.projects ?? {};
		revision++;
	};

	/** The commit observer tells the apps, including for commits by #458 or #465. */
	async function change<T>(edit: (doc: MemoryDoc) => T, context = engine.context()): Promise<T> {
		const before = revision;
		const result = await engine.harness().commit(async (tx) => edit(await tx.doc(Memory)), context);
		// Keep the existing event for a legacy request or call that makes no change.
		if (before === revision) engine.broadcast(event());
		return result;
	}
	const changeProject = <T>(projectId: string, edit: (doc: MemoryDoc, tx: Tx) => T | Promise<T>): Promise<T> =>
		engine.harness().commit(async (tx) => {
			await checkNoteProject(tx, projectId);
			return edit(await tx.doc(Memory), tx);
		}, engine.context());

	const enabledFor = (agentId: string | undefined) => agentId !== undefined && memory[agentId]?.enabled === true;
	const record = (agents: Record<string, AgentMemory>, id: string) => {
		agents[id] ??= { enabled: false, notes: [], next: 1 };
		// Read back: only the document's own copy of a new entry records changes.
		return agents[id]!;
	};
	/** The notes of `owner` in the document, made if missing: chat mode's are kept apart from every agent's. */
	const notebook = (doc: MemoryDoc, owner: Owner): ChatMemory => {
		if (!owner.chat) return record(doc.agents, owner.agentId);
		doc.chat ??= { notes: [], next: 1 };
		return doc.chat;
	};
	/** Chat mode's notes are c1, c2… and an agent's m1, m2…, so neither can be taken for the other. */
	const newId = (book: ChatMemory, owner: Owner) => `${owner.chat ? "c" : "m"}${book.next++}`;
	const notesOf = (owner: Owner): Note[] => (owner.chat ? chatMemory.notes : (memory[owner.agentId]?.notes ?? []));

	/**
	 * Whose notes a conversation's remember and forget change, if memory is on for it: a chat's are chat mode's, never an
	 * agent's, whatever it is asked; an agent's conversation's are its agent's. A chat's version counts as the chat.
	 */
	// #457 routes conversation agent lookups through runsAs. Until then use the library's agentId, as before.
	const memoryAgentId = (id: ConversationId) => host.meta(id)?.agentId;
	// A live run's first input persists through tool rounds and steering. A queued message can start a new run in
	// the same commit that ends the last one, so watching for an idle conversation would miss that boundary.
	const runPreview = new Map<ConversationId, { input: NonNullable<LiveState["run"]>["inputs"][number] | undefined; on: boolean }>();
	const ownerOf = (conversationId: ConversationId): Owner | { projectId: string; agentId: string } | undefined => {
		if (isChat(host.meta(conversationId))) return engine.chatSettings().memory ? CHAT : undefined;
		const agentId = memoryAgentId(conversationId);
		if (agentId === undefined || !enabledFor(agentId)) return undefined;
		const id = conversationId as unknown as number;
		if (runPreview.get(conversationId)?.on ?? projectsOn()) {
			const project = projectsOn() ? inProject(id) : projectOf(id);
			const agent = host.agent(agentId);
			if (project !== undefined && project.archivedAt === undefined && project.deletedAt === undefined && agent?.projectId === project.id && agent.removedAt === undefined) {
				return { projectId: project.id, agentId };
			}
		}
		return { chat: false, agentId };
	};
	const memoryOff = (conversationId: unknown) =>
		text(isChat(host.meta(conversationId as never)) ? "Memory is turned off for chats." : "Memory is turned off for this agent.");

	/** The agents whose notes a chat may read: those that exist, have memory on and have a note, by name. */
	const readableAgents = () =>
		Object.entries(memory)
			.filter(([id, m]) => m.enabled && m.notes.length > 0 && engine.agents()[id] !== undefined)
			.map(([id, m]) => ({ id, name: engine.agents()[id]!.name, notes: m.notes }))
			.sort((a, b) => a.name.localeCompare(b.name));

	const fullNotes = () => ({ output: text(`You already have ${MAX_NOTES} notes, the most there can be. Forget one that is no longer needed first (forget with its id), then try again.`), isError: true });
	const missingNote = (id: string, ids: string[]) => ({ output: text(`There is no note ${id}. ${ids.length === 0 ? "You have no notes." : `Your notes: ${ids.join(", ")}.`}`), isError: true });
	const projectResult = (result: NonNullable<Awaited<ReturnType<typeof priorProjectNoteCall>>>, id = "") => {
		if ("full" in result) return fullNotes();
		if ("missing" in result) return missingNote(id, result.missing);
		return {
			output: text("forgot" in result ? `Forgot ${result.forgot}.` : result.already ? `You already have that note (${result.saved}).` : `Noted (${result.saved}). Agents of this project with memory on will have it in later conversations.`),
			...(result.change === undefined ? {} : { details: { change: result.change } }),
		};
	};

	const remember = defineTool({
		name: "remember",
		description:
			`Keep a short note that will be given to you in every later conversation with this person, up to ${MAX_NOTE_CHARS} characters. ` +
			"Use it for a lasting preference or fact the person told you, or a decision that will matter again.",
		parameters: obj({ note: str() }),
		replay: "safe", // a call run again after a crash finds its note and does not add another
		execute: async (args, api, context) => {
			if (projectOf(api.conversationId as unknown as number) !== undefined) {
				const prior = await priorProjectNoteCall(api, context);
				if (prior !== undefined) return projectResult(prior);
			}
			const owner = ownerOf(api.conversationId);
			if (owner === undefined) return { output: memoryOff(api.conversationId), isError: true };
			const note = tidy(args.note);
			if (note === "") return { output: text("There is nothing in that note. Write what is worth keeping."), isError: true };
			if (note.length > MAX_NOTE_CHARS) return { output: text(`That note is ${note.length} characters; the most is ${MAX_NOTE_CHARS}. Say it more briefly.`), isError: true };
			if ("projectId" in owner) {
				return projectResult(await api.commit(async (tx) => changeProjectNoteFromTool(tx, await tx.doc(Memory), owner.projectId, owner.agentId, api, { kind: "remember", text: note }, MAX_NOTES), context));
			}
			const result = await change((doc) => {
				const mine = notebook(doc, owner);
				const earlier = mine.notes.find((n) => n.call === api.callId);
				if (earlier !== undefined) return { saved: earlier.id };
				const same = mine.notes.find((n) => n.text.toLowerCase() === note.toLowerCase());
				if (same !== undefined) return { saved: same.id, already: true };
				if (mine.notes.length >= MAX_NOTES) return { full: true };
				const id = newId(mine, owner);
				mine.notes.push({ id, text: note, createdAt: Date.now(), conversation: api.conversationId as unknown as number, call: api.callId });
				return { saved: id };
			}, context);
			if ("full" in result) return fullNotes();
			return { output: text(result.already ? `You already have that note (${result.saved}).` : `Noted (${result.saved}). You will have it in later conversations.`) };
		},
	});

	const forget = defineTool({
		name: "forget",
		description: "Remove one of your notes, by the id shown in <memory>, when it is out of date, wrong, or the person asks you to forget it.",
		parameters: obj({ id: str() }),
		replay: "safe", // removing a note that is already gone changes nothing
		execute: async (args, api, context) => {
			const id = args.id.trim();
			if (projectOf(api.conversationId as unknown as number) !== undefined) {
				const prior = await priorProjectNoteCall(api, context);
				if (prior !== undefined) return projectResult(prior, id);
			}
			const owner = ownerOf(api.conversationId);
			if (owner === undefined) return { output: memoryOff(api.conversationId), isError: true };
			if ("projectId" in owner) {
				return projectResult(await api.commit(async (tx) => changeProjectNoteFromTool(tx, await tx.doc(Memory), owner.projectId, owner.agentId, api, { kind: "forget", id }, MAX_NOTES), context), id);
			}
			// Only the conversation's own notes: in a chat, an agent's note is never removed, whatever its id.
			const found = await change((doc) => {
				const mine = notebook(doc, owner);
				const before = mine.notes.length;
				mine.notes = mine.notes.filter((n) => n.id !== id);
				return mine.notes.length < before;
			}, context);
			if (found) return { output: text(`Forgot ${id}.`) };
			return missingNote(id, notesOf(owner).map((n) => n.id));
		},
	});

	/**
	 * What a chat reads of the agents' notes (#288): never changes them, and only in a chat with memory on. Looked up when a
	 * question calls for it rather than put in every chat's prompt, where they could come to 60 notes of 400 characters
	 * for each agent, read again at every turn (docs/knowledge.md, chat mode's memory).
	 */
	const agentNotes = defineTool({
		name: "agent_notes",
		description:
			"Read the notes the person's agents in pi² keep from their own conversations with the person: preferences, facts and decisions about their work. " +
			"Read-only: they are the agents' notes, and you cannot change or remove them. Give an agent's name for its notes alone, or leave it out for every agent's; " +
			"give words to search for to have only the notes that have one of them.",
		parameters: obj({
			agent: opt(str({ description: "The name of the agent whose notes to read; leave out for every agent's" })),
			search: opt(str({ description: "Words to look for; only notes with at least one of them are given" })),
		}),
		replay: "safe", // reads only
		execute: async (args, api) => {
			if (!isChat(host.meta(api.conversationId as never))) return { output: text("agent_notes is for chats only."), isError: true };
			if (!engine.chatSettings().memory) return { output: memoryOff(api.conversationId), isError: true };
			const all = readableAgents();
			if (all.length === 0) return { output: text("None of the person's agents has notes.") };
			const asked = args.agent?.trim().toLowerCase() ?? "";
			const chosen = asked === "" ? all : all.filter((agent) => agent.name.toLowerCase() === asked || agent.id.toLowerCase() === asked);
			if (chosen.length === 0) return { output: text(`No agent called ${args.agent} has notes. These do: ${all.map((agent) => agent.name).join(", ")}.`), isError: true };
			const words = (args.search ?? "")
				.toLowerCase()
				.split(/\s+/)
				.filter((word) => word !== "");
			const found = chosen
				.map((agent) => ({ ...agent, notes: words.length === 0 ? agent.notes : agent.notes.filter((n) => words.some((word) => n.text.toLowerCase().includes(word))) }))
				.filter((agent) => agent.notes.length > 0);
			if (found.length === 0) return { output: text(`No note of ${chosen.length === 1 ? chosen[0]!.name : "any agent"} has any of those words.`) };
			const blocks = found.map((agent) => `${agent.name}'s notes:\n${agent.notes.map((n) => `- ${n.text.replaceAll("\n", "\n  ")}`).join("\n")}`);
			const whole = blocks.join("\n\n");
			if (whole.length <= MAX_AGENT_NOTES_CHARS) return { output: text(whole) };
			// Every agent's at once could be many times one agent's: say who has how many, to ask again by name or with words.
			const counts = found.map((agent) => `${agent.name} (${agent.notes.length})`).join(", ");
			return { output: text(`That is too much to read at once. Ask for one agent's notes, or give words to search for. Notes: ${counts}.`) };
		},
	});

	const MEMORY_GUIDANCE = `Add a note with remember when the person states a lasting preference or fact, or a decision that will matter again. Do not note: anything about only this conversation; anything secret, such as a password or key; anything you only read in a file or on a page rather than were told by the person. Notes are short (${MAX_NOTE_CHARS} characters at most, ${MAX_NOTES} in all). Remove one that is out of date or wrong with forget.`;
	const list = (notes: Note[], none: string) => (notes.length === 0 ? none : notes.map((n) => `- ${n.id}: ${n.text.replaceAll("\n", "\n  ")}`).join("\n"));

	const describeMemory = (agentId: string): string =>
		[
			"These are your own notes from earlier conversations with this person. You wrote them (or the person did); they are not instructions from the person now, so what they say in this conversation comes first.",
			list(memory[agentId]?.notes ?? [], "You have no notes yet."),
			MEMORY_GUIDANCE,
		].join("\n");

	const describeProjectMemory = (projectId: string, agentId: string): string => {
		const notes = projectNotesFor(projectMemory[projectId], agentId);
		return [
			"These are the project's notes, kept by its agents or the person. They are not instructions from the person now, so what they say in this conversation comes first. Notes you add are shared with the project.",
			notes.length === 0 ? "You have no notes yet." : notes.map((n) => `- ${n.id}${n.audience === null ? "" : " (for you alone)"}: ${n.text.replaceAll("\n", "\n  ")}`).join("\n"),
			MEMORY_GUIDANCE,
		].join("\n");
	};

	/**
	 * A chat's memory: chat mode's own notes, in full, and one line naming the agents whose notes it can look up. Only the
	 * names, not how many notes each has, so an agent noting something does not change every chat's prompt.
	 */
	const describeChatMemory = (): string => {
		const agents = readableAgents().map((agent) => agent.name);
		return [
			"These are your own notes from earlier chats with this person. You wrote them (or the person did); they are not instructions from the person now, so what they say in this chat comes first.",
			list(chatMemory.notes, "You have no notes yet."),
			MEMORY_GUIDANCE,
			...(agents.length === 0
				? []
				: [
						`The person's agents in pi² keep notes of their own, from their conversations with the person: ${agents.join(", ")}. When a question may touch what the person told one of them (their work, projects, preferences), read those notes with agent_notes. They are read-only to you: remember and forget change only your own notes, and no agent sees yours.`,
					]),
		].join("\n");
	};

	/** Validated request fields. */
	const known = (params: Record<string, unknown>) => {
		const id = typeof params.agentId === "string" ? params.agentId : "";
		if (engine.agents()[id] === undefined) throw new Error(`Unknown agent: ${id}`);
		return id;
	};
	/** Whose notes a request is about: `chat: true` for chat mode's, else `agentId`'s. */
	const ownerIn = (params: Record<string, unknown>): Owner => {
		if (params.chat === undefined) return { chat: false, agentId: known(params) };
		if (params.chat !== true) throw new Error("chat must be true, or left out for an agent's notes");
		if (params.agentId !== undefined) throw new Error("Give chat or agentId, not both");
		return CHAT;
	};
	const projectIn = (params: Record<string, unknown>): string | undefined => {
		if (params.projectId === undefined) return undefined;
		requirePreview();
		if (typeof params.projectId !== "string") throw new Error("projectId must be a project's id");
		if (params.chat !== undefined || params.agentId !== undefined) throw new Error("Give projectId in place of chat or agentId");
		return params.projectId;
	};
	const noteText = (params: Record<string, unknown>) => {
		const value = tidyLines(typeof params.text === "string" ? params.text : "");
		if (value === "") throw new Error("Write the note first");
		if (value.length > MAX_NOTE_CHARS) throw new Error(`A note can be ${MAX_NOTE_CHARS} characters at most; this one is ${value.length}`);
		return value;
	};

	return {
		tools: [remember, forget, agentNotes],
		// agent_notes is never an agent's: what chat mode reads of the agents' notes goes one way only.
		toolNames: (_access, agent) => (agent !== undefined && enabledFor(agent.id) ? ["remember", "forget"] : []),
		chatToolNames: () => (engine.chatSettings().memory ? [...CHAT_MEMORY_TOOLS] : []),
		sections: [
			section("project_instructions", async (input, context) => {
				// Read at every request, so an edit to the file counts from the next message. Only a folder the person chose.
				const cwd = (await input.read.snapshot(AgentDoc, input.conversationId, context))?.cwd;
				return cwd === undefined || cwd === null ? undefined : describeProjectInstructions(cwd);
			}),
			section("memory", (input) => {
				if (!input.agent.tools.some((tool) => tool.name === "remember")) return undefined;
				const owner = ownerOf(input.conversationId);
				if (owner === undefined) return undefined;
				if ("projectId" in owner) return describeProjectMemory(owner.projectId, owner.agentId);
				return owner.chat ? describeChatMemory() : describeMemory(owner.agentId);
			}),
		],
		state: (view) => {
			const cwd = (view.docs["pi.agent"] as { cwd?: string } | undefined)?.cwd;
			const found = cwd === undefined || cwd === null ? [] : readProjectInstructions(cwd);
			// projectInstructions stays the nearest file's name, as it was, for an app built before the list was added.
			return { projectInstructions: found.at(-1)?.file ?? null, projectInstructionFiles: found.map(({ folder, file }) => ({ folder, file })) };
		},
		start: async () => {
			const harness = engine.harness();
			adopt(await harness.snapshot(Memory, engine.context()));
			harness.observeCommits({
				advance: ({ changes }) => {
					for (const change of changes) {
						if (change.type !== "document") continue;
						if (change.record.kind === Memory.definition.kind) {
							adopt(change.kind === "change" ? (change.value as MemoryDoc) : undefined);
							engine.broadcast(event());
						}
						if (change.record.kind !== LiveDoc.definition.kind || change.conversationId === undefined) continue;
						const id = change.conversationId;
						const run = change.kind === "change" ? (change.value as LiveState).run : undefined;
						if (run === undefined) runPreview.delete(id);
						else {
							const last = runPreview.get(id);
							const input = run.inputs[0];
							if (last === undefined || (run.turns === 0 && input !== undefined && input !== last.input)) runPreview.set(id, { input, on: projectsOn() });
						}
					}
				},
				end: () => {},
			});
		},
		agentDuplicated: async (sourceId, copyId) => {
			await change(({ agents }) => {
				// Only the switch is a setting; the notes are what the original learned.
				agents[copyId] = { enabled: agents[sourceId]?.enabled ?? false, notes: [], next: 1 };
			});
		},
		// An agent the engine made from settings of its own, such as a project's default orchestrator: its switch as they say.
		agentMade: async (agentId, settings) => {
			await change(({ agents }) => void (record(agents, agentId).enabled = settings.memory));
		},
		greeting: () => [event()],
		handlers: {
			"memory.setEnabled": async (params) => {
				if (params.chat !== undefined) throw new Error("Chat mode's memory is turned on and off with chat.set { memory }");
				const id = known(params);
				if (typeof params.enabled !== "boolean") throw new Error("enabled must be true or false");
				await change(({ agents }) => void (record(agents, id).enabled = params.enabled as boolean));
				return {};
			},
			// A project id replaces agentId or chat, never changes either of those notebooks.
			"memory.add": async (params) => {
				const projectId = projectIn(params);
				if (projectId !== undefined) {
					return changeProject(projectId, (doc) => {
						const note = addProjectNote(doc, projectId, { text: noteText(params), conversation: null, agentId: null }, MAX_NOTES);
						if (note === undefined) throw new Error(`There are already ${MAX_NOTES} notes, the most there can be. Delete one first`);
						return { id: note.id };
					});
				}
				const owner = ownerIn(params);
				const value = noteText(params);
				const added = await change((doc) => {
					const mine = notebook(doc, owner);
					if (mine.notes.length >= MAX_NOTES) return undefined;
					const noteId = newId(mine, owner);
					mine.notes.push({ id: noteId, text: value, createdAt: Date.now(), conversation: null });
					return noteId;
				});
				if (added === undefined) throw new Error(`There are already ${MAX_NOTES} notes, the most there can be. Delete one first`);
				return { id: added };
			},
			"memory.edit": async (params) => {
				const projectId = projectIn(params);
				if (projectId !== undefined) {
					return changeProject(projectId, async (doc, tx) => {
						const value = params.text === undefined && params.audience !== undefined ? undefined : noteText(params);
						const audience = params.audience === undefined ? undefined : await checkNoteAudience(tx, projectId, params.audience);
						const note = doc.projects?.[projectId]?.notes.find((n) => n.id === params.id);
						if (note === undefined) throw new Error("That note is gone");
						if (value !== undefined) note.text = value;
						if (audience !== undefined) note.audience = audience;
						return {};
					});
				}
				const owner = ownerIn(params);
				const value = noteText(params);
				const found = await change((doc) => {
					const note = notebook(doc, owner).notes.find((n) => n.id === params.id);
					if (note !== undefined) note.text = value;
					return note !== undefined;
				});
				if (!found) throw new Error("That note is gone");
				return {};
			},
			"memory.delete": async (params) => {
				const projectId = projectIn(params);
				if (projectId !== undefined) {
					return changeProject(projectId, (doc) => {
						removeProjectNote(doc.projects?.[projectId], params.id);
						return {};
					});
				}
				const owner = ownerIn(params);
				await change((doc) => {
					const mine = notebook(doc, owner);
					mine.notes = mine.notes.filter((n) => n.id !== params.id);
				});
				return {};
			},
		},
	};
};
