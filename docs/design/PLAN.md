# pi² — a native Mac app for pi durable agents

Mockups: [mockups.html](mockups.html).

## What pi durable is, and what that means for the app

`@earendil-works/pi-durable` (v1.5.2, MIT, marked experimental) is a TypeScript library, not a server or CLI. It commits conversations, model turns, tool calls and tasks to storage before showing them, so a killed process resumes where it stopped. Model access comes from `@earendil-works/pi-ai`.

Three consequences shape everything:

1. **The app needs an engine process.** The library runs on Node, so the Mac app is a native SwiftUI shell talking to a small bundled Node "engine" that hosts the pi durable Harness.
2. **The engine should outlive the window.** Durability is the point: overnight runs, schedules and approvals must keep working with the app closed. The engine runs as a background login item; the window and menu bar are clients of it.
3. **The UI is a view of committed state.** pi durable exposes everything a UI needs as watchable state (transcript entries, `pi.live`, `pi.inbox`, `pi.usage`, `pi.agent`, the task graph). The app renders that state and never keeps its own copy of the truth.

## Architecture

```
┌────────────────────────── pi².app (Swift / SwiftUI) ────────────────────────────┐
│  Main window · Settings · Menu bar extra · Quick Ask panel · Notifications      │
│  EngineClient: JSON-RPC + streamed state patches over a Unix socket             │
│  Keychain (secrets) · SMAppService (login item) · global hotkey                 │
└───────────────────────────────────┬─────────────────────────────────────────────┘
                                    │  ~/Library/Application Support/pi2/engine.sock
┌───────────────────────────────────┴─────────────────────────────────────────────┐
│  pi2-engine (bundled Node runtime + TypeScript, runs as a LaunchAgent)          │
│  Harness.open(SQLite) · Models (pi-ai providers) · Registry (extensions)        │
│  pi² extensions: agents, subagents, approvals, ask-user, schedules, budgets     │
│  CredentialStore → Keychain (via the app) · NodeExecutionEnv per conversation   │
└─────────────────────────────────────────────────────────────────────────────────┘
        storage: ~/Library/Application Support/pi2/session.sqlite (single writer)
```

- **One writer.** pi durable allows one writing process per storage. The engine is that process; the app never opens the database.
- **Protocol.** Requests (`submit`, `abort`, `configure`, `fork`, `signal`, `login`…) are JSON-RPC. Subscriptions forward pi durable's watch calls — first value, then patch operations — so streaming text and tool output cost a few bytes per update. The app reconnects with the transcript's resume cursor and gets only what it missed.
- **Adapter layer.** The API is experimental and changes between releases. The engine pins exact versions and puts every pi durable call behind one internal module, so an upgrade touches one place and the Swift side never sees library types.
- **Secrets.** API keys and OAuth tokens live in the macOS Keychain. The engine implements pi-ai's `CredentialStore` by asking the app/Keychain; nothing secret is written to the database or to disk in plain text.

## How the requirements map onto pi durable

| You asked for | How it's built |
|---|---|
| Sign in with AI subscriptions | pi-ai's OAuth flows: Claude Pro/Max, ChatGPT Plus/Pro, GitHub Copilot, OpenRouter. The login prompts are bridged to native sheets; tokens refresh automatically. |
| Point it at hosted models | pi-ai `createProvider()` for any OpenAI-compatible or Anthropic-compatible endpoint (Ollama, LM Studio, vLLM, llama.cpp, a company gateway), with model list fetching and per-model compatibility switches. Plus API keys for ~30 built-in providers. |
| Different models for different agents | An agent is a saved profile applied with `conversation.configure()`: model, thinking level, instructions, tools, folder, turn limit, compaction. Subagents get their own model. A routing table sends compaction/titles to cheap or local models. |
| "My own Grok Bot" | A personal multi-agent assistant: named agents, always-on background runs, schedules, a menu bar presence and a global Quick Ask. |

## Feature set (filling in the gaps)

**Conversations**
- Streaming answers, thinking, tool calls as collapsible cards with live output; diffs for edits; images in and out.
- Type while it works: steer the current run or queue a follow-up; see and remove queued items; Stop aborts the whole task tree.
- Fork from any message, reset with a handoff note, manual and automatic compaction with a context meter.
- Failed runs show why (model error, turn limit, interrupted…) with a one-click Continue.
- Infinite transcript via the windowed view: load earlier, fill gaps after reconnect.

**Agents**
- Create, duplicate, import/export; templates (coder, researcher, reviewer, writer, read-only planner).
- Per-agent tools, permissions, folder, limits, spend cap, model routing and fallback model.
- Delegation: agents call other agents as foreground or background subagents; each shows inline and opens as its own conversation.
- After-run automations: run tests if files changed, have another agent review before the answer stands.

**Human in the loop**
- Approval gates on risky tool calls (durable — they sleep on a signal and survive restarts), with Allow once / Always / Deny rules per agent and folder.
- Agents can ask you a question and wait; answers from the Inbox, a notification, or the menu bar.

**Always on**
- Background engine as a login item; menu bar status with running / needs-you / next-up.
- Schedules and reminders as durable sleeping tasks (daily brief, weekly check, one-off).
- Activity view of the live task graph across everything, with a plain-language recovery report after a crash or restart.
- Native notifications with inline actions.

**Tools**
- Built-in file and shell tools, scoped to the conversation's folder.
- Code mode (the model writes scripts that call tools, in a sandbox).
- MCP servers, with large tool sets loaded on demand through tool search.
- Optional remote execution over SSH (pi-env) so an agent can work on another machine.

**Power and polish**
- ⌘K command palette and full-text search across all conversations.
- Global Quick Ask hotkey.
- Usage and cost by model, agent, conversation and day; daily and per-run budgets that pause rather than kill.
- Onboarding that gets you from first launch to first answer in under a minute.
- Settings: providers, models, tools & MCP, permissions, notifications, shortcuts, storage & backup.
- Export a conversation (Markdown/JSON), back up and restore the whole store.
- Light and dark appearance, full keyboard navigation, VoiceOver labels.

## Build plan

| Milestone | Delivers | Proves |
|---|---|---|
| **0 · Spike** | Engine + socket + one streaming chat in a bare SwiftUI window, on SQLite; kill the engine mid-answer and watch it resume. | The bridge and the durability story work end to end. |
| **1 · Core chat** | Sidebar, transcript, tool cards, steer/queue/stop, continue, model picker; providers (API key, OAuth sign-in, custom endpoint) with Keychain. | Usable daily as a single-agent chat app. |
| **2 · Agents** | Agent profiles and editor, per-agent models, subagents, model routing, approvals, ask-user, Inbox, notifications. | The multi-agent, multi-model core. |
| **3 · Always on** | Login-item engine, menu bar, Quick Ask, schedules, Activity view, recovery report. | Runs without the window. |
| **4 · Power** | MCP, code mode, fork/handoff/compaction UI, search, palette, usage & budgets, remote environments. | Feature complete. |
| **5 · Ship** | Onboarding, full settings, export/backup, accessibility pass, app icon, signing + notarization, auto-update. | Feels like a finished product. |

Each milestone ends with a runnable app. Tests: engine unit tests against pi durable's faux provider (no network, deterministic), a crash-and-resume test per durable feature, and SwiftUI view tests against recorded state.

Stack: Swift 6 / SwiftUI with a little AppKit (menu bar, global hotkey, panels), Xcode 27, a bundled Node runtime, TypeScript for the engine. No third-party Swift dependencies planned beyond an auto-updater.

## Risks and how the plan handles them

- **Experimental API.** Pinned versions, one adapter module, an upgrade test suite. Expect occasional engine-side churn.
- **Subscription sign-in terms.** The OAuth flows exist in pi-ai, but each provider decides whether a subscription may be used from third-party apps, and that has changed before. Fine for personal use at your own risk; if you ever distribute the app, API keys and custom endpoints should be the supported path.
- **Bundling Node in a signed Mac app.** Needs hardened-runtime entitlements and notarization of the embedded runtime. Tackled in the spike so it isn't a late surprise.
- **MCP wiring.** Pi 1.0 added MCP and pi durable has the pieces (nested tool calls, deferred tools, tool search), but I have not yet confirmed the exact bridge API. Verified in milestone 4 before committing to the UI.
- **Shell access.** Agents run real commands on your Mac. Defaults: scoped to a chosen folder, risky commands gated, nothing runs unattended without an explicit "always allow".

## Decisions I made that you may want to change

1. **Native SwiftUI + Node engine** rather than Electron/Tauri — you asked for native, and it buys the menu bar, notifications, Keychain and hotkey properly.
2. **General-purpose assistant with strong coding ability**, not a coding-only tool.
3. **Personal use first** (local-only, no accounts, no cloud sync). Distribution is possible later.
4. **Targets the current macOS** (26) to use the newest system look; can go lower if needed.
5. **Dark-first design with a single violet accent**; light mode included.
