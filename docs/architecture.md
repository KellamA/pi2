# Architecture

pi² is two programs:

```
app/      SwiftUI app: the window, menu bar, Quick Ask, settings
          Sources/pi2           the app
          Sources/ComputerKit   seeing and working other apps' windows
          Sources/pi2-probe     a command-line way to try ComputerKit while developing; not part of the app
engine/   Node + TypeScript process that hosts the pi durable harness
```

The app is a view of the engine's committed state. It keeps no truth of its own: everything on screen is what the engine last said. The engine is the only process that opens the database.

## How they talk

The engine listens on a Unix socket in the data folder (`engine.sock`). Messages are JSON, one object per line.

- The app sends requests: `{"id": 1, "method": "submit", "params": {…}}`. The engine answers `{"id": 1, "result": {…}}` or `{"id": 1, "error": "…"}`.
- The engine sends events without being asked, whenever something changes: `library`, `agents`, `inbox`, `activity`, `schedules`, `recovery`, `usage`, `mcp`, `providers`, `conversation`, `auth`, `computer`.

The app starts the engine if it is not running, and reconnects if it dies. A second engine on the same data folder exits at once.

## The engine

| File | What it holds |
|---|---|
| `src/main.ts` | Startup, the socket server, request handlers, events |
| `src/state.ts` | The app's own documents (conversation index, agents) and the Inbox |
| `src/extensions.ts` | What pi² adds to every conversation: approvals, `ask_user`, `delegate`, `read_reference`, `computer` |
| `src/providers.ts` | Built-in providers, custom endpoints, the scripted demo model |
| `src/credentials.ts` | Keys and sign-ins in the macOS Keychain |
| `src/computer.ts` | Computer use: what is allowed, the link to the app, trimming old screenshots |
| `src/reference.ts` | An agent's reference files |
| `src/schedules.ts` | Schedule rules and next-run times |
| `src/mcp.ts` | MCP servers and their tools |
| `src/backup.ts` | Backup and restore |

Conversations, runs and tool calls are pi durable's. pi² adds a few documents of its own on top: the list of conversations with their titles and settings, the agents, the schedules, and a per-day record of spend.

### Approvals

With tool access set to "Ask first", a hook runs before each tool call that would change something. It puts an item in the Inbox and waits. The wait lives in the running engine; after a restart pi durable runs the hook again, so the question reappears.

### Sub-chats

`delegate` creates a conversation owned by the calling tool call, configured from the other agent's profile, and waits for its answer. The app lists it under its parent. Passing `chat` continues an earlier sub-chat instead of starting a new one.

## Where things live

| What | Where |
|---|---|
| Conversations, agents, schedules, settings | `~/Library/Application Support/pi2` (one SQLite database and a few small files) |
| Keys and sign-ins | The macOS Keychain, service `dev.pi2.credentials` |
| Logs | `engine.log` and `app.log` in the data folder |

A sign-in credential can be several kilobytes, more than one Keychain command can carry, so long ones are split across several items with a checksum. A damaged item reads as "signed out" rather than as an error.

Environment variables the engine reads, mostly for tests: `PI2_HOME` (data folder), `PI2_KEYCHAIN_SERVICE` (Keychain service name), `PI2_DEMO_COST` (a price for the demo model so budgets can be tested), `PI2_DEMO_TEXT_MODEL` (adds a demo model that cannot see images).

## Known limits

- pi durable is marked experimental. The engine pins version 1.5.2 exactly.
- Approvals wait inside the running engine and are asked again after a restart. pi durable ends a waiting call after five crashes in a row.
- Whether a subscription may be used from a third-party app is up to each provider's terms.
- With "Full access", commands run without asking. Tools always work inside the conversation's folder, or the app's own scratch folder when none is chosen.
- A model on a custom endpoint is treated as text-only, so it gets the list of controls in computer use but not the pictures.
- Computer use: a click at a bare point (not on a listed control) is ignored by some apps while they are in the background; the agent is told when nothing changed. Pop-up menus and apps with little accessibility support (some games, some cross-platform apps) may not be workable.
- macOS ties the Accessibility and Screen Recording permissions to the exact build. After rebuilding a development build, remove pi² from those lists in System Settings and grant it again.
- Anything running as you can talk to the engine's socket. With computer use on, that includes asking an agent to use the apps you allowed.
- Builds are not signed with a Developer ID or notarized. The script has a path for it (`SIGN_IDENTITY`, `NOTARY_PROFILE`), which has not been exercised.
- Not built: remote environments over SSH, MCP sign-in (OAuth), per-run budgets, automatic updates, loading very old messages in very long conversations.
