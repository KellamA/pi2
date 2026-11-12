// The Keychain credential store on its own, against the throwaway Keychain service: long sign-in credentials,
// non-ASCII text, and a damaged item that a new sign-in has to be able to replace. Fake data only.

import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { mkdtempSync, readdirSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Credential } from "@earendil-works/pi-ai";
import { KeychainCredentialStore } from "../src/credentials.ts";

const SERVICE = process.env.PI2_TEST_KEYCHAIN_SERVICE ?? "dev.pi2.credentials.test";
const home = mkdtempSync(join(tmpdir(), "pi2-credentials-test-"));
const store = new KeychainCredentialStore(home, SERVICE);
// Unique to this run, so a second run at the same time (or the app's own tests) is left alone.
const run = `probe-${process.pid}-${Date.now().toString(36)}`;
const long = `${run}-long`;
const garbage = `${run}-garbage`;
const cut = `${run}-cut`;

const security = (...args: string[]) => spawnSync("/usr/bin/security", args, { encoding: "utf8" });
const exists = (account: string) => security("find-generic-password", "-s", SERVICE, "-a", account).status === 0;

function cleanup(): void {
	for (const account of [long, garbage, cut]) {
		security("delete-generic-password", "-s", SERVICE, "-a", account);
		for (let i = 0; i < 100; i++) security("delete-generic-password", "-s", SERVICE, "-a", `${account}:${i}`);
	}
	rmSync(home, { recursive: true, force: true });
}

const oauth = (scale: number) =>
	({ type: "oauth", access: "a".repeat(5 * scale), refresh: "r".repeat(3 * scale), expires: 1234567890, idToken: "x".repeat(6 * scale), note: "non-ascii ✓ é 日本語 🙂 \"quoted\" back\\slash" }) as unknown as Credential;

try {
	// Every size around the one-command limit and well past it comes back exactly.
	for (const scale of [10, 36, 70, 100, 140, 290, 570, 1200]) {
		const credential = oauth(scale);
		const bytes = Buffer.byteLength(JSON.stringify(credential));
		assert.deepEqual(await store.modify(long, async () => credential), credential, `modify returns the credential (${bytes} bytes)`);
		assert.deepEqual(await store.read(long), credential, `a ${bytes}-byte credential reads back exactly`);
	}
	const big = oauth(1200);
	assert.ok(Buffer.byteLength(JSON.stringify(big)) >= 16 * 1024, "the largest one is at least 16 KB");
	assert.deepEqual(await new KeychainCredentialStore(home, SERVICE).read(long), big, "another store instance reads it too");
	assert.ok(exists(`${long}:0`), "a long credential is kept in pieces");
	assert.deepEqual(await store.list(), [{ providerId: long, type: "oauth" }]);
	for (const name of readdirSync(home)) assert.ok(!readFileSync(join(home, name), "utf8").includes("aaaaaaaa"), "no secret on disk");

	// modify hands the current credential to its callback, and leaves it alone when the callback returns nothing.
	assert.deepEqual(await store.modify(long, async (current) => (assert.deepEqual(current, big), undefined)), big);

	// Writes to one provider run one at a time: each sees what the one before stored.
	const counted = await Promise.all([1, 2, 3].map(() => store.modify(long, async (current) => ({ ...big, expires: (current as any).expires + 1 }) as Credential)));
	assert.deepEqual(counted.map((c) => (c as any).expires), [1234567891, 1234567892, 1234567893]);

	// A short credential after a long one is stored whole, readable with `security` alone, and the pieces go away.
	const key = { type: "api_key", key: "sk_test_not_a_real_key" } as unknown as Credential;
	await store.modify(long, async () => key);
	assert.deepEqual(JSON.parse(execFileSync("/usr/bin/security", ["find-generic-password", "-s", SERVICE, "-a", long, "-w"], { encoding: "utf8" })), key);
	assert.ok(!exists(`${long}:0`), "no pieces left behind by the long credential");
	assert.deepEqual(await store.read(long), key);

	// An item that is not JSON reads as no credential, and a new sign-in replaces it.
	assert.equal(security("add-generic-password", "-U", "-s", SERVICE, "-a", garbage, "-w", "not json").status, 0);
	assert.equal(await store.read(garbage), undefined, "a damaged item reads as signed out");
	assert.deepEqual(await store.modify(garbage, async (current) => (assert.equal(current, undefined), big)), big, "modify replaces a damaged item");
	assert.deepEqual(await store.read(garbage), big);

	// What the bug left behind: a credential cut off part-way (which `security` prints as hex), replaced the same way.
	const half = Buffer.from(JSON.stringify(big).slice(0, 1992), "utf8").toString("hex").slice(0, -1);
	spawnSync("/usr/bin/security", ["-i"], { input: `add-generic-password -U -s ${SERVICE} -a ${cut} -X ${half}\n` });
	assert.ok(exists(cut));
	assert.equal(await store.read(cut), undefined, "a cut-off item reads as signed out");
	assert.deepEqual(await store.modify(cut, async () => big), big);
	assert.deepEqual(await store.read(cut), big);

	// A long credential with a piece missing is not half-read.
	security("delete-generic-password", "-s", SERVICE, "-a", `${cut}:1`);
	assert.equal(await store.read(cut), undefined, "a credential with a piece missing reads as signed out");

	// Removing a credential removes all of it.
	for (const account of [long, garbage, cut]) {
		await store.delete(account);
		assert.ok(!exists(account) && !exists(`${account}:0`) && !exists(`${account}:2`), "nothing left in the Keychain");
		assert.equal(await store.read(account), undefined);
	}
	assert.deepEqual(await store.list(), []);
	console.log("PASS credentials");
} finally {
	cleanup();
}
