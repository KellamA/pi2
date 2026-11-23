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
| (none: the first screen shows it) | Try it without a Mac, the demo mode | `DemoEntry()` | `Demo/` | #684 |

A project's id is `ProjectRow.id`, a conversation's `ConversationSummary.id`.

- **Opening another screen**: `@Environment(\.openRoute) private var openRoute`, then `openRoute(.conversation(id))`. It pushes the route's view; `.home` goes back to the list; a hub opened on another tab from the same hub changes tab in place.
- **Drawing another feature inside yours**, such as Needs you at the top of the list or the orchestrator's conversation in the hub's Chat tab: `RouteView(.needs(), placement: .inline)`. The view drawn reads `@Environment(\.placement)` (`.screen` or `.inline`) and leaves out what only a whole screen has: its navigation title, its own scrolling.
- **Never name another feature's view**, only its route. `RouteView.view(for:)` is the one place that maps each route to its view.

## Which folder is whose

Each screen issue owns its folder under `iphone/Sources/` and nothing else ([iphone.md 12.2](iphone.md#122-each-issue)): `Home/` #685, `Hub/` and `Dashboard/` #688, `Conversation/` #687, `Needs/` #686, `Demo/` #684. `App/` (the session, the routes, the root, the launch, the first screen) and `pi2.xcodeproj` are #680's: a screen's issue does not edit them. If yours needs something there (a route, a field of the session), say so in your report rather than changing it.

**The entry file.** Each folder has one file made for it, holding the type and initialiser in the table above and a body that shows `FeaturePlaceholder`, a box saying which screen it is and which issue builds it. Replace that body, keep the type's name and its initialiser as they are (the routes and the tests call them), and put everything else in new files beside it. A file added in a folder is built with no change to the project ([Building the iPhone app](development.md#building-the-iphone-app)). Name your other types after your feature (`HomeConnectionBar`, `NeedCard`), since every folder is one module.

## Launch arguments

A debug build reads these from its environment; `xcrun simctl launch` passes `SIMCTL_CHILD_<NAME>` as `<NAME>`. None of them is compiled into a release build (`App/DebugLaunch.swift`, all under `#if DEBUG`).

| Variable | Values | What it does |
|---|---|---|
| `PI2_TRANSPORT` | `replay`, `demo` | `demo` starts the demo mode ([The demo mode](#the-demo-mode)), which answers. `replay` connects to a recorded session instead of a Mac: the one `pi2-client-check` replays, two demo projects with their orchestrators, agents, conversations, work and what needs the person ([Client checks](development.md#client-checks)). The recording is copied into a debug build's bundle and left out of a release build. A conversation's entries come when it is opened; every request but `conversation.open`, `conversation.close` and `conversations.shown` is refused with an error that says so, and changes nothing |
| `PI2_CONNECTION` | `not-paired`, `demo`, `connecting`, `home`, `relay`, `direct`, `home-relay-down`, `out-of-reach` | What the connection bar says. With the replay it is `home` unless given, without it `not-paired` (the first screen) |
| `PI2_SHOW` | `home`, `dashboard[:<project>]`, `project:<project>[#chat\|now\|work\|more]`, `conversation:<id>`, `needs[:<project>]`, `face-id-check` | The route to open at launch, once the project it names has arrived. `<project>` is a project's name or id: the recording's are **Demo project** and **Demo project 2**, whose orchestrators' conversations are 9 and 139. `face-id-check` opens the Face ID check from the first screen |
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

- **`DemoTransport`** is one more `EngineTransport`. It starts from `Demo/Recording/demo-session.jsonl`, the latest event of each kind and every conversation of two demo projects, which `scripts/demo-recording` makes from the scripted demo model of a throwaway copy (run it again, with a development build, whenever the engine's events change shape). Unlike the replay it **answers**: the script in `Demo/Script/` answers each request against the recording held in memory, as the engine would, and sends the events that follow. It opens no socket, registers for nothing and writes nothing; leaving the demo forgets every change. The recording is in every build, a release build too.
- **What it answers today**: opening and closing conversations, `submit` (the demo model's answer, streamed, with the conversation working meanwhile; a second message waits its turn) and `abort`, and every kind of card (`needs.answer`, `inbox.decide`, `inbox.answer`, `needs.list`), which takes the card away and lets the agent carry on. **Anything else is refused** with "The demo does not do *method*: nothing was changed…", which your screen must show decently, and is noted in `world.unanswered`.
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
