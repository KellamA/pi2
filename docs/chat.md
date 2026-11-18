# Chat mode

Chat mode (#172) is a place beside the agent view to ask questions and talk things through, as in ChatGPT or Claude, with nothing to set up. This page is about how the engine does it (#283, `engine/src/chat.ts`); the app's switch, sidebar and chat view, the page's Edit, Try Again and sources, pictures and code, the web switch, instructions and memory, and Continue with an Agent are pieces of their own under #172.

## A chat

A chat is a conversation of pi²'s built-in chat assistant, not of one of the person's agents. Everything the engine does for conversations (storage, the transcript, titles, search, archive, export, backup, usage and the daily budget) does it for chats too; what is different is what a chat is offered and where it is listed.

- **Making one.** `conversation.create { chat: true, model? }` answers `{ id }`. Passing `agentId` with it is refused: a chat has no agent.
- **Its record.** The library event's row for it has `chat: true`, `agentId: null` and `pinned`, as every row now has (`false` for an agent's conversations). The rows of the Archive have `chat` and `pinned` too. Chat mode lists only rows with `chat: true`; the agent view's sidebar leaves them out.
- **The page.** The conversation's state has `chat: true` (false for any other conversation), so the page shows chat mode's own controls only then. `agent.agentId` and `agent.cwd` are null.
- **Pinning.** `conversation.pin { id, pinned }` sets or clears `pinned: true` on the record. Any top-level conversation can be pinned; a sub-chat cannot, on its own. A pinned conversation is never archived for going unused ([archive.md](archive.md#archiving-on-its-own)).
- **The rest** uses the requests conversations already have: `conversation.open`, `rename`, `archive`, `unarchive`, `delete`, `export`, `fork` (a fork of a chat is a chat), `submit`, `abort`, and `configure` for the model and thinking. `configure` refuses `cwd` and `access` for a chat.

## The assistant

The assistant is defined in the engine, not in the list of agents: it cannot be edited, deleted, duplicated, scheduled or handed work (`delegate` only names agents), and the `agents` event never lists it.

- **Its tools** are fixed: the entries of the [built-in tools](architecture.md#built-in-tools) whose keys `CHAT_TOOLS` names (`src/builtins.ts`): `web` (`web_search`, `web_fetch`) while chat mode's web setting is on, `documents` (`write_document`), and `pictures` and `code` as soon as the list has them (#286). Nothing else: no shell, no file tools, no computer use, no browser with sign-ins, no scheduling, no delegation, no `ask_user` or task list, no MCP servers. A tool's use shows in the transcript as in any conversation. A chat's tools are brought in line at its next message, as an agent's are, so turning the web off counts from there.
- **No approvals.** Nothing it is offered changes anything on the Mac, and its record's tool access is `none`, under which nothing waits for approval, so a chat never puts anything in the Inbox.
- **No folder.** A chat has none, and none can be chosen. Its documents go in a folder of its own in the data folder, `chats/<id>`, whatever path the model gives: `write_document` refuses one outside it. Its result's `details.path` is the document's full path, so the conversation can offer to open it. An archived chat keeps the folder; deleting the chat removes it, as it does a scratch folder. It is not in a backup, which copies the database and settings only.
- **What it is told.** The `chat` section of the system prompt, in chats only: that it is pi²'s chat assistant, that it has no folder and changes nothing on the Mac (and an agent can do that), and, with the tools it has, when to read the web and where its documents go. The chat instructions in Settings are kept but not yet sent (#288).
- **Attachments** work as for any conversation ([attachments.md](attachments.md)).

## The model

Each chat has its own model and thinking level, chosen with `conversation.configure` as in the agent view, also in the middle of a chat. A new chat starts with the model chosen last in a chat (by `configure`, or passed to `conversation.create`), else chat mode's default model, else the agent view's: choosing a default model in Settings forgets the last one, so it counts from the next chat. The agent view keeps its own last model apart; choosing one in a chat does not change it.

## Settings

Chat mode's settings are under `chat` in the engine's `settings.json`, with these defaults:

| Setting | Default | What it is |
|---|---|---|
| `instructions` | `""` | What the person wants every chat to know; 20,000 characters at most. Used from #288 |
| `defaultModel` | `null` | The model a new chat starts with (`{ provider, modelId }`), or null for the one used last |
| `web` | `true` | Whether chats may read the web; #287 adds a switch for each chat |
| `memory` | `true` | Whether chats remember lasting things across chats. Used from #288 |

`chat.set` changes any of them, each checked (an unknown model is refused), and answers with all four. The engine sends `{ event: "chat", instructions, defaultModel, web, memory }` when an app connects and after every change.

## Everywhere else

- **Activity:** a chat that is answering has a row with `chat: true` and `agentId: null`, so it can be named as a chat. So do the conversations in the `recovery` event.
- **Search:** results have `chat`, so the app can say which is which.
- **Usage:** a chat's spend counts towards the day's total and the budget, as any conversation's. It is not counted as an agent's: the `usage` event has `chats: { cost, tokens }` beside `agents`, and its rows of conversations have `chat`.
- **Export:** a chat's Markdown names the assistant "Assistant"; its JSON has `chat: true` and `agent: null`.
- **Versions:** Try Again and Edit make versions of a chat, each a hidden conversation of its own that the chat stands for everywhere: requests on the chat act on the version shown, and Activity, the Inbox, usage, search, archiving and deleting count a version as the chat. Only chats have them. See [architecture.md](architecture.md#a-chats-versions).
- **Schedules, worktrees, command rules, memory, reference files, variables:** these belong to agents, so a chat has none of them.
