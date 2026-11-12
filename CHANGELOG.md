# Changelog

What changed in each version, newest first.

## 0.6.0

### Added
- **Computer use.** An agent can see and work the apps you choose, one window at a time, in the background, asking before it acts. See [docs/computer-use.md](docs/computer-use.md).
- **Pictures and files in chats.** Paste, drop or attach pictures, text and code files, PDFs and Word documents. A model on your own endpoint can be marked as able to see pictures. See [docs/attachments.md](docs/attachments.md).
- **Sub-chats.** Each handoff to another agent opens a chat under the conversation that started it. An agent can continue an earlier sub-chat instead of starting a new one.
- **Reference files.** Files and folders an agent can always read, opened on demand.
- **Model picker per provider.** Choose which models show in the menus; "Newest Only" keeps one of each family.
- **A new look.** A dark-first palette, with light and match-system in Settings › General.

### Changed
- Reference files can be Word, RTF and OpenDocument files; the agent is given their text.
- Usage from a subscription sign-in, or from a local model, counts tokens only. It shows no cost and does not count toward the daily budget.
- Usage names models as "Provider · Model".

### Fixed
- Switching on hand-offs, reference files, computer use or extra tools for an agent did nothing in conversations it already had. They now pick up the change at their next message, and lose an ability that was switched off.
- The app did not build with Xcode 26 (Swift 6.3).
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
