// The sealed-bytes check after a live session (docs/iphone.md 10, #683): reads what the recorder kept and what the
// relay's objects keep (`GET /recording` from the recording relay, worker.ts), every file of the relay's local state
// (Wrangler's `--persist-to` folder: the objects' SQLite files and their journals, read whole and raw, so a page the
// relay deleted is read too), and what the local runtime printed (`--output`: anything the relay wrote to the console,
// or an error it threw, would be there), and checks them with scan.ts against the session the Swift program wrote.
//
// Run by `scripts/relay-protocol-test --sealed`, never by hand against anything but the recording relay on 127.0.0.1.
//
//   node test/sealed/check.mjs --relay http://127.0.0.1:<port> --state <folder> --session <file> --markers <file> [--output <file>]
//   node test/sealed/check.mjs … --planted <the planted session's file>
//
// Without --planted, exits 0 when nothing was found, 1 naming each finding. With --planted, a second session planted a
// marker in clear after the first (pi2-relay-check --plant), and the check runs on both: it exits 0 only when it finds
// the planted marker in every place it was planted, and nothing else. 2 for a wrong argument.

import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative } from "node:path";
import { check, decode, fromHex } from "./scan.ts";

const options = { relay: null, state: null, session: null, markers: null, planted: null, output: null };
const args = process.argv.slice(2);
while (args.length > 0) {
	const name = args.shift();
	if (["--relay", "--state", "--session", "--markers", "--planted", "--output"].includes(name) && args.length > 0) options[name.slice(2)] = args.shift();
	else usage(`unknown argument ${name}`);
}
if (options.relay === null || options.state === null || options.session === null || options.markers === null) {
	usage("--relay, --state, --session and --markers are needed");
}
const relay = new URL(options.relay);
if (!["127.0.0.1", "localhost", "[::1]"].includes(relay.hostname)) usage("a relay on this computer only");

function usage(why) {
	process.stderr.write(`sealed check: ${why}\n`);
	process.exit(2);
}

// The session as its ends tell it. The markers it must have sent are this folder's markers.json; the Swift program
// reads the same file, and says which it sent. A planted session adds its own.
const read = (path) => {
	const written = JSON.parse(readFileSync(path, "utf8"));
	return { markers: written.markers, secrets: written.secrets.map(fromHex), noise: written.noise, items: written.items, kept: written.kept };
};
const session = read(options.session);
const wanted = JSON.parse(readFileSync(options.markers, "utf8"));
const sent = new Set(session.markers.map((marker) => `${marker.place}\0${marker.text}`));
const missing = wanted.filter((marker) => !sent.has(`${marker.place}\0${marker.text}`));
if (missing.length > 0 || session.markers.length !== wanted.length) {
	process.stderr.write(`sealed check: the session did not send every marker of ${options.markers}: ${missing.map((marker) => marker.place).join(", ")}\n`);
	process.exit(1);
}
if (options.planted !== null) {
	const planted = read(options.planted);
	for (const key of Object.keys(session)) session[key] = [...session[key], ...planted[key]];
}

const response = await fetch(new URL("/recording", relay));
if (!response.ok) usage(`the recording relay answered ${response.status}`);
const recording = decode(await response.json());

const files = [];
(function readFolder(folder) {
	for (const name of readdirSync(folder)) {
		const path = join(folder, name);
		if (statSync(path).isDirectory()) readFolder(path);
		else files.push({ path: relative(options.state, path), bytes: new Uint8Array(readFileSync(path)) });
	}
})(options.state);
if (options.output !== null) files.push({ path: "(the local runtime's output)", bytes: new Uint8Array(readFileSync(options.output)) });

const findings = await check(recording, files, session);
const sockets = new Set(recording.events.map((event) => event.socket)).size;
const summary = `${recording.events.length} events on ${sockets} sockets, ${recording.stored.length} objects read back, ${files.length} files of the relay's state, ${recording.pushes.length} pushes`;
const headers = new Set(recording.events.flatMap((event) => (event.kind === "open" ? event.headers.map(([name]) => name.toLowerCase()) : [])));
process.stdout.write(`sealed check: the headers the relay was given: ${[...headers].sort().join(", ")}\n`);

if (options.planted === null) {
	if (findings.length === 0) {
		process.stdout.write(`sealed check: nothing readable. ${session.markers.length} markers and ${session.secrets.length} secrets looked for in ${summary}; ${session.noise.length} Noise messages and ${session.items.length} sealed items, each the session's own.\n`);
		process.exit(0);
	}
	for (const finding of findings) process.stderr.write(`FAIL ${finding.rule}: ${finding.where}: ${finding.detail}\n`);
	process.stderr.write(`sealed check: ${findings.length} findings in ${summary}\n`);
	process.exit(1);
}

// The planted session: the marker went in clear as the channel's bytes (on a joined phone's socket, then to the Mac)
// and as an item (put by the Mac, and left in the phone's mailbox). Each must be found where it went: the bytes as
// not the session's Noise, both ways, and readable; the item as not a sealed item of the session's, and readable where
// it was put, where it is kept, and in the relay's files. Nothing else may be found.
const where = [
	["readable", /bytes from the end$/],
	["readable", /bytes from the relay$/],
	["readable", /a text from the end$/],
	["readable", /the pairing object .*: tables\.items/],
	["readable", /^the relay's file /],
];
const planted = (finding) => finding.rule === "readable" && finding.detail.startsWith("the planted marker");
const missed = where.filter(([rule, pattern]) => !findings.some((finding) => finding.rule === rule && pattern.test(finding.where)));
const notNoise = findings.filter((finding) => finding.rule === "not-noise").map((finding) => finding.where.replace(/.* from the /, "")).sort();
const notSealed = findings.filter((finding) => finding.rule === "not-sealed").map((finding) => finding.where.replace(/.* from the /, ""));
if (JSON.stringify(notNoise) !== JSON.stringify(["end", "relay"])) missed.push(["not-noise", "once from the end and once from the relay"]);
if (JSON.stringify(notSealed) !== JSON.stringify(["end"])) missed.push(["not-sealed", "once, from the end"]);
const unexplained = findings.filter((finding) => !planted(finding) && finding.rule !== "not-noise" && finding.rule !== "not-sealed");
for (const finding of findings) process.stdout.write(`found ${finding.rule}: ${finding.where}: ${finding.detail}\n`);
if (missed.length === 0 && unexplained.length === 0) {
	process.stdout.write(`sealed check: the planted marker was found everywhere it was planted (${findings.length} findings in ${summary}).\n`);
	process.exit(0);
}
for (const [rule, where] of missed) process.stderr.write(`FAIL the planted marker was not found: ${rule} at ${where}\n`);
for (const finding of unexplained) process.stderr.write(`FAIL a finding the planting does not explain: ${finding.rule}: ${finding.where}: ${finding.detail}\n`);
process.exit(1);
