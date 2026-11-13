/*
 * What a selection in the transcript copies as. The page hands the selected nodes here on every copy, so the
 * clipboard holds text that reads well on its own rather than whatever the layout happens to produce:
 *
 *   - paragraphs, headings, quotes, lists and tables keep their shape ("- " and "1. " items, "> " quotes, tab-separated
 *     cells); code and command output are copied exactly as they are;
 *   - a collapsed tool row gives its one-line summary, an open one its summary and then its content;
 *   - buttons, chevrons, spinners and anything marked `data-nocopy` give nothing; an element with `data-copy` gives
 *     that text instead of its own (a picture gives "[Picture: name]").
 *
 * Works on any DOM-like nodes, so Node can test it. Loaded as a plain script by the page (it sets `PiClipboard`).
 */
(function (root, factory) {
	const api = factory();
	if (typeof module === "object" && module.exports) module.exports = api;
	else root.PiClipboard = api;
})(typeof globalThis !== "undefined" ? globalThis : this, function () {
	"use strict";

	const PARAGRAPH = new Set(["p", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "ul", "ol", "table", "hr", "article", "section", "figure"]);
	const LINE = new Set(["div", "li", "tr", "pre", "header", "footer", "details", "summary", "dl", "dt", "dd", "thead", "tbody"]);
	const DROPPED = new Set(["button", "svg", "script", "style", "template", "textarea", "select", "option", "noscript"]);
	// Containers whose class makes them a paragraph of their own: a message, a code block, a divider.
	const PARAGRAPH_CLASSES = ["msg", "codeblock", "marker", "table-wrap"];

	const tagOf = (el) => String(el.localName || el.tagName || "").toLowerCase();
	const classesOf = (el) => String(el.getAttribute("class") || "").split(/\s+/);

	function dropped(el) {
		if (el.hasAttribute("data-nocopy") || el.hasAttribute("hidden") || el.getAttribute("aria-hidden") === "true") return true;
		const tag = tagOf(el);
		if (DROPPED.has(tag)) return true;
		return tag === "input" && el.getAttribute("type") !== "checkbox";
	}

	/** Collects text, putting at least the asked-for number of line breaks between blocks and none at either end. */
	class Writer {
		constructor() {
			this.out = "";
			this.pending = 0;
		}
		text(value) {
			if (!value) return;
			if (this.out !== "" && this.pending > 0) this.out += "\n".repeat(this.pending);
			this.pending = 0;
			this.out += value;
		}
		block(lines) {
			if (this.out !== "") this.pending = Math.max(this.pending, lines);
		}
	}

	/** The text inside a `pre`, exactly, without its line numbers and other marked parts. */
	function preText(node) {
		if (node.nodeType === 3) return node.data;
		if (node.nodeType === 1 && dropped(node)) return node.hasAttribute("data-copy") ? node.getAttribute("data-copy") : "";
		let out = "";
		for (let child = node.firstChild; child; child = child.nextSibling) out += preText(child);
		return out;
	}

	function indent(text, first, rest) {
		return text
			.split("\n")
			.map((line, index) => (index === 0 ? first + line : line === "" ? line : rest + line))
			.join("\n");
	}

	function children(node, writer, context) {
		for (let child = node.firstChild; child; child = child.nextSibling) walk(child, writer, context);
	}

	function sub(node, context) {
		const writer = new Writer();
		children(node, writer, context);
		return writer.out;
	}

	function walk(node, writer, context) {
		if (node.nodeType === 3) {
			writer.text(node.data);
			return;
		}
		if (node.nodeType === 11 || node.nodeType === 9) {
			children(node, writer, context);
			return;
		}
		if (node.nodeType !== 1) return;
		const tag = tagOf(node);
		const classes = classesOf(node);
		const paragraph = PARAGRAPH.has(tag) || PARAGRAPH_CLASSES.some((name) => classes.includes(name));
		const line = !paragraph && (LINE.has(tag) || classes.includes("tool"));
		// Inside a list item, nested lists and paragraphs sit on the next line rather than after a blank one.
		const gap = paragraph ? (context.inItem && (tag === "ul" || tag === "ol" || tag === "p") ? 1 : 2) : line ? 1 : 0;

		if (node.hasAttribute("data-copy")) {
			if (gap) writer.block(gap);
			writer.text(node.getAttribute("data-copy"));
			if (gap) writer.block(gap);
			return;
		}
		if (dropped(node)) return;

		if (gap) writer.block(gap);
		switch (tag) {
			case "br":
				writer.text("\n");
				break;
			case "pre":
				writer.text(preText(node));
				break;
			case "hr":
				writer.text("---");
				break;
			case "input":
				writer.text(node.hasAttribute("checked") ? "[x] " : "[ ] ");
				break;
			case "img": {
				const alt = node.getAttribute("alt");
				writer.text(alt ? `[Picture: ${alt}]` : "[Picture]");
				break;
			}
			case "a": {
				const text = sub(node, context);
				writer.text(text);
				const href = node.getAttribute("href") || "";
				const shown = text.trim();
				if (href && shown !== href && !(href.startsWith("mailto:") && shown === href.slice(7)) && shown !== href.replace(/^https?:\/\//, "")) {
					writer.text(` (${href})`);
				}
				break;
			}
			case "li": {
				const parent = node.parentNode;
				const ordered = parent && parent.nodeType === 1 && tagOf(parent) === "ol";
				let marker = "- ";
				if (ordered) {
					let number = parseInt(parent.getAttribute("start") || "1", 10) || 1;
					for (let sibling = parent.firstChild; sibling && sibling !== node; sibling = sibling.nextSibling) {
						if (sibling.nodeType === 1 && tagOf(sibling) === "li") number++;
					}
					marker = `${number}. `;
				}
				const body = sub(node, { ...context, inItem: true });
				writer.text(indent(body, marker, " ".repeat(marker.length)));
				break;
			}
			case "blockquote":
				writer.text(indent(sub(node, context), "> ", "> ").replace(/^> $/gm, ">"));
				break;
			case "tr": {
				let first = true;
				for (let cell = node.firstChild; cell; cell = cell.nextSibling) {
					if (cell.nodeType !== 1) continue;
					// The tab goes in even for an empty cell, so every cell keeps its column.
					if (!first) writer.text("\t");
					writer.text(sub(cell, context).replace(/\n+/g, " "));
					first = false;
				}
				break;
			}
			default:
				children(node, writer, tag === "ul" || tag === "ol" ? { ...context, inItem: false } : context);
		}
		if (gap) writer.block(gap);
	}

	/** The plain text a selection copies as. `root` is what `Range.cloneContents()` gave, or any node. */
	function plainText(root) {
		const writer = new Writer();
		walk(root, writer, { inItem: false });
		return writer.out.replace(/^\n+|\s+$/g, "");
	}

	/**
	 * The selection made fit to paste as rich text elsewhere: controls and hidden parts taken out, elements with
	 * `data-copy` replaced by that text, and every attribute removed except a link's address, a list's start and a
	 * task's tick. Changes `root` in place and returns it.
	 */
	function cleanForHTML(root, doc) {
		const keep = { a: ["href"], ol: ["start"], input: ["type", "checked", "disabled"] };
		const visit = (node) => {
			for (let child = node.firstChild; child; ) {
				const next = child.nextSibling;
				if (child.nodeType === 1) {
					if (child.hasAttribute("data-copy")) {
						node.replaceChild(doc.createTextNode(child.getAttribute("data-copy")), child);
					} else if (dropped(child)) {
						node.removeChild(child);
					} else {
						const allowed = keep[tagOf(child)] ?? [];
						for (const attribute of [...child.attributes]) {
							if (!allowed.includes(attribute.name)) child.removeAttribute(attribute.name);
						}
						visit(child);
					}
				} else if (child.nodeType !== 3) {
					node.removeChild(child);
				}
				child = next;
			}
		};
		visit(root);
		return root;
	}

	return { plainText, cleanForHTML };
});
