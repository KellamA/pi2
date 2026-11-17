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
open "app/build/pi².app"
```

`npm ci` also runs `engine/scripts/patch-dependencies.ts`, which fixes bugs in installed dependencies that their own releases do not have yet (each patch says what and why). If a dependency update changes a patched file, the install stops with a message: check whether the fix is still needed, then update or remove its patch.

This is a development build. It runs the engine from `engine/` with the Node on your `PATH`, so engine edits take effect the next time the engine starts (**Debug › Kill Engine** restarts it), and the build only works on this machine.

For an app that carries its own Node and engine and can be moved:

```bash
./app/build.sh release
```

Signed builds, the update feed and the release workflow are described in [releasing.md](releasing.md).

## Tests

```bash
cd engine && npm test
```

This runs side by side the Keychain store's test, the test that commands keep their output when the engine is busy as they exit and get no input, the test that commands get the login shell's `PATH` (with stand-in shells, and a real engine started with the bare one), the test that a login shell too slow for start-up still has its `PATH` taken when it answers (stand-in shells again, and two real engines), the test that MCP servers started before that answer are started again with its `PATH` without cutting off a call (a stand-in shell, a test MCP server and a real engine), the test that reconnecting, editing, removing or switching off an MCP server deals with a call running on it as [architecture.md](architecture.md#an-mcp-server-changed-while-a-call-runs-on-it) says (a test MCP server whose calls answer when the test lets them, and a real engine), the test that an engine told to stop while it is still starting stops cleanly (a real engine held in start-up by a stand-in shell that never answers), the look tools' test, the documents test, the command rules' test (which also runs the commands its rules allow through `/bin/bash`, in a folder of its own), the worktrees test (which makes throwaway git repositories and has an engine make and remove worktrees in them), the background commands' test (which has an engine start, read and stop commands, stops and kills that engine with commands running, and checks that nothing it started is left), and the end-to-end test described next.

The test starts a real engine on a throwaway data folder and a throwaway Keychain service and drives it over the socket: chat, pictures and files in messages, tools, approvals, delegation and sub-chats, reference files, computer use and the browser (each with a stand-in for the app), schedules, crash recovery (`kill -9` mid-answer and mid-approval), usage and budget, search, code mode, a test MCP server, a mock OpenAI-compatible endpoint with and without a key, export, backup and restore. It makes the demo model type fast (`PI2_DEMO_TOKENS_PER_SECOND`); a check that needs an answer still on its way, to stop it or kill the engine in the middle of it, sends a message starting with `/slow `, which is answered at the usual pace. `npm run test:engine` runs this test alone.

Each test removes the folders it makes in the temporary folder, and the Keychain items it makes, when it ends, whether it passed or failed. A test you add should do the same: in a `finally`, or, in a test with no `try` around it, in a `process.on("exit")` handler, which still runs when a failed check ends the process. Several runs of the suite can go at the same time on one Mac (several agents, or two worktrees), so a test checks only what it made itself: it does not count what is in the shared temporary folder (the documents test gives the code it checks a temporary folder of its own), listens on port 0 rather than a fixed one, and keeps Keychain items under a service no other run uses (the end-to-end test's has its process id in it, unless `PI2_TEST_KEYCHAIN_SERVICE` names one). To see what a run leaves behind, give it a temporary folder of its own with a short path (a long one makes the engines' socket paths too long), then list it: only npm's own `node-compile-cache` should be there.

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

No check may depend on how fast the Mac is. With several runs of the suite going at once, an engine can take well over ten seconds to start listening, and anything can take many times longer than on a quiet machine. So a test waits for the thing itself, never for a time, and the limit on a wait (ten minutes, `PATIENT_MS`) is only there so that a hang fails instead of running for ever. A wait the test can tell has failed ends at once: when the engine exits, or the connection to it closes. `engine/test/patience.ts` has this for every test that starts an engine: `listening` connects once the engine listens, `EngineClient` is a connection with requests, events and `until`, and `stop` stops a process and waits for it. A process that only a check should stop (a command's `sleep`, a stand-in shell's program) runs for longer than any wait, so that a wait for it to be stopped cannot be met by its ending by itself. Where a check is about time, it measures what it is about: the processor time the converter took, or the time between a request arriving at a stand-in and the engine giving up on it, rather than the time on the test's clock around them.

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

The conversation page (`app/Web/transcript`) has tests that run in Node with a small stand-in for the DOM: its Markdown, its tool summaries and what a selection copies, including text written to break out of the page.

```bash
cd app/Web && node --test test/
```

See [transcript.md](transcript.md). The rest of the app has no automated tests. To try a change without touching your own data, run a copy on a throwaway folder:

```bash
open -n "app/build/pi².app" --env PI2_HOME=/tmp/pi2-try --env PI2_KEYCHAIN_SERVICE=dev.pi2.credentials.test
```

On a Mac where pi² is in real use, give the copy its own bundle id as well and clean up after it: [Testing safely](../CONTRIBUTING.md#testing-safely) in CONTRIBUTING.md has the steps and the rules.

A development build (not a release build) also reads a few variables that help when taking pictures of the app or checking it by script:

- `PI2_SHOW` chooses what the window opens on: `inbox`, `activity`, `usage`, `archive`, `branches`, `agent:<id>`, or a conversation's number or title. An agent's page is taller than any window, so `agent:<id>#<section>` opens it with one of its sections at the top: `profile`, `model`, `instructions`, `files` (reference files), `memory`, `tools`, `rules` (commands it may run without asking), `extras` (extra tools), `computer`, `browser`, `schedule` or `delegates` (who it can hand work to). A name it does not know opens the page at the top. The last few sections cannot come to the top, since the page ends below them; the page scrolls to its end and they show there. The page settles for a second or two after it opens, so wait a few seconds before capturing it.

  `output:<id>` opens a background command's output window as well, such as `output:bg-1` ([background.md](background.md)), about a second after the app has connected to its engine; the main window opens as it would without `PI2_SHOW`. It is a window of its own, 760 points wide, named after the command.

  `settings` opens the Settings window as well, which is a window of its own, and the main window opens as it would without `PI2_SHOW`. `settings:<tab>` opens it on one of its tabs: `general`, `providers`, `tools` or `storage`; a name it does not know opens General. A tab can be taller than the window, so `settings:<tab>#<section>` opens it with one of that tab's sections at the top: `appearance`, `notifications`, `background` or `updates` on General; `subscriptions`, `endpoints` or `keys` on Providers; `servers` on Tools; `folder` or `backup` on Storage. A section the tab does not have leaves it at the top, and so does one in a tab that already fits the window. Settings opens about a second after the app has connected to its engine, not while the app is launching, and a section takes a few seconds more to settle, so wait before capturing it. In the list of windows it is the one 660 points wide.
- `PI2_DRAW_WHEN_HIDDEN=1` keeps the transcript drawing while the window is covered or the screen is locked. WebKit normally stops drawing a page nobody can see, which leaves it blank in a window capture. This uses a WebKit switch that is not public, which is why it is left out of release builds.
- `PI2_WINDOW_BEHIND=1` keeps the copy's windows behind every other app's windows, from the moment they open: they sit just below ordinary windows (at window level -1, the `kCGWindowLayer` that `CGWindowListCopyWindowInfo` reports), so nothing brings them forward, not a sheet, Settings opening or a click. A window behind others is still drawn, and `screencapture -l` captures it whole; for the transcript, add `PI2_DRAW_WHEN_HIDDEN=1` as for any covered window.
- `PI2_WINDOW_ORIGIN=x,y` opens the main window, Settings, the browser and a background command's output with their top-left corner at that point, in points from the top-left corner of the main screen (the measure of `kCGWindowBounds`). It applies while a window opens, until a second after it shows; one already open can be moved as usual. macOS keeps a window from opening entirely off the screens: it moves it back until a corner of it (about 40 points across) shows, so a point far off to the bottom right, such as `10000,10000`, parks the window in the bottom-right corner with only that corner on screen. A sheet, such as the first-run one a copy on a new data folder shows, brings its window back far enough for the whole sheet to show. A window parked like that is drawn in full, and `screencapture -l` captures all of it.

  Without these, a copy's main window opens in the middle of the main screen at every launch, even launched with `open -g`: SwiftUI centres it, and ignores a frame written into the copy's preferences. A check that launches a copy many times should use both, as the steps in [Testing safely](../CONTRIBUTING.md#testing-safely) do.

To check a page without clicking, launch a throwaway copy with these (`open -n -g … --env PI2_SHOW=agent:<id>#rules --env PI2_DRAW_WHEN_HIDDEN=1 --env PI2_WINDOW_BEHIND=1 --env PI2_WINDOW_ORIGIN=10000,10000`) and capture its window with `screencapture -l <window id>`, taking the id from `CGWindowListCopyWindowInfo` for the copy's process. Check first that screen capture is already allowed (`CGPreflightScreenCaptureAccess()`), since capturing without it makes macOS ask.

The scripted demo model answers `/bash <command>`, `/timeout <seconds> <command>` (bash with a `timeout`), `/background <command>` (bash with `background: true`; see [background.md](background.md)), `/tool <name> <json>` (any tool the conversation has, such as `/tool background {"action":"list"}`, or `/tool delegate {"agent":"Forge","task":"…","title":"Fix X","worktree":"fix-x","from":"main"}` for the parameters `/delegate` does not take), `/read <path>`, `/ask <question>`, `/delegate <agent>: <task>`, `/continue <sub-chat>: <task>`, `/ref <path>`, `/code <script>`, `/mcp <tool> <json>`, `/computer <json>` and `/browser <json>` with the matching tool call, which is enough to exercise most of the app without a provider.

## Working on pi² with pi²

A development build runs its engine from the checkout it was built in. If that is the copy you work in, an engine edit, a branch switch or a `git pull` there changes the code its engine starts next time, and if that code is broken there is no pi² left to fix it with. So:

- Use an installed release as your everyday copy. It carries its own engine and Node, so nothing you change in a checkout reaches it.
- Do the work in git worktrees (a conversation can move into one of its own; see [worktrees.md](worktrees.md)) or in a separate clone, never in the checkout a running development build came from.
- Run a test copy on its own data folder (`PI2_HOME`), Keychain service (`PI2_KEYCHAIN_SERVICE`) and bundle id (change `CFBundleIdentifier` in the copy's `Info.plist`, then sign it again with `codesign --force --sign -`), so it shares no conversations, keys or macOS permissions with the copy you use. [CONTRIBUTING.md](../CONTRIBUTING.md) has the rules for testing safely.

`app/build.sh` deletes and rebuilds `app/build/pi².app`, so before it builds or deletes anything it looks for a running process whose executable is inside that bundle. If it finds one, it names the process and stops: deleting the bundle would pull the files out from under a running app, and the new build would lose the Accessibility and Screen Recording permissions given to the old one. Build in a worktree or clone instead, or quit that copy. `PI2_REPLACE_RUNNING=1 ./app/build.sh` replaces it anyway.

## Layout

See [architecture.md](architecture.md) for how the pieces fit. In short:

- `engine/src` is the engine; `engine/test` its tests.
- `app/Sources/pi2` is the app. `Theme.swift` holds the palette and the shared pieces (tags, buttons, panels); `EngineClient.swift` is the connection to the engine; the rest is one file per area.
- `app/Sources/ComputerKit` is the part of computer use that touches the screen. See [computer-use.md](computer-use.md).
- `app/Web/transcript` is the conversation page the app shows in a web view; `app/Web/test` its tests. See [transcript.md](transcript.md).
- `app/Sources/BrowserKit` is pi²'s own browser: everything that touches a web page. See [browser.md](browser.md).
- `app/Sources/PaneKit` is the tree of panes behind the conversation area and the ready-made layouts; the app's `Workspace.swift` keeps it and draws it.

## Conventions

- The engine is the only writer. If the app needs to change something, it asks the engine.
- Secrets go in the Keychain, never in files and never on a command line.
- Say what is and is not tested in the pull request.
