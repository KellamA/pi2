# Development

## What to read for what

Read only the sections that apply to your work. Before you build, run or test anything, read all of [Testing safely](../CONTRIBUTING.md#testing-safely).

| Work | Sections to read |
|---|---|
| Finding your way around the code | [Layout](#layout), [Conventions](#conventions) |
| Building the app or working on pi² from pi² | [Requirements](#requirements), [Build and run](#build-and-run), [Working on pi² with pi²](#working-on-pi-with-pi) |
| Running engine checks | [Running the engine tests](#running-the-engine-tests), [Engine type-check](#engine-type-check), [Running several suites at once](#running-several-suites-at-once) if needed |
| Adding or fixing an engine test | [Engine tests by file](#engine-tests-by-file), [The end-to-end test](#the-end-to-end-test) if it is `engine.ts`, [Keeping test runs apart](#keeping-test-runs-apart), [Waiting in tests](#waiting-in-tests) |
| Checking app changes | The relevant check: [Browser](#browser-checks), [Panes](#pane-layout-checks), [Window sizes](#window-size-checks), [Message fields](#message-field-checks), [File links](#file-link-checks) or [Conversation page](#conversation-page-tests) |
| Trying an app change in a copy | [Trying changes in a throwaway copy](#trying-changes-in-a-throwaway-copy), [Choosing what a copy shows](#choosing-what-a-copy-shows), [The scripted demo model](#the-scripted-demo-model) |
| Measuring speed | [Measuring under load](#measuring-under-load), [Measuring the app's speed](#measuring-the-apps-speed) |
| Repository scripts, checks and merging | [CI](#ci) |

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
open "app/build/pi² dev.app"
```

`npm ci` also runs `engine/scripts/patch-dependencies.ts`, which fixes bugs in installed dependencies that their own releases do not have yet (each patch says what and why). If a dependency update changes a patched file, the install stops with a message: check whether the fix is still needed, then update or remove its patch.

This is a development build. It runs the engine from `engine/` with the Node on your `PATH`, so engine edits take effect the next time the engine starts (**Debug › Kill Engine** restarts it), and the build only works on this machine.

A development build keeps apart from a pi² installed on the same Mac, so opening one can never reach that copy's conversations, sign-ins, preferences, macOS permissions or login item:

- Its bundle id is `dev.pi2.app.dev`, and it is called "pi² dev" in the Dock, Finder and the menu bar. macOS keeps its preferences, notifications and privacy permissions apart from the installed copy's (`dev.pi2.app`).
- Its data folder is `~/Library/Application Support/pi2-dev` and its Keychain service `dev.pi2.credentials.dev`, unless `PI2_HOME` and `PI2_KEYCHAIN_SERVICE` name others. Both are named after the bundle id: a copy whose bundle id is `dev.pi2.app.test-7` uses `pi2-test-7` and `dev.pi2.credentials.test-7` (`app/Sources/pi2/DevelopmentBuild.swift`).
- It never uses the usual data folder, `~/Library/Application Support/pi2`, or the usual Keychain service, `dev.pi2.credentials`, even when `PI2_HOME` or `PI2_KEYCHAIN_SERVICE` names them; it uses its own instead and says so in its `app.log`. That can happen without anyone meaning it: a terminal where they are set passes them on, and so did every command an agent of pi² ran until #195, which inherited its engine's `PI2_HOME`; `open` passes them on to the app it opens. The engine now leaves every `PI2_` variable but `PI2_RUN` out of what it starts ([architecture.md](architecture.md#what-commands-can-find)). To try a development build on your own conversations, restore a backup of them (Settings › Storage) into the development build's data folder; you sign in again there, since the sign-ins stay with the installed copy.
- It cannot turn the login item on or off: the switch in Settings › General shows as unavailable, as in any copy on a data folder of its own.
- Its agents' commands have none of its macOS permissions. The app starts the engine as its own responsible process, as a release build does, and a development build's Node is the one on your `PATH`, outside the bundle, so macOS cannot trace it back to the app ([architecture.md](architecture.md#whose-macos-permissions-commands-have)). A command such as `screencapture` run by one of its agents fails even where the build has Screen Recording, and the first one may put a prompt naming `node` on the screen. Computer use is not affected: the app does that under its own permissions.
- It never updates itself, and it never replaces the engine it finds on its data folder: that is only done by a release build, after an update. An engine started by another development build with the same bundle id, from another checkout, is noted in `app.log` and left running.

To check a problem that only happens with optimisation (such as #134), build an **optimised development build**:

```bash
./app/build.sh optimised
```

This compiles with Swift's release configuration (`-O`), but otherwise makes the same `app/build/pi² dev.app`: its own identity and data, the source engine, and all the development affordances below, including `PI2_SHOW` and keeping its windows out of the way. Use it in a throwaway copy just as for the ordinary development build. It defines `PI2_DEVELOPMENT` at compile time; debug builds define it through `Package.swift`. A release build never defines it, so those switches and the web inspector are compiled out, not enabled by an environment variable. `swift build -c release` alone is not an optimised development build; use the script.

For an app that carries its own Node and engine and can be moved:

```bash
./app/build.sh release
```

This makes `app/build/pi².app`, with the bundle id and the name of the release (`dev.pi2.app`, "pi²"), on the usual data folder and Keychain service unless `PI2_HOME` and `PI2_KEYCHAIN_SERVICE` say otherwise. That is the build that is released, so do not open it as built on a Mac where pi² is in use: [Testing safely](../CONTRIBUTING.md#testing-safely) says how to try one.

Signed builds, the update feed and the release workflow are described in [releasing.md](releasing.md).

## Tests

### Running the engine tests

```bash
cd engine && npm test
```

This runs, side by side, every file in `engine/test` but three: `patience.ts`, which is not a test but what the tests that start an engine share, `localserver.ts`, the stand-in for the engine that runs models on this Mac, which `localrun.ts` starts, and `browser.ts`, which needs the browser probe ([browser.md](browser.md)). A test you add as `engine/test/<name>.ts` is picked up by itself, with nothing to add to `package.json`; `node test/<name>.ts` runs it alone. Only `test:engine` and `test:browser` keep per-file npm aliases; do not add per-file scripts for new tests. `test:linux` and `test:macos` are CI's two groups, described under [CI](#ci). A file there that is not a test goes in the pattern in `package.json`'s `test` script, beside those, and among the files `engine/scripts/test-platform.ts` leaves out. Give a test you add a line of its own below, in its place by file name, so that two pull requests adding tests rarely touch the same lines. The tests:

### Engine tests by file

- `addedmodels.ts`: models added by hand to a built-in provider: what a new id is based on, adding, changing, keeping, giving way to the catalog and removing one, against stand-in providers; then a real engine whose added models are sent to a stand-in server on 127.0.0.1, which answers one and refuses the other, and what a conversation says when one is refused or removed.
- `background.ts`: background commands. An engine starts, reads and stops commands, and is stopped and killed with commands running; nothing they started is left.
- `cache.ts`: the prompt cache's lifetime. An engine against a stand-in Anthropic endpoint on 127.0.0.1: a conversation asks for the one-hour cache once it has handed out work and the others do not, a refusal of it is sent again with the short cache, and `engine.log` says what a request after a pause read; see [limits.md](limits.md#the-prompt-cache).
- `chat.ts`: chat mode's engine: a chat made, listed, opened and told it is one; offered only the assistant's tools, asking nothing, writing documents in its own folder; its model, settings, and web switch (where a new chat's starts, each chat's own, its versions and forks following it); pinned, searched, counted, exported, shown in Activity, forked, archived and deleted as a chat. See [chat.md](chat.md).
- `chatmemory.ts`: chat mode's instructions and memory: the instructions in every chat and no agent's conversation; chat mode's own notes kept across chats and apart from every agent's; the agents' notes read with `agent_notes` and never changed; no agent given chat mode's notes or the tool; the app's requests; memory off. It prints what one agent's notes would cost in a chat's prompt against what a chat is sent instead; see [knowledge.md](knowledge.md#chat-modes-memory).
- `codemode.ts`: what a conversation is told about scripts, with a test MCP server of 40 tools. It prints the size of each section of the system prompt; see [codemode.md](codemode.md).
- `compaction.ts`: earlier sizes, manual and agent-requested summaries, last request size, failed summaries leaving the model's context unchanged, open work and notes carried across summaries, and a steer and wake arriving at a gated summary. See [compaction.md](compaction.md).
- `credentials.ts`: the Keychain store.
- `documents.ts`: the documents tool.
- `earlystop.ts`: an engine told to stop while it is still starting stops cleanly (a real engine held in start-up by a stand-in shell that never answers).
- `engine.ts`: the end-to-end test described next.
- `environment.ts`: an engine started with pi²'s own variables set does not pass them to a shell command, a background command, a set-up command or an MCP server, and the commands get their conversation's scratch folder, a sub-chat its own, kept when archived and removed when deleted. The commands, not the server, get the variables the person gave their agent, whose values are in a Keychain service of the run's own and not in the data folder or a backup; a sub-chat gets its own agent's, names that would undo what the engine sets are refused, a copy of the agent gets the names alone, and deleting it removes its values.
- `everything.ts`: Allow everything ([allow-everything.md](allow-everything.md)). With the switch off, every kind of approval (a command, a file written or changed, a document, an MCP tool, computer use, the browser, a sub-chat's worktree, a schedule) is asked once, as before; with it on, none is, and each does its work. Then what it leaves alone: questions, the apps that stay refused, a sub-chat following its own agent, a duplicate, saving, a change counting from the next message both ways, the daily budget and the turn limit.
- `exec.ts`: commands keep their output when the engine is busy as they exit, and get no input.
- `handover.ts`: Continue with an Agent (#289): what an agent is given of a chat (the person's messages, files and pictures, the answers, a line for each use of the chat's own tools, and nothing of memory, other tools, thinking or the system prompt; pictures left out for a model that cannot see them, and at most ten), then a real engine with the demo model: refusals, a chat with a file, a picture, a document and an edited message continued with an agent in a chosen folder, the version shown handed over, both linked, the chat unchanged, and a deleted conversation unlinked.
- `heed.ts`: a message the person sends to steer ends an agent's wait on a sub-chat, `sub_chats` with `wait`, a background read or a question at once, and waits for a command in the foreground; a sub-chat let go carries on and gives its answer once, to a later `sub_chats` wait or by waking the agent. Every command waits on a file the test makes, so nothing is timed; see [architecture.md](architecture.md#a-message-while-an-agent-waits).
- `latepath.ts`: a login shell too slow for start-up still has its `PATH` and `SSH_AUTH_SOCK` taken when it answers (stand-in shells, and two real engines).
- `limits.ts`: the plan-limits refresh handler's minimum interval, with a controlled clock and stand-in fetch; no socket round trips have to fit inside a short window.
- `limitwait.ts`: limit waits. It reads refusals and decides waits on a clock of its own, and when a provider's limit counts as reached and when work carries on, then runs an engine against a stand-in provider on 127.0.0.1 that refuses with HTTP 429 and 529 and then answers, sends a message to steer a run that waits and checks the first request after the wait carries it, kills that engine in the middle of a wait, and stops it; and holds a sub-chat at the limit to check the Inbox notice going from "limit reached" to "carrying on" and what `sub_chats`' list says; see [limits.md](limits.md#when-a-limit-is-reached).
- `load.ts`: what the load script needs of the engine: the demo model's `/work`, which writes and runs a command several times as a working agent does, and `engine.lag`, how late the engine's thread ran ([Measuring under load](#measuring-under-load)).
- `localmodels.ts`: models on this Mac, the downloads ([local-models.md](local-models.md)). The downloader against a stand-in server on 127.0.0.1 that serves small files in pieces, drops the connection, stalls, is busy, refuses, ignores a range and sends the wrong bytes; then a real engine with a catalog of the test's own, served by that stand-in, and a stand-in control package whose Python plays Strata's commands: licences first, what fits, a checksum that does not match, the engine installed where Strata's server finds it, pause, resume, the engine killed in the middle of a download, preparing a pack with Strata's setup in pi²'s folders (and the engine killed while it does, the next one stopping what it left), files of the person's own used where they match, a preparation that fails and Try Again, a pack downloaded before the engine waiting for it, cancelling, the disk check, configuring and removing.
- `localrun.ts`: running a model on this Mac, with a stand-in for the engine (`localserver.ts`, which takes the command line of Strata's server, with the run config pi² writes from the model's settings, and loads when the test lets it): offered under On this Mac, thinking at Low, started when a conversation using it is shown, a message sent while it loads answered once it has, shared, kept for the grace period, stopped by hand and started again by the next message, a crash, a model that cannot start, one not prepared yet, one left by an engine killed outright, stopped when the last pane closes, kept while an agent works, a model changed or a conversation archived, and a clean stop of the engine; see [local-models-running.md](local-models-running.md).
- `log.ts`: every line of `engine.log` starts with its time, and `--restore`'s output does not.
- `look.ts`: the look tools.
- `mcppath.ts`: MCP servers started before a slow login shell answers are started again with its `PATH`, without cutting off a call (a stand-in shell, a test MCP server and a real engine).
- `mcpreconnect.ts`: reconnecting, editing, removing or switching off an MCP server deals with a call running on it as [architecture.md](architecture.md#an-mcp-server-changed-while-a-call-runs-on-it) says (a test MCP server whose calls answer when the test lets them, and a real engine).
- `modellists.ts`: asking a provider which models a key or sign-in can use, against stand-in providers on a stand-in server on 127.0.0.1 answering as ChatGPT's Codex service, Anthropic (two pages), OpenAI and Google do; a refusal (the key not repeated), a redirect (not followed) and providers that cannot be asked; and the catalogs the library refreshes itself, at start, on asking and from the store at the next start.
- `offthread.ts`: the programs the engine runs for itself, from a worker thread so that starting them never holds its own (#344): the folder, environment, output, exit code, a missing program, standard input, the time limit, and many at once.
- `offered.ts`: computer use with no app allowed, and scheduling in a sub-chat, are not offered, and neither are the built-in tools an agent's settings leave out: not their sections, not in a sub-chat of that agent, not to a script; a duplicated agent keeps the list; `run_code`, off by default, is offered only once an agent's settings turn it on, alone and with no section, and runs without asking. It prints the size of the prompt and the tool definitions for a plain agent, for such a sub-chat, and for a worker-like sub-chat with every built-in tool and with those a worker never uses left out.
- `opening.ts`: opening a long conversation newest first (#380): how the parts are cut (size, count, never starting at a tool result), then a real engine with a conversation of long command outputs, opened by an app that asks for newest first and one that does not, a message sent while the older parts come, and the conversation closed and opened again while they come; then the entries older than the engine's window of 300, asked for a part at a time until there are none (#440), in an agent's conversation and in a chat's version, which reads the history it shares with the one it came from; see [transcript.md](transcript.md#older-than-the-engines-window).
- `pictures.ts`: making pictures, with two engines: with no picture model the tool is offered to no one and an agent that wants it, or a chat, is told why; with a picture model on a stand-in server on 127.0.0.1 (`PI2_DEMO_PICTURES`), it makes and changes pictures, counts their cost and asks nothing; see [pictures.md](pictures.md).
- `priority.ts`: agents' commands run at a lower priority than pi² (#344): a shell command, what it starts and a background command run under `nice`, in the same shell and folder; with the switch off the next one runs at the engine's own priority, and the switch outlasts a restart.
- `planwindows.ts`: how full a subscription's windows are, as `delegate`'s result and `sub_chats`' list tell an agent that hands out work, and the Inbox notice when a window passes 90% with runs on it going. An engine with two stand-in subscriptions signed in under a test Keychain service, one of them answering requests over TLS on 127.0.0.1; see [limits.md](limits.md#telling-an-agent-that-hands-out-work-and-the-person).
- `reading.ts`: `read` of several files, or several parts of one, in one call, around the library's own tool.
- `rules.ts`: the command rules. It also runs the commands its rules allow through `/bin/bash`, in a folder of its own.
- `runcode.ts`: `run_code`'s sandbox: a program prints and returns, cannot reach files, the network (a server on 127.0.0.1 is never asked), the process or any tool, is stopped at its time limit with its worker thread, fails inside when it allocates too much, and has a long output shortened; see [code.md](code.md).
- `sections.ts`: it switches on, one at a time, what brings a section or a tool into a conversation, then leaves the built-in tools out one at a time and brings them back, then turns a chat's web switch off and on, and checks with `/system history` that each change is sent alone, without the rest of the prompt; see [architecture.md](architecture.md#the-system-prompts-sections).
- `shellpath.ts`: commands get the login shell's `PATH` and `SSH_AUTH_SOCK`, and nothing else from it (stand-in shells, the question itself in the real `bash` and `zsh`, and a real engine started with the bare `PATH`).
- `socket.ts`: the engine's socket path, and a data folder whose path is too long for a socket, which the engine then reaches through a short link.
- `testcopies.ts`: test copies of pi² for computer use (#146), with a stand-in for the app. Off, an unlisted copy is refused and a listed one is look-only, as before; on, the tool comes without an app, a copy is listed, looked at and acted on with the usual approvals, the app is told so it can check the copy itself, and pi² itself, the development build, other copies and terminals stay refused; a sub-chat follows its own agent's switch.
- `versions.ts`: a chat's versions (#285): Try Again, with the same model and another, Edit (of a later message and of the first), stepping between versions and what the model sees in each (`/context`), Try Again stopping an answer being written, the source a page read names, usage and search counting versions as the chat, the version shown outlasting a restart, and archiving. A real engine with the demo model, and a page served on 127.0.0.1 for `web_fetch`.
- `wakes.ts`: waking an agent that is not answering, when a sub-chat started with `delegate` and `wait: false` answers or a command started with `wake: true` ends, and each bound on it: the turn limit, Ask first, the daily budget, the hourly cap, the person's Stop and Don't Wake, archiving and deleting, and an engine stopped and started again; see [wakes.md](wakes.md).
- `worktrees.ts`: it makes throwaway Git repositories and has an engine make and remove worktrees in them. Stand-ins interrupt Git and file deletion at known points to check cleanup, retries in Branches and `sub_chats`, and refusal when pi² cannot prove a folder is safe to remove.

### The end-to-end test

The end-to-end test starts a real engine on a throwaway data folder and a throwaway Keychain service and drives it over the socket: chat, pictures and files in messages, tools, approvals, delegation and sub-chats, reference files, computer use and the browser (each with a stand-in for the app), schedules, crash recovery (`kill -9` mid-answer and mid-approval), usage and budget, search, code mode, a test MCP server, a mock OpenAI-compatible endpoint with and without a key, export, backup and restore. It makes the demo model type fast (`PI2_DEMO_TOKENS_PER_SECOND`); a check that needs an answer still on its way, to stop it or kill the engine in the middle of it, sends a message starting with `/slow `, which is answered at the usual pace. `npm run test:engine` runs this test alone.

### Keeping test runs apart

Each test removes the folders it makes in the temporary folder, and the Keychain items it makes, when it ends, whether it passed or failed. A test you add should do the same: in a `finally`, or, in a test with no `try` around it, in a `process.on("exit")` handler, which still runs when a failed check ends the process. An engine's [scratch folders](architecture.md#a-scratch-folder) are in `/tmp/pi2-<uid>`, outside its data folder: `engine/test/patience.ts` removes those of every engine a test connected to through it, as the test's process exits. Several runs of the suite can go at the same time on one Mac (several agents, or two worktrees), so a test checks only what it made itself: it does not count what is in the shared temporary folder (the documents test gives the code it checks a temporary folder of its own), listens on port 0 rather than a fixed one, and keeps Keychain items under a service no other run uses (the end-to-end test's has its process id in it, unless `PI2_TEST_KEYCHAIN_SERVICE` names one). To see what a run leaves behind, give it a temporary folder of its own with a short path (a long one makes the engines' socket paths too long), then list it: only npm's own `node-compile-cache` should be there.

```bash
T=$(mktemp -d /tmp/tests.XXXX)
(cd engine && TMPDIR="$T" npm test)
ls -A "$T"
```

### Running several suites at once

The whole suite takes about 80 seconds on a quiet Mac. Four runs at once took about two minutes each and six about two and a half, so runs from several agents or worktrees are quicker started side by side than taken in turn. Send a run's output to a file and read the file, rather than cutting it down with `tail` or `grep` as it runs: when the part you kept does not answer the question, the file does, and the suite does not have to run again.

```bash
(cd engine && npm test > /tmp/tests.log 2>&1; echo "exit $?")
grep -E "^(ℹ|✖)" /tmp/tests.log
```

### Waiting in tests

No check may depend on how fast the Mac is. With several runs of the suite going at once, an engine can take well over ten seconds to start listening, and anything can take many times longer than on a quiet machine. So a test waits for the thing itself, never for a time, and the limit on a wait (ten minutes, `PATIENT_MS`) is only there so that a hang fails instead of running for ever. A wait the test can tell has failed ends at once: when the engine exits, or the connection to it closes. `engine/test/patience.ts` has this for every test that starts an engine: `listening` connects once the engine listens, `EngineClient` is a connection with requests, events and `until`, and `stop` stops a process and waits for it. A process that only a check should stop (a command's `sleep`, a stand-in shell's program) runs for longer than any wait, so that a wait for it to be stopped cannot be met by its ending by itself. Where a check is about time, it measures what it is about: the processor time the converter took, or the time between a request arriving at a stand-in and the engine giving up on it, rather than the time on the test's clock around them. One check must retain an elapsed-time bound: a clean stop must fit in the five seconds the app gives the engine before a restore. It uses the engine's own monotonic elapsed time, not the test's time around the signal and exit, so a test process slow to notice the exit does not cause a failure. Scheduling delays inside the engine still count, as they do toward the app's deadline: subtracting them or using only processor time could hide a stop that really waits too long. This requirement can fail under extreme load; quiet CI verifies it. Where the engine has a limit of its own on a wait, such as the 30 seconds a request for a background command's output may wait, a test that must tell the wait ending for its reason from the limit running out sets the limit longer than its own patience (`PI2_OUTPUT_WAIT_SECONDS`). Before a test kills an engine to check that something outlives it, it waits for the answer or event that comes once that thing is stored, not for a time: a tool's result, or an event the engine sends from a stored document (the agents, the library). An event can come sooner than the storing it seems to report: the one that lists a background command as running comes before its process is on record, which the call that started it waits for. Streamed progress, such as the part of an answer already shown, is stored about a second later and may be lost.

### Engine type-check

```bash
cd engine && npm run check
```

type-checks the engine.

### Browser checks

The part of the app that works web pages is checked by a program of its own, which serves a few pages to itself and loads no real website:

```bash
cd app && swift build --product pi2-browser-probe && .build/debug/pi2-browser-probe
```

With the probe built, `cd engine && npm run test:browser` runs a real engine against it, to check that the two agree. See [browser.md](browser.md).

### Pane layout checks

The panes the conversation area is divided into (`app/Sources/PaneKit`) are checked by a program of its own: it splits panes, closes them down to one in every ready-made layout and at random, gives them equal room, saves and reads back each tree, and reads back damaged saved layouts, which must give a single pane. Build it with optimisation, as the app is released; closing a pane once crashed only in an optimised build (#134), and CI runs it this way:

```bash
cd app && swift build -c release --product pi2-layout-check && .build/release/pi2-layout-check
```

A crash in it prints the step it happened in; `--verbose` prints every step.

### Window size checks

How a window's size follows its SwiftUI content (`app/Sources/WindowKit`) is checked by a program of its own (#400). SwiftUI sets a scene's window's smallest size from its content, working it out from inside the window's Update Constraints passes, and the app once crashed there in the background. The app's windows put `windowMinimum(width:height:)` on their content, which gives SwiftUI a fixed base to measure instead, and the main window's detail column has `columnGivesWay()`, which keeps its content from asking for more height than the window has. The program makes windows as the app's are, in windows of its own that never come on screen: a hosting view with the option SwiftUI gives a scene's window, a toolbar, and a split view's sidebar and detail. It checks that the smallest size is the one SwiftUI worked out before; that the content is never measured for it, which it was before; that very long unbroken lines in each way the app shows text from outside it, rows and request cards that come and go, and the sidebar shown and hidden change neither the smallest size nor the window, at its smallest; that a stack of requests no longer makes the split view taller than the window; and that `SizeWatch`, which writes a line to `app.log` naming a hosting view whose size changes again and again without the run loop turning, reports one once and stays quiet for a window resized as a person does. It also checks `BodyWatch`, which a development build puts around the app's scene body (#436): that it reports, once, a body that reads something that then changes, stays quiet for one that only passes it on to a view of its own, and leaves SwiftUI seeing what the body reads as it would without it. It cannot make the crash itself happen, since what kept the window's size changing then was not found. CI runs it after building the app:

```bash
cd app && swift build --product pi2-window-check && .build/debug/pi2-window-check
```

### Message field checks

What Return does in a field that sends a message (`app/Sources/ComposeKit`: Return sends, Shift-Return or Option-Return starts a new line, and Return while an input method is composing is left to it) is checked by a program of its own. It checks the decision for every combination of modifier keys, then makes a SwiftUI text field as the message field is made, in a window of its own that never comes on screen, and hands key presses straight to that window: no key is posted to the system and no permission is needed. It checks that Shift-Return puts a line break at the cursor in place of the selection and the field grows, that Return sends the text with its line breaks, that Return with marked text (what an input method shows while a candidate is chosen) does not send, and that pasted line breaks are kept. It checks a field made as a memory note is in an agent's settings (a field of a grouped form that saves with Return and keeps its text) in the same way. Then it does the same for the answer field of a question on the conversation page, which has its own copy of the rule (`keys.js`): it loads the real page from `app/Web/transcript` in a web view that keeps nothing on disk. It cannot type with a real input method, so that is still worth trying by hand after a change there. CI runs it after building the app:

```bash
cd app && swift build --product pi2-compose-check && .build/debug/pi2-compose-check
```

### File link checks

What a click on a link to a file in a conversation does, and the link's menu (`app/Sources/FileLinkKit`, #451), is checked by a program of its own, in a temporary folder it makes and removes. It checks which path each kind of target names (absolute, `~/`, `file:`, relative to the conversation's folder) and which it refuses (another host, another scheme); that a path is made whole, through symbolic links, `..` and the link `/var` is, and that a loop of links, a file where a folder should be and a missing file are said to be gone; that it stops at a volume it must not look into, also through a link, and that `/home`, which the automounter has on most Macs, is never looked up; that a click shows a file or an application in its folder and opens a folder; what the notice says; and the menu's items, with Open for a document and a document package and never for a folder, an application, a script, a file anyone may run that is not a document, or a disk image. It shows nothing in Finder and opens nothing. CI runs it after building the app:

```bash
cd app && swift build --product pi2-file-link-check && .build/debug/pi2-file-link-check
```

In a throwaway copy, a click on a file link, and the menu's Show in Finder, Open and Copy Path, write what they would have done to `file-links.jsonl` in the copy's data folder, one JSON object a line (`action`: `show`, `showFolder`, `notice`, `open`, `copyPath`, or `menu` with its `items`; `path`, made whole; `conversation`), and do nothing else, so a test never puts Finder or another app on the screen or changes the pasteboard. The notice still shows in the page.

### Conversation page tests

The conversation page (`app/Web/transcript`) has tests that run in Node with a small stand-in for the DOM: its Markdown, its tool summaries and what a selection copies, including text written to break out of the page, and how older entries go above those on screen without moving them.

```bash
cd app/Web && node --test test/
```

See [transcript.md](transcript.md). The rest of the app has no automated tests.

### Trying changes in a throwaway copy

A development build already runs on a data folder of its own, so trying a change in it does not touch your own data. To start again from an empty folder, give it another:

```bash
open -n "app/build/pi² dev.app" --env PI2_HOME=/tmp/pi2-try --env PI2_KEYCHAIN_SERVICE=dev.pi2.credentials.try
```

On a Mac where pi² is in real use, and where other sessions may be testing too, try it in a copy with a bundle id of your own and clean up after it: `scripts/test-copy start test-7`, then `scripts/test-copy stop test-7`. [Testing safely](../CONTRIBUTING.md#testing-safely) in CONTRIBUTING.md has the rules and what the script does for each.

To seed that copy without writing a socket client, use `scripts/test-copy call <suffix> <method> [<json params>]`. It connects only to the socket in the copy's own data folder, never an environment override, and refuses a copy this checkout did not start or an engine it did not record. Params default to `{}` and must be a JSON object. The output is the complete JSON response, with `result` or `error`; an engine error exits non-zero. These start a copy waiting to show a conversation, create it after launch on the scripted demo model (no provider or sign-in), and send it a message. `PI2_SHOW` opens it when it appears while nothing else is open; no restart or click is needed:

```bash
scripts/test-copy start test-7 --show 'Late demo'
CHAT=$(scripts/test-copy call test-7 conversation.create '{"model":{"provider":"demo","modelId":"demo-1"}}' | jq -er '.result.id')
scripts/test-copy call test-7 conversation.rename "{\"id\":$CHAT,\"title\":\"Late demo\"}"
scripts/test-copy call test-7 submit "{\"id\":$CHAT,\"text\":\"Hello from a test copy\"}"
```

`call … submit` returns when accepted, not when the model has finished answering. Use `send` to wait for the exact new submission to finish and the conversation to be idle, following committed conversation events (not sleeping or accepting an earlier idle state):

```bash
scripts/test-copy send test-7 "$CHAT" 'Hello again' --timeout 120
```

The JSON result has `status`, conversation/submission ids and the answer on success. Exit `0`: done; `1`: failed or connection/engine error; `2`: waiting on the person (approval/question items included); `124`: timeout. The hang guard defaults to 600 seconds, at most 600. No approval is answered and no work is stopped when waiting ends. Before acceptance a timeout may have no submission id; inspect before resending. Like `call`, it refuses an unowned copy, an unrecorded engine or a symlink for its data/socket; it also refuses invalid conversation numbers, empty text and invalid limits. The engine's read-only `submission.get { id, submissionId }` reports the durable record and whether that conversation is busy, and refuses a submission belonging to another conversation, including another chat version.

After the answer finishes, archive it (this stops any work still running):

```bash
scripts/test-copy call test-7 conversation.archive "{\"id\":$CHAT}"
```

In a running copy, `scripts/test-copy show test-7 "$CHAT"` opens a conversation by id. `size test-7 820 532` sets the main window's outer frame in points; `size test-7 smallest` uses its current minimum. Use `shot` once the transcript has drawn.

`answer test-7 <conversation-id> allow|deny` answers exactly one waiting approval in that conversation (use the sub-chat's own id). `allow` means Allow Once, with no rule saved. `fill test-7 600` prints the id of a new demo conversation with 600 synthetic entries, including long tool outputs, without running the model or commands.

After rebuilding, `scripts/test-copy reopen test-7 --show "$CHAT"` installs the latest development app from this checkout, keeping the copy's engine and data. Without `--show`, it keeps the previous launch selection (not the last `show` command); it also keeps `--menu` and the demo environment. A failed relaunch leaves the data for retry or `stop`. Rebuild and start a fresh copy to pick up engine changes, including `fill` if the engine predates it.

`start --env NAME=VALUE` gives a copy an explicit demo switch without inheriting the caller's environment. For example (no provider needed):

```bash
scripts/test-copy start test-340 --show 'Demo variables' \
  --env PI2_DEMO_TEXT_MODEL=1 --env PI2_DEMO_COST=5 \
  --env PI2_DEMO_TOKENS_PER_SECOND=1000
```

The exact allowlist is `PI2_DEMO_PICTURES`, `PI2_DEMO_TEXT_MODEL`, `PI2_DEMO_COST`, `PI2_DEMO_TOKENS_PER_SECOND`. For a local picture stand-in, add `--env PI2_DEMO_PICTURES=http://127.0.0.1:PORT/v1` with its actual port. Never name a real provider. Each name may appear once; values with spaces or `=` work when quoted. Missing `=`, multiline values and every unlisted name (including `PI2_HOME` and `PI2_KEYCHAIN_SERVICE`) are refused before launch. The script sets isolation itself. The non-secret values are stored, revalidated and passed again at `reopen`; an engine already running keeps its original environment, so stop/start to change a value. Adding another allowed name is a reviewed script change, never a prefix wildcard.

### Choosing what a copy shows

A development build (ordinary or optimised, not a release build) also reads a few variables that help when taking pictures of the app or checking it by script:

- `PI2_SHOW` chooses what the window opens on: `inbox`, `activity`, `usage`, `archive`, `branches`, `agent:<id>`, or a conversation's number or title, matched exactly against the sidebar first, then the Archive. This includes a sub-chat archived on its own; opening it does not restore it, and the conversation still shows its archived bar and Restore button. Use the number when titles are shared. A conversation made after launch, such as through the copy's engine socket, opens when it comes, as long as nothing else is on screen. An agent's page is taller than any window, so `agent:<id>#<section>` opens it with one of its sections at the top: `profile`, `model`, `summaries` (when its conversations are summarised), `instructions`, `files` (reference files), `memory`, `tools`, `everything` (Allow everything), `builtins` (built-in tools), `rules` (commands it may run without asking), `variables` (variables for its commands), `extras` (extra tools), `computer`, `browser`, `schedule` or `delegates` (who it can hand work to). A name it does not know opens the page at the top. `#everything` also puts up the confirmation for turning Allow everything on, while it is off, so it can be captured. The last few sections cannot come to the top, since the page ends below them; the page scrolls to its end and they show there. The page settles for a second or two after it opens, so wait a few seconds before capturing it.

  `chat` opens chat mode on an empty chat (the one already waiting, or a new one), and `chat:<number or title>` on that chat; a chat's number or title alone opens it in chat mode too, as a chat chosen anywhere does ([chat.md](chat.md#in-the-app)).

  `output:<id>` opens a background command's output window as well, such as `output:bg-1` ([background.md](background.md)), about a second after the app has connected to its engine; the main window opens as it would without `PI2_SHOW`. It is a window of its own, 760 points wide, named after the command.

  `settings` opens the Settings window as well, which is a window of its own, and the main window opens as it would without `PI2_SHOW`. `settings:<tab>` opens it on one of its tabs: `general`, `chat`, `providers`, `tools` or `storage`; a name it does not know opens General. A tab can be taller than the window, so `settings:<tab>#<section>` opens it with one of that tab's sections at the top: `appearance`, `notifications`, `summaries` (long conversations), `background` or `updates` on General; `instructions`, `new-chats`, `memory` or `agent-notes` on Chat; `subscriptions`, `endpoints`, `local` (models on this Mac; `local=engine`, `local=model` or `local=configure:<model id>` opens that section's sheet for getting the engine, getting a model or a model's settings) or `keys` on Providers; `servers`, `commits` or `priority` on Tools; `folder` or `backup` on Storage. A section the tab does not have leaves it at the top, and so does one in a tab that already fits the window. On Providers, `settings:providers#models=<provider>` opens that provider's Models sheet, such as `#models=openai`, once the provider has models (it is signed in or has a key), and `settings:providers#add-model=<provider>/<model id>` opens its sheet for adding a model by id over it, with the id typed and looked up (`#add-model=openai/gpt-6.2-sol`; `#add-model=openai` leaves it empty). On Tools, `settings:tools#variables=<server id>` opens that MCP server's Variables sheet, once the server is listed. Settings opens about a second after the app has connected to its engine, not while the app is launching, and a section takes a few seconds more to settle, so wait before capturing it. In the list of windows it is the one 660 points wide.

  `palette` opens the command palette (⌘K) over the main window, which opens as it would without `PI2_SHOW`, and `palette:<query>` opens it with that query typed, so a capture shows the entries that match it, and the messages that do after the search has run. It opens about a second after the app has connected to its engine. The entries are listed by the palette's own code, so one added to it shows here with nothing more to do.
- `PI2_MENU=<label>` writes what a right-click on the element labelled `<label>` would show: the items of its context menu, in order, with submenus indented below their item, and the ones that cannot be chosen marked `[disabled]`. A conversation's row is labelled by its title and by its number, an agent's by its name and by its id, a row in the Archive as a conversation's is, and a pane's header as VoiceOver reads it (`Pane: <title>`, or `Empty pane`). The list goes to `context-menu.txt` in the data folder, a couple of seconds after the app has connected to its engine, and again a second after an element with that label comes on screen, so a row made after launch (through the engine's socket, say) is covered too; with no such element on screen, the file says so. A context menu is a pop-up macOS draws only while the app is in front, so it cannot be captured from a copy that must not take the focus; its items are made by the view, though, and can be asked for. Every context menu in the app is made with `.contextMenu(previewAs: <labels>)` (`LaunchPreviews.swift`), which in a development build puts an anchor behind the element whose label was asked for. The app builds a right-click event at the anchor's middle, never posted anywhere, and hands it to the view there with `menu(for:)`, as AppKit does to ask a view for its context menu; nothing is chosen and nothing appears on screen. A menu added with `.contextMenu(previewAs:)` is covered with nothing more to do, and `scripts/test-test-copy` fails on a plain `.contextMenu`. In a release build `.contextMenu(previewAs:)` is `.contextMenu` and nothing more.
- `PI2_DRAW_WHEN_HIDDEN=1` keeps the transcript drawing while the window is covered or the screen is locked. WebKit normally stops drawing a page nobody can see, which leaves it blank in a window capture. This uses a WebKit switch that is not public, which is why it is left out of release builds.
- `PI2_WINDOW_BEHIND=1` keeps the copy's windows behind every other app's windows, from the moment they open: they sit just below ordinary windows (at window level -1, the `kCGWindowLayer` that `CGWindowListCopyWindowInfo` reports), so nothing brings them forward, not a sheet, Settings opening or a click. A window behind others is still drawn, and `screencapture -l` captures it whole; for the transcript, add `PI2_DRAW_WHEN_HIDDEN=1` as for any covered window.
- `PI2_WINDOW_ORIGIN=x,y` opens the main window, Settings, the browser and a background command's output with their top-left corner at that point, in points from the top-left corner of the main screen (the measure of `kCGWindowBounds`). It applies while a window opens, until a second after it shows; one already open can be moved as usual. macOS keeps a window from opening entirely off the screens: it moves it back until a corner of it (about 40 points across) shows, so a point far off to the bottom right, such as `10000,10000`, parks the window in the bottom-right corner with only that corner on screen. A sheet, such as the first-run welcome a copy on a new data folder shows (`scripts/test-copy start` marks it done unless given `--welcome`), brings its window back far enough for the whole sheet to show. A window parked like that is drawn in full, and `screencapture -l` captures all of it.

  Without these, a copy's main window opens in the middle of the main screen at every launch, even launched with `open -g`: SwiftUI centres it, and ignores a frame written into the copy's preferences. A check that launches a copy many times should use both, as the steps in [Testing safely](../CONTRIBUTING.md#testing-safely) do.

To check a page without clicking, start a throwaway copy on it and capture its window: `scripts/test-copy start test-7 --show agent:<id>#rules` launches it with `PI2_SHOW` and the three variables above, with the first-run welcome marked done in the copy's data folder so that it does not cover the page (`--welcome` keeps it), and `scripts/test-copy shot test-7 app/build/test-copies/test-7/rules.png` captures it with `screencapture -l`, taking the window's id from `CGWindowListCopyWindowInfo` for the copy's process. It checks first that screen capture is already allowed (`CGPreflightScreenCaptureAccess()`) and refuses if it is not, since capturing without it makes macOS ask. It waits for a capturable window, even if that window is not marked on screen, but not for the contents of the page to settle. For a palette entry, `--show palette:<query>` and a capture; for a context menu, `--menu <label>`, which sets `PI2_MENU` and prints the file it writes.

### The scripted demo model

The scripted demo model answers `/bash <command>`, `/timeout <seconds> <command>` (bash with a `timeout`), `/background <command>` (bash with `background: true`; see [background.md](background.md)), `/tool <name> <json>` (any tool the conversation has, such as `/tool background {"action":"list"}`, or `/tool delegate {"agent":"Forge","task":"…","title":"Fix X","worktree":"fix-x","from":"main"}` for the parameters `/delegate` does not take), `/tools <json>` (several calls in one answer, as a real model makes them: `/tools [{"name":"bash","arguments":{"command":"ls"}},{"name":"read","arguments":{"path":"a.txt"}}]`), `/read <path>`, `/ask <question>`, `/delegate <agent>: <task>`, `/continue <sub-chat>: <task>`, `/ref <path>`, `/code <script>`, `/mcp <tool> <json>`, `/computer <json>` and `/browser <json>` with the matching tool call, which is enough to exercise most of the app without a provider. `/context` answers with what the person said in the conversation as the model was sent it, one message a line, with `(answer)` for each answer between, so a test can see which version of a chat a request saw. `/system` answers with parts of the system prompt it was sent: `/system <section> …` with those sections and the names of the tools offered, `/system sizes` with the length in characters of each section and of the tool definitions, `/system history` with one line for each system message in the conversation, saying which sections it set (with their length) or removed and which tools it added or took away. A section with nothing to say holds its place with empty text, which is not sent to the model; `/system sizes` and `/system <section>` leave it out. `/work <steps> <tokens a second> <command>` works as an agent does, for the load script below: it writes a paragraph at that pace and runs the command, `steps` times, then says it is done. Asked to summarize a conversation for compaction, it answers with a line at once, rather than repeating the whole conversation at a readable pace.

## Measuring under load

`node scripts/load.mts <suffix>` reproduces many agents working at once without a provider (#344), and measures how pi² answers meanwhile. It uses a throwaway copy started from this checkout (`scripts/test-copy start <suffix>`, which it does itself if the copy is not running, and stops again at the end), makes a conversation of a few hundred entries to open, then starts 20 conversations on the demo model, each in a small git repository of its own with full access, working with `/work`: writing at 60 tokens a second and running `git status`, `git log`, `ls` and a two-second `sleep` between paragraphs. Every second it asks what the app asks: a request that does nothing, opening a conversation (a working one, and the large one, whole and newest first as the app asks since #380), sending a message to an idle conversation and queueing one behind a run. It prints how long each took before the runs started and with them, how late the engine's thread ran (`engine.lag`) and how busy it was, and how many events a second, and how many kilobytes, the engine sent one client, by kind. At the end it archives what it made, which stops the runs.

```bash
node scripts/load.mts test-344 --runs 20 --seconds 120 --json /tmp/load.json
```

`--runs`, `--seconds`, `--before` (the seconds measured before the runs start), `--pace`, `--large` (the steps of the large conversation; 0 for none) and `--command` change the load; `--json <file>` keeps the numbers, to compare after a change; `--keep` leaves a copy it started running. `--socket <path>` measures an engine you started yourself instead of a copy, such as one under `node --cpu-prof` on a data folder of its own (`PI2_HOME`, `PI2_KEYCHAIN_SERVICE` and `PI2_LOGIN_SHELL=off`, as the tests start theirs). Take the numbers before and after a change on the same Mac, close together in time: they depend on how loaded the Mac is, which the script prints. `scripts/test-copy socket <suffix>` gives it the copy's socket, after the checks `call` makes.

The engine also writes a line to `engine.log` whenever its thread was held for a second or more, so a slow engine on a real Mac leaves a trace (`engine/src/lag.ts`).

## Measuring the app's speed

A development build (ordinary or optimised) measures its main thread while its data folder holds a file named `perf.on`, and writes what it found to `perf.log` there every ten seconds (`PerfProbe.swift`). It looks for the file every two seconds, so it can be turned on and off while the app runs. A release build never measures. Each ten seconds it writes:

- how much of the time the main thread was awake, and how late it answered a block sent to it every 50 ms from another thread (the wait a click would have), at the median, the 95th percentile and the worst;
- for each kind of event from the engine, and each kind of reply: how many a second, their size, and the main thread's time decoding and taking them in; `page update` is a conversation page being sent what changed;
- for each kind of request: how many, and how long their answers took;
- how many times the app's scene body was worked out (`count scene body worked out`), which updates every scene and sets each window's settings again. While agents work there should be none: the body reads nothing that changes while agents work ([architecture.md](architecture.md#keeping-the-app-quick-while-agents-work)).

It also writes a line for each conversation opened, with the time from asking for it to each step (the engine's first update, the engine's answer, the page being sent the entries, the page having drawn them), and one for each message accepted. Measure an optimised build in a throwaway copy, which is what a person runs:

```bash
./app/build.sh optimised
scripts/test-copy start test-7
touch ~/Library/Application\ Support/pi2-test-7/perf.on
```

Then make the load ([Measuring under load](#measuring-under-load), with `--keep`), work the copy, and read `perf.log`. What the probe cannot see, such as how much of the main thread's time SwiftUI spends laying out, `sample <app pid> 10` shows: a process of your own can be sampled without any permission. Never sample or signal the installed pi².

## CI

Every pull request, and every push to `main`, runs `.github/workflows/ci.yml`. Five of its checks are required before a pull request can merge: `Engine (type-check and tests)` (`npm run check` and `npm run test:macos`) and `App (build)` (the builds and checks above, and `scripts/test-test-copy`), both on macOS, and on Linux `Engine (Linux tests)` (`npm run test:linux`), `Transcript page (tests)` (the conversation page's tests, the release notes' extraction and the changelog entries) and `Scripts (tests)` (`scripts/test-issue` and `scripts/test-issue-hook`). Linux runners start in seconds; GitHub has fewer macOS runners, and a plan can run only a few macOS jobs at once, so the macOS jobs are where a pull request waits.

The engine's CI partition is in `engine/scripts/test-platform.ts`. `npm test` still runs the whole suite on a Mac. The partition discovers the same files automatically: only files verified unchanged on Linux are in its list; a new test stays on macOS until verified. Both halves together cover the whole suite. `credentialsplatform.ts` runs on both deliberately: on macOS it checks that the file store cannot be created, on Linux it checks persistence, permissions and read/modify/delete.

- **Linux, unchanged:** `addedmodels`, `cache`, `chat`, `codemode`, `earlystop`, `everything`, `exec`, `heed`, `latepath`, `limits`, `limitwait`, `localmodels`, `log`, `look`, `mcppath`, `mcpreconnect`, `modellists`, `offered`, `pictures`, `reading`, `rules`, `runcode`, `sections`, `shellpath`, `socket`, `testcopies`, `versions`, `wakes`. The document checks in `chat`, `everything` and `versions` use HTML, not `textutil`; `localmodels` recovers downloads, not processes; computer use and providers in these tests are stand-ins.
- **macOS:** `credentials` directly tests Keychain items and their pieces; `environment` checks agents' variables in the Keychain and their absence from files/backups; `mcpvariables` checks MCP servers' variable values directly in the Keychain; `planwindows` seeds subscriptions directly in the Keychain; `documents` needs `textutil`; `engine` checks Keychain values, agents' variables and `textutil`; `background`, `localrun` and `worktrees` check recovery of what an engine started after it crashed, which needs macOS `ps -E` to prove a process's environment marker belongs to that run. Linux cannot prove that and correctly leaves the process alone, so those tests stay on macOS. `browser` still needs the separate app probe and is outside `npm test` as before.

For tests on other systems **only**, the engine uses `test-credentials.json` inside its data folder in place of the Keychain credential store. These are plain-text fake credentials: use only a throwaway `PI2_HOME` and stand-in providers. This is not a supported way to run pi²; the app, agents' variables and process recovery still need macOS. Selection is by `process.platform`, never an environment variable or setting. On macOS the engine always uses Keychain, and even calling the test-store factory directly refuses to create a file. No sign-ins on a Mac can fall back to it if Keychain fails.

- **A pull request that changes only what no macOS job reads skips them.** A first job, `Which jobs the change needs`, lists the files the commit being tested changes from `main`. If they are all in `docs/` or `changelog.d/` (whose entries the Linux job checks), or are `README.md`, `CONTRIBUTING.md`, `CHANGELOG.md`, `SECURITY.md`, `CLAUDE.md`, `app/VERSION` (which it checks is a single version), or the scripts that `Scripts (tests)` checks on Linux (`scripts/issue`, `scripts/issue-hook` and their tests) or that no CI job tests (`scripts/rerun-if-no-runner`, `scripts/auto-merge`), the two macOS jobs are skipped, and a skipped job reports its required check as passed. Anything else runs them, and so does any doubt: they run unless that job says they need not, so they run if it fails. A push to `main` always runs them. If a macOS job starts reading one of those files, take it off the list in `ci.yml`.
- **A job no runner took is run again by itself.** GitHub cancels a job that no runner picked up in time, with the annotation "The job was not acquired by Runner of type hosted even after multiple attempts", and the check counts as failed. `.github/workflows/rerun.yml` runs after CI and after Release, and `scripts/rerun-if-no-runner` runs the failed jobs again, up to the run's fourth attempt, but only when every job that did not pass ended that way: cancelled, never started, with that annotation, in the newest run on its branch. A real failure, a job cancelled for another reason, or one beside it, is left for a person. `scripts/rerun-if-no-runner <run-id> --dry-run` says what it would do with a run. To run a job again yourself: `gh run rerun <run-id> --failed`.

## Working on pi² with pi²

A development build runs its engine from the checkout it was built in. If that is the copy you work in, an engine edit, a branch switch or a `git pull` there changes the code its engine starts next time, and if that code is broken there is no pi² left to fix it with. So:

- Use an installed release as your everyday copy. It carries its own engine and Node, so nothing you change in a checkout reaches it.
- Do the work in git worktrees (a conversation can move into one of its own; see [worktrees.md](worktrees.md)) or in a separate clone, never in the checkout a running development build came from.
- Test in a development build, which shares no conversations, keys, preferences, macOS permissions or login item with the copy you use: it has a bundle id, a data folder and a Keychain service of its own, and never takes the usual ones ([Build and run](#build-and-run)). When several sessions test at once, give each copy a bundle id of its own as well, as `scripts/test-copy start <suffix>` does; its data folder and Keychain service follow from it. [CONTRIBUTING.md](../CONTRIBUTING.md) has the rules for testing safely.

`app/build.sh` deletes and rebuilds the bundle it makes, `app/build/pi² dev.app` (or `app/build/pi².app` for a release build), so before it builds or deletes anything it looks for a running process whose executable is inside that bundle. If it finds one, it names the process and stops: deleting the bundle would pull the files out from under a running app, and the new build would lose the Accessibility and Screen Recording permissions given to the old one. Build in a worktree or clone instead, or quit that copy. `PI2_REPLACE_RUNNING=1 ./app/build.sh` replaces it anyway. A development build also deletes a development build that an older `build.sh` left at `app/build/pi².app`, under the same check, so that nobody tries out a stale build by its old name; a release build there is left alone.

## Layout

See [architecture.md](architecture.md) for how the pieces fit. In short:

- `engine/src` is the engine; `engine/test` its tests.
- `app/Sources/pi2` is the app. `Theme.swift` holds the palette and the shared pieces (tags, buttons, panels); `EngineClient.swift` is the connection to the engine; the rest is one file per area.
- `app/Sources/ComputerKit` is the part of computer use that touches the screen. See [computer-use.md](computer-use.md).
- `app/Web/transcript` is the conversation page the app shows in a web view; `app/Web/test` its tests. See [transcript.md](transcript.md).
- `app/Sources/BrowserKit` is pi²'s own browser: everything that touches a web page. See [browser.md](browser.md).
- `app/Sources/PaneKit` is the tree of panes behind the conversation area and the ready-made layouts; the app's `Workspace.swift` keeps it and draws it.
- `app/Sources/ComposeKit` is what Return does in the fields that send a message (`sendsOnReturn`, used in place of `onSubmit`).
- `app/Sources/WindowKit` is how the app's windows get their smallest size (`windowMinimum`), and the watch that names a view whose size does not settle (`SizeWatch`).
- `app/Sources/FileLinkKit` is what a file linked in a conversation is once its path is made whole, and what a click and the link's menu do with it ([transcript.md](transcript.md#files-on-this-mac)).

## Conventions

- The engine is the only writer. If the app needs to change something, it asks the engine.
- Secrets go in the Keychain, never in files and never on a command line. The non-macOS test stand-in described under CI holds fake credentials only and cannot be used on a Mac.
- Say what is and is not tested in the pull request.
