// The commands the engine runs for agents run at a lower priority than pi² itself (#344).
//
// With many agents building and testing at once, their commands kept every core busy, and they ran at the same
// priority as the engine, which the app waits on for everything it shows. So the shell tool's commands, background
// commands and worktrees' set-up commands are started under `nice -n 10`, as are all they start in turn: macOS gives
// the processor to the engine and the app first, and to agents' commands whenever those do not want it.
//
// Measured with the load script (scripts/load.mts) on an 18-core Mac, 20 runs each running a fixed piece of
// processor work again and again: with room on the Mac, a piece took the same time under `nice` as without it (0.33 s
// against 0.32 s), so it costs the agents nothing then. A QoS clamp of `utility` (`taskpolicy -c utility`) made the same
// pieces five times slower even with room, as macOS keeps such work on the efficiency cores, so it was not chosen.
// See docs/architecture.md, "Agents' commands at a lower priority", for the rest of the numbers.
//
// `nice` changes nothing a command can do or see but its own priority: the same program, arguments, folder,
// environment and process (it replaces itself with the command, keeping its process id). A command can lower its
// priority further, not raise it back. The person can turn it off in Settings › Tools, for the commands started after.
//
// MCP servers are left at pi²'s own priority: they are programs the person chose, started once and shared by every
// conversation, mostly idle, and some put up windows of their own; lowered, a server that waits on the person would
// answer them late. Models on this Mac are left at it too: the person waits on them as on pi².

import { defineDoc } from "@earendil-works/pi-durable";
import type { Feature } from "./features.ts";

/** How much lower: 10 of the 20 steps `nice` has. */
export const NICENESS = 10;
const NICE = "/usr/bin/nice";

/** Whether agents' commands start at the lower priority: on unless the person turned it off. */
let lower = true;

/**
 * The program and arguments that start `program` with `args` for an agent: under `nice` while the setting is on, and
 * as they are otherwise. Every caller that starts an agent's command goes through here.
 */
export function forAgent(program: string, args: readonly string[]): [string, string[]] {
	return lower ? [NICE, ["-n", String(NICENESS), program, ...args]] : [program, [...args]];
}

export type PrioritySettings = { lower: boolean };

/** One session-scoped document: the switch. */
const Priority = defineDoc<PrioritySettings>({
	kind: "pi2.commandPriority",
	version: 1,
	scope: "session",
	initial: () => ({ lower: true }),
	checkpointWhen: () => true,
});

export const priority: Feature = (_host, engine) => {
	const event = () => ({ event: "priority", lower, niceness: NICENESS });
	return {
		start: async () => {
			const stored = await engine.harness().snapshot(Priority, engine.context());
			lower = stored?.lower !== false;
		},
		greeting: () => [event()],
		handlers: {
			/** `{ lower }`: whether agents' commands start at the lower priority, from the next one started. */
			"priority.set": async (params) => {
				if (typeof params.lower !== "boolean") throw new Error("lower must be true or false");
				const wanted = params.lower;
				lower = await engine.harness().commit(async (tx) => {
					const doc = await tx.doc(Priority);
					doc.lower = wanted;
					return doc.lower;
				}, engine.context());
				engine.broadcast(event());
				return { lower };
			},
		},
	};
};
