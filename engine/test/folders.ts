// What a paired phone may see of the Mac's folders and files (#698, docs/iphone.md 4.2 and 5.7): `projects.folders` and
// `files.preview` (engine/src/folders.ts). First what needs no engine: reading a link's target as the conversation's
// page does, and a file swapped between the check and the read, with a stand-in engine in this process. Then a real
// engine on a throwaway data folder, driven over its socket: which folders it offers and which it never does, and every
// refusal of `files.preview` with its words. engine/test/devices.ts sends both from a phone in a session, with
// `projects.create` given a folder offered and one not.

import assert from "node:assert/strict";
import { type ChildProcess, execFileSync, spawn } from "node:child_process";
import { appendFileSync, linkSync, mkdirSync, mkdtempSync, realpathSync, renameSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { AgentDoc } from "@earendil-works/pi-durable";
import { folderOffered } from "../src/answers.ts";
import type { Engine } from "../src/features.ts";
import {
	CHANGED,
	DOT_OUTSIDE_GIT,
	folders,
	GIT_UNKNOWN,
	HARD_LINK,
	IGNORED,
	IN_GIT,
	IN_PI2,
	keepFolders,
	linkPath,
	linkTargets,
	MAX_FOLDERS,
	MAX_PREVIEW,
	MISSING,
	NO_FOLDER,
	NOT_A_FILE,
	NOT_A_PATH,
	NOT_LINKED,
	NOT_TEXT,
	OFFERED_MS,
	OUTSIDE,
	offeredFolders,
	PREVIEWS_PER_MINUTE,
	previewCounted,
	previewFile,
	TOO_MANY_PREVIEWS,
	tooLarge,
} from "../src/folders.ts";
import { scratchRoot } from "../src/scratch.ts";
import { EngineClient, standInApp } from "./patience.ts";

// Repositories made here use a fixed identity and none of the person's own git settings.
process.env.GIT_CONFIG_GLOBAL = "/dev/null";
process.env.GIT_CONFIG_NOSYSTEM = "1";
process.env.PI2_DEMO_TOKENS_PER_SECOND ??= "100000";
process.env.PI2_LOGIN_SHELL ??= "off";
// conversation.configure is the person's, taken from the app's connection: a stand-in takes this test's for it.
process.env.PI2_APP_BUNDLE = standInApp();

const work = realpathSync(mkdtempSync(join(tmpdir(), "pi2-folders-")));
const home = join(work, "home");
mkdirSync(home);
// The stand-in engine's data folder, and its scratch root, which is in the short private folder all engines share.
const standHome = join(work, "stand-home");
mkdirSync(standHome);
const standScratch = scratchRoot(standHome);
const KEYCHAIN_SERVICE = `dev.pi2.credentials.test-folders-${process.pid}`;
let engine: ChildProcess | undefined;
process.on("SIGTERM", () => process.exit(143));
process.on("SIGINT", () => process.exit(130));
process.on("exit", () => {
	if (engine !== undefined && engine.exitCode === null && engine.signalCode === null) engine.kill("SIGKILL");
	rmSync(work, { recursive: true, force: true });
	rmSync(standScratch, { recursive: true, force: true });
	try {
		while (true) execFileSync("/usr/bin/security", ["delete-generic-password", "-s", KEYCHAIN_SERVICE], { stdio: "ignore" });
	} catch {
		// None left.
	}
});

function step(text: string): void {
	console.log(`ok  ${text}`);
}

const git = (cwd: string, ...args: string[]) => execFileSync("git", args, { cwd, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();

// ---- Reading a link's target (as markdown.js and FileLink.path do)

{
	const folder = "/x/repo";
	assert.equal(linkPath("notes.md", folder, "/h"), "/x/repo/notes.md");
	assert.equal(linkPath("./a/../notes.md", folder, "/h"), "/x/repo/notes.md");
	assert.equal(linkPath("../other/notes.md", folder, "/h"), "/x/other/notes.md", "worked out by its text; the folder check comes after");
	assert.equal(linkPath("/x/repo/notes.md", folder, "/h"), "/x/repo/notes.md");
	assert.equal(linkPath("~/notes.md", folder, "/h"), "/h/notes.md");
	assert.equal(linkPath("file:///x/repo/my%20notes.md", folder, "/h"), "/x/repo/my notes.md");
	assert.equal(linkPath("file://localhost/x/repo/a.md#top", folder, "/h"), "/x/repo/a.md");
	for (const target of ["https://example.com/a.md", "file://elsewhere/a.md", "mailto:a@b", "//host/a", "#top", "?q", "~other/a", "", "a\nb", "javascript:x"]) {
		assert.equal(linkPath(target, folder, "/h"), null, target);
	}
	assert.deepEqual(
		linkTargets('See [the notes](notes.md), ![a picture](pics/a.png "title") and <file:///x/repo/b.md>, [spaced](<my notes.md>), [p](a(1).md).\n`[in code](code.md)`\n```\n[in a fence](fence.md)\n```\n[after](after.md)'),
		["notes.md", "pics/a.png", "my notes.md", "a(1).md", "after.md", "file:///x/repo/b.md"],
	);
	step("a link's target is read as the conversation's page reads it: links, pictures and file: autolinks outside code, relative to the folder");

	// A long run of white space after `](`, which took time growing with its square (3.6 s at 64,000 characters, minutes
	// at a megabyte). Now it is linear: a megabyte, and fifty such lines, each far under a bound no load reaches.
	for (const text of [`](${" ".repeat(1_000_000)}x`, `${`](${" ".repeat(4_000)}\n`.repeat(50)}`, `[a](${" ".repeat(1_000_000)}`]) {
		const began = performance.now();
		assert.deepEqual(linkTargets(text), []);
		const took = performance.now() - began;
		assert.ok(took < 10_000, `${took} ms for ${text.length} characters`);
	}
	assert.deepEqual(linkTargets(`[a](${" ".repeat(10_000)}notes.md${" ".repeat(10_000)})`), ["notes.md"]);
	step("a megabyte of white space after a link's opening is searched at once, not in time growing with its square");
}

// ---- A file swapped between the check and the read, with a stand-in engine

{
	const folder = join(work, "swap");
	const outside = join(work, "swap-outside");
	mkdirSync(join(folder, "sub"), { recursive: true });
	mkdirSync(join(outside, "sub"), { recursive: true });
	for (const name of ["a.md", "b.md", "c.md", "d.md", "sub/inner.md"]) writeFileSync(join(folder, name), `inside ${name}\n`);
	writeFileSync(join(outside, "secret.md"), "outside\n");
	writeFileSync(join(outside, "sub", "inner.md"), "outside inner\n");
	const answer = "[a](a.md) [b](b.md) [c](c.md) [d](d.md) [inner](sub/inner.md)";
	const stand: Engine = {
		home: standHome,
		library: () => ({ conversations: { "1": { title: "", createdAt: 0, updatedAt: 0, access: "read" } } }),
		context: () => ({}) as never,
		harness: () =>
			({
				snapshot: async () => ({ cwd: folder }),
				conversation: async () => ({ entries: async () => ({ items: [{ id: 1, kind: "message", model: [{ role: "assistant", content: [{ type: "text", text: answer }] }] }] }) }),
			}) as never,
	} as unknown as Engine;
	assert.deepEqual(await previewFile({ id: 1, path: "a.md" }, stand), { text: "inside a.md\n", size: 12 });
	await assert.rejects(
		previewFile({ id: 1, path: "a.md" }, stand, async () => {
			rmSync(join(folder, "a.md"));
			symlinkSync(join(outside, "secret.md"), join(folder, "a.md"));
		}),
		{ message: CHANGED },
		"the file swapped for a link out",
	);
	await assert.rejects(
		previewFile({ id: 1, path: "b.md" }, stand, async () => {
			renameSync(join(folder, "b.md"), join(folder, "b-was.md"));
			writeFileSync(join(folder, "b.md"), "another file\n");
		}),
		{ message: CHANGED },
		"the file swapped for another",
	);
	await assert.rejects(
		previewFile({ id: 1, path: "sub/inner.md" }, stand, async () => {
			renameSync(join(folder, "sub"), join(folder, "sub-was"));
			symlinkSync(join(outside, "sub"), join(folder, "sub"));
		}),
		{ message: CHANGED },
		"a folder on its path swapped for a link out",
	);
	await assert.rejects(
		previewFile({ id: 1, path: "c.md" }, stand, async () => {
			rmSync(join(folder, "c.md"));
			execFileSync("mkfifo", [join(folder, "c.md")]);
		}),
		{ message: CHANGED },
		"the file swapped for a pipe, which is not waited on",
	);
	await assert.rejects(
		previewFile({ id: 1, path: "d.md" }, stand, async () => appendFileSync(join(folder, "d.md"), "x".repeat(MAX_PREVIEW + 10))),
		{ message: tooLarge(MAX_PREVIEW + 10 + 12) },
		"a file that grows past the cap as it is read",
	);
	step("a file swapped between the check and the read, for a link out, another file or a pipe, or a folder on its path swapped for a link, or grown past the cap, is refused");
}

// ---- Which folders, with a stand-in engine; and pi²'s own files

{
	const at = (name: string) => {
		const path = join(work, "offer", name);
		mkdirSync(path, { recursive: true });
		return path;
	};
	const [agentFolder, removedAgent, top, subChat, chat, deletedConversation] = ["agent", "removed-agent", "top", "sub-chat", "chat", "deleted"].map(at);
	mkdirSync(join(standScratch, "1"), { recursive: true });
	writeFileSync(join(standScratch, "1", "notes.md"), "a scratch file\n");
	const meta = (updatedAt: number, extra: Record<string, unknown> = {}) => ({ title: "", createdAt: 0, updatedAt, access: "read", ...extra });
	const cwds: Record<string, string> = { "1": top, "2": subChat, "3": chat, "4": deletedConversation, "5": standScratch, "6": dirname(standHome), "7": "/", "8": standHome };
	const offering: Engine = {
		home: standHome,
		agents: () => ({
			a: { id: "a", cwd: agentFolder, createdAt: 10 },
			r: { id: "r", cwd: removedAgent, createdAt: 20, removedAt: 30 },
			slash: { id: "slash", cwd: "/", createdAt: 5 },
			scratch: { id: "scratch", cwd: join(standScratch, "1"), createdAt: 5 },
			holder: { id: "holder", cwd: work, createdAt: 5 },
		}),
		library: () => ({
			conversations: {
				"1": meta(100),
				"2": meta(200, { parent: 1 }),
				"3": meta(300, { chat: true }),
				"4": meta(400, { deleted: true }),
				"5": meta(50),
				"6": meta(50),
				"7": meta(50),
				"8": meta(50),
			},
		}),
		context: () => ({}) as never,
		harness: () => ({ snapshot: async (_doc: unknown, id: number) => ({ cwd: cwds[String(id)] ?? null }) }) as never,
	} as unknown as Engine;
	const offered = (await offeredFolders(offering)).map((folder) => folder.path);
	assert.deepEqual(offered, [top, agentFolder], "a top-level conversation's and an agent's, the one used last first");
	assert.ok(folderOffered(top) && !folderOffered(`${top}/`) && !folderOffered(`${top}/../top`), "told to the device row, by exact text only");
	step("never offered: a removed agent's, a sub-chat's, a chat's, a deleted conversation's folder, /, a scratch folder, the data folder, or a folder holding it");

	const folder = dirname(standScratch);
	const inScratch: Engine = {
		home: standHome,
		library: () => ({ conversations: { "1": meta(1) } }),
		context: () => ({}) as never,
		harness: () =>
			({
				snapshot: async () => ({ cwd: folder }),
				conversation: async () => ({
					entries: async () => ({ items: [{ id: 1, kind: "message", model: [{ role: "assistant", content: [{ type: "text", text: `[n](${standScratch.slice(folder.length + 1)}/1/notes.md)` }] }] }] }),
				}),
			}) as never,
	} as unknown as Engine;
	await assert.rejects(previewFile({ id: 1, path: `${standScratch.slice(folder.length + 1)}/1/notes.md` }, inScratch), { message: IN_PI2 });
	step("a file in a scratch folder is not shown, whatever the conversation's folder");
}

// ---- What is kept between requests, and what makes it stale (#902), with a stand-in engine and clock

{
	const at = (name: string) => {
		const path = join(work, "kept", name);
		mkdirSync(path, { recursive: true });
		return path;
	};
	const [first, second, third, linkedTo, retargeted, movedTo] = ["first", "second", "third", "linked-to", "retargeted", "moved-to"].map(at);
	git(first, "init", "-q");
	git(first, "remote", "add", "origin", "git@github.com:example/first.git");
	const meta = (updatedAt: number) => ({ title: "", createdAt: 0, updatedAt, access: "read" }) as Record<string, unknown>;
	const conversations: Record<string, Record<string, unknown>> = { "1": meta(30), "2": meta(20), "3": meta(10) };
	const cwds: Record<string, string> = { "1": first, "2": second, "3": third };
	let clock = 1_000_000;
	let snapshots = 0;
	let during: (() => void) | undefined;
	let observer: { advance(publication: unknown, context: unknown): void } | undefined;
	const stand = {
		home: standHome,
		agents: () => ({}),
		library: () => ({ conversations }),
		context: () => ({}),
		harness: () => ({
			snapshot: async (_doc: unknown, id: number) => {
				snapshots++;
				const cwd = cwds[String(id)];
				const then = during;
				during = undefined;
				then?.();
				return { cwd };
			},
			observeCommits: (given: typeof observer) => {
				observer = given;
				return { detach() {} };
			},
		}),
	} as unknown as Engine;
	keepFolders(stand, () => clock);
	const offered = async () => (await offeredFolders(stand)).map((folder) => (folder.repository === undefined ? folder.path : `${folder.path} ${folder.repository}`));
	const commit = (id: number, change: Record<string, unknown>) =>
		observer!.advance({ seq: 1, changes: [{ type: "document", record: { kind: "pi.agent" }, conversationId: id, ...change }] }, {});

	assert.deepEqual(await offered(), [`${first} example/first`, second, third]);
	assert.equal(snapshots, 3, "each conversation's document read once");
	git(first, "remote", "set-url", "origin", "git@github.com:example/renamed.git");
	assert.deepEqual(await offered(), [`${first} example/first`, second, third], "the same answer: .git/config not read again");
	assert.equal(snapshots, 3, "and no document read again");
	clock += OFFERED_MS;
	assert.deepEqual(await offered(), [`${first} example/renamed`, second, third], "made again once its time is up");
	assert.equal(snapshots, 3, "with each conversation's folder as the commits left it, not read again");
	step("projects.folders: a second call within the cache's life reads no document and no .git/config again; the folders are kept from the documents' commits after that");

	rmSync(third, { recursive: true });
	assert.deepEqual(await offered(), [`${first} example/renamed`, second], "a folder removed a moment ago is not offered");
	renameSync(second, `${second}-was`);
	symlinkSync(linkedTo, second);
	assert.deepEqual(await offered(), [`${first} example/renamed`, linkedTo], "nor one that is now a link: its real path is");
	rmSync(second);
	symlinkSync(retargeted, second);
	assert.deepEqual(await offered(), [`${first} example/renamed`, retargeted], "nor, once the link points elsewhere, where it pointed, though that is still there");
	commit(1, { kind: "change", value: { cwd: movedTo } });
	assert.deepEqual(await offered(), [movedTo, retargeted], "a conversation moved by a commit lends its new folder, not its old");
	assert.equal(snapshots, 3, "from the commit itself");
	commit(2, { kind: "retire" });
	assert.deepEqual(await offered(), [movedTo, retargeted]);
	assert.equal(snapshots, 4, "a document retired is read again");
	conversations["1"]!.deleted = true;
	assert.deepEqual(await offered(), [retargeted], "a conversation deleted a moment ago lends none");
	// A read a commit overtook is not kept: read again next time.
	commit(2, { kind: "retire" });
	during = () => commit(2, { kind: "change", value: { cwd: movedTo } });
	await offered();
	assert.equal(snapshots, 5);
	assert.deepEqual(await offered(), [retargeted]);
	assert.equal(snapshots, 6, "the read the commit overtook was not kept");
	await offered();
	assert.equal(snapshots, 6, "the next one is");
	step("projects.folders never offers from what it kept a folder removed or turned into a link, where a link pointed before, a conversation's old folder after a commit moved it, or a deleted conversation's; a retired document, or a read a commit overtook, is read again");
}

{
	const folder = join(work, "kept", "linking");
	const elsewhere = join(work, "kept", "linking-elsewhere");
	mkdirSync(folder, { recursive: true });
	mkdirSync(elsewhere, { recursive: true });
	writeFileSync(join(folder, "a.md"), "a here\n");
	writeFileSync(join(folder, "b.md"), "b here\n");
	writeFileSync(join(elsewhere, "a.md"), "a elsewhere\n");
	const answer = (id: number, text: string) => ({ id, kind: "message", model: [{ role: "assistant", content: [{ type: "text", text }] }] });
	const items = [answer(1, "[a](a.md)")];
	let cwd = folder;
	let scans = 0;
	const conversations: Record<string, Record<string, unknown>> = { "1": { title: "", createdAt: 0, updatedAt: 0, access: "read" } };
	const stand = {
		home: standHome,
		library: () => ({ conversations }),
		context: () => ({}),
		harness: () => ({
			snapshot: async () => ({ cwd }),
			observeCommits: () => ({ detach() {} }),
			conversation: async () => ({
				entries: async (query: { order: string }, limit: number) => {
					if (query.order === "descending") return { items: items.slice(-limit).reverse() };
					scans++;
					return { items };
				},
			}),
		}),
	} as unknown as Engine;
	keepFolders(stand);
	const preview = (path: string) => previewFile({ id: 1, path }, stand).then((shown) => shown.text, (error: Error) => error.message);
	assert.equal(await preview("a.md"), "a here\n");
	assert.equal(scans, 1);
	assert.equal(await preview("a.md"), "a here\n");
	assert.equal(await preview("b.md"), NOT_LINKED);
	assert.equal(scans, 1, "the transcript is not read again while its newest entry is the same");
	items.push(answer(2, "[b](b.md)"));
	assert.equal(await preview("b.md"), "b here\n", "a new entry: read again");
	assert.equal(scans, 2);
	cwd = elsewhere;
	assert.equal(await preview("a.md"), "a elsewhere\n", "another folder: the links read against it");
	assert.equal(await preview(`${folder}/a.md`), NOT_LINKED, "and no longer against the old one");
	assert.equal(await preview("b.md"), MISSING);
	assert.equal(scans, 3);
	conversations["1"]!.deleted = true;
	assert.equal(await preview("a.md"), "Unknown conversation: 1", "a conversation deleted shows nothing it linked");
	step("files.preview reads a transcript's links again only for a new entry or another folder, and never shows from what it kept a file the folder no longer links to");

	// At most PREVIEWS_PER_MINUTE a minute from a device, in words the phone shows; the Mac's app is not counted.
	conversations["1"]!.deleted = false;
	const handler = folders({} as never, stand).handlers!["files.preview"]!;
	const from = (device?: string) => handler({ id: 1, path: "unlinked.md" }, device === undefined ? {} : { device: { id: device, session: "s" } }).then(() => "shown", (error: Error) => error.message);
	for (let n = 0; n < PREVIEWS_PER_MINUTE; n++) assert.equal(await from("phone"), NOT_LINKED);
	assert.equal(await from("phone"), TOO_MANY_PREVIEWS, "one more in the same minute");
	assert.ok(!TOO_MANY_PREVIEWS.includes("/"));
	assert.equal(await from("another phone"), NOT_LINKED, "each device has its own");
	assert.equal(await from(), NOT_LINKED, "the app is not counted");
	assert.doesNotThrow(() => previewCounted("phone", Date.now() + 60_000), "a minute later, it may again");
	step(`files.preview: at most ${PREVIEWS_PER_MINUTE} a minute from each device, then refused in words the phone shows`);
}

{
	// The worktree pi² made for a conversation is its folder, and its sub-chats', which join it; no other conversation's.
	const worktree = join(standHome, "worktrees", "repo-1", "branch");
	mkdirSync(worktree, { recursive: true });
	writeFileSync(join(worktree, "notes.md"), "in its worktree\n");
	const meta = (extra: Record<string, unknown> = {}) => ({ title: "", createdAt: 0, updatedAt: 0, access: "read", ...extra });
	const stand = {
		home: standHome,
		library: () => ({ conversations: { "1": meta(), "2": meta({ parent: 1 }), "3": meta({ parent: 2 }), "4": meta() } }),
		context: () => ({}),
		harness: () => ({
			snapshot: async (doc: unknown) => (doc === AgentDoc ? { cwd: worktree } : { conversations: { "1": { path: worktree } } }),
			conversation: async () => ({
				entries: async () => ({ items: [{ id: 1, kind: "message", model: [{ role: "assistant", content: [{ type: "text", text: "[n](notes.md)" }] }] }] }),
			}),
		}),
	} as unknown as Engine;
	const preview = (id: number) => previewFile({ id, path: "notes.md" }, stand).then((shown) => shown.text, (error: Error) => error.message);
	assert.equal(await preview(1), "in its worktree\n", "the conversation's own");
	assert.equal(await preview(2), "in its worktree\n", "its sub-chat's");
	assert.equal(await preview(3), "in its worktree\n", "and that one's");
	assert.equal(await preview(4), IN_PI2, "not another conversation's, working in it");
	step("the worktree pi² made for a conversation is its folder and its sub-chats', and no other conversation's");
}

// ---- A real engine

const repo = join(work, "repo");
const outside = join(work, "outside");
mkdirSync(join(repo, "sub"), { recursive: true });
mkdirSync(join(repo, "secret"));
mkdirSync(outside);
git(repo, "init", "-q", "-b", "main");
git(repo, "remote", "add", "origin", "git@github.com:example/website.git");
writeFileSync(join(repo, ".gitignore"), ".env\nsecret/\n*.secret\n");
writeFileSync(join(repo, "notes.md"), "# Notes\nhello\n");
writeFileSync(join(repo, "unlinked.md"), "never linked\n");
writeFileSync(join(repo, "code.md"), "linked in code only\n");
writeFileSync(join(repo, "sub", "inner.md"), "inner\n");
writeFileSync(join(repo, ".env"), "TOKEN=abc\n");
writeFileSync(join(repo, "secret", "token.txt"), "abc\n");
writeFileSync(join(repo, "big.txt"), "a".repeat(MAX_PREVIEW + 1));
writeFileSync(join(repo, "edge.txt"), "b".repeat(MAX_PREVIEW));
writeFileSync(join(repo, "binary.bin"), Buffer.from([0xff, 0xfe, 0x41, 0x80]));
writeFileSync(join(repo, "nul.txt"), "a\u0000b");
writeFileSync(join(outside, "secret.md"), "outside\n");
writeFileSync(join(outside, "hard-target.md"), "hard\n");
symlinkSync(join(outside, "secret.md"), join(repo, "link-out.md"));
symlinkSync(outside, join(repo, "linked-dir"));
linkSync(join(outside, "hard-target.md"), join(repo, "hard.md"));
execFileSync("mkfifo", [join(repo, "fifo")]);
// Ignored, and larger than the cap: refused as ignored, its size never said.
writeFileSync(join(repo, "big.secret"), "s".repeat(MAX_PREVIEW + 50_000));
// A name git reads as a pathspec's magic, which check-ignore cannot judge.
writeFileSync(join(repo, ":(glob)x.md"), "magic\n");
// A folder that is no git repository, with secrets in dot-files.
const plain = join(work, "plain");
mkdirSync(join(plain, ".ssh"), { recursive: true });
writeFileSync(join(plain, "notes.md"), "plain notes\n");
writeFileSync(join(plain, ".env"), "TOKEN=1\n");
writeFileSync(join(plain, ".ssh", "config"), "Host x\n");

const main = join(import.meta.dirname, "..", "src", "main.ts");
engine = spawn(process.execPath, [main], { env: { ...process.env, PI2_HOME: home, PI2_KEYCHAIN_SERVICE: KEYCHAIN_SERVICE }, stdio: ["ignore", "ignore", "inherit"] });
const client = await EngineClient.connect(engine, home);

/** A conversation on the demo model working in `folder` (or none), once it has answered `text`, which it repeats. */
async function conversationIn(folder: string | null, text?: string): Promise<number> {
	const { id } = await client.call("conversation.create", { model: { provider: "demo", modelId: "demo-1" } });
	if (folder !== null) await client.call("conversation.configure", { id, cwd: folder });
	if (text !== undefined) {
		await client.call("conversation.open", { id });
		await client.call("submit", { id, text });
		await client.until("the demo's answer", () => client.conversations.get(id)?.items.some((item: any) => item.kind === "assistant" && item.text.includes(text.slice(0, 20))));
	}
	return id;
}

{
	const links = [
		"notes.md",
		`${repo}/notes.md`,
		"edge.txt",
		`${outside}/secret.md`,
		"link-out.md",
		"linked-dir/secret.md",
		".env",
		"secret/token.txt",
		".git/config",
		"big.txt",
		"binary.bin",
		"nul.txt",
		"fifo",
		"sub",
		"hard.md",
		"gone.md",
		"big.secret",
		":(glob)x.md",
		"../nothing-there.md",
	];
	const text = `${links.map((target, n) => `[link ${n}](${target})`).join(" ")} <file://${repo}/sub/inner.md> \`[c](code.md)\``;
	const id = await conversationIn(repo, text);
	const preview = (path: string, of = id) => client.call("files.preview", { id: of, path });
	const refused = async (path: string, words: string, of = id) => assert.equal((await preview(path, of).then(() => "taken", (error: Error) => error.message)), words, path);

	assert.deepEqual(await preview("notes.md"), { text: "# Notes\nhello\n", size: 14 });
	assert.deepEqual(await preview(`${repo}/notes.md`), { text: "# Notes\nhello\n", size: 14 }, "the same file, named whole");
	assert.deepEqual(await preview(`file://${repo}/sub/inner.md`), { text: "inner\n", size: 6 }, "an autolink");
	assert.equal((await preview("edge.txt")).size, MAX_PREVIEW, "256 KB is shown");
	await refused("unlinked.md", NOT_LINKED);
	await refused("code.md", NOT_LINKED);
	await refused(`${outside}/secret.md`, OUTSIDE);
	await refused("link-out.md", OUTSIDE);
	await refused("linked-dir/secret.md", OUTSIDE);
	await refused(".env", IGNORED);
	await refused("secret/token.txt", IGNORED);
	await refused(".git/config", IN_GIT);
	await refused("big.txt", tooLarge(MAX_PREVIEW + 1));
	await refused("binary.bin", NOT_TEXT);
	await refused("nul.txt", NOT_TEXT);
	await refused("fifo", NOT_A_FILE);
	await refused("sub", NOT_A_FILE);
	await refused("hard.md", HARD_LINK);
	await refused("gone.md", MISSING);
	await refused("big.secret", IGNORED, id);
	await refused(":(glob)x.md", GIT_UNKNOWN);
	await refused("../nothing-there.md", OUTSIDE, id);
	await refused("https://example.com/notes.md", NOT_A_PATH);
	const none = await conversationIn(null, "[n](notes.md)");
	await refused("notes.md", NO_FOLDER, none);
	await refused("notes.md", "Unknown conversation: 99999", 99999);

	// Outside a git repository: a dot-file or a file in a dot-folder is refused, the rest shown.
	const outsideGit = await conversationIn(plain, "[n](notes.md) [e](.env) [s](.ssh/config)");
	assert.deepEqual(await preview("notes.md", outsideGit), { text: "plain notes\n", size: 12 });
	await refused(".env", DOT_OUTSIDE_GIT, outsideGit);
	await refused(".ssh/config", DOT_OUTSIDE_GIT, outsideGit);
	// pi²'s data folder, from a conversation whose folder holds it; but a conversation's own worktree there is its folder.
	writeFileSync(join(home, "a-file-of-pi2s.json"), '{"command":"server --token t0p"}\n');
	const holding = await conversationIn(work, "[l](home/a-file-of-pi2s.json)");
	await refused("home/a-file-of-pi2s.json", IN_PI2, holding);
	// Only the worktree pi² made for the conversation (#902): a folder made by hand where worktrees are, or the folder
	// holding them, is pi²'s data.
	const worktree = join(home, "worktrees", "agent-1", "branch");
	mkdirSync(worktree, { recursive: true });
	writeFileSync(join(worktree, "notes.md"), "in a worktree\n");
	const inWorktree = await conversationIn(worktree, "[n](notes.md)");
	await refused("notes.md", IN_PI2, inWorktree);
	const holdingWorktrees = await conversationIn(join(home, "worktrees"), "[n](agent-1/branch/notes.md)");
	await refused("agent-1/branch/notes.md", IN_PI2, holdingWorktrees);
	const checkout = join(work, "checkout");
	mkdirSync(checkout);
	git(checkout, "init", "-q", "-b", "main");
	writeFileSync(join(checkout, "notes.md"), "in a worktree\n");
	git(checkout, "add", "notes.md");
	git(checkout, "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-q", "-m", "notes");
	const owner = await conversationIn(checkout, "[n](notes.md)");
	const made = await client.call("worktree.create", { id: owner });
	assert.ok(made.path.startsWith(`${home}/worktrees/`), made.path);
	assert.deepEqual(await preview("notes.md", owner), { text: "in a worktree\n", size: 14 }, "a conversation's own worktree is its folder");
	const visitor = await conversationIn(made.path, "[n](notes.md)");
	await refused("notes.md", IN_PI2, visitor);
	// A conversation working in a dot-folder outside a repository, or through a link to one (#902).
	const dotted = join(work, ".dotted");
	mkdirSync(dotted);
	writeFileSync(join(dotted, "notes.md"), "dotted notes\n");
	symlinkSync(dotted, join(work, "to-dotted"));
	await refused("notes.md", DOT_OUTSIDE_GIT, await conversationIn(dotted, "[n](notes.md)"));
	await refused("notes.md", DOT_OUTSIDE_GIT, await conversationIn(join(work, "to-dotted"), "[n](notes.md)"));
	for (const words of [OUTSIDE, IN_PI2, DOT_OUTSIDE_GIT, IGNORED, GIT_UNKNOWN, NOT_LINKED, MISSING]) assert.ok(!words.includes("/"), `no path in: ${words}`);
	step("files.preview shows a linked text file under the folder, and refuses one not linked, outside the folder by its text or after links, git's own, ignored (before its size), one git cannot judge, too large, not text, not a file, a hard link, missing, a dot-file outside a repository or in a dot-folder that is the conversation's own, pi²'s data, and a conversation with no folder; only the worktree pi² made for a conversation is its folder");

	// What is kept never shows what the rules refuse now (#902): a file that became ignored, a conversation moved
	// elsewhere or deleted, each a moment after it was shown.
	assert.deepEqual(await preview("notes.md"), { text: "# Notes\nhello\n", size: 14 });
	appendFileSync(join(repo, ".gitignore"), "notes.md\n");
	await refused("notes.md", IGNORED);
	writeFileSync(join(repo, ".gitignore"), ".env\nsecret/\n*.secret\n");
	const moving = await conversationIn(repo, "[n](notes.md) [whole](<" + `${repo}/notes.md` + ">)");
	assert.deepEqual(await preview("notes.md", moving), { text: "# Notes\nhello\n", size: 14 });
	await client.call("conversation.configure", { id: moving, cwd: plain });
	assert.deepEqual(await preview("notes.md", moving), { text: "plain notes\n", size: 12 }, "its link read against its new folder");
	await refused(`${repo}/notes.md`, OUTSIDE, moving);
	await client.call("conversation.delete", { id: moving });
	await refused("notes.md", `Unknown conversation: ${moving}`, moving);
	step("files.preview, a moment after showing a file: refuses it once git ignores it, reads a moved conversation's links against its new folder, and shows nothing of a deleted one");
}

{
	// Folders used with pi²: a project's, an archived project's, a repository's, an agent's, a conversation's; and folders
	// never offered: one never used, the data folder's, one gone, one whose path holds a key's shape.
	const folder = (name: string) => {
		const path = join(work, name);
		mkdirSync(path, { recursive: true });
		return path;
	};
	const projectFolder = folder("project");
	const archivedFolder = folder("archived");
	const agentFolder = folder("agent-folder");
	const recent = folder("recent");
	const unused = folder("unused");
	const gone = folder("gone");
	const keyed = folder("sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123");
	const inHome = join(home, "inside");
	mkdirSync(inHome);
	await client.call("projects.create", { folder: projectFolder, name: "Website" });
	const archived = await client.call("projects.create", { folder: archivedFolder, name: "Old" });
	await client.call("projects.archive", { id: archived.id });
	const deletedFolder = folder("deleted-project");
	const deleted = await client.call("projects.create", { folder: deletedFolder, name: "Gone" });
	await client.call("projects.delete", { id: deleted.id });
	await client.call("agents.save", { agent: { name: "Folded", access: "read", cwd: agentFolder } });
	for (const path of [gone, keyed, inHome, recent]) await conversationIn(path);
	rmSync(gone, { recursive: true });
	const { folders } = await client.call("projects.folders");
	const paths = folders.map((one: any) => one.path);
	for (const path of [repo, projectFolder, archivedFolder, agentFolder, recent]) assert.ok(paths.includes(path), `${path} is offered`);
	for (const path of [unused, gone, keyed, inHome, home, work, deletedFolder]) assert.ok(!paths.includes(path), `${path} is not`);
	assert.ok(paths.every((path: string) => !path.startsWith(`${home}/`)), "nothing in the data folder");
	const of = (path: string) => folders.find((one: any) => one.path === path);
	const where = work.startsWith(`${homedir()}/`) ? `~${work.slice(homedir().length)}` : work;
	assert.deepEqual(of(repo), { path: repo, name: "repo", where, repository: "example/website" });
	assert.deepEqual(of(projectFolder), { path: projectFolder, name: "project", where, project: "Website" });
	assert.equal(of(archivedFolder).project, "Old", "an archived project's folder is still its");
	assert.equal(paths[0], recent, "the folder used last comes first");
	const firstTaken = folders.findIndex((one: any) => one.project !== undefined);
	assert.ok(firstTaken > 0 && folders.slice(firstTaken).every((one: any) => one.project !== undefined), "then the projects' folders");
	// What is kept never offers what the rules refuse now (#902): a project deleted, a folder removed, a conversation moved,
	// each a moment after it was offered.
	const offeredNow = async () => (await client.call("projects.folders")).folders.map((one: any) => one.path) as string[];
	const keptFolder = folder("kept-project");
	const keptProject = await client.call("projects.create", { folder: keptFolder, name: "Kept" });
	assert.ok((await offeredNow()).includes(keptFolder));
	await client.call("projects.delete", { id: keptProject.id });
	assert.ok(!(await offeredNow()).includes(keptFolder), "a project deleted a moment ago");
	const leaving = folder("leaving");
	await conversationIn(leaving);
	assert.ok((await offeredNow()).includes(leaving));
	rmSync(leaving, { recursive: true });
	assert.ok(!(await offeredNow()).includes(leaving), "a folder removed a moment ago");
	const [before, after] = [folder("before"), folder("after")];
	const mover = await conversationIn(before);
	assert.ok((await offeredNow()).includes(before));
	await client.call("conversation.configure", { id: mover, cwd: after });
	const moved = await offeredNow();
	assert.ok(moved.includes(after) && !moved.includes(before), "a conversation moved a moment ago lends its new folder, not its old");
	for (let n = 0; n < MAX_FOLDERS; n++) await conversationIn(folder(`many/${n}`));
	assert.equal((await client.call("projects.folders")).folders.length, MAX_FOLDERS, `at most ${MAX_FOLDERS}`);
	assert.ok(!(await client.call("projects.folders")).folders.some((one: any) => one.path === join(work, "many")), "never a parent of one");
	step(`projects.folders offers the folders of projects, agents and recent conversations, at most ${MAX_FOLDERS}, by their real paths, never a parent, one gone, the data folder's or one shaped like a key`);
}

client.close();
engine.kill("SIGTERM");
