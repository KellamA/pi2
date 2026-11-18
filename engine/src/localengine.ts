// How to start the engine that runs models on this Mac, and how to tell that it is ready (#173, #291).
//
// Everything pi² assumes about the real engine (Strata) is here and nowhere else: its command line, where its
// OpenAI-compatible API is, how it says it has loaded the model, and how it reports progress. The rest of running a model
// (localrun.ts: when to start and stop it, its process, sharing it) goes by this description only, and is tested with a
// stand-in that takes the same command line (engine/test/localserver.ts). What has not been checked against the real
// engine is marked so: #293 corrects it here, and the stand-in with it.

import { mkdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
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
	/** Why `model` cannot be started with `engine` as they are set up, in words for the person; undefined when it can. */
	missing?(engine: LocalEngine, model: LocalModel): string | undefined;
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

/** A command to run: the program, its arguments, the folder it runs in, and what it needs in its environment. */
export type StrataCommand = { program: string; args: string[]; cwd: string; env: Record<string, string>; unset: string[] };

/** How Strata's setup names a pack, and the run config it writes for it (localcatalog.ts). */
export type PrepareNames = { family: string; model: string; config: string };

/** What one line Strata's setup printed says: the step it began, what it is doing, how far, or why it stopped. */
export type SetupLine = { step?: number; stage?: string; fraction?: number; failure?: string; hint?: string };

const python = (control: string) => join(control, "python", "bin", "python3");

/**
 * Strata's own setup, from its control package: it installs the engine where Strata's server finds it, and prepares a
 * downloaded pack once, as #290 ran it by hand and #293 runs it from pi². Neither asks anything (`--yes`), starts a
 * model or opens a browser. Preparing writes a pack folder and the draft layer into `data`, fetching the draft layer's
 * 5.2 GB from Qwen's original model unless they are there already, and a run config into the control package's folder.
 */
export const STRATA_SETUP = {
	/** The seven steps of setup on a Mac (there is no step 3 there): how far it has got is the step it is at. */
	steps: 7,
	/** Installs the engine's archive, already checked by pi², into Strata's component folder: it checks its signature and files again, without the network. */
	component: (control: string, archive: string, home: string): StrataCommand => ({
		program: python(control),
		args: [join(control, "strata.py"), "components", "install-file", archive],
		cwd: control,
		env: strataEnvironment(home),
		unset: STRATA_UNSET,
	}),
	/**
	 * Prepares the pack whose files are in `files` (the person's own files, as Strata calls them: it takes them as they are,
	 * so pi² checks them first), putting what it makes in `data`. Always with the picture reader where the pack has one, so
	 * that turning pictures on later needs no preparing again; the context size is pi²'s to set at each start.
	 */
	prepare: (control: string, names: PrepareNames, files: string, data: string, vision: boolean, home: string): StrataCommand => ({
		program: python(control),
		args: [join(control, "setup.py"), "--family", names.family, "--model", names.model, "--gguf-dir", files, "--data-dir", data, "--vision", vision ? "gpu" : "no", "--no-start", "--no-browser", "--yes"],
		cwd: control,
		env: { ...strataEnvironment(home), STRATA_CONTROL_INSTALL: "1" },
		unset: STRATA_UNSET,
	}),
	/** Where setup writes the run config: in the control package's own folder, which it takes for its home in this mode. */
	config: (control: string, names: PrepareNames) => join(control, names.config),
	/** One line it printed: "=== Step 6: preparing the model for Strata ===", "  MTP draft layer:   0.87 / 5.21 GB (16%)", "  [X]  …". */
	read: (line: string): SetupLine => {
		const step = /^=== Step (\d+): (.*?) ===$/.exec(line.trim());
		if (step !== null) return { step: Number(step[1]), stage: step[2] };
		const amount = /^\s*([A-Za-z][^:]*?):\s+([\d.]+) \/ ([\d.]+) GB \((\d+)%\)/.exec(line);
		if (amount !== null) return { stage: `fetching the ${amount[1].replace(/^MTP /, "")} (${amount[2]} of ${amount[3]} GB)`, fraction: Math.min(1, Number(amount[4]) / 100) };
		const failed = /^\s*\[X\]\s+(.*\S)/.exec(line);
		if (failed !== null) return { failure: failed[1] };
		return {};
	},
};

/** A file name from a model id: ids may hold "/", ":" and the like. */
export const fileName = (id: string) => id.replace(/[^A-Za-z0-9._-]+/g, "-").replace(/^[.-]+/, "") || "model";

/**
 * The run config a model is started with: the one Strata's setup wrote when it prepared the model (pi²'s copy of it,
 * `config`), with the model's settings as they are now, so that a change in Settings counts at the next start without
 * preparing it again. The context size is `--max-context` among the engine's arguments; pictures are `--vision` there
 * and the `vision` section, both left out when they are off; the engine's own log goes to pi²'s folder of logs. Written
 * to `local/run/<model>.json` in the data folder, readable by the person only.
 */
export function runConfig(model: LocalModel, home: string): string {
	const written = JSON.parse(readFileSync(model.config!, "utf8")) as { args?: unknown; vision?: unknown; [key: string]: unknown };
	const args = Array.isArray(written.args) ? written.args.map(String) : [];
	const at = args.indexOf("--max-context");
	if (at === -1) args.push("--max-context", String(model.contextSize));
	else args[at + 1] = String(model.contextSize);
	const vision = model.options.vision === true && written.vision !== undefined;
	const config: Record<string, unknown> = { ...written, args: vision || !args.includes("--vision") ? args : args.filter((arg) => arg !== "--vision") };
	if (!vision) delete config.vision;
	config.args_written = config.args;
	config.log = join(home, "local", "logs", `${fileName(model.id)}.engine.log`);
	const folder = join(home, "local", "run");
	mkdirSync(folder, { recursive: true });
	const path = join(folder, `${fileName(model.id)}.json`);
	writeFileSync(path, `${JSON.stringify(config, null, 1)}\n`, { mode: 0o600 });
	return path;
}

/**
 * Strata (https://github.com/Niko1221/Strata), as #290 found it and #293 ran it through pi²: its HTTP server is the
 * control package's Python `serve/server.py`, which starts the `strata` engine itself (from Strata's component folder,
 * where the downloads piece installs it), with the run config Strata's setup wrote when it prepared the model. It does
 * not listen until the model is loaded, so `/v1/models` answering is being ready; it reads its key from
 * `STRATA_API_KEY`; it says what it is doing while it loads in lines of its own, with no percentage.
 */
export const STRATA: EngineRecipe = {
	name: "Strata",
	missing: (engine, model) => {
		if (engine.control === undefined) return "The Strata engine set up on this Mac is from an earlier pi² and has no server. Update it in Settings › Providers › On this Mac.";
		if (model.config === undefined) return `${model.name} is not prepared for Strata yet: Settings › Providers › On this Mac shows how far it has got. It can be used once it is ready.`;
		return undefined;
	},
	command: (engine, model, port, home) => {
		const control = engine.control!.folder;
		const parallel = typeof model.options.parallel === "number" && Number.isInteger(model.options.parallel) && model.options.parallel > 0 ? model.options.parallel : 1;
		return {
			program: join(control, "python", "bin", "python3"),
			args: [
				join(control, "serve", "server.py"),
				"--engine",
				"strata",
				"--config",
				runConfig(model, home),
				"--host",
				"127.0.0.1",
				"--port",
				String(port),
				"--parallel",
				String(parallel),
				// Answers still being written when it is asked to stop are cut off after this long, inside the five seconds
				// pi² gives it before SIGKILL.
				"--shutdown-timeout",
				"2",
			],
			env: strataEnvironment(home),
			unset: STRATA_UNSET,
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
