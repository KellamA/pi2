// Stand-in credentials for engine tests on systems without a Keychain. This is NOT a supported way to run pi².
// Never available on macOS: the guard is the actual platform, not a setting or an environment variable.

import { readFileSync, renameSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { Credential, CredentialInfo, CredentialStore } from "@earendil-works/pi-ai";

export function testCredentials(home: string): CredentialStore {
	if (process.platform === "darwin") throw new Error("The test credential file is not available on macOS");
	return new TestCredentials(home);
}

class TestCredentials implements CredentialStore {
	readonly #path: string;
	readonly #locks = new Map<string, Promise<unknown>>();

	constructor(home: string) {
		this.#path = join(home, "test-credentials.json");
	}

	#all(): Record<string, Credential> {
		try {
			return JSON.parse(readFileSync(this.#path, "utf8"));
		} catch (error) {
			if ((error as NodeJS.ErrnoException).code === "ENOENT") return {};
			throw error;
		}
	}

	#save(all: Record<string, Credential>): void {
		// One engine writes a data folder. Synchronous read/write and an atomic rename keep changes to different
		// providers from losing each other, and an interrupted write from leaving half a credential.
		writeFileSync(`${this.#path}.new`, JSON.stringify(all), { mode: 0o600 });
		renameSync(`${this.#path}.new`, this.#path);
	}

	async read(providerId: string): Promise<Credential | undefined> {
		const all = this.#all();
		return Object.hasOwn(all, providerId) ? all[providerId] : undefined;
	}

	async list(): Promise<readonly CredentialInfo[]> {
		return Object.entries(this.#all()).map(([providerId, credential]) => ({ providerId, type: credential.type }));
	}

	modify(providerId: string, fn: (current: Credential | undefined) => Promise<Credential | undefined>): Promise<Credential | undefined> {
		const previous = this.#locks.get(providerId) ?? Promise.resolve();
		const next = previous.catch(() => {}).then(async () => {
			const current = await this.read(providerId);
			const updated = await fn(current);
			if (updated === undefined) return current;
			const all = this.#all();
			Object.defineProperty(all, providerId, { value: updated, enumerable: true, configurable: true, writable: true });
			this.#save(all);
			return updated;
		});
		this.#locks.set(providerId, next);
		return next;
	}

	async delete(providerId: string): Promise<void> {
		const all = this.#all();
		delete all[providerId];
		this.#save(all);
	}
}
