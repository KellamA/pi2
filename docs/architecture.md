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
| `src/subchats.ts` | `sub_chats`: an agent lists the sub-chats it opened and archives the finished ones. See [archive.md](archive.md#sub-chats-an-agent-puts-away) |
| `src/providers.ts` | Built-in providers, custom endpoints, the scripted demo model |
| `src/attachments.ts` | Pictures and files sent with a message: their limits, what the model is sent, what the transcript keeps. See [attachments.md](attachments.md) |
| `src/credentials.ts` | Keys and sign-ins in the macOS Keychain |
| `src/computer.ts` | Computer use: what is allowed, the link to the app, trimming old screenshots |
| `src/browser.ts` | The browser: which addresses and uploads are allowed, the link to the app, what the agent is told |
| `src/reference.ts` | An agent's reference files |
| `src/rules.ts` | Rules for the shell commands an agent may run without asking: reading a command line, matching, refusing. See [rules.md](rules.md) |
| `src/features.ts` | The list of features that live in one file each, and what such a file can add |
| `src/plan.ts` | The agent's task list |
| `src/codemode.ts` | What the model is told about code mode: the `codemode` section and the tool's description. See [codemode.md](codemode.md) |
| `src/archive.ts` | Archiving and deleting conversations, and archiving what has gone unused. See [archive.md](archive.md) |
| `src/knowledge.ts` | A project's instructions file, and an agent's memory |
| `src/coauthor.ts` | The setting that asks agents to end their commit messages with a `Co-authored-by` line naming pi². See [commits.md](commits.md) |
| `src/look.ts` | Listing and searching files, fetching pages and searching the web |
| `src/limits.ts` | A subscription's own usage limits |
| `src/schedules.ts` | Schedule rules and next-run times |
| `src/worktrees.ts` | A git worktree per conversation, its agent's set-up command, and the branch tracker. See [worktrees.md](worktrees.md) |
| `src/selfschedule.ts` | Schedules an agent sets for itself, each approved by the person. See [schedules.md](schedules.md) |
| `src/shellpath.ts` | The `PATH` the engine gives what it starts: asked of the person's login shell once, at start, and taken when it comes if the shell is slow |
| `src/commands.ts` | The shell tool: how long a command may run, the default time limit, and what the model is told about it and about a long output |
| `src/output.ts` | The whole output of a shell command whose result was shortened: the file it is kept in, and how long |
| `src/order.ts` | Which calls of one answer run one at a time, in order, and what the model is told about it |
| `src/reading.ts` | `read` of several files, or several ranges of one, in one call. See [Reading files](#reading-files) |
| `src/background.ts` | Commands an agent leaves running in the background: starting, reading their output, stopping, and what happens to them when a conversation is put away or the engine stops. See [background.md](background.md) |
| `src/processes.ts` | The processes of set-up and background commands: reading `ps`, the run's marker, and stopping only what is provably left over from an engine that died |
| `src/mcp.ts` | MCP servers and their tools. See [mcp.md](mcp.md) |
| `src/backup.ts` | Backup and restore |
| `src/log.ts` | The time at the start of each line of `engine.log`. See [The logs](#the-logs) |

Conversations, runs and tool calls are pi durable's. pi² adds a few documents of its own on top: the list of conversations with their titles and settings, the agents, the schedules, and a per-day record of spend.

### Approvals

With tool access set to "Ask first", a hook runs before each tool call that would change something. It puts an item in the Inbox and waits. The wait lives in the running engine; after a restart pi durable runs the hook again, so the question reappears. A shell command that the agent's own rules cover for the conversation's folder runs without asking; see [rules.md](rules.md). The hook decides nothing until the engine has loaded its conversations, its agents and its `PATH` (`Host.ready`): the last engine's work can be set going before then, by a feature writing into a transcript as it starts, and a call judged against agents not yet loaded would be asked about without its rule, or asked about although a rule covers it.

### Sub-chats

`delegate` creates a conversation owned by the calling tool call, configured from the other agent's profile, and waits for its answer. It works in its parent's folder unless the other agent has a folder of its own outside the parent's repository, or the call passes `worktree`, which gives it a worktree of its own made as New Worktree… makes one ([worktrees.md](worktrees.md#sub-chats)); without full access that asks the person first, unless the other agent gets worktrees anyway. The app lists it under its parent, by the `title` the calling agent gave it (80 characters at most), or else as the agent's name and the first words of the task, or the worktree's branch when it has one. Passing `chat` continues an earlier sub-chat instead of starting a new one, and restores it first if the agent had archived it; a `title` passed with it renames it, unless the person renamed it themselves. A conversation that can delegate also gets `sub_chats`, to list its sub-chats with how each stands and archive the finished ones ([archive.md](archive.md#sub-chats-an-agent-puts-away)).

### What commands can find

The app or the login item starts the engine, so it begins with the `PATH` macOS gives every program: `/usr/bin:/bin:/usr/sbin:/sbin`. Programs the person installed themselves (with Homebrew, a version manager, or into `~/.local/bin`) are not on it. As it starts, the engine asks the person's login shell for its `PATH`, the way a new terminal window would have it (`zsh`, `bash` or `fish`, run as a login and interactive shell), and takes that as its own, keeping its own folders after it. Shell commands, MCP servers started as programs, and git all inherit it. Only full paths are kept, so an entry that means "the current folder" never lets a file in a project stand in for a program.

A shell that fails, or is one the engine does not know how to ask, is left alone; the engine then adds `/opt/homebrew/bin`, `/opt/homebrew/sbin`, `/usr/local/bin` and `~/.local/bin`, where they exist. `engine.log` says which happened. A change to the shell's profile counts from the next time the engine starts.

Start-up waits five seconds for the shell's answer and no longer, since the app is waiting for the engine. A shell can take longer than that, most of all right after login, when the login item starts the engine and the Mac is at its busiest. Such a shell is not stopped: the engine adds the same usual folders for the time being, finishes starting, and keeps listening. When the shell answers, the engine's `PATH` becomes exactly what an answer in time would have made it: the shell's folders, then the ones the engine began with. The usual folders the shell does not name itself are dropped again, so a slow start and a quick one end with the same `PATH`.

Whatever is started after that gets the shell's `PATH`, because each of these reads the engine's `PATH` at the moment it starts something: an agent's shell commands, git, a worktree's set-up command, and an MCP server that is connected or reconnected. A command that was started before keeps the `PATH` it was started with until it ends.

MCP servers run as programs are connected as the engine starts listening, so on such a start they get the usual folders. When the shell's `PATH` is taken, each one that was started with another `PATH` is started again with it, without anyone pressing Reconnect (`McpServers.followPath` in `src/mcp.ts`):

- One that failed to start, as one whose program (`npx`, `uvx`, a `node` from a version manager) is only on the shell's `PATH` does, is connected again at once. Nothing was using it. A conversation is given its tools at its next message, as after any reconnect.
- One that is connected is started again beside the one running, and takes its place only once it has connected and listed its tools. Its tools never drop out of what conversations are offered meanwhile, so a conversation in the middle of an answer carries on. A call already running on the old process finishes there; the old process is closed once no call is left on it, or after ten minutes at most (see [below](#an-mcp-server-changed-while-a-call-runs-on-it)). A call that was resolved before the swap but runs after it (one waiting for an approval, say) goes to the new process. If the server will not start with the new `PATH`, the one running is kept, and `engine.log` says so.
- One still connecting is looked at again once it has connected or failed.

A server started with the `PATH` the engine has by then (one connected after the answer, or a `PATH` the answer did not change) is left alone, and so are servers reached over HTTP. `engine.log` has a line for each server started again.

A shell that has still not answered five minutes after it was asked is stopped, with whatever its profile started, and the `PATH` stays as it is. Five minutes is far longer than a shell that is merely slow has been seen to take, so one still going then is waiting for something that will not come. A shell still going when the engine stops is stopped with it, and neither the shell nor the five minutes keeps the engine from stopping. That holds while the engine is still starting too: told to stop then (the app quitting, say), it stops the shell instead of waiting for it, lets the rest of start-up finish, and stops cleanly without listening, so the next start does not take it for a crash. Only a shell that is still running is ever stopped: once it has ended, what it printed is its answer, and anything its profile left running is left alone, since the shell's process number may by then belong to another program. `engine.log` has a line when the wait runs out, and another when the shell's `PATH` is taken or when it is given up on, without the shell's folders.

### How long a command may run

A shell command has 2 minutes unless the call that runs it passes a `timeout` in seconds, which can give it up to 10 minutes; a call that asks for more gets 10 minutes. These are Claude Code's limits for its Bash tool (its `BASH_DEFAULT_TIMEOUT_MS` and `BASH_MAX_TIMEOUT_MS`). A command that may take longer than that, such as a full test suite on a busy Mac, runs with `background: true`, where the agent and the person can see it is still going. pi durable's `bash` has no default of its own, so `src/commands.ts` wraps it to add one.

At its limit, as in Claude Code, a command is moved to the background rather than stopped, and goes on there as a background command with an id, so the time it ran is not lost. Only where starting the same command in the background would not have asked the person (Full access, Always Allow bash Here, or a command rule that covers it), and not for a command that starts with `sleep`; otherwise it is stopped. The result says it did not complete within its limit and was moved to the background, with its id, what it had printed and how to read and stop it. [background.md](background.md#a-command-moved-there-at-its-time-limit) has the details. A worktree's set-up command keeps its own limit.

The tool's description gives both limits, and says that a command is moved at its limit. A command the limit stopped has, under what it had printed by then, a line saying which limit stopped it (the default, the call's own `timeout`, or the most, with what the call asked for), and what to do instead: a larger `timeout`, or `background: true`. One that was not moved because starting it in the background would ask says that too. When it had printed nothing at all, or nothing for the last minute or more, in a run of a minute or more, the line says so, and that a command that goes quiet that long may be waiting on something, such as a permission prompt on the person's screen, and may wait again if it is run again. A command that ends by itself after a minute or more says how long it took, and how long it went without printing anything when that was a minute or more.

The default was 30 minutes until #160, in which a command waiting on a system prompt that nobody had seen (by the timing, a macOS privacy prompt) held its conversation for 29 minutes with nothing to show for it. A worktree's set-up command is not an agent's command and keeps its own limit of 15 minutes ([worktrees.md](worktrees.md)).

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

The `bash` description says what the shell is not for: reading a file (`read`), finding and searching (`find_files`, `search_files`), changing a file (`edit`, `write`). It also says that a command starts in the conversation's folder, so there is no need to `cd` to it, and that there is no need to cut an output short, since the whole of it is kept. It is kept short, since every word of a description is read again on every turn.

### An MCP server changed while a call runs on it

The engine counts the tool calls running on each copy of an MCP server it started (a process, or a session with a server over HTTP), so that a change to the server in Settings does not cut off a call it did not mean to (`src/mcp.ts`):

- **Reconnect**, and **saving the server** with it still on (a new command, URL or token), start a new copy beside the one running. Until the new copy has connected and listed its tools, Settings shows the server as connecting, its tools stay in what conversations are offered, and a call made meanwhile goes to the copy running. Then the new copy takes over, and the old one is closed once no call is left on it. If the new copy fails to start, the server shows why and offers no tools, and the old copy is closed in the same way, once its calls are done.
- **Removing** the server, or **switching it off**, closes every copy of it at once, an old one still finishing a call included: the person asked for it to go, and a call left to finish could still change things on a server they took away. A call cut off this way ends with an error that tells the agent so ("The MCP server Name was removed while this call was running, so the call was stopped. Whatever it did before then may have happened.") rather than the protocol's "connection closed". A server that stops on its own says that it stopped, in the same way.
- An old copy is kept for its calls for **ten minutes at most** (`LINGER_MS`). A call usually ends far sooner, since a request with no word from the server for a minute times out, but a server that keeps reporting progress can hold one open for ever. When the ten minutes are up, the copy is closed and the call ends with an error that says why.

`engine.log` has a line when an old copy is kept for a call, when one is closed with a call still running, and when removing or switching off a server stopped a call. Settings says nothing about an old copy finishing a call: the call shows, and can be stopped, in its conversation, and stopping it closes that copy at once.

## Where things live

| What | Where |
|---|---|
| Conversations, agents, schedules, settings | `~/Library/Application Support/pi2` (one SQLite database and a few small files) |
| Keys and sign-ins | The macOS Keychain, service `dev.pi2.credentials` |
| Logs | `engine.log` and `app.log` in the data folder. See [The logs](#the-logs) |
| A shell command's whole output, when its result was shortened | `output/<conversation>/` in the data folder, for 7 days at most |

A development build uses `~/Library/Application Support/pi2-dev` and the Keychain service `dev.pi2.credentials.dev` instead, never the ones above ([development.md](development.md#build-and-run)).

A sign-in credential can be several kilobytes, more than one Keychain command can carry, so long ones are split across several items with a checksum. A damaged item reads as "signed out" rather than as an error.

Environment variables the engine reads, mostly for tests: `PI2_HOME` (data folder), `PI2_KEYCHAIN_SERVICE` (Keychain service name), `PI2_DEMO_COST` (a price for the demo model so budgets can be tested), `PI2_DEMO_TEXT_MODEL` (adds a demo model that cannot see images), `PI2_DEMO_TOKENS_PER_SECOND` (how fast the demo model types, except for messages that start with `/slow `), `PI2_LOGIN_SHELL` (the shell to ask for its `PATH` in place of the person's; `off` asks none and leaves the `PATH` as it is, which is what the tests do), `PI2_LOGIN_SHELL_TIMEOUT_SECONDS` (how long start-up waits for that shell's answer, in place of 5 seconds; the login shell test gives its stand-in 600, so a busy Mac does not make the engine go on without its `PATH`), `PI2_COMMAND_TIMEOUT_SECONDS` (the time limit for a shell command whose call gives none, in place of 2 minutes; the end-to-end test uses 3; a call's `timeout` may still go up to 10 minutes, or this, if it is longer), `PI2_OUTPUT_WAIT_SECONDS` (the longest the app's request for a background command's output waits for more, in place of 30 seconds; the background commands' test makes it longer than its own patience, so a wait that ends can only have ended for output or the command's end).

## The logs

`engine.log` is what the engine prints: the app, or the login item, sends its standard output and standard error there, and adds to the file rather than starting it again, so the lines of an engine that crashed are still there after the next start. `app.log` has the app's own notes, such as a dropped connection.

Every line of both starts with the time it was written, in UTC to the second (ISO 8601, as Swift's `.iso8601` writes it), then a space:

```
2026-11-16T18:03:12Z [pi2-engine] listening on …/engine.sock
2026-11-16T18:09:40Z [pi2-engine] worktree made for conversation 12 on fix-login
2026-11-16T18:15:02Z [pi2-engine] background command bg-3 of conversation 12 exited with code 1
```

The engine's own lines carry the `[pi2-engine]` tag after the time; a line without it came from a dependency or from Node. A line about a background command, a worktree or a set-up command names its conversation by number (`conversation 12`), the number the app shows for it, so `grep "conversation 12"` finds what was done for one conversation.

A clean stop ends with its elapsed time measured inside the engine, using a monotonic clock: `stopped cleanly in 1519 ms`. The app gives it five seconds to stop before it restores a backup. Measuring inside the engine avoids charging it for a test process that is slow to notice its exit; it still counts delays within the stop, including time the engine could not run on a busy Mac, which counts toward the app's deadline too.

The time is put on in one place, `engine/src/log.ts`, where the lines leave the engine, not by each line's writer: so a line a dependency writes, a warning from Node, and the trace of an error that stops the engine (which the engine writes itself, as a `fatal:` line) get one too, and so does each line of a message that runs over several. A line written in several pieces gets the time of its first piece. Only what Node writes before the engine's own code has started has no time: an engine file that cannot be read or has an error in it, which Node reports as it loads the files and stops. `--restore`, which the app runs to put a backup back, writes its output as it is: the app reads it, and shows its error to the person.

What reads the log goes by its wording, not by the start of a line: the app's "engine could not be started" notice shows its last lines as they are, and tests wait for a line such as `listening on` anywhere in a line. A new reader should do the same, or allow for the time.

## Known limits

- pi durable is marked experimental. The engine pins version 1.5.2 exactly.
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
