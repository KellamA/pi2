# Commands left running in the background

Some commands are not meant to finish while the agent waits: a development server, a build that watches for changes, a test copy of an app. An agent can start such a command, carry on with its work, read what the command prints later, and stop it when it is done.

The code is `engine/src/background.ts`.

## What the agent has

- **Starting one** is the ordinary command tool with one more argument: `bash` with `background: true`. The call returns after about a second with the command's id (`bg-1`, `bg-2`, …) and what it has printed by then, so a command that fails at once (a program that is not there, a port already taken) is reported as failed right away. Like any `bash` call, it is started only once the calls before it in the same answer have ended, so it sees a script the call before it wrote ([architecture.md](architecture.md#the-calls-of-one-answer)).
- **The `background` tool** works with the commands the conversation started:
  - `list`: each command's id, whether it is running or how it ended, and how much of its output has not been read.
  - `read`: what a command has printed since the last read, standard output and errors together, and whether it is still running. With `wait`, a read that finds nothing new waits up to that many seconds (600 at most) for more output or for the command to end. With `tail`, it gives the last lines instead, read or not; looking at the end does not change what counts as read.
  - `stop`: stops the command and everything it started, and gives what it printed since the last read.

A conversation reaches only its own commands. A sub-chat's commands are its own, not its parent's.

The command runs the way a command that is waited for runs: through `/bin/bash -c`, in the conversation's folder, with the same environment, and with no input. It should run the long-lived program itself, without `&` or `nohup`: when the command's own process ends, whatever it left running in the background is stopped with it, so that "ended" means nothing of it is still running unseen.

## Asking first

Starting a background command is a `bash` call, so it is judged exactly as any command is:

- Under **Ask first** it waits for you. The approval is a command's approval, with the same choices, and says that the command will be started and left running: "Forge wants to run a command in the background", and under the command, how long it runs and that Activity lists it.
- **Always Allow bash Here** covers it, as it covers any command in that conversation.
- A [command rule](rules.md) covers it too: a rule for `npm run dev` lets the agent start `npm run dev` in the background without asking, in that folder, and in the same folder of every worktree pi² made from that repository. Starting it this way is the point: `npm run dev &` is a line the rules cannot judge, and always asks.
- With **Full access** nothing asks. With tools off or **Read files** there is no shell, and no `background` tool either.

Listing, reading and stopping never ask. They change nothing but the commands the conversation itself started.

## How long it runs

There is no limit on how many background commands there are, or on how long one runs. The [limits](architecture.md#how-long-a-command-may-run) for a command in the foreground (2 minutes, or up to 10 with `timeout`) are not for them. A call can give one a limit of its own by passing `timeout`.

A background command runs until one of these:

- it ends by itself;
- the agent stops it;
- you stop it, in **Activity**;
- its conversation is archived or deleted, or the conversation its sub-chat belongs to is, or the agent that opened its sub-chat archives it ([archive.md](archive.md#sub-chats-an-agent-puts-away));
- the worktree it runs in is removed;
- pi²'s engine stops.

Stopping the agent's answer does not stop its background commands: they are meant to outlast an answer. A conversation with a background command still running is not [archived on its own](archive.md#archiving-on-its-own) for being unused.

Stopping sends the command and everything it started a request to end (SIGTERM), and ends them outright (SIGKILL) if they are still there three seconds later. The stop is told as that stop ("was stopped by the agent", "was stopped by the person") whether everything went at once or part of what the command started outlasted its own process for a moment, which on a busy Mac it can: the stop was of all of it either way.

## Seeing and stopping them

**Activity** has a **Background commands** section whenever any are running: each command, the conversation and agent that started it, the folder it runs in, how long it has been running, **Output**, **Open** for its conversation and a **Stop** button. The page's subtitle counts them.

**Output** opens a window of the command's own: the command, the conversation that started it (which it opens), the folder, whether it is running and for how long or how it ended, a **Stop** button while it runs, and what it has printed, standard output and errors together. More shows as it is printed, and the window follows the end while it is scrolled to the end. The output is plain text, exactly as the program printed it: nothing in it is followed or interpreted. It is what pi² keeps (see below), so when the command has printed more than that the window says how much of the start it does not have. The window stays useful after the command ends, for as long as pi² keeps its output, and says so when it no longer does. Reading the output here does not change what the agent has read: what it has not read is still there for it.

**In the conversation**, a strip above the message field, like the task list's, names the commands the conversation has running in the background, with those of its sub-chats ("in sub-chat …"): each with its id, how long it has been running, **Output**, and **Stop**. It is gone when none is running.

**The menu bar**'s list of what is running names them too, after the conversations at work; choosing one opens its output.

In the conversation:

- Starting one is a row like any command's: "Started `npm run dev` in the background", with its id. It opens to the command and what it had printed when the call returned.
- Reading and stopping are rows of their own: "Read the output of `npm run dev`", "Stopped `npm run dev`". They open to what the agent was given.
- A command that is over by the time the call that started it returns shows there: the row is marked failed if it exited with an error, and opens to what it printed.
- Any other end that the agent did not ask for gets a line of its own in the conversation, like the one for a context reset: "Background command bg-2 exited with code 1: npm run dev", "… was stopped by the person: …", "… was stopped because the conversation was archived: …". So does an end the command came to by itself that took something it had left running with it: "… finished, and what it had left running was stopped with it: …". A stop is never worded that way, since a stop was meant for everything the command started.
- Each of these rows and lines has **Output** at its end, which opens the command's output window, as Activity's Output does. A row gets it once the engine has answered the call, so a call refused for an id the conversation does not have gets none. For a command whose output pi² no longer has (one of more than the last 50 to end, or one from before the engine last stopped), the window opens and says so.

## What the agent is told when one ends

An agent is not woken when a background command ends. Starting an answer nobody asked for, at a moment nobody chose, is not something a command ending should do.

Instead, every request the agent makes carries a short list of the conversation's background commands: the ones running, since when, and the last five that are over, with how each ended ("it exited with code 1", "it was stopped by the person"). So the agent finds out at its next step if it is working, or when it is next sent a message, and it still knows what it left running after its context was reset or summarized. `list` and `read` say the same, with the output.

## The output that is kept

A command's output comes to the engine as it is printed, and the engine keeps only the end of it, in memory: the last 128 KB, cut back whenever twice that has piled up. Nothing is written to disk.

- A read gives the oldest output not yet read, at most 30,000 characters or 1,500 lines of it, and says how much more is waiting.
- If the command printed more than is kept between two reads, the read says how many characters were let go.
- The output of a command that has ended stays readable while the engine runs, for the 50 most recently ended commands.
- When the engine stops, the output goes with it.

## When the engine stops

**A clean stop** (quitting pi² without keeping agents running, an update, restoring a backup) stops every background command: SIGTERM, a second and a half, then SIGKILL. The app waits five seconds for the engine to stop before it restores a backup, so the engine does not wait for a command that ignores SIGTERM: it ends it with SIGKILL and goes on. `engine.log` says how long each clean stop took ("stopped cleanly in 1519 ms: 1438 ms of it waiting, and 12 ms of processor time"). The waiting and the processor time leave out the time a busy Mac kept the engine from running, so together they are what the stop would take on a quiet Mac. When the engine starts again it writes into each conversation that its command "ended when pi²'s engine stopped", and the agent is told the same at its next request. The command is not started again.

**An engine that crashed or was killed outright** leaves its background commands running for the moment. The next engine stops each one, with everything it started, and says so in the conversation. It does this the way it does for a worktree's [set-up command](worktrees.md#a-set-up-command), with the same code: each background command leads a process group of its own and is started with a random value in the environment variable `PI2_RUN`, which everything it starts inherits, and pi² keeps a record of the group, of when its first process started, and of that value. The next engine stops only what it can tell is the same, because a process number is used again by other programs once it is free: the whole group while its first process is still there and started when noted, and otherwise the processes in that group whose environment holds the value. Anything it cannot be sure of is left alone, and the conversation says so with the process group's number; when part of what the command started was stopped and part left, the line says both. Activity's notice that the engine stopped unexpectedly lists each such command with its conversation and what became of it: stopped, stopped in part, left alone, or already ended. That covers the programs that come with macOS (`/bin/sh`, `sleep`, `tail`), whose environment macOS does not let another process read, when the command's own first process is gone.

## For developers

- `engine/src/commands.ts` wraps `bash`, as it does for the time limit: a call with `background: true` goes to `startInBackground` in `engine/src/background.ts` instead of pi durable's own `bash`. Because the call is still `bash`, the approval hook in `engine/src/extensions.ts` needs to know nothing about it, except to put `background: true` on the approval it shows.
- What a command's process is noted as, and how the next engine stops what an engine that died left running, is `engine/src/processes.ts`, which set-up commands (`engine/src/worktrees.ts`) use too: one reading of `ps`, the run's marker, and `stopLeftOver`.
- Running commands and recently ended ones are held in memory, by id. A session document, `pi2.background`, holds `next` (ids are not used again) and a record of each running command: `{ id, conversationId, command, cwd, startedAt, process: { group, start, marker } }`. A record is removed when its command ends, and is what the next engine goes by when the last one stopped with commands still running.
- The engine sends `{"event": "background", "commands": [{ id, conversationId, rootConversationId, command, cwd, startedAt }]}` when the set of running commands changes, and to each app as it connects. `background.stop { id }` is the person's Stop.
- `background.output { id, from?, wait? }` is the person reading a command's output, running or among the ended ones still kept. It answers `{ id, conversationId, rootConversationId, command, cwd, startedAt, running, stopping, ended: { at, how, failed } | null, kept, total, from, dropped, output }`: `output` is what is kept from character `from` on (characters count as JavaScript counts them, from the first one the command printed), at most the last 128 KB; `total` is how many it has printed in all, where the next request starts; `dropped` is how many after the `from` asked for were let go before they could be shown; `kept` is false for a command an engine that stopped had started; `how` is worded to follow "It" ("exited with code 1 after 4 seconds"). With `wait` (seconds, at most 30, or `PI2_OUTPUT_WAIT_SECONDS` when that is set, which the test uses), a request that finds nothing new past `from` waits for more output or for the command to end. The output window asks with `wait` from where the last answer ended, and leaves half a second between answers, so it shows output as it arrives without asking over and over, and twice a second at most however much is printed. It never touches what counts as read for the agent. An id the engine no longer has is refused with a plain message.
- A command's end is written to its conversation as an entry of kind `pi2.background` with `{ id, command, how, seconds }`, which the model never sees; the app is sent it as a marker, with `details: { background: { id } }` so the line can open the command's output. None is written for a stop the agent asked for, or for an end the call that started the command reported: those are in their calls' rows.
- The list the agent is told is the prompt section `background_commands`. It has no running times in it, so it is sent again only when a command starts or ends.
- After an engine that stopped unexpectedly, the `recovery` event carries `background`: one `{ id, conversationId, rootConversationId, title, command, outcome, group }` for each command the last engine left, where `outcome` is `stopped`, `partly`, `gone`, `unsure` or `unknown` (left alone before its process was noted) and `title` is the root conversation's. A feature adds fields to that event with `recovery()` (`engine/src/features.ts`).
- Features can now take part in two more moments (`engine/src/features.ts`): `putAwayChanged`, when a conversation is archived, deleted or restored, and `stopping`, when the engine stops cleanly.
- The app's side is `app/Sources/pi2/BackgroundViews.swift` (the output window and the conversation's strip), with the rows in `ActivityViews.swift` and `MenuBar.swift`. The conversation page's Output buttons send `{type: "output", id}`, which `TranscriptBridge` acts on only for an id this conversation's results and lines name ([transcript.md](transcript.md#messages-between-the-app-and-the-page)). A development build opens a command's output window at launch with `PI2_SHOW=output:<id>` ([development.md](development.md)).
- `npm run test:background` (part of `npm test`) runs `engine/test/background.ts` against a real engine: start, read, wait, tail, list and stop; a stop's wording when part of what the command started outlasts its own process (it ignores SIGTERM, so the SIGKILL ends it); a command outliving the default limit; what bounds the output, also as the person reads it; approvals, rules across worktrees and Always Allow; ending by itself; a time limit of its own; Activity's stop; the person reading a command's output from any point, waiting for more (a wait that only output or the command's end can cut short, since `PI2_OUTPUT_WAIT_SECONDS` makes it outlast the test's patience), without changing what the agent has read; archiving, deleting (also of a sub-chat's parent) and removing a worktree; a clean stop of the engine, with a command that ignores SIGTERM, which has to fit in the app's five seconds by the engine's own account of the stop; an engine killed outright, and Activity's notice of it; one killed whose command's own process then ended, leaving what it had started; and the same where only part of what it started carries the marker.
- The demo model answers `/background <command>` with `bash` and `background: true`, and `/tool background {"action":"read","id":"bg-1"}` with the `background` tool.

## Known limits

- A background command gets no input, like any command an agent runs.
- Its output is not kept across an engine restart, and only the last 128 KB of it is kept at all.
- After a crash, with the command's own first process gone, what it started can be stopped only if its environment can be read, which macOS does not allow for the programs that come with it. What cannot be told apart is left alone, and the conversation says so.
