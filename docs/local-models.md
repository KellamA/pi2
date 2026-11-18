# Models on this Mac: getting them

pi² can run a model on the Mac itself with the [Strata](https://github.com/Niko1221/Strata) engine (#173). This page is about the part that gets the engine and a model onto the Mac and sets them up (#292): Settings › Providers › **On this Mac**. Starting and stopping a model is another part's (#291), which reads what this one writes. What the engine and the model need, as found by running them on a Mac (#290), is in [strata.md](strata.md).

The engine does all of it (`engine/src/localmodels.ts`, with `download.ts` and `localcatalog.ts`); the app shows it (`app/Sources/pi2/LocalModelsSettings.swift`).

## What can be downloaded: the catalog

`engine/src/localcatalog.ts` is data, and the one place it is written down:

- **The engine**: a pinned version of Strata's Metal engine for Apple silicon (the engine package alone, not the desktop app), and of Strata's control package, which holds the OpenAI- and Anthropic-compatible server that starts the engine and has a Python of its own: the engine has no HTTP server (#290). Each archive with its address, size and SHA-256.
- **The model packs**: for each, every file to download (address, size, SHA-256), the disk space preparing it takes as well, the memory it needs and from how much memory Strata recommends it, a plain note on what is lost against the others, its licences, and, for one pi² cannot set up yet, why.
- **The figures**: memory per token of context, the share of memory Metal lets one program keep, the context sizes offered, and the free space a download always leaves (10 GB).
- **Which pack to recommend**: an order of preference; the first that fits the Mac's memory is recommended.

Raising the engine's version, correcting a pack's memory figure, or adding a pack is a change to that file, reviewed like any other.

### Nothing that was not checked is run

Every checksum is written in that file in advance. pi² never takes one from beside a download: not a `SHA256SUMS` file, not a release's digest, not a server's header. So someone who can change what a server sends cannot change what pi² accepts.

- A file grows as `<name>.part` and gets its name only once its size and SHA-256 match. Its checksum is worked out as it arrives, and from the part already on disk when a download carries on.
- Both archives are downloaded and checked before either is unpacked, each into a folder of its own; entries with absolute paths or `..` are refused. Only then is the executable made runnable. pi² does not run anything here: #291 does, when a model starts.
- A file that does not match is deleted, and the person is told that nothing in it was run.
- Only HTTPS is used (a stand-in on 127.0.0.1 is allowed for tests), and a redirect to anything else is not followed.

### A newer engine

A newer engine reaches the person only with a pi² update that pins it, since pi² must know its checksum first. When the version installed is not the one pinned (pi² was updated), the engine's row says that version is available and offers **Update…**, which shows the licence again and replaces the old version once the new one is set up. pi² does not look for Strata releases newer than its pin: it could not run one anyway.

## Downloads

- **Licences first.** The engine's licence, and each pack's (the model's own and the quantiser's), are shown in the sheet before its download, which starts only on **Agree and Download**. `local.engine.install` and `local.model.install` refuse without `accept: true`.
- **The disk is checked first.** A download is refused if it, with the other downloads under way on the same disk, would leave less than 10 GB free, and the person is told how much it needs, how much is free, and that they can choose another folder for models. A disk that fills all the same stops the download with words that say so, keeping what it has.
- **It carries on.** `local-setup.json` in the data folder lists the downloads under way and whether each is running, paused or stopped. The next engine carries on with those that were running, after pi² quits, the engine restarts or is killed. A dropped connection, a stall (nothing for a minute) or a busy server (HTTP 429 or 5xx) is tried again by itself, waiting longer each time, eight times, each time from where it stopped (an HTTP range request); after that the download stops with a message, and **Try Again** carries on.
- **Pause, Resume, Cancel.** Pausing keeps what it has. Cancelling removes it all: the parts and any of the pack's files already finished.
- **Progress** is sent as `local.progress` events, about twice a second while a download runs, and the whole state as `local` whenever it changes.
- **Out of backups.** The engine and models are in `local/` in the data folder (`local/engine/<version>/`, `local/models/<pack>/`), or a folder the person chooses for models. pi²'s backup copies named files only, never these; each folder pi² makes is marked for Time Machine to skip (`tmutil addexclusion`, which needs no permission).
- **What a person reads when it fails**: no network ("pi² could not reach huggingface.co. Check the network connection…"), a dropped connection, no space, a checksum that does not match, a server that refuses ("huggingface.co refused the download (HTTP 403 Forbidden). The file may have moved or been withdrawn; a newer pi² may know where it is now."), a busy server.

## What fits this Mac

pi² reads the Mac's memory and, for each pack, says one of: fits (the Mac has at least the memory Strata recommends it from), fits with little left for other apps (it fits in the share Metal allows, about three quarters), too big to stay in memory (it runs, reading from the SSD, much more slowly), or too little memory to run at all (under 16 GB). It recommends the first pack of the catalog's preference that fits, else one that fits tightly, else the smallest. An Intel Mac is told that Strata runs only on Apple silicon, and nothing is offered.

## Configuring

A model's context size (16K to 262K tokens), whether it reads pictures (for a pack with a picture reader), and how many requests it runs at once (1 to 4). Each context size shows about how much memory the model takes with it; above what Metal lets one program keep, the sheet warns that it would read from the SSD or not start, and above 64K that Strata has not measured it on a Mac. The defaults are what Strata's setup chooses: 32K below 96 GB of memory and 64K from 96 GB, pictures on, one request at once. Nothing has to be pressed for them to apply.

## Trying it

**Try It** starts the model with `local.start` (#291), then `local.model.try` sends it one short message through the providers, as the model `local/<id>`, and shows the answer. Until #291's requests exist, it says that this version cannot start models.

## What the other parts read

`local-models.json` in the data folder, written whole each time (to a temporary file, then renamed):

```json
{
  "engine": { "version": "0.1.60", "path": "<the strata executable>", "folder": "<the engine package>",
              "control": { "version": "0.1.61", "folder": "<the control package>" } },
  "models": [{
    "id": "qwen3.8-flash-next-iq3-s", "name": "Qwen3.8-Flash-Next (IQ3_S)", "pack": "IQ3_S",
    "path": "<the pack's first file; the others are beside it>", "contextSize": 65536,
    "options": { "vision": true, "visionFile": "<the picture reader>", "parallel": 1 }
  }]
}
```

`engine` also has `folder` (the whole engine package, which holds `strata`, `strata-vision` and the Metal kernels it compiles as it starts) and `control: { version, folder }` (the control package). It is null until both are set up. A model is listed only once all its files have matched. As the engine starts, an entry whose files were removed by hand is dropped.

### Not done here yet: preparing a pack

Strata prepares a pack once after its download, with its own setup in the control package: a pack folder made from the first file, the draft layer (5.2 GB, which it fetches itself from Qwen's original model; it makes answers faster and can be left off) and a run config naming every flag the server starts the engine with (#290). [strata.md](strata.md#preparing-a-model) has the command that does it, how long it took and what it writes. That needs the real control package and model to check against, so it is left to #293, which runs the real thing; the disk check already counts the space it takes.

## Requests and events

| Request | What it does |
|---|---|
| `local.status` | What is installed, the catalog with what fits, the downloads, the folder for models; and what any feature adds with `localStatus()` (the running part's state) |
| `local.engine.install { accept }` | Downloads the pinned engine, or carries on |
| `local.engine.remove` | Removes the engine (and stops its download) |
| `local.model.install { pack, accept }` | Downloads a pack into the folder for models, or carries on |
| `local.model.remove { id }` | Removes a model's files and its entry |
| `local.model.configure { id, contextSize?, options? }` | `options`: `vision`, `parallel` |
| `local.model.folder { path }` | Where packs downloaded from now on go; `null` for pi²'s own |
| `local.model.try { id }` | One message to a model that is running; `{ text }` |
| `local.download.pause`, `.resume`, `.cancel { id }` | `id` is `engine` or a pack's id |

Events: `local` (the same as `local.status`'s result, whenever it changes) and `local.progress` (`{ download }`, one download's state). A feature that adds to the status calls `localChanged()` when its part changes.

## Tests

`engine/test/localmodels.ts`, against a stand-in server on 127.0.0.1 and a catalog of the test's own (`PI2_LOCAL_CATALOG`; the engine reads a catalog from a file only when that variable names one). No test downloads the real engine or a real model. `PI2_LOCAL_MEMORY_GB`, `PI2_LOCAL_STALL_MS`, `PI2_LOCAL_RETRY_MS`, `PI2_LOCAL_RETRIES` and `PI2_LOCAL_KEEP_FREE` set what a test needs.
