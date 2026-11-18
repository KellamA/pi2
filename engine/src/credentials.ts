// Credentials in the macOS login Keychain, one generic-password item per provider. The values of the variables a person
// gives an agent are kept the same way, under the same service, in an item per agent named `variables/<agent>`
// (variables.ts); "/" is not allowed in a provider id, so that can never be mistaken for a provider either.
//
// Secrets never touch the engine's own files or its command line: writes go to `security -i` over stdin as hex.
// A small index file next to the database lists which providers have a credential and of what type, so listing
// never reads a secret.
//
// `security -i` reads its commands in lines of at most 4095 bytes; anything longer is silently cut and the rest is
// run as a second, unknown command. That leaves room for about 1.9 KB of secret per command, which an API key fits
// and a sign-in (access, refresh and id tokens: several KB) does not. `security` has no other way to take a secret
// that is not the command line (its password prompt stops at 128 bytes). So a long credential is split over several
// items: the provider's own item holds a small manifest, and items named `<provider>:<n>` hold the pieces. ":" is
// not allowed in a provider id, so a piece can never be mistaken for a provider.

import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { Credential, CredentialInfo, CredentialStore } from "@earendil-works/pi-ai";

import { testCredentials } from "./testcredentials.ts";

/** macOS always uses Keychain. Other platforms have a file stand-in for tests, not a supported pi² runtime. */
export function credentialStore(home: string): CredentialStore {
	return process.platform === "darwin" ? new KeychainCredentialStore(home) : testCredentials(home);
}

const SECURITY = "/usr/bin/security";
const NOT_FOUND = 44;
/** Longest command line `security -i` takes whole is 4095 bytes; stay clear of it. */
const MAX_COMMAND = 3900;
/** Bytes of credential per Keychain item (twice that as hex on the command). */
const PART_BYTES = 1500;
const MANIFEST = "pi2-parts-v1";

type Manifest = { format: typeof MANIFEST; parts: number; sha256: string };

function run(args: string[], stdin?: string): Promise<{ code: number; stdout: string; stderr: string }> {
	return new Promise((resolve, reject) => {
		const child = spawn(SECURITY, args, { stdio: [stdin === undefined ? "ignore" : "pipe", "pipe", "pipe"] });
		let stdout = "";
		let stderr = "";
		child.stdout!.setEncoding("utf8").on("data", (chunk: string) => (stdout += chunk));
		child.stderr!.setEncoding("utf8").on("data", (chunk: string) => (stderr += chunk));
		child.on("error", reject);
		child.on("close", (code) => resolve({ code: code ?? 1, stdout, stderr }));
		// `security` may exit before it reads its input; that shows in its exit code, not as a crash here.
		child.stdin?.on("error", () => {});
		child.stdin?.end(stdin);
	});
}

/** The Keychain service pi²'s secrets are kept under: the usual one, or the one PI2_KEYCHAIN_SERVICE names. */
export const keychainService = (env: NodeJS.ProcessEnv = process.env): string => env.PI2_KEYCHAIN_SERVICE ?? "dev.pi2.credentials";

function checkId(providerId: string): void {
	if (!/^[A-Za-z0-9._-]{1,80}$/.test(providerId)) throw new Error(`Invalid provider id: ${providerId}`);
}

/** An account is written into a `security -i` command line as it is, so it may hold no space, quote or backslash. */
function checkAccount(account: string): void {
	if (!/^[A-Za-z0-9._/-]{1,200}$/.test(account)) throw new Error(`Invalid Keychain account: ${account}`);
}

/** ASCII-only JSON, so `security -w` prints it back as text and never as hex. */
function encode(value: object): string {
	return JSON.stringify(value).replace(/[\u007f-\uffff]/g, (c) => `\\u${c.charCodeAt(0).toString(16).padStart(4, "0")}`);
}

function sha256(text: string): string {
	return createHash("sha256").update(text, "utf8").digest("hex");
}

/** A JSON object out of what `security -w` printed, which is hex when the value is not plain text. Undefined if it is neither. */
function parseObject(text: string): Record<string, unknown> | undefined {
	const candidates = [text];
	if (text.length % 2 === 0 && /^[0-9a-fA-F]+$/.test(text)) candidates.push(Buffer.from(text, "hex").toString("utf8"));
	for (const candidate of candidates) {
		try {
			const value: unknown = JSON.parse(candidate);
			if (typeof value === "object" && value !== null && !Array.isArray(value)) return value as Record<string, unknown>;
		} catch {}
	}
	return undefined;
}

function isManifest(value: Record<string, unknown>): value is Manifest {
	return value.format === MANIFEST && Number.isInteger(value.parts) && (value.parts as number) > 0 && (value.parts as number) < 1000 && typeof value.sha256 === "string";
}

/**
 * JSON objects in Keychain items of one service, one to an account, in pieces when long (see the top of this file).
 * The credential store keeps providers' sign-ins with it, and variables.ts the values of agents' variables.
 */
export class KeychainObjects {
	readonly service: string;
	readonly #locks = new Map<string, Promise<unknown>>();

	constructor(service = keychainService()) {
		if (!/^[A-Za-z0-9._-]+$/.test(service)) throw new Error("Invalid keychain service name");
		this.service = service;
	}

	/** Run `change` once every change to `account` begun before it has ended: one read-modify-write at a time. */
	exclusive<T>(account: string, change: () => Promise<T>): Promise<T> {
		const previous = this.#locks.get(account) ?? Promise.resolve();
		const next = previous.catch(() => {}).then(change);
		this.#locks.set(account, next);
		return next;
	}

	/**
	 * The object kept for `account`, or undefined when there is none. A stored item that cannot be understood (damaged,
	 * cut short, pieces missing) also reads as none, and writing a new one overwrites it.
	 */
	async read(account: string): Promise<Record<string, unknown> | undefined> {
		checkAccount(account);
		const text = await this.#find(account);
		if (text === undefined) return undefined;
		const value = parseObject(text);
		if (value === undefined) return undefined;
		if (!isManifest(value)) return value;
		const parts = await Promise.all(Array.from({ length: value.parts }, (_, i) => this.#find(`${account}:${i}`)));
		if (parts.some((part) => part === undefined)) return undefined;
		const json = parts.join("");
		if (sha256(json) !== value.sha256) return undefined;
		return parseObject(json);
	}

	/** Keep `value` for `account`, read it back to be sure it is there whole, and remove the pieces it no longer uses. */
	async write(account: string, value: object, what = "it"): Promise<void> {
		checkAccount(account);
		const json = encode(value);
		const before = await this.#partCount(account);
		const parts = await this.#write(account, json);
		const stored = await this.read(account);
		if (stored === undefined || encode(stored) !== json) throw new Error(`The Keychain did not accept ${what}`);
		await this.#deleteParts(account, parts, before);
	}

	/** Remove what is kept for `account`, all of its pieces too. Nothing kept is not an error. */
	async delete(account: string): Promise<void> {
		checkAccount(account);
		const before = await this.#partCount(account);
		const result = await run(["delete-generic-password", "-s", this.service, "-a", account]);
		if (result.code !== 0 && result.code !== NOT_FOUND) throw new Error(`Keychain delete failed: ${result.stderr.trim()}`);
		await this.#deleteParts(account, 0, before);
	}

	/** One item's value as `security` prints it, or undefined when there is no such item. */
	async #find(account: string): Promise<string | undefined> {
		const result = await run(["find-generic-password", "-s", this.service, "-a", account, "-w"]);
		if (result.code === NOT_FOUND) return undefined;
		if (result.code !== 0) throw new Error(`Keychain read failed (${result.code}): ${result.stderr.trim()}`);
		return result.stdout.trim();
	}

	/** Stores the JSON, whole if it fits one command and in pieces behind a manifest if not. Returns how many pieces it used. */
	async #write(account: string, json: string): Promise<number> {
		const command = (name: string, value: string) => `add-generic-password -U -s ${this.service} -a ${name} -l "pi2: ${name}" -X ${Buffer.from(value, "utf8").toString("hex")}`;
		const whole = command(account, json);
		const commands: string[] = [];
		if (whole.length <= MAX_COMMAND) commands.push(whole);
		else {
			// Pieces first, manifest last: until the manifest lands, the old one still names the old checksum.
			for (let offset = 0; offset < json.length; offset += PART_BYTES) commands.push(command(`${account}:${commands.length}`, json.slice(offset, offset + PART_BYTES)));
			const manifest: Manifest = { format: MANIFEST, parts: commands.length, sha256: sha256(json) };
			commands.push(command(account, JSON.stringify(manifest)));
		}
		if (commands.some((line) => line.length > MAX_COMMAND)) throw new Error("It is too long for the Keychain");
		// What `security` prints here can quote its input, so it is never passed on; the caller reads the value back instead.
		await run(["-i"], commands.map((line) => `${line}\n`).join(""));
		return commands.length - 1;
	}

	/** How many pieces the stored object says it has: 0 when it is stored whole, damaged or absent. */
	async #partCount(account: string): Promise<number> {
		const value = parseObject((await this.#find(account)) ?? "");
		return value !== undefined && isManifest(value) ? value.parts : 0;
	}

	/**
	 * Removes the pieces numbered `from` and up, which a shorter or removed object no longer uses. It goes on to the
	 * first number that has no item, and at least as far as `known`, so a gap does not hide later pieces.
	 */
	async #deleteParts(account: string, from: number, known: number): Promise<void> {
		for (let i = from; ; i++) {
			const result = await run(["delete-generic-password", "-s", this.service, "-a", `${account}:${i}`]);
			if (result.code === NOT_FOUND && i >= known) return;
			if (result.code !== 0 && result.code !== NOT_FOUND) throw new Error(`Keychain delete failed: ${result.stderr.trim()}`);
		}
	}
}

/**
 * Providers' credentials, one object to a provider, its account named by the provider's id. A small index file next to
 * the database lists which providers have a credential and of what type, so listing never reads a secret.
 */
export class KeychainCredentialStore implements CredentialStore {
	readonly #items: KeychainObjects;
	readonly #indexPath: string;

	constructor(home: string, service = keychainService()) {
		this.#items = new KeychainObjects(service);
		this.#indexPath = join(home, "credentials.json");
	}

	/**
	 * The provider's credential, or undefined when there is none. A stored item that cannot be understood (damaged,
	 * cut short, pieces missing) also reads as none: the provider then shows as signed out, and signing in again
	 * overwrites it.
	 */
	async read(providerId: string): Promise<Credential | undefined> {
		checkId(providerId);
		return (await this.#items.read(providerId)) as Credential | undefined;
	}

	async list(): Promise<readonly CredentialInfo[]> {
		return Object.entries(this.#index()).map(([providerId, type]) => ({ providerId, type }));
	}

	modify(providerId: string, fn: (current: Credential | undefined) => Promise<Credential | undefined>): Promise<Credential | undefined> {
		checkId(providerId);
		// One read-modify-write at a time per provider, so two requests never refresh a rotated token twice.
		return this.#items.exclusive(providerId, async () => {
			const current = await this.read(providerId);
			const updated = await fn(current);
			if (updated === undefined) return current;
			await this.#items.write(providerId, updated, "the credential");
			this.#writeIndex({ ...this.#index(), [providerId]: updated.type });
			return updated;
		});
	}

	async delete(providerId: string): Promise<void> {
		checkId(providerId);
		await this.#items.delete(providerId);
		const index = this.#index();
		delete index[providerId];
		this.#writeIndex(index);
	}

	#index(): Record<string, Credential["type"]> {
		try {
			return JSON.parse(readFileSync(this.#indexPath, "utf8"));
		} catch {
			return {};
		}
	}

	#writeIndex(index: Record<string, Credential["type"]>): void {
		writeFileSync(this.#indexPath, JSON.stringify(index, null, "\t"));
	}
}
