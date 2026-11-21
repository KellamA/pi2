# Working on pi²

These are the project's instructions for any agent working in this repository, whatever tool it runs in: Claude Code, pi² itself, or another. Read [CONTRIBUTING.md](CONTRIBUTING.md) in full, and read the worker's brief in full if you were given one. Read the lists at the top of [docs/development.md](docs/development.md#what-to-read-for-what) and [docs/architecture.md](docs/architecture.md#what-to-read-for-what), then read only the sections that apply to your issue. The agent that hands out the work will usually name those sections. Before you build, run or test anything, read all of [Testing safely](CONTRIBUTING.md#testing-safely): the Mac you are working on may be running pi² for real work.

If you were handed issues to finish on your own, in a worktree of your own (as a worker of an orchestrating agent), also read [docs/agents.md](docs/agents.md) and follow it: where you are, what is not yours to touch, when to stop and what to report.

## Issues: one for every piece of work

Every task an agent does in this repository gets a GitHub issue, so there is a record of what was done and a backlog to choose from. This is the rule whichever tool you run in; how it is kept depends on where:

- **In a pi² project**, which offers you a tool named `work` whose work list is this repository's issues: with that tool. Keep an issue with it from start to end, since it knows who holds an issue only from its own comments.
- **Anywhere else** (Claude Code, or pi² with the projects preview off): with `scripts/issue`, which uses `gh`. A long text goes in a file, given with `--body-file FILE` in place of `-b` or of the text.

| When | In a pi² project: `work` with | Anywhere else: `scripts/issue` |
|---|---|---|
| Before changing any file | `take`, unless your task begins "Work #N:" (assigned to you already); new work: `file`, then `take` | `take N`; new work: `start "Title" -b "What and why"` |
| A decision or dead end worth keeping | `note` | `note N "…"` |
| Ending a turn unfinished | `wait` (on the person) or `block`, saying why; `resume` to go on | `wait N "…"` or `block N "…"`; `take N` to go on |
| A decision that is the person's | `needs_you` `ask`, and carry on; a sub-chat has none: `wait` | `wait N "…"` |
| A pull request | `pull_request` with `id`, which adds `Fixes #N` | `gh pr create --body-file FILE` |
| Finished: what changed, what was and was not verified | `finish`; once a merge has closed the issue (`finish` then refuses), a `note` beginning `**Done.**` | `done N "…"`, even once a merge has closed it |
| Abandoned | `release`, saying why in a `note` | `drop N "why"` |
| An idea outside the task: file it, do not do it | `file`, with no `class` | `idea "Title" -b "…"` |
| What is open | `list`, `show` | `list` |

- If `work` refuses to `take` an issue already in progress, waiting or blocked with no holder, it was kept with `scripts/issue` so far: keep it with the script, and say so in your report.
- **Classifying:** every open issue has a class, `local model` or `cloud model`, saying which kind of model it needs ([docs/issue-classes.md](docs/issue-classes.md)). Only the agent that hands out the work sets it: `work` `classify`, or `scripts/issue classify N local` or `cloud` (`--model` when it files). A worker never does, and never gives `file` a `class`, though the tool would take one.
- **Not tracking:** only if GitHub cannot be reached, or the person said not to track something: `scripts/issue skip "why"`, or in a project say so in your report.
- Mention the issue in commit messages and pull requests (`Fixes #N` closes it on merge; for a part, `Part of #N`, and `pull_request` without `id`).
- A question that changes no files needs no issue.
- **Checking the board:** `scripts/issue audit` lists what is wrong (a closed issue with a status label, an open one with none or more than one, one in progress with no activity for a day, an agent's issue closed as completed with no `**Done.**` summary, the script's or the tool's) and exits non-zero if anything is. It changes nothing. A workflow, `.github/workflows/issue-labels.yml`, takes the status labels off any closed issue and puts `backlog` on one reopened with none.

The repository is public, and so are its issues. Write them for any reader: no personal details, keys, or paths from this Mac (the script turns the home folder into `~`; the tool posts what it is given).

### The backstop under Claude Code

Under Claude Code only, two hooks in `.claude/settings.json` catch a step that was missed: an edit to a file in any checkout of the repository, the main one or a worktree, whatever the session's own folder, is refused until the session has an issue in progress (a checkout's `.git/` and `.claude/` excepted), and the end of a turn with an issue still marked in progress asks for its status first, unless GitHub says it is closed or paused, or gives no answer within ten seconds. They know the session's issues only from the `[pi2-issue]` lines `scripts/issue` printed in the output of the session's own commands, the agent's or the person's (`!`): the same line quoted anywhere else does not count. `PI2_ISSUES=off` turns them off; the header of `scripts/issue-hook` has the details.

Other tools, pi² among them, have no such hooks. Nothing refuses an edit or asks about an issue left in progress, so take each step above yourself.
