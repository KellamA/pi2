# Allowed commands

With tool access set to **Ask first**, shell commands wait for you unless you have already allowed them. Approving every `git status` and `npm test` gets old, but **Always Allow bash Here** gives one conversation the whole shell. Allowed commands let one agent run particular commands in one folder without asking, in every conversation from then on.

## Adding an allowed command

**From an approval.** When a command waits for you, the approval has a fourth choice next to **Allow Once**, **Always Allow bash Here** and **Deny**: **Always Allow `npm test` Here**. Choosing it runs the command and adds it to the agent's allowed commands. When the chosen folder is in a repository's main checkout, so that the entry also holds in the repository's pi² worktrees (see below), the button says **Always Allow `npm test` in This Repository**. That is the case in the main checkout and in a worktree pi² made, where the entry is kept for the same folder of the main checkout; hovering over the button says where it applies. "Here" means the entry holds in this one folder only, such as a folder outside any repository or a worktree pi² did not make. A long command is cut short in the button (in the middle in the Inbox, at its end in the conversation), so the button keeps saying where it applies; the whole command is shown above it.

The words are pi²'s proposal: the program, and for a program with subcommands the subcommand (`git status`, `npm test`, `npm run build`, `swift build`, `python3 -m pytest`), never the paths, values or options that follow. The choice is offered only when the proposed words would cover the command: one command (apart from the harmless ones listed below, so `npm test 2>&1 | tail -20` offers `npm test`), nothing in it that always asks, and words pi² accepts. The app sends back only the choice; the engine saves the entry it proposed, whatever the page shows.

**By hand.** In the agent's settings, under **Allowed commands**, type the words (such as `npm test`) and choose the folder; the agent's own folder is offered first. An entry added by hand passes exactly the same checks.

## What an allowed command covers

- **One agent, one folder.** The conversation must work in the folder chosen for the allowed command. A subfolder or a parent folder does not count. A conversation with no folder chosen works in pi²'s scratch folder, and an allowed command added there is for that folder.
- **That folder in the repository's pi² worktrees too.** When the chosen folder is in a git repository's main checkout, the entry also holds in the same folder of every worktree pi² made from that repository ([worktrees.md](worktrees.md)). Allowing `npm test` in `~/code/webapp` covers `npm test` in every conversation of that agent that works at the top of its own worktree of `webapp`. An entry added inside one of those worktrees, from an approval or by hand, is kept for the same folder of the main checkout, so it holds in the main checkout and in the other worktrees as well, and outlives the worktree it was made in. Subfolders still match exactly: an entry for `~/code/webapp/engine` covers `engine` in each worktree, not the top of it. Only worktrees pi² made count, and only until pi² removes them: pi² goes by its own record of each, not by where a folder is. A worktree made with `git worktree add` or by another tool is a folder like any other, and a worktree of another repository is that repository's.
- **Commands that start with its words, as whole words.** `git status` covers `git status -sb` and `git status --short`, but not `git statusx`, `git stat`, or `git -C /elsewhere status`. Words are matched exactly, case included: `NPM test` asks.
- **Anything after the words.** Options, file names, quoted text, `*.ts` and `~/x` are all fine after them.
- **Every conversation of that agent in that folder:** new ones, sub-chats where another agent hands work to it, and scheduled runs.
- **A command still waiting when the engine stops.** Its approval is asked again when the engine starts, and the command is judged afresh: if an allowed command covers it by then, it runs without asking. Otherwise it asks again, and offers an allowed command if it can.
- **Only under Ask first.** With tools off or "Read files" there is no shell at all; with full access nothing asks anyway, and neither does anything for an agent with [Allow everything](allow-everything.md) on. **Always Allow bash Here** still covers the whole shell for one conversation.
- **The same command left running in the background.** Allowing `npm run dev` covers both a command the agent waits for and one it starts with `background: true` and leaves running ([background.md](background.md)). Allow a server or a watcher only if you are content for the agent to start it unasked; Activity lists what is running, with its output and a Stop button.

A line with several commands joined by `&&`, `||`, `;`, `|` or line breaks runs without asking only when **every** command in it matches an allowed command or is one of these harmless ones: `echo`, `true`, `false`, `pwd`, `cat`, `head`, `tail`, `wc`, `grep`. At least one command must match an allowed command: `echo hi` on its own still asks.

Quotes and backslashes are read the way bash reads them, so `npm test -- 'a;b'` is one command with the argument `a;b`, and `"npm" "test"` is `npm test`. A comment (`# …`) runs to the end of its line. Sending one output to another (`2>&1`, `>&2`) and throwing output away (`>/dev/null`, `2>/dev/null`, `&>/dev/null`) are allowed: they write no file.

## What always asks

pi² reads the command line itself before deciding. Anything it is not certain about makes the whole line ask, just as it would with no allowed commands:

- `$` outside single quotes: variables, `$(…)`, `$((…))`, `${…}`, `$'…'`.
- Backticks.
- `(` and `)`: subshells, process substitution (`<(…)`, `>(…)`), arithmetic.
- `&` on its own (running in the background), `|&`, `;;`, `!`. An agent that wants a command left running starts it with `background: true` instead, which an allowed command can cover.
- Writing to a file: `>`, `>>`, `>|`, `<>`, `&>`, `>&file`, except onto `/dev/null`.
- Reading from a file or a here-document: `<`, `<<`, `<<<`.
- Bash's keywords as a command: `if`, `for`, `while`, `case`, `{ … }`, `function`, `time`, `[[ … ]]`.
- Changing folder: a command that starts with `cd`, `pushd` or `popd`. To work in a subfolder without changing folder, give the program the folder instead, and allow the command where the conversation works. Allowing `npm test` covers `npm test --prefix engine`, and allowing `swift build` covers `swift build --package-path app`. (`npm --prefix engine test` does the same, but doesn't start with `npm test`, and `npm --prefix` cannot be added.)
- Running text or another program: `eval`, `exec`, `source`, `.`, `env`, `command`, `builtin`, `xargs`, `sudo`, `su`, `nohup`, `nice`, `timeout`, `watch`, `xcrun`, `open`, `osascript` and the like.
- Changing how later commands run: `export`, `set`, `alias`, `hash`, `trap`, `shopt`, `declare`, `read`, `enable` and the like.
- Setting a variable before the command (`FOO=bar npm test`).
- A command name that is not written out plainly: a wildcard, `{a,b}` or `~` in it.
- An unclosed quote, a backslash at the very end, a control character, or a missing command next to `&&`, `||` or `|`.
- Another folder, or another agent.

## What you cannot add

pi² refuses entries that would amount to allowing anything, and says why:

- **A program that runs whatever it is given, on its own:** shells (`sh`, `bash`, `zsh`), interpreters (`python`, `python3`, `node`, `ruby`, `perl`, `swift`), runners (`npx`, `uvx`), and tools whose subcommands do anything (`git`, `npm`, `make`, `go`, `cargo`, `brew`). Add what it should run: `git status`, `npm test`, `python3 manage.py`, `bash ./scripts/check.sh`.
- **Such a program followed by an option,** which is where code written on the spot goes: `python3 -c`, `node -e`, `bash -c`, `git -c`, `git -C`, `npm --prefix`. (`python3 -m pytest` is allowed: a module, named.)
- **Subcommands that run other programs or throw work away for good:** among them `npm exec`, `npm install`, `npm config`, `pnpm dlx`, `yarn dlx`, `go run`, `uv run`, `deno run`, `brew install`, `gh api`, `git config`, `git push`, `git pull`, `git fetch`, `git clone`, `git rebase`, `git clean`, `git submodule`. `npm run` must name the script: `npm run build`.
- **Programs that always ask:** those that delete or move files anywhere (`rm`, `cp`, `mv`, `dd`, `chmod`), reach other machines (`curl`, `wget`, `ssh`, `rsync`), change the Mac's settings (`defaults`, `launchctl`, `security`), run commands of their own (`find`, `awk`, `sed`, `less`, `vim`, `sqlite3`), containers (`docker`, `kubectl`), and everything in the "always asks" list above.
- **Words that are not plain:** quotes, `$`, `;`, `|`, `&`, `>`, `<`, `(`, `)`, wildcards and `~` cannot be part of an allowed command. An entry has at most eight words.

The complete lists are in `engine/src/rules.ts`. An entry saved before a word was added to them stops working: allowed commands are checked again every time they are used.

## What you trust when you allow a command

An allowed command trusts its program with **any options that follow its words**. That is what makes `git status -sb` work, and it is also its limit: some programs have options that run other programs (for example `make --eval`, or npm's `--script-shell`). Add only a command you would let the agent run with any options, in that folder.

Allowing a script (`./run-tests`, or `npm test`, which runs the script in `package.json`) lets it run whatever that script says when it runs, including changes made to it since. Under Ask first, the agent cannot change files without asking you, but a command you allow could.

An allowed command for a repository's folder holds on whatever branch each of its pi² worktrees is on, and a branch can change what a command runs: in a worktree, `npm test` runs the `test` script of that branch's `package.json`, and `./run-tests` that branch's copy of the script. That includes a branch you had pi² check out by name, and one another agent changed in its own worktree.

## Seeing it happen

A command that ran because it matched an allowed command says so on its row in the conversation, once it has finished: "matched allowed command: `npm test`". A command you allowed yourself, or one run with full access, has no such note.

## Reviewing and removing allowed commands

Open the agent's settings. **Allowed commands** lists each entry's words and its folder (shortened with `~`; for an entry added in a pi² worktree, the main checkout's folder), with a remove button. Adding and removing take effect at once, without Save; saving the agent never changes its allowed commands. Deleting an agent deletes its allowed commands with it.

## For developers

The code still calls allowed commands **rules**. Storage, file names in the data folder, requests and events are unchanged; there is no migration.

- `engine/src/rules.ts` is pure: `parseCommandLine` (the reader), `judgeCommand` (allowed commands, folder and line to a verdict), `ruleRefusal` (why an entry cannot be added), `proposeRule` (the words to offer) and `ruleFolder` (the folder entries are kept and matched for: inside a worktree pi² made, the same folder of the main checkout). The worktrees it is given are pi²'s own records (`madeWorktrees` in `engine/src/worktrees.ts`); an older entry kept for a worktree's own folder still holds in that folder.
- Allowed commands live on the agent, as `commandRules: { folder, words, createdAt }[]` in the agents document, and change only through `rules.add { agentId, folder, command }`, `rules.remove { agentId, folder, words }` and an approval answered `inbox.decide { decision: "rule" }`. `agents.save` keeps the stored entries whatever it is sent.
- The check is in the `beforeTool` hook in `engine/src/extensions.ts`, for `bash` only and only under Ask first. A bash approval carries `rule: { words, folder }` when there is an allowed command to offer, with `worktrees: true` when it will also hold in the repository's pi² worktrees (its folder is in a main checkout); the button then ends "in This Repository" rather than "Here" (`ruleOffer` in `app/Web/transcript/tools.js`, `RuleOffer.place` in the app). A command let through this way gets `details.allowedBy` (the matched entries' words) on its result, added by the `afterTool` hook; the transcript and the SwiftUI fallback show it.
- `node test/rules.ts` from `engine/` (also part of `npm test`) runs `engine/test/rules.ts`: the reader, matching, refusals and offers, many attempts to slip a second command past a check, and some 6,000 random lines. Each allowed line is then run by the Mac's own `/bin/bash` in a folder of its own, with only stand-in programs on its `PATH`, to check that bash runs nothing else and writes no file. `engine/test/engine.ts` covers allowed commands and approvals asked again after a restart, and `engine/test/worktrees.ts` covers allowed commands in worktrees.
