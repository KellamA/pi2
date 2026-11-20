// The `edit` tool's loose matching (#575). An oldText that did not match the file byte for byte — a curly quotation
// mark for a straight one — was applied all the same, and the agent's slightly wrong newText written over a line the
// change never meant to alter, breaking a build; the tool answered the same "Successfully replaced" as for an exact
// match, so the agent could not see the mismatch. The lines the edit touched were written back from the
// fuzzy-normalised file as well, so the file's own quotation marks, dashes, spaces and trailing whitespace were lost
// on them. An edit may only ever change what the agent asked to change, so a match that is not exact is refused,
// before anything is written, with the file's own exact text for the place it nearly matched, so the agent can send it
// again exactly. Line endings keep today's tolerance: the file and the oldText are LF-normalised before the exact
// match, and the file's own endings are written back, as before.
const dir = "node_modules/@earendil-works/pi-durable/dist/tools/";
const patch = (file: string, why: string, find: string, replace: string) => ({ file: dir + file, why, find, replace });

export const EDIT_PATCHES = [
	patch(
		"edit-diff.js",
		"an oldText that matches only after the loose normalisation is refused, not applied",
		`    const initialMatches = normalizedEdits.map((edit) => fuzzyFindText(normalizedContent, edit.oldText));
    const usedFuzzyMatch = initialMatches.some((match) => match.usedFuzzyMatch);`,
		`    const initialMatches = normalizedEdits.map((edit) => fuzzyFindText(normalizedContent, edit.oldText));
    const usedFuzzyMatch = initialMatches.some((match) => match.usedFuzzyMatch);
    // Patched by pi2 (engine/scripts/patch-edit.ts, #575): an edit may only ever change what the agent asked to
    // change. A fuzzy match means the oldText was not in the file byte for byte: applying it would write the agent's
    // slightly wrong text, and a normalised rewrite of the file's own characters, over the lines it touched. Refuse
    // instead, with the file's own exact text for the place it nearly matched. Line endings are tolerated as before:
    // both the file and the oldText are LF-normalised before the exact match, and the file's own endings are kept.
    if (usedFuzzyMatch)
        throw nearMissError(path, normalizedContent, normalizedEdits, initialMatches);`,
	),
	patch(
		"edit-diff.js",
		"the refusal's message, with the file's own exact text for the place it nearly matched",
		`/**
 * Apply one or more exact-text replacements to LF-normalized content.`,
		`/**
 * Patched by pi2 (engine/scripts/patch-edit.ts, #575): the refusal for an oldText the loose matching would have
 * accepted — it differs from the file in quotation marks, dashes, spaces, trailing whitespace or NFKC lookalikes.
 * Nothing has been changed; the file's own exact text for the place it nearly matched is shown, so the agent can
 * send the oldText again as the file has it. A place too large to show is cut short and named by its lines instead.
 */
function nearMissError(path, normalizedContent, normalizedEdits, initialMatches) {
    const editIndex = initialMatches.findIndex((match) => match.usedFuzzyMatch);
    const named = normalizedEdits.length === 1 ? "The old text" : "edits[" + editIndex + "]'s oldText";
    const fuzzyContent = normalizeForFuzzyMatch(normalizedContent);
    const match = initialMatches[editIndex];
    // The line a position falls on: the normalisation keeps the file's lines (it strips only trailing whitespace
    // within them), so a position in normalised space is the same line of the file's own text. A match ending in a
    // line's own newline ends on that line, not on the empty one after it.
    const lineOf = (pos) => fuzzyContent.slice(0, pos).split("\\n").length - 1;
    const startLine = lineOf(match.index);
    const endLine = lineOf(match.index + Math.max(1, match.matchLength) - 1);
    const lines = normalizedContent.split("\\n");
    // Enough of the file's own text for the agent to copy, without putting a whole file in the refusal.
    const SHOWN_LINES = 40;
    const SHOWN_CHARACTERS = 4000;
    let shown = lines[startLine] ?? "";
    let upto = startLine + 1;
    while (upto <= endLine && upto < startLine + SHOWN_LINES && (shown + "\\n" + lines[upto]).length <= SHOWN_CHARACTERS) {
        shown += "\\n" + lines[upto];
        upto++;
    }
    const where = endLine === startLine ? "line " + (startLine + 1) : "lines " + (startLine + 1) + "-" + (endLine + 1);
    return new Error(named + " is not in " + path + " exactly: it differs from the file in quotation marks, dashes, spaces, trailing whitespace or lookalike characters, and an edit changes only text that matches exactly. Nothing was changed. The file's own text on " + where + ":\\n\\n" + shown + (upto <= endLine
        ? "\\n…\\nRead " + path + " from line " + (upto + 1) + " for the rest of it, and send the oldText again copied from the file exactly."
        : "\\n\\nSend the oldText again copied from the file exactly."));
}

/**
 * Apply one or more exact-text replacements to LF-normalized content.`,
	),
];
