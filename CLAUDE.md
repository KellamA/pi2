# Working on pi²

These are the project's instructions for any agent working in this repository, whatever tool it runs in: Claude Code, pi² itself, or another.

Start with [CONTRIBUTING.md](CONTRIBUTING.md), [docs/development.md](docs/development.md) and [docs/architecture.md](docs/architecture.md). Before you build, run or test anything, read [Testing safely](CONTRIBUTING.md#testing-safely) in CONTRIBUTING.md: the Mac you are working on may be running pi² for real work.

If you were handed issues to finish on your own, in a worktree of your own (as a worker of an orchestrating agent), also read [docs/agents.md](docs/agents.md) and follow it: where you are, what is not yours to touch, when to stop and what to report.

## Issues: one for every piece of work

Every task an agent does in this repository gets a GitHub issue, so there is a record of what was done and a backlog to choose from. This is the rule whichever tool you run in. `scripts/issue` does the bookkeeping with `gh`.

- **Starting work:** before changing any file, run `scripts/issue start "Short title" -b "What and why, in a few lines"`. If the work is an existing issue, run `scripts/issue take N` instead. Run `scripts/issue list` to see what is open.
- **While working:** `scripts/issue note N "..."` for anything worth remembering (a decision, a dead end).
- **Ending a turn before the work is finished:** `scripts/issue wait N "what you need from the person"`, or `scripts/issue block N "why"`. Run `scripts/issue take N` when you pick it up again.
- **Finished:** `scripts/issue done N "what changed, and what was and was not verified"`. If it is abandoned: `scripts/issue drop N "why"`. Run it even when the issue is already closed, as it is once a pull request with `Fixes #N` is merged: it posts the summary either way, takes the status label off, and closes the issue only if it is still open.
- **Ideas for later:** when you notice something worth doing that is outside the task, file it with `scripts/issue idea "Title" -b "..."` rather than doing it.
- **Not tracking:** only if GitHub cannot be reached, or the person said not to track something, run `scripts/issue skip "why"`.
- Mention the issue in commit messages and pull requests (`Fixes #N` in a pull request closes it on merge).
- A question that changes no files needs no issue.
- **Checking the board:** `scripts/issue audit` lists what is wrong (a closed issue with a status label, an open one with none or more than one, one in progress with no activity for a day, an agent's issue closed as completed with no `**Done.**` summary) and exits non-zero if anything is. It changes nothing. A workflow, `.github/workflows/issue-labels.yml`, takes the status labels off any issue that is closed, however it was closed, and puts `backlog` on one reopened with no status label.

The repository is public, and so are its issues. Write them for any reader: no personal details, keys, or paths from this Mac (the script turns the home folder into `~`).

### The backstop under Claude Code

Under Claude Code only, two hooks in `.claude/settings.json` (both run `scripts/issue-hook`) catch a step that was missed: an edit to a file in the repository is refused until the session has an issue in progress, and the end of a turn with an issue still marked in progress asks for its status first. Setting `PI2_ISSUES=off` turns the hooks off.

"In the repository" means in any checkout of it, the main one or a worktree, whichever of them the session's own folder is: a session in a worktree is refused an edit in the main checkout, and the other way round. The hook knows the repository by its own place, not by the session's folder, so a session whose folder has moved into another repository, or out of any, is refused an edit here too. A checkout's own `.git/` and `.claude/` (settings, memory) are left alone, as are files in no repository and files in a different one.

The hooks know the session's issues from the `[pi2-issue]` lines `scripts/issue` printed for it: the output of a shell command that runs `scripts/issue`, the agent's or the person's (`!`). The same line anywhere else in the transcript, in a file, a log, an issue or another session's transcript the session read, is only quoted and does not count. Before the end of a turn is held up, GitHub is asked whether the issue is still open and in progress; one closed since (by a merged pull request, say) or paused by another session needs nothing. If GitHub gives no answer within ten seconds, the turn ends anyway and the person is told which issue could not be checked: asking the agent to update an issue it cannot reach, or one that may be closed, would do more harm than good.

Other tools, pi² among them, have no such hooks. Nothing refuses an edit or asks about an issue left in progress, so take each step above yourself.
