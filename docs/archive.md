# Archive

Archiving puts a conversation away without losing it. It leaves the sidebar, and is kept in the Archive.

## What archiving does

- The conversation and the sub-chats its agents opened leave the sidebar. You archive a sub-chat together with the conversation it belongs to; its conversation's agent can archive one on its own (below).
- Any work it is doing is stopped, and anything it was waiting on you for is withdrawn.
- Commands its agents left running in the background are stopped, its sub-chats' too ([background.md](background.md)). Restoring it does not start them again.
- It can still be read. Open it from the Archive, or find it with search (⌘K), where it is marked as archived.
- It takes no new messages. In place of the message field there is a Restore button.

Archive a conversation from its menu in the sidebar, from Conversation › Archive Conversation (⌃⌘A), or leave it to pi² (below).

Chats are archived the same way. The Archive marks them as chats, with the chat mark where an agent's avatar would be, and chat mode lists its own archived chats at the foot of its sidebar, under Archived ([chat.md](chat.md#in-the-app)). A chat restored from either goes back to chat mode's list.

## Restoring

Restore puts the conversation and its sub-chats back in the sidebar as they were. It can then be continued from where it stopped. Work that was stopped when it was archived is not restarted on its own; send a message or choose Continue.

## Sub-chats an agent puts away

An agent that hands work to other agents leaves a sub-chat behind for each task. It can tidy them up itself with its `sub_chats` tool, which it has whenever it can hand work on:

- **list** gives each of its conversation's sub-chats that is not archived, with its number, agent and title; whether it is working, waiting for you, or idle; the folder and branch it works in, and for a [worktree of its own](worktrees.md#sub-chats) whether anything is uncommitted and whether its branch is merged; the commands it left running in the background; and what it used. The archived ones are only counted, in one line ("191 archived; `archived: true` lists them, …"), since a conversation that hands out work for months would otherwise be told every one of them at each list (#636). With `archived: true` it lists those instead, a line each (number, agent, title, when it was archived and last used), newest archived first, 40 at a time: the answer ends with the `cursor` to pass back for the next page. `usage: true` adds what each used; `chats` looks up the sub-chats numbered, archived or not.
- **archive** puts away the sub-chats it names. Only sub-chats of its own conversation (and theirs), never one that is working or waiting for you.

An archived sub-chat leaves the sidebar and is listed in the Archive as a sub-chat of its conversation, which stays where it is. It can be read, found by search, restored or deleted there like any archived conversation. Commands it left running in the background are stopped, and the agent is told which. A worktree of its own is left as it is (see [Worktrees left behind](worktrees.md#worktrees-left-behind)), unless the agent asks for it to go (`remove_worktree`) and nothing would be lost: nothing uncommitted and no commits that are not on the branch it was made from. Then it is removed as **Remove Worktree, Keep Branch** removes one, and the branch stays. The conversation that archived it gets a line saying which sub-chats were put away, how many background commands were stopped, and which worktrees were removed.

A sub-chat working on a task handed to it without waiting (`delegate` with `wait: false`) is not archived; `sub_chats` with `wait` waits for the next of those to answer ([wakes.md](wakes.md)). Archiving or deleting the conversation stops them, and the agent is not woken for them.

If the agent carries on an archived sub-chat (`delegate` with its number), the sub-chat is restored first, and the conversation gets a line saying so. Archiving the whole conversation archives its sub-chats with it as before; one the agent archived on its own stays archived when the conversation is restored.

## Archiving on its own

At the bottom of the Archive you can have pi² archive conversations nothing has happened in for a week, a month, three months or a year. A sub-chat used more recently than its conversation counts. A conversation that is working, waiting for you, or has a command running in the background, is left where it is, and so is one you pinned (`conversation.pin`; chat mode's sidebar pins chats, [chat.md](chat.md)). The check runs shortly after pi² starts, a few times a day, and at once when you change the setting.

This is off until you choose a length of time.

## Deleting is different

Delete removes a conversation from pi² for good: it is not in the sidebar, the Archive or search, and it cannot be restored. Commands its agents left running in the background are stopped, and the documents a chat wrote are removed with it. A conversation can be deleted from the sidebar or from the Archive.

Deleting does not erase the conversation's text from pi²'s data file. pi durable, the library that stores conversations, has no way to remove one, so pi² marks it as deleted and stops showing it. A backup made before the deletion still contains it as it was.

Conversations deleted in versions before the Archive existed stay deleted: they do not turn up in the Archive.
