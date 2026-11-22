// Workers' types say `TextEncoder.encode` gives a `Uint8Array` over any buffer; TypeScript's own (which the engine's
// type-check uses) say over an `ArrayBuffer`, which is what it gives in both runtimes: a new array over a new buffer.
// engine/src/appattest.ts, which the relay type-checks as it bundles it unchanged, relies on that, so the relay says it
// too, for a string given. Types only: nothing here runs.

declare global {
	interface TextEncoder {
		encode(input: string): Uint8Array<ArrayBuffer>;
	}
}

export {};
