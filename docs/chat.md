# Chat mode

Chat mode (#172) is a place beside the agent view to ask questions and talk things through, as in ChatGPT or Claude, with nothing to set up. This page is about how the engine does it (#283, `engine/src/chat.ts`) and how the app shows it ([In the app](#in-the-app), #284, `app/Sources/pi2/ChatMode.swift`); the page's Edit, Try Again and sources, pictures and code, the web switch, instructions and memory, and [Continue with an Agent](#continue-with-an-agent) are pieces of their own under #172.

## A chat

A chat is a conversation of pi²'s built-in chat assistant, not of one of the person's agents. Everything the engine does for conversations (storage, the transcript, titles, search, archive, export, backup, usage and the daily budget) does it for chats too; what is different is what a chat is offered and where it is listed.

- **Making one.** `conversation.create { chat: true, model? }` answers `{ id }`. Passing `agentId` with it is refused: a chat has no agent.
- **Its record.** The library event's row for it has `chat: true`, `agentId: null` and `pinned`, as every row now has (`false` for an agent's conversations). The rows of the Archive have `chat` and `pinned` too. Chat mode lists only rows with `chat: true`; the agent view's sidebar leaves them out.
- **The page.** The conversation's state has `chat: true` (false for any other conversation), so the page shows chat mode's own controls only then. `agent.agentId` and `agent.cwd` are null.
- **Pinning.** `conversation.pin { id, pinned }` sets or clears `pinned: true` on the record. Any top-level conversation can be pinned; a sub-chat cannot, on its own. A pinned conversation is never archived for going unused ([archive.md](archive.md#archiving-on-its-own)).
- **The rest** uses the requests conversations already have: `conversation.open`, `rename`, `archive`, `unarchive`, `delete`, `export`, `fork` (a fork of a chat is a chat), `submit`, `abort`, and `configure` for the model and thinking. `configure` refuses `cwd` and `access` for a chat.

## The assistant

The assistant is defined in the engine, not in the list of agents: it cannot be edited, deleted, duplicated, scheduled or handed work (`delegate` only names agents), and the `agents` event never lists it.

- **Its tools** are fixed: the entries of the [built-in tools](architecture.md#built-in-tools) whose keys `CHAT_TOOLS` names (`src/builtins.ts`): `web` (`web_search`, `web_fetch`) while the chat's [web switch](#the-web-switch) is on, `documents` (`write_document`), and `pictures` and `code` as soon as the list has them (#286); and while chat mode's memory is on, `remember`, `forget` and `agent_notes` ([Memory](#memory)), which a feature adds for chats with `chatToolNames`. Nothing else: no shell, no file tools, no computer use, no browser with sign-ins, no scheduling, no delegation, no `ask_user` or task list, no MCP servers. A tool's use shows in the transcript as in any conversation. A chat's tools are brought in line at its next message, as an agent's are, so turning the web off counts from there.
- **No approvals.** Nothing it is offered changes anything on the Mac, and its record's tool access is `none`, under which nothing waits for approval, so a chat never puts anything in the Inbox.
- **No folder.** A chat has none, and none can be chosen. Its documents go in a folder of its own in the data folder, `chats/<id>`, whatever path the model gives: `write_document` refuses one outside it. Its result's `details.path` is the document's full path, so the conversation can offer to open it. An archived chat keeps the folder; deleting the chat removes it, as it does a scratch folder. It is not in a backup, which copies the database and settings only.
- **What it is told.** The `chat` section of the system prompt, in chats only: that it is pi²'s chat assistant, that it has no folder and changes nothing on the Mac (and an agent can do that), and, with the tools it has, when to read the web (or, with the web off, that the person turned it off and the switch by the message field turns it on) and where its documents go. Like an agent, it is told in the `task_list` section to link a file it made for the person to look at, such as a document, which a click shows in Finder ([transcript.md](transcript.md#files-on-this-mac)); a chat has no folder, so its links are full paths. The chat instructions from Settings, when there are any, are the `chat_instructions` section, read at every request, so a change counts from each chat's next message. No agent is given them.
- **Memory** is below.
- **Attachments** work as for any conversation ([attachments.md](attachments.md)).

## The web switch

Each chat has a switch that turns the web off for it (#287). A new chat starts as chat mode's `web` setting says (on, unless Settings says otherwise), and from then on the switch is the chat's own: changing the setting changes no chat already made.

- **Turning it.** `conversation.configure { id, web: true|false }` on a chat; any other conversation refuses it, as its tools are chosen in its agent's settings. Off is kept on the chat's record as `web: false`; a fork of the chat keeps it, and its versions (Try Again, Edit) follow the chat's.
- **What the assistant sees.** It counts from the chat's next message, as any change to a conversation's tools does: an answer being written keeps the tools it started with. Then `web_search` and `web_fetch` go, with the `look_web` section, and the `chat` section says the web is off, so the assistant can say why it cannot look something up. Each is sent on its own, not the whole prompt again (`engine/test/sections.ts`), and comes back the same way when the web is turned on.
- **What the app sees.** The conversation's state has `web`: true or false for a chat, null for any other conversation.

## The model

Each chat has its own model and thinking level, chosen with `conversation.configure` as in the agent view, also in the middle of a chat. A new chat starts with the model chosen last in a chat (by `configure`, or passed to `conversation.create`), else chat mode's default model, else the agent view's: choosing a default model in Settings forgets the last one, so it counts from the next chat. The agent view keeps its own last model apart; choosing one in a chat does not change it.

## Settings

Chat mode's settings are under `chat` in the engine's `settings.json`, with these defaults:

| Setting | Default | What it is |
|---|---|---|
| `instructions` | `""` | What the person wants every chat to know; 20,000 characters at most. Sent to every chat as `chat_instructions` |
| `defaultModel` | `null` | The model a new chat starts with (`{ provider, modelId }`), or null for the one used last |
| `web` | `true` | Whether a new chat starts with its [web switch](#the-web-switch) on |
| `memory` | `true` | Whether chats remember lasting things across chats and read the agents' notes ([Memory](#memory)) |

`chat.set` changes any of them, each checked (an unknown model is refused), and answers with all four. The engine sends `{ event: "chat", instructions, defaultModel, web, memory }` when an app connects and after every change. The memory switch changes what every chat is offered, from its next message; the web setting changes only where a new chat's web switch starts.

## Memory

Chat mode remembers lasting things the person tells it, across chats, in notes of its own, and can read what the person's agents remember. It does not work the other way: an agent never sees chat mode's notes. [knowledge.md](knowledge.md#chat-modes-memory) has the whole of it; in short:

- **Its own notes** are one set for every chat, kept apart from every agent's: `remember` and `forget` in a chat change only them (ids `c1`, `c2`…), and the chat's `memory` section lists them.
- **The agents' notes** are not in a chat's prompt. The section has one line naming the agents that have memory on and a note, and the chat reads their notes with `agent_notes` when a question calls for it. It cannot change or remove them.
- **Off** (`chat.memory` false), a chat has none of the three tools and no `memory` section: nothing is remembered and nothing read. The notes are kept.

## Continue with an Agent

A chat that turns into real work can be handed to one of the person's agents (#289): `chat.continueWithAgent { id, agentId, cwd?, text? }` makes a new conversation of that agent, in `cwd` or else the agent's own folder, and answers with its `{ id }`. Its first message is the chat as it stands, with what the person typed in `text`, if anything. A chat still answering, with nothing in it yet, or deleted is refused, as are an unknown agent, a folder that is not there and a day over budget.

- **What the agent is given** (`src/handover.ts`). The version shown ([Try Again and Edit](#everywhere-else)), from its first message, written out as Markdown and attached to the message as a file, `Chat - <title>.md`: each of the person's messages, with what they attached named in place; each of the assistant's answers; and one line for each use of the assistant's own tools (a web search and its query, a page read and its address, a document written and where it is kept, a picture made, code run). The files the person attached come with the message as attachments of their own, as do the pictures (the person's and those the assistant made), up to the last ten; for an agent whose model cannot see pictures they are left out, and the message says so. A heading says that the chat's assistant had other tools than the agent, that what it did it did there, and that nothing in the chat is an approval. With nothing typed, it asks the agent to say what it understands and wait.
- **Why not a fork.** `conversation.fork` would start the agent's conversation with the chat's own history, its system messages among them: what the chat assistant is told, chat mode's instructions and, from #288, what chat mode remembers. Chat mode may read agents' memory, never the reverse. And the chat's answers would read as the agent's own, made with tools it may not have. So the agent gets only what the person saw, as context in a message.
- **Nothing of chat mode's memory.** The system prompt is never read, nor thinking, nor any tool's use but the five above: any other tool, a memory tool of #288 among them, is left out whole, with what it was given and what it said.
- **The agent's own rules.** The conversation is the agent's like any other: its access, approvals, Allow everything, tools, model and worktree (when its settings make one for each conversation) apply from the first message.
- **The chat stays as it was,** and each is linked to the other on its record: the agent's conversation has `continuedFrom` (the chat), the chat `continuedIn` (its conversations, oldest first), both in the library event's rows, a conversation deleted since left out. The new conversation is named after the chat.

## Everywhere else

- **Activity:** a chat that is answering has a row with `chat: true` and `agentId: null`, so it can be named as a chat. So do the conversations in the `recovery` event.
- **Search:** results have `chat`, so the app can say which is which.
- **Usage:** a chat's spend counts towards the day's total and the budget, as any conversation's. It is not counted as an agent's: the `usage` event has `chats: { cost, tokens }` beside `agents`, and its rows of conversations have `chat`.
- **Export:** a chat's Markdown names the assistant "Assistant"; its JSON has `chat: true` and `agent: null`.
- **Versions:** Try Again and Edit make versions of a chat, each a hidden conversation of its own that the chat stands for everywhere: requests on the chat act on the version shown, and Activity, the Inbox, usage, search, archiving and deleting count a version as the chat. Only chats have them. See [architecture.md](architecture.md#a-chats-versions).
- **Schedules, worktrees, command rules, reference files, variables:** these belong to agents, so a chat has none of them. A chat's memory is chat mode's own ([Memory](#memory)).

## In the app

- **The switch.** Agents and Chat, at the top of the sidebar, and in the View menu (⌘1 and ⌘2). The window opens on the agent view the first time, and afterwards on the side it was last on (`window.mode` in the app's preferences). Each side keeps what it showed while the other is on screen: the agent view's panes and selection are untouched in chat mode, and chat mode's chat is kept (`chat.selection`) while the agent view shows. Agents keep working meanwhile; in chat mode the Agents half of the switch counts what is waiting in the Inbox, or turns while an agent works, and in the agent view the Chat half turns while a chat answers. A chat chosen anywhere (the command palette, a fork, the Archive) opens in chat mode, and anything else chosen from the menu bar, the palette or the View menu opens in the agent view. The pane commands are off in chat mode, since panes are the agent view's.
- **The sidebar.** New Chat, a search, then the chats: Pinned first, then Today, Yesterday, Previous 7 Days and each month before, by when each was last used. The search keeps the chats whose title has what was typed, or whose messages do (the engine's `search`, after a pause in typing). A chat's context menu has Rename, Pin or Unpin, Archive and Delete. Archiving or deleting the chat on screen moves to the one below it, as in the agent view. The agent view's sidebar never lists chats (`EngineClient.rootConversations`).
- **A chat** is `ChatView`, the view an agent's conversation has, told it is a chat: the same conversation page, message field (attachments by drop, paste or the paper clip; Return sends, Shift-Return starts a new line) and Stop, in one column as wide as the page's text, with no agent to name and no steering, so a message written during an answer waits for it. The toolbar has the same model menu as an agent's conversation, with thinking effort where the model has it. By the paper clip is the chat's web switch, **Web**, lit while the assistant may read the web; turned off it reads **Web off**, and a line above the field says that the web is off for this chat and answers come from what the model already knows. An empty chat shows the message field in the middle, with a few ways to begin that fill it in. New Chat (⌘N in chat mode) shows the empty chat already waiting, if there is one, before making another, and chat mode with no chat on screen makes one.
- **The palette** finds chats and agents' conversations alike and marks chats as chats, and has New Chat and the switch, and Continue with an Agent… for the chat on screen.
- **Continue with an Agent…** is in the chat's toolbar, the chat's context menu in the sidebar, the Conversation menu and the palette, and is off while the chat is empty or answering. Its sheet (`ChatContinue.swift`) asks for the agent, the folder (the agent's own unless another is chosen) and, if the person wishes, what the agent should do now, and says what the agent may do and that nothing chat mode remembers goes with it. The new conversation opens in the agent view. Below each of the two, above the message field, a line links to the other: "Continued from the chat …" with Open Chat, or "Continued with Forge in …" with Open.
- **Settings › Chat** (`ChatSettings.swift`): the chat instructions, with Save; under New chats, the default model (or the model used last) and whether a new chat starts with the web on (`web`; each chat's own switch is by its message field); under Memory, the switch, chat mode's own notes, editable in place, deleted and added by hand as an agent's are in its settings, each saying whether a chat wrote it or the person did; and under Agents' notes, each agent with memory on and a note, its notes read-only (shown open, and can be folded away), with a lock and a footer saying they are changed in the agent's own settings and that no agent sees what chats remember. Every change but the instructions applies as it is made.
- **Archived chats** are listed under **Archived** at the foot of chat mode's sidebar, folded until it is opened (it stays open or folded, `chat.archivedOpen` in the app's preferences), most recently archived first; a search lists the archived chats that match as well, with the section open. Choosing one shows it in chat mode to read, with Restore in place of the message field, and its context menu has Open, Restore and Delete. The agent view's Archive lists them too, marked as chats (the chat mark in place of an agent's avatar, and "Chat" where an agent's name would be), so typing "chat" in its filter keeps only them; Open there shows the chat in chat mode. Restoring from either puts the chat back in chat mode's list.
