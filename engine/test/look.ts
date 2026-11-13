// The pure parts of engine/src/look.ts, and its fetching against a server of the test's own. No real website is loaded.

import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, realpathSync, symlinkSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { gzipSync } from "node:zlib";

const server = createServer((request, response) => {
	const url = request.url ?? "/";
	if (url === "/page") {
		response.writeHead(200, { "content-type": "text/html; charset=utf-8" }).end(PAGE);
	} else if (url === "/gz") {
		response.writeHead(200, { "content-type": "text/html", "content-encoding": "gzip" }).end(gzipSync(PAGE));
	} else if (url === "/data.json") {
		response.writeHead(200, { "content-type": "application/json" }).end('{"a":1}');
	} else if (url === "/file.pdf") {
		response.writeHead(200, { "content-type": "application/pdf" }).end("%PDF-1.4");
	} else if (url === "/big") {
		response.writeHead(200, { "content-type": "text/plain" }).end("x".repeat(3 * 1024 * 1024));
	} else if (url === "/long") {
		response.writeHead(200, { "content-type": "text/plain" }).end("y".repeat(50_000));
	} else if (url === "/to-private") {
		response.writeHead(302, { location: "http://10.1.2.3/secret" }).end();
	} else if (url === "/to-loopback-elsewhere") {
		response.writeHead(302, { location: "http://127.0.0.1:1/" }).end();
	} else if (url === "/to-file") {
		response.writeHead(302, { location: "file:///etc/passwd" }).end();
	} else if (url === "/hop") {
		response.writeHead(301, { location: "/page" }).end();
	} else if (url === "/loop") {
		response.writeHead(302, { location: "/loop" }).end();
	} else if (url === "/missing") {
		response.writeHead(404, { "content-type": "text/plain" }).end("no");
	} else if (url.startsWith("/html/")) {
		response.writeHead(200, { "content-type": "text/html" }).end(SEARCH);
	} else response.writeHead(404).end();
});
await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
const base = `http://127.0.0.1:${(server.address() as { port: number }).port}`;
// Test only: the one address web_fetch may reach on this Mac. Read when look.ts is first loaded.
process.env.PI2_TEST_ALLOW_ADDRESS = base.slice("http://".length);

const look = await import("../src/look.ts");
const never = { abortSignal: new AbortController().signal };

const PAGE = `<!doctype html><html><head><title>A &amp; B &mdash; Test</title><style>body{color:red}</style>
<script>var secret = "SCRIPT-TEXT";</script></head>
<body><nav><a href="/home">NAV-HOME</a></nav>
<main><h1>Heading</h1><p>First   paragraph with <a href="/more?x=1&amp;y=2">a link</a> and <b>bold</b> &lt;text&gt; &#65;&#x42;.</p>
<ul><li>one</li><li>two</li></ul><pre>  keep
   this</pre>
<p><a href="#top">skip</a> <a href="javascript:alert(1)">bad</a> <a href="https://example.org/x">https://example.org/x</a><img src="a.png" alt="a cat"></p>
<table><tr><td>c1</td><td>c2</td></tr></table>
${"<p>filler filler filler filler</p>".repeat(10)}
</main><footer>FOOTER-TEXT</footer><!-- COMMENT-TEXT --></body></html>`;

const SEARCH = `<html><body>
<div class="result results_links"><h2 class="result__title"><a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fone%3Fa%3D1&amp;rut=abc">First <b>result</b></a></h2>
<a class="result__snippet" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fone">A <b>snippet</b> about it &amp; more.</a></div>
<div class="result result--ad"><a class="result__a" href="https://duckduckgo.com/y.js?ad_provider=x">An advert</a><a class="result__snippet" href="x">Buy now</a></div>
<div class="result"><a class="result__a" href="https://example.net/two">Second</a><a class="result__snippet" href="x">Two.</a></div>
<div class="result"><a class="result__a" href="ftp://example.net/three">Odd scheme</a></div>
</body></html>`;

// ---- Glob
const matches = (glob: string, path: string) => look.globToRegExp(glob).test(path);
assert.ok(matches("**/*.ts", "a.ts") && matches("**/*.ts", "src/deep/a.ts") && !matches("**/*.ts", "a.tsx"));
assert.ok(matches("*.ts", "src/a.ts"), "no slash: names anywhere");
assert.ok(matches("src/**/test_*.py", "src/test_a.py") && matches("src/**/test_*.py", "src/x/y/test_a.py") && !matches("src/**/test_*.py", "lib/test_a.py"));
assert.ok(matches("src/*.ts", "src/a.ts") && !matches("src/*.ts", "src/x/a.ts"), "* stays within a folder");
assert.ok(matches("a?.md", "ab.md") && !matches("a?.md", "a/.md") && !matches("a?.md", "abc.md"));
assert.ok(matches("**/*.{ts,tsx}", "x/a.tsx") && matches("**/*.{ts,tsx}", "a.ts") && !matches("**/*.{ts,tsx}", "a.js"));
assert.ok(matches("{src,lib}/**", "lib/a/b") && matches("src/{a,b{1,2}}.c", "src/b2.c") && !matches("src/{a,b{1,2}}.c", "src/b3.c"));
assert.ok(matches("./docs/**", "docs/a/b.md") && matches("a.b", "x/a.b") && !matches("a.b", "x/axb"), "dots are literal");
assert.deepEqual(look.expandBraces("x{a,b}y{1,2}"), ["xay1", "xay2", "xby1", "xby2"]);
assert.ok(matches("{oops", "{oops"), "an unclosed brace is a character");

// ---- HTML to text
const read = look.htmlToText(PAGE, "https://site.test/dir/page");
assert.equal(read.title, "A & B — Test");
for (const gone of ["SCRIPT-TEXT", "color:red", "NAV-HOME", "FOOTER-TEXT", "COMMENT-TEXT", "javascript", "#top"]) assert.ok(!read.text.includes(gone), `${gone} is dropped`);
assert.ok(read.text.includes("# Heading"));
assert.ok(read.text.includes("First paragraph with a link (https://site.test/more?x=1&y=2) and bold <text> AB."), read.text);
assert.ok(read.text.includes("- one\n- two"));
assert.ok(read.text.includes("  keep\n   this"), "preformatted text keeps its spaces");
assert.ok(read.text.includes("skip bad https://example.org/x [image: a cat]") && !read.text.includes("https://example.org/x (https"), "a link whose text is its address is not repeated");
assert.ok(read.text.includes("c1 | c2") || read.text.includes("c1  | c2"));
assert.equal(look.htmlToText('<?xml version="1.0"?><!DOCTYPE html><html><body><p>Hi there</p></body></html>', "https://site.test/").text.trim(), "Hi there", "a page's declarations are not text");
assert.ok(!/\n{3}/.test(read.text));
assert.equal(look.htmlToText("<p>a<script>never closed", "https://x.test/").text, "a");
assert.equal(look.htmlToText("<p>1 < 2 &amp;&bogus; x</p>", "https://x.test/").text, "1 < 2 &&bogus; x");

// ---- Search results
const found = look.parseSearchResults(SEARCH);
assert.deepEqual(found, [
	{ title: "First result", url: "https://example.com/one?a=1", snippet: "A snippet about it & more." },
	{ title: "Second", url: "https://example.net/two", snippet: "Two." },
], "adverts and odd schemes are left out, redirects unwrapped");
assert.deepEqual(look.parseSearchResults("<html><body>Please complete the anomaly check</body></html>"), []);

// ---- Address rules
for (const bad of ["file:///etc/passwd", "http://localhost/", "http://127.0.0.1:1/", "http://10.0.0.1/", "http://169.254.169.254/", "http://[::1]/", "ftp://example.com/", "http://u:p@example.com/", "javascript:1"]) {
	assert.ok("refused" in look.vet(bad), `${bad} is refused`);
}
assert.ok("url" in look.vet("https://example.com/") && (look.vet(`${base}/page`) as { testing?: boolean }).testing === true, "only the test address is let through");
for (const private_ of ["127.0.0.1", "10.2.3.4", "192.168.0.9", "169.254.1.1", "::1", "fe80::1", "fd00::1", "::ffff:10.0.0.1"]) assert.ok(look.isPrivateAddress(private_), private_);
for (const open of ["93.184.216.34", "2606:4700::1111"]) assert.ok(!look.isPrivateAddress(open), open);

// A name is judged by what it resolves to, before anything connects.
const sneaky = async () => [{ address: "93.184.216.34", family: 4 }, { address: "10.0.0.5", family: 4 }];
assert.match(((await look.fetchPage("https://rebind.example.com/", never, sneaky)) as { refused: string }).refused, /local network/);
const lost = async () => {
	throw new Error("ENOTFOUND");
};
assert.match(((await look.fetchPage("https://nowhere.example.com/", never, lost)) as { refused: string }).refused, /Could not find/);

// ---- Fetching, against the test's own server
const fetched = async (path: string) => (await look.fetchPage(`${base}${path}`, never)) as { status: number; type: string; body: Buffer; url: string; cut: boolean };
const page = await fetched("/page");
assert.equal(page.status, 200);
const described = look.describePage(page, 0);
assert.match(described.text, /^Title: A & B — Test\nAddress: http:\/\/127\.0\.0\.1:\d+\/page\n\n# Heading/);
assert.match(look.describePage(await fetched("/gz"), 0).text, /# Heading/, "gzip is read");
assert.match(look.describePage(await fetched("/hop"), 0).text, /Address: .*\/page\n/, "a redirect is followed and the final address shown");
assert.equal(look.describePage(await fetched("/data.json"), 0).text, `Address: ${base}/data.json\n\n{"a":1}`);
const pdf = look.describePage(await fetched("/file.pdf"), 0);
assert.ok(pdf.isError && /application\/pdf/.test(pdf.text));
assert.equal(look.describePage(await fetched("/missing"), 0).isError, true);
const big = await fetched("/big");
assert.equal(big.body.length, 2 * 1024 * 1024);
assert.ok(big.cut && /larger than 2\.0 MB/.test(look.describePage(big, 0).text));
const first = look.describePage(await fetched("/long"), 0).text;
assert.match(first, /Characters 0–20000 of 50000\. Pass offset: 20000 to read on\./);
const last = look.describePage(await fetched("/long"), 40_000).text;
assert.match(last, /Characters 40000–50000 of 50000, the end\./);
assert.equal(look.describePage(await fetched("/long"), 60_000).isError, true);
for (const redirect of ["/to-private", "/to-loopback-elsewhere", "/to-file"]) {
	const refused = (await look.fetchPage(`${base}${redirect}`, never)) as { refused?: string };
	assert.ok(refused.refused !== undefined && /redirects to/.test(refused.refused), `${redirect}: ${JSON.stringify(refused)}`);
}
assert.match(((await look.fetchPage(`${base}/loop`, never)) as { refused: string }).refused, /more than 5 times/);
const stop = new AbortController();
stop.abort();
assert.match(((await look.fetchPage(`${base}/page`, { abortSignal: stop.signal })) as { refused: string }).refused, /Stopped/);

// ---- Files: the walk and its limits
const root = realpathSync(mkdtempSync(join(tmpdir(), "pi2-look-")));
mkdirSync(join(root, "src", "deep"), { recursive: true });
mkdirSync(join(root, "node_modules", "pkg"), { recursive: true });
mkdirSync(join(root, ".git"));
for (const name of ["src/a.ts", "src/deep/b.ts", "node_modules/pkg/c.ts", ".git/d.ts", "e.md"]) writeFileSync(join(root, name), `needle ${name}\n`);
const names: string[] = [];
const walked = await look.walk(root, root, never, async (_full, below) => void names.push(below));
assert.deepEqual(names, ["e.md", "src/a.ts", "src/deep/b.ts"], "skipped places stay skipped, in name order");
assert.equal(walked.stopped, undefined);
const capped = await look.walk(root, root, never, async () => {}, { files: 2, ms: 10_000 });
assert.deepEqual(capped, { visited: 2, stopped: "files" });
const timed = await look.walk(root, root, never, async () => {}, { files: 100, ms: -1 });
assert.equal(timed.stopped, "time");
const aborted = await look.walk(root, root, { abortSignal: stop.signal }, async () => {});
assert.equal(aborted.stopped, "cancelled");
symlinkSync(join(tmpdir()), join(root, "escape"));
assert.ok("refused" in (await look.locate(root, "escape")), "a link out of the folder is not followed");
assert.ok("refused" in (await look.locate(root, "../..")), ".. cannot climb out");
assert.ok("real" in (await look.locate(root, "src/deep/..")));
assert.match((await look.findFiles(root, "**/*.ts", undefined, never, { files: 1, ms: 10_000 })).text, /Stopped after looking at 1 files/);
assert.equal(look.clip("a".repeat(1000), 500).length <= look.clip("a".repeat(1000), 500).length && look.clip("a".repeat(1000), 500).length <= 242, true);
assert.ok(look.clip(`${"a".repeat(500)}NEEDLE${"b".repeat(500)}`, 500).includes("NEEDLE"), "a long line is cut around the match");

server.close();
console.log("look: ok");
