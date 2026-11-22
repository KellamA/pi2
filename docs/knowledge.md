# What an agent knows before the first message

Two things are put in front of the model before the person has said anything: the project's own instructions, and the agent's memory. Chat mode has a memory of its own, apart from the agents', described [below](#chat-modes-memory). The engine side is `engine/src/knowledge.ts`; the app side is `app/Sources/pi2/KnowledgeViews.swift`.

## Project instructions

When a conversation works in a folder that has an `AGENTS.md`, the agent is given its text, as Claude Code and Codex do. Without an `AGENTS.md`, a `CLAUDE.md` is used instead. In one folder they are never combined.

- The folder is the conversation's own (the agent's folder, or the one chosen for the conversation). A conversation in pi²'s scratch folder has none.
- In a git repository, the folders above the conversation's are looked in too, up to the top of the repository and no further, each by the same rule. The top is the nearest folder with a `.git` entry: a folder in a main checkout, a file in a worktree, so a worktree's own top is where the search stops. It is found without running git, since this happens at every request. A folder in no repository is looked in by itself. Folders are walked by their real paths, so a conversation in a link to a folder is treated as in that folder.
- The file is read again for every request, so an edit takes effect at the next message.
- It is put in the prompt as the `project_instructions` section, introduced by a line that says which file it is and that these are the project's instructions for working in this folder. When more than one folder has a file, all are given, the outermost folder's first and the nearest's last, each introduced by where it is from, under a line saying the nearer one has the last word where they differ. A file in a folder above is named by its full path.
- It applies whatever the conversation's tool access is, including tools off: the person chose the folder.
- The text is cut at 24,000 characters in all, with a note in the prompt after each cut file saying where to read the rest. With several files the 24,000 are shared: a file shorter than an equal share is given whole, and the longer ones split what is left equally, so no file is crowded out by a long one.
- A file that is missing, empty, unreadable or not text gives nothing. A file that is a link leading out of its folder is not followed and counts as missing (so `AGENTS.md` as such a link falls through to `CLAUDE.md`); this holds for each folder looked in, so a link in a sub-folder to the repository's top file is not followed either. Links are resolved as `reference.ts` resolves them: the real path must be inside the folder's real path.
- An empty conversation's introduction says "Follows the AGENTS.md in <folder>" (or "the AGENTS.md in <top> and the CLAUDE.md in <folder>"), so the person can see what is in effect. The engine sends the files as `projectInstructionFiles` in the conversation state: `[{ folder, file }]`, outermost first, with each folder's real path, empty when there are none. `projectInstructions` is still sent, as before, for an app built before the list: the name of the nearest file in effect, or null.

Files in sub-folders of the conversation's folder are not read.

## Memory

Memory is per agent and **off by default**, but for a new project's orchestrator, which has it on. A note written in one conversation is given to the model in every later one, so a note planted by something the agent read would persist. In a project, an agent with memory on keeps the project's notes, not notes of its own ([In a project](#in-a-project)).

With memory on, the agent's conversations get:

- **`remember { note }`** adds a note of up to 400 characters (whitespace is tidied to one line; only a note the person writes keeps line breaks, and its later lines are indented under its item in the list). At most 60 notes per agent; at the limit the tool says to forget something first. A note identical to an existing one is not added twice.
- **`forget { id }`** removes a note by the id shown in the prompt.
- **A prompt section, `memory`**, which says the notes are the agent's own from earlier conversations and not instructions from the person, lists them with their ids, and says when to add one (a lasting preference or fact the person stated, a decision that will matter again) and when not to (anything only about this conversation, anything secret, anything merely read in a file or on a page).

Both tools change only pi²'s own notes, so they never ask for approval, whatever the tool access, and are safe to run again after a crash: a `remember` call that is replayed finds the note it already wrote. The tools and section reach existing conversations at their next message, in the same way as other changes to an agent.

### In the app

A project's notes are on its board's Notes tab (`ProjectNotesTab.swift`): each editable in place (Return or leaving the field saves; Shift-Return or Option-Return starts a new line, with the rule of the message field in `ComposeKit`), removed, searched, shared with the whole project when it is for one agent, and added by hand. These changes apply at once, because the agents can change the notes at any time. Chat mode's notes are in Settings › Chat ([below](#chat-modes-memory)).

Every agent's page has the memory switch, "Remember things between conversations", under Memory (`AgentMemorySwitch` in `AgentViews.swift`, #731). It sends `memory.setEnabled` and applies at once, without Save. On a project's agent's page, in the project's Agents tab and the orchestrator's included, its footer says that with it on the agent is given the project's notes (the Notes tab) in every conversation, sub-chats included, and may add to them and remove them, the notes being the project's, shared by its agents with memory on; off, it is not given them and cannot add to them. On a template's page, the footer says that it is what a project's copy of the template starts with, and that with it on chats may read the template's notes. Beside the person's switch: a copy of a template takes the template's, a new project's orchestrator has it on, and the orchestrator turns it on for an agent with `project_agents`, which asks the person, since it widens reach ([projects.md](projects.md#71-every-setting-classed)). Turning memory off keeps the notes but stops them being sent. Duplicating an agent copies the switch, but not its own notes.

### Where it is stored

One session document, `pi2.memory`: under `agents`, keyed by agent id, `{ enabled, notes: [{ id, text, createdAt, conversation }], next }`, and chat mode's notes under `chat`, `{ notes, next }`. Nothing is added to the agent's profile. Deleting an agent leaves its notes behind; they are not shown or sent anywhere, and the document is small.

### Requests and events

| Request | Does |
|---|---|
| `memory.setEnabled { agentId, enabled }` | turns memory on or off |
| `memory.add { agentId, text }` | adds a note by hand (same limits; its line breaks are kept, each line tidied and blank lines dropped) |
| `memory.edit { agentId, id, text }` | changes a note's text |
| `memory.delete { agentId, id }` | removes a note |

`memory.add`, `memory.edit` and `memory.delete` take `chat: true` in place of `agentId` for chat mode's notes; `memory.setEnabled` refuses it, since chat mode's switch is `chat.set { memory }`.

After every change, from the app or from a tool, the engine broadcasts `{ event: "memory", agents: { <agentId>: { enabled, notes: [{ id, text, createdAt, conversation }] } }, chat: { notes }, projects }`, and sends the same event to an app when it connects. `conversation` is null for a note the person wrote.

### In a project

In a project, a project agent with memory on is given that project's notes instead of its own. `remember` shares a note with the project; `forget` can remove only a note shared with the project or addressed to this agent. The same holds in a sub-chat that runs as that agent. Other conversations, including chats, keep their own memory.

`memory.add`, `memory.edit` and `memory.delete` take `projectId` instead of `agentId` or `chat: true`. A note starts shared; `memory.edit` can change its `audience` to a project agent's id, or to `null` to share it again. The `memory` event's `projects` field is keyed by project id and holds `{ notes }` for each stored project notebook. The [projects contract](projects.md#38-notes-pi2memory) gives the note shape. The limits are the same as for an agent's notes, but count across the whole project. `memory.setEnabled` still takes an `agentId`.

## Chat mode's memory

Chat mode ([chat.md](chat.md)) remembers lasting things the person tells it, across chats, and can read what the agents remember. It does not work the other way: an agent never sees what chat mode remembers (#288, the owner's decision on #172).

- **Its switch** is `memory` in chat mode's settings, **on by default**, unlike an agent's: the person comes to chat mode to talk about themselves and their questions, and every note is in Settings › Chat, where it can be edited or deleted.
- **Its own notes** are one set for every chat, under `chat` in the memory document, with ids `c1`, `c2`… so that none can be taken for an agent's (`m1`…). With memory on, a chat is offered `remember` and `forget` as an agent is, with the same limits and guidance, and they change chat mode's notes only: in a chat, `forget` with an agent's note's id finds nothing. Its `memory` section lists them in full, as an agent's lists its own.
- **The agents' notes** are read with `agent_notes { agent?, search? }`, a tool only a chat with memory on is offered and that refuses anywhere else. It gives one agent's notes by name (or id), or every agent's, and with `search` only the notes with at least one of the words. It reads the notes of agents that exist and have memory on: an agent whose memory is off has its notes kept but not used, by it or by a chat. It gives at most 24,000 characters at once, one agent's full notes; more than that, it says which agents have how many and asks for one agent or some words. It changes nothing, so it is safe to run again.
- **Why a lookup, not the notes in the prompt.** Everything in the prompt is read again at every turn of every chat. One agent's 60 notes come to about 24,000 characters (some 6,000 tokens), measured with the demo model's `/system sizes`, and each agent with memory on adds as much. Instead, the chat's `memory` section has one line naming the agents with notes (about 330 characters for one), saying they can be read with `agent_notes` when a question may touch what the person told an agent, that they are read-only, and that no agent sees chat mode's notes. It names them without saying how many notes each has, so an agent writing a note does not change every chat's prompt. The three tools' definitions add about 1,350 characters. `engine/test/chatmemory.ts` prints these sizes.
- **Off**, a chat is offered none of the three tools and has no `memory` section, so nothing is remembered and nothing is read, chat mode's or the agents'. A call that comes anyway is refused. The notes are kept, and come back with the switch, from each chat's next message.
- **Never to an agent.** An agent's `memory` section and its `remember` and `forget` tools are for its own notes (or, in a project, its project's notes), not chat mode's. It is never offered `agent_notes`. A chat's notes are in its system prompt, not its transcript, so a conversation made from a chat's messages is not given them either.
- **In the app,** Settings › Chat has the switch and chat mode's notes, edited, deleted and added as an agent's are in its settings, and below them the agents' notes, read-only, by agent ([chat.md](chat.md#in-the-app)).

## Limits

- Notes are plain short text; there is no search or ranking, and all of an agent's notes (up to 60 × 400 characters) go into the prompt every time.
- The agent decides what to remember from the prompt's guidance; nothing stops a model from noting something it should not. That is why memory is off by default and the notes are visible and editable.
- Agents' own notes are not shared between agents, and a sub-chat uses the memory of the agent it runs as. A chat reads the agents' own notes only when it chooses to look them up, so it may answer without them.
- Project instructions are read from one file per folder, from the conversation's folder up to the top of its git repository; they are not combined with other agents' instructions, and nothing above a repository's top (or above a folder in no repository) is read.
