import assert from "node:assert/strict";
import { test } from "node:test";
import Ch from "../transcript/chat.js";
import MD from "../transcript/markdown.js";

const safe = (url) => MD.safeURL(url);

test("a chat's controls only when the app says it is a chat", () => {
	assert.equal(Ch.read(undefined), Ch.NONE);
	assert.equal(Ch.read({ enabled: false, versions: [{ after: 1, index: 0, count: 2 }] }), Ch.NONE);
	assert.equal(Ch.read({ enabled: "yes" }).enabled, false);
	const chat = Ch.read({
		enabled: true,
		versions: [
			{ after: 4, index: 1, count: 2 },
			{ after: null, index: 0, count: 3 },
			// Not points: one version, an index past the end, a fraction, a negative entry, nonsense.
			{ after: 9, index: 0, count: 1 },
			{ after: 9, index: 2, count: 2 },
			{ after: 9.5, index: 0, count: 2 },
			{ after: -1, index: 0, count: 2 },
			"nonsense",
		],
		models: [{ provider: "demo", id: "demo-1", name: "Demo", group: "Demo" }, { provider: "x", id: "" }, { provider: "openai", id: "gpt" }],
		model: "demo/demo-1",
	});
	assert.deepEqual(chat.versions, [
		{ after: 4, index: 1, count: 2 },
		{ after: null, index: 0, count: 3 },
	]);
	assert.deepEqual(chat.models, [
		{ provider: "demo", id: "demo-1", name: "Demo", group: "Demo" },
		{ provider: "openai", id: "gpt", name: "gpt", group: "openai" },
	]);
	assert.equal(chat.model, "demo/demo-1");
});

test("a version control sits under the first message or answer after its point", () => {
	const visible = [
		{ id: 1, kind: "user" },
		{ id: 3, kind: "assistant" },
		{ id: 5, kind: "assistant" },
		{ id: 6, kind: "user" },
		{ id: 8, kind: "marker" },
		{ id: 9, kind: "assistant" },
	];
	const rows = Ch.versionRows(visible, [
		// Edit of the first message: under it.
		{ after: null, index: 1, count: 2 },
		// Try Again of the first message's answer: at the end of the turn, under its last answer.
		{ after: 1, index: 0, count: 3 },
		// Edit of the second message, parting after an entry the page is not shown (a system prompt, say).
		{ after: 5, index: 1, count: 2 },
		// Try Again of the second message's answer, past a marker.
		{ after: 6, index: 0, count: 2 },
		// A point past everything shown (its version has nothing yet) has no row.
		{ after: 20, index: 1, count: 2 },
	]);
	assert.deepEqual([...rows], [
		[1, { after: null, index: 1, count: 2 }],
		[5, { after: 1, index: 0, count: 3 }],
		[6, { after: 5, index: 1, count: 2 }],
		[9, { after: 6, index: 0, count: 2 }],
	]);
	assert.equal(Ch.versionRows([], [{ after: null, index: 0, count: 2 }]).size, 0);
});

test("a point older than the page's first entry waits while older entries are to come (#440)", () => {
	// The page starts at entry 40, and older entries are still to come.
	const visible = [
		{ id: 40, kind: "assistant" },
		{ id: 42, kind: "user" },
		{ id: 44, kind: "assistant" },
	];
	const points = [
		{ after: null, index: 1, count: 2 },
		{ after: 12, index: 0, count: 2 },
		{ after: 42, index: 1, count: 3 },
	];
	// Without the bound, the first two would land under the first row the page has, which is not where they part.
	assert.deepEqual([...Ch.versionRows(visible, points).keys()], [40, 44]);
	assert.deepEqual([...Ch.versionRows(visible, points, 40)], [[44, { after: 42, index: 1, count: 3 }]]);
	// A point at or after the first entry the page has is placed as before.
	assert.deepEqual([...Ch.versionRows(visible, [{ after: 40, index: 0, count: 2 }], 40)], [[42, { after: 40, index: 0, count: 2 }]]);
});

test("sources are the pages a turn read, once each", () => {
	const turn = [
		{ toolCalls: [{ callId: "a", name: "web_search" }, { callId: "b", name: "web_fetch" }] },
		{ toolCalls: [{ callId: "c", name: "web_fetch" }, { callId: "d", name: "web_fetch" }, { callId: "e", name: "web_fetch" }, { callId: "f", name: "web_fetch" }, { callId: "g", name: "bash" }] },
		{ toolCalls: [] },
	];
	const results = new Map([
		// A search only lists pages: none of them is a source.
		["a", { details: null, text: "1. Something\n   https://listed.example/" }],
		["b", { details: { source: { url: "https://www.example.com/guide", title: "The Guide" } } }],
		// The same page again (a second part of it) counts once.
		["c", { details: { source: { url: "https://www.example.com/guide", title: "The Guide" } } }],
		// A page with no title is named by its site.
		["d", { details: { source: { url: "https://docs.example.org/a/b", title: "  " } } }],
		// A page that could not be read, and an address the page may not link to, are not sources.
		["e", { isError: true, details: { source: { url: "https://failed.example/" } } }],
		["f", { details: { source: { url: "javascript:alert(1)", title: "Trap" } } }],
		["g", { details: { source: { url: "https://bash.example/", title: "Not a web tool" } } }],
	]);
	const read = Ch.sources(turn, results, safe);
	assert.deepEqual(read, [
		{ url: "https://www.example.com/guide", title: "The Guide", host: "example.com" },
		{ url: "https://docs.example.org/a/b", title: "docs.example.org", host: "docs.example.org" },
	]);
	assert.equal(Ch.sourceLabel(read[0]), "The Guide · example.com");
	assert.equal(Ch.sourceLabel(read[1]), "docs.example.org");
	assert.deepEqual(Ch.sources([{ toolCalls: [{ callId: "x", name: "web_fetch" }] }], new Map(), safe), [], "a call still running has no source yet");
});

test("Try Again's models are grouped by provider, as the model selector groups them", () => {
	const groups = Ch.modelGroups([
		{ provider: "anthropic", id: "a", name: "A", group: "Anthropic" },
		{ provider: "demo", id: "d", name: "D", group: "Demo" },
		{ provider: "anthropic", id: "b", name: "B", group: "Anthropic" },
	]);
	assert.deepEqual(
		groups.map((group) => [group.name, group.models.map((model) => model.id)]),
		[
			["Anthropic", ["a", "b"]],
			["Demo", ["d"]],
		],
	);
});
