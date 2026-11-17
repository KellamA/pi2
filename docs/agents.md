# Working on pi² as a worker agent

This page is for an agent that has been handed one or more GitHub issues in this repository, usually by an orchestrating agent, to take from reading to merged in `main` on its own. It says where such an agent is, what is not its to touch, how to use its tools, when to stop and what to report. The rules every contributor follows, for making a change, testing it safely and merging it, are in [CONTRIBUTING.md](../CONTRIBUTING.md), [CLAUDE.md](../CLAUDE.md) and [development.md](development.md). This page points to them rather than saying them again, so follow them as they are there.

The work is meant to be done without help. Nobody is watching your chat as you go, and a question you ask will not be answered, so decide, record why on the issue, and carry on. Stop early only for the cases under [When to stop](#when-to-stop).

## Where you are

- You are an agent running inside pi², on a Mac where pi² is in real use. The pi² you run in is an installed release. Its engine, data folder, Keychain items, login item and macOS permissions belong to the person whose Mac it is: never drive, quit, restart or signal them ([Testing safely](../CONTRIBUTING.md#testing-safely)).
- Your folder is a git worktree pi² made for you, on a branch of your own, started from `origin/main`. pi² told you its path and its branch. Work only there: reading the code, editing, building, testing, committing. Other agents are working in worktrees of their own at the same moment.
- pi² keeps worktrees in its data folder (`worktrees/` in `~/Library/Application Support/pi2`; see [worktrees.md](worktrees.md)). Your worktree is the one place in that folder that is yours: work in it freely, and in nothing beside it.
- The repository's main checkout, the folder the worktrees were made from, is not yours. Do not edit files in it, switch its branch, pull or commit in it, or run `app/build.sh` or `npm ci` in it.
- Every shell command starts in your worktree, so do not begin commands with `cd` to it. A `cd` inside one command does not carry over to the next.

## Your worktree

Check where you are before anything else: `git rev-parse --show-toplevel` and `git status -sb`. If you are not in a worktree of your own on the branch your task names, stop and say so in your report, rather than working in a shared folder.

A new worktree has none of the files git ignores, installed packages among them. If your agent has no set-up command that installed them (pi² tells you whether one ran and how it ended), run `npm --prefix engine ci` before the engine's checks.

## Using your tools

- Read files with `read` (a range of lines, for a long file) and change them with `edit` or `write`, not with `cat`, `sed -i` or a script in the shell. The person then sees what you changed as a diff, and you get back less text.
- Do not cut a command's output with `head`, `tail` or `grep` to keep it short: what you cut is gone, and you end up running the command again. Let the tool shorten it (it keeps the whole output in a file and says where), or send a long run's output to a file in your conversation's scratch folder (`$PI2_SCRATCH`, which the system prompt names; see [architecture.md](architecture.md#a-scratch-folder)) and read the part you need.
- A command in the foreground is stopped after two minutes unless you pass `timeout` (ten minutes at most). A long run, such as the whole test suite or a build, goes in the background with `background: true`; read it with the `background` tool and `wait`. Keep each `wait` to 240 seconds or less and ask again: a longer pause loses the prompt cache, and the whole conversation is paid for again.
- When you need several files, or several lookups that do not depend on each other, send the calls together in one answer instead of one a turn. Each turn reads the whole conversation again.

## Read first

[CLAUDE.md](../CLAUDE.md), [CONTRIBUTING.md](../CONTRIBUTING.md) (all of it, and [Testing safely](../CONTRIBUTING.md#testing-safely) before you build, run or test anything), [development.md](development.md), [architecture.md](architecture.md), and the page in `docs/` for the area you touch. Then the issue with its comments:

```bash
gh issue view N --json title,body,comments --jq '.title, .body, (.comments[] | "--- comment ---\n" + .body)'
```

Plain `gh issue view N --comments` prints only the comments when it is not run in a terminal, and nothing at all for an issue with none.

## Issues

Keep each issue's record as [CLAUDE.md](../CLAUDE.md#issues-one-for-every-piece-of-work) says, from your worktree. For an issue you were given, that means:

- `scripts/issue take N` before you change any file;
- `scripts/issue note N "..."` for each decision or dead end worth keeping, since nobody saw you make it;
- `scripts/issue done N "..."` once the pull request is merged, and then `gh issue view N` to check it ended closed with no "in progress" label;
- `scripts/issue idea "Title" -b "..."` for anything worth doing outside your issue, and leave it.

## Doing the work

1. Understand the problem in the code. Reproduce it where that is practical and safe.
2. Make the change, and keep it to the issue, in the [style](../CONTRIBUTING.md#style) the repository uses.
3. Add or extend an automated test for what you changed where one is possible, and update the docs that describe the behaviour you changed.
4. Check it as [Making a change](../CONTRIBUTING.md#making-a-change) and [Tests](development.md#tests) say for the part you touched. To see a change in the app, build it in your worktree and try it in a throwaway copy exactly as [Testing safely](../CONTRIBUTING.md#testing-safely) describes (`scripts/test-copy` does the steps), with your issue number as the copy's suffix. On top of that:
   - Before any screen capture, check `CGPreflightScreenCaptureAccess()` from your own shell. If it says false, do not capture, and say in the pull request that the change was not seen on screen. Your commands act under the installed pi²'s Screen Recording, so the check answers for them ([architecture.md](architecture.md#whose-macos-permissions-commands-have)). Never capture from a copy's own agents (`/bash` through its demo model): they act under the copy's permissions, which it never has, and the capture puts a prompt on the person's screen.
   - Other agents are building and testing at the same time. No check depends on how fast the Mac is ([Tests](development.md#tests)), so a failure is a real one until shown otherwise: run that test file alone and compare with unchanged `origin/main` before you conclude anything, and say what you saw. Do not run the suite over and over.
   - Do not load the Mac on purpose, such as with busy loops to reproduce a problem under load, without saying so on the issue first. Keep it short, and stop what you started by its pid.
5. Commit in your worktree, staging files by name and checking that nothing personal is in the commit ([Testing safely](../CONTRIBUTING.md#rules)). Mention the issue in the message. Do not use `git stash`: a repository has one list of stashes for all its worktrees, so your `git stash pop` can apply another agent's work, and theirs yours. To set work aside, commit it on a branch of its own, as [Several issues](#several-issues) says.
6. If the change is worth an entry, add a file for it to `changelog.d`, named after your issue (`changelog.d/N.md`), as [Changelog entries](../CONTRIBUTING.md#changelog-entries) says, and run `node app/changelog.mjs check`. Never add it to `CHANGELOG.md` itself: a file of its own is what keeps your entry from conflicting with other agents' entries.
7. Push the branch and open a pull request with `gh pr create`. Its body says what changed and why, has `Fixes #N`, and says plainly what was and was not tested.
8. Merge it as step 7 of [Making a change](../CONTRIBUTING.md#making-a-change) says: run `scripts/auto-merge <number>` as soon as it is open, do something useful while the checks run, and run it again until it says `Merged.` before you call the work done. Run it again after every push too; it exits 0 once merged, 3 while it waits for checks, and 1 when something needs you, and says what. If `main` has moved and your branch conflicts, merge `origin/main` into your branch, keeping the other agents' work and their changelog entries, check again, and push. A check that shows as failed may only have been cancelled because no runner took the job in time: its annotation says "The job was not acquired by Runner of type hosted even after multiple attempts" (`gh run view <run-id>` shows it). That is not a failure of your change. CI runs such a job again by itself, three times at most ([CI](development.md#ci)); if it is still not running a few minutes later, run it again yourself with `gh run rerun <run-id> --failed`, then `scripts/auto-merge <number>`. Do not pass `--delete-branch` to `gh pr merge` (it tries to switch a checkout). GitHub deletes the remote branch once the pull request is merged; never delete the remote branch of one that is not, which closes it.
9. Clean up as [Testing safely](../CONTRIBUTING.md#testing-safely) says: the throwaway copy, its data folder, preferences and Keychain items, and any process you started. Leave your worktree and your branch as they are, for the agent that gave you the work to remove once it has your report.

### Several issues

Do them one after another, each with its own pull request, unless they change the same lines for the same reason, in which case one pull request may fix both. Use your one worktree for all of them.

While a pull request is open, every commit you push to its branch joins it. So do the next issue's work on a branch of its own: `git fetch origin` and start a new branch for it from `origin/main` in the same worktree ([worktrees.md](worktrees.md#another-branch-in-the-same-worktree)). If the next issue builds on the open pull request, wait until that has merged first. If the open pull request needs a merge of `main` while you are on the next branch, commit what you have there, finished or not (it need not be pushed), switch back to the pull request's branch, merge `origin/main`, push, and switch back again. Once a pull request has merged, you may instead `git merge origin/main` into its branch and carry on there, which makes the remote branch anew when you push. Never check out a branch another worktree has, and never set work aside with `git stash`. Name the branches you used in your report, and end with everything merged and nothing uncommitted, so the worktree can be removed.

## Never

- Release, tag, or change the version (`app/VERSION`), or change a section of `CHANGELOG.md` for a version already released.
- Touch the installed pi², its engine, its data folder (apart from your worktree), its Keychain service or its login item, call a model provider, or stop a process by name. [Testing safely](../CONTRIBUTING.md#rules) has these rules in full.
- Push to `main` directly, or force-push anything.

## When to stop

Make ordinary design choices yourself and record them with `scripts/issue note`. Stop, without merging, only if:

- the fix would widen what an agent can do without asking, or change what a person is asked to approve, beyond what the issue describes;
- it needs something only the person can do: a macOS permission, their sign-in, their running pi²;
- the issue turns out to be much larger than it reads, or wrong.

Then run `scripts/issue wait N "what you need"` (or `block`), leave the branch pushed, and say so in your report.

## The harness itself

pi² is developed with pi². If a tool you were given got in your way, was missing, misled you, or made you work around it (a limit, a refusal, something slow, something you could not see), that is worth knowing. Do not fix it as part of your issue. File it with `scripts/issue idea` if it is clear enough to act on, and list it in your report either way.

## Your report

End with a short report, as your final answer:

- each issue: what was wrong, what you changed, the pull request's number, and whether it is merged;
- what was tested, how, and what was not;
- decisions you made that the owner might have made differently;
- ideas you filed, with their numbers;
- limitations of the harness you met;
- anything left behind that needs cleaning up.

## Setting up a worker agent

This part is for the person who sets up the agent that does this work in pi², and for the agent that hands it work. What is true of the repository, and changes when its rules change, belongs on this page, where it is reviewed in the same pull request as the rule. What is true of the agent whatever it is given to do belongs in the agent's settings ([worktrees.md](worktrees.md#a-set-up-command)):

- **Folder:** the repository's main checkout. Worktrees are made from it, and the set-up command runs only in worktrees of the agent's own repository.
- **Set-up command:** `npm --prefix engine ci`. Every new worktree lacks the engine's packages, which its type-check and tests need, and this puts them back once, before the agent's first answer. Leave building the app out of it: not every issue touches the app, and a build is slow and is better started by the agent that needs it.
- **Instructions:** who the agent is and how it works, in a few lines, and where the rest is. For example:

  > You work on the pi² repository (https://github.com/KellamA/pi2). An orchestrating agent hands you GitHub issues to take from reading to merged in `main`, each in a git worktree of your own that pi² makes for you. Nobody watches your chat and questions go unanswered: decide, record why on the issue, and carry on. Before anything else, read `docs/agents.md` in your worktree and follow it. If a tool or limit of the harness gets in your way, say so in your report.

The task the orchestrating agent gives names the issues, the order to take them in, and anything this page cannot know (a release just made, another agent changing the same files), and points to `docs/agents.md` in the worker's own worktree, which is the version of this page that matches the code it works on.
