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

This runs side by side the Keychain store's test, the test that commands keep their output when the engine is busy as they exit and get no input, the test that commands get the login shell's `PATH` (with stand-in shells, and a real engine started with the bare one), the look tools' test, the documents test, the command rules' test (which also runs the commands its rules allow through `/bin/bash`, in a folder of its own), the worktrees test (which makes throwaway git repositories and has an engine make and remove worktrees in them), and the end-to-end test described next.

The test starts a real engine on a throwaway data folder and a throwaway Keychain service and drives it over the socket: chat, pictures and files in messages, tools, approvals, delegation and sub-chats, reference files, computer use and the browser (each with a stand-in for the app), schedules, crash recovery (`kill -9` mid-answer and mid-approval), usage and budget, search, code mode, a test MCP server, a mock OpenAI-compatible endpoint with and without a key, export, backup and restore. It makes the demo model type fast (`PI2_DEMO_TOKENS_PER_SECOND`); a check that needs an answer still on its way, to stop it or kill the engine in the middle of it, sends a message starting with `/slow `, which is answered at the usual pace. `npm run test:engine` runs this test alone.

```bash
cd engine && npm run check
```

type-checks the engine.

The part of the app that works web pages is checked by a program of its own, which serves a few pages to itself and loads no real website:

```bash
cd app && swift build --product pi2-browser-probe && .build/debug/pi2-browser-probe
```

With the probe built, `cd engine && npm run test:browser` runs a real engine against it, to check that the two agree. See [browser.md](browser.md).

The conversation page (`app/Web/transcript`) has tests that run in Node with a small stand-in for the DOM: its Markdown, its tool summaries and what a selection copies, including text written to break out of the page.

```bash
cd app/Web && node --test test/
```

See [transcript.md](transcript.md). The rest of the app has no automated tests. To try a change without touching your own data, run a copy on a throwaway folder:

```bash
open -n "app/build/pi².app" --env PI2_HOME=/tmp/pi2-try --env PI2_KEYCHAIN_SERVICE=dev.pi2.credentials.test
```

A development build (not a release build) also reads two variables that help when taking pictures of the app or checking it by script:

- `PI2_SHOW` chooses what the window opens on: `inbox`, `activity`, `usage`, `archive`, `branches`, `agent:<id>`, or a conversation's number or title.
- `PI2_DRAW_WHEN_HIDDEN=1` keeps the transcript drawing while the window is covered or the screen is locked. WebKit normally stops drawing a page nobody can see, which leaves it blank in a window capture. This uses a WebKit switch that is not public, which is why it is left out of release builds.

The scripted demo model answers `/bash <command>`, `/timeout <seconds> <command>` (bash with a `timeout`), `/read <path>`, `/ask <question>`, `/delegate <agent>: <task>`, `/continue <sub-chat>: <task>`, `/ref <path>`, `/code <script>`, `/mcp <tool> <json>`, `/computer <json>` and `/browser <json>` with the matching tool call, which is enough to exercise most of the app without a provider.

## Layout

See [architecture.md](architecture.md) for how the pieces fit. In short:

- `engine/src` is the engine; `engine/test` its tests.
- `app/Sources/pi2` is the app. `Theme.swift` holds the palette and the shared pieces (tags, buttons, panels); `EngineClient.swift` is the connection to the engine; the rest is one file per area.
- `app/Sources/ComputerKit` is the part of computer use that touches the screen. See [computer-use.md](computer-use.md).
- `app/Web/transcript` is the conversation page the app shows in a web view; `app/Web/test` its tests. See [transcript.md](transcript.md).
- `app/Sources/BrowserKit` is pi²'s own browser: everything that touches a web page. See [browser.md](browser.md).

## Conventions

- The engine is the only writer. If the app needs to change something, it asks the engine.
- Secrets go in the Keychain, never in files and never on a command line.
- Say what is and is not tested in the pull request.
