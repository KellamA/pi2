// How to start the engine that runs models on this Mac, and how to tell that it is ready (#173, #291).
//
// Everything pi² assumes about the real engine (Strata) is here and nowhere else: its command line, where its
// OpenAI-compatible API is, how it says it has loaded the model, and how it reports progress. The rest of running a model
// (localrun.ts: when to start and stop it, its process, sharing it) goes by this description only, and is tested with a
// stand-in that takes the same command line (engine/test/localserver.ts). What has not been checked against the real
// engine is marked so: #293 corrects it here, and the stand-in with it.

import { readFileSync, statSync } from "node:fs";
import { join } from "node:path";

/** A model set up on this Mac, as `local-models.json` lists it (the downloads piece writes it; see docs/local-models.md). */
export type LocalModel = {
	id: string;
	name: string;
	pack: string;
	/** The model's file: the first of its pack's files, the others beside it. */
	path: string;
	contextSize: number;
	/** Settings of the engine for this model. Keys pi² does not know are kept and ignored. */
	options: { vision?: boolean; visionFile?: string | null; parallel?: number; tools?: boolean; [key: string]: unknown };
};

/** What is on disk: the engine, if there is one, and the models set up for it. */
export type LocalSetup = { engine: { version: string; path: string } | null; models: LocalModel[] };

const EMPTY: LocalSetup = { engine: null, models: [] };

/** One model entry as written, or undefined when it lacks what running it needs. */
function readModel(raw: unknown): LocalModel | undefined {
	if (raw === null || typeof raw !== "object") return undefined;
	const entry = raw as Record<string, unknown>;
	if (typeof entry.id !== "string" || entry.id.trim() === "" || typeof entry.path !== "string") return undefined;
	const contextSize = typeof entry.contextSize === "number" && Number.isInteger(entry.contextSize) && entry.contextSize > 0 ? entry.contextSize : 32_768;
	const options = entry.options !== null && typeof entry.options === "object" ? (entry.options as LocalModel["options"]) : {};
	return {
		id: entry.id,
		name: typeof entry.name === "string" && entry.name.trim() !== "" ? entry.name : entry.id,
		pack: typeof entry.pack === "string" ? entry.pack : "",
		path: entry.path,
		contextSize,
		options,
	};
}

/**
 * `local-models.json` in the data folder, read again only when it has changed. A file that is missing or cannot be read
 * is no engine and no models: nothing is set up.
 */
export function localSetupReader(home: string): () => LocalSetup {
	const path = join(home, "local-models.json");
	let seen = "";
	let setup = EMPTY;
	return () => {
		let stamp: string;
		try {
			const stat = statSync(path);
			stamp = `${stat.mtimeMs}:${stat.size}:${stat.ino}`;
		} catch {
			seen = "";
			setup = EMPTY;
			return setup;
		}
		if (stamp === seen) return setup;
		seen = stamp;
		try {
			const raw = JSON.parse(readFileSync(path, "utf8")) as { engine?: unknown; models?: unknown };
			const engine = raw.engine as { version?: unknown; path?: unknown } | null | undefined;
			setup = {
				engine: engine !== null && typeof engine === "object" && typeof engine.path === "string" ? { version: String(engine.version ?? ""), path: engine.path } : null,
				models: (Array.isArray(raw.models) ? raw.models : []).map(readModel).filter((model): model is LocalModel => model !== undefined),
			};
		} catch {
			setup = EMPTY;
		}
		return setup;
	};
}

/** How to start one engine, serving one model, and how to know it is ready. */
export type EngineRecipe = {
	/** The engine's name, as the person reads it. */
	name: string;
	/**
	 * The program and its arguments that serve `model` on 127.0.0.1 at `port`, and only there. Nothing secret goes in the
	 * arguments, which every process on the Mac can read: the key goes in `keyVariable`.
	 */
	command(engine: { path: string; version: string }, model: LocalModel, port: number): { program: string; args: string[] };
	/** The environment variable the engine reads the key every request must carry from; null when it takes none. */
	keyVariable: string | null;
	/** Where the OpenAI-compatible API is, under `http://127.0.0.1:<port>`: the base its `/chat/completions` is under. */
	apiPath: string;
	/** A path that answers 200 once the model is loaded and can be asked, and anything else (or nothing) before that. */
	readyPath: string;
	/** How far loading has got, from 0 to 1, from one line the engine printed; undefined when the line does not say. */
	progress(line: string): number | undefined;
};

/**
 * Strata (https://github.com/Niko1221/Strata), as far as its documentation tells. Not yet checked against the version
 * the downloads piece pins, nor run by pi²: #290 tries it and #293 corrects what is wrong here. To check:
 * - the server's flags (`--model`, `--host`, `--port`, `--context`, `--parallel` and the picture reader's file);
 * - that it reads a key from the environment, and under which name (its setup takes `--api-key`, which would put it
 *   where every process can read it: rather none than that);
 * - that `/v1/models` answers 200 only once the model is loaded;
 * - what it prints while loading, and whether that says how far it has got.
 */
export const STRATA: EngineRecipe = {
	name: "Strata",
	command: (engine, model, port) => {
		const options = model.options;
		const vision = options.vision === true && typeof options.visionFile === "string" && options.visionFile !== "";
		const parallel = typeof options.parallel === "number" && Number.isInteger(options.parallel) && options.parallel > 0 ? options.parallel : 1;
		return {
			program: engine.path,
			args: [
				"--model",
				model.path,
				"--host",
				"127.0.0.1",
				"--port",
				String(port),
				"--context",
				String(model.contextSize),
				"--parallel",
				String(parallel),
				...(vision ? ["--vision-file", options.visionFile as string] : ["--vision", "no"]),
			],
		};
	},
	keyVariable: "STRATA_API_KEY",
	apiPath: "/v1",
	readyPath: "/v1/models",
	progress: (line) => {
		// "loading … 42%", "42.5 %": the last percentage on a line that speaks of loading.
		if (!/load/i.test(line)) return undefined;
		const found = [...line.matchAll(/(\d{1,3}(?:\.\d+)?)\s*%/g)].at(-1);
		if (found === undefined) return undefined;
		const value = Number(found[1]) / 100;
		return value >= 0 && value <= 1 ? value : undefined;
	},
};
