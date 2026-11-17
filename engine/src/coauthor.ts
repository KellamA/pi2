// Naming pi² as a co-author of the commits its agents make, when the person asks for it (#201).
//
// One switch for every agent and sub-chat, off by default, with the trailer line it adds. It is an instruction, not
// something the engine enforces: with the switch on, a conversation that can run commands gets a section asking the
// agent to end the message of every commit it makes with the line. The engine never changes git's configuration, a
// repository's hooks, a commit's author or committer, or a commit already made. Pointing git at hooks of pi²'s own
// would have set aside a repository's own, so the agent is asked instead. See docs/commits.md.

import { defineDoc, section } from "@earendil-works/pi-durable";
import type { Feature } from "./features.ts";

/**
 * The line pi² suggests. The project has no address of its own, and `.invalid` is reserved (RFC 2606): no one can ever
 * own it, so the default can never credit a commit to somebody's account.
 */
export const DEFAULT_COAUTHOR_LINE = "Co-authored-by: pi² <noreply@pi2.invalid>";
export const MAX_COAUTHOR_LINE = 200;

export type CoauthorSettings = { enabled: boolean; line: string };

/** One session-scoped document: the switch and the line, which is kept while the switch is off. */
const Coauthor = defineDoc<CoauthorSettings>({
	kind: "pi2.coauthor",
	version: 1,
	scope: "session",
	initial: () => ({ enabled: false, line: DEFAULT_COAUTHOR_LINE }),
	checkpointWhen: () => true,
});

/**
 * A well-formed `Co-authored-by` trailer, tidied (`Co-authored-by: Name <address>`), or an Error that says what is
 * wrong with it. Only that trailer: it is the one git hosts read as a co-author, and the section says what it is.
 */
export function checkCoauthorLine(value: unknown): string {
	if (typeof value !== "string" || value.trim() === "") throw new Error(`Write the line, such as ${DEFAULT_COAUTHOR_LINE}`);
	const line = value.trim();
	// biome-ignore lint/suspicious/noControlCharactersInRegex: control characters are what is refused
	if (/[\u0000-\u001f\u007f\u2028\u2029]/.test(line)) throw new Error("The line must be a single line, with no line breaks or tabs: git reads a trailer one line at a time");
	if (line.length > MAX_COAUTHOR_LINE) throw new Error(`The line can be ${MAX_COAUTHOR_LINE} characters at most; this one is ${line.length}`);
	const trailer = /^co-authored-by:\s*(.*)$/i.exec(line);
	if (trailer === null) throw new Error("Start the line with “Co-authored-by:”, the trailer git hosts read as a co-author");
	const parts = /^([^<>]+?)\s*<([^<>\s]+)>$/.exec(trailer[1]!);
	if (parts === null) throw new Error(`After Co-authored-by: give a name, then an address in angle brackets, as in ${DEFAULT_COAUTHOR_LINE}`);
	if (!/^[^@\s]+@[^@\s]+\.[^@\s.]+$/.test(parts[2]!)) throw new Error(`The address in angle brackets must be of the form name@domain; ${parts[2]} is not`);
	return `Co-authored-by: ${parts[1]!.trim()} <${parts[2]}>`;
}

export function describeCoauthor(line: string): string {
	return [
		"The person asked that the commits pi²'s agents make name pi² as a co-author. End the message of every git commit you make with this line, exactly as written, once:",
		line,
		"Put it on a line of its own in the message's last paragraph, after a blank line, together with any other trailers such as Signed-off-by. Add it only to commits you make yourself: do not add it to commits you did not make, and do not amend or rewrite earlier commits to add it. Leave the commit's author and committer, and git's configuration, as they are.",
	].join("\n");
}

export const coauthor: Feature = (_host, engine) => {
	let settings: CoauthorSettings = { enabled: false, line: DEFAULT_COAUTHOR_LINE };
	const event = () => ({ event: "coauthor", enabled: settings.enabled, line: settings.line, defaultLine: DEFAULT_COAUTHOR_LINE });

	return {
		sections: [
			// Only where a commit can be made: a conversation that can run commands, its sub-chats included. Read at every
			// request, so turning it on or off counts from each conversation's next message.
			section("commit_coauthor", (input) =>
				settings.enabled && input.agent.tools.some((tool) => tool.name === "bash") ? describeCoauthor(settings.line) : undefined,
			),
		],
		start: async () => {
			const stored = await engine.harness().snapshot(Coauthor, engine.context());
			if (stored !== undefined) settings = { enabled: stored.enabled === true, line: stored.line ?? DEFAULT_COAUTHOR_LINE };
		},
		greeting: () => [event()],
		handlers: {
			/** `{ enabled?, line? }`: either or both. A line that is not a well-formed trailer is refused, and nothing changes. */
			"coauthor.set": async (params) => {
				if (params.enabled !== undefined && typeof params.enabled !== "boolean") throw new Error("enabled must be true or false");
				const line = params.line === undefined ? undefined : checkCoauthorLine(params.line);
				const enabled = params.enabled as boolean | undefined;
				settings = await engine.harness().commit(async (tx) => {
					const doc = await tx.doc(Coauthor);
					if (enabled !== undefined) doc.enabled = enabled;
					if (line !== undefined) doc.line = line;
					return { enabled: doc.enabled, line: doc.line };
				}, engine.context());
				engine.broadcast(event());
				return { line: settings.line };
			},
		},
	};
};
