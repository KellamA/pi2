// Keeping this Mac awake while agents work (#561).
//
// The engine outlives the app's window, and it is the one that knows when work is going on: it holds the assertion
// while any conversation is working — or waiting for a limit or the network to carry on by itself, which is a run
// asleep in its own checkpoint and still in the task graph — and lets it go when none is. A conversation waiting for
// the person (an approval or a question, the runs Activity shows as "waiting") does not count: nobody is working then.
//
// Node has no call for a power assertion, so the engine runs `/usr/bin/caffeinate -i -w <its own pid>` while it holds
// one: `-i` asserts "no idle sleep" — the display may still sleep — and `-w` makes caffeinate watch the engine's
// process and end by itself when that process ends, however it ends (a clean stop, `kill -9`, a crash: caffeinate
// polls the pid, so no code of ours has to run for the assertion to be let go). The engine stops it directly as well:
// at once on a clean stop and on the setting being turned off, and a minute after the last run ends otherwise, so that
// a run that ends and another that starts do not flap it. It also watches the holder itself, so one that ends while the
// Mac is still to be kept awake is started again, and one that ends with nothing left to hold is not believed in.
//
// Only on power, unless the second switch says "Also on battery" (off by default). The power source is read with
// `pmset -g ps`, which changes nothing, and only while it matters: with "Also on battery" on, power is never read.
// A read that fails counts as AC power, so a Mac whose power cannot be read still has its agents' work protected.
//
// Nothing here writes the person's power settings; it only holds one assertion while work goes on. What no app can
// prevent still happens: closing the lid of a Mac with no display attached puts it to sleep (`pmset disablesleep`, as
// an administrator, or an external display, is what changes that), and with the screen locked or the lid closed agents
// cannot take pictures of windows or work other apps.

import { spawn, type ChildProcess } from "node:child_process";
import { readFileSync } from "node:fs";
import type { Feature } from "./features.ts";
import { runOffThread } from "./offthread.ts";

/** The switch and its second switch, in Settings › General. Absent from settings.json means on, and not on battery. */
export type AwakeSettings = { keep: boolean; battery: boolean };
export const DEFAULT_AWAKE: AwakeSettings = { keep: true, battery: false };

/** What `settings.json` can hold for the switch; anything else is taken as the default. */
export function awakeSettings(raw: unknown): AwakeSettings {
	if (raw === null || typeof raw !== "object") return { ...DEFAULT_AWAKE };
	const awake = raw as { keep?: unknown; battery?: unknown };
	return { keep: awake.keep !== false, battery: awake.battery === true };
}

/** Which of the two ways the Mac is powered, as `pmset -g ps` names it. */
export type Power = "ac" | "battery";

/** How the power source is read: `pmset -g ps`, which reads and changes nothing. A read that fails counts as AC power. */
export async function readPower(env: NodeJS.ProcessEnv, run: (file: string, args: readonly string[]) => Promise<{ stdout: string }> = runOffThread): Promise<Power> {
	const forced = env.PI2_AWAKE_POWER;
	if (forced === "ac" || forced === "battery") return forced;
	// A test can name a file holding `pmset -g ps`'s words instead, so it can change the power source while the engine
	// runs and watch being unplugged let the Mac sleep again.
	if (forced !== undefined) {
		try {
			return readFileSync(forced, "utf8").includes("Battery Power") ? "battery" : "ac";
		} catch {
			return "ac";
		}
	}
	const { stdout } = await run("/usr/bin/pmset", ["-g", "ps"]).catch(() => ({ stdout: "" }));
	return stdout.includes("Battery Power") ? "battery" : "ac";
}

/** What the decision is made from, so it can be taken apart from the engine that decides it. */
export type AwakeState = {
	keep: boolean;
	battery: boolean;
	power: Power;
	/** Every conversation with live work, sub-chats included. */
	working: ReadonlySet<number>;
	/** The conversations waiting for the person, as Activity shows them "waiting" rather than working. */
	waiting: ReadonlySet<number>;
};

/**
 * Whether the Mac is kept awake, and how many conversations it is kept awake for. A conversation waiting for the
 * person is not one: its work is stopped until they answer, and nothing of pi²'s carries on then.
 */
export function keepingAwake(state: AwakeState): { hold: boolean; conversations: number } {
	const conversations = [...state.working].filter((id) => !state.waiting.has(id)).length;
	return { hold: state.keep && conversations > 0 && (state.battery || state.power === "ac"), conversations };
}

/** A setting from the environment, for tests: a number of milliseconds, or the default. */
function setting(name: string, fallback: number): number {
	const value = Number(process.env[name]);
	return process.env[name] !== undefined && Number.isFinite(value) && value >= 0 ? value : fallback;
}

/** How long the assertion is held after the last run ends, so a run that ends and another that starts do not flap it. */
export const GRACE_MS = setting("PI2_AWAKE_GRACE_MS", 60_000);
/** How often the power source is looked at while work goes on, so being unplugged lets the Mac sleep again. */
const POWER_POLL_MS = setting("PI2_AWAKE_POLL_MS", 30_000);

/** The program that holds the assertion; a stand-in can be named for tests. */
const PROGRAM = process.env.PI2_AWAKE_PROGRAM ?? "/usr/bin/caffeinate";

export const keepAwake: Feature = (_host, engine) => {
	let settings = DEFAULT_AWAKE;
	/** Every conversation with live work, sub-chats included, as `runsChanged` last said. */
	let working: ReadonlySet<number> = new Set();
	let power: Power | undefined;
	let holding = false;
	let holder: ChildProcess | undefined;
	/** While the grace after the last run runs, when it ends. */
	let letGoAt: number | undefined;
	let graceTimer: ReturnType<typeof setTimeout> | undefined;
	let powerTimer: ReturnType<typeof setInterval> | undefined;
	/** When the holder was last started, so one that ends at once is not started over and over. */
	let startedAt = 0;
	const event = () => ({ event: "awake", keep: settings.keep, battery: settings.battery, holding });
	const conversationsWorking = (): number => {
		const waiting = engine.waitingOnThePerson();
		return [...working].filter((id) => !waiting.has(id)).length;
	};

	const readPowerNow = async (): Promise<void> => {
		const read = await readPower(process.env);
		if (read !== power) {
			power = read;
			decide();
		}
	};

	/** Whether the power source matters now: it does only with the setting on, work going and battery not allowed. */
	const powerMatters = (conversations: number): boolean => settings.keep && conversations > 0 && !settings.battery;

	/** Whether the Mac is to be kept awake now, as the decision in `keepingAwake` puts it. */
	const wanted = (): boolean => settings.keep && conversationsWorking() > 0 && (settings.battery || power !== "battery");

	const stopHolding = (why: string): void => {
		clearTimeout(graceTimer);
		graceTimer = undefined;
		letGoAt = undefined;
		if (holder !== undefined) {
			holder.kill();
			holder = undefined;
		}
		if (!holding) return;
		holding = false;
		engine.log(`letting this Mac sleep again: ${why}`);
		engine.broadcast(event());
	};

	/** Start a holder, and watch it: one that ends by itself is noticed rather than believed for ever. */
	const startHolding = (conversations: number): void => {
		holding = true;
		startedAt = Date.now();
		const child = spawn(PROGRAM, ["-i", "-w", String(process.pid)], { stdio: "ignore" });
		holder = child;
		// A program that could not be started never held anything: say so, and let the next change try again rather than
		// starting it over and over.
		child.once("error", (error) => {
			engine.log(`could not keep this Mac awake: ${error.message}`);
			if (holder !== child) return;
			holder = undefined;
			if (!holding) return;
			holding = false;
			engine.broadcast(event());
		});
		// A holder that ends by itself — killed, or a caffeinate that gave up — is one nothing holds any more: hold it
		// again while it is still wanted, and only then, so the app and `engine.log` never say it is held while it is not.
		child.once("exit", (code, signal) => {
			if (holder !== child) return;
			holder = undefined;
			if (!holding) return;
			const why = signal ?? `code ${code}`;
			if (wanted() && Date.now() - startedAt > 1_000) {
				engine.log(`the program that keeps this Mac awake ended (${why}); holding it again`);
				holding = false;
				decide();
				return;
			}
			holding = false;
			engine.log(`could not keep this Mac awake: the program ended (${why})`);
			engine.broadcast(event());
		});
		engine.log(`keeping this Mac awake: ${conversations} conversation${conversations === 1 ? "" : "s"} working${settings.battery ? " (battery allowed)" : ""}`);
		engine.broadcast(event());
	};

	const decide = (): void => {
		const conversations = conversationsWorking();
		// While the power source matters, it is looked at again now and then, so being unplugged lets the Mac sleep
		// again, and plugged in lets it be kept awake, without a person's click in between.
		if (powerMatters(conversations)) {
			if (powerTimer === undefined) {
				powerTimer = setInterval(() => void readPowerNow(), POWER_POLL_MS);
				powerTimer.unref();
			}
			if (power === undefined) {
				void readPowerNow();
				return;
			}
		} else if (powerTimer !== undefined) {
			clearInterval(powerTimer);
			powerTimer = undefined;
			// Read again when it next matters, rather than trusting a reading from before the Mac was unplugged or plugged
			// in while nothing worked: the first run after that would otherwise hold for half a minute on battery, or not
			// hold for half a minute on power.
			power = undefined;
		}
		if (settings.keep && conversations > 0 && (settings.battery || power !== "battery")) {
			// Work is going on: hold it now, and take back any grace that had begun.
			clearTimeout(graceTimer);
			graceTimer = undefined;
			letGoAt = undefined;
			if (holding) return;
			startHolding(conversations);
			return;
		}
		if (!holding) return;
		// The setting being turned off, or battery power with battery not allowed, ends it at once; the last run
		// ending is what the minute of grace is for.
		if (!settings.keep || (!settings.battery && power === "battery")) {
			stopHolding(settings.keep ? `on battery, and “Also on battery” is off` : "turned off in Settings");
			return;
		}
		if (letGoAt === undefined) {
			letGoAt = Date.now() + GRACE_MS;
			graceTimer = setTimeout(() => {
				graceTimer = undefined;
				letGoAt = undefined;
				// Look again, so work that came back within the grace keeps the holder it already has.
				if (wanted()) return;
				stopHolding("no conversation is working any more");
			}, GRACE_MS);
			graceTimer.unref();
		}
	};

	return {
		start: async () => {
			// The setting is read once the engine has it: the feature is made before settings.json is read.
			settings = awakeSettings(engine.setting("awake"));
		},
		greeting: () => [event()],
		handlers: {
			/** `{ keep, battery }`: the switch and its second switch in Settings › General, from the app only. */
			"settings.setAwake": async (params) => {
				if (params.keep !== undefined && typeof params.keep !== "boolean") throw new Error("keep must be true or false");
				if (params.battery !== undefined && typeof params.battery !== "boolean") throw new Error("battery must be true or false");
				settings = {
					keep: typeof params.keep === "boolean" ? params.keep : settings.keep,
					battery: typeof params.battery === "boolean" ? params.battery : settings.battery,
				};
				engine.saveSetting("awake", { ...settings });
				engine.broadcast(event());
				decide();
				return { ...settings };
			},
		},
		runsChanged: (ids) => {
			working = ids;
			decide();
		},
		inboxChanged: () => decide(),
		stopping: async () => {
			if (powerTimer !== undefined) {
				clearInterval(powerTimer);
				powerTimer = undefined;
			}
			stopHolding("the engine is stopping");
		},
	};
};
