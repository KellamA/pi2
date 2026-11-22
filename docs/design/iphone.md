# pi² for iPhone: the design

This is the design for epic [#620](https://github.com/KellamA/pi2/issues/620): an iPhone app that does nothing by itself and, once paired with pi² on a Mac, is the whole of pi² from the pocket. Nothing here is built yet. The drawings are in [iphone-drafts.html](iphone-drafts.html): open it in a browser; the buttons along its top switch between the screens, and one switches between dark and light (an address ending in `:light`, such as `iphone-drafts.html#card:light`, opens a screen in light). The contract that every later issue is built against is [../iphone.md](../iphone.md); this page says what the person sees and does, and that page says exactly how.

The owner has answered two of three decisions: the phone must work on any network, with the Mac on another; and it may do everything the person does at the Mac, with a Devices page on the Mac; Face ID opens the app, and nothing is asked after. The third, who it is for, is open; the owner asked what changes if the App Store is planned for from the start, and this page is written for that (below). This page is written for the answers given and for the likely answer of the open one, and each is kept in one place, so a different answer changes that section and the contract's matching section, not the whole.

## What the phone is, and is not

The phone runs no agents, holds no provider's key, and keeps nothing of its own but a short memory of what it last saw. It is a second window onto one Mac's pi², and speaks for the person: the Mac's engine does all the work, as now. Paired once, with both devices in hand, it shows every project, the Dashboard and what needs the person; it talks to orchestrators and agents, answers cards from a notification without opening the app, reads the work list and a pull request's diff and merges it, changes agents and rules, and stops anything. What needs the Mac's own screen or hands (computer use, pi²'s browser, choosing files in the Mac's panels, sign-ins to providers, setting up local models) stays on the Mac. A phone that is lost is cut off from the Mac with one click on the Mac, or by Find My's Erase iPhone away from it, and what it can still read from its own storage is a few days of summaries, kept out of backups. It is a remote control for agents that run code on the Mac as the person, and it is guarded as one ([A stolen or unlocked phone](#a-stolen-or-unlocked-phone)).

## The three decisions

| Decision | Written for | Where it lives |
|---|---|---|
| 1. How the phone reaches the Mac away from home | **Answered**: "it needs to work on separate networks or it defeats the purpose." The whole of pi², the live conversation included, works with the phone on any network and the Mac on another, with nothing to set up beyond pairing. The way recommended: **a small relay pi² runs**, on Cloudflare, which passes only sealed messages and sends the pushes; at home the phone talks to the Mac directly. | [On any network](#on-any-network) here; [sections 5 and 6](../iphone.md#5-transport) of the contract |
| 2. What the phone may do | **Answered**: everything the person does at the Mac, but what needs the Mac's hands or a secret; a Devices page on the Mac. After the security reading: **"Face ID to open the app, nothing after."** The same on every network. | [What the phone may do](#what-the-phone-may-do) here; [4.2](../iphone.md#42-what-a-device-may-send) of the contract |
| 3. Who it is for at first | **Open.** Written for what is likely: **built so that the App Store stays possible, given out to the owner alone through TestFlight first.** | [Who it is for](#who-it-is-for-at-first) here; [section 9](../iphone.md#9-who-it-is-for-and-how-it-is-given-out) of the contract, with [9.5, If it goes to the App Store](../iphone.md#95-if-it-goes-to-the-app-store) |

## The screens

Each has a drawing in [iphone-drafts.html](iphone-drafts.html), in phone-sized frames, dark and light.

### Pairing

On the Mac: **Settings › Devices › Pair an iPhone** shows a code to scan, good for five minutes. On the phone, the first screen says what pi² for iPhone is and offers **Scan the code on your Mac**, and under it **Try it without a Mac**, the demo mode ([below](#the-demo-mode)). The phone scans it with its own camera (never from a link), reaches the Mac (through pi²'s relay, or over the home network if it is on it: pairing works on any network), and shows six digits; **the person types them on the Mac**, which pairs only if they match. The Mac checks for itself that the claim comes from a genuine pi² for iPhone. The code is good for one claim: if another device tries it first, the Mac says so and asks to start again, away from a shared or recorded screen. Typing the digits, rather than comparing two numbers and clicking, is what stops whoever saw the code (someone at the screen, a screen share, or an agent on the Mac, which can take pictures of the screen) from pairing in the person's place. The phone then asks for notifications and for Face ID, saying what each is for. Pairing happens only at the Mac, with the Mac's own app: a phone cannot pair another phone. A phone already paired asks before replacing its pairing with another Mac's.

### The demo mode

The whole app against canned data, with no Mac and no network: demo projects with agents at work, a card of every kind, notifications with their buttons, a conversation that answers, a pull request to merge. A **Demo** bar across the top of every screen says so, with **Leave**, which deletes what the demo wrote. It is there for a person who has installed the app and has nothing paired yet, and for App Review, whose reviewer has no Mac running pi². Every screen in it is the real one, fed by a recording instead of a Mac.

### The projects list, with what needs the person at the top

The phone opens on one list. At the top, **Needs you**: every card waiting, newest first, each answered in place with its buttons (a long one opens). Below it, **Dashboard**, then the projects, each with the badge the Mac's sidebar shows (how many things need the person, or a spinner while its agents work), the orchestrator's last words in a line, and the time. Below the projects, chats and the archive. A bar across the top says which Mac and how it is reached (**At home**, **Through pi²'s relay**, **Direct**, **Mac asleep since 23:10**, **Relay unreachable · at home only**).

### The Dashboard on a phone

The Mac's columns become pages, one per watched project, swiped sideways: what needs the person, who is working (agent, model, how long, last line), the orchestrator's last words, and a field to message it. A strip along the top names the pages, with a dot on any that needs the person.

### A project's hub

A project opens on its **conversation with the orchestrator**, full width, as on the Mac with the board folded. A tab bar along the bottom is the board: **Chat · Now · Work · More**, where More lists Agents, Rules, Notes, Branches and the project's settings. A badge on Now counts what needs the person. The bar at the top names the project, its branch and the orchestrator's model, with the plan's week as a thin meter. The message field takes text, dictation, photos and the camera; **Stop** is where Send was while the orchestrator works.

### A card that needs the person, in the app and as a notification

In the app a card looks as on the Mac: who asks, in which project, what, and its buttons (Allow once, Deny; Answer; Allow…, Refuse; Accept, Refuse; Start anyway, Wait). As a notification: the title names the agent and the kind ("Forge needs approval"), the body the project and the short line the card shows, and the buttons are the card's, as far as a notification can carry them: a question gets **Reply**, which types an answer in the notification; a decision opens the app. Every button opens pi² on the card: it asks Face ID if pi² is not already open, shows the whole card, and then does what was chosen, since Face ID cannot be asked for from a notification in the background.[^fg] The phone must be unlocked first.[^auth] **Allow once** is on a notification only when it shows the whole command, and acts only after the app has shown it whole, so that a harmful end cut off after a harmless start is never allowed unseen. On the Lock Screen, a notification says only who needs the person and why ("Forge needs approval") until the phone is unlocked, unless the person turns details on. A card answered elsewhere (on the Mac, or on another device) takes its notification away.

### An agent's conversation

From Now, Agents, or a link in the orchestrator's conversation, an agent's conversation opens on its own screen, the same transcript page the Mac shows, with a field to write to it. A message written there is told to the orchestrator, as on the Mac. Its tool calls fold, and a long output opens on a screen of its own.

### The Work tab, and a pull request with its diff

Work is a list in the states the Mac uses (open, in progress, waiting, blocked, done), filtered by a segmented control. A piece of work opens with its text, its notes and **Give to an agent**. A pull request shows its checks, what a reviewing agent found, and its files; a file opens its diff, one file at a time, lines wrapped, with additions and removals coloured. **Send back** asks why.

### The Devices page on the Mac

A new tab in Settings, **Devices**: the switch for **Reach from an iPhone**, **Reach through pi²'s relay** with the relay's address and whether it can be reached, and **Find on this network** (the direct path at home); **Direct from any address** (off: the Mac takes direct connections only from home and private networks); each paired device with its name, model, when it was paired and last seen, and how (at home, through the relay, direct, from the mailbox); **Revoke** beside each, and **Resume** for one the Mac suspended after repeated failed tries; **What this device did**, a log of every answer and change it made, every connection and every file it read, with the time, the path and whether Face ID was given; a waiting Face ID key to accept, with *Accept only if you did it yourself*; the line *Lost your iPhone away from this Mac? Erase it with Find My*; and **Pair an iPhone**. While a device is connected, the menu bar item and the sidebar say so (*Alex's iPhone · through the relay*), and the Mac posts a notification when a device is paired, when its Face ID is set up again, and when it makes a change that widens what agents may do.

### The phone when the Mac is asleep or out of reach

The bar says so plainly, with the time the phone last heard from the Mac ("Mac asleep · last seen 23:10"). Everything shows as it was then, dimmed and dated. Answers to cards and messages can still be written: they wait in an **Outbox**; answers and short messages go on to wait in the relay's mailbox, sealed, and the Mac takes them when it wakes; each says whether it went. A card answered more than a day after the Mac last saw it is not sent; the phone says so and keeps the text for the person to send again.

## What the phone may do

Everything the person does at the Mac, but what needs the Mac's hands or a secret ([the table below](#every-screen-and-function-of-the-mac-app) says which, screen by screen). Answers and settings are taken from the phone because it holds keys made at pairing, and only once Face ID has opened pi² on it; the Mac checks that it was. Nothing is asked again while pi² is open. One switch stays on the Mac: **Allow everything**, which ends all asking for an agent. When a phone makes a change that widens what agents may do (more reach, an allowed command, starting past a limit, a merge or a release, a change to an agent's, a chat's or a project's settings, bringing back from the archive, deleting), the Mac notifies the person. The same holds on every network. While the Mac is asleep, only answers and short messages can wait for it in the relay's mailbox; everything else waits until it can be reached. The Mac keeps a log of everything each device did.

## A stolen or unlocked phone

Whoever holds the phone unlocked could use the reach the agents already have: a message to an agent with Full access runs what it says, and **Allow once** runs a waiting command. The common theft today is to watch the passcode, then take the phone, and revoking needs the Mac. The owner chose (the contract's [4.5](../iphone.md#45-a-stolen-or-unlocked-phone-the-owners-choice)): **"Face ID to open the app, nothing after."**

- **Face ID opens pi² on the phone**, with no passcode instead: the passcode is what a thief who watched it has. Without the owner's face, an unlocked phone shows pi²'s notifications and nothing else; its copy of conversations stays locked.
- **Nothing is asked again** while pi² is open.
- **pi² closes itself** a minute after the person leaves it, when the phone locks, and when it is restarted; opening it again asks Face ID.
- **A notification's buttons open pi²**, which asks Face ID if it was closed, shows the whole card, then does what was chosen.
- Siri and Shortcuts do nothing on a locked phone; widgets on the Lock Screen hide their content; the Mac suspends a device after repeated failed tries; away from the Mac the remedy is Find My's **Erase iPhone**, which destroys the keys that pair it.

The security reading recommended Face ID again for the risky answers too. Without it, a phone taken from the hand while pi² is open can, for up to a minute after, merge, approve and change agents with one tap; the Mac notifies the person of each such change, and keeps Allow everything to itself.

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
| **Face ID** | Asked to open pi²; nothing is asked after. | The Mac checks, on every connection, a signature the phone can make only under that Face ID. |

An Apple Watch glance and an iPad layout are left for later, if wanted.

## What stays on the Mac, and why

- **Computer use and pi²'s browser**: they act on the Mac's screen and windows, and the macOS permissions they need belong to the Mac.
- **Choosing files and folders in the Mac's panels**: the phone chooses from the folders the Mac offers (projects' folders, recent folders) instead.
- **Sign-ins and providers' keys, agents' variables' values, MCP servers**: secrets, and programs started on the Mac; the phone never receives a secret, so cannot show or send one.
- **Setting up local models**, installing and removing software, backups and restoring, the projects preview and carrying over, updates, the login item: the Mac's own upkeep, done where its consequences are seen.
- **Pairing another device**: only at the Mac, so that a stolen phone cannot add one.
- **Turning Allow everything on** for an agent: it ends all asking, and with no second Face ID while pi² is open, a phone taken from the hand could otherwise give it in one tap. Turning it off works from the phone.
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
| A pull request: checks, findings, diff, merge, send back | Another shape: one file's diff at a time, lines wrapped |
| Agents (of a project), and an agent's page | Another shape: grouped settings |
| Templates | Another shape: listed and edited as agents |
| Rules, Notes | As it is |
| Branches and worktrees | As it is |
| A project's settings and limits | Another shape: grouped settings |
| Changes with Undo in a conversation | As it is |
| An agent's conversation in place of the board | Another shape: a screen of its own |
| Chat mode | As it is |
| Conversations outside projects, sub-chats | As it is |
| Archive | As it is |
| Activity (runs going now) | Another shape: Now and the Dashboard |
| Background commands and their output window | Another shape: a list; output read on a screen of its own; stop |
| Wakes | As it is |
| Schedules | As it is |
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
| Settings › Tools: allowed commands | As it is: read, add and remove |
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

Decision 3 is open. The owner asked what changes if the App Store is planned for from the start, which is likely where it lands, so this page and the contract are written for it: **built so that the App Store stays possible, given out to the owner alone through TestFlight first.**

- **First, the owner alone**, as an internal tester in TestFlight: no review by Apple, builds good for 90 days, up to 100 people of the owner's own team. The Mac app shows Devices only once the owner turns on a preview switch, as projects had. External testers (up to 10,000 strangers, by e-mail or a public link) would add a review of the first build and everything a stranger needs.
- **Built for anyone from the start**, so the App Store needs no redesign: a pairing is two devices' keys, never an account; the relay serves any number of pairings, each with its own limits, and holds nothing of the owner's; everything it passes is sealed, so it has no content to disclose; only Apple's public APIs; the conversation's page is inside the app, never downloaded; it works on IPv6-only networks; the phone can unpair itself, which deletes what the relay keeps of it; a privacy policy and a way to reach pi² are in the app from the first build; and the demo mode shows a reviewer all of it.
- **What would still be to do then** is work, not redesign: the notes for review, the privacy label and policy, export compliance for the encryption, running the relay for strangers and whether to charge for it (through Apple's in-app purchase if so), the Mac app's first run written for people who are not its author, support, and the listing. One risk cannot be designed away: App Review keeps remote desktop apps that mirror software to the local network, and pi² for iPhone is not one (it draws its own screens from data), which the notes for review must say plainly. The contract's [9.5](../iphone.md#95-if-it-goes-to-the-app-store) lists each, with the guideline it rests on.

## Still open

- Whether a widget should ever show text an agent wrote (the orchestrator's last words), or only counts and names. The contract shows counts and names, and the last line only inside the app. A Live Activity shows numbers only, since its updates pass the relay unsealed.
- Whether to add, later, a fallback that carries notifications through the person's iCloud when the relay is down. Not in this epic.
- Whether the Mac should wake itself for the phone at home (macOS's Wake for network access); nothing here relies on it.
- An Apple Watch glance and an iPad layout.

## Roadmap

The issues, step by step, are in [section 12](../iphone.md#12-the-later-issues) of the contract and, once filed, in the epic. In short: (0) this design and the contract, agreed and read for security; (1) foundations side by side: the shared package, devices in the engine, the encrypted channel, the Mac's helper, the relay and its deployment, the Devices page, the iPhone app's shell, testing with no phone, and a check that the relay sees only sealed bytes; (2) the first useful release, on any network: projects, the Dashboard, Needs you, the orchestrator's conversation, Now, and the demo mode; (3) notifications through the relay, the Mac out of reach, moving between the relay and home; (4) the rest of the board; (5) what only a phone can do; (6) the second security reading, battery and data measured, a lost phone tried.

[^fg]: Apple, [UNNotificationActionOptions.foreground](https://developer.apple.com/documentation/usernotifications/unnotificationactionoptions/foreground): "The action causes the app to launch in the foreground." An action without it runs with the app in the background ([Handling notifications and notification-related actions](https://developer.apple.com/documentation/usernotifications/handling-notifications-and-notification-related-actions)), where no Face ID prompt can be shown.
[^auth]: Apple, [UNNotificationActionOptions.authenticationRequired](https://developer.apple.com/documentation/usernotifications/unnotificationactionoptions/authenticationrequired): "The action can be performed only on an unlocked device."
[^la]: Apple, [Displaying live data with Live Activities](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities): active for up to eight hours, on the Lock Screen up to twelve; static and dynamic data together at most 4 KB; a Live Activity cannot reach the network itself.
[^lapush]: Apple, [Starting and updating Live Activities with ActivityKit push notifications](https://developer.apple.com/documentation/activitykit/starting-and-updating-live-activities-with-activitykit-push-notifications): remote updates are sent by "your server" to APNs over a token-based connection, which needs the developer's push key.
[^widget]: Apple, [Keeping a widget up to date](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date): "a daily budget typically includes from 40 to 70 refreshes … roughly … every 15 to 60 minutes".
