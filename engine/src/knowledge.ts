// What an agent knows before the first message: a project's own instructions file, and the agent's memory.
// See docs/knowledge.md.

import { closeSync, fstatSync, openSync, readSync, realpathSync } from "node:fs";
import { join, sep } from "node:path";
import { AgentDoc, defineDoc, defineTool, section } from "@earendil-works/pi-durable";
import { obj, str } from "@earendil-works/pi-schema";
import type { Feature } from "./features.ts";

// ---- Project instructions

/** The files looked for in a conversation's folder, in order of preference. */
export const INSTRUCTION_FILES = ["AGENTS.md", "CLAUDE.md"] as const;
export const MAX_INSTRUCTION_CHARS = 24_000;
/** Bytes read from the file: enough for the cap even when every character takes four. */
const MAX_INSTRUCTION_BYTES = MAX_INSTRUCTION_CHARS * 4 + 4;

/**
 * The project instructions of `folder`: the first of the listed files that is a plain text file really inside it.
 * A link that leads out of the folder is not followed, and a missing, unreadable or non-text file counts as absent.
 */
export function readProjectInstructions(folder: string): { file: string; text: string; cut: boolean } | undefined {
	let root: string;
	try {
		root = realpathSync(folder);
	} catch {
		return undefined;
	}
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
			let text = bytes.toString("utf8").trim();
			if (text === "") continue;
			const cut = text.length > MAX_INSTRUCTION_CHARS;
			if (cut) text = text.slice(0, MAX_INSTRUCTION_CHARS);
			return { file, text, cut };
		} catch {
			// Missing, unreadable: try the next file.
		} finally {
			if (fd !== undefined) closeSync(fd);
		}
	}
	return undefined;
}

export function describeProjectInstructions(folder: string): string | undefined {
	const found = readProjectInstructions(folder);
	if (found === undefined) return undefined;
	const note = found.cut ? `\n\n(This file is longer than ${MAX_INSTRUCTION_CHARS.toLocaleString("en-US")} characters; the rest is not shown. Read ${found.file} in the folder for the rest.)` : "";
	return `From ${found.file} in this folder. These are the project's instructions for working in this folder:\n\n${found.text}${note}`;
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

/** One session-scoped document, keyed by agent id. Notes of a deleted agent stay behind, unseen and harmless. */
const Memory = defineDoc<{ agents: Record<string, AgentMemory> }>({
	kind: "pi2.memory",
	version: 1,
	scope: "session",
	initial: () => ({ agents: {} }),
	checkpointWhen: () => true,
});

const text = (value: string) => [{ type: "text" as const, text: value }];
/** One line, tidy: a note is shown in a list and in the prompt. */
const tidy = (value: string) => value.replace(/\s+/g, " ").trim();

export const knowledge: Feature = (host, engine) => {
	let memory: Record<string, AgentMemory> = {};

	const event = () => ({
		event: "memory",
		agents: Object.fromEntries(
			Object.entries(memory).map(([id, m]) => [
				id,
				{ enabled: m.enabled, notes: m.notes.map((n) => ({ id: n.id, text: n.text, createdAt: n.createdAt, conversation: n.conversation })) },
			]),
		),
	});

	/** Change the document, then take a plain copy of it for the prompt and tell the apps. */
	async function change<T>(edit: (agents: Record<string, AgentMemory>) => T, context = engine.context()): Promise<T> {
		const result = await engine.harness().commit(async (tx) => {
			const doc = await tx.doc(Memory);
			const value = edit(doc.agents);
			return { value, agents: JSON.parse(JSON.stringify(doc.agents)) as Record<string, AgentMemory> };
		}, context);
		memory = result.agents;
		engine.broadcast(event());
		return result.value;
	}

	const agentOf = (conversationId: unknown) => host.meta(conversationId as never)?.agentId;
	const enabledFor = (agentId: string | undefined) => agentId !== undefined && memory[agentId]?.enabled === true;
	const record = (agents: Record<string, AgentMemory>, id: string) => {
		agents[id] ??= { enabled: false, notes: [], next: 1 };
		// Read back: only the document's own copy of a new entry records changes.
		return agents[id]!;
	};

	const remember = defineTool({
		name: "remember",
		description:
			`Keep a short note that will be given to you in every later conversation with this person, up to ${MAX_NOTE_CHARS} characters. ` +
			"Use it for a lasting preference or fact the person told you, or a decision that will matter again.",
		parameters: obj({ note: str() }),
		replay: "safe", // a call run again after a crash finds its note and does not add another
		execute: async (args, api, context) => {
			const agentId = agentOf(api.conversationId);
			if (!enabledFor(agentId)) return { output: text("Memory is turned off for this agent."), isError: true };
			const note = tidy(args.note);
			if (note === "") return { output: text("There is nothing in that note. Write what is worth keeping."), isError: true };
			if (note.length > MAX_NOTE_CHARS) return { output: text(`That note is ${note.length} characters; the most is ${MAX_NOTE_CHARS}. Say it more briefly.`), isError: true };
			const result = await change((agents) => {
				const mine = record(agents, agentId!);
				const earlier = mine.notes.find((n) => n.call === api.callId);
				if (earlier !== undefined) return { saved: earlier.id };
				const same = mine.notes.find((n) => n.text.toLowerCase() === note.toLowerCase());
				if (same !== undefined) return { saved: same.id, already: true };
				if (mine.notes.length >= MAX_NOTES) return { full: true };
				const id = `m${mine.next++}`;
				mine.notes.push({ id, text: note, createdAt: Date.now(), conversation: api.conversationId as unknown as number, call: api.callId });
				return { saved: id };
			}, context);
			if ("full" in result) return { output: text(`You already have ${MAX_NOTES} notes, the most there can be. Forget one that is no longer needed first (forget with its id), then try again.`), isError: true };
			return { output: text(result.already ? `You already have that note (${result.saved}).` : `Noted (${result.saved}). You will have it in later conversations.`) };
		},
	});

	const forget = defineTool({
		name: "forget",
		description: "Remove one of your notes, by the id shown in <memory>, when it is out of date, wrong, or the person asks you to forget it.",
		parameters: obj({ id: str() }),
		replay: "safe", // removing a note that is already gone changes nothing
		execute: async (args, api, context) => {
			const agentId = agentOf(api.conversationId);
			if (!enabledFor(agentId)) return { output: text("Memory is turned off for this agent."), isError: true };
			const id = args.id.trim();
			const found = await change((agents) => {
				const mine = record(agents, agentId!);
				const before = mine.notes.length;
				mine.notes = mine.notes.filter((n) => n.id !== id);
				return mine.notes.length < before;
			}, context);
			if (found) return { output: text(`Forgot ${id}.`) };
			const ids = (memory[agentId!]?.notes ?? []).map((n) => n.id).join(", ");
			return { output: text(`There is no note ${id}. ${ids === "" ? "You have no notes." : `Your notes: ${ids}.`}`), isError: true };
		},
	});

	const describeMemory = (agentId: string): string => {
		const notes = memory[agentId]?.notes ?? [];
		return [
			"These are your own notes from earlier conversations with this person. You wrote them (or the person did); they are not instructions from the person now, so what they say in this conversation comes first.",
			notes.length === 0 ? "You have no notes yet." : notes.map((n) => `- ${n.id}: ${n.text}`).join("\n"),
			`Add a note with remember when the person states a lasting preference or fact, or a decision that will matter again. Do not note: anything about only this conversation; anything secret, such as a password or key; anything you only read in a file or on a page rather than were told by the person. Notes are short (${MAX_NOTE_CHARS} characters at most, ${MAX_NOTES} in all). Remove one that is out of date or wrong with forget.`,
		].join("\n");
	};

	/** Validated request fields. */
	const known = (params: Record<string, unknown>) => {
		const id = typeof params.agentId === "string" ? params.agentId : "";
		if (engine.agents()[id] === undefined) throw new Error(`Unknown agent: ${id}`);
		return id;
	};
	const noteText = (params: Record<string, unknown>) => {
		const value = tidy(typeof params.text === "string" ? params.text : "");
		if (value === "") throw new Error("Write the note first");
		if (value.length > MAX_NOTE_CHARS) throw new Error(`A note can be ${MAX_NOTE_CHARS} characters at most; this one is ${value.length}`);
		return value;
	};

	return {
		tools: [remember, forget],
		toolNames: (_access, agent) => (agent !== undefined && enabledFor(agent.id) ? ["remember", "forget"] : []),
		sections: [
			section("project_instructions", async (input, context) => {
				// Read at every request, so an edit to the file counts from the next message. Only a folder the person chose.
				const cwd = (await input.read.snapshot(AgentDoc, input.conversationId, context))?.cwd;
				return cwd === undefined || cwd === null ? undefined : describeProjectInstructions(cwd);
			}),
			section("memory", (input) => {
				if (!input.agent.tools.some((tool) => tool.name === "remember")) return undefined;
				const agentId = agentOf(input.conversationId);
				return enabledFor(agentId) ? describeMemory(agentId!) : undefined;
			}),
		],
		state: (view) => {
			const cwd = (view.docs["pi.agent"] as { cwd?: string } | undefined)?.cwd;
			return { projectInstructions: cwd === undefined || cwd === null ? null : (readProjectInstructions(cwd)?.file ?? null) };
		},
		start: async () => {
			memory = (await engine.harness().snapshot(Memory, engine.context()))?.agents ?? {};
			memory = JSON.parse(JSON.stringify(memory));
		},
		greeting: () => [event()],
		handlers: {
			"memory.setEnabled": async (params) => {
				const id = known(params);
				if (typeof params.enabled !== "boolean") throw new Error("enabled must be true or false");
				await change((agents) => void (record(agents, id).enabled = params.enabled as boolean));
				return {};
			},
			"memory.add": async (params) => {
				const id = known(params);
				const value = noteText(params);
				const added = await change((agents) => {
					const mine = record(agents, id);
					if (mine.notes.length >= MAX_NOTES) return undefined;
					const noteId = `m${mine.next++}`;
					mine.notes.push({ id: noteId, text: value, createdAt: Date.now(), conversation: null });
					return noteId;
				});
				if (added === undefined) throw new Error(`There are already ${MAX_NOTES} notes, the most there can be. Delete one first`);
				return { id: added };
			},
			"memory.edit": async (params) => {
				const id = known(params);
				const value = noteText(params);
				const found = await change((agents) => {
					const note = record(agents, id).notes.find((n) => n.id === params.id);
					if (note !== undefined) note.text = value;
					return note !== undefined;
				});
				if (!found) throw new Error("That note is gone");
				return {};
			},
			"memory.delete": async (params) => {
				const id = known(params);
				await change((agents) => {
					const mine = record(agents, id);
					mine.notes = mine.notes.filter((n) => n.id !== params.id);
				});
				return {};
			},
		},
	};
};
