// A model sometimes sends an argument that should be an array or an object as a JSON string of it (issue #572): the
// schema is right and the model is wrong, but refusing costs a turn and teaches the model to go round the tool. The
// string is read as the value it encodes before the arguments are checked against the schema, in one place for every
// tool, driven by each tool's own schema (`edit`'s `edits`, `read`'s `files`, `update_plan`'s `items`, `sub_chats`'s
// `chats` and the like). Only an argument whose schema says array or object, and only a string that parses as JSON of
// that kind; everything else is as today, and a string that does not parse, or parses to the wrong kind, is refused
// with the usual message.
//
// Where: pi durable checks a call's arguments in its tool task, before any tool runs and before a wrap could see them,
// but it repairs them first through `prepareArguments`, which runs before the check. Every tool passes through one such
// place already — the engine's `conversationAgent` (main.ts), applied to each conversation's resolved tools before
// every call — so the reading is added there, and the same place serves the MCP servers' tools: the reading asks each
// tool's own schema and only widens what would have been refused, so nothing that works today changes.

import { AgentDoc, hook, ToolTask } from "@earendil-works/pi-durable";
import type { ToolRegistration } from "@earendil-works/pi-durable";
import type { Feature } from "./features.ts";

/** A schema whose own `type` says what it is; anything more loosely said (a union, a `$ref`) reads as unknown. */
const schemaOf = (schema: unknown): { type?: unknown; properties?: unknown } | undefined =>
	schema !== null && typeof schema === "object" && !Array.isArray(schema) ? (schema as { type?: unknown; properties?: unknown }) : undefined;

/**
 * The arguments with every one the tool's schema says is an array or an object, and whose value is a string that
 * parses as JSON of that kind, read as the value it encodes; `undefined` when there is nothing to read. Pure: the
 * caller decides what to do with it (pi durable asks as much of `prepareArguments`, which runs again when a call is
 * retried). Only the schema's own word counts, so a union that allows a string, and an MCP tool's `$ref`, are left to
 * the check, which refuses them as today. A string is never touched where a string is wanted, whatever it holds.
 */
export function readStringified(parameters: object | undefined, args: unknown): { value: Record<string, unknown>; names: string[] } | undefined {
	if (args === null || typeof args !== "object" || Array.isArray(args)) return undefined;
	const properties = schemaOf(parameters)?.properties;
	if (properties === undefined || properties === null || typeof properties !== "object" || Array.isArray(properties)) return undefined;
	let value: Record<string, unknown> | undefined;
	const names: string[] = [];
	for (const [name, schema] of Object.entries(properties)) {
		const type = schemaOf(schema)?.type;
		if (type !== "array" && type !== "object") continue;
		const sent = (args as Record<string, unknown>)[name];
		if (typeof sent !== "string") continue;
		let parsed: unknown;
		try {
			parsed = JSON.parse(sent);
		} catch {
			// Not JSON: leave it for the check, which refuses it with its usual message.
			continue;
		}
		const right = type === "array" ? Array.isArray(parsed) : parsed !== null && typeof parsed === "object" && !Array.isArray(parsed);
		if (!right) continue;
		value ??= { ...(args as Record<string, unknown>) };
		value[name] = parsed;
		names.push(name);
	}
	return value === undefined ? undefined : { value, names };
}

/**
 * Each conversation's tools' parameter schemas as the engine last resolved them. The notice below re-runs the same
 * check on the arguments as the model sent them, which the repair itself cannot report: `prepareArguments` is pure and
 * knows neither the call nor anything it may tell. Only references are kept, and cleared wholesale once a few hundred
 * conversations have passed through: any one of them is filled again by its next resolution, which precedes every
 * call in it.
 */
const schemas = new Map<string, Map<string, object>>();

/**
 * The tool with the reading added as `prepareArguments`, which pi durable runs before it checks the call's arguments
 * against the schema. The tool's own repair, if it has one, runs after the reading, on what it expects: `edit`'s and
 * `read`'s already read some of these strings themselves. `conversationId` is the conversation whose tools are being
 * resolved (main.ts, `conversationAgent`), for the schema the notice below reads back.
 */
export function preparedTool<Tool extends ToolRegistration>(conversationId: number | string, tool: Tool): Tool {
	if (schemas.size > 400) schemas.clear();
	let ofConversation = schemas.get(String(conversationId));
	if (ofConversation === undefined) {
		ofConversation = new Map();
		schemas.set(String(conversationId), ofConversation);
	}
	ofConversation.set(tool.name, tool.parameters);
	const own = tool.prepareArguments;
	return {
		...tool,
		prepareArguments: (args: unknown) => {
			const read = readStringified(tool.parameters, args);
			const value = read === undefined ? args : read.value;
			// A repair that throws refuses the call with its own message; the reading never throws, so a string it
			// leaves alone is refused by the check, with the check's own words, exactly as before.
			return own === undefined ? (value as never) : (own(value as never) as never);
		},
	} as Tool;
}

/** The one line the model is told, before the tool's own result. */
const told = (names: readonly string[]): string => {
	const list = names.map((name) => `\`${name}\``).join(names.length === 2 ? " and " : ", ");
	const one = names.length === 1;
	return `${list} ${one ? "was sent as a JSON string and read as the value it encodes. Send the value itself next time, not a string of it." : "were sent as JSON strings and read as the values they encode. Send the values themselves next time, not strings of them."}`;
};

/**
 * When the reading happened, the call's result says so: the model is told in one line before the tool's own result,
 * the row says it in a few words for the person (`details.stringArguments`, the app shows it as it shows an allowed
 * command), and the engine's log names the tool, the conversation and the model, so it can be counted, by model.
 * `afterTool` sees the call with the arguments as the model sent them, so the same pure check answers whether the
 * reading fired — without the repair having to say so itself.
 */
export const stringArguments: Feature = (_host, engine) => ({
	hooks: [
		hook(ToolTask, {
			afterTool: async (call, result, api, context) => {
				const names = readStringified(schemas.get(String(api.conversationId))?.get(call.name), call.arguments)?.names;
				if (names === undefined || names.length === 0) return undefined;
				const model = (await api.snapshot(AgentDoc, api.conversationId, context))?.model;
				engine.log(
					`${call.name}'s ${names.join(", ")} arrived as a JSON string and was read as the value it encodes`,
					`(conversation ${api.conversationId}${model === undefined ? "" : `, model ${model.provider}/${model.modelId}`})`,
				);
				const details =
					result.details !== null && typeof result.details === "object" && !Array.isArray(result.details)
						? { ...(result.details as Record<string, unknown>) }
						: {};
				details.stringArguments = names;
				return {
					...result,
					output: [{ type: "text" as const, text: `${told(names)}\n` }, ...(result.output ?? [])],
					details: details as typeof result.details,
				};
			},
		}),
	],
});
