/*
 * Markdown for the transcript: CommonMark blocks and inlines plus the GitHub additions people expect (tables, task
 * lists, strikethrough, bare links). Written for this page, with no dependencies.
 *
 * Everything in a transcript is untrusted, so nothing here ever produces markup from input: the parser makes plain
 * objects, and the renderer turns them into elements with createElement and createTextNode. Raw HTML in the source
 * stays visible as the text it is. Links keep only http, https and mailto addresses; anything else is shown as text.
 *
 * Loaded as a plain script by the page (it sets `PiMarkdown`), and imported by Node for the tests.
 */
(function (root, factory) {
	const api = factory();
	if (typeof module === "object" && module.exports) module.exports = api;
	else root.PiMarkdown = api;
})(typeof globalThis !== "undefined" ? globalThis : this, function () {
	"use strict";

	// MARK: - Lines

	const TAB = 4;
	// Characters outside printable ASCII are written by number, so the source says plainly which one is meant.
	const char = String.fromCharCode;

	function isBlank(line) {
		return /^[ \t]*$/.test(line);
	}

	/** Columns of leading whitespace, with tabs to the next multiple of four. */
	function indentOf(line, startColumn = 0) {
		let column = startColumn;
		for (let i = 0; i < line.length; i++) {
			const c = line[i];
			if (c === " ") column++;
			else if (c === "\t") column += TAB - (column % TAB);
			else break;
		}
		return column - startColumn;
	}

	/** Removes up to `n` columns of leading whitespace. A tab that spans the cut leaves its remaining columns as spaces. */
	function stripIndent(line, n, startColumn = 0) {
		let column = startColumn;
		const goal = startColumn + n;
		let i = 0;
		while (i < line.length && column < goal) {
			const c = line[i];
			if (c === " ") {
				column++;
				i++;
			} else if (c === "\t") {
				const width = TAB - (column % TAB);
				if (column + width > goal) return " ".repeat(column + width - goal) + line.slice(i + 1);
				column += width;
				i++;
			} else break;
		}
		return line.slice(i);
	}

	// MARK: - Block starts

	const FENCE = /^( {0,3})(`{3,}|~{3,})(.*)$/;
	const ATX = /^ {0,3}(#{1,6})(?=[ \t]|$)(.*)$/;
	const HR = /^ {0,3}(?:(?:\*[ \t]*){3,}|(?:-[ \t]*){3,}|(?:_[ \t]*){3,})$/;
	const QUOTE = /^ {0,3}>/;
	const SETEXT_1 = /^ {0,3}=+[ \t]*$/;
	// Three or more, not CommonMark's one: a lone "-" is far more often the start of a list item still arriving.
	const SETEXT_2 = /^ {0,3}-{3,}[ \t]*$/;
	const LIST = /^( {0,3})([-+*]|(\d{1,9})([.)]))(?=[ \t]|$)/;

	function fenceStart(line) {
		const m = FENCE.exec(line);
		if (!m) return null;
		const fence = m[2];
		const info = m[3];
		if (fence[0] === "`" && info.includes("`")) return null;
		return { indent: m[1].length, char: fence[0], length: fence.length, info: info.trim() };
	}

	function isFenceEnd(line, open) {
		const m = /^ {0,3}(`{3,}|~{3,})[ \t]*$/.exec(line);
		return !!m && m[1][0] === open.char && m[1].length >= open.length;
	}

	function listStart(line) {
		const m = LIST.exec(line);
		if (!m) return null;
		const indent = m[1].length;
		const markerEnd = indent + m[2].length;
		const rest = line.slice(markerEnd);
		const empty = isBlank(rest);
		const spaces = indentOf(rest, markerEnd);
		// More than four spaces after the marker means the item starts with indented code; the item's own text starts
		// one column after the marker.
		const contentOffset = empty || spaces > 4 ? markerEnd + 1 : markerEnd + spaces;
		return {
			indent,
			markerEnd,
			contentOffset,
			empty,
			ordered: m[3] !== undefined,
			delimiter: m[3] !== undefined ? m[4] : m[2],
			start: m[3] !== undefined ? parseInt(m[3], 10) : 1,
		};
	}

	/** Whether a line can end a paragraph without a blank line before it. */
	function interruptsParagraph(line) {
		if (fenceStart(line) || ATX.test(line) || HR.test(line) || QUOTE.test(line)) return true;
		const item = listStart(line);
		return !!item && !item.empty && (!item.ordered || item.start === 1);
	}

	function isBlockStart(line) {
		return interruptsParagraph(line) || !!listStart(line);
	}

	// MARK: - Tables

	function splitCells(line) {
		let s = line.trim();
		if (s.startsWith("|")) s = s.slice(1);
		if (s.endsWith("|") && !s.endsWith("\\|")) s = s.slice(0, -1);
		const cells = [];
		let cell = "";
		for (let i = 0; i < s.length; i++) {
			const c = s[i];
			if (c === "\\" && s[i + 1] === "|") {
				cell += "|";
				i++;
			} else if (c === "|") {
				cells.push(cell.trim());
				cell = "";
			} else {
				cell += c;
			}
		}
		cells.push(cell.trim());
		return cells;
	}

	function delimiterRow(line) {
		if (!line.includes("|") || !line.includes("-")) return null;
		if (!/^ {0,3}\|?[ \t]*:?-+:?[ \t]*(\|[ \t]*:?-+:?[ \t]*)*\|?[ \t]*$/.test(line)) return null;
		return splitCells(line).map((cell) => {
			const left = cell.startsWith(":");
			const right = cell.endsWith(":");
			return left && right ? "center" : right ? "right" : left ? "left" : "";
		});
	}

	function tableStart(lines, i) {
		if (i + 1 >= lines.length) return null;
		const head = lines[i];
		if (!head.includes("|") || indentOf(head) > 3) return null;
		const align = delimiterRow(lines[i + 1]);
		if (!align) return null;
		const cells = splitCells(head);
		if (cells.length !== align.length) return null;
		return { head: cells, align };
	}

	// MARK: - Blocks

	/**
	 * The blocks of a Markdown text: paragraph, heading, code, quote, list, table and rule, each a plain object.
	 * Inline text is kept as source and parsed when it is rendered.
	 */
	function parse(source) {
		const text = String(source ?? "").replace(/\r\n?/g, "\n").replace(/\u0000/g, char(0xfffd));
		return parseLines(text.split("\n"));
	}

	function parseLines(lines) {
		const blocks = [];
		let i = 0;
		while (i < lines.length) {
			const line = lines[i];
			if (isBlank(line)) {
				i++;
				continue;
			}

			const fence = fenceStart(line);
			if (fence) {
				const body = [];
				let closed = false;
				i++;
				while (i < lines.length) {
					if (isFenceEnd(lines[i], fence)) {
						closed = true;
						i++;
						break;
					}
					body.push(stripIndent(lines[i], fence.indent));
					i++;
				}
				blocks.push({ type: "code", lang: fence.info.split(/\s+/)[0] || "", text: body.join("\n"), closed });
				continue;
			}

			const atx = ATX.exec(line);
			if (atx) {
				let content = atx[2].replace(/^[ \t]+/, "").replace(/[ \t]+$/, "");
				// A closing run of #s is decoration, unless it is all there is.
				content = /^#+$/.test(content) ? "" : content.replace(/[ \t]+#+$/, "");
				blocks.push({ type: "heading", level: atx[1].length, text: content });
				i++;
				continue;
			}

			if (HR.test(line)) {
				blocks.push({ type: "hr" });
				i++;
				continue;
			}

			if (QUOTE.test(line)) {
				const inner = [];
				while (i < lines.length) {
					const l = lines[i];
					if (QUOTE.test(l)) {
						inner.push(l.replace(/^ {0,3}> ?/, ""));
						i++;
					} else if (!isBlank(l) && inner.length > 0 && !isBlank(inner[inner.length - 1]) && !isBlockStart(l)) {
						// A lazy continuation line: the quote's paragraph goes on without its ">".
						inner.push(l);
						i++;
					} else break;
				}
				blocks.push({ type: "quote", children: parseLines(inner) });
				continue;
			}

			const item = listStart(line);
			if (item) {
				const parsed = parseList(lines, i, item);
				blocks.push(parsed.block);
				i = parsed.next;
				continue;
			}

			if (indentOf(line) >= 4) {
				const body = [];
				while (i < lines.length && (isBlank(lines[i]) || indentOf(lines[i]) >= 4)) {
					body.push(stripIndent(lines[i], 4));
					i++;
				}
				while (body.length > 0 && isBlank(body[body.length - 1])) body.pop();
				blocks.push({ type: "code", lang: "", text: body.join("\n"), closed: true });
				continue;
			}

			const table = tableStart(lines, i);
			if (table) {
				const rows = [];
				i += 2;
				while (i < lines.length && !isBlank(lines[i]) && lines[i].includes("|") && !interruptsParagraph(lines[i])) {
					const cells = splitCells(lines[i]);
					rows.push(table.head.map((_, column) => cells[column] ?? ""));
					i++;
				}
				blocks.push({ type: "table", align: table.align, head: table.head, rows });
				continue;
			}

			// A paragraph, or a setext heading if an underline follows it.
			const buffer = [line.replace(/^[ \t]+/, "")];
			i++;
			let heading = 0;
			while (i < lines.length) {
				const l = lines[i];
				if (isBlank(l)) break;
				if (SETEXT_1.test(l)) {
					heading = 1;
					i++;
					break;
				}
				if (SETEXT_2.test(l)) {
					heading = 2;
					i++;
					break;
				}
				if (interruptsParagraph(l) || tableStart(lines, i)) break;
				buffer.push(l.replace(/^[ \t]+/, ""));
				i++;
			}
			const content = buffer.join("\n").replace(/[ \t]+$/, "");
			blocks.push(heading ? { type: "heading", level: heading, text: content } : { type: "paragraph", text: content });
		}
		return blocks;
	}

	function sameList(a, b) {
		return a.ordered === b.ordered && a.delimiter === b.delimiter;
	}

	function parseList(lines, i, first) {
		const list = { type: "list", ordered: first.ordered, start: first.start, loose: false, items: [] };
		let item = first;
		while (item) {
			const firstLine = lines[i];
			const content = [stripIndent(firstLine.slice(item.markerEnd), item.contentOffset - item.markerEnd, item.markerEnd)];
			i++;
			let blankRun = 0;
			let innerBlank = false;
			while (i < lines.length) {
				const l = lines[i];
				if (isBlank(l)) {
					content.push("");
					blankRun++;
					i++;
					continue;
				}
				const indent = indentOf(l);
				if (indent >= item.contentOffset) {
					if (blankRun > 0) innerBlank = true;
					content.push(stripIndent(l, item.contentOffset));
					blankRun = 0;
					i++;
					continue;
				}
				// Not CommonMark, but how people and models write: a list marker indented past this item's own marker
				// belongs to this item, even when it is short of the column the item's text starts at ("1. a" then "  - b").
				const nested = listStart(l);
				if (nested && indent > item.indent && indent >= 2) {
					if (blankRun > 0) innerBlank = true;
					content.push(stripIndent(l, Math.min(indent, item.contentOffset)));
					blankRun = 0;
					i++;
					continue;
				}
				// A lazy continuation line of the item's paragraph.
				if (blankRun === 0 && !isBlockStart(l)) {
					content.push(l);
					i++;
					continue;
				}
				break;
			}
			let trailing = 0;
			while (content.length > 0 && isBlank(content[content.length - 1])) {
				content.pop();
				trailing++;
			}
			const children = parseLines(content);
			let task = null;
			const lead = children[0];
			if (lead && lead.type === "paragraph") {
				const m = /^\[([ xX])\](?:[ \t]+|$)/.exec(lead.text);
				if (m) {
					task = m[1] !== " ";
					lead.text = lead.text.slice(m[0].length);
				}
			}
			list.items.push({ task, children });
			if (innerBlank && children.length > 1) list.loose = true;

			const next = i < lines.length ? listStart(lines[i]) : null;
			if (next && sameList(next, first) && next.indent < item.contentOffset) {
				if (trailing > 0) list.loose = true;
				item = next;
			} else {
				item = null;
			}
		}
		return { block: list, next: i };
	}

	// MARK: - Inlines

	const ASCII_PUNCTUATION = /^[!-\/:-@\[-`{-~]$/;
	const ENTITIES = {
		amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: char(0xa0), copy: "©", reg: "®", trade: "™",
		hellip: "…", mdash: "—", ndash: "–", lsquo: "‘", rsquo: "’", ldquo: "“", rdquo: "”", laquo: "«", raquo: "»",
		times: "×", divide: "÷", middot: "·", bull: "•", deg: "°", plusmn: "±", larr: "←", rarr: "→", uarr: "↑",
		darr: "↓", harr: "↔", le: "≤", ge: "≥", ne: "≠", euro: "€", pound: "£", yen: "¥", cent: "¢", sect: "§",
		para: "¶", shy: char(0xad), zwj: char(0x200d), zwnj: char(0x200c), check: "✓",
	};

	function charClass(ch) {
		if (ch === undefined || ch === "") return "space";
		if (/\s/u.test(ch)) return "space";
		if (/[\p{P}\p{S}]/u.test(ch)) return "punct";
		return "other";
	}

	function charBefore(src, i) {
		if (i <= 0) return "";
		const low = src.charCodeAt(i - 1);
		if (low >= 0xdc00 && low <= 0xdfff && i >= 2) return src.slice(i - 2, i);
		return src[i - 1];
	}

	function charAt(src, i) {
		if (i >= src.length) return "";
		return String.fromCodePoint(src.codePointAt(i));
	}

	/** Parses `(destination "title")` after a link's closing bracket; null when it is not one. */
	function linkTail(src, start) {
		if (src[start] !== "(") return null;
		let i = start + 1;
		const skipSpace = () => {
			let newlines = 0;
			while (i < src.length && (src[i] === " " || src[i] === "\t" || src[i] === "\n")) {
				if (src[i] === "\n" && ++newlines > 1) return false;
				i++;
			}
			return true;
		};
		if (!skipSpace()) return null;
		let href = "";
		if (src[i] === "<") {
			i++;
			while (i < src.length && src[i] !== ">") {
				if (src[i] === "\n" || src[i] === "<") return null;
				if (src[i] === "\\" && ASCII_PUNCTUATION.test(src[i + 1] ?? "")) i++;
				href += src[i];
				i++;
			}
			if (src[i] !== ">") return null;
			i++;
		} else {
			let depth = 0;
			while (i < src.length) {
				const c = src[i];
				if (c === "\\" && ASCII_PUNCTUATION.test(src[i + 1] ?? "")) {
					href += src[i + 1];
					i += 2;
					continue;
				}
				if (/[\s\u0000-\u001f]/.test(c)) break;
				if (c === "(") depth++;
				if (c === ")") {
					if (depth === 0) break;
					depth--;
				}
				href += c;
				i++;
			}
			if (depth !== 0) return null;
		}
		const beforeTitle = i;
		if (!skipSpace()) return null;
		let title = null;
		const quote = src[i];
		if ((quote === '"' || quote === "'" || quote === "(") && i > beforeTitle) {
			const close = quote === "(" ? ")" : quote;
			let j = i + 1;
			let value = "";
			while (j < src.length && src[j] !== close) {
				if (src[j] === "\\" && ASCII_PUNCTUATION.test(src[j + 1] ?? "")) j++;
				value += src[j];
				j++;
			}
			if (src[j] !== close) return null;
			title = value;
			i = j + 1;
			if (!skipSpace()) return null;
		}
		if (src[i] !== ")") return null;
		return { href, title, end: i + 1 };
	}

	/** A bare web address at `i`, as GitHub links them: what to show and where it goes, or null. */
	function bareLink(src, i) {
		const m = /^(?:https?:\/\/|www\.)[^\s<]*/i.exec(src.slice(i, i + 4096));
		if (!m) return null;
		let url = m[0];
		for (;;) {
			const before = url;
			url = url.replace(/[?!.,:*_~'";]+$/, "");
			if (url.endsWith(")")) {
				const open = (url.match(/\(/g) || []).length;
				const close = (url.match(/\)/g) || []).length;
				if (close > open) url = url.slice(0, -1);
			}
			if (url === before) break;
		}
		const host = url.replace(/^(?:https?:\/\/)/i, "").split(/[\/?#]/)[0];
		if (host.length === 0 || (/^www\./i.test(url) && !/\.[^.]+$/.test(host.slice(4)))) return null;
		return { text: url, href: /^www\./i.test(url) ? "http://" + url : url };
	}

	/**
	 * Inline nodes of a text: text, code, em, strong, del, link, image, br and softbreak. Emphasis follows CommonMark's
	 * delimiter rules, so snake_case words and 2*3*4 stay as written.
	 */
	function parseInline(source) {
		const src = String(source ?? "");
		const nodes = [];
		const delimiters = [];
		const brackets = [];
		let text = "";
		const flush = () => {
			if (text) {
				nodes.push({ type: "text", text });
				text = "";
			}
		};
		let i = 0;
		while (i < src.length) {
			const c = src[i];

			if (c === "\\") {
				const next = src[i + 1];
				if (next === "\n") {
					flush();
					nodes.push({ type: "br" });
					i += 2;
					while (src[i] === " " || src[i] === "\t") i++;
					continue;
				}
				if (next !== undefined && ASCII_PUNCTUATION.test(next)) {
					text += next;
					i += 2;
					continue;
				}
				text += c;
				i++;
				continue;
			}

			if (c === "`") {
				let run = 0;
				while (src[i + run] === "`") run++;
				let j = i + run;
				let close = -1;
				while (j < src.length) {
					if (src[j] === "`") {
						let other = 0;
						while (src[j + other] === "`") other++;
						if (other === run) {
							close = j;
							break;
						}
						j += other;
					} else j++;
				}
				if (close >= 0) {
					let code = src.slice(i + run, close).replace(/\n/g, " ");
					if (code.length >= 2 && code[0] === " " && code[code.length - 1] === " " && /[^ ]/.test(code)) code = code.slice(1, -1);
					flush();
					nodes.push({ type: "code", text: code });
					i = close + run;
					continue;
				}
				text += "`".repeat(run);
				i += run;
				continue;
			}

			if (c === "<") {
				const rest = src.slice(i, i + 2048);
				const uri = /^<([a-zA-Z][a-zA-Z0-9+.-]{1,31}:[^\s<>\u0000-\u001f]*)>/.exec(rest);
				if (uri) {
					flush();
					nodes.push({ type: "link", href: uri[1], title: null, children: [{ type: "text", text: uri[1] }] });
					i += uri[0].length;
					continue;
				}
				const email = /^<([a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*)>/.exec(rest);
				if (email) {
					flush();
					nodes.push({ type: "link", href: "mailto:" + email[1], title: null, children: [{ type: "text", text: email[1] }] });
					i += email[0].length;
					continue;
				}
				text += c;
				i++;
				continue;
			}

			if (c === "&") {
				const m = /^&(?:#[xX]([0-9a-fA-F]{1,6})|#([0-9]{1,7})|([a-zA-Z][a-zA-Z0-9]{1,31}));/.exec(src.slice(i, i + 40));
				if (m) {
					let value = null;
					if (m[3] !== undefined) value = Object.prototype.hasOwnProperty.call(ENTITIES, m[3]) ? ENTITIES[m[3]] : null;
					else {
						const code = m[1] !== undefined ? parseInt(m[1], 16) : parseInt(m[2], 10);
						value = code === 0 || code > 0x10ffff || (code >= 0xd800 && code <= 0xdfff) ? char(0xfffd) : String.fromCodePoint(code);
					}
					if (value !== null) {
						text += value;
						i += m[0].length;
						continue;
					}
				}
				text += c;
				i++;
				continue;
			}

			if (c === "\n") {
				const hard = / {2,}$/.test(text);
				text = text.replace(/[ \t]+$/, "");
				flush();
				nodes.push({ type: hard ? "br" : "softbreak" });
				i++;
				while (src[i] === " " || src[i] === "\t") i++;
				continue;
			}

			if (c === "*" || c === "_" || c === "~") {
				let run = 0;
				while (src[i + run] === c) run++;
				const before = charClass(charBefore(src, i));
				const after = charClass(charAt(src, i + run));
				const left = after !== "space" && (after !== "punct" || before === "space" || before === "punct");
				const right = before !== "space" && (before !== "punct" || after === "space" || after === "punct");
				flush();
				const node = { type: "text", text: c.repeat(run) };
				nodes.push(node);
				if (c === "*") delimiters.push({ node, char: c, length: run, original: run, canOpen: left, canClose: right });
				else if (c === "_")
					delimiters.push({
						node, char: c, length: run, original: run,
						canOpen: left && (!right || before === "punct"),
						canClose: right && (!left || after === "punct"),
					});
				// Strikethrough takes two tildes only, so "~5 minutes" is never struck through.
				else if (run === 2) delimiters.push({ node, char: c, length: run, original: run, canOpen: left, canClose: right });
				i += run;
				continue;
			}

			if (c === "[" || (c === "!" && src[i + 1] === "[")) {
				flush();
				const image = c === "!";
				const node = { type: "text", text: image ? "![" : "[" };
				nodes.push(node);
				brackets.push({ node, image, active: true, bottom: delimiters.length });
				i += image ? 2 : 1;
				continue;
			}

			if (c === "]") {
				const opener = brackets[brackets.length - 1];
				const tail = opener && opener.active ? linkTail(src, i + 1) : null;
				if (!opener || !tail) {
					if (opener) brackets.pop();
					text += c;
					i++;
					continue;
				}
				flush();
				processEmphasis(nodes, delimiters, opener.bottom);
				const at = nodes.indexOf(opener.node);
				const children = nodes.splice(at + 1);
				nodes[at] = { type: opener.image ? "image" : "link", href: tail.href, title: tail.title, children };
				brackets.pop();
				// No links inside links.
				if (!opener.image) for (const bracket of brackets) if (!bracket.image) bracket.active = false;
				i = tail.end;
				continue;
			}

			if ((c === "h" || c === "H" || c === "w" || c === "W") && /^(?:http|www\.)$/i.test(src.slice(i, i + 4)) && /^(|[\s*_~(])$/u.test(charBefore(src, i))) {
				const link = bareLink(src, i);
				if (link) {
					flush();
					nodes.push({ type: "link", href: link.href, title: null, children: [{ type: "text", text: link.text }] });
					i += link.text.length;
					continue;
				}
			}

			text += c;
			i++;
		}
		flush();
		processEmphasis(nodes, delimiters, 0);
		return merge(nodes);
	}

	/** CommonMark's "process emphasis": pairs delimiter runs above `bottom` into em, strong and del nodes. */
	function processEmphasis(nodes, delimiters, bottom) {
		// Thousands of unmatched runs are not prose; leave them as text rather than spend quadratic time on them.
		if (delimiters.length - bottom > 2000) {
			delimiters.length = bottom;
			return;
		}
		let closerIndex = bottom;
		while (closerIndex < delimiters.length) {
			const closer = delimiters[closerIndex];
			if (!closer.canClose) {
				closerIndex++;
				continue;
			}
			let openerIndex = closerIndex - 1;
			let found = false;
			while (openerIndex >= bottom) {
				const opener = delimiters[openerIndex];
				if (opener.char === closer.char && opener.canOpen) {
					if (closer.char === "~") {
						if (opener.length === closer.length) {
							found = true;
							break;
						}
					} else {
						const multipleOfThree =
							(opener.canClose || closer.canOpen) &&
							(opener.original + closer.original) % 3 === 0 &&
							!(opener.original % 3 === 0 && closer.original % 3 === 0);
						if (!multipleOfThree) {
							found = true;
							break;
						}
					}
				}
				openerIndex--;
			}
			if (!found) {
				if (!closer.canOpen) delimiters.splice(closerIndex, 1);
				else closerIndex++;
				continue;
			}
			const opener = delimiters[openerIndex];
			const use = closer.char === "~" ? 2 : closer.length >= 2 && opener.length >= 2 ? 2 : 1;
			const type = closer.char === "~" ? "del" : use === 2 ? "strong" : "em";
			opener.length -= use;
			closer.length -= use;
			opener.node.text = opener.char.repeat(opener.length);
			closer.node.text = closer.char.repeat(closer.length);
			const start = nodes.indexOf(opener.node);
			const end = nodes.indexOf(closer.node);
			const inner = nodes.splice(start + 1, end - start - 1);
			nodes.splice(start + 1, 0, { type, children: inner });
			delimiters.splice(openerIndex + 1, closerIndex - openerIndex - 1);
			closerIndex = openerIndex + 1;
			if (opener.length === 0) {
				nodes.splice(nodes.indexOf(opener.node), 1);
				delimiters.splice(openerIndex, 1);
				closerIndex--;
			}
			if (closer.length === 0) {
				nodes.splice(nodes.indexOf(closer.node), 1);
				delimiters.splice(closerIndex, 1);
			}
		}
		delimiters.length = bottom;
	}

	/** Joins neighbouring text nodes and drops empty ones, recursively. */
	function merge(nodes) {
		const out = [];
		for (const node of nodes) {
			if (node.type === "text") {
				if (node.text === "") continue;
				const last = out[out.length - 1];
				if (last && last.type === "text") last.text += node.text;
				else out.push({ type: "text", text: node.text });
			} else {
				if (node.children) node.children = merge(node.children);
				out.push(node);
			}
		}
		return out;
	}

	/** The words of inline nodes, without their formatting. */
	function inlineText(nodes) {
		let out = "";
		for (const node of nodes) {
			if (node.type === "text" || node.type === "code") out += node.text;
			else if (node.type === "br" || node.type === "softbreak") out += "\n";
			else if (node.children) out += inlineText(node.children);
		}
		return out;
	}

	// MARK: - Links

	/** Spaces and control characters, which no address in a link may contain once tabs and line breaks are dropped. */
	const UNSAFE_IN_URL = new RegExp(
		"[" +
			[[0x00, 0x20], [0x7f, 0x9f], [0xa0], [0x1680], [0x2000, 0x200f], [0x2028, 0x202f], [0x205f, 0x206f], [0x3000], [0xfeff]]
				.map(([from, to]) => char(from) + (to === undefined ? "" : "-" + char(to)))
				.join("") +
			"]",
	);

	/**
	 * The address to put on a link, or null when it may not have one: only http and https (with a host) and mailto.
	 * Tabs and line breaks are dropped, as a browser would drop them; any other space or control character refuses it.
	 */
	function safeURL(raw) {
		if (typeof raw !== "string") return null;
		let start = 0;
		let end = raw.length;
		while (start < end && raw.charCodeAt(start) <= 0x20) start++;
		while (end > start && raw.charCodeAt(end - 1) <= 0x20) end--;
		const url = raw.slice(start, end).replace(/[\t\n\r]/g, "");
		if (url.length === 0 || url.length > 8192) return null;
		if (UNSAFE_IN_URL.test(url)) return null;
		if (/^https?:\/\/[^\/?#\\@:]/i.test(url)) return url;
		if (/^https?:\/\/[^\/?#\\]*@[^\/?#\\@:]/i.test(url)) return url;
		if (/^mailto:[^\/\\]/i.test(url)) return url;
		return null;
	}

	// MARK: - Rendering

	function element(doc, tag, className) {
		const el = doc.createElement(tag);
		if (className) el.setAttribute("class", className);
		return el;
	}

	function renderInline(doc, nodes, parent, inLink = false) {
		for (const node of nodes) {
			switch (node.type) {
				case "text":
					parent.appendChild(doc.createTextNode(node.text));
					break;
				case "code": {
					const code = element(doc, "code");
					code.appendChild(doc.createTextNode(node.text));
					parent.appendChild(code);
					break;
				}
				case "em":
				case "strong":
				case "del": {
					const el = element(doc, node.type);
					renderInline(doc, node.children, el, inLink);
					parent.appendChild(el);
					break;
				}
				case "br":
				case "softbreak":
					// Single line breaks are kept: in a chat they are meant (an address, a short list without markers).
					parent.appendChild(element(doc, "br"));
					break;
				case "link": {
					const url = inLink ? null : safeURL(node.href);
					if (url === null) {
						renderInline(doc, node.children, parent, inLink);
						break;
					}
					const a = element(doc, "a");
					a.setAttribute("href", url);
					a.setAttribute("title", url);
					renderInline(doc, node.children, a, true);
					parent.appendChild(a);
					break;
				}
				case "image": {
					// Pictures are never fetched: the page makes no requests. A web picture becomes a link to it.
					const alt = inlineText(node.children);
					const url = inLink ? null : safeURL(node.href);
					if (url === null || /^mailto:/i.test(url)) {
						if (alt) parent.appendChild(doc.createTextNode(alt));
						break;
					}
					const a = element(doc, "a", "image-link");
					a.setAttribute("href", url);
					a.setAttribute("title", url);
					a.appendChild(doc.createTextNode(alt || "Picture"));
					parent.appendChild(a);
					break;
				}
			}
		}
	}

	function renderCode(doc, block) {
		const box = element(doc, "div", "codeblock");
		const head = element(doc, "div", "code-head");
		head.setAttribute("data-nocopy", "");
		const lang = element(doc, "span", "code-lang");
		lang.appendChild(doc.createTextNode(block.lang.slice(0, 40)));
		head.appendChild(lang);
		const copy = element(doc, "button", "copy-button");
		copy.setAttribute("type", "button");
		copy.setAttribute("data-action", "copy-code");
		copy.setAttribute("aria-label", block.lang ? `Copy ${block.lang.slice(0, 40)} code` : "Copy code");
		copy.appendChild(doc.createTextNode("Copy"));
		head.appendChild(copy);
		box.appendChild(head);
		const pre = element(doc, "pre");
		const code = element(doc, "code");
		code.appendChild(doc.createTextNode(block.text));
		pre.appendChild(code);
		box.appendChild(pre);
		return box;
	}

	function renderBlock(doc, block) {
		switch (block.type) {
			case "paragraph": {
				const p = element(doc, "p");
				renderInline(doc, parseInline(block.text), p);
				return p;
			}
			case "heading": {
				const h = element(doc, "h" + block.level);
				renderInline(doc, parseInline(block.text), h);
				return h;
			}
			case "code":
				return renderCode(doc, block);
			case "quote": {
				const quote = element(doc, "blockquote");
				for (const child of block.children) quote.appendChild(renderBlock(doc, child));
				return quote;
			}
			case "list": {
				const list = element(doc, block.ordered ? "ol" : "ul");
				if (block.ordered && block.start !== 1) list.setAttribute("start", String(block.start));
				if (block.items.some((item) => item.task !== null)) list.setAttribute("class", "tasks");
				for (const item of block.items) {
					const li = element(doc, "li", item.task !== null ? "task" : "");
					if (item.task !== null) {
						const box = element(doc, "input");
						box.setAttribute("type", "checkbox");
						box.setAttribute("disabled", "");
						if (item.task) box.setAttribute("checked", "");
						box.setAttribute("aria-label", item.task ? "Done" : "Not done");
						li.appendChild(box);
					}
					for (const child of item.children) {
						if (!block.loose && child.type === "paragraph") {
							const span = element(doc, "span", "li-text");
							renderInline(doc, parseInline(child.text), span);
							li.appendChild(span);
						} else {
							li.appendChild(renderBlock(doc, child));
						}
					}
					list.appendChild(li);
				}
				return list;
			}
			case "table": {
				const wrap = element(doc, "div", "table-wrap");
				const table = element(doc, "table");
				const head = element(doc, "thead");
				const headRow = element(doc, "tr");
				block.head.forEach((cell, column) => {
					const th = element(doc, "th", block.align[column] ? "align-" + block.align[column] : "");
					renderInline(doc, parseInline(cell), th);
					headRow.appendChild(th);
				});
				head.appendChild(headRow);
				table.appendChild(head);
				if (block.rows.length > 0) {
					const body = element(doc, "tbody");
					for (const row of block.rows) {
						const tr = element(doc, "tr");
						row.forEach((cell, column) => {
							const td = element(doc, "td", block.align[column] ? "align-" + block.align[column] : "");
							renderInline(doc, parseInline(cell), td);
							tr.appendChild(td);
						});
						body.appendChild(tr);
					}
					table.appendChild(body);
				}
				wrap.appendChild(table);
				return wrap;
			}
			case "hr":
				return element(doc, "hr");
		}
		return element(doc, "div");
	}

	/** Renders Markdown into a fragment of new elements. */
	function render(doc, source) {
		const fragment = doc.createDocumentFragment();
		for (const block of parse(source)) fragment.appendChild(renderBlock(doc, block));
		return fragment;
	}

	/**
	 * Brings `container`'s children in line with `source`, replacing only the blocks that changed. A streaming answer
	 * re-renders its last paragraph many times a second; the ones above it, and any text selected in them, stay put.
	 */
	function patch(doc, container, source) {
		const blocks = parse(source);
		const existing = [];
		for (let child = container.firstChild; child; child = child.nextSibling) existing.push(child);
		blocks.forEach((block, index) => {
			const key = JSON.stringify(block);
			const old = existing[index];
			if (old && old.__mdKey === key) return;
			const el = renderBlock(doc, block);
			el.__mdKey = key;
			if (old) container.replaceChild(el, old);
			else container.appendChild(el);
		});
		for (let index = blocks.length; index < existing.length; index++) container.removeChild(existing[index]);
		return blocks.length;
	}

	return { parse, parseInline, inlineText, render, renderInline, renderBlock, patch, safeURL };
});
