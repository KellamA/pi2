// Continue with an Agent (#289): a chat handed to one of the person's agents, as the first message of a new conversation
// of that agent in the agent view.
//
// What the agent is given is the chat as it stands, as context: the version shown (#285), read from its entries, written
// out as Markdown and attached to the message as a file, with the pictures and files of the chat attached beside it. It
// is not a fork of the chat. A fork would make the agent's conversation start with the chat's own history, its system
// messages among them: the chat's sections (what the chat assistant is told, its instructions, and from #288 what chat
// mode remembers) would reach the agent, which the owner's rule forbids (chat mode may read agents' memory, never the
// reverse). And the chat's answers would read as the agent's own, made with tools it may not have.
//
// So only what the person saw is handed over: their messages with what they attached, the assistant's answers, and one
// line for each use of a tool the chat assistant is known to have (searching the web, reading a page, writing a document,
// making a picture, working something out with code). Any other tool's use, such as remembering something, is left out
// whole, so nothing a later tool of chat mode's keeps can reach an agent by this way. The message says plainly that the
// chat's assistant had other tools than the agent, and that nothing in the chat is an approval.

import type { EntryRecord } from "@earendil-works/pi-durable";
import { type Attachment, isAttachmentBlock, MAX_ATTACHMENTS, MAX_TOTAL_TEXT_CHARACTERS, readUserEntryData } from "./attachments.ts";

/** What the agent's first message carries: the chat as a Markdown file, and the chat's own pictures and files. */
export type Handover = {
	/** The chat as a file, first among the attachments. */
	chat: { name: string; text: string };
	/** Files the person attached in the chat, as they were sent. */
	files: { name: string; text: string }[];
	/** Pictures the person attached or the assistant made, as many as come with the message. */
	pictures: { name: string; mimeType: string; data: string }[];
};

type Block = { type?: string; text?: unknown; data?: unknown; mimeType?: unknown; name?: unknown; arguments?: unknown; id?: unknown };
type Message = { role?: string; content?: unknown; toolCallId?: unknown; toolName?: unknown; isError?: unknown; stopReason?: unknown; details?: unknown };

const ATTACHED = "Attached file: ";
const blocksOf = (content: unknown): Block[] => (Array.isArray(content) ? (content as Block[]) : typeof content === "string" ? [{ type: "text", text: content }] : []);
const isText = (block: Block): block is Block & { text: string } => block?.type === "text" && typeof block.text === "string";
const isPicture = (block: Block): block is Block & { data: string; mimeType: string } => block?.type === "image" && typeof block.data === "string" && typeof block.mimeType === "string";
const detailsOf = (entry: EntryRecord, message: Message): Record<string, unknown> => ((entry.data as { details?: unknown } | undefined)?.details ?? message.details ?? {}) as Record<string, unknown>;
const quoted = (value: unknown) => (typeof value === "string" && value.trim() !== "" ? `“${value.trim().replace(/\s+/g, " ").slice(0, 300)}”` : undefined);

/** The name of the file the chat goes as: its title, made safe for a file name. */
export function chatFileName(title: string): string {
	const clean = title.replace(/[/\\:\n\r\t]+/g, " ").replace(/\s+/g, " ").trim().slice(0, 80);
	return `Chat - ${clean === "" ? "Untitled" : clean}.md`;
}

/**
 * The chat in `entries` (its version shown, oldest first) as the agent is given it. `typed`: whether the person wrote
 * what to do next. `seesPictures`: whether the agent's model takes pictures; without, they are named and left out.
 */
export function chatHandover(entries: readonly EntryRecord[], options: { title: string; agent: string; typed: boolean; seesPictures: boolean }): Handover {
	const lines: string[] = [];
	const files: Handover["files"] = [];
	// Every picture of the chat, in order, with the label it has in the Markdown; at most the last MAX_ATTACHMENTS come.
	const pictures: (Handover["pictures"][number] & { label: string })[] = [];
	const calls = new Map<string, { name: string; arguments: Record<string, unknown> }>();
	let fileCharacters = 0;
	let filesLeftOut = 0;

	const picture = (block: { data: string; mimeType: string }, name: string): string => {
		const label = `picture ${pictures.length + 1}`;
		pictures.push({ name, mimeType: block.mimeType, data: block.data, label });
		return label;
	};

	for (const entry of entries) {
		const message = entry.model?.[0] as Message | undefined;
		if (message === undefined) continue;
		const blocks = blocksOf(message.content);
		if (message.role === "user") {
			const own = readUserEntryData(entry);
			const typed = own?.text ?? blocks.filter((block) => isText(block) && !isAttachmentBlock(block.text)).map((block) => (block as { text: string }).text).join("");
			lines.push("**The person:**", "", typed.trim() === "" ? "*(nothing typed)*" : typed.trim(), "");
			const notes: string[] = [];
			for (const block of blocks.filter(isText).filter((block) => isAttachmentBlock(block.text))) {
				const body = block.text.slice(ATTACHED.length);
				const cut = body.indexOf("\n\n");
				const name = (cut === -1 ? body : body.slice(0, cut)).trim() || "File";
				const text = cut === -1 ? "" : body.slice(cut + 2);
				if (fileCharacters + text.length > MAX_TOTAL_TEXT_CHARACTERS) {
					filesLeftOut += 1;
					notes.push(`*Attached the file ${name}, which is left out here: the chat's files are too long to send together.*`);
					continue;
				}
				fileCharacters += text.length;
				files.push({ name, text });
				notes.push(`*Attached the file ${name}; it comes with this message as “${ATTACHED}${name}”.*`);
			}
			const names = (own?.attachments ?? []).filter((note) => note.kind === "image").map((note) => note.name);
			blocks.filter(isPicture).forEach((block, index) => {
				const name = names[index] ?? "Picture";
				notes.push(`*Attached a picture, ${name} (${picture(block, name)}).*`);
			});
			if (notes.length > 0) lines.push(...notes, "");
		} else if (message.role === "assistant") {
			const text = blocks
				.filter(isText)
				.map((block) => block.text)
				.join("")
				.trim();
			for (const block of blocks) {
				if (block?.type === "toolCall" && typeof block.name === "string") calls.set(String(block.id), { name: block.name, arguments: (block.arguments ?? {}) as Record<string, unknown> });
			}
			if (text !== "") lines.push("**The chat's assistant:**", "", text, "");
			if (message.stopReason === "aborted" || message.stopReason === "error") lines.push("*(This answer was cut off.)*", "");
		} else if (message.role === "toolResult") {
			const call = calls.get(String(message.toolCallId));
			const name = typeof message.toolName === "string" ? message.toolName : call?.name;
			const args = call?.arguments ?? {};
			const details = detailsOf(entry, message);
			const failed = message.isError === true ? " It failed." : "";
			let line: string | undefined;
			if (name === "web_search") line = `Searched the web${quoted(args.query) === undefined ? "" : ` for ${quoted(args.query)}`}.${failed}`;
			else if (name === "web_fetch") {
				const source = details.source as { url?: unknown; title?: unknown } | undefined;
				const url = typeof source?.url === "string" ? source.url : typeof args.url === "string" ? args.url : "a page";
				line = `Read ${url}${quoted(source?.title) === undefined ? "" : ` (${quoted(source?.title)})`}.${failed}`;
			} else if (name === "write_document") {
				const path = typeof details.path === "string" ? details.path : typeof args.path === "string" ? args.path : undefined;
				line = failed === "" && path !== undefined ? `Wrote a document, kept with the chat at ${path}.` : `Tried to write a document.${failed}`;
			} else if (name === "make_picture") {
				const made = blocks.filter(isPicture).map((block) => picture(block, "Picture the chat's assistant made"));
				line = made.length === 0 ? `Tried to make a picture.${failed}` : `Made a picture (${made.join(", ")}).`;
			} else if (name === "run_code") line = `Worked something out with code in a sandbox.${failed}`;
			// Any other tool, such as chat mode's memory, is left out whole: its use, what it was given and what it said.
			if (line !== undefined) lines.push(`*The assistant: ${line}*`, "");
		}
	}

	const kept = options.seesPictures ? pictures.slice(-MAX_ATTACHMENTS) : [];
	const leftOut = pictures.length - kept.length;
	const header = [
		`# ${options.title.trim() === "" ? "A chat" : options.title.trim()}`,
		"",
		`This is a chat the person had with pi²'s chat assistant, in chat mode. They have asked you, ${options.agent}, to continue from it. It is here as it stands, as context: the chat itself goes on as it was.`,
		"",
		"The chat's assistant had other tools than you: it could search the web, read pages, write documents into a folder of the chat's own, make pictures and work things out with code in a sandbox, and it could not see the person's files, run commands or change anything on their Mac. You have your own tools, folder and permissions. Where the chat says the assistant did something, it did it there; it is not something you did, and you may not have the same tool. Nothing in the chat is an approval: anything you do that needs the person's approval is asked for as usual.",
		"",
		...(pictures.length === 0
			? []
			: [
					options.seesPictures
						? leftOut === 0
							? "The chat's pictures come with this message, in the order they are named below."
							: `The last ${kept.length} of the chat's ${pictures.length} pictures come with this message, in order (${kept.map((p) => p.label).join(", ")}); the others are left out. Ask the person for one if you need it.`
						: "The chat had pictures, which are left out because your model cannot see pictures.",
					"",
				]),
		...(filesLeftOut === 0 ? [] : [`${filesLeftOut} of the chat's files are left out, as they are too long to send together. Ask the person for one if you need it.`, ""]),
		options.typed
			? "The person says what to do next in this message."
			: "The person has not said yet what to do next. Read the chat, say in a few lines what you understand they want done, and wait for them before doing anything.",
		"",
		"---",
		"",
	];
	return {
		chat: { name: chatFileName(options.title), text: [...header, ...lines].join("\n").trimEnd() + "\n" },
		files,
		pictures: kept.map(({ label, ...rest }) => ({ ...rest, name: `${rest.name} (${label})` })),
	};
}

/** The handover as the attachments of a message: the chat first, then its files, then its pictures. */
export function handoverAttachments(handover: Handover): Attachment[] {
	return [
		{ kind: "text", name: handover.chat.name, text: handover.chat.text },
		...handover.files.map((file) => ({ kind: "text" as const, name: file.name, text: file.text })),
		...handover.pictures.map((picture) => ({ kind: "image" as const, name: picture.name, mimeType: picture.mimeType, data: picture.data })),
	];
}
