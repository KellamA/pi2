import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
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
