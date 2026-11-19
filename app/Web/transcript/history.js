/*
 * Entries that arrive before those the page has (#380). The engine sends a long conversation newest first, then the
 * older entries in parts, each to go above the first row. This puts their ids in front of the page's order, and keeps
 * the row the reader is looking at where it is on screen while rows are put above it.
 *
 * Entries older than the engine's window come when the page asks (#440): when the reader nears the top of what it has
 * (`wantsOlder`), or when a turn's Copy needs the start of a turn the page does not have yet (`turnCut`).
 *
 * Pure functions, so Node can test them. Loaded as a plain script by the page (it sets `PiHistory`).
 */
(function (root, factory) {
	const api = factory();
	if (typeof module === "object" && module.exports) module.exports = api;
	else root.PiHistory = api;
})(typeof globalThis !== "undefined" ? globalThis : this, function () {
	"use strict";

	/** What the page says at the top while older entries are still to come. */
	const LOADING = "Loading earlier entries" + String.fromCharCode(0x2026);

	/**
	 * `order` with `older` (ids, oldest first) in front of it, leaving out any it has already (`known.has`) and any given
	 * twice, and the ids that were added.
	 */
	function prepend(order, known, older) {
		const added = [];
		const seen = new Set();
		for (const id of older) {
			if (known.has(id) || seen.has(id)) continue;
			seen.add(id);
			added.push(id);
		}
		return { order: added.length === 0 ? order : added.concat(order), added };
	}

	/**
	 * The row to keep in place: the first of `rows` (in order down the page) whose bottom is below the top of the view,
	 * and where its top is now. `rect(row)` is where the row is on screen, as `getBoundingClientRect()` gives it. Rows
	 * go down the page in order, so this looks by halves rather than measuring every row above the one on screen.
	 */
	function anchor(rows, rect) {
		let low = 0;
		let high = rows.length;
		while (low < high) {
			const middle = (low + high) >> 1;
			if (rect(rows[middle]).bottom > 0) high = middle;
			else low = middle + 1;
		}
		if (low >= rows.length) return null;
		return { row: rows[low], top: rect(rows[low]).top };
	}

	/** How far to scroll so that the anchor's row is back where it was: 0 when it moved nowhere or is gone. */
	function shift(kept, rect) {
		if (!kept || !kept.row.isConnected) return 0;
		return rect(kept.row).top - kept.top;
	}

	/**
	 * How to keep a row in place when it moved down by `by` pixels: the page scrolls by whole pixels, and rows are
	 * fractions of one high, so scroll by the whole pixel above it and take up what is left with a sliver of space at the
	 * top of the page, `pad`, kept under a pixel. Gives the scroll and the new sliver; together they move the row back by
	 * exactly `by`.
	 */
	function settle(by, pad) {
		let scroll = Math.ceil(by);
		let next = pad + (scroll - by);
		if (next >= 1) {
			next -= 1;
			scroll -= 1;
		}
		return { scroll, pad: next };
	}

	/** How near the top the reader is, in screens, when the page asks for older entries. */
	const NEAR = 2;

	/**
	 * Whether the page asks for the part before the entries it has: there are older ones to ask for (`more`), nothing is
	 * on its way already (`earlier`, `loading`, `asked`), and the reader is within NEAR screens of the top, or `now`.
	 */
	function wantsOlder({ more, loading, asked, earlier, scrollTop, height, now = false }) {
		if (!more || loading || asked || earlier > 0) return false;
		return now || scrollTop < NEAR * height;
	}

	/**
	 * Whether the turn that ends at `index` of `visible` (the page's entries, tool results left out) may start before the
	 * first entry the page has: older entries may be still to come, and the turn's answers run back to the first entry.
	 */
	function turnCut(visible, index, olderToCome) {
		if (!olderToCome || index < 0 || index >= visible.length || visible[index].kind !== "assistant") return false;
		let start = index;
		while (start > 0 && visible[start - 1].kind === "assistant") start--;
		return start === 0 && visible[0].kind === "assistant";
	}

	return { LOADING, NEAR, prepend, anchor, shift, settle, wantsOlder, turnCut };
});
