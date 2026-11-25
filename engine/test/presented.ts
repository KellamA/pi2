// Presenting (#946, docs/design/presenting.md): the engine's piece. First without an engine: what the tool refuses
// before anything is read, each limit at its edge, reading a file once and never through a link, a page's folder, the
// pictures' sizes, `present.drawn`'s bounds, the record's lookups and what a phone is handed (`presented.picture` with a
// device's session, against a stand-in engine). Then a real engine on a throwaway data folder, the demo model calling
// `present`, and the test's own connection standing in for the app that draws: the tool offered where it should be, its
// refusals, the files copied by content, the record after an update, a page drawn (in time, late, never, by no app, an
// oversized answer, one from another connection), the requests and their refusals, the question answered and not, a
// fork, a deletion, a backup and its restore, and `engine.info`'s `presented`.

import assert from "node:assert/strict";
import { type ChildProcess, execFileSync, spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { appendFileSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, rmSync, symlinkSync, truncateSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { basename, dirname, join } from "node:path";
import { crc32, deflateSync } from "node:zlib";
import { restoreBackup } from "../src/backup.ts";
import { GONE } from "../src/needs.ts";
import {
	checkDrawn,
	consoleWords,
	errorsIn,
	checkGiven,
	copyItem,
	findItem,
	isSvg,
	pathFits,
	NO_SVG_TO_A_DEVICE,
	NOT_DRAWN,
	NOT_PRESENTED,
	pictureSize,
	presented,
	readKept,
	readOnce,
	svgSize,
	walkPage,
} from "../src/presented.ts";
import { scratchFolder } from "../src/scratch.ts";
import { aProject, EngineClient, leaveOut, standInApp, stop } from "./patience.ts";

const work = realpathSync(mkdtempSync(join(tmpdir(), "pi2-presented-")));
const KEYCHAIN_SERVICE = `dev.pi2.credentials.test-presented-${process.pid}`;
const engines: ChildProcess[] = [];
process.on("exit", () => {
	for (const engine of engines) if (engine.exitCode === null && engine.signalCode === null) engine.kill("SIGKILL");
	rmSync(work, { recursive: true, force: true });
	try {
		while (true) execFileSync("/usr/bin/security", ["delete-generic-password", "-s", KEYCHAIN_SERVICE], { stdio: "ignore" });
	} catch {
		// None left.
	}
});

function step(name: string): void {
	console.log(`ok  ${name}`);
}

const MB = 1024 * 1024;
const sha = (bytes: Buffer) => createHash("sha256").update(bytes).digest("hex");

/** A PNG of `width`×`height`: whole, or (`body` false) its header alone, which is all the engine reads of it. */
function png(width: number, height: number, body = true): Buffer {
	const chunk = (type: string, data: Buffer) => {
		const length = Buffer.alloc(4);
		length.writeUInt32BE(data.length);
		const typed = Buffer.concat([Buffer.from(type, "latin1"), data]);
		const check = Buffer.alloc(4);
		check.writeUInt32BE(crc32(typed));
		return Buffer.concat([length, typed, check]);
	};
	const header = Buffer.alloc(13);
	header.writeUInt32BE(width, 0);
	header.writeUInt32BE(height, 4);
	header[8] = 8;
	header[9] = 2;
	const parts = [Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), chunk("IHDR", header)];
	if (body) parts.push(chunk("IDAT", deflateSync(Buffer.alloc((width * 3 + 1) * height))));
	parts.push(chunk("IEND", Buffer.alloc(0)));
	return Buffer.concat(parts);
}
const pad = (bytes: Buffer, size: number) => Buffer.concat([bytes, Buffer.alloc(size - bytes.length)]);
function jpeg(width: number, height: number): Buffer {
	const app0 = Buffer.from([0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00]);
	const frame = Buffer.from([0xff, 0xc0, 0x00, 0x11, 0x08, height >> 8, height & 255, width >> 8, width & 255, 0x03, 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1]);
	return Buffer.concat([Buffer.from([0xff, 0xd8]), app0, frame, Buffer.from([0xff, 0xd9])]);
}
function gif(width: number, height: number): Buffer {
	const bytes = pad(Buffer.from("GIF89a", "latin1"), 32);
	bytes.writeUInt16LE(width, 6);
	bytes.writeUInt16LE(height, 8);
	return bytes;
}
function webp(kind: "VP8 " | "VP8L" | "VP8X", width: number, height: number): Buffer {
	const bytes = Buffer.alloc(40);
	bytes.write("RIFF", 0, "latin1");
	bytes.writeUInt32LE(32, 4);
	bytes.write("WEBP", 8, "latin1");
	bytes.write(kind, 12, "latin1");
	if (kind === "VP8 ") {
		bytes.set([0x9d, 0x01, 0x2a], 23);
		bytes.writeUInt16LE(width, 26);
		bytes.writeUInt16LE(height, 28);
	} else if (kind === "VP8L") {
		const bits = (width - 1) | ((height - 1) << 14);
		bytes[20] = 0x2f;
		bytes.writeUInt32LE(bits >>> 0, 21);
	} else {
		bytes.writeUIntLE(width - 1, 24, 3);
		bytes.writeUIntLE(height - 1, 27, 3);
	}
	return bytes;
}
const svg = (attributes: string, size = 0) => Buffer.from(`<?xml version="1.0"?>\n<!-- a mockup -->\n<svg xmlns="http://www.w3.org/2000/svg" ${attributes}><rect width="10" height="10"/>${" ".repeat(size)}</svg>`);

/** A refusal's message, from a function that throws one. */
const refusalOf = (run: () => unknown): string => {
	try {
		run();
	} catch (error) {
		return (error as Error).message;
	}
	throw new Error("it did not refuse");
};

// ---- Without an engine: what the tool refuses before anything is read

{
	const one = (extra: Record<string, unknown> = {}) => ({ title: "Sign-in", items: [{ path: "a.png" }], ...extra });
	const refused = (args: Record<string, unknown>, inAProject = true) => {
		const checked = checkGiven(args as never, inAProject);
		assert.equal(typeof checked, "string", JSON.stringify(args));
		return checked as string;
	};
	const taken = (args: Record<string, unknown>, inAProject = true) => {
		const checked = checkGiven(args as never, inAProject);
		assert.notEqual(typeof checked, "string", String(checked));
		return checked as Exclude<ReturnType<typeof checkGiven>, string>;
	};
	assert.match(refused({ title: " ", items: [{ path: "a.png" }] }), /Give a title/);
	assert.match(refused({ title: "x".repeat(121), items: [{ path: "a.png" }] }), /keep it to 120/);
	taken({ title: "x".repeat(120), items: [{ path: "a.png" }] });
	assert.match(refused({ title: "t", items: [] }), /at least one item/);
	assert.match(refused({ title: "t", items: Array.from({ length: 7 }, () => ({ path: "a.png" })) }), /give 6 at most/);
	assert.deepEqual(taken({ title: "t", items: Array.from({ length: 6 }, () => ({ path: "a.png" })) }).items.map((item) => item.label), ["A", "B", "C", "D", "E", "F"]);
	assert.match(refused({ title: "t", items: [{ path: " " }] }), /Item 1 has no path/);
	// A path is 1,024 bytes at most, and each name in it 255, in UTF-8 (#994's read).
	taken({ title: "t", items: [{ path: `${"d/".repeat(511)}ab` }] });
	assert.match(refused({ title: "t", items: [{ path: `${"d/".repeat(511)}abc` }] }), /is 1,025 bytes, or has a name over 255: a path can be 1,024 bytes at most, and each name in it 255/);
	assert.match(refused({ title: "t", items: [{ path: "é".repeat(513) }] }), /is 1,026 bytes/);
	taken({ title: "t", items: [{ path: `x/${"n".repeat(255)}` }] });
	assert.match(refused({ title: "t", items: [{ path: `x/${"n".repeat(256)}` }] }), /has a name over 255/);
	assert.match(refused({ title: "t", items: [{ path: `${"./".repeat(100_000)}a.png` }] }), /is 200,005 bytes/, "the reader's path");
	assert.ok(pathFits("a/b") && !pathFits("x".repeat(1025)) && !pathFits(`a/${"é".repeat(128)}`));
	assert.match(refused({ title: "t", items: [{ path: "a.png", label: "x".repeat(13) }] }), /keep labels to 12/);
	assert.equal(taken({ title: "t", items: [{ path: "a.png", label: "x".repeat(12) }] }).items[0]!.label, "x".repeat(12));
	assert.match(refused({ title: "t", items: [{ path: "a.png", label: "Wide" }, { path: "b.png", label: "wide" }] }), /Two items are labelled “wide”/);
	assert.match(refused({ title: "t", items: [{ path: "a.png", label: "B" }, { path: "b.png" }] }), /Two items are labelled “B”/, "a label of the agent's against a default one");
	assert.match(refused({ title: "t", items: [{ path: "a.png", caption: "c".repeat(401) }] }), /a line or two \(400/);
	taken({ title: "t", items: [{ path: "a.png", caption: "c".repeat(400) }] });
	assert.match(refused(one({ choices: ["Yes", "No"] })), /choices go with question/);
	assert.match(refused(one({ question: "Which?", choices: ["Only"] })), /Give 2 to 6 choices/);
	assert.match(refused(one({ question: "Which?", choices: ["1", "2", "3", "4", "5", "6", "7"] })), /Give 2 to 6 choices/);
	assert.match(refused(one({ question: "Which?", choices: ["x".repeat(61), "No"] })), /the most is 60/);
	assert.equal(taken(one({ question: "Which?", choices: ["x".repeat(60), "No"] })).question!.choices[0]!.label, "x".repeat(60));
	assert.match(refused(one({ question: "Which?", choices: ["Yes", " yes "] })), /Two choices are the same/);
	assert.match(refused(one({ question: "Which?", choices: ["Yes", " "] })), /A choice is empty/);
	assert.match(refused(one({ question: "x".repeat(2001) })), /the most is 2,000/);
	assert.equal(refused(one({ question: "Which?", wait: false }), false), "In a conversation outside a project, a question waits for its answer; leave out wait.");
	assert.equal(taken(one({ question: "Which?", wait: false })).question!.wait, false);
	assert.match(refused(one({ update: "2" })), /not the id of a presentation/);
	assert.deepEqual(taken({ title: "t", items: [{ path: "a" }, { path: "b", label: "Dark" }], question: "Which?" }).question!.choices, [
		{ id: "c1", label: "Use A" },
		{ id: "c2", label: "Use Dark" },
	]);
	step("before anything is read: the title, 1 to 6 items, labels (12, none the same), captions, the question and its choices, wait outside a project and update, each at its edge");
}

// ---- Reading a file once, never through a link; the pictures' sizes

{
	const folder = mkdtempSync(join(work, "read-"));
	const file = join(folder, "a.png");
	writeFileSync(file, png(4, 3));
	assert.deepEqual(readOnce(file, 1 * MB, "a.png", () => "too large"), png(4, 3));
	symlinkSync(file, join(folder, "link.png"));
	assert.match(refusalOf(() => readOnce(join(folder, "link.png"), MB, "“link.png”", () => "")), /is a symbolic link, which present does not follow/);
	assert.match(refusalOf(() => readOnce(folder, MB, "“folder”", () => "")), /is a folder/);
	execFileSync("/usr/bin/mkfifo", [join(folder, "pipe")]);
	assert.match(refusalOf(() => readOnce(join(folder, "pipe"), MB, "“pipe”", () => "")), /is not a plain file/, "a pipe is refused, without waiting for a writer");
	assert.match(refusalOf(() => readOnce(join(folder, "none.png"), MB, "“none.png”", () => "")), /does not exist/);
	assert.equal(refusalOf(() => readOnce(file, png(4, 3).length - 1, "a.png", (bytes) => `too large: ${bytes}`)), `too large: ${png(4, 3).length}`);
	// A file that changes between the check and the copy: grown, and rewritten to the same size.
	assert.match(refusalOf(() => readOnce(file, MB, "“a.png”", () => "", () => appendFileSync(file, "more"))), /changed while it was being copied/);
	writeFileSync(file, png(4, 3));
	assert.match(refusalOf(() => readOnce(file, MB, "“a.png”", () => "", () => writeFileSync(file, Buffer.alloc(png(4, 3).length, 1)))), /changed while it was being copied/);

	assert.deepEqual(pictureSize(png(1440, 900, false), "image/png"), { width: 1440, height: 900 });
	assert.deepEqual(pictureSize(jpeg(1024, 768), "image/jpeg"), { width: 1024, height: 768 });
	assert.deepEqual(pictureSize(gif(320, 200), "image/gif"), { width: 320, height: 200 });
	assert.deepEqual(pictureSize(webp("VP8 ", 640, 480), "image/webp"), { width: 640, height: 480 });
	assert.deepEqual(pictureSize(webp("VP8L", 16_384, 3), "image/webp"), { width: 16_384, height: 3 });
	assert.deepEqual(pictureSize(webp("VP8X", 2000, 1000), "image/webp"), { width: 2000, height: 1000 });
	assert.equal(pictureSize(Buffer.from([0xff, 0xd8, 0xff, 0x00]), "image/jpeg"), undefined);
	assert.ok(isSvg(svg('width="10" height="10"')) && isSvg(Buffer.from("\uFEFF  <svg/>")) && !isSvg(Buffer.from("<html><svg></svg></html>")));
	assert.deepEqual(svgSize(svg('width="1440" height="900px"')), { width: 1440, height: 900 });
	assert.deepEqual(svgSize(svg('viewBox="0 0 320 200" width="100%"')), { width: 320, height: 200 });
	assert.equal(svgSize(svg("")), null);

	// Each picture limit at its edge, through what the tool does with one item.
	const at = (name: string, bytes: Buffer) => {
		writeFileSync(join(folder, name), bytes);
		return join(folder, name);
	};
	assert.equal(copyItem(at("edge.png", pad(png(16_384, 16_384, false), 20 * MB)), "edge.png").item.width, 16_384);
	assert.match(refusalOf(() => copyItem(at("big.png", pad(png(10, 10, false), 20 * MB + 1)), "big.png")), /is 20\.0 MB; a picture can be 20 MB at most/);
	assert.match(refusalOf(() => copyItem(at("wide.png", png(16_385, 1, false)), "wide.png")), /is 16385×1 pixels; a picture can be 16,384 a side at most/);
	assert.match(refusalOf(() => copyItem(at("tall.jpg", jpeg(1, 16_385)), "tall.jpg")), /16,384 a side/);
	const svgEdge = svg('width="10" height="10"');
	assert.equal(copyItem(at("edge.svg", svg('width="10" height="10"', 2 * MB - svgEdge.length)), "edge.svg").item.mimeType, "image/svg+xml");
	assert.match(refusalOf(() => copyItem(at("big.svg", svg('width="10" height="10"', 2 * MB - svgEdge.length + 1)), "big.svg")), /an SVG can be 2 MB at most/);
	assert.match(refusalOf(() => copyItem(at("fake.svg", Buffer.from("<html></html>")), "fake.svg")), /is named \.svg but is not an SVG picture/);
	assert.match(refusalOf(() => copyItem(at("notes.txt", Buffer.from("hello")), "notes.txt")), /is neither a picture present shows \(PNG, JPEG, GIF, WebP or SVG\) nor a page/);
	assert.match(refusalOf(() => copyItem(at("broken.png", Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0])), "broken.png")), /its size cannot be read/);
	assert.equal(copyItem(at("type.png", jpeg(8, 8)), "type.png").item.mimeType, "image/jpeg", "a picture is what its first bytes say, whatever its name");
	step("a file is read once, never through a link, and refused if it changes while copied; sizes of PNG, JPEG, GIF, WebP and SVG; each picture limit at its edge");
}

// ---- A page's folder

{
	const page = mkdtempSync(join(work, "page-"));
	const outside = join(work, "secret.txt");
	writeFileSync(outside, "not the page's");
	writeFileSync(join(page, "index.html"), '<link rel="stylesheet" href="style.css"><img src="sub/pic.png">');
	writeFileSync(join(page, "style.css"), "body { color: red }");
	mkdirSync(join(page, "sub"));
	writeFileSync(join(page, "sub", "pic.png"), png(2, 2));
	mkdirSync(join(page, ".git"));
	writeFileSync(join(page, ".git", "config"), "[core]");
	writeFileSync(join(page, ".env"), "KEY=1");
	mkdirSync(join(page, "node_modules"));
	writeFileSync(join(page, "node_modules", "x.js"), "");
	symlinkSync(outside, join(page, "out.txt"));
	symlinkSync(join(page, "style.css"), join(page, "in.css"));
	symlinkSync(work, join(page, "up"));
	const walked = walkPage(join(page, "index.html"), "“index.html”");
	assert.deepEqual([...walked.files.keys()].sort(), ["index.html", "style.css", "sub/pic.png"]);
	assert.equal(walked.links, 3, "a link is left out, whether it leads out of the folder or not");
	assert.equal(walked.hidden, 3);
	const copied = copyItem(join(page, "index.html"), "page/index.html");
	const manifest = JSON.parse(copied.keep.at(-1)!.bytes.toString("utf8"));
	assert.deepEqual(manifest, {
		entry: "index.html",
		files: {
			"index.html": { sha256: sha(readFileSync(join(page, "index.html"))), bytes: readFileSync(join(page, "index.html")).length, type: "text/html" },
			"style.css": { sha256: sha(readFileSync(join(page, "style.css"))), bytes: 19, type: "text/css" },
			"sub/pic.png": { sha256: sha(png(2, 2)), bytes: png(2, 2).length, type: "image/png" },
		},
	});
	assert.equal(copied.item.sha256, sha(copied.keep.at(-1)!.bytes), "a page's item names its manifest");
	assert.deepEqual(copied.item.snapshot, { state: "pending" });

	// 500 files at most, the entry among them; 50 MB; 2,000 folders.
	const many = mkdtempSync(join(work, "many-"));
	writeFileSync(join(many, "index.html"), "<p>");
	for (let i = 1; i < 500; i++) writeFileSync(join(many, `f${i}.txt`), "x");
	assert.equal(walkPage(join(many, "index.html"), "p").files.size, 500);
	writeFileSync(join(many, "f500.txt"), "x");
	assert.match(refusalOf(() => walkPage(join(many, "index.html"), "p")), /holds more than 500 files\. Keep the folder to the mockup/);
	const heavy = mkdtempSync(join(work, "heavy-"));
	writeFileSync(join(heavy, "index.html"), "<p>");
	writeFileSync(join(heavy, "big.bin"), Buffer.alloc(50 * MB - 3));
	assert.equal(walkPage(join(heavy, "index.html"), "p").bytes, 50 * MB);
	appendFileSync(join(heavy, "big.bin"), "!");
	assert.match(refusalOf(() => walkPage(join(heavy, "index.html"), "p")), /holds more than 50 MB/);
	const deep = mkdtempSync(join(work, "deep-"));
	writeFileSync(join(deep, "index.html"), "<p>");
	for (let i = 1; i < 2000; i++) mkdirSync(join(deep, `d${i}`));
	assert.equal(walkPage(join(deep, "index.html"), "p").files.size, 1);
	mkdirSync(join(deep, "d2000"));
	assert.match(refusalOf(() => walkPage(join(deep, "index.html"), "p")), /more than 2,000 folders/);
	// The home folder, and what holds it, are refused before anything in them is read.
	assert.match(refusalOf(() => walkPage(join(homedir(), "index.html"), "p")), /which holds far more than a mockup/);
	assert.match(refusalOf(() => walkPage("/index.html", "p")), /which holds far more than a mockup/);
	assert.match(refusalOf(() => walkPage(join(homedir(), "Library", "index.html"), "p")), /which holds far more than a mockup/);
	// On real paths (#994's read): a link to a stand-in home, as the page's folder and one level above it, is the home
	// folder, and nothing in it is read. HOME names the stand-in for these checks alone.
	const fakeHome = mkdtempSync(join(work, "fake-home-"));
	writeFileSync(join(fakeHome, "page.html"), "<p>");
	writeFileSync(join(fakeHome, "notes.txt"), "private");
	const realHome = process.env.HOME;
	process.env.HOME = fakeHome;
	try {
		assert.equal(homedir(), fakeHome);
		const links = mkdtempSync(join(work, "links-"));
		symlinkSync(fakeHome, join(links, "toHome"));
		assert.match(refusalOf(() => walkPage(join(links, "toHome", "page.html"), "p")), /which holds far more than a mockup/, "a link to the home folder");
		symlinkSync(dirname(fakeHome), join(links, "toParent"));
		assert.match(refusalOf(() => walkPage(join(links, "toParent", basename(fakeHome), "page.html"), "p")), /which holds far more than a mockup/, "a link above it");
		assert.match(refusalOf(() => walkPage(join(links, "toParent", "page.html"), "p")), /which holds far more than a mockup/, "a link to a folder that holds it");
	} finally {
		process.env.HOME = realHome;
	}
	// A folder swapped for a link once its parent was listed, and a file reached through a folder swapped so, are refused.
	const elsewhere = mkdtempSync(join(work, "elsewhere-"));
	writeFileSync(join(elsewhere, "a.css"), "not the page's");
	const swapped = (when: (folder: string, root: string) => boolean) => {
		const root = realpathSync(mkdtempSync(join(work, "swap-")));
		writeFileSync(join(root, "index.html"), "<p>");
		mkdirSync(join(root, "sub"));
		writeFileSync(join(root, "sub", "a.css"), "the page's");
		return refusalOf(() =>
			walkPage(join(root, "index.html"), "“index.html”", {
				listed: (folder) => {
					if (!when(folder, root)) return;
					rmSync(join(root, "sub"), { recursive: true });
					symlinkSync(elsewhere, join(root, "sub"));
				},
			}),
		);
	};
	assert.match(swapped((folder, root) => folder === root), /The folder of “index\.html” changed while it was being copied/, "a subfolder that became a link before it was listed");
	assert.match(swapped((folder, root) => folder === join(root, "sub")), /changed while it was being copied/, "a file reached through a folder that became a link");
	// The page's own file a link out: never followed.
	const linkedEntry = mkdtempSync(join(work, "entry-"));
	symlinkSync(join(elsewhere, "a.css"), join(linkedEntry, "index.html"));
	assert.match(refusalOf(() => walkPage(join(linkedEntry, "index.html"), "“index.html”")), /is a symbolic link, which present does not follow/);
	// A page reached through a link to its folder is walked from its real folder, as the files there are.
	const viaLink = join(mkdtempSync(join(work, "via-")), "page");
	symlinkSync(page, viaLink);
	assert.deepEqual([...walkPage(join(viaLink, "index.html"), "p").files.keys()].sort(), ["index.html", "style.css", "sub/pic.png"]);
	// A file named __proto__ is a file of the manifest like any other.
	const odd = mkdtempSync(join(work, "odd-"));
	writeFileSync(join(odd, "index.html"), "<p>");
	writeFileSync(join(odd, "__proto__"), "x");
	assert.ok(Object.hasOwn(JSON.parse(copyItem(join(odd, "index.html"), "index.html").keep.at(-1)!.bytes.toString("utf8")).files, "__proto__"));
	step("a page: its folder without links, hidden files or node_modules; its manifest; 500 files, 50 MB and 2,000 folders at their edge; the home folder refused unread");
}

// ---- present.drawn's bounds, the record's lookups, what is served

{
	const snapshot = { mimeType: "image/png", data: png(2560, 1600, false).toString("base64") };
	const good = { ok: true, loadMs: 400, blank: false, height: 2140, console: [], blocked: [], snapshot };
	assert.equal(checkDrawn(good).ok, true);
	const bounds: [string, Record<string, unknown>, RegExp][] = [
		["console 51 lines", { console: Array.from({ length: 51 }, () => "e") }, /console holds 51 entries; the most is 50/],
		["a console line of 501", { console: ["e".repeat(501)] }, /is 501 characters; the most is 500/],
		["blocked 21", { blocked: Array.from({ length: 21 }, () => "https://x.example") }, /blocked holds 21 entries; the most is 20/],
		["an address of 2,049", { blocked: [`https://x.example/${"a".repeat(2049 - 18)}`] }, /the most is 2048/],
		["a snapshot over 20 MB", { snapshot: { mimeType: "image/png", data: pad(png(1, 1, false), 20 * MB + 3).toString("base64") } }, /larger than 20 MB/],
		["a snapshot that is no PNG", { snapshot: { mimeType: "image/png", data: jpeg(2, 2).toString("base64") } }, /is not a PNG/],
		["a snapshot another type", { snapshot: { mimeType: "image/jpeg", data: snapshot.data } }, /snapshot must be/],
		["a snapshot over 16,384 a side", { snapshot: { mimeType: "image/png", data: png(16_385, 1, false).toString("base64") } }, /over 16,384 pixels a side/],
		["no snapshot", { snapshot: undefined }, /snapshot must be/],
		["a height that is no whole number", { height: 2.5 }, /height must be/],
		["a load time below 0", { loadMs: -1 }, /loadMs must be/],
		["not base64", { snapshot: { mimeType: "image/png", data: "%%%%" } }, /not base64/],
	];
	for (const [what, change, message] of bounds) assert.throws(() => checkDrawn({ ...good, ...change }), message, what);
	assert.equal(checkDrawn({ ...good, console: Array.from({ length: 50 }, () => "e".repeat(500)), blocked: Array.from({ length: 20 }, () => "https://x.example") }).ok, true, "50 lines of 500, and 20 addresses");
	assert.deepEqual(checkDrawn({ ok: false, reason: "The page's process ended" }), { ok: false, reason: "The page's process ended", console: [], blocked: [] });
	assert.throws(() => checkDrawn({ ok: false, reason: "x".repeat(501) }), /500 characters at most/);
	assert.throws(() => checkDrawn({ ok: false }), /reason must say why/);
	assert.deepEqual((checkDrawn({ ...good, console: ["line\nbreak\u0007"] }) as { console: string[] }).console, ["line break"], "a finding is one line");
	// A console line is an error only when the app says so ("error: "): a log, info, debug or warning is a line.
	assert.equal(consoleWords([]), undefined, "nothing printed, nothing said");
	assert.equal(consoleWords(["error: TypeError: x"]), '1 console error: "TypeError: x"');
	assert.equal(consoleWords(["error: a", "error: b"]), '2 console errors: "a"; "b"');
	assert.equal(consoleWords(["log: hello"]), '1 console line, no errors: "log: hello"');
	assert.equal(consoleWords(["log: a", "info: b", "debug: c", "warn: d"]), '4 console lines, no errors: "log: a"; "info: b"; "debug: c"; "warn: d"');
	assert.equal(consoleWords(["log: a", "error: b"]), '1 console error: "b"; 1 other console line: "log: a"');
	assert.equal(consoleWords(["error: a", "error: b", "log: c", "warn: d"]), '2 console errors: "a"; "b"; 2 other console lines: "log: c"; "warn: d"');
	assert.equal(errorsIn(["error: a", "log: b", "warn: c", "errors: d", "error:e"]), 1, "by its prefix alone");

	const item = { label: "A", caption: null, kind: "picture" as const, name: "a.svg", mimeType: "image/svg+xml", sha256: "0".repeat(64), bytes: 1, files: 1, width: null, height: null, snapshot: null, drawn: null };
	const network = { allowed: false, changes: [] };
	const doc = { next: 2, items: { p1: { id: "p1", versions: [{ version: 1, callId: "c", createdAt: 0, title: "t", question: null, network, items: [item] }] } } };
	assert.equal(findItem(doc, "p1", 1, 0).item, item);
	for (const [presentation, version, index] of [
		["p2", 1, 0],
		["p1", 2, 0],
		["p1", 1, 1],
	] as const) {
		assert.equal(refusalOf(() => findItem(doc, presentation, version, index)), NOT_PRESENTED, `${presentation} ${version} ${index}`);
	}
	for (const presentation of ["__proto__", "constructor", "p0", "p01", "p1 ", "../p1", "P1", 1, null]) assert.throws(() => findItem(doc, presentation, 1, 0), /presentation must be|no such presentation/, String(presentation));
	for (const version of ["1", 1.5, 0, -1, Number.NaN, 2 ** 60, null]) assert.throws(() => findItem(doc, "p1", version, 0), /version must be a whole number/, String(version));
	for (const index of ["0", 0.5, -1, Number.POSITIVE_INFINITY]) assert.throws(() => findItem(doc, "p1", 1, index), /item must be a whole number/, String(index));
	step("present.drawn's bounds, each at its edge; a presentation, version and item only as whole numbers the conversation's record has");

	// What `presented.picture` hands a phone: through the feature's own handler, with a device's session as its
	// connection, against a stand-in engine whose record names an SVG, a PNG and a page.
	const home = mkdtempSync(join(work, "home-"));
	const keepBlob = (bytes: Buffer) => {
		mkdirSync(join(home, "presented", "7", "blobs"), { recursive: true });
		writeFileSync(join(home, "presented", "7", "blobs", sha(bytes)), bytes);
		return sha(bytes);
	};
	const svgBytes = svg('width="10" height="10"');
	const pngBytes = png(3, 3);
	const snapshotBytes = png(5, 5);
	const page = { ...item, kind: "page" as const, name: "index.html", mimeType: "text/html", sha256: "1".repeat(64), snapshot: { state: "pending" as const } };
	const record = {
		next: 2,
		items: {
			p1: {
				id: "p1",
				versions: [
					{
						version: 1,
						callId: "c",
						createdAt: 0,
						title: "t",
						question: null,
						network,
						items: [
							{ ...item, sha256: keepBlob(svgBytes) },
							{ ...item, mimeType: "image/png", name: "a.png", sha256: keepBlob(pngBytes) },
							page,
							{ ...page, snapshot: { state: "drawn" as const, sha256: keepBlob(snapshotBytes) } },
						],
					},
				],
			},
		},
	};
	const feature = presented({ inbox: {}, scratchFolder: () => home } as never, {
		home,
		log: () => {},
		context: () => undefined,
		library: () => ({ conversations: {} }),
		conversation: async (id: unknown) => {
			if (id !== 7) throw new Error(`Unknown conversation: ${String(id)}`);
			return { id: 7 };
		},
		harness: () => ({ snapshot: async () => structuredClone(record) }),
	} as never);
	const picture = feature.handlers!["presented.picture"]!;
	const phone = { device: { id: "d1", session: "s1" } };
	const mac = {};
	const ask = (connection: object, item: number) => picture({ id: 7, presentation: "p1", version: 1, item }, connection);
	await assert.rejects(ask(phone, 0), (error: Error) => error.message === NO_SVG_TO_A_DEVICE, "an SVG is refused to a phone, not converted");
	assert.deepEqual(await ask(mac, 0), { mimeType: "image/svg+xml", data: svgBytes.toString("base64") }, "and handed to the Mac");
	assert.deepEqual(await ask(phone, 1), { mimeType: "image/png", data: pngBytes.toString("base64") });
	await assert.rejects(ask(phone, 2), (error: Error) => error.message === NOT_DRAWN, "a page not drawn yet is refused");
	assert.deepEqual(await ask(phone, 3), { mimeType: "image/png", data: snapshotBytes.toString("base64") }, "a page's snapshot is a PNG");
	await assert.rejects(picture({ id: 8, presentation: "p1", version: 1, item: 1 }, phone), /Unknown conversation: 8/);
	assert.deepEqual(await picture({ id: 7, presentation: "p1", version: 1, item: 1, sha256: sha(svgBytes) }, phone), { mimeType: "image/png", data: pngBytes.toString("base64") }, "a sha256 in the request is not read");
	for (const method of ["presented.list", "presented.file", "presented.page"]) await assert.rejects(feature.handlers![method]!({ id: 7, presentation: "p1", version: 1, item: 3, path: "index.html" }, phone), /the Mac's/, `${method} from a phone`);
	// The blob is read under that conversation's folder only, never through a link, and must still be what was kept.
	writeFileSync(join(home, "presented", "7", "blobs", sha(pngBytes)), png(3, 4));
	await assert.rejects(ask(mac, 1), /has changed on disk since it was kept/);
	rmSync(join(home, "presented", "7", "blobs"), { recursive: true });
	mkdirSync(join(home, "elsewhere"));
	writeFileSync(join(home, "elsewhere", sha(pngBytes)), pngBytes);
	symlinkSync(join(home, "elsewhere"), join(home, "presented", "7", "blobs"));
	await assert.rejects(ask(mac, 1), /is not a folder pi² made/);
	assert.throws(() => readKept(home, 7, "blobs", "../../elsewhere"), (error: Error) => error.message === NOT_PRESENTED);
	step("a phone: presented.picture hands it PNG, JPEG, GIF or WebP alone, an SVG refused with a sentence, a page only once drawn; the blob named by the record, under that conversation's folder, no link followed");
}

// ---- A real engine

const main = join(import.meta.dirname, "..", "src", "main.ts");
process.env.PI2_DEMO_TOKENS_PER_SECOND ??= "100000";
process.env.PI2_LOGIN_SHELL ??= "off";
const bundle = standInApp();
const start = (home: string, extra: Record<string, string> = {}) => {
	const engine = spawn(process.execPath, [main], { env: { ...process.env, PI2_HOME: home, PI2_KEYCHAIN_SERVICE: KEYCHAIN_SERVICE, PI2_APP_BUNDLE: bundle, ...extra }, stdio: ["ignore", "ignore", "inherit"] });
	engines.push(engine);
	return engine;
};

type Event = Record<string, any>;
class Client extends EngineClient {
	draws: Event[] = [];
	presented: Event[] = [];
	/** What the stand-in app answers a draw with, as it comes; nothing when it holds its answer. */
	drawing: ((draw: Event) => Record<string, unknown> | undefined) | undefined;
	override receive(message: any): void {
		if (message.event === "present.draw") {
			this.draws.push(message);
			const answer = this.drawing?.(message);
			if (answer !== undefined) void this.call("present.drawn", { requestId: message.requestId, ...answer });
		}
		if (message.event === "conversation.presented") this.presented.push(message);
		super.receive(message);
	}
	items(id: number, kind: string): Event[] {
		return this.conversations.get(id)?.items.filter((item: Event) => item.kind === kind) ?? [];
	}
	idle(id: number): boolean {
		const conv = this.conversations.get(id);
		return conv !== undefined && !conv.state.busy;
	}
	async answer(id: number, text: string): Promise<string> {
		const before = this.items(id, "assistant").length;
		await this.call("submit", { id, text });
		await this.until(`answer to ${text}`, () => this.idle(id) && this.items(id, "assistant").length > before);
		return this.items(id, "assistant").at(-1)!.text as string;
	}
	/** A message the demo model answers with a tool call; that call's result, once the answer after it is in. */
	async tool(id: number, text: string): Promise<Event> {
		const count = this.items(id, "tool").length + 1;
		await this.call("submit", { id, text });
		return await this.until(`result of ${text.slice(0, 80)}`, () => {
			const conv = this.conversations.get(id);
			const results = this.items(id, "tool");
			if (conv === undefined || conv.state.busy || results.length < count) return undefined;
			const after = conv.items.slice(conv.items.indexOf(results[count - 1]) + 1);
			return after.some((item: Event) => item.kind === "assistant") ? results[count - 1] : undefined;
		});
	}
	present(id: number, args: Record<string, unknown>): Promise<Event> {
		return this.tool(id, `/tool present ${JSON.stringify(args)}`);
	}
	async offered(id: number): Promise<string[]> {
		const said = await this.answer(id, "/system none");
		return said.slice(said.indexOf("TOOLS: ") + 7).split(", ");
	}
	need(predicate: (item: Event) => boolean): Event | undefined {
		return (this.events.needs?.items ?? []).find(predicate);
	}
}

const drawnAnswer = (extra: Record<string, unknown> = {}) => ({ ok: true, loadMs: 400, blank: false, height: 2140, console: [], blocked: [], snapshot: { mimeType: "image/png", data: png(16, 10).toString("base64") }, ...extra });

const home = mkdtempSync(join(tmpdir(), "pi2-presented-home-"));
process.on("exit", () => rmSync(home, { recursive: true, force: true }));
const folder = join(work, "project");
mkdirSync(folder);
// The mockups: a picture, a page with what lies beside it, an SVG.
const pictureBytes = png(1440, 900);
writeFileSync(join(folder, "signin-a.png"), pictureBytes);
mkdirSync(join(folder, "signin-b"));
writeFileSync(join(folder, "signin-b", "index.html"), '<!doctype html><link rel="stylesheet" href="style.css"><script src="app.js"></script><p>Sign in</p>');
writeFileSync(join(folder, "signin-b", "style.css"), "p { color: teal }");
writeFileSync(join(folder, "signin-b", "app.js"), "document.title = 'B'");
writeFileSync(join(folder, "signin-b", "café.css"), "/* NFC */");
symlinkSync(join(work, "secret.txt"), join(folder, "signin-b", "out.txt"));
writeFileSync(join(folder, "signin-c.svg"), svg('width="1440" height="900"'));

// A draw wait longer than any of the test's own (`PI2_PRESENT_DRAW_MS`): a page the stand-in draws is drawn in time,
// however loaded the Mac. The 20 seconds themselves are the second engine's, below.
let engine = start(home, { PI2_PRESENT_DRAW_MS: String(11 * 60_000) });
let client = await Client.connect(engine, home);
let other: Client | undefined;
let backupPath = "";
let chat1 = 0;
try {
	await client.until("the engine's greeting", () => client.events.providers && client.events.agents && client.events.needs);

	// ---- Where it is offered

	const loose = (await client.call("conversation.create", { agentId: "forge" })).id as number;
	await leaveOut(client);
	await client.call("conversation.open", { id: loose });
	const project = await aProject(client, folder, ["forge"]);
	chat1 = (await client.call("conversation.create", { agentId: project.agents.forge })).id as number;
	await client.call("conversation.open", { id: chat1 });
	assert.ok((await client.offered(chat1)).includes("present"), "offered with tool access");
	assert.ok(client.events.agents.builtInTools.some((tool: Event) => tool.key === "present" && tool.title === "Present pictures and mockups" && tool.needs === "files"), "listed among the built-in tools");
	const none = (await client.call("conversation.create", { agentId: project.agents.forge })).id as number;
	await client.call("conversation.open", { id: none });
	await client.call("conversation.configure", { id: none, access: "none" });
	assert.equal((await client.offered(none)).includes("present"), false, "not with tool access off");
	const chat = (await client.call("conversation.create", { chat: true, model: { provider: "demo", modelId: "demo-1" } })).id as number;
	await client.call("conversation.open", { id: chat });
	assert.equal((await client.offered(chat)).includes("present"), false, "not in a chat");
	const setOff = async (toolsOff: string[]) => {
		await client.call("agents.save", { agent: { ...client.events.agents.agents.find((agent: Event) => agent.id === project.agents.forge), toolsOff } });
		await client.until("the agent saved", () => JSON.stringify(client.events.agents.agents.find((agent: Event) => agent.id === project.agents.forge)?.toolsOff ?? []) === JSON.stringify(toolsOff));
	};
	await setOff(["present"]);
	assert.equal((await client.offered(chat1)).includes("present"), false, "not when the agent's settings leave it out");
	await setOff([]);
	assert.ok((await client.offered(chat1)).includes("present"));
	step("present is offered where tool access is not off, listed under Built-in tools, never in a chat, and left out when the agent's settings say so");

	// ---- What the tool refuses, through the engine, each a sentence

	const refusedWith = async (id: number, args: Record<string, unknown>, message: RegExp | string) => {
		const result = await client.present(id, args);
		assert.equal(result.isError, true, `${JSON.stringify(args).slice(0, 120)}: ${result.text}`);
		if (typeof message === "string") assert.equal(result.text, message);
		else assert.match(result.text, message);
	};
	await refusedWith(chat1, { title: "t", items: [{ path: "missing.png" }] }, /“missing\.png” does not exist\. Check the path; a relative one is read from the conversation's folder\./);
	await refusedWith(chat1, { title: "t", items: [{ path: "signin-b/out.txt" }] }, /is a symbolic link, which present does not follow/);
	await refusedWith(chat1, { title: "t", items: [{ path: "signin-b" }] }, /is a folder/);
	await refusedWith(chat1, { title: "t", items: [{ path: "signin-b/style.css" }] }, /is neither a picture present shows/);
	await refusedWith(chat1, { title: "t", items: [{ path: "$HOME/a.png" }] }, "The file tools do not expand variables: write the full path. Only $PI2_SCRATCH may begin a path.");
	await refusedWith(chat1, { title: "t", items: [{ path: "signin-a.png" }], update: "p9" }, "This conversation has presented nothing as p9. Leave update out to present it as something new.");
	await refusedWith(loose, { title: "t", items: [{ path: join(folder, "signin-a.png") }], question: "Which?", wait: false }, "In a conversation outside a project, a question waits for its answer; leave out wait.");
	writeFileSync(join(folder, "nineteen.png"), pad(png(10, 10, false), 19 * MB));
	await refusedWith(chat1, { title: "t", items: Array.from({ length: 6 }, (_, index) => ({ path: "nineteen.png", label: `N${index}` })) }, /These items come to more than 100 MB in one call/);
	rmSync(join(folder, "nineteen.png"));
	assert.equal(existsSync(join(home, "presented", String(chat1))), false, "nothing refused was copied");
	step("the tool refuses, before anything is copied: a path that is not there, a link, a folder, a file of another kind, another variable, an unknown update, wait outside a project, a call over 100 MB");

	// ---- Presented with no app to draw: copied, stored, the page pending

	const first = await client.present(chat1, {
		title: "Sign-in screen, three layouts",
		items: [
			{ path: "signin-a.png", caption: "Centred" },
			{ path: "signin-b/index.html", caption: "Split, with a script" },
			{ path: join(folder, "signin-c.svg"), label: "Wide" },
		],
	});
	assert.equal(first.isError, false, first.text);
	const manifestBytes = Buffer.from(
		JSON.stringify({
			entry: "index.html",
			files: Object.fromEntries(
				["app.js", "café.css", "index.html", "style.css"].map((name) => {
					const bytes = readFileSync(join(folder, "signin-b", name));
					return [name, { sha256: sha(bytes), bytes: bytes.length, type: name.endsWith(".js") ? "text/javascript" : name.endsWith(".css") ? "text/css" : "text/html" }];
				}),
			),
		}),
	);
	const pageBytes = ["app.js", "café.css", "index.html", "style.css"].reduce((sum, name) => sum + readFileSync(join(folder, "signin-b", name)).length, 0);
	assert.equal(
		first.text,
		[
			'Presented "Sign-in screen, three layouts" as p1, version 1. The person sees a card in the conversation and can open it in a window.',
			`A  signin-a.png: PNG, 1440×900, ${Math.round(pictureBytes.length / 1024)} KB`,
			`B  signin-b/index.html: page, 4 files, ${pageBytes} bytes; not drawn yet: pi² is not open on this Mac. The person sees it once it is; nothing was checked`,
			`Wide  ${join(folder, "signin-c.svg")}: SVG, 1440×900, ${svg('width="1440" height="900"').length} bytes`,
			'To show a new version of this, call present again with update: "p1".',
		].join("\n"),
	);
	assert.equal(first.details.presentation, "p1");
	assert.equal(first.details.version, 1);
	assert.equal(first.details.title, "Sign-in screen, three layouts");
	assert.deepEqual(
		first.details.items.map((item: Event) => [item.label, item.kind, item.mimeType, item.caption, item.files, item.width, item.height, item.snapshot]),
		[
			["A", "picture", "image/png", "Centred", 1, 1440, 900, null],
			["B", "page", "text/html", "Split, with a script", 4, null, null, { state: "pending" }],
			["Wide", "picture", "image/svg+xml", null, 1, 1440, 900, null],
		],
	);
	assert.equal(first.details.items[0].sha256, sha(pictureBytes));
	assert.equal(first.details.items[1].sha256, sha(manifestBytes), "the page's item names its manifest by its SHA-256");
	const blobs = join(home, "presented", String(chat1), "blobs");
	assert.deepEqual(readFileSync(join(blobs, sha(pictureBytes))), pictureBytes, "copied by its content");
	assert.deepEqual(readFileSync(join(home, "presented", String(chat1), "pages", `${sha(manifestBytes)}.json`)), manifestBytes);
	assert.ok(!readdirSync(blobs).includes(sha(readFileSync(join(work, "secret.txt")))), "a link's target is not copied");
	const listed = (await client.call("presented.list", { id: chat1 })).items;
	assert.equal(listed.length, 1);
	assert.deepEqual({ presentation: "p1", ...listed[0].versions[0] }, first.details, "the result's details are the stored version, with its presentation");
	assert.deepEqual(listed[0].versions[0].network, { allowed: false, changes: [] }, "the network off");
	await client.until("conversation.presented for p1", () => client.presented.some((event) => event.id === chat1 && event.record.id === "p1"));
	step("presented with no app to draw: each file copied by its content, the page's manifest kept, the version stored and given in the result, the page pending, the event sent");

	// ---- The app registers: the pending page is asked of it

	other = await Client.connect(engine, home);
	await client.call("present.register");
	const draw = await client.until("the pending page asked of the app", () => client.draws.find((one) => one.conversationId === chat1 && one.presentation === "p1" && one.item === 1));
	assert.deepEqual({ ...draw, requestId: undefined }, { event: "present.draw", requestId: undefined, conversationId: chat1, presentation: "p1", version: 1, item: 1, width: 1280, height: 800 });
	assert.equal(other.draws.length, 0, "only the app that registered is asked");
	// What the page asks for as it is drawn, by its manifest's paths alone.
	const file = (path: unknown) => client.call("presented.file", { id: chat1, presentation: "p1", version: 1, item: 1, path });
	assert.deepEqual(await file("style.css"), { mimeType: "text/css", data: Buffer.from("p { color: teal }").toString("base64") });
	assert.equal(Buffer.from((await file("café.css")).data, "base64").toString(), "/* NFC */");
	for (const path of ["../signin-a.png", "%2e%2e/signin-a.png", "..%2fsignin-a.png", join(folder, "signin-b", "style.css"), "/etc/passwd", "out.txt", "STYLE.CSS", "café.css".normalize("NFD"), "./style.css", "style.css/", "sub/../style.css", "__proto__", "constructor"]) {
		await assert.rejects(file(path), (error: Error) => error.message === "The page has no such file.", path);
	}
	for (const path of ["x".repeat(1025), "", 5, null]) await assert.rejects(file(path), /path must be a file of the page/, String(path).slice(0, 10));
	await assert.rejects(client.call("presented.file", { id: chat1, presentation: "p1", version: 1, item: 0, path: "style.css" }), /That item is a picture, not a page/);
	// The page's list of files, as the page view takes it before it asks for any (presented.page).
	const listing = (params: Record<string, unknown>) => client.call("presented.page", { id: chat1, presentation: "p1", version: 1, item: 1, ...params });
	assert.deepEqual(await listing({}), {
		entry: "index.html",
		files: ["app.js", "café.css", "index.html", "style.css"].map((path) => ({ path, bytes: readFileSync(join(folder, "signin-b", path)).length, type: path.endsWith(".js") ? "text/javascript" : path.endsWith(".css") ? "text/css" : "text/html" })),
	});
	for (const [params, message] of [
		[{ item: 0 }, /^That item is a picture, not a page/],
		[{ version: 9 }, new RegExp(`^${NOT_PRESENTED}$`)],
		[{ presentation: "__proto__" }, /presentation must be/],
		[{ item: "1" }, /item must be a whole number/],
		[{ id: 99_999 }, /^Unknown conversation: 99999$/],
	] as const) {
		const page = await listing(params).catch((error: Error) => error.message);
		const file = await client.call("presented.file", { id: chat1, presentation: "p1", version: 1, item: 1, path: "style.css", ...params }).catch((error: Error) => error.message);
		assert.match(page, message, JSON.stringify(params));
		assert.equal(page, file, `refused as presented.file refuses it: ${JSON.stringify(params)}`);
	}
	await assert.rejects(client.call("presented.picture", { id: chat1, presentation: "p1", version: 1, item: 1 }), (error: Error) => error.message === NOT_DRAWN, "a page not drawn is refused");

	// Answers that are not taken: from another connection, past a bound, for a draw never asked.
	assert.deepEqual(await other.call("present.drawn", { requestId: draw.requestId, ...drawnAnswer() }), { answered: false }, "from a connection that was not asked");
	await assert.rejects(client.call("present.drawn", { requestId: draw.requestId, ...drawnAnswer({ console: Array.from({ length: 51 }, () => "e") }) }), /the most is 50/);
	await assert.rejects(client.call("present.drawn", { requestId: draw.requestId, ...drawnAnswer({ snapshot: { mimeType: "image/png", data: pad(png(1, 1, false), 20 * MB + 3).toString("base64") } }) }), /larger than 20 MB/);
	assert.deepEqual(await client.call("present.drawn", { requestId: "present-999", ...drawnAnswer() }), { answered: false }, "a draw never asked for");
	assert.equal((await client.call("presented.list", { id: chat1 })).items[0].versions[0].items[1].snapshot.state, "pending", "nothing refused was stored");
	const snapshot = png(16, 10);
	assert.deepEqual(await client.call("present.drawn", { requestId: draw.requestId, ...drawnAnswer({ console: ["error: TypeError: null is not an object (evaluating 'form.addEventListener') at app.js:12", "log: ready"], blocked: ["https://cdn.tailwindcss.com/3.4.1"] }) }), { answered: true });
	assert.deepEqual(await client.call("present.drawn", { requestId: draw.requestId, ...drawnAnswer() }), { answered: false }, "once");
	const drawnEvent = await client.until("the snapshot in conversation.presented", () => client.presented.find((event) => event.id === chat1 && event.record.versions[0].items[1].snapshot.state === "drawn"));
	const drawnItem = drawnEvent.record.versions[0].items[1];
	assert.deepEqual(drawnItem.snapshot, { state: "drawn", sha256: sha(snapshot) });
	assert.deepEqual([drawnItem.width, drawnItem.height], [1280, 2140]);
	assert.deepEqual(drawnItem.drawn, { loadMs: 400, blank: false, console: ["error: TypeError: null is not an object (evaluating 'form.addEventListener') at app.js:12", "log: ready"], errors: 1, blocked: ["https://cdn.tailwindcss.com/3.4.1"] }, "every console line kept, and its errors counted");
	assert.deepEqual(await client.call("presented.picture", { id: chat1, presentation: "p1", version: 1, item: 1 }), { mimeType: "image/png", data: snapshot.toString("base64") });
	assert.deepEqual(readFileSync(join(scratchFolder(home, chat1), "presented", "p1-v1-B.png")), snapshot, "and in the scratch folder, for the agent");
	assert.equal(other.presented.length, 0, "conversation.presented goes only to connections that have the conversation open");
	step("an app that registers is asked to draw what is pending; present.drawn taken from it alone, within its bounds, for a draw asked for, once; the page's files by their manifest's paths alone");

	// ---- An update, drawn in time by the app

	client.drawing = () => drawnAnswer({ loadMs: 400, height: 2140, console: ["error: ReferenceError: x is not defined at app.js:1", "log: ready", "warn: deprecated"], blocked: ["https://fonts.example/a.woff2"] });
	writeFileSync(join(folder, "signin-b", "style.css"), "p { color: red }");
	const second = await client.present(chat1, {
		title: "Sign-in screen, three layouts",
		update: "p1",
		items: [{ path: "signin-a.png" }, { path: "signin-b/index.html" }, { path: "signin-c.svg", label: "Wide" }],
	});
	assert.equal(second.isError, false, second.text);
	const lines = second.text.split("\n");
	assert.equal(lines[0], 'Presented "Sign-in screen, three layouts" as p1, version 2. The person sees a card in the conversation and can open it in a window.');
	assert.match(lines[2]!, /^B {2}signin-b\/index\.html: page, 4 files, \d+ bytes; loaded in 0\.4 s; drawn 1280×2140 \(taller than the window: it scrolls\); 1 console error: "ReferenceError: x is not defined at app\.js:1"; 2 other console lines: "log: ready"; "warn: deprecated"; blocked, since the network is off: https:\/\/fonts\.example\/a\.woff2 \(put it in the folder instead\)$/);
	assert.equal(lines.at(-2), "Pictures of the pages as drawn: $PI2_SCRATCH/presented/p1-v2-B.png. Read it, or look at it, to check.");
	assert.ok(existsSync(join(scratchFolder(home, chat1), "presented", "p1-v2-B.png")));
	const record = (await client.call("presented.list", { id: chat1 })).items[0];
	assert.deepEqual(record.versions.map((version: Event) => version.version), [1, 2], "the older version is kept");
	assert.equal(record.versions[1].items[0].sha256, record.versions[0].items[0].sha256, "an unchanged picture is the same blob");
	assert.notEqual(record.versions[1].items[1].sha256, record.versions[0].items[1].sha256, "a changed page is a new manifest");
	assert.equal(readdirSync(blobs).filter((name) => name === sha(pictureBytes)).length, 1, "kept once");
	assert.deepEqual(Buffer.from((await client.call("presented.file", { id: chat1, presentation: "p1", version: 1, item: 1, path: "style.css" })).data, "base64").toString(), "p { color: teal }", "version 1 still serves its own files");
	// A page that draws nothing visible, and one that could not be drawn.
	client.drawing = (one) => (one.item === 0 ? drawnAnswer({ blank: true, height: 800, console: ["log: one", "debug: two"] }) : { ok: false, reason: "The page's web content process ended twice" });
	const blank = await client.present(chat1, { title: "Two pages", items: [{ path: "signin-b/index.html", label: "Empty" }, { path: "signin-b/index.html", label: "Broken" }] });
	assert.match(blank.text, /Empty {2}signin-b\/index\.html: page, 4 files, \d+ bytes; loaded in 0\.4 s; drawn 1280×800; \*\*it looks blank\*\*: nothing but its background was drawn, and its body has no text; 2 console lines, no errors: "log: one"; "debug: two"\n/);
	assert.match(blank.text, /Broken {2}signin-b\/index\.html: page, 4 files, \d+ bytes; could not be drawn: The page's web content process ended twice\n/);
	await assert.rejects(client.call("presented.picture", { id: chat1, presentation: "p2", version: 1, item: 1 }), (error: Error) => error.message === NOT_DRAWN, "a page that could not be drawn has no snapshot");
	step("an update: version 2 beside version 1, an unchanged file kept once, the page drawn in time and its findings in the answer; a blank page and one that failed said so");

	// ---- The requests: whole numbers in that conversation's record, and the conversation found as conversation.image finds it

	const ask = (params: Record<string, unknown>) => client.call("presented.picture", { id: chat1, presentation: "p1", version: 1, item: 0, ...params });
	assert.deepEqual(await ask({}), { mimeType: "image/png", data: pictureBytes.toString("base64") });
	assert.deepEqual(await ask({ sha256: sha(snapshot), path: "../x" }), { mimeType: "image/png", data: pictureBytes.toString("base64") }, "what the request says of a blob is not read");
	for (const [change, message] of [
		[{ presentation: "p9" }, NOT_PRESENTED],
		[{ version: 3 }, NOT_PRESENTED],
		[{ item: 3 }, NOT_PRESENTED],
		[{ presentation: "__proto__" }, /presentation must be/],
		[{ presentation: "p1/../p2" }, /presentation must be/],
		[{ version: "1" }, /version must be/],
		[{ version: 1.5 }, /version must be/],
		[{ item: -1 }, /item must be/],
		[{ item: "0" }, /item must be/],
		[{ id: "1" }, /id must be a conversation's number/],
	] as const) {
		await assert.rejects(ask(change), (error: Error) => (typeof message === "string" ? error.message === message : message.test(error.message)), JSON.stringify(change));
	}
	await assert.rejects(ask({ presentation: "p1", id: none }), (error: Error) => error.message === NOT_PRESENTED, "another conversation's record is not this one's");
	const unknown = await client.call("conversation.image", { id: 99_999, entryId: 1 }).catch((error: Error) => error.message);
	await assert.rejects(ask({ id: 99_999 }), (error: Error) => error.message === unknown, "an unknown conversation refused as conversation.image refuses it");
	assert.deepEqual((await client.call("presented.list", { id: chat })).items, [], "a chat is its version shown, which presented nothing");
	// Allow network is a version's: turned on for version 2, off and on again, each time written down; version 1 keeps it off.
	for (const allow of [true, false, true]) await client.call("presented.network", { id: chat1, presentation: "p1", version: 2, allow });
	const switched = await client.until("the network switch in conversation.presented", () => client.presented.filter((event) => event.record.id === "p1" && event.record.versions[1]?.network.changes.length === 3).at(-1));
	assert.equal(switched.record.versions[1].network.allowed, true);
	assert.deepEqual(switched.record.versions[1].network.changes.map((change: Event) => change.allow), [true, false, true]);
	assert.ok(switched.record.versions[1].network.changes.every((change: Event) => typeof change.at === "number"), "with when");
	assert.deepEqual(switched.record.versions[0].network, { allowed: false, changes: [] }, "version 1 keeps the network off");
	await assert.rejects(client.call("presented.network", { id: chat1, presentation: "p9", version: 1, allow: true }), (error: Error) => error.message === NOT_PRESENTED);
	await assert.rejects(client.call("presented.network", { id: chat1, presentation: "p1", version: 9, allow: true }), (error: Error) => error.message === NOT_PRESENTED);
	await assert.rejects(client.call("presented.network", { id: chat1, presentation: "p1", allow: true }), /version must be a whole number/);
	await assert.rejects(client.call("presented.network", { id: chat1, presentation: "p1", version: 2, allow: "yes" }), /allow must be true or false/);
	const version3 = await client.present(chat1, { title: "Sign-in screen, three layouts", update: "p1", items: [{ path: "signin-a.png" }] });
	assert.deepEqual(version3.details.network, { allowed: false, changes: [] }, "a new version starts with the network off, whatever an earlier one had");
	step("the requests take whole numbers found in that conversation's record only, never a blob's name, the conversation as conversation.image finds it; Allow network is a version's, every change written down, and a new version starts with it off");

	// ---- The question, waiting

	const waiting = client.present(chat1, { title: "Pick one", items: [{ path: "signin-a.png" }, { path: "signin-c.svg" }], question: "Which layout should I build?" });
	const decision = await client.until("the decision under Needs you", () => client.need((item) => item.kind === "decision" && item.blocking && item.question === "Which layout should I build?"));
	assert.deepEqual(decision.choices, [
		{ id: "c1", label: "Use A" },
		{ id: "c2", label: "Use B" },
	]);
	assert.equal(decision.words, true);
	assert.deepEqual(decision.presentation, { conversationId: chat1, presentation: "p3", version: 1 });
	assert.equal(client.events.inbox.items.find((item: Event) => item.id === decision.id).tool, "present");
	await assert.rejects(client.call("needs.answer", { id: decision.id, answer: { kind: "decision", choice: "c3" } }), /There is no choice c3/);
	await assert.rejects(client.call("needs.answer", { id: decision.id, answer: { kind: "approval", decision: "once" } }), /This is a decision, not a request for approval/);
	await client.call("needs.answer", { id: decision.id, answer: { kind: "decision", choice: "c2" } });
	await assert.rejects(client.call("needs.answer", { id: decision.id, answer: { kind: "decision", choice: "c1" } }), (error: Error) => error.message === GONE);
	const chose = await waiting;
	assert.match(chose.text, /\n\nThe person chose B\.$/);
	assert.deepEqual(chose.details.question.answer, { chose: "Use B" });
	const stored = (await client.call("presented.list", { id: chat1 })).items.find((one: Event) => one.id === "p3");
	assert.deepEqual(stored.versions[0].question, { text: "Which layout should I build?", choices: decision.choices, words: true, need: decision.id, answer: { chose: "Use B" } });
	// In words, through the old route too; with choices of the agent's own.
	const inWords = client.present(chat1, { title: "Pick", items: [{ path: "signin-a.png" }, { path: "signin-c.svg" }], question: "Which?", choices: ["Neither", "Both"] });
	const asked = await client.until("the second decision", () => client.need((item) => item.kind === "decision" && item.blocking && item.question === "Which?"));
	// Words are bounded on every route, the Mac's inbox.answer too, at Needs you's 20,000 characters (#994's read).
	for (const [method, params] of [
		["inbox.answer", { id: asked.id, text: "w".repeat(20_001) }],
		["needs.answer", { id: asked.id, answer: { kind: "decision", text: "w".repeat(20_001) } }],
		["needs.answer", { id: asked.id, answer: { kind: "question", text: "w".repeat(20_001) } }],
	] as const) {
		await assert.rejects(client.call(method, params), /An answer can be 20,000 characters at most; this one is 20,001/, method);
	}
	assert.ok(client.need((item) => item.id === asked.id), "and it still waits");
	await client.call("inbox.answer", { id: asked.id, text: "B, but with the warning colour of A" });
	assert.match((await inWords).text, /\n\nThe person answered: B, but with the warning colour of A$/);
	const custom = client.present(chat1, { title: "Pick", items: [{ path: "signin-a.png" }, { path: "signin-c.svg" }], question: "Keep any?", choices: ["Neither", "Both"] });
	const third = await client.until("the third decision", () => client.need((item) => item.kind === "decision" && item.blocking && item.question === "Keep any?"));
	await client.call("needs.answer", { id: third.id, answer: { kind: "decision", choice: "c1" } });
	assert.match((await custom).text, /\n\nThe person chose “Neither”\.$/);
	step("a question that waits: a blocking decision under Needs you with its presentation, answered once by a choice or in words, by either route, and the answer in the record");

	// A message instead of an answer; the run stopped.
	const messaged = client.present(chat1, { title: "Pick", items: [{ path: "signin-a.png" }, { path: "signin-c.svg" }], question: "Steered?" });
	const steered = await client.until("the decision to steer past", () => client.need((item) => item.question === "Steered?"));
	await client.call("submit", { id: chat1, text: "Never mind, carry on", mode: "steer" });
	assert.match((await messaged).text, /The person sent you a message instead of answering the question; it follows\. The question was taken away/);
	await client.until("taken away", () => client.need((item) => item.id === steered.id) === undefined && client.idle(chat1));
	const stoppedCall = client.call("submit", { id: chat1, text: `/tool present ${JSON.stringify({ title: "Pick", items: [{ path: "signin-a.png" }, { path: "signin-c.svg" }], question: "Stopped?" })}` });
	await stoppedCall;
	await client.until("the decision to stop", () => client.need((item) => item.question === "Stopped?"));
	await client.call("abort", { id: chat1 });
	await client.until("stopped", () => client.need((item) => item.question === "Stopped?") === undefined && client.idle(chat1));
	// Each end reaches the record, and the open conversation is sent it.
	const endOf = (question: string) => client.presented.flatMap((event) => event.record.versions).filter((version: Event) => version.question?.text === question).at(-1)?.question.answer;
	assert.deepEqual(await client.until("the steered question's end", () => endOf("Steered?")), { ended: "messaged" });
	assert.deepEqual(await client.until("the stopped question's end", () => endOf("Stopped?")), { ended: "stopped" });
	step("a question left unanswered: ended by a message from the person, or by stopping the run, each said in the record");

	// ---- wait: false, in a project

	const later = await client.present(chat1, { title: "Later", items: [{ path: "signin-a.png" }, { path: "signin-c.svg" }], question: "Which one, when you can?", wait: false });
	assert.match(later.text, /\n\nThe question is under Needs you; the answer comes to you as a message\.$/);
	const storedNeed = await client.until("the stored decision", () => client.need((item) => item.question === "Which one, when you can?"));
	assert.equal(storedNeed.blocking, false);
	assert.match(storedNeed.id, /^n\d+$/);
	assert.deepEqual(storedNeed.presentation, { conversationId: chat1, presentation: later.details.presentation, version: 1 });
	assert.equal(client.idle(chat1), true, "the agent is not held");
	await client.call("needs.answer", { id: storedNeed.id, answer: { kind: "decision", choice: "c1" } });
	await client.until("woken with the answer", () => client.items(chat1, "marker").some((item: Event) => item.details?.wake?.text?.includes("The person answered your question “Which one, when you can?”: Use A.")) && client.idle(chat1));
	const laterRecord = (await client.call("presented.list", { id: chat1 })).items.find((one: Event) => one.id === later.details.presentation);
	assert.deepEqual(laterRecord.versions[0].question.answer, { chose: "Use A" });
	const withdrawn = await client.present(chat1, { title: "Later", items: [{ path: "signin-a.png" }, { path: "signin-c.svg" }], question: "Withdraw me?", wait: false });
	const need = await client.until("the decision to withdraw", () => client.need((item) => item.question === "Withdraw me?"));
	assert.equal((await client.tool(chat1, `/tool needs_you ${JSON.stringify({ action: "withdraw", id: need.id })}`)).isError, false);
	const withdrawnRecord = (await client.call("presented.list", { id: chat1 })).items.find((one: Event) => one.id === withdrawn.details.presentation);
	assert.deepEqual(withdrawnRecord.versions[0].question.answer, { ended: "withdrawn" });
	step("wait: false in a project: a stored decision with its presentation, the agent not held; its answer wakes the agent and is in the record, and a withdrawal too");

	// ---- The conversation's limit, at its edge

	const holds = (await client.call("engine.info")).presented;
	assert.ok(holds.bytes > 0 && holds.conversations === 1, JSON.stringify(holds));
	const edge = png(7, 7);
	writeFileSync(join(folder, "edge.png"), edge);
	const folderBytes = () => ["blobs", "pages"].flatMap((part) => readdirSync(join(home, "presented", String(chat1), part)).map((name) => join(home, "presented", String(chat1), part, name))).reduce((sum, path) => sum + readFileSync(path).length, 0);
	// A file of no content and the size wanted (sparse, so it takes no space) brings the conversation to its edge.
	const filler = join(blobs, "filler");
	writeFileSync(filler, "");
	truncateSync(filler, 500 * MB - folderBytes() - edge.length);
	const atEdge = await client.present(chat1, { title: "Edge", items: [{ path: "edge.png" }] });
	assert.equal(atEdge.isError, false, atEdge.text);
	writeFileSync(join(folder, "past.png"), png(8, 8));
	const past = await client.present(chat1, { title: "Past", items: [{ path: "past.png" }] });
	assert.equal(past.isError, true);
	assert.match(past.text, /^This conversation already holds 500\.0 MB of presented files, and these would take it past 500 MB\. Present smaller files, or fewer, or in a new conversation\.$/);
	const again = await client.present(chat1, { title: "Again", items: [{ path: "edge.png" }] });
	assert.equal(again.isError, false, "a file it keeps already adds nothing");
	rmSync(filler);
	step("a conversation's 500 MB of distinct files, at its edge, counting only what it does not keep already; engine.info's presented");

	// ---- Fork, archive, delete, backup

	const lastEntry = client.conversations.get(chat1).items.at(-1).id;
	const fork = (await client.call("conversation.fork", { id: chat1, entryId: lastEntry })).id as number;
	await client.until("the fork's files", () => existsSync(join(home, "presented", String(fork), "blobs", sha(pictureBytes))));
	assert.deepEqual((await client.call("presented.list", { id: fork })).items, (await client.call("presented.list", { id: chat1 })).items, "a fork carries its records");
	assert.deepEqual(await client.call("presented.picture", { id: fork, presentation: "p1", version: 2, item: 1 }), await client.call("presented.picture", { id: chat1, presentation: "p1", version: 2, item: 1 }));
	await client.call("conversation.archive", { id: fork });
	const directory = mkdtempSync(join(work, "backups-"));
	backupPath = (await client.call("backup.create", { directory })).path;
	assert.deepEqual(readFileSync(join(backupPath, "presented", String(chat1), "blobs", sha(pictureBytes))), pictureBytes, "a backup holds the presented files");
	await client.call("conversation.delete", { id: chat1 });
	await client.until("the deleted conversation's files gone", () => !existsSync(join(home, "presented", String(chat1))));
	for (const method of ["presented.page", "presented.file"]) {
		await assert.rejects(client.call(method, { id: chat1, presentation: "p1", version: 1, item: 1, path: "style.css" }), /^Error: The presented files of this conversation are not there\.$/, `${method} of a deleted conversation`);
	}
	assert.ok(existsSync(join(home, "presented", String(fork), "blobs", sha(pictureBytes))), "the fork's own stay, archived");
	assert.deepEqual(await client.call("presented.picture", { id: fork, presentation: "p1", version: 1, item: 0 }), { mimeType: "image/png", data: pictureBytes.toString("base64") });
	step("a fork clones the files and carries the records; archived they stay; deleted they go; a backup holds them");
} finally {
	other?.close();
	client.close();
	await stop(engine);
}

// A restore brings them back, and puts what was there aside.
{
	const aside = restoreBackup(home, backupPath);
	assert.ok(existsSync(join(aside, "presented")), "what was there is put aside");
	assert.deepEqual(readFileSync(join(home, "presented", String(chat1), "blobs", sha(pictureBytes))), pictureBytes);
	engine = start(home, { PI2_PRESENT_DRAW_MS: String(11 * 60_000) });
	client = await Client.connect(engine, home);
	try {
		await client.until("the restored engine", () => client.events.library);
		assert.equal((await client.call("presented.list", { id: chat1 })).items[0].id, "p1", "and the records with the database");
		assert.deepEqual(await client.call("presented.picture", { id: chat1, presentation: "p1", version: 1, item: 0 }), { mimeType: "image/png", data: pictureBytes.toString("base64") });
	} finally {
		client.close();
		await stop(engine);
	}
	step("a restore brings the presented files back with the database");
}

// ---- The 20 seconds: a page not drawn in time is pending, and drawn when the app answers late

{
	const late = mkdtempSync(join(tmpdir(), "pi2-presented-late-"));
	process.on("exit", () => rmSync(late, { recursive: true, force: true }));
	const engine2 = start(late);
	const app = await Client.connect(engine2, late);
	try {
		await app.until("the engine's greeting", () => app.events.providers && app.events.agents);
		const project = await aProject(app, folder, ["forge"]);
		const id = (await app.call("conversation.create", { agentId: project.agents.forge })).id as number;
		await app.call("conversation.open", { id });
		await app.call("present.register");
		const result = await app.present(id, { title: "Late", items: [{ path: "signin-b/index.html" }] });
		assert.match(result.text, /\nA {2}signin-b\/index\.html: page, 4 files, \d+ bytes; not drawn yet: pi² did not draw it within 20 seconds\. The person sees it once it is drawn; nothing was checked\n/);
		const asked = app.draws.find((one) => one.conversationId === id)!;
		assert.deepEqual(await app.call("present.drawn", { requestId: asked.requestId, ...drawnAnswer() }), { answered: true }, "a late answer is taken");
		await app.until("the late snapshot", () => app.presented.some((event) => event.id === id && event.record.versions[0].items[0].snapshot.state === "drawn"));
		assert.equal((await app.call("presented.picture", { id, presentation: "p1", version: 1, item: 0 })).mimeType, "image/png");
	} finally {
		app.close();
		await stop(engine2);
	}
	step("the app has 20 seconds: a page not drawn by then is pending in the answer, and a late answer is stored and sent");
}
