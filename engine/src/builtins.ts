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

import type { AgentProfile } from "./state.ts";

export type BuiltInTool = {
	/** What `toolsOff` holds. */
	key: string;
	/** The tools it stands for, by name. */
	tools: string[];
	/** What the person reads in the agent's settings: what it does, and what leaving it out means where that may surprise. */
	title: string;
	detail: string;
	/** Where it is offered at all: any access but none, Ask first or Full access, the browser on; anywhere when absent. */
	needs?: "files" | "changes" | "browser";
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
		detail: "Searches the web and reads pages without the browser. Offered only while the browser is on.",
		needs: "browser",
	},
];

/** The names of the tools `agent` leaves out. */
export function toolsLeftOut(agent: AgentProfile | undefined): Set<string> {
	const off = new Set(agent?.toolsOff ?? []);
	return new Set(BUILT_IN_TOOLS.filter((tool) => off.has(tool.key)).flatMap((tool) => tool.tools));
}

/** `toolsOff` as `agents.save` was sent it: known keys only, each once, in the list's order. */
export function validateToolsOff(input: unknown): string[] {
	if (!Array.isArray(input) || input.some((key) => typeof key !== "string")) throw new Error("toolsOff must be a list of tool names");
	const unknown = input.find((key) => !BUILT_IN_TOOLS.some((tool) => tool.key === key));
	if (unknown !== undefined) throw new Error(`Unknown built-in tool: ${unknown}`);
	return BUILT_IN_TOOLS.filter((tool) => input.includes(tool.key)).map((tool) => tool.key);
}
