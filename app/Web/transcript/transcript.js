/*
 * The transcript page. The app sends it the conversation through `pi2.receive(json)`: new entries, the live state
 * (the answer still arriving, tools running), what is waiting on the person, and names only the app knows. The page
 * renders that as one document, so a selection runs across prose, code and tool steps, and sends the person's actions
 * back through the `pi2` message handler.
 *
 * Rows are keyed by entry and call, and each keeps a signature of what it was built from: an update rebuilds only the
 * rows whose signature changed, and a streaming answer re-renders only the blocks of it that changed. Whether a row is
 * open is kept apart from the rows, so it survives their rebuilding.
 *
 * Nothing from the conversation becomes markup: text goes in as text nodes, and links only through PiMarkdown.safeURL.
 */
(function () {
	"use strict";

	const MD = window.PiMarkdown;
	const T = window.PiTools;
	const C = window.PiClipboard;
	const char = String.fromCharCode;
	const ELLIPSIS = char(0x2026);
	const RSQUO = char(0x2019);

	// MARK: - Bridge

	function post(message) {
		try {
			window.webkit.messageHandlers.pi2.postMessage(message);
		} catch {
			// Not inside the app (a browser, while developing): nothing to send to.
		}
	}

	// MARK: - State

	let revision = 0;
	const revisions = new WeakMap();
	const rev = (object) => (object ? revisions.get(object) ?? 0 : 0);
	const stamp = (object) => {
		revisions.set(object, ++revision);
		return object;
	};

	const items = new Map();
	let order = [];
	const results = new Map();
	let live = { busy: false, partial: null, tools: new Map(), retrying: false };
	let liveRevision = 0;
	let inbox = new Map();
	let names = { conversationId: 0, agentName: "", mcp: {}, agents: [], apps: {} };
	let namesRevision = 0;
	/** Rows the person opened or closed, by key; rows they never touched follow their default. */
	const opened = new Map();
	/** Pictures by "entry/index": { state: "loading" | "ready" | "failed", url }. */
	const pictures = new Map();
	let rendered = false;

	const isObject = (value) => value !== null && typeof value === "object" && !Array.isArray(value);
	const str = (value) => (typeof value === "string" ? value : "");

	function receive(json) {
		let message;
		try {
			message = JSON.parse(json);
		} catch {
			return;
		}
		if (!isObject(message)) return;
		let follow = false;

		if (message.reset === true) {
			items.clear();
			order = [];
			results.clear();
		}
		if (Array.isArray(message.items)) {
			for (const item of message.items) {
				if (!isObject(item) || !Number.isInteger(item.id) || typeof item.kind !== "string") continue;
				if (!items.has(item.id)) order.push(item.id);
				items.set(item.id, stamp(item));
				if (item.kind === "tool" && typeof item.callId === "string") results.set(item.callId, item);
				// Sending a message always brings the reader back to the bottom.
				if (item.kind === "user" && rendered && message.reset !== true) follow = true;
			}
		}
		if (isObject(message.live)) {
			const tools = new Map();
			for (const tool of Array.isArray(message.live.tools) ? message.live.tools : []) {
				if (!isObject(tool) || typeof tool.callId !== "string") continue;
				const key = JSON.stringify([tool.status, tool.output, tool.details]);
				const previous = live.tools.get(tool.callId);
				const next = { ...tool, key };
				if (previous && previous.key === key) revisions.set(next, rev(previous));
				else stamp(next);
				tools.set(tool.callId, next);
			}
			const partial = isObject(message.live.partial) ? message.live.partial : null;
			live = {
				busy: message.live.busy === true,
				partial: partial && {
					text: str(partial.text),
					thinking: str(partial.thinking),
					toolCalls: Array.isArray(partial.toolCalls) ? partial.toolCalls.filter((call) => isObject(call) && typeof call.callId === "string") : [],
				},
				tools,
				retrying: message.live.retrying === true,
			};
			liveRevision = ++revision;
		}
		if (Array.isArray(message.inbox)) {
			const next = new Map();
			for (const entry of message.inbox) {
				if (!isObject(entry) || typeof entry.id !== "string" || typeof entry.callId !== "string") continue;
				const previous = inbox.get(entry.callId);
				if (previous && JSON.stringify(previous) === JSON.stringify(entry)) next.set(entry.callId, previous);
				else next.set(entry.callId, stamp(entry));
			}
			inbox = next;
		}
		if (isObject(message.names)) {
			const n = message.names;
			names = {
				conversationId: Number.isInteger(n.conversationId) ? n.conversationId : 0,
				agentName: str(n.agentName),
				mcp: isObject(n.mcp) ? n.mcp : {},
				agents: Array.isArray(n.agents) ? n.agents.filter(isObject) : [],
				apps: isObject(n.apps) ? n.apps : {},
			};
			namesRevision = ++revision;
		}
		if (isObject(message.palette)) applyPalette(message.palette);
		if (isObject(message.image)) receivePicture(message.image);

		if (follow) pinned = true;
		schedule();
	}

	Object.defineProperty(window, "pi2", { value: Object.freeze({ receive }), writable: false, configurable: false });

	// MARK: - Palette

	const PALETTE = ["window", "panel", "card", "card2", "line", "line2", "tx", "tx2", "tx3", "acc", "ok", "warn", "bad", "on-acc"];
	const COLOUR = /^rgba?\(\s*\d{1,3}(?:\.\d+)?\s*,\s*\d{1,3}(?:\.\d+)?\s*,\s*\d{1,3}(?:\.\d+)?\s*(?:,\s*(?:0|1|0?\.\d+)\s*)?\)$/;

	function applyPalette(palette) {
		const root = document.documentElement;
		for (const name of PALETTE) {
			const value = palette[name];
			if (typeof value === "string" && COLOUR.test(value)) root.style.setProperty("--" + name, value);
		}
		if (palette.appearance === "dark" || palette.appearance === "light") {
			root.setAttribute("data-appearance", palette.appearance);
			root.style.setProperty("color-scheme", palette.appearance);
		}
	}

	// MARK: - Elements

	function el(tag, className, text) {
		const element = document.createElement(tag);
		if (className) element.className = className;
		if (text !== undefined && text !== null && text !== "") element.textContent = text;
		return element;
	}

	function button(className, label, text) {
		const b = el("button", className, text);
		b.type = "button";
		if (label) b.setAttribute("aria-label", label);
		b.setAttribute("data-nocopy", "");
		return b;
	}

	const GLYPHS = {
		terminal: ["M2.5 3h11a1 1 0 0 1 1 1v8a1 1 0 0 1-1 1h-11a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1z", "M4.5 6.2 6.6 8l-2.1 1.8", "M8.2 10.2h3.3"],
		file: ["M4 1.5h5.2l3.3 3.3v9.2a.5.5 0 0 1-.5.5H4a.5.5 0 0 1-.5-.5V2a.5.5 0 0 1 .5-.5z", "M9 1.7v3.3h3.3"],
		pencil: ["M10.6 2.4l3 3L6 13H3v-3z", "M9 4l3 3"],
		book: ["M2 3.2h4.2A1.8 1.8 0 0 1 8 5v8.6a1.4 1.4 0 0 0-1.4-1.4H2z", "M14 3.2H9.8A1.8 1.8 0 0 0 8 5v8.6a1.4 1.4 0 0 1 1.4-1.4H14z"],
		question: ["M8 14.5a6.5 6.5 0 1 0 0-13 6.5 6.5 0 0 0 0 13z", "M6.1 6.3a2 2 0 0 1 3.9.5c0 1.3-2 1.6-2 2.8", "M8 11.3v.2"],
		code: ["M5.5 4.5 2 8l3.5 3.5", "M10.5 4.5 14 8l-3.5 3.5"],
		cursor: ["M3.5 2.5 13 6.6 8.7 8.2l-1.6 4.4z"],
		globe: ["M8 14.5a6.5 6.5 0 1 0 0-13 6.5 6.5 0 0 0 0 13z", "M1.7 8h12.6", "M8 1.6c1.8 1.9 2.6 4 2.6 6.4S9.8 12.5 8 14.4C6.2 12.5 5.4 10.4 5.4 8S6.2 3.5 8 1.6z"],
		list: ["M6 4h8", "M6 8h8", "M6 12h8", "M2.3 4h.6", "M2.3 8h.6", "M2.3 12h.6"],
		memory: ["M4 1.8h8v12.4l-4-3-4 3z"],
		clock: ["M8 14.5a6.5 6.5 0 1 0 0-13 6.5 6.5 0 0 0 0 13z", "M8 4.4V8l2.5 1.6"],
		folder: ["M1.5 4.2a1 1 0 0 1 1-1h3.6l1.6 1.6h5.8a1 1 0 0 1 1 1v6.4a1 1 0 0 1-1 1h-11a1 1 0 0 1-1-1z"],
		search: ["M7 12a5 5 0 1 0 0-10 5 5 0 0 0 0 10z", "M10.6 10.6 14 14"],
		plug: ["M6 1.5v3", "M10 1.5v3", "M4 4.5h8v2.6a4 4 0 0 1-8 0z", "M8 11.1v3.4"],
		tool: ["M10.3 1.9a3.5 3.5 0 0 0-4.1 4.7L2.1 10.7a1.4 1.4 0 0 0 2 2l4.1-4.1a3.5 3.5 0 0 0 4.7-4.1l-2 2-1.8-.4-.4-1.8z"],
		sparkle: ["M8 1.6 9.3 6l4.4 1.4-4.4 1.4L8 13.2 6.7 8.8 2.3 7.4 6.7 6z"],
		chevron: ["M6 3.8 10.2 8 6 12.2"],
		copy: ["M5.5 5.5h7.2a.8.8 0 0 1 .8.8v7.2a.8.8 0 0 1-.8.8H5.5a.8.8 0 0 1-.8-.8V6.3a.8.8 0 0 1 .8-.8z", "M2.5 10.3V3.3a.8.8 0 0 1 .8-.8h7"],
		fork: [
			"M5 4.6a1.6 1.6 0 1 0 0-3.2 1.6 1.6 0 0 0 0 3.2z", "M5 14.6a1.6 1.6 0 1 0 0-3.2 1.6 1.6 0 0 0 0 3.2z",
			"M11 4.6a1.6 1.6 0 1 0 0-3.2 1.6 1.6 0 0 0 0 3.2z", "M5 4.6v6.8", "M11 4.6v1a3 3 0 0 1-3 3H7a2 2 0 0 0-2 2",
		],
		check: ["M3 8.6l3 3 7-7.2"],
		open: ["M5.5 10.5l6-6", "M6.5 4.5h5v5"],
		down: ["M8 3v10", "M4 9l4 4 4-4"],
		reply: ["M3 2.5v5a2 2 0 0 0 2 2h8.5", "M10.5 6.5l3 3-3 3"],
		close: ["M4 4l8 8", "M12 4l-8 8"],
		picture: ["M2.5 3h11a1 1 0 0 1 1 1v8a1 1 0 0 1-1 1h-11a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1z", "M1.8 11l3.6-3.6 3 3 2-2 3.8 3.8", "M10.5 6.2v.1"],
		warning: ["M8 2 14.5 13.5h-13z", "M8 6.5v3", "M8 11.6v.1"],
	};

	function glyph(name, className = "glyph") {
		const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
		svg.setAttribute("viewBox", "0 0 16 16");
		svg.setAttribute("class", className);
		svg.setAttribute("aria-hidden", "true");
		for (const d of GLYPHS[name] ?? GLYPHS.tool) {
			const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
			path.setAttribute("d", d);
			svg.appendChild(path);
		}
		return svg;
	}

	/**
	 * Starts an element's looping animation where a clock running since the page loaded has got to. Rows that stream
	 * are rebuilt many times a second, and an animation that began again with each rebuild would look frozen.
	 */
	function inPhase(element) {
		element.style.setProperty("--phase", -Math.round(performance.now()) + "ms");
		return element;
	}

	function spinner(label = "Running") {
		const s = el("span", "spinner");
		s.setAttribute("role", "img");
		s.setAttribute("aria-label", label);
		s.setAttribute("data-nocopy", "");
		return inPhase(s);
	}

	function labelPieces(pieces) {
		const label = el("span", "tool-label");
		for (const piece of pieces) {
			if (piece.style === "code") label.appendChild(el("code", "", piece.text));
			else if (piece.style) label.appendChild(el("span", piece.style, piece.text));
			else label.appendChild(document.createTextNode(piece.text));
		}
		return label;
	}

	function statsElement(stats) {
		const span = el("span", "stats");
		for (const part of stats.split(" ")) {
			if (span.firstChild) span.appendChild(document.createTextNode(" "));
			span.appendChild(el("span", part.startsWith("+") ? "add" : part.startsWith(char(0x2212)) ? "remove" : "", part));
		}
		return span;
	}

	// MARK: - Keyed children

	/**
	 * Brings `parent`'s children in line with `specs` ({key, sig, build(), update?(element)}): a child whose signature
	 * is unchanged is kept as it is, one that changed is updated in place or rebuilt, and children no longer listed go.
	 */
	function reconcile(parent, specs) {
		const known = parent.__rows ?? new Map();
		const next = new Map();
		let cursor = parent.firstChild;
		for (const spec of specs) {
			let entry = known.get(spec.key);
			if (!entry || entry.sig !== spec.sig) {
				if (entry && spec.update) {
					spec.update(entry.element);
					entry.sig = spec.sig;
				} else {
					const element = spec.build();
					if (spec.update) spec.update(element);
					if (entry) {
						if (cursor === entry.element) cursor = entry.element.nextSibling;
						entry.element.remove();
					}
					entry = { element, sig: spec.sig };
				}
			}
			next.set(spec.key, entry);
			if (entry.element !== cursor) parent.insertBefore(entry.element, cursor);
			else cursor = cursor.nextSibling;
		}
		for (const [key, entry] of known) if (!next.has(key) && entry.element.parentNode === parent) entry.element.remove();
		parent.__rows = next;
	}

	// MARK: - Rows

	const main = document.getElementById("transcript");

	function visibleItems() {
		const out = [];
		for (const id of order) {
			const item = items.get(id);
			if (item && item.kind !== "tool") out.push(item);
		}
		return out;
	}

	function render() {
		const visible = visibleItems();
		const specs = [];
		const shownCalls = new Set();
		visible.forEach((item, index) => {
			const next = visible[index + 1];
			if (item.kind === "user") {
				specs.push({ key: "i" + item.id, sig: "u" + rev(item), build: () => userRow(item) });
			} else if (item.kind === "assistant") {
				for (const call of calls(item)) shownCalls.add(call.callId);
				// A turn ends at the person's next message, or when the run is over; its actions wait until then.
				const turnEnd = next ? next.kind !== "assistant" : !live.partial && !live.busy;
				specs.push(assistantSpec(item, turnEnd, visible, index));
			} else {
				specs.push({ key: "i" + item.id, sig: "m" + rev(item), build: () => markerRow(item.text) });
			}
		});
		if (live.partial) {
			for (const call of live.partial.toolCalls) shownCalls.add(call.callId);
			specs.push({ key: "partial", sig: "p" + liveRevision + "/" + namesRevision, build: () => article("assistant streaming", names.agentName || "Answer"), update: fillPartial });
		}
		// Something waiting on the person for a call that is not in view (it should always be; this is a safety net).
		for (const pending of inbox.values()) {
			if (!shownCalls.has(pending.callId)) specs.push({ key: "q:" + pending.id, sig: "q" + rev(pending), build: () => questionCard(pending, null) });
		}
		if (!live.partial && live.busy && live.tools.size === 0 && !live.retrying) {
			specs.push({ key: "working", sig: "w", build: workingRow });
		}
		reconcile(main, specs);
		observePictures(main);
		rendered = true;
		if (pinned) scrollToBottom();
		updateJump();
	}

	let scheduled = false;
	function schedule() {
		if (scheduled) return;
		scheduled = true;
		const run = () => {
			if (!scheduled) return;
			scheduled = false;
			render();
		};
		requestAnimationFrame(run);
		// Animation frames pause while the window is hidden; the transcript still keeps up.
		setTimeout(run, 150);
	}

	function article(kind, label) {
		const row = el("article", "msg " + kind);
		row.setAttribute("aria-label", label);
		return row;
	}

	function markerRow(text) {
		const row = el("div", "marker");
		row.setAttribute("role", "separator");
		row.setAttribute("aria-label", text);
		row.appendChild(el("span", "", text));
		return row;
	}

	function workingRow() {
		const row = inPhase(el("div", "working"));
		row.setAttribute("role", "status");
		row.setAttribute("aria-label", "Working");
		row.setAttribute("data-nocopy", "");
		for (let i = 0; i < 3; i++) row.appendChild(el("span"));
		return row;
	}

	function actionsBar(actions) {
		const bar = el("div", "actions");
		bar.setAttribute("role", "toolbar");
		bar.setAttribute("aria-label", "Message actions");
		bar.setAttribute("data-nocopy", "");
		for (const action of actions) {
			const b = button("action", action.label);
			b.title = action.label;
			b.appendChild(glyph(action.glyph, "action-glyph"));
			b.addEventListener("click", (event) => {
				event.stopPropagation();
				action.run(b);
			});
			bar.appendChild(b);
		}
		return bar;
	}

	function flash(b, text) {
		b.classList.add("done");
		const previous = b.getAttribute("aria-label");
		b.setAttribute("aria-label", text);
		b.title = text;
		setTimeout(() => {
			b.classList.remove("done");
			b.setAttribute("aria-label", previous);
			b.title = previous;
		}, 1400);
	}

	function copyAction(text) {
		return { label: "Copy", glyph: "copy", run: (b) => {
			post({ type: "copy", text: text() });
			flash(b, "Copied");
		} };
	}

	// MARK: The person's messages

	function userRow(item) {
		const row = article("user", "You");
		const notes = Array.isArray(item.attachments) ? item.attachments.filter(isObject) : [];
		const count = Number.isInteger(item.images) && item.images > 0 ? Math.min(item.images, 50) : 0;
		const pictureNames = notes.filter((note) => note.kind === "image").map((note) => str(note.name));
		const files = notes.filter((note) => note.kind !== "image");
		if (count > 0 || files.length > 0) {
			const strip = el("div", "attachments");
			for (let index = 0; index < count; index++) {
				const name = pictureNames[index] || `Picture ${index + 1}`;
				strip.appendChild(thumbnail(item.id, index, name, "Picture you attached: " + name));
			}
			for (const file of files) {
				const chip = el("div", "chip");
				chip.setAttribute("data-copy", `[File: ${str(file.name)}]`);
				chip.title = str(file.name);
				chip.appendChild(glyph("file", "chip-glyph"));
				const words = el("span", "chip-words");
				words.appendChild(el("span", "chip-name", str(file.name)));
				words.appendChild(el("span", "chip-size", T.formatBytes(file.size)));
				chip.appendChild(words);
				chip.setAttribute("role", "img");
				chip.setAttribute("aria-label", `Attached file ${str(file.name)}, ${T.formatBytes(file.size)}`);
				strip.appendChild(chip);
			}
			row.appendChild(strip);
		}
		if (str(item.text) !== "") row.appendChild(el("div", "bubble", item.text));
		row.appendChild(actionsBar([copyAction(() => str(item.text))]));
		return row;
	}

	// MARK: Answers

	const phaseOf = (item) => (item.stop === "aborted" || item.stop === "error" ? "stopped" : "live");
	const calls = (item) => (Array.isArray(item.toolCalls) ? item.toolCalls.filter((call) => isObject(call) && typeof call.callId === "string") : []);

	/**
	 * Where a call stands. `phase` is "preparing" for a call the model is still writing, "stopped" for one in an
	 * answer that was interrupted (it never ran), and "live" otherwise.
	 */
	function statusOf(call, phase) {
		if (phase === "preparing") return "preparing";
		const result = results.get(call.callId);
		if (result) return result.isError ? "failed" : "done";
		return live.busy && phase !== "stopped" ? "running" : "none";
	}

	function callSignature(call, phase) {
		const pending = inbox.get(call.callId);
		return [
			call.callId,
			statusOf(call, phase),
			rev(results.get(call.callId)),
			rev(live.tools.get(call.callId)),
			pending ? rev(pending) : 0,
			phase === "preparing" ? JSON.stringify(call.arguments ?? null) : "",
		].join(":");
	}

	function assistantSpec(item, turnEnd, visible, index) {
		const phase = phaseOf(item);
		const sig = ["a", rev(item), turnEnd ? 1 : 0, namesRevision, ...calls(item).map((call) => callSignature(call, phase))].join("|");
		return {
			key: "i" + item.id,
			sig,
			build: () => article("assistant", names.agentName || "Answer"),
			update: (row) => fillAnswer(row, item, turnEnd, visible, index),
		};
	}

	/** The text of the whole turn an answer ends: its own and that of the answers just before it. */
	function turnText(visible, index) {
		const parts = [];
		for (let i = index; i >= 0 && visible[i].kind === "assistant"; i--) {
			if (str(visible[i].text).trim() !== "") parts.unshift(visible[i].text);
		}
		return parts.join("\n\n");
	}

	function fillAnswer(row, item, turnEnd, visible, index) {
		const stop = str(item.stop);
		const interrupted = stop === "aborted" || stop === "error";
		const text = str(item.text);
		const thinking = str(item.thinking);
		const itemCalls = calls(item);
		const parts = [];
		if (interrupted) {
			const note = stop === "error" ? "This attempt failed" : `Interrupted ${char(0x2014)} kept in the transcript`;
			parts.push({ key: "stop", sig: stop, build: () => noteRow("warn", note, "warning") });
		}
		if (thinking.trim() !== "") parts.push(thinkingSpec("th:" + item.id, thinking, false, rev(item)));
		if (text !== "") {
			parts.push({
				key: "text",
				sig: "t" + rev(item),
				build: () => el("div", "md" + (interrupted ? " dim" : "")),
				update: (box) => MD.patch(document, box, text),
			});
		}
		if (str(item.error) !== "") parts.push({ key: "error", sig: item.error, build: () => el("div", "error-text", item.error) });
		if (itemCalls.length > 0) {
			parts.push({
				key: "tools",
				sig: "c" + itemCalls.map((call) => callSignature(call, phaseOf(item))).join("|") + "/" + namesRevision,
				build: () => el("div", "tools"),
				update: (box) => reconcile(box, itemCalls.map((call) => toolSpec(call, phaseOf(item)))),
			});
		}
		if (stop === "length") parts.push({ key: "length", sig: "l", build: () => noteRow("muted", "The answer was cut off at the model" + RSQUO + "s output limit.") });
		if (turnEnd) {
			parts.push({
				key: "actions",
				sig: "x" + rev(item),
				build: () => {
					const actions = [];
					const words = turnText(visible, index);
					if (words !== "") actions.push(copyAction(() => words));
					actions.push({ label: "Fork from here", glyph: "fork", run: () => post({ type: "fork", entry: item.id }) });
					return actionsBar(actions);
				},
			});
		}
		reconcile(row, parts);
		row.classList.toggle("has-text", text !== "" || thinking !== "");
		row.classList.toggle("starts-with-tools", text === "" && thinking === "" && !interrupted && itemCalls.length > 0);
		row.classList.toggle("ends-with-tools", itemCalls.length > 0 && stop !== "length" && str(item.error) === "");
		row.classList.toggle("turn-end", turnEnd);
	}

	function noteRow(tone, text, glyphName) {
		const note = el("div", "note " + tone);
		if (glyphName) note.appendChild(glyph(glyphName));
		note.appendChild(document.createTextNode(text));
		return note;
	}

	/** The answer still arriving: its thinking, its text with a dot at the end, and the calls it is writing. */
	function fillPartial(row) {
		const partial = live.partial;
		if (!partial) return;
		const parts = [];
		const streamingThought = partial.text === "" && partial.toolCalls.length === 0;
		if (partial.thinking.trim() !== "") parts.push(thinkingSpec("th:partial", partial.thinking, streamingThought, liveRevision));
		if (partial.text !== "") {
			parts.push({
				key: "text",
				sig: "t" + liveRevision,
				build: () => el("div", "md"),
				update: (box) => {
					const caret = box.querySelector(".caret");
					if (caret) caret.remove();
					MD.patch(document, box, partial.text);
					if (partial.toolCalls.length === 0) placeCaret(box);
				},
			});
		}
		if (partial.toolCalls.length > 0) {
			parts.push({
				key: "tools",
				sig: "c" + liveRevision + "/" + namesRevision,
				build: () => el("div", "tools"),
				update: (box) => reconcile(box, partial.toolCalls.map((call) => toolSpec(call, "preparing"))),
			});
		}
		if (partial.text === "" && partial.thinking.trim() === "" && partial.toolCalls.length === 0) {
			parts.push({ key: "working", sig: "w", build: workingRow });
		}
		reconcile(row, parts);
		// Spaced as the answer will be once it is committed, so nothing shifts when it is.
		row.classList.toggle("starts-with-tools", partial.text === "" && partial.thinking.trim() === "" && partial.toolCalls.length > 0);
	}

	/** The pulsing dot that marks where streaming text has got to, at the end of its last line. */
	function placeCaret(box) {
		const caret = inPhase(el("span", "caret"));
		caret.setAttribute("aria-hidden", "true");
		caret.setAttribute("data-nocopy", "");
		let target = box.lastElementChild;
		while (target) {
			if (target.classList.contains("codeblock")) {
				target = target.querySelector("pre code");
				break;
			}
			const tag = target.localName;
			if (tag === "hr") {
				target = null;
				break;
			}
			if (["p", "h1", "h2", "h3", "h4", "h5", "h6", "td", "th"].includes(tag) || target.classList.contains("li-text")) break;
			const last = target.lastElementChild;
			if (!last) break;
			target = last;
		}
		(target ?? box).appendChild(caret);
	}

	// MARK: Thinking

	function thinkingSpec(key, text, streaming, version) {
		return {
			key: "thinking",
			sig: key + "/" + version + "/" + (streaming ? 1 : 0),
			build: () => {
				const row = el("div", "thinking");
				const head = el("div", "row-head thinking-head");
				row.appendChild(head);
				const body = el("div", "row-body thinking-body md");
				body.id = "body-" + key.replace(/[^\w-]/g, "_");
				row.appendChild(body);
				return row;
			},
			update: (row) => {
				const head = row.firstChild;
				const body = row.lastChild;
				// The line itself changes only when thinking stops; more thought arriving only changes what it opens to.
				if (row.__streaming !== streaming) {
					row.__streaming = streaming;
					head.replaceChildren();
					head.appendChild(streaming ? spinner("Thinking") : glyph("sparkle"));
					head.appendChild(el("span", "tool-label" + (streaming ? " shimmer" : ""), streaming ? "Thinking" + ELLIPSIS : "Thought"));
					head.appendChild(chevron(body.id, streaming ? "Thinking" : "Thought"));
					if (streaming) inPhase(head.children[1]);
				}
				const toggle = head.lastChild;
				const open = opened.get(key) ?? false;
				const apply = (value) => {
					row.classList.toggle("open", value);
					body.hidden = !value;
					toggle.setAttribute("aria-expanded", String(value));
					if (value) MD.patch(document, body, text);
				};
				apply(open);
				head.onclick = (event) => {
					if (selectionInside(head) || event.target.closest("a")) return;
					userToggle(row, () => {
						const value = !(opened.get(key) ?? false);
						opened.set(key, value);
						apply(value);
					});
				};
			},
		};
	}

	function chevron(controls, what) {
		const b = button("chevron", "Show details: " + what);
		b.setAttribute("aria-controls", controls);
		b.appendChild(glyph("chevron", "chevron-glyph"));
		return b;
	}

	/** Whether the person has just selected text in `element`, so a click there ended a drag rather than asked to open. */
	function selectionInside(element) {
		const selection = window.getSelection();
		return !!selection && !selection.isCollapsed && selection.rangeCount > 0 && element.contains(selection.getRangeAt(0).commonAncestorContainer);
	}

	// MARK: Tool rows

	let bodyCount = 0;

	function toolSpec(call, phase) {
		const pending = phase === "preparing" ? null : inbox.get(call.callId);
		if (pending) return { key: "q:" + pending.id, sig: "q" + rev(pending) + "/" + namesRevision, build: () => questionCard(pending, call) };
		const sig = callSignature(call, phase) + "/" + namesRevision;
		if (call.name === "delegate") return { key: "d:" + call.callId, sig, build: () => el("div", "tool delegate"), update: (row) => fillDelegate(row, call, phase) };
		return { key: "t:" + call.callId, sig, build: () => el("div", "tool"), update: (row) => fillTool(row, call, phase) };
	}

	function fillTool(row, call, phase) {
		const key = "t:" + call.callId;
		const status = statusOf(call, phase);
		const result = results.get(call.callId);
		const liveTool = live.tools.get(call.callId);
		const info = T.describe(call, status, result, liveTool, names);
		const sections = T.detailFor(call, status, result, liveTool);
		row.className = "tool " + status;

		// Where the output was scrolled to, so new output does not pull the reader away from what they are reading.
		const oldOutput = row.querySelector(".output");
		const followOutput = !oldOutput || oldOutput.scrollHeight - oldOutput.scrollTop - oldOutput.clientHeight < 8;
		const oldScroll = oldOutput ? oldOutput.scrollTop : 0;

		row.replaceChildren();
		const head = el("div", "row-head");
		head.title = info.title;
		head.appendChild(status === "running" || status === "preparing" ? spinner() : glyph(status === "failed" ? "warning" : info.glyph));
		head.appendChild(labelPieces(info.label));
		if (info.stats) {
			head.appendChild(document.createTextNode(" "));
			head.appendChild(statsElement(info.stats));
		}
		if (status === "failed") {
			head.appendChild(document.createTextNode(" "));
			head.appendChild(el("span", "tool-status failed", "Failed"));
		} else if (status === "none") {
			head.appendChild(document.createTextNode(" "));
			head.appendChild(el("span", "tool-status none", "No result"));
		}
		row.appendChild(head);
		if (sections.length === 0) return;

		const body = el("div", "row-body tool-body");
		body.id = "body-" + ++bodyCount;
		const toggle = chevron(body.id, info.title);
		head.appendChild(toggle);
		row.appendChild(body);
		const liveOutput = liveTool && str(liveTool.output) !== "";
		const defaultOpen = status === "failed" || (status === "running" && liveOutput && ["bash", "powershell", "codemode"].includes(call.name));
		const apply = (value) => {
			row.classList.toggle("open", value);
			body.hidden = !value;
			toggle.setAttribute("aria-expanded", String(value));
			if (value && !body.firstChild) {
				fillDetail(body, sections);
				observePictures(body);
			}
		};
		apply(opened.get(key) ?? defaultOpen);
		const output = body.querySelector(".output");
		if (output) output.scrollTop = followOutput ? output.scrollHeight : oldScroll;
		head.onclick = (event) => {
			if (selectionInside(head) || event.target.closest("a")) return;
			userToggle(row, () => {
				const value = !row.classList.contains("open");
				opened.set(key, value);
				apply(value);
			});
		};
	}

	/** The content behind a row's chevron. */
	function fillDetail(body, sections) {
		for (const section of sections) {
			switch (section.kind) {
				case "command": {
					const box = detailBox(section.label, () => (section.output !== "" ? section.output : section.command));
					const pre = el("pre", "output" + (section.failed ? " failed" : ""));
					const command = el("span", "command");
					command.appendChild(el("span", "prompt", "$ "));
					command.appendChild(document.createTextNode(section.command));
					pre.appendChild(command);
					if (section.output !== "") pre.appendChild(document.createTextNode("\n" + section.output));
					else if (section.placeholder) {
						pre.appendChild(document.createTextNode("\n"));
						pre.appendChild(el("span", "placeholder", section.placeholder));
					}
					box.appendChild(pre);
					body.appendChild(box);
					break;
				}
				case "text": {
					const box = detailBox(section.label, () => section.text);
					const pre = el("pre", "output" + (section.failed ? " failed" : ""));
					if (section.text !== "") pre.textContent = section.text;
					else pre.appendChild(el("span", "placeholder", section.placeholder || ""));
					box.appendChild(pre);
					body.appendChild(box);
					break;
				}
				case "diff": {
					const box = detailBox(section.label, () => T.diffText(section.diff));
					box.appendChild(diffElement(section.diff));
					body.appendChild(box);
					break;
				}
				case "images": {
					const strip = el("div", "pictures");
					for (let index = 0; index < Math.min(section.count, 20); index++) {
						strip.appendChild(thumbnail(section.entry, index, "What the agent saw", "Screenshot the agent took", true));
					}
					body.appendChild(strip);
					break;
				}
				case "plan": {
					const list = el("ul", "plan");
					for (const step of section.steps) {
						const done = ["done", "completed", "complete"].includes(step.status);
						const active = ["in_progress", "in-progress", "active", "doing", "running"].includes(step.status);
						const li = el("li", "task" + (done ? " done" : active ? " active" : ""));
						const box = el("input");
						box.type = "checkbox";
						box.setAttribute("disabled", "");
						if (done) box.setAttribute("checked", "");
						box.setAttribute("aria-label", done ? "Done" : active ? "In progress" : "Not done");
						li.append(box, document.createTextNode(step.text));
						if (active) li.appendChild(el("span", "muted", " (in progress)"));
						list.appendChild(li);
					}
					body.appendChild(list);
					break;
				}
				case "qa": {
					const qa = el("div", "qa");
					qa.appendChild(el("p", "qa-question", section.question));
					if (section.answer !== "") {
						const answer = el("p", "qa-answer" + (section.failed ? " failed" : ""));
						answer.appendChild(glyph("reply"));
						answer.appendChild(document.createTextNode(section.answer));
						qa.appendChild(answer);
					}
					body.appendChild(qa);
					break;
				}
			}
		}
	}

	function detailBox(label, copyText) {
		const box = el("div", "detail");
		const head = el("div", "detail-head");
		head.setAttribute("data-nocopy", "");
		head.appendChild(el("span", "detail-label", label));
		const copy = button("copy-button", "Copy " + (label || "output"), "Copy");
		copy.addEventListener("click", (event) => {
			event.stopPropagation();
			post({ type: "copy", text: copyText() });
			copy.textContent = "Copied";
			setTimeout(() => (copy.textContent = "Copy"), 1400);
		});
		head.appendChild(copy);
		box.appendChild(head);
		return box;
	}

	function diffElement(diff) {
		const numbered = diff.lines.some((line) => line.number !== null);
		const pre = el("pre", "output diff" + (numbered ? "" : " unnumbered"));
		const width = String(Math.max(0, ...diff.lines.map((line) => line.number ?? 0))).length;
		diff.lines.forEach((line, index) => {
			const row = el("span", "dl " + line.kind);
			const number = el("span", "ln", line.number === null ? "" : String(line.number).padStart(width, " "));
			number.setAttribute("data-nocopy", "");
			row.appendChild(number);
			const sign = line.kind === "add" ? "+" : line.kind === "remove" ? "-" : line.kind === "gap" ? "" : " ";
			row.appendChild(el("span", "sg", sign));
			row.appendChild(document.createTextNode(line.text + (index < diff.lines.length - 1 ? "\n" : "")));
			pre.appendChild(row);
		});
		return pre;
	}

	// MARK: Hand-offs

	function agentFor(name, id) {
		const lower = name.toLowerCase();
		return names.agents.find((agent) => agent.id === id && id !== "") ?? names.agents.find((agent) => str(agent.name).toLowerCase() === lower || agent.id === name) ?? null;
	}

	function fillDelegate(row, call, phase) {
		const key = "d:" + call.callId;
		const status = statusOf(call, phase);
		const result = results.get(call.callId);
		const liveTool = live.tools.get(call.callId);
		const info = T.delegation(call, result, liveTool);
		const agent = agentFor(info.agentName, info.agentId);
		const who = agent ? str(agent.name) : info.agentName;
		const answer = result ? T.subagentAnswer(result.text) : "";
		row.className = "tool delegate " + status;
		row.replaceChildren();

		const head = el("div", "row-head");
		const avatar = el("span", "avatar", who.slice(0, 1).toUpperCase());
		avatar.setAttribute("aria-hidden", "true");
		avatar.setAttribute("data-nocopy", "");
		const colour = agent && COLOUR.test(str(agent.color)) ? agent.color : null;
		if (colour) avatar.style.setProperty("--agent", colour);
		head.appendChild(avatar);
		const label = el("span", "tool-label");
		label.appendChild(document.createTextNode(info.continued ? "Continued with " : "Handed to "));
		label.appendChild(el("span", "name", who));
		const model = agent ? str(agent.model) : "";
		if (model) label.appendChild(el("span", "muted", " " + char(0xb7) + " " + model));
		head.appendChild(label);
		if (status === "running" || status === "preparing") {
			head.appendChild(document.createTextNode(" "));
			const working = el("span", "tool-status working");
			working.appendChild(spinner("Working"));
			working.appendChild(document.createTextNode("Working"));
			head.appendChild(working);
		} else if (status === "failed") {
			head.appendChild(document.createTextNode(" "));
			head.appendChild(el("span", "tool-status failed", "Did not finish"));
		} else if (status === "none") {
			head.appendChild(document.createTextNode(" "));
			head.appendChild(el("span", "tool-status none", "No result"));
		} else {
			const done = glyph("check", "glyph done-glyph");
			done.setAttribute("aria-hidden", "false");
			done.setAttribute("role", "img");
			done.setAttribute("aria-label", "Finished");
			head.appendChild(done);
		}
		if (info.chat !== null) {
			const open = button("link-button", `Open ${who}${RSQUO}s sub-chat`, "Open");
			open.title = `Open ${who}${RSQUO}s sub-chat`;
			open.appendChild(glyph("open", "open-glyph"));
			open.addEventListener("click", (event) => {
				event.stopPropagation();
				post({ type: "openChat", id: info.chat });
			});
			head.appendChild(open);
		}
		row.appendChild(head);

		const body = el("div", "delegate-body");
		body.id = "body-" + ++bodyCount;
		if (info.task !== "") body.appendChild(el("div", "delegate-task", info.task));
		const answerBox = el("div", "delegate-answer" + (status === "failed" ? " failed" : ""));
		if (answer !== "" && status !== "running") {
			answerBox.appendChild(glyph("reply"));
			answerBox.appendChild(el("div", "answer-text md"));
			body.appendChild(answerBox);
		}
		row.appendChild(body);

		const expandable = answer !== "" || info.task.length > 140;
		if (!expandable) return;
		const toggle = chevron(body.id, `${who}${RSQUO}s answer`);
		head.insertBefore(toggle, info.chat !== null ? head.lastChild : null);
		const apply = (value) => {
			row.classList.toggle("open", value);
			toggle.setAttribute("aria-expanded", String(value));
			const words = answerBox.querySelector(".answer-text");
			if (!words) return;
			words.replaceChildren();
			// Folded, the answer reads as one run of text; opened, it keeps its own lines and formatting.
			if (value) words.appendChild(MD.render(document, answer));
			else MD.renderInline(document, MD.parseInline(T.folded(answer)), words);
		};
		apply(opened.get(key) ?? false);
		const toggleOpen = (event) => {
			if (selectionInside(row) || event.target.closest("a") || event.target.closest(".link-button")) return;
			userToggle(row, () => {
				const value = !row.classList.contains("open");
				opened.set(key, value);
				apply(value);
			});
		};
		head.onclick = toggleOpen;
		answerBox.onclick = toggleOpen;
	}

	// MARK: Waiting on the person

	/** An approval or a question at the point of its call, in the words and with the choices the Inbox uses. */
	function questionCard(pending, call) {
		const approval = pending.kind === "approval";
		const args = isObject(pending.arguments) ? pending.arguments : {};
		const who = str(pending.agentName) || "The agent";
		const app = pending.tool === "computer" && str(args.app) ? str(names.apps[args.app]) || str(args.app) : "";
		const schedule = pending.tool === "schedule_task" ? T.scheduleApproval(pending) : null;
		let request;
		if (app) request = `${who} wants to use ${app}`;
		else if (schedule) request = schedule.request;
		else if (pending.tool === "bash") request = `${who} wants to run a command`;
		else if (pending.tool === "write") request = `${who} wants to write a file`;
		else if (pending.tool === "edit") request = `${who} wants to edit a file`;
		else request = `${who} wants to use ${str(pending.tool)}`;
		const title = approval ? request : `${who} has a question`;

		const card = el("div", "card " + (approval ? "approval" : "question"));
		card.setAttribute("role", "group");
		card.setAttribute("aria-label", title);
		const head = el("div", "card-head");
		head.appendChild(el("span", "card-title", title));
		const note = el("span", "card-note", "waits for you " + char(0xb7) + " survives restarts");
		note.setAttribute("data-nocopy", "");
		head.appendChild(note);
		card.appendChild(head);

		if (approval) {
			if (schedule) {
				// When it would run, in the engine's words, then what each run would be told, in full: the person approves
				// the words, and nobody may be watching when they are carried out.
				card.appendChild(el("p", "card-summary words", schedule.when || T.callSummary(args)));
				if (schedule.prompt) card.appendChild(el("p", "card-summary words card-prompt", schedule.prompt));
				const caption = el("p", "card-caption", "Each run starts a new conversation with this agent and works with no one watching. You can turn the schedule off or delete it in Activity.");
				caption.setAttribute("data-nocopy", "");
				card.appendChild(caption);
			} else {
				// A computer action is described in words by the app that will do it; a command is shown as written.
				const summary = app ? str(pending.question) || T.callSummary(args) : T.callSummary(args);
				card.appendChild(el(app ? "p" : "pre", app ? "card-summary words" : "card-summary", summary));
			}
			// What a file will become, so the decision can be made from the card.
			let change = null;
			if (pending.tool === "edit") change = T.diffFromEdits(args);
			if (pending.tool === "write" && typeof args.content === "string") {
				change = { lines: args.content.replace(/\n$/, "").split("\n").map((text) => ({ kind: "add", number: null, text })) };
			}
			if (change && change.lines.length > 0) card.appendChild(diffElement(change)).classList.add("card-diff");
			const choices = el("div", "card-buttons");
			choices.setAttribute("data-nocopy", "");
			const decide = (decision) => {
				for (const b of choices.querySelectorAll("button")) b.disabled = true;
				post({ type: "decide", inbox: pending.id, decision });
			};
			const once = button("btn primary", null, "Allow Once");
			once.addEventListener("click", () => decide("once"));
			choices.appendChild(once);
			// A schedule runs later with no one watching, so each one is a decision of its own: there is no "always".
			if (!schedule) {
				const always = button("btn", null, app ? `Always Allow in ${app}` : `Always Allow ${str(pending.tool)} Here`);
				always.title = app ? `Stop asking about ${app} for the rest of this conversation` : `Stop asking about ${str(pending.tool)} in this conversation`;
				always.addEventListener("click", () => decide("always"));
				choices.appendChild(always);
			}
			const deny = button("btn danger", null, "Deny");
			deny.addEventListener("click", () => decide("deny"));
			choices.appendChild(deny);
			card.appendChild(choices);
		} else {
			card.appendChild(el("p", "card-question", str(pending.question)));
			const form = el("div", "card-answer");
			form.setAttribute("data-nocopy", "");
			const field = el("input", "answer-field");
			field.type = "text";
			field.placeholder = "Type an answer" + ELLIPSIS;
			field.setAttribute("aria-label", "Your answer");
			const send = button("btn primary", null, "Send");
			send.disabled = true;
			const submit = () => {
				if (field.value.trim() === "") return;
				post({ type: "answer", inbox: pending.id, text: field.value });
				field.disabled = true;
				send.disabled = true;
			};
			field.addEventListener("input", () => (send.disabled = field.value.trim() === ""));
			field.addEventListener("keydown", (event) => {
				if (event.key === "Enter" && !event.isComposing) {
					event.preventDefault();
					submit();
				}
			});
			send.addEventListener("click", submit);
			form.append(field, send);
			card.appendChild(form);
		}
		return card;
	}

	// MARK: - Pictures

	function thumbnail(entry, index, name, label, wide = false) {
		const key = entry + "/" + index;
		const b = button("thumb" + (wide ? " wide" : ""), "Enlarge: " + label);
		b.removeAttribute("data-nocopy");
		b.setAttribute("data-copy", `[Picture: ${name}]`);
		b.setAttribute("data-picture", key);
		b.title = name;
		const image = el("img");
		image.alt = label;
		b.appendChild(image);
		showPicture(b, pictures.get(key));
		b.addEventListener("click", () => {
			const picture = pictures.get(key);
			if (picture && picture.state === "ready") openLightbox(picture.url, label, b);
		});
		return b;
	}

	function showPicture(b, picture) {
		const image = b.querySelector("img");
		b.classList.toggle("loading", !picture || picture.state === "loading");
		b.classList.toggle("failed", !!picture && picture.state === "failed");
		if (picture && picture.state === "ready" && image.getAttribute("src") !== picture.url) {
			image.src = picture.url;
			image.addEventListener("load", followIfPinned, { once: true });
		}
		if (picture && picture.state === "failed") b.title = "The picture could not be loaded.";
	}

	const pictureObserver = new IntersectionObserver(
		(entries) => {
			for (const entry of entries) {
				if (!entry.isIntersecting) continue;
				pictureObserver.unobserve(entry.target);
				requestPicture(entry.target.getAttribute("data-picture"));
			}
		},
		{ rootMargin: "400px 0px" },
	);

	function observePictures(root) {
		for (const b of root.querySelectorAll("[data-picture]")) {
			if (b.__observed || b.closest("[hidden]")) continue;
			b.__observed = true;
			pictureObserver.observe(b);
		}
	}

	function requestPicture(key) {
		if (!key || pictures.has(key)) return;
		const [entry, index] = key.split("/").map(Number);
		if (!Number.isInteger(entry) || !Number.isInteger(index)) return;
		pictures.set(key, { state: "loading" });
		post({ type: "image", entry, index });
	}

	const PICTURE_TYPES = ["image/png", "image/jpeg", "image/gif", "image/webp"];

	function receivePicture(message) {
		const key = message.entry + "/" + message.index;
		let picture = { state: "failed" };
		if (typeof message.data === "string" && PICTURE_TYPES.includes(message.mimeType)) {
			try {
				const bytes = Uint8Array.from(atob(message.data), (c) => c.charCodeAt(0));
				picture = { state: "ready", url: URL.createObjectURL(new Blob([bytes], { type: message.mimeType })) };
			} catch {
				picture = { state: "failed" };
			}
		}
		pictures.set(key, picture);
		for (const b of document.querySelectorAll("[data-picture]")) if (b.getAttribute("data-picture") === key) showPicture(b, picture);
	}

	// MARK: Lightbox

	const lightbox = document.getElementById("lightbox");
	let lightboxReturn = null;

	function openLightbox(url, label, from) {
		const image = lightbox.querySelector("img");
		image.src = url;
		image.alt = label;
		lightbox.setAttribute("aria-label", label);
		lightbox.hidden = false;
		lightboxReturn = from;
		lightbox.querySelector("button").focus();
	}

	function closeLightbox() {
		if (lightbox.hidden) return;
		lightbox.hidden = true;
		lightbox.querySelector("img").removeAttribute("src");
		if (lightboxReturn) lightboxReturn.focus();
		lightboxReturn = null;
	}

	lightbox.addEventListener("click", closeLightbox);
	document.addEventListener("keydown", (event) => {
		if (event.key === "Escape") closeLightbox();
	});

	// MARK: - Following the newest

	const scroller = document.scrollingElement || document.documentElement;
	const jump = document.getElementById("jump");
	let pinned = true;
	let ignoreScrollUntil = 0;

	const distanceFromBottom = () => scroller.scrollHeight - scroller.scrollTop - window.innerHeight;

	function scrollToBottom() {
		ignoreScrollUntil = performance.now() + 200;
		scroller.scrollTop = scroller.scrollHeight;
	}

	function followIfPinned() {
		if (pinned) scrollToBottom();
	}

	function updateJump() {
		jump.hidden = pinned || distanceFromBottom() < 120;
	}

	window.addEventListener(
		"scroll",
		() => {
			if (distanceFromBottom() < 40) pinned = true;
			else if (performance.now() > ignoreScrollUntil) pinned = false;
			updateJump();
		},
		{ passive: true },
	);
	// Scrolling up to read stops following at once, even while new content keeps scrolling the page down.
	window.addEventListener(
		"wheel",
		(event) => {
			if (event.deltaY < 0) {
				pinned = false;
				ignoreScrollUntil = 0;
			}
		},
		{ passive: true },
	);
	window.addEventListener("keydown", (event) => {
		if (["PageUp", "ArrowUp", "Home"].includes(event.key) || (event.key === " " && event.shiftKey)) {
			if (!(event.target instanceof HTMLInputElement)) {
				pinned = false;
				ignoreScrollUntil = 0;
			}
		}
	});
	window.addEventListener("resize", followIfPinned);

	jump.addEventListener("click", () => {
		pinned = true;
		ignoreScrollUntil = performance.now() + 1000;
		scroller.scrollTo({ top: scroller.scrollHeight, behavior: "smooth" });
		updateJump();
	});

	/** Opens or closes a row the person clicked, keeping the row where it was on screen. */
	function userToggle(row, change) {
		const before = row.getBoundingClientRect().top;
		change();
		const after = row.getBoundingClientRect().top;
		if (after !== before) scroller.scrollTop += after - before;
		ignoreScrollUntil = performance.now() + 200;
		pinned = distanceFromBottom() < 40;
		observePictures(row);
		updateJump();
	}

	// MARK: - Links, copying

	document.addEventListener("click", (event) => {
		const target = event.target instanceof Element ? event.target : null;
		const link = target && target.closest("a[href]");
		if (link) {
			event.preventDefault();
			const url = MD.safeURL(link.getAttribute("href"));
			if (url) post({ type: "openLink", url });
			return;
		}
		const copy = target && target.closest('[data-action="copy-code"]');
		if (copy) {
			const code = copy.closest(".codeblock")?.querySelector("pre code");
			if (code) {
				post({ type: "copy", text: codeText(code) });
				copy.textContent = "Copied";
				setTimeout(() => (copy.textContent = "Copy"), 1400);
			}
		}
	});
	// Middle clicks and the like on a link do nothing here; the app opens links only through the click above.
	document.addEventListener("auxclick", (event) => {
		if (event.target instanceof Element && event.target.closest("a[href]")) event.preventDefault();
	});
	document.addEventListener("dragstart", (event) => {
		if (event.target instanceof Element && event.target.closest("img")) event.preventDefault();
	});

	function codeText(code) {
		let out = "";
		const walk = (node) => {
			if (node.nodeType === 3) out += node.data;
			else if (node.nodeType === 1 && !node.hasAttribute("data-nocopy")) for (const child of node.childNodes) walk(child);
		};
		walk(code);
		return out;
	}

	document.addEventListener("copy", (event) => {
		const active = document.activeElement;
		if (active && (active.tagName === "INPUT" || active.tagName === "TEXTAREA")) return;
		const selection = window.getSelection();
		if (!selection || selection.rangeCount === 0 || selection.isCollapsed) return;
		const fragment = document.createDocumentFragment();
		for (let i = 0; i < selection.rangeCount; i++) fragment.appendChild(selection.getRangeAt(i).cloneContents());
		const text = C.plainText(fragment);
		const holder = document.createElement("div");
		holder.appendChild(C.cleanForHTML(fragment, document));
		event.clipboardData.setData("text/plain", text);
		event.clipboardData.setData("text/html", holder.innerHTML);
		event.preventDefault();
	});

	/** What a select-all would copy. For checking the page from outside; changes nothing. */
	function selectedText() {
		const selection = window.getSelection();
		if (!selection || selection.rangeCount === 0) return "";
		const fragment = document.createDocumentFragment();
		for (let i = 0; i < selection.rangeCount; i++) fragment.appendChild(selection.getRangeAt(i).cloneContents());
		return C.plainText(fragment);
	}
	Object.defineProperty(window, "pi2Selection", { value: selectedText, writable: false, configurable: false });

	post({ type: "ready" });
})();
