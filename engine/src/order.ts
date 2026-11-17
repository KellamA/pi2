// The order of the tool calls in one answer (issues #145, #129).
//
// pi durable starts the calls a model makes in one answer together, unless one of them is to a tool marked
// `executionMode: "sequential"`, which makes the whole round run one call at a time, in the order the model gave. A model
// that writes a file and uses it in the same answer (a `bash` that takes a screen capture and a `read` of the picture, a
// `bash` that writes a script and a `bash` with `background: true` that runs it) then had the second call start before
// the first had written anything: "No such file or directory", or the old contents of a file being changed, and the
// file there a moment later. Nothing told the model the calls ran side by side.
//
// So a round that has a call to a tool that changes files runs in order: each call sees what the ones before it did.
// Rounds of calls that only look (reads, searches, web pages) and rounds of sub-chats still run side by side, which is
// where running together saves real time. The tools' descriptions say both, so a model puts a call that needs another's
// result after it, or in a later answer.

import type { ToolRegistration, Wrap } from "@earendil-works/pi-durable";
import type { Feature } from "./features.ts";

/** Tools that change files, by name: any one of them in an answer makes its calls run in order. */
export const IN_ORDER = ["bash", "write", "edit", "write_document", "codemode"] as const;

/** What a model is told, after the description of each tool it most often writes a file with and uses one with. */
export const ORDER_NOTE =
	`Calls you make in one answer run one at a time, in the order you give them, when any of them is ${IN_ORDER.slice(0, -1).join(", ")} or ${IN_ORDER.at(-1)}, ` +
	"so each sees what the calls before it did. Otherwise they start together, so a call that needs another's result (a file a sub-chat writes, say) belongs in a later answer.";

/** The tools whose descriptions carry the note. */
const TOLD = new Set(["bash", "write", "edit", "read"]);

// Wraps by name, as `wrapTool` makes them, without a copy of each tool to name it by. The tool a wrap is given is
// whichever won, with the wraps of features listed before this one applied (bash's time limit, in commands.ts), so this
// adds to what those made of it.
const wraps: Wrap<ToolRegistration>[] = [...new Set<string>([...IN_ORDER, ...TOLD])].map((name) => ({
	tool: name,
	wrap: (tool: ToolRegistration) => ({
		...tool,
		...((IN_ORDER as readonly string[]).includes(name) ? { executionMode: "sequential" as const } : {}),
		...(TOLD.has(name) ? { description: `${tool.description} ${ORDER_NOTE}` } : {}),
	}),
}));

export const order: Feature = () => ({ wraps });
