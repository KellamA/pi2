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

This is a development build. It runs the engine from `engine/` with the Node on your `PATH`, so engine edits take effect the next time the engine starts (**Debug › Kill Engine** restarts it), and the build only works on this machine.

For an app that carries its own Node and engine and can be moved:

```bash
./app/build.sh release
```

To sign and notarize a release build, set `SIGN_IDENTITY` (a Developer ID Application identity) and optionally `NOTARY_PROFILE` (a `notarytool` keychain profile) first. That path is written but has not been exercised.

## Tests

```bash
cd engine && npm test
```

This runs three things in turn: the Keychain store's test, the look tools' test, and the end-to-end test described next.

The test starts a real engine on a throwaway data folder and a throwaway Keychain service and drives it over the socket: chat, pictures and files in messages, tools, approvals, delegation and sub-chats, reference files, computer use and the browser (each with a stand-in for the app), schedules, crash recovery (`kill -9` mid-answer and mid-approval), usage and budget, search, code mode, a test MCP server, a mock OpenAI-compatible endpoint with and without a key, export, backup and restore.

```bash
cd engine && npm run check
```

type-checks the engine.

The part of the app that works web pages is checked by a program of its own, which serves a few pages to itself and loads no real website:

```bash
cd app && swift build --product pi2-browser-probe && .build/debug/pi2-browser-probe
```

With the probe built, `cd engine && npm run test:browser` runs a real engine against it, to check that the two agree. See [browser.md](browser.md).

The rest of the app has no automated tests. To try a change without touching your own data, run a copy on a throwaway folder:

```bash
open -n "app/build/pi².app" --env PI2_HOME=/tmp/pi2-try --env PI2_KEYCHAIN_SERVICE=dev.pi2.credentials.test
```

The scripted demo model answers `/bash <command>`, `/read <path>`, `/ask <question>`, `/delegate <agent>: <task>`, `/continue <sub-chat>: <task>`, `/ref <path>`, `/code <script>`, `/mcp <tool> <json>`, `/computer <json>` and `/browser <json>` with the matching tool call, which is enough to exercise most of the app without a provider.

## Layout

See [architecture.md](architecture.md) for how the pieces fit. In short:

- `engine/src` is the engine; `engine/test` its tests.
- `app/Sources/pi2` is the app. `Theme.swift` holds the palette and the shared pieces (tags, buttons, panels); `EngineClient.swift` is the connection to the engine; the rest is one file per area.
- `app/Sources/ComputerKit` is the part of computer use that touches the screen. See [computer-use.md](computer-use.md).
- `app/Sources/BrowserKit` is pi²'s own browser: everything that touches a web page. See [browser.md](browser.md).

## Conventions

- The engine is the only writer. If the app needs to change something, it asks the engine.
- Secrets go in the Keychain, never in files and never on a command line.
- Say what is and is not tested in the pull request.
