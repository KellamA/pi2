import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { parseEntry, problems, readEntries } from "./changelog.mjs";
import { releaseNotes } from "./release-notes.mjs";

const helper = fileURLToPath(new URL("release-notes.mjs", import.meta.url));
const changelog = readFileSync(new URL("../CHANGELOG.md", import.meta.url), "utf8");

for (const [name, section, expected] of [
	["without the heading", "\n### Added\n- A change.\n\n", "\n### Added\n- A change.\n\n"],
	["heading last", "\n### Added\n- A change.\n\n### For contributors\n- Only for builders.\n\n", "\n### Added\n- A change.\n\n"],
	["heading in the middle", "### Added\n- Visible.\n### For contributors\n- Hidden.\n#### Fixed\n- Hidden too.\n### Fixed\n- Visible again.\n", "### Added\n- Visible.\n### Fixed\n- Visible again.\n"],
	["heading first", "### For contributors\n- Hidden.\n### Changed\n- Visible.\n", "### Changed\n- Visible.\n"],
	["repeated heading", "- Visible.\n### For contributors\n- Hidden.\n### Fixed\n- Visible again.\n### For contributors\n- Hidden again.\n", "- Visible.\n### Fixed\n- Visible again.\n"],
	["heading with trailing spaces", "- Visible.\n### For contributors  \n- Hidden.\n", "- Visible.\n"],
	["no final newline", "- Visible.", "- Visible.\n"],
]) {
	test(`extract a section ${name}`, () => {
		assert.equal(releaseNotes(`# Changelog\n## Other\n- Not this one.\n## 1.2.3\n${section}${section.endsWith("\n") ? "## Older\n- Nor this one.\n" : ""}`, "1.2.3"), expected);
	});
}

test("a hidden section does not hide the next version", () => {
	assert.equal(releaseNotes("## Unreleased\n### For contributors\n- Hidden.\n## 1.2.3\n- Visible.\n", "1.2.3"), "- Visible.\n");
});

test("docs links stay absolute and external links stay as written", () => {
	assert.equal(releaseNotes("## 1.2.3\nSee [worktrees](docs/worktrees.md#sub-chats) and [web](https://example.com).\n", "1.2.3"),
		"See [worktrees](https://github.com/KellamA/pi2/blob/v1.2.3/docs/worktrees.md#sub-chats) and [web](https://example.com).\n");
});

test("missing, duplicate, empty and contributor-only versions fail closed", () => {
	for (const source of ["## 1.2.30\n- Wrong version.\n", "## 1.2.3\n- One.\n## 1.2.3\n- Two.\n", "## 1.2.3\n\n", "## 1.2.3\n### For contributors\n- Hidden.\n"]) {
		assert.throws(() => releaseNotes(source, "1.2.3"), /exactly one section|no reader-facing notes/);
	}
});

// SHA-256 of the former release.sh awk+sed extraction at v0.7.6, before For contributors existed. Both versions are
// already published, so even 0.7.5's builder-only entries are deliberately kept as they were. No fixture drift.
for (const [version, digest] of [
	["0.7.5", "e456be69ff3318b8cf135c6ad7463d38e3224db91efa88d36519de0ee865995c"],
	["0.7.6", "668cb848f7f8fee7a80cd8572238d32759dbc7d6159b9a833bdfc7ababff1afa"],
]) {
	test(`${version}'s published notes are byte-for-byte unchanged`, () => {
		const notes = releaseNotes(changelog, version);
		assert.equal(createHash("sha256").update(notes).digest("hex"), digest);
		assert.equal(execFileSync(process.execPath, [helper, version], { encoding: "utf8" }), notes);
	});
}

test("the release.sh command works on a sample file and fails without emitting partial notes", () => {
	const folder = mkdtempSync(join(tmpdir(), "pi2-notes-"));
	try {
		const file = join(folder, "sample changelog.md");
		writeFileSync(file, "## 1.2.3\n- Reader change.\n### For contributors\n- Builder change.\n### Fixed\n- Reader fix.\n");
		const result = spawnSync(process.execPath, [helper, "1.2.3", file], { encoding: "utf8" });
		assert.equal(result.status, 0, result.stderr);
		assert.equal(result.stdout, "- Reader change.\n### Fixed\n- Reader fix.\n");
		const absent = spawnSync(process.execPath, [helper, "9.9.9", file], { encoding: "utf8" });
		assert.equal(absent.status, 1);
		assert.equal(absent.stdout, "");
		assert.match(absent.stderr, /exactly one section for 9.9.9/);
	} finally {
		rmSync(folder, { recursive: true, force: true });
	}
});

test("GitHub notes and the update feed have the same source", () => {
	const script = readFileSync(new URL("release.sh", import.meta.url), "utf8");
	assert.match(script, /node release-notes\.mjs "\$VERSION" > "\$OUT\/notes\.md"/);
	assert.match(script, /NOTES="\$\(sed .* "\$OUT\/notes\.md"\)"/);
	assert.match(script, /<description sparkle:format="markdown"><!\[CDATA\[\$NOTES\]\]><\/description>/);
});

// Changelog entries, a file each in changelog.d until a release gathers them (#237).

test("every entry in changelog.d is well formed, and Unreleased holds none", () => {
	assert.deepEqual(problems(fileURLToPath(new URL("..", import.meta.url))), []);
});

test("an entry file that is not well formed says what is wrong", () => {
	assert.deepEqual(parseEntry("12.md", "### Fixed\n- A fix,\n  over two lines.\n- And another.\n\n"), {
		name: "12.md", number: 12, heading: "Fixed", lines: ["- A fix,", "  over two lines.", "- And another."],
	});
	assert.equal(parseEntry("12-second.md", "### For contributors\n- Builders only.").heading, "For contributors");
	for (const [name, text, problem] of [
		["fix.md", "### Fixed\n- A fix.\n", /name it after its issue/],
		["12.MD", "### Fixed\n- A fix.\n", /name it after its issue/],
		["12.md", "### Removed\n- A fix.\n", /start with one of/],
		["12.md", "### Fixed \n- A fix.\n", /start with one of/],
		["12.md", "- A fix.\n", /start with one of/],
		["12.md", "### Fixed\n", /as a list item/],
		["12.md", "### Fixed\n\n- A fix.\n", /line 2: a blank line/],
		["12.md", "### Fixed\nA fix.\n", /as a list item/],
		["12.md", "### Fixed\n- A fix.\n\n- Another.\n", /line 3: a blank line/],
		["12.md", "### For contributors\n- A fix.\n#### Tests\n- Another.\n", /line 3: a heading/],
		["12.md", "### Fixed\n- A fix.\n## 9.9.9\n", /line 3: a heading/],
		["12.md", "### Fixed\r\n- A fix.\r\n", /carriage returns/],
	]) {
		const entry = parseEntry(name, text);
		assert.ok(entry.problems?.some((p) => problem.test(p)), `${name} ${JSON.stringify(text)}: ${JSON.stringify(entry.problems)}`);
	}
});

/** A folder laid out like the repository, with the scripts, a changelog, app/VERSION and entry files. */
function sandbox(changelogText, entries, version = "1.2.3") {
	const root = mkdtempSync(join(tmpdir(), "pi2-changelog-"));
	mkdirSync(join(root, "app"));
	mkdirSync(join(root, "changelog.d"));
	for (const name of ["changelog.mjs", "release-notes.mjs"]) copyFileSync(new URL(name, import.meta.url), join(root, "app", name));
	writeFileSync(join(root, "app", "VERSION"), `${version}\n`);
	writeFileSync(join(root, "CHANGELOG.md"), changelogText);
	writeFileSync(join(root, "changelog.d", "README.md"), "# Not an entry\n\nSome text.\n");
	for (const [name, text] of Object.entries(entries)) writeFileSync(join(root, "changelog.d", name), text);
	const run = (...args) => spawnSync(process.execPath, [join(root, "app", "changelog.mjs"), ...args], { encoding: "utf8" });
	const read = () => readFileSync(join(root, "CHANGELOG.md"), "utf8");
	const files = () => readdirSync(join(root, "changelog.d")).sort();
	return { root, run, read, files, [Symbol.dispose]: () => rmSync(root, { recursive: true, force: true }) };
}

const plain = "# Changelog\n\nIntro.\n\n## Unreleased\n\nSee changelog.d.\n\n## 1.2.2\n\n### Fixed\n- Older.\n";

test("0.7.8's published section is what gathering its entries from files makes, byte for byte", () => {
	// The changelog as it was when 0.7.8 was the newest version: a release puts its section first, so the sections of
	// later versions, which sit above 0.7.8's, are left out.
	const then = changelog.slice(0, changelog.search(/^## \d/m)) + changelog.slice(changelog.indexOf("## 0.7.8\n"));
	const start = then.indexOf("## 0.7.8\n");
	const end = then.indexOf("## 0.7.7\n");
	const entries = {};
	let heading;
	for (const line of then.slice(start, end).split("\n").slice(1)) {
		if (line.startsWith("### ")) heading = line;
		else if (line.startsWith("- ")) entries[`${Object.keys(entries).length + 1}.md`] = `${heading}\n${line}\n`;
		else assert.equal(line, "");
	}
	assert.ok(Object.keys(entries).length > 20);
	using box = sandbox(then.slice(0, start) + then.slice(end), entries, "0.7.8");
	const result = box.run("release", "0.7.8");
	assert.equal(result.status, 0, result.stderr);
	assert.equal(box.read(), then);
	assert.deepEqual(box.files(), ["README.md"]);
	assert.equal(releaseNotes(box.read(), "0.7.8"), releaseNotes(changelog, "0.7.8"));
});

test("entries are gathered by heading and then by issue number, For contributors last", () => {
	using box = sandbox(plain, {
		"10.md": "### Fixed\n- Ten.\n",
		"2.md": "### Fixed\n- Two, see [limits](docs/limits.md).\n",
		"1.md": "### For contributors\n- One.\n",
		"3-second.md": "### Added\n- Three, second.\n",
		"3.md": "### Added\n- Three.\n",
		"5.md": "### Changed\n- Five,\n  continued.\n",
	});
	const section = "## 1.2.3\n\n### Added\n- Three.\n- Three, second.\n\n### Changed\n- Five,\n  continued.\n\n### Fixed\n- Two, see [limits](docs/limits.md).\n- Ten.\n\n### For contributors\n- One.\n\n";
	const dry = box.run("release", "1.2.3", "--dry-run");
	assert.equal(dry.status, 0, dry.stderr);
	assert.equal(dry.stdout, section);
	const notes = box.run("notes", "1.2.3");
	assert.equal(notes.status, 0, notes.stderr);
	assert.equal(notes.stdout, "\n### Added\n- Three.\n- Three, second.\n\n### Changed\n- Five,\n  continued.\n\n### Fixed\n- Two, see [limits](https://github.com/KellamA/pi2/blob/v1.2.3/docs/limits.md).\n- Ten.\n\n");
	assert.equal(box.files().length, 7, "a preview removes nothing");
	assert.equal(box.read(), plain);
	const release = box.run("release", "1.2.3");
	assert.equal(release.status, 0, release.stderr);
	assert.equal(box.read(), plain.replace("## 1.2.2", `${section}## 1.2.2`));
	assert.deepEqual(box.files(), ["README.md"]);
	// What release.sh then writes to notes.md and the feed is what `notes` showed.
	assert.equal(execFileSync(process.execPath, [join(box.root, "app", "release-notes.mjs"), "1.2.3"], { encoding: "utf8" }), notes.stdout);
});

test("a release that cannot be made changes nothing and says why", () => {
	const fix = { "7.md": "### Fixed\n- A fix.\n" };
	for (const [name, text, entries, args, error] of [
		["no entries", plain, {}, ["release", "1.2.3"], /nothing to release/],
		["only For contributors", plain, { "7.md": "### For contributors\n- Builders.\n" }, ["release", "1.2.3"], /reader-facing notes/],
		["a bad entry", plain, { ...fix, "8.md": "### Fixed\n\n- Gap.\n" }, ["release", "1.2.3"], /8\.md: line 2/],
		["an existing section", plain, fix, ["release", "1.2.2"], /already has a section for 1\.2\.2/],
		["entries under Unreleased", plain.replace("See changelog.d.", "### Fixed\n- Old way."), fix, ["release", "1.2.3"], /Unreleased section holds entries/],
		["no Unreleased", plain.replace("## Unreleased", "## Next"), fix, ["release", "1.2.3"], /needs its "## Unreleased" heading/],
		["another app/VERSION", plain, fix, ["release", "1.2.4"], /app\/VERSION says 1\.2\.3/],
		["not a version", plain, fix, ["release", "v1.2.3"], /not a version/],
		["a wrong argument", plain, fix, ["release", "1.2.3", "--dry"], /Usage/],
	]) {
		using box = sandbox(text, entries);
		const before = box.files();
		const result = box.run(...args);
		assert.equal(result.status, 1, name);
		assert.match(result.stderr, error, name);
		assert.equal(result.stdout, "", name);
		assert.equal(box.read(), text, name);
		assert.deepEqual(box.files(), before, name);
	}
});

test("check fails on a bad entry and on entries under Unreleased", () => {
	using box = sandbox(plain.replace("See changelog.d.", "- Old way."), { "7.md": "### Fixed\n- A fix.\n", "notes.txt": "x" });
	const result = box.run("check");
	assert.equal(result.status, 1);
	assert.match(result.stderr, /changelog\.d\/notes\.txt: name it after its issue/);
	assert.match(result.stderr, /Unreleased section holds entries/);
	assert.equal(readEntries(join(box.root, "changelog.d")).entries.length, 1);
	writeFileSync(join(box.root, "CHANGELOG.md"), plain);
	rmSync(join(box.root, "changelog.d", "notes.txt"));
	assert.equal(box.run("check").stdout, "1 changelog entries, all well formed.\n");
	assert.ok(existsSync(join(box.root, "changelog.d", "7.md")));
});
