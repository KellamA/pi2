// A provider's error, as an agent or engine.log is told it: shortened, and with no keys, account identifiers or request
// ids in it. The text comes from the provider (pi-ai keeps its error body in the message), so anything in it may
// identify the account; `delegate` hands it to another model, and people paste engine.log into public issues.

/** The longest an error is kept, in characters, before it is cut with an ellipsis. */
const MAX = 300;

/**
 * How pi²'s own words after a provider's error end, when it ended a run that met a limit (src/limitwait.ts): a paragraph
 * of its own, after the provider's, kept whole however long the provider's was.
 */
export const CARRY_ON = "Continue the conversation to try again.";

/** What is taken out, and what stands in its place. Order matters: the specific before the general. */
const HIDDEN: [RegExp, string][] = [
	// Request ids, as a field or on their own.
	[/["']?request[_-]?id["']?\s*[:=]\s*["']?[\w-]+["']?,?/gi, ""],
	[/\breq_[A-Za-z0-9]{6,}\b/g, "[request]"],
	// Keys and tokens.
	[/\bBearer\s+[\w.~+/=-]+/gi, "Bearer [hidden]"],
	[/\b(?:sk|pk|rk)-[\w-]{8,}/g, "[key]"],
	[/\b(?:xai|gsk|ghp|gho|ghu|github_pat|AIza)[\w-]{10,}/g, "[key]"],
	// Accounts, organisations, projects and the like.
	[/\b(?:org|acct|account|user|proj|project|ws|workspace)[-_][A-Za-z0-9]{6,}\b/gi, "[id]"],
	[/\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/gi, "[id]"],
	[/[\w.+-]+@[\w-]+\.[\w.-]+/g, "[email]"],
	// Anything else that looks like a token: a long unbroken run of letters and digits with both in it.
	[/\b(?=[\w-]*\d)(?=[\w-]*[A-Za-z])[\w-]{32,}\b/g, "[id]"],
];

/**
 * The provider's own words for an error: an error body pi-ai put in the message ("429 {\"type\":\"error\",\"error\":{…}}")
 * read as "429 rate_limit_error: This request would …", the rest as it is.
 */
function readable(text: string): string {
	const brace = text.indexOf("{");
	if (brace === -1) return text;
	const head = text.slice(0, brace).replace(/[\s:]+$/, "");
	try {
		const body = JSON.parse(text.slice(brace)) as Record<string, unknown>;
		const error = (body.error !== null && typeof body.error === "object" ? body.error : body) as Record<string, unknown>;
		const type = typeof error.type === "string" && error.type !== "error" ? error.type : typeof error.code === "string" ? error.code : "";
		const message = typeof error.message === "string" ? error.message : "";
		if (message === "" && type === "") return text;
		return [head, [type, message].filter((part) => part !== "").join(": ")].filter((part) => part !== "").join(" ");
	} catch {
		return text;
	}
}

/** A provider's error, shortened to a few lines' worth, with keys and identifiers taken out. */
export function plainProviderError(text: string, max = MAX): string {
	let provider = text.trim();
	let own = "";
	const split = provider.lastIndexOf("\n\n");
	if (provider.endsWith(CARRY_ON) && split !== -1) {
		own = provider.slice(split + 2).replace(/\s+/g, " ").trim();
		provider = provider.slice(0, split).trim();
	}
	let plain = readable(provider);
	for (const [pattern, replacement] of HIDDEN) plain = plain.replace(pattern, replacement);
	plain = plain.replace(/\s+/g, " ").trim();
	if (plain.length > max) plain = `${plain.slice(0, max - 1).trimEnd()}…`;
	return own === "" ? plain : `${plain} ${own}`;
}
