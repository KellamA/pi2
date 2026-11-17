# Changelog

What changed in each version, newest first.

## 0.7.6

### Added
- **Read what a background command prints.** Activity's rows for background commands have an Output button, which opens a window with the command, its conversation, whether it is still running or how it ended, and what it has printed so far, kept up to date as more arrives. You can select and search the text, and stop the command from there. Reading it does not take anything away from what the agent has yet to read.
- **A conversation shows the commands it has running.** Above the message field, a strip names the background commands the conversation and its sub-chats have running, each with how long it has run, Output and Stop. The menu bar's Running list names them too.
- **An agent can put away its finished sub-chats.** An agent that hands out work can list its sub-chats, with whether each is working, waiting on you or idle and which folder and branch it works in, and archive the ones that are finished. It cannot archive one that is working or waiting on you, and nothing is deleted: they are in the Archive, where you can read or restore them. Background commands they left running are stopped first, and the conversation says what was archived.
- **A sub-chat can have a worktree of its own.** When an agent hands work to another, it can ask for a git worktree and branch for the new sub-chat, starting from the commit its own folder is on or from one it names. The sub-chat works there, the receiving agent's set-up command runs first, and the sidebar and Branches show it as the sub-chat's own worktree.
- **Sub-chats have names.** An agent can name a sub-chat as it starts it, so the sidebar, the Archive, the Inbox and search tell them apart. One it gives a worktree and no name is named after the agent and its branch. A name you give a sub-chat yourself is kept.

### Changed
- **Every sub-chat shows its branch in the sidebar.** A sub-chat working in the same checkout as its parent used to show no branch icon. It now shows one, faded, in the colour of how the branch stands; a sub-chat with a worktree of its own, or in another repository, shows it at full strength.
- **When the engine cannot be started, the window says so.** After three starts in a row have failed, a notice at the top of the window says how the last one ended and shows the end of `engine.log`, with what to check, Try Again and a way to find the log. pi² keeps trying on its own, less and less often, and the notice goes as soon as an engine answers. Before, the footer said "Starting engine…" for ever.
- **After an unexpected engine stop, Activity names the commands that were left.** Its notice now lists the background commands and worktree set-up commands the last engine left running, and what became of each: stopped, already over, or left alone because pi² could not be sure it was the same. It no longer says nothing was running when such a command was. When only part of what a command started could be stopped, its line in the conversation says so.

### Fixed
- Closing a pane crashed pi² 0.7.5 whenever the close left a split holding a single pane, which includes closing either pane of two.
- An approval asked again after the engine restarted could come back without its "always allow" choice, and a command a saved rule covers could be asked about anyway. It happened when the last engine had left a background command or a set-up command running.
- An engine told to stop while it was still starting (quitting pi² right after opening it, say) was killed outright, so the next start reported a crash that had not happened and the login shell it was asking for its `PATH` was left running. It now stops cleanly.
- When your login shell took more than five seconds to give its `PATH`, MCP servers started meanwhile kept the stand-in one: a server whose program is only on your `PATH`, such as `npx` or `uvx`, stayed failed until you pressed Reconnect. They are now started again with your `PATH` when it comes, without cutting off a tool call that is running.
- Opening pi² could show "Something went wrong: Unknown conversation" when a pane restored from the saved layout named a conversation the data folder does not have, as after restoring an older backup. The pane is now emptied quietly.

## 0.7.5

### Added
- **Commands left running in the background.** An agent can start a command and carry on while it runs (a development server, a watching build, a test copy of an app), read what it prints later, and stop it. Starting one asks the way any command does under Ask first, says in the approval that it will keep running, and is covered by Always Allow and by command rules. It has no time limit; it runs until it ends, the agent or you stop it, its conversation is archived or deleted, its worktree is removed, or pi² stops. Activity lists what is running, each with a Stop button, and the conversation says when one ends. After a crash, the next engine stops what the last one left running. See [docs/background.md](docs/background.md).
- **A set-up command for new worktrees.** In an agent's settings, under Give each conversation its own worktree, a command such as `npm ci` runs once in each new worktree of that agent's conversations, right after pi² makes it, so what git ignores is put back. The conversation shows it running, then its output and whether it failed; the first answer waits for it, and the agent is told how it went. See [docs/worktrees.md](docs/worktrees.md).

### Changed
- `app/build.sh` stops before building when a copy of pi² is running from the bundle it would replace, and says which process and what to do instead; `PI2_REPLACE_RUNNING=1` replaces it anyway. [docs/development.md](docs/development.md) has a new section, "Working on pi² with pi²".
- **A test copy of pi² can be looked at.** Computer use no longer refuses every app whose bundle id starts with `dev.pi2.app.`: such a copy is look-only, like browsers and System Settings, so an agent working on pi² can check a change by looking at a throwaway build. pi² itself (`dev.pi2.app`) still cannot be given to an agent.
- **Project instructions from the repository's top.** A conversation working in a subfolder of a git repository is now given the `AGENTS.md` or `CLAUDE.md` of each folder from the repository's top down to its own, the top's first, so the nearest has the last word. Nothing above the repository's top is read, and a folder in no repository reads only itself, as before. The 24,000-character cap is shared between the files. See [docs/knowledge.md](docs/knowledge.md).
- **Commands have a time limit.** A command an agent runs is stopped after 30 minutes, so one that never finishes no longer holds the conversation until you stop it. The agent is told the limit, can ask for longer for a command it knows is slow, and is told when the limit stopped one. A command that waits for typed input fails at once instead of waiting.
- **Command rules reach worktrees.** A rule made in a repository's main checkout, or in any worktree pi² made from it, now holds in the same folder of all that repository's pi² worktrees, for the same agent, so a conversation in a new worktree no longer asks for `npm test` again. A rule made in a worktree is kept for the main checkout's folder. Worktrees pi² did not make are not affected. See [docs/rules.md](docs/rules.md).
- **A worktree's set-up command shows its output as it runs**, as a command an agent runs does, rather than only once it ends. A set-up left running by an engine that crashed or was killed is now stopped when the engine starts again, when pi² can tell it is the same process, and the conversation says what happened. A command still running when you open its conversation now shows its newest output, not its first lines. See [docs/worktrees.md](docs/worktrees.md).
- **A sub-chat working in its parent's worktree says so.** Branches lists it under the conversation whose worktree it is, marked "parent's worktree" rather than "worktree"; its tooltip, its toolbar's branch menu and the branch details name that conversation. **New Worktree…** for such a sub-chat says that the new worktree starts from the parent's branch and that the sub-chat stops working in the parent's worktree. See [docs/worktrees.md](docs/worktrees.md).
- **A command's approval says how far its rule reaches.** When the rule it offers also holds in the repository's main checkout and its pi² worktrees, the button reads "Always Allow `npm test` in This Repository" instead of "…Here", in the conversation and in the Inbox, rather than saying so only when hovered. A long command is cut short in the button so the rest of the label still shows. See [docs/rules.md](docs/rules.md).

### Fixed
- An agent's commands could not find programs you installed yourself, such as `node`, `npm` or `gh`: they ran with the bare `PATH` macOS gives an app. The engine now takes its `PATH` from your login shell when it starts, so commands, MCP servers and git find what a terminal window would.
- When your login shell took more than five seconds to give its `PATH`, as it can right after login, the engine stopped it and ran with a few usual folders until its next start, so an agent's commands could fail with "command not found" or find another version of a program, with only a line in `engine.log` to say why. The engine still starts after five seconds with the usual folders, but now lets the shell finish and takes its `PATH` when it answers: commands, git and MCP servers started from then on get it. A command or MCP server already running keeps what it started with; reconnect the server in Settings to give it the new one. A shell that has not answered after five minutes is stopped.
- An agent could not look at a picture larger than 2,000 pixels or 4.5 MB with `read`, such as a screenshot of a window on a Retina display, and could not read BMP at all. `read` now scales such a picture down to fit, converts BMP, and tells the agent the size before and after.
- A conversation working in a worktree that handed work to another agent got a helper working in a different checkout, often the main one. A new sub-chat now starts in the folder its parent works in, worktree included, and is told so, unless the other agent's own folder is in another repository. See [docs/worktrees.md](docs/worktrees.md).
- Computer use compared bundle ids with regard to case, though macOS does not, so an agent given `com.apple.terminal` or `Dev.Pi2.App` could get past the lists that refuse `com.apple.Terminal` and `dev.pi2.app`. Every comparison, in the engine and in the app, now ignores case: the never and look-only lists, the check that a call names an app the agent was given, the app refusing itself, an agent's list of apps, and allowing an app for the rest of a conversation. See [docs/computer-use.md](docs/computer-use.md).
- A copy of pi² on a data folder of its own (`PI2_HOME`), such as a test copy, could turn off the login item and so stop the engine of the copy in real use, or replace it with one that started its own engine on the usual data folder. The login item can now be installed only by a copy on the usual data folder, and replaced or removed only by the copy whose data folder it serves; elsewhere the switch in Settings › General is unavailable and says why.
- A failed set-up command's row put the command first, so with any real command the reason was cut to "exited …", and its opened output was all red, standard output included. It now leads with what happened ("Set-up command failed: exited with code 3") and shortens the command instead, repeats the reason on a line of its own above the output, and shows the output in the ordinary colour. The one-line text other views and the Markdown export use also lead with the reason. See [docs/worktrees.md](docs/worktrees.md).
- Opening pi² with the window split into panes often showed "Something went wrong: The engine is not running yet." although the engine was running: the panes asked for their conversations before the app had connected. A conversation opened before the app connects now waits for the connection and opens then.

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
