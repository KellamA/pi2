import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { test } from "node:test";
import Pr from "../transcript/presented.js";
import T from "../transcript/tools.js";
import { document, elements, fire, html } from "./fakedom.mjs";

// A presentation as docs/design/presenting.md stores it ("What is stored"): three sign-in screens, B a page.
const picture = (label, name, caption, extra = {}) => ({
	label, caption, kind: "picture", name, mimeType: "image/png", sha256: "a".repeat(64), bytes: 212_000, files: 1, width: 1440, height: 900, snapshot: null, drawn: null, ...extra,
});
const page = (label, name, caption, snapshot = { state: "drawn", sha256: "b".repeat(64) }, drawn = { loadMs: 400, blank: false, console: [], blocked: [] }) => ({
	label, caption, kind: "page", name, mimeType: "text/html", sha256: "c".repeat(64), bytes: 1_200_000, files: 7, width: 1280, height: 900, snapshot, drawn,
});
const ITEMS = [
	picture("A", "mockups/signin-a.png", "Today's form in a card, on a soft wash"),
	page("B", "mockups/signin-b/index.html", "The product's promise beside the form"),
	picture("C", "mockups/signin-c.svg", "Nothing but the fields, large type", { mimeType: "image/svg+xml" }),
];
const QUESTION = { text: "Which one should I build?", choices: [{ id: "1", label: "Use A" }, { id: "2", label: "Use B" }, { id: "3", label: "Use C" }], words: true, need: "q-7", answer: null };
const version = (n, callId, extra = {}) => ({ version: n, callId, createdAt: 0, title: "Sign-in screen, three layouts", items: ITEMS, question: null, ...extra });
const record = (versions) => ({ id: "p2", versions, network: false });
const records = (list) => new Map(Pr.readRecords(list).map((r) => [r.id, r]));

/** What the page gives a card: a call's handlers record what they were asked. */
function ui(over = {}) {
	const asked = [];
	return {
		asked,
		narrow: false,
		shown: 0,
		picture: () => undefined,
		answering: false,
		glyph: (name, className) => {
			const svg = document.createElement("svg");
			svg.setAttribute("class", className);
			svg.setAttribute("data-glyph", name);
			return svg;
		},
		form: (placeholder, disabled, send) => {
			const form = document.createElement("div");
			form.setAttribute("class", "card-answer");
			form.setAttribute("data-placeholder", placeholder);
			form.disabled = disabled;
			form.send = send;
			return form;
		},
		expand: (index) => asked.push(["expand", index]),
		select: (index) => asked.push(["select", index]),
		choose: (id) => asked.push(["choose", id]),
		answer: (text) => asked.push(["answer", text]),
		...over,
	};
}

const byClass = (root, name) => elements(root).filter((e) => e.className.split(/\s+/).includes(name));
const one = (root, name) => {
	const found = byClass(root, name);
	assert.equal(found.length, 1, `one .${name}`);
	return found[0];
};

test("a call's card is drawn from its record's version, or from its result while it has none", () => {
	const map = records([record([version(1, "c1"), version(2, "c2", { question: QUESTION })])]);
	const first = Pr.forCall(map, "c1", null);
	assert.equal(first.presentation, "p2");
	assert.equal(first.version, 1);
	assert.equal(first.latest, 2, "the record knows of a newer version");
	assert.equal(first.items.length, 3);
	assert.equal(Pr.forCall(map, "c2", null).question.need, "q-7");
	// No record yet: the call's own result, the version with its presentation.
	const fromResult = Pr.forCall(new Map(), "c9", { presentation: "p4", ...version(1, "c9") });
	assert.equal(fromResult.presentation, "p4");
	assert.equal(fromResult.latest, 1);
	// The record is the newer truth (a snapshot drawn later, an answer): it wins over the result.
	const answered = records([record([version(1, "c1", { question: { ...QUESTION, answer: { chose: "Use B" } } })])]);
	assert.deepEqual(Pr.forCall(answered, "c1", { presentation: "p2", ...version(1, "c1", { question: QUESTION }) }).question.answer, { chose: "Use B" });
	assert.equal(Pr.forCall(new Map(), "c1", null), null, "nothing to draw yet");
	assert.equal(Pr.forCall(new Map(), "c1", { presentation: "x2", ...version(1, "c1") }), null, "not a presentation's id");
});

test("a shape the page does not understand gives no card, so the plain row is drawn", () => {
	const later = (change) => Pr.forCall(records([record([{ ...version(1, "c1"), ...change }])]), "c1", null);
	assert.equal(later({ items: [{ ...ITEMS[0], kind: "video" }] }), null, "an item of a kind it does not know");
	assert.equal(later({ items: { A: ITEMS[0] } }), null, "items not a list");
	assert.equal(later({ items: [] }), null, "no items");
	assert.equal(later({ items: [...ITEMS, ...ITEMS, ITEMS[0]] }), null, "more than six");
	assert.equal(later({ version: "1" }), null, "a version not a number");
	assert.equal(later({ title: { text: "Sign-in" } }), null, "a title not text");
	assert.equal(later({ items: [ITEMS[0], { ...ITEMS[1], snapshot: { state: "streaming" } }] }), null, "a snapshot state it does not know");
	assert.equal(later({ question: { ...QUESTION, answer: { picked: [1, 2] } } }), null, "an answer it does not know");
	assert.equal(later({ question: { ...QUESTION, choices: "A, B" } }), null, "choices not a list");
	// Fields it does not know of are left alone: a newer engine may add some.
	assert.notEqual(later({ shelf: "later", items: [{ ...ITEMS[0], palette: ["#fff"] }] }), null);
	// And a record whose id is not one is not kept at all.
	assert.equal(Pr.readRecords([{ id: "<p2>", versions: [version(1, "c1")] }, "nonsense", null]).length, 0);
});

test("wide: the items side by side, each labelled and captioned, Expand at the head, the page marked", () => {
	const v = Pr.forCall(records([record([version(1, "c1"), version(2, "c2")])]), "c1", null);
	const card = Pr.card(document, v, ui());
	assert.equal(card.localName, "section");
	assert.equal(card.className, "card present pa");
	assert.equal(one(card, "card-title").textContent, "Sign-in screen, three layouts");
	assert.equal(one(card, "card-note").textContent, "p2 · version 1");
	assert.equal(one(card, "expand").textContent, "Expand");
	assert.equal(one(card, "pa-grid").className, "pa-grid n3");
	assert.deepEqual(byClass(card, "pa-label").map((e) => e.textContent), ["A", "B", "C"]);
	assert.deepEqual(elements(card).filter((e) => e.localName === "figcaption").map((e) => e.textContent), ITEMS.map((item) => item.caption));
	assert.equal(one(card, "page-mark").textContent, "Page · 1280×900");
	assert.equal(byClass(card, "pa-tabs").length, 0, "no tabs when wide");
	// An older version says a newer one is below; the newest does not.
	assert.equal(one(card, "present-newer").textContent, "A newer version is below.");
	const newest = Pr.card(document, Pr.forCall(records([record([version(1, "c1"), version(2, "c2")])]), "c2", null), ui());
	assert.equal(byClass(newest, "present-newer").length, 0);
	assert.equal(one(newest, "card-note").textContent, "p2 · version 2");
	// The frames share one proportion, so the columns line up.
	assert.deepEqual(new Set(byClass(card, "pa-frame").map((f) => f.style.getPropertyValue("--ratio"))), new Set(["1.6"]));
	// Copied, each item reads as what it is.
	assert.deepEqual(elements(card).filter((e) => e.localName === "figure").map((e) => e.getAttribute("data-copy")), [
		"[Picture A: signin-a.png — Today's form in a card, on a soft wash]",
		"[Page B: index.html — The product's promise beside the form]",
		"[Picture C: signin-c.svg — Nothing but the fields, large type]",
	]);
});

test("one item alone: no label in its corner, at its own proportions, no wider than itself", () => {
	const shot = picture("A", "app/build/shots/946/settings.png", "As it is now, in a throwaway copy", { width: 1440, height: 900 });
	const v = Pr.forCall(new Map(), "c1", { presentation: "p1", ...version(1, "c1", { title: "Settings › General, as it is now", items: [shot] }) });
	const card = Pr.card(document, v, ui({ narrow: true }));
	assert.equal(card.className, "card present pa one");
	assert.equal(one(card, "pa-grid").className, "pa-grid n1", "one item has no tabs, even on a phone");
	assert.equal(byClass(card, "pa-label").length, 0);
	assert.equal(byClass(card, "dots").length, 0);
	const frame = one(card, "pa-frame");
	assert.equal(frame.style.getPropertyValue("--ratio"), "1.6");
	assert.equal(frame.style.getPropertyValue("--own-width"), "1440px");
	assert.equal(one(card, "card-note").textContent, "p1 · version 1");
	// A tall phone screenshot keeps its own shape, within bounds.
	assert.equal(Pr.ratio(picture("A", "a.png", "", { width: 1179, height: 2556 })), 1179 / 2556);
	assert.equal(Pr.ratio(picture("A", "a.png", "", { width: 100, height: 4000 })), 0.4);
	// A page shows the top of itself, as a window of 16 by 10 would.
	assert.equal(Pr.ratio(page("B", "b.html", "")), 1.6);
	assert.equal(Pr.ratio({ ...page("B", "b.html", ""), height: 400 }), 3, "a short wide page, within bounds");
});

test("pictures: asked for by key, the right proportions meanwhile, Not available when they fail", () => {
	const states = new Map([["p2/1/2", { state: "failed" }], ["p2/1/0", { state: "ready", url: "blob:pi2/1" }]]);
	const v = Pr.forCall(records([record([version(1, "c1")])]), "c1", null);
	const card = Pr.card(document, v, ui({ picture: (key) => states.get(key) }));
	const frames = byClass(card, "pa-frame");
	assert.deepEqual(frames.map((f) => f.getAttribute("data-presented")), ["p2/1/0", "p2/1/1", "p2/1/2"]);
	assert.equal(frames[0].className, "pa-frame ready");
	assert.equal(elements(frames[0]).find((e) => e.localName === "img").getAttribute("src"), "blob:pi2/1");
	assert.equal(frames[1].className, "pa-frame loading page", "asked for, not come yet");
	assert.equal(frames[2].className, "pa-frame failed");
	assert.equal(one(frames[2], "pa-status").textContent, "Not available");
	// When it comes, the same frame shows it.
	Pr.showPicture(frames[1], { state: "ready", url: "blob:pi2/2" });
	assert.equal(frames[1].className, "pa-frame ready page");
	assert.equal(one(frames[1], "pa-status").textContent, "");
	// A page whose snapshot is not drawn has nothing to ask for, and says so.
	const pending = Pr.forCall(records([record([version(1, "c1", { items: [ITEMS[0], page("B", "b/index.html", "", { state: "pending" }, null), page("C", "c/index.html", "", { state: "failed", reason: "It took longer than 20 seconds" }, null)] })])]), "c1", null);
	const waiting = byClass(Pr.card(document, pending, ui()), "pa-frame");
	assert.equal(waiting[1].getAttribute("data-presented"), null);
	assert.equal(one(waiting[1], "pa-status").textContent, "Drawing the page…");
	assert.equal(waiting[2].getAttribute("data-presented"), null);
	assert.equal(one(waiting[2], "pa-status").textContent, "The page could not be drawn");
	// Keys round-trip, and nothing else reads as one.
	assert.deepEqual(Pr.parseKey("p2/3/5"), { presentation: "p2", version: 3, item: 5 });
	for (const bad of ["p0/1/0", "p2/0/1", "p2/1/x", "../p2/1/0", "p2/1/10", 7]) assert.equal(Pr.parseKey(bad), null, String(bad));
});

test("Expand, and a click on an item, ask for that item", () => {
	const v = Pr.forCall(records([record([version(1, "c1")])]), "c1", null);
	const handlers = ui();
	const card = Pr.card(document, v, handlers);
	fire(one(card, "expand"), "click");
	fire(byClass(card, "pa-frame")[2], "click");
	assert.deepEqual(handlers.asked, [["expand", 0], ["expand", 2]]);
	// On a phone, Expand opens the item shown.
	const narrow = ui({ narrow: true, shown: 1 });
	fire(one(Pr.card(document, v, narrow), "expand"), "click");
	assert.deepEqual(narrow.asked, [["expand", 1]]);
});

test("the question: a button for each choice and the field for words, each answering once", () => {
	const v = Pr.forCall(records([record([version(2, "c2", { question: QUESTION })])]), "c2", null);
	const handlers = ui();
	const card = Pr.card(document, v, handlers);
	assert.equal(one(card, "card-note").textContent, "p2 · version 2 · waits for you");
	assert.equal(one(card, "card-question").textContent, "Which one should I build?");
	const buttons = elements(one(card, "card-buttons")).filter((e) => e.localName === "button");
	assert.deepEqual(buttons.map((b) => b.textContent), ["Use A", "Use B", "Use C"]);
	const form = one(card, "card-answer");
	assert.equal(form.getAttribute("data-placeholder"), "Or say it in words");
	fire(buttons[1], "click");
	fire(buttons[1], "click");
	fire(buttons[2], "click");
	assert.equal(form.send("B, with A's warning colour"), false, "the words do not go after a choice");
	assert.deepEqual(handlers.asked, [["choose", "2"]]);
	assert.ok(buttons.every((b) => b.disabled));

	// Words first: they go once, and the choices are done with.
	const words = ui();
	const second = Pr.card(document, v, words);
	const form2 = one(second, "card-answer");
	assert.equal(form2.send("B, with A's warning colour"), true);
	assert.equal(form2.send("again"), false);
	fire(elements(second).find((e) => e.localName === "button" && e.textContent === "Use A"), "click");
	assert.deepEqual(words.asked, [["answer", "B, with A's warning colour"]]);

	// Rebuilt while the answer is on its way: nothing to press, and it no longer says it waits.
	const sent = Pr.card(document, v, ui({ answering: true }));
	assert.equal(one(sent, "card-note").textContent, "p2 · version 2");
	assert.ok(elements(one(sent, "card-buttons")).filter((e) => e.localName === "button").every((b) => b.disabled));
	assert.equal(one(sent, "card-answer").disabled, true);
});

test("answered, the card says what was chosen or written; ended, that it no longer waits", () => {
	const answered = (answer) => {
		const v = Pr.forCall(records([record([version(2, "c2", { question: { ...QUESTION, answer } })])]), "c2", null);
		const card = Pr.card(document, v, ui());
		assert.equal(byClass(card, "card-buttons").length, 0);
		assert.equal(byClass(card, "card-answer").length, 0);
		assert.equal(one(card, "card-note").textContent, "p2 · version 2");
		return one(card, "present-answer").textContent;
	};
	assert.equal(answered({ chose: "Use B" }), "You chose B.");
	assert.equal(answered({ chose: "Ship the plain one" }), "You chose “Ship the plain one”.");
	assert.equal(answered({ words: "B, but with the warning colour of A" }), "You answered: “B, but with the warning colour of A”");
	assert.equal(answered({ ended: "withdrawn" }), "It no longer waits: the question was withdrawn.");
	assert.equal(answered({ ended: "messaged" }), "It no longer waits: you sent a message instead.");
	assert.equal(answered({ ended: "stopped" }), "It no longer waits: the agent stopped.");
});

test("narrow: the labels as tabs, one item at a time, the dots, and a swipe to the next", () => {
	const v = Pr.forCall(records([record([version(1, "c1")])]), "c1", null);
	const handlers = ui({ narrow: true, shown: 1 });
	const card = Pr.card(document, v, handlers);
	assert.equal(byClass(card, "pa-grid").length, 0);
	const tabs = elements(one(card, "pa-tabs")).filter((e) => e.localName === "button");
	assert.deepEqual(tabs.map((tab) => tab.textContent), ["A", "B", "C"]);
	assert.deepEqual(tabs.map((tab) => tab.getAttribute("aria-selected")), ["false", "true", "false"]);
	assert.equal(byClass(card, "pa-frame").length, 1, "one item at a time");
	assert.equal(one(card, "pa-frame").getAttribute("data-presented"), "p2/1/1");
	assert.equal(one(card, "pa-label").textContent, "B");
	assert.equal(elements(card).find((e) => e.localName === "figcaption").textContent, ITEMS[1].caption);
	assert.deepEqual(elements(one(card, "dots")).filter((e) => e.localName === "i").map((dot) => dot.className), ["", "on", ""]);
	fire(tabs[2], "click");
	fire(tabs[1], "click");
	const frame = one(card, "pa-frame");
	fire(frame, "touchstart", { touches: [{ clientX: 300, clientY: 100 }] });
	fire(frame, "touchend", { changedTouches: [{ clientX: 180, clientY: 110 }] });
	fire(frame, "touchstart", { touches: [{ clientX: 100, clientY: 100 }] });
	fire(frame, "touchend", { changedTouches: [{ clientX: 220, clientY: 104 }] });
	// A scroll down the page is not a swipe.
	fire(frame, "touchstart", { touches: [{ clientX: 100, clientY: 100 }] });
	fire(frame, "touchend", { changedTouches: [{ clientX: 150, clientY: 300 }] });
	assert.deepEqual(handlers.asked, [["select", 2], ["select", 2], ["select", 0]]);
	// At the ends a swipe goes nowhere.
	const last = ui({ narrow: true, shown: 2 });
	const end = one(Pr.card(document, v, last), "pa-frame");
	fire(end, "touchstart", { touches: [{ clientX: 300, clientY: 100 }] });
	fire(end, "touchend", { changedTouches: [{ clientX: 100, clientY: 100 }] });
	assert.deepEqual(last.asked, []);
	// A shown index out of range is the nearest item.
	assert.equal(one(Pr.card(document, v, ui({ narrow: true, shown: 9 })), "pa-frame").getAttribute("data-presented"), "p2/1/2");
});

test("everything an agent wrote is text: no markup, no link, no address", () => {
	const hostile = '<img src=x onerror="alert(1)">';
	const address = "javascript:alert(document.cookie)";
	const bad = (n) => `${hostile} ${address} ${n}`;
	const items = ["A", "B"].map((label, i) => ({
		...picture(`<b>${label}</b>`, `javascript:alert(${i})/<img onerror=x>.png`, bad("caption")),
	}));
	items[1] = { ...items[1], kind: "page", mimeType: "text/html", snapshot: { state: "drawn", sha256: "d" }, drawn: { blank: false, console: [hostile], blocked: [address] } };
	const question = { ...QUESTION, text: bad("question"), choices: [{ id: "1", label: bad("choice") }, { id: "2", label: address }] };
	const v = Pr.forCall(records([{ id: "p3", versions: [{ ...version(1, "c1"), title: bad("title"), items, question }] }]), "c1", null);
	for (const narrow of [false, true]) {
		const card = Pr.card(document, v, ui({ narrow }));
		const all = elements(card);
		// The only picture is the frame's own, with nothing but its alt and the blob it is given.
		for (const image of all.filter((e) => e.localName === "img")) assert.deepEqual(image.attributes.map((a) => a.name), ["alt"]);
		assert.equal(all.filter((e) => e.localName === "a" || e.localName === "iframe" || e.localName === "script").length, 0);
		for (const e of all) {
			for (const { name } of e.attributes) assert.ok(!/^on|^href$|^src$|^style$/.test(name), `${e.localName} has ${name}`);
		}
		const text = html(card);
		assert.ok(!text.includes("<img src"), "the agent's markup is never markup");
		assert.ok(text.includes("&lt;img") && text.includes("javascript:alert(document.cookie)"), "it is shown as the text it is");
		assert.ok(all.some((e) => e.textContent === `${hostile} ${address} title`));
	}
	// The row's words are text pieces too.
	const row = T.describe({ callId: "c1", name: "present", arguments: { title: hostile } }, "running", null, null);
	assert.deepEqual(row.label.map((piece) => piece.text).join(""), `Presenting ${hostile}…`);
});

test("the row folded under the card: what was presented, and how it went", () => {
	const row = (status, details, args = { title: "Sign-in screen, three layouts" }) => {
		const info = T.describe({ callId: "c1", name: "present", arguments: args }, status, details === undefined ? null : { text: "Presented …", details }, null);
		return info.label.map((piece) => piece.text).join("");
	};
	const d = (extra = {}) => ({ presentation: "p2", ...version(1, "c1"), ...extra });
	assert.equal(row("running", undefined), "Presenting Sign-in screen, three layouts…");
	assert.equal(row("done", d()), "Presented 2 pictures and a page · the page loaded, no errors");
	assert.equal(row("done", d({ version: 2, question: QUESTION })), "Presented version 2 of p2 · waits for your answer");
	assert.equal(row("done", d({ question: { ...QUESTION, answer: { chose: "Use B" } } })), "Presented 2 pictures and a page · you chose “Use B”");
	assert.equal(row("done", d({ items: [ITEMS[0]] })), "Presented 1 picture · 1440×900, 212 KB");
	assert.equal(row("done", d({ items: [ITEMS[0], ITEMS[2]] })), "Presented 2 pictures · 424 KB");
	assert.equal(row("done", d({ items: [page("A", "a.html", "", { state: "pending" }, null)] })), "Presented a page · the page is not drawn yet");
	assert.equal(row("done", d({ items: [page("A", "a.html", "", undefined, { blank: true, console: [], blocked: [] })] })), "Presented a page · the page looks blank");
	assert.equal(row("done", d({ items: [page("A", "a.html", "", undefined, { blank: false, console: ["TypeError"], blocked: ["https://cdn.example"] })] })), "Presented a page · the page loaded: 1 console error, 1 address blocked");
	assert.equal(row("done", d({ items: [page("A", "a.html", "", { state: "failed", reason: "x" }, null), ITEMS[1]] })), "Presented 2 pages · a page could not be drawn");
	// A version it cannot read still names what was presented.
	assert.equal(row("done", { presentation: "p2", items: [{ kind: "video" }] }), "Presented “Sign-in screen, three layouts”");
	assert.equal(row("failed", { message: "No such file" }), "Present “Sign-in screen, three layouts”");
	// Opened, it shows what the agent was told.
	const sections = T.detailFor({ callId: "c1", name: "present", arguments: { title: "x", items: [] } }, "done", { text: "Presented \"x\" as p2, version 1.", details: d() }, null);
	assert.deepEqual(sections.map((s) => [s.kind, s.label, s.text]), [["text", "What the agent was told", 'Presented "x" as p2, version 1.']]);
	assert.deepEqual(T.detailFor({ callId: "c1", name: "present", arguments: {} }, "done", { text: "", details: d() }, null), [], "no chevron while it waits");
});

test("the page's Content-Security-Policy is unchanged, and nothing frames or writes markup", () => {
	const folder = new URL("../transcript/", import.meta.url);
	const index = readFileSync(new URL("index.html", folder), "utf8");
	assert.ok(index.includes(`content="default-src 'none'; script-src 'self'; style-src 'self'; img-src blob:; base-uri 'none'; form-action 'none'"`));
	assert.ok(index.includes('<script defer src="presented.js"></script>'));
	for (const name of readdirSync(folder)) {
		const text = readFileSync(new URL(name, folder), "utf8");
		assert.ok(!/iframe/i.test(text), `${name} has no iframe`);
	}
	const source = readFileSync(new URL("presented.js", folder), "utf8");
	assert.ok(!/innerHTML|outerHTML|insertAdjacentHTML|document\.write/.test(source.replace(/^\s*(\/\/|\*).*$/gm, "")));
});
