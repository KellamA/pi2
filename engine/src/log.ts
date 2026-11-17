// engine.log: the engine's standard output and standard error, which the app and the login item send to that file.
//
// Every line of it starts with the time it was written, so that a line can be placed after the fact: which start of the
// engine it belongs to, and how long anything took. The time is put on where the lines leave the process, not where
// they are made, so that a line from a dependency, or one Node writes itself (a warning), gets one as well as the
// engine's own. See "engine.log" in docs/architecture.md for the format.

/** The time at the start of a line: ISO 8601 in UTC, to the second, as app.log has it (`2026-11-16T18:03:12Z`). */
export function stamp(date: Date): string {
	return date.toISOString().replace(/\.\d+Z$/, "Z");
}

type Writable = { write: NodeJS.WriteStream["write"] };

/**
 * From now on, put the time at the start of each line written to `stream`: the first one written, and each one after a
 * newline. A line written in several pieces gets one time, the time of its first piece; a write of several lines gets
 * the same time on each. Kept per stream, so a line one stream leaves unfinished is not taken as finished by the other.
 */
export function timeLines(stream: Writable, now: () => Date = () => new Date()): void {
	const write = stream.write.bind(stream) as (chunk: Uint8Array, callback?: (error?: Error | null) => void) => boolean;
	let atStart = true;
	stream.write = ((chunk: string | Uint8Array, encoding?: BufferEncoding | ((error?: Error | null) => void), callback?: (error?: Error | null) => void) => {
		const done = typeof encoding === "function" ? encoding : callback;
		// Worked in bytes, so a character split between two writes is left as it is.
		const data = typeof chunk === "string" ? Buffer.from(chunk, typeof encoding === "string" ? encoding : "utf8") : Buffer.from(chunk.buffer, chunk.byteOffset, chunk.byteLength);
		const time = stamp(now());
		const parts: Buffer[] = [];
		for (let from = 0; from < data.length; ) {
			const newline = data.indexOf(0x0a, from);
			const to = newline === -1 ? data.length : newline + 1;
			// An empty line gets the time alone, without a space trailing after it.
			if (atStart) parts.push(Buffer.from(newline === from ? time : `${time} `));
			parts.push(data.subarray(from, to));
			atStart = newline !== -1;
			from = to;
		}
		return write(Buffer.concat(parts), done);
	}) as NodeJS.WriteStream["write"];
}
