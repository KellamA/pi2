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
	/** Strata's run config for the model, which its installer writes once the model is prepared (#290); absent until then. */
	config?: string;
	/** Settings of the engine for this model. Keys pi² does not know are kept and ignored. */
	options: { vision?: boolean; visionFile?: string | null; parallel?: number; reasoning?: boolean; [key: string]: unknown };
};

/**
 * The engine as installed: `path` its executable, `folder` its whole package, and `control` Strata's control package,
 * whose server starts the executable (#290). The last two are absent from what an earlier downloads piece wrote.
 */
export type LocalEngine = { version: string; path: string; folder?: string; control?: { version: string; folder: string } };

/** What is on disk: the engine, if there is one, and the models set up for it. */
export type LocalSetup = { engine: LocalEngine | null; models: LocalModel[] };

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
		...(typeof entry.config === "string" && entry.config !== "" ? { config: entry.config } : {}),
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
			const engine = raw.engine as { version?: unknown; path?: unknown; folder?: unknown; control?: { version?: unknown; folder?: unknown } | null } | null | undefined;
			const control = engine?.control;
			setup = {
				engine:
					engine !== null && typeof engine === "object" && typeof engine.path === "string"
						? {
								version: String(engine.version ?? ""),
								path: engine.path,
								...(typeof engine.folder === "string" ? { folder: engine.folder } : {}),
								...(control !== null && typeof control === "object" && typeof control.folder === "string" ? { control: { version: String(control.version ?? ""), folder: control.folder } } : {}),
							}
						: null,
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
	 * The program, its arguments and what it needs in its environment, to serve `model` on 127.0.0.1 at `port`, and only
	 * there. `home` is pi²'s data folder. Nothing secret goes in the arguments, which every process on the Mac can read:
	 * the key goes in `keyVariable`.
	 */
	command(engine: LocalEngine, model: LocalModel, port: number, home: string): { program: string; args: string[]; env?: Record<string, string>; unset?: string[] };
	/** The environment variable the engine reads the key every request must carry from; null when it takes none. */
	keyVariable: string | null;
	/** Where the OpenAI-compatible API is, under `http://127.0.0.1:<port>`: the base its `/chat/completions` is under. */
	apiPath: string;
	/** A path that answers 200 once the model is loaded and can be asked, and anything else (or nothing) before that. */
	readyPath: string;
	/** How far loading has got, from 0 to 1, from one line the engine printed; undefined when the line does not say. */
	progress(line: string): number | undefined;
	/** What the engine is doing while it loads, in its own words, from one line it printed; undefined when the line does not say. */
	stage?(line: string): string | undefined;
};

/**
 * Where Strata keeps what it installs and finds (its engine component, its own settings), for every Strata command pi²
 * runs, so that nothing goes to the person's own `~/.local` or `~/.strata` (#290). The downloads piece installs the engine
 * component with the same ones.
 */
export function strataEnvironment(home: string): Record<string, string> {
	const root = join(home, "local", "strata");
	// And no Python of the person's own, as Strata's launcher does: with STRATA_UNSET left out of the environment.
	return { HOME: join(root, "home"), XDG_DATA_HOME: join(root, "data"), STRATA_HOME: join(root, "strata"), PYTHONNOUSERSITE: "1" };
}
/** Left out of the environment of every Strata command, as Strata's own launcher does (docs/strata.md). */
export const STRATA_UNSET = ["PYTHONHOME", "PYTHONPATH"];

/**
 * Strata (https://github.com/Niko1221/Strata), as far as #290 found and its documentation tells; not yet run by pi².
 * #293 corrects what is wrong here. Its HTTP server is the control package's Python `serve/server.py`, which starts the
 * `strata` executable itself, with the run config Strata's installer writes for a prepared model (`config`). A model
 * without one, or an engine without its control package, is started with the executable's own flags, as the stand-in
 * the tests use is. To check:
 * - the executable's own flags, for a model with no run config (the server's, `--engine`, `--config`, `--host` and
 *   `--port`, and the key in `STRATA_API_KEY`, are as #290 ran it);
 * - whether the executable alone reads the key from the environment as the server does;
 * - that `/v1/models` answers 200 once the model is loaded (#290: the server does not listen at all until then).
 */
export const STRATA: EngineRecipe = {
	name: "Strata",
	command: (engine, model, port, home) => {
		if (engine.control !== undefined && model.config !== undefined) {
			return {
				program: join(engine.control.folder, "python", "bin", "python3"),
				args: [join(engine.control.folder, "serve", "server.py"), "--engine", "strata", "--config", model.config, "--host", "127.0.0.1", "--port", String(port)],
				env: strataEnvironment(home),
				unset: STRATA_UNSET,
			};
		}
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
	// Read from there, as #290 saw.
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
	// It says what it is doing in lines of its own while it loads, with no percentage (#290): "[strata] mapping the experts …".
	stage: (line) => {
		const said = /^\[strata\]\s+(.*\S)/.exec(line.trim())?.[1]?.replace(/\s*(\.\.\.|…)$/, "");
		if (said === undefined || said === "" || /^ready\b/i.test(said)) return undefined;
		return said.length > 120 ? `${said.slice(0, 119)}…` : said;
	},
};
