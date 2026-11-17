// The one extraction used by release.sh for both GitHub's notes.md and Sparkle's description.
// Usage: node app/release-notes.mjs <version> [CHANGELOG.md]
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

export function releaseNotes(changelog, version) {
	let inside = false;
	let contributors = false;
	let found = 0;
	const notes = [];
	// Like the former awk extraction, write each kept line with a newline, even if the source ends without one.
	const lines = changelog.split("\n");
	if (lines.at(-1) === "") lines.pop();
	for (const line of lines) {
		if (line.startsWith("## ")) {
			inside = line.trimEnd() === `## ${version}`;
			contributors = false;
			if (inside) found++;
			continue;
		}
		if (!inside) continue;
		// #### subheadings belong to For contributors; the next ### starts a reader-facing category again.
		if (line.startsWith("### ")) contributors = line.trimEnd() === "### For contributors";
		if (!contributors) notes.push(line);
	}
	if (found !== 1) throw new Error(`CHANGELOG.md must have exactly one section for ${version}; found ${found}.`);
	const text = notes.join("\n") + "\n";
	if (!text.trim()) throw new Error(`CHANGELOG.md has no reader-facing notes for ${version}.`);
	return text.replace(/\]\((docs\/[^)]*)\)/g, `](https://github.com/KellamA/pi2/blob/v${version}/$1)`);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
	try {
		if (process.argv.length < 3 || process.argv.length > 4) throw new Error("Usage: node app/release-notes.mjs <version> [CHANGELOG.md]");
		const changelog = process.argv[3] ?? fileURLToPath(new URL("../CHANGELOG.md", import.meta.url));
		process.stdout.write(releaseNotes(readFileSync(changelog, "utf8"), process.argv[2]));
	} catch (error) {
		console.error(error.message);
		process.exitCode = 1;
	}
}
