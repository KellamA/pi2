# Worktrees and branches

Several agents can work on one git repository at once when each has a worktree of its own: a second checkout of the same repository, on its own branch, in its own folder. Their changes stay apart until you merge them.

pi² also keeps track of which branch every conversation's folder is on, and shows it next to the conversation.

## Giving a conversation a worktree

A conversation whose folder is in a git repository can move into a worktree:

- from the branch icon next to it in the sidebar, choose **New Worktree…**;
- or from the toolbar's branch menu or tools menu.

pi² suggests a branch name from the conversation's title (`pi2/fix-the-login-page`); change it if you like. A new branch starts from the commit the folder is on. A name that is already a branch, and is not checked out anywhere else, is checked out as it is, which is how to pick up a branch a removed worktree left behind.

The worktree is made in pi²'s data folder (`worktrees/<repository>-<id>/<branch>`), and the conversation's folder moves into it. If the conversation worked in a subfolder of the repository, it keeps working in the same subfolder of the worktree.

The agent is told it is in a worktree of its own, on which branch, and to commit there and leave other branches and the main checkout alone.

Files git ignores (installed packages, build output, `.env` files) are not in a new worktree. An agent that needs them has to set them up there, unless its agent has a set-up command.

## A set-up command

In an agent's settings, under **Give each conversation its own worktree**, **Set-up command** is a shell command that puts back what a new worktree lacks, such as `npm ci` or `npm --prefix engine ci && cp ../shared.env .env`. pi² runs it once in each new worktree of that agent's conversations, right after making it: the ones made for new conversations, and ones made from the branch menu for a conversation of that agent. It does not run for a worktree of another repository than the agent's folder, since the command was written for that one.

- It runs in the worktree's top folder through `/bin/bash -c`, with the same environment as the agent's own commands (including the `PATH` from your login shell) and one variable more, `PI2_RUN`, which pi² uses to know the command's processes again (see the last point). It runs without asking: you typed it, and an agent cannot change it.
- The conversation shows it running, with what it prints as it arrives, as for a command an agent runs; then what it printed (the last 32 KB) and whether it finished or failed. A failed set-up leads with what happened ("Set-up command failed: exited with code 3"), then the command, which is the part shortened when the row is narrow. It is opened so you see why: the reason again on a line of its own, then the output in the ordinary colour, so the line that failed is easy to find.
- A message sent while it runs waits for it, so the agent starts in a worktree that is ready. The agent is told the command ran and how it ended, with the end of its output if it failed. A failed set-up does not stop the conversation: the agent carries on, and can finish the job itself.
- It is stopped, together with anything it started, after 15 minutes, when the worktree is removed, or when pi²'s engine stops. Stopping the agent's answer does not stop the set-up. A set-up cut off by the engine stopping is shown as cut off when the engine starts again, and is not run again.
- If the engine crashes or is killed outright, the command is left running for the moment. The next engine stops it, with anything it started, and says so in the conversation. It stops only what it can tell is the same, because a process number is used again by other programs once it is free.
  - pi² notes the command's process group and when its first process started. While that first process is still there, and started when noted, the whole group is the command's, and is stopped.
  - Once the first process has ended, what it started in the background is known one process at a time. pi² gives each run a random value in the environment variable `PI2_RUN`, which everything the command starts inherits, and notes it too. A process in the noted group whose environment holds that value is stopped.
  - Anything else is left alone, and the conversation says so with the process group's number. That covers a process started with the variable taken out of its environment, and the programs that come with macOS (`/bin/sh`, `sleep`, `tail`, `/usr/bin/perl`), whose environment macOS does not let another process read. Other programs, such as `node` or one you compiled yourself, can be read. When some of the group carried the value and were stopped while others were left, the line says both: what pi² could tell the command had started was stopped, and something else in its process group may still be running.
  - Activity's notice that the engine stopped unexpectedly lists each set-up that was running, with its conversation and what became of it: stopped, stopped in part, left alone, or cut off. The `recovery` event carries them as `setups`: one `{ conversationId, rootConversationId, title, command, outcome, group }` each, with `outcome` as for background commands ([background.md](background.md#for-developers)), except that a set-up whose process was not yet noted counts as `gone`.

## Every conversation in its own worktree

In an agent's settings, under Tools, **Give each conversation its own worktree** makes every conversation you start with that agent begin in a new worktree, made from the agent's folder, on a branch named after the agent and the conversation (`pi2/forge-12`). The agent's folder has to be in a git repository.

Conversations started by a schedule, sub-chats, and forks are not given one: a fork works in the same folder as the conversation it came from, and a sub-chat usually works in its parent's, unless the agent handing it work asks for a worktree (see below).

The agent's command rules for the repository hold in these worktrees too, and a rule made in one is kept for the main checkout, so the next conversation does not ask again. See [rules.md](rules.md).

If the worktree cannot be made, the conversation starts in the agent's folder as usual, and its branch icon shows that.

## Sub-chats

When a conversation hands work to another agent, the sub-chat starts in the folder the conversation is working in at that moment. So a helper called from a worktree works in that worktree, on its branch, and is told so the same way. This holds when the other agent has no folder of its own, or when its folder is in the same git repository. An agent whose folder is in another repository, or in none, works in its own folder as usual.

Continuing an earlier sub-chat keeps the folder it has. Removing a worktree moves the sub-chats working in it back with their conversation.

An agent can see where each of its sub-chats works, on which branch and how that branch stands, and archive the finished ones with its `sub_chats` tool ([archive.md](archive.md#sub-chats-an-agent-puts-away)). A sub-chat's worktree of its own is left where it is when the sub-chat is archived, as for any archived conversation (below), unless the agent asks for it to be removed and nothing would be lost: nothing uncommitted, nothing half done, and no commits that are not on what it started from. The removal is the same as **Remove Worktree, Keep Branch**: the branch stays.

Every sub-chat whose folder is in a git repository shows its branch icon on its own row in the sidebar, so each one's branch and how it stands can be followed without opening Branches. One working in its parent's checkout, whether that is a worktree or the main checkout, has the icon faded and drawn lighter, still in the colour of how the branch stands; one with a worktree of its own, or working in another repository, has it at full strength like any conversation. So among a conversation's sub-chats, the ones on a branch of their own stand out, and a faded icon says "the same branch as the conversation above".

The app shows a sub-chat in its parent's worktree as working there: **Branches** lists it under the conversation whose worktree it is, marked "parent's worktree", and its tooltip and branch menu name that conversation. One sharing its parent's main checkout is listed under its parent in the same way, marked "parent's checkout", and its tooltip and branch menu name the parent too. Under a conversation, its sub-chats come oldest first, as in the sidebar; a sub-chat with a worktree of its own has a branch of its own, and is listed on its own among the repository's rows, by how its branch stands. A sub-chat can still be given a worktree of its own with **New Worktree…**: it starts from the parent's branch, and the sub-chat stops working in its parent's checkout.

The tracker looks at a sub-chat in its parent's worktree as that worktree, so it shows the same state as the parent, merged included, and however many sub-chats work in one folder, the folder is looked at once.

### A worktree of its own, from the agent

An agent handing work on can ask for the new sub-chat to get a worktree of its own: `delegate` with `worktree`, a branch name. This is for several sub-chats changing one repository at once, so each has its own branch and checkout and none disturbs the others or its parent's folder.

- pi² makes it exactly as **New Worktree…** does, in the repository the sub-chat would otherwise have worked in: the same place in the data folder, the sub-chat's folder moves into it, it is told it works there, the set-up command of the agent it hands to runs, command rules hold there, and the sidebar and **Branches** show it as the sub-chat's own worktree.
- The new branch starts from the commit the parent's folder is on, or from `from`: a branch, tag or commit as the repository has it now, such as `origin/main`. pi² does not fetch first. "Merged" is measured against what it started from. A branch that already exists is checked out as it is, unless `from` is given, which is then refused.
- If the worktree cannot be made (not a git repository, a ref that does not exist, a branch that cannot be used), the call fails with the reason, and no sub-chat is left behind.
- It is made without asking when the conversation handing the work on has full access, since its agent could make one with git itself, or when the agent it hands to has **Give each conversation its own worktree** on. Otherwise you are asked first, with what it would make and the task; **Always Allow Here** stops the questions for the rest of that conversation.
- Continuing the sub-chat keeps it in its worktree. Removing it works as for any other: the sub-chat goes back to its parent's folder.

## Removing a worktree

Choose **Remove Worktree…** from the same places. The conversation goes back to the folder it worked in before.

- **Remove Worktree, Keep Branch** removes the checkout. The branch and its commits stay in the repository.
- **Remove Worktree and Branch** deletes the branch too, but only if everything on it is merged. A branch with unmerged commits is kept, and pi² says so.
- A worktree with uncommitted changes can only be removed by discarding them (**Remove and Discard Changes**). Commit them first to keep them.

A worktree cannot be removed while its agent is working. A command the agent left running in the background in the worktree ([background.md](background.md)) does not prevent it: the command is stopped first, and the conversation says so.

## Worktrees left behind

Archiving or deleting a conversation leaves its worktree where it is, with any work in it: an archived conversation can be restored and carry on there. Commands its agent left running in the background are stopped. The same holds for a sub-chat an agent archived with `sub_chats`.

- When you delete a conversation whose worktree has nothing uncommitted, pi² offers **Delete and Remove Worktree**. The branch is kept. A worktree with uncommitted changes is always kept.
- **Branches** lists every worktree whose conversation was archived or deleted under **Left Behind**, with how its branch stands. **Remove…** asks the same questions as removing any other worktree: keep the branch or delete it too (only if merged), or discard uncommitted changes.

Removing the worktree of an archived conversation moves it back to the folder it worked in before, so if you restore it, it carries on there.

If a worktree's folder is deleted by hand, its icon turns grey and says it is missing. Removing it then lets git forget it.

## The branch tracker

Every few seconds while the app is open, pi² looks at the folder of each conversation in the sidebar. For one in a git repository it shows a branch icon on the conversation's row: a plain branch for the repository's main checkout, a branch in a box for a worktree, faded for a sub-chat working in its parent's checkout (see [Sub-chats](#sub-chats)). Click it for the details; the conversation's toolbar shows the branch name too, and **Branches** in the sidebar lists every conversation by repository.

The icon's colour says how the branch stands, the most pressing first:

| Colour | Meaning |
|---|---|
| Red | Files with conflicts, or a merge, rebase, cherry-pick or revert stopped half way |
| Amber | Uncommitted changes, including new files |
| Grey | HEAD is detached, or the worktree's folder is gone |
| Purple | Merged: everything on a worktree's branch is on the branch it was made from, and it has moved on since it was made |
| Blue | Commits not pushed to its upstream; with no upstream, commits not yet on the branch it was made from (or the default branch). Also used when it is behind its upstream |
| Green | Clean, and nothing to push or merge |

"Merged" is only said of worktrees pi² made, because only for those does it know where the branch started; any other branch with nothing of its own may simply be new.

Conversations working in the same folder share one look at it each time, and so do all that work in one worktree pi² made, sub-chats included.

Looking never changes the repository: git is run without taking its index lock, so it cannot get in the way of an agent's own git commands, and nothing is fetched, so "behind" is as of the last fetch.
