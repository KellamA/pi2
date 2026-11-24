// pi² Remote, as the engine starts it and hears it (docs/iphone.md 5.5, 4.1; #673): the engine's own child, trusted
// only on the socket pair the engine made for it (decision 24), and the device sessions it carries.
//
// The engine starts pi² Remote with its control connection as file descriptor 3: one end of a Unix socket pair, which
// libuv makes for a `pipe` in `spawn`'s stdio, as `pi2-peer` is given a connection. It starts one at a time, while the
// preview and remote access are on and a device is paired or a pairing is open, again if it dies (waiting twice as
// long after each failure, up to a minute), and stops it when they go off or the engine stops. It gives it nothing
// through arguments or the environment: the relay, the switches and the paired devices' keys come over the connection.
// The engine takes `remote.*` requests, and device sessions, only on that connection; on its listening socket a
// `remote.*` request is refused whoever sends it (main.ts), whatever PeerKit says of the process.
//
// The control connection carries one JSON object a line, each way:
//
// - pi² Remote's own requests, `{"id","method","params"}` with a `remote.*` method (FOR_THE_HELPER in answers.ts),
//   answered `{"id","result"}` or `{"id","error"}`;
// - a device's lines in a session: `{"session","message"}`, the message being one of the engine's own requests, as
//   the app sends them, and from the engine its answers and events, as the app is sent them (5.6);
// - the `remote` event, `{"event":"remote","kind",…}`, to pi² Remote alone: `start` (the relay, the switches, the
//   pairing, the paired devices' keys and the lowest build to attach, sent first), `settings`, `register`,
//   `openJoin` (the pairing's secret and the relay's token hash) and `closeJoin`, `paired` and `pairRefused` (the
//   answer to a claim), `revoke`, `presenceKey` (a device's new Face ID key, accepted on the Mac, #786), and
//   `sessionClosed`; and `push` (#689, P20), what pushes.ts chose to push to a device, which pi² Remote seals (but a
//   Live Activity's numbers) and asks the relay to send.
//
// pi² Remote's requests: `remote.hello` (the Mac's public keys, the pairing, the Mac's addresses), `remote.state` (the
// same when they change), `remote.pairClaim`, `remote.pairWrong` and `remote.pairRefused` (pairing, 3.3), `remote.attachBegin` and
// `remote.attach` (3.4: an attach or a resume, signed by the device key and the presence key), and
// `remote.sessionEnd` (the phone's session ended, 4.5), `remote.presenceKey` (a phone's offer of a new Face ID key, signed
// as an attach is, 3.2, #786), and `remote.pushRefused` (the relay refused a push, pushes.ts). `remote.mailboxIn` (#678,
// P10) is added here, and checks each
// item with `checkRequestItem` in devices.ts.
//
// A device session is a `Client` of its own (clients.ts) with `device` set, so it has its own subscriptions and
// greeting, and is sent the broadcasts every app is. What it is sent passes `forDevice`: never the events of 5.7,
// endpoints' addresses by name only, and every key-shaped string masked. Every request in it is checked against the
// device's table (`deviceMay`) before its handler runs, and logged (devices.ts).

import { type ChildProcess, spawn } from "node:child_process";
import { randomBytes } from "node:crypto";
import { existsSync } from "node:fs";
import type { Socket } from "node:net";
import { join } from "node:path";
import { allowsHiddenApproval, type DevicePath, deviceLogged, deviceMay, forTheHelper, HIDDEN_FROM_THE_PHONE, ONLY_ON_THE_MAC, OPEN_WITH_FACE_ID } from "./answers.ts";
import { type Client, clients, send, type Wire } from "./clients.ts";
import {
	attachChallenge,
	attachHolds,
	attachTaken,
	checkAttach,
	type Device,
	devicesState,
	fromBase64url,
	helperReported,
	helperWanted,
	logDevice,
	macNameNow,
	MINIMUM_PHONE_BUILD,
	maskValue,
	shownName,
	notify,
	offerPresenceKey,
	p256Key,
	pairClaim,
	pairedDevice,
	pairRefusedByHelper,
	pairWrong,
	helperGone,
	activeDevices,
	remoteHooks,
	requestLogged,
	sessionsChanged,
	summarize,
	DEVICE_FAULT,
} from "./devices.ts";
import type { SwitchName } from "./projects.ts";
import { pushes } from "./pushes.ts";
import type { Params } from "./requests.ts";
import { refusal } from "./requesterror.ts";
import { testSwitch } from "./testswitches.ts";

type Handler = (params: Params, client: Client) => Promise<unknown>;
type RemoteParts = {
	log: (...parts: unknown[]) => void;
	/** The app bundle this engine belongs to (answers.ts), which carries pi² Remote; null when it knows none. */
	bundle: string | null;
	handlers: Readonly<Record<string, Handler>>;
	/** What an app is sent on connecting (main.ts); a device session is sent the same, less what 5.7 keeps back. */
	greet: (client: Client) => void;
	/** What main.ts does when a connection goes: its subscriptions stopped, features told. */
	drop: (client: Client) => void;
	approvalSwitch: (id: string) => SwitchName | null;
	/** Whether a device's copy of the approval waiting under an id hides part of it (answers.ts, `approvalHidden`). */
	approvalHidden: (id: string) => boolean;
};

let log: RemoteParts["log"];
let bundle: string | null;
let handlers: RemoteParts["handlers"];
let greet: RemoteParts["greet"];
let drop: RemoteParts["drop"];
let approvalSwitch: RemoteParts["approvalSwitch"];
let approvalHidden: RemoteParts["approvalHidden"];

type Helper = { child: ChildProcess; wire: Socket; hello: { addresses: string[] } | null; stopping: boolean };
let helper: Helper | null = null;
let stopping = false;
let restartDelay = 1_000;
let restartTimer: ReturnType<typeof setTimeout> | undefined;
/** When pi² Remote stopped by itself, this last hour: the Devices page says so after three (4.4). */
let stops: number[] = [];
const waiters = new Set<{ resolve: (hello: { addresses: string[] }) => void }>();
let saidMissing = false;

type Session = { id: string; device: string; path: Exclude<DevicePath, "mailbox">; since: number; client: Client; closed: boolean; limit?: ReturnType<typeof setTimeout> };
const sessions = new Map<string, Session>();

/**
 * The engine's own bound on a session, whatever pi² Remote does: a session ends when the helper's connection closes,
 * and at the latest a day after its last attach or resume with a presence signature. A channel lasts at most a day
 * and is then made again (5.2), and every new channel is a resume with a new presence signature (5.8, decision 28),
 * so a day is the longest a session can rightly go without one. `PI2_DEVICE_SESSION_MS`, a development engine's test
 * switch, shortens it for the tests.
 */
const SESSION_LIMIT_MS = (() => {
	const given = Number(testSwitch("PI2_DEVICE_SESSION_MS"));
	return Number.isSafeInteger(given) && given > 0 ? given : 86_400_000;
})();
export const SESSION_OVER = "The session reached its limit. Open pi² with Face ID again.";

/** Starts the session's bound again from now: at an attach or a resume, each signed under Face ID. */
function bound(session: Session): void {
	clearTimeout(session.limit);
	session.limit = setTimeout(() => closeSession(session.id, SESSION_OVER), SESSION_LIMIT_MS);
	session.limit.unref();
}

export function wireRemote(parts: RemoteParts): void {
	({ log, bundle, handlers, greet, drop, approvalSwitch, approvalHidden } = parts);
	Object.assign(remoteHooks, {
		changed: reconsider,
		toHelper,
		ready,
		closeSessions,
		sessions: () => [...sessions.values()].map(({ device, id, path, since }) => ({ device, session: id, path, since })),
		helper: () => {
			const now = Date.now();
			stops = stops.filter((at) => now - at < 3_600_000);
			return { running: helper !== null && helper.hello !== null, stoppedInLastHour: stops.length };
		},
		recordChanged: (device: string) => {
			const record = pairedDevice(device);
			if (record !== undefined) for (const session of sessions.values()) if (session.device === device) send(session.client, deviceEvent(record));
		},
		addresses: () => (helper?.hello == null ? null : helper.hello.addresses),
	} satisfies typeof remoteHooks);
	reconsider();
}

/** Stops pi² Remote with the engine. */
export function stopRemote(): void {
	stopping = true;
	clearTimeout(restartTimer);
	clearTimeout(stopTimer);
	if (helper !== null) {
		helper.stopping = true;
		helper.child.kill("SIGTERM");
	}
}

// ---- Starting and stopping pi² Remote

/** What runs as pi² Remote: the bundle's helper, or in a development engine's tests, a stand-in run with this Node. */
function helperProgram(): { command: string; args: string[] } | null {
	const standIn = testSwitch("PI2_REMOTE_STAND_IN");
	if (standIn !== undefined && standIn !== "") return { command: process.execPath, args: [standIn] };
	if (bundle === null) return null;
	const program = join(bundle, "Contents", "Helpers", "pi² Remote.app", "Contents", "MacOS", "pi² Remote");
	return existsSync(program) ? { command: program, args: [] } : null;
}

let stopTimer: ReturnType<typeof setTimeout> | undefined;
/** The longest line pi² Remote takes from a phone (#675): two pictures of 5 MB in base64, with the message's text. */
export const MAX_PHONE_LINE = 16 * 1024 * 1024;
/**
 * The longest line taken from pi² Remote, in characters: a phone's line, at most MAX_PHONE_LINE bytes, so as many
 * characters or fewer, in its session's wrapping (`{"session":…,"message":…}`), with room to spare. pi² Remote's own
 * requests are far smaller.
 */
export const MAX_HELPER_LINE = MAX_PHONE_LINE + 64 * 1024;

/**
 * Starts or stops pi² Remote as `helperWanted` says. It is stopped a moment after it is no longer wanted, not at once:
 * what the engine has still to tell it (the answer to the claim that closed a window, `closeJoin`) goes first, and a
 * pairing started again at once finds it running. Its connection is ended first, which it exits on; then a signal.
 */
function reconsider(): void {
	if (stopping) return;
	if (!helperWanted()) {
		clearTimeout(restartTimer);
		restartTimer = undefined;
		if (helper !== null && stopTimer === undefined) {
			stopTimer = setTimeout(() => {
				stopTimer = undefined;
				if (helperWanted() || helper === null) return;
				const current = helper;
				current.stopping = true;
				current.wire.end();
				setTimeout(() => current.child.kill("SIGTERM"), 5_000).unref();
			}, 2_000);
			stopTimer.unref();
		}
		return;
	}
	clearTimeout(stopTimer);
	stopTimer = undefined;
	if (helper === null && restartTimer === undefined) startHelper();
}

function startHelper(): void {
	const program = helperProgram();
	if (program === null) {
		if (!saidMissing) log("remote: this build of pi² has no pi² Remote to start");
		saidMissing = true;
		return;
	}
	// One end of a socket pair as descriptor 3, and nothing else: no arguments, no environment (5.5).
	const child = spawn(program.command, program.args, { stdio: ["ignore", "ignore", "ignore", "pipe"], env: {} });
	const wire = child.stdio[3] as Socket;
	const current: Helper = { child, wire, hello: null, stopping: false };
	helper = current;
	log("remote: started pi² Remote, process", child.pid);
	const unfinished: string[] = [];
	wire.setEncoding("utf8");
	let held = 0;
	wire.on("data", (chunk: string) => {
		let start = 0;
		for (let newline = chunk.indexOf("\n"); ; newline = chunk.indexOf("\n", start)) {
			if (newline === -1) {
				if (start < chunk.length) unfinished.push(chunk.slice(start));
				held += chunk.length - start;
				// A line longer than any a phone may send stops pi² Remote, as a crash does: it faces the network.
				if (held > MAX_HELPER_LINE && !current.stopping) {
					log(`remote: pi² Remote sent a line longer than ${MAX_HELPER_LINE} characters, and was stopped`);
					unfinished.length = 0;
					wire.destroy();
					current.child.kill("SIGKILL");
				}
				break;
			}
			unfinished.push(chunk.slice(start, newline));
			const line = unfinished.join("");
			unfinished.length = 0;
			held = 0;
			start = newline + 1;
			if (line.trim() !== "") heard(current, line);
		}
	});
	wire.on("error", () => {});
	child.once("error", (error) => {
		log("remote: pi² Remote could not be started:", error.message);
		gone(current);
	});
	child.once("exit", (code, signal) => {
		if (!current.stopping) log(`remote: pi² Remote stopped by itself (${signal ?? `code ${code}`})`);
		gone(current);
	});
	const state = devicesState();
	toHelper({
		kind: "start",
		relay: state.relay,
		switches: state.remote,
		pairing: state.pairing,
		devices: activeDevices().map(({ id, deviceKey, channelKey, recordKey, presenceKey }) => ({ id, deviceKey, channelKey, recordKey, presenceKey })),
		minimumBuild: MINIMUM_PHONE_BUILD,
	});
}

function gone(current: Helper): void {
	if (helper !== current) return;
	helper = null;
	current.wire.destroy();
	for (const session of [...sessions.values()]) closeSession(session.id, "pi² Remote stopped");
	helperGone();
	sessionsChanged();
	if (stopping || current.stopping) {
		reconsider();
		return;
	}
	stops.push(Date.now());
	const delay = restartDelay;
	restartDelay = Math.min(restartDelay * 2, 60_000);
	restartTimer = setTimeout(() => {
		restartTimer = undefined;
		reconsider();
	}, delay);
	restartTimer.unref();
}

/** Waits for a pi² Remote that said hello, starting one. */
function ready(): Promise<{ addresses: string[] }> {
	reconsider();
	if (helper?.hello != null) return Promise.resolve(helper.hello);
	if (helperProgram() === null) return Promise.reject(new Error("This build of pi² has no pi² Remote."));
	return new Promise((resolve, reject) => {
		const waiter = {
			resolve: (hello: { addresses: string[] }) => {
				clearTimeout(timer);
				resolve(hello);
			},
		};
		const timer = setTimeout(() => {
			waiters.delete(waiter);
			reject(new Error("pi² Remote did not start. Try again in a moment."));
		}, 60_000);
		waiters.add(waiter);
	});
}

function write(current: Helper | null, message: string): void {
	if (current !== null && !current.wire.destroyed) current.wire.write(message);
}

/** A `remote` event, to pi² Remote alone. */
function toHelper(event: Record<string, unknown>): void {
	write(helper, `${JSON.stringify({ event: "remote", ...event })}\n`);
}

// ---- The control connection

function heard(current: Helper, line: string): void {
	if (helper !== current) return;
	let message: { id?: unknown; method?: unknown; params?: unknown; session?: unknown; message?: unknown };
	try {
		message = JSON.parse(line);
	} catch {
		log("remote: pi² Remote sent a line that is not JSON");
		return;
	}
	if (typeof message !== "object" || message === null || Array.isArray(message)) return;
	if (typeof message.session === "string") void deviceLine(message.session, message.message).catch(deviceLineFailed(message.session, message.message));
	else void helperRequest(current, message);
}

async function helperRequest(current: Helper, request: { id?: unknown; method?: unknown; params?: unknown }): Promise<void> {
	const respond = (body: Record<string, unknown>) => write(current, `${JSON.stringify({ id: request.id ?? null, ...body })}\n`);
	const method = request.method;
	if (typeof method !== "string" || !forTheHelper(method) || !Object.hasOwn(helperRequests, method)) {
		respond({ error: "pi² Remote's own requests are remote.*; a device's go in its session." });
		return;
	}
	const params = request.params ?? {};
	if (typeof params !== "object" || params === null || Array.isArray(params)) {
		respond({ error: "Request parameters must be an object" });
		return;
	}
	try {
		respond({ result: await helperRequests[method]!(current, params as Params) });
	} catch (error) {
		respond(refusal(error));
	}
}

const addressList = (value: unknown): value is string[] =>
	Array.isArray(value) && value.length <= 16 && value.every((one) => typeof one === "string" && /^(\d{1,3}(\.\d{1,3}){3}|\[[0-9a-fA-F:.]{2,45}\]):\d{1,5}$/.test(one));

/** pi² Remote's requests, taken on its connection alone. */
export const helperRequests: Record<string, (current: Helper, params: Params) => Promise<unknown>> = {
	"remote.hello": async (current, params) => {
		const keys = params.macKeys as Record<string, unknown> | undefined;
		if (typeof keys !== "object" || keys === null || p256Key(keys.identity) === null || p256Key(keys.record) === null || p256Key(keys.relay) === null || fromBase64url(keys.channel, 32) === null || typeof keys.secureEnclave !== "boolean") {
			throw new Error("The Mac's keys are not ones pi² Remote makes.");
		}
		const pairing = params.pairing ?? null;
		if (pairing !== null && fromBase64url(pairing, 16) === null) throw new Error("The pairing is not a pairing's id.");
		const addresses = params.addresses ?? [];
		if (!addressList(addresses)) throw new Error("The addresses are not the Mac's addresses.");
		const macKeys = { identity: keys.identity as string, channel: keys.channel as string, record: keys.record as string, relay: keys.relay as string, secureEnclave: keys.secureEnclave };
		await helperReported({ macKeys, pairing: pairing as string | null });
		current.hello = { addresses };
		restartDelay = 1_000;
		for (const waiter of [...waiters]) {
			waiters.delete(waiter);
			waiter.resolve(current.hello);
		}
		sessionsChanged();
		return {};
	},
	"remote.state": async (current, params) => {
		if (current.hello === null) throw new Error("pi² Remote has not said hello.");
		if (params.pairing !== undefined) {
			if (fromBase64url(params.pairing, 16) === null) throw new Error("The pairing is not a pairing's id.");
			await helperReported({ pairing: params.pairing as string });
		}
		if (params.addresses !== undefined) {
			if (!addressList(params.addresses)) throw new Error("The addresses are not the Mac's addresses.");
			current.hello = { addresses: params.addresses };
			for (const session of sessions.values()) {
				const device = pairedDevice(session.device);
				if (device !== undefined) send(session.client, deviceEvent(device));
			}
		}
		return {};
	},
	"remote.pairClaim": async (_current, params) => pairClaim(params),
	"remote.pairWrong": async () => {
		pairWrong();
		return {};
	},
	"remote.pairRefused": async (_current, params) => {
		pairRefusedByHelper(params.why);
		return {};
	},
	"remote.attachBegin": async (_current, params) => {
		if (Object.keys(params).some((key) => key !== "session")) throw new Error("remote.attachBegin takes a session to resume, or nothing.");
		return attachChallenge();
	},
	"remote.attach": async (current, params) => {
		const attached = await checkAttach(params);
		// Again, with nothing awaited before the session opens: a key accepted, or a revocation, while the attach was saved (#786).
		attachHolds(attached);
		const resuming = attached.session === null ? undefined : sessions.get(attached.session);
		const resumed = resuming !== undefined && resuming.device === attached.device.id;
		let session: Session;
		if (resumed) {
			session = resuming;
			session.path = attached.path;
			bound(session);
		} else {
			session = openSession(attached.device, attached.path);
			// The greeting goes once pi² Remote has the session's id, which this answer gives it: after the answer.
			setImmediate(() => {
				if (helper !== current || session.closed) return;
				greet(session.client);
				send(session.client, deviceEvent(attached.device));
			});
		}
		void attachTaken(attached.device.id, attached.path, resumed).catch((error) => log("devices: the log could not be written:", error));
		sessionsChanged();
		return { session: session.id, resume: resumed };
	},
	"remote.sessionEnd": async (_current, params) => {
		if (typeof params.session !== "string") throw new Error("session must be a session's id");
		closeSession(params.session, "The session ended on the phone.");
		return {};
	},
	"remote.presenceKey": async (_current, params) => offerPresenceKey(params),
	// "remote.mailboxIn": #678 (P10), with checkRequestItem (devices.ts).
	/** `{ id, why }`: the relay refused the push `id` (docs/iphone.md 7); pushes.ts holds back what the refusal says. */
	"remote.pushRefused": async (_current, params) => {
		if (typeof params.id !== "string" || typeof params.why !== "string" || Object.keys(params).length !== 2) throw new Error("remote.pushRefused takes a push's id and why");
		if (pushes?.refused(params.id, params.why) !== true) log("remote: pi² Remote answered for a push the engine does not know, or no longer remembers");
		return {};
	},
};

// ---- Device sessions (4.1)

function openSession(device: Device, path: Session["path"]): Session {
	const id = `s_${randomBytes(18).toString("base64url")}`;
	const session = { id, device: device.id, path, since: Date.now(), closed: false } as Session;
	session.client = { socket: deviceWire(session), subscriptions: new Map(), shown: new Set(), device: { id: device.id, session: id } };
	sessions.set(id, session);
	clients.add(session.client);
	bound(session);
	return session;
}

/** Ends a session at once: its connection goes as an app's does when it quits, and pi² Remote is told. */
function closeSession(id: string, why: string): void {
	const session = sessions.get(id);
	if (session === undefined) return;
	sessions.delete(id);
	session.closed = true;
	clearTimeout(session.limit);
	drop(session.client);
	toHelper({ kind: "sessionClosed", session: id, why });
	sessionsChanged();
}

/** Closes every session of `device`; a revoked one is told first, with `revoked: true` (5.6). */
function closeSessions(device: string, why: string): void {
	const record = devicesState().devices.find((one) => one.id === device);
	for (const session of [...sessions.values()]) {
		if (session.device !== device) continue;
		if (record !== undefined && record.revokedAt !== null) send(session.client, deviceEvent(record));
		closeSession(session.id, why);
	}
}

/** The `device` event: what a session is sent of its own record, after the greeting and whenever it changes (5.6). */
function deviceEvent(device: Device) {
	const state = devicesState();
	return {
		event: "device",
		id: device.id,
		// Stored shown already (devices.ts); stripped again, so a record from before reads back as a phone shows it.
		name: shownName(device.name, "iPhone"),
		pairing: state.pairing,
		mac: { name: macNameNow() },
		addresses: helper?.hello?.addresses ?? [],
		relay: state.remote.relay,
		revoked: device.revokedAt !== null,
	};
}

/** A session's connection: each line the engine writes goes to pi² Remote, tagged with the session, as `forDevice` lets it. */
function deviceWire(session: Session): Wire {
	return {
		get destroyed() {
			return session.closed || helper === null || helper.wire.destroyed;
		},
		write(text: string) {
			if (session.closed) return;
			for (const line of text.split("\n")) {
				if (line === "") continue;
				const out = forDevice(line);
				if (out !== null) write(helper, `{"session":${JSON.stringify(session.id)},"message":${out}}\n`);
			}
		},
		destroy() {
			closeSession(session.id, "closed");
		},
	};
}

/**
 * The events a device is sent (5.7), by name: an allow-list, so that an event added later reaches no phone until it is
 * named here. Never `computer`, `browser`, `auth`, `local`, `local.progress`, `local.running`, `mcp`, `devices` or
 * `remote` (the app's host roles, sign-ins, the Mac's upkeep, pairing and keys), nor `pictures`, `look` and
 * `priority`, settings a phone cannot change.
 */
export const TO_A_DEVICE: ReadonlySet<string> = new Set([
	"library",
	"agents",
	"inbox",
	"activity",
	"projects",
	"needs",
	"reports",
	"background",
	"schedules",
	"recovery",
	"usage",
	"providers",
	"conversation",
	"conversation.older",
	"chat",
	"compactionSettings",
	"agentDefault",
	"work",
	"wakes",
	"limits",
	"projectRules",
	"memory",
	"github",
	"coauthor",
	"branches",
	"awake",
	"device",
]);

/** When a line could not be made fit for a device, said in engine.log at most once a minute. */
let droppedSaid = 0;

/**
 * A line as a device may be sent it, or null for none (5.7). The line is read whole: an event on the list, or an answer
 * (`id` with `result` or `error`), and nothing else; endpoints by name only; then every string in it, the keys of its
 * objects too, masked of key shapes before it is written again, and what is nested too deep replaced by a marker
 * (devices.ts, `maskValue`), so that one deep call does not keep a whole list from the phone. Anything that still goes
 * wrong drops the line, but an answer, which is answered with an error, so that no request goes unanswered: a line is
 * never sent unmasked, and never throws into what wrote it.
 */
export function forDevice(line: string): string | null {
	try {
		const message: unknown = JSON.parse(line);
		if (typeof message !== "object" || message === null || Array.isArray(message)) return null;
		const fields = message as Record<string, unknown>;
		if (Object.hasOwn(fields, "event")) {
			if (typeof fields.event !== "string" || !TO_A_DEVICE.has(fields.event)) return null;
			if (fields.event === "providers") endpointsByName(fields);
		} else if (!Object.hasOwn(fields, "id") || !(Object.hasOwn(fields, "result") || Object.hasOwn(fields, "error"))) return null;
		return JSON.stringify(maskValue(fields));
	} catch (error) {
		const now = Date.now();
		if (now - droppedSaid > 60_000) {
			droppedSaid = now;
			log?.("remote: a line was not sent to a device, since it could not be made fit for one:", error instanceof Error ? error.message : error);
		}
		// Every answer starts with its id (`send` writes `{ id, … }`); a device's ids are its own numbers and strings.
		const id = /^\{"id":(-?\d{1,16}|"[A-Za-z0-9_.:-]{0,64}"|null)[,}]/.exec(line)?.[1];
		return id === undefined ? null : `{"id":${id},"error":${JSON.stringify(ANSWER_NOT_SENT)}}`;
	}
}

/** What a device is answered when the answer itself could not be made fit to send it. */
export const ANSWER_NOT_SENT = "The answer could not be sent to the phone. Look on the Mac.";

/** What a device is answered when its line failed in the engine, outside the request's own handling. */
export const DEVICE_LINE_FAILED = "The Mac could not take this request. Look on the Mac.";

/**
 * For a device's line that failed outside its request's own `try` (a fault of the engine's, never left to end it:
 * main.ts stops on an unhandled rejection): logged, and the line refused, as a request that failed is, with words of
 * its own rather than the fault's. The session stays open: the fault is the engine's, in this one request, and the
 * device is still the one that attached, so closing its session would only ask the person for Face ID again, for the
 * same request to fail again.
 */
function deviceLineFailed(id: string, message: unknown): (error: unknown) => void {
	return (error) => {
		log("remote: a device's request failed in the engine:", error instanceof Error ? (error.stack ?? error.message) : error);
		try {
			const given = typeof message === "object" && message !== null && !Array.isArray(message) ? (message as { id?: unknown }).id : undefined;
			const body = { id: given ?? null, error: DEVICE_LINE_FAILED };
			const session = sessions.get(id);
			if (session !== undefined) send(session.client, body);
			else {
				const out = forDevice(JSON.stringify(body));
				if (out !== null) write(helper, `{"session":${JSON.stringify(id)},"message":${out}}\n`);
			}
		} catch (again) {
			log("remote: and its refusal could not be sent:", again instanceof Error ? again.message : again);
		}
	};
}

/** Endpoints by name only: their addresses often carry a token typed outside the secret fields (5.7). */
function endpointsByName(message: Record<string, unknown>): void {
	const providers = Array.isArray(message.providers) ? (message.providers as { endpoint?: { id?: unknown; name?: unknown } | null; ask?: { can?: boolean; url?: unknown } | null }[]) : [];
	for (const provider of providers) {
		if (typeof provider !== "object" || provider === null) continue;
		if (provider.endpoint != null) provider.endpoint = { id: provider.endpoint.id, name: provider.endpoint.name };
		if (provider.ask?.can === true) provider.ask = { can: true, url: null };
	}
}

/** A device's line in a session: refused outside one, checked against its table, handled as from the app, logged. */
async function deviceLine(id: string, message: unknown): Promise<void> {
	const session = sessions.get(id);
	const request = (typeof message === "object" && message !== null && !Array.isArray(message) ? message : {}) as { id?: unknown; method?: unknown; params?: unknown };
	const reply = (body: Record<string, unknown>) => {
		if (session !== undefined) send(session.client, { id: request.id ?? null, ...body });
		else {
			const out = forDevice(JSON.stringify({ id: request.id ?? null, ...body }));
			if (out !== null) write(helper, `{"session":${JSON.stringify(id)},"message":${out}}\n`);
		}
	};
	const device = session === undefined ? undefined : pairedDevice(session.device);
	if (session === undefined || device === undefined || device.suspendedAt !== null) {
		reply({ error: OPEN_WITH_FACE_ID });
		if (session !== undefined) closeSession(id, "The device is no longer paired, or is suspended.");
		return;
	}
	const method = request.method;
	if (typeof method !== "string") {
		reply({ error: "A request must have a method name" });
		return;
	}
	const params = request.params ?? {};
	if (typeof params !== "object" || params === null || Array.isArray(params)) {
		reply({ error: "Request parameters must be an object" });
		return;
	}
	const gate = { path: session.path, approvalSwitch, approvalHidden };
	const answer = deviceMay(method, params as Params, gate);
	// The log's own names (a pairing, an offer of a Face ID key) are the engine's to write: a device's are "unknown" (#786).
	const summary = summarize(requestLogged(method), params as Params);
	if (DEVICE_FAULT !== undefined && method === DEVICE_FAULT) throw new Error("PI2_DEVICE_FAULT: the device's line");
	const record = (outcome: "done" | "refused" | "failed", why?: string) =>
		void logDevice({ device: device.id, path: session.path, method: requestLogged(method), summary, presence: true, outcome, ...(why === undefined ? {} : { why }) }).catch((error) =>
			log("devices: the log could not be written:", error instanceof Error ? error.message : error),
		);
	if (answer === "no" || !Object.hasOwn(handlers, method)) {
		const why = answer !== "no" ? `Unknown method: ${method}` : allowsHiddenApproval(method, params as Params, gate) ? HIDDEN_FROM_THE_PHONE : ONLY_ON_THE_MAC;
		reply({ error: why });
		record("refused", why);
		return;
	}
	const logged = deviceLogged(method, params as Params);
	// A request that widens is on disk before it is answered (4.4): the log keeps the rest in memory a moment.
	const widens = answer === "face";
	const writeLog = (outcome: "done" | "failed", why?: string) =>
		logDevice({ device: device.id, path: session.path, method, summary, presence: true, outcome, ...(why === undefined ? {} : { why }) }, widens).catch((error) =>
			log("devices: the log could not be written:", error instanceof Error ? error.message : error),
		);
	// Tell me when it answers (7): waited for from before the run the message starts, which may end before it is answered.
	const conversation = (params as Params).id;
	const tellMe = method === "submit" && (params as Params).tellWhenAnswered === true && typeof conversation === "number";
	if (tellMe) pushes?.answerWanted(device.id, conversation);
	try {
		const result = await handlers[method]!(params as Params, session.client);
		if (logged) await writeLog("done");
		reply({ result });
		if (widens) notify("widening", device.id, `${device.name}: ${summary}`);
	} catch (error) {
		const refused = refusal(error);
		if (tellMe) pushes?.answerNotWanted(device.id, conversation);
		if (logged) await writeLog("failed", refused.error);
		reply(refused);
		if (widens) notify("widening", device.id, `${device.name} tried: ${summary}`);
	}
}
