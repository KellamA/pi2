// A request refused with data beside its plain message (docs/projects.md, 4.1). The engine answers it
// `{ id, error, data }`, and the app's EngineClient keeps `data` on the error it throws.

/**
 * Throw from a request's handler, as any Error, when the app needs more than the message to act on the refusal: the new
 * report of a plan that changed since the person looked (carryover.ts), or the reading a limit refused a start with.
 */
export class Refused extends Error {
	readonly data: unknown;
	constructor(message: string, data: unknown) {
		super(message);
		this.data = data;
	}
}
