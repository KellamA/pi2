
# Projects: the contract

This is the contract for the projects epic, [#450](https://github.com/KellamA/pi2/issues/450): the engine's documents, requests, events, tools and prompt sections for a project, how what exists today is carried over, and what the preview switch turns on and off. Every later issue of the epic (#456 to #483) is built against it, several at once, by agents who read this page and not the conversation in which the design was made. Where this page and an issue's text differ, this page has the last word on names and shapes; [section 12](#12-the-later-issues) says which issues it changes.

The design it builds is [design/projects.md](design/projects.md), with its drawings in [design/projects-drafts.html](design/projects-drafts.html). This page does not repeat why; it says exactly what. Where the design left something open, this page decides it, and [section 13](#13-decisions-this-contract-made) lists each decision with its reason. What only the owner can decide is in [section 14](#14-questions-for-the-owner), each with the answer this page is written for.

Nothing here is built yet. When a piece is built, its issue updates the part of this page it built if the build had to differ, in the same pull request, so the page stays true for the issues after it. Once #483 has taken the old way out, this page becomes the guide to projects for a person and a developer.

**How to read it.** Read [section 1](#1-words) and [section 2](#2-the-preview-switch) whatever your issue, then the sections your issue's row in [section 12](#12-the-later-issues) names. Types are written as TypeScript, as `engine/src/state.ts` writes them. Times are milliseconds since 1970, as everywhere in the engine. "The person" is whoever uses pi²; "an agent" is a model working in a conversation.

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
- **The orchestrator's conversation**: the one current conversation between the person and a project's orchestrator. After **Start fresh**, the ones before it are its **earlier conversations**: readable, taking no messages.
- **Other conversations** of a project: its top-level conversations that are not the orchestrator's, current or earlier. Carrying over makes most of them; the person can start one with any agent of the project.
- **Runs as**: the agent whose settings a conversation uses at its next message. For almost every conversation it is its `agentId`, as today; for a conversation carried over, with the preview on, it is the project's copy of that agent ([3.4](#34-how-a-project-agent-is-shown-runsas)).
- **Reach**: what agents may do or spend without the person. A change that widens it is on the closed list in [section 7](#7-reach-what-an-agent-can-only-ask-for), and an agent can only ask for it.
- **Report**: the answer a sub-chat of the orchestrator ends with, or the way it ended without one (failed, stopped).
- **Catch-up**: a short text pi² puts in front of the orchestrator's next input, saying what changed in the project since its last turn ([6.4](#64-the-catch-up-and-the-state-block)).
- **Allowed commands**: what [rules.md](rules.md) calls rules today, commands an agent may run without asking. #460 renames them in everything a person or an agent reads; their stored fields and requests (`commandRules`, `rules.add`, `rules.remove`) keep their names. In this page **rule** always means a project's rule.

## 2. The preview switch

Projects are a preview until #483. The switch is a setting of the engine's, so that the engine, not only the app, knows whether agents are told about projects.

- **Where:** `settings.json`, as `projects: { preview: boolean }`. Absent means off. Read through one function, `projectsOn()` in `engine/src/projects.ts`, which every piece of the epic asks.
- **Changed by:** `projects.setPreview { on }` ([4.2](#42-requests)). Turning it on the first time runs the carrying-over ([section 9](#9-carrying-over)); turning it on again runs it again, which only adds what is new.
- **Shown:** Settings › General, under **Projects (preview)**, with a line saying what it does and that switching it off shows everything as it was.

What each state does:

| | Never turned on | On | Turned off again |
|---|---|---|---|
| Sidebar, Inbox, agents' pages, Activity, Archive | As today | Projects: the hub, Needs you, the Dashboard, templates ([section 10](#10-the-app)) | As today, showing every conversation, including those made in projects; agents with a `projectId` are left out of the agents' list ([10.2](#102-with-the-preview-off)) |
| Chat mode | As today | As today | As today |
| Documents | Nothing new is written | Projects, rules, notes, Needs you, reports, work, changes, as section 3 says | Kept as they are, untouched |
| A conversation's agent | Its `agentId` | Its project's copy, for a conversation carried over (`projectAgentId`); its `agentId` for every other | Its `agentId` |
| What an agent is told: prompt sections, tools, catch-up | As today | The project's sections and tools ([5](#5-tools-for-agents), [6](#6-prompt-sections-and-what-the-orchestrator-is-told)) for conversations in a project | As today: no project section, tool, catch-up or note reaches any conversation |
| Limits, waking rules, without-asking switches of a project | None | Enforced | Not enforced |
| New conversations made the old way (a schedule, Continue with an Agent) | As today | Put in the project of their folder as they are made ([9.6](#96-conversations-made-later)) | As today |
| Events | The new events of [4.4](#44-what-an-app-is-sent-on-connecting) (with `preview: false`, and nothing in them) and the fields added to existing events are sent; the app ignores them | All sent and used | As in the first column, with the projects in them |
| Requests | `projects.list`, `projects.setPreview` and `projects.carryOver` with `dryRun` only; every other request of section 4 is refused | All | As in the first column |

The refusal while the switch is off is one message for every request: "Projects are a preview. Turn them on in Settings › General first."

What does not wait for the switch: #460's renaming of rules to allowed commands, and #469's ability to fill a throwaway copy with a demo project (which turns the switch on in that copy).

Turning the switch on or off counts for each conversation from its next message, as any change to an agent does: an answer being written keeps what it started with. The engine sends the `projects` event to every app at once.

## 3. Documents

### 3.1 Where things are kept

Every document is a session document of pi durable, in `session.sqlite` in the data folder, like `pi2.library` and `pi2.agents` today, so a commit can change several together and a backup holds them. The GitHub listing is a cache, in a file.

| What | Document (`kind`) | Code | New or added to | Issue |
|---|---|---|---|---|
| Projects, the carrying-over record, news for each orchestrator | `pi2.projects` | `engine/src/projects.ts` | New | #456, #458, #466 |
| Agents and templates | `pi2.agents` | `state.ts` | Fields added to `AgentProfile` | #456, #457 |
| Conversations | `pi2.library` | `state.ts` | Fields added to `Meta` | #456, #458, #466 |
| Rules | `pi2.projectRules` | `engine/src/projectrules.ts` | New | #459 |
| Notes | `pi2.memory` | `knowledge.ts` | `projects` added beside `agents` and `chat` | #461 |
| Needs you | `pi2.needs`, and the `Inbox` in memory as today | `engine/src/needs.ts` | New; the Inbox unchanged | #462 |
| Reports | `pi2.reports` | `engine/src/reports.ts` | New | #463 |
| What wakes whom | `pi2.wakes` | `wakes.ts` | Fields added to a watch | #463 |
| Work kept by pi² | `pi2.work` | `engine/src/work.ts` | New | #467 |
| Work from GitHub | `github.json` in the data folder (a cache) | `engine/src/github.ts` | New | #468 |
| The record of changes | `pi2.changes` | `engine/src/changes.ts` | New | #465 |
| The preview switch | `settings.json`, `projects.preview` | `projects.ts` | New key | #456 |

Nothing that exists is removed, renamed or rewritten. Every field added is optional, so a document written before it reads as it did, and a field an older app does not know is ignored by it (the app's `Codable` types ignore unknown keys, and `EngineClient.handle` ignores unknown events).

### 3.2 The project (`pi2.projects`)

```ts
type ProjectsDoc = {
	projects: Record<string, Project>;
	/** What carrying over has done, so that a second run adds only what is new (section 9). */
	carry: CarryRecord;
	/** By project id: what the orchestrator has not been told yet (6.4). Oldest first, at most 200 each. */
	news: Record<string, News[]>;
};

type Project = {
	/** "p-" and a UUID. Never reused. */
	id: string;
	/** 1 to 80 characters, trimmed. Unique, ignoring case, among projects not deleted. */
	name: string;
	/**
	 * The real path of the project's folder, or null for a project with no folder (13, decision 7). At most one
	 * project not deleted has a given folder; any number may have none.
	 */
	folder: string | null;
	/** The GitHub repository attached, whose issues and pull requests are the work list; null: the list is kept by pi². */
	repository: { owner: string; name: string } | null;
	/** The project agent that is its orchestrator: in `pi2.agents`, with this `projectId` and `role: "orchestrator"`. */
	orchestratorId: string;
	/**
	 * The orchestrator's conversation now. `projects.create` makes it, empty, with the project. Null only for a project
	 * carried over already archived with no conversation to take, until it is restored, which makes it.
	 */
	conversation: number | null;
	/** Earlier conversations with the orchestrator, oldest first (Start fresh, 6.5). */
	earlier: number[];
	settings: ProjectSettings;
	createdAt: number;
	updatedAt: number;
	/** Archived: out of the sidebar, its conversations archived with it (4.2, `projects.archive`). */
	archivedAt?: number;
	/** Deleted: shown nowhere but the Archive, which lists its conversations under its name. */
	deletedAt?: number;
	/** Made by carrying over, at this time. */
	carriedAt?: number;
};
```

`ProjectSettings` is in [section 8](#8-settings-without-asking-waking-limits), with its defaults.

- **The work list's mode** follows `repository`: null, the list kept by pi² ([3.10](#310-work-pi2work-and-githubjson)); set, the repository's issues and pull requests. There is no separate field to disagree with it.
- **The folder** is checked to be a folder when it is set, and stored by its real path. A folder that has gone since is kept as it is; the `projects` event says `folderMissing: true`, and the project's agents work as a conversation whose folder has gone does today.
- **A project with no folder** (`folder: null`): its agents' conversations work in pi²'s own scratch folder, as a conversation with no folder does today. It has no Branches tab content and cannot attach a repository.
- **Archiving** a project archives its orchestrator's conversation and every other top-level conversation of it (and so their sub-chats, as archiving does), marking each it archived with `archivedWithProject: true`. Restoring the project restores exactly those. Its rules, notes, work and agents stay.
- **Deleting** a project marks it `deletedAt`, archives its conversations as archiving does, withdraws what it had under Needs you, and stops its agents being offered anywhere. Its conversations stay in the Archive, under the project's name, readable, restorable only as other conversations of no project, and deletable one by one. Its rules, notes, work and changes are kept but shown nowhere. Nothing is erased: pi durable cannot erase, and the person may want it back.

```ts
/** What carrying over has done (section 9). Keys are stable, so a second run finds what the first made. */
type CarryRecord = {
	/** When it last ran for real, and the backup made before its first real run. */
	ranAt: number | null;
	backup: string | null;
	/** The grouping key of a folder (9.2) to the project made for it. "none" for conversations with no folder. */
	folders: Record<string, string>;
	/** "<projectId> <templateId>" to the copy made for that project. */
	copies: Record<string, string>;
	/** "<projectId> <templateId> <noteId>" for each note copied. */
	notes: Record<string, true>;
};

/** One thing the orchestrator has not been told yet. `text` is one line, as the catch-up shows it (6.4). */
type News = {
	at: number;
	kind: "report" | "message" | "answer" | "change" | "work" | "limit" | "need";
	text: string;
	/** What it is about, so that the same news is not given twice: a conversation, a need, a change, a work item. */
	ref: string;
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
```

- **Templates** are the agents with no `projectId`. There is no other store and no other kind: today's agents are templates as they stand, which is how "today's agents become templates" is done without copying them. A template is made, edited, duplicated and deleted with today's requests (`agents.save`, `agents.duplicate`, `agents.delete`).
- **Names** are unique, ignoring case, among the templates, and among the agents of each project. A project's agent may share a name with a template or with another project's agent. `delegate` and every tool that names an agent look only among the agents of the conversation's own project (or only among templates, outside any project).
- **The orchestrator** is a project agent with `role: "orchestrator"`. It cannot be deleted; making another agent the orchestrator is `projects.setOrchestrator`, which starts a fresh conversation with it ([6.5](#65-start-fresh)).
- **What does not make sense in a project.** Every setting of an agent today holds for a project agent, except:
  - `cwd`: always the project's folder (null for a project with no folder). The engine sets it, at copying and whenever the project's folder changes; `agents.save` refuses another (“An agent of a project works in the project's folder”). A sub-chat still moves into a worktree as today, and the worktree setting still makes one per conversation.
  - `delegates`: the orchestrator hands work to every other agent of its project, whatever its `delegates` say, and to no agent outside it. Any other project agent may hand work only to agents of its own project named in its `delegates`. Outside a project, `delegates` names only templates, as today.
- **Copying a template** into a project copies every setting, through the same path as `agents.duplicate`, with these differences: the new agent gets `projectId`, `template` and the project's folder; `delegates` is mapped to the project's copies of the templates it named (a template the project has no copy of is left out); allowed commands (`commandRules`) are copied, only those whose folder is the project's folder or inside it; variables are copied with their names only, as a duplicate's are, except when carrying over, which copies their values too ([9.3](#93-agents-templates-become-copies)); Allow everything is never copied, except when carrying over; the memory switch is copied. No conversation, schedule or worktree is copied.
- **Update from template** compares the copy with its template, setting by setting, over every setting a copy takes from its template except its name, `cwd`, `delegates`, allowed commands, variables and Allow everything, which are the project's own. It says what would change (`agents.updateFromTemplate` with `apply: false`) before changing anything, then changes those settings and sets `template.copiedAt` and `templateUpdatedAt`. A template deleted since leaves the copy as it is, with **Update from template** unavailable ("The template this agent was made from has been deleted").
- **The default orchestrator** is a template that is not stored: a constant, `DEFAULT_ORCHESTRATOR` in `projects.ts`, like chat mode's assistant in `chat.ts`. It is not in the `agents` event and cannot be edited; a project made without naming a template gets a copy of it, which is an ordinary project agent from then on. Its settings: name "Orchestrator", colour violet, the default model, thinking unset, access Ask first, memory on, summarising at 100,000 tokens, the built-in tool **Summarise its own conversation** on, everything else as a new agent's defaults. Its instructions, in full:

  > You are the orchestrator of this project. The person talks to you. Plan the work with them, hand each piece to one of the project's agents with `delegate` or `work` (`assign`), review what comes back, and report plainly what was done and what was not. Keep the project's work list up to date. When a decision is the person's, put it to them with `needs_you` and carry on with what does not depend on it. If the project has no agent suited to a piece of work, make one with `project_agents`.

### 3.4 How a project agent is shown: `runsAs`

The engine decides which agent a conversation runs as with one function, `runsAs(meta)` in `state.ts`, and every place that today reads `agents[meta.agentId]` for a conversation reads `agents[runsAs(meta)]` instead (#457 makes that change, everywhere at once):

```ts
/** The agent whose settings conversation `meta` uses at its next message. */
function runsAs(meta: Meta): string | undefined {
	if (projectsOn() && meta.projectAgentId !== undefined && agents[meta.projectAgentId] !== undefined) return meta.projectAgentId;
	return meta.agentId;
}
```

A conversation whose `projectAgentId` names an agent deleted since runs as its `agentId`; one whose `agentId` was deleted too keeps the setup it has, as a conversation whose agent was deleted does today.

### 3.5 Conversations (`pi2.library`)

```ts
// Added to Meta (state.ts). All optional.
/** The project it belongs to. Set on every conversation of a project, sub-chats included (taken from the parent as one is made). */
projectId?: string;
/** For a conversation carried over: the project's copy of its agent, which it runs as while the preview is on (3.4). */
projectAgentId?: string;
/** An orchestrator's conversation begun with Start fresh: the one it followed. */
freshFrom?: number;
/** Archived by archiving its project: restored with it. */
archivedWithProject?: true;
```

- `agentId` is never changed by anything in the epic. With the preview off, a conversation is exactly what it was.
- A conversation made in a project with the preview on (by the person on the hub, by `delegate`, by `work assign`, by Start fresh) has `agentId` set to the project agent it was made with, and `projectId`. It has no `projectAgentId`. The person starts one of a project's other conversations with today's `conversation.create { agentId }`, naming a project agent: the conversation takes that agent's `projectId`.
- A chat (`chat: true`) and a chat's version never have a `projectId`. Chat mode is outside projects.
- Whether a conversation is the orchestrator's, current or earlier, is said only by the project (`conversation`, `earlier`): one place, which cannot disagree with another.
- An earlier conversation with the orchestrator takes no messages: `submit` and `continue` refuse with "This is an earlier conversation with the orchestrator. Write in the current one." It is not archived, so its sub-chats carry on ([6.5](#65-start-fresh)).

### 3.6 Rules (`pi2.projectRules`)

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
		| { kind: "agent"; agentId: string; conversationId: number } // a rule the person dictated (5.4, project_rules add)
		| { kind: "proposal"; agentId: string; conversationId: number; need: string }; // proposed, then accepted by the person
	createdAt: number;
	updatedAt: number;
};
```

- The array's order is the rules' order, which the prompt and the board show, numbered from 1.
- At most 50 rules per project. A 51st is refused: "This project has 50 rules, the most it can have. Remove one first."
- `binds` has two values. Binding one named agent was left open by the design; the shape leaves room to add `{ agent: id }` later without changing the others ([13](#13-decisions-this-contract-made), decision 10).
- A proposed rule waits under Needs you ([3.8](#38-needs-you-pi2needs-and-the-inbox)), not in this document, until the person accepts it.

### 3.7 Notes (`pi2.memory`)

The memory document ([knowledge.md](knowledge.md#where-it-is-stored)) gets a third part, beside `agents` and `chat`:

```ts
// Added to MemoryDoc (knowledge.ts).
projects?: Record<string, { notes: ProjectNote[]; next: number }>;

type ProjectNote = {
	/** "n" and a number, per project. */
	id: string;
	text: string;
	createdAt: number;
	/** The conversation that wrote it; null for a note the person wrote. */
	conversation: number | null;
	/** The agent that wrote it; null for the person. Kept for the board's "which agent wrote each". */
	agentId: string | null;
	/** Copied by carrying over, from this agent's note: so a second run does not copy it again. */
	carriedFrom?: { agentId: string; id: string };
};
```

- Notes keep today's limits: 400 characters each, 60 per project. Notes carried over are all kept even past 60; the 61st new one is refused until some are removed, as today.
- **Who reads and writes them.** A project agent whose memory switch is on (`agents[id].enabled` in the memory document, as today) gets the project's notes in its `memory` section and writes them with `remember` and `forget`, in every conversation of its, sub-chats included. With the preview off it gets its own agent notes, as today, which for a project agent are none.
- An agent's own notes (`agents`) and chat mode's (`chat`) are left as they are. Chat mode's `agent_notes` reads the agents' own notes only, not a project's, during the preview ([13](#13-decisions-this-contract-made), decision 22).
- Adding, editing and removing notes are not recorded as changes and get no line with Undo: they are the agents' own memory, and the Notes tab shows and removes them.

### 3.8 Needs you (`pi2.needs`, and the Inbox)

Needs you is one list, made of two sources:

- **The Inbox, as today:** approvals and `ask_user` questions, which live in memory while their tool call waits, and come back after a restart because the call runs again ([architecture.md](architecture.md#approvals)). Nothing about them changes.
- **`pi2.needs`:** everything that does not hold a tool call: a question or decision put with `needs_you`, a request for more reach, a proposed rule, and a hand-off refused for a limit. These are stored, so they survive a restart, and stay until answered or withdrawn.

```ts
type NeedsDoc = { items: Record<string, StoredNeed>; next: number };

type NeedKind = "approval" | "question" | "decision" | "reach" | "rule" | "limit";

/** What every item of the list has, from either source. */
type NeedBase = {
	/** An Inbox item's id as today; a stored one is "n" and a number. */
	id: string;
	kind: NeedKind;
	projectId: string | null;
	conversationId: number;
	rootConversationId: number;
	/** The conversation's title, and its root's, for "in …". */
	title: string;
	rootTitle: string;
	/** The agent the conversation runs as, and its name. */
	agentId: string | null;
	agentName: string | null;
	/** Whether the agent is held until it is answered: approvals and `ask_user` questions. */
	blocking: boolean;
	createdAt: number;
};

type NeedItem = NeedBase &
	(
		| { kind: "approval"; tool: string; arguments: unknown; question: string | null; site?: string; when?: string; rule?: { words: string[]; folder: string; worktrees?: true }; background?: true }
		| { kind: "question"; question: string } // blocking from ask_user; not blocking from needs_you
		| { kind: "decision"; question: string; choices: string[]; words: boolean } // from needs_you with choices
		| { kind: "reach"; change: ReachChange; why: string | null } // section 7
		| { kind: "rule"; text: string; binds: "orchestrator" | "everyone"; why: string | null }
		| { kind: "limit"; reason: string; handOff: { agentId: string; agentName: string; title: string; task: string; work: number | null } }
	);

/** What `pi2.needs` keeps: an item without what is worked out when it is sent (titles, names, `blocking`). */
type StoredNeed = Omit<NeedItem, "title" | "rootTitle" | "agentName" | "blocking"> & { callId: string | null };
```

- **Answers**, with `needs.answer` ([4.2](#42-requests)): an approval takes `once`, `always`, `rule` or `deny`, as `inbox.decide` does; a question takes text; a decision takes one of its `choices`, or text when `words` is true; a reach request takes `allow` or `refuse`; a proposed rule takes `accept` (with `text` when the person edited it) or `refuse`; a limit takes `start` or `drop`.
- **Telling the agent.** An approval and an `ask_user` question answer the waiting call, as today. Every other kind, once answered, is given to the conversation that asked as a wake of a new kind, `answer` ([wakes.md](wakes.md)): "The person answered your question “Merge now or after the release?”: After the release." It wakes the conversation if it is not answering, within the wakes' bounds (the budget, the turn limit, 30 an hour). A `limit` answer goes to the orchestrator's conversation as news instead ([6.4](#64-the-catch-up-and-the-state-block)), since the person, not the orchestrator, chose.
- **Withdrawn**: by the agent (`needs_you` with `withdraw`); when its conversation is archived or deleted (as an approval is today); and a reach request whose setting the person has meanwhile changed by hand, which is withdrawn with a line in the asking conversation. A withdrawn item leaves the list at once.
- **Allow everything answers none of them but approvals.** A conversation whose agent has Allow everything still has its questions, decisions, reach requests and proposed rules put to the person, and an approval for a switch of [8.1](#81-what-the-orchestrator-may-do-without-asking) that is off is still asked ([13](#13-decisions-this-contract-made), decision 17).
- **Order**: oldest first, as the Inbox is.

### 3.9 Reports and waking (`pi2.reports`, `pi2.wakes`)

```ts
type ReportsDoc = { projects: Record<string, Report[]> };

/** How a sub-chat of an orchestrator's conversation ended. Kept seven days after it ended. */
type Report = {
	/** The sub-chat. Its answer is its transcript's, read with `reports` (5.6); not copied here. */
	conversationId: number;
	agentId: string;
	title: string;
	endedAt: number;
	outcome: "answered" | "failed" | "stopped";
	/** The orchestrator has been given it: by a wake, by `delegate` waiting for it, or by `reports` with `read`. */
	read: boolean;
	/** It woke the orchestrator. */
	woke: boolean;
	/** The work item the sub-chat was handed with `work assign`, if any. */
	work: number | null;
};
```

A watch in `pi2.wakes` ([wakes.md](wakes.md#for-developers)) gets two optional fields, read only for a sub-chat of a project's orchestrator:

```ts
// Added to a watch in pi2.wakes.
/** When this sub-chat's report wakes the orchestrator. Absent: as the project's `wakeOnReports` says now. */
wake?: "each" | "all" | "failure" | "never";
/** Sub-chats chosen together with `reports` (`wake`, several chats): `all` and `failure` count over the batch. */
batch?: string;
```

How a report goes, for a sub-chat of an orchestrator's conversation (current or earlier) that was handed its task without waiting, or whose wait a message ended:

- The engine follows it as today. When it ends, a `Report` is added, unread.
- Then, by its watch's `wake` (or the project's setting when it has none: on is `each`, off is `never`):
  - `each`: it wakes the orchestrator's current conversation with the report, as a wake does today; the report becomes read and woke.
  - `all` (a batch): nothing until every sub-chat of the batch has ended; then one wake gives every report of the batch, oldest first.
  - `failure`: a report that ended answered wakes nobody; the first that failed or was stopped wakes the orchestrator with it. In a batch, the reports of the batch that ended before it come with it, and the rest wake nobody.
  - `never`: it wakes nobody.
- A report that woke nobody stays unread. It is in the next catch-up ([6.4](#64-the-catch-up-and-the-state-block)) by one line, and its text comes with `reports` (`read`), which marks it read.
- A `delegate` that waits for its sub-chat, and `sub_chats` with `wait`, give the report as their result, as today, and mark it read. Nothing else changes for them.
- Outside projects, and with the preview off, waking is exactly as [wakes.md](wakes.md) says.

The wakes' bounds hold for every wake above: the budget, the turn limit and 30 an hour.

### 3.10 Work (`pi2.work`, and `github.json`)

**Kept by pi²:**

```ts
type WorkDoc = { projects: Record<string, { items: Record<string, WorkItem>; next: number }> };

type WorkItem = {
	/** 1, 2, 3… per project, never reused. Shown as "#12". */
	id: number;
	/** 1 to 200 characters. */
	title: string;
	/** Up to 20,000 characters. */
	text: string;
	state: "open" | "in_progress" | "waiting" | "blocked" | "done" | "dropped";
	/** The class of model it needs (docs/issue-classes.md); null: not classified. */
	class: "local" | "cloud" | null;
	/** The agent working on it, and the conversation it works in. */
	takenBy: { agentId: string; conversationId: number } | null;
	notes: { at: number; by: Who; text: string }[];
	/** What finishing it said was done. */
	result: string | null;
	filedBy: Who;
	createdAt: number;
	updatedAt: number;
	closedAt: number | null;
};

type Who = { kind: "person" } | { kind: "agent"; agentId: string; conversationId: number };
```

The states are those `scripts/issue` keeps on this repository's issues: open is `backlog`, then `in progress`, `waiting`, `blocked`, and closed as done or dropped. That is deliberate: the same words for both kinds of list, and pi² itself moves to a project with nothing to translate (#482).

**From a GitHub repository** ([13](#13-decisions-this-contract-made), decision 20): the repository's issues are the work items, with the same fields, read from GitHub:

| A work item's | Is the issue's |
|---|---|
| `id` | number |
| `state` | open with the label `backlog` or none: `open`; with `in progress`, `waiting` or `blocked`: that state; closed as completed: `done`; closed as not planned: `dropped` |
| `class` | the label `local model` or `cloud model` |
| `notes` | comments, oldest first, by whom pi² posted each (from its first line, below) or the person otherwise |
| `result` | the comment that closed it as done, which pi² begins with `**Done.**` |
| `takenBy` | the last "Taken by" comment pi² posted, while the issue is `in progress` |

What pi² writes to GitHub it writes through `gh`, run in the project's folder, with the sign-in `gh` already has; pi² keeps no token. Each comment pi² posts for an agent begins with a line naming it: `*From Forge, an agent of the pi² project “pi²”.*` Labels it needs and the repository lacks are made as `scripts/issue` makes them (the same names, colours and descriptions).

Pull requests are only for a GitHub project:

```ts
type PullRequest = {
	number: number;
	title: string;
	url: string;
	branch: string;
	base: string;
	author: string;
	state: "open" | "merged" | "closed";
	draft: boolean;
	checks: "passing" | "failing" | "pending" | "none";
	mergeable: "yes" | "no" | "unknown";
	/** What reviewing agents found: the comments pi² posted for `work` `review`. */
	findings: { agentName: string; verdict: "approve" | "changes" | "comment"; at: number; url: string }[];
	/** The conversation that opened it through `work`, when pi² knows it; where Send back goes. */
	openedBy: { conversationId: number } | null;
	/** The work item it fixes, from "Fixes #N" in its text. */
	work: number | null;
};
```

`github.json` in the data folder keeps, by project, the last listing that was read in full (`{ readAt, issues, pulls, openedBy }`), so the board has something to show after a restart and when GitHub cannot be reached. `openedBy` is kept there because GitHub does not know it. The listing has the open issues and pull requests, and those closed in the last seven days.

**Reading GitHub.** At most once a minute per project, and only while an app shows that project's Work tab or Now tab, or an agent asks (`work` `list` or `show`), and at once after any change pi² makes there. A `gh` that fails, is not signed in, or answers that the rate limit is reached leaves the last listing in place, with what went wrong (`state` in the `github` event: `ok`, `loading`, `signed_out`, `unreachable`, `rate_limited`, with `error` and `readAt`). An agent's `work` call then answers with the cached listing and says when it was read and why it is not newer. For tests, `PI2_GH` names the program to run in place of `gh` (#468); #469 adds it to `scripts/test-copy`'s allowlist.

### 3.11 The record of changes (`pi2.changes`)

Every change an agent makes to the project's configuration through its tools, and every change the person allowed from a reach request, is recorded, so that it can be shown in the conversation with Undo and undone exactly.

```ts
type ChangesDoc = { projects: Record<string, Change[]>; next: number };

type Change = {
	/** 1, 2, 3… across all projects. */
	id: number;
	at: number;
	by:
		| { kind: "agent"; agentId: string; conversationId: number; callId: string }
		| { kind: "allowed"; need: string; agentId: string; conversationId: number }; // a reach request the person allowed
	target: { kind: "project" } | { kind: "agent"; id: string } | { kind: "rule"; id: string };
	action: "make" | "change" | "remove" | "move";
	/** The fields changed, as they were and as they became: whole for make and remove. */
	before: Record<string, unknown> | null;
	after: Record<string, unknown> | null;
	/** One line, as the conversation shows it: "Made the agent Reviewer (Claude Sonnet 4.6, Ask first)". */
	summary: string;
	undone?: { at: number; by: Who };
};
```

- **Recorded:** making, changing and removing agents, updating one from its template, changing the project's settings, making another agent the orchestrator, and adding, editing, moving and removing rules. **Not recorded:** notes (they are the agents' own memory) and work (its own history is the list), nor anything the person does by hand.
- **Undo** puts back `before` for exactly the fields in it, if each still has its `after` value. If any has changed since, nothing is undone: "This was changed again since, so it was not undone. Change it by hand." Undoing a make removes the agent (refused while it is working: "Forge is working. Stop it first, or wait."); undoing a remove puts the agent back with its id. An undo is itself checked against [section 7](#7-reach-what-an-agent-can-only-ask-for): an agent's undo that would widen reach (undoing the addition of a rule removes a rule) becomes a request; the person's never does.
- **In the conversation.** The tool call's result carries `details.change: id`, and the conversation's state has `projectChanges: [{ id, summary, undone, canUndo }]` for the changes made in it (the last 100), so the page draws each with Undo, and as undone once it is. An export writes each as its summary, with "(undone)" when it was.
- Kept: the last 500 per project.

## 4. Requests and events

### 4.1 Conventions

As every request today ([architecture.md](architecture.md#how-they-talk)): `{ id, method, params }`, answered `{ id, result }` or `{ id, error }`, where `error` is one plain sentence a person can act on. Every request in this section is the person's, made through the app: none is checked against [section 7](#7-reach-what-an-agent-can-only-ask-for), which is for agents' tools only. Every request but the three named in [section 2](#2-the-preview-switch) is refused while the preview is off.

Errors every request below can give, besides its own:

| When | Error |
|---|---|
| The project does not exist, or was deleted | "Unknown project: <id>" |
| The agent does not exist, or is in another project | "Unknown agent: <id>" (or "<name> is not an agent of this project") |
| A field has the wrong type | "<field> must be <what>", as today's requests say it |
| The project is archived and the request would change it | "This project is archived. Restore it first." |

### 4.2 Requests

**Projects** (#456, #466):

| Request | Answers | Does, and refuses |
|---|---|---|
| `projects.list {}` | `{ preview, projects }` | The `projects` event's content, for a script that does not read events |
| `projects.setPreview { on }` | `{ preview, carryOver }` | Turns the preview on or off. On: runs carrying over, and answers its report ([9.5](#95-the-report-and-the-run)); off: `carryOver` is null |
| `projects.create { folder, name?, template? }` | `{ id }` | A project from a folder in one step. `folder` a folder's path, or null; `name` defaults to the folder's last part ("No folder" for null), with " 2", " 3"… when taken; `template` the id of a template to copy as its orchestrator, else the default orchestrator. Refuses "Not a folder: …" and "There is already a project for this folder: <name>" (an archived one: "…; restore it instead") |
| `projects.rename { id, name }` | `{}` | Refuses an empty name, one over 80 characters, or one taken |
| `projects.set { id, folder?, settings? }` | `{ settings }` | Changes the folder (checked as in create; moves every agent of the project to it) and any part of the settings ([section 8](#8-settings-without-asking-waking-limits)), each checked; parts not given are kept |
| `projects.setOrchestrator { id, agentId }` | `{ conversation }` | Makes another agent of the project its orchestrator, and starts a fresh conversation with it ([6.5](#65-start-fresh)). Refused while the current one is answering |
| `projects.startFresh { id }` | `{ conversation }` | [6.5](#65-start-fresh). Refused while the current conversation is answering: "The orchestrator is answering. Stop it or wait, then start fresh." |
| `projects.archive { id }`, `projects.unarchive { id }` | `{}` | [3.2](#32-the-project-pi2projects) |
| `projects.delete { id }` | `{}` | [3.2](#32-the-project-pi2projects). Refused while any of its conversations is working: "Stop the project's agents first." |
| `projects.carryOver { dryRun? }` | the report ([9.5](#95-the-report-and-the-run)) | With `dryRun: true`, changes nothing; allowed with the preview off. Without, runs it (the preview must be on) |

**Agents and templates** (#457):

| Request | Answers | Does, and refuses |
|---|---|---|
| `projects.addAgent { projectId, template?, agent? }` | `{ id }` | Makes an agent of the project: a copy of `template`, or from `agent` (the fields `agents.save` takes). Same checks as `agents.save` |
| `agents.save { agent }` | `{ id }` | As today, for templates and project agents alike. Keeps `projectId`, `role`, `template` and `madeBy` as stored, whatever it is sent; refuses a `cwd` other than the project's for a project agent |
| `agents.duplicate { id }` | `{ id }` | As today; a project agent's copy is in the same project, never the orchestrator |
| `agents.delete { id }` | `{}` | As today; refuses the orchestrator: "<name> is the project's orchestrator. Make another agent the orchestrator first." |
| `agents.updateFromTemplate { id, apply }` | `{ changes: [{ setting, now, template }], applied }` | [3.3](#33-agents-and-templates-pi2agents). With `apply: false`, changes nothing |

**Rules** (#459). Under `projects.rules`, since `rules.add` and `rules.remove` are the allowed commands' and keep their names:

| Request | Answers | Does |
|---|---|---|
| `projects.rules.add { projectId, text, binds }` | `{ id }` | Adds a rule at the end |
| `projects.rules.edit { projectId, id, text?, binds? }` | `{}` | Changes its text or whom it binds |
| `projects.rules.move { projectId, id, to }` | `{}` | Moves it to place `to`, counted from 0 |
| `projects.rules.remove { projectId, id }` | `{}` | Removes it |

**Notes** (#461): `memory.add`, `memory.edit` and `memory.delete` take `projectId` in place of `agentId` or `chat: true`, for a project's notes, with the same limits; `memory.setEnabled { agentId }` is unchanged and is how a project agent's switch is set.

**Needs you** (#462):

| Request | Answers | Does |
|---|---|---|
| `needs.list { projectId? }` | `{ items }` | The `needs` event's items, of one project or all |
| `needs.answer { id, answer, text? }` | `{}` | Answers an item of any kind ([3.8](#38-needs-you-pi2needs-and-the-inbox)); refuses one gone ("This is no longer waiting: it was answered or withdrawn.") and an answer its kind does not take. `inbox.decide` and `inbox.answer` keep working for approvals and `ask_user` questions |

**Reports** (#463):

| Request | Answers | Does |
|---|---|---|
| `reports.wake { projectId, chats, when }` | `{}` | The person's choice for sub-chats working now, as `reports` `wake` is the orchestrator's ([5.6](#56-reports-the-orchestrator)) |

**Work** (#467 for both kinds of list where the request is the same, #468 for what is GitHub's):

| Request | Answers | Does |
|---|---|---|
| `work.list { projectId }` | `{ items }` | The list; for GitHub, the cached listing, read again if older than a minute |
| `work.create { projectId, title, text?, class? }` | `{ id }` | Files a piece of work (an issue, for GitHub, with the label `backlog`) |
| `work.edit { projectId, id, title?, text?, class? }` | `{}` | Changes it |
| `work.note { projectId, id, text }` | `{}` | Adds a note (a comment) |
| `work.assign { projectId, id, agentId, task? }` | `{ conversation }` | Gives it to an agent, which starts it: a sub-chat of the orchestrator's current conversation, handed the work's title and text (and `task`, when given) without waiting, the work taken for it. The orchestrator is told in its catch-up. The project's limits do not refuse the person ([8.3](#83-limits)) |
| `work.close { projectId, id, as, note? }` | `{}` | `as` is `done` or `dropped` |
| `work.reopen { projectId, id }` | `{}` | Back to open |
| `github.attach { projectId, repository? }` | `{ repository }` | Attaches `owner/name`, or by default the repository the folder's `origin` remote names. Refuses a project with no folder, a repository `gh` cannot see ("gh cannot reach owner/name: …"), and a project whose work list kept by pi² has open items ("Close or move this project's open work first: …") |
| `github.detach { projectId }` | `{}` | Back to a list kept by pi², which is as it was left |
| `github.refresh { projectId }` | `{}` | Reads again now, within the once-a-minute limit |
| `github.merge { projectId, number }` | `{}` | Merges the pull request with `gh pr merge --merge`; refuses one that cannot be merged, with GitHub's reason |
| `github.sendBack { projectId, number, reason }` | `{}` | Posts the reason on the pull request, and sends it to the conversation that opened it as a message from the person (when pi² knows it), which the orchestrator is told of |
| `github.diff { projectId, number }` | `{ diff }` | The pull request's diff, as `gh pr diff` gives it, cut at 2 MB with a line saying so |

**Changes** (#465):

| Request | Answers | Does |
|---|---|---|
| `changes.list { projectId, before?, limit? }` | `{ changes }` | Newest first, 50 by default |
| `changes.undo { id }` | `{}` | [3.11](#311-the-record-of-changes-pi2changes) |

### 4.3 Events

New events, each sent whole when what it holds changes, and to each app as it connects:

```ts
{ event: "projects"; preview: boolean; projects: ProjectRow[]; carryOver: { ranAt: number; backup: string | null } | null }

type ProjectRow = Project & {
	folderMissing: boolean;
	/** About how many tokens the rules add to each request: an orchestrator's, and every other agent's (6.2). */
	ruleTokens: { orchestrator: number; agents: number };
};

{ event: "needs"; items: NeedItem[] }                                  // every project's, and those of no project
{ event: "projectRules"; projects: Record<string, ProjectRule[]> }
{ event: "reports"; projects: Record<string, Report[]> }               // the last seven days
{ event: "work"; projects: Record<string, WorkItem[]> }                // lists kept by pi²
{ event: "github"; projects: Record<string, { state: "ok" | "loading" | "signed_out" | "unreachable" | "rate_limited"; error: string | null; readAt: number | null; repository: { owner: string; name: string }; issues: WorkItem[]; pulls: PullRequest[] }> }
```

Fields added to events that exist:

| Event | Added | Issue |
|---|---|---|
| `library` | each conversation's `projectId` (or null), `runsAs` (the agent id it runs as now), `orchestrator: "current" \| "earlier" \| null`; each archived row's `projectId` | #456, #457, #466 |
| `agents` | each agent's `projectId`, `role`, `template`, `madeBy`, `updatedAt` (as stored; absent when not set) | #456, #457 |
| `memory` | `projects: Record<projectId, { notes: ProjectNote[] }>` | #461 |
| `activity` | each run's `projectId`, `runsAs`, and `lastLine`: the last line of text its agent wrote, at most 140 characters, or null | #466 |
| `wakes` | each item's `projectId`, `wake` and `batch` | #463 |
| `usage` | `projects: [{ id, today: { cost, tokens } }]`, today's spending by project | #464 |
| `inbox` | nothing: it stays as it is for the old screens | |
| conversation state | `projectChanges` ([3.11](#311-the-record-of-changes-pi2changes)); and `project: { id, orchestrator: "current" \| "earlier" \| null }` or null | #465, #466 |

How often: `projects`, `projectRules`, `work` and `github` change at the pace of the person and the orchestrator, and are sent at once. `needs` is sent at once, as the Inbox is, since an item answered must leave the list before it could be answered again. `reports` is sent at once (a few a minute at most). `activity` stays coalesced as today, so its `lastLine` is at most a quarter of a second late. None is sent for a change that changes nothing in it.

### 4.4 What an app is sent on connecting

After today's events (`library`, `agents`, `inbox`, `activity`, `schedules`, `recovery`, `usage`, `mcp`, `chat`, `compactionSettings`, then the features' greetings), the projects' features greet with, in this order: `projects`, `projectRules`, `needs`, `reports`, `work`, `github`. They are sent whether the preview is on or not, so that turning it on shows everything at once; with it off, `projects` says `preview: false`, and the others are as small as what there is.

## 5. Tools for agents

### 5.1 Who is offered what

With the preview on, a conversation is in a project when its `projectId` is set and the project is not archived or deleted. Outside a project, and with the preview off, nothing in this table is offered and every existing tool is exactly as today.

| Tool | The orchestrator's current conversation | Its sub-chats, and other agents' conversations in the project | Outside a project |
|---|---|---|---|
| `project_agents` | Yes | No | No |
| `project_settings` | Yes | No | No |
| `project_rules` | Yes | No | No |
| `reports` | Yes | No | No |
| `needs_you` | Yes | Yes, in a top-level conversation; not in a sub-chat, which keeps `ask_user` | No |
| `work` | Yes, all actions | Yes; the orchestrator's actions are refused | No |
| `remember`, `forget` | With memory on: the project's notes | With memory on: the project's notes | As today: the agent's own notes |
| `delegate`, `sub_chats` | Yes, to every other agent of the project | As today, to the agents of the project its `delegates` name | As today |
| `ask_user` and every other tool | As its settings say | As its settings say | As today |

None of the new tools is in the list of [built-in tools](architecture.md#built-in-tools) that an agent's settings can leave out: each is offered by being in a project, and is sent to no other conversation. Only the orchestrator's current conversation is offered the orchestrator's tools; another conversation the person has with the orchestrator agent is offered what any other agent's is. An earlier conversation with the orchestrator, which takes no messages, is offered nothing new.

Every tool here changes only pi²'s own documents, or GitHub through `gh`, so none asks for approval under Ask first, except where [section 8](#8-settings-without-asking-waking-limits) says a switch that is off makes it ask. Each is safe to run again after a crash: a call run again finds what it already did, by its call id, as `remember` does.

Each tool's answer below is the text the model is given. A refusal is a result with `isError`, in a sentence that says what to do instead.

### 5.2 `project_agents` (the orchestrator)

```ts
project_agents {
	action: "list" | "templates" | "make" | "change" | "remove" | "update_from_template";
	agent?: string;        // name of an agent of the project: change, remove, update_from_template
	template?: string;     // name of a template: make (a copy)
	settings?: {           // make and change: any of these, others kept
		name?: string; description?: string; instructions?: string;
		model?: string;    // "provider/model id", as the model menu names it
		thinking?: string; access?: "none" | "read" | "ask" | "full";
		worktree?: boolean; turn_limit?: number | null; memory?: boolean;
		delegates?: string[];   // names
		built_in_tools?: { on?: string[]; off?: string[] };   // keys of builtInTools
		computer?: { enabled?: boolean; apps?: string[]; ask?: boolean };
		browser?: { enabled?: boolean; ask?: boolean };
		mcp_servers?: string[]; reference_files?: string[]; schedule?: boolean;
		setup?: string; allow_everything?: boolean;
	};
	apply?: boolean;       // update_from_template: false (the default) only says what would change
	why?: string;          // for a change on the closed list: shown to the person on the request
}
```

- `list`: each agent of the project with its model, access, whether it is working, and its description, one line each. `templates`: each template's name and description.
- `make`, `change`, `remove`, `update_from_template`: made at once when the project's `makeAgents` switch is on, as a change with Undo ("Made the agent Reviewer, a copy of the template Forge (Claude Sonnet 4.6, Ask first). The person can undo it."). With the switch off, the call asks the person first as an approval. A setting on the closed list ([section 7](#7-reach-what-an-agent-can-only-ask-for)) is never made: it is left as it was (for a new agent, at the baseline of [7.2](#72-asking-allowing-refusing)) and asked for, and the answer says so: "Made Reviewer with access Ask first. Full access widens what it may do, so the person was asked for it (under Needs you); you will be told their answer."
- `remove` refuses the orchestrator, and an agent that is working ("Forge is working on sub-chat 14. Wait for it, or ask the person to stop it.").
- Variables, sign-ins, the agent's colour and the project's templates themselves cannot be changed with it.

### 5.3 `project_settings` (the orchestrator)

```ts
project_settings {
	action: "show" | "change" | "set_orchestrator" | "undo";
	changes?: {
		name?: string; folder?: string | null; repository?: string | null;   // "owner/name"
		wake_on_reports?: boolean;
		without_asking?: Partial<Record<"start_agents" | "file_work" | "close_work" | "make_agents" | "add_rules" | "merge" | "release" | "pass_limits", boolean>>;
		limits?: { plan_share?: number | null; daily_spend?: number | null };
	};
	agent?: string;    // set_orchestrator: the agent of the project to become the orchestrator
	change?: number;   // undo: the id of a change, from a result's last line
	why?: string;
}
```

- `show`: the project's name, folder, work list, the switches, waking, the limits and how they stand now (today's spending, the plan windows of the models its agents run on), each on a line.
- `change`: each part made at once, as one change with Undo, unless it is on the closed list; those parts are asked for, and the answer says which were made and which asked.
- `set_orchestrator`: always a request ([7.1](#71-the-closed-list), R16): the person allows it, then the hub starts a fresh conversation with the new orchestrator.
- `undo`: undoes a change recorded in [3.11](#311-the-record-of-changes-pi2changes) that this project made, as `changes.undo` does, except that an undo that would widen reach is asked for.

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
- `add` is for a rule the person stated in this conversation, word for word or as near as it can be put. It adds it at once, with Undo, when the project's `addRules` switch is on; when it is off, it becomes a proposal. Its description says so: "Only for a rule the person has just told you to keep. To suggest one yourself, use propose."
- `propose` puts it under Needs you as a proposed rule, which the person accepts, edits or refuses; the orchestrator is told which.
- `move` is made at once, with Undo.
- `edit` and `remove` are always requests ([7.1](#71-the-closed-list), R5): no agent changes or removes a rule itself.

Other agents of the project have no rules tool: only the orchestrator talks with the person about the project.

### 5.5 `needs_you` (every top-level conversation in a project)

```ts
needs_you {
	action: "ask" | "withdraw" | "list";
	question?: string;      // ask: up to 2,000 characters
	choices?: string[];     // ask: 2 to 6 buttons, 60 characters each; without them, an answer in words
	words?: boolean;        // ask with choices: whether an answer in words is allowed too; default true
	id?: string;            // withdraw: the item's id
}
```

- `ask` puts a question (or, with `choices`, a decision) under Needs you and returns at once: "Put to the person as n12. Carry on with what does not depend on it; their answer will come to you as a message." The answer wakes the conversation ([3.8](#38-needs-you-pi2needs-and-the-inbox)).
- `withdraw` takes back one of this conversation's items that is still waiting, when it is no longer needed. `list` gives this conversation's items still waiting.
- A sub-chat is not offered it: a sub-chat is not woken ([wakes.md](wakes.md#what-wakes-an-agent)), so an answer could not reach it. It uses `ask_user`, which shows under Needs you as a question that holds it.

### 5.6 `reports` (the orchestrator)

```ts
reports {
	action: "list" | "read" | "wake";
	chats?: number[];       // read: these (default: every unread); wake: these sub-chats
	when?: "each" | "all" | "failure" | "never";   // wake
}
```

- `list`: the reports of the last seven days not yet read, then the sub-chats still working with how each will wake it.
- `read`: each report as `delegate` would have given it (the answer, which sub-chat, how to continue it, the `Used:` line), and marks them read.
- `wake`: sets when these sub-chats' reports wake it ([3.9](#39-reports-and-waking-pi2reports-pi2wakes)); with several chats and `all` or `failure`, they become one batch. Answers what was set: "Sub-chats 14, 15 and 16 are one batch: you will be woken once, when all three have ended."

This tool, and not new parameters of `delegate`, carries the choice of waking. `delegate`'s definition is sent to every conversation that can hand work on, and with the preview off nothing an agent is told may change ([13](#13-decisions-this-contract-made), decision 13). `delegate` with `wait: false` in an orchestrator's conversation says in its result how the report will come: "Its report waits for you unread; you are not woken for it (the project's setting). To be woken, use reports with action wake."

### 5.7 `work` (every agent of a project)

```ts
work {
	action: "list" | "show" | "take" | "note" | "wait" | "block" | "finish" | "file"
		| "pull_request" | "review"                                      // GitHub only
		| "assign" | "classify" | "close" | "merge" | "send_back";       // the orchestrator only
	id?: number;            // a work item (an issue's number), or a pull request's for review, merge, send_back
	text?: string;          // note, wait, block (why), finish (the result), file (the text), review (the finding), send_back (the reason)
	title?: string;         // file, pull_request, assign (the sub-chat's title)
	state?: string;         // list: only items in this state; default every open one
	class?: "local" | "cloud";   // file, classify
	agent?: string;         // assign
	task?: string;          // assign: what to say beyond the work's own text
	branch?: string;        // pull_request: default the branch the conversation's folder is on
	base?: string;          // pull_request: default the repository's default branch
	verdict?: "approve" | "changes" | "comment";  // review
	as?: "done" | "dropped";                      // close
}
```

For every agent of the project:

- `list`, `show`: the items, or one with its text, notes and result, and for GitHub its pull requests.
- `take`: takes it for this agent and conversation (in progress); refuses one another agent has ("#12 is taken by Forge, in sub-chat 14").
- `note`, `wait` (waiting on the person), `block` (blocked), `finish` (done, with the result): on an item this conversation has taken; `note` on any.
- `file`: a new item, open.
- `pull_request` (GitHub): opens one from `branch` with `gh pr create`, in the conversation's folder; with `id`, adds "Fixes #<id>" to the text unless it is there. Answers its number and address.
- `review` (GitHub): posts the finding on the pull request, as a comment beginning with the agent's line and the verdict, and the board shows it.

For the orchestrator only (others are refused: "Only the orchestrator assigns, classifies, closes, merges and sends back work."):

- `assign`: as `work.assign` does for the person, under the `startAgents` switch and the project's limits ([8.3](#83-limits)). Answers as `delegate` with `wait: false` does.
- `classify`: sets the class.
- `close`: closes as done or dropped.
- `merge`: merges a pull request, under the `merge` switch.
- `send_back`: as `github.sendBack` does.

`file` is under the `fileWork` switch, and `finish` and `close` under `closeWork`; a switch that is off makes the call ask the person first, as an approval. Outside GitHub, `pull_request`, `review`, `merge` and `send_back` are refused: "This project's work is kept by pi², which has no pull requests."

The `project` section ([6.1](#61-the-sections)) tells every agent of the project to keep the work list with this tool and not with scripts or `gh` of its own, so that no instructions are needed to teach it the tracker.

### 5.8 What existing tools say differently in a project

Only in a project, with the preview on:

- `delegate` names only agents of the project, and refuses a new sub-chat or a continued one past a limit ([8.3](#83-limits)), or asks first when `startAgents` is off. With `wait: false` its result says how the report will come (5.6).
- `sub_chats`, in an orchestrator's current conversation, lists the sub-chats of its earlier conversations too, still working or not archived, and `delegate` with `chat` continues one of them: Start fresh loses no sub-chat ([6.5](#65-start-fresh)). Each line says whether its report is read.
- `remember` and `forget` write the project's notes ([3.7](#37-notes-pi2memory)).

## 6. Prompt sections, and what the orchestrator is told

### 6.1 The sections

Two new sections, and one changed, in this order among [the existing ones](architecture.md#the-list-of-prompt-sections): after `task_list`, before `project_instructions`. They come from a feature in a file of its own (`projects.ts` for `project`, `projectrules.ts` for `project_rules`), listed in `FEATURES` just after `plan`, so they keep their place with nothing more ([architecture.md](architecture.md#the-system-prompts-sections)).

| Section | From | Has something to say when | Steady, or comes and goes |
|---|---|---|---|
| `project` | `projects.ts` | the conversation is in a project and the preview is on | Changes in place when the project's name, folder, repository, settings or orchestrator change; comes and goes with the preview |
| `project_rules` | `projectrules.ts` | the conversation is in a project, the preview is on, and some rule binds its agent | Changes in place when a rule binding its agent is added, edited, moved or removed |
| `memory` (changed) | `knowledge.ts` | as today; for a project agent with the preview on, the project's notes | As today |

Both new sections are worked out from documents only, never from the time, counts that move, or who is working, so a section's text changes only when what it holds changes. Each change is sent alone, as that one section ([architecture.md](architecture.md#the-system-prompts-sections)).

They also survive summaries: after a summary, pi durable writes the whole system prompt again with every section as it is then, and leaves out the sections' earlier changes (`findBaseline` in pi durable's `harness/context.js`). So a rule is word for word in front of the model at every request, whatever has been summarised. The summariser's instructions (`RETENTION_INSTRUCTIONS` in `compaction.ts`) get one more sentence, from #459: "The project's rules and notes are given to the model separately at every turn; do not restate them in the summary."

**`project`, for the orchestrator** (its text, with the parts in angle brackets filled in):

```
You are the orchestrator of the pi² project “<name>”, in <folder>. The person talks to you here; this is the project's one conversation with you.
Its work list is <kept by pi² | the issues and pull requests of github.com/<owner>/<name>>. Keep it with the work tool, not with scripts or gh of your own.
Change the project with project_agents, project_settings and project_rules; each change shows here with Undo for the person. A change that lets agents do or spend more is never made by a tool: it is put to the person, who allows or refuses it.
You may, without asking: <start agents, file work, …>. You ask first to: <merge, …>. <“Release” is the person's policy: pi² cannot check it, so keep to it yourself.>
Limits: <no new agent starts while a plan window it would run on is 90% used or more; none>, <and none once the project has spent $20 today; none>. Past a limit, a hand-off is refused with the reason.
A report from an agent <does not wake you; it waits unread until you read it with reports | wakes you>. Choose otherwise for particular sub-chats with reports.
When something happens in the project while you are not answering, pi² tells you at the start of your next turn.
Put a decision that is the person's to them with needs_you and carry on; do not stop to wait for it.
```

**`project`, for every other agent of the project:**

```
You are <name>, an agent of the pi² project “<project name>”, in <folder>. <Orchestrator name> is its orchestrator. <In a sub-chat: It handed you this work, and your answer is your report to it.>
The project's work list is <…>. Keep it with the work tool: take what you work on, note progress, and finish it with what was done.
```

The same text goes to every conversation of that agent of the same kind (a sub-chat, or a conversation of its own), so it changes only with the project.

**`project_rules`** (only the rules that bind this agent; for the orchestrator, both groups, each only when it has rules):

```
The person's rules for this project. Keep every one at every turn. If the person asks for something a rule forbids, say so and ask them to confirm or change the rule.
For you, the orchestrator:
1. Never merge a pull request without a review by another agent.
For every agent:
2. Run the engine's tests before every commit.
```

Numbers follow the board's order over all the rules, so a rule has the same number for every agent and on the board.

**`memory`, for a project agent:** as today's ([knowledge.md](knowledge.md#memory)), with "the project's notes, kept by its agents" in place of "your own notes from earlier conversations", and each note's id (`n7`).

### 6.2 What the rules cost

`ruleTokens` in the `projects` event is about how many tokens the rules add to each request: the `project_rules` section's text as an orchestrator is given it, and as every other agent is, each counted as its characters divided by four, rounded up. The board says "about", and says it is read again at every request of every agent it binds. It is an estimate made without a provider, the same for every model; a provider's own count differs by a little.

### 6.3 Why the project's state is not a section

The design asks that the conversation can be summarised hard or started afresh with nothing lost, because the project's state lives outside it; #466 proposed a section holding that state (open work, who is working, what waits for the person, reports not read).

A section that changes is sent again whole, as a system message in the conversation, and stays in the context until the next summary ([architecture.md](architecture.md#the-system-prompts-sections)). Who is working and what waits for the person change at almost every turn of a busy orchestrator: a section of some 500 tokens sent again at most turns would add those tokens to every later request until a summary, and makes a summary come sooner. So the state reaches the orchestrator in two ways instead, each sent once:

- **at the start of a context**: a whole **state block**, in the first input of a new conversation (a new project, Start fresh), and in what pi² adds to every summary ([compaction.md](compaction.md#what-stays));
- **between**: a **catch-up** in front of each input that starts a turn, with only what changed since the turn before.

Both are in the transcript, after the cached prompt, so nothing before them is sent again ([13](#13-decisions-this-contract-made), decision 14).

### 6.4 The catch-up and the state block

**The catch-up.** What happens in a project that the orchestrator was not part of is added to its project's `news` ([3.2](#32-the-project-pi2projects)) as it happens:

| News | Line |
|---|---|
| A report that woke nobody | "Sub-chat 14 “Fix login” (Forge) answered at 14:02; not read yet." |
| The person wrote to another agent | "The person wrote to Forge in sub-chat 14: “Use the new endpoint instead.”" (the first 300 characters) |
| The person changed the project, an agent or a rule by hand | "The person added a rule: 3. “…”"; "The person set Scout's model to …" |
| Another agent or the person filed, finished or closed work | "Scout filed #31 “…”."; "Forge finished #28." |
| The person answered a limit card | "The person started Forge on “…” past the daily limit." |
| Something came under Needs you, from another agent | "Forge's sub-chat 14 asks the person: “…”" |

When the next input that starts a turn of the orchestrator's current conversation is taken (the person's message, a wake, a queued message placed), the engine puts in front of it, in the same entry, a text made of those lines:

```
[pi² — what changed in the project since your last turn]
- Sub-chat 14 “Fix login” (Forge) answered at 14:02; not read yet.
- The person wrote to Forge in sub-chat 14: “Use the new endpoint instead.”
```

and empties the news in the same commit. At most 4,000 characters; past that, the oldest lines go, with a last line "…and 12 more; reports and work list them." With no news, nothing is added. The transcript shows it as one folded line, "pi² told the orchestrator what changed (2)", like a wake's row, opening to the text. A steer placed in the middle of a turn takes the news with it.

The orchestrator's own doings are not news to it, and nor is what a wake already gives it.

**The state block** is the whole state, made from the documents when it is given:

```
[pi² — the project as it stands, 19 November 14:20]
Working now: sub-chat 14 “Fix login” (Forge, since 13:40); sub-chat 16 “Docs” (Scout, waiting for Anthropic's limit until 15:30).
Under Needs you: 2 (an approval for Forge's command `npm publish`; your question “Merge now or after the release?”).
Reports not read: sub-chat 15 “Tests” (Scout) failed at 14:10.
Work: 12 open, 3 in progress (#28 Forge, #29 Scout, #31 nobody), 1 waiting, 0 blocked.
```

Each part says "none" when empty; "Working now" and "In progress" list at most 20, then "and N more". It is given:

- in front of the first input of a new orchestrator's conversation (a new project, Start fresh, or a new orchestrator), in place of a catch-up;
- at the end of what pi² adds to a summary of an orchestrator's conversation (`compactionCheckpoint`), after the open sub-chats and the task list it adds today; the news is emptied then too, since the block says all of it.

### 6.5 Start fresh

`projects.startFresh` (and `projects.setOrchestrator`, which does the same with another agent):

1. Refused while the current conversation is answering.
2. In one commit: a new conversation with the orchestrator, with `projectId` and `freshFrom` set; the project's `conversation` becomes it, and the old one goes to the end of `earlier`. Watches in `pi2.wakes` for sub-chats of the old conversation move to the new one, so their reports wake (or wait for) the new one. Questions and decisions the old conversation put under Needs you stay, and their answers go to the new one.
3. The old conversation stays as it is, readable, not archived (archiving would stop its sub-chats), and takes no new messages ([3.5](#35-conversations-pi2library)). Its page has a line at the end, "Continued in a fresh conversation", linking to the new one; the new one begins with "Started fresh from an earlier conversation", linking back.
4. The new conversation's first input carries the state block (6.4). The rules and notes are its sections, as in any conversation of the project.

## 7. Reach: what an agent can only ask for

### 7.1 The closed list

A change on this list, made through any tool by any agent, is never made by the tool. It is put to the person as a reach request. The list is closed: a change not on it is made by the tool, as a change with Undo, under the switches of [8.1](#81-what-the-orchestrator-may-do-without-asking).

| | The change | Why it widens reach |
|---|---|---|
| R1 | A switch of [8.1](#81-what-the-orchestrator-may-do-without-asking) turned on | Lets the orchestrator act without asking |
| R2 | A limit raised, or turned off | Lets agents spend more |
| R3 | The project's folder set or changed | Moves every agent onto other files |
| R4 | A GitHub repository attached or changed | Lets agents write in a repository, under the person's GitHub sign-in |
| R5 | A rule removed, or its text or whom it binds changed | A rule only ever binds; changing one can loosen it |
| R6 | An agent's access raised (none, read files, Ask first, Full access, in that order) | Lets it act without asking |
| R7 | An agent's Allow everything turned on | Lifts every approval |
| R8 | An agent's computer use turned on, an app added to it, test copies of pi² allowed, or its asking before each action turned off | Reaches other apps, or acts in them without asking |
| R9 | An agent's browser turned on, or its asking before acting on a page turned off | Reaches the web with the person's sign-ins |
| R10 | An MCP server added to an agent | Reaches what the server reaches |
| R11 | A reference file or folder added to an agent | Reads outside the project's folder |
| R12 | An agent's scheduling of its own work turned on | Starts work with nobody there |
| R13 | An allowed command added to an agent | Runs it without asking |
| R14 | An agent's set-up command set or changed | Runs without asking in every new worktree |
| R15 | A built-in tool that spends money turned on (`make_picture`) | Spends on the person's picture provider |
| R16 | Another agent made the orchestrator | Gives it everything the orchestrator may do without asking |
| R17 | An undo that is itself one of the above | As the change it puts back |

And for a **new agent** (`make`, a copy of a template, or `update_from_template`): it is made at the baseline (below) for every setting on the list, and one reach request asks for all the settings it was not given.

**Not offered to agents at all**, so neither made nor asked for by a tool: the preview switch, carrying over, archiving and deleting a project, deleting a template or changing one, an agent's variables, sign-ins and providers, MCP servers' own settings, and "Always Allow … Here" on a conversation.

Lowering any of these (access lowered, a switch turned off, a limit lowered, an app taken away) narrows reach and is made at once, with Undo.

**What the list does not cover**, and why: an agent's model and thinking level (spending is bounded by the limits of [8.3](#83-limits), which are on the list), its instructions (they cannot widen what the engine lets it do), its turn limit and summary size, code mode, `delegates` (only within the project), and waking (bounded by the limits and the wakes' cap of 30 an hour).

### 7.2 Asking, allowing, refusing

**The baseline** for a new agent made by an agent: access at most Ask first; Allow everything, computer use, the browser and scheduling off; no MCP server, reference file, allowed command or set-up command; `make_picture` off. Everything else as asked.

**Asking.** The tool:

1. Works out the change against what is stored now, and splits it: what is not on the list is made (as one change with Undo); what is on the list is not.
2. For what is on the list, puts one `reach` item under Needs you per call, with `change`:

   ```ts
   type ReachChange = {
   	/** What it changes, as the person reads it: "Let Forge run commands without asking (Full access)". */
   	summary: string;
   	/** Exactly what allowing it sets, field by field, with what is there now. */
   	target: { kind: "project" } | { kind: "agent"; id: string } | { kind: "rule"; id: string } | { kind: "new_agent"; id: string };
   	fields: { name: string; before: unknown; after: unknown }[];
   	/** Which entries of the closed list it is (R1–R17). */
   	entries: string[];
   };
   ```

   and `why`, the agent's `why`, shown as the agent's words, not pi²'s.
3. Answers at once, without waiting: what was made, and "<summary>: this widens what agents may do, so it was put to the person, who will allow or refuse it. You will be told their answer. Do not ask again meanwhile."

The same change asked again while one is waiting gives the one waiting, not a second.

**Allowing.** The card has two buttons, **Allow** and **Refuse**, and says what allowing means in the words the setting's own confirmation uses (for Allow everything, those of [allow-everything.md](allow-everything.md#turning-it-on)). On **Allow**, the engine checks each field still has its `before` value; if one does not, nothing is changed and the item is withdrawn: "This has changed since it was asked, so nothing was changed." Otherwise it makes the change, records it with `by: { kind: "allowed" }` (so it has Undo too), and the asking conversation is told: "The person allowed: Let Forge run commands without asking (Full access)."

**Refusing** changes nothing; the conversation is told: "The person refused: …. Do not ask for it again unless they bring it up."

**No other way through.** The decision is made by the change, never by who asked or why: a request is a request whether the agent was asked by the person, talked into it by a web page, or told to by another agent's report. Allow everything does not answer it. Nothing an agent can call allows one: `needs.answer` is a request of the app's, not a tool. Text in a tool's result, a page, a file or a report that tells the orchestrator to raise its own reach can, at most, produce a request (#465's test).

## 8. Settings: without asking, waking, limits

```ts
type ProjectSettings = {
	wakeOnReports: boolean;
	withoutAsking: {
		startAgents: boolean;   // delegate (a new sub-chat or a continued one), work assign
		fileWork: boolean;      // work file
		closeWork: boolean;     // work finish (any agent), work close
		makeAgents: boolean;    // project_agents make, change, remove, update_from_template
		addRules: boolean;      // project_rules add, for a rule the person dictated
		merge: boolean;         // work merge
		release: boolean;       // told to the orchestrator; not checked (section 11)
		passLimits: boolean;    // a hand-off past a limit
	};
	limits: {
		/** Percent, 1 to 100: no new agent starts while a window of the plan it would run on is this much used. Null: none. */
		planShare: number | null;
		/** Dollars: no new agent starts once the project's spending today reaches this. Null: none. */
		dailySpend: number | null;
	};
};
```

### 8.1 What the orchestrator may do without asking

| Switch | Default, new project | Default, carried over | Off means |
|---|---|---|---|
| `startAgents` | On | On | Each hand-off asks the person first, as an approval |
| `fileWork` | On | On | Each filing asks first |
| `closeWork` | On | On | Each finishing or closing asks first, by whichever agent |
| `makeAgents` | On | On | Each change to an agent asks first |
| `addRules` | On | On | A dictated rule becomes a proposal instead |
| `merge` | Off | Off | Each merge through `work` asks first |
| `release` | Off | Off | The orchestrator is told to ask before releasing (section 11) |
| `passLimits` | Off | Off | A hand-off past a limit is refused, and a limit card offered to the person |

A switch that is off makes the tool call ask through the Inbox, as an approval with Allow Once and Deny (no "always", no rule), whatever the agent's access. The Inbox item carries `projectSwitch` (the switch's name), which the app reads to offer only those two answers and to say which switch asked, and which `Inbox.ask` reads to ask even for an agent with Allow everything. Allow everything does not lift it ([13](#13-decisions-this-contract-made), decision 17). Turning a switch on is R1; turning one off is made at once.

The switches bind only what goes through pi²'s tools; [section 11](#11-what-the-engine-cannot-check) says what that leaves.

### 8.2 When a report wakes the orchestrator

`wakeOnReports`: **off** for a new project, as the design says; **on** for a project made by carrying over, so that an orchestrator whose habit is to hand work out and wait to be woken keeps working as it did ([13](#13-decisions-this-contract-made), decision 15). The orchestrator may change it either way, as a change with Undo: waking is bounded by the limits and by the wakes' 30 an hour, so it is not on the closed list. Its own choices with `reports` override it for the sub-chats they name ([3.9](#39-reports-and-waking-pi2reports-pi2wakes)).

### 8.3 Limits

| Limit | Default, new project | Default, carried over |
|---|---|---|
| `planShare` | 90 | None |
| `dailySpend` | None | None |

**What is counted.** `planShare`: every window of the subscription that the model of the agent being started is on, as Usage reads it ([limits.md](limits.md)); a window whose reset has passed since it was read does not count; a model on no subscription (a key, an endpoint, a model on this Mac) has no window to count. `dailySpend`: what the project's conversations, sub-chats included, have cost today, in the Mac's local day, as Usage counts it (`usage` event, `projects`).

**What it holds back.** A new run of an agent started by an agent: `delegate` (new or continued) and `work assign`. Not: the orchestrator's own turns, the person's messages, wakes, work already running (it carries on), or anything the person starts from the board. The daily budget of all of pi² still applies as today, on top.

**Past a limit**, with `passLimits` off, the call is refused at once with the reason, and a `limit` card goes under Needs you:

> Not started: the project's limit stops new agents while a plan window they would run on is 90% used or more, and the Anthropic subscription (Max) has its 5-hour window 93% used, resetting at 15:30 (in 1 h 12 min). Work already running carries on. The person can start it anyway from the card under Needs you, or raise the limit.

The card's **Start Anyway** starts exactly that hand-off, without waiting, as a sub-chat of the orchestrator's current conversation; **Leave It** drops it. Either way the orchestrator hears of it in its catch-up. With `passLimits` on, the hand-off starts, and its result ends with the same sentence of how the limit stands.

The board is told through the `needs` event (the card) and the `usage` event (today's spending).

## 9. Carrying over

Carrying over puts what a person has today into projects, with nothing lost, nothing deleted, and nothing the old way reads changed: it only adds documents, adds fields that the old way does not read, and copies agents. The code is `engine/src/carryover.ts` (#458).

### 9.1 What becomes what

| Today | Becomes | Old record |
|---|---|---|
| An agent | A template: the same agent, as it is | Unchanged |
| The agents a folder's conversations ran as | A copy of each in that folder's project | Unchanged |
| A top-level conversation with a folder | A conversation of the project of that folder (9.2) | `projectId`, `projectAgentId` added |
| A sub-chat | In its root conversation's project, whatever folder it worked in | As above |
| An archived conversation | In its project, still archived | As above |
| A conversation with no folder | In the project with no folder, "No folder" | As above |
| A deleted conversation | Nothing | Unchanged |
| A chat, a chat's version | Nothing: chat mode stays as it is | Unchanged |
| A conversation whose agent was deleted | In its folder's project, running as it does today | `projectId` added |
| An agent's memory notes | Notes of the projects its conversations were in (9.4) | Unchanged |
| Chat mode's notes | Nothing | Unchanged |
| Allowed commands | Copied with each copy, those for its project's folder | Unchanged |
| An agent's variables | Copied with each copy, names and values | Unchanged |
| Allow everything | Copied with each copy | Unchanged |
| Approvals and questions waiting | Shown under Needs you, in their conversation's project | Unchanged |
| Inbox notices of plans' limits | Stay in the `limits` event, shown as today | Unchanged |
| Worktrees | Stay where they are, with their conversations, in the project of their repository's main checkout | Unchanged |
| Schedules | Stay on their agent (the template); the conversations they make are put in the project of their folder as they are made (9.6) | Unchanged |

### 9.2 Grouping by folder

A conversation's folder is its `cwd` as its `pi.agent` document holds it now (null: no folder). Its grouping key is:

1. For a sub-chat: its root conversation's key.
2. With no folder: `none`.
3. In a worktree pi² made (`pi2.worktrees`): the top of the repository's main checkout that the worktree was made from.
4. In a git repository: the top of its main checkout, found without running git, as the project instructions are ([knowledge.md](knowledge.md#project-instructions)): the nearest folder upwards with a `.git` entry; when that entry is a file (a linked worktree), the main checkout it names (`gitdir: <main>/.git/worktrees/<name>`).
5. Otherwise: the folder itself, by its real path; a folder that has gone, by the path stored.

So a conversation in `engine/` of a repository, one in its main checkout and one in a worktree of it are one project; two repositories are two.

A project is made for each key that has at least one top-level conversation that is not deleted. It is named after its folder's last part ("No folder" for `none`), with " 2", " 3"… where two folders end alike, and it is archived (`archivedAt` set) when all its conversations are archived. Its settings are those of a new project, except that `wakeOnReports` is on and there are no limits ([section 8](#8-settings-without-asking-waking-limits)).

### 9.3 Agents: templates become copies

For each project, the templates copied into it are the agents its conversations ran as (sub-chats' included), and the agents those may hand work to, followed through their `delegates` until nothing is added, so that every conversation can still hand work to everyone it could. Each is copied once per project ([3.3](#33-agents-and-templates-pi2agents)), with, beyond a copy made by hand: its variables' values, copied in the Keychain under the copy's id; and Allow everything, when the template has it on. Carrying over is not an agent widening anything: it keeps each conversation able to do exactly what it did.

Each conversation of the project whose agent was copied gets `projectAgentId` set to that copy.

**The orchestrator.** Among the project's top-level conversations that are neither archived nor deleted, the one updated most recently that has at least one sub-chat (it hands out work) becomes the orchestrator's conversation, and the copy of its agent becomes the orchestrator (`role`). When none has a sub-chat, the project gets a copy of the default orchestrator and a new, empty conversation with it (for a project made archived, when it is restored). Every other conversation stays one of the project's other conversations.

### 9.4 Notes

For each note in `pi2.memory`'s `agents`:

- written by a conversation (`conversation` set) that is in a project: copied to that project's notes;
- written by the person (`conversation` null), or by a conversation now deleted or in no project: copied to the notes of every project that has a copy of its agent;

as a `ProjectNote` with the copy's `agentId`, the note's `createdAt`, and `carriedFrom`. A note whose text the project's notes already have is not copied twice. A copy's memory switch is its template's. The agents' own notes are left where they are.

### 9.5 The report and the run

`projects.carryOver { dryRun: true }` answers what a run would do, changing nothing:

```ts
type CarryOverReport = {
	projects: {
		key: string;             // the grouping key: a folder, or "none"
		name: string;
		existing: string | null; // the project already made for it by an earlier run
		archived: boolean;
		orchestrator: { conversation: number | null; title: string | null; template: string | null }; // template null: the default orchestrator
		copies: { template: string; name: string; existing: string | null }[];
		conversations: number;   // top-level, not archived, to be added
		archivedConversations: number;
		subChats: number;
		notes: number;
		allowedCommands: number;
	}[];
	leftOut: { chats: number; deleted: number };
	/** Already in a project from an earlier run: left as they are. */
	already: number;
	ranAt: number | null;
	backup: string | null;
};
```

The app shows it as the person turns the preview on, before the run, with a button to go ahead (#458 for the engine; the sheet is #470's).

**The real run**:

1. The first time only, makes a backup of the data folder as **Back Up** does (`createBackup`), into `backups/` in the data folder, and records its path. This and the preview switch are the way back ([13](#13-decisions-this-contract-made), decision 19).
2. Works out the same report.
3. Commits, in one commit per project (so a large library does not hold the engine's thread in one long commit): the project, its copies, the conversations' fields, the notes, and the carrying-over record.
4. Copies variables' values in the Keychain after the commit that made the copy; a value that cannot be copied is logged and the copy shows that variable as unset, as a duplicate's does.
5. Answers the report, with `ranAt` and `backup`.

### 9.6 Conversations made later

While the preview is on, carrying over has run, and a top-level conversation that is not a chat is made with no `projectId` (by a schedule, by Continue with an Agent, by `conversation.create` from a script), the engine puts it in the project of its folder as it is made, by the same rules for one conversation: into the project with its key if there is one (taking that project out of the archive if it is there, without restoring the conversations archived with it), else a new project made as 9.2 says; its agent copied into that project if it has no copy yet; and `projectAgentId` set. So every conversation that is not a chat is in a project from then on, and the person never meets one that is in none.

### 9.7 Running it again

Every step looks in the carrying-over record and in the conversations' own `projectId` before doing anything: a folder with a project gets no other, a template with a copy in a project gets no other, a conversation with a `projectId` is left as it is, a note copied is not copied again. So a second run, with nothing new, changes nothing and answers a report whose projects all have `existing` set and whose counts are all 0. What is new since (a conversation made with the preview off, an agent made since) is added as a first run would add it. The conversations of a project the person deleted stay in it. A conversation not yet in any project, in the folder of a deleted project, goes to a new project for that folder, as a first run would make it: the folder has no project that is not deleted.

### 9.8 Switching the preview off

Nothing is undone: the projects and everything in them stay, and turning the preview on again shows them as they were left. Meanwhile:

- every conversation runs as its `agentId`, exactly as before carrying over (3.4);
- no project section, rule, note, catch-up or tool reaches any conversation (section 2);
- the old screens show every conversation as before, and the templates as the agents list; project agents are left out of that list ([10.2](#102-with-the-preview-off));
- the agents' own notes, allowed commands and variables were never changed, so each agent has all of them;
- what was made in projects while the preview was on (new conversations, notes, rules, work) is kept, and conversations made in projects are listed in the old sidebar like any other.

## 10. The app

This page decides only what the app must read and send. What each screen looks like is the design's, with its drawings, and each app issue's.

### 10.1 What the app keeps itself

In the app's preferences, by project id, not in the engine: how each project's hub was left (`project.<id>.fold`: both shown, the conversation folded, or the board folded), the board's tab, and the projects ticked on the Dashboard (`dashboard.projects`). Two Macs do not share them, and the engine has no use for them.

### 10.2 With the preview off

The app shows today's screens, reading the same events as today, and:

- leaves agents with a `projectId` out of the agents' list, the New Conversation With menu and the palette's agents, while still finding them by id to name a conversation's agent;
- shows nothing of the `projects`, `needs`, `projectRules`, `reports`, `work` and `github` events;
- shows **Projects (preview)** in Settings › General.

### 10.3 With the preview on

- The sidebar's projects come from `projects`; each project's conversations from `library` by `projectId`, its other conversations listed under it, folded, after the agents working; its working agents from `activity` by `projectId` and `runsAs`; its badge from `needs` and `activity`. Nothing about who is working is in the `projects` event, so it is not sent again whenever a run starts or ends (#446).
- The menu bar item's count, the Dock's badge and notifications of things waiting count the `needs` event's items, approvals included, in place of the Inbox's (#462, #481).
- An agent's conversation, a card under Needs you, a change line with Undo: from the events and the conversation state of section 4.
- A conversation's page in a project shows the catch-up's and the state block's rows (6.4), the change lines with Undo (`projectChanges`), the reach and rule cards for the needs a tool call made (its result's `details.need`), and, in another agent's conversation the person wrote to, a line "The orchestrator will be told" (an entry `pi2.toldOrchestrator`, written by the engine as the message is taken, #466).

For `scripts/test-copy` (#469): `PI2_SHOW=project:<name or id>` opens a project's hub, `project:<name>#now`, `#work`, `#agents`, `#rules`, `#notes`, `#branches` or `#settings` one of its board's tabs, `project:<name>#agent:<agent name>` an agent's conversation in place of the board, and `dashboard` the Dashboard. `PI2_HUB=both|conversation-folded|board-folded` sets how the hub opens. `test-copy fill <suffix> --project` fills a demo project through a development build's engine request, `test-copy.fillProject`, which also turns the preview on in that copy.

## 11. What the engine cannot check

The engine enforces what goes through its own tools and requests. Three things lie outside them, and the contract does not pretend otherwise:

- **A command can do what a tool would ask about.** An agent with a shell can run `gh pr merge`, `gh issue close` or a release script. Under Ask first the command is asked about, as every command is, so the person still sees it, but not as "merge, which the project's switch says to ask about". With Full access or Allow everything, nothing asks. The `project` section tells the orchestrator to merge and keep work only with `work`, and the `merge` switch's line on the settings page says that it governs merges made through pi².
- **"Release" has no action in pi²**: there is nothing for the engine to hold back. The switch is told to the orchestrator as the project's policy and marked on the settings page as one pi² cannot check ([14](#14-questions-for-the-owner), question 1).
- **The engine's socket is reachable by any command an agent runs.** A command that writes to `engine.sock` can send any request the app can, `needs.answer` among them, as it can answer approvals today. Reach requests make an agent unable to widen its reach *by being talked into using a tool*; they do not stop an agent that sets out to get round pi² with its shell ([14](#14-questions-for-the-owner), question 2).

## 12. The later issues

What each issue of the epic builds of this contract, and whether the contract changes its scope. The issues' texts are not edited by this page; the agent that hands out the work edits those marked changed, saying how, as the epic's roadmap says. An issue builds the engine side of what it names unless it is an app issue (#470 on).

| Issue | Builds | Scope |
|---|---|---|
| #456 the project, its requests, the preview switch | [2](#2-the-preview-switch); [3.1](#31-where-things-are-kept), [3.2](#32-the-project-pi2projects) (without `carry` and `news`); of [3.3](#33-agents-and-templates-pi2agents), the fields `projectId`, `role`, `updatedAt` and the default orchestrator; of [3.5](#35-conversations-pi2library), `projectId`; the project requests of [4.2](#42-requests) but `setOrchestrator`, `startFresh` and `carryOver`; the `projects` event, `library`'s `projectId`, `agents`' fields; [4.4](#44-what-an-app-is-sent-on-connecting); [section 8](#8-settings-without-asking-waking-limits)'s settings stored and checked (enforced by #463, #464, #465) | **Changed.** It also makes each project's orchestrator as a project agent (a project cannot exist without one), the minimum of #457 that needs. While the preview is off it refuses every request of section 4 but three. Archiving and deleting a project archive its conversations ([3.2](#32-the-project-pi2projects)) |
| #457 agents of a project, templates | [3.3](#33-agents-and-templates-pi2agents), [3.4](#34-how-a-project-agent-is-shown-runsas); the agent requests of [4.2](#42-requests); `runsAs` in `library` and `activity` | **Changed.** Templates are the agents with no project, with no store of their own. `runsAs` replaces every lookup of a conversation's agent, everywhere at once. A project agent's folder is the project's, and `delegates` stays within the project |
| #458 carrying over | [section 9](#9-carrying-over); `carry` in [3.2](#32-the-project-pi2projects); `projectAgentId` in [3.5](#35-conversations-pi2library); `projects.carryOver` and the run in `projects.setPreview` | **Changed.** It carries the memory notes over too ([9.4](#94-notes), moved here from #461). "Can be undone" is the backup made before the first run and the preview switch, not a run backwards ([13](#13-decisions-this-contract-made), decision 19). It also puts conversations made later into projects ([9.6](#96-conversations-made-later)). Waits for #461 as well, for the notes' document |
| #459 rules | [3.6](#36-rules-pi2projectrules); `project_rules` and the summariser's sentence in [6.1](#61-the-sections); [6.2](#62-what-the-rules-cost); the rule requests; the `projectRules` event; `ruleTokens` | **Changed.** Requests are `projects.rules.*`. A rule binds the orchestrator or everyone. Proposing a rule moves to #462 (the card and its answer) and #465 (the tool) |
| #460 allowed commands | Nothing new: [section 1](#1-words) only uses its words | Unchanged |
| #461 notes of the project | [3.7](#37-notes-pi2memory); `memory.*` with `projectId`; the `memory` event's `projects`; the `memory` section's change in [6.1](#61-the-sections); `remember` and `forget` in [5.8](#58-what-existing-tools-say-differently-in-a-project) | **Changed.** Carrying today's notes over moves to #458 |
| #462 Needs you | [3.8](#38-needs-you-pi2needs-and-the-inbox); the Needs you requests; the `needs` event; `needs_you` ([5.5](#55-needs_you-every-top-level-conversation-in-a-project)); the wake kind `answer` | **Changed.** Six kinds, with `limit`. It stores and answers every kind; what allowing a reach request, accepting a rule or starting past a limit does is done by a function the feature that put the item there registers (#465, #459, #464). `needs_you` is not offered in a sub-chat. Allow everything answers no kind but approvals |
| #463 waking | [3.9](#39-reports-and-waking-pi2reports-pi2wakes); `reports` ([5.6](#56-reports-the-orchestrator)); `reports.wake`; the `reports` event; `wakes`' fields; [8.2](#82-when-a-report-wakes-the-orchestrator) | **Changed.** The orchestrator's choice is made with a new tool, `reports`, not with new parameters of `delegate`. Unread reports reach the orchestrator through #466's catch-up; until #466 lands, through `reports` alone |
| #464 limits | [8.3](#83-limits); the `limit` card's making; `usage`'s `projects` | **Changed.** Waits for #462 too, for the card. The person's own starts are not held back. A carried-over project has no limits |
| #465 the orchestrator changes the project | [3.11](#311-the-record-of-changes-pi2changes); [5.2](#52-project_agents-the-orchestrator), [5.3](#53-project_settings-the-orchestrator), [5.4](#54-project_rules-the-orchestrator); [section 7](#7-reach-what-an-agent-can-only-ask-for); [8.1](#81-what-the-orchestrator-may-do-without-asking)'s switches as approvals; `projectChanges`; `changes.*` | **Changed.** Notes are not recorded and have no Undo. Making another agent the orchestrator is a request (R16). The switch `release` is told, not checked ([section 11](#11-what-the-engine-cannot-check)) |
| #466 one conversation, Start fresh | [6.3](#63-why-the-projects-state-is-not-a-section), [6.4](#64-the-catch-up-and-the-state-block), [6.5](#65-start-fresh); `news` in [3.2](#32-the-project-pi2projects); `freshFrom`; `library`'s `orchestrator`; the conversation state's `project`; `activity`'s `lastLine`; `pi2.toldOrchestrator`; `projects.startFresh`, `projects.setOrchestrator`; `sub_chats` across earlier conversations; the `project` section of [6.1](#61-the-sections) | **Changed.** The state reaches the orchestrator as a catch-up and a state block, not as a section. It also builds the `project` section, and `lastLine` for the Now tab |
| #467 work kept by pi² | [3.10](#310-work-pi2work-and-githubjson)'s first part; `work` ([5.7](#57-work-every-agent-of-a-project)) but the GitHub actions; the `work.*` requests; the `work` event | **Changed.** A fifth state, `blocked`. `assign` starts a sub-chat with the work, which is how work is handed out with its link kept |
| #468 work from GitHub | [3.10](#310-work-pi2work-and-githubjson)'s GitHub part; the `github.*` requests; the `github` event; `work`'s GitHub actions; `PI2_GH` | **Changed.** States and classes are `scripts/issue`'s labels; comments are signed with the agent's line; attaching is refused while the list kept by pi² has open work. For an agent, attaching is a reach request (R4) |
| #469 throwaway copies that show a project | [10.3](#103-with-the-preview-on)'s last paragraph | **Changed.** The names are this page's: `PI2_SHOW=project:…`, `PI2_HUB`, `test-copy.fillProject`, `fill --project`. It adds `PI2_GH` to `scripts/test-copy`'s allowlist, for #480 |
| #470 the sidebar lists projects | [10.2](#102-with-the-preview-off), [10.3](#103-with-the-preview-on); the fields of [4.3](#43-events) | **Changed.** It also builds **Projects (preview)** in Settings › General, and the sheet that shows the carrying-over report before the first run ([9.5](#95-the-report-and-the-run)), being the first app issue. A project's other conversations are listed under it |
| #471 the hub's two panels | [10.1](#101-what-the-app-keeps-itself) | Unchanged |
| #472 the Now tab | `needs`, `activity`'s `lastLine` and `runsAs`, `reports`, `wakes`' `wake`, the `limit` card | Unchanged |
| #473 an agent's conversation in place of the board | `pi2.toldOrchestrator` ([10.3](#103-with-the-preview-on)) | Unchanged |
| #474 changes with Undo, reach requests in the conversation | `projectChanges`, `details.change`, `details.need`, the reach and rule cards ([7.2](#72-asking-allowing-refusing)) | Unchanged |
| #475 the Agents tab, templates | [3.3](#33-agents-and-templates-pi2agents); the agent requests; [8.1](#81-what-the-orchestrator-may-do-without-asking)'s switches | **Changed.** Templates are managed with today's agent pages, for agents with no project. A switch the person turns on by hand asks them to confirm in the app; a reach request is only for agents |
| #476 the Rules tab | [3.6](#36-rules-pi2projectrules), `ruleTokens`, `projects.rules.*`, the rule card | Unchanged |
| #477 the Notes tab | [3.7](#37-notes-pi2memory), `memory.*` with `projectId` | Unchanged; search is in the app, over the event |
| #478 settings, Branches | [section 8](#8-settings-without-asking-waking-limits), `projects.set`, `projects.archive`, `projects.delete`, `github.attach` | Unchanged |
| #479 the Work tab, kept by pi² | [3.10](#310-work-pi2work-and-githubjson), `work.*`, the `work` event | Unchanged |
| #480 the Work tab, GitHub | `github.*`, the `github` event | **Changed.** Needs `PI2_GH` in `scripts/test-copy`'s allowlist (#469) |
| #481 the Dashboard | `needs`; [10.3](#103-with-the-preview-on) on the menu bar's count | Unchanged |
| #482 build pi² as a pi² project | All of it, in use | **Changed.** Carrying over makes the orchestrator's standing rules, kept today as its memory notes, notes of the project; making them rules is done by hand as part of setting the project up |
| #483 take the old way out | [2](#2-the-preview-switch), [3.4](#34-how-a-project-agent-is-shown-runsas), [section 9](#9-carrying-over) | Unchanged. When the switch goes, `runsAs` always takes the project's copy, and `reports`' choices can move into `delegate` |

## 13. Decisions this contract made

What the design left open, or did not say exactly enough to build, and what this page chose. Each is one that the owner might have made differently.

1. **A project's agents are kept with every other agent**, in `pi2.agents`, marked with `projectId`. Every place the engine looks an agent up keeps working, so a project's agent behaves as today's agent does with nothing rebuilt.
2. **Templates are simply the agents that belong to no project.** Today's agents are templates where they stand: nothing is copied to make them, and with the preview off they are the agents list as before.
3. **Carried-over conversations keep their agent, and gain the project's copy beside it** (`projectAgentId`); which one they run as follows the preview switch. Nothing the old way reads is rewritten, so switching the preview off is exact.
4. **The preview switch is the engine's**, and off means that no project section, tool, note or catch-up reaches any agent, and project requests are refused. That is what "nothing an agent is told changes" needs.
5. **One folder, one project; a repository is one folder.** Conversations are grouped by the top of their repository's main checkout, so its worktrees and subfolders join it. Two projects in one repository are not possible yet.
6. **The orchestrator carried over** is the agent of the most recently used conversation that hands out work (has a sub-chat), and that conversation becomes the orchestrator's. Where none does, a default orchestrator with an empty conversation; no one-off conversation is promoted to it.
7. **A project may have no folder** (the design's open question): its agents work in pi²'s scratch folder as folderless conversations do today, and it has no branches or repository. Carrying over puts every folderless conversation in one such project, "No folder".
8. **A project has other conversations** besides the orchestrator's: those carried over, and any the person starts with one of its agents. The sidebar lists them under the project.
9. **A project agent works in the project's folder**, always; `cwd` is set by the engine. Several folders per project would need a design of their own.
10. **A rule binds the orchestrator or everyone**, not one named agent (left open by the design); the field can take a third form later without changing the others.
11. **Rules: at most 50, each 1,000 characters; their cost is characters divided by four**, the same for every model, labelled "about".
12. **No smaller version of rules before projects** (left open by the design): rules come in step 2, behind the preview, which is as early as a version tied to a project can come; a per-agent version would be thrown away.
13. **`delegate` does not change while the preview exists.** Its definition is sent to every conversation that can hand work on, so the waking choices are in a new tool for orchestrators, `reports`.
14. **The project's state is not a prompt section.** A changed section stays in the context until a summary, and the state changes at almost every turn; so a state block starts each context and a catch-up of what changed starts each turn (#466 changes).
15. **A carried-over project keeps working as it did:** reports wake its orchestrator and it has no limits. A new project follows the design: reports do not wake it, and agents stop starting at 90% of a plan window.
16. **Without asking, by default:** start agents, file and close work, make and change agents, add rules the person dictates. Ask first: merge, release, go past a limit.
17. **Allow everything lifts no project switch, and answers no reach request, proposed rule or question.** A switch that is off is the person's choice for this project, newer and narrower than Allow everything.
18. **A reach request does not hold the agent**, is one per call, comes once however often it is asked, and is checked again when allowed: a setting changed meanwhile is not overwritten.
19. **Carrying over is undone by the backup made before its first run, and by the preview switch**, not by a run backwards that would have to tell what the person changed since.
20. **GitHub's work list uses `scripts/issue`'s labels and its "Done." comment**, so this repository's issues are a project's list as they stand, and agents' comments are signed with the agent's name.
21. **Notes stay at 60 per project, and carried notes past that are all kept.** Notes are not recorded as changes and have no Undo: they are the agents' memory, edited on the Notes tab.
22. **Chat mode keeps reading the agents' own notes only**, not projects' notes, during the preview: chat mode is left as it is.
23. **`needs_you` is not offered in a sub-chat**, which cannot be woken to be told an answer; it keeps `ask_user`.
24. **Start fresh does not archive the old conversation**, which would stop its sub-chats: it stays readable and takes no messages, and its sub-chats' reports go to the new one.
25. **Deleting a project archives its conversations and keeps its data**, shown nowhere: pi durable cannot erase, and a person may want it back.
26. **Limits hold back only the agents' hand-offs**, not the person's own starts, the orchestrator's turns or work already running.
27. **Copies made by carrying over take the agent's variables' values and Allow everything;** copies made by hand, like duplicates, do not. Carrying over must not change what a conversation can do; a person's new copy should not inherit secrets unasked.
28. **The record of changes covers the project's configuration** (settings, agents, rules), made by agents or allowed from a request. The person's own edits are not recorded; the orchestrator hears of them in its catch-up.
29. **Only the orchestrator gets the tools that change the project.** Its agents get `work`, and `needs_you` where they can be told the answer.
30. **How a hub was left, and the Dashboard's choice of projects, are the app's preferences**, not the engine's.

## 14. Questions for the owner

Only what this page could not responsibly decide. It is written as if the recommended answer were given.

1. **"Release" cannot be checked, and merging only partly.** The design lists both among what the engine checks. pi² has no release action, so there is nothing to hold back; and a merge is held back only when made through `work` or the app, not when an agent runs `gh pr merge` in its shell with Full access. *Recommended:* keep both switches; `merge` governs merges made through pi² and says so; `release` is the project's policy, told to the orchestrator in its `project` section and marked on the settings page as one pi² tells the agent but cannot check. The alternative is to drop `release` from the list.
2. **Any command an agent runs can reach the engine's socket**, and through it answer its own requests for more reach, as it can answer its own approvals today. Reach requests stop an agent being talked into widening its reach through a tool; they do not stop one that sets out to get round pi² with its shell. *Recommended:* accept this for the epic, as the contract does, and have an issue of its own, outside the epic and before #483, that lets the engine take answers to the person's questions only from the app.
