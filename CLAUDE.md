# Working on pi²

These are the project's instructions for any agent working in this repository, whatever tool it runs in: Claude Code, pi² itself, or another.

Start with [CONTRIBUTING.md](CONTRIBUTING.md), [docs/development.md](docs/development.md) and [docs/architecture.md](docs/architecture.md). Before you build, run or test anything, read [Testing safely](CONTRIBUTING.md#testing-safely) in CONTRIBUTING.md: the Mac you are working on may be running pi² for real work.

## Issues: one for every piece of work

Every task an agent does in this repository gets a GitHub issue, so there is a record of what was done and a backlog to choose from. This is the rule whichever tool you run in. `scripts/issue` does the bookkeeping with `gh`.

- **Starting work:** before changing any file, run `scripts/issue start "Short title" -b "What and why, in a few lines"`. If the work is an existing issue, run `scripts/issue take N` instead. Run `scripts/issue list` to see what is open.
- **While working:** `scripts/issue note N "..."` for anything worth remembering (a decision, a dead end).
- **Ending a turn before the work is finished:** `scripts/issue wait N "what you need from the person"`, or `scripts/issue block N "why"`. Run `scripts/issue take N` when you pick it up again.
- **Finished:** `scripts/issue done N "what changed, and what was and was not verified"`. If it is abandoned: `scripts/issue drop N "why"`.
- **Ideas for later:** when you notice something worth doing that is outside the task, file it with `scripts/issue idea "Title" -b "..."` rather than doing it.
- **Not tracking:** only if GitHub cannot be reached, or the person said not to track something, run `scripts/issue skip "why"`.
- Mention the issue in commit messages and pull requests (`Fixes #N` in a pull request closes it on merge).
- A question that changes no files needs no issue.

The repository is public, and so are its issues. Write them for any reader: no personal details, keys, or paths from this Mac (the script turns the home folder into `~`).

### The backstop under Claude Code

Under Claude Code only, two hooks in `.claude/settings.json` (both run `scripts/issue-hook`) catch a step that was missed: an edit to a file in the repository is refused until the session has an issue in progress, and the end of a turn with an issue still marked in progress asks for its status first. Setting `PI2_ISSUES=off` turns the hooks off.

Other tools, pi² among them, have no such hooks. Nothing refuses an edit or asks about an issue left in progress, so take each step above yourself.
