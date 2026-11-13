// Formatted documents: `write_document` turns Markdown into a Word, RTF, OpenDocument or HTML file.
//
// The Markdown becomes plain, styled HTML first (nothing in it is ever passed through as markup), and macOS's own
// `textutil` converts that HTML to the other formats. The tool writes a file, so it is given and gated exactly like the
// built-in `write` tool: only with write access, and under "ask" it waits for the person's approval (see extensions.ts).
//
// See docs/documents.md. The converter and the file writing are exported for the tests.

import { execFile } from "node:child_process";
import { constants } from "node:fs";
import { copyFile, lstat, mkdir, mkdtemp, realpath, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, dirname, extname, isAbsolute, resolve, sep } from "node:path";
import type { Context } from "@earendil-works/chord/context";
import { AgentDoc, defineTool, section } from "@earendil-works/pi-durable";
import { bool, obj, opt, str } from "@earendil-works/pi-schema";
import type { Feature } from "./features.ts";

const text = (value: string) => [{ type: "text" as const, text: value }];

// ---- Escaping and links

const ESCAPES: Record<string, string> = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" };
// Control characters have no place in a document, and some break the converters; line breaks and tabs stay.
// biome-ignore lint/suspicious/noControlCharactersInRegex: that is the point
const CONTROL = /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/g;

/** Text or an attribute value, safe between tags and inside double or single quotes. */
export function escapeHtml(value: string): string {
	return value.replace(CONTROL, "").replace(/[&<>"']/g, (c) => ESCAPES[c]!);
}

/** The address if it may be a link: http, https or mailto only, with no spaces or control characters. */
export function safeUrl(raw: string): string | undefined {
	const url = raw.trim();
	// biome-ignore lint/suspicious/noControlCharactersInRegex: control characters hide schemes from filters
	if (/[\s\u0000-\u001f\u007f]/.test(url)) return undefined;
	return /^(?:https?:\/\/[^/?#]|mailto:.)/i.test(url) ? url : undefined;
}

// ---- Inline Markdown

type Piece = { kind: "text"; html: string } | { kind: "mark"; char: string; left: number; open: boolean; close: boolean; before: string; after: string };

const WHITESPACE = /^\s$/;
const PUNCTUATION = /^[\p{P}\p{S}]$/u;
const MAX_DEPTH = 12;

/** Index of the `]` that closes the `[` at `start`, skipping escapes and code, or -1. */
function closingBracket(source: string, start: number): number {
	let depth = 0;
	for (let i = start; i < source.length; i++) {
		const c = source[i];
		if (c === "\\") i++;
		else if (c === "`") {
			const run = /^`+/.exec(source.slice(i))![0];
			const end = source.indexOf(run, i + run.length);
			if (end >= 0) i = end + run.length - 1;
			else i += run.length - 1;
		} else if (c === "[") depth++;
		else if (c === "]" && --depth === 0) return i;
	}
	return -1;
}

/** `(address "title")` at the start of `rest`: what it said and how much of `rest` it took. */
function linkTail(rest: string): { url: string; title: string; length: number } | undefined {
	if (rest[0] !== "(") return undefined;
	let i = 1;
	while (/\s/.test(rest[i] ?? "x")) i++;
	let url = "";
	if (rest[i] === "<") {
		const end = rest.indexOf(">", i);
		if (end < 0 || rest.slice(i, end).includes("\n")) return undefined;
		url = rest.slice(i + 1, end);
		i = end + 1;
	} else {
		let depth = 0;
		const begin = i;
		for (; i < rest.length; i++) {
			const c = rest[i]!;
			if (c === "\\") i++;
			else if (/\s/.test(c)) break;
			else if (c === "(") depth++;
			else if (c === ")") {
				if (depth === 0) break;
				depth--;
			}
		}
		url = rest.slice(begin, i).replace(/\\([\\()<>[\]])/g, "$1");
	}
	while (/\s/.test(rest[i] ?? "x")) i++;
	let title = "";
	const quote = rest[i];
	if (quote === '"' || quote === "'" || quote === "(") {
		const closer = quote === "(" ? ")" : quote;
		let end = i + 1;
		while (end < rest.length && rest[end] !== closer) end += rest[end] === "\\" ? 2 : 1;
		if (end >= rest.length) return undefined;
		title = rest.slice(i + 1, end).replace(/\\(.)/g, "$1");
		i = end + 1;
		while (/\s/.test(rest[i] ?? "x")) i++;
	}
	if (rest[i] !== ")") return undefined;
	return { url, title, length: i + 1 };
}

/** What differs for a format whose writer drops tables and link addresses (Word): see docs/documents.md. */
export type Options = { lean?: boolean };

/** A link. Word files made here cannot hold a link's address, so there it is written out after the words. */
function link(url: string, inner: string, title: string, options: Options): string {
	if (!options.lean) return `<a href="${escapeHtml(url)}"${title === "" ? "" : ` title="${escapeHtml(title)}"`}>${inner}</a>`;
	const words = plainText(inner).trim();
	return words === url || words === url.replace(/^mailto:/i, "") ? inner : `${inner} (${escapeHtml(url)})`;
}

/** HTML as text again: for the aligned grid, where no markup is possible. */
function plainText(html: string): string {
	return html
		.replace(/<br>/g, " ")
		.replace(/<[^>]*>/g, "")
		.replace(/&lt;/g, "<")
		.replace(/&gt;/g, ">")
		.replace(/&quot;/g, '"')
		.replace(/&#39;/g, "'")
		.replace(/&amp;/g, "&");
}

/** Inline Markdown as HTML: emphasis, strikethrough, code, links, line breaks. Everything else is text, escaped. */
export function renderInline(source: string, depth = 0, options: Options = {}): string {
	const pieces: Piece[] = [];
	let buffer = "";
	const flush = () => {
		if (buffer !== "") pieces.push({ kind: "text", html: escapeHtml(buffer) });
		buffer = "";
	};
	const push = (html: string) => {
		flush();
		pieces.push({ kind: "text", html });
	};
	let i = 0;
	while (i < source.length) {
		const c = source[i]!;
		const rest = source.slice(i);
		if (c === "\\") {
			const next = source[i + 1];
			if (next === "\n") {
				push("<br>");
				i += 2;
			} else if (next !== undefined && /[!-/:-@[-`{-~]/.test(next)) {
				buffer += next;
				i += 2;
			} else {
				buffer += c;
				i++;
			}
		} else if (c === "`") {
			const run = /^`+/.exec(rest)![0];
			const end = source.indexOf(run, i + run.length);
			// A run of backticks the same length closes it; with none, the backticks are just text.
			let close = end;
			while (close >= 0 && source[close + run.length] === "`") close = source.indexOf(run, close + run.length + 1);
			if (close < 0) {
				buffer += run;
				i += run.length;
			} else {
				let code = source.slice(i + run.length, close).replace(/\n/g, " ");
				if (code.length > 2 && code.startsWith(" ") && code.endsWith(" ") && code.trim() !== "") code = code.slice(1, -1);
				push(`<code>${escapeHtml(code)}</code>`);
				i = close + run.length;
			}
		} else if (c === "!" && source[i + 1] === "[") {
			// Pictures are not fetched or embedded; what they say in words stays.
			const close = closingBracket(source, i + 1);
			const tail = close < 0 ? undefined : linkTail(source.slice(close + 1));
			if (close >= 0 && tail !== undefined) {
				const alt = source.slice(i + 2, close);
				if (alt.trim() !== "") push(`<em>${depth < MAX_DEPTH ? renderInline(alt, depth + 1, options) : escapeHtml(alt)}</em>`);
				i = close + 1 + tail.length;
			} else {
				buffer += c;
				i++;
			}
		} else if (c === "[") {
			const close = closingBracket(source, i);
			const tail = close < 0 ? undefined : linkTail(source.slice(close + 1));
			if (close >= 0 && tail !== undefined) {
				const label = source.slice(i + 1, close);
				const inner = depth < MAX_DEPTH ? renderInline(label, depth + 1, options) : escapeHtml(label);
				const url = safeUrl(tail.url);
				// A link that is not allowed keeps its words and loses the address.
				push(url === undefined ? inner : link(url, inner, tail.title, options));
				i = close + 1 + tail.length;
			} else {
				buffer += c;
				i++;
			}
		} else if (c === "<" && /^<(?:https?:\/\/[^\s<>]+|mailto:[^\s<>]+|[^\s<>@]+@[^\s<>@]+\.[^\s<>@]+)>/i.test(rest)) {
			const end = rest.indexOf(">");
			const inner = rest.slice(1, end);
			const url = safeUrl(inner.includes(":") ? inner : `mailto:${inner}`);
			push(url === undefined ? escapeHtml(inner) : link(url, escapeHtml(inner), "", options));
			i += end + 1;
		} else if (c === "h" && /^https?:\/\/[^\s<]+/i.test(rest) && !/[\p{L}\p{N}]/u.test(source[i - 1] ?? " ")) {
			// A bare address, without the full stop or bracket that ended the sentence.
			let url = /^https?:\/\/[^\s<]+/i.exec(rest)![0];
			while (/[.,;:!?'"*_~]$/.test(url) || (url.endsWith(")") && (url.match(/\(/g)?.length ?? 0) < (url.match(/\)/g)?.length ?? 0))) url = url.slice(0, -1);
			const safe = safeUrl(url);
			if (safe === undefined) {
				buffer += c;
				i++;
			} else {
				push(link(safe, escapeHtml(url), "", options));
				i += url.length;
			}
		} else if (c === "*" || c === "_" || c === "~") {
			let end = i;
			while (source[end] === c) end++;
			const count = end - i;
			if (c === "~" && count !== 2) {
				buffer += c.repeat(count);
			} else {
				const before = source[i - 1] ?? " ";
				const after = source[end] ?? " ";
				const afterSpace = WHITESPACE.test(after);
				const beforeSpace = WHITESPACE.test(before);
				const leftFlanking = !afterSpace && (!PUNCTUATION.test(after) || beforeSpace || PUNCTUATION.test(before));
				const rightFlanking = !beforeSpace && (!PUNCTUATION.test(before) || afterSpace || PUNCTUATION.test(after));
				// Inside a word an underscore is just an underscore (snake_case).
				const open = c === "_" ? leftFlanking && (!rightFlanking || PUNCTUATION.test(before)) : leftFlanking;
				const close = c === "_" ? rightFlanking && (!leftFlanking || PUNCTUATION.test(after)) : rightFlanking;
				flush();
				pieces.push({ kind: "mark", char: c, left: count, open, close, before: "", after: "" });
			}
			i = end;
		} else if (c === "\n") {
			// Two spaces before a line break make a hard one; otherwise it is a space.
			if (/ {2,}$/.test(buffer)) {
				buffer = buffer.replace(/ +$/, "");
				push("<br>");
			} else buffer = buffer.replace(/ +$/, "") + "\n";
			i++;
			while (source[i] === " ") i++;
		} else {
			buffer += c;
			i++;
		}
	}
	flush();

	// Pair up the emphasis marks, nearest opener first, so the inner pair is settled before the outer.
	for (let closer = 0; closer < pieces.length; closer++) {
		const c = pieces[closer]!;
		if (c.kind !== "mark" || !c.close) continue;
		while (c.left > 0) {
			let opener = closer - 1;
			while (opener >= 0) {
				const o = pieces[opener]!;
				if (o.kind === "mark" && o.char === c.char && o.open && o.left > 0) break;
				opener--;
			}
			if (opener < 0) break;
			const o = pieces[opener] as Extract<Piece, { kind: "mark" }>;
			const used = c.char === "~" ? 2 : o.left >= 2 && c.left >= 2 ? 2 : 1;
			if (c.char === "~" && (o.left < 2 || c.left < 2)) break;
			const [on, off] = c.char === "~" ? ["<del>", "</del>"] : used === 2 ? ["<strong>", "</strong>"] : ["<em>", "</em>"];
			o.left -= used;
			c.left -= used;
			o.after = on + o.after;
			c.before += off;
			// Marks caught between the pair can no longer pair with anything outside it.
			for (let between = opener + 1; between < closer; between++) {
				const m = pieces[between]!;
				if (m.kind === "mark") {
					m.open = false;
					m.close = false;
				}
			}
		}
	}
	return pieces.map((p) => (p.kind === "text" ? p.html : `${p.before}${escapeHtml(p.char.repeat(p.left))}${p.after}`)).join("");
}

// ---- Blocks

const LIST_MARKER = /^( *)([-+*]|\d{1,9}[.)])( +|$)/;
const FENCE_OPEN = /^( {0,3})(`{3,}|~{3,})(.*)$/;
const HEADING = /^ {0,3}(#{1,6})(?:[ \t]+(.*?))?(?:[ \t]+#+)?[ \t]*$/;
const RULE = /^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$/;
const QUOTE_START = /^ {0,3}>/;
const SETEXT = /^ {0,3}(=+|-+)[ \t]*$/;

const indentOf = (line: string) => /^ */.exec(line)![0].length;
const isBlank = (line: string) => line.trim() === "";

function fenceOf(line: string): { indent: number; marker: string } | undefined {
	const m = FENCE_OPEN.exec(line);
	if (m === null) return undefined;
	if (m[2]![0] === "`" && m[3]!.includes("`")) return undefined;
	return { indent: m[1]!.length, marker: m[2]! };
}

/** Whether a line starts something other than a paragraph, so a paragraph ends before it. */
function startsBlock(line: string): boolean {
	if (fenceOf(line) !== undefined || HEADING.test(line) || RULE.test(line) || QUOTE_START.test(line)) return true;
	const list = LIST_MARKER.exec(line);
	// Only a list that begins at 1 may interrupt a paragraph, and an empty item may not.
	return list !== null && indentOf(line) < 4 && list[3] !== "" && (!/\d/.test(list[2]![0]!) || /^0*1[.)]$/.test(list[2]!));
}

function splitRow(line: string): string[] {
	let row = line.trim();
	if (row.startsWith("|")) row = row.slice(1);
	if (row.endsWith("|") && !row.endsWith("\\|")) row = row.slice(0, -1);
	const cells: string[] = [];
	let cell = "";
	for (let i = 0; i < row.length; i++) {
		if (row[i] === "\\" && row[i + 1] === "|") {
			cell += "|";
			i++;
		} else if (row[i] === "|") {
			cells.push(cell.trim());
			cell = "";
		} else cell += row[i];
	}
	cells.push(cell.trim());
	return cells;
}

type Align = "left" | "right" | "center" | "";

/** The alignments a table's delimiter row asks for, or undefined when the line is not one. */
function delimiterRow(line: string, columns: number): Align[] | undefined {
	if (!line.includes("-") || !/^[\s|:-]+$/.test(line)) return undefined;
	const cells = splitRow(line);
	if (cells.length !== columns || !cells.every((cell) => /^:?-+:?$/.test(cell))) return undefined;
	return cells.map((cell) => (cell.startsWith(":") ? (cell.endsWith(":") ? "center" : "left") : cell.endsWith(":") ? "right" : ""));
}

const MAX_COLUMN = 60;

function renderTable(header: string[], align: Align[], rows: string[][], options: Options, depth: number): string {
	const inline = (cell: string) => renderInline(cell, depth, options);
	if (options.lean) {
		// A grid of text in a monospace face: the one table a Word file from textutil can show.
		const grid = [header, ...rows].map((row) => row.map((cell) => plainText(inline(cell))));
		const widths = header.map((_, c) => Math.min(MAX_COLUMN, Math.max(3, ...grid.map((row) => [...row[c]!].length))));
		const pad = (value: string, c: number) => {
			const cut = [...value].length > widths[c]! ? `${[...value].slice(0, widths[c]! - 1).join("")}…` : value;
			const gap = widths[c]! - [...cut].length;
			if (align[c] === "right") return " ".repeat(gap) + cut;
			if (align[c] === "center") return " ".repeat(gap >> 1) + cut + " ".repeat(gap - (gap >> 1));
			return cut + " ".repeat(gap);
		};
		const line = (row: string[]) => ` ${row.map((cell, c) => pad(cell, c)).join(" | ")}`.trimEnd();
		const rule = widths.map((w) => "-".repeat(w + 2)).join("+");
		const [head, ...body] = grid;
		return `<pre>${escapeHtml([line(head!), rule, ...body.map(line)].join("\n"))}</pre>\n`;
	}
	const style = (c: number) => (align[c] === "" || align[c] === undefined ? "" : ` style="text-align:${align[c]}"`);
	const head = header.map((cell, c) => `<th${style(c)}>${inline(cell)}</th>`).join("");
	const body = rows.map((row) => `<tr>${row.map((cell, c) => `<td${style(c)}>${inline(cell)}</td>`).join("")}</tr>`).join("");
	return `<table border="1" cellspacing="0" cellpadding="6"><thead><tr>${head}</tr></thead><tbody>${body}</tbody></table>\n`;
}

function renderList(lines: string[], start: number, depth: number, options: Options): { html: string; next: number } {
	const first = LIST_MARKER.exec(lines[start]!)!;
	const ordered = /\d/.test(first[2]![0]!);
	const delimiter = first[2]!.slice(-1);
	const sameKind = (line: string) => {
		const m = LIST_MARKER.exec(line);
		return m !== null && (ordered ? /\d/.test(m[2]![0]!) && m[2]!.slice(-1) === delimiter : m[2] === first[2]);
	};
	const items: string[] = [];
	let i = start;
	while (i < lines.length) {
		const m = LIST_MARKER.exec(lines[i]!);
		if (m === null || !sameKind(lines[i]!)) break;
		const markerIndent = m[1]!.length;
		const marker = m[2]!;
		// Five or more spaces after the marker are content that happens to be indented, not part of the gap.
		const gap = m[3]!.length > 4 ? 1 : m[3]!.length;
		const contentIndent = markerIndent + marker.length + Math.max(1, gap);
		const content = [lines[i]!.slice(markerIndent + marker.length + gap)];
		let j = i + 1;
		while (j < lines.length) {
			const line = lines[j]!;
			if (isBlank(line)) {
				let k = j;
				while (k < lines.length && isBlank(lines[k]!)) k++;
				if (k >= lines.length) break;
				const after = lines[k]!;
				if (indentOf(after) >= contentIndent || (LIST_MARKER.test(after) && indentOf(after) > markerIndent)) {
					for (let b = j; b < k; b++) content.push("");
					j = k;
					continue;
				}
				break;
			}
			if (indentOf(line) >= contentIndent) content.push(line.slice(contentIndent));
			// A nested list indented less than the text above it is still nested.
			else if (LIST_MARKER.test(line) && indentOf(line) > markerIndent) content.push(line.trimStart());
			else if (!isBlank(content[content.length - 1]!) && !startsBlock(line) && !LIST_MARKER.test(line)) content.push(line.trimStart());
			else break;
			j++;
		}
		i = j;
		let task = "";
		const box = /^\[([ xX])\][ \t]+/.exec(content[0]!);
		if (box !== null) {
			task = box[1] === " " ? "☐ " : "☑ ";
			content[0] = content[0]!.slice(box[0].length);
		}
		items.push(`<li>${task}${renderBlocks(content, depth + 1, options, true).trimEnd()}</li>`);
		while (i < lines.length && isBlank(lines[i]!)) i++;
		if (i < lines.length && !(sameKind(lines[i]!) && indentOf(lines[i]!) <= markerIndent)) break;
	}
	const number = ordered ? Number.parseInt(first[2]!, 10) : 1;
	const tag = ordered ? "ol" : "ul";
	return { html: `<${tag}${ordered && number !== 1 ? ` start="${number}"` : ""}>${items.join("")}</${tag}>\n`, next: i };
}

/** Blocks of Markdown as HTML. `tight` writes a first paragraph without its own tag, as a list item has it. */
export function renderBlocks(lines: string[], depth = 0, options: Options = {}, tight = false): string {
	if (depth > MAX_DEPTH) return `<p>${renderInline(lines.join("\n").trim(), depth, options)}</p>\n`;
	let out = "";
	let i = 0;
	let first = true;
	while (i < lines.length) {
		const line = lines[i]!;
		if (isBlank(line)) {
			i++;
			continue;
		}
		const wasFirst = first;
		first = false;
		const fence = fenceOf(line);
		if (fence !== undefined) {
			const body: string[] = [];
			i++;
			const close = new RegExp(`^ {0,3}${fence.marker[0] === "`" ? "`" : "~"}{${fence.marker.length},}[ \\t]*$`);
			while (i < lines.length && !close.test(lines[i]!)) {
				body.push(lines[i]!.replace(new RegExp(`^ {0,${fence.indent}}`), ""));
				i++;
			}
			i++;
			out += `<pre><code>${escapeHtml(body.join("\n"))}</code></pre>\n`;
			continue;
		}
		const heading = HEADING.exec(line);
		if (heading !== null) {
			const level = heading[1]!.length;
			out += `<h${level}>${renderInline((heading[2] ?? "").trim(), depth, options)}</h${level}>\n`;
			i++;
			continue;
		}
		if (RULE.test(line)) {
			out += "<hr>\n";
			i++;
			continue;
		}
		if (QUOTE_START.test(line)) {
			const inner: string[] = [];
			while (i < lines.length) {
				const l = lines[i]!;
				if (QUOTE_START.test(l)) inner.push(l.replace(/^ {0,3}> ?/, ""));
				else if (!isBlank(l) && inner.length > 0 && !isBlank(inner[inner.length - 1]!) && !startsBlock(l)) inner.push(l);
				else break;
				i++;
			}
			out += `<blockquote>${renderBlocks(inner, depth + 1, options)}</blockquote>\n`;
			continue;
		}
		if (LIST_MARKER.test(line) && indentOf(line) < 4) {
			const list = renderList(lines, i, depth, options);
			out += list.html;
			i = list.next;
			continue;
		}
		if (line.includes("|") && i + 1 < lines.length) {
			const header = splitRow(line);
			const align = delimiterRow(lines[i + 1]!, header.length);
			if (align !== undefined) {
				const rows: string[][] = [];
				i += 2;
				while (i < lines.length && !isBlank(lines[i]!) && lines[i]!.includes("|") && !startsBlock(lines[i]!)) {
					const cells = splitRow(lines[i]!);
					rows.push(header.map((_, c) => cells[c] ?? ""));
					i++;
				}
				out += renderTable(header, align, rows, options, depth);
				continue;
			}
		}
		// A paragraph, or a heading when an underline follows its text.
		const para: string[] = [line.trimStart()];
		i++;
		let setext = 0;
		while (i < lines.length && !isBlank(lines[i]!)) {
			const under = SETEXT.exec(lines[i]!);
			if (under !== null) {
				setext = under[1]![0] === "=" ? 1 : 2;
				i++;
				break;
			}
			if (startsBlock(lines[i]!)) break;
			para.push(lines[i]!.trimStart());
			i++;
		}
		const body = renderInline(para.join("\n").trimEnd(), depth, options);
		out += setext > 0 ? `<h${setext}>${body}</h${setext}>\n` : tight && wasFirst ? body : `<p>${body}</p>\n`;
	}
	return out;
}

/** The Markdown as the body of an HTML page. */
export function renderMarkdown(markdown: string, options: Options = {}): string {
	const lines = markdown
		.replace(/\r\n?/g, "\n")
		.split("\n")
		.map((line) => line.replace(/^[ \t]+/, (lead) => lead.replace(/\t/g, "    ")));
	return renderBlocks(lines, 0, options);
}

// ---- The page

const SANS = `Arial, Helvetica, sans-serif`;
const MONO = `"Courier New", Courier, monospace`;

// Written for textutil's reader as much as for a browser: sizes in points, and only what both understand.
const STYLE = `
body { font-family: ${SANS}; font-size: 11pt; line-height: 1.35; color: #1a1a1a; }
p { margin: 0 0 8pt 0; }
h1, h2, h3, h4, h5, h6 { font-family: ${SANS}; font-weight: bold; color: #111111; margin: 16pt 0 6pt 0; }
h1 { font-size: 22pt; }
h2 { font-size: 17pt; }
h3 { font-size: 14pt; }
h4 { font-size: 12pt; }
h5 { font-size: 11pt; }
h6 { font-size: 11pt; color: #555555; }
code { font-family: ${MONO}; font-size: 10pt; }
pre { font-family: ${MONO}; font-size: 9.5pt; line-height: 1.25; background-color: #f2f2f2; margin: 0 0 10pt 0; padding: 6pt; }
pre code { font-size: 9.5pt; }
ul, ol { margin: 0 0 8pt 0; }
li { margin: 0 0 2pt 0; }
blockquote { margin: 0 0 8pt 18pt; padding-left: 8pt; color: #555555; }
blockquote p { margin: 0 0 8pt 18pt; color: #555555; }
table { border-collapse: collapse; margin: 0 0 10pt 0; }
th, td { border: 1px solid #999999; padding: 4pt 6pt; vertical-align: top; }
th { background-color: #e6e6e6; font-weight: bold; }
hr { border: 0; border-top: 1px solid #999999; margin: 12pt 0; }
a { color: #0b57d0; }
`;

/** A whole HTML page for the Markdown. A title that the text does not already open with is added as a heading. */
export function documentHtml(markdown: string, title?: string, options: Options = {}): string {
	const name = (title ?? "").trim();
	const body = renderMarkdown(markdown, options);
	const heading = name !== "" && !/^\s*<h[12]>/.test(body) ? `<h1>${renderInline(name, 0, options)}</h1>\n` : "";
	return `<!DOCTYPE html>\n<html><head><meta charset="utf-8"><title>${escapeHtml(name)}</title><style>${STYLE}</style></head>\n<body>\n${heading}${body}</body></html>\n`;
}

// ---- Writing the file

export type DocumentFormat = "docx" | "rtf" | "odt" | "html";
export const FORMATS: Record<string, { format: DocumentFormat; name: string }> = {
	".docx": { format: "docx", name: "Word document" },
	".rtf": { format: "rtf", name: "RTF document" },
	".odt": { format: "odt", name: "OpenDocument text" },
	".html": { format: "html", name: "HTML page" },
};
const TEXTUTIL = "/usr/bin/textutil";
const MAX_MARKDOWN = 2_000_000;
const CONVERT_MS = 30_000;

const FORMAT_LIST = ".docx (Word), .rtf, .odt (OpenDocument) and .html";

/** Make `output` from the HTML file `input`. Replaceable so the tests can see what is run. */
export type Converter = (format: "docx" | "rtf" | "odt", input: string, output: string, title: string) => Promise<void>;

/** No shell, a fixed program, arguments as a list, and a time limit. */
const textutil: Converter = (format, input, output, title) =>
	new Promise((done, reject) => {
		execFile(TEXTUTIL, ["-convert", format, "-encoding", "UTF-8", ...(title === "" ? [] : ["-title", title]), "-output", output, input], { timeout: CONVERT_MS, maxBuffer: 1024 * 1024 }, (error, _out, stderr) => {
			if (error === null) return done();
			const killed = (error as { killed?: boolean }).killed === true;
			reject(new Error(killed ? "textutil took too long and was stopped" : `textutil could not convert it${String(stderr).trim() === "" ? "" : `: ${String(stderr).trim().slice(0, 300)}`}`));
		});
	});

const inside = (root: string, path: string) => path === root || path.startsWith(root.endsWith(sep) ? root : root + sep);

/** Where `path` would be: inside `root`, with every folder that exists already resolved so no link can lead out. */
async function targetOf(root: string, path: string): Promise<{ full: string } | { refused: string }> {
	const wanted = path.trim();
	if (wanted === "") return { refused: "path is empty. Give a file name such as report.docx." };
	const full = resolve(root, wanted);
	let parent = dirname(full);
	const missing: string[] = [basename(full)];
	for (;;) {
		try {
			parent = await realpath(parent);
			break;
		} catch {
			const up = dirname(parent);
			if (up === parent) return { refused: `Cannot place ${wanted}.` };
			missing.unshift(basename(parent));
			parent = up;
		}
	}
	const real = resolve(parent, ...missing);
	if (!inside(root, real) || real === root) return { refused: `"${wanted}" is outside this conversation's folder (${root}). Documents can only be written inside it.` };
	return { full: real };
}

export type WriteResult = { text: string; isError?: boolean };

/** Write the document. Every refusal says what to change. `root` is the real path of the conversation's folder. */
export async function writeDocument(root: string, args: { path: string; markdown: string; title?: string; overwrite?: boolean }, convert: Converter = textutil): Promise<WriteResult> {
	const refuse = (message: string): WriteResult => ({ text: `${message} Nothing was written.`, isError: true });
	const extension = extname(args.path.trim()).toLowerCase();
	if (extension === ".pdf") return refuse("PDF is not offered: macOS has no safe way to make one from here. Write a .docx instead; the person can save it as a PDF from Word or Pages.");
	const kind = FORMATS[extension];
	if (kind === undefined) return refuse(`write_document writes ${FORMAT_LIST}, chosen by the file name's ending. "${extension === "" ? args.path.trim() : extension}" is not one of them.`);
	if (args.markdown.trim() === "") return refuse("markdown is empty.");
	if (args.markdown.length > MAX_MARKDOWN) return refuse(`The text is ${Math.round(args.markdown.length / 1000)} thousand characters; the most allowed is ${MAX_MARKDOWN / 1_000_000} million. Split it into several documents.`);
	const target = await targetOf(root, args.path);
	if ("refused" in target) return refuse(target.refused);
	const shown = target.full.slice(root.length + 1);
	const existing = await lstat(target.full).catch(() => undefined);
	if (existing !== undefined) {
		if (!existing.isFile()) return refuse(`${shown} is a ${existing.isDirectory() ? "folder" : "link or special file"}, not a file to replace.`);
		if (args.overwrite !== true) return refuse(`${shown} already exists. To replace it, call again with overwrite: true; or choose another name.`);
	}
	const lean = kind.format === "docx";
	// One line, and never something textutil would read as an option of its own.
	const cleanTitle = (args.title ?? "").replace(/\s+/g, " ").trim().replace(/^-+\s*/, "").slice(0, 200);
	const html = documentHtml(args.markdown, cleanTitle, { lean });
	await mkdir(dirname(target.full), { recursive: true });
	const exclusive = args.overwrite === true ? 0 : constants.COPYFILE_EXCL;
	try {
		if (kind.format === "html") {
			await writeFile(target.full, html, { flag: args.overwrite === true ? "w" : "wx" });
		} else {
			const work = await mkdtemp(resolve(tmpdir(), "pi2-document-"));
			try {
				const input = resolve(work, "document.html");
				const output = resolve(work, `document.${kind.format}`);
				await writeFile(input, html);
				await convert(kind.format, input, output, cleanTitle);
				await copyFile(output, target.full, exclusive);
			} finally {
				await rm(work, { recursive: true, force: true });
			}
		}
	} catch (error) {
		if ((error as { code?: string }).code === "EEXIST") return refuse(`${shown} already exists. To replace it, call again with overwrite: true; or choose another name.`);
		return refuse(`The ${kind.name} could not be written: ${error instanceof Error ? error.message : String(error)}.`);
	}
	const notes = lean ? " Tables are written as aligned text and link addresses are shown after the link text, because Word files made here cannot hold either." : "";
	return { text: `Wrote ${shown} (${kind.name}).${notes}` };
}

// ---- The feature

const GUIDE = [
	"Use write_document when the person asks for a document they will send, print or open in a word processor: a report, letter, memo, proposal, résumé or similar. Write the content as Markdown and name the file with .docx (Word), .rtf, .odt or .html.",
	"Do not use it for notes, code, data files or anything the person will read as plain text; use write for those. Headings, lists, tables, bold and italic, code blocks, quotes and links are kept; pictures are not. Tell the person where the file is when it is done.",
].join(" ");

export const documents: Feature = (host) => {
	const writeDocumentTool = defineTool({
		name: "write_document",
		description:
			"Write a formatted document from Markdown: a Word (.docx), RTF (.rtf), OpenDocument (.odt) or HTML (.html) file, chosen by the ending of `path`. `path` is relative to the conversation's folder, or absolute inside it. " +
			"`markdown` is the content: headings, paragraphs, bold, italic, strikethrough, code, nested lists, task lists, tables, quotes, links and rules. Raw HTML and pictures are not kept. `title` is optional and becomes the document's title. " +
			"A file that already exists is not replaced unless `overwrite` is true.",
		parameters: obj({
			path: str({ description: "File to write, such as report.docx" }),
			markdown: str({ description: "The document's content as Markdown" }),
			title: opt(str({ description: "Document title" })),
			overwrite: opt(bool({ description: "Replace the file if it already exists" })),
		}),
		// A write cut off by a crash may have finished; running it again would find the file and refuse.
		replay: "unsafe",
		execute: async (args, api, context: Context) => {
			const doc = (await api.snapshot(AgentDoc, api.conversationId, context)) as { cwd?: string | null } | undefined;
			const root = await realpath(doc?.cwd ?? host.scratchFolder());
			const result = await writeDocument(root, args);
			return { output: text(result.text), ...(result.isError ? { isError: true } : {}) };
		},
	});
	return {
		tools: [writeDocumentTool],
		// Whoever may use `write` may use this; it writes a file in the same way.
		toolNames: (access) => (access === "ask" || access === "full" ? ["write_document"] : []),
		sections: [section("documents", (input) => (input.agent.tools.some((tool) => tool.name === "write_document") ? GUIDE : undefined))],
	};
};
