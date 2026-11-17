
// Changelog entries wait in changelog.d, one file each, until a release gathers them into CHANGELOG.md. Two pull
// requests then never add to the same lines, as they did when every entry went into one Unreleased list (#237).
//
//   node app/changelog.mjs check                          every entry is well formed, and Unreleased holds none
//   node app/changelog.mjs notes <version>                the notes the next version would have, as release.sh writes them
//   node app/changelog.mjs release <version> [--dry-run]  gather the entries into a "## <version>" section and remove them
//
// An entry file is named <issue>.md (or <issue>-<word>.md for a second one) and holds a heading, then the entry:
//
//   ### Fixed
//   - What used to go wrong, and what happens now.
import { readdirSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { releaseNotes } from "./release-notes.mjs";

/** The headings an entry may go under, in the order a version's section has them. For contributors comes last. */
export const HEADINGS = ["Added", "Changed", "Fixed", "For contributors"];
const NAME = /^(\d+)(-[a-z0-9]+)*\.md$/;
const VERSION = /^\d+\.\d+\.\d+$/;

/** One entry file's heading and lines, or the problems with it. */
export function parseEntry(name, text) {
	const problems = [];
	const match = NAME.exec(name);
	if (!match) problems.push("name it after its issue, such as 237.md, or 237-two.md for a second entry");
	if (text.includes("\r")) problems.push("use plain newlines, not carriage returns");
	const lines = text.replace(/\n+$/, "").split("\n");
	const heading = HEADINGS.find((h) => lines[0] === `### ${h}`);
	if (!heading) problems.push(`start with one of ${HEADINGS.map((h) => `"### ${h}"`).join(", ")}, on a line of its own`);
	const body = lines.slice(1);
	if (!body.length || !body[0].startsWith("- ")) problems.push('put the entry on the line after the heading, as a list item starting with "- "');
	body.forEach((line, i) => {
		if (/^(- \S|  +\S)/.test(line)) return;
		problems.push(`line ${i + 2}: ${line.trim() ? "a heading or other text" : "a blank line"} would end the list; every line is "- " and an entry, or indented to continue one`);
	});
	if (problems.length) return { name, problems };
	return { name, number: Number(match[1]), heading, lines: body };
}

/** The entries in a folder, in the order they are gathered: by issue number, then by name. README.md is not one. */
export function readEntries(folder) {
	const entries = [];
	const problems = [];
	for (const name of readdirSync(folder).sort()) {
		if (name === "README.md" || name.startsWith(".")) continue;
		const entry = parseEntry(name, readFileSync(join(folder, name), "utf8"));
		if (entry.problems) problems.push(...entry.problems.map((p) => `changelog.d/${name}: ${p}`));
		else entries.push(entry);
	}
	const stem = (entry) => entry.name.slice(0, -".md".length);
	entries.sort((a, b) => a.number - b.number || (stem(a) < stem(b) ? -1 : 1));
	return { entries, problems };
}

/** Where the version sections start, after Unreleased, and any problems with Unreleased. */
function unreleased(changelog) {
	const lines = changelog.split("\n");
	const start = lines.indexOf("## Unreleased");
	if (start < 0) return { problems: ['CHANGELOG.md needs its "## Unreleased" heading'] };
	let end = lines.findIndex((line, i) => i > start && line.startsWith("## "));
	if (end < 0) end = lines.length;
	const problems = lines.slice(start + 1, end).some((line) => /^(#|- |\* )/.test(line))
		? ["CHANGELOG.md's Unreleased section holds entries: move each into a file of its own in changelog.d, as CONTRIBUTING.md says"]
		: [];
	return { lines, end, problems };
}

/** A version's section as the release has it: the headings in order, each with its entries, a blank line between. */
export function section(version, entries) {
	const blocks = HEADINGS.map((heading) => entries.filter((e) => e.heading === heading).flatMap((e) => e.lines))
		.map((lines, i) => (lines.length ? `### ${HEADINGS[i]}\n${lines.join("\n")}\n` : ""))
		.filter(Boolean);
	return `## ${version}\n\n${blocks.join("\n")}\n`;
}

/** CHANGELOG.md with the entries gathered into a section for `version`, under Unreleased; throws if it cannot be released. */
export function gather(changelog, entries, version) {
	const text = merge(changelog, entries, version);
	if (!entries.some((e) => e.heading !== "For contributors")) {
		throw new Error("changelog.d has only For contributors entries, and a release needs reader-facing notes: an entry under Added, Changed or Fixed.");
	}
	releaseNotes(text, version); // Fails, before anything is written, wherever release.sh would.
	return text;
}

function merge(changelog, entries, version) {
	if (!VERSION.test(version)) throw new Error(`"${version}" is not a version such as 0.7.9.`);
	if (!entries.length) throw new Error("changelog.d has no entries: there is nothing to release.");
	const { lines, end, problems } = unreleased(changelog);
	if (problems.length) throw new Error(problems.join("\n"));
	if (lines.includes(`## ${version}`)) throw new Error(`CHANGELOG.md already has a section for ${version}.`);
	return [...lines.slice(0, end), ...section(version, entries).split("\n").slice(0, -1), ...lines.slice(end)].join("\n");
}

/** What `check` reports: every problem with the entries and with Unreleased. */
export function problems(root) {
	return [...readEntries(join(root, "changelog.d")).problems, ...unreleased(readFileSync(join(root, "CHANGELOG.md"), "utf8")).problems];
}

function main(root, [command, version, ...rest]) {
	const changelogPath = join(root, "CHANGELOG.md");
	const folder = join(root, "changelog.d");
	if (command === "check" && version === undefined) {
		const found = problems(root);
		if (found.length) throw new Error(found.join("\n"));
		console.log(`${readEntries(folder).entries.length} changelog entries, all well formed.`);
		return;
	}
	const dryRun = rest.length === 1 && rest[0] === "--dry-run";
	if (!["notes", "release"].includes(command) || !version || (rest.length && !(command === "release" && dryRun))) {
		throw new Error("Usage: node app/changelog.mjs check | notes <version> | release <version> [--dry-run]");
	}
	const { entries, problems: bad } = readEntries(folder);
	if (bad.length) throw new Error(bad.join("\n"));
	const changelog = readFileSync(changelogPath, "utf8");
	if (dryRun) {
		// Shows the section even when it could not be released yet, as with only For contributors entries.
		merge(changelog, entries, version);
		process.stdout.write(section(version, entries));
		return;
	}
	const text = gather(changelog, entries, version);
	if (command === "notes") return void process.stdout.write(releaseNotes(text, version));
	const set = readFileSync(join(root, "app", "VERSION"), "utf8").trim();
	if (set !== version) throw new Error(`app/VERSION says ${set}. Set it to ${version} first, as docs/releasing.md says.`);
	writeFileSync(changelogPath, text);
	for (const entry of entries) rmSync(join(folder, entry.name));
	console.log(`Gathered ${entries.length} entries into CHANGELOG.md's ${version} section and removed their files.`);
}

if (process.argv[1] && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) {
	try {
		main(fileURLToPath(new URL("..", import.meta.url)), process.argv.slice(2));
	} catch (error) {
		console.error(error.message);
		process.exitCode = 1;
	}
}
