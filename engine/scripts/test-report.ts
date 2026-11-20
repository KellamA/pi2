// A reporter for node's test runner that writes one JSON line per event, for the check at the end of a run (#577):
// which files reported, and what each said. The spec reporter's lines are not enough, as its own output showed: it
// prints nothing for a file whose start and pass arrive after its tests, and a file that ends without reporting
// looks like a pass. The runner reads these lines afterwards (scripts/test-run.ts); a program of its own, as
// check-installed.ts is.

export default async function* report(
	source: AsyncIterable<{ type: string; data?: { name?: string; file?: string } }>,
): AsyncGenerator<string> {
	for await (const event of source) {
		yield `${JSON.stringify({ type: event.type, name: event.data?.name, file: event.data?.file })}\n`;
	}
}
