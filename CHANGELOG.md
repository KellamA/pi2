# Changelog

What changed in each version, newest first.

## Unreleased

### Changed
- **A test copy of pi² can be looked at.** Computer use no longer refuses every app whose bundle id starts with `dev.pi2.app.`: such a copy is look-only, like browsers and System Settings, so an agent working on pi² can check a change by looking at a throwaway build. pi² itself (`dev.pi2.app`) still cannot be given to an agent.

### Fixed
- An agent's commands could not find programs you installed yourself, such as `node`, `npm` or `gh`: they ran with the bare `PATH` macOS gives an app. The engine now takes its `PATH` from your login shell when it starts, so commands, MCP servers and git find what a terminal window would.

## 0.7.0

### Added
- **Worktrees.** A conversation in a git repository can move into a worktree of its own, on a new branch, so several agents can change one project at once. An agent can be set to start every conversation in one. Removing a worktree takes the conversation back to where it was and keeps a branch with unmerged work. See [docs/worktrees.md](docs/worktrees.md).
- **Branch tracker.** Each conversation working in a git repository shows its branch next to it in the sidebar and in its toolbar: a plain icon for the main checkout, a boxed one for a worktree, coloured by how the branch stands (changes, commits to push or merge, merged, conflicts). Branches in the sidebar lists them all by repository.
- **Worktrees left behind.** Deleting a conversation offers to remove its worktree too, when nothing in it is uncommitted. Branches lists the worktrees of archived and deleted conversations under Left Behind, each with a Remove button.
- **Split panes.** The conversation area splits into up to 16 panes, each with its own conversation. Ready-made layouts (two, three even or one big with two half-size, grids up to four by four) are in the toolbar's Layout button and View › Layout; Split Right (⌘D) and Split Down (⇧⌘D) make any arrangement in between. Dividers drag to any size, and double-clicking one evens it out. The focused pane's conversation is the one the title, toolbar, sidebar and Conversation menu follow; ⌘] and ⌘[ move between panes and ⌃⌘W closes one. A conversation can be dragged in from the sidebar, and the layout is kept between launches.
- **Sub-chats beside their conversation.** A hand-off in the transcript has a Beside button next to Open: it splits the pane and shows the sub-chat next to the conversation that opened it, so you can watch both. A sub-chat already on screen is moved to instead.

### Changed
- **Plan limits stay current.** Opening Usage checks again any signed-in subscription whose figures are more than an hour old, without waiting for Check Now.
- **Model pickers name the provider.** An agent's model picker lists models under their provider, like the chat model menu, and names the provider when closed. Two providers offering a model with the same id no longer get their rows mixed up, and an agent whose model has since been hidden shows it as "(hidden)" instead of a blank picker.

### Fixed
- After saving one of the starter agents, Save and Revert stayed lit and New Conversation stayed off, because saving fills in settings the starters were made without. The agent page now compares an agent as it would be saved.

## 0.6.0

### Added
- **A new transcript.** The conversation is one page in the style of Claude Code: answers as plain text with full Markdown, tool steps as single lines that open to their output or diff, approvals and questions where the agent stopped. A selection runs across prose, code and tool steps and copies as clean text. See [docs/transcript.md](docs/transcript.md).
- **Archive.** A conversation can be archived instead of deleted: it leaves the sidebar with its sub-chats, stays readable and searchable, and can be restored. Conversations left unused for a chosen time can be archived automatically. See [docs/archive.md](docs/archive.md).
- **Downloads and updates.** Release builds are signed, notarized and packaged as a disk image by a workflow that runs on a version tag. A downloaded copy can update itself (Sparkle), only after you agree to checks, and only to updates signed with the project's key. Before an update the engine is stopped cleanly, and the new app replaces an engine left over from the old one. See [docs/releasing.md](docs/releasing.md).
- **Command rules.** An approval for a shell command can allow commands that start the same way from then on, for that agent in that folder. Compound commands, writes to files, variables and anything else not plainly covered still ask, and rules that would allow anything cannot be made. Rules are listed in the agent's settings. See [docs/rules.md](docs/rules.md).
- **Agents can schedule their own work.** Off by default per agent. Each schedule is approved by you before it is made, shows in Activity as set by the agent, and the agent can cancel only its own. See [docs/schedules.md](docs/schedules.md).
- **Formatted documents.** An agent that may write files can write a Word, RTF, OpenDocument or HTML document from Markdown with `write_document`, with the same approval as any other write. See [docs/documents.md](docs/documents.md).
- **Computer use.** An agent can see and work the apps you choose, one window at a time, in the background, asking before it acts. See [docs/computer-use.md](docs/computer-use.md).
- **A browser of the agents' own.** An agent can open pages, search, read, click, type and upload in pi²'s own browser, which keeps its sign-ins apart from Safari and Chrome. You can watch and take over in the Browser window. See [docs/browser.md](docs/browser.md).
- **Plan limits.** For a subscription you are signed in to, Usage shows how much of each of the provider's windows is used (for example 5-hour and weekly) and when it resets, for Anthropic, OpenAI Codex, GitHub Copilot and Kimi. These come from interfaces the providers do not document; see [docs/limits.md](docs/limits.md).
- **Project instructions.** An agent working in a folder that has an `AGENTS.md` or `CLAUDE.md` is given it, read fresh for every message.
- **Memory.** Per agent and off by default: the agent keeps short notes between conversations with `remember` and `forget`, and you can read, edit and delete them in its settings. See [docs/knowledge.md](docs/knowledge.md).
- **Tools for looking around.** `list_files`, `find_files` and `search_files` for any agent that may read its folder, and `web_fetch` and `web_search` for agents with the browser switched on. None of them changes anything or needs approval. See [docs/look.md](docs/look.md).
- **A task list.** For work with several steps an agent keeps a checklist, shown above the message field. It survives restarts and forks. See [docs/plan.md](docs/plan.md).
- **Pictures and files in chats.** Paste, drop or attach pictures, text and code files, PDFs and Word documents. A model on your own endpoint can be marked as able to see pictures. See [docs/attachments.md](docs/attachments.md).
- **Sub-chats.** Each handoff to another agent opens a chat under the conversation that started it. An agent can continue an earlier sub-chat instead of starting a new one.
- **Reference files.** Files and folders an agent can always read, opened on demand.
- **Model picker per provider.** Choose which models show in the menus. Search by name or id, Select All and Deselect All (which act on the search's matches while one is typed), and "Newest Only", which keeps one of each family. A provider may have every model unticked.
- **A new look.** A dark-first palette, with light and match-system in Settings › General.

### Changed
- Delete is now separate from Archive and says what it does: pi² stops showing the conversation and cannot bring it back, and its text stays in pi²'s data file.
- Reference files can be Word, RTF and OpenDocument files; the agent is given their text.
- Usage from a subscription sign-in, or from a local model, counts tokens only. It shows no cost and does not count toward the daily budget.
- Usage names models as "Provider · Model".

### Fixed
- A step you declined read "Ran … Failed" in the conversation. It is now crossed out and marked as declined.
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
