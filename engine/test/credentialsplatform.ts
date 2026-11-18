// The file stand-in is selected only off macOS; on a Mac even a direct call cannot create one.
import assert from "node:assert/strict";
import { mkdtempSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Credential } from "@earendil-works/pi-ai";
import { credentialStore, KeychainCredentialStore } from "../src/credentials.ts";
import { testCredentials } from "../src/testcredentials.ts";

const home = mkdtempSync(join(tmpdir(), "pi2-credential-platform-"));
try {
	const store = credentialStore(home);
	if (process.platform === "darwin") {
		assert.ok(store instanceof KeychainCredentialStore);
		assert.throws(() => testCredentials(home), /not available on macOS/);
		assert.deepEqual(readdirSync(home), [], "no credential file can be made on a Mac");
	} else {
		assert.ok(!(store instanceof KeychainCredentialStore));
		assert.equal(await store.read("test"), undefined);
		assert.equal(await store.read("constructor"), undefined);
		assert.deepEqual(await store.list(), []);
		const key: Credential = { type: "api_key", key: "fake-test-key-✓" };
		assert.deepEqual(await store.modify("test", async () => key), key);
		assert.deepEqual(await credentialStore(home).read("test"), key, "survives a restart");
		assert.deepEqual(await store.list(), [{ providerId: "test", type: "api_key" }]);
		assert.equal(statSync(join(home, "test-credentials.json")).mode & 0o777, 0o600);
		assert.deepEqual(await store.modify("test", async (current) => (assert.deepEqual(current, key), undefined)), key);
		const values = await Promise.all([1, 2, 3].map(() => store.modify("test", async (current) => ({ type: "api_key", key: `${(current as typeof key).key}!` }))));
		assert.deepEqual(values.map((value) => (value as typeof key).key), [key.key + "!", key.key + "!!", key.key + "!!!"]);
		await assert.rejects(store.modify("test", async () => { throw new Error("refused"); }), /refused/);
		await Promise.all(["test", "other", "__proto__"].map((id) => store.modify(id, async () => key)));
		for (const id of ["test", "other", "__proto__", "absent"]) await store.delete(id);
		assert.deepEqual(await store.list(), []);
		assert.equal(await store.read("__proto__"), undefined);
		writeFileSync(join(home, "test-credentials.json"), "broken");
		await assert.rejects(store.read("test"), SyntaxError, "a broken file is not silently overwritten");
	}
	console.log("PASS credentialsplatform");
} finally {
	rmSync(home, { recursive: true, force: true });
}
