
# Projects: the contract

This is the contract for the projects epic, [#450](https://github.com/KellamA/pi2/issues/450): the engine's documents, requests, events, tools and prompt sections for a project, how what exists today is carried over, and what the preview switch turns on and off. Every later issue of the epic (#456 to #483) is built against it, several at once, by agents who read this page and not the conversation in which the design was made. Where this page and an issue's text differ, this page has the last word on names and shapes; [section 12](#12-the-later-issues) says which issues it changes and who owns each piece that several issues share.

The design it builds is [design/projects.md](design/projects.md), with its drawings in [design/projects-drafts.html](design/projects-drafts.html). This page does not repeat why; it says exactly what. Where the design left something open, this page decides it, and [section 13](#13-decisions-this-contract-made) lists each decision with its reason. What only the owner can decide is in [section 14](#14-questions-for-the-owner), each with the answer this page is written for. Nothing in the epic starts until the owner has agreed this page (#455).

#456 has built the project itself, its requests and the preview switch, with the places the later issues fill in ([12.1](#121-who-owns-what-several-issues-share) says where); #457 the agents of a project, templates and `runsAs`; #463 reports and waking; #466 the orchestrator's one conversation, what it is told of the project, and Start fresh. When a piece is built, its issue updates the part of this page it built if the build had to differ, in the same pull request, so the page stays true for the issues after it. Once #483 has taken the old way out, this page becomes the guide to projects for a person and a developer.

**How to read it.** Read [section 1](#1-words) and [section 2](#2-the-preview-switch) whatever your issue, then [12.1](#121-who-owns-what-several-issues-share) and the sections your issue's row in [12.2](#122-each-issue) names. Types are written as TypeScript, as `engine/src/state.ts` writes them. Times are milliseconds since 1970, as everywhere in the engine. "The person" is whoever uses pi²; "an agent" is a model working in a conversation.

## Contents

1. [Words](#1-words)
2. [The preview switch](#2-the-preview-switch)
3. [Documents](#3-documents)
4. [Requests and events](#4-requests-and-events)
5. [Tools for agents](#5-tools-for-agents)
6. [Prompt sections, and what the orchestrator is told](#6-prompt-sections-and-what-the-orchestrator-is-told)
7. [Reach: what an agent can only ask for](#7-reach-what-an-agent-can-only-ask-for)
8. [Settings: without asking, waking, limits](#8-settings-without-asking-waking-limits)
9. [Carrying over](#9-carrying-over)
10. [The app](#10-the-app)
11. [What the engine cannot check](#11-what-the-engine-cannot-check)
12. [The later issues](#12-the-later-issues)
13. [Decisions this contract made](#13-decisions-this-contract-made)
14. [Questions for the owner](#14-questions-for-the-owner)

## 1. Words

The design's words ([design/projects.md](design/projects.md#words)) hold: project, orchestrator, agent, template, hub, board, Needs you. This page adds:

- **Project agent**: an agent that belongs to a project (it has a `projectId`). The orchestrator is one.
- **Template**: an agent that belongs to no project. Every agent that exists today is one, unchanged; with the preview off they are still shown and used as agents, as now.
- **Copy**: a project agent made from a template. It remembers which (`template`), so **Update from template** can say what would change.
- **The orchestrator's conversation**: the one current conversation between the person and a project's orchestrator. After **Start fresh**, the ones before it are its **earlier conversations**: readable, taking no messages while the preview is on.
- **Other conversations** of a project: its top-level conversations that are not the orchestrator's, current or earlier. Carrying over makes most of them; the person can start one with any agent of the project.
- **Runs as**: the agent whose settings a conversation uses at its next message. For almost every conversation it is its `agentId`, as today; for a conversation carried over, with the preview on, it is the project's copy of that agent ([3.4](#34-which-agent-a-conversation-runs-as-runsas)).
- **Reach**: what agents may do or spend without the person. A change that widens it is one an agent can only ask for ([section 7](#7-reach-what-an-agent-can-only-ask-for)).
- **Report**: how one run of a sub-chat of the orchestrator ended: its answer, or that it failed or was stopped. A sub-chat continued several times has a report for each run.
- **Catch-up**: a short text pi² puts in front of the orchestrator's next input, saying what changed in the project since its last turn ([6.4](#64-the-catch-up-and-the-state-block)).
- **Start**: any new run of an agent that an agent or the person sets going in a project: a new sub-chat, a sub-chat continued, work assigned. Every start passes one admission check ([8.3](#83-limits-and-the-one-admission-check)).
- **Allowed commands**: commands an agent may run without asking ([allowed-commands.md](allowed-commands.md)). They were called rules until #460, which has landed; their stored fields and requests (`commandRules`, `rules.add`, `rules.remove`) kept their names. In this page **rule** always means a project's rule.

## 2. The preview switch

Projects are a preview until #483. The switch is a setting of the engine's, so that the engine, not only the app, knows whether agents are told about projects.

- **Where:** `settings.json`, as `projects: { preview: boolean }`. Absent means off. Read through one function, `projectsOn()` in `engine/src/projects.ts`, which every piece of the epic asks.
- **Changed by:** `projects.setPreview { on, plan? }` ([4.2](#42-requests)). Turning it on runs the carrying-over ([section 9](#9-carrying-over)) when it has something to do, from the plan the person was shown.
- **Shown:** Settings › General, under **Projects (preview)**, with a line saying what it does and that switching it off shows everything as it was.

What each state does:

| | Never turned on | On | Turned off again |
|---|---|---|---|
| Sidebar, Inbox, agents' pages, Activity, Archive | As today | Projects: the hub, Needs you, the Dashboard, templates ([section 10](#10-the-app)) | As today, showing every conversation, including those made in projects; agents with a `projectId` are left out of the agents' list ([10.2](#102-with-the-preview-off)) |
| Chat mode | As today | As today | As today |
| Documents | Nothing new is written | As [section 3](#3-documents) says | Kept as they are; nothing in them is changed by switching off |
| A conversation's agent | Its `agentId` | Its project's copy, for a conversation carried over (`projectAgentId`); its `agentId` for every other | Its `agentId` |
| What a conversation outside any project is told | As today | As today, byte for byte: prompt, sections, tools, tool descriptions, summary instructions ([6.1](#61-the-sections)) | As today |
| What a conversation in a project is told | — | The project's sections and tools ([5](#5-tools-for-agents), [6](#6-prompt-sections-and-what-the-orchestrator-is-told)) | No project section, tool, note or catch-up from its next message; what it was already given stays in its history ([6.6](#66-what-switching-the-preview-off-leaves-in-a-conversation)) |
| A project's limits and its `startAgents` switch | — | Enforced | Still enforced for conversations in that project ([8.3](#83-limits-and-the-one-admission-check)): switching off removes no protection from work that can still run |
| A project's other switches, waking rules | — | Enforced | Not needed: the project tools they govern are not offered; reports wake as [wakes.md](wakes.md) says |
| An earlier conversation with the orchestrator | — | Takes no messages | Takes messages, as any conversation |
| New conversations made the old way (a schedule, Continue with an Agent) | As today | Put in the project of their folder as they are made ([9.9](#99-conversations-made-later)) | As today |
| Events | The new events of [4.4](#44-what-an-app-is-sent-on-connecting), with `preview: false` and nothing in them, and the fields added to existing events; the app ignores them | All sent and used | As in the first column, with the projects in them |
| Requests that exist today | As today | As today, with the additions [4.2](#42-requests) names | As today: every one works, for templates and project agents alike |
| Requests new in this epic | Refused, but `projects.list`, `projects.setPreview` and `projects.carryOver` with `dryRun` | All | As in the first column |

The refusal of a new request while the switch is off is one message for every request: "Projects are a preview. Turn them on in Settings › General first."

What does not wait for the switch: #469's ability to fill a throwaway copy with a demo project (which turns the switch on in that copy).

Turning the switch on or off counts for each conversation from its next message, as any change to an agent does: an answer being written keeps what it started with. The engine sends the `projects` event to every app at once.

## 3. Documents

### 3.1 Where things are kept

Every document is a session document of pi durable, in `session.sqlite` in the data folder, like `pi2.library` and `pi2.agents` today, so a commit can change several together. The GitHub listing is a cache, in a file.

| What | Document (`kind`) | Code | New or added to | Owner |
|---|---|---|---|---|
| Projects, the carrying-over record, news for each orchestrator | `pi2.projects` | `engine/src/projects.ts` | New | #456 (with `news` stored); `carry` #458; delivering `news` #466 |
| Agents and templates | `pi2.agents` | `state.ts` | Fields added to `AgentProfile` | #456 (fields), #457 |
| Conversations | `pi2.library` | `state.ts` | Fields added to `Meta` | #456, #458, #466 |
| Rules | `pi2.projectRules` | `engine/src/projectrules.ts` | New | #459 |
| Notes | `pi2.memory` | `knowledge.ts` | `projects` added beside `agents` and `chat` | #461 |
| Needs you | `pi2.needs`, and the `Inbox` in memory as today | `engine/src/needs.ts` | New; the Inbox gains one field and one way to be answered | #462 |
| Reports | `pi2.reports` | `engine/src/reports.ts` | New | #463 |
| What wakes whom | `pi2.wakes` | `wakes.ts` | Fields added to a watch | #463 |
| Work kept by pi² | `pi2.work` | `engine/src/work.ts` | New | #467 |
| What pi² did on GitHub, and what it is doing | `pi2.github` | `engine/src/github.ts` | New | #468 |
| GitHub's listing | `github.json` in the data folder (a cache) | `engine/src/github.ts` | New | #468 |
| The record of changes | `pi2.changes` | `engine/src/changes.ts` | New | #465 |
| The preview switch | `settings.json`, `projects.preview` | `projects.ts` | New key | #456 |

Nothing that exists is removed, renamed or rewritten. Every field added is optional, so a document written before it reads as it did, and a field an older app does not know is ignored by it (the app's `Codable` types ignore unknown keys, and `EngineClient.handle` ignores unknown events).

### 3.2 The project (`pi2.projects`)

```ts
type ProjectsDoc = {
	projects: Record<string, Project>;
	/** What carrying over has done, so that a second run adds only what is new (section 9). */
	carry: CarryRecord;
	/** By project id: what the orchestrator has not been told yet (6.4). Oldest first. */
	news: Record<string, News[]>;
	/** The next id of a piece of news, across all projects. */
	nextNews: number;
};

type Project = {
	/** "p-" and a UUID. Never reused. */
	id: string;
	/** 1 to 80 characters, trimmed. Unique, ignoring case, among projects not deleted. */
	name: string;
	/**
	 * The real path of the project's folder, or null for a project with no folder (13, decision 7). At most one project
	 * not deleted has a given folder; any number may have none.
	 */
	folder: string | null;
	/** The GitHub repository attached, whose issues and pull requests are the work list; null: the list is kept by pi². */
	repository: { owner: string; name: string } | null;
	/** The project agent that is its orchestrator: in `pi2.agents`, with this `projectId` and `role: "orchestrator"`. */
	orchestratorId: string;
	/**
	 * The orchestrator's conversation now. `projects.create` makes it, empty, with the project. Null when it was deleted
	 * (3.6), and in a project carrying over made with the default orchestrator (9.6), until the person first opens or
	 * writes to the orchestrator: the app then makes it with `projects.startFresh`, and it begins with the state block (6.4).
	 */
	conversation: number | null;
	/** Earlier conversations with the orchestrator, oldest first (Start fresh, 6.5). */
	earlier: number[];
	settings: ProjectSettings;
	createdAt: number;
	updatedAt: number;
	/** Archived by the person: out of the sidebar; nothing new starts in it (3.6). */
	archivedAt?: number;
	/** Deleted by the person: shown nowhere but the Archive (3.6). */
	deletedAt?: number;
	/** Made by carrying over, at this time. */
	carriedAt?: number;
};
```

`ProjectSettings` is in [section 8](#8-settings-without-asking-waking-limits), with its defaults.

- **The work list's mode** follows `repository`: null, the list kept by pi² ([3.11](#311-work-pi2work-pi2github-githubjson)); set, the repository's issues and pull requests. There is no separate field to disagree with it.
- **The folder** is checked to be a folder when it is set, and stored by its real path. A folder that has gone since is kept as it is; the `projects` event says `folderMissing: true`, and the project's agents work as a conversation whose folder has gone does today.
- **A project with no folder** (`folder: null`): its agents' conversations work where a conversation with no folder works today: the data folder's `workspace` folder, shared by every such conversation (`env` in `main.ts`; each still has its own scratch folder in `PI2_SCRATCH`). It has no Branches tab content and cannot attach a repository.

```ts
/** What carrying over has done (section 9). Keys are stable, so a later run finds what an earlier one made. */
type CarryRecord = {
	/** When a run last changed something, and the backup made before the first run that did (9.8). */
	ranAt: number | null;
	backup: string | null;
	/**
	 * The grouping key of a folder (9.2) to the project carrying over put its conversations in. "none": no folder. Every key
	 * that reaches a project is recorded, so a project whose folder moved is found by the old key and the new.
	 */
	folders: Record<string, string>;
	/**
	 * "<projectId> <templateId>" to the copy made or adopted for that project. Kept when the person deletes the copy: a
	 * deleted copy is not made again (9.5).
	 */
	copies: Record<string, string>;
	/**
	 * The notes of agents a run has dealt with (9.7): "<projectId> <templateId> <noteId>" for a note copied into that
	 * project, recorded in the commit that copies it, and where it went; "<agentId> <noteId>": "left" for a note of an agent
	 * deleted, left where it is.
	 */
	notes: Record<string, { projectId: string; noteId: string } | "left">;
	/** Copies whose variables' values are still to be copied into the Keychain (9.5). */
	secrets: { copyId: string; templateId: string; names: string[]; tries: number; lastError: string | null }[];
};

/** One thing the orchestrator has not been told yet (6.4). */
type News = {
	/** "w" and a number from `nextNews`: each piece of news is told once, by its id. */
	id: string;
	at: number;
	kind: "report" | "message" | "change" | "work" | "limit" | "need";
	/** One line, as the catch-up shows it. */
	text: string;
	/** What it is about (a conversation, a need, a change, a work item), for the board to link to. Not unique. */
	ref: string;
	/** A message the person wrote to another agent: never dropped for room (6.4). */
	keep?: true;
};
```

### 3.3 Agents and templates (`pi2.agents`)

A project agent is an `AgentProfile` in the same document as every agent today, with these fields added. Keeping them in one document means every place the engine looks an agent up by id (its tools, allowed commands, memory switch, variables, schedules, Allow everything, its worktree set-up, the summary size) works for a project agent with nothing more, and a conversation started with a project agent behaves as one started with the same agent does today.

```ts
// Added to AgentProfile (state.ts). All optional; an agent saved before has none, and is a template.
projectId?: string;
/** The project's orchestrator. Exactly one agent of each project not deleted has it. */
role?: "orchestrator";
/** A copy: the template it was made from, when, and the template's `updatedAt` then. */
template?: { id: string; copiedAt: number; templateUpdatedAt: number };
/** Made by an agent through a tool (the board's mark): which, and in which conversation. Absent: made by the person or by carrying over. */
madeBy?: { agentId: string; conversationId: number };
/** When it was last saved. Absent in an agent not saved since this field came: read as `createdAt`. */
updatedAt?: number;
/**
 * Removed through a tool (5.2): kept whole, with its variables' values, so that Undo can put it back; offered to
 * nobody, listed only as removed, and deleted for good only by the person (`agents.delete`).
 */
removedAt?: number;
```

- **Templates** are the agents with no `projectId`. There is no other store and no other kind: today's agents are templates as they stand, which is how "today's agents become templates" is done without copying them. A template is made, edited, duplicated and deleted with today's requests (`agents.save`, `agents.duplicate`, `agents.delete`).
- **Names** are unique, ignoring case, among the templates, and among the agents of each project (removed ones included). A project's agent may share a name with a template or with another project's agent. With the preview on, every tool that names an agent looks only among the agents of the conversation's own project, or only among templates outside any project. `delegate` names an agent among those the conversation may hand work to, as today, so with the preview off it works as today for every conversation.
- **The orchestrator** is a project agent with `role: "orchestrator"`. It cannot be removed or deleted; making another agent the orchestrator is `projects.setOrchestrator` ([6.5](#65-start-fresh)).
- **What does not make sense in a project.** Every setting of an agent today holds for a project agent, except:
  - `cwd`: always the project's folder (null for a project with no folder). The engine sets it, at copying and whenever the project's folder changes; `agents.save` refuses another (“An agent of a project works in the project's folder”). This is where a *new* conversation of the agent starts. A conversation already working somewhere keeps its own folder, which is its `pi.agent` document's, not the agent's: a conversation carried over, a sub-chat in another repository, a conversation in a worktree all stay where they are ([9.6](#96-conversations-what-each-keeps)).
  - `delegates`: the orchestrator's current conversation hands work to every other agent of its project, whatever its `delegates` say, and to no agent outside it. Any other conversation of a project agent hands work to the agents its `delegates` name, which for a project agent are agents of its own project.
- **Copying a template** into a project, by the person or by carrying over, copies every setting, through the same path as `agents.duplicate`, with these differences: the new agent gets `projectId`, `template` and the project's folder; `delegates` is mapped to the project's copies of the templates it named (a template the project has no copy of is left out); allowed commands are copied, all of them, whatever their folder (each holds only in its own folder, so one for another folder does nothing until a conversation works there); the memory switch is copied. Variables are copied with their names only, and Allow everything is not copied, as for a duplicate, except when carrying over ([9.5](#95-agents-copies-adoption-and-secrets)). No conversation, schedule or worktree is copied. Carrying over makes its copies inside its own commits (9.8), not through `agents.duplicate`'s path, which commits on its own: it does there what that path's feature hooks do (`agentDuplicated`: the memory switch, the variables' names), and turns `worktree` off for a copy in a project whose folder is no repository, where `agents.save` would refuse it, saying so in the report (9.5). A copy made **by an agent** is made at the baseline of [7.2](#72-asking-allowing-refusing), and asks for the rest.
- **Update from template** compares the copy with its template, setting by setting, over every setting a copy takes from its template except its name, `cwd`, `delegates`, allowed commands, variables and Allow everything, which are the project's own. It says what would change (`agents.updateFromTemplate` with `apply: false`) before changing anything, then changes those settings and sets `template.copiedAt` and `templateUpdatedAt`. A template deleted since leaves the copy as it is, with **Update from template** unavailable ("The template this agent was made from has been deleted").
- **The default orchestrator** is a template that is not stored: a constant, `DEFAULT_ORCHESTRATOR` in `projects.ts`, like chat mode's assistant in `chat.ts`. It is not in the `agents` event and cannot be edited; a project made without naming a template gets a copy of it, which is an ordinary project agent from then on. Its settings: name "Orchestrator", colour violet, the default model, thinking unset, access Ask first, memory on, summarising at 100,000 tokens, the built-in tool **Summarise its own conversation** on, everything else as a new agent's defaults. Its instructions, in full:

  > You are the orchestrator of this project. The person talks to you. Plan the work with them, hand each piece to one of the project's agents with `delegate` or `work` (`assign`), review what comes back, and report plainly what was done and what was not. Keep the project's work list up to date. When a decision is the person's, put it to them with `needs_you` and carry on with what does not depend on it. If the project has no agent suited to a piece of work, make one with `project_agents`.

### 3.4 Which agent a conversation runs as: `runsAs`

The engine decides which agent a conversation runs as with one function, `runsAs(meta)` in `state.ts`, and every place that today reads `agents[meta.agentId]` for a conversation reads `agents[runsAs(meta)]` instead (#457 makes that change, everywhere at once):

```ts
/** The agent whose settings conversation `meta` uses at its next message. */
function runsAs(meta: Meta | undefined, agents: Record<string, AgentProfile>): string | undefined {
	const copy = meta?.projectAgentId === undefined ? undefined : agents[meta.projectAgentId];
	if (projectsOn() && copy !== undefined && copy.removedAt === undefined && !projectDeleted(meta!.projectId) && !projectDeleted(copy.projectId)) return meta!.projectAgentId;
	return meta?.agentId;
}
```

The agents are an argument, since the engine keeps no one map of them that every caller reads (main.ts, a feature's `engine.agents()` and a commit's `tx.doc(Agents)` each have their own). Beside it, `agentOf(meta, agents)` gives the agent itself, or none for a chat, an agent deleted or one removed through a tool; most lookups use it.

A conversation whose copy has been removed or deleted, or whose project has been deleted, runs as its `agentId`; one whose `agentId` was deleted too keeps the setup it has, as a conversation whose agent was deleted does today. A conversation whose own `agentId` names a removed project agent keeps the setup it has in the same way.

Changing what a conversation runs as changes only what is taken from the agent at each message today: its tools (`syncTools`), Allow everything (`takeSwitch`), its allowed commands, memory, variables and the rest that are read from the agent as they are used. Its folder, its worktree, its "Always Allow … Here" and its access level are the conversation's own and do not change ([9.6](#96-conversations-what-each-keeps)).

### 3.5 Conversations (`pi2.library`)

```ts
// Added to Meta (state.ts). All optional.
/** The project it belongs to. Set on every conversation of a project, sub-chats included (taken from the parent as one is made). */
projectId?: string;
/** For a conversation carried over: the project's copy of its agent, which it runs as while the preview is on (3.4). */
projectAgentId?: string;
/** An orchestrator's conversation begun with Start fresh: the one it followed. */
freshFrom?: number;
```

- `agentId` is never changed by anything in the epic. With the preview off, a conversation is exactly what it was.
- A conversation made in a project with the preview on (by the person on the hub, by `delegate`, by `work assign`, by Start fresh) has `agentId` set to the project agent it was made with, and `projectId`. It has no `projectAgentId`. The person starts one of a project's other conversations with today's `conversation.create { agentId }`, naming a project agent: the conversation takes that agent's `projectId`.
- A chat (`chat: true`) and a chat's version never have a `projectId`. Chat mode is outside projects.
- Whether a conversation is the orchestrator's, current or earlier, is said only by the project (`conversation`, `earlier`): one place, which cannot disagree with another.
- With the preview on, an earlier conversation with the orchestrator takes no messages: `submit` and `continue` refuse with "This is an earlier conversation with the orchestrator. Write in the current one." With the preview off it is an ordinary conversation.

### 3.6 Archiving and deleting

Two states are kept apart, each with one owner, so that neither can undo the other:

- **A conversation's own**, as today: `archivedAt` and `deleted` on its `Meta`, set by the person (archive, delete, restore) and by an agent's `sub_chats` archive. Nothing in the epic writes them except as this table says.
- **A project's**: `archivedAt` and `deletedAt` on the `Project`, set only by the person (`projects.archive`, `projects.unarchive`, `projects.delete`). It hides the project with the preview on; it changes no conversation's own state, so with the preview off every conversation is where it was.

| Operation | A conversation's own state | The project | With the preview off |
|---|---|---|---|
| Archive a project | Unchanged. Refused while any conversation of the project is working or waiting on the person: "Stop the project's agents first." | Archived: out of the sidebar; `submit`, `continue` and starts in it refused: "This project is archived. Restore it first." Its approvals and questions cannot be waiting (it was idle); its other Needs you items stay, shown under the archived project | Its conversations show and work as today |
| Restore a project | Unchanged | Back | — |
| Delete a project | Unchanged. Refused as archiving is | Deleted: shown only in the Archive, under its name, with its conversations; its Needs you items withdrawn; its rules, notes, work and changes kept, shown nowhere. Conversations keep their `projectId`. Only those whose own `agentId` is not one of the project's agents fall back to no project: they run as their `agentId`, hand work to templates, read their agent's own notes, and have no project switch or limit. The project's own conversations keep their agent and their project, but its agents are not offered for delegation and starts with them (including continuing a sub-chat with one) are refused. Their schedules are held, with the reason in Activity › Scheduled and `engine.log`, until edited to use another agent | Conversations stay where they were; the same refusal and schedule hold apply to the project's own agents |
| Restore one conversation of a deleted project (the Archive, preview on; **not built yet**) | Would restore it if archived | Intended to move it to the project of its folder by the lookup of [9.4](#94-projects-lookup-and-adoption), making a project if needed. Today, a template-backed conversation can be forked into its folder's project; this does not move or restore the original | — |
| The person archives one conversation of a project (today's Archive) | Archived, as today: its work stopped, its sub-chats archived with it | Unchanged. If it was the orchestrator's current conversation, the hub shows it archived with Restore, and `conversation` keeps pointing at it | As today |
| The person restores it | Restored, as today | Unchanged | As today |
| The person deletes one conversation | Deleted, as today | If it was the orchestrator's current conversation, `conversation` becomes null, and Start fresh (`projects.startFresh`) makes a new one, which begins with the state block (6.4). If an earlier one, it leaves `earlier` | As today |
| `sub_chats` archives a sub-chat | As today | Unchanged | As today |
| A conversation made later in the folder of an archived project (a schedule's run) | — | It goes in that project ([9.9](#99-conversations-made-later)), and the project is restored, since the person set that run going | As today |
| A conversation made later in the folder of a deleted project | — | It goes in a new project for that folder | As today |

The engine tests cover the implemented archive and delete operations with the preview on and off.

### 3.7 Rules (`pi2.projectRules`)

```ts
type ProjectRulesDoc = { projects: Record<string, { rules: ProjectRule[]; next: number }> };

type ProjectRule = {
	/** "r" and a number, per project, never reused. */
	id: string;
	/** 1 to 1,000 characters. Line breaks kept; each line trimmed, blank lines dropped. */
	text: string;
	/** Whom it binds. */
	binds: "orchestrator" | "everyone";
	/** Who put it there. */
	addedBy:
		| { kind: "person" }
		| { kind: "agent"; agentId: string; conversationId: number } // added by the orchestrator, as the person dictated it (5.4)
		| { kind: "proposal"; agentId: string; conversationId: number; need: string }; // proposed, then accepted by the person
	createdAt: number;
	updatedAt: number;
};
```

- The array's order is the order the prompt and the board show, numbered from 1. **Order decides nothing else**: no rule outranks another by its place, and the prompt says so ([6.1](#61-the-sections)).
- At most 50 rules per project. A 51st is refused: "This project has 50 rules, the most it can have. Remove one first."
- `binds` has two values. Binding one named agent was left open by the design; the shape leaves room to add `{ agent: id }` later without changing the others ([13](#13-decisions-this-contract-made), decision 10).
- A proposed rule waits under Needs you ([3.9](#39-needs-you-pi2needs-and-the-inbox)), not in this document, until the person accepts it.

### 3.8 Notes (`pi2.memory`)

The memory document ([knowledge.md](knowledge.md#where-it-is-stored)) gets a third part, beside `agents` and `chat`:

```ts
// Added to MemoryDoc (knowledge.ts).
projects?: Record<string, { notes: ProjectNote[]; next: number }>;

type ProjectNote = {
	/** "n" and a number, per project. */
	id: string;
	text: string;
	createdAt: number;
	/** The conversation that wrote it; null for a note the person wrote, or one carried over. */
	conversation: number | null;
	/** The agent that wrote it; null for the person. */
	agentId: string | null;
	/**
	 * Who is given it: null, every agent of the project with memory on; an agent's id, that agent only (and only while its
	 * memory is on). A note carried over keeps the audience it had: the copy of the agent it belonged to (9.7). The person
	 * shares it with the project from the Notes tab (`memory.edit` with `audience: null`).
	 */
	audience: string | null;
	/** Copied by carrying over: the agent's note it came from, and that agent's name then, kept if the agent goes. */
	carriedFrom?: { agentId: string; agentName: string; id: string };
};
```

- Notes keep today's limits: 400 characters each, 60 per project. Notes carried over are all kept even past 60; the 61st new one is refused until some are removed, as today.
- **Who reads and writes them.** A project agent whose memory switch is on (`agents[id].enabled` in the memory document, as today) gets, in its `memory` section, the project's notes whose audience is null or itself, and writes notes for the whole project with `remember` (audience null) and removes any it is given with `forget`, in every conversation of its, sub-chats included. With the preview off it gets its own agent notes, as today, which for a project agent are none.
- An agent's own notes (`agents`) and chat mode's (`chat`) are left as they are. Chat mode's `agent_notes` reads the agents' own notes only, not a project's, during the preview ([13](#13-decisions-this-contract-made), decision 22).
- `remember` and `forget` by an agent are changes with a line and Undo ([3.12](#312-the-record-of-changes-pi2changes)).

### 3.9 Needs you (`pi2.needs`, and the Inbox)

Needs you is one list, made of two sources:

- **The Inbox, as today:** approvals and `ask_user` questions, which live in memory while their tool call waits, and come back after a restart because the call runs again ([architecture.md](architecture.md#approvals)).
- **`pi2.needs`:** everything that does not hold a tool call: a question or decision put with `needs_you`, a request for more reach, a proposed rule, and a start refused for a limit. These are stored, so they survive a restart, and stay until answered or withdrawn.

What is stored (`pi2.needs`), as a discriminated union, each kind with all it needs:

```ts
type NeedsDoc = { items: Record<string, StoredNeed>; next: number };

type StoredBase = {
	/** "n" and a number from `next`. Never reused. */
	id: string;
	projectId: string;
	/** The conversation that asked, or (for a limit) the orchestrator's conversation the start was for. */
	conversationId: number;
	/** The tool call that put it there, so that the call run again after a crash finds it rather than putting another. */
	callId: string | null;
	createdAt: number;
};

type StoredNeed =
	| (StoredBase & { kind: "question"; question: string })
	| (StoredBase & { kind: "decision"; question: string; choices: { id: string; label: string }[]; words: boolean })
	| (StoredBase & { kind: "reach"; change: ReachChange; why: string | null })
	| (StoredBase & { kind: "rule"; text: string; binds: "orchestrator" | "everyone"; why: string | null })
	| (StoredBase & { kind: "limit"; start: Start; limit: LimitReading });
```

`ReachChange` is in [7.2](#72-asking-allowing-refusing); `Start` and `LimitReading` in [8.3](#83-limits-and-the-one-admission-check). A choice's `id` is `"c1"`, `"c2"`… in the order given, so an answer names a choice and never has to be told apart from free text.

What is sent (the `needs` event and `needs.list`), as a discriminated union, with what is worked out when it is sent:

```ts
type WireBase = {
	id: string;
	projectId: string | null; // null: an approval or question of a conversation in no project
	conversationId: number;
	rootConversationId: number;
	/** The conversation's title, and its root's, for "in …". */
	title: string;
	rootTitle: string;
	/** The agent the conversation runs as, and its name. */
	agentId: string | null;
	agentName: string | null;
	/** Whether the agent is held until it is answered: true for approvals and ask_user questions only. */
	blocking: boolean;
	createdAt: number;
};

type NeedItem =
	| (WireBase & {
			kind: "approval";
			tool: string; arguments: unknown; question: string | null;
			site?: string; when?: string; rule?: { words: string[]; folder: string; worktrees?: true }; background?: true;
			/** Set when a switch of 8.1 that is off asked: which. Then `answers` is ["once", "deny"]. */
			projectSwitch?: SwitchName;
			/** The answers it takes. */
			answers: ("once" | "always" | "rule" | "deny")[];
	  })
	| (WireBase & { kind: "question"; question: string })
	| (WireBase & { kind: "decision"; question: string; choices: { id: string; label: string }[]; words: boolean })
	| (WireBase & { kind: "reach"; change: ReachChange; why: string | null })
	| (WireBase & { kind: "rule"; text: string; binds: "orchestrator" | "everyone"; why: string | null })
	| (WireBase & { kind: "limit"; start: Start; limit: LimitReading });
```

An approval's `answers` is what the Inbox offers it today (`always` where "Always Allow … Here" applies, `rule` where `rule` is set), or `["once", "deny"]` when `projectSwitch` is set. The Inbox item (`InboxItem` in `state.ts`) gets the one field `projectSwitch?`.

**Answers.** One shape, by kind:

```ts
type NeedAnswer =
	| { kind: "approval"; decision: "once" | "always" | "rule" | "deny" }   // one of the item's `answers`
	| { kind: "question"; text: string }                                    // 1 to 20,000 characters
	| { kind: "decision"; choice: string }                                  // a choice's id
	| { kind: "decision"; text: string }                                    // only when `words` is true
	| { kind: "reach"; allow: boolean }
	| { kind: "rule"; accept: false }
	| { kind: "rule"; accept: true; text?: string; binds?: "orchestrator" | "everyone" } // edited before accepting
	| { kind: "limit"; start: boolean };
```

**One way an answer is taken.** `needs.answer { id, answer }`, today's `inbox.decide` and `inbox.answer`, and nothing else, all call one function, `claim(id, answer)` in `needs.ts`, which takes the item off the list in the same step it reads it, so a second answer to the same item, by whichever route, finds it gone ("This is no longer waiting: it was answered or withdrawn.") and changes nothing. An answer of the wrong kind, or not among its `answers` or `choices`, is refused and leaves the item waiting.

- **Telling the agent.** An approval and an `ask_user` question answer the waiting call, as today. A question, decision, reach request or proposed rule, once answered, is given to the conversation that asked as a wake of a new kind, `answer` ([wakes.md](wakes.md)): "The person answered your question “Merge now or after the release?”: After the release." It wakes the conversation if it is not answering, within the wakes' bounds (the budget, the turn limit, 30 an hour). An answer is the person acting, so a project's limit does not hold it back ([8.3](#83-limits-and-the-one-admission-check)). A `limit` answer goes to the orchestrator's conversation as news instead ([6.4](#64-the-catch-up-and-the-state-block)), since the person, not the orchestrator, chose.
- **Withdrawn**: by the agent (`needs_you` with `withdraw`); when its conversation is deleted, or archived (as an approval is today); when its project is deleted; and a reach request whose fields the person has meanwhile changed by hand, with a line in the asking conversation. A withdrawn item leaves the list at once.
- **Allow everything answers none of them but approvals**, and not an approval with `projectSwitch` ([13](#13-decisions-this-contract-made), decision 17).
- **Order**: oldest first, as the Inbox is.

**Proposed (#507, not agreed):** A question or decision put in a sub-chat is served the same way, with one difference in where the answer goes. While the sub-chat's run is going, the answer wakes the sub-chat itself, queued while it answers and given as its next input, within the wakes' bounds. Once the run has ended — read from the report [3.10](#310-reports-and-waking-pi2reports-pi2wakes) keeps, which it does not change — the answer goes instead to the conversation that handed it the work (for the orchestrator's sub-chat, its current one), in the words any answer takes plus whose question it was, the sub-chat and the piece of work, and how to continue it: "The person answered Forge's question in sub-chat 14 “Fix login” (on #28): After the release. Continue the sub-chat with `delegate`'s `chat`." An answer is the person acting, so a project's limit does not hold it back, whichever conversation it wakes.

**Proposed (#507, not agreed):** For a need put in a sub-chat, the card names the agent that asked, the sub-chat's title, and the piece of work when the run was assigned one; the stored need carries the work item's number for that, put with the question.

The empty event, as an app with the preview off, or with nothing waiting, is sent it: `{ "event": "needs", "items": [] }`. An item, as sent:

```json
{ "id": "n12", "kind": "decision", "projectId": "p-6f0c…", "conversationId": 41, "rootConversationId": 41,
  "title": "pi²", "rootTitle": "pi²", "agentId": "orchestrator-3b1…", "agentName": "Orchestrator", "blocking": false,
  "createdAt": 1763561400000, "question": "Merge #503 now or after the release?",
  "choices": [{ "id": "c1", "label": "Now" }, { "id": "c2", "label": "After the release" }], "words": true }
```

### 3.10 Reports and waking (`pi2.reports`, `pi2.wakes`)

```ts
type ReportsDoc = { projects: Record<string, Report[]> };

/** How one run of a sub-chat of an orchestrator's conversation ended. Kept seven days after it was delivered. */
type Report = {
	/** The run: the sub-chat's submission that `delegate` (or `work assign`) made. Unique. */
	submissionId: number;
	conversationId: number;
	agentId: string;
	title: string;
	/** The batch it was put in with `reports` (`wake`), if any. */
	batch: string | null;
	/** The work item the sub-chat was handed with `work assign`, if any. */
	work: number | null;
	/** Null while the run goes on. */
	ended: { at: number; outcome: "answered" | "failed" | "stopped" } | null;
	/**
	 * Null until it is delivered: given to the orchestrator once, by exactly one of these, in the commit that gives it.
	 * `wake`: a wake carried it. `wait`: `delegate` waiting for it, or `sub_chats` with `wait`, returned it. `read`:
	 * `reports` with `read` returned it.
	 */
	delivered: { by: "wake" | "wait" | "read"; at: number; conversationId: number } | null;
};
```

The answer is the run's own, read from its submission (`harness.submission(id)`, as `delegate` reads it today), never "the last answer in the sub-chat", which a later run of the same sub-chat would replace.

A watch in `pi2.wakes` ([wakes.md](wakes.md#for-developers)) gets two optional fields, read only for a run of a sub-chat of a project's orchestrator:

```ts
// Added to a watch in pi2.wakes.
/** When this run's report wakes the orchestrator. Absent: as the project's `wakeOnReports` says now. */
wake?: "each" | "all" | "failure" | "never";
/** The batch it belongs to (`reports` `wake`, several chats): `all` and `failure` count over the batch's runs. */
batch?: string;
```

**One place decides.** `reports.ts` (#463) has the one function that decides what becomes of a report, `settle(report)`, and nothing else delivers one. It is called when a run ends, when a wait (`delegate`, `sub_chats` `wait`) or `reports` `read` asks for it, and when a batch's last run ends. In order:

1. A report already delivered is given to no one again.
2. A wait that asks for it (`delegate` waiting for this run, `sub_chats` `wait` naming it or waiting for any) takes it: delivered by `wait`, in the commit that returns the call's result, as today.
3. `reports` `read` takes it: delivered by `read`.
4. When the run ends and no wait is asking, its watch's `wake` (or the project's setting: on is `each`, off is `never`) decides:
   - `each`: it wakes the orchestrator's current conversation, as a wake does today; delivered by `wake` in the commit that submits the wake.
   - `all`: nothing until every run of the batch has ended; then one wake gives every report of the batch not delivered yet, oldest first.
   - `failure`: an answered run wakes nobody. The first run that failed or was stopped wakes the orchestrator with its report, and with the batch's reports that ended before it; the batch's later runs wake nobody.
   - `never`: it wakes nobody.
5. A report that woke nobody stays undelivered: the next catch-up names it in one line ([6.4](#64-the-catch-up-and-the-state-block)), and its text comes with `reports` (`read`).

A wake is queued, held (the budget, the hourly cap, the person's Stop) or delayed exactly as [wakes.md](wakes.md) says; a report in a wake not yet submitted is not delivered, and a `read` or a wait that comes first takes it instead, so it is never given twice. Past a project limit, a report wakes nobody ([8.3](#83-limits-and-the-one-admission-check)): it stays undelivered until the orchestrator's next turn or a `read`.

Outside projects, and with the preview off, waking is exactly as [wakes.md](wakes.md) says.

### 3.11 Work (`pi2.work`, `pi2.github`, `github.json`)

#### Items, and one state machine for both kinds of list

```ts
type WorkDoc = { projects: Record<string, { items: Record<string, WorkItem>; next: number }> };

type WorkItem = {
	/** Kept by pi²: 1, 2, 3… per project, never reused. GitHub: the issue's number. Shown as "#12". */
	id: number;
	/** 1 to 200 characters. */
	title: string;
	/** Up to 20,000 characters. */
	text: string;
	state: WorkState;
	/** The class of model it needs (docs/issue-classes.md); null: not classified. */
	class: "local" | "cloud" | null;
	/** Who holds it: the agent working on it, and the conversation it works in. */
	takenBy: { agentId: string; conversationId: number } | null;
	notes: { at: number; by: Who; text: string }[];
	/** What finishing it said was done. */
	result: string | null;
	filedBy: Who;
	createdAt: number;
	updatedAt: number;
	closedAt: number | null;
	/** GitHub only: the issue's address. */
	url?: string;
};

type WorkState = "open" | "in_progress" | "waiting" | "blocked" | "done" | "dropped";
type WorkAction = "file" | "take" | "assign" | "release" | "wait" | "block" | "resume" | "finish" | "close" | "reopen" | "note" | "edit" | "classify";
type Who = { kind: "person" } | { kind: "agent"; agentId: string; conversationId: number };
```

The states are those `scripts/issue` keeps on this repository's issues: open is `backlog`, then `in progress`, `waiting`, `blocked`, and closed as done or dropped. The same words for both kinds of list, and pi² itself moves to a project with nothing to translate (#482).

Every action, for either kind of list, goes through one table. "Holder" is `takenBy`.

| Action | From | To | Holder after | Who may |
|---|---|---|---|---|
| `file` | — | open | none | any agent of the project (under `fileWork`), the person |
| `take` | open | in_progress | the caller | any agent; refused if the item has a holder ("#12 is taken by Forge, in sub-chat 14") |
| `assign` | open | in_progress | the assigned agent and the sub-chat started for it | the orchestrator (under `startAgents`), the person |
| `release` | in_progress, waiting, blocked | open | none | the holder, the orchestrator, the person |
| `wait` | in_progress, blocked | waiting | unchanged | the holder |
| `block` | in_progress, waiting | blocked | unchanged | the holder |
| `resume` | waiting, blocked | in_progress | unchanged | the holder, the orchestrator, the person |
| `finish` | in_progress, waiting, blocked | done | none | the holder (under `closeWork`) |
| `close` | any open state | done or dropped | none | the orchestrator (under `closeWork`), the person |
| `reopen` | done, dropped | open | none | the orchestrator, the person |
| `note`, `edit`, `classify` | any | unchanged | unchanged | `note`: any agent; `edit`, `classify`: the orchestrator, the person |

An action from a state the table does not list is refused, saying the state it is in: "#12 is done. Reopen it first." `take` and `assign` of a closed item are refused that way. `assign` claims the item and starts the sub-chat as one step: if the start is refused (a limit, a switch the person denies, an error), the claim is let go in the same step and the item is as it was.

**The backend.** `work.ts` (#467) owns the dispatcher: the `work` tool, the `work.*` requests, the table above, the shapes of results and errors. It calls one of two backends, chosen by the project's `repository`, through one interface:

```ts
interface WorkBackend {
	list(project: Project, filter: { states?: WorkState[] }): Promise<WorkItem[]>;
	show(project: Project, id: number): Promise<WorkItem>;
	/** Each applies one row of the table, checking `from` against what the backend holds now. */
	apply(project: Project, action: WorkAction, id: number | null, by: Who, args: Record<string, unknown>): Promise<WorkItem>;
}
```

`work.ts` holds the backend kept by pi² (`pi2.work`), where each `apply` is one commit, so two `take`s at once cannot both succeed. `github.ts` (#468) holds the GitHub backend, and the pull-request actions, which have no counterpart in a list kept by pi².

#### The GitHub backend

The attached repository is named in every operation: every `gh` command pi² runs passes `--repo <owner>/<name>` (`-R`), so neither the project's folder nor a conversation's folder decides where it lands. It runs in the project's folder, with the sign-in `gh` already has; pi² keeps no token. For tests, `PI2_GH` names the program to run in place of `gh`.

| A work item's | Is the issue's |
|---|---|
| `id` | number |
| `state` | open with the label `backlog` or none: `open`; with `in progress`, `waiting` or `blocked`: that state; closed as completed: `done`; closed as not planned: `dropped` |
| `class` | the label `local model` or `cloud model` |
| `notes` | comments, oldest first, by whom pi² posted each (from its first line, below) or the person otherwise |
| `result` | the comment that closed it as done, which pi² begins with `**Done.**` |
| `takenBy` | the newest "Taken by" comment pi² posted that no later "Released" comment of pi²'s for the same holder follows, nor any later "Done." or "Dropped." comment of pi²'s, while the issue is in progress, waiting or blocked (#468: a "Released" names its holder, so the loser's in a race does not release the winner) |

Each comment pi² posts for an agent begins with a line naming it, `*From Forge, an agent of the pi² project “pi²”.*`, and ends with a marker GitHub does not show, `<!-- pi2:<intent id> -->`. Labels it needs and the repository lacks are made as `scripts/issue` makes them (the same names, colours and descriptions). Two `take`s at once on GitHub cannot be made one commit: after posting its "Taken by" comment, `take` reads the issue again, and if an earlier "Taken by" of another holder stands, it posts "Released" and is refused as above. (#468: the "Taken by" comments it weighs are those the read before it did not see, and any of the last ten minutes, which may be another take still on its way; an older one it saw on an open issue was left from before a close and reopen outside pi². `finish` and `close` always post "Done." or "Dropped.", with the text when there is one, which ends every hold.)

**Writes, and a write whose outcome is unknown.** Every write to GitHub (an issue filed, a comment, a label, closing, a pull request opened, a merge) is first recorded as an intent in `pi2.github`, then made, then marked done, each a commit:

```ts
type GithubDoc = {
	projects: Record<string, {
		repository: { owner: string; name: string };
		intents: Record<string, { id: string; action: string; args: Record<string, unknown>; at: number; state: "pending" | "done" | "failed" | "unknown"; result?: unknown }>;
		/** Pull requests pi² opened, by number: which conversation, for Send back. Durable: GitHub does not know it. */
		openedBy: Record<string, { conversationId: number; at: number }>;
	}>;
};
```

An intent found pending after a restart, or when its call runs again, is reconciled before anything is written again: pi² looks on GitHub for what it would have made, by the marker in its text (an issue, a comment, a pull request) or by the state it would have set (a label, closed, merged). Found, it is marked done with what was found. Not found and the write cannot have happened (GitHub refused it), it is marked failed and may be tried again. (#468: an intent is one `gh` write, not one action, so a `take` is a comment and a label change, each its own intent. A state not found is written again, since writing a state twice makes nothing twice; only a creating write, an issue, a comment or a pull request, can end `unknown`.) When it cannot tell, it is marked `unknown`, nothing is written again, and the call answers: "pi² could not tell whether GitHub took this (filing “…”). Look at the repository before trying again." The person sees the same under the project's Work tab.

**Pull requests** are only for a GitHub project:

```ts
type PullRequest = {
	number: number;
	title: string;
	url: string;
	/** The head as GitHub names it: "branch", or "owner:branch" from a fork. */
	head: string;
	base: string;
	author: string;
	state: "open" | "merged" | "closed";
	draft: boolean;
	checks: "passing" | "failing" | "pending" | "none";
	mergeable: "yes" | "no" | "unknown";
	/** What reviewing agents found: the comments pi² posted for `work` `review`. */
	findings: { agentName: string; verdict: "approve" | "changes" | "comment"; at: number; url: string }[];
	/** The conversation that opened it through `work`, from `pi2.github`'s `openedBy`. */
	openedBy: { conversationId: number } | null;
	/** The work item it fixes, from "Fixes #N" in its text. */
	work: number | null;
};
```

`pull_request` opens one in the attached repository (`--repo`), with `--head` the branch the conversation's folder is on, written `owner:branch` when that branch's upstream is in another repository than the attached one (a fork), and `--base` the attached repository's default branch unless given. A branch with no upstream is refused: "Push the branch first: it has no upstream."

**Send back** posts the reason on the pull request, and gives it to the conversation that opened it (from `openedBy`) as an input of its own kind, `pi2.sentBack { by: Who, number, reason }`, which the model reads as "<The person | Orchestrator> sent back pull request #12: <reason>" and the page shows as such, not as a message the person typed. The orchestrator is told in its catch-up when the person sent it.

**The listing** (`github.json` in the data folder) is a cache, kept by project and repository (`{ "<projectId>": { "<owner>/<name>": { readAt, issues, pulls } } }`), so a listing never shows under another repository after one is changed. It holds the open issues and pull requests, and those closed in the last seven days. It is read at most once a minute per project, only while an app has said it shows that project's Work or Now tab (`projects.watch`, [4.2](#42-requests)) or an agent asks (`work` `list` or `show`), and at once after any write pi² makes. A `gh` that fails, is not signed in, or answers that the rate limit is reached leaves the last listing in place, with what went wrong (`state` in the `github` event: `ok`, `loading`, `signed_out`, `unreachable`, `rate_limited`, with `error` and `readAt`). An agent's `work` call then answers with the cached listing and says when it was read and why it is not newer.

### 3.12 The record of changes (`pi2.changes`)

Every change an agent makes through a tool, and every change the person allowed from a reach request, is recorded as a typed operation, so that it can be shown in the conversation with a line and, where it has one, undone exactly.

```ts
type ChangesDoc = { projects: Record<string, Change[]>; next: number };

type Change = {
	/** 1, 2, 3… across all projects. */
	id: number;
	at: number;
	by:
		| { kind: "agent"; agentId: string; conversationId: number; callId: string }
		| { kind: "allowed"; need: string; agentId: string; conversationId: number } // a reach request the person allowed
		| { kind: "person" }; // the person's Undo (changes.undo)
	op: Op;
	/** One line, as the conversation shows it: "Made the agent Reviewer (Claude Sonnet 4.6, Ask first)". */
	summary: string;
	/** Null: it has no Undo (5.9 says which, and why). */
	inverse: Op | null;
	undone?: { at: number; by: Who; change: number };
};

/** Each kind of operation: what it touches, all of it. None holds a secret: variables' values never appear here. */
type Op =
	| { kind: "agent.make"; agent: AgentProfile }                                  // inverse: agent.remove
	| { kind: "agent.change"; id: string; fields: Field[] }                         // inverse: agent.change with before and after swapped
	| { kind: "agent.remove"; id: string }                                          // sets removedAt; inverse: agent.restore
	| { kind: "agent.restore"; id: string }                                         // clears removedAt; inverse: agent.remove
	| { kind: "project.change"; fields: Field[] }                                   // settings, name; inverse: swapped
	| { kind: "rule.add"; rule: ProjectRule; at?: number }                          // at: its place; inverse: rule.remove
	| { kind: "rule.remove"; rule: ProjectRule; at: number }                        // inverse: rule.add at the same place
	| { kind: "rule.edit"; id: string; before: { text: string; binds: string }; after: { text: string; binds: string } }
	| { kind: "rule.move"; id: string; from: number; to: number }                   // inverse: move back
	| { kind: "note.add"; note: ProjectNote }                                       // inverse: note.remove
	| { kind: "note.remove"; note: ProjectNote }                                    // inverse: note.add, with the same id
	| { kind: "work.local"; id: number; action: WorkAction; before: Partial<WorkItem>; after: Partial<WorkItem> } // kept by pi²; inverse: before; {}: not there (filed)
	| { kind: "work.github"; intent: string; action: WorkAction | "pull_request" | "review" | "merge" | "send_back"; summary: string } // no inverse
	| { kind: "wake.choice"; submissions: number[]; before: (string | null)[]; after: string | (string | null)[]; batches?: { before: (string | null)[]; after: (string | null)[] } } // inverse: before, each run its own, and its batch
	| { kind: "orchestrator.set"; from: string; to: string };                       // no inverse (5.9)

type Field = { name: string; before: unknown; after: unknown };
```

- **One validator for each.** Each operation is applied by the same function that applies the person's own request for it (`agents.save`'s checks for `agent.change`, `projects.set`'s for `project.change`, and so on), so an operation cannot do what the person's request could not.
- **Undo** applies the inverse, after two checks: the target still exists and is still what the operation left it (each `Field`'s `after` still holds; the rule, note or agent is still there, or still removed; the work item is still in the state it was put in), and the inverse is still allowed (the project is not archived or deleted; an agent's undo is checked against [section 7](#7-reach-what-an-agent-can-only-ask-for): undoing the addition of a rule removes a rule, so an agent's undo of it becomes a request; the person's never does). If a check fails, nothing is done: "This was changed again since, so it was not undone. Change it by hand." An Undo is itself a change, recorded with its own inverse.
- **Removing an agent through a tool** sets `removedAt`; nothing is deleted, its variables' values stay in the Keychain, and `agent.restore` puts it back whole. Deleting for good, which also removes its values from the Keychain and its name from others' `delegates`, as `agents.delete` does today, is the person's alone.
- **In the conversation.** The tool call's result carries `details.change: id`, and the conversation's state has `projectChanges: [{ id, summary, undone, canUndo, noUndo }]` for the changes made in it (the last 100), so the page draws each line, with Undo where `canUndo`, and as undone once it is. A change with no inverse is drawn without Undo, saying why: `noUndo` is that reason ("on GitHub; it cannot be undone here"), null for a change that has an inverse. `canUndo` is false once the change is undone, and while its project is archived or deleted. A conversation in no project has no `projectChanges`. An export writes each as its summary, with "(undone)" when it was.
- Kept: the last 500 per project.

## 4. Requests and events

### 4.1 Conventions

As every request today ([architecture.md](architecture.md#how-they-talk)): `{ id, method, params }`, answered `{ id, result }` or `{ id, error, data? }`, where `error` is a plain message a person can act on. `data`, when present, is an object the caller can act on without parsing the message; the app's `EngineError` keeps it. The limit refusal carries `data.limit`. Carrying over (#458) uses the same `RequestError` envelope for its changed report. Every request in this section is meant to be the person's, made through the app, and none is checked against [section 7](#7-reach-what-an-agent-can-only-ask-for), which is for agents' tools. The engine takes answers to what waits for the person, including a `confirmLimit` retry, only from the app, and the requests of this section that change what the person set only from the app too ([7.3](#73-who-answered)); the rest are reading and runs, as before.

**With the preview off**, every request that exists today works exactly as today, for templates and project agents alike, with or without the fields this page adds to it. Only the requests new in this epic are refused, but `projects.list`, `projects.setPreview` and `projects.carryOver` with `dryRun`; and an existing request is refused only for a parameter that is new and names a project (`memory.add { projectId }`, `conversation.create { confirmLimit }`), with the same message as in [section 2](#2-the-preview-switch).

Errors every new request can give, besides its own:

| When | Error |
|---|---|
| The project does not exist, or was deleted | "Unknown project: <id>" |
| The agent does not exist, is removed, or is in another project | "Unknown agent: <id>" (or "<name> is not an agent of this project") |
| A field has the wrong type | "<field> must be <what>", as today's requests say it |
| The project is archived and the request would change it or start something in it | "This project is archived. Restore it first." |

### 4.2 Requests

**Projects** (#456; `setPreview`'s carrying over #458; `startFresh`, `setOrchestrator` #466):

| Request | Answers | Does, and refuses |
|---|---|---|
| `projects.list {}` | `{ preview, projects, carryOver }` | Exactly the `projects` event's content, for a script that does not read events |
| `projects.setPreview { on, plan? }` | `{ preview, carryOver }` | Turns the preview off, or on. On, when carrying over has something to do, it needs `plan`, the `plan` of the report the person was shown ([9.8](#98-the-report-and-the-run)), runs it, and answers its report; when the plan has changed since, it turns nothing on and answers the new report with the error "What would be carried over has changed since you looked. Look at it again." Off: `carryOver` is null |
| `projects.create { folder, name?, template? }` | `{ id, conversation }` | A project from a folder in one step, with its orchestrator and an empty conversation with it. `folder` a folder's path, or null; `name` defaults to the folder's last part ("No folder" for null), with " 2", " 3"… when taken; `template` the id of a template to copy as its orchestrator, else the default orchestrator. Refuses "Not a folder: …" and, for a folder, "There is already a project for this folder: <name>" (an archived one: "…; restore it instead") |
| `projects.rename { id, name }` | `{}` | Refuses an empty name, one over 80 characters, or one taken |
| `projects.set { id, folder?, settings? }` | `{ settings }` | Changes the folder (checked as in create; new conversations of its agents start there, those working stay where they are) and any part of the settings ([section 8](#8-settings-without-asking-waking-limits)), each checked; parts not given are kept |
| `projects.setOrchestrator { id, agentId }` | `{ conversation }` | Makes another agent of the project its orchestrator and starts a fresh conversation with it, in one commit ([6.5](#65-start-fresh)) |
| `projects.startFresh { id }` | `{ conversation }` | [6.5](#65-start-fresh) |
| `projects.archive { id }`, `projects.unarchive { id }`, `projects.delete { id }` | `{}` | [3.6](#36-archiving-and-deleting) |
| `projects.carryOver { dryRun?, plan? }` | the report ([9.8](#98-the-report-and-the-run)) | With `dryRun: true`, changes nothing, and is allowed with the preview off. Without, the preview must be on, and it runs `plan` as `setPreview` does: to bring in what is new since |
| `projects.retrySecrets {}` | `{ secrets }` | Tries again to copy the variables' values still pending ([9.5](#95-agents-copies-adoption-and-secrets)), and answers what is still pending |
| `projects.watch { projectId, tabs }` | `{}` | This app shows these tabs of this project now (`"now"`, `"work"`): the engine reads GitHub for them ([3.11](#311-work-pi2work-pi2github-githubjson)). `projectId: null` or an empty `tabs` says it shows none. Per connection, and forgotten when the app disconnects |

**Agents and templates** (#457):

| Request | Answers | Does, and refuses |
|---|---|---|
| `projects.addAgent { projectId, template?, agent? }` | `{ id }` | Makes an agent of the project: a copy of `template`, or from `agent` (the fields `agents.save` takes). Same checks as `agents.save` |
| `agents.save { agent }` | `{ id }` | As today, for templates and project agents alike. Keeps `projectId`, `role`, `template`, `madeBy` and `removedAt` as stored, whatever it is sent; refuses a `cwd` other than the project's for a project agent |
| `agents.duplicate { id }` | `{ id }` | As today; a project agent's copy is in the same project, never the orchestrator |
| `agents.delete { id }` | `{}` | As today, which removes its variables' values and its name from others' `delegates`; refuses the orchestrator: "<name> is the project's orchestrator. Make another agent the orchestrator first." |
| `agents.restore { id }` | `{}` | Puts back a project agent removed through a tool |
| `agents.updateFromTemplate { id, apply }` | `{ changes: [{ setting, now, template }], applied }` | [3.3](#33-agents-and-templates-pi2agents). With `apply: false`, changes nothing |
| `conversation.create { agentId, confirmLimit? }` | `{ id }` | As today. With a project agent, a start in that project, checked as [8.3](#83-limits-and-the-one-admission-check) says |

**Rules** (#459). Under `projects.rules`, since `rules.add` and `rules.remove` are the allowed commands':

| Request | Answers | Does |
|---|---|---|
| `projects.rules.add { projectId, text, binds }` | `{ id }` | Adds a rule at the end |
| `projects.rules.edit { projectId, id, text?, binds? }` | `{}` | Changes its text or whom it binds |
| `projects.rules.move { projectId, id, to }` | `{}` | Moves it to place `to`, counted from 0 |
| `projects.rules.remove { projectId, id }` | `{}` | Removes it |

**Notes** (#461): `memory.add`, `memory.edit` and `memory.delete` take `projectId` in place of `agentId` or `chat: true`, for a project's notes, with the same limits; `memory.edit` takes `audience` (null, or an agent of the project) as well. `memory.setEnabled { agentId }` is unchanged and is how a project agent's switch is set.

**Needs you** (#462):

| Request | Answers | Does |
|---|---|---|
| `needs.list { projectId? }` | `{ items }` | The `needs` event's items, of one project or all |
| `needs.answer { id, answer }` | `{}` | Answers an item of any kind with a `NeedAnswer` ([3.9](#39-needs-you-pi2needs-and-the-inbox)), through `claim`. `inbox.decide` and `inbox.answer` keep working for approvals and `ask_user` questions, through the same `claim` |

**Reports** (#463):

| Request | Answers | Does |
|---|---|---|
| `reports.wake { projectId, chats, when }` | `{}` | The person's choice of waking for sub-chats' runs going now, as `reports` `wake` is the orchestrator's ([5.6](#56-reports-the-orchestrator)) |

**Work** (#467 the dispatcher and the list kept by pi²; #468 the GitHub backend and the pull-request requests):

| Request | Answers | Does |
|---|---|---|
| `work.list { projectId, states? }` | `{ items, readAt }` | The list; for GitHub, the cached listing, read again if older than a minute; `readAt` null for a list kept by pi² |
| `work.create { projectId, title, text?, class? }` | `{ id }` | `file` |
| `work.act { projectId, id, action, text?, title?, class?, agentId?, task?, as?, confirmLimit? }` | `{ item, conversation? }` | Any other row of the table in [3.11](#311-work-pi2work-pi2github-githubjson) the person may do: `assign` (with `agentId`, and `task` beyond the work's own text; answers the sub-chat started), `release`, `resume`, `close` (with `as`), `reopen`, `note`, `edit`, `classify`. `assign` is a start, checked as [8.3](#83-limits-and-the-one-admission-check) says |
| `github.attach { projectId, repository? }` | `{ repository }` | Attaches `owner/name`, or by default the repository the folder's `origin` remote names. Refuses a project with no folder, a repository `gh` cannot see ("gh cannot reach owner/name: …"), and a project whose list kept by pi² has open items ("Close or move this project's open work first: …") |
| `github.detach { projectId }` | `{}` | Back to the list kept by pi², which is as it was left |
| `github.refresh { projectId }` | `{}` | Reads again now, within the once-a-minute limit |
| `github.merge { projectId, number }` | `{}` | Merges with `gh pr merge --merge --repo …`; refuses one that cannot be merged, with GitHub's reason |
| `github.sendBack { projectId, number, reason }` | `{}` | [3.11](#311-work-pi2work-pi2github-githubjson) |
| `github.diff { projectId, number }` | `{ diff }` | As `gh pr diff --repo …` gives it, cut at 2 MB with a line saying so |
| `github.settle { projectId, intent, happened }` | `{}` | The person says whether a write whose outcome pi² could not tell happened (`true`) or not (`false`) |

**Changes** (#465):

| Request | Answers | Does |
|---|---|---|
| `changes.list { projectId, before?, limit? }` | `{ changes }` | Newest first, 50 by default |
| `changes.undo { id }` | `{}` | [3.12](#312-the-record-of-changes-pi2changes) |

### 4.3 Events

New events, each sent whole when what it holds changes, and to each app as it connects:

```ts
{ event: "projects"; preview: boolean; projects: ProjectRow[]; carryOver: CarryOverState | null }

type ProjectRow = Project & {
	folderMissing: boolean;
	/** About how many tokens the rules add to each request: an orchestrator's, and every other agent's (6.2). Zeros until #459. */
	ruleTokens: { orchestrator: number; agents: number };
	/** The last line of the orchestrator's last finished answer, at most 200 characters, and when: the Dashboard's and the folded strip's. */
	lastWords: { text: string; at: number } | null;
};

type CarryOverState = { ranAt: number | null; backup: string | null; secretsPending: { copy: string; name: string; project: string; variables: string[]; error: string | null }[] };

{ event: "needs"; items: NeedItem[] }                                  // every project's, and those of no project
{ event: "projectRules"; projects: Record<string, ProjectRule[]> }
{ event: "reports"; projects: Record<string, Report[]> }               // undelivered, and the last seven days'
{ event: "work"; projects: Record<string, WorkItem[]> }                // lists kept by pi²
{ event: "github"; projects: Record<string, { state: "ok" | "loading" | "signed_out" | "unreachable" | "rate_limited"; error: string | null; readAt: number | null; repository: { owner: string; name: string }; issues: WorkItem[]; pulls: PullRequest[]; unknown: { intent: string; summary: string; at: number }[] }> }
```

With the preview off, or on with nothing made yet, an app is sent exactly:

```json
{ "event": "projects", "preview": false, "projects": [], "carryOver": null }
{ "event": "projectRules", "projects": {} }
{ "event": "needs", "items": [] }
{ "event": "reports", "projects": {} }
{ "event": "work", "projects": {} }
{ "event": "github", "projects": {} }
```

and, after the preview was on and off again, the same events with what was made in them, and `preview: false`.

Fields added to events that exist:

| Event | Added | Owner |
|---|---|---|
| `library` | each conversation's `projectId` (or null), `runsAs` (the agent id it runs as now), `orchestrator: "current" \| "earlier" \| null`; each archived row's `projectId` | #456 (`projectId`), #457 (`runsAs`), #466 (`orchestrator`) |
| `agents` | each agent's `projectId`, `role`, `template`, `madeBy`, `updatedAt`, `removedAt` (as stored; absent when not set) | #456, #457 |
| `memory` | `projects: Record<projectId, { notes: ProjectNote[] }>` | #461 |
| `activity` | each run's `projectId`, `runsAs`, and `lastLine`: the last line of text its agent wrote, at most 140 characters, or null | #456 (`projectId`), #457 (`runsAs`), #466 (`lastLine`) |
| `wakes` | each item's `projectId`, `wake` and `batch` | #463 |
| `usage` | `projects: [{ id, today: { cost, tokens } }]`, today's spending by project | #464 |
| `inbox` | each item's `projectSwitch`, when set; nothing else: it stays as it is for the old screens | #462 |
| conversation state | `projectChanges` ([3.12](#312-the-record-of-changes-pi2changes)); `project: { id, orchestrator: "current" \| "earlier" \| null }` or null | #465, #466 |

How often: `projects`, `projectRules`, `work` and `github` change at the pace of the person and the orchestrator, and are sent at once; `lastWords` changes once per finished answer, not as one is written. `needs` is sent at once, as the Inbox is, since an item answered must leave the list before it could be answered again. `reports` is sent at once (a few a minute at most). `activity` stays coalesced as today, so its `lastLine` is at most a quarter of a second late. None is sent for a change that changes nothing in it.

### 4.4 What an app is sent on connecting

After today's events (`library`, `agents`, `inbox`, `activity`, `schedules`, `recovery`, `usage`, `mcp`, `chat`, `compactionSettings`), each feature's greeting, in the order of `FEATURES`. The projects' features are listed together there, so their events come in this order: `projects`, `projectRules`, `needs`, `reports`, `work`, `github` (#456 places the `projects` feature and leaves the places for the others; each issue adds its own feature in its place). They are sent whether the preview is on or not, so that turning it on shows everything at once.

## 5. Tools for agents

### 5.1 Who is offered what

With the preview on, a conversation is in a project when its `projectId` is set and the project is neither archived nor deleted. Outside a project, and with the preview off, nothing in this section is offered and every existing tool, with its definition and description, is exactly as today.

There are three kinds of conversation in a project:

- **the orchestrator's**: its current conversation;
- **an agent's own**: any other top-level conversation of a project agent, the orchestrator agent's included;
- **a sub-chat**: a sub-chat of either.

| Tool | The orchestrator's | An agent's own | A sub-chat |
|---|---|---|---|
| `project_agents` | Yes | No | No |
| `project_settings` | Yes | No | No |
| `project_rules` | Yes | No | No |
| `reports` | Yes | No | No |
| `needs_you` | Yes | Yes | **Proposed (#507, not agreed):** Yes, for a question or decision; `ask_user` for what cannot wait ([5.5](#55-needs_you-the-orchestrators-and-agents-own-conversations)) |
| `work` | Yes | Yes | Yes |
| `remember`, `forget` | With memory on: the project's notes | The same | The same |
| `delegate`, `sub_chats` | To every other agent of the project | To the agents its `delegates` name | Not offered, as today |
| Every other tool | As its settings say | As its settings say | As its settings say |

Which actions each may use, and what an agent's access level allows. "Writes" means the action changes the work list, kept by pi² or on GitHub; reading changes nothing:

| Action | The orchestrator's | An agent's own | A sub-chat | Access needed |
|---|---|---|---|---|
| `work` `list`, `show` | Yes | Yes | Yes | Any, Tools off included |
| `work` `take`, `release`, `wait`, `block`, `resume`, `finish`, `note`, `file` | Yes | Yes | Yes | Ask first or Full access |
| `work` `pull_request`, `review` (GitHub) | Yes | Yes | Yes | Ask first or Full access |
| `work` `assign`, `close`, `reopen`, `edit`, `classify`, `merge`, `send_back` | Yes | No | No | Ask first or Full access |
| `needs_you` `ask`, `withdraw`, `list` | Yes | Yes | — | Any |
| `reports` `list`, `read`, `wake` | Yes | — | — | Any |
| `project_agents` `list`, `templates`; `project_settings` `show`; `project_rules` `list` | Yes | — | — | Any |
| Every other action of `project_agents`, `project_settings`, `project_rules` | Yes | — | — | Ask first or Full access |
| `remember`, `forget` | With memory on | With memory on | With memory on | Any, as today |

An action a conversation may not use is refused with what it may do instead ("Only the orchestrator assigns work. Tell it in your report."; "This agent's access does not let it change the work list."). Under the access needed, the switches of [8.1](#81-what-the-orchestrator-may-do-without-asking) still decide whether it asks, and [section 7](#7-reach-what-an-agent-can-only-ask-for) whether it can only ask.

None of the new tools is in the list of [built-in tools](architecture.md#built-in-tools) that an agent's settings can leave out: each is offered by being in a project, and is sent to no other conversation. An earlier conversation with the orchestrator, which takes no messages, is offered nothing new.

No tool here asks for approval under Ask first, except where a switch of [8.1](#81-what-the-orchestrator-may-do-without-asking) that is off makes it ask. Each is safe to run again after a crash: a call run again finds what it already did, by its call id, as `remember` does; a write to GitHub goes through an intent ([3.11](#311-work-pi2work-pi2github-githubjson)).

Each tool's answer below is the text the model is given. A refusal is a result with `isError`, in a sentence that says what to do instead.

### 5.2 `project_agents` (the orchestrator)

```ts
project_agents {
	action: "list" | "templates" | "make" | "change" | "remove" | "restore" | "update_from_template";
	agent?: string;        // name of an agent of the project: change, remove, restore, update_from_template
	template?: string;     // name of a template: make (a copy)
	settings?: {           // make and change: any of these, others kept
		name?: string; description?: string; instructions?: string;
		model?: string;    // "provider/model id", as the model menu names it
		thinking?: string; access?: "none" | "read" | "ask" | "full";
		worktree?: boolean; setup?: string; turn_limit?: number | null; summarise_at?: number | null;
		memory?: boolean; code_mode?: boolean;
		delegates?: string[];   // names
		built_in_tools?: { on?: string[]; off?: string[] };   // keys of builtInTools: files, documents, ask, plan, web, pictures, compact, code
		computer?: { enabled?: boolean; apps?: string[]; ask?: boolean; test_copies?: boolean };
		browser?: { enabled?: boolean; ask?: boolean };
		mcp_servers?: string[]; reference_files?: string[]; schedule?: boolean;
		allowed_commands?: { add?: string[]; remove?: string[] };   // words, in the project's folder
		allow_everything?: boolean;
	};
	apply?: boolean;       // update_from_template: false (the default) only says what would change
	why?: string;          // for a change that widens reach: shown to the person on the request
}
```

- `list`: each agent of the project with its model, access, whether it is working, and its description, one line each; removed ones last, marked. `templates`: each template's name and description.
- `make`, `change`, `remove`, `restore`, `update_from_template`: made at once when the project's `makeAgents` switch is on, as a change with a line and Undo ("Made the agent Reviewer, a copy of the template Forge (Claude Sonnet 4.6, Ask first). The person can undo it."). With the switch off, the call asks the person first as an approval. Every setting is classed by [7.1](#71-every-setting-classed): one that widens reach is never made by the tool; it is left as it was (for a new agent, at the baseline of [7.2](#72-asking-allowing-refusing)) and asked for, and the answer says so: "Made Reviewer with access Ask first. Full access widens what it may do, so the person was asked for it (under Needs you); you will be told their answer."
- `remove` sets `removedAt` ([3.3](#33-agents-and-templates-pi2agents)); it refuses the orchestrator, and an agent that is working ("Forge is working on sub-chat 14. Wait for it, or ask the person to stop it.").
- Variables, sign-ins, the agent's colour and the templates themselves cannot be changed with it.

### 5.3 `project_settings` (the orchestrator)

```ts
project_settings {
	action: "show" | "change" | "set_orchestrator" | "undo";
	changes?: {
		name?: string; folder?: string | null; repository?: string | null;   // "owner/name"
		without_asking?: Partial<Record<"start_agents" | "file_work" | "close_work" | "make_agents" | "add_rules" | "merge" | "release" | "pass_limits", boolean>>;
		limits?: { plan_share?: number | null; daily_spend?: number | null };
	};
	agent?: string;    // set_orchestrator: the agent of the project to become the orchestrator
	change?: number;   // undo: the id of a change, from a result's last line
	why?: string;
}
```

- `show`: the project's name, folder, work list, the switches, waking, the limits and how they stand now (today's spending, the plan windows of the models its agents run on), each on a line.
- `change`: each part made at once, as one change with Undo, unless it widens reach ([7.1](#71-every-setting-classed)); those parts are asked for, and the answer says which were made and which asked.
- Waking for the whole project (`wakeOnReports`) is not here: it is the person's switch ([8.2](#82-when-a-report-wakes-the-orchestrator)). The orchestrator chooses waking for its own hand-offs with `reports`.
- `set_orchestrator`: always a request; when the person allows it, the engine makes the change and the fresh conversation in one commit ([6.5](#65-start-fresh)).
- `undo`: undoes a change of this project's recorded in [3.12](#312-the-record-of-changes-pi2changes), as `changes.undo` does, except that an undo that would widen reach is asked for.

Every change's result ends with "(change 31)", the id `undo` takes.

### 5.4 `project_rules` (the orchestrator)

```ts
project_rules {
	action: "list" | "add" | "propose" | "edit" | "move" | "remove";
	rule?: string;                         // the rule's id, "r3": edit, move, remove
	text?: string;                         // add, propose, edit
	binds?: "orchestrator" | "everyone";   // add, propose, edit; default "everyone"
	to?: number;                           // move: the place, from 1
	why?: string;
}
```

- `list`: each rule with its id, whom it binds, and who added it.
- `add`: with the project's `addRules` switch on, the rule is added at once, and the line with Undo in the conversation shows the person what was added. With it off, it becomes a proposal. Its description says: "For a rule the person has told you to keep. To suggest one yourself, use propose." The engine does not check that the person said it; the line, in front of the person, is the check ([14](#14-questions-for-the-owner), question 4).
- `propose`: under Needs you as a proposed rule, which the person accepts, edits or refuses; the orchestrator is told which.
- `edit`: making a rule bind everyone where it bound the orchestrator is made at once, with Undo. Any change to its text, or making it bind only the orchestrator, is a request: the engine cannot tell whether new words ask less.
- `remove`: always a request.
- `move`: made at once, with Undo. Order decides nothing but the order shown.

Other agents of the project have no rules tool: only the orchestrator talks with the person about the project.

### 5.5 `needs_you` (the orchestrator's and agents' own conversations)

```ts
needs_you {
	action: "ask" | "withdraw" | "list";
	question?: string;      // ask: up to 2,000 characters
	choices?: string[];     // ask: 2 to 6 buttons, 60 characters each; without them, an answer in words
	words?: boolean;        // ask with choices: whether an answer in words is allowed too; default true
	id?: string;            // withdraw: the item's id
}
```

- `ask` puts a question (or, with `choices`, a decision) under Needs you and returns at once: "Put to the person as n12. Carry on with what does not depend on it; their answer will come to you as a message." The answer wakes the conversation ([3.9](#39-needs-you-pi2needs-and-the-inbox)).
- `withdraw` takes back one of this conversation's items that is still waiting. `list` gives this conversation's items still waiting.
- **Proposed (#507, not agreed):** A sub-chat is offered it too, for a question or a decision. While its run is going, the answer wakes the sub-chat; once the run has ended, the answer goes to the conversation that handed it the work, with whose question it was and how to continue the sub-chat ([3.9](#39-needs-you-pi2needs-and-the-inbox)). `ask_user` stays for what cannot wait: a question whose answer the worker's next step needs, with no other work to do meanwhile. A reach request, a proposed rule or an approval is still not a sub-chat's to put ([5.1](#51-who-is-offered-what)).
- **A sub-chat is not offered it** (as agreed until the proposal above is): a sub-chat is not woken ([wakes.md](wakes.md#what-wakes-an-agent)), so an answer could not reach it once it has stopped. It uses `ask_user`, which shows under Needs you as a question and holds it until answered. This is a known gap against the design, which says an agent asks without stopping ([14](#14-questions-for-the-owner), question 8).

### 5.6 `reports` (the orchestrator)

```ts
reports {
	action: "list" | "read" | "wake";
	chats?: number[];       // read: these sub-chats' undelivered reports (default: every one); wake: these sub-chats' runs going now
	when?: "each" | "all" | "failure" | "never";   // wake
}
```

- `list`: the reports not yet delivered, then the sub-chats' runs going now, with how each will wake it.
- `read`: each report as `delegate` would have given it (the answer of that run, which sub-chat, how to continue it, the `Used:` line), delivered by `read` ([3.10](#310-reports-and-waking-pi2reports-pi2wakes)).
- `wake`: sets when these runs' reports wake it; with several chats and `all` or `failure`, they become one batch. Answers what was set: "Sub-chats 14, 15 and 16 are one batch: you will be woken once, when all three have ended." A change with a line and Undo.

This tool, and not new parameters of `delegate`, carries the choice of waking: `delegate`'s definition is sent to every conversation that can hand work on, and outside a project nothing an agent is told may change ([13](#13-decisions-this-contract-made), decision 13). `delegate` with `wait: false` in the orchestrator's conversation says in its result how the report will come: "Its report waits for you unread; you are not woken for it (the project's setting). To be woken, use reports with action wake."

### 5.7 `work` (every agent of a project)

```ts
work {
	action: "list" | "show" | "take" | "release" | "note" | "wait" | "block" | "resume" | "finish" | "file"
		| "pull_request" | "review"                                                        // GitHub only
		| "assign" | "close" | "reopen" | "edit" | "classify" | "merge" | "send_back";   // the orchestrator only
	id?: number;            // a work item (an issue's number), or a pull request's for review, merge, send_back
	text?: string;          // note, wait and block (why), finish (the result), file and edit (the text), review (the finding), send_back (the reason)
	title?: string;         // file, edit, pull_request, assign (the sub-chat's title)
	states?: string[];      // list: only items in these states; default every open one
	class?: "local" | "cloud";   // file, classify
	agent?: string;         // assign
	task?: string;          // assign: what to say beyond the work's own text
	base?: string;          // pull_request: default the repository's default branch
	verdict?: "approve" | "changes" | "comment";  // review
	as?: "done" | "dropped";                      // close
}
```

Each action is a row of the table in [3.11](#311-work-pi2work-pi2github-githubjson), with the same result and error shapes for both kinds of list. Besides:

- `list`, `show`: the items, or one with its text, notes and result; for GitHub, with when the listing was read.
- `pull_request` (GitHub): opens one from the branch this conversation's folder is on, in the attached repository; with `id`, adds "Fixes #<id>" to the text unless it is there. Answers its number and address.
- `review` (GitHub): posts the finding on the pull request, as a comment beginning with the agent's line and the verdict.
- `assign` answers as `delegate` with `wait: false` does. `merge` merges under the `merge` switch. `send_back` as [3.11](#311-work-pi2work-pi2github-githubjson) says.

Outside GitHub, `pull_request`, `review`, `merge` and `send_back` are refused: "This project's work is kept by pi², which has no pull requests."

The `project` section ([6.1](#61-the-sections)) tells every agent of the project to keep the work list with this tool and not with scripts or `gh` of its own, so that no instructions are needed to teach it the tracker.

### 5.8 What existing tools say differently in a project

Only in a project, with the preview on:

- `delegate` names only agents of the project; a new sub-chat, or a continued one, is a start, which passes the admission check ([8.3](#83-limits-and-the-one-admission-check)) and asks first when `startAgents` is off. With `wait: false` its result says how the report will come ([5.6](#56-reports-the-orchestrator)).
- `sub_chats`, in the orchestrator's conversation, lists the sub-chats of its earlier conversations too, still working or not archived, and `delegate` with `chat` continues one of them: Start fresh loses no sub-chat ([6.5](#65-start-fresh)). Each line says whether its last report has been delivered.
- `remember` and `forget` write the project's notes ([3.8](#38-notes-pi2memory)), each a change with a line and Undo.
- **Proposed (#507, not agreed):** `ask_user`, in a sub-chat of a project, is told apart from `needs_you` in the `project` section: what does not stop the worker goes under Needs you with `needs_you`, and `ask_user` is for the question whose answer its next step needs, with no other work to do meanwhile. The tool's own definition and description change nowhere.

With the preview off, a conversation of a project agent is offered what its agent's settings say, as any conversation is, and `delegate` hands work to the agents its `delegates` name, as today; its starts still pass the project's admission check ([section 2](#2-the-preview-switch)).

### 5.9 Every change in the hub: its tool, whether it asks, and its Undo

The owner's word: whatever the person can do by hand in the hub, the orchestrator has a tool for, and each change it makes shows as a line with Undo. This table is every change the hub offers. "Asks" says when the tool asks first or can only ask: a switch ([8.1](#81-what-the-orchestrator-may-do-without-asking)) or reach ([section 7](#7-reach-what-an-agent-can-only-ask-for)).

| Change in the hub | Tool action | Asks | Undo (the inverse) |
|---|---|---|---|
| Make an agent, by hand or from a template | `project_agents` `make` | `makeAgents` off; settings that widen reach | Remove it |
| Change an agent's settings | `project_agents` `change` | `makeAgents` off; settings that widen reach | Put the settings back |
| Remove an agent | `project_agents` `remove` | `makeAgents` off | Restore it |
| Update an agent from its template | `project_agents` `update_from_template` | `makeAgents` off; settings that widen reach | Put the settings back |
| Rename the project | `project_settings` `change` | No | Rename back |
| Change the folder, attach or change the repository | `project_settings` `change` | Always: reach | Put back (a person's Undo; an agent's undo is again a request) |
| Turn a switch off, lower a limit | `project_settings` `change` | No | Put back (an agent's undo widens reach: a request) |
| Turn a switch on, raise or remove a limit | `project_settings` `change` | Always: reach | Put back |
| Make another agent the orchestrator | `project_settings` `set_orchestrator` | Always | **None**: it starts a fresh conversation; going back is another change of orchestrator |
| Add a rule | `project_rules` `add` | `addRules` off: becomes a proposal | Remove it (an agent's undo: a request) |
| Edit, remove a rule | `project_rules` `edit`, `remove` | As 5.4 | Put it back |
| Move a rule | `project_rules` `move` | No | Move it back |
| Add, remove a note | `remember`, `forget` | No | Remove it, put it back |
| Share a carried-over note with the project | — | The person's alone | Set its audience back |
| File, take, release, note, change the state of, edit, classify, assign, close, reopen work (kept by pi²) | `work` | `fileWork`, `closeWork`, `startAgents` off | Put the item back as it was; for `assign`, the sub-chat started is not stopped |
| The same on GitHub; open, review, merge, send back a pull request | `work` | `fileWork`, `closeWork`, `startAgents`, `merge` off | **None**: done on GitHub, where the person can see and reverse it |
| Choose waking for runs going now | `reports` `wake` | No | Put the choice back |
| Turn waking on reports on or off for the project | — | The person's alone ([8.2](#82-when-a-report-wakes-the-orchestrator)) | — |
| Start fresh | — | The person's alone | **None**: the earlier conversation stays readable |
| Archive, restore, delete the project | — | The person's alone | **None** by Undo; restore is its own action |
| Answer what is under Needs you | — | The person's alone | **None** |
| Turn the preview on or off, carry over | — | The person's alone | **None** by Undo ([9.11](#911-switching-the-preview-off)) |
| Edit or delete a template; an agent's variables; Allow everything's own confirmation | — | The person's alone | — |

The exceptions, each with no tool or no Undo, are question 6 in [section 14](#14-questions-for-the-owner).

## 6. Prompt sections, and what the orchestrator is told

### 6.1 The sections

Two new sections, and one changed, in this order among [the existing ones](architecture.md#the-list-of-prompt-sections): after `task_list`, before `project_instructions`. They come from features in files of their own (`projects.ts` for `project`, `projectrules.ts` for `project_rules`), listed in `FEATURES` just after `plan`, so they keep their place with nothing more ([architecture.md](architecture.md#the-system-prompts-sections)).

| Section | From | Has something to say when | Steady, or comes and goes |
|---|---|---|---|
| `project` | `projects.ts` | the conversation is in a project and the preview is on | Changes in place when the project's name, folder, repository, settings or orchestrator change; comes and goes with the preview |
| `project_rules` | `projectrules.ts` | the conversation is in a project, the preview is on, and some rule binds its agent | Changes in place when a rule binding its agent is added, edited, moved or removed |
| `memory` (changed) | `knowledge.ts` | as today; for a project agent with the preview on, the project's notes it is given | As today |

**Outside a project nothing changes, byte for byte**, with the preview on or off: a section with nothing to say is not sent at all ([architecture.md](architecture.md#the-system-prompts-sections)), so the two new sections cost a conversation outside a project nothing; tools, their definitions and their order are as today; and the instructions the summariser is given (`RETENTION_INSTRUCTIONS`, which `main.ts` gives every conversation) are not changed at all ([13](#13-decisions-this-contract-made), decision 15). `engine/test/sections.ts` checks it, with the demo model's `/system history`, for a conversation outside a project with the preview on.

**A conversation that joins a project** (by carrying over, with the preview turned on) was started without places for the new sections, so the first time one of them has something to say, its whole prompt is sent once more, as for any section a conversation was started without ([architecture.md](architecture.md#the-system-prompts-sections)); from then on each keeps its place. That happens once, to conversations in a project only. A conversation made in a project has the places from its first request.

Both new sections are worked out from documents only, never from the time, counts that move, or who is working, so a section's text changes only when what it holds changes, and each change is sent alone, as that one section.

They also survive summaries: after a summary, pi durable writes the whole system prompt again with every section as it is then, and leaves out the sections' earlier changes (`findBaseline` in pi durable's `harness/context.js`). So a rule is word for word in front of the model at every request, whatever has been summarised.

**`project`, for the orchestrator's conversation** (its text, with the parts in angle brackets filled in):

```
You are the orchestrator of the pi² project “<name>”, in <folder>. The person talks to you here; this is the project's one conversation with you.
Its work list is <kept by pi² | the issues and pull requests of github.com/<owner>/<name>>. Keep it with the work tool, not with scripts or gh of your own.
Change the project with project_agents, project_settings and project_rules; each change shows here with Undo for the person. A change that lets agents do more is never made by a tool: it is put to the person, who allows or refuses it.
You may, without asking: <start agents, file work, …>. You ask first to: <merge, …>. <“Release” is the person's policy: pi² cannot check it, so keep to it yourself.>
Limits: <no new agent starts while a plan window it would run on is 90% used or more; none>, <and none once the project has spent $20 today; none>. Past a limit a start is refused with the reason, and reports do not wake you.
A report from an agent <does not wake you; it waits until you read it with reports | wakes you>. Choose otherwise for particular hand-offs with reports.
When something happens in the project while you are not answering, pi² tells you at the start of your next turn.
Put a decision that is the person's to them with needs_you and carry on; do not stop to wait for it.
```

**`project`, for every other conversation of the project:**

```
You are <name>, an agent of the pi² project “<project name>”, in <folder>. <Orchestrator name> is its orchestrator. <In a sub-chat: It handed you this work, and your answer is your report to it.>
The project's work list is <…>. Keep it with the work tool: take what you work on, note progress, and finish it with what was done.
```

The same text goes to every conversation of that agent of the same kind, so it changes only with the project.

**`project_rules`** (only the rules that bind this agent; for the orchestrator, both groups, each only when it has rules):

```
The person's rules for this project. Keep every one at every turn. Their order is only the order they are shown in; none outranks another. If two seem to conflict, or the person asks for something a rule forbids, say so and ask them.
For you, the orchestrator:
1. Never merge a pull request without a review by another agent.
For every agent:
2. Run the engine's tests before every commit.
```

Numbers follow the board's order over all the rules, so a rule has the same number for every agent and on the board.

**`memory`, for a project agent:** as today's ([knowledge.md](knowledge.md#memory)), with "the project's notes, kept by its agents" in place of "your own notes from earlier conversations", each note's id (`n7`), and the notes kept for this agent alone marked so.

### 6.2 What the rules cost

`ruleTokens` in the `projects` event is about how many tokens the rules add to each request: the `project_rules` section's text as an orchestrator is given it, and as every other agent is, each counted as its characters divided by four, rounded up. The board says "about", and says it is read again at every request of every agent it binds. It is an estimate made without a provider, the same for every model; a provider's own count differs by a little.

### 6.3 Why the project's state is not a section

The design asks that the conversation can be summarised hard or started afresh with nothing lost, because the project's state lives outside it; #466 proposed a section holding that state (open work, who is working, what waits for the person, reports not read).

A section that changes is sent again whole, as a system message in the conversation, and stays in the context until the next summary ([architecture.md](architecture.md#the-system-prompts-sections)). Who is working and what waits for the person change at almost every turn of a busy orchestrator: a section of some 500 tokens sent again at most turns would add those tokens to every later request until a summary, and makes a summary come sooner. So the state reaches the orchestrator in two ways instead, each given once:

- **at the start of a context**: a **state block**, in the first input of a new conversation with the orchestrator, and in what pi² adds to every summary of it ([compaction.md](compaction.md#what-stays));
- **between**: a **catch-up** in front of each input that starts a turn, with only what changed since.

Both are in the transcript, after the cached prompt, so nothing before them is sent again ([13](#13-decisions-this-contract-made), decision 14).

### 6.4 The catch-up and the state block

**News.** What happens in a project that the orchestrator was not part of is added to its project's `news` ([3.2](#32-the-project-pi2projects)) as it happens, each with an id of its own:

| News | Line |
|---|---|
| A report not delivered when its run ended | "Sub-chat 14 “Fix login” (Forge) answered at 14:02; not read yet." |
| The person wrote to another agent (`keep`) | "The person wrote to Forge in sub-chat 14: “Use the new endpoint instead.”" (the first 300 characters, and where to read the rest) |
| The person changed the project, an agent or a rule by hand | "The person added a rule: 3. “…”"; "The person set Scout's model to …" |
| Another agent or the person filed, finished or closed work | "Scout filed #31 “…”."; "Forge finished #28." |
| The person answered a limit card | "The person started Forge on “…” past the daily limit." |
| Something came under Needs you from another agent | "Forge's sub-chat 14 asks the person: “…”" |
| **Proposed (#507, not agreed):** the person answered a worker's question, the answer gone to the worker itself | "The person answered Forge's question in sub-chat 14: “…”" |

The orchestrator's own doings are not news to it, and nor is what a wake already gives it.

**The catch-up** is an entry of its own kind, `pi2.catchUp { news: News[] }`, committed in the same commit as the input it goes in front of and read by the model just before it, as one text:

```
[pi² — what changed in the project since your last turn]
- Sub-chat 14 “Fix login” (Forge) answered at 14:02; not read yet.
- The person wrote to Forge in sub-chat 14: “Use the new endpoint instead.”
```

- **When.** When an input is placed in the orchestrator's current conversation: the person's message that starts a turn, a wake, a queued message placed, or a steer placed in the middle of a turn. Each takes the news there is at that moment.
- **What is cleared.** Exactly the news whose ids the entry holds, in the same commit; news that comes meanwhile waits for the next.
- **Room.** At most 4,000 characters. When there is more, every `keep` piece goes in, then the newest of the rest; what does not fit stays in `news` for the next input, and the entry ends "…and 12 more, given at your next turn; reports and work list them now." So a message the person wrote to an agent always reaches the orchestrator. `news` holds at most 200 pieces besides those with `keep`; past that the oldest go, counted in the next catch-up as "(and 40 older changes not listed)".
- **Seen.** The transcript shows it as one folded line, "pi² told the orchestrator what changed (2)", like a wake's row, opening to the text.

**The state block** is an entry of its own kind, `pi2.state { snapshot: StateSnapshot }`, made from the documents when it is given, in a fixed order, so the same state gives the same text:

```ts
type StateSnapshot = {
	at: number;
	/** Runs of the project's sub-chats going now: number, agent, title, since, waiting for a limit until, or null. */
	working: { chat: number; agent: string; title: string; since: number; limitUntil: number | null }[];
	/** Everything under Needs you for the project: its id, kind and one line (the question, the change, the command). */
	needs: { id: string; kind: NeedKind; line: string; conversation: number }[];
	/** Reports not delivered: sub-chat, agent, title, outcome, when. */
	reports: { chat: number; agent: string; title: string; outcome: string; at: number }[];
	/** Open work: counts by state, and every item in progress, waiting or blocked with who holds it. */
	work: { counts: Record<WorkState, number>; held: { id: number; title: string; state: WorkState; agent: string | null }[] };
	/** News with `keep` not yet given. */
	messages: string[];
};
```

It reads as:

```
[pi² — the project as it stands, 19 November 14:20]
Working now: sub-chat 14 “Fix login” (Forge, since 13:40); sub-chat 16 “Docs” (Scout, waiting for Anthropic's limit until 15:30).
Under Needs you: n12 decision “Merge now or after the release?”; an approval for Forge's command `npm publish` (sub-chat 14).
Reports not read: sub-chat 15 “Tests” (Scout) failed at 14:10.
Work: 12 open, 3 in progress, 1 waiting, 0 blocked. In progress: #28 Forge, #29 Scout, #31 Scout. Waiting: #30 Forge.
The person wrote to Forge in sub-chat 14: “…”
```

Each part says "none" when empty; every list is whole up to 30 entries, then "and N more; <tool> lists them". It is given:

- in front of the first input of a new conversation with the orchestrator (a new project, Start fresh, a new orchestrator, or one made after the current one was deleted), in place of a catch-up, clearing every piece of news it represents (all of them);
- at the end of what pi² adds to a summary of the orchestrator's conversation (`compactionCheckpoint`), after the open sub-chats and the task list it adds today. The summary does not clear news: the news that reaches the orchestrator after the summary still comes in the next catch-up.

### 6.5 Start fresh

`projects.startFresh`, and `projects.setOrchestrator` (or allowing that request), which does the same with another agent and changes the roles in the same commit, are the engine's: the commit is made by the engine, whichever app, if any, is open.

It is refused while the current conversation is answering, while a message of the person's is queued in it ("Send or take back your queued message first."), or while it waits on an approval or an `ask_user` question ("Answer what the orchestrator is waiting for first."). Otherwise, in one commit:

| What the old conversation has pending | What becomes of it |
|---|---|
| Sub-chats working, handed over without waiting | Their watches move to the new conversation: their reports go there, by its waking rules. They stay sub-chats of the old one, which `sub_chats` in the new one lists |
| Reports not delivered | Stay undelivered; the new conversation's state block lists them |
| Wakes arrived and not handed over (`arrived` in `pi2.wakes`) | Move to the new conversation, handed over by its first wake or turn |
| A hold on waking: the hourly cap | Moves: the new conversation counts the old one's wakes in the last hour, so the cap still holds |
| A hold on waking: the person's Stop, or the budget | Does not move: the person starts the new conversation, which is the message that lifts a Stop; the budget holds anyway |
| Background commands with a wake | Their watches move to the new conversation, whose wake says they were started in the earlier one. The commands go on running; Activity shows them under the earlier conversation, where they can be stopped |
| Background commands without a wake | Go on running, in the earlier conversation, as today |
| Its questions and decisions under Needs you, its reach requests and proposed rules | Stay; their answers go to the new conversation, saying they were asked in the earlier one |
| Its task list (`update_plan`) | Stays with the earlier conversation, readable there |
| News | Represented by the new conversation's state block, and cleared |

The old conversation goes to the end of `earlier`, stays readable and is not archived (archiving would stop its sub-chats); with the preview on it takes no messages ([3.5](#35-conversations-pi2library)). Its page ends with a line, "Continued in a fresh conversation", linking to the new one; the new one begins with "Started fresh from an earlier conversation", linking back, and with the state block. The rules and notes are its sections, as in any conversation of the project.

Archiving or deleting the current conversation by hand does what [3.6](#36-archiving-and-deleting) says: archiving stops its work, as it does any conversation's.

### 6.6 What switching the preview off leaves in a conversation

From each conversation's next message, switching off takes away the project's sections and tools (each sent alone, as any change is) and adds no catch-up or state block. What it was already given stays in its transcript and its context, as everything does: catch-ups and state blocks already given are history, which a later summary may fold in like any other. News that comes while the preview is off is kept, and given at the first turn after it is on again. Nothing is deleted from a transcript.

## 7. Reach: what an agent can only ask for

The design: a change that lets agents do more or spend more, the orchestrator can only ask for, as a card the person answers with one click. This page keeps the list of such changes narrow for spending, which the limits bound ([8.3](#83-limits-and-the-one-admission-check)), and wide for what agents may do, where a setting it does not name counts as widening.

### 7.1 Every setting, classed

A change made through any tool, by any agent, and by every path a tool has to it (making an agent, a copy of a template, Update from template, Undo, restoring), is compared with what is stored now, setting by setting. A change that widens reach is never made by the tool: it is put to the person as a reach request. Every other change is made, with a line and Undo, under the switches of [8.1](#81-what-the-orchestrator-may-do-without-asking).

**An agent's settings** (`AgentProfile`, [state.ts](../engine/src/state.ts)):

| Setting | Widens reach when | Why |
|---|---|---|
| `name`, `description`, `color` | Never | Changes nothing it can do |
| `instructions` | Never | Cannot widen what the engine lets it do |
| `model`, `thinkingLevel` | Never | Spending is bounded by the project's limits ([8.3](#83-limits-and-the-one-admission-check)) |
| `maxTurns`, `compactionTokens` | Never | As above |
| `codeMode` | Never | A script calls only the agent's own tools, each judged as it is called |
| `access` | Raised (Tools off, Read files, Ask first, Full access, in that order) | It acts without asking, or acts at all |
| `allowEverything` | Turned on | Lifts every approval |
| `toolsOff` | A key taken out: a built-in tool turned back on (`files`, `documents`, `ask`, `plan`, `web`, `pictures`, `compact`, `code`) | It does what it could not; `documents` writes, `web` reads the web, `pictures` spends |
| `toolsOn` | A key added | As above |
| `computer` | Turned on, an app added, `testCopies` turned on, or `ask` turned off | Reaches other apps, or acts in them without asking |
| `browser` | Turned on, or `ask` turned off | Reaches the web with the person's sign-ins |
| `mcpServers` | A server added | Reaches what the server reaches |
| `files` (reference files) | One added | Reads outside the project's folder |
| `schedule` | Turned on | Starts work with nobody there |
| `commandRules` (allowed commands) | One added | Runs it without asking |
| `worktree` | Turned on | Its conversations get worktrees without asking, and its set-up command runs in each |
| `setup` (the set-up command) | Set or changed | Runs without asking in every new worktree |
| `delegates` | An agent added | Lets it use that agent's reach |
| Its memory switch | Turned on | A note planted by what it read persists ([knowledge.md](knowledge.md#memory)) |
| `variables` | — | Not offered to any tool: the person's alone |
| `cwd` | — | Set by the engine, never by a tool |
| `role` | Given to another agent (`set_orchestrator`) | The orchestrator's switches and tools go with it |
| `removedAt` | Never: restoring puts back only what the agent had | — |
| Any setting not in this table, or added to agents later | Any change | Counts as widening until this table names it |

**A project's settings:**

| Setting | Widens reach when |
|---|---|
| `name` | Never |
| `folder` | Set or changed |
| `repository` | Attached or changed |
| `withoutAsking`, each switch | Turned on |
| `limits.planShare`, `limits.dailySpend` | Raised, or turned off |
| `wakeOnReports` | — Not offered to any tool: the person's switch ([8.2](#82-when-a-report-wakes-the-orchestrator)) |
| Any setting not in this table | Any change |

**Rules:** adding one never widens; removing one, changing its text, or making it bind only the orchestrator where it bound everyone, always does ([5.4](#54-project_rules-the-orchestrator)). Moving one never does.

**Never widening, whatever the agent:** notes (`remember`, `forget`), work, and the waking of the orchestrator's own hand-offs (`reports` `wake`), which the limits bound.

**A new agent** made by an agent, a copy of a template among them, is made at the baseline (7.2) for every setting that would widen, and one reach request asks for all of those at once.

**Not offered to agents at all**, so neither made nor asked for by a tool: the preview switch, carrying over, archiving, restoring and deleting a project, Start fresh, waking for the whole project, deleting an agent for good, templates themselves, an agent's variables, sign-ins and providers, MCP servers' own settings, and "Always Allow … Here" on a conversation.

Lowering any of these (access lowered, a switch turned off, a limit lowered, an app taken away) narrows reach and is made at once, with Undo.

### 7.2 Asking, allowing, refusing

**The baseline** for a new agent made by an agent: access at most Ask first; Allow everything, computer use, the browser, scheduling, the worktree setting and memory off; no MCP server, reference file, allowed command, set-up command or delegate; the built-in tools as a new agent's defaults (`pictures`, `code` and `compact` off). Everything else as asked.

**Asking.** The tool:

1. Works out the change against what is stored now, and splits it: what does not widen is made (as one change with Undo); what widens is not.
2. For what widens, puts one `reach` item under Needs you per call, with `change`:

   ```ts
   type ReachChange = {
   	/** What it changes, as the person reads it: "Let Forge run commands without asking (Full access)". */
   	summary: string;
   	/** Exactly what allowing it sets, field by field, with what is there now. */
   	target: { kind: "project" } | { kind: "agent"; id: string } | { kind: "rule"; id: string };
   	fields: { name: string; before: unknown; after: unknown }[];
   	/** The change of section 3.12 it would be, once allowed. */
   	op: Op;
   	/** An agent's Undo of this change that had to be asked for: allowing it marks that change undone. */
   	undoes?: number;
   };
   ```

   and `why`, the agent's `why`, shown as the agent's words, not pi²'s. No variable's value is ever in it.
3. Answers at once, without waiting: what was made, and "<summary>: this widens what agents may do, so it was put to the person, who will allow or refuse it. You will be told their answer. Do not ask again meanwhile."

The same change asked again while one is waiting gives the one waiting, not a second.

**Allowing.** The card has two buttons, **Allow** and **Refuse**, and says what allowing means in the words the setting's own confirmation uses (for Allow everything, those of [allow-everything.md](allow-everything.md#turning-it-on)). On **Allow**, before anything is changed, the engine checks again: the project is neither archived nor deleted; the target is still there (and not removed); the asking conversation is still in the project; and each field still has its `before` value. If any check fails, nothing is changed and the item is withdrawn: "This has changed since it was asked, so nothing was changed." Otherwise it applies `op` through the same validator as the person's own request, records it with `by: { kind: "allowed" }` (so it has a line and Undo too), and the asking conversation is told: "The person allowed: Let Forge run commands without asking (Full access)."

**Refusing** changes nothing; the conversation is told: "The person refused: …. Do not ask for it again unless they bring it up."

**What decides.** The change, never who asked or why: a request is a request whether the agent was asked by the person, talked into it by a web page, or told to by another agent's report. Allow everything does not answer it, and no tool answers it. Text in a tool's result, a page, a file or a report that tells the orchestrator to raise its own reach can, through its tools, produce a request and nothing more (#465's test).

### 7.3 Who answered

Any command an agent runs is a process of the person's own and can connect to the engine's socket as the app does. Since #504 the engine takes an answer to what waits for the person only from the app, and since #513 the requests that change the person's settings only from the app too: it asks macOS which process is at the other end of each connection and checks it is pi² itself by its code signature ([architecture.md](architecture.md#who-may-answer-for-the-person)). From any other connection, `inbox.decide`, `inbox.answer`, `auth.answer` and `agents.allowEverything` with `on: true` are refused, and so is every request that changes what an agent, a chat or a project may do — an agent's settings, a conversation's access, an allowed command, a variable, a project's settings — with an error that tells the agent to ask the person. Those requests cannot answer a command's approvals or change its settings. Ordinary messages and starts remain open, including choosing an existing agent or model for a new conversation, as do reads, notes and display metadata.

The engine also takes `needs.answer`, which answers any item in [Needs you](#39-needs-you-pi2needs-and-the-inbox), only from the app.

Every new request that answers something waiting for the person joins that list, `FOR_THE_PERSON` in `engine/src/answers.ts`, and every request that changes what the person set joins `FOR_THE_PERSON_SETTINGS` beside it, in the issue that adds it, which checks that it is refused from a connection that is not the app's (`engine/test/answers.ts` and `engine/test/reachsettings.ts` show how). The engine will not open its socket if a registered handler belongs to zero or more than one list.

What this page promises is still this, and no more: **an agent can only ask, as long as it does not go round pi² on purpose**. A command can write the data folder itself (the database, `settings.json`), or stop the engine and start one of its own on it. These checks do not sandbox commands or protect the person's files from their own processes.

## 8. Settings: without asking, waking, limits

```ts
type SwitchName = "startAgents" | "fileWork" | "closeWork" | "makeAgents" | "addRules" | "merge" | "release" | "passLimits";

type ProjectSettings = {
	/** The person's switch alone (8.2). */
	wakeOnReports: boolean;
	withoutAsking: Record<SwitchName, boolean>;
	limits: {
		/** Percent, 1 to 100: no start while a window of the plan the started agent would run on is this much used. Null: none. */
		planShare: number | null;
		/** Dollars: no start once the project's spending today reaches this. Null: none. */
		dailySpend: number | null;
	};
};
```

### 8.1 What the orchestrator may do without asking

| Switch | Governs | Default, new project | Default, carried over | Off means |
|---|---|---|---|---|
| `startAgents` | Every start by an agent: `delegate` (new or continued), `work` `assign` | On | On | Each start asks the person first, as an approval |
| `fileWork` | `work` `file` | On | On | Each filing asks first |
| `closeWork` | `work` `finish` (by any agent), `close` | On | On | Each finishing or closing asks first |
| `makeAgents` | `project_agents` `make`, `change`, `remove`, `restore`, `update_from_template` | On | On | Each asks first |
| `addRules` | `project_rules` `add` | On | On | An added rule becomes a proposal instead |
| `merge` | `work` `merge` | Off | Off | Each merge through `work` asks first |
| `release` | Nothing pi² does | Off | Off | The orchestrator is told to ask before releasing ([section 11](#11-what-the-engine-cannot-check)) |
| `passLimits` | A start past a limit | Off | Off | A start past a limit is refused, and a limit card offered to the person |

A switch that is off makes the tool call ask through the Inbox, as an approval with Allow Once and Deny only, whatever the agent's access: the Inbox item carries `projectSwitch`, which the app reads to offer only those two answers and to say which switch asked, and which `Inbox.ask` reads to ask even for an agent with Allow everything ([13](#13-decisions-this-contract-made), decision 17). One helper, `requireSwitch(conversation, switch, what)` in `projects.ts` (#456), does this for every tool that a switch governs; [12.1](#121-who-owns-what-several-issues-share) gives its arguments and answer as built. Turning a switch on widens reach; turning one off is made at once.

### 8.2 When a report wakes the orchestrator

`wakeOnReports` is the person's switch, in the hub, and no tool changes it. **Off** for a new project, as the owner decided; **on** for a project made by carrying over ([14](#14-questions-for-the-owner), question 9). The orchestrator chooses only for its own hand-offs, with `reports` `wake` ([3.10](#310-reports-and-waking-pi2reports-pi2wakes)), which overrides the switch for the runs it names.

Past a limit of the project, no report wakes the orchestrator, whatever was chosen: it stays undelivered, for the next turn or a `read` ([8.3](#83-limits-and-the-one-admission-check)). The wakes' own bounds hold as always: the budget, the turn limit and 30 an hour.

### 8.3 Limits, and the one admission check

| Limit | Default, new project | Default, carried over |
|---|---|---|
| `planShare` | 90 | None |
| `dailySpend` | None | None |

The daily budget of all of pi² still applies as today, on top, and is what bounds a model on a key, which has no plan window.

**What is counted.** `planShare`: every window of the subscription that the started agent's model is on, as Usage last read it ([limits.md](limits.md)). A window whose reset has passed since it was read does not count; a subscription with no reading yet, or a model on no subscription (a key, an endpoint, a model on this Mac), has no window to count, and the start's result says so when a limit is set ("no reading of this plan's windows yet"). `dailySpend`: what the project's conversations, sub-chats included, have cost today, in the Mac's local day, as Usage counts it (`usage` event, `projects`).

**What it holds back.** Every start in the project, by an agent or the person, and every wake of the orchestrator for a report. Not: the orchestrator's own turns that the person's messages start, the person's messages to any conversation, wakes for answers the person gave, or work already running, which carries on. With the preview off, a project's limits still hold its starts ([section 2](#2-the-preview-switch)).

**One check.** `admit(start)` in `projectlimits.ts` (#464) is the one function every start passes, at the moment it would start, not when it was asked for:

```ts
/** Everything needed to make one start, as it was asked for: kept whole on a limit card, so allowing it makes exactly this. */
type Start = {
	by: Who;
	agentId: string;
	agentName: string;
	kind: "new" | "continue" | "assign" | "conversation";
	/** The parent conversation for a sub-chat; the sub-chat continued; the work item assigned. */
	parent: number | null;
	chat: number | null;
	work: number | null;
	title: string | null;
	task: string;
	/** What `delegate` was given beyond the task, as given: worktree, from, wait. */
	options: Record<string, unknown>;
};

/** What was over, when it was read. Its `id` names this limit and reading, for a one-shot confirmation. */
type LimitReading = { id: string; limit: "planShare" | "dailySpend"; reason: string; provider: string | null; window: string | null; used: number; max: number; resetsAt: number | null };

// At the start's commit, with its configured model (see 12.1 for AdmissionSite).
function admit(start: Start, confirm: string | undefined, site: AdmissionSite): Promise<{ ok: true; note?: string } | { ok: false; limit: LimitReading }>;
```

In order, for a start by an agent:

1. **The switch.** With `startAgents` off, the start asks the person first (8.1). Allowing that approval allows the start, not passing a limit.
2. **The limit,** at the moment of starting, after any approval: within every limit, it starts.
3. **Past one,** with `passLimits` on, it starts, and its result says how the limit stands. With it off, it is refused at once with the reason, and a `limit` card goes under Needs you holding the whole `Start` and the `LimitReading`:

   > Not started: the project's limit stops new agents while a plan window they would run on is 90% used or more, and the Anthropic subscription (Max) has its 5-hour window 93% used, resetting at 15:30 (in 1 h 12 min). Work already running carries on. The person can start it anyway from the card under Needs you, or raise the limit.

4. **The card's Start Anyway** (`{ kind: "limit", start: true }`) runs `admit` again with the card's reading as `confirm`: it starts when what is over is no more than that reading (the same limit; for the plan, the same window or a reading that is lower), and otherwise the card stays, showing the new reading. **Leave It** drops it. Either way the orchestrator hears of it in its catch-up. The card is taken once, through `claim`, so two answers start nothing twice.

For a start by the person (`work.act` `assign`, `conversation.create` with a project agent, a sub-chat started from the board): past a limit, the request is refused with the reading (error "Past the project's limit: …", and the reading as `limit` in the error's data); the app shows it, and the person confirms that one start by sending the request again with `confirmLimit` set to the reading's `id`, checked as Start Anyway is.

With the preview off, a start past a limit is refused with the reason and no card is put anywhere, since nothing would show it; the person can raise the limit after turning the preview on.

Two starts at once can each pass: the limit is a check, not a reservation, and the next start after them sees what they spent. A reading that cannot be made (Usage has never read the plan) does not hold a start back, as above.

## 9. Carrying over

Carrying over puts what a person has today into projects, with nothing lost, nothing deleted, and nothing the old way reads changed: it only adds documents, adds fields the old way does not read, and copies agents. The code is `engine/src/carryover.ts` (#458).

### 9.1 What becomes what

| Today | Becomes | Old record |
|---|---|---|
| An agent | A template: the same agent, as it is | Unchanged |
| The agents a folder's conversations ran as | A copy of each in that folder's project | Unchanged |
| A top-level conversation with a folder | A conversation of the project of that folder (9.2), working where it worked (9.6) | `projectId`, `projectAgentId` added |
| A sub-chat | In its root conversation's project, working where it worked, in whatever repository | As above |
| An archived conversation | In its project, still archived | As above |
| A conversation with no folder | In the project with no folder, "No folder" | As above |
| A deleted conversation | Nothing | Unchanged |
| A chat, a chat's version | Nothing: chat mode stays as it is | Unchanged |
| A conversation whose agent was deleted | In its folder's project, running as it does today | `projectId` added |
| An agent's memory notes | Notes of each project with a copy of that agent, for that copy alone (9.7) | Unchanged |
| Chat mode's notes | Nothing | Unchanged |
| Allowed commands | Copied with each copy, all of them | Unchanged |
| An agent's variables | Copied with each copy, names and values (9.5) | Unchanged |
| Allow everything | Copied with each copy whose template has it (9.5) | Unchanged |
| "Always Allow … Here" on a conversation | Stays on the conversation | Unchanged |
| Approvals and questions waiting | Shown under Needs you, in their conversation's project | Unchanged |
| Sub-chats handed over without waiting, still working | Their watches are left as they are: such a run has no report, so it wakes the agent that handed it over as it would have ([wakes.md](wakes.md)); runs started afterwards follow the project's `wakeOnReports`, which is on for a project carrying over makes | Unchanged |
| Inbox notices of plans' limits | Stay in the `limits` event, shown as today | Unchanged |
| Worktrees | Stay where they are, with their conversations | Unchanged |
| Schedules | Stay on their agent (the template); the conversations they make are put in projects as they are made (9.9) | Unchanged |

### 9.2 Grouping by folder

A conversation's folder is its `cwd` as its `pi.agent` document holds it now (null: no folder). Its grouping key is worked out by `groupingKey(cwd)` in `carryover.ts` (`Grouping`, which works each path out once in a plan), without running git, as follows:

1. A sub-chat: its root conversation's key, wherever it works.
2. No folder: `none`.
3. A folder in a worktree pi² made (`pi2.worktrees`, `madeWorktrees`): the top of the main checkout the worktree was made from, as pi² recorded it.
4. Otherwise, from the folder upwards, the nearest folder with a `.git` entry (this is where `knowledge.ts` stops looking for instruction files; the grouping goes further), but not past the home folder: a repository at the home folder (dotfiles, say) is the key of the home folder itself and no folder under it:
   - a folder `.git`: that folder is the top of a main checkout, and is the key;
   - a file `.git` reading `gitdir: <path>` (relative paths taken from the folder that holds the file): when `<path>` is `<main>/.git/worktrees/<name>`, a linked worktree, the key is `<main>`; when it is `<super>/.git/modules/…`, a submodule, the key is the submodule's own top, the folder with the file: a submodule is a project of its own; any other `gitdir`, or one that cannot be read, the folder with the file. A worktree of a bare repository (`<repo>.git/worktrees/<name>`) is therefore a project of its own;
   - none found: the folder itself.
5. Each key is the real path of that folder, as macOS gives it (`realpathSync.native`, with the case the disk has, so one folder stored with two casings is one key). A folder that has gone is walked up from as stored, so it is keyed by the repository above it that is still there, or, with none, by its path as stored (the real path of the nearest folder above it that is still there, with the rest of the path).

The report says, on the project's `notices`, when a worktree's repository has gone (pi² made the worktree, or it is a linked one whose main checkout is missing: the project's folder is then missing too) and when a bare repository's worktrees are each a project of their own.

So a conversation in `engine/` of a repository, one in its main checkout and one in a worktree of it are one project; two repositories, or a repository and its submodule, are two.

The key of an existing project is `groupingKey(project.folder)`, or `none` for a project with no folder.

### 9.3 One plan

Carrying over is worked out as one plan, `planCarryOver(snapshot)`, a function of the documents alone (library, agents, memory, worktrees, projects and the carrying-over record), with every choice made by a rule below and every tie broken by one: the most recently updated first, then the lowest conversation id, then the lowest agent id. The same documents give the same plan. The report a dry run shows is that plan, and has its fingerprint (`plan`, a hash of it). A real run works the plan out again and goes ahead only if the fingerprint is the same; otherwise it changes nothing and answers the new report ([9.8](#98-the-report-and-the-run)). A conversation made later (9.9) is carried by the same function, given that one conversation.

### 9.4 Projects: lookup and adoption

For each key with at least one top-level conversation that is not deleted and not yet in a project:

1. **A project not deleted whose folder has this key** is the one: made earlier by carrying over, or by the person by hand (adopted: recorded in `carry.folders`, its name, folder, settings and orchestrator left exactly as they are). A folder has at most one project not deleted, but several folders can have one key (a repository and its subfolder, or any number of projects with no folder), so among several: the one the record has for this key, if it is among them; otherwise the one whose folder is the key itself; then the oldest. For `none`, a project the person made with no folder is never taken: only one carrying over made, so the person's "Loose ends" never receives conversations because it was edited last.
2. Otherwise, **the project recorded for this key** in `carry.folders`, if it is not deleted (its folder moved since; the record keeps sending this key's conversations to it, since that is where the person has been working with them).
3. Otherwise **a new project**: named after the folder's last part ("No folder" for `none`), with " 2", " 3"… in the order of the keys when names are taken; archived when every conversation it gets is archived; with the settings of a new project, but `wakeOnReports` on and no limits ([section 8](#8-settings-without-asking-waking-limits)).

A run never changes the name, folder, settings, rules or orchestrator of a project that exists. When several keys reach one project (one by the record, another by the project's new folder), each is recorded, so none is reported adopted again. `adopted` in the report is true for a project found by its folder for a key the record does not send to it yet.

### 9.5 Agents: copies, adoption and secrets

For each project, the templates to copy into it are the agents its conversations ran as (sub-chats' included), and the agents those may hand work to, followed through their `delegates` until nothing is added, so that every conversation can still hand work to everyone it could. For each such template:

1. **The copy recorded** in `carry.copies` for this project and template is the one, if it still exists (removed or not).
2. Otherwise, **an agent of the project made from this template** (`template.id`), the oldest, is adopted and recorded.
3. Otherwise, if the record names a copy the person has since deleted, **nothing is made**: the deletion stands, and that template's conversations in this project get no `projectAgentId`, so they run as the template, as today.
4. Otherwise **a copy is made** ([3.3](#33-agents-and-templates-pi2agents)), with, beyond a copy made by hand, the template's Allow everything when it has it, and its variables' values (below). The copy takes what the plan, and so the report, said of these and of its memory switch, not what the template has by the time its commit is made: a template that has lost one since gives the copy what is left, and one that has gained one since (Allow everything turned on, a variable given a value, memory turned on) stops the run as changed ("Something changed while carrying over ran…"), for the person to look at the report again. A template that makes a worktree for each conversation, copied into a project whose folder is no repository (or that has none), gives a copy with worktrees off, and the report says so (`copies[].worktreeOff`).

**Variables' values.** A copy that needs them is put in `carry.secrets` in the commit that makes it. Copying the values into the Keychain, under the copy's id, is a step after that commit, taken again at every engine start and with `projects.retrySecrets` until each is done: a value is copied only while the copy's variable is still unset, so a value the person has set since is never overwritten; a copy done is taken off the list; one that fails keeps its error. While any is pending, the `projects` event's `carryOver.secretsPending` lists it, by copy, project and variable names, and the board says so on that agent: "2 of Forge's variables have not been copied from the agent it was made from. Try again, or set them by hand." The report lists, before the run, every copy that will take Allow everything or variables' values, by name ([9.8](#98-the-report-and-the-run)).

### 9.6 Conversations: what each keeps

Each conversation of the project whose agent has a copy there gets `projectAgentId` set to it. That changes only what is taken from the agent at each message ([3.4](#34-which-agent-a-conversation-runs-as-runsas)). Everything else is the conversation's own and stays as it is, with the preview on or off:

- **its folder**, which is its `pi.agent` document's: a conversation in a subfolder, a sub-chat in another repository and a conversation in a worktree keep working there, continued or not;
- **its worktree** in `pi2.worktrees`, and so what the branch tracker shows;
- **its access level** and its **"Always Allow … Here"** (`Meta.access`, `Meta.autoApprove`);
- **its allowed commands**: the copy has all of its template's, for every folder, so a command allowed in the folder where the conversation works, or in an older worktree-local rule, is still allowed there ([allowed-commands.md](allowed-commands.md)).

What does change, and the report says so for each copy: a *new* sub-chat that a copy is handed starts in the project's folder ([3.3](#33-agents-and-templates-pi2agents)), where its template, if it had a folder of its own in another repository, started there. The report lists each such copy with its template's folder (`copies[].folder`), so the person sees it before the run.

**The orchestrator** of a project carrying over makes (not one it adopts, whose orchestrator stands): among the project's top-level conversations that are neither archived nor deleted, whose agent still exists and that have at least one sub-chat (they hand out work), the first by the tie-break of 9.3 becomes the orchestrator's conversation, and the copy of its agent the orchestrator (`role`). When none qualifies, the project gets a copy of the default orchestrator, with no conversation yet (`conversation` null): the app makes one with `projects.startFresh` when the person first opens or writes to the orchestrator, and it begins with the state block (6.4). So no empty conversation appears in the old sidebar for each folder carried over. Every other conversation stays one of the project's other conversations.

### 9.7 Notes

Each note in `pi2.memory`'s `agents` is copied once into each project it goes to, and recorded in `carry.notes` for that project (`<projectId> <templateId> <noteId>`), in the commit that copies it, whatever became of it since, so no later run copies it there again, even if the note it became has been removed or shared. A run cut off between two projects' commits leaves each project it reached recorded, and the next run copies the note only to the others. A project that gets a copy of the agent later (a later run, or a conversation made later, 9.9) gets its notes then:

- a note of an agent that has a copy in one or more projects: copied to the project where a conversation of that agent's wrote it, when that project has a copy. A recorded copy that was removed or deleted receives nothing, but still keeps notes written in that project from going elsewhere. A note the person wrote (`conversation` null), or one whose conversation is deleted, in no project or in one without a copy, goes to every project with a copy that can receive it. A one-conversation plan narrows these destinations only after deciding where the note belongs, so it cannot send a note where the full plan would not;
- copied as a `ProjectNote` with its audience the copy alone (`audience` the copy's id), its `createdAt`, and `carriedFrom` with the agent's id and name. A copy's memory switch is its template's, so a note of an agent whose memory was off is still given to nobody. So a note reaches exactly whom it reached before, until the person shares it with the project;
- a note whose text the project already has for the same audience is not copied twice; its source is recorded as dealt with, pointing at the note that has the text;
- a note of an agent deleted (whose notes are kept and shown nowhere today) is left where it is and recorded `"left"` (`<agentId> <noteId>`); the report counts them (`notesLeft`). A note of an agent with no copy anywhere yet is recorded nowhere, and goes to the first project that gets one.

The agents' own notes are left where they are, and with the preview off are what each agent is given, as before.

### 9.8 The report and the run

`projects.carryOver { dryRun: true }` answers what a run would do, changing nothing:

```ts
type CarryOverReport = {
	/** The plan's fingerprint (9.3): what `setPreview` and `carryOver` must be given to run it. Null: nothing to do. */
	plan: string | null;
	projects: {
		key: string;             // the grouping key: a folder, or "none"
		name: string;
		existing: string | null; // the project found by 9.4, if any
		adopted: boolean;        // found by its folder for a key the record does not send to it yet (9.4)
		archived: boolean;
		orchestrator: { conversation: number | null; title: string | null; template: string | null } | null; // null: an existing project's stands; template null: the default orchestrator
		copies: {
			template: string; name: string; existing: string | null;
			allowEverything: boolean;   // the copy takes Allow everything
			variables: string[];        // the names whose values it takes
			worktreeOff: boolean;       // its template makes worktrees, and the project's folder is no repository: the copy does not (9.5)
			folder: string | null;      // its template's own folder, when outside the project's: new sub-chats start elsewhere (9.6)
		}[];
		conversations: number;   // top-level, not archived, to be added
		archivedConversations: number;
		subChats: number;
		notes: number;
		notices: string[];       // lines for the person: a repository gone, a bare repository's worktrees (9.2)
	}[];
	leftOut: { chats: number; deleted: number; deletedProject: number; notesLeft: number };
	/** Top-level conversations already in a project that has not been deleted: left as they are. */
	already: number;
	ranAt: number | null;
	backup: string | null;
	secretsPending: CarryOverState["secretsPending"];
};
```

`leftOut.deletedProject` counts top-level conversations of deleted projects that are not themselves deleted, whether archived or not. They keep their project record and are not carried again (3.6).

The app shows the report as the person turns the preview on, before the run, with a button to go ahead, and lists by name every copy that takes Allow everything or variables' values (#470).

**The real run** (`projects.setPreview { on: true, plan }`, or `projects.carryOver { plan }`):

1. Works the plan out again; a different fingerprint changes nothing (9.3).
2. When the plan is empty, changes nothing at all, `ranAt` included, and answers the report.
3. Before the first run that changes anything, makes a backup as **Back Up** does (`createBackup` in `backup.ts`), into `backups/` in the data folder, and records its path. That backup is a snapshot of the database and the settings files as they were before projects: it holds no Keychain item, so it cannot bring back keys or variables' values, and restoring it replaces everything done since, in projects or not. With the preview switch, which shows everything as it was without restoring anything, it is the way back ([13](#13-decisions-this-contract-made), decision 19).
4. Commits, one commit per project (so a large library does not hold the engine's thread in one long commit): the project, its copies, the conversations' fields, the notes, the record (its keys, copies and notes) and `ranAt`. A run cut off between two commits leaves what was committed, which the next run finds by 9.4, 9.5 and 9.7 and does not do again.
5. Copies variables' values, as 9.5 says.
6. Answers the report, with `ranAt`, `backup` and what is still pending.

### 9.9 Conversations made later

While the preview is on, when a top-level conversation that is not a chat is made with no `projectId` (by a schedule, by Continue with an Agent, by `conversation.create` from a script with a template, by a fork of a conversation in no project), the engine carries it over as it is made, with `planCarryOver` for that one conversation and its sub-chats: into the project of its key by 9.4 (restoring that project if it was archived, as [3.6](#36-archiving-and-deleting) says; a new one if the folder's was deleted), its agent copied there by 9.5 if it has no copy yet, with the notes that go to that copy (9.7), and `projectAgentId` set. Its start is checked against the limits of that project, as a start of one of its agents is ([8.3](#83-limits-and-the-one-admission-check)).

It is carried in a commit after the one that made it. If that fails, or the engine stops between the two, the conversation is not held up. With the preview on and a run already recorded (`carry.ranAt` is not null), the engine carries the top-level conversations that are not chats or deleted and have no `projectId`, one by one, at startup and again after a carry fails. If the preview is on but no run is recorded, there is no sweep: existing conversations without a project are left to the report and the first backed-up run (9.8). An archived conversation that is carried goes into its project without restoring that project. Conversations of a deleted project keep its `projectId` and are not swept; a fork of one whose own agent does not belong to the deleted project starts outside it and is carried (3.6).

### 9.10 Running it again

Every step looks first, by the rules of 9.4, 9.5 and 9.7, for what an earlier run made or the person made since, and does nothing it finds done. So a second run with nothing new has an empty plan, commits nothing and leaves every document exactly as it was, `ranAt` included. What is new since (a conversation made with the preview off, an agent made since, a note written since) is added as a first run would add it. Nothing the person chose since is changed: a project's name, folder, settings and orchestrator, a copy's settings, a copy or project they deleted, a note they removed or shared.

### 9.11 Switching the preview off

Nothing is undone: the projects and everything in them stay, and turning the preview on again shows them as they were left. Meanwhile:

- every conversation runs as its `agentId`, exactly as before carrying over ([3.4](#34-which-agent-a-conversation-runs-as-runsas)), in its own folder, as it always did;
- no project section, rule, note, catch-up or tool reaches any conversation from its next message ([6.6](#66-what-switching-the-preview-off-leaves-in-a-conversation)): a conversation carried over is told exactly what it was told before, byte for byte, whatever was changed in its project with the preview on;
- what holds for a project's conversations whatever the preview still holds for those carried over: its `startAgents` switch asks before one of their agents starts another ([8.1](#81-what-the-orchestrator-may-do-without-asking)), and its limits hold for their starts ([8.3](#83-limits-and-the-one-admission-check)). So a carried project's settings, changed with the preview on, change how the person's old conversations start agents with it off;
- a sub-chat made with the preview off in a conversation carried over takes its parent's `projectId` but no `projectAgentId`: with the preview on it runs as its agent, the template, not the project's copy;
- every request that exists today works as today, except that starts with a deleted project's own agents are refused (3.6);
- the old screens show every conversation where it was, since nothing in the epic writes a conversation's own archive state ([3.6](#36-archiving-and-deleting)), and no conversation is added for an orchestrator (9.6); the templates are the agents list, and project agents are left out of it by the app ([10.2](#102-with-the-preview-off)), which the app before #470 does not do (12.1);
- the agents' own notes, allowed commands and variables were never changed, so each agent has all of them;
- what was made in projects while the preview was on (new conversations, notes, rules, work) is kept, and conversations made in projects are listed in the old sidebar like any other.

## 10. The app

This page decides only what the app reads, sends and keeps. What each screen looks like is the design's, with its drawings, and each app issue's.

### 10.1 What the app keeps itself

In the app's preferences, by project id, not in the engine: how each project's hub was left (`project.<id>.fold`: both shown, the conversation folded, or the board folded), the board's tab, and the projects ticked on the Dashboard (`dashboard.projects`). Two Macs do not share them, and the engine has no use for them. While the app runs, which project shows is the window's selection (`Selection.project`), and how its hub was left is `ProjectHubs` (`app/Sources/pi2/ProjectHub.swift`): `AppModel.showProject` sets them together, for the sidebar of projects (#470) and a test copy's `show` (#471). `ProjectHubs` also keeps, for each project and for this launch only, the conversation of one of its agents shown in place of the board (#473): choosing a project or its orchestrator goes back to the board, and a hub opens on its board.

### 10.2 With the preview off

The app shows today's screens, reading the same events as today, and:

- leaves agents with a `projectId` out of the agents' list, the New Conversation With menu and the palette's agents, while still finding them by id to name a conversation's agent;
- shows nothing of the `projects`, `needs`, `projectRules`, `reports`, `work` and `github` events, but an approval's `projectSwitch` (offering only Allow Once and Deny);
- shows **Projects (preview)** in Settings › General.

### 10.3 With the preview on

Each thing the hub, the sidebar and the Dashboard show, where it comes from, and the issue that shows it:

| Shown | From | Issue |
|---|---|---|
| The sidebar's projects, their order and names | `projects` | #470 |
| A project's badge | `needs` by `projectId`; `activity` by `projectId` | #470 |
| The orchestrator and the agents working now, under the open project | `projects` (`orchestratorId`, `conversation`); `activity` by `projectId` and `runsAs` | #470 |
| A project's other conversations, folded under it | `library` by `projectId`, not the orchestrator's | #470 |
| The hub's bar: folder and branch, the orchestrator's model, the plan's week | `projects`; `branches`; `agents`; `limits` | #471 |
| The folded conversation's strip | `projects` (`lastWords`); sending to `projects`' current `conversation` | #471 |
| Now: Needs you | `needs` | #472 |
| Now: working, with model, time, last line, waking | `activity` (`lastLine`, `since`), `agents`, `wakes` (`wake`, `batch`) | #472 |
| Now: finished today, not yet read | `reports` | #472 |
| Lines with Undo, cards in the conversation | conversation state (`projectChanges`), `details.change`, `details.need`, `needs` | #474 |
| Agents tab | `agents` by `projectId`; templates (`agents` with none) | #475 |
| Rules tab and their cost | `projectRules`; `projects` (`ruleTokens`) | #476 |
| Notes tab | `memory` (`projects`) | #477 |
| Settings tab, Branches tab | `projects`; `usage` (`projects`); `branches` by the project's conversations | #478 |
| Work tab | `work`, or `github` | #479, #480 |
| Dashboard columns | `needs`, `activity`, `projects` (`lastWords`, `conversation`), `limits`, `local.running` (a model on this Mac answers one request at a time) | #481 |
| The menu bar item's count, the Dock's badge, notifications of what waits | `needs`, in place of the Inbox | #481 |
| Carrying over's report sheet; **Projects (preview)** | `projects.carryOver` `dryRun`; `projects.setPreview` | #470 |

The app sends `projects.watch` when it shows a project's Now or Work tab, and again when it stops (#472, #479); the engine forgets it when the app disconnects. Nothing about who is working is in the `projects` event, so it is not sent again whenever a run starts or ends (#446).

In a conversation of a project, the page shows the catch-up's and the state block's entries (6.4), lines with Undo, the reach and rule cards for the needs a tool call made, and, in another agent's conversation the person wrote to, a line "The orchestrator will be told" (an entry `pi2.toldOrchestrator`, written by the engine as the message is taken, #466).

For `scripts/test-copy` (#469): `PI2_SHOW=project:<name or id>` opens a project's hub, `project:<name>#now`, `#work`, `#agents`, `#rules`, `#notes`, `#branches` or `#settings` one of its board's tabs, `project:<name>#agent:<agent name>` an agent's conversation in place of the board, and `dashboard` the Dashboard. `PI2_HUB=both|conversation-folded|board-folded` sets how the hub opens. `test-copy fill <suffix> --project` fills a demo project through a development build's engine request, `test-copy.fillProject`, which also turns the preview on in that copy. `PI2_GH` joins `scripts/test-copy`'s allowlist, naming a stand-in `gh`.

## 11. What the engine cannot check

The engine enforces what goes through its own tools and requests. Three things lie outside them, and nothing in the epic may claim otherwise:

- **Who answered.** The engine takes an answer to what waits for the person only from the app (#504), and the person's settings only from the app too (#513), but it cannot keep a command from the data folder ([7.3](#73-who-answered)). An agent with a shell can still write there or start an engine of its own.
- **A command can do what a tool would ask about.** An agent with a shell can run `gh pr merge`, `gh issue close` or a release script. Under Ask first the command waits for the person as every command does, unless an allowed command or "Always Allow bash Here" covers it ([allowed-commands.md](allowed-commands.md)); with Full access or Allow everything, nothing asks. So `merge` governs merges made through pi² (`work` and the app), and its line on the settings page says so. The `project` section tells the orchestrator to merge and keep work only with `work`.
- **"Release" has no action in pi²**, so there is nothing for the engine to hold back. The switch is told to the orchestrator as the project's policy, and marked on the settings page as one pi² tells the agent but cannot check.

## 12. The later issues

### 12.1 Who owns what several issues share

Each piece below has one owner, which builds it, with what the others need of it from the start, so that the issues after it can be built side by side against it. "Until then" is what the pieces that come earlier see, so each issue is complete when it lands.

| Shared piece | Owner | Until then, and how others plug in |
|---|---|---|
| `projectsOn()`, `inProject(conversation)` (in a project, the preview on, the project neither archived nor deleted), the `projects` feature and its place in `FEATURES`, with the places after it for the others | #456 | Every other issue asks these two functions and adds its feature in its place |
| `pi2.projects`, the `projects` event and `ProjectRow` | #456 | `ruleTokens` is zeros until #459 fills it; `lastWords` null until #466; `carry` empty until #458 |
| `projects.setPreview`, and the refusal of new requests while off | #456 | #458 adds the carrying-over through one hook #456 leaves, `onPreviewOn(plan)`; until #458, turning on carries nothing over and a dry run answers an empty report |
| `requireSwitch` (8.1) and the Inbox's `projectSwitch` | #456 | Every tool a switch governs calls it (#457, #465, #467, #468) |
| `addNews` and `news` (storing) | #456 | #463, #464, #465, #467 add news from the start; #466 delivers it |
| `runsAs`, and every lookup of a conversation's agent through it | #457 | Until #457, a conversation runs as its `agentId` (no `projectAgentId` exists before #458) |
| `admit(start)` (8.3), project spending and limit answers | #464 | `delegate`, `work` `assign`, and the person's starts share `projectlimits.ts`. `reports` calls `reportPastLimit` at the end and again before a wake. #458 uses the same error envelope and checks any starts newly attributed by folder |
| The Needs you list: `needs.ts`, `claim`, `putNeed`, `withdrawNeed`, `onAnswer(kind, handler)`, the `needs` event, the wake kind `answer` | #462 | Each kind's handler belongs to the issue that puts it: reach (#465), proposed rules (#465, adding through #459's `addRule`), limit cards (#464), questions and decisions (#462). #464 and #465 wait for #462. Until a kind's handler is registered, an answer to it is refused and the item stays |
| Reports and `settle` (3.10), the watches' `wake` and `batch` | #463 | `delegate` and `sub_chats` call `settle` once it lands; until then they deliver as today |
| The catch-up and the state block, `compactionCheckpoint`'s addition | #466 | Until #466, news is stored and not delivered; the orchestrator reads reports with `reports` |
| The record of changes, `Op`, `record(op)`, `undo` | #465 | Notes' operations (#461) and work's (#467) record themselves through it when #465 has landed; whichever of the two lands after #465 does the wiring, and #465 wires those that landed before it, each saying so in its pull request |
| The work dispatcher, the table of 3.11, `WorkBackend`, the backend kept by pi² | #467 | #468 adds the GitHub backend behind the same interface |
| `pi2.github`, intents, `github.json`, `projects.watch` | #468 | — |
| The `project` section | #466 | Until #466, project conversations have no `project` section |
| The `project_rules` section | #459 | — |
| The `memory` section's project notes, `remember` and `forget` in a project | #461 | — |
| `activity`: `projectId` (#456), `runsAs` (#457), `lastLine` (#466) | as named | Absent until each lands |
| `library`: `projectId` (#456), `runsAs` (#457), `orchestrator` (#466) | as named | Absent until each lands |
| `scripts/test-copy`'s project commands, `PI2_SHOW` and `PI2_HUB` values, `PI2_GH` in its allowlist | #469 | — |
| **Projects (preview)** in Settings, the carrying-over report sheet | #470 | Until #470, the switch is turned on through the engine (`test-copy call`) |

**As #456 built them.** Every piece #456 owns is in `engine/src/projects.ts`, which says at its top which later issue fills in each place. What the table does not say:

- `projectsOn(): boolean`. `inProject(conversation: number): Project | undefined`, the project, or undefined outside one, with the preview off, or in an archived or deleted project. `projectOf(conversation)` gives the project whatever the preview and whether it is archived, for what holds with the preview off too (limits, `startAgents`); a conversation whose project was deleted is in none (#458), and `projectDeleted(id)` says so of a project. `allProjects()` gives a plain copy of every project.
- `requirePreview()` throws the refusal of section 2; every request new in the epic calls it first, but those section 2 allows with the preview off. `PROJECT_ARCHIVED` is the refusal of 4.1 for an archived project; `refuseInArchivedProject(conversation)` and `refuseStartWith(agent)` give it with the preview on, and `submit`, `continue` and `conversation.create` call them.
- `requireSwitch(conversation, name, what)`: `conversation` is the asking tool call, `{ conversationId, id, callId, tool, arguments, api, context }`, with `id` the Inbox item's (`String(api.taskId)`, as every approval's) and `api` the hook's or tool's (for `memo`). It answers `{ ok: true }`, or `{ ok: false, reason }` with what to tell the model when the person denies. It asks in a project whose switch is off, archived or not, with the preview on or off, and nowhere else: not in a deleted project's conversations, which are in no project (#458). `inbox.decide` takes only `once` or `deny` for such an item.
- `addNews(tx, projectId, { kind, text, ref, keep?, at? })` adds to `news` inside the commit `tx`, so a piece of news is stored with what it tells of, and answers the `News` with its id. An unknown project throws.
- `onPreviewOn(plan)`, `carryOverState()`, `ruleTokens(projectId)`, `lastWords(projectId)` are the bodies #458, #458, #459 and #466 replace; `emptyReport()` is the report of a run with nothing to do.
- `Projects` is the document's token, for a feature that changes it in a commit of its own; the `projects` event follows any commit that changes it, by anyone, and is sent only when what it holds changed.
- A project's orchestrator and its conversation are made in the one commit that makes the project. The default orchestrator's memory switch is set through a feature hook, `agentMade(agentId, { memory })`; a template copied as orchestrator goes through `agentDuplicated`, as `agents.duplicate` does.
- `agents.save` keeps `projectId`, `role`, `template`, `madeBy`, `updatedAt` and `removedAt` as stored, and checks a name against the templates, or against the agents of the same project. `agents.delete` refuses an orchestrator.
- A conversation takes `projectId` as it is made: from its agent (`conversation.create`, a schedule's run, Continue with an Agent), from its parent (a sub-chat) or from the conversation it forks.
- The engine's settings reach a feature through `engine.setting(key)` and `engine.saveSetting(key, value)` (`features.ts`), since the engine writes `settings.json` whole.

**As #467 built them.** `engine/src/work.ts` owns `Work`, `WorkBackend`, and the two backends' shared `checkWorkTransition` and `workTransition` functions. Local writes recheck the row in the committing transaction; for `assign` that commit also places the first input, starts the run, and saves its sub-chat watch and report (`stageReportRun` in `reports.ts`). Assignment follows the report as `delegate` with `wait: false` does, with the work item's number on it. Work news is saved in the same commit for #466 to deliver.

- The caller's identity uses `runsAs(meta, agents)` (#457), which falls back to `agentId` until #458 supplies carried-over copies.
- `assign` calls `requireSwitch` before starting. The normal start and a claimed limit card use the same `launchAssignment` in the assignment commit; the card keeps the task as it was asked for. The existing all-pi² budget still applies.
- `recordWork(tx, { projectId, action, by, before, after })` in `work.ts` is called on a change, in its transaction. #465 has wired it to `record(op)`: an agent's write is a change, `work.local`, with a line and Undo, and the tool's result carries `details.change`; the person's writes are not recorded.
- `githubWorkBackend(project)` in `work.ts` has no backend until #468 supplies it. Dispatch refuses an attached repository rather than writing to the project's local list; #468 also supplies the GitHub listing's `readAt` and the pull-request actions. The local `Work` document is available when checking for open work before attaching.
- The tool's `list` defaults to all open states. The person's `work.list` lists all items unless filtered; `close` needs an explicit `as`. The person can `note` through `work.act` as listed in 4.2. Optional text on `wait` or `block` adds a note, and reopening clears the result and `closedAt`.

**As #457 built them.** `runsAs` and `agentOf` are in `state.ts` ([3.4](#34-which-agent-a-conversation-runs-as-runsas)); the rest is in `engine/src/projectagents.ts`, which says at its top what later issues fill in. What the table does not say:

- Every lookup of a conversation's agent goes through `runsAs` or `agentOf`; a feature with the Host asks `host.agentOf(conversation)`, and whom a conversation may hand work to is `host.delegatesOf(conversation)` (`delegateTargets` in `projectagents.ts`, as [3.3](#33-agents-and-templates-pi2agents) and [5.1](#51-who-is-offered-what) say). Usage's spend by agent stays by `agentId`. `projectAgentId` is on `Meta` as a type, for #458 to set; a fork copies it.
- A feature saves an agent through `engine.saveAgent(input, { copiedRules?, project?, marks? })`, with `agents.save`'s checks: `project` makes a new agent in that project, in its folder, and `marks` sets `template` or `madeBy`. Copying a template is `projects.addAgent { template }`; #458's carrying over and #465's `make` copy through the same path.
- `agents.save` stamps `updatedAt` while the preview is on, and once any project exists whatever the preview; never while the preview has never been on.
- `agents.duplicate` of a project agent keeps it in the project, without `role` or `template`. "Keep at least one agent" counts agents of no project. `conversation.create` refuses an agent removed through a tool.
- `agents.updateFromTemplate`'s `setting` names are `AgentProfile`'s, from `TEMPLATE_SETTINGS`, and `memory` for the memory switch; values are compared as `agents.save` stores them. `apply: false` is allowed in an archived project.
- `removeAgent(id)` (#465's `agent.remove`) sets `removedAt`, refusing the orchestrator, an agent working now ("Forge is working on sub-chat 14. Wait for it, or ask the person to stop it.") and an archived project's agent. Nothing calls it before #465; `agents.restore` puts an agent back.
- `delegate`, in a conversation of a project, with the preview on or off: the approval hook asks through `requireSwitch` ("Start a new sub-chat with Forge, “Fix login”.", "Continue sub-chat 14, “Fix login”, with Forge.") while `startAgents` is off, and the tool calls `admit` as it makes or continues the sub-chat, answering "Not started: <reason>" when it is refused. `admit` decides `passLimits` and puts the card in that transaction. `delegate` uses `settle` through the reports helpers.

**As #459 built them.** The rules live in `engine/src/projectrules.ts`.

- `addRule(tx, projectId, { text, binds, addedBy })` validates and appends in the caller's transaction, returning the `ProjectRule`. The person's `projects.rules.add` calls it, attributing the rule to the person; #465's `project_rules` `add` (with `addRules` on) and the handler of an accepted proposal (on #462's cards) call it with agent or proposal attribution, after their own checks. The helper does not ask or make a card.
- `projectRulesPrompt` sits after `plan` in `FEATURES`. #466's `project` section goes between them; until then there is no `project` section. The rules prompt compares the agent the conversation runs as (`runsAs`, #457) to the project's `orchestratorId`.
- `projectRules` sits after `projects` in `FEATURES` for the greeting. It reads committed rules, including writes by `addRule` in another feature's transaction, and wires `ruleTokens` through `wireRuleTokens` in `projects.ts`. Estimates count the tagged section actually sent. The prompt keeps board order, repeating a heading if a binding recurs later in the order.

**As #461 built them.** Notes extend the existing `knowledge` feature in place in `FEATURES`, so the `memory` greeting and section keep their places. Project-only note storage and tool operations live in `engine/src/projectnotes.ts`.

- `Memory` and `MemoryDoc` (`knowledge.ts`) and `projectNotebook(doc, projectId)` (`projectnotes.ts`) are for #458 to write carried notes in its own commit. Until then nothing is copied from an agent's notes. `knowledge` sends the `memory` event for a commit to that document by any feature, including carrying over or Undo.
- `memoryAgentId(conversation)` in `knowledge.ts` is the agent the conversation runs as (`runsAs`, #457). A sub-chat runs with the notebook of its own agent, not the parent's; a template in a project-marked conversation is not given the project's notes.
- `recordNoteChange(tx, projectId, { by, op, inverse, summary })` in `projectnotes.ts` is for #465. The tools already form `note.add` and `note.remove` and their inverses in the note's transaction. #465 has wired it to `record` (see below): each note added or removed through a tool has `details.change`, a line and Undo. The request and tool paths share the project's lifecycle checks and note add/remove helpers.

**As #462 built them.** Needs you is `engine/src/needs.ts`, which says at its top what the later issues fill in. What the table does not say:

- `claim(id, answer)` takes the answer as well as the id: it checks the answer against the item and takes the item in one step, so a refused answer leaves it waiting. An Inbox item is taken with `Inbox.take` (`state.ts`), which answers the waiting call; a stored one in one commit. `main.ts`'s `inbox.decide` and `inbox.answer` call it, and so does `needs.answer`. A second answer by any route gets "This is no longer waiting: it was answered or withdrawn." in place of the old "That request is no longer waiting". An approval is checked as `inbox.decide` checked it, so that today's approvals work as before: `rule` only where a rule was offered, only `once` or `deny` with `projectSwitch`, and `always` taken where its `answers` leave it out (a schedule, a browser action with no site), which the tool counts as once, as it always has.
- `putNeed(tx, need)` puts a need in the commit `tx` that makes what it is about, and answers the stored item; the same `callId` again gets the one already put. The project must exist and not be deleted. `withdrawNeed(tx, id)` takes one off without an answer and answers it, or undefined. `needsIn(tx)` is the document in a commit; `storedNeeds()` a copy of what is stored.
- `onAnswer(kind, handler)` registers what an answer to a stored kind does: `handler(tx, need, answer)` runs inside the commit that takes the item. Throwing refuses the answer and stores nothing; `{ keep: true }` puts the item back as the handler left it (the limit card that stays with a new reading); `{ after }` runs once the commit is made. #465 registers `reach` and `rule` (changes.ts) and #464 `limit`; an answer to a kind with no handler is refused ("pi² cannot act on an answer to … yet") and the item stays.
- `ReachChange.op` is `unknown`, as what is stored; changes.ts (#465) reads it as its `Op`. The `pi2.needs` token is a plain JSON object's for that reason.
- An item's `agentId` is the agent its conversation runs as (`agentOf` in `needs.ts`, through `runsAs`, #457).
- Questions and decisions wake the conversation that asked through `arriveIn(tx, conversationId, item)` and `arrivedIn(conversationId)` in `wakes.ts`, the wake kind `answer`, keyed `answer:<id>`: stored in the commit that takes the answer, so it is given once, after a restart too.
- The `needs` event is `{ event: "needs", items: [] }` with the preview off; with it on, the Inbox's items and the stored ones, oldest first. Two feature hooks send it again: `inboxChanged` whenever `main.ts` sends the `inbox` event, and `previewChanged(on)`, which `projects.setPreview` calls. The menu bar item's count and notifications (#481) count its items.
- `needs_you` is offered by agent, since a feature's `toolNames` is not told the conversation: to a project agent of a project neither archived nor deleted, with the preview on, outside a sub-chat, whatever its access. The tool checks the conversation itself as well.
- A conversation archived or deleted, itself or its root, takes its stored needs with it (`putAwayChanged`), and so does a project deleted (read from any commit to `pi2.projects`).

**As #463 built them.** Reports and waking are in `engine/src/reports.ts`, with what it changed in `wakes.ts` ([wakes.md](wakes.md#in-a-project)). What 3.10 and 5.6 do not say:

- `settle(tx, submissionId, ask)`, where `ask` is `{ by: "end", outcome? }`, `{ by: "wait", conversationId, again? }`, `{ by: "read", conversationId }` or `{ by: "wake", conversationId }`, inside the commit that does it; it answers `{ give, to?, wake }`: for a wait, a read or a wake whether the report is given now, and at a run's end the conversation to wake and the reports the wake carries. A run with no report is given as today. `again` is `delegate` waiting for its own run: run again after a crash, it gives the report it already took.
- A run has a report when `delegate` starts it (new or continued, waited for or not) from a conversation that is a project's orchestrator's, now or earlier, with `inProject`: `reportRun(parent, run)`. `work` `assign` (#467) stages it in the start's transaction through `stageReportRun(tx, projectId, run)` with `work`, then follows it through `reportRun`. `delegate` waiting goes through `waitForRun`. The report's run is followed by reports.ts, not by wakes.ts.
- What wakes nobody: a run with no watch (`delegate` waited for it, or the person's Don't Wake or archiving let the watch go). A batch's `all` is decided when its last run ends, by that run's watch.
- At a run's end, a report not delivered then adds a `report` piece of news, `at` the run's end, with the sub-chat as `ref` and the line of 6.4; delivering the report takes that piece away, so #466's catch-up never names a report already given. None is added while `delegate` waits for the run.
- `reportPastLimit(tx, projectId, conversationId)` is checked by `settle` both at the run's end and in the commit that would submit the wake. It uses the receiving conversation's model. When true the report stays unread; other wake items, including the person's answers, can still wake the agent.
- The `wakes` event's `wake` and `batch` are the watch's own, as stored (null when absent), not the choice in effect; `projectId` is the project of the conversation woken, or null.
- `reports` is offered by agent, since a feature's `toolNames` is not told the conversation: to the orchestrator agent of a project in the preview, outside a sub-chat. Called from another conversation of that agent, it refuses: "reports is for the project's orchestrator, in its current conversation." A `read` run again after a crash gives what it gave, kept with the call (`pi2.reportsGiven`, a task document). `wake` is a change in #465's record of changes, `wake.choice`, with a line and Undo, and `details.change` on its result; the person's `reports.wake` is not recorded.
- `sub_chats`' list does not say "its answer will come to you as a message" of a run whose report will not wake the agent.

**As #466 built them.** The orchestrator's one conversation, what it is told and Start fresh are in `engine/src/orchestrator.ts`, which says at its top what a later issue fills in; it touches the files of others only at the seams below. What 6.1 and 6.3 to 6.6 do not say:

- **Where the catch-up is made.** pi durable places every input through one function, `appendInput`: the person's message that starts a run, a wake, a queued message or a steer placed at a boundary. A patch to it (`engine/scripts/patch-inputs.ts`) calls a setting of the engine's, `placeInput(tx, conversationId, now)`, in the commit that places the input, before its entry; `placeInput` in orchestrator.ts appends the catch-up or the state block there and clears the news it gives in the same commit. It does nothing with the preview off or in any conversation that is not a project's current conversation with its orchestrator, so a conversation in no project is placed exactly as before. A hook there may append entries and change documents; it must not read tables (`tx.entry`, `tx.scanEntries`), which a commit that has already written cannot do.
- **The entries.** `pi2.catchUp { news }` and `pi2.state { snapshot }` carry their text as a user message, which the model reads just before the input. The transcript shows them as folded lines that open to that text, as a wake's do: "pi² told the orchestrator what changed (2)" and "pi² told the orchestrator how the project stands" (`details.wake.text`). `pi2.toldOrchestrator { news }` is display only: "The orchestrator will be told".
- **Which conversation gets a state block.** One marked new in the commit that makes it (a conversation document, `pi2.orchestratorFresh`): the project's first conversation (`projects.create` calls `wireFresh`'s mark) and every one Start fresh or `setOrchestrator` makes. A conversation that becomes a project's otherwise (carried over, #458) gets catch-ups. A project whose conversation was deleted, or one carrying over made with the default orchestrator (#458, which makes no conversation for it), gets a new one with `projects.startFresh`, which is allowed then and makes one beginning with the state block; nothing else makes one.
- **Room.** The 200 pieces kept besides `keep` are counted when the news is given, not as it is stored: the catch-up drops the oldest past 200 and says how many. `addNews` and `settle` store every piece.
- **The state block's parts.** `working` is every sub-chat of the project working now (`host.working`); its `since` is when this engine first saw the run working, or the sub-chat's `updatedAt` for one working when the engine started; a wait for a limit reads "waiting for its provider's limit until 15:30". `needs` is the `needs` event's items for the project (approvals and `ask_user` questions as the Inbox holds them now). `reports` is read from `pi2.reports` in the same commit. `work` is read from #467's list kept by pi² (`pi2.work`): the four open states counted, and every item in progress, waiting or blocked with who took it; a project with no open work says "Work: none.". #468 gives a project with a repository attached its own through `wireWorkState(read)`, where `read(tx, project, local)` answers `{ counts, held }` and may hand any project back to `local`. A summary's block is made in the summary's commit (`summaryState`, called by `compactionCheckpoint` last) and clears no news.
- **What the person writes to another agent.** `submit` to a conversation in a project in the preview, other than its current conversation with the orchestrator, takes the message in a commit with a `message` piece of news (`keep`) and the `pi2.toldOrchestrator` line (`tellOrchestrator`, main.ts); the same `requestId` again is told once. Outside that, `submit` is unchanged. Only `submit` tells: a message `delegate` sends a sub-chat is the orchestrator's own doing.
- **Start fresh.** `startFresh` and `setOrchestrator` share one function. Refused, in this order: "Answer what the orchestrator is waiting for first." (an approval or an `ask_user` question of that conversation in the Inbox), "Send or take back your queued message first.", "The orchestrator is answering. Let it finish, or stop it, first." (the last two read in the commit). `setOrchestrator` refuses the agent that is the orchestrator already. Neither calls `admit`: a conversation made empty starts no run. The commit moves the old conversation's watches (a background command's label gains ", started in your earlier conversation"), its `arrived` wakes, its wakes of the last hour and a hold for the hourly cap; the features' `created` hooks run for the new conversation afterwards, as for `projects.create`; a wake that was waiting is then handed over at once.
- **Answers to what an earlier conversation asked.** `answerGoesTo(tx, conversationId)` gives the current conversation for an earlier one, with the preview on. Questions and decisions (needs.ts) use it, and say "(You asked this in your earlier conversation, 12.)"; #464's and #465's handlers for `limit`, `reach` and `rule` should use it too.
- **Earlier sub-chats.** `earlierOf(conversation)` and `ownsSubChat(caller, parent)` are what `sub_chats` (list, archive, wait), `delegate` with `chat` (and #464's `checkChild` for a continue held by a limit), its approval and `unreadReports` ask. An orchestrator's `sub_chats` list ends each line with whether the sub-chat's last report was given (`latestReport` in reports.ts).
- **What the apps are sent.** `library` rows have `orchestrator` and also `freshFrom` (null, or the conversation it followed), which the link back needs; `orchestrator` is kept from the commits to `pi2.projects` themselves, and the library is sent again when it changes (`engine.libraryChanged()`, new in `features.ts`), with the states of the conversations it changed. The conversation state's `project` and Activity's `lastLine` are added only for a conversation of a project; any other's state and Activity row are as before. `lastLine` and `lastWords` are read from the commits: an answer's text as it is stored, and a finished answer (`stopReason` stop or length) of a project's current conversation; `lastWords` is read again from the transcript when the engine starts. `projects.ts`'s `lastWords` is supplied through `wireLastWords`.
- **The `project` section** comes from `projectPrompt` in orchestrator.ts, placed in `FEATURES` before `projectRulesPrompt`. A line about a tool is there only while the conversation is offered it (`work`, `project_agents`, `project_settings`, `project_rules`, `reports`, `needs_you`), so it says nothing of #465's and #467's tools until they land, and changes once, in place, when they do.

**As #464 built them.** `projectlimits.ts` uses the same last good `planLimits()` readings as Usage; it never asks the provider. With the preview off it refuses over-limit starts without a card, even if `passLimits` was on.

- `admit(start, confirm, { tx, model, callId?, card? })` runs after any switch approval, inside the start's transaction. A refused tool returns without starting so its card and news can commit; its task receipt prevents a replay from asking or starting again. A person gets `limitError(limit)` (`RequestError` in `requesterror.ts`); #458 can throw `new RequestError(message, data)` through the same socket and app seam. The no-reading or pass-limit `note` goes with the start's result.
- `confirmLimit` is an opaque, short-lived receipt for the exact start and model. It is spent once; every currently exceeded window or budget must be covered. If more than one reading needs approval, the next refusal carries the next reading and remembers the earlier approvals for that start only. A reset plan window is not a reading of its next period.
- `projectlimitstarts.ts` registers the `limit` answer. `claim` keeps the card with its new reading if the confirmed reading no longer covers the start. A continued or new delegate hand-off uses the retained options and a durable `pi2.allowedStarts` receipt, replaying the same request id after a restart. The old tool call is no longer waiting: its result comes through the report/watch. `onLimitAssignment` lets the active work backend claim and submit a held assignment in the answer's transaction. Limit answers add news, not a wake of their own.
- `projectspend.ts` keeps per-conversation deltas in the existing Usage ledger. Admission sees committed counters, not just the coalesced Usage event; `usage.projects` groups today's amounts by library `projectId`, including archived and deleted conversations of a live project. The old ledger only has a global amount, so the first run after upgrading cannot recover its already-counted per-project shares; it uses the existing totals as its baseline.
- Conversation creation, Continue with an Agent, scheduled starts, and assignments check limits at their creation boundary. The person's messages and retries in existing conversations are unchanged. A start with a template that carrying over will put into its folder's project (9.9) passes that project as `site.projectId` (#458, `carriedProjectFor` in carryover.ts). #467's local assignment is wired; #468 must use the same admission seam for GitHub assignment before claiming it.

**As #465 built them.** The record and its operations are `engine/src/changes.ts`; what widens reach, `engine/src/reach.ts`; the three tools, `engine/src/projecttools.ts`. What the table does not say:

- `record(tx, projectId, { by, op, inverse, summary })` records a change in the commit that makes it, and answers it with its `id`. A change the orchestrator did not make in its own conversation is news for it (`addNews`, kind `change`, ref `change:<id>`), but for one the person allowed, whose conversation is told itself.
- Each kind of operation has its check, how it is applied, its inverse, and whether an agent applying it widens reach, registered with `defineOp(kind, rules)`. `agent.*`, `project.change`, `rule.*`, `note.*`, `orchestrator.set`, and the operations of the issues that landed before #465, `work.local` (#467, through `recordWork` and `recordWorkChange`) and `wake.choice` (#463, through `wakeChoicesIn` and `setWakeChoicesIn` in reports.ts), are registered there. **#468 registers `work.github`**, with no inverse, and records it with `record`; until then no change of that kind is recorded, and an Undo or a request of one is refused ("pi² cannot make this change yet."). `afterChanges()` is run once a commit that applied operations is stored, for what reads its document back only after its own commits (wakes.ts).
- `checkOp(tx, projectId, op)` says why an operation cannot be applied now (the project gone or archived; the target not what it expects, `CHANGED_SINCE`), `applyOp` applies it, and `undoIn(tx, id, by, who)` undoes a change. `changes.undo` is the person's, recorded with `by: { kind: "person" }`.
- Each operation is applied by the person's own validator, in the caller's commit: `engine.saveAgent` takes one (`tx` in its options); `removeAgentIn(tx, id)` is `removeAgent` in a commit; `applyProjectChange(tx, id, { name?, folder?, settings? })` is what `projects.rename` and `projects.set` do; `editRule`, `moveRule`, `removeRule` and `putBackRule` (projectrules.ts) are what `projects.rules.*` do; `putBackProjectNote` puts a removed note back with its id.
- `orchestrator.set` is made by #466's `projects.setOrchestrator`, which makes the roles and the fresh conversation in a commit of its own, so it cannot be made inside the commit that takes the answer, as 7.2 has every allowed change made. The narrowest that works: that commit checks the request as any other (and keeps it, "The orchestrator is answering or waiting for you. Let it finish, or stop it, first.", while its conversation works or waits); once it is stored, `projects.setOrchestrator` makes the change, which is then recorded, with no Undo, and the fresh conversation is told. If Start fresh refuses at that moment (the orchestrator began answering meanwhile), nothing is changed, the person is told why, and the request is gone: they can make the change themselves.
- `askReach(tx, { projectId, conversationId, callId, change, why })` puts a reach request, or answers the one waiting for the same change; `reachOf(op, summary, undoes?)` gives a request's target and fields from its operation. The handlers of `reach` and `rule` are registered as the engine makes the feature, so a test of needs.ts alone still sees them unregistered. The answer goes to the conversation that asked as a wake of kind `answer`, as a question's does, or to the current conversation for one asked in an earlier one (#466's `answerGoesTo`). Allowing a request whose target has changed takes it off the list, tells that conversation, and answers the person with `ASKED_CHANGED`.
- `ReachChange.op` stays typed `unknown` in needs.ts, as what is stored; changes.ts reads it as an `Op` (`Reach`) and checks it again when it is allowed.
- The tools are offered to the project's current conversation with its orchestrator (`toolNames`' `conversationId`, which #467 added), with the preview on, in a project neither archived nor deleted; a conversation not made yet, to its agent if it is the orchestrator, outside a sub-chat. Each refuses any conversation but that one, and a change without Ask first or Full access.
- `repository` in `project_settings` `change` is refused until #468 ("pi² cannot attach a repository to a project yet"), which makes it a reach request, as 7.1 says. `show` gives the limits as set, not how they stand now (today's spending, the plan windows): projectlimits.ts (#464) keeps no reading a tool can give, and adding one is left to an issue of its own.
- A copy of a template made by an agent is made at the baseline, and asks for the template's memory switch, allowed commands, delegates and the rest that widen in its one request. It is not given the variables' names, which are the person's.
- `remember` and `forget` in a project, `work` and `reports` `wake` answer with `details.change` and give the conversation a line with Undo, but their text is as before, without "(change N)" at its end: the person can undo them, and the orchestrator cannot name them to `project_settings` `undo`. Only the three tools' results end with the number.

**As #458 built them.** Carrying over is `engine/src/carryover.ts`: `groupingKey` (and `Grouping`, which works each path out once for a plan), `lookUp`, `planCarryOver(snapshot, only?)`, `fingerprint` and `reportOf` are plain functions of the documents (and of the `.git` entries on disk), and the `carryOver` feature, placed after `orchestrator` and before `projects` in `FEATURES` with no greeting, runs them. What section 9 does not say:

- It plugs into projects.ts through `wireCarryOver({ previewOn, state })`, which `onPreviewOn` and `carryOverState` call, and reads the record through `carryRecord()`. Without the feature (a stand-in engine in a test) turning on carries nothing over, as before.
- A request refused with data throws `RequestError(message, data)` (`requesterror.ts`, #464's); the engine answers `{ id, error, data }` (4.1). A plan that is not the one given, or no plan when there is something to do, is refused with the new report as `data`, `setPreview` turning nothing on.
- **Only a template-backed conversation of a deleted project falls back to no project**, with the preview on or off (3.6). `projectOf` keeps the project for a conversation whose own agent belongs to it; `runsAs` still gives the conversation's own `agentId`, not a deleted project's copy. `inProject` leaves out deleted projects when preparing the prompt and tools. `refuseStartWith` and the delegate tool stop starts with a deleted project's own agents; those agents cannot delegate. `previewOnLeavingOut` (`engine/test/patience.ts`) carries over and then deletes the projects so the existing tests' template-backed conversations are in no project.
- Copies are made inside the project's own commit, by copying the template's stored profile as `projects.create` copies one (3.3's differences, the memory switch and the variables' names written in the same commit), not through `engine.saveAgent`, which commits on its own: a run cut off part way must never leave a copy without its project. So the features' `agentDuplicated` hooks are not run; only knowledge.ts's and variables.ts's exist, and their part is done in the commit. A comment at the hook in features.ts says so, and carryplan.ts fails when another feature adds one. The copy takes Allow everything, the variables' values and the memory switch as the plan has them, and the commit stops with `CHANGED_DURING` when the template has gained one since (9.5). `worktreeOff` is worked out without running git, with the same home-folder boundary as the grouping (9.2).
- The variables' values: `copyAgentValues(from, to, names)` in variables.ts copies a value only while the copy still lists that variable with no value, in the Keychain or the profile, so a value set since is never overwritten and a variable removed since is not brought back; the value goes into the Keychain before the profile says there is one. A pending copy whose template or copy has been deleted is taken off the list, there being nothing to copy.
- Test switches: `PI2_CARRY_SECRETS_GATE` holds the Keychain step, and `PI2_CARRY_COMMIT_GATE` the run before each project's commit but the first, while the file it names exists (having written `<file>.started`), so a test can kill the engine there.
- Notes are recorded per project, in the commit that copies them (9.7), so a run cut off part way leaves a whole record of what it did. Where the same text for the same audience is in a project already (a note shared since, say), it is not copied twice, and the record points at the note that has it. A carried note's `agentId` is the copy's for a note the agent wrote, null for one the person wrote.
- A sub-chat made since in a conversation already in a project, with no `projectId` of its own, goes into that project; a sub-chat of a deleted conversation is counted with the deleted ones (`leftOut.deleted`).
- The watches' `wake` (9.1) is not written: a run handed over before carrying over has no report, so it wakes as [wakes.md](wakes.md) says, and a carried project has `wakeOnReports` on, which #463 reads as `each`, for runs started afterwards.
- No conversation is made for a carried project's default orchestrator (9.6): `conversation` stays null, for any such project, archived or not, until the app calls `projects.startFresh` (#466) as the person first opens or writes to the orchestrator. Restoring a project makes none either. So nothing carrying over makes needs `markFresh`: the conversation `startFresh` makes is marked by it.
- Conversations made later (9.9): a feature hook, `made(id)` (features.ts), is told of a top-level conversation of an agent made by `conversation.create`, `conversation.fork`, a schedule's run or Continue with an Agent, before its first message, and carries it with the plan for that conversation and its sub-chats, in a commit after the one that made it. It makes no backup and does not set `ranAt`. A failure is logged and starts a sweep of the conversations left without a `projectId`; it also runs once every feature has started (`host.ready`). Both sweeps require the preview on and a recorded run (9.9). Before the conversation is made, `carriedProjectFor(agent, cwd)` gives `admit` the project it will go into (`lookUp` on the stored projects), and main.ts's three starts pass it as `site.projectId`; a schedule refused by it waits a minute before it is tried again, as one of a project's agents does.
- **The old screens and project agents.** 10.2 has the app leave agents with a `projectId` out of the agents' list, the New Conversation With menu and the palette. The app as it is before #470 does not: with the preview off, after a run (through the socket, `test-copy`, a script), every copy and orchestrator is in its agents list under its template's name, and can be edited, deleted and picked for a new conversation, which then goes into its project. Only #470, which ships that filter with the switch the person turns the preview on with, makes 9.11's "project agents are left out" true; nothing in the app turns the preview on before it.

**As #468 built them.** Work from GitHub is `engine/src/github.ts`: the GitHub backend, the pull-request actions, `pi2.github` and its intents, `github.json`, `projects.watch`, the `github.*` requests and the `github` event. It touches the files of others only at the seams below. What 3.11 does not say:

- **The seam with work.ts.** github.ts plugs in through `wireGithubWork({ backend, readAt, listingNote, pull, assignHeld })`; `githubWorkBackend(project, writing)` gives the backend, with the tool call, the switch already asked about and, for `assign`, a `GithubAssign`: `admit(tx, project, item)`, the admission check of #464 in a commit of its own, and `start(tx, project, item, admitted)`, which starts the sub-chat without checking again. work.ts exports what both backends share: `checkWriterIn` (who may write, in a commit), `workReceipt` and `workReceiptOf` (what a `work` call did, kept with its task, now with `text` for a pull request's action), `workNews` and `workNewsText`, `orchestrates`, `canWrite`.
- **An assignment on GitHub** cannot claim and start in one commit. It is admitted first, then claimed ("Taken by", and the race check), then started; a start refused after the claim lets the claim go ("Released"). The person's `confirmLimit` is spent by the one admission. A limit card's Start Anyway is checked in the card's commit and claims and starts once that is stored (`onLimitAssignment` answers `child: null` for GitHub); if the claim then fails, the orchestrator is told in its catch-up.
- **News.** An action of the orchestrator's own, in its current conversation, adds no news for it, for either kind of list (`workNews`): #467 added it for every action.
- **Intents** are made one for each `gh` write, with ids from the call's id, so a call run again finds them. The labels of `scripts/issue` are made when the repository lacks them, once per repository while the engine runs, without intents: `gh label create --force` twice makes nothing twice. Intents done or failed are kept, the newest 2,000 per project, for knowing who posted each comment; pending and unknown ones are always kept. Pending intents are looked for when the engine is ready and after each listing read.
- **`--repo`.** `gh repo view` takes no `--repo`; it is given `owner/name` as its argument. A gh that fails is read by what it printed: the rate limit, not signed in (`gh` missing too), unreachable (it never reached GitHub, so a write is failed), unclear (a timeout or a reset: looked for, then unknown when not found), or refused.
- **The listing** reads open issues and pull requests, and those closed in the last seven days with `--search closed:>=<date>`. `state` is `loading` until a project's first read. Any `gh` that meets the rate limit, a sign-out or no network, a write's or `show`'s too, sets `state` and `error`; the next listing read clears them. An agent's `list` and `show` end with a line saying when the listing was read and why it is not newer; `show` reads the issue afresh, and gives the cached one when GitHub cannot be asked.
- **`projects.watch`** is kept per connection: a feature's handler is given the connection that asked (`handlers[method](params, connection)`), and a feature's `disconnected(connection)` is told when it closes (features.ts, main.ts).
- **Comments.** `wait` and `block` with text post "**Waiting:** …" and "**Blocked:** …"; `finish` and `close` post "**Done.** …" or "**Dropped.** …"; a review, "**Approved.**", "**Changes requested.**" or "**Comment.**" and the finding; Send back, "**Sent back.**" and the reason. Notes leave out pi²'s "Taken by", "Released", "Done." and "Dropped.". Who posted a comment is read from its intent: a comment whose intent is no longer kept reads as the person's.
- **Send back** gives the conversation that opened the pull request an input with the entry `pi2.sentBack { by, number, reason }` (`githubItem` draws its line, through main.ts's `toItem`), queued if it is answering; one archived or deleted is not given it, and the answer says so. The person's Send back and merge are news for the orchestrator.
- **Attaching.** `setRepositoryIn(tx, projectId, repository | null)` is what `github.attach` and `github.detach` do, and what `project.change`'s `repository` field applies (changes.ts, through `wireRepository`), first among its fields. `project_settings` `change` with `repository` asks `gh` for it before its commit, then puts it to the person as a reach request; detaching (null) is one too. `checkRepository` and `parseRepository` are for that.
- **The state block** reads a project's GitHub work from the cached listing (`wireWorkState`), as 6.4 says it for the list kept by pi².
- **`work.github`** is registered with no inverse; an agent's write on GitHub is one change per action, its summary such as "Took #12 “Fix login” on GitHub". The person's are not recorded.
- **Tests.** `PI2_GH` names `engine/test/gh-stand-in.mjs` through a small script (development.md says how); every test that could reach `gh` sets it.

### 12.2 Each issue

What each issue builds of this contract, and whether the contract changes its scope. The issues' texts are not edited by this page: once the owner has agreed it, the agent that hands out the work edits those marked changed, saying how, as the epic's roadmap says, before handing any of them out. An issue builds the engine side of what it names unless it is an app issue (#470 on).

| Issue | Builds | Scope |
|---|---|---|
| #456 the project, its requests, the preview switch | [2](#2-the-preview-switch); [3.1](#31-where-things-are-kept), [3.2](#32-the-project-pi2projects) with `news` stored; of [3.3](#33-agents-and-templates-pi2agents), the fields that mark a project agent and the default orchestrator; of [3.5](#35-conversations-pi2library), `projectId`; [3.6](#36-archiving-and-deleting); the project requests of [4.2](#42-requests) but `setOrchestrator`, `startFresh`, `carryOver` and `retrySecrets`; the `projects` event; `library`'s and `activity`'s `projectId`; `agents`' fields; [4.4](#44-what-an-app-is-sent-on-connecting)'s order; `requireSwitch`; the stub of `admit`; [section 8](#8-settings-without-asking-waking-limits)'s settings stored and checked | **Changed.** It makes each project's orchestrator as a project agent, and its empty conversation. With the preview off it refuses only new requests. It owns the pieces of [12.1](#121-who-owns-what-several-issues-share) named for it. Its tests switch the preview off and on after each operation of [3.6](#36-archiving-and-deleting) |
| #457 agents of a project, templates | [3.3](#33-agents-and-templates-pi2agents), [3.4](#34-which-agent-a-conversation-runs-as-runsas); the agent requests; `runsAs` in `library` and `activity`; `delegate` naming the project's agents and calling `admit` | **Changed.** Templates are the agents with no project. `runsAs` replaces every lookup of a conversation's agent, at once. A project agent's folder is the project's for new conversations only. Removing through a tool is `removedAt`, with `agents.restore` |
| #458 carrying over | [section 9](#9-carrying-over); `carry` in [3.2](#32-the-project-pi2projects); `projectAgentId`; `projects.carryOver`, `projects.retrySecrets` and the run behind `setPreview` | **Changed.** One plan for report and run, with its fingerprint; lookup, adoption and tie-breaks (9.3 to 9.5); the variables' values copied in a step that is retried; notes carried over too, with their audience (9.7, moved from #461); conversations made later (9.9). "Can be undone" is the backup and the preview switch, described as what they are. Waits for #461 as well, for the notes' document |
| #459 rules | [3.7](#37-rules-pi2projectrules); `project_rules` in [6.1](#61-the-sections); [6.2](#62-what-the-rules-cost); the rule requests; the `projectRules` event; `ruleTokens`; `addRule` for #465 | **Changed.** Requests are `projects.rules.*`. A rule binds the orchestrator or everyone, and order ranks nothing. Proposing a rule is #462's card and #465's tool. No sentence is added to the summariser's instructions |
| #460 allowed commands | Landed: [allowed-commands.md](allowed-commands.md) | Done. Nothing in the contract depends on the preview for it |
| #461 notes of the project | [3.8](#38-notes-pi2memory) with `audience`; `memory.*` with `projectId`; the `memory` event's `projects`; the `memory` section's change; `remember` and `forget` in a project, with their operations | **Changed.** Carrying today's notes over moves to #458. Notes have an audience. `remember` and `forget` are changes with a line and Undo |
| #462 Needs you | [3.9](#39-needs-you-pi2needs-and-the-inbox); the Needs you requests; the `needs` event; `needs_you` ([5.5](#55-needs_you-the-orchestrators-and-agents-own-conversations)); `claim` for every route; the wake kind `answer`; `projectSwitch` in the event | **Changed.** Six kinds, stored and sent as separate unions with one answer shape. Each kind's effect is registered by the issue that puts it. `needs_you` is not offered in a sub-chat, a known gap. Allow everything answers no kind but approvals without `projectSwitch` |
| #463 waking | [3.10](#310-reports-and-waking-pi2reports-pi2wakes) with `settle`; `reports` ([5.6](#56-reports-the-orchestrator)); `reports.wake`; the `reports` event; `wakes`' fields; [8.2](#82-when-a-report-wakes-the-orchestrator) | **Changed.** Reports are by run (submission), delivered once by one function. The orchestrator's choice is `reports`, not `delegate`'s parameters. Waking for the whole project is the person's switch. Past a limit, no report wakes the orchestrator (with #464). Undelivered reports reach the orchestrator through #466's catch-up |
| #464 limits | [8.3](#83-limits-and-the-one-admission-check): `admit`, the `limit` card's handler, the person's confirmation; `usage`'s `projects`; holding reports' wakes past a limit | **Changed.** One check for every start, the person's included, at the moment of starting, with a one-shot confirmation. Waits for #462 too, for the card. Limits hold with the preview off. A carried-over project has none |
| #465 the orchestrator changes the project | [3.12](#312-the-record-of-changes-pi2changes); [5.2](#52-project_agents-the-orchestrator), [5.3](#53-project_settings-the-orchestrator), [5.4](#54-project_rules-the-orchestrator); [5.9](#59-every-change-in-the-hub-its-tool-whether-it-asks-and-its-undo); [section 7](#7-reach-what-an-agent-can-only-ask-for); the reach handler; `projectChanges`; `changes.*` | **Changed.** Changes are typed operations with their own inverses; some have none, and say so. Every setting is classed, and an unnamed one counts as widening. Making another agent the orchestrator is a request with no Undo. Its tests must not claim more than [7.3](#73-who-answered) |
| #466 one conversation, Start fresh | [6.3](#63-why-the-projects-state-is-not-a-section) to [6.6](#66-what-switching-the-preview-off-leaves-in-a-conversation); delivering `news`; `freshFrom`; `library`'s `orchestrator`; the conversation state's `project`; `activity`'s `lastLine`; `projects`' `lastWords`; `pi2.toldOrchestrator`; `projects.startFresh`, `projects.setOrchestrator`; `sub_chats` across earlier conversations; the `project` section | **Changed.** The state is a catch-up and a state block, typed entries with ids, not a section. Start fresh says what becomes of everything pending, or is refused. It also builds the `project` section, `lastLine` and `lastWords` |
| #467 work kept by pi² | [3.11](#311-work-pi2work-pi2github-githubjson)'s items, state table, dispatcher and `WorkBackend`; the backend kept by pi²; `work` but its GitHub actions; `work.list`, `work.create`, `work.act`; the `work` event; its operations | **Changed.** One state machine for both kinds of list, with `release` and `resume`; `assign` claims and starts as one step; `work.act` in place of a request per action; the access needed for each action ([5.1](#51-who-is-offered-what)) |
| #468 work from GitHub | The GitHub backend; pull requests; `pi2.github` and its intents; `github.json` by repository; `projects.watch`; the `github.*` requests; the `github` event; `PI2_GH` | **Changed.** `--repo` on every command; a fork's head; intents with reconciliation and a reported unknown; Send back as its own input; `openedBy` kept durably. States and classes are `scripts/issue`'s labels. For an agent, attaching is a reach request |
| #469 throwaway copies that show a project | [10.3](#103-with-the-preview-on)'s last paragraph | **Changed.** The names are this page's, and it adds `PI2_GH` to `scripts/test-copy`'s allowlist, for #480 |
| #470 the sidebar lists projects | [10.2](#102-with-the-preview-off); its rows of [10.3](#103-with-the-preview-on); **Projects (preview)** and the carrying-over sheet, listing the copies that take secrets | **Changed.** It also builds the switch and the sheet, being the first app issue, and lists a project's other conversations under it |
| #471 the hub's two panels | [10.1](#101-what-the-app-keeps-itself); its rows of [10.3](#103-with-the-preview-on) | **Changed** only in that the strip reads `lastWords` |
| #472 the Now tab | Its rows of [10.3](#103-with-the-preview-on); `projects.watch` | **Changed** only in that it sends `projects.watch` |
| #473 an agent's conversation in place of the board | `pi2.toldOrchestrator` | Unchanged |
| #474 changes with Undo, reach requests in the conversation | `projectChanges`, `details.change`, `details.need`, the reach and rule cards ([7.2](#72-asking-allowing-refusing)) | **Changed** only in that a change with no Undo is drawn without it, saying why |
| #475 the Agents tab, templates | [3.3](#33-agents-and-templates-pi2agents); the agent requests; [8.1](#81-what-the-orchestrator-may-do-without-asking)'s switches | **Changed.** Templates are managed with today's agent pages, for agents with no project. A switch the person turns on by hand asks them to confirm in the app; a reach request is only for agents. Removed agents are listed apart, with Restore |
| #476 the Rules tab | [3.7](#37-rules-pi2projectrules), `ruleTokens`, `projects.rules.*`, the rule card | Unchanged |
| #477 the Notes tab | [3.8](#38-notes-pi2memory), `memory.*` with `projectId` | **Changed:** it shows each note's audience, and shares a carried-over note with the project |
| #478 settings, Branches | [section 8](#8-settings-without-asking-waking-limits), `projects.set`, [3.6](#36-archiving-and-deleting), `github.attach` | **Changed** only in that `wakeOnReports` is here and nowhere else, and the line under the switches says what [7.3](#73-who-answered) and [section 11](#11-what-the-engine-cannot-check) say |
| #479 the Work tab, kept by pi² | [3.11](#311-work-pi2work-pi2github-githubjson), `work.*`, the `work` event, `projects.watch` | **Changed:** `work.act` and the state table; a start past a limit is confirmed ([8.3](#83-limits-and-the-one-admission-check)) |
| #480 the Work tab, GitHub | `github.*`, the `github` event, its `unknown` writes | **Changed.** Needs `PI2_GH` in `scripts/test-copy`'s allowlist (#469), and shows writes whose outcome is unknown, with `github.settle` |
| #481 the Dashboard | Its rows of [10.3](#103-with-the-preview-on) | **Changed** only in that its sources are named |
| #482 build pi² as a pi² project | All of it, in use | **Changed.** Carrying over makes the orchestrator's standing rules, kept today as its memory notes, notes of the orchestrator's copy alone; making them rules is done by hand as part of setting the project up |
| #483 take the old way out | [2](#2-the-preview-switch), [3.4](#34-which-agent-a-conversation-runs-as-runsas), [section 9](#9-carrying-over) | **Changed:** it waits for #504 too ([7.3](#73-who-answered)). When the switch goes, `runsAs` always takes the project's copy, and `reports`' choices can move into `delegate` |

## 13. Decisions this contract made

What the design left open, or did not say exactly enough to build, and what this page chose. The product choices the owner may want to change are in [section 14](#14-questions-for-the-owner) instead.

1. **A project's agents are kept with every other agent**, in `pi2.agents`, marked with `projectId`. Every place the engine looks an agent up keeps working.
2. **Templates are simply the agents that belong to no project.** Today's agents are templates where they stand.
3. **Carried-over conversations keep their agent, and gain the project's copy beside it** (`projectAgentId`); which one they run as follows the preview switch. Nothing the old way reads is rewritten.
4. **With the preview off, every request that exists today works as today**; only what is new is refused. A conversation outside any project is told exactly what it is told today, with the preview on or off. A project's limits and `startAgents` still hold for its conversations with the preview off, so switching off removes no protection.
5. **One folder, one project; a repository is one folder**, grouped by the top of its main checkout, so its worktrees and subfolders join it. A submodule is a project of its own.
6. **The carried-over orchestrator** is the agent of the most recently used conversation that hands out work and whose agent still exists, with fixed tie-breaks; where none qualifies, a default orchestrator, whose conversation is made when the person first opens or writes to it (#458: not an empty one for every folder at once).
7. **A project may have no folder** (the design's open question): its agents work where a folderless conversation works today, the data folder's `workspace`. Carrying over puts every folderless conversation in one such project, "No folder".
8. **A project has other conversations** besides the orchestrator's, listed under it.
9. **A project agent's new conversations start in the project's folder**; every conversation already working keeps its own folder, worktree and allowances.
10. **A rule binds the orchestrator or everyone**, not one named agent (left open by the design); the field can take a third form later.
11. **Rules: at most 50, each 1,000 characters; their cost is characters divided by four**, labelled "about".
12. **No smaller version of rules before projects** (left open by the design): rules come in step 2, behind the preview.
13. **`delegate` does not change while the preview exists**: the waking choices are in a new tool for orchestrators, `reports`.
14. **The project's state is not a prompt section**: a changed section stays in the context until a summary. A state block starts each context and a catch-up starts each turn, both typed entries; each piece of news has an id and is cleared only when given, and a message the person wrote to an agent is never dropped for room.
15. **The summariser's instructions are not changed**, since they are the same for every conversation; a summary that restates a rule costs a few tokens and changes nothing the model is given.
16. **Without asking, by default:** start agents, file and close work, make and change agents, add rules. Ask first: merge, release, go past a limit.
17. **Allow everything lifts no project switch, and answers no reach request, proposed rule, question or decision.** A switch that is off is the person's choice for this project, newer and narrower than Allow everything.
18. **A reach request does not hold the agent up**, is one per call, comes once however often it is asked, and is checked again, project, target and fields, when it is allowed.
19. **Carrying over is undone by the backup made before its first run and by the preview switch**, not by a run backwards; the backup is the database and settings, without the Keychain.
20. **GitHub:** `scripts/issue`'s labels and its "Done." comment; `--repo` on every command; every write an intent first, reconciled after a restart, and reported as unknown rather than repeated when pi² cannot tell.
21. **Notes stay at 60 per project, and carried notes past that are all kept**, each for the copy of the agent it belonged to until the person shares it. A note is carried once, and never brought back after it is removed.
22. **Chat mode keeps reading the agents' own notes only** during the preview.
23. **Start fresh moves what it can and refuses what it cannot**: sub-chats' and background commands' wakes, arrived wakes and the hourly count move to the new conversation; a queued message or a pending approval must be dealt with first.
24. **Archiving or deleting a project never writes a conversation's own archive state**, so the old sidebar shows every conversation where it was; the project's state hides it with the preview on.
25. **Changes are typed operations, each with its own inverse or none**, applied by the same validator as the person's request. Removing an agent through a tool keeps it whole (`removedAt`); deleting for good is the person's.
26. **Work has one state machine for both kinds of list**, with `release` and `resume`; `assign` claims and starts in one step, or neither.
27. **Only the orchestrator gets the tools that change the project**; what each conversation may do with the rest depends on its kind and access level (5.1).
28. **A copy or a project the person deleted is not made again**, and a project made by hand is adopted with nothing about it changed.
29. **A copy takes all of its template's allowed commands**, whatever their folder: each holds only where it was made, so the copy can do exactly what the template could.
30. **How each hub was left, and the Dashboard's projects, are the app's preferences.**
31. **A limit is checked at the moment of starting, not reserved**, and allowing a `startAgents` approval allows the start, not passing a limit.

## 14. Questions for the owner

The page is written as if each recommended answer were given. Each can be answered yes, or changed.

1. **Who answered.** The engine cannot yet tell the app from a command an agent ran, so "an agent can only ask" holds against an agent that does not go round pi² on purpose; and merging is held back only when done through pi²'s own tools, while "release" is a policy pi² tells the orchestrator but cannot check. *Recommended:* say exactly that, and no more, everywhere; #504 closes the first gap and must land before #483, and the preview does not wait for it.
2. **Spending.** *Recommended:* keep the list of changes that widen reach narrow for spending, and let the limit bound it: a new project has one by default (no start while a plan window is 90% used), and past it a report does not wake the orchestrator either. An agent's model or thinking level may be changed without asking; waking for the whole project is the person's switch, and the orchestrator chooses waking only for its own hand-offs.
3. **What an agent can do.** *Recommended:* every setting an agent has is classed as widening reach or not, in the table of [7.1](#71-every-setting-classed) (tool access, built-in tools turned back on, Allow everything, computer and browser use, allowed commands, variables, MCP servers, the worktree with its set-up command, who it may hand work to, and the rest), and a setting the table does not name counts as widening. Which project tool actions each kind of conversation may use, by its access level, is the table in [5.1](#51-who-is-offered-what).
4. **Rules dictated.** *Recommended:* keep it simple: with the switch on, the orchestrator adds a rule directly, and the line with Undo in front of the person shows it; removing a rule, or changing one so that it may ask less (any change of its words, or binding fewer), is asked for. Order decides nothing but the order shown.
5. **Secrets when carrying over.** *Recommended:* a copy made by carrying over keeps its agent's variables and Allow everything, so the project works as before, and the report lists each such copy by name for the person to see before the run. Copying the Keychain values is a step that is retried until done and shown while incomplete, and the backup is described as what it is: the database and settings, without the Keychain.
6. **Tools and Undo.** *Recommended:* the table in [5.9](#59-every-change-in-the-hub-its-tool-whether-it-asks-and-its-undo) is every change the hub offers, with its tool action, whether it asks first, and its inverse. The person's alone: archiving, restoring and deleting a project, Start fresh, waking for the whole project, answering Needs you, the preview and carrying over, templates and variables; with no Undo: changing the orchestrator (it starts a fresh conversation) and anything already done on GitHub.
7. **Limits and the person.** *Recommended:* one check wherever an agent is started, by an agent or by the person, made at the moment it starts. The person starting one from the board past a limit is shown the limit and confirms that one start; Start Anyway on a limit card is the same confirmation.
8. **A worker's question.** **Proposed (#507, not agreed):** a worker's question goes under Needs you with `needs_you` and does not hold it: the person's answer wakes the worker while its run is going, and once the run has ended goes to the conversation that handed it the work, with whose question it was and how to continue the sub-chat ([5.5](#55-needs_you-the-orchestrators-and-agents-own-conversations)). `ask_user` stays for the question whose answer the worker's next step needs, with no other work to do meanwhile. *Recommended:* say yes to this. As the page stands until then: a sub-chat cannot be woken, so a worker's question to the person is `ask_user`, which holds it and shows under Needs you; only the orchestrator's and agents' own conversations ask without stopping.
9. **Waking after carrying over.** *Recommended:* a carried-over project keeps waking on, since its work was set going on that footing and would otherwise stop overnight with nobody to review it; a new project starts with it off, as decided.
