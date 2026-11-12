# Changelog

What changed in each version, newest first.

## 0.6.0

### Added
- **Computer use.** An agent can see and work the apps you choose, one window at a time, in the background, asking before it acts. See [docs/computer-use.md](docs/computer-use.md).
- **Sub-chats.** Each handoff to another agent opens a chat under the conversation that started it. An agent can continue an earlier sub-chat instead of starting a new one.
- **Reference files.** Files and folders an agent can always read, opened on demand.
- **Model picker per provider.** Choose which models show in the menus; "Newest Only" keeps one of each family.
- **A new look.** A dark-first palette, with light and match-system in Settings › General.

### Changed
- Usage from a subscription sign-in, or from a local model, counts tokens only. It shows no cost and does not count toward the daily budget.
- Usage names models as "Provider · Model".

### Fixed
- An endpoint saved without a key, the usual case for Ollama and LM Studio, failed with "No API key for provider".
- Signing in with a subscription could fail with "The stored credential is unreadable": long sign-in credentials were cut off when saved to the Keychain.
- Signing in with ChatGPT failed with "requires a device ID".
- A failed command's output showed internal `<harness>` tags.

## 0.5.0

- First-run welcome, export to Markdown and JSON, backup and restore, the app icon, and a self-contained release build.

## 0.4.0

- Usage and a daily budget, fork, search, the command palette, scripts that call tools, and MCP servers.

## 0.3.0

- Activity, schedules, a report after the engine recovers from a crash, the menu bar icon, and Quick Ask.

## 0.2.0

- Agents, delegation, the Inbox, approvals that survive restarts, and provider sign-in.

## 0.1.0

- Chat with a model through the engine, with tool calls, streaming, and recovery after a crash.
