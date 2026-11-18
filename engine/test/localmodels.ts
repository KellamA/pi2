// Running a model on this Mac (src/localrun.ts, #291): real engines on a throwaway data folder, with a stand-in for the
// engine that serves the model (localserver.ts), which takes the real one's command line, speaks the same API, loads
// when the test lets it, and can be told to fail or crash. Start on first use, sharing it between conversations, the
// grace period, stopping when the last conversation stops using it (its pane closed, its model changed, archived, its work
// over), a stop by hand, a model that cannot start, a crash, a clean stop of the engine, and one left by an engine that
// was killed outright.

import assert from "node:assert/strict";
import { type ChildProcess, execFileSync, spawn } from "node:child_process";
import { chmodSync, closeSync, existsSync, mkdtempSync, openSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { isRetryableAssistantError } from "@earendil-works/pi-ai/utils/retry";
import { STRATA } from "../src/localengine.ts";
import { EngineClient, exited, running, stop, until } from "./patience.ts";

const home = mkdtempSync(join(tmpdir(), "pi2-local-"));
const files = mkdtempSync(join(tmpdir(), "pi2-local-files-"));
const main = join(import.meta.dirname, "..", "src", "main.ts");
process.env.PI2_DEMO_TOKENS_PER_SECOND ??= "1000";
process.env.PI2_LOGIN_SHELL ??= "off";
const env = { ...process.env, PI2_HOME: home, PI2_KEYCHAIN_SERVICE: `dev.pi2.credentials.test-local-${process.pid}` };
const engineLog = join(home, "engine.log");

function step(name: string): void {
	console.log(`ok  ${name}`);
}

// ---- What is read from the engine's output, without an engine

assert.equal(STRATA.progress("loading model … 40%"), 0.4);
assert.equal(STRATA.progress("Loading tensors: 12.5 % done"), 0.125);
assert.equal(STRATA.progress("served 40% of requests"), undefined, "a percentage that is not about loading says nothing");
assert.equal(STRATA.progress("loading the vocabulary"), undefined);
step("how far loading has got is read from what the engine prints");
{
	// A prepared model is served by Strata's control package, with its run config, and Strata's own folders in pi²'s.
	const engine = { version: "0.1.60", path: "/e/strata", folder: "/e", control: { version: "0.1.61", folder: "/c" } };
	const model = { id: "m", name: "M", pack: "IQ3_S", path: "/m/1.gguf", contextSize: 65_536, options: {} };
	const served = STRATA.command(engine, { ...model, config: "/m/strata-m.json" }, 4321, "/data");
	assert.equal(served.program, "/c/python/bin/python3");
	assert.deepEqual(served.args.slice(0, 5), ["/c/serve/server.py", "--engine", "strata", "--config", "/m/strata-m.json"]);
	assert.ok(served.args.includes("4321") && served.args.includes("127.0.0.1"));
	assert.deepEqual(served.env, { HOME: "/data/local/strata/home", XDG_DATA_HOME: "/data/local/strata/data", STRATA_HOME: "/data/local/strata/strata" });
	assert.equal(STRATA.command(engine, model, 4321, "/data").program, "/e/strata", "a model not yet prepared has no run config");
	assert.ok(!JSON.stringify(served).includes("key"), "no key on the command line");
}
step("a prepared model is started through Strata's control package with its run config");

// ---- The stand-in, as the engine set up on this Mac, and the models it serves

const standIn = join(files, "strata");
writeFileSync(standIn, `#!/bin/sh\nexec "${process.execPath}" "${join(import.meta.dirname, "localserver.ts")}" "$@"\n`);
chmodSync(standIn, 0o755);
const model = (name: string, behaviour: Record<string, unknown>) => {
	const path = join(files, `${name}.json`);
	writeFileSync(path, JSON.stringify(behaviour));
	return path;
};
const gate = join(files, "alpha.loaded");
const alpha = model("alpha", { gate });
const beta = model("beta", { child: true, ignoreTerm: true });
const broken = model("broken", { fail: "not enough memory to load this model" });
writeFileSync(
	join(home, "local-models.json"),
	JSON.stringify({
		engine: { version: "0.0.0-test", path: standIn },
		models: [
			{ id: "alpha", name: "Alpha (stand-in)", pack: "Q2", path: alpha, contextSize: 40_960, options: { parallel: 2, unknown: "kept" } },
			{ id: "beta", name: "Beta (stand-in)", pack: "Q2", path: beta, contextSize: 8_192, options: { vision: true, visionFile: join(files, "beta.mmproj") } },
			{ id: "broken", name: "Broken (stand-in)", pack: "Q2", path: broken, contextSize: 8_192, options: {} },
		],
	}),
);

type Event = Record<string, any>;
class Client extends EngineClient {
	static async attach(engine: ChildProcess): Promise<Client> {
		const client = await Client.connect(engine, home);
		await client.until("first events", () => client.events.providers && client.events["local.running"]);
		return client;
	}
	/** The servers the engine says are running, by model. */
	server(id: string): any {
		return this.events["local.running"]?.running.find((each: Event) => each.id === id);
	}
	state(id: number): any {
		return this.conversations.get(id)?.state;
	}
	answers(id: number): Event[] {
		return this.conversations.get(id)?.items.filter((item: Event) => item.kind === "assistant") ?? [];
	}
	/** Sends a message and waits for its answer, or for the run to end without one; returns the last answer. */
	async ask(id: number, text: string): Promise<Event> {
		const before = this.answers(id).length;
		await this.call("submit", { id, text });
		return await this.until(`an answer to ${text}`, () => {
			const state = this.state(id);
			if (state === undefined || state.busy) return undefined;
			return this.answers(id).length > before ? this.answers(id).at(-1) : state.failure !== null ? { failure: state.failure } : undefined;
		});
	}
	async conversation(modelId: string): Promise<number> {
		const { id } = await this.call("conversation.create", { model: { provider: "local", modelId } });
		await this.call("conversation.open", { id });
		await this.until("its state", () => this.state(id));
		return id;
	}
	show(...ids: number[]): Promise<unknown> {
		return this.call("conversations.shown", { ids });
	}
}

const boot = (extra: Record<string, string> = {}) => {
	const log = openSync(engineLog, "a");
	try {
		return spawn(process.execPath, [main], { env: { ...env, ...extra }, stdio: ["ignore", "ignore", log] });
	} finally {
		closeSync(log);
	}
};
const logged = () => (existsSync(engineLog) ? readFileSync(engineLog, "utf8") : "");
/** Whether a process runs: one that has ended and waits only to be reaped (Z) runs nothing. */
const alive = (pid: number) => {
	try {
		return !execFileSync("/bin/ps", ["-o", "stat=", "-p", String(pid)], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim().startsWith("Z");
	} catch {
		return false;
	}
};
const pidOf = (path: string, suffix = ".pid") => Number(readFileSync(`${path}${suffix}`, "utf8"));
/** Every process this test may have started through an engine, to be sure none outlives it. */
const started = new Set<number>();
const note = (pid: number) => (started.add(pid), pid);

let passed = false;
let engine: ChildProcess = boot({ PI2_LOCAL_GRACE_SECONDS: "3600" });
try {
	let client = await Client.attach(engine);

	// ---- In the selector, set up but not running
	const listed = client.events.providers.models.filter((each: Event) => each.provider === "local");
	assert.deepEqual(
		listed.map((each: Event) => [each.id, each.name, each.providerName, each.contextWindow, each.vision]),
		[
			["alpha", "Alpha (stand-in)", "On this Mac", 40_960, false],
			["beta", "Beta (stand-in)", "On this Mac", 8_192, true],
			["broken", "Broken (stand-in)", "On this Mac", 8_192, false],
		],
		"every model set up is offered, under On this Mac, with its context size, whether or not it runs",
	);
	const provider = client.events.providers.providers.find((each: Event) => each.id === "local");
	assert.equal(provider.kind, "local");
	assert.equal(provider.keyAuth, false, "it asks for no key");
	assert.deepEqual(client.events["local.running"].running, [], "nothing runs at first");
	const status = await client.call("local.status");
	assert.equal(status.engine.path, standIn);
	assert.deepEqual(status.running, []);
	step("models set up on this Mac are offered under On this Mac, and none runs until one is used");

	// ---- Start on first use; a message sent while it loads waits and is answered
	const a = await client.conversation("alpha");
	assert.equal(client.state(a).local.status, "stopped", "a conversation with the model, not shown and not working, does not start it");
	assert.equal(client.server("alpha"), undefined);
	await client.show(a);
	const loading = await client.until("alpha starting", () => client.server("alpha"));
	assert.equal(loading.status, "starting");
	await client.until("the conversation says it is starting, and how far it has got", () => client.state(a).local.status === "starting" && client.state(a).local.progress === 0.4);
	const alphaPid = note(await until("the stand-in's pid", () => existsSync(`${alpha}.pid`) && pidOf(alpha)));
	await client.call("submit", { id: a, text: "hello while loading" });
	await client.until("the message waits", () => client.state(a).busy === true);
	assert.equal(client.answers(a).length, 0, "it is not answered before the model has loaded");
	assert.equal(client.state(a).failure, null, "nor refused");
	writeFileSync(gate, "");
	const first = await client.ask(a, "hello again");
	assert.match(client.answers(a)[0].text, /^You said: hello while loading/, "the message sent while it loaded is answered once it has");
	assert.match(first.text, /^You said: hello again/);
	assert.equal(client.server("alpha").status, "ready");
	assert.equal(client.state(a).local.status, "ready");
	assert.deepEqual(client.server("alpha").users, [a]);
	// Its process: the command line localengine.ts gives, on 127.0.0.1 only, a group of its own with the run's marker.
	const args = JSON.parse(readFileSync(`${alpha}.args`, "utf8")) as string[];
	assert.deepEqual(args.slice(0, 4), ["--model", alpha, "--host", "127.0.0.1"]);
	assert.deepEqual(args.slice(6), ["--context", "40960", "--parallel", "2", "--vision", "no"]);
	assert.equal(client.server("alpha").pid, alphaPid);
	assert.equal(Number(execFileSync("/bin/ps", ["-o", "pgid=", "-p", String(alphaPid)], { encoding: "utf8" }).trim()), alphaPid, "it leads a process group of its own");
	assert.match(execFileSync("/bin/ps", ["-E", "-ww", "-o", "command=", "-p", String(alphaPid)], { encoding: "utf8" }), /PI2_RUN=[0-9a-f]{32}/, "it carries the run's marker");
	step("a conversation shown with a model on this Mac starts it, says so, and a message sent while it loads is answered once it has");

	// ---- Shared between conversations
	const b = await client.conversation("alpha");
	await client.show(a, b);
	assert.match((await client.ask(b, "from b")).text, /^You said: from b/);
	await client.until("both use it", () => client.server("alpha")?.users.length === 2);
	assert.equal(client.server("alpha").pid, alphaPid, "the second conversation uses the model already loaded");
	assert.equal(client.events["local.running"].running.length, 1);
	step("several conversations share the one loaded model");

	// ---- The grace period
	await client.show();
	const waiting = await client.until("counting down", () => client.server("alpha")?.stopsAt);
	assert.ok(waiting > Date.now() + 60_000, "with nobody using it, it stays loaded for the grace period");
	assert.equal(client.server("alpha").status, "ready");
	await client.show(b);
	await client.until("no longer counting down", () => client.server("alpha")?.stopsAt === null);
	assert.equal(client.server("alpha").pid, alphaPid, "a conversation shown again within the grace period finds it still loaded");
	step("with no conversation using it, it stays loaded for the grace period, and one shown meanwhile keeps it");

	// ---- Stopped by hand
	await client.call("local.stop", { id: "alpha" });
	await client.until("stopped", () => client.server("alpha") === undefined && !alive(alphaPid));
	await client.until("the conversation says it is stopped", () => client.state(b).local.status === "stopped");
	const c = await client.call("conversation.create", {});
	await client.show(b, c.id);
	// A look at who uses what has come and gone (the demo conversation's): the open conversation has not started it again.
	await client.call("local.status");
	assert.equal(client.server("alpha"), undefined, "a model stopped by hand is not started again by itself");
	const again = await client.ask(b, "after the stop");
	assert.match(again.text, /^You said: after the stop/, "the next message starts it again");
	const alphaPid2 = note(client.server("alpha").pid);
	assert.notEqual(alphaPid2, alphaPid);
	step("Stop by hand stops it; the conversations using it are not broken, and the next message starts it again");

	// ---- A crash
	const answered = client.answers(b).length;
	await client.call("submit", { id: b, text: "/crash now" });
	await until("the stand-in crashed", () => !alive(alphaPid2));
	await client.until("the run is over", () => client.state(b).busy === false && (client.answers(b).length > answered || client.state(b).failure !== null));
	assert.match(logged(), /alpha stopped unexpectedly: Strata exited with code 3/);
	const after = await client.ask(b, "after the crash");
	assert.match(after.text, /^You said: after the crash/, "the next message starts it again after a crash");
	note(client.server("alpha").pid);
	step("a model that crashes is noted, and the next message starts it again");

	// ---- A model that cannot start says why
	const d = await client.conversation("broken");
	await client.show(b, d);
	await client.until("it failed", () => client.state(d).local.status === "failed");
	const failed = client.state(d).local;
	assert.equal(failed.error, "Strata exited with code 1 before the model was loaded");
	assert.ok(failed.lines.includes("error: not enough memory to load this model"), `the end of its log is shown: ${failed.lines}`);
	assert.equal(failed.log, join(home, "local", "logs", "broken.log"));
	const refused = await client.ask(d, "hello");
	const said = client.answers(d).at(-1)?.error ?? refused.failure?.detail ?? "";
	assert.match(said, /^Broken \(stand-in\) could not be started on this Mac: Strata exited with code 1 before the model was loaded\. What Strata printed is in its log, .*broken\.log\.$/);
	assert.equal(isRetryableAssistantError({ role: "assistant", stopReason: "error", errorMessage: said } as never), false, "it is not asked again and again");
	step("a model that cannot start says why in the conversation, and where its log is");

	// ---- Left over by an engine killed outright
	const e = await client.conversation("beta");
	await client.show(e);
	await client.until("beta ready", () => client.server("beta")?.status === "ready");
	const betaPid = note(pidOf(beta));
	const betaChild = note(pidOf(beta, ".child"));
	await client.until("its process on record", () => client.server("beta")?.recorded === true);
	await stop(engine, "SIGKILL");
	assert.ok(alive(betaPid) && alive(betaChild), "an engine killed outright leaves it running for the moment");
	engine = boot({ PI2_LOCAL_GRACE_SECONDS: "0" });
	client = await Client.attach(engine);
	await until("the next engine stops it, what it started too, though it ignores SIGTERM", () => !alive(betaPid) && !alive(betaChild));
	assert.match(logged(), /beta on this Mac, left by the last engine, was stopped/);
	step("one left running by an engine that was killed outright is stopped by the next, with what it started");

	// ---- Stops when the last conversation stops using it (no grace period here)
	await client.call("conversation.open", { id: a });
	await client.show(a);
	await client.until("alpha ready", () => client.server("alpha")?.status === "ready");
	let pid = note(client.server("alpha").pid);
	await client.show();
	await client.until("stopped", () => client.server("alpha") === undefined && !alive(pid));
	assert.equal((await client.call("local.status")).ended.alpha.how, "was stopped because no conversation was using it");
	step("once its pane is closed and nothing else uses it, it stops after the grace period");

	// ---- A conversation at work counts while not shown
	const hold = join(files, "hold");
	await client.show(a);
	await client.call("submit", { id: a, text: `/hold ${hold}` });
	await client.until("answering", () => client.state(a).busy && client.server("alpha")?.status === "ready");
	pid = note(client.server("alpha").pid);
	await client.show();
	await client.until("still used, by the work", () => client.server("alpha")?.users.includes(a));
	writeFileSync(hold, "");
	await client.until("answered", () => !client.state(a).busy && client.answers(a).at(-1)?.text.includes("/hold"));
	assert.equal(client.answers(a).at(-1)?.error ?? null, null, "the answer was not cut off");
	await client.until("stopped once the work is over", () => client.server("alpha") === undefined && !alive(pid));
	step("a conversation whose agent is working uses the model while not shown, and stops counting when the work ends");

	// ---- Its model changed, or archived
	await client.show(a);
	await client.until("alpha ready", () => client.server("alpha")?.status === "ready");
	pid = note(client.server("alpha").pid);
	await client.call("conversation.configure", { id: a, model: { provider: "demo", modelId: "demo-1" } });
	await client.until("stopped once its model changed", () => client.server("alpha") === undefined && !alive(pid));
	await client.until("not about a model on this Mac any more", () => client.state(a).local === null);
	await client.call("conversation.configure", { id: a, model: { provider: "local", modelId: "alpha" } });
	await client.until("started again for the model switched to", () => client.server("alpha")?.status === "ready");
	pid = note(client.server("alpha").pid);
	await client.call("conversation.archive", { id: a });
	await client.until("stopped once archived", () => client.server("alpha") === undefined && !alive(pid));
	step("a conversation stops counting when its model is changed or it is archived, and switching to the model starts it");

	// ---- A clean stop of the engine stops it within its deadline
	await client.show(e);
	await client.until("beta ready", () => client.server("beta")?.status === "ready");
	const betaPid2 = note(pidOf(beta));
	const betaChild2 = note(pidOf(beta, ".child"));
	engine.kill("SIGTERM");
	await exited(engine);
	assert.ok(!alive(betaPid2) && !alive(betaChild2), "a clean stop of the engine stops the model, and what it started, though it ignores SIGTERM");
	const took = Number(/stopped cleanly in (\d+) ms/.exec(logged().split("\n").filter((line) => line.includes("stopped cleanly")).at(-1) ?? "")?.[1]);
	assert.ok(took <= 5_000, `within the five seconds the app gives the engine: ${took} ms`);
	step("a clean stop of the engine stops the model it runs, in time");

	console.log("PASS");
	passed = true;
} finally {
	if (running(engine)) await stop(engine, "SIGKILL");
	for (const pid of started) {
		try {
			const line = execFileSync("/bin/ps", ["-o", "command=", "-p", String(pid)], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] });
			if (line.includes("localserver.ts") || line.includes("setInterval")) process.kill(pid, "SIGKILL");
		} catch {
			// Gone, as it should be.
		}
	}
	if (!passed && existsSync(engineLog)) process.stderr.write(readFileSync(engineLog, "utf8"));
	rmSync(home, { recursive: true, force: true });
	rmSync(files, { recursive: true, force: true });
}
process.exit(0);
