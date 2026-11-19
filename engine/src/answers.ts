// Who may answer for the person (#504).
//
// Every command an agent runs is a process of the same person as the app, and can connect to the engine's socket as
// the app does. So the requests that answer something waiting for the person are taken only from a connection whose
// other end is the pi² app itself, as macOS's code signing says: the app bundle's `Contents/MacOS/pi2-peer` (PeerKit
// in app/Sources) is started with the connection as its file descriptor 3 and says whether the process that connected
// satisfies the bundle's designated requirement. Node cannot ask a socket that itself. See "Who may answer for the
// person" in docs/architecture.md.

import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import type { Socket } from "node:net";
import { dirname, isAbsolute, join } from "node:path";

/** What a connection that is not the app's is told: it reaches an agent that tried, so it says what to do instead. */
export const ONLY_IN_THE_APP =
	"Only the person can answer this, in the pi² app: answers to approvals, questions and sign-ins, and turning on Allow everything, are not taken from a command or any other program. Ask the person instead.";

/**
 * The requests that answer something waiting for the person, and when a request is one. Turning Allow everything off
 * only narrows what an agent may do, and stays open to anyone.
 */
const FOR_THE_PERSON: Record<string, (params: Record<string, unknown>) => boolean> = {
	"inbox.decide": () => true, // an approval
	"inbox.answer": () => true, // a question an agent asked
	"auth.answer": () => true, // a prompt in a sign-in to a provider
	"agents.allowEverything": (params) => params.on === true, // sent once the person confirmed it in the app
};

export function answersForThePerson(method: string, params: Record<string, unknown>): boolean {
	return Object.hasOwn(FOR_THE_PERSON, method) && FOR_THE_PERSON[method]!(params);
}

/**
 * The app bundle this engine belongs to. A release engine is inside it (`Contents/Resources/engine/src/main.ts`) and
 * takes no other. A development engine runs from a checkout, so the app that starts it names its bundle in
 * `PI2_APP_BUNDLE`, which commands never get (environment.ts); without it, no connection is the app's.
 */
export function appBundle(engineMain: string, build: string | null, environment: NodeJS.ProcessEnv): string | null {
	if (build !== null) return dirname(dirname(dirname(dirname(dirname(engineMain)))));
	const named = environment.PI2_APP_BUNDLE;
	return named !== undefined && isAbsolute(named) ? named : null;
}

export type Verdict = { app: boolean; why: string };

/** Asks, once for each connection, whether the process at its other end is the app. */
export class AppCheck {
	readonly #bundle: string | null;
	readonly #log: (...parts: unknown[]) => void;
	readonly #patienceMs: number;
	readonly #verdicts = new WeakMap<Socket, Promise<Verdict>>();

	constructor(bundle: string | null, log: (...parts: unknown[]) => void, patienceMs = 10_000) {
		this.#bundle = bundle;
		this.#log = log;
		this.#patienceMs = patienceMs;
	}

	/**
	 * Whether `socket`'s other end is the app. The process at the other end of a connection cannot change, so a
	 * verdict is kept for the connection's life; a check that could not be made is not, and is made again next time.
	 * Anything that cannot be checked is not the app.
	 */
	verdict(socket: Socket): Promise<Verdict> {
		const known = this.#verdicts.get(socket);
		if (known !== undefined) return known;
		const asked = this.#ask(socket).then(({ verdict, lasting }) => {
			if (!lasting) this.#verdicts.delete(socket);
			this.#log("answers:", verdict.why, verdict.app ? "(may answer for the person)" : "(may not answer for the person)");
			return verdict;
		});
		this.#verdicts.set(socket, asked);
		return asked;
	}

	async #ask(socket: Socket): Promise<{ verdict: Verdict; lasting: boolean }> {
		const bundle = this.#bundle;
		if (bundle === null) return { verdict: { app: false, why: "this engine does not know which app it belongs to" }, lasting: true };
		const helper = join(bundle, "Contents", "MacOS", "pi2-peer");
		if (!existsSync(helper)) return { verdict: { app: false, why: `there is no ${helper} to ask whether a connection is the app's` }, lasting: false };
		return new Promise((resolve) => {
			const unchecked = (why: string) => resolve({ verdict: { app: false, why: `the connection could not be checked: ${why}` }, lasting: false });
			// The connection's descriptor, not the socket: given a stream, Node stops reading it in this process for good, as it
			// would if the child were to take it over. The helper only asks the socket about its other end, and never reads.
			const descriptor = (socket as unknown as { _handle?: { fd?: unknown } })._handle?.fd;
			if (typeof descriptor !== "number" || descriptor < 0) {
				unchecked("it has no descriptor to hand over");
				return;
			}
			let output = "";
			let child: ReturnType<typeof spawn>;
			try {
				child = spawn(helper, [bundle], { stdio: ["ignore", "pipe", "ignore", descriptor] });
			} catch (error) {
				unchecked(error instanceof Error ? error.message : String(error));
				return;
			}
			const timer = setTimeout(() => {
				child.kill("SIGKILL");
				unchecked(`${helper} did not answer within ${this.#patienceMs / 1000} seconds`);
			}, this.#patienceMs);
			child.stdout!.setEncoding("utf8").on("data", (text: string) => (output += text));
			child.once("error", (error) => {
				clearTimeout(timer);
				unchecked(error.message);
			});
			child.once("close", (code) => {
				clearTimeout(timer);
				try {
					const answer = JSON.parse(output.trim().split("\n").at(-1) ?? "") as { app?: unknown; why?: unknown };
					if (code !== 0 || typeof answer.app !== "boolean" || typeof answer.why !== "string") throw new Error();
					resolve({ verdict: { app: answer.app, why: answer.why }, lasting: true });
				} catch {
					unchecked(`${helper} ended with ${code === null ? "a signal" : `code ${code}`} and no answer`);
				}
			});
		});
	}
}
