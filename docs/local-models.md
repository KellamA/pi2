# Models on this Mac: getting them

pi² can run a model on the Mac itself with the [Strata](https://github.com/Niko1221/Strata) engine (#173). This page is about the part that gets the engine and a model onto the Mac and sets them up (#292, #293): Settings › Providers › **On this Mac**. Starting and stopping a model is another part's (#291, [local-models-running.md](local-models-running.md)), which reads what this one writes. What the engine and the model need, as found by running them on a Mac (#290), is in [strata.md](strata.md).

The engine does all of it (`engine/src/localmodels.ts`, with `download.ts` and `localcatalog.ts`, and Strata's own commands as `localengine.ts` describes them); the app shows it (`app/Sources/pi2/LocalModelsSettings.swift`).

Setting a model up has three parts, each shown in its row in Settings: the engine (downloaded, checked, unpacked and installed where Strata's server finds it), the model's files (downloaded, or taken from files already on the Mac, and checked), and **preparing** the model once with Strata's own setup. Only then is it offered in the model menus.

## What can be downloaded: the catalog

`engine/src/localcatalog.ts` is data, and the one place it is written down:

- **The engine**: a pinned version of Strata's Metal engine for Apple silicon (the engine package alone, not the desktop app), and of Strata's control package, which holds the OpenAI- and Anthropic-compatible server that starts the engine and has a Python of its own: the engine has no HTTP server (#290). Each archive with its address, size and SHA-256.
- **The model packs**: for each, every file to download (address, size, SHA-256), the disk space preparing it takes as well, the memory it needs and from how much memory Strata recommends it, a plain note on what is lost against the others, its licences (with a part the person must read quoted in full, `quote`), the names Strata's setup knows it by and the run config it writes for it (`prepare`), and, for one pi² cannot set up yet, why.
- **Where the packs come from**: each repository at the commit Strata's own setup pins (its `HF_REVISIONS`), `https://huggingface.co/<repository>/resolve/<commit>/<file>`, never `resolve/main` (#342). A repository that replaces a file on `main` would otherwise fail every download until pi² was updated; Unsloth's had done so by the time this was checked, and the catalog's Unsloth sizes and checksums, read from `main`, were not the files Strata prepares.
- **The figures**: memory per token of context, the share of memory Metal lets one program keep (0.84: Metal's own `recommendedMaxWorkingSetSize` on the M5 Max with 128 GB, 115.4 of 137.4 GB, not the three quarters first guessed), the context sizes offered and the largest Strata measured on a Mac (32K), and the free space a download always leaves (10 GB). The pack's memory figure (63 GB for IQ3_S) is Strata's; pi² saw IQ3_S hold 59 to 62 GB resident, picture reader and server included, at a 64K context (#293).
- **Which pack to recommend**: an order of preference; the first that fits the Mac's memory is recommended.

Raising the engine's version, correcting a pack's memory figure, or adding a pack is a change to that file, reviewed like any other.

### Nothing that was not checked is run

Every checksum is written in that file in advance. pi² never takes one from beside a download: not a `SHA256SUMS` file, not a release's digest, not a server's header. So someone who can change what a server sends cannot change what pi² accepts.

- A file grows as `<name>.part` and gets its name only once its size and SHA-256 match. Its checksum is worked out as it arrives, and from the part already on disk when a download carries on.
- Both archives are downloaded and checked before either is unpacked, each into a folder of its own; entries with absolute paths or `..` are refused. Only then is the executable made runnable. Then the engine's archive is installed into Strata's own component folder with the control package's `strata.py components install-file`, which checks the package's signature and every file again and runs `strata --version` once: Strata's server finds its engine there, not by a path (#290). The archives are deleted after that.
- Strata's setup takes a pack's files as they are (it checks each is as long as its header says, not its checksum), so pi² checks every file before setup sees it, as above.
- A file that does not match is deleted, and the person is told that nothing in it was run.
- Only HTTPS is used (a stand-in on 127.0.0.1 is allowed for tests), and a redirect to anything else is not followed.

### A newer engine

A newer engine reaches the person only with a pi² update that pins it, since pi² must know its checksum first. When the version installed is not the one pinned (pi² was updated), the engine's row says that version is available and offers **Update…**, which shows the licence again and replaces the old version once the new one is set up; the models are then prepared again by themselves ([below](#preparing-a-pack)). pi² does not look for Strata releases newer than its pin: it could not run one anyway. An engine 0.8.0 set up, which it did not install into Strata's component folder (`component` in its entry), is shown the same way, as "set up by an earlier pi²: update it to run models".

## Downloads

- **Licences first.** The engine's licence, and each pack's (the model's own and the quantiser's), are shown in the sheet before its download, which starts only on **Agree and Download**. `local.engine.install` and `local.model.install` refuse without `accept: true`.
- **The disk is checked first.** A download is refused if it, with the other downloads under way on the same disk, would leave less than 10 GB free, and the person is told how much it needs, how much is free, and that they can choose another folder for models. A disk that fills all the same stops the download with words that say so, keeping what it has.
- **It carries on.** `local-setup.json` in the data folder lists the downloads under way and whether each is running, paused or stopped. The next engine carries on with those that were running, after pi² quits, the engine restarts or is killed. A dropped connection, a stall (nothing for a minute) or a busy server (HTTP 429 or 5xx) is tried again by itself, waiting longer each time, eight times, each time from where it stopped (an HTTP range request); after that the download stops with a message, and **Try Again** carries on.
- **Pause, Resume, Cancel.** Pausing keeps what it has. Cancelling removes it all: the parts, any of the pack's files already finished, and what preparing it made. A model set up before that is being prepared again (below) has no Cancel: Remove is what takes it away.
- **Progress** is sent as `local.progress` events, about twice a second while a download runs, and the whole state as `local` whenever it changes.
- **Out of backups.** The engine and models are in `local/` in the data folder (`local/engine/<version>/` and `local/control/<version>/`, `local/models/<pack>/` with `prepared/` in it, `local/strata/` for what Strata keeps of its own, `local/configs/`, `local/run/` and `local/logs/`), or a folder the person chooses for models. pi²'s backup copies named files only, never these; each folder pi² makes is marked for Time Machine to skip (`tmutil addexclusion`, which needs no permission).
- **What a person reads when it fails**: no network ("pi² could not reach huggingface.co. Check the network connection…"), a dropped connection, no space, a checksum that does not match, a server that refuses ("huggingface.co refused the download (HTTP 403 Forbidden). The file may have moved or been withdrawn; a newer pi² may know where it is now."), a busy server, and preparing that stopped (below).

## Files already on this Mac

The person may have a pack's files already: from Strata itself, another app, or a download of their own. **Agree and Use Files on This Mac…**, beside Agree and Download in the sheet, asks for a folder: the one that holds the `.gguf` files, or one above it, such as Strata's own data folder. `local.model.install` takes it as `from`.

- pi² looks in that folder and up to three levels below it (not in hidden folders or through links) for each of the pack's files by its name and size. A file found is **cloned** into the pack's folder with `cp -c` (`clonefile`, which on the same APFS volume takes no time and no room; Node's own clone-or-fail is not there on macOS), or copied where the disk cannot clone, and then checked against its SHA-256 exactly as a download is. One that matches is used; one that does not is left where it was, said in `engine.log`, and downloaded instead. What is not found is downloaded. The person's own files are never changed or moved.
- The disk check counts a file that will be cloned as taking no room.
- The draft layer Strata's setup fetches (below) is looked for there too: a Strata `mtp` folder, with its `mtp-inventory.json` and `tensors/`. Its tensors are cloned beside the pack, and Strata's setup checks each against its own pinned SHA-256, fetching only what is missing or wrong. So someone who has run Strata before downloads nothing at all.
- A folder that holds none of the pack's files is refused at once, with the names it looked for.

With the files from #290's trial on the same disk, setting up IQ3_S this way took about 20 seconds to clone and check the 84.5 GB, and 55 seconds to prepare it.

## Preparing a pack

A pack whose files have all matched is not ready to run: Strata's own setup prepares it once (#290, #293). pi² runs it, from the control package, as the last part of setting the model up:

```sh
STRATA_CONTROL_INSTALL=1 <strataEnvironment> <control>/python/bin/python3 <control>/setup.py \
  --family qwen --model IQ3_S --gguf-dir <the pack's folder> --data-dir <the pack's folder>/prepared \
  --vision gpu --no-start --no-browser --yes
```

- **Where:** in the control package's folder, with `HOME`, `XDG_DATA_HOME` and `STRATA_HOME` in `local/strata/` of the data folder, as every Strata command pi² runs (`strataEnvironment` in `localengine.ts`), and with no `PYTHONHOME` or `PYTHONPATH`. What it makes goes in `prepared/` beside the pack's files: the pack folder (1.5 GB) and the draft layer (the 5.2 GB of tensors it fetches from Qwen's original model, kept so that preparing again does not fetch them again, and the 0.9 GB file packed from them). `--vision gpu` whenever the pack has a picture reader, so that turning pictures on later needs no preparing again; the context size is pi²'s to set at each start ([local-models-running.md](local-models-running.md#the-process)).
- **What it writes:** the run config, `strata-<pack>.json`, in the control package's folder (setup takes that folder for its home). pi² copies it to `local/configs/<model>.json` in the data folder and names it in the model's entry as `config`, with the control package's version as `preparedWith`. Only then is the model listed in `local-models.json`, and offered.
- **Progress:** setup prints a line for each of its steps (`=== Step 6: preparing the model for Strata ===`; there are seven, and no step 3 on a Mac) and, while it fetches the draft layer, `MTP draft layer:   0.87 / 5.21 GB (16%)`. pi² reads those (`STRATA_SETUP.read`) into the download's `prepare`: `{ step, stage, fraction, startedAt }`, which Settings shows under the model's name with a bar. Everything it prints goes to `local/logs/<model>.prepare.log`.
- **How long:** 55 seconds on the M5 Max when the draft layer's tensors were there already; #290 measured about 7 minutes on a busy Mac, and fetching the tensors takes about 6 minutes more on a good connection.
- **One at a time:** two would share Strata's settings and the control package's folder, so a second waits, and says so.
- **Resumable:** the download stays in `local-setup.json` at the `prepare` stage until setup has finished. Paused, or stopped with the engine, it is run again from the start, and setup keeps and skips what it had done (a pack folder already made, tensors already fetched, each checked again). Its process leads a group of its own with the run's marker, as a background command does, and is noted in `local-setup.json`: an engine that dies leaves it running, and the next one stops it, if it is provably the same (`stopLeftOver`), before running it again. A pause or a clean stop of the engine sends its group SIGTERM, then SIGKILL three seconds later.
- **When it fails:** setup ends with `  [X]  <what>` and a line of what to do, and a non-zero exit. The download stops with that in words, the log's place and Try Again: "Qwen3.8-Flash-Next (IQ3_S) could not be prepared. Strata's setup stopped: the draft layer's download keeps stopping (exit 3) run setup again - what is downloaded is kept. What it printed is in ~/…/qwen3.8-flash-next-iq3-s.prepare.log. Press Try Again: what was done is kept." Show Log opens the log.
- **Without the engine:** a pack downloaded before the engine is set up, or while it is set up by an earlier pi², waits (`state: "waiting"`): "Downloaded and checked. Preparing it for Strata needs the engine: get Strata above, and preparing starts by itself." Once the engine is set up, it does.
- **After an update of Strata:** a new control package means new run configs, since the old one names files inside the old control package's folder. A model whose `preparedWith` is not the control package installed, or whose run config is gone, is prepared again by itself, keeping its files and settings; meanwhile it stays listed, marked as being prepared, and is not started. Setup reuses a draft layer it finds in another pack's `prepared` folder, so removing a model prepares again any other whose run config named its folder.

## What fits this Mac

pi² reads the Mac's memory and, for each pack, says one of: fits (the Mac has at least the memory Strata recommends it from), fits with little left for other apps (it fits in the share Metal allows, about three quarters), too big to stay in memory (it runs, reading from the SSD, much more slowly), or too little memory to run at all (under 16 GB). It recommends the first pack of the catalog's preference that fits, else one that fits tightly, else the smallest. An Intel Mac is told that Strata runs only on Apple silicon, and nothing is offered.

## Configuring

A model's context size (16K to 262K tokens), whether it reads pictures (for a pack with a picture reader), and how many requests it runs at once (1 to 4). Each context size shows about how much memory the model takes with it; above what Metal lets one program keep, the sheet warns that it would read from the SSD or not start, and above 32K that Strata has not measured it on a Mac (its setup says the same of 64K: "measured on the Mac up to 32768 (needles found at 8K-32K); longer is kept"). The defaults are what Strata's setup chooses: 32K below 96 GB of memory and 64K from 96 GB, pictures on, one request at once. Nothing has to be pressed for them to apply, and none needs the model prepared again: the running part writes them into the run config at each start.

## Trying it

**Try It** starts the model with `local.start` (#291), then `local.model.try` sends it one message through the providers, as the model `local/<id>`, with thinking off, and shows the answer. The message is longer than 64 tokens on purpose: the first prompt that long after a first start makes Strata compile more of its kernels, which took a minute in #290, and Try It takes that out of the person's first conversation.

While it starts, the row says what the engine says it is doing and for how long, ticking: "Starting it on this Mac (0:42): mapping the experts from the model files … The first start after setting it up can take about three minutes, while macOS prepares Strata for this Mac's graphics, and the Mac may be slow meanwhile; later starts take about 20 seconds." Then "Loaded. Asking it a first question…", and the answer.

## What the other parts read

`local-models.json` in the data folder, written whole each time (to a temporary file, then renamed):

```json
{
  "engine": { "version": "0.1.60", "path": "<the strata executable>", "folder": "<the engine package>",
              "control": { "version": "0.1.61", "folder": "<the control package>" }, "component": true },
  "models": [{
    "id": "qwen3.8-flash-next-iq3-s", "name": "Qwen3.8-Flash-Next (IQ3_S)", "pack": "IQ3_S",
    "path": "<the pack's first file; the others are beside it>", "contextSize": 65536,
    "options": { "vision": true, "visionFile": "<the picture reader>", "parallel": 1 },
    "config": "<pi²'s copy of the run config Strata's setup wrote>", "preparedWith": "0.1.61"
  }]
}
```

`engine` has `folder` (the whole engine package, which holds `strata`, `strata-vision` and the Metal kernels it compiles as it starts), `control: { version, folder }` (the control package, with Strata's server and setup) and `component` (installed where Strata's server finds it). It is null until both are set up. A model is listed only once all its files have matched and Strata's setup has prepared it; `config` goes while it is being prepared again. As the engine starts, an entry whose files were removed by hand is dropped, and one whose run config was removed is prepared again.

## Requests and events

| Request | What it does |
|---|---|
| `local.status` | What is installed, the catalog with what fits, the downloads, the folder for models; and what any feature adds with `localStatus()` (the running part's state) |
| `local.engine.install { accept }` | Downloads the pinned engine, or carries on |
| `local.engine.remove` | Removes the engine (and stops its download) |
| `local.model.install { pack, accept, from? }` | Downloads a pack into the folder for models, or carries on, and prepares it; `from`, a folder of the person's, is looked in first ([above](#files-already-on-this-mac)) |
| `local.model.remove { id }` | Removes a model's files, what preparing it made, and its entry |
| `local.model.configure { id, contextSize?, options? }` | `options`: `vision`, `parallel` |
| `local.model.folder { path }` | Where packs downloaded from now on go; `null` for pi²'s own |
| `local.model.try { id }` | One message to a model that is running; `{ text }` |
| `local.download.pause`, `.resume`, `.cancel { id }` | `id` is `engine` or a pack's id |

Events: `local` (the same as `local.status`'s result, whenever it changes) and `local.progress` (`{ download }`, one download's state). A feature that adds to the status calls `localChanged()` when its part changes.

A download in the status is `{ id, kind, target, name, state, phase, error, received, total, retry, stage, again, prepare, from, log }`: `state` is `running`, `paused`, `failed` or `waiting` (for the engine, before preparing); `phase` is what a running one is doing (`downloading`, `checking`, `copying`, `waiting` to try again, `unpacking`, `preparing`); `stage` is `download` or `prepare`; `again` says a model set up before is being prepared again; `prepare` is how far preparing has got; `log` is where setup's output goes. A model in the status has `prepared`.

## Tests

`engine/test/localmodels.ts`, against a stand-in server on 127.0.0.1 and a catalog of the test's own (`PI2_LOCAL_CATALOG`; the engine reads a catalog from a file only when that variable names one). No test downloads the real engine or a real model. Its control package's Python is a stand-in that plays Strata's commands: `components install-file`, and `setup.py`, which prints Strata's steps, writes a run config and notes its environment, and fails or waits while a file the test names is there. `PI2_LOCAL_MEMORY_GB`, `PI2_LOCAL_STALL_MS`, `PI2_LOCAL_RETRY_MS`, `PI2_LOCAL_RETRIES` and `PI2_LOCAL_KEEP_FREE` set what a test needs.

The real thing was set up through a throwaway copy in #293, from the files #290 left on the Mac: [local-models-running.md](local-models-running.md#checked-against-the-real-engine-293) says what was seen.
