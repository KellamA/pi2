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

	/** "4", "4 and 7", "4, 7 and 9". */
	function andList(words) {
		return words.length <= 1 ? words.join("") : words.slice(0, -1).join(", ") + " and " + words[words.length - 1];
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

	/**
	 * The files a read asked for, `{path, offset, limit}` each: its `path`, then its `files` (paths or objects, or the
	 * same as a JSON string, which the engine also takes). Null for a read of one `path` alone, as reads were before #176.
	 */
	function readEntries(args) {
		let files = args.files;
		if (typeof files === "string") {
			try {
				files = JSON.parse(files);
			} catch {
				files = [];
			}
		}
		if (files === undefined) return null;
		const entries = [];
		if (typeof args.path === "string" && args.path !== "") entries.push({ path: args.path, offset: args.offset, limit: args.limit });
		for (const file of Array.isArray(files) ? files : []) {
			if (typeof file === "string" && file !== "") entries.push({ path: file });
			else if (isObject(file) && typeof file.path === "string" && file.path !== "") entries.push({ path: file.path, offset: file.offset, limit: file.limit });
		}
		return entries;
	}

	/** The line the engine puts above each file of a read of several (engine/src/reading.ts, `headerOf`). */
	function readHeader(entry) {
		const offset = typeof entry.offset === "number" ? entry.offset : null;
		const limit = typeof entry.limit === "number" ? entry.limit : null;
		const lines = offset === null && limit === null ? "" : limit === null ? `from line ${offset}` : `lines ${offset ?? 1}-${(offset ?? 1) + limit - 1}`;
		return `==> ${entry.path}${lines ? ` (${lines})` : ""} <==`;
	}

	/**
	 * A read of several files, cut into a section per file at the lines the engine put above each, labelled with the
	 * file and its range; one the engine could not read is marked failed. Null when the lines are not all there, as in
	 * an output that is not finished, so the caller shows it whole.
	 */
	function readSections(entries, details, output) {
		const told = isObject(details) && Array.isArray(details.files) && details.files.length === entries.length ? details.files : null;
		const starts = [];
		let from = 0;
		for (const entry of entries) {
			const header = readHeader(entry) + "\n";
			let at = output.indexOf(header, from);
			while (at > 0 && output[at - 1] !== "\n") at = output.indexOf(header, at + 1);
			if (at < 0) return null;
			starts.push({ at, body: at + header.length });
			from = at + header.length;
		}
		return entries.map((entry, index) => {
			const end = index + 1 < starts.length ? starts[index + 1].at : output.length;
			const window = readWindow(entry);
			return {
				kind: "text",
				label: entry.path + (window ? ", " + window : ""),
				text: output.slice(starts[index].body, end).replace(/\n+$/, ""),
				failed: told !== null && isObject(told[index]) && told[index].failed === true,
				language: extension(entry.path),
			};
		});
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
	 * How a set-up command failed, in the engine's words, worded to follow "the set-up command" ("exited with code 1",
	 * "was stopped because the worktree was removed"). Empty when it gave none beyond "failed".
	 */
	function setupReason(details) {
		const reason = isObject(details) ? str(details.reason).replace(/\s+/g, " ").trim() : "";
		return reason === "failed" ? "" : reason;
	}

	/** The same as a sentence: "The set-up command exited with code 1." */
	function setupSentence(details) {
		const reason = setupReason(details) || "failed";
		return "The set-up command " + reason + (/[.!?]$/.test(reason) ? "" : ".");
	}

	/**
	 * Everything the transcript shows about one call.
	 *
	 * `status` is "running" (a result is still coming), "preparing" (the model is still writing the call), "done",
	 * "failed", or "none" (no result and none coming: the run stopped first). `names` carries what only the app knows:
	 * `mcp` (tool name to "Server: tool") and `apps` (bundle ID to app name).
	 *
	 * Returns `{ glyph, label, stats, title, note, exit }`: `label` is a list of `{text, style}` pieces for the one line,
	 * `stats` a short figure after it, `title` the line as plain text for tooltips and VoiceOver, `note` pieces for
	 * a quiet remark after it (which rule let a command run without asking), empty when there is none, and `exit` a
	 * command's non-zero exit code when that is not a failure ("Exit code 1"), or "". What the chevron opens is
	 * `detailFor`'s.
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
				if (args.background === true) {
					// Started and left running: the row says so, and which command it became, for the rows that read and stop it.
					const started = isObject(details) && isObject(details.background) ? str(details.background.id) : "";
					label = command ? [t(active ? "Starting " : "Started "), code(command), t(" in the background" + dots)] : [t((active ? "Starting" : "Started") + " a command in the background" + dots)];
					stats = started;
					break;
				}
				label = command ? [t(active ? "Running " : "Ran "), code(command), t(dots)] : [t(active ? "Running a command" + ELLIPSIS : "Ran a command")];
				// A foreground call can return before its command ends: the engine moved it at its time limit.
				const moved = status === "done" ? backgroundCommand(call, result) : "";
				if (moved) label.push(t(", moved to the background as "), code(moved));
				break;
			}
			case "background": {
				// Listing, reading and stopping the commands a conversation left running. The engine says which command an id
				// stands for once it has answered; until then the row names the id.
				glyph = "terminal";
				const action = str(args.action).trim().toLowerCase();
				const id = str(args.id).trim();
				const command = isObject(details) ? firstLine(details.command) : "";
				const what = command ? [code(command)] : [t(id || "a background command")];
				if (action === "read") label = [t(active ? "Reading the output of " : "Read the output of "), ...what, t(dots)];
				else if (action === "stop") label = [t(active ? "Stopping " : "Stopped "), ...what, t(dots)];
				else if (action === "wake") label = [t(active ? "Asking to wake when " : "Asked to wake when "), ...what, t(" ends" + dots)];
				else label = [t(active ? "Listing background commands" + ELLIPSIS : "Listed background commands")];
				if (command && id) stats = isObject(details) && str(details.id) ? str(details.id) : id;
				break;
			}
			case "pi2_wake":
				glyph = "sparkle";
				label = [t(str(args.summary))];
				break;
			case "pi2_setup":
				// The agent's set-up command, which pi² ran in a new worktree: not a call the agent made.
				glyph = "terminal";
				if (status === "failed") {
					// A failed one leads with what happened, so that when the row is narrow the command gives way, not the reason.
					const reason = setupReason(details);
					label = [{ text: "Set-up command failed" + (reason ? ": " + reason : ""), style: "reason" }, muted(" · "), code(firstLine(args.command))];
				} else {
					label = [t(active ? "Running the set-up command " : "Ran the set-up command "), code(firstLine(args.command)), t(dots)];
				}
				break;
			case "read": {
				glyph = "file";
				const entries = readEntries(args);
				if (entries === null) {
					const file = basename(args.path);
					label = file ? [t(active ? "Reading " : "Read "), name(file), t(dots)] : [t(active ? "Reading a file" + ELLIPSIS : "Read a file")];
					stats = readWindow(args) ?? "";
					break;
				}
				// Several files are one row that names them: the first two or three, then how many more.
				const paths = [...new Set(entries.map((entry) => entry.path))];
				const shown = paths.length <= 3 ? paths : paths.slice(0, 2);
				const more = paths.length - shown.length;
				label = [t(active ? "Reading " : "Read ")];
				shown.forEach((path, index) => {
					if (index > 0) label.push(t(index === shown.length - 1 && more === 0 ? " and " : ", "));
					label.push(name(basename(path)));
				});
				if (more > 0) label.push(t(` and ${more} more`));
				if (shown.length === 0) label = [t(active ? "Reading files" : "Read files")];
				label.push(t(dots));
				if (paths.length > 1) stats = `${paths.length} files`;
				else if (entries.length > 1) stats = `${entries.length} parts`;
				else if (entries.length === 1) stats = readWindow(entries[0]) ?? "";
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
			case "make_picture": {
				// A picture model's work (#286): the description, and the picture itself under the row, which starts open.
				glyph = "picture";
				const what = str(args.description).replace(/\s+/g, " ").trim();
				const changing = args.change === true;
				const verb = changing ? (active ? "Changing the picture: " : "Changed the picture: ") : active ? "Making a picture: " : "Made a picture: ";
				label = what ? [t(verb), muted(quoted(what.length > 200 ? what.slice(0, 200) + ELLIPSIS : what)), t(dots)] : [t(verb.replace(/: $/, "") + dots)];
				if (status === "done" && isObject(details) && str(details.modelName)) stats = str(details.modelName);
				break;
			}
			case "look": {
				// A model that can see answered the agent's question about a picture file (#540).
				glyph = "picture";
				const asked = str(args.question).replace(/\s+/g, " ").trim();
				const several = Array.isArray(args.paths) && args.paths.length > 1 ? ` and ${args.paths.length - 1} more` : "";
				const file = basename(args.path ?? (Array.isArray(args.paths) ? args.paths[0] : ""));
				label = [t(active ? "Looking at " : "Looked at "), name(file ? file + several : "a picture")];
				if (asked) label.push(t(", asking "), muted(quoted(asked.length > 120 ? asked.slice(0, 120) + ELLIPSIS : asked)));
				label.push(t(dots));
				if (status === "done" && isObject(details) && str(details.modelName)) stats = str(details.modelName);
				break;
			}
			case "run_code":
				// A program in the sandbox (#286): nothing on the Mac, so the row says what it is for, not where it ran.
				glyph = "code";
				label = [t(active ? "Working it out with code" + ELLIPSIS : "Worked it out with code")];
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
			case "compact":
				// The summary itself comes after the step, as a line of its own (compaction below); this is only the asking.
				glyph = "memory";
				label = [t(active ? "Asking for earlier messages to be summarised" + ELLIPSIS : "Asked for earlier messages to be summarised")];
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
			case "sub_chats": {
				// Listing an agent's own sub-chats, or archiving finished ones: once done, the numbers it did archive.
				glyph = "list";
				if (str(args.action).trim().toLowerCase() !== "archive") {
					label = [t(active ? "Listing sub-chats" + ELLIPSIS : "Listed sub-chats")];
					break;
				}
				const numbers = (list) => (Array.isArray(list) ? list.filter((n) => typeof n === "number" && Number.isFinite(n)) : []);
				const done = status === "done" && isObject(details) ? numbers(details.archived) : [];
				const chats = status === "done" ? done : numbers(args.chats);
				const verb = active ? "Archiving " : status === "done" ? "Archived " : "Archive ";
				const which = chats.length === 0 ? "sub-chats" : (chats.length === 1 ? "sub-chat " : "sub-chats ") + andList(chats.map(String));
				label = [t(verb + which + dots)];
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
			case "agent_notes": {
				// A chat reading what the person's agents remember (#288).
				glyph = "memory";
				const agent = str(args.agent).trim();
				const search = str(args.search).trim();
				const whose = agent ? agent + "’s notes" : "the agents’ notes";
				label = [t((active ? "Reading " : "Read ") + whose), ...(search ? [t(" for "), muted(quoted(search))] : []), t(dots)];
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
		// A set-up that failed says how in its label.
		const approval = approvalNote(result);
		const note = toolName === "pi2_setup" ? [] : approval ? [t(approval)] : ruleNote(details);
		const exit = exitNote(toolName, status, args, details);
		const title =
			label.map((piece) => piece.text).join("") + (stats ? " " + stats : "") + (note.length > 0 ? " (" + note.map((piece) => piece.text).join("") + ")" : "") + (exit ? " " + String.fromCharCode(0xb7) + " " + exit : "");
		return { glyph, label, stats, title, note, exit };
	}

	/**
	 * "Exit code 1" for a command that ended by itself with a code other than 0 and is not a failure (the engine's
	 * `details.exitCode`, #182): a `grep` that found nothing, checks still pending. Empty otherwise. A failed one (not
	 * found, ended by a signal) says so in red instead, and its output says why.
	 */
	function exitNote(toolName, status, args, details) {
		if ((toolName !== "bash" && toolName !== "powershell") || status !== "done" || args.background === true || !isObject(details)) return "";
		const code = details.exitCode;
		return Number.isInteger(code) && code !== 0 ? "Exit code " + code : "";
	}

	/** The saved approval decision, not the conversation's current switch or a live tool's details. */
	function approvalNote(result) {
		return isObject(result?.details) && result.details.allowedByEverything === true ? "allowed by Allow everything" : "";
	}

	/**
	 * The rule an approval for a command offers to make (`pending.rule`), as `{ words, command, worktrees, place }`, or
	 * null. `place` ends the button's label: "Here", or "in This Repository" for a rule that also holds in the
	 * repository's main checkout and its pi² worktrees, so the button says how wide the rule is without hovering.
	 */
	function ruleOffer(pending) {
		// A project's switch asks about one action at a time: there is no rule to make of it (#553).
		if (switchAsked(pending)) return null;
		if (!isObject(pending) || pending.tool !== "bash" || !isObject(pending.rule) || !Array.isArray(pending.rule.words)) return null;
		const words = pending.rule.words;
		if (words.length === 0 || !words.every((word) => typeof word === "string" && word !== "")) return null;
		const worktrees = pending.rule.worktrees === true;
		return { words, command: words.join(" "), worktrees, place: worktrees ? "in This Repository" : "Here" };
	}

	/**
	 * Whether this approval came from a project's switch that is off, which asks each time (docs/projects.md, 8.1). Such
	 * a request is answered once or not at all: only the project's Settings can stop the asking, so a card for it offers
	 * Allow Once and Deny alone, and the engine refuses anything else (#553).
	 */
	function switchAsked(pending) {
		return isObject(pending) && typeof pending.projectSwitch === "string" && pending.projectSwitch !== "";
	}

	/**
	 * For an approval of a command that would be left running in the background (`pending.background`): the words under
	 * the command that say so, as the Inbox's card says them. Empty for any other approval.
	 */
	function backgroundCaption(pending) {
		if (!isObject(pending) || pending.tool !== "bash" || pending.background !== true) return "";
		return "It is started and left running, with no time limit, until it ends, the agent or you stop it, this conversation is archived, or pi" + String.fromCharCode(0xb2) + " stops. Activity lists it while it runs, with a Stop button.";
	}

	/** Which of the person's rules let a command run without asking, or no note if none did. */
	function ruleNote(details) {
		const rules = isObject(details) && Array.isArray(details.allowedBy) ? details.allowedBy.filter((rule) => typeof rule === "string" && rule !== "") : [];
		if (rules.length === 0) return [];
		const pieces = [t(rules.length === 1 ? "matched allowed command: " : "matched allowed commands: ")];
		rules.forEach((rule, index) => {
			if (index > 0) pieces.push(t(index === rules.length - 1 ? " and " : ", "));
			pieces.push(code(rule));
		});
		return pieces;
	}

	/**
	 * What a call's row opens to: a list of sections, each `{kind, ...}`.
	 *   { kind: "status", text, failed }                      what happened, on a line of its own (a failed set-up)
	 *   { kind: "command", label, command, output, failed }   a command and what it printed
	 *   { kind: "diff", label, diff }                          an edit
	 *   { kind: "text", label, text, failed, language }        a file's text, an output, the arguments
	 *   { kind: "images", entry, count, name?, label? }        pictures kept with the result, with what to call them
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
				sections.push({
					kind: "command",
					label: args.background === true ? str(call.name) + ", in the background" : str(call.name),
					command: str(args.command),
					output,
					failed,
					placeholder: active ? (args.background === true ? "Starting" : "Running") + ELLIPSIS : result ? "(no output)" : "",
				});
				break;
			case "background":
				// What the engine answered: how the command stands, then what it printed.
				outputSection(str(args.action).trim().toLowerCase() === "list" ? "Background commands" : "Output");
				break;
			case "pi2_wake":
				// Exact model input, not Markdown or harness notes to interpret.
				sections.push({ kind: "text", label: "What the agent was given", text: str(result && result.text), failed: false });
				break;
			case "pi2_setup":
				// A failed one says how first, on a line of its own. Its output keeps the ordinary colour: that line and the
				// status carry the red, and the line that failed is easier to find among lines that are not all red.
				if (failed) sections.push({ kind: "status", text: setupSentence(details), failed: true });
				sections.push({ kind: "command", label: "Set-up command", command: str(args.command), output, failed: false, placeholder: active ? "Running" + ELLIPSIS : result ? "(no output)" : "" });
				break;
			case "read":
			case "read_reference": {
				const entries = call.name === "read" ? readEntries(args) : null;
				const parts = entries !== null && result ? readSections(entries, details, output) : null;
				if (parts !== null) sections.push(...parts);
				else if (failed || !result || output !== "") outputSection(str(args.path) || (entries !== null ? "Files" : "Output"));
				break;
			}
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
			case "make_picture":
				if (images > 0) sections.push({ kind: "images", entry: result.id, count: images, name: "Picture", label: "Picture made" + (isObject(details) && str(details.modelName) ? " by " + str(details.modelName) : "") });
				if (failed || images === 0) outputSection("Result");
				break;
			case "look":
				// What was asked, then the other model's answer (#540).
				if (str(args.question).trim() !== "") sections.push({ kind: "text", label: "Question", text: str(args.question).trim() });
				outputSection("Answer");
				break;
			case "run_code":
				if (str(args.code)) sections.push({ kind: "text", label: "Program", text: str(args.code), language: "js" });
				outputSection("What it printed");
				break;
			case "computer":
			case "browser":
				if (images > 0) sections.push({ kind: "images", entry: result.id, count: images });
				outputSection("What the app said");
				break;
			case "compact":
				if (str(args.note).trim() !== "") sections.push({ kind: "text", label: "What the summary must keep", text: str(args.note).trim() });
				outputSection("Result");
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
	 * brief”"), when it would run in the engine's words, the prompt each run would be given, in full, and where the
	 * schedule is turned off afterwards. The approval does not say whether the agent is a project's or a template, so the
	 * caption names both places (the same words as the app's card in `InboxViews.swift`).
	 */
	const SCHEDULE_CAPTION =
		"Each run starts a new conversation with this agent and works with no one watching. You can turn the schedule off or delete it on the project's Settings tab, or on the template's page for a template.";

	function scheduleApproval(pending) {
		const item = isObject(pending) ? pending : {};
		const args = isObject(item.arguments) ? item.arguments : {};
		const who = str(item.agentName) || "The agent";
		const title = str(args.title).replace(/\s+/g, " ").trim();
		return {
			request: title ? `${who} wants to schedule ${QUOTE_OPEN}${title}${QUOTE_CLOSE}` : `${who} wants to schedule work`,
			when: str(item.when) || str(item.question),
			prompt: str(args.prompt).trim(),
			caption: SCHEDULE_CAPTION,
		};
	}

	function extension(path) {
		const m = /\.([A-Za-z0-9]{1,10})$/.exec(str(path));
		return m ? m[1].toLowerCase() : "";
	}

	// MARK: - Hand-offs

	/** An id the engine gives a background command: "bg-" and a number. */
	const BACKGROUND_ID = /^bg-[1-9][0-9]{0,8}$/;

	/**
	 * The background command a call's row is about ("bg-3"), for a way to the window with its output: the command a
	 * `bash` call with `background: true` started, or the one a `background` call read or stopped. Only the engine's
	 * answer counts, never the id the agent asked for, which may name no command at all; so it is empty until the call
	 * has a result, and for a call the engine refused. The app checks the id against the same results before it acts.
	 */
	function backgroundCommand(call, result) {
		const details = result && isObject(result.details) ? result.details : null;
		if (details === null || !isObject(call)) return "";
		let id = "";
		if (call.name === "bash") id = isObject(details.background) ? str(details.background.id) : "";
		else if (call.name === "background") id = str(details.id);
		return BACKGROUND_ID.test(id) ? id : "";
	}

	/**
	 * The document a `write_document` call wrote, as `{ entry, name }`, for Open and Save a Copy on its line (#286); null
	 * for any other call, or before it is written. The app finds the file from the call's result: the page names only
	 * the entry.
	 */
	function documentWritten(call, status, result) {
		if (!isObject(call) || call.name !== "write_document" || status !== "done" || !isObject(result) || !Number.isInteger(result.id)) return null;
		const path = isObject(result.details) ? str(result.details.path) : "";
		return path ? { entry: result.id, name: basename(path) } : null;
	}

	/** The same for the line that says a background command ended ("Background command bg-2 exited with code 1: …"). */
	function markerCommand(item) {
		const details = isObject(item) && isObject(item.details) ? item.details : null;
		const id = details !== null && isObject(details.background) ? str(details.background.id) : "";
		return BACKGROUND_ID.test(id) ? id : "";
	}

	/**
	 * The line for a summary of earlier messages (#408), from what the engine recorded rather than its words: who asked
	 * for it, and the agent's note on what to keep, if it gave one. Null for any other line.
	 */
	function compaction(item, agentName = "") {
		const details = isObject(item) && isObject(item.details) ? item.details : null;
		if (details === null || !isObject(details.compaction)) return null;
		const trigger = str(details.compaction.trigger);
		const note = str(details.compaction.note).trim();
		const agent = str(agentName).trim();
		const text =
			trigger === "size"
				? "Earlier messages summarised by pi² at the size you set"
				: trigger === "person"
					? "Earlier messages summarised, as you asked"
					: trigger === "agent"
						? `Earlier messages summarised, as ${agent || "the agent"} asked`
						: "Earlier messages summarised by pi² as the model’s limit neared";
		const whose = trigger === "person" ? "Your" : agent ? agent + "’s" : "The agent’s";
		return { trigger, text, note, noteLabel: `${whose} note on what to keep` };
	}

	/** An answer that is only an error: an attempt that failed before the model said or called anything. */
	function bareFailure(item) {
		if (!isObject(item) || item.kind !== "assistant" || item.stop !== "error") return false;
		return str(item.text).trim() === "" && str(item.thinking).trim() === "" && !(Array.isArray(item.toolCalls) && item.toolCalls.length > 0);
	}

	/**
	 * Failed attempts in a row, as a request retried, or refused again and again while a run waits for a provider's limit,
	 * leaves them: they show as one row, the last, which says how many there were. For each item shown that way, the
	 * number of attempts in its run (1 for one on its own); the attempts before the last of a run are not in it.
	 */
	function failedRuns(items) {
		const shown = new Map();
		const hidden = new Set();
		let run = [];
		for (let index = 0; index < items.length; index++) {
			const item = items[index];
			if (!bareFailure(item)) continue;
			run.push(item);
			if (bareFailure(items[index + 1])) continue;
			for (const before of run.slice(0, -1)) hidden.add(before.id);
			shown.set(item.id, run.length);
			run = [];
		}
		return { shown, hidden };
	}

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
		// A message from the person ended the call's wait, and the sub-chat carried on (engine/src/heed.ts). Only a result says so.
		const waitEnded = Boolean(result && isObject(result.details) && result.details.waitEnded === true);
		return { agentName, task: str(args.task), chat, continued, agentId: isObject(details) ? str(details.agentId) : "", waitEnded };
	}

	/** A running command shows how long it has gone without printing only after this long, so a busy one's row is still. */
	const QUIET_MS = 30_000;

	/** A short time: "45s", "3m 12s", "1h 4m". */
	function shortDuration(ms) {
		const seconds = Math.max(0, Math.floor((Number(ms) || 0) / 1000));
		if (seconds < 60) return seconds + "s";
		if (seconds < 3600) return Math.floor(seconds / 60) + "m " + (seconds % 60) + "s";
		return Math.floor(seconds / 3600) + "h " + Math.floor((seconds % 3600) / 60) + "m";
	}

	/**
	 * What a running command's clock says at `now` (#196), from the engine's `startedAt` and `lastOutputAt` (ms since the
	 * epoch; `lastOutputAt` null until it prints): `elapsed`, how long it has run, and `quiet`, "quiet for 45s" once it
	 * has printed nothing for QUIET_MS, else "". Null without a start time.
	 */
	function commandClock(startedAt, lastOutputAt, now) {
		if (typeof startedAt !== "number" || !Number.isFinite(startedAt)) return null;
		const since = typeof lastOutputAt === "number" && Number.isFinite(lastOutputAt) ? Math.max(startedAt, lastOutputAt) : startedAt;
		const quietMs = now - since;
		return { elapsed: shortDuration(now - startedAt), quiet: quietMs >= QUIET_MS ? "quiet for " + shortDuration(quietMs) : "" };
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

	// MARK: - Saving as a file

	/** File name endings for a code block's language, as a fence names it. Anything else is saved as text. */
	const ENDINGS = {
		js: "js", javascript: "js", jsx: "jsx", mjs: "mjs", ts: "ts", typescript: "ts", tsx: "tsx", json: "json",
		py: "py", python: "py", rb: "rb", ruby: "rb", go: "go", rs: "rs", rust: "rs", swift: "swift", kotlin: "kt", kt: "kt",
		java: "java", c: "c", h: "h", cpp: "cpp", "c++": "cpp", cs: "cs", csharp: "cs", php: "php", lua: "lua", r: "r",
		sh: "sh", bash: "sh", zsh: "sh", shell: "sh", fish: "fish", ps1: "ps1", powershell: "ps1",
		html: "html", css: "css", scss: "scss", xml: "xml", svg: "svg", yaml: "yaml", yml: "yml", toml: "toml", ini: "ini",
		sql: "sql", md: "md", markdown: "md", csv: "csv", tsv: "tsv", txt: "txt", text: "txt", diff: "diff", patch: "diff",
		dockerfile: "Dockerfile", makefile: "Makefile",
	};

	/**
	 * What a block offers to be saved as: `code.py` for a Python block, the file's own name for a section labelled with a
	 * path (`notes.md` for `docs/notes.md`), `output.txt` for anything else. Only a name, never a folder: the person
	 * chooses where in the save panel, and the app checks the name again.
	 */
	function saveName(kind, hint) {
		const word = str(hint).trim().toLowerCase();
		if (kind === "code") {
			const ending = Object.hasOwn(ENDINGS, word) ? ENDINGS[word] : undefined;
			if (ending === "Dockerfile" || ending === "Makefile") return ending;
			return "code." + (ending ?? "txt");
		}
		if (kind === "answer") return "answer.md";
		const name = basename(str(hint).trim());
		// A label that is a file's path or name keeps it; "Output" or "What it printed" is not one.
		return /^[^\s/\\]+\.[A-Za-z0-9]{1,10}$/.test(name) && name.length <= 120 ? name : "output.txt";
	}

	/** Whether an answer is long enough to offer saving it as a file, as a code block can be. */
	const LONG_ANSWER = 1500;
	function longAnswer(text) {
		return str(text).length >= LONG_ANSWER;
	}

	return {
		readable,
		saveName,
		longAnswer,
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
		approvalNote,
		ruleOffer,
		switchAsked,
		backgroundCaption,
		backgroundCommand,
		documentWritten,
		markerCommand,
		compaction,
		failedRuns,
		detailFor,
		subagentAnswer,
		scheduleApproval,
		folded,
		delegation,
		formatBytes,
		prettyJSON,
		shortDuration,
		commandClock,
		QUIET_MS,
	};
});
