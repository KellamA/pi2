// What pi2 adds to every conversation: approval before risky tools, a way to ask the person, and delegation.

import {
	type AgentChange,
	configure,
	type ConversationId,
	defineExtension,
	defineTool,
	type Extension,
	hook,
	section,
	ToolTask,
	type Tx,
} from "@earendil-works/pi-durable";
import { obj, str } from "@earendil-works/pi-schema";
import { type AgentProfile, type Inbox, Library, type Meta } from "./state.ts";

/** Tools that change things on the Mac, and so wait for approval when a conversation's access is "ask". */
const GATED = new Set(["bash", "write", "edit"]);

export type Host = {
	inbox: Inbox;
	/** Whether a tool outside the built-in set changes things, and so needs approval under "ask". */
	changesThings(tool: string): boolean;
	meta(conversationId: ConversationId): Meta | undefined;
	agent(id: string | undefined): AgentProfile | undefined;
	allowAlways(conversationId: ConversationId, tool: string): Promise<void>;
	/** How a conversation of `agent` is configured; `delegate` false leaves the delegation tool out. */
	agentChange(agent: AgentProfile, options: { delegate: boolean }): Promise<AgentChange>;
	answerText(conversationId: ConversationId, submissionAnswer: unknown): Promise<string>;
};

const text = (value: string) => [{ type: "text" as const, text: value }];

/** The agents a conversation may delegate to, from its own agent's list. */
function delegatesOf(host: Host, conversationId: ConversationId): AgentProfile[] {
	const own = host.agent(host.meta(conversationId)?.agentId);
	return (own?.delegates ?? []).map((id) => host.agent(id)).filter((a): a is AgentProfile => a !== undefined);
}

export function pi2Extension(host: Host): Extension {
	const askUser = defineTool({
		name: "ask_user",
		description: "Ask the person a question and wait for their answer. Use it when you need a decision or a fact only they have; do not use it for things you can find out yourself.",
		parameters: obj({ question: str() }),
		replay: "safe", // after a restart the question is simply asked again
		execute: async (args, api, context) => {
			const answer = await host.inbox.ask(
				{
					id: String(api.taskId),
					kind: "question",
					conversationId: api.conversationId as unknown as number,
					callId: api.callId,
					tool: "ask_user",
					arguments: args,
					question: args.question,
					createdAt: Date.now(),
				},
				context,
			);
			return { output: text(answer) };
		},
	});

	const delegate = defineTool({
		name: "delegate",
		description: "Hand a self-contained task to another agent and get its answer back. Name one of the agents listed in the <agents> section, and write the task so it stands on its own: the other agent sees none of this conversation.",
		parameters: obj({ agent: str(), task: str() }),
		replay: "safe", // a rerun after a crash finds the same child conversation and submission
		execute: async (args, api, context) => {
			const allowed = delegatesOf(host, api.conversationId);
			const target = allowed.find((a) => a.name.toLowerCase() === args.agent.trim().toLowerCase() || a.id === args.agent.trim());
			if (target === undefined) {
				const names = allowed.map((a) => a.name).join(", ");
				return { output: text(names === "" ? "This conversation has no agents to delegate to." : `Unknown agent "${args.agent}". Available: ${names}.`), isError: true };
			}
			const change = await host.agentChange(target, { delegate: false });
			const parent = api.conversationId as unknown as number;
			const child = await api.commit(async (tx: Tx) => {
				const existing = (await tx.scanConversations({ ownerTaskId: api.taskId }, 1)).items[0];
				if (existing !== undefined) return existing.id;
				const created = await tx.createConversation({ ownership: { kind: "task", taskId: api.taskId } });
				await configure(tx, created.id, change);
				const now = Date.now();
				(await tx.doc(Library)).conversations[String(created.id)] = {
					title: `${target.name}: ${args.task.trim().split("\n")[0]!.slice(0, 60)}`,
					createdAt: now,
					updatedAt: now,
					access: target.access,
					agentId: target.id,
					parent,
				};
				return created.id;
			}, context);
			// Lets the app open the subagent's transcript from the call's card.
			await api.details({ conversationId: child as unknown as number, agentId: target.id, agentName: target.name }, context);
			const handle = (await api.conversation(child, context))!;
			const submission = await handle.submit({ type: "input", content: args.task, requestId: `delegate:${String(api.taskId)}` }, context);
			const settled = await submission.wait(context);
			if (settled.status !== "done" || settled.type !== "input") {
				const why = "reason" in settled && settled.reason !== undefined ? ` (${String(settled.reason)})` : "";
				return { output: text(`${target.name} did not finish the task${why}.`), isError: true };
			}
			return { output: text(await host.answerText(child, settled.answer)) };
		},
	});

	return defineExtension({
		name: "pi2",
		tools: [askUser, delegate],
		sections: [
			section("agents", (input) => {
				const offered = input.agent.tools.some((tool) => tool.name === "delegate");
				const agents = offered ? delegatesOf(host, input.conversationId) : [];
				if (agents.length === 0) return undefined;
				return ["You can hand work to these agents with the delegate tool:", ...agents.map((a) => `- ${a.name}: ${a.description}`)].join("\n");
			}),
		],
		hooks: [
			hook(ToolTask, {
				beforeTool: async (call, api, context) => {
					const meta = host.meta(api.conversationId);
					if (meta?.access !== "ask" || !(GATED.has(call.name) || host.changesThings(call.name))) return undefined;
					if (meta.autoApprove?.includes(call.name)) return undefined;
					const decision = await host.inbox.ask(
						{
							id: String(api.taskId),
							kind: "approval",
							conversationId: api.conversationId as unknown as number,
							callId: call.id,
							tool: call.name,
							arguments: call.arguments,
							question: null,
							createdAt: Date.now(),
						},
						context,
					);
					if (decision === "always") await host.allowAlways(api.conversationId, call.name);
					return decision === "deny" ? { block: "The person declined this action. Do not retry it; ask what they would like instead." } : undefined;
				},
			}),
		],
	});
}
