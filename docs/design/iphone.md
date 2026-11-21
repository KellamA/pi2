# pi² for iPhone: the design

This is the design for epic [#620](https://github.com/KellamA/pi2/issues/620): an iPhone app that does nothing by itself and, once paired with pi² on a Mac, is the whole of pi² from the pocket. Nothing here is built yet. The drawings are in [iphone-drafts.html](iphone-drafts.html): open it in a browser; the buttons along its top switch between the screens, and one switches between dark and light (an address ending in `:light`, such as `iphone-drafts.html#card:light`, opens a screen in light). The contract that every later issue is built against is [../iphone.md](../iphone.md); this page says what the person sees and does, and that page says exactly how.

The owner has answered the first of three decisions: the phone must work on any network, with the Mac on another. The other two are open (below). This page is written for the answer given and for the recommended answer of each open one, and each is kept in one place, so a different answer changes that section and the contract's matching section, not the whole.

## What the phone is, and is not

The phone runs no agents, holds no provider's key, and keeps nothing of its own but a short memory of what it last saw. It is a second window onto one Mac's pi², and speaks for the person: the Mac's engine does all the work, as now. Paired once, with both devices in hand, it shows every project, the Dashboard and what needs the person; it talks to orchestrators and agents, answers cards from a notification without opening the app, reads the work list and a pull request's diff and merges it, changes agents and rules, and stops anything. What needs the Mac's own screen or hands (computer use, pi²'s browser, choosing files in the Mac's panels, sign-ins to providers, setting up local models) stays on the Mac. A phone that is lost is cut off from the Mac with one click, and what it can still read from its own storage is a few days of summaries behind its passcode.

## The three decisions

| Decision | Written for | Where it lives |
|---|---|---|
| 1. How the phone reaches the Mac away from home | **Answered**: "it needs to work on separate networks or it defeats the purpose." The whole of pi², the live conversation included, works with the phone on any network and the Mac on another, with nothing to set up beyond pairing. The way recommended: **a small relay pi² runs**, on Cloudflare, which passes only sealed messages and sends the pushes; at home the phone talks to the Mac directly. | [On any network](#on-any-network) here; [sections 5 and 6](../iphone.md#5-transport) of the contract |
| 2. What the phone may do | **What the person does at the Mac**, but what needs the Mac's hands or a secret; the riskiest answers (more reach, Allow everything, a merge, starting past a limit) ask for Face ID first. The same on every network. | [What the phone may do](#what-the-phone-may-do) here; [4.2](../iphone.md#42-what-a-device-may-send) of the contract |
| 3. Who it is for at first | **The owner alone, through TestFlight**, until the security reading of step 6; then the owner decides about the App Store. | [Who it is for](#who-it-is-for-at-first) here; [section 9](../iphone.md#9-who-it-is-for-and-how-it-is-given-out) of the contract |

## The screens

Each has a drawing in [iphone-drafts.html](iphone-drafts.html), in phone-sized frames, dark and light.

### Pairing

On the Mac: **Settings › Devices › Pair an iPhone** shows a code to scan, good for five minutes. On the phone, the first screen says what pi² for iPhone is and offers **Scan the code on your Mac**. The phone scans it, reaches the Mac (through pi²'s relay, or over the home network if it is on it: pairing works on any network), and both show the same six digits; the person checks them and clicks **Pair** on the Mac. The phone then asks for notifications and for Face ID, saying what each is for. Pairing happens only at the Mac, with the Mac's own app: a phone cannot pair another phone.

### The projects list, with what needs the person at the top

The phone opens on one list. At the top, **Needs you**: every card waiting, newest first, each answered in place with its buttons (a long one opens). Below it, **Dashboard**, then the projects, each with the badge the Mac's sidebar shows (how many things need the person, or a spinner while its agents work), the orchestrator's last words in a line, and the time. Below the projects, chats and the archive. A bar across the top says which Mac and how it is reached (**At home**, **Through pi²'s relay**, **Direct**, **Mac asleep since 23:10**, **Relay unreachable · at home only**).

### The Dashboard on a phone

The Mac's columns become pages, one per watched project, swiped sideways: what needs the person, who is working (agent, model, how long, last line), the orchestrator's last words, and a field to message it. A strip along the top names the pages, with a dot on any that needs the person.

### A project's hub

A project opens on its **conversation with the orchestrator**, full width, as on the Mac with the board folded. A tab bar along the bottom is the board: **Chat · Now · Work · More**, where More lists Agents, Rules, Notes, Branches and the project's settings. A badge on Now counts what needs the person. The bar at the top names the project, its branch and the orchestrator's model, with the plan's week as a thin meter. The message field takes text, dictation, photos and the camera; **Stop** is where Send was while the orchestrator works.

### A card that needs the person, in the app and as a notification

In the app a card looks as on the Mac: who asks, in which project, what, and its buttons (Allow once, Deny; Answer; Allow…, Refuse; Accept, Refuse; Start anyway, Wait). A card that asks for Face ID says so on its button (**Allow with Face ID**). As a notification: the title names the agent and the kind ("Forge needs approval"), the body the project and the short line the card shows, and the buttons are the card's, as far as a notification can carry them: a question gets **Reply**, which types an answer in the notification; a decision opens the app. A button that needs Face ID opens the app on the card and asks there, since Face ID cannot be asked for from a notification in the background.[^fg] Every button asks for the phone to be unlocked first.[^auth] A card answered elsewhere (on the Mac, or on another device) takes its notification away.

### An agent's conversation

From Now, Agents, or a link in the orchestrator's conversation, an agent's conversation opens on its own screen, the same transcript page the Mac shows, with a field to write to it. A message written there is told to the orchestrator, as on the Mac. Its tool calls fold, and a long output opens on a screen of its own.

### The Work tab, and a pull request with its diff

Work is a list in the states the Mac uses (open, in progress, waiting, blocked, done), filtered by a segmented control. A piece of work opens with its text, its notes and **Give to an agent**. A pull request shows its checks, what a reviewing agent found, and its files; a file opens its diff, one file at a time, lines wrapped, with additions and removals coloured. **Merge** asks for Face ID; **Send back** asks why.

### The Devices page on the Mac

A new tab in Settings, **Devices**: the switch for **Reach from an iPhone**, **Reach through pi²'s relay** with the relay's address and whether it can be reached, and **Find on this network** (the direct path at home); each paired device with its name, model, when it was paired and last seen, and how (at home, through the relay, direct, from the mailbox); **Revoke** beside each; **What this device did**, a log of every answer and change it made, with the time, the path and whether Face ID was given; and **Pair an iPhone**.

### The phone when the Mac is asleep or out of reach

The bar says so plainly, with the time the phone last heard from the Mac ("Mac asleep · last seen 23:10"). Everything shows as it was then, dimmed and dated. Answers to cards and messages can still be written: they wait in an **Outbox**; answers and short messages go on to wait in the relay's mailbox, sealed, and the Mac takes them when it wakes; each says whether it went. A card answered more than a day after the Mac last saw it is not sent; the phone says so and keeps the text for the person to send again.

## What the phone may do

Everything the person does at the Mac, but what needs the Mac's hands or a secret ([the table below](#every-screen-and-function-of-the-mac-app) says which, screen by screen). Answers and settings are taken from the phone because it holds a key made at pairing; the riskiest ask for Face ID on the phone first, and the Mac checks that it was given. The list that asks for Face ID is short: more reach for an agent, Allow everything, an allowed command added, starting past a limit, a merge, a change to an agent's or a project's settings, Undo of a change, deleting anything. The same list holds on every network. While the Mac is asleep, only answers and short messages can wait for it in the relay's mailbox; everything else waits until it can be reached. The Mac keeps a log of everything each device did.

## On any network

The owner's answer to decision 1: "it needs to work on separate networks or it defeats the purpose." So away from home is the main case, not the exception.

- **The main path is a small relay pi² runs.** The Mac and the phone each connect *out* to it, which any network allows, and it passes their messages between them. The two are encrypted end to end with keys made at pairing, so the relay can read none of it: it knows that a Mac and its phones are talking, how much and when, and nothing else. The whole of pi² works this way, the live conversation included, a few tens of milliseconds behind the Mac.
- **At home, the phone talks to the Mac directly**: the same encryption, the same keys and the same messages, over the home network, which is faster and costs the relay nothing. The phone moves between the two by itself as it comes and goes, without losing an answer being written. A private network the person already has (Tailscale and the like) is used the same way, and nothing needs it.
- **Notifications come from the relay**, sealed so that only the phone can read them: the relay holds pi²'s push key and asks Apple to deliver a notice whose text only the phone can open.
- **While the Mac sleeps**, the relay keeps a small mailbox for a day: the phone's answers and short messages wait there, sealed, and the Mac takes them when it wakes.
- **When the relay is down**, the phone still works at home, and over a private network; away from both it shows its last state, dated, and keeps what is written until it can send it. There are no notifications until the relay is back. A person who wants no relay can turn it off on the Mac, or run their own from pi²'s code.

**Why a relay**, of the three ways compared in the contract ([section 6](../iphone.md#6-across-any-two-networks-the-ways-compared)): a direct connection made through both networks' NATs fails often enough on mobile networks that a relay is needed anyway, and Apple's frameworks have no way to make one; the person's iCloud carries a notification and an answer well, but cannot carry a conversation as it is written. **Why Cloudflare**: no server to look after, connections that cost nothing while they wait, nothing to pay for one person on its free plan, and about $10 a month for a thousand people on its $5 plan.

**What the owner sets up once**: a Cloudflare account, a push key from the Apple developer account, and the app's records for TestFlight. pi² does the rest: the relay's code in this repository, its tests, its deployment, and every key, made at pairing. The person who uses the phone sets up nothing beyond pairing.

## What a phone adds

| | What it shows or does | What it needs from the Mac |
|---|---|---|
| **Live Activity and Dynamic Island** | For a project the person chose to follow: how many agents are working, what needs the person, and the last thing that finished; on the Lock Screen and in the Dynamic Island, tapping opens the hub. It ends by itself when the project goes idle, and Apple ends any after eight hours.[^la] | The project's counts, under 4 KB.[^la] Apple updates a Live Activity while the app is closed only through a push sent with the developer's push key,[^lapush] which the relay holds. That push cannot be sealed, since the system reads it directly, so it carries numbers only (working, needing the person, finished), which the relay can read; the project's name is set on the phone. The person turns on each Live Activity, and its switch says so. |
| **Widgets** | **Needs you** (the count and the newest card, which opens it), **Who is working** (agents and their projects), **Today's spending** against the plan's windows. | Counts and names the app and its notifications have stored on the phone. Apple decides how often a widget is redrawn, about every 15 to 60 minutes for one the person often looks at.[^widget] |
| **Shortcuts and Siri** | "Ask pi² to …": sends a message to a project's orchestrator (chosen, or the last one used) and speaks or shows the answer when it comes; "What needs me in pi²"; "Stop pi² in <project>". | The same requests the app makes, on any network. If the Mac is asleep, the message waits in the relay's mailbox and the Shortcut says the answer will come later. |
| **The share sheet** | Send a link, a text, a photo or a file from any app to an orchestrator or an agent, with a line of instructions. | `submit` with attachments, as the Mac's message field sends them, on any network; only text waits in the mailbox while the Mac sleeps. |
| **Camera and dictation** | The message field takes a photo, a scan, or dictation (Apple's own, on the keyboard), as attachments or text. | Nothing new: pictures are attachments as on the Mac. |
| **Face ID** | Asked before the riskiest answers. | The Mac checks a fresh signature made only after Face ID for that one request. |

An Apple Watch glance and an iPad layout are left for later, if wanted.

## What stays on the Mac, and why

- **Computer use and pi²'s browser**: they act on the Mac's screen and windows, and the macOS permissions they need belong to the Mac.
- **Choosing files and folders in the Mac's panels**: the phone chooses from the folders the Mac offers (projects' folders, recent folders) instead.
- **Sign-ins and providers' keys, agents' variables' values, MCP servers**: secrets, and programs started on the Mac; the phone never receives a secret, so cannot show or send one.
- **Setting up local models**, installing and removing software, backups and restoring, the projects preview and carrying over, updates, the login item: the Mac's own upkeep, done where its consequences are seen.
- **Pairing another device**: only at the Mac, so that a stolen phone cannot add one.
- **The relay's switches and address**: on the Mac's Devices page, so that a phone cannot change where its own messages go.

## Every screen and function of the Mac app

"As it is": the same content and actions, laid out for the phone. "Another shape": the function is there, done differently. "Not": stays on the Mac.

| Mac screen or function | On the phone |
|---|---|
| Sidebar of projects, with badges | Another shape: the projects list, with Needs you above it |
| The Dashboard | Another shape: one page per watched project, swiped sideways |
| Needs you (and the Inbox) | As it is: the same cards, answered in place; and as notifications with buttons |
| A project's hub: the orchestrator's conversation | As it is, full width |
| A project's hub: the board and its folding | Another shape: a tab bar (Chat · Now · Work · More) |
| Now | As it is |
| Work: the list, a piece of work, giving it to an agent | As it is |
| A pull request: checks, findings, diff, merge, send back | Another shape: one file's diff at a time, lines wrapped; merge with Face ID |
| Agents (of a project), and an agent's page | Another shape: grouped settings; changes with Face ID |
| Templates | Another shape: listed and edited as agents, with Face ID |
| Rules, Notes | As it is; removing a rule with Face ID |
| Branches and worktrees | As it is: read; removing a worktree with Face ID |
| A project's settings and limits | Another shape: grouped settings; changes with Face ID |
| Changes with Undo in a conversation | As it is; Undo with Face ID |
| An agent's conversation in place of the board | Another shape: a screen of its own |
| Chat mode | As it is |
| Conversations outside projects, sub-chats | As it is |
| Archive | As it is; deleting with Face ID |
| Activity (runs going now) | Another shape: Now and the Dashboard |
| Background commands and their output window | Another shape: a list; output read on a screen of its own; stop |
| Wakes | As it is |
| Schedules | As it is; a new or changed schedule with Face ID |
| Usage, limits, the plan strip | Another shape: a page, and a widget |
| Search | As it is |
| Command palette | Not: the phone has search, Shortcuts and Siri |
| Quick Ask | Another shape: Shortcuts, Siri and the share sheet |
| The menu bar item | Another shape: widgets and a Live Activity |
| Notifications | Another shape: pushes with the card's buttons |
| Attachments from Finder, drag and drop | Another shape: photos, camera, Files, the share sheet |
| A file linked in a conversation (open, reveal in Finder) | Another shape: read as text where the engine can send it; **Show on Mac** otherwise |
| Choosing a project's folder | Another shape: from the folders the Mac offers |
| Forking, versions, retry, edit, compaction | As it is |
| Settings › General (awake, auto-archive) | As it is for those two; the login item, appearance of the Mac app and command priority: not |
| Settings › Chat | As it is |
| Settings › Providers: keys, sign-ins, endpoints, models | Not; choosing a model from those set up is on the phone |
| Settings › Tools: allowed commands | As it is: read and remove; adding one with Face ID |
| Settings › Tools: variables | Another shape: names only; values set on the Mac |
| Settings › Tools: MCP servers, computer use, browser use | Not |
| Settings › Tools: co-author line | As it is |
| Settings › Storage: data folder, backups, restore | Not |
| Local models | Not |
| Computer use, pi²'s browser window | Not |
| Welcome and onboarding | Not: the phone has its own first screen, pairing |
| Updates | Not |
| Projects preview switch, carrying over | Not |
| Settings › Devices (new) | Not: pairing, revoking and the relay are the Mac's |

## Who it is for at first

Under the recommended answer to decision 3, the owner alone, through TestFlight's internal testing, with the Mac's pi² as the owner already runs it. The app goes to anyone else only after step 6, the second security reading, and on the owner's word. Until then nothing in the Mac app shows Devices unless the owner turns on a preview switch, as projects had.

## Still open

- Whether a widget should ever show text an agent wrote (the orchestrator's last words), or only counts and names. The contract shows counts and names, and the last line only inside the app. A Live Activity shows numbers only, since its updates pass the relay unsealed.
- Whether to add, later, a fallback that carries notifications through the person's iCloud when the relay is down. Not in this epic.
- Whether the Mac should wake itself for the phone at home (macOS's Wake for network access); nothing here relies on it.
- An Apple Watch glance and an iPad layout.

## Roadmap

The issues, step by step, are in [section 12](../iphone.md#12-the-later-issues) of the contract and, once filed, in the epic. In short: (0) this design and the contract, agreed and read for security; (1) foundations side by side: the shared package, devices in the engine, the encrypted channel, the Mac's helper, the relay and its deployment, the Devices page, the iPhone app's shell, testing with no phone, and a check that the relay sees only sealed bytes; (2) the first useful release, on any network: projects, the Dashboard, Needs you, the orchestrator's conversation, Now; (3) notifications through the relay, the Mac out of reach, moving between the relay and home; (4) the rest of the board; (5) what only a phone can do; (6) the second security reading, battery and data measured, a lost phone tried.

[^fg]: Apple, [UNNotificationActionOptions.foreground](https://developer.apple.com/documentation/usernotifications/unnotificationactionoptions/foreground): "The action causes the app to launch in the foreground." An action without it runs with the app in the background ([Handling notifications and notification-related actions](https://developer.apple.com/documentation/usernotifications/handling-notifications-and-notification-related-actions)), where no Face ID prompt can be shown.
[^auth]: Apple, [UNNotificationActionOptions.authenticationRequired](https://developer.apple.com/documentation/usernotifications/unnotificationactionoptions/authenticationrequired): "The action can be performed only on an unlocked device."
[^la]: Apple, [Displaying live data with Live Activities](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities): active for up to eight hours, on the Lock Screen up to twelve; static and dynamic data together at most 4 KB; a Live Activity cannot reach the network itself.
[^lapush]: Apple, [Starting and updating Live Activities with ActivityKit push notifications](https://developer.apple.com/documentation/activitykit/starting-and-updating-live-activities-with-activitykit-push-notifications): remote updates are sent by "your server" to APNs over a token-based connection, which needs the developer's push key.
[^widget]: Apple, [Keeping a widget up to date](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date): "a daily budget typically includes from 40 to 70 refreshes … roughly … every 15 to 60 minutes".
