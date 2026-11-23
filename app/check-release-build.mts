// Starts the engine packaged inside a release build of pi², as the app would, and checks that it answers as the build
// it came with. The release workflow runs it on the update archive and the disk image before it drafts a release, and
// CI runs it on every change, on a release build made without signing, so the check is known to work on GitHub's macOS
// before a release depends on it (issue #115). See docs/releasing.md.
//
//   node app/check-release-build.mts <pi².app | pi2-<version>.zip | pi2-<version>.dmg> [options]
//
//   --version V        the version the build must be (CFBundleShortVersionString); defaults to app/VERSION
//   --build-number N   the build number it must have (CFBundleVersion); any, if not given
//   --commit SHA       the commit it must have been built from; any, if not given
//   --bundle-id ID     the bundle id it must have; defaults to dev.pi2.app, which installed copies update to
//   --open-app         also open the app itself, on a data folder of its own, and check that it starts the engine inside
//                      it, as a process macOS holds responsible for itself rather than the app, and connects to it. For a Mac nobody uses, such as a CI runner: an app with pi²'s own bundle
//                      id shares its preferences and permissions with an installed copy, so this is refused for
//                      dev.pi2.app outside CI. Give a copy its own bundle id to try it elsewhere (CONTRIBUTING.md).
//
// Whatever it starts runs on a temporary data folder, with a Keychain service of its own, without asking a login shell
// for its PATH, and is stopped by its process id before it ends, whether the checks passed or not.

import { type ChildProcess, execFileSync, spawn, spawnSync } from "node:child_process";
import { closeSync, existsSync, lstatSync, mkdtempSync, openSync, readdirSync, readFileSync, readlinkSync, realpathSync, rmSync, statSync, writeFileSync } from "node:fs";
import { connect, type Socket } from "node:net";
import { homedir } from "node:os";
import { basename, join, resolve } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";
import { parseArgs } from "node:util";

/** How long the engine may take to listen, and the app to start it: far more than either takes, so only a hang fails. */
const START_MS = 5 * 60_000;
/** How long the demo model may take to answer, and the engine to stop. */
const ANSWER_MS = 2 * 60_000;
const STOP_MS = 2 * 60_000;
const BUNDLE_ID = "dev.pi2.app";
const inCI = process.env.CI === "true" || process.env.GITHUB_ACTIONS === "true";
/**
 * The variables only a development build reads (docs/development.md). A release build leaves out the code that reads
 * them at compile time (`PI2_DEVELOPMENT`), so its executable does not name them at all; one that does was built with
 * a development affordance outside that condition, which anyone could switch on.
 */
const DEVELOPMENT_ONLY = ["PI2_SHOW", "PI2_HUB", "PI2_MENU", "PI2_TEST_COPY", "PI2_WINDOW_BEHIND", "PI2_WINDOW_ORIGIN", "PI2_DRAW_WHEN_HIDDEN"];

/**
 * pi² Remote's bundle id, whatever the app's (a copy given its own keeps the helper's), and the entitlements its release
 * build may have: none until its Keychain access group comes with its provisioning profile (P14, #686), which adds it
 * here and in app/remote-helper.sh. Above all none that lets a program load a library into it
 * (`com.apple.security.cs.allow-dyld-environment-variables`, `disable-library-validation`) or attach to it
 * (`get-task-allow`): it holds the Mac's keys (docs/pi2-remote.md).
 */
const HELPER_ID = "dev.pi2.app.remote";
const HELPER_ENTITLEMENTS: string[] = [];
/**
 * What only a development build of pi² Remote has, compiled under PI2_DEVELOPMENT: its key files and the pairing id it
 * makes itself. A release helper that names one was built with the development paths in it.
 */
const HELPER_DEVELOPMENT_ONLY = ["remote-keys.json", "remote-devices.json", "a development build made its own pairing's id"];

class CheckFailed extends Error {}
function fail(message: string): never {
	throw new CheckFailed(message);
}
function step(message: string): void {
	console.log(`ok  ${message}`);
}

const { values: options, positionals } = parseArgs({
	allowPositionals: true,
	options: {
		version: { type: "string" },
		"build-number": { type: "string" },
		commit: { type: "string" },
		"bundle-id": { type: "string", default: BUNDLE_ID },
		"open-app": { type: "boolean", default: false },
	},
});
if (positionals.length !== 1) {
	console.error("Usage: node app/check-release-build.mts <pi².app | pi2-<version>.zip | pi2-<version>.dmg> [--version V] [--build-number N] [--commit SHA] [--bundle-id ID] [--open-app]");
	process.exit(2);
}
// Absolute, since the engine is started from the root folder, as the app starts it.
const given = resolve(positionals[0]!);
const expectedVersion = options.version ?? readFileSync(join(import.meta.dirname, "VERSION"), "utf8").trim();

/** Undone at the end, last first, whether the checks passed or not. */
const cleanups: (() => void | Promise<void>)[] = [];
/** The engine logs to show when a check fails. */
const logs: string[] = [];
const keychainService = `dev.pi2.credentials.release-check-${process.pid}`;

function run(command: string, args: string[]): string {
	return execFileSync(command, args, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], env: { ...process.env, LC_ALL: "en_US.UTF-8" } });
}

function temporaryFolder(prefix: string): string {
	// In /tmp rather than the usual temporary folder, whose long path would put the socket past macOS's 103 bytes.
	const folder = mkdtempSync(`/tmp/${prefix}`);
	cleanups.push(() => rmSync(folder, { recursive: true, force: true }));
	return folder;
}

function alive(pid: number): boolean {
	try {
		process.kill(pid, 0);
		return true;
	} catch (error) {
		return (error as NodeJS.ErrnoException).code === "EPERM";
	}
}

async function waitFor<T>(what: string, check: () => T | undefined | false, patience: number, over?: () => string | undefined): Promise<T> {
	for (const deadline = Date.now() + patience; ; ) {
		const value = check();
		if (value !== undefined && value !== false) return value;
		const reason = over?.();
		if (reason !== undefined) fail(`Waiting for ${what}, but ${reason}.`);
		if (Date.now() > deadline) fail(`Gave up waiting for ${what} after ${Math.round(patience / 1000)} seconds.`);
		await sleep(100);
	}
}

/** The same path however it was reached: through /tmp or /private/tmp, with its accents composed or not. */
function samePath(a: string, b: string): boolean {
	const real = (path: string) => {
		try {
			return realpathSync(path).normalize("NFC");
		} catch {
			return path.normalize("NFC");
		}
	};
	return real(a) === real(b);
}

// ---- The app to check: as given, unpacked from the update archive, or in the mounted disk image

function onlyApp(folder: string, from: string): string {
	const entries = readdirSync(folder).filter((name) => !name.startsWith("."));
	const apps = entries.filter((name) => name.endsWith(".app"));
	if (apps.length !== 1) fail(`${from} should hold one app, and holds ${apps.length === 0 ? "none" : apps.join(", ")}.`);
	return join(folder, apps[0]!);
}

async function appToCheck(): Promise<string> {
	if (!existsSync(given)) fail(`There is nothing at ${given}.`);
	if (given.endsWith(".zip")) {
		const folder = temporaryFolder("pi2-check-zip-");
		run("/usr/bin/ditto", ["-x", "-k", given, folder]);
		const app = onlyApp(folder, basename(given));
		const others = readdirSync(folder).filter((name) => !name.startsWith(".") && name !== basename(app));
		if (others.length > 0) fail(`${basename(given)} holds more than the app: ${others.join(", ")}. Sparkle expects the app alone.`);
		step(`unpacked ${basename(given)}: ${basename(app)}`);
		return app;
	}
	if (given.endsWith(".dmg")) {
		const mount = join(temporaryFolder("pi2-check-dmg-"), "volume");
		run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount, given]);
		cleanups.push(() => {
			try {
				run("/usr/bin/hdiutil", ["detach", mount]);
			} catch {
				run("/usr/bin/hdiutil", ["detach", "-force", mount]);
			}
		});
		const app = onlyApp(mount, basename(given));
		const link = join(mount, "Applications");
		if (!existsSync(link) || !lstatSync(link).isSymbolicLink() || readlinkSync(link) !== "/Applications") {
			fail(`${basename(given)} has no link to /Applications beside the app.`);
		}
		step(`mounted ${basename(given)}: ${basename(app)} and a link to /Applications`);
		return app;
	}
	if (!given.endsWith(".app")) fail(`${given} is not an app, a .zip or a .dmg.`);
	return given;
}

// ---- What the bundle says it is

function plistValue(plist: string, key: string): string | null {
	try {
		return run("/usr/bin/plutil", ["-extract", key, "raw", "-o", "-", plist]).trim();
	} catch {
		return null;
	}
}

type Build = { app: string; node: string; main: string; build: string; bundleId: string };

function checkBundle(app: string): Build {
	const plist = join(app, "Contents", "Info.plist");
	if (!existsSync(plist)) fail(`${app} has no Contents/Info.plist.`);
	const bundleId = plistValue(plist, "CFBundleIdentifier");
	if (bundleId !== options["bundle-id"]) {
		fail(`The app's bundle id is ${bundleId ?? "missing"}, not ${options["bundle-id"]}. Installed copies would not take it as an update of themselves.`);
	}
	const version = plistValue(plist, "CFBundleShortVersionString");
	if (version !== expectedVersion) fail(`The app says it is version ${version ?? "(none)"}, not ${expectedVersion}.`);
	const buildNumber = plistValue(plist, "CFBundleVersion") ?? "";
	if (!/^\d+$/.test(buildNumber)) fail(`The app's build number (CFBundleVersion) is "${buildNumber}", not a number. Sparkle compares it to decide what is newer.`);
	if (options["build-number"] !== undefined && buildNumber !== options["build-number"]) {
		fail(`The app's build number is ${buildNumber}, not ${options["build-number"]}.`);
	}
	const build = plistValue(plist, "PI2BuildID");
	if (build === null) fail("The app has no PI2BuildID, so it is not a release build: build it with ./app/build.sh release.");
	const escaped = expectedVersion.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
	const parts = new RegExp(`^${escaped}\\+${buildNumber}\\.([0-9a-f]{4,}|local)\\.\\d{14}$`).exec(build);
	if (parts === null) fail(`The app's build id, ${build}, is not "${expectedVersion}+${buildNumber}.<commit>.<time>".`);
	if (options.commit !== undefined && !options.commit.startsWith(parts[1]!)) {
		fail(`The app was built from commit ${parts[1]}, not ${options.commit}.`);
	}
	const resources = join(app, "Contents", "Resources");
	const node = join(resources, "node");
	const main = join(resources, "engine", "src", "main.ts");
	if (!existsSync(node)) fail("The app has no Node in Contents/Resources/node.");
	if (!existsSync(main)) fail("The app has no engine in Contents/Resources/engine/src/main.ts.");
	if (!existsSync(join(app, "Contents", "MacOS", "pi2-peer"))) fail("The app has no Contents/MacOS/pi2-peer, so its engine could not tell the app from any other program and nobody could answer an approval.");
	for (const fixture of ["test-copy-fixture.ts", "test-copy-project.ts"]) {
		if (existsSync(join(resources, "engine", "scripts", fixture))) fail(`The app carries the development-only fixture ${fixture}.`);
	}
	if (!existsSync(join(resources, "engine", "node_modules"))) fail("The app's engine has no node_modules: its dependencies were not installed.");
	let engineBuild = "";
	try {
		engineBuild = readFileSync(join(resources, "engine", "BUILD"), "utf8").trim();
	} catch {
		fail("The app's engine has no BUILD file, so the app could not tell it from an engine of another build.");
	}
	if (engineBuild !== build) fail(`The engine's BUILD file says ${engineBuild}, but the app is ${build}.`);
	const executable = readFileSync(join(app, "Contents", "MacOS", "pi2"));
	const named = DEVELOPMENT_ONLY.filter((name) => executable.includes(name));
	if (named.length > 0) {
		fail(`The app's executable names ${named.join(", ")}, which only a development build may read. Keep the code that reads ${named.length === 1 ? "it" : "them"} inside #if PI2_DEVELOPMENT.`);
	}
	step(`${basename(app)} is ${bundleId} ${version} (build ${buildNumber}), build id ${build}`);
	return { app, node, main, build, bundleId };
}

function checkSignature(app: string): void {
	try {
		run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app]);
	} catch (error) {
		fail(`The app's code signature does not hold: ${String((error as { stderr?: string }).stderr ?? error).trim()}`);
	}
	step("its code signature holds");
}

type Signing = { team: string | null; runtime: boolean; entitlements: string[] };

/** How `path` is signed: its team, whether it has the hardened runtime, and the names of its entitlements. */
function signingOf(path: string): Signing {
	const details = spawnSync("/usr/bin/codesign", ["-d", "--verbose=2", path], { encoding: "utf8" });
	const text = `${details.stdout}${details.stderr}`;
	const team = /^TeamIdentifier=(.+)$/m.exec(text)?.[1]?.trim() ?? null;
	const runtime = /flags=0x[0-9a-f]+\([^)]*\bruntime\b[^)]*\)/.test(text);
	const entitlements = spawnSync("/usr/bin/codesign", ["-d", "--entitlements", "-", "--xml", path], { encoding: "utf8" }).stdout ?? "";
	return { team: team === "not set" ? null : team, runtime, entitlements: [...entitlements.matchAll(/<key>([^<]+)<\/key>/g)].map((match) => match[1]!) };
}

/**
 * pi² Remote, the helper that holds the Mac's keys for a paired iPhone (#675, docs/pi2-remote.md): there, a release
 * build of it, signed by the app's team with the hardened runtime when the app is, and with no entitlement it may not
 * have. app/remote-helper.sh packages and signs it; this is the check that it did.
 */
function checkHelper(app: string): void {
	const helper = join(app, "Contents", "Helpers", "pi² Remote.app");
	const executable = join(helper, "Contents", "MacOS", "pi² Remote");
	if (!existsSync(executable)) fail("The app has no pi² Remote in Contents/Helpers/pi² Remote.app, so its engine could not reach a paired iPhone.");
	const id = plistValue(join(helper, "Contents", "Info.plist"), "CFBundleIdentifier");
	if (id !== HELPER_ID) fail(`pi² Remote's bundle id is ${id ?? "missing"}, not ${HELPER_ID}.`);
	try {
		run("/usr/bin/codesign", ["--verify", "--strict", helper]);
	} catch (error) {
		fail(`pi² Remote's code signature does not hold: ${String((error as { stderr?: string }).stderr ?? error).trim()}`);
	}
	const outer = signingOf(app);
	const mine = signingOf(helper);
	if (mine.team !== outer.team) fail(`pi² Remote is signed by team ${mine.team ?? "none"}, not the app's (${outer.team ?? "none"}).`);
	if ((outer.team !== null || outer.runtime) && !mine.runtime) fail("pi² Remote does not have the hardened runtime, which the app has: any program could load a library into it.");
	const extra = mine.entitlements.filter((name) => !HELPER_ENTITLEMENTS.includes(name));
	if (extra.length > 0) fail(`pi² Remote has entitlements it may not have: ${extra.join(", ")}. It holds the Mac's keys; nothing may load a library into it or attach to it.`);
	const bytes = readFileSync(executable);
	const development = HELPER_DEVELOPMENT_ONLY.filter((text) => bytes.includes(text));
	if (development.length > 0) fail(`pi² Remote's executable names ${development.join(", ")}, which only a development build has: it was built with PI2_DEVELOPMENT.`);
	if (!bytes.includes("_SecItemCopyMatching")) fail("pi² Remote's executable names no Keychain call, so it is not a release build of it.");
	step(`pi² Remote is there, ${HELPER_ID}, signed as the app is${mine.runtime ? " with the hardened runtime" : ""}, with no entitlement, and a release build of it`);
}

// ---- Talking to the engine

class Connection {
	readonly socket: Socket;
	conversations = new Map<number, { items: { kind: string; text?: string }[]; state: { busy?: boolean; failure?: { reason: string } | null } }>();
	events = new Set<string>();
	closed = false;
	#next = 1;
	#replies = new Map<number, { resolve: (value: any) => void; reject: (error: Error) => void }>();

	constructor(socket: Socket) {
		this.socket = socket;
		let buffer = "";
		socket.setEncoding("utf8").on("data", (chunk: string) => {
			buffer += chunk;
			const lines = buffer.split("\n");
			buffer = lines.pop()!;
			for (const line of lines) {
				if (line.trim() === "") continue;
				const message = JSON.parse(line);
				if (typeof message.event === "string") {
					this.events.add(message.event);
					if (message.event === "conversation") {
						const conversation = this.conversations.get(message.id) ?? { items: [], state: {} };
						if (message.reset) conversation.items = [];
						conversation.items.push(...message.items);
						conversation.state = message.state;
						this.conversations.set(message.id, conversation);
					}
				} else {
					const reply = this.#replies.get(message.id);
					this.#replies.delete(message.id);
					if (message.error !== undefined) reply?.reject(new CheckFailed(`The engine answered ${JSON.stringify(message.error)}.`));
					else reply?.resolve(message.result);
				}
			}
		});
		socket.on("error", () => {});
		socket.on("close", () => {
			this.closed = true;
			for (const reply of this.#replies.values()) reply.reject(new CheckFailed("The connection to the engine closed before it answered."));
			this.#replies.clear();
		});
	}

	call(method: string, params: Record<string, unknown> = {}): Promise<any> {
		if (this.closed) return Promise.reject(new CheckFailed(`The connection to the engine closed before ${method} was asked.`));
		const id = this.#next++;
		const answer = new Promise((resolve, reject) => this.#replies.set(id, { resolve, reject }));
		this.socket.write(`${JSON.stringify({ id, method, params })}\n`);
		let timer: ReturnType<typeof setTimeout>;
		const timeout = new Promise<never>((_, reject) => {
			timer = setTimeout(() => reject(new CheckFailed(`The engine did not answer ${method} within ${ANSWER_MS / 1000} seconds.`)), ANSWER_MS);
		});
		return Promise.race([answer, timeout]).finally(() => clearTimeout(timer));
	}

	close(): void {
		this.socket.destroy();
	}
}

/** Connects once the engine listens on the data folder's socket, giving up if `over` names a reason it never will. */
async function connectWhenListening(home: string, over: () => string | undefined): Promise<Connection> {
	const path = join(home, "engine.sock");
	if (Buffer.byteLength(path) > 103) fail(`The socket path ${path} is too long for macOS.`);
	for (const deadline = Date.now() + START_MS; ; ) {
		const socket = connect(path);
		try {
			await new Promise<void>((resolve, reject) => socket.once("connect", resolve).once("error", reject));
			return new Connection(socket);
		} catch {
			socket.destroy();
			const reason = over();
			if (reason !== undefined) fail(`The engine ${reason} before it listened.`);
			if (Date.now() > deadline) fail(`The engine did not listen within ${START_MS / 60_000} minutes.`);
			await sleep(100);
		}
	}
}

/** Asks the engine which build it is, and checks it is the one inside this app. */
async function checkInfo(connection: Connection, build: Build, pid: number): Promise<void> {
	const info = await connection.call("engine.info");
	if (info?.build !== build.build) fail(`The engine says it is build ${info?.build ?? "(none)"}, but the app is ${build.build}.`);
	if (typeof info.main !== "string" || !samePath(info.main, build.main)) fail(`The engine runs ${info?.main}, not the one inside the app (${build.main}).`);
	if (info.pid !== pid) fail(`The engine that answered is process ${info.pid}, not ${pid}, the one this check started.`);
	step(`engine.info: build ${info.build}, from inside the app, process ${info.pid}`);
}

/** A switch only the engine's tests may set (engine/src/testswitches.ts): the demo model's speed, which nothing else changes. */
const TEST_SWITCH = "PI2_DEMO_TOKENS_PER_SECOND";

/**
 * A release engine honours none of the switches only tests may set (#720), and says at start which it was given. Its
 * log is written before it listens, so the line is there by now.
 */
function checkTestSwitchIgnored(log: string): void {
	const line = readFileSync(log, "utf8").split("\n").find((each) => each.includes(`${TEST_SWITCH} is set and ignored`));
	if (line === undefined) fail(`The engine did not say it ignores ${TEST_SWITCH}, a switch only tests may set: a release engine must ignore it and say so.`);
	step(`the engine ignores a switch only tests may set: ${line.slice(line.indexOf(TEST_SWITCH))}`);
}

/** A conversation with the scripted demo model, which needs no provider: the engine stores it and runs a turn. */
async function checkAnswer(connection: Connection): Promise<void> {
	const { id } = await connection.call("conversation.create");
	await connection.call("conversation.open", { id });
	await connection.call("submit", { id, text: "hello from the release check" });
	const conversation = await waitFor(
		"the demo model's answer",
		() => {
			const conversation = connection.conversations.get(id);
			if (conversation?.state.failure) fail(`The conversation failed: ${conversation.state.failure.reason}`);
			return conversation !== undefined && conversation.state.busy === false && conversation.items.some((item) => item.kind === "assistant") && conversation;
		},
		ANSWER_MS,
		() => (connection.closed ? "the connection to the engine closed" : undefined),
	);
	const answer = conversation.items.find((item) => item.kind === "assistant")?.text ?? "";
	if (answer.trim() === "") fail("The demo model's answer was empty.");
	step(`the demo model answered in a new conversation (${answer.length} characters)`);
}

/**
 * Answers to what waits for the person are taken only from the app (#504). This check's own connection comes from Node,
 * not the app, so the engine must refuse it, having asked the helper inside the bundle rather than for want of one.
 */
async function checkOthersRefused(connection: Connection): Promise<void> {
	const verdict = await connection.call("connection.mayAnswer");
	if (verdict?.mayAnswer !== false) fail(`The engine would take answers for the person from this check's own connection: ${JSON.stringify(verdict)}.`);
	if (typeof verdict.why !== "string" || !/^process \d+ .*is not the app at /.test(verdict.why)) {
		fail(`The engine could not check this connection against the app with the pi2-peer inside it: ${verdict.why}.`);
	}
	const refused = await connection.call("inbox.answer", { id: "none", text: "yes" }).then(
		() => undefined,
		(error: Error) => error.message,
	);
	if (refused === undefined || !refused.includes("Only the person can answer this, in the pi² app")) {
		fail(`The engine did not refuse an answer from this check's connection as it should: ${refused ?? "it took it"}.`);
	}
	const setting = await connection.call("settings.setCompaction", { defaultCompactionTokens: null }).then(
		() => undefined,
		(error: Error) => error.message,
	);
	if (!setting?.includes("Only the person can do this, in the pi² app")) {
		fail(`The engine did not refuse a change to settings from this check's connection: ${setting ?? "it took it"}.`);
	}
	const key = await connection.call("test-copy.answerer").then(
		() => undefined,
		(error: Error) => error.message,
	);
	if (!key?.includes('"Unknown method: test-copy.answerer"')) fail(`The release engine must not register the test-copy key exchange: ${key ?? "it answered"}.`);
	step(`a connection from another program may not answer or change settings for the person: ${verdict.why}`);
}

/** Stops the engine as the app does when it quits, and checks it stopped cleanly. `exitCode` is for an engine this
 * check started itself, which can say how it ended: undefined while it runs. */
async function stopCleanly(pid: number, home: string, exitCode?: () => number | null | undefined): Promise<void> {
	const stopped = () => (exitCode ? exitCode() !== undefined : !alive(pid));
	if (!stopped()) process.kill(pid, "SIGTERM");
	await waitFor("the engine to stop after SIGTERM", stopped, STOP_MS);
	const code = exitCode?.();
	if (code !== undefined && code !== 0) fail(`The engine exited with ${code === null ? "a signal" : `code ${code}`} when told to stop.`);
	// The marker is removed only by a clean stop; the next start would take it for a crash.
	if (existsSync(join(home, "engine.running"))) fail("The engine did not stop cleanly: engine.running is still there.");
	step("the engine stopped cleanly when told to");
}

function engineEnvironment(home: string): Record<string, string> {
	// What an app opened from the Finder gives its engine: macOS's bare PATH, so nothing on the PATH of whoever runs the
	// check (such as their own Node) can stand in for what the app carries.
	const environment: Record<string, string> = {
		PATH: "/usr/bin:/bin:/usr/sbin:/sbin",
		PI2_HOME: home,
		PI2_KEYCHAIN_SERVICE: keychainService,
		PI2_LOGIN_SHELL: "off",
		// A switch only tests may set, which a release engine must ignore and name in its log (checkTestSwitchIgnored).
		[TEST_SWITCH]: "1000",
	};
	for (const name of ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "__CF_USER_TEXT_ENCODING"]) {
		const value = process.env[name];
		if (value !== undefined) environment[name] = value;
	}
	return environment;
}

async function checkEngine(build: Build): Promise<void> {
	const home = join(temporaryFolder("pi2-check-"), "home");
	const environment = engineEnvironment(home);
	execFileSync("/bin/mkdir", ["-p", home]);
	const log = join(home, "engine.log");
	logs.push(log);
	const output = openSync(log, "a");
	const engine: ChildProcess = spawn(build.node, [build.main], { cwd: "/", env: environment, stdio: ["ignore", output, output] });
	closeSync(output);
	let ended: string | undefined;
	let exitCode: number | null | undefined;
	engine.once("exit", (code, signal) => {
		exitCode = code;
		ended = signal !== null ? `was ended by ${signal}` : `exited with code ${code}`;
	});
	engine.once("error", (error) => (ended = `could not be started: ${error.message}`));
	cleanups.push(async () => {
		if (exitCode !== undefined || engine.pid === undefined || !alive(engine.pid)) return;
		const ended = new Promise<void>((resolve) => engine.once("exit", () => resolve()));
		engine.kill("SIGKILL");
		await ended;
	});
	const connection = await connectWhenListening(home, () => ended);
	cleanups.push(() => connection.close());
	step(`the engine inside the app listens on ${join(home, "engine.sock")}`);
	await checkInfo(connection, build, engine.pid!);
	checkTestSwitchIgnored(log);
	await checkAnswer(connection);
	await checkOthersRefused(connection);
	connection.close();
	await stopCleanly(engine.pid!, home, () => exitCode);
}

// ---- Opening the app itself

type Process = { pid: number; ppid: number; command: string };

function processes(): Process[] {
	return run("/bin/ps", ["-axww", "-o", "pid=,ppid=,comm="])
		.split("\n")
		.map((line) => /^\s*(\d+)\s+(\d+)\s+(.*)$/.exec(line))
		.filter((match) => match !== null)
		.map((match) => ({ pid: Number(match[1]), ppid: Number(match[2]), command: match[3]! }));
}

/**
 * The process macOS holds responsible for `pid`, by which it judges the privacy permissions of `pid` and of everything it
 * starts. Asked through libSystem's `responsibility_get_pid_responsible_for_pid`, which is not in the public headers and
 * which Node cannot call, so through a few lines of C compiled for the purpose. It only asks; it prompts for nothing.
 */
function responsibleFor(pid: number): number {
	const folder = temporaryFolder("pi2-check-responsible-");
	const source = join(folder, "responsible.c");
	writeFileSync(
		source,
		"#include <stdio.h>\n#include <stdlib.h>\n#include <unistd.h>\n" +
			"extern pid_t responsibility_get_pid_responsible_for_pid(pid_t);\n" +
			'int main(int argc, char **argv) { printf("%d\\n", responsibility_get_pid_responsible_for_pid(atoi(argv[1]))); }\n',
	);
	const program = join(folder, "responsible");
	run("/usr/bin/cc", [source, "-o", program]);
	return Number(run(program, [String(pid)]).trim());
}

/** The app's own sockets that are connected to one of the engine's: the app has connected. */
function appConnected(appPid: number, enginePid: number): boolean {
	// lsof names each Unix socket by its own address and, once connected, its peer's ("->0x…").
	const sockets = (pid: number) => {
		let text = "";
		try {
			text = run("/usr/sbin/lsof", ["-a", "-U", "-p", String(pid), "-F", "dn"]);
		} catch {
			return [];
		}
		const found: { address: string; peer: string | null }[] = [];
		for (const line of text.split("\n")) {
			if (line.startsWith("d")) found.push({ address: line.slice(1), peer: null });
			else if (line.startsWith("n->") && found.length > 0) found.at(-1)!.peer = line.slice(3);
		}
		return found;
	};
	const engine = new Set(sockets(enginePid).map((socket) => socket.address));
	return sockets(appPid).some((socket) => socket.peer !== null && engine.has(socket.peer));
}

/** Opening a copy with pi²'s own bundle id is for a Mac where no pi² is in use; asked before anything is started. */
function mayOpen(build: Build): void {
	if (build.bundleId.toLowerCase() !== BUNDLE_ID || inCI) return;
	fail(
		`--open-app would open an app with pi²'s own bundle id (${BUNDLE_ID}), which shares its preferences and macOS permissions with an installed copy. ` +
			"Run it on a CI runner, or on a copy with a bundle id of its own (CONTRIBUTING.md, Testing safely) with --bundle-id.",
	);
}

async function checkOpenedApp(build: Build): Promise<void> {
	const home = join(temporaryFolder("pi2-check-app-"), "home");
	logs.push(join(home, "engine.log"), join(home, "app.log"));
	const executable = join(build.app, "Contents", "MacOS", "pi2");
	const ours = () => processes().filter((process) => process.command.endsWith("/Contents/MacOS/pi2") && samePath(process.command, executable));
	if (ours().length > 0) fail(`A copy of this app is already running (${ours().map((process) => process.pid).join(", ")}); it must not be.`);
	const launched = Date.now();
	// `-W` keeps `open` running until the app quits, so an app that crashes as it launches is noticed at once.
	const opener = spawn("/usr/bin/open", ["-W", "-n", "-g", build.app, "--env", `PI2_HOME=${home}`, "--env", `PI2_KEYCHAIN_SERVICE=${keychainService}`, "--env", "PI2_LOGIN_SHELL=off"], {
		stdio: ["ignore", "ignore", "pipe"],
	});
	let openErrors = "";
	let openEnded: string | undefined;
	opener.stderr!.setEncoding("utf8").on("data", (text: string) => (openErrors += text));
	opener.once("exit", (code) => (openEnded = code === 0 ? "the app quit" : `open failed: ${openErrors.trim() || `exit code ${code}`}`));
	cleanups.push(() => {
		if (opener.exitCode === null && opener.signalCode === null) opener.kill();
	});
	// Stopped by process id, the app first so that it does not start another engine; then the engine it started.
	let appPid: number | undefined;
	let enginePid: number | undefined;
	const appGone = () => openEnded ?? (appPid !== undefined && !alive(appPid) ? "the app quit" : undefined);
	cleanups.push(async () => {
		for (const pid of [appPid, enginePid]) {
			if (pid === undefined || !alive(pid)) continue;
			process.kill(pid, "SIGTERM");
			for (let i = 0; i < 100 && alive(pid); i++) await sleep(100);
			if (alive(pid)) process.kill(pid, "SIGKILL");
		}
		try {
			run("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister", ["-u", build.app]);
		} catch {}
	});
	const pidFile = join(home, "engine.pid");
	const engineOnFile = () => {
		const pid = existsSync(pidFile) ? Number(readFileSync(pidFile, "utf8").trim()) : NaN;
		return Number.isInteger(pid) && pid > 0 && alive(pid) && pid;
	};
	try {
		const app = await waitFor("the app to start", () => ours()[0], START_MS, appGone);
		appPid = app.pid;
		step(`the app opened, process ${app.pid}`);
		enginePid = await waitFor("the app to start its engine", engineOnFile, START_MS, appGone);
	} catch (error) {
		// Whatever went wrong, macOS may know why the app ended.
		if (error instanceof CheckFailed && appGone() !== undefined) {
			const crash = await crashReport(build.bundleId, launched);
			fail(crash === undefined ? error.message : `${error.message} macOS's crash report says: ${crash}`);
		}
		throw error;
	}
	const [app, engine] = [appPid, enginePid];
	const engineProcess = processes().find((process) => process.pid === engine);
	if (engineProcess?.ppid !== app) fail(`The engine on the app's data folder, process ${engine}, was not started by the app (${app}).`);
	if (!samePath(engineProcess.command, build.node)) fail(`The app started its engine with ${engineProcess.command}, not the Node inside it.`);
	// Not the app: an agent's commands would have the app's Accessibility, around computer use's limits (#263).
	const responsible = responsibleFor(engine);
	if (responsible !== engine) {
		fail(`macOS holds process ${responsible}${responsible === app ? ", the app," : ""} responsible for the engine, not the engine itself, so agents' commands would have its privacy permissions.`);
	}
	const connection = await connectWhenListening(home, () => (alive(engine) ? undefined : "stopped"));
	cleanups.push(() => connection.close());
	step(`the app started the engine inside it, process ${engine}, responsible for itself, which listens`);
	await checkInfo(connection, build, engine);
	connection.close();
	await waitFor("the app to connect to its engine", () => appConnected(app, engine), START_MS, appGone);
	step("the app connected to its engine");
	// The app asks once it has connected (#504), and the engine writes down what it found.
	const said = (line: string) => line.includes(`answers: process ${app} `);
	const verdict = await waitFor(
		"the engine to say whether it takes answers from the app",
		() => readFileSync(join(home, "engine.log"), "utf8").split("\n").find(said),
		START_MS,
		appGone,
	);
	if (!verdict.endsWith("(may answer for the person)")) fail(`The engine will not take answers to approvals from the app itself: ${verdict}`);
	step(`the engine takes answers for the person from the app: ${verdict.slice(verdict.indexOf("answers: ") + 9)}`);
	const other = await connectWhenListening(home, () => (alive(engine) ? undefined : "stopped"));
	cleanups.push(() => other.close());
	await checkOthersRefused(other);
	other.close();
	process.kill(app, "SIGTERM");
	await waitFor("the app to quit", () => !alive(app), STOP_MS);
	step("the app quit when told to");
	await stopCleanly(engine, home);
}

/** What macOS's crash report for an app with this bundle id, written since `since`, says ended it. */
async function crashReport(bundleId: string, since: number): Promise<string | undefined> {
	const folder = join(homedir(), "Library", "Logs", "DiagnosticReports");
	// The report is written a moment after the process ends.
	for (const deadline = Date.now() + 20_000; Date.now() < deadline; await sleep(500)) {
		let names: string[];
		try {
			names = readdirSync(folder).filter((name) => name.endsWith(".ips"));
		} catch {
			return undefined;
		}
		for (const name of names) {
			const path = join(folder, name);
			try {
				if (statSync(path).mtimeMs < since - 1000) continue;
				const text = readFileSync(path, "utf8");
				const newline = text.indexOf("\n");
				if (JSON.parse(text.slice(0, newline)).bundleID !== bundleId) continue;
				const report = JSON.parse(text.slice(newline + 1));
				const exception = report.exception === undefined ? [] : [`${report.exception.type} (${report.exception.signal}).`];
				const reasons: string[] = report.termination?.reasons ?? [];
				return [...exception, ...reasons].join(" ").slice(0, 3000) || `see ${name}`;
			} catch {}
		}
	}
	return undefined;
}

// ----

let failure: string | undefined;
let logTails = "";
try {
	const app = await appToCheck();
	const build = checkBundle(app);
	if (options["open-app"]) mayOpen(build);
	checkSignature(app);
	checkHelper(app);
	await checkEngine(build);
	if (options["open-app"]) await checkOpenedApp(build);
} catch (error) {
	failure = error instanceof CheckFailed ? error.message : error instanceof Error ? (error.stack ?? error.message) : String(error);
	// Read now: the folders they are in go with the cleanup.
	for (const log of logs) {
		if (existsSync(log)) logTails += `\n--- end of ${basename(log)} ---\n${readFileSync(log, "utf8").split("\n").slice(-40).join("\n")}`;
	}
} finally {
	for (const cleanup of cleanups.reverse()) {
		try {
			await cleanup();
		} catch {}
	}
	// Nothing should have been stored, but whatever was goes with the check.
	for (let i = 0; i < 100; i++) {
		try {
			execFileSync("/usr/bin/security", ["delete-generic-password", "-s", keychainService], { stdio: "ignore" });
		} catch {
			break;
		}
	}
}
if (failure !== undefined) {
	const what = `The release build in ${given} did not pass: ${failure}`;
	console.error(inCI ? `::error title=Release build check::${what.replaceAll("\n", "%0A")}` : what);
	if (logTails !== "") console.error(logTails);
	process.exit(1);
}
console.log(`The release build in ${given} passed.`);
