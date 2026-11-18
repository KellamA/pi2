// Models on this Mac, the downloads piece (#292 of #173): getting the Strata engine and a model pack onto the Mac,
// checked, and setting them up. Starting and stopping a model is another piece's (#291), which reads what this one
// writes to `local-models.json`:
//
//   { "engine": { "version", "path", "folder", "control": { "version", "folder" } } | null,
//     "models": [{ "id", "name", "pack", "path", "contextSize", "options": { "vision", "visionFile", "parallel" } }] }
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

import { execFile } from "node:child_process";
import { existsSync, lstatSync, mkdirSync, readdirSync, readFileSync, renameSync, rmSync, statfsSync, statSync, writeFileSync, chmodSync } from "node:fs";
import { totalmem } from "node:os";
import { dirname, isAbsolute, join, sep } from "node:path";
import { promisify } from "node:util";
import type { Api, Model } from "@earendil-works/pi-ai";
import { DownloadError, download as downloadFile } from "./download.ts";
import type { Feature } from "./features.ts";
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
export type InstalledModel = { id: string; name: string; pack: string; path: string; contextSize: number; options: ModelOptions };
export type InstalledEngine = { version: string; path: string; folder: string; control: { version: string; folder: string } };
export type Installed = { engine: InstalledEngine | null; models: InstalledModel[] };

type DownloadState = "running" | "paused" | "failed";
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
};
type Setup = { folder: string | null; downloads: StoredDownload[] };

/** What a running download is doing, in memory only. */
type Live = {
	controller: AbortController;
	done: Promise<void>;
	phase: "checking" | "downloading" | "waiting" | "unpacking";
	/** Bytes of all its files on disk. */
	received: number;
	total: number;
	/** When it is waiting to try again: why, and when it will. */
	retry: { reason: string; at: number } | null;
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
		};
	}

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
			models: installed.models.map((model) => ({ ...model, needsGB: findPack(model.id)?.pack.needsGB ?? null })),
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
	/** Whether the engine set up is the one pi² pins, control package and all. */
	const current = (set: InstalledEngine) => set.version === catalog.engine.version && set.control?.version === catalog.engine.control.version;
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
		const remaining = (d: StoredDownload) => {
			const files = filesOf(d);
			const bytes = files.reduce((sum, file) => sum + file.size, 0);
			// The engine is unpacked beside its archives, to about three times their size; Strata's setup prepares a pack beside its files.
			const total = d.kind === "engine" ? bytes * 4 : bytes + (findPack(d.target)?.pack.prepareBytes ?? 0);
			return Math.max(0, total - onDisk(files, folderOf(d)));
		};
		// Other downloads under way on the same disk need their room too.
		const device = (path: string) => {
			let probe = path;
			while (!existsSync(probe) && dirname(probe) !== probe) probe = dirname(probe);
			return statSync(probe).dev;
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

	function start(download: StoredDownload): void {
		if (live.has(download.id)) return;
		const controller = new AbortController();
		const entry: Live = { controller, done: Promise.resolve(), phase: "downloading", received: 0, total: filesOf(download).reduce((sum, file) => sum + file.size, 0), retry: null, lastSent: 0 };
		live.set(download.id, entry);
		entry.done = (async () => {
			try {
				if (download.kind === "engine") await fetchEngine(download, entry);
				else await fetchModel(download, entry);
				setup.downloads = setup.downloads.filter((d) => d !== download);
				saveSetup();
				engine.log(`local models: ${download.kind === "engine" ? `Strata ${download.target}` : download.target} is downloaded, checked and set up`);
			} catch (error) {
				if (controller.signal.aborted) return; // paused, cancelled or the engine stopping: whoever stopped it says what comes next
				download.state = "failed";
				download.error = error instanceof Error ? error.message : String(error);
				saveSetup();
				engine.log(`local models: the download of ${download.target} stopped: ${download.error}`);
			} finally {
				live.delete(download.id);
				announce();
			}
		})();
		announce();
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
		for (const file of engineFiles()) rmSync(join(folder, file.name), { force: true });
		removeIfEmpty(folder);
		const previous = installed.engine;
		installed.engine = { version: pinned.version, path: unpacked.executable!, folder: unpacked.folder, control: { version: pinned.control.version, folder: control.folder } };
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
		const { model, pack } = found;
		const folder = download.folder!;
		await makeFolder(folder);
		let before = 0;
		for (const file of pack.files) {
			const dest = join(folder, file.name);
			// A file is moved to its name only once it has matched, so one there is whole and checked.
			if (!existsSync(dest) || sizeOf(dest) !== file.size) await downloadFile(file, dest, options(download, entry, before));
			before += file.size;
			entry.received = before;
		}
		const contextSize = defaultContext();
		const entryFor: InstalledModel = {
			id: pack.id,
			name: `${model.name} (${pack.pack})`,
			pack: pack.pack,
			path: join(folder, pack.files[0]!.name),
			contextSize,
			options: { vision: pack.visionFile !== null, visionFile: pack.visionFile === null ? null : join(folder, pack.visionFile), parallel: 1 },
		};
		installed.models = [...installed.models.filter((m) => m.id !== pack.id), entryFor];
		saveInstalled();
	}

	/** Stops a download, and resolves once it has stopped. */
	async function halt(id: string, reason: string): Promise<void> {
		const running = live.get(id);
		if (running === undefined) return;
		running.controller.abort(reason);
		await running.done;
	}

	/** Removes what a download left: the parts, the files of a pack not yet set up, and the engine's archive and unpacking. */
	function clearDownload(download: StoredDownload): void {
		const folder = folderOf(download);
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
		if (tidied) writeJson(installedFile, installed);
		setup.downloads = setup.downloads.filter((d) => (d.kind === "engine" ? true : findPack(d.target) !== undefined));
	}

	return {
		start: async () => {
			load();
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
					installed.engine = null;
					saveInstalled();
				}
				announce();
				return status();
			},

			/** `{ pack, accept: true }`: downloads a pack into the folder for models, or carries on with it. */
			"local.model.install": async (params) => {
				requireSupported();
				const found = findPack(String(params.pack));
				if (found === undefined) throw new Error("pi² does not offer that pack.");
				if (found.pack.unavailable !== undefined) throw new Error(found.pack.unavailable);
				requireAccepted(params, `${found.model.name}`);
				if (installed.models.some((m) => m.id === found.pack.id)) throw new Error(`${found.model.name} (${found.pack.pack}) is already set up.`);
				let download = setup.downloads.find((d) => d.id === found.pack.id);
				const fresh = download === undefined;
				if (download === undefined) {
					download = { id: found.pack.id, kind: "model", target: found.pack.id, folder: join(modelsFolder(), found.pack.id), state: "running", error: null };
					setup.downloads.push(download);
				}
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
				for (const name of pack?.files.map((file) => file.name) ?? [model.path.slice(folder.length + 1)]) {
					rmSync(join(folder, name), { force: true });
					rmSync(join(folder, `${name}.part`), { force: true });
				}
				removeIfEmpty(folder);
				installed.models = installed.models.filter((m) => m !== model);
				saveInstalled();
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
				const answer = await providers.models.completeSimple(found, {
					messages: [{ role: "user", content: "Say hello in one short sentence.", timestamp: Date.now() }],
				});
				if (answer.stopReason === "error" || answer.stopReason === "aborted") throw new Error(answer.errorMessage ?? "The model did not answer.");
				const text = answer.content.flatMap((part) => (part.type === "text" ? [part.text] : [])).join("").trim();
				return { text };
			},
		},
	};
};
