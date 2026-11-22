// A section of the system prompt that changes mid-conversation reaches every model where it changed (#629).
//
// pi durable sends a conversation's prompt once and then only what changed, as a later system message: a section whose
// text changed, under its name (the background commands, as one starts and as it ends, most often). pi-ai sends that
// message where it is only to a model whose `compat.supportsMidConvoSystemMessages` is set (Anthropic's own models and
// Codex, the models on this Mac); for any other, and always for Google's and Bedrock's APIs, it folds every later system
// message back into the first. The start of the prompt then changes at each change, and a prompt cache keeps nothing
// from there: the whole conversation is read, and paid for, as new. That was DeepSeek on OpenRouter, GLM and DeepSeek on
// OpenCode Go, 391 of OpenRouter's 403 models, and every endpoint of one's own (llama.cpp, LM Studio, Ollama, vLLM).
// Turning the flag on for them is no answer: many chat templates refuse a system message that is not first.
//
// So for such a model pi² sends the change itself, where it happened, as what every model and template takes: text in a
// user message whose first line says it is from pi², not the person, and asks for no answer, much as Strata's server does
// with a later system message for the model on this Mac (#606). The first system message is then the same at every
// request, byte for byte, and only what comes after the change is new to the provider.
//
// - Where: right after the message it follows. pi durable writes a change just before a request, after the person's
//   message or the tool results it answers. After the person's message it joins that message, so that no provider or
//   template that wants turns to alternate (DeepSeek's reasoner, some local templates) sees two user messages in a row;
//   after tool results it is a user message of its own, as a message the person sends while tools run already is.
// - Only from what comes before it: what a message becomes never depends on a message after it, so a request that adds to
//   the conversation leaves everything the last one sent as it was.
// - Several changes in a row (the remove-all and re-add-all pair pi durable sends when the order would change) are one
//   note, with each section's last word.
// - Tools that change are left to pi-ai as they were, on a system message with nothing else: for these models they are
//   still folded into the tools at the top, so a change of tools still changes the prompt's start.
// - Models that take a later system message are sent it as before, and an API pi² does not know is left alone (the demo
//   model reads the system messages themselves).

import { contentText, type Message, type Model, type SystemMessage, type UserMessage } from "@earendil-works/pi-ai";
import { normalizeContext } from "@earendil-works/pi-ai/utils/transcript";

/** The first line of a change pi² sends as a user message: whose it is, and that it asks nothing. */
export const PROMPT_CHANGE_NOTE = "[pi², not the person: your system prompt has changed, as below. Follow it from now on; this note itself needs no answer.]";

/** APIs that send a later system message where it is only when the model's compat says it takes one. */
const UNLESS_SAID = new Set(["openai-completions", "openai-responses", "azure-openai-responses", "openai-codex-responses", "anthropic-messages", "mistral-conversations"]);
/** APIs that always fold later system messages into the first. */
const ALWAYS = new Set(["google-generative-ai", "google-vertex", "bedrock-converse-stream"]);

type AnyModel = Pick<Model<string>, "api"> & { compat?: unknown };

/** Whether pi-ai would fold a later system message into the first for `model`, changing the start of the prompt. */
export function foldsPromptChanges(model: AnyModel): boolean {
	if (ALWAYS.has(model.api)) return true;
	if (!UNLESS_SAID.has(model.api)) return false;
	return (model.compat as { supportsMidConvoSystemMessages?: boolean } | undefined)?.supportsMidConvoSystemMessages !== true;
}

function describe(name: string, text: string | null): string {
	if (text === null) return `Removed system prompt section "${name}".`;
	if (text === "") return `System prompt section "${name}" is now empty: what it said before no longer holds.`;
	return `Updated system prompt section "${name}":\n\n${text}`;
}

/**
 * `messages` with every system message after the first sent as text where it is: in the user message it follows, or in a
 * user message of its own. What each carried of tools stays, on a system message of its own. Nothing is changed in place.
 */
export function promptChangesInPlace(messages: readonly Message[]): Message[] {
	const first = messages.findIndex((message) => message.role === "system");
	if (first < 0 || !messages.some((message, index) => index > first && message.role === "system")) return [...messages];
	const out: Message[] = [];
	let texts: string[] = [];
	let sections = new Map<string, string | null>();
	let at = 0;
	const place = () => {
		const parts = [...texts, ...[...sections].map(([name, text]) => describe(name, text))];
		texts = [];
		sections = new Map();
		if (parts.length === 0) return;
		const note = [PROMPT_CHANGE_NOTE, ...parts].join("\n\n");
		// System messages are folded away for these models, so they do not stand between two messages.
		const before = out.findLastIndex((message) => message.role !== "system");
		const joined = before < 0 ? undefined : out[before];
		if (joined?.role === "user") {
			const content: UserMessage["content"] = typeof joined.content === "string" ? `${joined.content}\n\n${note}` : [...joined.content, { type: "text", text: note }];
			out[before] = { ...joined, content };
		} else {
			out.push({ role: "user", content: note, timestamp: at });
		}
	};
	for (const [index, message] of messages.entries()) {
		if (message.role !== "system" || index === first) {
			place();
			out.push(message);
			continue;
		}
		at = message.timestamp;
		const text = contentText(message.content);
		if (text.length > 0) texts.push(text);
		for (const [name, value] of Object.entries(message.sections ?? {})) sections.set(name, value);
		if ((message.toolsAdded?.length ?? 0) > 0 || (message.toolsRemoved?.length ?? 0) > 0) {
			const tools: SystemMessage = { role: "system", content: "", timestamp: message.timestamp };
			if (message.toolsAdded !== undefined) tools.toolsAdded = message.toolsAdded;
			if (message.toolsRemoved !== undefined) tools.toolsRemoved = message.toolsRemoved;
			out.push(tools);
		}
	}
	place();
	return out;
}

type Call = (model: AnyModel, context: never, options?: unknown) => unknown;

/** The models, unchanged except that a model that would fold a changed section into the first system message is sent it in place. */
export function placingPromptChanges<T extends object>(models: T): T {
	return new Proxy(models, {
		get(target, key) {
			const value = Reflect.get(target, key, target);
			if (typeof value !== "function") return value;
			const original = (value as Call).bind(target);
			if (key !== "stream" && key !== "streamSimple" && key !== "complete" && key !== "completeSimple") return original;
			return (model: AnyModel, context: Parameters<typeof normalizeContext>[0], options?: unknown) => {
				if (!foldsPromptChanges(model)) return original(model, context as never, options);
				// The prompt and tools given apart become the leading system message, as pi-ai would make it.
				const transcript = normalizeContext(context);
				return original(model, { messages: promptChangesInPlace(transcript.messages) } as never, options);
			};
		},
	});
}
