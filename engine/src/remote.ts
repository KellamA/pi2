// pi² Remote, as the engine starts it and hears it (docs/iphone.md 5.5, 4.1; #673): the engine's own child, trusted
// only on the socket pair the engine made for it (decision 24), and the device sessions it carries.
//
// The engine starts pi² Remote with its control connection as file descriptor 3: one end of a Unix socket pair, which
// libuv makes for a `pipe` in `spawn`'s stdio, as `pi2-peer` is given a connection. It starts one at a time, while the
// preview and remote access are on and a device is paired or a pairing is open, again if it dies (waiting twice as
// long after each failure, up to a minute, and a second again only after a run that lasted, `restartWait`), and stops
// it when they go off or the engine stops. It gives it nothing
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
// same when they change), `remote.pairClaim`, `remote.pairWrong` and `remote.pairRefused` (pairing, 3.3), `remote.pairUnkept`
// (a pairing pi² Remote could not keep, taken back, #887), `remote.attachBegin` and `remote.attach` (3.4: an attach or
// a resume, signed by the device key and the presence key; a refusal may carry a reason for the phone, #818), and
// `remote.sessionEnd` (the phone's session ended, 4.5), `remote.presenceKey` (a phone's offer of a new Face ID key, signed
// as an attach is, 3.2, #786), `remote.pushRefused` (the relay refused a push, pushes.ts), `remote.mailboxIn` (#678,
// P10: a request a phone left in the relay's mailbox, checked again with `checkRequestItem` in devices.ts and handled on
// the path `mailbox`), and `remote.left` (#929: a phone's leave the relay passed on, its notice checked again with
// `deviceLeft` in devices.ts, which revokes the device). `remote.state` also carries what pi² Remote can do with the relay (`relay`, 6.5), which the
// Devices page is told (`helper.relay`). The event's `mailboxOut` asks pi² Remote to leave a sealed item for a phone (a
// receipt, 5.3). Its `forgetPairing` (#917), after a `revoke` for every device, has it forget the pairing the person
// started again from (`devices.startAgain`), whose `relay.reason` said it belongs to another relay or to none.
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
import { allowsHiddenApproval, type DevicePath, deviceLogged, deviceMay, devicePlacement, forTheHelper, HIDDEN_FROM_THE_PHONE, ONLY_ON_THE_MAC, OPEN_WITH_FACE_ID, typedRefusal } from "./answers.ts";
import { isPicture } from "./attachments.ts";
import { type Client, clients, send, type Wire } from "./clients.ts";
import {
	checkRequestItem,
	ITEM_TAKEN_BEFORE,
	ItemNotYet,
	maskKeys,
	remoteOn,
	attachChallenge,
	attachHolds,
	attachTaken,
	checkAttach,
	type Device,
	deviceLeft,
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
	pairUnkept,
	pairWrong,
	UNKEPT_WITHIN,
	helperGone,
	activeDevices,
	remoteHooks,
	requestLogged,
	sessionsChanged,
	summarize,
	DEVICE_FAULT,
	DEVICE_FAULT_AFTER,
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

type Helper = {
	child: ChildProcess;
	wire: Socket;
	hello: { addresses: string[] } | null;
	stopping: boolean;
	relay: Record<string, unknown> | null;
	/** When it said hello: a run counts as one that lasted from then on (`restartWait`). */
	helloAt?: number;
	/** Stopped for a line over MAX_HELPER_LINE. */
	overCap?: boolean;
	/** The device of the last `paired` this helper was sent, and when: the one it may take back (`remote.pairUnkept`). */
	paired?: { device: string; at: number };
};
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
			return { running: helper !== null && helper.hello !== null, stoppedInLastHour: stops.length, relay: helper?.relay ?? null };
		},
		recordChanged: (device: string) => {
			const record = pairedDevice(device);
			if (record !== undefined) for (const session of sessions.values()) if (session.device === device) send(session.client, deviceEvent(record));
		},
		addresses: () => (helper?.hello == null ? null : helper.hello.addresses),
		relayWord,
		lastRelayWord: () => {
			const now = devicesState();
			return lastWord !== null && lastWord.relay.address === now.relay && lastWord.pairing === now.pairing ? lastWord.relay : null;
		},
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
/**
 * The longest line pi² Remote takes from a phone (#675, #904): ten pictures of 5 MiB in base64, as a message on the Mac
 * may carry, with the message's text. `Remote.phoneLineLimit` in pi² Remote, which pi2-remote-helper-check and the
 * devices test hold equal to this.
 */
export const MAX_PHONE_LINE = 72 * 1024 * 1024;
/**
 * The longest line taken from pi² Remote, in characters: a phone's line, at most MAX_PHONE_LINE bytes, so as many
 * characters or fewer, in its session's wrapping (`{"session":…,"message":…}`), with room to spare. pi² Remote's own
 * requests are far smaller.
 */
export const MAX_HELPER_LINE = MAX_PHONE_LINE + 64 * 1024;
/**
 * The longest line the engine writes pi² Remote, in UTF-8 bytes without its newline (#919): what pi² Remote takes from
 * the engine (`EngineLink.maxLineLength`, RemoteKit's `Lines.defaultMaxLength`), past which it stops as if the engine
 * had failed, and every phone's session with it. A session's line goes on to the phone without its wrapping, and a
 * phone takes as much (`Lines.defaultMaxLength` once attached), so a line that fits here fits there. A phone's own
 * line may be longer (MAX_PHONE_LINE), and a message's typed text comes back to it in the transcript: so every line is
 * held to this as it is written (`write`, `sessionLine`). pi2-remote-helper-check and the devices test hold it equal to
 * pi² Remote's.
 */
export const MAX_LINE_TO_HELPER = 64 * 1024 * 1024;

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
	const current: Helper = { child, wire, hello: null, stopping: false, relay: null };
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
					current.overCap = true;
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
	const { wait, next } = restartWait(restartDelay, current);
	restartDelay = next;
	log(`remote: pi² Remote will be started again in ${wait / 1000} s`);
	restartTimer = setTimeout(() => {
		restartTimer = undefined;
		reconsider();
	}, wait);
	restartTimer.unref();
}

/** A run of pi² Remote that lasted: this long from its hello, and not stopped for a line over the cap. */
export const RUN_THAT_LASTED = 60_000;

/**
 * How long to wait before starting pi² Remote again after it stopped by itself (`wait`), given the wait due (`delay`),
 * and the wait due after that (`next`): twice as long after each stop, up to a minute, and back to a second only after
 * a run that lasted (#881). A stop for a line over MAX_HELPER_LINE never counts as one, whatever its length, and nor does
 * a hello: a pi² Remote that kept passing on such a line would otherwise be started again every few seconds, ending
 * every phone's session each time.
 */
export function restartWait(delay: number, run: { helloAt?: number; overCap?: boolean }, now = Date.now()): { wait: number; next: number } {
	const lasted = run.overCap !== true && run.helloAt !== undefined && now - run.helloAt >= RUN_THAT_LASTED;
	const wait = lasted ? 1_000 : delay;
	return { wait, next: Math.min(wait * 2, 60_000) };
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

/** Whether `line` (without its newline) is longer than pi² Remote takes; counted in bytes only when it could be. */
const overHelperLimit = (line: string): boolean => line.length * 3 > MAX_LINE_TO_HELPER && Buffer.byteLength(line) > MAX_LINE_TO_HELPER;

/** When a line too long for pi² Remote was last said in engine.log: at most once a minute, by kind and size alone. */
let tooLongSaid = 0;
function sayTooLong(what: string, line: string): void {
	const now = Date.now();
	if (now - tooLongSaid < 60_000) return;
	tooLongSaid = now;
	log?.(`remote: ${what} of ${Buffer.byteLength(line)} bytes was not written to pi² Remote, which takes lines of at most ${MAX_LINE_TO_HELPER} (said at most once a minute)`);
}

/**
 * Every line to pi² Remote is written here: a session's (`sessionLine`, which turns an answer too long into a refusal
 * first), the `remote` event (`toHelper`) and the answers to its own requests (`helperRequest`). One longer than it
 * takes is not written, so that no line of the engine's stops it.
 */
function write(current: Helper | null, message: string): void {
	if (current === null || current.wire.destroyed) return;
	const line = message.endsWith("\n") ? message.slice(0, -1) : message;
	if (overHelperLimit(line)) return sayTooLong("a line", line);
	current.wire.write(message);
}

/**
 * A line `forDevice` made for session `id`, in the session's wrapping, as written to pi² Remote; or null for none. A line
 * longer than pi² Remote takes (MAX_LINE_TO_HELPER, the wrapping counted) is never written: an answer becomes
 * ANSWER_NOT_SENT, as one that could not be made fit for a device does, so that no request goes unanswered; an event
 * is dropped. Either is said in engine.log, by kind and size, never what it held.
 */
export function sessionLine(id: string, out: string): string | null {
	const line = `{"session":${JSON.stringify(id)},"message":${out}}`;
	if (!overHelperLimit(line)) return `${line}\n`;
	const event = /^\{"event":"([A-Za-z0-9_.]{1,64})"/.exec(out)?.[1];
	// As forDevice reads an answer's id: every answer starts with it.
	const answer = event === undefined ? /^\{"id":(-?\d{1,16}|"[A-Za-z0-9_.:-]{0,64}"|null)[,}]/.exec(out)?.[1] : undefined;
	sayTooLong(event !== undefined ? `a device's ${event} event` : answer !== undefined ? "an answer to a device" : "a device's line", line);
	return answer === undefined ? null : `{"session":${JSON.stringify(id)},"message":{"id":${answer},"error":${JSON.stringify(ANSWER_NOT_SENT)}}}\n`;
}

/** A line for session `id`, as `forDevice` made it, to pi² Remote. */
function toSession(id: string, out: string): void {
	const line = sessionLine(id, out);
	if (line !== null) write(helper, line);
}

/** A `remote` event, to pi² Remote alone. A `paired` is the one pairing that helper may take back (`remote.pairUnkept`). */
function toHelper(event: Record<string, unknown>): void {
	if (event.kind === "paired" && helper !== null) helper.paired = { device: (event.device as { id: string }).id, at: Date.now() };
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
		// Not the restart's wait: that goes back to a second only after a run that lasted (`restartWait`).
		current.helloAt ??= Date.now();
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
		if (params.relay !== undefined) {
			const relay = relayState(params.relay);
			if (relay === null) throw new Error("The relay's state is not one pi² Remote reports.");
			current.relay = relay;
			lastWord = { relay, pairing: devicesState().pairing };
			sessionsChanged();
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
	// Only the device of the last `paired` this very helper was sent, within a minute, once (#887); devices.ts checks
	// the record again (`pairUnkept`).
	"remote.pairUnkept": async (current, params) => {
		const paired = current.paired;
		if (Object.keys(params).some((key) => key !== "device") || typeof params.device !== "string" || paired === undefined || paired.device !== params.device || Date.now() - paired.at >= UNKEPT_WITHIN) {
			throw new Error("pi² Remote may take back only the device it was last sent paired for, within a minute.");
		}
		current.paired = undefined;
		await pairUnkept(params.device);
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
	"remote.mailboxIn": async (current, params) => mailboxIn(current, params),
	/** `{ id, why }`: the relay refused the push `id` (docs/iphone.md 7); pushes.ts holds back what the refusal says. */
	"remote.pushRefused": async (_current, params) => {
		if (typeof params.id !== "string" || typeof params.why !== "string" || Object.keys(params).length !== 2) throw new Error("remote.pushRefused takes a push's id and why");
		if (pushes?.refused(params.id, params.why) !== true) log("remote: pi² Remote answered for a push the engine does not know, or no longer remembers");
		return {};
	},
	/**
	 * `{ device, at, notice }`: a phone's leave the relay passed on, which pi² Remote verified (3.6, #929). devices.ts
	 * checks the notice again against the device key in its own record: what pi² Remote says alone revokes nothing.
	 */
	"remote.left": async (_current, params) => deviceLeft(params),
};

/** What pi² Remote may say of the relay path (6.5): none wanted, why it cannot run, or how it runs. */
const RELAY_STATES = ["off", "unavailable", "connecting", "ready", "down", "stopped"];
/**
 * Why it cannot run, as a fixed word beside the sentence (#917), which the Devices page acts on and the sentence never:
 * the relay's address, its key, no pairing yet, a pairing registered at no relay or at another, its client, registering.
 */
const RELAY_REASONS = ["address", "key", "no-pairing", "unregistered", "another-relay", "client", "register-failed"];

/** `remote.state`'s `relay` as the Devices page is told it, or null for one pi² Remote does not send. */
function relayState(value: unknown): Record<string, unknown> | null {
	if (typeof value !== "object" || value === null || Array.isArray(value)) return null;
	const given = value as Record<string, unknown>;
	if (Object.keys(given).some((key) => !["available", "state", "why", "reason", "retryAt", "anotherMacAt", "registered", "address"].includes(key))) return null;
	if (given.registered !== undefined && !["here", "another-relay", "none"].includes(given.registered as string)) return null;
	if (given.address !== undefined && (typeof given.address !== "string" || given.address.length > 2048)) return null;
	if (typeof given.available !== "boolean") return null;
	if (given.state !== undefined && !RELAY_STATES.includes(given.state as string)) return null;
	if (given.reason !== undefined && (given.state !== "unavailable" || !RELAY_REASONS.includes(given.reason as string))) return null;
	if (given.why !== undefined && typeof given.why !== "string") return null;
	for (const time of [given.retryAt, given.anotherMacAt]) if (time !== undefined && !Number.isSafeInteger(time)) return null;
	return {
		available: given.available,
		state: given.state ?? (given.available ? "ready" : "unavailable"),
		...(given.why === undefined ? {} : { why: maskKeys((given.why as string).slice(0, 500)) }),
		...(given.reason === undefined ? {} : { reason: given.reason }),
		...(given.retryAt === undefined ? {} : { retryAt: given.retryAt }),
		...(given.anotherMacAt === undefined ? {} : { anotherMacAt: given.anotherMacAt }),
		...(given.registered === undefined ? {} : { registered: given.registered }),
		...(given.address === undefined ? {} : { address: given.address }),
	};
}

/**
 * pi² Remote's last word of the relay path, with the pairing the engine had when it came (#917, #1013): kept when pi²
 * Remote stops, as it does with no device paired, so that the Devices page goes on offering to start again. It holds
 * only while the address and the pairing are those now set: `registered` changes only with the pairing (register,
 * forgetPairing) or the address, and both pass through the engine.
 */
let lastWord: { relay: Record<string, unknown>; pairing: string | null } | null = null;

/**
 * What pi² Remote last said of the relay path, once it is about the relay's address now set (`address`, #1013), from a
 * pi² Remote that said hello; null if none says it within `within` ms. It says it after every hello, and again whenever
 * the address or where the pairing is registered changes, so a word about another address is one still on its way.
 */
function relayWord(within: number): Promise<Record<string, unknown> | null> {
	const deadline = Date.now() + within;
	return new Promise((resolve) => {
		const look = () => {
			const relay = helper?.hello != null ? helper.relay : null;
			if (relay !== null && relay.address === devicesState().relay) return resolve(relay);
			if (Date.now() >= deadline) return resolve(null);
			setTimeout(look, 50).unref();
		};
		look();
	});
}

// ---- The mailbox (5.3, 4.3; #678, #806)

/**
 * A request a phone left in the relay's mailbox, which pi² Remote took, opened and verified with the device's keys on
 * its own list: checked again here (`checkRequestItem`: the device key's signature first, then the presence key's, the
 * pairing, its row's mailbox column, its age and its nonce, stored once) and handled as from the device, on the path
 * `mailbox`, in a connection of its own that lasts the one request, by `deviceRequest`, as a live session's request is
 * (logged, on disk first and the person notified when it widens). Answered `{ taken: true }` once it was handled or
 * refused for good, and only then does pi² Remote tell the relay `took` (#806); an error is what could pass later
 * (remote access off, the device suspended, the nonce not stored), and the relay hands the item over again until it
 * expires. The phone is left a receipt either way (5.3), but for an item taken before, which had one.
 */
async function mailboxIn(current: Helper, params: Params): Promise<{ taken: true; outcome: "done" | "failed" | "refused" }> {
	if (current.hello === null) throw new Error("pi² Remote has not said hello.");
	if (Object.keys(params).some((key) => !["device", "id", "item"].includes(key)) || typeof params.device !== "string" || fromBase64url(params.id, 16) === null) {
		throw new Error("remote.mailboxIn takes a device, an item's id and the item.");
	}
	const device = params.device;
	const id = params.id as string;
	if (!remoteOn()) throw new Error("Reach from an iPhone is off on this Mac.");
	const record = pairedDevice(device);
	if (record !== undefined && record.suspendedAt !== null) throw new Error("This device is suspended. Resume it on the Mac's Devices page.");
	const item = params.item as { request?: { method?: unknown }; signed?: unknown } | undefined;
	const named = typeof item?.request?.method === "string" ? item.request.method.slice(0, 128) : null;
	let checked: Awaited<ReturnType<typeof checkRequestItem>>;
	try {
		checked = await checkRequestItem(device, params.item, { approvalSwitch, approvalHidden });
		// pi² Remote opened it at this id, which HPKE's info binds; its signed nonce must be the same.
		if ((JSON.parse(item!.signed as string) as { nonce?: unknown }).nonce !== id) throw new Error("The item's nonce is not its id.");
	} catch (error) {
		if (error instanceof ItemNotYet) throw error;
		const why = error instanceof Error ? error.message : String(error);
		if (record !== undefined && why !== ITEM_TAKEN_BEFORE) receipt(device, id, named, "refused", why);
		return { taken: true, outcome: "refused" };
	}
	const { method, params: given } = checked;
	const client: Client = { socket: { destroyed: false, write: () => true, destroy: () => {} }, subscriptions: new Map(), shown: new Set(), device: { id: device, session: "mailbox" } };
	let outcome: "done" | "failed" | "refused";
	let why: string | undefined;
	try {
		// What a live session's request does, the same function: its table on the path, the log (on disk first when it
		// widens), and the person notified of a widening request (4.4).
		outcome = await deviceRequest(pairedDevice(device)!, "mailbox", client, method, given, (body) => {
			why = typeof body.error === "string" ? body.error : undefined;
		});
	} catch (error) {
		// A fault of the engine's, as a live session's line has it (deviceLineFailed): said in engine.log throttled, kept in the
		// devices' log as a failed request in fixed words, and the item refused in fixed words. Its nonce is stored, so it is
		// taken: handed over again it would only be refused as taken before.
		const said = sayFault(device, "mailbox", method, false, error);
		if (said !== null) log(said.text, said.detail);
		requestFaulted(device, "mailbox", method, given);
		outcome = "failed";
		why = DEVICE_LINE_FAILED;
	} finally {
		drop(client);
	}
	receipt(device, id, method, outcome, why);
	return { taken: true, outcome };
}

/** A receipt for the phone (5.3): what became of the item it left, which pi² Remote seals for it and puts in its mailbox. */
function receipt(device: string, nonce: string, method: string | null, outcome: "done" | "failed" | "refused", why?: string): void {
	const body = { nonce, method, outcome, ...(why === undefined ? {} : { why: maskKeys(why.slice(0, 500)) }) };
	toHelper({ kind: "mailboxOut", device, item: { kind: "receipt", body } });
}

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
				if (out !== null) toSession(session.id, out);
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
 * objects too, masked of key shapes and of the values of the secrets the engine knows (secrets.ts) before it is
 * written again, and what is nested too deep replaced by a marker (devices.ts, `maskValue`), so that one deep call
 * does not keep a whole list from the phone. Anything that still goes wrong drops the line, but an answer, which is
 * answered with an error, so that no request goes unanswered: a line is
 * never sent unmasked, and never throws into what wrote it. It leaves nothing out by a field's name: the one answer
 * whose picture bytes go unmasked is put together by `deviceRequest` (PICTURE_ANSWERS).
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

/** How long a device's fault lines, and engine.log's ceiling, are counted over: a minute. */
const FAULT_SAID_MS = 60_000;

/**
 * The most devices `faultsSaid` keeps an entry for. An entry is never dropped while its minute lasts: dropped, its
 * next fault would be counted from nothing and said as its first again, with its stack, which is the bound the table
 * keeps. When the table is full, only an entry whose minute is over is forgotten; with none of those, a new device's
 * faults are counted in one shared entry (`otherFaults`), so a Mac's few devices bound the table, not a phone's choice.
 */
const MAX_FAULTS_SAID = 64;

/**
 * The most fault lines engine.log takes in a minute, all devices together, the line saying how many were not said among
 * them. Past it a fault is only counted. engine.log is never rotated, so this is what bounds an hour of faults.
 */
const MAX_FAULT_LINES = 30;

/** The most names of placed methods (`devicePlacement`) a counted fault's line says, each a fixed name from a list. */
const MAX_FAULT_METHODS = 3;

/**
 * The most characters of a fault's own words (its stack, or the message when there is none) that one line is said with:
 * a fault can carry a deep stack, or an error whose message a phone chose, and engine.log is never rotated. The line's
 * fixed words come on top of it.
 */
export const MAX_FAULT_DETAIL = 4096;

/**
 * What is said of faults while a minute lasts, by the device's id alone: when its last line was said (`at`), how many
 * of its faults came since (`more`), and up to `MAX_FAULT_METHODS` names of the methods they were for, each a name
 * only a list places (answers.ts), never a device's text. A device choosing paths, methods and after-or-failed reaches
 * one entry, not the 1,448 keys those four would give it: its first fault in a minute is said with its stack, every
 * further fault of it in that minute, whatever its path and method, is only counted, and one line when the minute is
 * over and more came says how many. So at most two lines for a device in a minute.
 */
type FaultSaid = { at: number; more: number; methods: string[]; shared: boolean };

const faultsSaid = new Map<string, FaultSaid>();

/** What faults of a device past the table's bound are counted in: said at most once a minute, and never with a stack. */
const otherFaults: FaultSaid = { at: 0, more: 0, methods: [], shared: true };

/** The ceiling's minute: when it began, the lines said in it, and the faults it kept from being said. */
let linesAt = 0;
let linesSaid = 0;
let linesNotSaid = 0;

/** The one line owed for the faults the last minute's ceiling kept from being said, said at the first fault after it. */
let linesNotSaidLine: string | null = null;

/**
 * The window a device's faults are counted in, made if it has none, or the shared one when the table is full of devices
 * inside their minutes. `fresh` says the entry was just made, so the fault is its first.
 */
function faultWindow(device: string, now: number): { entry: FaultSaid; fresh: boolean } {
	const known = faultsSaid.get(device);
	if (known !== undefined) return { entry: known, fresh: false };
	if (faultsSaid.size >= MAX_FAULTS_SAID) {
		for (const [id, one] of faultsSaid) {
			// Only one whose minute is over: one inside it keeps its count, and its next fault said as its first again.
			if (now - one.at >= FAULT_SAID_MS) {
				faultsSaid.delete(id);
				break;
			}
		}
	}
	if (faultsSaid.size < MAX_FAULTS_SAID) {
		const entry: FaultSaid = { at: now, more: 0, methods: [], shared: false };
		faultsSaid.set(device, entry);
		return { entry, fresh: true };
	}
	return { entry: otherFaults, fresh: false };
}

/**
 * What engine.log should say of a fault of a device's request, or null while nothing more is to be said: the first
 * fault of a device in a minute with its stack, and one line when the minute is over and more came, saying how many and
 * naming at most three placed methods. At most `MAX_FAULT_LINES` lines a minute, all devices together, and at most
 * `MAX_FAULT_DETAIL` characters of the fault's own words with the first line, never the request's: a fault can repeat
 * what the phone sent. `_path` is no longer read: the count is the device's alone, and a test walks the four paths to
 * show they change nothing.
 */
export function sayFault(device: string, _path: DevicePath, method: string, after: boolean, error: unknown, now = Date.now()): { text: string; detail: unknown } | null {
	const what = after ? "remote: a device's request was answered, and a fault came after the answer" : "remote: a device's request failed in the engine";
	const detail = error instanceof Error ? (error.stack ?? error.message).slice(0, MAX_FAULT_DETAIL) : error;
	const named = devicePlacement(method) === null ? null : method;
	const { entry, fresh } = faultWindow(device, now);
	let line: { text: string; detail: unknown } | null;
	if (fresh) line = { text: `${what}:`, detail };
	else if (now - entry.at >= FAULT_SAID_MS) {
		const counted = entry.more;
		const names = entry.methods.splice(0);
		entry.at = now;
		entry.more = 0;
		// The shared entry is never given a stack: it is no one device's first fault, and a stack says which code failed.
		// Which entry it is, both its lines say, so that neither can be read as a device's first fault either.
		const which = entry.shared ? " (a device past the table's bound)" : "";
		if (counted === 0) line = { text: `${what}${which}${entry.shared ? "" : " again"}:`, detail: entry.shared ? undefined : detail };
		else line = { text: `${what} again${which}, and ${counted} more since the last one said${names.length > 0 ? ` (${names.join(", ")})` : ""}:`, detail: undefined };
	} else {
		entry.more += 1;
		if (named !== null && entry.methods.length < MAX_FAULT_METHODS && !entry.methods.includes(named)) entry.methods.push(named);
		line = null;
	}
	// The ceiling's minute, and the one line it owes the faults it kept from being said.
	if (now - linesAt >= FAULT_SAID_MS) {
		const kept = linesNotSaid;
		linesAt = now;
		linesSaid = 0;
		linesNotSaid = 0;
		if (kept > 0) linesNotSaidLine = `remote: ${kept} faults of devices' requests were not said in engine.log in the last minute:`;
	}
	if (line !== null) {
		if (linesSaid < MAX_FAULT_LINES) {
			linesSaid += 1;
			return line;
		}
		linesNotSaid += 1;
	}
	if (linesNotSaidLine !== null && linesSaid < MAX_FAULT_LINES) {
		const owed = linesNotSaidLine;
		linesNotSaidLine = null;
		linesSaid += 1;
		return { text: owed, detail: undefined };
	}
	return null;
}

/**
 * A fault of the engine's after the answer for a request went out: one answer per id, so nothing more is sent for it,
 * and the fault is said in engine.log as what it is rather than as the request failing (#905).
 */
function faultAfterAnswer(device: string, path: DevicePath, method: string, error: unknown): void {
	const said = sayFault(device, path, method, true, error);
	if (said !== null) log(said.text, said.detail);
}

/**
 * A fault of the engine's before the answer for a request: said in engine.log as `sayFault` says it, and kept in the
 * devices' log where the person looks, as a failed request of that device in fixed words (DEVICE_LINE_FAILED), never
 * the fault's text or the request's values: the summary is the request's own, cleaned and masked as a refused one's.
 */
function requestFaulted(device: string, path: DevicePath, method: string, params: unknown): void {
	const given = (typeof params === "object" && params !== null && !Array.isArray(params) ? params : {}) as Params;
	const named = requestLogged(method);
	// A request refused for its text is summarized by its method alone: a summary reads the title, path or folder it names.
	const summary = typedRefusal(method, given) === null ? summarize(named, given) : `${named}: refused for the text it carries`;
	void logDevice({ device, path, method: named, summary, presence: true, outcome: "failed", why: DEVICE_LINE_FAILED }).catch((error) =>
		log("devices: the log could not be written:", error instanceof Error ? error.message : error),
	);
}

/**
 * For a device's line that failed outside its request's own `try` (a fault of the engine's, never left to end it:
 * main.ts stops on an unhandled rejection): the fault said in engine.log at most twice a minute for the device, with
 * its stack only for its first (`sayFault`), the request kept in the devices' log as failed in fixed words
 * (`requestFaulted`), and the line refused as a request that failed is, with words of its own rather than the fault's.
 * The session stays open: the fault is the engine's, in this one request, and the device is still the one that
 * attached, so closing its session would only ask the person for Face ID again, for the same request to fail again.
 */
function deviceLineFailed(id: string, message: unknown): (error: unknown) => void {
	return (error) => {
		const session = sessions.get(id);
		const request = (typeof message === "object" && message !== null && !Array.isArray(message) ? message : {}) as { id?: unknown; method?: unknown; params?: unknown };
		const method = typeof request.method === "string" ? request.method : "";
		const said = sayFault(session?.device ?? "unknown", session?.path ?? "relay", method, false, error);
		if (said !== null) log(said.text, said.detail);
		if (session !== undefined) requestFaulted(session.device, session.path, method, request.params);
		try {
			const given = typeof message === "object" && message !== null && !Array.isArray(message) ? (message as { id?: unknown }).id : undefined;
			const body = { id: deviceId(given) ? (given ?? null) : null, error: DEVICE_LINE_FAILED };
			if (session !== undefined) send(session.client, body);
			else {
				const out = forDevice(JSON.stringify(body));
				if (out !== null) toSession(id, out);
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

/**
 * A device's request id: a whole number, a text of at most MAX_DEVICE_ID characters, or none. The phone numbers its
 * requests (`ChannelTransport`); a test's are short words.
 */
const MAX_DEVICE_ID = 64;
const deviceId = (id: unknown) => id === undefined || id === null || Number.isSafeInteger(id) || (typeof id === "string" && id.length <= MAX_DEVICE_ID);

/** What a device is answered for a request whose id is none of those. */
export const NOT_AN_ID = "A request from a phone must have a whole number or a text of at most 64 characters as its id.";

/** A device's line in a session: refused outside one, checked against its table, handled as from the app, logged. */
async function deviceLine(id: string, message: unknown): Promise<void> {
	const session = sessions.get(id);
	const request = (typeof message === "object" && message !== null && !Array.isArray(message) ? message : {}) as { id?: unknown; method?: unknown; params?: unknown };
	// An id is answered back with every reply, masked and written each time: one of tens of megabytes, a list or an
	// object is refused before anything else is done with the line, answered with none, and logged nowhere (#997).
	const idTaken = deviceId(request.id);
	const answeredId = idTaken ? (request.id ?? null) : null;
	const reply = (body: Record<string, unknown>, picture?: string) => {
		if (session !== undefined && picture === undefined) send(session.client, { id: answeredId, ...body });
		else if (session?.closed !== true) {
			const out = forDevice(JSON.stringify({ id: answeredId, ...body }));
			if (out !== null) toSession(id, picture === undefined ? out : withPicture(out, picture));
		}
	};
	if (!idTaken) {
		reply({ error: NOT_AN_ID });
		return;
	}
	const device = session === undefined ? undefined : pairedDevice(session.device);
	if (session === undefined || device === undefined || device.suspendedAt !== null) {
		reply({ error: OPEN_WITH_FACE_ID });
		// The answer has gone out: a fault in closing the session sends nothing more for the id, and is said as what it is
		// rather than as the request failing (#905).
		if (session !== undefined) {
			try {
				closeSession(id, "The device is no longer paired, or is suspended.");
			} catch (error) {
				faultAfterAnswer(session.device, session.path, typeof request.method === "string" ? request.method : "", error);
			}
		}
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
	await deviceRequest(device, session.path, session.client, method, params as Params, reply);
}

/**
 * The answers whose picture bytes a device is sent as they are, unmasked and unsearched (#956), by the request that
 * fills them, never by a field's name or by how a string looks: `conversation.image`'s `data`, which the engine takes
 * from the entry's own image block (`imagesOf`, transcript.ts) and sends only once `isPicture` (attachments.ts) finds
 * it base64 of a picture of its `mimeType`, one of PICTURE_TYPES. Masking would break the picture (a run of base64
 * can look like a key) and would hide nothing a person reads: a picture shows a key as pixels, if it shows one, and no
 * mask ever looked at those. And `presented.picture`'s (#946, presented.ts), `{ mimeType, data }` too: a presented
 * PNG, JPEG, GIF or WebP, or a page's PNG snapshot, read from the copy the engine kept and checked by its first bytes;
 * an SVG item is refused to a device before any answer, and its type is not in PICTURE_TYPES either.
 */
export const PICTURE_ANSWERS: ReadonlySet<string> = new Set(["conversation.image", "presented.picture"]);

/**
 * The picture types whose bytes go to a device unmasked, fixed here on the owner's path: a type that attachments.ts
 * takes later (one that is text, such as SVG) reaches the exemption only by a change to this list.
 */
export const PICTURE_TYPES: ReadonlySet<string> = new Set(["image/png", "image/jpeg", "image/gif", "image/webp"]);

/** `result` as `conversation.image` answers it, `{ data, mimeType }` and nothing else, with bytes of a picture of that type; else undefined. */
export function pictureAnswer(result: unknown): { data: string; mimeType: string } | undefined {
	if (typeof result !== "object" || result === null || Array.isArray(result)) return undefined;
	const fields = result as Record<string, unknown>;
	const keys = Object.keys(fields).sort();
	if (keys.length !== 2 || keys[0] !== "data" || keys[1] !== "mimeType") return undefined;
	if (typeof fields.mimeType !== "string" || !PICTURE_TYPES.has(fields.mimeType) || !isPicture(fields.mimeType, fields.data)) return undefined;
	return { data: fields.data as string, mimeType: fields.mimeType as string };
}

/** A masked answer `out` with the picture's bytes put back as its `data`; an answer turned into a refusal stays one. */
function withPicture(out: string, data: string): string {
	const answer = JSON.parse(out) as { result?: unknown };
	if (typeof answer.result !== "object" || answer.result === null) return out;
	return JSON.stringify({ ...answer, result: { ...answer.result, data } });
}

/**
 * A device's request once the device is known, on either path: a live session's line (`deviceLine`) or an item from the
 * mailbox that `checkRequestItem` passed (`mailboxIn`). Checked against the device's table on its path, handled as from
 * the app, logged under the log's own rule for a device's names (#786), on disk before it is answered when it widens
 * (4.4), and the person notified of a widening request, done or tried (4.2, 4.4, 4.5). Both paths call this, so that no
 * duty is kept on one alone (#921's security read). `reply` is given the result or the refusal; the outcome is
 * returned. One answer per id (#905): a fault in a step after the answer sends nothing more, and the devices' log keeps
 * the request as done. What throws here before the answer (a fault of the engine's) is the caller's to catch, with
 * `DEVICE_LINE_FAILED`'s words.
 */
async function deviceRequest(device: Device, path: DevicePath, client: Client, method: string, params: Params, reply: (body: Record<string, unknown>, picture?: string) => void): Promise<"done" | "failed" | "refused"> {
	// One answer per request id (#905): once the reply has gone out, a fault in a step after it sends nothing more.
	let answered = false;
	const answerOnce = (body: Record<string, unknown>, picture?: string) => {
		reply(body, picture);
		answered = true;
	};
	// A typed text over 1 MB first (#924), and any other text over its bound (#940), measured in place: nothing below
	// reads or copies it before it is refused.
	const tooLong = typedRefusal(method, params as Params);
	const gate = { path, approvalSwitch, approvalHidden };
	const answer = tooLong === null ? deviceMay(method, params as Params, gate) : "no";
	// The log's own names (a pairing, an offer of a Face ID key) are the engine's to write: a device's are "unknown" (#786).
	// A request refused for its text is summarized by its method alone: a summary reads the title, path or folder it
	// names, which would clean and mask the whole of what was refused (#940's security read).
	const summary = tooLong === null ? summarize(requestLogged(method), params as Params) : `${requestLogged(method)}: refused for the text it carries`;
	const record = (outcome: "done" | "refused" | "failed", why?: string) =>
		void logDevice({ device: device.id, path, method: requestLogged(method), summary, presence: true, outcome, ...(why === undefined ? {} : { why }) }).catch((error) =>
			log("devices: the log could not be written:", error instanceof Error ? error.message : error),
		);
	if (tooLong !== null) {
		answerOnce({ error: tooLong });
		record("refused", tooLong);
		return "refused";
	}
	if (DEVICE_FAULT !== undefined && method === DEVICE_FAULT) throw new Error("PI2_DEVICE_FAULT: the device's line");
	if (answer === "no" || !Object.hasOwn(handlers, method)) {
		const why = answer !== "no" ? `Unknown method: ${method}` : allowsHiddenApproval(method, params as Params, gate) ? HIDDEN_FROM_THE_PHONE : ONLY_ON_THE_MAC;
		answerOnce({ error: why });
		record("refused", why);
		return "refused";
	}
	const logged = deviceLogged(method, params as Params);
	// A request that widens is on disk before it is answered (4.4): the log keeps the rest in memory a moment.
	const widens = answer === "face";
	const writeLog = (outcome: "done" | "failed", why?: string) =>
		logDevice({ device: device.id, path, method, summary, presence: true, outcome, ...(why === undefined ? {} : { why }) }, widens).catch((error) =>
			log("devices: the log could not be written:", error instanceof Error ? error.message : error),
		);
	// Tell me when it answers (7): waited for from before the run the message starts, which may end before it is answered.
	const conversation = (params as Params).id;
	const tellMe = method === "submit" && (params as Params).tellWhenAnswered === true && typeof conversation === "number";
	if (tellMe) pushes?.answerWanted(device.id, conversation);
	try {
		const result = await handlers[method]!(params as Params, client);
		if (logged) await writeLog("done");
		// The rest of the answer is masked as any is; only the bytes the picture check took are left as they are.
		const picture = PICTURE_ANSWERS.has(method) ? pictureAnswer(result) : undefined;
		if (picture === undefined) answerOnce({ result });
		else answerOnce({ result: { mimeType: picture.mimeType } }, picture.data);
		if (widens) notify("widening", device.id, `${device.name}: ${summary}`);
		// A fault in a step after the answer, for a test (#905): `PI2_DEVICE_FAULT_AFTER`'s method, asked with the id
		// "after-answer", throws here so that engine/test/devices.ts meets the one-answer-per-id rule. A development
		// engine only; a release one ignores it.
		if (DEVICE_FAULT_AFTER !== undefined && method === DEVICE_FAULT_AFTER && (params as Params).id === "after-answer") throw new Error("PI2_DEVICE_FAULT_AFTER: after the answer");
		return "done";
	} catch (error) {
		// The answer for this id has gone out, so a fault in a step after it sends nothing more, and the request is not
		// logged as failed: it ran. The fault is said as what it is, after the answer (#905).
		if (answered) {
			faultAfterAnswer(device.id, path, method, error);
			return "done";
		}
		const refused = refusal(error);
		if (tellMe) pushes?.answerNotWanted(device.id, conversation);
		if (logged) await writeLog("failed", refused.error);
		answerOnce(refused);
		if (widens) {
			try {
				notify("widening", device.id, `${device.name} tried: ${summary}`);
			} catch (again) {
				// The refusal has gone out: a fault in the notice after it sends nothing more, and is said after the answer.
				faultAfterAnswer(device.id, path, method, again);
			}
		}
		return "failed";
	}
}
