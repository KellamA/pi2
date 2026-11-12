// Credentials in the macOS login Keychain, one generic-password item per provider.
//
// Secrets never touch the engine's own files or its command line: writes go to `security -i` over stdin as hex.
// A small index file next to the database lists which providers have a credential and of what type, so listing
// never reads a secret.

import { spawn } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { Credential, CredentialInfo, CredentialStore } from "@earendil-works/pi-ai";

const SECURITY = "/usr/bin/security";
const NOT_FOUND = 44;

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

function checkId(providerId: string): void {
	if (!/^[A-Za-z0-9._-]{1,80}$/.test(providerId)) throw new Error(`Invalid provider id: ${providerId}`);
}

/** ASCII-only JSON, so `security -w` prints it back as text and never as hex. */
function encode(credential: Credential): string {
	return JSON.stringify(credential).replace(/[\u007f-￿]/g, (c) => `\\u${c.charCodeAt(0).toString(16).padStart(4, "0")}`);
}

export class KeychainCredentialStore implements CredentialStore {
	readonly #service: string;
	readonly #indexPath: string;
	readonly #locks = new Map<string, Promise<unknown>>();

	constructor(home: string, service = process.env.PI2_KEYCHAIN_SERVICE ?? "dev.pi2.credentials") {
		if (!/^[A-Za-z0-9._-]+$/.test(service)) throw new Error("Invalid keychain service name");
		this.#service = service;
		this.#indexPath = join(home, "credentials.json");
	}

	async read(providerId: string): Promise<Credential | undefined> {
		checkId(providerId);
		const result = await run(["find-generic-password", "-s", this.#service, "-a", providerId, "-w"]);
		if (result.code === NOT_FOUND) return undefined;
		if (result.code !== 0) throw new Error(`Keychain read failed (${result.code}): ${result.stderr.trim()}`);
		try {
			return JSON.parse(result.stdout.trim()) as Credential;
		} catch {
			throw new Error(`The stored credential for ${providerId} is unreadable`);
		}
	}

	async list(): Promise<readonly CredentialInfo[]> {
		return Object.entries(this.#index()).map(([providerId, type]) => ({ providerId, type }));
	}

	modify(providerId: string, fn: (current: Credential | undefined) => Promise<Credential | undefined>): Promise<Credential | undefined> {
		checkId(providerId);
		// One read-modify-write at a time per provider, so two requests never refresh a rotated token twice.
		const previous = this.#locks.get(providerId) ?? Promise.resolve();
		const next = previous.catch(() => {}).then(async () => {
			const current = await this.read(providerId);
			const updated = await fn(current);
			if (updated === undefined) return current;
			const hex = Buffer.from(encode(updated), "utf8").toString("hex");
			await run(["-i"], `add-generic-password -U -s ${this.#service} -a ${providerId} -l "pi2: ${providerId}" -X ${hex}\n`);
			const stored = await this.read(providerId);
			if (stored === undefined || encode(stored) !== encode(updated)) throw new Error("The Keychain did not accept the credential");
			this.#writeIndex({ ...this.#index(), [providerId]: updated.type });
			return updated;
		});
		this.#locks.set(providerId, next);
		return next;
	}

	async delete(providerId: string): Promise<void> {
		checkId(providerId);
		const result = await run(["delete-generic-password", "-s", this.#service, "-a", providerId]);
		if (result.code !== 0 && result.code !== NOT_FOUND) throw new Error(`Keychain delete failed: ${result.stderr.trim()}`);
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
