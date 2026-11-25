// The switches in the engine's environment that exist only for tests (#720), and the one rule for all of them: they are
// honoured in a development engine and ignored in a release one. A release engine is one with a `BUILD` file next to
// its `src`, which a release build writes and the app compares with its own (main.ts); a development engine, run from
// a checkout, has none. Nothing a person does needs one of these: a gate held for good would stall every backup or
// carrying over without a line in the log, and the demo model's would change what an installed copy offers and
// counts. Setting one takes the same access as setting `PI2_HOME`, so this shuts no door; it keeps a stray variable
// from doing harm, and the engine says at start which of them it was given and ignored.
//
// The stand-ins that redirect what the engine reaches or runs (#743) are test switches too: an address on this Mac
// `web_fetch` may reach, the usage addresses of the plan limits, the program that keeps the Mac awake and the power
// source it is told, the local models' catalog. So are the tunings of a wait or a limit that only tests change, each
// described where it is read: a stray one could make the engine give up on a command, a limit or a download early, or
// look as if it had stalled.
//
// Every read of one of these goes through `testSwitch`; engine/test/testswitches.ts fails on a direct read in src.
// The other variables the engine reads are not listed: those a person, the app or a script sets (the data folder, the
// Keychain service, the login shell and how long start-up waits for it, `PI2_GH`), and the few tunings that are not
// only for tests (`PI2_NETWORK_WAIT_SCALE`, `PI2_CACHE_PAUSE_MS`, `PI2_LOCAL_GRACE_SECONDS`), are read where they are
// used.

import { existsSync, lstatSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

/**
 * The test-only switches, by name. A gate holds a run at a point while the file it names exists, having written
 * `<file>.started`, so that a test can kill the engine there: `PI2_BACKUP_GATE` a backup's copy (backup.ts),
 * `PI2_CARRY_SECRETS_GATE`, `PI2_CARRY_COMMIT_GATE` and `PI2_RESTORE_COMMIT_GATE` carrying over and its undoing
 * (carryover.ts), `PI2_DEMO_COMPACTION_GATE` the demo model's summary (providers.ts). `PI2_CARRY_NEVER` makes a data
 * folder as an older version left it. The demo model's: a price (`PI2_DEMO_COST`, usage.ts), a model that cannot see
 * pictures (`PI2_DEMO_TEXT_MODEL`), a picture model on a stand-in server (`PI2_DEMO_PICTURES`) and its typing speed
 * (`PI2_DEMO_TOKENS_PER_SECOND`, all three providers.ts). `PI2_TEST_COPY` is a throwaway copy's suffix, which
 * `testCopySuffix` checks further against the copy's own folders.
 *
 * The stand-ins (#743): `PI2_TEST_ALLOW_ADDRESS` (look.ts), `PI2_LIMITS_ANTHROPIC_URL`, `PI2_LIMITS_CODEX_URL` and
 * `PI2_LIMITS_KIMI_URL` (limits.ts), `PI2_AWAKE_PROGRAM` and `PI2_AWAKE_POWER` (keepawake.ts), `PI2_LOCAL_CATALOG`
 * (localmodels.ts), and for paired devices (#673): `PI2_REMOTE_STAND_IN`, a program run with the engine's own Node in place
 * of pi² Remote (remote.ts); `PI2_APP_ATTEST_STAND_IN`, which takes a test's own attestations in place of App Attest's,
 * and `PI2_APP_ATTEST_TEAM`, the team id a pairing claim's attestation is checked against (devices.ts);
 * `PI2_PAIR_UNATTESTED`, which with `PI2_TEST_COPY` takes a claim with no attestation, from the simulator (devices.ts,
 * set by `scripts/test-copy start --remote`, #681);
 * `PI2_UNPLACED_HANDLER`, a request added to the engine's table and placed in no list, which must stop it starting
 * (main.ts); `PI2_DEVICE_SESSION_MS`, the engine's own bound on a device session, shortened (remote.ts);
 * `PI2_APPROVAL_DEPTH_THROWS`, with which an approval met deeper than a phone's forms put one throws rather than being
 * said in the log (devices.ts, #881); `PI2_DEVICE_FAULT`, a method whose log line and handling from a device's line
 * throw, which must not end the engine (devices.ts, remote.ts). The tunings
 * only tests change: `PI2_AWAKE_GRACE_MS`, `PI2_AWAKE_POLL_MS` (keepawake.ts),
 * `PI2_COMMAND_TIMEOUT_SECONDS` (commands.ts), `PI2_OUTPUT_WAIT_SECONDS` (background.ts), `PI2_LIMITS_MIN_INTERVAL_MS`
 * (limits.ts), the `PI2_LIMIT_*_MS` (limitwait.ts), `PI2_LOCAL_STALL_MS`, `PI2_LOCAL_RETRY_MS`, `PI2_LOCAL_RETRIES`,
 * `PI2_LOCAL_KEEP_FREE`, `PI2_LOCAL_MEMORY_GB` (localmodels.ts), `PI2_LOCAL_RUN_RETRY_MS` (localrun.ts),
 * `PI2_PRESENT_DRAW_MS` (how long `present` waits for the app to draw a page, presented.ts) and `PI2_WAKES_PER_HOUR`
 * (wakes.ts).
 */
export const TEST_SWITCHES = [
	"PI2_APPROVAL_DEPTH_THROWS",
	"PI2_APP_ATTEST_STAND_IN",
	"PI2_APP_ATTEST_TEAM",
	"PI2_AWAKE_GRACE_MS",
	"PI2_AWAKE_POLL_MS",
	"PI2_AWAKE_POWER",
	"PI2_AWAKE_PROGRAM",
	"PI2_BACKUP_GATE",
	"PI2_CARRY_COMMIT_GATE",
	"PI2_CARRY_NEVER",
	"PI2_CARRY_SECRETS_GATE",
	"PI2_COMMAND_TIMEOUT_SECONDS",
	"PI2_DEMO_COMPACTION_GATE",
	"PI2_DEMO_COST",
	"PI2_DEMO_PICTURES",
	"PI2_DEMO_TEXT_MODEL",
	"PI2_DEMO_TOKENS_PER_SECOND",
	"PI2_DEVICE_FAULT",
	"PI2_DEVICE_SESSION_MS",
	"PI2_LIMITS_ANTHROPIC_URL",
	"PI2_LIMITS_CODEX_URL",
	"PI2_LIMITS_KIMI_URL",
	"PI2_LIMITS_MIN_INTERVAL_MS",
	"PI2_LIMIT_BACKOFF_MS",
	"PI2_LIMIT_REACHED_MS",
	"PI2_LIMIT_REMEMBER_MS",
	"PI2_LIMIT_WAIT_MAX_MS",
	"PI2_LOCAL_CATALOG",
	"PI2_LOCAL_KEEP_FREE",
	"PI2_LOCAL_MEMORY_GB",
	"PI2_LOCAL_RETRIES",
	"PI2_LOCAL_RETRY_MS",
	"PI2_LOCAL_RUN_RETRY_MS",
	"PI2_LOCAL_STALL_MS",
	"PI2_OUTPUT_WAIT_SECONDS",
	"PI2_PAIR_UNATTESTED",
	"PI2_PRESENT_DRAW_MS",
	"PI2_REMOTE_STAND_IN",
	"PI2_RESTORE_COMMIT_GATE",
	"PI2_TEST_ALLOW_ADDRESS",
	"PI2_TEST_COPY",
	"PI2_UNPLACED_HANDLER",
	"PI2_WAKES_PER_HOUR",
] as const;
export type TestSwitch = (typeof TEST_SWITCHES)[number];

/** Which build of the app this engine came with: the `BUILD` file a release build writes next to `src`, or null in a
 * development engine, which has none (or an empty one). */
export const engineBuild: string | null = (() => {
	try {
		return readFileSync(join(dirname(fileURLToPath(import.meta.url)), "..", "BUILD"), "utf8").trim() || null;
	} catch {
		return null;
	}
})();

/** Whether this is a release engine, which honours no test switch. */
export const releaseEngine = engineBuild !== null;

/** A test switch's value: as the environment has it in a development engine, never in a release one. */
export const testSwitch = (name: TestSwitch, env: NodeJS.ProcessEnv = process.env): string | undefined => (releaseEngine ? undefined : env[name]);

/**
 * The suffix of the throwaway copy scripts/test-copy started this engine for, or undefined: `PI2_TEST_COPY`, checked
 * against what only test-copy makes for that copy (not `dev`; its own data folder as `PI2_HOME`, its own Keychain
 * service, its bundle in this checkout's app/build/test-copies). main.ts's fixtures and answer key and devices.ts's
 * claim with no attestation (#681) both ask this. Never in a release engine, which reads no test switch.
 */
export const testCopySuffix = (env: NodeJS.ProcessEnv = process.env): string | undefined => {
	const suffix = testSwitch("PI2_TEST_COPY", env);
	if (suffix === undefined || suffix === "dev" || !/^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$/.test(suffix)) return undefined;
	const home = join(homedir(), "Library", "Application Support", `pi2-${suffix}`);
	const checkout = dirname(dirname(dirname(fileURLToPath(import.meta.url))));
	return env.PI2_HOME === home && lstatSync(home, { throwIfNoEntry: false })?.isDirectory() === true
		&& env.PI2_KEYCHAIN_SERVICE === `dev.pi2.credentials.${suffix}`
		&& existsSync(join(checkout, "app", "build", "test-copies", suffix, `pi² ${suffix}.app`, "Contents", "MacOS", "pi2"))
		? suffix
		: undefined;
};

/** The test switches the environment sets that this engine ignores, being a release engine: none in a development one. */
export const ignoredTestSwitches = (env: NodeJS.ProcessEnv = process.env): TestSwitch[] => (releaseEngine ? TEST_SWITCHES.filter((name) => env[name] !== undefined) : []);

/** The line a release engine writes at start when it was given test switches, naming them. */
export const ignoredLine = (names: readonly string[]): string =>
	`${names.join(", ")} ${names.length === 1 ? "is" : "are"} set and ignored: ${names.length === 1 ? "it is a switch" : "they are switches"} for tests, which a release engine does not honour`;
