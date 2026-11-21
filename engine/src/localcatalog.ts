// What pi² can download to run models on this Mac (#173, #292): the pinned engine and the model packs, with the figures
// Settings shows. This file is data, and the one place to change it: raising the engine's version, correcting a pack's
// memory figure or adding a pack is an edit here, reviewed like any other change.
//
// Every file has its size and SHA-256 written here in advance. pi² never takes a checksum from beside a download (a
// SHA256SUMS file, a release's digest, a server's header): a file that does not match what is written here is deleted
// and nothing from it is run. So a newer engine reaches the person only with a pi² update that pins it.
//
// Sources, read on 2026-11-17, and confirmed by #290, which downloaded and ran them on a Mac (see #173):
// - The engine: Strata's release v0.2.17 on GitHub, asset strata-engine-0.1.63-macos-arm64-metal.tar.gz (the Metal
//   engine alone, without the desktop app), size and SHA-256 as the release's SHA256SUMS.txt and its signed
//   strata-feed.json list them (read on 2026-11-20, #605). 0.1.62 is the first whose watchdog does not end a Mac's
//   engine for two answers written side by side for a minute; 0.1.60, pinned before, did (#605).
// - The control package (the server): the same release, asset strata-control-0.1.63-macos-arm64.tar.gz.
// - The packs: Hugging Face's listing of each repository's files (size, and the SHA-256 of each large file) at the commit
//   Strata 0.2.15's setup pins (its HF_REVISIONS), read again on 2026-11-18 (#342); 0.2.17's setup pins the same commits
//   and checksums. Downloads ask for that commit, not `main`: a repository that replaces a file on `main` would otherwise
//   fail every download until pi² was updated, as Unsloth's had by then.
// - Memory: Strata's docs/MAC.md, "What you need" (the M5 Max with 128 GB they were measured on), checked against what
//   IQ3_S held when pi² ran it (#293).

/** A file to download, checked against `sha256` (lower-case hex) before it is used. */
export type CatalogFile = { url: string; name: string; size: number; sha256: string };

export type Licence = {
	/** Its name, as the person reads it. */
	name: string;
	/** Where the whole text is. */
	url: string;
	/** What it means for the person, in a sentence or two. Not a substitute for the text. */
	summary: string;
	/** A part of it the person must read before agreeing, quoted in full where they agree: its own words, unchanged. */
	quote?: string;
};

export type CatalogEngine = {
	version: string;
	/** A .tar.gz holding the engine package: `strata`, `strata-vision`, the Metal kernels it compiles as it starts. */
	archive: CatalogFile;
	/** The engine's executable, by its name: the shallowest regular file of that name in the archive. */
	executable: string;
	/**
	 * Strata's control package: the OpenAI- and Anthropic-compatible server (Python, with a Python of its own) that starts
	 * the engine, and Strata's setup, which prepares a model. The engine has no HTTP server of its own (#290).
	 */
	control: { version: string; archive: CatalogFile };
	licences: Licence[];
};

export type CatalogPack = {
	/** The model's id in pi² (`local/<id>` in the model selector) and the name of its folder. */
	id: string;
	/** The quantisation, as Strata and the provider name it. */
	pack: string;
	provider: string;
	/** What is lost, in plain words, against the other packs. */
	note: string;
	/** Memory the model needs while it runs, in GB, prompt buffers and a default context included (MAC.md). */
	needsGB: number;
	/** The Mac's memory from which Strata recommends it (MAC.md). */
	recommendedFromGB: number;
	/** In order: the first is the model file (its other parts must be beside it), then the rest. */
	files: CatalogFile[];
	/** The picture reader, among `files`, by name; null when the pack has none. */
	visionFile: string | null;
	/**
	 * Disk space Strata's setup takes when it prepares the model after the download, in bytes: the draft layer it
	 * fetches itself (5.2 GB for the ISTA-DASLab packs, #290) and the pack folder. Counted in the disk check.
	 */
	prepareBytes: number;
	/**
	 * How Strata's setup names the model, to prepare it (`setup.py --family <family> --model <model>`), and the run
	 * config it writes for it in the control package's folder. Null for a pack pi² cannot prepare.
	 */
	prepare: { family: string; model: string; config: string } | null;
	licences: Licence[];
	/** Why it cannot be installed yet, when it cannot. */
	unavailable?: string;
};

export type CatalogModel = { id: string; name: string; packs: CatalogPack[] };

export type Catalog = {
	engine: CatalogEngine;
	models: CatalogModel[];
	/** Which packs to recommend, best first: the first that fits this Mac's memory. */
	preference: string[];
};

const GITHUB = "https://github.com/Niko1221/Strata";
const ISTA = "https://huggingface.co/ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF";
const UNSLOTH = "https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF";
/** The commits Strata 0.2.15's setup pins (setup.py, HF_REVISIONS), whose files the checksums below are of (#342). */
const ISTA_FILES = `${ISTA}/resolve/ed59f92082b1e93c0e96d60a8b11aab089b52f09`;
const UNSLOTH_FILES = `${UNSLOTH}/resolve/38bb39ee97821de2c9009abb7e93950eec396e66`;

const QWEN_LICENCE: Licence = {
	name: "Qwen Community License 1.0",
	url: "https://huggingface.co/Qwen/Qwen3.8-Flash-Next/blob/main/LICENSE",
	summary:
		"The model's own licence, from Qwen. Free to use, copy, change and run, with no warranty. Its second clause, quoted below, asks a business that offers models as a service, or an AI coding or office assistant, to get a separate licence from Qwen for commercial use.",
	// Clause 2 and its two definitions, word for word from the licence's text on Hugging Face (read on 2026-11-18).
	quote: [
		"2. If the licensee or any of its affiliates conducts a Model as a Service or AI Work Assistant business, the licensee shall obtain a separate license from Qwen before Using the Software or its derivative works for any commercial purpose. The foregoing requirement shall not apply to the licensee's internal Use of the Software, provided that such Use does not make the Software, its outputs, or its underlying model capabilities available to any third party.",
		"\"Model as a Service\" means giving a third party access to language model inference or fine-tuning (e.g., via API or a hosted endpoint) in a manner that allows such third parties to exercise meaningful control over the inputs, parameters, or training data. This does not include the mere relaying of requests to models hosted by other third parties.",
		"\u201cAI Work Assistant\u201d means an independent AI-powered product primarily designed for AI-assisted coding or office productivity (e.g., Qoder and QwenWork). It does not include: (a) a single-purpose AI tool (such as an AI translation tool); (b) an AI assistant primarily designed for a domain other than coding or office productivity (such as Taobao AI Shopping Assistant or AMap AI Chat); or (c) an AI assistant that is a feature of a product whose primary purpose is not AI-assisted coding or office productivity.",
	].join("\n\n"),
};

const istaFile = (pack: string, part: number, size: number, sha256: string): CatalogFile => {
	const name = `Qwen3.8-Flash-Next-GSQ-RCO-${pack}-0000${part}-of-00002.gguf`;
	return { url: `${ISTA_FILES}/${pack}/${name}`, name, size, sha256 };
};
/** The second part of every ISTA-DASLab pack: the n-gram table, read from the SSD a few rows at a time. The same file in each. */
const istaTable = (pack: string) => istaFile(pack, 2, 28_800_138_432, "316b46f3a2dbd68c900f43136ab9449f9dcc3725dfd8c794847c204bc161e113");
const istaVision: CatalogFile = {
	url: `${ISTA_FILES}/mmproj-Qwen3.8-Flash-Next-BF16.gguf`,
	name: "mmproj-Qwen3.8-Flash-Next-BF16.gguf",
	size: 907_543_008,
	sha256: "b1a82259702816a5330d7bd7607cd9676b11780e79ff7348c21103ff3ce49bd0",
};
/**
 * What Strata's setup adds when it prepares an ISTA-DASLab pack: the draft layer's tensors it fetches from Qwen's original
 * model (5.2 GB, kept so that preparing again after an update does not fetch them again), the draft layer packed from
 * them (0.9 GB) and the pack folder (1.5 GB). Measured on IQ3_S (#293): 7.65 GB.
 */
const PREPARED = 7.7e9;
/** Strata's setup's names for an ISTA-DASLab pack, and the run config it writes for it. */
const istaPrepare = (model: string) => ({ family: "qwen", model, config: `strata-${model.toLowerCase()}.json` });
const istaLicences: Licence[] = [
	QWEN_LICENCE,
	{ name: "Apache License 2.0", url: `${ISTA}/blob/main/README.md`, summary: "ISTA-DASLab's quantised files of the model. Free to use, copy and change, with no warranty." },
];

export const CATALOG: Catalog = {
	engine: {
		version: "0.1.63",
		archive: {
			url: `${GITHUB}/releases/download/v0.2.17/strata-engine-0.1.63-macos-arm64-metal.tar.gz`,
			name: "strata-engine-0.1.63-macos-arm64-metal.tar.gz",
			size: 2_696_028,
			sha256: "92a3e6440da49e98d0493b59418c501fd9744ade1bee3ac192abf4e3b7a9c2fd",
		},
		executable: "strata",
		control: {
			version: "0.1.63",
			archive: {
				url: `${GITHUB}/releases/download/v0.2.17/strata-control-0.1.63-macos-arm64.tar.gz`,
				name: "strata-control-0.1.63-macos-arm64.tar.gz",
				size: 45_613_317,
				sha256: "f7ca382b30010772135f6f9ebfdd9cf4fd5046a5f3ba6bb8476cdc6264ebac4a",
			},
		},
		licences: [{ name: "MIT License", url: `${GITHUB}/blob/main/LICENSE`, summary: "Strata is free to use, copy and change, with no warranty." }],
	},
	models: [
		{
			id: "qwen3.8-flash-next",
			name: "Qwen3.8-Flash-Next",
			packs: [
				{
					id: "qwen3.8-flash-next-iq3-s",
					pack: "IQ3_S",
					provider: "ISTA-DASLab",
					note: "The most accurate of ISTA-DASLab's sizes: it matches the full model on the published tests. The slowest of the three, and it needs the most memory.",
					needsGB: 63,
					recommendedFromGB: 96,
					files: [istaFile("IQ3_S", 1, 54_817_524_224, "4c1eb2ceb4915e1192f4f386021897bde56a97f40a0bb78bb86465e0f7d2aca3"), istaTable("IQ3_S"), istaVision],
					visionFile: istaVision.name,
					prepareBytes: PREPARED,
					prepare: istaPrepare("IQ3_S"),
					licences: istaLicences,
				},
				{
					id: "qwen3.8-flash-next-iq3-xxs",
					pack: "IQ3_XXS",
					provider: "ISTA-DASLab",
					note: "Close to IQ3_S, a little less accurate, and somewhat faster: for a Mac where IQ3_S does not fit.",
					needsGB: 55,
					recommendedFromGB: 74,
					files: [istaFile("IQ3_XXS", 1, 47_039_860_096, "219ea929900dfa9ef091f3aa473fdba6874b65fcb36526d7d851ac9e95856d15"), istaTable("IQ3_XXS"), istaVision],
					visionFile: istaVision.name,
					prepareBytes: PREPARED,
					prepare: istaPrepare("IQ3_XXS"),
					licences: istaLicences,
				},
				{
					id: "qwen3.8-flash-next-q2-0",
					pack: "Q2_0",
					provider: "ISTA-DASLab",
					note: "The smallest and fastest. Its answers are less accurate than IQ3_S's, most of all on hard reasoning.",
					needsGB: 46,
					recommendedFromGB: 64,
					files: [istaFile("Q2_0", 1, 37_623_740_192, "69820c02ec7d0b45ef2ebb19d6620299db749fe2aded7f39f93c6b88b199b720"), istaTable("Q2_0"), istaVision],
					visionFile: istaVision.name,
					prepareBytes: PREPARED,
					prepare: istaPrepare("Q2_0"),
					licences: istaLicences,
				},
				{
					id: "qwen3.8-flash-next-ud-q4-k-xl",
					pack: "UD-Q4_K_XL",
					provider: "Unsloth",
					note: "Closer to the full model than IQ3_S, and slower. Needs a Mac with 128 GB.",
					needsGB: 91,
					recommendedFromGB: 128,
					// At the commit Strata pins, which are not the files on `main` today: Unsloth has since re-sharded them.
					files: [
						{ url: `${UNSLOTH_FILES}/UD-Q4_K_XL/Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf`, name: "Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf", size: 10_946_624, sha256: "4448186216b3af4cc558bbce2c3213f01608f8f8b2e5267a9767971dd3ec8082" },
						{ url: `${UNSLOTH_FILES}/UD-Q4_K_XL/Qwen3.8-Flash-Next-UD-Q4_K_XL-00002-of-00004.gguf`, name: "Qwen3.8-Flash-Next-UD-Q4_K_XL-00002-of-00004.gguf", size: 49_859_583_136, sha256: "3f342f1c1580473f1ee94ddd5b28206e8c07a70fa1a366f59d1d6c922919a6c9" },
						{ url: `${UNSLOTH_FILES}/UD-Q4_K_XL/Qwen3.8-Flash-Next-UD-Q4_K_XL-00003-of-00004.gguf`, name: "Qwen3.8-Flash-Next-UD-Q4_K_XL-00003-of-00004.gguf", size: 49_376_141_504, sha256: "56758f40269cad5cd9b0d3d6fbae0f40f6d5be6de49e4ab392dbe83157d9cbd3" },
						{ url: `${UNSLOTH_FILES}/UD-Q4_K_XL/Qwen3.8-Flash-Next-UD-Q4_K_XL-00004-of-00004.gguf`, name: "Qwen3.8-Flash-Next-UD-Q4_K_XL-00004-of-00004.gguf", size: 12_087_983_520, sha256: "753bda48b98ba4f1636134a90a967de1b2d3908a236c026e464777342e53510a" },
						{ url: `${UNSLOTH_FILES}/mmproj-BF16.gguf`, name: "mmproj-BF16.gguf", size: 907_542_944, sha256: "2e788f8c511d8093c7b43cb87b2fd7e14228340318057f8fb20c86df2efe2355" },
					],
					visionFile: "mmproj-BF16.gguf",
					// Repacked into one file of about the model's size, beside the shards (MAC.md).
					prepareBytes: 83e9,
					prepare: null,
					licences: [QWEN_LICENCE],
					unavailable: "Unsloth's files have to be repacked into one file for the Mac engine first, which pi² cannot do yet.",
				},
			],
		},
	],
	preference: ["qwen3.8-flash-next-iq3-s", "qwen3.8-flash-next-iq3-xxs", "qwen3.8-flash-next-q2-0"],
};

/** Memory the engine's key-value cache takes for each token of context, for each request run at once (MAC.md: 0.65 GB at 36,864 tokens). */
export const KV_BYTES_PER_TOKEN = 0.65e9 / 36_864;

/**
 * What each request run at once takes as well, for each token of context, once there is more than one: Strata then keeps
 * a session of its own for each (#605, IQ3_S at 131,072 tokens: `--batch 4: 4 slot sessions (3.34 GiB each)`, and the
 * engine's footprint 37 GB at four against 23 GB at one).
 */
export const SLOT_BYTES_PER_TOKEN = (3.34 * 2 ** 30) / 131_072;

/**
 * Requests at once for a model newly set up (#605). With Strata 0.1.63 on the M5 Max, four agents at once got as much
 * done together as one at a time (the Mac's engine runs the requests one after another, without its draft layer, so the
 * total does not grow), and each waited for its turn a third as long; up to ten minutes of answers written side by side
 * never stopped the engine.
 */
export const REQUESTS_AT_ONCE = 4;
/** The most Settings offers. */
export const MOST_REQUESTS_AT_ONCE = 4;

/** The context sizes offered. Strata measured up to 32K on a Mac, and the model takes up to 262K. */
export const CONTEXT_SIZES = [16_384, 32_768, 65_536, 131_072, 262_144];

/** Above this, Strata has not measured how the model does on a Mac (its setup's TESTED_CONTEXT: needles found at 8K to 32K). */
export const CONTEXT_MEASURED = 32_768;

/**
 * The share of the Mac's memory Metal lets one program keep resident: MAC.md's 107.5 GB of 128 GB, which are GiB, and
 * Metal's own `recommendedMaxWorkingSetSize` on the M5 Max with 128 GB, 115.4 GB of 137.4 GB (#293). Not three quarters.
 */
export const METAL_SHARE = 0.84;

/** Below this much memory, Strata says the model does not fit at all (MAC.md). */
export const SMALLEST_MAC_GB = 16;

/** Free disk space a download always leaves, so the Mac does not run out. */
export const KEEP_FREE_BYTES = 10e9;
