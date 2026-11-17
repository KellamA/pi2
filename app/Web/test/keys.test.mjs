import assert from "node:assert/strict";
import { test } from "node:test";
import K from "../transcript/keys.js";

const enter = (more = {}) => ({ key: "Enter", keyCode: 13, shiftKey: false, altKey: false, ctrlKey: false, metaKey: false, isComposing: false, repeat: false, ...more });

test("Return sends, Shift-Return and Option-Return start a new line", () => {
	assert.equal(K.returnKey(enter()), "send");
	assert.equal(K.returnKey(enter({ shiftKey: true })), "newLine");
	assert.equal(K.returnKey(enter({ altKey: true })), "newLine");
	assert.equal(K.returnKey(enter({ shiftKey: true, altKey: true })), "newLine");
	assert.equal(K.returnKey(enter({ shiftKey: true, repeat: true })), "newLine");
});

test("Return while an input method is composing is the input method's", () => {
	assert.equal(K.returnKey(enter({ isComposing: true })), "leave");
	assert.equal(K.returnKey(enter({ isComposing: true, shiftKey: true })), "leave");
	// WebKit ends the composition before the key down that confirms it, and marks that key down with 229.
	assert.equal(K.returnKey(enter({ keyCode: 229 })), "leave");
});

test("every combination of modifier keys, as the app's message fields have it", () => {
	const names = ["shiftKey", "altKey", "ctrlKey", "metaKey"];
	for (let mask = 0; mask < 16; mask++) {
		const held = Object.fromEntries(names.map((name, bit) => [name, (mask & (1 << bit)) !== 0]));
		for (const repeat of [false, true]) {
			const expected = mask === 0 ? (repeat ? "nothing" : "send") : !held.ctrlKey && !held.metaKey ? "newLine" : held.metaKey ? "leave" : "nothing";
			assert.equal(K.returnKey(enter({ ...held, repeat })), expected, JSON.stringify({ ...held, repeat }));
		}
	}
});

test("other keys are not Return", () => {
	assert.equal(K.returnKey({ key: "a" }), null);
	assert.equal(K.returnKey({ key: "Tab", shiftKey: true }), null);
	assert.equal(K.returnKey(undefined), null);
});
