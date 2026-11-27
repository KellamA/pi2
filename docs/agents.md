# Working on pi² as a worker agent

This page is for an agent that has been handed one or more GitHub issues in this repository, usually by an orchestrating agent, to take from reading to merged in `main` on its own. It says where such an agent is, what is not its to touch, how to use its tools, when to stop and what to report. The rules every contributor follows, for making a change, testing it safely and merging it, are in [CONTRIBUTING.md](../CONTRIBUTING.md), [CLAUDE.md](../CLAUDE.md) and [development.md](development.md). This page points to them rather than saying them again, so follow them as they are there.

The work is meant to be done without help. Nobody is watching your chat as you go, and a question you ask will not be answered, so decide, record why on the issue, and carry on. Stop early only for the cases under [When to stop](#when-to-stop).

As an agent of a pi² project, put what is truly the person's to decide, and does not stop your work meanwhile, to them with `needs_you` and carry on: their answer reaches you as you work, or the agent that handed you the work once you have finished. Use `ask_user`, which holds you until they answer, only when your next step needs the answer and there is nothing else to do meanwhile.

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
- `$PI2_SCRATCH`, which the system prompt names, works in a path given to a file tool as well as in a shell command: `read`, `write`, `edit`, `list_files`, `find_files` and `search_files` read a path beginning with `$PI2_SCRATCH` or `${PI2_SCRATCH}` as your conversation's scratch folder (see [architecture.md](architecture.md#a-scratch-folder)), and answer with the real path, which you can then use again. No other variable is expanded: a path beginning with `$HOME` is refused, and a `$` anywhere else is part of the name.
- A picture from `scripts/test-copy shot` goes inside your checkout. Put the ones worth keeping in `app/build/shots/<issue>/`, which git ignores: they stay after the copy is stopped, and a reviewer can read them from your worktree.
- If your model cannot look at pictures, say so in the first line of your report, do not read picture files, and check each state from what the copy and the engine answer and from the controls the computer tool lists.
- `scripts/test-copy reopen` puts the copy's window back at its smallest size and its sidebar at 250 points: run `scripts/test-copy size` (and `sidebar`) again after it.
- To make something that waits for the person in a copy (a question, a decision, a request for more reach, a proposed rule), send the demo orchestrator a message that begins `/tools` with a JSON list of tool calls; "The scripted demo model" in [development.md](development.md#the-scripted-demo-model) has the form.
- When you bring a branch that is not yours up to date, as a reviewer of another agent's pull request does, merge `origin/main` into it; do not rebase it. A rebase rewrites the author's commits, and their worktree can then not be removed.

## Read first

Read this page, [CLAUDE.md](../CLAUDE.md) and [CONTRIBUTING.md](../CONTRIBUTING.md) in full. Before you build, run or test anything, you must read all of [Testing safely](../CONTRIBUTING.md#testing-safely). Read the lists at the top of [development.md](development.md#what-to-read-for-what) and [architecture.md](architecture.md#what-to-read-for-what), then read only the sections that apply to your issue, and the page in `docs/` for the area you touch. The agent that hands out the work will usually name those sections. Read the issue with its comments:

```bash
gh issue view N --json title,body,comments --jq '.title, .body, (.comments[] | "--- comment ---\n" + .body)'
```

Plain `gh issue view N --comments` prints only the comments when it is not run in a terminal, and nothing at all for an issue with none.

## Issues

Keep each issue's record as [CLAUDE.md](../CLAUDE.md#issues-one-for-every-piece-of-work) says, from your worktree: its table gives each step with the `work` tool of a pi² project and with `scripts/issue`. For an issue you were given, that means:

- taking it before you change any file, unless your task begins "Work #N:" (the orchestrator's `work` `assign` made it yours);
- a note for each decision or dead end worth keeping, since nobody saw you make it;
- once the pull request is merged, the summary (`scripts/issue done`, or the tool's `finish`), then a check that the issue ended closed with no "in progress" label;
- an idea filed for anything worth doing outside your issue, and leave it.
- Do not classify issues (the labels `local model` and `cloud model`, the tool's `class`): the agent that handed out the work does that ([issue-classes.md](issue-classes.md)). If you think an issue is in the wrong class, say so in your report.

## Doing the work

1. Understand the problem in the code. Reproduce it where that is practical and safe.
2. Make the change, and keep it to the issue, in the [style](../CONTRIBUTING.md#style) the repository uses.
3. Add or extend an automated test for what you changed where one is possible, and update the docs that describe the behaviour you changed.
4. Check it as [Making a change](../CONTRIBUTING.md#making-a-change) and [Tests](development.md#tests) say for the part you touched. To see a change in the app, build it in your worktree and try it in a throwaway copy exactly as [Testing safely](../CONTRIBUTING.md#testing-safely) describes (`scripts/test-copy` does the steps), with `test-` and your issue number as the copy's suffix, such as `test-146`. On top of that:
   - Whether you can press anything in the copy depends on your agent. If its computer use has **Test copies of pi²** on ([computer-use.md](computer-use.md#clicking-in-test-copies)), you may: `computer` with the copy's bundle id, such as `dev.pi2.app.test-146` (`list_apps` shows it), works its buttons, menus, fields and sheets, with the approvals your agent's settings ask for. If it does not, don't try to click another way or ask for Accessibility from your shell. Use `test-copy show` and `size` (or `smallest`), `answer` for one approval, `fill` for long demo history, `press` for a control of the conversation page by its label (which the computer tool cannot reach either), and `shot` to check what the copy shows. Run `scripts/test-copy can-click <suffix>` before planning checks that need clicks: it answers yes (exit 0), no with its cause (exit 1), or cannot tell from here (exit 2), and only a no means the tool cannot read and click the copy now; even a yes cannot tell whether pi² has the Accessibility permission, which the tool's own answer then says ([#612](computer-use.md#limits)). After rebuilding, `test-copy reopen` replaces just the app and keeps the copy's data and engine. `--show`, `--menu` and the copy's engine socket still work; say in the pull request which controls went untried. A copy whose suffix does not begin with `test` is never covered by computer use.
   - Take a picture of the copy's own window only: with `scripts/test-copy shot`, or with the `look` and computer tools on that copy. Never capture a region of the screen or the whole screen (`screencapture -R`, or `screencapture` with no window named): it shows whatever the person has open, and it can put the Screen Recording prompt on their screen, which no test may do ([Testing safely](../CONTRIBUTING.md#rules)).
   - Before any screen capture, check `CGPreflightScreenCaptureAccess()` from your own shell. If it says false, do not capture, and say in the pull request that the change was not seen on screen. Your commands act under the installed pi²'s Screen Recording, so the check answers for them ([architecture.md](architecture.md#whose-macos-permissions-commands-have)). Never capture from a copy's own agents (`/bash` through its demo model): they act under the copy's permissions, which it never has, and the capture puts a prompt on the person's screen.
   - If your own model cannot see pictures, `look` can have one looked at by a model that can, if the person has chosen one ([pictures.md](pictures.md#a-model-that-looks-at-pictures)): save what you need judged to a picture file (a screenshot with `scripts/test-copy shot`, say) and ask your question about it, rather than saying you cannot see it. Without a chosen model, say plainly what went unseen.
   - Other agents are building and testing at the same time. No check depends on how fast the Mac is ([Tests](development.md#tests)), so a failure is a real one until shown otherwise: run that test file alone and compare with unchanged `origin/main` before you conclude anything, and say what you saw. Do not run the suite over and over.
   - Do not load the Mac on purpose, such as with busy loops to reproduce a problem under load, without saying so on the issue first. Keep it short, and stop what you started by its pid.
   - For Projects, `test-copy fill <suffix> --project` seeds a demo hub; repeat for the Dashboard. Use `--show 'project:Demo project#now' --hub both` at launch or `show <suffix> 'project:Demo project#work' --hub board-folded` live. The hub is drawn, an agent's conversation in place of the board too, and so is the Dashboard: `show` answers once it has drawn them, and `project-view.json` in the copy's data folder records each request. `answer <suffix> <need-id> '<json answer>'` takes a contract `NeedAnswer`; see [Choosing what a copy shows](development.md#choosing-what-a-copy-shows).
5. Commit in your worktree, staging files by name and checking that nothing personal is in the commit ([Testing safely](../CONTRIBUTING.md#rules)). Mention the issue in the message. Do not use `git stash`: a repository has one list of stashes for all its worktrees, so your `git stash pop` can apply another agent's work, and theirs yours. To set work aside, commit it on a branch of its own, as [Several issues](#several-issues) says.
6. If the change is worth an entry, add a file for it to `changelog.d`, named after your issue (`changelog.d/N.md`), as [Changelog entries](../CONTRIBUTING.md#changelog-entries) says, and run `node app/changelog.mjs check`. Never add it to `CHANGELOG.md` itself: a file of its own is what keeps your entry from conflicting with other agents' entries.
7. Push the branch and open a pull request. Its body says what changed and why, has `Fixes #N`, and says plainly what was and was not tested. In a pi² project, open it with `work` `pull_request` and the issue's number as `id`, which adds `Fixes #N`; give a body written to a file as `text_file` (`$PI2_SCRATCH/pr-body.md`), since `text` takes the words themselves and refuses a path. A long `note` or `finish` can be given the same way. To change the body or title of a pull request the tool opened, such as to add results that came in while CI ran, use `work` `update_pull_request` with its number as `id` and the new body as `text_file`, never `gh pr edit --body-file`, which drops the line naming you, `Fixes #N` and the tool's marker. Anywhere else, use `gh pr create`. **Write the body with the write tool into a file in your scratch folder, then pass `--body-file`.** For example, after writing `pr-body.md` there:

   ```bash
   gh pr create --title 'Short title' --body-file "$PI2_SCRATCH/pr-body.md"
   ```

   Do the same for pull request and issue comments (`gh pr comment N --body-file "$PI2_SCRATCH/comment.md"`, `gh issue comment N --body-file "$PI2_SCRATCH/comment.md"`). Give `scripts/issue` short literal summaries, not text assembled by command substitution; a longer text goes in a file, passed with `--body-file`. Never build a body in a shell argument, command substitution or here-document, nor write its file with one: on macOS's Bash 3.2, even a quoted here-document inside `$(...)` can be misparsed when the body holds an apostrophe, and words in Markdown backticks then run as commands, which once started a test copy while opening a pull request (#330). For a part of an issue write `Part of #N`, and never the words close, fix or resolve before `#N` in any sentence: GitHub reads them as closing it.
8. Merge it as step 7 of [Making a change](../CONTRIBUTING.md#making-a-change) says, in a project too (the tool's `merge` is the orchestrator's): run `scripts/auto-merge <number>` as soon as it is open, do something useful while the checks run, and run it again until it says `Merged.` before you call the work done. Run it again after every push too; it exits 0 once merged, 3 while it waits for checks, 4 when it touches a path that waits for the owner's review (leave it open, and mark the issue waiting on the owner; [iphone.md 12.3](iphone.md#123-before-anything-is-built-the-repository-p0)), and 1 when something needs you, and says what. If `main` has moved and your branch conflicts, merge `origin/main` into your branch, keeping the other agents' work and their changelog entries, check again, and push; after merging `main`, run `npm --prefix engine ci` again if the type-check or a test says the installed dependencies are older than the checkout. A check cancelled because no runner took the job in time (`gh run view <run-id>` shows "The job was not acquired by Runner of type hosted even after multiple attempts") is not a failure of your change: CI runs it again by itself, three times at most ([CI](development.md#ci)); if it is still not running a few minutes later, run `gh run rerun <run-id> --failed`, then `scripts/auto-merge <number>`. Do not pass `--delete-branch` to `gh pr merge` (it tries to switch a checkout). GitHub deletes the remote branch once the pull request is merged; never delete the remote branch of one that is not, which closes it.
9. Clean up as [Testing safely](../CONTRIBUTING.md#testing-safely) says: the throwaway copy, its data folder, preferences and Keychain items, and any process you started. Leave your worktree and your branch as they are, for the agent that gave you the work to remove once it has your report.

### Several issues

Do them one after another, each with its own pull request, unless they change the same lines for the same reason, in which case one pull request may fix both. Use your one worktree for all of them.

While a pull request is open, every commit you push to its branch joins it. So do the next issue's work on a branch of its own: `git fetch origin` and start a new branch for it from `origin/main` in the same worktree ([worktrees.md](worktrees.md#another-branch-in-the-same-worktree)). If the next issue builds on the open pull request, wait until that has merged first. If the open pull request needs a merge of `main` while you are on the next branch, commit what you have there, finished or not (it need not be pushed), switch back to the pull request's branch, merge `origin/main`, push, and switch back again. Once a pull request has merged, you may instead `git merge origin/main` into its branch and carry on there, which makes the remote branch anew when you push. Never check out a branch another worktree has, and never set work aside with `git stash`. Name the branches you used in your report, and end with everything merged and nothing uncommitted, so the worktree can be removed.

## Never

- Release, tag, or change the version (`app/VERSION`), or change a section of `CHANGELOG.md` for a version already released.
- Touch the installed pi², its engine, its data folder (apart from your worktree), its Keychain service or its login item, call a model provider, or stop a process by name. [Testing safely](../CONTRIBUTING.md#rules) has these rules in full.
- Push to `main` directly, or force-push anything.

## When to stop

Make ordinary design choices yourself and record them in a note on the issue. Stop, without merging, only if:

- the fix would widen what an agent can do without asking, or change what a person is asked to approve, beyond what the issue describes;
- it needs something only the person can do: a macOS permission, their sign-in, their running pi²;
- the issue turns out to be much larger than it reads, or wrong.

Then mark the issue waiting on what you need (or blocked), leave the branch pushed, and say so in your report.

## The harness itself

pi² is developed with pi². If a tool you were given got in your way, was missing, misled you, or made you work around it (a limit, a refusal, something slow, something you could not see), that is worth knowing. Do not fix it as part of your issue. File it as an idea if it is clear enough to act on, and list it in your report either way.

Before you file, check three things. Is the cause outside pi²: the pi² you run in was closed, the Mac restarted, or the screen was locked? Then it is not a fault in the harness; say it in your report instead. Does an open issue already cover it (`list`)? Then add a note there. Is it clear enough for someone else to act on? If you are unsure of any of these, put it in your report and do not file: the agent that handed out the work decides.

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
- **Computer use:** on, with **Test copies of pi²** on and no apps, so that the agent can click in the copies it starts, and nothing else. It needs Accessibility for pi², as [computer-use.md](computer-use.md#clicking-in-test-copies) says; leave **Ask before each action** on unless you are content for it to act in its copies without asking. Without the switch, a worker can only look at its copies.
- **Set-up command:** `npm --prefix engine ci`. Every new worktree lacks the engine's packages, which its type-check and tests need, and this puts them back once, before the agent's first answer. Leave building the app out of it: not every issue touches the app, and a build is slow and is better started by the agent that needs it.
- **Instructions:** who the agent is and how it works, in a few lines, and where the rest is. For example:

  > You work on the pi² repository (https://github.com/KellamA/pi2). An orchestrating agent hands you GitHub issues to take from reading to merged in `main`, each in a git worktree of your own that pi² makes for you. Nobody watches your chat and questions go unanswered: decide, record why on the issue, and carry on. Before anything else, read `docs/agents.md` in your worktree and follow it. If a tool or limit of the harness gets in your way, say so in your report.

The task the orchestrating agent gives names the issues, the order to take them in, and anything this page cannot know (a release just made, another agent changing the same files), and points to `docs/agents.md` in the worker's own worktree, which is the version of this page that matches the code it works on.
