// A model that cannot see pictures can have one looked at by a model that can (#540).
//
// Some strong models take only text. A conversation on such a model is offered the `look` tool only when the person has
// named a model that takes pictures (Settings, "Model that looks at pictures"; `lookModel` in settings.json, None by
// default, kept the way the picture-making model is): the tool sends the picture files — the same ones `read` opens,
// read by `read` itself, so their reach and size limits are its — with the agent's question to that model in one
// request, and gives the answer back as text. What it spends is counted for the conversation and shown in Usage under
// the model that looked, as picture making is (#339, src/pictures.ts).
//
// Where a picture would have been given to a model that cannot see, it is told so in one line, and the picture's bytes
// are kept out of its request: `read` on a picture says so in place of the picture (this file wraps `read`, applied
// after reading.ts's own wrap), and computer use and the browser say so beside the controls and the page's text they
// give such a model today (extensions.ts, `lookOffered`). A model that can see, or no named model, changes nothing: the
// tool is offered to no one and the prompt is the same, byte for byte.
//
// See docs/pictures.md.

import type { Context } from "@earendil-works/chord/context";
import type { Api, Model, Usage } from "@earendil-works/pi-ai";
import { defineTool, type ToolRegistration, wrapTool } from "@earendil-works/pi-durable";
import { createNodePhotonImages } from "@earendil-works/pi-durable/images/node";
import { createReadTool } from "@earendil-works/pi-durable/tools";
import { arr, obj, opt, str } from "@earendil-works/pi-schema";
import type { Host } from "./extensions.ts";
import type { Engine, Feature } from "./features.ts";
import { headerOf } from "./reading.ts";
import type { Access, AgentProfile, ModelRef } from "./state.ts";

type SeesModel = Model<Api>;
type Block = { type: "text"; text: string } | { type: "image"; data: string; mimeType: string };

const key = (model: SeesModel) => `${model.provider}/${model.id}`;
const priced = (model: SeesModel) => model.cost.input + model.cost.output > 0;
const matches = (model: SeesModel, choice: ModelRef | null) => choice !== null && model.provider === choice.provider && model.id === choice.modelId;

// Keep the price status from the time of the request, not what a refreshed catalog says about past spend.
const KNOWN = "look:priced/";
const UNKNOWN = "look:unpriced/";

export function lookUsageModel(bucket: string): { key: string; unpriced: boolean } | undefined {
	if (bucket.startsWith(KNOWN)) return { key: bucket.slice(KNOWN.length), unpriced: false };
	if (bucket.startsWith(UNKNOWN)) return { key: bucket.slice(UNKNOWN.length), unpriced: true };
	return undefined;
}

/** Whether the model `ref` names takes pictures. One pi² cannot find counts as one that does, so nothing changes for it. */
export function seesPictures(engine: Engine, ref: ModelRef | null | undefined): boolean {
	if (ref === undefined || ref === null) return true;
	const model = engine.providers().models.getModel(ref.provider, ref.modelId);
	return model === undefined ? true : model.input.includes("image");
}

/** The sentence pi durable's `read` adds when the model cannot see pictures; the line this feature puts in its place says it instead. */
const PLACEHOLDER = "The current model does not support images; it sees a placeholder instead.";

/** What a model that cannot see pictures is told where one would have been given to it, in one line. */
export function cannotSeeLine(path: string, offered: boolean): string {
	const what = `You cannot see pictures: ${path} is one.`;
	return offered ? `${what} Ask about it with look.` : what;
}

/** The most pictures one look call sends; `read` shows at most as many (reading.ts). */
const MAX_PICTURES = 5;

/** What the model that looks is told once, before the question: answer exactly, and never guess. */
const INSTRUCTION =
	"You are looking at pictures for another model that cannot see them. Answer exactly what is asked. Say what you cannot make out. Do not guess at text you cannot read.";

const DESCRIPTION =
	"Have a model that can see pictures answer a question about one or more picture files, and give its answer back as text. Your own model cannot see them. " +
	"`path` is one picture file, or `paths` several (jpg, png, gif, webp, bmp), relative to the conversation's folder or absolute: only what read could read, with its size limits. " +
	'`question` is what to ask, such as "Is any text cut off or overlapping?". Each picture is sent to the provider of the model that looks, and costs money on the person\'s account; ask about several pictures in one call rather than one call each.';

export const pictureLook: Feature = (host: Host, engine: Engine) => {
	/** The models the person's connected providers offer that take pictures, as of the last look. */
	let available: readonly SeesModel[] = [];
	/** The read tool `look` opens pictures with, with the image preparation the conversation's own `read` uses. */
	let read: ToolRegistration | undefined;

	const chosen = () => {
		const choice = engine.lookModel();
		if (choice === null) return undefined;
		return available.find((model) => matches(model, choice));
	};

	const event = () => ({
		event: "look",
		model: engine.lookModel(),
		models: available.map((model) => ({
			provider: model.provider,
			id: model.id,
			name: model.name,
			providerName: engine.providers().models.getProvider(model.provider)?.name ?? model.provider,
			price: priced(model) ? { input: model.cost.input, output: model.cost.output } : null,
		})),
	});

	/** The models the person's providers can use, as of the last look: at start and whenever a provider changes. */
	const look = async (): Promise<void> => {
		const before = event();
		available = (await engine.providers().models.getAvailable().catch(() => [])).filter((model) => model.input.includes("image"));
		const after = event();
		if (JSON.stringify(after) !== JSON.stringify(before)) engine.broadcast(after);
	};

	/** Whether `look` is offered to a conversation on the model `ref` just now: it cannot see pictures, and a model that can is chosen. */
	const offeredFor = (ref: ModelRef | null | undefined): boolean => ref !== undefined && ref !== null && !seesPictures(engine, ref) && chosen() !== undefined;

	// What the computer and browser tools add where they would have given a picture (extensions.ts).
	host.lookOffered = (_conversationId, model) => offeredFor(model);

	const tool = defineTool({
		name: "look",
		description: DESCRIPTION,
		parameters: obj({
			path: opt(str({ description: "Path to the picture file to look at, relative to the conversation's folder or absolute" })),
			paths: opt(arr(str({ description: `Several paths, in this order (at most ${MAX_PICTURES}); instead of \`path\`` }))),
			question: str({ description: "What to ask about the picture" }),
		}),
		// A call cut off by a crash may have asked the model, and paid for it: it is not asked again.
		replay: "unsafe",
		execute: async (args, api, context: Context) => {
			const refuse = (text: string) => ({ output: [{ type: "text" as const, text }], isError: true });
			const question = (args.question ?? "").trim();
			if (question === "") return refuse("look needs `question`: say what to ask about the picture.");
			const paths = (typeof args.path === "string" ? [args.path] : args.paths ?? []).map((path) => String(path).trim()).filter((path) => path !== "");
			if (paths.length === 0) return refuse("Give `path`, or `paths` with the picture files to look at.");
			if (paths.length > MAX_PICTURES) return refuse(`One call looks at at most ${MAX_PICTURES} pictures. Look at the rest in another call.`);
			const model = chosen();
			if (model === undefined) {
				return refuse(
					engine.lookModel() === null
						? "No model that looks at pictures is chosen. Ask the person to pick one in Settings, beside the picture model."
						: "The model that looks at pictures is no longer available. Ask the person to pick another in Settings.",
				);
			}
			// `read` itself opens each file, so look reaches only what it could read, with its kinds and size limits.
			const opener = read ?? createReadTool();
			const pictures: { path: string; data: string; mimeType: string }[] = [];
			const notes: string[] = [];
			for (const path of paths) {
				try {
					context.abortSignal?.throwIfAborted();
					const result = await opener.execute({ path }, api as never, context);
					const picture = (result.output ?? []).find((block): block is { type: "image"; data: string; mimeType: string } => block.type === "image");
					if (result.isError) notes.push(`${path}: ${(result.diagnostics ?? []).map((note) => note.message).join(" ") || "it could not be read."}`);
					else if (picture !== undefined) pictures.push({ path, data: picture.data, mimeType: picture.mimeType });
					else notes.push(`${path}: it is not a picture, so there is nothing to look at.`);
				} catch (error) {
					if (context.abortSignal?.aborted) throw error;
					notes.push(`${path}: ${(error as Error).message}`);
				}
			}
			if (pictures.length === 0) return refuse(`No picture could be read.\n${notes.join("\n")}`);
			const content: Block[] = [
				{ type: "text", text: `Question: ${question}\n\nThe pictures follow, in this order: ${pictures.map((picture) => picture.path).join(", ")}.` },
				...pictures.map((picture) => ({ type: "image" as const, data: picture.data, mimeType: picture.mimeType })),
			];
			const answer = await api.models.complete(model, { systemPrompt: INSTRUCTION, messages: [{ role: "user", content, timestamp: Date.now() }] }, context.abortSignal === undefined ? {} : { signal: context.abortSignal });
			const said = answer.content.flatMap((block) => (block.type === "text" && block.text.trim() !== "" ? [block.text.trim()] : [])).join("\n");
			const usage: { usage: Usage; usageKey: string } = {
				// An answer without counters still belongs in Usage, but not with an apparent price of zero.
				usage: answer.usage ?? { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
				usageKey: `${priced(model) ? KNOWN : UNKNOWN}${key(model)}`,
			};
			const details = { model: key(model), modelName: model.name, pictures: pictures.length };
			if (answer.stopReason !== "stop") {
				return { ...refuse(`${model.name} could not look at the picture: ${answer.errorMessage ?? answer.stopReason}`), details, ...usage };
			}
			if (said.trim() === "") return { ...refuse(`${model.name} answered without any text.`), details, ...usage };
			const cut = said.length > 4000;
			const text =
				`${model.name} looked at ${pictures.length === 1 ? "the picture" : `${pictures.length} pictures`} and answered:\n\n${cut ? said.slice(0, 4000) : said}${cut ? "\n\n(The answer was cut short here.)" : ""}` +
				`${notes.length > 0 ? `\n\n(Not read: ${notes.join(" ")})` : ""}`;
			return { output: [{ type: "text", text }], details, ...usage };
		},
	});

	/** What a model that cannot see pictures is given instead of a picture `read` opened: the line, never the bytes. */
	const holdingRead = wrapTool(createReadTool(), (read) => {
		const wrapped: ToolRegistration = {
			...(read as ToolRegistration),
			execute: async (given, api, context) => {
				const result = await read.execute(given as never, api as never, context);
				const ref = (await api.agent(context)).model;
				if (ref === undefined || ref === null || seesPictures(engine, ref)) return result;
				const output = result.output ?? [];
				if (!output.some((block) => block.type === "image")) return result;
				const offered = chosen() !== undefined;
				const args = given as { path?: string; files?: { path: string }[] };
				const entries = typeof args.path === "string" ? [args.path] : (args.files ?? []).map((file) => file.path);
				// The files form puts a "==> path <==" line before each file's part; a picture belongs to the last one named.
				let at = -1;
				const held = output.map((block) => {
					if (block.type === "image") {
						const path = entries[Math.max(at, 0)] ?? "the file";
						return { type: "text" as const, text: `${cannotSeeLine(path, offered)}\n` };
					}
					if (block.type === "text" && at + 1 < entries.length && block.text.includes(headerOf({ path: entries[at + 1]! }))) at++;
					return block;
				});
				return {
					...result,
					// The note about a placeholder said the model sees one; the line that replaces the picture says what it sees.
					output: held.map((block) => (block.type === "text" && block.text.includes(PLACEHOLDER) ? { ...block, text: block.text.replace(PLACEHOLDER, "").trim() } : block)),
					diagnostics: (result.diagnostics ?? []).map((note) => (note.message.includes(PLACEHOLDER) ? { ...note, message: note.message.replace(PLACEHOLDER, "").trim() } : note)),
				};
			},
		};
		return wrapped as unknown as typeof read;
	});

	return {
		tools: [tool],
		wraps: [holdingRead],
		handlers: {
			"look.setModel": async ({ model }) => {
				const given = model as Partial<ModelRef> | null | undefined;
				if (given === null) engine.setLookModel(null);
				else {
					if (typeof given?.provider !== "string" || typeof given.modelId !== "string") throw new Error("Choose a model that looks at pictures, or None.");
					const choice = { provider: given.provider, modelId: given.modelId };
					if (!available.some((candidate) => matches(candidate, choice)))
						throw new Error("That model cannot look at pictures: it is not offered by your connected providers, or it does not take pictures. Choose another, or None.");
					engine.setLookModel(choice);
				}
				const changed = event();
				engine.broadcast(changed);
				return { model: changed.model };
			},
		},
		toolNames: (access: Access, _agent: AgentProfile | undefined, where: { model?: ModelRef | null }) =>
			access === "none" || !offeredFor(where.model) ? [] : ["look"],
		start: async () => {
			// The same image preparation the conversation's `read` uses: BMP is converted and a large picture shrunk, not refused.
			read = createReadTool({ images: await createNodePhotonImages() });
			await look();
		},
		providersChanged: () => void look().catch((error) => engine.log("look: could not list the models that take pictures:", error instanceof Error ? error.message : error)),
		greeting: () => [event()],
	};
};
