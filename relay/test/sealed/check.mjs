// The sealed-bytes check after a live session (docs/iphone.md 10, #683): reads what the recorder kept and what the
// relay's objects keep (`GET /recording` from the recording relay, worker.ts), every file of the relay's local state
// (Wrangler's `--persist-to` folder: the objects' SQLite files and their journals, read whole and raw, so a page the
// relay deleted is read too), and what the local runtime printed (`--output`, at every level: anything the relay wrote
// to the console, or an error it threw; the recording relay's canaries show it gets there), and checks them with
// scan.ts against the session the Swift program wrote.
//
// Run by `scripts/relay-protocol-test --sealed`, never by hand against anything but the recording relay on 127.0.0.1.
//
//   node test/sealed/check.mjs --relay http://127.0.0.1:<port> --state <folder> --session <file> --markers <file> --output <file>
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
if (options.relay === null || options.state === null || options.session === null || options.markers === null || options.output === null) {
	usage("--relay, --state, --session, --markers and --output are needed");
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
	return {
		markers: written.markers,
		secrets: written.secrets.map(fromHex),
		keys: written.keys,
		devices: written.devices,
		noise: written.noise,
		items: written.items,
		kept: written.kept,
	};
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
	for (const key of Object.keys(session)) {
		if (key === "keys") for (const field of Object.keys(session.keys)) session.keys[field] = [...session.keys[field], ...planted.keys[field]];
		else session[key] = [...session[key], ...planted[key]];
	}
}

// The planted session plants its marker in the relay's console too (worker.ts, `?log=`).
const address = new URL("/recording", relay);
if (options.planted !== null) address.searchParams.set("log", session.markers.find((marker) => marker.place === "planted").text);
const response = await fetch(address);
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

// What the relay writes to the console reaches the output read here: the canaries the recording relay wrote, with
// `console.log` and `console.debug`, as it gave the recording, must be in it. The local runtime writes it out a moment
// after, so it is read again for a few seconds until both are there.
const canaries = [recording.canaries.log, recording.canaries.debug];
let output = new Uint8Array();
for (let tries = 0; tries < 50; tries++) {
	output = new Uint8Array(readFileSync(options.output));
	const text = Buffer.from(output).toString("latin1");
	if (canaries.every((canary) => text.includes(canary))) break;
	await new Promise((resolve) => setTimeout(resolve, 200));
}
files.push({ path: "(the local runtime's output)", bytes: output });

const findings = await check(recording, files, session);
const outputText = Buffer.from(output).toString("latin1");
for (const [method, canary] of [["console.log", canaries[0]], ["console.debug", canaries[1]]]) {
	if (!outputText.includes(canary)) findings.push({ rule: "unseen", where: "the local runtime's output", detail: `what the relay writes with ${method} does not reach it` });
}
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

// The planted session: the marker went in clear as the channel's bytes (on a joined phone's socket, then to the Mac),
// as an item (put by the Mac, and left in the phone's mailbox) and as a push (sent by the Mac to the phone, #689), and
// the check had the recording relay write it to the console. Each must be found where it went: the bytes as not the
// session's Noise, both ways, and readable; the item as not a sealed item of the session's, and readable where it was
// put, where it is kept, and in the relay's files; the push as not a sealed item of the session's, in the Mac's request
// and in what the relay posted to Apple, and readable there; the console's in the local runtime's output. Nothing else
// may be found.
const where = [
	["readable", /bytes from the end$/],
	["readable", /bytes from the relay$/],
	["readable", /a text from the end$/],
	["readable", /the pairing object .*: tables\.items/],
	["readable", /^the relay's file v3\//],
	["readable", /^the relay's file \(the local runtime's output\)$/],
	["readable", /^push \d+: its payload$/],
];
const planted = (finding) => finding.rule === "readable" && finding.detail.startsWith("the planted marker");
const missed = where.filter(([rule, pattern]) => !findings.some((finding) => finding.rule === rule && pattern.test(finding.where)));
const notNoise = findings.filter((finding) => finding.rule === "not-noise").map((finding) => finding.where.replace(/.* from the /, "")).sort();
const notSealed = findings
	.filter((finding) => finding.rule === "not-sealed")
	.map((finding) => finding.where.replace(/.* from the /, "").replace(/^push \d+$/, "push"))
	.sort();
if (JSON.stringify(notNoise) !== JSON.stringify(["end", "relay"])) missed.push(["not-noise", "once from the end and once from the relay"]);
if (JSON.stringify(notSealed) !== JSON.stringify(["end", "end", "push"])) missed.push(["not-sealed", "twice from the end (the item and the push) and once in the push to Apple"]);
const unexplained = findings.filter((finding) => !planted(finding) && finding.rule !== "not-noise" && finding.rule !== "not-sealed");
for (const finding of findings) process.stdout.write(`found ${finding.rule}: ${finding.where}: ${finding.detail}\n`);
if (missed.length === 0 && unexplained.length === 0) {
	process.stdout.write(`sealed check: the planted marker was found everywhere it was planted (${findings.length} findings in ${summary}).\n`);
	process.exit(0);
}
for (const [rule, where] of missed) process.stderr.write(`FAIL the planted marker was not found: ${rule} at ${where}\n`);
for (const finding of unexplained) process.stderr.write(`FAIL a finding the planting does not explain: ${finding.rule}: ${finding.where}: ${finding.detail}\n`);
process.exit(1);
