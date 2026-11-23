# The iPhone app: how it is put together

This page is for whoever builds a screen of pi² for iPhone (`iphone/`). It says what the screens share, where each one's code goes, and how to draw a screen in a simulator and picture it before pairing or the demo mode exist. What the app must do is the contract, [iphone.md](iphone.md), and the design, [design/iphone.md](design/iphone.md); how to build the project and the rules for the simulator are [Building the iPhone app](development.md#building-the-iphone-app).

## The session

`AppSession` (`iphone/Sources/App/AppSession.swift`) is the one object the whole app shares, in the environment:

```swift
@Environment(AppSession.self) private var session
```

- `session.engine` is EngineKit's client, an `EngineSession<MessageField>`, the same client the Mac app holds ([iphone.md section 8](iphone.md#8-the-shared-package)). Everything a screen shows is read from it, as the Mac's views read it: `projects`, `needs`, `conversations` and `rootConversations`, `activity`, `agents`, `open[id]` for an open conversation (after `openConversation(id)`), and the rest of its properties. Requests go through it: `call`, `perform`, `submit`, `openConversation`. No screen holds a transport or a client of its own.
- `session.connection` is what the connection bar says: `.notPaired`, `.demo`, `.connecting`, `.connected(path, relayReachable:)` with the path `.home`, `.relay` or `.direct`, and `.outOfReach(lastSeen:)`. `session.macName` is the paired Mac's name. For now they are set from outside: by the launch arguments below, and later by pairing and the channel (the rest of #680) and the demo mode (#684).
- `MessageField` is what the client keeps of a conversation's message field: its `text`.
- The transport is chosen in one place, `Launch` (`App/Launch.swift`).

## The routes

`Route` (`App/Route.swift`) names every screen; `RootView` (`App/RootView.swift`) is the one navigation root: the first screen while no Mac is paired and the demo is off, otherwise a `NavigationStack` on the projects list.

| Route | Screen | Entry view and its initialiser | Folder | Issue |
|---|---|---|---|---|
| `.home` | The projects list, Needs you on top, the connection bar (the root) | `HomeView()` | `Home/` | #685 |
| `.project(id, tab: .chat)` | A project's hub on a tab: `HubTab` `.chat`, `.now`, `.work`, `.more` | `HubView(projectID: String, tab: HubTab)` | `Hub/` | #688 |
| `.dashboard(project: id?)` | The Dashboard's pages, opened at a project's | `DashboardView(projectID: String?)` | `Dashboard/` | #688 |
| `.conversation(id)` | A conversation on its own screen | `ConversationView(conversationID: Int)` | `Conversation/` | #687 |
| `.needs(project: id?)` | What needs the person, of one project or all | `NeedsView(projectID: String?)` | `Needs/` | #686 |
| `.work(project: id, item: n?)` | A project's work list (the hub's Work tab, inline), or a piece of work by its number | `WorkView(projectID: String, itemID: Int?)` | `Work/` | #694 |
| `.pullRequest(project: id, number: n, file: path?)` | A pull request, opened from Work, or one file's diff by its path | `PullRequestView(projectID: String, number: Int, file: String?)` | `PullRequest/` | #695 |
| `.board(project: id, page: .agents)` | A board page the hub's More tab lists: `BoardPage` `.agents`, `.rules`, `.notes`, `.branches` | `BoardView(projectID: String, page: BoardPage)` | `Board/` | #696 |
| `.agent(id, project: id?)` | An agent's page: a project's agent, or with no project a template | `BoardAgentView(agentID: String, projectID: String?)` | `Board/` | #696 |
| `.templates` | The templates, from More on the projects list | `BoardTemplatesView()` | `Board/` | #696 |
| `.projectSettings(id)` | A project's settings and limits, from its hub's More tab | `ProjectSettingsView(projectID: String)` | `Settings/` | #697 |
| `.settings` | The app's settings a phone may change, from More on the projects list | `SettingsView()` | `Settings/` | #697 |
| `.schedules` | The schedules, from More on the projects list | `SchedulesView()` | `Settings/` | #697 |
| `.usage` | Usage and limits: the plan's windows, today's spending | `UsageView()` | `Usage/` | #697 |
| `.conversations(project: id?)` | A project's other conversations (its agents', sub-chats), or with no project those outside projects, chats among them | `ConversationsView(projectID: String?)` | `Conversations/` | #698 |
| `.archive` | The archive | `ArchiveView()` | `Conversations/` | #698 |
| `.backgroundCommands(output: id?)` | The background commands, or one's output | `BackgroundCommandsView(commandID: String?)` | `Conversations/` | #698 |
| `.newProject` | A new project, from a folder the Mac offers | `NewProjectView()` | `Conversations/` | #698 |

A project's id is `ProjectRow.id`, a conversation's `ConversationSummary.id`, an agent's `AgentProfile.id`, a background command's `BackgroundCommand.id`.

Where each is reached from ([design/iphone.md](design/iphone.md#the-screens)): the hub's Work tab draws `.work(project:)` inline, and a pull request opens from it; the hub's More tab lists `.board` for each `BoardPage`, `.conversations(project:)` and `.projectSettings`; More on the projects list lists `.templates`, `.schedules`, `.backgroundCommands()`, `.usage`, `.archive` and `.settings`; agents' conversations open from Now, the Agents page and the list as `.conversation(id)`, #687's screen, and `.conversations` lists them.

- **Opening another screen**: `@Environment(\.openRoute) private var openRoute`, then `openRoute(.conversation(id))`. It pushes the route's view; `.home` goes back to the list; a hub opened on another tab from the same hub changes tab in place.
- **Drawing another feature inside yours**, such as Needs you at the top of the list or the orchestrator's conversation in the hub's Chat tab: `RouteView(.needs(), placement: .inline)`. The view drawn reads `@Environment(\.placement)` (`.screen` or `.inline`) and leaves out what only a whole screen has: its navigation title, its own scrolling.
- **Never name another feature's view**, only its route. `RouteView.view(for:)` is the one place that maps each route to its view.

## Which folder is whose

Each screen issue owns its folder under `iphone/Sources/` and nothing else ([iphone.md 12.2](iphone.md#122-each-issue)): `Home/` #685, `Hub/` and `Dashboard/` #688, `Conversation/` #687, `Needs/` #686, `Demo/` #684, `Store/` and `Outbox/` #692, `Work/` #694, `PullRequest/` #695, `Board/` #696, `Settings/` and `Usage/` #697, `Conversations/` #698. `App/` (the session, the routes, the root, the launch, the first screen) and `pi2.xcodeproj` are #680's: a screen's issue does not edit them. If yours needs something there (a route, a field of the session), say so in your report rather than changing it.

**Shared views** are in `App/Shared/`, for what two features or more draw alike: `AgentMark(agent:)` (or `AgentMark(name:color:)`), an agent's or a project's mark in the Mac's pastels (`AgentColor`), and `Color.pi2Accent`, the app's tint, which the root sets. Use them rather than a copy of your own; ask for another in your report. The texts iOS shows when the app asks for a permission (the camera, the microphone, speech recognition, photos, Face ID) are the project's (`INFOPLIST_KEY_…` in `pi2.xcodeproj`); a feature that needs another asks for it the same way.

**The entry file.** Each folder has one file made for it (a folder with several routes, one for each), holding the type and initialiser in the table above and a body that shows `FeaturePlaceholder`, a box saying which screen it is and which issue builds it. Replace that body, keep the type's name and its initialiser as they are (the routes and the tests call them), and put everything else in new files beside it. A file added in a folder is built with no change to the project ([Building the iPhone app](development.md#building-the-iphone-app)). Name your other types after your feature (`HomeConnectionBar`, `NeedCard`), since every folder is one module.

## The phone's store and the Outbox

`Store/` and `Outbox/` (#692) keep what the phone holds between launches (iphone.md 3.6): the last state its Mac sent, and what the person wrote while the Mac was out of reach. Neither is wired into the session yet; this is what `AppSession` is to call, and when.

- **`PhoneStore()`**, one for the app, made at launch: one folder, `Library/Application Support/Store`, protected (`NSFileProtectionComplete`), out of backups. `sweep()` at launch and at every return to the foreground wipes what has gone seven days without the Mac; it needs no key.
- **`open(key:)`** with the cache key, once Face ID has opened the session (`Keys/` reads it under the session's context); **`close()`** when the session ends, which forgets the key and what was read. The cache and the Outbox are sealed with that key.
- **Connected**: `session.start(RecordingTransport(channel, store: store), as: .connected(path))`, which keeps every line the Mac sends in the cache as it passes. **Then the Outbox goes first**: `await outbox.send(through: EngineOutboxCourier(session.engine))`. Mailbox receipts: `outbox.receipt(for:taken:why:)`. A state from the mailbox: show it only if `store.takeState(number:)` says so.
- **Out of reach**: `session.start(CachedTransport(store.cache, outbox: outbox), as: .outOfReach(lastSeen: store.lastHeard))`. Every screen draws the last state through the same client; a message, a stop or an answer sent meanwhile goes to the Outbox, and anything else is refused with a line saying it needs the Mac.
- **Wiping**: `store.wipe(.unpaired)`, `.revoked` (only after RemoteKit's `Revocation.verify` with the Mac's identity key), or `.asked`: one call; it returns the Outbox's items that were not sent, for the screen to show before they are gone.
- **The Outbox's screen**: `OutboxView()`, for a route `.outbox`, with the `Outbox` in the environment (`.environment(outbox)`); `.inline` draws one line counting what waits. The window is covered in the app switcher by `.coveredInAppSwitcher()` on the root.

## Launch arguments

A debug build reads these from its environment; `xcrun simctl launch` passes `SIMCTL_CHILD_<NAME>` as `<NAME>`. None of them is compiled into a release build (`App/DebugLaunch.swift`, all under `#if DEBUG`).

| Variable | Values | What it does |
|---|---|---|
| `PI2_TRANSPORT` | `replay`, `demo` | `demo` starts the demo mode ([The demo mode](#the-demo-mode)), which answers. `replay` connects to a recorded session instead of a Mac: the one `pi2-client-check` replays, two demo projects with their orchestrators, agents, conversations, work and what needs the person ([Client checks](development.md#client-checks)). The recording is copied into a debug build's bundle and left out of a release build. A conversation's entries come when it is opened; every request but `conversation.open`, `conversation.close` and `conversations.shown` is refused with an error that says so, and changes nothing |
| `PI2_CONNECTION` | `not-paired`, `demo`, `connecting`, `home`, `relay`, `direct`, `home-relay-down`, `out-of-reach` | What the connection bar says. With the replay it is `home` unless given, without it `not-paired` (the first screen) |
| `PI2_SHOW` | `home`, `dashboard[:<project>]`, `project:<project>[#chat\|now\|work\|more]`, `conversation:<id>`, `needs[:<project>]`, `face-id-check`; `work:<project>[#<number>]`, `pull-request:<project>#<number>[:<file>]`, `board:<project>[#agents\|rules\|notes\|branches]`, `agent:<id>` (a template) or `agent:<project>#<id>`, `templates`, `project-settings:<project>`, `settings`, `schedules`, `usage`, `conversations[:<project>]`, `archive`, `background-commands[:<id>]`, `new-project` | The route to open at launch, once the project it names has arrived. `<project>` is a project's name or id: the recording's are **Demo project** and **Demo project 2**, whose orchestrators' conversations are 9 and 139. `face-id-check` opens the Face ID check from the first screen |
| `PI2_HUB_ACT`, `PI2_HUB_SCROLL` | `wake`, `stop`, `send:<text>`; `wake`, `stop-problem`, `finished`, `words` | A state of the hub's Now tab or the Dashboard reached by a tap, for a picture without one (#688, `Hub/HubDebugAct.swift`): turns Now's switch for reports waking the orchestrator on, stops the first run listed, or sends `<text>` from the Dashboard's field, each through the real request, so the recording's refusal shows; then scrolls the list to that row |

## Drawing a screen and picturing it

Use a simulator of your own, never the booted one, and derived data in your scratch folder ([Building the iPhone app](development.md#building-the-iphone-app) has the rules). From your worktree, for issue 686:

```bash
SIM=$(xcrun simctl create pi2-686 "iPhone 18 Pro")
xcrun simctl boot "$SIM"
nice -n 15 xcodebuild build -project iphone/pi2.xcodeproj -scheme pi2 \
  -destination "platform=iOS Simulator,id=$SIM" CODE_SIGNING_ALLOWED=NO \
  -derivedDataPath "$PI2_SCRATCH/iphone-build"
xcrun simctl install "$SIM" "$PI2_SCRATCH/iphone-build/Build/Products/Debug-iphonesimulator/pi2.app"
SIMCTL_CHILD_PI2_TRANSPORT=replay SIMCTL_CHILD_PI2_SHOW='needs' xcrun simctl launch "$SIM" dev.pi2.ios
sleep 2   # the replay is read on launch; a picture taken at once can show the screen empty
mkdir -p app/build/shots/686 && xcrun simctl io "$SIM" screenshot app/build/shots/686/needs.png
xcrun simctl terminate "$SIM" dev.pi2.ios   # before launching it again with other variables
xcrun simctl delete "$SIM"                  # when done
```

`xcrun simctl ui "$SIM" appearance dark` (or `light`) pictures the other appearance, and `xcrun simctl ui "$SIM" content_size accessibility-extra-extra-extra-large` the largest text. `xcrun simctl io … screenshot` takes the simulator's screen only, never the Mac's. Put the pictures worth keeping in `app/build/shots/<issue>/`, which git ignores. A SwiftUI `#Preview` beside your view works in Xcode too, but the pull request's pictures come from the simulator.

## The demo mode

The demo mode (#684, `Demo/`; [iphone.md 9.4](iphone.md#94-the-demo-mode)) is the whole app against canned data, with no Mac and no network: **Try it without a Mac** on the first screen starts it, and a debug build starts it with `PI2_TRANSPORT=demo` (with `PI2_SHOW` as above; `PI2_DEMO_NOTIFY=1` also shows the demo's notifications as it starts). `session.connection` is then `.demo` and `session.macName` is `Demo Mac`.

- **`DemoTransport`** is one more `EngineTransport`. It starts from `Demo/Recording/demo-session.jsonl`, the latest event of each kind and every conversation of two demo projects, which `scripts/demo-recording` makes from the scripted demo model of a throwaway copy (run it again, with a development build, whenever the engine's events change shape). It holds a card of every kind: questions and decisions, approvals of an agent's command (in the inbox), more reach and a proposed rule in **Demo project**, and in **Demo project 2** a start its daily spend limit held back and an approval its `fileWork` switch asked for, its orchestrator waiting on it. Atlas and Forge are at work in both projects, and in the first a sub-chat of the orchestrator (Scout, "Time the walkthrough") whose report is still to come. Unlike the replay it **answers**: the script in `Demo/Script/` answers each request against the recording held in memory, as the engine would, and sends the events that follow. It opens no socket, registers for nothing and writes nothing; leaving the demo forgets every change. The recording is in every build, a release build too.
- **What it answers today**, each as the engine does, with the same result and the events that follow:
  - a conversation (`Script/ConversationAnswers.swift`): `conversation.open`, `.close`, `.older` (nothing is older), `conversations.shown`; `submit` with pictures and files, checked as the engine checks them, answered by the demo model streamed ("With it came 1 picture"), with a message sent while it works queued (`steer` or `followUp`) until `withdraw` takes it back; `abort`, which ends the demo's answer or a run the recording holds (an agent's command, or one waiting on an approval, whose card is withdrawn), with the run stopped (`failure` `aborted`), out of the activity and, for a sub-chat the orchestrator handed out, its report ended `stopped`; `continue`, which answers the last message again; `conversation.image` for a picture sent in the demo;
  - what needs the person (`Script/NeedsAnswers.swift`): every kind of card through `needs.answer`, `inbox.decide` and `inbox.answer`, and `needs.list`. The card leaves Needs you and the inbox, so every count follows, and the agent carries on: an approved command runs; an approval a switch asked for takes only `once` or `deny`, and allowed, files the work it held; more reach allowed makes its change; a rule accepted joins the project's rules; Start anyway on a limit card starts the sub-chat it holds, which answers and reports;
  - the library (`Script/LibraryAnswers.swift`): `conversation.create` for a chat, `.pin`, `.archive` (stopping what works), `.unarchive`, `search`;
  - a project (`Script/ProjectAnswers.swift`): `projects.set` (its switches, `wakeOnReports` and limits, checked; its folder is the Mac's and is refused), `.rename`, `.archive` (refused while anything of it works or waits), `.startFresh` and `.watch`.

  **Anything else is refused** with "The demo does not do *method*: nothing was changed…", which your screen must show decently, and is noted in `world.unanswered`.
- **Adding your screen's answers**: when your screen sends a request the demo does not answer, add a file in `Demo/Script/` named after your feature (`WorkAnswers.swift`) holding `extension DemoScript { static let work: [String: DemoAnswer] = ["work.list": { request, world in … }] }`, and one line for it in `DemoScript.features`. An answer reads `request.params`, changes the world with `world.change("<event>") { … }` (which sends that event whole, as the engine does), `world.append(_:to:)` and `world.changeState(of:)` for a conversation, and `world.after(seconds) { … }` for what follows a moment later; it returns the result the engine returns, or throws `DemoRefusal("<the engine's words>")`. Do what the engine does, in the shape it does it: read the engine's handler for the request first. `Script/ConversationAnswers.swift` and `Script/NeedsAnswers.swift` are examples.
- **Adding your screen to the demo's test**: `iphone/Tests/DemoTests.swift` opens every screen listed in `DemoScreens.all` in the demo, checks that it draws, and fails if it sent a request the script does not answer. Add a line for each of your screens and states there: its name with your issue, and the route that opens it.
- **The Demo bar** (`DemoBar`, `.demoBar()`) goes above every screen while the demo is on, with **Leave**; a demo notification's button opens its card's screen through it.

## Adding a test

Unit tests go in `iphone/Tests/`, a file per feature (`NeedsTests.swift`), in Swift Testing (`import Testing`, `@Test`). The test target runs inside the app, so `@testable import pi2` reaches the app's types, the session and the replay among them; `AppSeamTests.swift` shows a session started on the replay and waited for:

```swift
let session = AppSession()
session.start(try #require(ReplayTransport.recording()), as: .connected(.home))
// then wait, polling, until session.engine.projects is not empty
```

Run them all with `xcodebuild test` and the same arguments as `build` above, or one suite with `-only-testing:pi2Tests/NeedsTests`. No test may depend on how fast the Mac is: wait for a condition with a generous limit, never for a fixed time.

## Shortcuts and Siri

`Intents/` (#701) holds the App Intents: **Ask an Orchestrator**, **What Needs Me** and **Stop a Project**, each with `authenticationPolicy = .requiresAuthentication` ([iphone.md 4.5](iphone.md#45-a-stolen-or-unlocked-phone-the-owners-choice)), a project as an `AppEntity` (`IntentProject`) read from `session.engine.projects`, and `PiShortcuts`, the phrases. They send what the Mac's screens send, through the same client: `submit` as the Dashboard's strip does, `abort` for each of the project's agent runs as Stop All does, and they read what needs the person from the client's `needs`.

- **The session.** App Intents run in the app's process, which iOS starts in the background for one, running `Pi2App.init` but drawing no scene. `App/` is to register its session there, once: `IntentSessions.register(session, isOpen: { … })`, where `isOpen` says whether a session Face ID opened is open, once `AppSession` keeps one. While it is closed, an intent opens pi² in the foreground for Face ID before it sends or reads anything (iOS 26 and later; before, it asks the person to open pi²). Until `App/` registers one, an intent makes a session as `Pi2App.init` does.
- **The Mac out of reach.** An intent sends through `IntentCourier`; its one courier, `IntentEngineCourier`, sends on `session.engine` and reads the Outbox's answer `{ "outbox": <id> }` (#692's `CachedTransport`, run by the session while `.outOfReach`) as kept for later, which the intent says: the message waits in the mailbox and the answer comes later. Without it, the intent says nothing was sent.
- **Tests.** `IntentsTests.swift` calls each intent's `perform()` and what it says in each state, on the recording, in the demo mode, and on stand-ins for a Mac that answers and for the Outbox. `IntentSessions.prompts` stands in for the system's confirmation and its opening of the app, which a test cannot answer.
