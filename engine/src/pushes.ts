// What the engine pushes to each paired phone, and when (docs/iphone.md 7, #689): the engine chooses, pi² Remote seals,
// the relay sends. Each choice goes to pi² Remote as the `remote` event's `push` (remote.ts sends it, on its control
// connection alone): `alert` and `background`, whose `body` pi² Remote seals for the device and pads to one of the
// relay's three sizes, and `activity`, a Live Activity's numbers, which the system reads and which are never sealed.
//
// What is pushed follows the events the Mac's own notifications follow (app/Sources/pi2/Notifier.swift): a new item in
// Needs you (the `needs` event, which holds the Inbox's approvals and questions too), a provider's limit reached or
// carried on past (the `limits` event's notices, at those two stages only), and, for a message the person sent from
// the phone with Tell me when it answers on, the orchestrator's finished answer. When an item it was told of is
// answered or withdrawn, the device gets a background push so that it takes the notification away. Nothing is pushed
// of what waited when the engine started (as the Mac's notifications do not), nothing to a revoked or suspended
// device, and nothing while remote access is off. A device's own settings (`pushes.set`) turn needs, limits and
// answers off, and quiet a project's needs and answers.
//
// What a push may say is less than what the channel carries (5.7): an alert's text is the card's title and short line,
// built from the item as a device's copy of it is built, through `maskValue` (key shapes, and the values of the secrets
// the engine knows, secrets.ts), with an approval walked from
// APPROVAL_DEPTH wherever it sits and marked `partHidden` as the channel marks it, or as the gate judges the engine's
// own record (`hidesSomething`), whichever hides more. So a push never shows what the channel hides, and never offers
// as whole an approval the gate treats as partly hidden. A run that reads as a token is hidden in the notification's
// text alone (`shown`). Never an output, a file, a diff, or any transcript text.
//
// The engine keeps no push token: the relay holds each device's, and each Live Activity's (5.3). The engine names a
// device by its id and an activity by the phone's own id for it.

import type { Client } from "./clients.ts";
import { broadcastWatchers } from "./clients.ts";
import { isChat } from "./chat.ts";
import { activeDevices, hidesSomething, maskKeys, maskValue, PART_HIDDEN, pairedDevice, remoteHooks, remoteOn, revokedWatchers, unhidden } from "./devices.ts";
import type { Feature } from "./features.ts";
import type { NeedItem } from "./needs.ts";
import { orchestratorRole } from "./orchestrator.ts";
import { allProjects, projectOf } from "./projects.ts";
import { SECRET_HIDDEN } from "./secrets.ts";
import { runsAs } from "./state.ts";
import { defineDoc } from "@earendil-works/pi-durable";

// ---- Shapes (docs/iphone.md 7, "What the engine pushes")

/** The category of an alert, which the phone's notification service extension sets from inside the seal (7's table). */
export type Category = "pi2.approval" | "pi2.question" | "pi2.decision" | "pi2.reach" | "pi2.rule" | "pi2.limit" | "pi2.notice";

/** What an alert says, sealed by pi² Remote: the notification service extension shows it, and nothing else. */
export type AlertBody = {
	v: 1;
	/** A new item in Needs you, a provider's limit, or the orchestrator's answer the person asked to be told of. */
	type: "need" | "limit" | "answer";
	category: Category;
	title: string;
	/** The project's name, when it is about one. */
	subtitle?: string;
	body: string;
	/** The project, for the notification's thread. */
	projectId?: string;
	/** The item in Needs you, which the phone opens on. */
	need?: string;
	conversationId?: number;
	/**
	 * The body shows the item's whole text, uncut, with nothing hidden: an approval's whole call, a question, a rule's
	 * text. Only then may the phone offer Allow once, Reply or Accept on the notification (7's table).
	 */
	whole: boolean;
	/** Masking hid part of it, or part was too deep to walk, or the gate judges the approval partly hidden: never allowed from a phone. */
	partHidden?: true;
	/** The provider's own time a limit's runs wait until, ms since 1970, for the phone to show in its own time zone. */
	until?: number;
	/** When the engine chose it, ms since 1970. */
	at: number;
};

/** A background push: the items the device was told of that no longer wait, so it takes their notifications away. */
export type GoneBody = { v: 1; type: "gone"; needs: string[]; at: number };

/** A Live Activity's numbers, exactly: the relay and Apple read them, so nothing here is ever text. */
export type Counts = { working: number; needs: number; finished: number; at: number };

/**
 * The `remote` event's `push`, `{ event: "remote", kind: "push", push }`. `id` names it in pi² Remote's answer when the
 * relay refuses it (`remote.pushRefused`). `collapse` is the item's own id, which pi² Remote turns into the relay's
 * collapse id (an HMAC keyed per pairing and device, 7), so that a second alert about the same thing replaces the
 * first; it never reaches the relay as it is.
 */
export type Push =
	| { id: string; device: string; kind: "alert"; collapse: string; body: AlertBody }
	| { id: string; device: string; kind: "background"; body: GoneBody }
	| { id: string; device: string; kind: "activity"; activity: string; event: "update" | "end"; state: Counts };

export type PushKind = Push["kind"];
/** A push before the engine names it and its device. */
type Unaddressed = Push extends infer One ? (One extends Push ? Omit<One, "id" | "device"> : never) : never;

/** Why the relay refused a push, as pi² Remote passes it on (relay/README.md, "Pushes"). */
export const REFUSALS = ["no-token", "token-dead", "push-limit", "push-later", "unavailable", "unknown-device"] as const;
export type Refusal = (typeof REFUSALS)[number];
/**
 * pi² Remote's own words for a push it will never send as it is, however often it is asked (7.1): a body that does not
 * fit the largest sealed push, and one not as 7.1 writes it. That one push is dropped (#914); nothing else is held back.
 */
export const DROPPED = ["too-large", "malformed"] as const;

/** A Live Activity a device follows: the phone's own id for it (16 bytes, base64url) and the project it shows. */
export type Follow = { projectId: string; activity: string; since: number };

/** A device's own settings for what it is pushed. Every switch is on until the phone turns it off. */
export type PushSettings = { needs: boolean; limits: boolean; answers: boolean; quiet: string[]; follows: Follow[] };

const defaults = (): PushSettings => ({ needs: true, limits: true, answers: true, quiet: [], follows: [] });

// ---- Bounds

const MINUTE = 60_000;
const HOUR = 60 * MINUTE;

/** The most characters of an alert's title, subtitle and body (7: the body at most 180), an ellipsis ending one cut. */
export const MAX_TITLE = 80;
export const MAX_SUBTITLE = 64;
export const MAX_BODY = 180;
/**
 * The most bytes of an alert's or a background push's body as JSON text. pi² Remote seals it, signs it and pads it to
 * 696, 1,464 or 3,000 bytes (relay/src/apns.ts, `SEALED_SIZES`); this leaves it 1,000 bytes of the largest for HPKE's
 * encapsulated key and tag, the Mac's signature and its own framing. The bounds above keep every body under it (the
 * pushes test makes the largest one); a body over it is cut further, never sent whole.
 */
export const MAX_BODY_BYTES = 2_000;
/**
 * The most pushes of each kind the engine asks for to one device in an hour, under the relay's 120 alerts, 60
 * background pushes and 60 Live Activity updates (iphone.md 6.6): the relay's limit is never what stops them. Past one,
 * alerts wait their turn (the latest MAX_OWED at most, and needs only while they still wait), the items gone wait to be
 * named together in the next background push, and a Live Activity gets its latest numbers when the hour allows.
 */
export const HOURLY: Readonly<Record<PushKind, number>> = { alert: 100, background: 50, activity: 50 };
/** A Live Activity is sent its numbers at most once a minute, the latest ones. */
export const ACTIVITY_EVERY_MS = MINUTE;
/** A followed project ends its Live Activity once idle (nothing working, nothing waiting) this long, so that a moment between two runs does not. */
export const IDLE_FOR_MS = 30_000;
/** At most this many Live Activities a device follows: one a project, as the phone starts them. */
export const MAX_FOLLOWS = 5;
/** A Live Activity is forgotten 12 hours after it was followed: iOS ends one after 8 hours, and the relay drops its token after 12. */
export const FOLLOW_KEPT_MS = 12 * HOUR;
/** Each count of a Live Activity, as the relay takes it. */
export const MAX_COUNT = 99_999;
/** Alerts waiting their turn for one device, the oldest dropped first: more than an hour's, so a burst is cut only past it. */
export const MAX_OWED = 200;
/** Answers waited for at once by one device, and how long one is waited for. */
const MAX_ANSWERS = 10;
const ANSWER_KEPT_MS = 6 * HOUR;
/** The items told of, remembered for each device so that their going can be pushed. */
const TOLD_KEPT = 200;
/** Items gone within this long of each other are named in one background push. */
export const GONE_TOGETHER_MS = 2_000;
const MAX_GONE = 50;
/** How long a push's id is remembered for pi² Remote's answer. */
const ASKED_KEPT_MS = 10 * MINUTE;
const MAX_ASKED = 500;
/** How long a refusal holds pushes of its kind to the device; `null`: until the phone next attaches. */
export const HOLDS: Readonly<Record<Refusal, number | null>> = {
	"no-token": null,
	"token-dead": null,
	"unknown-device": null,
	"push-later": MINUTE,
	"push-limit": 15 * MINUTE,
	unavailable: HOUR,
};
/** While pi² Remote is not running, what is owed is looked at again this often. */
const NOT_READY_RETRY_MS = 30_000;

// ---- What an alert says

/**
 * A run that may be a key or a token with no known prefix (7): 32 or more of base64's characters, base64url's too, with
 * a letter and a digit among them, and at least 4.25 bits a character (`highEntropy`). Hex (a commit's hash, a UUID)
 * has at most 4 bits a character, so it is never one; a random token of 32 letters and digits has about 4.6.
 */
const TOKEN_RUN = /[A-Za-z0-9+/=_-]{32,}/g;
export const TOKEN_RUN_BITS = 4.25;

/** Whether `run` reads as random: a letter and a digit in it, and TOKEN_RUN_BITS a character or more. */
export function highEntropy(run: string): boolean {
	if (!/[A-Za-z]/.test(run) || !/[0-9]/.test(run)) return false;
	const counts = new Map<string, number>();
	for (const character of run) counts.set(character, (counts.get(character) ?? 0) + 1);
	let bits = 0;
	for (const count of counts.values()) bits -= (count / run.length) * Math.log2(count / run.length);
	return bits >= TOKEN_RUN_BITS;
}

/**
 * `text` as a notification shows it, at most `max` characters: what is not shown taken out first, then every key shape
 * and every secret the engine knows masked (`maskKeys`, so that a key split by a zero-width character is hidden whole
 * once joined), then every run that reads as a token (`highEntropy`) shown as SECRET_HIDDEN, then cut. Says whether
 * anything was taken out or turned into something else (`changed`), masked here (`masked`), shown as a token
 * (`tokenLike`), or cut.
 *
 * A token-like run is hidden in the notification alone, which a Lock Screen can show: the channel carries what agents
 * ran (5.7), so the card in the app shows the run, and the gate does not judge it. So it makes the alert not whole (no
 * Allow once, Reply or Accept on the notification), but not `partHidden`: the person allows it in the app, having seen
 * it. Commit hashes, ids and base64 are everywhere in what agents run, and an approval that holds one stays answerable.
 */
export function shown(text: string, max: number): { text: string; cut: boolean; changed: boolean; masked: boolean; tokenLike: boolean } {
	// What a notification shows as nothing, or as something other than what is there, taken out, its lines kept: the
	// devices' log's own set (`unhidden`, devices.ts), a wider one than RemoteKit's `ShownText` refuses in a name. Each
	// of these but a line break kept changes the text.
	const cleaned = unhidden(text, "kept");
	const changed = cleaned !== text;
	const unmasked = maskKeys(cleaned);
	const masked = unmasked !== cleaned;
	const plain = unmasked.replace(TOKEN_RUN, (run) => (highEntropy(run) ? SECRET_HIDDEN : run));
	const tokenLike = plain !== unmasked;
	const points = [...plain];
	if (points.length <= max) return { text: plain, cut: false, changed, masked, tokenLike };
	return { text: `${points.slice(0, max - 1).join("")}…`, cut: true, changed, masked, tokenLike };
}

/** The arguments' fields a call's one line is taken from, in this order, as the app's `ToolCall.summary` takes them. */
const CALL_FIELDS = ["command", "path", "task", "code", "question"] as const;

/** A call's one line, and whether it is the whole call: the field it names, when that is all there is; else the call as JSON. */
function callLine(argumentsValue: unknown): { line: string; whole: boolean } {
	if (typeof argumentsValue === "object" && argumentsValue !== null && !Array.isArray(argumentsValue)) {
		const fields = argumentsValue as Record<string, unknown>;
		for (const name of CALL_FIELDS) {
			const value = fields[name];
			if (typeof value === "string") return { line: value, whole: Object.keys(fields).length === 1 };
		}
	}
	return { line: JSON.stringify(argumentsValue) ?? "", whole: true };
}

/**
 * The tools whose approval card the Mac puts in words, or shows more of than the call's line (InboxCard): an app, a site, a schedule's timing and prompt, a sub-chat's task.
 * The app's `InboxCard.inWords` (app/Sources/pi2/InboxViews.swift) names the same tools: change the two together.
 */
const SHOWN_IN_WORDS: ReadonlySet<string> = new Set(["computer", "browser", "schedule_task", "delegate"]);

type Approval = Extract<NeedItem, { kind: "approval" }>;
/**
 * Every member of an approval in Needs you, by what the alert makes of it: an allow-list, as `TO_A_DEVICE` is for the
 * events a device is sent (remote.ts). An approval with a member not named here is never whole, and a member added to
 * the type fails the type-check here until it is placed.
 * - "said": in the alert's body. The tool; its call's one line, whole only when that is all the call holds (`callLine`);
 *   a question, which makes the alert not whole when it stands in place of the call.
 * - "frame": who asks and where, which the alert's title (the agent's name, the kind's words) and subtitle (the project)
 *   say, or which says nothing of what is asked: the ids, the conversation's titles (the card's source line, the
 *   conversation a tap opens), whether the agent is held, and when it asked.
 * - "answers": what the person may answer, not what is asked: the answers it takes, and the rule "Always Allow" would
 *   make of a command (InboxCard's buttons).
 * - "more": a line of its own on the Mac's card that the alert does not show (left running, the site, when, the switch
 *   that asked): whole only without it.
 */
const APPROVAL_MEMBERS: Record<keyof Approval, "said" | "frame" | "answers" | "more"> = {
	kind: "frame",
	id: "frame",
	projectId: "frame",
	conversationId: "frame",
	rootConversationId: "frame",
	title: "frame",
	rootTitle: "frame",
	agentId: "frame",
	agentName: "frame",
	blocking: "frame",
	createdAt: "frame",
	tool: "said",
	arguments: "said",
	question: "said",
	answers: "answers",
	rule: "answers",
	background: "more",
	site: "more",
	when: "more",
	projectSwitch: "more",
};
/** Whether each member of `fields` is placed in APPROVAL_MEMBERS, and none of those with a line of their own on the card is there. */
const approvalAllKnown = (fields: Record<string, unknown>) =>
	Object.keys(fields).every((member) => Object.hasOwn(APPROVAL_MEMBERS, member) && (APPROVAL_MEMBERS[member as keyof Approval] !== "more" || fields[member] === undefined));
const BINDS: Record<string, string> = { orchestrator: "the orchestrator", everyone: "every agent" };

const TITLES: Record<NeedItem["kind"], [suffix: string, category: Category]> = {
	approval: ["needs approval", "pi2.approval"],
	question: ["has a question", "pi2.question"],
	decision: ["has a question", "pi2.decision"],
	reach: ["asks for more reach", "pi2.reach"],
	rule: ["proposes a rule", "pi2.rule"],
	limit: ["is held back by a limit", "pi2.limit"],
};

/**
 * An alert for an item in Needs you, as `item` is in the `needs` event. The item is masked first, whole, as a device's
 * copy is (`maskValue`, an approval from APPROVAL_DEPTH), and the text taken from the masked copy, then cleaned, masked
 * again and cut (`shown`): cutting after masking never leaves part of a key that masking would have hidden whole.
 * `gate` is the gate's own judgement of the engine's record of the approval (answers.ts, `approvalHidden`), which
 * marks it too.
 *
 * `whole` means the alert says the same facts of what is asked as the Mac's own card for it (app/Sources/pi2:
 * `InboxCard`, `NeedCard`, `RuleProposalCard`), and nothing of them was changed, taken out, masked or cut: an
 * approval's tool and its whole call, when the card shows no more than that (no question in its place, no tool the card
 * puts in words, no line for running in the background, a site, a schedule's timing or the switch that asked, no
 * argument beyond the one the line shows, and no member APPROVAL_MEMBERS does not place); a question; a rule's text
 * and whom it binds, when no reason is given; a reach request's summary, when no reason is given. A decision (its choices) and a limit card (its reason) are never
 * whole. The card's frame (who asks, in which project) is the alert's title and subtitle.
 */
export function needAlert(item: NeedItem, gate: boolean, project: string | undefined, at: number): AlertBody {
	const masking = { hidden: false };
	// From the top, as the gate walks the engine's record (`hidesSomething`): an approval's insides from APPROVAL_DEPTH.
	const copy = maskValue(item, masking) as Record<string, unknown>;
	const text = (value: unknown) => (typeof value === "string" ? value : "");
	let line: string;
	let whole = true;
	switch (item.kind) {
		case "approval": {
			// The tool and its call's summary (7), as "bash: npm test".
			const call = callLine(copy.arguments);
			const question = copy.question;
			line = `${text(copy.tool) || "a tool"}: ${typeof question === "string" ? question : call.line}`;
			const fields = item as unknown as Record<string, unknown>;
			whole = typeof question !== "string" && call.whole && !SHOWN_IN_WORDS.has(item.tool) && approvalAllKnown(fields);
			break;
		}
		case "question":
			line = text(copy.question);
			break;
		case "decision":
			line = text(copy.question);
			whole = false;
			break;
		case "reach":
			line = text((copy.change as Record<string, unknown> | undefined)?.summary) || "Asks for more reach";
			whole = copy.why == null && line === text((copy.change as Record<string, unknown> | undefined)?.summary);
			break;
		case "rule":
			line = `Proposes a rule for ${Object.hasOwn(BINDS, text(copy.binds)) ? BINDS[text(copy.binds)] : "every agent"}: ${text(copy.text)}`;
			whole = copy.why == null && Object.hasOwn(BINDS, text(copy.binds));
			break;
		case "limit": {
			const start = (copy.start ?? {}) as Record<string, unknown>;
			const what = [text(start.title), text(start.task)].filter((one) => one !== "").join(": ");
			line = what === "" ? "A start is held back by the project's limit" : `Held back by the limit: ${what}`;
			whole = false;
			break;
		}
		default:
			line = "Something needs you";
	}
	const [suffix, category] = TITLES[item.kind] ?? ["needs you", "pi2.notice"];
	const who = typeof copy.agentName === "string" && copy.agentName !== "" ? copy.agentName : "An agent";
	const hidden = gate || copy[PART_HIDDEN] === true || masking.hidden;
	return finish(
		{
			v: 1,
			type: "need",
			category,
			title: `${who} ${suffix}`,
			...(project === undefined ? {} : { subtitle: project }),
			body: line,
			...(item.projectId === null ? {} : { projectId: item.projectId }),
			need: item.id,
			conversationId: item.conversationId,
			whole: whole && !hidden,
			...(hidden ? { partHidden: true as const } : {}),
			at,
		},
		true,
	);
}

/** A provider's limit notice as the `limits` event has it, the fields an alert reads. */
export type LimitNoticeLike = {
	id: string;
	name: string;
	plan: string | null;
	label: string;
	stage?: string;
	reachedAt?: number;
	carriedOnAt?: number;
	waiting?: number;
	until?: number;
	told?: boolean;
	runs?: unknown[];
	more?: number;
};

/** An alert for a provider's limit reached, or work carried on past it, in the Mac's notification's words, less the clock time. */
export function limitAlert(notice: LimitNoticeLike, at: number): AlertBody | null {
	const subject = `${notice.name}${notice.plan === null ? "" : ` ${notice.plan}`}${notice.label === "" ? "" : `, ${notice.label.slice(0, 1).toLowerCase()}${notice.label.slice(1)}`}`;
	const count = (notice.runs?.length ?? 0) + (notice.more ?? 0);
	const one = (notice.waiting ?? count) === 1;
	let title: string;
	let body: string;
	if (notice.stage === "reached") {
		title = `${subject}: limit reached`;
		const waits = one ? "1 run waits" : `${notice.waiting ?? count} runs wait`;
		body =
			notice.told === true && notice.until !== undefined
				? `${waits} until the time ${notice.name} named, then ${one ? "carries" : "carry"} on by ${one ? "itself" : "themselves"}.`
				: `${waits} and ${one ? "asks" : "ask"} again by ${one ? "itself" : "themselves"}; ${notice.name} named no time.`;
	} else if (notice.stage === "carried_on") {
		title = `${subject}: carrying on`;
		body = `${notice.name} answers again. ${count === 1 ? "The run that waited carries" : `The ${count} runs that waited carry`} on by ${count === 1 ? "itself" : "themselves"}.`;
	} else return null;
	return finish({ v: 1, type: "limit", category: "pi2.notice", title, body, whole: false, ...(notice.told === true && notice.until !== undefined ? { until: notice.until } : {}), at }, false);
}

/** An alert that the orchestrator answered the person's message. Never the answer's words: they are transcript text (7). */
export function answerAlert(agent: string | null, project: { id: string; name: string } | undefined, conversationId: number, at: number): AlertBody {
	return finish(
		{
			v: 1,
			type: "answer",
			category: "pi2.notice",
			title: `${agent ?? "The orchestrator"} answered`,
			...(project === undefined ? {} : { subtitle: project.name, projectId: project.id }),
			body: "Open pi² to read the answer.",
			conversationId,
			whole: false,
			at,
		},
		false,
	);
}

/**
 * The texts cut to their bounds, and the whole body masked again: an alert is never sent with a key-shaped string in
 * it, wherever its text came from, and one that had to be masked here, cut, or cleaned of what a notification would
 * not show is no longer whole. A body still over MAX_BODY_BYTES as JSON is cut further.
 */
function finish(body: AlertBody, wholeMatters: boolean): AlertBody {
	const title = shown(body.title, MAX_TITLE);
	const subtitle = body.subtitle === undefined ? undefined : shown(body.subtitle, MAX_SUBTITLE);
	let text = shown(body.body, MAX_BODY);
	const altered = [title, subtitle, text].some((one) => one !== undefined && (one.changed || one.masked || one.tokenLike || one.cut));
	const maskedHere = [title, subtitle, text].some((one) => one?.masked === true);
	const out: AlertBody = { ...body, title: title.text, body: text.text, ...(subtitle === undefined ? {} : { subtitle: subtitle.text }) };
	for (let max = MAX_BODY; Buffer.byteLength(JSON.stringify(out)) > MAX_BODY_BYTES && max > 8; max = Math.floor(max / 2)) {
		text = shown(body.body, max);
		out.body = text.text;
		out.title = shown(body.title, Math.min(MAX_TITLE, max)).text;
		if (out.subtitle !== undefined) out.subtitle = shown(body.subtitle!, Math.min(MAX_SUBTITLE, max)).text;
		text.cut = true;
	}
	const masking = { hidden: false };
	const masked = maskValue(out, masking) as AlertBody;
	// A copy without a prototype (maskValue's) is written as JSON as a plain one is; spread back into one for the reader.
	const result: AlertBody = { ...masked };
	if (wholeMatters && (masking.hidden || maskedHere || altered || text.cut)) result.whole = false;
	if (wholeMatters && (masking.hidden || maskedHere)) result.partHidden = true;
	return result;
}

// ---- The choice

/** What the choice needs of the engine, given so that the pushes test can play the rest. */
export type PushParts = {
	now(): number;
	/** The paired devices, not revoked, with whether each is suspended and when it last attached. */
	devices(): readonly { id: string; suspendedAt: number | null; lastSeenAt: number | null }[];
	/** Whether a push can go now: remote access on, and pi² Remote running and said hello. */
	ready(): boolean;
	send(push: Push): void;
	/** Look at what waits again at `at` or soon after (`flush`). */
	wake(at: number): void;
	/** The settings changed: store them. */
	saved(settings: Record<string, PushSettings>): void;
	projectName(id: string): string | undefined;
	/** The gate's own judgement of the approval waiting under `id` (answers.ts, `approvalHidden`). */
	approvalHidden(id: string): boolean;
	/** A conversation's project and whether it is chat mode's, for the counts. */
	conversation(id: number): { projectId: string | null; chat: boolean } | undefined;
	/** The current conversation with a project's orchestrator: its project and the orchestrator's name; else undefined. */
	orchestrator(id: number): { projectId: string; agent: string | null } | undefined;
	/** Says something in engine.log. */
	log?(text: string): void;
};

type Owed = { collapse: string; need?: string; make: () => AlertBody | null; settingOn: (settings: PushSettings) => boolean };
type Gone = { needs: Set<string>; due: number };
type Hold = { until: number | null; since: number };
type Activity = { sent: Omit<Counts, "at"> | null; sentAt: number; idleSince: number | null; finished: number; held: Hold | null };
type Asked = { device: string; kind: PushKind; at: number; needs?: string[]; owed?: Owed[]; follow?: Follow };

const sameCounts = (a: Omit<Counts, "at"> | null, b: Omit<Counts, "at">) => a !== null && a.working === b.working && a.needs === b.needs && a.finished === b.finished;
const capped = (count: number) => Math.min(Math.max(0, Math.floor(count)), MAX_COUNT);

export class Pushes {
	readonly #parts: PushParts;
	#settings = new Map<string, PushSettings>();
	/** The ids in Needs you when last told, or null before the first `needs` event: what waited then is not pushed. */
	#waiting: Map<string, NeedItem> | null = null;
	/** When the choice began: a limit's stage reached before it is not pushed. */
	readonly #began: number;
	/** The limit notices' stages pushed, as `id stage`. */
	#stages = new Set<string>();
	/** The runs going, with their project, as `runsChanged` last said; null before it first did. */
	#working: Map<number, string | null> | null = null;
	#owed = new Map<string, Owed[]>();
	#told = new Map<string, string[]>();
	#gone = new Map<string, Gone>();
	#answers = new Map<string, { conversationId: number; at: number; seen: boolean }[]>();
	#activities = new Map<string, Activity>();
	#sent = new Map<string, number[]>();
	#holds = new Map<string, Hold>();
	#asked = new Map<string, Asked>();
	#next = 0;

	/** Whether the stored settings are read: until then an event only sets what waits, and nothing is chosen. */
	#loaded = false;
	/** The last `limits` event before the settings were read, chosen once they are. */
	#limitsBefore: readonly LimitNoticeLike[] | null = null;

	/** `stored`: the settings as stored; without it, nothing is chosen until `load` gives them. */
	constructor(parts: PushParts, stored?: Record<string, PushSettings>) {
		this.#parts = parts;
		this.#began = parts.now();
		if (stored !== undefined) this.load(stored);
	}

	/** The settings as stored, read at start; then what came meanwhile is chosen as it would have been. */
	load(stored: Record<string, PushSettings>): void {
		this.#read(stored);
		this.#loaded = true;
		const limits = this.#limitsBefore;
		this.#limitsBefore = null;
		if (limits !== null) this.limits(limits);
		this.flush();
	}

	/** A device revoked: its settings, its Live Activities and all that waited for it go, at once. */
	forget(device: string): void {
		for (const map of [this.#owed, this.#told, this.#gone, this.#answers] as Map<string, unknown>[]) map.delete(device);
		// Its pushes awaiting the relay's answer too: a late refusal would put settings back in memory for it.
		for (const [id, asked] of this.#asked) if (asked.device === device) this.#asked.delete(id);
		for (const map of [this.#activities, this.#sent, this.#holds] as Map<string, unknown>[]) for (const key of [...map.keys()]) if (key.startsWith(`${device}:`)) map.delete(key);
		if (this.#settings.delete(device)) this.#parts.saved(Object.fromEntries(this.#settings));
	}

	#read(stored: Record<string, PushSettings>): void {
		for (const [device, settings] of Object.entries(stored)) {
			if (typeof settings !== "object" || settings === null) continue;
			const own = { ...defaults(), ...settings };
			if (!Array.isArray(own.quiet) || !Array.isArray(own.follows)) continue;
			this.#settings.set(device, own);
		}
	}

	// -- The device's own settings

	/** A device's settings, as `pushes.set` answers them. */
	settings(device: string): Omit<PushSettings, "follows"> & { follows: { projectId: string; activity: string }[] } {
		const { needs, limits, answers, quiet, follows } = this.#own(device);
		return { needs, limits, answers, quiet: [...quiet], follows: follows.map(({ projectId, activity }) => ({ projectId, activity })) };
	}

	#own(device: string): PushSettings {
		return this.#settings.get(device) ?? defaults();
	}

	#store(device: string, settings: PushSettings): void {
		this.#settings.set(device, settings);
		this.#parts.saved(Object.fromEntries(this.#settings));
	}

	/** `pushes.set { needs?, limits?, answers?, project?: { id, quiet } }`: the device's switches; with none, they are only read. */
	set(device: string, params: Record<string, unknown>): ReturnType<Pushes["settings"]> {
		for (const key of Object.keys(params)) if (!["needs", "limits", "answers", "project"].includes(key)) throw new Error(`Unknown setting: ${key}`);
		const next = structuredClone(this.#own(device));
		for (const key of ["needs", "limits", "answers"] as const) {
			if (params[key] === undefined) continue;
			if (typeof params[key] !== "boolean") throw new Error(`${key} is on or off`);
			next[key] = params[key];
		}
		if (params.project !== undefined) {
			const project = params.project as Record<string, unknown> | null;
			if (typeof project !== "object" || project === null || typeof project.id !== "string" || typeof project.quiet !== "boolean" || Object.keys(project).length !== 2) {
				throw new Error("project is { id, quiet }");
			}
			if (this.#parts.projectName(project.id) === undefined) throw new Error(`Unknown project: ${project.id.slice(0, 64)}`);
			next.quiet = next.quiet.filter((id) => id !== project.id && this.#parts.projectName(id) !== undefined);
			if (project.quiet) next.quiet.push(project.id);
		}
		if (Object.keys(params).length > 0) {
			this.#store(device, next);
			// What is owed for something just turned off goes no more.
			this.#owed.set(device, (this.#owed.get(device) ?? []).filter((owed) => owed.settingOn(next)));
		}
		return this.settings(device);
	}

	/**
	 * `pushes.follow { projectId, activity, on }`: the phone's Live Activity `activity` follows the project, or no longer
	 * does. A project has one at a time on a device: a new one replaces the one before. At most MAX_FOLLOWS.
	 */
	follow(device: string, params: Record<string, unknown>): ReturnType<Pushes["settings"]> {
		const { projectId, activity, on } = params;
		if (Object.keys(params).some((key) => !["projectId", "activity", "on"].includes(key))) throw new Error("pushes.follow takes projectId, activity and on");
		if (typeof activity !== "string" || !/^[A-Za-z0-9_-]{22}$/.test(activity) || !/[AQgw]$/.test(activity)) throw new Error("activity is the Live Activity's 16-byte id, in base64url");
		if (typeof on !== "boolean") throw new Error("on is true or false");
		const settings = structuredClone(this.#own(device));
		this.#forgetActivity(device, settings);
		if (!on) {
			const before = settings.follows.length;
			settings.follows = settings.follows.filter((one) => one.activity !== activity);
			if (settings.follows.length !== before) this.#store(device, settings);
			this.#activities.delete(`${device}:${activity}`);
			return this.settings(device);
		}
		if (typeof projectId !== "string" || this.#parts.projectName(projectId) === undefined) throw new Error("projectId must be a project's id");
		const replaced = settings.follows.filter((one) => one.activity === activity || one.projectId === projectId);
		for (const one of replaced) this.#activities.delete(`${device}:${one.activity}`);
		settings.follows = settings.follows.filter((one) => !replaced.includes(one));
		if (settings.follows.length >= MAX_FOLLOWS) throw new Error(`A phone follows at most ${MAX_FOLLOWS} projects in Live Activities. Turn one off first.`);
		const now = this.#parts.now();
		settings.follows.push({ projectId, activity, since: now });
		this.#store(device, settings);
		// Its numbers as the phone started it with them, as far as the Mac knows: the next change is sent.
		const { working, needs } = this.#counts(projectId);
		this.#activities.set(`${device}:${activity}`, { sent: { working, needs, finished: 0 }, sentAt: 0, idleSince: null, finished: 0, held: null });
		return this.settings(device);
	}

	/** Follows past FOLLOW_KEPT_MS are dropped from `settings`. */
	#forgetActivity(device: string, settings: PushSettings): void {
		const now = this.#parts.now();
		for (const one of settings.follows.filter((follow) => now - follow.since >= FOLLOW_KEPT_MS)) this.#activities.delete(`${device}:${one.activity}`);
		settings.follows = settings.follows.filter((follow) => now - follow.since < FOLLOW_KEPT_MS);
	}

	// -- What happened in the engine

	/** The `needs` event: new items are owed to each device that wants them; items gone are pushed as gone to each told. */
	needs(items: readonly NeedItem[]): void {
		const now = new Map(items.map((item) => [item.id, item]));
		const before = this.#waiting;
		this.#waiting = now;
		// What waits before the settings are read is never pushed, as what waited when the engine started is not.
		if (before === null || !this.#loaded) return;
		for (const item of items) {
			if (before.has(item.id)) continue;
			const settingOn = (settings: PushSettings) => settings.needs && (item.projectId === null || !settings.quiet.includes(item.projectId));
			const make = () => {
				const current = this.#waiting?.get(item.id);
				if (current === undefined) return null;
				const project = current.projectId === null ? undefined : this.#parts.projectName(current.projectId);
				return needAlert(current, current.kind === "approval" && this.#parts.approvalHidden(current.id), project, this.#parts.now());
			};
			this.#owe({ collapse: `need:${item.id}`, need: item.id, make, settingOn });
		}
		for (const id of before.keys()) {
			if (now.has(id)) continue;
			for (const [device, told] of this.#told) {
				if (!told.includes(id)) continue;
				this.#told.set(device, told.filter((one) => one !== id));
				this.#goneTo(device, [id], this.#parts.now() + GONE_TOGETHER_MS);
			}
		}
		this.flush();
	}

	/**
	 * The `limits` event: a notice come to `reached` or `carried_on` is owed, once for each stage, if it came to it since
	 * the choice began (the 90% stage is never pushed, as the Mac does not notify it).
	 */
	limits(notices: readonly LimitNoticeLike[]): void {
		if (!this.#loaded) {
			this.#limitsBefore = notices;
			return;
		}
		const current = new Set(notices.map((notice) => `${notice.id} ${notice.stage ?? "nearly"}`));
		for (const seen of [...this.#stages]) if (!current.has(seen)) this.#stages.delete(seen);
		for (const notice of notices) {
			const key = `${notice.id} ${notice.stage ?? "nearly"}`;
			const since = notice.stage === "reached" ? notice.reachedAt : notice.stage === "carried_on" ? notice.carriedOnAt : undefined;
			if (this.#stages.has(key) || since === undefined || since < this.#began) continue;
			this.#stages.add(key);
			const alert = limitAlert(notice, this.#parts.now());
			if (alert === null) continue;
			this.#owe({ collapse: `limit:${notice.id}`, make: () => ({ ...alert, at: this.#parts.now() }), settingOn: (settings) => settings.limits });
		}
		this.flush();
	}

	/** Runs started or ended (`runsChanged`): the projects' counts, finished runs, and the answers waited for. */
	runs(working: ReadonlySet<number>): void {
		const now = new Map<number, string | null>();
		for (const id of working) {
			const conversation = this.#parts.conversation(id);
			if (conversation !== undefined && !conversation.chat) now.set(id, conversation.projectId);
		}
		const before = this.#working;
		this.#working = now;
		if (before !== null) {
			for (const [id, projectId] of before) {
				if (now.has(id) || projectId === null) continue;
				for (const [device, settings] of this.#settings) {
					for (const follow of settings.follows) if (follow.projectId === projectId) this.#activity(device, follow).finished += 1;
				}
			}
		}
		for (const [device, waiting] of this.#answers) {
			const left = waiting.filter((answer) => {
				if (working.has(answer.conversationId)) {
					answer.seen = true;
					return true;
				}
				if (!answer.seen) return this.#parts.now() - answer.at < ANSWER_KEPT_MS;
				const orchestrator = this.#parts.orchestrator(answer.conversationId);
				if (orchestrator === undefined) return false;
				const name = this.#parts.projectName(orchestrator.projectId);
				const alert = answerAlert(orchestrator.agent, name === undefined ? undefined : { id: orchestrator.projectId, name }, answer.conversationId, this.#parts.now());
				this.#oweTo(device, { collapse: `answer:${answer.conversationId}`, make: () => ({ ...alert, at: this.#parts.now() }), settingOn: (settings) => settings.answers && !settings.quiet.includes(orchestrator.projectId) });
				return false;
			});
			if (left.length === 0) this.#answers.delete(device);
			else this.#answers.set(device, left);
		}
		this.flush();
	}

	/**
	 * A message the device sent with Tell me when it answers on, to `conversationId`, before its handler runs: told once
	 * that conversation's run has been seen and has ended. Only for the current conversation with an orchestrator (7).
	 */
	answerWanted(device: string, conversationId: number): void {
		const orchestrator = this.#parts.orchestrator(conversationId);
		const settings = this.#own(device);
		if (orchestrator === undefined || !settings.answers || settings.quiet.includes(orchestrator.projectId)) return;
		const waiting = (this.#answers.get(device) ?? []).filter((one) => one.conversationId !== conversationId);
		// Already working: the message is taken in the run that goes, which ends once it is answered too.
		waiting.push({ conversationId, at: this.#parts.now(), seen: this.#working?.has(conversationId) === true });
		this.#answers.set(device, waiting.slice(-MAX_ANSWERS));
	}

	/** The message was refused after all: nothing to wait for. */
	answerNotWanted(device: string, conversationId: number): void {
		const waiting = this.#answers.get(device)?.filter((one) => one.conversationId !== conversationId);
		if (waiting !== undefined) this.#answers.set(device, waiting);
	}

	/**
	 * pi² Remote's answer for a push the relay refused (`remote.pushRefused { id, why }`). What it held back waits as the
	 * refusal says (HOLDS): until the phone next attaches for one with no token or a token Apple no longer takes (it
	 * gives its token at every connection, and reads what waits as it attaches, so what was held is dropped), or for a
	 * while for the limits, a busy push service and a relay with no push key, after which alerts still waiting are
	 * owed again and gone items named again. A Live Activity is sent its latest numbers when the hold ends; one whose
	 * token is dead has ended, and is followed no more. A push pi² Remote will never send as it is (DROPPED) is dropped
	 * alone, and said in engine.log by its id.
	 */
	refused(id: string, why: string): boolean {
		const asked = this.#asked.get(id);
		if (asked === undefined) return false;
		this.#asked.delete(id);
		if ((DROPPED as readonly string[]).includes(why)) {
			// Asked again, it would be built the same and refused the same, every minute for as long as it is owed.
			this.#parts.log?.(`pushes: pi² Remote refused push ${id} (${asked.kind}) as ${why}; it is dropped, and nothing else is held back`);
			// An item the phone was never told of is not named to it as gone.
			for (const owed of asked.owed ?? []) {
				const told = this.#told.get(asked.device);
				if (owed.need !== undefined && told !== undefined) this.#told.set(asked.device, told.filter((one) => one !== owed.need));
			}
			return this.#settle();
		}
		const refusal: Refusal = (REFUSALS as readonly string[]).includes(why) ? (why as Refusal) : "push-later";
		const now = this.#parts.now();
		const hold: Hold = { until: HOLDS[refusal] === null ? null : now + HOLDS[refusal]!, since: now };
		// No token, or a dead one, is the device's, whatever kind found it: alerts and background pushes alike (7.1's table).
		const kinds: PushKind[] =
			refusal === "unavailable" || refusal === "unknown-device"
				? ["alert", "background", "activity"]
				: (refusal === "no-token" || refusal === "token-dead") && asked.kind !== "activity"
					? ["alert", "background"]
					: [asked.kind];
		if (asked.kind === "activity" && asked.follow !== undefined) {
			const settings = this.#own(asked.device);
			if (refusal === "token-dead") {
				this.#activities.delete(`${asked.device}:${asked.follow.activity}`);
				const follows = settings.follows.filter((one) => one.activity !== asked.follow!.activity);
				if (follows.length !== settings.follows.length) this.#store(asked.device, { ...structuredClone(settings), follows });
			} else {
				// An end refused: the activity is still followed, so that it ends when the hold does.
				if (!settings.follows.some((one) => one.activity === asked.follow!.activity) && settings.follows.length < MAX_FOLLOWS) {
					this.#store(asked.device, { ...structuredClone(settings), follows: [...settings.follows, asked.follow] });
				}
				const state = this.#activity(asked.device, asked.follow);
				state.sent = null;
				// No token for this activity is this activity's alone; the others' go on.
				if (refusal === "no-token") state.held = hold;
			}
			if (refusal === "no-token" || refusal === "token-dead") return this.#settle();
		}
		for (const kind of kinds) this.#holds.set(`${asked.device}:${kind}`, hold);
		if (asked.owed !== undefined) this.#owed.set(asked.device, [...asked.owed, ...(this.#owed.get(asked.device) ?? [])].slice(-MAX_OWED));
		// The phone that attaches again reads what waits itself: gone items are named again only after a hold with an end.
		if (asked.needs !== undefined && hold.until !== null) this.#goneTo(asked.device, asked.needs, hold.until);
		return this.#settle();
	}

	#settle(): true {
		this.flush();
		return true;
	}

	// -- Sending

	#owe(owed: Owed): void {
		for (const device of this.#parts.devices()) this.#oweTo(device.id, owed);
	}

	#goneTo(device: string, needs: readonly string[], due: number): void {
		const gone = this.#gone.get(device) ?? { needs: new Set<string>(), due };
		for (const need of needs) gone.needs.add(need);
		while (gone.needs.size > MAX_GONE) gone.needs.delete(gone.needs.values().next().value!);
		gone.due = Math.min(gone.due, due);
		this.#gone.set(device, gone);
	}

	#oweTo(device: string, owed: Owed): void {
		if (!owed.settingOn(this.#own(device))) return;
		const list = [...(this.#owed.get(device) ?? []).filter((one) => one.collapse !== owed.collapse), owed];
		this.#owed.set(device, list.slice(-MAX_OWED));
	}

	#activity(device: string, follow: Follow): Activity {
		const key = `${device}:${follow.activity}`;
		let state = this.#activities.get(key);
		if (state === undefined) {
			state = { sent: null, sentAt: 0, idleSince: null, finished: 0, held: null };
			this.#activities.set(key, state);
		}
		return state;
	}

	/** A project's numbers now: its runs going that are not chat mode's, and its items in Needs you (as the phone counts them). */
	#counts(projectId: string): { working: number; needs: number } {
		let working = 0;
		for (const project of this.#working?.values() ?? []) if (project === projectId) working += 1;
		let needs = 0;
		for (const item of this.#waiting?.values() ?? []) if (item.projectId === projectId) needs += 1;
		return { working: capped(working), needs: capped(needs) };
	}

	/** Whether a hold is over: its time passed, or, for one until the next attach, the phone attached since. */
	#over(device: { lastSeenAt: number | null }, hold: Hold): boolean {
		return hold.until === null ? device.lastSeenAt !== null && device.lastSeenAt > hold.since : this.#parts.now() >= hold.until;
	}

	/** Whether pushes of `kind` to `device` are held: false, the time the hold ends, or true until the phone attaches. */
	#held(device: { id: string; lastSeenAt: number | null }, kind: PushKind): number | true | false {
		const key = `${device.id}:${kind}`;
		const hold = this.#holds.get(key);
		if (hold === undefined) return false;
		if (this.#over(device, hold)) {
			this.#holds.delete(key);
			return false;
		}
		return hold.until ?? true;
	}

	/** When the hour lets `device` have one more push of `kind`: now, or the time it will. */
	#room(device: string, kind: PushKind): number {
		const now = this.#parts.now();
		const times = (this.#sent.get(`${device}:${kind}`) ?? []).filter((at) => now - at < HOUR);
		this.#sent.set(`${device}:${kind}`, times);
		return times.length < HOURLY[kind] ? now : times[0]! + HOUR;
	}

	#send(device: string, push: Unaddressed, asked: Omit<Asked, "device" | "kind" | "at">): void {
		const now = this.#parts.now();
		const id = `p${++this.#next}`;
		const kind = push.kind;
		const times = this.#sent.get(`${device}:${kind}`) ?? [];
		times.push(now);
		this.#sent.set(`${device}:${kind}`, times);
		for (const [old, one] of this.#asked) if (now - one.at >= ASKED_KEPT_MS || this.#asked.size >= MAX_ASKED) this.#asked.delete(old);
		this.#asked.set(id, { device, kind, at: now, ...asked });
		this.#parts.send({ id, device, ...push } as Push);
	}

	/**
	 * Sends what is owed and allowed now, to each paired device not suspended, and asks to be woken when the next of what
	 * waits may go. What is owed a device revoked, suspended or unknown is dropped: nothing is emitted for it.
	 */
	flush(): void {
		const now = this.#parts.now();
		const devices = this.#parts.devices().filter((device) => device.suspendedAt === null);
		const known = new Set(devices.map((device) => device.id));
		for (const map of [this.#owed, this.#told, this.#gone, this.#answers] as Map<string, unknown>[]) for (const id of [...map.keys()]) if (!known.has(id)) map.delete(id);
		let wake = Number.POSITIVE_INFINITY;
		const later = (at: number | true) => {
			if (at !== true) wake = Math.min(wake, at);
		};
		const ready = this.#parts.ready();
		for (const device of devices) {
			const settings = this.#own(device.id);
			// Alerts, oldest first.
			const owed = (this.#owed.get(device.id) ?? []).filter((one) => one.settingOn(settings) && (one.need === undefined || this.#waiting?.has(one.need) === true));
			while (owed.length > 0 && ready) {
				const held = this.#held(device, "alert");
				// Held until the phone attaches: it reads what waits as it does, so what was held goes no more.
				if (held === true) owed.length = 0;
				if (held !== false) {
					later(held);
					break;
				}
				const room = this.#room(device.id, "alert");
				if (room > now) {
					later(room);
					break;
				}
				const next = owed.shift()!;
				const body = next.make();
				if (body === null) continue;
				this.#send(device.id, { kind: "alert", collapse: next.collapse, body }, { owed: [next] });
				if (next.need !== undefined) this.#told.set(device.id, [...(this.#told.get(device.id) ?? []).filter((one) => one !== next.need), next.need].slice(-TOLD_KEPT));
			}
			if (owed.length > 0 && !ready) later(now + NOT_READY_RETRY_MS);
			if (owed.length > 0) this.#owed.set(device.id, owed);
			else this.#owed.delete(device.id);
			// The items gone, together.
			const gone = this.#gone.get(device.id);
			if (gone !== undefined && now < gone.due) later(gone.due);
			else if (gone !== undefined) {
				const held = this.#held(device, "background");
				const room = this.#room(device.id, "background");
				// Held until the phone attaches: it reads what waits then, so nothing is named to it.
				if (held === true) this.#gone.delete(device.id);
				else if (held !== false) gone.due = held;
				else if (room > now) gone.due = room;
				else if (!ready) gone.due = now + NOT_READY_RETRY_MS;
				else {
					const needs = [...gone.needs];
					this.#gone.delete(device.id);
					this.#send(device.id, { kind: "background", body: { v: 1, type: "gone", needs, at: now } }, { needs });
				}
				if (this.#gone.has(device.id)) later(gone.due);
			}
			// Live Activities.
			if (settings.follows.some((follow) => now - follow.since >= FOLLOW_KEPT_MS)) {
				const kept = structuredClone(settings);
				this.#forgetActivity(device.id, kept);
				this.#store(device.id, kept);
			}
			for (const follow of this.#own(device.id).follows) {
				const at = this.#considerActivity(device, follow, ready);
				if (at !== null) later(at);
			}
		}
		if (wake !== Number.POSITIVE_INFINITY) this.#parts.wake(wake);
	}

	/** Sends a followed project's latest numbers if they changed and a minute has passed, or `end` once idle long enough; else when to look again. */
	#considerActivity(device: { id: string; lastSeenAt: number | null }, follow: Follow, ready: boolean): number | null {
		const now = this.#parts.now();
		const state = this.#activity(device.id, follow);
		const counts = { ...this.#counts(follow.projectId), finished: capped(state.finished) };
		const idle = counts.working === 0 && counts.needs === 0;
		state.idleSince = idle ? (state.idleSince ?? now) : null;
		if (sameCounts(state.sent, counts) && !(idle && state.sent !== null)) return null;
		if (sameCounts(state.sent, counts) && idle && now - (state.idleSince ?? now) < IDLE_FOR_MS) return (state.idleSince ?? now) + IDLE_FOR_MS;
		const due = Math.max(state.sentAt + ACTIVITY_EVERY_MS, idle ? (state.idleSince ?? now) + IDLE_FOR_MS : 0);
		if (now < due) return due;
		// A hold of this activity's own (no token for it), then the device's.
		if (state.held !== null && this.#over(device, state.held)) state.held = null;
		if (state.held !== null) return state.held.until;
		const held = this.#held(device, "activity");
		if (held !== false) return held === true ? null : held;
		const room = this.#room(device.id, "activity");
		if (room > now) return room;
		if (!ready) return now + NOT_READY_RETRY_MS;
		state.sent = { working: counts.working, needs: counts.needs, finished: counts.finished };
		state.sentAt = now;
		this.#send(device.id, { kind: "activity", activity: follow.activity, event: idle ? "end" : "update", state: { ...counts, at: now } }, { follow });
		if (idle) {
			// Ended: the phone starts a new one, with a new id, when it next opens with the project busy.
			const settings = structuredClone(this.#own(device.id));
			settings.follows = settings.follows.filter((one) => one.activity !== follow.activity);
			this.#store(device.id, settings);
			this.#activities.delete(`${device.id}:${follow.activity}`);
		}
		return null;
	}
}

// ---- In the engine

/** The document `pi2.devicePushes`: each paired device's own settings for what it is pushed, and the Live Activities it follows. */
export const DevicePushes = defineDoc<{ devices: Record<string, PushSettings> }>({
	kind: "pi2.devicePushes",
	version: 1,
	scope: "session",
	initial: () => ({ devices: {} }),
	checkpointWhen: () => true,
});

/** The engine's choice of pushes, once the feature has started; remote.ts tells it of messages and pi² Remote's answers. */
export let pushes: Pushes | undefined;

/** The device a request came from, in its own session: these requests are a device's own, refused anywhere else. */
function deviceOf(connection: object | undefined): string {
	const device = pairedDevice((connection as Client | undefined)?.device?.id);
	if (device === undefined) throw new Error("Only a paired device asks this, of itself.");
	return device.id;
}

export const devicePushes: Feature = (host, engine) => {
	let timer: ReturnType<typeof setTimeout> | undefined;
	let timerAt = Number.POSITIVE_INFINITY;
	let saving: Promise<unknown> = Promise.resolve();
	const watch = (message: unknown) => {
		const event = message as { event?: unknown; items?: unknown; notices?: unknown };
		try {
			if (event.event === "needs" && Array.isArray(event.items)) pushes?.needs(event.items as NeedItem[]);
			else if (event.event === "limits" && Array.isArray(event.notices)) pushes?.limits(event.notices as LimitNoticeLike[]);
		} catch (error) {
			engine.log("pushes: what to push could not be chosen:", error instanceof Error ? error.message : error);
		}
	};
	const parts: PushParts = {
		now: () => Date.now(),
		devices: () => (remoteOn() ? activeDevices() : []),
		ready: () => remoteOn() && remoteHooks.helper().running,
		send: (push) => remoteHooks.toHelper({ kind: "push", push }),
		wake: (at) => {
			if (at >= timerAt) return;
			clearTimeout(timer);
			timerAt = at;
			timer = setTimeout(
				() => {
					timerAt = Number.POSITIVE_INFINITY;
					pushes?.flush();
				},
				Math.max(0, at - Date.now()),
			);
			timer.unref();
		},
		saved: (all) => {
			// A device revoked since takes its settings with it.
			const paired = new Set(activeDevices().map((device) => device.id));
			const devices = Object.fromEntries(Object.entries(all).filter(([id]) => paired.has(id)));
			saving = saving
				.then(() =>
					engine.harness().commit(async (tx) => {
						(await tx.doc(DevicePushes)).devices = structuredClone(devices);
					}, engine.context()),
				)
				.catch((error) => engine.log("pushes: the devices' settings could not be saved:", error instanceof Error ? error.message : error));
		},
		projectName: (id) => {
			// Its own key only: `constructor` and `toString` are no projects.
			const projects = allProjects();
			const project = Object.hasOwn(projects, id) ? projects[id] : undefined;
			return project === undefined || project.deletedAt !== undefined ? undefined : project.name;
		},
		approvalHidden: (id) => {
			const item = host.inbox.get(id);
			return item !== undefined && item.kind === "approval" && hidesSomething(item);
		},
		conversation: (id) => {
			const meta = engine.library().conversations[String(id)];
			return meta === undefined ? undefined : { projectId: meta.projectId ?? null, chat: isChat(meta) };
		},
		orchestrator: (id) => {
			if (orchestratorRole(id) !== "current") return undefined;
			const project = projectOf(id);
			if (project === undefined || project.deletedAt !== undefined) return undefined;
			const agentId = runsAs(engine.library().conversations[String(id)], engine.agents());
			return { projectId: project.id, agent: agentId === undefined ? null : (engine.agents()[agentId]?.name ?? null) };
		},
		log: (text) => engine.log(text),
	};
	// Made, and listening, before any feature starts: the first `needs` and `limits` events, sent as those start, are what
	// waited before, which is never pushed.
	pushes = new Pushes(parts);
	broadcastWatchers.add(watch);
	const revoked = (device: string) => {
		try {
			pushes?.forget(device);
		} catch (error) {
			engine.log("pushes: a revoked device's settings could not be dropped:", error instanceof Error ? error.message : error);
		}
	};
	revokedWatchers.add(revoked);
	return {
		start: async () => {
			const stored = await engine.harness().snapshot(DevicePushes, engine.context());
			pushes?.load(typeof stored?.devices === "object" && stored.devices !== null ? stored.devices : {});
		},
		runsChanged: (working) => {
			try {
				pushes?.runs(working);
			} catch (error) {
				engine.log("pushes: what to push could not be chosen:", error instanceof Error ? error.message : error);
			}
		},
		stopping: async () => {
			broadcastWatchers.delete(watch);
			revokedWatchers.delete(revoked);
			clearTimeout(timer);
			await saving;
		},
		handlers: {
			/** `{ needs?, limits?, answers?, project?: { id, quiet } }`, a device's own: what it is pushed. Answers its settings. */
			"pushes.set": async (params, connection) => {
				const device = deviceOf(connection);
				if (pushes === undefined) throw new Error("pi² is still starting.");
				return pushes.set(device, params);
			},
			/** `{ projectId, activity, on }`, a device's own: which project its Live Activity `activity` follows. Answers its settings. */
			"pushes.follow": async (params, connection) => {
				const device = deviceOf(connection);
				if (pushes === undefined) throw new Error("pi² is still starting.");
				const answer = pushes.follow(device, params);
				pushes.flush();
				return answer;
			},
		},
	};
};
