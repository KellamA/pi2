import assert from "node:assert/strict";
import { test } from "node:test";
import T from "../transcript/tools.js";

const MINUS = "−";
const call = (name, args) => ({ callId: "c", name, arguments: args });
const line = (name, args, status = "done", result = null, live = null, names = {}) => T.describe(call(name, args), status, result, live, names).title;

test("harness notes read as the person's words", () => {
	assert.equal(T.readable("<harness>\n[error] The person denied this.\n</harness>"), "The person denied this.");
	assert.equal(T.readable("output\n\n\n<harness>\n[error] Command exited with code 1\n[info] Spilled\n</harness>\n"), "output\n\nCommand exited with code 1\nSpilled");
	assert.equal(T.readable("before<harness>note</harness>after"), "before\n\nnote\n\nafter");
	assert.equal(T.readable("<harness>unclosed"), "<harness>unclosed");
	assert.equal(T.readable(undefined), "");
});

test("one-line summaries, past and present", () => {
	assert.equal(line("bash", { command: "npm test" }), "Ran npm test");
	assert.equal(line("bash", { command: "npm test" }, "running"), "Running npm test…");
	assert.equal(line("bash", { command: "cd app\nswift build" }), "Ran cd app …");
	assert.equal(line("bash", {}, "preparing"), "Running a command…");
	assert.equal(line("read", { path: "engine/src/session.ts" }), "Read session.ts");
	assert.equal(line("read", { path: "a.ts", offset: 10, limit: 50 }), "Read a.ts lines 10–59");
	assert.equal(line("write", { path: "docs/notes.md", content: "a\nb\nc\n" }), "Wrote notes.md +3");
	assert.equal(line("write", { path: "docs/notes.md", content: "a" }, "running"), "Writing notes.md… +1");
	assert.equal(line("write_document", { path: "reports/q3.docx", markdown: "# Q3" }), "Wrote q3.docx");
	assert.equal(line("write_document", { path: "reports/q3.docx", markdown: "# Q3" }, "running"), "Writing q3.docx…");
	assert.equal(line("write_document", {}, "preparing"), "Writing a document…");
	assert.equal(line("write_document", {}), "Wrote a document");
	assert.equal(line("read_reference", { path: "/refs/style.md" }), "Read reference style.md");
	assert.equal(line("codemode", { code: "1+1" }), "Ran a script");
	assert.equal(line("update_plan", { items: [] }), "Updated the task list");
	assert.equal(line("ask_user", { question: "Which one?" }), "Asked “Which one?”");
	assert.equal(line("web_search", { query: "swift 6" }, "running"), "Searching the web for “swift 6”…");
	assert.equal(line("web_fetch", { url: "https://x.com" }), "Fetched https://x.com");
	// The look, plan and memory tools, with the arguments they take.
	assert.equal(line("search_files", { query: "TODO", glob: "**/*.ts", ignoreCase: true }), "Searched for TODO");
	assert.equal(line("find_files", { pattern: "**/*.ts" }), "Found **/*.ts");
	assert.equal(line("list_files", { path: "src/" }), "Listed src");
	assert.equal(line("list_files", {}), "Listed files");
	assert.equal(line("web_fetch", { url: "https://x.com/a", offset: 2000 }), "Fetched https://x.com/a");
	assert.equal(line("update_plan", { items: [{ content: "a", status: "in_progress" }] }, "running"), "Updating the task list…");
	assert.equal(line("remember", { note: "Prefers tabs" }), "Remembered “Prefers tabs”");
	assert.equal(line("forget", { id: "m3" }), "Forgot “m3”");
	assert.equal(line("forget", {}), "Forgot something");
});

test("an edit counts its lines from the result's diff, or from the call", () => {
	const args = { path: "src/a.ts", edits: [{ oldText: "a\nb", newText: "a\nc\nd" }] };
	assert.equal(line("edit", args), `Edited a.ts +2 ${MINUS}1`);
	const result = { details: { diff: " 1 a\n-2 b\n+2 c\n+3 d\n+4 e" } };
	assert.equal(line("edit", args, "done", result), `Edited a.ts +3 ${MINUS}1`);
	assert.equal(line("edit", { path: "a.ts", oldText: "x", newText: "y" }), `Edited a.ts +1 ${MINUS}1`);
	assert.equal(line("edit", args, "preparing"), "Editing a.ts…");
});

test("computer and browser rows use the app's own words when they have them", () => {
	assert.equal(line("computer", { action: "click", app: "com.apple.mail" }, "done", { details: { summary: "Clicked “Send” in Mail" } }), "Clicked “Send” in Mail");
	assert.equal(line("computer", { action: "open_app", app: "com.apple.mail" }, "running", null, null, { apps: { "com.apple.mail": "Mail" } }), "Open app in Mail…");
	assert.equal(line("browser", { action: "open", url: "https://x.com" }, "running"), "Open https://x.com…");
	assert.equal(line("browser", { action: "click", element: 4 }), "Click element 4");
	assert.equal(line("browser", { action: "scroll", dy: -1 }), "Scroll up");
	assert.equal(line("browser", { action: "upload", path: "/tmp/a/report.pdf" }), "Upload report.pdf");
	assert.equal(line("browser", { action: "search", query: "pi durable" }, "done", { details: { summary: "Searched for “pi durable”" } }), "Searched for “pi durable”");
	assert.equal(T.describe(call("browser", {}), "done", null, null).glyph, "globe");
});

test("MCP and unknown tools get a generic row", () => {
	const names = { mcp: { mcp__gh__create_issue: "GitHub: create_issue" } };
	assert.equal(line("mcp__gh__create_issue", { title: "Bug", labels: ["a"] }, "done", null, null, names), 'GitHub: create_issue title: Bug, labels: ["a"]');
	assert.equal(T.describe(call("mcp__gh__create_issue", {}), "done", null, null, names).glyph, "plug");
	assert.equal(line("frobnicate", { path: "x" }), "frobnicate x");
	assert.equal(line("frobnicate", {}, "running"), "frobnicate…");
	assert.equal(T.describe(call("frobnicate", {}), "done", null, null).glyph, "tool");
});

test("what a row opens to", () => {
	const kinds = (name, args, status = "done", result = { text: "out", id: 4 }) => T.detailFor(call(name, args), status, result, null).map((s) => s.kind);
	assert.deepEqual(kinds("bash", { command: "ls" }), ["command"]);
	assert.deepEqual(kinds("edit", { path: "a", edits: [{ oldText: "a", newText: "b" }] }), ["diff"]);
	assert.deepEqual(kinds("edit", { path: "a", edits: [{ oldText: "a", newText: "b" }] }, "failed"), ["diff", "text"]);
	assert.deepEqual(kinds("write_document", { path: "a.docx", markdown: "# x" }), ["text"]);
	assert.deepEqual(kinds("write_document", { path: "a.docx", markdown: "# x" }, "failed", { text: "exists", id: 4 }), ["text", "text"]);
	assert.equal(T.describe(call("write_document", { path: "a.docx" }), "done", null, null).glyph, "file");
	assert.deepEqual(kinds("write", { path: "a", content: "x" }), ["text"]);
	assert.deepEqual(kinds("ask_user", { question: "q" }), ["qa"]);
	assert.deepEqual(kinds("computer", { action: "screenshot" }, "done", { text: "Window", id: 4, images: 1 }), ["images", "text"]);
	assert.deepEqual(kinds("update_plan", { items: [{ content: "a", status: "done" }] }), ["plan"]);
	// A single plain argument is already in the row's line; more is shown as it was sent.
	assert.deepEqual(kinds("web_search", { query: "q" }), ["text"]);
	assert.deepEqual(kinds("mcp__x__y", { a: 1, b: 2 }), ["text", "text"]);
	const running = T.detailFor(call("bash", { command: "make" }), "running", null, { output: "partial\n" });
	assert.equal(running[0].output, "partial");
	const failed = T.detailFor(call("bash", { command: "false" }), "failed", { text: "<harness>\n[error] Command exited with code 1\n</harness>" }, null);
	assert.equal(failed[0].output, "Command exited with code 1");
	assert.equal(failed[0].failed, true);
});

test("scheduling: one-line summaries, what a row opens to, and the approval card", () => {
	const args = { title: "Morning  news\nbrief", prompt: " Sum up the news. ", repeat: "daily", time: "07:00" };
	const made = { text: "Scheduled …", details: { id: "s1", title: "Morning news brief", when: "every day at 07:00" } };
	assert.equal(line("schedule_task", args, "running"), "Scheduling “Morning news brief”…");
	assert.equal(line("schedule_task", args, "done", made), "Scheduled “Morning news brief”, every day at 07:00");
	// Refused or declined: nothing was scheduled, so it does not say it was.
	assert.equal(line("schedule_task", args, "failed", { text: "declined" }), "Schedule “Morning news brief”");
	assert.equal(line("schedule_task", {}, "preparing"), "Scheduling work…");
	assert.equal(line("list_schedules", {}, "running"), "Listing schedules…");
	assert.equal(line("list_schedules", {}), "Listed schedules");
	assert.equal(line("cancel_schedule", { id: "s1" }, "done", { text: "Cancelled", details: { id: "s1", title: "Morning news brief" } }), "Cancelled “Morning news brief”");
	assert.equal(line("cancel_schedule", { id: "s1" }, "running"), "Cancelling schedule s1…");
	assert.equal(line("cancel_schedule", { id: "s9" }, "failed", { text: "not yours" }), "Cancel schedule s9");
	assert.equal(line("cancel_schedule", {}), "Cancelled a schedule");
	for (const name of ["schedule_task", "list_schedules", "cancel_schedule"]) assert.equal(T.describe(call(name, {}), "done", null, null).glyph, "clock");

	const opens = T.detailFor(call("schedule_task", args), "done", made, null);
	assert.deepEqual(opens.map((s) => [s.kind, s.label]), [["text", "Prompt"], ["text", "Result"]]);
	assert.equal(opens[0].text, "Sum up the news.");
	assert.deepEqual(T.detailFor(call("list_schedules", {}), "done", { text: "It is now …" }, null).map((s) => s.label), ["Schedules"]);

	const pending = { kind: "approval", tool: "schedule_task", agentName: "Atlas", arguments: args, question: "Atlas wants to schedule …", when: "Every day at 07:00, first run Friday 13 November at 07:00" };
	assert.deepEqual(T.scheduleApproval(pending), { request: "Atlas wants to schedule “Morning news brief”", when: "Every day at 07:00, first run Friday 13 November at 07:00", prompt: "Sum up the news." });
	assert.deepEqual(T.scheduleApproval({ tool: "schedule_task", arguments: null, question: "Q" }), { request: "The agent wants to schedule work", when: "Q", prompt: "" });
	assert.deepEqual(T.scheduleApproval(null), { request: "The agent wants to schedule work", when: "", prompt: "" });
});

test("diffs: from the result's details, and built from the edits", () => {
	const diff = T.parseDiff(" 9 keep\n-10 old\n+10 new\n   ...\n 20 end");
	assert.deepEqual(diff.lines.map((l) => [l.kind, l.number, l.text]), [["context", 9, "keep"], ["remove", 10, "old"], ["add", 10, "new"], ["gap", null, "…"], ["context", 20, "end"]]);
	assert.equal(diff.added, 1);
	assert.equal(diff.removed, 1);
	const built = T.diffFromEdits({ edits: [{ oldText: "a\nb\nc", newText: "a\nB\nc" }, { oldText: "x", newText: "y\nz" }] });
	assert.deepEqual(built.lines.map((l) => l.kind), ["context", "remove", "add", "context", "gap", "remove", "add", "add"]);
	assert.equal(T.diffText(built), " a\n-b\n+B\n c\n…\n-x\n+y\n+z");
	assert.deepEqual(T.diffFromEdits({ edits: "not a list" }).lines, []);
	assert.deepEqual(T.diffFromEdits(null).lines, []);
	// Very long edits are shown as removed and added rather than compared line by line.
	const big = Array.from({ length: 600 }, (_, i) => "line " + i).join("\n");
	assert.equal(T.lineDiff(big, big + "\nmore").length, 1201);
});

test("hand-offs", () => {
	assert.equal(T.subagentAnswer("Done.\n\n(Sub-chat 4 with Atlas. To continue it, call delegate again with chat: 4.)"), "Done.");
	assert.deepEqual(T.delegation(call("delegate", { agent: "Atlas", task: "Review" }), { details: { conversationId: 4, agentId: "atlas", agentName: "Atlas" } }, null), {
		agentName: "Atlas", task: "Review", chat: 4, continued: false, agentId: "atlas",
	});
	const continued = T.delegation(call("delegate", { agent: "", task: "More", chat: 4 }), null, { details: { conversationId: 4, agentName: "Atlas" } });
	assert.equal(continued.agentName, "Atlas");
	assert.equal(continued.continued, true);
	assert.equal(T.delegation(call("delegate", {}), null, null).chat, null);
	assert.equal(T.delegation(call("delegate", {}), { details: { conversationId: "4" } }, null).chat, null);
});

test("a command one of the person's rules let through says which rule", () => {
	const ran = T.describe(call("bash", { command: "npm test -- --grep x" }), "done", { details: { allowedBy: ["npm test"] } }, null);
	assert.deepEqual(ran.note, [{ text: "allowed by your rule for " }, { text: "npm test", style: "code" }]);
	assert.equal(ran.title, "Ran npm test -- --grep x (allowed by your rule for npm test)");
	const several = T.describe(call("bash", { command: "a && b && c" }), "done", { details: { allowedBy: ["npm test", "git status", "./run-tests"] } }, null);
	assert.equal(several.note.map((piece) => piece.text).join(""), "allowed by your rules for npm test, git status and ./run-tests");
	for (const details of [null, {}, "x", { allowedBy: "npm test" }, { allowedBy: [] }, { allowedBy: [5, ""] }]) {
		assert.deepEqual(T.describe(call("bash", { command: "x" }), "done", { details }, null).note, [], JSON.stringify(details));
	}
	assert.equal(line("bash", { command: "npm test" }), "Ran npm test", "without a rule the row is as before");
});

test("a worktree's set-up command reads as pi²'s, and says how it failed", () => {
	assert.equal(line("pi2_setup", { command: "npm ci" }, "running"), "Running the set-up command npm ci…");
	assert.equal(line("pi2_setup", { command: "npm ci" }, "done", { text: "added 3 packages", details: { status: "done" } }), "Ran the set-up command npm ci");
	const failed = T.describe(call("pi2_setup", { command: "npm ci" }), "failed", { text: "npm ERR!", isError: true, details: { status: "failed", reason: "exited with code 1" } }, null);
	assert.equal(failed.title, "Ran the set-up command npm ci (exited with code 1)");
	assert.equal(failed.glyph, "terminal");
	const [opened] = T.detailFor(call("pi2_setup", { command: "npm ci" }), "failed", { text: "npm ERR!", isError: true }, null);
	assert.deepEqual(opened, { kind: "command", label: "Set-up command", command: "npm ci", output: "npm ERR!", failed: true, placeholder: "(no output)" });
	assert.equal(T.detailFor(call("pi2_setup", { command: "npm ci" }), "running", undefined, null)[0].placeholder, "Running…");
	const [arriving] = T.detailFor(call("pi2_setup", { command: "npm ci" }), "running", undefined, { status: "running", output: "added 1 package\n" });
	assert.equal(arriving.output, "added 1 package", "what it has printed so far shows while it runs");
});

test("an approval for a command offers the engine's rule, and nothing else does", () => {
	const pending = (rule, tool = "bash") => ({ id: "1", kind: "approval", tool, arguments: { command: "npm test -- --grep x" }, rule });
	assert.deepEqual(T.ruleOffer(pending({ words: ["npm", "test"], folder: "/w" })), { words: ["npm", "test"], command: "npm test", worktrees: false });
	assert.equal(T.ruleOffer(pending({ words: ["npm", "test"], folder: "/w", worktrees: true })).worktrees, true, "says when the rule also holds in the repository's worktrees");
	assert.equal(T.ruleOffer(pending({ words: ["npm", "test"], folder: "/w", worktrees: "yes" })).worktrees, false);
	assert.equal(T.ruleOffer(pending(undefined)), null);
	assert.equal(T.ruleOffer(pending({ words: ["npm", "test"] }, "write")), null, "only commands");
	for (const rule of [{}, { words: [] }, { words: "npm test" }, { words: ["npm", 5] }, { words: [""] }, null, "x"]) {
		assert.equal(T.ruleOffer(pending(rule)), null, JSON.stringify(rule));
	}
	assert.equal(T.ruleOffer(null), null);
});

test("summaries for approval cards match the Inbox's", () => {
	assert.equal(T.callSummary({ command: "rm -rf build" }), "rm -rf build");
	assert.equal(T.callSummary({ path: "a.ts", edits: [] }), "a.ts");
	assert.equal(T.callSummary({ code: "a\nb" }), "a b");
	assert.equal(T.callSummary({ z: 1, a: 2 }), '{   "a": 2,   "z": 1 }');
});

test("task lists in a call's arguments", () => {
	assert.deepEqual(T.planSteps({ items: [{ content: "a", status: "DONE" }, "b", { nothing: 1 }] }), [{ text: "a", status: "done" }, { text: "b", status: "" }]);
	assert.equal(T.planSteps({ items: [] }), null);
	assert.equal(T.planSteps({}), null);
});

test("sizes as Finder shows them", () => {
	assert.equal(T.formatBytes(1), "1 byte");
	assert.equal(T.formatBytes(999), "999 bytes");
	assert.equal(T.formatBytes(18234), "18 KB");
	assert.equal(T.formatBytes(2_450_000), "2.5 MB");
});

test("hostile arguments never break a summary", () => {
	for (const args of [null, "string", 5, [], { command: 5 }, { path: {} }, { edits: [{ oldText: 1, newText: null }] }, { action: {} }]) {
		for (const name of ["bash", "read", "write", "write_document", "edit", "computer", "delegate", "ask_user", "update_plan", "schedule_task", "list_schedules", "cancel_schedule", "mcp__a__b", "x"]) {
			const described = T.describe(call(name, args), "done", { text: null, details: "x" }, null);
			assert.equal(typeof described.title, "string");
			assert.ok(Array.isArray(T.detailFor(call(name, args), "done", { text: null }, null)));
		}
	}
});

test("an answer folded onto one line drops block marks and keeps the words", () => {
	assert.equal(
		T.folded("Per seat:\n\n- **Northwind** — $15\n- Lattice — $17\n\nAll three raised prices."),
		"Per seat: **Northwind** — $15 · Lattice — $17 All three raised prices.",
	);
	assert.equal(T.folded("## Fixed\n\n> quoted\n\n1. one\n2. two\n- [x] done"), "Fixed quoted one · two · done");
	assert.equal(T.folded("Run:\n```sh\nnpm test\n```\n---\n| a | b |\n| --- | :-: |\n| 1 | 2 |"), "Run: npm test a, b 1, 2");
	assert.equal(T.folded(""), "");
});
