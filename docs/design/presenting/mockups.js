// Builds the mockups of docs/design/presenting.md from the address's #…: take=A|B|C with layout=wide|narrow, or
// window=pictures|page. Static content, written by hand: nothing here comes from a conversation.

"use strict";

const PATHS = {
	chevron: ["M6 3.8 10.2 8 6 12.2"],
	terminal: ["M2.5 3h11a1 1 0 0 1 1 1v8a1 1 0 0 1-1 1h-11a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1z", "M4.5 6.5 6.5 8.2 4.5 10", "M8 10h3.5"],
	pencil: ["M10.8 2.7l2.5 2.5-7.6 7.6-3.2.7.7-3.2z", "M9.5 4l2.5 2.5"],
	picture: ["M2.5 3h11a1 1 0 0 1 1 1v8a1 1 0 0 1-1 1h-11a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1z", "M1.8 11l3.6-3.6 3 3 2-2 3.8 3.8", "M10.5 6.2v.1"],
	expand: ["M9.5 2.5h4v4", "M13.5 2.5 9 7", "M6.5 13.5h-4v-4", "M2.5 13.5 7 9"],
	page: ["M4 1.8h5.2l2.8 2.8v9.6H4z", "M9 1.8v3h3", "M6 8.5h4", "M6 10.8h4"],
	back: ["M10 3.8 5.8 8l4.2 4.2"],
	forward: ["M6 3.8 10.2 8 6 12.2"],
	reload: ["M13 8a5 5 0 1 1-1.5-3.6", "M13 2.2v2.6h-2.6"],
	globe: ["M8 14.5a6.5 6.5 0 1 0 0-13 6.5 6.5 0 0 0 0 13z", "M1.5 8h13", "M8 1.5c2 2.2 2 10.8 0 13", "M8 1.5c-2 2.2-2 10.8 0 13"],
	minus: ["M4 8h8"],
	plus: ["M4 8h8", "M8 4v8"],
	sun: ["M8 10.5a2.5 2.5 0 1 0 0-5 2.5 2.5 0 0 0 0 5z", "M8 1.5v1.5", "M8 13v1.5", "M1.5 8H3", "M13 8h1.5", "M3.4 3.4l1 1", "M11.6 11.6l1 1", "M3.4 12.6l1-1", "M11.6 4.4l1-1"],
	moon: ["M13 9.5A5.5 5.5 0 1 1 6.5 3a4.5 4.5 0 0 0 6.5 6.5z"],
	checker: ["M2.5 2.5h11v11h-11z", "M2.5 8h11", "M8 2.5v11"],
	strip: ["M2.5 3h11v6.5h-11z", "M2.5 11.5h3", "M6.5 11.5h3", "M10.5 11.5h3"],
	check: ["M3 8.6l3 3 7-7.2"],
};

const glyph = (name, cls = "glyph") =>
	`<svg viewBox="0 0 16 16" class="${cls}" aria-hidden="true">${PATHS[name].map((d) => `<path d="${d}"/>`).join("")}</svg>`;

// ---- What the agent made: small sign-in screens and a settings page, drawn in CSS so that they scale

function screen(kind, version = 1) {
	const v2 = version > 1 ? " v2" : "";
	switch (kind) {
		case "settings":
			return `<div class="screen s-settings"><div class="ss-bar"><i></i><i></i><i></i><b>Settings</b></div>
				<div class="ss-side"><span class="on">General</span><span>Chat</span><span>Providers</span><span>Tools</span><span>Storage</span></div>
				<div class="ss-main"><h4>General</h4>
					<div class="ss-row"><span>Appearance</span><em class="ss-select">Dark</em></div>
					<div class="ss-row"><span>Notify when an agent finishes</span><em class="ss-toggle on"></em></div>
					<div class="ss-row"><span>Notify at a limit</span><em class="ss-toggle on"></em></div>
					<div class="ss-row"><span>Keep the Mac awake while agents work</span><em class="ss-toggle"></em></div>
					<div class="ss-row"><span>Default model for agents</span><em class="ss-select">Claude Sonnet</em></div>
					<div class="ss-row"><span>Check for updates</span><em class="ss-toggle on"></em></div>
				</div></div>`;
		case "signin-a":
			return `<div class="screen s-a${v2}"><div class="sa-card"><i class="logo"></i><h4>Welcome back</h4>
				<span class="field">name@example.com</span><span class="field">Password</span>
				<span class="hint">Caps Lock is on</span><span class="button">Sign in</span><span class="link">Forgot your password?</span></div></div>`;
		case "signin-b":
			return `<div class="screen s-b${v2}"><div class="sb-brand"><i class="logo"></i><h4>Plan less.<br>Ship more.</h4><span class="bar"></span><span class="bar short"></span></div>
				<div class="sb-form"><h5>Sign in</h5><label>Email</label><span class="field"></span><label>Password</label><span class="field"></span>
				<span class="button">Continue</span><span class="or">or continue with</span><span class="alt"><b>Apple</b><b>Google</b></span></div></div>`;
		case "signin-c":
			return `<div class="screen s-c${v2}"><div class="sc-in"><span class="brand">northwind</span><h4>Sign in</h4>
				<span class="field">Email</span><span class="field">Password</span><span class="button">Sign in →</span>
				<span class="foot">New here? Make an account</span></div></div>`;
	}
	return "";
}

const SIGNIN = [
	{ label: "A", name: "Centred", caption: "Today's form in a card, on a soft wash", kind: "signin-a", file: "mockups/signin-a.png" },
	{ label: "B", name: "Split", caption: "The product's promise beside the form; Apple and Google", kind: "signin-b", file: "mockups/signin-b/index.html", page: "1280×900" },
	{ label: "C", name: "Plain", caption: "Nothing but the fields, large type", kind: "signin-c", file: "mockups/signin-c.svg" },
];

const SETTINGS = [{ label: "", name: "Settings › General", caption: "As it is now, in a throwaway copy (light text on dark)", kind: "settings", file: "app/build/shots/946/settings.png" }];

const QUESTION = { text: "Which one should I build?", choices: ["Use A", "Use B", "Use C"] };

// ---- The conversation around the cards

const user = (text) => `<div class="msg user"><div class="bubble">${text}</div></div>`;
const toolRow = (icon, label) =>
	`<div class="tool"><div class="row-head">${glyph(icon)}<span class="tool-label">${label}</span><span class="chevron">${glyph("chevron", "chevron-glyph")}</span></div></div>`;
const tools = (...rows) => `<div class="tools">${rows.join("")}</div>`;
const prose = (...paragraphs) => `<div class="md">${paragraphs.map((p) => `<p>${p}</p>`).join("")}</div>`;
const assistant = (...parts) => `<div class="msg assistant">${parts.join("")}</div>`;
const presentRow = (what) => tools(toolRow("picture", what));

const ask = (question, layout) =>
	`<div class="present-ask"><p class="card-question">${question.text}</p>
		<div class="card-buttons">${question.choices.map((c) => `<button class="btn">${c}</button>`).join("")}</div>
		<div class="card-answer"><textarea class="answer-field" rows="1" placeholder="${layout === "narrow" ? "Or say it in words" : "Or say it in words: “B, with A’s warning colour”"}"></textarea><button class="btn primary">Send</button></div></div>`;

const pageMark = (item) => (item.page ? `<span class="page-mark">${glyph("page", "mark-glyph")}Page · ${item.page}</span>` : "");
const expandButton = (words = true) => `<button class="link-button expand">${glyph("expand", "open-glyph")}${words ? "Expand" : ""}</button>`;

/** The note in a card's head: whose, which presentation and version. */
const note = (p) => `${p.id} · version ${p.version}${p.question ? " · waits for you" : ""}`;

// ---- Take A: Gallery

function takeA(p, layout) {
	const head = `<div class="card-head"><span class="card-title">${p.title}</span><span class="card-note">${note(p)}</span>${expandButton()}</div>`;
	const one = p.items.length === 1;
	let body;
	if (one || layout === "wide") {
		body = `<div class="pa-grid n${p.items.length}">${p.items
			.map(
				(item) => `<figure class="pa-item"><div class="pa-frame">${screen(item.kind, p.version)}${item.label ? `<span class="pa-label">${item.label}</span>` : ""}${pageMark(item)}</div>
				<figcaption>${one ? "" : `<strong>${item.name}</strong> `}${item.caption}</figcaption></figure>`,
			)
			.join("")}</div>`;
	} else {
		const item = p.items[1];
		body = `<div class="pa-tabs">${p.items.map((it, i) => `<button class="${i === 1 ? "on" : ""}">${it.label} · ${it.name}</button>`).join("")}</div>
			<figure class="pa-item"><div class="pa-frame">${screen(item.kind, p.version)}<span class="pa-label">${item.label}</span>${pageMark(item)}</div>
			<figcaption>${item.caption}</figcaption></figure><div class="dots">${p.items.map((_, i) => `<i class="${i === 1 ? "on" : ""}"></i>`).join("")}</div>`;
	}
	const newer = p.newer ? `<p class="present-newer">A newer version is below.</p>` : "";
	return `<section class="card present pa">${head}${body}${p.question ? ask(p.question, layout) : ""}${newer}</section>`;
}

// ---- Take B: Filmstrip

function takeB(p, layout) {
	const head = `<div class="pb-head"><span class="avatar">F</span><span class="pb-who">Forge presented</span><span class="pb-title">${p.title}</span><span class="pb-note">${note(p)}</span>${expandButton()}</div>`;
	const one = p.items.length === 1;
	const items = p.items
		.map(
			(item) => `<figure class="pb-item"><div class="pb-frame">${screen(item.kind, p.version)}${pageMark(item)}</div>
			<figcaption>${item.label ? `<span class="pb-label">${item.label}</span>` : ""}<span><strong>${one ? "" : item.name}</strong>${one ? "" : "<br>"}${item.caption}</span></figcaption></figure>`,
		)
		.join("");
	const strip = `<div class="pb-strip ${one ? "one" : layout === "narrow" ? "stack" : "film"}">${items}</div>`;
	const question = p.question ? `<div class="pb-ask">${ask(p.question, layout)}</div>` : "";
	const newer = p.newer ? `<p class="present-newer">A newer version is below.</p>` : "";
	return `<section class="present pb">${head}${strip}${question}${newer}</section>`;
}

// ---- Take C: Stage

function takeC(p, layout) {
	const head = `<div class="card-head"><span class="card-title">${p.title}</span><span class="card-note">${note(p)}</span></div>`;
	const shown = p.items.length === 1 ? p.items[0] : p.items[p.question ? 1 : 0];
	const stage = `<div class="pc-stage">${screen(shown.kind, p.version)}${shown.label ? `<span class="pc-label">${shown.label}</span>` : ""}${pageMark(shown)}<button class="pc-expand">${glyph("expand", "open-glyph")}</button></div>`;
	const caption = `<p class="pc-caption">${shown.label ? `<strong>${shown.label} · ${shown.name}</strong> ` : ""}${shown.caption}</p>`;
	let lower = "";
	if (p.items.length > 1) {
		const strip = `<div class="pc-strip">${p.items
			.map((item) => `<button class="pc-thumb${item === shown ? " on" : ""}"><div class="pc-mini">${screen(item.kind, p.version)}</div><span>${item.label} · ${item.name}</span></button>`)
			.join("")}</div>`;
		lower = `<div class="pc-lower ${layout}">${strip}${p.question ? ask(p.question, layout) : ""}</div>`;
	}
	const newer = p.newer ? `<p class="present-newer">A newer version is below.</p>` : "";
	return `<section class="card present pc">${head}${stage}${caption}${lower}${newer}</section>`;
}

const TAKES = { A: takeA, B: takeB, C: takeC };

function conversation(take, layout) {
	const card = (p) => TAKES[take](p, layout);
	return [
		user("Show me three ideas for the sign-in screen. And the settings page as it is now, for comparison."),
		assistant(
			tools(toolRow("terminal", "Ran <code>scripts/test-copy shot test-946 app/build/shots/946/settings.png</code>")),
			card({ id: "p1", version: 1, title: "Settings › General, as it is now", items: SETTINGS }),
			presentRow('Presented 1 picture <span class="muted">· 1440×900, 212 KB</span>'),
		),
		assistant(
			prose("Three ideas for the sign-in screen. A keeps today's form, B puts the product's promise beside it, C is the plainest."),
			tools(toolRow("pencil", "Wrote <span class=\"name\">signin-a.html</span>, <span class=\"name\">signin-b/index.html</span> and 1 more")),
			card({ id: "p2", version: 1, title: "Sign-in screen, three layouts", items: SIGNIN, newer: true }),
			presentRow('Presented 2 pictures and a page <span class="muted">· the page loaded, no errors</span>'),
		),
		user("Make the buttons bigger in all three, then I'll pick."),
		assistant(
			tools(toolRow("pencil", "Edited 3 files <span class=\"stats\"><span class=\"add\">+9</span> <span class=\"remove\">−9</span></span>")),
			card({ id: "p2", version: 2, title: "Sign-in screen, three layouts", items: SIGNIN, question: QUESTION }),
			presentRow('Presented version 2 of p2 <span class="muted">· waits for your answer</span>'),
		),
	].join("");
}

// ---- The window

function windowMock(what) {
	const page = what === "page";
	const shown = page ? SIGNIN[1] : SIGNIN[0];
	const tools = page
		? `<div class="seg">${["Phone", "Tablet", "Desktop", "Fit"].map((w) => `<button class="${w === "Desktop" ? "on" : ""}">${w}</button>`).join("")}</div>
			<button class="tb-btn" title="Reload">${glyph("reload", "tb-glyph")}</button>
			<span class="net off">${glyph("globe", "tb-glyph")}Network off</span>`
		: `<div class="seg"><button class="on">Fit</button><button>100%</button></div>
			<button class="tb-btn">${glyph("minus", "tb-glyph")}</button><button class="tb-btn">${glyph("plus", "tb-glyph")}</button>
			<div class="seg icons"><button class="on" title="Light">${glyph("sun", "tb-glyph")}</button><button title="Dark">${glyph("moon", "tb-glyph")}</button><button title="Chequered">${glyph("checker", "tb-glyph")}</button></div>`;
	const stage = page
		? `<div class="w-stage page"><div class="w-viewport"><div class="w-pagebody">${screen(shown.kind, 2)}<div class="w-below"><h5>Why teams switch</h5><p></p><p></p><p class="short"></p></div></div><div class="w-scroll"><i></i></div></div>
			<p class="w-blocked">Blocked a link to <code>example.com</code>: a mockup does not leave its folder.</p></div>`
		: `<div class="w-stage pictures light-bg"><div class="w-picture">${screen(shown.kind, 2)}</div></div>`;
	const strip = `<div class="w-strip">${SIGNIN.map(
		(item) => `<button class="w-thumb${item === shown ? " on" : ""}"><div class="w-mini">${screen(item.kind, 2)}${item.page ? `<span class="page-mark small">${glyph("page", "mark-glyph")}Page</span>` : ""}</div>
			<span class="w-cap"><strong>${item.label} · ${item.name}</strong><br>${item.caption}</span></button>`,
	).join("")}<span class="w-strip-note">← → between items · ⌥⌘S hides the strip</span></div>`;
	return `<div class="w-window">
		<div class="w-titlebar"><span class="lights"><i></i><i></i><i></i></span><span class="w-title">Sign-in screen, three layouts — Mockup by Forge</span></div>
		<div class="w-bar">
			<span class="avatar">F</span><span class="w-who"><strong>Mockup by Forge</strong> · pi2 · ${page ? "drawn from Forge's files" : "a picture Forge made"}</span>
			<div class="w-version"><button class="tb-btn">${glyph("back", "tb-glyph")}</button><span>Version 2 of 2</span><button class="tb-btn" disabled>${glyph("forward", "tb-glyph")}</button></div>
			<div class="w-tools">${tools}<button class="tb-btn" title="Hide the strip">${glyph("strip", "tb-glyph")}</button></div>
		</div>
		${stage}${strip}</div>`;
}

function draw() {
	const params = new URLSearchParams(location.hash.slice(1));
	const root = document.getElementById("root");
	const html = document.documentElement;
	if (params.has("window")) {
		html.classList.add("window-mock");
		root.innerHTML = windowMock(params.get("window"));
		return;
	}
	const take = params.get("take");
	if (!TAKES[take]) return;
	if (params.get("layout") === "narrow") html.classList.add("narrow", "touch");
	html.classList.add("take-" + take);
	root.innerHTML = conversation(take, params.get("layout"));
}

addEventListener("hashchange", () => location.reload());
draw();
