# The transcript

A conversation is shown as one web page in a `WKWebView`, so a selection can run across prose, code and tool steps and be copied as text. The message field below it stays SwiftUI.

```
app/Web/transcript/        the page: plain HTML, CSS and JavaScript, no build step, no libraries
  index.html               the shell and its Content-Security-Policy
  transcript.css           the look; colours are Theme.swift's, sent by the app
  markdown.js              Markdown to elements (PiMarkdown)
  tools.js                 what a tool call's row says and opens to (PiTools)
  clipboard.js             what a selection copies as (PiClipboard)
  keys.js                  what Return does in the answer to a question (PiKeys)
  chat.js                  a chat's versions, sources and Try Again's models (PiChat)
  history.js               entries put above those on screen, without moving them (PiHistory)
  transcript.js            state, rows, scrolling, the bridge
app/Web/test/              node --test: the five modules above, with a small fake DOM
app/Sources/pi2/
  TranscriptPage.swift     the web view: loading, navigation policy, menu, drops; checking the page's messages
  TranscriptFeed.swift     what the page is sent, and only what changed since last time
  TranscriptWeb.swift      the SwiftUI view, and the bridge to the engine
```

`app/build.sh` copies `app/Web/transcript` into `Contents/Resources/transcript` in both development and release builds. After changing the page, run `./app/build.sh` again and reopen the conversation. A bare `swift build` has no bundle to put the page in; there `ConversationTranscript` falls back to the SwiftUI `TranscriptView`, which is otherwise unchanged.

In a development build the page can be inspected with Safari's Web Inspector (Develop menu, the app's name).

## How it is drawn

The page keeps the conversation as the app sends it: entries by ID, tool results joined to their calls by `callId`, the live state, and what is waiting on the person. Rows are keyed by entry (and, inside an answer, by call), and each remembers a signature of what it was built from. An update rebuilds only the rows whose signature changed. An answer that is still arriving is parsed again on each update, but only the Markdown blocks that changed are replaced, so the paragraphs above it, and a selection in them, stay put. Whether a row is open is kept apart from the rows, so it survives their rebuilding.

- The person's messages sit right, in a rounded box, with their pictures and files above. Pictures are fetched when they scroll into view, and open larger in an overlay.
- Answers are plain prose with full Markdown: headings, emphasis, strikethrough, code, fenced code blocks with a language, Save… and Copy, nested and task lists, tables, quotes, rules and links. Raw HTML is shown as the text it is.
- Tool calls are one-line rows: "Ran `npm test`", "Read session.ts", "Edited session.ts +6 −2". A chevron opens the detail: a command and its output, a diff, a file's text, a screenshot. A read of several files is one row that names them ("Read a.ts, b.md and 3 more", with how many files), and opens to a section per file, labelled with its path and range; a file the engine could not read is red in it, while the row is red only when none could be read. Running rows show a spinner and a present-tense line; a shell command's row also shows how long it has run, and "quiet for 45s" once it has printed nothing for 30 seconds, ticked by the page once a second from the times the engine sends ([architecture.md](architecture.md#a-running-commands-clock)); a failed row is red and starts open. A command that ended by itself with an exit code other than 0 that is not a failure (a `grep` that found nothing; [architecture.md](architecture.md#a-commands-exit-code)) is not a failed row: it says "Exit code 1" at the end of its line, in a quiet colour, and stays closed. A command that could not be started (exit code 126 or 127), was ended by a signal, or was stopped at its time limit is a failed row. A call with no result after its run stopped says "No result". A command started with `background: true` reads "Started `npm run dev` in the background" with its id; one moved there at its time limit reads "Ran `npm test`, moved to the background as bg-4". The rows that read its output and stop it name the command ([background.md](background.md)). Once the engine has answered, each of those rows, and the line that says a background command ended, has an Output button at its end that opens the window with what the command printed. The id comes from the engine's answer (or, for the line, the entry's `details.background.id`), never from the id the agent asked for.
- A hand-off names the agent and the task, shows the answer folded to two lines, and has two buttons for the sub-chat: Open shows it in place of the conversation, and Beside splits the pane and shows it next to the conversation. One whose wait a message from the person ended says "Stopped waiting for your message; still working" instead of an answer ([architecture.md](architecture.md#a-message-while-an-agent-waits)).
- An approval or a question waiting on the person is a card at the call, with the Inbox's words and buttons. An edit's card also shows the change. A question's answer field grows with its lines: Return sends, Shift-Return or Option-Return starts a new line, and Return while an input method is composing confirms the candidate, as in the app's message field (`keys.js` mirrors ComposeKit's rule).
- A wake is a closed row, "pi² woke the agent: …", whose chevron opens to the exact message the agent was given, as plain text. It includes every result in a batch and any limit notice, and remains readable after a restart, also for wakes saved before this row was added. A single command's wake keeps its separate Output button. Other notices about waking stay plain lines.
- Thinking is a "Thinking…" line while it streams and a "Thought" row afterwards.
- Hovering over the end of a turn shows Copy (the turn's Markdown) and Fork from here, and, for a turn of 1,500 characters or more, Save as a File… (the same Markdown, as `answer.md`); hovering over a message of the person's shows Copy. A chat has its own controls there instead of Fork from here ([below](#a-chats-controls)).
- **Saving as a file** (#286): a code block's Save… offers `code.<ending>` for its language (`code.py`, `code.sh`; `code.txt` for one it does not know), an open tool output's Save… its file's name when its label is one (`notes.md`) or `output.txt`, an edit's `changes.diff`. A picture opened larger has Save…, which saves it as the engine has it. A document `write_document` wrote has, at the end of its line, **Open**, which opens it in the app the person uses for that kind of file, and **Save a Copy…**: a chat's documents are kept in the data folder, where the person would not find them. Each asks the app, which shows a save panel; the page only offers a name, and names a picture or a document by the entry that holds it, never by a path.
- The page follows new content while the reader is at the bottom. Scrolling up stops that, and a "Jump to latest" button appears. Sending a message brings the reader back.

## A long conversation, newest first

Opening a conversation draws its newest entries first and the older ones just after (#380), so a long one shows about as soon as a short one. Every step of opening grows with the bytes sent, not the number of entries, and an entry can be a few hundred bytes or 50 KB of command output, so the parts are cut by size:

- **The engine** (`engine/src/opening.ts`), when the app asks `conversation.open` with `newestFirst: true`, sends in its first `conversation` event the newest entries that come to 64 KB of JSON or number 40, whichever comes first (at least one), with `earlier`, how many are still to come. It answers the request then. The rest follows at once in `conversation.older` events of at most 256 KB, newest first, each holding entries in order that go just before the oldest the app has, with `earlier` counting down to 0. It sends one, then lets other requests and events through before the next. A part never starts with a tool result: it reaches back to the answer whose call it is.
- **Entries committed meanwhile** come as usual, at the end. Anything that starts the list over (another version of a chat shown, the engine's window moving on) splits the new list the same way and drops what of the old one was still to come; `conversation.close` stops it too.
- **The app** keeps the older entries in front of the others (`OpenConversation.prepend`) and how many are to come (`earlier`). `TranscriptFeed` sends a page that has none of the entries yet the newest part the same way, and the older ones a part at a time, each once the page has drawn the one before: every pane opens its own page, which loads after the engine's entries have usually all come, and it is the page's drawing that the split saves. A second pane on the same conversation is fed the same way.
- **The page** puts older entries above the first row. Before drawing them it notes the first row whose bottom is on screen and where it is, and after scrolls by however far it moved, rounded to whole pixels, so what is on screen stays put; a reader at the bottom stays at the bottom. While `earlier` is above 0, "Loading earlier entries…" sits at the top, and is not copied. The end of a turn is drawn again when entries come above it, since its Copy takes the whole turn.
- **Older and newer programs.** An app that does not ask for `newestFirst` gets the conversation in one event, as before, and never `conversation.older`; an engine from before #380 ignores the request's `newestFirst` and sends no `earlier`, which the app reads as nothing to come. The page is built into the app.

Copy and select-all work on what the page has, which is everything the app was sent once the last part has come, a fraction of a second after the first. Export and the palette's search ask the engine, which reads every entry.

## A chat's controls

When the app tells the page the conversation is a chat (`chat.enabled`), the page shows what a chat adds (#285; the engine's side is in [architecture.md](architecture.md#a-chats-versions)):

- **Try Again** at the end of a turn answers the turn's message again, as a new version; the narrow button beside it opens the list of models to try again with, the model selector's, grouped by provider, with the one in use ticked. Escape or a click elsewhere closes it.
- **Edit** on the person's message opens it in a field in place of the bubble: Return sends it as a new version, Shift-Return or Option-Return starts a new line, Escape or Cancel leaves it as it was. What it had attached goes with it.
- **‹ 2 / 3 ›** under a message or a turn with several versions shows which is shown and steps to the others. It stays in view without the pointer over the row, and is unavailable while an answer is being written. It sits under the first message or answer after the point where the versions part (`PiChat.versionRows`), which for Try Again is the end of the turn and for Edit the message.
- **Sources** under a turn name the pages it read with `web_fetch`, each once, as links: the page's title and its site. A page a search only listed is not a source.

Fork from here is not offered in a chat. The app decides from the conversation's state, which says `chat: true` for a chat (`TranscriptFeed.Chat.shown`).

Retries, failures, compaction, a wait for a provider's limit and queued messages are shown outside the transcript by `ChatView`, as before. Inside it, each failed attempt of a request is an answer row that says "This attempt failed" with the error; attempts that failed in a row, with nothing else in them, show as one row, the last, which says how many there were ("6 attempts in a row failed; the last said:"), since a run waiting for a provider's limit can leave dozens ([limits.md](limits.md#when-a-limit-is-reached); `failedRuns` in `tools.js`).

## Copying

The page answers every copy itself (`clipboard.js`), so what lands on the clipboard reads well as text: lists keep their markers, quotes their `>`, tables become tab-separated rows, and code and command output are copied exactly. A collapsed tool row gives its one-line summary; an open one its summary and content. Buttons, chevrons, spinners and anything marked `data-nocopy` give nothing; an element with `data-copy` gives that text instead (a picture gives `[Picture: name]`). A rich-text copy goes along with the plain text, with every attribute stripped except a link's address. ⌘A selects the whole transcript. Each code block and each open tool output also has its own Copy button.

## Messages between the app and the page

The app calls `window.pi2.receive(json)` with `callAsyncJavaScript`, passing the JSON as an argument (never as script). Each message carries only what changed:

| Field | What |
|---|---|
| `reset` | Forget every entry: the page has just loaded, or the conversation was reset. |
| `items` | New entries, as the engine sends them (`Item`). |
| `older` | Entries that go before the first the page has, oldest first ([newest first](#a-long-conversation-newest-first)). |
| `earlier` | How many entries older than those the page has are still to come; 0 when none are. |
| `live` | `{busy, partial, tools, retrying}`: the answer still arriving and the tools still running. A shell command running in the foreground has `startedAt` and `lastOutputAt` (ms since 1970, or null until it prints) for its clock. |
| `inbox` | Approvals and questions waiting in this conversation (`InboxItem`). |
| `names` | What only the app knows: `mcp` (tool name to "Server: tool"), `agents` (name, colour, model), `apps` (bundle ID to name), the conversation's `agentName`. |
| `palette` | Theme.swift's colours resolved for the view's appearance, and `appearance`. Sent again when the appearance changes. |
| `image` | A picture the page asked for: `{entry, index, mimeType, data}`, or without `data` when it could not be had. |
| `chat` | `{enabled, versions, models, model}`: whether it is a chat; where its versions part and which is shown (`{after, index, count}`, `after` null before the first message); the models Try Again offers (`{provider, id, name, group}`); and the model in use as `provider/id`. `enabled` false for an agent's conversation. |

The page posts to the `pi2` message handler. `TranscriptAction` checks every message (a known type, fields of the right kinds, sizes within limits) and `TranscriptBridge` checks that what it names belongs to this conversation before acting, with the same engine requests the SwiftUI views make:

| Message | Checked | Then |
|---|---|---|
| `{type: "ready"}` | | Send everything. |
| `{type: "copy", text}` | non-empty string, at most 20 million characters | The general pasteboard. |
| `{type: "openLink", url}` | http or https with a host, or mailto | The default browser or mail app. |
| `{type: "decide", inbox, decision}` | decision is `once`, `always` or `deny`; the approval is waiting in this conversation | `inbox.decide` |
| `{type: "answer", inbox, text}` | text not blank, at most 100,000 characters; the question is waiting in this conversation | `inbox.answer` |
| `{type: "openChat", id, beside}` | a whole number; a sub-chat one of this conversation's hand-offs opened. `beside` is optional, true or absent | `openConversation`, then `onOpenBeside` (a pane beside this one) or `onNavigate` |
| `{type: "fork", entry}` | a whole number; an answer in this conversation | `engine.fork` |
| `{type: "retry", entry, model?}` | a whole number, an answer in this conversation; `model` `{provider, modelId}`, one Try Again offers; a chat | `conversation.retry` |
| `{type: "edit", entry, text}` | a whole number, a message of the person's in this conversation; text at most a million characters; a chat | `conversation.edit` |
| `{type: "version", after, index}` | `after` null or a whole number, `index` a whole number: a point the engine named, and a version it has; a chat | `conversation.version` |
| `{type: "image", entry, index}` | whole numbers; the entry holds that many pictures | `conversation.image`, then an `image` message back |
| `{type: "save", text, name}` | text as for `copy`; a name of 1 to 120 characters, with no `/` or `:`, not starting with `.`, nothing unprintable | A save panel offering the name; the text written there as UTF-8 |
| `{type: "savePicture", entry, index}` | as for `image` | `conversation.image`, then a save panel offering `Picture.png` (or the picture's own type) |
| `{type: "openDocument", entry}`, `{type: "saveDocument", entry}` | a whole number; a `write_document` call of this conversation that succeeded, whose result names a file that is still there | Open: `NSWorkspace.open`. Save: a save panel offering its name, and a copy of the file there. Either says so if the file has gone |
| `{type: "output", id}` | `bg-` and a number; a background command this conversation's rows name, as the engine's results and lines name it | The command's output window (`openWindow`), as Activity's Output opens it |

Anything else is ignored, as is any message from another frame or another page.

## Safety

Everything in a transcript is untrusted: model output, tool output, web page text, file names.

- Nothing from the conversation becomes markup. The Markdown parser makes plain objects, and the page builds elements from them with `createElement` and `createTextNode`; tool rows, cards and chips are built the same way. No conversation text is ever assigned to `innerHTML`.
- Links keep only `http`, `https` (with a host) and `mailto` addresses (`PiMarkdown.safeURL`); anything else is shown as text. A link's address is its tooltip. A click asks the app, which checks the address again and opens it in the person's default browser. The page itself never navigates.
- Pictures in Markdown are never loaded; a web picture becomes a link to it.
- The Content-Security-Policy allows only the page's own scripts and stylesheet and `blob:` pictures: no inline scripts or styles, no fetches, frames, fonts, forms or base URL. The harness checked that fetches and image loads to other hosts are refused by it, as are inline scripts and style attributes.
- The web view allows exactly one navigation, the page itself, and cancels every other (links, reloads, scripts, dropped files). It opens no windows, keeps no website data on disk, has link previews off, takes no drops (files dropped on the conversation still attach to the message), and its menu has no Reload, Open, Download or Back items. If its process ends, it loads the page again and resends the conversation.

## Testing

```bash
cd app/Web && node --test test/
```

covers the Markdown renderer (including hostile HTML, link schemes, attribute escaping, half-arrived Markdown, tables, nested lists, fences, pathological input), the tool summaries and diffs, what a selection copies as, a chat's versions, sources and models (`chat.test.mjs`), and how older entries are put in front and which row is kept in place while they are (`history.test.mjs`). CI runs it.

For #380 the same kind of offscreen harness fed the page a conversation of 295 entries newest first, the reader scrolled to the top of the first part, and five older parts and a new answer arrived: the row on screen moved by at most 0.3 pixels at each, the steps ran in order across the join, a reader at the bottom stayed there, and select-all copied the whole list without the loading line.

The page itself was checked with an offscreen harness: a throwaway Swift program, kept out of the repository, that compiled `Models.swift`, `Theme.swift`, `TranscriptFeed.swift` and `TranscriptPage.swift` with a stub for `AttachmentNote`, loaded the page in the app's own `TranscriptWebKitView` in an offscreen window, fed it a realistic conversation through `TranscriptFeed`, and took snapshots in dark and light: streaming, opened rows, approval and question cards, hostile content, a 400-entry conversation, and the text a select-all copies as.

## Known limits

- The page is copied at build time, so a change to it needs `./app/build.sh` and reopening the conversation.
- A drag that starts on a control (a chevron, a button) does not start a selection, as in any web page; start it on text.
- The engine sends a conversation's newest 300 entries as it is opened (its view of a conversation is a window of 300 to 600 entries), so the oldest entries of a longer one are not shown, though Export and search still read them. They could come in when the person scrolls up, with the same `conversation.older` event. What is sent is drawn whole: there is no virtual scrolling.
