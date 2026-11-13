import assert from "node:assert/strict";
import { test } from "node:test";
import md from "../transcript/markdown.js";
import { document, html } from "./fakedom.mjs";

const render = (source) => html(md.render(document, source));

/** Every element and attribute the renderer may make; anything else came from the input. */
const TAGS = new Set(["p", "h1", "h2", "h3", "h4", "h5", "h6", "em", "strong", "del", "code", "pre", "a", "br", "hr", "ul", "ol", "li", "input", "span", "blockquote", "div", "table", "thead", "tbody", "tr", "th", "td", "button"]);
const ATTRIBUTES = new Set(["class", "href", "title", "start", "type", "disabled", "checked", "aria-label", "data-nocopy", "data-action"]);

function audit(node, found = { tags: new Set(), attributes: new Set(), hrefs: [] }) {
	for (const child of node.childNodes) {
		if (child.nodeType !== 1) continue;
		found.tags.add(child.localName);
		for (const { name, value } of child.attributes) {
			found.attributes.add(name);
			if (name === "href") found.hrefs.push(value);
		}
		audit(child, found);
	}
	return found;
}

function assertSafe(source) {
	const found = audit(md.render(document, source));
	for (const tag of found.tags) assert.ok(TAGS.has(tag), `unexpected <${tag}> from ${JSON.stringify(source)}`);
	for (const name of found.attributes) assert.ok(ATTRIBUTES.has(name), `unexpected attribute ${name} from ${JSON.stringify(source)}`);
	for (const href of found.hrefs) assert.match(href, /^(https?:\/\/[^\s]+|mailto:[^\s]+)$/i, `unsafe href ${href}`);
	return found;
}

// MARK: Blocks

test("headings, paragraphs and rules", () => {
	assert.equal(render("# One\n## Two\n###### Six\n#hashtag"), "<h1>One</h1><h2>Two</h2><h6>Six</h6><p>#hashtag</p>");
	assert.equal(render("# Closed ##"), "<h1>Closed</h1>");
	assert.equal(render("Title\n===\n\nSub\n---"), "<h1>Title</h1><h2>Sub</h2>");
	assert.equal(render("a\n\n***\n\n- - -\n\n___"), "<p>a</p><hr><hr><hr>");
});

test("single line breaks are kept, as the app always kept them", () => {
	assert.equal(render("one\ntwo"), "<p>one<br>two</p>");
	assert.equal(render("hard  \nbreak"), "<p>hard<br>break</p>");
	assert.equal(render("back\\\nslash"), "<p>back<br>slash</p>");
});

test("fenced code keeps its text exactly", () => {
	const code = "```py\ndef f():\n\treturn 1 < 2  # tab and spaces  \n```";
	const tree = md.render(document, code);
	assert.equal(tree.firstChild.getAttribute("class"), "codeblock");
	assert.equal(tree.firstChild.lastChild.textContent, "def f():\n\treturn 1 < 2  # tab and spaces  ");
	assert.match(render(code), /<span class="code-lang">py<\/span>/);
	assert.match(render(code), /<button class="copy-button" type="button" data-action="copy-code" aria-label="Copy py code">Copy<\/button>/);
	assert.equal(md.parse("~~~\n```\n~~~")[0].text, "```");
	assert.equal(md.parse("````\n```\n````")[0].text, "```");
	assert.equal(md.parse("```\n\n\n```")[0].text, "\n");
});

test("an unclosed fence runs to the end, as text still arriving does", () => {
	const blocks = md.parse("Here:\n\n```js\nconst a = 1;\nconst b");
	assert.equal(blocks.length, 2);
	assert.deepEqual(blocks[1], { type: "code", lang: "js", text: "const a = 1;\nconst b", closed: false });
});

test("indented code", () => {
	assert.equal(md.parse("text\n\n    code\n      more\n\nafter")[1].text, "code\n  more");
	// Indented lines inside a paragraph are just more of the paragraph.
	assert.equal(render("text\n    still text"), "<p>text<br>still text</p>");
});

test("lists: nested, ordered with a start, loose and tight", () => {
	assert.equal(
		render("- a\n- b\n  - c\n    - d\n- e"),
		'<ul><li><span class="li-text">a</span></li><li><span class="li-text">b</span><ul><li><span class="li-text">c</span><ul><li><span class="li-text">d</span></li></ul></li></ul></li><li><span class="li-text">e</span></li></ul>',
	);
	assert.equal(render("3. three\n4. four"), '<ol start="3"><li><span class="li-text">three</span></li><li><span class="li-text">four</span></li></ol>');
	assert.equal(render("- a\n\n- b"), "<ul><li><p>a</p></li><li><p>b</p></li></ul>");
	assert.equal(render("* star\n+ plus"), '<ul><li><span class="li-text">star</span></li></ul><ul><li><span class="li-text">plus</span></li></ul>');
	assert.equal(render("1) paren"), '<ol><li><span class="li-text">paren</span></li></ol>');
});

test("lists nest the way models write them, even short of the text column", () => {
	const blocks = md.parse("1. **Foo**\n  - bar\n  - baz\n2. Qux");
	assert.equal(blocks.length, 1);
	assert.equal(blocks[0].items.length, 2);
	assert.equal(blocks[0].items[0].children[1].type, "list");
	assert.equal(blocks[0].items[0].children[1].items.length, 2);
	const deeper = md.parse("1. a\n   - b\n     1. c\n2. d");
	assert.equal(deeper[0].items[0].children[1].items[0].children[1].type, "list");
});

test("a list item carries code, quotes and lazy lines", () => {
	const blocks = md.parse("- item\n  ```\n  code\n  ```\n- quoted\n  > q\n- lazy\ncontinued");
	assert.equal(blocks[0].items[0].children[1].type, "code");
	assert.equal(blocks[0].items[0].children[1].text, "code");
	assert.equal(blocks[0].items[1].children[1].type, "quote");
	assert.equal(blocks[0].items[2].children[0].text, "lazy\ncontinued");
});

test("a paragraph is interrupted by a list but not by a number that is not 1", () => {
	assert.deepEqual(md.parse("Steps:\n- one").map((b) => b.type), ["paragraph", "list"]);
	assert.deepEqual(md.parse("In\n2019. a year").map((b) => b.type), ["paragraph"]);
	assert.deepEqual(md.parse("Steps:\n1. one").map((b) => b.type), ["paragraph", "list"]);
});

test("task lists", () => {
	assert.equal(
		render("- [ ] todo\n- [x] done\n- [X] Done too\n- [] not a task"),
		'<ul class="tasks"><li class="task"><input type="checkbox" disabled="" aria-label="Not done"><span class="li-text">todo</span></li>' +
			'<li class="task"><input type="checkbox" disabled="" checked="" aria-label="Done"><span class="li-text">done</span></li>' +
			'<li class="task"><input type="checkbox" disabled="" checked="" aria-label="Done"><span class="li-text">Done too</span></li>' +
			'<li><span class="li-text">[] not a task</span></li></ul>',
	);
});

test("block quotes, nested and lazy", () => {
	assert.equal(render("> a\nlazy\n> > b"), "<blockquote><p>a<br>lazy</p><blockquote><p>b</p></blockquote></blockquote>");
	assert.equal(render("> # Head\n> - item"), '<blockquote><h1>Head</h1><ul><li><span class="li-text">item</span></li></ul></blockquote>');
});

test("tables, with alignment, escaped pipes, short rows and inline formatting", () => {
	assert.equal(
		render("| a | b | c |\n|:--|:-:|--:|\n| 1 | **2** | `x\\|y` |\n| only |"),
		'<div class="table-wrap"><table><thead><tr><th class="align-left">a</th><th class="align-center">b</th><th class="align-right">c</th></tr></thead>' +
			'<tbody><tr><td class="align-left">1</td><td class="align-center"><strong>2</strong></td><td class="align-right"><code>x|y</code></td></tr>' +
			'<tr><td class="align-left">only</td><td class="align-center"></td><td class="align-right"></td></tr></tbody></table></div>',
	);
	assert.equal(md.parse("a | b\n--|--\n1 | 2")[0].type, "table");
	assert.deepEqual(md.parse("Intro\n| a |\n|---|\n| 1 |").map((b) => b.type), ["paragraph", "table"]);
	// A delimiter row that does not match the header is not a table.
	assert.deepEqual(md.parse("| a | b |\n|---|").map((b) => b.type), ["paragraph"]);
	// A table ends at a blank line or a line without a pipe.
	assert.deepEqual(md.parse("| a |\n|---|\n| 1 |\nafter").map((b) => b.type), ["table", "paragraph"]);
});

test("a table still arriving reads as text until its delimiter row is whole", () => {
	assert.deepEqual(md.parse("| a | b |\n|--").map((b) => b.type), ["paragraph"]);
	assert.deepEqual(md.parse("| a | b |\n|--|--|").map((b) => b.type), ["table"]);
	assert.deepEqual(md.parse("| a | b |\n|--|--|\n| 1").map((b) => b.type), ["table"]);
});

// MARK: Inlines

test("emphasis follows CommonMark's rules", () => {
	assert.equal(render("*a* **b** ***c*** _d_ __e__"), "<p><em>a</em> <strong>b</strong> <em><strong>c</strong></em> <em>d</em> <strong>e</strong></p>");
	assert.equal(render("snake_case_name and 2 * 3 * 4"), "<p>snake_case_name and 2 * 3 * 4</p>");
	assert.equal(render("**bold *nested* bold**"), "<p><strong>bold <em>nested</em> bold</strong></p>");
	assert.equal(render("~~gone~~ but ~5 min and ~~~three~~~"), "<p><del>gone</del> but ~5 min and ~~~three~~~</p>");
	assert.equal(render("*not closed and **also not"), "<p>*not closed and **also not</p>");
	assert.equal(render("**a**b"), "<p><strong>a</strong>b</p>");
});

test("code spans", () => {
	assert.equal(render("`a` `` b`c `` ` d `"), "<p><code>a</code> <code>b`c</code> <code>d</code></p>");
	assert.equal(render("`*not em*` and `unclosed"), "<p><code>*not em*</code> and `unclosed</p>");
});

test("links: inline, auto, bare, with titles and parentheses", () => {
	assert.equal(render('[a](https://x.com "T")'), '<p><a href="https://x.com" title="https://x.com">a</a></p>');
	assert.equal(render("[a](<https://x.com/a b>)"), "<p>a</p>");
	assert.equal(render("[a](https://en.wikipedia.org/wiki/Foo_(bar))"), '<p><a href="https://en.wikipedia.org/wiki/Foo_(bar)" title="https://en.wikipedia.org/wiki/Foo_(bar)">a</a></p>');
	assert.equal(render("<https://x.com/a?b=c>"), '<p><a href="https://x.com/a?b=c" title="https://x.com/a?b=c">https://x.com/a?b=c</a></p>');
	assert.equal(render("<me@example.com>"), '<p><a href="mailto:me@example.com" title="mailto:me@example.com">me@example.com</a></p>');
	assert.equal(render("see https://x.com/a. and (www.y.org)"), '<p>see <a href="https://x.com/a" title="https://x.com/a">https://x.com/a</a>. and (<a href="http://www.y.org" title="http://www.y.org">www.y.org</a>)</p>');
	assert.equal(render("[**bold** link](https://x.com)"), '<p><a href="https://x.com" title="https://x.com"><strong>bold</strong> link</a></p>');
	// No link inside a link, even a bare address in the text.
	assert.equal(render("[https://a.com](https://b.com)"), '<p><a href="https://b.com" title="https://b.com">https://a.com</a></p>');
	assert.equal(render("[not a link] and [x]"), "<p>[not a link] and [x]</p>");
});

test("pictures are never loaded; a web picture becomes a link to it", () => {
	assert.equal(render("![chart](https://x.com/c.png)"), '<p><a class="image-link" href="https://x.com/c.png" title="https://x.com/c.png">chart</a></p>');
	assert.equal(render("![alt](data:image/png;base64,AAAA) ![b](javascript:x)"), "<p>alt b</p>");
});

test("entities and escapes", () => {
	assert.equal(render("&lt;b&gt; &amp; &#65; &#x42; &copy; &bogus; &#0;"), "<p>&lt;b&gt; &amp; A B © &amp;bogus; \uFFFD</p>");
	assert.equal(render("\\*not em\\* \\# \\[x\\](y) \\a"), "<p>*not em* # [x](y) \\a</p>");
});

// MARK: Safety

test("raw HTML is shown as text, never made", () => {
	const hostile = [
		"<script>alert(1)</script>",
		'<img src=x onerror="alert(1)">',
		"<div onclick=alert(1)>block</div>\n\npara",
		"<iframe src=https://evil.example></iframe>",
		"<a href=javascript:alert(1)>x</a>",
		"<svg><foreignObject><img src=x onerror=1></foreignObject></svg>",
		"```\n</code></pre><script>1</script>\n```",
		"`</code><script>1</script>`",
		"| <b>x</b> |\n|---|\n| <img src=x onerror=1> |",
		"> <style>*{display:none}</style>",
		"- <form action=https://evil.example><input name=x></form>",
		"<!-- comment --> <![CDATA[x]]> <?php ?>",
	];
	for (const source of hostile) {
		const found = assertSafe(source);
		assert.ok(!found.tags.has("script") && !found.tags.has("img") && !found.tags.has("iframe") && !found.tags.has("form"));
		assert.ok(!render(source).includes("<script"), source);
	}
	assert.equal(render("<b>x</b>"), "<p>&lt;b&gt;x&lt;/b&gt;</p>");
});

test("links go only to http, https and mailto", () => {
	const refused = [
		"javascript:alert(1)", "JAVASCRIPT:alert(1)", " javascript:alert(1)", "java\nscript:alert(1)", "jav&#x61;script:alert(1)",
		"data:text/html,<script>1</script>", "vbscript:msgbox(1)", "file:///etc/passwd", "/relative", "#fragment", "//evil.example/x",
		"https:///nohost", "http:evil.example", "mailto:", "https://exa mple.com", "https://x.com/\u2028y", "x-apple.systempreferences:x",
	];
	for (const url of refused) {
		assert.equal(md.safeURL(url), null, url);
		assertSafe(`[x](${url.replace(/[()]/g, "")})`);
		assertSafe(`<${url}>`);
	}
	for (const url of ["https://example.com", "HTTP://EXAMPLE.COM/A", "https://user@example.com/x", "mailto:a@b.c", "https://x.com/a?b=\"c\"&d=<e>"]) {
		assert.equal(md.safeURL(url), url, url);
	}
	// Tabs and line breaks are dropped as a browser drops them, and what is left is checked.
	assert.equal(md.safeURL("https://x.com/a\nb"), "https://x.com/ab");
	assert.equal(md.safeURL("  https://x.com  "), "https://x.com");
	// The address shows in the tooltip, so where a link goes is never hidden.
	assert.match(render("[innocent](https://evil.example)"), /title="https:\/\/evil.example"/);
	// Attribute values are escaped.
	assert.match(render('<https://x.com/"onmouseover=alert(1)>'), /href="https:\/\/x.com\/&quot;onmouseover=alert\(1\)"/);
});

test("broken and half-arrived Markdown never throws and stays readable", () => {
	const text = "# Title\n\nSome **bold** and a [link](https://example.com/path) and `code`.\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n```js\nconst x = 1;\n```\n\n> quote\n\n1. one\n   - two\n\n~~done~~ ![p](https://x.com/p.png)";
	for (let i = 0; i <= text.length; i++) assertSafe(text.slice(0, i));
	// Until the ")" arrives the address is a bare one, linked as GitHub links it.
	assert.equal(render("[link](https://exa"), '<p>[link](<a href="https://exa" title="https://exa">https://exa</a></p>');
	assert.equal(render("[link](https://exa)"), '<p><a href="https://exa" title="https://exa">link</a></p>');
	assert.equal(render("**bold"), "<p>**bold</p>");
	for (const odd of ["", "\n\n\n", "[", "]", "![", "`", "```", "|", "|-|", "> ", "- ", "1.", "*", "_", "~~", "<", "&", "\\", "\u0000", "\r\n\r\n", "*".repeat(5000), "[".repeat(3000), "`".repeat(3000), "> ".repeat(500) + "x", "- ".repeat(300) + "x"]) {
		assertSafe(odd);
	}
});

test("pathological input stays fast", () => {
	const started = Date.now();
	render("*a ".repeat(4000));
	render("**".repeat(4000));
	render("_".repeat(10000));
	render("[](".repeat(3000));
	render("<".repeat(10000));
	render(("- " + "  ".repeat(40) + "x\n").repeat(200));
	assert.ok(Date.now() - started < 3000, "took " + (Date.now() - started) + " ms");
});

// MARK: Streaming

test("patch replaces only the blocks that changed", () => {
	const box = document.createElement("div");
	md.patch(document, box, "First paragraph.\n\nSecond");
	const [first, second] = box.childNodes;
	md.patch(document, box, "First paragraph.\n\nSecond, longer now.\n\n- a list");
	assert.equal(box.childNodes.length, 3);
	assert.equal(box.childNodes[0], first, "an unchanged block is kept as it is");
	assert.notEqual(box.childNodes[1], second);
	assert.equal(html(box.childNodes[1]), "<p>Second, longer now.</p>");
	md.patch(document, box, "Only one");
	assert.equal(box.innerHTML, "<p>Only one</p>");
});
