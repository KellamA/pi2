# pi² as a co-author of agents' commits

A switch in **Settings › Tools › Agents' commits**, off by default: **Add pi² as a co-author to agents' commits**. When it is on, agents are asked to end the message of every git commit they make with a `Co-authored-by` trailer, which git hosts such as GitHub read as a co-author of the commit. The engine side is `engine/src/coauthor.ts`; the app side is `app/Sources/pi2/CoauthorSettings.swift`.

## The line

The trailer is shown under the switch and can be edited. It starts as:

```
Co-authored-by: pi² <noreply@pi2.invalid>
```

The project has no address of its own, and `.invalid` is a top-level name reserved so that it can never be registered (RFC 2606). So the default line cannot credit a commit to anyone's account: a host shows the name, linked to no one. To link the commits to an account of your own, put its address in the line instead, such as a GitHub no-reply address.

A line is refused, with the reason, unless it is a well-formed trailer: a single line, starting with `Co-authored-by:`, then a name, then an address in angle brackets of the form `name@domain`, 200 characters at most. Spaces are tidied (`co-authored-by:   pi²   <noreply@pi2.invalid>` is kept as `Co-authored-by: pi² <noreply@pi2.invalid>`). The line is kept while the switch is off. **Use Default** puts the default back.

## What it does, and what it does not

- **It is an instruction, not something pi² enforces.** With the switch on, every conversation that can run commands, sub-chats and conversations in worktrees included, gets a section of its system prompt, `commit_coauthor`. It gives the line and asks the agent to end the message of every commit it makes with it, once, on a line of its own in the last paragraph after a blank line, with any other trailers. It also tells the agent not to add it to commits it did not make, not to amend or rewrite earlier commits to add it, and to leave the commit's author, its committer and git's configuration as they are. A model may still leave the line out or get it wrong, and a commit made by other means (a script the agent runs, a tool of an MCP server, the person) does not get it.
- **With the switch off there is no such section.** A conversation that cannot run commands (no tool access, or read only) never gets it, since it cannot commit.
- **Turning it on or off, or changing the line, counts from each conversation's next message.** Commits already made keep whatever they have; nothing is removed from or added to them.
- **pi² itself never changes git's configuration, never rewrites history, and never touches the author or committer of a commit.**

Having the engine add the trailer itself was considered and left aside: the way to do it for every command an agent runs is a `prepare-commit-msg` hook given to git through the environment (`core.hooksPath`), and that would set aside the repository's own hooks.

## Where it is kept

One session document, `pi2.coauthor`: `{ enabled, line }`. It is in backups with the rest of the database.

## Requests and events

| Request | What it does |
|---|---|
| `coauthor.set { enabled?, line? }` | turns the switch on or off, changes the line, or both; a malformed line is refused and nothing changes. Answers `{ line }`, the line as kept |

After every change the engine broadcasts `{ event: "coauthor", enabled, line, defaultLine }`, and sends the same event to an app when it connects.

## The prompt section

`commit_coauthor` is declared after the sections that stay the same through a conversation and before `background_commands`, which comes and goes far more often. A section whose arrival puts it before one already shown makes pi durable send every section again (#186), so it is placed where it is in the way of as few others as possible.
