
# Allow everything

Every agent asks before it does something that matters, as its settings say: a command or a change to a file under **Ask first**, a click in an app with **Ask before each action**, a button on a web page, a worktree for a sub-chat, a schedule it wants to set. Computer use keeps to the apps you list, and can only look at browsers.

**Allow everything** is a switch, per agent and off unless you turn it on, that lifts all of that for one agent. It is for when you have set up its surroundings so that nothing it could reach is something you cannot afford to lose: a spare Mac, a virtual machine, a throwaway account, a folder you have backed up. It is the same idea as Claude Code's "dangerously skip permissions".

The code is the `Inbox` in `engine/src/state.ts`, which every approval goes through, and `agents.allowEverything` in `engine/src/main.ts`.

## Turning it on

Open the agent's settings and, under **Allow everything** (just below **Tools**), switch it on. pi² asks you to confirm, and says what it means. It is kept as soon as you confirm, without Save. Switching it off asks nothing.

## What it does

With it on, the agent:

- **is asked about nothing.** Commands, writing and changing files, documents, tools of MCP servers that change things, every computer use action, clicking, typing and uploading in pi²'s browser, a worktree for a sub-chat it hands work to, and a schedule it sets for itself all go ahead without an approval. No rule and no "always" is kept for them, so switching it off again leaves nothing behind.
- **may use any app** with computer use, not only the ones listed in its settings, as long as computer use is on for it. With no app listed, it still gets computer use.
- **may control browsers** through computer use: Safari, Chrome and the others, with every account you are signed in to there. Without the switch they can only be looked at.
- **covers scheduled runs**, which happen with nobody watching, and every conversation of the agent, including sub-chats another agent hands it.

A command that reaches its time limit is moved to the background rather than stopped, as it would be with Full access ([architecture.md](architecture.md#how-long-a-command-may-run)).

## What it does not lift

- **Questions.** When the agent asks you something with `ask_user`, it still waits for your answer.
- **Its tool access.** The switch lifts approvals, not the access level: an agent set to **Read files** still has no shell, and one with tools off still cannot change files. Choose **Ask first** or **Full access** for it to run commands.
- **pi² itself.** No agent can work pi², where it could approve its own requests, and copies of pi² can only be looked at, apart from the throwaway test copies an agent may be allowed under **Computer use** ([computer-use.md](computer-use.md)), which the switch does not change.
- **Terminals, script editors and password managers**, which computer use can never be given: typing in a terminal would get round the agent's tool access, and a password manager holds every secret.
- **System Settings**, which computer use can still only look at, since it changes the Mac's security. **Password fields**, in apps and in the browser, are never typed into, and the Apple menu is off limits. What macOS itself refuses, such as an app without the Accessibility permission, stays refused.
- **The browser's own limits**: only http and https, nothing on your Mac or your network, no downloads, uploads only of files it was given ([browser.md](browser.md#what-it-will-not-do)).
- **The daily budget and the turn limit.** A used-up budget still refuses new work, and a run still stops at the agent's turn limit.
- **Command rules** only ever allow; there is no rule that refuses, so there is nothing for the switch to override there.

## Sub-chats, copies and schedules

- **A sub-chat follows its own agent's switch, never its parent's.** An agent with the switch on that hands work to one without it does not pass it on: that sub-chat asks as its own agent's settings say. The other way round, a sub-chat of an agent with the switch on asks about nothing, whoever handed it the work.
- **Duplicating an agent does not copy the switch.** The copy starts with it off.
- **Saving an agent never changes it.** Only the switch itself, after its confirmation, turns it on.
- **Scheduled runs are covered**: a schedule of the agent, yours or one it set, starts a conversation that asks about nothing.

## When a change counts

Turning it on or off applies from each conversation's next message, both ways, never in the middle of a run: a run that started with it off still asks until it ends, and one that started with it on goes on without asking. To stop a run at once, press Stop (or Esc twice).

## Seeing it

It is shown in red, as pi² marks anything risky:

- the agent's row in the sidebar has the tag **allows everything**;
- every conversation of the agent has a red bar across its top, which says when the switch has changed and the conversation takes the change at its next message;
- the agent's settings say so at the top, and under **Allow everything**; with computer use on, its section says that any app may be used.

## What macOS needs

For computer use in any app, pi² needs Accessibility, and Screen Recording if the agent should get pictures. They are granted to pi² in System Settings › Privacy & Security; the **Grant…** buttons under **Computer use** in the agent's settings open the right place ([computer-use.md](computer-use.md#turning-it-on)).

## For developers

- The agent has `allowEverything: true` when it is on, set only by `agents.allowEverything { id, on }`. `agents.save` keeps what is stored and ignores what it is sent, and a new agent, a duplicate among them, never has it.
- A conversation takes it from its own agent as each message is sent (`takeSwitch` in `main.ts`, `takeAgentSwitch` in `state.ts`): `submit`, `continue`, a schedule's `deliver`, and an agent continuing a sub-chat (`continueChat`); `delegate` sets a new sub-chat's from its own agent as it makes it. It is kept on the conversation's entry in the library (`Meta.allowEverything`), and the `library` event carries it for the app's warning.
- `Inbox.ask` answers an approval `once` without showing it when the conversation has it, reading the stored library. Every approval goes through `Inbox.ask`, so a new kind of approval is covered with nothing more to do. `commandAsks` in `extensions.ts` follows the same flag.
- Computer use reads the conversation's flag too: `refusal` lets any app through but those `isNever` refuses, and `isViewOnlyFor(app, true)` keeps only System Settings and copies of pi² look-only. Requests to the app carry `anyApp: true`, and `ComputerPolicy` in ComputerKit lifts the browsers' look-only only then.
- `engine/test/everything.ts` checks every kind of approval with the switch off (each asked, once, as before) and on (none asked, each done), and the limits above.
