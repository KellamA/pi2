/*
 * What the transcript says about a tool call: the one-line summary ("Ran `npm test`", "Edited session.ts +6 −2"),
 * the glyph beside it, and the detail behind its chevron (a command and its output, a diff, a file's text).
 *
 * Pure functions over the call, its result and its live state, so Node can test them. Loaded as a plain script by the
 * page (it sets `PiTools`).
 */
(function (root, factory) {
	const api = factory();
	if (typeof module === "object" && module.exports) module.exports = api;
	else root.PiTools = api;
})(typeof globalThis !== "undefined" ? globalThis : this, function () {
	"use strict";

	const MINUS = String.fromCharCode(0x2212);
	const ELLIPSIS = String.fromCharCode(0x2026);
	const QUOTE_OPEN = String.fromCharCode(0x201c);
	const QUOTE_CLOSE = String.fromCharCode(0x201d);

	const isObject = (value) => value !== null && typeof value === "object" && !Array.isArray(value);
	const str = (value) => (typeof value === "string" ? value : "");

	/**
	 * pi durable wraps the results it writes itself (refused, blocked, interrupted, a command that exited non-zero) in a
	 * <harness> note meant for the model. The person reads the note's lines without the tag or their severity prefix.
	 */
	function readable(text) {
		let result = str(text);
		for (;;) {
			const open = result.indexOf("<harness>");
			if (open < 0) break;
			const close = result.indexOf("</harness>", open + 9);
			if (close < 0) break;
			const note = result
				.slice(open + 9, close)
				.split("\n")
				.map((line) => line.replace(/^\[(error|warning|info)\] /, ""))
				.join("\n")
				.replace(/^\n+|\n+$/g, "");
			// The note sits one blank line from the tool's own output, however the tag was spaced.
			const before = result.slice(0, open).replace(/\n+$/, "");
			const after = result.slice(close + 10).replace(/^\n+/, "");
			result = before + (before && note ? "\n\n" : "") + note + (after && (before || note) ? "\n\n" : "") + after;
		}
		return result.replace(/^\n+|\n+$/g, "");
	}

	function basename(path) {
		const clean = str(path).replace(/\/+$/, "");
		const parts = clean.split("/");
		return parts[parts.length - 1] || clean;
	}

	function firstLine(text) {
		const lines = str(text).trim().split("\n");
		return lines.length > 1 ? lines[0] + " " + ELLIPSIS : lines[0];
	}

	function compactJSON(value) {
		try {
			return JSON.stringify(value) ?? "";
		} catch {
			return "";
		}
	}

	function prettyJSON(value) {
		try {
			return JSON.stringify(value, null, 2) ?? "";
		} catch {
			return "";
		}
	}

	const oneLine = (text) => text.replace(/\s*\n\s*/g, " ").trim();

	/**
	 * Markdown folded onto one line for a short preview: the marks that start a heading, a quote, a list item or a
	 * fence are dropped, list items are set apart by a middle dot, and what formats words within a line is kept.
	 */
	function folded(text) {
		const parts = [];
		for (const raw of String(text).split("\n")) {
			if (/^\s*(?:```|~~~)/.test(raw) || /^\s*\|?\s*:?-+:?\s*(?:\|\s*:?-+:?\s*)*\|?\s*$/.test(raw) || /^\s*(?:[-*_]\s*){3,}$/.test(raw)) continue;
			const item = /^\s*(?:[-*+]|\d{1,9}[.)])\s+(?:\[[ xX]\]\s+)?/.exec(raw);
			let line = item ? raw.slice(item[0].length) : raw.replace(/^\s*(?:#{1,6}\s+|(?:>\s?)+)/, "");
			if (/^\s*\|.*\|\s*$/.test(line)) line = line.trim().slice(1, -1).split("|").map((cell) => cell.trim()).join(", ");
			line = line.trim();
			if (line === "") continue;
			parts.push({ line, item: item !== null });
		}
		let out = "";
		parts.forEach((part, index) => {
			if (index > 0) out += part.item && parts[index - 1].item ? " \u00b7 " : " ";
			out += part.line;
		});
		return out;
	}

	/**
	 * The one line worth showing for a call's arguments: the command, path, query or the like when there is one,
	 * otherwise its fields as "name: value" pairs.
	 */
	function argumentSummary(args) {
		if (!isObject(args)) return "";
		for (const key of ["command", "path", "pattern", "query", "url", "task", "code", "question", "text", "content", "note", "name"]) {
			const value = args[key];
			if (typeof value === "string" && value.trim() !== "") return oneLine(value);
		}
		const entries = Object.entries(args);
		// One plain value needs no name: forget's { id } reads as the ID.
		if (entries.length === 1 && ["string", "number", "boolean"].includes(typeof entries[0][1])) return oneLine(String(entries[0][1]));
		return entries
			.map(([key, value]) => `${key}: ${typeof value === "string" ? oneLine(value) : compactJSON(value)}`)
			.join(", ");
	}

	/** A call as `ToolCall.summary` shows it in the app, which the Inbox's approval cards use. */
	function callSummary(args) {
		if (!isObject(args)) return "";
		for (const key of ["command", "path", "task"]) if (typeof args[key] === "string") return args[key];
		if (typeof args.code === "string") return args.code.replace(/\n/g, " ");
		if (typeof args.question === "string") return args.question;
		return prettyJSON(sortKeys(args)).replace(/\n/g, " ");
	}

	function sortKeys(value) {
		if (Array.isArray(value)) return value.map(sortKeys);
		if (!isObject(value)) return value;
		return Object.fromEntries(Object.keys(value).sort().map((key) => [key, sortKeys(value[key])]));
	}

	/** The steps of a task list a call carries (`items`, `plan`, `todos`, `steps` or `tasks`), or null. */
	function planSteps(args) {
		if (!isObject(args)) return null;
		const list = [args.items, args.plan, args.todos, args.steps, args.tasks].find(Array.isArray);
		if (!list) return null;
		const steps = list
			.map((step) => {
				if (typeof step === "string") return { text: step, status: "" };
				if (!isObject(step)) return null;
				const text = [step.content, step.text, step.title, step.step, step.description, step.task].find((value) => typeof value === "string");
				return text === undefined ? null : { text, status: str(step.status).toLowerCase() };
			})
			.filter(Boolean);
		return steps.length > 0 ? steps : null;
	}

	/** Lines and columns of a read, when it asked for a window of the file. */
	function readWindow(args) {
		const offset = typeof args.offset === "number" ? args.offset : null;
		const limit = typeof args.limit === "number" ? args.limit : null;
		if (offset === null && limit === null) return null;
		const from = offset ?? 1;
		return limit === null ? `from line ${from}` : `lines ${from}${String.fromCharCode(0x2013)}${from + limit - 1}`;
	}

	// MARK: - Diffs

	/**
	 * The diff an edit result carries in `details.diff`: one line per row, "+12 text", "-12 text" or " 12 text", with
	 * a row of "..." where unchanged lines were left out.
	 */
	function parseDiff(diff) {
		const lines = [];
		let added = 0;
		let removed = 0;
		for (const row of str(diff).split("\n")) {
			if (row === "") continue;
			const m = /^([+\- ])( *)(\d*) (.*)$/.exec(row);
			if (!m) {
				lines.push({ kind: "context", number: null, text: row });
				continue;
			}
			if (m[3] === "" && m[4] === "...") {
				lines.push({ kind: "gap", number: null, text: ELLIPSIS });
				continue;
			}
			const kind = m[1] === "+" ? "add" : m[1] === "-" ? "remove" : "context";
			if (kind === "add") added++;
			if (kind === "remove") removed++;
			lines.push({ kind, number: m[3] === "" ? null : Number(m[3]), text: m[4] });
		}
		return { lines, added, removed };
	}

	/** Line diff of two texts by longest common subsequence; one side replaced wholesale when they are very long. */
	function lineDiff(before, after) {
		const a = before.split("\n");
		const b = after.split("\n");
		if (a.length * b.length > 250_000) {
			return [...a.map((text) => ({ kind: "remove", number: null, text })), ...b.map((text) => ({ kind: "add", number: null, text }))];
		}
		const table = Array.from({ length: a.length + 1 }, () => new Uint32Array(b.length + 1));
		for (let i = a.length - 1; i >= 0; i--) {
			for (let j = b.length - 1; j >= 0; j--) {
				table[i][j] = a[i] === b[j] ? table[i + 1][j + 1] + 1 : Math.max(table[i + 1][j], table[i][j + 1]);
			}
		}
		const out = [];
		let i = 0;
		let j = 0;
		while (i < a.length && j < b.length) {
			if (a[i] === b[j]) {
				out.push({ kind: "context", number: null, text: a[i] });
				i++;
				j++;
			} else if (table[i + 1][j] >= table[i][j + 1]) {
				out.push({ kind: "remove", number: null, text: a[i++] });
			} else {
				out.push({ kind: "add", number: null, text: b[j++] });
			}
		}
		while (i < a.length) out.push({ kind: "remove", number: null, text: a[i++] });
		while (j < b.length) out.push({ kind: "add", number: null, text: b[j++] });
		return out;
	}

	/** The edits a call asked for (`edits: [{oldText, newText}]`, or the older single pair), as one diff. */
	function diffFromEdits(args) {
		let edits = [];
		if (isObject(args)) {
			if (Array.isArray(args.edits)) edits = args.edits.filter(isObject);
			else if (isObject(args.edits)) edits = [args.edits];
			if (typeof args.oldText === "string" && typeof args.newText === "string") edits.push({ oldText: args.oldText, newText: args.newText });
		}
		const lines = [];
		edits.forEach((edit, index) => {
			if (index > 0) lines.push({ kind: "gap", number: null, text: ELLIPSIS });
			lines.push(...lineDiff(str(edit.oldText), str(edit.newText)));
		});
		return {
			lines,
			added: lines.filter((line) => line.kind === "add").length,
			removed: lines.filter((line) => line.kind === "remove").length,
		};
	}

	/** The diff to show for an edit: the result's own when it has one (it has line numbers), else built from the call. */
	function editDiff(args, details) {
		if (isObject(details) && typeof details.diff === "string" && details.diff.trim() !== "") return parseDiff(details.diff);
		return diffFromEdits(args);
	}

	/** A diff as text to copy: each line with its sign. */
	function diffText(diff) {
		return diff.lines
			.map((line) => (line.kind === "gap" ? ELLIPSIS : (line.kind === "add" ? "+" : line.kind === "remove" ? "-" : " ") + line.text))
			.join("\n");
	}

	const counts = (added, removed) => {
		const parts = [];
		if (added > 0) parts.push("+" + added);
		if (removed > 0) parts.push(MINUS + removed);
		return parts.join(" ");
	};

	// MARK: - Summaries

	const t = (text) => ({ text });
	const code = (text) => ({ text, style: "code" });
	const name = (text) => ({ text, style: "name" });
	const muted = (text) => ({ text, style: "muted" });

	/** A quoted, shortened argument for a one-line summary. */
	function quoted(text) {
		const line = str(text).replace(/\s+/g, " ").trim();
		return QUOTE_OPEN + (line.length > 120 ? line.slice(0, 120) + ELLIPSIS : line) + QUOTE_CLOSE;
	}

	/** A browser call before the app has said what it did, in the words `BrowserSession.line` uses. */
	function browserLine(args) {
		const element = Number.isInteger(args.element) ? `element ${args.element}` : "an element";
		switch (str(args.action).trim()) {
			case "open": return `Open ${str(args.url) || "a page"}`;
			case "search": return `Search for ${QUOTE_OPEN}${str(args.query)}${QUOTE_CLOSE}`;
			case "read": return "Read the page";
			case "screenshot": return "Take a picture of the page";
			case "click": return `Click ${element}`;
			case "type": return `Type into ${element}`;
			case "select": return `Choose ${QUOTE_OPEN}${str(args.option)}${QUOTE_CLOSE} in ${element}`;
			case "scroll": return `Scroll ${typeof args.dy === "number" && args.dy < 0 ? "up" : "down"}`;
			case "back": return "Go back";
			case "upload": return `Upload ${basename(args.path) || "a file"}`;
			default: return argumentSummary(args) || "Browser";
		}
	}

	function capitalized(text) {
		return text.charAt(0).toUpperCase() + text.slice(1);
	}

	/**
	 * Everything the transcript shows about one call.
	 *
	 * `status` is "running" (a result is still coming), "preparing" (the model is still writing the call), "done",
	 * "failed", or "none" (no result and none coming: the run stopped first). `names` carries what only the app knows:
	 * `mcp` (tool name to "Server: tool") and `apps` (bundle ID to app name).
	 *
	 * Returns `{ glyph, label, stats, title, note }`: `label` is a list of `{text, style}` pieces for the one line,
	 * `stats` a short figure after it, `title` the line as plain text for tooltips and VoiceOver, and `note` pieces for
	 * a quiet remark after it (which rule let a command run without asking), empty when there is none. What the chevron
	 * opens is `detailFor`'s.
	 */
	function describe(call, status, result, live, names = {}) {
		const args = isObject(call.arguments) ? call.arguments : {};
		const details = (result && result.details) ?? (live && live.details) ?? null;
		const active = status === "running" || status === "preparing";
		const dots = active ? ELLIPSIS : "";
		const toolName = str(call.name);
		let glyph = "tool";
		let label;
		let stats = "";

		switch (toolName) {
			case "bash":
			case "powershell": {
				glyph = "terminal";
				const command = firstLine(args.command);
				label = command ? [t(active ? "Running " : "Ran "), code(command), t(dots)] : [t(active ? "Running a command" + ELLIPSIS : "Ran a command")];
				break;
			}
			case "read": {
				glyph = "file";
				const file = basename(args.path);
				label = file ? [t(active ? "Reading " : "Read "), name(file), t(dots)] : [t(active ? "Reading a file" + ELLIPSIS : "Read a file")];
				stats = readWindow(args) ?? "";
				break;
			}
			case "write": {
				glyph = "pencil";
				const file = basename(args.path);
				label = file ? [t(active ? "Writing " : "Wrote "), name(file), t(dots)] : [t(active ? "Writing a file" + ELLIPSIS : "Wrote a file")];
				if (typeof args.content === "string" && status !== "preparing") {
					const lines = args.content === "" ? 0 : args.content.replace(/\n$/, "").split("\n").length;
					stats = lines > 0 ? "+" + lines : "";
				}
				break;
			}
			case "write_document": {
				glyph = "file";
				const file = basename(args.path);
				label = file ? [t(active ? "Writing " : "Wrote "), name(file), t(dots)] : [t(active ? "Writing a document" + ELLIPSIS : "Wrote a document")];
				break;
			}
			case "edit": {
				glyph = "pencil";
				const file = basename(args.path);
				label = file ? [t(active ? "Editing " : "Edited "), name(file), t(dots)] : [t(active ? "Editing a file" + ELLIPSIS : "Edited a file")];
				if (status !== "preparing") {
					const diff = editDiff(args, details);
					stats = counts(diff.added, diff.removed);
				}
				break;
			}
			case "read_reference": {
				glyph = "book";
				const file = basename(args.path);
				label = [t(active ? "Reading reference " : "Read reference "), name(file || "file"), t(dots)];
				stats = readWindow(args) ?? "";
				break;
			}
			case "ask_user":
				glyph = "question";
				label = [t(active ? "Asking " : "Asked "), muted(quoted(args.question))];
				break;
			case "codemode":
				glyph = "code";
				label = [t(active ? "Running a script" + ELLIPSIS : "Ran a script")];
				break;
			case "computer":
			case "browser": {
				glyph = toolName === "browser" ? "globe" : "cursor";
				// The app says what it did ("Clicked “Send” in Mail"); until then, what was asked.
				const summary = isObject(details) ? str(details.summary) : "";
				if (summary) {
					label = [t(summary)];
				} else if (toolName === "browser") {
					label = [t(browserLine(args) + dots)];
				} else {
					const action = capitalized(str(args.action).trim().replace(/_/g, " ")) || capitalized(toolName);
					const app = str(args.app);
					const appName = app ? (names.apps && typeof names.apps[app] === "string" ? names.apps[app] : app) : "";
					const where = appName ? " in " + appName : str(args.url) ? " " + str(args.url) : "";
					label = [t(action + where + dots)];
				}
				break;
			}
			case "update_plan":
				glyph = "list";
				label = [t(active ? "Updating the task list" + ELLIPSIS : "Updated the task list")];
				break;
			case "schedule_task": {
				glyph = "clock";
				// Until it is done the schedule may never exist (the person can say no), so only then is it "Scheduled".
				const title = str(args.title).replace(/\s+/g, " ").trim();
				const when = status === "done" && isObject(details) ? str(details.when) : "";
				const verb = active ? "Scheduling " : status === "done" ? "Scheduled " : "Schedule ";
				label = [t(verb), title ? muted(quoted(title)) : t("work"), ...(when ? [t(", " + when)] : []), t(dots)];
				break;
			}
			case "list_schedules":
				glyph = "clock";
				label = [t(active ? "Listing schedules" + ELLIPSIS : "Listed schedules")];
				break;
			case "cancel_schedule": {
				glyph = "clock";
				const id = str(args.id).trim();
				const title = status === "done" && isObject(details) ? str(details.title) : "";
				const verb = active ? "Cancelling " : status === "done" ? "Cancelled " : "Cancel ";
				if (title) label = [t(verb), muted(quoted(title))];
				else label = id ? [t(verb + "schedule "), code(id), t(dots)] : [t(verb + "a schedule" + dots)];
				break;
			}
			case "remember":
			case "forget": {
				glyph = "memory";
				const what = argumentSummary(args);
				const verb = toolName === "remember" ? (active ? "Remembering" : "Remembered") : active ? "Forgetting" : "Forgot";
				label = what ? [t(verb + " "), muted(quoted(what)), t(dots)] : [t(verb + (active ? ELLIPSIS : " something"))];
				break;
			}
			case "list_files": {
				glyph = "folder";
				const where = str(args.path) || str(args.dir) || str(args.directory);
				label = [t(active ? "Listing " : "Listed "), name(where ? basename(where) || where : "files"), t(dots)];
				break;
			}
			case "find_files":
			case "search_files": {
				glyph = "search";
				const pattern = str(args.pattern) || str(args.query) || str(args.glob) || str(args.regex) || argumentSummary(args);
				const verb = toolName === "find_files" ? (active ? "Finding " : "Found ") : active ? "Searching for " : "Searched for ";
				label = toolName === "find_files" ? [t(verb), code(pattern || "files"), t(dots)] : [t(verb), code(pattern || "text"), t(dots)];
				break;
			}
			case "web_fetch": {
				glyph = "globe";
				const url = str(args.url);
				label = [t(active ? "Fetching " : "Fetched "), name(url || "a page"), t(dots)];
				break;
			}
			case "web_search": {
				glyph = "search";
				const query = str(args.query) || argumentSummary(args);
				label = [t(active ? "Searching the web for " : "Searched the web for "), muted(quoted(query)), t(dots)];
				break;
			}
			default: {
				// An MCP tool reads as "Server: tool" rather than its long internal name.
				const mcp = names.mcp && typeof names.mcp[toolName] === "string" ? names.mcp[toolName] : null;
				glyph = mcp || toolName.startsWith("mcp__") ? "plug" : "tool";
				const summary = argumentSummary(args);
				label = [name(mcp ?? toolName)];
				if (summary) label.push(muted(" " + (summary.length > 200 ? summary.slice(0, 200) + ELLIPSIS : summary)));
				if (active) label.push(t(ELLIPSIS));
			}
		}
		const note = ruleNote(details);
		const title = label.map((piece) => piece.text).join("") + (stats ? " " + stats : "") + (note.length > 0 ? " (" + note.map((piece) => piece.text).join("") + ")" : "");
		return { glyph, label, stats, title, note };
	}

	/**
	 * For a command that ran without asking because of the person's rules (the engine lists them in `details.allowedBy`):
	 * which rules, so the row does not look as if nothing checked it. Empty otherwise.
	 */
	/** The rule an approval for a command offers to make (`pending.rule`), as `{ words, command }`, or null. */
	function ruleOffer(pending) {
		if (!isObject(pending) || pending.tool !== "bash" || !isObject(pending.rule) || !Array.isArray(pending.rule.words)) return null;
		const words = pending.rule.words;
		if (words.length === 0 || !words.every((word) => typeof word === "string" && word !== "")) return null;
		return { words, command: words.join(" "), worktrees: pending.rule.worktrees === true };
	}

	function ruleNote(details) {
		const rules = isObject(details) && Array.isArray(details.allowedBy) ? details.allowedBy.filter((rule) => typeof rule === "string" && rule !== "") : [];
		if (rules.length === 0) return [];
		const pieces = [t(rules.length === 1 ? "allowed by your rule for " : "allowed by your rules for ")];
		rules.forEach((rule, index) => {
			if (index > 0) pieces.push(t(index === rules.length - 1 ? " and " : ", "));
			pieces.push(code(rule));
		});
		return pieces;
	}

	/**
	 * What a call's row opens to: a list of sections, each `{kind, ...}`.
	 *   { kind: "command", label, command, output, failed }   a command and what it printed
	 *   { kind: "diff", label, diff }                          an edit
	 *   { kind: "text", label, text, failed, language }        a file's text, an output, the arguments
	 *   { kind: "images", entry, count }                       pictures kept with the result
	 *   { kind: "qa", question, answer }                       a question and the person's answer
	 *   { kind: "plan", steps: [{text, status}] }              a task list
	 */
	function detailFor(call, status, result, live) {
		const args = isObject(call.arguments) ? call.arguments : {};
		const details = (result && result.details) ?? (live && live.details) ?? null;
		const output = readable(result ? result.text : live ? live.output : "");
		const failed = status === "failed";
		const active = status === "running" || status === "preparing";
		const sections = [];
		const outputSection = (label) => {
			if (output !== "") sections.push({ kind: "text", label, text: output, failed });
			else if (active) sections.push({ kind: "text", label, text: "", placeholder: "Running" + ELLIPSIS });
			else if (result) sections.push({ kind: "text", label, text: "", placeholder: "(no output)" });
		};
		const images = result && typeof result.images === "number" && result.images > 0 ? result.images : 0;

		switch (str(call.name)) {
			case "bash":
			case "powershell":
				sections.push({ kind: "command", label: str(call.name), command: str(args.command), output, failed, placeholder: active ? "Running" + ELLIPSIS : result ? "(no output)" : "" });
				break;
			case "read":
			case "read_reference":
				if (failed || !result || output !== "") outputSection(str(args.path) || "Output");
				break;
			case "write":
				if (typeof args.content === "string") sections.push({ kind: "text", label: str(args.path) || "File", text: args.content, language: extension(args.path) });
				if (failed) outputSection("Result");
				break;
			case "write_document":
				// The Markdown as the agent wrote it, not the arguments with its line breaks escaped.
				if (typeof args.markdown === "string") sections.push({ kind: "text", label: str(args.path) || "Document", text: args.markdown, language: "md" });
				if (failed) outputSection("Result");
				break;
			case "edit": {
				const diff = editDiff(args, details);
				if (diff.lines.length > 0) sections.push({ kind: "diff", label: str(args.path) || "Changes", diff });
				if (failed) outputSection("Result");
				break;
			}
			case "ask_user":
				sections.push({ kind: "qa", question: str(args.question), answer: output, failed });
				break;
			case "codemode":
				if (str(args.code)) sections.push({ kind: "text", label: "Script", text: str(args.code), language: "js" });
				outputSection("Output");
				break;
			case "computer":
			case "browser":
				if (images > 0) sections.push({ kind: "images", entry: result.id, count: images });
				outputSection("What the app said");
				break;
			case "update_plan": {
				const steps = planSteps(args);
				if (steps) sections.push({ kind: "plan", steps });
				if (failed || !steps) outputSection("Output");
				break;
			}
			case "schedule_task":
				// What each run will be told, then whether it was set and when it runs.
				if (str(args.prompt).trim() !== "") sections.push({ kind: "text", label: "Prompt", text: str(args.prompt).trim() });
				outputSection("Result");
				break;
			case "list_schedules":
				outputSection("Schedules");
				break;
			case "cancel_schedule":
				outputSection("Result");
				break;
			default: {
				// A single plain value is already in the row's own line; anything more is shown as it was sent.
				const keys = Object.keys(args);
				const shown = keys.length === 1 && ["string", "number", "boolean"].includes(typeof args[keys[0]]);
				if (keys.length > 0 && !shown) sections.push({ kind: "text", label: "Input", text: prettyJSON(args), language: "json" });
				if (images > 0) sections.push({ kind: "images", entry: result.id, count: images });
				outputSection("Output");
			}
		}
		if (images > 0 && !sections.some((section) => section.kind === "images")) sections.unshift({ kind: "images", entry: result.id, count: images });
		return sections;
	}

	/**
	 * What an approval card shows for a schedule an agent wants to set: the heading ("Atlas wants to schedule “Morning
	 * brief”"), when it would run in the engine's words, and the prompt each run would be given, in full.
	 */
	function scheduleApproval(pending) {
		const item = isObject(pending) ? pending : {};
		const args = isObject(item.arguments) ? item.arguments : {};
		const who = str(item.agentName) || "The agent";
		const title = str(args.title).replace(/\s+/g, " ").trim();
		return {
			request: title ? `${who} wants to schedule ${QUOTE_OPEN}${title}${QUOTE_CLOSE}` : `${who} wants to schedule work`,
			when: str(item.when) || str(item.question),
			prompt: str(args.prompt).trim(),
		};
	}

	function extension(path) {
		const m = /\.([A-Za-z0-9]{1,10})$/.exec(str(path));
		return m ? m[1].toLowerCase() : "";
	}

	// MARK: - Hand-offs

	/** A delegation's answer without the footer the engine adds for the model ("(Sub-chat 4 with Atlas. …)"). */
	function subagentAnswer(output) {
		const text = readable(output);
		const at = text.indexOf("\n\n(Sub-chat ");
		return at >= 0 ? text.slice(0, at) : text;
	}

	/** Who a delegation went to and whether it carried on an earlier sub-chat. */
	function delegation(call, result, live) {
		const args = isObject(call.arguments) ? call.arguments : {};
		const details = (result && result.details) ?? (live && live.details) ?? null;
		const chat = isObject(details) && Number.isInteger(details.conversationId) ? details.conversationId : null;
		const named = str(args.agent).trim();
		const agentName = named || (isObject(details) ? str(details.agentName) : "") || "agent";
		const continued = Number.isInteger(args.chat);
		return { agentName, task: str(args.task), chat, continued, agentId: isObject(details) ? str(details.agentId) : "" };
	}

	/** Bytes as Finder shows a file's size. */
	function formatBytes(bytes) {
		const n = Number(bytes) || 0;
		if (n < 1000) return n === 1 ? "1 byte" : `${n} bytes`;
		const units = ["KB", "MB", "GB", "TB"];
		let value = n / 1000;
		let unit = 0;
		while (value >= 1000 && unit < units.length - 1) {
			value /= 1000;
			unit++;
		}
		return (unit === 0 ? Math.round(value) : Math.round(value * 10) / 10) + " " + units[unit];
	}

	return {
		readable,
		basename,
		argumentSummary,
		callSummary,
		planSteps,
		parseDiff,
		lineDiff,
		diffFromEdits,
		editDiff,
		diffText,
		describe,
		ruleOffer,
		detailFor,
		subagentAnswer,
		scheduleApproval,
		folded,
		delegation,
		formatBytes,
		prettyJSON,
	};
});
