// What every table of requests uses (#483, moved from main.ts): a request's parameters, reading one of them as text,
// and checking a start the person asked for against its project's limits.

import type { Tx } from "@earendil-works/pi-durable";
import { admit, confirmLimit, limitError } from "./projectlimits.ts";
import { Projects, refuseStartWith, type Start } from "./projects.ts";
import type { AgentProfile, ModelRef } from "./state.ts";

export type Params = Record<string, unknown>;
export const text = (params: Params, key: string): string => {
	const value = params[key];
	if (typeof value !== "string") throw new Error(`Missing ${key}`);
	return value;
};

/**
 * A value a request gave, as a refusal repeats it (#940): text cut to 60 characters, as the devices' log cuts a phone's
 * folder name, an object or a list as "?", so that a sentence never carries a phone's string whole, nor a list turned
 * into text. The cut never splits a character in two halves of a surrogate pair.
 */
export const repeated = (value: unknown): string => {
	if (typeof value === "object" && value !== null) return "?";
	if (typeof value !== "string") return String(value);
	if (value.length <= 60) return value;
	const high = value.charCodeAt(58);
	return `${value.slice(0, high >= 0xd800 && high <= 0xdbff ? 58 : 59)}…`;
};

export function startConfirmation(params: Params): string | undefined {
	return confirmLimit(params.confirmLimit);
}

/** The person's start, checked against its project's limits: its agent's, or `projectId`, the one it is carried into. */
export async function checkPersonStart(tx: Tx, agent: AgentProfile, model: ModelRef | null | undefined, confirm: string | undefined, options: Start["options"], task = "", projectId?: string): Promise<string | undefined> {
	if (agent.projectId !== undefined) refuseStartWith(agent, (await tx.doc(Projects)).projects);
	const result = await admit({ by: { kind: "person" }, agentId: agent.id, agentName: agent.name, kind: "conversation", parent: null, chat: null, work: null, title: null, task, options }, confirm, { tx, model, ...(projectId === undefined ? {} : { projectId }) });
	if (!result.ok) throw limitError(result.limit);
	return result.note;
}
