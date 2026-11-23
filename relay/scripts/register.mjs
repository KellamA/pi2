// A test client for a deployed relay (docs/relay.md, "Deploying"): asks whether the relay has its settings, then
// registers a pairing there as a Mac would, with a key made for the run and thrown away, and says what the relay
// answered. The pairing stays pending, with no phone, and the relay deletes it 15 minutes later (README.md, "What it
// decides"). It needs nothing installed, no account and no secret: only Node, from 22 on.
//
//   node relay/scripts/register.mjs wss://pi2-relay-development.<subdomain>.workers.dev/v1 [--build <build>]
//
// Exits 0 once registered; 1 with what went wrong otherwise. Each run counts against the address's registrations
// (5 an hour, 20 a day, docs/iphone.md 6.6).

import { request as httpRequest } from "node:http";
import { request as httpsRequest } from "node:https";
import { randomBytes } from "node:crypto";

const usage = "usage: node relay/scripts/register.mjs wss://<relay>/v1 [--build <build>]";
const args = process.argv.slice(2);
let address;
let build = "1";
for (let index = 0; index < args.length; index++) {
	if (args[index] === "--build" && index + 1 < args.length) build = args[++index];
	else if (address === undefined) address = args[index];
	else fail(usage);
}
if (address === undefined) fail(usage);

let url;
try {
	url = new URL(address);
} catch {
	fail(`not an address: ${address}\n${usage}`);
}
const local = url.hostname === "127.0.0.1" || url.hostname === "localhost" || url.hostname === "[::1]";
if (!(url.protocol === "wss:" || (url.protocol === "ws:" && local)) || url.pathname !== "/v1" || url.search !== "") {
	fail(`the relay's address is wss://<relay>/v1 (ws:// only on this computer): ${address}`);
}
if (!/^(?:0|[1-9][0-9]{0,8})(?:\.(?:0|[1-9][0-9]{0,8})){0,2}$/.test(build)) fail(`not a build: ${build}`);

// workers.dev turns away clients that send a library's own User-Agent (Browser Integrity Check), so say what this is.
const userAgent = "pi2-relay-check/1 (+https://github.com/KellamA/pi2/blob/main/docs/relay.md)";

await probe();
await register();

/**
 * Whether the relay is there and has every setting, without counting a registration or waking any pairing: a
 * WebSocket request with a `Pi2-Pairing` header that is no pairing's id is answered 503 by a relay missing a setting,
 * and 400 by one that has them all, before anything is counted (src/index.ts).
 */
async function probe() {
	const status = await new Promise((resolve, reject) => {
		const send = url.protocol === "wss:" ? httpsRequest : httpRequest;
		const req = send(
			{
				hostname: url.hostname.replace(/^\[|\]$/g, ""),
				port: url.port || (url.protocol === "wss:" ? 443 : 80),
				path: "/v1",
				method: "GET",
				headers: {
					"User-Agent": userAgent,
					Connection: "Upgrade",
					Upgrade: "websocket",
					"Sec-WebSocket-Version": "13",
					"Sec-WebSocket-Key": randomBytes(16).toString("base64"),
					"Pi2-Pairing": "not-a-pairing",
				},
				timeout: 15_000,
			},
			(response) => {
				response.resume();
				resolve(response.statusCode);
			},
		);
		req.on("upgrade", (_response, socket) => {
			socket.destroy();
			resolve(101);
		});
		req.on("timeout", () => req.destroy(new Error("no answer within 15 seconds")));
		req.on("error", reject);
		req.end();
	}).catch((error) => fail(`could not reach ${url.host}: ${error.message}`));

	if (status === 400) return;
	if (status === 503) {
		fail(
			`${url.host} answers, but is missing a setting, so it refuses everything: add its secrets APP_ATTEST_TEAM_ID and ADDRESS_KEY ` +
				"(at least 32 characters) in Cloudflare's dashboard, as docs/relay.md says, and try again in a minute.",
		);
	}
	if (status === 404) fail(`${url.host} answered 404: no relay at /v1 there. Is the address right?`);
	if (status === 403) fail(`${url.host} answered 403: something in front of the relay turned this request away.`);
	if (status === 429) fail(`${url.host} answered 429: too many requests from this address just now. Try again later.`);
	fail(`${url.host} answered ${status}, which no relay of this version answers to this request. Is the address right?`);
}

/** Registers a pairing as a Mac would (README.md, "The protocol"), and says what the relay answered. */
async function register() {
	const keys = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, false, ["sign", "verify"]);
	const relayKey = Buffer.from(await crypto.subtle.exportKey("spki", keys.publicKey)).toString("base64url");

	await new Promise((resolve) => {
		const socket = new WebSocket(url, { headers: { "User-Agent": userAgent } });
		let done = false;
		const timer = setTimeout(() => fail("the relay did not finish the registration within 15 seconds"), 15_000);
		const finish = (message, code) => {
			done = true;
			clearTimeout(timer);
			socket.close();
			if (code !== 0) fail(message);
			process.stdout.write(`${message}\n`);
			resolve();
		};

		socket.addEventListener("open", () => {
			socket.send(JSON.stringify({ register: { v: 1, build, relayKey } }));
		});
		socket.addEventListener("message", async (event) => {
			if (typeof event.data !== "string") return finish("the relay sent bytes where it should have sent a challenge", 1);
			let message;
			try {
				message = JSON.parse(event.data);
			} catch {
				return finish("the relay sent something that is not one of its messages", 1);
			}
			if (typeof message.challenge === "string") {
				// What a Mac signs at `register`: pi2-relay-v1, register, no pairing, no device, the challenge (src/protocol.ts).
				const text = ["pi2-relay-v1", "register", "", "", message.challenge].join("\0");
				const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, keys.privateKey, new TextEncoder().encode(text));
				socket.send(JSON.stringify({ proof: { signature: Buffer.from(signature).toString("base64url") } }));
			} else if (typeof message.registered?.pairing === "string") {
				finish(`Registered at ${url.host}: a pending pairing, which the relay deletes in 15 minutes.`, 0);
			} else if (typeof message.refused?.why === "string") {
				finish(`${url.host} refused the registration: ${message.refused.why}`, 1);
			}
		});
		socket.addEventListener("close", (event) => {
			if (!done) finish(`the relay closed the connection before registering (${event.code}${event.reason ? `, ${event.reason}` : ""})`, 1);
		});
		socket.addEventListener("error", () => {
			if (!done) finish("the WebSocket connection failed", 1);
		});
	});
}

function fail(message) {
	process.stderr.write(`register: ${message}\n`);
	process.exit(1);
}
