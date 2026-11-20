// A failed transport attempt uses the generation's durable retry sleep, not a new run. Its count and first failure
// time are kept in that generation's checkpoint, including across engine restarts and retries for another reason.
//
// Two failures are waited out that way: a network that is away, and a stream the provider closed before or during an
// answer (#550). A request the provider answered with an error of its own is neither.
import type { AssistantMessage } from "@earendil-works/pi-ai";

export const NETWORK_RESUMED_ENTRY = "pi2.networkResumed";
const DELAYS = [2_000, 5_000, 15_000, 30_000, 60_000];
/** Where the waits of a provider that asked for less begin: 15 seconds, not 2. */
const ASKED_FOR_LESS_STEP = 2;
const MAX_WAIT = 10 * 60_000;
const scale = Number(process.env.PI2_NETWORK_WAIT_SCALE ?? 1);
const SCALE = Number.isFinite(scale) && scale > 0 ? scale : 1;

const CODES = new Set([
	"ENOTFOUND", "EAI_AGAIN", "ENETUNREACH", "EHOSTUNREACH", "ENETDOWN", "ECONNREFUSED", "ECONNRESET", "ETIMEDOUT",
	"UND_ERR_CONNECT_TIMEOUT", "UND_ERR_HEADERS_TIMEOUT", "UND_ERR_SOCKET",
]);

/** Only inspect an error from the transport, never the assistant's (potentially provider-supplied) wording. */
export function isNetworkError(error: unknown, fromFetch = false): boolean {
	if (!(error instanceof Error)) return false;
	const { code, status, statusCode, $metadata } = error as Error & { code?: string; status?: number; statusCode?: number; $metadata?: { httpStatusCode?: number } };
	if (status !== undefined || statusCode !== undefined || $metadata?.httpStatusCode !== undefined || error.name === "AbortError") return false;
	if (code !== undefined && CODES.has(code)) return true;
	if (error instanceof AggregateError) return error.errors.length > 0 && error.errors.every((each) => isNetworkError(each, fromFetch));
	if (error.cause instanceof Error) return isNetworkError(error.cause, fromFetch);
	// Undici and the SDKs sometimes have no cause to give. Only trust these naked wrappers at the fetch boundary;
	// in an SDK that owns its fetch an untyped Error could come from a provider's stream instead.
	return error.name === "TimeoutError" || (fromFetch && (error.message === "fetch failed" || error.message === "Connection error."));
}

/**
 * A stream the provider closed, rather than a network that is away, and whether it asked for less (#550):
 *
 * - `calm`: HTTP/2's `NGHTTP2_ENHANCE_YOUR_CALM` ("you are sending too much, slow down", which a provider sends when
 *   too many streams are open at once) or its `NGHTTP2_REFUSED_STREAM` ("not another stream just now"). Both ask for
 *   fewer requests, so their waits begin at the longer steps.
 * - `closed`: a connection reset or closed at the other end: `ECONNRESET`, `UND_ERR_SOCKET`, or undici's own words for
 *   them, "terminated" and "other side closed".
 *
 * The message is read too. A stream that dies mid-answer does not throw from `fetch`, so an SDK wraps it and pi-ai
 * flattens the cause chain into the message the run ends with, such as "Connection error.: Stream closed with error code
 * NGHTTP2_ENHANCE_YOUR_CALM (ERR_HTTP2_STREAM_ERROR)"; those technical words are all that is left. Only they are
 * matched, never a provider's own wording, and never on an error carrying a response's status: a request the provider
 * answered is its own fault and is not waited for.
 */
export function closedStream(error: unknown): "calm" | "closed" | undefined {
	if (typeof error === "string") return closedIn(error);
	if (!(error instanceof Error)) return undefined;
	const { code, status, statusCode, $metadata } = error as Error & { code?: unknown; status?: number; statusCode?: number; $metadata?: { httpStatusCode?: number } };
	if (status !== undefined || statusCode !== undefined || $metadata?.httpStatusCode !== undefined || error.name === "AbortError") return undefined;
	if (typeof code === "string" && CLOSED_CODES.has(code)) return closedIn(`${error.message} ${code}`);
	const said = closedIn(error.message);
	if (said !== undefined) return said;
	if (error instanceof AggregateError) {
		for (const each of error.errors) {
			const found = closedStream(each);
			if (found !== undefined) return found;
		}
	}
	return error.cause === undefined ? undefined : closedStream(error.cause);
}

/** Node's and undici's codes for a connection that ended under a request in flight. */
const CLOSED_CODES = new Set(["ECONNRESET", "UND_ERR_SOCKET", "ERR_HTTP2_STREAM_ERROR", "ERR_STREAM_PREMATURE_CLOSE"]);
const ASKED_FOR_LESS = /NGHTTP2_(?:ENHANCE_YOUR_CALM|REFUSED_STREAM)/;
const CLOSED_WORDS = /NGHTTP2_(?:ENHANCE_YOUR_CALM|REFUSED_STREAM)|Stream closed with error code|(?<![a-z])other side closed(?![a-z])|(?<![a-z])terminated(?![a-z])|UND_ERR_SOCKET|ECONNRESET|ERR_HTTP2_STREAM_ERROR/;

function closedIn(text: string): "calm" | "closed" | undefined {
	if (ASKED_FOR_LESS.test(text)) return "calm";
	return CLOSED_WORDS.test(text) ? "closed" : undefined;
}

/** How a request failed at the transport: the network is away, or the provider closed the stream, asking for less or not. */
export type TransportFailure = "network" | "closed" | "calm";

/** How an error from the transport failed the request, if that is what it was. */
export function failureOf(error: unknown, fromFetch = false): TransportFailure | undefined {
	return closedStream(error) ?? (isNetworkError(error, fromFetch) ? "network" : undefined);
}

// SDKs that own their HTTP transport give us the original error before flattening it (see patch-dependencies.ts).
export const SDK_TRANSPORT_ERROR = Symbol.for("pi2.sdkTransportError");
const failures = new WeakMap<AssistantMessage, TransportFailure>();
export const noteTransportFailure = (message: AssistantMessage, failure: TransportFailure): void => { failures.set(message, failure); };
/** How the request that ended with this message failed at the transport, if it did at all. */
export const transportFailureOf = (message: AssistantMessage | undefined): TransportFailure | undefined => (message === undefined ? undefined : failures.get(message));

export type NetworkWait = {
	/** When the first failure of this episode came. */
	since: number;
	/** How many waits it has had. */
	count: number;
	/** The provider closed the stream, rather than the network being away: the conversation says so. */
	closed?: boolean;
	/** It asked for less, so the waits begin at the longer steps. */
	calm?: boolean;
};

export function retryNetwork(current: NetworkWait | undefined, now: number, timeScale = SCALE, failure?: TransportFailure): { waitMs: number | false; network?: NetworkWait } {
	const { since, count } = current ?? { since: now, count: 0 };
	const remaining = MAX_WAIT * timeScale - (now - since);
	if (remaining <= 0) return { waitMs: false };
	const closed = current?.closed === true || (failure !== undefined && failure !== "network");
	const calm = current?.calm === true || failure === "calm";
	const delay = DELAYS[Math.min(count + (calm ? ASKED_FOR_LESS_STEP : 0), DELAYS.length - 1)]!;
	return {
		waitMs: Math.min(delay * timeScale, remaining),
		network: { since, count: count + 1, ...(closed ? { closed: true } : {}), ...(calm ? { calm: true } : {}) },
	};
}
