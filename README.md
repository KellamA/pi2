# pi²

A native macOS app for running AI agents on [pi durable](https://github.com/earendil-works/pi/tree/main/packages/durable). Every model turn, tool call and decision is committed to storage before it is shown, so a crash, a restart or quitting the app does not lose a run.

- **Agents** with their own model, instructions, tools, folder and limits, which can hand work to each other.
- **Any model**: sign in with a subscription, paste an API key, or point at a local or hosted server (Ollama, LM Studio, vLLM, a gateway).
- **Control**: tool access per conversation (off, read, ask first, full), approvals and questions collected in an Inbox.
- **Always on**: schedules, a menu bar icon, Quick Ask (⌃⌥Space), and an engine that can keep running after the app quits.
- **Extras**: MCP servers, scripts that call tools, fork, search, a command palette (⌘K), usage and a daily budget, export and backup.

The original plan and screen mockups are in [PLAN.md](PLAN.md) and [mockups.html](mockups.html).

## How it is put together

```
app/      SwiftUI app (the window, menu bar, Quick Ask, settings)
engine/   Node + TypeScript process that hosts the pi durable harness
```

The app is a view of the engine's committed state. They talk over a Unix socket in the data folder, one JSON object per line: requests from the app, events from the engine. The engine is the only process that opens the database.

| Engine file | What it holds |
|---|---|
| `src/main.ts` | Startup, the socket server, request handlers, events |
| `src/state.ts` | The app's own documents (conversation index, agents) and the Inbox |
| `src/extensions.ts` | Approvals, `ask_user`, `delegate` |
| `src/providers.ts` | Built-in providers, custom endpoints, the scripted demo model |
| `src/credentials.ts` | Keys and sign-ins in the macOS Keychain |
| `src/schedules.ts` | Schedule rules and next-run times |
| `src/mcp.ts` | MCP servers and their tools |
| `src/backup.ts` | Backup and restore |

Data lives in `~/Library/Application Support/pi2` (one SQLite database plus a few settings files). Keys and sign-ins live in the Keychain under the service `dev.pi2.credentials`.

## Build and run

Needs macOS 15 or later, Xcode's command line tools, and Node 26 or later.

```bash
cd engine && npm ci
```

```bash
./app/build.sh
```

```bash
open "app/build/pi².app"
```

That is a development build: it runs the engine from `engine/` with the Node on your `PATH`, so it only works on this machine and engine edits take effect the next time the engine starts.

For an app that carries its own Node and engine and can be moved:

```bash
./app/build.sh release
```

To sign and notarize a release build for someone else, set `SIGN_IDENTITY` (a Developer ID Application identity) and optionally `NOTARY_PROFILE` (a `notarytool` keychain profile) before running it. That path is written but has not been exercised.

## Tests

```bash
cd engine && npm test
```

The test starts a real engine on a throwaway data folder and a throwaway Keychain service and drives it over the socket: chat, tools, approvals, delegation, schedules, crash recovery (`kill -9` mid-answer and mid-approval), usage and budget, search, code mode, a test MCP server, a mock OpenAI-compatible endpoint, export, backup and restore.

```bash
cd engine && npm run check
```

type-checks the engine.

Environment variables the engine reads, mostly for tests: `PI2_HOME` (data folder), `PI2_KEYCHAIN_SERVICE` (Keychain service name), `PI2_DEMO_COST` (a price for the demo model so budgets can be tested).

## Known limits

- pi durable is marked experimental. The engine pins version 1.5.2 exactly.
- Approvals wait inside the running engine and are asked again after a restart. pi durable ends a waiting call after five crashes in a row.
- Whether a subscription may be used from a third-party app is up to each provider's terms.
- With "Full access", commands run without asking. Tools always work inside the conversation's folder, or the app's own scratch folder when none is chosen.
- Not built: remote environments over SSH, MCP sign-in (OAuth), per-run budgets, automatic updates, loading very old messages in very long conversations.
