import assert from "node:assert/strict";
import { test } from "node:test";
import H from "../transcript/history.js";

test("older entries go in front of the page's order, once each", () => {
	const known = new Set([5, 6, 7]);
	assert.deepEqual(H.prepend([5, 6, 7], known, [2, 3, 4]), { order: [2, 3, 4, 5, 6, 7], added: [2, 3, 4] });
	// One the page has already, or one given twice, is left out.
	assert.deepEqual(H.prepend([5, 6, 7], known, [3, 3, 5, 4]), { order: [3, 4, 5, 6, 7], added: [3, 4] });
	// Nothing new leaves the order as it was.
	const order = [5, 6, 7];
	assert.equal(H.prepend(order, known, [5, 6]).order, order);
	assert.deepEqual(H.prepend([], new Set(), [1, 2]), { order: [1, 2], added: [1, 2] });
});

/** Rows of the given heights down a page scrolled to `scrollTop`, measured as getBoundingClientRect would. */
function page(heights, scrollTop) {
	const rows = heights.map((height, index) => ({ index, height, isConnected: true }));
	const layout = { rows, scrollTop };
	layout.rect = (row) => {
		let top = -layout.scrollTop;
		for (const other of layout.rows) {
			if (other === row) return { top, bottom: top + row.height };
			top += other.height;
		}
		throw new Error("not on the page");
	};
	return layout;
}

test("the row kept in place is the first whose bottom is in view", () => {
	const view = page([100, 100, 100, 100], 150);
	const kept = H.anchor(view.rows, view.rect);
	assert.equal(kept.row.index, 1, "the second row, half above the view");
	assert.equal(kept.top, -50);
	// At the top of the page, the first row.
	const top = page([100, 100], 0);
	assert.equal(H.anchor(top.rows, top.rect).row.index, 0);
	// A row that ends exactly at the top of the view is above it.
	const exact = page([100, 100, 100], 100);
	assert.equal(H.anchor(exact.rows, exact.rect).row.index, 1);
	// Scrolled past every row (or no rows): nothing to keep.
	const past = page([100, 100], 500);
	assert.equal(H.anchor(past.rows, past.rect), null);
	assert.equal(H.anchor([], () => ({ top: 0, bottom: 0 })), null);
});

test("it is found by halves, measuring few rows", () => {
	const view = page(Array.from({ length: 1000 }, () => 50), 30_000);
	let measured = 0;
	const kept = H.anchor(view.rows, (row) => {
		measured++;
		return view.rect(row);
	});
	assert.equal(kept.row.index, 600);
	assert.ok(measured <= 12, `measured ${measured} rows`);
});

test("rows put above move the page by just what keeps the row on screen where it was", () => {
	const view = page([100, 100, 100, 100], 250);
	const kept = H.anchor(view.rows, view.rect);
	const before = view.rect(kept.row).top;
	// Three older rows arrive above.
	view.rows = [{ height: 80, isConnected: true }, { height: 120, isConnected: true }, { height: 60, isConnected: true }, ...view.rows];
	const by = H.shift(kept, view.rect);
	assert.equal(by, 260);
	view.scrollTop += by;
	assert.equal(view.rect(kept.row).top, before, "the row is where it was");
	assert.equal(H.shift(kept, view.rect), 0, "and nothing more to do");
	// Nothing kept, or the row rebuilt and gone: nothing to do.
	assert.equal(H.shift(null, view.rect), 0);
	assert.equal(H.shift({ row: { isConnected: false }, top: 0 }, view.rect), 0);
});

test("what is left of a pixel goes in a sliver at the top, so the row moves back by exactly as far as it went", () => {
	let pad = 0;
	let scrolled = 0;
	let moved = 0;
	// Rows a fraction of a pixel high, arriving above part after part.
	for (const by of [260.33, 12.5, 0.4, 99.98, 7, -30.25, 0.75]) {
		const step = H.settle(by, pad);
		assert.ok(Number.isInteger(step.scroll), "the page scrolls by whole pixels");
		assert.ok(step.pad >= 0 && step.pad < 1, `the sliver stays under a pixel (${step.pad})`);
		moved += by + (step.pad - pad);
		scrolled += step.scroll;
		pad = step.pad;
		assert.ok(Math.abs(moved - scrolled) < 1e-9, `the row is back where it was (${moved - scrolled})`);
	}
});

test("the line at the top says older entries are coming", () => {
	assert.match(H.LOADING, /^Loading earlier entries…$/);
});

test("older entries are asked for when the reader nears the top, and only then (#440)", () => {
	const idle = { more: true, loading: false, asked: false, earlier: 0, height: 800 };
	// Within two screens of the top: ask.
	assert.equal(H.wantsOlder({ ...idle, scrollTop: 0 }), true);
	assert.equal(H.wantsOlder({ ...idle, scrollTop: 2 * 800 - 1 }), true);
	// Further down, reading or at the bottom: not yet.
	assert.equal(H.wantsOlder({ ...idle, scrollTop: 2 * 800 }), false);
	assert.equal(H.wantsOlder({ ...idle, scrollTop: 40_000 }), false);
	// A turn's Copy that needs them asks wherever the reader is.
	assert.equal(H.wantsOlder({ ...idle, scrollTop: 40_000, now: true }), true);
	// Nothing older, or something already on its way: never.
	for (const busy of [{ more: false }, { loading: true }, { asked: true }, { earlier: 12 }]) {
		assert.equal(H.wantsOlder({ ...idle, ...busy, scrollTop: 0, now: true }), false, JSON.stringify(busy));
	}
});

test("a turn may start before the page's first entry only while older entries may come (#440)", () => {
	const kinds = (list) => [...list].map((k, id) => ({ id, kind: k === "u" ? "user" : k === "a" ? "assistant" : "marker" }));
	// The page starts in the middle of a turn: the turn that ends at 2 runs back to the first entry.
	const cut = kinds("aaaua");
	assert.equal(H.turnCut(cut, 2, true), true);
	assert.equal(H.turnCut(cut, 4, true), false, "a turn after the person's message is whole");
	assert.equal(H.turnCut(cut, 2, false), false, "with nothing older, the first entry is the start");
	// The page starts with the person's message, or a line of its own: the turn is whole.
	assert.equal(H.turnCut(kinds("uaa"), 2, true), false);
	assert.equal(H.turnCut(kinds("maa"), 2, true), false);
	// Only an answer ends a turn.
	assert.equal(H.turnCut(kinds("aau"), 2, true), false);
	assert.equal(H.turnCut([], 0, true), false);
});
