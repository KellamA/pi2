/*
 * A `present` call's card (#946; docs/design/presenting.md, "The transcript page"), in the look the owner chose, A,
 * Gallery: a framed card, the items side by side in equal columns, each labelled in a corner and captioned under it,
 * the question and its buttons at the foot. On a phone (`html.narrow`), one item at a time, with the labels as tabs.
 *
 * What it reads is the app's `presented` message (each `PresentationRecord` of the conversation) or, while there is
 * no record, the call's own result (`details`: the `PresentedVersion` with its `presentation`). Anything it does not
 * understand, such as a later version of that shape, gives no card, and the page draws the plain tool row instead.
 *
 * Everything an agent wrote (title, labels, captions, names, the question and its choices) goes in as text, never as
 * markup, and nothing here makes a link. Loaded as a plain script by the page (it sets `PiPresented`); Node tests it.
 */
(function (root, factory) {
	const api = factory();
	if (typeof module === "object" && module.exports) module.exports = api;
	else root.PiPresented = api;
})(typeof globalThis !== "undefined" ? globalThis : this, function () {
	"use strict";

	const char = String.fromCharCode;
	const DOT = char(0xb7);
	const ELLIPSIS = char(0x2026);
	const LDQUO = char(0x201c);
	const RDQUO = char(0x201d);
	const DASH = char(0x2014);
	const TIMES = char(0xd7);

	const isObject = (value) => value !== null && typeof value === "object" && !Array.isArray(value);
	const str = (value) => (typeof value === "string" ? value : "");
	const size = (value) => (typeof value === "number" && Number.isFinite(value) && value > 0 ? value : null);

	/** A presentation's id: `p1`, `p2`, … */
	const ID = /^p[1-9]\d{0,8}$/;
	const MAX_ITEMS = 6;
	const ENDED = ["withdrawn", "messaged", "stopped"];

	// MARK: - Reading

	/** One item of a version, or null when it is not one this page knows how to draw. */
	function readItem(item) {
		if (!isObject(item) || typeof item.label !== "string" || (item.kind !== "picture" && item.kind !== "page")) return null;
		if (item.caption !== null && item.caption !== undefined && typeof item.caption !== "string") return null;
		let snapshot = null;
		if (item.kind === "page") {
			const s = item.snapshot;
			if (s === null || s === undefined) snapshot = { state: "pending" };
			else if (!isObject(s)) return null;
			else if (s.state === "drawn" || s.state === "pending") snapshot = { state: s.state };
			else if (s.state === "failed") snapshot = { state: "failed", reason: str(s.reason) };
			else return null;
		}
		const drawn = isObject(item.drawn) ? item.drawn : null;
		return {
			label: item.label,
			caption: str(item.caption),
			kind: item.kind,
			name: str(item.name),
			mimeType: str(item.mimeType),
			bytes: size(item.bytes),
			width: size(item.width),
			height: size(item.height),
			snapshot,
			drawn: drawn && {
				blank: drawn.blank === true,
				console: Array.isArray(drawn.console) ? drawn.console.filter((line) => typeof line === "string") : [],
				blocked: Array.isArray(drawn.blocked) ? drawn.blocked.filter((line) => typeof line === "string") : [],
			},
		};
	}

	/** A version's question, or null when it has one this page does not understand (undefined when it has none). */
	function readQuestion(question) {
		if (question === null || question === undefined) return undefined;
		if (!isObject(question) || typeof question.text !== "string" || typeof question.need !== "string" || !Array.isArray(question.choices)) return null;
		const choices = [];
		for (const choice of question.choices) {
			if (!isObject(choice) || typeof choice.id !== "string" || typeof choice.label !== "string") return null;
			choices.push({ id: choice.id, label: choice.label });
		}
		let answer = null;
		const a = question.answer;
		if (a !== null && a !== undefined) {
			if (!isObject(a)) return null;
			if (typeof a.chose === "string") answer = { chose: a.chose };
			else if (typeof a.words === "string") answer = { words: a.words };
			else if (ENDED.includes(a.ended)) answer = { ended: a.ended };
			else return null;
		}
		return { text: question.text, choices, need: question.need, answer };
	}

	/** A `PresentedVersion`, or null when this page does not understand it. */
	function readVersion(version) {
		if (!isObject(version) || !Number.isInteger(version.version) || version.version < 1 || typeof version.title !== "string") return null;
		if (!Array.isArray(version.items) || version.items.length === 0 || version.items.length > MAX_ITEMS) return null;
		const items = version.items.map(readItem);
		if (items.includes(null)) return null;
		const question = readQuestion(version.question);
		if (question === null) return null;
		return { version: version.version, callId: str(version.callId), title: version.title, items, question: question ?? null };
	}

	/**
	 * The app's `presented.records`, checked: each record with its id and, for each version, the call that presented it
	 * and the version as read (null where it is not understood, so that call's card falls back to its row).
	 */
	function readRecords(list) {
		const out = [];
		for (const record of Array.isArray(list) ? list : []) {
			if (!isObject(record) || typeof record.id !== "string" || !ID.test(record.id) || !Array.isArray(record.versions)) continue;
			const versions = [];
			for (const version of record.versions) {
				if (!isObject(version) || typeof version.callId !== "string" || version.callId === "") continue;
				versions.push({ callId: version.callId, version: Number.isInteger(version.version) ? version.version : 0, data: readVersion(version) });
			}
			out.push({ id: record.id, versions });
		}
		return out;
	}

	/**
	 * What a `present` call's card shows: from the record's version whose `callId` is the call's, or from the call's
	 * result (`details`) while it has no record. `latest` is the record's newest version, for "A newer version is
	 * below". Null when there is nothing to draw, or nothing this page understands.
	 */
	function forCall(records, callId, details) {
		for (const record of records.values()) {
			const found = record.versions.find((version) => version.callId === callId);
			if (!found) continue;
			if (!found.data) return null;
			const latest = Math.max(...record.versions.map((version) => version.version));
			return view(record.id, found.data, latest);
		}
		if (isObject(details) && typeof details.presentation === "string" && ID.test(details.presentation)) {
			const data = readVersion(details);
			if (data) return view(details.presentation, data, data.version);
		}
		return null;
	}

	function view(presentation, data, latest) {
		return { presentation, version: data.version, latest: Math.max(latest, data.version), title: data.title, items: data.items, question: data.question };
	}

	/** The version as the row under the card reads it (tools.js `presentedSummary`). */
	function asDetails(v) {
		return { presentation: v.presentation, version: v.version, title: v.title, items: v.items, question: v.question };
	}

	// MARK: - Pictures

	/** An item's picture, as the page keeps and asks for it: "p2/3/0". */
	const key = (v, index) => `${v.presentation}/${v.version}/${index}`;

	/** `{ presentation, version, item }` from a key, or null. */
	function parseKey(text) {
		const match = /^(p[1-9]\d{0,8})\/([1-9]\d{0,8})\/(\d)$/.exec(str(text));
		return match ? { presentation: match[1], version: Number(match[2]), item: Number(match[3]) } : null;
	}

	/** Whether there is a picture to ask for: a picture's own, or a page's snapshot once it is drawn. */
	const fetchable = (item) => item.kind === "picture" || item.snapshot.state === "drawn";

	const clamp = (value, low, high) => Math.min(high, Math.max(low, value));

	/**
	 * The width over the height of the frame an item is shown in, so its place is kept at the right proportions before
	 * the picture comes. A page shows its top as a window of 16 by 10 would, however long it is.
	 */
	function ratio(item) {
		const width = item.width ?? (item.kind === "page" ? 1280 : null);
		const height = item.height ?? (item.kind === "page" ? 800 : null);
		if (!width || !height) return 1.6;
		const shown = item.kind === "page" ? Math.min(height, width / 1.6) : height;
		return clamp(width / shown, 0.4, 3);
	}

	/** One proportion for all the frames of a card, so its columns line up: the middle one of its items'. */
	function gridRatio(items) {
		const ratios = items.map(ratio).sort((a, b) => a - b);
		return clamp(ratios[Math.floor((ratios.length - 1) / 2)], 0.6, 2.4);
	}

	// MARK: - Words

	/** The note in the card's head: which presentation and version, and whether it waits for the person. */
	function note(v, answering = false) {
		const waits = v.question && !v.question.answer && !answering;
		return `${v.presentation} ${DOT} version ${v.version}` + (waits ? ` ${DOT} waits for you` : "");
	}

	/** What the card says once its question has ended: what the person chose or wrote, or why it no longer waits. */
	function answerWords(question) {
		const answer = question && question.answer;
		if (!answer) return "";
		if (answer.chose !== undefined) {
			// The choices made for the person ("Use B") read as the item itself.
			const plain = /^Use (\S.{0,11})$/.exec(answer.chose);
			return plain ? `You chose ${plain[1]}.` : `You chose ${LDQUO}${answer.chose}${RDQUO}.`;
		}
		if (answer.words !== undefined) return `You answered: ${LDQUO}${answer.words}${RDQUO}`;
		if (answer.ended === "withdrawn") return "It no longer waits: the question was withdrawn.";
		if (answer.ended === "messaged") return "It no longer waits: you sent a message instead.";
		return "It no longer waits: the agent stopped.";
	}

	/** The item's file name, from the path the agent gave. */
	const fileName = (name) => name.split("/").filter(Boolean).pop() ?? "";

	/** What a copy of the card gives for an item: "[Picture A: login-a.png — Compact form]". */
	function copyText(item) {
		const what = (item.kind === "page" ? "Page" : "Picture") + (item.label ? " " + item.label : "");
		const name = fileName(item.name);
		return `[${what}${name ? ": " + name : ""}${item.caption ? " " + DASH + " " + item.caption.replace(/\s+/g, " ").trim() : ""}]`;
	}

	/** "Page · 1280×900", the mark on a page's snapshot. */
	function pageMark(item) {
		return "Page" + (item.width && item.height ? ` ${DOT} ${Math.round(item.width)}${TIMES}${Math.round(item.height)}` : "");
	}

	/** What a frame says in place of its picture: nothing while it comes, or why there is none. */
	function placeholder(item, picture) {
		if (item.kind === "page" && item.snapshot.state === "pending") return "Drawing the page" + ELLIPSIS;
		if (item.kind === "page" && item.snapshot.state === "failed") return "The page could not be drawn";
		if (picture && picture.state === "failed") return "Not available";
		return "";
	}

	// MARK: - Building

	function make(doc, tag, className, text) {
		const element = doc.createElement(tag);
		if (className) element.setAttribute("class", className);
		if (text !== undefined && text !== null && text !== "") element.appendChild(doc.createTextNode(text));
		return element;
	}

	function control(doc, className, label, text) {
		const b = make(doc, "button", className, text);
		b.setAttribute("type", "button");
		if (label) b.setAttribute("aria-label", label);
		b.setAttribute("data-nocopy", "");
		return b;
	}

	/**
	 * Shows `picture` ({ state: "loading" | "ready" | "failed", url }) in an item's frame, or what stands in its place.
	 * Called as the card is built and again when the picture comes.
	 */
	function showPicture(frame, picture) {
		const { item, image, status } = frame.__parts;
		const words = placeholder(item, picture);
		const ready = !!picture && picture.state === "ready" && words === "";
		const state = ready ? "ready" : words !== "" ? "failed" : "loading";
		frame.setAttribute("class", "pa-frame " + state + (item.kind === "page" ? " page" : ""));
		if (ready && image.getAttribute("src") !== picture.url) image.setAttribute("src", picture.url);
		if (status.textContent !== words) status.textContent = words;
	}

	/** One item: its frame, which opens it larger, with its label in a corner and a page's mark; its caption under it. */
	function figure(doc, v, index, ui, one, frameRatio) {
		const item = v.items[index];
		const box = make(doc, "figure", "pa-item");
		box.setAttribute("data-copy", copyText(item));
		const what = (item.kind === "page" ? "page" : "picture") + (one || !item.label ? "" : " " + item.label);
		const frame = control(doc, "pa-frame", `Expand the ${what}` + (item.caption ? `: ${item.caption}` : ""));
		if (item.name) frame.setAttribute("title", item.name);
		frame.style.setProperty("--ratio", String(Math.round(frameRatio * 1000) / 1000));
		if (one && item.kind === "picture" && item.width) frame.style.setProperty("--own-width", Math.round(item.width) + "px");
		if (fetchable(item)) frame.setAttribute("data-presented", key(v, index));
		const image = make(doc, "img");
		image.setAttribute("alt", item.caption || item.label || what);
		frame.appendChild(image);
		const status = frame.appendChild(make(doc, "span", "pa-status"));
		frame.__parts = { item, image, status };
		if (!one && item.label) frame.appendChild(make(doc, "span", "pa-label", item.label));
		if (item.kind === "page") {
			const mark = make(doc, "span", "page-mark");
			mark.appendChild(ui.glyph("page", "mark-glyph"));
			mark.appendChild(doc.createTextNode(pageMark(item)));
			frame.appendChild(mark);
		}
		showPicture(frame, ui.picture(key(v, index)));
		frame.addEventListener("click", (event) => {
			if (event && event.stopPropagation) event.stopPropagation();
			ui.expand(index, frame);
		});
		box.appendChild(frame);
		if (item.caption) box.appendChild(make(doc, "figcaption", "", item.caption));
		return { box, frame };
	}

	/** The question at the card's foot: a button for each choice and a field for words, or what was answered. */
	function ask(doc, v, ui) {
		const q = v.question;
		const box = make(doc, "div", "present-ask");
		box.appendChild(make(doc, "p", "card-question", q.text));
		if (q.answer) {
			box.appendChild(make(doc, "p", "present-answer", answerWords(q)));
			return box;
		}
		let sent = ui.answering;
		const buttons = [];
		const lock = () => {
			sent = true;
			for (const b of buttons) b.disabled = true;
		};
		const choices = make(doc, "div", "card-buttons");
		choices.setAttribute("data-nocopy", "");
		for (const choice of q.choices) {
			const b = control(doc, "btn", null, choice.label);
			b.disabled = sent;
			b.addEventListener("click", (event) => {
				if (event && event.stopPropagation) event.stopPropagation();
				if (sent) return;
				lock();
				ui.choose(choice.id);
			});
			buttons.push(b);
			choices.appendChild(b);
		}
		if (buttons.length > 0) box.appendChild(choices);
		// The words go once, as a choice does; the field's own Send and Return send them (keys.js).
		box.appendChild(
			ui.form("Or say it in words", sent, (text) => {
				if (sent) return false;
				lock();
				ui.answer(text);
				return true;
			}),
		);
		return box;
	}

	/**
	 * The card for a version `v` (from `forCall`). `ui` gives what the page keeps and does: `narrow`, the phone's
	 * layout; `shown`, the item shown there; `picture(key)`, a picture as the page has it; `answering`, an answer sent
	 * and not yet heard back; `glyph(name, className)`; `form(placeholder, disabled, send)`, the field for words, whose
	 * `send(text)` says whether it went; and `expand(index, from)`, `select(index)`, `choose(id)`, `answer(text)`.
	 */
	function card(doc, v, ui) {
		const one = v.items.length === 1;
		const shown = clamp(Number.isInteger(ui.shown) ? ui.shown : 0, 0, v.items.length - 1);
		const section = make(doc, "section", "card present pa" + (one ? " one" : ""));
		section.setAttribute("role", "group");
		section.setAttribute("aria-label", v.title);

		const head = make(doc, "div", "card-head");
		head.appendChild(make(doc, "span", "card-title", v.title));
		const noteText = make(doc, "span", "card-note", note(v, ui.answering));
		noteText.setAttribute("data-nocopy", "");
		head.appendChild(noteText);
		const expand = control(doc, "link-button expand", `Expand ${LDQUO}${v.title}${RDQUO}`, "");
		expand.setAttribute("title", "Open it in a window of its own");
		expand.appendChild(ui.glyph("expand", "open-glyph"));
		expand.appendChild(doc.createTextNode("Expand"));
		expand.addEventListener("click", (event) => {
			if (event && event.stopPropagation) event.stopPropagation();
			ui.expand(ui.narrow ? shown : 0, expand);
		});
		head.appendChild(expand);
		section.appendChild(head);

		if (one || !ui.narrow) {
			const grid = make(doc, "div", `pa-grid n${v.items.length}`);
			const frameRatio = one ? ratio(v.items[0]) : gridRatio(v.items);
			v.items.forEach((_, index) => grid.appendChild(figure(doc, v, index, ui, one, frameRatio).box));
			section.appendChild(grid);
		} else {
			// One at a time, the labels as tabs; a swipe across the picture steps to the next or the one before.
			const tabs = make(doc, "div", "pa-tabs");
			tabs.setAttribute("role", "tablist");
			tabs.setAttribute("data-nocopy", "");
			v.items.forEach((item, index) => {
				const tab = control(doc, index === shown ? "on" : "", null, item.label || String(index + 1));
				tab.setAttribute("role", "tab");
				tab.setAttribute("aria-selected", String(index === shown));
				if (item.caption) tab.setAttribute("title", item.caption);
				tab.addEventListener("click", (event) => {
					if (event && event.stopPropagation) event.stopPropagation();
					if (index !== shown) ui.select(index);
				});
				tabs.appendChild(tab);
			});
			section.appendChild(tabs);
			const { box, frame } = figure(doc, v, shown, ui, false, gridRatio(v.items));
			let from = null;
			frame.addEventListener("touchstart", (event) => {
				const touch = event && event.touches && event.touches[0];
				from = touch ? { x: touch.clientX, y: touch.clientY } : null;
			}, { passive: true });
			frame.addEventListener("touchend", (event) => {
				const touch = event && event.changedTouches && event.changedTouches[0];
				if (!from || !touch) return;
				const dx = touch.clientX - from.x;
				const dy = touch.clientY - from.y;
				from = null;
				if (Math.abs(dx) < 40 || Math.abs(dx) < Math.abs(dy) * 1.5) return;
				const next = clamp(shown + (dx < 0 ? 1 : -1), 0, v.items.length - 1);
				if (next !== shown) ui.select(next);
			});
			section.appendChild(box);
			const dots = make(doc, "div", "dots");
			dots.setAttribute("aria-hidden", "true");
			dots.setAttribute("data-nocopy", "");
			v.items.forEach((_, index) => dots.appendChild(make(doc, "i", index === shown ? "on" : "")));
			section.appendChild(dots);
		}

		if (v.question) section.appendChild(ask(doc, v, ui));
		if (v.latest > v.version) {
			const newer = make(doc, "p", "present-newer", "A newer version is below.");
			newer.setAttribute("data-nocopy", "");
			section.appendChild(newer);
		}
		return section;
	}

	return { readRecords, readVersion, forCall, asDetails, key, parseKey, fetchable, ratio, gridRatio, note, answerWords, copyText, pageMark, placeholder, showPicture, card };
});
