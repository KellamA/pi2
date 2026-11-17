# Development

## Requirements

- macOS 15 or later
- Xcode's command line tools (Swift 6)
- Node 26 or later

## Build and run

```bash
cd engine && npm ci
```

```bash
./app/build.sh
```

```bash
open "app/build/pi² dev.app"
```

`npm ci` also runs `engine/scripts/patch-dependencies.ts`, which fixes bugs in installed dependencies that their own releases do not have yet (each patch says what and why). If a dependency update changes a patched file, the install stops with a message: check whether the fix is still needed, then update or remove its patch.

This is a development build. It runs the engine from `engine/` with the Node on your `PATH`, so engine edits take effect the next time the engine starts (**Debug › Kill Engine** restarts it), and the build only works on this machine.

A development build keeps apart from a pi² installed on the same Mac, so opening one can never reach that copy's conversations, sign-ins, preferences, macOS permissions or login item:

- Its bundle id is `dev.pi2.app.dev`, and it is called "pi² dev" in the Dock, Finder and the menu bar. macOS keeps its preferences, notifications and privacy permissions apart from the installed copy's (`dev.pi2.app`).
- Its data folder is `~/Library/Application Support/pi2-dev` and its Keychain service `dev.pi2.credentials.dev`, unless `PI2_HOME` and `PI2_KEYCHAIN_SERVICE` name others. Both are named after the bundle id: a copy whose bundle id is `dev.pi2.app.test-7` uses `pi2-test-7` and `dev.pi2.credentials.test-7` (`app/Sources/pi2/DevelopmentBuild.swift`).
- It never uses the usual data folder, `~/Library/Application Support/pi2`, or the usual Keychain service, `dev.pi2.credentials`, even when `PI2_HOME` or `PI2_KEYCHAIN_SERVICE` names them; it uses its own instead and says so in its `app.log`. That can happen without anyone meaning it: a terminal where they are set passes them on, and so did every command an agent of pi² ran until #195, which inherited its engine's `PI2_HOME`; `open` passes them on to the app it opens. The engine now leaves every `PI2_` variable but `PI2_RUN` out of what it starts ([architecture.md](architecture.md#what-commands-can-find)). To try a development build on your own conversations, restore a backup of them (Settings › Storage) into the development build's data folder; you sign in again there, since the sign-ins stay with the installed copy.
- It cannot turn the login item on or off: the switch in Settings › General shows as unavailable, as in any copy on a data folder of its own.
- It never updates itself, and it never replaces the engine it finds on its data folder: that is only done by a release build, after an update. An engine started by another development build with the same bundle id, from another checkout, is noted in `app.log` and left running.

To check a problem that only happens with optimisation (such as #134), build an **optimised development build**:

```bash
./app/build.sh optimised
```

This compiles with Swift's release configuration (`-O`), but otherwise makes the same `app/build/pi² dev.app`: its own identity and data, the source engine, and all the development affordances below, including `PI2_SHOW` and keeping its windows out of the way. Use it in a throwaway copy just as for the ordinary development build. It defines `PI2_DEVELOPMENT` at compile time; debug builds define it through `Package.swift`. A release build never defines it, so those switches and the web inspector are compiled out, not enabled by an environment variable. `swift build -c release` alone is not an optimised development build; use the script.

For an app that carries its own Node and engine and can be moved:

```bash
./app/build.sh release
```

This makes `app/build/pi².app`, with the bundle id and the name of the release (`dev.pi2.app`, "pi²"), on the usual data folder and Keychain service unless `PI2_HOME` and `PI2_KEYCHAIN_SERVICE` say otherwise. That is the build that is released, so do not open it as built on a Mac where pi² is in use: [Testing safely](../CONTRIBUTING.md#testing-safely) says how to try one.

Signed builds, the update feed and the release workflow are described in [releasing.md](releasing.md).

## Tests

```bash
cd engine && npm test
```

This runs, side by side, every file in `engine/test` but two: `patience.ts`, which is not a test but what the tests that start an engine share, and `browser.ts`, which needs the browser probe ([browser.md](browser.md)). A test you add as `engine/test/<name>.ts` is picked up by itself, with nothing to add to `package.json`; `node test/<name>.ts` runs it alone. Only `test:engine` and `test:browser` keep npm aliases; do not add per-file scripts for new tests. A file there that is not a test goes in the pattern in `package.json`'s `test` script, beside those two. Give a test you add a line of its own below, in its place by file name, so that two pull requests adding tests rarely touch the same lines. The tests:

- `addedmodels.ts`: models added by hand to a built-in provider: what a new id is based on, adding, changing, keeping, giving way to the catalog and removing one, against stand-in providers; then a real engine whose added models are sent to a stand-in server on 127.0.0.1, which answers one and refuses the other, and what a conversation says when one is refused or removed.
- `background.ts`: background commands. An engine starts, reads and stops commands, and is stopped and killed with commands running; nothing they started is left.
- `cache.ts`: the prompt cache's lifetime. An engine against a stand-in Anthropic endpoint on 127.0.0.1: a conversation asks for the one-hour cache once it has handed out work and the others do not, a refusal of it is sent again with the short cache, and `engine.log` says what a request after a pause read; see [limits.md](limits.md#the-prompt-cache).
- `chat.ts`: chat mode's engine: a chat made, listed, opened and told it is one; offered only the assistant's tools, asking nothing, writing documents in its own folder; its model, settings and web setting; pinned, searched, counted, exported, shown in Activity, forked, archived and deleted as a chat. See [chat.md](chat.md).
- `codemode.ts`: what a conversation is told about scripts, with a test MCP server of 40 tools. It prints the size of each section of the system prompt; see [codemode.md](codemode.md).
- `credentials.ts`: the Keychain store.
- `documents.ts`: the documents tool.
- `earlystop.ts`: an engine told to stop while it is still starting stops cleanly (a real engine held in start-up by a stand-in shell that never answers).
- `engine.ts`: the end-to-end test described next.
- `environment.ts`: an engine started with pi²'s own variables set does not pass them to a shell command, a background command, a set-up command or an MCP server, and the commands get their conversation's scratch folder, a sub-chat its own, kept when archived and removed when deleted. The commands, not the server, get the variables the person gave their agent, whose values are in a Keychain service of the run's own and not in the data folder or a backup; a sub-chat gets its own agent's, names that would undo what the engine sets are refused, a copy of the agent gets the names alone, and deleting it removes its values.
- `exec.ts`: commands keep their output when the engine is busy as they exit, and get no input.
- `latepath.ts`: a login shell too slow for start-up still has its `PATH` and `SSH_AUTH_SOCK` taken when it answers (stand-in shells, and two real engines).
- `limits.ts`: the plan-limits refresh handler's minimum interval, with a controlled clock and stand-in fetch; no socket round trips have to fit inside a short window.
- `limitwait.ts`: limit waits. It reads refusals and decides waits on a clock of its own, then runs an engine against a stand-in provider on 127.0.0.1 that refuses with HTTP 429 and 529 and then answers, kills that engine in the middle of a wait, and stops it; see [limits.md](limits.md#when-a-limit-is-reached).
- `log.ts`: every line of `engine.log` starts with its time, and `--restore`'s output does not.
- `look.ts`: the look tools.
- `mcppath.ts`: MCP servers started before a slow login shell answers are started again with its `PATH`, without cutting off a call (a stand-in shell, a test MCP server and a real engine).
- `mcpreconnect.ts`: reconnecting, editing, removing or switching off an MCP server deals with a call running on it as [architecture.md](architecture.md#an-mcp-server-changed-while-a-call-runs-on-it) says (a test MCP server whose calls answer when the test lets them, and a real engine).
- `modellists.ts`: asking a provider which models a key or sign-in can use, against stand-in providers on a stand-in server on 127.0.0.1 answering as ChatGPT's Codex service, Anthropic (two pages), OpenAI and Google do; a refusal (the key not repeated), a redirect (not followed) and providers that cannot be asked; and the catalogs the library refreshes itself, at start, on asking and from the store at the next start.
- `offered.ts`: computer use with no app allowed, and scheduling in a sub-chat, are not offered, and neither are the built-in tools an agent's settings leave out: not their sections, not in a sub-chat of that agent, not to a script; a duplicated agent keeps the list. It prints the size of the prompt and the tool definitions for a plain agent, for such a sub-chat, and for a worker-like sub-chat with every built-in tool and with those a worker never uses left out.
- `planwindows.ts`: how full a subscription's windows are, as `delegate`'s result and `sub_chats`' list tell an agent that hands out work, and the Inbox notice when a window passes 90% with runs on it going. An engine with two stand-in subscriptions signed in under a test Keychain service, one of them answering requests over TLS on 127.0.0.1; see [limits.md](limits.md#telling-an-agent-that-hands-out-work-and-the-person).
- `reading.ts`: `read` of several files, or several parts of one, in one call, around the library's own tool.
- `rules.ts`: the command rules. It also runs the commands its rules allow through `/bin/bash`, in a folder of its own.
- `sections.ts`: it switches on, one at a time, what brings a section or a tool into a conversation, then leaves the built-in tools out one at a time and brings them back, and checks with `/system history` that each change is sent alone, without the rest of the prompt; see [architecture.md](architecture.md#the-system-prompts-sections).
- `shellpath.ts`: commands get the login shell's `PATH` and `SSH_AUTH_SOCK`, and nothing else from it (stand-in shells, the question itself in the real `bash` and `zsh`, and a real engine started with the bare `PATH`).
- `socket.ts`: the engine's socket path, and a data folder whose path is too long for a socket, which the engine then reaches through a short link.
- `testcopies.ts`: test copies of pi² for computer use (#146), with a stand-in for the app. Off, an unlisted copy is refused and a listed one is look-only, as before; on, the tool comes without an app, a copy is listed, looked at and acted on with the usual approvals, the app is told so it can check the copy itself, and pi² itself, the development build, other copies and terminals stay refused; a sub-chat follows its own agent's switch.
- `worktrees.ts`: it makes throwaway git repositories and has an engine make and remove worktrees in them.

The end-to-end test starts a real engine on a throwaway data folder and a throwaway Keychain service and drives it over the socket: chat, pictures and files in messages, tools, approvals, delegation and sub-chats, reference files, computer use and the browser (each with a stand-in for the app), schedules, crash recovery (`kill -9` mid-answer and mid-approval), usage and budget, search, code mode, a test MCP server, a mock OpenAI-compatible endpoint with and without a key, export, backup and restore. It makes the demo model type fast (`PI2_DEMO_TOKENS_PER_SECOND`); a check that needs an answer still on its way, to stop it or kill the engine in the middle of it, sends a message starting with `/slow `, which is answered at the usual pace. `npm run test:engine` runs this test alone.

Each test removes the folders it makes in the temporary folder, and the Keychain items it makes, when it ends, whether it passed or failed. A test you add should do the same: in a `finally`, or, in a test with no `try` around it, in a `process.on("exit")` handler, which still runs when a failed check ends the process. An engine's [scratch folders](architecture.md#a-scratch-folder) are in `/tmp/pi2-<uid>`, outside its data folder: `engine/test/patience.ts` removes those of every engine a test connected to through it, as the test's process exits. Several runs of the suite can go at the same time on one Mac (several agents, or two worktrees), so a test checks only what it made itself: it does not count what is in the shared temporary folder (the documents test gives the code it checks a temporary folder of its own), listens on port 0 rather than a fixed one, and keeps Keychain items under a service no other run uses (the end-to-end test's has its process id in it, unless `PI2_TEST_KEYCHAIN_SERVICE` names one). To see what a run leaves behind, give it a temporary folder of its own with a short path (a long one makes the engines' socket paths too long), then list it: only npm's own `node-compile-cache` should be there.

```bash
T=$(mktemp -d /tmp/tests.XXXX)
(cd engine && TMPDIR="$T" npm test)
ls -A "$T"
```

The whole suite takes about 80 seconds on a quiet Mac. Four runs at once took about two minutes each and six about two and a half, so runs from several agents or worktrees are quicker started side by side than taken in turn. Send a run's output to a file and read the file, rather than cutting it down with `tail` or `grep` as it runs: when the part you kept does not answer the question, the file does, and the suite does not have to run again.

```bash
(cd engine && npm test > /tmp/tests.log 2>&1; echo "exit $?")
grep -E "^(ℹ|✖)" /tmp/tests.log
```

No check may depend on how fast the Mac is. With several runs of the suite going at once, an engine can take well over ten seconds to start listening, and anything can take many times longer than on a quiet machine. So a test waits for the thing itself, never for a time, and the limit on a wait (ten minutes, `PATIENT_MS`) is only there so that a hang fails instead of running for ever. A wait the test can tell has failed ends at once: when the engine exits, or the connection to it closes. `engine/test/patience.ts` has this for every test that starts an engine: `listening` connects once the engine listens, `EngineClient` is a connection with requests, events and `until`, and `stop` stops a process and waits for it. A process that only a check should stop (a command's `sleep`, a stand-in shell's program) runs for longer than any wait, so that a wait for it to be stopped cannot be met by its ending by itself. Where a check is about time, it measures what it is about: the processor time the converter took, or the time between a request arriving at a stand-in and the engine giving up on it, rather than the time on the test's clock around them. One check must retain an elapsed-time bound: a clean stop must fit in the five seconds the app gives the engine before a restore. It uses the engine's own monotonic elapsed time, not the test's time around the signal and exit, so a test process slow to notice the exit does not cause a failure. Scheduling delays inside the engine still count, as they do toward the app's deadline: subtracting them or using only processor time could hide a stop that really waits too long. This requirement can fail under extreme load; quiet CI verifies it. Where the engine has a limit of its own on a wait, such as the 30 seconds a request for a background command's output may wait, a test that must tell the wait ending for its reason from the limit running out sets the limit longer than its own patience (`PI2_OUTPUT_WAIT_SECONDS`). Before a test kills an engine to check that something outlives it, it waits for the answer or event that comes once that thing is stored, not for a time: a tool's result, or an event the engine sends from a stored document (the agents, the library). An event can come sooner than the storing it seems to report: the one that lists a background command as running comes before its process is on record, which the call that started it waits for. Streamed progress, such as the part of an answer already shown, is stored about a second later and may be lost.

```bash
cd engine && npm run check
```

type-checks the engine.

The part of the app that works web pages is checked by a program of its own, which serves a few pages to itself and loads no real website:

```bash
cd app && swift build --product pi2-browser-probe && .build/debug/pi2-browser-probe
```

With the probe built, `cd engine && npm run test:browser` runs a real engine against it, to check that the two agree. See [browser.md](browser.md).

The panes the conversation area is divided into (`app/Sources/PaneKit`) are checked by a program of its own: it splits panes, closes them down to one in every ready-made layout and at random, gives them equal room, saves and reads back each tree, and reads back damaged saved layouts, which must give a single pane. Build it with optimisation, as the app is released; closing a pane once crashed only in an optimised build (#134), and CI runs it this way:

```bash
cd app && swift build -c release --product pi2-layout-check && .build/release/pi2-layout-check
```

A crash in it prints the step it happened in; `--verbose` prints every step.

What Return does in a field that sends a message (`app/Sources/ComposeKit`: Return sends, Shift-Return or Option-Return starts a new line, and Return while an input method is composing is left to it) is checked by a program of its own. It checks the decision for every combination of modifier keys, then makes a SwiftUI text field as the message field is made, in a window of its own that never comes on screen, and hands key presses straight to that window: no key is posted to the system and no permission is needed. It checks that Shift-Return puts a line break at the cursor in place of the selection and the field grows, that Return sends the text with its line breaks, that Return with marked text (what an input method shows while a candidate is chosen) does not send, and that pasted line breaks are kept. It checks a field made as a memory note is in an agent's settings (a field of a grouped form that saves with Return and keeps its text) in the same way. Then it does the same for the answer field of a question on the conversation page, which has its own copy of the rule (`keys.js`): it loads the real page from `app/Web/transcript` in a web view that keeps nothing on disk. It cannot type with a real input method, so that is still worth trying by hand after a change there. CI runs it after building the app:

```bash
cd app && swift build --product pi2-compose-check && .build/debug/pi2-compose-check
```

The conversation page (`app/Web/transcript`) has tests that run in Node with a small stand-in for the DOM: its Markdown, its tool summaries and what a selection copies, including text written to break out of the page.

```bash
cd app/Web && node --test test/
```

See [transcript.md](transcript.md). The rest of the app has no automated tests. A development build already runs on a data folder of its own, so trying a change in it does not touch your own data. To start again from an empty folder, give it another:

```bash
open -n "app/build/pi² dev.app" --env PI2_HOME=/tmp/pi2-try --env PI2_KEYCHAIN_SERVICE=dev.pi2.credentials.try
```

On a Mac where pi² is in real use, and where other sessions may be testing too, try it in a copy with a bundle id of your own and clean up after it: `scripts/test-copy start test-7`, then `scripts/test-copy stop test-7`. [Testing safely](../CONTRIBUTING.md#testing-safely) in CONTRIBUTING.md has the rules and what the script does for each.

A development build (ordinary or optimised, not a release build) also reads a few variables that help when taking pictures of the app or checking it by script:

- `PI2_SHOW` chooses what the window opens on: `inbox`, `activity`, `usage`, `archive`, `branches`, `agent:<id>`, or a conversation's number or title, matched exactly against the sidebar first, then the Archive. This includes a sub-chat archived on its own; opening it does not restore it, and the conversation still shows its archived bar and Restore button. Use the number when titles are shared. An agent's page is taller than any window, so `agent:<id>#<section>` opens it with one of its sections at the top: `profile`, `model`, `instructions`, `files` (reference files), `memory`, `tools`, `builtins` (built-in tools), `rules` (commands it may run without asking), `variables` (variables for its commands), `extras` (extra tools), `computer`, `browser`, `schedule` or `delegates` (who it can hand work to). A name it does not know opens the page at the top. The last few sections cannot come to the top, since the page ends below them; the page scrolls to its end and they show there. The page settles for a second or two after it opens, so wait a few seconds before capturing it.

  `output:<id>` opens a background command's output window as well, such as `output:bg-1` ([background.md](background.md)), about a second after the app has connected to its engine; the main window opens as it would without `PI2_SHOW`. It is a window of its own, 760 points wide, named after the command.

  `settings` opens the Settings window as well, which is a window of its own, and the main window opens as it would without `PI2_SHOW`. `settings:<tab>` opens it on one of its tabs: `general`, `providers`, `tools` or `storage`; a name it does not know opens General. A tab can be taller than the window, so `settings:<tab>#<section>` opens it with one of that tab's sections at the top: `appearance`, `notifications`, `background` or `updates` on General; `subscriptions`, `endpoints` or `keys` on Providers; `servers` or `commits` on Tools; `folder` or `backup` on Storage. A section the tab does not have leaves it at the top, and so does one in a tab that already fits the window. On Providers, `settings:providers#models=<provider>` opens that provider's Models sheet, such as `#models=openai`, once the provider has models (it is signed in or has a key), and `settings:providers#add-model=<provider>/<model id>` opens its sheet for adding a model by id over it, with the id typed and looked up (`#add-model=openai/gpt-6.2-sol`; `#add-model=openai` leaves it empty). On Tools, `settings:tools#variables=<server id>` opens that MCP server's Variables sheet, once the server is listed. Settings opens about a second after the app has connected to its engine, not while the app is launching, and a section takes a few seconds more to settle, so wait before capturing it. In the list of windows it is the one 660 points wide.

  `palette` opens the command palette (⌘K) over the main window, which opens as it would without `PI2_SHOW`, and `palette:<query>` opens it with that query typed, so a capture shows the entries that match it, and the messages that do after the search has run. It opens about a second after the app has connected to its engine. The entries are listed by the palette's own code, so one added to it shows here with nothing more to do.
- `PI2_MENU=<label>` writes what a right-click on the element labelled `<label>` would show: the items of its context menu, in order, with submenus indented below their item, and the ones that cannot be chosen marked `[disabled]`. A conversation's row is labelled by its title and by its number, an agent's by its name and by its id, a row in the Archive as a conversation's is, and a pane's header as VoiceOver reads it (`Pane: <title>`, or `Empty pane`). The list goes to `context-menu.txt` in the data folder, a couple of seconds after the app has connected to its engine, and again a second after an element with that label comes on screen, so a row made after launch (through the engine's socket, say) is covered too; with no such element on screen, the file says so. A context menu is a pop-up macOS draws only while the app is in front, so it cannot be captured from a copy that must not take the focus; its items are made by the view, though, and can be asked for. Every context menu in the app is made with `.contextMenu(previewAs: <labels>)` (`LaunchPreviews.swift`), which in a development build puts an anchor behind the element whose label was asked for. The app builds a right-click event at the anchor's middle, never posted anywhere, and hands it to the view there with `menu(for:)`, as AppKit does to ask a view for its context menu; nothing is chosen and nothing appears on screen. A menu added with `.contextMenu(previewAs:)` is covered with nothing more to do, and `scripts/test-test-copy` fails on a plain `.contextMenu`. In a release build `.contextMenu(previewAs:)` is `.contextMenu` and nothing more.
- `PI2_DRAW_WHEN_HIDDEN=1` keeps the transcript drawing while the window is covered or the screen is locked. WebKit normally stops drawing a page nobody can see, which leaves it blank in a window capture. This uses a WebKit switch that is not public, which is why it is left out of release builds.
- `PI2_WINDOW_BEHIND=1` keeps the copy's windows behind every other app's windows, from the moment they open: they sit just below ordinary windows (at window level -1, the `kCGWindowLayer` that `CGWindowListCopyWindowInfo` reports), so nothing brings them forward, not a sheet, Settings opening or a click. A window behind others is still drawn, and `screencapture -l` captures it whole; for the transcript, add `PI2_DRAW_WHEN_HIDDEN=1` as for any covered window.
- `PI2_WINDOW_ORIGIN=x,y` opens the main window, Settings, the browser and a background command's output with their top-left corner at that point, in points from the top-left corner of the main screen (the measure of `kCGWindowBounds`). It applies while a window opens, until a second after it shows; one already open can be moved as usual. macOS keeps a window from opening entirely off the screens: it moves it back until a corner of it (about 40 points across) shows, so a point far off to the bottom right, such as `10000,10000`, parks the window in the bottom-right corner with only that corner on screen. A sheet, such as the first-run welcome a copy on a new data folder shows (`scripts/test-copy start` marks it done unless given `--welcome`), brings its window back far enough for the whole sheet to show. A window parked like that is drawn in full, and `screencapture -l` captures all of it.

  Without these, a copy's main window opens in the middle of the main screen at every launch, even launched with `open -g`: SwiftUI centres it, and ignores a frame written into the copy's preferences. A check that launches a copy many times should use both, as the steps in [Testing safely](../CONTRIBUTING.md#testing-safely) do.

To check a page without clicking, start a throwaway copy on it and capture its window: `scripts/test-copy start test-7 --show agent:<id>#rules` launches it with `PI2_SHOW` and the three variables above, with the first-run welcome marked done in the copy's data folder so that it does not cover the page (`--welcome` keeps it), and `scripts/test-copy shot test-7 app/build/test-copies/test-7/rules.png` captures it with `screencapture -l`, taking the window's id from `CGWindowListCopyWindowInfo` for the copy's process. It checks first that screen capture is already allowed (`CGPreflightScreenCaptureAccess()`) and refuses if it is not, since capturing without it makes macOS ask. For a palette entry, `--show palette:<query>` and a capture; for a context menu, `--menu <label>`, which sets `PI2_MENU` and prints the file it writes.

The scripted demo model answers `/bash <command>`, `/timeout <seconds> <command>` (bash with a `timeout`), `/background <command>` (bash with `background: true`; see [background.md](background.md)), `/tool <name> <json>` (any tool the conversation has, such as `/tool background {"action":"list"}`, or `/tool delegate {"agent":"Forge","task":"…","title":"Fix X","worktree":"fix-x","from":"main"}` for the parameters `/delegate` does not take), `/tools <json>` (several calls in one answer, as a real model makes them: `/tools [{"name":"bash","arguments":{"command":"ls"}},{"name":"read","arguments":{"path":"a.txt"}}]`), `/read <path>`, `/ask <question>`, `/delegate <agent>: <task>`, `/continue <sub-chat>: <task>`, `/ref <path>`, `/code <script>`, `/mcp <tool> <json>`, `/computer <json>` and `/browser <json>` with the matching tool call, which is enough to exercise most of the app without a provider. `/system` answers with parts of the system prompt it was sent: `/system <section> …` with those sections and the names of the tools offered, `/system sizes` with the length in characters of each section and of the tool definitions, `/system history` with one line for each system message in the conversation, saying which sections it set (with their length) or removed and which tools it added or took away. A section with nothing to say holds its place with empty text, which is not sent to the model; `/system sizes` and `/system <section>` leave it out.

## CI

Every pull request, and every push to `main`, runs `.github/workflows/ci.yml`. Four of its checks are required before a pull request can merge: `Engine (type-check and tests)` (`npm run check` and `npm test`) and `App (build)` (the builds and checks above, and `scripts/test-test-copy`), both on macOS, and on Linux `Transcript page (tests)` (the conversation page's tests, the release notes' extraction and the changelog entries) and `Scripts (tests)` (`scripts/test-issue` and `scripts/test-issue-hook`). Linux runners start in seconds; GitHub has fewer macOS runners, and a plan can run only a few macOS jobs at once, so the macOS jobs are where a pull request waits.

- **A pull request that changes only what no macOS job reads skips them.** A first job, `Which jobs the change needs`, lists the files the commit being tested changes from `main`. If they are all in `docs/` or `changelog.d/` (whose entries the Linux job checks), or are `README.md`, `CONTRIBUTING.md`, `CHANGELOG.md`, `SECURITY.md`, `CLAUDE.md`, `app/VERSION` (which it checks is a single version), or the scripts that `Scripts (tests)` checks on Linux (`scripts/issue`, `scripts/issue-hook` and their tests) or that no CI job tests (`scripts/rerun-if-no-runner`, `scripts/auto-merge`), the two macOS jobs are skipped, and a skipped job reports its required check as passed. Anything else runs them, and so does any doubt: they run unless that job says they need not, so they run if it fails. A push to `main` always runs them. If a macOS job starts reading one of those files, take it off the list in `ci.yml`.
- **A job no runner took is run again by itself.** GitHub cancels a job that no runner picked up in time, with the annotation "The job was not acquired by Runner of type hosted even after multiple attempts", and the check counts as failed. `.github/workflows/rerun.yml` runs after CI and after Release, and `scripts/rerun-if-no-runner` runs the failed jobs again, up to the run's fourth attempt, but only when every job that did not pass ended that way: cancelled, never started, with that annotation, in the newest run on its branch. A real failure, a job cancelled for another reason, or one beside it, is left for a person. `scripts/rerun-if-no-runner <run-id> --dry-run` says what it would do with a run. To run a job again yourself: `gh run rerun <run-id> --failed`.

## Working on pi² with pi²

A development build runs its engine from the checkout it was built in. If that is the copy you work in, an engine edit, a branch switch or a `git pull` there changes the code its engine starts next time, and if that code is broken there is no pi² left to fix it with. So:

- Use an installed release as your everyday copy. It carries its own engine and Node, so nothing you change in a checkout reaches it.
- Do the work in git worktrees (a conversation can move into one of its own; see [worktrees.md](worktrees.md)) or in a separate clone, never in the checkout a running development build came from.
- Test in a development build, which shares no conversations, keys, preferences, macOS permissions or login item with the copy you use: it has a bundle id, a data folder and a Keychain service of its own, and never takes the usual ones ([Build and run](#build-and-run)). When several sessions test at once, give each copy a bundle id of its own as well, as `scripts/test-copy start <suffix>` does; its data folder and Keychain service follow from it. [CONTRIBUTING.md](../CONTRIBUTING.md) has the rules for testing safely.

`app/build.sh` deletes and rebuilds the bundle it makes, `app/build/pi² dev.app` (or `app/build/pi².app` for a release build), so before it builds or deletes anything it looks for a running process whose executable is inside that bundle. If it finds one, it names the process and stops: deleting the bundle would pull the files out from under a running app, and the new build would lose the Accessibility and Screen Recording permissions given to the old one. Build in a worktree or clone instead, or quit that copy. `PI2_REPLACE_RUNNING=1 ./app/build.sh` replaces it anyway. A development build also deletes a development build that an older `build.sh` left at `app/build/pi².app`, under the same check, so that nobody tries out a stale build by its old name; a release build there is left alone.

## Layout

See [architecture.md](architecture.md) for how the pieces fit. In short:

- `engine/src` is the engine; `engine/test` its tests.
- `app/Sources/pi2` is the app. `Theme.swift` holds the palette and the shared pieces (tags, buttons, panels); `EngineClient.swift` is the connection to the engine; the rest is one file per area.
- `app/Sources/ComputerKit` is the part of computer use that touches the screen. See [computer-use.md](computer-use.md).
- `app/Web/transcript` is the conversation page the app shows in a web view; `app/Web/test` its tests. See [transcript.md](transcript.md).
- `app/Sources/BrowserKit` is pi²'s own browser: everything that touches a web page. See [browser.md](browser.md).
- `app/Sources/PaneKit` is the tree of panes behind the conversation area and the ready-made layouts; the app's `Workspace.swift` keeps it and draws it.
- `app/Sources/ComposeKit` is what Return does in the fields that send a message (`sendsOnReturn`, used in place of `onSubmit`).

## Conventions

- The engine is the only writer. If the app needs to change something, it asks the engine.
- Secrets go in the Keychain, never in files and never on a command line.
- Say what is and is not tested in the pull request.
