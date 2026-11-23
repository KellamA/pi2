#!/usr/bin/env node
// A stand-in for GitHub's `gh`, for the engine's tests of work from an attached repository (#468) and for throwaway
// copies (`scripts/test-copy start … --env PI2_GH=…`). It answers the commands github.ts runs, from a JSON file of
// repositories, and never reaches the network. Nothing it is given is checked against a real GitHub.
//
// GH_STAND_IN_STATE names the file. The engine passes its own environment on to `gh` without pi²'s variables, so a test
// starts it through a small shell script that sets this one: see `standInGh` in engine/test/github.ts.
//
// The file holds `{ repos: { "owner/name": { defaultBranch, issues, pulls, labels, next } }, fail?, block? }`:
// - `fail: { kind: "unreachable" | "rate_limited" | "signed_out", match? }` makes every command (or those whose
//   arguments contain `match`) fail as gh does then.
// - `block: { match, when: "before" | "after" }` makes the first command whose arguments contain `match` stop before
//   or after it changes anything, write its process id to `<state>.blocked`, and wait until it is killed or
//   `<state>.release` appears.
// Every command is logged, one JSON line each, to `<state>.log`, with when it began and ended (`at`, `ended`).
//
// For measuring (#599), GH_STAND_IN_DELAY makes each command take as long as the real gh does: `400-900` waits a random
// time in that many milliseconds, and `400-900+6.5` adds 6.5 ms for each kilobyte it prints, as a list with bodies and
// comments costs GitHub more to answer. `delay` in the file, in the same form, does the same for a test, and wins over the variable.
// A search with a qualifier it cannot read (`closed:` or `updated:` without a date it takes) fails as GitHub refuses it.

import { appendFileSync, existsSync, mkdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync, writeSync } from "node:fs";

const file = process.env.GH_STAND_IN_STATE;
if (!file) {
	console.error("GH_STAND_IN_STATE is not set");
	process.exit(2);
}
const args = process.argv.slice(2);
const began = Date.now();
const sleep = (ms) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
/** How long this command waits before it answers, as the real gh would, for `bytes` printed. */
const wait = (bytes) => {
	const delay = /^(\d+)-(\d+)(?:\+([\d.]+))?$/.exec(peek().delay ?? process.env.GH_STAND_IN_DELAY ?? "");
	if (delay === null) return;
	const [low, high, perKb] = [Number(delay[1]), Number(delay[2]), Number(delay[3] ?? 0)];
	sleep(low + Math.random() * (high - low) + (perKb * bytes) / 1024);
};
process.on("exit", () => appendFileSync(`${file}.log`, `${JSON.stringify({ args, cwd: process.cwd(), at: began, ended: Date.now() })}\n`));
const lock = `${file}.lock`;
function withState(change) {
	for (let tries = 0; ; tries++) {
		try {
			mkdirSync(lock);
			break;
		} catch {
			// A lock older than ten seconds was left by a stand-in that was killed.
			try {
				if (Date.now() - statSync(lock).mtimeMs > 10_000) rmSync(lock, { recursive: true, force: true });
			} catch {}
			sleep(5);
		}
	}
	try {
		const state = JSON.parse(readFileSync(file, "utf8"));
		const result = change(state);
		// Whole or not at all: a stand-in running at the same moment reads the file without the lock (`peek`), and once
		// read half of one, failing as GitHub refusing (#707).
		writeFileSync(`${file}.${process.pid}`, JSON.stringify(state, null, "\t"));
		renameSync(`${file}.${process.pid}`, file);
		return result;
	} finally {
		rmSync(lock, { recursive: true, force: true });
	}
}
const peek = () => JSON.parse(readFileSync(file, "utf8"));

function fail(message, code = 1) {
	console.error(message);
	process.exit(code);
}

// ---- Arguments

const [group, command, ...rest] = args;
const flags = {};
const positional = [];
const many = new Set(["label", "add-label", "remove-label"]);
for (let i = 0; i < rest.length; i++) {
	const arg = rest[i];
	if (arg.startsWith("--") || arg === "-R") {
		const name = arg === "-R" ? "repo" : arg.slice(2);
		const value = ["merge", "force"].includes(name) ? true : rest[++i];
		if (many.has(name)) flags[name] = [...(flags[name] ?? []), ...String(value).split(",").map((one) => one.trim()).filter(Boolean)];
		else flags[name] = value;
	} else positional.push(arg);
}
const line = args.join(" ");

const state0 = peek();
if (state0.fail && (!state0.fail.match || line.includes(state0.fail.match))) {
	if (state0.fail.kind === "unreachable") fail("error connecting to api.github.com\ncheck your internet connection or https://githubstatus.com");
	if (state0.fail.kind === "rate_limited") fail("GraphQL: API rate limit exceeded for user ID 1. (RATE_LIMITED)");
	if (state0.fail.kind === "signed_out") fail("To get started with GitHub CLI, please run:  gh auth login\nAlternatively, populate the GH_TOKEN environment variable with a GitHub API authentication token.", 4);
}

const block = state0.block && line.includes(state0.block.match) ? state0.block : undefined;
function hold() {
	writeFileSync(`${file}.blocked`, String(process.pid));
	while (!existsSync(`${file}.release`)) sleep(20);
}
if (block?.when === "before") hold();

// ---- Shapes

// GitHub reads owner and name without regard to case, and answers them as they are spelt there.
const asked = group === "repo" ? positional[0] : flags.repo;
const repoName = Object.keys(state0.repos).find((name) => name.toLowerCase() === String(asked).toLowerCase()) ?? asked;
const now = () => new Date().toISOString();
const urlOf = (name, kind, number) => `https://github.com/${name}/${kind}/${number}`;
const pick = (object, fields) => (fields ? Object.fromEntries(String(fields).split(",").map((field) => [field, object[field] ?? null])) : object);
const printJson = (value) => {
	const text = `${JSON.stringify(value)}\n`;
	const bytes = Buffer.from(text);
	wait(bytes.length);
	// Written to its end before the process exits: a long listing to a pipe would otherwise be cut short.
	for (let at = 0; at < bytes.length; ) {
		try {
			at += writeSync(1, bytes, at);
		} catch (error) {
			if (error.code !== "EAGAIN") throw error;
			sleep(1);
		}
	}
};
function repoIn(state) {
	const repo = state.repos[repoName];
	if (!repo) fail(`GraphQL: Could not resolve to a Repository with the name '${asked}'. (repository)`);
	return repo;
}
// The two qualifiers of GitHub's search the engine asks with: `closed:>=` a day, and `updated:>=` a time to the second
// (`2026-11-20T10:00:00+00:00`), as GitHub takes them.
const since = (qualifier) => {
	const match = new RegExp(`${qualifier}:>=(\\d{4}-\\d{2}-\\d{2}(?:T\\d{2}:\\d{2}:\\d{2}(?:Z|[+-]\\d{2}:\\d{2}))?)(?:\\s|$)`).exec(flags.search ?? "");
	return match ? Date.parse(match[1]) : null;
};
if (flags.search !== undefined && /\b(closed|updated):/.test(flags.search) && since("closed") === null && since("updated") === null) {
	fail(`Invalid search query "${flags.search}".`);
}
function filterState(items, kind) {
	const wanted = flags.state ?? "open";
	const from = since("closed");
	const changed = since("updated");
	return items.filter((item) => {
		if (wanted === "open" && item.state !== "OPEN") return false;
		if (wanted === "closed" && item.state === "OPEN") return false;
		if (wanted === "merged" && item.state !== "MERGED") return false;
		if (from !== null && (item.closedAt === null || Date.parse(item.closedAt) < from)) return false;
		if (changed !== null && Date.parse(item.updatedAt ?? item.createdAt ?? 0) < changed) return false;
		if (kind === "pr" && flags.head !== undefined && item.headRefName !== flags.head) return false;
		return true;
	});
}
const newest = (items) => [...items].sort((a, b) => b.number - a.number).slice(0, Number(flags.limit ?? 30));
function find(repo, number, kind) {
	const list = kind === "pr" ? repo.pulls : repo.issues;
	const item = list.find((one) => one.number === Number(number));
	if (!item) fail(kind === "pr" ? `GraphQL: Could not resolve to a PullRequest with the number of ${number}. (repository.pullRequest)` : `GraphQL: Could not resolve to an issue or pull request with the number of ${number}. (repository.issue)`);
	return item;
}
function comment(repo, item, kind) {
	repo.nextComment = (repo.nextComment ?? 1000) + 1;
	const made = { id: `IC_${repo.nextComment}`, author: { login: "stand-in" }, body: flags.body ?? "", createdAt: now(), url: `${item.url}#issuecomment-${repo.nextComment}` };
	item.comments.push(made);
	item.updatedAt = now();
	return made.url;
}
function checkLabels(repo, names) {
	for (const name of names) if (!repo.labels.some((label) => label.name === name)) fail(`could not add label: '${name}' not found`);
}
function done(output) {
	if (block?.when === "after") hold();
	wait(0);
	if (output !== undefined) process.stdout.write(`${output}\n`);
	process.exit(0);
}

// ---- Commands

const key = `${group} ${command}`;
if (group === "repo" && command === "view") {
	positional.shift();
	const repo = repoIn(peek());
	printJson(pick({ nameWithOwner: repoName, defaultBranchRef: { name: repo.defaultBranch ?? "main" } }, flags.json));
	process.exit(0);
}
switch (key) {
	case "label list":
		printJson(repoIn(peek()).labels.map((label) => pick(label, flags.json)));
		process.exit(0);
		break;
	case "label create":
		withState((state) => {
			const repo = repoIn(state);
			repo.labels = repo.labels.filter((label) => label.name !== positional[0]);
			repo.labels.push({ name: positional[0], color: flags.color ?? "", description: flags.description ?? "" });
		});
		done();
		break;
	case "issue list":
		printJson(newest(filterState(repoIn(peek()).issues, "issue")).map((issue) => pick(issue, flags.json)));
		process.exit(0);
		break;
	case "issue view":
		printJson(pick(find(repoIn(peek()), positional[0], "issue"), flags.json));
		process.exit(0);
		break;
	case "issue create": {
		const url = withState((state) => {
			const repo = repoIn(state);
			checkLabels(repo, flags.label ?? []);
			const number = repo.next ?? 1;
			repo.next = number + 1;
			const issue = {
				number, title: flags.title, body: flags.body ?? "", state: "OPEN", stateReason: null, labels: (flags.label ?? []).map((name) => ({ name })),
				url: urlOf(repoName, "issues", number), createdAt: now(), updatedAt: now(), closedAt: null, comments: [], author: { login: "stand-in" },
			};
			repo.issues.push(issue);
			return issue.url;
		});
		done(url);
		break;
	}
	case "issue comment":
	case "pr comment":
		done(withState((state) => {
			const repo = repoIn(state);
			return comment(repo, find(repo, positional[0], group === "pr" ? "pr" : "issue"), group);
		}));
		break;
	case "issue edit":
		withState((state) => {
			const repo = repoIn(state);
			const issue = find(repo, positional[0], "issue");
			checkLabels(repo, flags["add-label"] ?? []);
			const names = new Set(issue.labels.map((label) => label.name));
			for (const name of flags["add-label"] ?? []) names.add(name);
			for (const name of flags["remove-label"] ?? []) names.delete(name);
			issue.labels = [...names].map((name) => ({ name }));
			if (flags.title !== undefined) issue.title = flags.title;
			if (flags.body !== undefined) issue.body = flags.body;
			issue.updatedAt = now();
		});
		done(`${urlOf(repoName, "issues", positional[0])}`);
		break;
	case "issue close":
		withState((state) => {
			const issue = find(repoIn(state), positional[0], "issue");
			issue.state = "CLOSED";
			issue.stateReason = flags.reason === "not planned" ? "NOT_PLANNED" : "COMPLETED";
			issue.closedAt = now();
			issue.updatedAt = now();
		});
		done();
		break;
	case "issue reopen":
		withState((state) => {
			const issue = find(repoIn(state), positional[0], "issue");
			issue.state = "OPEN";
			issue.stateReason = "REOPENED";
			issue.closedAt = null;
			issue.updatedAt = now();
		});
		done();
		break;
	case "pr list":
		printJson(newest(filterState(repoIn(peek()).pulls, "pr")).map((pull) => pick(pull, flags.json)));
		process.exit(0);
		break;
	case "pr view":
		printJson(pick(find(repoIn(peek()), positional[0], "pr"), flags.json));
		process.exit(0);
		break;
	case "pr create": {
		const url = withState((state) => {
			const repo = repoIn(state);
			const [owner, branch] = String(flags.head).includes(":") ? String(flags.head).split(":") : [repoName.split("/")[0], String(flags.head)];
			const cross = owner.toLowerCase() !== repoName.split("/")[0].toLowerCase();
			if (repo.pulls.some((pull) => pull.state === "OPEN" && pull.headRefName === branch && pull.headRepositoryOwner.login === owner)) {
				fail(`a pull request for branch "${flags.head}" into branch "${flags.base}" already exists`);
			}
			const number = repo.next ?? 1;
			repo.next = number + 1;
			const pull = {
				number, title: flags.title, url: urlOf(repoName, "pull", number), headRefName: branch, headRepositoryOwner: { login: owner }, isCrossRepository: cross,
				baseRefName: flags.base, author: { login: "stand-in" }, state: "OPEN", isDraft: false, statusCheckRollup: [], mergeable: "MERGEABLE",
				body: flags.body ?? "", comments: [], createdAt: now(), updatedAt: now(), closedAt: null, mergedAt: null,
			};
			repo.pulls.push(pull);
			return pull.url;
		});
		done(url);
		break;
	}
	case "pr edit":
		withState((state) => {
			const pull = find(repoIn(state), positional[0], "pr");
			if (flags.title !== undefined) pull.title = flags.title;
			if (flags.body !== undefined) pull.body = flags.body;
			pull.updatedAt = now();
		});
		done(`${urlOf(repoName, "pull", positional[0])}`);
		break;
	case "pr merge":
		withState((state) => {
			const repo = repoIn(state);
			const pull = find(repo, positional[0], "pr");
			if (pull.state !== "OPEN") fail(`GraphQL: Pull request #${pull.number} is not open (mergePullRequest)`);
			if (pull.mergeable === "CONFLICTING") fail(`Pull request #${pull.number} is not mergeable: the merge commit cannot be cleanly created.`);
			pull.state = "MERGED";
			pull.mergedAt = now();
			pull.closedAt = now();
			pull.updatedAt = now();
			// As GitHub does: "Fixes #N" closes the issue as completed.
			for (const match of String(pull.body).matchAll(/\b(?:fix(?:e[sd])?|close[sd]?|resolve[sd]?)\s+#(\d+)\b/gi)) {
				const issue = repo.issues.find((one) => one.number === Number(match[1]));
				if (issue && issue.state === "OPEN") Object.assign(issue, { state: "CLOSED", stateReason: "COMPLETED", closedAt: now(), updatedAt: now() });
			}
		});
		done();
		break;
	case "pr diff":
		process.stdout.write(peek().repos[repoName]?.diff ?? `diff --git a/README.md b/README.md\n--- a/README.md\n+++ b/README.md\n@@ -1 +1 @@\n-old\n+new\n`);
		process.exit(0);
		break;
	default:
		fail(`unknown command "${key}" for the stand-in gh`);
}
