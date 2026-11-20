/*
 * What the transcript shows of a project in the conversation's own page (#474; docs/projects.md, 3.9, 3.12 and
 * 7.2): the line for each change a tool call made, with its Undo and how it reads once undone; and the cards for a
 * request for more reach and for a proposed rule, answered in place, which become a quiet line with their outcome.
 *
 * Pure functions over what the app sends and the page's items, so Node can test them. Loaded as a plain script by the
 * page (it sets `PiProjects`).
 */
(function (root, factory) {
	const api = factory();
	if (typeof module === "object" && module.exports) module.exports = api;
	else root.PiProjects = api;
})(typeof globalThis !== "undefined" ? globalThis : this, function () {
	"use strict";

	const QUOTE_OPEN = String.fromCharCode(0x201c);
	const QUOTE_CLOSE = String.fromCharCode(0x201d);

	const isObject = (value) => value !== null && typeof value === "object" && !Array.isArray(value);
	const str = (value) => (typeof value === "string" ? value : "");

	/**
	 * The app's `changes` message (the conversation's `projectChanges`, docs/projects.md, 3.12), checked: each line
	 * names a change, says what changed in the record's own words, and whether it was undone and can be. Anything
	 * malformed is dropped rather than trusted.
	 */
	function readChanges(list) {
		return (Array.isArray(list) ? list : [])
			.filter(isObject)
			.map((change) => ({
				id: change.id,
				summary: str(change.summary),
				undone: change.undone === true,
				canUndo: change.canUndo === true,
				noUndo: typeof change.noUndo === "string" ? change.noUndo : null,
				undoneAt: typeof change.undoneAt === "number" ? change.undoneAt : null,
			}))
			.filter((change) => Number.isInteger(change.id) && change.summary !== "");
	}

	/**
	 * The app's `needs` message (the reach requests and proposed rules waiting from this conversation, 3.9), checked
	 * the same way.
	 */
	function readNeeds(list) {
		return (Array.isArray(list) ? list : [])
			.filter(isObject)
			.map((need) => ({
				id: str(need.id),
				kind: need.kind === "rule" ? "rule" : need.kind === "reach" ? "reach" : "",
				agentName: typeof need.agentName === "string" ? need.agentName : "",
				change: isObject(need.change) ? str(need.change.summary) : "",
				text: str(need.text),
				binds: need.binds === "orchestrator" ? "orchestrator" : need.binds === "everyone" ? "everyone" : "",
				why: str(need.why),
			}))
			.filter((need) => need.id !== "" && need.kind !== "" && (need.kind !== "reach" || need.change !== "") && (need.kind !== "rule" || need.text !== ""));
	}

	/** How a need names what it asks, as the engine words the wake that answers it: "the request "…"". */
	function labelOf(need) {
		if (!isObject(need)) return null;
		if (need.kind === "rule") return `the proposed rule ${QUOTE_OPEN}${need.text}${QUOTE_CLOSE}`;
		if (need.kind === "reach") return `the request ${QUOTE_OPEN}${need.change}${QUOTE_CLOSE}`;
		return null;
	}

	/**
	 * Which Needs you items the conversation's items say were answered, and how: the wake markers the engine writes as
	 * it answers one carry `{ need, ended, label }` (the wake kind `answer`), by need id.
	 */
	function answersOf(items) {
		const answers = new Map();
		for (const item of Array.isArray(items) ? items : []) {
			if (!isObject(item) || !isObject(item.details) || !Array.isArray(item.details.answers)) continue;
			for (const answer of item.details.answers) {
				if (!isObject(answer) || typeof answer.need !== "string" || answer.need === "") continue;
				answers.set(answer.need, { ended: str(answer.ended), label: str(answer.label) });
			}
		}
		return answers;
	}

	/** A change id or need id a call's result names in `details`, or null: the engine puts each there as it is made. */
	function namedOf(result, key) {
		if (!isObject(result) || !isObject(result.details)) return null;
		const value = result.details[key];
		if (key === "change") return Number.isInteger(value) ? value : null;
		return typeof value === "string" && value !== "" ? value : null;
	}

	/** A short time, "14:32"; "yesterday 14:32" the day before; "3 Mar 14:32" any earlier. */
	function whenText(at, now) {
		if (typeof at !== "number" || !Number.isFinite(at) || typeof now !== "number" || !Number.isFinite(now)) return "";
		const time = new Date(at).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
		const day = (date) => new Date(date.getFullYear(), date.getMonth(), date.getDate()).getTime();
		const days = Math.round((day(new Date(now)) - day(new Date(at))) / 86_400_000);
		if (days <= 0) return time;
		if (days === 1) return `yesterday ${time}`;
		return `${new Date(at).toLocaleDateString([], { day: "numeric", month: "short" })} ${time}`;
	}

	/**
	 * The words for a change's line (3.12): its summary, as the record wrote it, and the note after it. The note is
	 * empty while it can be undone (the Undo button is the note then), says when it was undone once it was, why it has
	 * no Undo when it has none, and that it cannot be undone now while its project is away.
	 */
	function changeWords(change, now) {
		const note = change.undone
			? `Undone ${whenText(change.undoneAt, now)}`
			: change.noUndo !== null
				? `No Undo ${String.fromCharCode(0x2014)} ${change.noUndo}`
				: change.canUndo
					? ""
					: "cannot be undone now";
		return { summary: change.summary, note, undone: change.undone };
	}

	/**
	 * The words for a reach request's or a proposed rule's card (7.2): who asks, what for, and for a rule whom it
	 * would bind. `why` is the agent's own words, shown as its reason, not pi²'s.
	 */
	function cardWords(need) {
		const who = str(need.agentName) || "The agent";
		if (need.kind === "reach") {
			return { title: `${who} asks for more reach`, summary: need.change, binds: "", why: need.why };
		}
		return {
			title: `${who} proposes a rule`,
			summary: need.text,
			binds: need.binds === "orchestrator" ? "Binds the orchestrator only" : "Binds every agent of the project",
			why: need.why,
		};
	}

	/**
	 * The one line a card becomes once its need is answered or gone (7.2): the wake's own words where the conversation
	 * has them ("the request "…" was allowed"), else what the card knew and that it no longer waits.
	 */
	function outcomeWords(need, answer) {
		const label = (isObject(answer) && str(answer.label) !== "" ? str(answer.label) : null) ?? labelOf(need);
		if (label === null) return "a request that no longer waits for you";
		return `${label} ${isObject(answer) && str(answer.ended) !== "" ? str(answer.ended) : "no longer waits for you"}`;
	}

	return { readChanges, readNeeds, answersOf, namedOf, whenText, changeWords, cardWords, outcomeWords, labelOf };
});
