# Projects: the design

*Kept as history: this is the design as it was made, not the app as it is. For the app as it is, see [the guide](../guide.md); for projects' exact names and shapes, [the contract](../projects.md).*

This is the design for epic [#450](https://github.com/KellamA/pi2/issues/450): pi² organised around projects, each with an orchestrator, in place of free-standing agents and their conversations. It records what the owner decided on 19 November 2026 and what is still open. Nothing here is built yet. The drawings are in [projects-drafts.html](projects-drafts.html): open it in a browser; the buttons along its top switch between the screens.

The work is split into issues, listed step by step in the epic's roadmap. The first is the contract, `docs/projects.md` ([#455](https://github.com/KellamA/pi2/issues/455)); nothing else starts until the owner has agreed it.

## Why

pi² was built around agents a person defines one by one, and the conversations had with each. The way pi² itself is built is different, and works better: one long-lived conversation per codebase with an agent that plans, hands the work to other agents, reviews what comes back, and reports. Today that way of working is assembled by hand from an agent's instructions, memory notes, scripts and habit. The app should be built around it.

## Words

- **Project**: a piece of work with a folder (often a git repository), an orchestrator, agents, rules, notes, a list of work, and settings.
- **Orchestrator**: the project's main agent. The person talks to it; it hands work to the project's other agents.
- **Agent**: as today (model, instructions, tools and the rest), but belonging to one project.
- **Template**: an agent kept outside any project, to make agents from.
- **Hub**: what opens when a project is clicked.
- **Board**: the half of the hub that shows the project's state.
- **Needs you**: everything waiting for the person, in one place.

## The sidebar

The sidebar lists projects, in place of conversations and agents. Each shows a badge: how many things need the person, or how many agents are working, or idle. A project's row is its orchestrator's too: the orchestrator is the project's voice, not one more of its agents, so it has no row of its own. The row shows a spinner in place of the project's mark while the orchestrator works, the waiting dot or the hourglass while it waits for the person or a limit, names the orchestrator and its model in its help, and offers to stop it in its menu. The open project lists the agents working now beneath it, then its other conversations, as sub-chats are listed under a conversation today, and the arrow keys go from the project to its first working agent. Each of those rows, and each of the project's other conversations, has a quiet second line: the branch it works on, with the old sidebar's mark for a worktree of its own or the main checkout, and the size of its change in lines added and removed (`+128 −14`, nothing when there is none). A working agent in the repository's main checkout on its default branch says so there, in the warning's colour. The title has the room: the agent's name beside it gives way first, cut in the middle and then down to the agent's avatar. Above the projects is the Dashboard; below them, the templates and the archive. The switch between this and chat mode stays.

## The hub

The hub is two panels side by side: the conversation with the orchestrator on the left, the board on the right (draft C).

- **Each panel folds**, with a button and a key of its own, and a project remembers how it was left. Both shown: talking and seeing together. The conversation folded: the board takes the width, and a strip along the bottom keeps the orchestrator's last words and a field to answer. The board folded: the conversation takes the width, for a long plan or a review. In a narrow window the board folds by itself.
- **The board's tabs are the project's navigation:** Now, Work, Agents, Rules, Notes, Branches, and its settings. (The drawings also show tabs in the bar above; those go.)
- **Now** shows what needs the person, who is working (the agent, its model, how long, its last line), and what finished today.
- **Clicking an agent** opens its conversation in place of the board, so the person can watch or talk to a worker and still talk to the orchestrator. A message sent straight to an agent is told to the orchestrator, so it does not act on a stale picture.
- **The board's side splits into panes** (#657), as the old screens' conversation area did, so two or three workers can be watched at once beside the orchestrator. Each pane shows the board or one of the project's conversations, under the agent panel's header with a close button; the board shows in one pane at most and can always be had back (closing the last conversation brings it, and a new pane offers it). View › Split Right and Split Down make a pane that offers the project's working agents first, then its other conversations, to the keyboard; Close Pane, Next and Previous Pane, Even Out and the ready-made layouts work on the panes. A conversation opened from the sidebar, Now, the Work tab or a link goes to the focused pane (from the board, to the conversation pane used last, so the board stays), and with ⌥, or a sub-chat card's Beside, to a new pane beside it; one dragged from the sidebar shows in the pane it is dropped on, or beside it when dropped on its right or bottom edge. Each column, the orchestrator's conversation and each pane side by side, gets the same width and never less than 320 points: a window too narrow for the conversation beside the panes folds it, as it folds the board, and a split that cannot fit is refused with a line that says why. Folding the board folds all its panes. A project keeps its panes, and comes back to them; a pane whose conversation is archived or deleted closes. Only the project's own conversations show in its panes: across projects is the Dashboard's.
- **The bar** shows the project, its folder and branch, the orchestrator's model, and how much of the plan's week is used.

## The orchestrator

- **One conversation per project, for good.** It is kept small by summaries. **Start fresh** begins a new one from the board, the rules and the notes; the old one stays readable.
- **The project's state lives outside the conversation**: the board, the rules, the notes and the work list. A summary or a fresh start loses nothing, and the hub goes on working while the orchestrator waits on a provider's limit.
- **It can do everything about the project that the person can do by hand**: make and change agents, change settings, add rules, file and close work. It has a tool for each. Every change it makes shows in the conversation as a line with Undo.
- **Except widen its own reach.** A change that lets agents do more or spend more (merging or releasing without asking, a higher limit, Allow everything, dropping a rule) it can only ask for, as a card under Needs you that the person answers with one click. Otherwise text the agent merely reads, such as a web page or another agent's report, could talk it into raising its own limits.
- **What it may do without asking is explicit**, per project, and shown on its page: start agents, file and close work, make and change agents, add rules the person dictates, merge, release, go past a limit.
- **Reports and waking.** A report from an agent does not wake the orchestrator by default: it lands under Finished and waits. A small switch in the hub turns waking on for the project. The orchestrator can also ask to be woken itself: for one agent, for a batch when all of it has ended, or only when one fails.

## Needs you

One list for everything that waits for the person: an agent's request to run something, a question, a decision, a request for more reach, a proposed rule. Each is a card answered in place. It does not stop the agent that asked from doing other work, and it stays until answered, where a question asked in a message scrolls away. The same cards show in the hub, on the Dashboard, and behind the menu bar item.

## The Dashboard

The person ticks the projects to watch. Each gets a column: what needs the person, who is working, the orchestrator's last words, and a field to message it, with a button to the project's own hub. Cards are answered there. With every project ticked it does what the Inbox does today.

Under each column's header, one quiet line of the project's vitals: what needs the person, who is working and how many wait for a provider's limit until when, what finished today and how much of it the orchestrator has not read, and what the project spent today against its limit; each part opens the hub where it is shown (#618). At the column's foot, a small window onto the conversation with the orchestrator: its last few turns as the app's own text, Markdown drawn simply and each run of tool calls one quiet line, following as it writes, with what the orchestrator is doing in its header. The field under it messages the orchestrator, so a short exchange needs no hub. The window can be made taller by its top edge or folded away, for each column, and its header opens the hub. Only the end of the conversation is asked for, and a column out of sight or folded asks for nothing.

Under Working, what finished today, folded with its count and how many the orchestrator has not read, in the Now tab's own rows; for a project whose work is a GitHub repository, its open pull requests, only when there are any, each with its checks and its review in a word, opening it on the Work tab (nothing is merged from the Dashboard). Across the top, one line for all the projects watched: how many things need the person (⌥⌘0 brings the first into view), how many agents work, today's spending, and each subscription's windows as Usage shows them, marked while a provider refuses for its limit and until when. The person puts the columns in their own order by dragging a header onto another (or Move Left and Move Right in its menu), folds a column to a narrow strip with its name and badge, and ⌥⌘1 to ⌥⌘9 put the keyboard in that column's field; Tab moves among a column's own cards before the next column's.

## Agents and templates

- Agents are made per project, with everything an agent has today as far as it makes sense for an agent in a project.
- The orchestrator is an agent too, with the same page, plus its list of what it may do without asking.
- A template is copied into a project when it is used, so changing the copy changes that project only. **Update from template** brings a copy up to date.
- Making an agent by hand and asking the orchestrator for one end in the same place.

## Rules and notes

- **Rules** are a short list that is the person's. They are given to the model at every turn, word for word, in a section of their own outside the conversation, so no summary can change or drop them. Each rule binds the orchestrator alone or every agent in the project. The board shows them and what they cost in tokens at every request.
- The person writes rules, or dictates one to the orchestrator. Unasked, an agent can only propose one, as a card to accept, edit or refuse. Dropping a rule is a change that widens reach, so an agent can only ask for it.
- **Notes** are what an agent keeps for itself: facts about the project, as memory is today. They belong to the project, so a new orchestrator starts with them.
- [Allowed commands](../allowed-commands.md) are separate: they say which shell commands an agent may run without asking.

## Work

A project has a list of work, in one of two modes, behind the same screen:

- **Kept by pi²**: for a project with no repository, or one that does not use GitHub's issues.
- **A GitHub repository attached to the project**: its issues and pull requests are the list. pi² shows them and changes them there. To begin with it uses the sign-in the Mac's `gh` already has.

Every agent in the project knows the list through tools (take, note, finish, file, open a pull request), so no script or instruction has to teach it the tracker. A pull request shows its checks and what a reviewing agent found, and can be read, sent back or merged in the app. Whether the orchestrator may merge by itself is the project's setting.

## Limits

Limits on spending are the project's settings and are enforced by the app: past the limit, no new agent is started, whatever an agent remembers or forgets. Plans' limits are shared by all projects, and a model on this Mac answers one request at a time; the Dashboard is where that shows.

## What stays, and what becomes of what there is

- Chat mode stays as it is.
- A project can be made from a folder in one step, with a default orchestrator, so a small task needs no setting up.
- Today's agents become templates. Today's conversations are grouped into projects by their folder.
- The present agents and conversations keep working until projects can replace them. While both exist, projects are a preview the person switches on.

## Still open

- Whether a rule can bind one named agent, besides "the orchestrator" and "every agent".
- Whether a first, smaller version of rules (per agent, on the app as it is) is worth shipping before projects.
- What a project with no folder at all looks like.

## Roadmap

The issues, step by step, are in the epic, [#450](https://github.com/KellamA/pi2/issues/450). In short:

1. **The contract** (`docs/projects.md`): the engine's documents, requests, events and tools for a project, and how what exists is carried over. Agreed by the owner before anything is built.
2. **The engine**, with nothing a person sees changed: projects, their agents and templates, the carrying-over, rules, notes, Needs you, waking, limits, the orchestrator's own tools, the list of work and GitHub.
3. **The hub**: the sidebar of projects, the two panels and their folding, Now, an agent's conversation in place of the board. The first release with the preview.
4. **Agents, Rules, Notes, settings** on the board.
5. **Work** on the board, for both kinds of list.
6. **The Dashboard.**
7. **Projects become the only way**: pi² itself built as a pi² project for a week, then the old screens taken out, on the owner's word.

The old way and the new exist side by side behind a preview switch until the last step.
