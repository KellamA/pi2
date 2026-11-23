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

Where each is reached from ([design/iphone.md](design/iphone.md#the-screens)): the hub's Work tab draws `.work(project:)` inline, and a pull request opens from it; the hub's More tab lists `.board` for each `BoardPage` and `.projectSettings`; More on the projects list lists `.templates`, `.schedules`, `.backgroundCommands()`, `.usage`, `.archive` and `.settings`; agents' conversations open from Now, the Agents page and the list as `.conversation(id)`, #687's screen, and `.conversations` lists them.

- **Opening another screen**: `@Environment(\.openRoute) private var openRoute`, then `openRoute(.conversation(id))`. It pushes the route's view; `.home` goes back to the list; a hub opened on another tab from the same hub changes tab in place.
- **Drawing another feature inside yours**, such as Needs you at the top of the list or the orchestrator's conversation in the hub's Chat tab: `RouteView(.needs(), placement: .inline)`. The view drawn reads `@Environment(\.placement)` (`.screen` or `.inline`) and leaves out what only a whole screen has: its navigation title, its own scrolling.
- **Never name another feature's view**, only its route. `RouteView.view(for:)` is the one place that maps each route to its view.

## Which folder is whose

Each screen issue owns its folder under `iphone/Sources/` and nothing else ([iphone.md 12.2](iphone.md#122-each-issue)): `Home/` #685, `Hub/` and `Dashboard/` #688, `Conversation/` #687, `Needs/` #686, `Demo/` #684, `Work/` #694, `PullRequest/` #695, `Board/` #696, `Settings/` and `Usage/` #697, `Conversations/` #698. `App/` (the session, the routes, the root, the launch, the first screen) and `pi2.xcodeproj` are #680's: a screen's issue does not edit them. If yours needs something there (a route, a field of the session), say so in your report rather than changing it.

**Shared views** are in `App/Shared/`, for what two features or more draw alike: `AgentMark(agent:)` (or `AgentMark(name:color:)`), an agent's or a project's mark in the Mac's pastels (`AgentColor`), and `Color.pi2Accent`, the app's tint, which the root sets. Use them rather than a copy of your own; ask for another in your report. The texts iOS shows when the app asks for a permission (the camera, the microphone, speech recognition, photos, Face ID) are the project's (`INFOPLIST_KEY_…` in `pi2.xcodeproj`); a feature that needs another asks for it the same way.

**The entry file.** Each folder has one file made for it (a folder with several routes, one for each), holding the type and initialiser in the table above and a body that shows `FeaturePlaceholder`, a box saying which screen it is and which issue builds it. Replace that body, keep the type's name and its initialiser as they are (the routes and the tests call them), and put everything else in new files beside it. A file added in a folder is built with no change to the project ([Building the iPhone app](development.md#building-the-iphone-app)). Name your other types after your feature (`HomeConnectionBar`, `NeedCard`), since every folder is one module.

## Launch arguments

A debug build reads these from its environment; `xcrun simctl launch` passes `SIMCTL_CHILD_<NAME>` as `<NAME>`. None of them is compiled into a release build (`App/DebugLaunch.swift`, all under `#if DEBUG`).

| Variable | Values | What it does |
|---|---|---|
| `PI2_TRANSPORT` | `replay` | Connects to a recorded session instead of a Mac: the one `pi2-client-check` replays, two demo projects with their orchestrators, agents, conversations, work and what needs the person ([Client checks](development.md#client-checks)). The recording is copied into a debug build's bundle and left out of a release build. A conversation's entries come when it is opened; every request but `conversation.open`, `conversation.close` and `conversations.shown` is refused with an error that says so, and changes nothing. The demo mode's `DemoTransport` (#684) takes its place in `Launch` |
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

## Adding a test

Unit tests go in `iphone/Tests/`, a file per feature (`NeedsTests.swift`), in Swift Testing (`import Testing`, `@Test`). The test target runs inside the app, so `@testable import pi2` reaches the app's types, the session and the replay among them; `AppSeamTests.swift` shows a session started on the replay and waited for:

```swift
let session = AppSession()
session.start(try #require(ReplayTransport.recording()), as: .connected(.home))
// then wait, polling, until session.engine.projects is not empty
```

Run them all with `xcodebuild test` and the same arguments as `build` above, or one suite with `-only-testing:pi2Tests/NeedsTests`. No test may depend on how fast the Mac is: wait for a condition with a generous limit, never for a fixed time.
