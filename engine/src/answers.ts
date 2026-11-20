// Who may act for the person (#504, #513).
//
// Every command an agent runs is a process of the same person as the app, and can connect to the engine's socket as
// the app does. So the requests that answer something waiting for the person are taken only from a connection whose
// other end is the pi² app itself, as macOS's code signing says: the app bundle's `Contents/MacOS/pi2-peer` (PeerKit
// in app/Sources) is started with the connection as its file descriptor 3 and says whether the process that connected
// satisfies the bundle's designated requirement. Node cannot ask a socket that itself. The same holds for the requests
// that change what the person set (an agent's or a chat's settings, a project's, providers and sign-ins, the app's own
// switches): without that, a command could widen its own reach through the socket without answering anything (#513).
// Every handler must be in exactly one of the three lists below. The engine will not listen if it is not.
// See "Who may answer for the person" in docs/architecture.md.

import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import type { Socket } from "node:net";
import { dirname, isAbsolute, join } from "node:path";

/** What a connection that is not the app's is told: it reaches an agent that tried, so it says what to do instead. */
export const ONLY_IN_THE_APP =
	"Only the person can answer this, in the pi² app: answers to approvals, questions and sign-ins, starting past a project limit, and turning on Allow everything are not taken from a command or any other program. Ask the person instead.";

export const SETTINGS_ONLY_IN_THE_APP = "Only the person can do this, in the pi² app. Ask the person to make the change there instead.";

/**
 * The requests that answer something waiting for the person, and when a request is one. Turning Allow everything off
 * only narrows what an agent may do, and stays open to anyone.
 */
const FOR_THE_PERSON: Record<string, (params: Record<string, unknown>) => boolean> = {
	"inbox.decide": () => true, // an approval
	"inbox.answer": () => true, // a question an agent asked
	"needs.answer": () => true, // an item in Needs you
	// First attempts stay open to scripts; overriding the reading is the person's answer.
	"conversation.create": (params) => params.confirmLimit !== undefined,
	"chat.continueWithAgent": (params) => params.confirmLimit !== undefined,
	"schedules.runNow": (params) => params.confirmLimit !== undefined,
	"auth.answer": () => true, // a prompt in a sign-in to a provider
	"agents.allowEverything": (params) => params.on === true, // sent once the person confirmed it in the app
};

export function answersForThePerson(method: string, params: Record<string, unknown>): boolean {
	return Object.hasOwn(FOR_THE_PERSON, method) && FOR_THE_PERSON[method]!(params);
}

/**
 * The requests that change what the person set (projects.md 7.1): an agent's or a chat's settings, a conversation's
 * access and folder, a project's settings and rules, worktrees, providers and sign-ins, models, spending, schedules,
 * and the app's own switches. Each is made in the app, and a command that could send it could widen its own reach
 * without answering anything (#513). Where only part of a request widens (`agents.save` with an unchanged access), the
 * whole request is the person's, from the app.
 */
const FOR_THE_PERSON_SETTINGS: Record<string, (params: Record<string, unknown>) => boolean> = {
	// An agent's or a chat's settings, and the requests around them.
	"agents.save": () => true, // access, computer and browser use, tools, MCP servers, delegates, worktree, set-up command
	"agents.duplicate": () => true, // a copy made with the source's reach
	"agents.delete": () => true, // deleting an agent for good
	"agents.restore": () => true, // undoes the person's removal of an agent that may have had full reach
	"agents.updateFromTemplate": () => true, // changes an agent's settings from a template
	"conversation.configure": () => true, // a conversation's access, folder and model; a chat's web switch
	"conversation.carryOn": () => true, // changes the model of an existing run and the default for future ones
	"conversation.fork": () => true, // copies a conversation's settings and its historical state
	"conversation.retry": (params) => params.model != null, // a different model changes the chat; retry alone does not
	"conversation.archive": () => true, // archiving and deleting are the person's
	"conversation.unarchive": () => true, // as above
	"conversation.delete": () => true, // as above
	"chat.set": () => true, // the assistant's instructions, model, web switch and memory
	"memory.setEnabled": () => true, // a memory switch turned on plants what an agent read
	"rules.add": () => true, // an allowed command
	"rules.remove": () => true, // removing one is the person's too
	"variables.set": () => true, // "not offered to any tool: the person's alone"
	"variables.remove": () => true, // as above
	"schedules.save": () => true, // schedules start work with nobody there
	"schedules.delete": () => true, // as above
	"coauthor.set": () => true, // the switch that tells every agent how to end its commits
	// Projects.
	"projects.create": () => true, // claims a folder and its conversations for a project
	"projects.set": () => true, // the switches of 8.1 and the limits
	"projects.setPreview": () => true, // the preview switch, the person's alone
	"projects.carryOver": () => true, // carrying over, not offered to agents
	"projects.retrySecrets": () => true, // the person's retry of the Keychain step of carrying over
	"projects.archive": () => true, // archiving, restoring and deleting are the person's
	"projects.unarchive": () => true, // as above
	"projects.delete": () => true, // as above
	// Moving a conversation of a deleted project between projects is the person's act, like deleting the project (#531);
	// the dry run, which changes nothing, stays open to scripts, as a first attempt does.
	"projects.restoreConversation": (params) => params.dryRun !== true,
	"projects.startFresh": () => true, // Start fresh
	"projects.setOrchestrator": () => true, // the orchestrator's role carries its switches and tools
	"projects.watch": () => true, // a repository attached to a project
	"projects.addAgent": () => true, // making an agent is the person's; through tools it is baseline-gated
	"projects.rules.add": () => true, // the project's rules
	"projects.rules.edit": () => true, // as above
	"projects.rules.move": () => true, // as above
	"projects.rules.remove": () => true, // as above
	"changes.undo": () => true, // undo can restore what the person narrowed
	"work.create": () => true, // files work as the person, including on GitHub
	"work.act": () => true, // acts as the person, past the work switches; assign may also confirm a limit
	"worktree.create": () => true, // worktrees and the folder they are made in
	"worktree.remove": () => true, // as above
	// GitHub, where the app records each of these as the person's own act.
	"github.attach": () => true, // a repository attached
	"github.detach": () => true, // as above
	"github.merge": () => true, // past the merge switch, as the person
	"github.sendBack": () => true, // as the person
	"github.settle": () => true, // the person's answer to a write whose outcome is unknown
	// Providers, sign-ins, models, spending.
	"providers.setKey": () => true, // a secret
	"providers.login": () => true, // a sign-in
	"providers.logout": () => true, // as above
	"auth.cancel": () => true, // cancels a sign-in owned by the app
	"providers.addModel": () => true, // names any endpoint
	"providers.removeModel": () => true, // as above
	"providers.setHiddenModels": () => true, // the person's model list
	"endpoints.save": () => true, // a provider's endpoint
	"endpoints.remove": () => true, // as above
	"endpoints.probe": () => true, // makes a request from the engine to a URL chosen by the caller
	"pictures.setModel": () => true, // the model that spends on pictures
	"usage.setBudget": () => true, // raising the daily budget unbinds spending
	// The app's own switches, and its role as the host of computer use and the browser.
	"settings.finishOnboarding": () => true, // settings.json
	"settings.setCompaction": () => true, // as above
	"settings.setAutoArchive": () => true, // as above
	"backup.create": () => true, // copies the person's database to a chosen folder
	"recovery.dismiss": () => true, // clears the notice for everyone
	"limits.dismiss": () => true, // silences the person's provider-limit notice
	"priority.set": () => true, // the person's switch in Settings
	"computer.register": () => true, // a command that registered would receive agents' actions and answer them
	"computer.result": () => true, // the app's half of computer use
	"browser.register": () => true, // as with the computer
	"browser.result": () => true, // as above
	"mcp.save": () => true, // MCP servers and their settings
	"mcp.reconnect": () => true, // starts the configured program or reconnects using stored credentials
	"mcp.delete": () => true, // as above
	"mcp.setVariable": () => true, // a server's own variables
	"mcp.removeVariable": () => true, // as above
	"local.engine.install": () => true, // installing software on the Mac
	"local.engine.remove": () => true, // as above
	"local.model.install": () => true, // as above
	"local.model.remove": () => true, // as above
	"local.model.configure": () => true, // the model's settings
	"local.model.folder": () => true, // where models live
	"local.download.pause": () => true, // controls a persistent software installation
	"local.download.resume": () => true, // as above
	"local.download.cancel": () => true, // as above
	"test-copy.fillProject": () => true, // invokes several of these handlers to build a demo project
};

export function settingsForThePerson(method: string, params: Record<string, unknown>): boolean {
	return Object.hasOwn(FOR_THE_PERSON_SETTINGS, method) && FOR_THE_PERSON_SETTINGS[method]!(params);
}

/** The refusal to use if only the app can send this request. Ordinary first starts and retries stay open. */
export function personOnly(method: string, params: Record<string, unknown>): string | undefined {
	if (answersForThePerson(method, params) || (method === "work.act" && params.action === "assign" && params.confirmLimit !== undefined)) return ONLY_IN_THE_APP;
	if (settingsForThePerson(method, params) || (method === "chat.continueWithAgent" && params.cwd != null)) return SETTINGS_ONLY_IN_THE_APP;
	return undefined;
}

/**
 * Every other request on the socket, open to any connection: reading, sending a message, starting and stopping runs, and
 * transient controls. Notes and names do not change reach (projects.md 7.1). First starts and retries are also open
 * where their parameters do not make them a person's request. The test-copy key exchange stays open so a connection
 * can prove itself.
 */
const OPEN_TO_ANY = new Set([
	"engine.info",
	"engine.lag",
	"connection.mayAnswer",
	"conversation.pin",
	"conversation.open",
	"conversation.older",
	"conversation.close",
	"conversations.shown",
	"conversation.rename",
	"projects.rename",
	"conversation.compact",
	"conversation.dismissCompactionError",
	"conversation.reset",
	"conversation.image",
	"conversation.export",
	"conversation.edit",
	"conversation.version",
	"search",
	"submit",
	"continue",
	"abort",
	"withdraw",
	"submission.get",
	"providers.draftModel",
	"providers.ask",
	"settings.getCompaction",
	"background.output",
	"background.stop",
	"changes.list",
	"github.refresh",
	"github.diff",
	"memory.add",
	"memory.edit",
	"memory.delete", // notes never widen (projects.md 7.1)
	"needs.list",
	"projects.list",
	"reports.wake", // waking never widens; the limits bound it
	"wakes.cancel",
	"wakes.resume",
	"work.list",
	"worktree.suggest",
	"branches.refresh",
	"limits.refresh",
	"local.status",
	"local.start",
	"local.stop",
	"local.model.try",
	"test-copy.answerer",
	"test-copy.fill",
]);

const REQUEST_CLASSES: readonly ReadonlySet<string>[] = [new Set(Object.keys(FOR_THE_PERSON)), new Set(Object.keys(FOR_THE_PERSON_SETTINGS)), OPEN_TO_ANY];

/** Validate the completed handler table before serving requests. Some classified methods exist only in test copies. */
export function checkRequestClasses(methods: Iterable<string>, classes = REQUEST_CLASSES): void {
	const mistakes: string[] = [];
	for (const method of methods) {
		const count = classes.filter((list) => list.has(method)).length;
		if (count !== 1) mistakes.push(`${method} belongs to ${count} request classes (expected one)`);
	}
	if (mistakes.length > 0) throw new Error(`Request classes in answers.ts:\n${mistakes.join("\n")}`);
}

/**
 * The app bundle this engine belongs to. A release engine is inside it (`Contents/Resources/engine/src/main.ts`) and
 * takes no other. A development engine runs from a checkout, so the app that starts it names its bundle in
 * `PI2_APP_BUNDLE`, which commands never get (environment.ts); without it, no connection is the app's.
 */
export function appBundle(engineMain: string, build: string | null, environment: NodeJS.ProcessEnv): string | null {
	if (build !== null) return dirname(dirname(dirname(dirname(dirname(engineMain)))));
	const named = environment.PI2_APP_BUNDLE;
	return named !== undefined && isAbsolute(named) ? named : null;
}

export type Verdict = { app: boolean; why: string };

/** Asks, once for each connection, whether the process at its other end is the app. */
export class AppCheck {
	readonly #bundle: string | null;
	readonly #log: (...parts: unknown[]) => void;
	readonly #patienceMs: number;
	readonly #verdicts = new WeakMap<Socket, Promise<Verdict>>();

	constructor(bundle: string | null, log: (...parts: unknown[]) => void, patienceMs = 10_000) {
		this.#bundle = bundle;
		this.#log = log;
		this.#patienceMs = patienceMs;
	}

	/**
	 * Whether `socket`'s other end is the app. The process at the other end of a connection cannot change, so a
	 * verdict is kept for the connection's life; a check that could not be made is not, and is made again next time.
	 * Anything that cannot be checked is not the app.
	 */
	verdict(socket: Socket): Promise<Verdict> {
		const known = this.#verdicts.get(socket);
		if (known !== undefined) return known;
		const asked = this.#ask(socket).then(({ verdict, lasting }) => {
			if (!lasting) this.#verdicts.delete(socket);
			this.#log("answers:", verdict.why, verdict.app ? "(may answer for the person)" : "(may not answer for the person)");
			return verdict;
		});
		this.#verdicts.set(socket, asked);
		return asked;
	}

	async #ask(socket: Socket): Promise<{ verdict: Verdict; lasting: boolean }> {
		const bundle = this.#bundle;
		if (bundle === null) return { verdict: { app: false, why: "this engine does not know which app it belongs to" }, lasting: true };
		const helper = join(bundle, "Contents", "MacOS", "pi2-peer");
		if (!existsSync(helper)) return { verdict: { app: false, why: `there is no ${helper} to ask whether a connection is the app's` }, lasting: false };
		return new Promise((resolve) => {
			const unchecked = (why: string) => resolve({ verdict: { app: false, why: `the connection could not be checked: ${why}` }, lasting: false });
			// The connection's descriptor, not the socket: given a stream, Node stops reading it in this process for good, as it
			// would if the child were to take it over. The helper only asks the socket about its other end, and never reads.
			const descriptor = (socket as unknown as { _handle?: { fd?: unknown } })._handle?.fd;
			if (typeof descriptor !== "number" || descriptor < 0) {
				unchecked("it has no descriptor to hand over");
				return;
			}
			let output = "";
			let child: ReturnType<typeof spawn>;
			try {
				child = spawn(helper, [bundle], { stdio: ["ignore", "pipe", "ignore", descriptor] });
			} catch (error) {
				unchecked(error instanceof Error ? error.message : String(error));
				return;
			}
			const timer = setTimeout(() => {
				child.kill("SIGKILL");
				unchecked(`${helper} did not answer within ${this.#patienceMs / 1000} seconds`);
			}, this.#patienceMs);
			child.stdout!.setEncoding("utf8").on("data", (text: string) => (output += text));
			child.once("error", (error) => {
				clearTimeout(timer);
				unchecked(error.message);
			});
			child.once("close", (code) => {
				clearTimeout(timer);
				try {
					const answer = JSON.parse(output.trim().split("\n").at(-1) ?? "") as { app?: unknown; why?: unknown };
					if (code !== 0 || typeof answer.app !== "boolean" || typeof answer.why !== "string") throw new Error();
					resolve({ verdict: { app: answer.app, why: answer.why }, lasting: true });
				} catch {
					unchecked(`${helper} ended with ${code === null ? "a signal" : `code ${code}`} and no answer`);
				}
			});
		});
	}
}
