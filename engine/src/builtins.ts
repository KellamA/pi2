// Which of the built-in tools an agent is offered (#221).
//
// Every conversation with tools used to get the tools below, whatever its agent was for, and each one's definition (and
// the section of the system prompt that goes with it) is read again on every turn. A worker that only runs commands
// and edits files carried them all. An agent's settings list them, each on by default, and the person can leave some
// out: `toolsOff` on the agent holds the keys of those left out, so an agent saved before this, or a tool added after,
// is offered as before until the person changes it.
//
// Only tools no other switch governs are listed. The shell and the file tools (and `background`, which works the
// shell's background commands) follow the access level; computer use, the browser, scheduling, code mode, memory,
// reference files and handing work on have switches of their own. A tool listed here is still offered only where it
// was before (by access level, with the browser on): leaving it out only takes it away. A tool left out is gone from
// the conversation altogether, so from code mode's listing too, and a script cannot call it.
//
// A tool added for some agents only, such as the chat assistant's (#286), is off by default instead (`offByDefault`):
// `toolsOn` on the agent holds the keys of those it is given, so no agent that has not asked for one pays for it in
// its prompt.

import type { AgentProfile } from "./state.ts";

export type BuiltInTool = {
	/** What `toolsOff` holds. */
	key: string;
	/** The tools it stands for, by name. */
	tools: string[];
	/** What the person reads in the agent's settings: what it does, and what leaving it out means where that may surprise. */
	title: string;
	detail: string;
	/**
	 * Where it is offered at all: any access but none, Ask first or Full access, the browser on, one of the person's
	 * providers having a picture model (pictures.ts); anywhere when absent.
	 */
	needs?: "files" | "changes" | "browser" | "pictures";
	/** Off unless the agent's `toolsOn` names it; `toolsOff` names only the others. */
	offByDefault?: true;
};

/** In the order the settings show them. */
export const BUILT_IN_TOOLS: readonly BuiltInTool[] = [
	{
		key: "files",
		tools: ["list_files", "find_files", "search_files"],
		title: "List, find and search files",
		detail: "Lists a folder, finds files by name and searches their text, without the shell.",
		needs: "files",
	},
	{
		key: "documents",
		tools: ["write_document"],
		title: "Write documents",
		detail: "Writes a Word, RTF, OpenDocument or HTML file from Markdown.",
		needs: "changes",
	},
	{
		key: "ask",
		tools: ["ask_user"],
		title: "Ask you questions",
		detail: "Asks you something and waits for your answer. Without it, an agent that needs a decision from you can only stop and say so.",
	},
	{
		key: "plan",
		tools: ["update_plan"],
		title: "Keep a task list",
		detail: "Shows its plan above the message field and ticks off the steps. Without it, you see no plan while it works.",
	},
	{
		key: "web",
		tools: ["web_fetch", "web_search"],
		title: "Read the web",
		detail: "Searches the web and reads pages without opening the browser.",
		needs: "browser",
	},
	{
		key: "present",
		tools: ["present"],
		title: "Present pictures and mockups",
		detail: "Shows you pictures and mockup pages it made in a card of their own, with a window to see them large, and can ask you to pick one. Without it, an agent can only name the files.",
		needs: "files",
	},
	{
		key: "pictures",
		tools: ["make_picture"],
		title: "Make pictures",
		detail: "Makes a picture from a description, or changes the newest one in the conversation, with one of your providers' picture models, and shows it in the conversation. Each picture is charged by the provider.",
		needs: "pictures",
		offByDefault: true,
	},
	{
		key: "compact",
		tools: ["compact"],
		title: "Summarise its own conversation",
		detail: "Lets the agent have its earlier messages summarised when it reaches a good place, such as between two pieces of work, with a note on what the summary must keep. Later turns then read less. The conversation shows each time it asks.",
		offByDefault: true,
	},
	{
		key: "code",
		tools: ["run_code"],
		title: "Work things out with code",
		detail: "Runs a short JavaScript program in a sandbox and shows what it printed: for sums, dates and data. The program cannot reach your files, the network or any other tool.",
		offByDefault: true,
	},
];

/**
 * The built-in tools pi²'s chat assistant is offered (chat.ts), by key, fixed in the engine: reading the web while the
 * chat's web switch is on, writing documents, and making pictures and working things out with code once the list has
 * them. Nothing else, so nothing a chat does needs an approval. A key the list does not have yet is offered as soon as
 * it does, with whatever tools it stands for.
 */
export const CHAT_TOOLS: readonly string[] = ["web", "documents", "pictures", "code"];

/** The names of the tools a chat is offered, with the web on or off. */
export function chatToolNames(web: boolean): string[] {
	return BUILT_IN_TOOLS.filter((tool) => CHAT_TOOLS.includes(tool.key) && (web || tool.key !== "web")).flatMap((tool) => tool.tools);
}

/** The names of the tools `agent` leaves out: those its `toolsOff` names, and those off by default its `toolsOn` does not. */
export function toolsLeftOut(agent: Pick<AgentProfile, "toolsOff" | "toolsOn"> | undefined): Set<string> {
	const off = new Set(agent?.toolsOff ?? []);
	const on = new Set(agent?.toolsOn ?? []);
	return new Set(BUILT_IN_TOOLS.filter((tool) => (tool.offByDefault ? !on.has(tool.key) : off.has(tool.key))).flatMap((tool) => tool.tools));
}

/**
 * `toolsOff` or `toolsOn` as `agents.save` was sent it: known keys only, each once, in the list's order. `toolsOff` takes
 * the tools on by default, `toolsOn` those off by default.
 */
function validateKeys(input: unknown, field: "toolsOff" | "toolsOn"): string[] {
	if (!Array.isArray(input) || input.some((key) => typeof key !== "string")) throw new Error(`${field} must be a list of tool names`);
	const unknown = input.find((key) => !BUILT_IN_TOOLS.some((tool) => tool.key === key));
	if (unknown !== undefined) throw new Error(`Unknown built-in tool: ${unknown}`);
	const onByDefault = field === "toolsOff";
	const misplaced = BUILT_IN_TOOLS.find((tool) => input.includes(tool.key) && (tool.offByDefault === true) === onByDefault);
	if (misplaced !== undefined) throw new Error(`${misplaced.key} is ${onByDefault ? "off unless toolsOn names it" : "on unless toolsOff names it"}`);
	return BUILT_IN_TOOLS.filter((tool) => input.includes(tool.key)).map((tool) => tool.key);
}

export const validateToolsOff = (input: unknown): string[] => validateKeys(input, "toolsOff");
export const validateToolsOn = (input: unknown): string[] => validateKeys(input, "toolsOn");
