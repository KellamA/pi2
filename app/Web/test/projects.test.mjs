import assert from "node:assert/strict";
import { test } from "node:test";
import P from "../transcript/projects.js";
import { document, html } from "./fakedom.mjs";

const at = (hours, minutes, day = 0) => {
	const when = new Date(2026, 2, 12 + day, hours, minutes);
	return { at: when.getTime(), now: new Date(2026, 2, 12, 18, 0).getTime() };
};

test("the conversation's changes, checked as the app sends them", () => {
	assert.deepEqual(P.readChanges(undefined), []);
	assert.deepEqual(P.readChanges([{ id: 3.5, summary: "Added a rule" }, "nonsense"]), [], "a fraction is no change's number");
	assert.deepEqual(P.readChanges([{ id: 3, summary: "" }]), [], "a change says what it changed");
	const [change] = P.readChanges([
		{ id: 31, summary: "Added rule r1: “Ship on Fridays”", undone: false, canUndo: true, noUndo: null, undoneAt: null, need: null },
		// A change the person allowed has no call of its own: its line rides on the request that asked for it.
		{ id: 32, summary: "Changed Forge: access Full access (now Ask first)", undone: false, canUndo: true, noUndo: null, undoneAt: null, need: "n2" },
	]);
	assert.deepEqual(change, { id: 31, summary: "Added rule r1: “Ship on Fridays”", undone: false, canUndo: true, noUndo: null, undoneAt: null, need: null });
	assert.equal(P.readChanges([{ id: 32, summary: "Changed Forge", need: "n2" }])[0].need, "n2");
	assert.equal(P.readChanges([{ id: 33, summary: "Changed Forge", need: 7 }])[0].need, null, "a need's id is a string");
});

test("the needs waiting from the conversation, checked the same way", () => {
	assert.deepEqual(P.readNeeds([{ id: "", kind: "reach", change: { summary: "More" } }]), [], "an id names the need");
	assert.deepEqual(P.readNeeds([{ id: "n2", kind: "decision", question: "Merge now?" }]), [], "only a reach request or a proposed rule is a card");
	const needs = P.readNeeds([
		{ id: "n2", kind: "reach", agentName: "Orchestrator", change: { summary: "Change Forge: access Full access (now Ask first)", fields: [] }, why: "It needs to run the checks itself." },
		{ id: "n3", kind: "rule", agentName: "Orchestrator", text: "Ship on Fridays.", binds: "everyone", why: null },
		{ id: "n4", kind: "rule", agentName: null, text: "Never release on a Friday.", binds: "orchestrator", why: "" },
	]);
	assert.equal(needs.length, 3);
	assert.equal(needs[0].change, "Change Forge: access Full access (now Ask first)");
	assert.equal(needs[1].binds, "everyone");
	assert.equal(needs[2].agentName, "");
	assert.equal(needs[2].binds, "orchestrator");
});

test("a change's line: what changed, in the record's own words, and how it reads once undone", () => {
	const open = { id: 31, summary: "Added rule r1: “Ship on Fridays”", undone: false, canUndo: true, noUndo: null, undoneAt: null };
	// While it can be undone the button is the note; the line is the summary alone.
	assert.deepEqual(P.changeWords(open, at(15, 5).now), { summary: "Added rule r1: “Ship on Fridays”", note: "", undone: false });
	// Undone, here or elsewhere: the same line, saying when.
	const undone = { ...open, undone: true, canUndo: false, undoneAt: at(15, 32).at };
	assert.deepEqual(P.changeWords(undone, at(15, 45).now), { summary: "Added rule r1: “Ship on Fridays”", note: "Undone 15:32", undone: true });
	// A change with no Undo says why, in the engine's few words (5.9).
	assert.deepEqual(
		P.changeWords({ id: 40, summary: "Made Reviewer the project's orchestrator", undone: false, canUndo: false, noUndo: "it started a fresh conversation; going back is another change of orchestrator", undoneAt: null }, 0),
		{ summary: "Made Reviewer the project's orchestrator", note: "No Undo — it started a fresh conversation; going back is another change of orchestrator", undone: false },
	);
	// One undone on GitHub says so; the plain one says only that it cannot be.
	assert.equal(P.changeWords({ id: 41, summary: "Merged #12", undone: false, canUndo: false, noUndo: "on GitHub; it cannot be undone here", undoneAt: null }, 0).note, "No Undo — on GitHub; it cannot be undone here");
	assert.equal(P.changeWords({ id: 42, summary: "Renamed the project", undone: false, canUndo: false, noUndo: "it cannot be undone", undoneAt: null }, 0).note, "No Undo — it cannot be undone");
	// A change that can no longer be undone while its project is away.
	assert.equal(P.changeWords({ id: 43, summary: "Added a rule", undone: false, canUndo: false, noUndo: null, undoneAt: null }, 0).note, "cannot be undone now");
});

test("when a change was undone, as a short time", () => {
	assert.equal(P.whenText(at(15, 32).at, at(18, 0).now), "15:32");
	assert.equal(P.whenText(at(9, 4, -1).at, at(18, 0).now), "yesterday 09:04");
	assert.equal(P.whenText(at(23, 59, -1).at, at(0, 1).now), "yesterday 23:59");
	assert.equal(P.whenText(at(9, 4, -9).at, at(18, 0).now), "3 Mar 09:04");
	assert.equal(P.whenText(null, 0), "");
});

test("which needs the conversation's items say were answered, and how", () => {
	const items = [
		{ id: 90, kind: "marker", text: "pi² woke the agent", details: { wake: { text: "" }, answers: [{ need: "n2", ended: "was allowed", label: "the request “Change Forge: access Full access”" }] } },
		{ id: 91, kind: "marker", text: "pi² woke the agent", details: { answers: [{ need: "n3", ended: "was accepted", label: "the proposed rule “Ship on Fridays.”" }, { need: "", ended: "no" }] } },
		{ id: 92, kind: "marker", text: "pi² woke the agent", details: { answers: "nonsense" } },
		{ id: 93, kind: "marker", text: "pi² woke the agent" },
	];
	const answers = P.answersOf(items);
	assert.deepEqual(answers.get("n2"), { ended: "was allowed", label: "the request “Change Forge: access Full access”" });
	assert.deepEqual(answers.get("n3"), { ended: "was accepted", label: "the proposed rule “Ship on Fridays.”" });
	assert.equal(answers.has(""), false);
	assert.equal(answers.size, 2);
	// The id a call's result names, as the engine puts it there as it is made.
	assert.equal(P.namedOf({ details: { change: 31, need: "n2" } }, "change"), 31);
	assert.equal(P.namedOf({ details: { change: 31 } }, "need"), null);
	assert.equal(P.namedOf(null, "change"), null);
	assert.equal(P.namedOf({ details: { change: "31" } }, "change"), null);
});

test("the cards: who asks, what for, and for a rule whom it would bind", () => {
	assert.deepEqual(P.cardWords({ kind: "reach", agentName: "Orchestrator", change: "Change Forge: access Full access (now Ask first)", why: "It needs to run the checks itself." }), {
		title: "Orchestrator asks for more reach",
		summary: "Change Forge: access Full access (now Ask first)",
		binds: "",
		why: "It needs to run the checks itself.",
		accept: "Allow",
		refuse: "Refuse",
	});
	assert.deepEqual(P.cardWords({ kind: "rule", agentName: "Orchestrator", text: "Ship on Fridays.", binds: "everyone", why: "" }), {
		title: "Orchestrator proposes a rule",
		summary: "Ship on Fridays.",
		binds: "Binds every agent of the project",
		why: "",
		accept: "Accept",
		refuse: "Refuse",
	});
	assert.deepEqual(P.cardWords({ kind: "rule", agentName: "", text: "Never release on a Friday.", binds: "orchestrator", why: "Friday releases have gone wrong." }), {
		title: "The agent proposes a rule",
		summary: "Never release on a Friday.",
		binds: "Binds the orchestrator only",
		why: "Friday releases have gone wrong.",
		accept: "Accept",
		refuse: "Refuse",
	});
});

test("the answers are the contract's words, the same the board's cards use (7.2)", () => {
	// One wording everywhere: the contract's Allow and Refuse for more reach, Accept and Refuse for a rule.
	const reach = P.cardWords({ kind: "reach", agentName: "Orchestrator", change: "Change Forge: access Full access (now Ask first)", why: "" });
	assert.deepEqual([reach.accept, reach.refuse], ["Allow", "Refuse"]);
	const rule = P.cardWords({ kind: "rule", agentName: "Orchestrator", text: "Ship on Fridays.", binds: "everyone", why: "" });
	assert.deepEqual([rule.accept, rule.refuse], ["Accept", "Refuse"]);
});

test("a rule's own words and an agent's name are shown as text, never as markup", () => {
	const [need] = P.readNeeds([
		{
			id: "n5",
			kind: "rule",
			agentName: "<img src=x onerror=alert(1)>",
			text: "Ship </p><script>alert(1)</script> <b>on Fridays</b>",
			binds: "everyone",
			why: "<script>steal()</script>",
		},
	]);
	const rows = P.needRows(document, need);
	const markup = rows.map(html).join("");
	for (const tag of ["<script", "<b>", "<img"]) assert.equal(markup.includes(tag), false, `no ${tag} from what the agent wrote`);
	// The text is there all the same, escaped as every other text on the page.
	assert.ok(markup.includes("&lt;script&gt;alert(1)&lt;/script&gt;"));
	assert.ok(markup.includes("&lt;img src=x onerror=alert(1)&gt;"));
	assert.equal(rows[1].textContent, "Ship </p><script>alert(1)</script> <b>on Fridays</b>");
	// The head is the title, with the name as it was given, and the note beside it.
	assert.equal(rows[0].childNodes[0].textContent, "<img src=x onerror=alert(1)> proposes a rule");
	assert.ok(html(rows[0]).includes("waits for you"));
});

test("a call's key changes when its card is answered or its line is undone elsewhere", () => {
	// The page keys a row by this: a state that changes with nothing else about the entry has to change it, or the
	// page never draws the new state (a card answered on the board, a change undone from another window).
	const revisions = new WeakMap();
	let count = 0;
	const rev = (object) => (object ? revisions.get(object) ?? 0 : 0);
	const stamp = (object) => {
		revisions.set(object, ++count);
		return object;
	};
	const world = () => ({ results: new Map(), changes: new Map(), needs: new Map(), knownNeeds: new Map(), answered: new Map(), refusals: new Map(), undoing: new Set(), answering: new Set(), rev });
	const w = world();
	const call = { callId: "c1", name: "project_settings", arguments: {} };
	w.results.set("c1", { details: { change: 32, need: "n2" } });
	const change = stamp({ id: 32, summary: "Change Forge: access Full access", undone: false, canUndo: true, noUndo: null, undoneAt: null, need: "n2" });
	w.changes.set(32, change);
	const need = stamp({ id: "n2", kind: "reach", change: "Change Forge: access Full access", text: "", binds: "", why: "" });
	w.needs.set("n2", need);
	w.knownNeeds.set("n2", need);
	const waiting = P.callKey(call, w);
	// Nothing changed: the same key, so the page draws nothing again.
	assert.equal(P.callKey(call, w), waiting);
	// Answered on the board: the card becomes its outcome's line.
	w.needs.delete("n2");
	const answered = P.callKey(call, w);
	assert.notEqual(answered, waiting);
	// Undone elsewhere: the line turns undone, with no button.
	w.changes.set(32, stamp({ ...change, undone: true, canUndo: false, undoneAt: 1 }));
	assert.notEqual(P.callKey(call, w), answered);
	// A call that asked nothing carries nothing.
	assert.equal(P.callKey({ callId: "c2" }, w), "0:0");
});

test("the one line a card becomes, with its outcome", () => {
	const reach = { kind: "reach", change: "Change Forge: access Full access (now Ask first)" };
	const rule = { kind: "rule", text: "Ship on Fridays." };
	// Allowed and refused, accepted and refused: the wake's own words.
	assert.equal(P.outcomeWords(reach, { ended: "was allowed", label: "the request “Change Forge: access Full access (now Ask first)”" }), "the request “Change Forge: access Full access (now Ask first)” was allowed");
	assert.equal(P.outcomeWords(reach, { ended: "was refused", label: "the request “Change Forge: access Full access (now Ask first)”" }), "the request “Change Forge: access Full access (now Ask first)” was refused");
	assert.equal(P.outcomeWords(rule, { ended: "was accepted", label: "the proposed rule “Ship on Fridays.”" }), "the proposed rule “Ship on Fridays.” was accepted");
	assert.equal(P.outcomeWords(rule, { ended: "was not accepted", label: "the proposed rule “Ship on Fridays.”" }), "the proposed rule “Ship on Fridays.” was not accepted");
	// The wake has not come yet, or the need was withdrawn: what the card knew, and that it no longer waits.
	assert.equal(P.outcomeWords(reach, null), "the request “Change Forge: access Full access (now Ask first)” no longer waits for you");
	assert.equal(P.outcomeWords(rule, {}), "the proposed rule “Ship on Fridays.” no longer waits for you");
	// Nothing left that says what it was.
	assert.equal(P.outcomeWords(undefined, null), "a request that no longer waits for you");
});
