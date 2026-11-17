// Every section of the system prompt keeps its place in a conversation, so one that comes or goes changes only itself.
//
// pi durable sends a conversation's prompt once, at its first request, and after that only what changed: a section
// whose text changed is sent again under its name, and one that went is named as removed. A section that is new is
// added at the end. When that would leave the sections in another order than the agent declares them, it removes every
// section and sends them all again instead (harness/prompt.js), which puts the whole prompt in the middle of the
// conversation for every later turn to carry, and starts the prompt cache again from there (#186). The agent's own
// instructions are always declared last, under a key no extension may use, so in a conversation whose agent has
// instructions, any section arriving after the first request would be out of order, wherever it was declared.
//
// So a section with nothing to say renders as empty instead of being left out, and keeps its place: an empty section
// is not sent at all (pi-ai joins only the parts that have text), and when it has something to say its text changes in
// place, which is sent as that one section. It tags its own text, since a section's tag would wrap the empty text too.
//
// A section is only given an empty place where that moves nothing: in a conversation's first request, or where it is
// already shown. A conversation from before this, sent its prompt without the section, has the whole prompt sent once
// more when the section first has something to say, as before, and keeps its place from then on; making room for it at
// once would send the whole prompt to every such conversation at its next message, whether the section ever came or not.

import type { Extension, PromptSection } from "@earendil-works/pi-durable";

export function holdingPlace<S extends PromptSection>(section: S): S {
	return {
		...section,
		tag: false,
		render: async (input, context) => {
			const text = await section.render(input, context);
			if (text !== undefined) return section.tag === false ? text : `<${section.key}>\n${text}\n</${section.key}>`;
			const shown = Object.keys(input.shown);
			return shown.length === 0 || shown.includes(section.key) ? "" : undefined;
		},
	};
}

/** `extension` with each of its sections keeping its place. */
export function holdingPlaces<E extends Extension>(extension: E): E {
	return extension.sections === undefined ? extension : { ...extension, sections: extension.sections.map(holdingPlace) };
}
