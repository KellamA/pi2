import assert from "node:assert/strict";
import { test } from "node:test";
import C from "../transcript/clipboard.js";
import md from "../transcript/markdown.js";
import { document, h, html } from "./fakedom.mjs";

const answer = (source) => h("article", { class: "msg assistant" }, h("div", { class: "md" }, md.render(document, source)));

test("prose keeps its shape", () => {
	const text = C.plainText(answer("# Title\n\nA **bold** [link](https://x.com) and `code`.\n\n- one\n- two\n  1. nested\n  2. again\n\n> quoted\n> lines\n\n---\n\nEnd"));
	assert.equal(text, "Title\n\nA bold link (https://x.com) and code.\n\n- one\n- two\n  1. nested\n  2. again\n\n> quoted\n> lines\n\n---\n\nEnd");
});

test("code copies exactly, without its header", () => {
	const source = "```py\ndef f():\n\treturn  1\n\n\n# end\n```";
	assert.equal(C.plainText(answer(source)), "def f():\n\treturn  1\n\n\n# end");
});

test("ordered lists keep their numbers; task lists their ticks", () => {
	assert.equal(C.plainText(answer("3. a\n4. b")), "3. a\n4. b");
	assert.equal(C.plainText(answer("- [x] done\n- [ ] todo")), "- [x] done\n- [ ] todo");
});

test("tables copy as tab-separated rows", () => {
	assert.equal(C.plainText(answer("| a | b |\n|---|---|\n| 1 | |\n| | 2 |")), "a\tb\n1\t\n\t2");
});

test("a link shows where it goes unless its text already does", () => {
	assert.equal(C.plainText(answer("<https://x.com/a> and www.y.org and <me@x.org>")), "https://x.com/a and www.y.org and me@x.org");
});

function toolRow(open) {
	const row = h(
		"div",
		{ class: "tool done" + (open ? " open" : "") },
		h("div", { class: "row-head" }, h("svg", { "aria-hidden": "true" }), h("span", { class: "tool-label" }, "Ran ", h("code", "npm test")), " ", h("span", { class: "stats" }, "+1"), h("button", { class: "chevron", "data-nocopy": "" }, "Show details")),
		h(
			"div",
			{ class: "row-body", ...(open ? {} : { hidden: "" }) },
			h("div", { class: "detail" }, h("div", { class: "detail-head", "data-nocopy": "" }, h("span", "bash"), h("button", "Copy")), h("pre", { class: "output" }, h("span", h("span", { class: "prompt" }, "$ "), "npm test"), "\nok 1\nok 2")),
		),
	);
	return row;
}

test("a collapsed tool row gives its summary; an open one its content too", () => {
	const turn = (open) => h("article", { class: "msg assistant" }, h("div", { class: "md" }, md.render(document, "Running the tests.")), h("div", { class: "tools" }, toolRow(open), toolRow(false)));
	assert.equal(C.plainText(turn(false)), "Running the tests.\n\nRan npm test +1\nRan npm test +1");
	assert.equal(C.plainText(turn(true)), "Running the tests.\n\nRan npm test +1\n$ npm test\nok 1\nok 2\n\nRan npm test +1");
});

test("controls, hidden parts and marked parts give nothing; data-copy gives its text", () => {
	const tree = h(
		"div",
		h("button", "Allow Once"),
		h("span", { "data-nocopy": "" }, "waits for you"),
		h("span", { "aria-hidden": "true" }, "decoration"),
		h("input", { type: "text", value: "typed" }),
		h("div", { hidden: "" }, "secret"),
		h("button", { class: "thumb", "data-copy": "[Picture: shot.png]" }, h("img", { alt: "x" })),
		h("div", { class: "chip", "data-copy": "[File: notes.txt]" }, "notes.txt 12 KB"),
		h("p", "Kept"),
	);
	assert.equal(C.plainText(tree), "[Picture: shot.png]\n[File: notes.txt]\n\nKept");
});

test("a diff copies with its signs and without its line numbers", () => {
	const pre = h("pre", { class: "output diff" });
	for (const [number, sign, text, last] of [["1", "-", "old", false], ["1", "+", "new", true]]) {
		pre.appendChild(h("span", { class: "dl" }, h("span", { class: "ln", "data-nocopy": "" }, number), h("span", { class: "sg" }, sign), text + (last ? "" : "\n")));
	}
	assert.equal(C.plainText(pre), "-old\n+new");
});

test("messages are separated by blank lines; a selection inside one block is just its text", () => {
	const page = h("main", h("article", { class: "msg user" }, h("div", { class: "bubble" }, "line one\nline two")), answer("Reply."), h("div", { class: "marker" }, h("span", "Context reset")), answer("After."));
	assert.equal(C.plainText(page), "line one\nline two\n\nReply.\n\nContext reset\n\nAfter.");
	assert.equal(C.plainText(document.createTextNode("partial words")), "partial words");
});

test("rich text keeps structure and drops every attribute but a link's address", () => {
	const tree = h("div", { class: "x", onclick: "y" }, h("a", { href: "https://x.com", title: "t", class: "c" }, "x"), h("button", "Copy"), h("span", { "data-copy": "[Picture: p]" }, h("img", { src: "blob:1" })), h("ol", { start: "3", class: "z" }, h("li", "a")));
	const fragment = document.createDocumentFragment();
	fragment.appendChild(tree);
	C.cleanForHTML(fragment, document);
	assert.equal(html(fragment), '<div><a href="https://x.com">x</a>[Picture: p] <ol start="3"><li>a</li></ol></div>');
});
