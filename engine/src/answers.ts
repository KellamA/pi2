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
//
// A paired phone is a second way to be the person (docs/iphone.md section 4, #673): its requests come through the pi²
// Remote the engine started, in a device session, and each is checked against the device lists further down whatever
// its class here. Every handler is also in exactly one of those, or the engine will not listen either.

import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import type { Socket } from "node:net";
import { dirname, isAbsolute, join } from "node:path";
import type { SwitchName } from "./projects.ts";

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
	"projects.retrySecrets": () => true, // the person's retry of the Keychain step of carrying over
	"projects.archive": () => true, // archiving, restoring and deleting are the person's
	"projects.unarchive": () => true, // as above
	"projects.delete": () => true, // as above
	// Moving a conversation of a deleted project between projects is the person's act, like deleting the project (#531);
	// the dry run, which changes nothing, stays open to scripts, as a first attempt does.
	"projects.restoreConversation": (params) => params.dryRun !== true,
	"projects.startFresh": () => true, // Start fresh
	"projects.setOrchestrator": () => true, // the orchestrator's role carries its switches and tools
	"projects.watch": () => true, // which of a project's tabs this connection watches; it attaches nothing (iphone.md decision 27)
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
	"look.setModel": () => true, // as above, for the model that looks at pictures (#540)
	"usage.setBudget": () => true, // raising the daily budget unbinds spending
	// The app's own switches, and its role as the host of computer use and the browser.
	"settings.finishOnboarding": () => true, // settings.json
	"settings.setCompaction": () => true, // as above
	"settings.setAutoArchive": () => true, // as above
	"settings.setAgentDefault": () => true, // as above: the model every agent with none of its own starts on (#617)
	"settings.setAwake": () => true, // as above: keeping the Mac awake while agents work
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
	// Paired devices (iphone.md 3, 4.1): every devices.* request but devices.self and devices.forgetSelf. A command that
	// could call devices.pairStart would be given the pairing's secret, and one that could confirm would pair a phone.
	"devices.watch": () => true, // the `devices` event, with claims and the devices' keys, goes to the app alone
	// Turning a switch on, or naming the relay; turning one off is open, as turning Allow everything off is.
	"devices.set": (params) => params.relayAddress !== undefined || Object.values(params).some((value) => value === true),
	"devices.pairStart": () => true, // its answer holds the pairing's secret
	"devices.pairCancel": () => true, // the sheet closed
	"devices.pairConfirm": () => true, // the digits the person typed
	"devices.rename": () => true, // the person's name for a device
	"devices.revoke": () => true, // as the person
	"devices.resume": () => true, // takes a suspended device back
	"devices.log": () => true, // what each device did
	"devices.acceptPresenceKey": () => true, // a phone's new Face ID key, which then opens sessions (3.2)
	"devices.refusePresenceKey": () => true, // drops it
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
	"github.unknown", // reads the writes whose outcome pi² could not tell (#573)
	"github.show", // reads one issue or pull request whole into the listing (#599)
	"memory.add",
	"memory.edit",
	"memory.delete", // notes never widen (projects.md 7.1)
	"needs.list",
	"projects.list",
	"projects.carryOver", // a dry run alone since carrying over runs by itself at the update (#715): it changes nothing
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
	"devices.self", // a device's own record and log; refused outside a device session
	"devices.forgetSelf", // a device unpairing itself; refused outside a device session
	"pushes.set", // what a device is pushed: its own settings; refused outside a device session (iphone.md 7)
	"pushes.follow", // which project a device's Live Activity follows; refused outside a device session
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

// ---- From a paired device (docs/iphone.md 4.1 and 4.2, #673)
//
// Every request in a device session is checked here, whatever its class above: `deviceMay` answers "yes", "face" or
// "no". "no" is refused before the handler runs. "yes" and "face" are handled as from the app: a session exists only
// once Face ID opened it, so every request in it is under that Face ID, and none asks again (the owner's choice, 4.5).
// "face" marks a request that widens reach: it lives an hour in the mailbox, not a day, and the Mac tells the person of
// it (4.4). What a phone may send is decided by what a request does, not by its name (decision 27), so some rows are
// functions of the parameters, and of the approval an answer is for.
//
// The lists are 4.2's table, which is decision 2's one place. FROM_A_DEVICE holds what a phone may send, "yes" or by its
// parameters; WITH_FACE_ID what it may send that always widens; MAC_ONLY what only the Mac may do, with the handlers the
// table does not name ("not named in 4.2"), which stay the Mac's until an issue places them; FOR_THE_HELPER the
// requests of pi² Remote itself, taken only on the connection the engine made for it. A request added later is placed
// by the issue that adds it, which tests its refusal from a device. engine/test/devices.ts lists every request of the
// person's two lists above that a device may send, with its reason, so nothing reaches a phone by default.

/** What a device is told when its table refuses a request. */
export const ONLY_ON_THE_MAC = "This can be done only on the Mac, in the pi² app.";
/** What a device is told for a request outside any session. */
export const OPEN_WITH_FACE_ID = "Open pi² with Face ID.";
/** What any other connection is told for a `remote.*` request. */
export const ONLY_FROM_THE_HELPER = "This is taken only from the pi² Remote this engine started, on the connection it made for it.";

export type DeviceAnswer = "yes" | "face" | "no";
export type DevicePath = "relay" | "home" | "direct" | "mailbox";

/** What `deviceMay` is told of where a request comes from. */
export type DeviceSession = {
	path: DevicePath;
	/** The project switch an approval waiting under `id` asked for, or null for none (or no such approval). */
	approvalSwitch: (id: string) => SwitchName | null;
	/**
	 * Whether the device's copy of the approval waiting under `id` hides part of the call (masked, or too deep), judged
	 * from the engine's own record of it: then the phone did not see the whole call, and may not allow it.
	 */
	approvalHidden: (id: string) => boolean;
};

/** What a device is told when it would allow an approval it was not shown whole. */
export const HIDDEN_FROM_THE_PHONE = "Answer this on the Mac: part of this call is hidden from the phone.";

/** Whether `method` with `params` allows an approval part of which the device was not shown. Denying stays open. */
export function allowsHiddenApproval(method: string, params: Params, session: DeviceSession): boolean {
	const answer = params.answer as Params | null | undefined;
	const decision = method === "inbox.decide" ? params.decision : method === "needs.answer" && typeof answer === "object" && answer?.kind === "approval" ? answer.decision : "deny";
	return decision !== "deny" && typeof params.id === "string" && session.approvalHidden(params.id);
}

type Params = Record<string, unknown>;

type DeviceRow = {
	/** Why a phone may send it, in a line. */
	why: string;
	/** "yes" when left out. */
	may?: (params: Params, session: DeviceSession) => DeviceAnswer;
	/** 4.2's Reading row, which the devices' log leaves out (4.4); with parameters, only those that read. */
	reading?: true | ((params: Params) => boolean);
	/** Whether it may also wait in the relay's mailbox as a sealed item (4.2's last column). */
	mailbox?: (params: Params) => boolean;
};

/** The switches whose approvals are the person's ordinary acts; an approval for any other widens (4.2). */
const NARROW_SWITCHES: ReadonlySet<SwitchName> = new Set<SwitchName>(["startAgents", "fileWork", "closeWork"]);

/** An answer to an approval: once or deny, unless once allows what a widening switch holds back; always and rule widen. */
function approvalAnswer(decision: unknown, id: unknown, session: DeviceSession): DeviceAnswer {
	if (decision === "deny") return "yes";
	if (decision === "always" || decision === "rule") return "face";
	if (decision !== "once") return "no";
	const asked = typeof id === "string" ? session.approvalSwitch(id) : null;
	return asked === null || NARROW_SWITCHES.has(asked) ? "yes" : "face";
}

/** Any request with `confirmLimit` starts work past a limit (4.2, "Answers that widen"). */
const pastALimit = (params: Params): DeviceAnswer => (params.confirmLimit !== undefined ? "face" : "yes");
const always = () => true;

const FROM_A_DEVICE: Record<string, DeviceRow> = {
	// Reading.
	"engine.info": { why: "reading", reading: true },
	"engine.lag": { why: "reading", reading: true },
	"connection.mayAnswer": { why: "reading: it answers false in a device session, with why (4.1)", reading: true },
	"conversation.open": { why: "reading", reading: true },
	"conversation.older": { why: "reading", reading: true },
	"conversation.close": { why: "reading", reading: true },
	"conversations.shown": { why: "reading", reading: true },
	"conversation.image": { why: "reading", reading: true },
	"conversation.export": { why: "reading, and logged, since it copies a transcript out (4.4)" },
	search: { why: "reading", reading: true },
	"submission.get": { why: "reading", reading: true },
	"background.output": { why: "reading", reading: true },
	"changes.list": { why: "reading", reading: true },
	"github.refresh": { why: "reading", reading: true },
	"github.diff": { why: "reading", reading: true },
	"github.unknown": { why: "reading", reading: true },
	"needs.list": { why: "reading", reading: true },
	"projects.list": { why: "reading", reading: true },
	"projects.watch": { why: "reading: it chooses which of a project's tabs this session watches, and attaches nothing (decision 27)", reading: true },
	"work.list": { why: "reading", reading: true },
	"worktree.suggest": { why: "reading", reading: true },
	"branches.refresh": { why: "reading", reading: true },
	"limits.refresh": { why: "reading", reading: true },
	"settings.getCompaction": { why: "reading", reading: true },
	"local.status": { why: "reading", reading: true },
	// Messages, starts and stops.
	submit: {
		why: "a message, as the person sends one at the Mac",
		// Text only, at most 4,000 characters, in the mailbox.
		mailbox: (params) => params.attachments === undefined && typeof params.text === "string" && [...params.text].length <= 4_000,
	},
	continue: { why: "a message's ordinary next step" },
	abort: { why: "stopping only narrows", mailbox: always },
	withdraw: { why: "taking back a queued message" },
	"conversation.create": { why: "a new conversation with an agent the person has; past a limit, it widens", may: pastALimit },
	"chat.continueWithAgent": {
		why: "Continue with an Agent; with an explicit folder it is the Mac's, past a limit it widens",
		may: (params) => (params.cwd != null ? "no" : pastALimit(params)),
	},
	"conversation.compact": { why: "the person's ordinary act" },
	"conversation.reset": { why: "the person's ordinary act" },
	"conversation.edit": { why: "the person's ordinary act" },
	"conversation.version": { why: "the person's ordinary act" },
	"conversation.retry": { why: "Try Again, on the same model or another the person has (4.2, two rows)" },
	"background.stop": { why: "stopping only narrows" },
	"wakes.cancel": { why: "cancelling only narrows" },
	"wakes.resume": { why: "the person's ordinary act; the limits bound it" },
	"reports.wake": { why: "waking never widens; the limits bound it" },
	"schedules.runNow": { why: "running a schedule the person made; past a limit, it widens", may: pastALimit },
	// Names, pins, notes.
	"conversation.rename": { why: "a name" },
	"conversation.pin": { why: "a pin" },
	"conversation.dismissCompactionError": { why: "a notice dismissed" },
	"projects.rename": { why: "a name" },
	"memory.add": { why: "notes never widen (projects.md 7.1)" },
	"memory.edit": { why: "notes never widen" },
	"memory.delete": { why: "notes never widen" },
	// Answers, and answers that widen.
	"inbox.decide": {
		why: "an answer to an approval; always, rule, or once past a widening switch widens",
		may: (params, session) => approvalAnswer(params.decision, params.id, session),
		mailbox: always,
	},
	"inbox.answer": { why: "an answer to an agent's question", mailbox: always },
	"needs.answer": {
		why: "an answer under Needs you; allowing a reach request or Start anyway on a limit widens",
		may: (params, session) => {
			const answer = params.answer as Params | null | undefined;
			if (typeof answer !== "object" || answer === null) return "no";
			switch (answer.kind) {
				case "approval":
					return approvalAnswer(answer.decision, params.id, session);
				case "question":
				case "decision":
				case "rule":
					return "yes";
				case "reach":
					return answer.allow === false ? "yes" : "face";
				case "limit":
					return answer.start === false ? "yes" : "face";
				default:
					return "no";
			}
		},
		mailbox: always,
	},
	"work.act": { why: "what the person does by hand on the board; it merges nothing (4.2); past a limit, it widens", may: pastALimit },
	"github.settle": {
		why: "the person's answer to a write whose outcome is unknown; Not done lets the write be made again, which widens",
		may: (params) => (params.happened === true ? "yes" : "face"),
	},
	"projects.restoreConversation": {
		why: "its dry run reads; restoring puts back what was put away, with its reach, which widens",
		may: (params) => (params.dryRun === true ? "yes" : "face"),
		reading: (params) => params.dryRun === true,
	},
	"chat.set": {
		why: "chat mode's settings; turning the web or memory on, or new instructions, widen",
		may: (params) => (params.web === true || params.memory === true || params.instructions !== undefined ? "face" : "yes"),
	},
	// Changes that narrow, or are the person's ordinary acts.
	"agents.allowEverything": { why: "turning Allow everything off narrows; on is the Mac's alone (question 5)", may: (params) => (params.on === true ? "no" : "yes") },
	"conversation.carryOn": { why: "the person's ordinary act" },
	"conversation.archive": { why: "putting away narrows" },
	"rules.remove": { why: "removing an allowed command narrows" },
	"schedules.delete": { why: "deleting a schedule narrows" },
	"coauthor.set": { why: "the person's ordinary act" },
	// With a folder only once the Mac offers it (projects.folders, #696, P29), which no request does yet.
	// With a template it copies an agent with its reach, as agents.duplicate does, so it widens (decision 27).
	"projects.create": {
		why: "a new project; with a folder only one the Mac offers (P29), until then none; with a template it copies an agent, which widens",
		may: (params) => (params.folder != null ? "no" : params.template != null ? "face" : "yes"),
	},
	"projects.archive": { why: "putting away narrows" },
	"projects.startFresh": { why: "the person's ordinary act" },
	"projects.rules.add": { why: "the person's ordinary act" },
	"work.create": { why: "filing work, as the person does on the board" },
	"worktree.create": { why: "the person's ordinary act" },
	"github.detach": { why: "detaching narrows" },
	"github.sendBack": { why: "the person's ordinary act" },
	"settings.setCompaction": { why: "the person's ordinary act" },
	"settings.setAutoArchive": { why: "the person's ordinary act" },
	"settings.setAwake": { why: "the person's ordinary act" },
	"recovery.dismiss": { why: "a notice dismissed" },
	"limits.dismiss": { why: "a notice dismissed" },
	// A device's own (4.2's last paragraph).
	"devices.self": { why: "its own record and log" },
	"devices.forgetSelf": { why: "it unpairs itself (3.6)" },
	// What it is pushed (7, #689): its own settings, which widen nothing; read alone when sent with none.
	"pushes.set": { why: "its own notifications", reading: (params) => Object.keys(params).length === 0 },
	"pushes.follow": { why: "its own Live Activities" },
	// remote.mailboxIn (#678, P10) is pi² Remote's and goes in FOR_THE_HELPER. projects.folders and files.preview (P29)
	// go here, with their reasons, when they are made.
};

/** What a phone may send that always widens reach: the Mac notifies the person of each (4.4). */
const WITH_FACE_ID: Record<string, string> = {
	"agents.save": "an agent's settings, as the person changes them at the Mac",
	"agents.duplicate": "a copy with the source's reach",
	"agents.delete": "cannot be undone",
	"agents.restore": "puts back what was put away, with its reach",
	"agents.updateFromTemplate": "an agent's settings from a template",
	"conversation.configure": "a conversation's access, folder and model",
	"conversation.fork": "copies the conversation's access, agent and project",
	"conversation.unarchive": "gives an archived conversation back its access",
	"conversation.delete": "cannot be undone",
	"memory.setEnabled": "a memory switch turned on plants what an agent read",
	"rules.add": "an allowed command",
	"schedules.save": "schedules start work with nobody there",
	"usage.setBudget": "raising the budget unbinds spending",
	"changes.undo": "undo can restore what the person narrowed",
	"projects.addAgent": "making an agent",
	"projects.setOrchestrator": "the orchestrator's role carries its switches and tools",
	"projects.set": "the switches of 8.1 and the limits",
	"projects.unarchive": "puts back what was put away, with its reach",
	"projects.delete": "cannot be undone",
	"projects.rules.edit": "a project's rules",
	"projects.rules.move": "a project's rules",
	"projects.rules.remove": "a project's rules",
	"github.attach": "a repository attached",
	"github.merge": "a merge, as the person merges at the Mac",
	"worktree.remove": "cannot be undone",
};

/** What only the Mac may do, with why. `NOT_NAMED`: a handler 4.2 does not name, kept to the Mac until one places it. */
const NOT_NAMED = "not named in 4.2's table";
const MAC_ONLY: Record<string, string> = {
	// Secrets and sign-ins.
	"variables.set": "a secret",
	"variables.remove": "a secret",
	"providers.setKey": "a secret",
	"providers.login": "a sign-in",
	"providers.logout": "a sign-in",
	"providers.addModel": "providers.*",
	"providers.removeModel": "providers.*",
	"providers.setHiddenModels": "providers.*",
	"providers.draftModel": "providers.*",
	"providers.ask": "providers.*",
	"auth.answer": "a sign-in",
	"auth.cancel": "a sign-in",
	"endpoints.save": "endpoints.*",
	"endpoints.remove": "endpoints.*",
	"endpoints.probe": "endpoints.*",
	// The models that spend on pictures.
	"pictures.setModel": "spends on pictures",
	"look.setModel": "spends on pictures",
	// Programs started on the Mac.
	"mcp.save": "a program started on the Mac",
	"mcp.reconnect": "a program started on the Mac",
	"mcp.delete": "a program started on the Mac",
	"mcp.setVariable": "a program started on the Mac",
	"mcp.removeVariable": "a program started on the Mac",
	"local.start": "a program started on the Mac",
	"local.stop": "a program started on the Mac",
	"local.model.try": "a program started on the Mac",
	"local.engine.install": "a program installed on the Mac",
	"local.engine.remove": "a program installed on the Mac",
	"local.model.install": "a program installed on the Mac",
	"local.model.remove": "a program installed on the Mac",
	"local.model.configure": "a program started on the Mac",
	"local.model.folder": "a program started on the Mac",
	"local.download.pause": "a program installed on the Mac",
	"local.download.resume": "a program installed on the Mac",
	"local.download.cancel": "a program installed on the Mac",
	// The app's host roles.
	"computer.register": "the app's host role",
	"computer.result": "the app's host role",
	"browser.register": "the app's host role",
	"browser.result": "the app's host role",
	// The Mac's upkeep.
	"backup.create": "the Mac's upkeep",
	"priority.set": "the Mac's upkeep",
	"settings.finishOnboarding": "the Mac's upkeep",
	"projects.carryOver": "the Mac's upkeep",
	"projects.retrySecrets": "the Mac's upkeep",
	// Throwaway copies.
	"test-copy.answerer": "test-copy.*",
	"test-copy.fill": "test-copy.*",
	"test-copy.fillProject": "test-copy.*",
	// Every devices.* request but devices.self and devices.forgetSelf: pairing, and what decides who the person is.
	"devices.watch": "devices.*",
	"devices.set": "devices.*",
	"devices.pairStart": "devices.*",
	"devices.pairCancel": "devices.*",
	"devices.pairConfirm": "devices.*",
	"devices.rename": "devices.*",
	"devices.revoke": "devices.*",
	"devices.resume": "devices.*",
	"devices.log": "devices.*",
	"devices.acceptPresenceKey": "devices.*", // a phone never accepts its own new Face ID key, nor another's (3.2)
	"devices.refusePresenceKey": "devices.*",
	// The handlers the table does not name, listed for the owner in #673's pull request.
	"github.show": NOT_NAMED,
	"settings.setAgentDefault": NOT_NAMED,
};

/**
 * pi² Remote's own requests, taken only on the connection the engine made for the helper it started (5.5), never on
 * its listening socket and never in a device session. remote.mailboxIn (#678, P10) is added here when it is made.
 */
const FOR_THE_HELPER: ReadonlySet<string> = new Set(["remote.hello", "remote.state", "remote.pairClaim", "remote.pairWrong", "remote.pairRefused", "remote.attachBegin", "remote.attach", "remote.sessionEnd", "remote.presenceKey", "remote.pushRefused"]);

export function forTheHelper(method: string): boolean {
	return FOR_THE_HELPER.has(method);
}

/**
 * Whether a device may send `method` with `params`, from `session`: "yes", "face" (it widens reach) or "no". What the
 * table does not hold is "no". From the mailbox, only what its row lets wait there (5.3).
 */
export function deviceMay(method: string, params: Params, session: DeviceSession): DeviceAnswer {
	if (FOR_THE_HELPER.has(method) || allowsHiddenApproval(method, params, session)) return "no";
	if (Object.hasOwn(WITH_FACE_ID, method)) return session.path === "mailbox" ? "no" : "face";
	if (!Object.hasOwn(FROM_A_DEVICE, method)) return "no";
	const row = FROM_A_DEVICE[method]!;
	if (session.path === "mailbox" && row.mailbox?.(params) !== true) return "no";
	return row.may?.(params, session) ?? "yes";
}

/** Whether a request from a device goes in the devices' log: all but 4.2's Reading row (4.4). */
export function deviceLogged(method: string, params: Params): boolean {
	const reading = Object.hasOwn(FROM_A_DEVICE, method) ? FROM_A_DEVICE[method]!.reading : undefined;
	return reading === undefined ? true : reading !== true && !reading(params);
}

export type DevicePlacement = "FROM_A_DEVICE" | "WITH_FACE_ID" | "MAC_ONLY" | "FOR_THE_HELPER";

/** Which device list holds `method`, and its reason there: for the tests, and for the pull request's list. */
export function devicePlacement(method: string): { list: DevicePlacement; why: string } | null {
	if (Object.hasOwn(FROM_A_DEVICE, method)) return { list: "FROM_A_DEVICE", why: FROM_A_DEVICE[method]!.why };
	if (Object.hasOwn(WITH_FACE_ID, method)) return { list: "WITH_FACE_ID", why: WITH_FACE_ID[method]! };
	if (Object.hasOwn(MAC_ONLY, method)) return { list: "MAC_ONLY", why: MAC_ONLY[method]! };
	if (FOR_THE_HELPER.has(method)) return { list: "FOR_THE_HELPER", why: "pi² Remote's own" };
	return null;
}

/** The requests that answer for the person or change what they set, which a device's table must place with care. */
export const PERSON_REQUESTS: readonly string[] = [...Object.keys(FOR_THE_PERSON), ...Object.keys(FOR_THE_PERSON_SETTINGS)];

const DEVICE_LISTS: readonly ReadonlySet<string>[] = [new Set(Object.keys(FROM_A_DEVICE)), new Set(Object.keys(WITH_FACE_ID)), new Set(Object.keys(MAC_ONLY))];

/** The requests only a throwaway copy's engine has (main.ts): listed, and absent from every other engine. */
const ONLY_IN_TEST_COPIES: ReadonlySet<string> = new Set(["test-copy.answerer", "test-copy.fill", "test-copy.fillProject"]);

/**
 * Validate the device lists against the completed tables before serving requests (4.1): every handler of the socket
 * in exactly one of FROM_A_DEVICE, WITH_FACE_ID and MAC_ONLY, and in no FOR_THE_HELPER; every handler of the helper's
 * connection in FOR_THE_HELPER alone, and in no request class above, so that no other connection can reach one. And
 * every name in a list has its handler: nothing is placed for a device ahead of the request it names, which would let
 * that request through from a phone the day it is added (but a test copy's own, which other engines have not).
 */
export function checkDeviceLists(methods: Iterable<string>, helperMethods: Iterable<string>, lists = DEVICE_LISTS, helper = FOR_THE_HELPER): void {
	const mistakes: string[] = [];
	const handled = new Set(methods);
	const helperHandled = new Set(helperMethods);
	for (const list of lists) {
		for (const method of list) if (!handled.has(method) && !ONLY_IN_TEST_COPIES.has(method)) mistakes.push(`${method} is in a device list and has no handler`);
	}
	for (const method of helper) if (!helperHandled.has(method)) mistakes.push(`${method} is in FOR_THE_HELPER and has no handler on pi² Remote's connection`);
	for (const method of handled) {
		const count = lists.filter((list) => list.has(method)).length;
		if (count !== 1) mistakes.push(`${method} belongs to ${count} device lists (expected one)`);
		if (helper.has(method)) mistakes.push(`${method} is pi² Remote's (FOR_THE_HELPER), and cannot be a handler of the socket`);
	}
	for (const method of helperHandled) {
		if (!helper.has(method)) mistakes.push(`${method} is a handler of pi² Remote's connection, and is not in FOR_THE_HELPER`);
		if (lists.some((list) => list.has(method)) || REQUEST_CLASSES.some((list) => list.has(method))) {
			mistakes.push(`${method} is pi² Remote's, and is in a list of the socket's requests too`);
		}
	}
	if (mistakes.length > 0) throw new Error(`Device lists in answers.ts:\n${mistakes.join("\n")}`);
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
		// A Mac under load can hold the helper past its limit (#707). Refusing the app then would tell the person that only
		// they can do what they just did, in the app they did it in; so a helper that did not answer is asked once more.
		const first = await this.#askHelper(socket, helper, bundle);
		if (!first.slow) return first;
		this.#log("answers:", first.verdict.why, "(asking once more)");
		return this.#askHelper(socket, helper, bundle);
	}

	/** One run of the helper. `slow`: it did not answer within the limit, and was stopped. */
	#askHelper(socket: Socket, helper: string, bundle: string): Promise<{ verdict: Verdict; lasting: boolean; slow?: boolean }> {
		return new Promise((resolve) => {
			const unchecked = (why: string, slow = false) => resolve({ verdict: { app: false, why: `the connection could not be checked: ${why}` }, lasting: false, slow });
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
				unchecked(`${helper} did not answer within ${this.#patienceMs / 1000} seconds`, true);
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
