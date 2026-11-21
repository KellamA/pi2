// Work from an attached GitHub repository (#468): docs/projects.md, 3.11 ("The GitHub backend"), 4.2's `github.*`
// requests and `projects.watch`, 4.3's `github` event, and 5.7's pull-request actions.
//
// A project with a `repository` keeps its work as that repository's issues, and has its pull requests besides. pi²
// runs `gh` for every look and every write, with the sign-in `gh` already has: pi² keeps no token. `PI2_GH` names a
// program to run in place of `gh`, for tests (engine/test/gh-stand-in.mjs is one). Every command names the repository
// with `--repo owner/name`, so neither the project's folder nor a conversation's decides where a write lands; the one
// command that takes no `--repo`, `gh repo view`, names it as its argument.
//
// What is kept, and where:
//
// - `pi2.github` (a session document): by project, the repository attached, every write pi² made or is making there
//   (its intents), and which conversation opened each pull request pi² opened (`openedBy`), which GitHub does not know.
// - `github.json` in the data folder: the last listing of each project's repository, by project and repository, so a
//   listing never shows under another repository. A cache: losing it loses nothing but the wait for the next look.
//
// Writes. Each `gh` command that changes something is first recorded as an intent, then run, then marked done, each a
// commit. An intent's id is made from the tool call's id (or a fresh one for the person's request), so a call run
// again after a crash finds its intents. A write that creates something (an issue, a comment, a pull request) carries
// its intent's id in a marker GitHub does not show, `<!-- pi2:<id> -->`, and is found by it; one that sets a state
// (labels, closed or open, a title and text, merged) is found by the state. An intent found pending (after a restart,
// or when its call runs again) is looked for before anything is written again. Found, it is done. A state not found is
// written again, which cannot make anything twice. A creating write not found, or not looked for because GitHub could
// not be asked, is `unknown`: nothing is written again, the call says so, and the person settles it (`github.settle`).
//
// Who holds an issue is read from pi²'s own comments: the newest "Taken by" comment whose holder no later "Released"
// comment names, while the issue is in progress, waiting or blocked. Two takes at once cannot be one commit on GitHub:
// each reads the issue again after its "Taken by", and the later one lets go ("Released") and is refused.

import { createHash, randomUUID } from "node:crypto";
import { existsSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { AgentDoc, type ConversationId, defineDoc, type EntryRecord, type JsonObject, type Tx } from "@earendil-works/pi-durable";
import { defineOp, record, wireRepository } from "./changes.ts";
import { commandEnvironment } from "./environment.ts";
import type { Engine, Feature } from "./features.ts";
import { runOffThread } from "./offthread.ts";
import { wireWorkState } from "./orchestrator.ts";
import { limitError, limitRefusal } from "./projectlimits.ts";
import { addNews, allProjects, type Project, PROJECT_ARCHIVED, Projects, requirePreview, requireSwitch, type Start, type Who } from "./projects.ts";
import { Library } from "./state.ts";
import {
	type Call,
	checkWorkTransition,
	checkWriterIn,
	type GithubWriting,
	type PullAction,
	syncWorkForInput,
	unknownItem,
	type WorkAction,
	type WorkItem,
	type WorkState,
	Work,
	workNews,
	workNewsText,
	workReceipt,
	workReceiptOf,
	workTransition,
	wireGithubWork,
} from "./work.ts";
import { git } from "./worktrees.ts";

// ---- What is stored (3.11)

export type Repository = { owner: string; name: string };
type IntentState = "pending" | "done" | "failed" | "unknown";
export type Intent = { id: string; action: WriteKind; args: Record<string, unknown>; at: number; state: IntentState; result?: unknown };
export type GithubDoc = {
	projects: Record<
		string,
		{
			repository: Repository;
			intents: Record<string, Intent>;
			/** Pull requests pi² opened, by number: which conversation, for Send back. Durable: GitHub does not know it. */
			openedBy: Record<string, { conversationId: number; at: number }>;
		}
	>;
};

/** Made by the first write: with no repository ever attached, nothing is written. A plain JSON object's token, as `pi2.needs`'s. */
export const Github = defineDoc<JsonObject>({ kind: "pi2.github", version: 1, scope: "session", initial: () => ({ projects: {} }), checkpointWhen: () => true });
const githubIn = async (tx: Tx): Promise<GithubDoc> => (await tx.doc(Github)) as unknown as GithubDoc;

export type PullRequest = {
	number: number;
	title: string;
	url: string;
	/** The head as GitHub names it: "branch", or "owner:branch" from a fork. */
	head: string;
	base: string;
	author: string;
	state: "open" | "merged" | "closed";
	draft: boolean;
	checks: "passing" | "failing" | "pending" | "none";
	/** The checks of the roll-up that failed, by name, each with its page on GitHub: empty when none fail (#573). */
	failingChecks: { name: string; url: string }[];
	mergeable: "yes" | "no" | "unknown";
	/** What reviewing agents found: the comments pi² posted for `work` `review`. */
	findings: { agentName: string; verdict: "approve" | "changes" | "comment"; at: number; url: string; text: string }[];
	/** The conversation that opened it through `work`, from `openedBy`. */
	openedBy: { conversationId: number } | null;
	/** The work item it fixes, from "Fixes #N" in its text. */
	work: number | null;
};

type ListingState = "ok" | "loading" | "signed_out" | "unreachable" | "rate_limited";
type Listing = { readAt: number | null; issues: WorkItem[]; pulls: PullRequest[] };

/** How many intents done or failed are kept per project, newest; pending and unknown ones are always kept. */
const KEPT_INTENTS = 2_000;
/** The listing is read at most this often per project, but after a write of pi²'s (3.11). */
const READ_EVERY_MS = 60_000;
/** Closed issues and pull requests are listed for this long after they closed. */
const CLOSED_FOR_MS = 7 * 24 * 60 * 60_000;
/** A `gh` command still running after this is stopped: a hang guard, not a measure of GitHub. */
const GH_TIMEOUT_MS = 2 * 60_000;
/** `github.diff` is cut here. */
const DIFF_BYTES = 2 * 1024 * 1024;

// ---- Running gh

type FailureKind = "rate_limited" | "signed_out" | "unreachable" | "refused" | "unclear";

/** A `gh` command that failed, and how: whether GitHub refused it, could not be reached, or cannot be told. */
export class GhError extends Error {
	readonly kind: FailureKind;
	readonly said: string;
	constructor(kind: FailureKind, said: string) {
		super(failureWords(kind, said));
		this.kind = kind;
		this.said = said;
	}
}

function failureWords(kind: FailureKind, said: string): string {
	switch (kind) {
		case "rate_limited":
			return `GitHub's rate limit is reached: ${said}. Try again later.`;
		case "signed_out":
			return `gh is not signed in to GitHub: ${said}. The person can sign in with gh auth login.`;
		case "unreachable":
			return `GitHub cannot be reached: ${said}`;
		case "unclear":
			return `GitHub did not answer clearly: ${said}`;
		default:
			return `GitHub refused it: ${said}`;
	}
}

/** What a failed `gh` said, as one of the kinds above. A refusal is GitHub's answer; `unclear` may have reached it. */
export function classify(code: unknown, killed: boolean, stderr: string, message: string): GhError {
	const lines = `${stderr}\n${message}`.split(/[\r\n]+/).map((line) => line.trim()).filter((line) => line !== "" && !/^Command failed:/.test(line));
	const said = (lines.find((line) => !/^(check your internet|To get started|  )/i.test(line)) ?? lines[0] ?? "gh failed").slice(0, 300);
	const all = lines.join("\n");
	if (code === "ENOENT") return new GhError("signed_out", "gh was not found; install GitHub's command-line tool");
	if (/rate limit/i.test(all)) return new GhError("rate_limited", said);
	if (/gh auth login|not logged in|authentication required|HTTP 401|bad credentials/i.test(all)) return new GhError("signed_out", said);
	if (/error connecting to|could not resolve host|no such host|connection refused|network is unreachable|dial tcp/i.test(all)) return new GhError("unreachable", said);
	if (killed || /timed? ?out|deadline exceeded|connection reset|unexpected EOF|\bEOF\b|HTTP 50[0234]|TLS handshake/i.test(all)) return new GhError("unclear", said);
	return new GhError("refused", said);
}

/** Run `gh` (or `PI2_GH`) to its end, off the engine's thread, in `cwd`, never asking for input. */
async function gh(args: string[], cwd: string): Promise<string> {
	const program = process.env.PI2_GH || "gh";
	const { GH_REPO: _, ...env } = commandEnvironment({ GH_PROMPT_DISABLED: "1", GH_NO_UPDATE_NOTIFIER: "1", GH_SPINNER_DISABLED: "1", NO_COLOR: "1", CLICOLOR: "0" });
	const { error, stdout, stderr } = await runOffThread(program, args, { cwd, env, timeout: GH_TIMEOUT_MS, maxBuffer: 64 * 1024 * 1024 });
	if (error === null) return stdout;
	throw classify(error.code, error.killed || error.signal !== null, stderr, error.message);
}

const repoName = (repository: Repository) => `${repository.owner}/${repository.name}`;
const sameRepository = (a: Repository | null | undefined, b: Repository | null | undefined) => a != null && b != null && repoName(a).toLowerCase() === repoName(b).toLowerCase();

/** `owner/name` from a git remote's address on github.com, or undefined. */
export function parseRemote(url: string): Repository | undefined {
	const match = /github\.com[:/]+([A-Za-z0-9-]+)\/([A-Za-z0-9._-]+?)(?:\.git)?\/?$/i.exec(url.trim());
	return match === null ? undefined : { owner: match[1]!, name: match[2]! };
}

/** `owner/name` as given, or undefined when it is not one. */
export function parseRepository(value: string): Repository | undefined {
	const match = /^([A-Za-z0-9-]+)\/([A-Za-z0-9._-]+)$/.exec(value.trim());
	return match === null ? undefined : { owner: match[1]!, name: match[2]!.replace(/\.git$/, "") };
}

// ---- The labels of scripts/issue (docs/issue-classes.md)

const STATUS_LABELS: Record<string, { color: string; description: string }> = {
	"in progress": { color: "fbca04", description: "Being worked on now" },
	waiting: { color: "c5def5", description: "Waiting on a decision or review" },
	blocked: { color: "b60205", description: "Cannot go on until something else changes" },
	backlog: { color: "ededed", description: "Not started; a candidate for later" },
};
const CLASS_LABELS: Record<string, { color: string; description: string }> = {
	"local model": { color: "0e8a16", description: "A model on this Mac can do it" },
	"cloud model": { color: "1d76db", description: "It needs a cloud model" },
};
const STATUS_OF: Partial<Record<WorkState, string>> = { open: "backlog", in_progress: "in progress", waiting: "waiting", blocked: "blocked" };
const classLabel = (value: WorkItem["class"]) => (value === "local" ? "local model" : value === "cloud" ? "cloud model" : null);

// ---- What GitHub answers

type GhComment = { author?: { login?: string } | null; body?: string; createdAt?: string; url?: string };
type GhIssue = {
	number: number;
	title: string;
	body?: string;
	state: string;
	stateReason?: string | null;
	labels?: { name: string }[];
	url: string;
	createdAt?: string;
	updatedAt?: string;
	closedAt?: string | null;
	comments?: GhComment[];
};
// A check of the roll-up is a check run (`name`, `status`, `conclusion`, `detailsUrl`) or a commit's status
// (`context`, `state`, `targetUrl`); the name and page below are whichever of the two it is.
type GhCheck = { status?: string; conclusion?: string | null; state?: string; name?: string; context?: string; detailsUrl?: string; targetUrl?: string };
type GhPull = {
	number: number;
	title: string;
	url: string;
	headRefName: string;
	headRepositoryOwner?: { login?: string } | null;
	isCrossRepository?: boolean;
	baseRefName: string;
	author?: { login?: string } | null;
	state: string;
	isDraft?: boolean;
	statusCheckRollup?: GhCheck[] | null;
	mergeable?: string;
	body?: string;
	comments?: GhComment[];
};

const ISSUE_FIELDS = "number,title,body,state,stateReason,labels,url,createdAt,updatedAt,closedAt,comments";
const PULL_FIELDS = "number,title,url,headRefName,headRepositoryOwner,isCrossRepository,baseRefName,author,state,isDraft,statusCheckRollup,mergeable,body,comments";

const time = (value: string | null | undefined) => (value == null || value === "" ? null : Date.parse(value));
const json = <T>(text: string): T => JSON.parse(text) as T;

// ---- Comments pi² posts

const MARKER = /<!-- pi2:([0-9a-f]{16}) -->/;
const marker = (id: string) => `<!-- pi2:${id} -->`;
const AGENT_LINE = /^\*From .*?, an agent of the pi² project “[^”]*”\.\*\s*\n?/;

/** The text pi² posts: for an agent, a line naming it first (3.11); the marker last, which GitHub does not show. */
function compose(project: Project, by: Who, text: string, id: string): string {
	const name = by.kind === "agent" ? agentName(by.agentId) : null;
	const head = name === null ? "" : `*From ${name}, an agent of the pi² project “${project.name}”.*\n\n`;
	return `${head}${text}${text === "" ? "" : "\n\n"}${marker(id)}`;
}

/** What a person reads of a text pi² posted: without the agent's line and the marker. */
function plain(body: string): string {
	return body.replace(AGENT_LINE, "").replace(/\s*<!-- pi2:[0-9a-f]{16} -->\s*$/, "").trim();
}

const VERDICTS = { approve: "Approved", changes: "Changes requested", comment: "Comment" } as const;
type Verdict = keyof typeof VERDICTS;

// ---- The feature's state (in memory, read from the documents)

let engine: Engine | undefined;
/** `pi2.github` as last stored. */
let mirror: GithubDoc = { projects: {} };
/** The listings, by project and repository (`github.json`). */
let listings: Record<string, Record<string, Listing>> = {};
/** How each project's last look went, while it went wrong; "loading" while the first is under way. */
const states = new Map<string, { state: ListingState; error: string | null }>();
const reading = new Map<string, Promise<void>>();
const labelled = new Set<string>();
const locks = new Map<string, Promise<unknown>>();
let announce = () => {};

const agentName = (id: string) => engine?.agents()[id]?.name ?? "an agent that was deleted";
const copy = <T>(value: T): T => (value === undefined ? value : (JSON.parse(JSON.stringify(value)) as T));
const folderOf = (project: Project) => (project.folder !== null && existsSync(project.folder) ? project.folder : engine!.home);
const repositoryOf = (project: Project): Repository => {
	if (project.repository === null) throw new Error("This project's work is kept by pi², which has no pull requests.");
	return project.repository;
};
const listingOf = (project: Project): Listing | undefined => (project.repository === null ? undefined : listings[project.id]?.[repoName(project.repository)]);
const intentsOf = (project: Project): Record<string, Intent> => (sameRepository(mirror.projects[project.id]?.repository, project.repository) ? mirror.projects[project.id]!.intents : {});

/** One at a time per key: two looks or writes of the same intent never overlap. */
function locked<T>(key: string, run: () => Promise<T>): Promise<T> {
	const before = locks.get(key) ?? Promise.resolve();
	const next = before.then(run, run);
	const kept = next.catch(() => {});
	locks.set(key, kept);
	void kept.then(() => {
		if (locks.get(key) === kept) locks.delete(key);
	});
	return next;
}

async function readMirror(): Promise<GithubDoc> {
	const stored = (await engine!.harness().snapshot(Github, engine!.context())) as unknown as GithubDoc | undefined;
	mirror = stored === undefined ? { projects: {} } : copy(stored);
	return mirror;
}

function commit<T>(edit: (tx: Tx) => Promise<T>, call?: Call): Promise<T> {
	return call === undefined ? engine!.harness().commit(edit, engine!.context()) : call.api.commit(edit, call.context);
}

/** The project's entry in `pi2.github`, made or begun again when the repository changed. */
async function entryIn(tx: Tx, project: Project): Promise<GithubDoc["projects"][string]> {
	const doc = await githubIn(tx);
	const repository = repositoryOf(project);
	const entry = doc.projects[project.id];
	if (entry === undefined || !sameRepository(entry.repository, repository)) doc.projects[project.id] = { repository: copy(repository), intents: {}, openedBy: {} };
	return doc.projects[project.id]!;
}

// ---- Reading issues and pull requests

type Parsed = { at: number; url: string; by: Who; role: string | undefined; text: string; holder?: { agentId: string; conversationId: number | null }; intent?: Intent };

function parseComment(comment: GhComment, intents: Record<string, Intent>): Parsed {
	const body = comment.body ?? "";
	const id = MARKER.exec(body)?.[1];
	const intent = id === undefined ? undefined : intents[id];
	const args = intent?.args ?? {};
	return {
		at: time(comment.createdAt) ?? 0,
		url: comment.url ?? "",
		by: (args.by as Who | undefined) ?? { kind: "person" },
		role: args.role as string | undefined,
		text: plain(body),
		...(args.holder === undefined ? {} : { holder: args.holder as Parsed["holder"] }),
		...(intent === undefined ? {} : { intent }),
	};
}

const sameHolder = (a: Parsed["holder"], b: Parsed["holder"]) => a !== undefined && b !== undefined && a.agentId === b.agentId && a.conversationId === b.conversationId;

/**
 * The takes that stand, oldest first: each "Taken by" with no later "Released" for the same holder, and no later
 * closing comment of pi²'s ("Done.", "Dropped."), which ends every hold.
 */
function standing(comments: Parsed[]): Parsed[] {
	let takes: Parsed[] = [];
	for (const comment of comments) {
		if (comment.role === "done" || comment.role === "dropped") takes = [];
		else if (comment.holder === undefined) continue;
		else if (comment.role === "take") takes = [...takes.filter((one) => !sameHolder(one.holder, comment.holder)), comment];
		else if (comment.role === "release") takes = takes.filter((one) => !sameHolder(one.holder, comment.holder));
	}
	return takes;
}

/**
 * A "Taken by" that the read before a take saw, on an issue that was open, is one left from before the issue was
 * closed and opened again outside pi², unless it is this recent: then it is another take still on its way.
 */
const IN_FLIGHT_MS = 10 * 60_000;

const holderOf = (take: Parsed | undefined): WorkItem["takenBy"] => {
	if (take?.holder === undefined) return null;
	// An assignment's sub-chat is known once it starts; until then, the conversation that assigned it.
	const parent = (take.intent?.args.parent as number | undefined) ?? (take.by.kind === "agent" ? take.by.conversationId : 0);
	return { agentId: take.holder.agentId, conversationId: take.holder.conversationId ?? parent };
};

const BOOKKEEPING = new Set(["take", "release", "done", "dropped"]);

/** An issue as a work item (3.11). */
export function issueItem(issue: GhIssue, intents: Record<string, Intent>): WorkItem {
	const labels = (issue.labels ?? []).map((label) => label.name);
	const closed = issue.state.toUpperCase() === "CLOSED";
	const reason = (issue.stateReason ?? "").toUpperCase();
	const state: WorkState = closed
		? reason === "NOT_PLANNED" || reason === "DUPLICATE" ? "dropped" : "done"
		: labels.includes("in progress") ? "in_progress" : labels.includes("waiting") ? "waiting" : labels.includes("blocked") ? "blocked" : "open";
	const comments = (issue.comments ?? []).map((comment) => parseComment(comment, intents));
	const held = state === "in_progress" || state === "waiting" || state === "blocked";
	const done = [...comments].reverse().find((comment) => comment.role === "done" || comment.text.startsWith("**Done.**"));
	const filed = MARKER.exec(issue.body ?? "")?.[1];
	const createdAt = time(issue.createdAt) ?? 0;
	return {
		id: issue.number,
		title: issue.title,
		text: plain(issue.body ?? ""),
		state,
		class: labels.includes("local model") ? "local" : labels.includes("cloud model") ? "cloud" : null,
		takenBy: held ? holderOf(standing(comments).at(-1)) : null,
		notes: comments
			.filter((comment) => !BOOKKEEPING.has(comment.role ?? "") && !(comment.role === undefined && comment.text.startsWith("**Done.**")))
			.map((comment) => ({ at: comment.at, by: comment.by, text: comment.role === "wait" || comment.role === "block" ? comment.text.replace(/^\*\*(Waiting|Blocked):\*\*\s*/, "") : comment.text })),
		result: state === "done" && done !== undefined ? done.text.replace(/^\*\*Done\.\*\*\s*/, "") || null : null,
		filedBy: (filed === undefined ? undefined : (intents[filed]?.args.by as Who | undefined)) ?? { kind: "person" },
		createdAt,
		updatedAt: time(issue.updatedAt) ?? createdAt,
		closedAt: closed ? (time(issue.closedAt) ?? null) : null,
		url: issue.url,
	};
}

/** Whether one check of the roll-up has run and failed, as GitHub says it in either of the two shapes. */
function failed(check: GhCheck): boolean {
	const status = (check.status ?? (check.state === "PENDING" || check.state === "EXPECTED" ? "IN_PROGRESS" : "COMPLETED")).toUpperCase();
	const conclusion = (check.conclusion ?? check.state ?? "").toUpperCase();
	return status === "COMPLETED" && ["FAILURE", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "ERROR", "STARTUP_FAILURE"].includes(conclusion);
}

function checksOf(rollup: GhCheck[] | null | undefined): PullRequest["checks"] {
	if (failingChecksOf(rollup).length > 0) return "failing";
	if (rollup == null || rollup.length === 0) return "none";
	let pending = false;
	for (const check of rollup) {
		const status = (check.status ?? (check.state === "PENDING" || check.state === "EXPECTED" ? "IN_PROGRESS" : "COMPLETED")).toUpperCase();
		if (status !== "COMPLETED") {
			pending = true;
			break;
		}
	}
	return pending ? "pending" : "passing";
}

/** The checks of the roll-up that failed, by name, each with its page on GitHub (#573): what the opened pull request lists. */
function failingChecksOf(rollup: GhCheck[] | null | undefined): PullRequest["failingChecks"] {
	if (rollup == null) return [];
	const failing: PullRequest["failingChecks"] = [];
	for (const check of rollup) {
		if (!failed(check)) continue;
		const name = String(check.name ?? check.context ?? "").trim();
		const url = String(check.detailsUrl ?? check.targetUrl ?? "").trim();
		// A check GitHub leaves unnamed is still a failure the person can see, with the pull request for its page.
		failing.push({ name: name === "" ? "a check" : name, url });
	}
	return failing;
}

/** A pull request as 3.11 has it. */
export function pullOf(pull: GhPull, intents: Record<string, Intent>, openedBy: GithubDoc["projects"][string]["openedBy"] | undefined): PullRequest {
	const owner = pull.headRepositoryOwner?.login;
	const fixes = /\b(?:fix(?:e[sd])?|close[sd]?|resolve[sd]?)\s+#(\d+)\b/i.exec(pull.body ?? "");
	const opened = openedBy?.[String(pull.number)];
	return {
		number: pull.number,
		title: pull.title,
		url: pull.url,
		head: pull.isCrossRepository === true && owner !== undefined ? `${owner}:${pull.headRefName}` : pull.headRefName,
		base: pull.baseRefName,
		author: pull.author?.login ?? "",
		state: pull.state.toUpperCase() === "MERGED" ? "merged" : pull.state.toUpperCase() === "CLOSED" ? "closed" : "open",
		draft: pull.isDraft === true,
		checks: checksOf(pull.statusCheckRollup),
		failingChecks: failingChecksOf(pull.statusCheckRollup),
		mergeable: pull.mergeable === "MERGEABLE" ? "yes" : pull.mergeable === "CONFLICTING" ? "no" : "unknown",
		findings: (pull.comments ?? [])
			.map((comment) => parseComment(comment, intents))
			.filter((comment) => comment.role === "review" && comment.intent !== undefined)
			// The finding's own words are the comment pi² posted without the verdict line it began with (#573).
			.map((comment) => ({
				agentName: String(comment.intent!.args.agentName ?? "an agent"),
				verdict: comment.intent!.args.verdict as Verdict,
				at: comment.at,
				url: comment.url,
				text: comment.text.replace(/^\*\*(Approved|Changes requested|Comment)\.\*\*\s*/, ""),
			})),
		openedBy: opened === undefined ? null : { conversationId: opened.conversationId },
		work: fixes === null ? null : Number(fixes[1]),
	};
}

async function viewIssue(project: Project, number: number): Promise<GhIssue> {
	try {
		return json<GhIssue>(await gh(["issue", "view", String(number), "--repo", repoName(repositoryOf(project)), "--json", ISSUE_FIELDS], folderOf(project)));
	} catch (error) {
		if (error instanceof GhError && error.kind === "refused" && /could not resolve to an? (issue|pullrequest)|not found/i.test(error.said)) throw unknownItem(number);
		throw error;
	}
}

async function viewPull(project: Project, number: number): Promise<GhPull> {
	try {
		return json<GhPull>(await gh(["pr", "view", String(number), "--repo", repoName(repositoryOf(project)), "--json", PULL_FIELDS], folderOf(project)));
	} catch (error) {
		if (error instanceof GhError && error.kind === "refused" && /could not resolve|not found|no pull requests? found/i.test(error.said)) throw new Error(`There is no pull request #${number} in ${repoName(repositoryOf(project))}.`);
		throw error;
	}
}

/** Put a fresh reading of one issue or pull request into the listing, so what the apps are sent shows it at once. */
function keepInListing(project: Project, item?: WorkItem, pull?: PullRequest): void {
	const listing = listingOf(project);
	if (listing === undefined) return;
	if (item !== undefined) listing.issues = [...listing.issues.filter((one) => one.id !== item.id), item].sort((a, b) => b.id - a.id);
	if (pull !== undefined) listing.pulls = [...listing.pulls.filter((one) => one.number !== pull.number), pull].sort((a, b) => b.number - a.number);
	announce();
}

// ---- The listing (github.json)

let listingFile = "";

function loadListings(): void {
	try {
		const stored = JSON.parse(readFileSync(listingFile, "utf8")) as typeof listings;
		listings = stored !== null && typeof stored === "object" ? stored : {};
	} catch {
		listings = {};
	}
}

function saveListings(): void {
	const kept: typeof listings = {};
	const projects = allProjects();
	// Only the repository each project has now: a listing of one detached since is not shown again.
	for (const [id, byRepository] of Object.entries(listings)) {
		const repository = projects[id]?.repository;
		if (repository == null || projects[id]?.deletedAt !== undefined) continue;
		const listing = byRepository[repoName(repository)];
		if (listing !== undefined) kept[id] = { [repoName(repository)]: listing };
	}
	listings = kept;
	try {
		const temporary = `${listingFile}.${process.pid}.tmp`;
		writeFileSync(temporary, JSON.stringify(kept));
		renameSync(temporary, listingFile);
	} catch (error) {
		engine?.log("could not keep the GitHub listing:", error instanceof Error ? error.message : error);
	}
}

function noteFailure(project: Project, error: unknown): void {
	if (!(error instanceof GhError) || error.kind === "refused") return;
	const state: ListingState = error.kind === "rate_limited" ? "rate_limited" : error.kind === "signed_out" ? "signed_out" : "unreachable";
	states.set(project.id, { state, error: error.message });
	announce();
}

/**
 * Read the project's repository's open issues and pull requests, and those closed in the last seven days, unless it
 * was read in the last minute (`force`: after a write of pi²'s). A failure leaves the last listing as it was, with what
 * went wrong. Two reads at once are one.
 */
export function readListing(project: Project, force = false): Promise<void> {
	if (project.repository === null) return Promise.resolve();
	const already = reading.get(project.id);
	if (already !== undefined) return force ? already.then(() => readListing(project, true), () => readListing(project, true)) : already;
	const listing = listingOf(project);
	if (!force && listing?.readAt != null && Date.now() - listing.readAt < READ_EVERY_MS) return Promise.resolve();
	const repository = project.repository;
	const run = (async () => {
		if (listing === undefined) {
			states.set(project.id, { state: "loading", error: null });
			announce();
		}
		const name = repoName(repository);
		const cwd = folderOf(project);
		const since = new Date(Date.now() - CLOSED_FOR_MS).toISOString().slice(0, 10);
		try {
			const openIssues = json<GhIssue[]>(await gh(["issue", "list", "--repo", name, "--state", "open", "--limit", "1000", "--json", ISSUE_FIELDS], cwd));
			const closedIssues = json<GhIssue[]>(await gh(["issue", "list", "--repo", name, "--state", "closed", "--search", `closed:>=${since}`, "--limit", "200", "--json", ISSUE_FIELDS], cwd));
			const openPulls = json<GhPull[]>(await gh(["pr", "list", "--repo", name, "--state", "open", "--limit", "200", "--json", PULL_FIELDS], cwd));
			const closedPulls = json<GhPull[]>(await gh(["pr", "list", "--repo", name, "--state", "closed", "--search", `closed:>=${since}`, "--limit", "200", "--json", PULL_FIELDS], cwd));
			await readMirror();
			const intents = intentsOf(project);
			const openedBy = mirror.projects[project.id]?.openedBy;
			const issues = [...openIssues, ...closedIssues].map((issue) => issueItem(issue, intents)).sort((a, b) => b.id - a.id);
			const pulls = [...openPulls, ...closedPulls].map((pull) => pullOf(pull, intents, openedBy)).sort((a, b) => b.number - a.number);
			// A repository changed while this was read is not given another's listing.
			if (!sameRepository(allProjects()[project.id]?.repository, repository)) return;
			listings[project.id] = { ...(listings[project.id] ?? {}), [name]: { readAt: Date.now(), issues, pulls } };
			states.delete(project.id);
			saveListings();
			announce();
			void reconcileAll(project);
		} catch (error) {
			engine?.log("could not read GitHub for project", project.id, error instanceof Error ? error.message : error);
			if (error instanceof GhError && error.kind !== "refused") noteFailure(project, error);
			else {
				states.set(project.id, { state: "unreachable", error: error instanceof Error ? error.message : String(error) });
				announce();
			}
			throw error;
		}
	})().finally(() => reading.delete(project.id));
	reading.set(project.id, run);
	return run;
}

/** What went wrong with GitHub shows in the listing's state, whichever call met it. */
async function noting<T>(project: Project, running: Promise<T>): Promise<T> {
	try {
		return await running;
	} catch (error) {
		noteFailure(project, error);
		throw error;
	}
}

/** Read again soon after a write, without making the caller wait or fail for it. */
function readSoon(project: Project): void {
	void readListing(project, true).catch(() => {});
}

/** When the listing was read and, when it is not newer, why: for an agent's `work` `list` and `show`. */
function listingNote(project: Project): string {
	const listing = listingOf(project);
	const status = states.get(project.id);
	const when = listing?.readAt == null ? "never read" : `read ${new Date(listing.readAt).toISOString()}`;
	if (status === undefined || status.state === "ok" || status.state === "loading") return `(GitHub's listing of ${repoName(repositoryOf(project))}, ${when}.)`;
	return `(GitHub's listing of ${repoName(repositoryOf(project))}, ${when}. It is not newer: ${status.error ?? status.state})`;
}

// ---- Writes and their intents

type WriteKind = "issue.create" | "issue.comment" | "issue.labels" | "issue.edit" | "issue.close" | "issue.reopen" | "pr.create" | "pr.comment" | "pr.merge";
const CREATING = new Set<WriteKind>(["issue.create", "issue.comment", "pr.create", "pr.comment"]);

/** A write pi² could not tell GitHub took. */
export class UnknownWrite extends Error {}
const unknownWords = (summary: string) => `pi² could not tell whether GitHub took this (${summary}). Look at the repository before trying again.`;

const numberIn = (url: string) => Number(/\/(\d+)(?:#.*)?\s*$/.exec(url.trim())?.[1] ?? Number.NaN);

/** Make the write `kind`; what it answers is kept as the intent's result. */
async function perform(project: Project, kind: WriteKind, args: Record<string, unknown>): Promise<unknown> {
	const repo = ["--repo", repoName(repositoryOf(project))];
	const cwd = folderOf(project);
	const n = String(args.number);
	const list = (key: string) => ((args[key] as string[] | undefined) ?? []).join(",");
	switch (kind) {
		case "issue.create": {
			const labels = ((args.labels as string[] | undefined) ?? []).flatMap((label) => ["--label", label]);
			const url = (await gh(["issue", "create", ...repo, "--title", String(args.title), "--body", String(args.body), ...labels], cwd)).trim().split("\n").at(-1)!;
			return { number: numberIn(url), url };
		}
		case "issue.comment":
		case "pr.comment": {
			const url = (await gh([kind === "pr.comment" ? "pr" : "issue", "comment", n, ...repo, "--body", String(args.body)], cwd)).trim().split("\n").at(-1)!;
			return { url };
		}
		case "issue.labels": {
			const add = list("add");
			const remove = list("remove");
			await gh(["issue", "edit", n, ...repo, ...(add === "" ? [] : ["--add-label", add]), ...(remove === "" ? [] : ["--remove-label", remove])], cwd);
			return {};
		}
		case "issue.edit":
			await gh(["issue", "edit", n, ...repo, "--title", String(args.title), "--body", String(args.body)], cwd);
			return {};
		case "issue.close":
			await gh(["issue", "close", n, ...repo, "--reason", String(args.reason)], cwd);
			return {};
		case "issue.reopen":
			await gh(["issue", "reopen", n, ...repo], cwd);
			return {};
		case "pr.create": {
			const url = (await gh(["pr", "create", ...repo, "--head", String(args.head), "--base", String(args.base), "--title", String(args.title), "--body", String(args.body)], cwd)).trim().split("\n").at(-1)!;
			return { number: numberIn(url), url };
		}
		case "pr.merge":
			await gh(["pr", "merge", n, ...repo, "--merge"], cwd);
			return {};
	}
}

/** Look on GitHub for what intent `intent` would have made: what it found, or undefined. Throws when GitHub cannot be asked. */
async function look(project: Project, intent: Intent): Promise<{ result: unknown } | undefined> {
	const repo = ["--repo", repoName(repositoryOf(project))];
	const cwd = folderOf(project);
	const args = intent.args;
	const has = (body: string | undefined) => body?.includes(marker(intent.id)) === true;
	switch (intent.action) {
		case "issue.create": {
			const recent = json<{ number: number; body?: string; url: string }[]>(await gh(["issue", "list", ...repo, "--state", "all", "--limit", "30", "--json", "number,body,url"], cwd));
			const found = recent.find((issue) => has(issue.body));
			return found === undefined ? undefined : { result: { number: found.number, url: found.url } };
		}
		case "issue.comment":
		case "pr.comment": {
			const { comments } = json<{ comments?: GhComment[] }>(await gh([intent.action === "pr.comment" ? "pr" : "issue", "view", String(args.number), ...repo, "--json", "comments"], cwd));
			const found = (comments ?? []).find((comment) => has(comment.body));
			return found === undefined ? undefined : { result: { url: found.url ?? "" } };
		}
		case "pr.create": {
			const branch = String(args.head).replace(/^[^:]*:/, "");
			const pulls = json<{ number: number; body?: string; url: string }[]>(await gh(["pr", "list", ...repo, "--state", "all", "--head", branch, "--limit", "30", "--json", "number,body,url"], cwd));
			const found = pulls.find((pull) => has(pull.body));
			return found === undefined ? undefined : { result: { number: found.number, url: found.url } };
		}
		case "pr.merge": {
			const { state } = json<{ state: string }>(await gh(["pr", "view", String(args.number), ...repo, "--json", "state"], cwd));
			return state.toUpperCase() === "MERGED" ? { result: {} } : undefined;
		}
		default: {
			const issue = json<GhIssue>(await gh(["issue", "view", String(args.number), ...repo, "--json", "title,body,state,stateReason,labels"], cwd));
			const labels = (issue.labels ?? []).map((label) => label.name);
			const closed = issue.state.toUpperCase() === "CLOSED";
			const holds =
				intent.action === "issue.labels"
					? ((args.add as string[] | undefined) ?? []).every((label) => labels.includes(label)) && !((args.remove as string[] | undefined) ?? []).some((label) => labels.includes(label))
					: intent.action === "issue.edit"
						? issue.title === args.title && (issue.body ?? "") === args.body
						: intent.action === "issue.close"
							? closed && (issue.stateReason ?? "").toUpperCase() === (args.reason === "not planned" ? "NOT_PLANNED" : "COMPLETED")
							: !closed;
			return holds ? { result: {} } : undefined;
		}
	}
}

/** Mark intent `id` of the project; done keeps what it made, and a pull request's opener (3.11). */
async function mark(project: Project, id: string, state: IntentState, result?: unknown): Promise<void> {
	await commit(async (tx) => {
		const entry = await entryIn(tx, project);
		const intent = entry.intents[id];
		if (intent === undefined) return;
		intent.state = state;
		if (result !== undefined) intent.result = copy(result);
		if (state === "done" && intent.action === "pr.create" && typeof intent.args.openedBy === "number") {
			const number = (result as { number?: number } | undefined)?.number;
			if (typeof number === "number" && Number.isSafeInteger(number)) entry.openedBy[String(number)] = { conversationId: intent.args.openedBy, at: Date.now() };
		}
		const settled = Object.values(entry.intents).filter((one) => one.state === "done" || one.state === "failed").sort((a, b) => a.at - b.at);
		for (const old of settled.slice(0, Math.max(0, settled.length - KEPT_INTENTS))) delete entry.intents[old.id];
	});
	await readMirror();
	if (state === "unknown" || state === "done") announce();
}

/**
 * An intent found pending: look for what it made. Found, it is done. A state not set is written now. A creating write
 * not found, or not looked for, is unknown. `ended`: this engine's own `gh` for it has ended, with `failure`.
 */
async function settlePending(project: Project, intent: Intent, failure?: GhError): Promise<unknown> {
	let found: { result: unknown } | undefined;
	try {
		found = await look(project, intent);
	} catch (error) {
		noteFailure(project, error);
		if (!CREATING.has(intent.action)) {
			await mark(project, intent.id, "failed");
			throw failure ?? error;
		}
		await mark(project, intent.id, "unknown");
		throw new UnknownWrite(unknownWords(String(intent.args.summary ?? intent.action)));
	}
	if (found !== undefined) {
		await mark(project, intent.id, "done", found.result);
		return found.result;
	}
	if (!CREATING.has(intent.action)) {
		if (failure !== undefined) {
			await mark(project, intent.id, "failed");
			throw failure;
		}
		// Not set, after a restart: writing a state again cannot make anything twice.
		return run(project, intent);
	}
	await mark(project, intent.id, "unknown");
	throw new UnknownWrite(unknownWords(String(intent.args.summary ?? intent.action)));
}

/** Make the intent's write, and mark it by how it went. */
async function run(project: Project, intent: Intent): Promise<unknown> {
	try {
		const result = await perform(project, intent.action, intent.args);
		await mark(project, intent.id, "done", result);
		return result;
	} catch (error) {
		const failure = error instanceof GhError ? error : new GhError("unclear", error instanceof Error ? error.message : String(error));
		if (failure.kind === "unclear") return settlePending(project, intent, failure);
		noteFailure(project, failure);
		await mark(project, intent.id, "failed", { error: failure.said });
		throw failure;
	}
}

/**
 * Write to GitHub through intent `id` (3.11): recorded, made, marked. Found done already, it answers what it made; found
 * pending, it is looked for first; found unknown, nothing is written and the call is told so.
 */
async function write(project: Project, id: string, kind: WriteKind, args: Record<string, unknown>): Promise<unknown> {
	return locked(id, async () => {
		const prior = await commit(async (tx) => {
			const entry = await entryIn(tx, project);
			const intent = entry.intents[id];
			if (intent === undefined || intent.state === "failed") {
				entry.intents[id] = { id, action: kind, args: copy(args), at: Date.now(), state: "pending" };
				return undefined;
			}
			return copy(intent);
		});
		await readMirror();
		if (prior?.state === "done") return prior.result;
		if (prior?.state === "unknown") throw new UnknownWrite(unknownWords(String(prior.args.summary ?? prior.action)));
		if (prior?.state === "pending") return settlePending(project, prior);
		return run(project, mirror.projects[project.id]!.intents[id]!);
	});
}

/** Look for what every pending intent of the project made, once GitHub answers (after a restart). */
async function reconcileAll(project: Project): Promise<void> {
	for (const intent of Object.values(intentsOf(project))) {
		if (intent.state !== "pending" || locks.has(intent.id)) continue;
		await locked(intent.id, async () => {
			const now = mirror.projects[project.id]?.intents[intent.id];
			if (now?.state === "pending") await settlePending(project, now);
		}).catch((error) => engine?.log("could not settle a GitHub write:", error instanceof Error ? error.message : error));
	}
}

/** The labels of scripts/issue, made in the repository when it lacks them, once per repository while the engine runs. */
async function ensureLabels(project: Project): Promise<void> {
	const name = repoName(repositoryOf(project));
	if (labelled.has(name)) return;
	const cwd = folderOf(project);
	const have = new Set(json<{ name: string }[]>(await gh(["label", "list", "--repo", name, "--limit", "200", "--json", "name"], cwd)).map((label) => label.name));
	for (const [label, { color, description }] of Object.entries({ ...STATUS_LABELS, ...CLASS_LABELS })) {
		if (!have.has(label)) await gh(["label", "create", label, "--repo", name, "--color", color, "--description", description, "--force"], cwd);
	}
	labelled.add(name);
}

// ---- Work on GitHub: one row of the table (3.11) as writes

/** The key of a call's intents, and each step's intent id. Made from the call's id, so a call run again finds them. */
function keysOf(project: Project, seed: string) {
	const call = createHash("sha256").update(`${project.id}\n${seed}`).digest("hex").slice(0, 16);
	return { call, step: (step: string) => createHash("sha256").update(`${call}\n${step}`).digest("hex").slice(0, 16) };
}

const WORK_DONE: Record<WorkAction, string> = {
	file: "Filed",
	take: "Took",
	assign: "Assigned",
	release: "Released",
	wait: "Marked as waiting",
	block: "Marked as blocked",
	resume: "Resumed",
	finish: "Finished",
	close: "Closed",
	reopen: "Reopened",
	note: "Added a note to",
	edit: "Edited",
	classify: "Classified",
};
const short = (title: string) => {
	const line = title.replace(/\s+/g, " ").trim();
	return line.length > 60 ? `${line.slice(0, 59).trimEnd()}…` : line;
};

/** Record an agent's write on GitHub as a change with no Undo (3.12), in the commit `tx`: its id. */
async function recordGithub(tx: Tx, project: Project, by: Who, call: Call | undefined, intent: string, action: WorkAction | PullAction, summary: string): Promise<number | undefined> {
	if (by.kind !== "agent") return undefined;
	const change = await record(tx, project.id, { by: { kind: "agent", agentId: by.agentId, conversationId: by.conversationId, callId: call?.api.callId ?? "" }, op: { kind: "work.github", intent, action, summary }, inverse: null, summary });
	return change.id;
}

/** The labels to add and take off for an issue to read as `state` and `cls`, from those it has. */
function labelChange(have: string[], state: WorkState | null, cls: WorkItem["class"] | undefined): { add: string[]; remove: string[] } {
	const want = new Set<string>();
	const drop = new Set<string>();
	if (state !== null) {
		const status = STATUS_OF[state];
		for (const label of Object.keys(STATUS_LABELS)) (label === status ? want : drop).add(label);
	}
	if (cls !== undefined) {
		const label = classLabel(cls);
		for (const one of Object.keys(CLASS_LABELS)) (one === label ? want : drop).add(one);
	}
	return { add: [...want].filter((label) => !have.includes(label)), remove: [...drop].filter((label) => have.includes(label)) };
}

function backend(writing: GithubWriting) {
	return {
		list: async (current: Project, { states: wanted }: { states?: WorkState[] }) => {
			try {
				await readListing(current);
			} catch (error) {
				if (listingOf(current) === undefined) throw error;
			}
			return (listingOf(current)?.issues ?? []).filter((item) => wanted === undefined || wanted.includes(item.state));
		},
		show: async (current: Project, id: number) => {
			try {
				await readMirror();
				const item = issueItem(await viewIssue(current, id), intentsOf(current));
				keepInListing(current, item);
				return item;
			} catch (error) {
				noteFailure(current, error);
				const cached = listingOf(current)?.issues.find((one) => one.id === id);
				if (cached === undefined || !(error instanceof GhError)) throw error;
				return cached;
			}
		},
		apply: (current: Project, action: WorkAction, id: number | null, by: Who, args: Record<string, unknown>) => noting(current, applyOnGithub(current, action, id, by, args, writing)),
	};
}

async function applyOnGithub(given: Project, action: WorkAction, id: number | null, by: Who, args: Record<string, unknown>, writing: GithubWriting): Promise<WorkItem> {
	const { call, confirmedSwitch, assign } = writing;
	if (call !== undefined) {
		const receipt = await workReceiptOf(call);
		if (receipt?.refused !== undefined) throw new Error(receipt.refused);
		if (receipt?.item != null) return receipt.item;
	}
	const { project, agents } = copy(await commit(async (tx) => copy(await checkWriterIn(tx, given.id, by, action, confirmedSwitch, true))));
	const names = (agentId: string) => agents[agentId]?.name ?? agentId;
	const keys = keysOf(project, call?.api.callId ?? randomUUID());
	const step = keys.step;
	const base = { call: keys.call, by };
	await readMirror();
	const resuming = Object.values(intentsOf(project)).some((intent) => intent.args.call === keys.call);
	await ensureLabels(project);
	let number = id;
	let issue = number === null ? undefined : await viewIssue(project, number);
	let before = issue === undefined ? null : issueItem(issue, intentsOf(project));
	if (before !== null && !resuming) checkWorkTransition(project, before, action, by, names);
	// The shapes and limits of what is given, checked as the list kept by pi² checks them.
	const after = workTransition(before, number ?? 1, action, by, args, Date.now(), action === "assign" ? { agentId: "", conversationId: 0 } : undefined);
	const text = typeof args.text === "string" ? args.text : undefined;
	const comment = async (key: string, role: string, said: string, extra: Record<string, unknown> = {}) =>
		write(project, step(key), "issue.comment", { ...base, number, role, body: compose(project, by, said, step(key)), summary: `commenting on #${number}`, ...extra });
	const labels = async (state: WorkState | null, cls?: WorkItem["class"]) => {
		const now = await viewIssue(project, number!);
		const change = labelChange((now.labels ?? []).map((label) => label.name), state, cls);
		if (change.add.length === 0 && change.remove.length === 0) return;
		await write(project, step(`labels:${state}:${cls}`), "issue.labels", { ...base, number, ...change, summary: `labelling #${number}` });
	};
	let admittedNote: string | undefined;
	const holderName = (holder: WorkItem["takenBy"]) => (holder === null ? "nobody" : names(holder.agentId));

	switch (action) {
		case "file": {
			const labelsOf = ["backlog", ...(after.class === null ? [] : [classLabel(after.class)!])];
			const made = (await write(project, step("create"), "issue.create", { ...base, title: after.title, body: compose(project, by, after.text, step("create")), labels: labelsOf, summary: `filing “${short(after.title)}”` })) as { number: number };
			number = made.number;
			break;
		}
		case "take":
		case "assign": {
			const claimKey = step("claim");
			let claim = intentsOf(project)[claimKey];
			if (action === "assign" && claim === undefined) {
				// The admission check of #464, before the item is claimed: a start held back claims nothing.
				if (assign === undefined) throw new Error("The assigned agent's sub-chat was not started.");
				const admitted = await commit(async (tx) => copy(await assign.admit(tx, project, before!)), call);
				if (!admitted.ok) {
					if (by.kind === "person") throw limitError(admitted.limit);
					const refused = limitRefusal(admitted.limit, project.conversation !== null);
					if (call !== undefined) await commit((tx) => workReceipt(tx, call, { item: null, refused }), call);
					throw new Error(refused);
				}
				admittedNote = admitted.note;
			}
			const holder = action === "take" && by.kind === "agent" ? { agentId: by.agentId, conversationId: by.conversationId } : { agentId: assign?.agentId ?? "", conversationId: null };
			if (action === "assign" && holder.agentId === "") throw new Error("The assigned agent's sub-chat was not started.");
			const seen = (claim?.args.seen as string[] | undefined) ?? (issue?.comments ?? []).map((one) => one.url ?? "");
			const said = action === "take" ? `Taken by ${names(holder.agentId)}, in ${by.kind === "agent" ? `conversation ${by.conversationId}` : "pi²"}.` : `Taken by ${names(holder.agentId)}, assigned by ${by.kind === "person" ? "the person" : "the orchestrator"}.`;
			await comment("claim", "take", said, { holder, seen, parent: project.conversation, ...(admittedNote === undefined ? {} : { admitted: admittedNote }) });
			await readMirror();
			claim = intentsOf(project)[claimKey]!;
			// Two takes at once: the earlier "Taken by" of another holder stands, and this one lets go.
			const fresh = await viewIssue(project, number!);
			const comments = (fresh.comments ?? []).map((one) => parseComment(one, intentsOf(project)));
			const mine = comments.findIndex((one) => one.intent?.id === claimKey);
			const rival = standing(comments.slice(0, mine === -1 ? comments.length : mine)).find(
				(one) => (!seen.includes(one.url) || Date.now() - one.at < IN_FLIGHT_MS) && !sameHolder(one.holder, claim!.args.holder as Parsed["holder"]),
			);
			if (rival !== undefined) {
				await comment("lost", "release", `Released: ${names(holder.agentId)} did not take it after all.`, { holder: claim.args.holder });
				readSoon(project);
				const taken = holderOf(rival)!;
				throw new Error(`#${number} is taken by ${names(taken.agentId)}, in sub-chat ${taken.conversationId}`);
			}
			if (action === "assign" && (claim.args.holder as Parsed["holder"])!.conversationId === null) {
				try {
					await commit(async (tx) => {
						const entry = await entryIn(tx, project);
						const stored = entry.intents[claimKey]!;
						const now = stored.args.holder as NonNullable<Parsed["holder"]>;
						if (now.conversationId !== null) return;
						const started = await assign!.start(tx, project, before!, { note: (stored.args.admitted as string | undefined) ?? admittedNote });
						stored.args.holder = started;
					}, call);
				} catch (error) {
					// The start was refused: the claim is let go, and the item is as it was.
					await comment("letgo", "release", `Released: ${names(holder.agentId)} could not be started.`, { holder: claim.args.holder }).catch((failure) => engine?.log("could not let go of a claim on GitHub:", failure instanceof Error ? failure.message : failure));
					readSoon(project);
					throw error;
				}
				await readMirror();
				admittedNote = (intentsOf(project)[claimKey]?.args.admitted as string | undefined) ?? admittedNote;
			}
			await labels("in_progress");
			break;
		}
		case "release":
			await comment("release", "release", `Released: ${holderName(before!.takenBy)} no longer works on it.`, { holder: before!.takenBy ?? undefined });
			await labels("open");
			break;
		case "wait":
		case "block":
			if (text?.trim()) await comment("note", action, `**${action === "wait" ? "Waiting" : "Blocked"}:** ${text}`);
			await labels(after.state);
			break;
		case "resume":
			await labels("in_progress");
			break;
		case "finish":
		case "close": {
			// Always a comment: it ends every hold, so a "Taken by" before it never counts again.
			const done = after.state === "done";
			await comment("done", done ? "done" : "dropped", `**${done ? "Done" : "Dropped"}.**${text?.trim() ? ` ${text}` : ""}`);
			await labels(null);
			const now = await viewIssue(project, number!);
			if (now.state.toUpperCase() !== "CLOSED") await write(project, step("close"), "issue.close", { ...base, number, reason: done ? "completed" : "not planned", summary: `closing #${number}` });
			break;
		}
		case "reopen": {
			await labels("open");
			const now = await viewIssue(project, number!);
			if (now.state.toUpperCase() === "CLOSED") await write(project, step("reopen"), "issue.reopen", { ...base, number, summary: `reopening #${number}` });
			break;
		}
		case "note":
			await comment("note", "note", text ?? "");
			break;
		case "edit": {
			// The text keeps the line and the marker pi² filed it with, so who filed it is still known.
			const body = issue?.body ?? "";
			const head = AGENT_LINE.exec(body)?.[0] ?? "";
			const tail = MARKER.exec(body)?.[0];
			const edited = `${head}${after.text}${tail === undefined ? "" : `\n\n${tail}`}`;
			if (after.title !== before!.title || edited !== body) await write(project, step("edit"), "issue.edit", { ...base, number, title: after.title, body: edited, summary: `editing #${number}` });
			break;
		}
		case "classify":
			await labels(null, after.class);
			break;
	}

	await readMirror();
	issue = await viewIssue(project, number!);
	const item = issueItem(issue, intentsOf(project));
	before = before ?? null;
	keepInListing(project, item);
	const main = action === "file" ? step("create") : action === "take" || action === "assign" ? step("claim") : step(action);
	await commit(async (tx) => {
		const change = await recordGithub(tx, project, by, call, main, action, `${WORK_DONE[action]} #${item.id} “${short(item.title)}” on GitHub`);
		await workNews(tx, project, by, workNewsText(item, action), String(item.id));
		if (call !== undefined) await workReceipt(tx, call, { item, ...(change === undefined ? {} : { change }), ...(admittedNote === undefined ? {} : { note: admittedNote }) });
	}, call);
	readSoon(project);
	return item;
}

// ---- Pull requests (5.7)

/** The branch to open a pull request from: the folder's branch, as GitHub names its upstream ("owner:branch" from a fork). */
export async function headOf(folder: string, repository: Repository): Promise<{ head: string; branch: string }> {
	const tryGit = (args: string[]) => git(args, folder).then((out) => out.trim(), () => undefined);
	const branch = await tryGit(["rev-parse", "--abbrev-ref", "HEAD"]);
	if (branch === undefined || branch === "") throw new Error("This conversation's folder is not in a git repository.");
	if (branch === "HEAD") throw new Error("Check out a branch first: this folder's checkout is on no branch.");
	const remote = await tryGit(["config", `branch.${branch}.remote`]);
	const merge = await tryGit(["config", `branch.${branch}.merge`]);
	if (!remote || !merge || remote === ".") throw new Error("Push the branch first: it has no upstream.");
	const upstream = merge.replace(/^refs\/heads\//, "");
	const url = (await tryGit(["remote", "get-url", remote])) ?? remote;
	const where = parseRemote(url);
	if (where === undefined) throw new Error(`The branch's upstream, ${remote}, is not on GitHub.`);
	return { head: sameRepository(where, repository) ? upstream : `${where.owner}:${upstream}`, branch: upstream };
}

async function defaultBranch(project: Project): Promise<string> {
	const view = json<{ defaultBranchRef?: { name?: string } | null }>(await gh(["repo", "view", repoName(repositoryOf(project)), "--json", "defaultBranchRef"], folderOf(project)));
	const name = view.defaultBranchRef?.name;
	if (!name) throw new Error(`${repoName(repositoryOf(project))} has no default branch. Give base.`);
	return name;
}

/** Merge pull request `number` (`gh pr merge --merge`), refusing one that cannot be merged, with GitHub's reason. */
async function mergePull(project: Project, number: number, key: string, by: Who): Promise<PullRequest> {
	const pull = await viewPull(project, number);
	if (pull.state.toUpperCase() === "CLOSED") throw new Error(`Pull request #${number} is closed, so it cannot be merged.`);
	if (pull.state.toUpperCase() !== "MERGED") {
		if (pull.mergeable === "CONFLICTING") throw new Error(`Pull request #${number} cannot be merged: it conflicts with ${pull.baseRefName}.`);
		try {
			await write(project, key, "pr.merge", { by, number, role: "merge", summary: `merging pull request #${number}` });
		} catch (error) {
			if (error instanceof GhError && error.kind === "refused") throw new Error(`GitHub would not merge pull request #${number}: ${error.said}`);
			throw error;
		}
	}
	await readMirror();
	const merged = pullOf(await viewPull(project, number), intentsOf(project), mirror.projects[project.id]?.openedBy);
	keepInListing(project, undefined, merged);
	readSoon(project);
	return merged;
}

export const SENT_BACK_ENTRY = "pi2.sentBack";
const sentBackText = (data: { by: Who; number: number; reason: string }) => `${data.by.kind === "person" ? "The person" : "Orchestrator"} sent back pull request #${data.number}: ${data.reason}`;

/** The transcript's line for a pull request sent back (3.11): not a message the person typed. */
export function githubItem(entry: EntryRecord): { id: number; kind: "marker"; text: string; details: { wake: { text: string } } } | undefined {
	if (entry.kind !== SENT_BACK_ENTRY) return undefined;
	const data = entry.data as { by: Who; number: number; reason: string };
	const text = sentBackText(data);
	return { id: entry.id as unknown as number, kind: "marker", text, details: { wake: { text } } };
}

/**
 * Send back pull request `number`: the reason on it, then to the conversation that opened it, as an input of its own
 * kind (`pi2.sentBack`). Answers what was done, in words.
 */
async function sendBack(project: Project, number: number, reason: string, by: Who, key: string, call?: Call): Promise<string> {
	if (reason.trim() === "") throw new Error("Say why it goes back, in text.");
	const pull = await viewPull(project, number);
	await write(project, key, "pr.comment", { by, number, role: "send_back", body: compose(project, by, `**Sent back.** ${reason}`, key), summary: `sending back pull request #${number}` });
	await readMirror();
	const opened = mirror.projects[project.id]?.openedBy[String(number)];
	const data = { by, number, reason };
	let told = `Sent back pull request #${number} “${pull.title}”, with the reason on it.`;
	if (opened === undefined) told += " Nobody opened it through pi², so no conversation was told.";
	else {
		const harness = engine!.harness();
		const conversation = await harness.conversation(opened.conversationId as unknown as ConversationId, engine!.context());
		const meta = engine!.library().conversations[String(opened.conversationId)];
		if (conversation === undefined || meta === undefined || meta.deleted === true || meta.archivedAt !== undefined) told += ` Conversation ${opened.conversationId}, which opened it, is put away, so it was not told.`;
		else {
			const requestId = `${SENT_BACK_ENTRY}:${key}`;
			await harness.commit(async (tx) => {
				if ((await tx.submissionByRequest(conversation.id, requestId)) !== undefined) return;
				const conversations = (await tx.doc(Library)).conversations;
				await syncWorkForInput(tx, conversation.id, conversations[String(opened.conversationId)]);
				await conversation.submit(tx, { type: "input", content: sentBackText(data), entry: { kind: SENT_BACK_ENTRY, data: copy(data) as never }, whenBusy: "followUp", requestId });
				const now = conversations[String(opened.conversationId)];
				if (now !== undefined) now.updatedAt = Date.now();
			}, engine!.context());
			told += ` Conversation ${opened.conversationId}, which opened it, was given it.`;
		}
	}
	readSoon(project);
	return told;
}

/** Every pull-request action of `work` (5.7); the tool has checked who may. */
async function pull(project: Project, action: PullAction, by: Who, args: Record<string, unknown>, call: Call): Promise<{ text: string; change?: number }> {
	const receipt = await workReceiptOf(call);
	if (receipt?.text !== undefined) return { text: receipt.text, ...(receipt.change === undefined ? {} : { change: receipt.change }) };
	const keys = keysOf(project, call.api.callId);
	const key = keys.step(action);
	const id = args.id;
	const number = () => {
		if (typeof id !== "number" || !Number.isSafeInteger(id) || id < 1) throw new Error("id must be the pull request's number");
		return id;
	};
	const reasonOf = () => (typeof args.text === "string" ? args.text : "");
	let text: string;
	let summary: string;
	if (action === "pull_request") {
		if (by.kind !== "agent") throw new Error("Only an agent opens a pull request.");
		const folder = (await call.api.snapshot(AgentDoc, call.api.conversationId, call.context))?.cwd ?? project.folder;
		if (folder === null || folder === undefined) throw new Error("This conversation has no folder, so it has no branch to open a pull request from.");
		const fixes = typeof id === "number" ? id : null;
		const item = fixes === null ? undefined : await backend({}).show(project, fixes);
		const title = (typeof args.title === "string" ? args.title.trim() : "") || (item === undefined ? "" : item.title);
		if (title === "") throw new Error("Give the pull request a title.");
		const { head } = await headOf(folder, repositoryOf(project));
		const baseBranch = typeof args.base === "string" && args.base.trim() !== "" ? args.base.trim() : await defaultBranch(project);
		let said = typeof args.text === "string" ? args.text : "";
		if (fixes !== null && !new RegExp(`\\b(?:fix(?:e[sd])?|close[sd]?|resolve[sd]?)\\s+#${fixes}\\b`, "i").test(said)) said = said.trim() === "" ? `Fixes #${fixes}` : `${said}\n\nFixes #${fixes}`;
		const made = (await write(project, key, "pr.create", { call: keys.call, by, role: "pull_request", head, base: baseBranch, title, body: compose(project, by, said, key), openedBy: by.conversationId, summary: `opening the pull request “${short(title)}”` })) as { number: number; url: string };
		text = `Opened pull request #${made.number} from ${head} into ${baseBranch}: ${made.url}`;
		summary = `Opened pull request #${made.number} “${short(title)}” on GitHub`;
	} else if (action === "review") {
		const verdict = (typeof args.verdict === "string" ? args.verdict : "comment") as Verdict;
		if (!Object.hasOwn(VERDICTS, verdict)) throw new Error("verdict must be approve, changes or comment");
		const finding = reasonOf();
		if (finding.trim() === "") throw new Error("Say what you found, in text.");
		const n = number();
		const pr = await viewPull(project, n);
		const name = by.kind === "agent" ? agentName(by.agentId) : "the person";
		const made = (await write(project, key, "pr.comment", { call: keys.call, by, number: n, role: "review", verdict, agentName: name, body: compose(project, by, `**${VERDICTS[verdict]}.** ${finding}`, key), summary: `posting a finding on pull request #${n}` })) as { url: string };
		text = `Posted your finding (${VERDICTS[verdict].toLowerCase()}) on pull request #${n} “${pr.title}”: ${made.url}`;
		summary = `Reviewed pull request #${n} “${short(pr.title)}” on GitHub: ${VERDICTS[verdict].toLowerCase()}`;
	} else if (action === "merge") {
		const n = number();
		const pr = await viewPull(project, n);
		if (pr.state.toUpperCase() === "OPEN" && by.kind === "agent") {
			const answer = await requireSwitch({ conversationId: by.conversationId, id: String(call.api.taskId), callId: call.api.callId, tool: "work", arguments: { action, id: n }, api: call.api, context: call.context }, "merge", `Merge pull request #${n} “${pr.title}”?`);
			if (!answer.ok) throw new Error(answer.reason);
		}
		await mergePull(project, n, key, by);
		text = `Merged pull request #${n} “${pr.title}”.`;
		summary = `Merged pull request #${n} “${short(pr.title)}” on GitHub`;
	} else {
		const n = number();
		text = await sendBack(project, n, reasonOf(), by, key, call);
		summary = `Sent back pull request #${n} on GitHub`;
	}
	const done = await commit(async (tx) => {
		const change = await recordGithub(tx, project, by, call, key, action, summary);
		await workNews(tx, project, by, summary.replace(/ on GitHub/, ""), `pull:${key}`);
		await workReceipt(tx, call, { item: null, text, ...(change === undefined ? {} : { change }) });
		return change;
	}, call);
	readSoon(project);
	return { text, ...(done === undefined ? {} : { change: done }) };
}

/** Start Anyway on a limit card for an assignment on GitHub: claim the item, then start, after the card's commit. */
async function assignHeld(project: Project, start: Start, launch: (tx: Tx, item: WorkItem) => Promise<NonNullable<WorkItem["takenBy"]>>): Promise<WorkItem> {
	try {
		return await applyOnGithub(project, "assign", start.work!, { kind: "person" }, { agentId: start.agentId }, {
			assign: {
				agentId: start.agentId,
				admit: async () => ({ ok: true }),
				start: (tx, _project, item) => launch(tx, item),
			},
		});
	} catch (error) {
		const why = error instanceof Error ? error.message : String(error);
		await commit((tx) => addNews(tx, project.id, { kind: "limit", text: `Work #${start.work} could not start with ${start.agentName} after all: ${why}`, ref: String(start.work) })).catch(() => {});
		throw error;
	}
}

// ---- Attaching (4.2; for an agent, a reach request: 7.1)

/** Whether `gh` can see `owner/name`: its name as GitHub spells it. Refuses, saying why, when it cannot. */
export async function checkRepository(repository: Repository, cwd: string): Promise<Repository> {
	try {
		const view = json<{ nameWithOwner?: string }>(await gh(["repo", "view", repoName(repository), "--json", "nameWithOwner,defaultBranchRef"], cwd));
		return parseRepository(view.nameWithOwner ?? "") ?? repository;
	} catch (error) {
		const said = error instanceof GhError ? error.said : error instanceof Error ? error.message : String(error);
		throw new Error(`gh cannot reach ${repoName(repository)}: ${said}`);
	}
}

/**
 * Attach `repository` to project `projectId`, or detach with null, in the commit `tx`: what `github.attach` and
 * `github.detach` do, and the project's `repository` field when an agent's request for it is allowed (changes.ts).
 * `gh` is asked before, outside the commit.
 */
export async function setRepositoryIn(tx: Tx, projectId: string, repository: Repository | null): Promise<void> {
	const project = (await tx.doc(Projects)).projects[projectId];
	if (project === undefined || project.deletedAt !== undefined) throw new Error(`Unknown project: ${projectId}`);
	if (project.archivedAt !== undefined) throw new Error(PROJECT_ARCHIVED);
	if (repository !== null) {
		if (project.folder === null) throw new Error("This project has no folder. Give it the repository's folder first.");
		const open = Object.values((await tx.doc(Work)).projects[projectId]?.items ?? {}).filter((item) => item.state !== "done" && item.state !== "dropped");
		if (open.length > 0) throw new Error(`Close or move this project's open work first: ${open.slice(0, 10).map((item) => `#${item.id} “${short(item.title)}”`).join(", ")}${open.length > 10 ? `, and ${open.length - 10} more` : ""}.`);
	}
	project.repository = repository === null ? null : { owner: repository.owner, name: repository.name };
	project.updatedAt = Date.now();
}

/** The project's writes whose outcome pi² could not tell, oldest first (3.11): what the `github` event carries and `github.unknown` answers (#573). */
function unknownWrites(project: Project): { intent: string; summary: string; at: number }[] {
	return Object.values(intentsOf(project))
		.filter((intent) => intent.state === "unknown")
		.sort((a, b) => a.at - b.at)
		.map((intent) => ({ intent: intent.id, summary: String(intent.args.summary ?? intent.action), at: intent.at }));
}

// ---- The feature

type Watch = { projectId: string; tabs: string[] };

export const github: Feature = (host, running) => {
	engine = running;
	listingFile = join(running.home, "github.json");
	/** What each app shows now (`projects.watch`), by connection. */
	const watching = new Map<object, Watch>();
	let timer: NodeJS.Timeout | undefined;
	let sent = "";

	const event = () => {
		const projects: Record<string, unknown> = {};
		for (const project of Object.values(allProjects())) {
			if (project.repository === null || project.deletedAt !== undefined) continue;
			const listing = listingOf(project);
			const status = states.get(project.id) ?? { state: listing === undefined ? "loading" : "ok", error: null };
			projects[project.id] = {
				state: status.state,
				error: status.error,
				readAt: listing?.readAt ?? null,
				repository: copy(project.repository),
				issues: listing?.issues ?? [],
				pulls: listing?.pulls ?? [],
				unknown: unknownWrites(project),
			};
		}
		return { event: "github", projects };
	};
	announce = () => {
		const next = event();
		const line = JSON.stringify(next);
		if (line === sent) return;
		sent = line;
		running.broadcast(next);
	};

	const watched = () => {
		const ids = new Set<string>();
		for (const watch of watching.values()) if (watch.tabs.length > 0) ids.add(watch.projectId);
		return ids;
	};
	const look = () => {
		for (const id of watched()) {
			const project = allProjects()[id];
			if (project?.repository != null && project.deletedAt === undefined) void readListing(project).catch(() => {});
		}
	};
	const keepLooking = () => {
		if (watched().size > 0 && timer === undefined) {
			timer = setInterval(look, READ_EVERY_MS);
			timer.unref();
		} else if (watched().size === 0 && timer !== undefined) {
			clearInterval(timer);
			timer = undefined;
		}
	};

	const projectFor = (value: unknown, write = false): Project => {
		if (typeof value !== "string") throw new Error("projectId must be a project's id");
		const project = allProjects()[value];
		if (project === undefined || project.deletedAt !== undefined) throw new Error(`Unknown project: ${value}`);
		if (write && project.archivedAt !== undefined) throw new Error(PROJECT_ARCHIVED);
		return project;
	};
	const attached = (value: unknown, write = false): Project => {
		const project = projectFor(value, write);
		if (project.repository === null) throw new Error("This project has no repository attached.");
		return project;
	};
	const numberOf = (value: unknown) => {
		if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 1) throw new Error("number must be a pull request's number");
		return value;
	};

	defineOp("work.github", {
		check: async () => "This was done on GitHub; it cannot be undone here.",
		apply: async () => {
			throw new Error("This was done on GitHub; it cannot be undone here.");
		},
		inverse: () => null,
		// Work never widens reach (7.1).
		widens: () => false,
	});
	wireRepository(async (tx, projectId, value) => {
		const repository = value === null ? null : parseRepository(`${(value as Repository).owner}/${(value as Repository).name}`);
		if (value !== null && repository === undefined) throw new Error("repository must be owner/name");
		await setRepositoryIn(tx, projectId, repository ?? null);
	});
	wireGithubWork({
		backend: (_project, writing) => backend(writing),
		readAt: (project) => listingOf(project)?.readAt ?? null,
		pulls: (project) => listingOf(project)?.pulls ?? [],
		listingNote,
		pull: (project, action, by, args, call) => noting(project, pull(project, action, by, args, call)),
		assignHeld,
	});
	wireWorkState(async (tx, project, local) => {
		if (project.repository === null) return local(tx, project);
		const open: WorkState[] = ["open", "in_progress", "waiting", "blocked"];
		const items = (listingOf(project)?.issues ?? []).filter((item) => open.includes(item.state));
		if (items.length === 0) return { counts: {}, held: [] };
		const counts = Object.fromEntries(open.map((state) => [state, items.filter((item) => item.state === state).length]));
		const held = items
			.filter((item) => item.state !== "open")
			.sort((a, b) => open.indexOf(a.state) - open.indexOf(b.state) || a.id - b.id)
			.map((item) => ({ id: item.id, title: item.title, state: item.state, agent: item.takenBy === null ? null : agentName(item.takenBy.agentId) }));
		return { counts, held };
	});

	return {
		start: async () => {
			loadListings();
			await readMirror();
			running.harness().observeCommits({
				advance: ({ changes }) => {
					const kinds = new Set(changes.filter((one) => one.type === "document" || one.type === "document.copy").map((one) => one.record.kind));
					if (kinds.has("pi2.github")) void readMirror().then(announce, (error) => running.log("could not read pi2.github again:", error));
					// A repository attached by an agent's allowed request (changes.ts) is read at once.
					if (kinds.has("pi2.projects")) {
						setTimeout(() => {
							for (const project of Object.values(allProjects())) {
								if (project.repository !== null && project.deletedAt === undefined && listingOf(project) === undefined && !reading.has(project.id)) readSoon(project);
							}
							announce();
						}, 0).unref();
					}
				},
				end: () => {},
			});
			// Writes an engine stopped in the middle of are looked for once it is ready and GitHub answers (a listing read
			// settles them), so that GitHub out of reach at that moment does not make them unknown. A call run again looks itself.
			void host.ready.then(() => {
				for (const project of Object.values(allProjects())) {
					if (project.repository === null || project.deletedAt !== undefined) continue;
					if (Object.values(intentsOf(project)).some((intent) => intent.state === "pending")) readSoon(project);
				}
			});
		},
		greeting: () => [event()],
		disconnected: (connection) => {
			watching.delete(connection);
			keepLooking();
		},
		stopping: async () => {
			if (timer !== undefined) clearInterval(timer);
			timer = undefined;
		},
		handlers: {
			/** `{ projectId, tabs }`: this app shows these tabs of this project now; the engine reads GitHub for them. */
			"projects.watch": async (params, connection) => {
				requirePreview();
				const key = connection ?? watching;
				if (params.projectId === null || (Array.isArray(params.tabs) && params.tabs.length === 0)) {
					watching.delete(key);
					keepLooking();
					return {};
				}
				const project = projectFor(params.projectId);
				if (!Array.isArray(params.tabs) || params.tabs.some((tab) => tab !== "now" && tab !== "work")) throw new Error("tabs must be a list of now and work");
				watching.set(key, { projectId: project.id, tabs: [...new Set(params.tabs as string[])] });
				keepLooking();
				if (project.repository !== null) void readListing(project).catch(() => {});
				return {};
			},
			"github.attach": async (params) => {
				requirePreview();
				const project = projectFor(params.projectId, true);
				if (project.folder === null) throw new Error("This project has no folder. Give it the repository's folder first.");
				let wanted: Repository | undefined;
				if (params.repository === undefined || params.repository === null) {
					const origin = await git(["remote", "get-url", "origin"], project.folder).then((out) => out.trim(), () => "");
					wanted = parseRemote(origin);
					if (wanted === undefined) throw new Error("This folder's origin remote is not on GitHub. Name the repository as owner/name.");
				} else {
					wanted = typeof params.repository === "string" ? parseRepository(params.repository) : undefined;
					if (wanted === undefined) throw new Error("repository must be owner/name");
				}
				const repository = await checkRepository(wanted, folderOf(project));
				await running.harness().commit((tx) => setRepositoryIn(tx, project.id, repository), running.context());
				const now = { ...project, repository };
				void readListing(now, true).catch(() => {});
				return { repository };
			},
			"github.detach": async (params) => {
				requirePreview();
				const project = projectFor(params.projectId, true);
				await running.harness().commit((tx) => setRepositoryIn(tx, project.id, null), running.context());
				return {};
			},
			"github.refresh": async (params) => {
				requirePreview();
				await readListing(attached(params.projectId));
				return {};
			},
			"github.merge": async (params) => {
				requirePreview();
				const project = attached(params.projectId, true);
				const n = numberOf(params.number);
				await mergePull(project, n, keysOf(project, randomUUID()).step("merge"), { kind: "person" });
				await commit((tx) => workNews(tx, project, { kind: "person" }, `The person merged pull request #${n}.`, `pull:${n}`));
				return {};
			},
			"github.sendBack": async (params) => {
				requirePreview();
				const project = attached(params.projectId, true);
				if (typeof params.reason !== "string") throw new Error("reason must be text");
				const n = numberOf(params.number);
				await sendBack(project, n, params.reason, { kind: "person" }, keysOf(project, randomUUID()).step("send_back"));
				// The orchestrator is told in its catch-up when the person sent it (3.11).
				await commit((tx) => workNews(tx, project, { kind: "person" }, `The person sent back pull request #${n}: ${params.reason}`, `pull:${n}`));
				return {};
			},
			"github.diff": async (params) => {
				requirePreview();
				const project = attached(params.projectId);
				const n = numberOf(params.number);
				const diff = await gh(["pr", "diff", String(n), "--repo", repoName(repositoryOf(project))], folderOf(project));
				const bytes = Buffer.from(diff, "utf8");
				if (bytes.length <= DIFF_BYTES) return { diff };
				return { diff: `${bytes.subarray(0, DIFF_BYTES).toString("utf8")}\n[pi² cut the diff here: it is longer than 2 MB. gh pr diff ${n} --repo ${repoName(repositoryOf(project))} shows all of it.]` };
			},
			/** `{ projectId }`: the writes whose outcome pi² could not tell, with the id each is settled by (#573). */
			"github.unknown": async (params) => {
				requirePreview();
				await readMirror();
				return { unknown: unknownWrites(attached(params.projectId)) };
			},
			"github.settle": async (params) => {
				requirePreview();
				const project = attached(params.projectId);
				if (typeof params.intent !== "string") throw new Error("intent must be the id of a write whose outcome is unknown");
				if (typeof params.happened !== "boolean") throw new Error("happened must be true or false");
				const id = params.intent;
				await commit(async (tx) => {
					const intent = (await entryIn(tx, project)).intents[id];
					if (intent?.state !== "unknown") throw new Error("That write is not waiting to be settled.");
					intent.state = params.happened ? "done" : "failed";
				});
				await readMirror();
				announce();
				readSoon(project);
				return {};
			},
		},
	};
};

