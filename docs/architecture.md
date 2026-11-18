# Architecture

pi² is two programs:

```
app/      SwiftUI app: the window, menu bar, Quick Ask, settings
          Sources/pi2           the app
          Sources/ComputerKit   seeing and working other apps' windows
          Sources/BrowserKit    pi²'s own browser: loading web pages, reading them and acting in them
          Sources/pi2-probe     a command-line way to try ComputerKit while developing; not part of the app
          Sources/pi2-browser-probe   checks BrowserKit against pages it serves itself; not part of the app
          Sources/PaneKit       the tree of panes the conversation area is divided into, and the ready-made layouts
          Sources/pi2-layout-check    checks PaneKit, built with optimisation; not part of the app
          Sources/ComposeKit    what Return does in a field that sends a message: send, start a new line, or leave it to an input method
          Sources/pi2-compose-check   checks ComposeKit, with a real text field in a window of its own; not part of the app
          Web/transcript        the conversation page the app shows in a web view; Web/test, its tests
engine/   Node + TypeScript process that hosts the pi durable harness
```

The app is a view of the engine's committed state. It keeps no truth of its own: everything on screen is what the engine last said. The engine is the only process that opens the database.

## How they talk

The engine listens on a Unix socket in the data folder (`engine.sock`). Messages are JSON, one object per line. macOS limits a socket's path to 103 bytes, so when the data folder's path is too long for that (only possible with `PI2_HOME`), the app and the engine both reach the socket through a short link to the data folder in `/tmp/pi2-<uid>/` (`engine/src/socket.ts` and `app/Sources/pi2/EngineSocket.swift` work it out the same way).

- The app sends requests: `{"id": 1, "method": "submit", "params": {…}}`. The engine answers `{"id": 1, "result": {…}}` or `{"id": 1, "error": "…"}`.
- The engine sends events without being asked, whenever something changes: `library`, `agents`, `inbox`, `activity`, `background`, `schedules`, `recovery`, `usage`, `mcp`, `providers`, `conversation`, `auth`, `computer`, `browser`.

The app starts the engine if it is not running, and reconnects if it dies. A second engine on the same data folder exits at once.

If the engine ends before the app can reach it three starts in a row (Node or the engine's files missing, an error as it loads), the window says the engine could not be started, shows the end of `engine.log` and what to check, and offers to try again at once. The app keeps trying on its own, waiting twice as long after each further failure, up to a minute between starts, and the notice goes away as soon as an engine answers.

## The engine

| File | What it holds |
|---|---|
| `src/main.ts` | Startup, the socket server, request handlers, events |
| `src/state.ts` | The app's own documents (conversation index, agents) and the Inbox |
| `src/extensions.ts` | What pi² adds to every conversation: approvals, `ask_user`, `delegate`, `read_reference`, `computer`, `browser` |
| `src/versions.ts` | A chat's versions: Try Again, Edit and the step between them. See [A chat's versions](#a-chats-versions) |
| `src/subchats.ts` | `sub_chats`: an agent lists the sub-chats it opened and archives the finished ones. See [archive.md](archive.md#sub-chats-an-agent-puts-away) |
| `src/providers.ts` | Built-in providers, models added to them by hand (`added-models.json`), custom endpoints, the scripted demo model |
| `src/modellists.ts` | Asking a built-in provider which models a key or sign-in can use; the store of catalogs the library refreshes itself (`model-catalogs.json`) |
| `src/localmodels.ts` | Models on this Mac: downloading the Strata engine and model packs, setting them up, and `local-models.json`, which the part that runs them reads. See [local-models.md](local-models.md) |
| `src/localcatalog.ts` | What can be downloaded for models on this Mac: the pinned engine and the packs, with their checksums and memory figures |
| `src/download.ts` | Downloading one large file that carries on where it stopped and is checked against a checksum known in advance |
| `src/attachments.ts` | Pictures and files sent with a message: their limits, what the model is sent, what the transcript keeps. See [attachments.md](attachments.md) |
| `src/credentials.ts` | Keys and sign-ins in the macOS Keychain |
| `src/computer.ts` | Computer use: what is allowed, the link to the app, trimming old screenshots |
| `src/browser.ts` | The browser: which addresses and uploads are allowed, the link to the app, what the agent is told |
| `src/reference.ts` | An agent's reference files |
| `src/rules.ts` | Rules for the shell commands an agent may run without asking: reading a command line, matching, refusing. See [rules.md](rules.md) |
| `src/features.ts` | The list of features that live in one file each, and what such a file can add |
| `src/builtins.ts` | The built-in tools an agent's settings list, and which of them an agent leaves out, and the chat assistant's fixed set. See [Built-in tools](#built-in-tools) |
| `src/chat.ts` | Chat mode's built-in assistant: its settings, the folder its documents go in, and what it is told. See [chat.md](chat.md) |
| `src/plan.ts` | The agent's task list |
| `src/pictures.ts` | `make_picture`: a picture from one of the person's picture models, offered only while there is one. See [pictures.md](pictures.md) |
| `src/runcode.ts` | `run_code`: a short program run in a sandbox with no tools, files or network. See [code.md](code.md) |
| `src/codemode.ts` | What the model is told about code mode: the `codemode` section and the tool's description. See [codemode.md](codemode.md) |
| `src/archive.ts` | Archiving and deleting conversations, and archiving what has gone unused. See [archive.md](archive.md) |
| `src/knowledge.ts` | A project's instructions file, and an agent's memory |
| `src/coauthor.ts` | The setting that asks agents to end their commit messages with a `Co-authored-by` line naming pi². See [commits.md](commits.md) |
| `src/look.ts` | Listing and searching files, fetching pages and searching the web |
| `src/limits.ts` | A subscription's own usage limits |
| `src/limitwait.ts` | A run refused for a provider's rate limit, or because it is overloaded: how long it waits before it asks again by itself, and what is shown and logged meanwhile. See [limits.md](limits.md#when-a-limit-is-reached) |
| `src/cache.ts` | How long a provider keeps a conversation's prompt cache: the long cache for a conversation that hands out work, a refusal of it, and what `engine.log` says. See [limits.md](limits.md#the-prompt-cache) |
| `src/providererror.ts` | A provider's error as `delegate` and `engine.log` give it: shortened, with keys, account identifiers and request ids taken out |
| `src/schedules.ts` | Schedule rules and next-run times |
| `src/worktrees.ts` | A git worktree per conversation, its agent's set-up command, and the branch tracker. See [worktrees.md](worktrees.md) |
| `src/selfschedule.ts` | Schedules an agent sets for itself, each approved by the person. See [schedules.md](schedules.md) |
| `src/environment.ts` | The environment the engine gives what it starts for an agent: its own, without the `PI2_` variables that configure pi² |
| `src/shellpath.ts` | The `PATH` the engine gives what it starts: asked of the person's login shell once, at start, and taken when it comes if the shell is slow |
| `src/commands.ts` | The shell tool: how long a command may run, the default time limit, and what the model is told about it and about a long output |
| `src/output.ts` | The whole output of a shell command whose result was shortened: the file it is kept in, and how long |
| `src/scratch.ts` | Each conversation's scratch folder: where it is, making it, the line of the system prompt that names it, and removing it with the conversation. See [A scratch folder](#a-scratch-folder) |
| `src/running.ts` | When each shell command running in the foreground started and last printed, for the clocks on its row and in Activity |
| `src/order.ts` | Which calls of one answer run one at a time, in order, and what the model is told about it |
| `src/reading.ts` | `read` of several files, or several ranges of one, in one call. See [Reading files](#reading-files) |
| `src/background.ts` | Commands an agent leaves running in the background: starting, reading their output, stopping, and what happens to them when a conversation is put away or the engine stops. See [background.md](background.md) |
| `src/processes.ts` | The processes of set-up and background commands: reading `ps`, the run's marker, and stopping only what is provably left over from an engine that died |
| `src/mcp.ts` | MCP servers and their tools. See [mcp.md](mcp.md) |
| `src/backup.ts` | Backup and restore |
| `src/log.ts` | The time at the start of each line of `engine.log`. See [The logs](#the-logs) |

Conversations, runs and tool calls are pi durable's. pi² adds a few documents of its own on top: the list of conversations with their titles and settings, the agents, the schedules, and a per-day record of spend.

### Agent settings

`agents.save { agent }` creates or edits a saved setup. `agents.duplicate { id }` copies one in the engine and returns the new `{ id }`; the app opens its settings. Both use the same validation and defaults, including checking the folder, reference files, worktree setting, computer use and browser. New names and ids are allocated in the commit, so simultaneous duplicates remain distinct. Each copy's id includes a fresh UUID: a deleted copy's conversations, schedules and worktrees must never be inherited by another copy with the same name. The name is `<name> copy`, then `<name> copy 2`, and so on, ignoring case when checking what is taken.

Duplication copies the whole saved profile through that shared path, including command rules from the stored original (never from the app). It does not copy conversations, schedules or worktrees, or add the copy to any other agent's `delegates`. The settings page explains how to enable incoming handoffs. Built-in agents have no special status in the copy. Features with person-set settings outside the profile can copy those through `agentDuplicated`; memory uses it to copy only its on/off switch, with no notes ([knowledge.md](knowledge.md)), and the agent's own variables to copy their names without their values ([An agent's own variables](#an-agents-own-variables)). The settings action is unavailable while there are unsaved edits: Save or Revert first.

### Built-in tools

Every conversation with tools used to be offered the same few tools whatever its agent was for, and every tool's definition, with the section of the system prompt that goes with it, is read again on every turn (#177, #221). An agent's settings list them under **Built-in tools**, each with a line saying what it is for, and the person can leave any of them out:

| Entry | Tools | Offered at all when |
|---|---|---|
| List, find and search files | `list_files`, `find_files`, `search_files` | tool access is not off |
| Write documents | `write_document` | Ask first or Full access |
| Ask you questions | `ask_user` | always |
| Keep a task list | `update_plan` | always |
| Read the web | `web_fetch`, `web_search` | the browser is on |
| Make pictures (off by default) | `make_picture` | one of the person's providers has a picture model |
| Work things out with code (off by default) | `run_code` | always |

- **Only tools no other switch governs.** The shell and the file tools, and `background`, which works the shell's background commands, follow the access level. Computer use, the browser, scheduling, code mode, memory, reference files and handing work on keep their own switches and are not listed twice. Reading the web still needs the browser on: the list can take it away, never give it to an agent without the browser.
- **On by default, but for a few.** The agent keeps the keys of the ones left out, `toolsOff` (`src/builtins.ts`), so an agent saved before the list, or a tool added to it later, is offered as before. A tool added for some agents only, such as those of the chat assistant (#286), is marked `offByDefault` instead, and the agent keeps the keys of those it is given, `toolsOn`: no existing agent is offered it, or pays for it in its prompt, until the person turns it on. `agents.save` refuses a key it does not know, and one in the wrong list; `agents.duplicate` copies both lists, as it copies every saved setting.
- **Withheld while it could do nothing.** Make pictures is offered, to an agent that turned it on and to a chat alike, only while one of the person's providers has a picture model (a feature's `withheld`, which `toolsFor` and a chat's tools both leave out). Its line in the settings says why it is not offered, and the conversation's `pictures` section tells the model ([pictures.md](pictures.md)).
- **None is forced on.** Where leaving one out has a consequence the person might not expect, its line says so: without asking, an agent that needs a decision can only stop; without the task list, the person sees no plan.
- **Gone everywhere.** `toolsFor` in `main.ts` drops them last, after everything else has decided what is offered, so a sub-chat follows its own agent's list, and code mode's listing and `ALL_TOOLS` lack them: a script calling one finds it does not exist. A tool that is not offered is never called, so it is never asked about either. The section of the system prompt that goes with a tool goes with it (`documents`, `look_web`, `update_plan`'s part of `task_list`); the sentence about sending calls together stays in `task_list` without the task list.
- **From the next message.** An existing conversation is changed at its next message, as for any switch: the tools that went are taken away, and the sections that changed are sent alone ([The system prompt's sections](#the-system-prompts-sections)).

The engine sends the list, with each entry's title, line and what it needs, in the `agents` event (`builtInTools`), so the app has no copy of it.

Chat mode's assistant is offered the entries `CHAT_TOOLS` names, and nothing else, whatever any agent's settings say ([chat.md](chat.md#the-assistant)).

### Approvals

With tool access set to "Ask first", a hook runs before each tool call that would change something. It puts an item in the Inbox and waits. Every approval, of any kind, goes through `Inbox.ask` (`src/state.ts`), which answers it at once, without showing it, for a conversation whose agent had [Allow everything](allow-everything.md) on at its latest message. The wait lives in the running engine; after a restart pi durable runs the hook again, so the question reappears. A shell command that the agent's own rules cover for the conversation's folder runs without asking; see [rules.md](rules.md). The hook decides nothing until the engine has loaded its conversations, its agents and its `PATH` (`Host.ready`): the last engine's work can be set going before then, by a feature writing into a transcript as it starts, and a call judged against agents not yet loaded would be asked about without its rule, or asked about although a rule covers it.

### Sub-chats

`delegate` creates a conversation owned by the calling tool call, configured from the other agent's profile, and waits for its answer. It works in its parent's folder unless the other agent has a folder of its own outside the parent's repository, or the call passes `worktree`, which gives it a worktree of its own made as New Worktree… makes one ([worktrees.md](worktrees.md#sub-chats)); without full access that asks the person first, unless the other agent gets worktrees anyway. The app lists it under its parent, by the `title` the calling agent gave it (80 characters at most), or else as the agent's name and the first words of the task, or the worktree's branch when it has one. Passing `chat` continues an earlier sub-chat instead of starting a new one, and restores it first if the agent had archived it; a `title` passed with it renames it, unless the person renamed it themselves. A conversation that can delegate also gets `sub_chats`, to list its sub-chats with how each stands and archive the finished ones ([archive.md](archive.md#sub-chats-an-agent-puts-away)).

A sub-chat is given its agent's tools, as a conversation of that agent's would be, less what only makes sense in a conversation of its own (`toolsFor` in `main.ts`, and a feature's `toolNames`, which is told whether it is for a sub-chat): handing work on (`delegate`, `sub_chats`) and scheduling its own work ([schedules.md](schedules.md#turning-it-on)). It keeps `ask_user`, unless its agent's settings leave it out: a sub-chat that needs the person shows as waiting on them. A sub-chat follows its own agent's list of [built-in tools](#built-in-tools), not that of the agent that handed it the work. What a sub-chat is offered follows its agent's settings at each message, as for any conversation.

A sub-chat whose run ends without an answer is kept as it stopped, and `delegate`'s result says why and how to carry on: "Scout did not finish the task: the model's provider answered with an error: “429 rate_limit_error: This request would exceed your account's rate limit. …” The sub-chat is kept as it stopped: to carry on from there, call delegate again with chat: 12." The provider's message is shortened to 300 characters, with keys, account and organisation identifiers, request ids and email addresses taken out (`src/providererror.ts`). A refusal for the provider's limit is waited for before it gets that far ([limits.md](limits.md#when-a-limit-is-reached)); when the run ends on one all the same, the result says that carrying on works once the limit has reset.

When a window of the subscription a sub-chat ran on is 80% used or more, `delegate`'s result ends with a line saying so, and `sub_chats`' list ends with how every signed-in subscription's windows stand and which of the agents run on each, so an agent that hands out work can start fewer sub-chats on one nearly used up ([limits.md](limits.md#telling-an-agent-that-hands-out-work-and-the-person)).

### A chat's versions

In a chat, Try Again answers a message again and Edit sends one of the person's messages again with new words, each as a new version that keeps the earlier one; a small control under the message or the answer steps between the versions at that point, and the conversation below follows the version shown (#285; the page's side is in [transcript.md](transcript.md#a-chats-controls)). Only for chats ([chat.md](chat.md)): an agent's conversation may have changed files that going back would not undo, so the engine refuses the requests for one, and its state has no versions.

- **A version is a fork.** pi durable's `conversation.fork(at)` makes a conversation that sees another up to an entry, compactions and all, with the agent (`pi.agent`) and code mode's store as they were there (both are rewindable documents that a fork takes as of its entry), a usage count of its own that starts at nothing, and a provider session of its own. That is what a version needs, so every version after the first is one, made from the conversation that owns the entry, so that the versions at a point are that conversation's own continuation and the forks made there, oldest first. Edit forks at the entry before the message; editing the first message, which has none, starts a new conversation with a copy of the version's `pi.agent`. A new version starts with the settings of the one shown (model, thinking, tools), or the model chosen for Try Again. Entry `head`s, which only move a context's start forward, and `edits`, which omit or replace earlier entries, were the other way to do it; neither makes a tree, and a version going back past a compaction could not be said with them.
- **One id.** A version is a conversation the app never sees by its own id. Its record in the library has the chat as its `parent`, as a sub-chat's does, so the chat's busy state, usage, archiving and deleting take its versions with it, and `version: true`, which keeps it out of the sidebar, the Archive, search, `sub_chats` and the reasons for the long prompt cache. A session document, `pi2.versions` (`src/versions.ts`), keeps which version each chat shows and how its versions part. Every request the app makes with the chat's id (`submit`, `abort`, `continue`, `configure`, `conversation.image`, `export`, `fork`, search) acts on the version shown, and the `conversation` event for the chat follows it: when another version is shown, it starts over with that version's entries (`reset`). Activity and the Inbox name a version's work by the chat.
- **Requests.** `conversation.retry { id, entryId, model? }` answers again the person's message at or before `entryId` (an answer, or the message): a new version forked at the message, then a continue. A message whose answer left nothing at all (it failed before a word was kept) is answered in place instead. `conversation.edit { id, entryId, text }` sends the message again with `text`, keeping what it had attached. `conversation.version { id, after, index }` shows version `index` at the point after entry `after` (null: before the first message): of that version, the one under it shown last, so the conversation below is as it was left. Each answers `{ id, version }`. The conversation's state has `versions`, the points on the path shown where there is more than one (`{ after, index, count }`), or null where versions are not offered, and `chat`.
- **What going back takes with it: nothing.** A version that is no longer shown keeps what it made: a document or a picture stays where it was written (every version of a chat writes in the chat's own folder, `chats/<id>`), and its rows still show it when stepped back to. What it spent stays counted, in Usage under the chat and towards the day's budget. Try Again and Edit stop an answer being written first, as Stop does, and it stays in its version as it stopped; stepping to another version is refused while an answer is being written.
- **Sources.** `web_fetch`'s result names the page it read in its `details` (`source: { url, title }`, the address after redirects), and the page names those under the answer. A page a search only listed is not a source: the model saw a line about it, not the page.

### What commands can find

The app or the login item starts the engine, so it begins with the `PATH` macOS gives every program: `/usr/bin:/bin:/usr/sbin:/sbin`. Programs the person installed themselves (with Homebrew, a version manager, or into `~/.local/bin`) are not on it. As it starts, the engine asks the person's login shell for its `PATH`, the way a new terminal window would have it (`zsh`, `bash` or `fish`, run as a login and interactive shell), and takes that as its own, keeping its own folders after it. Shell commands, MCP servers started as programs, and git all inherit it. Only full paths are kept, so an entry that means "the current folder" never lets a file in a project stand in for a program. It takes the shell's `SSH_AUTH_SOCK` in the same answer, and nothing else from the shell ([What an agent's commands get](#what-an-agents-commands-get)).

A shell that fails, or is one the engine does not know how to ask, is left alone; the engine then adds `/opt/homebrew/bin`, `/opt/homebrew/sbin`, `/usr/local/bin` and `~/.local/bin`, where they exist. `engine.log` says which happened. A change to the shell's profile counts from the next time the engine starts.

Start-up waits five seconds for the shell's answer and no longer, since the app is waiting for the engine. A shell can take longer than that, most of all right after login, when the login item starts the engine and the Mac is at its busiest. Such a shell is not stopped: the engine adds the same usual folders for the time being, finishes starting, and keeps listening. When the shell answers, the engine's `PATH` becomes exactly what an answer in time would have made it: the shell's folders, then the ones the engine began with. The usual folders the shell does not name itself are dropped again, so a slow start and a quick one end with the same `PATH`.

Whatever is started after that gets the shell's `PATH`, because each of these reads the engine's `PATH` at the moment it starts something: an agent's shell commands, git, a worktree's set-up command, and an MCP server that is connected or reconnected. A command that was started before keeps the `PATH` it was started with until it ends.

MCP servers run as programs are connected as the engine starts listening, so on such a start they get the usual folders. When the shell's `PATH` is taken, each one that was started with another `PATH` is started again with it, without anyone pressing Reconnect (`McpServers.followPath` in `src/mcp.ts`):

- One that failed to start, as one whose program (`npx`, `uvx`, a `node` from a version manager) is only on the shell's `PATH` does, is connected again at once. Nothing was using it. A conversation is given its tools at its next message, as after any reconnect.
- One that is connected is started again beside the one running, and takes its place only once it has connected and listed its tools. Its tools never drop out of what conversations are offered meanwhile, so a conversation in the middle of an answer carries on. A call already running on the old process finishes there; the old process is closed once no call is left on it, or after ten minutes at most (see [below](#an-mcp-server-changed-while-a-call-runs-on-it)). A call that was resolved before the swap but runs after it (one waiting for an approval, say) goes to the new process. If the server will not start with the new `PATH`, the one running is kept, and `engine.log` says so.
- One still connecting is looked at again once it has connected or failed.

A server started with the `PATH` the engine has by then (one connected after the answer, or a `PATH` the answer did not change) is left alone, and so are servers reached over HTTP. `engine.log` has a line for each server started again.

Everything else in what these get is the engine's own environment too, read as each is started, less the variables that configure pi² itself: every name that starts with `PI2_` (`src/environment.ts`, #195). The engine is started with `PI2_HOME` naming its data folder, and `PI2_KEYCHAIN_SERVICE` when its Keychain service is not the usual one. Passed on, they would give a command that starts pi² or an engine without setting them itself (a release build of a test copy, `node engine/src/main.ts`) this copy's data folder and sign-ins. The other `PI2_` variables are settings for the copy that was given them, such as the demo model's speed, the login shell to ask, or what a development build's window opens on, and a copy a command starts should not take them unasked either. The one passed on is `PI2_RUN`, the marker of a command's run: an engine started by such a command has it, and what that engine starts must carry it, so that the engine that started the command can still find those processes after a crash ([background.md](background.md)). A shell, background or set-up command gets a marker of its own in its place, so in practice only an MCP server carries it on. A development build still refuses the usual data folder and Keychain service whatever its environment says ([development.md](development.md#build-and-run)), which also covers one started from a terminal where they are set.

A shell that has still not answered five minutes after it was asked is stopped, with whatever its profile started, and the `PATH` stays as it is. Five minutes is far longer than a shell that is merely slow has been seen to take, so one still going then is waiting for something that will not come. A shell still going when the engine stops is stopped with it, and neither the shell nor the five minutes keeps the engine from stopping. That holds while the engine is still starting too: told to stop then (the app quitting, say), it stops the shell instead of waiting for it, lets the rest of start-up finish, and stops cleanly without listening, so the next start does not take it for a crash. Only a shell that is still running is ever stopped: once it has ended, what it printed is its answer, and anything its profile left running is left alone, since the shell's process number may by then belong to another program. `engine.log` has a line when the wait runs out, and another when the shell's `PATH` is taken or when it is given up on, without the shell's folders.

### Whose macOS permissions commands have

macOS decides whether a program may read the screen, use Accessibility and the like by its *responsible* process, the app a person would say started it, not by the program itself. A command an agent runs shares the engine's responsible process, so it acts under whatever permissions that process has (#95). The privacy log names it for each check: `log stream --info --predicate 'subsystem == "com.apple.TCC"'` shows the `responsible` and `requesting` processes and the `subject` whose permission was looked up.

The engine is always its own responsible process, whatever started it (#263):

- **The login item**: launchd starts the Node inside the bundle directly, after login and whenever the app starts the engine while the login item is on.
- **The app**: it starts the engine with its responsibility for it disclaimed (`EngineSpawn.swift`, through libSystem's `responsibility_spawnattrs_setdisclaim`, as Terminal does for its shells), and the same for the late start after an update. The engine is still the app's child, in a process group of its own, so finding it, stopping it and replacing it work as before. `app/check-release-build.mts --open-app`, which CI runs on a release build of every change, fails if macOS holds anything but the engine itself responsible for it. If a macOS ever lacks the call, the app starts the engine anyway and says so in `app.log`.

Until #263, the app was responsible for an engine it started itself, so an agent's commands had all of the app's permissions, Accessibility included: a command could drive any app, around computer use's list of apps and its approvals. Computer use itself does not need the engine to have any permission: the app does the seeing and clicking, under its own ([computer-use.md](computer-use.md#how-it-works)).

What an engine responsible for itself has depends on where its Node is:

- **A release build**: the Node inside the bundle. For Screen Recording, macOS traces it back to the app it lies in, which is signed by the same team, and looks up pi²: pi²'s Screen Recording covers an agent's commands. For Accessibility it does not: it looks up the Node by its path, which nobody has granted, so an agent's commands do not have pi²'s Accessibility. Other permissions were not checked.
- **A development build or a throwaway copy**: the Node on `PATH`, outside the bundle, which macOS cannot trace back to the app. Both permissions are looked up by the Node's path, so an agent's commands have neither the build's Screen Recording nor its Accessibility, and a prompt from one would name `node` ([development.md](development.md#build-and-run)).

So in a release build, an agent's command that captures the screen, such as `screencapture`, works if and only if pi² itself has Screen Recording (System Settings › Privacy & Security › Screen & System Audio Recording); in a development build or a copy, it never does. Without it the command fails (`screencapture` exits 1 with "could not create image from display" and writes no file), and the first time (seen in #47, in a copy), macOS puts a prompt naming the app on the person's screen and adds the app to the list, switched off; later tries fail with no prompt. Granting it to pi² for computer use's pictures grants it to every command an agent runs too, including one that runs without asking (Full access, or a rule), with none of computer use's limits on which apps it sees ([computer-use.md](computer-use.md#commands-an-agent-runs)). To check without a prompt, ask from the same shell: `swift -e 'import CoreGraphics; print(CGPreflightScreenCaptureAccess())'`.

Seen on macOS 27.2: from an installed release's engine started by the login item (#95), `CGPreflightScreenCaptureAccess()` true and `AXIsProcessTrusted()` false, the log showing the subject `dev.pi2.app` for the first and the Node's path for the second, and a one-pixel `screencapture` working. A prompt in that case was not seen, since pi² had the permission; by the subject, it would name pi². From a throwaway copy's engine before #263, both false with the copy's bundle id as the subject of each; after it (#263), both false with the Node's path as the subject of each, and the engine its own responsible process. No capture was tried from a copy.

### How long a command may run

A shell command has 2 minutes unless the call that runs it passes a `timeout` in seconds, which can give it up to 10 minutes; a call that asks for more gets 10 minutes. These are Claude Code's limits for its Bash tool (its `BASH_DEFAULT_TIMEOUT_MS` and `BASH_MAX_TIMEOUT_MS`). A command that may take longer than that, such as a full test suite on a busy Mac, runs with `background: true`, where the agent and the person can see it is still going. pi durable's `bash` has no default of its own, so `src/commands.ts` wraps it to add one.

At its limit, as in Claude Code, a command is moved to the background rather than stopped, and goes on there as a background command with an id, so the time it ran is not lost. Only where starting the same command in the background would not have asked the person (Full access, Always Allow bash Here, or a command rule that covers it), and not for a command that starts with `sleep`; otherwise it is stopped. The result says it did not complete within its limit and was moved to the background, with its id, what it had printed and how to read and stop it. [background.md](background.md#a-command-moved-there-at-its-time-limit) has the details. A worktree's set-up command keeps its own limit.

The tool's description gives both limits, and says that a command is moved at its limit. A command the limit stopped has, under what it had printed by then, a line saying which limit stopped it (the default, the call's own `timeout`, or the most, with what the call asked for), and what to do instead: a larger `timeout`, or `background: true`. One that was not moved because starting it in the background would ask says that too. When it had printed nothing at all, or nothing for the last minute or more, in a run of a minute or more, the line says so, and that a command that goes quiet that long may be waiting on something, such as a permission prompt on the person's screen, and may wait again if it is run again. A command that ends by itself after a minute or more says how long it took, and how long it went without printing anything when that was a minute or more.

The default was 30 minutes until #160, in which a command waiting on a system prompt that nobody had seen (by the timing, a macOS privacy prompt) held its conversation for 29 minutes with nothing to show for it. A worktree's set-up command is not an agent's command and keeps its own limit of 15 minutes ([worktrees.md](worktrees.md)).

### A running command's clock

A command that is stuck (on a privacy prompt, a network folder, a lock) would otherwise look like one that is busy: a spinner and "Running…" (#196). So the person sees how long each command running in the foreground has been going and, once it has printed nothing for 30 seconds, how long it has been quiet: on its row in the conversation ("1m 12s · quiet for 45s") and under its run in Activity. Quiet is shown only after 30 seconds, so a busy command's row does not flicker.

pi durable's live document says which calls are running, not since when, so the shell tool notes it as it runs a command, after any approval (`src/running.ts`, in memory only). The engine adds `startedAt` and `lastOutputAt` (ms since 1970; `lastOutputAt` is null until the command prints) to each such call in the conversation state's `tools`, and a `commands` list (`callId`, `command`, `startedAt`, `lastOutputAt`, oldest first) to each run in the `activity` event. It sends the conversation's state again when a command starts or ends, and the `activity` event then too, and while a command prints, at most every five seconds; its output reaches the conversation on its own. The page and the app tick the clocks themselves, once a second, from those times, so nothing is sent each second. A command started with `background: true`, or moved to the background at its time limit, has its own row in Activity ([background.md](background.md)) and no clock here; a command a code mode script runs is listed under its run in Activity but has no row of its own in the conversation.

### A command's exit code

A command that ran to its end is not an error because its exit code is not 0 (#182). A command line's exit code is that of its last command, and that is often no failure at all: a `grep` that found nothing, `gh pr checks` with checks still pending, `a && b` stopping where it was meant to. So the result tells the model the code as a fact, under the output (`[info] Exit code 1`), and its `details.exitCode` lets the conversation show it on the row, which stays closed, in a quiet colour ([transcript.md](transcript.md#how-it-is-drawn)). A result is still an error, with a red row that starts open, when the command:

- was stopped at its time limit, or stopped or aborted (it has no exit code: the call throws, as above);
- could not be started: exit code 127 ("a command it ran was not found") or 126 ("could not be run (it is not executable, or not allowed)");
- was ended by a signal: 128 and the signal's number, as the shell and pi durable report it ("The command was ended by SIGKILL (exit code 137)."), with the signal's name in `details.signal`.

`exitResult` in `src/commands.ts` decides. Nothing else reads a shell result's error flag to decide what to do: Activity, notifications and the Inbox go by runs and approvals, not by tool results; a Markdown export says "Result:" rather than "Result (error):" for these. A script in code mode gets `{ output, exitCode, … }` from `tools.bash()` for any command that ran to its end, failure or not, as before; it rejects only when the command was stopped, aborted or could not be run at all ([codemode.md](codemode.md)). Results stored before this change keep the error they were given.

A command the agent starts with `background: true` is not waited for and has no limit unless its call gives one: it is left running, and the agent reads its output and stops it with the `background` tool. See [background.md](background.md).

### A long output

A command's result shows the end of its output only: the last 2000 lines or 50 KB, whichever is less, as pi durable's `bash` keeps it. When that leaves some of the output out, the whole output is kept in a file, and the result says so under the output, in a line such as "The output is 4,812 lines long; only the last 2,000 are shown. All of it is in `…/output/12/toolu_….log`, for 7 days: read it with `read` (`offset`, `limit`) or search it with `grep`, rather than running the command again." The tool's description says the same, and tells the agent not to cut an output short itself with `head`, `tail` or `grep`: what it cuts is not kept, and getting it back means running the command again (#161). An output shown whole keeps no file.

The files are only text a program printed. They live in the data folder, in `output/<conversation>/`, one per call, named after the call's id, readable by the person's user only; never in the conversation's folder, which may be a project's. A conversation keeps the files of its last 50 shortened commands, each for 7 days at most, and a file holds at most the first 64 MB of an output (the result says so when it holds less). A deleted conversation's folder is removed. The engine tidies them as it starts, whenever conversations are archived or deleted, whenever a conversation keeps a new one, and once a day. They are not part of a backup.

`src/commands.ts` runs the command itself rather than through pi durable's `bash`, the same way but without that tool's own file of the output, which goes to the system's temporary folder and is never removed. A script in code mode that calls `bash` gets the file's path as `fullOutputPath`, as before.

A command's standard input is `/dev/null`, as pi durable starts it, so a command that asks a question (a password, "are you sure?") gets no answer and fails at once instead of waiting for one. `engine/test/exec.ts` checks it stays that way.

### A scratch folder

Each conversation has a scratch folder of its own for temporary files, outside its working folder, which may be a project's (#180). Every command it runs, in the foreground or the background, and its worktree's set-up command get its path in `PI2_SCRATCH`, and the system prompt names it in one line, in a `scratch` section that is there whenever the conversation can run commands, so it does not come and go during a conversation. What one command leaves there the next finds. A sub-chat is a conversation of its own and has its own. An MCP server, which no one conversation has, gets none.

It is `/tmp/pi2-<uid>/scratch-<hash>/<conversation>`, where the hash is the first 8 hex digits of the SHA-256 of the data folder's path, so that copies of pi² on other data folders (a development build, a test's engine) never share one:

- **Short, with no spaces.** The data folder's path has a space in it ("Application Support"), and a command that puts a socket in a temporary folder, as the engine's tests do, has 103 bytes for the socket's whole path. The scratch folder's path is about 32 bytes; the system's per-user temporary folder (`/var/folders/…/T/`) is about 49 before anything is added.
- **Private.** `/tmp/pi2-<uid>` is the folder the socket's short links are in too ([How they talk](#how-they-talk)). It is made with mode 0700 and checked to be a folder of this user's that nobody else can open, and so is each scratch folder in it, so no other user's process can put files in it or point it elsewhere. If another user made `/tmp/pi2-<uid>` first, no scratch folder is made, commands run without `PI2_SCRATCH`, and `engine.log` says why.
- **Not in backups.** pi²'s backup copies only the data folder, and Time Machine leaves out `/private/tmp`.
- **Temporary.** It is made when first needed, as a command of the conversation starts, and removed when the conversation is deleted, or the conversation it is a sub-chat of. An archived conversation keeps it, since it can be restored and continued where it stopped. macOS removes files in `/tmp` that have not been used for three days, so an unused folder does not stay for long either way; one that macOS took away is made again for the next command. The engine looks for folders to remove as it starts, whenever conversations are archived or deleted, and once a day, as it does for kept outputs. There is no limit on its size: it is for temporary files, not for keeping anything.

Commands keep the system's `TMPDIR`; it is not pointed at the scratch folder (#228). Programs use the temporary folder for more than throwaway files, and some of that only works when every process of the user shares one. Swift Package Manager keeps its lock files there, both for the caches every build of the user shares (`~/.swiftpm`, `~/Library/Caches/org.swift.swiftpm`) and for a checkout's `.build` folder: with a `TMPDIR` for each conversation, two agents building at once, or an agent and the person in a terminal, would each lock a file of their own and no longer keep off each other. Caches kept there (Node's compile cache, Jest's) would be made again in each conversation and lost with it, and a program that finds another through a socket there (an Emacs server) would not find it. So the scratch folder is offered rather than imposed: the system prompt names it, and a command that wants a program's temporary files there says so, as in `TMPDIR="$PI2_SCRATCH" npm test`.

### What an agent's commands get

A shell command, in the foreground or the background, and a worktree's set-up command are started with, each item overriding the ones before it:

1. The engine's own environment, as macOS gave it to the app or the login item, without the variables that configure pi² itself (every `PI2_` name but `PI2_RUN`; [What commands can find](#what-commands-can-find)).
2. From the person's login shell, its `PATH` and its `SSH_AUTH_SOCK` (#96), asked as the engine starts (`src/shellpath.ts`). `SSH_AUTH_SOCK` is the path of the socket of the SSH agent that holds the person's keys, not a secret. A profile often points it at another agent than macOS's own (1Password, Secretive, a `gpg-agent`), and without it an agent's `git push` over SSH would find none of those keys. A shell that names none leaves the engine's. It follows the `PATH` in every way: a shell too slow for start-up has both taken when it answers, and an MCP server started before then is started again with them.
3. The variables the person gave the conversation's agent in its settings ([below](#an-agents-own-variables)).
4. `PI2_SCRATCH`, the conversation's [scratch folder](#a-scratch-folder), and `PI2_RUN`, the marker of the command's run ([background.md](background.md)), which the engine sets for each command.

They get nothing else of what the person's shell profile exports: not a `GH_TOKEN`, `GITHUB_TOKEN`, `GIT_SSH_COMMAND`, `GH_HOST` or `AWS_PROFILE` set there, which a terminal would have. Taking the whole environment from the shell would hand every secret it exports to every command an agent runs, so a variable a command needs is given to the agent in its settings, where the person sees it and chooses which agent has it. A tool that keeps its sign-in in the Keychain or a file of its own (`gh`, git's `osxkeychain` helper) works without either.

An MCP server run as a program gets the first two, and `PI2_RUN` when the engine itself has one, then variables of its own that the person gives it in Settings › Tools ([mcp.md](mcp.md#a-servers-own-variables), #273); not an agent's variables, nor a scratch folder. One server process serves every agent that uses it, so it cannot take one agent's variables, and what a server needs belongs to its own configuration. git that the engine runs itself (for worktrees and branches) gets the first two, with settings of its own that keep it from prompting or taking locks.

### An agent's own variables

In an agent's settings, under **Variables for its commands**, the person gives it environment variables of its own: a name and a value, such as `GH_TOKEN` for `gh` (#96). Every command it runs gets them, as above, without asking: the person set them, so they are theirs to give. The section says plainly, above the list, that every command the agent runs can read these values, and so can whatever those commands start; an agent can print a value or send it wherever a command can.

- **Where values are kept.** In the macOS Keychain, under the service the engine keeps sign-ins under, in one item per agent, `variables/<agent id>` (`src/variables.ts`, by way of `src/credentials.ts`, so a long value is split into pieces as a long sign-in is). Never in the database, a settings file, a backup or the app: the agent's profile holds the names only, and whether each has a value (`variables: [{ name, set }]`). The settings show the names; a value can be set and replaced, never read back, as an API key is. The engine keeps the values it has read in memory, so a command does not ask the Keychain each time. If the values cannot be read, the command is not run, and says why, rather than run without them.
- **Changing them.** `variables.set { agentId, name, value }` sets or replaces one, adding the name if it is new, and `variables.remove { agentId, name }` removes one with its value. They apply at once, without Save, from the next command, as command rules do. Saving the agent never changes them. An agent may have 50, each value 16 KB at most, with no NUL character.
- **Names that are refused**, each with why: anything that is not a name a shell can use; `PATH`, which comes from the login shell; any name that starts with `PI2_`, which are pi²'s own (it sets `PI2_SCRATCH` and `PI2_RUN` itself, and keeps the rest out); names bash reads as it starts every command and that would change what each one does, including the commands an agent's rules let it run without asking (`BASH_ENV`, `ENV`, `SHELLOPTS`, `BASHOPTS`, `PS4`, `IFS`, `CDPATH`, `GLOBIGNORE`, `POSIXLY_CORRECT` and every `BASH_` name); and `DYLD_` names, which macOS takes away from `/bin/bash`, so they would never arrive. Other names, `SSH_AUTH_SOCK` and `HOME` among them, are the person's to set, and win over the engine's.
- **Sub-chats.** A sub-chat is a conversation of the agent the work was handed to, so its commands get that agent's variables, never those of the agent that handed it the work.
- **A copy.** Duplicating an agent copies the names of its variables, without values: a secret is not copied without the person doing it. The copy's settings show each as having no value, and its commands get none until the person sets them.
- **Deleting the agent** removes its values from the Keychain first; if they cannot be removed, the agent is not deleted, and the person is told why.
- **Another Mac, or another copy of pi².** A backup holds the names, not the values. As the engine starts, a variable its profile says has a value that the Keychain does not hold (a backup restored elsewhere, an item removed by hand) is shown as having none, to be set again.

### The calls of one answer

A model can make several tool calls in one answer. pi durable starts them all at once, unless one of them is to a tool marked to run in order, in which case the whole answer's calls run one at a time, in the order the model gave them, each starting when the one before it has ended. Started together, a call that uses a file the one before it writes finds nothing there, or the file as it was: a `read` of a screen capture that a `bash` call is taking, or a `bash` with `background: true` that runs a script the call before it is writing (#145, #129).

So `src/order.ts` marks the tools that change files to run in order: `bash` (in the background too), `write`, `edit`, `write_document` and `codemode` (whose scripts can call the others). `src/mcp.ts` marks an MCP tool the same way unless its server marks it read-only (#190; see [mcp.md](mcp.md#read-only-tools)). An answer that calls any of them runs in order; one that only looks (reads, searches, web pages) or hands work to sub-chats still runs its calls side by side, which is where that saves real time. The system prompt tells the model both, once, in the `task_list` section, which every conversation with tools has (with or without `update_plan`): that calls which do not depend on each other belong together in one answer, and how they run, so it puts a call after the one whose result it needs, or in a later answer when neither of them changes files. Until #176 this was a note added to the descriptions of `bash`, `write`, `edit` and `read`, four copies read again on every turn, and nothing said that calls could go together: nine answers in ten made one call. Under Ask first, a call waiting for approval holds back the calls after it in the same answer. The computer and browser tools were already marked to run in order, each action depending on what the last one left. Calls a code mode script makes run as the script makes them, whatever their tool.

### Reading files

`read` is pi durable's, wrapped by `src/reading.ts` wherever it is offered. A call with `path` (and `offset`, `limit`) is handed to the library as it is and gives exactly what it gave before. A call with `files`, a list of `{path, offset, limit}` (or of paths), reads several files, or several ranges of one, in that order, each with the library's own `read`, and returns them one after another, each under a line `==> path <==` (or `==> path (lines 10-59) <==`). Agents had been reading through the shell, `cat` of several files or several `sed -n` ranges in one command, because `read` took one file a call (#176, #162).

- A file that cannot be read (missing, a folder, an offset past its end) says why in its place, and the others are still returned. The call is an error only when none could be read.
- Each file keeps the library's limit of 2000 lines or 50 KB, and says which `offset` continues it. A call shows at most 100 KB of text in all, and reads at most 20 files: the file that crosses the limit is cut at the end of a line and says which offset continues it, and the files after it are listed as not read.
- Pictures come back as the library prepares them ([attachments.md](attachments.md)), each under its line, at most five in a call.
- A code mode script gets, for `files`, a list with an entry per file: its `text` or `image`, a `note` (such as where to go on from), or the `error` that kept it from being read. For `path`, it gets what it always got.
- The result's `details` list the files, with which failed and which were pictures. The conversation shows the call as one row that names them ("Read reading.ts, tools.js and 3 more"), and opens to a section per file, cut at those lines.

The `bash` description says what the shell is not for: reading a file (`read`) and changing one (`edit`, `write`), which come with it at every access level that has it. It used to name `find_files` and `search_files` too; since an agent may leave those out (#221), they say themselves to use them rather than `find` or `grep` in the shell. It also says that a command starts in the conversation's folder, so there is no need to `cd` to it, and that there is no need to cut an output short, since the whole of it is kept. It is kept short, since every word of a description is read again on every turn.

### The system prompt's sections

A conversation's system prompt is its agent's sections, each tagged with its key (`<worktree>…</worktree>`), in the order the extensions declare them, then the agent's own instructions. pi durable sends the whole prompt and the tool definitions once, at the conversation's first request, and after that only what changed, as a system message in the transcript: a section whose text changed is sent again under its name, a section that went is named as removed, and tools are added and taken away by name. A new section, or a new tool, is added at the end. When that would leave them in another order than the agent's, pi durable removes every section (or every tool) and sends them all again instead, which puts the whole prompt in the middle of the conversation, for every later turn to carry, and starts the prompt cache again from there (#186).

The agent's instructions always come last, under a key no extension may use, so in a conversation whose agent has instructions a section that arrived after the first request would always be out of order, wherever it was declared. So every section keeps its place instead (`src/sections.ts`, applied to pi²'s extension and code mode's in `main.ts`): a section with nothing to say is empty rather than left out, and an empty section is not sent to the model at all. When it has something to say, its text changes in place and is sent as that one section; when it has nothing again, it goes back to empty, which is sent as that section with no text. A section is only given an empty place where that moves nothing: in a conversation's first request, or where the section is already shown. A conversation started before this goes on as before for each section it was sent without: when that section has something to say, the whole prompt is sent once more, and from then on the section keeps its place. Making room for them all at once would send the whole prompt to every such conversation at its next message, whether or not any of them ever came. Tools keep their order the same way: a conversation whose tools change (`syncTools`, or its access level changed) keeps the ones it has in the order it has them, and the new ones come after (`keepingOrder`). `engine/test/sections.ts` checks that each section and tool that arrives or goes is sent alone, with the demo model's `/system history`, which lists what each system message of the conversation changed.

The cheaper of the two ways the issue offered was chosen. Declaring the sections that come and go after the steady ones cannot work while the instructions come last, and several of them can come in any order. A one-line "none" text for each would be sent in every conversation; an empty one costs nothing.

The sections, in the order they are declared:

| Section | From | Has something to say when | Steady, or comes and goes |
|---|---|---|---|
| `computer_use` | `extensions.ts` | the `computer` tool is offered: computer use on, with at least one app allowed (#177) | Comes and goes with the agent's settings, and with the first app allowed and the last taken away; changes in place as apps are allowed |
| `browser` | `extensions.ts` | the `browser` tool is offered (the browser on) | Comes and goes with the agent's settings |
| `reference_files` | `extensions.ts` | the agent has reference files | Comes and goes with the agent's settings |
| `agents` | `extensions.ts` | the conversation can hand work to another agent (not in a sub-chat) | Comes and goes with the agent's settings and as agents are added or deleted |
| `task_list` | `plan.ts` | the conversation has any tools: `update_plan`, and how the calls of one answer run | Steady; changes in place when the agent's settings leave `update_plan` out or bring it back, keeping the second part |
| `project_instructions` | `knowledge.ts` | the conversation's folder has an instructions file (`CLAUDE.md`, `AGENTS.md`) | Comes and goes as the folder changes (moving into a worktree, the person choosing another) and as the file comes and goes; changes in place as it is edited |
| `memory` | `knowledge.ts` | memory is on for the agent | Comes and goes with the agent's settings |
| `look_web` | `look.ts` | `web_fetch` is offered (the browser on, and reading the web not left out) | Comes and goes with the agent's settings |
| `pictures` | `pictures.ts` | the conversation would make pictures (a chat, or an agent that turned them on) but no provider of the person's has a picture model: it says so | Comes and goes as providers are signed in and out |
| `documents` | `documents.ts` | `write_document` is offered (access Ask first or Full, and not left out; always in a chat) | Changes with the conversation's access level, and comes and goes with the agent's built-in tools |
| `chat` | `chat.ts` | the conversation is a chat ([chat.md](chat.md)) | Steady; changes in place as the web is turned off or on |
| `scheduling` | `selfschedule.ts` | the scheduling tools are offered: scheduling on, not in a sub-chat (#177) | Comes and goes with the agent's settings |
| `worktree` | `worktrees.ts` | the conversation works in a worktree pi² made | Comes when it moves into one, goes when it leaves it or the worktree is removed |
| `scratch` | `scratch.ts` | `bash` is offered: it names the conversation's [scratch folder](#a-scratch-folder) | Steady; changes only with the conversation's access level |
| `commit_coauthor` | `coauthor.ts` | the person's co-author switch in Settings is on, and the conversation can run commands | Comes and goes with that switch |
| `background_commands` | `background.ts` | the conversation has started a background command | Comes at its first background command; goes when the engine restarts, which forgets them |
| `codemode` | `codemode.ts` (pi durable's, cut down) | code mode is on | Comes and goes with the agent's settings; changes in place as its tools change |
| `instructions` | pi durable | the agent has instructions | Steady: set when the conversation is, and always last |

A section added to `extensions.ts` or to a feature (`features.ts`) keeps its place without anything more. A section in a new extension needs `holdingPlaces` where the extension is installed in `main.ts`, and a test in `engine/test/sections.ts` if it comes and goes.

### An MCP server changed while a call runs on it

The engine counts the tool calls running on each copy of an MCP server it started (a process, or a session with a server over HTTP), so that a change to the server in Settings does not cut off a call it did not mean to (`src/mcp.ts`):

- **Reconnect**, **saving the server** with it still on (a new command, URL or token), and **changing one of its variables** ([mcp.md](mcp.md#a-servers-own-variables)) start a new copy beside the one running. Until the new copy has connected and listed its tools, Settings shows the server as connecting, its tools stay in what conversations are offered, and a call made meanwhile goes to the copy running. Then the new copy takes over, and the old one is closed once no call is left on it. If the new copy fails to start, the server shows why and offers no tools, and the old copy is closed in the same way, once its calls are done.
- **Removing** the server, or **switching it off**, closes every copy of it at once, an old one still finishing a call included: the person asked for it to go, and a call left to finish could still change things on a server they took away. A call cut off this way ends with an error that tells the agent so ("The MCP server Name was removed while this call was running, so the call was stopped. Whatever it did before then may have happened.") rather than the protocol's "connection closed". A server that stops on its own says that it stopped, in the same way.
- An old copy is kept for its calls for **ten minutes at most** (`LINGER_MS`). A call usually ends far sooner, since a request with no word from the server for a minute times out, but a server that keeps reporting progress can hold one open for ever. When the ten minutes are up, the copy is closed and the call ends with an error that says why.

`engine.log` has a line when an old copy is kept for a call, when one is closed with a call still running, and when removing or switching off a server stopped a call. Settings says nothing about an old copy finishing a call: the call shows, and can be stopped, in its conversation, and stopping it closes that copy at once.

## Where things live

| What | Where |
|---|---|
| Conversations, agents, schedules, settings | `~/Library/Application Support/pi2` (one SQLite database and a few small files) |
| Keys and sign-ins, and the values of agents' variables | The macOS Keychain, service `dev.pi2.credentials` |
| Logs | `engine.log` and `app.log` in the data folder. See [The logs](#the-logs) |
| A shell command's whole output, when its result was shortened | `output/<conversation>/` in the data folder, for 7 days at most |
| A conversation's scratch folder, for temporary files | `/tmp/pi2-<uid>/scratch-<hash>/<conversation>`, until the conversation is deleted. See [A scratch folder](#a-scratch-folder) |

A development build uses `~/Library/Application Support/pi2-dev` and the Keychain service `dev.pi2.credentials.dev` instead, never the ones above ([development.md](development.md#build-and-run)).

A sign-in credential can be several kilobytes, more than one Keychain command can carry, so long ones are split across several items with a checksum. A damaged item reads as "signed out" rather than as an error.

Only on other platforms, engine tests use a plain-text file inside their throwaway data folder (`test-credentials.json`, mode 0600). This is a stand-in for fake credentials, not a supported way to run pi². The actual platform chooses the store (`credentialStore` in `credentials.ts`); on macOS it always uses Keychain, and the test-file factory itself refuses to run there. No variable can select it on a Mac, and a Keychain error never falls back to a file. Agents' variables still use Keychain. See [CI](development.md#ci) for which unchanged tests run on Linux.

Environment variables the engine reads, mostly for tests (none of them is passed on to what it starts; see [What commands can find](#what-commands-can-find)): `PI2_HOME` (data folder), `PI2_KEYCHAIN_SERVICE` (Keychain service name), `PI2_DEMO_COST` (a price for the demo model so budgets can be tested), `PI2_DEMO_TEXT_MODEL` (adds a demo model that cannot see images), `PI2_DEMO_PICTURES` (adds a demo picture model on a stand-in server at that address, used only on 127.0.0.1; [pictures.md](pictures.md)), `PI2_DEMO_TOKENS_PER_SECOND` (how fast the demo model types, except for messages that start with `/slow `), `PI2_LOGIN_SHELL` (the shell to ask for its `PATH` in place of the person's; `off` asks none and leaves the `PATH` as it is, which is what the tests do), `PI2_LOGIN_SHELL_TIMEOUT_SECONDS` (how long start-up waits for that shell's answer, in place of 5 seconds; the login shell test gives its stand-in 600, so a busy Mac does not make the engine go on without its `PATH`), `PI2_COMMAND_TIMEOUT_SECONDS` (the time limit for a shell command whose call gives none, in place of 2 minutes; the end-to-end test uses a limit longer than its patience, except for its default-timeout check, which uses 3; a call's `timeout` may still go up to 10 minutes, or this, if it is longer), `PI2_OUTPUT_WAIT_SECONDS` (the longest the app's request for a background command's output waits for more, in place of 30 seconds; the background commands' test makes it longer than its own patience, so a wait that ends can only have ended for output or the command's end), `PI2_LIMIT_BACKOFF_MS` (the first wait for a provider's limit when it names no time, in place of 15 seconds; later waits double it, up to 40 times it) and `PI2_LIMIT_WAIT_MAX_MS` (the longest a run waits by itself for a limit when no time is named, in place of 6 hours), both for `engine/test/limitwait.ts` ([limits.md](limits.md#when-a-limit-is-reached)).

## The logs

`engine.log` is what the engine prints: the app, or the login item, sends its standard output and standard error there, and adds to the file rather than starting it again, so the lines of an engine that crashed are still there after the next start. `app.log` has the app's own notes, such as a dropped connection.

Every line of both starts with the time it was written, in UTC to the second (ISO 8601, as Swift's `.iso8601` writes it), then a space:

```
2026-11-16T18:03:12Z [pi2-engine] listening on …/engine.sock
2026-11-16T18:09:40Z [pi2-engine] worktree made for conversation 12 on fix-login
2026-11-16T18:15:02Z [pi2-engine] background command bg-3 of conversation 12 exited with code 1
```

The engine's own lines carry the `[pi2-engine]` tag after the time; a line without it came from a dependency or from Node. A line about a background command, a worktree or a set-up command names its conversation by number (`conversation 12`), the number the app shows for it, so `grep "conversation 12"` finds what was done for one conversation. So do the lines about a run that waits for a provider's limit, when the wait starts and ends ([limits.md](limits.md#when-a-limit-is-reached)), and the line written when a run ends on an error from the model's provider, with the provider's message shortened and with keys and account identifiers taken out:

```
2026-11-17T09:12:40Z [pi2-engine] conversation 14 is waiting for Anthropic's rate limit: until 2026-11-17T10:00:00Z, the time it named
2026-11-17T10:00:03Z [pi2-engine] conversation 14 carries on: Anthropic answered after 47 min of waiting (2 refusals)
2026-11-17T10:20:51Z [pi2-engine] conversation 15's run ended on an error from Anthropic: 401 authentication_error: invalid x-api-key
```

The lines about the prompt cache name the conversation too: when one that hands out work starts asking for the long cache, and what a request after more than five minutes without one read from the cache ([limits.md](limits.md#the-prompt-cache)):

```
2026-11-17T11:02:17Z [pi2-engine] conversation 12 read 143,912 tokens from the prompt cache after 31 min without a request; the request before asked for the long cache
```

A clean stop ends with its elapsed time measured inside the engine, using a monotonic clock: `stopped cleanly in 1519 ms`. The app gives it five seconds to stop before it restores a backup. Measuring inside the engine avoids charging it for a test process that is slow to notice its exit; it still counts delays within the stop, including time the engine could not run on a busy Mac, which counts toward the app's deadline too.

The time is put on in one place, `engine/src/log.ts`, where the lines leave the engine, not by each line's writer: so a line a dependency writes, a warning from Node, and the trace of an error that stops the engine (which the engine writes itself, as a `fatal:` line) get one too, and so does each line of a message that runs over several. A line written in several pieces gets the time of its first piece. Only what Node writes before the engine's own code has started has no time: an engine file that cannot be read or has an error in it, which Node reports as it loads the files and stops. `--restore`, which the app runs to put a backup back, writes its output as it is: the app reads it, and shows its error to the person.

What reads the log goes by its wording, not by the start of a line: the app's "engine could not be started" notice shows its last lines as they are, and tests wait for a line such as `listening on` anywhere in a line. A new reader should do the same, or allow for the time.

## Known limits

- pi durable is marked experimental. The engine pins version 1.5.2 exactly, and patches a few of its files as it is installed (`engine/scripts/patch-dependencies.ts`), among them its retry of a failed model request, so that a provider's rate limit is waited for ([limits.md](limits.md#when-a-limit-is-reached)).
- Approvals wait inside the running engine and are asked again after a restart. pi durable ends a waiting call after five crashes in a row.
- Whether a subscription may be used from a third-party app is up to each provider's terms.
- A background command's output is kept in memory only, its last 128 KB, and is gone when the engine stops. See [background.md](background.md).
- With "Full access", commands run without asking. Tools always work inside the conversation's folder, or the app's own scratch folder when none is chosen.
- A model on a custom endpoint is treated as text-only until it is marked as able to see pictures in the endpoint's settings. Unmarked, it gets the list of controls in computer use but not the pictures, and cannot be sent attached pictures.
- Computer use: a click at a bare point (not on a listed control) is ignored by some apps while they are in the background; the agent is told when nothing changed. Pop-up menus and apps with little accessibility support (some games, some cross-platform apps) may not be workable.
- macOS ties the Accessibility and Screen Recording permissions to the exact build. After rebuilding a development build, remove pi² from those lists in System Settings and grant it again.
- Anything running as you can talk to the engine's socket. With computer use on, that includes asking an agent to use the apps you allowed.
- The browser: pi² has to be open; a frame from another site is listed with its address rather than read in place; a page that is not showing in the Browser window counts as hidden to the site. See [browser.md](browser.md).
- Builds are not signed with a Developer ID or notarized. The script has a path for it (`SIGN_IDENTITY`, `NOTARY_PROFILE`), which has not been exercised.
- Deleting a conversation stops pi² showing it; it does not erase its text from the session file, because pi durable cannot remove a conversation. See [archive.md](archive.md).
- Not built: remote environments over SSH, MCP sign-in (OAuth), per-run budgets, automatic updates, loading very old messages in very long conversations.
