# What an agent knows before the first message

Two things are put in front of the model before the person has said anything: the project's own instructions, and the agent's memory. The engine side is `engine/src/knowledge.ts`; the app side is `app/Sources/pi2/KnowledgeViews.swift`.

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

Memory is per agent and **off by default**. A note written in one conversation is given to the model in every later one, so a note planted by something the agent read would persist; the person turns memory on for the agents they want it for. In the agent's settings: "Remember things between conversations".

With memory on, the agent's conversations get:

- **`remember { note }`** adds a note of up to 400 characters (whitespace is tidied to one line). At most 60 notes per agent; at the limit the tool says to forget something first. A note identical to an existing one is not added twice.
- **`forget { id }`** removes a note by the id shown in the prompt.
- **A prompt section, `memory`**, which says the notes are the agent's own from earlier conversations and not instructions from the person, lists them with their ids, and says when to add one (a lasting preference or fact the person stated, a decision that will matter again) and when not to (anything only about this conversation, anything secret, anything merely read in a file or on a page).

Both tools change only pi²'s own notes, so they never ask for approval, whatever the tool access, and are safe to run again after a crash: a `remember` call that is replayed finds the note it already wrote. The tools and section reach existing conversations at their next message, in the same way as other changes to an agent.

### In the app

The settings section shows a switch, then the notes, newest first, each editable in place (Return or leaving the field saves) with a delete button and when and by whom it was written; a field to add a note by hand; and a footer saying that every note is sent to the model in every conversation with the agent. These changes apply at once; they are not part of the form's Save, because the agent can change its notes at any time. Turning memory off keeps the notes but stops them being sent.

### Where it is stored

One session document, `pi2.memory`, keyed by agent id: `{ enabled, notes: [{ id, text, createdAt, conversation }], next }`. Nothing is added to the agent's profile. Deleting an agent leaves its notes behind; they are not shown or sent anywhere, and the document is small.

### Requests and events

| Request | Does |
|---|---|
| `memory.setEnabled { agentId, enabled }` | turns memory on or off |
| `memory.add { agentId, text }` | adds a note by hand (same limits) |
| `memory.edit { agentId, id, text }` | changes a note's text |
| `memory.delete { agentId, id }` | removes a note |

After every change, from the app or from a tool, the engine broadcasts `{ event: "memory", agents: { <agentId>: { enabled, notes: [{ id, text, createdAt, conversation }] } } }`, and sends the same event to an app when it connects. `conversation` is null for a note the person wrote.

## Limits

- Notes are plain short text; there is no search or ranking, and all of an agent's notes (up to 60 × 400 characters) go into the prompt every time.
- The agent decides what to remember from the prompt's guidance; nothing stops a model from noting something it should not. That is why memory is off by default and the notes are visible and editable.
- Notes are not shared between agents, and a sub-chat uses the notes of the agent it runs as.
- Project instructions are read from one file per folder, from the conversation's folder up to the top of its git repository; they are not combined with other agents' instructions, and nothing above a repository's top (or above a folder in no repository) is read.
