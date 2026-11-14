// How long an agent's shell command may run (issue #45).
//
// pi durable's `bash` takes an optional `timeout` and has no default, so a command that never finishes, or waits for
// input that never comes, would hold the run until the person stopped it. This wraps `bash` wherever it is offered: a
// call without `timeout` gets the default limit, and the model is told about the limit in the tool's description and
// when it stops a command. Standard input is already closed: pi durable starts every command with it on /dev/null
// (engine/test/exec.ts checks), so a command that asks a question gets no answer and fails at once.

import { wrapTool } from "@earendil-works/pi-durable";
import { createBashTool } from "@earendil-works/pi-durable/tools";
import { num, obj, opt, str } from "@earendil-works/pi-schema";
import type { Feature } from "./features.ts";

/** The limit for a command whose call names none: 30 minutes. Tests shorten it with PI2_COMMAND_TIMEOUT_SECONDS. */
export const DEFAULT_COMMAND_TIMEOUT_SECONDS = (() => {
	const seconds = Number(process.env.PI2_COMMAND_TIMEOUT_SECONDS);
	return Number.isFinite(seconds) && seconds > 0 ? seconds : 30 * 60;
})();

/** "30 minutes", "90 seconds", "1 second". */
export function duration(seconds: number): string {
	const [count, unit] = seconds >= 60 && seconds % 60 === 0 ? [seconds / 60, "minute"] : [seconds, "second"];
	return `${count} ${unit}${count === 1 ? "" : "s"}`;
}

const LIMIT = duration(DEFAULT_COMMAND_TIMEOUT_SECONDS);

// The library's own text, but for its last sentence, which says there is no default.
const DESCRIPTION =
	`${createBashTool().description.replace(/\s*Optionally provide a timeout in seconds\.\s*$/, "")} ` +
	`A command is stopped after ${LIMIT} unless you pass \`timeout\`; for a command you know takes longer, pass a larger one. ` +
	"Standard input is closed, so a command that asks a question fails instead of waiting for an answer: give answers as options or through a pipe.";

const PARAMETERS = obj(
	{
		command: str({ description: "Bash command to execute" }),
		timeout: opt(num({ description: `Timeout in seconds. Default ${DEFAULT_COMMAND_TIMEOUT_SECONDS} (${LIMIT}); pass a larger one for a command known to take longer.` })),
	},
	{ open: true },
);

/** What the model reads when the limit stopped a command, under whatever output it had written. */
export function stoppedMessage(timeout: number | undefined): string {
	const why = timeout === undefined ? `${LIMIT}, the default time limit for a command` : `${duration(timeout)}, the \`timeout\` this call gave`;
	return `The command was stopped after ${why}. If it needs longer, run it again with a larger \`timeout\` (in seconds).`;
}

const withTimeLimit = wrapTool(createBashTool(), (bash) => ({
	...bash,
	description: DESCRIPTION,
	parameters: PARAMETERS,
	execute: async (args, api, context) => {
		try {
			return await bash.execute({ ...args, timeout: args.timeout ?? DEFAULT_COMMAND_TIMEOUT_SECONDS }, api, context);
		} catch (error) {
			// pi durable throws this for a timeout; any other failure goes on as it was.
			if (error instanceof Error && error.message.startsWith("Command timed out after ")) throw new Error(stoppedMessage(args.timeout));
			throw error;
		}
	},
}));

export const commands: Feature = () => ({ wraps: [withTimeLimit] });
