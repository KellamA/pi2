// The switches in the engine's environment that exist only for tests (#720), and the one rule for all of them: they are
// honoured in a development engine and ignored in a release one. A release engine is one with a `BUILD` file next to
// its `src`, which a release build writes and the app compares with its own (main.ts); a development engine, run from
// a checkout, has none. Nothing a person does needs one of these: a gate held for good would stall every backup or
// carrying over without a line in the log, and the demo model's would change what an installed copy offers and
// counts. Setting one takes the same access as setting `PI2_HOME`, so this shuts no door; it keeps a stray variable
// from doing harm, and the engine says at start which of them it was given and ignored.
//
// Every read of one of these goes through `testSwitch`; engine/test/testswitches.ts fails on a direct read in src.
// The other variables the engine reads are not listed: those a person, the app or a script sets (the data folder, the
// Keychain service, the login shell, `PI2_GH`), and the tunings of a limit or a wait, which change no data and stall
// nothing for good, are read where they are used.

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

/**
 * The test-only switches, by name. A gate holds a run at a point while the file it names exists, having written
 * `<file>.started`, so that a test can kill the engine there: `PI2_BACKUP_GATE` a backup's copy (backup.ts),
 * `PI2_CARRY_SECRETS_GATE`, `PI2_CARRY_COMMIT_GATE` and `PI2_RESTORE_COMMIT_GATE` carrying over and its undoing
 * (carryover.ts), `PI2_DEMO_COMPACTION_GATE` the demo model's summary (providers.ts). `PI2_CARRY_NEVER` makes a data
 * folder as an older version left it. The demo model's: a price (`PI2_DEMO_COST`, main.ts), a model that cannot see
 * pictures (`PI2_DEMO_TEXT_MODEL`), a picture model on a stand-in server (`PI2_DEMO_PICTURES`) and its typing speed
 * (`PI2_DEMO_TOKENS_PER_SECOND`, all three providers.ts). `PI2_TEST_COPY` is a throwaway copy's suffix, which main.ts
 * checks further against the copy's own folders.
 */
export const TEST_SWITCHES = [
	"PI2_BACKUP_GATE",
	"PI2_CARRY_COMMIT_GATE",
	"PI2_CARRY_NEVER",
	"PI2_CARRY_SECRETS_GATE",
	"PI2_DEMO_COMPACTION_GATE",
	"PI2_DEMO_COST",
	"PI2_DEMO_PICTURES",
	"PI2_DEMO_TEXT_MODEL",
	"PI2_DEMO_TOKENS_PER_SECOND",
	"PI2_RESTORE_COMMIT_GATE",
	"PI2_TEST_COPY",
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

/** The test switches the environment sets that this engine ignores, being a release engine: none in a development one. */
export const ignoredTestSwitches = (env: NodeJS.ProcessEnv = process.env): TestSwitch[] => (releaseEngine ? TEST_SWITCHES.filter((name) => env[name] !== undefined) : []);

/** The line a release engine writes at start when it was given test switches, naming them. */
export const ignoredLine = (names: readonly string[]): string =>
	`${names.join(", ")} ${names.length === 1 ? "is" : "are"} set and ignored: ${names.length === 1 ? "it is a switch" : "they are switches"} for tests, which a release engine does not honour`;
