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

Files git ignores (installed packages, build output, `.env` files) are not in a new worktree. An agent that needs them has to set them up there.

## Every conversation in its own worktree

In an agent's settings, under Tools, **Give each conversation its own worktree** makes every conversation you start with that agent begin in a new worktree, made from the agent's folder, on a branch named after the agent and the conversation (`pi2/forge-12`). The agent's folder has to be in a git repository.

Conversations started by a schedule, sub-chats, and forks are not given one: a fork works in the same folder as the conversation it came from, and a sub-chat usually works in its parent's (see below).

If the worktree cannot be made, the conversation starts in the agent's folder as usual, and its branch icon shows that.

## Sub-chats

When a conversation hands work to another agent, the sub-chat starts in the folder the conversation is working in at that moment. So a helper called from a worktree works in that worktree, on its branch, and is told so the same way. This holds when the other agent has no folder of its own, or when its folder is in the same git repository. An agent whose folder is in another repository, or in none, works in its own folder as usual.

Continuing an earlier sub-chat keeps the folder it has. Removing a worktree moves the sub-chats working in it back with their conversation.

## Removing a worktree

Choose **Remove Worktree…** from the same places. The conversation goes back to the folder it worked in before.

- **Remove Worktree, Keep Branch** removes the checkout. The branch and its commits stay in the repository.
- **Remove Worktree and Branch** deletes the branch too, but only if everything on it is merged. A branch with unmerged commits is kept, and pi² says so.
- A worktree with uncommitted changes can only be removed by discarding them (**Remove and Discard Changes**). Commit them first to keep them.

A worktree cannot be removed while its agent is working.

## Worktrees left behind

Archiving or deleting a conversation leaves its worktree where it is, with any work in it: an archived conversation can be restored and carry on there.

- When you delete a conversation whose worktree has nothing uncommitted, pi² offers **Delete and Remove Worktree**. The branch is kept. A worktree with uncommitted changes is always kept.
- **Branches** lists every worktree whose conversation was archived or deleted under **Left Behind**, with how its branch stands. **Remove…** asks the same questions as removing any other worktree: keep the branch or delete it too (only if merged), or discard uncommitted changes.

Removing the worktree of an archived conversation moves it back to the folder it worked in before, so if you restore it, it carries on there.

If a worktree's folder is deleted by hand, its icon turns grey and says it is missing. Removing it then lets git forget it.

## The branch tracker

Every few seconds while the app is open, pi² looks at the folder of each conversation in the sidebar. For one in a git repository it shows a branch icon on the conversation's row: a plain branch for the repository's main checkout, a branch in a box for a worktree. Click it for the details; the conversation's toolbar shows the branch name too, and **Branches** in the sidebar lists every conversation by repository.

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

Looking never changes the repository: git is run without taking its index lock, so it cannot get in the way of an agent's own git commands, and nothing is fetched, so "behind" is as of the last fetch.
