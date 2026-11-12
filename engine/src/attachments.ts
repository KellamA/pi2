// Pictures and files sent with a message: checking them, turning them into what the model is sent, and recording
// what the transcript shows for them.

import type { ImageContent, TextContent } from "@earendil-works/pi-ai";

export type Attachment = { kind: "image"; name: string; mimeType: string; data: string } | { kind: "text"; name: string; text: string };

/** What the transcript keeps about an attachment. `size` is in bytes: the picture's, or the text's as UTF-8. */
export type AttachmentNote = { name: string; kind: "image" | "text"; size: number };

/** What a message with attachments records beside its model message: the typed text on its own, and what came with it. */
export type UserEntryData = { text: string; attachments: AttachmentNote[] };

/** The entry kind of a message sent with attachments. A message without any is pi durable's plain `pi.user`. */
export const USER_ENTRY_KIND = "pi2.user";

export const MAX_ATTACHMENTS = 10;
export const MAX_IMAGE_BYTES = 5 * 1024 * 1024;
export const MAX_TEXT_CHARACTERS = 400_000;
export const MAX_TOTAL_TEXT_CHARACTERS = 1_500_000;

/** The picture formats every provider that takes pictures accepts, and how each file starts. */
const IMAGE_TYPES: Record<string, { label: string; matches: (head: Buffer) => boolean }> = {
	"image/png": { label: "PNG", matches: (head) => head.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) },
	"image/jpeg": { label: "JPEG", matches: (head) => head[0] === 0xff && head[1] === 0xd8 && head[2] === 0xff },
	"image/gif": { label: "GIF", matches: (head) => ["GIF87a", "GIF89a"].includes(head.subarray(0, 6).toString("latin1")) },
	"image/webp": { label: "WebP", matches: (head) => head.subarray(0, 4).toString("latin1") === "RIFF" && head.subarray(8, 12).toString("latin1") === "WEBP" },
};

const count = (n: number) => n.toLocaleString("en-US");

/** A size as a person reads it: "340 KB", "1.4 MB". */
export function sizeText(bytes: number): string {
	if (bytes < 1024) return `${bytes} bytes`;
	if (bytes < 1024 * 1024) return `${Math.max(1, Math.round(bytes / 1024))} KB`;
	return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

/** A name on one line, short enough to show. */
function cleanName(value: unknown, fallback: string): string {
	const name = typeof value === "string" ? value.replace(/\s+/g, " ").trim().slice(0, 200) : "";
	return name === "" ? fallback : name;
}

/** How many bytes a base64 string decodes to, without decoding it. */
function decodedSize(base64: string): number {
	const padding = base64.endsWith("==") ? 2 : base64.endsWith("=") ? 1 : 0;
	return Math.floor((base64.length * 3) / 4) - padding;
}

/**
 * Check what the app sent with a message. Every refusal says what is wrong and what to do about it, because the
 * person reads it as it is.
 */
export function validateAttachments(input: unknown): Attachment[] {
	if (input === undefined || input === null) return [];
	if (!Array.isArray(input)) throw new Error("attachments must be a list");
	if (input.length > MAX_ATTACHMENTS) throw new Error(`A message can carry at most ${MAX_ATTACHMENTS} attachments; this one has ${input.length}. Remove some and send again.`);
	const attachments: Attachment[] = [];
	let totalText = 0;
	for (const raw of input as { kind?: unknown; name?: unknown; mimeType?: unknown; data?: unknown; text?: unknown }[]) {
		if (raw?.kind === "image") {
			const name = cleanName(raw.name, "Picture");
			const type = typeof raw.mimeType === "string" && Object.hasOwn(IMAGE_TYPES, raw.mimeType) ? IMAGE_TYPES[raw.mimeType] : undefined;
			if (type === undefined) throw new Error(`“${name}” is ${typeof raw.mimeType === "string" && raw.mimeType !== "" ? raw.mimeType : "of an unknown type"}, which cannot be sent as a picture. Use PNG, JPEG, GIF or WebP.`);
			const data = typeof raw.data === "string" ? raw.data : "";
			if (data === "" || data.length % 4 !== 0 || !/^[A-Za-z0-9+/]*={0,2}$/.test(data)) throw new Error(`“${name}” did not arrive whole. Attach it again.`);
			const size = decodedSize(data);
			if (size > MAX_IMAGE_BYTES) {
				// Rounded to a tenth, a picture barely over the limit would read as "5.0 MB; at most 5.0 MB".
				const actual = sizeText(size) === sizeText(MAX_IMAGE_BYTES) ? "just over 5 MB" : sizeText(size);
				throw new Error(`“${name}” is ${actual}; a picture can be at most 5 MB. Scale it down and attach it again.`);
			}
			// A file whose contents are not what its type says would only fail later, at the provider, with a worse message.
			if (!type.matches(Buffer.from(data.slice(0, 24), "base64"))) throw new Error(`“${name}” is not a ${type.label} picture, though it was sent as one. Attach it again.`);
			attachments.push({ kind: "image", name, mimeType: raw.mimeType as string, data });
		} else if (raw?.kind === "text") {
			const name = cleanName(raw.name, "Text");
			const text = typeof raw.text === "string" ? raw.text : "";
			if (text.trim() === "") throw new Error(`“${name}” has no text in it. Remove it and send again.`);
			if (text.length > MAX_TEXT_CHARACTERS) throw new Error(`“${name}” has ${count(text.length)} characters; one attached text can have at most ${count(MAX_TEXT_CHARACTERS)}. Attach a shorter part of it.`);
			totalText += text.length;
			attachments.push({ kind: "text", name, text });
		} else {
			throw new Error(`Unknown kind of attachment: ${String(raw?.kind)}`);
		}
	}
	if (totalText > MAX_TOTAL_TEXT_CHARACTERS) throw new Error(`The attached texts add up to ${count(totalText)} characters; a message can carry at most ${count(MAX_TOTAL_TEXT_CHARACTERS)}. Remove some and send again.`);
	return attachments;
}

/** The first line of an attached text's block, so the model knows the text under it is a file and which one. */
const ATTACHMENT_HEADER = "Attached file: ";

/** Whether a text block of a user message is an attached file rather than what the person typed. */
export function isAttachmentBlock(text: string): boolean {
	return text.startsWith(ATTACHMENT_HEADER);
}

/**
 * The model's view of a message with attachments: what the person typed, then each attached text under a line naming
 * it, then the pictures.
 */
export function userContent(text: string, attachments: readonly Attachment[]): (TextContent | ImageContent)[] {
	const blocks: (TextContent | ImageContent)[] = [];
	if (text.trim() !== "") blocks.push({ type: "text", text });
	for (const attachment of attachments) {
		// Ending on a line break keeps one file apart from the next for providers that join a message's text blocks.
		if (attachment.kind === "text") blocks.push({ type: "text", text: `${ATTACHMENT_HEADER}${attachment.name}\n\n${attachment.text}${attachment.text.endsWith("\n") ? "" : "\n"}` });
	}
	for (const attachment of attachments) {
		if (attachment.kind === "image") blocks.push({ type: "image", data: attachment.data, mimeType: attachment.mimeType });
	}
	return blocks;
}

/** What the transcript keeps of a message with attachments. */
export function userEntryData(text: string, attachments: readonly Attachment[]): UserEntryData {
	return {
		// Nothing typed is recorded as nothing, not as the spaces or line breaks the text field held.
		text: text.trim() === "" ? "" : text,
		attachments: attachments.map((attachment) => ({
			name: attachment.name,
			kind: attachment.kind,
			size: attachment.kind === "image" ? decodedSize(attachment.data) : Buffer.byteLength(attachment.text, "utf8"),
		})),
	};
}

/** Read back what `userEntryData` recorded, from an entry or a queued input; undefined for anything else. */
export function readUserEntryData(entry: { kind?: unknown; data?: unknown } | undefined): UserEntryData | undefined {
	if (entry?.kind !== USER_ENTRY_KIND) return undefined;
	const data = entry.data as { text?: unknown; attachments?: unknown } | undefined;
	if (typeof data?.text !== "string" || !Array.isArray(data.attachments)) return undefined;
	const attachments = (data.attachments as Partial<AttachmentNote>[]).flatMap((note): AttachmentNote[] =>
		typeof note?.name === "string" && (note.kind === "image" || note.kind === "text") && typeof note.size === "number" ? [{ name: note.name, kind: note.kind, size: note.size }] : [],
	);
	return { text: data.text, attachments };
}

/** One line naming a message's attachments, for an export; undefined when it has none. */
export function describeAttachments(attachments: readonly AttachmentNote[], images: number): string | undefined {
	if (attachments.length > 0) return `Attached: ${attachments.map((note) => `${note.name} (${note.kind === "image" ? "picture" : "text"}, ${sizeText(note.size)})`).join("; ")}`;
	// Pictures that came without a record of their names.
	return images > 0 ? `Attached: ${images} picture${images === 1 ? "" : "s"}` : undefined;
}
