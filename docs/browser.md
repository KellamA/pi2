# Browser

An agent with the browser on can open web pages, read them, follow links and fill in forms, in a browser that belongs to pi². You can watch it work, and use the same pages yourself: to sign in, to get past a CAPTCHA, or to take over.

The browser has its own profile. Its cookies and sign-ins are kept apart from Safari's, Chrome's and every other browser's, so an agent is signed in only where you signed in, in pi²'s browser.

## Turning it on

1. Open an agent and scroll to **Browser**. Switch it on.
2. Ask the agent to look something up, or to open a page. Conversations it already has pick up the change at their next message.
3. To see what it is doing, choose **Window › Browser** (⇧⌘B), press the globe at the bottom of the sidebar, or press **Browser** in the conversation's toolbar.

If a site needs you to be signed in, sign in before you ask: open the Browser window, press **+** for a page of your own, go to the site and sign in. The agent's pages share that sign-in.

## How it works

The engine decides what is allowed and asks for approval. The app loads the pages and works them, because the web views live in the app. So pi² has to be open.

- **One page per conversation.** Each conversation that browses gets its own page, made the first time it is needed. The strip at the top of the Browser window switches between them. They all share the one profile.
- **Pages are read as text.** The agent is given the page's title and address, a numbered list of what it can act on (links, buttons, fields with their labels and what they hold, checkboxes, lists with their choices, file inputs), and the page's text, where `[n]` marks where each of those sits. It acts on a thing by its number. A model that cannot see images needs nothing more.
- **Long pages come in parts** of about 8,000 characters. The list shows what is in the part being read; the agent asks for the next part when it wants it.
- **Every action answers with the page as it is afterwards**, so the agent checks each step before the next. Text that has not changed since its last view is not sent again.
- **Pictures on request.** An agent whose model takes images can ask for a screenshot of the page. Only the two newest pictures are sent to the model; the conversation keeps them all.
- **A plain link is followed by loading its address.** That is how following a link can go without approval: it does exactly what opening that address would, and nothing else.

The actions are: open an address, search the web, read the page, take a screenshot, click, type into a field, choose from a list, scroll, go back, and upload a file.

Searching opens the results page of DuckDuckGo's script-free search, which the agent reads like any other page.

## Asking first

With **Ask before clicking buttons, typing and uploading** on, which is the default:

- Opening a page, searching, reading, scrolling, going back and following a plain link are not asked about.
- Clicking a button or anything else that is not a plain link, typing, choosing from a list and uploading wait for you. The request says what will happen in words, such as "Click “Submit application” on boards.greenhouse.io" or "Type “ada@example.com” into the “Email” field on example.com". When the text to type is long, the request shows all of it.
- You can allow once, allow that site for the rest of the conversation, or deny.

What you approve is what is done. If the page changes between the request and your answer, so that the same number now means something else, the action is not done and the agent is told to look again.

While an agent is browsing, a pill at the top of the screen says so. Its Show button brings up the page; its Stop button, or pressing Esc twice, stops the run.

## What it will not do

These hold whatever the agent, its instructions or a page say. They are checked in the engine and again in the app.

- **Only http and https.** `file:`, `javascript:`, `data:` and every other kind of address are refused.
- **Nothing on your Mac or your network.** `localhost`, loopback and private addresses (127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 100.64.0.0/10, `::1`, `fc00::/7`, `fe80::/10`), names ending in `.local`, `.localhost`, `.internal`, `.lan` or `.home.arpa`, and names with no dot in them are refused. The app also looks a name up before loading it, and refuses it if it points at one of those addresses. This applies to redirects, to links, and to what you type in the address field. Pages are kept from fetching from those addresses too.
- **Password fields are never typed into.** The agent is told to ask you to sign in yourself, in the Browser window. Fields marked for payment card numbers are refused the same way.
- **No downloads.** A link to a file is not saved; the agent is told so.
- **Uploads only of files you gave it.** An agent can upload one of its reference files, or a file in the conversation's folder if the conversation may read files there. With tool access off, the folder does not count.
- **No camera or microphone** for any page.

The agent is also told that what a page says is content, not instructions. That lowers the risk from text planted in a page; it does not remove it. Keep asking first on for anything that matters.

## Limits

- pi² must be open.
- Opening an address and searching are not asked about, and both send something to a site: the address, or the words searched for.
- A frame from another site is not read in place. It is listed with its address, which the agent can open as a page of its own. Sign-in and payment forms are often such frames.
- Pages closed to scripts in other ways (a closed shadow tree, a canvas) cannot be read; a screenshot may still show them.
- A page that is not showing in the Browser window counts as hidden to the site. Loading, timers and content that appears when scrolled to all work; animation that is driven frame by frame does not run until the page is shown.
- A page is given a few seconds to come to rest after an action. One that loads more later has to be read again.
- PDFs and other documents that are not web pages cannot be read.
- The check on private addresses looks at how an address is written and at what its name points to when the page is opened. A page's own requests to a public name that points at a private address are not caught.
- At most eight pages are kept open; the ones not used for longest are closed. Closing a page does not sign you out.
- The browser's cookies and sign-ins are kept by WebKit, outside pi²'s data folder, so a backup does not include them.
- **Forget Sign-ins and Site Data…**, in the Browser window's ⋯ menu, signs you out everywhere in pi²'s browser.
- A copy of pi² run on another data folder (`PI2_HOME`) has its own browser profile.

## For developers

Everything that touches WebKit is its own module, `app/Sources/BrowserKit`: loading, waiting for a page to settle, the script that lists a page's elements and text, and the actions. Unlike ComputerKit it needs no permission from macOS, so it is checked by a program:

```bash
cd app && swift build --product pi2-browser-probe
```

```bash
.build/debug/pi2-browser-probe
```

The probe serves a handful of pages to itself on this Mac (a form with every kind of field, a long page, pages that reach for private addresses, downloads, dialogs) and drives them through BrowserKit the way the engine would. It loads no real website, shows no window, and keeps no profile. `--show` prints each page as an agent would be given it; `--out <folder>` saves the screenshot it takes.

The engine's side (what may be opened, when to ask, what may be uploaded) is covered by `engine/test/engine.ts`, with a scripted stand-in for the app. To try the two halves together, build the probe and run:

```bash
cd engine && npm run test:browser
```

That starts a real engine on a throwaway data folder and has the probe stand in for the app as its browser (`pi2-browser-probe --engine <socket>`), so the approval card's words, the approval and the action all pass between the real engine and the real BrowserKit. It is not part of `npm test`, which needs no Swift.

The Browser window itself, and the few lines in the app that hand the engine's requests to BrowserKit, have no automated test.

With the scripted demo model, `/browser {"action":"open","url":"https://example.com"}` makes a browser call without a provider.
