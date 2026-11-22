// Makes noise.json and hpke.json, the published test vectors pi2-remote-check runs RemoteKit against (#674).
//
//   node app/Sources/pi2-remote-check/vectors/extract.mjs
//
// Each source is fetched at a pinned commit and its SHA-256 checked before anything is taken from it, so the fixtures
// can be made again and compared, byte for byte, with the ones in the repository. Only the vectors of the protocols
// pi² uses are kept, each exactly as its source has it: Noise_KK_25519_ChaChaPoly_SHA256 and
// Noise_IKpsk2_25519_ChaChaPoly_SHA256 (iphone.md 5.2), and HPKE's authenticated mode with DHKEM(P-256, HKDF-SHA256),
// HKDF-SHA256 and AES-256-GCM (iphone.md 5.3). flynn/noise writes its vectors as key=value blocks; they are kept as
// objects of the same keys and values.

import { createHash } from "node:crypto";
import { writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const protocols = ["Noise_KK_25519_ChaChaPoly_SHA256", "Noise_IKpsk2_25519_ChaChaPoly_SHA256"];

const noiseSources = [
	{
		name: "cacophony",
		repository: "https://github.com/haskell-cryptography/cacophony",
		commit: "8ee9d41e34a1a596cfa3ab12aa4069ff87dc1247",
		path: "vectors/cacophony.txt",
		sha256: "3bde7c09a6f349ee11c825c50fcc02649f8f02a47c857a459206b357f9386cae",
		format: "json",
	},
	{
		name: "snow",
		repository: "https://github.com/mcginty/snow",
		commit: "8ac60f51cfe3e010c84f0a454cc575ad9204fa12",
		path: "tests/vectors/snow.txt",
		sha256: "69da433305fd045f6c9f01b656662a389d022688986fd39fbe7af009cd402fd3",
		format: "json",
	},
	{
		name: "noise-c",
		repository: "https://github.com/rweather/noise-c",
		commit: "cfe25410979a87391bb9ac8d4d4bef64e9f268c6",
		path: "tests/vector/noise-c-basic.txt",
		sha256: "e826749cf90efda26be85410381f4b1f75552c61c7c0dcad7f9ffb4d639e4e45",
		format: "json",
	},
	{
		name: "flynn-noise",
		repository: "https://github.com/flynn/noise",
		commit: "4d9f71cd4ba1fe81415efac312664ccc4bc79b46",
		path: "vectors.txt",
		sha256: "0b8a1305176c95952802b114baa4aa2a3d6e7c33fdf2035b60b8c92058a50d9c",
		format: "blocks",
	},
];

const hpkeSource = {
	name: "cfrg-hpke",
	repository: "https://github.com/cfrg/draft-irtf-cfrg-hpke",
	commit: "b1f7cb0cdeab6906c61b3d6574e8bdfdbe1cd3fb",
	path: "test-vectors.json",
	sha256: "61fc662f01996cd06d713dacf5e133167bd309a1f329442d53f1e21a47b3ede6",
	note: "RFC 9180, Appendix A: 'These test vectors are also available in JSON format at [TestVectors]', this file.",
};

async function fetchSource(source) {
	const url = `https://raw.githubusercontent.com/${source.repository.replace("https://github.com/", "")}/${source.commit}/${source.path}`;
	const response = await fetch(url);
	if (!response.ok) throw new Error(`${url}: ${response.status}`);
	const bytes = Buffer.from(await response.arrayBuffer());
	const sha256 = createHash("sha256").update(bytes).digest("hex");
	if (sha256 !== source.sha256) throw new Error(`${url}: SHA-256 ${sha256}, expected ${source.sha256}`);
	return { url, sha256, text: bytes.toString("utf8") };
}

function blocks(text) {
	return text
		.split(/\n\s*\n/)
		.map((block) => {
			const entry = {};
			for (const line of block.split("\n")) {
				const at = line.indexOf("=");
				if (at > 0) entry[line.slice(0, at)] = line.slice(at + 1);
			}
			return entry;
		})
		.filter((entry) => Object.keys(entry).length > 0);
}

const noise = { about: "Published Noise test vectors for the two protocols of iphone.md 5.2, made by extract.mjs.", sources: [], vectors: [] };
for (const source of noiseSources) {
	const { url, sha256, text } = await fetchSource(source);
	noise.sources.push({ name: source.name, repository: source.repository, commit: source.commit, url, sha256, format: source.format });
	const all = source.format === "json" ? JSON.parse(text).vectors : blocks(text);
	for (const vector of all) {
		const name = vector.protocol_name ?? vector.name ?? vector.handshake;
		if (protocols.includes(name)) noise.vectors.push({ source: source.name, vector });
	}
}

const hpke = { about: "RFC 9180's published HPKE test vectors for the suite of iphone.md 5.3, made by extract.mjs.", sources: [], vectors: [] };
{
	const { url, sha256, text } = await fetchSource(hpkeSource);
	hpke.sources.push({ name: hpkeSource.name, repository: hpkeSource.repository, commit: hpkeSource.commit, url, sha256, note: hpkeSource.note });
	for (const vector of JSON.parse(text)) {
		if (vector.mode === 2 && vector.kem_id === 16 && vector.kdf_id === 1 && vector.aead_id === 2) hpke.vectors.push({ source: hpkeSource.name, vector });
	}
}

writeFileSync(join(here, "noise.json"), JSON.stringify(noise, null, "\t") + "\n");
writeFileSync(join(here, "hpke.json"), JSON.stringify(hpke, null, "\t") + "\n");
console.log(`noise.json: ${noise.vectors.length} vectors from ${noise.sources.map((s) => `${s.name} (${s.sha256})`).join(", ")}`);
console.log(`hpke.json: ${hpke.vectors.length} vectors from ${hpke.sources[0].name} (${hpke.sources[0].sha256})`);
