// Code mode: the `codemode` tool, which runs a script that calls the conversation's tools, and what the model is told
// about it (issue #163).
//
// pi durable's extension comes with a `codemode` prompt section that declares, in TypeScript, every tool a script can
// call, up to about 3,000 tokens of them. It is made for a model that is given few tools directly and reaches the rest
// through scripts. pi² gives a conversation every one of its tools directly, so the section said again what the tool
// definitions already say, and it was more than half of a conversation's system prompt, in conversations without code
// mode too. Here the section is cut to what the tool definitions do not say: that scripts call the same tools by the
// same names and arguments, which of them resolve to an object rather than text, and how to find and describe them.
// A tool a script can call that the model was not given directly is still declared in full, by the library's own
// section, as before. A tool pi durable defers (none in pi² so far) stays out of the section, as before: it is found
// with `searchTools()`. Scripts themselves are unchanged: they get every callable tool, and `ALL_TOOLS`,
// `searchTools()` and `describeTool()` answer from all of them, whatever the section shows.

import type { Context } from "@earendil-works/chord/context";
import type { CodemodeJsonSchema } from "@earendil-works/pi-codemode";
import { renderToolOutputType, toCodemodeIdentifier } from "@earendil-works/pi-codemode/declarations";
import { defineExtension, type Extension, type PromptInput, type PromptSection, type ToolRegistration } from "@earendil-works/pi-durable";
import { CODEMODE_TOOL_NAME, type CodemodeToolOptions, createCodemodeExtension } from "@earendil-works/pi-durable/codemode";

/** The library's tools for `models.*`, which scripts reach only through those globals (its `CODEMODE_INTERNAL_PREFIX`). */
const INTERNAL_PREFIX = "pi.codemode.";

/** The first line of the library's section, which the fuller listing keeps the rest of. */
const LIBRARY_HEADING = "Tools scripts can call (`await tools.<name>(args)`):";

// The library's description of the tool, but for the two places that say the section lists the tools.
const DESCRIPTION_CHANGES: [string, string][] = [
	["find tools the `codemode` section does not list.", "list, find and describe the tools scripts can call."],
	[
		"The `codemode` section of the system prompt lists the tools scripts can call, by namespace, as far as space allows.",
		"The `codemode` section of the system prompt says which tools scripts can call.",
	],
];

function describe(description: string): string {
	return DESCRIPTION_CHANGES.reduce((text, [from, to]) => text.replace(from, to), description);
}

/** What a call to `tool` resolves to, on one line: `{ exitCode: number; output: string; }`. */
function resultType(tool: ToolRegistration): string {
	return renderToolOutputType(tool.structuredOutputSchema as CodemodeJsonSchema)
		.split("\n")
		.filter((line) => !line.trim().startsWith("//"))
		.map((line) => line.trim())
		.join(" ");
}

/**
 * The few lines for tools the model was given directly: no declarations, since the tool definitions have them. Says
 * which tools resolve to an object, which a definition does not say, and the names a script uses that differ.
 */
function shortSection(given: readonly ToolRegistration[]): string {
	const lines = ["Scripts can call your other tools, by the same names and with the same arguments, as `await tools.<name>(args)`."];
	const renamed = given.filter((tool) => toCodemodeIdentifier(tool.name) !== tool.name);
	if (renamed.length > 0) lines.push(`In a script, ${renamed.map((tool) => `\`${tool.name}\` is \`tools.${toCodemodeIdentifier(tool.name)}\``).join(", ")}.`);
	const structured = given.filter((tool) => tool.structuredOutputSchema !== undefined);
	if (structured.length === 0) lines.push("Each call resolves to the tool's text output, as a string.");
	else {
		lines.push("Each call resolves to the tool's text output, as a string, except:");
		for (const tool of structured) lines.push(`- \`tools.${toCodemodeIdentifier(tool.name)}()\`: \`${resultType(tool)}\``);
	}
	lines.push("`ALL_TOOLS` lists every tool a script can call, `searchTools(query)` finds them by topic, and `describeTool(name)` gives a tool's declaration.");
	return lines.join("\n");
}

async function render(library: PromptSection, input: PromptInput, context: Context): Promise<string | undefined> {
	// Without the tool there is nothing to say: the section went into every conversation before.
	if (!input.agent.tools.some((tool) => tool.name === CODEMODE_TOOL_NAME)) return undefined;
	const offered = new Set(input.agent.tools.map((tool) => tool.name));
	// What the library's section is made from: deferred tools are left to `searchTools()`.
	const scriptable = input.agent.callable.filter((tool) => !tool.name.startsWith(INTERNAL_PREFIX) && tool.deferred !== true);
	if (scriptable.length === 0) return undefined;
	const given = scriptable.filter((tool) => offered.has(tool.name));
	const notGiven = scriptable.filter((tool) => !offered.has(tool.name));
	const parts = given.length === 0 ? [] : [shortSection(given)];
	if (notGiven.length > 0) {
		// The library's listing, of these tools only: their declarations, grouped and cut to its budget as before.
		const listing = await library.render({ ...input, agent: { ...input.agent, callable: notGiven } }, context);
		if (listing !== undefined) {
			const heading = given.length === 0 ? LIBRARY_HEADING : "Scripts can also call these tools, which you were not given directly (`await tools.<name>(args)`):";
			parts.push(listing.startsWith(LIBRARY_HEADING) ? heading + listing.slice(LIBRARY_HEADING.length) : listing);
		}
	}
	return parts.length === 0 ? undefined : parts.join("\n\n");
}

/** pi durable's code mode extension, with its section cut down and the tool's description to match. */
export function codemodeExtension(options: CodemodeToolOptions): Extension {
	const library = createCodemodeExtension(options);
	return defineExtension({
		...library,
		tools: library.tools?.map((tool) => (tool.name === CODEMODE_TOOL_NAME ? { ...tool, description: describe(tool.description) } : tool)),
		sections: library.sections?.map((section) => (section.key === "codemode" ? { ...section, render: (input, context) => render(section, input, context) } : section)),
	});
}
