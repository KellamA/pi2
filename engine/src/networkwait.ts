// A failed transport attempt uses the generation's durable retry sleep, not a new run. Its count and first failure
// time are kept in that generation's checkpoint, including across engine restarts and retries for another reason.
import type { AssistantMessage } from "@earendil-works/pi-ai";

export const NETWORK_RESUMED_ENTRY = "pi2.networkResumed";
const DELAYS = [2_000, 5_000, 15_000, 30_000, 60_000];
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

// SDKs that own their HTTP transport give us the original error before flattening it (see patch-dependencies.ts).
export const SDK_TRANSPORT_ERROR = Symbol.for("pi2.sdkTransportError");
const failures = new WeakSet<AssistantMessage>();
export const noteNetworkFailure = (message: AssistantMessage): void => { failures.add(message); };
export const networkFailure = (message: AssistantMessage | undefined): boolean => message !== undefined && failures.has(message);

export type NetworkWait = { since: number; count: number };

export function retryNetwork(current: NetworkWait | undefined, now: number, timeScale = SCALE): { waitMs: number | false; network?: NetworkWait } {
	const { since, count } = current ?? { since: now, count: 0 };
	const remaining = MAX_WAIT * timeScale - (now - since);
	if (remaining <= 0) return { waitMs: false };
	const delay = DELAYS[Math.min(count, DELAYS.length - 1)]!;
	return { waitMs: Math.min(delay * timeScale, remaining), network: { since, count: count + 1 } };
}
