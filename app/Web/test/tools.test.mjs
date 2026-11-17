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

test("a read of several files is one row that names them, and opens to a section per file", () => {
	const files = [{ path: "engine/src/a.ts" }, { path: "docs/b.md", offset: 10, limit: 5 }, { path: "gone.txt" }];
	assert.equal(line("read", { files }), "Read a.ts, b.md and gone.txt 3 files");
	assert.equal(line("read", { files }, "running"), "Reading a.ts, b.md and gone.txt… 3 files");
	assert.equal(line("read", { files: [...files, "c.ts", "d.ts"] }), "Read a.ts, b.md and 3 more 5 files");
	assert.equal(line("read", { files: ["a.ts", "b.ts"] }), "Read a.ts and b.ts 2 files", "paths alone");
	assert.equal(line("read", { files: JSON.stringify(["a.ts", "b.ts"]) }), "Read a.ts and b.ts 2 files", "a list sent as a string");
	assert.equal(line("read", { path: "a.ts", files: ["b.ts"] }), "Read a.ts and b.ts 2 files", "path counts as the first");
	assert.equal(line("read", { files: [{ path: "x/a.ts", limit: 20 }, { path: "x/a.ts", offset: 300, limit: 20 }] }), "Read a.ts 2 parts", "ranges of one file");
	assert.equal(line("read", { files: [{ path: "a.ts", offset: 10, limit: 50 }] }), "Read a.ts lines 10–59");
	assert.equal(line("read", { files: [] }, "preparing"), "Reading files…");

	// What the engine sends back (engine/src/reading.ts): each file under its line, a blank line between them.
	const text = "==> engine/src/a.ts <==\nconst a = 1;\n\n==> docs/b.md (lines 10-14) <==\n# B\n[20 more lines in file. Use offset=15 to continue.]\n\n==> gone.txt <==\n[ENOENT: no such file or directory]\n";
	const details = { files: [{ path: "engine/src/a.ts" }, { path: "docs/b.md", offset: 10, limit: 5 }, { path: "gone.txt", failed: true }] };
	assert.deepEqual(T.detailFor(call("read", { files }), "done", { text, details }, null), [
		{ kind: "text", label: "engine/src/a.ts", text: "const a = 1;", failed: false, language: "ts" },
		{ kind: "text", label: "docs/b.md, lines 10–14", text: "# B\n[20 more lines in file. Use offset=15 to continue.]", failed: false, language: "md" },
		{ kind: "text", label: "gone.txt", text: "[ENOENT: no such file or directory]", failed: true, language: "txt" },
	]);
	// A file whose text holds a line like another's header is not cut there: only a header in its place counts.
	const tricky = "==> a.ts <==\nsee\n==> a.ts <==\n\n==> b.ts <==\nb\n";
	assert.deepEqual(T.detailFor(call("read", { files: ["a.ts", "b.ts"] }), "done", { text: tricky, details: null }, null).map((s) => s.text), ["see\n==> a.ts <==", "b"]);
	// Without the lines (an older engine, say), the output is shown whole; while it runs, a placeholder.
	assert.deepEqual(T.detailFor(call("read", { files: ["a.ts", "b.ts"] }), "done", { text: "something else" }, null), [{ kind: "text", label: "Files", text: "something else", failed: false }]);
	assert.deepEqual(T.detailFor(call("read", { files: ["a.ts"] }), "running", null, null), [{ kind: "text", label: "Files", text: "", placeholder: "Running…" }]);
	// A read of one path is shown as before.
	assert.deepEqual(T.detailFor(call("read", { path: "a.ts" }), "done", { text: "const a = 1;" }, null), [{ kind: "text", label: "a.ts", text: "const a = 1;", failed: false }]);
});

test("a command left running in the background, and the rows that read and stop it", () => {
	const dev = { command: "npm run dev", background: true };
	assert.equal(line("bash", dev, "running"), "Starting npm run dev in the background…");
	assert.equal(line("bash", dev, "done", { details: { background: { id: "bg-3", status: "running" } } }), "Started npm run dev in the background bg-3");
	assert.equal(line("bash", dev, "failed", { details: { background: { id: "bg-3", status: "ended" } } }), "Started npm run dev in the background bg-3");
	assert.equal(line("bash", { background: true }, "preparing"), "Starting a command in the background…");
	assert.equal(line("bash", { command: "npm run dev", background: false }), "Ran npm run dev", "only true is the background");
	// Which rule let it start is said as for any command.
	assert.equal(
		line("bash", dev, "done", { details: { background: { id: "bg-3" }, allowedBy: ["npm run dev"] } }),
		"Started npm run dev in the background bg-3 (allowed by your rule for npm run dev)",
	);
	const read = { details: { action: "read", id: "bg-3", command: "npm run dev", status: "running" } };
	assert.equal(line("background", { action: "read", id: "bg-3" }, "running"), "Reading the output of bg-3…");
	assert.equal(line("background", { action: "read", id: "3" }, "done", read), "Read the output of npm run dev bg-3");
	assert.equal(line("background", { action: "stop", id: "bg-3" }, "done", { details: { ...read.details, action: "stop", status: "ended" } }), "Stopped npm run dev bg-3");
	assert.equal(line("background", { action: "stop", id: "bg-9" }, "failed"), "Stopped bg-9");
	assert.equal(line("background", { action: "stop" }, "failed"), "Stopped a background command");
	assert.equal(line("background", { action: "list" }), "Listed background commands");
	assert.equal(line("background", { action: "list" }, "running"), "Listing background commands…");

	const started = T.detailFor(call("bash", dev), "done", { text: "Started in the background as bg-3.", details: {} }, null);
	assert.deepEqual(started, [{ kind: "command", label: "bash, in the background", command: "npm run dev", output: "Started in the background as bg-3.", failed: false, placeholder: "(no output)" }]);
	assert.equal(T.detailFor(call("bash", dev), "running", null, null)[0].placeholder, "Starting…");
	assert.equal(T.detailFor(call("bash", { command: "ls" }), "done", { text: "a" }, null)[0].label, "bash");
	assert.deepEqual(T.detailFor(call("background", { action: "read", id: "bg-3" }), "done", { text: "bg-3: running.\nready" }, null), [{ kind: "text", label: "Output", text: "bg-3: running.\nready", failed: false }]);
	assert.equal(T.detailFor(call("background", { action: "list" }), "done", { text: "none" }, null)[0].label, "Background commands");
});

test("a background command's rows name it for its output window only as the engine answered", () => {
	const dev = call("bash", { command: "npm run dev", background: true });
	assert.equal(T.backgroundCommand(dev, { details: { background: { id: "bg-3", status: "running" } } }), "bg-3");
	assert.equal(T.backgroundCommand(dev, { isError: true, details: { background: { id: "bg-3", status: "ended" } } }), "bg-3", "one already over still has its output");
	assert.equal(T.backgroundCommand(dev, null), "", "not before the engine has answered");
	assert.equal(T.backgroundCommand(dev, { text: "The command could not be started: …", isError: true }), "", "one that never started has none");
	assert.equal(T.backgroundCommand(call("bash", { command: "ls" }), { details: {} }), "");
	const read = (args, details) => T.backgroundCommand(call("background", args), details === undefined ? null : { details });
	assert.equal(read({ action: "read", id: "3" }, { action: "read", id: "bg-3", command: "npm run dev" }), "bg-3", "the engine's id, not the agent's");
	assert.equal(read({ action: "stop", id: "bg-3" }, { action: "stop", id: "bg-3" }), "bg-3");
	assert.equal(read({ action: "read", id: "bg-9" }), "", "an id the agent asked for counts for nothing until the engine answers");
	assert.equal(read({ action: "read", id: "bg-9" }, {}), "", "nor once it has refused it");
	assert.equal(read({ action: "list" }, { action: "list", count: 2, running: 1 }), "", "a list is about no one command");
	// Anything that is not an id the engine makes is not passed on.
	for (const id of ["bg-0", "bg-01", "bg-", "BG-3", "3", " bg-3", "bg-3 ", "bg-3\n", "bg-3\"><img src=x>", "bg-1234567890", 3, null, { id: "bg-3" }]) {
		assert.equal(read({ action: "read" }, { id }), "", JSON.stringify(id));
		assert.equal(T.backgroundCommand(dev, { details: { background: { id } } }), "", JSON.stringify(id));
		assert.equal(T.markerCommand({ kind: "marker", text: "x", details: { background: { id } } }), "", JSON.stringify(id));
	}
	assert.equal(T.backgroundCommand(call("web_fetch", {}), { details: { id: "bg-3", background: { id: "bg-3" } } }), "", "only bash and background rows");

	const ended = { id: 12, kind: "marker", text: "Background command bg-2 exited with code 1: npm run dev", details: { background: { id: "bg-2" } } };
	assert.equal(T.markerCommand(ended), "bg-2");
	assert.equal(T.markerCommand({ id: 13, kind: "marker", text: "Context reset" }), "", "other lines have none");
	assert.equal(T.markerCommand({ id: 14, kind: "marker", text: "Background command bg-2 exited" }), "", "never read from the words");
	assert.equal(T.markerCommand(null), "");
});

test("an approval for a background command says it keeps running", () => {
	const caption = T.backgroundCaption({ tool: "bash", background: true });
	assert.match(caption, /^It is started and left running, with no time limit, until it ends, the agent or you stop it/);
	assert.match(caption, /Activity lists it while it runs/);
	assert.equal(T.backgroundCaption({ tool: "bash" }), "");
	assert.equal(T.backgroundCaption({ tool: "bash", background: "true" }), "", "only the engine's own true");
	assert.equal(T.backgroundCaption({ tool: "write", background: true }), "", "only for a command");
	assert.equal(T.backgroundCaption(null), "");
	// The rule it offers is the one a command that is waited for would be offered.
	assert.equal(T.ruleOffer({ tool: "bash", background: true, rule: { words: ["npm", "run", "dev"], folder: "/x", worktrees: true } }).place, "in This Repository");
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
	const failed = T.detailFor(call("bash", { command: "nope" }), "failed", { text: "<harness>\n[error] Exit code 127: a command it ran was not found.\n</harness>", isError: true, details: { exitCode: 127 } }, null);
	assert.equal(failed[0].output, "Exit code 127: a command it ran was not found.");
	assert.equal(failed[0].failed, true);
});

test("a command's non-zero exit that is not a failure is said quietly, and one that is a failure is not (#182)", () => {
	const grep = { command: "grep -q left /tmp/x" };
	const exited = { text: "<harness>\n[info] Exit code 1\n</harness>", isError: false, details: { exitCode: 1 } };
	const info = T.describe(call("bash", grep), "done", exited, null);
	assert.equal(info.exit, "Exit code 1");
	assert.equal(info.title, "Ran grep -q left /tmp/x · Exit code 1");
	const [opened] = T.detailFor(call("bash", grep), "done", exited, null);
	assert.equal(opened.output, "Exit code 1");
	assert.equal(opened.failed, false, "its output is not drawn as a failure");
	// Only for a command that ended with a code other than 0 and was not a failure.
	assert.equal(T.describe(call("bash", grep), "done", { text: "x" }, null).exit, "", "exit 0 has no details");
	assert.equal(T.describe(call("bash", grep), "done", { text: "x", details: { exitCode: 0 } }, null).exit, "");
	assert.equal(T.describe(call("bash", grep), "failed", { text: "x", isError: true, details: { exitCode: 137, signal: "SIGKILL" } }, null).exit, "", "a failure says Failed instead");
	assert.equal(T.describe(call("bash", grep), "running", null, { output: "" }).exit, "");
	assert.equal(T.describe(call("bash", grep), "done", { text: "x", details: { exitCode: "1" } }, null).exit, "", "only a whole number");
	assert.equal(T.describe(call("read", { path: "a" }), "done", { text: "x", details: { exitCode: 1 } }, null).exit, "", "only for a command");
	// Older results, from before #182, have no exit code in their details: they keep the error they were.
	assert.equal(T.describe(call("bash", grep), "failed", { text: "<harness>\n[error] Command exited with code 1\n</harness>", isError: true }, null).exit, "");
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
	// An agent's own sub-chats: the line says which it archived, once the engine has said.
	assert.equal(line("sub_chats", { action: "list" }, "running"), "Listing sub-chats…");
	assert.equal(line("sub_chats", { action: "list" }), "Listed sub-chats");
	assert.equal(line("sub_chats", { action: "archive", chats: [4, 7] }, "running"), "Archiving sub-chats 4 and 7…");
	assert.equal(line("sub_chats", { action: "archive", chats: [4, 7, 9] }, "done", { text: "", details: { archived: [4, 9] } }), "Archived sub-chats 4 and 9");
	assert.equal(line("sub_chats", { action: "archive", chats: [4, 7, 9] }, "done", { text: "", details: { archived: [4, 7, 9] } }), "Archived sub-chats 4, 7 and 9");
	assert.equal(line("sub_chats", { action: "archive", chats: [4] }, "done", { text: "", details: { archived: [4] } }), "Archived sub-chat 4");
	assert.equal(line("sub_chats", { action: "archive", chats: [4] }, "failed", { text: "working" }), "Archive sub-chat 4");
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
	assert.equal(failed.title, "Set-up command failed: exited with code 1 · npm ci");
	assert.equal(failed.glyph, "terminal");
	assert.deepEqual(failed.note, []);
	const [said, opened] = T.detailFor(call("pi2_setup", { command: "npm ci" }), "failed", { text: "npm ERR!", isError: true, details: { status: "failed", reason: "exited with code 1" } }, null);
	assert.deepEqual(said, { kind: "status", text: "The set-up command exited with code 1.", failed: true });
	assert.deepEqual(opened, { kind: "command", label: "Set-up command", command: "npm ci", output: "npm ERR!", failed: false, placeholder: "(no output)" });
	assert.equal(T.detailFor(call("pi2_setup", { command: "npm ci" }), "running", undefined, null)[0].placeholder, "Running…");
	const [arriving] = T.detailFor(call("pi2_setup", { command: "npm ci" }), "running", undefined, { status: "running", output: "added 1 package\n" });
	assert.equal(arriving.output, "added 1 package", "what it has printed so far shows while it runs");
	assert.equal(T.detailFor(call("pi2_setup", { command: "npm ci" }), "done", { text: "added 3 packages", details: { status: "done" } }, null).length, 1, "one that finished says nothing more");
});

test("a failed set-up leads with what happened, for each way the engine says it can fail", () => {
	const command = 'echo "fetching deps"; sleep 2; echo "npm ERR! could not resolve" >&2; npm --prefix engine ci && npm run build && cp ../shared.env .env; exit 3';
	const output = "fetching deps\nnpm ERR! could not resolve";
	// The reasons as engine/src/worktrees.ts words them, and the sentence the opened row starts with.
	const reasons = [
		["exited with code 3", "The set-up command exited with code 3."],
		["was ended by SIGKILL", "The set-up command was ended by SIGKILL."],
		["could not start: spawn /bin/bash ENOENT", "The set-up command could not start: spawn /bin/bash ENOENT."],
		["did not finish within 15 minutes and was stopped", "The set-up command did not finish within 15 minutes and was stopped."],
		["was stopped because the worktree was removed", "The set-up command was stopped because the worktree was removed."],
		["was cut off when pi²’s engine stopped", "The set-up command was cut off when pi²’s engine stopped."],
		["was left running when pi²’s engine stopped, and was stopped when the engine started again", "The set-up command was left running when pi²’s engine stopped, and was stopped when the engine started again."],
		[
			"was cut off when pi²’s engine stopped. Something it started may still be running (process group 4321), and was left alone because pi² could not be sure it is the same",
			"The set-up command was cut off when pi²’s engine stopped. Something it started may still be running (process group 4321), and was left alone because pi² could not be sure it is the same.",
		],
	];
	for (const [reason, sentence] of reasons) {
		const result = { text: output, isError: true, details: { status: "failed", reason, command } };
		const info = T.describe(call("pi2_setup", { command }), "failed", result, null);
		// The reason comes first, whole, in a piece of its own; the command, which the row shortens, comes last.
		assert.deepEqual(info.label[0], { text: "Set-up command failed: " + reason, style: "reason" }, reason);
		assert.deepEqual(info.label.at(-1), { text: command, style: "code" }, reason);
		assert.equal(info.title, `Set-up command failed: ${reason} · ${command}`);
		const [said, opened] = T.detailFor(call("pi2_setup", { command }), "failed", result, null);
		assert.deepEqual(said, { kind: "status", text: sentence, failed: true });
		assert.equal(opened.output, output);
		assert.equal(opened.failed, false, "its output is not all red");
	}
	// With no reason, or only "failed" (the engine's word when it has none), it still says it failed, once.
	for (const details of [{ status: "failed", reason: "failed" }, { status: "failed", reason: null }, {}, null]) {
		const result = { text: output, isError: true, details };
		assert.equal(T.describe(call("pi2_setup", { command: "npm ci" }), "failed", result, null).title, "Set-up command failed · npm ci", JSON.stringify(details));
		assert.equal(T.detailFor(call("pi2_setup", { command: "npm ci" }), "failed", result, null)[0].text, "The set-up command failed.");
	}
	// A command over several lines shows its first; a reason over several lines is kept whole, on one.
	const lines = T.describe(call("pi2_setup", { command: "npm ci\nnpm run build" }), "failed", { details: { reason: "could not start:\n  spawn E2BIG" } }, null);
	assert.equal(lines.title, "Set-up command failed: could not start: spawn E2BIG · npm ci …");
	// A command an agent ran is drawn as before: its output stays red when it fails.
	assert.equal(T.detailFor(call("bash", { command: "exit 3" }), "failed", { text: "boom", isError: true }, null)[0].failed, true);
	assert.equal(line("bash", { command: "exit 3" }, "failed", { text: "boom", isError: true }), "Ran exit 3");
});

test("an approval for a command offers the engine's rule, and nothing else does", () => {
	const pending = (rule, tool = "bash") => ({ id: "1", kind: "approval", tool, arguments: { command: "npm test -- --grep x" }, rule });
	assert.deepEqual(T.ruleOffer(pending({ words: ["npm", "test"], folder: "/w" })), { words: ["npm", "test"], command: "npm test", worktrees: false, place: "Here" });
	assert.equal(T.ruleOffer(pending({ words: ["npm", "test"], folder: "/w", worktrees: true })).worktrees, true, "says when the rule also holds in the repository's worktrees");
	assert.equal(T.ruleOffer(pending({ words: ["npm", "test"], folder: "/w", worktrees: "yes" })).worktrees, false);
	assert.equal(T.ruleOffer(pending(undefined)), null);
	assert.equal(T.ruleOffer(pending({ words: ["npm", "test"] }, "write")), null, "only commands");
	for (const rule of [{}, { words: [] }, { words: "npm test" }, { words: ["npm", 5] }, { words: [""] }, null, "x"]) {
		assert.equal(T.ruleOffer(pending(rule)), null, JSON.stringify(rule));
	}
	assert.equal(T.ruleOffer(null), null);
});

test("the rule's button says how far the rule reaches", () => {
	const label = (rule) => {
		const offer = T.ruleOffer({ id: "1", kind: "approval", tool: "bash", arguments: { command: "./run-tests --fast" }, rule });
		return `Always Allow ${offer.command} ${offer.place}`;
	};
	assert.equal(label({ words: ["./run-tests"], folder: "/w" }), "Always Allow ./run-tests Here");
	assert.equal(label({ words: ["./run-tests"], folder: "/w", worktrees: false }), "Always Allow ./run-tests Here");
	assert.equal(label({ words: ["./run-tests"], folder: "/w", worktrees: true }), "Always Allow ./run-tests in This Repository", "a rule kept for the main checkout covers its worktrees");
	assert.equal(label({ words: ["./run-tests"], folder: "/w", worktrees: 1 }), "Always Allow ./run-tests Here", "only a real true widens it");
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
		for (const name of ["bash", "read", "write", "write_document", "edit", "computer", "delegate", "ask_user", "update_plan", "schedule_task", "list_schedules", "cancel_schedule", "sub_chats", "mcp__a__b", "x"]) {
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

test("failed attempts in a row show as one row, the last, with how many there were", () => {
	const failed = (id, error = "429 rate_limit_error") => ({ id, kind: "assistant", stop: "error", text: "", error });
	const items = [
		{ id: 1, kind: "user", text: "go" },
		failed(2),
		failed(3, "429 rate_limit_error (req_b)"),
		failed(4),
		{ id: 5, kind: "assistant", stop: "stop", text: "Done." },
		{ id: 6, kind: "user", text: "again" },
		failed(7),
		{ id: 8, kind: "assistant", stop: "error", text: "Half an answer", error: "terminated" },
		failed(9),
		{ id: 10, kind: "assistant", stop: "error", text: "", error: "x", toolCalls: [{ callId: "c" }] },
	];
	const { shown, hidden } = T.failedRuns(items);
	assert.deepEqual([...hidden], [2, 3]);
	assert.deepEqual([...shown], [[4, 3], [7, 1], [9, 1]]);
	assert.deepEqual(T.failedRuns([]), { shown: new Map(), hidden: new Set() });
});

test("a running command's clock: how long it has run, and how long it has been quiet once that is a while (#196)", () => {
	const start = 1_000_000;
	assert.deepEqual(T.commandClock(start, null, start), { elapsed: "0s", quiet: "" });
	assert.deepEqual(T.commandClock(start, null, start + 12_400), { elapsed: "12s", quiet: "" });
	assert.deepEqual(T.commandClock(start, null, start + 29_999), { elapsed: "29s", quiet: "" }, "quiet only after half a minute");
	assert.deepEqual(T.commandClock(start, null, start + 45_000), { elapsed: "45s", quiet: "quiet for 45s" }, "printing nothing at all counts from the start");
	assert.deepEqual(T.commandClock(start, start + 60_000, start + 72_000), { elapsed: "1m 12s", quiet: "" }, "a busy one is not quiet");
	assert.deepEqual(T.commandClock(start, start + 10_000, start + 192_000), { elapsed: "3m 12s", quiet: "quiet for 3m 2s" });
	assert.deepEqual(T.commandClock(start, start - 5000, start + 31_000), { elapsed: "31s", quiet: "quiet for 31s" }, "an output time before the start counts as the start");
	assert.equal(T.commandClock(start, null, start + 3_840_000).elapsed, "1h 4m");
	assert.equal(T.commandClock(start, null, start - 2000).elapsed, "0s", "a clock a little ahead never goes below zero");
	assert.equal(T.commandClock(undefined, null, start), null, "no start time, no clock");
	assert.equal(T.commandClock("1000", null, start), null);
	assert.equal(T.QUIET_MS, 30_000);
});
