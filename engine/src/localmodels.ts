// Models on this Mac, the downloads piece (#292 of #173): getting the Strata engine and a model pack onto the Mac,
// checked, and setting them up. Starting and stopping a model is another piece's (#291), which reads what this one
// writes to `local-models.json`:
//
//   { "engine": { "version", "path", "folder", "control": { "version", "folder" }, "component" } | null,
//     "models": [{ "id", "name", "pack", "path", "contextSize", "config", "preparedWith",
//                  "options": { "vision", "visionFile", "parallel" } }] }
//
// The engine's `path` is its executable, and `folder` the whole engine package; `control` is Strata's control package,
// with the server that starts the engine (#290). A model's `path` is its pack's first file, with the others beside it. Nothing is listed there before
// every one of its files has been downloaded and matched the size and SHA-256 written in localcatalog.ts, and the
// engine's archive is unpacked, and its executable made runnable, only after that. See docs/local-models.md.
//
// A download keeps going across a pause, pi² quitting, the engine restarting or the network dropping: what it has
// is kept in `<file>.part` files, `local-setup.json` says which downloads are under way, and the next engine carries
// on with those that were running. Cancelling one removes what it left. The files go in folders of pi²'s own,
// which pi²'s backup does not copy and which are marked for Time Machine to skip.
//
// A pack whose files have all matched is not ready to run yet: Strata's own setup prepares it once (#293), from the
// control package, with Strata's folders in pi²'s (`strataEnvironment`): a pack folder made from the first file, the
// draft layer it fetches from Qwen's original model, and a run config. pi² keeps a copy of that run config and names it
// in the model's entry (`config`), which the running piece starts the server with; only then is the model listed. The
// files the person already has on this Mac (`from`) are used in place of downloading them, once their size and SHA-256
// match: cloned where the disk can (APFS), copied where it cannot.

import { type ChildProcess, execFile, spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { chmodSync, closeSync, constants, createReadStream, createWriteStream, existsSync, lstatSync, mkdirSync, openSync, readdirSync, readFileSync, renameSync, rmSync, statfsSync, statSync, writeFileSync, writeSync } from "node:fs";
import { copyFile } from "node:fs/promises";
import { homedir, totalmem } from "node:os";
import { basename, dirname, isAbsolute, join, sep } from "node:path";
import { promisify } from "node:util";
import type { Api, Model } from "@earendil-works/pi-ai";
import { DownloadError, download as downloadFile } from "./download.ts";
import { commandEnvironment } from "./environment.ts";
import type { Feature } from "./features.ts";
import { STRATA_SETUP, type StrataCommand } from "./localengine.ts";
import { forgetRun, leftOverLog, newRun, noteProcess, RUN_VARIABLE, type RunProcess, signallable, stopLeftOver } from "./processes.ts";
import {
	CATALOG,
	type Catalog,
	type CatalogFile,
	type CatalogPack,
	CONTEXT_MEASURED,
	CONTEXT_SIZES,
	KEEP_FREE_BYTES,
	KV_BYTES_PER_TOKEN,
	METAL_SHARE,
	SMALLEST_MAC_GB,
} from "./localcatalog.ts";

const run = promisify(execFile);

export type ModelOptions = { vision: boolean; visionFile: string | null; parallel: number };
export type InstalledModel = {
	id: string;
	name: string;
	pack: string;
	path: string;
	contextSize: number;
	/** pi²'s copy of the run config Strata's setup wrote when it prepared the model; absent while it is being prepared again. */
	config?: string;
	/** The version of the control package it was prepared with: a new one means preparing it again. */
	preparedWith?: string;
	options: ModelOptions;
};
/** `component`: the engine is installed where Strata's server finds it (`strata components install-file`), as 0.8.0 did not do. */
export type InstalledEngine = { version: string; path: string; folder: string; control: { version: string; folder: string }; component?: boolean };
export type Installed = { engine: InstalledEngine | null; models: InstalledModel[] };

/** `waiting`: downloaded and checked, waiting for the engine before it can be prepared. */
type DownloadState = "running" | "paused" | "failed" | "waiting";
/** A download under way, as kept in `local-setup.json` so that the next engine carries on with it. */
type StoredDownload = {
	/** "engine", or the pack's id. */
	id: string;
	kind: "engine" | "model";
	/** The engine's version and its control package's ("0.1.60/0.1.61"), or the pack's id. */
	target: string;
	/** For a model, the folder its files go in. */
	folder: string | null;
	state: DownloadState;
	error: string | null;
	/** For a model: `prepare` once every file has matched, and Strata's setup is to prepare it (or prepare it again). */
	stage?: "download" | "prepare";
	/** For a model: a folder of the person's to take its files from, where they are there and match, before downloading. */
	from?: string | null;
	/** Strata's setup while it prepares the model, for the next engine to stop should this one die. */
	process?: RunProcess;
};
type Setup = { folder: string | null; downloads: StoredDownload[] };

/** What a running download is doing, in memory only. */
type Live = {
	controller: AbortController;
	done: Promise<void>;
	phase: "checking" | "downloading" | "waiting" | "unpacking" | "copying" | "preparing";
	/** Bytes of all its files on disk. */
	received: number;
	total: number;
	/** When it is waiting to try again: why, and when it will. */
	retry: { reason: string; at: number } | null;
	/** While Strata's setup prepares it: the step it is at (of 7), what it says it is doing, and how far, when it says. */
	prepare: { step: number | null; stage: string | null; fraction: number | null; startedAt: number } | null;
	/** Strata's setup, while it runs. */
	child?: ChildProcess;
	lastSent: number;
};

/** Settings for tests, from the environment. The catalog can be replaced only by naming a file, which a test does. */
const TUNING = {
	stallMs: Number(process.env.PI2_LOCAL_STALL_MS ?? 60_000),
	retryMs: Number(process.env.PI2_LOCAL_RETRY_MS ?? 2_000),
	retries: Number(process.env.PI2_LOCAL_RETRIES ?? 8),
	keepFree: Number(process.env.PI2_LOCAL_KEEP_FREE ?? KEEP_FREE_BYTES),
	memoryGB: process.env.PI2_LOCAL_MEMORY_GB === undefined ? undefined : Number(process.env.PI2_LOCAL_MEMORY_GB),
};

function loadCatalog(): Catalog {
	const file = process.env.PI2_LOCAL_CATALOG;
	return file === undefined ? CATALOG : (JSON.parse(readFileSync(file, "utf8")) as Catalog);
}

let changed: () => void = () => {};
/** Send the `local` event (what `local.status` answers) to every app: for a change to what is installed or running. */
export function localChanged(): void {
	changed();
}

const GB = 1e9;
const formatGB = (bytes: number) => (bytes < GB ? `${(bytes / 1e6).toFixed(1)} MB` : `${(bytes / GB).toFixed(bytes < 10 * GB ? 1 : 0)} GB`);
const tilde = (path: string) => (path.startsWith(`${homedir()}/`) ? `~${path.slice(homedir().length)}` : path);

/** Where Strata's setup puts what it makes for a pack (the pack folder, the draft layer): beside the pack's files. */
const PREPARED_FOLDER = "prepared";

/**
 * What Try It sends: longer than 64 tokens, since the first prompt that long after the first start makes Strata compile
 * more of its kernels, which took a minute (#290). Sent with thinking off, so the answer is quick.
 */
const TRY_MESSAGE =
	"This is pi², the app you are running in on this Mac, checking that you are set up and answer. The person who set you up has just pressed Try It in Settings, and will see your answer under the button, so keep it short and friendly: one sentence that greets them and says you are ready to help with their work. Do not use a list, a heading or Markdown.";

export const localModels: Feature = (host, engine) => {
	const catalog = loadCatalog();
	const root = join(engine.home, "local");
	const installedFile = join(engine.home, "local-models.json");
	const setupFile = join(engine.home, "local-setup.json");
	const live = new Map<string, Live>();
	let installed: Installed = { engine: null, models: [] };
	let setup: Setup = { folder: null, downloads: [] };

	const packs = () => catalog.models.flatMap((model) => model.packs.map((pack) => ({ model, pack })));
	const findPack = (id: string) => packs().find((entry) => entry.pack.id === id);
	const memoryGB = () => TUNING.memoryGB ?? totalmem() / 2 ** 30;
	const supported = () => process.platform === "darwin" && process.arch === "arm64";
	const defaultContext = () => (memoryGB() >= 96 ? 65_536 : 32_768);
	const defaultFolder = () => join(root, "models");
	const modelsFolder = () => setup.folder ?? defaultFolder();

	function writeJson(path: string, value: unknown): void {
		const temporary = `${path}.${process.pid}.tmp`;
		writeFileSync(temporary, `${JSON.stringify(value, null, "\t")}\n`);
		renameSync(temporary, path);
	}
	/** Writes `local-models.json`, and sends the providers again: the model selector offers what is set up (#291). */
	const saveInstalled = () => {
		writeJson(installedFile, installed);
		engine.providersChanged();
	};
	const saveSetup = () => writeJson(setupFile, setup);

	/** Marks a folder for Time Machine to skip. pi²'s own backup copies named files only, never these folders. */
	async function makeFolder(folder: string): Promise<void> {
		mkdirSync(folder, { recursive: true });
		await run("/usr/bin/tmutil", ["addexclusion", folder]).catch((error: Error) => engine.log(`local models: could not mark ${folder} for Time Machine to skip: ${error.message}`));
	}

	// ---- What fits

	type Fit = "fits" | "tight" | "streams" | "no";
	function fit(pack: CatalogPack): Fit {
		const memory = memoryGB();
		if (memory < SMALLEST_MAC_GB) return "no";
		if (memory >= pack.recommendedFromGB) return "fits";
		if (memory * METAL_SHARE >= pack.needsGB) return "tight";
		return "streams";
	}
	const FIT_NOTES: Record<Fit, string> = {
		fits: "Fits this Mac's memory.",
		tight: "Fits, with little memory left for other apps while it runs.",
		streams: "Too big to stay in this Mac's memory: it runs, reading from the SSD, but much more slowly.",
		no: "This Mac has too little memory to run it.",
	};
	/** The pack to recommend: the first of the catalog's preference that fits, else one that fits tightly, else the smallest. */
	function recommended(): string | null {
		if (!supported() || memoryGB() < SMALLEST_MAC_GB) return null;
		const usable = catalog.preference.map(findPack).filter((entry) => entry !== undefined && entry.pack.unavailable === undefined).map((entry) => entry!.pack);
		return (usable.find((pack) => fit(pack) === "fits") ?? usable.find((pack) => fit(pack) === "tight") ?? usable.at(-1))?.id ?? null;
	}

	// ---- Status

	function sizeOf(path: string): number {
		try {
			return statSync(path).size;
		} catch {
			return 0;
		}
	}
	/** Bytes of the files under `path`, a folder or one file; 0 when there is nothing there. */
	function sizeOfTree(path: string): number {
		try {
			const stat = lstatSync(path);
			if (!stat.isDirectory()) return stat.isFile() ? stat.size : 0;
			return readdirSync(path).reduce((sum, name) => sum + sizeOfTree(join(path, name)), 0);
		} catch {
			return 0;
		}
	}

	/**
	 * Folders under `from`, itself first, to at most three levels below it, nearest first: where the files the person
	 * already has may be, in whatever layout (Strata's own data folder has `models/<pack>/` and `mtp/`). Hidden folders
	 * and links are not followed, and pi²'s own folders for the pack are left out.
	 */
	function foldersUnder(from: string, skip: string): string[] {
		const found: string[] = [];
		let level = [from];
		for (let depth = 0; depth <= 3 && level.length > 0 && found.length < 2_000; depth++) {
			const next: string[] = [];
			for (const dir of level) {
				if (dir === skip) continue;
				found.push(dir);
				try {
					for (const item of readdirSync(dir, { withFileTypes: true })) if (item.isDirectory() && !item.name.startsWith(".")) next.push(join(dir, item.name));
				} catch {
					// Not readable: nothing of it is used.
				}
			}
			level = next.sort();
		}
		return found;
	}
	/** A file of a pack in the person's folder: by its name and its size, which its checksum is still to confirm. */
	function findFile(from: string, file: CatalogFile, skip = ""): string | undefined {
		return foldersUnder(from, skip)
			.map((dir) => join(dir, file.name))
			.find((path) => {
				try {
					const stat = lstatSync(path);
					return stat.isFile() && stat.size === file.size;
				} catch {
					return false;
				}
			});
	}
	/** The draft layer's tensors Strata's setup fetched once, in the person's folder: its `mtp` folder, with its list of them. */
	function findDraftLayer(from: string, skip: string): string | undefined {
		return foldersUnder(from, skip).find((dir) => existsSync(join(dir, "mtp-inventory.json")) && existsSync(join(dir, "tensors")));
	}

	/** Bytes of a pack's files already on disk in `folder`, whole or in part. */
	function onDisk(files: CatalogFile[], folder: string): number {
		return files.reduce((sum, file) => sum + (existsSync(join(folder, file.name)) ? file.size : sizeOf(join(folder, `${file.name}.part`))), 0);
	}
	const engineFiles = () => [catalog.engine.archive, catalog.engine.control.archive];
	const engineTarget = () => `${catalog.engine.version}/${catalog.engine.control.version}`;
	const filesOf = (download: StoredDownload): CatalogFile[] => (download.kind === "engine" ? engineFiles() : (findPack(download.target)?.pack.files ?? []));
	const folderOf = (download: StoredDownload) => (download.kind === "engine" ? join(root, "downloads") : download.folder!);

	function downloadStatus(download: StoredDownload) {
		const running = live.get(download.id);
		const total = filesOf(download).reduce((sum, file) => sum + file.size, 0);
		const prepared = installed.models.some((model) => model.id === download.target);
		const name = download.kind === "engine" ? `Strata engine ${download.target.split("/")[0]}` : (() => {
			const entry = findPack(download.target);
			return entry === undefined ? download.target : `${entry.model.name} (${entry.pack.pack})`;
		})();
		return {
			id: download.id,
			kind: download.kind,
			target: download.target,
			name,
			state: download.state,
			phase: running?.phase ?? null,
			error: download.error,
			received: running?.received ?? onDisk(filesOf(download), folderOf(download)),
			total,
			retry: running?.retry ?? null,
			/** `prepare` once its files are all here and Strata's setup prepares it; `again` when it was set up before. */
			stage: download.stage ?? "download",
			again: prepared,
			prepare: running?.prepare ?? null,
			from: download.from ?? null,
			log: download.kind === "model" ? prepareLog(download.target) : null,
		};
	}
	const prepareLog = (id: string) => join(engine.home, "local", "logs", `${id}.prepare.log`);

	function freeBytes(folder: string): number | null {
		try {
			let probe = folder;
			while (!existsSync(probe) && dirname(probe) !== probe) probe = dirname(probe);
			const stats = statfsSync(probe);
			return stats.bavail * stats.bsize;
		} catch {
			return null;
		}
	}

	function status(): Record<string, unknown> {
		const memory = memoryGB();
		const best = recommended();
		const own: Record<string, unknown> = {
			platform: {
				supported: supported(),
				why: supported() ? null : "Strata runs only on Macs with Apple silicon (M1 or newer). This Mac cannot run it.",
				memoryGB: Math.round(memory),
				limitGB: Math.round(memory * METAL_SHARE * 10) / 10,
			},
			engine: {
				installed: installed.engine,
				pinned: {
					version: catalog.engine.version,
					controlVersion: catalog.engine.control.version,
					size: engineFiles().reduce((sum, file) => sum + file.size, 0),
					licences: catalog.engine.licences,
				},
				update: installed.engine !== null && !current(installed.engine),
			},
			catalog: catalog.models.map((model) => ({
				id: model.id,
				name: model.name,
				packs: model.packs.map((pack) => ({
					id: pack.id,
					pack: pack.pack,
					provider: pack.provider,
					note: pack.note,
					needsGB: pack.needsGB,
					size: pack.files.reduce((sum, file) => sum + file.size, 0),
					prepareSize: pack.prepareBytes,
					fit: fit(pack),
					fitNote: FIT_NOTES[fit(pack)],
					recommended: pack.id === best,
					licences: pack.licences,
					unavailable: pack.unavailable ?? null,
					installed: installed.models.some((installedModel) => installedModel.id === pack.id),
				})),
			})),
			models: installed.models.map((model) => ({ ...model, needsGB: findPack(model.id)?.pack.needsGB ?? null, prepared: model.config !== undefined || findPack(model.id)?.pack.prepare == null })),
			downloads: setup.downloads.map(downloadStatus),
			folder: { path: modelsFolder(), isDefault: setup.folder === null, free: freeBytes(modelsFolder()) },
			context: {
				sizes: CONTEXT_SIZES,
				default: defaultContext(),
				measured: CONTEXT_MEASURED,
				gbPerToken: KV_BYTES_PER_TOKEN / GB,
			},
		};
		return Object.assign(own, ...host.features.map((feature) => feature.localStatus?.() ?? {}));
	}
	/** Whether the engine set up is the one pi² pins, control package and all, and installed where Strata's server finds it. */
	const current = (set: InstalledEngine) => set.version === catalog.engine.version && set.control?.version === catalog.engine.control.version && set.component === true;
	const announce = () => engine.broadcast({ event: "local", ...status() });
	changed = announce;

	function progress(download: StoredDownload, force = false): void {
		const running = live.get(download.id);
		if (running === undefined) return;
		const now = Date.now();
		if (!force && now - running.lastSent < 500) return;
		running.lastSent = now;
		engine.broadcast({ event: "local.progress", download: downloadStatus(download) });
	}

	// ---- Space

	/** Throws, in plain words, when the downloads would leave less than pi² keeps free on the disk. */
	function checkSpace(download: StoredDownload): void {
		const folder = folderOf(download);
		const free = freeBytes(folder);
		if (free === null) return;
		// Other downloads under way on the same disk need their room too.
		const device = (path: string) => {
			let probe = path;
			while (!existsSync(probe) && dirname(probe) !== probe) probe = dirname(probe);
			return statSync(probe).dev;
		};
		const remaining = (d: StoredDownload) => {
			const files = filesOf(d);
			const bytes = files.reduce((sum, file) => sum + file.size, 0);
			// The engine is unpacked beside its archives, to about three times their size; Strata's setup prepares a pack beside its files.
			if (d.kind === "engine") return Math.max(0, bytes * 4 - onDisk(files, folderOf(d)));
			const prepared = Math.max(0, (findPack(d.target)?.pack.prepareBytes ?? 0) - sizeOfTree(join(folderOf(d), PREPARED_FOLDER)));
			// Files of the person's own on the same disk are cloned, which takes no room.
			const clones = d.from != null && existsSync(d.from) && device(d.from) === device(folderOf(d));
			const left = files.reduce((sum, file) => {
				if (existsSync(join(folderOf(d), file.name))) return sum;
				if (clones && findFile(d.from!, file) !== undefined) return sum;
				return sum + file.size - sizeOf(join(folderOf(d), `${file.name}.part`));
			}, 0);
			return Math.max(0, left) + prepared;
		};
		const here = device(folder);
		const others = setup.downloads.filter((d) => d.id !== download.id && d.state === "running" && device(folderOf(d)) === here);
		const needed = remaining(download) + others.reduce((sum, d) => sum + remaining(d), 0);
		if (free - needed >= TUNING.keepFree) return;
		const where = download.kind === "model" ? " or choose another folder for models" : "";
		throw new Error(
			`Not enough free disk space: this needs ${formatGB(needed)} more${others.length > 0 ? ", with the other downloads under way," : ""} and pi² leaves ${formatGB(TUNING.keepFree)} free for the Mac, but the disk has ${formatGB(free)} free. Free up some space${where}, then try again.`,
		);
	}

	// ---- Downloading

	/** A model downloaded and checked that cannot be prepared until the engine is set up: it waits, and starts by itself. */
	class NeedsEngine extends Error {}

	function start(download: StoredDownload): void {
		if (live.has(download.id)) return;
		const controller = new AbortController();
		const total = filesOf(download).reduce((sum, file) => sum + file.size, 0);
		const entry: Live = { controller, done: Promise.resolve(), phase: "downloading", received: download.stage === "prepare" ? total : 0, total, retry: null, prepare: null, lastSent: 0 };
		live.set(download.id, entry);
		entry.done = (async () => {
			try {
				if (download.kind === "engine") await fetchEngine(download, entry);
				else {
					if (download.stage !== "prepare") {
						await fetchModel(download, entry);
						download.stage = "prepare";
						saveSetup();
					}
					await prepareModel(download, entry);
				}
				setup.downloads = setup.downloads.filter((d) => d !== download);
				saveSetup();
				engine.log(`local models: ${download.kind === "engine" ? `Strata ${download.target}` : download.target} is downloaded, checked and set up`);
				if (download.kind === "engine") afterEngine();
			} catch (error) {
				if (controller.signal.aborted) return; // paused, cancelled or the engine stopping: whoever stopped it says what comes next
				download.state = error instanceof NeedsEngine ? "waiting" : "failed";
				download.error = error instanceof Error ? error.message : String(error);
				saveSetup();
				engine.log(`local models: ${download.state === "waiting" ? "waiting:" : `the ${download.stage === "prepare" ? "preparation" : "download"} of ${download.target} stopped:`} ${download.error}`);
			} finally {
				live.delete(download.id);
				announce();
			}
		})();
		announce();
	}

	/** Once the engine is set up: the models waiting for it are prepared, and those prepared with another control package are prepared again. */
	function afterEngine(): void {
		queueReprepare();
		for (const download of setup.downloads) {
			if (download.kind !== "model" || download.state !== "waiting" || live.has(download.id)) continue;
			try {
				begin(download);
			} catch (error) {
				download.state = "failed";
				download.error = (error as Error).message;
				saveSetup();
			}
		}
		announce();
	}

	/**
	 * Models set up that have no run config from the control package installed now (after an update of it, or one whose
	 * run config was removed): each is prepared again, and is not started meanwhile. Its files and settings stay.
	 */
	function queueReprepare(): void {
		const set = installed.engine;
		if (set === null || !current(set)) return;
		let changed = false;
		for (const model of installed.models) {
			const pack = findPack(model.id)?.pack;
			if (pack?.prepare == null) continue;
			const stale = model.config === undefined || !existsSync(model.config) || model.preparedWith !== set.control.version;
			if (!stale || setup.downloads.some((d) => d.id === model.id)) continue;
			if (model.config !== undefined) {
				delete model.config;
				changed = true;
			}
			const download: StoredDownload = { id: model.id, kind: "model", target: model.id, folder: dirname(model.path), state: "running", error: null, stage: "prepare", from: null };
			setup.downloads.push(download);
			engine.log(`local models: ${model.id} is prepared again for Strata's control package ${set.control.version}`);
			try {
				begin(download);
			} catch (error) {
				download.state = "failed";
				download.error = (error as Error).message;
				saveSetup();
			}
		}
		if (changed) saveInstalled();
	}

	function options(download: StoredDownload, entry: Live, before: number) {
		return {
			signal: entry.controller.signal,
			stallMs: TUNING.stallMs,
			retries: TUNING.retries,
			retryMs: TUNING.retryMs,
			progress: (received: number) => {
				if (entry.phase !== "downloading" || entry.retry !== null) {
					entry.phase = "downloading";
					entry.retry = null;
					announce();
				}
				entry.received = before + received;
				progress(download);
			},
			checking: () => {
				entry.phase = "checking";
				announce();
			},
			retrying: (error: DownloadError, delayMs: number) => {
				entry.phase = "waiting";
				entry.retry = { reason: error.message, at: Date.now() + delayMs };
				engine.log(`local models: ${download.target}: ${error.message} Trying again in ${Math.round(delayMs / 1000)} s.`);
				announce();
			},
		};
	}

	async function fetchEngine(download: StoredDownload, entry: Live): Promise<void> {
		const pinned = catalog.engine;
		const folder = join(root, "downloads");
		await makeFolder(root);
		mkdirSync(folder, { recursive: true });
		// Both archives are downloaded and checked before either is unpacked.
		let before = 0;
		for (const file of engineFiles()) {
			const archive = join(folder, file.name);
			// An archive is moved to its name only once it has matched, so one there is whole and checked.
			if (!existsSync(archive)) await downloadFile(file, archive, options(download, entry, before));
			before += file.size;
			entry.received = before;
		}
		entry.phase = "unpacking";
		announce();
		const unpacked = await unpack(join(folder, pinned.archive.name), join(root, "engine"), pinned.version, pinned.executable);
		const control = await unpack(join(folder, pinned.control.archive.name), join(root, "control"), pinned.control.version);
		// Strata's server finds its engine in its own component folder, not by a path: installed there from the archive.
		await installComponent(control.folder, join(folder, pinned.archive.name), entry.controller.signal);
		for (const file of engineFiles()) rmSync(join(folder, file.name), { force: true });
		removeIfEmpty(folder);
		const previous = installed.engine;
		installed.engine = { version: pinned.version, path: unpacked.executable!, folder: unpacked.folder, control: { version: pinned.control.version, folder: control.folder }, component: true };
		saveInstalled();
		if (previous?.folder !== undefined && previous.folder !== unpacked.folder) rmSync(previous.folder, { recursive: true, force: true });
		if (previous?.control?.folder !== undefined && previous.control.folder !== control.folder) rmSync(previous.control.folder, { recursive: true, force: true });
	}

	/**
	 * Unpacks an archive, already checked, into `<parent>/<version>`, and finds `executable` in it and makes it runnable.
	 * Nothing in it is run here, and nothing outside that folder is written: entries with absolute paths or `..` are
	 * refused, and macOS's tar does not write through a link it unpacked.
	 */
	async function unpack(archive: string, parent: string, version: string, executable?: string): Promise<{ folder: string; executable?: string }> {
		const { stdout } = await run("/usr/bin/tar", ["-tzf", archive], { maxBuffer: 64 * 1024 * 1024 });
		const entries = stdout.split("\n").filter((line) => line !== "");
		if (entries.some((name) => isAbsolute(name) || name.split("/").includes(".."))) throw new Error("The engine's archive holds a file that would go outside its folder, so it was not unpacked.");
		const staging = join(parent, `.${version}.unpacking`);
		rmSync(staging, { recursive: true, force: true });
		mkdirSync(staging, { recursive: true });
		await run("/usr/bin/tar", ["-xzf", archive, "-C", staging, "--no-same-owner"]);
		let found: string | undefined;
		if (executable !== undefined) {
			found = shallowest(staging, executable);
			if (found === undefined) {
				rmSync(staging, { recursive: true, force: true });
				throw new Error(`The engine's archive has no ${executable} in it, so it cannot be used. pi² needs an update.`);
			}
			chmodSync(found, 0o755);
		}
		const final = join(parent, version);
		rmSync(final, { recursive: true, force: true });
		renameSync(staging, final);
		return { folder: final, executable: found === undefined ? undefined : join(final, found.slice(staging.length + 1)) };
	}

	/** The shallowest regular file (not a link) called `name` under `folder`. */
	function shallowest(folder: string, name: string): string | undefined {
		let level = [folder];
		for (let depth = 0; depth < 6 && level.length > 0; depth++) {
			const next: string[] = [];
			for (const dir of level) {
				for (const item of readdirSync(dir, { withFileTypes: true })) {
					const path = join(dir, item.name);
					if (item.isFile() && item.name === name && lstatSync(path).isFile()) return path;
					if (item.isDirectory()) next.push(path);
				}
			}
			level = next.sort();
		}
		return undefined;
	}

	async function fetchModel(download: StoredDownload, entry: Live): Promise<void> {
		const found = findPack(download.target);
		if (found === undefined) throw new Error("pi² no longer offers this pack.");
		const { pack } = found;
		const folder = download.folder!;
		await makeFolder(folder);
		let before = 0;
		for (const file of pack.files) {
			const dest = join(folder, file.name);
			// A file is moved to its name only once it has matched, so one there is whole and checked.
			if (!existsSync(dest) || sizeOf(dest) !== file.size) {
				const mine = download.from != null && !existsSync(`${dest}.part`) ? findFile(download.from, file, folder) : undefined;
				if (mine === undefined || !(await adopt(mine, file, dest, download, entry, before))) await downloadFile(file, dest, options(download, entry, before));
			}
			before += file.size;
			entry.received = before;
		}
	}

	/**
	 * Takes a file of the person's own in place of downloading it: cloned where the disk can (APFS, the same volume: no
	 * time, no room), else copied, then checked against its SHA-256 as a download is. Answers whether it matched; one that
	 * does not is left where it was, and downloaded instead.
	 */
	async function adopt(source: string, file: CatalogFile, dest: string, download: StoredDownload, entry: Live, before: number): Promise<boolean> {
		const part = `${dest}.part`;
		const signal = entry.controller.signal;
		const counted = (bytes: number) => {
			entry.received = before + bytes;
			progress(download);
		};
		rmSync(part, { force: true });
		let digest: string;
		try {
			// `cp -c` clones or fails (clonefile(2)); Node's own clone-or-fail is not there on macOS (ENOSYS).
			await run("/bin/cp", ["-c", source, part], { signal });
			entry.phase = "checking";
			announce();
			digest = await hashOf(part, signal, counted);
		} catch (error) {
			if (signal.aborted) throw error;
			// Another disk, or one that cannot clone: a copy, checked as it is made.
			entry.phase = "copying";
			announce();
			digest = await copyHashing(source, part, signal, counted);
		}
		if (digest !== file.sha256) {
			rmSync(part, { force: true });
			engine.log(`local models: ${source} is not the file pi² expected (its checksum does not match), so it is downloaded instead`);
			return false;
		}
		renameSync(part, dest);
		engine.log(`local models: ${file.name} taken from ${source}, checked`);
		return true;
	}

	/** The SHA-256 of a file, read in large pieces, saying how far it has read. */
	async function hashOf(path: string, signal: AbortSignal, read: (bytes: number) => void): Promise<string> {
		const hash = createHash("sha256");
		let done = 0;
		for await (const chunk of createReadStream(path, { highWaterMark: 8 * 1024 * 1024, signal })) {
			hash.update(chunk as Buffer);
			done += (chunk as Buffer).length;
			read(done);
		}
		return hash.digest("hex");
	}
	/** Copies a file, working out its SHA-256 from what it reads. */
	async function copyHashing(source: string, dest: string, signal: AbortSignal, read: (bytes: number) => void): Promise<string> {
		const hash = createHash("sha256");
		const out = createWriteStream(dest);
		let done = 0;
		try {
			for await (const chunk of createReadStream(source, { highWaterMark: 8 * 1024 * 1024, signal })) {
				hash.update(chunk as Buffer);
				if (!out.write(chunk)) await new Promise((resolve) => out.once("drain", resolve));
				done += (chunk as Buffer).length;
				read(done);
			}
		} finally {
			await new Promise((resolve) => out.end(resolve));
		}
		return hash.digest("hex");
	}

	// ---- Preparing a pack with Strata's setup

	/** One preparation at a time: two would share Strata's settings and the control package's folder. */
	let preparing: Promise<void> = Promise.resolve();

	/**
	 * Prepares a model whose files have all matched, with Strata's setup (localengine.ts, `STRATA_SETUP`), and lists it
	 * with its run config. Throws `NeedsEngine` while the engine is not set up; the model waits, and is prepared once it is.
	 * Run again after a stop, setup keeps and skips what it had done; the draft layer it fetches carries on where it was.
	 */
	async function prepareModel(download: StoredDownload, entry: Live): Promise<void> {
		const found = findPack(download.target);
		if (found === undefined) throw new Error("pi² no longer offers this pack.");
		const { model, pack } = found;
		const folder = download.folder!;
		const existing = installed.models.find((m) => m.id === pack.id);
		const list = (config?: string, control?: string) => {
			const entryFor: InstalledModel = existing ?? {
				id: pack.id,
				name: `${model.name} (${pack.pack})`,
				pack: pack.pack,
				path: join(folder, pack.files[0]!.name),
				contextSize: defaultContext(),
				options: { vision: pack.visionFile !== null, visionFile: pack.visionFile === null ? null : join(folder, pack.visionFile), parallel: 1 },
			};
			if (config !== undefined) {
				entryFor.config = config;
				entryFor.preparedWith = control;
			}
			installed.models = [...installed.models.filter((m) => m.id !== pack.id), entryFor];
			saveInstalled();
		};
		// A pack with nothing to prepare (a test's) is ready once its files are.
		if (pack.prepare == null) return list();
		const set = installed.engine;
		if (set === null || !current(set)) {
			throw new NeedsEngine(
				`Downloaded and checked. Preparing it for Strata needs the engine${set === null ? "" : " as this pi² sets it up"}: ${set === null ? "get Strata above" : "update Strata above"}, and preparing starts by itself.`,
			);
		}
		const names = pack.prepare;
		const control = set.control.folder;
		entry.phase = "preparing";
		entry.received = entry.total;
		entry.prepare = { step: null, stage: null, fraction: null, startedAt: Date.now() };
		announce();

		const previous = preparing;
		let release = () => {};
		preparing = new Promise<void>((resolve) => (release = resolve));
		try {
			const signal = entry.controller.signal;
			entry.prepare.stage = "waiting for another model to finish preparing";
			await new Promise<void>((resolve, reject) => {
				if (signal.aborted) return reject(signal.reason);
				signal.addEventListener("abort", () => reject(signal.reason), { once: true });
				previous.then(resolve);
			});
			entry.prepare = { step: null, stage: null, fraction: null, startedAt: Date.now() };
			announce();
			const data = join(folder, PREPARED_FOLDER);
			mkdirSync(data, { recursive: true });
			// The draft layer's tensors from the person's own Strata folder, where they are: setup checks each against its
			// SHA-256 and fetches only what is missing or wrong.
			const draft = join(data, "mtp");
			if (download.from != null && !existsSync(join(draft, "tensors"))) {
				const theirs = findDraftLayer(download.from, folder);
				if (theirs !== undefined) await cloneDraftLayer(theirs, draft);
			}
			const log = prepareLog(pack.id);
			await runSetup(download, entry, STRATA_SETUP.prepare(control, names, folder, data, pack.visionFile !== null, engine.home), log, `${model.name} (${pack.pack})`);
			const written = STRATA_SETUP.config(control, names);
			let config: unknown;
			try {
				config = JSON.parse(readFileSync(written, "utf8"));
			} catch {
				throw new Error(`Strata's setup finished without writing the settings to run ${model.name} (${pack.pack}) with, so it cannot be started. What it printed is in ${tilde(log)}. Press Try Again.`);
			}
			// pi²'s own copy, which the running piece starts the server with (and adjusts at each start).
			const configs = join(root, "configs");
			mkdirSync(configs, { recursive: true });
			const copy = join(configs, `${pack.id}.json`);
			writeJson(copy, config);
			list(copy, set.control.version);
		} finally {
			release();
		}
	}

	/** Clones (or copies) the draft layer's fetched tensors and their lists from the person's folder into `dest`. */
	async function cloneDraftLayer(source: string, dest: string): Promise<void> {
		const staging = `${dest}.copying`;
		rmSync(staging, { recursive: true, force: true });
		mkdirSync(join(staging, "tensors"), { recursive: true });
		for (const name of ["mtp-inventory.json", "mtp-manifest.json"]) if (existsSync(join(source, name))) await copyFile(join(source, name), join(staging, name), constants.COPYFILE_FICLONE);
		for (const name of readdirSync(join(source, "tensors"))) {
			const from = join(source, "tensors", name);
			if (lstatSync(from).isFile()) await copyFile(from, join(staging, "tensors", name), constants.COPYFILE_FICLONE);
		}
		rmSync(dest, { recursive: true, force: true });
		renameSync(staging, dest);
		engine.log(`local models: the draft layer's tensors taken from ${source}; Strata's setup checks them`);
	}

	/**
	 * Runs one of Strata's setup commands to its end, as the engine runs what it leaves to run on its own: a process group
	 * of its own, the run's marker, its process noted for the next engine should this one die. What it prints goes to
	 * `log` and, read line by line, to the download's progress. Stopping the download stops it. Throws, in words a person
	 * can act on, when it fails.
	 */
	async function runSetup(download: StoredDownload, entry: Live, command: StrataCommand, log: string, name: string): Promise<void> {
		mkdirSync(dirname(log), { recursive: true });
		const out = openSync(log, "a");
		writeSync(out, `\n---- ${new Date().toISOString()}: ${basename(command.program)} ${command.args.map((arg) => (arg.includes(" ") ? JSON.stringify(arg) : arg)).join(" ")}\n`);
		const run = newRun();
		let child: ChildProcess;
		try {
			child = spawn(command.program, command.args, {
				cwd: command.cwd,
				env: Object.fromEntries(Object.entries(commandEnvironment({ ...command.env, [RUN_VARIABLE]: run.marker })).filter(([variable]) => !command.unset.includes(variable))),
				detached: true,
				stdio: run.stdio,
			});
		} catch (error) {
			forgetRun(run.marker);
			closeSync(out);
			throw error;
		}
		entry.child = child;
		let failure: string | undefined;
		let hint: string | undefined;
		let lastLine = "";
		const take = (line: string) => {
			writeSync(out, `${line}\n`);
			if (line.trim() !== "") lastLine = line.trim();
			if (failure !== undefined && hint === undefined && /^\s{4,}\S/.test(line) && !/^Setup stopped/.test(line.trim())) hint = line.trim();
			const said = STRATA_SETUP.read(line);
			if (said.failure !== undefined) failure = said.failure;
			if (entry.prepare !== null && (said.step !== undefined || said.stage !== undefined)) {
				if (said.stage !== undefined) entry.prepare.stage = said.stage;
				if (said.fraction !== undefined) entry.prepare.fraction = said.fraction;
				if (said.step !== undefined) {
					// A new step is said to every app at once; what happens within one, at most twice a second.
					entry.prepare.step = said.step;
					entry.prepare.fraction = null;
					announce();
				} else progress(download);
			}
		};
		for (const stream of [child.stdout, child.stderr]) {
			let partial = "";
			stream?.setEncoding("utf8").on("data", (chunk: string) => {
				const lines = (partial + chunk).split(/\r?\n|\r/);
				partial = lines.pop() ?? "";
				for (const line of lines) take(line);
			});
		}
		void noteProcess(child, run.marker)
			.then((noted) => {
				if (noted === undefined || child.exitCode !== null || child.signalCode !== null) return;
				download.process = noted;
				saveSetup();
			})
			.catch(() => {});
		const signal = entry.controller.signal;
		const stopIt = () => {
			const group = child.pid;
			if (!signallable(group) || child.exitCode !== null || child.signalCode !== null) return;
			try {
				process.kill(-group, "SIGTERM");
			} catch {}
			setTimeout(() => {
				if (child.exitCode !== null || child.signalCode !== null) return;
				try {
					process.kill(-group, "SIGKILL");
				} catch {}
			}, 3_000).unref();
		};
		signal.addEventListener("abort", stopIt, { once: true });
		const ended = await new Promise<{ code: number | null; error?: Error }>((resolve) => {
			child.once("error", (error) => resolve({ code: null, error }));
			child.once("close", (code) => resolve({ code }));
		});
		signal.removeEventListener("abort", stopIt);
		entry.child = undefined;
		closeSync(out);
		forgetRun(run.marker);
		if (download.process !== undefined) {
			delete download.process;
			saveSetup();
		}
		if (signal.aborted) throw signal.reason instanceof Error ? signal.reason : new Error(String(signal.reason));
		if (ended.code === 0) return;
		const why = ended.error !== undefined ? `Strata's setup could not be run (${ended.error.message})` : failure !== undefined ? `Strata's setup stopped: ${failure}${hint === undefined ? "" : ` ${hint}`}` : `Strata's setup stopped (exit code ${ended.code ?? "none"})${lastLine === "" ? "" : `: “${lastLine.slice(0, 200)}”`}`;
		throw new Error(`${name} could not be prepared. ${why.replace(/\.?$/, ".")} What it printed is in ${tilde(log)}. Press Try Again: what was done is kept.`);
	}

	/** Installs the engine's archive where Strata's server finds it, with Strata's own command. */
	async function installComponent(control: string, archive: string, signal: AbortSignal): Promise<void> {
		const command = STRATA_SETUP.component(control, archive, engine.home);
		const log = join(engine.home, "local", "logs", "engine-install.log");
		mkdirSync(dirname(log), { recursive: true });
		const result = await run(command.program, command.args, {
			cwd: command.cwd,
			env: Object.fromEntries(Object.entries(commandEnvironment(command.env)).filter(([variable]) => !command.unset.includes(variable))),
			signal,
			timeout: 10 * 60_000,
			maxBuffer: 16 * 1024 * 1024,
		}).then(
			({ stdout, stderr }) => ({ ok: true, text: `${stdout}${stderr}` }),
			(error: { stdout?: string; stderr?: string; message: string }) => ({ ok: false, text: `${error.stdout ?? ""}${error.stderr ?? ""}` || error.message }),
		);
		writeFileSync(log, result.text);
		if (signal.aborted) throw new Error("stopped");
		if (!result.ok) {
			const last = result.text.split("\n").map((line) => line.trim()).filter((line) => line !== "").at(-1) ?? "";
			throw new Error(`Strata could not install its engine${last === "" ? "" : `: “${last.slice(0, 200)}”`}. What it printed is in ${tilde(log)}. Press Try Again.`);
		}
	}

	/** Stops a download, and resolves once it has stopped. */
	async function halt(id: string, reason: string): Promise<void> {
		const running = live.get(id);
		if (running === undefined) return;
		running.controller.abort(reason);
		await running.done;
	}

	/**
	 * Removes what a download left: the parts, the files of a pack not yet set up with what preparing it made, and the
	 * engine's archive and unpacking. A model set up before and being prepared again keeps everything.
	 */
	function clearDownload(download: StoredDownload): void {
		const folder = folderOf(download);
		if (download.kind === "model" && installed.models.some((model) => model.id === download.target)) return;
		if (download.kind === "model") {
			rmSync(join(folder, PREPARED_FOLDER), { recursive: true, force: true });
			rmSync(join(folder, `${PREPARED_FOLDER}.copying`), { recursive: true, force: true });
		}
		for (const file of filesOf(download)) {
			rmSync(join(folder, `${file.name}.part`), { force: true });
			rmSync(join(folder, file.name), { force: true });
		}
		if (download.kind === "engine") {
			const [version, control] = download.target.split("/");
			rmSync(join(root, "engine", `.${version}.unpacking`), { recursive: true, force: true });
			rmSync(join(root, "control", `.${control}.unpacking`), { recursive: true, force: true });
		}
		removeIfEmpty(folder);
	}
	function removeIfEmpty(folder: string): void {
		try {
			if (readdirSync(folder).filter((name) => name !== ".DS_Store").length === 0) rmSync(folder, { recursive: true, force: true });
		} catch {}
	}

	function requireSupported(): void {
		if (!supported()) throw new Error("Strata runs only on Macs with Apple silicon (M1 or newer). This Mac cannot run it.");
	}
	function requireAccepted(params: Record<string, unknown>, what: string): void {
		if (params.accept !== true) throw new Error(`Read ${what}'s licence first: it is shown before the download, and the download starts once you agree to it.`);
	}
	const findDownload = (id: unknown) => {
		const download = setup.downloads.find((d) => d.id === id);
		if (download === undefined) throw new Error("There is no such download.");
		return download;
	};
	const findInstalled = (id: unknown) => {
		const model = installed.models.find((m) => m.id === id);
		if (model === undefined) throw new Error("That model is not set up on this Mac.");
		return model;
	};

	function begin(download: StoredDownload): void {
		checkSpace(download);
		download.state = "running";
		download.error = null;
		saveSetup();
		start(download);
	}

	// ---- Loading what is there

	function load(): void {
		try {
			const read = JSON.parse(readFileSync(installedFile, "utf8")) as Partial<Installed>;
			installed = { engine: read.engine ?? null, models: Array.isArray(read.models) ? read.models : [] };
		} catch {}
		try {
			const read = JSON.parse(readFileSync(setupFile, "utf8")) as Partial<Setup>;
			setup = { folder: typeof read.folder === "string" ? read.folder : null, downloads: Array.isArray(read.downloads) ? read.downloads : [] };
		} catch {}
		// What was removed by hand since is no longer offered.
		let tidied = false;
		if (installed.engine !== null && ![installed.engine.path, installed.engine.folder, installed.engine.control?.folder].every((path) => path !== undefined && existsSync(path))) {
			engine.log(`local models: the engine at ${installed.engine.path} is gone; it is no longer listed`);
			installed.engine = null;
			tidied = true;
		}
		const kept = installed.models.filter((model) => {
			const pack = findPack(model.id)?.pack;
			const whole = existsSync(model.path) && (pack === undefined || pack.files.every((file) => existsSync(join(dirname(model.path), file.name))));
			if (!whole) engine.log(`local models: files of ${model.id} are gone; it is no longer listed`);
			return whole;
		});
		if (kept.length !== installed.models.length) {
			installed.models = kept;
			tidied = true;
		}
		// A run config removed by hand: the model is prepared again once the engine is there (queueReprepare).
		for (const model of installed.models) {
			if (model.config !== undefined && !existsSync(model.config)) {
				delete model.config;
				tidied = true;
			}
		}
		if (tidied) writeJson(installedFile, installed);
		// A download of what pi² no longer offers (an engine pinned before an update, a pack withdrawn) goes, with what it left.
		const offered = (d: StoredDownload) => (d.kind === "engine" ? d.target === engineTarget() : findPack(d.target) !== undefined);
		for (const stale of setup.downloads.filter((d) => !offered(d))) {
			if (stale.kind === "engine") {
				const downloads = join(root, "downloads");
				if (existsSync(downloads)) for (const name of readdirSync(downloads)) rmSync(join(downloads, name), { force: true, recursive: true });
				removeIfEmpty(downloads);
			} else if (stale.folder !== null) rmSync(stale.folder, { recursive: true, force: true });
			engine.log(`local models: the download of ${stale.target} is no longer offered; what it left was removed`);
		}
		setup.downloads = setup.downloads.filter(offered);
	}

	return {
		start: async () => {
			load();
			// Strata's setup, left preparing a model by an engine that died: stopped, if it is provably the same, before it is run again.
			for (const download of setup.downloads) {
				if (download.process === undefined) continue;
				const found = await stopLeftOver(download.process).catch(() => "unsure" as const);
				engine.log(`local models: Strata's setup preparing ${download.target}, left by the last engine, ${leftOverLog[found]}`);
				delete download.process;
				saveSetup();
			}
			// Downloads that were running when the last engine stopped carry on.
			for (const download of setup.downloads) {
				if (download.state !== "running") continue;
				try {
					checkSpace(download);
					start(download);
				} catch (error) {
					download.state = "failed";
					download.error = (error as Error).message;
					saveSetup();
				}
			}
			// Models waiting for the engine, and those without a run config from the control package installed (after an
			// update): prepared now, if the engine is set up.
			if (installed.engine !== null && current(installed.engine)) afterEngine();
		},
		greeting: () => [{ event: "local", ...status() }],
		stopping: async () => {
			// They stay "running" in local-setup.json, so the next engine carries on with them.
			await Promise.all([...live.keys()].map((id) => halt(id, "the engine is stopping")));
		},
		handlers: {
			"local.status": async () => status(),

			/** `{ accept: true }`, once the person has seen the engine's licence: downloads the pinned engine, or carries on. */
			"local.engine.install": async (params) => {
				requireSupported();
				requireAccepted(params, "Strata");
				const version = engineTarget();
				if (installed.engine !== null && current(installed.engine)) throw new Error(`Strata ${catalog.engine.version} is already set up.`);
				let download = setup.downloads.find((d) => d.id === "engine");
				if (download !== undefined && download.target !== version) {
					await halt("engine", "replaced");
					clearDownload(download);
					setup.downloads = setup.downloads.filter((d) => d !== download);
					download = undefined;
				}
				if (download === undefined) {
					download = { id: "engine", kind: "engine", target: version, folder: null, state: "running", error: null };
					setup.downloads.push(download);
				}
				try {
					begin(download);
				} catch (error) {
					setup.downloads = setup.downloads.filter((d) => d !== download);
					saveSetup();
					throw error;
				}
				return status();
			},

			"local.engine.remove": async () => {
				const download = setup.downloads.find((d) => d.id === "engine");
				if (download !== undefined) {
					await halt("engine", "cancelled");
					clearDownload(download);
					setup.downloads = setup.downloads.filter((d) => d !== download);
					saveSetup();
				}
				if (installed.engine !== null) {
					rmSync(join(root, "engine"), { recursive: true, force: true });
					rmSync(join(root, "control"), { recursive: true, force: true });
					// And what Strata keeps of its own (its installed engine, its settings): getting it again puts it back.
					rmSync(join(root, "strata"), { recursive: true, force: true });
					installed.engine = null;
					saveInstalled();
				}
				announce();
				return status();
			},

			/**
			 * `{ pack, accept: true, from? }`: downloads a pack into the folder for models, or carries on with it. `from`, a
			 * folder of the person's, is looked in first (and up to three levels below it) for the pack's files and the draft
			 * layer Strata fetches: those whose size and SHA-256 match are taken from there instead of being downloaded.
			 */
			"local.model.install": async (params) => {
				requireSupported();
				const found = findPack(String(params.pack));
				if (found === undefined) throw new Error("pi² does not offer that pack.");
				if (found.pack.unavailable !== undefined) throw new Error(found.pack.unavailable);
				requireAccepted(params, `${found.model.name}`);
				if (installed.models.some((m) => m.id === found.pack.id)) throw new Error(`${found.model.name} (${found.pack.pack}) is already set up.`);
				let from: string | null = null;
				if (params.from !== undefined && params.from !== null) {
					from = String(params.from);
					if (!isAbsolute(from) || !existsSync(from) || !statSync(from).isDirectory()) throw new Error(`There is no folder at ${from}.`);
					const have = found.pack.files.filter((file) => findFile(from!, file) !== undefined);
					if (have.length === 0) throw new Error(`None of the files of ${found.model.name} (${found.pack.pack}) is in ${tilde(from)} or the folders in it, by name and size: ${found.pack.files.map((file) => file.name).join(", ")}. Choose the folder that holds them.`);
				}
				let download = setup.downloads.find((d) => d.id === found.pack.id);
				const fresh = download === undefined;
				if (download === undefined) {
					download = { id: found.pack.id, kind: "model", target: found.pack.id, folder: join(modelsFolder(), found.pack.id), state: "running", error: null, stage: "download", from };
					setup.downloads.push(download);
				} else if (from !== null) download.from = from;
				try {
					begin(download);
				} catch (error) {
					if (fresh) {
						setup.downloads = setup.downloads.filter((d) => d !== download);
						saveSetup();
					}
					throw error;
				}
				return status();
			},

			"local.model.remove": async (params) => {
				const model = findInstalled(params.id);
				const folder = dirname(model.path);
				const pack = findPack(model.id)?.pack;
				// Being prepared again: that stops first.
				const preparing = setup.downloads.find((d) => d.id === model.id);
				if (preparing !== undefined) {
					await halt(preparing.id, "cancelled");
					setup.downloads = setup.downloads.filter((d) => d !== preparing);
					saveSetup();
				}
				for (const name of pack?.files.map((file) => file.name) ?? [model.path.slice(folder.length + 1)]) {
					rmSync(join(folder, name), { force: true });
					rmSync(join(folder, `${name}.part`), { force: true });
				}
				rmSync(join(folder, PREPARED_FOLDER), { recursive: true, force: true });
				if (model.config !== undefined && model.config.startsWith(`${join(root, "configs")}${sep}`)) rmSync(model.config, { force: true });
				removeIfEmpty(folder);
				installed.models = installed.models.filter((m) => m !== model);
				// Strata's setup reuses a draft layer it finds in another pack's folder: a model whose run config named what was
				// just removed is prepared again.
				for (const other of installed.models) {
					if (other.config === undefined) continue;
					try {
						if (readFileSync(other.config, "utf8").includes(`${folder}${sep}`)) delete other.config;
					} catch {}
				}
				saveInstalled();
				queueReprepare();
				announce();
				return status();
			},

			/** `{ id, contextSize?, options?: { vision?, parallel? } }` */
			"local.model.configure": async (params) => {
				const model = findInstalled(params.id);
				if (params.contextSize !== undefined) {
					const size = params.contextSize;
					if (typeof size !== "number" || !CONTEXT_SIZES.includes(size)) throw new Error(`The context size must be one of ${CONTEXT_SIZES.join(", ")} tokens.`);
					model.contextSize = size;
				}
				const options = (params.options ?? {}) as Record<string, unknown>;
				if (options.vision !== undefined) {
					if (typeof options.vision !== "boolean") throw new Error("vision must be true or false");
					if (options.vision && model.options.visionFile === null) throw new Error("This pack has no picture reader.");
					model.options.vision = options.vision;
				}
				if (options.parallel !== undefined) {
					if (typeof options.parallel !== "number" || !Number.isInteger(options.parallel) || options.parallel < 1 || options.parallel > 4) throw new Error("Requests at once must be a whole number from 1 to 4.");
					model.options.parallel = options.parallel;
				}
				saveInstalled();
				announce();
				return status();
			},

			/** `{ path }` for a folder of the person's, or `{ path: null }` for pi²'s own: where packs downloaded from now on go. */
			"local.model.folder": async (params) => {
				if (params.path === null) setup.folder = null;
				else {
					const path = String(params.path);
					if (!isAbsolute(path)) throw new Error("Choose a folder.");
					if (!existsSync(path) || !statSync(path).isDirectory()) throw new Error(`There is no folder at ${path}.`);
					if (path === engine.home || path.startsWith(`${engine.home}${sep}`)) {
						if (path !== defaultFolder()) throw new Error("Choose a folder outside pi²'s data folder, or keep pi²'s own.");
					}
					setup.folder = path === defaultFolder() ? null : path;
				}
				saveSetup();
				announce();
				return status();
			},

			"local.download.pause": async (params) => {
				const download = findDownload(params.id);
				download.state = "paused";
				saveSetup();
				await halt(download.id, "paused");
				announce();
				return status();
			},

			"local.download.resume": async (params) => {
				const download = findDownload(params.id);
				if (live.has(download.id)) return status();
				begin(download);
				return status();
			},

			"local.download.cancel": async (params) => {
				const download = findDownload(params.id);
				if (download.kind === "model" && installed.models.some((model) => model.id === download.target)) {
					throw new Error("This model was set up before and is being prepared again for the Strata installed now. Pause it, or remove the model.");
				}
				await halt(download.id, "cancelled");
				clearDownload(download);
				setup.downloads = setup.downloads.filter((d) => d !== download);
				saveSetup();
				announce();
				return status();
			},

			/** `{ id }`: one short message to a model that is set up and started, through the providers. Answers `{ text }`. */
			"local.model.try": async (params) => {
				const model = findInstalled(params.id);
				const providers = engine.providers();
				const found = providers.models.getModel("local", model.id) as Model<Api> | undefined;
				if (found === undefined) throw new Error("Trying a model needs the part of pi² that runs models on this Mac, which this version does not have yet.");
				// Longer than 64 tokens on purpose: Strata compiles the kernels a longer prompt needs the first time it reads one,
				// which took a minute after the first start (#290), and this takes that out of the person's first conversation.
				const answer = await providers.models.completeSimple(found, {
					messages: [{ role: "user", content: TRY_MESSAGE, timestamp: Date.now() }],
				});
				if (answer.stopReason === "error" || answer.stopReason === "aborted") throw new Error(answer.errorMessage ?? "The model did not answer.");
				const text = answer.content.flatMap((part) => (part.type === "text" ? [part.text] : [])).join("").trim();
				return { text };
			},
		},
	};
};
