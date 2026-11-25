
# Presenting: the design

*The design for [#946](https://github.com/KellamA/pi2/issues/946), made before any of it is built. Once it is built, the guide and `docs/presenting.md` say how it is; this page stays as the design it came from. The pictured mockups of the card and the window are made from [presenting/mockups.html](presenting/mockups.html): open it in a browser, or see "The mockups" below.*

An agent that makes something visual today can only write a file and name its path, or read a picture so that it sits folded in a tool row's detail. This design gives it a built-in tool, `present`, that puts pictures and mockup pages in a card of their own in the conversation, open, large and labelled; Expand opens them in a window of their own that follows newer versions; and the card can ask the person to pick one.

## Words

- **Presentation**: what one call of the tool shows: a title and one to six **items**. It has an id in its conversation, `p1`, `p2`, …
- **Item**: a picture file, or a **page** (an HTML file with what lies in its folder and below).
- **Version**: the same presentation shown again (`update: "p2"`). Version 1 is the first call.
- **Variant**: one of several items shown to choose between. Each has a **label** (A, B, C, or the agent's own) and a **caption**.
- **Snapshot**: a picture of a page as pi² drew it when it was presented, for the card, the phone and an agent's own look.

## What the person sees

### The card

A `present` call is drawn as a card at its place in the conversation, not as a one-line tool row: open, never folded behind a chevron.

- **One item**: the title, the picture as wide as the column allows (at most its own size, never taller than about two thirds of the pane), the caption under it.
- **Several items**: side by side, each with its label and caption, so the person can answer "B, but with the warning colour of A". Six at most. In a narrow pane, and on the phone, they page sideways, one at a time, with the labels as tabs. How exactly is the owner's choice of look (A, B or C below).
- **A page** is shown as its snapshot, with a small "Page" mark and its drawn size, and opens live in the window. (Why not live in the card: [Safety](#a-page-an-agent-wrote-is-untrusted).)
- **Expand** (a button on the card, and a click on any picture) opens the window at that item. On the phone it opens the page's own picture viewer, full screen, swiping between the items.
- **A newer version** of the same presentation (the agent called `present` with `update`) is a new card further down, saying "Version 3 of p2"; the older cards stay as they were, each with "A newer version is below".
- **What the agent is told** is not on the card. The tool's answer (sizes, a page's console errors) is in the call's row, folded under the card, for whoever wants it.
- **Copying** the card gives its title, and each item as `[Picture A: login-a.png — Compact form]`; a turn's Copy and Export do the same.

### Picking

With a `question`, the card ends with it and a button for each choice ("Use A", "Use B", "Use C" unless the agent names its own), and a field for an answer in words, as a question card does today. Return sends the words, as in the question card (`keys.js`).

- The question is listed **under Needs you** as a decision, with the presentation's pictures small on its card (in the hub, on the Dashboard and behind the menu bar item), so it can be answered from there too, and Expand works there as well.
- Answered, the buttons go and the card says "You chose B" or quotes the words. Withdrawn or ended, the card says it no longer waits, as cards do today.
- The phone shows the same buttons, and answers the decision as it answers one today.

### The window

Expand opens the presentation in **a window of its own**, one per presentation: Expand on another card of the same presentation brings that window forward at that version.

- **The frame says whose it is.** Its title is the presentation's title, and a bar along its top, drawn by pi² (not by the page), names the agent and the conversation ("Mockup by Forge · Sign-in screen · pi2"), the version ("Version 3 of 3", with ‹ › to step back to older ones), and for a page "Drawn from Forge's files · network off". The bar stays in full screen.
- **Moving between items**: a strip of the items along the bottom, with their labels, and ← → keys. The strip folds away (and comes back with a key) for a bigger stage.
- **Pictures**: fit to the window, or actual size (⌘0 and ⌘1), zoom with a pinch or ⌘+ ⌘−, scrolled when larger than the window; the background behind a picture light, dark or chequered (for transparency).
- **Pages**: live, at the window's size, or at a width chosen from Phone (390), Tablet (820), Desktop (1280) and Fit, scrolled, hovered and clicked as in a browser. Reload draws it again from the copy. "Allow network for this page" turns the network on for this presentation, after a line that says what that means; it is remembered for its later versions, never for others.
- **Full screen** from the green button or ⌃⌘F; the bar and the strip stay.
- **It follows the conversation.** While it is open, a new version of the same presentation shows in it at once, at the item that was shown; the person can step back to older versions. It stays open while the conversation goes on and after the agent finishes, and closes with the conversation's archiving or deletion.
- **No window on the phone** for now: the picture viewer is its Expand. A page is shown there by its snapshot, with "Open it on your Mac to use it".

### Elsewhere

- **A sub-chat's presentation** is in its own conversation, as any entry is, so it shows wherever that is opened: in place of the board, in a pane Beside, in the Archive. A question with it is under Needs you in the orchestrator's hub with its pictures. The orchestrator's hand-off row does not repeat it.
- **A project's shelf** of everything presented is for later ([Roadmap](#roadmap)).

## What the agent gets

### The tool

A built-in tool, `present`, listed in an agent's settings under **Built-in tools** as "Present pictures and mockups" ("Shows you pictures and mockup pages it made in a card of their own, with a window to see them large, and can ask you to pick one. Without it, an agent can only name the files."). On by default, offered where tool access is not off (`needs: "files"`), since it reads files as `read` does. Not in chat mode's `CHAT_TOOLS` for now: a chat makes no files to present but its documents.

The name is the owner's to choose; see [What the owner decides](#what-the-owner-decides).

Its declaration, word for word:

```ts
defineTool({
	name: "present",
	description:
		"Show the person pictures or mockups in a card of their own in the conversation, large, with a label and a caption under each. They can open it in a window, full screen, and step between the items. " +
		"Use it whenever the person asks to see something, and for anything visual you made (a screenshot, a design, a mockup page), instead of naming its path. " +
		"Each item is a picture file (PNG, JPEG, GIF, WebP or SVG) or a page: an HTML file, shown with what lies in its folder and below, drawn with its scripts on and the network off, so put everything it needs in that folder and keep the folder to the mockup. " +
		"Give several items to offer variants side by side, labelled A, B, C or with short labels of your own, each with a caption saying how it differs. " +
		"With `question`, the card asks the person to pick, and the call waits for the answer; with `wait: false`, in a project, it returns at once and the answer comes to you later as a message. " +
		"To show a new version of something you presented before, pass its id as `update`: the person's window then shows the new version and keeps the older ones. " +
		"The files are copied as they are now; a later change to them is not shown until you present again. " +
		"The answer says what was shown: each item's size and, for a page, whether it loaded, its console errors, the addresses it tried to reach, and a picture of it as drawn that you can read or look at.",
	parameters: obj({
		title: str({ description: "What is shown, in a few words, such as \"Sign-in screen, three layouts\"" }),
		items: arr(
			obj({
				path: str({ description: "A picture file or an HTML file, relative to the conversation's folder or absolute" }),
				label: opt(str({ description: "A short label, 12 characters at most, such as \"Compact\"; A, B, C… in order when left out" })),
				caption: opt(str({ description: "A line or two shown under it: what this one is, or how it differs" })),
			}),
			{ description: "What to show, in this order: 1 to 6 items" },
		),
		question: opt(str({ description: "A question for the person to answer by picking, such as \"Which layout should I build?\"" })),
		choices: opt(arr(str(), { description: "With question: the answers offered as buttons, 2 to 6, 60 characters each; by default \"Use A\", \"Use B\"… one per item. The person can always answer in words instead" })),
		wait: opt(bool({ description: "With question, in a project: false returns at once, and the answer comes later as a message. Default true" })),
		update: opt(str({ description: "The id of something presented before in this conversation, such as \"p2\", to show this as its new version" })),
	}),
	replay: "safe", // run again after a crash, it finds its own record by its call and copies nothing twice
});
```

- **Refused before anything is copied**, each with what to do instead: no items or more than six; a label over 12 characters or two the same; a path `read` could not read (the same reach and the same checks); a file that is neither a picture of a kind it takes nor HTML (`.html`, `.htm`); one over the [limits](#where-presented-files-are-copied-and-their-limits); `choices` without `question`, or not 2 to 6 of at most 60 characters; `wait: false` outside a project ("In a conversation outside a project, a question waits for its answer; leave out wait"); `update` naming no presentation of this conversation.
- **A text-only model** uses it as any other: it writes the page, presents it, and learns from the answer whether it drew (an empty page, a script error, a stylesheet it could not reach), and can `look` at the snapshot when the person has chosen a model that looks at pictures ([pictures.md](../pictures.md#a-model-that-looks-at-pictures)).
- **Its prompt section**: none. The description says when to use it; agents of this repository are told to present what `scripts/test-copy shot` and `scripts/iphone-sim shot` make ([below](#from-a-test-copy-or-a-simulator)).

### Its answer

Text only: the presented pictures are not put in the model's request (they would be paid for on every later turn, and a text-only model cannot take them). For example:

```
Presented "Sign-in screen, three layouts" as p2, version 3. The person sees a card in the conversation and can open it in a window.
A  mockups/signin-a.png: PNG, 1440×900, 212 KB
B  mockups/signin-b/index.html: page, 7 files, 1.2 MB; loaded in 0.4 s; drawn 1280×2140 (taller than the window: it scrolls); 1 console error: "TypeError: null is not an object (evaluating 'form.addEventListener') at app.js:12"; blocked, since the network is off: https://cdn.tailwindcss.com/3.4.1 (put it in the folder instead)
C  mockups/signin-c.svg: SVG, 1440×900, 18 KB
Pictures of the pages as drawn: $PI2_SCRATCH/presented/p2-v3-B.png. Read it, or look at it, to check it.
To show a new version of this, call present again with update: "p2".
```

- A page that drew nothing visible says so: "**it looks blank**: nothing but its background was drawn, and its body has no text".
- A page not drawn because no pi² window is open on the Mac (the engine running for a phone alone): "not drawn yet: pi² is not open on this Mac. The person sees it once it is; nothing was checked." The page is drawn when the app next connects; nothing further reaches the agent.
- With a question and `wait` (the default): the answer follows it, "The person chose B." or "The person answered: B, but with the warning colour of A". A message from the person instead ends the wait as `ask_user`'s does (`heed.ts`), and the question is taken away.
- With `wait: false`: "The question is under Needs you; the answer comes to you as a message."

### How it sits with the other picture tools

- **`read` of a picture** stays the way an agent sees a picture for itself: it is put in the model's request and its row folds. `present` is for showing the person, and puts nothing in the request.
- **`look`** (#540) answers a text-only model's question about a picture; `present`'s answer names the snapshots of its pages so that `look` can check them.
- **`make_picture`** keeps its row. Showing its pictures as a presentation (they are in the conversation, not in files) is for later.
- **The computer tool's and the browser's screenshots** are not files. Presenting "the newest screenshot" (`items: [{ screenshot: "latest" }]`) is for later; for now an agent saves what it wants shown.

### From a test copy or a simulator

Not a step of its own. `scripts/test-copy shot` and `scripts/iphone-sim shot` already write a file, and presenting it is the next call: `present` with that path. A source that takes the picture itself (`from: "test-copy"`) would put this repository's scripts, and a capture under pi²'s own Screen Recording permission, inside a tool every agent of every project has. Instead, `docs/agents.md` gains one line: present the pictures you take of a copy or a simulator, labelled, rather than naming their paths (part of the guide piece below).

## The contract

What each side does, exact enough for the engine, the transcript page and the app to be built at the same time. Names are final unless the owner renames the tool, which renames only `present` and the `present.*` requests.

### Where presented files are copied, and their limits

The engine copies every item when the tool runs, before it answers, into the data folder:

```
presented/<conversation>/blobs/<sha256>          each file's bytes, once, by content (a file shared by versions is kept once)
presented/<conversation>/pages/<sha256>.json     a page's manifest: { "entry": "index.html", "files": { "<path>": { "sha256", "bytes", "type" } } }
```

`<conversation>` is the conversation's id, or for a chat's versions the chat's (`chatIdOf`). A page's folder is the HTML file's own folder and everything below it, without hidden files or folders (`.git`), `node_modules`, and symbolic links that lead out of the folder; paths in the manifest are relative, `/`-separated and normalised (no `..`).

| Limit | |
|---|---|
| Items in one call | 6 |
| A picture | 20 MB; at most 16,384 pixels a side; PNG, JPEG, GIF, WebP by their first bytes (as `attachments.ts` checks), SVG of 2 MB at most |
| A page | its folder: 500 files, 50 MB |
| One call | 100 MB in all |
| One conversation | 500 MB of distinct files; a call past it is refused, saying how much the conversation holds |

- **Kept** as long as the conversation: through archiving, in a [backup](../architecture.md#where-things-live) (`backup.ts` copies `presented/` with the database, and a restore brings it back), and removed when the conversation is deleted. A fork clones its conversation's folder (APFS clones: no space until either changes), so each conversation's cards stand alone.
- **Counted** in Settings › Storage, under the data folder's line: "Presented pictures and pages: 312 MB, in 14 conversations", from `engine.info`'s new `presented: { bytes, conversations }`.
- **A snapshot** of each page is a blob too, a PNG at 2× of the card's drawing size, 1280×800 points. It is also written to `presented/` in the conversation's scratch folder (`$PI2_SCRATCH/presented/p2-v3-B.png`), for the agent to read or look at; that copy may go with the scratch folder, the blob stays.

### What is stored

A document of the conversation, `pi2.presented` (scope: conversation), the index the window and waiting cards read:

```ts
type PresentedDoc = { next: number; items: Record<string, PresentationRecord> }; // keyed "p1", "p2", …

type PresentationRecord = {
	id: string;              // "p2"
	versions: PresentedVersion[];
	/** The person's "Allow network for this page", for this presentation's pages, every version. */
	network: boolean;
};

type PresentedVersion = {
	version: number;         // 1, 2, …
	callId: string;          // the call that presented it; a call run again finds its version by this
	createdAt: number;
	title: string;
	items: PresentedItem[];
	question: PresentedQuestion | null;
};

type PresentedItem = {
	label: string;           // "A", or the agent's
	caption: string | null;
	kind: "picture" | "page";
	name: string;            // the path as the agent gave it, for the card's tooltip and Copy
	mimeType: string;        // "image/png" …, "image/svg+xml"; "text/html" for a page
	sha256: string;          // a picture's blob, or a page's manifest
	bytes: number;           // a picture's, or a page's folder's
	files: number;           // 1 for a picture
	width: number | null;    // a picture's pixels; a page's drawn width in CSS pixels (1280)
	height: number | null;   // a picture's pixels; a page's drawn height, the whole of it
	/** A page's picture as drawn: "drawn" with its blob, "pending" while no app has drawn it, "failed" with why. */
	snapshot: { state: "drawn"; sha256: string } | { state: "pending" } | { state: "failed"; reason: string } | null; // null for a picture
	/** What drawing it found, as the agent was told: for a page only. */
	drawn: { loadMs: number; blank: boolean; console: string[]; blocked: string[] } | null;
};

type PresentedQuestion = {
	text: string;
	choices: { id: string; label: string }[];   // ids "1", "2", … as needs.ts makes them
	words: true;                                 // an answer in words is always taken
	need: string;                                // the Inbox item's id (it waits) or the stored need's ("n…", wait: false)
	/** Set once it has ended: the choice's label or the words, or why it ended. */
	answer: { chose: string } | { words: string } | { ended: "withdrawn" | "messaged" | "stopped" } | null;
};
```

The tool's result (`details`) holds `{ presentation: "p2", version: 3 }` and the whole `PresentedVersion` as it was when it was presented, so an Export, a fork, or a page with no access to the document still draws the card; the document is the newer truth (a snapshot drawn later, an answer).

### The question

- **It waits** (the default): an Inbox item, as `ask_user`'s, with `kind: "question"`, `tool: "present"`, and two new optional fields, `choices` and `presentation: { conversationId, presentation, version }`. On the wire (`needs` event, 3.9 of [projects.md](../projects.md)) it is a **`decision`** with `blocking: true`, `words: true` and the same `presentation`, so every Needs you card and the phone already draw it and answer it with `{ kind: "decision", choice }` or `{ kind: "decision", text }` through `claim`. The waiting call is given the chosen choice's label or the words.
- **`wait: false`** (a project only): a stored need of kind `decision` with `presentation` added, put as `needs_you` puts one; the answer comes back as a wake of kind `answer` (`wakes.ts`).
- Either way the engine sets `question.answer` in `pi2.presented` when it ends, in the commit that ends it.

### Drawing a page: the engine asks the app

The engine never loads a page. As the browser does, it asks the app that registered to draw:

| Direction | Message | |
|---|---|---|
| app → engine | `present.register {}` | This connection draws pages. The latest app to ask draws. Answer `{}` |
| engine → app | event `present.draw { requestId, conversationId, presentation, version, item, width: 1280, height: 800 }` | Draw this page as [below](#how-a-page-is-drawn), offscreen |
| app → engine | `present.drawn { requestId, ok, loadMs, blank, height, console, blocked, snapshot?: { mimeType: "image/png", data }, reason? }` | What it found. `console` at most 50 lines of 500 characters; `blocked` at most 20 addresses. Answer `{ answered }` |

The tool waits for the answer at most 20 seconds a page (pages of one call are drawn at the same time), then answers with what it has: a page not answered by then is `pending`, drawn when it is answered, as is every page `pending` when an app registers. `present.drawn` stores the snapshot as a blob and the findings in the item, and sends `conversation.presented`.

### Events and requests for the app and the phone

| Request | Who may send it (`answers.ts`) | |
|---|---|---|
| `presented.list { id }` | anyone; not a device, for now (the phone's card reads `presented.picture` alone) | `{ items: PresentationRecord[] }` for the window: every version |
| `presented.picture { id, presentation, version, item }` | anyone; a device: reading | `{ mimeType, data }`: a picture, or a page's snapshot. Refused for a page whose snapshot is not drawn |
| `presented.file { id, presentation, version, item, path }` | anyone; not a device, for now | `{ mimeType, data }`: one file of a page, by its manifest path; refused for a path the manifest does not have |
| `presented.network { id, presentation, allow }` | the app only (a setting of the person's) | Stores `network`; sends `conversation.presented` |
| `present.register`, `present.drawn` | the app only (the app's host role, as `browser.register`) | Above |

`id` is the conversation as the app shows it (the chat's id for a chat). Every one of these must be named in `answers.ts`'s lists, which is a path waiting for the owner's review ([Roadmap](#roadmap)).

The event **`conversation.presented { id, record: PresentationRecord }`** goes to every connection subscribed to that conversation (as `conversation` events do) whenever a version is added, a snapshot drawn, the network switch changed, or a question ended.

### The transcript page

New in the [messages from the app](../transcript.md#messages-between-the-app-and-the-page):

| Field | What |
|---|---|
| `presented` | `{ records: PresentationRecord[] }`, those changed since last sent, keyed by `id`. The page draws a `present` call's card from the record's version whose `callId` is the call's, or from the result's `details` while it has no record |
| `image` | as today, and also `{ presented: { presentation, version, item }, mimeType, data }` answering the message below |

New messages from the page, each checked by `TranscriptAction` and `TranscriptBridge` as the others are:

| Message | Checked | Then |
|---|---|---|
| `{type: "presentedImage", presentation, version, item}` | `p` and a number; whole numbers; a version and an item this conversation's records have | `presented.picture`, then an `image` message back |
| `{type: "expand", presentation, version, item}` | as above | Open, or bring forward, the presentation's window at that version and item |
| `{type: "choose", need, choice}` | a need waiting in this conversation that is a `present` question; `choice` one of its ids | `needs.answer { id: need, answer: { kind: "decision", choice } }` |
| `{type: "answer", need, text}` | as today's `answer`, for a `present` question by its need's id | `needs.answer { … { kind: "decision", text } }` |

- The page draws a `present` call as a card in place of its row (as it draws a hand-off), with the call's own row, its answer, folded under the card. While the call runs and has no record, the row reads "Presenting Sign-in screen…".
- A picture's bytes reach the page only as `blob:` pictures, as today, so its Content-Security-Policy is unchanged; an SVG is drawn by an `<img>` and so runs no script and loads nothing.
- On a phone (`html.narrow.touch`) the items page sideways one at a time, and Expand opens the existing lightbox with left and right swipes between the items.

### The window, in the app

- **`PresentationWindow`**: a SwiftUI `WindowGroup(for: PresentationRef.self)`, `PresentationRef = { conversationId, presentation }`, so opening one that is open brings it forward. It reads `presented.list` once and follows `conversation.presented`, subscribing to the conversation as a pane does (and closing with it, which keeps the conversation's subscription while the window is open).
- Pictures are fetched with `presented.picture` and drawn natively (`NSImageView` in a scroll view with magnification). Pages are drawn in a `PresentedPageView` as [below](#how-a-page-is-drawn), its files fetched with `presented.file`, a page's files cached in memory for its window's life.
- The bar, the strip and the menus are the app's own SwiftUI views around the page's view, never part of the page.

### The phone

The phone's page shows the card from the same messages; its bridge gains `presentedImage` (an engine read, `presented.picture`, checked as `conversation.image` is) and nothing else. `expand` opens the page's lightbox instead of a window. A question is answered as any decision. A page is its snapshot. `presented.file` and a live page on the phone are for later.

## A page an agent wrote is untrusted

An agent's page is content written by a model that may have read anything: a web page, an issue, another agent's report. It is drawn as a hostile page would have to be.

### How a page is drawn

The same view (`PresentedPageView`, in `TranscriptKit` beside the transcript's so that the phone can have it later) draws it offscreen for its snapshot and live in the window:

- **Its own `WKWebView`, its own web content process.** Never inside the transcript page (whose process holds the bridge to the engine) and never in an `iframe` of it: the transcript's Content-Security-Policy allows no frames and keeps it so. A data store of its own for each presentation, `WKWebsiteDataStore.nonPersistent()`: nothing on disk, nothing shared with another presentation, the browser or the transcript.
- **Loaded from a scheme of its own**, `pi2-presented://<origin>/<path>`, served by a `WKURLSchemeHandler` from the copy alone: the manifest's files, by their normalised path, fetched with `presented.file`; any other path is a 404. `<origin>` is a random name made for each presentation's version as it is loaded, so two versions or two presentations are different origins and share no storage. No `file:` address is ever loaded, and no read access to a folder is given, so nothing outside the copy can be reached, not even the original folder.
- **No bridge.** No `WKScriptMessageHandler` is added to the live view, so `window.webkit.messageHandlers` is empty. The offscreen view used for drawing adds one, `pi2log`, taking only strings for the console lines it reports (capped as above) from its own main frame; it can do nothing but add to the agent's answer, which is untrusted text already.
- **Network off**: a `WKContentRuleList` blocks every load whose address is not `pi2-presented://<origin>/` (http, https, ws, wss, other schemes; `file:` above all), and the scheme handler's responses carry `Content-Security-Policy: default-src pi2-presented: data: blob: 'unsafe-inline' 'unsafe-eval'; connect-src pi2-presented:; form-action 'none'; base-uri 'none'`. A user script at document start in every frame takes away `RTCPeerConnection` and its kin, which neither of those covers. WebKit also connects ahead to an http(s) link's server when the link is clicked, by the person or a script, before the navigation delegate is asked and without the rule list (#964 measured it): the data store's proxy (`proxyConfigurations`) is an HTTP CONNECT proxy on 127.0.0.1 at a port bound and never listened on, so whatever WebKit connects to by itself is refused there and no name is looked up, and, since no proxy is used for this Mac's own addresses, the same user script follows such a link by a script's navigation instead, which connects to nothing ahead and which the navigation delegate refuses. Blocked addresses are counted for the agent's answer. **Allow network for this page** swaps the rule list for one that blocks only this Mac and the local network (the browser's rules for private addresses, BrowserKit's `BrowserPolicy`) and the policy's `connect-src` for `*`; it is the person's alone, in the window, never on the card or from the engine.
- **No navigation away.** The navigation delegate allows the first load and links within the same `<origin>` (a mockup of several pages), and cancels everything else, saying in the window's bar "Blocked a link to example.com". No new windows (`javaScriptCanOpenWindowsAutomatically` false and `createWebViewWith` returns nil), no downloads, no element full screen (`isElementFullscreenEnabled` false), no back and forward gestures, no link previews.
- **Nothing that asks the person.** The `WKUIDelegate` answers alerts, confirmations and prompts at once without showing a panel (a panel would look like pi²'s own), refuses file pickers, and denies camera, microphone and screen capture (`requestMediaCapturePermission` → `.deny`) and any other permission without asking. That denial alone is too late: WebKit asks macOS for the camera or the microphone before it asks the delegate, and the page's scheme is a secure context, where `navigator.mediaDevices` is. So the user script also takes away, in every frame, what would ask for a permission or put up the system's own sheets (media devices, location, clipboard, passkeys, sharing, payments, notifications, speech recognition), and a page can never put a macOS permission prompt up. Clipboard reading is off (`javaScriptCanAccessClipboard` false).
- **Its menu**: WebKit's for text (Copy, Look Up), without Reload, Open Link, Download or Inspect Element (Inspect is kept in a development build, as the transcript's is).
- **Its process ending** draws it again, once; a second time says so in the window.
- **Scripts run.** A mockup is often a page that does something: tabs that switch, a menu that opens on hover, a form that shows its error. The issue asks for one that "can be scrolled, hovered and resized", and a text-only model will reach for a script. What makes a script safe here is everything above: its own process, no bridge, no files, no network, no navigation and no panels; turning scripts off would take the mockups' use and leave little risk behind. The snapshot is taken after the page has loaded and been quiet for half a second (at most 10 seconds), so a script that draws the page is in it.
- **Not live in the card.** The card shows the snapshot. A live page in the card would need either an `iframe` in the transcript page, which puts untrusted content in the process that holds the bridge, or a native view kept over the page's scrolling, which is fragile and has no form on the phone. A click on the snapshot opens it live in the window.

### What stops it looking like pi²

- The page only ever fills the area inside the window's frame. The bar above it (the agent's name, "Drawn from Forge's files", the version, the network's state) and the strip below are pi²'s own SwiftUI, outside the web view, and stay in full screen (`.windowToolbarFullScreenVisibility(.visible)`); the page cannot go full screen by itself.
- The window's title is the presentation's title with "— Mockup by Forge" after it, as Mission Control and the Window menu list it.
- A page draws no panels (alerts and the like are answered without showing), opens no windows, and has no way to ask the engine or the app anything, so a page that draws a fake approval card has nothing behind its buttons: it can only change what is drawn inside its own frame.
- In the card, a page is a picture with a "Page" mark, inside the card's frame, under the card's own title.

### For the security read when it is built

The claims to check: that the live view has no message handler; that a page cannot load a `file:` address, its original folder, another presentation's origin, or any network address with the network off (fetch, XHR, `<img>`, CSS `url()`, `@import`, fonts, WebSocket, `EventSource`, `navigator.sendBeacon`, a form, a meta refresh, a link, `window.open`, WebRTC); that DNS prefetching (`<link rel="dns-prefetch">`) sends no query (WebKit's own setting, or the rule list; to be measured); that the scheme handler cannot be made to serve a path outside the manifest (`..`, encoded `%2e%2e`, a symbolic link in the copy, a very long path); that the manifest is made without following a link out of the folder and without reading a file twice (a file changed between the size check and the copy); and that nothing a page does puts up a panel or a permission prompt.

## What the owner decides

1. **The card's look**: takes A, B and C, pictured. Recommended: **A**.
   - **A, Gallery**: a card with a frame, as Needs you's cards; the items side by side in equal columns, each labelled in a corner and captioned under it; the question and its buttons at the foot. Narrow: one item at a time, with the labels as tabs.
   - **B, Filmstrip**: no frame; a heading with the agent's colour, then the pictures large in a row that bleeds to the column's edges and scrolls sideways when they do not fit, big labels under each. Narrow: the items one under another, full width.
   - **C, Stage**: one item large on a stage, with a strip of the items under it to switch (the window in small); the question beside the strip. Narrow: the same, the strip under the stage.
2. **The tool's name**: `present` (recommended: says what it does for the person, and is not mistaken for showing a file in Finder) or `show`.
3. Everything else above is decided, with its reason; the owner may of course overrule any of it.

## The mockups

[presenting/mockups.html](presenting/mockups.html) draws every state with the transcript page's own stylesheet (`app/Web/transcript/transcript.css`) and its classes: open it in a browser, with `#take=A&layout=wide` (or `B`, `C`; `narrow`; `#window`) to see one. The pictures were made from it by a throwaway program that draws it in an offscreen `WKWebView` and takes its snapshot, as `pi2-transcript-check --pictures` pictures the transcript page, in the dark and the light appearance. They are not committed: they are in `app/build/shots/946/` of the worktree that made them, and the page draws them again.

| Picture | What |
|---|---|
| `take-A-wide-dark.png`, `-light` (and `B`, `C`) | In a pane 880 points wide: a card with one picture, a card of three variants, and its second version with a question |
| `take-A-narrow-dark.png`, `-light` (and `B`, `C`) | The same at a phone's 390 points, as the phone marks the page |
| `window-pictures-dark.png`, `-light` | The window on a picture, with its bar, the version, zoom, the background, the strip |
| `window-page-dark.png`, `-light` | The window on a page: the widths, Reload, the network's state, a link it blocked |

## Roadmap

After the owner chooses the look, the pieces, with what each may build on:

1. **The requests named in `answers.ts`** (owner's review): `present.register`, `present.drawn`, `presented.list`, `presented.picture`, `presented.file`, `presented.network`, in their lists and the device lists, with the devices' test. Small, so the owner's review comes first and does not hold the rest.
2. **The engine** (after 1): the tool, the copying and its limits, `pi2.presented`, the Inbox's `choices` and `presentation`, the decision on the wire, asking the app to draw, the requests and the event, backup and fork and delete, `engine.info`'s `presented`, the built-in tool's entry; tests in `engine/test`. Against a stand-in app that draws, so it needs no app.
3. **The transcript page** (alongside 2, against this contract's messages): the card in the chosen look, wide and narrow, picking, `presentedImage` and `expand`; `app/Web/test`.
4. **`PresentedPageView`** (alongside 2 and 3): the sandboxed web view, its scheme, rules and delegates, drawing offscreen for a snapshot; a check program beside `pi2-transcript-check` that loads hostile pages and holds every claim of the security read.
5. **The app** (after 2 and 4, with 3): the bridge's new messages, `present.register` and drawing, the window, the Needs you card's pictures, Settings › Storage's line.
6. **The phone** (after 3): the bridge's `presentedImage`, the lightbox's swiping; the device rows came with 1.
7. **The guide and the docs**: `docs/presenting.md`, the guide's section, transcript.md and architecture.md, and the line in `docs/agents.md` about presenting a copy's pictures; with 5.
8. **The security read** of 4 and 5 together, before release.

Then, later and each on its own: a live page on the phone; an address on this Mac (a preview server's) as an item, live in the window and snapshotted for the card; the newest screenshot or `make_picture`'s pictures as an item; a project's shelf of what was presented, in the hub; presenting in chat mode.

2, 3 and 4 can be built at the same time; 5 joins them; 6 and 7 follow. Only 1 (and any later change to a device's rows) waits for the owner's review.
