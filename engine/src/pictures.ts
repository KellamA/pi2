// Making pictures: `make_picture` asks one of the person's picture models for a picture and puts it in the
// conversation (#286).
//
// It is a built-in tool off by default (builtins.ts, key `pictures`): the chat assistant is given it, and an agent whose
// settings turn it on. It reaches the model the way code mode's `models.generateImages` does, through pi-ai's
// `Models.generateImages`, which finds the provider's key itself. Of pi-ai's providers, only OpenRouter has picture
// models, so it is offered only while one of the person's providers can make pictures (`withheld`): otherwise the tool
// is not offered at all, and a conversation that would have it is told why in a line of its own (the `pictures`
// section), so the model can say so when asked for a picture. The person reads the same in the agent's settings.
//
// A picture model's spend comes back with its pictures and is kept as the tool's usage (pi durable's `pi.usage.tools`),
// which the conversation's, the agent's and the day's totals count, and so the daily budget; it has no row of its own
// among the models in Usage. A model with no price in pi-ai's catalog counts tokens only.
//
// See docs/pictures.md.

import type { Context } from "@earendil-works/chord/context";
import type { ImageContent, ImageModel, ImagesInputContent } from "@earendil-works/pi-ai";
import { defineTool, section } from "@earendil-works/pi-durable";
import { bool, obj, opt, str } from "@earendil-works/pi-schema";
import type { Engine, Feature } from "./features.ts";
import { type AgentProfile, agentOf, type Meta } from "./state.ts";

// biome-ignore lint/suspicious/noExplicitAny: a picture model of any API
type PictureModel = ImageModel<any>;

/**
 * Picture models used first, when the person's providers have them: good at following a description, able to change a
 * picture they are given, and with a price in the catalog, so Usage counts what they cost.
 */
export const PREFERRED = ["google/gemini-3.1-flash-image", "google/gemini-2.5-flash-image", "openai/gpt-image-1-mini", "openai/gpt-5-image-mini"];

const key = (model: PictureModel) => `${model.provider}/${model.id}`;
const priced = (model: PictureModel) => model.cost.input + model.cost.output > 0;
const takesPictures = (model: PictureModel) => model.input.includes("image");

/** The model to ask, of those available: a preferred one, else one with a price, else the first. Only one that takes a picture, to change one. */
export function chooseModel(available: readonly PictureModel[], changing: boolean): PictureModel | undefined {
	const usable = changing ? available.filter(takesPictures) : [...available];
	for (const wanted of PREFERRED) {
		const found = usable.find((model) => key(model) === wanted);
		if (found !== undefined) return found;
	}
	return usable.find(priced) ?? usable[0];
}

/** The newest picture in conversation `id`, one the person attached or one made before: at most `entries` entries back. */
export async function newestPicture(engine: Engine, id: number, context: Context, entries = 400): Promise<ImageContent | undefined> {
	const conv = await engine.harness().conversation(id as never, context);
	if (conv === undefined) return undefined;
	let cursor: unknown;
	let seen = 0;
	while (seen < entries) {
		const page = await conv.entries({}, 50, cursor as never, context);
		for (const entry of page.items) {
			seen++;
			for (const message of [...((entry.model ?? []) as readonly { content?: unknown }[])].reverse()) {
				const blocks = Array.isArray(message.content) ? (message.content as { type?: string; data?: unknown; mimeType?: unknown }[]) : [];
				const picture = blocks.findLast((block) => block?.type === "image" && typeof block.data === "string" && typeof block.mimeType === "string");
				if (picture !== undefined) return { type: "image", data: picture.data as string, mimeType: picture.mimeType as string };
			}
		}
		if (page.next === undefined || page.items.length === 0) return undefined;
		cursor = page.next;
	}
	return undefined;
}

/** Whether a conversation with this record and agent would be offered pictures, with a picture model to be had. */
function wantsPictures(meta: Meta | undefined, agent: AgentProfile | undefined): boolean {
	return meta?.chat === true || (agent?.toolsOn ?? []).includes("pictures");
}

const DESCRIPTION =
	"Make a picture from a description, with one of the person's picture models, and show it to them in the conversation. " +
	"Describe what to show in plain words: subject, style, composition, colours, any text it should hold. " +
	"With `change`, the newest picture in this conversation (one the person attached, or one made before) is changed as the description says, rather than a new one made. " +
	"Each picture costs money on the person's account with the provider; make one at a time, and only when asked for a picture.";

export const pictures: Feature = (_host, engine) => {
	/** The picture models the person's providers can use, as of the last look: at start and whenever a provider changes. */
	let available: PictureModel[] = [];
	/** The providers whose catalogs have picture models at all, by name, for saying where to get one. */
	let makers: string[] = [];

	const look = async (): Promise<void> => {
		const models = engine.providers().models;
		const before = available.map(key).join(" ");
		available = (await models.getAvailableOfType("image").catch(() => [])) as PictureModel[];
		makers = [...new Set(models.getModelsOfType("image").map((model) => model.provider))].map((id) => models.getProvider(id)?.name ?? id).filter((name) => name !== "Demo");
		if (available.map(key).join(" ") !== before) engine.broadcast(event());
	};
	const event = () => ({ event: "pictures", models: available.map((model) => ({ provider: model.provider, id: model.id, name: model.name })), makers });

	/** What the model is told when it would have the tool but cannot: no provider of the person's has a picture model. */
	const none = () =>
		`You cannot make pictures here: none of the person's providers has a model that makes them${makers.length === 0 ? "" : ` (${makers.join(" and ")} ${makers.length === 1 ? "has" : "have"} them; the person can add a key in Settings › Providers)`}. If they ask for a picture, say so plainly.`;

	const tool = defineTool({
		name: "make_picture",
		description: DESCRIPTION,
		parameters: obj({
			description: str({ description: "What the picture shows, in plain words" }),
			change: opt(bool({ description: "Change the newest picture in this conversation instead of making a new one" })),
		}),
		// A call cut off by a crash may have made its picture, and paid for it: it is not made again.
		replay: "unsafe",
		execute: async (args, api, context: Context) => {
			const refuse = (text: string) => ({ output: [{ type: "text" as const, text }], isError: true });
			const changing = args.change === true;
			if (args.description.trim() === "") return refuse("description is empty: say what the picture should show.");
			if (available.length === 0) await look();
			const model = chooseModel(available, changing);
			if (model === undefined) return refuse(available.length === 0 ? none() : "None of the person's picture models can change a picture they are given; make a new one instead.");
			const input: ImagesInputContent[] = [{ type: "text", text: args.description }];
			if (changing) {
				const picture = await newestPicture(engine, api.conversationId as unknown as number, context);
				if (picture === undefined) return refuse("There is no picture in this conversation to change. Make a new one, or ask the person to attach the picture.");
				input.push(picture);
			}
			const result = await api.models.generateImages(model, { input }, context.abortSignal === undefined ? {} : { signal: context.abortSignal });
			const usage = result.usage === undefined ? {} : { usage: result.usage };
			const made = result.output.filter((block): block is ImageContent => block.type === "image");
			const said = result.output.flatMap((block) => (block.type === "text" && block.text.trim() !== "" ? [block.text.trim()] : []));
			const details = { model: key(model), modelName: model.name, pictures: made.length, changed: changing };
			if (result.stopReason !== "stop") {
				return { ...refuse(`${model.name} could not make the picture: ${result.errorMessage ?? result.stopReason}`), details, ...usage };
			}
			if (made.length === 0) {
				return { ...refuse(`${model.name} answered without a picture${said.length === 0 ? "." : `: ${said.join(" ").slice(0, 1000)}`}`), details, ...usage };
			}
			const note = `${changing ? "Changed the picture" : made.length === 1 ? "Made a picture" : `Made ${made.length} pictures`} with ${model.name}. The person sees ${made.length === 1 ? "it" : "them"} in the conversation.`;
			const text = said.length === 0 ? note : `${note}\n${model.name} said: ${said.join(" ").slice(0, 2000)}`;
			return { output: [{ type: "text", text }, ...made], details, ...usage };
		},
	});

	return {
		tools: [tool],
		toolNames: () => ["make_picture"],
		withheld: () => (available.length === 0 ? ["make_picture"] : []),
		sections: [
			section("pictures", (input) => {
				if (available.length > 0) return undefined;
				const meta = engine.library().conversations[String(input.conversationId)];
				return wantsPictures(meta, agentOf(meta, engine.agents())) ? none() : undefined;
			}),
		],
		start: look,
		providersChanged: () => void look().catch((error) => engine.log("pictures: could not list the picture models:", error instanceof Error ? error.message : error)),
		greeting: () => [event()],
	};
};
