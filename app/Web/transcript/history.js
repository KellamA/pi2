/*
 * Entries that arrive before those the page has (#380). The engine sends a long conversation newest first, then the
 * older entries in parts, each to go above the first row. This puts their ids in front of the page's order, and keeps
 * the row the reader is looking at where it is on screen while rows are put above it.
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

	return { LOADING, prepend, anchor, shift };
});
