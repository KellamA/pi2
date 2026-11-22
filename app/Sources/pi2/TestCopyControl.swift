import ComputerKit
import SwiftUI
import WindowKit

#if PI2_DEVELOPMENT
/// `PI2_APPEARANCE=light|dark`, which `scripts/test-copy start|reopen --appearance` sets on the copy's launch: the copy
/// draws in that appearance whatever the Mac's own is, so that a page can be pictured in both (#553). It is the copy's
/// own, under its own bundle id, and the Mac's setting is not touched. Only a development build reads it, as with every
/// test-copy control.
enum TestCopyAppearance {
    static func apply() {
        switch ProcessInfo.processInfo.environment["PI2_APPEARANCE"] {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
    }
}

/// Like PI2_SHOW and the file-driven performance probe, this is part of development builds only.
/// The launch switch isn't enough: require the bundle and data folder that scripts/test-copy makes.
@MainActor
struct TestCopyControl: NSViewRepresentable {
    let model: AppModel
    let folder: URL

    static func folder(for model: AppModel) -> URL? {
        home(engine: model.engine)?.appendingPathComponent("test-copy-control", isDirectory: true)
    }

    /// The data folder of the test copy this app is, or nil when it is not one that scripts/test-copy made.
    static func home(engine: EngineClient) -> URL? { location(engine: engine)?.home }

    static func location(engine: EngineClient) -> (home: URL, checkout: URL)? {
        let bundle = Bundle.main
        guard DevelopmentBuild.isDevelopment,
              let suffix = ProcessInfo.processInfo.environment["PI2_TEST_COPY"], suffix != "dev",
              suffix.range(of: #"^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$"#, options: .regularExpression) != nil,
              bundle.bundleIdentifier == "dev.pi2.app.\(suffix)",
              let main = bundle.object(forInfoDictionaryKey: "PI2EngineMain") as? String else { return nil }
        let checkout = URL(fileURLWithPath: main).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let expected = checkout.appendingPathComponent("app/build/test-copies/\(suffix)/pi² \(suffix).app")
        let own = DevelopmentBuild.defaults(bundleID: bundle.bundleIdentifier, applicationSupport: DevelopmentBuild.usualHome.deletingLastPathComponent())
        guard bundle.bundleURL.standardizedFileURL.path == expected.standardizedFileURL.path,
              engine.dataFolder.standardizedFileURL.path == own.home.standardizedFileURL.path,
              !DevelopmentBuild.isSameFolder(own.home.path, as: DevelopmentBuild.usualHome) else { return nil }
        return (own.home, checkout)
    }

    func makeNSView(context: Context) -> Control { Control(model: model, folder: folder) }
    func updateNSView(_ view: Control, context: Context) {}
    static func dismantleNSView(_ view: Control, coordinator: ()) { view.stop() }

    final class Control: NSView {
        private struct Request: Decodable {
            let pid: Int32
            let command: String
            let id: Int?
            let show: String?
            let hub: String?
            let page: String?
            let width: Int?
            let height: Int?
            let smallest: Bool?
            let narrowest: Bool?
            let paths: [String]?
        }

        let model: AppModel
        let folder: URL
        private var timer: Timer?
        /// `show` requests answered once the page has drawn the conversation, or after `limit`: the request's folder,
        /// the conversation, and how many drawings the page had made when it was asked.
        private var waiting: [(dir: URL, id: Int, after: Int, until: Date)] = []
        /// `show` requests for a project's hub, answered once the hub has drawn what was asked, or after `limit`, and
        /// whether showing an agent's conversation unfolded a folded board (#553).
        private var hubWaiting: [(dir: URL, asked: ProjectCopyView, project: String, unfolded: Bool, until: Date)] = []
        /// `show` requests for the Dashboard, answered once it has drawn its columns, or after `limit` (#481).
        private var dashboardWaiting: [(dir: URL, until: Date)] = []
        /// The project `PI2_SHOW` named at launch, until it comes in the `projects` event and is shown, and how long to
        /// wait for an agent's conversation of it named there.
        private var launchProject: ProjectCopyView?
        private var launchUntil = Date.distantFuture
        /// Within test-copy's own thirty seconds, so it hears why rather than that nothing answered.
        private static let limit: TimeInterval = 20

        init(model: AppModel, folder: URL) {
            self.model = model
            self.folder = folder
            // The computer tool asks a parked copy to raise its window over this folder (#579), and a copy's first
            // look can come before any scripts/test-copy command has made it. A symlink is left alone: poll refuses it.
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            if let launch = ProjectCopyView.launch, launch.show != nil || launch.hub != nil {
                _ = recordProjectView(launch, source: "launch")
                if launch.project != nil {
                    launchProject = launch
                    launchUntil = Date().addingTimeInterval(Self.limit)
                }
            }
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll() }
            }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        }

        func stop() {
            timer?.invalidate()
            timer = nil
        }

        /// The window's split view of the sidebar and the detail: the outermost one, found before any a page holds.
        private static func sidebarSplit(in root: NSView?) -> NSSplitView? {
            var level = root.map { [$0] } ?? []
            while !level.isEmpty {
                if let split = level.lazy.compactMap({ $0 as? NSSplitView }).first(where: { $0.isVertical && $0.arrangedSubviews.count > 1 }) {
                    return split
                }
                level = level.flatMap(\.subviews)
            }
            return nil
        }

        private func isDirectory(_ url: URL) -> Bool {
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
            return values.isDirectory == true && values.isSymbolicLink == false
        }

        private func poll() {
            guard let window, window.isVisible, model.engine.hasLoadedLibrary,
                  isDirectory(folder.deletingLastPathComponent()), isDirectory(folder),
                  let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
            waiting = waiting.filter { wait in
                if (TranscriptDrawn.drawings[wait.id] ?? 0) > wait.after {
                    answer(wait.dir, ["result": "Showing conversation #\(wait.id), drawn"])
                } else if Date() >= wait.until {
                    answer(wait.dir, ["result": "Showing conversation #\(wait.id), though its page had not drawn it after \(Int(Self.limit)) seconds"])
                } else {
                    return isDirectory(wait.dir)
                }
                return false
            }
            hubWaiting = hubWaiting.filter { wait in
                if let drawn = hubDrawn(wait.asked, project: wait.project, unfolded: wait.unfolded) {
                    answer(wait.dir, ["result": drawn])
                } else if Date() >= wait.until {
                    answer(wait.dir, ["result": "Showing the project, though the hub had not drawn it after \(Int(Self.limit)) seconds"])
                } else {
                    return isDirectory(wait.dir)
                }
                return false
            }
            dashboardWaiting = dashboardWaiting.filter { wait in
                if let drawn = DashboardDrawn.current {
                    let columns = drawn.count == 1 ? "1 column" : "\(drawn.count) columns"
                    answer(wait.dir, ["result": "Showing the Dashboard, \(columns), drawn"])
                } else if Date() >= wait.until {
                    answer(wait.dir, ["result": "Showing the Dashboard, though it had not drawn after \(Int(Self.limit)) seconds"])
                } else {
                    return isDirectory(wait.dir)
                }
                return false
            }
            // A project made after launch, such as by `fill --project`, opens when it comes, as a conversation does. An
            // agent's conversation named there comes with the library and the activity, so it is waited for, but not for
            // ever: past the limit the hub opens on its board.
            if let launch = launchProject, let project = launch.project, let id = projectID(project) {
                let conversation = launch.agent.flatMap { asked -> Int? in
                    if case .conversation(let found) = model.agentChoice(asked, of: id) { return found }
                    return nil
                }
                if conversation != nil || launch.agent == nil || Date() >= launchUntil {
                    launchProject = nil
                    model.showProject(id, tab: launch.tab.flatMap { HubTab(rawValue: $0.rawValue) }, fold: launch.hub.flatMap { HubFold(rawValue: $0.rawValue) })
                    if let conversation { model.openAgent(conversation, in: id, beside: false) }
                }
            }
            for name in names.sorted() where name.hasPrefix("request-") {
                let dir = folder.appendingPathComponent(name, isDirectory: true)
                guard isDirectory(dir), !waiting.contains(where: { $0.dir == dir }) else { continue }
                let response = dir.appendingPathComponent("response.json")
                let request = dir.appendingPathComponent("request.json")
                guard !FileManager.default.fileExists(atPath: response.path),
                      let data = try? Data(contentsOf: request),
                      let asked = try? JSONDecoder().decode(Request.self, from: data), asked.pid == getpid() else { continue }
                if let result = apply(asked, to: window, dir: dir) { answer(dir, result) }
            }
        }

        private func answer(_ dir: URL, _ result: [String: String]) {
            if let json = try? JSONEncoder().encode(result) { try? json.write(to: dir.appendingPathComponent("response.json"), options: .atomic) }
        }

        private struct ProjectViewRecord: Encodable {
            let source: String
            let view: ProjectCopyView
        }

        private func recordProjectView(_ view: ProjectCopyView, source: String) -> [String: String] {
            let home = folder.deletingLastPathComponent()
            guard isDirectory(home) else { return ["error": "the copy's data folder is missing or a symlink"] }
            do {
                let data = try JSONEncoder().encode(ProjectViewRecord(source: source, view: view))
                try data.write(to: home.appendingPathComponent("project-view.json"), options: .atomic)
                return ["result": "Recorded \(view.show ?? "hub fold")\(view.hub.map { " (\($0.rawValue))" } ?? "")"]
            } catch {
                return ["error": "could not record the project view: \(error.localizedDescription)"]
            }
        }

        /// A project by its id, or by its name in any case, among those the copy shows.
        private func projectID(_ asked: String) -> String? {
            let engine = model.engine
            let live = engine.projects.filter { $0.deletedAt == nil }
            return (live.first { $0.id == asked } ?? live.first { $0.name.lowercased() == asked.lowercased() })?.id
        }

        /// Shows the hub `view` asks for: its project, its tab, its fold and, when it names an agent, that agent's
        /// conversation in place of the board (#473). Nil when the answer is to wait for the hub to draw it. A fold alone
        /// applies to the project shown. The Dashboard is answered once it has drawn its columns (#481).
        private func showProject(_ view: ProjectCopyView, dir: URL) -> [String: String]? {
            if view.show == "dashboard" {
                model.selection = .dashboard
                // Answered once the Dashboard has drawn its columns, as a hub is once it has drawn what was asked.
                if let drawn = DashboardDrawn.current {
                    let columns = drawn.count == 1 ? "1 column" : "\(drawn.count) columns"
                    return ["result": "Showing the Dashboard, \(columns), drawn"]
                }
                dashboardWaiting.append((dir, Date().addingTimeInterval(Self.limit)))
                return nil
            }
            let fold = view.hub.flatMap { HubFold(rawValue: $0.rawValue) }
            let id: String
            if let project = view.project {
                guard let found = projectID(project) else {
                    return ["error": "no project called \(project) in the copy"]
                }
                id = found
            } else if let shown = model.shownProject {
                id = shown
            } else {
                return ["error": "no project is shown to fold; name one with project:<name>"]
            }
            var conversation: Int?
            if let asked = view.agent {
                switch model.agentChoice(asked, of: id) {
                case .conversation(let found): conversation = found
                case .problem(let why): return ["error": why]
                }
            }
            // Showing an agent's conversation unfolds a board folded in the preferences, which is kept there: the answer
            // says so (#553).
            let unfolded = conversation != nil && (fold ?? model.hubs.fold(id)) == .boardFolded
            model.showProject(id, tab: view.tab.flatMap { HubTab(rawValue: $0.rawValue) }, fold: fold)
            if let conversation { model.openAgent(conversation, in: id, beside: false) }
            hubWaiting.append((dir, view, id, unfolded, Date().addingTimeInterval(Self.limit)))
            return nil
        }

        /// What to answer once the hub has drawn the project, with its tab and fold, and the orchestrator's conversation
        /// when its panel shows it; nil until then.
        private func hubDrawn(_ asked: ProjectCopyView, project: String, unfolded: Bool) -> String? {
            let fold = model.hubs.fold(project)
            guard let drawn = HubDrawn.current, drawn.project == project, drawn.tab == model.hubs.tab(project),
                  drawn.fold == fold.shown(narrow: drawn.narrow, agent: drawn.panes),
                  drawn.agent == (fold == .boardFolded ? nil : model.hubs.agent(project)) else { return nil }
            // The page draws a conversation with entries; an empty one shows the agent's introduction once it has come.
            for conversation in [drawn.conversation, drawn.agent].compactMap({ $0 }) where TranscriptDrawn.drawings[conversation] == nil {
                guard let open = model.engine.open[conversation], open.state != nil, open.items.isEmpty else { return nil }
            }
            let name = model.engine.project(project)?.name ?? project
            let words = switch drawn.fold {
            case .both: "both panels"
            case .conversationFolded:
                // An agent's conversation folds the board by itself only when the window is too narrow for both panels.
                fold == .both && drawn.narrow ? "the conversation folded, as the window is narrow" : "the conversation folded"
            case .boardFolded: drawn.narrow && fold == .both ? "the board folded, as the window is narrow" : "the board folded"
            }
            let agent = drawn.agent.map { conversation in
                let summary = model.engine.conversations.first { $0.id == conversation }
                let who = model.engine.agent(summary?.agentId)?.name ?? "an agent"
                let title = (summary?.title ?? "").isEmpty ? "" : " “\(summary?.title ?? "")”"
                // The board shows, so an unfolded one really is: a window too narrow to hold both panels keeps it folded,
                // and `words` says so instead.
                return "; the conversation with \(who)\(title) in place of the board\(unfolded && drawn.fold != .boardFolded ? ", which was unfolded" : "")"
            } ?? (asked.agent.map { "; no conversation of \($0) is in place of the board" } ?? "")
            return "Showing project “\(name)”, \(drawn.tab.title), \(words), drawn\(agent)"
        }

        /// Shows conversation `id`, or nil when the answer is to wait for its page to draw.
        private func showConversation(_ id: Int, dir: URL, beside: Bool = false) -> [String: String]? {
            guard model.engine.conversations.contains(where: { $0.id == id }) || model.isArchived(id) else {
                return ["error": "no conversation #\(id) in the copy's library"]
            }
            // It opens where it lives (#644): chat mode, a hub's panel or pane, or the Archive's reader. One already on
            // screen there does not draw again.
            let alreadyShown = model.mode == .chat ? model.chats.selection == id
                : HubDrawn.current.map { $0.conversation == id || $0.shown.contains(id) } == true || model.archiveConversation == id
            let before = TranscriptDrawn.drawings[id]
            model.openConversation(id, beside: beside)
            if alreadyShown, before != nil { return ["result": "Showing conversation #\(id), drawn"] }
            waiting.append((dir, id, before ?? 0, Date().addingTimeInterval(Self.limit)))
            return nil
        }

        /// Shows the page a `PI2_SHOW` value names, as the copy's launch does, while the copy runs (#553). A
        /// conversation's page is answered once it has drawn; of any other page it says plainly that it cannot wait.
        private func showPage(_ page: String, dir: URL) -> [String: String]? {
            if ChatLaunch.apply(page, to: model) {
                return ["result": "Showing chat mode from \(page); test-copy cannot wait for its page to be drawn"]
            }
            if let asked = Selection(launch: page) {
                model.selection = asked
                if case .agent(let id) = asked {
                    let section = AgentSection.asked(in: page).map { " at #\($0.section.rawValue)" } ?? ""
                    return ["result": "Showing the page of agent \(id)\(section); test-copy cannot wait for its page to be drawn"]
                }
                return ["result": "Showing \(page); test-copy cannot wait for its page to be drawn"]
            }
            if let id = LaunchConversation.match(page, conversations: model.engine.conversations, archived: model.engine.archived) {
                return showConversation(id, dir: dir)
            }
            // One of a project's conversations in a new pane of its hub, as ⌥ or a sub-chat card's Beside opens it (#657).
            if page.hasPrefix("beside:") {
                guard let id = Int(page.dropFirst("beside:".count)) else { return ["error": "beside:<id> needs a conversation's number"] }
                return showConversation(id, dir: dir, beside: true)
            }
            if page == "palette" || page.hasPrefix("palette:") {
                let query = page == "palette" ? "" : String(page.dropFirst("palette:".count))
                PaletteLaunch.live = query.isEmpty ? nil : query
                model.showingPalette = true
                return ["result": "Opened the command palette\(query.isEmpty ? "" : " with “\(query)” in its search field"); test-copy cannot wait for it to be drawn"]
            }
            if page == "settings" || page.hasPrefix("settings:") {
                guard let asked = SettingsLaunch(page), let open = model.openSettingsWindow else {
                    return ["error": "the copy's Settings window cannot be opened from here"]
                }
                model.settingsTabLive = asked.tab
                open()
                let section = asked.section.map { " at #\($0.rawValue)" } ?? ""
                return ["result": "Opened Settings on \(asked.tab.rawValue.capitalized)\(section); test-copy cannot wait for it to be drawn"]
            }
            if page.hasPrefix("output:") {
                let id = String(page.dropFirst("output:".count))
                guard !id.isEmpty, let open = model.openOutputWindow else {
                    return ["error": "output:<id> needs the id of a background command"]
                }
                open(id)
                return ["result": "Opened the output window of \(id); test-copy cannot wait for it to be drawn"]
            }
            return ["error": "no page or conversation called \(page)"]
        }

        /// The answer to a request, or nil when it is to wait.
        private func apply(_ request: Request, to window: NSWindow, dir: URL) -> [String: String]? {
            switch request.command {
            case "choose":
                guard let paths = request.paths else { return ["error": "missing panel answer"] }
                return TestCopyPanels.choose(paths)
            case "show":
                // A section the page does not have is refused, with those it has.
                if let page = request.page, let refusal = AgentSection.refusal(page) ?? SettingsLaunch.refusal(page) {
                    return ["error": refusal]
                }
                // What was last asked, where an agent's page, its Allow everything confirmation and Settings' tabs take
                // their section from, as they take the launch's (#768).
                if let value = request.page ?? request.show ?? request.id.map({ String($0) }) { ShowAsked.shared.ask(value) }
                if request.show != nil || request.hub != nil {
                    do {
                        let view = try ProjectCopyView(show: request.show, hub: request.hub)
                        guard view.show != nil || view.hub != nil else { return ["error": "not a project view"] }
                        let recorded = recordProjectView(view, source: "show")
                        guard recorded["error"] == nil else { return recorded }
                        return showProject(view, dir: dir)
                    } catch {
                        return ["error": error.localizedDescription]
                    }
                }
                if let page = request.page { return showPage(page, dir: dir) }
                guard let id = request.id else { return ["error": "missing what to show"] }
                return showConversation(id, dir: dir)
            case "expose":
                // The computer tool cannot read a parked window: it is joined to the app's accessibility windows
                // only by an ordering event, which a copy's launch window never gets (#579). Raise this one within
                // its own level, where it stays behind every ordinary window and nothing on screen changes, and put
                // it back — as the Window menu's own command does for a window someone chose. The raise is what
                // the tool needs. The answer is whether the tool's search would then find it, asked of every attribute
                // that search reads, not of the window list alone, which comes and goes with the Space (#612).
                guard !window.styleMask.contains(.fullScreen) else { return ["error": "the main window is full screen"] }
                // A copy opened by hand has no launch switch parking its window, and raising a window among ordinary
                // ones would put it over the person's work, so that one is never raised.
                guard ParkedWindow.isParked(window) else {
                    return ["error": "the main window is not parked behind other windows, so it was not raised"]
                }
                _ = ParkedWindow.expose(window)
                guard ParkedWindow.isReachable(window) else {
                    return ["error": "the app does not give its main window to accessibility, even after raising it: it is not the app's main or focused window, nor among its windows, so the computer tool would not find it"]
                }
                // Found there, the window is still turned down by the tool where the window server's record of it
                // disagrees, so the answer follows the tool's own rule for that too (#748).
                if let refusal = ParkedWindow.refusal(window) { return ["error": refusal] }
                return ["result": "Raised the parked main window within its own level, and the app gives it to accessibility, where the computer tool looks for it, at the size the window server has it"]
            case "size":
                guard !window.styleMask.contains(.fullScreen) else { return ["error": "the main window is full screen"] }
                let minimum = window.frameRect(forContentRect: NSRect(origin: .zero, size: window.contentMinSize)).size
                let minWidth = Int(ceil(max(minimum.width, window.minSize.width)))
                let minHeight = Int(ceil(max(minimum.height, window.minSize.height)))
                let width = request.smallest == true ? minWidth : request.width ?? 0
                let height = request.smallest == true ? minHeight : request.height ?? 0
                guard width >= minWidth, height >= minHeight else {
                    return ["error": "the smallest window is \(minWidth)×\(minHeight) points"]
                }
                guard width <= 10_000, height <= 10_000 else { return ["error": "window dimensions must be at most 10000 points"] }
                let frame = window.frame
                window.setFrame(NSRect(x: frame.minX, y: frame.maxY - CGFloat(height), width: CGFloat(width), height: CGFloat(height)), display: true)
                let actual = window.frame.size
                guard actual == NSSize(width: CGFloat(width), height: CGFloat(height)) else {
                    return ["error": "AppKit sized the main window to \(Int(actual.width))×\(Int(actual.height)) points instead"]
                }
                return ["result": "Sized the main window to \(width)×\(height) points"]
            case "sidebar":
                // The column's width as a person sets it, by its divider (#613). A width written to the copy's
                // preferences before launch does not hold: the split view starts at the column's ideal width.
                guard let split = Self.sidebarSplit(in: window.contentView), let sidebar = split.arrangedSubviews.first else {
                    return ["error": "the main window has no sidebar column"]
                }
                guard !split.isSubviewCollapsed(sidebar), !sidebar.isHidden else {
                    return ["error": "the sidebar is hidden; show it first (View > Show Sidebar)"]
                }
                let asked = request.narrowest == true ? SidebarColumn.narrowest : CGFloat(request.width ?? 0)
                let width = min(max(asked, SidebarColumn.narrowest), SidebarColumn.widest)
                split.setPosition(width, ofDividerAt: 0)
                window.layoutIfNeeded()
                let actual = sidebar.frame.width
                guard abs(actual - width) < 0.5 else {
                    return ["error": "AppKit made the sidebar \(Int(actual.rounded())) points wide instead of \(Int(width)); a wider window may hold it (scripts/test-copy size)"]
                }
                let clamped = asked < SidebarColumn.narrowest ? "its narrowest, " : asked > SidebarColumn.widest ? "its widest, " : ""
                return ["result": "Set the sidebar's width to \(clamped)\(Int(width)) points"]
            default:
                return ["error": "unknown test-copy window command"]
            }
        }
    }
}
#endif

/// A row of a project's Work tab a copy was asked to open, so that a picture can show it: a copy parked behind every
/// other window cannot be clicked (#480). The copy's own preference names it, so nothing of the person's sets it, and
/// only a development build reads it, as with every test-copy control:
///
///     defaults write dev.pi2.app.test-7 work-open -string 'pull:8'
///
/// `issue:1` and `pull:8` open that issue or pull request, `merge:8` opens the pull request with the question to merge
/// it showing, and `diff:8` with its diff. See docs/development.md, "Choosing what a copy shows".
enum WorkRowLaunch: Equatable {
    case issue(Int)
    case pull(Int)
    case merge(Int)
    case diff(Int)

    static var asked: WorkRowLaunch? {
        #if PI2_DEVELOPMENT
            guard let asked = UserDefaults.standard.string(forKey: "work-open") else { return nil }
            let parts = asked.split(separator: ":")
            guard parts.count == 2, let number = Int(parts[1]) else { return nil }
            switch parts[0] {
            case "issue": return .issue(number)
            case "pull": return .pull(number)
            case "merge": return .merge(number)
            case "diff": return .diff(number)
            default: return nil
            }
        #else
            return nil
        #endif
    }
}

#if PI2_DEVELOPMENT
/// How many times the transcript page has drawn each conversation from the start, once it was shown or the page loaded
/// again: for a test copy's `show`, which answers once the page has drawn the one it asked for.
@MainActor
enum TranscriptDrawn {
    private static var count = 0
    private(set) static var drawings: [Int: Int] = [:]

    static func note(_ conversation: Int) {
        count += 1
        drawings[conversation] = count
    }
}
#endif

/// What a test copy does in place of what would reach beyond it: it writes it down, for a test to read.
@MainActor
enum TestCopyRecord {
    /// Where a test copy writes what a file link would have shown, opened or copied (#451), one JSON object a line:
    /// `file-links.jsonl` in its data folder. Nil in any other copy of pi², which does it.
    static func fileLinks(engine: EngineClient) -> URL? {
        #if PI2_DEVELOPMENT
        TestCopyControl.home(engine: engine)?.appendingPathComponent("file-links.jsonl")
        #else
        nil
        #endif
    }

    /// Adds one line to `file`.
    static func append(_ entry: [String: Any], to file: URL) {
        guard var line = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        line.append(UInt8(ascii: "\n"))
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: file, options: .atomic)
        }
    }
}

extension View {
    func testCopyControl(model: AppModel) -> some View {
        #if PI2_DEVELOPMENT
        background {
            if let folder = TestCopyControl.folder(for: model) { TestCopyControl(model: model, folder: folder) }
        }
        #else
        self
        #endif
    }
}
