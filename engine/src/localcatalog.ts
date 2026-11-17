// What pi² can download to run models on this Mac (#173, #292): the pinned engine and the model packs, with the figures
// Settings shows. This file is data, and the one place to change it: raising the engine's version, correcting a pack's
// memory figure or adding a pack is an edit here, reviewed like any other change.
//
// Every file has its size and SHA-256 written here in advance. pi² never takes a checksum from beside a download (a
// SHA256SUMS file, a release's digest, a server's header): a file that does not match what is written here is deleted
// and nothing from it is run. So a newer engine reaches the person only with a pi² update that pins it.
//
// Sources, read on 2026-11-17 (see #173 for what #290 found when it tried them on a Mac):
// - The engine: Strata's release v0.2.14 on GitHub, asset strata-engine-0.1.60-macos-arm64-metal.tar.gz (the Metal
//   engine alone, without the desktop app), size and SHA-256 as GitHub lists them for that asset.
// - The packs: Hugging Face's listing of each repository's files (size, and the SHA-256 of each large file).
// - Memory: Strata's docs/MAC.md, "What you need" (the M5 Max with 128 GB they were measured on).

/** A file to download, checked against `sha256` (lower-case hex) before it is used. */
export type CatalogFile = { url: string; name: string; size: number; sha256: string };

export type Licence = {
	/** Its name, as the person reads it. */
	name: string;
	/** Where the whole text is. */
	url: string;
	/** What it means for the person, in a sentence or two. Not a substitute for the text. */
	summary: string;
};

export type CatalogEngine = {
	version: string;
	/** A .tar.gz holding the engine. */
	archive: CatalogFile;
	/** The engine's executable, by its name: the shallowest regular file of that name in the archive. */
	executable: string;
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

const QWEN_LICENCE: Licence = {
	name: "Qwen Community License 1.0",
	url: "https://huggingface.co/Qwen/Qwen3.8-Flash-Next/blob/main/LICENSE",
	summary:
		"The model's own licence, from Qwen. Free to use, copy and change, with no warranty. A business that offers models as a service, or an AI coding or office assistant, needs a separate licence from Qwen for commercial use; using it for your own work does not.",
};

const istaFile = (pack: string, part: number, size: number, sha256: string): CatalogFile => {
	const name = `Qwen3.8-Flash-Next-GSQ-RCO-${pack}-0000${part}-of-00002.gguf`;
	return { url: `${ISTA}/resolve/main/${pack}/${name}`, name, size, sha256 };
};
/** The second part of every ISTA-DASLab pack: the n-gram table, read from the SSD a few rows at a time. The same file in each. */
const istaTable = (pack: string) => istaFile(pack, 2, 28_800_138_432, "316b46f3a2dbd68c900f43136ab9449f9dcc3725dfd8c794847c204bc161e113");
const istaVision: CatalogFile = {
	url: `${ISTA}/resolve/main/mmproj-Qwen3.8-Flash-Next-BF16.gguf`,
	name: "mmproj-Qwen3.8-Flash-Next-BF16.gguf",
	size: 907_543_008,
	sha256: "b1a82259702816a5330d7bd7607cd9676b11780e79ff7348c21103ff3ce49bd0",
};
const istaLicences: Licence[] = [
	QWEN_LICENCE,
	{ name: "Apache License 2.0", url: `${ISTA}/blob/main/README.md`, summary: "ISTA-DASLab's quantised files of the model. Free to use, copy and change, with no warranty." },
];

export const CATALOG: Catalog = {
	engine: {
		version: "0.1.60",
		archive: {
			url: `${GITHUB}/releases/download/v0.2.14/strata-engine-0.1.60-macos-arm64-metal.tar.gz`,
			name: "strata-engine-0.1.60-macos-arm64-metal.tar.gz",
			size: 5_754_720,
			sha256: "31ce1cd98bef83938434c15fcc94c1768340037b8fe7f292ee82836db0ca074d",
		},
		executable: "strata",
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
					licences: istaLicences,
				},
				{
					id: "qwen3.8-flash-next-ud-q4-k-xl",
					pack: "UD-Q4_K_XL",
					provider: "Unsloth",
					note: "Closer to the full model than IQ3_S, and slower. Needs a Mac with 128 GB.",
					needsGB: 91,
					recommendedFromGB: 128,
					files: [
						{ url: `${UNSLOTH}/resolve/main/UD-Q4_K_XL/Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf`, name: "Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf", size: 10_946_618, sha256: "acc44040f74d0e55fb89c3967056cce5dbda1bcc52e909c3ba6fc72b5e9c0858" },
						{ url: `${UNSLOTH}/resolve/main/UD-Q4_K_XL/Qwen3.8-Flash-Next-UD-Q4_K_XL-00002-of-00004.gguf`, name: "Qwen3.8-Flash-Next-UD-Q4_K_XL-00002-of-00004.gguf", size: 49_720_539_552, sha256: "45792ae869072d8229384c51c7c73dd959e191505252b41dd71852d9746f5ce4" },
						{ url: `${UNSLOTH}/resolve/main/UD-Q4_K_XL/Qwen3.8-Flash-Next-UD-Q4_K_XL-00003-of-00004.gguf`, name: "Qwen3.8-Flash-Next-UD-Q4_K_XL-00003-of-00004.gguf", size: 32_803_030_176, sha256: "8c76e79d444b16a663d9c8db54e585ed3b1da13eebd2619c37b0c355da803c82" },
						{ url: `${UNSLOTH}/resolve/main/UD-Q4_K_XL/Qwen3.8-Flash-Next-UD-Q4_K_XL-00004-of-00004.gguf`, name: "Qwen3.8-Flash-Next-UD-Q4_K_XL-00004-of-00004.gguf", size: 28_800_138_432, sha256: "5de8b5dbf89409acc39468decafd4a4a95b13c29d88a14b0356107897829ec36" },
						{ url: `${UNSLOTH}/resolve/main/mmproj-BF16.gguf`, name: "mmproj-BF16.gguf", size: 907_542_944, sha256: "2e788f8c511d8093c7b43cb87b2fd7e14228340318057f8fb20c86df2efe2355" },
					],
					visionFile: "mmproj-BF16.gguf",
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

/** The context sizes offered. Strata measured up to 32K on a Mac, and the model takes up to 262K. */
export const CONTEXT_SIZES = [16_384, 32_768, 65_536, 131_072, 262_144];

/** Above this, Strata has not measured how the model does on a Mac. */
export const CONTEXT_MEASURED = 65_536;

/** The share of the Mac's memory Metal lets one program keep resident (MAC.md: 107.5 GB of 128 GB, about 3/4). */
export const METAL_SHARE = 0.75;

/** Below this much memory, Strata says the model does not fit at all (MAC.md). */
export const SMALLEST_MAC_GB = 16;

/** Free disk space a download always leaves, so the Mac does not run out. */
export const KEEP_FREE_BYTES = 10e9;
