// Just enough of the DOM for the transcript's modules to run under Node: elements, text, fragments, attributes, and
// an HTML serializer that escapes the way a browser does. Tests read what the modules built through `html()`.

const VOID = new Set(["br", "hr", "input", "img"]);

class Node {
	constructor(nodeType) {
		this.nodeType = nodeType;
		this.childNodes = [];
		this.parentNode = null;
	}
	get firstChild() {
		return this.childNodes[0] ?? null;
	}
	get lastChild() {
		return this.childNodes[this.childNodes.length - 1] ?? null;
	}
	get nextSibling() {
		if (!this.parentNode) return null;
		const siblings = this.parentNode.childNodes;
		return siblings[siblings.indexOf(this) + 1] ?? null;
	}
	get previousSibling() {
		if (!this.parentNode) return null;
		const siblings = this.parentNode.childNodes;
		return siblings[siblings.indexOf(this) - 1] ?? null;
	}
	get children() {
		return this.childNodes.filter((node) => node.nodeType === 1);
	}
	appendChild(node) {
		if (node.nodeType === 11) {
			for (const child of [...node.childNodes]) this.appendChild(child);
			return node;
		}
		if (node.parentNode) node.parentNode.removeChild(node);
		node.parentNode = this;
		this.childNodes.push(node);
		return node;
	}
	insertBefore(node, reference) {
		if (reference === null) return this.appendChild(node);
		if (node.parentNode) node.parentNode.removeChild(node);
		node.parentNode = this;
		this.childNodes.splice(this.childNodes.indexOf(reference), 0, node);
		return node;
	}
	removeChild(node) {
		const index = this.childNodes.indexOf(node);
		if (index < 0) throw new Error("not a child");
		this.childNodes.splice(index, 1);
		node.parentNode = null;
		return node;
	}
	replaceChild(node, old) {
		this.insertBefore(node, old);
		return this.removeChild(old);
	}
	get textContent() {
		return this.childNodes.map((node) => node.textContent).join("");
	}
	set textContent(value) {
		for (const child of this.childNodes) child.parentNode = null;
		this.childNodes = [];
		if (value !== "") this.appendChild(new Text(String(value)));
	}
}

class Text extends Node {
	constructor(data) {
		super(3);
		this.data = data;
		this.nodeName = "#text";
	}
	get textContent() {
		return this.data;
	}
	set textContent(value) {
		this.data = String(value);
	}
	get nodeValue() {
		return this.data;
	}
}

class Element extends Node {
	constructor(tag) {
		super(1);
		this.localName = tag.toLowerCase();
		this.tagName = this.localName.toUpperCase();
		this.nodeName = this.tagName;
		this._attributes = new Map();
	}
	setAttribute(name, value) {
		this._attributes.set(String(name).toLowerCase(), String(value));
	}
	getAttribute(name) {
		return this._attributes.get(String(name).toLowerCase()) ?? null;
	}
	hasAttribute(name) {
		return this._attributes.has(String(name).toLowerCase());
	}
	removeAttribute(name) {
		this._attributes.delete(String(name).toLowerCase());
	}
	get attributes() {
		return [...this._attributes].map(([name, value]) => ({ name, value }));
	}
	get className() {
		return this.getAttribute("class") ?? "";
	}
	get classList() {
		const element = this;
		return {
			contains: (name) => element.className.split(/\s+/).includes(name),
		};
	}
	get outerHTML() {
		const attributes = [...this._attributes].map(([name, value]) => ` ${name}="${escapeAttribute(value)}"`).join("");
		if (VOID.has(this.localName)) return `<${this.localName}${attributes}>`;
		return `<${this.localName}${attributes}>${this.innerHTML}</${this.localName}>`;
	}
	get innerHTML() {
		return this.childNodes.map(html).join("");
	}
}

class Fragment extends Node {
	constructor() {
		super(11);
		this.nodeName = "#document-fragment";
	}
}

function escapeText(text) {
	return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/ /g, "&nbsp;");
}

function escapeAttribute(text) {
	return text.replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

export function html(node) {
	if (node.nodeType === 3) return escapeText(node.data);
	if (node.nodeType === 1) return node.outerHTML;
	return node.childNodes.map(html).join("");
}

export const document = {
	createElement: (tag) => new Element(tag),
	createElementNS: (_namespace, tag) => new Element(tag),
	createTextNode: (data) => new Text(String(data)),
	createDocumentFragment: () => new Fragment(),
};

/** Builds a tree from a compact description: ["p", {class: "x"}, "text", ["em", "more"]]. */
export function h(tag, ...rest) {
	const element = document.createElement(tag);
	for (const part of rest) {
		if (part === null || part === undefined) continue;
		if (typeof part === "string") element.appendChild(document.createTextNode(part));
		else if (Array.isArray(part)) element.appendChild(h(...part));
		else if (part instanceof Node) element.appendChild(part);
		else for (const [name, value] of Object.entries(part)) element.setAttribute(name, value);
	}
	return element;
}
