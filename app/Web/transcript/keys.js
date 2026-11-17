/*
 * What Return does in a field on this page that sends something: the answer to an agent's question. The same rule as
 * the app's own message fields (ComposeKit's `ReturnKey`, #174): Return sends, Shift-Return and Option-Return start a
 * new line, and while an input method is composing every Return is its own.
 *
 * A pure function over the key event, so Node can test it. Loaded as a plain script by the page (it sets `PiKeys`).
 */
(function (root, factory) {
	const api = factory();
	if (typeof module === "object" && module.exports) module.exports = api;
	else root.PiKeys = api;
})(typeof globalThis !== "undefined" ? globalThis : this, function () {
	"use strict";

	/**
	 * "send", "newLine", "leave" (let the field have it) or "nothing" (swallow it); null for a key that is not Return.
	 *
	 * Composing is `isComposing`, or the key code 229 that WebKit gives the key down which ends a composition: there,
	 * the composition has already ended and `isComposing` is false, so confirming a Japanese candidate would send.
	 * Command is left alone, for shortcuts. Control-Return means nothing here, and a held Return must not send twice.
	 */
	function returnKey(event) {
		if (!event || event.key !== "Enter") return null;
		if (event.isComposing || event.keyCode === 229) return "leave";
		if (!event.shiftKey && !event.altKey && !event.ctrlKey && !event.metaKey) return event.repeat ? "nothing" : "send";
		if (!event.ctrlKey && !event.metaKey) return "newLine";
		if (event.metaKey) return "leave";
		return "nothing";
	}

	return { returnKey };
});
