// Loaded only for a throwaway copy, alongside test-copy-fixture.ts. All project data is made through engine requests.
import { mkdtempSync } from "node:fs";
import { join } from "node:path";
import { setTimeout as pause } from "node:timers/promises";

type Params = Record<string, unknown>;
type Request = (method: string, params: Params) => Promise<unknown>;
const omitted = ["reach and proposed-rule requests (#465)", "limit cards (#464)", "GitHub pull requests (#468)"];
const sleep = "/bin/sleep 540";

export async function fillProject(home: string, request: Request, ready: (ids: { projectId: string; working: number[]; waiting: number; finished: number }) => Promise<boolean>) {
	const deadline = Date.now() + 120_000;
	const call = async <T>(method: string, params: Params = {}): Promise<T> => await request(method, params) as T;
	const until = async (label: string, check: () => boolean | Promise<boolean>) => {
		while (!(await check())) {
			if (Date.now() >= deadline) throw new Error(`Timed out waiting for ${label} in the demo project`);
			await pause(100);
		}
	};
	const submit = (id: number, text: string) => call<{ submissionId: number }>("submit", { id, text });
	const send = async (id: number, text: string) => {
		const { submissionId } = await submit(id, text);
		await until(`conversation #${id} to finish`, async () => {
			const { submission, busy } = await call<{ submission: { status: string }; busy: boolean }>("submission.get", { id, submissionId });
			if (!busy && submission.status !== "placed" && submission.status !== "queued" && submission.status !== "done") {
				throw new Error(`Demo submission ${submissionId} ended as ${submission.status}`);
			}
			return !busy && submission.status === "done";
		});
	};
	if (!(await call<{ preview: boolean }>("projects.list")).preview) {
		// #458 supplies a carry-over plan. Until it lands, turning the preview on carries nothing over.
		const { plan } = await call<{ plan?: string }>("projects.carryOver", { dryRun: true }).catch((error) => {
			if (error.message !== "Unknown method: projects.carryOver") throw error;
			return { plan: undefined };
		});
		await call("projects.setPreview", { on: true, ...(plan === undefined ? {} : { plan }) });
	}
	const { projects } = await call<{ projects: { name: string }[] }>("projects.list");
	const base = "Demo project";
	const names = new Set(projects.map(({ name }) => name.toLowerCase()));
	let name = base;
	for (let n = 2; names.has(name.toLowerCase()); n++) name = `${base} ${n}`;
	const folder = mkdtempSync(join(home, "demo-project-"));
	const { id: projectId, conversation: orchestrator } = await call<{ id: string; conversation: number }>("projects.create", { name, folder });
	try {
		const model = { provider: "demo", modelId: "demo-1" };
		const { projects } = await call<{ projects: { id: string; orchestratorId: string }[] }>("projects.list");
		await call("agents.save", { agent: { id: projects.find(({ id }) => id === projectId)!.orchestratorId, name: "Orchestrator", model } });
		const addAgent = (name: string, color: string) => call<{ id: string }>("projects.addAgent", { projectId, agent: { name, color, access: "ask", model } });
		const { id: atlas } = await addAgent("Atlas", "blue");
		const { id: forge } = await addAgent("Forge", "orange");
		const { id: scout } = await addAgent("Scout", "green");
		const { id: beacon } = await addAgent("Beacon", "pink");
		const conversation = async (agentId: string, title: string) => {
			const { id } = await call<{ id: number }>("conversation.create", { agentId });
			await call("conversation.rename", { id, title });
			return id;
		};
		const atlasChat = await conversation(atlas, "Check the sample build");
		const forgeChat = await conversation(forge, "Check the handoff");
		const beaconChat = await conversation(beacon, "Verify the preview");

		for (const [binds, text] of [
			["everyone", "Keep the sample data fictional."],
			["orchestrator", "Summarise open decisions before the handoff."],
			["everyone", "Record what you checked and what you skipped."],
		]) await call("projects.rules.add", { projectId, binds, text });
		await call("memory.add", { projectId, text: "The sample is for the Friday walkthrough." });
		const { id: note } = await call<{ id: string }>("memory.add", { projectId, text: "Compare the two preview layouts before recommending one." });
		await call("memory.edit", { projectId, id: note, audience: atlas });

		const file = async (title: string, text: string) => (await call<{ id: number }>("work.create", { projectId, title, text })).id;
		const open = await file("Write the release checklist", "List the checks still to run before handing over.");
		const inProgress = await file("Check the sample build", "Walk through the build output.");
		const waiting = await file("Confirm the walkthrough date", "Wait for the person to confirm the date.");
		const blocked = await file("Review the handoff checklist", "The sample handoff is missing its summary.");
		const done = await file("Read the draft notes", "The sample notes are ready for the walkthrough.");
		const dropped = await file("Try the old layout", "Keep just the two current layouts.");
		await call("work.act", { projectId, id: dropped, action: "close", as: "dropped" });
		const { conversation: scoutChat } = await call<{ conversation: number }>("work.act", { projectId, id: done, action: "assign", agentId: scout });
		await call("work.act", { projectId, id: done, action: "close", as: "done", text: "The notes are ready to share." });
		const work = (chat: number, action: string, id: number, text?: string) => send(chat, `/tool work ${JSON.stringify({ action, id, text })}`);
		const ask = (question: string, choices?: string[]) => ({ name: "needs_you", arguments: { action: "ask", question, choices } });
		await Promise.all([
			send(orchestrator, "Put together a short walkthrough for Friday."),
			(async () => {
				await work(atlasChat, "take", waiting);
				await work(atlasChat, "wait", waiting, "Waiting on the walkthrough date.");
				await work(atlasChat, "take", inProgress);
			})(),
			(async () => {
				await work(forgeChat, "take", blocked);
				await work(forgeChat, "block", blocked, "The handoff summary is not ready.");
			})(),
		]);
		await send(orchestrator, `/tools ${JSON.stringify([
			ask("Who should join the Friday walkthrough?"),
			ask("Which preview layout should we show?", ["Side by side", "Board first"]),
		])}`);

		const { items } = await call<{ items: { id: number; state: string }[] }>("work.list", { projectId });
		const expected = [[open, "open"], [inProgress, "in_progress"], [waiting, "waiting"], [blocked, "blocked"], [done, "done"], [dropped, "dropped"]];
		for (const [id, state] of expected) {
			if (!items.some((item) => item.id === id && item.state === state)) throw new Error(`Work #${id} did not reach ${state}`);
		}
		// Keep two real runs working long enough to take pictures. Only this harmless command, in this fixture's own
		// folder, is allowed. Beacon instead asks before running a harmless command, so the approval can be answered.
		for (const agentId of [atlas, forge]) await call("rules.add", { agentId, folder, command: sleep });
		await submit(atlasChat, `/timeout 600 ${sleep}`);
		await submit(forgeChat, `/timeout 600 ${sleep}`);
		await submit(beaconChat, "/bash /usr/bin/true");
		await until("the working agents, waiting agent and unread report", () => ready({ projectId, working: [atlasChat, forgeChat], waiting: beaconChat, finished: scoutChat }));
		const { items: needs } = await call<{ items: { id: string; kind: string }[] }>("needs.list", { projectId });
		if (["question", "decision", "approval"].some((kind) => !needs.some((item) => item.kind === kind))) {
			throw new Error("The demo question, decision or approval is missing");
		}
		return { id: projectId, name, conversations: { Orchestrator: orchestrator, Atlas: atlasChat, Forge: forgeChat, Scout: scoutChat, Beacon: beaconChat }, needs: needs.map(({ id, kind }) => ({ id, kind })), omitted };
	} catch (error) {
		throw new Error(`Could not fill ${name} (${projectId}, orchestrator #${orchestrator}): ${error instanceof Error ? error.message : String(error)}`);
	}
}
