// Rules that let an agent run particular shell commands without asking, in one folder. See docs/rules.md.
//
// Everything here is pure, so engine/test/rules.ts can try it against commands that attempt to smuggle a second one
// past a rule. The guiding principle: the command line is read the way bash will read it, and anything this reader is
// not certain about makes the whole line ask, as it would without rules.

import { relative, resolve, sep } from "node:path";

/**
 * Commands that start with `words` may run without asking, for one agent, when its conversation works in `folder`, or in
 * the same folder of a worktree pi² made from that repository (see `ruleFolder`).
 */
export type CommandRule = { folder: string; words: string[]; createdAt: number };

/** One word of a simple command, with quotes and escapes taken off. */
export type Token = {
	text: string;
	/** False when bash may still change the word: a glob, a brace or a tilde outside quotes. */
	literal: boolean;
};

/** A command line split into simple commands, or why it must ask. */
export type Parsed = { commands: Token[][] } | { ask: string };

/** Whether a command may run under the rules, and which rules allowed it. */
export type Verdict = { allowed: true; rules: string[] } | { allowed: false; reason: string };

export const MAX_WORDS = 8;
const MAX_WORD_LENGTH = 100;

/** Plain characters a word may hold outside quotes. Anything else outside quotes means something to bash. */
const PLAIN = /[A-Za-z0-9_\-./,:@%+=^]/;
/** Characters that make bash expand a word (globs, braces, tilde) without running anything. */
const EXPANDING = new Set(["*", "?", "[", "]", "{", "}", "~"]);
/** What may follow a redirection's target for the target to be complete. */
const BOUNDARY = new Set([undefined, " ", "\t", "\n", ";", "|", "&", "<", ">", "(", ")"]);

/**
 * Split a command line into simple commands at `&&`, `||`, `;`, `|` and newlines, the way bash would, or say why it
 * cannot be judged. Quotes and backslashes are understood. What asks: `$` outside single quotes (variables, `$(…)`,
 * `$((…))`), backticks, `(` and `)`, `&` on its own (running in the background), `<` (reading a file, here-documents,
 * process substitution), `>` except onto `/dev/null` or another output (`2>&1`), `!`, control characters, unbalanced
 * quotes, and a command missing next to `&&`, `||` or `|`.
 */
export function parseCommandLine(line: string): Parsed {
	const commands: Token[][] = [];
	let current: Token[] = [];
	let word = "";
	let inWord = false;
	let literal = true;
	let quoted = false;
	// What came before the command being read: nothing yet, a `;` or newline, or `&&`, `||` or `|` (which need a
	// command after them).
	let after = "start" as "start" | "list" | "operator";

	const endWord = () => {
		if (inWord) current.push({ text: word, literal });
		word = "";
		inWord = false;
		literal = true;
		quoted = false;
	};
	const empty = () => current.length === 0 && !inWord;
	/** End the simple command being read; false when there is none where bash needs one. */
	const endCommand = (by: "list" | "operator"): boolean => {
		if (empty()) return false;
		endWord();
		commands.push(current);
		current = [];
		after = by;
		return true;
	};
	const control = (code: number) => (code < 0x20 && code !== 0x09 && code !== 0x0a) || code === 0x7f;

	for (let i = 0; i < line.length; ) {
		const c = line[i]!;
		const code = c.charCodeAt(0);
		if (c === "\n") {
			if (!empty()) endCommand("list");
			// A blank line, or a line break after `&&`, `||` or `|`, which bash reads as carrying on.
			i++;
			continue;
		}
		if (c === " " || c === "\t") {
			endWord();
			i++;
			continue;
		}
		if (control(code)) return { ask: "it contains a control character" };
		if (c === "'") {
			const close = line.indexOf("'", i + 1);
			if (close === -1) return { ask: "a quote is not closed" };
			const inside = line.slice(i + 1, close);
			for (let k = 0; k < inside.length; k++) if (control(inside.charCodeAt(k))) return { ask: "it contains a control character" };
			word += inside;
			inWord = true;
			quoted = true;
			i = close + 1;
			continue;
		}
		if (c === '"') {
			let j = i + 1;
			for (;;) {
				const d = line[j];
				if (d === undefined) return { ask: "a quote is not closed" };
				if (d === '"') break;
				if (d === "$") return { ask: "it uses $ (a variable or a command inside the command)" };
				if (d === "`") return { ask: "it runs a command inside the command (backticks)" };
				if (control(d.charCodeAt(0))) return { ask: "it contains a control character" };
				if (d === "\\") {
					const e = line[j + 1];
					if (e === undefined) return { ask: "a quote is not closed" };
					if (e === "\n") {
						j += 2;
						continue;
					}
					// Inside double quotes a backslash only escapes these; before anything else it stays as written.
					if (e === "$" || e === "`" || e === '"' || e === "\\") {
						word += e;
						j += 2;
						continue;
					}
				}
				word += d;
				j++;
			}
			inWord = true;
			quoted = true;
			i = j + 1;
			continue;
		}
		if (c === "\\") {
			const next = line[i + 1];
			if (next === undefined) return { ask: "it ends with a backslash" };
			// A backslash before a line break joins the lines.
			if (next === "\n") {
				i += 2;
				continue;
			}
			if (control(next.charCodeAt(0))) return { ask: "it contains a control character" };
			word += next;
			inWord = true;
			quoted = true;
			i += 2;
			continue;
		}
		if (c === "#") {
			// At the start of a word, a comment runs to the end of the line, and the line break still ends the command.
			// Inside a word it is an ordinary character.
			if (inWord) {
				word += c;
				i++;
			} else while (i < line.length && line[i] !== "\n") i++;
			continue;
		}
		if (c === ";") {
			if (line[i + 1] === ";" || line[i + 1] === "&") return { ask: "it uses ;; or ;&" };
			if (!endCommand("list")) return { ask: "there is a ; with no command before it" };
			i++;
			continue;
		}
		if (c === "&" && line[i + 1] === "&") {
			if (!endCommand("operator")) return { ask: "there is a && with no command before it" };
			i += 2;
			continue;
		}
		if (c === "|") {
			if (line[i + 1] === "&") return { ask: "it uses |&" };
			const or = line[i + 1] === "|";
			if (!endCommand("operator")) return { ask: `there is a ${or ? "||" : "|"} with no command before it` };
			i += or ? 2 : 1;
			continue;
		}
		if (c === ">" || (c === "&" && line[i + 1] === ">")) {
			// Digits right before `>` name the output it redirects (2> is errors); they are not a word of the command.
			if (c === ">" && inWord && !quoted && /^[0-9]+$/.test(word)) {
				word = "";
				inWord = false;
				literal = true;
			} else endWord();
			let j = c === "&" ? i + 2 : i + 1;
			const append = line[j] === ">";
			// The Mac's bash 3.2 has no &>>; it would read it as & (in the background) and >>.
			if (append && c === "&") return { ask: "it uses &>>" };
			if (append) j++;
			if (line[j] === "|") return { ask: "it writes to a file (>|)" };
			if (c === ">" && !append && line[j] === "&") {
				// `>&2`, `2>&1`: send one output where another goes. Only a single digit; anything else names a file.
				j++;
				while (line[j] === " " || line[j] === "\t") j++;
				if (/[0-9]/.test(line[j] ?? "") && BOUNDARY.has(line[j + 1])) {
					i = j + 1;
					continue;
				}
				return { ask: "it writes to a file (>&)" };
			}
			while (line[j] === " " || line[j] === "\t") j++;
			// Throwing output away writes nothing.
			if (line.startsWith("/dev/null", j) && BOUNDARY.has(line[j + 9])) {
				i = j + 9;
				continue;
			}
			return { ask: "it writes to a file (>)" };
		}
		if (c === "&") return { ask: "it runs something in the background (&)" };
		if (c === "<") return { ask: "it reads from a file or a here-document (<)" };
		if (c === "(" || c === ")") return { ask: "it uses ( or ), a subshell or a group" };
		if (c === "$") return { ask: "it uses $ (a variable or a command inside the command)" };
		if (c === "`") return { ask: "it runs a command inside the command (backticks)" };
		if (c === "!") return { ask: "it uses !" };
		if (EXPANDING.has(c)) {
			word += c;
			inWord = true;
			literal = false;
			i++;
			continue;
		}
		// Letters beyond ASCII are part of a word to bash; only ASCII characters mean anything to it.
		if (PLAIN.test(c) || code >= 0x80) {
			word += c;
			inWord = true;
			i++;
			continue;
		}
		return { ask: `it uses the character ${c}` };
	}
	if (!empty()) endCommand("list");
	else if (after === "operator") return { ask: "it ends with &&, || or |" };
	return { commands };
}

// ---- Which commands a rule can never cover

/**
 * Words that, as the name of a simple command, make the whole line ask, whatever the rules say: bash's own keywords,
 * changing folder, builtins that run text as a command or change how later commands run, and programs that run
 * another command (`sudo npm test` is not `npm test`).
 */
export const ALWAYS_ASK: ReadonlySet<string> = new Set([
	// Keywords
	"if", "then", "else", "elif", "fi", "case", "esac", "for", "select", "while", "until", "do", "done", "in", "function", "time", "coproc", "{", "}", "!", "[[", "]]",
	// Changing folder: a rule is for one folder.
	"cd", "pushd", "popd",
	// Builtins that run text, load code, or change what later commands do
	"eval", "exec", "source", ".", "command", "builtin", "enable", "trap", "alias", "unalias", "hash", "export", "set", "unset", "declare", "typeset", "readonly", "local", "let", "shopt",
	"read", "mapfile", "readarray", "ulimit", "umask", "fc", "history", "bind", "complete", "compgen", "getopts", "shift", "exit", "return", "logout", "wait", "jobs", "fg", "bg", "disown", "suspend", "kill",
	// Programs that run another command
	"env", "sudo", "su", "doas", "xargs", "nohup", "nice", "renice", "timeout", "gtimeout", "watch", "stdbuf", "caffeinate", "chroot", "script", "unbuffer", "setsid", "flock",
	"strace", "ltrace", "dtruss", "dtrace", "sandbox-exec", "xcrun", "arch", "parallel", "watchexec", "entr", "osascript", "open",
]);

/**
 * Programs no rule may name at all: they delete or change files anywhere, reach other machines, change the Mac's
 * settings, or run commands of their own (`find -exec`, `awk`'s `system()`, a pager's `!`).
 */
const NEVER: ReadonlySet<string> = new Set([
	"rm", "rmdir", "unlink", "shred", "srm", "dd", "mkfs", "newfs", "diskutil", "fdisk", "mount", "umount", "cp", "mv", "ln", "install", "tee", "truncate",
	"chmod", "chown", "chgrp", "chflags", "shutdown", "reboot", "halt", "killall", "pkill", "launchctl", "defaults", "security", "shortcuts", "automator",
	"pmset", "scutil", "networksetup", "systemsetup", "csrutil", "spctl", "tccutil", "nvram", "bless", "softwareupdate", "installer", "dscl", "sysadminctl", "kmutil", "profiles",
	"curl", "wget", "ssh", "scp", "sftp", "rsync", "nc", "ncat", "netcat", "telnet", "ftp", "socat",
	"crontab", "at", "batch", "find", "awk", "gawk", "nawk", "mawk", "sed", "gsed", "vim", "vi", "nvim", "emacs", "nano", "ed", "ex", "less", "more", "man", "screen", "tmux",
	"sqlite3", "psql", "mysql", "gdb", "lldb", "docker", "podman", "nerdctl", "kubectl", "colima", "lima", "vagrant",
]);

/**
 * Programs that run whatever they are given: a rule must also say what (`python3 manage.py`, `npm test`), and that may
 * not be an option, which is where code written on the spot goes (`python3 -c`, `node -e`, `git -c`).
 */
const NEEDS_MORE: ReadonlySet<string> = new Set([
	"sh", "bash", "zsh", "fish", "dash", "ksh", "csh", "tcsh", "ash", "nu", "pwsh", "powershell",
	"python", "pypy", "ruby", "perl", "php", "lua", "luajit", "node", "nodejs", "deno", "bun", "java", "jshell", "scala", "groovy", "kotlin", "swift",
	"rscript", "r", "julia", "tclsh", "wish", "expect", "elixir", "iex", "erl", "ghci", "runghc", "runhaskell", "ocaml", "guile", "racket", "irb",
	"npx", "bunx", "pnpx", "uvx", "pipx", "npm", "pnpm", "yarn", "git", "make", "gmake", "go", "cargo", "uv", "poetry", "pipenv", "pdm", "hatch", "pip", "pip3",
	"gem", "bundle", "brew", "dotnet", "gh", "mix", "rake", "aws", "gcloud", "az", "gsutil", "heroku", "fly", "flyctl", "terraform", "tofu", "pulumi", "ansible", "ansible-playbook",
]);

/** Two words that still allow anything, or something no rule should cover, so a rule may not start with them. */
const REFUSED_PAIRS: ReadonlySet<string> = new Set([
	// Code from anywhere, or settings that make later commands run something else
	"npm exec", "npm x", "npm explore", "npm config", "npm set", "npm init", "npm create", "npm install", "npm i", "npm add", "npm link", "npm edit",
	"npm publish", "npm unpublish", "npm login", "npm adduser", "npm token",
	"pnpm exec", "pnpm dlx", "pnpm create", "pnpm init", "pnpm config", "pnpm add", "pnpm link", "pnpm publish",
	"yarn exec", "yarn dlx", "yarn create", "yarn init", "yarn config", "yarn add", "yarn link", "yarn node", "yarn publish",
	"bun x", "bun exec", "bun create", "bun init", "bun add", "bun link", "bun publish", "bun repl",
	"deno run", "deno eval", "deno repl", "deno x", "deno install", "deno compile",
	"uv run", "uv tool", "uv pip", "uv add", "pipx run", "pipx install", "poetry run", "poetry shell", "poetry add", "poetry config", "pipenv run", "pipenv shell",
	"pdm run", "hatch run", "hatch shell", "pip install", "pip download", "pip3 install", "pip3 download",
	"gem install", "gem exec", "bundle exec", "bundle add", "bundle config", "brew install", "brew reinstall", "brew upgrade", "brew tap", "brew bundle", "brew sh", "brew ruby", "brew irb", "brew services",
	"go run", "go generate", "go install", "go get", "go tool", "go env", "cargo install", "dotnet tool", "mix run", "swift repl",
	"gh api", "gh extension", "gh ext", "gh alias", "gh auth", "gh secret",
	// git can be told to run another program (config, hooks, --upload-pack, --exec), or to throw work away for good
	"git config", "git submodule", "git rebase", "git bisect", "git filter-branch", "git filter-repo", "git difftool", "git mergetool", "git daemon", "git instaweb",
	"git clone", "git fetch", "git pull", "git push", "git ls-remote", "git archive", "git remote", "git credential", "git send-email", "git svn", "git p4", "git hook",
	"git help", "git clean", "git alias",
]);

/** Two words that run whatever script is named after them: the rule must name the script too. */
const NEEDS_NAME: ReadonlySet<string> = new Set(["npm run", "npm run-script", "pnpm run", "yarn run", "bun run", "deno task"]);

/** Commands that may sit next to ones a rule covers (`npm test 2>&1 | tail -20`). They print and change nothing. */
export const HARMLESS: ReadonlySet<string> = new Set(["echo", "true", "false", "pwd", "cat", "head", "tail", "wc", "grep"]);

/** A word of a rule: plain characters only, so it can only ever match the same word written plainly. */
const WORD = /^[A-Za-z0-9_\-./,:@%+=^]+$/;
/** The first word of a rule: a program's name or a path to it. */
const FIRST = /^[A-Za-z0-9_./][A-Za-z0-9_\-./@+]*$/;

/** The program a command word names, lower-cased (a Mac's disk does not mind case) and without a version (`python3.12`). */
export function programName(word: string): string {
	return (word.split("/").pop() ?? word).toLowerCase();
}
const withoutVersion = (name: string) => name.replace(/[-.]?[0-9][0-9.]*$/, "");
const isPython = (name: string) => withoutVersion(name) === "python" || withoutVersion(name) === "pypy";
const inSet = (set: ReadonlySet<string>, name: string) => set.has(name) || set.has(withoutVersion(name));

/** Why a rule with these words cannot be made, in words for the person, or undefined when it can. */
export function ruleRefusal(words: readonly string[]): string | undefined {
	if (words.length === 0) return "Write the command's first words, such as npm test.";
	if (words.length > MAX_WORDS) return `A rule can have at most ${MAX_WORDS} words.`;
	for (const word of words) {
		if (word.length > MAX_WORD_LENGTH) return `“${word.slice(0, 40)}…” is too long for a word of a rule.`;
		if (!WORD.test(word)) return `“${word}” is not a plain word. Write the command as you would type it, without quotes, variables, wildcards, or symbols such as $ ; | & > < ( ) * ~.`;
	}
	const first = words[0]!;
	if (!FIRST.test(first) || first.endsWith("/") || first === "." || first === "..") {
		return `“${first}” is not the name of a program. A rule starts with the program to run, such as npm or ./run-tests.`;
	}
	if (first.includes("=")) return "A rule cannot start by setting a variable.";
	const name = programName(first);
	if (inSet(ALWAYS_ASK, name)) {
		return name === "cd" || name === "pushd" || name === "popd"
			? "A rule cannot change folder: it is for one folder, and a command that changes folder always asks."
			: `${name} runs other commands or changes how they run, so pi² always asks before it.`;
	}
	if (inSet(NEVER, name)) return `${name} can delete or change things anywhere, or reach other machines, so pi² always asks before it.`;
	if (inSet(NEEDS_MORE, name) || isPython(name)) {
		const second = words[1];
		if (second === undefined) return `A rule for ${name} alone would let the agent run anything with it. Add what it should run, such as ${example(name)}.`;
		const module = isPython(name) && second === "-m" && words[2] !== undefined && !words[2].startsWith("-");
		if (second.startsWith("-") && !module) return `${name} ${second} lets the agent run code it writes on the spot, so pi² always asks before it.`;
		const pair = `${name} ${second.toLowerCase()}`;
		if (REFUSED_PAIRS.has(pair) || REFUSED_PAIRS.has(`${withoutVersion(name)} ${second.toLowerCase()}`)) {
			return `${name} ${second} can run other programs or undo work for good, so pi² always asks before it.`;
		}
		if (words.length === 2 && NEEDS_NAME.has(pair)) return `${name} ${second} runs any script. Name the script too, such as ${name} ${second} build.`;
	}
	return undefined;
}

function example(name: string): string {
	if (isPython(name)) return `${name} manage.py`;
	if (["npm", "pnpm", "yarn", "bun"].includes(name)) return `${name} test`;
	if (name === "git") return "git status";
	if (name === "make" || name === "gmake") return `${name} test`;
	if (["go", "cargo", "swift", "dotnet"].includes(name)) return `${name} test`;
	if (["sh", "bash", "zsh"].includes(name)) return `${name} ./script.sh`;
	if (name === "node" || name === "deno") return `${name} scripts/build.js`;
	return `${name} and a subcommand`;
}

/** The words of a rule typed by hand, such as "npm test". */
export function wordsOf(text: string): string[] {
	return text.trim().split(/\s+/).filter((word) => word !== "");
}

/** Whether two folders are the same place, as written. */
export function sameFolder(a: string, b: string): boolean {
	return resolve(a) === resolve(b);
}

/** A worktree pi² made (worktrees.ts keeps the record): its folder, and the main checkout of the repository it came from. */
export type MadeWorktree = { path: string; repo: string };

/**
 * The folder rules are kept for and matched against, for a conversation working in `folder`. Inside a worktree pi² made,
 * it is the same subfolder of the repository's main checkout, so one rule holds in the main checkout and in every
 * worktree pi² makes from it; anywhere else, the folder itself. Only pi²'s own records count, never a guess from a path.
 */
export function ruleFolder(folder: string, worktrees: readonly MadeWorktree[]): string {
	const here = resolve(folder);
	let best: { root: string; repo: string } | undefined;
	for (const worktree of worktrees) {
		const root = resolve(worktree.path);
		if (here !== root && !here.startsWith(root.endsWith(sep) ? root : root + sep)) continue;
		if (best === undefined || root.length > best.root.length) best = { root, repo: worktree.repo };
	}
	return best === undefined ? here : resolve(best.repo, relative(best.root, here));
}

/**
 * Whether `command`, run in `folder`, is covered by `rules`: every simple command in it is covered by a rule for that
 * folder (or, inside a worktree pi² made, for its rule folder: see `ruleFolder`) or is on the harmless list, and at least
 * one is covered by a rule. Anything else asks.
 */
export function judgeCommand(command: string, folder: string, rules: readonly CommandRule[], worktrees: readonly MadeWorktree[] = []): Verdict {
	const kept = ruleFolder(folder, worktrees);
	// A rule kept for the worktree's own folder, as rules were before they followed worktrees, still counts there.
	const here = rules.filter((rule) => (sameFolder(rule.folder, kept) || sameFolder(rule.folder, folder)) && ruleRefusal(rule.words) === undefined);
	if (here.length === 0) return { allowed: false, reason: "no rule for this folder" };
	const parsed = parseCommandLine(command);
	if ("ask" in parsed) return { allowed: false, reason: parsed.ask };
	const used: string[] = [];
	for (const tokens of parsed.commands) {
		const head = tokens[0]!;
		if (!head.literal) return { allowed: false, reason: "the command's name is not written out plainly" };
		if (head.text.includes("=")) return { allowed: false, reason: "it starts by setting a variable" };
		const name = programName(head.text);
		if (inSet(ALWAYS_ASK, name)) return { allowed: false, reason: `${name} always asks` };
		const rule = here.find((r) => r.words.length <= tokens.length && r.words.every((w, k) => tokens[k]!.literal && tokens[k]!.text === w));
		if (rule !== undefined) {
			const words = rule.words.join(" ");
			if (!used.includes(words)) used.push(words);
			continue;
		}
		if (HARMLESS.has(head.text)) continue;
		return { allowed: false, reason: `no rule covers ${head.text}` };
	}
	if (used.length === 0) return { allowed: false, reason: "no rule covers any part of it" };
	return { allowed: true, rules: used };
}

/** Programs whose second word picks what they do (`git status`, `npm test`); a rule offered for them includes it. */
const SUBCOMMANDS: ReadonlySet<string> = new Set([
	"git", "npm", "pnpm", "yarn", "bun", "deno", "swift", "cargo", "go", "make", "gmake", "ninja", "just", "brew", "pip", "pip3", "uv", "poetry", "pipenv", "pdm", "hatch",
	"gradle", "gradlew", "mvn", "mvnw", "dotnet", "gh", "rails", "rake", "bundle", "mix", "terraform", "tofu", "xcodebuild", "tuist", "pod", "fastlane", "flutter", "dart",
	"composer", "bazel", "bazelisk", "nx", "turbo", "lerna", "ng", "expo", "wrangler", "vercel", "netlify", "firebase", "aws", "gcloud", "az", "heroku", "fly", "flyctl",
	"npx", "bunx", "pnpx", "uvx", "pipx", "gem", "pulumi",
]);
/** A subcommand or script name: a plain name, not a path, an option or a value. */
const NAME = /^[a-z][a-z0-9_-]*(:[a-z0-9_-]+)*$/i;
const MODULE = /^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*$/;

/**
 * The words of the rule to offer for `command`: its program, and for a program with subcommands the subcommand
 * (`git status`, `npm run build`), never paths or values. Undefined when no rule could cover it: more than one command
 * that is not on the harmless list, a line that asks whatever the rules, or a rule that would be refused.
 */
export function proposeRule(command: string): string[] | undefined {
	const parsed = parseCommandLine(command);
	if ("ask" in parsed || parsed.commands.length === 0) return undefined;
	const harmless = (tokens: Token[]) => tokens[0]!.literal && HARMLESS.has(tokens[0]!.text);
	const others = parsed.commands.filter((tokens) => !harmless(tokens));
	const tokens = others.length === 1 ? others[0]! : parsed.commands.length === 1 ? parsed.commands[0]! : undefined;
	if (tokens === undefined || !tokens[0]!.literal) return undefined;
	const [first, second, third] = tokens as [Token, Token | undefined, Token | undefined];
	const words = [first.text];
	const name = programName(first.text);
	const plain = (token: Token | undefined, pattern: RegExp): token is Token => token !== undefined && token.literal && pattern.test(token.text);
	if (isPython(name) && second?.literal && second.text === "-m" && plain(third, MODULE)) words.push("-m", third.text);
	else if (inSet(SUBCOMMANDS, name) && plain(second, NAME)) {
		words.push(second.text);
		if (NEEDS_NAME.has(`${name} ${second.text.toLowerCase()}`) && plain(third, NAME)) words.push(third.text);
	}
	// Offered only if it would be accepted, and would then cover this very command.
	if (ruleRefusal(words) !== undefined) return undefined;
	return judgeCommand(command, "/", [{ folder: "/", words, createdAt: 0 }]).allowed ? words : undefined;
}
