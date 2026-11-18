// Downloading one large file, checked, for models on this Mac (#292). A file grows in `<name>.part` beside where it
// goes, so a download stopped by a pause, pi² quitting, the engine restarting or the network dropping carries on from
// where it stopped, with an HTTP range request. Its SHA-256 is worked out as it arrives (and from the part already on
// disk when it carries on), and only a file whose size and checksum are the ones pi² knew in advance is moved to its
// place. A file that does not match is deleted.

import { createHash, type Hash } from "node:crypto";
import { createReadStream, existsSync, renameSync, rmSync, statSync, truncateSync } from "node:fs";
import { open } from "node:fs/promises";
import type { CatalogFile } from "./localcatalog.ts";

/**
 * Why a download did not finish. `retry`: trying again soon may work (the network, a stall, a server's own trouble);
 * the others need the person, or a pi² update.
 */
export type FailureKind = "network" | "stalled" | "server" | "refused" | "mismatch" | "space" | "stopped";

export class DownloadError extends Error {
	readonly kind: FailureKind;
	readonly retry: boolean;
	constructor(kind: FailureKind, message: string) {
		super(message);
		this.kind = kind;
		this.retry = kind === "network" || kind === "stalled" || kind === "server";
	}
}

export type DownloadOptions = {
	/** Aborting it stops the download and keeps what it has; the reason is passed on as the error's message. */
	signal: AbortSignal;
	/** No bytes for this long counts as a dropped connection. */
	stallMs: number;
	/** How many times to try again after a failure that may pass, waiting longer each time, before giving up. */
	retries: number;
	/** The first wait before trying again; each later one is twice as long, up to a minute. */
	retryMs: number;
	/** Bytes of this file on disk so far. */
	progress(received: number): void;
	/** Reading the part already on disk to carry its checksum on, before asking for the rest. */
	checking?(): void;
	/** About to try again after `error`, in `delayMs`. */
	retrying?(error: DownloadError, delayMs: number): void;
};

/** The host a file comes from, for a message. */
export function hostOf(url: string): string {
	try {
		return new URL(url).host;
	} catch {
		return url;
	}
}

/** Only HTTPS, apart from a stand-in on this Mac's loopback address, which only a test can name. */
export function allowedUrl(url: string): boolean {
	try {
		const parsed = new URL(url);
		return parsed.protocol === "https:" || (parsed.protocol === "http:" && parsed.hostname === "127.0.0.1");
	} catch {
		return false;
	}
}

const sizeOf = (path: string) => (existsSync(path) ? statSync(path).size : 0);

/** Downloads `file` to `dest` and checks it, carrying on from `dest.part` if there is one. Throws a `DownloadError`. */
export async function download(file: CatalogFile, dest: string, options: DownloadOptions): Promise<void> {
	if (!allowedUrl(file.url)) throw new DownloadError("refused", `pi² downloads only over HTTPS, and ${file.url} is not.`);
	const part = `${dest}.part`;
	// The checksum of the first `hashed` bytes of the part, carried from one try to the next.
	let state: { hash: Hash; hashed: number } | undefined;
	for (let attempt = 0; ; attempt++) {
		try {
			state = await once(file, part, options, state);
			break;
		} catch (error) {
			const failure = asFailure(error, file, options.signal);
			// What does not match is not kept: trying again starts from nothing.
			if (failure.kind === "mismatch") rmSync(part, { force: true });
			if (!failure.retry || attempt >= options.retries) throw failure;
			const delay = Math.min(options.retryMs * 2 ** attempt, 60_000);
			options.retrying?.(failure, delay);
			await wait(delay, options.signal).catch(() => {
				throw asFailure(undefined, file, options.signal);
			});
		}
	}
	const digest = state.hash.digest("hex");
	if (digest !== file.sha256) {
		rmSync(part, { force: true });
		throw mismatch(file);
	}
	renameSync(part, dest);
}

function mismatch(file: CatalogFile): DownloadError {
	return new DownloadError(
		"mismatch",
		`The file downloaded from ${hostOf(file.url)} is not the one pi² expected: its checksum does not match. It was deleted, and nothing in it was run. Try again; if it happens again, the file on the server has changed, and pi² needs an update before it can use it.`,
	);
}

/** One request: the rest of the file into the part. Returns the checksum of all of it once the part is whole. */
async function once(
	file: CatalogFile,
	part: string,
	options: DownloadOptions,
	carried: { hash: Hash; hashed: number } | undefined,
): Promise<{ hash: Hash; hashed: number }> {
	let have = sizeOf(part);
	if (have > file.size) {
		truncateSync(part, 0);
		have = 0;
	}
	let state = carried !== undefined && carried.hashed === have ? carried : undefined;
	if (state === undefined) {
		state = { hash: createHash("sha256"), hashed: 0 };
		if (have > 0) {
			options.checking?.();
			for await (const chunk of createReadStream(part, { signal: options.signal })) {
				state.hash.update(chunk as Buffer);
				state.hashed += (chunk as Buffer).length;
			}
		}
	}
	options.progress(have);
	if (have === file.size) return state;

	const controller = new AbortController();
	const stop = () => controller.abort(options.signal.reason);
	options.signal.addEventListener("abort", stop, { once: true });
	let stalled = false;
	let timer: NodeJS.Timeout | undefined;
	const watch = () => {
		clearTimeout(timer);
		timer = setTimeout(() => {
			stalled = true;
			controller.abort("stalled");
		}, options.stallMs);
	};
	watch();
	try {
		let response: Response;
		try {
			response = await fetch(file.url, { headers: have > 0 ? { range: `bytes=${have}-` } : {}, signal: controller.signal, redirect: "follow" });
		} catch (error) {
			if (stalled) throw stalledError(file);
			throw error;
		}
		if (!allowedUrl(response.url)) throw new DownloadError("refused", `${hostOf(file.url)} sent the download on to an address that is not HTTPS, so pi² did not follow it.`);
		if (response.status === 416 && have > 0) {
			// The server will not give the part asked for: start again from nothing.
			truncateSync(part, 0);
			throw new DownloadError("server", `${hostOf(file.url)} would not carry on the download where it stopped.`);
		}
		if (response.status === 429 || response.status >= 500) {
			throw new DownloadError("server", `${hostOf(file.url)} is having trouble (HTTP ${response.status}${response.statusText ? ` ${response.statusText}` : ""}). Try again later; the download carries on from where it stopped.`);
		}
		if (response.status !== 200 && response.status !== 206) {
			throw new DownloadError(
				"refused",
				`${hostOf(file.url)} refused the download (HTTP ${response.status}${response.statusText ? ` ${response.statusText}` : ""}). The file may have moved or been withdrawn; a newer pi² may know where it is now.`,
			);
		}
		let start = 0;
		if (response.status === 206) {
			const range = /^bytes (\d+)-(\d+)\/(\d+|\*)$/.exec(response.headers.get("content-range") ?? "");
			if (range === null || Number(range[1]) !== have) {
				truncateSync(part, 0);
				throw new DownloadError("server", `${hostOf(file.url)} sent another part of the file than the one asked for.`);
			}
			if (range[3] !== "*" && Number(range[3]) !== file.size) throw mismatch(file);
			start = have;
		} else if (have > 0) {
			// The server sends the whole file again: start the part, and its checksum, from nothing.
			truncateSync(part, 0);
			state = { hash: createHash("sha256"), hashed: 0 };
		}
		const length = response.headers.get("content-length");
		if (length !== null && start + Number(length) !== file.size) throw mismatch(file);
		if (response.body === null) throw new DownloadError("network", `${hostOf(file.url)} sent nothing.`);

		const handle = await open(part, start === 0 ? "w" : "a");
		let received = start;
		try {
			for await (const chunk of response.body) {
				watch();
				if (received + chunk.length > file.size) throw mismatch(file);
				await handle.write(chunk);
				state.hash.update(chunk);
				received += chunk.length;
				state.hashed = received;
				options.progress(received);
			}
		} catch (error) {
			if (stalled) throw stalledError(file);
			if (error instanceof DownloadError || options.signal.aborted || (error as { code?: string }).code === "ENOSPC") throw error;
			throw new DownloadError("network", `The connection to ${hostOf(file.url)} dropped during the download. Check the network connection; the download carries on from where it stopped.`);
		} finally {
			await handle.close().catch(() => {});
		}
		if (received < file.size) throw new DownloadError("network", `The connection to ${hostOf(file.url)} closed before the whole file arrived. The download carries on from where it stopped.`);
		return state;
	} finally {
		clearTimeout(timer);
		options.signal.removeEventListener("abort", stop);
	}
}

function stalledError(file: CatalogFile): DownloadError {
	return new DownloadError("stalled", `Nothing arrived from ${hostOf(file.url)} for a while, so pi² dropped the connection.`);
}

/** Any error, as a `DownloadError` with a message a person can act on. */
function asFailure(error: unknown, file: CatalogFile, signal: AbortSignal): DownloadError {
	if (signal.aborted) return new DownloadError("stopped", typeof signal.reason === "string" ? signal.reason : "stopped");
	if (error instanceof DownloadError) return error;
	const code = (error as { code?: string; cause?: { code?: string } } | undefined)?.code ?? (error as { cause?: { code?: string } } | undefined)?.cause?.code;
	if (code === "ENOSPC") return new DownloadError("space", "The disk filled up during the download. Free up some space, then press Resume: it carries on from where it stopped.");
	if (code === "EACCES" || code === "EPERM" || code === "EROFS") return new DownloadError("refused", "pi² cannot write to the folder the download goes to. Choose another folder for models.");
	return new DownloadError("network", `pi² could not reach ${hostOf(file.url)}. Check the network connection; the download carries on from where it stopped.`);
}

function wait(ms: number, signal: AbortSignal): Promise<void> {
	return new Promise((resolve, reject) => {
		if (signal.aborted) return reject(signal.reason);
		const timer = setTimeout(() => {
			signal.removeEventListener("abort", stop);
			resolve();
		}, ms);
		const stop = () => {
			clearTimeout(timer);
			reject(signal.reason);
		};
		signal.addEventListener("abort", stop, { once: true });
	});
}
