// How long each shell command running in the foreground has been going, and when it last printed (issue #196).
//
// A command that is stuck (waiting on a privacy prompt, a network folder, a lock) looks the same as one that is busy:
// a spinner and "Running…". pi durable's live document says which calls are running but not since when, so the shell
// tool notes it here as it runs a command (commands.ts), and the engine adds it to what the app is sent: each running
// call of a conversation's live state, and each run in Activity (main.ts). The app and the conversation page tick the
// clocks themselves; the engine sends a time only when it changes, and the time of the last output at most every few
// seconds, which is close enough for "quiet for" shown only after half a minute.
//
// Kept in memory only. A command running when the engine stopped is not running any more.

/** A command running in the foreground: which call, what it runs, when it started and when it last printed, in ms since the epoch. */
export type CommandClock = { callId: string; command: string; startedAt: number; lastOutputAt: number | null };

/** Why the clocks of a conversation changed: a command started or ended, or printed since the last time it was said. */
export type ClockChange = "started" | "printed" | "ended";

/** How often a command that keeps printing has its time of last output sent to the app. */
export const PRINTED_EVERY_MS = 5_000;

export class RunningCommands {
	private readonly byConversation = new Map<number, Map<string, CommandClock>>();
	/** Conversations whose commands printed since the change was last said, and the timer that will say it. */
	private readonly printedIn = new Set<number>();
	private timer: NodeJS.Timeout | undefined;
	/** Told of each change: at once for a start or an end, at most every PRINTED_EVERY_MS for output. */
	onChange: ((conversationId: number, why: ClockChange) => void) | undefined;

	/** A command of `callId` starts now. Call `printed` as it prints and `end` once it has ended, however it ended. */
	begin(conversationId: number, callId: string, command: string, now = Date.now()): { printed(): void; end(): void } {
		let calls = this.byConversation.get(conversationId);
		if (calls === undefined) this.byConversation.set(conversationId, (calls = new Map()));
		const clock: CommandClock = { callId, command, startedAt: now, lastOutputAt: null };
		calls.set(callId, clock);
		this.onChange?.(conversationId, "started");
		let ended = false;
		return {
			printed: () => {
				if (ended) return;
				clock.lastOutputAt = Date.now();
				this.printedIn.add(conversationId);
				if (this.timer === undefined) {
					this.timer = setTimeout(() => this.sayPrinted(), PRINTED_EVERY_MS);
					this.timer.unref();
				}
			},
			end: () => {
				if (ended) return;
				ended = true;
				const current = this.byConversation.get(conversationId);
				if (current?.get(callId) === clock) current.delete(callId);
				if (current?.size === 0) this.byConversation.delete(conversationId);
				this.onChange?.(conversationId, "ended");
			},
		};
	}

	/** The commands running in a conversation, oldest first. */
	of(conversationId: number): CommandClock[] {
		return [...(this.byConversation.get(conversationId)?.values() ?? [])].sort((a, b) => a.startedAt - b.startedAt);
	}

	/** The clock of one call, if it is a command running in the foreground. */
	clock(conversationId: number, callId: string): CommandClock | undefined {
		return this.byConversation.get(conversationId)?.get(callId);
	}

	private sayPrinted(): void {
		this.timer = undefined;
		const conversations = [...this.printedIn];
		this.printedIn.clear();
		for (const id of conversations) if (this.byConversation.has(id)) this.onChange?.(id, "printed");
	}
}

/** The engine's one list, which the shell tool writes and the engine reads. */
export const runningCommands = new RunningCommands();
