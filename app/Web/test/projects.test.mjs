import assert from "node:assert/strict";
import { test } from "node:test";
import P from "../transcript/projects.js";

const at = (hours, minutes, day = 0) => {
	const when = new Date(2026, 2, 12 + day, hours, minutes);
	return { at: when.getTime(), now: new Date(2026, 2, 12, 18, 0).getTime() };
};

test("the conversation's changes, checked as the app sends them", () => {
	assert.deepEqual(P.readChanges(undefined), []);
	assert.deepEqual(P.readChanges([{ id: 3.5, summary: "Added a rule" }, "nonsense"]), [], "a fraction is no change's number");
	assert.deepEqual(P.readChanges([{ id: 3, summary: "" }]), [], "a change says what it changed");
	const [change] = P.readChanges([
		{ id: 31, summary: "Added rule r1: “Ship on Fridays”", undone: false, canUndo: true, noUndo: null, undoneAt: null },
	]);
	assert.deepEqual(change, { id: 31, summary: "Added rule r1: “Ship on Fridays”", undone: false, canUndo: true, noUndo: null, undoneAt: null });
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
	assert.equal(P.whenText(at(23, 59, -1).at, at(0, 1).now), "23:59", "late last night is not yesterday until the day has turned");
	assert.equal(P.whenText(at(9, 4, -1).at, at(18, 0).now), "yesterday 09:04");
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
	});
	assert.deepEqual(P.cardWords({ kind: "rule", agentName: "Orchestrator", text: "Ship on Fridays.", binds: "everyone", why: "" }), {
		title: "Orchestrator proposes a rule",
		summary: "Ship on Fridays.",
		binds: "Binds every agent of the project",
		why: "",
	});
	assert.deepEqual(P.cardWords({ kind: "rule", agentName: "", text: "Never release on a Friday.", binds: "orchestrator", why: "Friday releases have gone wrong." }), {
		title: "The agent proposes a rule",
		summary: "Never release on a Friday.",
		binds: "Binds the orchestrator only",
		why: "Friday releases have gone wrong.",
	});
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
