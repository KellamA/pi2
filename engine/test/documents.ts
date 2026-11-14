// The Markdown converter of engine/src/documents.ts, and real conversions through macOS's textutil in a throwaway folder.

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { documentHtml, renderInline, renderMarkdown, safeUrl, writeDocument } from "../src/documents.ts";

const md = (source: string, lean = false) => renderMarkdown(source, { lean });

// ---- Blocks

assert.equal(md("# One\n## Two\n###### Six"), "<h1>One</h1>\n<h2>Two</h2>\n<h6>Six</h6>\n");
assert.equal(md("Title\n=====\n\nSub\n---"), "<h1>Title</h1>\n<h2>Sub</h2>\n");
assert.equal(md("## Closed ##"), "<h2>Closed</h2>\n");
assert.equal(md("#hashtag"), "<p>#hashtag</p>\n", "a # with no space is text");
assert.equal(md("First line\nsecond line\n\nNext"), "<p>First line\nsecond line</p>\n<p>Next</p>\n");
assert.equal(md("one  \ntwo\\\nthree"), "<p>one<br>two<br>three</p>\n", "two spaces or a backslash make a line break");
assert.equal(md("a\n\n---\n\nb"), "<p>a</p>\n<hr>\n<p>b</p>\n");
assert.equal(md("* * *"), "<hr>\n");
assert.equal(md("\r\nwindows\r\nlines\r\n"), "<p>windows\nlines</p>\n");

// Code
assert.equal(md("```ts\nconst a = 1 < 2;\n  indented\n```"), "<pre><code>const a = 1 &lt; 2;\n  indented</code></pre>\n");
assert.equal(md("~~~\n<b>x</b>\n~~~"), "<pre><code>&lt;b&gt;x&lt;/b&gt;</code></pre>\n");
assert.equal(md("````\n```\ninner\n```\n````"), "<pre><code>```\ninner\n```</code></pre>\n", "a longer fence holds a shorter one");
assert.equal(md("```\nnever closed\n# not a heading"), "<pre><code>never closed\n# not a heading</code></pre>\n");
assert.equal(md("```\n**not bold**\n```"), "<pre><code>**not bold**</code></pre>\n", "nothing inside a code block is Markdown");
assert.equal(renderInline("use `a < b` and ``x ` y``"), "use <code>a &lt; b</code> and <code>x ` y</code>");
assert.equal(renderInline("a ` lone tick"), "a ` lone tick");

// Emphasis
assert.equal(renderInline("**bold** *it* _it_ __bold__ ***both*** ~~gone~~"), "<strong>bold</strong> <em>it</em> <em>it</em> <strong>bold</strong> <em><strong>both</strong></em> <del>gone</del>");
assert.equal(renderInline("snake_case_name and 2*3*4"), "snake_case_name and 2<em>3</em>4");
assert.equal(renderInline("**bold with *nested* inside**"), "<strong>bold with <em>nested</em> inside</strong>");
assert.equal(renderInline("a * b * c and ** loose **"), "a * b * c and ** loose **");
assert.equal(renderInline("~single~ tilde and ~~~three~~~"), "~single~ tilde and ~~~three~~~");
assert.equal(renderInline("\\*not\\* emphasis \\# \\\\"), "*not* emphasis # \\");
assert.equal(renderInline("**unclosed"), "**unclosed");

// Lists
assert.equal(md("- one\n- two"), "<ul><li>one</li><li>two</li></ul>\n");
assert.equal(md("1. one\n2. two"), "<ol><li>one</li><li>two</li></ol>\n");
assert.equal(md("3. three\n4. four"), '<ol start="3"><li>three</li><li>four</li></ol>\n');
assert.equal(md("- a\n  - b\n    - c\n- d"), "<ul><li>a<ul><li>b<ul><li>c</li></ul></li></ul></li><li>d</li></ul>\n");
assert.equal(md("1. a\n   1. b\n   2. c\n2. d"), "<ol><li>a<ol><li>b</li><li>c</li></ol></li><li>d</li></ol>\n");
assert.equal(md("1. a\n  - b (indented two)\n2. c"), "<ol><li>a<ul><li>b (indented two)</li></ul></li><li>c</li></ol>\n", "a nested list indented less than the text above is still nested");
assert.equal(md("- a\n\n- b"), "<ul><li>a</li><li>b</li></ul>\n", "blank lines between items do not split a list");
assert.equal(md("- a\ncontinued\n- b"), "<ul><li>a\ncontinued</li><li>b</li></ul>\n", "a lazy continuation line stays in its item");
assert.equal(md("- a\n\n  second paragraph\n- b"), "<ul><li>a<p>second paragraph</p></li><li>b</li></ul>\n");
assert.equal(md("- a\n+ b"), "<ul><li>a</li></ul>\n<ul><li>b</li></ul>\n", "a different bullet starts a new list");
assert.equal(md("- [ ] todo\n- [x] done\n- [X] also"), "<ul><li>☐ todo</li><li>☑ done</li><li>☑ also</li></ul>\n");
assert.equal(md("Text\n- starts a list"), "<p>Text</p>\n<ul><li>starts a list</li></ul>\n");
assert.equal(md("- ```\n  code in item\n  ```"), "<ul><li><pre><code>code in item</code></pre></li></ul>\n");
assert.equal(md("-\n- empty first"), "<ul><li></li><li>empty first</li></ul>\n");

// Quotes
assert.equal(md("> quoted\n> more"), "<blockquote><p>quoted\nmore</p>\n</blockquote>\n");
assert.equal(md("> a\n>\n> > nested"), "<blockquote><p>a</p>\n<blockquote><p>nested</p>\n</blockquote>\n</blockquote>\n");
assert.equal(md("> - item\n> - item two"), "<blockquote><ul><li>item</li><li>item two</li></ul>\n</blockquote>\n");
assert.equal(md("> lazy\ncontinuation"), "<blockquote><p>lazy\ncontinuation</p>\n</blockquote>\n");

// Tables
const table = md("| Name | Qty | Price |\n|:--|--:|:-:|\n| Apple | 3 | 1.50 |\n| Pear \\| green | 12 |");
assert.ok(table.startsWith('<table border="1" cellspacing="0" cellpadding="6"><thead><tr><th style="text-align:left">Name</th><th style="text-align:right">Qty</th><th style="text-align:center">Price</th></tr></thead>'), table);
assert.ok(table.includes("<td>Pear | green</td>".replace("<td>", '<td style="text-align:left">')), "an escaped pipe is a pipe in the cell");
assert.ok(table.includes('<td style="text-align:center"></td>'), "a short row is filled out");
assert.ok(md("A | B\n--|--\n1 | 2").startsWith("<table"), "a table needs no outer pipes");
assert.equal(md("a | b\nnot a delimiter"), "<p>a | b\nnot a delimiter</p>\n");
assert.equal(md("| a |\n|---|\n| **b** |"), md("| a |\n|---|\n| **b** |"));
assert.ok(md("| a |\n|---|\n| **b** |").includes("<td><strong>b</strong></td>"), "cells hold inline Markdown");
const grid = md("| Name | Qty |\n|:--|--:|\n| Apple | 3 |\n| Pear & co | 12 |", true);
assert.equal(grid, "<pre> Name      | Qty\n-----------+-----\n Apple     |   3\n Pear &amp; co |  12</pre>\n".replace(" Pear &amp; co |", " Pear &amp; co |"), grid);

// Links
assert.equal(renderInline('[site](https://example.com "A title")'), '<a href="https://example.com" title="A title">site</a>');
assert.equal(renderInline("[mail](mailto:a@b.co) <https://example.com/x> <me@example.com>"), '<a href="mailto:a@b.co">mail</a> <a href="https://example.com/x">https://example.com/x</a> <a href="mailto:me@example.com">me@example.com</a>');
assert.equal(renderInline("See https://example.com/a_(b). Next"), 'See <a href="https://example.com/a_(b)">https://example.com/a_(b)</a>. Next');
assert.equal(renderInline("(https://example.com/x)"), '(<a href="https://example.com/x">https://example.com/x</a>)');
assert.equal(renderInline("[**bold** link](http://example.com/a?b=1&c=2)"), '<a href="http://example.com/a?b=1&amp;c=2"><strong>bold</strong> link</a>');
assert.equal(renderInline("[a [b] c](https://example.com)"), '<a href="https://example.com">a [b] c</a>');
assert.equal(renderInline("[not a link] (https://example.com)"), "[not a link] (<a href=\"https://example.com\">https://example.com</a>)");
assert.equal(renderInline("![a cat](https://example.com/cat.png)"), "<em>a cat</em>", "a picture is not fetched or embedded; its description stays");
assert.equal(safeUrl("https://example.com"), "https://example.com");
assert.equal(safeUrl("HTTP://EXAMPLE.COM/x"), "HTTP://EXAMPLE.COM/x");
for (const bad of ["javascript:alert(1)", " JaVaScRiPt:alert(1)", "java\tscript:alert(1)", "data:text/html,<script>1</script>", "vbscript:x", "file:///etc/passwd", "//evil.example/x", "/relative", "#anchor", "https://", "https:// spaced.example", "mailto:", "ftp://example.com", "https://a.example/\u0000"]) {
	assert.equal(safeUrl(bad), undefined, bad);
}
// Link text with the address in word files: Word cannot keep the address.
assert.equal(renderInline("[site](https://example.com)", 0, { lean: true }), "site (https://example.com)");
assert.equal(renderInline("<https://example.com>", 0, { lean: true }), "https://example.com");
assert.equal(renderInline("[mail me](mailto:a@b.co)", 0, { lean: true }), "mail me (mailto:a@b.co)");

// ---- Hostile input: nothing becomes markup

const ALLOWED_TAGS = new Set(["p", "h1", "h2", "h3", "h4", "h5", "h6", "strong", "em", "del", "code", "pre", "ul", "ol", "li", "a", "table", "thead", "tbody", "tr", "th", "td", "blockquote", "hr", "br"]);
const ALLOWED_ATTRIBUTES = new Set(["href", "title", "style", "start", "border", "cellspacing", "cellpadding"]);

/** Throws unless the body holds only the tags and attributes the converter writes, with every value quoted and escaped. */
function assertOnlyOurMarkup(html: string): void {
	const body = html.slice(html.indexOf("<body>") + 6, html.lastIndexOf("</body>"));
	const left = body.replace(/<(\/?)([a-z0-9]+)((?:\s+[a-z-]+="[^"<>]*")*)\s*>/g, (_whole, _close, tag: string, attributes: string) => {
		assert.ok(ALLOWED_TAGS.has(tag), `tag <${tag}> is not one the converter writes`);
		for (const [, name, value] of attributes.matchAll(/\s([a-z-]+)="([^"]*)"/g)) {
			assert.ok(ALLOWED_ATTRIBUTES.has(name!), `attribute ${name} is not one the converter writes`);
			if (name === "href") assert.match(value!, /^(?:https?:\/\/|mailto:)[^\s"<>]*$/i, "an unsafe address in href");
			if (name === "style") assert.match(value!, /^text-align:(?:left|right|center)$/, "style is only ever an alignment");
			assert.doesNotMatch(value!, /[<>]|&(?!amp;|lt;|gt;|quot;|#39;)/, `attribute value ${value} is not escaped`);
		}
		return "";
	});
	assert.doesNotMatch(left, /[<>]/, `raw angle brackets left in the text: ${left.slice(0, 120)}`);
}

const hostile = [
	"<script>alert(1)</script>",
	"# <script>alert(1)</script>",
	"<img src=x onerror=alert(1)>",
	"<iframe src='https://evil.example'></iframe>",
	"<a href=\"javascript:alert(1)\">x</a>",
	"[x](javascript:alert(1))",
	"[x](JAVASCRIPT:alert(1))",
	"[x](&#106;avascript:alert(1))",
	"[x](java\nscript:alert(1))",
	"[x](data:text/html;base64,PHNjcmlwdD4=)",
	'[x](https://a.example/ "t\\" onmouseover=\\"alert(1)")',
	'[x](https://a.example/ "t" onmouseover="alert(1)")',
	'[x](https://a.example/"onmouseover="alert(1))',
	"[x](<https://a.example/\"><script>alert(1)</script>>)",
	"[\"><script>alert(1)</script>](https://a.example)",
	"![x](https://evil.example/pixel.gif)",
	"![<script>alert(1)</script>](https://evil.example/p.gif)",
	"<https://a.example/\"onclick=\"alert(1)>",
	"| <script> | b |\n|---|---|\n| <img src=x onerror=1> | `<b>` |",
	"- <script>alert(1)</script>\n  - [ ] <b>bold?</b>",
	"> <iframe>\n> </iframe>",
	"```\n</code></pre><script>alert(1)</script>\n```",
	"`</code><script>alert(1)</script>`",
	"<!-- comment --> <style>body{display:none}</style>",
	"<![CDATA[ x ]]> <?php echo 1 ?> &lt;script&gt; &#60;script&#62;",
	"**<b onmouseover=alert(1)>x</b>**",
	"https://a.example/<script>alert(1)</script>",
	"a\u0000b<\u0000script>",
];
for (const source of hostile) {
	for (const lean of [false, true]) assertOnlyOurMarkup(documentHtml(source, '<script>alert("title")</script>', { lean }));
}
assert.ok(!md("<script>alert(1)</script>").includes("<script"), "raw HTML is shown as text");
assert.equal(md("<script>alert(1)</script>"), "<p>&lt;script&gt;alert(1)&lt;/script&gt;</p>\n");
assert.equal(md("[x](javascript:alert(1))"), "<p>x</p>\n", "a link that is not allowed keeps its words and loses its address");
assert.ok(md('[x](https://a.example/ "t\\" onmouseover=\\"alert(1)")').includes('title="t&quot; onmouseover=&quot;alert(1)"'), "a quote in a title cannot end the attribute");
assert.ok(md('[x](https://a.example/"onmouseover="alert(1))').includes('href="https://a.example/&quot;onmouseover=&quot;alert(1)"'), "a quote in an address cannot end the attribute");
assert.ok(documentHtml("x", '"></title><script>alert(1)</script>').includes("<title>&quot;&gt;&lt;/title&gt;&lt;script&gt;alert(1)&lt;/script&gt;</title>"), "the title is escaped too");
// Whatever the input, the output stays well-formed and the converter stays fast: deep nesting and long runs of marks.
for (const source of ["> ".repeat(500) + "deep", "- ".repeat(200) + "deep", "*".repeat(5000), "[".repeat(3000), "`".repeat(3000), "a_".repeat(5000), "[a](".repeat(1000), "| a ".repeat(500) + "\n" + "|--".repeat(500)]) {
	const started = Date.now();
	assertOnlyOurMarkup(documentHtml(source));
	assert.ok(Date.now() - started < 3000, `slow on ${source.slice(0, 20)}`);
}

// ---- A document

const page = documentHtml("# Report\n\nBody", "Report");
assert.ok(page.startsWith("<!DOCTYPE html>") && page.includes('<meta charset="utf-8">') && page.includes("<title>Report</title>"));
assert.ok(page.includes('font-family: Arial') && page.includes('"Courier New"') && page.includes("font-size: 11pt"), "sensible fonts and size");
assert.equal((page.match(/<h1>/g) ?? []).length, 1, "a title the text already opens with is not added twice");
assert.ok(documentHtml("Just text", "Added Title").includes("<h1>Added Title</h1>\n<p>Just text</p>"), "a title the text does not open with is added as a heading");
assert.ok(!documentHtml("Just text").includes("<h1>"));

// ---- Writing files, through the real textutil

const textutil = (...args: string[]) => execFileSync("/usr/bin/textutil", args, { encoding: "utf8", maxBuffer: 16 * 1024 * 1024 });
const root = realpathSync(mkdtempSync(join(tmpdir(), "pi2-documents-")));
const outside = realpathSync(mkdtempSync(join(tmpdir(), "pi2-documents-outside-")));
// Removed however the test ends: a failed check ends the process, and "exit" still runs.
process.on("exit", () => {
	rmSync(root, { recursive: true, force: true });
	rmSync(outside, { recursive: true, force: true });
});
const before = readdirSync(tmpdir()).filter((name) => name.startsWith("pi2-document-")).length;

const REPORT = `# Quarterly report

Intro with **bold**, *italic*, ~~gone~~, \`inline_code\` and a [link](https://example.com/page).

## Lists

- apple
  - nested pear
- plum
1. first step
2. second step
- [ ] open task
- [x] finished task

### Code

\`\`\`
let total = 1 < 2;
\`\`\`

| Item | Count |
|:-----|------:|
| Apples | 3 |
| Pears | 12 |

> A wise quotation.

---

Closing words.`;

for (const extension of ["docx", "rtf", "odt", "html"]) {
	const written = await writeDocument(root, { path: `report.${extension}`, markdown: REPORT, title: "Q3 Report" });
	assert.equal(written.isError, undefined, `${extension}: ${written.text}`);
	assert.match(written.text, new RegExp(`^Wrote report\\.${extension} \\(`));
	const bytes = readFileSync(join(root, `report.${extension}`));
	if (extension === "docx" || extension === "odt") assert.equal(bytes.subarray(0, 2).toString(), "PK", `${extension} is a zip container`);
	if (extension === "rtf") assert.ok(bytes.subarray(0, 5).toString() === "{\\rtf", "rtf starts like rtf");
	if (extension === "html") assert.ok(bytes.toString().startsWith("<!DOCTYPE html>"));

	// Read it back as text: what the person would see, whichever program opens it.
	const plain = textutil("-convert", "txt", "-stdout", join(root, `report.${extension}`));
	for (const wanted of ["Quarterly report", "Intro with bold, italic, gone, inline_code and a link", "Lists", "apple", "nested pear", "first step", "second step", "open task", "finished task", "let total = 1 < 2;", "Apples", "Pears", "A wise quotation.", "Closing words."]) {
		assert.ok(plain.includes(wanted), `${extension}: "${wanted}" missing from:\n${plain}`);
	}
	assert.ok(!plain.includes("<") || extension === "html" || plain.includes("1 < 2"), `${extension}: no markup in the text`);
	assert.ok(!plain.includes("**") && !plain.includes("```") && !plain.includes("[link]"), `${extension}: no Markdown marks left`);
}

// What survives, read back as HTML: formatting is real formatting, not characters.
const back = (name: string) => textutil("-convert", "html", "-stdout", join(root, name));
for (const extension of ["docx", "rtf", "odt"]) {
	const html = back(`report.${extension}`);
	assert.match(html, /<b>bold<\/b>/, `${extension}: bold`);
	assert.match(html, /<i>italic<\/i>/, `${extension}: italic`);
	assert.match(html, /line-through/, `${extension}: strikethrough`);
	assert.match(html, /Courier New|Courier/, `${extension}: a monospace face for code`);
	assert.match(html, /Arial/, `${extension}: the body face`);
}
for (const extension of ["rtf", "odt"]) {
	const html = back(`report.${extension}`);
	assert.match(html, /<table/, `${extension}: a real table`);
	assert.equal((html.match(/<td /g) ?? []).length, 6, `${extension}: six cells`);
}
{
	const html = back("report.docx");
	assert.doesNotMatch(html, /<table/, "docx: textutil's Word writer keeps no tables, so the document carries a text grid instead");
	const plain = textutil("-convert", "txt", "-stdout", join(root, "report.docx"));
	assert.match(plain, / Item\s+\| Count\n-+\+-+\n Apples\s+\|\s+3\n Pears\s+\|\s+12/, plain);
	assert.match(plain, /link \(https:\/\/example\.com\/page\)/, "docx: the link's address is written out");
	assert.match(written(await writeDocument(root, { path: "link.docx", markdown: "x" })), /Tables are written as aligned text/, "the model is told what Word files cannot hold");
}
{
	const rtf = readFileSync(join(root, "report.rtf"), "latin1");
	assert.match(rtf, /HYPERLINK "https:\/\/example\.com\/page"/, "rtf keeps the link");
	assert.match(textutil("-convert", "html", "-stdout", join(root, "report.odt")), /example\.com\/page/, "odt keeps the link");
}
// The title is the document's title.
assert.match(execFileSync("/usr/bin/unzip", ["-p", join(root, "report.docx"), "docProps/core.xml"], { encoding: "utf8" }), /<dc:title>Q3 Report<\/dc:title>/);
assert.match(execFileSync("/usr/bin/unzip", ["-p", join(root, "report.odt"), "meta.xml"], { encoding: "utf8" }), /<dc:title>Q3 Report<\/dc:title>/);

function written(result: { text: string; isError?: boolean }): string {
	assert.equal(result.isError, undefined, result.text);
	return result.text;
}

// Capital letters in the ending, nested folders that do not exist yet, a name with spaces and non-ASCII text.
written(await writeDocument(root, { path: "out/2026/Plan Ü.DOCX", markdown: "# Plan Ü\n\nCafé — naïve, 日本語, 🙂." }));
assert.ok(existsSync(join(root, "out", "2026", "Plan Ü.DOCX")));
{
	const plain = textutil("-convert", "txt", "-stdout", join(root, "out", "2026", "Plan Ü.DOCX"));
	assert.ok(plain.includes("Café — naïve, 日本語, 🙂."), plain);
}
written(await writeDocument(root, { path: join(root, "absolute.html"), markdown: "inside, given in full" }));
assert.ok(existsSync(join(root, "absolute.html")));

// ---- Refusals, each with what to change, and nothing written

const refused = async (args: Parameters<typeof writeDocument>[1], pattern: RegExp, convert?: Parameters<typeof writeDocument>[2]) => {
	const result = await writeDocument(root, args, convert);
	assert.equal(result.isError, true, `expected a refusal of ${args.path}`);
	assert.match(result.text, pattern);
	assert.match(result.text, /Nothing was written\.$/);
};
await refused({ path: "x.txt", markdown: "x" }, /\.docx \(Word\), \.rtf, \.odt \(OpenDocument\) and \.html.*"\.txt"/);
await refused({ path: "noending", markdown: "x" }, /\.docx.*"noending"/);
await refused({ path: "x.pdf", markdown: "x" }, /PDF is not offered.*\.docx/);
await refused({ path: "x.PDF", markdown: "x" }, /PDF is not offered/);
await refused({ path: "x.doc", markdown: "x" }, /not one of them/);
await refused({ path: "report.docx", markdown: "again" }, /report\.docx already exists.*overwrite: true/);
await refused({ path: "empty.docx", markdown: "  \n " }, /markdown is empty/);
await refused({ path: " ", markdown: "x" }, /\.docx.*not one of them|path is empty/);
await refused({ path: ".docx", markdown: "x" }, /not one of them|empty/);
await refused({ path: "../escape.docx", markdown: "x" }, /outside this conversation's folder/);
await refused({ path: join(outside, "escape.docx"), markdown: "x" }, /outside this conversation's folder/);
await refused({ path: "a/../../escape.html", markdown: "x" }, /outside this conversation's folder/);
await refused({ path: "big.docx", markdown: "x".repeat(2_000_001) }, /most allowed/);
await refused({ path: "out", markdown: "x" }, /not one of them/);
mkdirSync(join(root, "folder.docx"));
await refused({ path: "folder.docx", markdown: "x", overwrite: true }, /is a folder/);
symlinkSync(outside, join(root, "link-out"));
await refused({ path: "link-out/escape.docx", markdown: "x" }, /outside this conversation's folder/);
await refused({ path: "link-out/new/escape.html", markdown: "x" }, /outside this conversation's folder/);
writeFileSync(join(outside, "target.html"), "keep me");
symlinkSync(join(outside, "target.html"), join(root, "link-file.html"));
await refused({ path: "link-file.html", markdown: "x", overwrite: true }, /link or special file/);
assert.equal(readFileSync(join(outside, "target.html"), "utf8"), "keep me", "a link is never written through");
assert.deepEqual(readdirSync(outside).sort(), ["target.html"], "nothing was written outside the folder");
await refused({ path: "slow.docx", markdown: "x" }, /could not be written: textutil took too long/, async () => {
	throw new Error("textutil took too long and was stopped");
});
assert.ok(!existsSync(join(root, "slow.docx")), "a failed conversion leaves no file");

// overwrite: true replaces, and only then
written(await writeDocument(root, { path: "replace.html", markdown: "first" }));
written(await writeDocument(root, { path: "replace.html", markdown: "second", overwrite: true }));
assert.ok(readFileSync(join(root, "replace.html"), "utf8").includes("<p>second</p>"));
written(await writeDocument(root, { path: "replace.docx", markdown: "first draft" }));
written(await writeDocument(root, { path: "replace.docx", markdown: "second draft", overwrite: true }));
assert.ok(textutil("-convert", "txt", "-stdout", join(root, "replace.docx")).includes("second draft"));

// Nothing is left behind in the temporary folder, and a title that looks like an option is only a title.
assert.equal(readdirSync(tmpdir()).filter((name) => name.startsWith("pi2-document-")).length, before, "working folders are removed");
written(await writeDocument(root, { path: "dash.docx", markdown: "text", title: "--help -output /tmp/x" }));
assert.ok(existsSync(join(root, "dash.docx")));

console.log("documents: ok");
