# Strata and Qwen3.8-Flash-Next on a Mac: what they need

This page is for whoever builds or changes local models in pi² (#173 and its pieces #291, #292, #293). It records what was found by running the real engine and model on a Mac (#290), so that the pieces can be built and checked without downloading 90 GB first, and what running them through pi² added (#293). How pi² gets them onto the Mac and prepares them is in [local-models.md](local-models.md), how it runs them in [local-models-running.md](local-models-running.md), with what #293 saw there. It describes **Strata 0.2.15** (engine 0.1.60, control 0.1.61), released on 2026-11-16. When pi² pins a newer Strata, check again everything below that is marked as pinned. Since #605 pi² pins **Strata 0.2.17** (engine and control 0.1.63, released on 2026-11-20): what #605 found running it, and why, is in [Several requests at once](#several-requests-at-once-605); the rest of this page was not measured again with it.

Unless a line says it was read from Strata's code or documentation, it was run on an Apple M5 Max with 128 GB, macOS 27.2, on 2026-11-17, while seventeen other agents were building and testing on the same Mac. Times and speeds are from that busy Mac: a quiet Mac does better.

## In short

- Strata is **two downloads**: the engine (5.8 MB, the Metal inference program) and the control package (48.7 MB, its HTTP server in Python, with its own Python). pi² needs both, and neither the desktop app nor the install script.
- A model is **not ready when its files are downloaded**: Strata's installer prepares it once (a 1.4 GB "pack" folder, an optional 5.2 GB draft layer, and a run config). pi² runs that installer, from the control package, with the files it downloaded.
- pi² starts **one process**, the Python server, which starts the engine and the picture reader. It is ready when it writes its ready file; SIGTERM stops all of them in about 2 seconds.
- The server speaks the **OpenAI chat completions API** (and Anthropic's and the Responses API), streams, returns **tool calls** as OpenAI `tool_calls`, reads **pictures**, and sends the model's thinking as `reasoning_content`.
- With IQ3_S: ready **160 s** after the first start (Metal compiles the kernels once) and **21 s** after later ones; about **60 GB** of memory held; **90 to 100 tokens/s** written, about 740 tokens/s read; one request at a time unless started with `--parallel N`.

## The engine

### What to download

| Component | Archive | Release | Bytes | SHA-256 |
| --- | --- | --- | --- | --- |
| Engine 0.1.60 (Metal) | `strata-engine-0.1.60-macos-arm64-metal.tar.gz` | v0.2.14 | 5,754,720 (15.8 MB unpacked) | `31ce1cd98bef83938434c15fcc94c1768340037b8fe7f292ee82836db0ca074d` |
| Control 0.1.61 | `strata-control-0.1.61-macos-arm64.tar.gz` | v0.2.15 | 48,715,939 (149 MB unpacked) | `b5fcda16daee894260efc9726d19b526b70df869c46ed73f22e5345833c92a86` |
| Engine 0.1.63 (Metal), pinned since #605 | `strata-engine-0.1.63-macos-arm64-metal.tar.gz` | v0.2.17 | 2,696,028 (6.9 MB unpacked) | `92a3e6440da49e98d0493b59418c501fd9744ade1bee3ac192abf4e3b7a9c2fd` |
| Control 0.1.63, pinned since #605 | `strata-control-0.1.63-macos-arm64.tar.gz` | v0.2.17 | 45,613,317 (139 MB unpacked) | `f7ca382b30010772135f6f9ebfdd9cf4fd5046a5f3ba6bb8476cdc6264ebac4a` |

The URLs are `https://github.com/Niko1221/Strata/releases/download/<release>/<archive>`. Note that the newest Mac engine is in the **v0.2.14** release, not in v0.2.15: it is listed only in the signed update feed, so "latest" does not find it. Pin both URLs and both SHA-256 in pi².

- **Where the pins come from.** `strata-feed.json` in the v0.2.15 release lists both packages with their URL, size and SHA-256, and for the engine also `manifest_sha256`, the hash of the package's `engine-component.json`, which in turn lists every file's SHA-256. The feed is signed (`strata-feed.json.sig`, Ed25519; Strata's key ids are in its `strata_control/update_keys.json`). The control archive is also in the release's `SHA256SUMS.txt` and in GitHub's asset digest. Pinning the SHA-256 in pi²'s code is enough; pi² need not check the feed's signature.
- **Signed binaries.** `strata` and `strata-vision` are signed with a Developer ID (Niko Veit, team 79LR4R7RSC) with the hardened runtime. Downloaded with `curl` they carry no quarantine flag, so Gatekeeper does not ask; a download by pi²'s engine (Node's `fetch`) sets none either.
- **What is not needed.** The `.dmg` (167 MB) is Strata's desktop app, with its own chat window and its own way of managing models. `install.sh` installs Strata's terminal app for the user and adds a line to the shell's profile. Neither is wanted.
- **Not on Intel Macs.** The engine is arm64 and Metal only, and needs macOS 15 or newer (it keeps its buffers resident through a residency set). An Intel Mac should be told local models are not available.

### What is inside

The **engine** package is a folder: `strata` (the engine, 5.8 MB), `strata-vision` (the picture reader, 8.5 MB), `metal/` (Metal kernel sources the engine compiles when it starts, and two data files), `engine-component.json` (the signed manifest) and `BUILD.json`. `strata --version` prints `strata 0.1.60-metal`. The engine has no HTTP server: it speaks a line protocol on its standard input and output (`strata --serve …`), which only Strata's server uses.

The **control** package is Strata's terminal app and server: `python/` (CPython 3.12.15 with the packages the server needs), `serve/` (the HTTP server), `strata_control/`, `setup.py` (the installer that prepares models), `tools/` (the preparation tools), `bin/strata` (a shell launcher) and `data/`. `bin/strata --version` prints `strata 0.2.15 (build 0.1.61; python 3.12.15 …)`.

### Keeping Strata to pi²'s folder

Strata writes its state under the home folder: `~/.local/share/strata` (engine components, install state), `~/.local/state/strata` and `~/.strata`. For every Strata command pi² runs, set `HOME`, `XDG_DATA_HOME` and `STRATA_HOME` to folders inside pi²'s own local-models folder, and set `PYTHONNOUSERSITE=1` and unset `PYTHONHOME` and `PYTHONPATH`, as Strata's own launcher does. Run that way, nothing went outside the folder in this trial.

### Installing the engine for the server

The server finds its engine through Strata's component folder, not a path in the config: the installer writes `"exe": "component:strata-engine"` into the run config. Install the downloaded engine archive there with the control package, which needs no network:

```sh
<control>/bin/strata components install-file <engine archive .tar.gz>
```

It checks the package's signature and every file's hash, runs `strata --version` once, and puts the engine in `$XDG_DATA_HOME/strata/components/engine/0.1.60-macos-arm64-metal/`. It took 10 seconds. `strata components engines` lists what is installed. So pi² keeps the engine archive's own folder only as long as it needs to install it.

## The model

### The packs

Strata's Mac engine runs the original model's packs by ISTA-DASLab (Q2_0, IQ2_XS, IQ3_XXS, IQ3_S), Unsloth's packs (prepared differently, see below) and agentionai's Gyro packs. The two the owner suggested:

| | ISTA-DASLab IQ3_S | Unsloth UD-Q4_K_XL |
| --- | --- | --- |
| Repository, pinned commit | `ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF` @ `ed59f92082b1e93c0e96d60a8b11aab089b52f09` | `unsloth/Qwen3.8-Flash-Next-GGUF` @ `38bb39ee…` (Strata's `setup.py`, `HF_REVISIONS`) |
| Files | `IQ3_S/…-IQ3_S-00001-of-00002.gguf` 54,817,524,224 B; `IQ3_S/…-IQ3_S-00002-of-00002.gguf` 28,800,138,432 B (the n-gram table) | four shards, 111 GB in all |
| Download | 83.6 GB, + 0.9 GB picture reader, + 5.2 GB draft layer = 89.7 GB | 111 GB, + the picture reader and a 0.34 GB drafter |
| Memory it needs (Strata's figure) | about 63 GB; recommended from 96 GB | about 91 GB; recommended from 128 GB |
| Quality against Q8_0 (same top token / KL) | 87.9% / 0.142 | 92.8% / 0.055 |
| Decode on an M5 Max (Strata's figures, story, with draft layer) | 94.7 tokens/s | 73.7 tokens/s |
| Prepared on a Mac by | Strata's installer in app mode, as below | Strata's source installer only: it repacks the shards into one 82.6 GB file. The app and terminal app do not offer it on a Mac |
| Licence | Qwen Community License 1.0 (the repository is labelled Apache-2.0; the weights are Qwen's) | Qwen Community License 1.0 |

SHA-256 of the IQ3_S files, as Hugging Face and Strata's `setup.py` (`ISTA_FILES`) both give them:

- `Qwen3.8-Flash-Next-GSQ-RCO-IQ3_S-00001-of-00002.gguf`: `4c1eb2ceb4915e1192f4f386021897bde56a97f40a0bb78bb86465e0f7d2aca3`
- `Qwen3.8-Flash-Next-GSQ-RCO-IQ3_S-00002-of-00002.gguf`: `316b46f3a2dbd68c900f43136ab9449f9dcc3725dfd8c794847c204bc161e113` (the same n-gram table for all four ISTA-DASLab sizes)
- `mmproj-Qwen3.8-Flash-Next-BF16.gguf` (the picture reader, at the repository's top, 907,543,008 B): `b1a82259702816a5330d7bd7607cd9676b11780e79ff7348c21103ff3ce49bd0`

The file URLs are `https://huggingface.co/<repository>/resolve/<commit>/<path>`. Neither repository needs a sign-in. Hugging Face answers a `HEAD` with `x-linked-size` and `x-linked-etag` (the SHA-256), so pi² can check a pin before downloading. Its CDN serves byte ranges; one connection gave about 14 MB/s here and four or five together about 20 to 40 MB/s, so 84 GB took about an hour.

The other ISTA-DASLab sizes, with the same second shard (Strata's figures): Q2_0 shard 1 37.6 GB, needs about 46 GB; IQ2_XS 39.2 GB; IQ3_XXS 47.0 GB, needs about 55 GB.

**What each loses.** IQ3_S is the best of the original packs (ISTA-DASLab: it matches the full model on their published tests) and the slowest of them. The lower sizes trade quality for speed and memory: Q2_0 is the fastest and needs the least. UD-Q4_K_XL is closer to the full model than IQ3_S (93% against 88% same top token) and slower, and needs nearly all of a 128 GB Mac.

**Why IQ3_S was tried.** It is Strata's recommendation from 96 GB, its own app installer prepares it on a Mac, and it needs about 63 GB. UD-Q4_K_XL needs about 91 GB resident (Metal lets one program keep about 107 GB resident on 128 GB), only Strata's source installer can prepare it on a Mac, and with other work on the Mac it would not load without swapping. For pi², IQ3_S is the pack to offer first on a 96 GB or larger Mac, and Q2_0 or IQ3_XXS on 64 GB.

### Licences

- **Strata:** MIT (`LICENSE` in its repository). The draft layer for Unsloth's packs (DFlash2) is Apache-2.0.
- **Qwen3.8-Flash-Next:** the **Qwen Community License 1.0** (`LICENSE` in `Qwen/Qwen3.8-Flash-Next` on Hugging Face). It allows use, change and redistribution, with two conditions. Clause 1: a product with more than 100 million monthly users or US$20 million monthly revenue must show the model's name. Clause 2: a licensee that runs a "Model as a Service" or an "AI Work Assistant" business (a product "primarily designed for AI-assisted coding or office productivity") needs a separate licence from Qwen for commercial use, except for internal use that does not make the model available to a third party. pi² does not redistribute the weights: the person downloads them from Hugging Face and runs them on their own Mac. Whether clause 2 touches pi² as a product is the owner's call; the download screen should show the licence and link it, as #173 planned.

### Preparing a model

Strata's engine does not run the GGUF files as they are. Its installer prepares them once:

1. **The pack**: a folder made from shard 1 by `tools/iq_pack.py`: `dense.bin` (1.5 GB, the weights that are not experts), `index.txt`, `native_experts.txt`, `conversions.json` and `tokenizer/`. It took about 30 seconds.
2. **The draft layer (MTP)**, optional but makes answers faster: 5.2 GB of tensors range-read from the original checkpoint, `Qwen/Qwen3.8-Flash-Next` at a pinned commit, by `tools/mtp_fetch.py` (every tensor checked against a pinned SHA-256), then packed by `tools/mtp_pack.py` into `mtp-q2_0.gguf`. The fetch took about 6 minutes here. With `--mtp off` none of it is downloaded and the model is a little slower.
3. **The run config**, `strata-<model>.json`: the engine and every flag it is started with, the tokenizer, the model's name, the picture reader and the port.

The installer does all three from the control package, with the files already downloaded by pi²:

```sh
STRATA_CONTROL_INSTALL=1 HOME=… XDG_DATA_HOME=… STRATA_HOME=… PYTHONNOUSERSITE=1 \
  <control>/python/bin/python3 <control>/setup.py --family qwen --model IQ3_S \
    --gguf-dir <folder with the shards and the mmproj file> --data-dir <folder for the pack and the draft layer> \
    --context 65536 --vision gpu --no-start --no-browser --yes
```

It took 6 minutes 54 seconds on the busy Mac with the draft layer's tensors already fetched (it checks each against its SHA-256 again, then packs them, which took most of the time), and ended `All set.` with exit 0. Run by pi² in #293, on a quieter Mac and with the tensors there already, the same took 55 seconds. It prints one line per step (`=== Step 6: preparing the model for Strata ===`, `[ok] model prepared: …`, `MTP draft layer:   0.87 / 5.21 GB (16%)`), which pi² can show as progress. A first run that also fetches the draft layer takes about 6 minutes more on a good connection.

`--gguf-dir` files are taken as they are: the installer checks that each shard is as long as its own header says, not its hash, so pi² checks the SHA-256 itself after downloading (it did check the mmproj file's hash). The GGUF reader its tools use is in the control package (`third_party/strata-gguf-py`), so only the draft layer needs the network. Preparing belongs to the download step, not to starting.

What it printed for pi² in #293 (abridged): `Strata on a Mac (Apple Silicon, Metal)`, then `=== Step 1: checking your Mac ===`, `=== Step 2: your choices ===` (with `context 65536: measured on the Mac up to 32768 (needles found at 8K-32K); longer is kept`), `=== Step 4: the Strata engine (Metal) ===` (`[ok] engine component: 0.1.60 (macos-arm64-metal)`: it needs the engine installed with `components install-file` first), `=== Step 5: downloading Qwen3.8-Flash-Next IQ3_S ===` (`[ok] model files present`, and the picture reader's SHA-256 checked), `=== Step 6: preparing the model for Strata ===` (`tools/iq_pack.py`, then `tools/mtp_fetch.py`, whose `MTP draft layer:   5.21 / 5.21 GB (100%)` goes to standard error, a line per tensor checked, then `tools/mtp_pack.py`), `=== Step 7: writing the run settings ===`, `All set.`. There is no step 3 on a Mac. When it fails it prints `  [X]  <what>`, a line of what to do, and `Setup stopped. Fix the item above and run it again - everything already done is kept and skipped.`, and exits 1.

The run config written for this trial, `strata-iq3_s.json` (paths shortened to `<trial>`, `<control>` and `<engines>`):

```json
{
 "exe": "component:strata-engine",
 "args": ["--pack", "<trial>/data/packs/iq3_s",
          "--native", "<trial>/models/qwen3.8-flash-next-IQ3_S/Qwen3.8-Flash-Next-GSQ-RCO-IQ3_S-00001-of-00002.gguf",
          "--ple-gguf", "<trial>/models/qwen3.8-flash-next-IQ3_S/Qwen3.8-Flash-Next-GSQ-RCO-IQ3_S-00002-of-00002.gguf",
          "--expert-profile", "<control>/data/expert-profile.bin", "--expert-cache", "64", "--prefill", "auto",
          "--spec", "3", "--spec-min-p", "0.5", "--mtp", "<trial>/data/mtp/rt",
          "--max-context", "32768", "--mmap-experts", "--vision"],
 "cwd": "<control>",
 "tokenizer": "<trial>/data/packs/iq3_s/tokenizer",
 "model_name": "qwen3.8-flash-next-iq3_s",
 "log": "<control>/strata-iq3_s.log",
 "lib_dirs": [], "port": 8080, "backend": "metal",
 "env": {"STRATA_METAL_STREAM": "0"},
 "open_browser": false,
 "vision": {"exe": "<engines>/0.1.60-macos-arm64-metal/strata-vision", "cpu_exe": "<same>",
            "mmproj": "<trial>/models/qwen3.8-flash-next-IQ3_S/mmproj-Qwen3.8-Flash-Next-BF16.gguf",
            "model": "<shard 1>", "gpu": true, "max_tokens": 1024},
 "args_written": ["…the same as args…"]
}
```

Three things about it matter to pi²:

- **It is written into the control package's own folder**, with the engine's log and a `run-iq3_s.sh` beside it (Strata's app mode treats that folder as its home), and it names files inside that folder (`cwd`, `--expert-profile`). A new control version is a new folder, so after updating the control package pi² runs the installer again for each model rather than reusing the old file. pi² may keep its own copy elsewhere and point `"log"` at its own logs folder; the server takes `--config` from anywhere.
- **The context size is fixed in it** (`--max-context`), so changing it means a new run config and a new start. The server reports it: `meta.n_ctx` in `/v1/models`, `max_context` in `/health`.
- `"port"` is ignored when `--port` is given.

To change a setting later (the context size, pictures on or off, the draft layer), run the installer again with the new choices, or change the run config. (Read from Strata's code, not tried: `--setup` is the installer's "change settings" mode, and Strata's own Settings page changes only the keys `serve/runconfig.py` lists and keeps the rest.) Either takes effect at the next start of the server.

## Running it

### Starting

pi² starts one process, Strata's server, which starts the engine as its child:

```sh
STRATA_API_KEY=<key made for this run> HOME=… XDG_DATA_HOME=… STRATA_HOME=… PYTHONNOUSERSITE=1 \
  <control>/python/bin/python3 <control>/serve/server.py --engine strata --config <run config> \
    --host 127.0.0.1 --port <port> --ready-file <absolute path>
```

- `--host 127.0.0.1` is the default too. `--port 0` lets the system choose and the ready file says which.
- `--ready-file` must be an absolute path in an existing folder, and must not exist yet. The server writes it (mode 0600) once the API is listening and the model is loaded: `{"api_state": "ready", "model_state": "ready", "api_url", "bound_host", "bound_port", "pid", "instance_id", "model_id", "created_at", "schema_version": 1}`. It removes it on a clean stop. A file left by a server that was killed stays: delete it before the next start.
- `<control>/bin/strata serve --profile <run config> --host … --port … --ready-file … --output jsonl` does the same through Strata's launcher, and prints one JSON line per stage on standard output (`starting`, `ready`, `stopping`, `stopped`).
- **The key**: `STRATA_API_KEY` in the environment (or `--api-key`; the environment keeps it out of `ps`). The server then asks for `Authorization: Bearer <key>` or `x-api-key: <key>` on `/v1/*`. A key made for each run works.
- **Lazy start**: `--lazy` (or `"lazy_load": true` in the run config) starts the API at once with the model unloaded; the first request loads it and waits. Text only: it cannot be used with pictures on. `--idle-unload S` unloads the model after S seconds without requests and loads it again on the next. pi² decides when to stop the model itself (#291), so neither is needed.
- **Other settings at start**: `--parallel N` (requests answered at once; see below), `--max-queue N`, `--queue-timeout S`, `--shutdown-timeout S` (how long a stop waits for running answers, 0 to 300 s).
- **While it loads**, the port is not open yet: in the normal mode the server loads the model before it listens. What it is doing is in its standard output, one plain line per step, with no percentage. The first start printed:
  ```
     1.2s loading the vision encoder ...
     4.7s loading the model (the first start takes a minute or two) ...
     7.9s [strata] starting the engine: reading the model's weights ...
    16.5s [strata] mapping the experts from the model files (about 55 GB, --mmap-experts): …
    16.5s          YOUR PC CAN BE SLOW OR STOP RESPONDING FOR 1-3 MINUTES NOW - this is normal.
    20.0s [strata] filling the GPU's expert cache (82 experts, 0.16 GiB of VRAM) ...
    20.0s [strata] almost ready ...
    40.6s [strata] still starting (33 s) - please wait ...
          … every 20 s …
   162.3s ready: http://127.0.0.1:56359/v1  (OpenAI: /v1/chat/completions, Anthropic: /v1/messages, context 32768 tokens, images on, API key required)
  ```
  While it answers, it prints a line a second about the request: `[strata] reading the prompt: 2,048 of 9,096 tokens, 6 s so far`, `[strata] thinking: 830 of budget 2250 (max 3000) tokens, 74.6 tok/s, 15 s`, `[strata] writing a tool call: bash: …`, `[strata] answering: 2329 of max 3000 tokens, 91.8 tok/s, 29 s`, `[strata] done: 2514 tokens in 30 s (93.5 tok/s)`. These are for a person to read, not a format to parse; the engine's own log (the run config's `"log"`) has more.
- **If the engine stops before it is ready**, the server says why from the engine's log (the run config's `"log"`), retries a GPU runtime that was not ready up to three times, and exits with an error.
- The server ends engines that an earlier server of the same install left running ("leftovers", matched by process id, start time and command line) before it starts one.

### How long it takes, and the memory it holds

| | |
| --- | --- |
| First start after installing | **162 s** to the ready file. About 140 s of it is macOS compiling the engine's Metal kernels (`MTLCompilerService` busy, the engine idle), once. |
| Later starts | **21 s** to the ready file. |
| First prompt longer than 64 tokens after the first start | **62 s** for a 391-token prompt (more kernels compiled on first use). After a later start the same prompt took 3.3 s. |
| Memory | The engine held **58 to 61 GB** resident: its own memory ("physical footprint") was 14 GB; the rest is the 55 GB model file, mapped and kept resident for the GPU. The Mac's wired memory went from about 5 GB to 63 GB. The picture reader held about 1 GB more, the server 40 to 240 MB. `/v1/status` reports `machine.gpu.used_mib` (56,278 while answering) and `machine.ram`. Through pi² in #293, at a 64K context: 59 to 69 GB resident in all, growing as answers paged more experts in; Activity Monitor showed 14 GB for `strata` and 1 GB for `strata-vision`; wired memory stayed about 5 GB. |
| Effect on the Mac | With other agents building, about 250 MB went to swap while it was loaded, and memory pressure stayed normal. On a Mac with 64 GB this pack would not fit beside other work; Strata's own rule is IQ3_S from 96 GB. |
| After stopping | Wired memory back to about 5 GB within 3 seconds. |

### Stopping

Send SIGTERM to the server (SIGINT and SIGHUP do the same). It tells the engine to quit, waits for running answers (up to `--shutdown-timeout`), removes the ready file and exits 0. With the model loaded and idle, the server and all four of its children were gone **2.3 seconds** after SIGTERM.

**The children are not in the server's process group.** The server starts the engine, the picture reader and one small watcher process for each, and every one of them leads a process group of its own. So signalling pi²'s process group for the server does not reach the engine. What does reach it is Strata's own guarantee (`serve/lifeline.py`): each watcher holds a pipe to the server and ends its child when the pipe closes. After a `kill -9` of the server, the engine, the reader and both watchers were gone within **1 second**. The ready file stays behind after a kill: delete it before the next start.

So for pi²: SIGTERM the server by its pid, wait (a few seconds; allow `--shutdown-timeout` more if answers were running), then SIGKILL the server if it is still there, and its watchers end the rest. A server that pi²'s previous engine left running is found by its marker, as `engine/src/processes.ts` does, and stopped the same way. The server also ends, before it starts an engine, any engine of the same executable that an earlier server lost.

## What the server answers

### Addresses

| Address | What |
| --- | --- |
| `POST /v1/chat/completions` | OpenAI chat completions, streaming or not |
| `POST /v1/messages`, `/v1/messages/count_tokens` | Anthropic messages |
| `POST /v1/responses` | OpenAI Responses API (stateless: send the whole conversation) |
| `GET /v1/models` | the model: `id`, `meta.n_ctx` (the context size), `architecture.input_modalities` (`["text","image"]` with pictures on) |
| `GET /health` | `{"status":"ok","loaded","max_context","model","images","api_key","service":"strata"}`, without a key |
| `GET /v1/status` | context, concurrency, whether loaded, the last request's timings, the Mac's memory and GPU memory in use |
| `POST /v1/load`, `POST /v1/unload` | load or unload the model without stopping the server (a JSON request with no other site's `Origin`, as from pi²'s engine) |
| `GET /metrics`, `/metrics/prometheus`, `/v1/telemetry` | counters for Strata's monitor |
| `GET /` | Strata's own chat page |

The model's id is `qwen3.8-flash-next-iq3_s` for this pack (the run config's `model_name`); the server answers whatever `model` a request names.

### Streaming

`"stream": true` sends server-sent events, `data: {…chat.completion.chunk…}` lines ending with `data: [DONE]`. With `"stream_options": {"include_usage": true}` the last chunk carries `usage` (`prompt_tokens`, `completion_tokens`, `prompt_tokens_details.cached_tokens`).

### Thinking

The model thinks before it answers, and the server sends the thinking separately, as `delta.reasoning_content` (streaming) or `message.reasoning_content`, the form llama.cpp and DeepSeek use. pi-ai's OpenAI completions client already reads `reasoning_content` as thinking. A request can turn thinking down or off with `"reasoning_effort"` or `"chat_template_kwargs": {"enable_thinking": false}`.

- All of `none`, `minimal`, `low`, `medium`, `high` and `xhigh` were accepted. `none` and `minimal` gave no thinking at all; `low` a few lines; with none given the model thinks as it likes.
- It thinks a lot by default: for "write a short story of about 200 words" it thought for about 2,200 tokens (25 s) before the first word of the story.
- Any level given keeps it short. In #293, with an agent's system prompt and two tools, on three small agent tasks ("Which file in the current folder is the largest? Find out." and the like), a short sum and the 200-word story: `low` thought 120 to 320 characters and answered or called a tool within 1.1 to 1.8 seconds; `medium` and `high` about the same; none given, the story took 6,500 characters of thinking and 31 seconds before its first word. `none` called the tool in three of four tries, and once only said it would; `low` in all four. So pi² gives a new conversation with this model Low ([local-models-running.md](local-models-running.md#in-the-model-selector)).
- The server caps the thinking at 75% of `max_tokens` (`[strata] thinking limited to 2250 of max_tokens 3000 so the answer has room`) and then makes it wrap up.
- So pi² marks the model as a reasoning model whose effort can be set, and maps its thinking levels to `reasoning_effort`.

### Tools

**The model calls tools through the server.** Given OpenAI `tools` (function definitions with JSON Schema parameters) in `/v1/chat/completions`:

- Asked a question whose answer was in a file, it called `read_file` and the server returned `message.tool_calls`: `[{"id": "call_b1e5bb6d…", "type": "function", "function": {"name": "read_file", "arguments": "{\"path\":\"README.md\"}"}}]`, `content` empty, `finish_reason: "tool_calls"`.
- Given the result back as `{"role": "tool", "tool_call_id": …, "content": …}` after the assistant message with its `tool_calls`, it answered from the result. The second request reused 386 of its 452 prompt tokens from the conversation cache.
- Streamed, the call comes as OpenAI deltas: the first with `index`, `id`, `type`, `function.name` and empty `arguments`, then the arguments in small pieces (`{`, `"command":`, `"`, `ls`, ` -`, `la`, `"`, `}`), then `finish_reason: "tool_calls"`.
- The model writes Qwen's XML form (`<tool_call><function=…><parameter=…>`); Strata's server turns it into OpenAI's, so pi² sees only OpenAI's. Thinking before a call comes as `reasoning_content`.

Only short, clear tasks were tried; how well it chooses and chains tools in a long agent session is for #293 to see in pi².

### Pictures

A user message with `{"type": "image_url", "image_url": {"url": "data:image/png;base64,…"}}` beside the text was read on the GPU: asked about a 64×64 PNG of a red square on white, it answered "Red square", in 3.2 s. Pictures need the picture reader (the 0.9 GB mmproj file and `strata-vision`), which the run config's `vision` section names; with it off, `/v1/models` lists only `text`.

### Two requests at once

- **Started as above (one slot)**: two requests sent 0.2 s apart were both answered in full, one after the other. The second's first token came at 13.0 s, just after the first finished at 12.7 s; both were done in 24.6 s. Nothing was refused. `--max-queue` and `--queue-timeout` limit the waiting.
- **With `--parallel 2`** (`/v1/status` then says `"concurrency": {"serving": 2}`): both started at once (first tokens at 0.3 s and 0.9 s), each written at about 43 tokens/s, and both were done in 19.8 s. The engine's resident memory was within the first run's range (about 60 GB), so the extra slot's cost was too small to see here. Strata's own measurement on the same chip (`docs/MAC.md`): 0.65 GB of state per slot at a 36K context, the engine's own memory 8.3, 12.0, 14.0 and 16.0 GB for one to four slots, and the total rate rising to about 120 tokens/s at four.
- So several pi² conversations can share one loaded model either way. With one slot, a conversation waits while another is answering; with two or more they answer side by side, each more slowly. The number of slots is fixed when the server starts.

### Several requests at once (#605)

In real use at `--parallel 4`, engine 0.1.60 ended itself three times when two long answers overlapped: `strata serve: no progress for 60 s during a request (idle -1) - stopping the engine so the server starts it again (issue #29)`, exit code -6. #605 found why, from Strata's source and on a server of its own on the installed model's files (M5 Max, 128 GB, IQ3_S at a 131,072-token context, pictures on, requests of a pi² worker's shape: its system prompt, 14 tools, a history of file reads, `reasoning_effort: high`, streamed).

**Why it stopped.** The message is the engine's own watchdog (`strata-watchdog` in `src/program/generate.cpp`): once a second it looks at a `busy` flag and a counter of beats, and ends the engine with `std::abort()` (the -6) when the flag is up and nothing has beaten for `STRATA_WATCHDOG_S` seconds (60; 0 turns it off). Prompt chunks and the one-request loop's windows beat. With `--parallel N` above one the server starts the engine with `--batch N`, and as soon as a second request comes the requests are decoded in batch windows, which raise the flag. On CUDA a finished batch window beats; on Metal, `Verifier::run_slot_rows` returned before the beat. So on a Mac the engine was ended whenever **two or more answers had been written side by side for 60 s with no request admitted meanwhile**, whatever N, thinking or not; one answer alone, however long, never tripped it (it runs in the one-request loop), and neither did a request reading its prompt (its chunks beat). `idle -1` is the stage the last admission left; the stall report (`0 layers served`, the CPU pool and the one-request loop idle for minutes) describes the parts a Mac's batch windows do not use, not a hang. Reproduced on 0.1.60: two requests 5 s apart, answers of about 2,000 tokens each, stopped 60 s after the second was admitted; the same with overlaps of 45 and 58 s did not.

**The fix is Strata's**, in engine 0.1.62 (Strata 0.2.16, 2026-11-18): the Metal batch window beats, "Without it a Metal --batch decode with no admission for 60 s was ended as "no progress"". pi² pins 0.2.17 (engine and control 0.1.63). It runs a model prepared by control 0.1.61 as it is, and its setup prepares one with pi²'s command line exactly as 0.1.61's did, the same seven steps and the same run config (tried in a scratch folder on clones of the model's files, in under a minute with the draft layer's tensors there). With 0.1.63, the same runs at 2, 3 and 4 at once never stopped, with up to ten minutes of answers written side by side. An engine older than 0.1.62 is started with one request at a time whatever the setting (`requestsAtOnce` in `localengine.ts`).

**New in 0.1.62 and later: an SSD tier for parked conversations**, by default in `conversation-spill/` beside the pack's folder (for pi², `prepared/conversation-spill/` in the model's folder, which is out of backups), up to min(32 GiB, a quarter of the free disk). Each engine writes into a folder of its own (`<pid>-<nonce>`, with a `.lock`), a clean stop removes it and the next start removes those of engines that died. `--conversation-spill-dir` and `--conversation-spill-mib` (0 = off) set it.

**What several at once are worth** (engine 0.1.63; one run each, on a Mac with other agents' builds running):

| At once | First tokens of N fresh 42–44K prompts sent together | Each writes | All of them together while all decode | Engine's footprint |
| --- | --- | --- | --- | --- |
| 1 | 42 s | 113 tok/s (copying text; an agent's own turns 40–62) | — | 23 GB at `--parallel 1` |
| 2 | 37, 137 s | 16–33 tok/s | 44 tok/s (76 with 8.6K prompts) | |
| 3 | 69, 176, 274 s | 14–27 tok/s | 64 tok/s | |
| 4 | 61, 154, 247, 351 s | 11–19 tok/s | 61 tok/s | 37 GB at `--parallel 4` |

- **The total does not grow with more slots.** The Mac's engine runs a batch window slot by slot (`strata verify: batch windows of up to 4 sequences, run slot by slot in the Metal window`) and without draft rows (`--batch-mtp` is refused on Metal, #5674 in Strata), where one request alone uses the draft layer. Strata's MAC.md figure of about 120 tok/s at four is for 150-token prompts; at an agent's 40–50K tokens it is about half.
- **Prompts are read one at a time** whatever the slots; while others decode, a prompt is read in ~1K-token parts at 394–461 tok/s, against 700–1,150 alone.
- **Memory:** each slot takes about 3.3 GiB at a 131K context once there is more than one (`--batch 4: the slot sessions take 13.36 GiB`). `ps`'s resident memory, which counts the mapped model file, stayed at 60–68 GiB either way.
- **Four agents working** (four conversations of a worker's shape, 42–43K first prompts, six turns each, every tool answered after 2 s with a real file's first 6 KB): at `--parallel 1` all was done in 426 s, at 4 in 472 s. The four cold first turns took longer at 4 (done by 335 s against 267 s); after them, four slots got more done (29.5 against 23.5 tok/s together), a turn took the same (median 20 s), and its first token came after a median 4.1 s against 11.8 s, the worst 11.9 s against 44.5 s. At one slot every later turn still reused its conversation's 42–51K tokens from Strata's conversation cache and read only the 1.5–1.9K new ones (1.8–3.3 s): one slot does not mean prompts read again, only waiting for the others' turns.

So pi² runs four at once by default from #605 ([local-models.md](local-models.md#configuring)). What would make several worth more than one is Strata's: a Metal batch window that runs the slots together and takes draft rows.

## How fast it answers

On the busy M5 Max, context 32K, draft layer on, one slot:

| | |
| --- | --- |
| Writing, with thinking | 92 to 98 tokens/s (the server's own figure; Strata measured 94.7 on a quiet M5 Max) |
| Writing, thinking off | 72 to 85 tokens/s |
| Reading a 9,096-token prompt | 12.3 s, about 740 tokens/s |
| A short prompt (20 to 80 tokens), once warm | 0.2 to 0.5 s |
| "What is the capital of France?", whole answer | 4.5 s, as the first request after the first start |
| "What is 17 * 23?" with little or no thinking, once warm | 0.6 to 3.4 s |

The draft layer (MTP) proposes tokens that the full model checks, which changes nothing in the answer: the server reported 80 to 90% of the drafts accepted.

## Where an agent's time goes, and what makes it faster (#606)

Measured on the same M5 Max on 2026-11-20, with the installed model's files: first from the logs of a night in which a local worker did six tickets (engine 0.1.60), then on a server of the worker's own with fixed prompts, a fixed seed and three runs or more of each. The issue (#606) has every run.

**Where six tickets' time went** (Strata's engine log has a line per request: tokens reused and read, time reading, tokens written and time writing):

| Ticket | Wall time | Requests | Reading | of it, read again because the prompt's start changed | Summaries | Writing | Tools and the rest |
|---|---|---|---|---|---|---|---|
| #558 | 2 min | 25 | 16% | none | none | 61% | 23% |
| #560 | 7 min | 22 | 38% | 30% (4 times) | none | 35% | 27% |
| #564 | 68 min | 298 | 27% | 16% (15 times) | 6, 6 min | 54% | 19% |
| #553 (first part) | 137 min | 543 | 33% | 26% (48 times) | 9, 11 min | 56% | 11% |
| #584 | 41 min | 113 | 20% | 16% (9 times) | 1, 1 min | 18% | 62% |
| #588 | 120 min | 220 | 15% | 11% (21 times) | 6, 5 min | 30% | 55% |
| All six | 374 min | 1,221 | 25% (93 min) | 18% (68 min) | 23 min | 43% (160 min) | 32% (121 min) |

- **Read again from the start: 97 times, 68 minutes.** pi² sends a changed section of the system prompt as a later system message; pi-ai folds such messages back into the first one for a model that does not say it takes them (`compat.supportsMidConvoSystemMessages`), and the local provider did not. So each change (the list of background commands, as one starts and as it ends) changed the prompt's first tokens, and the engine, whose state can only go back to a kept checkpoint, read everything again. Strata's server takes a system message after the first and makes it a user message where it is (`_late_system_to_user` in `serve/frontend.py`), so the local provider now says it takes them. On the real model, a 31K-token conversation with the section changed: folded, nothing reused and 31,315 tokens read in 27 to 49 s; in place, 31,261 reused and 57 read in 0.8 to 0.9 s.
- **Summaries**: at 81,920 tokens (pi-durable's default for a 131,072 window: the window less 16,384 kept for the answer and 32,768 for a summary made in the background). Each costs a fresh read of the summariser's prompt (18K to 32K tokens: it is not the conversation's own prefix), about 1,500 tokens written, then a fresh read of the summarised conversation, of which only the 8,800 to 9,200 tokens of tools and system prompt were reused: about 75 s each on 0.1.60.
- **Thinking**: the worker thinks at High, which Strata's template turns into its `xhigh` instruction. In the two tickets whose server log was left, 41% and 63% of the tokens written were thinking.
- **Writing speed did not fall with length**: 68 to 70 tokens/s in every 20K band from 20K to 100K of context; reading 1,000 to 1,230 tokens/s at every position. A turn that read under 4,000 new tokens took 0.79 s on average before its first token (1,067 of them, 14 minutes).

**Engine 0.1.60 against 0.1.63** (Strata 0.2.17), the same files and start line, one after the other on a quiet Mac, three runs each, 400 tokens written with thinking off (the same tokens in both):

| | 0.1.60 | 0.1.63 |
|---|---|---|
| Writing code | 52 to 54 tokens/s | 104 to 109 |
| Writing prose | 45 to 49 | 82 to 88 |
| Copying a file with small edits | 60 to 61 | 110 to 115 |
| Reading 25,669 new tokens | 27 to 36 s | 19 to 20 s |
| A turn of about 190 new tokens on a 24K conversation | 0.59 to 0.83 s | 0.44 to 0.60 s |

**Each option of the engine, on 0.1.63**, one at a time against pi²'s start line (`--expert-cache 64 --prefill auto --spec 3 --spec-min-p 0.5 --mtp … --mmap-experts`, `STRATA_METAL_STREAM=0`), with the unchanged line started again after every two. The unchanged line itself moved by up to 20% from one start to the next (Strata's `tools/calibrate.py` says 8 to 28%), so only larger differences count:

| Option | Reading | Writing | So |
|---|---|---|---|
| `--spec 2`, `--spec 4`, `--spec-min-p 0.3` or `0.7`, `--lookup-chain 4` | the same | the same, within the drift | keep Strata's Metal default for a resident IQ3_S, `--spec 3 --spec-min-p 0.5` (its `strata_control/mac_fit.py`, measured by Strata in interleaved pairs) |
| No draft layer (`--mtp` left out) | the same | code 48 against 71 tokens/s, prose 48 against 60 | keep it |
| `--suffix-draft 0` | the same | copying 74 against 90 | keep the default (3) |
| `STRATA_METAL_STREAM=1` | 15 to 25% slower | 15 to 25% slower | keep 0: it is for a Mac that streams experts from the SSD |
| `--expert-cache 0` or `1024` | the same | the same | on a Mac the engine computes every expert from its own arena |
| `--prefill 8192` or `auto:16384` | the same | the same | the Metal prompt kernels read in chunks of 2,048 rows whatever is asked |
| `--short-read 0` | the same | the same | |
| `--short-read 256` | a 190-token turn 2.0 s against 0.57 | the same | keep the default (64) |
| `--kv int8`, `k8v4`, `q4_0` | the same | the same | 1.5, 1.8 and 2.2 GB less memory at a 131K context: only a few of this model's layers keep K/V |
| Context 65,536 or 262,144 instead of 131,072 | the same at a 25K prompt | the same | 2.6 GB less, 5.3 GB more |
| Pictures off | 13% quicker in one start, the same in two others | the same | not shown; the idle picture reader keeps the GPU no busier |

Writing does slow somewhat deep into a conversation: after a 55K-token prompt, code 63 to 66 tokens/s, prose 49 to 52 and copying 69 to 77, against 72 to 75, 60 to 62 and 88 to 95 after a short one (0.1.63, the same session, three runs each).

## What this changed in the design (#173)

All of it is built (#291, #292, #293); where pi² does it is in [local-models.md](local-models.md) and [local-models-running.md](local-models-running.md). Two things found while building it: Metal lets one program keep 115.4 GB of the M5 Max's 137.4 GB (`recommendedMaxWorkingSetSize`; MAC.md's "107.5 GB" is GiB), not three quarters; and Unsloth's files on `main` are no longer the ones Strata pins (it has re-sharded UD-Q4_K_XL), which is why pi² downloads from the pinned commit (#342).

- **The engine is two components.** `local-models.json`'s `engine` names both the engine package (a folder, not one file) and the control package, with both versions, as #292 now writes it; for the server to find the engine, it is also installed into Strata's component folder with `strata components install-file`.
- **Pin the model files' commit.** Strata downloads `resolve/<commit>/` at a pinned commit (`ed59f920…` for ISTA-DASLab), not `resolve/main/`: if a repository changes its files, a pinned URL still gives the bytes whose SHA-256 pi² knows, where `main` would give a file that fails the check.
- **Installing a model has a preparation step after the download**, with the network (the draft layer), about 7 minutes plus 5.2 GB, and its own progress lines. Its result, the run config, is what starting needs: the model's entry names it.
- **Updating the control package** means preparing each model again (its run config names files inside the old control folder). Updating only the engine does not.
- **Starting is slow the first time** (about 160 s, then a minute more on the first long prompt), and about 20 s after that. Show that it is starting, relay the server's lines, and do not time out early. A "Try it" at the end of setting up takes the slow first start out of the person's first conversation, if it sends a message longer than 64 tokens.
- **The port opens only when the model is loaded**, so readiness is the ready file (or the port answering `/health`), not the process having started.
- **Stopping** is SIGTERM to the server by pid; its children are in process groups of their own and are ended by Strata's watchers, not by pi²'s group signal.
- **One request at a time by default** was the design; since #605 it is four, with Strata 0.1.63 ([Several requests at once](#several-requests-at-once-605)). Which to use is a setting fixed at start.
- **Memory**: about 60 GB held while loaded, and most of it wired. Offer IQ3_S from 96 GB, and say plainly that the Mac has that much less while the model is loaded.
- **Tools and pictures work** through the OpenAI API, and thinking is `reasoning_content`, so the model can be an OpenAI-completions model in pi²'s providers with tools, images and reasoning marked on.
- **The licence** (Qwen Community License 1.0, clause 2) is for the owner to read before pi² offers the model; see [Licences](#licences).
- Nothing found changes the shape of #173 itself: separate downloads, a choice of pack, a pinned version with checksums, start on first use, stop when unused, all hold.

## For the stand-in in tests

Strata has a stand-in of its own: `server.py --engine mock` serves the same HTTP API with no engine and no model, with a scripted answer (`--script TEXT`, given more than once for answers in turn, and `--script-delay S` between tokens). It is the reference for what the real server returns, but CI cannot download it, so pi²'s own stand-in copies its shapes: the ready file, `/health`, `/v1/models`, streamed chunks with `reasoning_content` and `content`, a tool call as a first `tool_calls` delta with its id and name followed by its arguments in pieces (the mock sends them whole; the real server in pieces, as [above](#tools)) and `finish_reason: "tool_calls"`, usage in the last chunk, and a clean exit on SIGTERM that removes the ready file. Even the mock took about 20 seconds to be ready on this busy Mac (Python's imports), so do not give a start a short timeout.

## What is on this Mac

The trial left everything in one folder, `~/Library/Caches/pi2-local-trial`, 86 GiB in all, for #293 to use instead of downloading again:

| Path | What | Size |
| --- | --- | --- |
| `dl/` | the two Strata archives as downloaded | 52 MB |
| `control/0.1.61/` | the control package unpacked, with the run config `strata-iq3_s.json`, the engine's log `strata-iq3_s.log` and Strata's `run-iq3_s.sh` | 161 MB |
| `home/` | what Strata wrote under `HOME`, `XDG_DATA_HOME` and `STRATA_HOME`; the installed engine is `home/.local/share/strata/components/engine/0.1.60-macos-arm64-metal/` | 15 MB |
| `models/qwen3.8-flash-next-IQ3_S/` | the two IQ3_S shards and the mmproj file, SHA-256 checked | 79 GiB |
| `data/packs/iq3_s/` | the prepared pack | 1.4 GiB |
| `data/mtp/` | the draft layer: `mtp-q2_0.gguf` (0.9 GB) and the 4.9 GiB of fetched tensors it was made from | 5.7 GiB |
| `download-iq3s.sh`, `download-ranges.sh` | the scripts that downloaded the pack | |
| `run/key` | the API key the trial used | |

To start it again as the trial did, with `T=~/Library/Caches/pi2-local-trial` and `C=$T/control/0.1.61`:

```sh
STRATA_API_KEY=$(cat $T/run/key) HOME=$T/home XDG_DATA_HOME=$T/home/.local/share STRATA_HOME=$T/home/.strata PYTHONNOUSERSITE=1 \
  $C/python/bin/python3 $C/serve/server.py --engine strata --config $C/strata-iq3_s.json \
    --host 127.0.0.1 --port 0 --ready-file $T/run/ready.json
```

The whole folder can be deleted when it is no longer wanted; nothing outside it was installed or changed.

#293 set the model up in a throwaway copy of pi² from this folder, with Settings' Agree and Use Files on This Mac…: pi² cloned the three model files and the draft layer's tensors from `models/` and `data/mtp/` (clones take no room on the same disk) and checked them, so nothing was downloaded again but the engine's 54 MB. The folder was not changed.
