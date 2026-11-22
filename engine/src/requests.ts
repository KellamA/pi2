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
