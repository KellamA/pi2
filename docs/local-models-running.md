# Models on this Mac: running them

pi² can run a model on the Mac itself, with the Strata engine, and use it like any other model (#173). It is built in pieces: getting the engine and a model onto the Mac and setting them up in Settings (#292, [local-models.md](local-models.md)), running them (#291, this page), and trying the real thing (#293). The two halves meet at `local-models.json` in the data folder, which the downloads piece writes and the running piece reads.

The code that runs them is `engine/src/localrun.ts`, with everything particular to the real engine in `engine/src/localengine.ts`, and the provider in `engine/src/providers.ts`. The app's side is `app/Sources/pi2/LocalModelViews.swift`.

## In the model selector

A model that is set up is always offered, under **On this Mac**, whether or not it is running. Its context size is the one it was set up with, and is what pi² goes by to decide when to summarise a long conversation. It is marked as seeing pictures when it was set up with its picture reader, and as thinking, with Off, Low, Medium, High and Extra High (sent as Strata's `reasoning_effort`; Off is `none`). Its use counts tokens only, as for any model without a price.

## When it runs

A model on this Mac starts when a conversation starts using it, and stops a minute after the last one stops.

A conversation **uses** the model while its model is that one and:

- it is open in one of the agent view's panes (whichever page the window shows, and whether or not the window is open), or is chat mode's chat on screen (whichever side the window shows, since each keeps what it shows while the other is up); or
- its agent is working: a run, a sub-chat's run, or a scheduled one, whether or not it is open.

It stops counting when its pane is closed or shows another conversation, when it is archived or deleted, or when its model is changed. An idle open conversation keeps the model loaded: it is not started and stopped between messages.

So it **starts** when a conversation with it chosen is opened or created, when a conversation's model is switched to it, or when work starts with it. The conversation says it is starting, with what the engine says it is doing ("mapping the experts") or how far it has got, and a message sent meanwhile waits and is answered once it has loaded.

It **stops** once nothing has used it for a minute, so that switching between two conversations does not unload and load it again. Activity shows the time left.

**Quitting the app** closes its panes. When the engine keeps running after the app quits (the login item, or "Keep agents running after I quit pi²"), a model only open conversations were using stops a minute later; one an agent is working with stays until that work ends. Nobody can see or type into a pane of an app that is not running, a loaded model holds tens of gigabytes, and opening the app again shows the same panes, which start it again.

**Several conversations** share the one loaded model.

## Seeing and stopping it

**Activity** has a section, **Models on this Mac**, while one runs: its name, whether it is loading or since when it has been loaded, how much memory it and what it started hold (resident, by `ps`, the model's mapped file included), how many conversations use it or how long until it stops, its log, and **Stop**. The **menu bar** lists it under Running, with Stop.

Stopping it by hand does not break the conversations using it: an answer it was giving is cut off, and the next message starts it again. It is not started again by itself for the conversations already open, only for a message, or for a conversation that starts using it.

## When it cannot start, or stops unexpectedly

If the model cannot be loaded, the conversation says why, shows the last lines the engine printed and offers its log; a message sent to it gets the same answer, with where the log is. The next message tries again. The log is `local/logs/<model>.log` in the data folder, written afresh at each start. It is not part of a backup.

If it stops unexpectedly while loaded, an answer it was giving fails, and pi² asks again as it does after any dropped connection, which starts it again. It is not otherwise started again by itself; the next message does.

## The process

pi²'s engine starts it, never the app, as it starts everything it leaves to run on its own ([background.md](background.md)): bound to 127.0.0.1 on a port pi² picks, with a key made for each run in its environment (never on its command line, which any process can read), leading a process group of its own, with the run's marker (`PI2_RUN`) in its environment and its run's file open, as the engine's other runs have them. Its group, when its first process started, and the marker are kept in a session document, `pi2.local`.

- **What it starts** is followed too. Strata's server starts its engine and picture reader in process groups of their own (#290), which a signal to the server's group does not reach. So pi² lists, every ten seconds while it runs and again as a stop begins, every process the server started, at any depth and in any group, and once the server has gone ends whatever of them is still the same process (the same number and start time). Strata's server ends them itself when asked to stop, in about two seconds, and its watchers end them within a second when it is killed ([strata.md](strata.md#stopping)); this is for when neither happens. It also lets Activity count their memory, the engine's 60 GB among it.
- A **clean stop** of the engine stops it: SIGTERM, a second and a half, then SIGKILL for whatever of its group, and of what it started, is left, inside the five seconds the app gives the engine.
- An engine that **died** (killed outright, or crashed) leaves it running for the moment. The next engine stops it as it stops a background command left that way (`stopLeftOver` in `engine/src/processes.ts`): the whole group while its first process is still the one noted, else only the processes carrying its marker or holding its run's file. What its first process started in groups of their own, listed at the moment that process is proved the same, is ended a few seconds later if it is still there. `engine.log` says what became of it.
- A stop by hand, or for want of anyone using it, gives it five seconds to end before SIGKILL. A crash of the server is followed by the end of what it started, five seconds later.

Loading may take up to 20 minutes before pi² gives up on it and says so.

## For developers

- **What is set up** comes from `local-models.json`: `{ "engine": { "version", "path", "folder", "control": { "version", "folder" } } | null, "models": [{ "id", "name", "pack", "path", "contextSize", "config", "options" }] }`: the engine's executable, its whole package and Strata's control package; the model's first file and, once Strata's installer has prepared it, its run config. `localSetupReader` reads it again whenever it changes. Of `options`, `vision` with `visionFile` and `parallel` are used; other keys are kept and ignored.
- **The engine's description** is `STRATA` in `localengine.ts`: the program, arguments and environment that serve a model on a port, the variable it reads its key from, where its OpenAI-compatible API is, the path that answers 200 once it has loaded, and how far loading has got, or what it is doing, from a line it prints. Nothing else assumes anything about the real engine. As #290 found, Strata's HTTP server is its control package's `serve/server.py`, which starts the executable with a prepared model's run config, and every Strata command runs with `HOME`, `XDG_DATA_HOME` and `STRATA_HOME` in `local/strata/` of the data folder, `PYTHONNOUSERSITE=1` and no `PYTHONHOME` or `PYTHONPATH` (`strataEnvironment`), so nothing goes to the person's own folders and no Python of theirs is used. A model without a run config, or an engine without its control package, is started with the executable's own flags, as the stand-in is. None of it has been run against the real Strata yet; #293 does that, and corrects it there and in the stand-in.
- **A request** to `local/<id>` goes through `localProvider` in `providers.ts`, an OpenAI-compatible provider like an endpoint of one's own. Before each request it takes a lease from the runner (`lease` in `localrun.ts`), which starts the model if need be, waits until it has loaded, and holds it while the request runs; the request then goes to wherever it runs now, with that run's key. A model that cannot start fails the request with words pi-ai does not treat as worth asking again, so the run ends with the reason instead of starting it over and over.
- **Who uses it** is worked out again whenever it may have changed: which conversations the apps show (`shownChanged`), which have work running (`runsChanged`), a model changed (`modelChanged`), a conversation archived or deleted (`putAwayChanged`), and a request ending.
- **Requests:** `conversations.shown { ids }` from the app, with the conversations in its panes (and chat mode's current chat), whenever that changes and as it connects; the engine keeps one set for each connection, so an app that quits shows nothing. `local.start { id }` starts a model and answers once it is ready, or with why it is not (Settings' Try it). `local.stop { id }` is the person's Stop. `local.status` (localmodels.ts) answers what is set up and, from this feature's `localStatus()`, `running` and `ended` below; a change to them sends `local.running`, and `local` through `localChanged()`.
- **Events:** `{ "event": "local.running", running, ended }` on every change and to each app as it connects. A running entry is `{ id, name, status: "starting" | "ready" | "stopping", startedAt, readyAt, progress, stage, memory, pid, users, stopsAt, log, recorded }`: `progress` from 0 to 1 when the engine says, `stage` what it says it is doing while it loads, `memory` the bytes it and what it started have resident (by `ps`), `users` the conversations using it, `stopsAt` when it stops unless someone uses it by then, `recorded` whether its process is on record for the next engine. `ended` says, for each model, how its last run ended: `{ at, how, failed, lines, log }`.
- **A conversation's state** has `local: { model, name, status: "starting" | "ready" | "stopping" | "stopped" | "failed", since, progress, stage, error, lines, log }` when its model is on this Mac, and `null` otherwise.
- **The test** is `engine/test/localrun.ts`, with a stand-in for the engine, `engine/test/localserver.ts`, that takes the same command line, serves the same API, loads only once the test lets it, and can be told to fail to load, to crash in the middle of an answer, to hold an answer, to start a program of its own in a group of its own (as Strata's server starts its engine) and to ignore SIGTERM. `PI2_LOCAL_GRACE_SECONDS` sets the grace period, which the test makes an hour for one engine and nothing for another.

## Still to check against the real engine (#293)

#290 ran Strata's server as `localengine.ts` now starts it (`server.py --engine strata --config <run config> --host 127.0.0.1 --port <n>`, the key in `STRATA_API_KEY`): it does not listen until the model is loaded, prints its stages with no percentage, calls tools and sees pictures in OpenAI's form, thinks in `reasoning_content`, ends the engine it started within about 2.3 seconds of SIGTERM, and holds about 60 GB resident for IQ3_S. Through pi², still to see:

- Whether to wait for its ready file (`--ready-file`) rather than asking `/v1/models`, and `--shutdown-timeout` against the five seconds a stop by hand gives it.
- Preparing a pack (the run config) with Strata's installer, which neither the downloads nor this part does yet, and the same `HOME`, `XDG_DATA_HOME` and `STRATA_HOME` (`strataEnvironment`) for it.
- That the first start, about three minutes with the kernels compiled once, and a first long prompt, about a minute, show as they should, and that a message waits through them.
- Memory as Activity shows it against Activity Monitor's.
- A kill -9 of pi²'s engine with the model loaded: the next engine's stop of the server, and of the engine it started.
- Two requests at once (one slot by default: the second waits) and `parallel`.
- Which thinking level a new conversation gets, since thinking is long.
