/** A refused socket request whose caller needs more than the message shown to the person. */
export class RequestError extends Error {
	readonly data: Record<string, unknown>;
	constructor(message: string, data: Record<string, unknown>) {
		super(message);
		this.data = data;
	}
}

export function refusal(error: unknown): { error: string; data?: Record<string, unknown> } {
	return { error: error instanceof Error ? error.message : String(error), ...(error instanceof RequestError ? { data: error.data } : {}) };
}
